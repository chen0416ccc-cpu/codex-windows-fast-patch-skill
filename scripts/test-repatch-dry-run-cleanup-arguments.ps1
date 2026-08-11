[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptRoot 'repatch-codex-windows.ps1'
$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('repatch-dry-run-cleanup-' + [guid]::NewGuid().ToString('N'))
$fakePatcher = Join-Path $fixtureRoot 'fake-patcher.ps1'
$capturePath = Join-Path $fixtureRoot 'captured-parameters.json'
$outputRoot = Join-Path $fixtureRoot 'patch-output'
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

$fakePatcherSource = @'
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ForceRebuild,
  [switch]$CleanupAfter,
  [switch]$InstallPrerequisites,
  [switch]$Install,
  [switch]$Launch,
  [switch]$CleanupWindowsSdkAfterInstall,
  [switch]$VerifyFastModeRequest,
  [string]$OutputRoot
)

$record = [ordered]@{
  keys = @($PSBoundParameters.Keys | Sort-Object)
  outputRoot = $OutputRoot
}
$json = ($record | ConvertTo-Json -Depth 5) + "`n"
[System.IO.File]::WriteAllText(
  $env:CODEX_TEST_PATCH_ARGS_OUTPUT,
  $json,
  [System.Text.UTF8Encoding]::new($false)
)
'@
[System.IO.File]::WriteAllText(
  $fakePatcher,
  $fakePatcherSource,
  [System.Text.UTF8Encoding]::new($false)
)

function Invoke-DryRunFixture {
  param([switch]$KeepBuild)

  if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
    [System.IO.File]::Delete($capturePath)
  }
  $previousCapturePath = $env:CODEX_TEST_PATCH_ARGS_OUTPUT
  try {
    $env:CODEX_TEST_PATCH_ARGS_OUTPUT = $capturePath
    $arguments = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $wrapper,
      '-DryRun',
      '-SkipMarketplace',
      '-SkipComputerUse',
      '-PatchScript',
      $fakePatcher,
      '-OutputRoot',
      $outputRoot
    )
    if ($KeepBuild) {
      $arguments += '-KeepBuild'
    }
    $output = @(& powershell @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "wrapper DryRun fixture failed: $($output -join [Environment]::NewLine)"
    }
  } finally {
    $env:CODEX_TEST_PATCH_ARGS_OUTPUT = $previousCapturePath
  }

  if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    throw 'fake patcher did not capture wrapper arguments'
  }
  return Get-Content -Raw -Encoding UTF8 -LiteralPath $capturePath | ConvertFrom-Json
}

function Assert-KeySet {
  param(
    [object]$Capture,
    [string[]]$Required,
    [string[]]$Forbidden
  )

  $keys = @($Capture.keys | ForEach-Object { [string]$_ })
  foreach ($name in $Required) {
    if ($keys -cnotcontains $name) {
      throw "wrapper did not forward required fake-patcher parameter: $name keys=$($keys -join ',')"
    }
  }
  foreach ($name in $Forbidden) {
    if ($keys -ccontains $name) {
      throw "wrapper forwarded forbidden fake-patcher parameter: $name keys=$($keys -join ',')"
    }
  }
  if ([string]$Capture.outputRoot -cne $outputRoot) {
    throw "wrapper forwarded the wrong OutputRoot: actual=$($Capture.outputRoot) expected=$outputRoot"
  }
}

$defaultCapture = Invoke-DryRunFixture
Assert-KeySet $defaultCapture `
  -Required @('DryRun', 'ForceRebuild', 'CleanupAfter', 'OutputRoot') `
  -Forbidden @('InstallPrerequisites', 'Install', 'Launch', 'CleanupWindowsSdkAfterInstall', 'VerifyFastModeRequest')

$keepCapture = Invoke-DryRunFixture -KeepBuild
Assert-KeySet $keepCapture `
  -Required @('DryRun', 'ForceRebuild', 'OutputRoot') `
  -Forbidden @('CleanupAfter', 'InstallPrerequisites', 'Install', 'Launch', 'CleanupWindowsSdkAfterInstall', 'VerifyFastModeRequest')

Write-Output "Repatch DryRun cleanup argument forwarding regression passed: $fixtureRoot"
