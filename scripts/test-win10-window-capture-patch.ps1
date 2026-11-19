[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$HelperPath)

$ErrorActionPreference = 'Stop'
$patcher = Join-Path $PSScriptRoot 'patch-computer-use-helper-win10.ps1'
$baseline = '0D89485AE06573C5F65DB35C6E3999C338F2F1B08BEABEA9F9EB429C448E41CD'
$expected = 'BAF8C5542B41B167EA04BA46C864C445F1365BBC096F1C9646748FCFF3E106E3'
function Assert-Equal($actual, $wanted, [string]$message) {
  if ($actual -ne $wanted) { throw "$message`: actual=$actual expected=$wanted" }
}
Assert-Equal (Get-FileHash -LiteralPath $HelperPath).Hash $baseline 'baseline fixture'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryBase ('codex-window-capture-test-' + [guid]::NewGuid().ToString('N'))
if (-not ([IO.Path]::GetFullPath($testRoot)).StartsWith($temporaryBase.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Test directory escaped temporary root'
}
try {
  $skyRoot = Join-Path $testRoot 'sky'
  $testHelper = Join-Path $skyRoot 'bin\windows\codex-computer-use.exe'
  $backupRoot = Join-Path $testRoot 'state'
  New-Item -ItemType Directory -Path (Split-Path -Parent $testHelper) -Force | Out-Null
  Copy-Item -LiteralPath $HelperPath -Destination $testHelper
  [IO.File]::WriteAllText((Join-Path $skyRoot 'package.json'), '{"version":"0.7.21"}')
  $argsForPatch = @{HelperPath=$testHelper; CodexHome=$backupRoot; WindowCapture=$true}
  $before = @(& $patcher @argsForPatch) | Select-Object -Last 1
  Assert-Equal $before.State 'original-patchable' 'overlay input status'
  Assert-Equal (@(& $patcher @argsForPatch -ComputeCandidateHash) | Select-Object -Last 1) $expected 'candidate hash'
  & $patcher @argsForPatch -Install -WhatIf
  Assert-Equal (Get-FileHash -LiteralPath $testHelper).Hash $baseline 'WhatIf modified fixture'
  & $patcher @argsForPatch -Install
  $after = @(& $patcher -HelperPath $testHelper -CodexHome $backupRoot) | Select-Object -Last 1
  Assert-Equal $after.State 'patched' 'ordinary verification must recognize overlay'
  Assert-Equal $after.Sha256 $expected 'installed candidate hash'
  Assert-Equal (Get-FileHash -LiteralPath $after.BackupPath).Hash $baseline 'overlay rollback baseline'
  & $patcher -HelperPath $testHelper -CodexHome $backupRoot -Install
  Assert-Equal (Get-FileHash -LiteralPath $testHelper).Hash $expected 'ordinary repair must preserve overlay'
  & $patcher @argsForPatch -Rollback
  Assert-Equal (Get-FileHash -LiteralPath $testHelper).Hash $baseline 'rollback must preserve earlier compatibility patch'
  & $patcher @argsForPatch -Rollback
  $bytes = [IO.File]::ReadAllBytes($testHelper)
  $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
  [IO.File]::WriteAllBytes($testHelper, $bytes)
  $unknownHash = (Get-FileHash -LiteralPath $testHelper).Hash
  $rejected = $false
  try { & $patcher @argsForPatch -Install } catch { $rejected = $_.Exception.Message -like '*unsupported helper SHA-256*' }
  Assert-Equal $rejected $true 'unknown fixture must be rejected'
  Assert-Equal (Get-FileHash -LiteralPath $testHelper).Hash $unknownHash 'unknown fixture must remain unchanged'
  Assert-Equal (Get-FileHash -LiteralPath $HelperPath).Hash $baseline 'source fixture changed'
  Write-Output 'WINDOW_CAPTURE_LIFECYCLE_TESTS_PASSED; runtime occlusion validation is separate'
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
