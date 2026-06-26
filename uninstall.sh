#!/system/bin/sh
MODDIR=${0%/*}

sh "$MODDIR/scripts/dnscrypt-control.sh" stop >/dev/null 2>&1 || true
rm -rf "$MODDIR/tmp" "$MODDIR/run"

# Proactively wipe DNS query logs (privacy-sensitive) in case the manager leaves
# the module directory or config dir behind after uninstall.
rm -f "$MODDIR/config/query.log" "$MODDIR/config/nx.log" \
      "$MODDIR/config/dnscrypt-proxy.log" \
      "$MODDIR/logs/query.log" "$MODDIR/logs/nx.log" 2>/dev/null || true

# Intentionally keep logs/config until module directory is removed by the manager.
# Module managers remove $MODDIR after uninstall; this script only ensures runtime cleanup.
