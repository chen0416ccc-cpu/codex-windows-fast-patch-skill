[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\repair-storage.ps1')
. (Join-Path $PSScriptRoot 'lib\post-update-readiness.ps1')
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  $threw = $false
  try { & $Action | Out-Null } catch { $threw = $true }
  Assert $threw $Message
}
$c = [pscustomobject]@{ Root = 'C:\'; AvailableFreeSpace = 90GB }
$d = [pscustomobject]@{ Root = 'D:\'; AvailableFreeSpace = 10GB }
$e = [pscustomobject]@{ Root = 'E:\'; AvailableFreeSpace = 120GB }
Assert ((Select-RepairStorageDrive -Drives @($c, $d, $e)) -eq 'E:\') 'largest free space must win, not the original D: preference'
Assert ((Select-RepairStorageDrive -Drives @($c, $d)) -eq 'C:\') 'C: is usable when it has more free space'
Assert ((Select-RepairStorageDrive -Drives @($c)) -eq 'C:\') 'a machine without D: must work'
Assert-Throws { Select-RepairStorageDrive -Drives @() } 'no eligible disk must fail before installation'
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('storage-fixture-' + [guid]::NewGuid().ToString('N'))
$oldOverride = $env:CODEX_WINDOWS_REPAIR_DATA_ROOT
try {
  $env:CODEX_WINDOWS_REPAIR_DATA_ROOT = $null
  $layout = Get-RepairStorageLayout -DataRoot (Join-Path $root 'chosen data')
  Assert (-not (Test-Path -LiteralPath $root)) 'selection and discovery must not create directories'
  Assert ($layout.TemporaryRoot -eq (Join-Path ([IO.Path]::GetPathRoot($root)) 'CodexData\cwp-tmp')) 'short ASAR parent stays on the chosen volume'
  $null = Assert-RepairLocalDirectory -Path $layout.DataRoot -Create
  Assert (Test-Path -LiteralPath $layout.DataRoot) 'first-run data root is created when requested'
  $env:CODEX_WINDOWS_REPAIR_DATA_ROOT = $layout.DataRoot
  Assert ((Get-RepairStorageLayout).DataRoot -eq $layout.DataRoot) 'explicit environment override is honored'
  Assert (@(Get-RepairKnownDataRoots) -contains $layout.DataRoot) 'read-only discovery includes the configured existing root'
  foreach ($bad in @('relative\path', '\\server\share\repair', 'C:\repair:stream', 'C:\repair\..\escape', 'C:\repair.\child')) {
    Assert-Throws { Assert-RepairLocalDirectory -Path $bad -AllowMissing } 'relative, network and ambiguous paths must be rejected'
  }
  $run = Join-Path $layout.RunRoot ('20260101-010101-' + ('a' * 32))
  $checkpoint = Join-Path $layout.LogRoot 'fixture.transcript.txt.state.json'
  Assert ((Get-RepairDataRootFromRunPath $run) -eq $layout.DataRoot) 'resume derives the root from the original run'
  Assert ((Get-RepairDataRootFromStatePath $checkpoint) -eq $layout.DataRoot) 'finalization derives the root from its checkpoint'
  Assert-Throws { Get-RepairDataRootFromRunPath (Join-Path $layout.DataRoot 'unrelated') } 'resume must not admit an unrelated directory'
  Assert-Throws { Get-RepairDataRootFromStatePath (Join-Path $layout.DataRoot 'fixture.state.json') } 'finalization must not admit an unrelated checkpoint'
  $file = Join-Path $layout.DataRoot 'file-ancestor'
  [IO.File]::WriteAllText($file, 'fixture')
  Assert-Throws { Assert-RepairLocalDirectory -Path (Join-Path $file 'child') -Create } 'file ancestors must not be treated as directories'
  $junction = Join-Path $layout.DataRoot 'junction'
  New-Item -ItemType Junction -Path $junction -Target $layout.DataRoot | Out-Null
  try {
    Assert-Throws { Assert-RepairLocalDirectory -Path (Join-Path $junction 'child') -AllowMissing } 'reparse ancestors must be rejected even for new child directories'
  } finally { [IO.Directory]::Delete($junction) }

  $statusScript = Join-Path $root 'status-fixture.ps1'
  [IO.File]::WriteAllText($statusScript, 'param($StatePath,[switch]$Json); Get-Content -LiteralPath $StatePath -Raw')
  $firstLogs = Join-Path $root 'old-disk-logs'
  $secondLogs = Join-Path $root 'new-disk-logs'
  New-Item -ItemType Directory -Path $firstLogs, $secondLogs | Out-Null
  $pending = Join-Path $firstLogs 'pending.state.json'
  $accepted = Join-Path $secondLogs 'accepted.state.json'
  [IO.File]::WriteAllText($pending, '{"Status":"installed-needs-verification"}')
  [IO.File]::WriteAllText($accepted, '{"Status":"verified-complete"}')
  (Get-Item -LiteralPath $pending).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
  $transaction = Get-PostUpdateTransaction -LogRoot @($firstLogs, $secondLogs) -StatusScript $statusScript
  Assert ($transaction.StatePath -eq $pending) 'older pending acceptance must not be hidden by a newer accepted record on another disk'
  [IO.File]::WriteAllText($accepted, '{"Status":"installer-running"}')
  Assert ((Get-PostUpdateTransaction -LogRoot @($firstLogs, $secondLogs) -StatusScript $statusScript).Assessment.Status -eq 'installer-running') 'an installer on either disk blocks a second installation'
  [IO.File]::WriteAllText($accepted, 'broken checkpoint')
  Assert-Throws { Get-PostUpdateTransaction -LogRoot @($firstLogs, $secondLogs) -StatusScript $statusScript } 'malformed checkpoints on other disks must fail closed'

  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'), [ref]$tokens, [ref]$errors)
  $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PreparedTemporaryWorkspace' }, $true)
  . ([scriptblock]::Create($functionAst.Extent.Text))
  $repairTempParent = Join-Path $root 'temp parent'
  $temp = Join-Path $repairTempParent 'r-1234567890ab'
  $null = Assert-RepairLocalDirectory -Path $temp -Create
  [IO.File]::WriteAllText((Join-Path $temp '.codex-model-experience-temp'), ('b' * 32))
  $transcript = "[model-experience-repair] short-path temporary workspace: $temp`r`n"
  Assert ((Get-PreparedTemporaryWorkspace $transcript).Path -eq $temp) 'prepared-build parsing uses the transaction root, including spaces, not a hardcoded disk'
  Assert-Throws { Get-PreparedTemporaryWorkspace $transcript.Replace('r-1234567890ab', 'outside') } 'prepared workspace names remain constrained'

  $fixture = Join-Path $root 'launcher'
  New-Item -ItemType Directory -Path (Join-Path $fixture 'lib') | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-model-experience-repair.ps1') -Destination $fixture
  foreach ($name in @('repair-storage.ps1', 'appx-launch.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "lib\$name") -Destination (Join-Path $fixture 'lib')
  }
  [IO.File]::WriteAllText((Join-Path $fixture 'lib\post-update-readiness.ps1'), 'function Get-PostUpdateTransaction { param($LogRoot,$StatusScript) return $null }')
  [IO.File]::WriteAllText((Join-Path $fixture 'repatch-model-experience-recoverable.ps1'), 'throw "Fixture must never deploy"')
  function Get-AppxPackage { param($Name) [pscustomobject]@{ Version = [version]'1.2.3.0'; PackageFullName = 'OpenAI.Codex_1.2.3.0_x64__fixture' } }
  $fresh = Join-Path $root 'whatif-new-root'
  & (Join-Path $fixture 'start-model-experience-repair.ps1') -DataRoot $fresh -CustomModels @('fixture-model') -WhatIf | Out-Null
  Assert (-not (Test-Path -LiteralPath $fresh)) 'WhatIf must neither create data roots nor launch an installer'
  $null = Assert-RepairLocalDirectory -Path $run -Create
  $null = Assert-RepairLocalDirectory -Path $layout.LogRoot -Create
  $preparedTranscript = Join-Path $layout.LogRoot 'prepared.transcript.txt'
  [IO.File]::WriteAllText($preparedTranscript, 'prepared fixture')
  $env:CODEX_WINDOWS_REPAIR_DATA_ROOT = $fresh
  & (Join-Path $fixture 'start-model-experience-repair.ps1') -ResumePreparedBuild -PreparedOutputRoot $run `
    -PreparedTranscriptPath $preparedTranscript -CustomModels @('fixture-model') -WhatIf | Out-Null
  Assert (-not (Test-Path -LiteralPath $fresh)) 'resume must stay on the original drive even when the environment override has changed'
  Remove-Item function:\Get-AppxPackage
} finally {
  $env:CODEX_WINDOWS_REPAIR_DATA_ROOT = $oldOverride
  $full = [IO.Path]::GetFullPath($root)
  if ((Split-Path -Parent $full) -ine [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\') -or
      (Split-Path -Leaf $full) -notmatch '^storage-fixture-[a-f0-9]{32}$') { throw 'Test fixture cleanup escaped its workspace.' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
Write-Output "REPAIR_STORAGE_TESTS_PASSED checks=$script:checks"
