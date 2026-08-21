[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'install-computer-use-local.ps1'
$parseErrors = $null
$tokens = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $installer,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "Installer has PowerShell parse errors: $($parseErrors.Message -join '; ')"
}
foreach ($statement in $installerAst.EndBlock.Statements) {
  if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}

# Loading only the function definitions skips the installer's script-level state,
# which Backup-ConfigBeforeOverwrite needs before any config write.
$script:ConfigBackupBeforeOverwrite = @{}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('bundled-marketplace-source-' + [guid]::NewGuid().ToString('N'))
$script:CodexHome = Join-Path $fixtureRoot 'codex-home'
New-Item -ItemType Directory -Force -Path $script:CodexHome | Out-Null

$stableRoot = Join-Path $script:CodexHome 'marketplaces\openai-bundled-local'
$stagedRoot = Join-Path $script:CodexHome '.tmp\bundled-marketplaces\openai-bundled'
New-Item -ItemType Directory -Force -Path $stableRoot | Out-Null
$configPath = Join-Path $script:CodexHome 'config.toml'

# Get-TomlTableStringValue must read the value the installer itself writes,
# including the literal backslashes and quote escaping used for Windows paths.
Set-TomlTable $configPath '[marketplaces.openai-bundled]' @{
  source = '\\?\C:\does\not\exist\o''brien'
  source_type = 'local'
}
$readBack = Get-TomlTableStringValue $configPath '[marketplaces.openai-bundled]' 'source'
if ($readBack -cne '\\?\C:\does\not\exist\o''brien') {
  throw "Get-TomlTableStringValue did not round-trip a single-quoted Windows path: '$readBack'"
}
if ((Get-TomlTableStringValue $configPath '[marketplaces.openai-bundled]' 'missing_key') -cne '') {
  throw 'Get-TomlTableStringValue must return an empty string for a missing key'
}
if ((Get-TomlTableStringValue $configPath '[marketplaces.absent]' 'source') -cne '') {
  throw 'Get-TomlTableStringValue must return an empty string for a missing table'
}
Set-TomlTableKey $configPath '[marketplaces.double-quoted]' 'source' 'C:\quoted' 'test'
[System.IO.File]::WriteAllText(
  $configPath,
  ([System.IO.File]::ReadAllText($configPath, [System.Text.UTF8Encoding]::new($false)) -replace
    "(?m)^source = 'C:\\\\quoted'$", 'source = "C:\quoted"'),
  [System.Text.UTF8Encoding]::new($false)
)
if ((Get-TomlTableStringValue $configPath '[marketplaces.double-quoted]' 'source') -cne 'C:\quoted') {
  throw 'Get-TomlTableStringValue must also read double-quoted values'
}

function Set-ProbeResult {
  param([object]$Value)

  # Override at script scope: the installer's own definition lives there, so a
  # global stub would never win function lookup.
  $global:ProbeResult = $Value
  $global:ProbeCalls = 0
  Set-Item -Path 'function:script:Test-CodexReservedMarketplaceSourceRestricted' -Value {
    $global:ProbeCalls++
    return $global:ProbeResult
  }
}

# The staged root is always allowed, so it must never pay for a probe.
Set-ProbeResult $true
$stagedSource = Get-BundledMarketplaceConfigSource $stagedRoot $configPath
if ($stagedSource -cne ('\\?\' + $stagedRoot)) {
  throw "The Desktop-staged root must be pinned verbatim: $stagedSource"
}
if ($global:ProbeCalls -ne 0) {
  throw 'The Desktop-staged root must not trigger a reserved-source probe'
}

# Unrestricted CLI: keep pinning the stable mirror the installer maintains.
Set-ProbeResult $false
if ((Get-BundledMarketplaceConfigSource $stableRoot $configPath) -cne ('\\?\' + $stableRoot)) {
  throw 'An unrestricted CLI must keep the stable mirror pin'
}
if ($global:ProbeCalls -ne 1) {
  throw "The stable mirror must probe exactly once: $($global:ProbeCalls)"
}

# Inconclusive probe must not change behaviour either.
Set-ProbeResult $null
if ((Get-BundledMarketplaceConfigSource $stableRoot $configPath) -cne ('\\?\' + $stableRoot)) {
  throw 'An inconclusive probe must keep the stable mirror pin'
}

# Restricted CLI with a staged root present: pin the staged root instead, so the
# reserved `openai-bundled` name is not silently dropped by the CLI.
Set-ProbeResult $true
New-Item -ItemType Directory -Force -Path $stagedRoot | Out-Null
if ((Get-BundledMarketplaceConfigSource $stableRoot $configPath) -cne ('\\?\' + $stagedRoot)) {
  throw 'A restricted CLI must fall back to the Desktop-staged root'
}

# Restricted CLI with no staged root: keep whatever source is already configured
# rather than overwriting a working pin with one the CLI will ignore.
Remove-Item -LiteralPath $stagedRoot -Recurse -Force
Set-TomlTable $configPath '[marketplaces.openai-bundled]' @{
  source = '\\?\C:\already\working'
  source_type = 'local'
}
Set-ProbeResult $true
if ((Get-BundledMarketplaceConfigSource $stableRoot $configPath) -cne '\\?\C:\already\working') {
  throw 'A restricted CLI with no staged root must preserve the configured source'
}

# Restricted CLI, no staged root and nothing configured: fall back to the stable
# mirror and warn rather than writing an empty source.
Remove-Item -LiteralPath $configPath -Force
Set-ProbeResult $true
if ((Get-BundledMarketplaceConfigSource $stableRoot $configPath) -cne ('\\?\' + $stableRoot)) {
  throw 'A restricted CLI with nothing to fall back to must keep the stable mirror pin'
}

Write-Host "bundled marketplace source selection regression passed: $fixtureRoot"
