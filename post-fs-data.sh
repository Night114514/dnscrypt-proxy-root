#!/system/bin/sh
MODDIR=${0%/*}

# Apply DNS redirection as early as possible. Failures are non-fatal because some
# ROMs initialize iptables later; service.sh will try again after boot service starts.
sh "$MODDIR/scripts/dnscrypt-control.sh" apply-iptables >/dev/null 2>&1 || true
