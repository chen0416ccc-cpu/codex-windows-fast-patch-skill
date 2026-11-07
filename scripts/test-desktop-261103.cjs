'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const crypto = require('node:crypto');
const {transform, resolveManifest} = require('./patch-desktop-261029.cjs');
const root = process.argv[2];
const manifest = resolveManifest(rel => fs.existsSync(path.join(root, rel)));
assert(['26.1103.3517.0', '26.1103.4239.0'].includes(manifest.version));
let checks = 0;
const models = ['fixture-model'];
async function main() {
  assert.equal(manifest.files.length, 29);
  assert.throws(()=>resolveManifest(()=>false),/Expected one complete/);
  assert.throws(()=>resolveManifest(rel=>rel!==manifest.files[0].file&&fs.existsSync(path.join(root,rel))),/Expected one complete/);
  checks+=3;
  for (const profile of manifest.files) {
    const source = fs.readFileSync(path.join(root, profile.file), 'utf8');
    const patched = transform(source, profile, models);
    const syntax=spawnSync(process.execPath,['--check','--input-type=module'],{input:patched.source,encoding:'utf8',windowsHide:true});
    assert.equal(syntax.status,0,syntax.stderr?.slice(-1000));
    assert.equal(transform(patched.source, profile, models).status, 'already-patched');
    assert.throws(() => transform(source + 'drift', profile, models), /Unsupported/);
    assert.equal(transform(patched.source, profile, models, 'model-experience').source, patched.source);
    checks += 4;
    if (profile.edits.length > 1) {
      // Model-only is an accepted complete state; use an unrelated or startup
      // edit when checking rejection of an incomplete desktop patch.
      const e = profile.edits.find(edit=>edit.kind.startsWith('startup-')) ??
        profile.edits.find(edit=>!['custom-models','fast-request','fast-ui','ultra'].includes(edit.kind)) ?? profile.edits[0];
      const partial = source.replace(e.before, e.after.replace('__MODELS_JSON__', JSON.stringify(models)));
      assert.throws(() => transform(partial, profile, models), /Unsupported/, profile.file); checks++;
    }
    for (const edit of profile.edits) {
      if (edit.kind === 'ultra') {
        const [,, enabled, get, ns] = edit.before.match(/(\w+)=(\w+)&&(\w+)\((\w+)\.JW,/);
        const custom = edit.after.match(/&&\((\w+)\|\|/)[1];
        const context = {[enabled]:true, [custom]:true, [get]:()=>false, [ns]:{JW:{}}};
        assert.equal(vm.runInNewContext(edit.after, context), true);
        context[custom] = false;
        assert.equal(vm.runInNewContext(edit.after, context), false);
        context[enabled] = false; context[custom] = true;
        assert.equal(vm.runInNewContext(edit.after, context), false); checks += 3;
      }
      if (edit.kind === 'fast-request') {
        const index = source.indexOf(edit.before);
        const start = source.lastIndexOf('async function(', index);
        const end = source.indexOf(')}(', index) + 2;
        assert(start >= 0 && end > index && end - start < 800);
        const before = source.slice(start, end);
        const after = before.replace(edit.before, edit.after);
        const authNs = before.match(/await \(0,(\w+)\.s\)/)[1];
        const requirements = before.match(/await \(0,(\w+)\.Wr\)/)[1];
        const converter = before.match(/\(0,(\w+)\.W6\)/)[1];
        for (const method of ['apikey','chatgpt','amazonBedrock','personalAccessToken']) {
          let calls = 0, caches = 0;
          const context = {[authNs]:{s:async()=>method},[requirements]:{Wr:async()=>{calls++;return ['priority'];},b9:'key'},[converter]:{W6:value=>value}};
          const fn = vm.runInNewContext('(' + after + ')',context);
          const result = await fn({query:{setData(){caches++;}}},'local');
          assert.equal(calls,1); assert.equal(caches,1); assert.deepEqual(Array.from(result),['priority']); checks+=3;
          if (method==='apikey') {
            calls=0;
            assert.equal(await vm.runInNewContext('('+before+')',context)({query:{setData(){}}},'local'),null);
            assert.equal(calls,0);checks+=2;
          }
        }
      }
      if (edit.kind === 'custom-models') {
        const context={s:{model:'fixture-model',hidden:true},e:null,i:false,o:false,a:true,n:'apikey',r:new Set(),t:false,l:undefined};
        assert.equal(vm.runInNewContext(edit.after.replace('__MODELS_JSON__',JSON.stringify(models)),context),true);
        context.s.model='unknown';
        assert.equal(vm.runInNewContext(edit.after.replace('__MODELS_JSON__',JSON.stringify(models)),context),false);checks+=2;
      }
      if (edit.kind === 'startup-renderer-diagnostics') {
        for (const [reason,quitting,expected] of [['crashed',false,1],['oom',false,1],['killed',false,1],['clean-exit',false,0],['crashed',true,0]]) {
          const records=[];
          const context={e:{},n:1,i:2,t:'primary',r:{on:(_,cb)=>{context.callback=cb;}},eEc:()=>({warning:(name,entry)=>records.push({name,...entry})})};
          vm.runInNewContext('(function(){'+edit.after+';})}).call({isAppQuitting:'+quitting+',appBadgeCounts:{delete(){}}})',context);
          context.callback(null,{reason,exitCode:3});
          assert.equal(records.length,expected);
          if(expected){assert.equal(records[0].safe.reason,reason);assert.equal(Object.keys(records[0].sensitive).length,0);}
          checks++;
        }
      }
    }
  }
  const shared=manifest.files.find(p=>p.edits.some(e=>e.kind==='startup-bootstrap-budget'));
  const source=fs.readFileSync(path.join(root,shared.file),'utf8');
  const deadline=shared.edits.find(e=>e.kind==='startup-bootstrap-budget');
  const at=source.indexOf(deadline.before);
  const begin=source.lastIndexOf('async function(e,t){',at);
  const end=source.indexOf('}(e,k);try{',at)+1;
  assert(begin>=0&&end>at);
  const fn=source.slice(begin,end).replace(deadline.before,deadline.after);
  for(const [platform,expected] of [['Windows',5000],['macOS',62500]]){
    const timers=[];
    const context={AbortController,AbortSignal,setTimeout:(cb,ms)=>{timers.push({cb,ms});return timers.length;},clearTimeout(){},Error,
      c:{CodexPostLoginStatsigBootstrapFailureType:{CODEX_POST_LOGIN_STATSIG_BOOTSTRAP_FAILURE_TYPE_REQUEST_FAILED:1}},
      t3:class extends Error{constructor(type,cause){super(cause.message);this.cause=cause;this.failureType=type;}},
      E:{_qC:(promise,signal)=>Promise.race([promise,new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}))])},
      t1:{CodexRequest:{postResponse:()=>new Promise(()=>{})}},tQ:{C:'Codex'}};
    const pending=vm.runInNewContext('('+fn+')',context)({systemName:platform},{current:0});
    assert.equal(timers[0].ms,expected);
    timers[0].cb();
    await assert.rejects(pending,/deadline/);checks+=2;
  }
  for(const profile of manifest.native){
    const source=fs.readFileSync(path.join(root,profile.file),'utf8');
    assert.equal(crypto.createHash('sha256').update(source).digest('hex'),profile.sha256);
    for(const witness of profile.witnesses)assert(source.includes(witness));
    checks++;
  }
  console.log(JSON.stringify({checks,files:manifest.files.length,native:manifest.native.length,fastRequests:7,fastUi:7,ultra:11}));
}
main().catch(error=>{console.error(error.stack?.slice(-1500)??error.message);process.exitCode=1;});
