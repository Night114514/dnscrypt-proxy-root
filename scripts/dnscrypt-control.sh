#!/system/bin/sh

SCRIPT_DIR=${0%/*}
MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
. "$MODDIR/scripts/common.sh"

ACTION="${1:-status}"

shell_quote_json() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' | tr '\n' ' '
}

manager_name() {
  if [ "$APATCH" = "true" ] || [ -d /data/adb/ap ]; then
    echo "APatch"
  elif [ "$KSU" = "true" ] || [ -d /data/adb/ksu ]; then
    echo "KernelSU"
  elif [ -d /data/adb/magisk ]; then
    echo "Magisk"
  else
    echo "Unknown"
  fi
}

ensure_binary() {
  if [ ! -x "$DNSCRYPT_BIN" ]; then
    sh "$MODDIR/scripts/update-dnscrypt.sh" install >> "$UPDATE_LOG" 2>&1 || return 1
  fi
  [ -x "$DNSCRYPT_BIN" ]
}

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF'
listen_addresses = ['127.0.0.1:5354']
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
fallback_resolvers = ['9.9.9.9:53', '1.1.1.1:53']
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

[static]
EOF
  fi
  for f in allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt; do
    [ -f "$CONFIG_DIR/$f" ] || : > "$CONFIG_DIR/$f"
  done
}

apply_iptables() {
  PORT="5354"
  CHAIN="DNSCRYPT_PROXY"
  if ! has_cmd iptables; then
    log_msg "$CONTROL_LOG" "iptables not found; DNS redirection skipped."
    return 1
  fi
  # route_localnet must be enabled so the kernel does not drop packets DNAT'd to
  # 127.0.0.1 from the OUTPUT chain.
  sysctl -w net.ipv4.conf.all.route_localnet=1 2>/dev/null \
    || echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null || true

  iptables -t nat -N "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
  # Exclude dnscrypt-proxy's own upstream DNS queries (DoH/DoT) by destination IP so
  # they are not redirected back into the proxy. Using --uid-owner 0 here is wrong on
  # Android because netd (the system DNS proxy) also runs as root, which would exclude
  # all app DNS traffic.
  for _upstream_ip in 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112; do
    iptables -t nat -A "$CHAIN" -d "$_upstream_ip" -p udp --dport 53 -j RETURN >/dev/null 2>&1 || true
    iptables -t nat -A "$CHAIN" -d "$_upstream_ip" -p tcp --dport 53 -j RETURN >/dev/null 2>&1 || true
  done
  # Exclude loopback destination (dnscrypt-proxy listens on 127.0.0.1)
  iptables -t nat -A "$CHAIN" -d 127.0.0.0/8 -j RETURN >/dev/null 2>&1 || true
  iptables -t nat -A "$CHAIN" -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:$PORT" >/dev/null 2>&1 || true
  iptables -t nat -A "$CHAIN" -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:$PORT" >/dev/null 2>&1 || true
  iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -A OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -A OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true

  # dnscrypt-proxy only listens on IPv4 (127.0.0.1:5354). Block IPv6 plaintext DNS
  # so queries cannot leak unencrypted over IPv6.
  if has_cmd ip6tables; then
    ip6tables -t filter -I OUTPUT -p udp --dport 53 -j REJECT 2>/dev/null || true
    ip6tables -t filter -I OUTPUT -p tcp --dport 53 -j REJECT 2>/dev/null || true
    ip6tables -t filter -I INPUT -p udp --dport 53 -j REJECT 2>/dev/null || true
  fi

  log_msg "$CONTROL_LOG" "Applied IPv4 DNS redirection to 127.0.0.1:$PORT (IPv6 plaintext DNS blocked)."
}

remove_iptables() {
  CHAIN="DNSCRYPT_PROXY"
  if has_cmd iptables; then
    iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -X "$CHAIN" >/dev/null 2>&1 || true
  fi
  if has_cmd ip6tables; then
    ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT 2>/dev/null || true
    ip6tables -t filter -D OUTPUT -p tcp --dport 53 -j REJECT 2>/dev/null || true
    ip6tables -t filter -D INPUT -p udp --dport 53 -j REJECT 2>/dev/null || true
  fi
  # Reset route_localnet back to its default.
  sysctl -w net.ipv4.conf.all.route_localnet=0 2>/dev/null \
    || echo 0 > /proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null || true
  log_msg "$CONTROL_LOG" "Removed DNS redirection rules."
}

start_service() {
  ensure_config
  ensure_binary || {
    echo "dnscrypt-proxy binary is missing and automatic download failed."
    return 1
  }
  if is_dnscrypt_running; then
    echo "dnscrypt-proxy is already running."
    return 0
  fi
  cd "$CONFIG_DIR" || return 1
  "$DNSCRYPT_BIN" -config "$CONFIG_FILE" >> "$SERVICE_LOG" 2>&1 &
  echo $! > "$PID_FILE"
  sleep 1
  if is_dnscrypt_running; then
    apply_iptables >/dev/null 2>&1 || true
    log_msg "$SERVICE_LOG" "dnscrypt-proxy started with PID $(cat "$PID_FILE" 2>/dev/null)."
    echo "dnscrypt-proxy started."
    return 0
  fi
  echo "dnscrypt-proxy failed to start; check logs."
  return 1
}

stop_service() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    [ -n "$pid" ] && kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
  fi
  pkill -x dnscrypt-proxy >/dev/null 2>&1 || true
  remove_iptables >/dev/null 2>&1 || true
  log_msg "$SERVICE_LOG" "dnscrypt-proxy stopped."
  echo "dnscrypt-proxy stopped."
}

restart_service() {
  stop_service >/dev/null 2>&1 || true
  start_service
}

print_status() {
  running="false"
  pid=""
  if is_dnscrypt_running; then
    running="true"
    if [ -f "$PID_FILE" ]; then pid=$(cat "$PID_FILE" 2>/dev/null); fi
    [ -z "$pid" ] && pid=$(pgrep -x dnscrypt-proxy 2>/dev/null | head -n 1)
  fi
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
  payload="$2"
  [ -n "$payload" ] || {
    echo "Missing base64 payload."
    return 1
  }
  ensure_config
  tmp="$RUN_DIR/dnscrypt-proxy.toml.new"
  backup="$CONFIG_FILE.$(date +%Y%m%d%H%M%S 2>/dev/null || date +%s).bak"
  if has_cmd base64; then
    printf '%s' "$payload" | base64 -d > "$tmp" 2>/dev/null || {
      echo "Failed to decode base64 config."
      rm -f "$tmp"
      return 1
    }
  else
    printf '%s' "$payload" | busybox_cmd base64 -d > "$tmp" 2>/dev/null || {
      echo "Failed to decode base64 config."
      rm -f "$tmp"
      return 1
    }
  fi
  if [ -x "$DNSCRYPT_BIN" ]; then
    "$DNSCRYPT_BIN" -check -config "$tmp" >> "$CONTROL_LOG" 2>&1 || {
      echo "dnscrypt-proxy rejected the new configuration. Original file was kept."
      rm -f "$tmp"
      return 1
    }
  fi
  cp -af "$CONFIG_FILE" "$backup" 2>/dev/null || true
  mv -f "$tmp" "$CONFIG_FILE"
  chmod 0644 "$CONFIG_FILE" 2>/dev/null || true
  log_msg "$CONTROL_LOG" "Configuration saved; backup: $backup"
  echo "Configuration saved. Backup: $backup"
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
  tail -n "$lines" "$CONFIG_DIR/dnscrypt-proxy.log" 2>/dev/null || true
}

dns_test() {
  _domain="$2"
  [ -z "$_domain" ] && { echo '{"error":"Missing domain argument"}'; return 1; }
  # Reject anything that is not a valid domain to prevent command injection.
  case "$_domain" in
    *[!a-zA-Z0-9.\-]*) echo '{"error":"invalid domain"}'; return 1 ;;
  esac
  PORT="5354"
  # Test via dnscrypt-proxy local listener
  if has_cmd nslookup; then
    _result=$(nslookup "$_domain" 127.0.0.1 -port=$PORT 2>&1)
  elif has_cmd dig; then
    _result=$(dig @127.0.0.1 -p $PORT "$_domain" +short +time=5 2>&1)
  elif has_cmd host; then
    _result=$(host "$_domain" 127.0.0.1 2>&1)
  else
    _result="No DNS lookup tool available (nslookup/dig/host)"
  fi
  # Also test direct (bypass) for comparison
  if has_cmd nslookup; then
    _direct=$(nslookup "$_domain" 9.9.9.9 2>&1)
  elif has_cmd dig; then
    _direct=$(dig @9.9.9.9 "$_domain" +short +time=5 2>&1)
  else
    _direct="N/A"
  fi
  # Measure latency
  _start=$(date +%s%N 2>/dev/null || date +%s)
  if has_cmd nslookup; then
    nslookup "$_domain" 127.0.0.1 -port=$PORT >/dev/null 2>&1
  elif has_cmd dig; then
    dig @127.0.0.1 -p $PORT "$_domain" +short +time=5 >/dev/null 2>&1
  fi
  _end=$(date +%s%N 2>/dev/null || date +%s)
  if [ ${#_start} -gt 10 ]; then
    _latency=$(( (_end - _start) / 1000000 ))
  else
    _latency=$(( _end - _start ))
    _latency=$(( _latency * 1000 ))
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
  _resolvers="$2"
  [ -z "$_resolvers" ] && { echo "Missing resolver list."; return 1; }
  # Validate each resolver name (comma separated) to prevent command/TOML injection.
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
  log_msg "$CONTROL_LOG" "Resolvers updated: $_resolvers"
  echo "Resolvers updated: $_resolvers"
}

ping_resolver() {
  # Ping a single resolver by name via dnscrypt-proxy's built-in resolver test
  _resolver="$2"
  [ -z "$_resolver" ] && { echo '{"name":"","latency_ms":-1,"error":"Missing resolver name"}'; return 1; }
  case "$_resolver" in
    *[!a-zA-Z0-9._-]*) echo '{"name":"","latency_ms":-1,"error":"invalid resolver name"}'; return 1 ;;
  esac
  # Use nslookup through local proxy to measure latency
  _start=$(date +%s%N 2>/dev/null || date +%s)
  if has_cmd nslookup; then
    nslookup "dns.google" 127.0.0.1 -port=5354 >/dev/null 2>&1
  elif has_cmd dig; then
    dig @127.0.0.1 -p 5354 "dns.google" +short +time=3 >/dev/null 2>&1
  fi
  _end=$(date +%s%N 2>/dev/null || date +%s)
  if [ ${#_start} -gt 10 ]; then
    _latency=$(( (_end - _start) / 1000000 ))
  else
    _latency=$(( (_end - _start) * 1000 ))
  fi
  printf '{"name":"%s","latency_ms":%d}\n' "$_resolver" "$_latency"
}

ping_all_resolvers() {
  # Ping all currently selected resolvers and return JSON array
  ensure_config
  _resolvers=$(grep '^server_names' "$CONFIG_FILE" 2>/dev/null | sed "s/.*\[//;s/\].*//;s/'//g;s/\"//g;s/,/ /g" | tr -s ' ')
  printf '['
  _first=1
  for _r in $_resolvers; do
    [ -z "$_r" ] && continue
    _start=$(date +%s%N 2>/dev/null || date +%s)
    if has_cmd nslookup; then
      nslookup "dns.google" 127.0.0.1 -port=5354 >/dev/null 2>&1
    elif has_cmd dig; then
      dig @127.0.0.1 -p 5354 "dns.google" +short +time=3 >/dev/null 2>&1
    fi
    _end=$(date +%s%N 2>/dev/null || date +%s)
    if [ ${#_start} -gt 10 ]; then
      _latency=$(( (_end - _start) / 1000000 ))
    else
      _latency=$(( (_end - _start) * 1000 ))
    fi
    [ $_first -eq 0 ] && printf ','
    printf '{"name":"%s","latency_ms":%d}' "$_r" "$_latency"
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
    if has_cmd nslookup; then
      if nslookup dns.google 127.0.0.1 -port=5354 >/dev/null 2>&1; then
        _quality="good"
      else
        _quality="degraded"
      fi
    elif has_cmd dig; then
      if dig @127.0.0.1 -p 5354 dns.google +short +time=3 >/dev/null 2>&1; then
        _quality="good"
      else
        _quality="degraded"
      fi
    fi
  fi
  # Count active resolvers from log
  _active_resolvers=0
  if [ -f "$LOG_DIR/dnscrypt-proxy.log" ]; then
    _active_resolvers=$(grep -c '\] OK' "$LOG_DIR/dnscrypt-proxy.log" 2>/dev/null || echo 0)
  fi
  printf '{"dnscrypt":%s,"doh":%s,"odoh":%s,"anonymized":%s,"running":%s,"quality":"%s","active_resolvers":%d}\n' \
    "$([ $_dnscrypt -gt 0 ] && echo true || echo false)" \
    "$([ $_doh -gt 0 ] && echo true || echo false)" \
    "$([ $_odoh -gt 0 ] && echo true || echo false)" \
    "$_anon" "$_running" "$_quality" "$_active_resolvers"
}

quick_mode() {
  # Apply a preset configuration mode
  # $2 = mode name: fastest | privacy | family
  _mode="$2"
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
      sed -i "s|^server_names.*|server_names = ['quad9-dnscrypt-ip4-filter-pri', 'scaleway-fr', 'lelux.fi', 'pf-dnscrypt']|" "$CONFIG_FILE"
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
  # Helper: encode file to base64 (portable across busybox/GNU)
  _b64_encode() {
    if base64 -w 0 < /dev/null >/dev/null 2>&1; then
      cat "$1" 2>/dev/null | base64 -w 0
    else
      cat "$1" 2>/dev/null | base64 | tr -d '\n'
    fi
  }
  _config_b64=$(_b64_encode "$CONFIG_FILE")
  _blocked_names_b64=$(_b64_encode "$CONFIG_DIR/blocked-names.txt")
  _allowed_names_b64=$(_b64_encode "$CONFIG_DIR/allowed-names.txt")
  _blocked_ips_b64=$(_b64_encode "$CONFIG_DIR/blocked-ips.txt")
  _allowed_ips_b64=$(_b64_encode "$CONFIG_DIR/allowed-ips.txt")
  _subs_b64=""
  [ -f "$CONFIG_DIR/subscriptions.json" ] && _subs_b64=$(_b64_encode "$CONFIG_DIR/subscriptions.json")
  printf '{"version":1,"config":"%s","blocked_names":"%s","allowed_names":"%s","blocked_ips":"%s","allowed_ips":"%s","subscriptions":"%s"}\n' \
    "$_config_b64" "$_blocked_names_b64" "$_allowed_names_b64" "$_blocked_ips_b64" "$_allowed_ips_b64" "$_subs_b64"
}

import_config_b64() {
  # Import config from base64-encoded JSON
  _data_b64="$2"
  [ -z "$_data_b64" ] && { echo "Missing import data."; return 1; }
  _json=$(printf '%s' "$_data_b64" | base64 -d 2>/dev/null)
  [ -z "$_json" ] && { echo "Failed to decode import data."; return 1; }
  ensure_config
  # Backup current
  _ts=$(date +%Y%m%d_%H%M%S)
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$_ts" 2>/dev/null
  # Extract and write each part
  _cfg=$(printf '%s' "$_json" | sed 's/.*"config":"\([^"]*\)".*/\1/' | base64 -d 2>/dev/null)
  [ -n "$_cfg" ] && printf '%s' "$_cfg" > "$CONFIG_FILE"
  _bn=$(printf '%s' "$_json" | sed 's/.*"blocked_names":"\([^"]*\)".*/\1/' | base64 -d 2>/dev/null)
  [ -n "$_bn" ] && printf '%s' "$_bn" > "$CONFIG_DIR/blocked-names.txt"
  _an=$(printf '%s' "$_json" | sed 's/.*"allowed_names":"\([^"]*\)".*/\1/' | base64 -d 2>/dev/null)
  [ -n "$_an" ] && printf '%s' "$_an" > "$CONFIG_DIR/allowed-names.txt"
  _bi=$(printf '%s' "$_json" | sed 's/.*"blocked_ips":"\([^"]*\)".*/\1/' | base64 -d 2>/dev/null)
  [ -n "$_bi" ] && printf '%s' "$_bi" > "$CONFIG_DIR/blocked-ips.txt"
  _ai=$(printf '%s' "$_json" | sed 's/.*"allowed_ips":"\([^"]*\)".*/\1/' | base64 -d 2>/dev/null)
  [ -n "$_ai" ] && printf '%s' "$_ai" > "$CONFIG_DIR/allowed-ips.txt"
  _subs=$(printf '%s' "$_json" | sed 's/.*"subscriptions":"\([^"]*\)".*/\1/' | base64 -d 2>/dev/null)
  [ -n "$_subs" ] && printf '%s' "$_subs" > "$CONFIG_DIR/subscriptions.json"
  log_msg "$CONTROL_LOG" "Config imported from backup (previous saved as .bak.$_ts)"
  echo "Config imported successfully. Previous config backed up as .bak.$_ts"
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
  _data_b64="$2"
  [ -z "$_data_b64" ] && { echo "Missing data."; return 1; }
  ensure_config
  printf '%s' "$_data_b64" | base64 -d > "$CONFIG_DIR/subscriptions.json" 2>/dev/null
  echo "Subscriptions saved."
}

apply_subscriptions() {
  # Download all enabled subscription lists and merge into blocked-names.txt
  ensure_config
  [ ! -f "$CONFIG_DIR/subscriptions.json" ] && { echo "No subscriptions configured."; return 0; }
  # Parse JSON subscriptions (simple line-based extraction for busybox)
  _subs_file="$CONFIG_DIR/subscriptions.json"
  _merged="$CONFIG_DIR/blocked-names.txt"
  # Keep user's manual entries (lines not starting with # subscription-)
  _user_entries=$(grep -v '^# subscription-' "$_merged" 2>/dev/null | grep -v '^## Auto-' || true)
  # Start fresh
  printf '%s\n' "$_user_entries" > "$_merged.tmp"
  printf '## Auto-generated from subscriptions on %s\n' "$(date +%Y-%m-%d)" >> "$_merged.tmp"
  # For each enabled subscription URL, download and append
  # Simple JSON parsing: extract url fields from enabled entries
  _urls=$(grep -o '"url":"[^"]*"' "$_subs_file" | sed 's/"url":"//;s/"//' || true)
  _enabled_list=$(grep -o '"enabled":[a-z]*' "$_subs_file" | sed 's/"enabled"://' || true)
  _i=0
  echo "$_urls" | while IFS= read -r _url; do
    _i=$((_i + 1))
    _en=$(echo "$_enabled_list" | sed -n "${_i}p")
    [ "$_en" != "true" ] && continue
    [ -z "$_url" ] && continue
    printf '# subscription-%d: %s\n' "$_i" "$_url" >> "$_merged.tmp"
    if has_cmd curl; then
      curl -fsSL --connect-timeout 10 "$_url" 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -v '^!' >> "$_merged.tmp" || true
    elif has_cmd wget; then
      wget -qO- --timeout=10 "$_url" 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -v '^!' >> "$_merged.tmp" || true
    fi
  done
  mv "$_merged.tmp" "$_merged"
  _count=$(wc -l < "$_merged" 2>/dev/null || echo 0)
  log_msg "$CONTROL_LOG" "Subscriptions applied: $_count total entries in blocked-names.txt"
  echo "Subscriptions applied. Total entries: $_count"
}

query_stats() {
  QUERY_LOG="$CONFIG_DIR/query.log"
  if [ ! -f "$QUERY_LOG" ] || [ ! -s "$QUERY_LOG" ]; then
    echo '{"totalQueries":0,"blockedCount":0,"blockRate":0,"uniqueDomains":0,"topDomains":[],"topBlocked":[],"timeline":[]}'
    return 0
  fi
  # TSV format: timestamp client_ip domain query_type action latency
  total=$(wc -l < "$QUERY_LOG" 2>/dev/null || echo 0)
  blocked=$(grep -cE 'REJECT|BLOCK' "$QUERY_LOG" 2>/dev/null || echo 0)
  if [ "$total" -gt 0 ]; then
    rate=$(awk "BEGIN{if($total>0) printf \"%.1f\", $blocked*100/$total; else print \"0.0\"}")
  else
    rate=0
  fi
  unique=$(awk -F'\t' '{print $3}' "$QUERY_LOG" 2>/dev/null | sort -u | wc -l || echo 0)
  # Top domains
  top_domains=$(awk -F'\t' '{print $3}' "$QUERY_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | awk '{printf "{\"domain\":\"%s\",\"count\":%d},", $2, $1}')
  top_domains="[${top_domains%,}]"
  # Top blocked
  top_blocked=$(grep -E 'REJECT|BLOCK' "$QUERY_LOG" 2>/dev/null | awk -F'\t' '{print $3}' | sort | uniq -c | sort -rn | head -5 | awk '{printf "{\"domain\":\"%s\",\"count\":%d},", $2, $1}')
  top_blocked="[${top_blocked%,}]"
  # Timeline by hour
  timeline=$(awk -F'\t' '{split($1,a,"[T ]"); split(a[2],b,":"); h=b[1]; total[h]++} /REJECT|BLOCK/{blocked[h]++} END{for(i=0;i<24;i++){hh=sprintf("%02d",i); printf "{\"hour\":\"%s\",\"queries\":%d,\"blocked\":%d},",hh,total[hh]+0,blocked[hh]+0}}' "$QUERY_LOG" 2>/dev/null)
  timeline="[${timeline%,}]"
  printf '{"totalQueries":%d,"blockedCount":%d,"blockRate":%s,"uniqueDomains":%d,"topDomains":%s,"topBlocked":%s,"timeline":%s}\n' \
    "$total" "$blocked" "$rate" "$unique" "$top_domains" "$top_blocked" "$timeline"
}

case "$ACTION" in
  start) start_service ;;
  stop) stop_service ;;
  restart) restart_service ;;
  status) print_status ;;
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
  save-subscriptions-b64) save_subscriptions_b64 "$@" ;;
  apply-subscriptions) apply_subscriptions ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|apply-iptables|remove-iptables|update|check-update|auto-update|get-config|save-config-b64|logs|query-stats|dns-test|list-resolvers|set-resolvers|ping-resolver|ping-all|protocol-status|quick-mode|get-mode|export-config|import-config-b64|get-subscriptions|save-subscriptions-b64|apply-subscriptions}"
    exit 1
    ;;
esac
