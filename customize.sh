ui_print " "
ui_print "***************************************"
ui_print "* DNSCrypt Proxy Root WebUI Module    *"
ui_print "* Magisk / KernelSU / APatch          *"
ui_print "***************************************"
ui_print " "

ui_print "* Preparing directories"
mkdir -p "$MODPATH/bin" "$MODPATH/config" "$MODPATH/run" "$MODPATH/logs" "$MODPATH/tmp"

ui_print "* Setting permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

if [ -f "$MODPATH/config/dnscrypt-proxy.toml" ]; then
  set_perm "$MODPATH/config/dnscrypt-proxy.toml" 0 0 0644
fi

ui_print "* Disabling Android Private DNS to avoid conflicts"
settings put global private_dns_mode off >/dev/null 2>&1 || true

ui_print "* Downloading latest dnscrypt-proxy binary for this architecture"
if sh "$MODPATH/scripts/update-dnscrypt.sh" install >/dev/null 2>&1; then
  ui_print "* dnscrypt-proxy binary installed"
else
  ui_print "! Automatic binary download failed"
  ui_print "! You can retry after boot from KernelSU/APatch WebUI or action button"
fi

ui_print " "
ui_print "Installation finished. Reboot is recommended."
