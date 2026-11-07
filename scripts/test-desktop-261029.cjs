'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { resolveManifest, modelExperienceKinds, planFiles, patchFiles, transform } = require('./patch-desktop-261029.cjs');

const sourceRoot = process.argv[2];
assert(sourceRoot, 'Pass the original extracted 26.1029 ASAR');
const manifest = resolveManifest(rel => fs.existsSync(path.join(sourceRoot, rel)));
const models = ['gpt-6-astra', 'fixture-model'];
const plan = planFiles(sourceRoot, models);
let checks = 0;
assert.deepEqual(plan.targets.map(target => target.file), manifest.files.map(profile => profile.file)); checks++;
for (const target of plan.targets) {
  delete target.source;
  delete target.original;
}
const projectOnlyFiles = ['.vite/build/early-bootstrap-133-485dbc70b8296756.js',
  'webview/assets/async/678916.1a2b7b8d2a.js'];
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-desktop-261029-'));
const pending = [];

async function main() {
try {
  for (const profile of manifest.files) {
    const source = fs.readFileSync(path.join(sourceRoot, profile.file), 'utf8');
    const patched = transform(source, profile, models);
    assert.equal(transform(patched.source, profile, models).status, 'already-patched');
    assert.throws(() => transform(source + 'drift', profile, models), /Unsupported/); checks += 2;
    if (profile.edits.length > 1) {
      // The complete pre-startup patch is a supported upgrade state, not a partial patch.
      const edit = profile.edits.find(edit => edit.kind?.startsWith('startup-')) ?? profile.edits[0];
      const partial = source.replace(edit.before, edit.after.replace('__MODELS_JSON__', JSON.stringify(models)));
      const modelEdits = profile.edits.filter(item => modelExperienceKinds.has(item.kind));
      if (modelEdits.length === 1 && modelEdits[0] === edit) {
        assert.equal(transform(partial, profile, models).source, patched.source);
      } else {
        assert.throws(() => transform(partial, profile, models), /Unsupported/);
      }
      checks++;
    }
    for (const edit of profile.edits.filter(edit => edit.kind === 'bundled-deep-research')) {
      const before = vm.runInNewContext('({' + edit.before + '})');
      const after = vm.runInNewContext('({' + edit.after + '})');
      assert.equal(before.isAvailable({features: {deepResearch: false}}), false);
      assert.equal(after.isAvailable({features: {deepResearch: false}}), true);
      assert.equal(after.isAvailable({features: {deepResearch: true}}), true); checks += 3;
    }
    for (const edit of profile.edits.filter(edit => edit.kind === 'ultra')) {
      const custom = edit.after.match(/&&\(([\w$]+)\|\|/)[1];
      const enabled = edit.before.match(/^[\w$]+=([\w$]+)&&/)[1];
      const gate = edit.before.match(/&&([\w$]+)\(([\w$]+)\.JW,/);
      const context = { [enabled]: true, [custom]: true, [gate[1]]: () => false, [gate[2]]: {JW: {}} };
      assert.equal(vm.runInNewContext(edit.after, context), true);
      context[custom] = false;
      assert.equal(vm.runInNewContext(edit.after, context), false);
      context[enabled] = false; context[custom] = true;
      assert.equal(vm.runInNewContext(edit.after, context), false); checks += 3;
    }
  }
  const shared = manifest.files.find(profile => profile.file.includes('/24191.'));
  const fast = shared.edits.find(edit => edit.kind === 'fast-request');
  for (const method of ['chatgpt', 'personalAccessToken', 'amazonBedrock', 'apikey']) {
    let requests = 0;
    const context = {o: {s: async () => method}, l: {Wr: async () => {requests++; return ['fast'];}, b9: 'requirements'},
      r: {W6: data => data}};
    vm.runInNewContext(fast.after + ';globalThis.invoke=p', context);
    // The shipped converter and data cache are used for every account method.
    context.pending = context.invoke({query: {setData() {}}}, 'local').then(value => {
      assert.equal(requests, 1); assert.deepEqual(Array.from(value), ['fast']); checks++;
    });
    // Await outside the vm while retaining the real async function body.
    pending.push(context.pending);
  }
  const visibility = shared.edits.find(edit => edit.kind === 'custom-models');
  const expression = visibility.after.replace('__MODELS_JSON__', JSON.stringify(models));
  const context = {s: {model: 'fixture-model', hidden: true}, e: null, i: false, o: false, a: false,
    n: 'apikey', r: new Set(), t: false, l: undefined};
  assert.equal(vm.runInNewContext(expression, context), true);
  context.s.model = 'unknown-model'; assert.equal(vm.runInNewContext(expression, context), false); checks += 2;

  const root = path.join(fixture, 'asar'), backup = path.join(fixture, 'backups');
  for (const target of plan.targets) {
    fs.mkdirSync(path.dirname(path.join(root, target.file)), {recursive: true});
    fs.writeFileSync(path.join(root, target.file), target.input);
  }
  for (const native of manifest.native) {
    if (fs.existsSync(path.join(root, native.file))) continue;
    fs.mkdirSync(path.dirname(path.join(root, native.file)), {recursive: true});
    fs.copyFileSync(path.join(sourceRoot, native.file), path.join(root, native.file));
  }
  for (const file of projectOnlyFiles) {
    assert(!plan.targets.some(target => target.file === file));
    fs.mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
    fs.copyFileSync(path.join(sourceRoot, file), path.join(root, file)); checks++;
  }
  const modelRoot = path.join(fixture, 'model-asar'), modelBackup = path.join(fixture, 'model-backups');
  fs.cpSync(root, modelRoot, {recursive: true});
  const modelPlan = planFiles(modelRoot, models, 'model-experience');
  assert.equal(modelPlan.targets.length, 21);
  assert.deepEqual(modelPlan.targets.map(target => target.file), manifest.files.filter(profile =>
    profile.edits.some(edit => modelExperienceKinds.has(edit.kind))).map(profile => profile.file)); checks += 2;
  for (const target of modelPlan.targets) {
    delete target.input;
    delete target.original;
    delete target.source;
  }
  patchFiles(modelRoot, modelBackup, models, true, 'model-experience');
  assert(!fs.existsSync(modelBackup)); checks++;
  const mixed = modelPlan.targets.find(target => target.file === shared.file);
  const originalMixed = fs.readFileSync(path.join(modelRoot, mixed.file), 'utf8');
  fs.writeFileSync(path.join(modelRoot, mixed.file), originalMixed.replace(visibility.before,
    visibility.after.replace('__MODELS_JSON__', JSON.stringify(models))));
  assert.throws(() => patchFiles(modelRoot, modelBackup, models, false, 'model-experience'), /Unsupported/);
  assert(!fs.existsSync(modelBackup)); checks += 2;
  fs.writeFileSync(path.join(modelRoot, mixed.file), originalMixed);
  patchFiles(modelRoot, modelBackup, models, false, 'model-experience');
  for (const profile of manifest.files) {
    const original = fs.readFileSync(path.join(sourceRoot, profile.file), 'utf8');
    const expected = profile.edits.filter(edit => modelExperienceKinds.has(edit.kind)).reduce((text, edit) =>
      text.replace(edit.before, () => edit.after.replace('__MODELS_JSON__', JSON.stringify(models))), original);
    assert.equal(fs.readFileSync(path.join(modelRoot, profile.file), 'utf8'), expected); checks++;
  }
  for (const file of projectOnlyFiles) {
    assert.deepEqual(fs.readFileSync(path.join(modelRoot, file)), fs.readFileSync(path.join(sourceRoot, file)));
    assert(!fs.existsSync(path.join(modelBackup, file))); checks += 2;
  }
  assert(patchFiles(modelRoot, modelBackup, models, false, 'model-experience').files.every(file => file.status === 'already-patched'));
  assert.equal(patchFiles(modelRoot, modelBackup, ['model-only-updated'], false, 'model-experience').files.filter(file => file.status === 'patched').length, 1);
  patchFiles(modelRoot, modelBackup, models);
  assert(patchFiles(modelRoot, modelBackup, models).files.every(file => file.status === 'already-patched'));
  assert(patchFiles(modelRoot, modelBackup, models, false, 'model-experience').files.every(file => file.status === 'already-patched')); checks += 4;
  patchFiles(modelRoot, modelBackup, ['full-kept'], false, 'model-experience');
  for (const target of plan.targets) {
    const profile = manifest.files.find(profile => profile.file === target.file);
    assert.equal(fs.readFileSync(path.join(modelRoot, target.file), 'utf8'), transform(target.input, profile, ['full-kept']).source); checks++;
  }
  assert.throws(() => planFiles(modelRoot, models, 'unknown'), /Unsupported desktop patch scope/); checks++;
  patchFiles(root, backup, models, true);
  assert(!fs.existsSync(backup)); checks++;
  const last = plan.targets.at(-1);
  fs.appendFileSync(path.join(root, last.file), 'unsupported');
  assert.throws(() => patchFiles(root, backup, models), /Unsupported/);
  assert.equal(fs.readFileSync(path.join(root, plan.targets[0].file), 'utf8'), plan.targets[0].input);
  assert(!fs.existsSync(backup)); checks++;
  fs.writeFileSync(path.join(root, last.file), last.input);
  const result = patchFiles(root, backup, models);
  for (const file of projectOnlyFiles) {
    assert.deepEqual(fs.readFileSync(path.join(root, file)), fs.readFileSync(path.join(sourceRoot, file)));
    assert(!fs.existsSync(path.join(backup, file))); checks += 2;
  }
  const membershipFile = manifest.files.find(profile => profile.file.includes('/early-bootstrap-632-')).file;
  const membershipAnchor = 'M.setThreadAssignmentsEnabled(tl().localProjectTaskMembership)';
  assert(fs.readFileSync(path.join(root, membershipFile), 'utf8').includes(membershipAnchor)); checks++;
  assert(result.files.every(file => file.status === 'patched'));
  assert(patchFiles(root, backup, models).files.every(file => file.status === 'already-patched')); checks += 2;
  const changed = patchFiles(root, backup, ['fixture-model-2']);
  assert.equal(changed.files.filter(file => file.status === 'patched').length, 1);
  assert(patchFiles(root, backup, ['fixture-model-2']).files.every(file => file.status === 'already-patched')); checks += 2;
  fs.appendFileSync(path.join(backup, last.file), 'drift');
  assert.throws(() => patchFiles(root, backup, ['fixture-model-3']), /backup differs/); checks++;
  await Promise.all(pending);
  console.log(JSON.stringify({checks, files: result.files.length, native: result.native.length,
    duplicatedUltraCopies: manifest.files.filter(profile => profile.edits.some(edit => edit.kind === 'ultra')).length,
    preflightAtomic: true, modelListUpdates: true}));
} finally {
  fs.rmSync(fixture, {recursive: true, force: true});
}
}
main().catch(error => { console.error(error); process.exitCode = 1; });
