#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {TextDecoder, TextEncoder} = require('node:util');

const rootDir = path.resolve(__dirname, '..');
const bridgePath = path.join(rootDir, 'webui', 'src', 'bridge.js');
const appPath = path.join(rootDir, 'webui', 'src', 'app.js');
const indexPath = path.join(rootDir, 'webui', 'src', 'index.html');
const bridgeSource = fs.readFileSync(bridgePath, 'utf8');
const appSource = fs.readFileSync(appPath, 'utf8');
const indexSource = fs.readFileSync(indexPath, 'utf8');
const marker = '__DPR_EXIT_7d393ba6__';

function encodeBinary(value) {
  return Buffer.from(value, 'binary').toString('base64');
}

function decodeBinary(value) {
  return Buffer.from(value, 'base64').toString('binary');
}

function loadBridge(nativeExec, {textCodec = true} = {}) {
  const host = {
    atob: decodeBinary,
    btoa: encodeBinary,
  };
  if (textCodec) Object.assign(host, {TextDecoder, TextEncoder});
  if (nativeExec !== undefined) {
    host.ksu = {exec: (...args) => nativeExec(host, ...args)};
  }
  const context = {window: host};
  vm.createContext(context);
  vm.runInContext(bridgeSource, context, {filename: bridgePath});
  return {bridge: context.DnscryptBridge, host};
}

function liveCallbacks(host) {
  return Object.keys(host).filter((name) => name.startsWith('dpr_exec_'));
}

async function main() {
  const unavailable = loadBridge(undefined).bridge;
  assert.equal(unavailable.available(), false, 'missing native bridge was reported as available');
  assert.equal('_test' in unavailable, false,
    'production bridge exposes an internal command-execution test hook');
  await assert.rejects(unavailable.control('status'), /bridge is unavailable/,
    'missing native bridge pretended that a control action succeeded');

  let wrappedCommand = '';
  const legacyRuntime = loadBridge((_host, command) => {
    wrappedCommand = command;
    return `first line\nsecond line\n${marker}0`;
  });
  assert.equal(await legacyRuntime.bridge.control('get-config'), 'first line\nsecond line\n',
    'successful command stdout was not preserved');
  assert.match(wrappedCommand, /dnscrypt-control\.sh' 'get-config'/,
    'allowlisted control action did not reach the native bridge');
  assert.match(wrappedCommand, /3>&1/, 'command wrapper does not preserve stdout separately from diagnostics');
  assert.match(wrappedCommand, new RegExp(marker), 'command wrapper does not emit its exit-status sentinel');
  assert.deepEqual(liveCallbacks(legacyRuntime.host), [], 'legacy callback registration leaked after completion');

  const failure = loadBridge(() => `permission denied\n${marker}126`).bridge;
  await assert.rejects(failure.control('get-config'), /permission denied/,
    'non-zero wrapped status did not expose its diagnostic');

  const silentFailure = loadBridge(() => `${marker}7`).bridge;
  await assert.rejects(silentFailure.control('get-config'), /exit status 7/,
    'silent non-zero wrapped status was not actionable');

  const missingStatus = loadBridge(() => 'apparently successful output').bridge;
  await assert.rejects(missingStatus.control('get-config'), /did not return an exit status/,
    'legacy output without a sentinel was accepted');

  const invalidStatus = loadBridge(() => `${marker}not-a-number`).bridge;
  await assert.rejects(invalidStatus.control('get-config'), /invalid exit status/,
    'malformed wrapped status was accepted');

  const embeddedMarker = loadBridge(() => `payload ${marker} text\n${marker}0`).bridge;
  assert.equal(await embeddedMarker.control('get-config'), `payload ${marker} text\n`,
    'parser did not use the final exit-status sentinel');

  const callbackRuntime = loadBridge((host, command, options, callbackName) => {
    assert.equal(options, '{}', 'KernelSU callback options must be valid JSON');
    assert.match(command, /dnscrypt-control\.sh' 'get-config'/,
      'callback bridge received the wrong command');
    host[callbackName](0, `callback output\n${marker}0`, '');
  });
  assert.equal(await callbackRuntime.bridge.control('get-config'), 'callback output\n',
    'current KernelSU callback result was not handled');
  assert.deepEqual(liveCallbacks(callbackRuntime.host), [], 'KernelSU callback registration leaked after completion');

  const callbackFailure = loadBridge((host, _command, _options, callbackName) => {
    host[callbackName](13, '', 'root command denied');
  });
  await assert.rejects(callbackFailure.bridge.control('get-config'), /root command denied/,
    'native callback errno was accepted as success');
  assert.deepEqual(liveCallbacks(callbackFailure.host), [], 'failed callback registration was not cleaned up');

  const promiseRuntime = loadBridge(() => Promise.resolve({errno: 0, stdout: 'promise output', stderr: ''}));
  assert.equal(await promiseRuntime.bridge.control('get-config'), 'promise output',
    'Promise-based APatch result was not normalized');

  const rejectedRuntime = loadBridge(() => Promise.reject(new Error('native promise rejected')));
  await assert.rejects(rejectedRuntime.bridge.control('get-config'), /native promise rejected/,
    'native Promise rejection was swallowed');
  assert.deepEqual(liveCallbacks(rejectedRuntime.host), [], 'rejected Promise callback registration was not cleaned up');

  let controlCommand = '';
  const controlRuntime = loadBridge((_host, command) => {
    controlCommand = command;
    return `${marker}0`;
  });
  await controlRuntime.bridge.control('get-list', ['allowed-names']);
  assert.match(controlCommand, /'get-list' 'allowed-names'/,
    'managed list read does not go through the canonical backend action');
  assert.throws(() => controlRuntime.bridge.control('get-list', ['../../config']), /Unknown managed list kind/,
    'unrecognized managed list kind reached the shell');
  assert.throws(() => controlRuntime.bridge.control('arbitrary-root-command'), /Unsupported control action/,
    'unallowlisted root action reached the shell');

  const unicodeList = '例子.invalid\nδοκιμή.example\n';
  await controlRuntime.bridge.saveList('blocked-names', unicodeList, true);
  assert.match(controlCommand, /'save-list-b64' 'blocked-names'/,
    'managed list save does not use the validated backend action');
  assert.match(controlCommand, new RegExp(`'${controlRuntime.bridge.encodeText(unicodeList)}' 'apply'`),
    'save-and-apply did not send the exact UTF-8 list generation');
  assert.equal(controlRuntime.bridge.decodeText(controlRuntime.bridge.encodeText(unicodeList)), unicodeList,
    'UTF-8 bridge codec did not round-trip managed list content');

  const fallbackCodec = loadBridge((_host) => `${marker}0`, {textCodec: false}).bridge;
  assert.equal(fallbackCodec.decodeText(fallbackCodec.encodeText(unicodeList)), unicodeList,
    'legacy WebView UTF-8 codec fallback did not round-trip content');

  assert.match(appSource, /status\.healthy/,
    'WebUI does not render the backend health verdict');
  assert.match(appSource, /status\.service_state/,
    'WebUI does not render the backend service state');
  assert.match(appSource, /status\.dns_mode/,
    'WebUI does not render the backend DNS integration mode');
  assert.match(appSource, /status\.firewall/,
    'WebUI does not render the backend firewall state');
  assert.match(appSource, /status\.config_apply_state/,
    'WebUI does not expose pending versus applied configuration state');
  assert.match(appSource, /bridge\.getList\(/,
    'WebUI managed list editor does not read through the canonical backend');
  assert.doesNotMatch(appSource, /\/data\/adb\/modules\/[^'"`]+\/config/,
    'WebUI reads a stale module-directory configuration path directly');
  assert.match(indexSource, /cannot prove|不能證明|不能证明/,
    'diagnostics UI omits the sampled-check limitation');
  assert.match(appSource, /not a .direct DNS. policy-bypass test|不是繞過策略|不是绕过策略/,
    'strict-mode destination comparison is presented as a policy bypass');

  console.log('WebUI bridge tests passed (13 runtime cases plus canonical-state, policy-scope, and UI invariants).');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});
