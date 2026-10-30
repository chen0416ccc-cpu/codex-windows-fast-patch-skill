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

function Get-InstallerFunctionBody {
  param([string]$Name)

  $node = $installerAst.Find({
    param($candidate)
    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $candidate.Name -eq $Name
  }, $true)
  if (-not $node) {
    throw "Installer does not define the required function: $Name"
  }
  return [string]$node.Body.Extent.Text
}

function Assert-ThrowsLike {
  param(
    [scriptblock]$Action,
    [string]$ExpectedMessage
  )
  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notlike $ExpectedMessage) {
      throw "Expected failure '$ExpectedMessage' but got '$($_.Exception.Message)'"
    }
    return
  }
  throw "Expected failure '$ExpectedMessage' but the call succeeded"
}

# The production repair must wire the Desktop-visibility invariant into both the
# install path and the strict verification path, otherwise Desktop keeps taking
# its delete branch after every restart.
$enableUserEnvironmentBody = Get-InstallerFunctionBody 'Enable-UserEnvironment'
if ($enableUserEnvironmentBody -notmatch '\bSync-DesktopVisibleChromeProfileRoot\b') {
  throw 'Install path does not establish the Desktop-visible Chrome profile root'
}
$verifyBody = Get-InstallerFunctionBody 'Test-ComputerUse'
foreach ($requiredCall in @('Test-DesktopChromeExtensionVisible', 'Test-DesktopChromeNativeHostLifecycle')) {
  $callCount = ([regex]::Matches($verifyBody, "\b$requiredCall\b")).Count
  if ($callCount -lt 2) {
    throw "Verification calls $requiredCall in $callCount of the 2 supported cache layouts"
  }
}
$installBody = Get-InstallerFunctionBody 'Install-ComputerUse'
foreach ($requiredPlugin in @('browser', 'chrome')) {
  if ($installBody -notmatch "Assert-BundledMarketplacePluginInstalledWithCodexCli '$requiredPlugin'") {
    throw "Install path does not keep $requiredPlugin@openai-bundled installed"
  }
}
$assertBody = Get-InstallerFunctionBody 'Assert-BundledMarketplacePluginInstalledWithCodexCli'
if ($assertBody -notmatch '\bTest-BundledMarketplacePluginInstalledWithCodexCli\b') {
  throw 'Plugin registration does not check installed state before re-adding, which fails while Desktop holds the cache'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('desktop-chrome-visibility-' + [guid]::NewGuid().ToString('N'))
$localAppData = Join-Path $fixtureRoot 'AppData\Local'
$realChromeRoot = Join-Path $fixtureRoot 'custom-chrome\Data'
$realProfileRoot = Join-Path $realChromeRoot 'Default'
$otherChromeRoot = Join-Path $fixtureRoot 'other-chrome\Data'
$chromeCacheRoot = Join-Path $fixtureRoot "chrome-cache\26.903.71938"
$cacheScriptsRoot = Join-Path $chromeCacheRoot 'scripts'
$nodeSource = [string](Get-Command node.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source)
New-Item -ItemType Directory -Force -Path @(
  $localAppData,
  $realProfileRoot,
  $otherChromeRoot,
  $cacheScriptsRoot
) | Out-Null

$installedMarketplaceRoot = Get-InstalledBundledMarketplaceRoot
$installedChromeScripts = Join-Path $installedMarketplaceRoot 'plugins\chrome\scripts'
foreach ($officialScript in @('check-extension-installed.js', 'chromium-browser-diagnostics.mjs', 'extension-ids.json')) {
  $sourcePath = Join-Path $installedChromeScripts $officialScript
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Installed Chrome plugin is missing an official diagnostic input: $sourcePath"
  }
  Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $cacheScriptsRoot $officialScript) -Force
}

$extensionIdsDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $cacheScriptsRoot 'extension-ids.json') | ConvertFrom-Json
$chromeDiagnostics = @($extensionIdsDocument.browserDiagnostics | Where-Object { $_.browserFamily -eq 'chrome' })[0]
$extensionId = [string]$chromeDiagnostics.extensionIds[0]
$userDataSegments = @($chromeDiagnostics.windows.userDataDirectorySegments | ForEach-Object { [string]$_ })
if (($userDataSegments -join '\') -ne 'Google\Chrome\User Data') {
  throw "Official Chrome descriptor no longer uses the expected Windows profile segments: $($userDataSegments -join '\')"
}

$extensionVersionRoot = Join-Path $realProfileRoot "Extensions\$extensionId\1.26.901.11451_0"
New-Item -ItemType Directory -Force -Path $extensionVersionRoot | Out-Null
Set-Content -LiteralPath (Join-Path $extensionVersionRoot 'manifest.json') -Value '{"name":"fixture"}' -Encoding ASCII
# Chrome writes these without a BOM and the official diagnostic JSON.parses them
# verbatim, so the fixture must not introduce one.
ConvertTo-JsonFile (Join-Path $realChromeRoot 'Local State') @{
  profile = @{ last_used = 'Default'; last_active_profiles = @('Default') }
}
$preferences = @{ extensions = @{ settings = @{ $extensionId = @{ state = 1; disable_reasons = @() } } } }
ConvertTo-JsonFile (Join-Path $realProfileRoot 'Preferences') $preferences
ConvertTo-JsonFile (Join-Path $realProfileRoot 'Secure Preferences') $preferences

$runtimeInventory = [pscustomobject]@{
  NodePath = $nodeSource
}

$previousEnvironment = @{
  APPDATA = $env:APPDATA
  CODEX_CHROME_USER_DATA_DIR = $env:CODEX_CHROME_USER_DATA_DIR
  CODEX_CHROMIUM_USER_DATA_DIR = $env:CODEX_CHROMIUM_USER_DATA_DIR
  LOCALAPPDATA = $env:LOCALAPPDATA
  USERPROFILE = $env:USERPROFILE
}
try {
  $env:APPDATA = Join-Path $fixtureRoot 'AppData\Roaming'
  $env:LOCALAPPDATA = $localAppData
  $env:USERPROFILE = $fixtureRoot
  # A stale override must never be able to make the Desktop-visibility check pass.
  $env:CODEX_CHROME_USER_DATA_DIR = $realChromeRoot
  $env:CODEX_CHROMIUM_USER_DATA_DIR = $realChromeRoot

  $desktopRoot = Get-DesktopChromeUserDataDirectory
  if ($desktopRoot -ine ([System.IO.Path]::GetFullPath((Join-Path $localAppData 'Google\Chrome\User Data')))) {
    throw "Desktop profile root resolution ignored LOCALAPPDATA: $desktopRoot"
  }

  Assert-ThrowsLike {
    Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory
  } '*Chrome profile root that Codex Desktop scans does not exist*'

  $mappedRoot = Sync-DesktopVisibleChromeProfileRoot $realChromeRoot
  if ($mappedRoot -ine $desktopRoot) {
    throw "Desktop-visible mapping returned an unexpected root: $mappedRoot"
  }
  $mappedItem = Get-Item -LiteralPath $desktopRoot -Force
  if (($mappedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    throw "Desktop-visible Chrome profile root is not a reparse point: $desktopRoot"
  }
  $mappedTarget = [string](@($mappedItem.Target)[0])
  if ([System.IO.Path]::GetFullPath($mappedTarget).TrimEnd('\') -ine ([System.IO.Path]::GetFullPath($realChromeRoot).TrimEnd('\'))) {
    throw "Desktop-visible Chrome profile root points at the wrong directory: $mappedTarget"
  }

  # This is the invariant Desktop itself evaluates: with both overrides cleared,
  # the official diagnostic must still resolve the extension as enabled.
  Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory

  # Re-running the repair is idempotent and must not recreate or repoint it.
  $secondRoot = Sync-DesktopVisibleChromeProfileRoot $realChromeRoot
  if ($secondRoot -ine $desktopRoot) {
    throw "Idempotent repair returned an unexpected root: $secondRoot"
  }

  # A junction that points somewhere else is a user decision; refuse silently repointing it.
  ConvertTo-JsonFile (Join-Path $otherChromeRoot 'Local State') @{}
  Assert-ThrowsLike {
    Sync-DesktopVisibleChromeProfileRoot $otherChromeRoot
  } '*points at a different directory and was not changed*'

  # A disabled extension must fail the strict check instead of reporting success.
  $disabledPreferences = @{ extensions = @{ settings = @{ $extensionId = @{ state = 0; disable_reasons = @(1) } } } }
  ConvertTo-JsonFile (Join-Path $realProfileRoot 'Preferences') $disabledPreferences
  ConvertTo-JsonFile (Join-Path $realProfileRoot 'Secure Preferences') $disabledPreferences
  Assert-ThrowsLike {
    Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory
  } '*Codex Desktop cannot see the Chrome extension*'

  # An absent extension must fail too, and must not be masked by the override.
  Remove-Item -LiteralPath (Join-Path $realProfileRoot 'Extensions') -Recurse -Force
  ConvertTo-JsonFile (Join-Path $realProfileRoot 'Preferences') $preferences
  ConvertTo-JsonFile (Join-Path $realProfileRoot 'Secure Preferences') $preferences
  Assert-ThrowsLike {
    Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory
  } '*Codex Desktop cannot see the Chrome extension*'

  # Edge-only users must pass through Edge's own default root and official
  # diagnostic, without reusing the stale Chrome overrides or changing profiles.
  $edgeRoot = Join-Path $localAppData 'Microsoft\Edge\User Data'
  $edgeProfile = Join-Path $edgeRoot 'Default'
  $edgeExtension = Join-Path $edgeProfile "Extensions\$extensionId\1.26.1020.11845_0"
  New-Item -ItemType Directory -Force -Path $edgeExtension | Out-Null
  Set-Content -LiteralPath (Join-Path $edgeExtension 'manifest.json') -Value '{"name":"edge fixture"}' -Encoding ASCII
  ConvertTo-JsonFile (Join-Path $edgeRoot 'Local State') @{
    profile = @{ last_used = 'Default'; last_active_profiles = @('Default') }
  }
  ConvertTo-JsonFile (Join-Path $edgeProfile 'Preferences') $preferences
  ConvertTo-JsonFile (Join-Path $edgeProfile 'Secure Preferences') $preferences
  Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory
  if ($env:CODEX_CHROME_USER_DATA_DIR -cne $realChromeRoot -or
      $env:CODEX_CHROMIUM_USER_DATA_DIR -cne $realChromeRoot) {
    throw 'Edge fallback did not restore the caller profile overrides'
  }
  if ((Get-Item -LiteralPath $edgeRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Edge verification changed the Edge profile root'
  }
  ConvertTo-JsonFile (Join-Path $edgeProfile 'Preferences') $disabledPreferences
  ConvertTo-JsonFile (Join-Path $edgeProfile 'Secure Preferences') $disabledPreferences
  Assert-ThrowsLike {
    Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory
  } '*Edge verification also failed*'
  # A registered extension with no installed files must still fail.
  [IO.File]::Delete((Join-Path $edgeExtension 'manifest.json'))
  [IO.Directory]::Delete($edgeExtension)
  ConvertTo-JsonFile (Join-Path $edgeProfile 'Preferences') $preferences
  ConvertTo-JsonFile (Join-Path $edgeProfile 'Secure Preferences') $preferences
  Assert-ThrowsLike {
    Test-DesktopChromeExtensionVisible $chromeCacheRoot $runtimeInventory
  } '*Edge verification also failed*'

  # A real directory at the Desktop path belongs to the user; never replace it.
  [System.IO.Directory]::Delete($desktopRoot)
  New-Item -ItemType Directory -Force -Path $desktopRoot | Out-Null
  $preservedRoot = Sync-DesktopVisibleChromeProfileRoot $realChromeRoot
  $preservedItem = Get-Item -LiteralPath $preservedRoot -Force
  if (($preservedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Repair replaced a real Chrome profile directory with a junction: $preservedRoot"
  }
} finally {
  foreach ($name in $previousEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
  }
  $leakedRoot = Join-Path $localAppData 'Google\Chrome\User Data'
  if (Test-Path -LiteralPath $leakedRoot) {
    $leakedItem = Get-Item -LiteralPath $leakedRoot -Force
    if (($leakedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      [System.IO.Directory]::Delete($leakedRoot)
    }
  }
}

Write-Output "Desktop Chrome profile visibility regression passed: $fixtureRoot"
