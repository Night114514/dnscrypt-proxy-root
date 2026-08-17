# DNSCrypt Proxy Root WebUI Module

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

A systemless Magisk/KernelSU/APatch module that runs **dnscrypt-proxy** on rooted Android devices with:

- **Systemless encrypted DNS** via dnscrypt-proxy (DNSCrypt / DoH)
- **Works on Magisk, KernelSU, and APatch**
- **Automatic DNS redirection** for all apps via iptables DNAT (transparent, no per-app setup)
- **IPv6 DNS leak protection** — plaintext DNS over IPv6 is blocked with ip6tables
- **DNSSEC + NOLOG resolver filtering** (`require_dnssec` / `require_nolog`)
- **Automatic binary updates** from upstream releases
- **WebUI** for KernelSU/APatch managers (configuration, logs, statistics)
- **Custom blocklist subscriptions** with safe URL validation
- **Multi-language support** (English, 繁體中文, 简体中文)
- **DNS query statistics** dashboard
- **Blocklist/Allowlist** graphical management
- **DNS Leak Test** — verify your DNS traffic actually passes through dnscrypt-proxy *(v0.7.0)*
- **Service watchdog with Android notifications** — auto-restart and notify if the service stops unexpectedly *(v0.7.0)*
- **Light/Dark theme toggle** in the WebUI *(v0.7.0)*
- **GitHub Actions CI/CD** for automatic module releases

---

## Requirements

- Android 7.0+ (API 24+)
- One of: **Magisk 20.4+**, **KernelSU 0.7.0+**, or **APatch 10596+**
- The updater requires `flock` (provided by Android 7+ Toybox, with a root-manager BusyBox fallback)
- A device whose kernel supports **iptables NAT** (the case on the vast majority of devices)
- The WebUI management interface requires KernelSU or APatch (Magisk has no WebUI; on Magisk
  the action button toggles the service instead)

---

## Installation

1. Download the latest `dnscrypt-proxy-root-vX.X.X.zip` from [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases).
2. Flash via **Magisk Manager**, **KernelSU Manager**, or **APatch Manager**.
3. Reboot.

The module will automatically download the correct dnscrypt-proxy binary for your device
architecture during installation.

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

### DNS Redirection

- dnscrypt-proxy listens on `127.0.0.1:5354`.
- An iptables NAT chain (`DNSCRYPT_PROXY`) in the `OUTPUT` chain DNATs all outgoing
  plaintext DNS queries (UDP/TCP port 53) to `127.0.0.1:5354`.
- `net.ipv4.conf.all.route_localnet=1` is enabled so the kernel does not drop packets
  DNAT'd to the loopback address from the `OUTPUT` chain (without this the redirection
  fails completely).
- Upstream resolver IPs (Cloudflare `1.1.1.1`/`1.0.0.1`, Quad9 `9.9.9.9`/`149.112.112.112`)
  and the `127.0.0.0/8` loopback range are excluded with `RETURN` rules so bootstrap and
  netprobe traffic is not redirected back into the proxy, avoiding a resolution loop.
  Exclusion is done **by destination IP**, not by UID — using `--uid-owner 0` is wrong on
  Android because `netd` (the system DNS proxy) also runs as root, which would let app DNS
  bypass the proxy entirely.
- Because dnscrypt-proxy only listens on IPv4, plaintext DNS over IPv6 (port 53) is blocked
  with `ip6tables` `REJECT` rules to prevent unencrypted IPv6 DNS leakage.

### skip_mount

The `skip_mount` file is intentionally present because this module does **not** overlay any system partition files. All components (binary, config, webroot) reside within the module directory and operate as a standalone daemon with iptables redirection. Skipping the mount phase avoids unnecessary overhead.

### Auto-Update (On-Device)

On each boot, `service.sh` triggers a background update check:

1. Queries the GitHub API for the latest dnscrypt-proxy release
2. Compares with the currently installed version
3. If newer, downloads the architecture-specific asset
4. Extracts and atomically replaces the binary
5. Updates module metadata

The check is rate-limited to once per 24 hours (configurable via `DNSCRYPT_UPDATE_INTERVAL_SECONDS`).
The rate-limit timestamp is recorded only after the release metadata has been downloaded and a
non-empty release tag has been parsed, so network and metadata-format failures can be retried on the
next invocation.

The updater also attempts a best-effort SHA256 comparison using `minisign.txt` downloaded from the
same release. It does **not** authenticate that checksum list with Minisign or a pinned signing key.
An actual hash mismatch aborts the update, but installation continues if the list cannot be
downloaded, the asset has no entry, or no hash can be calculated. This comparison can detect
accidental corruption when checksum data is available; it does not authenticate the publisher.

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
4. Reports a verdict as single-line JSON:
   - `protected` — all 4 appeared in the log; DNS traffic is going through dnscrypt-proxy.
   - `partial` — some appeared; possible partial leak.
   - `leaking` — none appeared; DNS traffic is bypassing dnscrypt-proxy.

If the query log is disabled it returns `{"status":"error","reason":"query_log_disabled"}` and the
WebUI prompts you to enable it. No remote services are contacted — the test is fully local.

### Service Watchdog & Notifications *(v0.7.0)*

`service.sh` starts a background watchdog that checks the service every 60 seconds:

- If dnscrypt-proxy stops **unexpectedly** (i.e. not via a user-initiated stop — tracked with a
  `run/user_stopped` marker file), it posts an Android notification and **auto-restarts the service
  once**. On successful recovery it posts a "service recovered" notification.
- Notifications are capped at **3 per boot** so a crash loop cannot spam the status bar.
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
│   └── dnscrypt-proxy.toml      # Default configuration
├── scripts/
│   ├── common.sh                # Shared utilities
│   ├── dnscrypt-control.sh      # Service control & WebUI API
│   └── update-dnscrypt.sh       # Binary updater
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

The default configuration is at `<module_dir>/config/dnscrypt-proxy.toml`. Key settings:

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
  rather than redirected. Apps that are IPv6-only for DNS will fall back to IPv4.
- **Requires iptables NAT support.** A small number of heavily stripped custom ROMs ship
  kernels without NAT/`route_localnet`, where transparent redirection cannot work.
- DNS redirection only covers port 53 (Do53). Apps that hardcode their own DoH/DoT endpoints
  (e.g. some browsers) bypass the system resolver by design and are not affected.

---

## Changelog

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
- **DNS Leak Test**: new `leak-test` command and a WebUI button that resolves random subdomains
  through the system DNS path and checks the query log to confirm traffic is encrypted
  (protected / partial / leaking verdict).
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
