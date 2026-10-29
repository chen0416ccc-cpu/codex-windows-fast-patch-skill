'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const { STUB, normalizeProxy, managedBlock, patchSource, checkConnect, run } = require('./patch-cua-runtime-proxy.cjs');

async function mockProxy(mode, callback) {
  const sockets = new Set();
  const server = http.createServer();
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  server.on('connect', (request, socket) => {
    assert.equal(request.url, 'chatgpt.com:443');
    if (mode === 'close') socket.destroy();
    else if (mode !== 'timeout') socket.end(`HTTP/1.1 ${mode} Response\r\n\r\n`);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try { await callback(`http://127.0.0.1:${server.address().port}`); }
  finally { for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); }
}

async function main() {
  const proxy = 'http://127.0.0.1:1234';
  assert.equal(normalizeProxy(proxy + '/'), proxy);
  assert.equal(normalizeProxy('http://[::1]:8080'), 'http://[::1]:8080');
  for (const invalid of ['socks5://localhost:1080', 'https://localhost:8080', 'http://u:p@localhost:8080', 'http://localhost:0', 'http://localhost:65536', 'http://localhost:abc', 'http://localhost/proxy.pac', 'http://localhost?x', ' http://localhost']) assert.throws(() => normalizeProxy(invalid));
  const patched = patchSource(STUB, proxy).source;
  assert.equal(patchSource(patched, proxy).changed, false);
  assert.match(patched, /HTTP_PROXY: process\.env\.HTTP_PROXY \|\|/);
  assert.match(patched, /NO_PROXY: process\.env\.NO_PROXY \|\|/);
  const explicit = { HTTP_PROXY: 'http://explicit:8080', HTTPS_PROXY: 'http://secure:8080', NO_PROXY: 'internal.example', NODE_USE_ENV_PROXY: '0' };
  vm.runInNewContext(managedBlock(proxy), { process: { env: explicit } });
  assert.deepEqual(explicit, { HTTP_PROXY: 'http://explicit:8080', HTTPS_PROXY: 'http://secure:8080', NO_PROXY: 'internal.example', NODE_USE_ENV_PROXY: '1' });
  const absent = {};
  vm.runInNewContext(managedBlock(proxy), { process: { env: absent } });
  assert.deepEqual(absent, { HTTP_PROXY: proxy, HTTPS_PROXY: proxy, NO_PROXY: 'localhost,127.0.0.1,::1', NODE_USE_ENV_PROXY: '1' });
  assert.equal(patchSource(patched, 'http://localhost:5678').changed, true);
  assert.equal(patchSource(patched, null).source, STUB);
  assert.equal(patchSource(STUB, null).changed, false);
  assert.equal(patchSource('unknown official future stub', null).changed, false);
  const crlf = patchSource(STUB.replace(/\n/g, '\r\n'), proxy).source;
  assert.equal(crlf.replace(/\r\n/g, '').includes('\n'), false);
  const historicalBlock = `// Local proxy repair; revalidate after runtime updates.\nObject.assign(process.env, {\n  NODE_USE_ENV_PROXY: '1',\n  HTTP_PROXY: '${proxy}',\n  HTTPS_PROXY: '${proxy}',\n  NO_PROXY: 'localhost,127.0.0.1,::1',\n});\n\n`;
  const historical = STUB.replace('try {', historicalBlock + 'try {');
  assert.equal(patchSource(historical, proxy).source, patched);
  assert.equal(patchSource(historical, null).source, STUB);
  for (const invalid of [STUB + '// unknown\n', patched + patched, patched.replace('// END CODEX MANAGED CUA PROXY', ''), patched.replace("NODE_USE_ENV_PROXY: '1'", "NODE_USE_ENV_PROXY: '0'"), historical.replace('HTTPS_PROXY:', 'OTHER_PROXY:'), STUB + '// END CODEX MANAGED CUA PROXY\n']) {
    assert.throws(() => patchSource(invalid, proxy));
    if (/CODEX MANAGED CUA PROXY|Local proxy repair/.test(invalid)) assert.throws(() => patchSource(invalid, null));
  }
  await mockProxy('200', url => checkConnect(url, 500));
  for (const mode of ['407', '502', 'close', 'timeout']) await mockProxy(mode, url => assert.rejects(checkConnect(url, 80)));

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cua-proxy-fixture-'));
  try {
    const entryPath = path.join(root, 'runtime', 'node_modules', '@oai', 'cua-repl', 'bin', 'cua-repl.mjs');
    const backupRoot = path.join(root, 'backups');
    fs.mkdirSync(path.dirname(entryPath), { recursive: true });
    const original = Buffer.from(STUB.replace(/\n/g, '\r\n'));
    fs.writeFileSync(entryPath, original);
    await mockProxy('200', async proxyUrl => {
      const options = { entryPath, proxyUrl, verifyOnly: true, backupRoot };
      await assert.rejects(run(options), /missing or proxy URL drifted/);
      assert.equal(fs.existsSync(backupRoot), false);
      assert.deepEqual(fs.readFileSync(entryPath), original);
      const first = await run({ ...options, verifyOnly: false });
      assert.equal(first.state, 'patched');
      assert.equal(first.restartRequired, true);
      assert.deepEqual(fs.readFileSync(first.backupPath), original);
      const after = fs.readFileSync(entryPath);
      assert.equal((await run(options)).state, 'already-patched');
      assert.equal((await run({ ...options, verifyOnly: false })).state, 'already-patched');
      assert.equal(fs.readdirSync(backupRoot).length, 1);
      await assert.rejects(run({ ...options, proxyUrl: 'http://127.0.0.1:1' }), /drifted/);
      await assert.rejects(run({ ...options, proxyUrl: null }), /drifted/);
      assert.deepEqual(fs.readFileSync(entryPath), after);
      assert.equal(fs.readdirSync(backupRoot).length, 1);
      const restored = await run({ ...options, proxyUrl: null, verifyOnly: false });
      assert.equal(restored.state, 'restored');
      assert.deepEqual(fs.readFileSync(entryPath), original);
      assert.equal((await run({ ...options, proxyUrl: null })).state, 'not-needed');
    });
    await mockProxy('407', async proxyUrl => {
      await assert.rejects(run({ entryPath, proxyUrl, verifyOnly: false, backupRoot }), /407/);
      assert.deepEqual(fs.readFileSync(entryPath), original);
      assert.equal(fs.readdirSync(backupRoot).length, 2);
    });
    const blockingBackup = path.join(root, 'blocking-file');
    fs.writeFileSync(blockingBackup, 'not a directory');
    await mockProxy('200', async proxyUrl => {
      await assert.rejects(run({ entryPath, proxyUrl, verifyOnly: false, backupRoot: blockingBackup }));
      assert.deepEqual(fs.readFileSync(entryPath), original);
      fs.writeFileSync(entryPath, STUB + '//unknown');
      await assert.rejects(run({ entryPath, proxyUrl, verifyOnly: false, backupRoot }), /shape/);
      assert.equal(fs.readFileSync(entryPath, 'utf8'), STUB + '//unknown');
    });
    const protectedEntry = path.join(root, 'WindowsApps', 'node_modules', '@oai', 'cua-repl', 'bin', 'cua-repl.mjs');
    fs.mkdirSync(path.dirname(protectedEntry), { recursive: true }); fs.writeFileSync(protectedEntry, STUB);
    await assert.rejects(run({ entryPath: protectedEntry, proxyUrl: null, verifyOnly: true }), /user-local/);
    assert.equal(fs.readdirSync(path.dirname(entryPath)).length, 1);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
  console.log('PASS: source profiles, proxy validation, CONNECT, strict read-only, backup, restore and failure guards');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
