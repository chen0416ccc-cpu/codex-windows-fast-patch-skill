[CmdletBinding()]
param(
  [string]$StateRoot,
  [ValidateRange(1024, 65535)][int]$Port = 8765,
  [string]$TaskName = 'Codex Desktop Guard',
  [switch]$NoOpen,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SkillRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$uiRoot = Join-Path $state.Paths.Root 'ui'
$serverPath = Join-Path $uiRoot 'server.json'
$logPath = Join-Path $uiRoot 'server.log'
$htmlPath = Join-Path $SkillRoot 'assets\codex-desktop-guard-ui.html'
$runnerScript = Join-Path $ScriptRoot 'run-codex-desktop-guard-check.ps1'
$pythonServer = Join-Path $ScriptRoot 'codex_desktop_guard_ui_server.py'
$url = "http://127.0.0.1:$Port/"

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

function Test-UiServerRunning {
  param([AllowNull()][object]$Server)
  if (-not $Server -or -not $Server.Pid) {
    return $false
  }
  $process = Get-Process -Id ([int]$Server.Pid) -ErrorAction SilentlyContinue
  return ($null -ne $process)
}

function Get-PythonCommand {
  $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($py) {
    $capture = Invoke-GuardProcessCapture -FilePath $py.Source -Arguments @('-3', '-c', 'import sys; print(sys.executable)') -TimeoutSeconds 10
    if ($capture.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($capture.Stdout)) {
      return $capture.Stdout.Trim()
    }
  }
  foreach ($name in @('python.exe', 'python')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
      return $cmd.Source
    }
  }
  throw 'python is required to host the guard UI.'
}

if (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) {
  throw "UI asset not found: $htmlPath"
}
if (-not (Test-Path -LiteralPath $runnerScript -PathType Leaf)) {
  throw "guard runner script not found: $runnerScript"
}
if (-not (Test-Path -LiteralPath $pythonServer -PathType Leaf)) {
  throw "guard UI server script not found: $pythonServer"
}

New-Item -ItemType Directory -Force -Path $uiRoot | Out-Null
$python = Get-PythonCommand
$existing = Read-UiServerRecord
if (Test-UiServerRunning -Server $existing) {
  if (-not $NoOpen) {
    Start-Process $url | Out-Null
  }
  $result = [pscustomobject]@{
    Status = 'already_running'
    Url = $url
    Pid = [int]$existing.Pid
    ServerPath = $serverPath
    LogPath = $logPath
  }
  if ($Json) {
    $result | ConvertTo-Json -Depth 6
  } else {
    Write-Host "Codex Desktop Guard UI: $url"
  }
  return
}

$arguments = @(
  $pythonServer,
  '--state-root',
  $state.Paths.Root,
  '--port',
  [string]$Port,
  '--task-name',
  $TaskName,
  '--html-path',
  $htmlPath,
  '--runner-script',
  $runnerScript
)

$argumentText = (($arguments | ForEach-Object { ConvertTo-GuardWindowsCommandArgument $_ }) -join ' ')
$process = Start-Process -FilePath $python -ArgumentList $argumentText -WindowStyle Hidden -PassThru
$deadline = (Get-Date).AddSeconds(10)
$started = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
  $started = Read-UiServerRecord
  if ($started -and $started.Status -eq 'running' -and (Test-UiServerRunning -Server $started)) {
    break
  }
  if ($process.HasExited) {
    break
  }
}

if (-not $started -or $started.Status -ne 'running' -or -not (Test-UiServerRunning -Server $started)) {
  throw "guard UI server did not start. Check log: $logPath"
}

if (-not $NoOpen) {
  Start-Process $url | Out-Null
}

$result = [pscustomobject]@{
  Status = 'started'
  Url = $url
  Pid = [int]$started.Pid
  ServerPath = $serverPath
  LogPath = $logPath
}
if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Host "Codex Desktop Guard UI: $url"
}
