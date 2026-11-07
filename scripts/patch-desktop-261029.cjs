'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const manifest = require('./desktop-261029-profiles.json');
const desktop261103 = require('./desktop-261103-profiles.json');
const desktop2611034239 = require('./desktop-2611034239-profiles.json');
const { profiles: projectProfiles, relativePath: projectPath } = require('./patch-project-archive-state.cjs');
const modelExperienceKinds = new Set(['custom-models', 'fast-request', 'fast-ui', 'ultra']);

const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function replaceOnce(source, before, after) {
  assert.equal(source.split(before).length - 1, 1, 'Expected one complete patch anchor');
  return source.replace(before, () => after);
}

// Later 26.1029 builds rename hashed bundles while keeping every anchor; each
// variant pins the renamed file and its complete original hash.
function layouts() {
  return [{ version: manifest.version, files: manifest.files, native: manifest.native },
    ...(manifest.variants ?? []).map(variant => {
      const swap = profile => variant.files[profile.file] ? { ...profile, ...variant.files[profile.file] } : profile;
      return { version: variant.version, files: manifest.files.map(swap), native: manifest.native.map(swap) };
    }), desktop261103, desktop2611034239];
}

function resolveManifest(hasFile) {
  const matches = layouts().filter(layout => layout.files.every(profile => hasFile(profile.file)));
  if (matches.length !== 1) throw new Error(`Expected one complete supported desktop layout, found ${matches.length}`);
  return matches[0];
}

function validateModels(models) {
  assert(Array.isArray(models) && models.length > 0 && models.every(model =>
    typeof model === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$/.test(model)), 'Pass nonempty model identifiers');
  return [...new Set(models)];
}

function selectEdits(profile, scope) {
  assert(['desktop', 'model-experience'].includes(scope), 'Unsupported desktop patch scope');
  return scope === 'desktop' ? profile.edits : profile.edits.filter(edit => modelExperienceKinds.has(edit.kind));
}

function restoreState(source, profile) {
  const membership = projectProfiles.find(candidate => candidate.kind === 'project-membership' &&
    projectPath(candidate) === profile.file && candidate.sha256.includes(profile.sha256));
  const states = [{ source, projectEdits: [] }];
  if (membership) {
    try {
      states.push({ source: [...membership.edits].reverse().reduce((text, [before, after]) =>
        replaceOnce(text, after, before), source), projectEdits: membership.edits });
    } catch {}
  }
  // An opt-in membership edit may coexist, but must restore the same pinned hash.
  for (const state of states) {
    if (hash(state.source) === profile.sha256) return { original: state.source, appliedEdits: [], projectEdits: state.projectEdits };
    const legacyEdits = profile.edits.filter(edit => !edit.kind?.startsWith('startup-'));
    for (const edits of [profile.edits, legacyEdits, selectEdits(profile, 'model-experience')].filter(edits => edits.length)) {
      let original = state.source;
      try {
        for (const edit of [...edits].reverse()) {
          if (edit.after.includes('__MODELS_JSON__')) {
            const [prefix, suffix] = edit.after.split('__MODELS_JSON__');
            const matches = [...original.matchAll(new RegExp(escape(prefix) + '(\\[[^\\r\\n]*?\\])' + escape(suffix), 'g'))];
            assert.equal(matches.length, 1, 'Expected one pinned model override');
            validateModels(JSON.parse(matches[0][1]));
            original = replaceOnce(original, matches[0][0], edit.before);
          } else {
            original = replaceOnce(original, edit.after, edit.before);
          }
        }
        assert.equal(hash(original), profile.sha256, 'Restored file hash differs');
        return { original, appliedEdits: edits, projectEdits: state.projectEdits };
      } catch {}
    }
  }
  throw new Error(`Unsupported or partial desktop asset ${profile.file}: ${hash(source)}`);
}

function restore(source, profile) {
  return restoreState(source, profile).original;
}

function transform(source, profile, models, scope = 'desktop') {
  const requested = selectEdits(profile, scope);
  const { original, appliedEdits, projectEdits } = restoreState(source, profile);
  // A targeted model update must not remove an existing complete desktop patch.
  const edits = profile.edits.filter(edit => requested.includes(edit) || appliedEdits.includes(edit));
  const desktop = edits.reduce((text, edit) => replaceOnce(text, edit.before,
    edit.after.replace('__MODELS_JSON__', () => JSON.stringify(models))), original);
  const output = projectEdits.reduce((text, [before, after]) => replaceOnce(text, before, after), desktop);
  return { original, source: output, status: source === output ? 'already-patched' : 'patched' };
}

function planFiles(root, models, scope = 'desktop') {
  models = validateModels(models);
  const layout = resolveManifest(rel => fs.existsSync(path.join(root, rel)));
  const targets = new Map();
  for (const profile of layout.files) {
    if (!selectEdits(profile, scope).length) continue;
    assert(!targets.has(profile.file), 'Overlapping patch profiles');
    const input = fs.readFileSync(path.join(root, profile.file), 'utf8');
    targets.set(profile.file, { file: profile.file, input, kinds: profile.edits.map(edit => edit.kind),
      ...transform(input, profile, models, scope) });
  }
  const native = layout.native.map(profile => {
    let source = targets.get(profile.file)?.original ?? fs.readFileSync(path.join(root, profile.file), 'utf8');
    const desktopProfile = layout.files.find(target => target.file === profile.file);
    if (desktopProfile) source = restore(source, desktopProfile);
    assert.equal(hash(source), profile.sha256, `Unsupported native asset: ${profile.file}`);
    for (const witness of profile.witnesses) assert(source.includes(witness), `Missing native behavior in ${profile.file}`);
    return { file: profile.file, status: 'already-open-native', sha256: profile.sha256 };
  });
  return { version: layout.version, targets: [...targets.values()], native };
}

function patchFiles(root, backupRoot, models, checkOnly = false, scope = 'desktop') {
  const plan = planFiles(root, models, scope);
  if (!checkOnly) {
    for (const target of plan.targets) {
      assert.equal(fs.readFileSync(path.join(root, target.file), 'utf8'), target.input, 'Target changed during preflight');
      const backup = path.join(backupRoot, target.file);
      if (fs.existsSync(backup)) assert.equal(hash(fs.readFileSync(backup)), hash(target.original), 'Existing original backup differs');
    }
    for (const target of plan.targets.filter(target => target.status === 'patched')) {
      const backup = path.join(backupRoot, target.file);
      fs.mkdirSync(path.dirname(backup), { recursive: true });
      if (!fs.existsSync(backup)) fs.writeFileSync(backup, target.original, { flag: 'wx', flush: true });
    }
    for (const target of plan.targets.filter(target => target.status === 'patched')) {
      fs.writeFileSync(path.join(root, target.file), target.source, { encoding: 'utf8', flush: true });
    }
  }
  return { version: plan.version, scope, files: plan.targets.map(target => ({ file: target.file,
    status: target.status, kinds: target.kinds, sha256: hash(target.source) })), native: plan.native };
}

module.exports = { manifest, layouts, resolveManifest, modelExperienceKinds, validateModels, restore, transform, planFiles, patchFiles };
if (require.main === module) {
  const [root, backupRoot, modelsJson, ...flags] = process.argv.slice(2);
  assert(root && backupRoot && modelsJson && flags.every(flag => ['--check', '--model-experience'].includes(flag)) &&
    new Set(flags).size === flags.length,
    'Usage: patch-desktop-261029.cjs <extracted-asar> <backup-root> <models.json> [--check] [--model-experience]');
  console.log(JSON.stringify(patchFiles(root, backupRoot, JSON.parse(fs.readFileSync(modelsJson, 'utf8').replace(/^\uFEFF/, '')),
    flags.includes('--check'), flags.includes('--model-experience') ? 'model-experience' : 'desktop')));
}
