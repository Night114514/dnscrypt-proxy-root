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
  # Get dnscrypt-proxy UID to exclude its own traffic from redirection (avoid loops)
  PROXY_UID=""
  if [ -f "$PID_FILE" ]; then
    _pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$_pid" ] && PROXY_UID=$(stat -c '%u' /proc/$_pid 2>/dev/null || id -u root 2>/dev/null)
  fi
  [ -z "$PROXY_UID" ] && PROXY_UID=0

  iptables -t nat -N "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
  # Exclude dnscrypt-proxy's own outbound DNS queries
  iptables -t nat -A "$CHAIN" -m owner --uid-owner "$PROXY_UID" -j RETURN >/dev/null 2>&1 || true
  # Exclude traffic destined for common resolvers used as bootstrap/fallback
  for ip in 127.0.0.1 0.0.0.0 9.9.9.9 149.112.112.112 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4; do
    iptables -t nat -A "$CHAIN" -d "$ip" -j RETURN >/dev/null 2>&1 || true
  done
  iptables -t nat -A "$CHAIN" -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:$PORT" >/dev/null 2>&1 || true
  iptables -t nat -A "$CHAIN" -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:$PORT" >/dev/null 2>&1 || true
  iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -A OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  iptables -t nat -A OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
  log_msg "$CONTROL_LOG" "Applied IPv4 DNS redirection to 127.0.0.1:$PORT (exclude UID $PROXY_UID)."
}

remove_iptables() {
  CHAIN="DNSCRYPT_PROXY"
  if has_cmd iptables; then
    iptables -t nat -D OUTPUT -p udp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -X "$CHAIN" >/dev/null 2>&1 || true
  fi
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

query_stats() {
  QUERY_LOG="$CONFIG_DIR/query.log"
  if [ ! -f "$QUERY_LOG" ] || [ ! -s "$QUERY_LOG" ]; then
    echo '{"totalQueries":0,"blockedCount":0,"blockRate":0,"uniqueDomains":0,"topDomains":[],"topBlocked":[],"timeline":[]}'
    return 0
  fi
  # TSV format: timestamp client_ip domain query_type action latency
  total=$(wc -l < "$QUERY_LOG" 2>/dev/null || echo 0)
  blocked=$(grep -c 'REJECT\|BLOCK' "$QUERY_LOG" 2>/dev/null || echo 0)
  if [ "$total" -gt 0 ]; then
    rate=$(echo "scale=1; $blocked * 100 / $total" | bc 2>/dev/null || echo 0)
  else
    rate=0
  fi
  unique=$(awk -F'\t' '{print $3}' "$QUERY_LOG" 2>/dev/null | sort -u | wc -l || echo 0)
  # Top domains
  top_domains=$(awk -F'\t' '{print $3}' "$QUERY_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | awk '{printf "{\"domain\":\"%s\",\"count\":%d},", $2, $1}')
  top_domains="[${top_domains%,}]"
  # Top blocked
  top_blocked=$(grep 'REJECT\|BLOCK' "$QUERY_LOG" 2>/dev/null | awk -F'\t' '{print $3}' | sort | uniq -c | sort -rn | head -5 | awk '{printf "{\"domain\":\"%s\",\"count\":%d},", $2, $1}')
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
  *)
    echo "Usage: $0 {start|stop|restart|status|apply-iptables|remove-iptables|update|check-update|auto-update|get-config|save-config-b64|logs|query-stats}"
    exit 1
    ;;
esac
