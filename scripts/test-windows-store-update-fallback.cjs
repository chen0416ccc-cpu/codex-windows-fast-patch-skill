const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {patchText, MARKER, PROFILES, OFFERS_PROFILE} = require('./patch-windows-store-update-fallback.cjs');

const source = fs.readFileSync(process.argv[2], 'utf8');
if (OFFERS_PROFILE.changes.some(change => source.includes(change.original) || source.includes(change.replacement))) {
  require('./test-windows-store-offers-fallback.cjs');
  return;
}
const profile = PROFILES.find(item => source.includes(item.original) || source.includes(item.replacement));
assert(profile, 'Expected a supported Windows Store updater profile');
const {original: ORIGINAL, replacement: REPLACEMENT} = profile;
const start = source.indexOf(`var ${profile.logger}=`);
const storeClass = new RegExp('var ' + profile.logger + '=' + (profile.loggerObject ?? 'l') + '\\.i\\(`windows-store-updater`\\),([\\w$]+)=class\\{').exec(source);
const combinedClass = /,([\w$]+)=class\{options;activeUpdater=null;installPromise=null;isMsixFallbackUpdaterInitialized=!1;(?:shouldCheckMsixFallback=!1;)?/.exec(source);
assert(start >= 0 && storeClass && combinedClass && combinedClass.index > start,
  'Expected the current Windows Store updater and fallback coordinator');
let definitions;
// The native parser finds the complete class boundary without pinning minified names.
for (let end = source.indexOf('},', combinedClass.index); end >= 0 && end - start < 65536;
  end = source.indexOf('},', end + 2)) {
  const candidate = source.slice(start, end + 1) +
    `;globalThis.classes={Store:${storeClass[1]},Combined:${combinedClass[1]}};`;
  try {
    new vm.Script(candidate);
    definitions = candidate;
    break;
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
  }
}
assert(definitions, 'Expected complete Windows updater class definitions');
if (source.includes(MARKER)) {
  assert.equal(patchText(source).state, 'already-patched');
  assert.throws(() => patchText(source.replace(REPLACEMENT, `/*${MARKER}*/${ORIGINAL}`)), /Partial/);
  assert.throws(() => patchText(source + REPLACEMENT), /Partial/);
  assert.throws(() => patchText(source.replace(REPLACEMENT, ORIGINAL + ORIGINAL)), /exactly one/);
  console.log('PASS patch idempotence, partial patch and duplicate branch guards');
}
const compare = (a, b) => {
  const left = a.split('.').map(Number);
  const right = b.split('.').map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    if ((left[i] || 0) !== (right[i] || 0)) return (left[i] || 0) - (right[i] || 0);
  }
  return 0;
};

async function check({name, newer = true, manifest = true, allowFallback = true, storeResult, storeError, expected, manual = false}) {
  const events = [];
  let fallbackCalls = 0;
  let storeCalls = 0;
  const context = vm.createContext({
    [profile.loggerObject ?? 'l']: {i: () => () => ({info() {}, warning() {}, error() {}})},
    [profile.electronObject ?? 'p']: {app: {isPackaged: true, getName: () => 'Codex'}, net: {}, dialog: {showMessageBox: async x => events.push(x.message)}},
    [profile.manifest]: async () => manifest ? {buildVersion: newer ? '2.0.0.0' : '1.0.0.0'} : null,
    [profile.valid]: x => /^\d+(?:\.\d+)+$/.test(x),
    [profile.compare]: compare,
    [profile.decision]: ({manifest: m, buildVersion}) => !m || compare(m.buildVersion, buildVersion) <= 0 ? 'up-to-date' : 'should-check-store',
    [profile.beforeInstall]() {}, Date, Promise,
  });
  vm.runInContext(definitions, context);
  const store = new context.classes.Store({
    buildVersion: '1.0.0.0', packageIdentity: 'OpenAI.Codex', storeProductId: 'fixture',
    nativeAddon: {trySilentDownloadStoreUpdates: async () => {storeCalls++; if (storeError) throw storeError; return storeResult;}},
  });
  if (!allowFallback) {
    const result = await store.performCheck({allowFallback: false, bypassStoreDetectionThrottle: true});
    assert.equal(result.outcome, expected, name);
  } else {
    const fallback = {hasUpdater: () => true, getIsUpdateReady: () => fallbackCalls > 0,
      checkForUpdates: async () => {fallbackCalls++;}, checkForUpdatesInBackground: async () => {fallbackCalls++;}};
    const combined = new context.classes.Combined({storeUpdater: store, msixFallbackUpdater: fallback});
    combined.isMsixFallbackUpdaterInitialized = true;
    await combined.runCheck(manual ? 'manual' : 'background');
    assert.equal(fallbackCalls, expected, name);
    if (expected === 1) assert.equal(combined.activeUpdater, fallback, 'The official MSIX updater must become active');
  }
  if (!newer || !manifest) assert.equal(storeCalls, 0, 'No Store call without a newer manifest');
  if (newer && manifest && !storeResult?.hasUpdate) assert(!events.includes('Codex is up to date.'), 'Never report current when the manifest is newer');
  console.log(`PASS ${name}`);
}

(async () => {
  const noUpdates = {hasUpdate: false, canSilentlyDownload: true, completed: false, overallState: 'NoUpdates'};
  await check({name: 'newer manifest plus Store NoUpdates starts background MSIX download', storeResult: noUpdates, expected: 1});
  await check({name: 'manual check uses the same download fallback without a false current dialog', storeResult: noUpdates, expected: 1, manual: true});
  await check({name: 'current manifest does not start fallback', newer: false, storeResult: noUpdates, expected: 0});
  await check({name: 'missing manifest does not start fallback', manifest: false, storeResult: noUpdates, expected: 0});
  await check({name: 'completed Store download keeps Store active', storeResult: {...noUpdates, hasUpdate: true, completed: true, overallState: 'Completed'}, expected: 0});
  await check({name: 'Store without silent download uses existing fallback', storeResult: {...noUpdates, hasUpdate: true, canSilentlyDownload: false}, expected: 1});
  await check({name: 'Store download errors keep existing fallback', storeResult: {...noUpdates, hasUpdate: true, overallState: 'OtherError'}, expected: 1});
  await check({name: 'Store-only callers report update availability', storeResult: noUpdates, expected: 'update-available-in-store', allowFallback: false});
})().catch(error => {console.error(error); process.exitCode = 1;});
