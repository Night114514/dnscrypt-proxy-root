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
HOST_READLINK=$(find_host_tool readlink 2>/dev/null || true)
HOST_SLEEP=$(find_host_tool sleep 2>/dev/null || true)
HOST_CMP=$(find_host_tool cmp 2>/dev/null || true)
HOST_MKTEMP=$(find_host_tool mktemp 2>/dev/null || true)
HOST_KILL=$(find_host_tool kill 2>/dev/null || true)
HOST_STAT=$(find_host_tool stat 2>/dev/null || true)
HOST_CHMOD=$(find_host_tool chmod 2>/dev/null || true)
HOST_FLOCK=$(find_host_tool flock 2>/dev/null || true)
TEST_SHELL_KIND=${TEST_SHELL_KIND:-sh}

for required_tool in "$HOST_ENV" "$HOST_BASE64" "$HOST_CP" "$HOST_MV" "$HOST_NODE" "$HOST_TOUCH" "$HOST_TR" "$HOST_TRUE" "$HOST_READLINK" "$HOST_SLEEP" "$HOST_CMP" "$HOST_MKTEMP" "$HOST_KILL" "$HOST_STAT" "$HOST_CHMOD" "$HOST_FLOCK"; do
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
  ASSERT_EXPECTED=$1
  ASSERT_ACTUAL=$2
  ASSERT_MESSAGE=$3
  [ "$ASSERT_EXPECTED" = "$ASSERT_ACTUAL" ] ||
    fail "$ASSERT_MESSAGE (expected '$ASSERT_EXPECTED', got '$ASSERT_ACTUAL')"
}

assert_contains() {
  ASSERT_TEXT=$1
  ASSERT_NEEDLE=$2
  ASSERT_MESSAGE=$3
  case "$ASSERT_TEXT" in
    *"$ASSERT_NEEDLE"*) return 0 ;;
    *) fail "$ASSERT_MESSAGE (missing '$ASSERT_NEEDLE')" ;;
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

assert_file_not_exact_line() {
  if grep -Fx "$2" "$1" >/dev/null 2>&1; then
    fail "$3 (unexpected exact line '$2' in '$1')"
  fi
}

assert_file_empty() {
  [ -f "$1" ] || return 1
  [ ! -s "$1" ] || fail "$2 ('$1' is not empty)"
}

assert_not_exists() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "$2"
  fi
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
  unset DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS DNSCRYPT_CONFIG_CHECK_KILL_COMMAND
  unset DNSCRYPT_RUNTIME_ROOT DNSCRYPT_RUNTIME_TEST_MODE
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
  MOCK_MV_FAIL_MATCH_COUNT=0
  MOCK_MV_MATCH_COUNT_FILE="$CURRENT_CASE_DIR/mv-match-count"
  MOCK_FLOCK_FAILURES=0
  MOCK_FLOCK_STATE="$CURRENT_CASE_DIR/flock-state"
  MOCK_MANAGED_FIREWALL_POLICY=absent
  MOCK_FOREIGN_IPV6_REJECTS=absent
  MOCK_PRIVATE_DNS_MODE=opportunistic
  MOCK_PRIVATE_DNS_SPECIFIER=null
  MOCK_PRIVATE_DNS_MODE_FILE="$CURRENT_CASE_DIR/private-dns-mode"
  MOCK_PRIVATE_DNS_SPECIFIER_FILE="$CURRENT_CASE_DIR/private-dns-specifier"
  MOCK_SETTINGS_FAIL_MODE_PUT=0
  MOCK_SETTINGS_FAIL_MODE_PUT_VALUE=
  MOCK_DAEMON_REJECT_FAMILY_ON_START=0
  MOCK_DAEMON_PROBE_MODE=success
  MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR=0
  MOCK_DAEMON_REQUIRE_SU=0
  MOCK_DAEMON_REPLACE_CHECK_STAGE_TARGET=
  MOCK_DAEMON_START_MODE=success
  MOCK_LOCAL_HANDLER_MODE=success
  MOCK_STAT_UNTRUSTED_PATH=
  MOCK_STAT_UNTRUSTED_UID=3003
  MOCK_MKTEMP_MODE=normal
  MOCK_MKTEMP_SYMLINK_TARGET=
  MOCK_KILL_MODE=normal
  MOCK_FIREWALL_STATEFUL=0
  MOCK_MANAGED_FIREWALL_POLICY_FILE="$CURRENT_CASE_DIR/managed-firewall-policy"
  MOCK_RUNTIME_SOURCE_ROOT="$MODULE_DIR"
  MOCK_RUNTIME_PARENT=
  MOCK_RUNTIME_ROOT="$MODULE_DIR"
  MOCK_RUNTIME_PARENT_UID=0
  MOCK_RUNTIME_PARENT_GID=0
  MOCK_RUNTIME_PARENT_MODE=755
  MOCK_CHMOD_STATE="$CURRENT_CASE_DIR/chmod.state"
  MOCK_CHOWN_STATE="$CURRENT_CASE_DIR/chown.state"
  MOCK_CHMOD_SHUTDOWN_PATH=
  DNSCRYPT_RUNTIME_TEST_MODE=1
  DNSCRYPT_PROC_ROOT="$CURRENT_CASE_DIR/proc"
  DNSCRYPT_PROC_SYS_ROOT="$CURRENT_CASE_DIR/proc-sys"
  BUSYBOX_PRELUDE="$MODULE_DIR/scripts/busybox-prelude.sh"
  BUSYBOX_CONTROL_SCRIPT="$MODULE_DIR/scripts/dnscrypt-control-busybox.sh"

  mkdir -p "$MODULE_DIR/scripts" "$MODULE_DIR/bin" "$MODULE_DIR/config" \
    "$MODULE_DIR/data" \
    "$MODULE_DIR/state" "$MODULE_DIR/run" "$MODULE_DIR/logs" "$MODULE_DIR/tmp" \
    "$DNSCRYPT_PROC_ROOT" \
    "$DNSCRYPT_PROC_SYS_ROOT/kernel/random" \
    "$DNSCRYPT_PROC_SYS_ROOT/net/ipv4/conf/all" \
    "$TOOL_BIN" "$MOCK_FIREWALL_STATE"
  printf '%s\n' 'fixture-boot-id' > "$DNSCRYPT_PROC_SYS_ROOT/kernel/random/boot_id"
  printf '%s\n' '0' > "$DNSCRYPT_PROC_SYS_ROOT/net/ipv4/conf/all/route_localnet"
  sed 's/\r$//' "$ROOT_DIR/scripts/common.sh" > "$MODULE_DIR/scripts/common.sh"
  sed 's/\r$//' "$ROOT_DIR/scripts/dnscrypt-control.sh" > "$MODULE_DIR/scripts/dnscrypt-control.sh"
  sed 's/\r$//' "$ROOT_DIR/scripts/watchdog.sh" > "$MODULE_DIR/scripts/watchdog.sh"
  sed 's/\r$//' "$ROOT_DIR/config/dnscrypt-proxy.toml" > "$MODULE_DIR/config/dnscrypt-proxy.toml"
  chmod 0700 "$MODULE_DIR/config"
  chmod 0700 "$MODULE_DIR/data"
  chmod 0700 "$MODULE_DIR/state"
  chmod 0700 "$MODULE_DIR/run" "$MODULE_DIR/logs" "$MODULE_DIR/tmp"
  chmod 0600 "$MODULE_DIR/config/dnscrypt-proxy.toml"
  sed 's/\r$//' "$MOCK_SOURCE_DIR/busybox-ash-prelude" > "$BUSYBOX_PRELUDE"
  cp "$BUSYBOX_PRELUDE" "$BUSYBOX_CONTROL_SCRIPT"
  sed '1d; s/\r$//' "$ROOT_DIR/scripts/dnscrypt-control.sh" >> "$BUSYBOX_CONTROL_SCRIPT"
  : > "$MOCK_CALL_LOG"
  : > "$MOCK_SUBSCRIPTION_PAYLOAD"
  : > "$MOCK_CHMOD_STATE"
  : > "$MOCK_CHOWN_STATE"
  printf '%s\n' "$MOCK_PRIVATE_DNS_MODE" > "$MOCK_PRIVATE_DNS_MODE_FILE"
  printf '%s\n' "$MOCK_PRIVATE_DNS_SPECIFIER" > "$MOCK_PRIVATE_DNS_SPECIFIER_FILE"
  printf '%s\n' "$MOCK_MANAGED_FIREWALL_POLICY" > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  for list_file in allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt; do
    : > "$MODULE_DIR/config/$list_file"
    chmod 0600 "$MODULE_DIR/config/$list_file"
  done

  for fixture_tool in awk cat chgrp chmod cmp cp date dd grep head ln ls mkdir rm sed sh sort stat tail tr uniq wc; do
    link_host_tool "$fixture_tool" || return 1
  done
  install_mock mv mv
  install_mock mktemp mktemp
  install_mock kill kill
  install_mock dnscrypt-control-stat stat
  install_mock dnscrypt-control-chmod chmod
  install_mock dnscrypt-control-chown chown
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_TRUE" > "$TOOL_BIN/sleep"
  chmod 0755 "$TOOL_BIN/sleep"
  install_mock dnscrypt-control-busybox busybox-mock
  cp "$TOOL_BIN/busybox-mock" "$TOOL_BIN/busybox"
  install_mock dnscrypt-control-nslookup nslookup
  install_mock dnscrypt-control-firewall iptables
  install_mock dnscrypt-control-firewall ip6tables
  install_mock dnscrypt-control-readlink readlink
  install_mock dnscrypt-control-settings settings
  install_mock dnscrypt-control-sysctl sysctl
  install_mock dnscrypt-control-su su

  MOCK_HOST_BASE64=$HOST_BASE64
  MOCK_HOST_CP=$HOST_CP
  MOCK_REAL_MV=$HOST_MV
  MOCK_HOST_READLINK=$HOST_READLINK
  MOCK_HOST_SLEEP=$HOST_SLEEP
  MOCK_HOST_MKTEMP=$HOST_MKTEMP
  MOCK_HOST_KILL=$HOST_KILL
  MOCK_HOST_STAT=$HOST_STAT
  MOCK_HOST_CHMOD=$HOST_CHMOD
  MOCK_HOST_SH=$HOST_SH
  DNSCRYPT_RUNTIME_ROOT=$MODULE_DIR
  export MOCK_HOST_BASE64 MOCK_HOST_CP MOCK_CALL_LOG MOCK_FIREWALL_STATE
  export MOCK_SUBSCRIPTION_PAYLOAD MOCK_NX_LOG MOCK_NSLOOKUP_STATUS MOCK_DOWNLOAD_MODE
  export MOCK_REAL_MV MOCK_MV_MODE MOCK_INSTALL_TARGET
  export MOCK_MV_FAIL_MATCH_COUNT MOCK_MV_MATCH_COUNT_FILE
  export MOCK_HOST_READLINK MOCK_HOST_MKTEMP MOCK_MKTEMP_MODE MOCK_MKTEMP_SYMLINK_TARGET
  export MOCK_HOST_KILL MOCK_KILL_MODE
  export MOCK_HOST_STAT MOCK_HOST_CHMOD MOCK_STAT_UNTRUSTED_PATH MOCK_STAT_UNTRUSTED_UID
  export MOCK_HOST_SLEEP MOCK_HOST_SH MODULE_DIR
  export MOCK_FLOCK_FAILURES MOCK_FLOCK_STATE
  export MOCK_MANAGED_FIREWALL_POLICY MOCK_FOREIGN_IPV6_REJECTS MOCK_FIREWALL_STATEFUL
  export MOCK_MANAGED_FIREWALL_POLICY_FILE
  export MOCK_PRIVATE_DNS_MODE MOCK_PRIVATE_DNS_SPECIFIER MOCK_SETTINGS_FAIL_MODE_PUT
  export MOCK_SETTINGS_FAIL_MODE_PUT_VALUE
  export MOCK_PRIVATE_DNS_MODE_FILE MOCK_PRIVATE_DNS_SPECIFIER_FILE
  export MOCK_DAEMON_REJECT_FAMILY_ON_START MOCK_DAEMON_PROBE_MODE
  export MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR MOCK_DAEMON_REQUIRE_SU
  export MOCK_DAEMON_REPLACE_CHECK_STAGE_TARGET
  export MOCK_DAEMON_START_MODE
  export MOCK_LOCAL_HANDLER_MODE
  export MOCK_RUNTIME_SOURCE_ROOT MOCK_RUNTIME_PARENT MOCK_RUNTIME_ROOT
  export MOCK_RUNTIME_PARENT_UID MOCK_RUNTIME_PARENT_GID MOCK_RUNTIME_PARENT_MODE
  export MOCK_CHMOD_STATE MOCK_CHOWN_STATE MOCK_CHMOD_SHUTDOWN_PATH
  export DNSCRYPT_RUNTIME_ROOT DNSCRYPT_RUNTIME_TEST_MODE
  export DNSCRYPT_PROC_ROOT DNSCRYPT_PROC_SYS_ROOT
}

cleanup_fixture() {
  [ -n "$CURRENT_CASE_DIR" ] || return 0
  chmod -R u+rwX "$CURRENT_CASE_DIR" >/dev/null 2>&1 || true
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
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
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
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
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
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
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
  query_log="$MODULE_DIR/data/query-fixture.log"
  printf '%s\n' \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = '../data/query-fixture.log'" \
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

  output=$(run_control query-stats 2>&1)
  status=$?
  assert_eq 0 "$status" "query-stats failed: $output; calls: $(tr '\n' ';' < "$MOCK_CALL_LOG")" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'su 3003 -c ' \
    "query-stats did not snapshot the daemon-owned log as UID3003" || return 1
  QUERY_STATS_JSON=$output "$HOST_NODE" - <<'NODE'
let stats;
try {
  stats = JSON.parse(process.env.QUERY_STATS_JSON);
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
  chmod 0600 "$MODULE_DIR/config/subscriptions.json"
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
  printf '%s\n' \
    "user_name = '3003'" \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = '../data/custom-query.log'" \
    '[nx_log]' \
    "  file = '../data/custom-nx.log'" > "$config_file"
  : > "$MODULE_DIR/data/custom-query.log"
  MOCK_NX_LOG="$MODULE_DIR/data/custom-nx.log"
  : > "$MOCK_NX_LOG"

  output=$(run_control leak-test 2>&1)
  status=$?
  assert_eq 0 "$status" "leak test with custom nx log failed: $output" || return 1
  assert_contains "$output" '"status":"protected"' \
    "custom nx_log path was not used" || return 1
  assert_contains "$output" '"matched":4' "not all custom nx log entries matched" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'su 3003 -c ' \
    "leak-test did not snapshot daemon-owned logs as UID3003" || return 1
  assert_eq 2 "$(grep -c '^su 3003 -c ' "$MOCK_CALL_LOG")" \
    "leak-test did not snapshot both query and NX logs as UID3003" || return 1
  assert_eq 4 "$(wc -l < "$MOCK_NX_LOG" | tr -d ' ')" \
    "nslookup mock did not record four queries" || return 1
  assert_eq 4 "$(grep -c '^busybox timeout 8 nslookup ' "$MOCK_CALL_LOG")" \
    "system DNS leak-test triggers were not all bounded" || return 1

  printf '%s\n' \
    "user_name = '3003'" \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = '../data/custom-query.log'" > "$config_file"
  : > "$MODULE_DIR/data/custom-query.log"
  MOCK_NX_LOG="$MODULE_DIR/data/nx.log"
  : > "$MOCK_NX_LOG"
  output=$(run_control leak-test 2>&1)
  status=$?
  assert_eq 0 "$status" "leak test without nx_log failed: $output" || return 1
  assert_contains "$output" '"status":"leaking"' \
    "disabled nx_log incorrectly consumed a stale default nx.log" || return 1
  assert_eq 3 "$(grep -c '^su 3003 -c ' "$MOCK_CALL_LOG")" \
    "disabled nx_log caused an extra privileged log read" || return 1
  assert_eq 8 "$(grep -c '^busybox timeout 8 nslookup ' "$MOCK_CALL_LOG")" \
    "second leak-test run bypassed the bounded system resolver wrapper"
}

test_dns_test_uses_one_bounded_local_and_direct_query() {
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" \
    > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR=1
  MOCK_DAEMON_REQUIRE_SU=1
  export MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR MOCK_DAEMON_REQUIRE_SU

  output=$(run_control dns-test dns.google 2>&1)
  status=$?
  assert_eq 0 "$status" "bounded DNS diagnostic failed: $output" || return 1
  assert_contains "$output" '"domain":"dns.google"' \
    "DNS diagnostic did not return the requested domain" || return 1
  assert_contains "$output" '"latency_ms":' \
    "DNS diagnostic omitted latency" || return 1
  assert_eq 1 "$(grep -c '^daemon-resolve-config ' "$MOCK_CALL_LOG")" \
    "DNS diagnostic ran the local resolver more than once" || return 1
  assert_eq 1 "$(grep -c '^su 3003 -c ' "$MOCK_CALL_LOG")" \
    "DNS diagnostic did not run its one-shot resolver as UID3003" || return 1
  assert_eq 1 "$(grep -c '^busybox timeout 8 nslookup dns.google 9.9.9.9$' "$MOCK_CALL_LOG")" \
    "direct DNS comparison was not bounded by eight seconds"
}

test_resolver_rtt_log_parsing() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  printf '%s\n' \
    "user_name = '3003'" \
    "server_names = ['cloudflare', 'quad9-dnscrypt-ip4-filter-pri', 'missing']" \
    "listen_addresses = ['127.0.0.1:5354']" > "$config_file"
  printf '%s\n' \
    '[2026-08-28 10:00:00] [cloudflare] OK (DoH) - rtt: 91ms' \
    '[2026-08-28 10:00:01] [cloudflare] OK (DoH) - rtt: 17ms' \
    '[2026-08-28 10:00:02] [not-cloudflare] OK (DoH) - rtt: 1ms' \
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
  setup_ready_daemon_fixture
  printf '%s\n' strict > "$MODULE_DIR/state/dns-mode.state"
  printf '%s\n' present > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  MOCK_MANAGED_FIREWALL_POLICY=present
  MOCK_FIREWALL_STATEFUL=1
  printf '%s\n' fixture-boot-id > "$MODULE_DIR/state/legacy-firewall-adopt.state"
  MOCK_FOREIGN_IPV6_REJECTS=present
  export MOCK_MANAGED_FIREWALL_POLICY MOCK_FIREWALL_STATEFUL MOCK_FOREIGN_IPV6_REJECTS
  output=$(run_control apply-iptables 2>&1)
  status=$?
  if ! assert_eq 0 "$status" "iptables application failed: $output"; then
    printf '%s\n' '    firewall mock call log:' >&2
    sed 's/^/      /' "$MOCK_CALL_LOG" >&2
    printf '%s\n' '    control log:' >&2
    sed 's/^/      /' "$MODULE_DIR/logs/control.log" >&2 2>/dev/null || true
    return 1
  fi
  assert_eq 4 "$(grep -cF 'iptables -t nat -D OUTPUT -p udp --dport 53 -j DNSCRYPT_PROXY' "$MOCK_CALL_LOG")" \
    "legacy and token-bound IPv4 UDP jumps were not each deleted until absent" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT' \
    "foreign direct IPv6 DNS rules were deleted during apply" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D OUTPUT -p tcp --dport 53 -j REJECT' \
    "foreign direct IPv6 TCP DNS rules were deleted during apply" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D INPUT -p udp --dport 53 -j REJECT' \
    "foreign direct IPv6 input rules were deleted during apply" || return 1
  assert_file_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -I OUTPUT 1 -j DNSCRYPT_PROXY6' \
    "IPv6 dedicated chain was not installed" || return 1
  assert_eq "$(printf 'tcp\nudp')" "$(cat "$MOCK_FIREWALL_STATE/ipv4-output-order")" \
    "stateful -I position semantics did not produce TCP then UDP" || return 1

  rm -rf "$MOCK_FIREWALL_STATE"
  mkdir -p "$MOCK_FIREWALL_STATE"
  : > "$MOCK_CALL_LOG"
  MOCK_MANAGED_FIREWALL_POLICY=absent
  export MOCK_MANAGED_FIREWALL_POLICY
  output=$(run_control remove-iptables 2>&1)
  status=$?
  assert_eq 0 "$status" "iptables removal failed: $output" || return 1
  assert_eq 3 "$(grep -cF 'ip6tables -t filter -D OUTPUT -j DNSCRYPT_PROXY6' "$MOCK_CALL_LOG")" \
    "IPv6 chain jumps were not deleted until absent" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'ip6tables -t filter -X DNSCRYPT_PROXY6' \
    "IPv6 dedicated chain was not removed" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT' \
    "foreign direct IPv6 DNS rules were deleted during removal" || return 1

  : > "$MOCK_CALL_LOG"
  printf '%s\n' fixture-boot-id > "$MODULE_DIR/state/legacy-ipv6-reboot.state"
  output=$(run_control remove-iptables 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "indistinguishable legacy IPv6 rules were deleted without a reboot" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D OUTPUT -p udp --dport 53 -j REJECT' \
    "legacy IPv6 UDP output rule was deleted despite ambiguous ownership" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D OUTPUT -p tcp --dport 53 -j REJECT' \
    "legacy IPv6 TCP output rule was deleted despite ambiguous ownership" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" \
    'ip6tables -t filter -D INPUT -p udp --dport 53 -j REJECT' \
    "legacy IPv6 input rule was deleted despite ambiguous ownership" || return 1
  [ -e "$MODULE_DIR/state/legacy-ipv6-reboot.state" ] \
    || fail "legacy IPv6 reboot marker disappeared before reboot" || return 1
  printf '%s\n' next-boot-id > "$DNSCRYPT_PROC_SYS_ROOT/kernel/random/boot_id"
  output=$(run_control remove-iptables 2>&1)
  status=$?
  assert_eq 0 "$status" "stale legacy marker did not clear after simulated reboot: $output" || return 1
  [ ! -e "$MODULE_DIR/state/legacy-ipv6-reboot.state" ] \
    || fail "stale legacy IPv6 reboot marker survived the next boot"
}

test_foreign_same_name_firewall_chains_are_never_claimed() {
  printf '%s\n' strict > "$MODULE_DIR/state/dns-mode.state"
  for policy_shape in foreign present; do
    MOCK_MANAGED_FIREWALL_POLICY=$policy_shape
    printf '%s\n' "$policy_shape" > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
    export MOCK_MANAGED_FIREWALL_POLICY
    rm -f "$MODULE_DIR/state/firewall-owned.state" \
      "$MODULE_DIR/state/legacy-firewall-adopt.state"
    : > "$MOCK_CALL_LOG"
    output=$(run_control apply-iptables 2>&1)
    status=$?
    [ "$status" -ne 0 ] \
      || fail "unproven $policy_shape same-name chains were claimed" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -F DNSCRYPT_PROXY' \
      "unproven IPv4 chain was flushed" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -F DNSCRYPT_PROXY6' \
      "unproven IPv6 chain was flushed" || return 1

    : > "$MOCK_CALL_LOG"
    output=$(run_control remove-iptables 2>&1)
    status=$?
    assert_eq 0 "$status" "foreign-chain preserving removal failed: $output" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -F DNSCRYPT_PROXY' \
      "unproven IPv4 chain was flushed during removal" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -X DNSCRYPT_PROXY' \
      "unproven IPv4 chain was deleted during removal" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -F DNSCRYPT_PROXY6' \
      "unproven IPv6 chain was flushed during removal" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -X DNSCRYPT_PROXY6' \
      "unproven IPv6 chain was deleted during removal" || return 1
  done

  # A valid marker from an earlier generation must not authorize a foreign
  # replacement created after an external firewall reset.
  MOCK_MANAGED_FIREWALL_POLICY=foreign
  printf '%s\n' foreign > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  printf '%s\n' 'fixture-boot-id:Ab12Cd' > "$MODULE_DIR/state/firewall-owned.state"
  export MOCK_MANAGED_FIREWALL_POLICY
  : > "$MOCK_CALL_LOG"
  output=$(run_control remove-iptables 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "orphan marker authorized foreign replacement deletion" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -F DNSCRYPT_PROXY' \
    "orphan marker flushed a token-mismatched IPv4 chain" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -X DNSCRYPT_PROXY6' \
    "orphan marker deleted a token-mismatched IPv6 chain" || return 1
  : > "$MOCK_CALL_LOG"
  output=$(run_control apply-iptables 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "orphan marker authorized foreign replacement mutation" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -F DNSCRYPT_PROXY' \
    "orphan marker flushed a replacement chain during apply"
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

test_managed_inputs_fail_closed_on_mode_owner_and_symlink() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  config_before="$CURRENT_CASE_DIR/config.before"
  "$HOST_CP" "$config_file" "$config_before" || return 1

  "$TOOL_BIN/chmod" 0666 "$config_file"
  output=$(run_control get-config 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "get-config read a mode-unsafe TOML" || return 1
  assert_file_not_contains "$CURRENT_CASE_DIR/calls.log" 'dnscrypt-control-daemon' \
    "unsafe get-config unexpectedly launched the proxy" || return 1
  "$TOOL_BIN/chmod" 0600 "$config_file"

  "$TOOL_BIN/chmod" 0666 "$MODULE_DIR/config/blocked-names.txt"
  output=$(run_control set-resolvers cloudflare 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "set-resolvers laundered an unsafe managed list" || return 1
  "$HOST_CMP" -s "$config_before" "$config_file" \
    || fail "set-resolvers changed TOML after an auxiliary input trust failure" || return 1
  "$TOOL_BIN/chmod" 0600 "$MODULE_DIR/config/blocked-names.txt"

  secret_file="$CURRENT_CASE_DIR/root-only-secret"
  printf '%s\n' 'must-not-be-exposed' > "$secret_file"
  ln -s "$secret_file" "$MODULE_DIR/config/subscriptions.json"
  output=$(run_control get-subscriptions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "get-subscriptions followed a symlink" || return 1
  case "$output" in
    *must-not-be-exposed*) fail "symlink target contents were exposed"; return 1 ;;
  esac
  output=$(run_control apply-subscriptions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "apply-subscriptions parsed a symlink" || return 1
  assert_eq must-not-be-exposed "$(cat "$secret_file")" \
    "subscription symlink target was modified" || return 1

  rm -f "$MODULE_DIR/config/subscriptions.json"
  printf '%s\n' '[]' > "$MODULE_DIR/config/subscriptions.json"
  chmod 0600 "$MODULE_DIR/config/subscriptions.json"
  install_mock dnscrypt-control-stat stat || return 1
  MOCK_STAT_UNTRUSTED_PATH="$MODULE_DIR/config/subscriptions.json"
  MOCK_STAT_UNTRUSTED_UID=3003
  export MOCK_STAT_UNTRUSTED_PATH MOCK_STAT_UNTRUSTED_UID
  output=$(run_control get-subscriptions 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "UID-3003-owned subscriptions were trusted" || return 1
  output=$(run_control export-config 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "UID-3003-owned subscriptions were exported by root" || return 1
}

test_log_readers_reject_symlinks_and_unbounded_paths() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  printf '%s\n' \
    "user_name = '3003'" \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = '../data/query-link.log'" \
    "  format = 'tsv'" > "$config_file"
  chmod 0600 "$config_file"
  secret_file="$CURRENT_CASE_DIR/root-log-secret"
  printf '%s\n' 'root-log-secret-value' > "$secret_file"
  ln -s "$secret_file" "$MODULE_DIR/data/query-link.log"

  output=$(run_control logs 999999999 2>&1)
  status=$?
  assert_eq 0 "$status" "logs command failed while refusing a symlink: $output" || return 1
  case "$output" in
    *root-log-secret-value*) fail "logs followed an attacker-controlled symlink"; return 1 ;;
  esac
  case "$output" in
    *unsafe*) fail "protected proxy log was unexpectedly rejected"; return 1 ;;
  esac

  output=$(run_control query-stats 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "query-stats followed a symlink" || return 1
  assert_contains "$output" 'unsafe_query_log' "unsafe query log was not reported" || return 1

  printf '%s\n' \
    "user_name = '3003'" \
    "server_names = ['cloudflare']" \
    "listen_addresses = ['127.0.0.1:5354']" \
    "log_file = '../data/proxy-link.log'" > "$config_file"
  ln -s "$secret_file" "$MODULE_DIR/data/proxy-link.log"
  output=$(run_control logs 100 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsafe pre-drop log path passed config validation" || return 1
  case "$output" in
    *root-log-secret-value*) fail "unsafe pre-drop log target contents were exposed"; return 1 ;;
  esac
  assert_eq root-log-secret-value "$(cat "$secret_file")" \
    "unsafe pre-drop log target was modified"
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

run_common_probe() {
  probe=$1
  case "$TEST_SHELL_KIND" in
    sh)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" \
        DNSCRYPT_PROC_ROOT="$DNSCRYPT_PROC_ROOT" DNSCRYPT_PROC_SYS_ROOT="$DNSCRYPT_PROC_SYS_ROOT" \
        "$HOST_SH" -c '. "$1"; eval "$2"' common-probe \
        "$MODULE_DIR/scripts/common.sh" "$probe"
      ;;
    dash)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" \
        DNSCRYPT_PROC_ROOT="$DNSCRYPT_PROC_ROOT" DNSCRYPT_PROC_SYS_ROOT="$DNSCRYPT_PROC_SYS_ROOT" \
        "$HOST_DASH" -c '. "$1"; eval "$2"' common-probe \
        "$MODULE_DIR/scripts/common.sh" "$probe"
      ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MODDIR="$MODULE_DIR" MOCK_COMMAND_DIR="$TOOL_BIN" \
        DNSCRYPT_PROC_ROOT="$DNSCRYPT_PROC_ROOT" DNSCRYPT_PROC_SYS_ROOT="$DNSCRYPT_PROC_SYS_ROOT" \
        "$HOST_BUSYBOX" ash -c '. "$1"; . "$2"; eval "$3"' common-probe \
        "$BUSYBOX_PRELUDE" "$MODULE_DIR/scripts/common.sh" "$probe"
      ;;
  esac
}

prepare_runtime_tree_fixture() {
  runtime_parent="$CURRENT_CASE_DIR/runtime-parent"
  runtime_root="$runtime_parent/dnscrypt-runtime"
  rm -rf "$runtime_parent"
  : > "$MOCK_CHMOD_STATE"
  : > "$MOCK_CHOWN_STATE"
  mkdir -p "$runtime_parent" || return 1
  "$HOST_CHMOD" 0755 "$runtime_parent" || return 1
  MOCK_RUNTIME_SOURCE_ROOT="$MODULE_DIR"
  MOCK_RUNTIME_PARENT="$runtime_parent"
  MOCK_RUNTIME_ROOT="$runtime_root"
  MOCK_RUNTIME_PARENT_UID=0
  MOCK_RUNTIME_PARENT_GID=0
  MOCK_RUNTIME_PARENT_MODE=755
  DNSCRYPT_RUNTIME_ROOT="$runtime_root"
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  "$HOST_CHMOD" 0755 "$MODULE_DIR/bin/dnscrypt-proxy" || return 1
  : > "$MOCK_CALL_LOG"
  export MOCK_RUNTIME_SOURCE_ROOT MOCK_RUNTIME_PARENT MOCK_RUNTIME_ROOT
  export MOCK_RUNTIME_PARENT_UID MOCK_RUNTIME_PARENT_GID MOCK_RUNTIME_PARENT_MODE
  export DNSCRYPT_RUNTIME_ROOT
}

test_runtime_tree_is_copied_with_exact_layout_and_canonical_argv() {
  prepare_runtime_tree_fixture || return 1

  output=$(run_common_probe '
    ensure_runtime_tree || exit $?
    printf "%s\n%s\n%s\n%s\n" \
      "$RUNTIME_ROOT" "$RUNTIME_BIN" "$RUNTIME_CONFIG_DIR" "$RUNTIME_CONFIG_FILE"
  ' 2>&1)
  status=$?
  expected=$(printf '%s\n%s\n%s\n%s' \
    "$DNSCRYPT_RUNTIME_ROOT" \
    "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy" \
    "$DNSCRYPT_RUNTIME_ROOT/active" \
    "$DNSCRYPT_RUNTIME_ROOT/active/dnscrypt-proxy.toml")
  assert_eq 0 "$status" "safe runtime tree creation failed: $output" || return 1
  assert_eq "$expected" "$output" "canonical runtime variables did not use the persistent tree" || return 1

  assert_eq 755 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT")" \
    "runtime root did not have exact mode 0755" || return 1
  assert_eq 755 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT/bin")" \
    "runtime bin directory did not have exact mode 0755" || return 1
  assert_eq 755 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy")" \
    "runtime binary did not have exact mode 0755" || return 1
  assert_eq 700 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT/config")" \
    "canonical config directory did not have exact mode 0700" || return 1
  assert_eq 500 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT/active")" \
    "active config directory did not have exact mode 0500" || return 1
  assert_eq 700 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT/data")" \
    "runtime data directory did not have exact mode 0700" || return 1
  assert_eq 600 "$("$TOOL_BIN/stat" -c %a "$DNSCRYPT_RUNTIME_ROOT/.layout-owner")" \
    "runtime layout marker did not have exact mode 0600" || return 1
  assert_eq 'dnscrypt-proxy-root:5' "$(cat "$DNSCRYPT_RUNTIME_ROOT/.layout-owner")" \
    "runtime layout marker content was not exact" || return 1
  assert_eq 22 "$(wc -c < "$DNSCRYPT_RUNTIME_ROOT/.layout-owner" | tr -d ' ')" \
    "runtime layout marker was not exactly one LF-terminated line" || return 1

  for runtime_input in dnscrypt-proxy.toml allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt; do
    canonical_path="$DNSCRYPT_RUNTIME_ROOT/config/$runtime_input"
    active_path="$DNSCRYPT_RUNTIME_ROOT/active/$runtime_input"
    [ -f "$canonical_path" ] && [ ! -L "$canonical_path" ] \
      || fail "canonical runtime input was not copied as a regular file: $runtime_input" || return 1
    assert_eq '0:0:600' "$("$TOOL_BIN/stat" -c %u:%g:%a "$canonical_path")" \
      "canonical runtime input was not root-only: $runtime_input" || return 1
    [ -f "$active_path" ] && [ ! -L "$active_path" ] \
      || fail "managed runtime input was not copied as a regular file: $runtime_input" || return 1
    assert_eq 400 "$("$TOOL_BIN/stat" -c %a "$active_path")" \
      "managed runtime input did not have exact mode 0400: $runtime_input" || return 1
    assert_eq '3003:0:400' "$("$TOOL_BIN/stat" -c %u:%g:%a "$active_path")" \
      "managed runtime input was readable through the shared AID_INET group: $runtime_input" || return 1
    cmp -s "$MODULE_DIR/config/$runtime_input" "$canonical_path" \
      || fail "canonical runtime input bytes changed during copy: $runtime_input" || return 1
    if [ "$runtime_input" = dnscrypt-proxy.toml ]; then
      assert_file_not_contains "$active_path" 'user_name' \
        "UID3003 execution config retained a second privilege-drop directive" || return 1
      assert_file_contains "$canonical_path" "user_name = '3003'" \
        "canonical config lost the documented UID invariant" || return 1
    else
      cmp -s "$MODULE_DIR/config/$runtime_input" "$active_path" \
        || fail "managed runtime input bytes changed during copy: $runtime_input" || return 1
    fi
  done
  assert_eq '0:0:755' "$("$TOOL_BIN/stat" -c %u:%g:%a "$DNSCRYPT_RUNTIME_ROOT/bin")" \
    "runtime bin ownership contract was not root:root" || return 1
  assert_eq '0:0:700' "$("$TOOL_BIN/stat" -c %u:%g:%a "$DNSCRYPT_RUNTIME_ROOT/config")" \
    "canonical config ownership contract was not root-only" || return 1
  assert_eq '3003:0:500' "$("$TOOL_BIN/stat" -c %u:%g:%a "$DNSCRYPT_RUNTIME_ROOT/active")" \
    "active config directory was not private to the daemon UID" || return 1
  assert_eq '3003:0:700' "$("$TOOL_BIN/stat" -c %u:%g:%a "$DNSCRYPT_RUNTIME_ROOT/data")" \
    "runtime data ownership contract was not UID-3003 private" || return 1
  assert_eq '3003:0:600' "$("$TOOL_BIN/stat" -c %u:%g:%a "$DNSCRYPT_RUNTIME_ROOT/.daemon-pid")" \
    "unprivileged daemon PID handshake did not have the exact owner-only mode" || return 1
  assert_file_not_exact_line "$MOCK_CALL_LOG" "chmod 0755 $MOCK_RUNTIME_PARENT" \
    "runtime setup changed the parent directory mode" || return 1

  # This check starts an external mock through background su and waits for its
  # completion or PID handshake. Most tests replace sleep with a no-op, but that
  # turns the bounded startup wait into a scheduler-dependent tight loop on a
  # loaded CI runner. Preserve the real bounded wait at this async boundary.
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_SLEEP" > "$TOOL_BIN/sleep" \
    || return 1
  "$HOST_CHMOD" 0755 "$TOOL_BIN/sleep" || return 1

  : > "$MOCK_CALL_LOG"
  output=$(run_common_probe '
    ensure_runtime_tree || exit $?
    run_bounded_config_check "$CONFIG_FILE" "$CONTROL_LOG" "$RUNTIME_BIN"
  ' 2>&1)
  status=$?
  assert_eq 0 "$status" "canonical runtime config check failed: $output" || return 1
  assert_file_contains "$MOCK_CALL_LOG" \
    "daemon-check-config $DNSCRYPT_RUNTIME_ROOT/.config-check." \
    "config check did not use the canonical runtime config argv"
}

test_runtime_tree_rejects_unsafe_parent_symlink_and_collisions() {
  prepare_runtime_tree_fixture || return 1
  MOCK_RUNTIME_PARENT_MODE=775
  export MOCK_RUNTIME_PARENT_MODE
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "a group-writable runtime parent was accepted"
    return 1
  fi
  [ ! -e "$DNSCRYPT_RUNTIME_ROOT" ] \
    || fail "unsafe runtime parent still created a runtime tree" || return 1
  assert_file_not_exact_line "$MOCK_CALL_LOG" "chmod 0755 $MOCK_RUNTIME_PARENT" \
    "unsafe runtime parent was repaired with chmod" || return 1

  prepare_runtime_tree_fixture || return 1
  mkdir -p "$CURRENT_CASE_DIR/runtime-symlink-target" || return 1
  ln -s "$CURRENT_CASE_DIR/runtime-symlink-target" "$DNSCRYPT_RUNTIME_ROOT" || return 1
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "a symlink runtime target was accepted"
    return 1
  fi
  [ ! -e "$CURRENT_CASE_DIR/runtime-symlink-target/.layout-owner" ] \
    || fail "runtime creation followed a symlink target" || return 1

  prepare_runtime_tree_fixture || return 1
  mkdir -p "$DNSCRYPT_RUNTIME_ROOT" || return 1
  printf '%s\n' occupied > "$DNSCRYPT_RUNTIME_ROOT/foreign-entry"
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "a nonempty runtime target was accepted"
    return 1
  fi
  assert_eq occupied "$(cat "$DNSCRYPT_RUNTIME_ROOT/foreign-entry")" \
    "collision handling modified foreign runtime content" || return 1
  [ ! -e "$DNSCRYPT_RUNTIME_ROOT/.layout-owner" ] \
    || fail "collision handling claimed a foreign runtime tree" || return 1

  prepare_runtime_tree_fixture || return 1
  mkdir -p "$DNSCRYPT_RUNTIME_ROOT/bin" "$DNSCRYPT_RUNTIME_ROOT/config" || return 1
  printf '%s\n' 'wrong-owner' > "$DNSCRYPT_RUNTIME_ROOT/.layout-owner"
  "$HOST_CHMOD" 0600 "$DNSCRYPT_RUNTIME_ROOT/.layout-owner" || return 1
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "a runtime tree with a foreign layout marker was accepted"
    return 1
  fi
  assert_file_not_exact_line "$MOCK_CALL_LOG" "chmod 0755 $MOCK_RUNTIME_PARENT" \
    "collision recovery changed the parent directory mode"

  prepare_runtime_tree_fixture || return 1
  run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1 || {
    fail "safe runtime fixture could not be created for active-snapshot trust test"
    return 1
  }
  printf '%s|%s\n' 600 \
    "$DNSCRYPT_RUNTIME_ROOT/active/dnscrypt-proxy.toml" >> "$MOCK_CHMOD_STATE"
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "a runtime tree with an unexpected active-configuration mode was accepted"
    return 1
  fi
}

test_runtime_tree_recovers_transactions_and_honors_shutdown_lock() {
  prepare_runtime_tree_fixture || return 1

  # A failed atomic publish must not expose a partial canonical tree, and a
  # subsequent invocation must be able to create it from scratch.
  MOCK_MV_MODE=fail
  MOCK_INSTALL_TARGET=$DNSCRYPT_RUNTIME_ROOT
  export MOCK_MV_MODE MOCK_INSTALL_TARGET
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "a failed runtime publish was reported as success"
    return 1
  fi
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT" \
    "failed runtime publish exposed the canonical path" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT.creating" \
    "failed runtime publish left its owned staging tree" || return 1
  assert_not_exists "$MODULE_DIR/state/runtime-tree-op.state" \
    "failed runtime publish left a stale creation operation" || return 1

  # Recreate the exact durable state left by a process killed after mkdir but
  # before the private staging tree was populated. The next ensure must prove
  # ownership, discard the partial tree, and complete a fresh publication.
  output=$(run_common_probe '
    write_runtime_operation create || exit $?
    mkdir "$RUNTIME_CREATE_PATH" || exit $?
    chown 0:0 "$RUNTIME_CREATE_PATH" || exit $?
    chmod 0700 "$RUNTIME_CREATE_PATH"
  ' 2>&1)
  status=$?
  assert_eq 0 "$status" "failed to construct interrupted creation fixture: $output" || return 1

  MOCK_MV_MODE=success
  MOCK_INSTALL_TARGET=
  export MOCK_MV_MODE MOCK_INSTALL_TARGET
  output=$(run_common_probe 'ensure_runtime_tree' 2>&1)
  status=$?
  assert_eq 0 "$status" "runtime creation could not recover after failed publish: $output" || return 1

  # Simulate a power loss after the durable remove state and atomic tombstone
  # rename. A retry must finish deletion instead of treating absence as done.
  output=$(run_common_probe '
    write_runtime_operation remove || exit $?
    mv "$RUNTIME_ROOT" "$RUNTIME_REMOVE_PATH"
  ' 2>&1)
  status=$?
  assert_eq 0 "$status" "failed to construct interrupted removal fixture: $output" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT" \
    "interrupted removal fixture retained the canonical path" || return 1
  [ -d "$DNSCRYPT_RUNTIME_ROOT.removing" ] \
    || fail "interrupted removal fixture did not retain the tombstone" || return 1
  output=$(run_common_probe 'remove_runtime_tree' 2>&1)
  status=$?
  assert_eq 0 "$status" "runtime removal retry failed: $output" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT.removing" \
    "runtime removal retry left the tombstone" || return 1
  assert_not_exists "$MODULE_DIR/state/runtime-tree-op.state" \
    "runtime removal retry left durable operation state" || return 1

  # A real kernel-held lifecycle lock must fail without creating state or
  # paths. Install the host flock only for this isolated case so the separate
  # BusyBox fallback tests still exercise their own dispatch path.
  prepare_runtime_tree_fixture || return 1
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_FLOCK" > "$TOOL_BIN/flock"
  chmod 0755 "$TOOL_BIN/flock"
  exec 7>> "$MODULE_DIR/run/runtime-tree.lock" || return 1
  "$HOST_FLOCK" -n 7 || return 1
  if run_common_probe '
      DNSCRYPT_RUNTIME_LOCK_WAIT_SECONDS=0
      export DNSCRYPT_RUNTIME_LOCK_WAIT_SECONDS
      ensure_runtime_tree
    ' >/dev/null 2>&1; then
    fail "runtime creation bypassed a contended lifecycle lock"
    "$HOST_FLOCK" -u 7
    exec 7>&-
    return 1
  fi
  "$HOST_FLOCK" -u 7 || return 1
  exec 7>&-
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT" \
    "lock contention still created the canonical runtime" || return 1
  assert_not_exists "$MODULE_DIR/state/runtime-tree-op.state" \
    "lock contention still created durable operation state" || return 1

  # Trigger shutdown at the final stage chmod. The publish-time recheck must
  # cancel creation and clean its own private staging state.
  rm -f "$TOOL_BIN/flock" "$MOCK_FLOCK_STATE"
  MOCK_FLOCK_FAILURES=0
  MOCK_CHMOD_SHUTDOWN_PATH="$DNSCRYPT_RUNTIME_ROOT.creating"
  export MOCK_FLOCK_FAILURES MOCK_CHMOD_SHUTDOWN_PATH
  if run_common_probe 'ensure_runtime_tree' >/dev/null 2>&1; then
    fail "runtime tree was published after shutdown began"
    return 1
  fi
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT" \
    "shutdown-time creation exposed the canonical runtime" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT.creating" \
    "shutdown-time creation left its staging tree" || return 1
  assert_not_exists "$MODULE_DIR/state/runtime-tree-op.state" \
    "shutdown-time creation left durable operation state"
}

test_runtime_version_authority_ignores_module_marker() {
  prepare_runtime_tree_fixture || return 1
  output=$(run_common_probe 'ensure_runtime_tree' 2>&1)
  status=$?
  assert_eq 0 "$status" "runtime setup failed: $output" || return 1

  printf '%s\n' '#!/bin/sh' "printf '%s\\n' '1.0.0'" \
    > "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy"
  chmod 0755 "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy"
  printf '%s\n' '2.1.18' > "$MODULE_DIR/run/installed-version"
  chmod 0600 "$MODULE_DIR/run/installed-version"

  output=$(run_common_probe 'installed_version' 2>&1)
  status=$?
  assert_eq 0 "$status" "installed_version failed: $output" || return 1
  assert_eq 1.0.0 "$output" \
    "module-local marker masked the canonical executable version"
}

test_module_binary_is_promoted_before_persistent_start_and_rolled_back() {
  prepare_runtime_tree_fixture || return 1
  output=$(run_common_probe 'ensure_runtime_tree' 2>&1)
  status=$?
  assert_eq 0 "$status" "runtime setup failed: $output" || return 1

  # Model an offline module upgrade: the persistent executable is still 1.0.0,
  # while the already-verified module-local executable is 2.1.18.  No network
  # updater should be needed and the very first daemon argv must use 2.1.18.
  sed "s/'2\.1\.18'/'1.0.0'/" "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" \
    > "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy" || return 1
  chmod 0755 "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy" || return 1
  printf '%s\n' '99.0.0' > "$MODULE_DIR/run/installed-version"
  chmod 0600 "$MODULE_DIR/run/installed-version" || return 1
  printf '%s\n' upstream_only > "$MODULE_DIR/state/dns-mode.state"
  : > "$MOCK_CALL_LOG"

  output=$(run_control start 2>&1)
  status=$?
  assert_eq 0 "$status" "pre-start module binary promotion failed: $output" || return 1
  output=$(run_common_probe 'installed_version' 2>&1)
  status=$?
  assert_eq 0 "$status" "promoted runtime version probe failed: $output" || return 1
  assert_eq 2.1.18 "$output" \
    "stale installed-version bookkeeping overrode the promoted executable" || return 1
  cmp -s "$MODULE_DIR/bin/dnscrypt-proxy" "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy" \
    || fail "persistent daemon did not receive the verified module executable" || return 1
  assert_file_contains "$MOCK_CALL_LOG" \
    "daemon-check-config $DNSCRYPT_RUNTIME_ROOT/.config-check." \
    "promoted candidate was not checked through a UID3003 snapshot" || return 1
  assert_file_contains "$MOCK_CALL_LOG" \
    "daemon-start $DNSCRYPT_RUNTIME_ROOT/active/dnscrypt-proxy.toml" \
    "first persistent start did not use the protected active snapshot" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'su 3003 -c ' \
    "persistent daemon was not launched directly as UID3003" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT/bin/.dnscrypt-proxy-module-stage" \
    "successful promotion left its candidate stage" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT/bin/.dnscrypt-proxy-prestart-backup" \
    "successful startup left its rollback backup" || return 1
  run_control stop >/dev/null 2>&1 || return 1

  # A failure after the atomic promotion must restore the former executable,
  # regardless of the deliberately stale high bookkeeping marker.
  sed "s/'2\.1\.18'/'1.0.0'/" "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" \
    > "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy" || return 1
  chmod 0755 "$DNSCRYPT_RUNTIME_ROOT/bin/dnscrypt-proxy" || return 1
  printf '%s\n' '99.0.0' > "$MODULE_DIR/run/installed-version"
  MOCK_DAEMON_START_MODE='exit'
  export MOCK_DAEMON_START_MODE
  : > "$MOCK_CALL_LOG"

  output=$(run_control start 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "post-promotion daemon failure was reported successful" || return 1
  output=$(run_common_probe 'installed_version' 2>&1)
  status=$?
  assert_eq 0 "$status" "rolled-back runtime version probe failed: $output" || return 1
  assert_eq 1.0.0 "$output" \
    "failed start did not restore the previous persistent executable" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT/bin/.dnscrypt-proxy-module-stage" \
    "failed startup left its candidate stage" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT/bin/.dnscrypt-proxy-prestart-backup" \
    "successful rollback left its backup copy" || return 1
  assert_file_contains "$MODULE_DIR/logs/service.log" \
    'Rolled back the pre-start module binary promotion after startup failed.' \
    "binary rollback was not recorded" || return 1

  # Reconstruct the durable state left by SIGKILL immediately after the atomic
  # binary rename. A new control process must keep the backup armed rather than
  # discarding it merely because the promoted executable has a valid version.
  output=$(run_common_probe '
    copy_runtime_template \
      "$RUNTIME_BIN" "$RUNTIME_MODULE_BINARY_BACKUP" 0755 0:0 || exit $?
    copy_runtime_template \
      "$MODULE_BIN_DIR/dnscrypt-proxy" "$RUNTIME_MODULE_BINARY_STAGE" 0755 0:0 || exit $?
    mv -f "$RUNTIME_MODULE_BINARY_STAGE" "$RUNTIME_BIN"
  ' 2>&1)
  status=$?
  assert_eq 0 "$status" "failed to construct interrupted binary transaction: $output" || return 1
  : > "$MOCK_CALL_LOG"
  output=$(run_control start 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "interrupted promotion followed by daemon failure was reported successful" || return 1
  output=$(run_common_probe 'installed_version' 2>&1)
  status=$?
  assert_eq 0 "$status" "interrupted-transaction rollback version probe failed: $output" || return 1
  assert_eq 1.0.0 "$output" \
    "next-process recovery discarded the still-needed rollback backup" || return 1
  assert_file_contains "$MODULE_DIR/logs/service.log" \
    'Recovered an interrupted pre-start binary promotion; rollback remains armed' \
    "interrupted promotion was not resumed as a recoverable transaction" || return 1
  assert_not_exists "$DNSCRYPT_RUNTIME_ROOT/bin/.dnscrypt-proxy-prestart-backup" \
    "interrupted-transaction rollback left its backup"
}

test_config_root_open_paths_are_restricted_before_check() {
  config_file="$MODULE_DIR/config/dnscrypt-proxy.toml"
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" \
    > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  printf '%s\n' \
    "user_name = '3003'" \
    "listen_addresses = ['127.0.0.1:5354']" \
    '[query_log]' \
    "  file = '../data/query.log'" > "$config_file"
  : > "$MOCK_CALL_LOG"
  output=$(run_common_probe '
    run_bounded_config_check "$CONFIG_FILE" "$CONTROL_LOG" "$RUNTIME_BIN"
  ' 2>&1)
  status=$?
  assert_eq 0 "$status" "safe root-only canonical config was rejected: $output" || return 1
  assert_file_contains "$MOCK_CALL_LOG" \
    "daemon-check-config $MODULE_DIR/.config-check." \
    "safe config did not reach dnscrypt-proxy -check" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'su 3003 -c ' \
    "safe config check was not executed as UID3003" || return 1

  for unsafe_line in \
    "log_file = '../logs/dnscrypt-proxy.log'" \
    "log_file = '/tmp/root-target'" \
    "tls_key_log_file = '/tmp/tls-keys'" \
    '[[doh_client_x509_auth.creds]]'
  do
    printf '%s\n' \
      "user_name = '3003'" \
      "listen_addresses = ['127.0.0.1:5354']" \
      "$unsafe_line" > "$config_file"
    : > "$MOCK_CALL_LOG"
    if run_common_probe '
        run_bounded_config_check "$CONFIG_FILE" "$CONTROL_LOG" "$RUNTIME_BIN"
      ' >/dev/null 2>&1; then
      fail "unsafe pre-drop config path passed validation: $unsafe_line"
      return 1
    fi
    if grep -F 'daemon-check-config ' "$MOCK_CALL_LOG" >/dev/null 2>&1; then
      fail "unsafe pre-drop path reached dnscrypt-proxy -check: $unsafe_line"
      return 1
    fi
  done

  printf '%s\n' \
    "listen_addresses = ['127.0.0.1:5354']" > "$config_file"
  : > "$MOCK_CALL_LOG"
  if run_common_probe '
      run_bounded_config_check "$CONFIG_FILE" "$CONTROL_LOG" "$RUNTIME_BIN"
    ' >/dev/null 2>&1; then
    fail "a config without the required UID 3003 runtime user passed validation"
    return 1
  fi
  if grep -F 'daemon-check-config ' "$MOCK_CALL_LOG" >/dev/null 2>&1; then
    fail "a config without user_name reached dnscrypt-proxy -check"
    return 1
  fi
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

  printf '%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '-child' > "$proc_dir/cmdline"
  output=$(run_dnscrypt_pid_probe 2>&1)
  status=$?
  assert_eq 0 "$status" "the upstream exec -child daemon form was rejected: $output" || return 1
  assert_eq "$$" "$output" "the -child daemon PID lookup returned the wrong process" || return 1

  printf '%s\0%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '-child' '-resolve' \
    > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "a -child command with an extra argument was mistaken for the daemon"
    return 1
  fi

  printf '%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '' > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "an empty fourth argv bypassed exact parent-daemon identity"
    return 1
  fi

  printf '%s\0%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '-child' '' \
    > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "an empty fifth argv bypassed exact child-daemon identity"
    return 1
  fi

  printf '%s\0%s\0%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '-child' '' '-resolve' \
    > "$proc_dir/cmdline"
  if run_dnscrypt_pid_probe >/dev/null 2>&1; then
    fail "a child command with an empty argv and later one-shot command was accepted"
    return 1
  fi
}

test_dns_mode_state_is_exact_and_never_sourced() {
  mode_file="$MODULE_DIR/state/dns-mode.state"

  output=$(run_common_probe 'get_dns_mode' 2>&1)
  status=$?
  assert_eq 0 "$status" "an absent DNS mode did not default safely: $output" || return 1
  assert_eq strict "$output" "an absent DNS mode did not default to strict" || return 1

  for mode in strict upstream_only; do
    printf '%s\n' "$mode" > "$mode_file"
    output=$(run_common_probe 'get_dns_mode' 2>&1)
    status=$?
    assert_eq 0 "$status" "valid DNS mode $mode was rejected: $output" || return 1
    assert_eq "$mode" "$output" "valid DNS mode $mode was parsed incorrectly" || return 1
  done

  marker="$CURRENT_CASE_DIR/injection-ran"
  for invalid in 'strict extra' 'STRICT' 'strict;touch injection-ran'; do
    printf '%s\n' "$invalid" > "$mode_file"
    if run_common_probe 'get_dns_mode' >/dev/null 2>&1; then
      fail "invalid DNS mode state was accepted: $invalid"
      return 1
    fi
  done
  [ ! -e "$marker" ] || fail "DNS mode state content was executed" || return 1

  printf 'strict\r\n' > "$mode_file"
  if run_common_probe 'get_dns_mode' >/dev/null 2>&1; then
    fail "CRLF DNS mode state was accepted"
    return 1
  fi
  printf '%s\n%s\n' strict upstream_only > "$mode_file"
  if run_common_probe 'get_dns_mode' >/dev/null 2>&1; then
    fail "multi-line DNS mode state was accepted"
    return 1
  fi
  rm -f "$mode_file"
  ln -s "$MODULE_DIR/config/dnscrypt-proxy.toml" "$mode_file"
  if run_common_probe 'get_dns_mode' >/dev/null 2>&1; then
    fail "symlinked DNS mode state was accepted"
    return 1
  fi
  rm -f "$mode_file"
  mkdir "$mode_file"
  if run_common_probe 'get_dns_mode' >/dev/null 2>&1; then
    fail "directory DNS mode state was accepted"
    return 1
  fi
}

write_listener_table() {
  table=$1
  endpoint=$2
  state=$3
  inode=$4
  printf '%s\n' \
    '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode' \
    "   0: $endpoint 00000000:0000 $state 00000000:00000000 00:00000000 00000000 0 0 $inode 1" \
    > "$DNSCRYPT_PROC_ROOT/net/$table"
}

setup_ready_daemon_fixture() {
  proc_dir="$DNSCRYPT_PROC_ROOT/$$"
  mkdir -p "$proc_dir/fd" "$DNSCRYPT_PROC_ROOT/net"
  printf '%s\0%s\0%s\0%s\0' \
    "$MODULE_DIR/bin/dnscrypt-proxy" '-config' \
    "$MODULE_DIR/config/dnscrypt-proxy.toml" '-child' > "$proc_dir/cmdline"
  printf 'Uid:\t3003\t3003\t3003\t3003\n' > "$proc_dir/status"
  printf 'socket:[111]\n' > "$proc_dir/fd/3"
  printf 'socket:[222]\n' > "$proc_dir/fd/4"
  write_listener_table tcp 0100007F:14EA 0A 111
  write_listener_table udp 0100007F:14EA 07 222
  printf '%s\n' "$$" > "$MODULE_DIR/run/dnscrypt-proxy.pid"
}

test_listener_readiness_requires_owned_tcp_and_udp_loopback_sockets() {
  proc_dir="$DNSCRYPT_PROC_ROOT/$$"
  binary="$MODULE_DIR/bin/dnscrypt-proxy"
  config="$MODULE_DIR/config/dnscrypt-proxy.toml"
  mkdir -p "$proc_dir/fd" "$DNSCRYPT_PROC_ROOT/net"
  printf '%s\0%s\0%s\0%s\0' "$binary" '-config' "$config" '-child' > "$proc_dir/cmdline"
  printf 'Uid:\t3003\t3003\t3003\t3003\n' > "$proc_dir/status"
  printf 'socket:[111]\n' > "$proc_dir/fd/3"
  printf 'socket:[222]\n' > "$proc_dir/fd/4"
  write_listener_table tcp 0100007F:14EA 0A 111
  write_listener_table udp 0100007F:14EA 07 222

  run_common_probe "dnscrypt_listener_ready $$" \
    || fail "owned TCP and UDP loopback listener sockets were rejected" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "a UID-3003 daemon with both owned listener sockets was not locally ready" || return 1

  MOCK_LOCAL_HANDLER_MODE=empty_success
  export MOCK_LOCAL_HANDLER_MODE
  if run_common_probe 'is_dnscrypt_ready' >/dev/null 2>&1; then
    fail "an empty TCP close with no valid local DNS response was accepted"
    return 1
  fi

  MOCK_LOCAL_HANDLER_MODE=wrong_response
  export MOCK_LOCAL_HANDLER_MODE
  if run_common_probe 'is_dnscrypt_ready' >/dev/null 2>&1; then
    fail "a DNS response with the wrong transaction ID was accepted"
    return 1
  fi

  MOCK_LOCAL_HANDLER_MODE=wedged
  export MOCK_LOCAL_HANDLER_MODE
  run_common_probe "dnscrypt_listener_ready $$" \
    || fail "wedged-handler fixture lost its owned socket evidence" || return 1
  if run_common_probe 'is_dnscrypt_ready' >/dev/null 2>&1; then
    fail "a daemon that never processed the bounded local DNS frame was accepted"
    return 1
  fi
  output=$(run_control status 2>&1)
  assert_contains "$output" '"listener":true' \
    "status lost the independent listener signal" || return 1
  assert_contains "$output" '"local_dns":false' \
    "status did not expose the wedged local DNS handler" || return 1
  output=$(run_control service-state 2>&1)
  assert_eq local_fault "$output" \
    "wedged local DNS handler was not classified as a local fault" || return 1
  MOCK_LOCAL_HANDLER_MODE=success
  export MOCK_LOCAL_HANDLER_MODE

  # A foreign SO_REUSEPORT-style entry can appear first in /proc/net. Search
  # every matching inode rather than rejecting the owned listener after the
  # first foreign row.
  printf '%s\n' \
    '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode' \
    '   0: 0100007F:14EA 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 999 1' \
    '   1: 0100007F:14EA 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 111 1' \
    > "$DNSCRYPT_PROC_ROOT/net/tcp"
  run_common_probe "dnscrypt_listener_ready $$" \
    || fail "a preceding foreign inode hid the daemon-owned TCP listener" || return 1

  write_listener_table tcp 00000000:14EA 0A 111
  if run_common_probe "dnscrypt_listener_ready $$" >/dev/null 2>&1; then
    fail "a wildcard TCP listener was accepted as the loopback service"
    return 1
  fi
  write_listener_table tcp 0100007F:14EA 01 111
  if run_common_probe "dnscrypt_listener_ready $$" >/dev/null 2>&1; then
    fail "a non-LISTEN TCP socket was accepted"
    return 1
  fi
  write_listener_table tcp 0100007F:14EA 0A 111
  printf 'socket:[999]\n' > "$proc_dir/fd/4"
  if run_common_probe "dnscrypt_listener_ready $$" >/dev/null 2>&1; then
    fail "a UDP socket owned by another process was accepted"
    return 1
  fi
  printf 'socket:[222]\n' > "$proc_dir/fd/4"
  printf 'Uid:\t0\t0\t0\t0\n' > "$proc_dir/status"
  if run_common_probe 'is_dnscrypt_ready' >/dev/null 2>&1; then
    fail "a root daemon was accepted instead of the dedicated UID"
    return 1
  fi
}

test_dns_mode_actions_are_stopped_safe_and_live_transactional() {
  mode_file="$MODULE_DIR/state/dns-mode.state"
  MOCK_MANAGED_FIREWALL_POLICY=absent
  MOCK_FIREWALL_STATEFUL=1
  printf '%s\n' absent > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  export MOCK_MANAGED_FIREWALL_POLICY MOCK_FIREWALL_STATEFUL

  output=$(run_control set-dns-mode upstream_only 2>&1)
  status=$?
  assert_eq 0 "$status" "stopped switch to upstream_only failed: $output" || return 1
  assert_eq upstream_only "$(cat "$mode_file")" "stopped switch did not persist upstream_only" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -N ' \
    "stopped switch unexpectedly created firewall policy" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -I ' \
    "stopped switch unexpectedly attached firewall policy" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" 'settings ' \
    "stopped upstream_only switch changed Android Private DNS" || return 1

  output=$(run_control get-dns-mode 2>&1)
  assert_eq upstream_only "$output" "get-dns-mode did not report the integration mode" || return 1
  output=$(run_control leak-test 2>&1)
  assert_contains "$output" '"status":"not_applicable"' \
    "upstream_only leak-test claimed global protection" || return 1

  printf '%s\n' 'mode=opportunistic' 'specifier=null' \
    > "$MODULE_DIR/state/private-dns.state"
  printf '%s\n' present > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  printf '%s\n' fixture-boot-id > "$MODULE_DIR/state/legacy-firewall-adopt.state"
  : > "$MOCK_CALL_LOG"
  output=$(run_control apply-iptables 2>&1)
  status=$?
  assert_eq 0 "$status" "stopped upstream_only reconcile did not remove stale policy: $output" || return 1
  assert_eq absent "$(cat "$MOCK_MANAGED_FIREWALL_POLICY_FILE")" \
    "stopped upstream_only reconcile left managed firewall policy" || return 1
  [ ! -e "$MODULE_DIR/state/private-dns.state" ] \
    || fail "stopped upstream_only reconcile left Private DNS rollback state" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -I ' \
    "stopped upstream_only reconcile installed global firewall policy" || return 1

  setup_ready_daemon_fixture
  printf '%s\n' 'mode=opportunistic' 'specifier=null' \
    > "$MODULE_DIR/state/private-dns.state"
  : > "$MOCK_CALL_LOG"
  output=$(run_control set-dns-mode strict 2>&1)
  status=$?
  assert_eq 0 "$status" "live switch to strict failed: $output" || return 1
  assert_eq strict "$(cat "$mode_file")" "live strict switch did not commit last" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'settings put global private_dns_mode off' \
    "strict switch did not disable Private DNS" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j DNSCRYPT_PROXY' \
    "strict switch did not attach the managed IPv4 policy" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "live strict switch restarted or damaged the daemon" || return 1

  : > "$MOCK_CALL_LOG"
  output=$(run_control set-dns-mode upstream_only 2>&1)
  status=$?
  assert_eq 0 "$status" "live switch to upstream_only failed: $output" || return 1
  assert_eq upstream_only "$(cat "$mode_file")" "live upstream_only switch did not commit" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'settings put global private_dns_mode opportunistic' \
    "upstream_only switch did not restore Private DNS" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -I ' \
    "upstream_only switch installed a global firewall rule" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "live upstream_only switch restarted or damaged the daemon" || return 1

  MOCK_INSTALL_TARGET=$mode_file
  MOCK_MV_MODE=fail
  export MOCK_INSTALL_TARGET MOCK_MV_MODE
  output=$(run_control set-dns-mode strict 2>&1)
  status=$?
  MOCK_INSTALL_TARGET=
  MOCK_MV_MODE=success
  export MOCK_INSTALL_TARGET MOCK_MV_MODE
  [ "$status" -ne 0 ] || fail "failed mode-state commit was reported as success" || return 1
  assert_contains "$output" 'rolled back' "failed mode commit did not report rollback: $output" || return 1
  assert_eq upstream_only "$(cat "$mode_file")" \
    "failed commit changed the authoritative DNS mode" || return 1
  [ ! -e "$MODULE_DIR/state/private-dns.state" ] \
    || fail "failed strict commit left Private DNS rollback state behind" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "failed DNS mode commit restarted or damaged the daemon" || return 1

  MOCK_INSTALL_TARGET=$mode_file
  MOCK_MV_MODE=fail
  MOCK_SETTINGS_FAIL_MODE_PUT_VALUE=opportunistic
  export MOCK_INSTALL_TARGET MOCK_MV_MODE MOCK_SETTINGS_FAIL_MODE_PUT_VALUE
  output=$(run_control set-dns-mode strict 2>&1)
  status=$?
  assert_eq 3 "$status" "rollback failure did not return its distinct failure status: $output" || return 1
  assert_contains "$output" 'rollback_failed' \
    "rollback failure was hidden behind a restored-policy claim" || return 1
  assert_eq upstream_only "$(cat "$mode_file")" \
    "rollback failure changed the authoritative mode state" || return 1
  output=$(run_control service-state 2>&1)
  assert_eq policy_fault "$output" "rollback failure was not externally visible as policy_fault" || return 1

  MOCK_INSTALL_TARGET=
  MOCK_MV_MODE=success
  MOCK_SETTINGS_FAIL_MODE_PUT_VALUE=
  export MOCK_INSTALL_TARGET MOCK_MV_MODE MOCK_SETTINGS_FAIL_MODE_PUT_VALUE
  run_control set-dns-mode upstream_only >/dev/null 2>&1 || return 1

  printf '%s\n' strict > "$mode_file"
  MOCK_SETTINGS_FAIL_MODE_PUT=1
  export MOCK_SETTINGS_FAIL_MODE_PUT
  output=$(run_control start 2>&1)
  status=$?
  MOCK_SETTINGS_FAIL_MODE_PUT=0
  export MOCK_SETTINGS_FAIL_MODE_PUT
  [ "$status" -ne 0 ] || fail "failed strict policy reconciliation was reported as healthy" || return 1
  assert_contains "$output" 'locally ready' \
    "policy failure did not distinguish local daemon health" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "policy reconciliation failure killed the healthy daemon"
}

test_upstream_probe_requires_explicit_success_output() {
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  setup_ready_daemon_fixture
  printf '%s\n' upstream_only > "$MODULE_DIR/state/dns-mode.state"
  MOCK_FIREWALL_STATEFUL=1
  MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR=1
  MOCK_DAEMON_REQUIRE_SU=1
  printf '%s\n' absent > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  export MOCK_FIREWALL_STATEFUL MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR MOCK_DAEMON_REQUIRE_SU

  for probe_mode in incomplete exit_nonzero timeout; do
    MOCK_DAEMON_PROBE_MODE=$probe_mode
    export MOCK_DAEMON_PROBE_MODE
    output=$(run_control probe-upstream 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$probe_mode upstream probe was reported online: $output" || return 1
    output=$(run_control status 2>&1)
    assert_contains "$output" '"upstream":"offline"' \
      "$probe_mode upstream probe did not persist offline state" || return 1
    output=$(run_control protocol-status 2>&1)
    assert_contains "$output" '"quality":"degraded"' \
      "$probe_mode protocol diagnostic trusted only the resolve exit status" || return 1
  done

  MOCK_DAEMON_PROBE_MODE=success
  export MOCK_DAEMON_PROBE_MODE
  output=$(run_control probe-upstream 2>&1)
  status=$?
  assert_eq 0 "$status" "explicit successful upstream probe was rejected: $output" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'su 3003 -c' \
    "upstream diagnostics did not drop to UID 3003" || return 1
  assert_file_contains "$MOCK_CALL_LOG" '/.config-check.' \
    "upstream diagnostics did not use a disposable configuration snapshot" || return 1
  for leftover in "$DNSCRYPT_RUNTIME_ROOT/.config-check."*; do
    [ ! -e "$leftover" ] && [ ! -L "$leftover" ] \
      || fail "upstream diagnostics left a disposable configuration snapshot" || return 1
  done
  output=$(run_control status 2>&1)
  assert_contains "$output" '"upstream":"online"' \
    "successful upstream probe did not recover offline state to online" || return 1
  output=$(run_control protocol-status 2>&1)
  assert_contains "$output" '"quality":"good"' \
    "explicit IPv4 answer was not reflected in protocol quality"
}

test_invalid_dns_mode_blocks_policy_but_status_is_safe() {
  printf '%s\n' 'strict;touch /data/local/tmp/pwned' > "$MODULE_DIR/state/dns-mode.state"
  : > "$MOCK_CALL_LOG"
  for action in start apply-iptables health; do
    output=$(run_control "$action" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "invalid DNS mode allowed $action" || return 1
  done
  if grep -E '^(ip6?tables|settings) ' "$MOCK_CALL_LOG" >/dev/null 2>&1; then
    fail "invalid DNS mode still changed firewall or Android settings"
    return 1
  fi
  output=$(run_control status 2>&1)
  status=$?
  assert_eq 0 "$status" "status failed on invalid DNS mode: $output" || return 1
  assert_contains "$output" '"dns_mode":"invalid"' \
    "status did not expose invalid DNS mode safely"
}

test_cold_start_waits_for_local_listener_before_selected_policy() {
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  printf '%s\n' strict > "$MODULE_DIR/state/dns-mode.state"
  MOCK_MANAGED_FIREWALL_POLICY=absent
  MOCK_FIREWALL_STATEFUL=1
  printf '%s\n' absent > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  export MOCK_MANAGED_FIREWALL_POLICY MOCK_FIREWALL_STATEFUL

  output=$(run_control start 2>&1)
  status=$?
  assert_eq 0 "$status" "strict cold start failed: $output" || return 1
  assert_contains "$output" 'started in strict mode' "strict cold start did not report its policy" || return 1
  output=$(run_control health 2>&1)
  status=$?
  assert_eq 0 "$status" "strict local listener and policy were not healthy: $output" || return 1
  [ ! -e "$MODULE_DIR/run/startup.state" ] || fail "startup marker survived readiness" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'settings put global private_dns_mode off' \
    "strict policy did not disable Private DNS after readiness" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j DNSCRYPT_PROXY' \
    "strict policy did not attach redirection after readiness" || return 1

  MOCK_MANAGED_FIREWALL_POLICY=absent
  export MOCK_MANAGED_FIREWALL_POLICY
  run_control stop >/dev/null 2>&1 || return 1
  run_control set-dns-mode upstream_only >/dev/null 2>&1 || return 1
  : > "$MOCK_CALL_LOG"
  output=$(run_control start 2>&1)
  status=$?
  assert_eq 0 "$status" "upstream_only cold start failed: $output" || return 1
  assert_contains "$output" 'started in upstream_only mode' \
    "upstream_only cold start did not report its policy" || return 1
  output=$(run_control health 2>&1)
  status=$?
  assert_eq 0 "$status" "upstream_only local listener was not healthy: $output" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" 'settings ' \
    "upstream_only cold start changed Private DNS" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" ' -I ' \
    "upstream_only cold start attached global firewall policy" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "upstream_only did not keep the 127.0.0.1:5354 daemon available"
}

test_cold_start_failure_reasons_are_distinct_and_recoverable() {
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  printf '%s\n' upstream_only > "$MODULE_DIR/state/dns-mode.state"
  MOCK_FIREWALL_STATEFUL=1
  printf '%s\n' absent > "$MOCK_MANAGED_FIREWALL_POLICY_FILE"
  export MOCK_FIREWALL_STATEFUL

  for failure_spec in \
    config_error:config_error \
    missing_cache_key:config_error \
    source_cache_error:source_cache_unavailable \
    check_timeout:source_cache_unavailable \
    check_shutdown:shutdown_cancelled \
    no_listener_shutdown:shutdown_cancelled \
    exit:process_exit \
    no_listener:listener_timeout; do
    MOCK_DAEMON_START_MODE=${failure_spec%%:*}
    expected_failure=${failure_spec#*:}
    export MOCK_DAEMON_START_MODE
    : > "$MOCK_CALL_LOG"
    output=$(run_control start 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$MOCK_DAEMON_START_MODE cold start was reported successful" || return 1
    # While the injected marker exists, service-state correctly reports the
    # higher-level `shutdown` state. Remove only the fixture marker before
    # checking that the underlying startup failure was persisted distinctly.
    [ "$expected_failure" != shutdown_cancelled ] \
      || rm -f "$MODULE_DIR/state/shutdown-requested"
    output=$(run_control service-state 2>&1)
    assert_eq "start_$expected_failure" "$output" \
      "$MOCK_DAEMON_START_MODE failure was not classified distinctly" || return 1
    output=$(run_control status 2>&1)
    assert_contains "$output" "\"start_failure\":\"$expected_failure\"" \
      "$MOCK_DAEMON_START_MODE failure reason was absent from status JSON" || return 1
    [ ! -e "$MODULE_DIR/run/startup.state" ] \
      || fail "$MOCK_DAEMON_START_MODE failure left a stale startup marker" || return 1
    assert_file_not_contains "$MOCK_CALL_LOG" ' -I ' \
      "$MOCK_DAEMON_START_MODE failure installed global DNS policy" || return 1
    case "$MOCK_DAEMON_START_MODE" in
      config_error|missing_cache_key|source_cache_error|check_timeout|check_shutdown)
        assert_file_not_contains "$MOCK_CALL_LOG" 'daemon-start ' \
          "$MOCK_DAEMON_START_MODE was not stopped by source/config preflight" || return 1
        ;;
      *)
        assert_file_contains "$MOCK_CALL_LOG" 'daemon-start ' \
          "$MOCK_DAEMON_START_MODE did not exercise the post-preflight daemon path" || return 1
        ;;
    esac
    rm -f "$MODULE_DIR/state/shutdown-requested"
  done

  MOCK_DAEMON_START_MODE=success
  export MOCK_DAEMON_START_MODE
  output=$(run_control start 2>&1)
  status=$?
  assert_eq 0 "$status" "cold start did not recover after prior failures: $output" || return 1
  output=$(run_control status 2>&1)
  assert_contains "$output" '"start_failure":"none"' \
    "successful recovery did not clear the previous start failure" || return 1
  run_control stop >/dev/null 2>&1 || return 1
  output=$(run_control service-state 2>&1)
  assert_eq stopped "$output" "intentional stop retained a stale start failure"
}

test_config_check_pid_reuse_is_not_sigkilled() {
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  printf '%s\n' upstream_only > "$MODULE_DIR/state/dns-mode.state"
  MOCK_DAEMON_START_MODE=check_pid_reuse
  MOCK_KILL_MODE=replace_after_term
  DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS=1
  DNSCRYPT_CONFIG_CHECK_KILL_COMMAND="$TOOL_BIN/kill"
  export MOCK_DAEMON_START_MODE MOCK_KILL_MODE DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS
  export DNSCRYPT_CONFIG_CHECK_KILL_COMMAND
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_SLEEP" > "$TOOL_BIN/sleep"
  chmod 0755 "$TOOL_BIN/sleep"

  output=$(run_control start 2>&1)
  status=$?
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_TRUE" > "$TOOL_BIN/sleep"
  chmod 0755 "$TOOL_BIN/sleep"
  [ "$status" -ne 0 ] || fail "timed-out config check was reported successful" || return 1
  assert_contains "$output" 'source_cache_unavailable' \
    "timed-out config check was not classified" || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'kill -TERM ' \
    "owned config check did not receive TERM; calls: $(tr '\n' ' ' < "$MOCK_CALL_LOG")" || return 1
  assert_file_not_contains "$MOCK_CALL_LOG" 'kill -KILL ' \
    "replacement PID received SIGKILL after identity changed"
}

test_startup_grace_matches_upstream_netprobe_semantics() {
  config="$MODULE_DIR/config/dnscrypt-proxy.toml"
  for grace_spec in '600:630' '-1:3630' '1_200:1230' '0:30' '0x10:3630'; do
    raw=${grace_spec%%:*}
    expected_grace=${grace_spec#*:}
    sed -i "s/^[[:space:]]*netprobe_timeout[[:space:]]*=.*/netprobe_timeout = $raw/" "$config"
    output=$(run_common_probe 'dnscrypt_startup_grace_seconds' 2>&1)
    status=$?
    assert_eq 0 "$status" "startup grace parser rejected $raw: $output" || return 1
    assert_eq "$expected_grace" "$output" "startup grace did not match upstream semantics for $raw" || return 1
  done
  sed -i '/^[[:space:]]*netprobe_timeout[[:space:]]*=/d' "$config"
  output=$(run_common_probe 'dnscrypt_startup_grace_seconds' 2>&1)
  status=$?
  assert_eq 0 "$status" "startup grace parser rejected an absent netprobe_timeout: $output" || return 1
  assert_eq 90 "$output" "absent netprobe_timeout did not retain upstream's 60-second default"
}

write_quick_mode_fixture() {
  printf '%s\n' \
    "user_name = '3003'" \
    '  server_names = ['"'"'cloudflare'"'"']' \
    '  dnscrypt_servers = true' \
    '  doh_servers = true' \
    '  odoh_servers = false' \
    '  require_dnssec = true' \
    '  require_nolog = true' \
    '  require_nofilter = false' \
    'note = "literal [anonymized_dns] is not a header"' \
    ' [anonymized_dns]' \
    '   routes = [' \
    '     { server_name = '"'"'*'"'"', via = ['"'"'anon-example'"'"'] }' \
    '   ]' \
    '  [sources.'"'"'custom'"'"']' \
    '  require_nofilter = false' \
    '  urls = ['"'"'https://example.invalid/list.md'"'"']' \
    > "$MODULE_DIR/config/dnscrypt-proxy.toml"
}

test_quick_mode_rewrite_is_scoped_atomic_and_fail_closed() {
  config="$MODULE_DIR/config/dnscrypt-proxy.toml"
  write_quick_mode_fixture
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR=1
  export MOCK_DAEMON_REQUIRE_CHECK_CONFIG_DIR

  output=$(run_control quick-mode fastest 2>&1)
  status=$?
  assert_eq 0 "$status" "safe fastest TOML rewrite failed: $output" || return 1
  assert_file_contains "$MOCK_CALL_LOG" "daemon-check-config $MODULE_DIR/.config-check." \
    "quick-mode validation did not use the disposable UID3003 check snapshot" || return 1
  assert_file_contains "$config" \
    "  server_names = ['cloudflare', 'google', 'nextdns', 'cloudflare-ipv6']" \
    "leading-space root server_names was not rewritten" || return 1
  assert_file_contains "$config" '  [sources.'"'"'custom'"'"']' \
    "the indented section after anonymized_dns was consumed" || return 1
  assert_file_contains "$config" '  require_nofilter = false' \
    "a nested same-name key was rewritten" || return 1
  assert_file_contains "$config" 'note = "literal [anonymized_dns] is not a header"' \
    "a quoted header-like string was damaged" || return 1
  if grep -Eq '^[[:space:]]*\[anonymized_dns\][[:space:]]*$' "$config"; then
    fail "fastest mode retained the anonymized_dns table"
    return 1
  fi

  once=$(cat "$config")
  run_control quick-mode fastest >/dev/null 2>&1 || return 1
  twice=$(cat "$config")
  assert_eq "$once" "$twice" "repeating the same quick mode was not idempotent" || return 1

  rm -f "$MODULE_DIR/bin/dnscrypt-proxy"
  output=$(run_control quick-mode privacy 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "quick-mode skipped validation when the binary was unavailable" || return 1
  assert_contains "$output" 'dnscrypt-proxy is unavailable' \
    "missing validator binary was not reported" || return 1
  assert_eq "$once" "$(cat "$config")" \
    "missing validator binary changed the live TOML" || return 1
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"

  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_SLEEP" > "$TOOL_BIN/sleep"
  chmod 0755 "$TOOL_BIN/sleep"
  for check_spec in check_timeout:source_cache_unavailable check_shutdown:shutdown_cancelled; do
    MOCK_DAEMON_START_MODE=${check_spec%%:*}
    expected_check_failure=${check_spec#*:}
    DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS=1
    export MOCK_DAEMON_START_MODE DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS
    output=$(run_control quick-mode privacy 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$MOCK_DAEMON_START_MODE validation was reported successful" || return 1
    assert_contains "$output" "$expected_check_failure" \
      "$MOCK_DAEMON_START_MODE was not classified distinctly" || return 1
    assert_eq "$once" "$(cat "$config")" \
      "$MOCK_DAEMON_START_MODE changed the live TOML" || return 1
    rm -f "$MODULE_DIR/state/shutdown-requested"
  done
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_TRUE" > "$TOOL_BIN/sleep"
  chmod 0755 "$TOOL_BIN/sleep"
  MOCK_DAEMON_START_MODE=success
  unset DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS
  export MOCK_DAEMON_START_MODE

  output=$(run_control quick-mode privacy 2>&1)
  status=$?
  assert_eq 0 "$status" "privacy TOML rewrite failed: $output" || return 1
  assert_eq 1 "$(grep -Ec '^[[:space:]]*\[anonymized_dns\][[:space:]]*$' "$config")" \
    "privacy mode did not create one canonical anonymized_dns table" || return 1
  assert_file_contains "$config" '  [sources.'"'"'custom'"'"']' \
    "privacy rewrite damaged the following indented table" || return 1

  # A target table at EOF, including an input with no terminating newline,
  # must be removed without requiring a following header as a sentinel.
  printf '%s\n' \
    "user_name = '3003'" \
    "server_names = ['cloudflare']" \
    'dnscrypt_servers = true' \
    'doh_servers = true' \
    'odoh_servers = false' \
    'require_dnssec = true' \
    'require_nolog = true' \
    'require_nofilter = false' \
    > "$config"
  printf '%s' '[anonymized_dns]
  routes = [{ server_name = '"'"'*'"'"', via = ['"'"'anon-example'"'"'] }]' >> "$config"
  output=$(run_control quick-mode fastest 2>&1)
  status=$?
  assert_eq 0 "$status" "EOF/no-newline anonymized_dns rewrite failed: $output" || return 1
  if grep -Eq '^[[:space:]]*\[anonymized_dns\][[:space:]]*$' "$config"; then
    fail "an anonymized_dns table at EOF was retained"
    return 1
  fi
  assert_file_contains "$config" "server_names = ['cloudflare', 'google', 'nextdns', 'cloudflare-ipv6']" \
    "EOF/no-newline rewrite damaged root settings" || return 1

  # Even a compromised/non-conforming mktemp result must never make root follow
  # a stage symlink supplied from the proxy-writable directory.
  sentinel="$CURRENT_CASE_DIR/symlink-target"
  printf '%s\n' untouched > "$sentinel"
  write_quick_mode_fixture
  before=$(cat "$config")
  MOCK_MKTEMP_MODE=symlink_stage
  MOCK_MKTEMP_SYMLINK_TARGET=$sentinel
  export MOCK_MKTEMP_MODE MOCK_MKTEMP_SYMLINK_TARGET
  output=$(run_control quick-mode fastest 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a symlink returned as the stage was accepted" || return 1
  assert_eq untouched "$(cat "$sentinel")" "stage symlink target was modified" || return 1
  assert_eq "$before" "$(cat "$config")" "stage symlink attempt changed live TOML" || return 1
  MOCK_MKTEMP_MODE=normal
  export MOCK_MKTEMP_MODE

  # Replacing the already validated stage during dnscrypt-proxy -check must be
  # detected by the device/inode comparison before commit.
  write_quick_mode_fixture
  before=$(cat "$config")
  MOCK_DAEMON_REPLACE_CHECK_STAGE_TARGET=$sentinel
  export MOCK_DAEMON_REPLACE_CHECK_STAGE_TARGET
  output=$(run_control quick-mode fastest 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a replaced stage inode was accepted" || return 1
  assert_eq untouched "$(cat "$sentinel")" "replacement symlink target was modified" || return 1
  assert_eq "$before" "$(cat "$config")" "replaced stage inode changed live TOML" || return 1
  MOCK_DAEMON_REPLACE_CHECK_STAGE_TARGET=
  export MOCK_DAEMON_REPLACE_CHECK_STAGE_TARGET

  for invalid_kind in missing duplicate multiline multiline_string; do
    write_quick_mode_fixture
    case "$invalid_kind" in
      missing) sed -i '/^[[:space:]]*require_nolog[[:space:]]*=/d' "$config" ;;
      duplicate) sed -i '2i dnscrypt_servers = false' "$config" ;;
      multiline)
        sed -i '1c server_names = [' "$config"
        sed -i '2i   '"'"'cloudflare'"'"',' "$config"
        ;;
      multiline_string) sed -i '8i note = """unsupported\nmultiline"""' "$config" ;;
    esac
    before=$(cat "$config")
    output=$(run_control quick-mode family 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$invalid_kind target syntax was accepted" || return 1
    after=$(cat "$config")
    assert_eq "$before" "$after" "$invalid_kind rewrite changed the live TOML" || return 1
  done

  write_quick_mode_fixture
  before=$(cat "$config")
  MOCK_MV_MODE=fail
  MOCK_INSTALL_TARGET=$config
  export MOCK_MV_MODE MOCK_INSTALL_TARGET
  output=$(run_control quick-mode family 2>&1)
  status=$?
  MOCK_MV_MODE=success
  MOCK_INSTALL_TARGET=
  export MOCK_MV_MODE MOCK_INSTALL_TARGET
  [ "$status" -ne 0 ] || fail "failed atomic TOML install was reported as success" || return 1
  after=$(cat "$config")
  assert_eq "$before" "$after" "failed atomic TOML install changed the live file" || return 1

  # A staged config can pass -check yet fail only when the daemon restarts.
  # The control path must restore the exact old bytes and revive that config.
  sed 's/\r$//' "$MOCK_SOURCE_DIR/dnscrypt-control-daemon" > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
  printf '%s\n' upstream_only > "$MODULE_DIR/state/dns-mode.state"
  MOCK_MANAGED_FIREWALL_POLICY=absent
  export MOCK_MANAGED_FIREWALL_POLICY
  run_control start >/dev/null 2>&1 || return 1
  before=$(cat "$config")
  MOCK_DAEMON_REJECT_FAMILY_ON_START=1
  export MOCK_DAEMON_REJECT_FAMILY_ON_START
  output=$(run_control quick-mode family 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "restart failure was reported as a successful quick mode" || return 1
  assert_contains "$output" 'previous TOML was restored' \
    "restart failure did not report rollback" || return 1
  after=$(cat "$config")
  assert_eq "$before" "$after" "restart failure did not restore the original TOML bytes" || return 1
  run_common_probe 'is_dnscrypt_ready' \
    || fail "restart rollback did not revive the old configuration" || return 1
  MOCK_DAEMON_REJECT_FAMILY_ON_START=0
  export MOCK_DAEMON_REJECT_FAMILY_ON_START

  # A symlink returned for the rollback restore temp must fail closed and leave
  # its target untouched; the distinct status makes recovery requirements clear.
  run_control start >/dev/null 2>&1 || return 1
  printf '%s\n' untouched > "$sentinel"
  MOCK_DAEMON_REJECT_FAMILY_ON_START=1
  MOCK_MKTEMP_MODE=symlink_restore
  MOCK_MKTEMP_SYMLINK_TARGET=$sentinel
  export MOCK_DAEMON_REJECT_FAMILY_ON_START MOCK_MKTEMP_MODE MOCK_MKTEMP_SYMLINK_TARGET
  output=$(run_control quick-mode family 2>&1)
  status=$?
  assert_eq 3 "$status" "restore symlink failure did not return status 3: $output" || return 1
  assert_contains "$output" 'rollback_failed' \
    "restore symlink failure was reported as a successful rollback" || return 1
  assert_eq untouched "$(cat "$sentinel")" "restore symlink target was modified" || return 1
  MOCK_MKTEMP_MODE=normal
  MOCK_DAEMON_REJECT_FAMILY_ON_START=0
  export MOCK_MKTEMP_MODE MOCK_DAEMON_REJECT_FAMILY_ON_START

  # A rollback install can fail independently after the new TOML was committed.
  # The command must expose that fault instead of claiming the old file is live.
  run_control start >/dev/null 2>&1 || return 1
  MOCK_DAEMON_REJECT_FAMILY_ON_START=1
  MOCK_MV_MODE=fail_nth
  MOCK_INSTALL_TARGET=$config
  MOCK_MV_FAIL_MATCH_COUNT=2
  : > "$MOCK_MV_MATCH_COUNT_FILE"
  export MOCK_DAEMON_REJECT_FAMILY_ON_START MOCK_MV_MODE MOCK_INSTALL_TARGET
  export MOCK_MV_FAIL_MATCH_COUNT MOCK_MV_MATCH_COUNT_FILE
  output=$(run_control quick-mode family 2>&1)
  status=$?
  assert_eq 3 "$status" "quick-mode rollback failure did not return status 3: $output" || return 1
  assert_contains "$output" 'rollback_failed' \
    "quick-mode rollback failure was reported as a restored TOML" || return 1
  MOCK_MV_MODE=success
  MOCK_INSTALL_TARGET=
  MOCK_MV_FAIL_MATCH_COUNT=0
  MOCK_DAEMON_REJECT_FAMILY_ON_START=0
  export MOCK_MV_MODE MOCK_INSTALL_TARGET MOCK_MV_FAIL_MATCH_COUNT
  export MOCK_DAEMON_REJECT_FAMILY_ON_START
  run_control stop >/dev/null 2>&1
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

test_watchdog_uses_capped_backoff_and_resets() {
  watchdog_sleep_log="$CURRENT_CASE_DIR/watchdog-sleeps"
  watchdog_sleep_count="$CURRENT_CASE_DIR/watchdog-sleep-count"
  watchdog_start_count="$CURRENT_CASE_DIR/watchdog-start-count"
  watchdog_state_count="$CURRENT_CASE_DIR/watchdog-state-count"
  MOCK_WATCHDOG_SLEEP_LOG=$watchdog_sleep_log
  MOCK_WATCHDOG_SLEEP_COUNT=$watchdog_sleep_count
  MOCK_WATCHDOG_START_COUNT=$watchdog_start_count
  MOCK_WATCHDOG_STATE_COUNT=$watchdog_state_count

  cat > "$MODULE_DIR/scripts/dnscrypt-control.sh" <<'EOF'
#!/bin/sh
set -u

increment_file() {
  count=0
  [ ! -f "$1" ] || count=$(cat "$1")
  count=$((count + 1))
  printf '%s\n' "$count" > "$1"
  printf '%s\n' "$count"
}

case "${1:-}" in
  service-state)
    state_count=$(increment_file "$MOCK_WATCHDOG_STATE_COUNT")
    case "${MOCK_WATCHDOG_SCENARIO:-}" in
      health_recovery)
        [ "$state_count" -eq 2 ] && { echo degraded; exit 0; }
        ;;
    esac
    echo stopped
    exit 1
    ;;
  start)
    start_count=$(increment_file "$MOCK_WATCHDOG_START_COUNT")
    case "${MOCK_WATCHDOG_SCENARIO:-}" in
      capped_success) [ "$start_count" -ge 4 ] && exit 0 ;;
      contention) exit 2 ;;
    esac
    exit 1
    ;;
  health)
    [ "${MOCK_WATCHDOG_SCENARIO:-}" = capped_success ] \
      && [ "$(cat "$MOCK_WATCHDOG_START_COUNT" 2>/dev/null || echo 0)" -ge 4 ]
    ;;
  probe-upstream|stop|shutdown-stop) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod 0755 "$MODULE_DIR/scripts/dnscrypt-control.sh"

  cat > "$TOOL_BIN/sleep" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "${1:-}" >> "$MOCK_WATCHDOG_SLEEP_LOG"
count=0
[ ! -f "$MOCK_WATCHDOG_SLEEP_COUNT" ] || count=$(cat "$MOCK_WATCHDOG_SLEEP_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_WATCHDOG_SLEEP_COUNT"
case "${MOCK_WATCHDOG_SCENARIO:-}" in
  capped_success) [ "$count" -ge 5 ] && rm -f "$MODULE_DIR/module.prop" ;;
  health_recovery) [ "$count" -ge 3 ] && rm -f "$MODULE_DIR/module.prop" ;;
  manual_stop)
    [ "$count" -eq 2 ] && : > "$MODULE_DIR/run/user_stopped"
    [ "$count" -ge 3 ] && rm -f "$MODULE_DIR/module.prop"
    ;;
  contention) [ "$count" -ge 2 ] && rm -f "$MODULE_DIR/module.prop" ;;
esac
exit 0
EOF
  chmod 0755 "$TOOL_BIN/sleep"

  export MOCK_WATCHDOG_SLEEP_LOG MOCK_WATCHDOG_SLEEP_COUNT
  export MOCK_WATCHDOG_START_COUNT MOCK_WATCHDOG_STATE_COUNT MOCK_WATCHDOG_SCENARIO
  for watchdog_spec in \
    'capped_success:2 4 8 8 2' \
    'health_recovery:2 4 2' \
    'manual_stop:2 4 2' \
    'contention:2 2'; do
    MOCK_WATCHDOG_SCENARIO=${watchdog_spec%%:*}
    expected_sleeps=${watchdog_spec#*:}
    export MOCK_WATCHDOG_SCENARIO
    : > "$watchdog_sleep_log"
    rm -f "$watchdog_sleep_count" "$watchdog_start_count" "$watchdog_state_count" \
      "$MODULE_DIR/run/user_stopped" "$MODULE_DIR/run/watchdog.pid"
    : > "$MODULE_DIR/module.prop"
    case "$TEST_SHELL_KIND" in
      sh)
        "$HOST_ENV" PATH="$TOOL_BIN" DNSCRYPT_WATCHDOG_INTERVAL_SECONDS=2 \
          DNSCRYPT_WATCHDOG_MAX_BACKOFF_SECONDS=8 DNSCRYPT_WATCHDOG_TEST_SLEEP="$TOOL_BIN/sleep" \
          "$HOST_SH" "$MODULE_DIR/scripts/watchdog.sh"
        ;;
      dash)
        "$HOST_ENV" PATH="$TOOL_BIN" DNSCRYPT_WATCHDOG_INTERVAL_SECONDS=2 \
          DNSCRYPT_WATCHDOG_MAX_BACKOFF_SECONDS=8 DNSCRYPT_WATCHDOG_TEST_SLEEP="$TOOL_BIN/sleep" \
          "$HOST_DASH" "$MODULE_DIR/scripts/watchdog.sh"
        ;;
      busybox-ash)
        "$HOST_ENV" PATH="$TOOL_BIN" DNSCRYPT_WATCHDOG_INTERVAL_SECONDS=2 \
          DNSCRYPT_WATCHDOG_MAX_BACKOFF_SECONDS=8 DNSCRYPT_WATCHDOG_TEST_SLEEP="$TOOL_BIN/sleep" \
          "$HOST_BUSYBOX" ash "$MODULE_DIR/scripts/watchdog.sh"
        ;;
    esac
    status=$?
    assert_eq 0 "$status" "$MOCK_WATCHDOG_SCENARIO watchdog run failed" || return 1
    actual_sleeps=$(tr '\n' ' ' < "$watchdog_sleep_log" | sed 's/[[:space:]]*$//')
    assert_eq "$expected_sleeps" "$actual_sleeps" \
      "$MOCK_WATCHDOG_SCENARIO backoff/reset sequence was wrong" || return 1
  done
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
  assert_file_contains "$ROOT_DIR/customize.sh" \
    'for MIGRATION_STATE in private-dns.state dns-mode.state' \
    "upgrade does not migrate the exact root-only DNS mode state" || return 1
  assert_file_contains "$ROOT_DIR/customize.sh" \
    'OLD_CONFIG_META" = "0:0:700"' \
    "upgrade migration does not require the root-owned non-writable config boundary" || return 1
  if grep -F 'OLD_MODPATH/config/dns-mode.state' "$ROOT_DIR/customize.sh" >/dev/null 2>&1; then
    fail "DNS mode state migration trusts the proxy-writable config directory"
    return 1
  fi
  assert_file_contains "$ROOT_DIR/scripts/watchdog.sh" 'healthy|degraded)' \
    "watchdog does not preserve locally healthy service during upstream degradation" || return 1
  assert_file_contains "$ROOT_DIR/scripts/watchdog.sh" 'probe-upstream' \
    "watchdog does not record upstream reachability separately"
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
run_case 'DNS diagnostics use one bounded local and direct query' test_dns_test_uses_one_bounded_local_and_direct_query
run_case 'resolver RTTs are parsed from the real proxy logs' test_resolver_rtt_log_parsing
run_case 'IPv4 and IPv6 firewall cleanup is idempotent' test_firewall_rule_cleanup_is_idempotent
run_case 'unproven same-name firewall chains are preserved' test_foreign_same_name_firewall_chains_are_never_claimed
run_case 'lifecycle lock waits are bounded and shutdown blocks firewall commits' test_lifecycle_lock_wait_and_shutdown_interlock
run_case 'managed inputs reject unsafe modes, owners, and symlinks' test_managed_inputs_fail_closed_on_mode_owner_and_symlink
run_case 'log readers reject symlinks and unsafe unbounded paths' test_log_readers_reject_symlinks_and_unbounded_paths
run_case 'runtime tree copies exact layout and uses canonical argv' test_runtime_tree_is_copied_with_exact_layout_and_canonical_argv
run_case 'runtime tree rejects unsafe parent, symlink, and collisions' test_runtime_tree_rejects_unsafe_parent_symlink_and_collisions
run_case 'runtime tree transactions recover and honor shutdown locking' test_runtime_tree_recovers_transactions_and_honors_shutdown_lock
run_case 'runtime executable is the installed-version authority' test_runtime_version_authority_ignores_module_marker
run_case 'module binary promotion precedes persistent start and rolls back' test_module_binary_is_promoted_before_persistent_start_and_rolled_back
run_case 'pre-drop root-open paths are rejected before config check' test_config_root_open_paths_are_restricted_before_check
run_case 'PID discovery requires the exact daemon argv and config' test_dnscrypt_pid_requires_exact_daemon_argv
run_case 'DNS mode state is exact, fail-closed, and never sourced' test_dns_mode_state_is_exact_and_never_sourced
run_case 'local readiness separates owned sockets and handler response' test_listener_readiness_requires_owned_tcp_and_udp_loopback_sockets
run_case 'DNS mode actions are stopped-safe and live-transactional' test_dns_mode_actions_are_stopped_safe_and_live_transactional
run_case 'upstream probe requires explicit successful answer output' test_upstream_probe_requires_explicit_success_output
run_case 'invalid DNS mode blocks policy while status remains safe' test_invalid_dns_mode_blocks_policy_but_status_is_safe
run_case 'cold start waits for local listeners before applying selected policy' test_cold_start_waits_for_local_listener_before_selected_policy
run_case 'cold start failure reasons are distinct and recoverable' test_cold_start_failure_reasons_are_distinct_and_recoverable
run_case 'config-check PID reuse is revalidated before SIGKILL' test_config_check_pid_reuse_is_not_sigkilled
run_case 'startup grace matches upstream NetProbe timeout semantics' test_startup_grace_matches_upstream_netprobe_semantics
run_case 'quick-mode TOML rewrite is scoped, atomic, and fail-closed' test_quick_mode_rewrite_is_scoped_atomic_and_fail_closed
run_case 'Private DNS rollback state validation is fail-closed' test_private_dns_state_validation_is_fail_closed
run_case 'watchdog retry backoff is capped and reset by recovery or control' test_watchdog_uses_capped_backoff_and_resets
run_case 'WebUI assets and Android portability source invariants' test_webui_relative_assets_and_android_source_invariants

printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
