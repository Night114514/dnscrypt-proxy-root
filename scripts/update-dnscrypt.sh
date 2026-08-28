#!/system/bin/sh
set -u

SCRIPT_DIR=${0%/*}
MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
# The runtime module path is dynamic by design; common.sh is linted separately.
# shellcheck disable=SC1091
. "$MODDIR/scripts/common.sh"

MODE="${1:-auto}"
case "$MODE" in
  auto|check|force|install) ;;
  *)
    echo "Unknown update mode: $MODE"
    echo "Usage: $0 {auto|check|force|install}"
    exit 64
    ;;
esac
CHECK_INTERVAL_SECONDS="${DNSCRYPT_UPDATE_INTERVAL_SECONDS:-86400}"
case "$CHECK_INTERVAL_SECONDS" in
  ""|*[!0-9]*) CHECK_INTERVAL_SECONDS=86400 ;;
esac
[ "${#CHECK_INTERVAL_SECONDS}" -le 10 ] || CHECK_INTERVAL_SECONDS=86400
LAST_CHECK_FILE="$RUN_DIR/last-update-check"
LOCK_FILE="$RUN_DIR/update.lock"
LOCK_GUARD_FILE="$RUN_DIR/update.lock.guard"
LEGACY_REAP_FILE="$RUN_DIR/update.lock.reap"
LOCK_OWNER="flock:$$"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$TMP_BASE"

LOCK_OWNED=0
LOCK_FD_OPEN=0
CONTROL_LOCK_FD_OPEN=0

# Called indirectly by the signal and exit traps below.
# shellcheck disable=SC2317
finish() {
  if [ "$LOCK_OWNED" -eq 1 ]; then
    lock_owner=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ "$lock_owner" = "$LOCK_OWNER" ]; then
      rm -f "$LOCK_FILE"
    fi
    LOCK_OWNED=0
  fi
  if [ "$LOCK_FD_OPEN" -eq 1 ]; then
    exec 9>&-
    LOCK_FD_OPEN=0
  fi
  if [ "$CONTROL_LOCK_FD_OPEN" -eq 1 ]; then
    exec 8>&-
    CONTROL_LOCK_FD_OPEN=0
  fi
}
trap finish 0
trap 'finish; exit 129' HUP
trap 'finish; exit 130' INT
trap 'finish; exit 143' TERM

lock_fd_nonblocking() {
  if has_cmd flock; then
    flock -n "$1"
    return $?
  fi
  busybox_cmd flock -n "$1"
}

acquire_update_lock() {
  # Android 7+ Toybox provides flock.  The root-manager BusyBox is a fallback.
  # The stable inode must never be unlinked: the kernel releases its advisory
  # lock automatically when this shell and all inherited descriptors exit.
  if ! exec 9>> "$LOCK_GUARD_FILE"; then
    return 1
  fi
  LOCK_FD_OPEN=1

  lock_fd_nonblocking 9
  flock_status=$?
  case "$flock_status" in
    0) ;;
    1)
      exec 9>&-
      LOCK_FD_OPEN=0
      return 2
      ;;
    *)
      exec 9>&-
      LOCK_FD_OPEN=0
      return 1
      ;;
  esac

  # A running pre-flock updater only owns the PID marker.  Respect it during a
  # live script upgrade so old and new installers cannot replace the binary at
  # the same time.  Dead, empty, and malformed markers are migration residue.
  legacy_owner=$(cat "$LOCK_FILE" 2>/dev/null || true)
  case "$legacy_owner" in
    ''|0*|*[!0-9]*) ;;
    *)
      if [ "$legacy_owner" != "$$" ] && kill -0 "$legacy_owner" >/dev/null 2>&1; then
        exec 9>&-
        LOCK_FD_OPEN=0
        return 2
      fi
      ;;
  esac

  # Remove an abandoned gate from the short-lived hard-link implementation only
  # after the kernel lock is held.  A stale diagnostic marker is overwritten.
  rm -f "$LEGACY_REAP_FILE"

  if ! printf '%s\n' "$LOCK_OWNER" > "$LOCK_FILE"; then
    exec 9>&-
    LOCK_FD_OPEN=0
    return 1
  fi
  LOCK_OWNED=1
  return 0
}

acquire_update_lock
lock_status=$?
case "$lock_status" in
  0) ;;
  2)
    echo "Another update process is running."
    exit 2
    ;;
  *)
    echo "Failed to acquire update lock."
    exit 1
    ;;
esac

should_skip_auto_check() {
  [ "$MODE" = "auto" ] || return 1
  [ -f "$LAST_CHECK_FILE" ] || return 1
  now=$(date +%s 2>/dev/null || echo 0)
  last=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)
  case "$now" in
    ""|*[!0-9]*) return 1 ;;
  esac
  case "$last" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [ "${#now}" -le 12 ] || return 1
  [ "${#last}" -le 12 ] || return 1
  [ "$now" -gt 0 ] || return 1
  age=$((now - last))
  [ "$age" -ge 0 ] && [ "$age" -lt "$CHECK_INTERVAL_SECONDS" ]
}

if should_skip_auto_check; then
  log_msg "$UPDATE_LOG" "Skip automatic update check; interval has not elapsed."
  echo "skip: checked recently"
  exit 0
fi

ARCH_ASSET=$(asset_arch_name)
if [ "$ARCH_ASSET" = "unknown" ]; then
  msg="Unsupported architecture: $(get_device_arch)"
  write_update_status "error" "unknown" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  echo "$msg"
  exit 1
fi

WORK="$TMP_BASE/update-$$"
API_JSON="$WORK/latest.json"
ZIP_FILE="$WORK/dnscrypt-proxy.zip"
EXTRACT_DIR="$WORK/extract"
mkdir -p "$WORK" "$EXTRACT_DIR"

log_msg "$UPDATE_LOG" "Checking upstream release for $ARCH_ASSET."
if ! download_file "$UPSTREAM_API" "$API_JSON"; then
  msg="Failed to download GitHub release metadata."
  write_update_status "error" "unknown" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

LATEST_VERSION=$(extract_tag_name "$API_JSON")
if [ -z "$LATEST_VERSION" ]; then
  msg="Failed to parse latest dnscrypt-proxy version."
  write_update_status "error" "unknown" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
if ! printf '%s\n' "$LATEST_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  msg="GitHub returned an unsafe or unsupported release tag: $LATEST_VERSION"
  write_update_status "error" "unknown" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

CURRENT_VERSION=$(installed_version)
ASSET_NAME="dnscrypt-proxy-${ARCH_ASSET}-${LATEST_VERSION}.zip"
ASSET_URL=$(make_asset_url "$LATEST_VERSION" "$ARCH_ASSET")

if [ "$MODE" = "check" ]; then
  write_update_status "checked" "$LATEST_VERSION" "Latest upstream version is $LATEST_VERSION; installed version is $CURRENT_VERSION."
  echo "latest=$LATEST_VERSION"
  echo "installed=$CURRENT_VERSION"
  echo "asset=$ASSET_URL"
  date +%s > "$LAST_CHECK_FILE" 2>/dev/null || true
  rm -rf "$WORK"
  exit 0
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ] && [ -x "$DNSCRYPT_BIN" ] && [ "$MODE" != "force" ] && [ "$MODE" != "install" ]; then
  msg="Already up to date: $LATEST_VERSION"
  write_update_status "up_to_date" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  echo "$msg"
  date +%s > "$LAST_CHECK_FILE" 2>/dev/null || true
  rm -rf "$WORK"
  exit 0
fi

EXPECTED_SHA=$(extract_asset_sha256 "$API_JSON" "$ASSET_NAME" 2>/dev/null || true)
if [ "${#EXPECTED_SHA}" -ne 64 ]; then
  msg="GitHub metadata did not provide a SHA256 digest for $ASSET_NAME; refusing to install."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
case "$EXPECTED_SHA" in
  *[!0-9a-f]*)
    msg="GitHub metadata returned a malformed SHA256 digest for $ASSET_NAME; refusing to install."
    write_update_status "error" "$LATEST_VERSION" "$msg"
    log_msg "$UPDATE_LOG" "$msg"
    rm -rf "$WORK"
    echo "$msg"
    exit 1
    ;;
esac

log_msg "$UPDATE_LOG" "Downloading $ASSET_URL"
if ! download_file "$ASSET_URL" "$ZIP_FILE"; then
  msg="Failed to download dnscrypt-proxy asset: $ASSET_URL"
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

# GitHub computes this digest from the stored release asset and returns it in
# the separately downloaded release metadata. Verification is mandatory: a
# missing hash implementation, malformed digest, or mismatch fails closed.
ACTUAL_SHA=$(sha256_of "$ZIP_FILE" 2>/dev/null || true)
if [ "${#ACTUAL_SHA}" -ne 64 ]; then
  msg="No working SHA256 implementation is available; refusing to install $ASSET_NAME."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
case "$ACTUAL_SHA" in
  *[!0-9a-f]*)
    msg="The computed SHA256 digest is malformed; refusing to install $ASSET_NAME."
    write_update_status "error" "$LATEST_VERSION" "$msg"
    log_msg "$UPDATE_LOG" "$msg"
    rm -rf "$WORK"
    echo "$msg"
    exit 1
    ;;
esac
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  msg="SHA256 mismatch for $ASSET_NAME; expected $EXPECTED_SHA got $ACTUAL_SHA."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
log_msg "$UPDATE_LOG" "GitHub release-asset SHA256 matched for $ASSET_NAME."

if ! unzip_file "$ZIP_FILE" "$EXTRACT_DIR"; then
  msg="Failed to unzip dnscrypt-proxy release asset."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

case "$ARCH_ASSET" in
  android_arm) INNER_DIR="android-arm" ;;
  android_arm64) INNER_DIR="android-arm64" ;;
  android_i386) INNER_DIR="android-i386" ;;
  android_x86_64) INNER_DIR="android-x86_64" ;;
  *) INNER_DIR="" ;;
esac
NEW_BIN="$EXTRACT_DIR/$INNER_DIR/dnscrypt-proxy"

if [ -z "$INNER_DIR" ] || [ ! -f "$NEW_BIN" ]; then
  msg="Release asset did not contain dnscrypt-proxy binary."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

if [ ! -s "$NEW_BIN" ]; then
  msg="Downloaded dnscrypt-proxy binary is empty."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
if ! chmod 0755 "$NEW_BIN" 2>/dev/null; then
  msg="Failed to make the downloaded dnscrypt-proxy binary executable."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

NEW_VERSION=$("$NEW_BIN" -version 2>/dev/null | sed -n '1{s/\r$//;p;q;}')
if [ "$NEW_VERSION" != "$LATEST_VERSION" ]; then
  msg="Downloaded binary version '$NEW_VERSION' does not match release $LATEST_VERSION."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
if [ -f "$CONFIG_FILE" ]; then
  if ! (cd "$CONFIG_DIR" && "$NEW_BIN" -check -config "$CONFIG_FILE") >> "$UPDATE_LOG" 2>&1; then
    msg="Downloaded dnscrypt-proxy rejected the active configuration; the installed binary was kept."
    write_update_status "error" "$LATEST_VERSION" "$msg"
    log_msg "$UPDATE_LOG" "$msg"
    rm -rf "$WORK"
    echo "$msg"
    exit 1
  fi
fi

# Downloads and executable/config validation happen without blocking normal
# controls. Serialize only the short commit/restart phase with fd 8, then sample
# the current service state under that lock. This prevents a concurrent user
# stop from being undone and prevents a concurrent start from keeping an old
# in-memory executable after the on-disk binary changes.
DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS=10
export DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS
_control_lock_ready=0
if [ "${DNSCRYPT_CONTROL_LOCK_HELD:-0}" = "1" ]; then
  inherited_control_lock_valid
  _control_lock_status=$?
  if [ "$_control_lock_status" -eq 0 ]; then
    # The child owns only an inherited copy. Its ordinary process exit closes
    # that copy while the parent control action remains the lock owner.
    _control_lock_ready=1
  else
    msg="The inherited dnscrypt-proxy control lock is invalid; the validated update was not installed."
  fi
else
  acquire_control_lock
  _control_lock_status=$?
  case "$_control_lock_status" in
    0) CONTROL_LOCK_FD_OPEN=1; _control_lock_ready=1 ;;
    2) msg="Another dnscrypt-proxy control operation remained active; the validated update was not installed." ;;
    *) msg="Failed to acquire the dnscrypt-proxy control lock; the validated update was not installed." ;;
  esac
fi
if [ "$_control_lock_ready" -ne 1 ]; then
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit "$_control_lock_status"
fi
if shutdown_requested; then
  msg="Module shutdown is pending; the validated update was not installed."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

mkdir -p "$BIN_DIR"
WAS_RUNNING=0
is_dnscrypt_running && WAS_RUNNING=1
HAD_OLD_BINARY=0
OLD_BINARY="$WORK/old-dnscrypt-proxy"
if [ -f "$DNSCRYPT_BIN" ]; then
  HAD_OLD_BINARY=1
  if ! cp -af "$DNSCRYPT_BIN" "$OLD_BINARY" 2>/dev/null; then
    msg="Failed to create a rollback copy of the installed dnscrypt-proxy binary."
    write_update_status "error" "$LATEST_VERSION" "$msg"
    log_msg "$UPDATE_LOG" "$msg"
    rm -rf "$WORK"
    echo "$msg"
    exit 1
  fi
fi
HAD_OLD_VERSION_FILE=0
OLD_VERSION_FILE="$WORK/old-installed-version"
if [ -f "$INSTALLED_VERSION_FILE" ]; then
  HAD_OLD_VERSION_FILE=1
  if ! cp -af "$INSTALLED_VERSION_FILE" "$OLD_VERSION_FILE" 2>/dev/null; then
    msg="Failed to preserve the installed-version marker for rollback."
    write_update_status "error" "$LATEST_VERSION" "$msg"
    log_msg "$UPDATE_LOG" "$msg"
    rm -rf "$WORK"
    echo "$msg"
    exit 1
  fi
fi
cp -af "$NEW_BIN" "$DNSCRYPT_BIN.tmp" || {
  msg="Failed to copy new dnscrypt-proxy binary."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -f "$DNSCRYPT_BIN.tmp"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
}
if ! chmod 0755 "$DNSCRYPT_BIN.tmp" 2>/dev/null; then
  msg="Failed to set executable permissions on the staged dnscrypt-proxy binary."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -f "$DNSCRYPT_BIN.tmp"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
if ! mv -f "$DNSCRYPT_BIN.tmp" "$DNSCRYPT_BIN"; then
  msg="Failed to install new dnscrypt-proxy binary."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -f "$DNSCRYPT_BIN.tmp"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

rollback_binary() {
  rm -f "$DNSCRYPT_BIN.tmp"
  if [ "$HAD_OLD_BINARY" -eq 1 ]; then
    cp -af "$OLD_BINARY" "$DNSCRYPT_BIN.tmp" 2>/dev/null \
      && chmod 0755 "$DNSCRYPT_BIN.tmp" 2>/dev/null \
      && mv -f "$DNSCRYPT_BIN.tmp" "$DNSCRYPT_BIN"
    return $?
  fi
  rm -f "$DNSCRYPT_BIN"
}

restore_old_version_marker() {
  _restore_version_tmp="$INSTALLED_VERSION_FILE.$$.rollback"
  rm -f "$_restore_version_tmp"
  if [ "$HAD_OLD_VERSION_FILE" -eq 1 ]; then
    if cp -af "$OLD_VERSION_FILE" "$_restore_version_tmp" 2>/dev/null \
      && mv -f "$_restore_version_tmp" "$INSTALLED_VERSION_FILE"; then
      return 0
    fi
    rm -f "$_restore_version_tmp"
    # With the old binary restored, removing a stale new marker is safer than
    # claiming the wrong version; installed_version can query the executable.
    rm -f "$INSTALLED_VERSION_FILE"
    return 1
  fi
  rm -f "$INSTALLED_VERSION_FILE"
}

_version_tmp="$INSTALLED_VERSION_FILE.$$.tmp"
if ! printf '%s\n' "$LATEST_VERSION" > "$_version_tmp" \
  || ! mv -f "$_version_tmp" "$INSTALLED_VERSION_FILE"; then
  rm -f "$_version_tmp"
  _marker_rollback_binary=0
  _marker_rollback_version=0
  _marker_removed_for_probe=0
  rollback_binary >/dev/null 2>&1 && _marker_rollback_binary=1
  if [ "$_marker_rollback_binary" -eq 1 ]; then
    restore_old_version_marker >/dev/null 2>&1 && _marker_rollback_version=1
  else
    # The new executable may still be installed. Remove any stale marker so
    # installed_version derives the version from the executable instead.
    rm -f "$INSTALLED_VERSION_FILE" >/dev/null 2>&1 && _marker_removed_for_probe=1
  fi
  if [ "$_marker_rollback_binary" -eq 1 ] && [ "$_marker_rollback_version" -eq 1 ]; then
    msg="Failed to record the installed dnscrypt-proxy version; the previous binary and marker were restored."
  elif [ "$_marker_rollback_binary" -eq 1 ]; then
    msg="Failed to record the installed dnscrypt-proxy version; the previous binary was restored but its version marker could not be restored."
  elif [ "$_marker_removed_for_probe" -eq 1 ]; then
    msg="Failed to record the installed dnscrypt-proxy version and failed to roll back the binary; the stale marker was removed so the executable remains authoritative."
  else
    msg="Failed to record the installed dnscrypt-proxy version and failed to roll back the binary; installed state may be inconsistent."
  fi
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

if [ "$WAS_RUNNING" -eq 1 ]; then
  if ! DNSCRYPT_CONTROL_LOCK_HELD=1 \
    sh "$MODDIR/scripts/dnscrypt-control.sh" restart >/dev/null 2>&1; then
    _rollback_ok=0
    rollback_binary >/dev/null 2>&1 && _rollback_ok=1
    _marker_restore_ok=0
    if [ "$_rollback_ok" -eq 1 ]; then
      restore_old_version_marker >/dev/null 2>&1 && _marker_restore_ok=1
    fi
    _recovery_ok=0
    if [ "$_rollback_ok" -eq 1 ] \
      && DNSCRYPT_CONTROL_LOCK_HELD=1 \
        sh "$MODDIR/scripts/dnscrypt-control.sh" start >/dev/null 2>&1; then
      _recovery_ok=1
    fi
    if [ "$_recovery_ok" -eq 1 ] && [ "$_marker_restore_ok" -eq 1 ]; then
      msg="dnscrypt-proxy $LATEST_VERSION failed to restart; the previous binary was restored and restarted."
    elif [ "$_recovery_ok" -eq 1 ]; then
      msg="dnscrypt-proxy $LATEST_VERSION failed to restart; the previous binary was restarted but its version marker could not be restored."
    elif [ "$_rollback_ok" -eq 1 ]; then
      msg="dnscrypt-proxy $LATEST_VERSION failed to restart; the previous binary was restored but recovery did not become healthy."
    else
      msg="dnscrypt-proxy $LATEST_VERSION failed to restart and the binary rollback failed; the new version marker was left unchanged to avoid misreporting the on-disk binary."
    fi
    write_update_status "error" "$LATEST_VERSION" "$msg"
    log_msg "$UPDATE_LOG" "$msg"
    rm -rf "$WORK"
    echo "$msg"
    exit 1
  fi
fi

if [ "$HAD_OLD_BINARY" -eq 1 ]; then
  cp -af "$OLD_BINARY" "$DNSCRYPT_BIN.bak" 2>/dev/null || true
fi
update_module_description "$LATEST_VERSION"

msg="Installed dnscrypt-proxy $LATEST_VERSION for $ARCH_ASSET."
write_update_status "updated" "$LATEST_VERSION" "$msg"
log_msg "$UPDATE_LOG" "$msg"
date +%s > "$LAST_CHECK_FILE" 2>/dev/null || true
# Notify only on a successful update; failures stay silent (log only) to avoid noise.
notify_user "dnscrypt-proxy 已更新" "已更新至 $LATEST_VERSION，GitHub 發佈資產 SHA256 比對相符"
rm -rf "$WORK"
echo "$msg"
exit 0
