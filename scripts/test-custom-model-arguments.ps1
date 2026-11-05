[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Package patcher does not parse.' }
$statements = @($ast.EndBlock.Statements)
if ($statements[1].Extent.Text -notmatch '^\$CustomModels\s*=' -or
    $statements[2].Extent.Text -notmatch '^if \(\$CustomModels.Count -eq 0\)') {
  throw 'Model normalization must precede package/runtime side effects.'
}
$normalize = [scriptblock]::Create($statements[1].Extent.Text + "`n" + $statements[2].Extent.Text)
$cases = @(
  @{ Input = @('gpt-a'); Expected = @('gpt-a') },
  @{ Input = @('gpt-a,gpt-b'); Expected = @('gpt-a', 'gpt-b') },
  @{ Input = @(' gpt-a, gpt-b ', 'gpt-a', '', ' gpt-c '); Expected = @('gpt-a', 'gpt-b', 'gpt-c') },
  @{ Input = @('gpt-a', 'gpt-b'); Expected = @('gpt-a', 'gpt-b') }
)
$checks = 0
foreach ($case in $cases) {
  $CustomModels = @($case.Input)
  . $normalize
  if (($CustomModels -join '|') -cne ($case.Expected -join '|')) { throw 'Model identifier normalization mismatch.' }
  $checks++
}
foreach ($empty in @(@(), @(''), @(' , , '))) {
  $CustomModels = @($empty)
  $message = $null
  try { . $normalize } catch { $message = $_.Exception.Message }
  if ($message -cne 'CustomModels must contain at least one model identifier.') { throw 'Empty model set was not rejected.' }
  $checks++
}
Write-Output "CUSTOM_MODEL_ARGUMENTS_PASSED checks=$checks"
