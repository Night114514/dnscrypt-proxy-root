# Android real-device acceptance matrix for v0.9.2

> Status: **NOT EXECUTED for v0.9.2** as of 2026-09-09. The repository CI uses
> isolated mocks and cannot validate a real Android kernel, SELinux policy, root-manager mount/lifecycle
> behavior, Private DNS service, VPN routing, firewall counters, or DNS egress. Do not convert any row to PASS
> without attaching the observations listed below.

The Xiaomi 14T Pro / Android 16 combination and Magisk, KernelSU, and APatch are
reference test targets, not verified current device states or compatibility claims.
Before testing, record the actual device model, Android build, kernel, SELinux
mode, root manager and module version; do not infer them from this checklist.

## Evidence to capture for every row

Run the checks as root immediately before and after the scenario. Redact public
addresses or hostnames if the report will be shared, but keep PID, UID, rule
counters and state transitions.

```sh
getprop ro.product.model
getprop ro.build.version.release
getprop ro.build.version.incremental
uname -a
getenforce
# Record the one root manager and exact version used by this run.
command -v magisk >/dev/null 2>&1 && magisk -V
command -v ksud >/dev/null 2>&1 && ksud --version
command -v apd >/dev/null 2>&1 && apd --version
sed -n '1,8p' /data/adb/modules/dnscrypt-proxy-root/module.prop

/data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh status
ps -A -o PID,UID,ARGS | grep '[d]nscrypt-proxy'
# Replace PID below with the daemon PID reported by status.
tr '\0' '\n' < /proc/PID/cmdline
grep '^Uid:' /proc/PID/status
ls -l /proc/PID/fd | grep 'socket:'
grep '0100007F:14EA' /proc/net/tcp /proc/net/udp

# Capture both the immutable module templates and the canonical runtime copy.
stat -c '%u:%g %a %d:%i %n' \
  /data/adb/modules/dnscrypt-proxy-root/bin \
  /data/adb/modules/dnscrypt-proxy-root/bin/dnscrypt-proxy \
  /data/adb/modules/dnscrypt-proxy-root/config \
  /data/local \
  /data/local/dnscrypt-proxy-root-runtime \
  /data/local/dnscrypt-proxy-root-runtime/.layout-owner \
  /data/local/dnscrypt-proxy-root-runtime/bin \
  /data/local/dnscrypt-proxy-root-runtime/bin/dnscrypt-proxy \
  /data/local/dnscrypt-proxy-root-runtime/config \
  /data/local/dnscrypt-proxy-root-runtime/config/dnscrypt-proxy.toml \
  /data/local/dnscrypt-proxy-root-runtime/config/allowed-names.txt \
  /data/local/dnscrypt-proxy-root-runtime/config/blocked-names.txt \
  /data/local/dnscrypt-proxy-root-runtime/config/allowed-ips.txt \
  /data/local/dnscrypt-proxy-root-runtime/config/blocked-ips.txt \
  /data/local/dnscrypt-proxy-root-runtime/active \
  /data/local/dnscrypt-proxy-root-runtime/active/dnscrypt-proxy.toml \
  /data/local/dnscrypt-proxy-root-runtime/active/allowed-names.txt \
  /data/local/dnscrypt-proxy-root-runtime/active/blocked-names.txt \
  /data/local/dnscrypt-proxy-root-runtime/active/allowed-ips.txt \
  /data/local/dnscrypt-proxy-root-runtime/active/blocked-ips.txt \
  /data/local/dnscrypt-proxy-root-runtime/data \
  /data/local/dnscrypt-proxy-root-runtime/.daemon-pid
[ ! -e /data/local/dnscrypt-proxy-root-runtime/config/subscriptions.json ] || \
  stat -c '%u:%g %a %d:%i %n' /data/local/dnscrypt-proxy-root-runtime/config/subscriptions.json
cat /data/adb/modules/dnscrypt-proxy-root/run/installed-version
/data/local/dnscrypt-proxy-root-runtime/bin/dnscrypt-proxy -version

# Capture SELinux labels; do not infer compatibility from Unix modes alone.
ls -Zd /data/local \
  /data/local/dnscrypt-proxy-root-runtime \
  /data/local/dnscrypt-proxy-root-runtime/bin \
  /data/local/dnscrypt-proxy-root-runtime/config \
  /data/local/dnscrypt-proxy-root-runtime/active \
  /data/local/dnscrypt-proxy-root-runtime/data
ls -lZ /data/local/dnscrypt-proxy-root-runtime \
  /data/local/dnscrypt-proxy-root-runtime/bin \
  /data/local/dnscrypt-proxy-root-runtime/config \
  /data/local/dnscrypt-proxy-root-runtime/active \
  /data/local/dnscrypt-proxy-root-runtime/data

# The marker must be exactly one LF-terminated line; retain both text and bytes.
cat /data/local/dnscrypt-proxy-root-runtime/.layout-owner
od -An -tx1 /data/local/dnscrypt-proxy-root-runtime/.layout-owner

settings get global private_dns_mode
settings get global private_dns_specifier
cat /proc/sys/net/ipv4/conf/all/route_localnet
cat /data/adb/modules/dnscrypt-proxy-root/state/firewall-owned.state
iptables-save -c
ip6tables-save -c
```

For DNS egress, capture at least two independent signals: the dnscrypt-proxy
query log, the selected front-end/VPN query or connection log, and packet capture
or firewall counter changes on the real egress interface. A successful lookup or
a browser leak-test page alone is not sufficient. Also record whether the tested
application uses system Do53, built-in DoH/DoT, or a VPN-provided resolver.

The normal v0.9.2 daemon identity is exactly:

```text
/data/local/dnscrypt-proxy-root-runtime/bin/dnscrypt-proxy -config /data/local/dnscrypt-proxy-root-runtime/active/dnscrypt-proxy.toml
```

The module starts that argv directly as UID 3003, so it should not need to
re-exec. Lifecycle ownership matching also accepts only the same exact argv with
one trailing `-child`, for upstream compatibility. A real validation process is
also UID 3003 and has exactly `-check -config` followed by its private
`/data/local/dnscrypt-proxy-root-runtime/.config-check.PID/dnscrypt-proxy.toml`
snapshot; capture it while a deliberately slow validation is in progress.

The effective UID must be 3003, the same PID must own both TCP LISTEN and UDP
bound sockets at `127.0.0.1:5354`, and status must independently report
`"listener":true` and `"local_dns":true`. Capture the canary probe or an
equivalent packet trace showing the complete local NXDOMAIN response rather
than treating TCP accept/close as functional DNS. In `strict`, the random token after
the boot ID in `firewall-owned.state` must be the comment token in both managed chains.
The `/data/local` parent must be `0:0`, not group/other-writable, other-executable, and one of modes
`701/705/711/715/741/745/751/755`. The runtime root and `bin` must be `0:0 755`, the runtime
executable must be `0:0 755`, canonical `config` must be `0:0 700`, and every canonical
managed input (plus optional subscriptions) must be a regular, non-symlink `0:0 600` file.
The disposable `active` directory must be `3003:0 500`, each of its five inputs
must be `3003:0 400`, `data` must be `3003:0 700`, and `.daemon-pid` must be
`3003:0 600`. `.layout-owner` must be `0:0 600` with exact bytes for
`dnscrypt-proxy-root:5\n`. Confirm the active TOML has no `user_name`, all shipped/generated
cache and query/NX-log paths resolve under `../data`, and an unrelated process that merely
has supplemental INTERNET GID 3003 cannot read the canonical or active inputs.
The `/data/local` parent and all runtime components must have recorded SELinux
labels with no relevant `avc: denied` evidence; only a successful run under the
named root manager can turn that manager/device row into PASS.

## Acceptance matrix

| Scenario | Mode | Required observations | v0.9.2 result |
| --- | --- | --- | --- |
| Clean boot on ordinary Wi-Fi/mobile data, repeated separately on Magisk, KernelSU, and APatch | `strict` | Installer records digest/version validation but defers `-check`; first boot creates the exact marked `/data/local` copy with the modes, owners, canonical inputs, active snapshot, data directory and SELinux evidence above. Daemon and source/cache `-check` run as UID 3003 using only the runtime binary and their disposable snapshot/cwd; root never parses those snapshots. Preflight and NetProbe remain fail-open; no module OUTPUT jump appears before both owned listeners and the bounded local synthesized NXDOMAIN response succeed; saved Private DNS changes only after readiness; ordered IPv4/IPv6 policy, ownership tokens, `route_localnet`, and Do53 counters are complete. | **NOT RUN** |
| Installer binary download fails, then network recovers after reboot | Both, tested separately | Flashing reports the nonfatal download warning and leaves no unverified executable; first boot remains fail-open, retries the digest/version-verified download before daemon launch, then performs the deferred runtime-path `-check`. If automatic recovery still fails, action/WebUI retry succeeds after connectivity returns without unsafe config adoption or partial binary commit. | **NOT RUN** |
| Pre-existing unmarked, symlinked, or permission/owner-mismatched runtime collision (disposable test state only) | Both, tested separately | Startup fails closed without adopting, deleting, or overwriting the collision; no daemon, Private DNS change, route ownership, or module firewall jump is left behind; the failure state identifies the unsafe runtime path. | **NOT RUN** |
| Boot in flight mode, then restore Wi-Fi/mobile data | `strict` | During source preflight/NetProbe the system is not redirected to an absent listener; missing cache plus failed source download is reported distinctly; repeated cold-start failures follow capped backoff rather than a 60-second loop; an already listening daemon is not restarted merely because upstream is offline; state eventually moves to healthy/online after recovery. | **NOT RUN** |
| Wi-Fi disconnect/reconnect after the daemon is listening | `strict` | PID, UID, listener sockets and the local synthesized-DNS response stay stable; status may be `degraded` while upstream is unavailable and returns to `healthy` after recovery; no firewall duplication. | **NOT RUN** |
| Android Private DNS off/opportunistic/hostname before start and after stop | `strict` | Original mode/specifier are saved exactly, `off` is applied only for active strict policy, and the original values are restored on stop, mode switch, disable and uninstall. | **NOT RUN** |
| Local service only | `upstream_only` | Listener remains `127.0.0.1:5354`; no module OUTPUT jumps/dedicated chains, no `route_localnet=1` ownership, and no Private DNS mutation; generic leak-test reports not applicable. | **NOT RUN** |
| AdGuard Home as DNS entry, dnscrypt-proxy as explicit upstream | `upstream_only` | AdGuard is the only device DNS entry; its upstream is exactly `127.0.0.1:5354`; no resolution loop; AdGuard and dnscrypt logs show the same test query and the observed egress is dnscrypt-proxy's upstream. | **NOT RUN** |
| box/Mihomo Fake-IP as DNS entry, dnscrypt-proxy as explicit real-resolution upstream | `upstream_only` | The proxy core remains the single DNS entry/Fake-IP owner; bootstrap does not depend on the not-yet-established proxy path; dnscrypt receives only explicitly forwarded queries; no assumed `tun+` or `198.18.0.0/15` exemption is credited. | **NOT RUN** |
| VPN off/on and Android lockdown off/on | Both, tested separately | Record actual routes, fwmarks, VPN interface and socket egress; no VPN kill-switch bypass is introduced; daemon PID is not restarted solely for reachability loss; behavior is reported per tested VPN, not generalized to other brands. | **NOT RUN** |
| Module disable and re-enable | Both, tested separately | Disable removes only module-owned chains/jumps, restores saved Private DNS and route state, and terminates only the exact daemon argv; re-enable recreates only the selected mode policy. | **NOT RUN** |
| Module uninstall with a valid owned runtime tree | Both, tested separately | Same cleanup as disable, including interrupted-operation retry; third-party firewall rules survive; the exact marked `/data/local/dnscrypt-proxy-root-runtime` tree is absent afterward, while unrelated `/data/local` content survives. Capture `test ! -e /data/local/dnscrypt-proxy-root-runtime; echo $?` and require `0`. | **NOT RUN** |
| Module uninstall with an unsafe/unmarked runtime collision (disposable test state only) | Both, tested separately | Cleanup fails closed and preserves the unverified tree for manual inspection instead of recursively deleting it; firewall, Private DNS, route, and daemon cleanup results are recorded independently. | **NOT RUN** |
| Upgrade from v0.9.0 and v0.8.0 | Both, tested separately | Installer clearly warns that older inputs ineligible under v0.9.1's exact migration-provenance policy are reset; settings were exported first and re-applied after reboot; v0.9.0 exact chains are adopted only with trusted current-boot provenance; legacy generic IPv6 direct rules are not deleted in place and disappear only after the required reboot; unrelated identical and same-name third-party rules survive. | **NOT RUN** |
| Upgrade from a trusted v0.9.1 runtime | Both, tested separately | The canonical TOML, all four managed lists and optional subscriptions remain byte-identical after installation; active state is rebuilt only through the normal start path; v0.9.2 status reports `config_apply_state` without weakening owner/mode checks. | **NOT RUN** |
| KernelSU and APatch WebUI bridge | Both, tested separately on each manager | The shipped callback bridge opens without synthetic data; status visibly distinguishes process, health, policy, mode, upstream and pending state; every action returns or displays the backend result; long update operations do not freeze or lose their completion callback. | **NOT RUN** |
| Canonical managed-list save and apply | Both, tested separately | WebUI load bytes equal the matching file under runtime `config/`, not the module template. Save-only changes canonical bytes and reports `pending` while active bytes remain unchanged. Save-and-apply publishes the exact new bytes after a healthy restart; a deliberately rejected disposable generation restores the previous canonical bytes and known-working service rather than reporting success. | **NOT RUN** |
| Generation v2 export/import | Both, tested separately | Export contains the exact fixed v2 fields and round-trips TOML, four lists and subscriptions without changing the Android integration mode. A valid import is reported pending until restart. A controlled commit interruption restores every old canonical file from the trusted generation backup on the next control invocation, with no mixed generation exposed as success. | **NOT RUN** |
| DNS destination comparison in strict mode | `strict` | The comparison is visibly labelled `comparison_scope=policy_affected`; firewall counters or a packet trace confirm the named destination query follows current redirect policy. Neither the UI nor the report calls it a direct-policy bypass or independent destination RTT. | **NOT RUN** |
| dnscrypt-proxy core update succeeds | Both, tested separately | Exact child/parent daemon is detected, stopped and restarted under the same selected mode; `run/installed-version` agrees with the canonical runtime binary's `-version` output, while `.layout-owner` remains the exact runtime-layout marker; listener and policy evidence is re-captured. | **NOT RUN** |
| dnscrypt-proxy core update restart fails and rolls back | Both, tested separately | The old canonical runtime binary and `run/installed-version` marker are restored and agree, `.layout-owner` remains unchanged, the old configuration starts, selected mode remains authoritative, and any rollback failure is explicitly shown as `rollback_failed`/`policy_fault` rather than success. | **NOT RUN** |

## Explicitly outside this v0.9.2 claim

- Tethered-client/PREROUTING DNS capture and hotspot interface discovery.
- Interception of application-owned DoH/DoT or guaranteed capture of every DNS path.
- Generic compatibility with untested VPN, Fake-IP, TUN, WireGuard or proxy brands.
- Automatic bypass of VPN routing, lockdown or kill-switch policy for UID 3003.
- SELinux and root-manager lifecycle compatibility of the `/data/local` runtime copy on Magisk,
  KernelSU, APatch, Xiaomi 14T Pro, Android 16, or any other unexecuted combination.

Record real results in a separate dated report. Keep this file as the immutable
pre-test checklist so a future PASS has auditable evidence rather than a changed
expectation.
