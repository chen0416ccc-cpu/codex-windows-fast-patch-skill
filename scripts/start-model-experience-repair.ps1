[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$ResumePreparedBuild,
  [string]$PreparedOutputRoot,
  [string]$PreparedTranscriptPath,
  [string[]]$CustomModels,
  [string]$DataRoot,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'
. (Join-Path $PSScriptRoot 'lib\repair-storage.ps1')
. (Join-Path $PSScriptRoot 'lib\post-update-readiness.ps1')
. (Join-Path $PSScriptRoot 'lib\appx-launch.ps1')

function Assert-LocalDirectory {
  param([string]$Path, [switch]$Create)
  return Assert-RepairLocalDirectory -Path $Path -Create:$Create
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

$configuredDataRoot = if ($DataRoot) { $DataRoot } else { $env:CODEX_WINDOWS_REPAIR_DATA_ROOT }
if ($ResumePreparedBuild -and $PreparedOutputRoot) {
  $preparedDataRoot = Get-RepairDataRootFromRunPath $PreparedOutputRoot
  if ($DataRoot -and (Get-RepairStorageLayout $DataRoot).DataRoot -ine $preparedDataRoot) {
    throw 'Prepared output does not belong to the explicitly configured data root.'
  }
  $configuredDataRoot = $preparedDataRoot
}
$storage = Get-RepairStorageLayout -DataRoot $configuredDataRoot
$dataRoot = $storage.DataRoot
$runRoot = $storage.RunRoot
$logRoot = $storage.LogRoot
$knownLogs = @((Get-RepairKnownDataRoots -DataRoot $dataRoot) | ForEach-Object { Join-Path $_ 'model-experience-repair-logs' })
$transaction = Get-PostUpdateTransaction -LogRoot $knownLogs -StatusScript (Join-Path $PSScriptRoot 'get-model-experience-repair-status.ps1')
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
$null = Assert-RepairLocalDirectory -Path $dataRoot -AllowMissing
$suffix = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
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
  DataRoot = $dataRoot
  KeepArtifacts = [bool]$KeepArtifacts
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
  -DataRoot $payload.DataRoot `
  -KeepArtifacts:([bool]$payload.KeepArtifacts) `
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
$powershellExe = Get-AppxNativePowerShellPath
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
  $null = Assert-LocalDirectory -Path $dataRoot -Create
  $null = Assert-LocalDirectory -Path $runRoot -Create
  $null = Assert-LocalDirectory -Path $logRoot -Create
  try {
    $process = Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
  } catch {
    throw "UAC did not authorize the external repair process; Codex was not closed or changed. $($_.Exception.Message)"
  }
  Write-Host "Independent elevated installer started: pid=$($process.Id)"
  Write-Host "Inspect transcript and retained recovery artifacts after Codex relaunch: $transcriptPath"
}
