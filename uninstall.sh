#!/system/bin/sh
MODDIR=${0%/*}

sh "$MODDIR/scripts/dnscrypt-control.sh" stop >/dev/null 2>&1 || true
rm -rf "$MODDIR/tmp" "$MODDIR/run"

# Intentionally keep logs/config until module directory is removed by the manager.
# Module managers remove $MODDIR after uninstall; this script only ensures runtime cleanup.
