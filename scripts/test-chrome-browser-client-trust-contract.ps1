[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
  throw "installer has parse errors: $($parseErrors[0].Message)"
}

$requiredFunctions = @('Test-FileContainsAsciiText', 'Get-ChromeBrowserClientTrustMode')
$definitions = foreach ($name in $requiredFunctions) {
  $definition = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true) | Select-Object -First 1
  if (-not $definition) {
    throw "installer function is missing: $name"
  }
  $definition.Extent.Text
}
. ([scriptblock]::Create($definitions -join "`n"))

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )
  if ([string]$Actual -cne [string]$Expected) {
    throw "$Message / expected=$Expected actual=$Actual"
  }
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixture = Join-Path $temp ('chrome-browser-client-trust-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixture | Out-Null

try {
  $sha256 = '3b9d8dcc6dc968887e8a969c63dae6380e3c1c59ff5c474eb32df08c353dad87'
  $legacyAsar = Join-Path $fixture 'legacy.asar'
  [IO.File]::WriteAllText($legacyAsar, "legacy-prefix $sha256 legacy-suffix", [Text.Encoding]::ASCII)
  Assert-Equal (Get-ChromeBrowserClientTrustMode $legacyAsar $sha256) 'asar-sha256' 'legacy hash contract was not detected'

  $nativeAsar = Join-Path $fixture 'native.asar'
  [IO.File]::WriteAllText(
    $nativeAsar,
    'browserClientPath browserServicePath codex-host-chunked-message-v1 Chrome native host did not provide a browser-client path',
    [Text.Encoding]::ASCII
  )
  Assert-Equal (Get-ChromeBrowserClientTrustMode $nativeAsar $sha256) 'native-host-paths' 'native-host path contract was not detected'

  $registration = 'browserClientPath:(0,eh.join)(e.pluginRoot,"scripts","browser-client.mjs"),browserServicePath:(0,eh.join)(e.pluginRoot,"scripts","browser-service.mjs"),codexCliPath:o.codexCliPath'
  $modern = 'codex-host-chunked-message-v1 schemaVersion:2,appServerProtocolVersion:1 ' + $registration
  $modernAsar = Join-Path $fixture 'modern.asar'
  [IO.File]::WriteAllText($modernAsar, $modern, [Text.Encoding]::ASCII)
  Assert-Equal (Get-ChromeBrowserClientTrustMode $modernAsar $sha256) 'native-host-paths' 'paired native-host registration was not detected'
  $boundaryAsar = Join-Path $fixture 'boundary.asar'
  [IO.File]::WriteAllText($boundaryAsar, ('x' * (4MB - 180)) + $modern, [Text.Encoding]::ASCII)
  Assert-Equal (Get-ChromeBrowserClientTrustMode $boundaryAsar $sha256) 'native-host-paths' 'paired registration across a read boundary was not detected'

  foreach ($content in @(
    'browserClientPath browserServicePath codex-host-chunked-message-v1',
    'unknown browser runtime contract',
    $modern.Replace('schemaVersion:2,', 'schemaVersion:1,'),
    $modern.Replace('codex-host-chunked-message-v1', 'unknown-protocol'),
    $modern.Replace('browserServicePath:(0,eh.join)', 'browserServicePath:(0,other.join)'),
    $modern.Replace('browserServicePath:(0,eh.join)(e.pluginRoot', 'browserServicePath:(0,eh.join)(other.pluginRoot'),
    $modern.Replace('browser-service.mjs', 'unknown-service.mjs'),
    $modern.Replace('browser-client.mjs', 'unknown-client.mjs'),
    $registration
  )) {
    $unknownAsar = Join-Path $fixture ([guid]::NewGuid().ToString('N') + '.asar')
    [IO.File]::WriteAllText($unknownAsar, $content, [Text.Encoding]::ASCII)
    $rejected = $false
    try {
      $null = Get-ChromeBrowserClientTrustMode $unknownAsar $sha256
    } catch {
      $rejected = $_.Exception.Message -match 'neither the packaged Chrome browser client hash nor the complete native-host path contract'
    }
    Assert-Equal $rejected $true 'unknown or partial browser-client contract was not rejected'
  }
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Chrome browser-client trust contract regression passed'
