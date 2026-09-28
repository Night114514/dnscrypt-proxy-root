#!/bin/sh
set -u

ROOT_DIR=$(CDPATH='' cd "${0%/*}/.." && pwd) || exit 1
REAL_MKSH=$(command -v mksh) || exit 1
REAL_FLOCK=$(command -v flock) || exit 1
REAL_BUSYBOX=$(command -v busybox) || exit 1
export REAL_MKSH REAL_FLOCK REAL_BUSYBOX
WORK=$(mktemp -d) || exit 1
owner=
child=
cleanup() {
  [ -z "$owner" ] || kill -KILL "$owner" 2>/dev/null || true
  [ -z "$child" ] || kill -KILL "$child" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Exercise the actual production function, without running the updater action.
awk '/^lock_fd_nonblocking\(\) \{/ { copy=1 } copy { print } copy && /^}/ { exit }' \
  "$ROOT_DIR/scripts/update-dnscrypt.sh" > "$WORK/updater-helper.sh"

cat > "$WORK/owner.sh" <<'OWNER'
#!/bin/sh
set -u
MODDIR=$1
common=$2
updater=$3
fd=$4
implementation=$5
helper=$6
. "$common"
. "$updater"
if [ "$implementation" = fallback ]; then
  has_cmd() { return 1; }
  # Ubuntu BusyBox packages may omit the flock applet. Exercise the fallback
  # dispatch with real kernel locking even there; never mock a return code.
  busybox_cmd() {
    if "$REAL_BUSYBOX" --list | grep -qx "$1"; then
      "$REAL_BUSYBOX" "$@"
    elif [ "$1" = flock ]; then
      shift
      "$REAL_FLOCK" "$@"
    else
      return 127
    fi
  }
fi
lock="$SERVICE_LOCK_FILE"
case "$fd" in
  6) exec 6>> "$lock" ;;
  7) exec 7>> "$lock" ;;
  8) exec 8>> "$lock" ;;
  9) exec 9>> "$lock" ;;
  *) exit 1 ;;
esac
inode=$(stat -c '%d:%i' "$lock")
"$REAL_FLOCK" -n "$fd" 2>/dev/null
direct_rc=$?
"$helper" "$fd"
bridge_rc=$?
"$REAL_FLOCK" -n "$lock" true
held_rc=$?
if [ "$fd" = 8 ] && [ "$bridge_rc" = 0 ]; then
  # Explicitly export the same OFD across an external mksh process boundary.
  DNSCRYPT_CONTROL_LOCK_HELD=1 "$REAL_MKSH" -c '
    MODDIR=$1
    . "$2"
    inherited_control_lock_valid
  ' inherited "$MODDIR" "$common" 8>&8 || exit 1
fi
case "$fd" in
  6) exec 6>&- ;;
  7) exec 7>&- ;;
  8) exec 8>&- ;;
  9) exec 9>&- ;;
esac
"$REAL_FLOCK" -n "$lock" true
released_rc=$?
printf '%s/%s FD%s: direct_rc=%s bridge_rc=%s held_rc=%s released_rc=%s\n' \
  "$helper" "$implementation" "$fd" "$direct_rc" "$bridge_rc" "$held_rc" "$released_rc"
[ "$direct_rc" -ne 0 ] && [ "$bridge_rc" -eq 0 ] \
  && [ "$held_rc" -ne 0 ] && [ "$released_rc" -eq 0 ] \
  && [ "$(stat -c '%d:%i' "$lock")" = "$inode" ]
OWNER

failed=0
for implementation in native fallback; do
  for fd in 6 7 8 9; do
    "$REAL_MKSH" "$WORK/owner.sh" "$WORK/module" "$ROOT_DIR/scripts/common.sh" \
      "$WORK/updater-helper.sh" "$fd" "$implementation" flock_fd_nonblocking || failed=1
  done
  "$REAL_MKSH" "$WORK/owner.sh" "$WORK/module" "$ROOT_DIR/scripts/common.sh" \
    "$WORK/updater-helper.sh" 9 "$implementation" lock_fd_nonblocking || failed=1
done
[ "$failed" -eq 0 ] || exit 1
echo 'mksh real-flock portability: PASS (10 acquisition/contention/release cases)'

# A real cp blocks opening a FIFO while its transaction owner is killed. The
# independent contender must remain excluded until that cp finishes writing.
cat > "$WORK/crash-owner.sh" <<'CRASH'
MODDIR=$1
. "$2"
case "$3" in
  8|both|7-8|all) acquire_control_lock || exit 1 ;;
esac
case "$3" in
  6|both|6-7|all) acquire_runtime_tree_lock || exit 1 ;;
esac
case "$3" in
  7|6-7|7-8|all)
    # Match service.sh::start_watchdog's stable FD7 acquisition.
    exec 7>> "$RUN_DIR/watchdog-start.lock" || exit 1
    flock_fd_nonblocking 7 || exit 1
    ;;
esac
printf '%s\n' "$$" > "$4/owner"
cp "$4/input" "$4/output"
# Prevent mksh's last-command exec optimization from replacing the owner.
printf '%s\n' done > "$4/owner-done"
CRASH

for shell_kind in dash ash mksh; do
  for fd in 6 7 8 both 6-7 7-8 all; do
    case_dir="$WORK/crash-$shell_kind-$fd"
    mkdir -p "$case_dir"
    mkfifo "$case_dir/input"
    case "$shell_kind" in
      dash) set -- dash ;;
      ash) set -- "$REAL_BUSYBOX" ash ;;
      mksh) set -- "$REAL_MKSH" ;;
    esac
    "$@" "$WORK/crash-owner.sh" "$case_dir/module" \
      "$ROOT_DIR/scripts/common.sh" "$fd" "$case_dir" &
    owner=$!
    child=
    attempts=0
    while [ "$attempts" -lt 100 ]; do
      # Locate the actual external cp, not a mock or a shell sleeping in its place.
      children=$(cat "/proc/$owner/task/$owner/children" 2>/dev/null)
      for candidate in $children; do
        if [ "$(cat "/proc/$candidate/comm" 2>/dev/null)" = cp ]; then
          child=$candidate
          break
        fi
      done
      [ -n "$child" ] && break
      sleep 0.05
      attempts=$((attempts + 1))
    done
    if [ -z "$child" ]; then
      kill -KILL "$owner" 2>/dev/null || true
      wait "$owner" 2>/dev/null || true
      owner=
      echo "FAIL: $shell_kind FD$fd did not start critical cp"
      failed=1
      continue
    fi
    case "$fd" in
      6|both|6-7|all) lock="$case_dir/module/run/runtime-tree.lock" ;;
      7|7-8) lock="$case_dir/module/run/watchdog-start.lock" ;;
      8) lock="$case_dir/module/run/control.lock" ;;
    esac
    inode=$(stat -c '%d:%i' "$lock") || exit 1
    kill -KILL "$owner" || exit 1
    wait "$owner" 2>/dev/null
    killed_rc=$?
    owner=
    [ "$killed_rc" -eq 137 ] || exit 1
    kill -0 "$child" || exit 1
    "$REAL_FLOCK" -n "$lock" true
    orphan_held_rc=$?
    case "$fd" in both|7-8|all)
      if "$REAL_FLOCK" -n "$case_dir/module/run/control.lock" true; then
        failed=1
      fi
      ;;
    esac
    case "$fd" in 6-7|all)
      if "$REAL_FLOCK" -n "$case_dir/module/run/watchdog-start.lock" true; then
        failed=1
      fi
      ;;
    esac
    # Deliver bytes after owner death: the orphan really can still mutate output.
    timeout 5 sh -c 'printf "critical bytes\n" > "$1"' sh "$case_dir/input" || exit 1
    "$REAL_FLOCK" -w 5 "$lock" true
    released_rc=$?
    case "$fd" in both|7-8|all)
      "$REAL_FLOCK" -w 5 "$case_dir/module/run/control.lock" true || failed=1
      ;;
    esac
    case "$fd" in 6-7|all)
      "$REAL_FLOCK" -w 5 "$case_dir/module/run/watchdog-start.lock" true || failed=1
      ;;
    esac
    attempts=0
    while [ ! -s "$case_dir/output" ] && [ "$attempts" -lt 100 ]; do
      sleep 0.05
      attempts=$((attempts + 1))
    done
    printf '%s FD%s crash: orphan_held_rc=%s released_rc=%s\n' \
      "$shell_kind" "$fd" "$orphan_held_rc" "$released_rc"
    [ "$orphan_held_rc" -ne 0 ] && [ "$released_rc" -eq 0 ] \
      && [ "$(cat "$case_dir/output")" = 'critical bytes' ] \
      && [ "$(stat -c '%d:%i' "$lock")" = "$inode" ] || failed=1
    child=
  done
done
[ "$failed" -eq 0 ] || exit 1
echo 'real-flock crash lifetime: PASS (21 FD6/FD7/FD8/combined cases under dash/ash/mksh)'

# Bridging locks on mutations must not consume the command's actual stdin.
"$REAL_MKSH" -c '
  MODDIR=$1
  . "$2"
  acquire_control_lock && acquire_runtime_tree_lock || exit 1
  exec 7>> "$RUN_DIR/watchdog-start.lock" || exit 1
  flock_fd_nonblocking 7 || exit 1
  printf "stdin payload\n" | cp /dev/stdin "$MODDIR/stdin-copy" || exit 1
  [ "$(cat "$MODDIR/stdin-copy")" = "stdin payload" ]
' stdin-check "$WORK/stdin-module" "$ROOT_DIR/scripts/common.sh" || exit 1
echo 'locked file command stdin: PASS'
