'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const desktop = require('./patch-desktop-261029.cjs');
const project = require('./patch-project-archive-state.cjs');
const legacyAvailability = 'isAvailable:()=>!0/*codex_windows_deep_research_bundled_plugin_available*/';
let checks = 0;

for (const layout of desktop.layouts()) {
  const profile = layout.files.find(profile => profile.edits.some(edit => edit.kind === 'bundled-deep-research'));
  const edit = profile.edits.find(edit => edit.kind === 'bundled-deep-research');
  for (const enabled of [undefined, false, true]) {
    // A deliberately auto-installing catalog makes an inherited default observable.
    const saved = enabled === undefined ? {} : {'deep-research@openai-bundled': {enabled}};
    const before = JSON.stringify(saved);
    const descriptor = vm.runInNewContext('({...catalog,' + edit.after + '})', {
      catalog: {name: 'deep-research', installWhenMissing: true}, saved
    });
    assert.equal(descriptor.isAvailable({features: {deepResearch: false}}), true);
    assert.equal(descriptor.installWhenMissing, false);
    assert.equal(JSON.stringify(saved), before);
    checks += 3;
  }
}

for (const root of process.argv.slice(2)) {
  const layout = desktop.resolveManifest(rel => fs.existsSync(path.join(root, rel)));
  const profile = layout.files.find(profile => profile.edits.some(edit => edit.kind === 'bundled-deep-research'));
  const edit = profile.edits.find(edit => edit.kind === 'bundled-deep-research');
  const original = fs.readFileSync(path.join(root, profile.file), 'utf8');
  const safe = desktop.transform(original, profile, ['fixture-model']).source;
  const membership = project.profiles.find(candidate => candidate.kind === 'project-membership' &&
    project.relativePath(candidate) === profile.file);
  const prior = safe.replace(edit.after, legacyAvailability);
  const preStartup = profile.edits.filter(item => !item.kind?.startsWith('startup-')).reduce((source, item) =>
    source.replace(item.before, item.legacyAfter ?? item.after.replace('__MODELS_JSON__', '["fixture-model"]')), original);
  assert.notEqual(prior, safe);
  assert.equal(desktop.transform(prior, profile, ['fixture-model']).source, safe);
  assert.equal(desktop.transform(preStartup, profile, ['fixture-model']).source, safe);
  assert.equal(desktop.transform(safe, profile, ['fixture-model']).status, 'already-patched');
  checks += 4;
  if (membership) {
    for (const source of new Set([safe, prior, preStartup])) {
      const withProject = project.transform(source, membership).source;
      const upgraded = desktop.transform(withProject, profile, ['fixture-model']).source;
      const expected = project.transform(safe, membership).source;
      assert.equal(upgraded, expected);
      assert.equal(project.transform(upgraded, membership).status, 'already-patched');
      assert.equal(desktop.transform(upgraded, profile, ['fixture-model']).status, 'already-patched');
      checks += 3;
    }
  }
  for (const bad of [prior + 'drift', safe.replace(edit.after, edit.after + edit.after),
    safe.replace(edit.after, edit.after.replace('installWhenMissing:!1', 'installWhenMissing:!0'))]) {
    assert.throws(() => desktop.transform(bad, profile, ['fixture-model']), /Unsupported/);
    if (membership) assert.throws(() => project.transform(bad, membership), /Unsupported/);
    checks += membership ? 2 : 1;
  }
  if (layout.version === '26.1103.4239.0') {
    // Execute the shipped install selection and reason expressions, not a replacement reconciler.
    const selection = original.match(/p=(t\.marketplacePluginDescriptors\.filter\(e=>!0===e\.installWhenMissing\)[\s\S]+?\.map\(e=>e\.name\)),m=/);
    const reason = original.match(/if\(p=(\(h=\{forceInstall:c,installWhenMissing:S,installedPluginStatus:s\}\)[\s\S]+?),null==p\)/);
    assert(selection && reason, 'Expected the pinned native reconciliation policy');
    for (const enabled of [undefined, false, true]) {
      const saved = enabled === undefined ? {} : {'deep-research@openai-bundled': {enabled}};
      const baseline = JSON.stringify(saved);
      const descriptor = vm.runInNewContext('({name:"deep-research",installWhenMissing:true,' + edit.after + '})');
      const names = vm.runInNewContext(selection[1], {t: {marketplacePluginDescriptors: [descriptor]}});
      const result = vm.runInNewContext(reason[1], {
        c: false, S: names.includes(descriptor.name), s: enabled === undefined ? 'missing' : 'current', saved
      });
      assert.equal(names.length, 0);
      assert.equal(result, null, 'No install/reinstall for missing, enabled or disabled plugins');
      assert.equal(JSON.stringify(saved), baseline);
      checks += 3;
    }
  }
}

console.log(JSON.stringify({checks, layouts: desktop.layouts().length, discoveryOnly: true,
  legacyUpgrade: true, userChoicesPreserved: true}));
