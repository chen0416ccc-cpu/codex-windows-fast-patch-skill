[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptRoot 'repatch-codex-windows.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
  throw "wrapper has parse errors: $($parseErrors[0].Message)"
}

$definition = $ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Test-CodexPatchInstallResult'
}, $true) | Select-Object -First 1
if (-not $definition) {
  throw 'wrapper function is missing: Test-CodexPatchInstallResult'
}
. ([scriptblock]::Create($definition.Extent.Text))

function New-PackageRecord {
  param(
    [string]$Version,
    [string]$SignatureKind
  )
  return [pscustomobject]@{
    Version = $Version
    SignatureKind = $SignatureKind
  }
}

function Assert-Result {
  param(
    [object]$Result,
    [bool]$Success,
    [bool]$Retryable,
    [string]$ReasonPattern,
    [string]$Message
  )
  if ([bool]$Result.Success -ne $Success) {
    throw "assertion failed: $Message success=$($Result.Success)"
  }
  if ([bool]$Result.Retryable -ne $Retryable) {
    throw "assertion failed: $Message retryable=$($Result.Retryable)"
  }
  if ([string]$Result.Reason -notmatch $ReasonPattern) {
    throw "assertion failed: $Message reason=$($Result.Reason)"
  }
}

$oldDeveloper = New-PackageRecord -Version '26.810.6296.0' -SignatureKind 'Developer'
$newDeveloper = New-PackageRecord -Version '26.810.7004.0' -SignatureKind 'Developer'
$newStore = New-PackageRecord -Version '26.810.7004.0' -SignatureKind 'Store'
$olderDeveloper = New-PackageRecord -Version '26.803.10989.0' -SignatureKind 'Developer'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $oldDeveloper $newDeveloper) `
  -Success $true `
  -Retryable $false `
  -ReasonPattern '^staged package upgraded during repair:' `
  -Message 'a Developer-signed staged upgrade is accepted'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $oldDeveloper $oldDeveloper) `
  -Success $true `
  -Retryable $false `
  -ReasonPattern '^version=26\.810\.6296\.0 signature=Developer$' `
  -Message 'the original same-version Developer result remains accepted'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $oldDeveloper $newStore) `
  -Success $false `
  -Retryable $true `
  -ReasonPattern '^Codex package changed during repair:' `
  -Message 'a Store-signed newer package remains retryable drift'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $oldDeveloper $olderDeveloper) `
  -Success $false `
  -Retryable $false `
  -ReasonPattern '^Codex package changed during repair:' `
  -Message 'a Developer-signed version rollback is rejected'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $oldDeveloper (New-PackageRecord -Version '26.810.6296.0' -SignatureKind 'Store')) `
  -Success $false `
  -Retryable $true `
  -ReasonPattern '^Codex repair did not leave a Developer-signed package:' `
  -Message 'a same-version Store result remains retryable'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $null $newDeveloper) `
  -Success $false `
  -Retryable $false `
  -ReasonPattern '^source OpenAI\.Codex package was not found$' `
  -Message 'a missing source package is rejected'

Assert-Result `
  -Result (Test-CodexPatchInstallResult $oldDeveloper $null) `
  -Success $false `
  -Retryable $false `
  -ReasonPattern '^OpenAI\.Codex package is missing after repair$' `
  -Message 'a missing final package is rejected'

Write-Output 'Repatch install result regression passed'
