#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const exists = (relativePath) => fs.existsSync(path.join(root, relativePath));

const control = read('scripts/dnscrypt-control.sh');
assert.match(control, /^get_list\(\) \{/m,
  'v0.9.2 must read canonical lists through a validated backend command');
assert.match(control, /^config_apply_state\(\) \{/m,
  'v0.9.2 status must expose whether canonical inputs are pending application');
assert.match(control, /get-list\) get_list /,
  'the get-list backend function is not reachable from the command dispatcher');
assert.match(control, /"comparison_scope":"%s"/,
  'DNS diagnostics do not describe whether the comparison is policy-affected');
assert.match(control, /^subscriptions_json_to_pairs\(\) \{/m,
  'subscription payloads do not have a portable strict-schema parser');
assert.match(control, /canonical generation already has pending or unavailable changes/,
  'list apply does not refuse an unrelated pending generation before commit');

for (const sourcePath of [
  'webui/package.json',
  'webui/package-lock.json',
  'webui/build.mjs',
  'webui/src/index.html',
  'webui/src/bridge.js',
  'webui/src/app.js',
  'webui/src/styles.css',
]) {
  assert.ok(exists(sourcePath), `rebuildable WebUI source is missing: ${sourcePath}`);
}

const bridgeSource = read('webui/src/bridge.js');
assert.doesNotMatch(bridgeSource, /_test\s*:/,
  'production WebUI bridge exposes an internal raw-command test hook');

const webuiPackage = JSON.parse(read('webui/package.json'));
assert.deepEqual(webuiPackage.dependencies || {}, {},
  'the replacement WebUI must not add untracked runtime dependencies');
assert.deepEqual(webuiPackage.devDependencies || {}, {},
  'the deterministic WebUI build must not depend on an untracked toolchain');

const indexHtml = read('webroot/index.html');
assert.match(indexHtml, /\.\/assets\/bridge\.js/,
  'generated WebUI entry does not load the audited bridge');
assert.match(indexHtml, /\.\/assets\/app\.js/,
  'generated WebUI entry does not load the application');
assert.doesNotMatch(indexHtml, /index-CD85Tj2j|index-BRNBHrsZ|addons\//,
  'generated WebUI still references the unrebuildable legacy bundle');

const shippedJavaScript = fs.readdirSync(path.join(root, 'webroot', 'assets'))
  .filter((name) => name.endsWith('.js'))
  .map((name) => read(path.join('webroot', 'assets', name)))
  .join('\n');
assert.doesNotMatch(shippedJavaScript,
  /react(?:-dom|-jsx-runtime)?\.development\.js|\/home\/ubuntu\/dnscrypt_proxy_root_webui/,
  'release WebUI still contains a development framework build or source-machine paths');

for (const legalPath of [
  'LICENSE',
  'THIRD_PARTY_NOTICES.md',
  'LICENSES/GPL-3.0-only.txt',
  'LICENSES/ISC-dnscrypt-proxy.txt',
]) {
  assert.ok(exists(legalPath), `release legal material is missing: ${legalPath}`);
  assert.ok(read(legalPath).trim().length > 0, `release legal material is empty: ${legalPath}`);
}

const notices = read('THIRD_PARTY_NOTICES.md');
assert.match(notices, /28b48e580a9b605038bd3de15c5aba08d2258b14/,
  'Magisk installer blob identity is missing from third-party notices');
assert.match(notices, /37063225d4f344a8f41de8201f679e57098cb7e6/,
  'Magisk source revision is not pinned in third-party notices');
assert.match(notices, /GPL-3\.0-only/,
  'the copied Magisk installer license is not identified precisely');

const autoUpdate = read('.github/workflows/auto-update.yml');
assert.match(autoUpdate, /ref:\s+\$\{\{ github\.sha \}\}/,
  'auto-update packaging is not pinned to the commit that passed verification');
assert.doesNotMatch(autoUpdate, /ref:\s+master/,
  'auto-update still checks out a moving master branch after verification');

assert.match(read('.github/workflows/test.yml'), /node tests\/test-v092-release\.js/,
  'the v0.9.2 release contract is not enforced by the reusable CI workflow');

for (const workflowPath of [
  '.github/workflows/auto-update.yml',
  '.github/workflows/release.yml',
]) {
  const workflow = read(workflowPath);
  assert.match(workflow, /THIRD_PARTY_NOTICES\.md/,
    `${workflowPath} does not package third-party notices`);
  assert.match(workflow, /LICENSES/,
    `${workflowPath} does not package the license directory`);
  assert.match(workflow, /node webui\/build\.mjs --check/,
    `${workflowPath} does not prove that shipped WebUI assets are reproducible`);
}

assert.match(read('module.prop'), /^version=v0\.9\.2$/m,
  'module.prop is not prepared for v0.9.2');
const update = JSON.parse(read('update.json'));
assert.equal(update.version, 'v0.9.2', 'update.json is not prepared for v0.9.2');
assert.match(read('CHANGELOG.md'), /^## v0\.9\.2 \(2026-09-09\)$/m,
  'CHANGELOG.md has no dated v0.9.2 entry');

console.log('v0.9.2 release contract passed.');
