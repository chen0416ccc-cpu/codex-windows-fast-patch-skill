'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const profile = {
  version: '26.1103.4239.0',
  file: '.vite/build/early-bootstrap-339-ce026819bf837ba7.js',
  sha256: '3147715e4f64625f331cacd455d3474dcaa368da7579b8ed69f3d8b746509ad8',
};
const before = '- Do not create an automation to track a specific job or task through a milestone, failure, or completion. If the user asks you to watch a run or task to completion, keep checking in the current task and follow through when the requested condition is met.';
const after = '- When the user explicitly asks for scheduled or recurring follow-ups on a specific job or task, use a heartbeat automation attached to the current chat through the Automations tool. Include the requested cadence and stop condition in its prompt, and pause or delete it when that condition is met. Use a standalone cron automation only when the user explicitly asks for independent runs. For an ordinary request to watch a run to completion without scheduled follow-ups, keep checking in the current task.';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');

function replaceOnce(source, from, to) {
  assert.equal(source.split(from).length, 2, 'Expected exactly one thread automation instruction');
  return source.replace(from, () => to);
}

function transform(source) {
  let original = source;
  if (hash(original) !== profile.sha256) {
    original = replaceOnce(source, after, before);
    assert.equal(hash(original), profile.sha256, 'Unsupported or partial thread automation asset');
  }
  const output = replaceOnce(original, before, after);
  return { original, source: output, status: source === output ? 'already-patched' : 'patched' };
}

function patchFiles(root, backupRoot, checkOnly = false) {
  const target = path.join(root, profile.file);
  const input = fs.readFileSync(target, 'utf8');
  const result = transform(input);
  if (!checkOnly && result.status === 'patched') {
    const backup = path.join(backupRoot, profile.file);
    assert.equal(fs.readFileSync(target, 'utf8'), input, 'Target changed during preflight');
    if (fs.existsSync(backup)) {
      assert.equal(hash(fs.readFileSync(backup)), profile.sha256, 'Existing original backup differs');
    } else {
      fs.mkdirSync(path.dirname(backup), {recursive: true});
      fs.writeFileSync(backup, result.original, {flag: 'wx', flush: true});
    }
    fs.writeFileSync(target, result.source, {encoding: 'utf8', flush: true});
  }
  return {version: profile.version, file: profile.file, status: result.status, sha256: hash(result.source)};
}

module.exports = {profile, transform, patchFiles};
if (require.main === module) {
  const [root, backupRoot, ...flags] = process.argv.slice(2);
  assert(root && backupRoot && (flags.length === 0 || flags.length === 1 && flags[0] === '--check'),
    'Usage: patch-thread-automations.cjs <extracted-asar> <backup-root> [--check]');
  console.log(JSON.stringify(patchFiles(root, backupRoot, flags.includes('--check'))));
}
