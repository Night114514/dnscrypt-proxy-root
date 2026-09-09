# Third-party notices

This distribution contains or installs the components below. The repository's
MIT license applies only to material for which the project has the right to
offer that license. Third-party components remain under their own terms.

## Magisk module installer

- Distributed file: `META-INF/com/google/android/update-binary`
- Upstream project: Magisk, <https://github.com/topjohnwu/Magisk>
- Source revision: `37063225d4f344a8f41de8201f679e57098cb7e6`
- Upstream path: `scripts/module_installer.sh`
- Git blob identity: `28b48e580a9b605038bd3de15c5aba08d2258b14`
- Local modifications: none; the distributed file is a verbatim copy
- License: GNU General Public License version 3 (`GPL-3.0-only`)
- License text: `LICENSES/GPL-3.0-only.txt`

The preferred source form of the distributed installer is the shell script in
this repository at the path stated above. The pinned upstream revision is
provided so recipients can verify provenance and retrieve the surrounding
upstream source.

## dnscrypt-proxy

- Installed component: dnscrypt-proxy executable
- Upstream project: dnscrypt-proxy, <https://github.com/DNSCrypt/dnscrypt-proxy>
- Tracked release for v0.9.2: `2.1.18`
- Distribution boundary: the executable is not included in the module ZIP; the
  installer/updater downloads the matching official release asset on device
- License: ISC
- License text: `LICENSES/ISC-dnscrypt-proxy.txt`

The module's updater verifies the upstream asset digest published with the
release before installing it. An upstream checksum authenticates consistency
with that release channel; it is not an independent project signature.

## WebUI

The v0.9.2 WebUI under `webui/src/` and its deterministic output under
`webroot/` use browser platform APIs only. The package manifest has no runtime
or development dependencies, and the release does not contain the former
React, Recharts, Lucide, or object-assign bundle.
