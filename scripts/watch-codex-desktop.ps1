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
    "If this update/download activity is new, the guard now runs update payload discovery. It writes WAITING_FOR_UPDATE_PAYLOAD when no usable payload is available, or PATCHED_UPDATE_READY when a patched update package is staged."
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
    Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update prepare already handled: $EventId"
    return
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
  Write-GuardUtf8NoBom -Path $lastPreparedPath -Content $EventId
  Write-GuardLog -State $state -LogName 'watch.log' -Message "patched-update prepare complete for event: $EventId"
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
