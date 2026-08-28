#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..');
const bundlePath = path.join(rootDir, 'webroot', 'assets', 'index-CD85Tj2j.js');
const bundle = fs.readFileSync(bundlePath, 'utf8');
const bridgeStart = bundle.indexOf('function It(){');
const bridgeEnd = bundle.indexOf('function Rg(', bridgeStart);

assert.notEqual(bridgeStart, -1, 'WebUI bridge availability function is missing');
assert.notEqual(bridgeEnd, -1, 'WebUI bridge function boundary is missing');

// Exercise the bridge implementation that ships in the minified bundle, not a
// test-side copy of its algorithm. The short extracted region has no DOM or
// React dependencies and exposes the otherwise module-private command helper.
const bridgeSource = `${bundle.slice(bridgeStart, bridgeEnd)};globalThis.__bridgeExec=$t;`;

function loadBridge(nativeExec) {
  const context = {
    console: {log() {}},
  };
  if (nativeExec !== undefined) {
    context.window = {ksu: {exec: nativeExec}};
  }
  vm.createContext(context);
  vm.runInContext(bridgeSource, context, {filename: bundlePath});
  return context.__bridgeExec;
}

const marker = '__DPR_EXIT_7d393ba6__';

assert.equal(loadBridge(undefined)('printf ignored'), '',
  'browser fallback should not pretend a native command returned output');

let wrappedCommand = '';
const successExec = loadBridge((command) => {
  wrappedCommand = command;
  return `first line\nsecond line\n${marker}0`;
});
assert.equal(successExec('printf success'), 'first line\nsecond line\n',
  'successful command stdout was not preserved');
assert.match(wrappedCommand, /printf success/,
  'requested command was not passed to the native bridge');
assert.match(wrappedCommand, /3>&1/,
  'native wrapper does not preserve stdout on a dedicated descriptor');
assert.match(wrappedCommand, new RegExp(marker),
  'native wrapper does not emit its exit-status sentinel');

const failedExec = loadBridge(() => `permission denied\n${marker}126`);
assert.throws(() => failedExec('protected command'), /permission denied/,
  'non-zero native status did not expose its diagnostic');

const silentFailureExec = loadBridge(() => `${marker}7`);
assert.throws(() => silentFailureExec('false'), /exit status 7/,
  'silent non-zero native status did not produce an actionable error');

const missingStatusExec = loadBridge(() => 'apparently successful output');
assert.throws(() => missingStatusExec('true'), /did not return an exit status/,
  'missing sentinel was accepted as success');

const invalidStatusExec = loadBridge(() => `${marker}not-a-number`);
assert.throws(() => invalidStatusExec('true'), /invalid exit status/,
  'malformed native exit status was accepted');

const missingOutputExec = loadBridge(() => undefined);
assert.throws(() => missingOutputExec('true'), /returned no output/,
  'non-string native bridge output was accepted');

const embeddedMarkerExec = loadBridge(() => `payload ${marker} text\n${marker}0`);
assert.equal(embeddedMarkerExec('printf payload'), `payload ${marker} text\n`,
  'the parser did not use the final exit-status sentinel');

const saveListStart = bundle.indexOf('function vJ(');
const saveListEnd = bundle.indexOf('const $3=', saveListStart);
assert.notEqual(saveListStart, -1, 'WebUI list-save bridge function is missing');
assert.notEqual(saveListEnd, -1, 'WebUI list-save bridge boundary is missing');
const saveListSource = bundle.slice(saveListStart, saveListEnd);
assert.match(saveListSource, /save-list-b64/,
  'WebUI list save does not use the validated control-script command');
assert.doesNotMatch(saveListSource, /base64\s+-d\s*>/,
  'WebUI list save writes decoded data directly to a live file');

console.log('WebUI bridge tests passed (8 runtime cases plus static list-save invariants).');
