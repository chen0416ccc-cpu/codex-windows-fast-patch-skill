[CmdletBinding()]
param(
  [string]$StateRoot,
  [switch]$NotifyMsg,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$watchScript = Join-Path $ScriptRoot 'watch-codex-desktop.ps1'
$uiRoot = Join-Path $state.Paths.Root 'ui'
$runStatePath = Join-Path $uiRoot 'last-run.json'

if (-not (Test-Path -LiteralPath $watchScript -PathType Leaf)) {
  throw "watch script not found: $watchScript"
}

function Write-RunState {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [string]$ErrorText,
    [datetime]$StartedAt = (Get-Date),
    [datetime]$FinishedAt = (Get-Date)
  )
  New-Item -ItemType Directory -Force -Path $uiRoot | Out-Null
  $payload = [pscustomobject]@{
    SchemaVersion = 1
    Status = $Status
    StartedAt = $StartedAt.ToString('o')
    FinishedAt = $FinishedAt.ToString('o')
    StateRoot = $state.Paths.Root
    Pid = $PID
    Error = $ErrorText
  }
  Write-GuardJsonFile -Path $runStatePath -Value $payload
  return $payload
}

$startedAt = Get-Date
Write-RunState -Status 'running' -StartedAt $startedAt -FinishedAt $startedAt | Out-Null

$result = $null
try {
  $arguments = @{
    StateRoot = $state.Paths.Root
  }
  if ($NotifyMsg) {
    $arguments.NotifyMsg = $true
  }
  & $watchScript @arguments 2>&1 | Out-Null
  $result = Write-RunState -Status 'completed' -StartedAt $startedAt -FinishedAt (Get-Date)
} catch {
  $result = Write-RunState -Status 'failed' -ErrorText $_.Exception.Message -StartedAt $startedAt -FinishedAt (Get-Date)
  throw
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
}
