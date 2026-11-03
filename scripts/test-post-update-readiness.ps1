[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
. (Join-Path $sourceRoot 'lib\post-update-readiness.ps1')
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('update-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
function Write-Fixture([string]$RelativePath, [string]$Text) {
  $path = Join-Path $root $RelativePath
  New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
  [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'codex-after-update.ps1') -Destination $root
Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\post-update-readiness.ps1') -Destination (Join-Path $root 'lib')
Write-Fixture 'probe-repair-models.cjs' 'process.stdout.write(JSON.stringify({defaultModel:"fixture-new",customModels:["fixture-new","future-model"],models:[{model:"fixture-new",reasoningEfforts:["ultra"],serviceTiers:["priority"]}]}));'
Write-Fixture 'OpenAI\Codex\bin\fixture\codex.exe' 'unused executable marker'
Write-Fixture 'get-model-experience-repair-status.ps1' @'
param($StatePath,[switch]$Json)
Get-Content -LiteralPath $StatePath -Raw
'@
Write-Fixture 'install-computer-use-local.ps1' @'
param([switch]$StrictVerifyOnly,[switch]$VerifyOnly,[switch]$VerifyAllBundledPluginsAvailable)
$status=Join-Path $PSScriptRoot 'plugin-broken'
if($VerifyOnly){[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'plugin-repaired'),'yes');[IO.File]::Delete($status)}
if(Test-Path -LiteralPath $status){exit 7};exit 0
'@
Write-Fixture 'start-model-experience-repair.ps1' @'
param([string[]]$CustomModels)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'installer-called'),($CustomModels -join ','))
'@
Write-Fixture 'complete-model-experience-repair.ps1' @'
param([string]$StatePath)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'finalizer-called'),$StatePath);exit 0
'@
$features = @('fast-mode', 'fast-mode UI', 'custom models', 'Power slider', 'Ultra slider local-fallback', 'locale i18n',
  'plugin', 'goal', 'browser-use gate', 'computer-use gate', 'Node REPL trusted-paths', 'Node REPL proxy environment',
  'Windows CUA surface', 'bundled marketplace copy')
$healthy = ($features | ForEach-Object { '[codex-msix-patch-win] ' + $_ + ' patch result: already-patched' }) -join "`n"
$nativeHealthy = $healthy.Replace('Windows CUA surface patch result: already-patched', 'Windows CUA surface patch result: already-open-native-windows')
if ((Get-PostUpdatePatchAssessment $nativeHealthy $true).Status -ne 'present') { throw 'Native Windows healthy layout rejected' }
if ((Get-PostUpdatePatchAssessment ($healthy + "`n" + $healthy) $true).Status -ne 'unsupported') { throw 'Duplicate patch report accepted' }
if ((Get-PostUpdatePatchAssessment ($healthy.Replace('locale i18n patch result: already-patched', 'locale i18n patch result: unknown')) $true).Status -ne 'unsupported') { throw 'Unknown patch state accepted' }
$noUltra = $healthy.Replace('Ultra slider local-fallback patch result: already-patched', 'Ultra slider local-fallback patch result: not-applicable')
if ((Get-PostUpdatePatchAssessment $noUltra $true).Status -ne 'unsupported') { throw 'Missing Ultra passed for an Ultra catalog' }
if ((Get-PostUpdatePatchAssessment $noUltra $false).Status -ne 'present') { throw 'A catalog without Ultra requires no Ultra patch' }
Write-Fixture 'patch-report.txt' $healthy
Write-Fixture 'patch_codex_fast_mode_windows_msix.ps1' @'
param($AppPath,$OutputRoot,$AsarWorkRoot,[string[]]$CustomModels,[switch]$DryRun)
if(-not $DryRun){throw 'Fixture refuses deployment'}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'diagnostic-models'),($CustomModels -join ','))
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'patch-report.txt') | ForEach-Object {Write-Host $_}
exit 0
'@
$logRoot = Join-Path $root 'logs'
$checkRoot = Join-Path $root 'checks'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$script:fixturePackageName = 'OpenAI.Codex_1.2.3.0_x64__fixture'
function Get-AppxPackage {
  param([string]$Name)
  [pscustomobject]@{PackageFullName='OpenAI.Codex_1.2.3.0_x64__fixture';Version=[version]'1.2.3.0';Status='Ok';InstallLocation=(Join-Path $root 'package')}
}
function Read-Result {
  param([hashtable]$Options = @{})
  $result = & (Join-Path $root 'codex-after-update.ps1') -LogRoot $logRoot -CheckRoot $checkRoot @Options
  return ($result -join "`n") | ConvertFrom-Json
}
function Set-State([string]$Status) { Write-Fixture 'logs\fixture.state.json' (@{Status=$Status} | ConvertTo-Json) }
function Remove-Marker([string]$Name) { [IO.File]::Delete((Join-Path $root $Name)) }
function Require([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
$previousLocalAppData = $env:LOCALAPPDATA
try {
  $env:LOCALAPPDATA = $root
  $result = Read-Result
  Require ($result.package -eq 'OpenAI.Codex_1.2.3.0_x64__fixture') 'Package identity was lost'
  Require ($result.status -eq 'app-check-needed') 'Unknown new package was claimed healthy'
  Require (-not(Test-Path -LiteralPath $checkRoot)) 'Default check created a build'
  $result = Read-Result @{CheckApp=$true}
  Require ($result.status -eq 'verified-contracts') 'Healthy dry-run rejected'
  Require ((Get-Content -LiteralPath (Join-Path $root 'diagnostic-models') -Raw) -eq 'fixture-new,future-model') 'Live catalog models were lost'
  Require (@(Get-ChildItem -LiteralPath $checkRoot -Force).Count -eq 0) 'Diagnostic scratch leaked'
  $result = Read-Result @{RepairApp=$true}
  Require ($result.status -eq 'verified-contracts') 'Already patched application requested deployment'
  Require (-not(Test-Path -LiteralPath (Join-Path $root 'installer-called'))) 'Already patched application was redeployed'
  $result = Read-Result @{CheckApp=$true;CustomModels=@('explicit-model')}
  Require ((Get-Content -LiteralPath (Join-Path $root 'diagnostic-models') -Raw) -eq 'explicit-model') 'Explicit model override was ignored'
  $changed = $healthy.Replace('locale i18n patch result: already-patched', 'locale i18n patch result: patched')
  Write-Fixture 'patch-report.txt' $changed
  $result = Read-Result @{CheckApp=$true}
  Require ($result.status -eq 'app-repair-needed') 'Lost locale patch was not detected'
  $result = Read-Result @{RepairApp=$true;WhatIf=$true}
  Require (-not(Test-Path -LiteralPath (Join-Path $root 'installer-called'))) 'WhatIf launched an installer'
  $result = Read-Result @{RepairApp=$true}
  Require ($result.status -eq 'awaiting-installation-and-acceptance') 'Dispatch was reported as completed acceptance'
  Require ((Get-Content -LiteralPath (Join-Path $root 'installer-called') -Raw) -eq 'fixture-new,future-model') 'Installer lost active models'
  Remove-Marker 'installer-called'
  Write-Fixture 'patch-report.txt' ($changed.Replace('locale i18n patch result: patched','locale i18n patch result: unfamiliar'))
  $result = Read-Result @{RepairApp=$true}
  Require ($result.status -eq 'unsupported-app-layout') 'Unknown layout was not rejected'
  Require (-not(Test-Path -LiteralPath (Join-Path $root 'installer-called'))) 'Unknown layout launched an installer'
  Write-Fixture 'patch-report.txt' $healthy
  Set-State 'verified-complete'
  $result = Read-Result
  Require ($result.status -eq 'verified-contracts') 'Accepted current package was forgotten'
  Require ($result.app.Status -eq 'accepted-checkpoint') 'Historical package acceptance was confused with a fresh bundle check'
  Write-Fixture 'plugin-broken' 'yes'
  $result = Read-Result
  Require ($result.status -eq 'plugin-repair-needed') 'Plugin failure was hidden by old acceptance'
  $result = Read-Result @{RepairPlugins=$true}
  Require ($result.status -eq 'verified-contracts') 'Plugin repair was not separately verified'
  Require (-not(Test-Path -LiteralPath (Join-Path $root 'installer-called'))) 'Plugin repair deployed an app'
  foreach ($busy in @('installer-running','installer-status-unknown','different-user')) {
    Set-State $busy
    $result = Read-Result @{RepairPlugins=$true;RepairApp=$true}
    Require ($result.status -eq 'installer-busy-or-unknown') 'Busy or unknown installer was ignored'
    Require (-not(Test-Path -LiteralPath (Join-Path $root 'installer-called'))) 'A second installer was launched'
  }
  Set-State 'installed-needs-verification'
  Write-Fixture 'plugin-broken' 'yes'
  $result = Read-Result @{RepairApp=$true;RepairPlugins=$true}
  Require ($result.action -eq 'existing-installation-finalized') 'Pending installation was not resumed'
  Require (-not(Test-Path -LiteralPath (Join-Path $root 'plugin-broken'))) 'Pending acceptance skipped requested plugin refresh'
  Require (-not(Test-Path -LiteralPath (Join-Path $root 'installer-called'))) 'Pending installation was redeployed'
  Set-State 'verified-complete'
  $reportPath = Join-Path $root 'public-report.json'
  $result = Read-Result @{ReportPath=$reportPath}
  Require (Test-Path -LiteralPath $reportPath) 'Explicit report was not written'
  $oldHash = (Get-FileHash -LiteralPath $reportPath).Hash
  $refused = $false
  try { $null = Read-Result @{ReportPath=$reportPath} } catch { $refused = $_.Exception.Message -like '*already exists*' }
  Require $refused 'Existing report was overwritten'
  Require ((Get-FileHash -LiteralPath $reportPath).Hash -eq $oldHash) 'Existing report contents changed'
  Write-Fixture 'logs\invalid.state.json' 'invalid json'
  $refused = $false
  try { $null = Read-Result @{RepairApp=$true} } catch { $refused = $true }
  Require $refused 'Malformed installer state was ignored'
} finally { $env:LOCALAPPDATA = $previousLocalAppData }
Write-Output "Post-update public workflow and guard regressions passed: $root"
