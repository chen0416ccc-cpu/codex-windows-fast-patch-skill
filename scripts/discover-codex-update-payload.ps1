[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$EventPath,
  [string]$PayloadRoot,
  [string]$OutputPath,
  [switch]$NoNotifications
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot

$event = $null
if (-not [string]::IsNullOrWhiteSpace($EventPath)) {
  $event = Read-GuardJsonFile -Path $EventPath
}
$snapshot = if ($event -and $event.CurrentSnapshot) { $event.CurrentSnapshot } else { Get-GuardSnapshot }
$eventId = if ($event -and $event.EventId) { [string]$event.EventId } else { New-GuardUpdateActivityEventId -Snapshot $snapshot }

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $state.Paths.Logs ("update-payload-discovery-$eventId.json")
}

function Get-PackageIdentityFromRoot {
  param([Parameter(Mandatory = $true)][string]$Root)
  $name = Split-Path -Leaf $Root
  $manifestPath = Join-Path $Root 'AppxManifest.xml'
  $version = $null
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
      [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
      $version = [string]$manifest.Package.Identity.Version
    } catch {
    }
  }
  if ([string]::IsNullOrWhiteSpace($version) -and $name -match '^OpenAI\.Codex_([^_]+)_') {
    $version = $Matches[1]
  }
  return [pscustomobject]@{
    PackageFullName = $name
    Version = $version
    ManifestPath = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { $manifestPath } else { $null }
  }
}

function Get-CodexExeVersionFromPath {
  param([string]$Path)
  $versionOutput = $null
  $version = $null
  $errorText = $null
  try {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      throw "codex.exe not found: $Path"
    }
    try {
      $capture = Invoke-GuardProcessCapture -FilePath $Path -Arguments @('--version') -TimeoutSeconds 15
    } catch {
      $firstError = $_.Exception.Message
      $probeRoot = Join-Path $env:TEMP 'codex-guard-version-probe'
      $probeDir = Join-Path $probeRoot ([guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
      $probeExe = Join-Path $probeDir 'codex.exe'
      try {
        Copy-Item -LiteralPath $Path -Destination $probeExe -Force
        $capture = Invoke-GuardProcessCapture -FilePath $probeExe -Arguments @('--version') -TimeoutSeconds 15
      } catch {
        throw "$firstError; fallback copy probe failed: $($_.Exception.Message)"
      } finally {
        Remove-Item -LiteralPath $probeExe -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $probeDir -Force -ErrorAction SilentlyContinue
      }
    }
    $versionOutput = $capture.Stdout
    if ($capture.ExitCode -ne 0) {
      throw "codex.exe --version exited with $($capture.ExitCode): $($capture.Stderr)"
    }
    if ($versionOutput -match 'codex-cli\s+([0-9]+\.[0-9]+\.[0-9]+)') {
      $version = $Matches[1]
    }
  } catch {
    $errorText = $_.Exception.Message
  }
  return [pscustomobject]@{
    VersionOutput = $versionOutput
    Version = $version
    Error = $errorText
  }
}

function New-DirectoryCandidate {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Source = 'directory'
  )
  $fullRoot = Resolve-GuardFullPath $Root
  $identity = Get-PackageIdentityFromRoot -Root $fullRoot
  $resourceCodexExe = Join-Path $fullRoot 'app\resources\codex.exe'
  $appAsar = Join-Path $fullRoot 'app\resources\app.asar'
  $shellExe = Join-Path $fullRoot 'app\Codex.exe'
  $resourceInfo = Get-GuardFileFingerprint -Path $resourceCodexExe
  $appAsarInfo = Get-GuardFileFingerprint -Path $appAsar
  $shellInfo = Get-GuardFileFingerprint -Path $shellExe
  $currentPackageFullName = Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.PackageFullName'
  $currentPackageVersion = Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.Version'
  $hasRequiredResources = [bool]($resourceInfo.Exists -and $appAsarInfo.Exists -and $shellInfo.Exists)
  $isCurrentInstalled = (-not [string]::IsNullOrWhiteSpace($currentPackageFullName) -and $identity.PackageFullName -eq $currentPackageFullName)
  $isSameVersion = (-not [string]::IsNullOrWhiteSpace($currentPackageVersion) -and $identity.Version -eq $currentPackageVersion)
  $usable = [bool]($hasRequiredResources -and -not $isCurrentInstalled -and -not $isSameVersion)
  $versionInfo = if ($usable) {
    Get-CodexExeVersionFromPath -Path $resourceCodexExe
  } else {
    [pscustomobject]@{
      VersionOutput = $null
      Version = $null
      Error = 'version probe skipped for current or non-usable payload'
    }
  }
  $reason = if ($usable) {
    'usable_update_payload'
  } elseif (-not $hasRequiredResources) {
    'missing_required_resources'
  } elseif ($isCurrentInstalled) {
    'current_installed_package'
  } elseif ($isSameVersion) {
    'same_package_version_as_current'
  } else {
    'not_usable'
  }
  return [pscustomobject]@{
    Source = $Source
    Kind = 'unpacked_directory'
    Path = $fullRoot
    PackageFullName = $identity.PackageFullName
    PackageVersion = $identity.Version
    ManifestPath = $identity.ManifestPath
    HasRequiredResources = $hasRequiredResources
    IsCurrentInstalled = $isCurrentInstalled
    IsSameVersionAsCurrent = $isSameVersion
    Usable = $usable
    Reason = $reason
    ResourceCodexExe = $resourceInfo
    AppAsar = $appAsarInfo
    CodexShellExe = $shellInfo
    CodexCliVersion = $versionInfo.Version
    CodexCliVersionOutput = $versionInfo.VersionOutput
    CodexCliVersionError = $versionInfo.Error
  }
}

$candidates = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]

if (-not [string]::IsNullOrWhiteSpace($PayloadRoot)) {
  try {
    $candidates.Add((New-DirectoryCandidate -Root $PayloadRoot -Source 'explicit_payload_root'))
  } catch {
    $errors.Add([pscustomobject]@{
      Source = 'explicit_payload_root'
      Path = $PayloadRoot
      Error = $_.Exception.Message
    })
  }
}

$windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
if (Test-Path -LiteralPath $windowsApps -PathType Container) {
  try {
    Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue |
      ForEach-Object {
        try {
          $candidates.Add((New-DirectoryCandidate -Root $_.FullName -Source 'windowsapps_directory'))
        } catch {
          $errors.Add([pscustomobject]@{
            Source = 'windowsapps_directory'
            Path = $_.FullName
            Error = $_.Exception.Message
          })
        }
      }
  } catch {
    $errors.Add([pscustomobject]@{
      Source = 'windowsapps_directory_scan'
      Path = $windowsApps
      Error = $_.Exception.Message
    })
  }
}

$usableCandidates = @($candidates | Where-Object { $_.Usable } | Sort-Object PackageVersion -Descending)
$status = if ($usableCandidates.Count -gt 0) {
  'update_payload_ready'
} elseif (-not [string]::IsNullOrWhiteSpace($PayloadRoot)) {
  'needs_update_payload'
} elseif ($snapshot.UpdateSignals -and $snapshot.UpdateSignals.HasCodexUpdateActivity) {
  'waiting_for_update_payload'
} else {
  'no_update_activity'
}
$selected = if ($usableCandidates.Count -gt 0) { $usableCandidates[0] } else { $null }

$discovery = [pscustomobject]@{
  SchemaVersion = 1
  Status = $status
  EventId = $eventId
  CreatedAt = (Get-Date).ToString('o')
  StateRoot = $state.Paths.Root
  EventPath = $EventPath
  CurrentPackageFullName = (Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.PackageFullName')
  CurrentPackageVersion = (Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.Version')
  UpdateSignals = (Resolve-GuardPropertyPath -Object $snapshot -Path 'UpdateSignals')
  SelectedPayload = $selected
  CandidateCount = $candidates.Count
  UsableCandidateCount = $usableCandidates.Count
  Candidates = @($candidates.ToArray())
  Errors = @($errors.ToArray())
  OutputPath = $OutputPath
}

Write-GuardJsonFile -Path $OutputPath -Value $discovery
if (-not $NoNotifications) {
  if ($status -eq 'update_payload_ready') {
    $text = @(
      "Codex Desktop Guard found an update payload.",
      "Event: $eventId",
      "Payload: $($selected.Path)",
      "Package: $($selected.PackageFullName)",
      "Version: $($selected.PackageVersion)",
      "codex-cli: $($selected.CodexCliVersion)",
      "",
      "The guard has not installed anything. A patched-update prepare step can now process this payload."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "UPDATE_PAYLOAD_READY-$eventId.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'UPDATE_PAYLOAD_READY.txt' -Content $text | Out-Null
  } elseif ($status -eq 'waiting_for_update_payload') {
    $text = @(
      "Codex Desktop Guard detected update/download activity but no usable new Codex Desktop payload is available yet.",
      "Event: $eventId",
      "Current package: $(Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.PackageFullName')",
      "Candidate directories checked: $($candidates.Count)",
      "Usable update payloads: 0",
      "",
      "The guard did not patch or install anything. It will keep watching for a new OpenAI.Codex package directory or explicit payload."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "WAITING_FOR_UPDATE_PAYLOAD-$eventId.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'WAITING_FOR_UPDATE_PAYLOAD.txt' -Content $text | Out-Null
  } elseif ($status -eq 'needs_update_payload') {
    $text = @(
      "Codex Desktop Guard could not use the supplied update payload.",
      "Event: $eventId",
      "PayloadRoot: $PayloadRoot",
      "Candidate directories checked: $($candidates.Count)",
      "Usable update payloads: 0",
      "",
      "Provide an unpacked OpenAI.Codex payload containing app\resources\codex.exe and app\resources\app.asar."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "NEEDS_UPDATE_PAYLOAD-$eventId.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'NEEDS_UPDATE_PAYLOAD.txt' -Content $text | Out-Null
  }
}

$discovery | ConvertTo-Json -Depth 12
