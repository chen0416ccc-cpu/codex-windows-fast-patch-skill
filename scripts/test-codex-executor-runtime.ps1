[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'lib\toml-config.ps1')
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $scriptRoot 'install-computer-use-local.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer parse failed.' }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}
$script:ConfigBackupBeforeOverwrite = @{}
$script:LogPrefix = '[executor-runtime-test]'
$script:TestUserPin = $null
function Send-CodexExecutorEnvironmentChange { $script:BroadcastCalled = $true }
# Fixture environment access must never change the real user's CLI selection.
function Get-TestEnvironmentVariable {
  param([string]$Name, [string]$Scope)
  if ($Scope -eq 'User') { return $script:TestUserPin }
  return $script:TestProcessPin
}
function Set-TestEnvironmentVariable {
  param([string]$Name, [string]$Value, [string]$Scope)
  if ($Scope -ne 'User') { throw 'Unexpected environment mutation.' }
  $script:TestUserPin = $Value
}
$repairSource = (Get-Item Function:\Repair-CodexExecutorRuntime).ScriptBlock.ToString().
  Replace("[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')", "(Get-TestEnvironmentVariable 'CODEX_CLI_PATH' 'User')").
  Replace("[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process')", "(Get-TestEnvironmentVariable 'CODEX_CLI_PATH' 'Process')").
  Replace("[Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', `$currentCli, 'User')", "Set-TestEnvironmentVariable 'CODEX_CLI_PATH' `$currentCli 'User'")
Set-Item Function:\Repair-CodexExecutorRuntime ([scriptblock]::Create($repairSource))

function Assert-ThrowsLike {
  param([scriptblock]$Action, [string]$Expected)
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notlike $Expected) { throw "Expected '$Expected', got '$($_.Exception.Message)'" }
    return
  }
  throw "Expected rejection: $Expected"
}

$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('executor-' + [guid]::NewGuid().ToString('N'))
$localRoot = Join-Path $root 'local-codex'
$packageRoot = Join-Path $root 'package-resources'
$script:CodexHome = Join-Path $root 'codex-home'
$current = Join-Path $localRoot 'bin\1111111111111111\codex.exe'
$retired = Join-Path $localRoot 'bin\2222222222222222\codex.exe'
$config = Join-Path $script:CodexHome 'config.toml'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $current), (Split-Path -Parent $retired), $packageRoot, $script:CodexHome | Out-Null
$names = @('codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe')
Set-Content -LiteralPath (Join-Path $packageRoot 'codex.exe') -Value 'current-cli' -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $packageRoot 'codex.exe') -Destination $current
Set-Content -LiteralPath $retired -Value 'retired-cli' -Encoding ASCII
foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $packageRoot $name) -Value "current-$name" -Encoding ASCII }
$inventory = [pscustomobject]@{ LocalCodexRoot = $localRoot; PackageResourcesRoot = $packageRoot;
  CodexCliPath = $current; ReferenceCodexCliPath = (Join-Path $packageRoot 'codex.exe'); AllowedCodexCliPaths = @($current) }
$script:TestUserPin = $retired
$script:TestProcessPin = $retired
Write-Utf8NoBom $config ("model = 'fixture-model'`r`n[mcp_servers.node_repl.env]`r`nKEEP = 'fixture'`r`nCODEX_CLI_PATH = '$retired' # old pin`r`n")
$before = [IO.File]::ReadAllText($config)
Assert-ThrowsLike { Repair-CodexExecutorRuntime $inventory $script:CodexHome -VerifyOnly } '*Stale CODEX_CLI_PATH*'
if ([IO.File]::ReadAllText($config) -cne $before -or (Test-Path (Join-Path (Split-Path $current) $names[0]))) { throw 'Strict verification wrote data.' }
$result = Repair-CodexExecutorRuntime $inventory $script:CodexHome
if (-not $script:BroadcastCalled -or -not $result.RestartRequired -or $script:TestUserPin -ine $current -or
    (Get-CodexNodeReplCliPin $config) -ine $current) { throw 'Retired CLI pins were not migrated.' }
if (-not $result.BackupPath -or -not (Test-Path -LiteralPath $result.BackupPath)) { throw 'Environment rollback record missing.' }
$backup = Get-Content -LiteralPath $result.BackupPath -Raw | ConvertFrom-Json
if ([IO.File]::ReadAllText($backup.ConfigBackupPath) -cne $before -or $backup.UserCliPath -ine $retired) { throw 'Rollback backup differs from original state.' }
foreach ($name in $names) {
  if (-not (Test-FilesMatchByContent (Join-Path (Split-Path $current) $name) (Join-Path $packageRoot $name))) { throw 'Missing companion not restored.' }
  if (Test-Path (Join-Path (Split-Path $retired) $name)) { throw 'New companion mixed into retired runtime.' }
}
if ([IO.File]::ReadAllText($config) -notmatch "KEEP = 'fixture'" -or
    [IO.File]::ReadAllText($config) -notmatch "model = 'fixture-model'") { throw 'Unrelated configuration changed.' }
$beforeRepeat = (Get-FileHash -LiteralPath $config).Hash
$null = Repair-CodexExecutorRuntime $inventory $script:CodexHome
if ((Get-FileHash -LiteralPath $config).Hash -cne $beforeRepeat -or
    @(Get-ChildItem -LiteralPath (Join-Path $script:CodexHome 'backups\executor-runtime')).Count -ne 1) { throw 'Repair was not idempotent.' }

$hostPath = Join-Path (Split-Path $current) $names[0]
Set-Content -LiteralPath $hostPath -Value 'different-version-host' -Encoding ASCII
Assert-ThrowsLike { Repair-CodexExecutorRuntime $inventory $script:CodexHome } '*companion differs*'
if ((Get-Content -LiteralPath $hostPath).Trim() -cne 'different-version-host') { throw 'Unknown companion was overwritten.' }
Remove-Item -LiteralPath $hostPath
Assert-ThrowsLike { Repair-CodexExecutorRuntime $inventory $script:CodexHome -VerifyOnly } '*Missing package-matched executor companion*'
$null = Repair-CodexExecutorRuntime $inventory $script:CodexHome

$custom = Join-Path $root 'custom\codex.exe'
$script:TestUserPin = $custom
Assert-ThrowsLike { Repair-CodexExecutorRuntime $inventory $script:CodexHome } '*custom CODEX_CLI_PATH*'
if ($script:TestUserPin -ine $custom) { throw 'Custom CLI pin changed.' }
$null = Repair-CodexExecutorRuntime $inventory $script:CodexHome -VerifyOnly -SkipEnvironment
$script:TestUserPin = $null
Write-Utf8NoBom $config ("[mcp_servers.node_repl.env]`nCODEX_CLI_PATH = " + ($current | ConvertTo-Json -Compress) + " # basic string`nKEEP = 'fixture'`n")
$null = Repair-CodexExecutorRuntime $inventory $script:CodexHome -VerifyOnly
if ($null -ne $script:TestUserPin) { throw 'Absent user override was created.' }

$linkRoot = Join-Path $localRoot 'bin\3333333333333333'
New-Item -ItemType Junction -Path $linkRoot -Target (Split-Path -Parent $current) | Out-Null
$script:TestUserPin = Join-Path $linkRoot 'codex.exe'
Assert-ThrowsLike { Repair-CodexExecutorRuntime $inventory $script:CodexHome } '*custom CODEX_CLI_PATH*'
[IO.Directory]::Delete($linkRoot)
$script:TestUserPin = $null
$full = [IO.Path]::GetFullPath($root)
$parent = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\') + '\'
if (-not $full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or
    @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Fixture cleanup boundary failed.' }
Remove-Item -LiteralPath $full -Recurse -Force
Write-Output 'Codex executor runtime regression passed: stale pins, missing/mismatched companions, rollback, idempotence, custom paths and junctions.'
