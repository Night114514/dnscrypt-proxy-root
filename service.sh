#!/system/bin/sh
MODDIR=${0%/*}

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

# Start service and re-apply DNS redirection.
sh "$MODDIR/scripts/dnscrypt-control.sh" start >/dev/null 2>&1 || true
