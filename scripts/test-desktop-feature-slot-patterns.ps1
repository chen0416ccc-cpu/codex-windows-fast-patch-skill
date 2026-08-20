[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

# Desktop 26.818 inserted a `browserExtensions` key between `browserPane` and
# `externalBrowserUse` in the renderer feature payload and in the main-process
# feature object. The sender rewrite is value-only, so the patched text keeps
# that key and the old no-slot patched-state literal never matches again: a
# second run of the patcher on an already-patched install reported
# `browser-use-desktop-feature-sender-patch-target-not-found`. These fixtures
# pin both the new slot shape and the older no-slot shape.

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
      $node.Value.Contains('function patchDesktopFeatureSender(file) {') -and
      $node.Value.Contains('function patchDesktopFeatureMain(file) {')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded desktop-feature patcher was not found in the patch script'
}

$functionStart = $patcherAst.Value.IndexOf('function patchDesktopFeatureSender(file) {', [StringComparison]::Ordinal)
$functionEnd = $patcherAst.Value.IndexOf('patchFeatureHook(featureHookFile);', $functionStart, [StringComparison]::Ordinal)
if ($functionStart -lt 0 -or $functionEnd -le $functionStart) {
  throw 'desktop-feature patch function boundaries were not found'
}
$featureFunctions = $patcherAst.Value.Substring($functionStart, $functionEnd - $functionStart)
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
$featureFunctions
if (process.argv[3] === 'sender') {
  patchDesktopFeatureSender(process.argv[2]);
} else {
  patchDesktopFeatureMain(process.argv[2]);
}
process.stdout.write(changed ? 'patched' : 'already-patched');
"@

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the desktop-feature slot regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('desktop-feature-slots-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchDesktopFeatures.cjs'
[System.IO.File]::WriteAllText($patcherPath, $harness, [System.Text.UTF8Encoding]::new($false))

function Invoke-PatcherFixture {
  param(
    [string]$Name,
    [string]$Source,
    [string]$Target,
    [int]$ExpectedExitCode
  )

  $assetPath = Join-Path $fixtureRoot ($Name + '.js')
  [System.IO.File]::WriteAllText($assetPath, $Source, [System.Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source $patcherPath $assetPath $Target 2>&1)
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

function Assert-Idempotent {
  param(
    [string]$Name,
    [string]$AssetPath,
    [string]$Target
  )

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source $patcherPath $AssetPath $Target 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0 -or (($output -join "`n").Trim() -cne 'already-patched')) {
    throw "$Name fixture was not idempotent: exit=$exitCode output=$($output -join ' | ')"
  }
}

function Assert-ValidJavaScript {
  param(
    [string]$Name,
    [string]$AssetPath
  )

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source --check $AssetPath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "$Name fixture produced invalid JavaScript: $($output -join ' | ')"
  }
}

# Desktop 26.818 renderer payload: `browserExtensions` sits between browserPane
# and externalBrowserUse.
$senderSlotSource = 'const send=(c,p)=>p;function notify(s,a,o,r,l){send(`electron-desktop-features-changed`,{codexLocalAccess:s.codexLocalAccess,inAppBrowserUse:s.inAppBrowserUse,inAppBrowserUseAllowed:s.inAppBrowserUseAllowed,inAppBrowserUseHistory:s.inAppBrowserUseHistory,browserUseTinysky:s.browserUseTinysky,defaultLinkOpenTargetPreference:s.defaultLinkOpenTargetPreference,localBackend:s.localBackend,browserPane:s.browserPane,browserExtensions:s.browserExtensions,externalBrowserUse:s.externalBrowserUse,externalBrowserUseAllowed:s.externalBrowserUseAllowed,computerUse:s.computerUse,computerUseNodeRepl:s.computerUseNodeRepl});logger.info(`browser_use_availability_resolved`,{safe:{available:a,platform:o,reason:r,release:l},sensitive:{browserPane:s.browserPane}});}'
# Pre-26.818 renderer payload: no key between browserPane and externalBrowserUse.
$senderLegacySource = 'const send=(c,p)=>p;function notify(s,a,o,r,l){send(`electron-desktop-features-changed`,{inAppBrowserUse:s.inAppBrowserUse,inAppBrowserUseAllowed:s.inAppBrowserUseAllowed,inAppBrowserUseHistory:s.inAppBrowserUseHistory,browserPane:s.browserPane,externalBrowserUse:s.externalBrowserUse,externalBrowserUseAllowed:s.externalBrowserUseAllowed,computerUse:s.computerUse});logger.info(`browser_use_availability_resolved`,{safe:{available:a,platform:o,reason:r,release:l},sensitive:{browserPane:s.browserPane}});}'
$senderNegativeSource = 'const send=(c,p)=>p;const unrelated=()=>!0;'

# Main-process env gate, which is the shape real builds carry, plus a
# `browserExtensions` slot in the object it spreads.
$mainSlotSource = 'const env=process.env;function resolve(e,t,r){let i=r===`win32`&&env.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`?{...e,computerUse:!0,computerUseNodeRepl:!0}:e;let n={inAppBrowserUse:e.inAppBrowserUse,inAppBrowserUseAllowed:e.inAppBrowserUseAllowed,inAppBrowserUseHistory:e.inAppBrowserUseHistory,browserPane:e.browserPane,browserExtensions:e.browserExtensions,externalBrowserUse:e.externalBrowserUse,externalBrowserUseAllowed:e.externalBrowserUseAllowed,computerUse:e.computerUse};return[i,n];}'
# Same env gate without the new slot.
$mainLegacySource = 'const env=process.env;function resolve(e,t,r){let i=r===`win32`&&env.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`?{...e,computerUse:!0,computerUseNodeRepl:!0}:e;let n={inAppBrowserUse:e.inAppBrowserUse,inAppBrowserUseAllowed:e.inAppBrowserUseAllowed,browserPane:e.browserPane,externalBrowserUse:e.externalBrowserUse,externalBrowserUseAllowed:e.externalBrowserUseAllowed,computerUse:e.computerUse};return[i,n];}'
$mainNegativeSource = 'const env=process.env;const unrelated=()=>!0;'

$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
$previousNativePreference = $null
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  # 26.818 sender: the middle slot must survive the rewrite, the availability
  # telemetry must be forced local, and a second run must stay a no-op.
  $slot = Invoke-PatcherFixture -Name 'codex-26-818-desktop-feature-sender' -Source $senderSlotSource -Target 'sender' -ExpectedExitCode 0
  if ($slot.Output -cne 'patched') {
    throw "26.818 sender fixture did not report patched: $($slot.Output)"
  }
  $patched = [System.IO.File]::ReadAllText($slot.AssetPath)
  foreach ($fragment in @(
      'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,inAppBrowserUseHistory:s.inAppBrowserUseHistory,browserUseTinysky:s.browserUseTinysky,defaultLinkOpenTargetPreference:s.defaultLinkOpenTargetPreference,localBackend:s.localBackend,browserPane:!0,browserExtensions:s.browserExtensions,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:s.computerUse',
      'safe:{available:!0,platform:o,reason:`local-patched`,release:l}',
      'sensitive:{browserPane:!0}')) {
    if (-not $patched.Contains($fragment)) {
      throw "26.818 sender fixture is missing fragment: $fragment"
    }
  }
  Assert-ValidJavaScript -Name '26.818 sender' -AssetPath $slot.AssetPath
  Assert-Idempotent -Name '26.818 sender' -AssetPath $slot.AssetPath -Target 'sender'

  # Older builds without the slot must keep patching and stay idempotent.
  $legacy = Invoke-PatcherFixture -Name 'codex-26-814-desktop-feature-sender' -Source $senderLegacySource -Target 'sender' -ExpectedExitCode 0
  if ($legacy.Output -cne 'patched') {
    throw "pre-26.818 sender fixture did not report patched: $($legacy.Output)"
  }
  $patchedLegacy = [System.IO.File]::ReadAllText($legacy.AssetPath)
  if (-not $patchedLegacy.Contains('browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:s.computerUse')) {
    throw 'pre-26.818 sender fixture lost its no-slot patched shape'
  }
  Assert-ValidJavaScript -Name 'pre-26.818 sender' -AssetPath $legacy.AssetPath
  Assert-Idempotent -Name 'pre-26.818 sender' -AssetPath $legacy.AssetPath -Target 'sender'

  $senderNegative = Invoke-PatcherFixture -Name 'unrelated-desktop-feature-sender' -Source $senderNegativeSource -Target 'sender' -ExpectedExitCode 2
  if ($senderNegative.Output -cne 'browser-use-desktop-feature-sender-target-not-found') {
    throw "unrelated sender fixture failed for the wrong reason: $($senderNegative.Output)"
  }
  if ([System.IO.File]::ReadAllText($senderNegative.AssetPath) -cne $senderNegativeSource) {
    throw 'unrelated sender fixture was modified'
  }

  # 26.818 main: the env gate is rewritten and the slot-bearing feature object
  # keeps `browserExtensions` while the browser flags are forced on.
  $mainSlot = Invoke-PatcherFixture -Name 'codex-26-818-desktop-feature-main' -Source $mainSlotSource -Target 'main' -ExpectedExitCode 0
  if ($mainSlot.Output -cne 'patched') {
    throw "26.818 main fixture did not report patched: $($mainSlot.Output)"
  }
  $patchedMain = [System.IO.File]::ReadAllText($mainSlot.AssetPath)
  foreach ($fragment in @(
      'browserPane:!0,inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0',
      'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,inAppBrowserUseHistory:e.inAppBrowserUseHistory,browserPane:!0,browserExtensions:e.browserExtensions,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:e.computerUse')) {
    if (-not $patchedMain.Contains($fragment)) {
      throw "26.818 main fixture is missing fragment: $fragment"
    }
  }
  Assert-ValidJavaScript -Name '26.818 main' -AssetPath $mainSlot.AssetPath
  Assert-Idempotent -Name '26.818 main' -AssetPath $mainSlot.AssetPath -Target 'main'

  $mainLegacy = Invoke-PatcherFixture -Name 'codex-26-814-desktop-feature-main' -Source $mainLegacySource -Target 'main' -ExpectedExitCode 0
  if ($mainLegacy.Output -cne 'patched') {
    throw "pre-26.818 main fixture did not report patched: $($mainLegacy.Output)"
  }
  $patchedMainLegacy = [System.IO.File]::ReadAllText($mainLegacy.AssetPath)
  if (-not $patchedMainLegacy.Contains('inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:e.computerUse')) {
    throw 'pre-26.818 main fixture lost its no-slot patched shape'
  }
  Assert-ValidJavaScript -Name 'pre-26.818 main' -AssetPath $mainLegacy.AssetPath
  Assert-Idempotent -Name 'pre-26.818 main' -AssetPath $mainLegacy.AssetPath -Target 'main'

  $mainNegative = Invoke-PatcherFixture -Name 'unrelated-desktop-feature-main' -Source $mainNegativeSource -Target 'main' -ExpectedExitCode 2
  if ($mainNegative.Output -cne 'browser-use-desktop-feature-main-target-not-found') {
    throw "unrelated main fixture failed for the wrong reason: $($mainNegative.Output)"
  }
  if ([System.IO.File]::ReadAllText($mainNegative.AssetPath) -cne $mainNegativeSource) {
    throw 'unrelated main fixture was modified'
  }
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "desktop-feature slot regression passed: $fixtureRoot"
