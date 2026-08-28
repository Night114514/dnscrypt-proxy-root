#!/system/bin/sh
set -u

MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"

# Establish the fail-closed lifecycle invariant before interrupting background
# work. Any control/updater process that reaches a later start/firewall commit
# observes this marker and cancels instead of racing uninstall cleanup.
if ! request_module_shutdown; then
  log_msg "$SERVICE_LOG" "Failed to create the module shutdown marker during uninstall."
  # The module manager also treats a root-level remove flag as a shutdown
  # condition. Use it as a second independent, fail-closed guard so a late
  # updater/watchdog cannot restart the service while uninstall is in flight.
  : > "$MODDIR/remove" 2>/dev/null \
    || log_msg "$SERVICE_LOG" "Failed to create the fallback module remove marker during uninstall."
fi

# Stop the exact tracked watchdog before removing its intentional-stop marker or
# scripts. Otherwise the detached shell can outlive the module and keep trying
# to restart a path that no longer exists.
stop_watchdog

# Give an in-flight atomic control operation a bounded opportunity to finish on
# the original lock inode. If it is stuck, shutdown-stop is marker-gated and
# repeatedly removes any process/rules that passed a pre-shutdown check.
DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS=30 \
  sh "$MODDIR/scripts/dnscrypt-control.sh" stop >/dev/null 2>&1
STOP_STATUS=$?
if [ "$STOP_STATUS" -ne 0 ]; then
  sh "$MODDIR/scripts/dnscrypt-control.sh" shutdown-stop >/dev/null 2>&1
  STOP_STATUS=$?
fi
if [ "$STOP_STATUS" -eq 0 ]; then
  rm -rf "$MODDIR/tmp" "$MODDIR/run"
else
  # Keep run/control.lock and route-localnet.state intact on incomplete cleanup.
  # Unlinking a contended lock would permit a second operation on a new inode;
  # deleting route state would also make a later restoration impossible.
  rm -rf "$MODDIR/tmp"
  log_msg "$SERVICE_LOG" "Uninstall cleanup is incomplete; runtime lock/state files were retained for the module manager removal step."
fi

# Proactively wipe DNS query logs (privacy-sensitive) in case the manager leaves
# the module directory or config dir behind after uninstall.
rm -f "$MODDIR/config/query.log" "$MODDIR/config/nx.log" \
      "$MODDIR/config/blocked-names.log" "$MODDIR/config/blocked-ips.log" \
      "$MODDIR/config/dnscrypt-proxy.log" \
      "$MODDIR/logs/query.log" "$MODDIR/logs/nx.log" 2>/dev/null || true

# Intentionally keep logs/config until module directory is removed by the manager.
# Module managers remove $MODDIR after uninstall; this script only ensures runtime cleanup.
