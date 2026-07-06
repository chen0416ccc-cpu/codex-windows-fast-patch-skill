[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$StagingManifest,
  [switch]$AllowStopCodexDesktop,
  [switch]$AllowFromCodexDesktop,
  [switch]$LaunchAfterInstall
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot

function Write-ApplyLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath (Join-Path $state.Paths.Logs 'apply.log') -Value $line -Encoding UTF8
}

Write-ApplyLog "apply started; state root: $($state.Paths.Root)"

if ((Test-GuardInvokedFromCodexDesktop) -and -not $AllowFromCodexDesktop) {
  throw 'Refusing to apply from a Codex Desktop-launched process. Run this from external PowerShell or VS Code Codex, or pass -AllowFromCodexDesktop only after confirming the executor will survive Desktop restart.'
}

$desktopProcesses = @(Get-GuardCodexDesktopProcesses)
if ($desktopProcesses.Count -gt 0 -and -not $AllowStopCodexDesktop) {
  $details = ($desktopProcesses | ForEach-Object { "PID $($_.ProcessId): $($_.ExecutablePath)" }) -join "`r`n"
  throw "Codex Desktop is still running. Close Codex Desktop first, then rerun apply. Running processes:`r`n$details"
}

if ([string]::IsNullOrWhiteSpace($StagingManifest)) {
  $ready = Get-ChildItem -LiteralPath $state.Paths.Staging -Recurse -Filter 'manifest.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
  if (-not $ready) {
    throw 'No StagingManifest was supplied and no staging manifest was found.'
  }
  $StagingManifest = $ready.FullName
}

$manifest = Read-GuardJsonFile -Path $StagingManifest
if (-not $manifest) {
  throw "could not read staging manifest: $StagingManifest"
}
$manifestStatus = [string]$manifest.Status
if ($manifestStatus -notin @('ready', 'current_version_ready', 'patched_update_ready')) {
  throw "staging manifest is not ready for apply; status=$manifestStatus"
}
if ($manifestStatus -ne 'patched_update_ready' -and [string]::IsNullOrWhiteSpace($manifest.ReplacementResourceCodexExe)) {
  throw 'staging manifest does not contain a replacement resources\codex.exe path'
}
$replacementExe = if ([string]::IsNullOrWhiteSpace($manifest.ReplacementResourceCodexExe)) { $null } else { Resolve-GuardFullPath ([string]$manifest.ReplacementResourceCodexExe) }
if ($replacementExe -and -not (Test-Path -LiteralPath $replacementExe -PathType Leaf)) {
  throw "replacement resources\codex.exe not found: $replacementExe"
}

$backupScript = Join-Path $ScriptRoot 'manage-codex-backups.ps1'
$patchScript = Join-Path $ScriptRoot 'patch-remote-control-windows-msix.ps1'
$verifyScript = Join-Path $ScriptRoot 'install-computer-use-local.ps1'
foreach ($script in @($backupScript, $patchScript, $verifyScript)) {
  if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "required script not found: $script"
  }
}

$installedBeforeApply = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
if ($manifestStatus -eq 'current_version_ready') {
  $manifestPackageVersion = Resolve-GuardPropertyPath -Object $manifest -Path 'Snapshot.Package.Version'
  $manifestPackageFullName = Resolve-GuardPropertyPath -Object $manifest -Path 'Snapshot.Package.PackageFullName'
  if ([string]::IsNullOrWhiteSpace($manifestPackageVersion) -or [string]$installedBeforeApply.Version -ne [string]$manifestPackageVersion) {
    throw "current_version_ready staging is only valid for package version '$manifestPackageVersion'; installed version is '$($installedBeforeApply.Version)'. Prepare a new mapping for the installed version instead."
  }
  if (-not [string]::IsNullOrWhiteSpace($manifestPackageFullName) -and $installedBeforeApply.PackageFullName -ne $manifestPackageFullName) {
    throw "current_version_ready staging is only valid for package '$manifestPackageFullName'; installed package is '$($installedBeforeApply.PackageFullName)'. Prepare a new mapping for the installed package instead."
  }
}

if ($manifestStatus -eq 'patched_update_ready') {
  if ([string]::IsNullOrWhiteSpace($manifest.PatchedMsixPath)) {
    throw 'patched_update_ready manifest does not contain PatchedMsixPath'
  }
  $patchedMsixPath = Resolve-GuardFullPath ([string]$manifest.PatchedMsixPath)
  if (-not (Test-Path -LiteralPath $patchedMsixPath -PathType Leaf)) {
    throw "patched MSIX not found: $patchedMsixPath"
  }
  Write-ApplyLog 'creating Desktop state backup before patched update apply'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $backupScript -Action Backup
  if ($LASTEXITCODE -ne 0) {
    throw "backup failed with exit code $LASTEXITCODE"
  }

  if ($installedBeforeApply) {
    Write-ApplyLog "removing existing package before patched update install: $($installedBeforeApply.PackageFullName)"
    try {
      Remove-AppxPackage -Package $installedBeforeApply.PackageFullName -PreserveApplicationData -ErrorAction Stop
    } catch {
      Remove-AppxPackage -Package $installedBeforeApply.PackageFullName -ErrorAction Stop
    }
  }
  Write-ApplyLog "installing patched update MSIX: $patchedMsixPath"
  Add-AppxPackage -Path $patchedMsixPath -ErrorAction Stop

  $installed = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
    Sort-Object Version -Descending |
    Select-Object -First 1
  $expectedVersion = Resolve-GuardPropertyPath -Object $manifest -Path 'Payload.PackageVersion'
  if (-not [string]::IsNullOrWhiteSpace($expectedVersion) -and [string]$installed.Version -ne [string]$expectedVersion) {
    throw "installed patched update version does not match manifest payload; installed=$($installed.Version) payload=$expectedVersion"
  }
  if ($replacementExe) {
    $liveExe = Join-Path $installed.InstallLocation 'app\resources\codex.exe'
    $liveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveExe).Hash.ToUpperInvariant()
    $replacementHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $replacementExe).Hash.ToUpperInvariant()
    if ($liveHash -ne $replacementHash) {
      throw "live resources\codex.exe hash does not match patched update replacement; live=$liveHash replacement=$replacementHash"
    }
  }

  Write-ApplyLog 'running Computer Use strict verify after patched update install'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -StrictVerifyOnly
  if ($LASTEXITCODE -ne 0) {
    throw "post-apply strict verification failed with exit code $LASTEXITCODE"
  }

  Write-GuardNotification -State $state -Name 'APPLIED.txt' -Content "Codex Desktop Guard applied patched update manifest:`r`n$StagingManifest`r`nInstalled package: $($installed.PackageFullName)`r`n" | Out-Null
  Write-ApplyLog "patched update apply complete; installed package: $($installed.PackageFullName)"
  return
}

Write-ApplyLog 'creating Desktop state backup before apply'
& powershell -NoProfile -ExecutionPolicy Bypass -File $backupScript -Action Backup
if ($LASTEXITCODE -ne 0) {
  throw "backup failed with exit code $LASTEXITCODE"
}

$outputRoot = Join-Path $state.Paths.Staging ('apply-msix-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$patchArgs = @(
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  $patchScript,
  '-ReplacementResourceCodexExe',
  $replacementExe,
  '-OutputRoot',
  $outputRoot,
  '-Install',
  '-InstallPrerequisites'
)
if ($LaunchAfterInstall) {
  $patchArgs += '-Launch'
}

Write-ApplyLog "installing prepared replacement through targeted patch script: $replacementExe"
& powershell @patchArgs
if ($LASTEXITCODE -ne 0) {
  throw "targeted patch install failed with exit code $LASTEXITCODE"
}

Write-ApplyLog 'verifying live installed resources\codex.exe hash'
$installed = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
$liveExe = Join-Path $installed.InstallLocation 'app\resources\codex.exe'
$liveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveExe).Hash.ToUpperInvariant()
$replacementHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $replacementExe).Hash.ToUpperInvariant()
if ($liveHash -ne $replacementHash) {
  throw "live resources\codex.exe hash does not match prepared replacement; live=$liveHash replacement=$replacementHash"
}

Write-ApplyLog 'running Computer Use strict verify after package install'
& powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -StrictVerifyOnly
if ($LASTEXITCODE -ne 0) {
  throw "post-apply strict verification failed with exit code $LASTEXITCODE"
}

Write-GuardNotification -State $state -Name 'APPLIED.txt' -Content "Codex Desktop Guard applied staging manifest:`r`n$StagingManifest`r`nInstalled package: $($installed.PackageFullName)`r`n" | Out-Null
Write-ApplyLog "apply complete; installed package: $($installed.PackageFullName)"
