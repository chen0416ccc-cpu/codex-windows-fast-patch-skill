[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Test-FileContainsAsciiText {
  param(
    [string]$Path,
    [string]$Needle
  )

  $encoding = [System.Text.Encoding]::ASCII
  $buffer = New-Object byte[] (4 * 1024 * 1024)
  $carry = ''
  $stream = [System.IO.File]::Open(
    $Path,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite
  )
  try {
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $text = $carry + $encoding.GetString($buffer, 0, $read)
      if ($text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
      }
      $carryLength = [Math]::Min($Needle.Length - 1, $text.Length)
      $carry = if ($carryLength -gt 0) { $text.Substring($text.Length - $carryLength) } else { '' }
    }
  } finally {
    $stream.Dispose()
  }
  return $false
}

$installerPath = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$msixPatcherPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
foreach ($repairScriptPath in @($installerPath, $msixPatcherPath)) {
  $repairScriptContent = [System.IO.File]::ReadAllText($repairScriptPath, [System.Text.UTF8Encoding]::new($false))
  foreach ($forbiddenMarker in @(
    'Test-BrowserClientProcessShimCompatible',
    'nodeProcessEnvPattern',
    'browserClientAnchor'
  )) {
    if ($repairScriptContent.Contains($forbiddenMarker)) {
      throw "repair script still rewrites trusted browser-client bytes: $repairScriptPath / $forbiddenMarker"
    }
  }
}

$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
$installedBrowserClient = Join-Path $package.InstallLocation 'app\resources\plugins\openai-bundled\plugins\chrome\scripts\browser-client.mjs'
$installedBrowserService = Join-Path $package.InstallLocation 'app\resources\plugins\openai-bundled\plugins\chrome\scripts\browser-service.mjs'
$appAsar = Join-Path $package.InstallLocation 'app\resources\app.asar'
if (-not (Test-Path -LiteralPath $installedBrowserClient -PathType Leaf)) {
  throw "installed Chrome browser client is missing: $installedBrowserClient"
}
if (-not (Test-Path -LiteralPath $installedBrowserService -PathType Leaf)) {
  throw "installed Chrome browser service is missing: $installedBrowserService"
}

$codexHome = Join-Path $env:USERPROFILE '.codex'
$marketplaceRoot = Join-Path $codexHome 'plugins\cache\openai-bundled\chrome'
$latest = Join-Path $marketplaceRoot 'latest'
if (-not (Test-Path -LiteralPath $latest -PathType Container)) {
  throw "Chrome latest cache is missing: $latest"
}

$browserClient = Join-Path $latest 'scripts\browser-client.mjs'
$browserService = Join-Path $latest 'scripts\browser-service.mjs'
if (-not (Test-Path -LiteralPath $browserClient -PathType Leaf)) {
  throw "Chrome browser client is missing: $browserClient"
}
if (-not (Test-Path -LiteralPath $browserService -PathType Leaf)) {
  throw "Chrome browser service is missing: $browserService"
}

$installedHash = (Get-FileHash -LiteralPath $installedBrowserClient -Algorithm SHA256).Hash.ToLowerInvariant()
$cachedHash = (Get-FileHash -LiteralPath $browserClient -Algorithm SHA256).Hash.ToLowerInvariant()
if ($cachedHash -ne $installedHash) {
  throw "Chrome browser client hash drift removes privileged node_repl capabilities: expected=$installedHash actual=$cachedHash path=$browserClient"
}
$trustMode = if (Test-FileContainsAsciiText $appAsar $installedHash) {
  'asar-sha256'
} else {
  foreach ($marker in @(
    'browserClientPath',
    'browserServicePath',
    'codex-host-chunked-message-v1',
    'Chrome native host did not provide a browser-client path'
  )) {
    if (-not (Test-FileContainsAsciiText $appAsar $marker)) {
      throw "installed app.asar contains neither the packaged browser-client hash nor the complete native-host path contract: missing=$marker"
    }
  }
  'native-host-paths'
}

$installedServiceHash = (Get-FileHash -LiteralPath $installedBrowserService -Algorithm SHA256).Hash.ToLowerInvariant()
$cachedServiceHash = (Get-FileHash -LiteralPath $browserService -Algorithm SHA256).Hash.ToLowerInvariant()
if ($cachedServiceHash -ne $installedServiceHash) {
  throw "Chrome browser service differs from the installed package: expected=$installedServiceHash actual=$cachedServiceHash path=$browserService"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
  throw 'node.exe not found; cannot syntax-check the Chrome browser client'
}
& $node.Source --check $browserClient
if ($LASTEXITCODE -ne 0) {
  throw "Chrome browser client syntax check failed: $browserClient"
}
& $node.Source --check $browserService
if ($LASTEXITCODE -ne 0) {
  throw "Chrome browser service syntax check failed: $browserService"
}

Write-Output "Chrome browser client contract passed: mode=$trustMode hash=$installedHash"
