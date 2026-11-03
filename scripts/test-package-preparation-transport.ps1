[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'repatch-model-experience-recoverable.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$function = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RepairPackagePreparation'
}, $true)
if (-not $function) { throw 'Package preparation helper missing' }
Invoke-Expression $function.Extent.Text
$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('preparation fixture ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$fixturePath = Join-Path $root 'fixture.ps1'
$fixture = @'
param([string[]]$CustomModels, [bool]$Enabled, [string]$TargetPath, [int]$ReturnCode)
if (($CustomModels -join ',') -ne 'gpt-6.1-sol,gpt-6-astra' -or -not $Enabled -or $TargetPath -ne 'space path/fixture') { exit 9 }
[Console]::Error.WriteLine('npm warn fixture: harmless deprecation')
Write-Host 'package host marker'
Write-Output 'package fixture success'
exit $ReturnCode
'@
[IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))
$parameters = @{ CustomModels = @('gpt-6.1-sol', 'gpt-6-astra'); Enabled = $true; TargetPath = 'space path/fixture'; ReturnCode = 0 }
$result = Invoke-RepairPackagePreparation -PatcherPath $fixturePath -Parameters $parameters -LogRoot $root
if ($result.ExitCode -ne 0 -or ($result.Lines -join '') -notlike '*npm warn fixture*' -or
    ($result.Lines -join '') -notlike '*package fixture success*' -or
    ($result.Lines -join '') -notlike '*package host marker*' -or
    ($result.Lines -join '') -like '*#< CLIXML*') {
  throw "A successful package child with stderr was rejected: $($result.ExitCode)"
}
$parameters.ReturnCode = 7
$failed = Invoke-RepairPackagePreparation -PatcherPath $fixturePath -Parameters $parameters -LogRoot $root
if ($failed.ExitCode -ne 7) { throw 'A nonzero package preparation exit was lost' }
Write-Output 'Package preparation transport passed: stderr, exit codes, model arrays and path arguments.'
