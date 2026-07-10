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

function Read-UiServerRecord {
  if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    return $null
  }
  try {
    return Read-GuardJsonFile -Path $serverPath
  } catch {
    Remove-Item -LiteralPath $serverPath -Force -ErrorAction SilentlyContinue
    return $null
  }
}

function Write-StopResult {
  param([object]$Result)
  if ($Json) {
    $Result | ConvertTo-Json -Depth 6
  } else {
    Write-Host $Result.Message
  }
}

$server = Read-UiServerRecord
if (-not $server -or -not $server.Pid) {
  Write-StopResult ([pscustomobject]@{
    Status = 'not_running'
    Message = 'Codex Desktop Guard UI is not running.'
    ServerPath = $serverPath
  })
  return
}

$pidValue = [int]$server.Pid
$process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
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

Stop-Process -Id $pidValue -Force
Remove-Item -LiteralPath $serverPath -Force -ErrorAction SilentlyContinue
Write-StopResult ([pscustomobject]@{
  Status = 'stopped'
  Message = "Codex Desktop Guard UI stopped: PID $pidValue"
  Pid = $pidValue
  Url = if ($server.Url) { [string]$server.Url } else { $null }
  ServerPath = $serverPath
})
