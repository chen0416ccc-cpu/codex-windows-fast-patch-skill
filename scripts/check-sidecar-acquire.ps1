[CmdletBinding()]
param(
  [string]$StateRoot,
  [ValidateRange(0, 60)][int]$TailLines = 60,
  [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$paths = New-GuardDirectorySet -StateRoot $StateRoot
$outputRoot = Join-Path $paths.Root 'sidecar-output'
$statusPath = Join-Path $outputRoot 'status.json'
$logPath = Join-Path $outputRoot 'sandbox-sidecar.log'
$payloadZip = Join-Path $outputRoot 'codex-payload.zip'

function Limit-SidecarText {
  param(
    [AllowNull()][string]$Text,
    [int]$MaxLength = 1000
  )
  if ($null -eq $Text) {
    return $null
  }
  $value = ([string]$Text) -replace "`0", ''
  if ($value.Length -le $MaxLength) {
    return $value
  }
  return $value.Substring(0, $MaxLength) + '...'
}

function Get-RecentSidecarLog {
  param([int]$LineCount)
  if ($LineCount -le 0 -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    return @()
  }
  $tailCount = [int](@($LineCount)[0])
  return @(Get-Content -LiteralPath $logPath -Tail $tailCount | ForEach-Object {
    Limit-SidecarText -Text $_ -MaxLength 800
  })
}

function Get-LatestSidecarSessionLog {
  param([int]$LineCount)
  if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    return @()
  }
  [int]$safeLines = $LineCount
  if ($safeLines -lt 1) {
    $safeLines = 1
  }
  if ($safeLines -gt 60) {
    $safeLines = 60
  }
  $tailCount = [int](@($safeLines)[0])
  $logLines = @(Get-Content -LiteralPath $logPath -Tail $tailCount | ForEach-Object { ([string]$_) -replace "`0", '' })
  $startIndex = -1
  for ($i = 0; $i -lt $logLines.Count; $i++) {
    if ($logLines[$i] -match 'Codex Desktop sidecar sandbox started') {
      $startIndex = $i
    }
  }
  if ($startIndex -ge 0) {
    return @($logLines[$startIndex..($logLines.Count - 1)])
  }
  return $logLines
}

function Resolve-SidecarStateFromLog {
  param([string[]]$Lines)
  $joined = ($Lines -join "`n")
  if (Test-Path -LiteralPath $payloadZip -PathType Leaf) {
    return [pscustomobject]@{ state = 'ready'; step = 'payload_ready'; lastError = $null }
  }
  if ($joined -match 'READY:\s+') {
    return [pscustomobject]@{ state = 'ready'; step = 'payload_ready'; lastError = $null }
  }
  if ($joined -match 'NEEDS_ACTION') {
    return [pscustomobject]@{ state = 'needs_action'; step = 'needs_action'; lastError = 'NEEDS_ACTION marker found in sidecar log.' }
  }
  if ($joined -match 'winget\.exe is still not visible') {
    return [pscustomobject]@{ state = 'failed'; step = 'winget_not_visible'; lastError = 'App Installer bootstrap completed, but winget.exe is still not visible.' }
  }
  if ($joined -match 'App Installer bundle install failed') {
    return [pscustomobject]@{ state = 'failed'; step = 'appinstaller_install_failed'; lastError = 'App Installer bundle install failed.' }
  }
  if ($joined -match 'Windows App Runtime installer failed|Windows App Runtime install failed|Windows App Runtime 1\.8 was not visible') {
    return [pscustomobject]@{ state = 'failed'; step = 'windows_app_runtime_failed'; lastError = 'Windows App Runtime 1.8 bootstrap failed.' }
  }
  if ($joined -match 'Microsoft Store offline package download requires Microsoft Entra ID authorization|0x8A150076') {
    return [pscustomobject]@{ state = 'failed'; step = 'store_offline_authorization_required'; lastError = 'Microsoft Store offline package download requires Microsoft Entra ID authorization.' }
  }
  if ($joined -match 'Store offline download did not produce|winget download failed|winget download.*exit code:\s*(?!0\b)(-?\d+)') {
    return [pscustomobject]@{ state = 'failed'; step = 'store_download_failed'; lastError = 'Store offline download failed or produced no usable payload.' }
  }
  if ($joined -match 'Store install failed|winget install exit code:\s*(?!0\b)(\d+)') {
    return [pscustomobject]@{ state = 'failed'; step = 'store_install_failed'; lastError = 'Store install failed.' }
  }
  if ($joined -match 'Download failed') {
    return [pscustomobject]@{ state = 'failed'; step = 'download_failed'; lastError = 'A sidecar download failed.' }
  }
  if ($joined -match 'trust relationship|SSL/TLS secure channel|certificate validation failed|certificate chain') {
    return [pscustomobject]@{ state = 'failed'; step = 'tls_trust_failed'; lastError = 'Sandbox HTTPS failed TLS trust validation.' }
  }
  if ($joined -match 'Codex Desktop sidecar sandbox started') {
    return [pscustomobject]@{ state = 'running'; step = 'log_seen'; lastError = $null }
  }
  return [pscustomobject]@{ state = 'unknown'; step = 'no_status'; lastError = 'No status.json and no recognizable sidecar log session.' }
}

function ConvertTo-SidecarClassification {
  param([AllowNull()][string]$State)
  switch ([string]$State) {
    'ready' { 'READY'; break }
    'failed' { 'FAILED'; break }
    'needs_action' { 'NEEDS_ACTION'; break }
    'running' { 'RUNNING'; break }
    'starting' { 'RUNNING'; break }
    'stopped' { 'STOPPED'; break }
    'stop_failed' { 'FAILED'; break }
    default { 'UNKNOWN'; break }
  }
}

$statusReadError = $null
try {
  $status = Read-GuardJsonFile -Path $statusPath
} catch {
  $status = $null
  $statusReadError = Limit-SidecarText -Text $_.Exception.Message -MaxLength 1000
}
$latestSession = Get-LatestSidecarSessionLog -LineCount 60
$inferred = Resolve-SidecarStateFromLog -Lines $latestSession
$effective = if ($status) {
  [pscustomobject]@{
    state = [string]$status.state
    step = [string]$status.step
    lastError = [string]$status.lastError
  }
} else {
  $inferred
}

$sandboxProcesses = @(Get-Process WindowsSandbox, WindowsSandboxClient -ErrorAction SilentlyContinue |
  Select-Object ProcessName, Id, @{Name = 'StartTime'; Expression = { try { $_.StartTime.ToString('o') } catch { $null } } })
$payloadInfo = $null
if (Test-Path -LiteralPath $payloadZip -PathType Leaf) {
  $item = Get-Item -LiteralPath $payloadZip
  $payloadInfo = [pscustomobject]@{
    path = $item.FullName
    length = $item.Length
    lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
  }
}

[pscustomobject]@{
  schemaVersion = 1
  checkedAt = (Get-Date).ToString('o')
  state = $effective.state
  classification = ConvertTo-SidecarClassification -State $effective.state
  step = $effective.step
  lastError = $effective.lastError
  statusPath = $statusPath
  statusReadError = $statusReadError
  status = $status
  inferred = $inferred
  lastRun = $inferred
  lastRunClassification = ConvertTo-SidecarClassification -State $inferred.state
  outputRoot = $outputRoot
  logPath = $logPath
  payloadZip = $payloadZip
  payload = $payloadInfo
  sandboxProcesses = $sandboxProcesses
  recentLog = if ($NoLog) { @() } else { Get-RecentSidecarLog -LineCount $TailLines }
} | ConvertTo-Json -Depth 12
