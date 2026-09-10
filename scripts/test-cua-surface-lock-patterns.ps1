[CmdletBinding()]
param(
  [string]$NodePath
)

# Fixture-level tests for repair-cua-surface-lock.ps1. Nothing here touches the real Codex home:
# every case builds its own throwaway tree, so an unknown future layout can never be edited by a test.
$ErrorActionPreference = 'Stop'
$LogPrefix = '[test-cua-surface-lock]'
$script:Failures = 0

$RepairScript = Join-Path $PSScriptRoot 'repair-cua-surface-lock.ps1'
if (-not (Test-Path -LiteralPath $RepairScript -PathType Leaf)) {
  throw "$LogPrefix repair script not found: $RepairScript"
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if ($Condition) {
    Write-Host "$LogPrefix PASS $Message"
  } else {
    Write-Host "$LogPrefix FAIL $Message"
    $script:Failures++
  }
}

function New-FixtureHome {
  param([string]$Label)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("cua-surface-lock-" + $Label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $plugin = Join-Path $root 'plugins\cache\openai-bundled\unified-computer-use\99.0.0'
  New-Item -ItemType Directory -Force -Path (Join-Path $plugin 'scripts') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $plugin 'resources') | Out-Null
  return $root
}

function New-FixtureDescription {
  param([string]$Root)

  $path = Join-Path $Root 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\resources\computer-description.md'
  $body = @"
If the user specifies an app to use, get the app by name, bundle ID, or path:

``````javascript
let app = await cua.getApp("Example App");
``````
"@
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, ($body -replace "`r`n", "`n" -replace "`n", "`r`n"), $encoding)
  return $path
}

function New-FixtureLaunch {
  param([string]$Path, [string]$SurfacesExpression, [string]$SurfacesValue = 'browser')

  # The bundled plugin scripts ship with LF; keep that convention so the newline handling in the
  # patcher is exercised the same way the real launch.mjs exercises it.
  $body = @"
import process from "node:process";
const executable = process.env.CUA_REPL_NODE_REPL_PATH;
$SurfacesExpression
if (!executable) { throw new Error("missing"); }
console.log([...surfaces].join(","));
"@
  $body = $body -replace "`r`n", "`n"

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $body, $encoding)

  if ($SurfacesValue -ne $null) {
    $mcp = Join-Path (Split-Path -Parent $Path) '..\.mcp.json'
    $mcpPath = [System.IO.Path]::GetFullPath($mcp)
    $json = @"
{
  "mcpServers": {
    "cua_repl": {
      "env": {
        "CUA_REPL_ENABLED_SURFACES": "$SurfacesValue"
      }
    }
  }
}
"@
    [System.IO.File]::WriteAllText($mcpPath, ($json -replace "`r`n", "`n"), $encoding)
  }
}

$OriginalExpression = @'
  const surfaces = new Set(
    (process.env.CUA_REPL_ENABLED_SURFACES ?? "browser,computer").split(",").map((surface) => surface.trim()).filter(Boolean)
  );
'@

$UnknownExpression = @'
  const allowed = (process.env.CUA_REPL_ENABLED_SURFACES ?? "browser").split(",");
  const surfaces = new Set(allowed);
'@

# --- 1. verify mode flags an unpatched fixture and leaves it untouched -------------------------

$fixtureHome = New-FixtureHome 'original'
$launch = Join-Path $fixtureHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $launch -SurfacesExpression $OriginalExpression
$description = New-FixtureDescription -Root $fixtureHome
$before = [System.IO.File]::ReadAllText($launch)
$beforeDescription = [System.IO.File]::ReadAllText($description)

$threw = $false
try { & $RepairScript -CodexHome $fixtureHome -VerifyOnly -SkipSourceCopies | Out-Null } catch { $threw = $true }
Assert-True $threw 'verify-only fails (throws) while the fixture is unpatched'
Assert-True ([System.IO.File]::ReadAllText($launch) -eq $before) 'verify-only does not write the launch script'
Assert-True ([System.IO.File]::ReadAllText($description) -eq $beforeDescription) 'verify-only does not write the description'

# --- 2. install patches both targets, backs them up, and normalizes .mcp.json ------------------

& $RepairScript -CodexHome $fixtureHome -Install -SkipSourceCopies | Out-Null
$patchedText = [System.IO.File]::ReadAllText($launch)
$patchedDescription = [System.IO.File]::ReadAllText($description)
$mcpPath = Join-Path $fixtureHome 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\.mcp.json'

Assert-True ($patchedText -match 'CUA_SURFACE_LOCK_PATCH') 'install writes the surface patch marker'
Assert-True ($patchedText -match '"computer"\s*\]\);') 'install appends the forced computer surface'
Assert-True (-not $patchedText.Contains("`r")) 'install keeps the launch script LF-only, mirroring the shipped file'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $launch) -Filter 'launch.mjs.bak-*').Count -ge 1) 'install leaves one adjacent launch backup'
Assert-True ($patchedDescription -match 'CUA_WINDOWS_DESCRIPTION_PATCH') 'install writes the description patch marker'
Assert-True ($patchedDescription -match 'cua\.computer\.list_windows') 'install adds the Windows window-based entry point'
Assert-True ($patchedDescription -match 'Native app bindings are unavailable for windows') 'install warns that the macOS app binding is unavailable on Windows'
Assert-True ($patchedDescription.Contains("`r`n")) 'install keeps the description CRLF, mirroring the shipped resource'
Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $description) -Filter 'computer-description.md.bak-*').Count -ge 1) 'install leaves one adjacent description backup'
Assert-True (([System.IO.File]::ReadAllText($mcpPath)) -match '"CUA_REPL_ENABLED_SURFACES"\s*:\s*"browser,computer"') 'install normalizes the materialized .mcp.json value'
Assert-True ((Get-FileHash -LiteralPath $launch -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $launch -Algorithm SHA256).Hash) 'patched file is stable'

# --- 3. the patched file is still valid JavaScript --------------------------------------------

if (-not $NodePath) {
  $resolved = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($resolved) { $NodePath = $resolved.Source }
}
if ($NodePath -and (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
  & $NodePath --check $launch 2>&1 | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) 'node --check accepts the patched module'
} else {
  Write-Host "$LogPrefix SKIP node --check (node not found)"
}

# --- 4. install is idempotent and verify now passes -------------------------------------------

$stable = [System.IO.File]::ReadAllText($launch)
$stableDescription = [System.IO.File]::ReadAllText($description)
& $RepairScript -CodexHome $fixtureHome -Install -SkipSourceCopies | Out-Null
Assert-True ([System.IO.File]::ReadAllText($launch) -eq $stable) 'second install is a no-op for the launch script'
Assert-True ([System.IO.File]::ReadAllText($description) -eq $stableDescription) 'second install is a no-op for the description'

$ok = $true
try { & $RepairScript -CodexHome $fixtureHome -VerifyOnly -SkipSourceCopies | Out-Null } catch { $ok = $false }
Assert-True $ok 'verify-only passes once both targets are patched'

$json = & $RepairScript -CodexHome $fixtureHome -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True ($json.ok -eq $true) 'json report marks ok'
Assert-True (@($json.targets | Where-Object { $_.Patch -eq 'description' }).Count -ge 1) 'json report covers the description target'

# --- 5. rollback restores both original blocks --------------------------------------------------

& $RepairScript -CodexHome $fixtureHome -Rollback -SkipSourceCopies | Out-Null
$restored = [System.IO.File]::ReadAllText($launch)
$restoredDescription = [System.IO.File]::ReadAllText($description)
Assert-True ($restored -notmatch 'CUA_SURFACE_LOCK_PATCH') 'rollback removes the surface marker'
Assert-True ($restored.Contains("const surfaces = new Set(`n    (process.env.CUA_REPL_ENABLED_SURFACES")) 'rollback restores the original expression shape'
Assert-True ($restored -eq $before) 'rollback reproduces the original launch script byte for byte'
Assert-True ($restoredDescription -notmatch 'CUA_WINDOWS_DESCRIPTION_PATCH') 'rollback removes the description marker'
Assert-True ($restoredDescription -eq $beforeDescription) 'rollback reproduces the original description byte for byte'

Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue

# --- 6. an unrecognized layout is reported, never edited ---------------------------------------

$fixtureHome2 = New-FixtureHome 'unknown'
$launch2 = Join-Path $fixtureHome2 'plugins\cache\openai-bundled\unified-computer-use\99.0.0\scripts\launch.mjs'
New-FixtureLaunch -Path $launch2 -SurfacesExpression $UnknownExpression
$before2 = [System.IO.File]::ReadAllText($launch2)

$threw2 = $false
try { & $RepairScript -CodexHome $fixtureHome2 -VerifyOnly -SkipSourceCopies | Out-Null } catch { $threw2 = $true }
$json2 = & $RepairScript -CodexHome $fixtureHome2 -Json -SkipSourceCopies | ConvertFrom-Json
Assert-True ($threw2) 'an unrecognized layout fails verification'
Assert-True ($json2.targets[0].State -eq 'unsupported') 'an unrecognized layout is classified unsupported'
Assert-True ($json2.ok -eq $false) 'an unrecognized layout reports ok=false'

$installedAnyway = $true
try { & $RepairScript -CodexHome $fixtureHome2 -Install -SkipSourceCopies | Out-Null } catch { $installedAnyway = $false }
Assert-True ($installedAnyway) 'install does not throw on an unrecognized layout'
Assert-True ([System.IO.File]::ReadAllText($launch2) -eq $before2) 'install never edits an unrecognized layout'

Remove-Item -LiteralPath $fixtureHome2 -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
  throw "$LogPrefix $($script:Failures) assertion(s) failed"
}
Write-Host "$LogPrefix all assertions passed"
