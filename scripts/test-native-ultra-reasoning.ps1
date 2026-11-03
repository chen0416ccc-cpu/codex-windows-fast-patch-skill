[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [string]$CurrentAssetsDir
)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$embedded = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
  $node.Value.Contains("const marker = 'CODEX_ULTRA_LOCAL_FALLBACK_V1';")
}, $true)
if (-not $embedded) { throw 'Ultra patcher not found' }
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('native-ultra-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$patcher = Join-Path $root 'patch-ultra.cjs'
[IO.File]::WriteAllText($patcher, $embedded.Value, [Text.UTF8Encoding]::new($false))
$test = @'
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const [patcher, root, actual] = process.argv.slice(2);
let checks = 0;
const query = 'const Lg={};const witness={hasModelSupportingUltraReasoningEffort:false};const query=({additionalAvailableModels:e,authMethod:t,enabledReasoningEfforts:n,hasConfiguredModelCatalog:r,hostId:i,includeUltraReasoningEffort:a,isCustomModelProvider:o,limit:s,modelCatalogPath:c,modelProvider:l,teamCatalog:u},{get:d,queryClient:f,scope:p})=>{let x=0,S=a&&d(Lg,`1186680773`);return{queryKey:[],select:()=>({includeUltraReasoningEffort:S,isCustomModelProvider:o,enabledReasoningEfforts:n})}};';
const host = 'const o={hasConfiguredModelCatalog:gs(p),hostId:e.hostId,includeUltraReasoningEffort:Ff(t,`1186680773`),isAuthLoading:false,isTabAvailable:()=>true,isCustomModelProvider:Oa(p),workspaceDependenciesEnabled:false};';
function run(q,h,name,status=0) {
 const dir=path.join(root,name);fs.mkdirSync(dir);
 const qf=path.join(dir,'app-initial-fixture.js'), hf=path.join(dir,'initialize-app-host-services-fixture.js');
 fs.writeFileSync(qf,q);fs.writeFileSync(hf,h);
 const r=spawnSync(process.execPath,[patcher,qf],{encoding:'utf8'});
 assert.equal(r.status,status,r.stderr);checks++;
 if(status!==0){assert.equal(fs.readFileSync(qf,'utf8'),q);assert.equal(fs.readFileSync(hf,'utf8'),h);checks+=2;}
 return {q:fs.readFileSync(qf,'utf8'),h:fs.readFileSync(hf,'utf8'),qf,hf};
}
const good=run(query,host,'good');
assert.equal(good.q.replace('&&(o||d(Lg,`1186680773`))/*CODEX_NATIVE_ULTRA_QUERY_V1*/','&&d(Lg,`1186680773`)'),query);
assert.equal(good.h.replace('Oa(p)||Ff(t,`1186680773`)/*CODEX_NATIVE_ULTRA_HOST_V1*/','Ff(t,`1186680773`)'),host);checks+=2;
const repeat=spawnSync(process.execPath,[patcher,good.qf],{encoding:'utf8'});
assert.equal(repeat.status,0);assert.equal(repeat.stdout,'already-patched');assert.equal(fs.readFileSync(good.qf,'utf8'),good.q);checks+=3;
for(const custom of [false,true])for(const enabled of [false,true])for(const gate of [false,true]){
 const ctx={options:{includeUltraReasoningEffort:enabled,isCustomModelProvider:custom,enabledReasoningEfforts:['high','ultra']},scope:{get:()=>gate}};
 const got=vm.runInNewContext(good.q+'query(options,scope).select()',ctx);
 assert.equal(got.includeUltraReasoningEffort,enabled&&(custom||gate));
 assert.equal(JSON.stringify(got.enabledReasoningEfforts),'["high","ultra"]');checks+=2;
 const value=vm.runInNewContext(good.h+'o.includeUltraReasoningEffort',{gs:()=>true,p:{},e:{hostId:'local'},Ff:()=>gate,t:{},Oa:()=>custom});
 assert.equal(value,custom||gate);checks++;
}
run(query+query,host,'duplicate-query',2);
run(query,host+host,'duplicate-host',2);
run(query.replace('a&&d(Lg,`1186680773`)','a&&d(Lg,`1186680773`)&&extra'),host,'extra-condition',2);
run(query,host.replace('Oa(p)','Oa(p,extra)'),'unknown-provider-call',2);
run(good.q,host,'partial-query',2);
run(query,good.h,'partial-host',2);
run(query+'/*CODEX_NATIVE_ULTRA_QUERY_V1*/',host,'stray-query-marker',2);
run(query,host+'/*CODEX_NATIVE_ULTRA_HOST_V1*/','stray-host-marker',2);
run(query.replace(/\bo\b/g,'customProvider').replace(/\ba\b/g,'includeUltra'),host,'renamed-locals');
if(actual){
 const names=fs.readdirSync(actual), qn=names.find(n=>/^app-initial-.*\.js$/.test(n)), hn=names.find(n=>/^initialize-app-host-services-.*\.js$/.test(n));
 assert.ok(qn&&hn);checks++;
 const current=run(fs.readFileSync(path.join(actual,qn),'utf8'),fs.readFileSync(path.join(actual,hn),'utf8'),'actual-assets');
 assert.equal(current.q.split('CODEX_NATIVE_ULTRA_QUERY_V1').length,2);assert.equal(current.h.split('CODEX_NATIVE_ULTRA_HOST_V1').length,2);checks+=2;
 const again=spawnSync(process.execPath,[patcher,current.qf],{encoding:'utf8'});assert.equal(again.status,0);assert.equal(again.stdout,'already-patched');checks+=2;
}
console.log('NATIVE_ULTRA_PASSED checks='+checks);
'@
$testPath = Join-Path $root 'test.cjs'
[IO.File]::WriteAllText($testPath, $test, [Text.UTF8Encoding]::new($false))
& node.exe --check $patcher
if ($LASTEXITCODE) { throw 'Ultra patcher syntax check failed' }
& node.exe $testPath $patcher $root $CurrentAssetsDir
if ($LASTEXITCODE) { throw 'Native Ultra regression failed' }
