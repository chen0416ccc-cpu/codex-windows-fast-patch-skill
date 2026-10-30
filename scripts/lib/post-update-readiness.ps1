function Get-RepairModelInventory {
  param([string]$CliPath)
  if (-not $CliPath) {
    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $hit = Get-ChildItem -LiteralPath $binRoot -Filter codex.exe -Recurse -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $hit) { throw 'No user-local Codex CLI is available; pass explicit CustomModels when launching repair.' }
    $CliPath = $hit.FullName
  }
  $node = Get-Command node.exe -ErrorAction Stop | Select-Object -First 1
  $probe = Join-Path (Split-Path -Parent $PSScriptRoot) 'probe-repair-models.cjs'
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source $probe $CliPath 2>&1)
    $probeExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  if ($probeExit -ne 0) { throw 'Cannot read the active model catalog; no old model defaults were substituted. Pass explicit CustomModels or fix model/list.' }
  $inventory = ($output -join '') | ConvertFrom-Json -ErrorAction Stop
  if (-not $inventory.defaultModel -or @($inventory.customModels).Count -eq 0) { throw 'Invalid active model inventory.' }
  return $inventory
}

function Get-PostUpdateTransaction {
  param([string]$LogRoot, [string]$StatusScript)
  if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { return $null }
  $current = $null
  foreach ($file in @(Get-ChildItem -LiteralPath $LogRoot -Filter '*.state.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
    # A malformed checkpoint must never be treated as proof that no installer exists.
    $status = & $StatusScript -StatePath $file.FullName -Json | ConvertFrom-Json -ErrorAction Stop
    if ($status.Status -in @('installer-running', 'installer-status-unknown', 'different-user')) {
      return [pscustomobject]@{ StatePath = $file.FullName; Assessment = $status }
    }
    if (-not $current -and $status.Status -in @('installed-needs-verification', 'verified-complete', 'verified-cleanup-needed')) {
      $current = [pscustomobject]@{ StatePath = $file.FullName; Assessment = $status }
    }
  }
  return $current
}

function Get-PostUpdatePatchAssessment {
  param([string]$LogText, [bool]$HasUltraModels)
  $results = [ordered]@{}
  foreach ($feature in @('fast-mode', 'fast-mode UI', 'custom models', 'Power slider', 'Ultra slider local-fallback',
      'locale i18n', 'plugin', 'goal', 'browser-use gate', 'computer-use gate', 'Node REPL trusted-paths',
      'Node REPL proxy environment', 'Windows CUA surface', 'bundled marketplace copy')) {
    $pattern = '(?m)^\[codex-msix-patch-win\] ' + [regex]::Escape($feature) + ' patch result: ([^\r\n]+)\r?$'
    $matches = [regex]::Matches($LogText, $pattern)
    if ($matches.Count -ne 1) { return [pscustomobject]@{ Status = 'unsupported'; Results = $results; Reason = "Missing or duplicate result: $feature" } }
    $results[$feature] = $matches[0].Groups[1].Value.Trim()
  }
  foreach ($feature in $results.Keys) {
    $value = $results[$feature]
    if ($value -match '^patched(?: \([^\r\n]*\))?$') { continue }
    if ($value -eq 'already-patched') { continue }
    if ($feature -eq 'Windows CUA surface' -and $value -eq 'already-open-native-windows') { continue }
    if ($feature -eq 'Ultra slider local-fallback' -and -not $HasUltraModels -and $value -eq 'not-applicable') { continue }
    return [pscustomobject]@{ Status = 'unsupported'; Results = $results; Reason = "Unverified patch result: $feature = $value" }
  }
  $changes = @($results.Keys | Where-Object { $results[$_] -match '^patched(?: \([^\r\n]*\))?$' })
  return [pscustomobject]@{ Status = $(if ($changes.Count) { 'repair-needed' } else { 'present' }); Results = $results; Reason = ($changes -join ', ') }
}

function Get-PostUpdateDecision {
  param([string]$TransactionStatus, [int]$PluginExitCode, [string]$AppStatus, [bool]$ModelProbePassed)
  if ($TransactionStatus -in @('installer-running', 'installer-status-unknown', 'different-user')) { return 'installer-busy-or-unknown' }
  if ($TransactionStatus -in @('installed-needs-verification', 'verified-cleanup-needed')) { return 'resume-verification' }
  if (-not $ModelProbePassed) { return 'model-probe-failed' }
  if ($PluginExitCode -ne 0) { return 'plugin-repair-needed' }
  if ($AppStatus -eq 'repair-needed') { return 'app-repair-needed' }
  if ($AppStatus -eq 'unsupported') { return 'unsupported-app-layout' }
  if ($AppStatus -eq 'present' -or $TransactionStatus -eq 'verified-complete') { return 'verified-contracts' }
  return 'app-check-needed'
}
