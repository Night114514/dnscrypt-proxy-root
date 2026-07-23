#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"

# Wait for Android userspace and network stack to become usable.
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 120 ]; do
  sleep 2
  i=$((i + 1))
done

# Check upstream binary in the background. The check is rate-limited by the update script.
(
  sh "$MODDIR/scripts/dnscrypt-control.sh" auto-update >/dev/null 2>&1 || true
) &

# Disable Android Private DNS now that the framework is ready; running this during
# installation (customize.sh) is unreliable because settings/framework is not up yet.
settings put global private_dns_mode off >/dev/null 2>&1 || true

# Start service and re-apply DNS redirection.
sh "$MODDIR/scripts/dnscrypt-control.sh" start >/dev/null 2>&1 || true

# Background watchdog: if dnscrypt-proxy dies unexpectedly (not a user-initiated
# stop), notify and try to bring it back once per outage. Notifications are capped
# per boot so a crash loop cannot spam the status bar. Runs detached so it never
# blocks service.sh from completing.
(
  notify_count=0
  restart_pending=1
  while true; do
    sleep 60
    if is_dnscrypt_running; then
      # Service healthy again; re-arm the single restart attempt for the next outage.
      restart_pending=1
      continue
    fi
    # A missing PID plus the user_stopped marker means the user stopped it on purpose.
    [ -f "$USER_STOPPED_FILE" ] && continue
    [ "$notify_count" -ge 3 ] && continue

    notify_user "dnscrypt-proxy 服務異常停止" "DNS 加密服務已停止運作，請開啟 WebUI 檢查"
    notify_count=$((notify_count + 1))

    if [ "$restart_pending" -eq 1 ]; then
      restart_pending=0
      sh "$MODDIR/scripts/dnscrypt-control.sh" start >/dev/null 2>&1 || true
      sleep 5
      if is_dnscrypt_running && [ "$notify_count" -lt 3 ]; then
        notify_user "dnscrypt-proxy 服務已自動恢復" "DNS 加密服務已自動重啟並恢復運作"
        notify_count=$((notify_count + 1))
      fi
    fi
  done
) &
