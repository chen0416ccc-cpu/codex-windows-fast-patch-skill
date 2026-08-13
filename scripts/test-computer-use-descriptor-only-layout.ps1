[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'install-computer-use-local.ps1'
$package = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
if (-not $package) {
  throw 'OpenAI.Codex is not installed'
}

$pluginRoot = Join-Path $package.InstallLocation 'app\resources\plugins\openai-bundled\plugins\computer-use'
$descriptor = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$legacyClient = Join-Path $pluginRoot 'scripts\computer-use-client.mjs'
$packageSkill = Join-Path $pluginRoot 'skills\computer-use\SKILL.md'
$packageApi = Join-Path $pluginRoot 'docs\api.md'
if (-not (Test-Path -LiteralPath $descriptor -PathType Leaf)) {
  throw "Computer Use descriptor is missing: $descriptor"
}
if (Test-Path -LiteralPath $legacyClient -PathType Leaf) {
  throw "Current package is not the descriptor-only layout: $legacyClient"
}
$pluginVersion = [string]((Get-Content -Raw -LiteralPath $descriptor | ConvertFrom-Json).version)
if ([string]::IsNullOrWhiteSpace($pluginVersion)) {
  throw "Computer Use descriptor has no version: $descriptor"
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$env:TEMP = $temp
$env:TMP = $temp

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $output = @(
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -VerifyOnly 2>&1
  )
  $exitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
if ($exitCode -ne 0) {
  $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "descriptor-only Computer Use repair failed: $detail"
}

$text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ($text -notmatch '(?m)^\[codex-computer-use-local\] verification ok$') {
  throw "descriptor-only Computer Use repair did not report verification ok: $text"
}
$expectedCurrentCacheMarker = "official lightweight cache verification ok: computer-use@$pluginVersion"
if (-not $text.Contains($expectedCurrentCacheMarker)) {
  throw "descriptor-only repair did not verify the current package cache ($expectedCurrentCacheMarker): $text"
}
if ($text -notmatch 'runtime import ok: .*"exports":\["sky"\].*"method":"list_windows"') {
  throw "descriptor-only repair did not verify the official @oai/sky list_windows API: $text"
}

$cacheDescriptor = Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-bundled\computer-use\$pluginVersion\.codex-plugin\plugin.json"
if (-not (Test-Path -LiteralPath $cacheDescriptor -PathType Leaf)) {
  throw "descriptor-only repair did not create the current cache descriptor: $cacheDescriptor"
}
if ((Get-FileHash -LiteralPath $descriptor -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $cacheDescriptor -Algorithm SHA256).Hash) {
  throw "descriptor-only cache does not match the installed package: $cacheDescriptor"
}

$cacheSkill = Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-bundled\computer-use\$pluginVersion\skills\computer-use\SKILL.md"
if (-not (Test-Path -LiteralPath $cacheSkill -PathType Leaf)) {
  throw "descriptor-only repair did not create the current Computer Use skill: $cacheSkill"
}
$cacheApi = Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-bundled\computer-use\$pluginVersion\docs\api.md"
if (-not (Test-Path -LiteralPath $cacheApi -PathType Leaf)) {
  throw "descriptor-only repair did not create the current Computer Use API reference: $cacheApi"
}
foreach ($pair in @(
  @($packageSkill, $cacheSkill),
  @($packageApi, $cacheApi)
)) {
  if (-not (Test-Path -LiteralPath $pair[0] -PathType Leaf)) {
    throw "installed package is missing a Computer Use contract file: $($pair[0])"
  }
  if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
      (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
    throw "descriptor-only cache contract does not match the installed package: $($pair[1])"
  }
}

$skillContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cacheSkill
$apiContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cacheApi
$contractContent = $skillContent + "`n" + $apiContent
foreach ($stalePrompt in @('sky.documentation(', 'sky.document_info(')) {
  if ($contractContent.Contains($stalePrompt)) {
    throw "descriptor-only repair retained a missing Sky documentation API prompt: $cacheSkill / $cacheApi"
  }
}
if (-not $skillContent.Contains('const { sky } = await import("@oai/sky")')) {
  throw "descriptor-only repair omitted the official @oai/sky initialization: $cacheSkill"
}
foreach ($requiredApi in @('list_windows():', 'get_window_state(input:', 'activate_window(input:')) {
  if (-not $apiContent.Contains($requiredApi)) {
    throw "descriptor-only repair omitted the current Sky API contract ($requiredApi): $cacheApi"
  }
}

Write-Output 'descriptor-only Computer Use repair passed'
