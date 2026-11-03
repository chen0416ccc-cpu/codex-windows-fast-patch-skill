[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'lib\toml-config.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptRoot 'install-computer-use-local.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
$CodexHome = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('plugin-upgrade-' + [guid]::NewGuid().ToString('N'))
$script:ConfigBackupBeforeOverwrite = @{}
$LogPrefix = '[fixture]'
$installedRoot = Join-Path $CodexHome 'package'
$reservedRoot = Get-ReservedBundledMarketplaceRoot $CodexHome
$names = @('fixture', 'optional', 'private')
function Set-Fixture([string]$root, [string]$version) {
  $entries = @()
  foreach ($name in $names) {
    $dir = Join-Path $root "plugins\$name"
    $descriptor = @{name=$name; version=$version}
    if ($name -eq 'private') { $descriptor.publicationPolicy = 'INTERNAL_ONLY' }
    Write-Utf8NoBom (Join-Path $dir '.codex-plugin\plugin.json') ($descriptor | ConvertTo-Json)
    Write-Utf8NoBom (Join-Path $dir 'asset.txt') "$name-$version"
    $entries += @{name=$name; source=@{source='local'; path="./plugins/$name"}}
  }
  Write-Utf8NoBom (Join-Path $root '.agents\plugins\marketplace.json') (@{name='openai-bundled'; plugins=$entries} | ConvertTo-Json -Depth 6)
}
Set-Fixture $installedRoot '2.0.0'
Set-Fixture $reservedRoot '1.0.0'
# The published entry set belongs to Desktop; keep unpublished optional/private
# entries absent even though the complete package contains them.
$manifestPath = Join-Path $reservedRoot '.agents\plugins\marketplace.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifest.plugins = @($manifest.plugins | Where-Object name -ne 'optional')
ConvertTo-JsonFile $manifestPath $manifest
$manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
Sync-ReservedBundledMarketplaceVersions $installedRoot
if ((Get-PluginVersion (Join-Path $reservedRoot 'plugins\fixture')) -ne '2.0.0') { throw 'Published mirror was not refreshed' }
if ((Get-PluginVersion (Join-Path $reservedRoot 'plugins\optional')) -ne '1.0.0') { throw 'Unpublished optional plugin was touched' }
if ((Get-PluginVersion (Join-Path $reservedRoot 'plugins\private')) -ne '1.0.0') { throw 'INTERNAL_ONLY plugin was touched' }
if ((Get-FileHash -LiteralPath $manifestPath).Hash -ne $manifestHash) { throw 'Published entry set was rewritten' }
$backups = @(Get-ChildItem -LiteralPath (Join-Path $CodexHome 'backups\bundled-marketplace-drift') -Directory)
if ($backups.Count -ne 1) { throw 'Missing drift backup' }
if ((Get-Content -LiteralPath (Join-Path $backups[0].FullName 'fixture\asset.txt') -Raw) -ne 'fixture-1.0.0') { throw 'Backup did not preserve old bytes' }
Sync-ReservedBundledMarketplaceVersions $installedRoot
if (@(Get-ChildItem -LiteralPath (Join-Path $CodexHome 'backups\bundled-marketplace-drift') -Directory).Count -ne 1) { throw 'Idempotent call created another backup' }

$configPath = Join-Path $CodexHome 'config.toml'
Write-Utf8NoBom $configPath "[plugins.`"fixture@openai-bundled`"]`nenabled = false`ncustom = 'keep'`n"
$script:FixtureVersion = '1.0.0'
$script:AddCalls = 0
function Get-BundledMarketplacePluginListWithCodexCli {
  param([switch]$IncludeAvailable)
  $content = Get-Content -LiteralPath $configPath -Raw
  return [pscustomobject]@{installed=@([pscustomobject]@{name='fixture'; pluginId='fixture@openai-bundled'; version=$script:FixtureVersion; installed=$true; enabled=($content -match 'enabled = true')}); available=@([pscustomobject]@{name='optional'; pluginId='optional@openai-bundled'; version='1.0.0'; installed=$false})}
}
function Stop-OpenAiBundledExtensionHosts { param([string[]]$Roots) }
function Install-BundledMarketplacePluginWithCodexCli {
  param([string]$PluginName)
  if ($PluginName -ne 'fixture') { throw 'Attempted to install an optional plugin' }
  $script:AddCalls++
  Set-TomlTableKey $configPath '[plugins."fixture@openai-bundled"]' 'enabled' $true
  $script:FixtureVersion = '2.0.0'
}
$detected = $false
try { Test-InstalledBundledPluginVersions $installedRoot } catch {
  if ($_.Exception.Message -notlike 'installed bundled plugin version drift:*') { throw }
  $detected = $true
}
if (-not $detected -or $script:AddCalls -ne 0) { throw 'Read-only check did not detect drift without mutation' }
Sync-InstalledBundledPluginVersions $installedRoot
Test-InstalledBundledPluginVersions $installedRoot
$config = Get-Content -LiteralPath $configPath -Raw
if ($script:AddCalls -ne 1 -or $config -notmatch '(?m)^enabled = false$' -or $config -notmatch "custom = 'keep'") { throw 'Disabled state or unrelated keys were lost' }
Sync-InstalledBundledPluginVersions $installedRoot
if ($script:AddCalls -ne 1) { throw 'Current plugin was reinstalled unnecessarily' }
if (@(Get-ChildItem -LiteralPath (Join-Path $CodexHome 'backups\config') -File).Count -ne 1) { throw 'Expected one config backup per task' }
# A CLI failure after enabling must still restore disabled state.
$script:FixtureVersion = '1.0.0'
function Install-BundledMarketplacePluginWithCodexCli {
  param([string]$PluginName)
  Set-TomlTableKey $configPath '[plugins."fixture@openai-bundled"]' 'enabled' $true
  throw 'fixture registration failed'
}
$failed = $false
try { Sync-InstalledBundledPluginVersions $installedRoot } catch {
  if ($_.Exception.Message -ne 'fixture registration failed') { throw }
  $failed = $true
}
if (-not $failed -or (Get-Content -LiteralPath $configPath -Raw) -notmatch '(?m)^enabled = false$') { throw 'Failure did not preserve disabled state' }
Write-Output "Bundled plugin upgrade repair regressions passed: $CodexHome"
