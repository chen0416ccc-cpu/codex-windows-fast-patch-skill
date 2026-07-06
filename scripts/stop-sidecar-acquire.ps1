[CmdletBinding()]
param(
  [string]$StateRoot
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$outputRoot = Join-Path $state.Paths.Root 'sidecar-output'
$statusPath = Join-Path $outputRoot 'status.json'
$logPath = Join-Path $outputRoot 'sandbox-sidecar.log'
$payloadZip = Join-Path $outputRoot 'codex-payload.zip'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$previousStatus = $null
try {
  $previousStatus = Read-GuardJsonFile -Path $statusPath
} catch {
  $previousStatus = [pscustomobject]@{
    state = 'unknown'
    step = 'previous_status_read_failed'
    lastError = $_.Exception.Message
  }
}

$processes = @(Get-Process WindowsSandbox, WindowsSandboxClient -ErrorAction SilentlyContinue)
foreach ($process in $processes) {
  Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
$remaining = @(Get-Process WindowsSandbox, WindowsSandboxClient -ErrorAction SilentlyContinue)

$status = [pscustomobject]@{
  schemaVersion = 1
  state = if ($remaining.Count -eq 0) { 'stopped' } else { 'stop_failed' }
  step = 'stop_sidecar'
  lastError = if ($remaining.Count -eq 0) { $null } else { 'Some Windows Sandbox processes are still running.' }
  payloadZip = $payloadZip
  payloadZipExists = (Test-Path -LiteralPath $payloadZip -PathType Leaf)
  updatedAt = (Get-Date).ToString('o')
  logPath = $logPath
  outputRoot = $outputRoot
  previousStatus = $previousStatus
  stoppedProcesses = @($processes | Select-Object ProcessName, Id)
  remainingProcesses = @($remaining | Select-Object ProcessName, Id)
}
Write-GuardJsonFile -Path $statusPath -Value $status
$status | ConvertTo-Json -Depth 8
