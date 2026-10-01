const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { brotliCompressSync } = require('node:zlib');
const { spawnSync } = require('node:child_process');
const { run } = require('./repair-browser-accessibility-assets.cjs');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-ax-assets-test-'));
const good = process.argv[2] ? fs.readFileSync(process.argv[2]) : brotliCompressSync(Buffer.from('0061736d01000000', 'hex'));
const other = brotliCompressSync(Buffer.from('0061736d01000000000100', 'hex'));
const bad = process.argv[3] ? fs.readFileSync(process.argv[3]) : Buffer.from('broken brotli');
let checks = 0;
function check(fn) { fn(); checks++; }
function put(p, bytes) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, bytes); }
function fixture(name, versions = {}) {
  const base = path.join(root, name);
  const options = {
    installedMarketplaceRoot: path.join(base, 'installed'),
    marketplaceRoot: path.join(base, 'marketplace'),
    codexHomeRoot: path.join(base, 'home'),
    runtime: { referenceBin: path.join(base, 'packaged-bin'), bins: [path.join(base, 'current-bin')] },
    backupRoot: path.join(base, 'backups'),
  };
  const targets = [];
  const sources = [];
  for (const plugin of ['browser', 'chrome']) {
    const version = versions[plugin] || '1.2.3';
    const sourceRoot = path.join(options.installedMarketplaceRoot, 'plugins', plugin);
    put(path.join(sourceRoot, '.codex-plugin', 'plugin.json'), JSON.stringify({ name: plugin, version }));
    put(path.join(sourceRoot, 'scripts', 'browser-service.mjs'), 'const asset="./browser-accessibility.wasm.br";');
    const source = path.join(sourceRoot, 'scripts', 'browser-accessibility.wasm.br');
    put(source, good); sources.push(source);
    for (const dir of [
      path.join(options.marketplaceRoot, 'plugins', plugin),
      path.join(options.codexHomeRoot, 'plugins', 'cache', 'openai-bundled', plugin, version),
      path.join(base, 'openai-bundled-cache', plugin, version),
      path.join(options.codexHomeRoot, '.tmp', 'bundled-marketplaces', 'openai-bundled', 'plugins', plugin),
    ]) {
      put(path.join(dir, '.codex-plugin', 'plugin.json'), JSON.stringify({ name: plugin, version }));
      put(path.join(dir, 'scripts', 'browser-client.mjs'), 'trusted client');
      const target = path.join(dir, 'scripts', 'browser-accessibility.wasm.br');
      put(target, good); targets.push(target);
    }
  }
  for (const bin of [options.runtime.referenceBin, ...options.runtime.bins]) {
    const dir = path.join(bin, 'node_modules', '@oai', 'browser-desktop');
    put(path.join(dir, 'package.json'), JSON.stringify({ name: '@oai/browser-desktop', exports: { './service': './scripts/browser-service.mjs' } }));
    put(path.join(dir, 'scripts', 'browser-service.mjs'), 'const asset="./browser-accessibility.wasm.br";');
    const asset = path.join(dir, 'scripts', 'browser-accessibility.wasm.br');
    put(asset, good);
    (bin === options.runtime.referenceBin ? sources : targets).push(asset);
  }
  put(path.join(options.codexHomeRoot, 'config.toml'), 'untouched config');
  return { options, sources, targets };
}
try {
  const f = fixture('damaged-source');
  put(f.sources[0], bad);
  put(f.targets[0], bad);
  check(() => assert.throws(() => run({ ...f.options, verifyOnly: true }), /missing or corrupt/));
  check(() => assert.deepEqual(fs.readFileSync(f.targets[0]), bad));
  check(() => assert.equal(fs.existsSync(f.options.backupRoot), false));
  let result = run(f.options);
  check(() => assert.equal(result.filter(r => r.state === 'repaired').length, 1));
  check(() => assert.equal(result.length, 9));
  check(() => assert.deepEqual(fs.readFileSync(f.sources[0]), bad));
  check(() => assert.deepEqual(fs.readFileSync(f.targets[0]), good));
  const backups = fs.readdirSync(f.options.backupRoot);
  check(() => assert.equal(backups.length, 1));
  check(() => assert.deepEqual(fs.readFileSync(path.join(f.options.backupRoot, backups[0])), bad));
  check(() => assert.equal(run(f.options).every(r => r.state === 'verified'), true));
  check(() => assert.deepEqual(fs.readdirSync(f.options.backupRoot), backups));
  check(() => assert.equal(run({ ...f.options, verifyOnly: true }).length, 9));
  check(() => assert.equal(fs.readFileSync(path.join(f.options.codexHomeRoot, 'config.toml'), 'utf8'), 'untouched config'));
  check(() => assert.equal(fs.readFileSync(path.join(path.dirname(f.targets[0]), 'browser-client.mjs'), 'utf8'), 'trusted client'));

  const mixed = fixture('mixed-cache');
  put(mixed.targets[0], bad); put(mixed.targets[7], other);
  check(() => assert.throws(() => run(mixed.options), /differs from package/));
  check(() => assert.deepEqual(fs.readFileSync(mixed.targets[0]), bad));
  check(() => assert.equal(fs.existsSync(mixed.options.backupRoot), false));

  for (const mismatch of ['version', 'service', 'both-corrupt']) {
    const x = fixture(mismatch, mismatch === 'version' ? { chrome: '9.9.9' } : {}); put(x.sources[0], bad);
    const peerRoot = path.dirname(path.dirname(x.sources[1]));
    if (mismatch === 'service') put(path.join(peerRoot, 'scripts', 'browser-service.mjs'), 'const asset="./browser-accessibility.wasm.br"; // different');
    if (mismatch === 'both-corrupt') put(x.sources[1], bad);
    check(() => assert.throws(() => run(x.options), /no equivalent healthy packaged/));
  }

  const missing = fixture('missing-assets');
  fs.unlinkSync(missing.targets[0]);
  check(() => assert.throws(() => run({ ...missing.options, verifyOnly: true }), /missing or corrupt/));
  check(() => assert.equal(run(missing.options)[0].state, 'repaired'));
  fs.unlinkSync(missing.sources[0]);
  check(() => assert.equal(run({ ...missing.options, verifyOnly: true }).length, 9));

  const runtime = fixture('runtime'); put(runtime.targets[8], bad);
  check(() => assert.throws(() => run({ ...runtime.options, verifyOnly: true }), /missing or corrupt/));
  check(() => assert.equal(run(runtime.options)[8].state, 'repaired'));
  put(runtime.sources[2], bad);
  check(() => assert.throws(() => run(runtime.options), /no equivalent healthy packaged/));

  const protectedTarget = fixture('protected');
  fs.cpSync(protectedTarget.options.marketplaceRoot, path.join(root, 'WindowsApps', 'mirror'), { recursive: true });
  protectedTarget.options.marketplaceRoot = path.join(root, 'WindowsApps', 'mirror');
  check(() => assert.throws(() => run(protectedTarget.options), /protected/));
  if (process.platform === 'win32') {
    const alias = path.join(root, 'package-mirror-junction');
    fs.symlinkSync(protectedTarget.options.marketplaceRoot, alias, 'junction');
    check(() => assert.throws(() => run({ ...protectedTarget.options, marketplaceRoot: alias }), /protected/));
  }
  const incomplete = fixture('missing-directory');
  put(incomplete.targets[0], bad);
  const emptyTarget = path.join(root, 'incomplete-bin');
  incomplete.options.runtime.bins = [emptyTarget];
  check(() => assert.throws(() => run(incomplete.options), /directory missing/));
  check(() => assert.deepEqual(fs.readFileSync(incomplete.targets[0]), bad));
  const wrongVersion = fixture('wrong-target-version');
  put(path.join(path.dirname(path.dirname(wrongVersion.targets[0])), '.codex-plugin', 'plugin.json'), '{"version":"0.1.0"}');
  check(() => assert.throws(() => run(wrongVersion.options), /target version/));
  const independent = fixture('independent-runtime');
  for (const plugin of ['browser', 'chrome']) fs.unlinkSync(path.join(independent.options.installedMarketplaceRoot, 'plugins', plugin, '.codex-plugin', 'plugin.json'));
  put(independent.targets[8], bad);
  check(() => assert.throws(() => run({ ...independent.options, verifyOnly: true }), /missing or corrupt/));
  check(() => assert.equal(run(independent.options)[0].state, 'repaired'));
  const stale = path.join(root, 'stale-runtime', 'scripts', 'browser-accessibility.wasm.br');
  put(stale, bad);
  run(independent.options);
  check(() => assert.deepEqual(fs.readFileSync(stale), bad));

  const stdin = spawnSync(process.execPath, [path.join(__dirname, 'repair-browser-accessibility-assets.cjs')], {
    input: '\uFEFF' + JSON.stringify({ ...f.options, verifyOnly: true }), encoding: 'utf8',
  });
  check(() => assert.equal(stdin.status, 0, stdin.stderr));
  check(() => assert.equal(JSON.parse(stdin.stdout).length, 9));
  if (process.platform === 'win32') {
    const fixtureJson = path.join(root, 'wrapper.json');
    put(fixtureJson, JSON.stringify(f.options));
    const hosts = [path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), 'pwsh.exe'];
    for (const host of hosts) {
      const wrapped = spawnSync(host, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'test-browser-accessibility-wrapper.ps1'), '-FixtureJson', fixtureJson, '-NodePath', process.execPath], { encoding: 'utf8' });
      if (host === 'pwsh.exe' && wrapped.error?.code === 'ENOENT') continue;
      check(() => assert.equal(wrapped.status, 0, wrapped.stderr || wrapped.stdout));
      check(() => assert.equal((wrapped.stdout.match(/Browser AX asset verified:/g) || []).length, 8));
    }
  }
  console.log(JSON.stringify({ passed: checks }));
} finally {
  assert.equal(path.dirname(fs.realpathSync(root)), fs.realpathSync(os.tmpdir()));
  assert.ok(path.basename(root).startsWith('browser-ax-assets-test-'));
  fs.rmSync(root, { recursive: true, force: true });
}
