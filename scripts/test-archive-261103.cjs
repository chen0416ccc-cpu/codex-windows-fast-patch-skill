'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const {profiles, transform, patchFiles, relativePath} = require('./patch-project-archive-state.cjs');
const profile = profiles.find(p => p.file === 'async/678916.8bc60ed422.js');
const source = fs.readFileSync(path.join(process.argv[2], relativePath(profile)), 'utf8');
const patched = transform(source, profile).source;
let checks = 0;
function renderCases(text, broken) {
  const start = text.indexOf('ea[117]!==eS'), end = text.indexOf(',ea[125]', start);
  assert(start > 0 && end > start);
  const code = '{let z;' + text.slice(start, end) + ';globalThis.row=z;}';
  const called = [];
  const state = {ea: [], eS: Error('account'), eA: false, e_: () => called.push('account'),
    eb: () => called.push('durable'), eC: () => called.push('local'), tc: true, td: true, er: [],
    r: {jsx: (type, props) => ({type,props})}, el: {t:'row'}, es: {ic:'label'}, k: {A:'text'}, E: {$:'button'}, N: {p:{retry:{}}}};
  function render() {vm.runInNewContext(code,state);return state.row;}
  assert(render(), 'Empty failures retain retry'); checks++;
  render().props.children.props.control.props.onClick();
  assert.deepEqual(called, ['local','durable','account']); checks++;
  state.er = Array(20).fill({kind:'local'});
  assert.equal(!!render(), broken, 'Rows invalidate cached failure'); checks++;
  state.er = [];
  assert(render(), 'Removing rows restores retry'); checks++;
  state.eS=null; state.tc=false; state.td=false;
  assert.equal(render(),null,'Empty success'); checks++;
  state.tc=true; state.eA=true;
  assert.equal(render(),null,'Loading state'); checks++;
}
renderCases(source,true); renderCases(patched,false);
const start=patched.indexOf('(0,r.jsx)(eU,{'), end=patched.indexOf('},`${y}:',start);
const parent=patched.slice(start+'(0,r.jsx)(eU,'.length,end+1);
const ctx={ew:[1],j:null,ek:[],y:'local',N:true,eC:false,eb:true,ex:[1],Q:[{}, {data:[1],isError:true}],U:'disconnected',
  d(){},c(){},eP:false,eM:false,V:false,J:true,es:false,eo:{fI:'local'},ej:false,H:false,el:false,O:[],X:false,ee:[1],eh:true,eu:Error('account'),h(){},v(){}};
let props=vm.runInNewContext('('+parent+')',ctx);
assert.equal(props.isLocalArchiveError,false); assert.equal(props.isDurableArchiveError,false);assert.equal(props.chatGptArchiveError,null);checks+=3;
ctx.ex=[];ctx.Q[1].data=[];ctx.ee=[];
props=vm.runInNewContext('('+parent+')',ctx);
assert.equal(props.isLocalArchiveError,true);assert.equal(props.isDurableArchiveError,true);assert(props.chatGptArchiveError);checks+=3;
assert.equal(transform(patched,profile).status,'already-patched');checks++;
assert.throws(()=>transform(source+'changed',profile),/Unsupported/);checks++;
assert.throws(()=>transform(source.replace(...profile.edits[0]),profile),/Unsupported/);checks++;
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'codex-archive-261103-'));
try {
  const file=path.join(temp,relativePath(profile)), backup=path.join(temp,'backups');
  fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,source);
  patchFiles(temp,backup,true);assert.equal(fs.readFileSync(file,'utf8'),source);assert(!fs.existsSync(backup));checks+=2;
  patchFiles(temp,backup);assert.equal(fs.readFileSync(file,'utf8'),patched);assert.equal(fs.readFileSync(path.join(backup,profile.file),'utf8'),source);checks+=2;
  assert.equal(patchFiles(temp,backup)[0].status,'already-patched');checks++;
} finally {fs.rmSync(temp,{recursive:true,force:true});}
console.log(JSON.stringify({checks,originalReproduced:true,patchedPassed:true}));
