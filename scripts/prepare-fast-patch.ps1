[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$EventPath,
  [switch]$DryRun,
  [switch]$NoBuild,
  [string]$WorkRoot
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot

$event = $null
if (-not [string]::IsNullOrWhiteSpace($EventPath)) {
  $event = Read-GuardJsonFile -Path $EventPath
  if (-not $event) {
    throw "event file could not be read: $EventPath"
  }
}

$snapshot = if ($event -and $event.CurrentSnapshot) { $event.CurrentSnapshot } else { Get-GuardSnapshot }
$eventId = if ($event -and $event.EventId) { [string]$event.EventId } else { New-GuardEventId -Changes @() -Snapshot $snapshot }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stagingDir = Join-Path $state.Paths.Staging ("$stamp-$eventId")
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

$prepareLog = Join-Path $stagingDir 'prepare.log'
$verificationLog = Join-Path $stagingDir 'verification.log'
$manifestPath = Join-Path $stagingDir 'manifest.json'
$hashesPath = Join-Path $stagingDir 'hashes.json'

function Write-PrepareLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath $prepareLog -Value $line -Encoding UTF8
  Add-Content -LiteralPath (Join-Path $state.Paths.Logs 'prepare.log') -Value $line -Encoding UTF8
}

function Complete-NeedsAction {
  param(
    [string]$Reason,
    [string[]]$Details
  )
  $manifest = [pscustomobject]@{
    SchemaVersion = 1
    Status = 'needs_action'
    Reason = $Reason
    Details = $Details
    EventId = $eventId
    CreatedAt = (Get-Date).ToString('o')
    StagingDir = $stagingDir
    EventPath = $EventPath
    Snapshot = $snapshot
  }
  Write-GuardJsonFile -Path $manifestPath -Value $manifest
  Write-GuardJsonFile -Path $hashesPath -Value ([pscustomobject]@{
    CodexExe = Resolve-GuardPropertyPath -Object $snapshot -Path 'Resources.CodexExe'
    AppAsar = Resolve-GuardPropertyPath -Object $snapshot -Path 'Resources.AppAsar'
    LocalCli = Resolve-GuardPropertyPath -Object $snapshot -Path 'LocalCli'
    CodexConfigToml = Resolve-GuardPropertyPath -Object $snapshot -Path 'CodexConfigToml'
  })
  Write-GuardUtf8NoBom -Path (Join-Path $stagingDir 'NEEDS_ACTION') -Content ($Reason + "`r`n")
  $text = @(
    "Codex Desktop Guard needs manual action.",
    "Event: $eventId",
    "Reason: $Reason",
    "",
    ($Details -join "`r`n"),
    "",
    "No patch was prepared. Do not reuse an old native replacement for this version."
  ) -join "`r`n"
  Write-GuardNotification -State $state -Name "NEEDS_ACTION-$eventId.txt" -Content $text | Out-Null
  Write-GuardNotification -State $state -Name 'NEEDS_ACTION.txt' -Content $text | Out-Null
  Write-PrepareLog "needs action: $Reason"
  return $manifest
}

Write-PrepareLog "prepare started; event: $eventId; staging: $stagingDir"
$mappingResult = Resolve-GuardKnownVersionMapping -Snapshot $snapshot
if (-not $mappingResult.Safe) {
  [void](Complete-NeedsAction -Reason 'needs_manual_version_mapping' -Details @($mappingResult.Reasons))
  return
}

$mapping = $mappingResult.Mapping
$replacementExe = $null
$buildRoot = if ([string]::IsNullOrWhiteSpace($WorkRoot)) { Join-Path $stagingDir 'native-build' } else { Resolve-GuardFullPath $WorkRoot }
$buildRoot = Assert-GuardPathUnderRoot -Path $buildRoot -Root $state.Paths.Root -Label 'WorkRoot'

Write-PrepareLog "safe mapping resolved: package=$($mapping.PackageVersion), codex-cli=$($mapping.NativeCliVersion), source=$($mapping.CodexSourceRef)"
if ($DryRun -or $NoBuild) {
  Write-PrepareLog 'DryRun/NoBuild set; native build skipped after mapping verification'
  Add-Content -LiteralPath $verificationLog -Value 'mapping verification passed; build skipped by DryRun/NoBuild' -Encoding UTF8
} else {
  $buildScript = Join-Path $ScriptRoot 'build-remote-control-native-replacement.ps1'
  if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "native build script not found: $buildScript"
  }
  Write-PrepareLog "starting native replacement build under: $buildRoot"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript `
    -WorkRoot $buildRoot `
    -CodexSourceRef $mapping.CodexSourceRef `
    -AppServerVersion $mapping.AppServerVersion *>&1 |
    Tee-Object -FilePath $verificationLog
  if ($LASTEXITCODE -ne 0) {
    throw "native replacement build failed with exit code $LASTEXITCODE"
  }
  $replacementExe = Join-Path $buildRoot 'target-msvc\x86_64-pc-windows-msvc\dev-small\codex.exe'
  if (-not (Test-Path -LiteralPath $replacementExe -PathType Leaf)) {
    throw "expected replacement binary was not produced: $replacementExe"
  }
}

$replacementInfo = if ($replacementExe) { Get-GuardFileFingerprint -Path $replacementExe } else { $null }
$hashes = [pscustomobject]@{
  CodexExe = Resolve-GuardPropertyPath -Object $snapshot -Path 'Resources.CodexExe'
  AppAsar = Resolve-GuardPropertyPath -Object $snapshot -Path 'Resources.AppAsar'
  LocalCli = Resolve-GuardPropertyPath -Object $snapshot -Path 'LocalCli'
  CodexConfigToml = Resolve-GuardPropertyPath -Object $snapshot -Path 'CodexConfigToml'
  ReplacementResourceCodexExe = $replacementInfo
}
Write-GuardJsonFile -Path $hashesPath -Value $hashes

$applyScript = Join-Path $ScriptRoot 'apply-prepared-fast-patch.ps1'
$applyCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0} -StateRoot {1} -StagingManifest {2}' -f (ConvertTo-GuardWindowsCommandArgument $applyScript), (ConvertTo-GuardWindowsCommandArgument $state.Paths.Root), (ConvertTo-GuardWindowsCommandArgument $manifestPath)
$applyCommandPath = Join-Path $stagingDir 'apply-command.ps1.txt'

$status = if ($replacementExe) { 'ready' } else { 'ready_dry_run' }
$manifest = [pscustomobject]@{
  SchemaVersion = 1
  Status = $status
  EventId = $eventId
  CreatedAt = (Get-Date).ToString('o')
  StagingDir = $stagingDir
  EventPath = $EventPath
  Mapping = $mapping
  DryRun = [bool]$DryRun
  NoBuild = [bool]$NoBuild
  BuildRoot = $buildRoot
  ReplacementResourceCodexExe = $replacementExe
  HashesPath = $hashesPath
  VerificationLog = $verificationLog
  ApplyCommand = $applyCommand
  Snapshot = $snapshot
}
Write-GuardJsonFile -Path $manifestPath -Value $manifest
Write-GuardUtf8NoBom -Path $applyCommandPath -Content ($applyCommand + "`r`n")
Write-GuardUtf8NoBom -Path (Join-Path $stagingDir 'READY') -Content ("$status`r`n")

$readyText = @(
  "Codex Desktop Guard prepared a fast-patch staging directory.",
  "Event: $eventId",
  "Status: $status",
  "Staging: $stagingDir",
  "",
  "Close Codex Desktop first, then run this from external PowerShell or VS Code Codex:",
  $applyCommand,
  "",
  "The guard task never applies this automatically."
) -join "`r`n"
Write-GuardNotification -State $state -Name "READY-$eventId.txt" -Content $readyText | Out-Null
Write-GuardNotification -State $state -Name 'READY.txt' -Content $readyText | Out-Null
Write-PrepareLog "prepare complete; status: $status; manifest: $manifestPath"
$manifest | ConvertTo-Json -Depth 12
