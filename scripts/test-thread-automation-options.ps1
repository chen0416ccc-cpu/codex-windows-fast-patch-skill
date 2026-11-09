$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
$options = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ComputerUseSurfaceOptions'
}, $true)
Invoke-Expression $options.Extent.Text
function Fail([string]$Message) { throw $Message }
$names = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Where-Object { $_ -like 'Only*' -or $_ -like 'Patch*' }) +
  @('AddLocalPluginMarketplace', 'VerifyFastModeRequest')
$checks = 0
$defaults = @(& ([scriptblock]::Create($ast.ParamBlock.Extent.Text +
  "`n[bool]`$OnlyThreadAutomations; [bool]`$PatchThreadAutomations")))
if ($defaults.Count -ne 2 -or $defaults[0] -or $defaults[1]) {
  throw 'Thread automation customization must remain opt-in'
}
$checks += 2
function Check-Options([string[]]$Enabled, [bool]$Reject) {
  foreach ($name in $names) { Set-Variable -Name $name -Value ($name -in $Enabled) -Scope Script }
  $failed = $false
  try { Assert-ComputerUseSurfaceOptions } catch { $failed = $true }
  if ($failed -ne $Reject) { throw "Unexpected option validation: $($Enabled -join ', ')" }
  $script:checks++
}
Check-Options @() $false
Check-Options @('OnlyThreadAutomations') $false
Check-Options @('PatchThreadAutomations') $false
Check-Options @('PatchThreadAutomations', 'PatchWindows10ScreenshotHelper', 'VerifyFastModeRequest') $false
foreach ($option in @('AddLocalPluginMarketplace', 'VerifyFastModeRequest',
    'PatchWindows10ScreenshotHelper', 'PatchWindowsStoreUpdateFallback')) {
  Check-Options @('PatchThreadAutomations', $option) $false
}
foreach ($mode in $names | Where-Object { $_ -like 'Only*' -and $_ -ne 'OnlyThreadAutomations' }) {
  Check-Options @('OnlyThreadAutomations', $mode) $true
  Check-Options @('PatchThreadAutomations', $mode) $true
}
foreach ($option in @('PatchThreadAutomations', 'AddLocalPluginMarketplace', 'VerifyFastModeRequest',
    'PatchWindows10ScreenshotHelper', 'PatchWindowsStoreUpdateFallback')) {
  Check-Options @('OnlyThreadAutomations', $option) $true
}
Write-Output "Thread automation option checks passed: $checks"
