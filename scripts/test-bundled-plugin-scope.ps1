[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'install-computer-use-local.ps1'
$trackedPluginNames = @('sites', 'deep-research', 'visualize', 'latex')

function Get-TrackedPluginState {
  $json = @(& codex plugin list --marketplace openai-bundled --available --json 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Codex CLI failed to list bundled plugins: $($json -join [Environment]::NewLine)"
  }
  $document = (($json | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
  $entries = @($document.installed) + @($document.available)
  $state = @{}
  foreach ($name in $trackedPluginNames) {
    $entry = @($entries | Where-Object { $_.name -eq $name } | Select-Object -First 1)
    if ($entry.Count -eq 0) {
      throw "Bundled plugin is missing from CLI output: $name"
    }
    $state[$name] = "installed=$([bool]$entry[0].installed);enabled=$([bool]$entry[0].enabled)"
  }
  return $state
}

$before = Get-TrackedPluginState
$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$env:TEMP = $temp
$env:TMP = $temp

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $output = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1)
  $exitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
if ($exitCode -ne 0) {
  throw "Bundled plugin normal repair path failed: $($output -join [Environment]::NewLine)"
}

$after = Get-TrackedPluginState
foreach ($name in $trackedPluginNames) {
  if ($after[$name] -ne $before[$name]) {
    throw "Bundled plugin installation state changed for ${name}: $($before[$name]) -> $($after[$name])"
  }
}

$ErrorActionPreference = 'Continue'
try {
  $availabilityOutput = @(
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
      -StrictVerifyOnly -VerifyAllBundledPluginsAvailable 2>&1
  )
  $availabilityExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
if ($availabilityExitCode -ne 0) {
  throw "Bundled plugin availability verification failed: $($availabilityOutput -join [Environment]::NewLine)"
}
$availabilityText = ($availabilityOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ($availabilityText -notmatch '(?m)^\[codex-computer-use-local\] all bundled marketplace plugins are available without changing install state:') {
  throw "Bundled plugin availability verification did not report its read-only success marker: $availabilityText"
}

$afterAvailability = Get-TrackedPluginState
foreach ($name in $trackedPluginNames) {
  if ($afterAvailability[$name] -ne $after[$name]) {
    throw "Availability verification changed bundled plugin state for ${name}: $($after[$name]) -> $($afterAvailability[$name])"
  }
}

Write-Output 'Bundled plugin installation scope passed'
