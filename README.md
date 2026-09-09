# DNSCrypt Proxy Root

Run dnscrypt-proxy on a rooted Android device for encrypted DNS, managed domain/IP lists, and a
local DNS upstream.

[Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) ·
[繁體中文](README.zh-TW.md) · [简体中文](README.zh-CN.md) · [Changelog](CHANGELOG.md)

> **v0.9.2 status:** the module tracks dnscrypt-proxy 2.1.18. Its automated dash, BusyBox ash,
> JavaScript, lint, rollback, and archive checks do not replace Android hardware testing. The
> [real-device acceptance matrix](REAL_DEVICE_ACCEPTANCE.md) remains explicitly **NOT RUN** for
> v0.9.2; do not assume every device, root manager, VPN, or DNS frontend is already certified.

## Choose the integration mode

| | `strict` (default) | `upstream_only` |
|---|---|---|
| Intended use | Let this module handle ordinary system Do53 | Let another DNS frontend or proxy own interception and routing |
| Local service | `127.0.0.1:5354` | `127.0.0.1:5354` |
| IPv4 Do53 | Redirected to the local service, with daemon-UID and loopback exemptions | No module-owned global redirect |
| IPv6 Do53 | Blocked in module-owned chains, with the daemon UID exempted | No module-owned blocking policy |
| Android Private DNS | Saved and disabled while strict policy is active; restored on stop or mode exit | Preserved/restored |
| Coexistence | Audit rule order and loops when another component also handles DNS | Configure the frontend explicitly to use this module as an upstream |

`upstream_only` does not make every app use the module. The frontend must be able to reach
`127.0.0.1:5354` in its network namespace and must perform its own DNS interception/routing.

The integration mode is separate from WebUI resolver presets. `strict`/`upstream_only` controls
Android routing policy; `quick-mode` selects resolver/protocol preferences.

## Requirements

- Target: Android 7.0+; actual support depends on device and root-manager acceptance.
- Magisk, KernelSU, or APatch module environment.
- `strict` requires suitable iptables/ip6tables, NAT, owner, and comment support.
- Root shell tools for locking and diagnostics; a root manager's BusyBox supplies some fallbacks.
- GitHub connectivity during installation/core updates and possibly the initial resolver-source load.

The WebUI is intended for KernelSU/APatch. Magisk users can use the module action button and the
root-shell control script.

| Device ABI | Upstream release asset |
|---|---|
| arm64-v8a | `android_arm64` |
| armeabi-v7a | `android_arm` |
| x86_64 | `android_x86_64` |
| x86 | `android_i386` |

## Install or upgrade

1. Download `dnscrypt-proxy-root-v0.9.2.zip` from [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases).
2. Install it in your root manager.
3. Reboot.
4. Check the full service state, then select the integration mode that matches your DNS topology.

The module ZIP does not embed the dnscrypt-proxy executable. Installation attempts to download the
correct official asset and validates its release digest and reported version. A failed download
warns without abandoning module installation; first boot or a later manual update can retry.

> **Upgrading from v0.9.0 or older:** export or record configuration, lists, and subscriptions
> first. Those layouts do not meet the hardened migration-provenance boundary and are replaced with
> audited defaults. Reboot, then reapply the desired inputs. Direct upgrades from v0.6.0 through
> v0.8.0 must reboot so indistinguishable legacy per-boot IPv6 rules disappear safely. A trusted
> v0.9.1 canonical generation is preserved by the v0.9.2 installer.

## First verification and common controls

Run these commands in an **Android root shell**. With ADB, enter `adb shell` and then `su` first.

```sh
DPR_CTL=/data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh

sh "$DPR_CTL" status
sh "$DPR_CTL" get-dns-mode
sh "$DPR_CTL" logs
```

A running process alone does not prove working DNS protection. Inspect `healthy`, `service_state`,
`listener`, `local_dns`, `firewall`, `upstream`, `config_apply_state`, and `start_failure` together.

| State example | Meaning |
|---|---|
| `healthy` | Local DNS and the selected policy pass checks; the upstream probe may still be unknown |
| `degraded` | Local service/policy works, but the latest upstream probe failed |
| `starting` | A bounded startup/preflight is still in progress |
| `policy_fault` | The process may exist, but the selected system policy failed verification |
| `stopped` / `start_*` | Intentionally stopped, or failed at a named startup stage |

Common actions:

```sh
sh "$DPR_CTL" start
sh "$DPR_CTL" stop
sh "$DPR_CTL" restart

sh "$DPR_CTL" set-dns-mode upstream_only
sh "$DPR_CTL" set-dns-mode strict
```

These are alternatives, not a sequence to run blindly. A live mode change keeps a healthy daemon
process running and applies only the selected Android policy. When the daemon is stopped, changing
mode records the choice but does not start it.

## WebUI and canonical generations

Open the module WebUI from KernelSU/APatch to see backend-reported status, edit TOML and managed
lists, choose resolvers, manage subscriptions, inspect statistics/logs, run bounded diagnostics,
update the core, and export/import a generation. The TOML control is a plain text editor.

The v0.9.2 WebUI is built from the dependency-free source in `webui/src/`; the committed five-file
output in `webroot/` is deterministic and contains no development React bundle or remote analytics.
The bridge allowlists control actions and leaves path, ownership, lock, validation, and rollback
enforcement to the root backend.

| Path | Purpose |
|---|---|
| `/data/adb/modules/dnscrypt-proxy-root/config/` | Audited install templates, not the live source of truth |
| `/data/local/dnscrypt-proxy-root-runtime/config/` | Canonical TOML, four managed lists, and subscriptions |
| `/data/local/dnscrypt-proxy-root-runtime/active/` | Read-only snapshot used by the current daemon generation |
| `/data/local/dnscrypt-proxy-root-runtime/data/` | Resolver cache and configured query/NX logs |

Do not edit `active/`. Use the WebUI/backend or carefully edit the canonical location as root.

Saving and applying are intentionally distinct:

- **Configuration – Save (pending):** validates and atomically replaces the canonical TOML. It does
  not change the running snapshot until a successful restart.
- **Configuration – Save & restart:** saves first, then requests a restart. If restart fails, the
  saved TOML remains canonical and the failure is reported explicitly.
- **Managed list – Save (pending):** updates one canonical list without restarting.
- **Managed list – Save + apply:** if the service is running and no canonical input is already
  pending, restarts it with the new generation. If that start fails, it restores the previous
  canonical list and restarts the known-working one. An existing pending or unavailable generation
  is refused before the selected list is changed; restart or restore that generation first. If the
  rollback replacement itself fails, the backend retains and reports the validated old-list backup
  path for manual recovery.
- `status.config_apply_state` is `pending`, `applied`, or `unavailable`; use it instead of inferring
  apply state from a successful save message.

Managed-list reads and writes use the same canonical backend API. The WebUI never reads an install
template while writing a different runtime path.

## Backup and restore

`export-config` emits one strict generation manifest (schema v2) containing TOML, four managed
lists, and subscriptions. The Android integration mode is intentionally separate and is not changed
by import.

An import accepts only the exact v1/v2 field layout, applies per-field size limits, decodes and
protects all fields in a private staging directory, and runs dnscrypt-proxy validation against the
staged lists. Only then does it begin the canonical commit. A full previous generation and recovery
marker are retained so any commit failure or interruption restores every canonical input. A
pending recovery is completed before the next control action—including `status`—is dispatched. A
successful import is still pending until restart.

Subscriptions use a strict JSON array. Every entry must contain exactly an HTTPS `url` string and an
`enabled` boolean (either field order is accepted); unknown fields, duplicate fields, escaped or
unsafe URLs, and mistyped booleans are rejected. Ordinary multiline JSON whitespace is accepted.

Back up before upgrades or major edits. Do not include transient PID, lock, active-snapshot, or log
files in a configuration backup.

## Updating dnscrypt-proxy

```sh
sh "$DPR_CTL" check-update
sh "$DPR_CTL" update
```

- **Module updates** arrive as Release ZIPs through the root manager and may require reboot.
- **Core updates** use the WebUI or `update`; `check-update` only compares versions.
- Boot triggers a background core check subject to the default 24-hour success interval. This is not
  a resident scheduler that wakes every 24 hours.
- The updater validates the release asset digest, executable version, staged configuration, and
  rollback path. A GitHub release checksum establishes consistency with that channel, not an
  independent publisher signature.
- Interrupted runs clean only their exact owned `tmp/update-<pid>` workspace.

## Diagnostic, privacy, and routing limits

- `strict` primarily governs ordinary Do53. It does not guarantee interception of app-owned DoH/DoT,
  every VPN DNS path, or every network namespace.
- Strict mode blocks IPv6 Do53 rather than redirecting it to an IPv6 listener. That is separate from
  returning AAAA records or using an IPv6 upstream. IPv6-only networks require device testing.
- Startup/recovery removes old policy before local readiness and adds strict policy only after the
  bounded preflight succeeds. That interval is deliberately fail-open.
- Query logging is enabled in the default template for statistics and sampled route checks. Inspect
  domain data before sharing logs. Resolver `require_nolog` is a server-selection property; it does
  not disable local query logging.
- `leak-test` checks whether four generated sample names appear in configured query/NX logs. Its
  legacy `protected`/`partial`/`leaking` labels do not prove the state of every DNS path, and the test
  is not applicable to system-wide interception in `upstream_only`.
- In `strict`, the named-destination query in `dns-test` is redirected by the current policy. The
  result is labeled `comparison_scope=policy_affected` and is not a direct DNS bypass measurement.

## Troubleshooting

| Symptom | Check first |
|---|---|
| Installed but not started | `status.start_failure`, download connectivity, and `logs` |
| Breakage with a VPN/DNS module | Who owns Do53, whether `upstream_only` is appropriate, upstream address, and loops |
| Allow-list entry still blocked | Canonical list content, `config_apply_state`, and filtering by another frontend/upstream |
| Process exists but policy fails | `service_state` and `firewall`, not only `running` |
| Remove/disable the module | Run `stop`, verify the result, then disable/remove in the manager and reboot if requested |

The watchdog checks the local service and selected policy. An intentional stop is not a fault, and
an upstream-only outage does not cause an unbounded restart loop.

When reporting a problem, include module/root-manager/Android versions, integration mode, relevant
errors, and redacted logs. Never post private subscription tokens or unreviewed query history.

## Development and verification

Useful repository checks:

```sh
node webui/build.mjs --check
node tests/test-webui-bridge.js
node tests/test-v092-release.js
env DNSCRYPT_UPDATE_INTERVAL_SECONDS=0 TEST_SHELL_KIND=dash dash tests/test-update-dnscrypt.sh
env TEST_SHELL_KIND=dash dash tests/test-dnscrypt-control.sh
env DNSCRYPT_UPDATE_INTERVAL_SECONDS=0 TEST_SHELL_KIND=busybox-ash busybox ash tests/test-update-dnscrypt.sh
env TEST_SHELL_KIND=busybox-ash busybox ash tests/test-dnscrypt-control.sh
```

`node webui/build.mjs` intentionally replaces `webroot/` with the deterministic files declared by
the build script. CI also checks shell syntax, ShellCheck, JavaScript syntax, both shell matrices,
release metadata, executable/data modes, archive exclusions, and legal files. These checks are not
evidence of actual Android installation, SELinux, firewall, VPN, or packet-path behavior; record
that evidence in [REAL_DEVICE_ACCEPTANCE.md](REAL_DEVICE_ACCEPTANCE.md).

Automatic release packaging checks out the exact event SHA that passed the reusable test job and
aborts if `master` has advanced. Release tags and ZIPs are therefore not built from a later untested
branch tip.

## License and third-party material

Project-owned code is available under the [MIT License](LICENSE). Third-party material remains under
its own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [LICENSES/](LICENSES/).

The module ZIP includes a verbatim Magisk installer script under GPL-3.0-only with pinned source/blob
provenance. The dnscrypt-proxy executable is not bundled, but the updater installs the official
ISC-licensed 2.1.18 asset on device, so its ISC notice is also included in the module ZIP.
