# Real-device acceptance report — 2026-09-29

## Scope

This dated report records one physical-device validation run against repository commit
`a3615948400bc84b7679da07b66dfef986b7e787`. It supplements, but does not modify,
the immutable expectations in `REAL_DEVICE_ACCEPTANCE.md`.

This run does **not** convert the whole v0.9.2 matrix to PASS. It covers only the
observations explicitly recorded below.

## Device and root environment

- Device model: Xiaomi `2407FPN8EG`
- Product/device: `rothko_global` / `rothko`
- Android: 16
- HyperOS incremental build: `OS3.0.303.0.WNNMIXM`
- Android security patch: `2026-08-01`
- Kernel: `6.1.138-android14-11-g6ab8c9a86a33-ab14396278`
- SELinux: Enforcing
- Root manager: KernelSU
- `ksud`: `4.2.0-rc3-13-gfa8311f6 (uapi: 4)`
- Module: `dnscrypt-proxy-root` v0.9.2 / versionCode `2026090901`
- dnscrypt-proxy: 2.1.18
- Android integration mode during this run: `upstream_only`

The tested ZIP SHA-256 was:

```text
a513d8dcaabd3f435efc25d7e5142dbbdbfb434e4a1e78bc4f3acce07b3bb8ed
```

The same digest was observed on Windows and on-device before installation.

## Installation and promotion

KernelSU staged the update under `/data/adb/modules_update/dnscrypt-proxy-root`
and returned installation status 0. The installer reported:

- trusted settings migration
- permissions applied
- dnscrypt-proxy 2.1.18 downloaded and verified
- reboot required

Persistent staged scripts matched the ZIP byte-for-byte. `customize.sh` was not
present after installation because KernelSU sources that installer-only file and
then removes it during installer cleanup.

After reboot, the staged update directory and live update marker were gone and the
live control script SHA-256 matched the tested merged-master payload:

```text
3311198afeaaeb9a8f43766954c69bef3e9949da24d46fa30ff7e90ee3cec444
```

## Canonical configuration preservation

Before installation, the canonical TOML SHA-256 was:

```text
a5b2f6e3e34c6e5d83773f21760abea5cd2e5414c0e98496c8d584394f0458f1
```

The four managed lists were empty and each had the empty-file SHA-256:

```text
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

Those five canonical hashes were byte-identical after the first reboot.

The trusted runtime identities observed after boot were:

- runtime root: `0:0 0755`
- `.layout-owner`: `0:0 0600`, value `dnscrypt-proxy-root:5`
- canonical `config/`: `0:0 0700`
- canonical TOML and four managed lists: `0:0 0600`
- active snapshot directory: `3003:0 0500`
- active TOML and four managed lists: `3003:0 0400`

No canonical managed input was a symlink.

## First-boot readiness observation

Android `sys.boot_completed=1` was observed before the module had reached its
steady-state service readiness. An early sample reported an incomplete control
state, while the service log later showed:

- source/config preflight at approximately 18:59:15
- daemon start attempt at approximately 19:00:29
- local UDP/TCP listeners on `127.0.0.1:5354`
- healthy start completion at approximately 19:00:34

A later sample converged to:

- `running=true`
- `healthy=true`
- `uid=3003`
- `listener=true`
- `local_dns=true`
- `upstream=online`
- `config_apply_state=applied`
- `start_failure=none`

Therefore an external acceptance harness must not use Android boot completion as
a proxy for module readiness. After boot completion, poll module `status` until
`running`, `healthy`, `listener`, and `local_dns` are all true, with a
bounded timeout.

A PowerShell boot-completion loop must also tolerate temporary empty ADB output:

```powershell
do {
    Start-Sleep -Seconds 2
    $raw = adb shell getprop sys.boot_completed 2>$null
    $boot = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
} until ($boot -eq '1')
```

That should be followed by the module-readiness poll rather than treated as the
final service-ready signal.

## Daemon identity

At steady state, the daemon ran with all effective UID fields equal to 3003 and
the exact managed argv was:

```text
/data/local/dnscrypt-proxy-root-runtime/bin/dnscrypt-proxy -config /data/local/dnscrypt-proxy-root-runtime/active/dnscrypt-proxy.toml
```

The module independently reported both listener and local DNS readiness.

## Privacy preset validation

The installed merged-master control script changed the resolver preset from
`custom` to `privacy` with status 0. The resulting canonical semantics were:

```text
server_names = []
dnscrypt_servers = true
doh_servers = false
odoh_servers = false
require_dnssec = true
require_nolog = true
require_nofilter = false
skip_incompatible = true
anonymized wildcard route present
```

All nine explicit semantic assertions passed.

Normal `probe-upstream` returned 0. The same probe under KernelSU BusyBox with
`ASH_STANDALONE=1` also returned 0.

A real `dns-test example.com` query through `127.0.0.1:5354` returned 0 and
the query log showed anonymized relays including:

- `anon-cs-de`
- `anon-tiarap`
- `anon-kama`

## Second-reboot persistence

The privacy canonical TOML immediately before reboot had SHA-256:

```text
f9a7b6b3ac5c358b62b602325f6a2b018a3ae9e391e490ce438ae8e99db67b1a
```

After the second reboot, without re-running `quick-mode privacy`:

- `get-mode` returned `privacy`
- the five canonical configuration hashes were byte-identical to pre-reboot
- `protocol-status` reported DNSCrypt enabled, DoH/ODoH disabled, anonymized enabled
- normal upstream probe returned 0
- KernelSU ASH_STANDALONE upstream probe returned 0
- `dns-test example.net` returned 0
- query-log relay evidence included `anon-kama`, `anon-tiarap`, `anon-cs-de`,
  and `anon-cs-fr`
- final status remained healthy with UID 3003, both listener checks true,
  `start_failure=none`, and `config_apply_state=applied`
- Android Private DNS remained `hostname` / `dns11.quad9.net`, as expected for
  `upstream_only`
- the final bounded log scan found no `error`, `failed`, `failure`, `unsafe`,
  or `rollback` line

## Protocol-status observation

In privacy mode, `protocol-status` returned:

```json
{"dnscrypt":true,"doh":false,"odoh":false,"anonymized":true,"running":true,"quality":"good","active_resolvers":0}
```

This did not represent zero usable resolvers. The same live generation resolved
real queries through anonymized relays, and dnscrypt-proxy logged a startup
summary with `live servers: 175`.

The cause is that the current `protocol_status()` implementation counts RTTs
only for names explicitly listed in `server_names`. Privacy mode deliberately
uses `server_names = []`, which asks dnscrypt-proxy to auto-select every resolver
matching the configured metadata filters. A regression test and backend fix are
tracked separately so explicit resolver-list behavior remains unchanged.

## Result and limits

**PASS for the explicitly exercised KernelSU update path, upstream-only local
service, privacy preset semantics, anonymized real queries, and two-reboot
configuration persistence on this one device/build.**

Not exercised in this run, and therefore not claimed:

- strict-mode firewall/Private-DNS takeover
- Magisk or APatch
- VPN/lockdown interactions
- Wi-Fi/flight-mode recovery scenarios
- uninstall/disable cleanup
- unsafe runtime collision cases
- packet capture or a second independent DNS-egress signal
- SELinux label inventory beyond confirming Enforcing mode
- WebUI interaction acceptance
