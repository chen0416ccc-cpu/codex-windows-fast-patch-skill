'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const desktop = require('./patch-desktop-261029.cjs');
const project = require('./patch-project-archive-state.cjs');

const sourceRoot = process.argv[2];
assert(sourceRoot, 'Pass the original extracted 26.1029 ASAR');
const profiles = project.selectProfiles(rel => fs.existsSync(path.join(sourceRoot, rel)));
assert(profiles.some(profile => profile.compatibleEdits), 'Expected the 26.1029 membership layout');
const files = new Set([...desktop.manifest.files, ...desktop.manifest.native].map(profile => profile.file));
profiles.forEach(profile => files.add(project.relativePath(profile)));
const originals = new Map([...files].map(file => [file, fs.readFileSync(path.join(sourceRoot, file), 'utf8')]));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-desktop-project-'));
let checks = 0;

function replace(source, before, after) {
  assert.equal(source.split(before).length, 2, 'Expected one independent fixture anchor');
  return source.replace(before, () => after);
}

function reset(name) {
  const fixture = path.join(root, name);
  for (const [file, source] of originals) {
    fs.mkdirSync(path.dirname(path.join(fixture, file)), {recursive: true});
    fs.writeFileSync(path.join(fixture, file), source);
  }
  return fixture;
}

function snapshot(fixture) {
  return [...files].map(file => fs.readFileSync(path.join(fixture, file), 'utf8'));
}

function verify(fixture, state) {
  for (const [file, original] of originals) {
    let expected = original;
    const desktopProfile = desktop.manifest.files.find(profile => profile.file === file);
    for (const edit of desktopProfile?.edits ?? []) {
      if (state.full || state.models && desktop.modelExperienceKinds.has(edit.kind)) {
        expected = replace(expected, edit.before, edit.after.replace('__MODELS_JSON__', JSON.stringify(state.models)));
      }
    }
    if (state.project) {
      const projectProfile = profiles.find(profile => project.relativePath(profile) === file);
      for (const [before, after] of projectProfile?.edits ?? []) expected = replace(expected, before, after);
    }
    assert.equal(fs.readFileSync(path.join(fixture, file), 'utf8'), expected, file);
    checks++;
  }
}

const sequences = [
  ['desktop', 'project'], ['project', 'desktop'],
  ['model-experience', 'project'], ['project', 'model-experience'],
  ['desktop', 'project', 'model-experience'], ['project', 'desktop', 'model-experience'],
  ['project', 'model-experience', 'desktop'], ['model-experience', 'project', 'desktop'],
  ['desktop', 'project', 'desktop'], ['project', 'desktop', 'project'],
];

try {
  for (const [index, sequence] of sequences.entries()) {
    const fixture = reset(String(index));
    const state = {full: false, project: false, models: null};
    for (const [step, scope] of sequence.entries()) {
      const backup = path.join(root, `${index}-${step}-backup`);
      const before = snapshot(fixture);
      const models = [`fixture-model-${step}`, 'gpt-6-astra'];
      if (scope === 'project') {
        project.patchFiles(fixture, backup, true);
        assert(!fs.existsSync(backup));
        assert.deepEqual(snapshot(fixture), before); checks += 2;
        const result = project.patchFiles(fixture, backup);
        for (const [i, profile] of profiles.entries()) {
          if (result[i].status !== 'patched') continue;
          assert.equal(fs.readFileSync(path.join(backup, profile.file), 'utf8'),
            before[[...files].indexOf(project.relativePath(profile))]); checks++;
        }
        state.project = true;
        assert(project.patchFiles(fixture, backup).every(item => item.status === 'already-patched')); checks++;
      } else {
        desktop.patchFiles(fixture, backup, models, true, scope);
        assert(!fs.existsSync(backup));
        assert.deepEqual(snapshot(fixture), before); checks += 2;
        desktop.patchFiles(fixture, backup, models, false, scope);
        state.full ||= scope === 'desktop';
        state.models = models;
        assert(desktop.patchFiles(fixture, backup, models, false, scope).files.every(item => item.status === 'already-patched')); checks++;
      }
      verify(fixture, state);
    }
  }

  const fixture = reset('invalid');
  desktop.patchFiles(fixture, path.join(root, 'desktop-backup'), ['fixture-model']);
  project.patchFiles(fixture, path.join(root, 'project-backup'));
  const membership = profiles.find(profile => profile.kind === 'project-membership');
  const target = path.join(fixture, project.relativePath(membership));
  const complete = fs.readFileSync(target, 'utf8');
  const [before, after] = membership.compatibleEdits[0];
  for (const invalid of [complete + 'drift', complete.replace(after, after + after),
    complete.replace(after, before.replace('e.deepResearch', '!0'))]) {
    fs.writeFileSync(target, invalid);
    const snapshotBefore = snapshot(fixture);
    const backup = path.join(root, 'rejected-backup');
    assert.throws(() => project.patchFiles(fixture, backup), /Unsupported/);
    assert.throws(() => desktop.patchFiles(fixture, backup, ['updated-model']), /Unsupported/);
    assert.throws(() => desktop.patchFiles(fixture, backup, ['updated-model'], false, 'model-experience'), /Unsupported/);
    assert(!fs.existsSync(backup));
    assert.deepEqual(snapshot(fixture), snapshotBefore); checks += 5;
  }
  for (const [file, original] of originals) {
    assert.equal(fs.readFileSync(path.join(sourceRoot, file), 'utf8'), original); checks++;
  }
  console.log(JSON.stringify({checks, sequences: sequences.length, bidirectionalComposition: true,
    modelOnlyScopePreserved: true, exactProjectBackups: true, preflightAtomic: true}));
} finally {
  fs.rmSync(root, {recursive: true, force: true});
}
