#!/system/bin/sh
MODDIR=${0%/*}

# In module managers without WebUI, the action button toggles the service.
if sh "$MODDIR/scripts/dnscrypt-control.sh" status 2>/dev/null | grep -q '"running":true'; then
  sh "$MODDIR/scripts/dnscrypt-control.sh" stop
else
  sh "$MODDIR/scripts/dnscrypt-control.sh" start
fi
