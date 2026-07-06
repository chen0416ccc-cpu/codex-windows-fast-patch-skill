[CmdletBinding()]
param(
  [string]$TaskName = 'Codex Desktop Guard',
  [string]$StateRoot,
  [switch]$RemoveState
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-GuardLog -State $state -LogName 'task.log' -Message "uninstalled scheduled task '$TaskName'"
} else {
  Write-GuardLog -State $state -LogName 'task.log' -Message "scheduled task was not present: '$TaskName'"
}

if ($RemoveState) {
  $defaultRoot = Resolve-GuardFullPath (Get-GuardDefaultStateRoot)
  $targetRoot = Resolve-GuardFullPath $state.Paths.Root
  if ($targetRoot -ne $defaultRoot) {
    throw "refusing to remove non-default state root automatically: $targetRoot"
  }
  if (Test-Path -LiteralPath $targetRoot -PathType Container) {
    Remove-Item -LiteralPath $targetRoot -Recurse -Force
    Write-Host "removed state root: $targetRoot"
  }
}

[pscustomobject]@{
  TaskName = $TaskName
  StateRoot = $state.Paths.Root
  RemovedState = [bool]$RemoveState
} | ConvertTo-Json
