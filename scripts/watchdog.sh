#!/system/bin/sh
set -u

SCRIPT_DIR=${0%/*}
MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd) || exit 1
. "$MODDIR/scripts/common.sh"

# A watchdog must never inherit service/control/updater advisory locks. service.sh
# already closes fd 7 for the child; these closes also make direct/manual launch
# safe and prevent a long-lived shell from pinning any stale lock inode.
exec 7>&- 8>&- 9>&-

watchdog_cleanup() {
  _recorded_pid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)
  [ "$_recorded_pid" != "$$" ] || rm -f "$WATCHDOG_PID_FILE"
}
trap 'watchdog_cleanup; exit 0' HUP INT TERM
trap watchdog_cleanup 0

shutdown_requested && exit 0

_watchdog_tmp="$WATCHDOG_PID_FILE.$$.tmp"
printf '%s\n' "$$" > "$_watchdog_tmp" \
  && chmod 0600 "$_watchdog_tmp" 2>/dev/null \
  && mv -f "$_watchdog_tmp" "$WATCHDOG_PID_FILE" || exit 1

notify_count=0
restart_pending=1
WATCHDOG_INTERVAL_SECONDS=${DNSCRYPT_WATCHDOG_INTERVAL_SECONDS:-60}
case "$WATCHDOG_INTERVAL_SECONDS" in
  ""|*[!0-9]*|0) WATCHDOG_INTERVAL_SECONDS=60 ;;
esac

while [ -f "$MODDIR/module.prop" ]; do
  sleep "$WATCHDOG_INTERVAL_SECONDS"
  [ -f "$MODDIR/module.prop" ] || exit 0

  # KernelSU/APatch expose disable/remove markers inside the module directory.
  # Stop promptly while scripts are still available, restore Private DNS, and
  # then terminate this watchdog instead of surviving module deactivation.
  if shutdown_requested; then
    DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS=10 \
      sh "$MODDIR/scripts/dnscrypt-control.sh" stop >/dev/null 2>&1
    _stop_status=$?
    [ "$_stop_status" -eq 0 ] && exit 0
    sh "$MODDIR/scripts/dnscrypt-control.sh" shutdown-stop >/dev/null 2>&1 \
      && exit 0
    log_msg "$SERVICE_LOG" "Could not stop cleanly while the module is disabled/removed; watchdog will retry."
    # Cleanup failures (for example settings temporarily unavailable) should be
    # retried promptly rather than leaving the module active for another minute.
    WATCHDOG_INTERVAL_SECONDS=5
    continue
  fi

  if sh "$MODDIR/scripts/dnscrypt-control.sh" health >/dev/null 2>&1; then
    restart_pending=1
    continue
  fi

  # A user-initiated stop is not a fault. A later start removes the marker and
  # the healthy branch above re-arms recovery for a future outage.
  [ -f "$USER_STOPPED_FILE" ] && continue
  [ "$restart_pending" -eq 1 ] || continue
  restart_pending=0

  if [ "$notify_count" -lt 3 ]; then
    notify_user "dnscrypt-proxy 服務異常停止" "DNS 加密服務或防火牆保護異常，正在嘗試自動恢復"
    notify_count=$((notify_count + 1))
  fi

  sh "$MODDIR/scripts/dnscrypt-control.sh" start >/dev/null 2>&1
  _restart_status=$?
  if [ "$_restart_status" -eq 2 ]; then
    # A concurrent user/control operation held the lock; retry on the next
    # interval instead of treating contention as a permanent failed recovery.
    restart_pending=1
    continue
  fi

  _restart_healthy=0
  if [ "$_restart_status" -eq 0 ] \
    && sh "$MODDIR/scripts/dnscrypt-control.sh" health >/dev/null 2>&1; then
    _restart_healthy=1
  fi
  if [ "$_restart_healthy" -eq 1 ] && [ "$notify_count" -lt 3 ]; then
    notify_user "dnscrypt-proxy 服務已自動恢復" "DNS 加密服務與防火牆保護已恢復運作"
    notify_count=$((notify_count + 1))
  fi
  # Any failed or immediately unhealthy restart is retryable on the next
  # interval. The notification counter remains capped independently.
  if [ "$_restart_healthy" -ne 1 ]; then
    restart_pending=1
  fi
done

exit 0
