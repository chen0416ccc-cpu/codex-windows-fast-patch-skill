'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const timers = require('node:timers/promises');
const { selectProfiles, relativePath, transform, patchFiles } = require('./patch-project-archive-state.cjs');

const sourceRoot = process.argv[2];
assert(sourceRoot, 'Pass the original extracted ASAR directory');
const profiles = selectProfiles(rel => fs.existsSync(path.join(sourceRoot, rel)));
const sources = profiles.map(p => fs.readFileSync(path.join(sourceRoot, relativePath(p)), 'utf8'));
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
  if (source.includes('function eP(e){')) return modernArchiveCases(source, expectBroken);
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

function modernArchiveCases(source, expectBroken) {
  const parentStart = source.indexOf('(0,r.jsx)(eU,{');
  const parentEnd = source.indexOf('},`${y}:', parentStart);
  assert(parentStart > 0 && parentEnd > parentStart);
  const parent = source.slice(parentStart + '(0,r.jsx)(eU,'.length, parentEnd + 1);
  const context = {
    e_: [1, 2, 3, 4, 5, 6], j: null, eI: [], y: 'local', S: true, ex: false, eC: false,
    ey: [1, 2, 3, 4, 5, 6], q: [{}, {data: [], isError: true}], U: 'disconnected',
    d() {}, c() {}, ew: false, eP: false, K: false, Y: true, ei: false, el: {fI: 'local'},
    ef: false, z: false, en: false, Q: [], Z: false, J: undefined, ec: true,
    eh: Error('An unrelated account source failed'), h() {}, v() {},
  };
  const start = source.indexOf('Y[109]');
  const end = source.indexOf(',Y[117]', start);
  assert(start > 0 && end > start);
  const snippet = '{' + source.slice(start, end) + ';globalThis.row=K;}';
  const row = {
    Y: [], eC: false, eI() {}, ej() {}, ef() {}, ee: context.e_,
    r: {jsx: (type, props) => ({type, props})}, en: {t: 'row'}, ei: {ic: 'label'},
    k: {A: 'text'}, E: {$: 'button'}, N: {p: {retry: {}}},
  };
  function render() {
    const props = vm.runInNewContext('(' + parent + ')', context);
    row.eA = props.chatGptArchiveError;
    row.tr = props.isLocalArchiveError;
    row.ti = props.isDurableArchiveError;
    row.ee = context.e_;
    vm.runInNewContext(snippet, row);
    return row.row;
  }
  assert.equal(Boolean(render()), expectBroken, 'Loaded local rows with an empty failed durable/account source'); checks++;
  if (expectBroken) return;
  context.e_ = []; context.ey = []; context.eC = true;
  let result = render();
  assert(result, 'Empty failures retain retry'); checks++;
  let called = [];
  row.ef = () => called.push('local'); row.ej = () => called.push('durable'); row.eI = () => called.push('account');
  result = render(); result.props.children.props.control.props.onClick();
  assert.deepEqual(called, ['local', 'durable', 'account']); checks++;
  context.e_ = [1];
  assert.equal(render(), null, 'Rows invalidate the same memo even when all error props stay true'); checks++;
  context.e_ = [];
  assert(render(), 'Removing all rows restores the failed empty state'); checks++;
  context.eC = false; context.q[1].isError = false; context.U = 'connected'; context.ec = false;
  assert.equal(render(), null, 'Empty success remains error free'); checks++;
  context.eC = true; context.q[1].data = [1]; context.ey = [1];
  const props = vm.runInNewContext('(' + parent + ')', context);
  assert.equal(props.isLocalArchiveError, false);
  assert.equal(props.isDurableArchiveError, false); checks++;
}

async function membershipCases(source, expectBroken) {
  const anchor = source.match(/[EM]\.setThreadAssignmentsEnabled\(tl\(\)\.localProjectTaskMembership[^)]*\)/)[0];
  const gate = {};
  const E = { setThreadAssignmentsEnabled: value => { gate.enabled = value; } };
  const context = { E, M: E, tl: () => ({ localProjectTaskMembership: false }), process: { platform: 'win32' } };
  vm.runInNewContext(anchor, context);
  assert.equal(gate.enabled, !expectBroken); checks++;
  const start = source.indexOf('async write(e,t,r,n,i,s,a){');
  const end = source.indexOf('async syncAssignment(', start);
  assert(start > 0 && end > start);
  const method = vm.runInNewContext('({' + source.slice(start, end) + '}).write', {
    efo: async (map, id, fn) => fn(), efq: async (map, id, fn) => fn(), ec: { Q2Y: { THREAD_PROJECT_ASSIGNMENTS: 'assignments' }, RWz: () => false },
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
    if (profiles[1].file === 'early-bootstrap-632-62c641245a52ef0e.js') {
      const [before, after] = profiles[1].compatibleEdits[0];
      const fullSource = sources[1].replace(before, after);
      const full = patched[1].replace(before, after);
      assert.equal(transform(fullSource, profiles[1]).source, full);
      assert.equal(transform(fullSource, profiles[1]).status, 'patched');
      assert.equal(transform(full, profiles[1]).status, 'already-patched');
      assert.throws(() => transform(fullSource + 'changed', profiles[1]), /Unsupported/);
      assert.throws(() => transform(full + 'changed', profiles[1]), /Unsupported/); checks += 5;
    }
    const filesRoot = path.join(fixtureRoot, 'asar');
    const backupRoot = path.join(fixtureRoot, 'backups');
    const targets = profiles.map(p => path.join(filesRoot, relativePath(p)));
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
