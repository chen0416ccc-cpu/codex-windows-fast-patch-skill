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
      $node.Value.Contains('function patchFeatureHook(file) {') -and
      $node.Value.Contains('CODEX_BROWSER_EXTERNAL_CONFIG_V2')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Browser Use patcher was not found in the patch script'
}

$functionStart = $patcherAst.Value.IndexOf('function patchFeatureHook(file) {', [StringComparison]::Ordinal)
$functionEnd = $patcherAst.Value.IndexOf('function patchSidebarAvailability(file) {', $functionStart, [StringComparison]::Ordinal)
if ($functionStart -lt 0 -or $functionEnd -le $functionStart) {
  throw 'Browser feature-hook patch function boundaries were not found'
}
$hookFunction = $patcherAst.Value.Substring($functionStart, $functionEnd - $functionStart)
$harness = @"
const fs = require('node:fs');
let changed = false;
function read(file) { return fs.readFileSync(file, 'utf8'); }
function writeIfChanged(file, before, after) {
  if (after !== before) {
    fs.writeFileSync(file, after);
    changed = true;
  }
}
$hookFunction
patchFeatureHook(process.argv[2]);
process.stdout.write(changed ? 'patched' : 'already-patched');
"@

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Browser feature-hook regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('browser-feature-hooks-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchBrowserFeatureHook.cjs'
[System.IO.File]::WriteAllText($patcherPath, $harness, [System.Text.UTF8Encoding]::new($false))

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

$currentSource = 'const externalFeature={featureName:`browser_use_external`},inAppFeature={featureName:`browser_use`},browserConfig=`browser.in-app`,computerFeature={featureName:`computer_use`};function external(e){let s=Px(`410065390`),c;let l=GNr(c),u=sX(Yu.runCodexInWsl),d=$g(e),f=u===!0||d.kind===`wsl`,p;}function inApp(e){let o=hs(gj,a).isCapable,s=Px(`410262010`),c;let l=GNr(c),u=sX(Yu.runCodexInWsl),d=$g(r),f=l.enabled&&!l.isLoading,p=l.isLoading,m=u===!0||d.kind===`wsl`,h;}'
$negativeSource = 'const externalFeature={featureName:`browser_use_external`},inAppFeature={featureName:`browser_use`},computerFeature={featureName:`computer_use`};const unrelated=()=>!0;'

$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
$previousNativePreference = $null
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  $result = Invoke-PatcherFixture -Name 'codex-26-814-feature-hook' -Source $currentSource -ExpectedExitCode 0
  if ($result.Output -cne 'patched') {
    throw "current Browser feature-hook fixture did not report patched: $($result.Output)"
  }
  $patched = [System.IO.File]::ReadAllText($result.AssetPath)
  foreach ($marker in @(
      'CODEX_BROWSER_IN_APP_GATES_V2',
      'CODEX_BROWSER_IN_APP_CONFIG_V2',
      'CODEX_BROWSER_EXTERNAL_GATE_V2',
      'CODEX_BROWSER_EXTERNAL_CONFIG_V2')) {
    if (-not $patched.Contains($marker)) {
      throw "current Browser feature-hook fixture is missing marker: $marker"
    }
  }
  $syntaxOutput = @(& $node.Source --check $result.AssetPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "current Browser feature-hook fixture produced invalid JavaScript: $($syntaxOutput -join ' | ')"
  }

  $secondOutput = @(& $node.Source $patcherPath $result.AssetPath 2>&1)
  if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
    throw "current Browser feature-hook fixture was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
  }

  $negative = Invoke-PatcherFixture -Name 'unrelated-true-callback' -Source $negativeSource -ExpectedExitCode 2
  if ($negative.Output -cne 'browser-use-feature-hook-patch-target-not-found') {
    throw "unrelated Browser feature-hook fixture failed for the wrong reason: $($negative.Output)"
  }
  if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
    throw 'unrelated Browser feature-hook fixture was modified'
  }
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "Browser feature-hook regression passed: $fixtureRoot"
