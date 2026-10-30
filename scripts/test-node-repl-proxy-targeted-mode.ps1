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

# Exercise production orchestration without extracting or installing a real package.
$definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PatchAppAsar'}, $true)
$body = $definition.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))
. ([scriptblock]::Create($body))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('proxy-mode-' + [guid]::NewGuid().ToString('N'))
$testRoot = [IO.Path]::GetFullPath($testRoot)
$script:proxyFixture = 'const hints=["NODE_REPL_NODE_MODULE_DIRS","NODE_REPL_TRUSTED_CODE_PATHS"]; function env(n){let p=n;let e=`CODEX_WINDOWS_REGISTERED_CORE`;p=[...new Set([...n,e])];return p}'
$script:sourceProxyPatcher = Join-Path $PSScriptRoot 'patch-node-repl-proxy-env.cjs'
function Write-Log([string]$Message) {}
function Get-RequiredCommand([string]$Name) { Get-Command $Name -ErrorAction Stop }
function Write-PatcherFiles([string]$Dir) { @{ ComputerUseSurface = 'surface-test-double' } }
function Find-ComputerUseSurfaceTarget([string]$Dir) {
    if ($script:rejectSurface) { throw 'unsupported surface fixture' }
    Join-Path $Dir '.vite\build\surface.js'
}
function Invoke-NodePatcher($Node, $Patcher, $Files) {
    if ($Patcher -eq 'surface-test-double') {
        $script:surfaceCalls++
        return $script:surfaceResult
    }
    $output = & $Node $Patcher @Files
    if ($LASTEXITCODE) { throw 'proxy patcher failed' }
    return $output
}
function Invoke-NpxAsar($Mode, $Source, $Destination) {
    if ($Mode -eq 'pack') {
        $script:packCalls++
        [IO.File]::WriteAllText($Destination, 'packed fixture')
        return
    }
    $build = Join-Path $Destination '.vite\build'
    New-Item -ItemType Directory -Force -Path $build | Out-Null
    [IO.File]::WriteAllText((Join-Path $build 'surface.js'), 'const surface = true;')
    for ($i = 0; $i -lt $script:proxyCount; $i++) {
        $target = Join-Path $build "proxy-$i.js"
        [IO.File]::WriteAllText($target, $script:proxyFixture)
        if ($script:proxyAlready) {
            & node $script:sourceProxyPatcher $target | Out-Null
            if ($LASTEXITCODE) { throw 'fixture patch failed' }
        }
    }
}
$cases = @(
    @{ name='proxy-change'; combined=$false; already=$false; surface='already-patched'; dry=$false; count=1; packs=1 },
    @{ name='proxy-idempotent'; combined=$false; already=$true; surface='already-patched'; dry=$false; count=1; packs=0 },
    @{ name='proxy-dry-run'; combined=$false; already=$false; surface='patched'; dry=$true; count=1; packs=0 },
    @{ name='combined-both-change'; combined=$true; already=$false; surface='patched'; dry=$false; count=1; packs=1 },
    @{ name='combined-proxy-only-change'; combined=$true; already=$false; surface='already-patched'; dry=$false; count=1; packs=1 },
    @{ name='combined-surface-only-change'; combined=$true; already=$true; surface='patched'; dry=$false; count=1; packs=1 },
    @{ name='combined-idempotent'; combined=$true; already=$true; surface='already-patched'; dry=$false; count=1; packs=0 },
    @{ name='combined-dry-run'; combined=$true; already=$false; surface='patched'; dry=$true; count=1; packs=0 },
    @{ name='missing-proxy'; combined=$true; already=$false; surface='patched'; dry=$false; count=0; packs=0; error='expected exactly one' },
    @{ name='ambiguous-proxy'; combined=$true; already=$false; surface='patched'; dry=$false; count=2; packs=0; error='expected exactly one' },
    @{ name='missing-surface'; combined=$true; already=$false; surface='patched'; dry=$false; count=1; packs=0; error='unsupported surface' }
)
try {
    $originalFixture = $script:proxyFixture
    foreach ($quote in @('`', '"', "'")) {
    $script:proxyFixture = $originalFixture.Replace('`CODEX_WINDOWS_REGISTERED_CORE`', ($quote + 'CODEX_WINDOWS_REGISTERED_CORE' + $quote))
    foreach ($case in $cases) {
        $OnlyNodeReplProxyEnv = -not $case.combined
        $OnlyComputerUseSurfaceAndProxyEnv = $case.combined
        $DryRun = $case.dry
        $script:proxyAlready = $case.already
        $script:surfaceResult = $case.surface
        $script:proxyCount = $case.count
        $script:rejectSurface = $case.name -eq 'missing-surface'
        $script:packCalls = 0
        $script:surfaceCalls = 0
        $dir = Join-Path $testRoot (([int][char]$quote).ToString() + '-' + $case.name)
        $app = Join-Path $dir 'app'
        New-Item -ItemType Directory -Force -Path (Join-Path $app 'resources') | Out-Null
        $asar = Join-Path $app 'resources\app.asar'
        [IO.File]::WriteAllText($asar, 'original fixture')
        $failure = $null
        try { $changed = Invoke-PatchAppAsar $app $app $dir } catch { $failure = $_.Exception.Message }
        if ($case.error) {
            if ($failure -notlike "*$($case.error)*") { throw "Expected failure for $($case.name): $failure" }
        } else {
            if ($failure) { throw $failure }
            if ($changed -ne ($case.packs -eq 1)) { throw "Wrong changed result: $($case.name)" }
            if ($script:surfaceCalls -ne [int]$case.combined) { throw "Wrong surface scope: $($case.name)" }
        }
        if ($script:packCalls -ne $case.packs) { throw "Wrong repack count: $($case.name)" }
        $expected = if ($case.packs) { 'packed fixture' } else { 'original fixture' }
        if ([IO.File]::ReadAllText($asar) -ne $expected) { throw "Unexpected ASAR write: $($case.name)" }
    }
    Write-Output "PROXY_ORCHESTRATION_PASSED cases=$($cases.Count)"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if ($resolved -ne $testRoot -or (Split-Path -Leaf $resolved) -notlike 'proxy-mode-*') { throw 'Unexpected fixture root' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
