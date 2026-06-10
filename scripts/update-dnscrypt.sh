#!/system/bin/sh

SCRIPT_DIR=${0%/*}
MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
. "$MODDIR/scripts/common.sh"

MODE="${1:-auto}"
CHECK_INTERVAL_SECONDS="${DNSCRYPT_UPDATE_INTERVAL_SECONDS:-86400}"
LAST_CHECK_FILE="$RUN_DIR/last-update-check"
LOCK_FILE="$RUN_DIR/update.lock"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$TMP_BASE"

finish() {
  rm -f "$LOCK_FILE"
}
trap finish EXIT HUP INT TERM

if [ -f "$LOCK_FILE" ]; then
  old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
    echo "Another update process is running."
    exit 2
  fi
fi
echo $$ > "$LOCK_FILE"

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

date +%s > "$LAST_CHECK_FILE" 2>/dev/null || true

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
  rm -rf "$WORK"
  echo "$msg"
  exit 1
}
chmod 0755 "$DNSCRYPT_BIN.tmp" 2>/dev/null || true
mv -f "$DNSCRYPT_BIN.tmp" "$DNSCRYPT_BIN"
echo "$LATEST_VERSION" > "$INSTALLED_VERSION_FILE"
update_module_description "$LATEST_VERSION"

msg="Installed dnscrypt-proxy $LATEST_VERSION for $ARCH_ASSET."
write_update_status "updated" "$LATEST_VERSION" "$msg"
log_msg "$UPDATE_LOG" "$msg"
rm -rf "$WORK"
echo "$msg"
exit 0
