'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const timers = require('node:timers/promises');
const assert = require('node:assert/strict');
const {selectProfiles, relativePath, transform, patchFiles} = require('./patch-project-archive-state.cjs');

const root = process.argv[2];
assert(root, 'Pass the original extracted Desktop 26.1106.6628 ASAR');
const profiles = selectProfiles(rel => fs.existsSync(path.join(root, rel)));
assert.equal(profiles[0].file, 'early-bootstrap-133-d277c7adebbd24e5.js');
const sources = profiles.map(profile => fs.readFileSync(path.join(root, relativePath(profile)), 'utf8'));
const patched = sources.map((source, index) => transform(source, profiles[index]).source);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-project-6628-'));
let checks = 0;
const keys = new Proxy({}, {get: (_, key) => String(key)});

function storeClass(source) {
  // Execute the shipped owner module instead of replacing its account boundaries.
  const bundle = {exports: {}};
  vm.runInNewContext(source, bundle);
  const owner = {};
  const load = id => {
    if (id === 78335) return crypto;
    assert.equal(id, 25838);
    return {Q2Y:keys,aiU:{global:'global-atom'},aU6:'ephemeral:',i0d:'draft:'};
  };
  load.d = (target, _, exports) => Object.assign(target, exports);
  bundle.exports.modules[60656]({}, owner, load);
  const start = source.indexOf('class eR{'), end = source.indexOf('},75211(', start);
  assert(start > 0 && end > start);
  const writes = [];
  const io = {...fs, writeFileSync(...args) {writes.push(args[2]);return fs.writeFileSync(...args);}};
  const asyncIo = {...fs.promises, async writeFile(...args) {writes.push(args[2]);return fs.promises.writeFile(...args);}};
  const logger = {warning() {}};
  const context = {n:crypto,i:io,s:asyncIo,o:path,a:timers,process,queueMicrotask,DOMException,Error,
    h:{vB:()=>()=>logger},eg:()=>logger,E:owner,S:'legacy-account-state',eO:{},ef:[100,200,400],
    u:{Q2Y:keys,sg1:cb=>Object.assign(cb,{cancel(){}}),yDt:()=>null},f:{Q:[]},
    I:{o:'archives'},B:'runtime',Q:'outbox'};
  vm.runInNewContext(source.slice(start, end) + ';globalThis.Store=eR;', context);
  return {Store:context.Store,owner,writes};
}

async function recoveryCases(source, broken) {
  const {Store,writes} = storeClass(source);
  const dir = path.join(temp, broken ? 'original' : 'patched');
  fs.mkdirSync(dir);
  const file = path.join(dir, 'state.json');
  fs.writeFileSync(file + '.bak', JSON.stringify({'local-projects':{p:{}},'thread-project-assignments':{thread:{projectId:'p'}}}));
  const recovered = new Store(file);
  assert.equal(Boolean(recovered.getStored('local-projects')), !broken); checks++;
  if (!broken) {
    assert.equal(recovered.getStored('thread-project-assignments').thread.projectId,'p'); checks++;
    fs.unlinkSync(file + '.bak');
    const valid = path.join(dir, '.state.json.tmp-valid');
    const invalid = path.join(dir, '.state.json.tmp-invalid');
    fs.writeFileSync(valid, JSON.stringify({test:'interrupted'}));
    fs.writeFileSync(invalid, '{');
    fs.utimesSync(valid,100,100); fs.utimesSync(invalid,200,200);
    fs.mkdirSync(path.join(dir,'.state.json.tmp-directory'));
    fs.writeFileSync(file,'{');
    assert.equal(new Store(file).getStored('test'),'interrupted'); checks++;
    fs.unlinkSync(valid);
    const backupTemp = path.join(dir,'.state.json.bak.tmp-valid');
    fs.writeFileSync(backupTemp,JSON.stringify({test:'backup-temp'}));
    assert.equal(new Store(file).getStored('test'),'backup-temp'); checks++;
    fs.writeFileSync(file + '.bak',JSON.stringify({test:'backup'}));
    assert.equal(new Store(file).getStored('test'),'backup'); checks++;
    fs.writeFileSync(file,JSON.stringify({test:'primary'}));
    assert.equal(new Store(file).getStored('test'),'primary'); checks++;
    fs.writeFileSync(file,'{}');
    assert.equal(new Store(file).getStored('test'),undefined); checks++;
    fs.unlinkSync(file + '.bak'); fs.unlinkSync(backupTemp); fs.writeFileSync(file,'{');
    assert.equal(new Store(file).getStored('test'),undefined); checks++;
  }
  fs.writeFileSync(file,'{}');
  const store = new Store(file);
  await store.updateAndPersist('test',()=>1);
  assert.equal(JSON.parse(fs.readFileSync(file,'utf8')).test,1); checks++;
  assert.equal(writes.length,2); checks++;
  assert(writes.every(options=>broken ? options==='utf8' : options.flush===true)); checks++;
  writes.length=0;
  store.set('test',2); await store.flushOrThrow();
  assert.equal(new Store(file).getStored('test'),2); checks++;
  assert(writes.length>=2 && writes.every(options=>broken ? options==='utf8' : options.flush===true)); checks++;
}

async function accountCases(source, name) {
  const {Store,owner} = storeClass(source);
  const file = path.join(temp,name + '.json');
  fs.writeFileSync(file,JSON.stringify({[owner.Ww]:'signed-out',[owner.Oq]:{'global-atom':'shared'},
    'electron-owner-atoms:signed-out':{custom:'signed-out'},
    'electron-owner-value:SELECTED_PROJECT:signed-out':'signed-out-project',
    'local-projects':{p:{}},'thread-project-assignments':{thread:{projectId:'p'}}}));
  const store = new Store(file);
  assert.equal(store.needsRendererContentOwner,true); checks++;
  assert.equal(store.getStored(keys.SELECTED_PROJECT),undefined); checks++;
  await assert.rejects(store.updateAndPersist(keys.SELECTED_PROJECT,()=> 'bad'),/Account is not confirmed/); checks++;
  store.confirmRendererContentOwner(null);
  assert.equal(store.getStored(keys.SELECTED_PROJECT),'signed-out-project'); checks++;
  const A={userId:'fixture-user-A',accountId:'fixture-account-A'};
  const B={userId:'fixture-user-B',accountId:'fixture-account-B'};
  store.confirmRendererContentOwner(A);
  assert.equal(store.getStored(keys.SELECTED_PROJECT),undefined); checks++;
  assert.equal(store.getStored(owner.Oq).custom,undefined); checks++;
  assert.equal(store.getStored(owner.Oq)['global-atom'],'shared'); checks++;
  store.set(keys.SELECTED_PROJECT,'project-A'); store.set(owner.Oq,{custom:'A','global-atom':'shared'});
  store.confirmRendererContentOwner(B);
  assert.equal(store.getStored(keys.SELECTED_PROJECT),undefined); checks++;
  assert.equal(store.getStored(owner.Oq).custom,undefined); checks++;
  store.set(keys.SELECTED_PROJECT,'project-B'); store.set(owner.Oq,{custom:'B','global-atom':'shared'});
  store.confirmRendererContentOwner(A);
  assert.equal(store.getStored(keys.SELECTED_PROJECT),'project-A'); checks++;
  assert.equal(store.getStored(owner.Oq).custom,'A'); checks++;
  assert.equal(store.getStored('thread-project-assignments').thread.projectId,'p'); checks++;
  const stale = store.captureRendererAccount(); store.retireRenderer();
  assert.throws(stale,/Renderer account changed/); checks++;
  const pending = store.updateAndPersist(keys.SELECTED_PROJECT,()=> 'stale');
  store.confirmRendererContentOwner(B);
  await assert.rejects(pending,/Saved account state changed/); checks++;
  await store.flushOrThrow();
  const reopened = new Store(file);
  assert.equal(reopened.getStored(keys.SELECTED_PROJECT),undefined); checks++;
  reopened.confirmRendererContentOwner(A);
  assert.equal(reopened.getStored(keys.SELECTED_PROJECT),'project-A'); checks++;
  assert.equal(reopened.getStored(owner.Oq).custom,'A'); checks++;
  await reopened.flushOrThrow();
}

async function membershipCases(source, broken) {
  const context = {T:{setThreadAssignmentsEnabled:value=>context.enabled=value},tr:()=>({localProjectTaskMembership:false}),process:{platform:'win32'}};
  const anchor = source.match(/T\.setThreadAssignmentsEnabled\(tr\(\)\.localProjectTaskMembership[^)]*\)/)[0];
  vm.runInNewContext(anchor,context);
  assert.equal(context.enabled,!broken); checks++;
  const end=source.indexOf('async syncAssignment(e,t,n){'), start=source.lastIndexOf('async write(',end);
  const writer=source.slice(start,end);
  const serialize=writer.match(/^async write\(e,t,n,r,i,s,a\)\{await (\w+)\(/)[1];
  const method=vm.runInNewContext('({'+writer+'}).write',{[serialize]:async(_,id,fn)=>fn(),ea:{Q2Y:keys,RWz:()=>false}});
  const sent=[];let writes=0;
  const receiver={pendingWrites:new Map(),globalState:{get:()=>({})},localProjectId:value=>value?.projectId??null,
    isEnabled:()=>context.enabled,activeServerProjectId:()=> 'backend',connection:{sendAppServerRequest:async(...args)=>sent.push(args)}};
  await method.call(receiver,'thread',{projectKind:'local',projectId:'p'},async()=>writes++,async()=>true,{throwIfAborted(){}},undefined,'local');
  assert.equal(sent.length,broken?0:1); assert.equal(writes,1); checks+=2;
  if (broken) return;
  assert.equal(sent[0][0],'thread/metadata/update'); assert.equal(sent[0][1].projectId,'backend'); checks+=2;
  sent.length=0;
  await method.call(receiver,'thread',{projectKind:'local',projectId:'p'},async()=>{},async()=>false,{throwIfAborted(){}},undefined,'local');
  assert.equal(sent.length,0); checks++;
  context.process.platform='linux';vm.runInNewContext(anchor,context);
  assert.equal(context.enabled,false); checks++;
}

async function main() {
  await recoveryCases(sources[0],true); await recoveryCases(patched[0],false);
  await accountCases(sources[0],'original-accounts'); await accountCases(patched[0],'patched-accounts');
  await membershipCases(sources[1],true); await membershipCases(patched[1],false);
  const fixture=path.join(temp,'fixture'), backup=path.join(temp,'backup');
  profiles.forEach((profile,index)=>{const target=path.join(fixture,relativePath(profile));fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,sources[index]);});
  patchFiles(fixture,backup,true); assert(!fs.existsSync(backup)); checks++;
  patchFiles(fixture,backup);
  for (const [index,profile] of profiles.entries()) {
    assert.equal(fs.readFileSync(path.join(backup,profile.file),'utf8'),sources[index]);
    assert.equal(transform(patched[index],profile).status,'already-patched');
    assert.throws(()=>transform(sources[index]+'drift',profile),/Unsupported/);
    if (profile.edits.length>1) {
      assert.throws(()=>transform(sources[index].replace(...profile.edits[0]),profile),/Unsupported/); checks++;
    }
    checks+=3;
  }
  assert(patchFiles(fixture,backup).every(item=>item.status==='already-patched')); checks++;
  fs.writeFileSync(path.join(fixture,relativePath(profiles[2])),sources[2]+'drift');
  const rejectedBackup=path.join(temp,'rejected-backup');
  assert.throws(()=>patchFiles(fixture,rejectedBackup),/Unsupported/); assert(!fs.existsSync(rejectedBackup)); checks+=2;
  console.log(JSON.stringify({checks,version:'26.1106.6628.0',originalDefectsReproduced:true,shippedAccountIsolation:true,flushedWrites:true,failClosed:true}));
}
main().finally(()=>fs.rmSync(temp,{recursive:true,force:true})).catch(error=>{console.error(error.stack);process.exitCode=1;});
