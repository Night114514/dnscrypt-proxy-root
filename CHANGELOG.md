# Changelog

## v0.9.1 (2026-09-07)

> **Upgrade warning:** Before flashing over v0.9.0 or older, export or record configuration, lists,
> and subscriptions. The v0.9.1 installer intentionally replaces those inputs with audited defaults
> because their layouts do not meet the hardened migration-provenance boundary; reboot, then
> re-apply the desired settings. Direct upgrades from v0.6.0 through v0.8.0 must reboot to clear
> indistinguishable legacy per-boot IPv6 rules safely.

### Local health and lifecycle

- Add a persistent, copy-based canonical execution tree at
  `/data/local/dnscrypt-proxy-root-runtime`; no bind mount or mount-namespace dependency is used.
  Its root and `bin` are `root:root 0755`; canonical `config` is `root:root 0700` with managed inputs
  at `root:root 0600`; the disposable `active` snapshot is `3003:root 0500` with five inputs at
  `3003:root 0400`; mutable cache/query data is under `3003:root 0700`; and the UID-3003 PID handshake
  is mode `0600`. The root-only `0600` `.layout-owner` marker is exactly one LF-terminated line,
  `dnscrypt-proxy-root:5`. The `/data/adb` module supplies audited templates and, when its installer
  download succeeds, a digest/version-verified binary. A missing staged binary is recovered through
  the same verified download path before first-boot daemon startup.
- Launch the daemon and every real `-check` directly as numeric UID 3003 from a disposable runtime
  configuration that omits `user_name`. Root never asks upstream code to parse that runtime input,
  and the process never has to traverse the root-only `/data/adb` path. Lifecycle matching continues
  to accept only the exact parent or optional upstream `-child` argv. Existing unmarked, symlinked,
  or unsafe runtime collisions fail closed; uninstall deletes only the exact marked tree after
  durable create/remove transaction recovery and full revalidation.
- Accept the exact optional `-child` argument used when dnscrypt-proxy 2.1.18 re-execs after
  privilege setup, while still rejecting one-shot commands and all extra arguments. Status, stop,
  watchdog, uninstall, and binary-update restart/rollback now retain ownership of the live child.
- Define readiness as the exact canonical runtime daemon running under Android AID_INET UID 3003, owning
  both the TCP LISTEN and UDP bound sockets at `127.0.0.1:5354`, and returning the exact locally
  synthesized NXDOMAIN frame for a bounded, upstream-independent Firefox-canary query. Socket inodes
  are correlated from `/proc/net/{tcp,udp}` to `/proc/<pid>/fd`; status exposes listener ownership,
  local DNS functionality, and upstream resolution as separate signals.
- Preflight the real 2.1.18 configuration and resolver sources with `-check` while global DNS stays
  fail-open, with a 660-second hard limit covering the default source/signature fetch budget. Then
  apply the upstream NetProbe semantics exactly (`0` skips, negative values map to 3600 seconds,
  positive values cap at 3600, and TOML decimal separators are accepted) plus a 30-second listener
  stabilization margin. Policy is never installed before this bounded initialization succeeds.
  Module disable, removal, or shutdown cancels both an in-flight preflight and the later listener
  readiness wait immediately instead of waiting for their full timeouts.
- Record upstream reachability as online/offline and report an otherwise healthy local service as
  degraded during flight mode, Wi-Fi loss, or resolver outages. The watchdog does not restart for
  those upstream-only failures and suppresses false alerts during the bounded starting state.
- Expose distinct cold-start failure states for configuration errors, missing resolver source/cache
  data, early process exit, listener timeout, cleanup failure, and policy installation failure.
  The upstream `Missing cache file for source` message is correctly treated as a missing TOML key,
  while `Unable to retrieve source [...]` is treated as unavailable source/cache data. Successful
  recovery and intentional stop clear the previous failure.
- Add capped watchdog recovery backoff (60, 120, 240, 480, then 900 seconds by default). Healthy
  recovery, an intentional stop, a starting daemon, and concurrent manual control reset the delay;
  a healthy local daemon with an offline upstream is still never restarted.

### DNS integration policies and firewall ownership

- Add root-only, exactly parsed `strict` and `upstream_only` integration modes. Missing state
  defaults to the historical `strict` behavior; malformed, multiline, CRLF, symlinked, or
  non-regular state fails closed and is never sourced as shell input.
- Make live mode changes transactional and commit the mode state last. Switching modes preserves
  the daemon PID, rolls policy back on failure, and never starts a daemon that was already stopped.
- In `strict`, save/disable Android Private DNS and install module-owned IPv4 redirection and IPv6
  plaintext-DNS blocking only after local readiness. In `upstream_only`, expose only
  `127.0.0.1:5354`, restore Private DNS, restore `route_localnet`, and leave global firewall policy
  to the user's VPN or DNS frontend.
- Stop deleting indistinguishable direct IPv6 `REJECT` rules. Apply/remove/health manage fixed-name
  chains only when a random generation token is present in both chains and in a current-boot,
  root-only ownership marker. Exact v0.9.0 chains may be adopted only when the installer also
  produced a current-boot marker from a trusted old `module.prop`; other same-name or replacement
  chains are preserved and strict mode fails closed. Strict health verifies the complete ordered
  chain shape, OUTPUT jump order, loopback exemption, and `route_localnet=1`.
- Releases v0.6.0 through v0.8.0 used generic direct IPv6 `REJECT` rules whose individual ownership cannot
  be distinguished from identical VPN/firewall rules. A trusted legacy install records a reboot
  requirement, but v0.9.1 deliberately does not delete those rules in place; the required
  module-manager reboot clears the per-boot netfilter state safely.
- Return `not_applicable` from the sampled system-DNS log-visibility test in `upstream_only`, where
  the module does not claim system-wide interception. Its legacy result names remain API-compatible,
  while the WebUI now states that samples cannot prove all DNS paths or app-owned DoH/DoT behavior.

### Configuration safety and verification

- Replace quick-mode's in-place `sed` sequence with a conservative POSIX-AWK TOML lexer/rewriter.
  It scopes owned keys to the root table, recognizes whitespace-prefixed table boundaries, ignores
  header-like text inside quoted strings, preserves nested same-name keys and unrelated bytes, and
  rejects missing, duplicate, multiline, commented, or ambiguous owned syntax.
- Stage and validate a preset beside the live TOML with dnscrypt-proxy `-check`, preserving relative
  cache/list paths; back up the original, atomically install the candidate, and restore/restart the
  byte-identical old config if the new daemon fails to start. A failed rollback is reported as
  `rollback_failed` instead of being presented as a successful restore.
- Keep the canonical TOML, managed lists, and optional subscriptions in a root-only `0700`
  directory at mode `0600`. Publish only a disposable, UID-3003-owned read-only execution snapshot;
  keep mutable caches and query/NX logs in a separate UID-3003-owned `0700` data directory and the
  main service log root-only. Same-directory stage, backup and restore files use `mktemp`/O_EXCL and
  are revalidated by regular-file, symlink, owner, mode and device/inode identity checks before
  validation and atomic commit.
- Fail closed at every control, boot-service, and downloaded-binary validation entry when the canonical
  TOML, four managed lists, or optional subscriptions file has an unsafe type, owner, group, or
  mode. Query/NX-log diagnostics create bounded snapshots under UID 3003 before root parses them;
  root never follows the daemon-controlled source pathname after validation. Every real `-resolve`
  diagnostic runs as UID 3003 against a disposable snapshot, and interactive local, direct, and
  system-resolver diagnostic commands now have hard timeouts.
- Do not automatically copy configuration, lists, or subscriptions from v0.9.0 and older. v0.9.0
  made the source directory writable by UID 3003, so a compromised old daemon could pre-seed
  root-opened log/TLS-key paths or race migration; earlier layouts do not carry the new hardened
  provenance. Upgrades install audited defaults and explicitly require operators to export/record
  settings before flashing and re-apply them after reboot. Only exact root-owned state from an
  already hardened layout is eligible for migration.
- During root-manager staging, verify the downloaded release-asset digest and reported binary version,
  but defer the configuration/source `-check` until first boot creates the traversable canonical
  runtime tree. Normal on-device updates continue to validate candidates against the live runtime
  configuration before commit.
- Route save-config, resolver changes, quick modes, imports, cold-start preflight, and downloaded
  binary compatibility checks through a common 660-second-capped, shutdown-cancellable `-check`.
  Missing validators fail closed, and TERM-to-KILL escalation revalidates the full NUL-delimited
  parent/child argv immediately before SIGKILL to protect against PID reuse.
- Extend dash and BusyBox ash coverage for the upstream child argv, UID/socket/handler readiness, exact
  mode-state parsing, live and stopped mode transitions, commit failure rollback, startup ordering,
  real 2.1.18 source-error text, NetProbe boundaries, token-bound firewall generations and
  third-party preservation, managed-input/log symlinks, TOML boundaries/idempotence,
  symlink/inode replacement, restart rollback, and watchdog backoff/reset.

### Validation scope

- Portable shell syntax, ShellCheck, updater/control harnesses, WebUI bridge invariants, metadata,
  and runtime-only ZIP layout are automated. Xiaomi 14T Pro / Android 16 and named VPN/fake-IP/TUN
  combinations remain manual real-device acceptance items and are not claimed as CI coverage; the
  shipped real-device matrix marks every v0.9.1 scenario `NOT RUN` until evidence is recorded.
- SELinux execution/access behavior and lifecycle compatibility of the persistent `/data/local`
  runtime tree remain `NOT RUN` on Magisk, KernelSU, and APatch, including the Xiaomi 14T Pro /
  Android 16 reference environment. v0.9.1 makes no compatibility claim for those combinations.

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
