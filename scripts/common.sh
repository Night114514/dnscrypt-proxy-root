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

MODULE_BIN_DIR="$MODDIR/bin"
MODULE_CONFIG_DIR="$MODDIR/config"
STATE_DIR="$MODDIR/state"
RUN_DIR="$MODDIR/run"
LOG_DIR="$MODDIR/logs"
TMP_BASE="$MODDIR/tmp"
PROC_SYS_ROOT="${DNSCRYPT_PROC_SYS_ROOT:-/proc/sys}"
# Android deliberately keeps /data/adb at 0700, so a process already switched
# to UID/GID 3003 cannot traverse the module's storage path. The executable and
# its disposable execution inputs therefore live in a narrow persistent tree
# below /data/local. This is a copy, not a mount, so all root-manager mount
# namespaces see the same path.
RUNTIME_ROOT="${DNSCRYPT_RUNTIME_ROOT:-/data/local/dnscrypt-proxy-root-runtime}"
RUNTIME_LAYOUT_FILE="$RUNTIME_ROOT/.layout-owner"
RUNTIME_CREATE_PATH="$RUNTIME_ROOT.creating"
RUNTIME_REMOVE_PATH="$RUNTIME_ROOT.removing"
RUNTIME_ACTIVE_STAGE="$RUNTIME_ROOT/.active.creating"
RUNTIME_MODULE_BINARY_STAGE="$RUNTIME_ROOT/bin/.dnscrypt-proxy-module-stage"
RUNTIME_MODULE_BINARY_BACKUP="$RUNTIME_ROOT/bin/.dnscrypt-proxy-prestart-backup"
RUNTIME_OPERATION_FILE="$STATE_DIR/runtime-tree-op.state"
RUNTIME_LOCK_FILE="$RUN_DIR/runtime-tree.lock"
BIN_DIR="$RUNTIME_ROOT/bin"
CONFIG_DIR="$RUNTIME_ROOT/config"
RUNTIME_DATA_DIR="$RUNTIME_ROOT/data"
RUNTIME_BIN="$RUNTIME_ROOT/bin/dnscrypt-proxy"
if [ "$RUNTIME_ROOT" = "$MODDIR" ]; then
  RUNTIME_ACTIVE_DIR="$RUNTIME_ROOT/config"
else
  RUNTIME_ACTIVE_DIR="$RUNTIME_ROOT/active"
fi
RUNTIME_CONFIG_DIR="$RUNTIME_ACTIVE_DIR"
RUNTIME_CONFIG_FILE="$RUNTIME_CONFIG_DIR/dnscrypt-proxy.toml"
RUNTIME_DAEMON_PID_FILE="$RUNTIME_ROOT/.daemon-pid"
DNSCRYPT_BIN="$RUNTIME_BIN"
CONFIG_FILE="$CONFIG_DIR/dnscrypt-proxy.toml"
PID_FILE="$RUN_DIR/dnscrypt-proxy.pid"
WATCHDOG_PID_FILE="$RUN_DIR/watchdog.pid"
WATCHDOG_SCRIPT="$MODDIR/scripts/watchdog.sh"
SERVICE_LOCK_FILE="$RUN_DIR/control.lock"
PRIVATE_DNS_STATE_FILE="$STATE_DIR/private-dns.state"
DNS_MODE_STATE_FILE="$STATE_DIR/dns-mode.state"
FIREWALL_OWNERSHIP_FILE="$STATE_DIR/firewall-owned.state"
LEGACY_FIREWALL_ADOPTION_FILE="$STATE_DIR/legacy-firewall-adopt.state"
LEGACY_IPV6_REBOOT_FILE="$STATE_DIR/legacy-ipv6-reboot.state"
MODULE_SHUTDOWN_FILE="$STATE_DIR/shutdown-requested"
INSTALLED_VERSION_FILE="$RUN_DIR/installed-version"
USER_STOPPED_FILE="$RUN_DIR/user_stopped"
UPDATE_STATUS_FILE="$RUN_DIR/update-status.env"
STARTUP_STATE_FILE="$RUN_DIR/startup.state"
START_FAILURE_STATE_FILE="$RUN_DIR/start-failure.state"
UPSTREAM_STATUS_FILE="$RUN_DIR/upstream-status.env"
UPDATE_LOG="$LOG_DIR/update.log"
SERVICE_LOG="$LOG_DIR/service.log"
CONTROL_LOG="$LOG_DIR/control.log"

mkdir -p "$STATE_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_BASE" 2>/dev/null
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

runtime_override_is_authorized() {
  if [ -z "${DNSCRYPT_RUNTIME_ROOT:-}" ]; then
    [ "$RUNTIME_ROOT" = "/data/local/dnscrypt-proxy-root-runtime" ]
    return $?
  fi
  case "${DNSCRYPT_RUNTIME_TEST_MODE:-0}:${DNSCRYPT_INSTALLER_STAGE:-0}" in
    1:0) return 0 ;;
    0:1) ;;
    *) return 1 ;;
  esac
  [ "$RUNTIME_ROOT" = "$MODDIR" ]
}

runtime_path_is_safe() {
  runtime_override_is_authorized || return 1
  case "$RUNTIME_ROOT" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$RUNTIME_ROOT" in
    /|*/../*|*/./*|*//*|*/..|*/.|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
}

runtime_config_path_is_safe() {
  _runtime_config_candidate="$1"
  case "$_runtime_config_candidate" in
    "$CONFIG_DIR"/*)
      _runtime_config_basename=${_runtime_config_candidate#"$CONFIG_DIR"/}
      ;;
    *) return 1 ;;
  esac
  case "$_runtime_config_basename" in
    ""|.|..|*/*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
}

runtime_binary_path_is_safe() {
  _runtime_binary_candidate="$1"
  case "$_runtime_binary_candidate" in
    "$BIN_DIR"/*)
      _runtime_binary_basename=${_runtime_binary_candidate#"$BIN_DIR"/}
      ;;
    *) return 1 ;;
  esac
  case "$_runtime_binary_basename" in
    ""|.|..|*/*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
}

runtime_parent_is_trusted() {
  _runtime_parent=${RUNTIME_ROOT%/*}
  [ -n "$_runtime_parent" ] && [ "$_runtime_parent" != "$RUNTIME_ROOT" ] || return 1
  [ -d "$_runtime_parent" ] && [ ! -L "$_runtime_parent" ] || return 1
  [ "$(stat -c '%u:%g' "$_runtime_parent" 2>/dev/null)" = "0:0" ] || return 1
  # Android normally creates /data/local as 0751. Equally restrictive owner-
  # controlled modes are accepted, but group/other write is never repaired or
  # tolerated and the runtime UID must be able to traverse the parent.
  case "$(stat -c %a "$_runtime_parent" 2>/dev/null)" in
    701|705|711|715|741|745|751|755) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_layout_marker_at_is_trusted() {
  _runtime_marker_root="$1"
  _runtime_marker_path="$_runtime_marker_root/.layout-owner"
  [ -f "$_runtime_marker_path" ] && [ ! -L "$_runtime_marker_path" ] || return 1
  [ "$(stat -c '%u:%g:%a' "$_runtime_marker_path" 2>/dev/null)" = "0:0:600" ] || return 1
  [ "$(wc -c < "$_runtime_marker_path" 2>/dev/null | tr -d ' ')" = "22" ] || return 1
  [ "$(wc -l < "$_runtime_marker_path" 2>/dev/null | tr -d ' ')" = "1" ] || return 1
  [ "$(sed -n '1p' "$_runtime_marker_path" 2>/dev/null)" = "dnscrypt-proxy-root:5" ]
}

runtime_layout_marker_is_trusted() {
  runtime_layout_marker_at_is_trusted "$RUNTIME_ROOT"
}

runtime_binary_at_is_trusted() {
  _runtime_binary_path="$1"
  [ -f "$_runtime_binary_path" ] && [ ! -L "$_runtime_binary_path" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_binary_path" 2>/dev/null)" = "0:0:755" ]
}

runtime_active_snapshot_at_is_trusted() {
  _runtime_active_root="$1"
  [ -d "$_runtime_active_root" ] && [ ! -L "$_runtime_active_root" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_active_root" 2>/dev/null)" = \
      "$DNSCRYPT_UID:0:500" ] || return 1
  for _runtime_active_name in \
    dnscrypt-proxy.toml allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt
  do
    _runtime_active_path="$_runtime_active_root/$_runtime_active_name"
    [ -f "$_runtime_active_path" ] && [ ! -L "$_runtime_active_path" ] \
      && [ "$(stat -c '%u:%g:%a' "$_runtime_active_path" 2>/dev/null)" = \
        "$DNSCRYPT_UID:0:400" ] || return 1
  done
  return 0
}

runtime_tree_at_is_trusted() {
  _runtime_tree_root="$1"
  _runtime_tree_bin="$_runtime_tree_root/bin"
  _runtime_tree_config="$_runtime_tree_root/config"
  _runtime_tree_active="$_runtime_tree_root/active"
  _runtime_tree_data="$_runtime_tree_root/data"
  _runtime_tree_binary="$_runtime_tree_bin/dnscrypt-proxy"
  _runtime_tree_pid="$_runtime_tree_root/.daemon-pid"
  [ -d "$_runtime_tree_root" ] && [ ! -L "$_runtime_tree_root" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_tree_root" 2>/dev/null)" = "0:0:755" ] \
    && [ -d "$_runtime_tree_bin" ] && [ ! -L "$_runtime_tree_bin" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_tree_bin" 2>/dev/null)" = "0:0:755" ] \
    && [ -d "$_runtime_tree_config" ] && [ ! -L "$_runtime_tree_config" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_tree_config" 2>/dev/null)" = "0:0:700" ] \
    && [ -d "$_runtime_tree_data" ] && [ ! -L "$_runtime_tree_data" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_tree_data" 2>/dev/null)" = "3003:0:700" ] \
    && [ -f "$_runtime_tree_pid" ] && [ ! -L "$_runtime_tree_pid" ] \
    && [ "$(stat -c '%u:%g:%a' "$_runtime_tree_pid" 2>/dev/null)" = \
      "$DNSCRYPT_UID:0:600" ] \
    && runtime_layout_marker_at_is_trusted "$_runtime_tree_root" \
    || return 1
  if [ -e "$_runtime_tree_active" ] || [ -L "$_runtime_tree_active" ]; then
    runtime_active_snapshot_at_is_trusted "$_runtime_tree_active" || return 1
  fi
  if [ -e "$_runtime_tree_binary" ] || [ -L "$_runtime_tree_binary" ]; then
    runtime_binary_at_is_trusted "$_runtime_tree_binary" || return 1
  fi
  return 0
}

runtime_tree_is_trusted() {
  runtime_path_is_safe || return 1
  if [ "$RUNTIME_ROOT" = "$MODDIR" ]; then
    [ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] \
      && [ -d "$BIN_DIR" ] && [ ! -L "$BIN_DIR" ] \
      && [ -d "$CONFIG_DIR" ] && [ ! -L "$CONFIG_DIR" ]
    return $?
  fi
  runtime_parent_is_trusted || return 1
  runtime_tree_at_is_trusted "$RUNTIME_ROOT"
}

module_runtime_templates_are_trusted() {
  [ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] \
    && [ "$(stat -c '%u:%g:%a' "$MODDIR" 2>/dev/null)" = "0:0:755" ] \
    && [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] \
    && [ "$(stat -c '%u:%g:%a' "$STATE_DIR" 2>/dev/null)" = "0:0:700" ] \
    && [ -d "$MODULE_CONFIG_DIR" ] && [ ! -L "$MODULE_CONFIG_DIR" ] \
    && [ "$(stat -c '%u:%g:%a' "$MODULE_CONFIG_DIR" 2>/dev/null)" = "0:0:700" ] \
    && [ -d "$MODULE_BIN_DIR" ] && [ ! -L "$MODULE_BIN_DIR" ] \
    && [ "$(stat -c '%u:%g:%a' "$MODULE_BIN_DIR" 2>/dev/null)" = "0:0:755" ] \
    || return 1
  for _runtime_template_name in \
    dnscrypt-proxy.toml allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt
  do
    _runtime_template_path="$MODULE_CONFIG_DIR/$_runtime_template_name"
    [ -f "$_runtime_template_path" ] && [ ! -L "$_runtime_template_path" ] \
      && [ "$(stat -c '%u:%g:%a' "$_runtime_template_path" 2>/dev/null)" = "0:0:600" ] \
      || return 1
  done
  _runtime_template_subscriptions="$MODULE_CONFIG_DIR/subscriptions.json"
  if [ -e "$_runtime_template_subscriptions" ] || [ -L "$_runtime_template_subscriptions" ]; then
    [ -f "$_runtime_template_subscriptions" ] && [ ! -L "$_runtime_template_subscriptions" ] \
      && [ "$(stat -c '%u:%g:%a' "$_runtime_template_subscriptions" 2>/dev/null)" = "0:0:600" ] \
      || return 1
  fi
  if [ -e "$MODULE_BIN_DIR/dnscrypt-proxy" ] || [ -L "$MODULE_BIN_DIR/dnscrypt-proxy" ]; then
    [ -f "$MODULE_BIN_DIR/dnscrypt-proxy" ] && [ ! -L "$MODULE_BIN_DIR/dnscrypt-proxy" ] \
      && [ "$(stat -c '%u:%g:%a' "$MODULE_BIN_DIR/dnscrypt-proxy" 2>/dev/null)" = "0:0:755" ] \
      || return 1
  fi
}

runtime_operation_state() {
  if [ ! -e "$RUNTIME_OPERATION_FILE" ] && [ ! -L "$RUNTIME_OPERATION_FILE" ]; then
    printf '%s\n' none
    return 0
  fi
  [ -f "$RUNTIME_OPERATION_FILE" ] && [ ! -L "$RUNTIME_OPERATION_FILE" ] || return 1
  [ "$(stat -c '%u:%g:%a' "$RUNTIME_OPERATION_FILE" 2>/dev/null)" = "0:0:600" ] \
    || return 1
  [ "$(wc -c < "$RUNTIME_OPERATION_FILE" 2>/dev/null | tr -d ' ')" = "40" ] \
    && [ "$(wc -l < "$RUNTIME_OPERATION_FILE" 2>/dev/null | tr -d ' ')" = "2" ] \
    && [ "$(sed -n '1p' "$RUNTIME_OPERATION_FILE" 2>/dev/null)" = \
      "dnscrypt-proxy-root-runtime-op:1" ] || return 1
  _runtime_operation=$(sed -n '2p' "$RUNTIME_OPERATION_FILE" 2>/dev/null)
  case "$_runtime_operation" in
    create|remove) printf '%s\n' "$_runtime_operation" ;;
    *) return 1 ;;
  esac
}

write_runtime_operation() {
  _runtime_operation="$1"
  case "$_runtime_operation" in create|remove) ;; *) return 1 ;; esac
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] \
    && [ "$(stat -c '%u:%g:%a' "$STATE_DIR" 2>/dev/null)" = "0:0:700" ] || return 1
  _runtime_operation_tmp="$RUNTIME_OPERATION_FILE.$$.tmp"
  [ ! -e "$_runtime_operation_tmp" ] && [ ! -L "$_runtime_operation_tmp" ] || return 1
  if printf '%s\n%s\n' 'dnscrypt-proxy-root-runtime-op:1' "$_runtime_operation" \
      > "$_runtime_operation_tmp" \
    && chown 0:0 "$_runtime_operation_tmp" 2>/dev/null \
    && chmod 0600 "$_runtime_operation_tmp" 2>/dev/null \
    && mv -f "$_runtime_operation_tmp" "$RUNTIME_OPERATION_FILE" \
    && [ "$(runtime_operation_state 2>/dev/null)" = "$_runtime_operation" ]; then
    return 0
  fi
  rm -f "$_runtime_operation_tmp"
  return 1
}

clear_runtime_operation() {
  rm -f "$RUNTIME_OPERATION_FILE" \
    && [ ! -e "$RUNTIME_OPERATION_FILE" ] && [ ! -L "$RUNTIME_OPERATION_FILE" ]
}

acquire_runtime_tree_lock() {
  _runtime_lock_wait=${DNSCRYPT_RUNTIME_LOCK_WAIT_SECONDS:-10}
  case "$_runtime_lock_wait" in ""|*[!0-9]*) return 1 ;; esac
  [ "${#_runtime_lock_wait}" -le 3 ] || return 1
  mkdir -p "$RUN_DIR" || return 1
  exec 6>> "$RUNTIME_LOCK_FILE" || return 1
  chmod 0600 "$RUNTIME_LOCK_FILE" 2>/dev/null || {
    exec 6>&-
    return 1
  }
  _runtime_lock_waited=0
  while :; do
    flock_fd_nonblocking 6
    _runtime_lock_status=$?
    case "$_runtime_lock_status" in
      0) return 0 ;;
      1)
        if [ "$_runtime_lock_waited" -ge "$_runtime_lock_wait" ]; then
          exec 6>&-
          return 2
        fi
        sleep 1
        _runtime_lock_waited=$((_runtime_lock_waited + 1))
        ;;
      *) exec 6>&-; return 1 ;;
    esac
  done
}

runtime_owned_aux_path_is_safe() {
  _runtime_aux_path="$1"
  case "$_runtime_aux_path" in
    "$RUNTIME_CREATE_PATH"|"$RUNTIME_REMOVE_PATH"|"$RUNTIME_ACTIVE_STAGE") ;;
    *) return 1 ;;
  esac
  [ -d "$_runtime_aux_path" ] && [ ! -L "$_runtime_aux_path" ] \
    && [ "$(stat -c '%u:%g' "$_runtime_aux_path" 2>/dev/null)" = "0:0" ]
}

runtime_module_binary_stage_is_owned() {
  [ -f "$RUNTIME_MODULE_BINARY_STAGE" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_STAGE" ] \
    && [ "$(stat -c '%u:%g:%a' "$RUNTIME_MODULE_BINARY_STAGE" 2>/dev/null)" = \
      "0:0:755" ]
}

runtime_module_binary_backup_is_owned() {
  [ -f "$RUNTIME_MODULE_BINARY_BACKUP" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_BACKUP" ] \
    && [ "$(stat -c '%u:%g:%a' "$RUNTIME_MODULE_BINARY_BACKUP" 2>/dev/null)" = \
      "0:0:755" ]
}

cleanup_runtime_module_binary_stage() {
  if [ ! -e "$RUNTIME_MODULE_BINARY_STAGE" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_STAGE" ]; then
    return 0
  fi
  runtime_module_binary_stage_is_owned || return 1
  rm -f "$RUNTIME_MODULE_BINARY_STAGE" \
    && [ ! -e "$RUNTIME_MODULE_BINARY_STAGE" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_STAGE" ]
}

cleanup_runtime_module_binary_backup() {
  if [ ! -e "$RUNTIME_MODULE_BINARY_BACKUP" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_BACKUP" ]; then
    return 0
  fi
  runtime_module_binary_backup_is_owned || return 1
  rm -f "$RUNTIME_MODULE_BINARY_BACKUP" \
    && [ ! -e "$RUNTIME_MODULE_BINARY_BACKUP" ] \
    && [ ! -L "$RUNTIME_MODULE_BINARY_BACKUP" ]
}

cleanup_runtime_create_path() {
  if [ ! -e "$RUNTIME_CREATE_PATH" ] && [ ! -L "$RUNTIME_CREATE_PATH" ]; then
    return 0
  fi
  runtime_owned_aux_path_is_safe "$RUNTIME_CREATE_PATH" || return 1
  rm -rf "$RUNTIME_CREATE_PATH" \
    && [ ! -e "$RUNTIME_CREATE_PATH" ] && [ ! -L "$RUNTIME_CREATE_PATH" ]
}

recover_runtime_create_locked() {
  if [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ]; then
    return 1
  fi
  if [ -e "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ]; then
    runtime_tree_is_trusted || return 1
    cleanup_runtime_create_path || return 1
    clear_runtime_operation || return 1
    return 0
  fi
  cleanup_runtime_create_path || return 1
  clear_runtime_operation
}

copy_runtime_template() {
  _runtime_copy_source="$1"
  _runtime_copy_target="$2"
  _runtime_copy_mode="$3"
  _runtime_copy_owner="$4"
  _runtime_copy_tmp="$_runtime_copy_target.$$.new"
  [ ! -e "$_runtime_copy_tmp" ] && [ ! -L "$_runtime_copy_tmp" ] || return 1
  if cp "$_runtime_copy_source" "$_runtime_copy_tmp" \
    && chown "$_runtime_copy_owner" "$_runtime_copy_tmp" 2>/dev/null \
    && chmod "$_runtime_copy_mode" "$_runtime_copy_tmp" 2>/dev/null \
    && mv -f "$_runtime_copy_tmp" "$_runtime_copy_target"; then
    return 0
  fi
  rm -f "$_runtime_copy_tmp"
  return 1
}

# Write the canonical TOML without its one exact top-level user_name assignment.
# Quote-aware comment handling keeps a # or [ inside a string from changing the
# parser state, and exactly one removal is required so this transformation can
# never silently diverge from config_runtime_user_is_safe().
write_config_without_runtime_user() {
  _runtime_strip_source="$1"
  _runtime_strip_target="$2"
  awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function code_without_comment(s,    i,c,out,in_sq,in_dq,esc) {
      out=""; in_sq=0; in_dq=0; esc=0
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (in_dq) {
          out=out c
          if (esc) esc=0
          else if (c=="\\") esc=1
          else if (c==dq) in_dq=0
          continue
        }
        if (in_sq) { out=out c; if (c==sq) in_sq=0; continue }
        if (c=="#") break
        out=out c
        if (c==dq) in_dq=1
        else if (c==sq) in_sq=1
      }
      if (in_sq || in_dq) bad=1
      return out
    }
    BEGIN { sq=sprintf("%c",39); dq=sprintf("%c",34); root=1; removed=0; bad=0 }
    {
      raw=$0
      if (index(raw,"\"\"\"") || index(raw,sq sq sq)) bad=1
      code=code_without_comment(raw); t=trim(code)
      if (t!="" && substr(t,1,1)=="[") root=0
      if (root && index(code,"=")>0) {
        lhs=code; sub(/=.*/,"",lhs); lhs=trim(lhs)
        if (lhs=="user_name") { removed++; next }
      }
      print raw
    }
    END { exit (!bad && removed==1) ? 0 : 42 }
  ' "$_runtime_strip_source" > "$_runtime_strip_target"
}

# The canonical TOML retains the documented user_name='3003' invariant, but
# dnscrypt-proxy is launched by the module after the shell has already switched
# to UID/GID 3003. Its daemon-owned, owner-readable execution copy must therefore
# omit the directive: upstream 2.1.18 otherwise requires an effective root UID
# and tries to perform a second privilege transition. The source has passed the
# restricted root-table checks before this helper is called.
copy_runtime_config_for_uid() {
  _runtime_uid_source="$1"
  _runtime_uid_target="$2"
  _runtime_uid_tmp="$_runtime_uid_target.$$.new"
  [ ! -e "$_runtime_uid_tmp" ] && [ ! -L "$_runtime_uid_tmp" ] || return 1
  if write_config_without_runtime_user \
      "$_runtime_uid_source" "$_runtime_uid_tmp" \
    && chown "$DNSCRYPT_UID:0" "$_runtime_uid_tmp" 2>/dev/null \
    && chmod 0400 "$_runtime_uid_tmp" 2>/dev/null \
    && mv -f "$_runtime_uid_tmp" "$_runtime_uid_target"; then
    return 0
  fi
  rm -f "$_runtime_uid_tmp"
  return 1
}

ensure_runtime_tree() {
  runtime_path_is_safe || return 1
  if [ "$RUNTIME_ROOT" = "$MODDIR" ]; then
    runtime_tree_is_trusted
    return $?
  fi
  runtime_parent_is_trusted || return 1
  acquire_runtime_tree_lock || return $?
  _runtime_ensure_status=1
  _runtime_operation=$(runtime_operation_state 2>/dev/null) || {
    exec 6>&-
    return 1
  }
  case "$_runtime_operation" in
    create)
      recover_runtime_create_locked || {
        exec 6>&-
        return 1
      }
      ;;
    remove)
      exec 6>&-
      return 1
      ;;
    none)
      if [ -e "$RUNTIME_CREATE_PATH" ] || [ -L "$RUNTIME_CREATE_PATH" ] \
        || [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ]; then
        exec 6>&-
        return 1
      fi
      ;;
  esac
  if [ -e "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ]; then
    if runtime_tree_is_trusted; then
      _runtime_ensure_status=0
    fi
    exec 6>&-
    return "$_runtime_ensure_status"
  fi

  # A shutdown marker must make the absence of the runtime tree terminal for
  # this invocation. The same lock is shared with removal, and shutdown is
  # sampled again immediately before the atomic publish below.
  shutdown_requested && {
    exec 6>&-
    return 1
  }
  module_runtime_templates_are_trusted || {
    exec 6>&-
    return 1
  }
  if ! config_root_open_paths_are_safe "$MODULE_CONFIG_DIR/dnscrypt-proxy.toml" \
    || ! config_runtime_user_is_safe "$MODULE_CONFIG_DIR/dnscrypt-proxy.toml"; then
    exec 6>&-
    return 1
  fi
  write_runtime_operation create || {
    exec 6>&-
    return 1
  }

  _runtime_stage="$RUNTIME_CREATE_PATH"
  _runtime_stage_bin="$_runtime_stage/bin"
  _runtime_stage_config="$_runtime_stage/config"
  _runtime_stage_active="$_runtime_stage/active"
  _runtime_stage_data="$_runtime_stage/data"
  _runtime_stage_binary="$_runtime_stage_bin/dnscrypt-proxy"
  if ! mkdir "$_runtime_stage" \
    || ! chown 0:0 "$_runtime_stage" 2>/dev/null \
    || ! chmod 0700 "$_runtime_stage" 2>/dev/null \
    || ! mkdir "$_runtime_stage_bin" "$_runtime_stage_config" "$_runtime_stage_active" \
      "$_runtime_stage_data" \
    || ! chown 0:0 "$_runtime_stage_bin" "$_runtime_stage_config" \
      "$_runtime_stage_active" 2>/dev/null \
    || ! chown "$DNSCRYPT_UID:0" "$_runtime_stage_data" 2>/dev/null \
    || ! chmod 0755 "$_runtime_stage_bin" \
    || ! chmod 0700 "$_runtime_stage_config" \
    || ! chmod 0700 "$_runtime_stage_active" \
    || ! chmod 0700 "$_runtime_stage_data"; then
    if cleanup_runtime_create_path >/dev/null 2>&1; then
      clear_runtime_operation >/dev/null 2>&1 || true
    fi
    exec 6>&-
    return 1
  fi

  for _runtime_template_name in \
    dnscrypt-proxy.toml allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt
  do
    if ! copy_runtime_template \
        "$MODULE_CONFIG_DIR/$_runtime_template_name" \
        "$_runtime_stage_config/$_runtime_template_name" 0600 0:0; then
      if cleanup_runtime_create_path >/dev/null 2>&1; then
        clear_runtime_operation >/dev/null 2>&1 || true
      fi
      exec 6>&-
      return 1
    fi
    if [ "$_runtime_template_name" = dnscrypt-proxy.toml ]; then
      _runtime_active_copy_ok=0
      copy_runtime_config_for_uid \
        "$MODULE_CONFIG_DIR/$_runtime_template_name" \
        "$_runtime_stage_active/$_runtime_template_name" \
        && _runtime_active_copy_ok=1
    else
      _runtime_active_copy_ok=0
      copy_runtime_template \
        "$MODULE_CONFIG_DIR/$_runtime_template_name" \
        "$_runtime_stage_active/$_runtime_template_name" 0400 "$DNSCRYPT_UID:0" \
        && _runtime_active_copy_ok=1
    fi
    if [ "$_runtime_active_copy_ok" -ne 1 ]; then
      if cleanup_runtime_create_path >/dev/null 2>&1; then
        clear_runtime_operation >/dev/null 2>&1 || true
      fi
      exec 6>&-
      return 1
    fi
  done
  _runtime_template_subscriptions="$MODULE_CONFIG_DIR/subscriptions.json"
  if [ -f "$_runtime_template_subscriptions" ] && [ ! -L "$_runtime_template_subscriptions" ]; then
    if ! copy_runtime_template \
        "$_runtime_template_subscriptions" "$_runtime_stage_config/subscriptions.json" \
        0600 0:0; then
      if cleanup_runtime_create_path >/dev/null 2>&1; then
        clear_runtime_operation >/dev/null 2>&1 || true
      fi
      exec 6>&-
      return 1
    fi
  fi
  if [ -f "$MODULE_BIN_DIR/dnscrypt-proxy" ] && [ ! -L "$MODULE_BIN_DIR/dnscrypt-proxy" ]; then
    if ! copy_runtime_template \
        "$MODULE_BIN_DIR/dnscrypt-proxy" "$_runtime_stage_binary" 0755 0:0; then
      if cleanup_runtime_create_path >/dev/null 2>&1; then
        clear_runtime_operation >/dev/null 2>&1 || true
      fi
      exec 6>&-
      return 1
    fi
  fi
  if ! chown "$DNSCRYPT_UID:0" "$_runtime_stage_active" 2>/dev/null \
    || ! chmod 0500 "$_runtime_stage_active" \
    || ! : > "$_runtime_stage/.daemon-pid" \
    || ! chown "$DNSCRYPT_UID:0" "$_runtime_stage/.daemon-pid" 2>/dev/null \
    || ! chmod 0600 "$_runtime_stage/.daemon-pid" 2>/dev/null \
    || ! printf '%s\n' 'dnscrypt-proxy-root:5' > "$_runtime_stage/.layout-owner" \
    || ! chown 0:0 "$_runtime_stage/.layout-owner" 2>/dev/null \
    || ! chmod 0600 "$_runtime_stage/.layout-owner" 2>/dev/null \
    || ! chmod 0755 "$_runtime_stage" \
    || ! runtime_tree_at_is_trusted "$_runtime_stage" \
    || shutdown_requested \
    || [ -e "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ] \
    || ! mv "$_runtime_stage" "$RUNTIME_ROOT" \
    || ! runtime_tree_is_trusted \
    || ! clear_runtime_operation; then
    if [ ! -e "$RUNTIME_ROOT" ] && [ ! -L "$RUNTIME_ROOT" ]; then
      if cleanup_runtime_create_path >/dev/null 2>&1; then
        clear_runtime_operation >/dev/null 2>&1 || true
      fi
    fi
    exec 6>&-
    return 1
  fi
  exec 6>&-
  return 0
}

runtime_active_stage_is_owned() {
  [ -d "$RUNTIME_ACTIVE_STAGE" ] && [ ! -L "$RUNTIME_ACTIVE_STAGE" ] || return 1
  case "$(stat -c '%u:%g' "$RUNTIME_ACTIVE_STAGE" 2>/dev/null)" in
    0:0|"$DNSCRYPT_UID:0") return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_runtime_active_stage() {
  if [ ! -e "$RUNTIME_ACTIVE_STAGE" ] && [ ! -L "$RUNTIME_ACTIVE_STAGE" ]; then
    return 0
  fi
  runtime_active_stage_is_owned || return 1
  rm -rf "$RUNTIME_ACTIVE_STAGE" \
    && [ ! -e "$RUNTIME_ACTIVE_STAGE" ] && [ ! -L "$RUNTIME_ACTIVE_STAGE" ]
}

# Publish a disposable daemon-readable snapshot from the root-only canonical
# configuration. Callers must already hold the control lock and must ensure the
# managed daemon is stopped. The runtime-tree lock serializes this reserved
# path with uninstall/removal and makes an interrupted publish recoverable.
publish_runtime_active_snapshot() {
  ensure_runtime_tree || return $?
  if [ "$RUNTIME_ROOT" = "$MODDIR" ]; then
    runtime_config_inputs_are_trusted
    return $?
  fi
  runtime_config_inputs_are_trusted || return 1
  config_root_open_paths_are_safe "$CONFIG_FILE" \
    && config_runtime_user_is_safe "$CONFIG_FILE" || return 1
  is_dnscrypt_running && return 1
  acquire_runtime_tree_lock || return $?
  _runtime_active_status=1
  if ! runtime_tree_is_trusted \
    || [ "$(runtime_operation_state 2>/dev/null)" != none ] \
    || [ -e "$RUNTIME_CREATE_PATH" ] || [ -L "$RUNTIME_CREATE_PATH" ] \
    || [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ] \
    || is_dnscrypt_running \
    || ! cleanup_runtime_active_stage \
    || ! mkdir "$RUNTIME_ACTIVE_STAGE" \
    || ! chown 0:0 "$RUNTIME_ACTIVE_STAGE" 2>/dev/null \
    || ! chmod 0700 "$RUNTIME_ACTIVE_STAGE"; then
    cleanup_runtime_active_stage >/dev/null 2>&1 || true
    exec 6>&-
    return 1
  fi
  for _runtime_active_name in \
    dnscrypt-proxy.toml allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt
  do
    if [ "$_runtime_active_name" = dnscrypt-proxy.toml ]; then
      _runtime_active_publish_ok=0
      copy_runtime_config_for_uid \
        "$CONFIG_DIR/$_runtime_active_name" \
        "$RUNTIME_ACTIVE_STAGE/$_runtime_active_name" \
        && _runtime_active_publish_ok=1
    else
      _runtime_active_publish_ok=0
      copy_runtime_template \
        "$CONFIG_DIR/$_runtime_active_name" \
        "$RUNTIME_ACTIVE_STAGE/$_runtime_active_name" 0400 "$DNSCRYPT_UID:0" \
        && _runtime_active_publish_ok=1
    fi
    if [ "$_runtime_active_publish_ok" -ne 1 ]; then
      cleanup_runtime_active_stage >/dev/null 2>&1 || true
      exec 6>&-
      return 1
    fi
  done
  if ! chown "$DNSCRYPT_UID:0" "$RUNTIME_ACTIVE_STAGE" 2>/dev/null \
    || ! chmod 0500 "$RUNTIME_ACTIVE_STAGE" \
    || ! runtime_active_snapshot_at_is_trusted "$RUNTIME_ACTIVE_STAGE" \
    || shutdown_requested \
    || is_dnscrypt_running; then
    cleanup_runtime_active_stage >/dev/null 2>&1 || true
    exec 6>&-
    return 1
  fi
  if [ -e "$RUNTIME_ACTIVE_DIR" ] || [ -L "$RUNTIME_ACTIVE_DIR" ]; then
    if [ ! -d "$RUNTIME_ACTIVE_DIR" ] || [ -L "$RUNTIME_ACTIVE_DIR" ] \
      || ! rm -rf "$RUNTIME_ACTIVE_DIR"; then
      cleanup_runtime_active_stage >/dev/null 2>&1 || true
      exec 6>&-
      return 1
    fi
  fi
  if mv "$RUNTIME_ACTIVE_STAGE" "$RUNTIME_ACTIVE_DIR" \
    && runtime_active_snapshot_at_is_trusted "$RUNTIME_ACTIVE_DIR"; then
    _runtime_active_status=0
  else
    cleanup_runtime_active_stage >/dev/null 2>&1 || true
  fi
  exec 6>&-
  return "$_runtime_active_status"
}

remove_runtime_tree() {
  runtime_path_is_safe || return 1
  [ "$RUNTIME_ROOT" != "$MODDIR" ] || return 0
  acquire_runtime_tree_lock || return $?
  _runtime_operation=$(runtime_operation_state 2>/dev/null) || {
    exec 6>&-
    return 1
  }
  if [ "$_runtime_operation" = create ]; then
    recover_runtime_create_locked || {
      exec 6>&-
      return 1
    }
    _runtime_operation=none
  fi
  if [ "$_runtime_operation" = none ]; then
    if [ -e "$RUNTIME_CREATE_PATH" ] || [ -L "$RUNTIME_CREATE_PATH" ] \
      || [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ]; then
      exec 6>&-
      return 1
    fi
    if [ ! -e "$RUNTIME_ROOT" ] && [ ! -L "$RUNTIME_ROOT" ]; then
      exec 6>&-
      return 0
    fi
    runtime_tree_is_trusted || {
      exec 6>&-
      return 1
    }
    write_runtime_operation remove || {
      exec 6>&-
      return 1
    }
  fi

  if [ -e "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ]; then
    if [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ] \
      || ! runtime_tree_is_trusted \
      || ! mv "$RUNTIME_ROOT" "$RUNTIME_REMOVE_PATH"; then
      exec 6>&-
      return 1
    fi
  fi
  if [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ]; then
    runtime_owned_aux_path_is_safe "$RUNTIME_REMOVE_PATH" || {
      exec 6>&-
      return 1
    }
    if ! rm -rf "$RUNTIME_REMOVE_PATH" \
      || [ -e "$RUNTIME_REMOVE_PATH" ] || [ -L "$RUNTIME_REMOVE_PATH" ]; then
      exec 6>&-
      return 1
    fi
  fi
  if [ -e "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ] \
    || ! clear_runtime_operation; then
    exec 6>&-
    return 1
  fi
  exec 6>&-
  return 0
}

# The module template and persistent canonical configuration remain root-only.
# A disposable active snapshot is separately published for UID3003 immediately
# before a controlled start, so daemon compromise cannot rewrite the root
# control plane or race a later privileged configuration read.
config_control_uid() {
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || return 1
  _config_control_uid=$(stat -c %u "$STATE_DIR" 2>/dev/null) || return 1
  case "$_config_control_uid" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_config_control_uid"
}

config_dir_expected_identity() {
  _config_expected_control_uid=$(config_control_uid) || return 1
  printf '%s:0:700\n' "$_config_expected_control_uid"
}

managed_config_expected_identity() {
  _config_expected_control_uid=$(config_control_uid) || return 1
  printf '%s:0:600\n' "$_config_expected_control_uid"
}

managed_config_mode() {
  printf '%s\n' 600
}

config_dir_is_trusted() {
  [ -d "$CONFIG_DIR" ] && [ ! -L "$CONFIG_DIR" ] || return 1
  _trusted_config_identity=$(config_dir_expected_identity) || return 1
  [ "$(stat -c '%u:%g:%a' "$CONFIG_DIR" 2>/dev/null)" = "$_trusted_config_identity" ]
}

managed_config_input_is_trusted() {
  _trusted_config_input="$1"
  config_dir_is_trusted || return 1
  [ -f "$_trusted_config_input" ] && [ ! -L "$_trusted_config_input" ] || return 1
  _trusted_config_identity=$(managed_config_expected_identity) || return 1
  [ "$(stat -c '%u:%g:%a' "$_trusted_config_input" 2>/dev/null)" = \
    "$_trusted_config_identity" ]
}

control_only_config_input_is_trusted() {
  _trusted_control_input="$1"
  config_dir_is_trusted || return 1
  [ -f "$_trusted_control_input" ] && [ ! -L "$_trusted_control_input" ] || return 1
  _trusted_control_uid=$(config_control_uid) || return 1
  [ "$(stat -c '%u:%g:%a' "$_trusted_control_input" 2>/dev/null)" = \
    "$_trusted_control_uid:0:600" ]
}

config_file_is_trusted() {
  managed_config_input_is_trusted "$CONFIG_FILE"
}

runtime_config_inputs_are_trusted() {
  config_file_is_trusted || return 1
  for _trusted_config_name in \
    allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt
  do
    managed_config_input_is_trusted "$CONFIG_DIR/$_trusted_config_name" || return 1
  done
  _trusted_subscriptions="$CONFIG_DIR/subscriptions.json"
  if [ -e "$_trusted_subscriptions" ] || [ -L "$_trusted_subscriptions" ]; then
    control_only_config_input_is_trusted "$_trusted_subscriptions" || return 1
  fi
}

# The daemon and configuration checks are launched only after switching to
# UID/GID 3003, and the root-only canonical TOML is copied to a disposable
# execution snapshot.  Keep all file-opening features constrained nevertheless:
# the main log stays on inherited stderr (service.log), while TLS key logging and
# DoH client X.509 authentication remain unsupported in v0.9.1. Ambiguous TOML
# is rejected byte-identically before an execution snapshot is published.
config_root_open_paths_are_safe() {
  _root_path_config="$1"
  [ -f "$_root_path_config" ] && [ ! -L "$_root_path_config" ] || return 1
  awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function code_without_comment(s,    i,c,out,in_sq,in_dq,esc) {
      out=""; in_sq=0; in_dq=0; esc=0
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (in_dq) {
          out=out c
          if (esc) esc=0
          else if (c=="\\") esc=1
          else if (c==dq) in_dq=0
          continue
        }
        if (in_sq) { out=out c; if (c==sq) in_sq=0; continue }
        if (c=="#") break
        out=out c
        if (c==dq) in_dq=1
        else if (c==sq) in_sq=1
      }
      if (in_sq || in_dq) bad=1
      return out
    }
    BEGIN { sq=sprintf("%c",39); dq=sprintf("%c",34); root=1; bad=0; log_count=0 }
    {
      raw=$0
      if (index(raw,"\"\"\"") || index(raw,sq sq sq)) bad=1
      code=code_without_comment(raw); t=trim(code)
      if (t=="") next
      if (substr(t,1,1)=="[") {
        root=0
        if (index(t,"\\") || index(t,"doh_client_x509_auth") \
            || index(t,"tls_client_auth")) bad=1
        next
      }
      if (!root || index(code,"=")==0) next
      lhs=code; sub(/=.*/,"",lhs); lhs=trim(lhs)
      if (lhs !~ /^[A-Za-z0-9_-]+$/) { bad=1; next }
      rhs=code; sub(/^[^=]*=/,"",rhs); rhs=trim(rhs)
      if (lhs=="tls_key_log_file" || lhs=="doh_client_x509_auth" \
          || lhs=="tls_client_auth") bad=1
      if (lhs=="log_file") {
        log_count++
        bad=1
      }
    }
    END { if (log_count>1) bad=1; exit bad ? 42 : 0 }
  ' "$_root_path_config" >/dev/null
}

config_runtime_user_is_safe() {
  _runtime_user_config="$1"
  [ -f "$_runtime_user_config" ] && [ ! -L "$_runtime_user_config" ] || return 1
  awk -v wanted="$DNSCRYPT_UID" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function code_without_comment(s,    i,c,out,in_sq,in_dq,esc) {
      out=""; in_sq=0; in_dq=0; esc=0
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (in_dq) {
          out=out c
          if (esc) esc=0
          else if (c=="\\") esc=1
          else if (c==dq) in_dq=0
          continue
        }
        if (in_sq) { out=out c; if (c==sq) in_sq=0; continue }
        if (c=="#") break
        out=out c
        if (c==dq) in_dq=1
        else if (c==sq) in_sq=1
      }
      if (in_sq || in_dq) bad=1
      return out
    }
    BEGIN { count=0; bad=0; root=1; sq=sprintf("%c",39); dq=sprintf("%c",34) }
    {
      raw=$0
      if (index(raw,"\"\"\"") || index(raw,sq sq sq)) bad=1
      code=code_without_comment(raw); t=trim(code)
      if (t=="") next
      if (substr(t,1,1)=="[") { root=0; next }
      if (!root || index(code,"=")==0) next
      lhs=code; sub(/=.*/,"",lhs); lhs=trim(lhs)
      if (lhs!="user_name") next
      count++
      rhs=code; sub(/^[^=]*=/,"",rhs); rhs=trim(rhs)
      if (rhs != sq wanted sq && rhs != dq wanted dq) bad=1
    }
    END { exit (count == 1 && !bad) ? 0 : 42 }
  ' "$_runtime_user_config" >/dev/null
}

config_check_snapshot_is_owned() {
  _check_snapshot_dir="$1"
  case "$_check_snapshot_dir" in "$RUNTIME_ROOT/.config-check.$$" ) ;; *) return 1 ;; esac
  [ -d "$_check_snapshot_dir" ] && [ ! -L "$_check_snapshot_dir" ] || return 1
  case "$(stat -c '%u:%g' "$_check_snapshot_dir" 2>/dev/null)" in
    0:0|"$DNSCRYPT_UID:0") return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_config_check_snapshot() {
  _check_snapshot_dir="$1"
  if [ ! -e "$_check_snapshot_dir" ] && [ ! -L "$_check_snapshot_dir" ]; then
    return 0
  fi
  config_check_snapshot_is_owned "$_check_snapshot_dir" || return 1
  # The disposable directory is intentionally 0500 while UID3003 consumes it.
  # Restore owner write permission only after the exact-path/owner check so a
  # non-root test runner can exercise the same cleanup that production root can.
  chmod 0700 "$_check_snapshot_dir" 2>/dev/null || return 1
  rm -rf "$_check_snapshot_dir" \
    && [ ! -e "$_check_snapshot_dir" ] && [ ! -L "$_check_snapshot_dir" ]
}

# Build a daemon-owned, owner-readable copy for an unprivileged `-check`. The required
# user_name is removed only from this disposable copy: the check process already
# starts as UID3003, so upstream must not attempt a second privilege transition.
prepare_config_check_snapshot() {
  _check_source_config="$1"
  _check_snapshot_dir="$2"
  _check_snapshot_config="$_check_snapshot_dir/dnscrypt-proxy.toml"
  _check_snapshot_pid="$_check_snapshot_dir/.pid"
  runtime_config_inputs_are_trusted || return 1
  runtime_config_path_is_safe "$_check_source_config" || return 1
  [ -f "$_check_source_config" ] && [ ! -L "$_check_source_config" ] || return 1
  _check_source_identity=$(managed_config_expected_identity) || return 1
  [ "$(stat -c '%u:%g:%a' "$_check_source_config" 2>/dev/null)" = \
    "$_check_source_identity" ] || return 1
  config_root_open_paths_are_safe "$_check_source_config" || return 1
  config_runtime_user_is_safe "$_check_source_config" || return 1
  cleanup_config_check_snapshot "$_check_snapshot_dir" || return 1
  if ! mkdir "$_check_snapshot_dir" \
    || ! chown 0:0 "$_check_snapshot_dir" 2>/dev/null \
    || ! chmod 0700 "$_check_snapshot_dir"; then
    cleanup_config_check_snapshot "$_check_snapshot_dir" >/dev/null 2>&1 || true
    return 1
  fi
  if ! write_config_without_runtime_user \
      "$_check_source_config" "$_check_snapshot_config"; then
    cleanup_config_check_snapshot "$_check_snapshot_dir" >/dev/null 2>&1 || true
    return 1
  fi
  for _check_snapshot_name in allowed-names.txt blocked-names.txt allowed-ips.txt blocked-ips.txt
  do
    cp "$CONFIG_DIR/$_check_snapshot_name" \
      "$_check_snapshot_dir/$_check_snapshot_name" || {
        cleanup_config_check_snapshot "$_check_snapshot_dir" >/dev/null 2>&1 || true
        return 1
      }
  done
  : > "$_check_snapshot_pid" || {
    cleanup_config_check_snapshot "$_check_snapshot_dir" >/dev/null 2>&1 || true
    return 1
  }
  if ! chown "$DNSCRYPT_UID:0" "$_check_snapshot_dir" \
      "$_check_snapshot_config" \
      "$_check_snapshot_dir/allowed-names.txt" "$_check_snapshot_dir/blocked-names.txt" \
      "$_check_snapshot_dir/allowed-ips.txt" "$_check_snapshot_dir/blocked-ips.txt" 2>/dev/null \
    || ! chown "$DNSCRYPT_UID:0" "$_check_snapshot_pid" 2>/dev/null \
    || ! chmod 0500 "$_check_snapshot_dir" \
    || ! chmod 0400 "$_check_snapshot_config" \
      "$_check_snapshot_dir/allowed-names.txt" "$_check_snapshot_dir/blocked-names.txt" \
      "$_check_snapshot_dir/allowed-ips.txt" "$_check_snapshot_dir/blocked-ips.txt" \
    || ! chmod 0600 "$_check_snapshot_pid"; then
    cleanup_config_check_snapshot "$_check_snapshot_dir" >/dev/null 2>&1 || true
    return 1
  fi
  runtime_active_snapshot_at_is_trusted "$_check_snapshot_dir" \
    && [ "$(stat -c '%u:%g:%a' "$_check_snapshot_pid" 2>/dev/null)" = \
      "$DNSCRYPT_UID:0:600" ]
}

files_equal_exact() {
  _exact_left="$1"
  _exact_right="$2"
  if has_cmd cmp; then
    cmp -s "$_exact_left" "$_exact_right"
    return $?
  fi
  busybox_cmd cmp -s "$_exact_left" "$_exact_right"
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

config_check_signal() {
  if [ -n "${DNSCRYPT_CONFIG_CHECK_KILL_COMMAND:-}" ]; then
    "$DNSCRYPT_CONFIG_CHECK_KILL_COMMAND" "$@"
  else
    kill "$@"
  fi
}

is_dnscrypt_config_check_pid() {
  _check_candidate_pid="$1"
  _check_candidate_config="$2"
  _check_candidate_binary="${3:-$RUNTIME_BIN}"
  case "$_check_candidate_pid" in ""|*[!0-9]*) return 1 ;; esac
  _check_candidate_cmdline="$PROC_ROOT/$_check_candidate_pid/cmdline"
  [ -r "$_check_candidate_cmdline" ] || return 1
  config_check_signal -0 "$_check_candidate_pid" >/dev/null 2>&1 || return 1
  _check_expected="$RUN_DIR/.dnscrypt-check-cmdline.$$.${_check_candidate_pid}.expected"
  rm -f "$_check_expected"
  if ! printf '%s\0%s\0%s\0%s\0' \
      "$_check_candidate_binary" '-check' '-config' "$_check_candidate_config" \
      > "$_check_expected"; then
    rm -f "$_check_expected"
    return 1
  fi
  if files_equal_exact "$_check_expected" "$_check_candidate_cmdline"; then
    _check_candidate_match=0
  else
    printf '%s\0%s\0%s\0%s\0%s\0' \
      "$_check_candidate_binary" '-check' '-config' "$_check_candidate_config" '-child' \
      > "$_check_expected" || {
        rm -f "$_check_expected"
        return 1
      }
    if files_equal_exact "$_check_expected" "$_check_candidate_cmdline"; then
      _check_candidate_match=0
    else
      _check_candidate_match=1
    fi
  fi
  rm -f "$_check_expected"
  [ "$_check_candidate_match" -eq 0 ] || return 1
  [ "$(dnscrypt_process_uid "$_check_candidate_pid" 2>/dev/null)" = "$DNSCRYPT_UID" ] \
    || return 1
  config_check_signal -0 "$_check_candidate_pid" >/dev/null 2>&1
}

terminate_dnscrypt_config_check() {
  _check_stop_pid="$1"
  _check_stop_config="$2"
  _check_stop_binary="${3:-$RUNTIME_BIN}"
  _check_was_owned=0
  if is_dnscrypt_config_check_pid "$_check_stop_pid" "$_check_stop_config" "$_check_stop_binary"; then
    _check_was_owned=1
    config_check_signal -TERM "$_check_stop_pid" >/dev/null 2>&1 || true
  fi
  sleep 1
  # Revalidate the complete parent/child argv immediately before SIGKILL. A
  # check can exit on TERM and its PID can be reused during the grace second.
  if is_dnscrypt_config_check_pid "$_check_stop_pid" "$_check_stop_config" "$_check_stop_binary"; then
    _check_was_owned=1
    config_check_signal -KILL "$_check_stop_pid" >/dev/null 2>&1 || true
  fi
  [ "$_check_was_owned" -eq 0 ] || wait "$_check_stop_pid" >/dev/null 2>&1 || true
}

run_bounded_config_check() {
  _bounded_check_config="$1"
  _bounded_check_log="$2"
  _bounded_check_binary="${3:-$DNSCRYPT_BIN}"
  _bounded_check_limit=${DNSCRYPT_CONFIG_CHECK_TIMEOUT_SECONDS:-${DNSCRYPT_SOURCE_PREFLIGHT_TIMEOUT_SECONDS:-660}}
  case "$_bounded_check_limit" in
    ""|*[!0-9]*|0) _bounded_check_limit=660 ;;
  esac
  [ "$_bounded_check_limit" -le 660 ] || _bounded_check_limit=660
  ensure_runtime_tree || return 126
  runtime_config_path_is_safe "$_bounded_check_config" || return 126
  runtime_binary_path_is_safe "$_bounded_check_binary" || return 126
  [ -f "$_bounded_check_config" ] && [ ! -L "$_bounded_check_config" ] || return 126
  config_root_open_paths_are_safe "$_bounded_check_config" || return 126
  config_runtime_user_is_safe "$_bounded_check_config" || return 126
  [ -f "$_bounded_check_binary" ] && [ ! -L "$_bounded_check_binary" ] \
    && [ -x "$_bounded_check_binary" ] || return 126
  _bounded_control_uid=$(config_control_uid) || return 126
  _bounded_config_identity=$(managed_config_expected_identity) || return 126
  [ "$(stat -c '%u:%g:%a' "$_bounded_check_config" 2>/dev/null)" = \
    "$_bounded_config_identity" ] || return 126
  [ "$(stat -c %u "$_bounded_check_binary" 2>/dev/null)" = "$_bounded_control_uid" ] \
    && [ "$(stat -c %a "$_bounded_check_binary" 2>/dev/null)" = "755" ] \
    || return 126
  has_cmd su || return 126
  _bounded_snapshot_dir="$RUNTIME_ROOT/.config-check.$$"
  prepare_config_check_snapshot "$_bounded_check_config" "$_bounded_snapshot_dir" \
    || return 126
  _bounded_runtime_config="$_bounded_snapshot_dir/dnscrypt-proxy.toml"
  _bounded_pid_file="$_bounded_snapshot_dir/.pid"
  _bounded_runtime_binary=$_bounded_check_binary
  _bounded_su_command="printf '%s\\n' \"\$\$\" > '$_bounded_pid_file'; exec '$_bounded_runtime_binary' -check -config '$_bounded_runtime_config'"
  su "$DNSCRYPT_UID" -c "$_bounded_su_command" 6>&- 8>&- 9>&- \
    >> "$_bounded_check_log" 2>&1 &
  _bounded_su_pid=$!
  _bounded_check_pid=
  _bounded_check_elapsed=0
  _bounded_start_wait=0
  while config_check_signal -0 "$_bounded_su_pid" >/dev/null 2>&1; do
    _bounded_pid_value=$(sed -n '1p' "$_bounded_pid_file" 2>/dev/null || true)
    case "$_bounded_pid_value" in
      ""|*[!0-9]*) ;;
      *)
        if is_dnscrypt_config_check_pid \
            "$_bounded_pid_value" "$_bounded_runtime_config" "$_bounded_runtime_binary"; then
          _bounded_check_pid=$_bounded_pid_value
          break
        fi
        ;;
    esac
    [ "$_bounded_start_wait" -lt 5 ] || break
    sleep 1
    _bounded_start_wait=$((_bounded_start_wait + 1))
    _bounded_check_elapsed=$((_bounded_check_elapsed + 1))
  done
  if config_check_signal -0 "$_bounded_su_pid" >/dev/null 2>&1 \
    && [ -z "$_bounded_check_pid" ]; then
    config_check_signal -TERM "$_bounded_su_pid" >/dev/null 2>&1 || true
    wait "$_bounded_su_pid" >/dev/null 2>&1 || true
    cleanup_config_check_snapshot "$_bounded_snapshot_dir" >/dev/null 2>&1 || true
    return 126
  fi
  while config_check_signal -0 "$_bounded_su_pid" >/dev/null 2>&1; do
    if shutdown_requested; then
      if [ -n "$_bounded_check_pid" ]; then
        terminate_dnscrypt_config_check \
          "$_bounded_check_pid" "$_bounded_runtime_config" "$_bounded_runtime_binary"
      else
        config_check_signal -TERM "$_bounded_su_pid" >/dev/null 2>&1 || true
      fi
      wait "$_bounded_su_pid" >/dev/null 2>&1 || true
      cleanup_config_check_snapshot "$_bounded_snapshot_dir" >/dev/null 2>&1 || true
      return 125
    fi
    if [ "$_bounded_check_elapsed" -ge "$_bounded_check_limit" ]; then
      if [ -n "$_bounded_check_pid" ]; then
        terminate_dnscrypt_config_check \
          "$_bounded_check_pid" "$_bounded_runtime_config" "$_bounded_runtime_binary"
      else
        config_check_signal -TERM "$_bounded_su_pid" >/dev/null 2>&1 || true
      fi
      wait "$_bounded_su_pid" >/dev/null 2>&1 || true
      cleanup_config_check_snapshot "$_bounded_snapshot_dir" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    _bounded_check_elapsed=$((_bounded_check_elapsed + 1))
  done
  wait "$_bounded_su_pid"
  _bounded_check_status=$?
  if ! cleanup_config_check_snapshot "$_bounded_snapshot_dir"; then
    return 126
  fi
  return "$_bounded_check_status"
}

# The integration policy is intentionally kept outside dnscrypt-proxy.toml and
# inside the root-only state directory. An absent file preserves the historical
# strict policy. Any existing malformed, non-regular, or symlinked file fails
# closed instead of silently enabling a policy the user did not select.
dns_mode_state_valid() {
  _dns_mode_file="$1"
  [ -f "$_dns_mode_file" ] && [ ! -L "$_dns_mode_file" ] || return 1
  _dns_mode_lines=$(wc -l < "$_dns_mode_file" 2>/dev/null | tr -d ' ')
  [ "$_dns_mode_lines" = "1" ] || return 1
  _dns_mode_bytes=$(wc -c < "$_dns_mode_file" 2>/dev/null | tr -d ' ')
  _dns_mode_value=$(sed -n '1p' "$_dns_mode_file" 2>/dev/null)
  case "$_dns_mode_value:$_dns_mode_bytes" in
    strict:7|upstream_only:14) return 0 ;;
    *) return 1 ;;
  esac
}

get_dns_mode() {
  if [ ! -e "$DNS_MODE_STATE_FILE" ] && [ ! -L "$DNS_MODE_STATE_FILE" ]; then
    printf '%s\n' strict
    return 0
  fi
  dns_mode_state_valid "$DNS_MODE_STATE_FILE" || return 1
  sed -n '1p' "$DNS_MODE_STATE_FILE"
}

write_dns_mode() {
  _new_dns_mode="$1"
  case "$_new_dns_mode" in
    strict|upstream_only) ;;
    *) return 1 ;;
  esac
  mkdir -p "$STATE_DIR" || return 1
  _dns_mode_tmp="$DNS_MODE_STATE_FILE.$$.tmp"
  printf '%s\n' "$_new_dns_mode" > "$_dns_mode_tmp" || {
    rm -f "$_dns_mode_tmp"
    return 1
  }
  chmod 0600 "$_dns_mode_tmp" 2>/dev/null || {
    rm -f "$_dns_mode_tmp"
    return 1
  }
  chown 0:0 "$_dns_mode_tmp" 2>/dev/null || true
  mv -f "$_dns_mode_tmp" "$DNS_MODE_STATE_FILE" || {
    rm -f "$_dns_mode_tmp"
    return 1
  }
}

start_failure_reason_valid() {
  case "$1" in
    binary_unavailable|cleanup_failed|config_error|listener_timeout|mode_state_invalid|\
      policy_install_failed|process_exit|runtime_path_unavailable|shutdown_cancelled|\
      source_cache_unavailable|state_record_failed)
      return 0
      ;;
    *) return 1 ;;
  esac
}

write_start_failure() {
  _start_failure_reason="$1"
  start_failure_reason_valid "$_start_failure_reason" || return 1
  _start_failure_tmp="$START_FAILURE_STATE_FILE.$$.tmp"
  printf '%s\n' "$_start_failure_reason" > "$_start_failure_tmp" || {
    rm -f "$_start_failure_tmp"
    return 1
  }
  chmod 0600 "$_start_failure_tmp" 2>/dev/null || {
    rm -f "$_start_failure_tmp"
    return 1
  }
  mv -f "$_start_failure_tmp" "$START_FAILURE_STATE_FILE" || {
    rm -f "$_start_failure_tmp"
    return 1
  }
}

get_start_failure() {
  if [ ! -e "$START_FAILURE_STATE_FILE" ] && [ ! -L "$START_FAILURE_STATE_FILE" ]; then
    printf '%s\n' none
    return 0
  fi
  [ -f "$START_FAILURE_STATE_FILE" ] && [ ! -L "$START_FAILURE_STATE_FILE" ] || return 1
  [ "$(wc -l < "$START_FAILURE_STATE_FILE" 2>/dev/null | tr -d ' ')" = "1" ] || return 1
  _stored_start_failure=$(sed -n '1p' "$START_FAILURE_STATE_FILE" 2>/dev/null)
  start_failure_reason_valid "$_stored_start_failure" || return 1
  _stored_start_failure_bytes=$(wc -c < "$START_FAILURE_STATE_FILE" 2>/dev/null | tr -d ' ')
  [ "$_stored_start_failure_bytes" = "$((${#_stored_start_failure} + 1))" ] || return 1
  printf '%s\n' "$_stored_start_failure"
}

clear_start_failure() {
  rm -f "$START_FAILURE_STATE_FILE" "$START_FAILURE_STATE_FILE.$$.tmp"
}

dnscrypt_startup_grace_seconds() {
  _netprobe_timeout=$(awk '
    BEGIN { found=0 }
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*netprobe_timeout[[:space:]]*=/ {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      print line
      found=1
      exit
    }
    END { if (!found) print "__DNSCRYPT_NETPROBE_ABSENT__" }
  ' "$CONFIG_FILE" 2>/dev/null)
  # Match dnscrypt-proxy 2.1.18 NetProbe semantics: an absent value retains the
  # upstream 60-second default, an explicit zero skips the probe, negative
  # values wait up to MaxTimeout (3600 seconds), positive values are capped at
  # MaxTimeout, and TOML decimal separators are legal.
  # If this deliberately small lexer cannot recognize a value, choose the
  # upstream maximum instead of risking an early kill of a valid daemon.
  _netprobe_timeout=$(printf '%s\n' "$_netprobe_timeout" | awk '
    {
      value=$0
      if (value == "__DNSCRYPT_NETPROBE_ABSENT__") normalized=60
      else {
        gsub(/_/, "", value)
        if (value == "") normalized=3600
      else if (value ~ /^-[0-9]+$/) {
        if ((value + 0) < 0) normalized=3600
        else normalized=0
      } else if (value ~ /^\+?[0-9]+$/) {
        normalized=value + 0
        if (normalized > 3600) normalized=3600
      } else normalized=3600
      }
      printf "%.0f\n", normalized
      exit
    }
  ')
  # Source availability is preflighted separately before the daemon starts;
  # this extra window covers post-NetProbe cache parsing, privilege exec and
  # listener stabilization without truncating the upstream probe itself.
  printf '%s\n' "$((_netprobe_timeout + 30))"
}

mark_dnscrypt_starting() {
  _startup_pid="$1"
  case "$_startup_pid" in ""|*[!0-9]*) return 1 ;; esac
  _startup_now=$(date +%s 2>/dev/null || echo 0)
  case "$_startup_now" in ""|*[!0-9]*) return 1 ;; esac
  _startup_deadline=$((_startup_now + $(dnscrypt_startup_grace_seconds)))
  _startup_tmp="$STARTUP_STATE_FILE.$$.tmp"
  {
    printf 'pid=%s\n' "$_startup_pid"
    printf 'deadline=%s\n' "$_startup_deadline"
  } > "$_startup_tmp" || return 1
  chmod 0600 "$_startup_tmp" 2>/dev/null || true
  mv -f "$_startup_tmp" "$STARTUP_STATE_FILE" || {
    rm -f "$_startup_tmp"
    return 1
  }
}

dnscrypt_is_starting() {
  [ -f "$STARTUP_STATE_FILE" ] && [ ! -L "$STARTUP_STATE_FILE" ] || return 1
  [ "$(wc -l < "$STARTUP_STATE_FILE" 2>/dev/null | tr -d ' ')" = "2" ] || return 1
  _starting_pid=$(sed -n 's/^pid=//p' "$STARTUP_STATE_FILE" | head -n 1)
  _starting_deadline=$(sed -n 's/^deadline=//p' "$STARTUP_STATE_FILE" | head -n 1)
  case "$_starting_pid:$_starting_deadline" in
    *[!0-9:]*) return 1 ;;
  esac
  [ "$(grep -c '^pid=' "$STARTUP_STATE_FILE" 2>/dev/null || true)" = "1" ] || return 1
  [ "$(grep -c '^deadline=' "$STARTUP_STATE_FILE" 2>/dev/null || true)" = "1" ] || return 1
  is_dnscrypt_pid "$_starting_pid" || return 1
  _starting_now=$(date +%s 2>/dev/null || echo 0)
  case "$_starting_now" in ""|*[!0-9]*) return 1 ;; esac
  [ "$_starting_now" -le "$_starting_deadline" ]
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

strict_semver() {
  _strict_semver_value="$1"
  printf '%s\n' "$_strict_semver_value" \
    | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

binary_version_bounded() {
  _version_binary="$1"
  [ -f "$_version_binary" ] && [ ! -L "$_version_binary" ] \
    && [ -x "$_version_binary" ] || return 1
  [ -d "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] || return 1
  _version_output="$RUN_DIR/.dnscrypt-version.$$.tmp"
  [ ! -e "$_version_output" ] && [ ! -L "$_version_output" ] || return 1
  (umask 077; : > "$_version_output") || return 1
  chmod 0600 "$_version_output" 2>/dev/null || {
    rm -f "$_version_output"
    return 1
  }
  if has_cmd timeout; then
    timeout 5 "$_version_binary" -version 6>&- 8>&- 9>&- \
      > "$_version_output" 2>/dev/null
  else
    busybox_cmd timeout 5 "$_version_binary" -version 6>&- 8>&- 9>&- \
      > "$_version_output" 2>/dev/null
  fi
  _version_status=$?
  _version_size=$(wc -c < "$_version_output" 2>/dev/null | tr -d ' ')
  _version_line=$(sed -n '1{s/\r$//;p;q;}' "$_version_output" 2>/dev/null)
  _version_lines=$(wc -l < "$_version_output" 2>/dev/null | tr -d ' ')
  rm -f "$_version_output"
  [ "$_version_status" -eq 0 ] || return 1
  case "$_version_size:$_version_lines" in
    "":*|*[!0-9:]*|*:0) return 1 ;;
  esac
  [ "$_version_size" -le 64 ] && [ "$_version_lines" -eq 1 ] || return 1
  strict_semver "$_version_line" || return 1
  printf '%s\n' "$_version_line"
}

# Print -1, 0, or 1 when the first strict x.y.z version is older than, equal
# to, or newer than the second one.
compare_semver() {
  _compare_left="$1"
  _compare_right="$2"
  strict_semver "$_compare_left" && strict_semver "$_compare_right" || return 1
  awk -v left="$_compare_left" -v right="$_compare_right" '
    BEGIN {
      split(left, l, "."); split(right, r, ".")
      for (i=1; i<=3; i++) {
        if ((l[i] + 0) < (r[i] + 0)) { print -1; exit }
        if ((l[i] + 0) > (r[i] + 0)) { print 1; exit }
      }
      print 0
    }
  '
}

installed_version() {
  # The module-local marker is rollback bookkeeping only. On module upgrades it
  # can describe a freshly downloaded template while the persistent runtime
  # still contains an older executable, so the protected executable itself is
  # the sole version authority.
  if runtime_binary_at_is_trusted "$DNSCRYPT_BIN"; then
    _installed_binary_version=$(binary_version_bounded "$DNSCRYPT_BIN" 2>/dev/null) \
      && {
        printf '%s\n' "$_installed_binary_version"
        return 0
      }
  fi
  echo "none"
}

refresh_installed_version_marker() {
  _refresh_version=$(installed_version)
  if [ "$_refresh_version" = none ]; then
    rm -f "$INSTALLED_VERSION_FILE"
    return 1
  fi
  _refresh_tmp="$INSTALLED_VERSION_FILE.$$.tmp"
  [ ! -e "$_refresh_tmp" ] && [ ! -L "$_refresh_tmp" ] || return 1
  if (umask 077; printf '%s\n' "$_refresh_version" > "$_refresh_tmp") \
    && chmod 0600 "$_refresh_tmp" 2>/dev/null \
    && mv -f "$_refresh_tmp" "$INSTALLED_VERSION_FILE"; then
    return 0
  fi
  rm -f "$_refresh_tmp" "$INSTALLED_VERSION_FILE"
  return 1
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
  # Compare the complete NUL-delimited byte stream. Splitting argv on newlines
  # cannot distinguish a missing argument from an empty one and is unsafe for
  # arguments that themselves contain newlines.
  _candidate_expected="$RUN_DIR/.dnscrypt-cmdline.$$.${_candidate_pid}.expected"
  rm -f "$_candidate_expected"
  if ! printf '%s\0%s\0%s\0' "$RUNTIME_BIN" '-config' "$RUNTIME_CONFIG_FILE" \
      > "$_candidate_expected"; then
    rm -f "$_candidate_expected"
    return 1
  fi
  if files_equal_exact "$_candidate_expected" "$_candidate_cmdline"; then
    _candidate_match=0
  else
    printf '%s\0%s\0%s\0%s\0' "$RUNTIME_BIN" '-config' "$RUNTIME_CONFIG_FILE" '-child' \
      > "$_candidate_expected" || {
        rm -f "$_candidate_expected"
        return 1
      }
    if files_equal_exact "$_candidate_expected" "$_candidate_cmdline"; then
      _candidate_match=0
    else
      _candidate_match=1
    fi
  fi
  rm -f "$_candidate_expected"
  [ "$_candidate_match" -eq 0 ] || return 1
  # Revalidate liveness after reading cmdline so a process that exited during
  # comparison is not returned as the managed daemon.
  kill -0 "$_candidate_pid" >/dev/null 2>&1
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
      "$RUNTIME_BIN")
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

# Match a socket inode from /proc/net back to the exact daemon's file
# descriptors. This avoids accepting a foreign process that happens to bind the
# configured port. The socket table UID is deliberately not used: the daemon
# can open its listeners before dropping to the dedicated Android UID.
dnscrypt_pid_owns_socket_inode() {
  _socket_pid="$1"
  _socket_inode="$2"
  [ -n "$_socket_inode" ] || return 1
  for _socket_fd in "$PROC_ROOT/$_socket_pid"/fd/[0-9]*; do
    _socket_target=$(readlink "$_socket_fd" 2>/dev/null || true)
    [ "$_socket_target" = "socket:[$_socket_inode]" ] && return 0
  done
  return 1
}

dnscrypt_pid_owns_matching_socket() {
  _matching_pid="$1"
  _matching_table="$2"
  _matching_endpoint="$3"
  _matching_state="$4"
  _matching_inodes_file="$RUN_DIR/.socket-inodes.$$.${_matching_pid}.tmp"
  awk -v endpoint="$_matching_endpoint" -v state="$_matching_state" \
    '$2 == endpoint && $4 == state { print $10 }' "$_matching_table" \
    > "$_matching_inodes_file" 2>/dev/null || {
      rm -f "$_matching_inodes_file"
      return 1
    }
  _matching_found=1
  while IFS= read -r _matching_inode; do
    if dnscrypt_pid_owns_socket_inode "$_matching_pid" "$_matching_inode"; then
      _matching_found=0
      break
    fi
  done < "$_matching_inodes_file"
  rm -f "$_matching_inodes_file"
  return "$_matching_found"
}

dnscrypt_listener_ready() {
  _listener_pid="$1"
  is_dnscrypt_pid "$_listener_pid" || return 1
  [ -r "$PROC_ROOT/net/tcp" ] && [ -r "$PROC_ROOT/net/udp" ] || return 1
  dnscrypt_pid_owns_matching_socket "$_listener_pid" "$PROC_ROOT/net/tcp" 0100007F:14EA 0A \
    && dnscrypt_pid_owns_matching_socket "$_listener_pid" "$PROC_ROOT/net/udp" 0100007F:14EA 07
}

# Exercise the daemon's complete local DNS handler without consulting an
# upstream. dnscrypt-proxy 2.1.18 always synthesizes an NXDOMAIN response for
# the Firefox canary name over ordinary DNS. Comparing the complete framed
# response distinguishes a working local DNS path from a process that merely
# owns the TCP/UDP sockets, accepts and closes connections, or has a wedged
# handler loop.
dnscrypt_local_handler_ready() {
  _handler_pid="$1"
  dnscrypt_listener_ready "$_handler_pid" || return 1
  _handler_probe_output="$RUN_DIR/.local-handler-probe.$$.out"
  _handler_probe_expected="$RUN_DIR/.local-handler-probe.$$.expected"
  _handler_probe_status=127
  rm -f "$_handler_probe_output" "$_handler_probe_expected"
  (
    umask 077
    : > "$_handler_probe_output" \
      && printf '\000\051\104\120\201\203\000\001\000\000\000\000\000\000\023use-application-dns\003net\000\000\001\000\001' \
        > "$_handler_probe_expected"
  ) || {
    rm -f "$_handler_probe_output" "$_handler_probe_expected"
    return 1
  }
  if has_cmd timeout && has_cmd nc; then
    printf '\000\051\104\120\001\000\000\001\000\000\000\000\000\000\023use-application-dns\003net\000\000\001\000\001' \
      | timeout 3 nc -w 2 127.0.0.1 5354 \
      > "$_handler_probe_output" 2>/dev/null
    _handler_probe_status=$?
  elif has_cmd busybox; then
    printf '\000\051\104\120\001\000\000\001\000\000\000\000\000\000\023use-application-dns\003net\000\000\001\000\001' \
      | busybox timeout 3 busybox nc -w 2 127.0.0.1 5354 \
      > "$_handler_probe_output" 2>/dev/null
    _handler_probe_status=$?
  elif [ -x /data/adb/magisk/busybox ]; then
    printf '\000\051\104\120\001\000\000\001\000\000\000\000\000\000\023use-application-dns\003net\000\000\001\000\001' \
      | /data/adb/magisk/busybox timeout 3 /data/adb/magisk/busybox nc \
        -w 2 127.0.0.1 5354 \
      > "$_handler_probe_output" 2>/dev/null
    _handler_probe_status=$?
  elif [ -x /data/adb/ksu/bin/busybox ]; then
    printf '\000\051\104\120\001\000\000\001\000\000\000\000\000\000\023use-application-dns\003net\000\000\001\000\001' \
      | /data/adb/ksu/bin/busybox timeout 3 /data/adb/ksu/bin/busybox nc \
        -w 2 127.0.0.1 5354 \
      > "$_handler_probe_output" 2>/dev/null
    _handler_probe_status=$?
  elif [ -x /data/adb/ap/bin/busybox ]; then
    printf '\000\051\104\120\001\000\000\001\000\000\000\000\000\000\023use-application-dns\003net\000\000\001\000\001' \
      | /data/adb/ap/bin/busybox timeout 3 /data/adb/ap/bin/busybox nc \
        -w 2 127.0.0.1 5354 \
      > "$_handler_probe_output" 2>/dev/null
    _handler_probe_status=$?
  fi
  _handler_probe_valid=1
  if [ "$_handler_probe_status" -eq 0 ] \
    && [ -f "$_handler_probe_output" ] && [ ! -L "$_handler_probe_output" ] \
    && [ -f "$_handler_probe_expected" ] && [ ! -L "$_handler_probe_expected" ] \
    && files_equal_exact "$_handler_probe_expected" "$_handler_probe_output" \
    && dnscrypt_listener_ready "$_handler_pid"; then
    _handler_probe_valid=0
  fi
  rm -f "$_handler_probe_output" "$_handler_probe_expected"
  return "$_handler_probe_valid"
}

dnscrypt_process_uid() {
  _uid_pid="$1"
  sed -n 's/^Uid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$PROC_ROOT/$_uid_pid/status" 2>/dev/null | head -n 1
}

is_dnscrypt_ready() {
  _ready_pid=$(dnscrypt_pid 2>/dev/null || true)
  [ -n "$_ready_pid" ] || return 1
  [ "$(dnscrypt_process_uid "$_ready_pid")" = "$DNSCRYPT_UID" ] || return 1
  dnscrypt_local_handler_ready "$_ready_pid"
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
    if is_watchdog_pid "$_watchdog_pid"; then
      kill -9 "$_watchdog_pid" >/dev/null 2>&1 || true
    fi
    _watchdog_stop_count=$((_watchdog_stop_count + 1))
  done
  rm -f "$WATCHDOG_PID_FILE"
}
