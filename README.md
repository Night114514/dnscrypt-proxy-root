# DNSCrypt Proxy Root WebUI Module

A systemless Magisk/KernelSU/APatch module that runs **dnscrypt-proxy** on rooted Android devices with:

- **Automatic binary updates** from upstream releases
- **WebUI** for KernelSU/APatch managers (configuration, logs, statistics)
- **Multi-language support** (English, 繁體中文, 简体中文)
- **DNS query statistics** dashboard
- **Blocklist/Allowlist** graphical management
- **iptables-based DNS redirection** (all device DNS → dnscrypt-proxy)
- **GitHub Actions CI/CD** for automatic module releases

---

## Installation

1. Download the latest `dnscrypt-proxy-root-vX.X.X.zip` from [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases).
2. Flash via **Magisk Manager**, **KernelSU Manager**, or **APatch Manager**.
3. Reboot.

The module will automatically download the correct dnscrypt-proxy binary for your device architecture during installation.

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

The module uses iptables NAT rules to redirect all outgoing DNS queries (port 53) to `127.0.0.1:5354` where dnscrypt-proxy listens. The proxy's own UID is excluded to prevent loops, and loopback destinations (127.0.0.0/8) are also excluded since dnscrypt-proxy itself listens there.

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
├── post-fs-data.sh              # Early iptables setup
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
- **WebUI not showing**: Ensure your manager supports WebUI (KernelSU 0.6.6+ / APatch)

---

## Credits

- [dnscrypt-proxy](https://github.com/dnscrypt/dnscrypt-proxy) by Frank Denis
- [dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) for reference
- [KernelSU](https://kernelsu.org) / [APatch](https://apatch.dev) for WebUI framework

---

## License

This module is provided as-is under the MIT License. The dnscrypt-proxy binary is distributed under its own license (ISC).
