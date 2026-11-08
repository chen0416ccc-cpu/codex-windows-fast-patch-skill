param()

$ErrorActionPreference = 'Stop'
$script:checks = 0

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}

$runnerPath = Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'
$launcherPath = Join-Path $PSScriptRoot 'start-model-experience-repair.ps1'
$patcherPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$runnerText = Get-Content -LiteralPath $runnerPath -Raw
$launcherText = Get-Content -LiteralPath $launcherPath -Raw
$patcherText = Get-Content -LiteralPath $patcherPath -Raw

foreach ($path in @($runnerPath, $launcherPath, $patcherPath)) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  Assert ($errors.Count -eq 0) "PowerShell syntax: $path"
  Assert ($null -ne $ast) "PowerShell AST returned: $path"
}

foreach ($required in @(
  'ExpectedUserSid',
  'ExpectedSessionId',
  'ExpectedPackageFullName',
  'ResumePreparedBuild',
  'Assert-PreparedOutputRoot',
  'Read-PreparedPatchTranscript',
  'Get-PreparedTemporaryWorkspace',
  'Remove-PreparedRecoveryArtifacts',
  'Assert-NoReparsePointsRecursive',
  'Remove-DirectoryTreeRobust',
  '[IO.Directory]::GetFileSystemEntries($directory)',
  '[IO.File]::Delete($entry)',
  '[IO.Directory]::Delete($directory, $false)',
  'catch [IO.DirectoryNotFoundException]',
  'catch [IO.FileNotFoundException]',
  'Assert-NoReparsePointsRecursive -Path $fullPath',
  'Assert-NoReparsePointsRecursive -Path $recoveryRoot',
  'Test-CodeSigningCertificate',
  '$objectId = [string]$usage.ObjectId',
  'recovery signing certificate verified:',
  'Prepared transcript does not prove a signed, Fast-verified package stopped at a recognized pre-deployment guard.',
  'Prepared transcript does not record a recognized pre-deployment stop.',
  "`$transcriptFullPath = Assert-TranscriptPathIsSafe -Path `$TranscriptPath -RepairRoot `$requestedOutputRoot",
  'codex-original-content-recovery.msix',
  'Prepared recovery artifact has an unexpected type or is a reparse point:',
  'patchParameters = @{',
  'AppPath = Join-Path $package.InstallLocation',
  'CleanupWindowsSdkAfterInstall = $false',
  'Get-Content -LiteralPath $transcriptFullPath -Raw -ErrorAction Stop',
  '$patchText = ($patchLog -join [Environment]::NewLine) + [Environment]::NewLine + $patchTranscriptText',
  'Assert-MsixExternalExecutor',
  'Copy-RecoveryPackageLayout',
  'Invoke-RecoverableMsixInstall',
  'Test-ComputerUseStrictVerification',
  'Test-ModelListFastTiers',
  'capabilities: { experimentalApi: true }',
  'pending.set(id, {',
  'resolve: value => { clearTimeout(timer); resolve(value); }',
  'reject: error => { clearTimeout(timer); reject(error); }',
  'default model does not expose the Fast service tier',
  'ultrafastModels',
  'will not invent unsupported model tiers',
  'Node REPL trusted-paths patch result:',
  'already-patched',
  'CODEX_NODE_REPL_TRUSTED_PATHS_V1',
  'staged app.asar trusted-path contract verified:',
  'The staged app.asar does not contain the external trust-path contract marker:'
)) {
  Assert ($runnerText.Contains($required)) "recoverable runner guard: $required"
}

Assert (-not $runnerText.Contains("'-OnlyModelExperience'")) 'runner repairs the complete non-phone package path'
Assert (-not $runnerText.Contains('Get-ChildItem -LiteralPath $recoveryRoot -Recurse')) 'incomplete recovery trees use the missing-entry-tolerant scanner'
Assert ($launcherText.Contains("-Verb RunAs")) 'launcher requests standard UAC elevation'
Assert ($launcherText.Contains('-WindowStyle Hidden')) 'elevated installer console stays hidden to prevent QuickEdit pauses'
Assert ($launcherText.Contains('CODEX_HOME')) 'launcher rejects isolated CLI homes'
Assert ($launcherText.Contains('ExpectedPackageFullName')) 'launcher binds source package identity'
Assert (-not $launcherText.Contains('Register-ScheduledTask')) 'launcher does not bypass UAC through Task Scheduler'
Assert ($launcherText.Contains('ShouldProcess')) 'launcher supports non-mutating WhatIf verification'
Assert ($launcherText.Contains('ResumePreparedBuild')) 'launcher exposes guarded prepared-build resume'
Assert ($launcherText.Contains('PreparedOutputRoot')) 'launcher binds the prepared output root'
Assert ($launcherText.Contains('PreparedTranscriptPath')) 'launcher binds the prepared transcript'
Assert ($launcherText.Contains('-ResumePreparedBuild:([bool]$payload.ResumePreparedBuild)')) 'elevated bootstrap receives the resume mode explicitly'
$allowedEntriesText = '$allowedEntries = @(''.codex-model-experience-repair'', ''patched-build'', ''recovery-package'', ''codex-original-content-recovery.msix'')'
Assert ($runnerText.Contains($allowedEntriesText)) 'resume accepts only known partial recovery artifacts'
Assert ($patcherText.Contains("Join-Path `$WorkDir 'asar'")) 'ASAR extraction uses the short Windows-compatible directory name'
Assert (-not $patcherText.Contains("Join-Path `$WorkDir 'asar-extracted'")) 'legacy MAX_PATH extraction directory is not used'
Assert ($patcherText.Contains('[string]$AsarWorkRoot')) 'patcher accepts a dedicated ASAR work root'
Assert ($patcherText.Contains("Join-Path `$env:TEMP 'codex-msix-work'")) 'standalone patcher retains its temporary-root fallback'
Assert ($patcherText.Contains('[IO.Path]::GetFullPath($AsarWorkRoot)')) 'explicit ASAR work root is normalized'
Assert ($patcherText.Contains("('w-' + [guid]::NewGuid().ToString('N').Substring(0, 16))")) 'ASAR temporary work directory uses a bounded unique name'
Assert ($patcherText.Contains('-RequiredRoot $tempWorkRoot -BestEffort')) 'temporary work cleanup stays within its dedicated root'
Assert ($runnerText.Contains('$repairTempParent = $storage.TemporaryRoot')) 'recoverable runner uses the transaction-bound short temp parent'
Assert ($launcherText.Contains('DataRoot = $dataRoot')) 'launcher binds the chosen drive into the elevated payload'
Assert ($runnerText.Contains("['temporarySentinelId'] = `$tempSentinelId")) 'checkpoint retains temporary workspace ownership for exact-run finalization'
Assert ($runnerText.Contains('AsarWorkRoot = $tempRoot')) 'recoverable runner passes the short root directly to the patcher'
Assert ($runnerText.Contains('Remove-RepairTemporaryRoot -Path $tempRoot -SentinelId $tempSentinelId')) 'short temp workspace is removed only after successful validation'
Assert ($runnerText.Contains('temporary workspace retained for diagnosis')) 'failed repair retains and reports the temporary workspace'
Assert ($runnerText.Contains('Remove-DirectoryTreeRobust -Path $resolvedOutputRoot')) 'deep build and recovery tree uses extended-path cleanup after acceptance'
$markerFunctionAst = $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
$markerFunctionAst = $markerFunctionAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-FileContainsAsciiText' }, $true)
Assert ($null -ne $markerFunctionAst) 'binary marker scanner is available for staged ASAR validation'
. ([scriptblock]::Create($markerFunctionAst.Extent.Text))
$patchResultFunctionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-NodeReplTrustedPathsPatchResult' }, $true)
Assert ($null -ne $patchResultFunctionAst) 'trusted-path result parser is available for multiline repair logs'
. ([scriptblock]::Create($patchResultFunctionAst.Extent.Text))
$alreadyPatchedLog = "[codex-msix-patch-win] Node REPL trusted-paths patch result: already-patched`r`nother log line`r`n"
$patchedLog = "heading`r`n[model-experience-repair] patcher: Node REPL trusted-paths patch result: patched`r`n"
Assert ((Get-NodeReplTrustedPathsPatchResult $alreadyPatchedLog) -ceq 'already-patched') 'multiline transcript recognizes an already-patched result'
Assert ((Get-NodeReplTrustedPathsPatchResult $patchedLog) -ceq 'patched') 'prefixed multiline transcript recognizes a patched result'
Assert ($null -eq (Get-NodeReplTrustedPathsPatchResult 'no trusted-path patch report')) 'missing trusted-path result fails closed'
$conflictingLog = $alreadyPatchedLog + $patchedLog
$conflictRejected = $false
try { $null = Get-NodeReplTrustedPathsPatchResult $conflictingLog } catch { $conflictRejected = $true }
Assert $conflictRejected 'conflicting trusted-path results are rejected'
$markerFixture = Join-Path ([IO.Path]::GetTempPath()) ('trusted-path-marker-' + [guid]::NewGuid().ToString('N') + '.bin')
try {
  $markerBytes = [Text.Encoding]::ASCII.GetBytes('CODEX_NODE_REPL_TRUSTED_PATHS_V1')
  $fixtureBytes = [byte[]]::new(65536 + $markerBytes.Length + 17)
  for ($index = 0; $index -lt $fixtureBytes.Length; $index++) { $fixtureBytes[$index] = 0x41 }
  [Array]::Copy($markerBytes, 0, $fixtureBytes, 65536 - 9, $markerBytes.Length)
  [IO.File]::WriteAllBytes($markerFixture, $fixtureBytes)
  Assert (Test-FileContainsAsciiText -Path $markerFixture -Text 'CODEX_NODE_REPL_TRUSTED_PATHS_V1') 'binary marker scanner finds a marker spanning read chunks'
  Assert (-not (Test-FileContainsAsciiText -Path $markerFixture -Text 'MISSING_TRUSTED_PATH_MARKER')) 'binary marker scanner rejects an absent marker'
} finally {
  Remove-Item -LiteralPath $markerFixture -Force -ErrorAction SilentlyContinue
}
$sampleAsarEntry = 'node_modules\@worklouder\device-kit-oai\node_modules\@serialport\bindings-cpp\node_modules\@serialport\parser-readline\node_modules\@serialport\parser-delimiter\dist\index.d.ts'
$sampleAsarRoot = 'D:\CodexData\cwp-tmp\r-1234567890ab\w-0123456789abcdef\asar'
$sampleAssetPath = [IO.Path]::GetFullPath((Join-Path $sampleAsarRoot $sampleAsarEntry))
Assert ($sampleAssetPath.Length -lt 240) 'longest current nested ASAR entry stays within the short-path budget'
$failedAssetPath = [IO.Path]::GetFullPath((Join-Path $sampleAsarRoot 'webview\assets\calculator-cha2ds2-vasc-score-for-atrial-fibrillation-stroke-risk-widget-b7d2b083b886.js'))
Assert ($failedAssetPath.Length -lt 200) 'previously failing long hashed asset stays well below MAX_PATH'
$legacyAsarRoot = 'D:\CodexData\codex-windows-fast-patch\model-experience-repair-runs\20261018-142121-f7c300499931459ca758aca6236b3b4e\temp\codex-msix-work\w-0123456789abcdef\asar'
$legacyAssetPath = [IO.Path]::GetFullPath((Join-Path $legacyAsarRoot 'webview\assets\calculator-cha2ds2-vasc-score-for-atrial-fibrillation-stroke-risk-widget-b7d2b083b886.js'))
Assert ($legacyAssetPath.Length -ge 260) 'regression fixture reproduces the overlong failed ASAR asset path'

Write-Output "MODEL_EXPERIENCE_RECOVERABLE_TESTS_PASSED checks=$script:checks"
