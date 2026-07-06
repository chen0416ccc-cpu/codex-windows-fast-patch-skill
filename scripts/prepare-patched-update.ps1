[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$EventPath,
  [string]$DiscoveryPath,
  [string]$PayloadRoot,
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
$eventId = if ($event -and $event.EventId) { [string]$event.EventId } else { New-GuardUpdateActivityEventId -Snapshot $snapshot }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stagingDir = Join-Path $state.Paths.Staging ("$stamp-$eventId-patched-update")
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

$prepareLog = Join-Path $stagingDir 'prepare-patched-update.log'
$verificationLog = Join-Path $stagingDir 'verification.log'
$manifestPath = Join-Path $stagingDir 'manifest.json'
$hashesPath = Join-Path $stagingDir 'hashes.json'
$diagnosticsPath = Join-Path $stagingDir 'diagnostics.json'

function Write-PatchedUpdateLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath $prepareLog -Value $line -Encoding UTF8
  Add-Content -LiteralPath (Join-Path $state.Paths.Logs 'prepare-patched-update.log') -Value $line -Encoding UTF8
}

function Write-PatchedUpdateTerminalManifest {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$Reason,
    [string[]]$Details = @(),
    [object]$Discovery
  )
  $manifest = [pscustomobject]@{
    SchemaVersion = 1
    Status = $Status
    Mode = 'PatchedUpdate'
    Reason = $Reason
    Details = $Details
    EventId = $eventId
    CreatedAt = (Get-Date).ToString('o')
    StagingDir = $stagingDir
    EventPath = $EventPath
    DiscoveryPath = $DiscoveryPath
    DiagnosticsPath = $diagnosticsPath
    Snapshot = $snapshot
    Discovery = $Discovery
  }
  Write-GuardJsonFile -Path $manifestPath -Value $manifest
  Write-GuardJsonFile -Path $diagnosticsPath -Value ([pscustomobject]@{
    Status = $Status
    Reason = $Reason
    Details = $Details
    Discovery = $Discovery
    Snapshot = $snapshot
  })
  $marker = switch ($Status) {
    'waiting_for_update_payload' { 'WAITING_FOR_UPDATE_PAYLOAD' }
    'needs_update_payload' { 'NEEDS_UPDATE_PAYLOAD' }
    'needs_action' { 'NEEDS_ACTION' }
    default { $Status.ToUpperInvariant() }
  }
  Write-GuardUtf8NoBom -Path (Join-Path $stagingDir $marker) -Content ($Reason + "`r`n")
  $notificationName = "$marker.txt"
  $eventNotificationName = "$marker-$eventId.txt"
  $text = @(
    "Codex Desktop Guard patched-update staging did not produce an installable package yet.",
    "Event: $eventId",
    "Status: $Status",
    "Reason: $Reason",
    "",
    ($Details -join "`r`n"),
    "",
    "No patch was applied and no Desktop process was stopped."
  ) -join "`r`n"
  Write-GuardNotification -State $state -Name $eventNotificationName -Content $text | Out-Null
  Write-GuardNotification -State $state -Name $notificationName -Content $text | Out-Null
  Write-PatchedUpdateLog "$Status`: $Reason"
  return $manifest
}

function Convert-DiscoveryPayloadToSnapshot {
  param([Parameter(Mandatory = $true)][object]$Payload)
  return [pscustomobject]@{
    SchemaVersion = 1
    CreatedAt = (Get-Date).ToString('o')
    Package = [pscustomobject]@{
      Name = 'OpenAI.Codex'
      PackageFullName = $Payload.PackageFullName
      Version = $Payload.PackageVersion
      SignatureKind = 'Unknown'
      InstallLocation = $Payload.Path
    }
    Resources = [pscustomobject]@{
      CodexExe = $Payload.ResourceCodexExe
      AppAsar = $Payload.AppAsar
    }
    LocalCli = [pscustomobject]@{
      Path = $Payload.ResourceCodexExe.Path
      Exists = $Payload.ResourceCodexExe.Exists
      Length = $Payload.ResourceCodexExe.Length
      LastWriteTimeUtc = $Payload.ResourceCodexExe.LastWriteTimeUtc
      Sha256 = $Payload.ResourceCodexExe.Sha256
      VersionOutput = $Payload.CodexCliVersionOutput
      Version = $Payload.CodexCliVersion
      VersionError = $Payload.CodexCliVersionError
    }
    CodexConfigToml = Resolve-GuardPropertyPath -Object $snapshot -Path 'CodexConfigToml'
    UpdateSignals = Resolve-GuardPropertyPath -Object $snapshot -Path 'UpdateSignals'
  }
}

Write-PatchedUpdateLog "patched-update prepare started; event: $eventId; staging: $stagingDir"

if ([string]::IsNullOrWhiteSpace($DiscoveryPath)) {
  $DiscoveryPath = Join-Path $stagingDir 'update-payload-discovery.json'
  $discoverScript = Join-Path $ScriptRoot 'discover-codex-update-payload.ps1'
  if (-not (Test-Path -LiteralPath $discoverScript -PathType Leaf)) {
    throw "discover script not found: $discoverScript"
  }
  $discoverArgs = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $discoverScript,
    '-StateRoot',
    $state.Paths.Root,
    '-OutputPath',
    $DiscoveryPath
  )
  if (-not [string]::IsNullOrWhiteSpace($EventPath)) {
    $discoverArgs += @('-EventPath', $EventPath)
  }
  if (-not [string]::IsNullOrWhiteSpace($PayloadRoot)) {
    $discoverArgs += @('-PayloadRoot', $PayloadRoot)
  }
  Write-PatchedUpdateLog 'discovering update payload'
  & powershell @discoverArgs | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "update payload discovery failed with exit code $LASTEXITCODE"
  }
}

$discovery = Read-GuardJsonFile -Path $DiscoveryPath
if (-not $discovery) {
  throw "could not read discovery output: $DiscoveryPath"
}

if ($discovery.Status -eq 'waiting_for_update_payload' -or $discovery.Status -eq 'no_update_activity') {
  $terminalManifest = Write-PatchedUpdateTerminalManifest -Status 'waiting_for_update_payload' -Reason 'waiting_for_update_payload' -Details @(
    "Codex update/download activity exists, but no usable new OpenAI.Codex payload directory is available yet.",
    "The guard will keep watching. It will not patch the current package as if it were the update."
  ) -Discovery $discovery
  $terminalManifest | ConvertTo-Json -Depth 12
  return
}
if ($discovery.Status -eq 'needs_update_payload' -or -not $discovery.SelectedPayload) {
  $terminalManifest = Write-PatchedUpdateTerminalManifest -Status 'needs_update_payload' -Reason 'needs_update_payload' -Details @(
    "No usable unpacked update payload was found.",
    "Provide a new OpenAI.Codex package root containing app\resources\codex.exe and app\resources\app.asar, or wait for Store deployment to expose one."
  ) -Discovery $discovery
  $terminalManifest | ConvertTo-Json -Depth 12
  return
}

$payload = $discovery.SelectedPayload
$payloadSnapshot = Convert-DiscoveryPayloadToSnapshot -Payload $payload
$mappingResult = Resolve-GuardKnownVersionMapping -Snapshot $payloadSnapshot
if (-not $mappingResult.Safe) {
  $terminalManifest = Write-PatchedUpdateTerminalManifest -Status 'needs_action' -Reason 'needs_manual_version_mapping' -Details @($mappingResult.Reasons) -Discovery $discovery
  $terminalManifest | ConvertTo-Json -Depth 12
  return
}

$mapping = $mappingResult.Mapping
$buildRoot = if ([string]::IsNullOrWhiteSpace($WorkRoot)) { Join-Path $stagingDir 'native-build' } else { Resolve-GuardFullPath $WorkRoot }
$buildRoot = Assert-GuardPathUnderRoot -Path $buildRoot -Root $state.Paths.Root -Label 'WorkRoot'
$replacementExe = $null
$patchedMsixPath = $null
$patchOutputRoot = Join-Path $stagingDir 'patched-msix'

if ($DryRun -or $NoBuild) {
  Write-PatchedUpdateLog 'DryRun/NoBuild set; patched update package build skipped after payload mapping verification'
  Add-Content -LiteralPath $verificationLog -Value 'payload mapping verification passed; build skipped by DryRun/NoBuild' -Encoding UTF8
} else {
  $buildScript = Join-Path $ScriptRoot 'build-remote-control-native-replacement.ps1'
  if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "native build script not found: $buildScript"
  }
  Write-PatchedUpdateLog "building native replacement for update payload under: $buildRoot"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript `
    -WorkRoot $buildRoot `
    -CodexSourceRef $mapping.CodexSourceRef `
    -AppServerVersion $mapping.AppServerVersion *>&1 |
    Tee-Object -FilePath $verificationLog
  if ($LASTEXITCODE -ne 0) {
    throw "native replacement build failed with exit code $LASTEXITCODE"
  }
  $builtReplacement = Join-Path $buildRoot 'target-msvc\x86_64-pc-windows-msvc\dev-small\codex.exe'
  if (-not (Test-Path -LiteralPath $builtReplacement -PathType Leaf)) {
    throw "expected replacement binary was not produced: $builtReplacement"
  }
  $replacementDir = Join-Path $stagingDir 'replacement'
  New-Item -ItemType Directory -Force -Path $replacementDir | Out-Null
  $replacementExe = Join-Path $replacementDir 'codex.exe'
  Copy-Item -LiteralPath $builtReplacement -Destination $replacementExe -Force

  $patchScript = Join-Path $ScriptRoot 'patch-remote-control-windows-msix.ps1'
  if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
    throw "targeted patch script not found: $patchScript"
  }
  New-Item -ItemType Directory -Force -Path $patchOutputRoot | Out-Null
  Write-PatchedUpdateLog "building patched update package from payload: $($payload.Path)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $patchScript `
    -SourceRoot $payload.Path `
    -SourcePackageFullName $payload.PackageFullName `
    -SourcePackageVersion $payload.PackageVersion `
    -ReplacementResourceCodexExe $replacementExe `
    -OutputRoot $patchOutputRoot `
    -InstallPrerequisites *>&1 |
    Tee-Object -FilePath $verificationLog -Append
  if ($LASTEXITCODE -ne 0) {
    throw "patched update package build failed with exit code $LASTEXITCODE"
  }
  $patchedMsix = Get-ChildItem -LiteralPath $patchOutputRoot -Filter '*.msix' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
  if (-not $patchedMsix) {
    throw "patched update package build did not produce an MSIX under: $patchOutputRoot"
  }
  $patchedMsixPath = $patchedMsix.FullName
}

$hashes = [pscustomobject]@{
  PayloadCodexExe = $payload.ResourceCodexExe
  PayloadAppAsar = $payload.AppAsar
  ReplacementResourceCodexExe = if ($replacementExe) { Get-GuardFileFingerprint -Path $replacementExe } else { $null }
  PatchedMsix = if ($patchedMsixPath) { Get-GuardFileFingerprint -Path $patchedMsixPath } else { $null }
}
Write-GuardJsonFile -Path $hashesPath -Value $hashes

$applyScript = Join-Path $ScriptRoot 'apply-prepared-fast-patch.ps1'
$applyCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0} -StateRoot {1} -StagingManifest {2}' -f (ConvertTo-GuardWindowsCommandArgument $applyScript), (ConvertTo-GuardWindowsCommandArgument $state.Paths.Root), (ConvertTo-GuardWindowsCommandArgument $manifestPath)
$status = if ($patchedMsixPath) { 'patched_update_ready' } else { 'patched_update_ready_dry_run' }
$manifest = [pscustomobject]@{
  SchemaVersion = 1
  Status = $status
  Mode = 'PatchedUpdate'
  EventId = $eventId
  CreatedAt = (Get-Date).ToString('o')
  StagingDir = $stagingDir
  EventPath = $EventPath
  DiscoveryPath = $DiscoveryPath
  Mapping = $mapping
  Payload = $payload
  PayloadSnapshot = $payloadSnapshot
  DryRun = [bool]$DryRun
  NoBuild = [bool]$NoBuild
  BuildRoot = $buildRoot
  PatchOutputRoot = $patchOutputRoot
  ReplacementResourceCodexExe = $replacementExe
  PatchedMsixPath = $patchedMsixPath
  HashesPath = $hashesPath
  DiagnosticsPath = $diagnosticsPath
  VerificationLog = $verificationLog
  ApplyCommand = $applyCommand
  Snapshot = $snapshot
}
Write-GuardJsonFile -Path $manifestPath -Value $manifest
Write-GuardJsonFile -Path $diagnosticsPath -Value ([pscustomobject]@{
  Discovery = $discovery
  Mapping = $mappingResult
  PayloadSnapshot = $payloadSnapshot
  Manifest = $manifest
})
Write-GuardUtf8NoBom -Path (Join-Path $stagingDir 'apply-command.ps1.txt') -Content ($applyCommand + "`r`n")
if ($patchedMsixPath) {
  Write-GuardUtf8NoBom -Path (Join-Path $stagingDir 'PATCHED_UPDATE_READY') -Content ("$status`r`n")
  $readyText = @(
    "Codex Desktop Guard prepared a patched update package.",
    "Event: $eventId",
    "Status: $status",
    "Payload: $($payload.Path)",
    "Payload package: $($payload.PackageFullName)",
    "Payload version: $($payload.PackageVersion)",
    "Patched MSIX: $patchedMsixPath",
    "",
    "Close Codex Desktop first, then run this from external PowerShell or VS Code Codex:",
    $applyCommand,
    "",
    "The guard task never applies this automatically."
  ) -join "`r`n"
  Write-GuardNotification -State $state -Name "PATCHED_UPDATE_READY-$eventId.txt" -Content $readyText | Out-Null
  Write-GuardNotification -State $state -Name 'PATCHED_UPDATE_READY.txt' -Content $readyText | Out-Null
} else {
  Write-GuardUtf8NoBom -Path (Join-Path $stagingDir 'PATCHED_UPDATE_READY_DRY_RUN') -Content ("$status`r`n")
}

Write-PatchedUpdateLog "patched-update prepare complete; status: $status; manifest: $manifestPath"
$manifest | ConvertTo-Json -Depth 12
