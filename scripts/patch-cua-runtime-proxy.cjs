#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const START = '// BEGIN CODEX MANAGED CUA PROXY';
const END = '// END CODEX MANAGED CUA PROXY';
const STUB = `#!/usr/bin/env node
import * as cua_repl from "@oai/cua-repl";

try {
  await cua_repl.launch();
} catch (error) {
  const error_message = error instanceof Error ? error.message : String(error);
  console.error(\`cua_repl could not start: \${error_message}\`);
  process.exitCode = 1;
}
`;

function normalizeProxy(value) {
  if (typeof value !== 'string' || value !== value.trim() || /[\s\\?#]/.test(value)) throw new Error('invalid HTTP proxy URL');
  // Check the literal port before URL normalizes a default port away.
  if (!/^http:\/\/(?:\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+)(?::[0-9]+)?\/?$/.test(value)) throw new Error('only HTTP proxies without credentials are supported');
  const url = new URL(value);
  const port = /:(\d+)\/?$/.exec(value);
  if (port && (+port[1] < 1 || +port[1] > 65535)) throw new Error('invalid proxy port');
  if (!url.hostname || url.username || url.password || url.pathname !== '/') throw new Error('invalid HTTP proxy URL');
  return url.origin;
}

function managedBlock(proxyUrl) {
  const value = JSON.stringify(normalizeProxy(proxyUrl));
  return `${START}
Object.assign(process.env, {
  NODE_USE_ENV_PROXY: '1',
  HTTP_PROXY: process.env.HTTP_PROXY || ${value},
  HTTPS_PROXY: process.env.HTTPS_PROXY || ${value},
  NO_PROXY: process.env.NO_PROXY || 'localhost,127.0.0.1,::1',
});
${END}\n\n`;
}

function patchSource(source, proxyUrl) {
  const proxy = proxyUrl === null ? null : normalizeProxy(proxyUrl);
  const newline = source.includes('\r\n') ? '\r\n' : '\n';
  if (source.replace(/\r\n/g, '').includes('\r')) throw new Error('unsupported newline style');
  const normalized = source.replace(/\r\n/g, '\n');
  let original = normalized;
  const marker = normalized.indexOf(START);
  if (marker !== -1) {
    const ending = normalized.indexOf(END, marker);
    if (ending === -1 || normalized.indexOf(START, marker + START.length) !== -1 || normalized.indexOf(END, ending + END.length) !== -1) throw new Error('invalid managed proxy markers');
    const block = normalized.slice(marker, ending + END.length + 2);
    const match = /HTTP_PROXY: process\.env\.HTTP_PROXY \|\| ("[^"\n]+"),/.exec(block);
    if (!match || block !== managedBlock(JSON.parse(match[1]))) throw new Error('unknown managed proxy block');
    original = normalized.slice(0, marker) + normalized.slice(marker + block.length);
  } else if (normalized.includes('Object.assign(process.env')) {
    const historical = /\/\/ Local proxy repair; revalidate after runtime updates\.\nObject\.assign\(process\.env, \{\n  NODE_USE_ENV_PROXY: '1',\n  HTTP_PROXY: '([^'\n]+)',\n  HTTPS_PROXY: '([^'\n]+)',\n  NO_PROXY: 'localhost,127\.0\.0\.1,::1',\n\}\);\n\n/g;
    const matches = [...normalized.matchAll(historical)];
    if (matches.length !== 1 || normalizeProxy(matches[0][1]) !== normalizeProxy(matches[0][2])) throw new Error('unknown historical proxy block');
    original = normalized.replace(historical, '');
  }
  if (original !== STUB) {
    if (proxy === null && !/CODEX MANAGED CUA PROXY|Local proxy repair|NODE_USE_ENV_PROXY|HTTP_PROXY|HTTPS_PROXY|Object\.assign\(process\.env/.test(normalized)) return { source, changed: false };
    throw new Error('unsupported cua-repl entry shape');
  }
  const candidate = (proxy === null ? STUB : STUB.replace('\ntry {', '\n' + managedBlock(proxy) + 'try {')).replace(/\n/g, newline);
  return { source: candidate, changed: candidate !== source };
}

function checkConnect(proxyUrl, timeoutMs = 5000) {
  const proxy = new URL(normalizeProxy(proxyUrl));
  return new Promise((resolve, reject) => {
    let settled = false;
    let socket;
    const request = http.request({ hostname: proxy.hostname.replace(/^\[|\]$/g, ''), port: proxy.port || 80,
      method: 'CONNECT', path: 'chatgpt.com:443', headers: { Host: 'chatgpt.com:443' }, agent: false });
    const timer = setTimeout(() => finish(new Error('HTTP CONNECT timed out')), timeoutMs);
    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (socket) socket.destroy();
      request.destroy();
      error ? reject(error) : resolve();
    }
    request.on('connect', (response, connectedSocket) => {
      socket = connectedSocket;
      finish(response.statusCode === 200 ? null : new Error(`HTTP CONNECT returned ${response.statusCode}`));
    });
    request.on('response', response => { response.resume(); finish(new Error(`HTTP CONNECT returned ${response.statusCode}`)); });
    request.on('error', error => finish(error));
    request.end();
  });
}

const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

async function run(options) {
  if (!options || typeof options.entryPath !== 'string' || typeof options.verifyOnly !== 'boolean') throw new Error('entryPath and boolean verifyOnly are required');
  const entryPath = fs.realpathSync(options.entryPath);
  const normalizedPath = entryPath.replace(/\\/g, '/');
  if (/(^|\/)WindowsApps(\/|$)/i.test(normalizedPath) || !/\/node_modules\/@oai\/cua-repl\/bin\/cua-repl\.mjs$/i.test(normalizedPath)) throw new Error('entry must be a user-local cua-repl runtime launcher');
  const original = fs.readFileSync(entryPath);
  const source = original.toString('utf8');
  if (!Buffer.from(source, 'utf8').equals(original)) throw new Error('entry is not valid UTF-8');
  const patch = patchSource(source, options.proxyUrl);
  if (options.verifyOnly && patch.changed) throw new Error('CUA runtime proxy patch missing or proxy URL drifted');
  if (options.proxyUrl !== null) await checkConnect(options.proxyUrl);
  if (!patch.changed) return { state: options.proxyUrl === null ? 'not-needed' : 'already-patched', restartRequired: false, entryPath, sha256: hash(original), backupPath: null };
  const syntax = spawnSync(process.execPath, ['--check', '--input-type=module'], { input: patch.source, encoding: 'utf8', windowsHide: true });
  if (syntax.error || syntax.status !== 0) throw new Error(`candidate syntax check failed: ${syntax.error || syntax.stderr}`);
  if (typeof options.backupRoot !== 'string' || !options.backupRoot) throw new Error('backupRoot is required for writes');
  if (!fs.readFileSync(entryPath).equals(original)) throw new Error('entry changed during proxy preflight');
  fs.mkdirSync(options.backupRoot, { recursive: true });
  const backupPath = path.join(options.backupRoot, `cua-repl.mjs.${hash(original)}.bak`);
  try { fs.writeFileSync(backupPath, original, { flag: 'wx' }); }
  catch (error) { if (error.code !== 'EEXIST' || !fs.readFileSync(backupPath).equals(original)) throw error; }
  const temporary = `${entryPath}.${crypto.randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temporary, patch.source, { encoding: 'utf8', flag: 'wx', mode: fs.statSync(entryPath).mode });
    if (!fs.readFileSync(entryPath).equals(original)) throw new Error('entry changed before replacement');
    fs.renameSync(temporary, entryPath);
  } finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
  return { state: options.proxyUrl === null ? 'restored' : 'patched', restartRequired: true, entryPath, sha256: hash(Buffer.from(patch.source)), backupPath };
}

module.exports = { STUB, normalizeProxy, managedBlock, patchSource, checkConnect, run };
if (require.main === module) {
  (async () => {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    const options = JSON.parse(Buffer.concat(chunks).toString('utf8').replace(/^\uFEFF/, ''));
    process.stdout.write(JSON.stringify(await run(options)) + '\n');
  })().catch(error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; });
}
