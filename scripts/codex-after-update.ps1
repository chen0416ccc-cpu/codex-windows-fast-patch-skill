[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$CheckApp,
  [switch]$RepairPlugins,
  [switch]$RepairApp,
  [string[]]$CustomModels,
  [string]$ReportPath,
  [string]$LogRoot = 'D:\CodexData\codex-windows-fast-patch\model-experience-repair-logs',
  [string]$CheckRoot = (Join-Path ([IO.Path]::GetTempPath()) 'codex-update-checks')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\post-update-readiness.ps1')
$statusScript = Join-Path $PSScriptRoot 'get-model-experience-repair-status.ps1'
$pluginScript = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$patcherScript = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$launcherScript = Join-Path $PSScriptRoot 'start-model-experience-repair.ps1'
$finalizerScript = Join-Path $PSScriptRoot 'complete-model-experience-repair.ps1'
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-PluginCheck {
  param([switch]$Repair)
  $mode = if ($Repair) { '-VerifyOnly' } else { '-StrictVerifyOnly' }
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    # Do not merge native stderr into a Stop pipeline under PowerShell 5.1.
    & $powershellExe -NoProfile -ExecutionPolicy RemoteSigned -File $pluginScript $mode -VerifyAllBundledPluginsAvailable | Out-Host
    return [int]$LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
}

function Invoke-PackageGateCheck {
  param([string]$AppPath, [string[]]$Models, [bool]$HasUltraModels)
  $parent = [IO.Path]::GetFullPath($CheckRoot)
  New-Item -ItemType Directory -Force -Path $parent -WhatIf:$false | Out-Null
  $scratch = Join-Path $parent ('check-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $scratch -WhatIf:$false | Out-Null
  $sentinel = Join-Path $scratch '.codex-readonly-update-check'
  $sentinelValue = [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($sentinel, $sentinelValue)
  try {
    $stdout = Join-Path $scratch 'stdout.log'
    $stderr = Join-Path $scratch 'stderr.log'
    $payload = @{ Patcher = $patcherScript; App = $AppPath; Output = (Join-Path $scratch 'build'); Work = $scratch; Models = @($Models) } |
      ConvertTo-Json -Compress -Depth 4
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
try {
  & $p.Patcher -AppPath $p.App -OutputRoot $p.Output -AsarWorkRoot $p.Work -CustomModels @($p.Models) -DryRun 6>&1 |
    ForEach-Object { [Console]::Out.WriteLine([string]$_) }
  exit $LASTEXITCODE
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap.Replace('__PAYLOAD__', $payloadBase64)))
    $diagnosticProcessOptions = @{}
    if ((Get-Command Start-Process).Parameters.ContainsKey('WhatIf')) { $diagnosticProcessOptions.WhatIf = $false }
    $process = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile', '-OutputFormat', 'Text',
      '-ExecutionPolicy', 'RemoteSigned', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru -Wait @diagnosticProcessOptions `
      -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ((Get-Item -LiteralPath $stdout).Length -gt 32MB -or (Get-Item -LiteralPath $stderr).Length -gt 32MB) {
      throw 'Package gate diagnostic exceeded its log limit.'
    }
    $text = [IO.File]::ReadAllText($stdout) + [Environment]::NewLine + [IO.File]::ReadAllText($stderr)
    if ($process.ExitCode -ne 0) {
      return [pscustomobject]@{ Status = 'unsupported'; Results = @{}; Reason = 'Full package dry run failed. Review the current source layout before repair.' }
    }
    return Get-PostUpdatePatchAssessment -LogText $text -HasUltraModels $HasUltraModels
  } finally {
    # Only this call's exact ordinary directory can be removed. Never sweep a
    # user-supplied CheckRoot, another attempt, or a junction target.
    $full = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path -Parent $full) -ine $parent.TrimEnd('\') -or
        (Get-Content -LiteralPath $sentinel -Raw) -cne $sentinelValue) { throw 'Diagnostic cleanup sentinel mismatch; scratch retained.' }
    $items = @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
      throw 'Diagnostic scratch contains a reparse point; retained for inspection.'
    }
    Remove-Item -LiteralPath $full -Recurse -Force -WhatIf:$false
  }
}

function Write-UpdateReport {
  param([object]$Report)
  $json = $Report | ConvertTo-Json -Depth 10
  if ($ReportPath -and $PSCmdlet.ShouldProcess($ReportPath, 'Save update diagnostic report')) {
    $full = [IO.Path]::GetFullPath($ReportPath)
    if (Test-Path -LiteralPath $full) { throw 'ReportPath already exists; choose a new report path.' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
    [IO.File]::WriteAllText($full, $json, [Text.UTF8Encoding]::new($false))
  }
  Write-Output $json
}

foreach ($scope in @('Process', 'User', 'Machine')) {
  if ([Environment]::GetEnvironmentVariable('CODEX_HOME', $scope)) {
    throw "CODEX_HOME is set at $scope scope; refusing to inspect Desktop using an isolated CLI home."
  }
}
$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
if (-not $package -or [string]$package.Status -ne 'Ok') { throw 'No healthy current-user Codex package is registered.' }
$report = [ordered]@{
  schemaVersion = 1; package = $package.PackageFullName; status = 'checking'; transaction = $null
  models = $null; pluginExitCode = $null; app = $null; action = 'none'
  limits = @('Package/CLI/runtime contracts only; visible menus, native screenshot/input and upstream speed are not verified.')
}
$transaction = Get-PostUpdateTransaction -LogRoot $LogRoot -StatusScript $statusScript
$transactionStatus = if ($transaction) { [string]$transaction.Assessment.Status } else { '' }
if ($transaction) { $report.transaction = @{ status = $transactionStatus; statePath = $transaction.StatePath } }
if ($transactionStatus -in @('installer-running', 'installer-status-unknown', 'different-user')) {
  $report.status = 'installer-busy-or-unknown'; Write-UpdateReport $report; return
}
if ($transactionStatus -in @('installed-needs-verification', 'verified-cleanup-needed')) {
  $report.status = 'resume-verification'
  if ($RepairApp -and $PSCmdlet.ShouldProcess($transaction.StatePath, 'Complete the existing installation without redeployment')) {
    if ($RepairPlugins) {
      $pluginExit = Invoke-PluginCheck
      if ($pluginExit -ne 0 -and $PSCmdlet.ShouldProcess($package.PackageFullName, 'Refresh local plugins before existing-installation acceptance')) {
        $pluginExit = Invoke-PluginCheck -Repair
        if ($pluginExit -eq 0) { $pluginExit = Invoke-PluginCheck }
      }
      if ($pluginExit -ne 0) { throw 'Plugin refresh/verification failed; the pending installation was not redeployed or marked accepted.' }
      $report.pluginExitCode = $pluginExit
    }
    & $powershellExe -NoProfile -ExecutionPolicy RemoteSigned -File $finalizerScript -StatePath $transaction.StatePath | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Existing installation acceptance did not pass; no new installer was started.' }
    $report.action = 'existing-installation-finalized'
    $report.status = 'verified-contracts'
  }
  Write-UpdateReport $report; return
}
try { $inventory = Get-RepairModelInventory; $report.models = $inventory } catch {
  $report.status = 'model-probe-failed'; Write-UpdateReport $report
  if ($RepairApp) { throw 'Model capabilities are unknown; no installation was started.' }
  return
}
if (-not $PSBoundParameters.ContainsKey('CustomModels')) { $CustomModels = @($inventory.customModels) }
if (@($CustomModels).Count -eq 0) { throw 'CustomModels must not be empty.' }
$pluginExit = Invoke-PluginCheck
if ($pluginExit -ne 0 -and $RepairPlugins -and $PSCmdlet.ShouldProcess($package.PackageFullName, 'Repair local plugin/version drift')) {
  $pluginExit = Invoke-PluginCheck -Repair
  if ($pluginExit -eq 0) { $pluginExit = Invoke-PluginCheck }
  $report.action = 'plugin-repair-attempted'
}
$report.pluginExitCode = $pluginExit
$app = [pscustomobject]@{ Status = 'not-checked'; Results = @{}; Reason = 'No accepted repair checkpoint for the current package. Use -CheckApp or -RepairApp.' }
if ($transactionStatus -eq 'verified-complete') {
  $app = [pscustomobject]@{ Status = 'accepted-checkpoint'; Results = @{}; Reason = 'The exact current package has accepted deployment evidence; bundle gates were not rechecked in this invocation. Use -CheckApp to recheck.' }
}
if ($CheckApp -or $RepairApp) {
  $hasUltra = @($inventory.models | Where-Object { (-not $_.hidden -or $_.isDefault) -and @($_.reasoningEfforts) -contains 'ultra' }).Count -gt 0
  $app = Invoke-PackageGateCheck -AppPath (Join-Path $package.InstallLocation 'app') -Models $CustomModels -HasUltraModels $hasUltra
}
$report.app = $app
$report.status = Get-PostUpdateDecision -TransactionStatus $transactionStatus -PluginExitCode $pluginExit -AppStatus $app.Status -ModelProbePassed $true
if ($RepairApp -and $report.status -eq 'app-repair-needed') {
  # Repeat the transaction/package checks immediately before dispatch. The
  # launcher also independently checks current installer identity and source.
  $latest = Get-PostUpdateTransaction -LogRoot $LogRoot -StatusScript $statusScript
  if ($latest -and $latest.Assessment.Status -in @('installer-running', 'installer-status-unknown', 'installed-needs-verification', 'verified-cleanup-needed', 'different-user')) {
    throw 'An existing repair appeared during diagnostics; inspect it before launching.'
  }
  $current = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
  if ($current.PackageFullName -cne $package.PackageFullName) { throw 'The package changed during diagnostics; rerun against the new version.' }
  if ($PSCmdlet.ShouldProcess($package.PackageFullName, 'Start the recoverable full non-phone repair (UAC and Desktop restart)')) {
    & $launcherScript -CustomModels $CustomModels
    $report.action = 'installer-dispatched'
    $report.status = 'awaiting-installation-and-acceptance'
  }
}
Write-UpdateReport $report
