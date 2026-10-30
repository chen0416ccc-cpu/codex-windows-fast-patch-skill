[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$ResumePreparedBuild,
  [string]$PreparedOutputRoot,
  [string]$PreparedTranscriptPath,
  [string[]]$CustomModels
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'
$dataRoot = 'D:\CodexData\codex-windows-fast-patch'
$runRoot = Join-Path $dataRoot 'model-experience-repair-runs'
$logRoot = Join-Path $dataRoot 'model-experience-repair-logs'
. (Join-Path $PSScriptRoot 'lib\post-update-readiness.ps1')

function Assert-LocalDirectory {
  param([string]$Path, [switch]$Create)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repair data must stay on D:\: $fullPath"
  }
  $drive = [IO.DriveInfo]::new('D:\')
  if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'D: is not a fixed local drive.' }
  $relative = $fullPath.Substring(3).Split('\')
  $current = 'D:\'
  foreach ($part in $relative) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $current = Join-Path $current $part
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Repair data path is not a normal local directory: $current"
      }
    } elseif ($Create) {
      New-Item -ItemType Directory -Path $current -ErrorAction Stop | Out-Null
    } else {
      throw "Repair data directory does not exist: $current"
    }
  }
  return $fullPath
}

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Recoverable runner not found: $runner" }
foreach ($scope in @('Process', 'User', 'Machine')) {
  if ([Environment]::GetEnvironmentVariable('CODEX_HOME', $scope)) {
    throw "CODEX_HOME is set at $scope scope; refusing to target an isolated CLI home."
  }
}

$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $package) { throw 'The current-user Codex MSIX package is unavailable.' }

$transaction = Get-PostUpdateTransaction -LogRoot $logRoot -StatusScript (Join-Path $PSScriptRoot 'get-model-experience-repair-status.ps1')
if ($transaction -and $transaction.Assessment.Status -in @('installer-running', 'installer-status-unknown', 'different-user',
    'installed-needs-verification', 'verified-cleanup-needed')) {
  throw "An existing repair requires attention instead of a new installer: $($transaction.Assessment.Status); state=$($transaction.StatePath)"
}
if (-not $PSBoundParameters.ContainsKey('CustomModels')) {
  $CustomModels = @((Get-RepairModelInventory).customModels)
  Write-Host "Selected $($CustomModels.Count) repair model IDs from the active catalog."
}
if (@($CustomModels).Count -eq 0) { throw 'CustomModels must not be empty.' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
$sid = $identity.User.Value
$null = Assert-LocalDirectory -Path $dataRoot
$suffix = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
$null = Assert-LocalDirectory -Path $runRoot -Create
$null = Assert-LocalDirectory -Path $logRoot -Create
$outputRoot = Join-Path $runRoot $suffix
if ($ResumePreparedBuild) {
  if (-not $PreparedOutputRoot -or -not $PreparedTranscriptPath) {
    throw 'ResumePreparedBuild requires both PreparedOutputRoot and PreparedTranscriptPath.'
  }
  $outputRoot = [IO.Path]::GetFullPath($PreparedOutputRoot)
  if ((Split-Path -Parent $outputRoot) -ine [IO.Path]::GetFullPath($runRoot).TrimEnd('\')) {
    throw "Prepared output must be a direct child of $($runRoot): $outputRoot"
  }
  $null = Assert-LocalDirectory -Path $outputRoot
  $PreparedTranscriptPath = [IO.Path]::GetFullPath($PreparedTranscriptPath)
  if ((Split-Path -Parent $PreparedTranscriptPath) -ine [IO.Path]::GetFullPath($logRoot).TrimEnd('\')) {
    throw "Prepared transcript must be a direct child of $($logRoot)."
  }
  $preparedTranscriptItem = Get-Item -LiteralPath $PreparedTranscriptPath -Force -ErrorAction Stop
  if ($preparedTranscriptItem.PSIsContainer -or ($preparedTranscriptItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Prepared transcript must be an ordinary file.'
  }
} elseif ($PreparedOutputRoot -or $PreparedTranscriptPath) {
  throw 'PreparedOutputRoot and PreparedTranscriptPath require ResumePreparedBuild.'
}
$transcriptPath = Join-Path $logRoot ($suffix + '.transcript.txt')
if (-not $ResumePreparedBuild -and (Test-Path -LiteralPath $outputRoot)) { throw "Repair output root already exists: $outputRoot" }
if (Test-Path -LiteralPath $transcriptPath) { throw "Repair transcript already exists: $transcriptPath" }

$payload = [ordered]@{
  Runner = $runner
  OutputRoot = $outputRoot
  TranscriptPath = $transcriptPath
  ExpectedUserSid = $sid
  ExpectedSessionId = $sessionId
  ExpectedPackageFullName = $package.PackageFullName
  ResumePreparedBuild = [bool]$ResumePreparedBuild
  PreparedTranscriptPath = if ($ResumePreparedBuild) { $PreparedTranscriptPath } else { $null }
  CustomModels = @($CustomModels)
}
$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 5 -Compress)))
$bootstrap = @'
$payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))
$payload = $payloadJson | ConvertFrom-Json
& $payload.Runner `
  -OutputRoot $payload.OutputRoot `
  -TranscriptPath $payload.TranscriptPath `
  -ExpectedUserSid $payload.ExpectedUserSid `
  -ExpectedSessionId ([int]$payload.ExpectedSessionId) `
  -ExpectedPackageFullName $payload.ExpectedPackageFullName `
  -ResumePreparedBuild:([bool]$payload.ResumePreparedBuild) `
  -PreparedTranscriptPath $payload.PreparedTranscriptPath `
  -CustomModels @($payload.CustomModels)
exit $LASTEXITCODE
'@
$bootstrap = $bootstrap.Replace('__PAYLOAD__', $payloadBase64)
$bootstrapTokens = $null
$bootstrapErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($bootstrap, [ref]$bootstrapTokens, [ref]$bootstrapErrors)
if ($bootstrapErrors.Count -gt 0) {
  throw "Generated elevated bootstrap failed PowerShell parsing: $($bootstrapErrors[0].Message)"
}
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found: $powershellExe" }
$arguments = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-EncodedCommand', $encodedCommand)

Write-Host "Source package: $($package.PackageFullName)"
Write-Host "Installer identity: $($identity.Name); session=$sessionId"
if ($ResumePreparedBuild) {
  Write-Host "Resuming verified prepared build: $outputRoot"
  Write-Host "Prepared patch transcript: $PreparedTranscriptPath"
} else {
  Write-Host "Recovery and build root: $outputRoot"
}
Write-Host "Transcript: $transcriptPath"
Write-Host "Deployment state (written after installer identity checks): $transcriptPath.state.json"
Write-Host 'The external installer will request normal Windows UAC consent. No task-scheduler or policy bypass is used.'

if ($PSCmdlet.ShouldProcess($package.PackageFullName, 'Start independent elevated recoverable Model Experience repair')) {
  try {
    $process = Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
  } catch {
    throw "UAC did not authorize the external repair process; Codex was not closed or changed. $($_.Exception.Message)"
  }
  Write-Host "Independent elevated installer started: pid=$($process.Id)"
  Write-Host "Inspect transcript and retained recovery artifacts after Codex relaunch: $transcriptPath"
}
