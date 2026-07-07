[CmdletBinding()]
param(
  [string]$StateRoot,
  [switch]$Once,
  [switch]$NoPrepare,
  [switch]$NotifyMsg
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$baselinePath = Join-Path $state.Paths.Baselines 'current.json'
$eventLogPath = Join-Path $state.Paths.Logs 'events.jsonl'

function New-GuardUpdateActivityText {
  param(
    [Parameter(Mandatory = $true)]$Snapshot,
    [string]$EventId = ''
  )
  $signals = $Snapshot.UpdateSignals
  $eventLine = if ([string]::IsNullOrWhiteSpace($EventId)) { 'Event: none; active update signal is already in the baseline' } else { "Event: $EventId" }
  $versionCache = ''
  if ($signals -and $signals.DoctorVersionCache) {
    if ($signals.DoctorVersionCache -is [array]) {
      $versionCache = ($signals.DoctorVersionCache -join '; ')
    } else {
      $versionCache = [string]$signals.DoctorVersionCache
    }
  }
  $latestVersion = if ($signals -and -not [string]::IsNullOrWhiteSpace($signals.DoctorLatestVersion)) { $signals.DoctorLatestVersion } else { 'unknown' }
  $latestStatus = if ($signals -and -not [string]::IsNullOrWhiteSpace($signals.DoctorLatestVersionStatus)) { $signals.DoctorLatestVersionStatus } else { 'unknown' }
  $probe = if ($signals -and -not [string]::IsNullOrWhiteSpace($signals.DoctorLatestVersionProbe)) { $signals.DoctorLatestVersionProbe } else { 'not reported' }
  $errorText = if ($signals -and -not [string]::IsNullOrWhiteSpace($signals.DoctorUpdateError)) { $signals.DoctorUpdateError } else { 'none' }

  return @(
    "Codex Desktop Guard detected Codex-related update activity before an installed package/resource change.",
    "Refreshed: $((Get-Date).ToString('o'))",
    $eventLine,
    "Installed package/resource changed: no",
    "WindowsApps Codex directories: $($signals.CodexWindowsAppsDirectoryCount)",
    "Recent Codex AppX events: $($signals.RecentCodexAppxEventCount)",
    "BITS Codex transfers: $($signals.BitsCodexTransferCount)",
    "Current CLI version: $($signals.DoctorCodexVersion)",
    "Doctor update status: $($signals.DoctorUpdateStatus)",
    "Doctor update summary: $($signals.DoctorUpdateSummary)",
    "Doctor startup update check: $($signals.DoctorStartupUpdateCheck)",
    "Doctor latest version: $latestVersion",
    "Doctor latest version status: $latestStatus",
    "Doctor latest version probe: $probe",
    "Doctor update action: $($signals.DoctorUpdateAction)",
    "Doctor version cache: $versionCache",
    "Doctor update error: $errorText",
    "",
    "The guard did not apply any patch.",
    "If this update/download activity is new, the guard now runs update payload acquisition and discovery. It writes PATCHED_UPDATE_READY when a patched update package is staged, or NEEDS_UPDATE_SOURCE when Store/package acquisition needs user action."
  ) -join "`r`n"
}

function Invoke-GuardPrepareUpdateActivity {
  param(
    [Parameter(Mandatory = $true)][string]$EventId,
    [string]$EventPath,
    [Parameter(Mandatory = $true)]$Snapshot
  )
  $lastPreparedPath = Join-Path $state.Paths.Baselines 'last-prepared-patched-update-event-id.txt'
  $lastPreparedEventId = if (Test-Path -LiteralPath $lastPreparedPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $lastPreparedPath).Trim() } else { '' }

  function Get-LatestPatchedUpdateManifestForEvent {
    param([Parameter(Mandatory = $true)][string]$Id)
    $pattern = "*-$Id-patched-update"
    $dir = Get-ChildItem -LiteralPath $state.Paths.Staging -Directory -Filter $pattern -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1
    if (-not $dir) {
      return $null
    }
    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      return $null
    }
    return Read-GuardJsonFile -Path $manifestPath
  }

  function Test-IncomingPayloadCandidate {
    if (-not (Test-Path -LiteralPath $state.Paths.Incoming -PathType Container)) {
      return $false
    }
    $manifest = Get-ChildItem -LiteralPath $state.Paths.Incoming -Recurse -File -Filter 'AppxManifest.xml' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    return ($null -ne $manifest)
  }

  function Test-StoreOfflineAuthorizationRequiredForEvent {
    param([Parameter(Mandatory = $true)][string]$Id)
    $notificationPath = Join-Path $state.Paths.Notifications "STORE_OFFLINE_AUTHORIZATION_REQUIRED-$Id.txt"
    if (Test-Path -LiteralPath $notificationPath -PathType Leaf) {
      return $true
    }
    $pattern = "*-$Id-patched-update"
    $dirs = @(Get-ChildItem -LiteralPath $state.Paths.Staging -Directory -Filter $pattern -ErrorAction SilentlyContinue)
    foreach ($dir in $dirs) {
      $manifestPath = Join-Path $dir.FullName 'manifest.json'
      if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        continue
      }
      $manifest = Read-GuardJsonFile -Path $manifestPath
      $reason = if ($manifest -and $manifest.Reason) { [string]$manifest.Reason } else { '' }
      $acquireReason = if ($manifest -and $manifest.Discovery -and $manifest.Discovery.Acquire -and $manifest.Discovery.Acquire.Reason) { [string]$manifest.Discovery.Acquire.Reason } else { '' }
      if ($reason -eq 'store_offline_authorization_required' -or $acquireReason -eq 'store_offline_authorization_required') {
        return $true
      }
    }
    return $false
  }

  function Write-StoreOfflineAuthorizationWaitNotification {
    param([Parameter(Mandatory = $true)][string]$Id)
    $text = @(
      "Codex Desktop Guard is waiting for an external Codex Desktop update payload.",
      "Event: $Id",
      "Status: needs_update_source",
      "Reason: store_offline_authorization_required",
      "",
      "This event already hit the Microsoft Store offline distribution / Microsoft Entra ID authorization boundary.",
      "The scheduled guard will not repeat the same winget download while incoming has no payload.",
      "",
      "Use a clean Windows / VM / another user environment to install official Codex Desktop, export the official package payload, then import it here:",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptRoot\import-codex-update-payload.ps1`" -PayloadZip <codex-payload.zip>",
      "",
      "No patch was applied and no Desktop process was stopped."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "NEEDS_UPDATE_SOURCE-$Id.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'NEEDS_UPDATE_SOURCE.txt' -Content $text | Out-Null
    Write-GuardNotification -State $state -Name "STORE_OFFLINE_AUTHORIZATION_REQUIRED-$Id.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'STORE_OFFLINE_AUTHORIZATION_REQUIRED.txt' -Content $text | Out-Null
    Remove-Item -LiteralPath (Join-Path $state.Paths.Notifications 'PREPARE_FAILED.txt') -Force -ErrorAction SilentlyContinue
  }

  if ((Test-StoreOfflineAuthorizationRequiredForEvent -Id $EventId) -and -not (Test-IncomingPayloadCandidate)) {
    Write-GuardUtf8NoBom -Path $lastPreparedPath -Content $EventId
    Write-StoreOfflineAuthorizationWaitNotification -Id $EventId
    Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update source previously hit Store offline authorization; waiting for sidecar/imported payload for event: $EventId"
    return
  }

  if ([string]::IsNullOrWhiteSpace($EventPath)) {
    $EventPath = Join-Path $state.Paths.Logs ("event-$EventId.json")
  }
  if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
    $activityEvent = [pscustomobject]@{
      SchemaVersion = 1
      Kind = 'update_activity'
      EventId = $EventId
      CreatedAt = (Get-Date).ToString('o')
      StateRoot = $state.Paths.Root
      ChangeCount = 0
      Changes = @()
      BaselineSnapshot = $baseline
      CurrentSnapshot = $Snapshot
    }
    Write-GuardJsonFile -Path $EventPath -Value $activityEvent
    Add-GuardJsonLine -Path $eventLogPath -Value ([pscustomobject]@{
      EventId = $EventId
      CreatedAt = $activityEvent.CreatedAt
      Kind = 'update_activity'
      ChangeCount = 0
      ChangedFields = @()
      EventPath = $EventPath
    })
  }

  if ($NoPrepare) {
    Write-GuardLog -State $state -LogName 'watch.log' -Message "NoPrepare set; patched-update prepare skipped for event: $EventId"
    return
  }
  if ($lastPreparedEventId -eq $EventId) {
    $previousManifest = Get-LatestPatchedUpdateManifestForEvent -Id $EventId
    $previousStatus = if ($previousManifest) { [string]$previousManifest.Status } else { '' }
    $previousReason = if ($previousManifest -and $previousManifest.Reason) { [string]$previousManifest.Reason } else { '' }
    if ($previousStatus -eq 'needs_update_source' -and $previousReason -eq 'store_offline_authorization_required') {
      Write-StoreOfflineAuthorizationWaitNotification -Id $EventId
      Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update source requires Store offline authorization; waiting for sidecar/imported payload for event: $EventId"
      return
    } elseif ($previousStatus -in @('waiting_for_update_payload', 'needs_update_source') -or [string]::IsNullOrWhiteSpace($previousStatus)) {
      Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update source/payload still not ready; retrying acquisition and discovery for event: $EventId"
    } else {
      Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update prepare already reached terminal status '$previousStatus' for event: $EventId"
      return
    }
  }

  $prepareScript = Join-Path $ScriptRoot 'prepare-patched-update.ps1'
  if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
    throw "patched-update prepare script not found: $prepareScript"
  }
  Write-GuardLog -State $state -LogName 'watch.log' -Message "starting patched-update prepare for event: $EventId"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $prepareScript -StateRoot $state.Paths.Root -EventPath $EventPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "patched-update prepare failed with exit code $LASTEXITCODE"
  }
  $latestManifest = Get-LatestPatchedUpdateManifestForEvent -Id $EventId
  $latestStatus = if ($latestManifest) { [string]$latestManifest.Status } else { '' }
  $latestReason = if ($latestManifest -and $latestManifest.Reason) { [string]$latestManifest.Reason } else { '' }
  if ($latestStatus -eq 'needs_update_source' -and $latestReason -eq 'store_offline_authorization_required') {
    Write-GuardUtf8NoBom -Path $lastPreparedPath -Content $EventId
    Write-StoreOfflineAuthorizationWaitNotification -Id $EventId
    Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update source requires Store offline authorization; future watches will wait for sidecar/imported payload for event: $EventId"
  } elseif ($latestStatus -in @('waiting_for_update_payload', 'needs_update_source')) {
    Remove-Item -LiteralPath $lastPreparedPath -Force -ErrorAction SilentlyContinue
    Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update prepare still needs source/payload; future watches will retry event: $EventId"
  } else {
    Write-GuardUtf8NoBom -Path $lastPreparedPath -Content $EventId
    Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update prepare complete for event: $EventId; status: $latestStatus"
  }
}

Write-GuardLog -State $state -LogName 'watch.log' -Message "watch started; state root: $($state.Paths.Root)"
$snapshot = Get-GuardSnapshot
$baseline = Read-GuardJsonFile -Path $baselinePath

if (-not $baseline) {
  Write-GuardJsonFile -Path $baselinePath -Value $snapshot
  Write-GuardLog -State $state -LogName 'watch.log' -Message 'baseline initialized; no prepare triggered on first run'
  Write-GuardNotification -State $state -Name 'BASELINE.txt' -Content "Codex Desktop Guard baseline initialized at $($snapshot.CreatedAt).`r`nNo prepare was triggered on the first run." -NotifyMsg:$NotifyMsg | Out-Null
  return
}

$changes = @(Compare-GuardSnapshots -Baseline $baseline -Current $snapshot)
if ($changes.Count -eq 0) {
  if ($snapshot.UpdateSignals -and $snapshot.UpdateSignals.HasCodexUpdateActivity) {
    $updateActivityEventId = New-GuardUpdateActivityEventId -Snapshot $snapshot
    $activityText = New-GuardUpdateActivityText -Snapshot $snapshot
    Write-GuardNotification -State $state -Name 'UPDATE_ACTIVITY.txt' -Content $activityText | Out-Null
    try {
      Invoke-GuardPrepareUpdateActivity -EventId $updateActivityEventId -Snapshot $snapshot
    } catch {
      $failureText = @(
        "Codex Desktop Guard update-activity prepare failed.",
        "Event: $updateActivityEventId",
        "Error: $($_.Exception.Message)",
        "",
        "The guard did not apply any patch. Inspect logs under:",
        $state.Paths.Logs
      ) -join "`r`n"
      Write-GuardNotification -State $state -Name "PREPARE_FAILED-$updateActivityEventId.txt" -Content $failureText | Out-Null
      Write-GuardNotification -State $state -Name 'PREPARE_FAILED.txt' -Content $failureText | Out-Null
      Write-GuardLog -State $state -LogName 'watch.log' -Message "update-activity prepare failed for event ${updateActivityEventId}: $($_.Exception.Message)"
      throw
    }
    Write-GuardLog -State $state -LogName 'watch.log' -Message "no watched Codex Desktop changes detected; active update marker refreshed for event: $updateActivityEventId"
  } else {
    Write-GuardLog -State $state -LogName 'watch.log' -Message 'no watched Codex Desktop changes detected'
  }
  return
}

$updateSignalNames = @('codex_windowsapps_dir_signature', 'appx_codex_event_signature', 'bits_codex_transfer_signature', 'doctor_update_signature')
$onlyUpdateSignals = (($changes | Where-Object { $updateSignalNames -notcontains $_.Name } | Measure-Object).Count -eq 0)
$installedPackageChangeNames = @(
  'package_full_name',
  'package_version',
  'package_signature_kind',
  'install_location',
  'resources_codex_exe_sha256',
  'resources_codex_exe_length',
  'resources_app_asar_sha256',
  'resources_app_asar_length',
  'local_cli_path',
  'local_cli_sha256',
  'local_cli_version'
)
$configChangeNames = @('codex_config_toml_sha256', 'codex_config_toml_length')
$hasInstalledPackageOrResourceChange = (($changes | Where-Object { $installedPackageChangeNames -contains $_.Name } | Measure-Object).Count -gt 0)
$hasConfigOnlyChange = (
  (($changes | Where-Object { $configChangeNames -contains $_.Name } | Measure-Object).Count -gt 0) -and
  (($changes | Where-Object { ($configChangeNames + $updateSignalNames) -notcontains $_.Name } | Measure-Object).Count -eq 0)
)

$eventId = New-GuardEventId -Changes $changes -Snapshot $snapshot
$event = [pscustomobject]@{
  SchemaVersion = 1
  EventId = $eventId
  CreatedAt = (Get-Date).ToString('o')
  StateRoot = $state.Paths.Root
  ChangeCount = $changes.Count
  Changes = $changes
  BaselineSnapshot = $baseline
  CurrentSnapshot = $snapshot
}

$eventPath = Join-Path $state.Paths.Logs ("event-$eventId.json")
$lastEventPath = Join-Path $state.Paths.Baselines 'last-event-id.txt'
$lastEventId = if (Test-Path -LiteralPath $lastEventPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $lastEventPath).Trim() } else { '' }

Write-GuardJsonFile -Path $eventPath -Value $event
Add-GuardJsonLine -Path $eventLogPath -Value ([pscustomobject]@{
  EventId = $eventId
  CreatedAt = $event.CreatedAt
  ChangeCount = $changes.Count
  ChangedFields = @($changes | ForEach-Object { $_.Name })
  EventPath = $eventPath
})

Write-GuardLog -State $state -LogName 'watch.log' -Message "detected $($changes.Count) watched changes; event: $eventId"

try {
  if ($lastEventId -eq $eventId) {
    Write-GuardLog -State $state -LogName 'watch.log' -Message "event already handled by previous watch run: $eventId"
  } elseif ($onlyUpdateSignals) {
    if ($snapshot.UpdateSignals -and $snapshot.UpdateSignals.HasCodexUpdateActivity) {
      $activityText = New-GuardUpdateActivityText -Snapshot $snapshot -EventId $eventId
      Write-GuardNotification -State $state -Name "UPDATE_ACTIVITY-$eventId.txt" -Content $activityText -NotifyMsg:$NotifyMsg | Out-Null
      Write-GuardNotification -State $state -Name 'UPDATE_ACTIVITY.txt' -Content $activityText | Out-Null
      Write-GuardLog -State $state -LogName 'watch.log' -Message "Codex-related update activity detected for event: $eventId"
      Invoke-GuardPrepareUpdateActivity -EventId $eventId -EventPath $eventPath -Snapshot $snapshot
    } else {
      Write-GuardLog -State $state -LogName 'watch.log' -Message "update-signal baseline refreshed without Codex update activity: $eventId"
    }
  } elseif ($hasConfigOnlyChange -and -not $hasInstalledPackageOrResourceChange) {
    $summary = @(
      "Codex Desktop Guard detected a Desktop config hash change.",
      "Event: $eventId",
      "Package: $(Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.PackageFullName')",
      "Changed fields:",
      (($changes | ForEach-Object { "  - $($_.Name)" }) -join "`r`n"),
      "",
      "Only config metadata changed. The guard recorded hash/length/timestamp only and did not read config.toml contents.",
      "No native replacement build was started for this config-only event."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "CONFIG_CHANGE-$eventId.txt" -Content $summary -NotifyMsg:$NotifyMsg | Out-Null
    Write-GuardNotification -State $state -Name 'CONFIG_CHANGE.txt' -Content $summary -NotifyMsg:$false | Out-Null
    Write-GuardLog -State $state -LogName 'watch.log' -Message "config-only change recorded without installed-change prepare: $eventId"
    if ($snapshot.UpdateSignals -and $snapshot.UpdateSignals.HasCodexUpdateActivity) {
      if ($NoPrepare) {
        Write-GuardLog -State $state -LogName 'watch.log' -Message "NoPrepare set; active update activity check skipped after config-only change: $eventId"
      } else {
        $activityEventId = New-GuardUpdateActivityEventId -Snapshot $snapshot
        $activityText = New-GuardUpdateActivityText -Snapshot $snapshot -EventId $activityEventId
        Write-GuardNotification -State $state -Name 'UPDATE_ACTIVITY.txt' -Content $activityText | Out-Null
        Write-GuardLog -State $state -LogName 'watch.log' -Message "active update activity still present after config-only change; checking patched-update event: $activityEventId"
        Invoke-GuardPrepareUpdateActivity -EventId $activityEventId -Snapshot $snapshot
      }
    }
  } elseif ($NoPrepare) {
    $summary = @(
      "Codex Desktop Guard detected a watched change.",
      "Event: $eventId",
      "Package: $(Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.PackageFullName')",
      "Changed fields:",
      (($changes | ForEach-Object { "  - $($_.Name)" }) -join "`r`n"),
      "",
      "NoPrepare was set, so no staging was prepared."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "CHANGE-$eventId.txt" -Content $summary -NotifyMsg:$NotifyMsg | Out-Null
    Write-GuardNotification -State $state -Name 'CHANGE.txt' -Content $summary -NotifyMsg:$false | Out-Null
    Write-GuardLog -State $state -LogName 'watch.log' -Message "NoPrepare set; prepare skipped for event: $eventId"
  } else {
    $summary = @(
      "Codex Desktop Guard detected a watched package/resource change.",
      "Event: $eventId",
      "Package: $(Resolve-GuardPropertyPath -Object $snapshot -Path 'Package.PackageFullName')",
      "Changed fields:",
      (($changes | ForEach-Object { "  - $($_.Name)" }) -join "`r`n"),
      "",
      "The guard will prepare staging only. It will not apply a patch."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "CHANGE-$eventId.txt" -Content $summary -NotifyMsg:$NotifyMsg | Out-Null
    Write-GuardNotification -State $state -Name 'CHANGE.txt' -Content $summary -NotifyMsg:$false | Out-Null
    $prepareScript = Join-Path $ScriptRoot 'prepare-fast-patch.ps1'
    if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
      throw "prepare script not found: $prepareScript"
    }
    Write-GuardLog -State $state -LogName 'watch.log' -Message "starting prepare for event: $eventId"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $prepareScript -StateRoot $state.Paths.Root -EventPath $eventPath
    if ($LASTEXITCODE -ne 0) {
      throw "prepare failed with exit code $LASTEXITCODE"
    }
  }
} catch {
  $failureText = @(
    "Codex Desktop Guard prepare failed.",
    "Event: $eventId",
    "Error: $($_.Exception.Message)",
    "",
    "The guard did not apply any patch. Inspect logs under:",
    $state.Paths.Logs
  ) -join "`r`n"
  Write-GuardNotification -State $state -Name "PREPARE_FAILED-$eventId.txt" -Content $failureText | Out-Null
  Write-GuardNotification -State $state -Name 'PREPARE_FAILED.txt' -Content $failureText | Out-Null
  Write-GuardLog -State $state -LogName 'watch.log' -Message "prepare failed for event ${eventId}: $($_.Exception.Message)"
  throw
} finally {
  Write-GuardUtf8NoBom -Path $lastEventPath -Content $eventId
  Write-GuardJsonFile -Path $baselinePath -Value $snapshot
  Write-GuardLog -State $state -LogName 'watch.log' -Message "baseline updated after event: $eventId"
}
