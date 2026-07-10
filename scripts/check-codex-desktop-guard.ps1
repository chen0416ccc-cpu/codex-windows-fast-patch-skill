[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$TaskName = 'Codex Desktop Guard',
  [ValidateRange(0, 60)][int]$TailLines = 20,
  [switch]$Json,
  [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$paths = New-GuardDirectorySet -StateRoot $StateRoot
$guardState = [pscustomobject]@{
  Paths = $paths
}

function ConvertTo-GuardCheckSingleLine {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) {
    return ''
  }
  return (([string]$Text) -replace "`0", '' -replace '\s+', ' ').Trim()
}

function Get-GuardCheckTaskStatus {
  param([string]$Name)
  $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if (-not $task) {
    return [pscustomobject]@{
      Installed = $false
      Enabled = $false
      State = 'not_installed'
      TaskName = $Name
      TaskPath = $null
      LastRunTime = $null
      LastTaskResult = $null
      NextRunTime = $null
      NumberOfMissedRuns = $null
      Execute = $null
      Arguments = $null
      WorkingDirectory = $null
    }
  }

  $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
  $enabled = $false
  foreach ($trigger in @($task.Triggers)) {
    if ($trigger.Enabled) {
      $enabled = $true
      break
    }
  }
  $action = @($task.Actions) | Select-Object -First 1
  return [pscustomobject]@{
    Installed = $true
    Enabled = $enabled
    State = [string]$task.State
    TaskName = [string]$task.TaskName
    TaskPath = [string]$task.TaskPath
    LastRunTime = if ($info) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
    LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
    NextRunTime = if ($info) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
    NumberOfMissedRuns = if ($info) { $info.NumberOfMissedRuns } else { $null }
    Execute = if ($action) { [string]$action.Execute } else { $null }
    Arguments = if ($action) { [string]$action.Arguments } else { $null }
    WorkingDirectory = if ($action) { [string]$action.WorkingDirectory } else { $null }
  }
}

function Get-GuardCheckRecentLog {
  param([int]$LineCount)
  $watchLog = Join-Path $paths.Logs 'watch.log'
  if ($LineCount -le 0 -or -not (Test-Path -LiteralPath $watchLog -PathType Leaf)) {
    return @()
  }
  return @(Get-Content -LiteralPath $watchLog -Tail $LineCount | ForEach-Object {
    ConvertTo-GuardCheckSingleLine -Text $_
  })
}

function Get-GuardCheckLatestNotification {
  if (-not (Test-Path -LiteralPath $paths.Notifications -PathType Container)) {
    return $null
  }
  $item = Get-ChildItem -LiteralPath $paths.Notifications -File -Filter '*.txt' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
  if (-not $item) {
    return $null
  }
  return [pscustomobject]@{
    Name = $item.Name
    Path = $item.FullName
    LastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
  }
}

function Get-GuardCheckNotificationNames {
  if (-not (Test-Path -LiteralPath $paths.Notifications -PathType Container)) {
    return @()
  }
  return @(Get-ChildItem -LiteralPath $paths.Notifications -File -Filter '*.txt' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 20 -ExpandProperty Name)
}

function Get-GuardCheckNotificationText {
  param([string]$Name)
  $path = Join-Path $paths.Notifications $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }
  return Get-Content -Raw -LiteralPath $path
}

function Get-GuardCheckLatestStagingManifest {
  if (-not (Test-Path -LiteralPath $paths.Staging -PathType Container)) {
    return $null
  }
  $manifest = Get-ChildItem -LiteralPath $paths.Staging -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
      $candidate = Join-Path $_.FullName 'manifest.json'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
      }
    } |
    Where-Object { $null -ne $_ } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
  if (-not $manifest) {
    return $null
  }
  $value = Read-GuardJsonFile -Path $manifest.FullName
  if (-not $value) {
    return $null
  }
  return [pscustomobject]@{
    Path = $manifest.FullName
    LastWriteTime = $manifest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    Status = if ($value.Status) { [string]$value.Status } else { $null }
    Reason = if ($value.Reason) { [string]$value.Reason } else { $null }
    EventId = if ($value.EventId) { [string]$value.EventId } else { $null }
    Mode = if ($value.Mode) { [string]$value.Mode } else { $null }
    ApplyCommand = if ($value.ApplyCommand) { [string]$value.ApplyCommand } else { $null }
    StagingDir = if ($value.StagingDir) { [string]$value.StagingDir } else { Split-Path -Parent $manifest.FullName }
  }
}

function Get-GuardCheckReadyManifest {
  $candidates = @(
    @{ Marker = 'PATCHED_UPDATE_READY'; State = 'patched_update_ready' },
    @{ Marker = 'READY'; State = 'ready' },
    @{ Marker = 'CURRENT_VERSION_READY'; State = 'current_version_ready' }
  )
  if (-not (Test-Path -LiteralPath $paths.Staging -PathType Container)) {
    return $null
  }
  $matches = New-Object System.Collections.Generic.List[object]
  $stagingDirs = @(Get-ChildItem -LiteralPath $paths.Staging -Directory -ErrorAction SilentlyContinue)
  foreach ($candidate in $candidates) {
    foreach ($dir in $stagingDirs) {
      $markerPath = Join-Path $dir.FullName $candidate.Marker
      if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        continue
      }
      $manifestPath = Join-Path $dir.FullName 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
          $manifest = Read-GuardJsonFile -Path $manifestPath
          $matches.Add([pscustomobject]@{
            State = $candidate.State
            Marker = $markerPath
            MarkerTimeUtc = (Get-Item -LiteralPath $markerPath).LastWriteTimeUtc
            ManifestPath = $manifestPath
            Manifest = $manifest
          })
        }
    }
  }
  $latest = $matches | Sort-Object MarkerTimeUtc -Descending | Select-Object -First 1
  if (-not $latest) {
    return $null
  }
  return [pscustomobject]@{
    State = $latest.State
    Marker = $latest.Marker
    ManifestPath = $latest.ManifestPath
    EventId = if ($latest.Manifest.EventId) { [string]$latest.Manifest.EventId } else { $null }
    Status = if ($latest.Manifest.Status) { [string]$latest.Manifest.Status } else { $null }
    ApplyCommand = if ($latest.Manifest.ApplyCommand) { [string]$latest.Manifest.ApplyCommand } else { $null }
    StagingDir = if ($latest.Manifest.StagingDir) { [string]$latest.Manifest.StagingDir } else { Split-Path -Parent $latest.ManifestPath }
  }
}

function Get-GuardCheckPreferredManifestData {
  param(
    [AllowNull()][object]$ReadyManifest,
    [AllowNull()][object]$LatestManifest
  )
  $manifestPath = if ($ReadyManifest -and $ReadyManifest.ManifestPath) {
    [string]$ReadyManifest.ManifestPath
  } elseif ($LatestManifest -and $LatestManifest.Path) {
    [string]$LatestManifest.Path
  } else {
    $null
  }
  if ([string]::IsNullOrWhiteSpace($manifestPath)) {
    return $null
  }
  return Read-GuardJsonFile -Path $manifestPath
}

function Get-GuardCheckCurrentStep {
  param(
    [Parameter(Mandatory = $true)][string]$State,
    [AllowNull()][object]$ManifestData,
    [int]$DesktopProcessCount
  )
  if ($State -eq 'patched_update_ready') {
    if ($DesktopProcessCount -gt 0) {
      return 'waiting_for_restart'
    }
    return 'ready_to_apply'
  }
  switch ($State) {
    'waiting_for_raw_package_source' { return 'acquiring_raw_package' }
    'waiting_for_update_payload' { return 'discovering_update_candidate' }
    'watching' { return 'watching_for_update_activity' }
    'prepare_failed' { return 'prepare_failed' }
    'needs_action' { return 'manual_intervention_required' }
    'config_change_only' { return 'config_change_only' }
    'idle' { return 'idle' }
    default {
      $status = Resolve-GuardPropertyPath -Object $ManifestData -Path 'Status'
      if (-not [string]::IsNullOrWhiteSpace([string]$status)) {
        return [string]$status
      }
      return $State
    }
  }
}

function Get-GuardCheckLastErrorSummary {
  param(
    [AllowNull()][object]$ManifestData,
    [AllowNull()][string]$LatestNotificationText
  )
  $status = [string](Resolve-GuardPropertyPath -Object $ManifestData -Path 'Status')
  $reason = [string](Resolve-GuardPropertyPath -Object $ManifestData -Path 'Reason')
  $details = @(Resolve-GuardPropertyPath -Object $ManifestData -Path 'Details')
  if ($status -in @('prepare_failed', 'needs_action', 'needs_update_source', 'waiting_for_update_payload', 'needs_update_payload')) {
    $firstDetail = @($details | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
    if ($firstDetail.Count -gt 0) {
      return [string]$firstDetail[0]
    }
    if (-not [string]::IsNullOrWhiteSpace($reason)) {
      return $reason
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($LatestNotificationText)) {
    $line = @(
      $LatestNotificationText -split "`r?`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
      return [string]$line
    }
  }
  return $null
}

function Get-GuardCheckIncomingCount {
  if (-not (Test-Path -LiteralPath $paths.Incoming -PathType Container)) {
    return 0
  }
  return @(
    Get-ChildItem -LiteralPath $paths.Incoming -Recurse -File -Filter 'AppxManifest.xml' -ErrorAction SilentlyContinue
  ).Count
}

function Get-GuardCheckDesktopProcessCount {
  return @(
    Get-CimInstance Win32_Process -Filter "Name = 'Codex.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like '*\OpenAI.Codex_*' }
  ).Count
}

function Resolve-GuardCheckState {
  param(
    [object]$Task,
    [string[]]$NotificationNames,
    [object]$ReadyManifest,
    [object]$LatestManifest,
    [string[]]$RecentLog,
    [object]$MirrorSettings
  )
  if (-not $Task.Installed) {
    return [pscustomobject]@{
      State = 'not_installed'
      Reason = 'scheduled_task_missing'
      EventId = $null
      UserAction = 'Install the guard task when you want periodic watch.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($ReadyManifest -and $ReadyManifest.State -eq 'patched_update_ready') {
    return [pscustomobject]@{
      State = 'patched_update_ready'
      Reason = 'patched_update_ready'
      EventId = $ReadyManifest.EventId
      UserAction = 'Close Codex Desktop, then run the apply command from external PowerShell or VS Code Codex.'
      Safe = $true
      ApplyPending = $true
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'NEEDS_ACTION.txt') {
    return [pscustomobject]@{
      State = 'needs_action'
      Reason = 'needs_action_marker'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = 'Open NEEDS_ACTION.txt and resolve the manual version/payload mapping request.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'STORE_OFFLINE_AUTHORIZATION_REQUIRED.txt') {
    return [pscustomobject]@{
      State = $(if ($MirrorSettings.Enabled) { 'waiting_for_raw_package_source' } else { 'waiting_for_external_payload' })
      Reason = 'store_offline_authorization_required'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = $(if ($MirrorSettings.Enabled) { 'A configured mirror raw-package source is available; rerun watch now or wait for the next scheduled retry.' } else { 'Configure an authorized mirror that serves the official raw MSIX/MSIXBundle package, then rerun the guard.' })
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'NEEDS_UPDATE_SOURCE.txt') {
    return [pscustomobject]@{
      State = $(if ($MirrorSettings.Enabled) { 'waiting_for_raw_package_source' } else { 'waiting_for_external_payload' })
      Reason = 'needs_update_source'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = $(if ($MirrorSettings.Enabled) { 'Inspect the configured mirror raw-package source or rerun watch after the mirror is reachable.' } else { 'Configure an authorized mirror that serves the official raw MSIX/MSIXBundle package.' })
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'WAITING_FOR_UPDATE_PAYLOAD.txt') {
    return [pscustomobject]@{
      State = 'waiting_for_update_payload'
      Reason = 'waiting_for_update_payload'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = 'Wait for the guard to acquire a usable raw official package, or rerun watch after the mirror/source is reachable.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'PREPARE_FAILED.txt') {
    return [pscustomobject]@{
      State = 'prepare_failed'
      Reason = 'prepare_failed_marker'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = 'Inspect the event-specific PREPARE_FAILED file and staging verification log.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($ReadyManifest -and $ReadyManifest.State -eq 'current_version_ready') {
    return [pscustomobject]@{
      State = 'current_version_ready'
      Reason = 'current_version_ready'
      EventId = $ReadyManifest.EventId
      UserAction = 'Use only as same-version protection after closing Codex Desktop from an external executor.'
      Safe = $true
      ApplyPending = $true
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'CONFIG_CHANGE.txt') {
    return [pscustomobject]@{
      State = 'config_change_only'
      Reason = 'config_change_only'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = 'No action needed for config-only changes.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($NotificationNames -contains 'UPDATE_ACTIVITY.txt') {
    return [pscustomobject]@{
      State = 'watching'
      Reason = 'update_activity_marker'
      EventId = if ($LatestManifest) { $LatestManifest.EventId } else { $null }
      UserAction = 'Keep the guard enabled and watch for PATCHED_UPDATE_READY or NEEDS_UPDATE_SOURCE.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  if ($Task.Enabled) {
    return [pscustomobject]@{
      State = 'idle'
      Reason = 'task_enabled_no_action_marker'
      EventId = $null
      UserAction = 'No action needed.'
      Safe = $true
      ApplyPending = $false
      DesktopTouched = $false
    }
  }
  return [pscustomobject]@{
    State = 'unknown'
    Reason = 'no_recognized_marker'
    EventId = $null
    UserAction = 'Inspect notifications and watch.log.'
    Safe = $true
    ApplyPending = $false
    DesktopTouched = $false
  }
}

function Format-GuardCheckValue {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return 'none'
  }
  return [string]$Value
}

function Write-GuardCheckText {
  param([Parameter(Mandatory = $true)][object]$Report)

  Write-Host 'Codex Desktop Guard Status'
  Write-Host ''
  Write-Host 'Task:'
  Write-Host ("  Installed: {0}" -f ($(if ($Report.Task.Installed) { 'yes' } else { 'no' })))
  Write-Host ("  Enabled: {0}" -f ($(if ($Report.Task.Enabled) { 'yes' } else { 'no' })))
  Write-Host ("  State: {0}" -f (Format-GuardCheckValue $Report.Task.State))
  Write-Host ("  Last run: {0}" -f (Format-GuardCheckValue $Report.Task.LastRunTime))
  Write-Host ("  Next run: {0}" -f (Format-GuardCheckValue $Report.Task.NextRunTime))
  Write-Host ("  Last result: {0}" -f (Format-GuardCheckValue $Report.Task.LastTaskResult))
  Write-Host ''
  Write-Host 'Current guard state:'
  Write-Host ("  State: {0}" -f $Report.State)
  Write-Host ("  Event: {0}" -f (Format-GuardCheckValue $Report.EventId))
  Write-Host ("  Reason: {0}" -f (Format-GuardCheckValue $Report.Reason))
  Write-Host ("  Safe: {0}" -f ($(if ($Report.Safe) { 'yes' } else { 'no' })))
  Write-Host ("  Desktop touched: {0}" -f ($(if ($Report.DesktopTouched) { 'yes' } else { 'no' })))
  Write-Host ("  Apply pending: {0}" -f ($(if ($Report.ApplyPending) { 'yes' } else { 'no' })))
  Write-Host ("  Desktop process count: {0}" -f $Report.DesktopProcessCount)
  Write-Host ("  Incoming payload candidates: {0}" -f $Report.IncomingPayloadCandidateCount)
  Write-Host ("  Mirror source enabled: {0}" -f ($(if ($Report.MirrorSourceEnabled) { 'yes' } else { 'no' })))
  if ($Report.MirrorPackageUrl) {
    Write-Host ("  Mirror package URL: {0}" -f $Report.MirrorPackageUrl)
  }
  Write-Host ''
  Write-Host 'Latest notification:'
  if ($Report.LatestNotification) {
    Write-Host ("  {0}" -f $Report.LatestNotification.Name)
    Write-Host ("  {0}" -f $Report.LatestNotification.Path)
  } else {
    Write-Host '  none'
  }
  Write-Host ''
  Write-Host 'User action:'
  Write-Host ("  {0}" -f $Report.UserAction)
  if ($Report.ApplyCommand) {
    Write-Host ''
    Write-Host 'Apply command:'
    Write-Host ("  {0}" -f $Report.ApplyCommand)
  }
  if (-not $NoLog) {
    Write-Host ''
    Write-Host 'Recent watch log:'
    if ($Report.RecentLog.Count -eq 0) {
      Write-Host '  none'
    } else {
      foreach ($line in $Report.RecentLog) {
        Write-Host ("  {0}" -f $line)
      }
    }
  }
}

$task = Get-GuardCheckTaskStatus -Name $TaskName
$notificationNames = Get-GuardCheckNotificationNames
$latestNotification = Get-GuardCheckLatestNotification
$readyManifest = Get-GuardCheckReadyManifest
$latestManifest = Get-GuardCheckLatestStagingManifest
$recentLog = if ($NoLog) { @() } else { Get-GuardCheckRecentLog -LineCount $TailLines }
$mirrorSettings = Get-GuardMirrorFallbackSettings -State $guardState
$state = Resolve-GuardCheckState -Task $task -NotificationNames $notificationNames -ReadyManifest $readyManifest -LatestManifest $latestManifest -RecentLog $recentLog -MirrorSettings $mirrorSettings
$desktopProcessCount = Get-GuardCheckDesktopProcessCount
$incomingCount = Get-GuardCheckIncomingCount
$latestNotificationText = if ($latestNotification) { Get-GuardCheckNotificationText -Name $latestNotification.Name } else { $null }
$manifestData = Get-GuardCheckPreferredManifestData -ReadyManifest $readyManifest -LatestManifest $latestManifest
$currentPackageVersion = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Snapshot.Package.Version')
if ([string]::IsNullOrWhiteSpace($currentPackageVersion)) {
  $currentPackageVersion = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Discovery.CurrentPackageVersion')
}
$candidateUpdateVersion = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Payload.PackageVersion')
if ([string]::IsNullOrWhiteSpace($candidateUpdateVersion)) {
  $candidateUpdateVersion = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Discovery.SelectedPayload.PackageVersion')
}
$updateSource = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Discovery.Acquire.MirrorLabel')
if (-not [string]::IsNullOrWhiteSpace($updateSource)) {
  $mirrorUrl = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Discovery.Acquire.MirrorPackageUrl')
  if (-not [string]::IsNullOrWhiteSpace($mirrorUrl)) {
    $updateSource = "$updateSource ($mirrorUrl)"
  }
} else {
  $updateSource = [string](Resolve-GuardPropertyPath -Object $manifestData -Path 'Discovery.Acquire.Source')
}
if ([string]::IsNullOrWhiteSpace($updateSource) -and $mirrorSettings.Enabled -and -not [string]::IsNullOrWhiteSpace($mirrorSettings.Label)) {
  $updateSource = [string]$mirrorSettings.Label
}
$currentStep = Get-GuardCheckCurrentStep -State $state.State -ManifestData $manifestData -DesktopProcessCount $desktopProcessCount
$needsAction = ($state.State -in @('needs_action', 'prepare_failed')) -or ($currentStep -in @('waiting_for_restart', 'ready_to_apply'))
$lastErrorSummary = Get-GuardCheckLastErrorSummary -ManifestData $manifestData -LatestNotificationText $latestNotificationText
$applyCommand = if ($readyManifest -and $readyManifest.ApplyCommand -and $state.ApplyPending) {
  [string]$readyManifest.ApplyCommand
} elseif ($latestManifest -and $latestManifest.ApplyCommand -and $state.ApplyPending) {
  [string]$latestManifest.ApplyCommand
} else {
  $null
}

$report = [pscustomobject]@{
  SchemaVersion = 1
  CheckedAt = (Get-Date).ToString('o')
  StateRoot = $paths.Root
  State = $state.State
  Reason = $state.Reason
  Step = $currentStep
  EventId = $state.EventId
  Safe = [bool]$state.Safe
  NeedsAction = [bool]$needsAction
  DesktopTouched = [bool]$state.DesktopTouched
  ApplyPending = [bool]$state.ApplyPending
  UserAction = $state.UserAction
  CurrentPackageVersion = $currentPackageVersion
  CandidateUpdateVersion = $candidateUpdateVersion
  UpdateSource = $updateSource
  LastErrorSummary = $lastErrorSummary
  Task = $task
  DesktopProcessCount = $desktopProcessCount
  IncomingPayloadCandidateCount = $incomingCount
  LatestNotification = $latestNotification
  LatestNotificationText = $latestNotificationText
  NotificationNames = $notificationNames
  LatestManifest = $latestManifest
  ReadyManifest = $readyManifest
  ApplyCommand = $applyCommand
  MirrorSourceEnabled = [bool]$mirrorSettings.Enabled
  MirrorPackageUrl = $mirrorSettings.PackageUrl
  MirrorLabel = $mirrorSettings.Label
  OpenLogsPath = $paths.Logs
  OpenStagingPath = if ($readyManifest -and $readyManifest.StagingDir) { [string]$readyManifest.StagingDir } elseif ($latestManifest -and $latestManifest.StagingDir) { [string]$latestManifest.StagingDir } else { $paths.Staging }
  RunStatePath = (Join-Path $paths.Root 'ui\last-run.json')
  Paths = $paths
  RecentLog = $recentLog
}

if ($Json) {
  $report | ConvertTo-Json -Depth 12
} else {
  Write-GuardCheckText -Report $report
}
