'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const {profiles, transform, patchFiles} = require('./patch-thread-automations.cjs');

const sourceRoot = process.argv[2];
assert(sourceRoot, 'Pass the extracted Desktop 26.1103.4239 ASAR');
const profile = profiles.find(p => fs.existsSync(path.join(sourceRoot, p.file)));
assert(profile, "Pass a supported thread automation layout");
const original = fs.readFileSync(path.join(sourceRoot, profile.file), 'utf8');
const patched = transform(original).source;
let checks = 0;

// Evaluate the actual template consumed by the Desktop instruction builder.
function instructions(source) {
  const start = source.indexOf('`### Automations\n');
  const end = source.indexOf('`,', start) + 1;
  assert(start >= 0 && end > start);
  const lookup = source.match(/aJ=("(?:[^"\\]|\\.)*");/);
  return {start, end, text: vm.runInNewContext(source.slice(start, end),
    {st:'AUTOMATION_TOOL_LOOKUP',Y:'AUTOMATION_TOOL_LOOKUP',aJ:lookup?JSON.parse(lookup[1]):undefined,C:{H43:10000}})};
}
const oldPrompt = instructions(original);
const newPrompt = instructions(patched);
assert.match(oldPrompt.text, /Do not create an automation to track a specific job/);
assert.doesNotMatch(newPrompt.text, /Do not create an automation to track a specific job/);
assert.match(newPrompt.text, /explicitly asks for scheduled or recurring follow-ups/);
assert.match(newPrompt.text, /heartbeat automation attached to the current chat/);
assert.match(newPrompt.text, /pause or delete it when that condition is met/);
assert.match(newPrompt.text, /ordinary request[\s\S]*keep checking in the current task/);
assert.match(newPrompt.text, /Unless the user asks for periodic updates/);
assert.match(newPrompt.text, profile.version==='26.1106.6628.0'?/search for the `automation_update` tool first/:/AUTOMATION_TOOL_LOOKUP/);
assert.match(newPrompt.text, /set_thread_archived/);
assert.equal(patched.slice(0, newPrompt.start), original.slice(0, oldPrompt.start));
assert.equal(patched.slice(newPrompt.end), original.slice(oldPrompt.end));
assert.equal(transform(patched).status, 'already-patched');
const syntax = spawnSync(process.execPath, ['--check', '--input-type=commonjs'],
  {input: patched, encoding: 'utf8', windowsHide: true});
assert.equal(syntax.status, 0, syntax.stderr);
checks += 13;

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-thread-automation-'));
const target = path.join(root, 'asar', profile.file);
const backupRoot = path.join(root, 'backup');
try {
  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.writeFileSync(target, original);
  assert.equal(patchFiles(path.join(root, 'asar'), backupRoot, true).status, 'patched');
  assert.equal(fs.readFileSync(target, 'utf8'), original);
  assert.equal(fs.existsSync(backupRoot), false);
  patchFiles(path.join(root, 'asar'), backupRoot);
  assert.equal(fs.readFileSync(target, 'utf8'), patched);
  assert.equal(fs.readFileSync(path.join(backupRoot, profile.file), 'utf8'), original);
  assert.equal(patchFiles(path.join(root, 'asar'), backupRoot).status, 'already-patched');
  checks += 6;
  const instruction = newPrompt.text.split('\n').find(line => line.includes('heartbeat automation'));
  for (const invalid of [original + '\n// drift', patched + '\n// drift',
    original.replace('Do not create an automation', 'Never create an automation'),
    patched.replace(instruction, instruction + '\n' + instruction),
    patched.replace('stop condition', 'completion condition')]) {
    fs.writeFileSync(target, invalid);
    assert.throws(() => patchFiles(path.join(root, 'asar'), backupRoot));
    assert.equal(fs.readFileSync(target, 'utf8'), invalid);
    assert.equal(fs.readFileSync(path.join(backupRoot, profile.file), 'utf8'), original);
    checks += 3;
  }
  fs.writeFileSync(target, original);
  fs.writeFileSync(path.join(backupRoot, profile.file), 'unrelated backup');
  assert.throws(() => patchFiles(path.join(root, 'asar'), backupRoot), /backup differs/);
  assert.equal(fs.readFileSync(target, 'utf8'), original);
  checks += 2;
} finally {
  fs.rmSync(root, {recursive: true, force: true});
}
console.log(JSON.stringify({checks, version: profile.version, generatedPrompt: true,
  unrelatedCodePreserved: true, failClosed: true}));
