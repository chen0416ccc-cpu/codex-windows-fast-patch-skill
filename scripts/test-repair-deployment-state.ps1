[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1')
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  $threw = $false
  try { & $Action | Out-Null } catch { $threw = $true }
  Assert $threw $Message
}
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('deployment-state-' + [guid]::NewGuid().ToString('N'))
$logRoot = Join-Path $root 'logs'
$resolvedOutputRoot = Join-Path $root 'build'
New-Item -ItemType Directory -Path $logRoot, $resolvedOutputRoot -Force | Out-Null
$statePath = Join-Path $logRoot 'repair.transcript.txt.state.json'
$transcriptPath = Join-Path $logRoot 'repair.transcript.txt'
$source = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_26.1016.8120.0_x64__test'; Version = [version]'26.1016.8120.0' }
$target = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_26.1016.8120.1_x64__test'; Version = [version]'26.1016.8120.1' }
$recovery = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_26.1016.8120.2_x64__test'; Version = [version]'26.1016.8120.2' }
$newer = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_26.1020.11127.0_x64__test'; Version = [version]'26.1020.11127.0' }
$currentProcess = Get-Process -Id $PID
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$missingProcessError = [Management.Automation.ErrorRecord]::new(
  [InvalidOperationException]::new('missing process'),
  'NoProcessFoundForGivenId,Microsoft.PowerShell.Commands.GetProcessCommand',
  [Management.Automation.ErrorCategory]::ObjectNotFound,
  2147483647)
$otherProcessError = [Management.Automation.ErrorRecord]::new(
  [UnauthorizedAccessException]::new('access denied'),
  'GetProcessAccessDenied,Microsoft.PowerShell.Commands.GetProcessCommand',
  [Management.Automation.ErrorCategory]::PermissionDenied,
  2147483647)
Assert (Test-RepairProcessNotFoundError -ErrorRecord $missingProcessError) 'Windows PowerShell 5.1 missing-process error is recognized as exited'
Assert (-not (Test-RepairProcessNotFoundError -ErrorRecord $otherProcessError)) 'other process errors remain unknown'
function New-FixtureState {
  New-RepairDeploymentState -SourcePackage $source -InstallerProcess $currentProcess -UserSid $sid `
    -SessionId $currentProcess.SessionId -OutputRoot $resolvedOutputRoot -TranscriptPath $transcriptPath
}
$state = New-FixtureState
Write-RepairDeploymentState -Path $statePath -State $state
$read = Read-RepairDeploymentState $statePath
Assert ($read.targetPackageFullName -ceq $target.PackageFullName) 'target identity uses exactly one revision increment'
Assert (-not $read.acceptancePassed) 'preparation never implies acceptance'
Assert ($statePath.StartsWith($logRoot) -and -not $statePath.StartsWith($resolvedOutputRoot)) 'checkpoint is outside the disposable build tree'
Assert ((Get-RepairDeploymentAssessment $read $target $null $sid).Status -eq 'installed-needs-verification') 'registration alone needs verification'
Assert ((Get-RepairDeploymentAssessment $read $source $currentProcess $sid).Status -eq 'installer-running') 'PID, session and start time match a live process'

$postDeploy = New-FixtureState | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$postDeploy.stage = 'deploying'
$modelListEvidence = [pscustomobject]@{ model = 'gpt-6-astra'; serviceTiers = @('priority', 'ultrafast') }
Set-RepairAcceptanceCheckpoint -State $postDeploy -CurrentPackageFullName $target.PackageFullName `
  -InstallerExited $true -DesktopLaunchPassed $true -FastWirePassed $true `
  -ModelList $modelListEvidence -StrictVerificationPassed $true
Assert ($postDeploy.acceptancePassed -and $postDeploy.stage -eq 'cleanup-pending' -and
  $postDeploy.verifiedPackageFullName -ceq $target.PackageFullName) 'post-deployment finalizer records only complete target-bound evidence'
Write-RepairDeploymentState -Path $statePath -State $postDeploy
$roundTripAccepted = Read-RepairDeploymentState $statePath
Assert ($roundTripAccepted.acceptancePassed -and $roundTripAccepted.verifiedPackageFullName -ceq $target.PackageFullName) 'JSON-loaded acceptance checkpoint writes atomically'
Assert (@($modelListEvidence.serviceTiers) -contains 'ultrafast') 'advertised Ultrafast remains model-specific evidence'
Assert-Throws {
  $bad = New-FixtureState; $bad.stage = 'deploying'
  Set-RepairAcceptanceCheckpoint -State $bad -CurrentPackageFullName $source.PackageFullName `
    -InstallerExited $true -DesktopLaunchPassed $true -FastWirePassed $true `
    -ModelList $modelListEvidence -StrictVerificationPassed $true
} 'a superseded or wrong package cannot be accepted'
Assert-Throws {
  $bad = New-FixtureState; $bad.stage = 'deploying'
  Set-RepairAcceptanceCheckpoint -State $bad -CurrentPackageFullName $target.PackageFullName `
    -InstallerExited $false -DesktopLaunchPassed $true -FastWirePassed $true `
    -ModelList $modelListEvidence -StrictVerificationPassed $true
} 'a live or unknown installer cannot be accepted'
Assert-Throws {
  $bad = New-FixtureState; $bad.stage = 'deploying'
  Set-RepairAcceptanceCheckpoint -State $bad -CurrentPackageFullName $target.PackageFullName `
    -InstallerExited $true -DesktopLaunchPassed $true -FastWirePassed $true `
    -ModelList ([pscustomobject]@{ model = 'gpt-6-astra'; serviceTiers = @() }) -StrictVerificationPassed $true
} 'model/list without priority cannot be accepted'
Assert-Throws {
  $bad = New-FixtureState; $bad.stage = 'deploying'
  Set-RepairAcceptanceCheckpoint -State $bad -CurrentPackageFullName $target.PackageFullName `
    -InstallerExited $true -DesktopLaunchPassed $false -FastWirePassed $true `
    -ModelList $modelListEvidence -StrictVerificationPassed $true
} 'a missing target Desktop launch cannot be accepted'
Assert-Throws {
  $bad = New-FixtureState; $bad.stage = 'deploying'
  Set-RepairAcceptanceCheckpoint -State $bad -CurrentPackageFullName $target.PackageFullName `
    -InstallerExited $true -DesktopLaunchPassed $true -FastWirePassed $true `
    -ModelList $modelListEvidence -StrictVerificationPassed $false
} 'a failed strict runtime check cannot be accepted'

$reused = [pscustomobject]@{ Id = $PID; SessionId = $currentProcess.SessionId; StartTime = $currentProcess.StartTime.AddSeconds(1) }
Assert ((Get-RepairDeploymentAssessment $read $source $reused $sid).Status -eq 'interrupted-not-installed') 'PID reuse cannot impersonate the installer'
$otherSession = [pscustomobject]@{ Id = $PID; SessionId = $currentProcess.SessionId + 1; StartTime = $currentProcess.StartTime }
Assert ((Get-RepairDeploymentAssessment $read $source $otherSession $sid).Status -eq 'interrupted-not-installed') 'a different session is not the installer'
Assert ((Get-RepairDeploymentAssessment $read $target $null $sid -InstallerProbeFailed).Status -eq 'installer-status-unknown') 'access errors are not treated as process exit'
$unreadableProcess = [pscustomobject]@{ Id = $PID; SessionId = $currentProcess.SessionId; StartTime = $null }
Assert ((Get-RepairDeploymentAssessment $read $target $unreadableProcess $sid -InstallerProbeFailed).Status -eq 'installer-status-unknown') 'unknown start time does not crash or imply process exit'
Assert ((Get-RepairDeploymentAssessment $read $target $null 'other-user').Status -eq 'different-user') 'current-user package results cannot validate another user'
Assert ((Get-RepairDeploymentAssessment $read $null $null $sid).Status -eq 'package-missing') 'missing registration is explicit'
Assert ((Get-RepairDeploymentAssessment $read $newer $null $sid).Status -eq 'superseded') 'a newer version supersedes the old candidate'
$changed = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_26.1020.11127.0_x64__other'; Version = $newer.Version }
Assert ((Get-RepairDeploymentAssessment $read $changed $null $sid).Status -eq 'package-changed') 'another package identity cannot imply supersession'
$state.stage = 'failed'
$state.recoveryPackageFullName = $recovery.PackageFullName
Assert ((Get-RepairDeploymentAssessment $state $source $null $sid).Status -eq 'failed-original-retained') 'original registration retained after failure'
Assert ((Get-RepairDeploymentAssessment $state $recovery $null $sid).Status -eq 'recovered-original-content') 'recovery is not patch acceptance'
$state.stage = 'cleanup-pending'
$state.acceptancePassed = $true
$state.verifiedPackageFullName = $target.PackageFullName
$state.verifiedUtc = [DateTime]::UtcNow.ToString('o')
$state.cleanupStatus = 'pending'
Assert ((Get-RepairDeploymentAssessment $state $target $null $sid).Status -eq 'verified-cleanup-needed') 'acceptance and cleanup remain distinct'
$state.cleanupStatus = 'removed'
$state.stage = 'verified-complete'
Write-RepairDeploymentState -Path $statePath -State $state
$read = Read-RepairDeploymentState $statePath
Assert ($read.acceptancePassed -and (Get-RepairDeploymentAssessment $read $target $null $sid).Status -eq 'verified-complete') 'atomic replacement persists successful acceptance'
Assert ((Get-RepairDeploymentAssessment $read $newer $null $sid).Status -eq 'superseded') 'old acceptance cannot validate a later Store update'
$superseded = Get-RepairDeploymentAssessment $read $newer $null $sid
Assert (-not $superseded.AcceptancePassed -and $superseded.RecordedAcceptancePassed) 'query separates historical acceptance from acceptance of the current registration'
$state.verifiedPackageFullName = $recovery.PackageFullName
Assert-Throws { Write-RepairDeploymentState $statePath $state } 'acceptance for the recovery identity is rejected'
$state = New-FixtureState
$state.acceptancePassed = 'false'
Assert-Throws { Write-RepairDeploymentState $statePath $state } 'string booleans cannot become true acceptance'
Assert-Throws { Read-RepairDeploymentState (Join-Path $logRoot 'missing.json') } 'missing checkpoint fails explicitly'
$invalid = Join-Path $logRoot 'invalid.json'
[IO.File]::WriteAllText($invalid, '{"schemaVersion":1}')
Assert-Throws { Read-RepairDeploymentState $invalid } 'incomplete JSON cannot imply completion'
[IO.File]::WriteAllText($invalid, '{')
Assert-Throws { Read-RepairDeploymentState $invalid } 'truncated JSON is rejected'
[IO.File]::WriteAllText($invalid, ('x' * 65537))
Assert-Throws { Read-RepairDeploymentState $invalid } 'oversized state is rejected before parsing'
Assert-Throws { Write-RepairDeploymentState $logRoot (New-FixtureState) } 'directory cannot be replaced by a checkpoint'
Assert-Throws { Write-RepairDeploymentState ($statePath + ':alternate') (New-FixtureState) } 'alternate data stream is not an ordinary checkpoint file'
$originalBytes = [IO.File]::ReadAllBytes($statePath)
$lock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { Assert-Throws { Write-RepairDeploymentState $statePath (New-FixtureState) } 'locked destination stops atomic replacement' } finally { $lock.Dispose() }
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -ceq [Convert]::ToBase64String($originalBytes)) 'failed replacement preserves the previous complete checkpoint'
Assert (@(Get-ChildItem -LiteralPath $logRoot -Filter '*.tmp').Count -eq 0) 'failed writes leave no partial state file'

# Execute the runner's actual checkpoint helper and transaction/cleanup tail with mock deployment.
$runnerPath = Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'
$finalizerPath = Join-Path $PSScriptRoot 'complete-model-experience-repair.ps1'
$finalizerTokens = $null; $finalizerErrors = $null
$finalizerAst = [Management.Automation.Language.Parser]::ParseFile($finalizerPath, [ref]$finalizerTokens, [ref]$finalizerErrors)
Assert ($finalizerErrors.Count -eq 0 -and $null -ne $finalizerAst) 'post-deployment finalizer parses'
$finalizerSource = Get-Content -LiteralPath $finalizerPath -Raw
foreach ($required in @('Test-InstallerExited', 'Get-DesktopLaunchEvidence', 'request wire service_tier=priority',
  "'model/list'", '-StrictVerifyOnly', '-VerifyAllBundledPluginsAvailable', 'Set-RepairAcceptanceCheckpoint',
  'VerifiedStatePath = $CheckpointPath', 'ExplicitTargetsOnly = $true', 'Confirm = $false', '[switch]$KeepArtifacts')) {
  Assert ($finalizerSource.Contains($required)) "post-deployment acceptance guard: $required"
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'runner AST parses'
$save = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-RepairCheckpoint' }, $true)
Invoke-Expression $save.Extent.Text
$mainTry = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
$tail = @($mainTry.Body.Statements | Where-Object { $_.Extent.StartOffset -ge ($mainTry.Body.Statements | Where-Object { $_.Extent.Text -eq '$cliPath = Get-CodexCli' }).Extent.StartOffset })
Assert ($tail.Count -gt 10) 'real transaction and cleanup statements extracted'
$transaction = [scriptblock]::Create('try {' + [Environment]::NewLine + (($tail | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine) + [Environment]::NewLine + '} catch ' + $mainTry.CatchClauses[0].Body.Extent.Text)
function Write-Log([string]$Message) { $script:messages += $Message }
function Get-CodexCli { 'fixture-cli' }
function Start-AndValidateCodex { param($Package, $PatchedVersion, $CliPath) $script:validationCalls++ }
function Invoke-RecoverableMsixInstall {
  param($MsixPath, $RecoveryMsixPath, $ValidateInstalledPackage, $PackageName)
  $script:transactionCalls++
  & $ValidateInstalledPackage $script:fixtureOutcome.Package
  if ($script:lockAfterAcceptance) {
    $script:fixtureLock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  }
  return $script:fixtureOutcome
}
function Remove-RepairTemporaryRoot { param($Path, $SentinelId) $script:cleanupCalls++ }
function Remove-DirectoryTreeRobust { param($Path) if ($script:failCleanup) { throw 'fixture cleanup blocked' }; $script:cleanupCalls++ }
$script:RepairStatePath = $statePath
$script:messages = @()
$script:RepairDeploymentState = New-FixtureState
$script:RepairCheckpointFailed = $false
$lock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
  Assert-Throws { Save-RepairCheckpoint } 'checkpoint failure before deployment blocks the next step'
  Save-RepairCheckpoint -AfterDeployment
  Assert $script:RepairCheckpointFailed 'checkpoint failure after deployment is reported without rollback'
} finally { $lock.Dispose() }
$package = $source; $recoveryVersion = $recovery.Version
$patchedInfo = [pscustomobject]@{ Version = $target.Version }
$patchedMsix = 'fixture-patched.msix'; $recoveryMsix = 'fixture-recovery.msix'
$tempRoot = Join-Path $root 'temp'; $tempSentinelId = 'fixture-temp'
$sentinel = Join-Path $resolvedOutputRoot '.codex-model-experience-repair'; $sentinelId = 'fixture-run'
[IO.File]::WriteAllText($sentinel, $sentinelId)
foreach ($scenario in @('success', 'cleanup-error', 'recovery', 'original-retained', 'keep-artifacts', 'predeploy-checkpoint-error', 'postdeploy-checkpoint-error')) {
  $script:RepairDeploymentState = New-FixtureState
  $script:RepairCheckpointFailed = $false
  $script:cleanupCalls = 0; $script:validationCalls = 0; $script:transactionCalls = 0; $script:messages = @()
  $script:fixtureLock = $null
  $script:lockAfterAcceptance = $scenario -eq 'postdeploy-checkpoint-error'
  $script:failCleanup = $scenario -eq 'cleanup-error'
  $failure = $null; $KeepArtifacts = $scenario -eq 'keep-artifacts'
  $ok = $scenario -notin @('recovery', 'original-retained')
  $installed = if ($ok) { $target } elseif ($scenario -eq 'recovery') { $recovery } else { $source }
  $script:fixtureOutcome = [pscustomobject]@{ Success = $ok; Recovered = -not $ok; Package = $installed; Error = 'fixture launch rejected' }
  Write-RepairDeploymentState $statePath $script:RepairDeploymentState
  if ($scenario -eq 'predeploy-checkpoint-error') {
    $script:fixtureLock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  }
  try { . $transaction } finally { if ($script:fixtureLock) { $script:fixtureLock.Dispose() } }
  $saved = Read-RepairDeploymentState $statePath
  if ($scenario -eq 'predeploy-checkpoint-error') {
    Assert ($null -ne $failure -and $script:transactionCalls -eq 0 -and $script:cleanupCalls -eq 0) 'failed pre-deployment checkpoint blocks real transaction entry'
    Assert (-not $saved.acceptancePassed) 'blocked deployment cannot persist successful acceptance'
    continue
  }
  Assert ($script:validationCalls -eq 1) "$scenario invokes validation callback"
  if ($scenario -eq 'postdeploy-checkpoint-error') {
    Assert ($null -eq $failure -and $script:cleanupCalls -eq 0 -and $script:RepairDeploymentState.acceptancePassed) 'post-deployment I/O failure keeps accepted artifacts without reporting an install failure'
    Assert ($script:RepairDeploymentState.cleanupStatus -eq 'retained-checkpoint-error' -and -not $saved.acceptancePassed) 'missing durable acceptance requires transcript review instead of silent cleanup'
    continue
  }
  Assert ($saved.acceptancePassed -eq $ok) "$scenario persists the actual acceptance result"
  if (-not $ok) {
    Assert ($null -ne $failure -and $script:cleanupCalls -eq 0) "$scenario retains artifacts and reports repair failure"
    Assert ($saved.stage -eq 'failed') "$scenario does not record patch success"
  } elseif ($scenario -eq 'cleanup-error') {
    Assert ($null -eq $failure -and $saved.stage -eq 'cleanup-failed' -and $saved.cleanupStatus -eq 'failed') 'cleanup error preserves successful acceptance without an install-failure exit'
  } elseif ($KeepArtifacts) {
    Assert ($script:cleanupCalls -eq 0 -and $saved.cleanupStatus -eq 'retained-requested') 'KeepArtifacts retains builds without a cleanup failure'
  } else {
    Assert ($null -eq $failure -and $script:cleanupCalls -eq 2 -and $saved.cleanupStatus -eq 'removed') 'success records verified completion after guarded cleanup'
  }
}

# Exercise the public read-only command with real process identity and a fixture package query.
function Get-AppxPackage { [CmdletBinding()]param($Name) return $target }
Write-RepairDeploymentState $statePath (New-FixtureState)
$query = & (Join-Path $PSScriptRoot 'get-model-experience-repair-status.ps1') -StatePath $statePath -Json | ConvertFrom-Json
Assert ($query.Status -eq 'installer-running' -and -not $query.AcceptancePassed) 'public JSON query reads state and verifies the real installer process'
$exitedState = New-FixtureState
$exitedState.installerPid = [int]::MaxValue
Write-RepairDeploymentState $statePath $exitedState
$beforeQuery = [IO.File]::ReadAllText($statePath)
$query = & (Join-Path $PSScriptRoot 'get-model-experience-repair-status.ps1') -StatePath $statePath -Json | ConvertFrom-Json
Assert ($query.Status -eq 'installed-needs-verification' -and -not $query.InstallerRunning) 'public query recognizes a missing process without inventing acceptance'
Assert ([IO.File]::ReadAllText($statePath) -ceq $beforeQuery) 'public query leaves the checkpoint unchanged'
Write-Host "Repair deployment state tests passed: $script:checks checks. Fixtures: $root"
