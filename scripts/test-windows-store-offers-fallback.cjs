const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {patchText, MARKER, OFFERS_PROFILE} = require('./patch-windows-store-update-fallback.cjs');

const input = fs.readFileSync(process.argv[2], 'utf8');
let original = input;
if (input.includes(MARKER)) {
  const current = patchText(input);
  assert(['patched', 'already-patched'].includes(current.state));
  original = current.source;
  for (const change of OFFERS_PROFILE.changes) original = original.replace(change.replacement, change.original);
}
const patched = patchText(original).source;
assert.equal(patchText(patched).state, 'already-patched');
assert.equal(patchText(patched).source, patched);
for (const change of OFFERS_PROFILE.changes) {
  assert.throws(() => patchText(patched.replace(change.replacement, change.original)), /Partial|exactly one/);
  assert.throws(() => patchText(original + change.original), /exactly one/);
  assert.throws(() => patchText(patched + change.replacement), /Partial/);
}
assert.throws(() => patchText(original + `/*${MARKER}*/`), /Partial/);
const stale = patched.replaceAll('fn(t,this.options.buildVersion)>0?', 'un(t,this.options.buildVersion)>0?')
  .replaceAll('fn(codexStoreMarker,this.options.buildVersion)>0?', 'un(codexStoreMarker,this.options.buildVersion)>0?');
assert.equal(patchText(stale).state, 'patched');
assert.equal(patchText(stale).source, patched);
assert.throws(() => patchText(original.replace('if(fn(n.buildVersion,this.options.buildVersion)>0)', 'if(other(n.buildVersion,this.options.buildVersion)>0)')), /exactly one/);
assert.throws(() => patchText(stale.replace('r=fn(n,this.options.buildVersion)>0;', 'r=other(n,this.options.buildVersion)>0;')), /Partial/);
console.log('PASS exact version comparator guard and stale overlay repair');
console.log('PASS complete patch, idempotence, partial and duplicate guards');

function classDefinition(source, pattern) {
  const match = pattern.exec(source);
  assert(match, 'Expected the exact offers updater class');
  for (let end = source.indexOf('},', match.index); end >= 0 && end - match.index < 65536;
    end = source.indexOf('},', end + 2)) {
    const candidate = 'var ' + source.slice(match.index, end + 1) + `;globalThis.Selected=${match[1]};`;
    try { new vm.Script(candidate); return candidate; }
    catch (error) { if (!(error instanceof SyntaxError)) throw error; }
  }
  throw new Error('Could not parse the complete offers updater class');
}

function definitions(source) {
  return {
    Store: classDefinition(source, /([\w$]+)=class\{options;isUpdateReady=!1;downloadProgressPercent=null;installProgressPercent=null;lastUnavailableReason=null;activeCheck=null;/),
    Combined: classDefinition(source, /([\w$]+)=class\{options;activeUpdater=null;installPromise=null;isMsixFallbackUpdaterInitialized=!1;/),
    Offers: classDefinition(source, /([\w$]+)=class\{options;logger=l\.i\(`windows-offers`\);lastStoreCheckAtMs=null;/),
  };
}

const versionFunctions = /function fn\(e,t\)\{[\s\S]{0,1500}?function pn\(e\)\{[\s\S]{0,1500}?\}(?=var )/.exec(original);
assert(versionFunctions, 'Expected the shipped version comparator and parser');

async function scenario(source, options = {}) {
  const events = [], calls = {discover: 0, download: 0, fallback: 0, invalidations: 0, manifests: 0};
  const discovery = options.discovery ?? {hasUpdate: false, canSilentlyDownload: true};
  const download = options.download ?? {hasUpdate: false, canSilentlyDownload: true, completed: false};
  const release = {buildVersion: options.newer === false ? '1.0.0.0' : '2.0.0.0', packageIdentity: 'OpenAI.Codex', packagePublisher: 'CN=Fixture'};
  const noopLogger = () => ({info() {}, warning() {}, error() {}});
  const context = vm.createContext({
    l: {a: () => noopLogger, i: noopLogger}, vn: noopLogger,
    y: {app: {isPackaged: true, getName: () => 'Codex'}, dialog: {showMessageBox: async x => events.push(x.message)},
      net: {fetch: async url => {
        calls.manifests++;
        if (options.missingManifest || options.feedFailsAfterFirst && calls.manifests > 1) throw new Error('Fixture feed unavailable');
        return {ok: true, url, status: 200, json: async () => ({...release, ...(options.wrongIdentity ? {packageIdentity: 'Other.Package'} : {}), ...(options.wrongPublisher ? {packagePublisher: 'CN=Other'} : {})})};
      }}},
    Sn: {parse: x => x}, Cn: {parse: x => x}, xn: {parse: x => x},
    process: {arch: 'x64'}, Date, Promise, URL,
  });
  vm.runInContext(versionFunctions[0], context);
  const classes = {};
  for (const [name, definition] of Object.entries(definitions(source))) {
    vm.runInContext(definition, context);
    classes[name] = context.Selected;
  }
  const nativeAddon = {
    discoverStoreUpdates: async () => { calls.discover++; if (options.discoveryError) throw new Error('Fixture Store discovery unavailable'); return discovery; },
    trySilentDownloadStoreUpdates: async () => { calls.download++; return download; },
  };
  const offers = new classes.Offers({nativeAddon, buildVersion: options.localVersion ?? '1.0.0.0', packageIdentity: 'OpenAI.Codex', packagePublisher: 'CN=Fixture', manifestUrl: 'https://example.com/manifest.json', getStorePackageUrl: version => `https://example.com/${version}/ChatGPT-x64.msix`});
  offers.setPreparedUpdateInvalidator(async () => {calls.invalidations++;});
  const store = new classes.Store({offers, nativeAddon});
  const fallback = {hasUpdater: () => true, getIsUpdateReady: () => calls.fallback > 0,
    checkForUpdates: async () => stage(), checkForUpdatesInBackground: async () => stage()};
  async function stage() {
    const offer = await offers.discover();
    assert.equal(offer.source, 'store-unavailable');
    assert.equal(offer.buildVersion, '2.0.0.0');
    assert.match(offer.packageInfo.packageUrl, /^https:\/\/example\.com\/2\.0\.0\.0\/ChatGPT-x64\.msix$/);
    calls.fallback++;
  }
  const combined = new classes.Combined({storeUpdater: store, msixFallbackUpdater: fallback});
  combined.isMsixFallbackUpdaterInitialized = true;
  let result;
  if (options.allowFallback === false) result = await store.performCheck({allowFallback: false, manual: !!options.manual});
  else await combined.runCheck(options.manual ? 'manual' : 'background');
  if (options.repeat) await combined.runCheck('background');
  return {calls, events, result, active: combined.activeUpdater === fallback ? 'fallback' : combined.activeUpdater === store ? 'store' : null, info: await offers.checkForUpdateInformation()};
}

(async () => {
  const before = await scenario(original);
  assert.equal(before.calls.fallback, 0);
  assert.equal(before.info.status, 'up_to_date');
  console.log('PASS original newer-manifest NoUpdates failure reproduced');
  const cases = [
    ['newer manifest and discovery NoUpdates select official package', {}, 1, 'fallback'],
    ['manual discovery NoUpdates select official package', {manual: true}, 1, 'fallback'],
    ['cached NoUpdates retain official fallback offer', {repeat: true}, 2, 'fallback'],
    ['silent download NoUpdates select official package', {discovery: {hasUpdate: true, canSilentlyDownload: true}}, 1, 'fallback'],
    ['manual silent download NoUpdates select official package', {manual: true, discovery: {hasUpdate: true, canSilentlyDownload: true}}, 1, 'fallback'],
    ['current manifest keeps no-update path', {newer: false}, 0, null],
    ['missing manifest never starts package fallback', {missingManifest: true}, 0, null],
    ['completed Store download keeps Store active', {discovery: {hasUpdate: true, canSilentlyDownload: true}, download: {hasUpdate: true, canSilentlyDownload: true, completed: true}}, 0, 'store'],
    ['Store without silent download preserves availability', {discovery: {hasUpdate: true, canSilentlyDownload: false}}, 0, null],
    ['Store discovery errors use existing official fallback', {discoveryError: true}, 1, 'fallback'],
    ['wrong package identity prevents fallback', {wrongIdentity: true}, 0, null],
    ['wrong package publisher prevents fallback', {wrongPublisher: true}, 0, null],
    ['invalid local build prevents discovery fallback', {localVersion: 'invalid'}, 0, null],
    ['unavailable direct feed waits after discovery NoUpdates', {feedFailsAfterFirst: true}, 0, null],
    ['unavailable direct feed waits after silent NoUpdates', {feedFailsAfterFirst: true, discovery: {hasUpdate: true, canSilentlyDownload: true}}, 0, null],
  ];
  for (const [name, options, expected, active] of cases) {
    const result = await scenario(patched, options);
    assert.equal(result.calls.fallback, expected, name);
    assert.equal(result.active, active, name);
    if (expected > 0) assert.equal(result.info.status, 'available', name);
    if (options.repeat) assert.equal(result.calls.discover, 1, 'Discovery throttle must be preserved');
    console.log(`PASS ${name}`);
  }
  for (const discovery of [{hasUpdate: false, canSilentlyDownload: true}, {hasUpdate: true, canSilentlyDownload: true}]) {
    const result = await scenario(patched, {allowFallback: false, discovery});
    assert.equal(result.calls.fallback, 0);
    assert.equal(result.result.outcome, 'update-available-in-store');
    console.log('PASS Store-only callers keep availability after NoUpdates');
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
