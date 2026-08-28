# Changelog

## v0.9.0 (2026-08-29)

### Reliability and Android lifecycle

- Fixed configuration-backup pruning so only the five newest backups are retained.
- Reworked subscription merging around an explicit managed section. Updating or disabling a subscription now removes stale generated entries without consuming user-maintained rules, and a failed download leaves the previous list untouched.
- Made IPv4 and IPv6 firewall installation idempotent, removed duplicate legacy rules, verified every required rule, and restored the pre-existing `route_localnet` value on stop.
- Replaced globally allowlisted plaintext-DNS destinations with a dedicated Android AID_INET (`3003`) owner exemption for dnscrypt-proxy itself.
- Added bounded readiness and health checks before claiming DNS protection, with automatic firewall repair if Android recreates its networking tables.
- Fixed exact PID validation so control scripts and reused PIDs cannot be mistaken for dnscrypt-proxy.
- Added a single-instance watchdog with tracked shutdown, independent notification throttling, repeated recovery attempts, and clean disable/uninstall handling.
- Preserve user configuration and list inputs across KernelSU/APatch staged module upgrades while excluding runtime files, resolver caches, and privacy-sensitive logs.
- Save the original Android Private DNS mode/provider before starting and restore it on stop, disable, failed start, or uninstall.

### Configuration, subscriptions, and diagnostics

- Added portable standalone/BusyBox base64 fallbacks for every import, export, subscription, and list operation.
- Empty lists in an imported backup now correctly clear existing lists.
- Added an atomic, validated `save-list-b64` control action used by the WebUI.
- Resolver lists now trim whitespace and reject empty or unsafe entries.
- Resolver latency reports now use dnscrypt-proxy's actual upstream startup probes instead of cached local lookups; non-portable `nslookup -port` usage was removed.
- The DNS leak test now follows the configured query/NX log paths and reports when the required log is disabled.
- Query statistics now parse the official TSV columns, count only `REJECT` and `DROP` return codes as blocked, escape JSON domain data, and return no data for unsupported log formats.

### Update and WebUI security

- Replaced the nonexistent, fail-open `minisign.txt` path with mandatory SHA-256 comparison against the exact GitHub release-asset digest. Missing, malformed, unavailable, or mismatched hashes now abort before extraction.
- Validate the downloaded executable's exact archive path, version, executable permission, and active configuration before atomically replacing the installed binary.
- Running services are restarted after an update; restart failure restores the previous binary and version state where possible, and failed installs do not start a 24-hour update cooldown.
- Control and updater transactions now share a validated inherited lock, preventing self-deadlock when a service start must recover a missing binary.
- WebUI shell failures now propagate through a checked exit-status bridge instead of being displayed as successes.
- WebUI list writes are atomic, failed subscription/resolver saves no longer show success, and real-device telemetry failures no longer fall back to fabricated demo data.
- Static resources use relative paths for compatibility with both official KernelSU/APatch WebUI roots and subdirectory/file-based hosts.

### Module and release quality

- Revalidated the ZIP layout, module metadata, lifecycle entry points, permissions, update descriptor, and WebUI structure against current KernelSU and APatch implementations.
- The update descriptor now points to raw Markdown instead of a GitHub HTML release page.
- Expanded dash and BusyBox ash regression coverage for control, firewall, subscription, updater, WebUI bridge, and lifecycle behavior.

## v0.8.0 (2026-08-18)

- Separated module `vX.Y.Z` releases from the independently tracked upstream dnscrypt-proxy version.
- Added crash-safe updater locking and dash/BusyBox ash CI coverage.
- Switched future installations to the stable latest-release update descriptor.

## v0.7.0 (2026-07-23)

- Added the DNS leak test, service watchdog notifications, and persistent WebUI theme selection.

## v0.6.0 (2026-06-26)

- Added the first transparent DNS-redirection, IPv6 leak-prevention, WebUI hardening, and update-integrity safeguards.
