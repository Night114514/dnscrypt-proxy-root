#!/bin/sh
set -u

TEST_DIR=$(CDPATH='' cd "${0%/*}" 2>/dev/null && pwd)
ROOT_DIR=$(CDPATH='' cd "$TEST_DIR/.." 2>/dev/null && pwd)
MOCK_SOURCE_DIR="$TEST_DIR/mocks"
HOST_PATH=$PATH

find_host_tool() {
  FIND_TOOL_NAME=$1
  FIND_TOOL_OLD_IFS=$IFS
  IFS=:
  for FIND_TOOL_DIR in $HOST_PATH; do
    [ -n "$FIND_TOOL_DIR" ] || FIND_TOOL_DIR=.
    if [ -f "$FIND_TOOL_DIR/$FIND_TOOL_NAME" ] && [ -x "$FIND_TOOL_DIR/$FIND_TOOL_NAME" ]; then
      printf '%s\n' "$FIND_TOOL_DIR/$FIND_TOOL_NAME"
      IFS=$FIND_TOOL_OLD_IFS
      return 0
    fi
  done
  IFS=$FIND_TOOL_OLD_IFS
  return 1
}

HOST_SH=$(find_host_tool sh 2>/dev/null || true)
HOST_DASH=$(find_host_tool dash 2>/dev/null || true)
HOST_BUSYBOX=$(find_host_tool busybox 2>/dev/null || true)
HOST_MV=$(find_host_tool mv 2>/dev/null || true)
HOST_SLEEP=$(find_host_tool sleep 2>/dev/null || true)
HOST_ENV=$(find_host_tool env 2>/dev/null || true)
HOST_FLOCK=$(find_host_tool flock 2>/dev/null || true)
TEST_SHELL_KIND=${TEST_SHELL_KIND:-sh}

[ -n "$HOST_ENV" ] || {
  echo "env is required" >&2
  exit 2
}
[ -n "$HOST_FLOCK" ] || {
  echo "flock is required" >&2
  exit 2
}

case "$TEST_SHELL_KIND" in
  sh)
    [ -n "$HOST_SH" ] || {
      echo "sh is required" >&2
      exit 2
    }
    ;;
  dash)
    [ -n "$HOST_DASH" ] || {
      echo "dash is required for TEST_SHELL_KIND=dash" >&2
      exit 2
    }
    ;;
  busybox-ash)
    [ -n "$HOST_BUSYBOX" ] || {
      echo "busybox is required for TEST_SHELL_KIND=busybox-ash" >&2
      exit 2
    }
    ;;
  *)
    echo "Unknown TEST_SHELL_KIND: $TEST_SHELL_KIND" >&2
    exit 2
    ;;
esac

PASS_COUNT=0
FAIL_COUNT=0

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

assert_exists() {
  [ -e "$1" ] || fail "$2 (missing '$1')"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "$2 (unexpected '$1')"
}

assert_file_contains() {
  grep -F "$2" "$1" >/dev/null 2>&1 || fail "$3 (missing '$2' in '$1')"
}

run_test_shell_with_path() {
  TEST_PATH_VALUE=$1
  shift
  case "$TEST_SHELL_KIND" in
    sh) "$HOST_ENV" PATH="$TEST_PATH_VALUE" "$HOST_SH" "$@" ;;
    dash) "$HOST_ENV" PATH="$TEST_PATH_VALUE" "$HOST_DASH" "$@" ;;
    busybox-ash) "$HOST_ENV" PATH="$TEST_PATH_VALUE" MOCK_COMMAND_DIR="$TEST_PATH_VALUE" "$HOST_BUSYBOX" ash "$@" ;;
  esac
}

link_host_tool() {
  LINK_NAME=$1
  LINK_SOURCE=$(find_host_tool "$LINK_NAME" 2>/dev/null || true)
  [ -n "$LINK_SOURCE" ] || return 1
  ln -s "$LINK_SOURCE" "$TOOL_BIN/$LINK_NAME"
}

install_mock() {
  MOCK_SOURCE=$1
  MOCK_TARGET=$2
  sed 's/\r$//' "$MOCK_SOURCE_DIR/$MOCK_SOURCE" > "$TOOL_BIN/$MOCK_TARGET"
  chmod 0755 "$TOOL_BIN/$MOCK_TARGET"
}

install_busybox_mock() {
  install_mock busybox busybox-mock
  ln -s busybox-mock "$TOOL_BIN/busybox"
}

setup_fixture() {
  CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dnscrypt-update-test.XXXXXX") || return 1
  MODULE_DIR="$CASE_DIR/module"
  TOOL_BIN="$CASE_DIR/bin"
  MOCK_CALL_LOG="$CASE_DIR/calls.log"
  MOCK_DOWNLOAD_HELPER="$CASE_DIR/download-helper"
  MOCK_WAIT_READY="$CASE_DIR/download-ready"
  MOCK_WAIT_RELEASE="$CASE_DIR/download-release"
  BUSYBOX_UPDATE_SCRIPT="$MODULE_DIR/scripts/update-dnscrypt-busybox.sh"

  mkdir -p "$MODULE_DIR/scripts" "$MODULE_DIR/bin" "$MODULE_DIR/config" \
    "$MODULE_DIR/run" "$MODULE_DIR/logs" "$MODULE_DIR/tmp" "$TOOL_BIN"
  sed 's/\r$//' "$ROOT_DIR/scripts/common.sh" > "$MODULE_DIR/scripts/common.sh"
  sed 's/\r$//' "$ROOT_DIR/scripts/update-dnscrypt.sh" > "$MODULE_DIR/scripts/update-dnscrypt.sh"
  sed 's/\r$//' "$MOCK_SOURCE_DIR/busybox-ash-prelude" > "$BUSYBOX_UPDATE_SCRIPT"
  sed '1d; s/\r$//' "$ROOT_DIR/scripts/update-dnscrypt.sh" >> "$BUSYBOX_UPDATE_SCRIPT"
  sed 's/\r$//' "$ROOT_DIR/module.prop" > "$MODULE_DIR/module.prop"
  sed 's/\r$//' "$MOCK_SOURCE_DIR/download" > "$MOCK_DOWNLOAD_HELPER"
  chmod 0755 "$MOCK_DOWNLOAD_HELPER"
  : > "$MOCK_CALL_LOG"

  for FIXTURE_TOOL in awk cat chmod cp flock grep head ln mkdir mv rm rmdir sed sleep; do
    link_host_tool "$FIXTURE_TOOL" || return 1
  done

  install_mock date date
  install_mock getprop getprop
  install_mock uname uname
  install_mock download curl
  install_mock sha256sum sha256sum
  install_mock unzip unzip
  install_mock notify cmd
  install_mock notify su

  MOCK_HOST_SH=$HOST_SH
  MOCK_HOST_FLOCK=$HOST_FLOCK
  MOCK_HOST_SLEEP=$HOST_SLEEP
  MOCK_REAL_MV=$HOST_MV
  MOCK_UPSTREAM_API='https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest'
  MOCK_LATEST_VERSION='9.9.9'
  MOCK_ASSET_NAME='dnscrypt-proxy-android_arm64-9.9.9.zip'
  MOCK_METADATA_MODE=success
  MOCK_ASSET_MODE=success
  MOCK_CHECKSUM_MODE=match
  MOCK_UNZIP_MODE=success
  MOCK_MV_MODE=success
  MOCK_DATE_MODE=success
  MOCK_NOW=200000
  MOCK_ABI='arm64-v8a'
  MOCK_UNAME='aarch64'
  MOCK_ACTUAL_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  MOCK_NEW_BINARY='new dnscrypt binary'
  MOCK_INSTALL_TARGET="$MODULE_DIR/bin/dnscrypt-proxy"
  DNSCRYPT_UPDATE_INTERVAL_SECONDS=86400

  export MOCK_HOST_SH MOCK_HOST_FLOCK MOCK_HOST_SLEEP MOCK_REAL_MV MOCK_CALL_LOG MOCK_DOWNLOAD_HELPER
  export MOCK_WAIT_READY MOCK_WAIT_RELEASE
  export MOCK_UPSTREAM_API MOCK_LATEST_VERSION MOCK_ASSET_NAME
  export MOCK_METADATA_MODE MOCK_ASSET_MODE MOCK_CHECKSUM_MODE MOCK_UNZIP_MODE
  export MOCK_MV_MODE MOCK_DATE_MODE MOCK_NOW MOCK_ABI MOCK_UNAME
  export MOCK_ACTUAL_SHA MOCK_NEW_BINARY MOCK_INSTALL_TARGET
  export DNSCRYPT_UPDATE_INTERVAL_SECONDS

  trap 'rm -rf "$CASE_DIR"' 0 HUP INT TERM
}

run_update() {
  case "$TEST_SHELL_KIND" in
    sh) "$HOST_ENV" PATH="$TOOL_BIN" "$HOST_SH" "$MODULE_DIR/scripts/update-dnscrypt.sh" "$@" ;;
    dash) "$HOST_ENV" PATH="$TOOL_BIN" "$HOST_DASH" "$MODULE_DIR/scripts/update-dnscrypt.sh" "$@" ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MOCK_COMMAND_DIR="$TOOL_BIN" \
        "$HOST_BUSYBOX" ash "$BUSYBOX_UPDATE_SCRIPT" "$@"
      ;;
  esac
}

start_update_in_background() {
  BACKGROUND_OUTPUT=$1
  shift
  case "$TEST_SHELL_KIND" in
    sh) "$HOST_ENV" PATH="$TOOL_BIN" "$HOST_SH" "$MODULE_DIR/scripts/update-dnscrypt.sh" "$@" > "$BACKGROUND_OUTPUT" 2>&1 & ;;
    dash) "$HOST_ENV" PATH="$TOOL_BIN" "$HOST_DASH" "$MODULE_DIR/scripts/update-dnscrypt.sh" "$@" > "$BACKGROUND_OUTPUT" 2>&1 & ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MOCK_COMMAND_DIR="$TOOL_BIN" \
        "$HOST_BUSYBOX" ash "$BUSYBOX_UPDATE_SCRIPT" "$@" > "$BACKGROUND_OUTPUT" 2>&1 &
      ;;
  esac
  UPDATE_PID=$!
}

wait_for_file() {
  WAIT_PATH=$1
  WAIT_COUNT=0
  while [ ! -e "$WAIT_PATH" ]; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    [ "$WAIT_COUNT" -le 500 ] || return 1
    "$HOST_SLEEP" 0.02
  done
}

wait_for_lock_available() {
  WAIT_LOCK_PATH=$1
  WAIT_LOCK_COUNT=0
  while :; do
    exec 7>> "$WAIT_LOCK_PATH" || return 1
    if "$HOST_FLOCK" -n 7; then
      exec 7>&-
      return 0
    fi
    exec 7>&-
    WAIT_LOCK_COUNT=$((WAIT_LOCK_COUNT + 1))
    [ "$WAIT_LOCK_COUNT" -le 500 ] || return 1
    "$HOST_SLEEP" 0.02
  done
}

run_common() {
  # The snippet is intentionally expanded by the isolated child shell.
  # shellcheck disable=SC2016
  case "$TEST_SHELL_KIND" in
    sh|dash)
      run_test_shell_with_path "$TOOL_BIN" -c '
        MODDIR=$1
        export MODDIR
        . "$MODDIR/scripts/common.sh"
        common_function=$2
        shift 2
        "$common_function" "$@"
      ' test "$MODULE_DIR" "$@"
      ;;
    busybox-ash)
      "$HOST_ENV" PATH="$TOOL_BIN" MOCK_COMMAND_DIR="$TOOL_BIN" \
        "$HOST_BUSYBOX" ash -c '
          . "$1"
          MODDIR=$2
          export MODDIR
          . "$MODDIR/scripts/common.sh"
          common_function=$3
          shift 3
          "$common_function" "$@"
        ' test "$MOCK_SOURCE_DIR/busybox-ash-prelude" "$MODULE_DIR" "$@"
      ;;
  esac
}

make_current_install() {
  printf '%s\n' "$MOCK_LATEST_VERSION" > "$MODULE_DIR/run/installed-version"
  printf '%s\n' 'old dnscrypt binary' > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
}

make_old_install() {
  printf '%s\n' '1.0.0' > "$MODULE_DIR/run/installed-version"
  printf '%s\n' 'old dnscrypt binary' > "$MODULE_DIR/bin/dnscrypt-proxy"
  chmod 0755 "$MODULE_DIR/bin/dnscrypt-proxy"
}

api_call_count() {
  grep -F -c "$MOCK_UPSTREAM_API" "$MOCK_CALL_LOG" 2>/dev/null || true
}

test_all_abi_mappings() {
  setup_fixture || return 1

  for ABI_CASE in \
    'arm64-v8a:android_arm64' \
    'aarch64:android_arm64' \
    'arm64:android_arm64' \
    'armeabi-v7a:android_arm' \
    'armeabi:android_arm' \
    'armv7l:android_arm' \
    'armv8l:android_arm' \
    'arm:android_arm' \
    'x86:android_i386' \
    'i386:android_i386' \
    'i686:android_i386' \
    'x86_64:android_x86_64' \
    'amd64:android_x86_64' \
    'mips64:unknown'
  do
    MOCK_ABI=${ABI_CASE%%:*}
    ABI_EXPECTED=${ABI_CASE#*:}
    export MOCK_ABI
    ABI_ACTUAL=$(run_common asset_arch_name) || return 1
    assert_eq "$ABI_EXPECTED" "$ABI_ACTUAL" "ABI mapping failed for $MOCK_ABI" || return 1
  done
}

test_unknown_abi_aborts_before_network() {
  setup_fixture || return 1
  MOCK_ABI=mips64
  export MOCK_ABI

  ABI_OUTPUT=$(run_update auto 2>&1)
  ABI_STATUS=$?

  assert_eq 1 "$ABI_STATUS" 'unknown ABI should fail' || return 1
  assert_contains "$ABI_OUTPUT" 'Unsupported architecture: unknown' 'unknown ABI reason missing' || return 1
  assert_eq 0 "$(api_call_count)" 'unknown ABI should not contact GitHub' || return 1
  assert_not_exists "$MODULE_DIR/run/last-update-check" 'unknown ABI should not start a cooldown' || return 1
}

test_download_fallbacks() {
  setup_fixture || return 1
  DOWNLOAD_OUTPUT="$CASE_DIR/download.out"

  run_common download_file "$MOCK_UPSTREAM_API" "$DOWNLOAD_OUTPUT" || return 1
  DOWNLOAD_CALL=$(sed -n '1p' "$MOCK_CALL_LOG")
  assert_contains "$DOWNLOAD_CALL" 'curl ' 'curl should be the first downloader' || return 1

  : > "$MOCK_CALL_LOG"
  rm -f "$TOOL_BIN/curl"
  install_mock download wget
  run_common download_file "$MOCK_UPSTREAM_API" "$DOWNLOAD_OUTPUT" || return 1
  DOWNLOAD_CALL=$(sed -n '1p' "$MOCK_CALL_LOG")
  assert_contains "$DOWNLOAD_CALL" 'wget ' 'wget should be used when curl is absent' || return 1

  : > "$MOCK_CALL_LOG"
  rm -f "$TOOL_BIN/wget"
  install_busybox_mock
  run_common download_file "$MOCK_UPSTREAM_API" "$DOWNLOAD_OUTPUT" || return 1
  DOWNLOAD_CALL=$(sed -n '1p' "$MOCK_CALL_LOG")
  assert_contains "$DOWNLOAD_CALL" 'busybox ' 'BusyBox wget should be the final fallback' || return 1
}

test_sha256_fallbacks() {
  setup_fixture || return 1
  printf 'archive\n' > "$CASE_DIR/archive.zip"

  SHA_ACTUAL=$(run_common sha256_of "$CASE_DIR/archive.zip") || return 1
  assert_eq "$MOCK_ACTUAL_SHA" "$SHA_ACTUAL" 'sha256sum output was not used' || return 1

  rm -f "$TOOL_BIN/sha256sum"
  install_busybox_mock
  SHA_ACTUAL=$(run_common sha256_of "$CASE_DIR/archive.zip") || return 1
  assert_eq "$MOCK_ACTUAL_SHA" "$SHA_ACTUAL" 'BusyBox sha256sum fallback failed' || return 1
}

test_metadata_network_failure_is_immediately_retryable() {
  setup_fixture || return 1
  MOCK_METADATA_MODE=fail
  export MOCK_METADATA_MODE

  FIRST_OUTPUT=$(run_update auto 2>&1)
  FIRST_STATUS=$?
  SECOND_OUTPUT=$(run_update auto 2>&1)
  SECOND_STATUS=$?

  assert_eq 1 "$FIRST_STATUS" 'first failed metadata request should fail' || return 1
  assert_eq 1 "$SECOND_STATUS" 'second failed metadata request should retry and fail' || return 1
  assert_contains "$SECOND_OUTPUT" 'Failed to download GitHub release metadata.' 'second call did not retry metadata' || return 1
  assert_eq 2 "$(api_call_count)" 'metadata endpoint should be called twice' || return 1
  assert_not_exists "$MODULE_DIR/run/last-update-check" 'failed metadata must not create cooldown state' || return 1
}

test_malformed_metadata_is_immediately_retryable() {
  setup_fixture || return 1
  MOCK_METADATA_MODE=malformed
  export MOCK_METADATA_MODE

  FIRST_OUTPUT=$(run_update auto 2>&1)
  FIRST_STATUS=$?
  SECOND_OUTPUT=$(run_update auto 2>&1)
  SECOND_STATUS=$?

  assert_eq 1 "$FIRST_STATUS" 'first malformed metadata request should fail' || return 1
  assert_eq 1 "$SECOND_STATUS" 'second malformed metadata request should retry and fail' || return 1
  assert_contains "$SECOND_OUTPUT" 'Failed to parse latest dnscrypt-proxy version.' 'second call did not retry malformed metadata' || return 1
  assert_eq 2 "$(api_call_count)" 'malformed metadata should be downloaded twice' || return 1
  assert_not_exists "$MODULE_DIR/run/last-update-check" 'malformed metadata must not create cooldown state' || return 1
}

test_successful_metadata_starts_cooldown() {
  setup_fixture || return 1
  make_current_install

  FIRST_OUTPUT=$(run_update auto 2>&1)
  FIRST_STATUS=$?
  SECOND_OUTPUT=$(run_update auto 2>&1)
  SECOND_STATUS=$?

  assert_eq 0 "$FIRST_STATUS" 'successful metadata check should succeed' || return 1
  assert_contains "$FIRST_OUTPUT" 'Already up to date' 'first check did not complete normally' || return 1
  assert_eq "$MOCK_NOW" "$(cat "$MODULE_DIR/run/last-update-check")" 'successful metadata did not record its epoch' || return 1
  assert_eq 0 "$SECOND_STATUS" 'cooldown skip should succeed' || return 1
  assert_contains "$SECOND_OUTPUT" 'skip: checked recently' 'second check should be rate-limited' || return 1
  assert_eq 1 "$(api_call_count)" 'cooldown should prevent a second metadata request' || return 1
}

test_active_lock_is_preserved() {
  setup_fixture || return 1
  exec 8>> "$MODULE_DIR/run/update.lock.guard" || return 1
  "$HOST_FLOCK" -n 8 || return 1
  printf 'flock:%s\n' "$$" > "$MODULE_DIR/run/update.lock"

  LOCK_OUTPUT=$(run_update auto 2>&1)
  LOCK_STATUS=$?

  assert_eq 2 "$LOCK_STATUS" 'active lock should reject the second updater' || return 1
  assert_contains "$LOCK_OUTPUT" 'Another update process is running.' 'active-lock error message missing' || return 1
  assert_exists "$MODULE_DIR/run/update.lock" 'a process must not delete another updater lock' || return 1
  assert_eq "flock:$$" "$(cat "$MODULE_DIR/run/update.lock")" 'active lock owner changed' || return 1
  exec 8>&-
}

test_active_legacy_lock_is_preserved() {
  setup_fixture || return 1
  printf '%s\n' "$$" > "$MODULE_DIR/run/update.lock"

  LEGACY_ACTIVE_OUTPUT=$(run_update auto 2>&1)
  LEGACY_ACTIVE_STATUS=$?

  assert_eq 2 "$LEGACY_ACTIVE_STATUS" 'an active pre-flock updater should reject the new updater' || return 1
  assert_contains "$LEGACY_ACTIVE_OUTPUT" 'Another update process is running.' 'legacy active-lock error message missing' || return 1
  assert_eq "$$" "$(cat "$MODULE_DIR/run/update.lock")" 'the active legacy owner marker was overwritten' || return 1
}

test_current_marker_pid_reuse_does_not_block() {
  setup_fixture || return 1
  make_current_install
  printf 'flock:%s\n' "$$" > "$MODULE_DIR/run/update.lock"

  REUSED_OUTPUT=$(run_update auto 2>&1)
  REUSED_STATUS=$?

  assert_eq 0 "$REUSED_STATUS" 'a stale current-format marker must not become authoritative after guard release' || return 1
  assert_contains "$REUSED_OUTPUT" 'Already up to date' 'current-format marker recovery did not continue' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'current-format stale marker was not cleaned' || return 1
}

test_abandoned_legacy_reaper_gate_is_recovered() {
  setup_fixture || return 1
  make_current_install
  printf '%s\n' '99999999' > "$MODULE_DIR/run/update.lock.reap"

  REAPER_OUTPUT=$(run_update auto 2>&1)
  REAPER_STATUS=$?

  assert_eq 0 "$REAPER_STATUS" 'an abandoned legacy reaper gate should not block future updates' || return 1
  assert_contains "$REAPER_OUTPUT" 'Already up to date' 'reaper-gate recovery did not continue' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock.reap" 'abandoned legacy reaper gate was not cleaned' || return 1
}

test_stale_legacy_lock_file_is_migrated() {
  setup_fixture || return 1
  make_current_install
  printf '%s\n' '99999999' > "$MODULE_DIR/run/update.lock"

  LEGACY_OUTPUT=$(run_update auto 2>&1)
  LEGACY_STATUS=$?

  assert_eq 0 "$LEGACY_STATUS" 'a stale lock file from the previous updater should be migrated' || return 1
  assert_contains "$LEGACY_OUTPUT" 'Already up to date' 'legacy stale-lock run did not continue' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'migrated legacy lock or replacement lock was not cleaned' || return 1
}

test_empty_lock_file_is_recovered() {
  setup_fixture || return 1
  make_current_install
  : > "$MODULE_DIR/run/update.lock"

  EMPTY_LOCK_OUTPUT=$(run_update auto 2>&1)
  EMPTY_LOCK_STATUS=$?

  assert_eq 0 "$EMPTY_LOCK_STATUS" 'an empty lock left before owner publication should be recovered' || return 1
  assert_contains "$EMPTY_LOCK_OUTPUT" 'Already up to date' 'empty-lock recovery did not continue' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'empty lock or replacement lock was not cleaned' || return 1
}

test_malformed_lock_file_is_recovered() {
  setup_fixture || return 1
  make_current_install
  printf '%s\n' 'not-a-pid' > "$MODULE_DIR/run/update.lock"

  MALFORMED_LOCK_OUTPUT=$(run_update auto 2>&1)
  MALFORMED_LOCK_STATUS=$?

  assert_eq 0 "$MALFORMED_LOCK_STATUS" 'a malformed legacy lock should be recovered' || return 1
  assert_contains "$MALFORMED_LOCK_OUTPUT" 'Already up to date' 'malformed-lock recovery did not continue' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'malformed lock or replacement lock was not cleaned' || return 1
}

test_atomic_lock_preserves_first_owner() {
  setup_fixture || return 1
  make_current_install
  MOCK_METADATA_MODE=wait-success
  export MOCK_METADATA_MODE

  start_update_in_background "$CASE_DIR/first-update.out" auto
  FIRST_UPDATE_PID=$UPDATE_PID
  wait_for_file "$MOCK_WAIT_READY" || {
    kill -TERM "$FIRST_UPDATE_PID" 2>/dev/null || true
    return 1
  }

  if [ -f "$MODULE_DIR/run/update.lock" ]; then
    FIRST_LOCK_TYPE='owner-file'
    FIRST_LOCK_OWNER=$(cat "$MODULE_DIR/run/update.lock" 2>/dev/null || true)
  else
    FIRST_LOCK_TYPE='other'
    FIRST_LOCK_OWNER=
  fi

  SECOND_OUTPUT=$(run_update auto 2>&1)
  SECOND_STATUS=$?
  SECOND_LOCK_OWNER=$(cat "$MODULE_DIR/run/update.lock" 2>/dev/null || true)

  : > "$MOCK_WAIT_RELEASE"
  wait "$FIRST_UPDATE_PID"
  FIRST_STATUS=$?

  assert_eq owner-file "$FIRST_LOCK_TYPE" 'the updater did not publish its diagnostic owner marker' || return 1
  assert_eq "flock:$FIRST_UPDATE_PID" "$FIRST_LOCK_OWNER" 'the first updater did not publish its versioned owner marker' || return 1
  assert_eq 2 "$SECOND_STATUS" 'a concurrent updater should be rejected' || return 1
  assert_contains "$SECOND_OUTPUT" 'Another update process is running.' 'concurrent-updater error message missing' || return 1
  assert_eq "$FIRST_LOCK_OWNER" "$SECOND_LOCK_OWNER" 'a competing updater replaced the first owner token' || return 1
  assert_eq 0 "$FIRST_STATUS" 'the first updater should finish normally' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'the first updater did not clean its lock' || return 1
  assert_exists "$MODULE_DIR/run/update.lock.guard" 'the stable kernel-lock inode should not be unlinked' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock.reap" 'kernel locking must not leave a reaper gate' || return 1
}

test_sigkill_releases_kernel_lock() {
  setup_fixture || return 1
  make_current_install
  MOCK_METADATA_MODE=wait-success
  export MOCK_METADATA_MODE

  start_update_in_background "$CASE_DIR/killed-update.out" auto
  KILLED_PID=$UPDATE_PID
  wait_for_file "$MOCK_WAIT_READY" || {
    kill -KILL "$KILLED_PID" 2>/dev/null || true
    return 1
  }

  kill -KILL "$KILLED_PID"
  wait "$KILLED_PID" 2>/dev/null
  KILLED_STATUS=$?
  # The first download child already inherited wait-success.  Make a faulty
  # second updater finish instead of hanging, so this assertion fails clearly.
  MOCK_METADATA_MODE=success
  export MOCK_METADATA_MODE
  INHERITED_OUTPUT=$(run_update auto 2>&1)
  INHERITED_STATUS=$?
  : > "$MOCK_WAIT_RELEASE"
  wait_for_lock_available "$MODULE_DIR/run/update.lock.guard" || return 1

  RECOVERY_OUTPUT=$(run_update auto 2>&1)
  RECOVERY_STATUS=$?

  assert_eq 137 "$KILLED_STATUS" 'SIGKILL should terminate the first updater' || return 1
  assert_eq 2 "$INHERITED_STATUS" 'an inherited lock descriptor must stay authoritative until the child exits' || return 1
  assert_contains "$INHERITED_OUTPUT" 'Another update process is running.' 'the inherited descriptor did not reject a concurrent updater' || return 1
  assert_eq 0 "$RECOVERY_STATUS" 'the kernel lock should be reusable after SIGKILL' || return 1
  assert_contains "$RECOVERY_OUTPUT" 'Already up to date' 'the post-SIGKILL retry did not continue' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'the retry did not clean the stale diagnostic marker' || return 1
}

test_busybox_flock_fallback_dispatch() {
  setup_fixture || return 1
  make_current_install
  rm -f "$TOOL_BIN/flock"
  install_busybox_mock

  FALLBACK_OUTPUT=$(run_update auto 2>&1)
  FALLBACK_STATUS=$?

  assert_eq 0 "$FALLBACK_STATUS" 'BusyBox flock fallback should allow an update check' || return 1
  assert_contains "$FALLBACK_OUTPUT" 'Already up to date' 'BusyBox flock fallback did not continue' || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'busybox flock -n 9' 'BusyBox flock fallback was not invoked' || return 1
}

test_busybox_flock_busy_maps_to_concurrent_status() {
  setup_fixture || return 1
  exec 8>> "$MODULE_DIR/run/update.lock.guard" || return 1
  "$HOST_FLOCK" -n 8 || return 1
  printf 'flock:%s\n' "$$" > "$MODULE_DIR/run/update.lock"
  rm -f "$TOOL_BIN/flock"
  install_busybox_mock

  BUSY_OUTPUT=$(run_update auto 2>&1)
  BUSY_STATUS=$?

  assert_eq 2 "$BUSY_STATUS" 'BusyBox flock contention should map to concurrent-update status' || return 1
  assert_contains "$BUSY_OUTPUT" 'Another update process is running.' 'BusyBox contention reason missing' || return 1
  assert_file_contains "$MOCK_CALL_LOG" 'busybox flock -n 9' 'BusyBox contention path was not invoked' || return 1
  assert_eq "flock:$$" "$(cat "$MODULE_DIR/run/update.lock")" 'BusyBox contention overwrote the active marker' || return 1
  exec 8>&-
}

test_missing_flock_fails_closed() {
  setup_fixture || return 1
  rm -f "$TOOL_BIN/flock"

  MISSING_FLOCK_OUTPUT=$(run_update auto 2>&1)
  MISSING_FLOCK_STATUS=$?

  assert_eq 1 "$MISSING_FLOCK_STATUS" 'missing flock implementations should fail closed' || return 1
  assert_contains "$MISSING_FLOCK_OUTPUT" 'Failed to acquire update lock.' 'missing-flock reason was not reported' || return 1
  assert_eq 0 "$(api_call_count)" 'an updater without a lock primitive must not contact GitHub' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'an updater without flock left an owner marker' || return 1
}

test_term_signal_stops_update_and_cleans_lock() {
  setup_fixture || return 1
  make_old_install
  MOCK_METADATA_MODE=wait-success
  export MOCK_METADATA_MODE

  start_update_in_background "$CASE_DIR/signaled-update.out" force
  SIGNALED_PID=$UPDATE_PID
  wait_for_file "$MOCK_WAIT_READY" || {
    kill -TERM "$SIGNALED_PID" 2>/dev/null || true
    return 1
  }

  kill -TERM "$SIGNALED_PID"
  : > "$MOCK_WAIT_RELEASE"
  wait "$SIGNALED_PID"
  SIGNAL_STATUS=$?

  assert_eq 143 "$SIGNAL_STATUS" 'TERM should stop the updater with signal-derived status' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'a signaled updater should clean its owned lock' || return 1
  assert_not_exists "$MODULE_DIR/run/last-update-check" 'a signaled metadata request must not start cooldown' || return 1
  assert_eq 'old dnscrypt binary' "$(cat "$MODULE_DIR/bin/dnscrypt-proxy")" 'a signaled updater continued into installation' || return 1
}

test_owned_lock_is_cleaned_on_failure() {
  setup_fixture || return 1
  MOCK_METADATA_MODE=fail
  export MOCK_METADATA_MODE

  FAILURE_OUTPUT=$(run_update auto 2>&1)
  FAILURE_STATUS=$?

  assert_eq 1 "$FAILURE_STATUS" 'metadata failure should be reported' || return 1
  assert_contains "$FAILURE_OUTPUT" 'Failed to download GitHub release metadata.' 'metadata failure message missing' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'owned lock should be cleaned on failure' || return 1
}

test_checksum_match_installs() {
  setup_fixture || return 1

  MATCH_OUTPUT=$(run_update force 2>&1)
  MATCH_STATUS=$?

  assert_eq 0 "$MATCH_STATUS" 'matching checksum should allow installation' || return 1
  assert_contains "$MATCH_OUTPUT" 'Installed dnscrypt-proxy' 'successful install message missing' || return 1
  assert_file_contains "$MODULE_DIR/logs/update.log" 'SHA256 matched for' 'hash match should be described as a match' || return 1
  assert_eq "$MOCK_NEW_BINARY" "$(cat "$MODULE_DIR/bin/dnscrypt-proxy")" 'new binary was not installed' || return 1
}

test_checksum_mismatch_aborts() {
  setup_fixture || return 1
  make_old_install
  MOCK_CHECKSUM_MODE=mismatch
  export MOCK_CHECKSUM_MODE

  MISMATCH_OUTPUT=$(run_update force 2>&1)
  MISMATCH_STATUS=$?

  assert_eq 1 "$MISMATCH_STATUS" 'checksum mismatch must abort installation' || return 1
  assert_contains "$MISMATCH_OUTPUT" 'SHA256 mismatch' 'checksum mismatch reason missing' || return 1
  assert_eq 'old dnscrypt binary' "$(cat "$MODULE_DIR/bin/dnscrypt-proxy")" 'mismatch replaced the installed binary' || return 1
  assert_file_contains "$MODULE_DIR/run/update-status.env" 'state=error' 'mismatch status was not recorded as error' || return 1
}

test_missing_checksum_entry_is_documented_fail_open() {
  setup_fixture || return 1
  MOCK_CHECKSUM_MODE=missing-entry
  export MOCK_CHECKSUM_MODE

  MISSING_OUTPUT=$(run_update force 2>&1)
  MISSING_STATUS=$?

  assert_eq 0 "$MISSING_STATUS" 'missing checksum entry should preserve current fail-open behavior' || return 1
  assert_contains "$MISSING_OUTPUT" 'Installed dnscrypt-proxy' 'missing checksum entry did not continue' || return 1
  assert_file_contains "$MODULE_DIR/logs/update.log" 'continuing without checksum comparison' 'fail-open checksum log is unclear' || return 1
}

test_checksum_download_failure_is_documented_fail_open() {
  setup_fixture || return 1
  MOCK_CHECKSUM_MODE=fail
  export MOCK_CHECKSUM_MODE

  FAILURE_OUTPUT=$(run_update force 2>&1)
  FAILURE_STATUS=$?

  assert_eq 0 "$FAILURE_STATUS" 'checksum download failure should preserve current fail-open behavior' || return 1
  assert_contains "$FAILURE_OUTPUT" 'Installed dnscrypt-proxy' 'checksum download failure did not continue' || return 1
  assert_file_contains "$MODULE_DIR/logs/update.log" 'continuing without checksum comparison' 'checksum download fail-open log is unclear' || return 1
}

test_zip_without_binary_aborts() {
  setup_fixture || return 1
  MOCK_UNZIP_MODE=missing
  export MOCK_UNZIP_MODE

  MISSING_OUTPUT=$(run_update force 2>&1)
  MISSING_STATUS=$?

  assert_eq 1 "$MISSING_STATUS" 'archive without a binary must fail' || return 1
  assert_contains "$MISSING_OUTPUT" 'did not contain dnscrypt-proxy binary' 'missing binary reason not reported' || return 1
  assert_not_exists "$MODULE_DIR/bin/dnscrypt-proxy" 'missing archive binary created an installed binary' || return 1
}

test_empty_binary_aborts() {
  setup_fixture || return 1
  MOCK_UNZIP_MODE=empty
  export MOCK_UNZIP_MODE

  EMPTY_OUTPUT=$(run_update force 2>&1)
  EMPTY_STATUS=$?

  assert_eq 1 "$EMPTY_STATUS" 'empty extracted binary must fail' || return 1
  assert_contains "$EMPTY_OUTPUT" 'binary is empty' 'empty binary reason not reported' || return 1
  assert_not_exists "$MODULE_DIR/bin/dnscrypt-proxy" 'empty binary was installed' || return 1
}

test_atomic_install_keeps_backup_and_cleans_temporary_files() {
  setup_fixture || return 1
  make_old_install

  INSTALL_OUTPUT=$(run_update force 2>&1)
  INSTALL_STATUS=$?

  assert_eq 0 "$INSTALL_STATUS" 'valid update should install successfully' || return 1
  assert_contains "$INSTALL_OUTPUT" 'Installed dnscrypt-proxy' 'install success message missing' || return 1
  assert_eq "$MOCK_NEW_BINARY" "$(cat "$MODULE_DIR/bin/dnscrypt-proxy")" 'installed binary content is wrong' || return 1
  assert_eq 'old dnscrypt binary' "$(cat "$MODULE_DIR/bin/dnscrypt-proxy.bak")" 'previous binary backup is wrong' || return 1
  assert_not_exists "$MODULE_DIR/bin/dnscrypt-proxy.tmp" 'temporary binary was not atomically moved' || return 1
  assert_eq "$MOCK_LATEST_VERSION" "$(cat "$MODULE_DIR/run/installed-version")" 'installed version was not updated' || return 1
  assert_not_exists "$MODULE_DIR/run/update.lock" 'lock remained after a successful install' || return 1
  TEMP_REMAINS=$(find "$MODULE_DIR/tmp" -mindepth 1 -print)
  assert_eq '' "$TEMP_REMAINS" 'update work directory was not cleaned' || return 1
}

test_atomic_move_failure_is_not_reported_as_success() {
  setup_fixture || return 1
  make_old_install
  rm -f "$TOOL_BIN/mv"
  install_mock mv mv
  MOCK_MV_MODE=fail
  export MOCK_MV_MODE

  MOVE_OUTPUT=$(run_update force 2>&1)
  MOVE_STATUS=$?

  assert_eq 1 "$MOVE_STATUS" 'failed atomic move must fail the update' || return 1
  assert_contains "$MOVE_OUTPUT" 'Failed to install new dnscrypt-proxy binary.' 'atomic move failure reason missing' || return 1
  assert_eq 'old dnscrypt binary' "$(cat "$MODULE_DIR/bin/dnscrypt-proxy")" 'failed move damaged the installed binary' || return 1
  assert_eq '1.0.0' "$(cat "$MODULE_DIR/run/installed-version")" 'failed move incorrectly advanced installed version' || return 1
  assert_file_contains "$MODULE_DIR/run/update-status.env" 'state=error' 'failed move was not recorded as error' || return 1
}

run_case() {
  CASE_NAME=$1
  CASE_FUNCTION=$2
  printf '  %s ... ' "$CASE_NAME"
  if ("$CASE_FUNCTION"); then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo 'ok'
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo 'FAIL'
  fi
}

echo "Running updater tests with $TEST_SHELL_KIND"

run_case 'all ABI mappings' test_all_abi_mappings
run_case 'unknown ABI aborts before network' test_unknown_abi_aborts_before_network
run_case 'curl/wget/BusyBox download fallbacks' test_download_fallbacks
run_case 'sha256sum/BusyBox hash fallbacks' test_sha256_fallbacks
run_case 'metadata network failure is retryable' test_metadata_network_failure_is_immediately_retryable
run_case 'malformed metadata is retryable' test_malformed_metadata_is_immediately_retryable
run_case 'successful metadata starts cooldown' test_successful_metadata_starts_cooldown
run_case 'active lock is preserved' test_active_lock_is_preserved
run_case 'active legacy lock is preserved' test_active_legacy_lock_is_preserved
run_case 'current marker PID reuse does not block' test_current_marker_pid_reuse_does_not_block
run_case 'abandoned legacy reaper gate is recovered' test_abandoned_legacy_reaper_gate_is_recovered
run_case 'stale legacy lock file is migrated' test_stale_legacy_lock_file_is_migrated
run_case 'empty lock file is recovered' test_empty_lock_file_is_recovered
run_case 'malformed lock file is recovered' test_malformed_lock_file_is_recovered
run_case 'atomic lock preserves the first owner' test_atomic_lock_preserves_first_owner
run_case 'SIGKILL releases the kernel lock' test_sigkill_releases_kernel_lock
run_case 'BusyBox flock fallback dispatch' test_busybox_flock_fallback_dispatch
run_case 'BusyBox flock busy status mapping' test_busybox_flock_busy_maps_to_concurrent_status
run_case 'missing flock fails closed' test_missing_flock_fails_closed
run_case 'TERM stops update and cleans lock' test_term_signal_stops_update_and_cleans_lock
run_case 'owned lock is cleaned on failure' test_owned_lock_is_cleaned_on_failure
run_case 'matching checksum installs' test_checksum_match_installs
run_case 'checksum mismatch aborts' test_checksum_mismatch_aborts
run_case 'missing checksum entry fails open explicitly' test_missing_checksum_entry_is_documented_fail_open
run_case 'checksum download failure fails open explicitly' test_checksum_download_failure_is_documented_fail_open
run_case 'ZIP without binary aborts' test_zip_without_binary_aborts
run_case 'empty binary aborts' test_empty_binary_aborts
run_case 'successful install is atomic' test_atomic_install_keeps_backup_and_cleans_temporary_files
run_case 'failed atomic move is an error' test_atomic_move_failure_is_not_reported_as_success

printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
