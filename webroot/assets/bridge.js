(function installDnscryptBridge(globalObject) {
  'use strict';

  const host = globalObject.window || globalObject;
  const controlScript = '/data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh';
  const exitMarker = '__DPR_EXIT_7d393ba6__';
  const listKinds = new Set(['blocked-names', 'allowed-names', 'blocked-ips', 'allowed-ips']);
  let callbackCounter = 0;

  const actionRules = Object.freeze({
    'apply-iptables': [0, 0],
    'apply-subscriptions': [0, 0],
    'auto-update': [0, 0],
    'check-update': [0, 0],
    'dns-test': [1, 1],
    'export-config': [0, 0],
    'get-config': [0, 0],
    'get-dns-mode': [0, 0],
    'get-list': [1, 1],
    'get-mode': [0, 0],
    'get-subscriptions': [0, 0],
    'health': [0, 0],
    'import-config-b64': [1, 1],
    'leak-test': [0, 0],
    'list-resolvers': [0, 0],
    'logs': [0, 1],
    'ping-all': [0, 0],
    'ping-resolver': [1, 1],
    'protocol-status': [0, 0],
    'query-stats': [0, 0],
    'quick-mode': [1, 1],
    'remove-iptables': [0, 0],
    'restart': [0, 0],
    'save-config-b64': [1, 1],
    'save-list-b64': [2, 3],
    'save-subscriptions-b64': [1, 1],
    'service-state': [0, 0],
    'set-dns-mode': [1, 1],
    'set-resolvers': [1, 1],
    'start': [0, 0],
    'status': [0, 0],
    'stop': [0, 0],
    'update': [0, 0],
  });

  function bridgeAvailable() {
    return Boolean(host.ksu && typeof host.ksu.exec === 'function');
  }

  function shellQuote(value) {
    const text = String(value);
    if (text.includes('\0')) throw new Error('Command arguments cannot contain NUL bytes');
    return `'${text.replace(/'/g, `'"'"'`)}'`;
  }

  function wrapCommand(command) {
    return `{ __dpr_err=$( ( ${command} ) 2>&1 1>&3); __dpr_rc=$?; `
      + `if [ "$__dpr_rc" -ne 0 ] && [ -n "$__dpr_err" ]; then printf '\\n%s' "$__dpr_err"; fi; `
      + `printf '${exitMarker}%s' "$__dpr_rc"; } 3>&1`;
  }

  function parseMarkedOutput(output) {
    if (typeof output !== 'string') {
      throw new Error('KernelSU/APatch command bridge returned no output');
    }
    const markerIndex = output.lastIndexOf(exitMarker);
    if (markerIndex < 0) {
      throw new Error('KernelSU/APatch command bridge did not return an exit status');
    }
    const statusText = output.slice(markerIndex + exitMarker.length).trim();
    const commandOutput = output.slice(0, markerIndex);
    if (!/^[0-9]+$/.test(statusText)) {
      throw new Error('KernelSU/APatch command bridge returned an invalid exit status');
    }
    if (Number(statusText) !== 0) {
      throw new Error(commandOutput.trim() || `Command failed with exit status ${statusText}`);
    }
    return commandOutput;
  }

  function normalizeNativeResult(result) {
    if (typeof result === 'string') return parseMarkedOutput(result);
    if (!result || typeof result !== 'object') {
      throw new Error('KernelSU/APatch command bridge returned no output');
    }
    const errno = Number(result.errno);
    const stdout = typeof result.stdout === 'string' ? result.stdout : '';
    const stderr = typeof result.stderr === 'string' ? result.stderr : '';
    if (stdout.includes(exitMarker)) return parseMarkedOutput(stdout);
    if (!Number.isInteger(errno) || errno < 0) {
      throw new Error('KernelSU/APatch command bridge returned an invalid native status');
    }
    if (errno !== 0) throw new Error(stderr.trim() || stdout.trim() || `Command failed with exit status ${errno}`);
    return stdout;
  }

  function invokeNative(wrappedCommand) {
    if (!bridgeAvailable()) {
      return Promise.reject(new Error('KernelSU/APatch command bridge is unavailable'));
    }
    return new Promise((resolve, reject) => {
      const callbackName = `dpr_exec_${Date.now()}_${callbackCounter++}`;
      let settled = false;
      const cleanup = () => {
        try {
          delete host[callbackName];
        } catch (_) {
          host[callbackName] = undefined;
        }
      };
      const finish = (result) => {
        if (settled) return;
        settled = true;
        cleanup();
        try {
          resolve(normalizeNativeResult(result));
        } catch (error) {
          reject(error);
        }
      };
      host[callbackName] = (errno, stdout, stderr) => finish({errno, stdout, stderr});
      try {
        // Current KernelSU uses (command, JSON options, callback name). Legacy
        // KernelSU/APatch bridges ignore the extra arguments and return a string.
        const immediate = host.ksu.exec(wrappedCommand, '{}', callbackName);
        if (immediate !== undefined) {
          Promise.resolve(immediate).then(finish, (error) => {
            settled = true;
            cleanup();
            reject(error);
          });
        }
      } catch (error) {
        settled = true;
        cleanup();
        reject(error);
      }
    });
  }

  async function execCommand(command) {
    if (typeof command !== 'string' || command.length === 0 || command.length > 20_000_000) {
      throw new Error('Command is empty or exceeds the bridge safety limit');
    }
    return invokeNative(wrapCommand(command));
  }

  function validateControlArguments(action, args) {
    const rule = actionRules[action];
    if (!rule) throw new Error(`Unsupported control action: ${action}`);
    if (!Array.isArray(args) || args.length < rule[0] || args.length > rule[1]) {
      throw new Error(`Unexpected argument count for ${action}`);
    }
    for (const argument of args) {
      if (typeof argument !== 'string' || argument.length > 15_000_000 || argument.includes('\0')) {
        throw new Error(`Invalid argument for ${action}`);
      }
    }
    if ((action === 'get-list' || action === 'save-list-b64') && !listKinds.has(args[0])) {
      throw new Error('Unknown managed list kind');
    }
    if (action === 'save-list-b64' && args[2] !== undefined && args[2] !== 'apply') {
      throw new Error('Unknown list commit mode');
    }
  }

  function control(action, args = []) {
    validateControlArguments(action, args);
    const command = ['sh', shellQuote(controlScript), shellQuote(action), ...args.map(shellQuote)].join(' ');
    return execCommand(command);
  }

  function bytesToBase64(bytes) {
    let binary = '';
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return host.btoa(binary);
  }

  function encodeText(text) {
    const value = String(text);
    if (typeof host.TextEncoder === 'function') {
      return bytesToBase64(new host.TextEncoder().encode(value));
    }
    const binary = encodeURIComponent(value).replace(/%([0-9A-F]{2})/g, (_, hex) => (
      String.fromCharCode(Number.parseInt(hex, 16))
    ));
    return host.btoa(binary);
  }

  function decodeText(encoded) {
    const binary = host.atob(String(encoded));
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    if (typeof host.TextDecoder === 'function') return new host.TextDecoder().decode(bytes);
    let escaped = '';
    for (const byte of bytes) escaped += `%${(`0${byte.toString(16)}`).slice(-2)}`;
    return decodeURIComponent(escaped);
  }

  async function status() {
    return JSON.parse(await control('status'));
  }

  function getList(kind) {
    return control('get-list', [kind]);
  }

  function saveList(kind, text, apply = false) {
    return control('save-list-b64', [kind, encodeText(text), ...(apply ? ['apply'] : [])]);
  }

  const api = Object.freeze({
    available: bridgeAvailable,
    control,
    decodeText,
    encodeText,
    getList,
    saveList,
    status,
  });
  host.DnscryptBridge = api;
  globalObject.DnscryptBridge = api;
}(globalThis));
