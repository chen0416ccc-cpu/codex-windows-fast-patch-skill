'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const timers = require('node:timers/promises');
const assert = require('node:assert/strict');
const {selectProfiles, relativePath, transform, patchFiles} = require('./patch-project-archive-state.cjs');
const desktop = require('./patch-desktop-261029.cjs');
const root = process.argv[2];
const profiles = selectProfiles(rel => fs.existsSync(path.join(root, rel)));
assert.equal(profiles.length, 3);
assert.equal(profiles[0].file, 'early-bootstrap-133-1c544c3280919085.js');
const sources = profiles.map(p => fs.readFileSync(path.join(root, relativePath(p)), 'utf8'));
const patched = sources.map((s, i) => transform(s, profiles[i]).source);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-project-4239-'));
let checks = 0;
function storeClass(source) {
  const start = source.indexOf('class eh{'), end = source.indexOf('},75211(', start);
  assert(start > 0 && end > start);
  const logger = {warning() {}};
  const context = {n:fs,s:fs.promises,i:crypto,o:path,a:timers,process,queueMicrotask,
    h:{vB:()=>()=>logger},ei:()=>logger,u:{sg1:cb=>Object.assign(cb,{cancel(){}}),yDt:()=>null,nh0:['local-projects','thread-project-assignments']},
    ep:{},er:[],m:'account-state',R:'atoms',I:'runtime',P:'outbox',k:{o:'archives'},b:new Set(),y:e=>e.id};
  vm.runInNewContext(source.slice(start,end)+';globalThis.Store=eh;',context);
  return context.Store;
}
async function stateCases(source, broken) {
  const Store = storeClass(source);
  const file = path.join(temp, broken ? 'broken.json' : 'patched.json');
  fs.writeFileSync(file+'.bak', JSON.stringify({'local-projects':{p:{name:'project'}}}));
  assert.equal(Boolean(new Store(file).getStored('local-projects')), !broken); checks++;
  if (!broken) {
    fs.unlinkSync(file+'.bak');
    fs.writeFileSync(path.join(temp,'.'+path.basename(file)+'.tmp-valid'),JSON.stringify({test:'recovered'}));
    fs.writeFileSync(file,'{');
    assert.equal(new Store(file).getStored('test'),'recovered');checks++;
    fs.writeFileSync(file,'{}');
    assert.equal(new Store(file).getStored('test'),undefined);checks++;
  }
  fs.writeFileSync(file,JSON.stringify({'account-state':{owner:null,inactive:{}},'local-projects':{p:{}},'thread-project-assignments':{thread:{projectId:'p'}}}));
  const store=new Store(file);
  assert.equal(Boolean(store.getStored('local-projects')),!broken);checks++;
  if (broken) return;
  store.beginRendererAccountSwitch(null);
  store.selectRendererOwner(null);
  assert.equal(store.getStored('thread-project-assignments').thread.projectId,'p');checks++;
  await store.flushOrThrow();
  assert.equal(new Store(file).getStored('thread-project-assignments').thread.projectId,'p');checks++;
  store.selectRendererOwner({id:'A'});
  assert.equal(store.getStored('local-projects'),undefined);checks++;
  store.set('local-projects',{a:{}});
  store.selectRendererOwner({id:'B'});
  assert.equal(store.getStored('local-projects'),undefined);checks++;
  store.selectRendererOwner({id:'A'});
  assert(store.getStored('local-projects').a);checks++;
  await store.flushOrThrow();
  const restored = new Store(file);
  restored.selectRendererOwner({id:'A'});
  assert(restored.getStored('local-projects').a);checks++;
  await restored.flushOrThrow();
  const events=[];
  const nativeWrite=fs.writeFileSync;
  // Capture the options through the actual synchronous commit path.
  fs.writeFileSync=function(...args){events.push(args[2]);return nativeWrite.apply(this,args);};
  try {await store.updateAndPersist('test',()=>1);}finally{fs.writeFileSync=nativeWrite;}
  assert(events.length>=2&&events.every(e=>e?.flush===true));checks++;
}
async function membershipCases(source, broken) {
  const gate={enabled:false};
  const context={T:{setThreadAssignmentsEnabled:e=>gate.enabled=e},tr:()=>({localProjectTaskMembership:false}),process:{platform:'win32'}};
  const anchor=source.match(/T\.setThreadAssignmentsEnabled\(tr\(\)\.localProjectTaskMembership[^)]*\)/)[0];
  vm.runInNewContext(anchor,context);assert.equal(gate.enabled,!broken);checks++;
  const start=source.indexOf('async write(e,t,r,n,i,s,a){'),end=source.indexOf('async syncAssignment(',start);
  const method=vm.runInNewContext('({'+source.slice(start,end)+'}).write',{ed5:async(_,id,fn)=>fn(),es:{Q2Y:{THREAD_PROJECT_ASSIGNMENTS:'assignments'},RWz:()=>false}});
  const sent=[];let writes=0;
  const receiver={pendingWrites:new Map(),globalState:{get:()=>({})},localProjectId:e=>e?.projectId??null,isEnabled:()=>gate.enabled,activeServerProjectId:()=> 'backend',connection:{sendAppServerRequest:async(...a)=>sent.push(a)}};
  await method.call(receiver,'thread',{projectKind:'local',projectId:'project'},async()=>writes++,async()=>true,{throwIfAborted(){}},undefined,'local');
  assert.equal(sent.length,broken?0:1);assert.equal(writes,1);checks++;
  if (broken)return;
  assert.equal(sent[0][0],'thread/metadata/update');assert.equal(sent[0][1].projectId,'backend');checks++;
  sent.length=0;
  await method.call(receiver,'thread',{projectKind:'local',projectId:'project'},async()=>{},async()=>false,{throwIfAborted(){}},undefined,'local');
  assert.equal(sent.length,0);checks++;
  context.process.platform='linux';vm.runInNewContext(anchor,context);assert.equal(gate.enabled,false);checks++;
}
async function main(){
  await stateCases(sources[0],true);await stateCases(patched[0],false);
  await membershipCases(sources[1],true);await membershipCases(patched[1],false);
  for(let i=0;i<profiles.length;i++){
    assert.equal(transform(patched[i],profiles[i]).status,'already-patched');
    assert.throws(()=>transform(sources[i]+'drift',profiles[i]),/Unsupported/);checks+=2;
  }
  const dp=desktop.resolveManifest(rel=>fs.existsSync(path.join(root,rel))).files.find(p=>p.file===relativePath(profiles[1]));
  const d=desktop.transform(sources[1],dp,['fixture']).source;
  const pd=transform(d,profiles[1]).source;
  assert.equal(desktop.transform(patched[1],dp,['fixture']).source,pd);checks++;
  assert.equal(desktop.transform(pd,dp,['fixture'],'model-experience').source,pd);checks++;
  assert.equal(transform(pd,profiles[1]).status,'already-patched');checks++;
  const fixture=path.join(temp,'fixture');
  for(let i=0;i<profiles.length;i++){const p=path.join(fixture,relativePath(profiles[i]));fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,sources[i]);}
  patchFiles(fixture,path.join(temp,'backups'),true);assert(!fs.existsSync(path.join(temp,'backups')));checks++;
  patchFiles(fixture,path.join(temp,'backups'));
  for(let i=0;i<profiles.length;i++){assert.equal(fs.readFileSync(path.join(temp,'backups',profiles[i].file),'utf8'),sources[i]);checks++;}
  assert(patchFiles(fixture,path.join(temp,'backups')).every(p=>p.status==='already-patched'));checks++;
  console.log(JSON.stringify({checks,originalDefectsReproduced:true,accountIsolation:true,composition:true}));
}
main().finally(()=>fs.rmSync(temp,{recursive:true,force:true})).catch(e=>{console.error(e.stack);process.exitCode=1;});
