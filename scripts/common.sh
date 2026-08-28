#!/system/bin/sh
# These assignments form the public state of a sourced shell library.
# shellcheck disable=SC2034
set -u

MODID="dnscrypt-proxy-root"
UPSTREAM_API="https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest"
UPSTREAM_RELEASE_BASE="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download"
DEFAULT_LISTEN="127.0.0.1:5354"
# Run the proxy with Android's reserved AID_INET numeric identity. dnscrypt-proxy
# clears supplementary groups while dropping privileges, so an arbitrary Linux
# nobody UID can lose permission to create AF_INET/AF_INET6 sockets on Android.
# Owner matching checks the UID (3003), not apps' supplementary inet group.
DNSCRYPT_UID="3003"
PROC_ROOT="${DNSCRYPT_PROC_ROOT:-/proc}"

if [ -z "${MODDIR:-}" ]; then
  SCRIPT_DIR=${0%/*}
  MODDIR=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
fi

BIN_DIR="$MODDIR/bin"
CONFIG_DIR="$MODDIR/config"
STATE_DIR="$MODDIR/state"
RUN_DIR="$MODDIR/run"
LOG_DIR="$MODDIR/logs"
TMP_BASE="$MODDIR/tmp"
PROC_SYS_ROOT="${DNSCRYPT_PROC_SYS_ROOT:-/proc/sys}"
DNSCRYPT_BIN="$BIN_DIR/dnscrypt-proxy"
CONFIG_FILE="$CONFIG_DIR/dnscrypt-proxy.toml"
PID_FILE="$RUN_DIR/dnscrypt-proxy.pid"
WATCHDOG_PID_FILE="$RUN_DIR/watchdog.pid"
WATCHDOG_SCRIPT="$MODDIR/scripts/watchdog.sh"
SERVICE_LOCK_FILE="$RUN_DIR/control.lock"
PRIVATE_DNS_STATE_FILE="$STATE_DIR/private-dns.state"
MODULE_SHUTDOWN_FILE="$STATE_DIR/shutdown-requested"
INSTALLED_VERSION_FILE="$RUN_DIR/installed-version"
USER_STOPPED_FILE="$RUN_DIR/user_stopped"
UPDATE_STATUS_FILE="$RUN_DIR/update-status.env"
UPDATE_LOG="$LOG_DIR/update.log"
SERVICE_LOG="$LOG_DIR/service.log"
CONTROL_LOG="$LOG_DIR/control.log"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_BASE" 2>/dev/null
chmod 0700 "$STATE_DIR" 2>/dev/null || true
chown 0:0 "$STATE_DIR" 2>/dev/null || true

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

# Post an Android status-bar notification. title/message are fixed strings we
# control, so single-quoting them in the su fallback is safe from injection.
notify_user() {
  _title="$1"
  _message="$2"
  cmd notification post -S bigtext -t "$_title" "dnscrypt_proxy" "$_message" >/dev/null 2>&1 || \
  su 2000 -c "cmd notification post -S bigtext -t '$_title' 'dnscrypt_proxy' '$_message'" >/dev/null 2>&1 || \
  true
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

flock_fd_nonblocking() {
  _lock_fd="$1"
  if has_cmd flock; then
    flock -n "$_lock_fd"
    return $?
  fi
  busybox_cmd flock -n "$_lock_fd"
}

# Serialize mutating control actions. Normal WebUI/action calls remain
# non-blocking. Lifecycle callers can set DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS to
# wait a bounded number of seconds for an operation already in its commit
# section instead of unlinking a live lock inode during uninstall.
acquire_control_lock() {
  _lock_wait_seconds=${DNSCRYPT_CONTROL_LOCK_WAIT_SECONDS:-0}
  case "$_lock_wait_seconds" in
    ""|*[!0-9]*) return 1 ;;
  esac
  mkdir -p "$RUN_DIR" || return 1
  exec 8>> "$SERVICE_LOCK_FILE" || return 1
  _lock_waited=0
  while :; do
    flock_fd_nonblocking 8
    _lock_status=$?
    case "$_lock_status" in
      0) return 0 ;;
      1)
        if [ "$_lock_waited" -ge "$_lock_wait_seconds" ]; then
          exec 8>&-
          return 2
        fi
        sleep 1
        _lock_waited=$((_lock_waited + 1))
        ;;
      *)
        exec 8>&-
        return 1
        ;;
    esac
  done
}

# update-dnscrypt.sh may hold the control lock across binary commit and delegate
# a restart to dnscrypt-control.sh. Validate the inherited descriptor rather
# than trusting an environment flag alone; this keeps the nested call on the
# same stable inode and prevents a self-deadlock from reopening the lock file.
inherited_control_lock_valid() {
  [ "${DNSCRYPT_CONTROL_LOCK_HELD:-0}" = "1" ] || return 1
  if has_cmd readlink; then
    _inherited_lock_path=$(readlink "/proc/$$/fd/8" 2>/dev/null || true)
  else
    _inherited_lock_path=$(busybox_cmd readlink "/proc/$$/fd/8" 2>/dev/null || true)
  fi
  [ "$_inherited_lock_path" = "$SERVICE_LOCK_FILE" ] || return 1
  flock_fd_nonblocking 8
}

shutdown_requested() {
  [ -f "$MODULE_SHUTDOWN_FILE" ] \
    || [ -f "$MODDIR/disable" ] \
    || [ -f "$MODDIR/remove" ]
}

# uninstall.sh writes this persistent marker before stopping background work.
# It lives outside run/ so removing transient PID/lock files cannot accidentally
# re-enable a late updater or control process.
request_module_shutdown() {
  mkdir -p "$STATE_DIR" || return 1
  _shutdown_tmp="$MODULE_SHUTDOWN_FILE.$$.tmp"
  printf '%s\n' "$(now_iso)" > "$_shutdown_tmp" || {
    rm -f "$_shutdown_tmp"
    return 1
  }
  chmod 0600 "$_shutdown_tmp" 2>/dev/null || true
  chown 0:0 "$_shutdown_tmp" 2>/dev/null || true
  mv -f "$_shutdown_tmp" "$MODULE_SHUTDOWN_FILE" || {
    rm -f "$_shutdown_tmp"
    return 1
  }
}

private_dns_state_valid() {
  _private_state_file="$1"
  [ -f "$_private_state_file" ] && [ ! -L "$_private_state_file" ] || return 1
  [ "$(grep -c '^mode=' "$_private_state_file" 2>/dev/null || true)" = "1" ] || return 1
  [ "$(grep -c '^specifier=' "$_private_state_file" 2>/dev/null || true)" = "1" ] || return 1
  [ "$(wc -l < "$_private_state_file" 2>/dev/null | tr -d ' ')" = "2" ] || return 1
  _state_mode=$(sed -n 's/^mode=//p' "$_private_state_file" | head -n 1)
  _state_specifier=$(sed -n 's/^specifier=//p' "$_private_state_file" | head -n 1)
  case "$_state_mode" in
    null|off|opportunistic) ;;
    hostname)
      case "$_state_specifier" in null|"") return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  case "$_state_specifier" in
    null|"") ;;
    *[!a-zA-Z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Android's settings command prints the literal string "null" for an unset
# key. Store that value verbatim so uninstall/stop can restore deletion rather
# than accidentally writing the word "null" as a real setting.
save_and_disable_private_dns() {
  has_cmd settings || return 1
  if [ -f "$PRIVATE_DNS_STATE_FILE" ]; then
    # A malformed or symlinked migrated state is not a usable rollback point.
    # Refuse to change Android settings until the user repairs/removes it.
    private_dns_state_valid "$PRIVATE_DNS_STATE_FILE" || return 1
  else
    _private_mode=$(settings get global private_dns_mode 2>/dev/null) || return 1
    _private_specifier=$(settings get global private_dns_specifier 2>/dev/null) || return 1
    case "$_private_mode" in
      null|off|opportunistic|hostname) ;;
      *) return 1 ;;
    esac
    case "$_private_specifier" in
      null|""|*[!a-zA-Z0-9._-]*)
        [ "$_private_specifier" = "null" ] || [ -z "$_private_specifier" ] || return 1
        ;;
    esac
    _private_tmp="$PRIVATE_DNS_STATE_FILE.$$.tmp"
    {
      printf 'mode=%s\n' "$_private_mode"
      printf 'specifier=%s\n' "$_private_specifier"
    } > "$_private_tmp" || {
      rm -f "$_private_tmp"
      return 1
    }
    chmod 0600 "$_private_tmp" 2>/dev/null || true
    chown 0:0 "$_private_tmp" 2>/dev/null || true
    mv -f "$_private_tmp" "$PRIVATE_DNS_STATE_FILE" || {
      rm -f "$_private_tmp"
      return 1
    }
  fi
  settings put global private_dns_mode off >/dev/null 2>&1
}

restore_private_dns() {
  [ -f "$PRIVATE_DNS_STATE_FILE" ] || return 0
  has_cmd settings || return 1
  private_dns_state_valid "$PRIVATE_DNS_STATE_FILE" || return 1
  _private_mode=$(sed -n 's/^mode=//p' "$PRIVATE_DNS_STATE_FILE" | head -n 1)
  _private_specifier=$(sed -n 's/^specifier=//p' "$PRIVATE_DNS_STATE_FILE" | head -n 1)
  case "$_private_specifier" in
    null) settings delete global private_dns_specifier >/dev/null 2>&1 || return 1 ;;
    "") settings put global private_dns_specifier "" >/dev/null 2>&1 || return 1 ;;
    *[!a-zA-Z0-9._-]*) return 1 ;;
    *) settings put global private_dns_specifier "$_private_specifier" >/dev/null 2>&1 || return 1 ;;
  esac
  # Restore the specifier first so hostname mode is never briefly re-enabled
  # with a stale provider name.
  case "$_private_mode" in
    null) settings delete global private_dns_mode >/dev/null 2>&1 || return 1 ;;
    *) settings put global private_dns_mode "$_private_mode" >/dev/null 2>&1 || return 1 ;;
  esac
  rm -f "$PRIVATE_DNS_STATE_FILE"
}

# Use the platform base64 implementation when it is exposed as a standalone
# command, and fall back to the BusyBox applet shipped by the root manager.
base64_decode() {
  if has_cmd base64; then
    base64 -d
  else
    busybox_cmd base64 -d
  fi
}

base64_encode_file() {
  _file="$1"
  [ -r "$_file" ] || return 1
  if has_cmd base64; then
    base64 "$_file" 2>/dev/null | tr -d '\r\n'
    return $?
  fi
  # Probe the applet before entering a pipeline, whose final tr command would
  # otherwise hide a missing BusyBox implementation.
  busybox_cmd base64 </dev/null >/dev/null 2>&1 || return $?
  busybox_cmd base64 "$_file" 2>/dev/null | tr -d '\r\n'
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

sha256_of() {
  _file="$1"
  if has_cmd sha256sum; then
    sha256sum "$_file" 2>/dev/null | awk '{print $1}'
  else
    busybox_cmd sha256sum "$_file" 2>/dev/null | awk '{print $1}'
  fi
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

# Extract GitHub's server-computed SHA-256 digest for one top-level release
# asset. GitHub may return compact one-line JSON or pretty-printed JSON, so a
# fixed-indentation parser is not sufficient. This small JSON object scanner
# tracks strings and nested braces inside the assets array, then reads the
# first name and digest fields from each complete asset object. Asset names are
# restricted by the caller to our generated safe filename. Any malformed or
# unsupported response produces no output so callers fail closed.
extract_asset_sha256() {
  _asset_json="$1"
  _asset_name="$2"
  awk -v wanted="$_asset_name" '
    function first_string_field(object, key,    prefix, tail, end) {
      prefix = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      if (!match(object, prefix)) return ""
      tail = substr(object, RSTART + RLENGTH)
      if (!match(tail, /"/)) return ""
      end = RSTART
      return substr(tail, 1, end - 1)
    }
    {
      json = json $0 "\n"
    }
    END {
      assets_at = index(json, "\"assets\"")
      if (!assets_at) exit
      rest = substr(json, assets_at)
      array_at = index(rest, "[")
      if (!array_at) exit
      rest = substr(rest, array_at + 1)

      depth = 0
      in_string = 0
      escaped = 0
      object = ""
      for (i = 1; i <= length(rest); i++) {
        ch = substr(rest, i, 1)
        if (in_string) {
          if (depth > 0) object = object ch
          if (escaped) escaped = 0
          else if (ch == "\\") escaped = 1
          else if (ch == "\"") in_string = 0
          continue
        }
        if (ch == "\"") {
          in_string = 1
          if (depth > 0) object = object ch
          continue
        }
        if (ch == "{") {
          depth++
          if (depth == 1) object = "{"
          else object = object ch
          continue
        }
        if (depth == 0 && ch == "]") exit
        if (depth > 0) object = object ch
        if (ch != "}") continue

        depth--
        if (depth != 0) continue
        name = first_string_field(object, "name")
        if (name == wanted) {
          digest = first_string_field(object, "digest")
          if (digest ~ /^sha256:/) {
            sub(/^sha256:/, "", digest)
            print digest
          }
          exit
        }
        object = ""
      }
    }
  ' "$_asset_json"
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
  if [ "${KSU:-}" = "true" ] && has_cmd ksud; then
    ksud module config set override.description "$_desc" >/dev/null 2>&1 || true
  fi
}

# Verify liveness and the complete daemon command line. Requiring the exact
# binary/config tuple and no one-shot subcommand prevents a stale PID file from
# matching an unrelated process or a short-lived `dnscrypt-proxy -resolve`.
is_dnscrypt_pid() {
  _candidate_pid="$1"
  case "$_candidate_pid" in
    ""|*[!0-9]*) return 1 ;;
  esac
  _candidate_cmdline="$PROC_ROOT/$_candidate_pid/cmdline"
  [ -r "$_candidate_cmdline" ] || return 1
  kill -0 "$_candidate_pid" >/dev/null 2>&1 || return 1
  _candidate_argv0=$(tr '\0' '\n' < "$_candidate_cmdline" 2>/dev/null | sed -n '1p')
  _candidate_argv1=$(tr '\0' '\n' < "$_candidate_cmdline" 2>/dev/null | sed -n '2p')
  _candidate_argv2=$(tr '\0' '\n' < "$_candidate_cmdline" 2>/dev/null | sed -n '3p')
  _candidate_argv3=$(tr '\0' '\n' < "$_candidate_cmdline" 2>/dev/null | sed -n '4p')
  [ "$_candidate_argv0" = "$DNSCRYPT_BIN" ] \
    && [ "$_candidate_argv1" = "-config" ] \
    && [ "$_candidate_argv2" = "$CONFIG_FILE" ] \
    && [ -z "$_candidate_argv3" ]
}

# Resolve the running dnscrypt-proxy PID. Fall back to an exact argv[0] scan
# because pgrep is not guaranteed on toybox-only Android shells.
dnscrypt_pid() {
  if [ -f "$PID_FILE" ]; then
    _pid=$(cat "$PID_FILE" 2>/dev/null)
    if is_dnscrypt_pid "$_pid"; then
      echo "$_pid"
      return 0
    fi
  fi
  for _cmdline in "$PROC_ROOT"/[0-9]*/cmdline; do
    [ -r "$_cmdline" ] || continue
    _argv0=$(tr '\0' '\n' < "$_cmdline" 2>/dev/null | head -n 1)
    case "$_argv0" in
      "$DNSCRYPT_BIN")
        _proc_dir=${_cmdline%/cmdline}
        _pid=${_proc_dir##*/}
        if is_dnscrypt_pid "$_pid"; then
          echo "$_pid"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

is_dnscrypt_running() {
  dnscrypt_pid >/dev/null 2>&1
}

is_dnscrypt_ready() {
  is_dnscrypt_running || return 1
  [ -x "$DNSCRYPT_BIN" ] || return 1
  [ -f "$CONFIG_FILE" ] || return 1
  "$DNSCRYPT_BIN" -config "$CONFIG_FILE" -resolve dns.google >/dev/null 2>&1
}

is_watchdog_pid() {
  _watchdog_candidate="$1"
  case "$_watchdog_candidate" in
    ""|*[!0-9]*) return 1 ;;
  esac
  _watchdog_cmdline="$PROC_ROOT/$_watchdog_candidate/cmdline"
  [ -r "$_watchdog_cmdline" ] || return 1
  kill -0 "$_watchdog_candidate" >/dev/null 2>&1 || return 1
  _watchdog_argv0=$(tr '\0' '\n' < "$_watchdog_cmdline" 2>/dev/null | sed -n '1p')
  _watchdog_argv1=$(tr '\0' '\n' < "$_watchdog_cmdline" 2>/dev/null | sed -n '2p')
  case "$_watchdog_argv0" in
    sh|*/sh) ;;
    *) return 1 ;;
  esac
  [ "$_watchdog_argv1" = "$WATCHDOG_SCRIPT" ]
}

watchdog_pid() {
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    _watchdog_pid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    if is_watchdog_pid "$_watchdog_pid"; then
      printf '%s\n' "$_watchdog_pid"
      return 0
    fi
  fi
  # Recover an untracked watchdog left by an interrupted service.sh PID-file
  # write. Exact argv validation prevents matching unrelated shell scripts.
  for _watchdog_cmdline in "$PROC_ROOT"/[0-9]*/cmdline; do
    [ -r "$_watchdog_cmdline" ] || continue
    _watchdog_proc_dir=${_watchdog_cmdline%/cmdline}
    _watchdog_pid=${_watchdog_proc_dir##*/}
    if is_watchdog_pid "$_watchdog_pid"; then
      printf '%s\n' "$_watchdog_pid"
      return 0
    fi
  done
  return 1
}

stop_watchdog() {
  # Clean up all exact watchdog instances, including duplicates created by an
  # older module version. The cap prevents a hostile process churn from making
  # uninstall wait forever.
  _watchdog_stop_count=0
  while [ "$_watchdog_stop_count" -lt 16 ]; do
    _watchdog_pid=$(watchdog_pid 2>/dev/null || true)
    [ -n "$_watchdog_pid" ] || break
    kill "$_watchdog_pid" >/dev/null 2>&1 || true
    _watchdog_wait=0
    while is_watchdog_pid "$_watchdog_pid" && [ "$_watchdog_wait" -lt 5 ]; do
      sleep 1
      _watchdog_wait=$((_watchdog_wait + 1))
    done
    is_watchdog_pid "$_watchdog_pid" && kill -9 "$_watchdog_pid" >/dev/null 2>&1 || true
    _watchdog_stop_count=$((_watchdog_stop_count + 1))
  done
  rm -f "$WATCHDOG_PID_FILE"
}
