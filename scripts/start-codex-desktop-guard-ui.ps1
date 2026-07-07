[CmdletBinding()]
param(
  [string]$StateRoot,
  [ValidateRange(1024, 65535)][int]$Port = 8765,
  [string]$TaskName = 'Codex Desktop Guard',
  [switch]$Foreground,
  [switch]$NoOpen,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SkillRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$paths = New-GuardDirectorySet -StateRoot $StateRoot
$uiRoot = Join-Path $paths.Root 'ui'
$serverPath = Join-Path $uiRoot 'server.json'
$logPath = Join-Path $uiRoot 'server.log'
$htmlPath = Join-Path $SkillRoot 'assets\codex-desktop-guard-ui.html'
$checkScript = Join-Path $ScriptRoot 'check-codex-desktop-guard.ps1'
$url = "http://127.0.0.1:$Port/"

function Write-UiLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
  if ($Foreground) {
    Write-Host $line
  }
}

function Join-UiArgumentList {
  param([string[]]$Arguments)
  return (($Arguments | ForEach-Object { ConvertTo-GuardWindowsCommandArgument $_ }) -join ' ')
}

function Write-UiResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Body,
    [string]$ContentType = 'text/plain; charset=utf-8',
    [int]$StatusCode = 200
  )
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentLength64 = $Body.Length
  $Context.Response.Headers['Cache-Control'] = 'no-store'
  $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
  $Context.Response.OutputStream.Close()
}

function Write-UiTextResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
    [AllowNull()][string]$Text,
    [string]$ContentType = 'text/plain; charset=utf-8',
    [int]$StatusCode = 200
  )
  $body = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
  Write-UiResponse -Context $Context -Body $body -ContentType $ContentType -StatusCode $StatusCode
}

function Get-UiStatusJson {
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $checkScript,
    '-TaskName',
    $TaskName,
    '-TailLines',
    '12',
    '-Json'
  )
  if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    $arguments += @('-StateRoot', $paths.Root)
  }
  $capture = Invoke-GuardProcessCapture -FilePath 'powershell.exe' -Arguments $arguments -TimeoutSeconds 12
  if ($capture.ExitCode -ne 0) {
    throw "check-codex-desktop-guard.ps1 exited with $($capture.ExitCode): $($capture.Stderr)"
  }
  return $capture.Stdout
}

function Test-UiServerRunning {
  param([AllowNull()][object]$Server)
  if (-not $Server -or -not $Server.Pid) {
    return $false
  }
  $process = Get-Process -Id ([int]$Server.Pid) -ErrorAction SilentlyContinue
  return ($null -ne $process)
}

if (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) {
  throw "UI asset not found: $htmlPath"
}
if (-not (Test-Path -LiteralPath $checkScript -PathType Leaf)) {
  throw "guard status script not found: $checkScript"
}
New-Item -ItemType Directory -Force -Path $uiRoot | Out-Null

if (-not $Foreground) {
  $existing = Read-GuardJsonFile -Path $serverPath
  if (Test-UiServerRunning -Server $existing) {
    if (-not $NoOpen) {
      Start-Process ([string]$existing.Url) | Out-Null
    }
    $result = [pscustomobject]@{
      Status = 'already_running'
      Url = [string]$existing.Url
      Pid = [int]$existing.Pid
      ServerPath = $serverPath
    }
    if ($Json) {
      $result | ConvertTo-Json -Depth 6
    } else {
      Write-Host "Codex Desktop Guard UI already running: $($result.Url)"
    }
    return
  }

  $scriptPath = $MyInvocation.MyCommand.Path
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $scriptPath,
    '-Foreground',
    '-NoOpen',
    '-Port',
    [string]$Port,
    '-TaskName',
    $TaskName
  )
  if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    $arguments += @('-StateRoot', $paths.Root)
  }
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-UiArgumentList -Arguments $arguments) -WindowStyle Hidden -PassThru
  $deadline = (Get-Date).AddSeconds(10)
  $started = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $started = Read-GuardJsonFile -Path $serverPath
    if ($started -and [int]$started.Pid -eq $process.Id -and $started.Status -eq 'running') {
      break
    }
    if ($process.HasExited) {
      break
    }
  }
  if (-not $started -or [int]$started.Pid -ne $process.Id -or $started.Status -ne 'running') {
    throw "guard UI server did not start. Check log: $logPath"
  }
  if (-not $NoOpen) {
    Start-Process $url | Out-Null
  }
  $result = [pscustomobject]@{
    Status = 'started'
    Url = $url
    Pid = $process.Id
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

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)
try {
  $listener.Start()
  Write-GuardJsonFile -Path $serverPath -Value ([pscustomobject]@{
    Status = 'running'
    Url = $url
    Pid = $PID
    Port = $Port
    StateRoot = $paths.Root
    StartedAt = (Get-Date).ToString('o')
    ScriptPath = $MyInvocation.MyCommand.Path
    LogPath = $logPath
  })
  Write-UiLog "server started: $url"
  if (-not $NoOpen) {
    Start-Process $url | Out-Null
  }
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $path = $context.Request.Url.AbsolutePath
      if ($path -eq '/' -or $path -eq '/index.html') {
        $html = [System.IO.File]::ReadAllBytes($htmlPath)
        Write-UiResponse -Context $context -Body $html -ContentType 'text/html; charset=utf-8'
      } elseif ($path -eq '/favicon.ico') {
        Write-UiResponse -Context $context -Body ([byte[]]@()) -ContentType 'image/x-icon' -StatusCode 204
      } elseif ($path -eq '/api/status') {
        Write-UiTextResponse -Context $context -Text (Get-UiStatusJson) -ContentType 'application/json; charset=utf-8'
      } else {
        Write-UiTextResponse -Context $context -Text 'Not found' -StatusCode 404
      }
    } catch {
      $errorJson = [pscustomobject]@{
        error = $_.Exception.Message
      } | ConvertTo-Json -Depth 4
      try {
        Write-UiTextResponse -Context $context -Text $errorJson -ContentType 'application/json; charset=utf-8' -StatusCode 500
      } catch {
      }
    }
  }
} catch {
  Write-GuardJsonFile -Path $serverPath -Value ([pscustomobject]@{
    Status = 'failed'
    Url = $url
    Pid = $PID
    Port = $Port
    StateRoot = $paths.Root
    UpdatedAt = (Get-Date).ToString('o')
    Error = $_.Exception.Message
    LogPath = $logPath
  })
  Write-UiLog "server failed: $($_.Exception.Message)"
  throw
} finally {
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
  $current = Read-GuardJsonFile -Path $serverPath
  if ($current -and [int]$current.Pid -eq $PID) {
    Remove-Item -LiteralPath $serverPath -Force -ErrorAction SilentlyContinue
  }
  Write-UiLog 'server stopped'
}
