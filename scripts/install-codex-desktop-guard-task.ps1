[CmdletBinding()]
param(
  [string]$TaskName = 'Codex Desktop Guard',
  [int]$IntervalMinutes = 30,
  [string]$StateRoot,
  [switch]$NotifyMsg,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
if ($IntervalMinutes -lt 5) {
  throw 'IntervalMinutes must be at least 5.'
}
$state = Initialize-GuardState -StateRoot $StateRoot
$runnerScript = Join-Path $ScriptRoot 'run-codex-desktop-guard-check.ps1'
if (-not (Test-Path -LiteralPath $runnerScript -PathType Leaf)) {
  throw "guard runner script not found: $runnerScript"
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
  if (-not $Force) {
    throw "scheduled task already exists: $TaskName. Re-run with -Force to replace it."
  }
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$arguments = @(
  '-NoProfile',
  '-WindowStyle',
  'Hidden',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  (ConvertTo-GuardWindowsCommandArgument $runnerScript),
  '-StateRoot',
  (ConvertTo-GuardWindowsCommandArgument $state.Paths.Root)
)
if ($NotifyMsg) {
  $arguments += '-NotifyMsg'
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($arguments -join ' ')
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Watch Codex Desktop package/resource changes and prepare fast-patch staging only. It never applies patches automatically.'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
Write-GuardLog -State $state -LogName 'task.log' -Message "installed scheduled task '$TaskName' every $IntervalMinutes minutes for $identity"
[pscustomobject]@{
  TaskName = $TaskName
  IntervalMinutes = $IntervalMinutes
  StateRoot = $state.Paths.Root
  RunnerScript = $runnerScript
} | ConvertTo-Json
