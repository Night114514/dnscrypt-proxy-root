ui_print " "
ui_print "***************************************"
ui_print "* DNSCrypt Proxy Root WebUI Module    *"
ui_print "* Magisk / KernelSU / APatch          *"
ui_print "***************************************"
ui_print " "

ui_print "* Preparing directories"
mkdir -p "$MODPATH/bin" "$MODPATH/config" "$MODPATH/state" "$MODPATH/run" "$MODPATH/logs" "$MODPATH/tmp"

# KernelSU/APatch stage an update in a fresh module directory and replace the
# live one at reboot. Migrate only active inputs managed by this module/WebUI.
# Broad extension globs can accidentally preserve a downloaded
# cache or attacker-created file from the proxy-writable config directory.
OLD_MODPATH="/data/adb/modules/dnscrypt-proxy-root"
if [ -d "$OLD_MODPATH" ] && [ "$OLD_MODPATH" != "$MODPATH" ]; then
  ui_print "* Migrating settings from the installed module"
  if [ -d "$OLD_MODPATH/config" ]; then
    for MIGRATION_FILE in \
      "$OLD_MODPATH/config/dnscrypt-proxy.toml" \
      "$OLD_MODPATH/config/allowed-names.txt" \
      "$OLD_MODPATH/config/blocked-names.txt" \
      "$OLD_MODPATH/config/allowed-ips.txt" \
      "$OLD_MODPATH/config/blocked-ips.txt" \
      "$OLD_MODPATH/config/subscriptions.json"
    do
      [ -f "$MIGRATION_FILE" ] || continue
      if [ -L "$MIGRATION_FILE" ]; then
        ui_print "! Ignoring symlinked migration input: ${MIGRATION_FILE##*/}"
        continue
      fi
      cp -f "$MIGRATION_FILE" "$MODPATH/config/" \
        || abort "! Failed to migrate module configuration"
    done
  fi
  if [ -f "$OLD_MODPATH/state/private-dns.state" ] \
    && [ ! -L "$OLD_MODPATH/state/private-dns.state" ]; then
    cp -f "$OLD_MODPATH/state/private-dns.state" "$MODPATH/state/private-dns.state" \
      || abort "! Failed to migrate Android Private DNS state"
  elif [ -f "$OLD_MODPATH/config/private-dns.state" ] \
    && [ ! -L "$OLD_MODPATH/config/private-dns.state" ]; then
    cp -f "$OLD_MODPATH/config/private-dns.state" "$MODPATH/state/private-dns.state" \
      || abort "! Failed to migrate Android Private DNS state"
  fi
fi

ui_print "* Setting permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

# Enforce the dedicated numeric runtime user in both fresh and migrated TOML.
# This control action does not require the dnscrypt-proxy binary.
if ! sh "$MODPATH/scripts/dnscrypt-control.sh" get-config >/dev/null 2>&1; then
  abort "! Failed to prepare dnscrypt-proxy configuration"
fi

# Android AID_INET (UID/GID 3003) owns the config working directory so the proxy
# can create resolver caches and logs after dropping privileges. Root control
# actions can still atomically replace files.
set_perm_recursive "$MODPATH/config" 3003 3003 0750 0640
set_perm_recursive "$MODPATH/state" 0 0 0700 0600

ui_print "* Android Private DNS will be saved and temporarily disabled while the service runs"

ui_print "* Downloading latest dnscrypt-proxy binary for this architecture"
if sh "$MODPATH/scripts/update-dnscrypt.sh" install >/dev/null 2>&1; then
  ui_print "* dnscrypt-proxy binary installed"
else
  ui_print "! Automatic binary download failed"
  ui_print "! You can retry after boot from KernelSU/APatch WebUI or action button"
fi

ui_print " "
ui_print "Installation finished. Reboot is recommended."
