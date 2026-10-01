const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { brotliDecompressSync } = require('node:zlib');

const ASSET = 'browser-accessibility.wasm.br';
const SERVICE = 'browser-service.mjs';
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const json = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
function read(file) { return fs.existsSync(file) ? fs.readFileSync(file) : null; }
function valid(bytes) {
  if (!bytes) return false;
  try { return WebAssembly.validate(brotliDecompressSync(bytes)); } catch { return false; }
}
function physical(file) {
  if (!path.isAbsolute(file)) throw new Error(`Expected absolute asset path: ${file}`);
  return fs.existsSync(file) ? fs.realpathSync.native(file) : path.join(physical(path.dirname(file)), path.basename(file));
}
function writable(file, sources) {
  const resolved = physical(file);
  if (resolved.split(/[\\/]/).some(part => part.toLowerCase() === 'windowsapps') ||
      sources.some(source => physical(source).toLowerCase() === resolved.toLowerCase())) {
    throw new Error(`Refusing protected package asset target: ${file}`);
  }
  return resolved;
}
function collect(options) {
  const { installedMarketplaceRoot: installed, marketplaceRoot: mirror, codexHomeRoot: home, runtime } = options;
  const groups = [];
  for (const plugin of ['browser', 'chrome']) {
    const dir = path.join(installed, 'plugins', plugin);
    const descriptor = path.join(dir, '.codex-plugin', 'plugin.json');
    if (!fs.existsSync(descriptor)) continue;
    const version = json(descriptor).version;
    if (typeof version !== 'string' || !/^[0-9A-Za-z][0-9A-Za-z._-]*$/.test(version)) throw new Error(`Invalid ${plugin} version`);
    const service = read(path.join(dir, 'scripts', SERVICE));
    if (!service || !service.includes(ASSET)) {
      if (fs.existsSync(path.join(dir, 'scripts', ASSET))) throw new Error(`Missing or unrecognized packaged AX loader: ${dir}`);
      continue;
    }
    const roots = [
      path.join(mirror, 'plugins', plugin),
      path.join(home, 'plugins', 'cache', 'openai-bundled', plugin, version),
      path.join(path.dirname(mirror), 'openai-bundled-cache', plugin, version),
      path.join(home, '.tmp', 'bundled-marketplaces', 'openai-bundled', 'plugins', plugin),
    ];
    const targets = [];
    for (const [index, root] of roots.entries()) {
      // The stable mirror and current cache are required; other mirrors are optional.
      if (index > 1 && !fs.existsSync(root)) continue;
      const targetDescriptor = path.join(root, '.codex-plugin', 'plugin.json');
      if (!fs.existsSync(targetDescriptor) || json(targetDescriptor).version !== version) throw new Error(`Missing or mixed AX target version: ${root}`);
      targets.push(path.join(root, 'scripts', ASSET));
    }
    groups.push({ kind: 'plugin', version, serviceHash: hash(service), source: path.join(dir, 'scripts', ASSET), targets });
  }
  if (runtime) {
    const relative = path.join('node_modules', '@oai', 'browser-desktop');
    const dir = path.join(runtime.referenceBin, relative);
    if (fs.existsSync(dir)) {
      const descriptor = json(path.join(dir, 'package.json'));
      if (descriptor.name !== '@oai/browser-desktop' || descriptor.exports?.['./service'] !== './scripts/browser-service.mjs') throw new Error('Unrecognized packaged browser-desktop service');
      const service = read(path.join(dir, 'scripts', SERVICE));
      if (!service) throw new Error('Missing packaged browser-desktop service');
      if (service.includes(ASSET)) {
        const targets = [...new Set(runtime.bins)].map(bin => path.join(bin, relative, 'scripts', ASSET));
        groups.push({ kind: 'runtime', source: path.join(dir, 'scripts', ASSET), targets });
      }
    }
  }
  return groups;
}
function run(options) {
  const groups = collect(options);
  const sources = groups.map(group => group.source);
  const plans = new Map();
  // Validate every source and target before the first backup or write.
  for (const group of groups) {
    let source = group.source;
    let bytes = read(source);
    const recovered = !valid(bytes);
    if (recovered) {
      const donors = groups.filter(peer => peer !== group && group.kind === 'plugin' && peer.kind === 'plugin' &&
        peer.version === group.version && peer.serviceHash === group.serviceHash)
        .map(peer => ({ source: peer.source, bytes: read(peer.source) })).filter(peer => valid(peer.bytes));
      if (!donors.length || new Set(donors.map(peer => hash(peer.bytes))).size !== 1) throw new Error(`AX asset has no equivalent healthy packaged peer: ${source}`);
      ({ source, bytes } = donors[0]);
    }
    const expected = hash(bytes);
    for (const target of group.targets) {
      const resolved = writable(target, sources);
      if (!fs.existsSync(path.dirname(resolved))) throw new Error(`AX asset directory missing: ${target}`);
      const existing = read(resolved);
      const matches = existing && hash(existing) === expected;
      if (!matches && valid(existing)) throw new Error(`Healthy AX asset differs from package; refusing mixed version: ${target}`);
      if (!matches && options.verifyOnly) throw new Error(`AX asset missing or corrupt: ${target}`);
      const prior = plans.get(resolved.toLowerCase());
      if (prior && prior.sha256 !== expected) throw new Error(`Conflicting AX sources for target: ${target}`);
      plans.set(resolved.toLowerCase(), { target: resolved, source, sourceRecovered: recovered, sha256: expected, bytes, existing, matches });
    }
  }
  if ([...plans.values()].some(plan => !plan.matches)) {
    if (!options.backupRoot) throw new Error('AX asset repair requires a backup root');
    writable(options.backupRoot, sources);
  }
  const results = [];
  for (const plan of plans.values()) {
    const { target, source, sourceRecovered, sha256, bytes, existing, matches } = plan;
    let backup;
    if (!matches) {
      // Refuse a concurrent replacement instead of overwriting its bytes.
      const current = read(target);
      if (current === null ? existing !== null : existing === null || !current.equals(existing)) throw new Error(`AX asset changed during repair: ${target}`);
      if (existing) {
        fs.mkdirSync(options.backupRoot, { recursive: true });
        backup = path.join(options.backupRoot, `${hash(Buffer.from(target)).slice(0, 16)}-${hash(existing)}.br`);
        if (fs.existsSync(backup)) {
          if (!fs.readFileSync(backup).equals(existing)) throw new Error(`AX backup content mismatch: ${backup}`);
        } else fs.writeFileSync(backup, existing, { flag: 'wx' });
      }
      const temporary = `${target}.${crypto.randomUUID()}.tmp`;
      try {
        fs.writeFileSync(temporary, bytes, { flag: 'wx' });
        fs.renameSync(temporary, target);
      } finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
      if (hash(fs.readFileSync(target)) !== sha256) throw new Error(`AX asset write verification failed: ${target}`);
    }
    results.push({ state: matches ? 'verified' : 'repaired', target, source, sourceRecovered, sha256, ...(backup ? { backup } : {}) });
  }
  return results;
}
module.exports = { run };
if (require.main === module) {
  try {
    const options = JSON.parse(fs.readFileSync(0, 'utf8').replace(/^\uFEFF/, ''));
    console.log(JSON.stringify(run(options)));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
