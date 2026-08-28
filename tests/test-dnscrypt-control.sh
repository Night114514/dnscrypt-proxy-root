#!/bin/sh
set -u

TEST_DIR=$(CDPATH='' cd "${0%/*}" 2>/dev/null && pwd)
ROOT_DIR=$(CDPATH='' cd "$TEST_DIR/.." 2>/dev/null && pwd)
MOCK_SOURCE_DIR="$TEST_DIR/mocks"
HOST_PATH=$PATH

find_host_tool() {
  tool_name=$1
  old_ifs=$IFS
  IFS=:
  for tool_dir in $HOST_PATH; do
    [ -n "$tool_dir" ] || tool_dir=.
    if [ -f "$tool_dir/$tool_name" ] && [ -x "$tool_dir/$tool_name" ]; then
      printf '%s\n' "$tool_dir/$tool_name"
      IFS=$old_ifs
      return 0
    fi
    # Git for Windows resolves commands through PATHEXT, while POSIX test -f
    # still needs the physical .exe suffix. Keeping this fallback here makes
    # the same fixture runnable locally without changing Linux CI behavior.
    if [ -f "$tool_dir/$tool_name.exe" ] && [ -x "$tool_dir/$tool_name.exe" ]; then
      printf '%s\n' "$tool_dir/$tool_name.exe"
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

HOST_SH=$(find_host_tool sh 2>/dev/null || true)
HOST_DASH=$(find_host_tool dash 2>/dev/null || true)
HOST_BUSYBOX=$(find_host_tool busybox 2>/dev/null || true)
HOST_ENV=$(find_host_tool env 2>/dev/null || true)
HOST_BASE64=$(find_host_tool base64 2>/dev/null || true)
HOST_CP=$(find_host_tool cp 2>/dev/null || true)
HOST_MV=$(find_host_tool mv 2>/dev/null || true)
HOST_NODE=$(find_host_tool node 2>/dev/null || true)
HOST_TOUCH=$(find_host_tool touch 2>/dev/null || true)
HOST_TR=$(find_host_tool tr 2>/dev/null || true)
HOST_TRUE=$(find_host_tool true 2>/dev/null || true)
TEST_SHELL_KIND=${TEST_SHELL_KIND:-sh}

for required_tool in "$HOST_ENV" "$HOST_BASE64" "$HOST_CP" "$HOST_MV" "$HOST_NODE" "$HOST_TOUCH" "$HOST_TR" "$HOST_TRUE"; do
  [ -n "$required_tool" ] || {
    echo "A required host test tool is missing." >&2
    exit 2
  }
done

case "$TEST_SHELL_KIND" in
  sh)
    [ -n "$HOST_SH" ] || { echo "sh is required" >&2; exit 2; }
    ;;
  dash)
    [ -n "$HOST_DASH" ] || { echo "dash is required" >&2; exit 2; }
    ;;
  busybox-ash)
    [ -n "$HOST_BUSYBOX" ] || { echo "busybox is required" >&2; exit 2; }
    ;;
  *)
    echo "Unknown TEST_SHELL_KIND: $TEST_SHELL_KIND" >&2
    exit 2
    ;;
esac

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_CASE_DIR=

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_eq() {
  expected=$1
  actual=$2
  message=$3
  [ "$expected" = "$actual" ] ||
    fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
  text=$1
  needle=$2
  message=$3
  case "$text" in
    *"$needle"*) return 0 ;;
    *) fail "$message (missing '$needle')" ;;
  esac
}

assert_file_contains() {
  grep -F "$2" "$1" >/dev/null 2>&1 || fail "$3 (missing '$2' in '$1')"
}

assert_file_not_contains() {
  if grep -F "$2" "$1" >/dev/null 2>&1; then
    fail "$3 (unexpected '$2' in '$1')"
  fi
}

assert_file_empty() {
  [ -f "$1" ] || return 1
  [ ! -s "$1" ] || fail "$2 ('$1' is not empty)"
}

link_host_tool() {
  link_name=$1
  link_source=$(find_host_tool "$link_name" 2>/dev/null || true)
  [ -n "$link_source" ] || return 1
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$link_source" > "$TOOL_BIN/$link_name"
  chmod 0755 "$TOOL_BIN/$link_name"
}

install_mock() {
  source_name=$1
  target_name=$2
  sed 's/\r$//' "$MOCK_SOURCE_DIR/$source_name" > "$TOOL_BIN/$target_name"
  chmod 0755 "$TOOL_BIN/$target_name"
}

setup_fixture() {
  CURRENT_CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dnscrypt-control-test.XXXXXX") || return 1
  MODULE_DIR="$CURRENT_CASE_DIR/module"
  TOOL_BIN="$CURRENT_CASE_DIR/bin"
  MOCK_CALL_LOG="$CURRENT_CASE_DIR/calls.log"
  MOCK_FIREWALL_STATE="$CURRENT_CASE_DIR/firewall-state"
  MOCK_SUBSCRIPTION_PAYLOAD="$CURRENT_CASE_DIR/subscription-payload.txt"
  MOCK_NX_LOG=
  MOCK_NSLOOKUP_STATUS=0
  MOCK_DOWNLOAD_MODE=success
  MOCK_MV_MODE=success
  MOCK_INSTALL_TARGET=
  MOCK_FLOCK_FAILURES=0
  MOCK_FLOCK_STATE="$CURRENT_CASE_DIR/flock-state"
  DNSCRYPT_PROC_ROOT="$CURRENT_CASE_DIR/proc"
  DNSCRYPT_PROC_SYS_ROOT="$CURRENT_CASE_DIR/proc-sys"
  BUSYBOX_CONTROL_SCRIPT="$MODULE_DIR/scripts/dnscrypt-control-busybox.sh"

  mkdir -p "$MODULE_DIR/scripts" "$MODULE_DIR/bin" "$MODULE_DIR/config" \
    "$MODULE_DIR/state" "$MODULE_DIR/run" "$MODULE_DIR/logs" "$MODULE_DIR/tmp" \
    "$DNSCRYPT_PROC_ROOT" \
    "$DNSCRYPT_PROC_SYS_ROOT/kernel/random" \
    "$DNSCRYPT_PROC_SYS_ROOT/net/ipv4/conf/all" \
    "$TOOL_BIN" "$MOCK_FIREWALL_STATE"
  printf '%s\n' 'fixture-boot-id' > "$DNSCRYPT_PROC_SYS_ROOT/kernel/random/boot_id"
  printf '%s\n' '0' > "$DNSCRYPT_PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet"
  sed 's/\r$//' "$ROOT_DIR/scripts/common.sh" > "$MODULE_DIR/scripts/common.sh"
  sed 's/\r$//' "$ROOT_DIR/scripts/dnscrypt-control.sh" > "$MODULE_DIR/scripts/dnscrypt-control.sh"
  sed 's/\r$//' "$ROOT_DIR/config/dnscrypt-proxy.toml" > "$MODULE_DIR/config/dnscrypt-proxy.toml"
  sed 's/\r$//' "$MOCK_SOURCE_DIR/busybox-ash-prelude" > "$BUSYBOX_CONTROL_SCRIPT"
  sed '1d; s/\r$//' "$ROOT_DIR/scripts/dnscrypt-control.sh" >> "$BUSYBOX_CONTROL_SCRIPT"
  : > "$MOCK_CALL_LOG"
  : > "$MOCK_SUBSCRIPTION_PAYLOAD"
  for list_file in allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt; do
    : > "$MODULE_DIR/config/$list_file"
  done

  for fixture_tool in awk cat chmod cp date dd grep head kill ln ls mkdir rm sed sort tail tr uniq wc; do
    link_host_tool "$fixture_tool" || return 1
  done
  install_mock mv mv
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_TRUE" > "$TOOL_BIN/sleep"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_TRUE" > "$TOOL_BIN/sysctl"
  chmod 0755 "$TOOL_BIN/sleep" "$TOOL_BIN/sysctl"
  install_mock dnscrypt-control-busybox busybox-mock
  cp "$TOOL_BIN/busybox-mock" "$TOOL_BIN/busybox"
  install_mock dnscrypt-control-nslookup nslookup
  install_mock dnscrypt-control-firewall iptables
  install_mock dnscrypt-control-firewall ip6tables

  MOCK_HOST_BASE64=$HOST_BASE64
  MOCK_HOST_CP=$HOST_CP
  MOCK_REAL_MV=$HOST_MV
  export MOCK_HOST_BASE64 MOCK_HOST_CP MOCK_CALL_LOG MOCK_FIREWALL_STATE
  export MOCK_SUBSCRIPTION_PAYLOAD MOCK_NX_LOG MOCK_NSLOOKUP_STATUS MOCK_DOWNLOAD_MODE
  export MOCK_REAL_MV MOCK_MV_MODE MOCK_INSTALL_TARGET
  export MOCK_FLOCK_FAILURES MOCK_FLOCK_STATE
  export DNSCRYPT_PROC_ROOT DNSCRYPT_PROC_SYS_ROOT
}

cleanup_fixture() {
  [ -n "$CURRENT_CASE_DIR" ] || return 0
  rm -rf "$CURRENT_CASE_DIR"
  CURRENT_CASE_DIR=
}

trap 'cleanup_fixture' 0 HUP INT TERM

run_control() {
  case "$TEST_SHELL_KIND" in
    sh)
      "$HOST_ENV" PATH="$TOOL_BIN" "$HOST_SH" \
        "$MODULE_DIR/scripts/dnscrypt-control.sh" "$@"
      ;;
    dash)
      "$HOST_ENV" PATH="$TOOL_BIN" "$HOST_DASH" \
        "$MODULE_DIR/scripts/dnscrypt-control.sh" "$@"
      ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MOCK_COMMAND_DIR="$TOOL_BIN" \
        "$HOST_BUSYBOX" ash "$BUSYBOX_CONTROL_SCRIPT" "$@"
      ;;
  esac
}

host_b64_file() {
  "$HOST_BASE64" "$1" | "$HOST_TR" -d '\r\n'
}

host_b64_text() {
  printf '%s' "$1" | "$HOST_BASE64" | "$HOST_TR" -d '\r\n'
}

backup_count() {
  count=0
  for backup_path in \
    "$MODULE_DIR/config/dnscrypt-proxy.toml".*.bak \
    "$MODULE_DIR/config/dnscrypt-proxy.toml".bak.*
  do
    [ -f "$backup_path" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

test_backup_pruning_combines_both_name_families() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  backup_1="$config_file.20260101010101.bak"
  backup_2="$config_file.bak.20260101010102"
  backup_3="$config_file.20260101010103.bak"
  backup_4="$config_file.bak.20260101010104"
  backup_5="$config_file.20260101010105.bak"
  backup_6="$config_file.bak.20260101010106"
  backup_7="$config_file.20260101010107.bak"

  printf 'one\n' > "$backup_1"
  printf 'two\n' > "$backup_2"
  printf 'three\n' > "$backup_3"
  printf 'four\n' > "$backup_4"
  printf 'five\n' > "$backup_5"
  printf 'six\n' > "$backup_6"
  printf 'seven\n' > "$backup_7"
  "$HOST_TOUCH" -t 202601010101.01 "$backup_1"
  "$HOST_TOUCH" -t 202601010101.02 "$backup_2"
  "$HOST_TOUCH" -t 202601010101.03 "$backup_3"
  "$HOST_TOUCH" -t 202601010101.04 "$backup_4"
  "$HOST_TOUCH" -t 202601010101.05 "$backup_5"
  "$HOST_TOUCH" -t 202601010101.06 "$backup_6"
  "$HOST_TOUCH" -t 202601010101.07 "$backup_7"

  payload=$(host_b64_file "$config_file") || return 1
  output=$(run_control save-config-b64 "$payload" 2>&1)
  status=$?
  assert_eq 0 "$status" "saving a valid config failed: $output" || return 1
  assert_eq 5 "$(backup_count)" "backup pruning did not keep exactly five files" || return 1
  [ ! -e "$backup_1" ] || return 1
  [ ! -e "$backup_2" ] || return 1
  [ ! -e "$backup_3" ] || return 1
  [ -e "$backup_7" ] || return 1
}

test_resolver_whitespace_and_empty_elements() {
  output=$(run_control set-resolvers '  cloudflare  ,   quad9-dnscrypt-ip4-filter-pri  ' 2>&1)
  status=$?
  assert_eq 0 "$status" "resolver whitespace normalization failed: $output" || return 1
  assert_file_contains "$MODULE_DIR/config/dnscrypt-proxy.toml" \
    "server_names = ['cloudflare', 'quad9-dnscrypt-ip4-filter-pri']" \
    "normalized resolver list was not written" || return 1

  before=$(cat "$MODULE_DIR/config/dnscrypt-proxy.toml")
  for invalid_list in ',cloudflare' 'cloudflare,' 'cloudflare,,quad9' 'cloudflare, bad resolver'; do
    output=$(run_control set-resolvers "$invalid_list" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "invalid resolver list was accepted: $invalid_list" || return 1
  done
  after=$(cat "$MODULE_DIR/config/dnscrypt-proxy.toml")
  assert_eq "$before" "$after" "invalid resolver input changed the configuration"
}

test_busybox_base64_fallback_and_empty_import() {
  subscriptions_b64=$(host_b64_text '[]') || return 1
  output=$(run_control save-subscriptions-b64 "$subscriptions_b64" 2>&1)
  status=$?
  assert_eq 0 "$status" "BusyBox base64 subscription decode failed: $output" || return 1
  assert_eq '[]' "$(cat "$MODULE_DIR/config/subscriptions.json")" \
    "decoded subscriptions were not saved" || return 1

  printf 'old-blocked\n' > "$MODULE_DIR/config/blocked-names.txt"
  printf 'old-allowed\n' > "$MODULE_DIR/config/allowed-names.txt"
  printf '192.0.2.1\n' > "$MODULE_DIR/config/blocked-ips.txt"
  printf '192.0.2.2\n' > "$MODULE_DIR/config/allowed-ips.txt"
  printf '[{"enabled":true}]\n' > "$MODULE_DIR/config/subscriptions.json"
  import_config="$CURRENT_CASE_DIR/import.toml"
  import_json="$CURRENT_CASE_DIR/import.json"
  printf '%s\n' "server_names = ['cloudflare']" 'listen_addresses = ['"'"'127.0.0.1:5354'"'"']' > "$import_config"
  config_b64=$(host_b64_file "$import_config") || return 1
  printf '{"version":1,"config":"%s","blocked_names":"","allowed_names":"","blocked_ips":"","allowed_ips":"","subscriptions":""}\n' \
    "$config_b64" > "$import_json"
  import_b64=$(host_b64_file "$import_json") || return 1

  output=$(run_control import-config-b64 "$import_b64" 2>&1)
  status=$?
  assert_eq 0 "$status" "BusyBox base64 config import failed: $output" || return 1
  assert_file_empty "$MODULE_DIR/config/blocked-names.txt" "blocked names were not cleared" || return 1
  assert_file_empty "$MODULE_DIR/config/allowed-names.txt" "allowed names were not cleared" || return 1
  assert_file_empty "$MODULE_DIR/config/blocked-ips.txt" "blocked IPs were not cleared" || return 1
  assert_file_empty "$MODULE_DIR/config/allowed-ips.txt" "allowed IPs were not cleared" || return 1
  [ ! -e "$MODULE_DIR/config/subscriptions.json" ] ||
    fail "empty imported subscriptions should remove the live subscription file" || return 1

  output=$(run_control export-config 2>&1)
  status=$?
  assert_eq 0 "$status" "BusyBox base64 config export failed: $output" || return 1
  assert_contains "$output" '"config":"' "export did not contain an encoded config" || return 1
  assert_contains "$output" '"subscriptions":""' "absent subscriptions were not exported as empty" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'busybox base64 -d' \
    "decode did not exercise the BusyBox fallback" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'busybox base64 ' \
    "encode did not exercise the BusyBox fallback"
}

test_save_list_b64_is_exact_atomic_and_fail_closed() {
  target="$MODULE_DIR/config/allowed-names.txt"
  printf 'old-value\n' > "$target"

  payload_file="$CURRENT_CASE_DIR/list-payload.txt"
  printf 'one.example\ntwo.example\n' > "$payload_file"
  payload=$(host_b64_file "$payload_file") || return 1
  output=$(run_control save-list-b64 allowed-names "$payload" 2>&1)
  status=$?
  assert_eq 0 "$status" "valid list payload was rejected: $output" || return 1
  assert_eq "$(cat "$payload_file")" "$(cat "$target")" \
    "valid list payload was not installed exactly" || return 1

  output=$(run_control save-list-b64 allowed-names '' 2>&1)
  status=$?
  assert_eq 0 "$status" "an explicit empty list was rejected: $output" || return 1
  assert_file_empty "$target" "an explicit empty list did not clear the target" || return 1

  printf 'preserve-after-decode-error\n' > "$target"
  output=$(run_control save-list-b64 allowed-names '@@@not-base64@@@' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed base64 was reported as success" || return 1
  assert_eq 'preserve-after-decode-error' "$(cat "$target")" \
    "malformed base64 changed the live list" || return 1

  printf 'preserve-after-install-error\n' > "$target"
  MOCK_MV_MODE=fail
  MOCK_INSTALL_TARGET=$target
  output=$(run_control save-list-b64 allowed-names "$payload" 2>&1)
  status=$?
  MOCK_MV_MODE=success
  MOCK_INSTALL_TARGET=
  [ "$status" -ne 0 ] || fail "failed atomic install was reported as success" || return 1
  assert_contains "$output" 'Failed to install the list.' \
    "failed atomic install did not report its error" || return 1
  assert_eq 'preserve-after-install-error' "$(cat "$target")" \
    "failed atomic install changed the live list" || return 1

  for leftover in "$MODULE_DIR/run/list."*.new; do
    [ ! -e "$leftover" ] || fail "temporary list file was left behind: $leftover" || return 1
  done
}

test_query_stats_matches_official_tsv_contract() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  query_log="$MODULE_DIR/config/query-fixture.log"
  printf '%s\n' \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = 'query-fixture.log'" \
    "  format = 'tsv'" > "$config_file"

  # dnscrypt-proxy's official TSV order is timestamp, client, qname, qtype,
  # return code, duration, server, relay. StringQuote-escaped qnames can carry
  # literal backslashes and escaped quotes, which must remain valid JSON.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    '[2026-08-28 01:00:00]' '127.0.0.1' 'pass.example' 'A' 'PASS' '1ms' 'cloudflare' '-' \
    '[2026-08-28 01:01:00]' '127.0.0.1' 'ad.example' 'A' 'REJECT' '2ms' '-' '-' \
    '[2026-08-28 01:02:00]' '127.0.0.1' 'tracker.example' 'AAAA' 'DROP' '3ms' '-' '-' \
    '[2026-08-28 01:03:00]' '127.0.0.1' 'BLOCK.example' 'A' 'PASS' '4ms' 'cloudflare' '-' \
    '[2026-08-28 01:04:00]' '127.0.0.1' 'quote\"slash\\name.example' 'TXT' 'PASS' '5ms' 'cloudflare' '-' \
    '[2026-08-28 02:00:00]' '127.0.0.1' 'pass.example' 'A' 'PASS' '6ms' 'cloudflare' '-' \
    > "$query_log"
  printf 'malformed\trow\n' >> "$query_log"

  stats_file="$CURRENT_CASE_DIR/query-stats.json"
  output=$(run_control query-stats 2>&1)
  status=$?
  assert_eq 0 "$status" "query-stats failed: $output" || return 1
  printf '%s\n' "$output" > "$stats_file"

  "$HOST_NODE" - "$stats_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
let stats;
try {
  stats = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (error) {
  console.error(`query-stats did not emit valid JSON: ${error.message}`);
  process.exit(1);
}
function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}
assert(stats.totalQueries === 6, `expected 6 valid rows, got ${stats.totalQueries}`);
assert(stats.blockedCount === 2, `expected only REJECT/DROP to be blocked, got ${stats.blockedCount}`);
assert(stats.blockRate === 33.3, `expected a 33.3 block rate, got ${stats.blockRate}`);
assert(stats.uniqueDomains === 5, `expected 5 unique domains, got ${stats.uniqueDomains}`);
assert(stats.topDomains.some(({domain, count}) => domain === 'pass.example' && count === 2),
  'topDomains did not count repeated PASS rows');
const expectedEscapedName = 'quote\\"slash\\\\name.example';
assert(stats.topDomains.some(({domain}) => domain === expectedEscapedName),
  'StringQuote escapes were not preserved through JSON encoding');
const blockedNames = stats.topBlocked.map(({domain}) => domain);
assert(blockedNames.includes('ad.example') && blockedNames.includes('tracker.example'),
  'topBlocked omitted a REJECT or DROP row');
assert(!blockedNames.includes('BLOCK.example'),
  'a PASS qname containing BLOCK was misclassified as blocked');
const hour01 = stats.timeline.find(({hour}) => hour === '01');
const hour02 = stats.timeline.find(({hour}) => hour === '02');
assert(hour01 && hour01.queries === 5 && hour01.blocked === 2,
  '01:00 timeline bucket is incorrect');
assert(hour02 && hour02.queries === 1 && hour02.blocked === 0,
  '02:00 timeline bucket is incorrect');
NODE
}

test_subscription_section_replacement_and_failure_rollback() {
  printf '%s\n' \
    'manual.example' \
    '## Auto-generated from subscriptions on 2026-01-01' \
    'legacy-stale.example' > "$MODULE_DIR/config/blocked-names.txt"
  printf '%s\n' '[{"url":"https://lists.example/one.txt","enabled":true}]' \
    > "$MODULE_DIR/config/subscriptions.json"
  printf '%s\n' '# comment' 'first.example' '! ignored' '' > "$MOCK_SUBSCRIPTION_PAYLOAD"

  output=$(run_control apply-subscriptions 2>&1)
  status=$?
  assert_eq 0 "$status" "initial subscription application failed: $output" || return 1
  blocklist="$MODULE_DIR/config/blocked-names.txt"
  assert_file_contains "$blocklist" 'manual.example' "manual rule was lost" || return 1
  assert_file_contains "$blocklist" 'first.example' "downloaded rule was not installed" || return 1
  assert_file_not_contains "$blocklist" 'legacy-stale.example' "legacy managed tail was retained" || return 1
  assert_eq 1 "$(grep -cF '## BEGIN dnscrypt-proxy-root managed subscriptions' "$blocklist")" \
    "managed begin marker count is wrong" || return 1
  assert_eq 1 "$(grep -cF '## END dnscrypt-proxy-root managed subscriptions' "$blocklist")" \
    "managed end marker count is wrong" || return 1

  printf '%s\n' 'manual-after.example' >> "$blocklist"
  printf '%s\n' 'second.example' > "$MOCK_SUBSCRIPTION_PAYLOAD"
  output=$(run_control apply-subscriptions 2>&1)
  status=$?
  assert_eq 0 "$status" "managed subscription replacement failed: $output" || return 1
  assert_file_contains "$blocklist" 'manual.example' "manual rule before section was lost" || return 1
  assert_file_contains "$blocklist" 'manual-after.example' "manual rule after section was lost" || return 1
  assert_file_contains "$blocklist" 'second.example' "replacement rule was not installed" || return 1
  assert_file_not_contains "$blocklist" 'first.example' "old managed rule accumulated" || return 1

  before=$(cat "$blocklist")
  MOCK_DOWNLOAD_MODE=failure
  output=$(run_control apply-subscriptions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failed subscription download was reported as success" || return 1
  assert_contains "$output" 'previous blocklist was kept' "rollback message is missing" || return 1
  after=$(cat "$blocklist")
  assert_eq "$before" "$after" "failed download changed the live blocklist" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'busybox wget ' \
    "subscription download did not exercise BusyBox wget fallback"
}

test_dynamic_nx_log_path_and_disabled_nx_log() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  mkdir -p "$MODULE_DIR/config/nested"
  printf '%s\n' \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = 'custom-query.log'" \
    '[nx_log]' \
    "  file = 'nested/custom-nx.log'" > "$config_file"
  : > "$MODULE_DIR/config/custom-query.log"
  MOCK_NX_LOG="$MODULE_DIR/config/nested/custom-nx.log"
  : > "$MOCK_NX_LOG"

  output=$(run_control leak-test 2>&1)
  status=$?
  assert_eq 0 "$status" "leak test with custom nx log failed: $output" || return 1
  assert_contains "$output" '"status":"protected"' \
    "custom nx_log path was not used" || return 1
  assert_contains "$output" '"matched":4' "not all custom nx log entries matched" || return 1
  assert_eq 4 "$(wc -l < "$MOCK_NX_LOG" | tr -d ' ')" \
    "nslookup mock did not record four queries" || return 1

  printf '%s\n' \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = 'custom-query.log'" > "$config_file"
  : > "$MODULE_DIR/config/custom-query.log"
  MOCK_NX_LOG="$MODULE_DIR/config/nx.log"
  : > "$MOCK_NX_LOG"
  output=$(run_control leak-test 2>&1)
  status=$?
  assert_eq 0 "$status" "leak test without nx_log failed: $output" || return 1
  assert_contains "$output" '"status":"leaking"' \
    "disabled nx_log incorrectly consumed a stale default nx.log"
}

test_resolver_rtt_log_parsing() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  printf '%s\n' \
    "server_names = ['cloudflare', 'quad9-dnscrypt-ip4-filter-pri', 'missing']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    "log_file = 'custom-proxy.log'" > "$config_file"
  printf '%s\n' \
    '[2026-08-28 10:00:00] [cloudflare] OK (DoH) - rtt: 91ms' \
    '[2026-08-28 10:00:01] [cloudflare] OK (DoH) - rtt: 17ms' \
    '[2026-08-28 10:00:02] [not-cloudflare] OK (DoH) - rtt: 1ms' \
    > "$MODULE_DIR/config/custom-proxy.log"
  printf '%s\n' \
    '[2026-08-28 10:00:03] [quad9-dnscrypt-ip4-filter-pri] OK (DNSCrypt) - rtt: 44ms' \
    > "$MODULE_DIR/logs/service.log"

  output=$(run_control ping-resolver cloudflare 2>&1)
  assert_eq '{"name":"cloudflare","latency_ms":17}' "$output" \
    "latest exact resolver RTT was not returned" || return 1
  output=$(run_control ping-resolver quad9-dnscrypt-ip4-filter-pri 2>&1)
  assert_eq '{"name":"quad9-dnscrypt-ip4-filter-pri","latency_ms":44}' "$output" \
    "service log RTT fallback was not returned" || return 1
  output=$(run_control ping-resolver missing 2>&1)
  assert_contains "$output" '"latency_ms":-1' "missing RTT was reported as a real latency" || return 1
  output=$(run_control ping-all 2>&1)
  assert_contains "$output" '"name":"cloudflare","latency_ms":17' \
    "ping-all missed custom proxy log RTT" || return 1
  assert_contains "$output" '"name":"quad9-dnscrypt-ip4-filter-pri","latency_ms":44' \
    "ping-all missed service log RTT" || return 1
  assert_contains "$output" '"name":"missing","latency_ms":-1' \
    "ping-all did not mark unavailable RTT"
}

test_firewall_rule_cleanup_is_idempotent() {
  output=$(run_control apply-iptables 2>&1)
  status=$?
  if ! assert_eq 0 "$status" "iptables application failed: $output"; then
    printf '%s\n' '    firewall mock call log:' >&2
    sed 's/^/      /' "$MOCK_CALL_LOG" >&2
    printf '%s\n' '    control log:' >&2
    sed 's/^/      /' "$MODULE_DIR/logs/control.log" >&2 2>/dev/null || true
    return 1
  fi
  assert_eq 3 "$(grep -cF 'iptables -t nat -D OUTPUT -p udp --dport 53 -j DNSCRYPT_PROXY' "$MOCK_CALL_LOG")" \
    "IPv4 duplicate UDP rules were not deleted until absent" || return 1
  assert_eq 3 "$(grep -cF 'ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT' "$MOCK_CALL_LOG")" \
    "legacy IPv6 duplicate rules were not deleted until absent" || return 1
  assert_file_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -I OUTPUT 1 -j DNSCRYPT_PROXY6' \
    "IPv6 dedicated chain was not installed" || return 1

  rm -rf "$MOCK_FIREWALL_STATE"
  mkdir -p "$MOCK_FIREWALL_STATE"
  : > "$MOCK_CALL_LOG"
  output=$(run_control remove-iptables 2>&1)
  status=$?
  assert_eq 0 "$status" "iptables removal failed: $output" || return 1
  assert_eq 3 "$(grep -cF 'ip6tables -t filter -D OUTPUT -j DNSCRYPT_PROXY6' "$MOCK_CALL_LOG")" \
    "IPv6 chain jumps were not deleted until absent" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'ip6tables -t filter -X DNSCRYPT_PROXY6' \
    "IPv6 dedicated chain was not removed"
}

test_lifecycle_lock_wait_and_shutdown_interlock() {
  MOCK_FLOCK_FAILURES=2
  export MOCK_FLOCK_FAILURES
  DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS=2
  export DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS
  output=$(run_control get-config 2>&1)
  status=$?
  assert_eq 0 "$status" "bounded control-lock wait did not recover: $output" || return 1
  assert_eq 3 "$(grep -cF 'busybox flock -n 8' "$MOCK_CALL_LOG")" \
    "control lock was not retried for the requested bound" || return 1

  rm -f "$MOCK_FLOCK_STATE"
  : > "$MOCK_CALL_LOG"
  MOCK_FLOCK_FAILURES=3
  export MOCK_FLOCK_FAILURES
  output=$(run_control get-config 2>&1)
  status=$?
  assert_eq 2 "$status" "exhausted lock contention did not return status 2: $output" || return 1
  assert_eq 3 "$(grep -cF 'busybox flock -n 8' "$MOCK_CALL_LOG")" \
    "control lock exceeded or undershot its bounded retries" || return 1

  unset DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS
  MOCK_FLOCK_FAILURES=0
  export MOCK_FLOCK_FAILURES
  rm -f "$MOCK_FLOCK_STATE"
  : > "$MOCK_CALL_LOG"
  : > "$MODULE_DIR/state/shutdown-requested"
  output=$(run_control apply-iptables 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "firewall installation succeeded during lifecycle shutdown" || return 1
  if grep -E '^(ip6?tables) ' "$MOCK_CALL_LOG" >/dev/null 2>&1; then
    fail "shutdown-interlocked firewall action still invoked iptables"
    return 1
  fi
}

run_private_dns_state_validation() {
  state_file=$1
  case "$TEST_SHELL_KIND" in
    sh)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" "$HOST_SH" -c \
        '. "$1"; private_dns_state_valid "$2"' lifecycle \
        "$MODULE_DIR/scripts/common.sh" "$state_file"
      ;;
    dash)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" "$HOST_DASH" -c \
        '. "$1"; private_dns_state_valid "$2"' lifecycle \
        "$MODULE_DIR/scripts/common.sh" "$state_file"
      ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" \
        "$HOST_BUSYBOX" ash -c \
        '. "$1"; private_dns_state_valid "$2"' lifecycle \
        "$MODULE_DIR/scripts/common.sh" "$state_file"
      ;;
  esac
}

run_dnscrypt_pid_probe() {
  case "$TEST_SHELL_KIND" in
    sh)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" DNSCRYPT_PROC_ROOT="$DNSCRYPT_PROC_ROOT" \
        "$HOST_SH" -c '. "$1"; dnscrypt_pid' pid-probe "$MODULE_DIR/scripts/common.sh"
      ;;
    dash)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" DNSCRYPT_PROC_ROOT="$DNSCRYPT_PROC_ROOT" \
        "$HOST_DASH" -c '. "$1"; dnscrypt_pid' pid-probe "$MODULE_DIR/scripts/common.sh"
      ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" DNSCRYPT_PROC_ROOT="$DNSCRYPT_PROC_ROOT" \
        "$HOST_BUSYBOX" ash -c '. "$1"; dnscrypt_pid' pid-probe "$MODULE_DIR/scripts/common.sh"
      ;;
  esac
}

test_dnscrypt_pid_requires_exact_daemon_argv() {
  proc_dir="$DNSCRYPT_PROC_ROOT/$$"
  pid_file="$MODULE_DIR/run/dnscrypt-proxy.pid"
  binary="$MODULE_DIR/bin/dnscrypt-proxy"
  config="$MODULE_DIR/config/dnscrypt-proxy.toml"
  mkdir -p "$proc_dir"
  printf '%s\n' "$$" > "$pid_file"

  # A control shell whose script path contains dnscrypt-proxy must not be
  # mistaken for the daemon merely because its cmdline contains that string.
  printf '%s\0%s\0%s\0' '/system/bin/sh' \
    "$MODULE_DIR/scripts/dnscrypt-control.sh" 'status' > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "control script cmdline was mistaken for dnscrypt-proxy"
    return 1
  fi

  printf '%s\0%s\0%s\0' "$binary" '-config' "$MODULE_DIR/config/other.toml" \
    > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "dnscrypt-proxy using another config was claimed by this module"
    return 1
  fi

  printf '%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '-resolve' \
    > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "one-shot dnscrypt-proxy -resolve was mistaken for the daemon"
    return 1
  fi

  printf '%s\0%s\0%s\0' "$binary" '-config' "$config" > "$proc_dir/cmdline"
  output=$(run_dnscrypt_pid_probe 2>&1)
  status=$?
  assert_eq 0 "$status" "exact daemon PID was rejected: $output" || return 1
  assert_eq "$$" "$output" "exact daemon PID lookup returned the wrong process" || return 1

  rm -f "$pid_file"
  output=$(run_dnscrypt_pid_probe 2>&1)
  status=$?
  assert_eq 0 "$status" "exact /proc fallback scan failed: $output" || return 1
  assert_eq "$$" "$output" "fallback scan returned the wrong daemon PID"
}

test_private_dns_state_validation_is_fail_closed() {
  state_file="$MODULE_DIR/state/private-dns.state"
  printf '%s\n' 'mode=hostname' 'specifier=dns.example' > "$state_file"
  run_private_dns_state_validation "$state_file" \
    || fail "valid Private DNS rollback state was rejected" || return 1

  printf '%s\n' 'mode=hostname' 'specifier=null' > "$state_file"
  if run_private_dns_state_validation "$state_file"; then
    fail "hostname mode without a provider was accepted"
    return 1
  fi
  printf '%s\n' 'mode=off' 'specifier=null' 'injected=1' > "$state_file"
  if run_private_dns_state_validation "$state_file"; then
    fail "Private DNS state with extra fields was accepted"
    return 1
  fi
  printf '%s\n' 'mode=invalid' 'specifier=dns.example' > "$state_file"
  if run_private_dns_state_validation "$state_file"; then
    fail "invalid Private DNS mode was accepted"
    return 1
  fi
}

test_webui_relative_assets_and_android_source_invariants() {
  index_file="$ROOT_DIR/webroot/index.html"
  if grep -E '(src|href)="/(assets|addons)/' "$index_file" >/dev/null 2>&1; then
    fail "WebUI contains an origin-root asset URL"
    return 1
  fi
  asset_count=0
  asset_paths=$(sed -n 's/.*\(src\|href\)="\.\/\([^"]*\)".*/\2/p' "$index_file")
  for asset_path in $asset_paths; do
    case "$asset_path" in
      assets/*|addons/*) ;;
      *) fail "unexpected relative WebUI asset path: $asset_path"; return 1 ;;
    esac
    [ -f "$ROOT_DIR/webroot/$asset_path" ] || {
      fail "relative WebUI asset does not exist: $asset_path"
      return 1
    }
    asset_count=$((asset_count + 1))
  done
  assert_eq 6 "$asset_count" "not all WebUI entry assets were checked" || return 1

  if grep -F -- '-port=5354' "$ROOT_DIR/scripts/dnscrypt-control.sh" >/dev/null 2>&1; then
    fail "Android-incompatible nslookup -port usage returned"
    return 1
  fi
  if grep -F '[ "$notify_count" -ge 3 ] && continue' "$ROOT_DIR/service.sh" >/dev/null 2>&1; then
    fail "notification throttling can still bypass watchdog recovery"
    return 1
  fi
  assert_file_contains "$ROOT_DIR/scripts/dnscrypt-control.sh" \
    'is_dnscrypt_pid "$pid" && kill -9 "$pid"' \
    "SIGKILL is not protected by exact PID identity revalidation" || return 1
  assert_file_contains "$ROOT_DIR/uninstall.sh" \
    'DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS=30' \
    "uninstall does not wait on the stable control lock inode" || return 1
  assert_file_contains "$ROOT_DIR/uninstall.sh" \
    'shutdown-stop' \
    "uninstall has no marker-gated cleanup fallback" || return 1
  if grep -E 'OLD_MODPATH/config"/\*\.(toml|txt|json|conf|rules)' "$ROOT_DIR/customize.sh" >/dev/null 2>&1; then
    fail "upgrade migration reverted to a broad extension glob"
    return 1
  fi
}

run_case() {
  case_name=$1
  case_function=$2
  case "$case_name" in
    *"${TEST_CASE_FILTER:-}"*) ;;
    *) return 0 ;;
  esac
  printf '  %-68s ' "$case_name"
  if ! setup_fixture; then
    echo 'FAIL'
    fail "fixture setup failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    cleanup_fixture
    return
  fi
  if "$case_function"; then
    echo 'PASS'
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo 'FAIL'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  cleanup_fixture
}

echo "Running dnscrypt-control tests with $TEST_SHELL_KIND"

run_case 'backup pruning combines both filename families' test_backup_pruning_combines_both_name_families
run_case 'resolver whitespace is normalized and empty elements rejected' test_resolver_whitespace_and_empty_elements
run_case 'BusyBox base64 fallback imports empty lists exactly' test_busybox_base64_fallback_and_empty_import
run_case 'save-list-b64 is exact, atomic, and fail-closed' test_save_list_b64_is_exact_atomic_and_fail_closed
run_case 'query stats follow the official TSV fields and emit valid JSON' test_query_stats_matches_official_tsv_contract
run_case 'subscription section replacement and failed-download rollback' test_subscription_section_replacement_and_failure_rollback
run_case 'custom and disabled nx_log paths are honored' test_dynamic_nx_log_path_and_disabled_nx_log
run_case 'resolver RTTs are parsed from the real proxy logs' test_resolver_rtt_log_parsing
run_case 'IPv4 and IPv6 firewall cleanup is idempotent' test_firewall_rule_cleanup_is_idempotent
run_case 'lifecycle lock waits are bounded and shutdown blocks firewall commits' test_lifecycle_lock_wait_and_shutdown_interlock
run_case 'PID discovery requires the exact daemon argv and config' test_dnscrypt_pid_requires_exact_daemon_argv
run_case 'Private DNS rollback state validation is fail-closed' test_private_dns_state_validation_is_fail_closed
run_case 'WebUI assets and Android portability source invariants' test_webui_relative_assets_and_android_source_invariants

printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
