#!/system/bin/sh

MODID="dnscrypt-proxy-root"
UPSTREAM_API="https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest"
UPSTREAM_RELEASE_BASE="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download"
DEFAULT_LISTEN="127.0.0.1:5354"

if [ -z "$MODDIR" ]; then
  SCRIPT_DIR=${0%/*}
  MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
fi

BIN_DIR="$MODDIR/bin"
CONFIG_DIR="$MODDIR/config"
RUN_DIR="$MODDIR/run"
LOG_DIR="$MODDIR/logs"
TMP_BASE="$MODDIR/tmp"
DNSCRYPT_BIN="$BIN_DIR/dnscrypt-proxy"
CONFIG_FILE="$CONFIG_DIR/dnscrypt-proxy.toml"
PID_FILE="$RUN_DIR/dnscrypt-proxy.pid"
INSTALLED_VERSION_FILE="$RUN_DIR/installed-version"
UPDATE_STATUS_FILE="$RUN_DIR/update-status.env"
UPDATE_LOG="$LOG_DIR/update.log"
SERVICE_LOG="$LOG_DIR/service.log"
CONTROL_LOG="$LOG_DIR/control.log"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_BASE" 2>/dev/null

now_iso() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

log_msg() {
  _target="$1"
  shift
  echo "[$(now_iso)] $*" >> "$_target"
}

json_escape_line() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

busybox_cmd() {
  if has_cmd busybox; then
    busybox "$@"
  elif [ -x /data/adb/magisk/busybox ]; then
    /data/adb/magisk/busybox "$@"
  elif [ -x /data/adb/ksu/bin/busybox ]; then
    /data/adb/ksu/bin/busybox "$@"
  elif [ -x /data/adb/ap/bin/busybox ]; then
    /data/adb/ap/bin/busybox "$@"
  else
    return 127
  fi
}

download_file() {
  _url="$1"
  _out="$2"
  rm -f "$_out"
  if has_cmd curl; then
    curl -LfsS --connect-timeout 15 --max-time 180 -o "$_out" "$_url"
    return $?
  fi
  if has_cmd wget; then
    wget -q -T 180 -O "$_out" "$_url"
    return $?
  fi
  busybox_cmd wget -q -T 180 -O "$_out" "$_url"
}

unzip_file() {
  _zip="$1"
  _dest="$2"
  mkdir -p "$_dest"
  if has_cmd unzip; then
    unzip -oq "$_zip" -d "$_dest"
    return $?
  fi
  busybox_cmd unzip -oq "$_zip" -d "$_dest"
}

get_device_arch() {
  _abi=$(getprop ro.product.cpu.abi 2>/dev/null)
  [ -z "$_abi" ] && _abi=$(uname -m 2>/dev/null)
  case "$_abi" in
    arm64-v8a|aarch64|arm64) echo "arm64" ;;
    armeabi-v7a|armeabi|armv7l|armv8l|arm) echo "arm" ;;
    x86|i386|i686) echo "i386" ;;
    x86_64|amd64) echo "x86_64" ;;
    *) echo "unknown" ;;
  esac
}

asset_arch_name() {
  case "$(get_device_arch)" in
    arm64) echo "android_arm64" ;;
    arm) echo "android_arm" ;;
    i386) echo "android_i386" ;;
    x86_64) echo "android_x86_64" ;;
    *) echo "unknown" ;;
  esac
}

extract_tag_name() {
  sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

make_asset_url() {
  _tag="$1"
  _asset_arch="$2"
  echo "$UPSTREAM_RELEASE_BASE/$_tag/dnscrypt-proxy-${_asset_arch}-${_tag}.zip"
}

installed_version() {
  if [ -f "$INSTALLED_VERSION_FILE" ]; then
    cat "$INSTALLED_VERSION_FILE"
  elif [ -x "$DNSCRYPT_BIN" ]; then
    "$DNSCRYPT_BIN" -version 2>/dev/null | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
  else
    echo "none"
  fi
}

write_update_status() {
  _state="$1"
  _version="$2"
  _message="$3"
  {
    echo "state=$_state"
    echo "version=$_version"
    echo "message=$_message"
    echo "time=$(now_iso)"
  } > "$UPDATE_STATUS_FILE"
}

set_prop_value() {
  _key="$1"
  _value="$2"
  _file="$3"
  if [ -f "$_file" ] && grep -q "^${_key}=" "$_file"; then
    sed -i "s#^${_key}=.*#${_key}=${_value}#" "$_file"
  else
    echo "${_key}=${_value}" >> "$_file"
  fi
}

update_module_description() {
  _version="$1"
  _desc="Systemless dnscrypt-proxy for Magisk/KernelSU/APatch with automatic upstream binary updates and KernelSU/APatch WebUI. Installed dnscrypt-proxy: ${_version}."
  set_prop_value description "$_desc" "$MODDIR/module.prop"
  if [ "$KSU" = "true" ] && has_cmd ksud; then
    ksud module config set override.description "$_desc" >/dev/null 2>&1 || true
  fi
}

is_dnscrypt_running() {
  if [ -f "$PID_FILE" ]; then
    _pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$_pid" ] && kill -0 "$_pid" >/dev/null 2>&1 && return 0
  fi
  pgrep -x dnscrypt-proxy >/dev/null 2>&1
}
