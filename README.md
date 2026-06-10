# DNSCrypt Proxy Root Module

A Magisk / KernelSU / APatch module that runs **dnscrypt-proxy** as a system-level encrypted DNS resolver on rooted Android devices. It features **automatic binary updates** from the official upstream releases and a built-in **WebUI** for configuration management.

---

## Features

- **Cross-Manager Compatibility** — Works with Magisk (v20.4+), KernelSU, and APatch.
- **Automatic Updates** — On every boot, the module checks for new dnscrypt-proxy releases on GitHub and updates the binary in-place. Rate-limited to once per 24 hours.
- **WebUI** — KernelSU and APatch managers display a built-in web interface for controlling the service, editing the TOML configuration, viewing logs, and triggering manual updates.
- **iptables DNS Redirection** — Transparently redirects all device DNS traffic (port 53) to the local dnscrypt-proxy listener.
- **Architecture Auto-Detection** — Supports arm64, arm, x86, and x86_64 devices.
- **Action Button** — In managers that support it, the action button toggles the service on/off.

---

## Installation

1. Download the latest release ZIP from the [Releases](https://github.com/user/dnscrypt-proxy-root/releases) page.
2. Flash via your root manager:
   - **Magisk**: Modules → Install from storage → select ZIP
   - **KernelSU**: Module → Install → select ZIP
   - **APatch**: Module → Install → select ZIP
3. Reboot.

On first install, the module will attempt to download the latest dnscrypt-proxy binary. An internet connection is required.

---

## WebUI (KernelSU / APatch)

After installation, open the module's WebUI from the KernelSU or APatch manager. The interface provides:

| Tab | Function |
|-----|----------|
| **Overview** | Service status, PID, version, device info, start/stop/restart controls |
| **Config** | Full TOML editor with save, validate, and restart integration |
| **Logs** | Real-time log viewer with auto-refresh and color-coded severity |
| **Update** | Version comparison, one-click update, auto-update status |

---

## Configuration

The default configuration is stored at:

```
/data/adb/modules/dnscrypt-proxy-root/config/dnscrypt-proxy.toml
```

Key defaults:
- Listen address: `127.0.0.1:5354`
- Servers: `cloudflare`, `quad9-dnscrypt-ip4-filter-pri`
- DNSSEC required: `true`
- No-log required: `true`
- IPv6: disabled (to avoid leaks on IPv4-only networks)

You can edit this file via the WebUI or directly on the filesystem.

---

## Auto-Update Mechanism

The module checks for new upstream releases at:
- Every device boot (after `sys.boot_completed`)
- Manually via the WebUI "Update" tab
- Via the action button (if configured)

The update process:
1. Queries the GitHub Releases API for the latest tag.
2. Compares with the locally installed version.
3. Downloads the architecture-appropriate release ZIP.
4. Extracts and replaces the binary atomically (with backup).
5. Restarts the service if it was running.

---

## File Structure

```
/data/adb/modules/dnscrypt-proxy-root/
├── META-INF/             # Magisk flashable ZIP metadata
├── bin/                  # dnscrypt-proxy binary (auto-downloaded)
├── config/               # TOML config + filter lists
├── logs/                 # Service, update, and control logs
├── run/                  # PID file, version tracking, update status
├── scripts/
│   ├── common.sh         # Shared utility functions
│   ├── dnscrypt-control.sh  # Service control & WebUI API
│   └── update-dnscrypt.sh   # Upstream binary updater
├── webroot/              # WebUI static assets
├── customize.sh          # Installation script
├── post-fs-data.sh       # Early boot DNS redirection
├── service.sh            # Late boot service start + auto-update
├── action.sh             # Action button handler
├── uninstall.sh          # Cleanup on removal
├── module.prop           # Module metadata
└── skip_mount            # Prevent systemless overlay (not needed)
```

---

## Troubleshooting

- **Binary not downloaded**: Ensure internet is available. Check `logs/update.log`.
- **DNS not working**: Verify iptables rules with `iptables -t nat -L OUTPUT`.
- **Service won't start**: Check `logs/service.log` and `config/dnscrypt-proxy.log`.
- **WebUI not showing**: Ensure you're using KernelSU v0.6.0+ or APatch with WebUI support.

---

## Credits

- [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) by the DNSCrypt project
- [dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) for reference
- [KernelSU WebUI Module Template](https://github.com/pzqqt/ksu-webui-module-template) for WebUI integration patterns

---

## License

This module is provided as-is under the MIT License. The dnscrypt-proxy binary is distributed under its own license (ISC).
