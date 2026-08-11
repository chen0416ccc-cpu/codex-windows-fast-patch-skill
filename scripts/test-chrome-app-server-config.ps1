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

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('chrome-app-server-config-' + [guid]::NewGuid().ToString('N'))
$script:CodexHome = Join-Path $fixtureRoot 'codex-home'
$chromeRoot = Join-Path $fixtureRoot 'chrome\26.803.41515'
$scriptsRoot = Join-Path $chromeRoot 'scripts'
$hostRoot = Join-Path $chromeRoot 'extension-host\windows\x64'
$descriptorRoot = Join-Path $chromeRoot '.codex-plugin'
$hostPath = Join-Path $hostRoot 'extension-host.exe'
$configPath = Join-Path $hostRoot 'extension-host-config.json'
$browserClientPath = Join-Path $scriptsRoot 'browser-client.mjs'
$localAppData = Join-Path $fixtureRoot 'local-app-data'
$codexCliPath = Join-Path $fixtureRoot 'runtime\codex.exe'
$nodePath = Join-Path $fixtureRoot 'runtime\node.exe'
$nodeReplPath = Join-Path $fixtureRoot 'runtime\node_repl.exe'
$nodeSource = [string](Get-Command node.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source)

New-Item -ItemType Directory -Force -Path $script:CodexHome, $scriptsRoot, $hostRoot, $descriptorRoot, $localAppData, (Split-Path -Parent $codexCliPath) | Out-Null
Set-Content -LiteralPath $hostPath -Value 'fixture host' -Encoding ASCII
Set-Content -LiteralPath $browserClientPath -Value 'export const fixture = true;' -Encoding ASCII
Set-Content -LiteralPath $codexCliPath -Value 'fixture codex' -Encoding ASCII
Copy-Item -LiteralPath $nodeSource -Destination $nodePath -Force
Set-Content -LiteralPath $nodeReplPath -Value 'fixture node repl' -Encoding ASCII
@{ name = 'chrome'; version = '26.803.41515' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $descriptorRoot 'plugin.json') -Encoding UTF8
$extensionIdsFixture = @{
  extensionIds = @('hehggadaopoacecdllhhajmbjkdcmajg', 'odlomjlbamekndcpllcnffbgeohgkmjh')
  extensionHostName = 'com.openai.codexextension'
  windowsNativeMessaging = @{ registryRoot = 'HKCU\Software\Google\Chrome\NativeMessagingHosts' }
}
ConvertTo-JsonFile (Join-Path $scriptsRoot 'extension-ids.json') $extensionIdsFixture

$fakeInstaller = @'
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

export async function install({ appServerRuntimePaths }) {
  const chromeRoot = path.resolve(import.meta.dirname, "..");
  const hostRoot = path.join(chromeRoot, "extension-host", "windows", "x64");
  const manifestRoot = path.join(process.env.LOCALAPPDATA, "OpenAI", "extension");
  await mkdir(hostRoot, { recursive: true });
  const config = {
    schemaVersion: 1,
    channel: "prod",
    browserClientPath: path.join(chromeRoot, "scripts", "browser-client.mjs"),
    codexCliPath: appServerRuntimePaths.codexCliPath,
    nodePath: appServerRuntimePaths.nodePath,
    nodeReplPath: appServerRuntimePaths.nodeReplPath,
    proxyHost: "127.0.0.1",
    proxyPort: 0,
  };
  await writeFile(path.join(hostRoot, "extension-host-config.json"), JSON.stringify(config, null, 2));
  await mkdir(manifestRoot, { recursive: true });
  await writeFile(path.join(manifestRoot, "com.openai.codexextension.json"), JSON.stringify({
    allowed_origins: [
      "chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/",
      "chrome-extension://odlomjlbamekndcpllcnffbgeohgkmjh/",
    ],
    description: "Codex chrome native messaging host",
    name: "com.openai.codexextension",
    path: path.join(hostRoot, "extension-host.exe"),
    type: "stdio",
  }, null, 2));
}
'@
Set-Content -LiteralPath (Join-Path $scriptsRoot 'installManifest.mjs') -Value $fakeInstaller -Encoding UTF8

$runtimeInventory = [pscustomobject]@{
  CodexCliPath = $codexCliPath
  NodePath = $nodePath
  NodeReplPath = $nodeReplPath
  AllowedCodexCliPaths = @($codexCliPath)
  AllowedCuaBinRoots = @((Split-Path -Parent $nodePath))
  ReferenceCodexCliPath = $codexCliPath
  ReferenceNodePath = $nodePath
  ReferenceNodeReplPath = $nodeReplPath
}

$previousLocalAppData = $env:LOCALAPPDATA
try {
  $env:LOCALAPPDATA = $localAppData
  Invoke-ChromeOfficialManifestInstall $chromeRoot $runtimeInventory
  Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory

Remove-Item -LiteralPath $configPath -Force
Assert-ThrowsLike {
  Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory
} '*app-server host config is missing*'

Invoke-ChromeOfficialManifestInstall $chromeRoot $runtimeInventory
$config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
$config.nodePath = Join-Path $fixtureRoot 'runtime\missing-node.exe'
ConvertTo-JsonFile $configPath $config
Assert-ThrowsLike {
  Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory
} '*missing required path nodePath*'

$config.nodePath = $nodePath
$staleCodexPath = Join-Path $fixtureRoot 'runtime\stale-codex.exe'
Set-Content -LiteralPath $staleCodexPath -Value 'stale codex' -Encoding ASCII
$config.codexCliPath = $staleCodexPath
ConvertTo-JsonFile $configPath $config
Assert-ThrowsLike {
  Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory
} '*codexCliPath does not match the current Codex runtime*'

$equivalentCodexPath = Join-Path $fixtureRoot 'equivalent-runtime\codex.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $equivalentCodexPath) | Out-Null
Copy-Item -LiteralPath $codexCliPath -Destination $equivalentCodexPath -Force
$runtimeInventory.AllowedCodexCliPaths = @($codexCliPath, $equivalentCodexPath)
$config.codexCliPath = $equivalentCodexPath
ConvertTo-JsonFile $configPath $config
Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory

$chromeAlias = Join-Path $fixtureRoot 'chrome-alias'
New-Item -ItemType Junction -Path $chromeAlias -Target $chromeRoot | Out-Null
$settings = Get-ChromeNativeMessagingSettings $chromeRoot
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $settings.ManifestPath | ConvertFrom-Json
$manifest.path = Join-Path $chromeAlias 'extension-host\windows\x64\extension-host.exe'
ConvertTo-JsonFile $settings.ManifestPath $manifest
$config.browserClientPath = Join-Path $chromeAlias 'scripts\browser-client.mjs'
ConvertTo-JsonFile $configPath $config
Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory

$sameHashOutsideCache = Join-Path $fixtureRoot 'same-hash-outside-cache\extension-host.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sameHashOutsideCache) | Out-Null
Copy-Item -LiteralPath $hostPath -Destination $sameHashOutsideCache -Force
$manifest.path = $sameHashOutsideCache
ConvertTo-JsonFile $settings.ManifestPath $manifest
Assert-ThrowsLike {
  Test-ChromeAppServerHostConfig $chromeRoot $runtimeInventory
} '*not beside a current stable cache host*'
} finally {
  $env:LOCALAPPDATA = $previousLocalAppData
}

$inventoryFixture = Join-Path $fixtureRoot 'runtime-inventory'
$packageResourcesRoot = Join-Path $inventoryFixture 'package-resources'
$localCodexRoot = Join-Path $inventoryFixture 'local-codex'
$packageCuaBin = Join-Path $packageResourcesRoot 'cua_node\bin'
New-Item -ItemType Directory -Force -Path $packageCuaBin, $localCodexRoot | Out-Null
Set-Content -LiteralPath (Join-Path $packageResourcesRoot 'codex.exe') -Value 'current codex fixture' -Encoding ASCII
Copy-Item -LiteralPath $nodeSource -Destination (Join-Path $packageCuaBin 'node.exe') -Force
Set-Content -LiteralPath (Join-Path $packageCuaBin 'node_repl.exe') -Value 'current repl fixture' -Encoding ASCII
Assert-ThrowsLike {
  Get-CurrentCodexAppServerRuntimeInventory -PackageResourcesRoot $packageResourcesRoot -LocalCodexRoot $localCodexRoot
} '*no current user-local Codex CLI matches*'

$pluginAppServerRoot = Join-Path $localCodexRoot 'bin\.plugin-appserver'
New-Item -ItemType Directory -Force -Path $pluginAppServerRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $packageResourcesRoot 'codex.exe') -Destination (Join-Path $pluginAppServerRoot 'codex.exe') -Force
Assert-ThrowsLike {
  Get-CurrentCodexAppServerRuntimeInventory -PackageResourcesRoot $packageResourcesRoot -LocalCodexRoot $localCodexRoot
} '*no current user-local Codex CLI matches*'

$localBinRoot = Join-Path $localCodexRoot 'bin\current'
New-Item -ItemType Directory -Force -Path $localBinRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $packageResourcesRoot 'codex.exe') -Destination (Join-Path $localBinRoot 'codex.exe') -Force
Assert-ThrowsLike {
  Get-CurrentCodexAppServerRuntimeInventory -PackageResourcesRoot $packageResourcesRoot -LocalCodexRoot $localCodexRoot
} '*no current user-local CUA Node runtime matches*'

$localCuaBin = Join-Path $localCodexRoot 'runtimes\cua_node\current\bin'
New-Item -ItemType Directory -Force -Path $localCuaBin | Out-Null
Copy-Item -LiteralPath (Join-Path $packageCuaBin 'node.exe') -Destination (Join-Path $localCuaBin 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $packageCuaBin 'node_repl.exe') -Destination (Join-Path $localCuaBin 'node_repl.exe') -Force
$discoveredInventory = Get-CurrentCodexAppServerRuntimeInventory -PackageResourcesRoot $packageResourcesRoot -LocalCodexRoot $localCodexRoot
if ($discoveredInventory.CodexCliPath -match '(?i)[\\/]package-resources[\\/]' -or
    $discoveredInventory.NodePath -match '(?i)[\\/]package-resources[\\/]') {
  throw 'Runtime inventory selected the protected package reference instead of the user-local copy'
}

Write-Output "Chrome app-server config regression passed: $fixtureRoot"
