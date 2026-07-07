[CmdletBinding()]
param(
  [string]$StateRoot,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$paths = New-GuardDirectorySet -StateRoot $StateRoot
$serverPath = Join-Path $paths.Root 'ui\server.json'

function Write-StopResult {
  param([object]$Result)
  if ($Json) {
    $Result | ConvertTo-Json -Depth 6
  } else {
    Write-Host $Result.Message
  }
}

$server = Read-GuardJsonFile -Path $serverPath
if (-not $server -or -not $server.Pid) {
  Write-StopResult ([pscustomobject]@{
    Status = 'not_running'
    Message = 'Codex Desktop Guard UI is not running.'
    ServerPath = $serverPath
  })
  return
}

$pidValue = [int]$server.Pid
$process = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
if (-not $process) {
  Remove-Item -LiteralPath $serverPath -Force -ErrorAction SilentlyContinue
  Write-StopResult ([pscustomobject]@{
    Status = 'stale'
    Message = 'Codex Desktop Guard UI server record was stale and has been removed.'
    Pid = $pidValue
    ServerPath = $serverPath
  })
  return
}

$commandLine = [string]$process.CommandLine
if ($commandLine -notlike '*start-codex-desktop-guard-ui.ps1*' -or $commandLine -notlike '*-Foreground*') {
  throw "Refusing to stop PID $pidValue because it does not look like the guard UI server."
}

Stop-Process -Id $pidValue -Force
Remove-Item -LiteralPath $serverPath -Force -ErrorAction SilentlyContinue
Write-StopResult ([pscustomobject]@{
  Status = 'stopped'
  Message = "Codex Desktop Guard UI stopped: PID $pidValue"
  Pid = $pidValue
  Url = if ($server.Url) { [string]$server.Url } else { $null }
  ServerPath = $serverPath
})
