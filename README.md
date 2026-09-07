# DNSCrypt Proxy Root WebUI Module

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

A systemless Magisk/KernelSU/APatch module that runs **dnscrypt-proxy** on rooted Android devices with:

- **Systemless encrypted DNS** via dnscrypt-proxy (DNSCrypt / DoH)
- **Packaged for Magisk, KernelSU, and APatch**; the v0.9.1 manager/device matrix remains
  [NOT RUN](REAL_DEVICE_ACCEPTANCE.md), so this release does not claim verified compatibility
- **Two explicit integration modes**: default `strict` system-wide Do53 capture, or
  `upstream_only` for coexistence with Android Private DNS, VPNs, and other DNS frontends
- **IPv6 DNS leak protection in `strict` mode** through a module-owned ip6tables chain
- **DNSSEC + NOLOG resolver filtering** (`require_dnssec` / `require_nolog`)
- **Automatic binary updates** from upstream releases
- **WebUI** for KernelSU/APatch managers (configuration, logs, statistics)
- **Custom blocklist subscriptions** with safe URL validation
- **Multi-language support** (English, 繁體中文, 简体中文)
- **DNS query statistics** dashboard
- **Blocklist/Allowlist** graphical management
- **DNS path sample test** — check whether synthetic system-DNS queries appear in dnscrypt-proxy's log *(v0.7.0)*
- **Service watchdog with Android notifications** — auto-restart and notify if the service stops unexpectedly *(v0.7.0)*
- **Light/Dark theme toggle** in the WebUI *(v0.7.0)*
- **GitHub Actions CI/CD** for automatic module releases

---

## Requirements

- Android 7.0+ (API 24+)
- Packaging target (not yet device-accepted for v0.9.1): **Magisk 20.4+**, **KernelSU 0.7.0+**,
  or **APatch 10596+**
- The updater requires `flock` (provided by Android 7+ Toybox, with a root-manager BusyBox fallback)
- A device whose kernel supports **iptables NAT** (the case on the vast majority of devices)
- The WebUI management interface requires KernelSU or APatch (Magisk has no WebUI; on Magisk
  the action button toggles the service instead)

---

## Installation

1. Download the latest `dnscrypt-proxy-root-vX.X.X.zip` from [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases).
2. Flash via **Magisk Manager**, **KernelSU Manager**, or **APatch Manager**.
3. Reboot.

The installer attempts to download the dnscrypt-proxy binary for the detected architecture. A
successful download is accepted only after its release-asset digest and reported binary version are
verified. Download failure is reported but does not abort flashing: first boot retries before daemon
startup, and the action button or KernelSU/APatch WebUI can retry later. Because the root manager
stages the module below `/data/adb`, the install process deliberately defers the real
configuration/source `-check` until first boot, after the protected runtime copy has been created at
`/data/local/dnscrypt-proxy-root-runtime`.

> **v0.9.1 upgrade warning:** export or record your configuration, lists, and subscriptions before
> flashing over v0.9.0 or older. v0.9.0 allowed UID 3003 to write the whole config directory;
> earlier layouts also do not satisfy v0.9.1's hardened migration-provenance checks. The installer
> therefore installs audited defaults for all of these versions; re-apply your settings after
> reboot. Upgrades from v0.6.0 through v0.8.0 must reboot so the kernel clears indistinguishable
> legacy direct IPv6 rules.

---

## WebUI

In **KernelSU** or **APatch** managers, tap the module's WebUI icon to access the configuration interface.

| Tab | Function |
|-----|----------|
| **Overview** | Service status, version info, quick start/stop/restart |
| **Config** | Edit `dnscrypt-proxy.toml` with syntax highlighting |
| **Blocklist** | Graphical domain blocklist/allowlist editor |
| **Stats** | DNS query statistics (total queries, block rate, top domains, hourly timeline) |
| **DNS Test** | Test domain resolution through dnscrypt-proxy vs direct DNS, compare latency, and run a **DNS Leak Test** *(v0.7.0)* |
| **Resolvers** | Graphical DNS server selector with protocol/feature badges |
| **Logs** | Real-time service and query logs |
| **Update** | Check and install upstream binary updates |

The WebUI supports **English**, **繁體中文**, and **简体中文** with automatic detection based on system language.

A **Light/Dark theme toggle** (sun/moon button) sits in the top-right corner *(v0.7.0)*. The choice is
saved in the browser's `localStorage`; the default is dark (AMOLED-friendly).

---

## How It Works

### Protected runtime copy

The module directory under `/data/adb/modules/dnscrypt-proxy-root` contains the audited configuration
templates, control scripts, WebUI, and, when the installer download succeeds, a digest/version-verified
binary. If that binary is absent, first boot must download and verify it before daemon startup. The
service creates a separate persistent execution tree at `/data/local/dnscrypt-proxy-root-runtime`;
this is a file copy, not a bind mount or mount-namespace overlay. The module invokes both the daemon
and `-check` as numeric UID 3003 from this traversable tree, so no root process asks upstream code to
parse a runtime configuration and no UID-3003 process needs to traverse the root-only `/data/adb`
path. Lifecycle matching still recognizes upstream 2.1.18's exact optional `-child` form, but the
normal v0.9.1 launch starts at its final UID and does not need that re-exec.

The runtime root and `bin` directory are `root:root 0755`. Canonical `config` is `root:root 0700`;
its five managed inputs (and `subscriptions.json` when present) are `root:root 0600`. Before each
launch, the module publishes a disposable `active` snapshot as `3003:root 0500` with its five inputs
at `3003:root 0400`, omitting `user_name` because the process already has its final UID. Mutable
query/NX logs and resolver caches live under `data` (`3003:root 0700`), while the PID handshake is
`3003:root 0600`. A root-owned `0600` marker named `.layout-owner` must contain exactly one
LF-terminated line, `dnscrypt-proxy-root:5`. An existing unmarked tree, unsafe parent/path, symlink,
or permission/ownership mismatch is treated as a collision and startup fails closed instead of
adopting or overwriting it. Uninstall removes this tree only after the same ownership, mode, path,
transaction state, and marker checks succeed.

### DNS Integration Modes

The integration mode is stored as root-only module state, separately from
`dnscrypt-proxy.toml`. A missing state file means `strict`; malformed or symlinked state fails
closed. Changing the mode while the daemon is healthy does not restart it:

```sh
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh get-dns-mode
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh set-dns-mode strict
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh set-dns-mode upstream_only
```

In the default **`strict`** mode:

- dnscrypt-proxy listens on `127.0.0.1:5354`.
- An iptables NAT chain (`DNSCRYPT_PROXY`) in the `OUTPUT` chain DNATs all outgoing
  plaintext DNS queries (UDP/TCP port 53) to `127.0.0.1:5354`.
- `net.ipv4.conf.all.route_localnet=1` is enabled so the kernel does not drop packets
  DNAT'd to the loopback address from the `OUTPUT` chain (without this the redirection
  fails completely).
- dnscrypt-proxy runs with Android's numeric AID_INET identity (`3003`). Only traffic whose effective
  UID is 3003 and the `127.0.0.0/8` loopback range receive `RETURN` rules, so bootstrap and
  netprobe traffic cannot recurse into the proxy. No resolver destination is globally allowlisted;
  ordinary apps therefore cannot bypass protection by querying one of the bootstrap IPs directly.
- Because dnscrypt-proxy only listens on IPv4, plaintext DNS over IPv6 (port 53) is blocked
  inside the module-owned `DNSCRYPT_PROXY6` chain. A random generation token binds both module
  chains to root-only current-boot state; unproven same-name chains and indistinguishable direct
  rules belonging to VPNs, firewalls, or other modules are preserved.
- Android Private DNS is saved and disabled only after both the TCP and UDP listeners are owned
  by the exact UID-3003 daemon and a bounded, upstream-independent canary query receives the exact
  locally synthesized NXDOMAIN response; it is restored on stop or when leaving `strict` mode.

In **`upstream_only`** mode, the module only keeps dnscrypt-proxy available at
`127.0.0.1:5354`. It does not install global iptables/ip6tables rules, change
`route_localnet`, or alter Android Private DNS. A local DNS frontend such as a VPN-based
filter can use that listener as its upstream. System-wide leak protection is therefore the
responsibility of that frontend, and the module's leak-test command reports `not_applicable`.

During either mode's cold start, the system DNS path remains fail-open while a bounded real
`dnscrypt-proxy -check` source/cache preflight runs as UID 3003 from a disposable runtime snapshot,
and while the upstream NetProbe completes.
The source preflight has a 660-second hard limit; NetProbe follows upstream 2.1.18 semantics up to
its 3600-second maximum, followed by a 30-second listener margin. Policy is applied only after the
preflight succeeds and the exact daemon PID, UID 3003, TCP LISTEN socket, and UDP bound socket at
`127.0.0.1:5354` have all been verified, together with the bounded local synthesized-DNS-response probe.
Disabling, removing, or shutting down the module immediately cancels both preflight and listener wait.

The canonical runtime configuration is root-only. The daemon can read only a freshly published,
owner-readable execution snapshot and writes only within its separate UID-3003-owned `data`
directory; the module's main service log remains root-only. Configuration staging, backup,
validation, rollback, and commit revalidate the protected file's type, owner, mode, and
device/inode identity. Every control and update entry rejects unsafe managed inputs. Query/NX-log
diagnostics copy bounded snapshots as UID 3003 before root parses them, rather than reopening a
daemon-controlled pathname after a check.

### skip_mount

The `skip_mount` file is intentionally present because this module does **not** overlay any system
partition files. The module directory supplies scripts, WebUI, audited templates, and any binary that
the installer successfully verified, while the daemon runs from the separate persistent copy at
`/data/local/dnscrypt-proxy-root-runtime`. No bind mount or mount-namespace dependency is used;
skipping the root manager's system-overlay mount phase does not suppress creation of that `/data/local`
runtime tree.

### Auto-Update (On-Device)

On each boot, `service.sh` triggers a background update check:

1. Queries the GitHub API for the latest dnscrypt-proxy release
2. Compares with the currently installed version
3. If newer, downloads the architecture-specific asset
4. Extracts, validates, and atomically replaces the binary in the protected `/data/local` runtime tree
5. Updates module metadata

The check is rate-limited to once per 24 hours (configurable via `DNSCRYPT_UPDATE_INTERVAL_SECONDS`).
The rate-limit timestamp is recorded only after a successful check, an up-to-date result, or a fully
committed installation. Network, metadata, download, validation, restart, and rollback failures remain
immediately retryable.

Before extraction, the updater requires the exact asset's server-computed SHA-256 digest from the
GitHub Release API and compares it with the downloaded archive. A missing, malformed, unavailable, or
mismatched digest aborts the install. This is a fail-closed integrity check within GitHub's HTTPS/API
trust boundary; it is not an independent Minisign publisher-identity verification.

### CI/CD Auto-Update (GitHub Actions)

A scheduled workflow runs monthly (on the 1st of each month, and on demand via `workflow_dispatch`):

1. Checks upstream dnscrypt-proxy releases against the separately tracked `.github/upstream-version`
2. If a new upstream version is detected, increments the module's independent `vX.X.X` patch version
3. Updates `module.prop`, `update.json`, and the tracked upstream version
4. Builds a runtime-only module ZIP and creates a GitHub Release named after the module version

This enables Magisk's built-in module updater to notify users of new module versions.

### DNS Leak Test *(v0.7.0)*

The DNS Test page includes a **Leak Test** button. When pressed, the backend
(`dnscrypt-control.sh leak-test`):

1. Generates 4 random `[a-z0-9-]` subdomains.
2. Resolves each one **through the system DNS path** (not directly to dnscrypt-proxy), mimicking
   an ordinary app query subject to the iptables redirection.
3. After a short delay, greps the dnscrypt-proxy query log (and `nx.log`) for each subdomain.
4. Reports the sampled log-visibility result as single-line JSON (the legacy status names remain for
   API compatibility):
   - `protected` — all 4 tested queries appeared in the dnscrypt-proxy log.
   - `partial` — only some tested queries appeared; investigate a possible bypass or query/log failure.
   - `leaking` — none appeared; investigate a possible bypass or query/log failure.

If the query log is disabled it returns `{"status":"error","reason":"query_log_disabled"}` and the
WebUI prompts you to enable it. No dedicated third-party leak-test website is contacted, but the
synthetic DNS queries traverse the configured DNS/upstream path and can appear in network or
upstream resolver logs. This sample does not cover app-owned DoH/DoT, every DNS path, or prove a
global no-leak condition.

### Service Watchdog & Notifications *(v0.7.0)*

`service.sh` starts a background watchdog that checks the service every 60 seconds:

- If the exact process, UID, local TCP/UDP listeners, bounded local handler probe, or selected integration policy fails
  **unexpectedly** (i.e. not after a user-initiated stop), it posts an Android notification and
  retries with capped exponential backoff: 60, 120, 240, 480, then 900 seconds by default.
  Healthy recovery, intentional stop, startup in progress, or concurrent manual control resets
  the delay. Flight mode, Wi-Fi loss, and upstream resolver outages are reported as `degraded` and
  never restart an otherwise healthy local daemon.
- Notifications are capped at **3 per boot** so a crash loop cannot spam the status bar.
- The watchdog is single-instance and tracked by PID; disable, removal, and uninstall stop it and
  restore the saved Android Private DNS state before the module files disappear.
- A successful upstream binary update also posts a notification. Failed updates stay silent (logged
  only) to avoid noise.

Notifications use `cmd notification post` (falling back to `su 2000 -c ...`).

### Light/Dark Theme *(v0.7.0)*

The WebUI ships an AMOLED-dark palette by default. A toggle button flips
`document.documentElement.dataset.theme` to `light`, activating a light palette defined via CSS
custom properties. The preference persists in `localStorage`. This is implemented as an offline
addon injected via `webroot/index.html` without modifying the bundled JS/CSS.

---

## File Layout

```
dnscrypt-proxy-root/
├── META-INF/                    # Magisk installer metadata
├── .github/
│   ├── upstream-version         # Separately tracked dnscrypt-proxy version
│   └── workflows/               # CI/CD automation
│       ├── auto-update.yml      # Scheduled upstream check
│       ├── release.yml          # Validated module-version release
│       └── test.yml             # dash/BusyBox ash tests and ShellCheck
├── config/
│   └── dnscrypt-proxy.toml      # Packaged default template
├── scripts/
│   ├── common.sh                # Shared utilities
│   ├── dnscrypt-control.sh      # Service control & WebUI API
│   ├── update-dnscrypt.sh       # Binary updater
│   └── watchdog.sh              # Single-instance health/recovery loop
├── tests/                        # POSIX sh updater regression suite and mocks
├── webroot/                     # WebUI static files
│   ├── index.html
│   ├── icon.svg
│   ├── addons/                  # Offline addons: leak test + theme toggle (v0.7.0)
│   └── assets/                  # JS/CSS bundles
├── module.prop                  # Module metadata
├── customize.sh                 # Installation script
├── service.sh                   # Boot-time service start
├── post-fs-data.sh              # Early-boot hook (no iptables; see service.sh)
├── action.sh                    # Action button handler
├── uninstall.sh                 # Cleanup on removal
├── update.json                  # Magisk update descriptor
└── skip_mount                   # Skip system overlay
```

---

## Configuration

The packaged default template is at `<module_dir>/config/dnscrypt-proxy.toml`. After first boot,
the editable, root-only canonical configuration is
`/data/local/dnscrypt-proxy-root-runtime/config/dnscrypt-proxy.toml`; the daemon reads a generated,
read-only execution snapshot. Use the WebUI to edit the canonical configuration, or edit that
persistent path as root. The module template only seeds a newly created runtime tree. Key settings:

- **listen_addresses**: `127.0.0.1:5354`
- **server_names**: `cloudflare`, `quad9-dnscrypt-ip4-filter-pri`
- **require_dnssec**: `true`
- **require_nolog**: `true`
- **query_log**: Enabled (TSV format, used by Stats page)
- **blocked_names/allowed_names**: File-based filtering

Edit via the WebUI Config tab or manually with a text editor.

---

## Supported Architectures

| Architecture | Asset Name |
|---|---|
| arm64-v8a | `android_arm64` |
| armeabi-v7a | `android_arm` |
| x86_64 | `android_x86_64` |
| x86 | `android_i386` |

---

## Troubleshooting

- **Binary not found**: Tap "Force Update" in WebUI or use the action button
- **DNS not working**: Check if iptables rules are applied (Overview → status)
- **Service won't start**: Check Logs tab for error messages
- **WebUI not showing**: Ensure your manager supports WebUI (KernelSU 0.7.0+ / APatch)

---

## Known Limitations

- **Encrypted IPv6 DNS is not yet supported.** dnscrypt-proxy is configured to listen on
  IPv4 only (`127.0.0.1:5354`); to prevent leaks, plaintext IPv6 DNS (port 53) is *blocked*
  rather than redirected. In `strict` mode, clients must support and use IPv4 DNS fallback;
  DNS queries from an IPv6-only client otherwise fail.
- **Requires iptables NAT support.** A small number of heavily stripped custom ROMs ship
  kernels without NAT/`route_localnet`, where transparent redirection cannot work.
- DNS redirection only covers port 53 (Do53). Apps that hardcode their own DoH/DoT endpoints
  (e.g. some browsers) bypass the system resolver by design and are not affected.
- `strict` mode owns only the module's OUTPUT-chain jumps and dedicated chains. It does not claim
  PREROUTING/tethered-client traffic or provide product-specific VPN/fake-IP/TUN exemptions.
- `upstream_only` deliberately provides no system-wide interception or generic leak verdict.
- SELinux execution/access behavior and root-manager lifecycle compatibility for the persistent
  `/data/local` runtime copy remain **NOT RUN** on Magisk, KernelSU, and APatch, including the Xiaomi
  14T Pro / Android 16 reference environment. No compatibility claim is made for those combinations.
- Real-device validation on Xiaomi 14T Pro / Android 16 and interoperability testing with specific
  VPN products remain manual acceptance items; CI covers portable shell behavior, not those stacks.
  Use the [real-device acceptance matrix](REAL_DEVICE_ACCEPTANCE.md), whose v0.9.1 rows are explicitly
  marked **NOT RUN**, before making any device or VPN compatibility claim.

---

## Changelog

### v0.9.1 (2026-09-07)

- Recognizes dnscrypt-proxy 2.1.18's exact optional `-child` exec form and separately verifies the
  UID-3003 TCP/UDP listener sockets, locally synthesized NXDOMAIN response, and upstream reachability.
- Runs the daemon and `-check` as UID 3003 from disposable snapshots in a marked, permission-checked
  persistent `/data/local/dnscrypt-proxy-root-runtime` copy; root-only canonical inputs,
  UID-3003-readable execution snapshots, and mutable data are separated. Unsafe or unmarked
  collisions fail closed and uninstall deletes only the verified owned tree.
- Adds transactional `strict` and `upstream_only` integration modes, bounded source/cache preflight
  plus upstream-compatible NetProbe grace, degraded/offline reporting, and capped watchdog backoff
  that preserves a healthy daemon during outages.
- Uses token-bound current-boot ownership/adoption markers and exact ordered rule checks so
  unproven same-name or direct third-party firewall rules are preserved; applies strict redirection
  only after readiness.
- Replaces quick-mode in-place `sed` edits with a staged, conservative TOML rewrite, proxy
  validation, atomic install, and restart rollback; root-only canonical inputs and disposable
  UID-3003 snapshots isolate the control plane from daemon-writable data.
- Expands dash/BusyBox ash lifecycle, updater, socket, mode, firewall, and TOML regression coverage.
- Resets v0.9.0-and-older configuration that does not meet the new migration-provenance boundary;
  export first, reboot, then re-apply it.

### v0.9.0 (2026-08-29)

- Fixed all confirmed backup, subscription, IPv6 firewall, resolver timing, watchdog, base64,
  import, download fallback, resource-path, log-path, and resolver-list issues from the v0.8 audit.
- Hardened exact PID ownership, DNS/firewall readiness, Android Private DNS restoration, staged
  upgrade migration, disable/uninstall shutdown, and the dedicated AID_INET runtime identity.
- Made upstream archive verification mandatory and fail-closed; added executable/config validation,
  transactional restart, and explicit rollback state handling.
- Made WebUI command failures visible, list writes atomic, and query statistics conform to the
  official TSV return-code fields instead of displaying false successes or demo telemetry.
- Revalidated KernelSU/APatch metadata, ZIP layout, lifecycle scripts, permissions, WebUI bridge,
  and Markdown update descriptor; expanded dash/BusyBox ash and JavaScript CI coverage.

See [CHANGELOG.md](CHANGELOG.md) for the complete changelog, including v0.9.1.

### v0.8.0 (2026-08-18)

- Separated module `vX.X.X` releases from the independently tracked upstream dnscrypt-proxy version.
- Fixed update throttling so failed or malformed metadata requests can be retried immediately.
- Made updater locking crash-safe with kernel `flock`, including BusyBox fallback and legacy-lock migration.
- Clarified that the optional checksum comparison is not Minisign authentication and remains best-effort.
- Added POSIX `sh` updater coverage under dash and BusyBox ash, plus ShellCheck and GitHub Actions CI.
- Standardized Traditional Chinese domain terminology in the README and WebUI.
- Existing installations pinned to the immutable `v0.7.0` update descriptor must install `v0.8.0` manually once; this release switches future checks to a stable descriptor URL.

### v0.7.0 (2026-07-23)

**New features**
- **DNS path sample test**: new `leak-test` command and a WebUI button that resolves random
  subdomains through the system DNS path and reports which samples appear in the query log. The
  legacy protected/partial/leaking status names do not prove every DNS path is encrypted.
- **Service watchdog + Android notifications**: `service.sh` monitors the daemon every 60s,
  auto-restarts it once on an unexpected stop, and notifies via `cmd notification post`
  (capped at 3 notifications per boot, with a user-stop marker to avoid false alarms). Successful
  binary updates now also notify.
- **Light/Dark theme toggle**: a WebUI toggle button with `localStorage` persistence, defaulting to
  the AMOLED-dark palette.

**Implementation notes**
- WebUI additions are injected as offline addons under `webroot/addons/` without touching the
  minified bundle, and are compatible with both KernelSU and APatch WebUI `ksu.exec` conventions.
- All shell additions preserve `set -u` / busybox / toybox compatibility (no bash-only syntax,
  no `bc`).
- Added `README.zh-TW.md` and `README.zh-CN.md` with a language switcher across all three READMEs.

### v0.6.0 (2026-06-26)

**Security fixes**
- Fixed a WebUI command-injection vector by validating all user-supplied input (H3)
- Removed the third-party analytics remote script from the WebUI (H4)
- Added a best-effort SHA256 comparison of the downloaded dnscrypt-proxy archive against a checksum
  list from the same release. The list is not signature-authenticated, and unavailable checksum data
  does not block installation.
- Proactively wipe DNS query logs on uninstall to protect privacy

**Functionality fixes**
- Fixed DNAT to `127.0.0.1` being silently dropped — `route_localnet=1` is now enabled,
  without which redirection failed completely (H1)
- Fixed the iptables exclusion logic that let app DNS bypass the proxy; switched from
  `--uid-owner 0` to an upstream-IP whitelist (H2)
- Removed premature iptables setup in `post-fs-data.sh` that created an early-boot DNS
  blackhole before the proxy was listening (H5)
- Added ip6tables rules to block plaintext IPv6 DNS leakage (H6)
- Fixed the WebUI failing to load its JavaScript bundle (blank UI) by referencing the
  built entry script in `index.html`, and removed orphaned/unused build assets
- Hardened query/protocol statistics counting so an empty match no longer produces
  malformed JSON

**Compatibility improvements**
- Block-rate calculation uses `awk` instead of `bc` (unavailable on Android)
- `grep` patterns use `-E` for toybox compatibility
- Process management prefers the PID file and no longer depends on `pgrep -x`
- Subscription JSON parsing is now object-by-object for robustness
- Improved `date +%N` fallback for toybox

**Other**
- Limit config backups to the 5 most recent
- Corrected the README auto-update cron description and the DNS-redirection explanation

---

## Credits

- [dnscrypt-proxy](https://github.com/dnscrypt/dnscrypt-proxy) by Frank Denis
- [dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) for reference
- [KernelSU](https://kernelsu.org) / [APatch](https://apatch.dev) for WebUI framework

---

## License

This module is provided as-is under the MIT License. The dnscrypt-proxy binary is distributed under its own license (ISC).
