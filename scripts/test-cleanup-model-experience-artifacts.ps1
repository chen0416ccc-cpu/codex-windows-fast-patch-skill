param()

$ErrorActionPreference = 'Stop'
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

$cleanupPath = Join-Path $PSScriptRoot 'cleanup-model-experience-repair-artifacts.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($cleanupPath, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'cleanup script PowerShell syntax'
Assert ($null -ne $ast) 'cleanup script AST'
$source = Get-Content -LiteralPath $cleanupPath -Raw
foreach ($required in @(
  'SupportsShouldProcess = $true',
  'if (-not $Clean)',
  'model-experience-repair-runs',
  '^\d{8}-\d{6}-[a-f0-9]{32}$',
  '.codex-model-experience-repair',
  'cwp-tmp',
  '.codex-model-experience-temp',
  '[string[]]$LegacyRunPath',
  '[string[]]$PurgeLegacyRunPath',
  '[string[]]$ObsoleteBuildRootPath',
  '[string]$VerifiedStatePath',
  '[switch]$ExplicitTargetsOnly',
  'Assert-LegacyRepairRunRoot',
  'Assert-ObsoleteBuildRoot',
  'Get-VerifiedRepairRunCandidate',
  '-not $ExplicitTargetsOnly',
  'Get-CurrentCodexPackageVersion',
  'Get-LegacyRecoveryVersion',
  'Get-LegacyGeneratedArtifactDirectories',
  '^upgrade-repair-\d{8}',
  'recovery-layout',
  'non-selected backups and evidence were retained',
  'Get-RepairTreeSnapshot',
  'Assert-NoReparsePointsRecursive',
  'Get-CimInstance -ClassName Win32_Process',
  'backups and evidence are included',
  'exact accepted Codex repair build and recovery package',
  '-StrictVerifyOnly',
  '-VerifyAllBundledPluginsAvailable',
  '[IO.File]::Delete($entry)',
  '[IO.Directory]::Delete($directory, $false)'
)) {
  Assert ($source.Contains($required)) "cleanup guard: $required"
}
Assert (-not $source.Contains('Remove-Item -Recurse')) 'cleanup does not use recursive PowerShell deletion'

foreach ($name in @(
  'ConvertTo-ExtendedPath',
  'Assert-NoReparsePointsRecursive',
  'Get-RepairTreeSnapshot',
  'Assert-LegacyRepairRunRoot',
  'Get-LegacyRecoveryVersion',
  'Get-LegacyGeneratedArtifactDirectories',
  'Assert-ObsoleteBuildRoot',
  'Get-VerifiedRepairRunCandidate',
  'Remove-DirectoryTreeRobust'
)) {
  $functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true)
  Assert ($null -ne $functionAst) "cleanup helper exists: $name"
  . ([scriptblock]::Create($functionAst.Extent.Text))
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('repair-cleanup-test-' + [guid]::NewGuid().ToString('N'))
try {
  $nested = Join-Path $fixtureRoot 'nested'
  New-Item -ItemType Directory -Path $nested -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'root.txt'), 'root')
  [IO.File]::WriteAllText((Join-Path $nested 'nested.txt'), 'nested')
  Remove-DirectoryTreeRobust -Path $fixtureRoot
  Assert (-not (Test-Path -LiteralPath $fixtureRoot)) 'validated cleanup removes a nested fixture'

  $legacyParent = Join-Path $fixtureRoot 'legacy-parent'
  $legacyRoot = Join-Path $legacyParent 'upgrade-repair-20260101-test-run'
  New-Item -ItemType Directory -Path $legacyRoot -Force | Out-Null
  foreach ($name in @('build', 'tmp', 'transactional', 'recovery-layout', 'backups', 'evidence')) {
    New-Item -ItemType Directory -Path (Join-Path $legacyRoot $name) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $legacyRoot $name) 'sample.txt'), $name)
  }
  $manifestPath = Join-Path $legacyRoot 'recovery-layout\AppxManifest.xml'
  [IO.File]::WriteAllText($manifestPath, '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="OpenAI.Codex" Version="1.0.0.0" /></Package>')
  $statusPath = Join-Path $legacyRoot 'build-status.json'
  [IO.File]::WriteAllText($statusPath, '{"stage":"failed","installed":false,"time":"2026-01-01T00:00:00Z"}')
  [IO.Directory]::SetLastWriteTime($legacyRoot, (Get-Date).AddDays(-2))
  $validatedRoot = Assert-LegacyRepairRunRoot -Path $legacyRoot -ExpectedParent $legacyParent -Cutoff (Get-Date).AddHours(-24)
  Assert ($validatedRoot -ceq [IO.Path]::GetFullPath($legacyRoot)) 'explicit legacy root is accepted under its exact parent'

  $badParentRejected = $false
  try { Assert-LegacyRepairRunRoot -Path $legacyRoot -ExpectedParent $fixtureRoot -Cutoff (Get-Date).AddHours(-24) | Out-Null } catch { $badParentRejected = $true }
  Assert $badParentRejected 'legacy root outside the expected direct parent is rejected'
  $badNameRejected = $false
  try { Assert-LegacyRepairRunRoot -Path (Join-Path $legacyParent 'unrelated-data') -ExpectedParent $legacyParent -Cutoff (Get-Date).AddHours(-24) | Out-Null } catch { $badNameRejected = $true }
  Assert $badNameRejected 'unrelated directory names are rejected'

  [IO.File]::WriteAllText($statusPath, '{"stage":"failed","installed":true}')
  $installedRejected = $false
  try { Assert-LegacyRepairRunRoot -Path $legacyRoot -ExpectedParent $legacyParent -Cutoff (Get-Date).AddHours(-24) | Out-Null } catch { $installedRejected = $true }
  Assert $installedRejected 'installed legacy runs cannot be selected by the failed-build compatibility path'
  [IO.File]::WriteAllText($statusPath, '{"stage":"failed","installed":false}')

  $dataRoot = Join-Path $legacyParent 'skill-data'
  New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
  $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $inventory = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $cleanupPath -DataRoot $dataRoot -LegacyRunPath $legacyRoot 2>&1)
  Assert ($LASTEXITCODE -eq 0) ('default inventory succeeds without a modern runs directory: ' + ($inventory -join ' '))
  Assert (($inventory -join ' ') -like '*Dry run only*') 'default invocation explicitly reports inventory-only mode'
  Assert (Test-Path -LiteralPath (Join-Path $legacyRoot 'build\sample.txt')) 'default inventory leaves generated files untouched'

  $purgeInventory = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $cleanupPath `
    -DataRoot $dataRoot -PurgeLegacyRunPath $legacyRoot 2>&1)
  Assert ($LASTEXITCODE -eq 0) ('explicit failed-run purge inventory succeeds: ' + ($purgeInventory -join ' '))
  Assert (($purgeInventory -join ' ') -like '*backups and evidence are included*') 'whole-run purge clearly reports its wider scope'
  Assert (Test-Path -LiteralPath (Join-Path $legacyRoot 'backups\sample.txt')) 'purge inventory remains read-only'

  $obsoleteRoot = Join-Path $legacyParent 'nonphone-repair-20260101-1021'
  $obsoletePackageRoot = Join-Path $obsoleteRoot 'OpenAI.Codex_1.0.0.0_x64__test'
  $obsoletePackage = Join-Path $obsoletePackageRoot 'package'
  $obsoleteArtifacts = Join-Path $obsoletePackageRoot 'artifacts'
  New-Item -ItemType Directory -Path $obsoletePackage, $obsoleteArtifacts -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $obsoletePackage 'AppxManifest.xml'),
    '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="OpenAI.Codex" Version="1.0.0.1" /></Package>')
  [IO.File]::WriteAllText((Join-Path $obsoleteArtifacts 'OpenAI.Codex_1.0.0.0_patched.msix'), 'fixture')
  $obsolete = Assert-ObsoleteBuildRoot -Path $obsoleteRoot -ExpectedParent $legacyParent `
    -CurrentCodexVersion ([version]'2.0.0.0') -CurrentDesktopStartTime (Get-Date)
  Assert ($obsolete.SourceVersion -eq [version]'1.0.0.0' -and $obsolete.TargetVersion -eq [version]'1.0.0.1' -and
    $obsolete.Snapshot.Files -eq 2) 'obsolete build binds its source directory, incremented manifest and patch artifact'
  Assert-Throws {
    Assert-ObsoleteBuildRoot -Path $obsoleteRoot -ExpectedParent $legacyParent `
      -CurrentCodexVersion ([version]'1.0.0.0') -CurrentDesktopStartTime (Get-Date)
  } 'a build matching the current Codex version is not obsolete'
  Assert-Throws {
    Assert-ObsoleteBuildRoot -Path (Join-Path $legacyParent 'unrelated') -ExpectedParent $legacyParent `
      -CurrentCodexVersion ([version]'2.0.0.0') -CurrentDesktopStartTime (Get-Date)
  } 'an unrecognized build root name is rejected'
  [IO.File]::WriteAllText((Join-Path $obsoleteRoot 'notes.txt'), 'not an owned build artifact')
  Assert-Throws {
    Assert-ObsoleteBuildRoot -Path $obsoleteRoot -ExpectedParent $legacyParent `
      -CurrentCodexVersion ([version]'2.0.0.0') -CurrentDesktopStartTime (Get-Date)
  } 'unexpected files prevent obsolete build cleanup'
  [IO.File]::Delete((Join-Path $obsoleteRoot 'notes.txt'))

  . (Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1')
  $script:repairLogsName = 'model-experience-repair-logs'
  $verifiedData = Join-Path $fixtureRoot 'verified-data'
  $verifiedLogs = Join-Path $verifiedData $repairLogsName
  $verifiedRuns = Join-Path $verifiedData 'model-experience-repair-runs'
  $verifiedOutput = Join-Path $verifiedRuns ('20260101-010101-' + ('a' * 32))
  New-Item -ItemType Directory -Path $verifiedLogs, $verifiedOutput -Force | Out-Null
  $verifiedTarget = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_1.9.9.10_x64__test'; Version = [version]'1.9.9.10'; Status = 'Ok' }
  $verifiedSource = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_1.9.9.9_x64__test'; Version = [version]'1.9.9.9' }
  $verifiedProcess = Get-Process -Id $PID
  $verifiedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $verifiedState = New-RepairDeploymentState -SourcePackage $verifiedSource -InstallerProcess $verifiedProcess `
    -UserSid $verifiedSid -SessionId $verifiedProcess.SessionId -OutputRoot $verifiedOutput `
    -TranscriptPath (Join-Path $verifiedLogs 'verify.transcript.txt')
  $verifiedState.stage = 'cleanup-pending'
  $verifiedState.acceptancePassed = $true
  $verifiedState.verifiedPackageFullName = $verifiedTarget.PackageFullName
  $verifiedState.verifiedUtc = [DateTime]::UtcNow.ToString('o')
  $verifiedState.cleanupStatus = 'pending'
  $verifiedState.installerPid = [int]::MaxValue
  $verifiedStatePath = Join-Path $verifiedLogs 'verify.transcript.txt.state.json'
  Write-RepairDeploymentState -Path $verifiedStatePath -State $verifiedState
  $marker = Join-Path $verifiedOutput '.codex-model-experience-repair'
  [IO.File]::WriteAllText($marker, ('b' * 32))
  $script:cleanupMockPackage = $verifiedTarget
  function Get-AppxPackage { param($Name) return $script:cleanupMockPackage }
  $verifiedCandidate = Get-VerifiedRepairRunCandidate -StatePath $verifiedStatePath -DataRoot $verifiedData -RunsRoot $verifiedRuns
  Assert (-not $verifiedCandidate.Missing -and $verifiedCandidate.Path -ceq $verifiedOutput -and
    $verifiedCandidate.SentinelId -ceq ('b' * 32)) 'immediate cleanup is bound to a verified checkpoint and matching run sentinel'
  $script:cleanupMockPackage = [pscustomobject]@{ PackageFullName = 'OpenAI.Codex_2.0.0.1_x64__test'; Version = [version]'2.0.0.1'; Status = 'Ok' }
  Assert-Throws {
    Get-VerifiedRepairRunCandidate -StatePath $verifiedStatePath -DataRoot $verifiedData -RunsRoot $verifiedRuns
  } 'a superseding package prevents immediate old-run cleanup'
  Remove-Item function:\Get-AppxPackage -ErrorAction SilentlyContinue

  $newerThanRecovery = @(Get-LegacyGeneratedArtifactDirectories -Path $legacyRoot -CurrentCodexVersion ([version]'2.0.0.0'))
  Assert ($newerThanRecovery.Count -eq 4) 'older recovery layout is eligible only when current Codex is newer'
  $sameVersion = @(Get-LegacyGeneratedArtifactDirectories -Path $legacyRoot -CurrentCodexVersion ([version]'1.0.0.0'))
  Assert ($sameVersion.Count -eq 3 -and $sameVersion.Name -notcontains 'recovery-layout') 'recovery layout is preserved when current version does not prove it obsolete'

  foreach ($directory in $newerThanRecovery) { Remove-DirectoryTreeRobust -Path $directory.Path }
  Assert (-not (Test-Path -LiteralPath (Join-Path $legacyRoot 'build'))) 'known generated build output is removed'
  Assert (Test-Path -LiteralPath (Join-Path $legacyRoot 'backups')) 'legacy user-state backups are preserved'
  Assert (Test-Path -LiteralPath (Join-Path $legacyRoot 'evidence')) 'legacy evidence is preserved'
  Assert (Test-Path -LiteralPath (Join-Path $legacyRoot 'build-status.json')) 'legacy run record is preserved'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-DirectoryTreeRobust -Path $fixtureRoot
  }
}

Write-Output "REPAIR_ARTIFACT_CLEANUP_TESTS_PASSED checks=$script:checks"
