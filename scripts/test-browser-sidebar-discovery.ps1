[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
$patchScript = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($patchScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Patch script did not parse.' }
$source = [IO.File]::ReadAllText($patchScript)
$discoveryBlocks = [regex]::Matches($source, '(?s)  \$browserSidebarAvailabilityTarget = \$null\r?\n.*?(?=  \$desktopFeatureSenderTarget = \$null)')
# The automatic-repair fork also carries a separate scoped finder. Exercise both there.
$expectedFinders = if ($source.Contains('function Find-BrowserComputerUsePatchTargets {')) { 2 } else { 1 }
if ($discoveryBlocks.Count -ne $expectedFinders) { throw 'Sidebar discovery block count differs from the available entrypoints.' }
$patcher = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value.Contains('function patchSidebarAvailability(file) {')
}, $true).Value
$start = $patcher.IndexOf('function patchSidebarAvailability(file) {')
$end = $patcher.IndexOf('function patchDesktopFeatureSender(file) {', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Sidebar patch function not found.' }
$functionSource = $patcher.Substring($start, $end - $start)
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('sidebar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$harness = Join-Path $root 'patch-sidebar.cjs'
[IO.File]::WriteAllText($harness, @"
const fs = require('node:fs');
function read(file) { return fs.readFileSync(file, 'utf8'); }
function writeIfChanged(file, before, after) { if (before !== after) fs.writeFileSync(file, after); }
$functionSource
patchSidebarAvailability(process.argv[2]);
"@)
$node = (Get-Command node.exe -ErrorAction Stop).Source
# Same bounded capability shape as Desktop 26.924, with unrelated policy retained.
$fixture = @'
const category=`experimental-features`;
const policies={"browser.in-app":{accessPolicy:`workspace-in-app-browser`,configFeatures:[{key:`in_app_browser`,host:`default`}],supportedClients:[`electron`]},"other":{accessPolicy:`unrelated-policy`}};
function availability(){const a={name:`browser.in-app`},opts={featureName:`browser_use`};let o=hk(HX,a).isCapable,s=wZ(`410262010`),c;return [o,s,opts];}
'@
$checks = 0
foreach ($assetName in @('app-initial-fixture.js', 'app-shared-fixture.js')) {
  $assetsDir = Join-Path $root $assetName.Replace('.js', '')
  New-Item -ItemType Directory -Path $assetsDir | Out-Null
  $asset = Join-Path $assetsDir $assetName
  [IO.File]::WriteAllText($asset, $fixture)
  foreach ($block in $discoveryBlocks) {
    . ([scriptblock]::Create($block.Value))
    if ($browserSidebarAvailabilityTarget -ne $asset) { throw "Original target not discovered: $assetName" }
    $checks++
  }
  & $node $harness $asset
  if ($LASTEXITCODE -ne 0) { throw "Sidebar patch failed: $assetName" }
  $patched = [IO.File]::ReadAllText($asset)
  if (-not $patched.Contains('CODEX_BROWSER_IN_APP_GATES_V2') -or
      -not $patched.Contains('supportedClients:[`electron`]') -or
      -not $patched.Contains('accessPolicy:`unrelated-policy`')) { throw 'Sidebar patch changed unrelated fields or missed its target.' }
  & $node --check $asset
  if ($LASTEXITCODE -ne 0) { throw 'Patched fixture is not valid JavaScript.' }
  foreach ($block in $discoveryBlocks) {
    . ([scriptblock]::Create($block.Value))
    if ($browserSidebarAvailabilityTarget -ne $asset) { throw "Patched target not discovered: $assetName" }
    $checks++
  }
  $hash = (Get-FileHash -LiteralPath $asset).Hash
  & $node $harness $asset
  if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $asset).Hash -ne $hash) { throw 'Repeated sidebar patch is not idempotent.' }
  $checks += 3
  [IO.File]::WriteAllText($asset, 'const x=`in_app_browser experimental-features browser.in-app 410262010`;')
  foreach ($block in $discoveryBlocks) {
    . ([scriptblock]::Create($block.Value))
    if ($browserSidebarAvailabilityTarget) { throw 'Marker-only lookalike was accepted.' }
    $checks++
  }
}
Write-Output "Browser sidebar discovery regression passed: checks=$checks root=$root"
