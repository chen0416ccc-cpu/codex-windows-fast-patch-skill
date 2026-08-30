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
      $node.Value.Contains('function patchSidebarAvailability(file) {') -and
      $node.Value.Contains('browser-use-feature-hook-target-not-found')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Browser Use patcher was not found in the patch script'
}

$functionStart = $patcherAst.Value.IndexOf('function patchSidebarAvailability(file) {', [StringComparison]::Ordinal)
$functionEnd = $patcherAst.Value.IndexOf('function patchDesktopFeatureSender(file) {', $functionStart, [StringComparison]::Ordinal)
if ($functionStart -lt 0 -or $functionEnd -le $functionStart) {
  throw 'Browser sidebar patch function boundaries were not found'
}
$sidebarFunction = $patcherAst.Value.Substring($functionStart, $functionEnd - $functionStart)
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
$sidebarFunction
patchSidebarAvailability(process.argv[2]);
process.stdout.write(changed ? 'patched' : 'already-patched');
"@

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Browser sidebar gate regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('browser-sidebar-gates-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchBrowserSidebar.cjs'
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

$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
$previousNativePreference = $null
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  $currentSource = 'const DPr={"browser.in-app":{configFeatures:[{key:`in_app_browser`,host:`default`}],supportedClients:[`electron`]}};function available(gj,a){let o=hs(gj,a).isCapable,s=Px(`410262010`);return o&&s}'
  $current = Invoke-PatcherFixture -Name 'codex-26-814-capability' -Source $currentSource -ExpectedExitCode 0
  if ($current.Output -cne 'patched') {
    throw "current Browser sidebar fixture did not report patched: $($current.Output)"
  }
  $patched = [System.IO.File]::ReadAllText($current.AssetPath)
  if (-not $patched.Contains('let o=!0,s=(Px(`410262010`),!0)/*CODEX_BROWSER_IN_APP_GATES_V2*/')) {
    throw 'current Browser sidebar fixture did not force the capability result'
  }
  $syntaxOutput = @(& $node.Source --check $current.AssetPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "current Browser sidebar fixture produced invalid JavaScript: $($syntaxOutput -join ' | ')"
  }

  $secondOutput = @(& $node.Source $patcherPath $current.AssetPath 2>&1)
  if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
    throw "current Browser sidebar fixture was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
  }

  $negativeSource = 'const in_app_browser=true;const unrelated=()=>!0;'
  $negative = Invoke-PatcherFixture -Name 'unrelated-true-callback' -Source $negativeSource -ExpectedExitCode 2
  if ($negative.Output -cne 'browser-sidebar-availability-patch-target-not-found') {
    throw "unrelated Browser sidebar fixture failed for the wrong reason: $($negative.Output)"
  }
  if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
    throw 'unrelated Browser sidebar fixture was modified'
  }
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "Browser sidebar gate regression passed: $fixtureRoot"
