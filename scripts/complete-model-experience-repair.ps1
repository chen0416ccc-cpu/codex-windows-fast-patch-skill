[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$StatePath,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1')

function Test-InstallerExited {
  param([object]$State)
  try {
    $process = Get-Process -Id ([int]$State.installerPid) -ErrorAction Stop
  } catch {
    if (Test-RepairProcessNotFoundError -ErrorRecord $_) { return $true }
    throw "Installer process status is unknown; acceptance is not recorded: $($_.Exception.Message)"
  }
  $expectedStart = ConvertTo-RepairUtcDateTime $State.installerStartedUtc
  if ([int]$process.SessionId -eq [int]$State.sessionId -and
      $process.StartTime.ToUniversalTime().Ticks -eq $expectedStart.Ticks) {
    throw "The repair installer is still running: pid=$($process.Id)"
  }
  return $true
}

function Get-DesktopLaunchEvidence {
  param([object]$State, [object]$Package)
  $expectedPath = Resolve-RepairPhysicalPath (Join-Path $Package.InstallLocation 'app\ChatGPT.exe')
  $installerStart = ConvertTo-RepairUtcDateTime $State.installerStartedUtc
  $process = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
    Where-Object {
      ($_.Path -and (Resolve-RepairPhysicalPath $_.Path) -ieq $expectedPath) -and $_.MainWindowHandle -ne 0 -and $_.Responding -and
      [int]$_.SessionId -eq [int]$State.sessionId -and
      $_.StartTime.ToUniversalTime() -ge $installerStart
    } |
    Sort-Object StartTime -Descending |
    Select-Object -First 1
  if (-not $process) { throw "A launched Codex Desktop window from the exact target package was not found: $expectedPath" }
  return $process
}

function Get-CodexCliPath {
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  $cli = Get-ChildItem -LiteralPath $binRoot -Recurse -Filter codex.exe -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $cli) { throw "A user-local Codex CLI was not found under $binRoot" }
  return $cli.FullName
}

function Test-ModelListFastTiers {
  param([string]$CliPath)
  $node = Get-Command node.exe -ErrorAction Stop | Select-Object -First 1
  $probe = @'
const { spawn } = require('child_process');
const nl = String.fromCharCode(10);
const child = spawn(process.argv[2], ['app-server', '--stdio'], { stdio: ['pipe', 'pipe', 'ignore'] });
let buffer = ''; let nextId = 1; const pending = new Map();
child.stdout.on('data', chunk => {
  buffer += chunk.toString();
  for (;;) {
    const newline = buffer.indexOf(nl);
    if (newline < 0) break;
    const line = buffer.slice(0, newline).trim(); buffer = buffer.slice(newline + 1);
    try {
      const message = JSON.parse(line);
      if (message.id !== undefined && pending.has(message.id)) {
        const settle = pending.get(message.id); pending.delete(message.id);
        message.error ? settle.reject(new Error(message.error.message)) : settle.resolve(message.result);
      }
    } catch {}
  }
});
function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(method + ' timed out')), 20000);
    pending.set(id, {
      resolve: value => { clearTimeout(timer); resolve(value); },
      reject: error => { clearTimeout(timer); reject(error); }
    });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + nl);
  });
}
(async () => {
  try {
    await request('initialize', {
      clientInfo: { name: 'model-experience-post-deploy-check', version: '1.0.0' },
      capabilities: { experimentalApi: true }
    });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'initialized', params: {} }) + nl);
    const response = await request('model/list', { includeHidden: true, limit: 200 });
    const models = response.data || response.models || [];
    const selected = models.find(model => model.isDefault);
    const serviceTiers = selected?.serviceTiers?.map(tier => tier.id) || [];
    if (!selected || !serviceTiers.includes('priority')) throw new Error('default model does not expose priority');
    const visibleModels = models.filter(model => !model.hidden).map(model => ({
      id: model.id,
      serviceTiers: (model.serviceTiers || []).map(tier => tier.id)
    }));
    const ultrafastModels = visibleModels.filter(model => model.serviceTiers.includes('ultrafast')).map(model => model.id);
    process.stdout.write(JSON.stringify({ model: selected.id, serviceTiers, visibleModels, ultrafastModels }));
  } catch (error) {
    process.stderr.write(String(error?.message || error));
    process.exitCode = 1;
  } finally {
    child.kill();
  }
})();
'@
  $probePath = Join-Path (Split-Path -Parent $StatePath) ('model-list-probe-' + [guid]::NewGuid().ToString('N') + '.cjs')
  [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $result = @(& $node.Source $probePath $CliPath 2>&1)
    $probeExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    [IO.File]::Delete($probePath)
  }
  if ($probeExitCode -ne 0) { throw "app-server model/list verification failed: $($result -join ' ')" }
  $parsed = (($result -join '').Trim()) | ConvertFrom-Json -ErrorAction Stop
  if (-not $parsed.model -or @($parsed.serviceTiers) -notcontains 'priority') {
    throw "Unexpected model/list verification response: $($result -join '')"
  }
  return $parsed
}

function Invoke-StrictComputerUseVerification {
  param([string]$EvidenceBase)
  $strictScript = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
  $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $strictScript -PathType Leaf) -or -not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
    throw 'Strict verification prerequisites are missing.'
  }
  $stdoutPath = $EvidenceBase + '.strict.stdout.log'
  $stderrPath = $EvidenceBase + '.strict.stderr.log'
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $strictScript,
    '-StrictVerifyOnly', '-VerifyAllBundledPluginsAvailable')
  $process = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  if ($process.ExitCode -ne 0) {
    $detail = @((Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) +
      (Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)) -join [Environment]::NewLine
    throw "Strict installed-package verification failed with exit code $($process.ExitCode): $detail"
  }
  return [pscustomobject]@{ ExitCode = $process.ExitCode; StdoutPath = $stdoutPath; StderrPath = $stderrPath }
}

function Invoke-ExactRunCleanup {
  param([string]$CheckpointPath)
  $cleanupScript = Join-Path $PSScriptRoot 'cleanup-model-experience-repair-artifacts.ps1'
  if (-not (Test-Path -LiteralPath $cleanupScript -PathType Leaf)) { throw 'Exact-run cleanup script is missing.' }
  $cleanupParameters = @{
    Clean = $true
    ExplicitTargetsOnly = $true
    DataRoot = 'D:\CodexData\codex-windows-fast-patch'
    VerifiedStatePath = $CheckpointPath
    Confirm = $false
  }
  & $cleanupScript @cleanupParameters
}

$state = Read-RepairDeploymentState $StatePath
if ($state.acceptancePassed) {
  if ($state.stage -notin @('cleanup-pending', 'cleanup-failed') -or $state.cleanupStatus -notin @('pending', 'failed')) {
    throw 'This repair already has a completed acceptance and no pending exact-run cleanup.'
  }
  try {
    Invoke-ExactRunCleanup -CheckpointPath $StatePath
  } catch {
    $state = Read-RepairDeploymentState $StatePath
    $state.stage = 'cleanup-failed'
    $state.cleanupStatus = 'failed'
    Write-RepairDeploymentState -Path $StatePath -State $state
    throw "Acceptance remains passed; exact-run cleanup is still pending: $($_.Exception.Message)"
  }
  $state = Read-RepairDeploymentState $StatePath
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
    Sort-Object Version -Descending | Select-Object -First 1
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $assessment = Get-RepairDeploymentAssessment -State $state -CurrentPackage $package -InstallerProcess $null -CurrentUserSid $sid
  if ($assessment.Status -ne 'verified-complete') { throw "Exact-run cleanup did not complete: $($assessment.Status)" }
  Write-Output "VERIFIED_COMPLETE package=$($package.PackageFullName) state=$StatePath"
  exit 0
}
if ($state.stage -notin @('deploying', 'verifying')) { throw "Repair stage is not eligible for post-deployment acceptance: $($state.stage)" }

$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
  Sort-Object Version -Descending | Select-Object -First 1
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not $package -or [string]$package.Status -ne 'Ok') { throw 'No healthy current Codex package is registered.' }
$assessment = Get-RepairDeploymentAssessment -State $state -CurrentPackage $package -InstallerProcess $null -CurrentUserSid $sid
if ($assessment.Status -ne 'installed-needs-verification') {
  throw "Current package is not the pending target for this user: $($assessment.Status)"
}
$installerExited = Test-InstallerExited $state
$desktopProcess = Get-DesktopLaunchEvidence -State $state -Package $package
$transcript = Get-Item -LiteralPath $state.transcriptPath -Force -ErrorAction Stop
if ($transcript.Attributes -band [IO.FileAttributes]::ReparsePoint -or $transcript.Length -gt 32MB) {
  throw 'Repair transcript is not a bounded ordinary file; acceptance evidence was retained.'
}
$fastWirePassed = Select-String -LiteralPath $state.transcriptPath -SimpleMatch `
  'fast verification: request wire service_tier=priority' -Quiet
if (-not $fastWirePassed) { throw 'The repair transcript lacks a passing Fast request wire capture.' }

$cliPath = Get-CodexCliPath
$modelList = Test-ModelListFastTiers -CliPath $cliPath
$evidenceBase = $StatePath + '.finalization'
$strict = Invoke-StrictComputerUseVerification -EvidenceBase $evidenceBase
$evidence = [ordered]@{
  verifiedUtc = [DateTime]::UtcNow.ToString('o')
  currentPackageFullName = [string]$package.PackageFullName
  packageStatus = [string]$package.Status
  installerExited = $installerExited
  desktopProcessId = [int]$desktopProcess.Id
  desktopProcessStartUtc = $desktopProcess.StartTime.ToUniversalTime().ToString('o')
  fastWirePassed = [bool]$fastWirePassed
  modelList = $modelList
  strictVerificationExitCode = $strict.ExitCode
  strictStdoutPath = $strict.StdoutPath
  strictStderrPath = $strict.StderrPath
}
$evidencePath = $StatePath + '.final-verification.json'
[IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Set-RepairAcceptanceCheckpoint -State $state -CurrentPackageFullName $package.PackageFullName `
  -InstallerExited $installerExited -DesktopLaunchPassed ($desktopProcess.MainWindowHandle -ne 0) `
  -FastWirePassed $fastWirePassed -ModelList $modelList -StrictVerificationPassed ($strict.ExitCode -eq 0)
if ($KeepArtifacts) {
  $state.cleanupStatus = 'retained-requested'
  $state.stage = 'verified-complete'
  Write-RepairDeploymentState -Path $StatePath -State $state
  Write-Output "VERIFIED_COMPLETE artifacts-retained state=$StatePath evidence=$evidencePath"
  exit 0
}
Write-RepairDeploymentState -Path $StatePath -State $state

try {
  Invoke-ExactRunCleanup -CheckpointPath $StatePath
} catch {
  $state = Read-RepairDeploymentState $StatePath
  if ($state.acceptancePassed) {
    $state.stage = 'cleanup-failed'
    $state.cleanupStatus = 'failed'
    Write-RepairDeploymentState -Path $StatePath -State $state
  }
  throw "Acceptance remains passed; exact-run cleanup is still pending: $($_.Exception.Message)"
}

$finalState = Read-RepairDeploymentState $StatePath
$finalAssessment = Get-RepairDeploymentAssessment -State $finalState -CurrentPackage $package -InstallerProcess $null -CurrentUserSid $sid
if ($finalAssessment.Status -ne 'verified-complete') { throw "Final deployment state did not complete: $($finalAssessment.Status)" }
Write-Output "VERIFIED_COMPLETE package=$($package.PackageFullName) model=$($modelList.model) tiers=$($modelList.serviceTiers -join ',') evidence=$evidencePath"
