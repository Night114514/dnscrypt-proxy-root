#!/system/bin/sh
set -u

SCRIPT_DIR=${0%/*}
MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
. "$MODDIR/scripts/common.sh"

ACTION="${1:-status}"

# Millisecond timestamp. toybox's date lacks %N and echoes the literal "%N",
# so fall back to second precision when nanoseconds are unavailable.
_now_ms() {
  _ts=$(date +%s%N 2>/dev/null)
  case "$_ts" in
    *[!0-9]*|"") echo "$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))" ;;
    *) echo "$(( _ts / 1000000 ))" ;;
  esac
}

shell_quote_json() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' | tr '\n' ' '
}

# Keep only the 5 most recent config backups so they cannot grow unbounded.
prune_config_backups() {
  # Both glob families must be passed to a single ls invocation. Iterating over
  # an expanded glob first would sort one file at a time and never prune any.
  ls -1t "$CONFIG_FILE".*.bak "$CONFIG_FILE".bak.* 2>/dev/null \
    | tail -n +6 \
    | while IFS= read -r _old; do
        [ -n "$_old" ] && rm -f "$_old"
      done
}

secure_config_temp_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null
}

secure_config_temp_valid() {
  _secure_path="$1"
  _secure_identity="$2"
  _secure_mode="$3"
  config_dir_is_trusted || return 1
  [ -f "$_secure_path" ] && [ ! -L "$_secure_path" ] || return 1
  _trusted_uid=$(config_control_uid) || return 1
  case "$_secure_mode" in
    600) _secure_expected_identity="$_trusted_uid:0:600" ;;
    400) _secure_expected_identity="$DNSCRYPT_UID:0:400" ;;
    *) return 1 ;;
  esac
  [ "$(stat -c '%u:%g:%a' "$_secure_path" 2>/dev/null)" = \
    "$_secure_expected_identity" ] || return 1
  [ "$(secure_config_temp_identity "$_secure_path")" = "$_secure_identity" ] || return 1
}

create_secure_config_temp() {
  _secure_prefix="$1"
  case "$_secure_prefix" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  config_dir_is_trusted || return 1
  if has_cmd mktemp; then
    _secure_created=$(mktemp "$CONFIG_DIR/$_secure_prefix.XXXXXX" 2>/dev/null) || return 1
  else
    _secure_created=$(busybox_cmd mktemp "$CONFIG_DIR/$_secure_prefix.XXXXXX" 2>/dev/null) \
      || return 1
  fi
  case "$_secure_created" in "$CONFIG_DIR/$_secure_prefix."*) ;;
    *) return 1 ;;
  esac
  if [ ! -f "$_secure_created" ] || [ -L "$_secure_created" ]; then
    rm -f "$_secure_created"
    return 1
  fi
  _secure_created_identity=$(secure_config_temp_identity "$_secure_created" 2>/dev/null) || {
    rm -f "$_secure_created"
    return 1
  }
  if ! secure_config_temp_valid "$_secure_created" "$_secure_created_identity" 600; then
    rm -f "$_secure_created"
    return 1
  fi
  printf '%s\n' "$_secure_created"
}

prepare_secure_config_temp_for_proxy() {
  _secure_path="$1"
  _secure_identity="$2"
  secure_config_temp_valid "$_secure_path" "$_secure_identity" 600 || return 1
  _proxy_config_mode=$(managed_config_mode) || return 1
  if [ "$_proxy_config_mode" = 400 ]; then
    chown "$DNSCRYPT_UID:0" "$_secure_path" 2>/dev/null || return 1
    chmod 0400 "$_secure_path" 2>/dev/null || return 1
  fi
  secure_config_temp_valid "$_secure_path" "$_secure_identity" "$_proxy_config_mode"
}

prepare_managed_input_for_proxy() {
  _managed_input="$1"
  config_dir_is_trusted || return 1
  [ -f "$_managed_input" ] && [ ! -L "$_managed_input" ] || return 1
  _trusted_uid=$(config_control_uid) || return 1
  [ "$(stat -c %u "$_managed_input" 2>/dev/null)" = "$_trusted_uid" ] || return 1
  _proxy_config_mode=$(managed_config_mode) || return 1
  if [ "$_proxy_config_mode" = 400 ]; then
    chown "$DNSCRYPT_UID:0" "$_managed_input" 2>/dev/null || return 1
    chmod 0400 "$_managed_input" 2>/dev/null || return 1
  else
    chown "$_trusted_uid:0" "$_managed_input" 2>/dev/null || return 1
    chmod 0600 "$_managed_input" 2>/dev/null || return 1
  fi
  _managed_expected_identity=$(managed_config_expected_identity) || return 1
  [ "$(stat -c '%u:%g:%a' "$_managed_input" 2>/dev/null)" = \
    "$_managed_expected_identity" ]
}

prepare_control_only_input() {
  _control_input="$1"
  config_dir_is_trusted || return 1
  [ -f "$_control_input" ] && [ ! -L "$_control_input" ] || return 1
  _trusted_uid=$(config_control_uid) || return 1
  chown "$_trusted_uid:0" "$_control_input" 2>/dev/null || return 1
  chmod 0600 "$_control_input" 2>/dev/null || return 1
  control_only_config_input_is_trusted "$_control_input"
}

manager_name() {
  if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ]; then
    echo "APatch"
  elif [ "${KSU:-}" = "true" ] || [ -d /data/adb/ksu ]; then
    echo "KernelSU"
  elif [ -d /data/adb/magisk ]; then
    echo "Magisk"
  else
    echo "Unknown"
  fi
}

ensure_binary() {
  _ensured_binary_version=$(binary_version_bounded "$DNSCRYPT_BIN" 2>/dev/null || true)
  if ! runtime_binary_at_is_trusted "$DNSCRYPT_BIN" \
    || [ -z "$_ensured_binary_version" ]; then
    # start_service already owns the control lock. Pass that exact inherited
    # descriptor into the updater so its short commit phase cannot deadlock on
    # the parent shell while recovering a binary missing after installation.
    DNSCRYPT_CONTROL_LOCK_HELD=1 \
      sh "$MODDIR/scripts/update-dnscrypt.sh" install >> "$UPDATE_LOG" 2>&1 || return 1
  fi
  runtime_binary_at_is_trusted "$DNSCRYPT_BIN" \
    && binary_version_bounded "$DNSCRYPT_BIN" >/dev/null 2>&1
}

enforce_dnscrypt_user() {
  _user_config="$1"
  if [ "$(grep -c "^[[:space:]]*user_name[[:space:]]*=[[:space:]]*['\"]${DNSCRYPT_UID}['\"][[:space:]]*$" \
      "$_user_config" 2>/dev/null || echo 0)" = "1" ] \
      && [ "$(grep -c '^[[:space:]]*user_name[[:space:]]*=' "$_user_config" 2>/dev/null || echo 0)" = "1" ]; then
    return 0
  fi
  if [ "$_user_config" = "$CONFIG_FILE" ]; then
    config_file_is_trusted || return 1
    _user_tmp=$(create_secure_config_temp '.dnscrypt-proxy.toml.user') || return 1
    _user_tmp_identity=$(secure_config_temp_identity "$_user_tmp") || {
      rm -f "$_user_tmp"
      return 1
    }
    if ! awk -v line="user_name = '$DNSCRYPT_UID'" '
        BEGIN { print line }
        $0 !~ /^[[:space:]]*user_name[[:space:]]*=/ { print }
      ' "$_user_config" > "$_user_tmp" \
      || ! secure_config_temp_valid "$_user_tmp" "$_user_tmp_identity" 600 \
      || ! prepare_secure_config_temp_for_proxy "$_user_tmp" "$_user_tmp_identity" \
      || ! secure_config_temp_valid "$_user_tmp" "$_user_tmp_identity" "$(managed_config_mode)" \
      || ! mv -f "$_user_tmp" "$_user_config"; then
      rm -f "$_user_tmp"
      return 1
    fi
    return 0
  fi
  _user_tmp="${_user_config}.user.$$"
  awk -v line="user_name = '$DNSCRYPT_UID'" '
    BEGIN { print line }
    $0 !~ /^[[:space:]]*user_name[[:space:]]*=/ { print }
  ' "$_user_config" > "$_user_tmp" && mv -f "$_user_tmp" "$_user_config"
  _user_status=$?
  rm -f "$_user_tmp"
  return "$_user_status"
}

ensure_config() {
  ensure_runtime_tree || return 1
  if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    config_file_is_trusted || return 1
  else
    config_dir_is_trusted || return 1
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    _ensure_config_tmp=$(create_secure_config_temp '.dnscrypt-proxy.toml.default') || return 1
    _ensure_config_identity=$(secure_config_temp_identity "$_ensure_config_tmp") || {
      rm -f "$_ensure_config_tmp"
      return 1
    }
    cat > "$_ensure_config_tmp" <<'EOF'
listen_addresses = ['127.0.0.1:5354']
user_name = '3003'
server_names = ['cloudflare', 'quad9-dnscrypt-ip4-filter-pri']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
odoh_servers = false
require_dnssec = true
require_nolog = true
require_nofilter = false
force_tcp = false
timeout = 5000
keepalive = 30
cert_refresh_delay = 240
bootstrap_resolvers = ['9.9.9.9:53', '149.112.112.112:53', '1.1.1.1:53']
ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '9.9.9.9:53'
log_level = 2
use_syslog = false

[query_log]
  file = '../data/query.log'
  format = 'tsv'

[nx_log]
  file = '../data/nx.log'
  format = 'tsv'

[blocked_names]
  blocked_names_file = 'blocked-names.txt'

[allowed_names]
  allowed_names_file = 'allowed-names.txt'

[blocked_ips]
  blocked_ips_file = 'blocked-ips.txt'

[allowed_ips]
  allowed_ips_file = 'allowed-ips.txt'

[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '../data/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

  [sources.'relays']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/relays.md', 'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/relays.md']
  cache_file = '../data/relays.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

  [sources.'odoh-servers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-servers.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-servers.md']
  cache_file = '../data/odoh-servers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

  [sources.'odoh-relays']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-relays.md']
  cache_file = '../data/odoh-relays.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

[static]
EOF
    if ! secure_config_temp_valid "$_ensure_config_tmp" "$_ensure_config_identity" 600 \
      || ! prepare_secure_config_temp_for_proxy "$_ensure_config_tmp" "$_ensure_config_identity" \
      || ! secure_config_temp_valid "$_ensure_config_tmp" "$_ensure_config_identity" "$(managed_config_mode)" \
      || ! mv -f "$_ensure_config_tmp" "$CONFIG_FILE"; then
      rm -f "$_ensure_config_tmp"
      return 1
    fi
  fi
  enforce_dnscrypt_user "$CONFIG_FILE" || return 1
  config_file_is_trusted || return 1
  config_root_open_paths_are_safe "$CONFIG_FILE" || return 1
  config_runtime_user_is_safe "$CONFIG_FILE" || return 1
  for f in allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt; do
    _managed_list="$CONFIG_DIR/$f"
    if [ -e "$_managed_list" ] || [ -L "$_managed_list" ]; then
      managed_config_input_is_trusted "$_managed_list" || return 1
      continue
    fi
    _managed_list_tmp=$(create_secure_config_temp '.dnscrypt-managed-list') || return 1
    _managed_list_identity=$(secure_config_temp_identity "$_managed_list_tmp") || {
      rm -f "$_managed_list_tmp"
      return 1
    }
    if ! prepare_secure_config_temp_for_proxy "$_managed_list_tmp" "$_managed_list_identity" \
      || ! mv -f "$_managed_list_tmp" "$_managed_list"; then
      rm -f "$_managed_list_tmp"
      return 1
    fi
  done
  _managed_subscriptions="$CONFIG_DIR/subscriptions.json"
  if [ -e "$_managed_subscriptions" ] || [ -L "$_managed_subscriptions" ]; then
    control_only_config_input_is_trusted "$_managed_subscriptions" || return 1
  fi
  runtime_config_inputs_are_trusted
}

save_route_localnet_state() {
  _route_state_file="$RUN_DIR/route-localnet.state"
  _route_boot_id=$(cat "$PROC_SYS_ROOT/kernel/random/boot_id" 2>/dev/null || true)
  [ -n "$_route_boot_id" ] || return 1
  case "$(cat "$_route_state_file" 2>/dev/null || true)" in
    "$_route_boot_id":0|"$_route_boot_id":1) return 0 ;;
  esac
  _route_original=$(cat "$PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet" 2>/dev/null || true)
  case "$_route_original" in
    0|1) ;;
    *) return 1 ;;
  esac
  _route_tmp="$_route_state_file.$$.tmp"
  printf '%s:%s\n' "$_route_boot_id" "$_route_original" > "$_route_tmp" || {
    rm -f "$_route_tmp"
    return 1
  }
  chmod 0600 "$_route_tmp" 2>/dev/null || true
  mv -f "$_route_tmp" "$_route_state_file" || {
    rm -f "$_route_tmp"
    return 1
  }
}

restore_route_localnet_state() {
  _route_state_file="$RUN_DIR/route-localnet.state"
  [ -f "$_route_state_file" ] || return 0
  _route_boot_id=$(cat "$PROC_SYS_ROOT/kernel/random/boot_id" 2>/dev/null || true)
  [ -n "$_route_boot_id" ] || return 1
  _route_state=$(cat "$_route_state_file" 2>/dev/null || true)
  case "$_route_state" in
    "$_route_boot_id":0) _route_restore=0 ;;
    "$_route_boot_id":1) _route_restore=1 ;;
    *) rm -f "$_route_state_file"; return 0 ;;
  esac
  sysctl -w "net.ipv4.conf.all.route_localnet=$_route_restore" 2>/dev/null \
    || echo "$_route_restore" > "$PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet" 2>/dev/null \
    || return 1
  rm -f "$_route_state_file"
}

boot_marker_state() {
  _boot_marker_file="$1"
  if [ ! -e "$_boot_marker_file" ] && [ ! -L "$_boot_marker_file" ]; then
    printf '%s\n' absent
    return 0
  fi
  [ -f "$_boot_marker_file" ] && [ ! -L "$_boot_marker_file" ] || {
    printf '%s\n' invalid
    return 0
  }
  [ "$(wc -l < "$_boot_marker_file" 2>/dev/null | tr -d ' ')" = 1 ] || {
    printf '%s\n' invalid
    return 0
  }
  _boot_marker_value=$(sed -n '1p' "$_boot_marker_file" 2>/dev/null)
  case "$_boot_marker_value" in ""|*[!A-Za-z0-9-]*) printf '%s\n' invalid; return 0 ;; esac
  _boot_marker_bytes=$(wc -c < "$_boot_marker_file" 2>/dev/null | tr -d ' ')
  [ "$_boot_marker_bytes" = "$((${#_boot_marker_value} + 1))" ] || {
    printf '%s\n' invalid
    return 0
  }
  _boot_marker_current=$(cat "$PROC_SYS_ROOT/kernel/random/boot_id" 2>/dev/null || true)
  [ -n "$_boot_marker_current" ] || {
    printf '%s\n' invalid
    return 0
  }
  if [ "$_boot_marker_value" = "$_boot_marker_current" ]; then
    printf '%s\n' valid
  else
    # Netfilter state is per-boot. A well-formed marker for an older boot no
    # longer proves ownership of any same-named chain in the current kernel.
    rm -f "$_boot_marker_file" 2>/dev/null || {
      printf '%s\n' invalid
      return 0
    }
    printf '%s\n' absent
  fi
}

write_boot_marker() {
  _boot_marker_target="$1"
  _boot_marker_current=$(cat "$PROC_SYS_ROOT/kernel/random/boot_id" 2>/dev/null || true)
  case "$_boot_marker_current" in ""|*[!A-Za-z0-9-]*) return 1 ;; esac
  _boot_marker_tmp="$_boot_marker_target.$$.tmp"
  printf '%s\n' "$_boot_marker_current" > "$_boot_marker_tmp" || {
    rm -f "$_boot_marker_tmp"
    return 1
  }
  chmod 0600 "$_boot_marker_tmp" 2>/dev/null || {
    rm -f "$_boot_marker_tmp"
    return 1
  }
  chown 0:0 "$_boot_marker_tmp" 2>/dev/null || true
  mv -f "$_boot_marker_tmp" "$_boot_marker_target" || {
    rm -f "$_boot_marker_tmp"
    return 1
  }
}

# The firewall marker binds this boot to a random token that is also embedded in
# both managed chains.  A boot ID alone is insufficient: an external firewall
# can delete a chain and later create an unrelated chain with the same name.
firewall_marker_state() {
  if [ ! -e "$FIREWALL_OWNERSHIP_FILE" ] && [ ! -L "$FIREWALL_OWNERSHIP_FILE" ]; then
    printf '%s\n' absent
    return 0
  fi
  [ -f "$FIREWALL_OWNERSHIP_FILE" ] && [ ! -L "$FIREWALL_OWNERSHIP_FILE" ] || {
    printf '%s\n' invalid
    return 0
  }
  [ "$(wc -l < "$FIREWALL_OWNERSHIP_FILE" 2>/dev/null | tr -d ' ')" = 1 ] || {
    printf '%s\n' invalid
    return 0
  }
  _firewall_marker_value=$(sed -n '1p' "$FIREWALL_OWNERSHIP_FILE" 2>/dev/null)
  _firewall_marker_boot=${_firewall_marker_value%%:*}
  _firewall_marker_token=${_firewall_marker_value#*:}
  case "$_firewall_marker_boot" in ""|*[!A-Za-z0-9-]*) printf '%s\n' invalid; return 0 ;; esac
  case "$_firewall_marker_token" in
    *[!A-Za-z0-9]*) printf '%s\n' invalid; return 0 ;;
    ??????) ;;
    *) printf '%s\n' invalid; return 0 ;;
  esac
  [ "$_firewall_marker_value" = "$_firewall_marker_boot:$_firewall_marker_token" ] || {
    printf '%s\n' invalid
    return 0
  }
  _firewall_marker_bytes=$(wc -c < "$FIREWALL_OWNERSHIP_FILE" 2>/dev/null | tr -d ' ')
  [ "$_firewall_marker_bytes" = "$((${#_firewall_marker_value} + 1))" ] || {
    printf '%s\n' invalid
    return 0
  }
  _firewall_marker_current=$(cat "$PROC_SYS_ROOT/kernel/random/boot_id" 2>/dev/null || true)
  [ -n "$_firewall_marker_current" ] || {
    printf '%s\n' invalid
    return 0
  }
  if [ "$_firewall_marker_boot" = "$_firewall_marker_current" ]; then
    printf '%s\n' valid
  else
    rm -f "$FIREWALL_OWNERSHIP_FILE" 2>/dev/null || {
      printf '%s\n' invalid
      return 0
    }
    printf '%s\n' absent
  fi
}

load_firewall_token() {
  [ "$(firewall_marker_state)" = valid ] || return 1
  _firewall_marker_value=$(sed -n '1p' "$FIREWALL_OWNERSHIP_FILE" 2>/dev/null) || return 1
  FIREWALL_TOKEN=${_firewall_marker_value#*:}
  case "$FIREWALL_TOKEN" in
    *[!A-Za-z0-9]*) return 1 ;;
    ??????) ;;
    *) return 1 ;;
  esac
}

generate_firewall_token() {
  if has_cmd mktemp; then
    _firewall_token_path=$(mktemp "$STATE_DIR/.firewall-token.XXXXXX" 2>/dev/null) || return 1
  else
    _firewall_token_path=$(busybox_cmd mktemp "$STATE_DIR/.firewall-token.XXXXXX" 2>/dev/null) \
      || return 1
  fi
  case "$_firewall_token_path" in "$STATE_DIR/.firewall-token."*) ;;
    *) rm -f "$_firewall_token_path"; return 1 ;;
  esac
  _firewall_token=${_firewall_token_path##*.}
  rm -f "$_firewall_token_path" || return 1
  case "$_firewall_token" in
    *[!A-Za-z0-9]*) return 1 ;;
    ??????) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$_firewall_token"
}

write_firewall_marker() {
  _firewall_write_token="$1"
  case "$_firewall_write_token" in
    *[!A-Za-z0-9]*) return 1 ;;
    ??????) ;;
    *) return 1 ;;
  esac
  _firewall_write_boot=$(cat "$PROC_SYS_ROOT/kernel/random/boot_id" 2>/dev/null || true)
  case "$_firewall_write_boot" in ""|*[!A-Za-z0-9-]*) return 1 ;; esac
  _firewall_write_tmp="$FIREWALL_OWNERSHIP_FILE.$$.tmp"
  printf '%s:%s\n' "$_firewall_write_boot" "$_firewall_write_token" > "$_firewall_write_tmp" || {
    rm -f "$_firewall_write_tmp"
    return 1
  }
  chmod 0600 "$_firewall_write_tmp" 2>/dev/null || {
    rm -f "$_firewall_write_tmp"
    return 1
  }
  chown 0:0 "$_firewall_write_tmp" 2>/dev/null || true
  mv -f "$_firewall_write_tmp" "$FIREWALL_OWNERSHIP_FILE" || {
    rm -f "$_firewall_write_tmp"
    return 1
  }
  [ "$(firewall_marker_state)" = valid ]
}

firewall_chain_exists() {
  _chain_tool="$1"
  _chain_table="$2"
  _chain_name="$3"
  "$_chain_tool" -t "$_chain_table" -S "$_chain_name" >/dev/null 2>&1
}

firewall_legacy_shape_exact() {
  has_cmd iptables && has_cmd ip6tables || return 1
  iptables -t nat -S DNSCRYPT_PROXY 2>/dev/null | awk -v uid="$DNSCRYPT_UID" '
    $1 == "-A" && $2 == "DNSCRYPT_PROXY" {
      count++
      if (count == 1 && $0 != "-A DNSCRYPT_PROXY -m owner --uid-owner " uid " -j RETURN") bad=1
      if (count == 2 && $0 != "-A DNSCRYPT_PROXY -d 127.0.0.0/8 -j RETURN") bad=1
      if (count == 3 && $0 !~ /^-A DNSCRYPT_PROXY -p udp( -m udp)? --dport 53 -j DNAT --to-destination 127[.]0[.]0[.]1:5354$/) bad=1
      if (count == 4 && $0 !~ /^-A DNSCRYPT_PROXY -p tcp( -m tcp)? --dport 53 -j DNAT --to-destination 127[.]0[.]0[.]1:5354$/) bad=1
    }
    END { exit !(count == 4 && !bad) }
  ' || return 1
  ip6tables -t filter -S DNSCRYPT_PROXY6 2>/dev/null | awk -v uid="$DNSCRYPT_UID" '
    $1 == "-A" && $2 == "DNSCRYPT_PROXY6" {
      count++
      if (count == 1 && $0 != "-A DNSCRYPT_PROXY6 -m owner --uid-owner " uid " -j RETURN") bad=1
      if (count == 2 && $0 !~ /^-A DNSCRYPT_PROXY6 -p udp( -m udp)? --dport 53 -j REJECT( --reject-with [A-Za-z0-9_-]+)?$/) bad=1
      if (count == 3 && $0 !~ /^-A DNSCRYPT_PROXY6 -p tcp( -m tcp)? --dport 53 -j REJECT( --reject-with [A-Za-z0-9_-]+)?$/) bad=1
    }
    END { exit !(count == 3 && !bad) }
  ' || return 1
  iptables -t nat -S OUTPUT 2>/dev/null | awk '
    $1 == "-A" && $2 == "OUTPUT" {
      output_count++
      if (output_count == 1 && $0 !~ /^-A OUTPUT -p tcp( -m tcp)? --dport 53 -j DNSCRYPT_PROXY$/) bad=1
      if (output_count == 2 && $0 !~ /^-A OUTPUT -p udp( -m udp)? --dport 53 -j DNSCRYPT_PROXY$/) bad=1
      if ($0 ~ /-j DNSCRYPT_PROXY$/) jump_count++
    }
    END { exit !(output_count >= 2 && jump_count == 2 && !bad) }
  ' || return 1
  ip6tables -t filter -S OUTPUT 2>/dev/null | awk '
    $1 == "-A" && $2 == "OUTPUT" {
      output_count++
      if (output_count == 1 && $0 != "-A OUTPUT -j DNSCRYPT_PROXY6") bad=1
      if ($0 ~ /-j DNSCRYPT_PROXY6$/) jump_count++
    }
    END { exit !(output_count >= 1 && jump_count == 1 && !bad) }
  ' || return 1
  _legacy_v4_rules=$(iptables -t nat -S DNSCRYPT_PROXY 2>/dev/null \
    | awk '$1 == "-A" && $2 == "DNSCRYPT_PROXY" { count++ } END { print count + 0 }')
  _legacy_v6_rules=$(ip6tables -t filter -S DNSCRYPT_PROXY6 2>/dev/null \
    | awk '$1 == "-A" && $2 == "DNSCRYPT_PROXY6" { count++ } END { print count + 0 }')
  [ "$_legacy_v4_rules" = 4 ] && [ "$_legacy_v6_rules" = 3 ] \
    && iptables -t nat -C OUTPUT -p udp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1 \
    && iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -m owner --uid-owner "$DNSCRYPT_UID" -j RETURN >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -d 127.0.0.0/8 -j RETURN >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 >/dev/null 2>&1 \
    && ip6tables -t filter -C OUTPUT -j DNSCRYPT_PROXY6 >/dev/null 2>&1 \
    && ip6tables -t filter -C DNSCRYPT_PROXY6 -m owner --uid-owner "$DNSCRYPT_UID" -j RETURN >/dev/null 2>&1 \
    && ip6tables -t filter -C DNSCRYPT_PROXY6 -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
    && ip6tables -t filter -C DNSCRYPT_PROXY6 -p tcp --dport 53 -j REJECT >/dev/null 2>&1
}

firewall_owned_chains_exact() {
  _owned_token="$1"
  case "$_owned_token" in
    *[!A-Za-z0-9]*) return 1 ;;
    ??????) ;;
    *) return 1 ;;
  esac
  has_cmd iptables && has_cmd ip6tables || return 1
  iptables -t nat -S DNSCRYPT_PROXY 2>/dev/null | awk \
    -v uid="$DNSCRYPT_UID" -v token="dnscrypt-proxy-root:$_owned_token" '
      $1 == "-A" && $2 == "DNSCRYPT_PROXY" {
        count++
        if (count == 1 \
          && $0 != "-A DNSCRYPT_PROXY -m owner --uid-owner " uid " -m comment --comment " token " -j RETURN" \
          && $0 != "-A DNSCRYPT_PROXY -m owner --uid-owner " uid " -m comment --comment \"" token "\" -j RETURN") bad=1
        if (count == 2 && $0 != "-A DNSCRYPT_PROXY -d 127.0.0.0/8 -j RETURN") bad=1
        if (count == 3 && $0 !~ /^-A DNSCRYPT_PROXY -p udp( -m udp)? --dport 53 -j DNAT --to-destination 127[.]0[.]0[.]1:5354$/) bad=1
        if (count == 4 && $0 !~ /^-A DNSCRYPT_PROXY -p tcp( -m tcp)? --dport 53 -j DNAT --to-destination 127[.]0[.]0[.]1:5354$/) bad=1
      }
      END { exit !(count == 4 && !bad) }
    ' || return 1
  ip6tables -t filter -S DNSCRYPT_PROXY6 2>/dev/null | awk \
    -v uid="$DNSCRYPT_UID" -v token="dnscrypt-proxy-root:$_owned_token" '
      $1 == "-A" && $2 == "DNSCRYPT_PROXY6" {
        count++
        if (count == 1 \
          && $0 != "-A DNSCRYPT_PROXY6 -m owner --uid-owner " uid " -m comment --comment " token " -j RETURN" \
          && $0 != "-A DNSCRYPT_PROXY6 -m owner --uid-owner " uid " -m comment --comment \"" token "\" -j RETURN") bad=1
        if (count == 2 && $0 !~ /^-A DNSCRYPT_PROXY6 -p udp( -m udp)? --dport 53 -j REJECT( --reject-with [A-Za-z0-9_-]+)?$/) bad=1
        if (count == 3 && $0 !~ /^-A DNSCRYPT_PROXY6 -p tcp( -m tcp)? --dport 53 -j REJECT( --reject-with [A-Za-z0-9_-]+)?$/) bad=1
      }
      END { exit !(count == 3 && !bad) }
    '
}

firewall_owned_policy_exact() {
  _owned_policy_token="$1"
  firewall_owned_chains_exact "$_owned_policy_token" || return 1
  iptables -t nat -S OUTPUT 2>/dev/null | awk '
    $1 == "-A" && $2 == "OUTPUT" {
      output_count++
      if (output_count == 1 && $0 !~ /^-A OUTPUT -p tcp( -m tcp)? --dport 53 -j DNSCRYPT_PROXY$/) bad=1
      if (output_count == 2 && $0 !~ /^-A OUTPUT -p udp( -m udp)? --dport 53 -j DNSCRYPT_PROXY$/) bad=1
      if ($0 ~ /-j DNSCRYPT_PROXY$/) jump_count++
    }
    END { exit !(output_count >= 2 && jump_count == 2 && !bad) }
  ' || return 1
  ip6tables -t filter -S OUTPUT 2>/dev/null | awk '
    $1 == "-A" && $2 == "OUTPUT" {
      output_count++
      if (output_count == 1 && $0 != "-A OUTPUT -j DNSCRYPT_PROXY6") bad=1
      if ($0 ~ /-j DNSCRYPT_PROXY6$/) jump_count++
    }
    END { exit !(output_count >= 1 && jump_count == 1 && !bad) }
  '
}

remove_exact_legacy_firewall() {
  firewall_legacy_shape_exact || return 1
  while iptables -t nat -D OUTPUT -p udp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1; do :; done
  while iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1; do :; done
  while ip6tables -t filter -D OUTPUT -j DNSCRYPT_PROXY6 >/dev/null 2>&1; do :; done
  iptables -t nat -F DNSCRYPT_PROXY >/dev/null 2>&1 \
    && iptables -t nat -X DNSCRYPT_PROXY >/dev/null 2>&1 \
    && ip6tables -t filter -F DNSCRYPT_PROXY6 >/dev/null 2>&1 \
    && ip6tables -t filter -X DNSCRYPT_PROXY6 >/dev/null 2>&1 \
    && ! firewall_chain_exists iptables nat DNSCRYPT_PROXY \
    && ! firewall_chain_exists ip6tables filter DNSCRYPT_PROXY6
}

prepare_firewall_ownership() {
  _firewall_marker_state=$(firewall_marker_state)
  case "$_firewall_marker_state" in
    valid)
      load_firewall_token || return 1
      _v4_chain_present=0
      _v6_chain_present=0
      firewall_chain_exists iptables nat DNSCRYPT_PROXY && _v4_chain_present=1
      firewall_chain_exists ip6tables filter DNSCRYPT_PROXY6 && _v6_chain_present=1
      if [ "$_v4_chain_present" -eq 0 ] && [ "$_v6_chain_present" -eq 0 ]; then
        # A complete external firewall reset removed both token-bound chains.
        # Clear the now-stale generation and acquire new chains exclusively.
        rm -f "$FIREWALL_OWNERSHIP_FILE" || return 1
      elif [ "$_v4_chain_present" -eq 1 ] && [ "$_v6_chain_present" -eq 1 ] \
        && firewall_owned_chains_exact "$FIREWALL_TOKEN"; then
        return 0
      else
        # A partial or mismatched generation is ambiguous. Never flush it.
        return 1
      fi
      ;;
    invalid) return 1 ;;
  esac
  _v4_chain_present=0
  _v6_chain_present=0
  firewall_chain_exists iptables nat DNSCRYPT_PROXY && _v4_chain_present=1
  firewall_chain_exists ip6tables filter DNSCRYPT_PROXY6 && _v6_chain_present=1
  if [ "$_v4_chain_present" -ne 0 ] || [ "$_v6_chain_present" -ne 0 ]; then
    # v0.9.0 created these chains before a token-bound ownership marker existed.
    # Exact shape alone is not provenance: adoption additionally requires the
    # one-boot installer marker derived from a trusted old module version.
    [ "$(boot_marker_state "$LEGACY_FIREWALL_ADOPTION_FILE")" = valid ] \
      && remove_exact_legacy_firewall || return 1
  fi
  rm -f "$LEGACY_FIREWALL_ADOPTION_FILE"

  FIREWALL_TOKEN=$(generate_firewall_token) || return 1
  _firewall_created_v4=0
  _firewall_created_v6=0
  iptables -t nat -N DNSCRYPT_PROXY >/dev/null 2>&1 || return 1
  _firewall_created_v4=1
  if ! ip6tables -t filter -N DNSCRYPT_PROXY6 >/dev/null 2>&1; then
    iptables -t nat -X DNSCRYPT_PROXY >/dev/null 2>&1 || true
    return 1
  fi
  _firewall_created_v6=1
  if ! iptables -t nat -A DNSCRYPT_PROXY -m owner --uid-owner "$DNSCRYPT_UID" \
      -m comment --comment "dnscrypt-proxy-root:$FIREWALL_TOKEN" -j RETURN >/dev/null 2>&1 \
    || ! iptables -t nat -A DNSCRYPT_PROXY -d 127.0.0.0/8 -j RETURN >/dev/null 2>&1 \
    || ! iptables -t nat -A DNSCRYPT_PROXY -p udp --dport 53 -j DNAT \
      --to-destination 127.0.0.1:5354 >/dev/null 2>&1 \
    || ! iptables -t nat -A DNSCRYPT_PROXY -p tcp --dport 53 -j DNAT \
      --to-destination 127.0.0.1:5354 >/dev/null 2>&1 \
    || ! ip6tables -t filter -A DNSCRYPT_PROXY6 -m owner --uid-owner "$DNSCRYPT_UID" \
      -m comment --comment "dnscrypt-proxy-root:$FIREWALL_TOKEN" -j RETURN >/dev/null 2>&1 \
    || ! ip6tables -t filter -A DNSCRYPT_PROXY6 -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
    || ! ip6tables -t filter -A DNSCRYPT_PROXY6 -p tcp --dport 53 -j REJECT >/dev/null 2>&1 \
    || ! firewall_owned_chains_exact "$FIREWALL_TOKEN" \
    || ! write_firewall_marker "$FIREWALL_TOKEN"; then
    [ "$_firewall_created_v4" -eq 0 ] || iptables -t nat -F DNSCRYPT_PROXY >/dev/null 2>&1 || true
    [ "$_firewall_created_v4" -eq 0 ] || iptables -t nat -X DNSCRYPT_PROXY >/dev/null 2>&1 || true
    [ "$_firewall_created_v6" -eq 0 ] || ip6tables -t filter -F DNSCRYPT_PROXY6 >/dev/null 2>&1 || true
    [ "$_firewall_created_v6" -eq 0 ] || ip6tables -t filter -X DNSCRYPT_PROXY6 >/dev/null 2>&1 || true
    rm -f "$FIREWALL_OWNERSHIP_FILE"
    return 1
  fi
}

apply_iptables() {
  PORT="5354"
  CHAIN="DNSCRYPT_PROXY"
  IP6_CHAIN="DNSCRYPT_PROXY6"
  if ! has_cmd iptables || ! has_cmd ip6tables; then
    log_msg "$CONTROL_LOG" "iptables/ip6tables is unavailable; refusing to claim DNS leak protection."
    return 1
  fi
  shutdown_requested && {
    log_msg "$CONTROL_LOG" "Module shutdown is pending; refusing to install DNS redirection."
    return 1
  }
  if ! prepare_firewall_ownership; then
    log_msg "$CONTROL_LOG" "A same-name firewall chain or ownership marker is ambiguous; preserving it and refusing strict policy."
    return 1
  fi
  load_firewall_token || return 1
  # route_localnet must be enabled so the kernel does not drop packets DNAT'd to
  # 127.0.0.1 from the OUTPUT chain.
  if ! save_route_localnet_state; then
    log_msg "$CONTROL_LOG" "Unable to preserve route_localnet; DNS redirection was not installed."
    remove_iptables >/dev/null 2>&1 || true
    return 1
  fi
  sysctl -w net.ipv4.conf.all.route_localnet=1 2>/dev/null \
    || echo 1 > "$PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet" 2>/dev/null || {
      log_msg "$CONTROL_LOG" "Unable to enable route_localnet; DNS redirection was not installed."
      restore_route_localnet_state
      return 1
    }

  firewall_owned_chains_exact "$FIREWALL_TOKEN" || {
    log_msg "$CONTROL_LOG" "The token-bound firewall generation changed before attachment; strict policy was refused."
    return 1
  }
  while iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1; do :; done
  while iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1; do :; done
  shutdown_requested && {
    remove_iptables >/dev/null 2>&1 || true
    return 1
  }
  iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 \
    && iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || {
      log_msg "$CONTROL_LOG" "Unable to attach the IPv4 DNS chain."
      remove_iptables >/dev/null 2>&1 || true
      return 1
    }

  # dnscrypt-proxy only listens on IPv4 (127.0.0.1:5354). Block IPv6 plaintext
  # DNS through the token-bound module chain. Never delete indistinguishable
  # direct REJECT rules belonging to a VPN, firewall, or another root module.
  while ip6tables -t filter -D OUTPUT -j "$IP6_CHAIN" >/dev/null 2>&1; do :; done
  shutdown_requested && {
    remove_iptables >/dev/null 2>&1 || true
    return 1
  }
  ip6tables -t filter -I OUTPUT 1 -j "$IP6_CHAIN" >/dev/null 2>&1 || {
    log_msg "$CONTROL_LOG" "Unable to attach the IPv6 DNS chain."
    remove_iptables >/dev/null 2>&1 || true
    return 1
  }

  if ! firewall_owned_policy_exact "$FIREWALL_TOKEN"; then
    log_msg "$CONTROL_LOG" "The installed token-bound firewall policy failed exact shape verification."
    remove_iptables >/dev/null 2>&1 || true
    return 1
  fi

  log_msg "$CONTROL_LOG" "Applied IPv4 DNS redirection to 127.0.0.1:$PORT (IPv6 plaintext DNS blocked)."
}

firewall_rules_present() {
  has_cmd iptables && has_cmd ip6tables || return 1
  [ "$(firewall_marker_state)" = valid ] \
    && load_firewall_token \
    && firewall_owned_policy_exact "$FIREWALL_TOKEN" \
    && [ "$(cat "$PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet" 2>/dev/null)" = "1" ]
}

firewall_rules_absent() {
  _absent_marker_state=$(firewall_marker_state)
  case "$_absent_marker_state" in
    valid|invalid) return 1 ;;
  esac
  _legacy_marker_state=$(boot_marker_state "$LEGACY_IPV6_REBOOT_FILE")
  case "$_legacy_marker_state" in
    valid|invalid) return 1 ;;
  esac
  _adoption_marker_state=$(boot_marker_state "$LEGACY_FIREWALL_ADOPTION_FILE")
  case "$_adoption_marker_state" in
    valid)
      has_cmd iptables && has_cmd ip6tables || return 1
      if ! firewall_chain_exists iptables nat DNSCRYPT_PROXY \
        && ! firewall_chain_exists ip6tables filter DNSCRYPT_PROXY6; then
        rm -f "$LEGACY_FIREWALL_ADOPTION_FILE" || return 1
      else
        return 1
      fi
      ;;
    invalid) return 1 ;;
  esac
  return 0
}

remove_iptables() {
  CHAIN="DNSCRYPT_PROXY"
  IP6_CHAIN="DNSCRYPT_PROXY6"
  _remove_status=0
  _remove_owned=0
  _remove_marker_state=$(firewall_marker_state)
  case "$_remove_marker_state" in
    valid)
      if ! load_firewall_token; then
        _remove_status=1
      else
        _remove_v4_present=0
        _remove_v6_present=0
        has_cmd iptables \
          && firewall_chain_exists iptables nat "$CHAIN" && _remove_v4_present=1
        has_cmd ip6tables \
          && firewall_chain_exists ip6tables filter "$IP6_CHAIN" && _remove_v6_present=1
        if [ "$_remove_v4_present" -eq 0 ] && [ "$_remove_v6_present" -eq 0 ]; then
          rm -f "$FIREWALL_OWNERSHIP_FILE" || _remove_status=1
        elif [ "$_remove_v4_present" -eq 1 ] && [ "$_remove_v6_present" -eq 1 ] \
          && firewall_owned_chains_exact "$FIREWALL_TOKEN"; then
          _remove_owned=1
        else
          # A marker never authorizes deletion of a partial or token-mismatched
          # chain generation. Preserve it for explicit administrator recovery.
          _remove_status=1
        fi
      fi
      ;;
    invalid) _remove_status=1 ;;
    absent)
      _remove_adoption_state=$(boot_marker_state "$LEGACY_FIREWALL_ADOPTION_FILE")
      if [ "$_remove_adoption_state" = valid ]; then
        if firewall_legacy_shape_exact && remove_exact_legacy_firewall; then
          rm -f "$LEGACY_FIREWALL_ADOPTION_FILE" || _remove_status=1
        else
          _remove_v4_present=0
          _remove_v6_present=0
          has_cmd iptables \
            && firewall_chain_exists iptables nat "$CHAIN" && _remove_v4_present=1
          has_cmd ip6tables \
            && firewall_chain_exists ip6tables filter "$IP6_CHAIN" && _remove_v6_present=1
          if [ "$_remove_v4_present" -eq 0 ] && [ "$_remove_v6_present" -eq 0 ]; then
            rm -f "$LEGACY_FIREWALL_ADOPTION_FILE"
          else
            _remove_status=1
          fi
        fi
      elif [ "$_remove_adoption_state" = invalid ]; then
        _remove_status=1
      fi
      ;;
  esac
  if [ "$_remove_owned" -eq 1 ] && has_cmd iptables; then
    while iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1; do :; done
    while iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1; do :; done
    iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -X "$CHAIN" >/dev/null 2>&1 || true
  fi
  if [ "$_remove_owned" -eq 1 ] && has_cmd ip6tables; then
    while ip6tables -t filter -D OUTPUT -j "$IP6_CHAIN" >/dev/null 2>&1; do :; done
    ip6tables -t filter -F "$IP6_CHAIN" >/dev/null 2>&1 || true
    ip6tables -t filter -X "$IP6_CHAIN" >/dev/null 2>&1 || true
  fi
  if [ "$_remove_owned" -eq 1 ]; then
    if has_cmd iptables && has_cmd ip6tables \
      && ! firewall_chain_exists iptables nat "$CHAIN" \
      && ! firewall_chain_exists ip6tables filter "$IP6_CHAIN"; then
      rm -f "$FIREWALL_OWNERSHIP_FILE"
    else
      _remove_status=1
    fi
  fi
  _legacy_direct_state=$(boot_marker_state "$LEGACY_IPV6_REBOOT_FILE")
  case "$_legacy_direct_state" in
    valid)
      # v0.6.0 through v0.8.0 used generic direct REJECT rules. Even a trusted
      # old version cannot prove which identical duplicate belongs to another VPN
      # or firewall, so preserve every rule and require the module-manager
      # reboot that naturally resets per-boot netfilter state.
      log_msg "$CONTROL_LOG" \
        "Legacy direct IPv6 DNS rules were preserved because their individual ownership is indistinguishable; reboot is required."
      _remove_status=1
      ;;
    invalid) _remove_status=1 ;;
  esac
  # Restore the value that existed before this module changed it in this boot.
  restore_route_localnet_state || _remove_status=1
  log_msg "$CONTROL_LOG" "Removed DNS redirection rules."
  return "$_remove_status"
}

strict_policy_present() {
  firewall_rules_present || return 1
  [ -f "$PRIVATE_DNS_STATE_FILE" ] || return 1
  private_dns_state_valid "$PRIVATE_DNS_STATE_FILE" || return 1
  [ "$(settings get global private_dns_mode 2>/dev/null)" = "off" ]
}

upstream_only_policy_present() {
  firewall_rules_absent && [ ! -e "$PRIVATE_DNS_STATE_FILE" ] && [ ! -L "$PRIVATE_DNS_STATE_FILE" ]
}

reconcile_running_policy() {
  _policy_mode="$1"
  is_dnscrypt_ready || return 1
  case "$_policy_mode" in
    strict)
      save_and_disable_private_dns || return 1
      if apply_iptables >/dev/null 2>&1 && firewall_rules_present; then
        return 0
      fi
      remove_iptables >/dev/null 2>&1 || true
      restore_private_dns >/dev/null 2>&1 || true
      return 1
      ;;
    upstream_only)
      restore_private_dns || return 1
      remove_iptables >/dev/null 2>&1 || return 1
      firewall_rules_absent
      ;;
    *) return 1 ;;
  esac
}

rollback_running_policy() {
  _rollback_mode="$1"
  reconcile_running_policy "$_rollback_mode" || return 1
  is_dnscrypt_ready || return 1
  case "$_rollback_mode" in
    strict) strict_policy_present ;;
    upstream_only) upstream_only_policy_present ;;
    *) return 1 ;;
  esac
}

apply_selected_policy() {
  _selected_mode=$(get_dns_mode 2>/dev/null) || {
    echo "The DNS integration mode state is invalid; no policy was changed."
    return 1
  }
  if [ "$_selected_mode" = "upstream_only" ] && ! is_dnscrypt_running; then
    restore_private_dns || return 1
    remove_iptables >/dev/null 2>&1 || return 1
    firewall_rules_absent
    return $?
  fi
  reconcile_running_policy "$_selected_mode"
}

set_dns_mode() {
  _target_mode="${2:-}"
  case "$_target_mode" in
    strict|upstream_only) ;;
    *) echo "Unknown DNS integration mode. Use: strict|upstream_only"; return 1 ;;
  esac
  _current_mode=$(get_dns_mode 2>/dev/null) || {
    echo "The existing DNS integration mode state is invalid; repair or remove it first."
    return 1
  }

  if ! is_dnscrypt_running; then
    _cleanup_ok=1
    remove_iptables >/dev/null 2>&1 || _cleanup_ok=0
    restore_private_dns >/dev/null 2>&1 || _cleanup_ok=0
    firewall_rules_absent || _cleanup_ok=0
    [ "$_cleanup_ok" -eq 1 ] || {
      echo "Unable to clean stale DNS policy before changing mode."
      return 1
    }
    write_dns_mode "$_target_mode" || {
      echo "Failed to persist the DNS integration mode."
      return 1
    }
    echo "DNS integration mode set to $_target_mode; the daemon remains stopped."
    return 0
  fi

  is_dnscrypt_ready || {
    echo "The running daemon is not locally ready; its DNS mode was not changed."
    return 1
  }
  if [ "$_target_mode" = "$_current_mode" ]; then
    reconcile_running_policy "$_target_mode" || {
      echo "Failed to reconcile the selected DNS policy; policy_fault requires repair."
      return 3
    }
    echo "DNS integration mode $_target_mode was refreshed."
    return 0
  fi

  if ! reconcile_running_policy "$_target_mode"; then
    if rollback_running_policy "$_current_mode" >/dev/null 2>&1; then
      echo "DNS mode transition failed; the previous policy was restored."
      return 1
    fi
    log_msg "$SERVICE_LOG" "DNS mode transition failed and rollback_failed; authoritative mode remains $_current_mode with policy_fault."
    echo "DNS mode transition failed; rollback_failed and policy_fault requires repair."
    return 3
  fi
  if ! write_dns_mode "$_target_mode"; then
    if rollback_running_policy "$_current_mode" >/dev/null 2>&1; then
      echo "DNS mode transition was rolled back because its state could not be committed."
      return 1
    fi
    log_msg "$SERVICE_LOG" "DNS mode state commit failed and rollback_failed; authoritative mode remains $_current_mode with policy_fault."
    echo "DNS mode state commit failed; rollback_failed and policy_fault requires repair."
    return 3
  fi
  echo "DNS integration mode changed from $_current_mode to $_target_mode without restarting dnscrypt-proxy."
}

classify_start_failure_since() {
  _failure_marker="$1"
  _failure_source_log="${2:-$SERVICE_LOG}"
  _failure_log="$RUN_DIR/start-failure-log.$$.tmp"
  sed -n "/$_failure_marker/,\$p" "$_failure_source_log" 2>/dev/null > "$_failure_log" || true
  if grep -Eq 'Missing cache file for source' "$_failure_log" 2>/dev/null; then
    # In upstream 2.1.18 this exact message means the TOML source table omitted
    # its cache_file key; it is a configuration error, not an offline cache miss.
    _classified_failure=config_error
  elif grep -Eq 'Unable to retrieve source \[|cache file \[.*\] not present and no valid URL' \
    "$_failure_log" 2>/dev/null; then
    _classified_failure=source_cache_unavailable
  elif grep -Eq \
    'Unable to load the configuration file|Unsupported key in configuration file|(^|[^A-Za-z])toml([^A-Za-z]|$)' \
    "$_failure_log" 2>/dev/null; then
    _classified_failure=config_error
  else
    _classified_failure=process_exit
  fi
  rm -f "$_failure_log"
  printf '%s\n' "$_classified_failure"
}

validate_dnscrypt_config() {
  _validate_config_path="$1"
  _validate_log_path="$2"
  _validate_marker_prefix="$3"
  case "$_validate_marker_prefix" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac
  CONFIG_CHECK_FAILURE=none
  _validate_marker="$_validate_marker_prefix=$$-$(date +%s 2>/dev/null || echo 0)"
  log_msg "$_validate_log_path" "$_validate_marker"
  run_bounded_config_check "$_validate_config_path" "$_validate_log_path"
  _validate_status=$?
  case "$_validate_status" in
    0) return 0 ;;
    124)
      CONFIG_CHECK_FAILURE=source_cache_unavailable
      log_msg "$_validate_log_path" \
        "Configuration/source check exceeded its ${_bounded_check_limit}-second hard limit."
      ;;
    125)
      CONFIG_CHECK_FAILURE=shutdown_cancelled
      log_msg "$_validate_log_path" "Configuration/source check was cancelled by module shutdown."
      ;;
    126)
      CONFIG_CHECK_FAILURE=runtime_path_unavailable
      log_msg "$_validate_log_path" \
        "The UID3003-traversable runtime tree is unavailable or unsafe."
      ;;
    *) CONFIG_CHECK_FAILURE=$(classify_start_failure_since "$_validate_marker" "$_validate_log_path") ;;
  esac
  return 1
}

MODULE_BINARY_WAS_PROMOTED=0
MODULE_BINARY_PREVIOUS_VERSION=
MODULE_BINARY_PROMOTED_VERSION=

recover_prestart_binary_backup() {
  if [ ! -e "$RUNTIME_MODULE_BINARY_BACKUP" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_BACKUP" ]; then
    return 0
  fi
  acquire_runtime_tree_lock || return $?
  _backup_recovery_status=1
  if runtime_tree_is_trusted \
    && [ "$(runtime_operation_state 2>/dev/null)" = none ] \
    && ! shutdown_requested \
    && ! is_dnscrypt_running \
    && runtime_module_binary_backup_is_owned; then
    _backup_previous_version=$(binary_version_bounded \
      "$RUNTIME_MODULE_BINARY_BACKUP" 2>/dev/null || true)
    _backup_current_version=$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)
    if [ -n "$_backup_previous_version" ] && [ -n "$_backup_current_version" ]; then
      if [ "$_backup_previous_version" = "$_backup_current_version" ]; then
        # The process stopped after making the rollback copy but before the
        # atomic replacement. The canonical executable never changed.
        cleanup_runtime_module_binary_backup \
          && _backup_recovery_status=0
      else
        # The process stopped after the atomic replacement but before startup
        # reached a terminal success/failure. Preserve the rollback copy and
        # resume that exact transaction: this invocation will either finalize
        # it after local readiness or restore it on any later start failure.
        MODULE_BINARY_WAS_PROMOTED=1
        MODULE_BINARY_PREVIOUS_VERSION=$_backup_previous_version
        MODULE_BINARY_PROMOTED_VERSION=$_backup_current_version
        _backup_recovery_status=0
      fi
    elif [ -n "$_backup_previous_version" ] \
      && mv -f "$RUNTIME_MODULE_BINARY_BACKUP" "$RUNTIME_BIN" \
      && runtime_binary_at_is_trusted "$RUNTIME_BIN" \
      && [ "$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)" = \
        "$_backup_previous_version" ]; then
      # The canonical name was lost or corrupted before publication completed.
      _backup_recovery_status=0
    fi
  fi
  exec 6>&-
  [ "$_backup_recovery_status" -eq 0 ] || return 1
  refresh_installed_version_marker >/dev/null 2>&1 || true
  if [ "$MODULE_BINARY_WAS_PROMOTED" -eq 1 ]; then
    log_msg "$SERVICE_LOG" \
      "Recovered an interrupted pre-start binary promotion; rollback remains armed until startup is healthy."
  fi
}

rollback_reconciled_module_binary() {
  [ "$MODULE_BINARY_WAS_PROMOTED" -eq 1 ] || return 0
  is_dnscrypt_running && return 1
  acquire_runtime_tree_lock || return $?
  _reconcile_rollback_status=1
  if runtime_tree_is_trusted \
    && [ "$(runtime_operation_state 2>/dev/null)" = none ] \
    && ! is_dnscrypt_running; then
    if [ -n "$MODULE_BINARY_PREVIOUS_VERSION" ]; then
      if runtime_module_binary_backup_is_owned \
        && mv -f "$RUNTIME_MODULE_BINARY_BACKUP" "$RUNTIME_BIN" \
        && runtime_binary_at_is_trusted "$RUNTIME_BIN" \
        && [ "$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)" = \
          "$MODULE_BINARY_PREVIOUS_VERSION" ]; then
        _reconcile_rollback_status=0
      fi
    elif runtime_binary_at_is_trusted "$RUNTIME_BIN" \
      && [ "$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)" = \
        "$MODULE_BINARY_PROMOTED_VERSION" ] \
      && rm -f "$RUNTIME_BIN"; then
      _reconcile_rollback_status=0
    fi
  fi
  exec 6>&-
  [ "$_reconcile_rollback_status" -eq 0 ] || return 1
  MODULE_BINARY_WAS_PROMOTED=0
  refresh_installed_version_marker >/dev/null 2>&1 || true
  log_msg "$SERVICE_LOG" \
    "Rolled back the pre-start module binary promotion after startup failed."
}

finalize_reconciled_module_binary() {
  [ "$MODULE_BINARY_WAS_PROMOTED" -eq 1 ] || return 0
  acquire_runtime_tree_lock || return $?
  _reconcile_finalize_status=1
  if runtime_tree_is_trusted \
    && [ "$(runtime_operation_state 2>/dev/null)" = none ] \
    && runtime_binary_at_is_trusted "$RUNTIME_BIN" \
    && [ "$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)" = \
      "$MODULE_BINARY_PROMOTED_VERSION" ] \
    && cleanup_runtime_module_binary_backup; then
    _reconcile_finalize_status=0
  fi
  exec 6>&-
  [ "$_reconcile_finalize_status" -eq 0 ] || return 1
  MODULE_BINARY_WAS_PROMOTED=0
  refresh_installed_version_marker >/dev/null 2>&1 || true
}

rollback_reconciled_module_binary_after_failure() {
  [ "$MODULE_BINARY_WAS_PROMOTED" -eq 1 ] || return 0
  if rollback_reconciled_module_binary; then
    return 0
  fi
  write_start_failure state_record_failed >/dev/null 2>&1 || true
  log_msg "$SERVICE_LOG" \
    "Startup failed after module binary promotion and rollback_failed; protected runtime repair is required."
  return 1
}

# A module upgrade can stage a verified upstream executable below /data/adb
# while an older executable remains in the persistent /data/local runtime tree.
# Reconcile only while start_service owns the control lock and no exact daemon
# is running.  Version decisions come exclusively from bounded `-version`
# probes of protected executables; installed-version is bookkeeping, never an
# authority.  Equal/older module copies cannot silently downgrade the runtime.
reconcile_module_runtime_binary() {
  MODULE_BINARY_WAS_PROMOTED=0
  MODULE_BINARY_PREVIOUS_VERSION=
  MODULE_BINARY_PROMOTED_VERSION=
  [ "$RUNTIME_ROOT" != "$MODDIR" ] || return 0
  recover_prestart_binary_backup || return 1
  [ "$MODULE_BINARY_WAS_PROMOTED" -eq 0 ] || return 0
  _module_binary="$MODULE_BIN_DIR/dnscrypt-proxy"
  if [ ! -e "$_module_binary" ] && [ ! -L "$_module_binary" ]; then
    refresh_installed_version_marker >/dev/null 2>&1 || true
    return 0
  fi

  _runtime_version=$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)
  if [ ! -d "$MODULE_BIN_DIR" ] || [ -L "$MODULE_BIN_DIR" ] \
    || [ "$(stat -c '%u:%g:%a' "$MODULE_BIN_DIR" 2>/dev/null)" != "0:0:755" ] \
    || [ ! -f "$_module_binary" ] || [ -L "$_module_binary" ] \
    || [ "$(stat -c '%u:%g:%a' "$_module_binary" 2>/dev/null)" != "0:0:755" ]; then
    if [ -n "$_runtime_version" ]; then
      log_msg "$SERVICE_LOG" \
        "Ignored an unsafe module-local dnscrypt-proxy candidate; protected runtime $_runtime_version was kept."
      refresh_installed_version_marker >/dev/null 2>&1 || true
      return 0
    fi
    return 1
  fi
  _module_version=$(binary_version_bounded "$_module_binary" 2>/dev/null || true)
  if [ -z "$_module_version" ]; then
    if [ -n "$_runtime_version" ]; then
      log_msg "$SERVICE_LOG" \
        "Ignored a module-local dnscrypt-proxy candidate with an invalid or timed-out version probe; protected runtime $_runtime_version was kept."
      refresh_installed_version_marker >/dev/null 2>&1 || true
      return 0
    fi
    return 1
  fi
  if [ -n "$_runtime_version" ]; then
    _module_comparison=$(compare_semver "$_module_version" "$_runtime_version") || return 1
    if [ "$_module_comparison" -le 0 ]; then
      refresh_installed_version_marker >/dev/null 2>&1 || true
      return 0
    fi
  fi
  shutdown_requested && return 1
  is_dnscrypt_running && return 1
  cleanup_runtime_module_binary_stage || return 1
  if ! copy_runtime_template \
      "$_module_binary" "$RUNTIME_MODULE_BINARY_STAGE" 0755 0:0 \
    || ! runtime_module_binary_stage_is_owned \
    || ! files_equal_exact "$_module_binary" "$RUNTIME_MODULE_BINARY_STAGE"; then
    cleanup_runtime_module_binary_stage >/dev/null 2>&1 || true
    return 1
  fi
  _staged_version=$(binary_version_bounded "$RUNTIME_MODULE_BINARY_STAGE" 2>/dev/null || true)
  if [ "$_staged_version" != "$_module_version" ]; then
    cleanup_runtime_module_binary_stage >/dev/null 2>&1 || true
    return 1
  fi

  run_bounded_config_check \
    "$CONFIG_FILE" "$SERVICE_LOG" "$RUNTIME_MODULE_BINARY_STAGE"
  _module_check_status=$?
  if [ "$_module_check_status" -ne 0 ]; then
    cleanup_runtime_module_binary_stage >/dev/null 2>&1 || true
    if [ -n "$_runtime_version" ]; then
      log_msg "$SERVICE_LOG" \
        "Module-local dnscrypt-proxy $_module_version failed bounded configuration/source validation (status $_module_check_status); protected runtime $_runtime_version was kept."
      refresh_installed_version_marker >/dev/null 2>&1 || true
      return 0
    fi
    return 1
  fi

  acquire_runtime_tree_lock || {
    _module_lock_status=$?
    cleanup_runtime_module_binary_stage >/dev/null 2>&1 || true
    return "$_module_lock_status"
  }
  _module_commit_status=1
  _module_replaced=0
  _module_backup_ready=0
  if runtime_tree_is_trusted \
    && [ "$(runtime_operation_state 2>/dev/null)" = none ] \
    && ! shutdown_requested \
    && ! is_dnscrypt_running \
    && cleanup_runtime_module_binary_backup; then
    if [ -n "$_runtime_version" ]; then
      if copy_runtime_template \
          "$RUNTIME_BIN" "$RUNTIME_MODULE_BINARY_BACKUP" 0755 0:0 \
        && runtime_module_binary_backup_is_owned \
        && [ "$(binary_version_bounded "$RUNTIME_MODULE_BINARY_BACKUP" 2>/dev/null || true)" = \
          "$_runtime_version" ]; then
        _module_backup_ready=1
      fi
    else
      _module_backup_ready=1
    fi
  fi
  if [ "$_module_backup_ready" -eq 1 ] \
    && runtime_module_binary_stage_is_owned \
    && [ -f "$_module_binary" ] && [ ! -L "$_module_binary" ] \
    && [ "$(stat -c '%u:%g:%a' "$_module_binary" 2>/dev/null)" = "0:0:755" ] \
    && files_equal_exact "$_module_binary" "$RUNTIME_MODULE_BINARY_STAGE" \
    && ! shutdown_requested \
    && ! is_dnscrypt_running \
    && mv -f "$RUNTIME_MODULE_BINARY_STAGE" "$RUNTIME_BIN"; then
    _module_replaced=1
    if runtime_binary_at_is_trusted "$RUNTIME_BIN" \
      && [ "$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)" = \
        "$_module_version" ]; then
      _module_commit_status=0
    fi
  fi
  if [ "$_module_commit_status" -ne 0 ] && [ "$_module_replaced" -eq 1 ]; then
    if [ -n "$_runtime_version" ] \
      && runtime_module_binary_backup_is_owned \
      && mv -f "$RUNTIME_MODULE_BINARY_BACKUP" "$RUNTIME_BIN" \
      && [ "$(binary_version_bounded "$RUNTIME_BIN" 2>/dev/null || true)" = \
        "$_runtime_version" ]; then
      _module_replaced=0
    elif [ -z "$_runtime_version" ] \
      && runtime_binary_at_is_trusted "$RUNTIME_BIN" \
      && rm -f "$RUNTIME_BIN"; then
      _module_replaced=0
    fi
  fi
  exec 6>&-
  if [ "$_module_commit_status" -ne 0 ]; then
    cleanup_runtime_module_binary_stage >/dev/null 2>&1 || true
    [ "$_module_replaced" -ne 0 ] \
      || cleanup_runtime_module_binary_backup >/dev/null 2>&1 || true
    return 1
  fi
  MODULE_BINARY_WAS_PROMOTED=1
  MODULE_BINARY_PREVIOUS_VERSION=$_runtime_version
  MODULE_BINARY_PROMOTED_VERSION=$_module_version
  refresh_installed_version_marker >/dev/null 2>&1 || true
  log_msg "$SERVICE_LOG" \
    "Promoted verified module-local dnscrypt-proxy $_module_version into the persistent runtime before startup."
  return 0
}

# Start dnscrypt-proxy with its final numeric identity instead of allowing a
# root process to parse configuration before upstream's -child re-exec. The
# canonical TOML stays root-only, while publish_runtime_active_snapshot creates
# an owner-readable execution copy for only the final UID3003 process.
# It removes user_name only from this disposable execution copy. The handshake
# PID is accepted only after the complete argv and effective UID are verified.
launch_dnscrypt_runtime_uid() {
  LAUNCHED_DNSCRYPT_PID=
  LAUNCHED_DNSCRYPT_SU_PID=
  has_cmd su || return 1
  _launch_pid_file=$RUNTIME_DAEMON_PID_FILE
  if [ "$RUNTIME_ROOT" = "$MODDIR" ]; then
    # Installer-stage commands never launch the daemon.  The repository's
    # shell harness intentionally exercises lifecycle logic without creating a
    # production /data/local tree; keep that explicit test-only path isolated.
    [ "${DNSCRYPT_RUNTIME_TEST_MODE:-0}" = 1 ] || return 1
    config_file_is_trusted || return 1
    _launch_pid_file="$RUN_DIR/.dnscrypt-test-launch.pid"
    : > "$_launch_pid_file" || return 1
    chmod 0600 "$_launch_pid_file" 2>/dev/null || return 1
  else
    runtime_active_snapshot_at_is_trusted "$RUNTIME_ACTIVE_DIR" || return 1
    [ -f "$_launch_pid_file" ] && [ ! -L "$_launch_pid_file" ] \
      && [ "$(stat -c '%u:%g:%a' "$_launch_pid_file" 2>/dev/null)" = \
        "$DNSCRYPT_UID:0:600" ] || return 1
    : > "$_launch_pid_file" || return 1
    chown "$DNSCRYPT_UID:0" "$_launch_pid_file" 2>/dev/null || return 1
    chmod 0600 "$_launch_pid_file" 2>/dev/null || return 1
    [ "$(stat -c '%u:%g:%a' "$_launch_pid_file" 2>/dev/null)" = \
      "$DNSCRYPT_UID:0:600" ] || return 1
  fi
  _launch_command="printf '%s\\n' \"\$\$\" > '$_launch_pid_file'; exec '$RUNTIME_BIN' -config '$RUNTIME_CONFIG_FILE'"
  su "$DNSCRYPT_UID" -c "$_launch_command" 6>&- 8>&- 9>&- \
    >> "$SERVICE_LOG" 2>&1 &
  LAUNCHED_DNSCRYPT_SU_PID=$!
  _launch_wait=0
  while [ "$_launch_wait" -lt 6 ]; do
    _launch_pid=$(sed -n '1p' "$_launch_pid_file" 2>/dev/null || true)
    case "$_launch_pid" in
      ""|*[!0-9]*) ;;
      *)
        if is_dnscrypt_pid "$_launch_pid" \
          && [ "$(dnscrypt_process_uid "$_launch_pid" 2>/dev/null)" = "$DNSCRYPT_UID" ]; then
          LAUNCHED_DNSCRYPT_PID=$_launch_pid
          return 0
        fi
        ;;
    esac
    kill -0 "$LAUNCHED_DNSCRYPT_SU_PID" >/dev/null 2>&1 || break
    sleep 1
    _launch_wait=$((_launch_wait + 1))
  done
  kill "$LAUNCHED_DNSCRYPT_SU_PID" >/dev/null 2>&1 || true
  wait "$LAUNCHED_DNSCRYPT_SU_PID" >/dev/null 2>&1 || true
  _launch_pid=$(sed -n '1p' "$_launch_pid_file" 2>/dev/null || true)
  case "$_launch_pid" in
    ""|*[!0-9]*) ;;
    *) is_dnscrypt_pid "$_launch_pid" && terminate_dnscrypt_process >/dev/null 2>&1 || true ;;
  esac
  return 1
}

start_service() {
  if shutdown_requested; then
    echo "The module is disabled, being removed, or shutting down; service start was refused."
    return 1
  fi
  _start_mode=$(get_dns_mode 2>/dev/null) || {
    write_start_failure mode_state_invalid >/dev/null 2>&1 || true
    echo "The DNS integration mode state is invalid; service start was refused."
    return 1
  }
  ensure_config || {
    write_start_failure config_error >/dev/null 2>&1 || true
    echo "Failed to prepare the dnscrypt-proxy configuration."
    return 1
  }
  if ! ensure_runtime_tree; then
    if ! is_dnscrypt_running; then
      remove_iptables >/dev/null 2>&1 || true
      restore_private_dns >/dev/null 2>&1 || true
    fi
    write_start_failure runtime_path_unavailable >/dev/null 2>&1 || true
    echo "The UID3003-traversable runtime tree is unavailable or unsafe; service start was refused."
    return 1
  fi
  clear_start_failure
  shutdown_requested && {
    echo "Module shutdown began while preparing the service; start was cancelled."
    return 1
  }
  if is_dnscrypt_running; then
    if is_dnscrypt_ready; then
      if reconcile_running_policy "$_start_mode"; then
        rm -f "$STARTUP_STATE_FILE"
        rm -f "$USER_STOPPED_FILE"
        echo "dnscrypt-proxy is already running; $_start_mode policy refreshed."
        return 0
      fi
      write_start_failure policy_install_failed >/dev/null 2>&1 || true
      log_msg "$SERVICE_LOG" "The locally ready daemon was preserved after $_start_mode policy reconciliation failed."
      echo "dnscrypt-proxy is locally ready, but $_start_mode policy could not be reconciled."
      return 1
    fi
    if dnscrypt_is_starting; then
      rm -f "$USER_STOPPED_FILE"
      echo "dnscrypt-proxy is still within its bounded startup grace period."
      return 0
    fi
    log_msg "$SERVICE_LOG" "Existing dnscrypt-proxy instance failed local process, UID, or listener readiness; restarting it."
    if ! terminate_dnscrypt_process || ! remove_iptables >/dev/null 2>&1; then
      restore_private_dns >/dev/null 2>&1 || true
      write_start_failure cleanup_failed >/dev/null 2>&1 || true
      echo "The unhealthy dnscrypt-proxy instance could not be cleaned up safely."
      return 1
    fi
  fi
  # Keep the system fail-open while dnscrypt-proxy performs its upstream
  # NetProbe. Stale redirection would blackhole DNS before the local TCP and UDP
  # listeners exist.
  if ! remove_iptables >/dev/null 2>&1 || ! restore_private_dns >/dev/null 2>&1; then
    write_start_failure cleanup_failed >/dev/null 2>&1 || true
    echo "Failed to clear stale DNS policy before startup."
    return 1
  fi
  if ! reconcile_module_runtime_binary; then
    write_start_failure binary_unavailable >/dev/null 2>&1 || true
    echo "Failed to reconcile the verified module binary with the protected runtime."
    return 1
  fi
  if ! ensure_binary; then
    write_start_failure binary_unavailable >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "dnscrypt-proxy binary recovery failed and rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "dnscrypt-proxy binary is missing and automatic download failed."
    return 1
  fi
  if shutdown_requested; then
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "Module shutdown began and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "Module shutdown began while preparing the daemon; start was cancelled."
    return 1
  fi
  # Clear the intentional-stop marker so the watchdog treats future outages as faults.
  rm -f "$USER_STOPPED_FILE"
  # A real 2.1.18 -check performs the same source/cache loading as cold start,
  # while skipping NetProbe and listener creation. Doing it while fail-open
  # prevents a bound-but-not-yet-usable socket from being mistaken for ready and
  # gives offline cache/config failures an accurate, bounded classification.
  if ! validate_dnscrypt_config "$CONFIG_FILE" "$SERVICE_LOG" dnscrypt-source-preflight; then
    _start_failure=$CONFIG_CHECK_FAILURE
    write_start_failure "$_start_failure" >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "dnscrypt-proxy source/config preflight failed and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "dnscrypt-proxy source/config preflight failed ($_start_failure); firewall rules were not installed."
    return 1
  fi
  if ! publish_runtime_active_snapshot; then
    write_start_failure runtime_path_unavailable >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "Publishing the daemon snapshot failed and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "Failed to publish the protected daemon configuration snapshot; service start was refused."
    return 1
  fi
  shutdown_requested && {
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "Module shutdown began and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "Module shutdown began after configuration validation; start was cancelled."
    return 1
  }
  cd "$RUNTIME_CONFIG_DIR" || {
    write_start_failure config_error >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "The runtime directory became unavailable and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    return 1
  }
  # Close control/updater/runtime lock descriptors in the unprivileged launcher
  # so the long-running daemon cannot keep a parent's advisory lock alive.
  _start_log_marker="dnscrypt-start-attempt=$$-$(date +%s 2>/dev/null || echo 0)"
  log_msg "$SERVICE_LOG" "$_start_log_marker"
  if ! launch_dnscrypt_runtime_uid; then
    _start_failure=$(classify_start_failure_since "$_start_log_marker")
    [ "$_start_failure" != none ] || _start_failure=process_exit
    write_start_failure "$_start_failure" >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "dnscrypt-proxy launch failed and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "dnscrypt-proxy could not be launched as UID $DNSCRYPT_UID ($_start_failure)."
    return 1
  fi
  _started_pid=$LAUNCHED_DNSCRYPT_PID
  _pid_tmp="$PID_FILE.$$.tmp"
  printf '%s\n' "$_started_pid" > "$_pid_tmp" && mv -f "$_pid_tmp" "$PID_FILE" || {
    rm -f "$_pid_tmp"
    terminate_dnscrypt_process >/dev/null 2>&1 || true
    write_start_failure state_record_failed >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "The PID record failed and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "Failed to record the dnscrypt-proxy PID."
    return 1
  }
  if ! mark_dnscrypt_starting "$_started_pid"; then
    terminate_dnscrypt_process >/dev/null 2>&1 || true
    write_start_failure state_record_failed >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "The startup-state record failed and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "Failed to record the bounded startup state."
    return 1
  fi
  _startup_grace=$(dnscrypt_startup_grace_seconds)
  _ready_try=0
  while [ "$_ready_try" -lt "$_startup_grace" ]; do
    shutdown_requested && break
    if is_dnscrypt_ready; then
      break
    fi
    kill -0 "$_started_pid" >/dev/null 2>&1 || break
    sleep 1
    _ready_try=$((_ready_try + 1))
  done
  _actual_pid=$(dnscrypt_pid 2>/dev/null || true)
  if shutdown_requested || ! is_dnscrypt_ready; then
    _start_process_alive=0
    kill -0 "$_started_pid" >/dev/null 2>&1 && _start_process_alive=1
    log_msg "$SERVICE_LOG" "dnscrypt-proxy did not expose both loopback listeners under UID $DNSCRYPT_UID within ${_startup_grace}s."
    terminate_dnscrypt_process
    remove_iptables >/dev/null 2>&1 || true
    restore_private_dns >/dev/null 2>&1 || true
    rm -f "$STARTUP_STATE_FILE"
    if shutdown_requested; then
      write_start_failure shutdown_cancelled >/dev/null 2>&1 || true
      echo "dnscrypt-proxy startup was cancelled by module shutdown; firewall rules were not installed."
    elif [ "$_start_process_alive" -eq 0 ]; then
      _start_failure=$(classify_start_failure_since "$_start_log_marker")
      write_start_failure "$_start_failure" >/dev/null 2>&1 || true
      echo "dnscrypt-proxy exited before listener readiness ($_start_failure); firewall rules were not installed."
    else
      write_start_failure listener_timeout >/dev/null 2>&1 || true
      echo "dnscrypt-proxy listener readiness timed out; firewall rules were not installed."
    fi
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "The failed startup could not restore the previous runtime binary; rollback_failed requires repair."
      return 3
    fi
    return 1
  fi
  rm -f "$STARTUP_STATE_FILE"
  if ! reconcile_running_policy "$_start_mode"; then
    write_start_failure policy_install_failed >/dev/null 2>&1 || true
    log_msg "$SERVICE_LOG" "$_start_mode policy installation failed; the locally ready daemon was preserved without global redirection."
    if ! finalize_reconciled_module_binary; then
      write_start_failure state_record_failed >/dev/null 2>&1 || true
      log_msg "$SERVICE_LOG" \
        "The locally ready daemon was preserved, but promoted-binary finalization failed."
      echo "dnscrypt-proxy is locally ready without global redirection, but promoted-binary finalization requires repair."
      return 3
    fi
    echo "dnscrypt-proxy is locally ready, but $_start_mode policy could not be installed."
    return 1
  fi
  clear_start_failure
  if shutdown_requested; then
    terminate_dnscrypt_process >/dev/null 2>&1 || true
    remove_iptables >/dev/null 2>&1 || true
    restore_private_dns >/dev/null 2>&1 || true
    if ! rollback_reconciled_module_binary_after_failure; then
      echo "Module shutdown began and the promoted binary rollback_failed; protected runtime repair is required."
      return 3
    fi
    echo "Module shutdown began while installing DNS redirection; start was cancelled."
    return 1
  fi
  if ! finalize_reconciled_module_binary; then
    write_start_failure state_record_failed >/dev/null 2>&1 || true
    log_msg "$SERVICE_LOG" \
      "dnscrypt-proxy became healthy, but promoted-binary finalization failed."
    echo "dnscrypt-proxy is healthy, but promoted-binary finalization requires repair."
    return 3
  fi
  log_msg "$SERVICE_LOG" "dnscrypt-proxy started with PID $_actual_pid under UID $DNSCRYPT_UID in $_start_mode mode."
  echo "dnscrypt-proxy started in $_start_mode mode."
  return 0
}

terminate_dnscrypt_process() {
  _terminate_count=0
  while [ "$_terminate_count" -lt 16 ]; do
    pid=$(dnscrypt_pid 2>/dev/null || true)
    [ -n "$pid" ] || break
    kill "$pid" >/dev/null 2>&1 || true
    _terminate_wait=0
    while is_dnscrypt_pid "$pid" && [ "$_terminate_wait" -lt 3 ]; do
      sleep 1
      _terminate_wait=$((_terminate_wait + 1))
    done
    # Revalidate argv[0] immediately before SIGKILL. A PID can be recycled
    # during the graceful wait and must never target an unrelated process.
    is_dnscrypt_pid "$pid" && kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    _terminate_count=$((_terminate_count + 1))
  done
  rm -f "$PID_FILE"
  ! is_dnscrypt_running
}

stop_service() {
  # Mark this as an intentional stop so the service watchdog does not treat it as a
  # crash. start_service removes the marker again.
  : > "$USER_STOPPED_FILE"
  rm -f "$STARTUP_STATE_FILE"
  clear_start_failure
  _stop_cleanup_status=0
  terminate_dnscrypt_process || _stop_cleanup_status=1
  remove_iptables >/dev/null 2>&1 || _stop_cleanup_status=1
  firewall_rules_absent || _stop_cleanup_status=1
  if ! restore_private_dns; then
    log_msg "$SERVICE_LOG" "Failed to restore the saved Android Private DNS settings."
    echo "dnscrypt-proxy stopped, but Android Private DNS could not be restored."
    return 1
  fi
  if [ "$_stop_cleanup_status" -ne 0 ]; then
    log_msg "$SERVICE_LOG" "dnscrypt-proxy stop left incomplete process, firewall, or route_localnet cleanup."
    echo "dnscrypt-proxy stop cleanup was incomplete."
    return 1
  fi
  log_msg "$SERVICE_LOG" "dnscrypt-proxy stopped."
  echo "dnscrypt-proxy stopped."
}

# Emergency lifecycle cleanup intentionally bypasses the ordinary control lock,
# but is available only after a disable/remove/shutdown marker exists. The
# marker makes concurrent starts and firewall commits fail closed; repeated
# cleanup closes the small race with an operation that passed its pre-check just
# before the marker appeared.
shutdown_stop_service() {
  if ! shutdown_requested; then
    echo "shutdown-stop requires a module disable/remove/shutdown marker."
    return 1
  fi
  : > "$USER_STOPPED_FILE"
  rm -f "$STARTUP_STATE_FILE"
  clear_start_failure
  _shutdown_try=0
  while [ "$_shutdown_try" -lt 3 ]; do
    _shutdown_ok=1
    terminate_dnscrypt_process || _shutdown_ok=0
    remove_iptables >/dev/null 2>&1 || _shutdown_ok=0
    restore_private_dns >/dev/null 2>&1 || _shutdown_ok=0
    if [ "$_shutdown_ok" -eq 1 ] \
      && ! is_dnscrypt_running \
      && firewall_rules_absent; then
      log_msg "$SERVICE_LOG" "dnscrypt-proxy lifecycle shutdown cleanup completed."
      echo "dnscrypt-proxy lifecycle shutdown cleanup completed."
      return 0
    fi
    sleep 1
    _shutdown_try=$((_shutdown_try + 1))
  done
  log_msg "$SERVICE_LOG" "dnscrypt-proxy lifecycle shutdown cleanup is incomplete and must be retried."
  echo "dnscrypt-proxy lifecycle shutdown cleanup is incomplete."
  return 1
}

restart_service() {
  stop_service >/dev/null 2>&1 || return 1
  start_service
}

service_state() {
  _state_mode=$(get_dns_mode 2>/dev/null) || {
    echo "config_fault"
    return 1
  }
  if shutdown_requested; then
    echo "shutdown"
    return 1
  fi
  if ! is_dnscrypt_running; then
    _start_failure=$(get_start_failure 2>/dev/null || echo invalid)
    case "$_start_failure" in
      none) echo "stopped" ;;
      invalid) echo "start_state_invalid" ;;
      *) echo "start_$_start_failure" ;;
    esac
    return 1
  fi
  if ! is_dnscrypt_ready; then
    if dnscrypt_is_starting; then
      echo "starting"
    else
      echo "local_fault"
    fi
    return 1
  fi
  case "$_state_mode" in
    strict) strict_policy_present || { echo "policy_fault"; return 1; } ;;
    upstream_only) upstream_only_policy_present || { echo "policy_fault"; return 1; } ;;
  esac
  if [ "$(upstream_probe_state)" = "offline" ]; then
    echo "degraded"
  else
    echo "healthy"
  fi
}

protection_health() {
  _health_state=$(service_state 2>/dev/null || true)
  [ "$_health_state" = "healthy" ] || [ "$_health_state" = "degraded" ]
}

dnscrypt_resolve_output_has_ipv4_answer() {
  _resolve_answer_file="$1"
  [ -f "$_resolve_answer_file" ] && [ ! -L "$_resolve_answer_file" ] || return 1
  grep -Eq \
    '^IPv4 addresses: [0-9]{1,3}(\.[0-9]{1,3}){3}(, [0-9]{1,3}(\.[0-9]{1,3}){3})*$' \
    "$_resolve_answer_file" 2>/dev/null
}

probe_upstream() {
  ensure_config || return 1
  ensure_runtime_tree || return 1
  is_dnscrypt_ready || return 1
  _probe_output="$RUN_DIR/upstream-probe.$$.out"
  _probe_state=offline
  local_dns_query dns.google 8 > "$_probe_output" 2>&1
  _probe_status=$?
  # dnscrypt-proxy 2.1.18 can return zero after later query failures. Require
  # an explicit IPv4 answer for the requested probe name instead of treating
  # process exit status as proof of upstream DNS availability.
  if [ "$_probe_status" -eq 0 ] \
    && dnscrypt_resolve_output_has_ipv4_answer "$_probe_output"; then
    _probe_state=online
  fi
  _probe_tmp="$UPSTREAM_STATUS_FILE.$$.tmp"
  {
    printf 'state=%s\n' "$_probe_state"
    printf 'time=%s\n' "$(now_iso)"
  } > "$_probe_tmp" && chmod 0600 "$_probe_tmp" 2>/dev/null \
    && mv -f "$_probe_tmp" "$UPSTREAM_STATUS_FILE"
  _probe_write_status=$?
  rm -f "$_probe_output" "$_probe_tmp"
  [ "$_probe_write_status" -eq 0 ] || return 1
  [ "$_probe_state" = "online" ]
}

upstream_probe_state() {
  _upstream_state=$(sed -n 's/^state=//p' "$UPSTREAM_STATUS_FILE" 2>/dev/null | head -n 1)
  case "$_upstream_state" in
    online|offline) printf '%s\n' "$_upstream_state" ;;
    *) printf '%s\n' unknown ;;
  esac
}

print_status() {
  running="false"
  pid=""
  pid=$(dnscrypt_pid 2>/dev/null || true)
  [ -n "$pid" ] && running="true"
  dns_mode=$(get_dns_mode 2>/dev/null || echo invalid)
  state=$(service_state 2>/dev/null || true)
  [ -n "$state" ] || state="unknown"
  healthy="false"
  { [ "$state" = "healthy" ] || [ "$state" = "degraded" ]; } && healthy="true"
  uid=""
  listener="false"
  local_dns="false"
  firewall="absent"
  if [ -n "$pid" ]; then
    uid=$(dnscrypt_process_uid "$pid")
    dnscrypt_listener_ready "$pid" >/dev/null 2>&1 && listener="true"
    dnscrypt_local_handler_ready "$pid" >/dev/null 2>&1 && local_dns="true"
  fi
  case "$dns_mode" in
    strict) firewall_rules_present >/dev/null 2>&1 && firewall="strict" || firewall="fault" ;;
    upstream_only) firewall_rules_absent >/dev/null 2>&1 || firewall="residue" ;;
    *) firewall="unknown" ;;
  esac
  upstream=$(upstream_probe_state)
  start_failure=$(get_start_failure 2>/dev/null || echo invalid)
  version=$(installed_version)
  manager=$(manager_name)
  update_state="unknown"
  update_msg=""
  update_time=""
  if [ -f "$UPDATE_STATUS_FILE" ]; then
    update_state=$(sed -n 's/^state=//p' "$UPDATE_STATUS_FILE" | head -n 1)
    update_msg=$(sed -n 's/^message=//p' "$UPDATE_STATUS_FILE" | head -n 1)
    update_time=$(sed -n 's/^time=//p' "$UPDATE_STATUS_FILE" | head -n 1)
  fi
  printf '{"running":%s,"healthy":%s,"pid":"%s","uid":"%s","listener":%s,"local_dns":%s,"dns_mode":"%s","service_state":"%s","start_failure":"%s","firewall":"%s","upstream":"%s","version":"%s","manager":"%s","config":"%s","update_state":"%s","update_message":"%s","update_time":"%s"}\n' \
    "$running" "$healthy" "$(shell_quote_json "$pid")" "$(shell_quote_json "$uid")" "$listener" "$local_dns" \
    "$(shell_quote_json "$dns_mode")" "$(shell_quote_json "$state")" "$(shell_quote_json "$start_failure")" "$(shell_quote_json "$firewall")" "$(shell_quote_json "$upstream")" \
    "$(shell_quote_json "$version")" "$(shell_quote_json "$manager")" "$(shell_quote_json "$CONFIG_FILE")" \
    "$(shell_quote_json "$update_state")" "$(shell_quote_json "$update_msg")" "$(shell_quote_json "$update_time")"
}

save_config_b64() {
  payload="${2:-}"
  [ -n "$payload" ] || {
    echo "Missing base64 payload."
    return 1
  }
  ensure_config || {
    echo "The live configuration inputs are unsafe; no changes were made."
    return 1
  }
  tmp="$RUN_DIR/dnscrypt-proxy.toml.$$.new"
  printf '%s' "$payload" | base64_decode > "$tmp" 2>/dev/null || {
    echo "Failed to decode base64 config."
    rm -f "$tmp"
    return 1
  }
  [ -s "$tmp" ] || {
    echo "Decoded configuration is empty."
    rm -f "$tmp"
    return 1
  }
  enforce_dnscrypt_user "$tmp" || {
    echo "Failed to enforce the dedicated dnscrypt-proxy user."
    rm -f "$tmp"
    return 1
  }
  _save_stage=$(create_secure_config_temp '.dnscrypt-proxy.toml.save') || {
    rm -f "$tmp"
    echo "Failed to create a secure configuration staging file."
    return 1
  }
  _save_stage_identity=$(secure_config_temp_identity "$_save_stage") || {
    rm -f "$tmp" "$_save_stage"
    return 1
  }
  if ! cat "$tmp" > "$_save_stage" \
    || ! secure_config_temp_valid "$_save_stage" "$_save_stage_identity" 600 \
    || ! prepare_secure_config_temp_for_proxy "$_save_stage" "$_save_stage_identity"; then
    rm -f "$tmp" "$_save_stage"
    echo "Failed to protect the staged configuration."
    return 1
  fi
  rm -f "$tmp"
  if ! ensure_binary; then
    echo "dnscrypt-proxy is unavailable; the new configuration was not installed."
    rm -f "$_save_stage"
    return 1
  fi
  if ! validate_dnscrypt_config "$_save_stage" "$CONTROL_LOG" dnscrypt-save-check; then
    echo "dnscrypt-proxy rejected the new configuration ($CONFIG_CHECK_FAILURE). Original file was kept."
    rm -f "$_save_stage"
    return 1
  fi
  secure_config_temp_valid "$_save_stage" "$_save_stage_identity" "$(managed_config_mode)" || {
    rm -f "$_save_stage"
    echo "The staged configuration was replaced during validation."
    return 1
  }
  backup=$(create_secure_config_temp 'dnscrypt-proxy.toml.bak.save') || {
    rm -f "$_save_stage"
    echo "Failed to create a secure configuration backup."
    return 1
  }
  _save_backup_identity=$(secure_config_temp_identity "$backup") || {
    rm -f "$_save_stage" "$backup"
    return 1
  }
  if ! cat "$CONFIG_FILE" > "$backup" \
    || ! secure_config_temp_valid "$backup" "$_save_backup_identity" 600; then
    echo "Failed to back up the current configuration."
    rm -f "$_save_stage" "$backup"
    return 1
  fi
  prune_config_backups
  if ! secure_config_temp_valid "$_save_stage" "$_save_stage_identity" "$(managed_config_mode)" \
    || ! mv -f "$_save_stage" "$CONFIG_FILE"; then
    echo "Failed to install the new configuration."
    rm -f "$_save_stage"
    return 1
  fi
  config_file_is_trusted || return 1
  log_msg "$CONTROL_LOG" "Configuration saved; backup: $backup"
  echo "Configuration saved. Backup: $backup"
}

# Resolve data-log paths from the root-only canonical TOML. The daemon's main
# log is intentionally left on inherited stderr and captured in service.log.
toml_section_log_path() {
  _section="$1"
  _file=$(sed -n "/^[[:space:]]*\[$_section\][[:space:]]*$/,/^[[:space:]]*\[/p" "$CONFIG_FILE" 2>/dev/null \
    | sed -n "s/^[[:space:]]*file[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
    | head -n 1)
  [ -n "$_file" ] || return 1
  case "$_file" in
    ../data/[A-Za-z0-9_.-]*)
      _log_basename=${_file#../data/}
      case "$_log_basename" in ""|.|..|*/*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
      printf '%s/%s' "$RUNTIME_DATA_DIR" "$_log_basename"
      ;;
    *) return 1 ;;
  esac
}

query_log_path() {
  toml_section_log_path query_log
}

nx_log_path() {
  toml_section_log_path nx_log
}

proxy_log_path() {
  _file=$(sed -n "1,/^[[:space:]]*\[/ { s/^[[:space:]]*log_file[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p; }" \
    "$CONFIG_FILE" 2>/dev/null | head -n 1)
  if [ -z "$_file" ]; then
    printf '%s' "$SERVICE_LOG"
  else
    return 1
  fi
}

log_file_is_safe_for_read() {
  _safe_log_path="$1"
  case "$_safe_log_path" in
    "$RUNTIME_DATA_DIR"/*)
      _safe_log_basename=${_safe_log_path#"$RUNTIME_DATA_DIR"/}
      case "$_safe_log_basename" in ""|.|..|*/*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
      ;;
    "$LOG_DIR"/*)
      _safe_log_basename=${_safe_log_path#"$LOG_DIR"/}
      case "$_safe_log_basename" in ""|.|..|*/*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  [ -f "$_safe_log_path" ] && [ ! -L "$_safe_log_path" ] || return 1
  _safe_log_size=$(stat -c %s "$_safe_log_path" 2>/dev/null) || return 1
  case "$_safe_log_size" in ""|*[!0-9]*) return 1 ;; esac
  [ "$_safe_log_size" -le 16777216 ]
}

# Dynamic query/NX logs live in a directory owned by UID3003 so lumberjack and
# the atomic source-cache writer can rename files. Root must never reopen those
# pathnames directly after an lstat check: the owner could swap an entry in the
# gap. Read a bounded snapshot through the module's existing su implementation
# after dropping to the daemon UID; a raced symlink to a root-only object then
# fails in the unprivileged process instead of becoming a privileged read.
snapshot_dnscrypt_data_log() {
  _snapshot_source="$1"
  case "$_snapshot_source" in
    "$RUNTIME_DATA_DIR"/*)
      _snapshot_basename=${_snapshot_source#"$RUNTIME_DATA_DIR"/}
      case "$_snapshot_basename" in
        ""|.|..|*/*|*[!A-Za-z0-9_.-]*) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  if has_cmd mktemp; then
    _snapshot_file=$(mktemp "$TMP_BASE/.dnscrypt-log-snapshot.XXXXXX" 2>/dev/null) || return 1
  else
    _snapshot_file=$(busybox_cmd mktemp "$TMP_BASE/.dnscrypt-log-snapshot.XXXXXX" 2>/dev/null) \
      || return 1
  fi
  case "$_snapshot_file" in "$TMP_BASE/.dnscrypt-log-snapshot."*) ;;
    *) rm -f "$_snapshot_file"; return 1 ;;
  esac
  _snapshot_control_uid=$(config_control_uid) || {
    rm -f "$_snapshot_file"
    return 1
  }
  if ! chmod 0600 "$_snapshot_file" 2>/dev/null \
    || [ ! -f "$_snapshot_file" ] || [ -L "$_snapshot_file" ] \
    || [ "$(stat -c '%u:%g:%a' "$_snapshot_file" 2>/dev/null)" != \
      "$_snapshot_control_uid:0:600" ]; then
    rm -f "$_snapshot_file"
    return 1
  fi
  if [ ! -e "$_snapshot_source" ] && [ ! -L "$_snapshot_source" ]; then
    printf '%s\n' "$_snapshot_file"
    return 0
  fi
  log_file_is_safe_for_read "$_snapshot_source" || {
    rm -f "$_snapshot_file"
    return 1
  }
  _snapshot_command="tail -c 16777216 '$_snapshot_source'"
  if has_cmd timeout; then
    timeout 8 su "$DNSCRYPT_UID" -c "$_snapshot_command" > "$_snapshot_file" 2>/dev/null
  else
    busybox_cmd timeout 8 su "$DNSCRYPT_UID" -c "$_snapshot_command" \
      > "$_snapshot_file" 2>/dev/null
  fi
  _snapshot_status=$?
  if [ "$_snapshot_status" -ne 0 ] \
    || [ ! -f "$_snapshot_file" ] || [ -L "$_snapshot_file" ] \
    || [ "$(stat -c '%u:%g:%a' "$_snapshot_file" 2>/dev/null)" != \
      "$_snapshot_control_uid:0:600" ]; then
    rm -f "$_snapshot_file"
    return 1
  fi
  _snapshot_size=$(stat -c %s "$_snapshot_file" 2>/dev/null) || {
    rm -f "$_snapshot_file"
    return 1
  }
  case "$_snapshot_size" in ""|*[!0-9]*) rm -f "$_snapshot_file"; return 1 ;; esac
  if [ "$_snapshot_size" -gt 16777216 ]; then
    rm -f "$_snapshot_file"
    return 1
  fi
  printf '%s\n' "$_snapshot_file"
}

# dnscrypt-proxy's own -resolve client understands the configured nonstandard
# listen port. Android Toybox/BusyBox nslookup does not reliably support -port.
local_dns_query() {
  _query_name="$1"
  _query_limit="${2:-12}"
  case "$_query_name" in
    ""|.*|*..|*..*|*[!A-Za-z0-9.-]*) return 64 ;;
  esac
  [ "${#_query_name}" -le 253 ] || return 64
  case "$_query_limit" in ""|*[!0-9]*|0) return 64 ;; esac
  [ "$_query_limit" -le 30 ] || return 64

  if [ ! -x "$DNSCRYPT_BIN" ]; then
    if has_cmd dig; then
      dig @127.0.0.1 -p 5354 "$_query_name" +short +time=5 +tries=1
      return $?
    fi
    return 127
  fi
  ensure_runtime_tree || return 126
  runtime_binary_at_is_trusted "$RUNTIME_BIN" || return 126
  has_cmd su || return 126
  _query_snapshot="$RUNTIME_ROOT/.config-check.$$"
  prepare_config_check_snapshot "$CONFIG_FILE" "$_query_snapshot" || return 126
  _query_runtime_config="$_query_snapshot/dnscrypt-proxy.toml"
  _query_outer_limit=$((_query_limit + 3))
  _query_status=127

  if has_cmd timeout; then
    _query_timeout=$(command -v timeout 2>/dev/null || true)
    case "$_query_timeout" in
      /*) ;;
      *)
        cleanup_config_check_snapshot "$_query_snapshot" >/dev/null 2>&1 || true
        return 126
        ;;
    esac
    _query_command="exec '$_query_timeout' '$_query_limit' '$RUNTIME_BIN' -config '$_query_runtime_config' -resolve '$_query_name'"
    timeout "$_query_outer_limit" su "$DNSCRYPT_UID" -c "$_query_command"
    _query_status=$?
  else
    if has_cmd busybox; then
      _query_busybox=$(command -v busybox 2>/dev/null || true)
    elif [ -x /data/adb/magisk/busybox ]; then
      _query_busybox=/data/adb/magisk/busybox
    elif [ -x /data/adb/ksu/bin/busybox ]; then
      _query_busybox=/data/adb/ksu/bin/busybox
    elif [ -x /data/adb/ap/bin/busybox ]; then
      _query_busybox=/data/adb/ap/bin/busybox
    else
      _query_busybox=
    fi
    case "$_query_busybox" in
      /*) ;;
      *)
        cleanup_config_check_snapshot "$_query_snapshot" >/dev/null 2>&1 || true
        return 126
        ;;
    esac
    _query_command="exec '$_query_busybox' timeout '$_query_limit' '$RUNTIME_BIN' -config '$_query_runtime_config' -resolve '$_query_name'"
    "$_query_busybox" timeout "$_query_outer_limit" \
      su "$DNSCRYPT_UID" -c "$_query_command"
    _query_status=$?
  fi
  if ! cleanup_config_check_snapshot "$_query_snapshot"; then
    return 126
  fi
  return "$_query_status"
}

# Keep interactive diagnostics from pinning the WebUI or control process when
# Android's resolver, a direct DNS server, or the network is unresponsive.
# Prefer a standalone timeout implementation and fall back to the root
# manager's BusyBox applet, matching the portability contract used elsewhere.
bounded_diagnostic_command() {
  _diagnostic_limit="${1:-}"
  shift || return 64
  case "$_diagnostic_limit" in ""|*[!0-9]*|0) return 64 ;; esac
  [ "$_diagnostic_limit" -le 30 ] || return 64
  [ "$#" -gt 0 ] || return 64
  if has_cmd timeout; then
    timeout "$_diagnostic_limit" "$@"
  else
    busybox_cmd timeout "$_diagnostic_limit" "$@"
  fi
}

# dnscrypt-proxy probes every selected upstream while starting and logs the
# actual protocol RTT. Return the latest recorded value for one resolver.
resolver_latency_from_log() {
  _resolver_name="$1"
  _proxy_log=$(proxy_log_path)
  for _latency_log in "$_proxy_log" "$SERVICE_LOG"; do
    log_file_is_safe_for_read "$_latency_log" || continue
    _resolver_latency=$(awk -v resolver="$_resolver_name" '
      index($0, "[" resolver "] OK (") && match($0, /rtt: [0-9][0-9]*ms/) {
        value = substr($0, RSTART, RLENGTH)
        sub(/^rtt: /, "", value)
        sub(/ms$/, "", value)
        latest = value
      }
      END { if (latest != "") print latest }
    ' "$_latency_log" 2>/dev/null)
    case "$_resolver_latency" in
      ""|*[!0-9]*) ;;
      *) printf '%s' "$_resolver_latency"; return 0 ;;
    esac
  done
  return 1
}

show_logs() {
  lines="${2:-160}"
  case "$lines" in ""|*[!0-9]*) lines=160 ;; esac
  [ "${#lines}" -le 4 ] || lines=160
  [ "$lines" -ge 1 ] && [ "$lines" -le 2000 ] || lines=160
  ensure_config || {
    echo "The live configuration inputs are unsafe; logs were not read."
    return 1
  }
  echo "===== service.log ====="
  tail -n "$lines" "$SERVICE_LOG" 2>/dev/null || true
  echo "===== update.log ====="
  tail -n "$lines" "$UPDATE_LOG" 2>/dev/null || true
  echo "===== control.log ====="
  tail -n "$lines" "$CONTROL_LOG" 2>/dev/null || true
  echo "===== dnscrypt-proxy.log ====="
  _proxy_log=$(proxy_log_path)
  if log_file_is_safe_for_read "$_proxy_log"; then
    tail -n "$lines" "$_proxy_log" 2>/dev/null || true
  elif [ -e "$_proxy_log" ] || [ -L "$_proxy_log" ]; then
    echo "Log path is unsafe or exceeds the 16 MiB read limit."
  fi
}

dns_test() {
  _domain="${2:-}"
  [ -z "$_domain" ] && { echo '{"error":"Missing domain argument"}'; return 1; }
  # Reject anything that is not a valid domain to prevent command injection.
  case "$_domain" in
    *[!a-zA-Z0-9.\-]*) echo '{"error":"invalid domain"}'; return 1 ;;
  esac
  ensure_config || { echo '{"error":"unsafe configuration inputs"}'; return 1; }
  PORT="5354"
  # Test the dnscrypt-proxy path once and use that same bounded query for both
  # the displayed result and latency. A second lookup would double network
  # delay and could produce a result that disagrees with the first one.
  _start=$(_now_ms)
  _query_ok=0
  _result=$(local_dns_query "$_domain" 8 2>&1) && _query_ok=1
  _end=$(_now_ms)
  if [ "$_query_ok" -eq 1 ]; then
    _latency=$(( _end - _start ))
  else
    _latency=-1
    _result="Local DNS query failed or timed out"
  fi
  # Also test direct (bypass) for comparison
  if has_cmd nslookup; then
    _direct=$(bounded_diagnostic_command 8 nslookup "$_domain" 9.9.9.9 2>&1) \
      || _direct="Direct DNS query failed or timed out"
  elif has_cmd dig; then
    _direct=$(bounded_diagnostic_command 8 dig @9.9.9.9 "$_domain" \
      +short +time=5 +tries=1 2>&1) \
      || _direct="Direct DNS query failed or timed out"
  else
    _direct="N/A"
  fi
  _result_escaped=$(printf '%s' "$_result" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|')
  _direct_escaped=$(printf '%s' "$_direct" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|')
  printf '{"domain":"%s","result":"%s","direct":"%s","latency_ms":%d,"server":"127.0.0.1:%d"}\n' \
    "$_domain" "$_result_escaped" "$_direct_escaped" "$_latency" "$PORT"
}

list_resolvers() {
  # Parse current server_names from config
  ensure_config || {
    echo "The live configuration inputs are unsafe."
    return 1
  }
  _current=$(grep '^server_names' "$CONFIG_FILE" 2>/dev/null | sed "s/.*\[//;s/\].*//;s/'//g;s/\"//g;s/,/ /g" | tr -s ' ')
  echo "$_current"
}

set_resolvers() {
  # $2 = comma-separated list of resolver names
  _resolvers="${2:-}"
  [ -z "$_resolvers" ] && { echo "Missing resolver list."; return 1; }
  # Normalize whitespace around commas, then reject missing or unsafe elements.
  _resolvers=$(printf '%s' "$_resolvers" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]*,[[:space:]]*/,/g')
  case "$_resolvers" in
    ""|,*|*,|*,,*|*[!a-zA-Z0-9._,-]*) echo "Invalid resolver list."; return 1 ;;
  esac
  _old_ifs="$IFS"
  IFS=','
  for _name in $_resolvers; do
    case "$_name" in
      ""|*[!a-zA-Z0-9._-]*) IFS="$_old_ifs"; echo "Invalid resolver name: $_name"; return 1 ;;
    esac
  done
  IFS="$_old_ifs"
  ensure_config || {
    echo "The live configuration inputs are unsafe; resolver selection was not changed."
    return 1
  }
  # Format as TOML array
  _toml_list=$(printf '%s' "$_resolvers" | sed "s/,/', '/g")
  _toml_line="server_names = ['${_toml_list}']"
  _resolver_stage=$(create_secure_config_temp '.dnscrypt-proxy.toml.resolvers') || {
    echo "Failed to create a secure resolver staging file."
    return 1
  }
  _resolver_stage_identity=$(secure_config_temp_identity "$_resolver_stage") || {
    rm -f "$_resolver_stage"
    return 1
  }
  # Replace in config using awk to avoid sed special-character issues.
  if grep -q '^server_names' "$CONFIG_FILE" 2>/dev/null; then
    awk -v line="$_toml_line" '/^server_names/ {print line; next} {print}' \
      "$CONFIG_FILE" > "$_resolver_stage"
  else
    awk -v line="$_toml_line" 'NR==1 {print; print line; next} {print}' \
      "$CONFIG_FILE" > "$_resolver_stage"
  fi
  _resolver_rewrite_status=$?
  if [ "$_resolver_rewrite_status" -ne 0 ] \
    || ! secure_config_temp_valid "$_resolver_stage" "$_resolver_stage_identity" 600 \
    || ! prepare_secure_config_temp_for_proxy "$_resolver_stage" "$_resolver_stage_identity"; then
    rm -f "$_resolver_stage"
    echo "Failed to prepare the resolver list safely."
    return 1
  fi
  if ! ensure_binary; then
    rm -f "$_resolver_stage"
    echo "dnscrypt-proxy is unavailable; the resolver list was not installed."
    return 1
  fi
  if ! validate_dnscrypt_config "$_resolver_stage" "$CONTROL_LOG" dnscrypt-resolver-check; then
    rm -f "$_resolver_stage"
    echo "dnscrypt-proxy rejected the resolver list ($CONFIG_CHECK_FAILURE); original file was kept."
    return 1
  fi
  if ! secure_config_temp_valid "$_resolver_stage" "$_resolver_stage_identity" "$(managed_config_mode)" \
    || ! mv -f "$_resolver_stage" "$CONFIG_FILE"; then
    rm -f "$_resolver_stage"
    echo "Failed to install the resolver list safely."
    return 1
  fi
  log_msg "$CONTROL_LOG" "Resolvers updated: $_resolvers"
  echo "Resolvers updated: $_resolvers"
}

ping_resolver() {
  # Report dnscrypt-proxy's real upstream probe RTT, not a cached local query.
  _resolver="${2:-}"
  [ -z "$_resolver" ] && { echo '{"name":"","latency_ms":-1,"error":"Missing resolver name"}'; return 1; }
  case "$_resolver" in
    *[!a-zA-Z0-9._-]*) echo '{"name":"","latency_ms":-1,"error":"invalid resolver name"}'; return 1 ;;
  esac
  ensure_config || { echo '{"name":"","latency_ms":-1,"error":"unsafe configuration inputs"}'; return 1; }
  _latency=$(resolver_latency_from_log "$_resolver" 2>/dev/null || true)
  if [ -n "$_latency" ]; then
    printf '{"name":"%s","latency_ms":%d}\n' "$_resolver" "$_latency"
  else
    printf '{"name":"%s","latency_ms":-1,"error":"upstream latency unavailable"}\n' "$_resolver"
  fi
}

ping_all_resolvers() {
  # Ping all currently selected resolvers and return JSON array
  ensure_config || { echo '[]'; return 1; }
  _resolvers=$(grep '^server_names' "$CONFIG_FILE" 2>/dev/null | sed "s/.*\[//;s/\].*//;s/'//g;s/\"//g;s/,/ /g" | tr -s ' ')
  printf '['
  _first=1
  for _r in $_resolvers; do
    [ -z "$_r" ] && continue
    _latency=$(resolver_latency_from_log "$_r" 2>/dev/null || true)
    [ "$_first" -eq 0 ] && printf ','
    if [ -n "$_latency" ]; then
      printf '{"name":"%s","latency_ms":%d}' "$_r" "$_latency"
    else
      printf '{"name":"%s","latency_ms":-1,"error":"upstream latency unavailable"}' "$_r"
    fi
    _first=0
  done
  printf ']\n'
}

protocol_status() {
  # Return JSON with current protocol configuration and connection quality
  ensure_config || { echo '{"error":"unsafe configuration inputs"}'; return 1; }
  _dnscrypt=$(grep '^dnscrypt_servers' "$CONFIG_FILE" 2>/dev/null | grep -c 'true')
  _doh=$(grep '^doh_servers' "$CONFIG_FILE" 2>/dev/null | grep -c 'true')
  _odoh=$(grep '^odoh_servers' "$CONFIG_FILE" 2>/dev/null | grep -c 'true')
  _anon="false"
  if grep -q '^\[anonymized_dns\]' "$CONFIG_FILE" 2>/dev/null || grep -q '^routes' "$CONFIG_FILE" 2>/dev/null; then
    _anon="true"
  fi
  _running="false"
  is_dnscrypt_running && _running="true"
  # Check connectivity by resolving a test domain
  _quality="disconnected"
  if [ "$_running" = "true" ]; then
    _protocol_probe="$RUN_DIR/protocol-probe.$$.out"
    rm -f "$_protocol_probe"
    if (umask 077; : > "$_protocol_probe") \
      && local_dns_query dns.google 8 > "$_protocol_probe" 2>&1 \
      && dnscrypt_resolve_output_has_ipv4_answer "$_protocol_probe"; then
      _quality="good"
    else
      _quality="degraded"
    fi
    rm -f "$_protocol_probe"
  fi
  # Count selected resolvers with a successful upstream probe in the log.
  _active_resolvers=0
  _selected_resolvers=$(list_resolvers)
  for _selected in $_selected_resolvers; do
    resolver_latency_from_log "$_selected" >/dev/null 2>&1 \
      && _active_resolvers=$((_active_resolvers + 1))
  done
  printf '{"dnscrypt":%s,"doh":%s,"odoh":%s,"anonymized":%s,"running":%s,"quality":"%s","active_resolvers":%d}\n' \
    "$([ $_dnscrypt -gt 0 ] && echo true || echo false)" \
    "$([ $_doh -gt 0 ] && echo true || echo false)" \
    "$([ $_odoh -gt 0 ] && echo true || echo false)" \
    "$_anon" "$_running" "$_quality" "$_active_resolvers"
}

rewrite_quick_mode_toml() {
  _rewrite_input="$1"
  _rewrite_output="$2"
  _rewrite_mode="$3"
  awk -v mode="$_rewrite_mode" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function code_without_comment(s,    i,c,out,in_sq,in_dq,esc) {
      out=""; in_sq=0; in_dq=0; esc=0; had_comment=0
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (in_dq) {
          out=out c
          if (esc) esc=0
          else if (c=="\\") esc=1
          else if (c==dq) in_dq=0
          continue
        }
        if (in_sq) { out=out c; if (c==sq) in_sq=0; continue }
        if (c=="#") { had_comment=1; break }
        out=out c
        if (c==dq) in_dq=1
        else if (c==sq) in_sq=1
      }
      if (in_sq || in_dq) bad=1
      return out
    }
    function is_header(s,    t,i,c,depth,in_sq,in_dq,esc) {
      t=trim(s)
      if (substr(t,1,1)!="[") return 0
      depth=0; in_sq=0; in_dq=0; esc=0
      for (i=1; i<=length(t); i++) {
        c=substr(t,i,1)
        if (in_dq) {
          if (esc) esc=0
          else if (c=="\\") esc=1
          else if (c==dq) in_dq=0
          continue
        }
        if (in_sq) { if (c==sq) in_sq=0; continue }
        if (c==dq) { in_dq=1; continue }
        if (c==sq) { in_sq=1; continue }
        if (c=="[") depth++
        else if (c=="]") { depth--; if (depth<0) { bad=1; return 0 } }
        else if (depth==0 && c !~ /[ \t]/) { bad=1; return 0 }
      }
      if (in_sq || in_dq || depth!=0) { bad=1; return 0 }
      return 1
    }
    function valid_string_array(s,    t,i,n,c,q,esc,seen,expect_value) {
      t=trim(s); n=length(t)
      if (n<2 || substr(t,1,1)!="[" || substr(t,n,1)!="]") return 0
      i=2; seen=0; expect_value=1
      while (i<n) {
        c=substr(t,i,1)
        if (c ~ /[ \t]/) { i++; continue }
        if (expect_value) {
          if (c==",") return 0
          if (c!=sq && c!=dq) return 0
          q=c; i++; esc=0
          while (i<n) {
            c=substr(t,i,1)
            if (q==dq && esc) { esc=0; i++; continue }
            if (q==dq && c=="\\") { esc=1; i++; continue }
            if (c==q) break
            i++
          }
          if (i>=n || substr(t,i,1)!=q) return 0
          seen=1; expect_value=0; i++; continue
        }
        if (c!=",") return 0
        expect_value=1; i++
      }
      return seen || trim(substr(t,2,n-2))==""
    }
    BEGIN {
      sq=sprintf("%c",39); dq=sprintf("%c",34); root=1; in_anon=0; bad=0; anon_count=0
      if (mode=="fastest") {
        repl["server_names"]="server_names = [" sq "cloudflare" sq ", " sq "google" sq ", " sq "nextdns" sq ", " sq "cloudflare-ipv6" sq "]"
        repl["dnscrypt_servers"]="dnscrypt_servers = true"; repl["doh_servers"]="doh_servers = true"; repl["odoh_servers"]="odoh_servers = false"
        repl["require_dnssec"]="require_dnssec = false"; repl["require_nolog"]="require_nolog = false"; repl["require_nofilter"]="require_nofilter = true"
      } else if (mode=="privacy") {
        repl["server_names"]="server_names = [" sq "quad9-dnscrypt-ip4-filter-pri" sq ", " sq "mullvad-doh" sq ", " sq "adguard-dns" sq "]"
        repl["dnscrypt_servers"]="dnscrypt_servers = true"; repl["doh_servers"]="doh_servers = false"; repl["odoh_servers"]="odoh_servers = false"
        repl["require_dnssec"]="require_dnssec = true"; repl["require_nolog"]="require_nolog = true"; repl["require_nofilter"]="require_nofilter = false"
      } else if (mode=="family") {
        repl["server_names"]="server_names = [" sq "cloudflare-family" sq ", " sq "adguard-dns-family" sq ", " sq "cleanbrowsing-family" sq "]"
        repl["dnscrypt_servers"]="dnscrypt_servers = true"; repl["doh_servers"]="doh_servers = true"; repl["odoh_servers"]="odoh_servers = false"
        repl["require_dnssec"]="require_dnssec = true"; repl["require_nolog"]="require_nolog = true"; repl["require_nofilter"]="require_nofilter = false"
      } else bad=1
    }
    {
      raw=$0
      if (index(raw,"\"\"\"") || index(raw,sq sq sq)) bad=1
      code=code_without_comment(raw); t=trim(code); header=is_header(code)
      if (in_anon) {
        if (!header) next
        in_anon=0
      }
      if (header) {
        root=0
        if (t=="[anonymized_dns]") { anon_count++; in_anon=1; next }
      }
      key=""
      if (root) {
        if (code ~ /^[ \t]*server_names[ \t]*=/) key="server_names"
        else if (code ~ /^[ \t]*dnscrypt_servers[ \t]*=/) key="dnscrypt_servers"
        else if (code ~ /^[ \t]*doh_servers[ \t]*=/) key="doh_servers"
        else if (code ~ /^[ \t]*odoh_servers[ \t]*=/) key="odoh_servers"
        else if (code ~ /^[ \t]*require_dnssec[ \t]*=/) key="require_dnssec"
        else if (code ~ /^[ \t]*require_nolog[ \t]*=/) key="require_nolog"
        else if (code ~ /^[ \t]*require_nofilter[ \t]*=/) key="require_nofilter"
      }
      if (key!="") {
        count[key]++
        rhs=code; sub(/^[^=]*=[ \t]*/,"",rhs); rhs=trim(rhs)
        if (had_comment) bad=1
        if (key=="server_names") { if (!valid_string_array(rhs)) bad=1 }
        else if (rhs!="true" && rhs!="false") bad=1
        match(raw,/^[ \t]*/); indent=substr(raw,1,RLENGTH)
        print indent repl[key]
        next
      }
      print raw
    }
    END {
      required[1]="server_names"; required[2]="dnscrypt_servers"; required[3]="doh_servers"; required[4]="odoh_servers"
      required[5]="require_dnssec"; required[6]="require_nolog"; required[7]="require_nofilter"
      for (i=1;i<=7;i++) if (count[required[i]]!=1) bad=1
      if (anon_count>1) bad=1
      if (bad) exit 42
      if (mode=="privacy") {
        print "[anonymized_dns]"
        print "  routes = ["
        print "    { server_name = " sq "*" sq ", via = [" sq "anon-cs-fr" sq ", " sq "anon-cs-de" sq ", " sq "anon-tiarap" sq ", " sq "anon-kama" sq "] }"
        print "  ]"
      }
    }
  ' "$_rewrite_input" > "$_rewrite_output"
}

quick_mode() {
  _mode="${2:-}"
  case "$_mode" in
    fastest|privacy|family) ;;
    *) echo "Unknown mode: $_mode. Use: fastest|privacy|family"; return 1 ;;
  esac
  if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    runtime_config_inputs_are_trusted
  else
    ensure_config
  fi || {
    echo "The live configuration ownership or permissions are unsafe; original file was kept."
    return 1
  }
  # Keep validation and atomic rename in the live TOML directory. Upstream
  # resolves relative source/cache paths from the config file's directory. The
  # root-only directory trust check and O_EXCL mktemp files
  # prevent UID 3003 from replacing a root staging/backup/restore inode.
  config_dir_is_trusted || {
    echo "The configuration directory ownership or permissions are unsafe; original file was kept."
    return 1
  }
  _quick_stage=$(create_secure_config_temp '.dnscrypt-proxy.toml.quick-stage') || {
    echo "Failed to create a secure same-directory staging file."
    return 1
  }
  _quick_stage_identity=$(secure_config_temp_identity "$_quick_stage") || {
    rm -f "$_quick_stage"
    return 1
  }
  _quick_backup=$(create_secure_config_temp 'dnscrypt-proxy.toml.bak.quick') || {
    rm -f "$_quick_stage"
    echo "Failed to create a secure configuration backup."
    return 1
  }
  _quick_backup_identity=$(secure_config_temp_identity "$_quick_backup") || {
    rm -f "$_quick_stage" "$_quick_backup"
    return 1
  }
  if ! cat "$CONFIG_FILE" > "$_quick_backup" \
    || ! secure_config_temp_valid "$_quick_backup" "$_quick_backup_identity" 600; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "Failed to back up the current configuration."
    return 1
  fi
  if ! rewrite_quick_mode_toml "$CONFIG_FILE" "$_quick_stage" "$_mode" \
    || ! secure_config_temp_valid "$_quick_stage" "$_quick_stage_identity" 600; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "The TOML uses missing, duplicate, multiline, or ambiguous preset-owned fields; original file was kept."
    return 1
  fi
  if ! prepare_secure_config_temp_for_proxy "$_quick_stage" "$_quick_stage_identity"; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "The staged preset did not retain its protected inode and permissions; original file was kept."
    return 1
  fi
  if ! ensure_binary; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "dnscrypt-proxy is unavailable; the staged preset was not installed."
    return 1
  fi
  if ! validate_dnscrypt_config "$_quick_stage" "$CONTROL_LOG" dnscrypt-quick-check; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "dnscrypt-proxy rejected the staged preset ($CONFIG_CHECK_FAILURE); original file was kept."
    return 1
  fi
  if ! secure_config_temp_valid "$_quick_stage" "$_quick_stage_identity" "$(managed_config_mode)"; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "The staged preset was replaced during validation; original file was kept."
    return 1
  fi
  _quick_was_running=0
  is_dnscrypt_running && _quick_was_running=1
  if ! secure_config_temp_valid "$_quick_stage" "$_quick_stage_identity" "$(managed_config_mode)" \
    || ! mv -f "$_quick_stage" "$CONFIG_FILE"; then
    rm -f "$_quick_stage" "$_quick_backup"
    echo "Failed to atomically install the staged preset; original file was kept."
    return 1
  fi
  prune_config_backups
  if [ "$_quick_was_running" -eq 1 ] && ! restart_service >/dev/null 2>&1; then
    _quick_rollback_ok=0
    _quick_restore=$(create_secure_config_temp '.dnscrypt-proxy.toml.quick-restore' 2>/dev/null || true)
    if [ -n "$_quick_restore" ]; then
      _quick_restore_identity=$(secure_config_temp_identity "$_quick_restore" 2>/dev/null || true)
      if [ -n "$_quick_restore_identity" ] \
        && secure_config_temp_valid "$_quick_backup" "$_quick_backup_identity" 600 \
        && cat "$_quick_backup" > "$_quick_restore" \
        && secure_config_temp_valid "$_quick_restore" "$_quick_restore_identity" 600 \
        && prepare_secure_config_temp_for_proxy "$_quick_restore" "$_quick_restore_identity" \
        && secure_config_temp_valid "$_quick_restore" "$_quick_restore_identity" "$(managed_config_mode)" \
        && mv -f "$_quick_restore" "$CONFIG_FILE"; then
        if start_service >/dev/null 2>&1; then
          _quick_rollback_ok=1
        fi
      fi
    fi
    rm -f "$_quick_restore"
    if [ "$_quick_rollback_ok" -eq 1 ]; then
      echo "The preset restart failed; the previous TOML was restored."
      return 1
    fi
    log_msg "$CONTROL_LOG" "Preset restart failed and rollback_failed; configuration recovery is required."
    echo "The preset restart failed; rollback_failed and configuration recovery is required."
    return 3
  fi
  case "$_mode" in
    fastest) echo "Applied mode: fastest (low latency, no filtering)" ;;
    privacy) echo "Applied mode: privacy (anonymized DNSCrypt, no-log, DNSSEC)" ;;
    family) echo "Applied mode: family (family-safe filtering, DNSSEC)" ;;
  esac
}

get_current_mode() {
  # Detect the resolver preset. This is deliberately distinct from the
  # strict/upstream_only Android integration mode returned by get-dns-mode.
  ensure_config || {
    echo "The live configuration inputs are unsafe."
    return 1
  }
  _servers=$(awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*server_names[[:space:]]*=/ { print; exit }
  ' "$CONFIG_FILE" 2>/dev/null)
  _anon="false"
  grep -q '^[[:space:]]*\[anonymized_dns\][[:space:]]*$' "$CONFIG_FILE" 2>/dev/null && _anon="true"
  _nofilter=$(awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*require_nofilter[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { found=1 }
    END { print found + 0 }
  ' "$CONFIG_FILE" 2>/dev/null)
  
  if [ "$_anon" = "true" ]; then
    echo "privacy"
  elif echo "$_servers" | grep -q 'family\|cleanbrowsing'; then
    echo "family"
  elif [ "$_nofilter" -gt 0 ]; then
    echo "fastest"
  else
    echo "custom"
  fi
}

export_config() {
  # Export full config as JSON (config + blocklists + resolver selection)
  ensure_config || {
    echo "The live configuration inputs are unsafe; nothing was exported."
    return 1
  }
  _config_b64=$(base64_encode_file "$CONFIG_FILE") || { echo "No working base64 encoder is available."; return 1; }
  _blocked_names_b64=$(base64_encode_file "$CONFIG_DIR/blocked-names.txt") || return 1
  _allowed_names_b64=$(base64_encode_file "$CONFIG_DIR/allowed-names.txt") || return 1
  _blocked_ips_b64=$(base64_encode_file "$CONFIG_DIR/blocked-ips.txt") || return 1
  _allowed_ips_b64=$(base64_encode_file "$CONFIG_DIR/allowed-ips.txt") || return 1
  _subs_b64=""
  if [ -f "$CONFIG_DIR/subscriptions.json" ]; then
    _subs_b64=$(base64_encode_file "$CONFIG_DIR/subscriptions.json") || return 1
  fi
  printf '{"version":1,"config":"%s","blocked_names":"%s","allowed_names":"%s","blocked_ips":"%s","allowed_ips":"%s","subscriptions":"%s"}\n' \
    "$_config_b64" "$_blocked_names_b64" "$_allowed_names_b64" "$_blocked_ips_b64" "$_allowed_ips_b64" "$_subs_b64"
}

import_config_b64() {
  # Stage the complete import before replacing any live file. Decoding directly
  # to files preserves empty lists and trailing newlines exactly.
  _data_b64="${2:-}"
  [ -z "$_data_b64" ] && { echo "Missing import data."; return 1; }
  ensure_config || {
    echo "The live configuration inputs are unsafe; import was refused."
    return 1
  }
  _import_dir="$RUN_DIR/import.$$"
  rm -rf "$_import_dir"
  mkdir -p "$_import_dir" || { echo "Failed to create import workspace."; return 1; }
  if ! printf '%s' "$_data_b64" | base64_decode > "$_import_dir/import.json" 2>/dev/null; then
    rm -rf "$_import_dir"
    echo "Failed to decode import data."
    return 1
  fi
  [ -s "$_import_dir/import.json" ] || {
    rm -rf "$_import_dir"
    echo "Failed to decode import data."
    return 1
  }

  for _field in config blocked_names allowed_names blocked_ips allowed_ips subscriptions; do
    if ! grep -q "\"$_field\"[[:space:]]*:" "$_import_dir/import.json" 2>/dev/null; then
      if [ "$_field" = "config" ]; then
        rm -rf "$_import_dir"
        echo "Import data is missing the config field."
        return 1
      fi
      continue
    fi
    _encoded=$(sed -n "s/.*\"$_field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      "$_import_dir/import.json" | head -n 1)
    if ! printf '%s' "$_encoded" | base64_decode > "$_import_dir/$_field" 2>/dev/null; then
      rm -rf "$_import_dir"
      echo "Failed to decode import field: $_field"
      return 1
    fi
  done

  [ -s "$_import_dir/config" ] || {
    rm -rf "$_import_dir"
    echo "Imported configuration is empty."
    return 1
  }
  enforce_dnscrypt_user "$_import_dir/config" || {
    rm -rf "$_import_dir"
    echo "Failed to enforce the dedicated dnscrypt-proxy user."
    return 1
  }
  _import_config_stage=$(create_secure_config_temp '.dnscrypt-proxy.toml.import') || {
    rm -rf "$_import_dir"
    echo "Failed to create a secure import staging file."
    return 1
  }
  _import_stage_identity=$(secure_config_temp_identity "$_import_config_stage") || {
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    return 1
  }
  if ! cat "$_import_dir/config" > "$_import_config_stage" \
    || ! secure_config_temp_valid "$_import_config_stage" "$_import_stage_identity" 600 \
    || ! prepare_secure_config_temp_for_proxy "$_import_config_stage" "$_import_stage_identity"; then
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    echo "Failed to protect the imported configuration."
    return 1
  fi
  if ! ensure_binary; then
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    echo "dnscrypt-proxy is unavailable; the imported configuration was not installed."
    return 1
  fi
  if ! validate_dnscrypt_config "$_import_config_stage" "$CONTROL_LOG" dnscrypt-import-check; then
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    echo "dnscrypt-proxy rejected the imported configuration ($CONFIG_CHECK_FAILURE)."
    return 1
  fi
  secure_config_temp_valid "$_import_config_stage" "$_import_stage_identity" "$(managed_config_mode)" || {
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    echo "The imported configuration was replaced during validation."
    return 1
  }

  _backup=$(create_secure_config_temp 'dnscrypt-proxy.toml.bak.import') || {
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    echo "Failed to create a secure configuration backup."
    return 1
  }
  _import_backup_identity=$(secure_config_temp_identity "$_backup") || {
    rm -f "$_import_config_stage" "$_backup"
    rm -rf "$_import_dir"
    return 1
  }
  if ! cat "$CONFIG_FILE" > "$_backup" \
    || ! secure_config_temp_valid "$_backup" "$_import_backup_identity" 600; then
    rm -f "$_import_config_stage" "$_backup"
    rm -rf "$_import_dir"
    echo "Failed to back up the current configuration."
    return 1
  fi
  prune_config_backups
  if ! secure_config_temp_valid "$_import_config_stage" "$_import_stage_identity" "$(managed_config_mode)" \
    || ! mv -f "$_import_config_stage" "$CONFIG_FILE"; then
    rm -f "$_import_config_stage"
    rm -rf "$_import_dir"
    echo "Failed to install imported configuration."
    return 1
  fi

  for _field in blocked_names allowed_names blocked_ips allowed_ips; do
    [ -f "$_import_dir/$_field" ] || continue
    case "$_field" in
      blocked_names) _target="$CONFIG_DIR/blocked-names.txt" ;;
      allowed_names) _target="$CONFIG_DIR/allowed-names.txt" ;;
      blocked_ips) _target="$CONFIG_DIR/blocked-ips.txt" ;;
      allowed_ips) _target="$CONFIG_DIR/allowed-ips.txt" ;;
    esac
    if ! prepare_managed_input_for_proxy "$_import_dir/$_field" \
      || ! mv -f "$_import_dir/$_field" "$_target"; then
      rm -rf "$_import_dir"
      echo "Failed to install imported field: $_field"
      return 1
    fi
  done
  if [ -f "$_import_dir/subscriptions" ]; then
    if [ -s "$_import_dir/subscriptions" ]; then
      if ! prepare_control_only_input "$_import_dir/subscriptions" \
        || ! mv -f "$_import_dir/subscriptions" "$CONFIG_DIR/subscriptions.json"; then
        rm -rf "$_import_dir"
        echo "Failed to install imported subscriptions."
        return 1
      fi
    else
      rm -f "$CONFIG_DIR/subscriptions.json"
    fi
  fi
  rm -rf "$_import_dir"
  log_msg "$CONTROL_LOG" "Config imported from backup (previous saved as $_backup)"
  echo "Config imported successfully. Previous config backed up as $_backup"
}

get_subscriptions() {
  # Return subscription list JSON
  ensure_config || { echo '[]'; return 1; }
  if [ -f "$CONFIG_DIR/subscriptions.json" ]; then
    cat "$CONFIG_DIR/subscriptions.json"
  else
    echo '[]'
  fi
}

save_subscriptions_b64() {
  # Save subscriptions from base64 input
  _data_b64="${2:-}"
  [ -z "$_data_b64" ] && { echo "Missing data."; return 1; }
  ensure_config || {
    echo "The live configuration inputs are unsafe; subscriptions were not changed."
    return 1
  }
  _tmp_subscriptions="$RUN_DIR/subscriptions.$$.json"
  if ! printf '%s' "$_data_b64" | base64_decode > "$_tmp_subscriptions" 2>/dev/null; then
    rm -f "$_tmp_subscriptions"
    echo "Failed to decode subscriptions."
    return 1
  fi
  if ! grep -Eq '^[[:space:]]*\[.*\][[:space:]]*$' "$_tmp_subscriptions" 2>/dev/null; then
    rm -f "$_tmp_subscriptions"
    echo "Subscriptions must be a JSON array."
    return 1
  fi
  if ! prepare_control_only_input "$_tmp_subscriptions" \
    || ! mv -f "$_tmp_subscriptions" "$CONFIG_DIR/subscriptions.json"; then
    rm -f "$_tmp_subscriptions"
    echo "Failed to save subscriptions."
    return 1
  fi
  echo "Subscriptions saved."
}

save_list_b64() {
  [ "$#" -ge 3 ] || {
    echo "Missing list payload."
    return 1
  }
  _list_kind="${2:-}"
  _list_payload="${3:-}"
  case "$_list_kind" in
    blocked-names) _list_target="$CONFIG_DIR/blocked-names.txt" ;;
    allowed-names) _list_target="$CONFIG_DIR/allowed-names.txt" ;;
    blocked-ips) _list_target="$CONFIG_DIR/blocked-ips.txt" ;;
    allowed-ips) _list_target="$CONFIG_DIR/allowed-ips.txt" ;;
    *) echo "Unknown list type."; return 1 ;;
  esac
  ensure_config || return 1
  _list_tmp="$RUN_DIR/list.$$.new"
  if ! printf '%s' "$_list_payload" | base64_decode > "$_list_tmp" 2>/dev/null; then
    rm -f "$_list_tmp"
    echo "Failed to decode list data."
    return 1
  fi
  _list_size=$(wc -c < "$_list_tmp" 2>/dev/null || echo 0)
  case "$_list_size" in
    ""|*[!0-9]*) rm -f "$_list_tmp"; echo "Unable to validate list size."; return 1 ;;
  esac
  if [ "$_list_size" -gt 10485760 ]; then
    rm -f "$_list_tmp"
    echo "List exceeds the 10 MiB safety limit."
    return 1
  fi
  prepare_managed_input_for_proxy "$_list_tmp" || {
    rm -f "$_list_tmp"
    echo "Failed to set list permissions."
    return 1
  }
  mv -f "$_list_tmp" "$_list_target" || {
    rm -f "$_list_tmp"
    echo "Failed to install the list."
    return 1
  }
  log_msg "$CONTROL_LOG" "Saved $_list_kind list ($_list_size bytes)."
  echo "List saved."
}

apply_subscriptions() {
  # Download all enabled subscription lists and merge into blocked-names.txt
  ensure_config || {
    echo "The live configuration inputs are unsafe; subscriptions were not applied."
    return 1
  }
  [ ! -f "$CONFIG_DIR/subscriptions.json" ] && { echo "No subscriptions configured."; return 0; }
  # Parse JSON subscriptions (simple line-based extraction for busybox)
  _subs_file="$CONFIG_DIR/subscriptions.json"
  _merged="$CONFIG_DIR/blocked-names.txt"
  _begin_marker='## BEGIN dnscrypt-proxy-root managed subscriptions'
  _end_marker='## END dnscrypt-proxy-root managed subscriptions'
  _pairs_file="$RUN_DIR/subscription-pairs.$$"
  _download_file="$RUN_DIR/subscription-download.$$"
  _generated_file="$RUN_DIR/subscription-generated.$$"
  _user_file="$RUN_DIR/subscription-user.$$"
  _final_file="$RUN_DIR/subscription-final.$$"
  # Parse JSON object-by-object so url/enabled always come from the same entry,
  # regardless of field order. Uses RS/RSTART/RLENGTH only, which busybox awk
  # supports (the 3-argument match() capture form does not exist there).
  awk '
    BEGIN { RS="}" }
    {
      url=""; enabled="false"
      if (match($0, /"url"[ \t]*:[ \t]*"[^"]*"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"url"[ \t]*:[ \t]*"/, "", s)
        sub(/"$/, "", s)
        url = s
      }
      if ($0 ~ /"enabled"[ \t]*:[ \t]*true/) enabled="true"
      if (url != "") print url "|" enabled
    }
  ' "$_subs_file" > "$_pairs_file"
  printf '%s\n' "$_begin_marker" > "$_generated_file"
  printf '## Auto-generated from subscriptions on %s\n' "$(date +%Y-%m-%d)" >> "$_generated_file"
  _i=0
  _download_failed=0
  while IFS='|' read -r _url _en; do
    [ "$_en" = "true" ] || continue
    [ -n "$_url" ] || continue
    case "$_url" in
      https://*) ;;
      *) log_msg "$CONTROL_LOG" "Subscription URLs must use HTTPS."; _download_failed=1; break ;;
    esac
    # Only allow URLs built from safe characters. The URL is quoted as well, so
    # it cannot become a downloader option or shell expression.
    case "$_url" in
      *[!a-zA-Z0-9:/._?=\&%~+#@,-]*) log_msg "$CONTROL_LOG" "Skipping unsafe subscription URL."; _download_failed=1; break ;;
    esac
    _i=$((_i + 1))
    if ! download_file "$_url" "$_download_file" || [ ! -s "$_download_file" ]; then
      log_msg "$CONTROL_LOG" "Failed to download subscription $_i."
      _download_failed=1
      break
    fi
    _download_size=$(wc -c < "$_download_file" 2>/dev/null || echo 0)
    case "$_download_size" in
      ""|*[!0-9]*) _download_failed=1; break ;;
    esac
    if [ "$_download_size" -gt 10485760 ]; then
      log_msg "$CONTROL_LOG" "Subscription $_i exceeds the 10 MiB size limit."
      _download_failed=1
      break
    fi
    printf '# subscription-%d: %s\n' "$_i" "$_url" >> "$_generated_file"
    awk '{ sub(/\r$/, ""); if ($0 !~ /^[[:space:]]*($|#|!)/) print }' \
      "$_download_file" >> "$_generated_file"
  done < "$_pairs_file"
  rm -f "$_pairs_file" "$_download_file"

  if [ "$_download_failed" -ne 0 ]; then
    rm -f "$_generated_file" "$_user_file" "$_final_file"
    echo "Failed to apply subscriptions; the previous blocklist was kept."
    return 1
  fi
  printf '%s\n' "$_end_marker" >> "$_generated_file"

  # Preserve manual rules outside the managed section. For the legacy format,
  # the old auto-generated header always began a tail section, so discard that
  # tail once during migration instead of retaining stale subscription rules.
  awk -v begin="$_begin_marker" -v end="$_end_marker" '
    $0 == begin { managed=1; next }
    $0 == end { managed=0; next }
    !managed && /^## Auto-generated from subscriptions on / { legacy=1; next }
    managed || legacy { next }
    { print }
  ' "$_merged" 2>/dev/null > "$_user_file"
  : > "$_final_file"
  if [ -s "$_user_file" ]; then
    cat "$_user_file" >> "$_final_file"
    printf '\n' >> "$_final_file"
  fi
  cat "$_generated_file" >> "$_final_file"
  if ! prepare_managed_input_for_proxy "$_final_file" \
    || ! mv -f "$_final_file" "$_merged"; then
    rm -f "$_generated_file" "$_user_file" "$_final_file"
    echo "Failed to install the merged subscription blocklist."
    return 1
  fi
  rm -f "$_generated_file" "$_user_file"
  _count=$(awk '$0 !~ /^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' "$_merged" 2>/dev/null)
  _count=${_count:-0}
  if is_dnscrypt_running; then
    if ! restart_service >/dev/null 2>&1; then
      log_msg "$CONTROL_LOG" "Subscriptions were saved, but dnscrypt-proxy failed to restart."
      echo "Subscriptions were saved, but dnscrypt-proxy failed to restart."
      return 1
    fi
  fi
  log_msg "$CONTROL_LOG" "Subscriptions applied: $_count active entries in blocked-names.txt"
  echo "Subscriptions applied. Total entries: $_count"
}

empty_query_stats() {
  echo '{"totalQueries":0,"blockedCount":0,"blockRate":0,"uniqueDomains":0,"topDomains":[],"topBlocked":[],"timeline":[]}'
}

query_stats() {
  ensure_config || { echo '{"error":"unsafe_configuration"}'; return 1; }
  if ! grep -q '^[[:space:]]*\[query_log\][[:space:]]*$' "$CONFIG_FILE" 2>/dev/null; then
    empty_query_stats
    return 0
  fi
  _query_format=$(sed -n '/^[[:space:]]*\[query_log\][[:space:]]*$/,/^[[:space:]]*\[/p' "$CONFIG_FILE" 2>/dev/null \
    | sed -n "s/^[[:space:]]*format[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
    | head -n 1)
  [ -n "$_query_format" ] || _query_format="tsv"
  if [ "$_query_format" != "tsv" ]; then
    log_msg "$CONTROL_LOG" "query-stats supports TSV query logs; configured format is $_query_format."
    empty_query_stats
    return 0
  fi
  QUERY_LOG=$(query_log_path 2>/dev/null || true)
  if [ ! -e "$QUERY_LOG" ] && [ ! -L "$QUERY_LOG" ]; then
    empty_query_stats
    return 0
  fi
  if ! log_file_is_safe_for_read "$QUERY_LOG"; then
    echo '{"error":"unsafe_query_log"}'
    return 1
  fi
  _query_snapshot=$(snapshot_dnscrypt_data_log "$QUERY_LOG" 2>/dev/null) || {
    echo '{"error":"unsafe_query_log"}'
    return 1
  }
  if [ ! -s "$_query_snapshot" ]; then
    rm -f "$_query_snapshot"
    empty_query_stats
    return 0
  fi
  # Official TSV fields: timestamp, client_ip, query_name, query_type,
  # return_code, duration, server, relay. A query is blocked only when the
  # return-code field is exactly REJECT or DROP.
  total=$(awk -F'\t' 'NF >= 5 { n++ } END { print n + 0 }' "$_query_snapshot" 2>/dev/null)
  blocked=$(awk -F'\t' 'NF >= 5 && ($5 == "REJECT" || $5 == "DROP") { n++ } END { print n + 0 }' "$_query_snapshot" 2>/dev/null)
  total=${total:-0}
  blocked=${blocked:-0}
  if [ "$total" -gt 0 ]; then
    rate=$(awk -v total="$total" -v blocked="$blocked" 'BEGIN { printf "%.1f", blocked * 100 / total }')
  else
    rate="0.0"
  fi
  unique=$(awk -F'\t' 'NF >= 5 { print $3 }' "$_query_snapshot" 2>/dev/null | sort -u | wc -l || echo 0)
  # Top domains
  top_domains=$(awk -F'\t' 'NF >= 5 { print $3 }' "$_query_snapshot" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{ count=$1; $1=""; sub(/^[[:space:]]+/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "{\"domain\":\"%s\",\"count\":%d},", $0, count }')
  top_domains="[${top_domains%,}]"
  # Top blocked
  top_blocked=$(awk -F'\t' 'NF >= 5 && ($5 == "REJECT" || $5 == "DROP") { print $3 }' "$_query_snapshot" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{ count=$1; $1=""; sub(/^[[:space:]]+/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "{\"domain\":\"%s\",\"count\":%d},", $0, count }')
  top_blocked="[${top_blocked%,}]"
  # Timeline by hour
  timeline=$(awk -F'\t' 'NF >= 5 { h=substr($1, 13, 2); if (h ~ /^[0-2][0-9]$/) { total[h]++; if ($5 == "REJECT" || $5 == "DROP") blocked[h]++ } } END { for (i=0; i<24; i++) { hh=sprintf("%02d", i); printf "{\"hour\":\"%s\",\"queries\":%d,\"blocked\":%d},", hh, total[hh]+0, blocked[hh]+0 } }' "$_query_snapshot" 2>/dev/null)
  timeline="[${timeline%,}]"
  rm -f "$_query_snapshot"
  printf '{"totalQueries":%d,"blockedCount":%d,"blockRate":%s,"uniqueDomains":%d,"topDomains":%s,"topBlocked":%s,"timeline":%s}\n' \
    "$total" "$blocked" "$rate" "$unique" "$top_domains" "$top_blocked" "$timeline"
}

# Generate a random DNS label made only of [a-z0-9-] characters.
random_label() {
  _r=""
  if [ -r /dev/urandom ]; then
    _r=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | dd bs=1 count=12 2>/dev/null)
  fi
  if [ -z "$_r" ]; then
    _r=$(printf '%s%s' "$$" "$(date +%s 2>/dev/null || echo 0)" | tr -dc 'a-z0-9')
  fi
  printf 'leaktest-%s' "$_r"
}

# Trigger a resolution over the system DNS path (subject to iptables redirection)
# so it mimics an ordinary app query rather than talking to dnscrypt directly.
resolve_via_system() {
  if has_cmd nslookup; then
    bounded_diagnostic_command 8 nslookup "$1" >/dev/null 2>&1 || true
  elif has_cmd ping; then
    bounded_diagnostic_command 8 ping -c 1 -W 2 "$1" >/dev/null 2>&1 || true
  elif has_cmd getent; then
    bounded_diagnostic_command 8 getent hosts "$1" >/dev/null 2>&1 || true
  fi
  return 0
}

leak_test() {
  _leak_mode=$(get_dns_mode 2>/dev/null) || {
    echo '{"status":"error","reason":"invalid_dns_mode"}'
    return 0
  }
  if [ "$_leak_mode" = "upstream_only" ]; then
    echo '{"status":"not_applicable","reason":"upstream_only_has_no_global_dns_capture"}'
    return 0
  fi
  ensure_config || {
    echo '{"status":"error","reason":"unsafe_configuration"}'
    return 0
  }
  # Query log must be enabled for the comparison to work.
  if ! grep -q '^[[:space:]]*\[query_log\]' "$CONFIG_FILE" 2>/dev/null; then
    echo '{"status":"error","reason":"query_log_disabled"}'
    return 0
  fi
  _qlog=$(query_log_path 2>/dev/null || true)
  [ -n "$_qlog" ] || {
    echo '{"status":"error","reason":"query_log_path_missing"}'
    return 0
  }
  if { [ -e "$_qlog" ] || [ -L "$_qlog" ]; } && ! log_file_is_safe_for_read "$_qlog"; then
    echo '{"status":"error","reason":"unsafe_query_log"}'
    return 0
  fi
  # nx.log captures NXDOMAIN responses; random subdomains resolve to NXDOMAIN, so
  # searching both logs avoids a false "leaking" verdict.
  _nxlog=""
  if grep -q '^[[:space:]]*\[nx_log\][[:space:]]*$' "$CONFIG_FILE" 2>/dev/null; then
    _nxlog=$(nx_log_path 2>/dev/null || true)
    if [ -n "$_nxlog" ] && { [ -e "$_nxlog" ] || [ -L "$_nxlog" ]; } \
      && ! log_file_is_safe_for_read "$_nxlog"; then
      echo '{"status":"error","reason":"unsafe_nx_log"}'
      return 0
    fi
  fi

  _domains=""
  _i=0
  while [ "$_i" -lt 4 ]; do
    _label=$(random_label)
    case "$_label" in
      *[!a-z0-9-]*) continue ;;
    esac
    _domain="${_label}.example.com"
    _domains="$_domains $_domain"
    resolve_via_system "$_domain"
    _i=$((_i + 1))
  done

  # Give dnscrypt-proxy a moment to flush the query log.
  sleep 2

  _qlog_snapshot=$(snapshot_dnscrypt_data_log "$_qlog" 2>/dev/null) || {
    echo '{"status":"error","reason":"unsafe_query_log"}'
    return 0
  }
  _nxlog_snapshot=""
  if [ -n "$_nxlog" ]; then
    _nxlog_snapshot=$(snapshot_dnscrypt_data_log "$_nxlog" 2>/dev/null) || {
      rm -f "$_qlog_snapshot"
      echo '{"status":"error","reason":"unsafe_nx_log"}'
      return 0
    }
  fi

  _matched=0
  _json_domains=""
  _first=1
  for _d in $_domains; do
    _hit=0
    if grep -qF "$_d" "$_qlog_snapshot" 2>/dev/null; then
      _hit=1
    elif [ -n "$_nxlog_snapshot" ] && grep -qF "$_d" "$_nxlog_snapshot" 2>/dev/null; then
      _hit=1
    fi
    [ "$_hit" -eq 1 ] && _matched=$((_matched + 1))
    [ $_first -eq 0 ] && _json_domains="$_json_domains,"
    _json_domains="$_json_domains\"$_d\""
    _first=0
  done
  rm -f "$_qlog_snapshot"
  [ -z "$_nxlog_snapshot" ] || rm -f "$_nxlog_snapshot"

  if [ "$_matched" -eq 4 ]; then
    _status="protected"
  elif [ "$_matched" -eq 0 ]; then
    _status="leaking"
  else
    _status="partial"
  fi
  printf '{"status":"%s","tested":4,"matched":%d,"domains":[%s]}\n' \
    "$_status" "$_matched" "$_json_domains"
}

case "$ACTION" in
  start|stop|restart|apply-iptables|remove-iptables|set-dns-mode|get-config|save-config-b64|set-resolvers|quick-mode|import-config-b64|save-list-b64|save-subscriptions-b64|apply-subscriptions)
    if [ "${DNSCRYPT_CONTROL_LOCK_HELD:-0}" = "1" ]; then
      inherited_control_lock_valid
      _control_lock_status=$?
      if [ "$_control_lock_status" -ne 0 ]; then
        echo "The inherited dnscrypt-proxy control lock is invalid."
        exit 1
      fi
    else
      acquire_control_lock
      _control_lock_status=$?
    fi
    case "$_control_lock_status" in
      0) ;;
      2)
        echo "Another dnscrypt-proxy control operation is running."
        exit 2
        ;;
      *)
        echo "Failed to acquire the dnscrypt-proxy control lock."
        exit 1
        ;;
    esac
    ;;
esac

case "$ACTION" in
  start) start_service ;;
  stop) stop_service ;;
  shutdown-stop) shutdown_stop_service ;;
  restart) restart_service ;;
  status) print_status ;;
  health) protection_health ;;
  apply-iptables) apply_selected_policy ;;
  remove-iptables) remove_iptables ;;
  get-dns-mode) get_dns_mode ;;
  set-dns-mode) set_dns_mode "$@" ;;
  service-state) service_state ;;
  probe-upstream) probe_upstream ;;
  update) sh "$MODDIR/scripts/update-dnscrypt.sh" force ;;
  check-update) sh "$MODDIR/scripts/update-dnscrypt.sh" check ;;
  auto-update) sh "$MODDIR/scripts/update-dnscrypt.sh" auto ;;
  get-config)
    ensure_config || {
      echo "The live configuration inputs are unsafe."
      exit 1
    }
    cat "$CONFIG_FILE"
    ;;
  save-config-b64) save_config_b64 "$@" ;;
  logs) show_logs "$@" ;;
  query-stats) query_stats ;;
  dns-test) dns_test "$@" ;;
  leak-test) leak_test ;;
  list-resolvers) list_resolvers ;;
  set-resolvers) set_resolvers "$@" ;;
  ping-resolver) ping_resolver "$@" ;;
  ping-all) ping_all_resolvers ;;
  protocol-status) protocol_status ;;
  quick-mode) quick_mode "$@" ;;
  get-mode) get_current_mode ;;
  export-config) export_config ;;
  import-config-b64) import_config_b64 "$@" ;;
  get-subscriptions) get_subscriptions ;;
  save-list-b64) save_list_b64 "$@" ;;
  save-subscriptions-b64) save_subscriptions_b64 "$@" ;;
  apply-subscriptions) apply_subscriptions ;;
  *)
    echo "Usage: $0 {start|stop|shutdown-stop|restart|status|health|service-state|probe-upstream|apply-iptables|remove-iptables|get-dns-mode|set-dns-mode|update|check-update|auto-update|get-config|save-config-b64|save-list-b64|logs|query-stats|dns-test|leak-test|list-resolvers|set-resolvers|ping-resolver|ping-all|protocol-status|quick-mode|get-mode|export-config|import-config-b64|get-subscriptions|save-subscriptions-b64|apply-subscriptions}"
    exit 1
    ;;
esac
