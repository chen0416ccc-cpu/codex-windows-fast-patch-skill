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

$installFunction = $installerAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Install-ComputerUse'
}, $true)
if (-not $installFunction -or $installFunction.Body.Extent.Text -notmatch '\bInvoke-ChromeOfficialManifestInstall\b') {
  throw 'Production Computer Use repair does not call the official Chrome manifest installer'
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
  throw "Expected failure '$ExpectedMessage' but the verification passed"
}

$installedMarketplaceRoot = Get-InstalledBundledMarketplaceRoot
$installedChromeRoot = Join-Path $installedMarketplaceRoot 'plugins\chrome'
$chromeVersion = Get-PluginVersion $installedChromeRoot
$officialInstallerPath = Join-Path $installedChromeRoot 'scripts\installManifest.mjs'
$officialExtensionIdsPath = Join-Path $installedChromeRoot 'scripts\extension-ids.json'
foreach ($requiredPath in @($officialInstallerPath, $officialExtensionIdsPath)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Installed Chrome plugin is missing an official regression input: $requiredPath"
  }
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('chrome-native-host-origin-drift-' + [guid]::NewGuid().ToString('N'))
$script:CodexHome = Join-Path $fixtureRoot 'codex-home'
$chromeRoot = Join-Path $fixtureRoot "chrome\$chromeVersion"
$scriptsRoot = Join-Path $chromeRoot 'scripts'
$hostRoot = Join-Path $chromeRoot 'extension-host\windows\x64'
$descriptorRoot = Join-Path $chromeRoot '.codex-plugin'
$fixtureUserProfile = Join-Path $fixtureRoot 'user'
$localAppData = Join-Path $fixtureUserProfile 'AppData\Local'
$runtimeRoot = Join-Path $fixtureRoot 'runtime'
$fakeBinRoot = Join-Path $fixtureRoot 'fake-bin'
$fakeRegPath = Join-Path $fakeBinRoot 'reg.exe'
$fakeRegLog = Join-Path $fixtureRoot 'reg-args.txt'
$nodeSource = [string](Get-Command node.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source)
$nodePath = Join-Path $runtimeRoot 'node.exe'
$codexCliPath = Join-Path $runtimeRoot 'codex.exe'
$nodeReplPath = Join-Path $runtimeRoot 'node_repl.exe'
New-Item -ItemType Directory -Force -Path $script:CodexHome, $scriptsRoot, $hostRoot, $descriptorRoot, $localAppData, $runtimeRoot, $fakeBinRoot | Out-Null
Copy-Item -LiteralPath $nodeSource -Destination $nodePath -Force
Copy-Item -LiteralPath $officialInstallerPath -Destination (Join-Path $scriptsRoot 'installManifest.mjs') -Force
Copy-Item -LiteralPath $officialExtensionIdsPath -Destination (Join-Path $scriptsRoot 'extension-ids.json') -Force
Set-Content -LiteralPath (Join-Path $hostRoot 'extension-host.exe') -Value 'fixture host' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $scriptsRoot 'browser-client.mjs') -Value 'export const fixture = true;' -Encoding ASCII
Set-Content -LiteralPath $codexCliPath -Value 'fixture codex' -Encoding ASCII
Set-Content -LiteralPath $nodeReplPath -Value 'fixture node repl' -Encoding ASCII
@{ name = 'chrome'; version = $chromeVersion } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $descriptorRoot 'plugin.json') -Encoding UTF8

$fakeRegSource = @'
using System;
using System.IO;

namespace CodexChromeOriginFixture {
  public static class FakeReg {
    public static int Main(string[] args) {
      string logPath = Environment.GetEnvironmentVariable("CODEX_FAKE_REG_LOG");
      if (String.IsNullOrWhiteSpace(logPath)) return 2;
      File.WriteAllLines(logPath, args);
      return 0;
    }
  }
}
'@
Add-Type -TypeDefinition $fakeRegSource -OutputAssembly $fakeRegPath -OutputType ConsoleApplication

$extensionIdsDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $scriptsRoot 'extension-ids.json') | ConvertFrom-Json
$extensionIds = @($extensionIdsDocument.extensionIds | ForEach-Object { [string]$_ })
if ($extensionIds.Count -eq 0) {
  throw 'Official Chrome extension ID descriptor has no top-level extensionIds'
}

$previousEnvironment = @{
  CODEX_FAKE_REG_LOG = $env:CODEX_FAKE_REG_LOG
  HOME = $env:HOME
  HOMEDRIVE = $env:HOMEDRIVE
  HOMEPATH = $env:HOMEPATH
  LOCALAPPDATA = $env:LOCALAPPDATA
  PATH = $env:PATH
  USERPROFILE = $env:USERPROFILE
}
try {
  $env:CODEX_FAKE_REG_LOG = $fakeRegLog
  $env:HOME = $fixtureUserProfile
  $env:HOMEDRIVE = (Split-Path -Qualifier $fixtureUserProfile).TrimEnd('\')
  $env:HOMEPATH = $fixtureUserProfile.Substring((Split-Path -Qualifier $fixtureUserProfile).Length)
  $env:LOCALAPPDATA = $localAppData
  $env:PATH = "$fakeBinRoot;$($previousEnvironment.PATH)"
  $env:USERPROFILE = $fixtureUserProfile

  $runtimeInventory = [pscustomobject]@{
    CodexCliPath = $codexCliPath
    NodePath = $nodePath
    NodeReplPath = $nodeReplPath
  }
  Invoke-ChromeOfficialManifestInstall $chromeRoot $runtimeInventory

  $settings = Get-ChromeNativeMessagingSettings $chromeRoot
  $script:FixtureRegistryPath = $settings.ManifestPath
  function Get-ChromeNativeMessagingRegistryManifestPath {
    param([string]$RegistryKey)
    return $script:FixtureRegistryPath
  }
  Test-ChromeNativeMessagingManifest $chromeRoot

  $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $settings.ManifestPath | ConvertFrom-Json
  $expectedOrigins = @($extensionIds | ForEach-Object { "chrome-extension://$_/" })
  if (-not (Test-OrdinalStringArrayEqual -Actual @($manifest.allowed_origins) -Expected $expectedOrigins)) {
    throw "Official installer did not write exact current origins: $($manifest.allowed_origins -join ',')"
  }

  $regArgs = @(Get-Content -LiteralPath $fakeRegLog)
  $expectedRegistryKey = 'HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension'
  foreach ($requiredArgument in @('add', $expectedRegistryKey, '/ve', '/t', 'REG_SZ', '/d', $settings.ManifestPath, '/f')) {
    if ($regArgs -cnotcontains $requiredArgument) {
      throw "Official installer did not send the expected isolated reg.exe argument: $requiredArgument"
    }
  }

  $manifest.allowed_origins = @($expectedOrigins[0])
  ConvertTo-JsonFile $settings.ManifestPath $manifest
  Assert-ThrowsLike {
    Test-ChromeNativeMessagingManifest $chromeRoot
  } '*allowed_origins do not match*'
} finally {
  foreach ($name in $previousEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
  }
}

Write-Output "Chrome native-host official-installer origin regression passed: $fixtureRoot"
