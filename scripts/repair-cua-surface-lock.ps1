[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [switch]$Install,
  [switch]$VerifyOnly,
  [switch]$Rollback,
  [switch]$Json,
  # The cache copy is the one Desktop launches. The two marketplace source copies are patched
  # too so a same-version plugin re-materialization inherits the fix; skip them with this switch.
  [switch]$SkipSourceCopies
)

<#
Repairs the Windows `unified-computer-use` plugin cache, which needs two independent patches:

1. surface       `scripts\launch.mjs`                 - the Desktop plugin reconcile regenerates
                                                       `.mcp.json` on every start from a surface
                                                       list that only contains `computer` when
                                                       `platform` is `darwin`, so the `cua`
                                                       runtime object loses its native surface.
2. description   `resources\computer-description.md`  - the injected `js` tool description only
                                                       documents the macOS `cua.getApp` entry
                                                       point, which throws
                                                       `Native app bindings are unavailable for
                                                       windows.` on Windows.

Both are verified and repaired independently; `-VerifyOnly` fails while either is unpatched.
#>

$ErrorActionPreference = 'Stop'
$LogPrefix = '[cua-surface-lock]'

$PatchProfiles = @(
  [ordered]@{
    Name             = 'surface'
    RelativePath     = 'scripts\launch.mjs'
    Marker           = 'CUA_SURFACE_LOCK_PATCH'
    RelatedText      = 'CUA_REPL_ENABLED_SURFACES'
    UseRegex         = $true
    OriginalSha256   = 'A50B66879F7B72E45AB6FBAAD77EFF14A87680A946135F410C121B9B166A2597'
    PatchedSha256    = '4312E22A1BD77D26D02AECF3A466D256C908567D98EEA8EC93B0B45B39419175'
    # Tolerates the whitespace forms a future Desktop build may ship.
    Pattern          = '(?ms)const surfaces = new Set\(\s*\(process\.env\.CUA_REPL_ENABLED_SURFACES \?\? "browser,computer"\)\.split\(","\)\.map\(\(surface\) => surface\.trim\(\)\)\.filter\(Boolean\)\s*\);'
    PatchedPattern   = '(?ms)const surfaces = new Set\(\[(?=[\s\S]*?CUA_SURFACE_LOCK_PATCH)[\s\S]*?\]\);'
    Anchor           = @'
const surfaces = new Set(
    (process.env.CUA_REPL_ENABLED_SURFACES ?? "browser,computer").split(",").map((surface) => surface.trim()).filter(Boolean)
  );
'@
    Replacement      = @'
const surfaces = new Set([
    ...(process.env.CUA_REPL_ENABLED_SURFACES ?? "browser,computer").split(",").map((surface) => surface.trim()).filter(Boolean),
    // CUA_SURFACE_LOCK_PATCH: the Desktop plugin reconcile only pushes the "computer" surface when
    // platform is darwin, so every Desktop start rewrites the materialized .mcp.json env back to
    // CUA_REPL_ENABLED_SURFACES=browser and the native surface is dropped. Force it here, because
    // .mcp.json is regenerated on every launch.
    "computer"
  ]);
'@
  }
  [ordered]@{
    Name             = 'description'
    RelativePath     = 'resources\computer-description.md'
    Marker           = 'CUA_WINDOWS_DESCRIPTION_PATCH'
    RelatedText      = 'cua.getApp'
    UseRegex         = $false
    # Recorded on unified-computer-use 26.903.61454.
    OriginalSha256   = '46BD5B39A31EE241D089EE2A091CE014652D4FEFA9A11CB58C3E8DF308EC4514'
    PatchedSha256    = 'C72E08A0C82D993953880FD0D34199AA3EBDA07B6EB74F4BA3E1102CAEFB9291'
    Anchor           = @'
If the user specifies an app to use, get the app by name, bundle ID, or path:

```javascript
let app = await cua.getApp("Example App");
```
'@
    Replacement      = @'
If the user specifies an app to use, first check which native surface the CUA runtime exposes:

```javascript
cua.computer.target;
```

On macOS (`"mac"`) get the app by name, bundle ID, or path:

```javascript
let app = await cua.getApp("Example App");
```

On Windows (`"windows"`) `cua.getApp` and `cua.listApps` are unavailable and throw `Native app bindings are unavailable for windows.` Windows exposes windows rather than apps, so list them and select one instead:

```javascript
let windows = await cua.computer.list_windows();
let window = windows.find((entry) => entry.title?.includes("Notepad"));
await cua.computer.activate_window({ window: { app: window.app, id: window.id } });
let state = await cua.computer.get_window_state({
  window: { app: window.app, id: window.id },
  include_screenshot: true,
  include_text: true
});
```

The Windows helper methods are `list_apps`, `list_windows`, `get_window`, `activate_window`, `get_window_state`, `launch_app`, `click`, `scroll`, `drag`, `press_key`, `type_text`, `set_value`, `perform_secondary_action`, `start_audio_recording`, and `stop_audio_recording`. Pass the complete `{ app, id }` object returned by `list_windows()` or `list_apps()` to every window-scoped call; `{ id }` alone is rejected with `window.app must be a non-empty string and window.id must be an integer >= 0`. `get_window_state` returns `{ accessibility, screenshots, window }` on Windows, not the macOS `{ text, screenshot }` shape. The first call that targets an app raises an approval request, so expect one confirmation per app per session.

CUA_WINDOWS_DESCRIPTION_PATCH
'@
  }
)

function Write-Log {
  param([string]$Message)
  if (-not $Json) { Write-Host "$LogPrefix $Message" }
}

function Write-TextNoBom {
  param([string]$Path, [string]$Text)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Sha256 {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function ConvertTo-TargetNewline {
  param([string]$Text, [string]$Target)

  # The bundled plugin resources ship with CRLF and the bundled scripts with LF; this skill's own
  # sources are CRLF. Emit with the target file's convention so the diff stays limited to the
  # patched region. A bare LF anywhere proves the file is LF-based; an already-patched LF file must
  # not be mistaken for CRLF just because the inserted block carries CRLF.
  $body = $Text.TrimEnd("`r", "`n")
  if ($Target -match "(?<!`r)`n") { return ($body -replace "`r`n", "`n") }
  return $body
}

function Get-PluginRoots {
  param([string]$CodexRoot)

  $roots = New-Object System.Collections.Generic.List[object]

  $cacheRoot = Join-Path $CodexRoot 'plugins\cache\openai-bundled\unified-computer-use'
  if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
    Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
      $roots.Add([pscustomobject]@{ Kind = 'cache'; Root = $_.FullName })
    }
  }

  if (-not $SkipSourceCopies) {
    $sources = @(
      (Join-Path $CodexRoot '.tmp\bundled-marketplaces\openai-bundled\plugins\unified-computer-use'),
      (Join-Path $CodexRoot 'marketplaces\openai-bundled-local\plugins\unified-computer-use')
    )
    foreach ($source in $sources) {
      if (Test-Path -LiteralPath $source -PathType Container) {
        $roots.Add([pscustomobject]@{ Kind = 'source'; Root = $source })
      }
    }
  }

  return $roots
}

function Get-McpJsonPaths {
  param([string]$CodexRoot)

  $results = New-Object System.Collections.Generic.List[object]
  $cacheRoot = Join-Path $CodexRoot 'plugins\cache\openai-bundled\unified-computer-use'
  if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
    Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $candidate = Join-Path $_.FullName '.mcp.json'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { $results.Add($candidate) }
    }
  }
  return $results
}

function Get-TargetState {
  param([object]$Profile, [string]$Text)

  if ($Text -match [regex]::Escape($Profile.Marker)) { return 'patched' }
  if ($Profile.UseRegex) {
    if ([regex]::IsMatch($Text, $Profile.Pattern)) { return 'original-patchable' }
  } elseif ($Text.Contains((ConvertTo-TargetNewline -Text $Profile.Anchor -Target $Text))) {
    return 'original-patchable'
  }
  if ($Text -match [regex]::Escape($Profile.RelatedText)) { return 'unsupported' }
  return 'not-applicable'
}

function Get-PatchedText {
  param([object]$Profile, [string]$Text, [string]$Path)

  if ($Text -match [regex]::Escape($Profile.Marker)) { return $Text }
  $replacement = ConvertTo-TargetNewline -Text $Profile.Replacement -Target $Text

  if (-not $Profile.UseRegex) {
    $anchor = ConvertTo-TargetNewline -Text $Profile.Anchor -Target $Text
    if (-not $Text.Contains($anchor)) {
      throw "anchor not found in $Path; this plugin build needs fresh analysis instead of the documented pattern"
    }
    return $Text.Replace($anchor, $replacement)
  }

  $match = [regex]::Match($Text, $Profile.Pattern)
  if (-not $match.Success) {
    throw "anchor not found in $Path; this plugin build needs fresh analysis instead of the documented pattern"
  }
  return $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
}

function Get-RestoredText {
  param([object]$Profile, [string]$Text, [string]$Path)

  if ($Text -notmatch [regex]::Escape($Profile.Marker)) { return $Text }
  $anchor = ConvertTo-TargetNewline -Text $Profile.Anchor -Target $Text

  if (-not $Profile.UseRegex) {
    $replacement = ConvertTo-TargetNewline -Text $Profile.Replacement -Target $Text
    if (-not $Text.Contains($replacement)) {
      throw "patched block not recognized in $Path; restore it from the adjacent backup"
    }
    return $Text.Replace($replacement, $anchor)
  }

  $match = [regex]::Match($Text, $Profile.PatchedPattern)
  if (-not $match.Success) {
    throw "patched block not recognized in $Path; restore it from the adjacent backup"
  }
  return $Text.Substring(0, $match.Index) + $anchor + $Text.Substring($match.Index + $match.Length)
}

function Set-McpJsonSurfaces {
  param([string]$Path, [string]$BackupDir)

  $text = Read-Text -Path $Path
  if ($text -notmatch '"CUA_REPL_ENABLED_SURFACES"\s*:\s*"browser"') { return 'unchanged' }

  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupDir ('.mcp.json.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.bak')) -Force

  $updated = $text -replace '"CUA_REPL_ENABLED_SURFACES"\s*:\s*"browser"', '"CUA_REPL_ENABLED_SURFACES": "browser,computer"'
  Write-TextNoBom -Path $Path -Text $updated
  return 'flipped-to-browser,computer'
}

$report = New-Object System.Collections.Generic.List[object]
$roots = @(Get-PluginRoots -CodexRoot $CodexHome)

$launchFound = $false
foreach ($root in $roots) {
  foreach ($profile in $PatchProfiles) {
    $path = Join-Path $root.Root $profile.RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    if ($profile.Name -eq 'surface') { $launchFound = $true }

    $text = Read-Text -Path $path
    $state = Get-TargetState -Profile $profile -Text $text
    $action = 'none'

    if ($Rollback) {
      if ($state -ne 'patched') {
        $action = 'nothing-to-roll-back'
      } elseif ($PSCmdlet.ShouldProcess($path, "Restore the original $($profile.Name) block")) {
        $backup = Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter ((Split-Path -Leaf $path) + '.bak-*') -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($backup) {
          Copy-Item -LiteralPath $backup.FullName -Destination $path -Force
          $action = "restored-from-backup:$($backup.Name)"
        } else {
          Write-TextNoBom -Path $path -Text (Get-RestoredText -Profile $profile -Text $text -Path $path)
          $action = 'restored-from-pattern'
        }
        $state = 'original-patchable'
      }
    } elseif ($Install -and $state -eq 'original-patchable') {
      if ($PSCmdlet.ShouldProcess($path, "Patch the $($profile.Name) block")) {
        Copy-Item -LiteralPath $path -Destination ($path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
        Write-TextNoBom -Path $path -Text (Get-PatchedText -Profile $profile -Text $text -Path $path)
        $state = 'patched'
        $action = 'patched'
      }
    } elseif ($state -eq 'original-patchable') {
      $action = 'needs-patch'
    } elseif ($state -eq 'unsupported') {
      $action = 'manual-analysis-required'
    }

    $report.Add([pscustomobject]@{
        Patch  = $profile.Name
        Kind   = $root.Kind
        Path   = $path
        State  = $state
        Action = $action
        Sha256 = Get-Sha256 -Path $path
      })
  }
}

if (-not $launchFound) {
  throw "no unified-computer-use launch.mjs found under $CodexHome; is the plugin installed?"
}

$mcpResults = New-Object System.Collections.Generic.List[object]
$mcpBackupDir = Join-Path $CodexHome 'backups\cua-surface'
foreach ($mcpPath in Get-McpJsonPaths -CodexRoot $CodexHome) {
  $before = Read-Text -Path $mcpPath
  $value = if ($before -match '"CUA_REPL_ENABLED_SURFACES"\s*:\s*"([^"]*)"') { $Matches[1] } else { $null }
  $action = 'none'

  # The value is normalized only on -Install. Every other mode reports it, because `browser` here
  # is the expected outcome of the Desktop reconcile rather than evidence of a missing repair.
  if ($Install -and -not $Rollback -and $value -eq 'browser') {
    if ($PSCmdlet.ShouldProcess($mcpPath, 'Normalize CUA_REPL_ENABLED_SURFACES')) {
      $action = Set-McpJsonSurfaces -Path $mcpPath -BackupDir $mcpBackupDir
      $value = 'browser,computer'
    }
  } elseif ($value -eq 'browser') {
    $action = 'desktop-rewrites-this-on-every-launch'
  }

  $mcpResults.Add([pscustomobject]@{ Path = $mcpPath; Surfaces = $value; Action = $action })
}

$unpatched = @($report | Where-Object { $_.State -eq 'original-patchable' -or $_.State -eq 'unsupported' })
$ok = ($unpatched.Count -eq 0)

if ($Json) {
  [pscustomobject]@{
    codexHome = $CodexHome
    mode      = if ($Install) { 'install' } elseif ($Rollback) { 'rollback' } else { 'verify' }
    targets   = $report
    mcpJson   = $mcpResults
    profiles  = $PatchProfiles | ForEach-Object {
      [pscustomobject]@{
        patch          = $_.Name
        relativePath   = $_.RelativePath
        originalSha256 = $_.OriginalSha256
        patchedSha256  = $_.PatchedSha256
      }
    }
    ok        = $ok
  } | ConvertTo-Json -Depth 6
} else {
  Write-Log "codex home: $CodexHome"
  foreach ($entry in $report) {
    Write-Log ("{0,-11} {1,-7} {2,-20} {3}" -f $entry.Patch, $entry.Kind, $entry.State, $entry.Path)
    if ($entry.Action -ne 'none') { Write-Log ("        action: {0}" -f $entry.Action) }
    $profile = $PatchProfiles | Where-Object { $_.Name -eq $entry.Patch } | Select-Object -First 1
    if ($entry.Sha256 -eq $profile.OriginalSha256) { Write-Log "        sha256 matches the recorded original" }
    elseif ($profile.PatchedSha256 -and $entry.Sha256 -eq $profile.PatchedSha256) { Write-Log "        sha256 matches the recorded patched output" }
    elseif ($entry.State -eq 'unsupported') { Write-Log "        sha256 $($entry.Sha256) is not a recorded profile" }
  }
  foreach ($entry in $mcpResults) {
    Write-Log ("mcp.json CUA_REPL_ENABLED_SURFACES = {0} ({1})" -f $entry.Surfaces, $entry.Path)
    if ($entry.Action -ne 'none') { Write-Log ("        action: {0}" -f $entry.Action) }
  }
  if ($Install) {
    Write-Log 'patched; start a fresh Codex conversation so a new cua_repl process reads both the new surface list and the new tool description'
  }
  if (@($report | Where-Object { $_.State -eq 'unsupported' }).Count -gt 0) {
    Write-Log 'WARNING: at least one target has no recognized anchor; it was left untouched'
  }
  Write-Log ("result: {0}" -f $(if ($ok) { 'ok' } else { 'repair-required' }))
}

# Throwing, not `exit`, is the convention here: it keeps the script callable in-process by the
# test harness while a `-File` invocation still fails with a non-zero exit code. Only -VerifyOnly
# is a gate; -Json and the default read-only report always return the state without throwing.
if ($VerifyOnly -and -not $Install -and -not $Rollback -and -not $ok) {
  throw "$LogPrefix repair required: $(($unpatched | ForEach-Object { "$($_.Patch) $($_.State) $($_.Path)" }) -join '; ')"
}
