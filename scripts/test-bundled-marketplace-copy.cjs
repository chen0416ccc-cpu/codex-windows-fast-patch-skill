const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const script = fs.readFileSync(path.join(__dirname, 'patch_codex_fast_mode_windows_msix.ps1'), 'utf8').replace(/\r\n/g, '\n');
const anchor = "Set-Content -LiteralPath $bundledMarketplaceCopyPatcherPath -Encoding UTF8 -Value @'\n";
const start = script.indexOf(anchor);
assert.notEqual(start, -1);
const sourceStart = start + anchor.length;
const sourceEnd = script.indexOf("\n'@", sourceStart);
assert.notEqual(sourceEnd, -1);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-marketplace-test-'));
const patcher = path.join(root, 'patcher.cjs');
fs.writeFileSync(patcher, script.slice(sourceStart, sourceEnd));
const nativeCopy = 'require(`./windows-file-copy-fixture.js`);';
const retirement = 'async function retire(client){let{plugins:saved}=await client.getUserSavedConfiguration();typeof saved==`object`&&saved&&!Array.isArray(saved)&&Object.hasOwn(saved,`sites@openai-bundled`)&&await client.uninstallPlugin({pluginId:`sites@openai-bundled`})}';
const research = '{...catalog.plugins.deepResearch,isAvailable:({features:flags})=>flags.deepResearch}';
const sites = '{...catalog.plugins.sites,isAvailable:({features:flags})=>flags.sites}';
const codeReview = '{...catalog.plugins.pullRequests,isAvailable:({features:flags})=>flags.codeReviewPlugin}';
const unifiedCua = '{...catalog.plugins.unifiedComputerUse,isAvailable:({features:flags})=>flags.browserUseTinysky&&(flags.inAppBrowserUse||flags.externalBrowserUse||flags.computerUse)}';
const imageGuidedAssets = '{...catalog.plugins.imageGuidedAssets,autoInstallOptOutKey:catalog.plugins.imageGuidedAssets.name,isAvailable:({features:flags})=>flags.imageGuidedAssets}';
let cases = 0;
function run(name, source, expectedStatus, check) {
  const file = path.join(root, name + '.js');
  fs.writeFileSync(file, nativeCopy + source);
  const before = fs.readFileSync(file, 'utf8');
  const result = spawnSync(process.execPath, [patcher, file], { encoding: 'utf8' });
  assert.equal(result.status, expectedStatus, result.stderr);
  const after = fs.readFileSync(file, 'utf8');
  if (expectedStatus) {
    assert.equal(after, before, 'failed recognition must not write the file');
  } else {
    assert.equal(spawnSync(process.execPath, ['--check', file]).status, 0);
    check(after);
    const repeat = spawnSync(process.execPath, [patcher, file], { encoding: 'utf8' });
    assert.equal(repeat.status, 0, repeat.stderr);
    assert.equal(repeat.stdout, 'already-patched');
    assert.equal(fs.readFileSync(file, 'utf8'), after);
  }
  cases++;
}
try {
  run('legacy', `const plugins=[${sites},${research}];`, 0, after => {
    assert.ok(after.includes('codex_windows_sites_bundled_plugin_available'));
    assert.ok(after.includes('codex_windows_deep_research_bundled_plugin_available'));
  });
  run('retired-sites', retirement + `const plugins=[${research}];`, 0, after => {
    assert.ok(after.includes(retirement), 'preserve the retirement function');
    assert.ok(!after.includes('codex_windows_sites_bundled_plugin_available'));
    assert.ok(after.includes('codex_windows_deep_research_bundled_plugin_available'));
  });
  run('missing-sites', `const plugins=[${research}];`, 2);
  run('duplicate-retirement', retirement + retirement.replace('retire(', 'retireAgain(') + `const plugins=[${research}];`, 2);
  run('retirement-with-sites-descriptor', retirement + `const plugins=[{...catalog.plugins.sites,isAvailable:()=>false},${research}];`, 2);
  run('missing-research', retirement + 'const plugins=[];', 2);
  const optionalSource = `const flags={browserUseTinysky:false,codeReviewPlugin:false,imageGuidedAssets:false};const plugins=[${codeReview},${unifiedCua},${imageGuidedAssets},${research}];`;
  run('optional-entries', retirement + optionalSource, 0, after => {
    assert.ok(after.includes('const flags={browserUseTinysky:false,codeReviewPlugin:false,imageGuidedAssets:false};'), 'feature flags must remain unchanged');
    assert.ok(after.includes('pullRequests,isAvailable:()=>!0/*codex_windows_code_review_bundled_plugin_available*/,installWhenMissing:!1'));
    assert.ok(after.includes('unifiedComputerUse,isAvailable:()=>!0/*codex_windows_unified_cua_bundled_plugin_available*/,installWhenMissing:!1'));
    assert.ok(after.includes('imageGuidedAssets,autoInstallOptOutKey:catalog.plugins.imageGuidedAssets.name,isAvailable:()=>!0/*codex_windows_image_guided_assets_bundled_plugin_available*/,installWhenMissing:!1'));
    assert.ok(!after.includes('plugin add'), 'availability must not install plugins');
    const state = vm.runInNewContext(after + ';plugins.map(plugin=>({available:plugin.isAvailable({features:flags}),automatic:plugin.installWhenMissing}));', {
      require: () => ({}),
      catalog: { plugins: {
        pullRequests: {installWhenMissing:true},
        unifiedComputerUse: {installWhenMissing:true},
        imageGuidedAssets: {installWhenMissing:true,name:'image-guided-assets'},
        deepResearch: {installWhenMissing:true}
      } }
    });
    assert.deepEqual(JSON.parse(JSON.stringify(state)), [
      {available:true,automatic:false},{available:true,automatic:false},
      {available:true,automatic:false},{available:true,automatic:false}
    ]);
  });
  const legacyResearch = research.replace('({features:flags})=>flags.deepResearch',
    '()=>!0/*codex_windows_deep_research_bundled_plugin_available*/');
  run('legacy-research-upgrade', retirement + `const plugins=[${legacyResearch}];`, 0, after => {
    assert.ok(after.includes('codex_windows_deep_research_bundled_plugin_available*/,installWhenMissing:!1'));
  });
  run('duplicate-research', retirement + `const plugins=[${research},${research}];`, 2);
  run('research-marker-only', retirement + '/*codex_windows_deep_research_bundled_plugin_available*/const plugins=[];', 2);
  run('research-extra-predicate', retirement + `const plugins=[${research.replace('flags.deepResearch}', 'flags.deepResearch&&flags.futurePolicy}')}];`, 2);
  run('research-extra-property', retirement + `const plugins=[${research.replace('flags.deepResearch}', 'flags.deepResearch,installWhenMissing:true}')}];`, 2);
  run('research-unsafe-patched', retirement + `const plugins=[${legacyResearch.replace('*/}', '*/,installWhenMissing:!0}')}];`, 2);
  run('unknown-code-review', retirement + `const plugins=[${codeReview.replace('codeReviewPlugin', 'futureReview')},${research}];`, 2);
  run('duplicate-code-review', retirement + `const plugins=[${codeReview},${codeReview},${research}];`, 2);
  run('unknown-unified-cua', retirement + `const plugins=[${unifiedCua.replace('browserUseTinysky', 'futureEngine')},${research}];`, 2);
  run('duplicate-unified-cua', retirement + `const plugins=[${unifiedCua},${unifiedCua},${research}];`, 2);
  run('code-review-marker-only', retirement + `/*codex_windows_code_review_bundled_plugin_available*/const plugins=[${research}];`, 2);
  run('unified-cua-marker-only', retirement + `/*codex_windows_unified_cua_bundled_plugin_available*/const plugins=[${research}];`, 2);
  run('unknown-image-guided-assets', retirement + `const plugins=[${imageGuidedAssets.replace('flags.imageGuidedAssets}', 'flags.futureImageGuidedAssets}')},${research}];`, 2);
  run('duplicate-image-guided-assets', retirement + `const plugins=[${imageGuidedAssets},${imageGuidedAssets},${research}];`, 2);
  run('image-guided-assets-marker-only', retirement + `/*codex_windows_image_guided_assets_bundled_plugin_available*/const plugins=[${research}];`, 2);
  run('image-guided-assets-extra-predicate', retirement + `const plugins=[${imageGuidedAssets.replace('flags.imageGuidedAssets}', 'flags.imageGuidedAssets&&flags.futurePolicy}')},${research}];`, 2);
  run('image-guided-assets-extra-property', retirement + `const plugins=[${imageGuidedAssets.replace('autoInstallOptOutKey:', 'installWhenMissing:true,autoInstallOptOutKey:')},${research}];`, 2);
  run('mixed-code-review', retirement + `const plugins=[${codeReview},{...catalog.plugins.pullRequests,isAvailable:()=>!0/*codex_windows_code_review_bundled_plugin_available*/},${research}];`, 2);
  run('code-review-extra-predicate', retirement + `const plugins=[${codeReview.replace('flags.codeReviewPlugin}', 'flags.codeReviewPlugin&&flags.futurePolicy}')},${research}];`, 2);
  run('unified-cua-extra-predicate', retirement + `const plugins=[${unifiedCua.replace('flags.computerUse)}', 'flags.computerUse)&&flags.futurePolicy}')},${research}];`, 2);
  run('code-review-extra-property', retirement + `const plugins=[${codeReview.replace('Plugin}', 'Plugin,migrate:futureMigration}')},${research}];`, 2);
  run('unified-cua-extra-property', retirement + `const plugins=[${unifiedCua.replace('Use)}', 'Use),migrate:futureMigration}')},${research}];`, 2);
  process.stdout.write(`Bundled marketplace regression passed: ${cases} cases\n`);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
