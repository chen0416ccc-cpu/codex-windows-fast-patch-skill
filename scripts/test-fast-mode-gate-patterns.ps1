[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $scriptPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "patch script did not parse: $($parseErrors[0].Message)"
}

$patcherAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains('const currentManagerCachedAsyncOriginalRe =') -and
      $node.Value.Contains('fast-mode-patch-target-not-found')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Fast Mode patcher was not found in the patch script'
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Fast Mode gate regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('fast-mode-gates-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchFastMode.cjs'
[System.IO.File]::WriteAllText(
  $patcherPath,
  $patcherAst.Value,
  [System.Text.UTF8Encoding]::new($false)
)

function Invoke-PatcherFixture {
  param(
    [string]$Name,
    [string]$Source,
    [int]$ExpectedExitCode
  )

  $assetPath = Join-Path $fixtureRoot ($Name + '.js')
  [System.IO.File]::WriteAllText($assetPath, $Source, [System.Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source $patcherPath $assetPath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Name patcher exit mismatch: expected=$ExpectedExitCode actual=$exitCode output=$($output -join ' | ')"
  }
  return [pscustomobject]@{
    AssetPath = $assetPath
    Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  }
}

$positiveFixtures = @(
  [pscustomobject]@{
    Name = 'cached-host-id-requirements'
    Source = 'async function qUr(e,t){let n=await WUr(e,t);if(n!==`chatgpt`)return!1;let r=await P2t(t,{priority:`critical`});return e.query.setData(ix,{authMethod:n,hostId:t},r),r.requirements?.featureRequirements?.fast_mode!==!1}'
  },
  [pscustomobject]@{
    Name = 'codex-26-814-manager-requirements'
    Source = 'async function qUr(e,t){let n=await WUr(e,t);if(n!==`chatgpt`)return!1;let r=await P2t(e,t,{priority:`critical`});return e.query.setData(ix,{authMethod:n,hostId:t},r),r.requirements?.featureRequirements?.fast_mode!==!1}'
  },
  [pscustomobject]@{
    Name = 'codex-26-924-personal-access-token'
    Source = 'async function qUr(e,t){let n=await WUr(e,t);if(n!==`chatgpt`&&n!==`personalAccessToken`)return!1;let r=await P2t(e,t,{priority:`critical`});return e.query.setData(ix,{authMethod:n,hostId:t},r),r.requirements?.featureRequirements?.fast_mode!==!1}'
  }
)

# Execute each patched source with controlled auth, requirements and cache APIs.
$behaviorPath = Join-Path $fixtureRoot 'fast-mode-behavior.cjs'
[IO.File]::WriteAllText($behaviorPath, @'
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
let checks = 0;
async function run(authMethod, fastMode, failureAt) {
  const events = [];
  const data = fastMode === undefined ? {} : {requirements: {featureRequirements: {fast_mode: fastMode}}};
  const failure = new Error('controlled requirements failure');
  const manager = {query: {setData(query, key, value) {
    assert.equal(query, 'requirements-query');
    assert.equal(key.authMethod, authMethod);
    assert.equal(key.hostId, 'test-host');
    assert.equal(value, data);
    events.push('cache');
  }}};
  const gate = vm.runInNewContext(source + ';qUr', {
    ix: 'requirements-query',
    WUr: async (actualManager, hostId) => {
      assert.equal(actualManager, manager);
      assert.equal(hostId, 'test-host');
      events.push('auth');
      if (failureAt === 'auth') throw failure;
      return authMethod;
    },
    P2t: async (...args) => {
      if (args.length === 3) assert.equal(args.shift(), manager);
      assert.equal(args.length, 2);
      assert.equal(args[0], 'test-host');
      assert.equal(args[1].priority, 'critical');
      events.push('requirements');
      if (failureAt === 'requirements') throw failure;
      return data;
    },
  }, {timeout: 1000});
  if (failureAt) {
    await assert.rejects(gate(manager, 'test-host'), error => error === failure);
    assert.deepEqual(events, failureAt === 'auth' ? ['auth'] : ['auth', 'requirements']);
  } else {
    assert.equal(await gate(manager, 'test-host'), fastMode !== false);
    assert.deepEqual(events, ['auth', 'requirements', 'cache']);
  }
  checks++;
}
(async () => {
  for (const authMethod of ['chatgpt', 'personalAccessToken', 'apikey', null]) {
    for (const fastMode of [true, false, undefined]) await run(authMethod, fastMode);
    await run(authMethod, true, 'auth');
    await run(authMethod, true, 'requirements');
  }
  console.log(`FAST_MODE_BEHAVIOR_PASSED cases=${checks}`);
})().catch(error => {console.error(error); process.exitCode = 1;});
'@, [Text.UTF8Encoding]::new($false))

$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
$previousNativePreference = $null
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  foreach ($fixture in $positiveFixtures) {
    $result = Invoke-PatcherFixture -Name $fixture.Name -Source $fixture.Source -ExpectedExitCode 0
    if ($result.Output -cne 'patched') {
      throw "$($fixture.Name) did not report patched: $($result.Output)"
    }

    $patched = [System.IO.File]::ReadAllText($result.AssetPath)
    if ($patched.Contains('if(n!==`chatgpt`')) {
      throw "$($fixture.Name) retained the ChatGPT-only Fast Mode gate"
    }
    $syntaxOutput = @(& $node.Source --check $result.AssetPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "$($fixture.Name) produced invalid JavaScript: $($syntaxOutput -join ' | ')"
    }
    & $node.Source $behaviorPath $result.AssetPath
    if ($LASTEXITCODE -ne 0) { throw "$($fixture.Name) changed the Fast Mode requirements/cache contract" }

    $secondOutput = @(& $node.Source $patcherPath $result.AssetPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
      throw "$($fixture.Name) was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
    }
  }

  $negativeSource = 'const unrelated={fast_mode:false};const always=()=>!0;'
  $negative = Invoke-PatcherFixture -Name 'unrelated-fast-mode' -Source $negativeSource -ExpectedExitCode 2
  if ($negative.Output -cne 'fast-mode-patch-target-not-found') {
    throw "unrelated Fast Mode fixture failed for the wrong reason: $($negative.Output)"
  }
  if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
    throw 'unrelated Fast Mode fixture was modified'
  }
  $mismatched = $positiveFixtures[-1].Source.Replace('&&n!==`personalAccessToken`', '&&other!==`personalAccessToken`')
  $negative = Invoke-PatcherFixture -Name 'mismatched-auth-method' -Source $mismatched -ExpectedExitCode 2
  if ([IO.File]::ReadAllText($negative.AssetPath) -cne $mismatched) {
    throw 'mismatched auth-method lookalike was modified'
  }
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "Fast Mode gate regression passed: $fixtureRoot"
