[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$OutputRoot = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('runtime-refresh-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'), [ref]$tokens, [ref]$errors)
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ComputerUseStrictVerification' }, $true)
$script:fixtureScriptRoot = $PSScriptRoot
# An AST-extracted function has no file-backed PSScriptRoot; preserve its source
# directory while executing the actual production body with a process fixture.
Invoke-Expression ($function.Extent.Text.Replace('$PSScriptRoot', '$script:fixtureScriptRoot'))
function Write-Log { param([string]$Message) }
$script:calls = @()
$script:failMode = ''
function Start-Process {
  param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, [switch]$Wait, $RedirectStandardOutput, $RedirectStandardError)
  $script:calls += ,@($ArgumentList)
  if ($WindowStyle -ne 'Hidden' -or -not $Wait) { throw 'Verification process lost hidden/wait guards.' }
  [IO.File]::WriteAllText($RedirectStandardOutput, '')
  [IO.File]::WriteAllText($RedirectStandardError, '')
  $exitCode = if ($script:failMode -and $ArgumentList -contains $script:failMode) { 7 } else { 0 }
  return [pscustomobject]@{ ExitCode = $exitCode }
}
Test-ComputerUseStrictVerification
if ($script:calls.Count -ne 2 -or $script:calls[0] -notcontains '-VerifyOnly' -or
    $script:calls[1] -notcontains '-StrictVerifyOnly') { throw 'Refresh must precede a separate strict pass.' }
foreach ($mode in @('-VerifyOnly', '-StrictVerifyOnly')) {
  $script:calls = @(); $script:failMode = $mode; $rejected = $false
  try { Test-ComputerUseStrictVerification } catch {
    if ($_.Exception.Message -notlike '*failed with exit code 7*') { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw 'A failed runtime pass was accepted.' }
  if ($mode -eq '-VerifyOnly' -and $script:calls.Count -ne 1) { throw 'Strict pass ran after a failed refresh.' }
}
Write-Output 'Post-install runtime refresh guards passed.'
