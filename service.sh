#!/system/bin/sh
set -u

MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"

# A persisted uninstall marker or manager disable/remove marker is authoritative.
# Do not revive the service merely because a stale boot-service invocation ran.
shutdown_requested && exit 0

# Wait for Android userspace and the settings/network services to become usable.
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 120 ]; do
  sleep 2
  i=$((i + 1))
done

start_watchdog() {
  shutdown_requested && return 1
  _existing_watchdog=$(watchdog_pid 2>/dev/null || true)
  [ -z "$_existing_watchdog" ] || return 0
  rm -f "$WATCHDOG_PID_FILE"

  _watchdog_lock="$RUN_DIR/watchdog-start.lock"
  exec 7>> "$_watchdog_lock" || return 1
  flock_fd_nonblocking 7
  _watchdog_lock_status=$?
  case "$_watchdog_lock_status" in
    0) ;;
    1) exec 7>&-; return 0 ;;
    *) exec 7>&-; return 1 ;;
  esac

  _existing_watchdog=$(watchdog_pid 2>/dev/null || true)
  if [ -n "$_existing_watchdog" ]; then
    exec 7>&-
    return 0
  fi
  if shutdown_requested; then
    exec 7>&-
    return 1
  fi
  sh "$WATCHDOG_SCRIPT" 7>&- >> "$SERVICE_LOG" 2>&1 &
  _watchdog_pid=$!
  _watchdog_tmp="$WATCHDOG_PID_FILE.$$.tmp"
  printf '%s\n' "$_watchdog_pid" > "$_watchdog_tmp" \
    && chmod 0600 "$_watchdog_tmp" 2>/dev/null \
    && mv -f "$_watchdog_tmp" "$WATCHDOG_PID_FILE" || {
      kill "$_watchdog_pid" >/dev/null 2>&1 || true
      rm -f "$_watchdog_tmp"
      exec 7>&-
      return 1
    }
  exec 7>&-
  return 0
}

# start_service saves/disables Android Private DNS, waits for a real encrypted
# resolution, and installs firewall rules only after the proxy is ready.
if ! sh "$MODDIR/scripts/dnscrypt-control.sh" start >/dev/null 2>&1; then
  log_msg "$SERVICE_LOG" "Boot-time dnscrypt-proxy start failed."
fi
if ! shutdown_requested; then
  start_watchdog || log_msg "$SERVICE_LOG" "Failed to launch the service watchdog."
fi

# Check the upstream binary only after the initial start. This avoids racing
# ensure_binary during first installation; a successful updater restarts the
# already-running daemon transactionally.
if ! shutdown_requested; then
  (
    sh "$MODDIR/scripts/dnscrypt-control.sh" auto-update >/dev/null 2>&1 || true
  ) 7>&- &
fi
