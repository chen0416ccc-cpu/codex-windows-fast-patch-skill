const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const MARKER = 'CODEX_WINDOWS_STORE_FALLBACK_V1';
const ORIGINAL = 'if(S7().info(`Windows Store package update check completed`,{safe:{canSilentlyDownload:i.canSilentlyDownload,completed:i.completed,hasUpdate:i.hasUpdate,overallState:i.overallState},sensitive:{}}),!i.hasUpdate)return this.setUpdateReady(!1),this.setUpdateLifecycleState(`idle`),{decision:{kind:`handled`},outcome:`up-to-date`};';
const REPLACEMENT = 'if(S7().info(`Windows Store package update check completed`,{safe:{canSilentlyDownload:i.canSilentlyDownload,completed:i.completed,hasUpdate:i.hasUpdate,overallState:i.overallState},sensitive:{}}),!i.hasUpdate){this.setUpdateReady(!1),this.setUpdateLifecycleState(`idle`);let codexManifestHasUpdate=n!=null&&f7(this.options.buildVersion)&&d7(n.buildVersion,this.options.buildVersion)>0;return e&&codexManifestHasUpdate?{decision:{kind:`fallback`,reason:`store-no-update-for-newer-manifest`},outcome:null}:{decision:{kind:`handled`},outcome:codexManifestHasUpdate?`update-available-in-store`:`up-to-date`}}/*CODEX_WINDOWS_STORE_FALLBACK_V1*/';

const PROFILES = [
  {original: ORIGINAL, replacement: REPLACEMENT, logger: 'S7', manifest: 'b7', valid: 'f7', compare: 'd7', decision: 'x7', beforeInstall: 'y7'},
  {
    original: ORIGINAL.replaceAll('S7()', 'p7()'),
    replacement: REPLACEMENT.replaceAll('S7()', 'p7()').replaceAll('f7(', 'i7(').replaceAll('d7(', 'r7('),
    logger: 'p7', manifest: 'd7', valid: 'i7', compare: 'r7', decision: 'f7', beforeInstall: 'o7',
  },
  {
    original: ORIGINAL.replaceAll('S7()', 'jn()'),
    replacement: REPLACEMENT.replaceAll('S7()', 'jn()').replaceAll('f7(', 'yn(').replaceAll('d7(', 'vn('),
    logger: 'jn', loggerObject: 'c', electronObject: 'f', manifest: 'kn', valid: 'yn', compare: 'vn', decision: 'An',
  },
];

const OFFERS_PROFILE = {
  required: [
    'if(fn(n.buildVersion,this.options.buildVersion)>0)t=n.buildVersion;',
    'r=fn(n,this.options.buildVersion)>0;',
  ],
  changes: [
    {
      original: 'this.lastStoreResult=e.hasUpdate?{source:`store`,canSilentlyDownload:e.canSilentlyDownload}:{source:`none`},this.lastStoreResult',
      replacement: 'this.lastStoreResult=e.hasUpdate?{source:`store`,canSilentlyDownload:e.canSilentlyDownload}:t!=null&&/^\\d+(?:\\.\\d+)*$/.test(this.options.buildVersion)&&fn(t,this.options.buildVersion)>0?await this.discoverStoreFallback():{source:`none`},this.lastStoreResult/*CODEX_WINDOWS_STORE_FALLBACK_V1*/',
    },
    {
      original: 'recordStoreNoUpdate(){return this.serializeOfferOperation(async()=>{this.storeDownloadAttemptAvailable=!1,this.lastStoreResult={source:`none`},this.lastStoreCheckAtMs=Date.now(),await this.invalidatePreparedUpdate?.()})}',
      replacement: 'recordStoreNoUpdate(){return this.serializeOfferOperation(async()=>{this.storeDownloadAttemptAvailable=!1;let codexStoreMarker=this.lastCheckedMarker,codexStoreFallback=codexStoreMarker!=null&&/^\\d+(?:\\.\\d+)*$/.test(this.options.buildVersion)&&fn(codexStoreMarker,this.options.buildVersion)>0?await this.discoverStoreFallback():{source:`none`};return this.lastStoreResult=codexStoreFallback,this.lastStoreCheckAtMs=Date.now(),await this.invalidatePreparedUpdate?.(),codexStoreFallback})}',
    },
    {
      original: 'return r.hasUpdate||await this.options.offers.recordStoreNoUpdate(),r.hasUpdate&&r.canSilentlyDownload&&r.completed?',
      replacement: 'let codexStoreNoUpdateFallback=!r.hasUpdate&&await this.options.offers.recordStoreNoUpdate();return codexStoreNoUpdateFallback?.source===`store-unavailable`?(this.setUpdateReady(!1),this.setUpdateLifecycleState(`idle`),e?{decision:{kind:`fallback`,reason:`store-no-update-for-newer-manifest`},outcome:null}:{decision:{kind:`handled`},outcome:`update-available-in-store`}):codexStoreNoUpdateFallback?.source===`waiting`?(this.setUpdateReady(!1),this.setUpdateLifecycleState(`idle`),{decision:{kind:`waiting`},outcome:`waiting-for-store`}):r.hasUpdate&&r.canSilentlyDownload&&r.completed?',
    },
  ],
};

function patchText(source) {
  if (!source.includes('windows-store-updater') || !source.includes('msixFallbackUpdater') ||
      !source.includes('checkForUpdatesWithFallbackDecision') ||
      !(source.includes('async downloadUpdatePackage(') ||
        (source.includes('async checkForUpdateInformation(') && source.includes('async checkMsixFallback(') &&
         source.includes('async discardPreparedUpdate(')))) {
    throw new Error('Unsupported Windows updater layout; no files changed');
  }
  const count = fragment => source.split(fragment).length - 1;
  const variants = [...PROFILES.map(profile => [profile]), OFFERS_PROFILE.changes];
  const supported = changes => changes !== OFFERS_PROFILE.changes || OFFERS_PROFILE.required.every(fragment => count(fragment) === 1);
  if (source.includes(MARKER)) {
    const noOriginals = !variants.some(changes => changes.some(change => count(change.original) !== 0));
    const patched = variants.filter(changes => supported(changes) && changes.every(change => count(change.replacement) === 1));
    if (count(MARKER) === 1 && patched.length === 1 && noOriginals) return {state: 'already-patched', source};
    // A previous local overlay called the appcast URL helper `un` as a version comparator.
    const previous = OFFERS_PROFILE.changes.map(change => change.replacement.replaceAll('fn(', 'un('));
    if (count(MARKER) === 1 && noOriginals && supported(OFFERS_PROFILE.changes) &&
        previous.every(fragment => count(fragment) === 1)) {
      let repaired = source;
      for (let i = 0; i < previous.length; i++) repaired = repaired.replace(previous[i], OFFERS_PROFILE.changes[i].replacement);
      return {state: 'patched', source: repaired};
    }
    throw new Error('Partial or ambiguous Windows updater patch; no files changed');
  }
  const profiles = variants.filter(changes => supported(changes) && changes.every(change => count(change.original) === 1));
  const originalCount = variants.reduce((sum, changes) => sum + changes.reduce((total, change) => total + count(change.original), 0), 0);
  if (profiles.length !== 1 || originalCount !== profiles[0].length) {
    throw new Error('Expected exactly one Windows Store NoUpdates branch; no files changed');
  }
  let patchedSource = source;
  for (const change of profiles[0]) patchedSource = patchedSource.replace(change.original, change.replacement);
  return {state: 'patched', source: patchedSource};
}

if (require.main === module) {
  try {
    const root = path.resolve(process.argv[2]);
    if (/(?:^|[\\/])WindowsApps(?:[\\/]|$)/i.test(root)) throw new Error('Refusing WindowsApps writes');
    const candidates = fs.readdirSync(root).filter(name => name.endsWith('.js')).map(name => path.join(root, name))
      .filter(file => fs.readFileSync(file, 'utf8').includes('windows-store-updater'));
    if (candidates.length !== 1) throw new Error(`Expected one Windows updater asset, found ${candidates.length}`);
    const file = candidates[0];
    const result = patchText(fs.readFileSync(file, 'utf8'));
    const syntax = spawnSync(process.execPath, ['--check', '--input-type=commonjs'], {input: result.source, encoding: 'utf8'});
    if (syntax.status !== 0) throw new Error(syntax.stderr || 'Windows updater syntax validation failed');
    if (result.state === 'patched') fs.writeFileSync(file, result.source);
    console.log(result.state);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {patchText, ORIGINAL, REPLACEMENT, MARKER, PROFILES, OFFERS_PROFILE};
