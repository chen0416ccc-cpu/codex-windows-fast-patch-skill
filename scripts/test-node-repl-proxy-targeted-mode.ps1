$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Patch script parse failed.'}
foreach($name in @('Assert-ComputerUseSurfaceOptions','Patch-ChromePluginWindowsRegistryParsing')){
    $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(-not $definition){throw "Missing function: $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Fail([string]$Message){throw $Message}
$OnlyNodeReplProxyEnv=$true
$flags=@('OnlyComputerUseSurface','OnlyBundledMarketplaceCopy','OnlyModelExperience','AddLocalPluginMarketplace','VerifyFastModeRequest','PatchWindows10ScreenshotHelper','PatchWindowsStoreUpdateFallback')
foreach($flag in $flags){Set-Variable -Name $flag -Value $false}
Assert-ComputerUseSurfaceOptions
foreach($flag in $flags){
    Set-Variable -Name $flag -Value $true
    $rejected=$false
    try{Assert-ComputerUseSurfaceOptions}catch{if($_.Exception.Message -match 'OnlyNodeReplProxyEnv'){$rejected=$true}else{throw}}
    if(-not $rejected){throw "Unexpected mixed-mode acceptance: $flag"}
    Set-Variable -Name $flag -Value $false
}
if((Patch-ChromePluginWindowsRegistryParsing 'no-files-needed') -ne 'skipped-targeted-node-repl-proxy-env'){throw 'Unrelated registry patch was not skipped.'}
Write-Output 'NODE_REPL_PROXY_TARGETED_MODE_PASSED valid=1 conflicting_options=7 registry_skip=1'
$OnlyNodeReplProxyEnv=$false
$OnlyComputerUseSurfaceAndProxyEnv=$true
$combinedFlags=$flags+@('OnlyNodeReplProxyEnv')
Assert-ComputerUseSurfaceOptions
foreach($flag in $combinedFlags){
    Set-Variable -Name $flag -Value $true
    $rejected=$false
    try{Assert-ComputerUseSurfaceOptions}catch{if($_.Exception.Message -match 'OnlyComputerUseSurfaceAndProxyEnv'){$rejected=$true}else{throw}}
    if(-not $rejected){throw "Unexpected combined-mode acceptance: $flag"}
    Set-Variable -Name $flag -Value $false
}
if((Patch-ChromePluginWindowsRegistryParsing 'no-files-needed') -ne 'skipped-targeted-computer-use-surface-and-proxy-env'){throw 'Combined mode did not skip unrelated registry patch.'}
Write-Output 'CUA_AND_PROXY_TARGETED_MODE_PASSED valid=1 conflicting_options=8 registry_skip=1'
