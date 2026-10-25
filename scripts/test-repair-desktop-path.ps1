param([Parameter(Mandatory)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1')
foreach ($entry in @(@('complete-model-experience-repair.ps1','Get-DesktopLaunchEvidence'), @('cleanup-model-experience-repair-artifacts.ps1','Get-CurrentCodexDesktopProcess'))) {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $entry[0]),[ref]$tokens,[ref]$errors)
  $definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -EQ $entry[1])
  if ($errors.Count -or $definition.Count -ne 1) { throw 'Helper import failed' }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
$root=Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('desktop-path-' + [guid]::NewGuid().ToString('N'))
$physical=Join-Path $root 'physical'
$link=Join-Path $root 'registered'
$null=New-Item -ItemType Directory -Path (Join-Path $physical 'app') -Force
[IO.File]::WriteAllText((Join-Path $physical 'app\ChatGPT.exe'),'fixture')
$null=New-Item -ItemType Junction -Path $link -Target $physical
$package=[pscustomobject]@{InstallLocation=$link}
$state=[pscustomobject]@{sessionId=1;installerStartedUtc=[datetime]::UtcNow.AddMinutes(-2)}
$script:candidate=[pscustomobject]@{Id=123;Path=(Join-Path $physical 'app\ChatGPT.exe');MainWindowHandle=1;Responding=$true;SessionId=1;StartTime=[datetime]::UtcNow.AddMinutes(-1)}
function Get-Process { param($Name,$ErrorAction) return $script:candidate }
function Reject([scriptblock]$Action) { $failed=$false;try { & $Action | Out-Null } catch { $failed=$true }; if (-not $failed) { throw 'Expected acceptance rejection' } }
try {
  if ((Get-DesktopLaunchEvidence $state $package).Id -ne 123 -or (Get-CurrentCodexDesktopProcess $package).Id -ne 123) { throw 'Registered junction did not match physical executable' }
  $script:candidate.Responding=$false
  Reject { Get-DesktopLaunchEvidence $state $package }
  Reject { Get-CurrentCodexDesktopProcess $package }
  $script:candidate.Responding=$true
  $script:candidate.SessionId=2
  Reject { Get-DesktopLaunchEvidence $state $package }
  $script:candidate.SessionId=1
  $other=Join-Path $root 'other.exe'
  [IO.File]::WriteAllText($other,'fixture')
  $script:candidate.Path=$other
  Reject { Get-DesktopLaunchEvidence $state $package }
  Reject { Get-CurrentCodexDesktopProcess $package }
  Write-Host 'DESKTOP_PHYSICAL_PATH_PASSED: junction, unrelated file, responsiveness, session guards'
} finally {
  # Remove the junction itself before deleting the owned fixture tree.
  [IO.Directory]::Delete($link)
  if ((Split-Path -Parent $root) -ine [IO.Path]::GetFullPath($TemporaryRoot)) { throw 'Fixture boundary changed' }
  Remove-Item -LiteralPath $root -Recurse -Force
}
