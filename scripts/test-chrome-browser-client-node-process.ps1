[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$codexHome = Join-Path $env:USERPROFILE '.codex'
$marketplaceRoot = Join-Path $codexHome 'plugins\cache\openai-bundled\chrome'
$latest = Join-Path $marketplaceRoot 'latest'
if (-not (Test-Path -LiteralPath $latest -PathType Container)) {
  throw "Chrome latest cache is missing: $latest"
}

$browserClient = Join-Path $latest 'scripts\browser-client.mjs'
if (-not (Test-Path -LiteralPath $browserClient -PathType Leaf)) {
  throw "Chrome browser client is missing: $browserClient"
}

$content = [System.IO.File]::ReadAllText($browserClient, [System.Text.UTF8Encoding]::new($false))
if ($content.Contains('node:process')) {
  throw "Chrome browser client still imports node:process: $browserClient"
}
$localProxy = "  const process = processShim;`n  const global = Object.create(globalThis, { process: { value: processShim, enumerable: true } });"
$hasDirectShim = $true
foreach ($marker in @(
  'const processShim = {',
  'processShim.on("beforeExit"',
  'processShim.memoryUsage().rss',
  'typeof processShim.versions.icu'
)) {
  if (-not $content.Contains($marker)) {
    $hasDirectShim = $false
  }
}
if (-not $content.Contains($localProxy) -and -not $hasDirectShim) {
  throw "Chrome browser client has neither a local proxy nor a direct process shim: $browserClient"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
  throw 'node.exe not found; cannot syntax-check the Chrome browser client'
}
& $node.Source --check $browserClient
if ($LASTEXITCODE -ne 0) {
  throw "Chrome browser client syntax check failed: $browserClient"
}

Write-Output 'Chrome browser client process shim passed'
