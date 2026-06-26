# DNSCrypt Proxy Root WebUI Module

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
- **GitHub Actions CI/CD** for automatic module releases

---

## Requirements

- Android 7.0+ (API 24+)
- One of: **Magisk 20.4+**, **KernelSU 0.7.0+**, or **APatch 10596+**
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
| **DNS Test** | Test domain resolution through dnscrypt-proxy vs direct DNS, compare latency |
| **Resolvers** | Graphical DNS server selector with protocol/feature badges |
| **Logs** | Real-time service and query logs |
| **Update** | Check and install upstream binary updates |

The WebUI supports **English**, **繁體中文**, and **简体中文** with automatic detection based on system language.

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

### CI/CD Auto-Update (GitHub Actions)

A scheduled workflow runs monthly (on the 1st of each month, and on demand via `workflow_dispatch`):

1. Checks upstream dnscrypt-proxy releases
2. If a new version is detected, updates `module.prop` and `update.json`
3. Builds a new module ZIP
4. Creates a GitHub Release with the updated assets

This enables Magisk's built-in module updater to notify users of new module versions.

---

## File Layout

```
dnscrypt-proxy-root/
├── META-INF/                    # Magisk installer metadata
├── .github/workflows/           # CI/CD automation
│   ├── auto-update.yml          # Scheduled upstream check
│   └── release.yml              # Tag-triggered release
├── config/
│   └── dnscrypt-proxy.toml      # Default configuration
├── scripts/
│   ├── common.sh                # Shared utilities
│   ├── dnscrypt-control.sh      # Service control & WebUI API
│   └── update-dnscrypt.sh       # Binary updater
├── webroot/                     # WebUI static files
│   ├── index.html
│   ├── icon.svg
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

### v0.6.0 (2026-06-26)

**Security fixes**
- Fixed a WebUI command-injection vector by validating all user-supplied input (H3)
- Removed the third-party analytics remote script from the WebUI (H4)
- Added SHA256 verification of the downloaded dnscrypt-proxy binary against the upstream
  signed checksum list
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
