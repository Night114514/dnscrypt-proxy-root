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
  if [ ! -x "$DNSCRYPT_BIN" ]; then
    # start_service already owns the control lock. Pass that exact inherited
    # descriptor into the updater so its short commit phase cannot deadlock on
    # the parent shell while recovering a binary missing after installation.
    DNSCRYPT_CONTROL_LOCK_HELD=1 \
      sh "$MODDIR/scripts/update-dnscrypt.sh" install >> "$UPDATE_LOG" 2>&1 || return 1
  fi
  [ -x "$DNSCRYPT_BIN" ]
}

enforce_dnscrypt_user() {
  _user_config="$1"
  if [ "$(grep -c "^[[:space:]]*user_name[[:space:]]*=[[:space:]]*['\"]${DNSCRYPT_UID}['\"][[:space:]]*$" \
      "$_user_config" 2>/dev/null || echo 0)" = "1" ] \
      && [ "$(grep -c '^[[:space:]]*user_name[[:space:]]*=' "$_user_config" 2>/dev/null || echo 0)" = "1" ]; then
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
  if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF'
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
log_file = 'dnscrypt-proxy.log'
use_syslog = false

[query_log]
  file = 'query.log'
  format = 'tsv'

[nx_log]
  file = 'nx.log'
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
  cache_file = 'public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

  [sources.'relays']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/relays.md', 'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/relays.md']
  cache_file = 'relays.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

  [sources.'odoh-servers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-servers.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-servers.md']
  cache_file = 'odoh-servers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

  [sources.'odoh-relays']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-relays.md']
  cache_file = 'odoh-relays.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 73
  prefix = ''

[static]
EOF
  fi
  enforce_dnscrypt_user "$CONFIG_FILE" || return 1
  chmod 0644 "$CONFIG_FILE" 2>/dev/null || true
  for f in allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt; do
    [ -f "$CONFIG_DIR/$f" ] || : > "$CONFIG_DIR/$f"
  done
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
  # route_localnet must be enabled so the kernel does not drop packets DNAT'd to
  # 127.0.0.1 from the OUTPUT chain.
  if ! save_route_localnet_state; then
    log_msg "$CONTROL_LOG" "Unable to preserve route_localnet; DNS redirection was not installed."
    return 1
  fi
  sysctl -w net.ipv4.conf.all.route_localnet=1 2>/dev/null \
    || echo 1 > "$PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet" 2>/dev/null || {
      log_msg "$CONTROL_LOG" "Unable to enable route_localnet; DNS redirection was not installed."
      restore_route_localnet_state
      return 1
    }

  iptables -t nat -N "$CHAIN" >/dev/null 2>&1 \
    || iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || {
      log_msg "$CONTROL_LOG" "Unable to create or access the IPv4 DNS chain."
      remove_iptables >/dev/null 2>&1 || true
      return 1
    }
  iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || {
    remove_iptables >/dev/null 2>&1 || true
    return 1
  }
  # Only the dedicated dnscrypt-proxy UID may bypass the port-53 redirect for
  # bootstrap traffic. Destination-IP exemptions would let every app send
  # plaintext DNS directly to the allowlisted resolver.
  iptables -t nat -A "$CHAIN" -m owner --uid-owner "$DNSCRYPT_UID" -j RETURN >/dev/null 2>&1 || {
    log_msg "$CONTROL_LOG" "Owner matching is unavailable; refusing an unsafe global DNS exemption."
    remove_iptables >/dev/null 2>&1 || true
    return 1
  }
  # Exclude loopback destination (dnscrypt-proxy listens on 127.0.0.1)
  iptables -t nat -A "$CHAIN" -d 127.0.0.0/8 -j RETURN >/dev/null 2>&1 \
    && iptables -t nat -A "$CHAIN" -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:$PORT" >/dev/null 2>&1 \
    && iptables -t nat -A "$CHAIN" -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:$PORT" >/dev/null 2>&1 || {
      log_msg "$CONTROL_LOG" "Unable to populate the IPv4 DNS chain."
      remove_iptables >/dev/null 2>&1 || true
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

  # dnscrypt-proxy only listens on IPv4 (127.0.0.1:5354). Block IPv6 plaintext DNS
  # so queries cannot leak unencrypted over IPv6. A dedicated chain makes this
  # idempotent, while the delete loops migrate duplicate direct rules from older
  # module versions.
  while ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1; do :; done
  while ip6tables -t filter -D OUTPUT -p tcp --dport 53 -j REJECT >/dev/null 2>&1; do :; done
  while ip6tables -t filter -D INPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1; do :; done
  ip6tables -t filter -N "$IP6_CHAIN" >/dev/null 2>&1 \
    || ip6tables -t filter -F "$IP6_CHAIN" >/dev/null 2>&1 || {
      log_msg "$CONTROL_LOG" "Unable to create or access the IPv6 DNS chain."
      remove_iptables >/dev/null 2>&1 || true
      return 1
    }
  ip6tables -t filter -F "$IP6_CHAIN" >/dev/null 2>&1 \
    && ip6tables -t filter -A "$IP6_CHAIN" -m owner --uid-owner "$DNSCRYPT_UID" -j RETURN >/dev/null 2>&1 \
    && ip6tables -t filter -A "$IP6_CHAIN" -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
    && ip6tables -t filter -A "$IP6_CHAIN" -p tcp --dport 53 -j REJECT >/dev/null 2>&1 || {
      log_msg "$CONTROL_LOG" "Unable to populate the IPv6 DNS chain."
      remove_iptables >/dev/null 2>&1 || true
      return 1
    }
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

  log_msg "$CONTROL_LOG" "Applied IPv4 DNS redirection to 127.0.0.1:$PORT (IPv6 plaintext DNS blocked)."
}

firewall_rules_present() {
  has_cmd iptables && has_cmd ip6tables || return 1
  iptables -t nat -C OUTPUT -p udp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1 \
    && iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -m owner --uid-owner "$DNSCRYPT_UID" -j RETURN >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 >/dev/null 2>&1 \
    && iptables -t nat -C DNSCRYPT_PROXY -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5354 >/dev/null 2>&1 \
    && ip6tables -t filter -C OUTPUT -j DNSCRYPT_PROXY6 >/dev/null 2>&1 \
    && ip6tables -t filter -C DNSCRYPT_PROXY6 -m owner --uid-owner "$DNSCRYPT_UID" -j RETURN >/dev/null 2>&1 \
    && ip6tables -t filter -C DNSCRYPT_PROXY6 -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
    && ip6tables -t filter -C DNSCRYPT_PROXY6 -p tcp --dport 53 -j REJECT >/dev/null 2>&1
}

firewall_rules_absent() {
  if has_cmd iptables; then
    ! iptables -t nat -C OUTPUT -p udp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1 \
      || return 1
    ! iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNSCRYPT_PROXY >/dev/null 2>&1 \
      || return 1
  fi
  if has_cmd ip6tables; then
    ! ip6tables -t filter -C OUTPUT -j DNSCRYPT_PROXY6 >/dev/null 2>&1 \
      || return 1
    ! ip6tables -t filter -C OUTPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
      || return 1
    ! ip6tables -t filter -C OUTPUT -p tcp --dport 53 -j REJECT >/dev/null 2>&1 \
      || return 1
    ! ip6tables -t filter -C INPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1 \
      || return 1
  fi
  return 0
}

remove_iptables() {
  CHAIN="DNSCRYPT_PROXY"
  IP6_CHAIN="DNSCRYPT_PROXY6"
  if has_cmd iptables; then
    while iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1; do :; done
    while iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1; do :; done
    iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -X "$CHAIN" >/dev/null 2>&1 || true
  fi
  if has_cmd ip6tables; then
    while ip6tables -t filter -D OUTPUT -j "$IP6_CHAIN" >/dev/null 2>&1; do :; done
    while ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1; do :; done
    while ip6tables -t filter -D OUTPUT -p tcp --dport 53 -j REJECT >/dev/null 2>&1; do :; done
    while ip6tables -t filter -D INPUT -p udp --dport 53 -j REJECT >/dev/null 2>&1; do :; done
    ip6tables -t filter -F "$IP6_CHAIN" >/dev/null 2>&1 || true
    ip6tables -t filter -X "$IP6_CHAIN" >/dev/null 2>&1 || true
  fi
  # Restore the value that existed before this module changed it in this boot.
  _route_restore_status=0
  restore_route_localnet_state || _route_restore_status=1
  log_msg "$CONTROL_LOG" "Removed DNS redirection rules."
  return "$_route_restore_status"
}

start_service() {
  if shutdown_requested; then
    echo "The module is disabled, being removed, or shutting down; service start was refused."
    return 1
  fi
  ensure_config || {
    echo "Failed to prepare the dnscrypt-proxy configuration."
    return 1
  }
  ensure_binary || {
    echo "dnscrypt-proxy binary is missing and automatic download failed."
    return 1
  }
  shutdown_requested && {
    echo "Module shutdown began while preparing the service; start was cancelled."
    return 1
  }
  if is_dnscrypt_running; then
    _running_pid=$(dnscrypt_pid 2>/dev/null || true)
    _running_uid=$(sed -n 's/^Uid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PROC_ROOT/$_running_pid/status" 2>/dev/null | head -n 1)
    if [ "$_running_uid" = "$DNSCRYPT_UID" ] \
      && is_dnscrypt_ready \
      && save_and_disable_private_dns \
      && apply_iptables >/dev/null 2>&1; then
      rm -f "$USER_STOPPED_FILE"
      echo "dnscrypt-proxy is already running; firewall rules refreshed."
      return 0
    fi
    log_msg "$SERVICE_LOG" "Existing dnscrypt-proxy instance was unhealthy or used the wrong UID; restarting it."
    if ! terminate_dnscrypt_process || ! remove_iptables >/dev/null 2>&1; then
      restore_private_dns >/dev/null 2>&1 || true
      echo "The unhealthy dnscrypt-proxy instance could not be cleaned up safely."
      return 1
    fi
  fi
  save_and_disable_private_dns || {
    echo "Failed to save and disable Android Private DNS; service was not started."
    return 1
  }
  if shutdown_requested; then
    restore_private_dns >/dev/null 2>&1 || true
    echo "Module shutdown began while saving Android Private DNS; start was cancelled."
    return 1
  fi
  # Clear the intentional-stop marker so the watchdog treats future outages as faults.
  rm -f "$USER_STOPPED_FILE"
  cd "$CONFIG_DIR" || {
    restore_private_dns >/dev/null 2>&1 || true
    return 1
  }
  # Close control/updater lock descriptors so the long-running daemon cannot
  # keep a parent shell's advisory lock alive after that shell exits.
  "$DNSCRYPT_BIN" -config "$CONFIG_FILE" 8>&- 9>&- >> "$SERVICE_LOG" 2>&1 &
  _started_pid=$!
  _pid_tmp="$PID_FILE.$$.tmp"
  printf '%s\n' "$_started_pid" > "$_pid_tmp" && mv -f "$_pid_tmp" "$PID_FILE" || {
    rm -f "$_pid_tmp"
    terminate_dnscrypt_process >/dev/null 2>&1 || true
    restore_private_dns >/dev/null 2>&1 || true
    echo "Failed to record the dnscrypt-proxy PID."
    return 1
  }
  _ready_try=0
  while [ "$_ready_try" -lt 8 ]; do
    if is_dnscrypt_ready; then
      break
    fi
    is_dnscrypt_running || break
    sleep 1
    _ready_try=$((_ready_try + 1))
  done
  _actual_pid=$(dnscrypt_pid 2>/dev/null || true)
  _actual_uid=$(sed -n 's/^Uid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PROC_ROOT/$_actual_pid/status" 2>/dev/null | head -n 1)
  if shutdown_requested || ! is_dnscrypt_ready || [ "$_actual_uid" != "$DNSCRYPT_UID" ]; then
    log_msg "$SERVICE_LOG" "dnscrypt-proxy did not become ready under UID $DNSCRYPT_UID."
    terminate_dnscrypt_process
    remove_iptables >/dev/null 2>&1 || true
    restore_private_dns >/dev/null 2>&1 || true
    echo "dnscrypt-proxy failed its readiness check; firewall rules were not installed."
    return 1
  fi
  if ! apply_iptables >/dev/null 2>&1; then
    log_msg "$SERVICE_LOG" "Firewall installation failed; stopping dnscrypt-proxy to avoid an unprotected state."
    terminate_dnscrypt_process
    restore_private_dns >/dev/null 2>&1 || true
    echo "DNS redirection could not be installed; dnscrypt-proxy was stopped."
    return 1
  fi
  if shutdown_requested; then
    terminate_dnscrypt_process >/dev/null 2>&1 || true
    remove_iptables >/dev/null 2>&1 || true
    restore_private_dns >/dev/null 2>&1 || true
    echo "Module shutdown began while installing DNS redirection; start was cancelled."
    return 1
  fi
  log_msg "$SERVICE_LOG" "dnscrypt-proxy started with PID $_actual_pid under UID $DNSCRYPT_UID."
  echo "dnscrypt-proxy started."
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

protection_health() {
  ! shutdown_requested && is_dnscrypt_ready && firewall_rules_present
}

print_status() {
  running="false"
  pid=""
  pid=$(dnscrypt_pid 2>/dev/null || true)
  [ -n "$pid" ] && running="true"
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
  printf '{"running":%s,"pid":"%s","version":"%s","manager":"%s","config":"%s","update_state":"%s","update_message":"%s","update_time":"%s"}\n' \
    "$running" "$(shell_quote_json "$pid")" "$(shell_quote_json "$version")" "$(shell_quote_json "$manager")" "$(shell_quote_json "$CONFIG_FILE")" "$(shell_quote_json "$update_state")" "$(shell_quote_json "$update_msg")" "$(shell_quote_json "$update_time")"
}

save_config_b64() {
  payload="${2:-}"
  [ -n "$payload" ] || {
    echo "Missing base64 payload."
    return 1
  }
  ensure_config
  tmp="$RUN_DIR/dnscrypt-proxy.toml.$$.new"
  backup="$CONFIG_FILE.$(date +%Y%m%d%H%M%S 2>/dev/null || date +%s).$$.bak"
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
  if [ -x "$DNSCRYPT_BIN" ]; then
    "$DNSCRYPT_BIN" -check -config "$tmp" >> "$CONTROL_LOG" 2>&1 || {
      echo "dnscrypt-proxy rejected the new configuration. Original file was kept."
      rm -f "$tmp"
      return 1
    }
  fi
  cp -af "$CONFIG_FILE" "$backup" 2>/dev/null || {
    echo "Failed to back up the current configuration."
    rm -f "$tmp"
    return 1
  }
  prune_config_backups
  mv -f "$tmp" "$CONFIG_FILE" || {
    echo "Failed to install the new configuration."
    rm -f "$tmp"
    return 1
  }
  chmod 0644 "$CONFIG_FILE" 2>/dev/null || true
  log_msg "$CONTROL_LOG" "Configuration saved; backup: $backup"
  echo "Configuration saved. Backup: $backup"
}

# Resolve log paths from the TOML file. Relative paths are interpreted from
# CONFIG_DIR because dnscrypt-proxy is launched with that working directory.
toml_section_log_path() {
  _section="$1"
  _file=$(sed -n "/^[[:space:]]*\[$_section\][[:space:]]*$/,/^[[:space:]]*\[/p" "$CONFIG_FILE" 2>/dev/null \
    | sed -n "s/^[[:space:]]*file[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
    | head -n 1)
  [ -n "$_file" ] || return 1
  case "$_file" in
    /*) printf '%s' "$_file" ;;
    *) printf '%s/%s' "$CONFIG_DIR" "$_file" ;;
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
  [ -n "$_file" ] || _file="dnscrypt-proxy.log"
  case "$_file" in
    /*) printf '%s' "$_file" ;;
    *) printf '%s/%s' "$CONFIG_DIR" "$_file" ;;
  esac
}

# dnscrypt-proxy's own -resolve client understands the configured nonstandard
# listen port. Android Toybox/BusyBox nslookup does not reliably support -port.
local_dns_query() {
  _query_name="$1"
  if [ -x "$DNSCRYPT_BIN" ]; then
    "$DNSCRYPT_BIN" -config "$CONFIG_FILE" -resolve "$_query_name"
  elif has_cmd dig; then
    dig @127.0.0.1 -p 5354 "$_query_name" +short +time=5
  else
    return 127
  fi
}

# dnscrypt-proxy probes every selected upstream while starting and logs the
# actual protocol RTT. Return the latest recorded value for one resolver.
resolver_latency_from_log() {
  _resolver_name="$1"
  _proxy_log=$(proxy_log_path)
  for _latency_log in "$_proxy_log" "$SERVICE_LOG"; do
    [ -f "$_latency_log" ] || continue
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
  echo "===== service.log ====="
  tail -n "$lines" "$SERVICE_LOG" 2>/dev/null || true
  echo "===== update.log ====="
  tail -n "$lines" "$UPDATE_LOG" 2>/dev/null || true
  echo "===== control.log ====="
  tail -n "$lines" "$CONTROL_LOG" 2>/dev/null || true
  echo "===== dnscrypt-proxy.log ====="
  _proxy_log=$(proxy_log_path)
  tail -n "$lines" "$_proxy_log" 2>/dev/null || true
}

dns_test() {
  _domain="${2:-}"
  [ -z "$_domain" ] && { echo '{"error":"Missing domain argument"}'; return 1; }
  # Reject anything that is not a valid domain to prevent command injection.
  case "$_domain" in
    *[!a-zA-Z0-9.\-]*) echo '{"error":"invalid domain"}'; return 1 ;;
  esac
  ensure_config
  PORT="5354"
  # Test via dnscrypt-proxy local listener
  _result=$(local_dns_query "$_domain" 2>&1) || _result="Local DNS query failed or no compatible lookup client is available"
  # Also test direct (bypass) for comparison
  if has_cmd nslookup; then
    _direct=$(nslookup "$_domain" 9.9.9.9 2>&1)
  elif has_cmd dig; then
    _direct=$(dig @9.9.9.9 "$_domain" +short +time=5 2>&1)
  else
    _direct="N/A"
  fi
  # Measure latency
  _start=$(_now_ms)
  _query_ok=0
  local_dns_query "$_domain" >/dev/null 2>&1 && _query_ok=1
  _end=$(_now_ms)
  if [ "$_query_ok" -eq 1 ]; then
    _latency=$(( _end - _start ))
  else
    _latency=-1
  fi
  _result_escaped=$(printf '%s' "$_result" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|')
  _direct_escaped=$(printf '%s' "$_direct" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|')
  printf '{"domain":"%s","result":"%s","direct":"%s","latency_ms":%d,"server":"127.0.0.1:%d"}\n' \
    "$_domain" "$_result_escaped" "$_direct_escaped" "$_latency" "$PORT"
}

list_resolvers() {
  # Parse current server_names from config
  ensure_config
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
  ensure_config
  # Format as TOML array
  _toml_list=$(printf '%s' "$_resolvers" | sed "s/,/', '/g")
  _toml_line="server_names = ['${_toml_list}']"
  # Replace in config using awk to avoid sed special-character issues.
  if grep -q '^server_names' "$CONFIG_FILE" 2>/dev/null; then
    awk -v line="$_toml_line" '/^server_names/ {print line; next} {print}' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  else
    awk -v line="$_toml_line" 'NR==1 {print; print line; next} {print}' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  fi
  chmod 0644 "$CONFIG_FILE" 2>/dev/null || true
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
  ensure_config
  _latency=$(resolver_latency_from_log "$_resolver" 2>/dev/null || true)
  if [ -n "$_latency" ]; then
    printf '{"name":"%s","latency_ms":%d}\n' "$_resolver" "$_latency"
  else
    printf '{"name":"%s","latency_ms":-1,"error":"upstream latency unavailable"}\n' "$_resolver"
  fi
}

ping_all_resolvers() {
  # Ping all currently selected resolvers and return JSON array
  ensure_config
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
  ensure_config
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
    if local_dns_query dns.google >/dev/null 2>&1; then
      _quality="good"
    else
      _quality="degraded"
    fi
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

quick_mode() {
  # Apply a preset configuration mode
  # $2 = mode name: fastest | privacy | family
  _mode="${2:-}"
  [ -z "$_mode" ] && { echo "Missing mode name. Use: fastest|privacy|family"; return 1; }
  ensure_config
  case "$_mode" in
    fastest)
      # Fastest: Use DoH servers known for low latency, disable anonymization
      sed -i "s|^server_names.*|server_names = ['cloudflare', 'google', 'nextdns', 'cloudflare-ipv6']|" "$CONFIG_FILE"
      sed -i "s|^dnscrypt_servers.*|dnscrypt_servers = true|" "$CONFIG_FILE"
      sed -i "s|^doh_servers.*|doh_servers = true|" "$CONFIG_FILE"
      sed -i "s|^odoh_servers.*|odoh_servers = false|" "$CONFIG_FILE"
      sed -i "s|^require_dnssec.*|require_dnssec = false|" "$CONFIG_FILE"
      sed -i "s|^require_nolog.*|require_nolog = false|" "$CONFIG_FILE"
      sed -i "s|^require_nofilter.*|require_nofilter = true|" "$CONFIG_FILE"
      # Remove anonymized_dns section if present
      sed -i '/^\[anonymized_dns\]/,/^\[/{ /^\[anonymized_dns\]/d; /^\[/!d; }' "$CONFIG_FILE"
      echo "Applied mode: fastest (low latency, no filtering)"
      ;;
    privacy)
      # Privacy: Anonymized DNSCrypt with no-log resolvers
      sed -i "s|^server_names.*|server_names = ['quad9-dnscrypt-ip4-filter-pri', 'mullvad-doh', 'adguard-dns']|" "$CONFIG_FILE"
      sed -i "s|^dnscrypt_servers.*|dnscrypt_servers = true|" "$CONFIG_FILE"
      sed -i "s|^doh_servers.*|doh_servers = false|" "$CONFIG_FILE"
      sed -i "s|^odoh_servers.*|odoh_servers = false|" "$CONFIG_FILE"
      sed -i "s|^require_dnssec.*|require_dnssec = true|" "$CONFIG_FILE"
      sed -i "s|^require_nolog.*|require_nolog = true|" "$CONFIG_FILE"
      sed -i "s|^require_nofilter.*|require_nofilter = false|" "$CONFIG_FILE"
      # Enable anonymized DNS routes
      if ! grep -q '^\[anonymized_dns\]' "$CONFIG_FILE" 2>/dev/null; then
        cat >> "$CONFIG_FILE" <<'ANON'

[anonymized_dns]
  routes = [
    { server_name = '*', via = ['anon-cs-fr', 'anon-cs-de', 'anon-tiarap', 'anon-kama'] }
  ]
ANON
      fi
      echo "Applied mode: privacy (anonymized DNSCrypt, no-log, DNSSEC)"
      ;;
    family)
      # Family: Filtered resolvers that block adult content + malware
      sed -i "s|^server_names.*|server_names = ['cloudflare-family', 'adguard-dns-family', 'cleanbrowsing-family']|" "$CONFIG_FILE"
      sed -i "s|^dnscrypt_servers.*|dnscrypt_servers = true|" "$CONFIG_FILE"
      sed -i "s|^doh_servers.*|doh_servers = true|" "$CONFIG_FILE"
      sed -i "s|^odoh_servers.*|odoh_servers = false|" "$CONFIG_FILE"
      sed -i "s|^require_dnssec.*|require_dnssec = true|" "$CONFIG_FILE"
      sed -i "s|^require_nolog.*|require_nolog = true|" "$CONFIG_FILE"
      sed -i "s|^require_nofilter.*|require_nofilter = false|" "$CONFIG_FILE"
      # Remove anonymized_dns section if present
      sed -i '/^\[anonymized_dns\]/,/^\[/{ /^\[anonymized_dns\]/d; /^\[/!d; }' "$CONFIG_FILE"
      echo "Applied mode: family (family-safe filtering, DNSSEC)"
      ;;
    *)
      echo "Unknown mode: $_mode. Use: fastest|privacy|family"
      return 1
      ;;
  esac
  # Restart service if running
  if is_dnscrypt_running; then
    restart_service
  fi
}

get_current_mode() {
  # Detect current mode based on config settings
  ensure_config
  _servers=$(grep '^server_names' "$CONFIG_FILE" 2>/dev/null || echo "")
  _anon="false"
  grep -q '^\[anonymized_dns\]' "$CONFIG_FILE" 2>/dev/null && _anon="true"
  _nofilter=$(grep '^require_nofilter' "$CONFIG_FILE" 2>/dev/null | grep -c 'true')
  
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
  ensure_config
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
  ensure_config
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
  if [ -x "$DNSCRYPT_BIN" ]; then
    "$DNSCRYPT_BIN" -check -config "$_import_dir/config" >> "$CONTROL_LOG" 2>&1 || {
      rm -rf "$_import_dir"
      echo "dnscrypt-proxy rejected the imported configuration."
      return 1
    }
  fi

  _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)
  _backup="$CONFIG_FILE.bak.$_ts.$$"
  cp -af "$CONFIG_FILE" "$_backup" 2>/dev/null || {
    rm -rf "$_import_dir"
    echo "Failed to back up the current configuration."
    return 1
  }
  prune_config_backups
  mv -f "$_import_dir/config" "$CONFIG_FILE" || {
    rm -rf "$_import_dir"
    echo "Failed to install imported configuration."
    return 1
  }
  chmod 0644 "$CONFIG_FILE" 2>/dev/null || true

  for _field in blocked_names allowed_names blocked_ips allowed_ips; do
    [ -f "$_import_dir/$_field" ] || continue
    case "$_field" in
      blocked_names) _target="$CONFIG_DIR/blocked-names.txt" ;;
      allowed_names) _target="$CONFIG_DIR/allowed-names.txt" ;;
      blocked_ips) _target="$CONFIG_DIR/blocked-ips.txt" ;;
      allowed_ips) _target="$CONFIG_DIR/allowed-ips.txt" ;;
    esac
    mv -f "$_import_dir/$_field" "$_target" || {
      rm -rf "$_import_dir"
      echo "Failed to install imported field: $_field"
      return 1
    }
    chmod 0644 "$_target" 2>/dev/null || true
  done
  if [ -f "$_import_dir/subscriptions" ]; then
    if [ -s "$_import_dir/subscriptions" ]; then
      mv -f "$_import_dir/subscriptions" "$CONFIG_DIR/subscriptions.json" || {
        rm -rf "$_import_dir"
        echo "Failed to install imported subscriptions."
        return 1
      }
      chmod 0644 "$CONFIG_DIR/subscriptions.json" 2>/dev/null || true
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
  ensure_config
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
  ensure_config
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
  mv -f "$_tmp_subscriptions" "$CONFIG_DIR/subscriptions.json" || {
    rm -f "$_tmp_subscriptions"
    echo "Failed to save subscriptions."
    return 1
  }
  chmod 0644 "$CONFIG_DIR/subscriptions.json" 2>/dev/null || true
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
  chmod 0644 "$_list_tmp" 2>/dev/null || {
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
  ensure_config
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
  mv -f "$_final_file" "$_merged" || {
    rm -f "$_generated_file" "$_user_file" "$_final_file"
    echo "Failed to install the merged subscription blocklist."
    return 1
  }
  chmod 0644 "$_merged" 2>/dev/null || true
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
  ensure_config || { empty_query_stats; return 0; }
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
  if [ ! -f "$QUERY_LOG" ] || [ ! -s "$QUERY_LOG" ]; then
    empty_query_stats
    return 0
  fi
  # Official TSV fields: timestamp, client_ip, query_name, query_type,
  # return_code, duration, server, relay. A query is blocked only when the
  # return-code field is exactly REJECT or DROP.
  total=$(awk -F'\t' 'NF >= 5 { n++ } END { print n + 0 }' "$QUERY_LOG" 2>/dev/null)
  blocked=$(awk -F'\t' 'NF >= 5 && ($5 == "REJECT" || $5 == "DROP") { n++ } END { print n + 0 }' "$QUERY_LOG" 2>/dev/null)
  total=${total:-0}
  blocked=${blocked:-0}
  if [ "$total" -gt 0 ]; then
    rate=$(awk -v total="$total" -v blocked="$blocked" 'BEGIN { printf "%.1f", blocked * 100 / total }')
  else
    rate="0.0"
  fi
  unique=$(awk -F'\t' 'NF >= 5 { print $3 }' "$QUERY_LOG" 2>/dev/null | sort -u | wc -l || echo 0)
  # Top domains
  top_domains=$(awk -F'\t' 'NF >= 5 { print $3 }' "$QUERY_LOG" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{ count=$1; $1=""; sub(/^[[:space:]]+/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "{\"domain\":\"%s\",\"count\":%d},", $0, count }')
  top_domains="[${top_domains%,}]"
  # Top blocked
  top_blocked=$(awk -F'\t' 'NF >= 5 && ($5 == "REJECT" || $5 == "DROP") { print $3 }' "$QUERY_LOG" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{ count=$1; $1=""; sub(/^[[:space:]]+/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "{\"domain\":\"%s\",\"count\":%d},", $0, count }')
  top_blocked="[${top_blocked%,}]"
  # Timeline by hour
  timeline=$(awk -F'\t' 'NF >= 5 { h=substr($1, 13, 2); if (h ~ /^[0-2][0-9]$/) { total[h]++; if ($5 == "REJECT" || $5 == "DROP") blocked[h]++ } } END { for (i=0; i<24; i++) { hh=sprintf("%02d", i); printf "{\"hour\":\"%s\",\"queries\":%d,\"blocked\":%d},", hh, total[hh]+0, blocked[hh]+0 } }' "$QUERY_LOG" 2>/dev/null)
  timeline="[${timeline%,}]"
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
    nslookup "$1" >/dev/null 2>&1 || true
  elif has_cmd ping; then
    ping -c 1 -W 2 "$1" >/dev/null 2>&1 || true
  elif has_cmd getent; then
    getent hosts "$1" >/dev/null 2>&1 || true
  fi
  return 0
}

leak_test() {
  ensure_config
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
  # nx.log captures NXDOMAIN responses; random subdomains resolve to NXDOMAIN, so
  # searching both logs avoids a false "leaking" verdict.
  _nxlog=""
  if grep -q '^[[:space:]]*\[nx_log\][[:space:]]*$' "$CONFIG_FILE" 2>/dev/null; then
    _nxlog=$(nx_log_path 2>/dev/null || true)
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

  _matched=0
  _json_domains=""
  _first=1
  for _d in $_domains; do
    _hit=0
    if [ -f "$_qlog" ] && grep -qF "$_d" "$_qlog" 2>/dev/null; then
      _hit=1
    elif [ -n "$_nxlog" ] && [ -f "$_nxlog" ] && grep -qF "$_d" "$_nxlog" 2>/dev/null; then
      _hit=1
    fi
    [ "$_hit" -eq 1 ] && _matched=$((_matched + 1))
    [ $_first -eq 0 ] && _json_domains="$_json_domains,"
    _json_domains="$_json_domains\"$_d\""
    _first=0
  done

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
  start|stop|restart|apply-iptables|remove-iptables|get-config|save-config-b64|set-resolvers|quick-mode|import-config-b64|save-list-b64|save-subscriptions-b64|apply-subscriptions)
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
  apply-iptables) apply_iptables ;;
  remove-iptables) remove_iptables ;;
  update) sh "$MODDIR/scripts/update-dnscrypt.sh" force ;;
  check-update) sh "$MODDIR/scripts/update-dnscrypt.sh" check ;;
  auto-update) sh "$MODDIR/scripts/update-dnscrypt.sh" auto ;;
  get-config) ensure_config; cat "$CONFIG_FILE" ;;
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
    echo "Usage: $0 {start|stop|shutdown-stop|restart|status|health|apply-iptables|remove-iptables|update|check-update|auto-update|get-config|save-config-b64|save-list-b64|logs|query-stats|dns-test|leak-test|list-resolvers|set-resolvers|ping-resolver|ping-all|protocol-status|quick-mode|get-mode|export-config|import-config-b64|get-subscriptions|save-subscriptions-b64|apply-subscriptions}"
    exit 1
    ;;
esac
