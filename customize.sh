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
OLD_MODULE_TRUSTED=0
if [ -d "$OLD_MODPATH" ] && [ ! -L "$OLD_MODPATH" ] && [ "$OLD_MODPATH" != "$MODPATH" ]; then
  OLD_MODULE_META=$(stat -c '%u:%g:%a' "$OLD_MODPATH" 2>/dev/null || true)
  [ "$OLD_MODULE_META" = "0:0:755" ] && OLD_MODULE_TRUSTED=1
fi
if [ "$OLD_MODULE_TRUSTED" -eq 1 ]; then
  ui_print "* Migrating settings from the installed module"
  # Releases v0.6.0 through v0.8.0 installed three direct IPv6 REJECT rules.
  # Only a trusted, root-owned module.prop from one of those known releases can
  # establish why matching rules require a reboot. The module never deletes
  # these otherwise indistinguishable rules in place; the boot-bound marker
  # becomes harmless after netfilter state is reset by the required reboot.
  OLD_PROP_META=$(stat -c '%u:%g:%a' "$OLD_MODPATH/module.prop" 2>/dev/null || true)
  if [ -f "$OLD_MODPATH/module.prop" ] && [ ! -L "$OLD_MODPATH/module.prop" ] \
    && [ "$OLD_PROP_META" = "0:0:644" ]; then
    OLD_MODULE_VERSION=$(sed -n 's/^version=//p' "$OLD_MODPATH/module.prop" 2>/dev/null | head -n 1)
    case "$OLD_MODULE_VERSION" in
      v0.6.0|v0.7.0|v0.8.0)
        if command -v ip6tables >/dev/null 2>&1 \
          && ip6tables -t filter -C OUTPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
          && ip6tables -t filter -C OUTPUT -p tcp --dport 53 -j REJECT >/dev/null 2>&1 \
          && ip6tables -t filter -C INPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1; then
          LEGACY_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
          case "$LEGACY_BOOT_ID" in
            ""|*[!A-Za-z0-9-]*) ;;
            *)
              printf '%s\n' "$LEGACY_BOOT_ID" > "$MODPATH/state/legacy-ipv6-reboot.state" \
                || abort "! Failed to record the legacy IPv6 reboot requirement"
              ui_print "! Legacy IPv6 DNS rules detected; reboot is required to clear them safely"
              ;;
          esac
        fi
        ;;
    esac
    case "$OLD_MODULE_VERSION" in
      v0.9.0)
        LEGACY_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        case "$LEGACY_BOOT_ID" in
          ""|*[!A-Za-z0-9-]*) ;;
          *)
            printf '%s\n' "$LEGACY_BOOT_ID" > "$MODPATH/state/legacy-firewall-adopt.state" \
              || abort "! Failed to authorize legacy firewall-chain adoption"
            ui_print "* Authorized exact v0.9.0 firewall chains for one-time migration"
            ;;
        esac
        ;;
    esac
  fi
  OLD_CONFIG_META=$(stat -c '%u:%g:%a' "$OLD_MODPATH/config" 2>/dev/null || true)
  if [ -d "$OLD_MODPATH/config" ] && [ ! -L "$OLD_MODPATH/config" ] \
    && [ "$OLD_CONFIG_META" = "0:0:700" ]; then
    for MIGRATION_FILE in \
      "$OLD_MODPATH/config/dnscrypt-proxy.toml" \
      "$OLD_MODPATH/config/allowed-names.txt" \
      "$OLD_MODPATH/config/blocked-names.txt" \
      "$OLD_MODPATH/config/allowed-ips.txt" \
      "$OLD_MODPATH/config/blocked-ips.txt" \
      "$OLD_MODPATH/config/subscriptions.json"
    do
      [ -f "$MIGRATION_FILE" ] || continue
      MIGRATION_META=$(stat -c '%u:%g:%a' "$MIGRATION_FILE" 2>/dev/null || true)
      if [ -L "$MIGRATION_FILE" ] || [ "$MIGRATION_META" != "0:0:600" ]; then
        ui_print "! Ignoring untrusted migration input: ${MIGRATION_FILE##*/}"
        continue
      fi
      cp -f "$MIGRATION_FILE" "$MODPATH/config/" \
        || abort "! Failed to migrate module configuration"
    done
  else
    # v0.9.0 intentionally made the entire config directory writable by UID
    # 3003. Its TOML can therefore select root-opened log/TLS-key paths before
    # dnscrypt-proxy drops privileges. Do not read or copy those inputs during
    # an upgrade; install the audited defaults and let the operator re-enter
    # desired settings after boot.
    ui_print "! Previous configuration is not eligible under v0.9.1's exact hardened migration policy"
    ui_print "! Audited defaults will be installed; re-apply custom settings after reboot"
  fi
  OLD_STATE_META=$(stat -c '%u:%g:%a' "$OLD_MODPATH/state" 2>/dev/null || true)
  if [ -d "$OLD_MODPATH/state" ] && [ ! -L "$OLD_MODPATH/state" ] \
    && [ "$OLD_STATE_META" = "0:0:700" ]; then
    for MIGRATION_STATE in private-dns.state dns-mode.state; do
      MIGRATION_FILE="$OLD_MODPATH/state/$MIGRATION_STATE"
      [ -f "$MIGRATION_FILE" ] || continue
      MIGRATION_META=$(stat -c '%u:%g:%a' "$MIGRATION_FILE" 2>/dev/null || true)
      if [ -L "$MIGRATION_FILE" ] || [ "$MIGRATION_META" != "0:0:600" ]; then
        ui_print "! Ignoring untrusted migration state: $MIGRATION_STATE"
        continue
      fi
      cp -f "$MIGRATION_FILE" "$MODPATH/state/$MIGRATION_STATE" \
        || abort "! Failed to migrate trusted module state"
    done
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

# Keep root-only service state, updater scratch data, and control logs private.
# At first boot, audited templates and any successfully verified binary are
# copied into a separately marked, root-owned runtime tree below /data/local.
set_perm_recursive "$MODPATH/state" 0 0 0700 0600
set_perm_recursive "$MODPATH/run" 0 0 0700 0600
set_perm_recursive "$MODPATH/logs" 0 0 0700 0600
set_perm_recursive "$MODPATH/tmp" 0 0 0700 0600

# AID_INET is a shared Android networking group, not a module-private reader.
# Keep staged templates root-only below /data/adb. First boot creates a
# UID-3003-readable but non-writable configuration directory and a separate
# UID-3003-owned 0700 data directory for mutable source caches/query logs.
set_perm_recursive "$MODPATH/config" 0 0 0700 0600
set_perm "$MODPATH/config" 0 0 0700
for CONTROL_FILE in \
  "$MODPATH/config/dnscrypt-proxy.toml" \
  "$MODPATH/config/allowed-names.txt" \
  "$MODPATH/config/blocked-names.txt" \
  "$MODPATH/config/allowed-ips.txt" \
  "$MODPATH/config/blocked-ips.txt" \
  "$MODPATH/config/subscriptions.json"
do
  [ -f "$CONTROL_FILE" ] && [ ! -L "$CONTROL_FILE" ] || continue
  set_perm "$CONTROL_FILE" 0 0 0600
done

# Enforce the dedicated numeric runtime user in both fresh and migrated TOML.
# This control action does not require the dnscrypt-proxy binary.
if ! DNSCRYPT_RUNTIME_ROOT="$MODPATH" DNSCRYPT_INSTALLER_STAGE=1 \
    sh "$MODPATH/scripts/dnscrypt-control.sh" get-config >/dev/null 2>&1; then
  abort "! Failed to prepare dnscrypt-proxy configuration"
fi

for CONTROL_FILE in \
  "$MODPATH/config/dnscrypt-proxy.toml" \
  "$MODPATH/config/allowed-names.txt" \
  "$MODPATH/config/blocked-names.txt" \
  "$MODPATH/config/allowed-ips.txt" \
  "$MODPATH/config/blocked-ips.txt" \
  "$MODPATH/config/subscriptions.json"
do
  [ -f "$CONTROL_FILE" ] && [ ! -L "$CONTROL_FILE" ] || continue
  set_perm "$CONTROL_FILE" 0 0 0600
done

ui_print "* DNS integration defaults to strict; upstream_only can be selected after boot"

ui_print "* Downloading and verifying the latest dnscrypt-proxy binary"
# The staged module lives below /data/adb, whose 0700 ancestor cannot be
# traversed after switching to UID3003. Verify the official asset digest and
# reported version here, install it into the staged template, and defer the
# unprivileged source/config check to first boot after the protected /data/local
# runtime tree exists.
if DNSCRYPT_RUNTIME_ROOT="$MODPATH" DNSCRYPT_INSTALLER_STAGE=1 \
    DNSCRYPT_INSTALLER_DOWNLOAD_ONLY=1 \
    sh "$MODPATH/scripts/update-dnscrypt.sh" install >/dev/null 2>&1; then
  ui_print "* dnscrypt-proxy binary installed"
else
  ui_print "! Automatic binary download failed"
  ui_print "! You can retry after boot from KernelSU/APatch WebUI or action button"
fi

ui_print " "
ui_print "Installation finished. Reboot is required before using this module."
