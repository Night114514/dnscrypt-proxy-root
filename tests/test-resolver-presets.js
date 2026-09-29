// Integration test against the real upstream binary and signed resolver caches.
// DNSCRYPT_PROXY_TEST_BIN=/absolute/dnscrypt-proxy
// DNSCRYPT_RESOLVER_CACHE=/directory/with/{public-resolvers,relays,odoh-servers,odoh-relays}.md[.minisig]
// node tests/test-resolver-presets.js
// No daemon is started; -check and -list only validate configuration/selection.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const binary = process.env.DNSCRYPT_PROXY_TEST_BIN;
const cache = process.env.DNSCRYPT_RESOLVER_CACHE;
assert.ok(binary && path.isAbsolute(binary), 'Supply an absolute real dnscrypt-proxy binary');
assert.ok(cache && path.isAbsolute(cache), 'Supply signed official resolver caches');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'dnscrypt-presets-'));
try {
  fs.mkdirSync(path.join(work, 'config'));
  fs.cpSync(cache, path.join(work, 'data'), { recursive: true });
  for (const name of ['blocked-names', 'allowed-names', 'blocked-ips', 'allowed-ips']) {
    fs.writeFileSync(path.join(work, 'config', `${name}.txt`), '');
  }
  const source = fs.readFileSync(process.env.DNSCRYPT_CONTROL_TEST_SOURCE || path.join(root, 'scripts/dnscrypt-control.sh'), 'utf8');
  const writer = source.slice(source.indexOf('rewrite_quick_mode_toml()'), source.indexOf('\nquick_mode()'));
  assert.ok(writer.startsWith('rewrite_quick_mode_toml()'), 'Use the actual production preset writer');
  const helper = path.join(work, 'writer.sh');
  fs.writeFileSync(helper, `${writer}\nrewrite_quick_mode_toml "$1" "$2" "$3"\n`);
  // Isolated check snapshot: no privilege drop, no network probe or source fetch.
  // Resolver eligibility and preset fields remain exactly as shipped/generated.
  const template = fs.readFileSync(path.join(root, 'config/dnscrypt-proxy.toml'), 'utf8')
    .replace(/^user_name =.*\r?\n/m, '')
    .replace(/^netprobe_timeout =.*$/m, 'netprobe_timeout = 0')
    .replace(/^\s*urls =.*$/gm, '  urls = []');
  const input = path.join(work, 'config', 'input.toml');
  fs.writeFileSync(input, template);
  const invoke = (config, ...args) => execFileSync(binary, ['-config', config, ...args], { encoding: 'utf8', timeout: 30000 });
  const list = config => JSON.parse(invoke(config, '-list', '-json'));
  console.log(`Real upstream version: ${execFileSync(binary, ['-version'], { encoding: 'utf8' }).trim()}`);
  for (const mode of ['privacy', 'family', 'fastest']) {
    const config = path.join(work, 'config', `${mode}.toml`);
    execFileSync('dash', [helper, input, config, mode]);
    const text = fs.readFileSync(config, 'utf8');
    if (mode === 'privacy') {
      assert.match(text, /^server_names = \[\]$/m);
      assert.match(text, /^\s*skip_incompatible = true$/m);
    }
    invoke(config, '-check');
    const selected = list(config);
    assert.ok(selected.length > 0, `${mode} must select resolvers`);
    if (mode === 'privacy') {
      assert.ok(selected.every(s => s.proto === 'DNSCrypt' && s.dnssec && s.nolog), 'Privacy must filter protocol, DNSSEC and no-log properties');
      const relays = fs.readFileSync(path.join(work, 'data', 'relays.md'), 'utf8');
      for (const name of ['anon-cs-fr', 'anon-cs-de', 'anon-tiarap', 'anon-kama']) {
        assert.ok(relays.includes(`## ${name}\n`), `Retained relay ${name} must exist`);
      }
    }
    if (mode === 'family') {
      assert.deepEqual(selected.map(s => s.name).sort(),
        ['adguard-dns-family', 'cleanbrowsing-family', 'cloudflare-family'],
        'Family must select exactly the complete curated family set');
    }
    if (mode === 'fastest') {
      assert.match(text, /^ipv6_servers = false$/m);
      assert.deepEqual(selected.map(s => s.name).sort(), ['cloudflare', 'google', 'nextdns'],
        'Fastest without IPv6 must select exactly the complete IPv4 curated set');
      assert.ok(!selected.some(s => s.name === 'cloudflare-ipv6'), 'IPv6-only explicit name is excluded with ipv6_servers=false');
      fs.writeFileSync(config, text.replace('ipv6_servers = false', 'ipv6_servers = true'));
      const withIPv6 = list(config);
      assert.ok(withIPv6.some(s => s.name === 'cloudflare-ipv6' && s.ipv6), 'IPv6-only explicit name is included with ipv6_servers=true');
      assert.deepEqual(withIPv6.map(s => s.name).sort(), ['cloudflare', 'cloudflare-ipv6', 'google', 'nextdns'],
        'Fastest with IPv6 must select exactly the complete curated set');
      fs.writeFileSync(config, text.replace('doh_servers = true', 'doh_servers = false')
        .replace(/^server_names =.*$/m, "server_names = ['cloudflare', 'quad9-dnscrypt-ip4-filter-pri']"));
      assert.deepEqual(list(config).map(s => s.name), ['quad9-dnscrypt-ip4-filter-pri'], 'Protocol switches still filter explicit names');
      console.log('Explicit cloudflare-ipv6 excluded with ipv6_servers=false, included with true; protocol filtering retained.');
    }
    console.log(`${mode}: real -check and resolver selection PASS`);
  }
  // Each signed source must fail closed, including sources unused by a preset.
  for (const name of ['public-resolvers', 'relays', 'odoh-servers', 'odoh-relays']) {
    for (const suffix of ['md', 'md.minisig']) {
      const file = path.join(work, 'data', `${name}.${suffix}`);
      const original = fs.readFileSync(file);
      try {
        fs.writeFileSync(file, suffix === 'md' ? Buffer.concat([original, Buffer.from('\n# tampered\n')]) : 'invalid signature\n');
        const rejected = spawnSync(binary, ['-config', path.join(work, 'config', 'privacy.toml'), '-check'], {encoding: 'utf8', timeout: 30000});
        assert.ifError(rejected.error);
        assert.ok(Number.isInteger(rejected.status) && rejected.status !== 0, `${name}.${suffix} corruption must fail -check`);
      } finally {
        fs.writeFileSync(file, original);
      }
    }
  }
  console.log('Signed caches: all eight content/signature corruption cases rejected.');
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
