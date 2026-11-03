'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const timers = require('node:timers/promises');
const { profiles, transform, patchFiles } = require('./patch-project-archive-state.cjs');

const sourceRoot = process.argv[2];
assert(sourceRoot, 'Pass the original extracted ASAR directory');
const sources = profiles.map(p => fs.readFileSync(path.join(sourceRoot, p.kind === 'archive-errors' ? 'webview/assets' : '.vite/build', p.file), 'utf8'));
const patched = sources.map((source, i) => transform(source, profiles[i]).source);
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-state-test-'));
let checks = 0;

function makeStore(source) {
  const start = source.indexOf('class el{');
  const end = source.indexOf('r.d(t,{RL:()=>el}', start);
  assert(start > 0 && end > start);
  const debounce = callback => Object.assign(callback, { cancel() {} });
  const logger = { warning() {} };
  const context = {
    n: fs, s: fs.promises, i: crypto, o: path, a: timers, J: [], ea: {},
    h: { vB: () => () => logger }, u: { sg1: debounce, yDt: () => null }, K: () => logger,
    y: { o: 'archives' }, v: 'atoms', S: 'runtime', x: 'outbox', queueMicrotask,
  };
  vm.runInNewContext(source.slice(start, end) + ';globalThis.Store=el', context);
  return context.Store;
}

function recoveryCases(source, expectBroken) {
  const Store = makeStore(source);
  const primary = path.join(fixtureRoot, `state-${expectBroken ? 'before' : 'after'}.json`);
  const backup = primary + '.bak';
  fs.writeFileSync(backup, JSON.stringify({ project: 'Antigravity' }));
  const value = new Store(primary).getStored('project');
  if (expectBroken) assert.equal(value, undefined);
  else assert.equal(value, 'Antigravity');
  checks++;
  if (expectBroken) return;
  fs.writeFileSync(primary, JSON.stringify({ project: 'Primary' }));
  assert.equal(new Store(primary).getStored('project'), 'Primary'); checks++;
  fs.writeFileSync(primary, '{');
  assert.equal(new Store(primary).getStored('project'), 'Antigravity'); checks++;
  fs.unlinkSync(backup);
  const prefix = `.${path.basename(primary)}`;
  fs.writeFileSync(path.join(fixtureRoot, prefix + '.bak.tmp-1-valid'), JSON.stringify({ project: 'Interrupted' }));
  fs.writeFileSync(path.join(fixtureRoot, prefix + '.tmp-2-invalid'), '');
  fs.utimesSync(path.join(fixtureRoot, prefix + '.tmp-2-invalid'), Date.now()/1000+10, Date.now()/1000+10);
  fs.writeFileSync(path.join(fixtureRoot, 'unrelated.json.tmp-3'), JSON.stringify({ project: 'Wrong' }));
  assert.equal(new Store(primary).getStored('project'), 'Interrupted'); checks++;
  fs.unlinkSync(primary);
  assert.equal(new Store(primary).getStored('project'), 'Interrupted'); checks++;
  fs.writeFileSync(primary, '{}');
  assert.equal(new Store(primary).getStored('project'), undefined); checks++;
  return new Store(primary);
}

function archiveSnippet(source) {
  const start = source.indexOf('let at;', source.indexOf('function kjn(){'));
  const end = source.indexOf('let ot;', start);
  assert(start > 0 && end > start);
  return '{' + source.slice(start, end) + ';globalThis.row=at;}';
}

function archiveCases(source, expectBroken) {
  const context = {
    e: [], Ee: true, ae: true, se: false, K() {}, oe() {}, Be: false, Ne: [],
    a: { formatMessage: () => 'Retry' }, GG: { retry: {} }, Cg: 'row', $: 'label',
    gK: { jsx: (type, props) => ({ type, props }) },
  };
  const snippet = archiveSnippet(source);
  vm.runInNewContext(snippet, context);
  assert(context.row, 'An empty failing archive must expose retry'); checks++;
  context.Ne = [1, 2, 3, 4, 5, 6];
  vm.runInNewContext(snippet, context);
  if (expectBroken) assert(context.row, 'Original code reproduces stale error alongside rows');
  else assert.equal(context.row, null, 'New rows must invalidate the memoized error');
  checks++;
  if (!expectBroken) {
    context.Ne = [];
    vm.runInNewContext(snippet, context);
    assert(context.row); checks++;
    context.Ee = false;
    vm.runInNewContext(snippet, context);
    assert.equal(context.row, null); checks++;
    const error = source.match(/He=(Se&&we\.some\(Njn\)\|\|Te&&W\|\|Ee&&ae)/)[1];
    const scoped = { Se: true, we: [{ failed: false }], Njn: q => q.failed, Te: false, W: true, Ee: false, ae: true };
    assert.equal(vm.runInNewContext(error, scoped), false); checks++;
    scoped.we[0].failed = true;
    assert.equal(vm.runInNewContext(error, scoped), true); checks++;
  }
}

async function membershipCases(source, expectBroken) {
  const anchor = source.match(/E\.setThreadAssignmentsEnabled\(tl\(\)\.localProjectTaskMembership[^)]*\)/)[0];
  const gate = {};
  const E = { setThreadAssignmentsEnabled: value => { gate.enabled = value; } };
  const context = { E, tl: () => ({ localProjectTaskMembership: false }), process: { platform: 'win32' } };
  vm.runInNewContext(anchor, context);
  assert.equal(gate.enabled, !expectBroken); checks++;
  const start = source.indexOf('async write(e,t,r,n,i,s,a){');
  const end = source.indexOf('async syncAssignment(', start);
  assert(start > 0 && end > start);
  const method = vm.runInNewContext('({' + source.slice(start, end) + '}).write', {
    efo: async (map, id, fn) => fn(), ec: { Q2Y: { THREAD_PROJECT_ASSIGNMENTS: 'assignments' }, RWz: () => false },
  });
  const sent = [];
  let writes = 0;
  const receiver = {
    pendingWrites: new Map(), globalState: { get: () => ({}) }, localProjectId: a => a?.projectId ?? null,
    isEnabled: () => gate.enabled, activeServerProjectId: () => 'server-project',
    connection: { sendAppServerRequest: async (...args) => sent.push(args) },
  };
  const signal = { throwIfAborted() {} };
  await method.call(receiver, 'thread', { projectKind: 'local', projectId: 'project' }, async () => { writes++; }, async () => true, signal, undefined, 'local');
  assert.equal(sent.length, expectBroken ? 0 : 1); assert.equal(writes, 1); checks++;
  if (!expectBroken) {
    sent.length = 0;
    await method.call(receiver, 'thread', { projectKind: 'local', projectId: 'project' }, async () => {}, async () => false, signal, undefined, 'local');
    assert.equal(sent.length, 0, 'Unsupported project backend stays guarded'); checks++;
    context.process.platform = 'linux';
    vm.runInNewContext(anchor, context);
    assert.equal(gate.enabled, false); checks++;
  }
}

(async () => {
  try {
    recoveryCases(sources[0], true);
    archiveCases(sources[2], true);
    await membershipCases(sources[1], true);
    const store = recoveryCases(patched[0], false);
    store.set('project', 'Durable');
    await store.flushOrThrow();
    assert.equal(new (makeStore(patched[0]))(store.getStateFilePath()).getStored('project'), 'Durable'); checks++;
    archiveCases(patched[2], false);
    await membershipCases(patched[1], false);
    for (let i = 0; i < profiles.length; i++) {
      assert.equal(transform(patched[i], profiles[i]).status, 'already-patched'); checks++;
      assert.throws(() => transform(sources[i] + 'changed', profiles[i]), /Unsupported/); checks++;
    }
    const filesRoot = path.join(fixtureRoot, 'asar');
    const backupRoot = path.join(fixtureRoot, 'backups');
    const targets = profiles.map(p => path.join(filesRoot, p.kind === 'archive-errors' ? 'webview/assets' : '.vite/build', p.file));
    function resetFiles() {
      targets.forEach((target, i) => {
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, sources[i]);
      });
    }
    resetFiles();
    patchFiles(filesRoot, backupRoot, true);
    assert(!fs.existsSync(backupRoot));
    targets.forEach((target, i) => assert.equal(fs.readFileSync(target, 'utf8'), sources[i])); checks++;
    fs.appendFileSync(targets[2], 'changed');
    assert.throws(() => patchFiles(filesRoot, backupRoot), /Unsupported/);
    assert.equal(fs.readFileSync(targets[0], 'utf8'), sources[0]);
    assert(!fs.existsSync(backupRoot)); checks++;
    resetFiles();
    patchFiles(filesRoot, backupRoot);
    targets.forEach((target, i) => {
      assert.equal(fs.readFileSync(target, 'utf8'), patched[i]);
      assert.equal(fs.readFileSync(path.join(backupRoot, profiles[i].file), 'utf8'), sources[i]);
    }); checks++;
    assert(patchFiles(filesRoot, backupRoot).every(result => result.status === 'already-patched')); checks++;
    resetFiles();
    assert(patchFiles(filesRoot, backupRoot).every(result => result.status === 'patched')); checks++;
    resetFiles();
    fs.writeFileSync(path.join(backupRoot, profiles[0].file), 'unrelated');
    assert.throws(() => patchFiles(filesRoot, backupRoot), /Existing backup/);
    targets.forEach((target, i) => assert.equal(fs.readFileSync(target, 'utf8'), sources[i])); checks++;
    console.log(JSON.stringify({ checks, originalBugsReproduced: 3, patchedPassed: true }));
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
