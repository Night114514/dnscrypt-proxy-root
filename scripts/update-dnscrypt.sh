#!/system/bin/sh
set -u

SCRIPT_DIR=${0%/*}
MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
# The runtime module path is dynamic by design; common.sh is linted separately.
# shellcheck disable=SC1091
. "$MODDIR/scripts/common.sh"

MODE="${1:-auto}"
CHECK_INTERVAL_SECONDS="${DNSCRYPT_UPDATE_INTERVAL_SECONDS:-86400}"
LAST_CHECK_FILE="$RUN_DIR/last-update-check"
LOCK_FILE="$RUN_DIR/update.lock"
LOCK_GUARD_FILE="$RUN_DIR/update.lock.guard"
LEGACY_REAP_FILE="$RUN_DIR/update.lock.reap"
LOCK_OWNER="flock:$$"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$TMP_BASE"

LOCK_OWNED=0
LOCK_FD_OPEN=0

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
  [ "$now" -gt 0 ] || return 1
  age=$((now - last))
  [ "$age" -lt "$CHECK_INTERVAL_SECONDS" ]
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

date +%s > "$LAST_CHECK_FILE" 2>/dev/null || true

CURRENT_VERSION=$(installed_version)
ASSET_URL=$(make_asset_url "$LATEST_VERSION" "$ARCH_ASSET")

if [ "$MODE" = "check" ]; then
  write_update_status "checked" "$LATEST_VERSION" "Latest upstream version is $LATEST_VERSION; installed version is $CURRENT_VERSION."
  echo "latest=$LATEST_VERSION"
  echo "installed=$CURRENT_VERSION"
  echo "asset=$ASSET_URL"
  rm -rf "$WORK"
  exit 0
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ] && [ -x "$DNSCRYPT_BIN" ] && [ "$MODE" != "force" ] && [ "$MODE" != "install" ]; then
  msg="Already up to date: $LATEST_VERSION"
  write_update_status "up_to_date" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  echo "$msg"
  rm -rf "$WORK"
  exit 0
fi

log_msg "$UPDATE_LOG" "Downloading $ASSET_URL"
if ! download_file "$ASSET_URL" "$ZIP_FILE"; then
  msg="Failed to download dnscrypt-proxy asset: $ASSET_URL"
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

# Best-effort integrity comparison only: when a "minisign.txt" checksum list is
# available, compare its SHA256 entry with the downloaded archive. This list is
# fetched from the same release and is not authenticated with Minisign. Missing
# checksum data therefore fails open and installation continues.
SHA_MATCHED=0
SHA_FILE="$WORK/minisign.txt"
SHA_URL="$UPSTREAM_RELEASE_BASE/$LATEST_VERSION/minisign.txt"
if download_file "$SHA_URL" "$SHA_FILE" && [ -s "$SHA_FILE" ]; then
  ASSET_NAME="dnscrypt-proxy-${ARCH_ASSET}-${LATEST_VERSION}.zip"
  EXPECTED_SHA=$(grep -F "$ASSET_NAME" "$SHA_FILE" 2>/dev/null | awk '{print $1}' | head -n 1)
  ACTUAL_SHA=$(sha256_of "$ZIP_FILE")
  if [ -n "$EXPECTED_SHA" ] && [ -n "$ACTUAL_SHA" ]; then
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
      msg="SHA256 mismatch for $ASSET_NAME; expected $EXPECTED_SHA got $ACTUAL_SHA."
      write_update_status "error" "$LATEST_VERSION" "$msg"
      log_msg "$UPDATE_LOG" "$msg"
      rm -rf "$WORK"
      echo "$msg"
      exit 1
    fi
    SHA_MATCHED=1
    log_msg "$UPDATE_LOG" "SHA256 matched for $ASSET_NAME; checksum list is not signature-authenticated."
  else
    log_msg "$UPDATE_LOG" "SHA256 entry unavailable for $ASSET_NAME; continuing without checksum comparison."
  fi
else
  log_msg "$UPDATE_LOG" "Could not fetch checksum list; continuing without checksum comparison."
fi

if ! unzip_file "$ZIP_FILE" "$EXTRACT_DIR"; then
  msg="Failed to unzip dnscrypt-proxy release asset."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

NEW_BIN=""
for candidate in "$EXTRACT_DIR"/android-*/dnscrypt-proxy "$EXTRACT_DIR"/*/dnscrypt-proxy "$EXTRACT_DIR"/dnscrypt-proxy; do
  if [ -f "$candidate" ]; then
    NEW_BIN="$candidate"
    break
  fi
done

if [ -z "$NEW_BIN" ]; then
  msg="Release asset did not contain dnscrypt-proxy binary."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

chmod 0755 "$NEW_BIN" 2>/dev/null || true
if [ ! -s "$NEW_BIN" ]; then
  msg="Downloaded dnscrypt-proxy binary is empty."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi

mkdir -p "$BIN_DIR"
if [ -f "$DNSCRYPT_BIN" ]; then
  cp -af "$DNSCRYPT_BIN" "$DNSCRYPT_BIN.bak" 2>/dev/null || true
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
chmod 0755 "$DNSCRYPT_BIN.tmp" 2>/dev/null || true
if ! mv -f "$DNSCRYPT_BIN.tmp" "$DNSCRYPT_BIN"; then
  msg="Failed to install new dnscrypt-proxy binary."
  write_update_status "error" "$LATEST_VERSION" "$msg"
  log_msg "$UPDATE_LOG" "$msg"
  rm -f "$DNSCRYPT_BIN.tmp"
  rm -rf "$WORK"
  echo "$msg"
  exit 1
fi
echo "$LATEST_VERSION" > "$INSTALLED_VERSION_FILE"
update_module_description "$LATEST_VERSION"

msg="Installed dnscrypt-proxy $LATEST_VERSION for $ARCH_ASSET."
write_update_status "updated" "$LATEST_VERSION" "$msg"
log_msg "$UPDATE_LOG" "$msg"
# Notify only on a successful update; failures stay silent (log only) to avoid noise.
if [ "$SHA_MATCHED" -eq 1 ]; then
  notify_user "dnscrypt-proxy 已更新" "已更新至 $LATEST_VERSION，SHA256 比對相符"
else
  notify_user "dnscrypt-proxy 已更新" "已更新至 $LATEST_VERSION"
fi
rm -rf "$WORK"
echo "$msg"
exit 0
