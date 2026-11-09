param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$functions = @{}
foreach ($name in @('Resolve-ExistingDirectory', 'Resolve-ExistingFileProviderPath', 'Get-FinalFileIdentityPath',
    'Test-NodeReplTrustedRootCoverage', 'Test-NodeReplTrustedPathRepair')) {
  $definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $false)
  if (-not $definition) { throw "Production function is missing: $name" }
  $functions[$name] = $definition.Extent.Text
  if ($name -ne 'Test-NodeReplTrustedPathRepair') { Invoke-Expression $definition.Extent.Text }
}
# Substitute only the registry read; the checker and filesystem logic are production code.
$userRead = "[Environment]::GetEnvironmentVariable('NODE_REPL_TRUSTED_CODE_PATHS', 'User')"
$checker = $functions['Test-NodeReplTrustedPathRepair']
if ($checker.Split(@($userRead), [StringSplitOptions]::None).Count -ne 2) { throw 'User environment seam changed' }
Invoke-Expression $checker.Replace($userRead, '$script:fixtureUserPaths')
function Get-NodeReplTrustedRoots { param($MarketplaceRoot) return @($script:fixtureRequiredRoot) }
function Get-NodeReplConfiguredTrustedRoots { param($ConfigPath) return @($script:fixtureConfigRoots) }
function Test-FileContainsAsciiText { param($Path, $Text) $script:markerReads++; return $script:fixtureMarker }
function Write-Log { param($Message) }

$parent = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\')
$root = Join-Path $parent ('trusted-coverage-' + [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $root 'home'
$required = Join-Path $fixtureHome 'marketplaces\live'
$sibling = Join-Path $fixtureHome 'marketplaces\live-extra'
$outside = Join-Path $root 'outside'
$alias = Join-Path $root 'home-alias'
$escaped = Join-Path $fixtureHome 'escaped-marketplace'
$marketplace = Join-Path $root 'package\app\resources\plugins\openai-bundled'
$userBefore = [Environment]::GetEnvironmentVariable('NODE_REPL_TRUSTED_CODE_PATHS', 'User')
$checks = 0
try {
  foreach ($path in @($required, $sibling, $outside, $marketplace)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
  $asar = Join-Path $root 'package\app\resources\app.asar'
  [IO.File]::WriteAllText($asar, 'fixture', [Text.UTF8Encoding]::new($false))
  New-Item -ItemType Junction -Path $alias -Target $fixtureHome | Out-Null
  New-Item -ItemType Junction -Path $escaped -Target $outside | Out-Null

  $cases = @(
    @{ Path=$required; Roots=@($required); Expected=$true },
    @{ Path=$required; Roots=@($fixtureHome); Expected=$true },
    @{ Path=$required; Roots=@($fixtureHome.ToUpperInvariant() + '\'); Expected=$true },
    @{ Path=$required; Roots=@($fixtureHome.Replace('\','/')); Expected=$true },
    @{ Path=$sibling; Roots=@($required); Expected=$false },
    @{ Path=$required; Roots=@((Join-Path $root 'missing')); Expected=$false },
    @{ Path=$required; Roots=@('.\home', 'C:relative'); Expected=$false },
    @{ Path=$required; Roots=@((Join-Path $root 'missing'), $fixtureHome); Expected=$true },
    @{ Path=$outside; Roots=@($fixtureHome); Expected=$false },
    @{ Path=$required; Roots=@($alias); Expected=$true },
    @{ Path=$escaped; Roots=@($fixtureHome); Expected=$false },
    @{ Path=$escaped; Roots=@($outside); Expected=$true }
  )
  foreach ($case in $cases) {
    $actual = Test-NodeReplTrustedRootCoverage $case.Path $case.Roots
    if ($actual -ne $case.Expected) { throw "Unexpected coverage for $($case.Path) under $($case.Roots -join ';')" }
    $checks++
  }
  if ((Get-FinalFileIdentityPath $asar) -ne [IO.Path]::GetFullPath($asar)) { throw 'Existing file identity changed' }
  $checks++
  $caught = $false
  try { Get-FinalFileIdentityPath $fixtureHome | Out-Null } catch { $caught = $true }
  if (-not $caught) { throw 'Default file-only identity accepted a directory' }
  $checks++

  function Assert-Checker([string]$ExpectedError) {
    $failure = $null
    try { Test-NodeReplTrustedPathRepair 'unused.toml' $marketplace $marketplace $fixtureHome }
    catch { $failure = $_.Exception.Message }
    if ($ExpectedError) {
      if (-not $failure -or $failure -notmatch $ExpectedError) { throw "Expected $ExpectedError, observed $failure" }
    } elseif ($failure) { throw $failure }
    $script:checks++
  }
  $script:fixtureRequiredRoot = $required
  $script:fixtureConfigRoots = @($fixtureHome)
  $script:fixtureUserPaths = $fixtureHome
  $script:fixtureMarker = $false
  $script:markerReads = 0
  Assert-Checker
  if ($script:markerReads) { throw 'Home-contained root required an external ASAR marker' }
  $script:fixtureConfigRoots = @($sibling)
  Assert-Checker 'config.toml Node REPL trusted paths'
  $script:fixtureConfigRoots = @($fixtureHome)
  $script:fixtureUserPaths = $sibling
  Assert-Checker 'user NODE_REPL_TRUSTED_CODE_PATHS'
  $script:fixtureRequiredRoot = $outside
  $script:fixtureConfigRoots = @($root)
  $script:fixtureUserPaths = $root
  Assert-Checker 'does not preserve external NODE_REPL_TRUSTED_CODE_PATHS'
  $script:fixtureMarker = $true
  Assert-Checker
  $script:fixtureRequiredRoot = $escaped
  $script:fixtureMarker = $false
  Assert-Checker 'does not preserve external NODE_REPL_TRUSTED_CODE_PATHS'
  $script:fixtureMarker = $true
  Assert-Checker
  if ([Environment]::GetEnvironmentVariable('NODE_REPL_TRUSTED_CODE_PATHS', 'User') -cne $userBefore) {
    throw 'The fixture modified user environment'
  }
  Write-Output "TRUSTED_ROOT_COVERAGE_PASSED checks=$checks"
} finally {
  foreach ($junction in @($alias, $escaped)) {
    if (Test-Path -LiteralPath $junction) {
      if (-not ((Get-Item -LiteralPath $junction -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Fixture junction changed: $junction"
      }
      [IO.Directory]::Delete($junction)
    }
  }
  if (Test-Path -LiteralPath $root) {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if (-not $resolved.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase) -or
        @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint).Count) {
      throw 'Fixture cleanup escaped its ordinary temporary root'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
