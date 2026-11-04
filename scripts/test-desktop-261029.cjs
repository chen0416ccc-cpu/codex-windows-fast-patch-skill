'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { manifest, planFiles, patchFiles, transform } = require('./patch-desktop-261029.cjs');

const sourceRoot = process.argv[2];
assert(sourceRoot, 'Pass the original extracted 26.1029 ASAR');
const models = ['gpt-6-astra', 'fixture-model'];
const plan = planFiles(sourceRoot, models);
let checks = 0;
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
      const edit = profile.edits[0];
      const partial = source.replace(edit.before, edit.after.replace('__MODELS_JSON__', JSON.stringify(models)));
      assert.throws(() => transform(partial, profile, models), /Unsupported/); checks++;
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
  const bundled = manifest.files.find(profile => profile.edits.some(edit => edit.kind === 'bundled-deep-research'));
  const membership = require('./patch-project-archive-state.cjs').profiles.find(profile =>
    require('./patch-project-archive-state.cjs').relativePath(profile) === bundled.file);
  const legacy = membership.edits.reduce((text, [before, after]) => text.replace(before, after),
    fs.readFileSync(path.join(sourceRoot, bundled.file), 'utf8'));
  fs.writeFileSync(path.join(root, bundled.file), legacy);
  const legacyUpgrade = planFiles(root, models).targets.find(target => target.file === bundled.file);
  assert.equal(legacyUpgrade.source.includes(bundled.edits[0].after), true);
  assert.equal(legacyUpgrade.source.includes(membership.edits[0][1]), true);
  fs.writeFileSync(path.join(root, bundled.file), fs.readFileSync(path.join(sourceRoot, bundled.file))); checks += 2;
  patchFiles(root, backup, models, true);
  assert(!fs.existsSync(backup)); checks++;
  const last = plan.targets.at(-1);
  fs.appendFileSync(path.join(root, last.file), 'unsupported');
  assert.throws(() => patchFiles(root, backup, models), /Unsupported/);
  assert.equal(fs.readFileSync(path.join(root, plan.targets[0].file), 'utf8'), plan.targets[0].input);
  assert(!fs.existsSync(backup)); checks++;
  fs.writeFileSync(path.join(root, last.file), last.input);
  const result = patchFiles(root, backup, models);
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
