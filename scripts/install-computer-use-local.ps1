[CmdletBinding()]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$PluginVersion = '0.1.0-local',
  [switch]$VerifyOnly,
  [switch]$StrictVerifyOnly,
  [switch]$VerifyAllBundledPluginsAvailable,
  [switch]$SkipUserEnvironment
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-computer-use-local]'
$script:ConfigBackupBeforeOverwrite = @{}

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Backup-ConfigBeforeOverwrite {
  param(
    [string]$ConfigPath,
    [string]$Reason = 'config-write'
  )

  if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return
  }

  $fullPath = [System.IO.Path]::GetFullPath($ConfigPath)
  if ($script:ConfigBackupBeforeOverwrite.ContainsKey($fullPath)) {
    return
  }

  $configDir = Split-Path -Parent $fullPath
  $backupRoot = Join-Path $configDir 'backups\config'
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

  $safeReason = ([string]$Reason -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeReason)) {
    $safeReason = 'config-write'
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $backupPath = Join-Path $backupRoot "config.toml.$stamp.$safeReason.bak"
  Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
  $script:ConfigBackupBeforeOverwrite[$fullPath] = $backupPath
  Write-Log "config.toml backup before overwrite: $backupPath"
}

function ConvertTo-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )
  Write-Utf8NoBom $Path (($Value | ConvertTo-Json -Depth 30) + "`n")
}

function Resolve-OrCreateDirectory {
  param([string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-ExistingDirectory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "missing required directory: $Path"
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-UnderPath {
  param(
    [string]$Path,
    [string]$Parent
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to modify path outside expected root: $full"
  }
}

function Remove-ReparsePointOrDirectory {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    [System.IO.Directory]::Delete($item.FullName)
    return
  }

  Remove-Item -LiteralPath $item.FullName -Recurse -Force
}

function Test-TransientCopyRace {
  param([System.Exception]$Exception)

  $current = $Exception
  while ($current) {
    if ($current -is [System.IO.FileNotFoundException] -or $current -is [System.IO.DirectoryNotFoundException]) {
      return $true
    }
    $current = $current.InnerException
  }
  return $false
}

function Copy-DirectoryDataOnly {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "copy source directory not found: $Source"
  }

  $maxAttempts = 3
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      if (Test-Path -LiteralPath $Destination) {
        Remove-ReparsePointOrDirectory $Destination
      }

      $sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath
      Resolve-OrCreateDirectory $Destination | Out-Null

      foreach ($dir in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory -Force) {
        $relative = $dir.FullName.Substring($sourceRoot.Length).TrimStart('\')
        Resolve-OrCreateDirectory (Join-Path $Destination $relative) | Out-Null
      }

      foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        $targetParent = Split-Path -Parent $target
        Resolve-OrCreateDirectory $targetParent | Out-Null
        [System.IO.Directory]::CreateDirectory($targetParent) | Out-Null
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($file.FullName))
        [System.IO.File]::SetLastWriteTime($target, $file.LastWriteTime)
      }
      return
    } catch {
      if ($attempt -ge $maxAttempts -or -not (Test-TransientCopyRace $_.Exception)) {
        throw
      }
      Write-Log "warning: source tree changed during copy; retrying $attempt/${maxAttempts}: $Source"
      Start-Sleep -Seconds 1
    }
  }
}

function Set-TomlTable {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [hashtable]$Values
  )

  $content = ''
  if (Test-Path -LiteralPath $ConfigPath) {
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  }

  $lines = foreach ($key in ($Values.Keys | Sort-Object)) {
    $value = $Values[$key]
    if ($value -is [bool]) {
      "$key = $($value.ToString().ToLowerInvariant())"
    } else {
      $escaped = [string]$value -replace "'", "''"
      "$key = '$escaped'"
    }
  }
  $body = ($lines -join "`r`n") + "`r`n"
  $escapedHeader = [regex]::Escape($Header)
  $pattern = "(?ms)^$escapedHeader\s*\r?\n(?:(?!^\[).)*"
  $replacement = "$Header`r`n$body"

  if ([regex]::IsMatch($content, $pattern)) {
    $content = [regex]::Replace($content, $pattern, $replacement, 1)
  } else {
    if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) {
      $content += "`r`n"
    }
    if ($content.Length -gt 0 -and -not $content.EndsWith("`r`n`r`n")) {
      $content += "`r`n"
    }
    $content += $replacement
  }

  Backup-ConfigBeforeOverwrite $ConfigPath "set-$Header"
  Write-Utf8NoBom $ConfigPath $content
}

function Set-TomlTableKey {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [string]$Key,
    [string]$Value,
    [string]$Reason = 'set-table-key'
  )

  $content = ''
  if (Test-Path -LiteralPath $ConfigPath) {
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  }
  $escapedHeader = [regex]::Escape($Header)
  $tablePattern = "(?ms)^(?<header>$escapedHeader)\s*\r?\n(?<body>(?:(?!^\[).)*)"
  $tableMatch = [regex]::Match($content, $tablePattern)
  $escapedValue = [string]$Value -replace "'", "''"
  $line = "$Key = '$escapedValue'"
  if ($tableMatch.Success) {
    $body = $tableMatch.Groups['body'].Value
    $escapedKey = [regex]::Escape($Key)
    $keyPattern = "(?m)^\s*$escapedKey\s*=.*$"
    if ([regex]::IsMatch($body, $keyPattern)) {
      $body = [regex]::Replace($body, $keyPattern, $line, 1)
    } else {
      $body = $line + "`r`n" + $body
    }
    $replacement = $tableMatch.Groups['header'].Value + "`r`n" + $body
    $content = $content.Substring(0, $tableMatch.Index) + $replacement + $content.Substring($tableMatch.Index + $tableMatch.Length)
  } else {
    if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) {
      $content += "`r`n"
    }
    if ($content.Length -gt 0 -and -not $content.EndsWith("`r`n`r`n")) {
      $content += "`r`n"
    }
    $content += "$Header`r`n$line`r`n"
  }

  Backup-ConfigBeforeOverwrite $ConfigPath $Reason
  Write-Utf8NoBom $ConfigPath $content
}

function Remove-TomlTableKeys {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [string[]]$Keys,
    [string]$Reason = 'remove-table-keys'
  )

  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf) -or $Keys.Count -eq 0) {
    return
  }

  $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  $escapedHeader = [regex]::Escape($Header)
  $pattern = "(?ms)^$escapedHeader\s*\r?\n(?:(?!^\[).)*"
  $match = [regex]::Match($content, $pattern)
  if (-not $match.Success) {
    return
  }

  $keyPattern = '^\s*(?:' + (($Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*='
  $lines = $match.Value -split "(\r?\n)"
  $rebuilt = New-Object System.Text.StringBuilder
  $changed = $false
  for ($i = 0; $i -lt $lines.Count; $i += 2) {
    $line = $lines[$i]
    $newline = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { '' }
    if ($line -match $keyPattern) {
      $changed = $true
      continue
    }
    [void]$rebuilt.Append($line)
    [void]$rebuilt.Append($newline)
  }

  if (-not $changed) {
    return
  }

  Backup-ConfigBeforeOverwrite $ConfigPath $Reason
  $updated = $content.Remove($match.Index, $match.Length).Insert($match.Index, $rebuilt.ToString())
  Write-Utf8NoBom $ConfigPath $updated
}

function Get-ChromeUserDataDirectoryOverride {
  $candidates = @()
  $userOverride = [Environment]::GetEnvironmentVariable('CODEX_CHROME_USER_DATA_DIR', 'User')
  if (-not [string]::IsNullOrWhiteSpace($userOverride)) {
    $candidates += [Environment]::ExpandEnvironmentVariables($userOverride.Trim().Trim('"'))
  }

  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data')
  }

  $chromeAppPathKeys = @(
    'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
  )
  foreach ($registryPath in $chromeAppPathKeys) {
    try {
      $chromeExe = [string](Get-Item -LiteralPath $registryPath -ErrorAction Stop).GetValue('')
    } catch {
      continue
    }
    if ([string]::IsNullOrWhiteSpace($chromeExe)) {
      continue
    }

    $chromeExe = [Environment]::ExpandEnvironmentVariables($chromeExe.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $chromeExe -PathType Leaf)) {
      continue
    }

    $appDirectory = Split-Path -Parent $chromeExe
    if ((Split-Path -Leaf $appDirectory) -ieq 'App') {
      $candidates += (Join-Path (Split-Path -Parent $appDirectory) 'Data')
    }
  }

  $seen = @{}
  foreach ($candidate in $candidates) {
    try {
      $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    } catch {
      continue
    }
    $key = $resolved.TrimEnd('\').ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      continue
    }
    $seen[$key] = $true

    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'Local State') -PathType Leaf)) {
      continue
    }
    foreach ($profile in @(Get-ChildItem -LiteralPath $resolved -Directory -Force -ErrorAction SilentlyContinue)) {
      if (Test-Path -LiteralPath (Join-Path $profile.FullName 'Preferences') -PathType Leaf) {
        return $resolved
      }
    }
  }

  return $null
}

function Enable-UserEnvironment {
  param([string]$MarketplaceRoot)

  if ($SkipUserEnvironment) {
    Write-Log 'skipping user environment update'
    return
  }

  [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', '1', 'User')
  $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = '1'

  $trustedRoots = @(Get-NodeReplTrustedRoots $MarketplaceRoot)
  if ($trustedRoots.Count -gt 0) {
    $trustedCodePaths = $trustedRoots -join ';'
    [Environment]::SetEnvironmentVariable('NODE_REPL_TRUSTED_CODE_PATHS', $trustedCodePaths, 'User')
    $env:NODE_REPL_TRUSTED_CODE_PATHS = $trustedCodePaths
  }

  $chromeUserDataDirectory = Get-ChromeUserDataDirectoryOverride
  if ($chromeUserDataDirectory) {
    [Environment]::SetEnvironmentVariable('CODEX_CHROME_USER_DATA_DIR', $chromeUserDataDirectory, 'User')
    $env:CODEX_CHROME_USER_DATA_DIR = $chromeUserDataDirectory
  } else {
    Write-Log 'warning: Chrome user data directory was not detected; CODEX_CHROME_USER_DATA_DIR was not changed'
  }

  try {
    $signature = @'
using System;
using System.Runtime.InteropServices;
public static class CodexEnvBroadcast {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
    if (-not ('CodexEnvBroadcast' -as [type])) {
      Add-Type -TypeDefinition $signature
    }
    $result = [UIntPtr]::Zero
    [CodexEnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result) | Out-Null
  } catch {
    Write-Log "warning: environment broadcast failed: $($_.Exception.Message)"
  }

  Write-Log 'enabled CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1 for this process and the current user'
  if ($trustedRoots.Count -gt 0) {
    Write-Log "enabled NODE_REPL_TRUSTED_CODE_PATHS=$trustedCodePaths for this process and the current user"
  }
  if ($chromeUserDataDirectory) {
    Write-Log "enabled CODEX_CHROME_USER_DATA_DIR=$chromeUserDataDirectory for this process and the current user"
  }
}

function Get-PluginJson {
  return [ordered]@{
    name = 'computer-use'
    version = $PluginVersion
    description = 'Local Windows Computer Use compatibility helper for Codex Desktop.'
    author = [ordered]@{
      name = 'Local'
    }
    homepage = 'https://openai.com/'
    repository = 'https://openai.com/'
    license = 'Proprietary'
    keywords = @('computer-use', 'windows', 'desktop')
    skills = './skills/'
    interface = [ordered]@{
      displayName = 'Computer Use'
      shortDescription = 'Control this Windows desktop from Codex'
      longDescription = 'Local compatibility plugin that provides the Windows helper paths expected by Codex Desktop Computer Use.'
      developerName = 'Local'
      category = 'Productivity'
      capabilities = @('Interactive', 'Read', 'Write')
      websiteURL = 'https://openai.com/'
      privacyPolicyURL = 'https://openai.com/policies/row-privacy-policy/'
      termsOfServiceURL = 'https://openai.com/policies/row-terms-of-use/'
      defaultPrompt = @('Look at my screen and help me navigate')
      brandColor = '#10A37F'
      screenshots = @()
    }
  }
}

function Get-SkillMarkdown {
  return @'
---
name: computer-use
description: Local Windows Computer Use compatibility helper for Codex Desktop. Provides the @oai/sky paths that the Desktop app expects when CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1.
---

# Computer Use

This local compatibility plugin is installed by the codex-windows-fast-patch skill. It supplies the Windows helper transport paths that Codex Desktop resolves for Computer Use.

The Desktop app must be launched with `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`. The installer writes that as a user environment variable, so restart Codex after installation.
'@
}

function Get-ComputerUseSkillDocumentationProfile {
  param([string]$SkyRoot)

  $packagePath = Join-Path $SkyRoot 'package.json'
  $clientTypePath = Join-Path $SkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.d.ts'
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $clientTypePath -PathType Leaf)) {
    return $null
  }

  try {
    $package = Get-Content -Raw -Encoding UTF8 -LiteralPath $packagePath | ConvertFrom-Json
  } catch {
    return $null
  }
  if ([string]$package.version -ne '0.6.2') {
    return $null
  }

  $clientTypes = [System.IO.File]::ReadAllText($clientTypePath, [System.Text.UTF8Encoding]::new($false))
  $requiredSignatures = @(
    'activate_window: ({ window }: T.Window2.ActivateWindow.Input)',
    'get_window_state: ({ include_screenshot, include_text, window, }: T.Window2.GetWindowState.Input)',
    'list_windows: () => Promise<T.Window2.Window[]>;'
  )
  foreach ($signature in $requiredSignatures) {
    if (-not $clientTypes.Contains($signature)) {
      return $null
    }
  }

  return [pscustomobject]@{
    Name = 'sky-0.6.2-window2-api'
    Marker = '<!-- codex-windows-fast-patch: sky-0.6.2-window2-api -->'
  }
}

function Get-ComputerUseSkillCompatibilityMarkdown {
  return @'
---
name: computer-use
description: Control Windows apps from ChatGPT
---

# Computer Use

<!-- codex-windows-fast-patch: sky-0.6.2-window2-api -->

Use this skill to automate Windows apps through the bundled `@oai/sky` runtime. This local compatibility overlay applies only to the recognized `@oai/sky` 0.6.2 Window2 API profile.

The runtime exposes `sky` with `list_windows`, `get_window`, `get_window_state`, `activate_window`, and interaction methods. It does not provide an in-process documentation method in this profile. Use the concrete calls below rather than probing undocumented method names.

## Initialize

Run this once in a fresh `node_repl` JavaScript session:

```js
if (!globalThis.sky) {
  const { sky } = await import("@oai/sky");
  globalThis.sky = sky;
}
```

## Read A Window

Start with the current targetable windows, then pass the returned `Window` object, not just its numeric id, to state and action methods:

```js
const windows = await sky.list_windows();
const target = windows.find((window) => window.title);
if (!target) throw new Error("No targetable window is available");

const state = await sky.get_window_state({
  window: target,
  include_screenshot: true,
  include_text: true,
});
```

`get_window_state` returns `window`, `screenshots`, and `accessibility`. To refresh a retained target after the UI changes, call `sky.get_window({ id: target.id, app: target.app })` or list the windows again before acting.

## Interact Safely

Use the same window object with object-shaped inputs, for example `await sky.activate_window({ window: target })` or `await sky.click({ window: target, element_index })`. Re-read state after navigation, dialog changes, or focus changes. Immediately before a capture, revalidate and activate the intended window, then inspect the returned image content rather than treating a screenshot record or PNG alone as success.
'@
}

function Patch-ComputerUseSkillDocumentation {
  param(
    [string]$SkillPath,
    [string]$RuntimeSkyRoot
  )

  $profile = Get-ComputerUseSkillDocumentationProfile $RuntimeSkyRoot
  if (-not $profile) {
    return
  }

  $content = if (Test-Path -LiteralPath $SkillPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($SkillPath, [System.Text.UTF8Encoding]::new($false))
  } else {
    ''
  }
  if ($content.Contains($profile.Marker)) {
    return
  }

  # Preserve a future upstream skill unless it still contains the known stale API prompt.
  $knownStalePrompt = $content.Contains('sky.documentation(') -or
    $content.Contains('sky.document_info(')
  if ($content.Length -gt 0 -and -not $knownStalePrompt) {
    Write-Log "Computer Use skill has no known stale runtime-doc prompt; leaving it unchanged: $SkillPath"
    return
  }

  Write-Utf8NoBom $SkillPath ((Get-ComputerUseSkillCompatibilityMarkdown) + "`n")
  Write-Log "applied Computer Use Sky API documentation overlay: $SkillPath"
}

function Test-ComputerUseSkillDocumentation {
  param(
    [string]$SkillPath,
    [string]$RuntimeSkyRoot
  )

  $profile = Get-ComputerUseSkillDocumentationProfile $RuntimeSkyRoot
  if (-not $profile) {
    return
  }
  if (-not (Test-Path -LiteralPath $SkillPath -PathType Leaf)) {
    throw "Computer Use skill documentation is missing: $SkillPath"
  }

  $content = [System.IO.File]::ReadAllText($SkillPath, [System.Text.UTF8Encoding]::new($false))
  foreach ($stalePrompt in @('sky.documentation(', 'sky.document_info(')) {
    if ($content.Contains($stalePrompt)) {
      throw "Computer Use skill documentation still calls a missing Sky documentation API: $SkillPath"
    }
  }
  foreach ($requiredApi in @('sky.list_windows()', 'sky.get_window_state({', 'sky.activate_window({ window: target })')) {
    if (-not $content.Contains($requiredApi)) {
      throw "Computer Use skill documentation is missing its current Sky API workflow ($requiredApi): $SkillPath"
    }
  }
  $source = if ($content.Contains($profile.Marker)) { 'local-overlay' } else { 'upstream-current-api' }
  Write-Log "Computer Use Sky API documentation verification ok: source=$source path=$SkillPath"
}

function Get-HelperTransportJs {
  return @'
import { execFile } from "node:child_process";
import { appendFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const logPath = join(
  process.env.LOCALAPPDATA || process.env.TEMP || ".",
  "OpenAI",
  "Codex",
  "computer-use-local-helper.log",
);

async function log(entry) {
  try {
    await mkdir(dirname(logPath), { recursive: true });
    await appendFile(logPath, `${new Date().toISOString()} ${JSON.stringify(entry)}\n`, "utf8");
  } catch {
    // Logging must never break Computer Use requests.
  }
}

function encodePowerShell(script) {
  return Buffer.from(script, "utf16le").toString("base64");
}

async function runPowerShell(script, timeout = 30000) {
  const { stdout } = await execFileAsync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodePowerShell(script)],
    {
      encoding: "utf8",
      env: process.env,
      timeout,
      windowsHide: true,
      maxBuffer: 64 * 1024 * 1024,
    },
  );
  const text = stdout.trim();
  return text.length === 0 ? null : JSON.parse(text);
}

function numberFrom(params, names, fallback = 0) {
  for (const name of names) {
    const value = params?.[name];
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
  }
  return fallback;
}

function buttonFrom(params) {
  const raw = String(params?.button || params?.mouseButton || "left").toLowerCase();
  if (raw.includes("right")) return "right";
  if (raw.includes("middle")) return "middle";
  return "left";
}

function keyFrom(params) {
  return String(params?.key || params?.keys || params?.text || params?.value || "");
}

function textFrom(params) {
  return String(params?.text ?? params?.value ?? params?.input ?? "");
}

const user32Script = `
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexUser32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
}
"@
`;

function mouseFlags(button, action) {
  if (button === "right") return action === "down" ? "0x0008" : "0x0010";
  if (button === "middle") return action === "down" ? "0x0020" : "0x0040";
  return action === "down" ? "0x0002" : "0x0004";
}

async function screenshot() {
  return await runPowerShell(`
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
$stream = New-Object System.IO.MemoryStream
$bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
$bytes = $stream.ToArray()
$stream.Dispose()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::Write((ConvertTo-Json -Compress @{
  mimeType = "image/png"
  data = [Convert]::ToBase64String($bytes)
  width = $bounds.Width
  height = $bounds.Height
  left = $bounds.Left
  top = $bounds.Top
}))
`, 30000);
}

async function screenInfo() {
  return await runPowerShell(`
Add-Type -AssemblyName System.Windows.Forms
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::Write((ConvertTo-Json -Compress @{
  width = $bounds.Width
  height = $bounds.Height
  left = $bounds.Left
  top = $bounds.Top
}))
`);
}

async function moveMouse(params) {
  const x = Math.round(numberFrom(params, ["x", "X", "left"]));
  const y = Math.round(numberFrom(params, ["y", "Y", "top"]));
  return await runPowerShell(`
${user32Script}
[CodexUser32]::SetCursorPos(${x}, ${y}) | Out-Null
[Console]::Write('{"ok":true}')
`);
}

async function clickMouse(params, count = 1) {
  const x = Math.round(numberFrom(params, ["x", "X", "left"], Number.NaN));
  const y = Math.round(numberFrom(params, ["y", "Y", "top"], Number.NaN));
  const button = buttonFrom(params);
  const down = mouseFlags(button, "down");
  const up = mouseFlags(button, "up");
  const maybeMove = Number.isFinite(x) && Number.isFinite(y) ? `[CodexUser32]::SetCursorPos(${x}, ${y}) | Out-Null` : "";
  return await runPowerShell(`
${user32Script}
${maybeMove}
for ($i = 0; $i -lt ${count}; $i++) {
  [CodexUser32]::mouse_event(${down}, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 35
  [CodexUser32]::mouse_event(${up}, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
}
[Console]::Write('{"ok":true}')
`);
}

async function dragMouse(params) {
  const fromX = Math.round(numberFrom(params, ["fromX", "startX", "x1", "x"]));
  const fromY = Math.round(numberFrom(params, ["fromY", "startY", "y1", "y"]));
  const toX = Math.round(numberFrom(params, ["toX", "endX", "x2"]));
  const toY = Math.round(numberFrom(params, ["toY", "endY", "y2"]));
  return await runPowerShell(`
${user32Script}
[CodexUser32]::SetCursorPos(${fromX}, ${fromY}) | Out-Null
Start-Sleep -Milliseconds 80
[CodexUser32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[CodexUser32]::SetCursorPos(${toX}, ${toY}) | Out-Null
Start-Sleep -Milliseconds 120
[CodexUser32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
[Console]::Write('{"ok":true}')
`);
}

async function scrollMouse(params) {
  const delta = Math.round(numberFrom(params, ["delta", "wheelDelta"], 0) || -120 * numberFrom(params, ["amount", "clicks"], 1));
  return await runPowerShell(`
${user32Script}
[CodexUser32]::mouse_event(0x0800, 0, 0, ${delta}, [UIntPtr]::Zero)
[Console]::Write('{"ok":true}')
`);
}

function sendKeysLiteral(text) {
  return text
    .replaceAll("{", "{{}")
    .replaceAll("}", "{}}")
    .replaceAll("+", "{+}")
    .replaceAll("^", "{^}")
    .replaceAll("%", "{%}")
    .replaceAll("~", "{~}")
    .replaceAll("(", "{(}")
    .replaceAll(")", "{)}")
    .replaceAll("[", "{[}")
    .replaceAll("]", "{]}")
    .replaceAll("\n", "{ENTER}");
}

function normalizeKey(key) {
  const value = String(key).trim();
  const upper = value.toUpperCase();
  const aliases = {
    ENTER: "{ENTER}",
    RETURN: "{ENTER}",
    ESC: "{ESC}",
    ESCAPE: "{ESC}",
    TAB: "{TAB}",
    BACKSPACE: "{BACKSPACE}",
    DELETE: "{DELETE}",
    DEL: "{DELETE}",
    SPACE: " ",
    UP: "{UP}",
    DOWN: "{DOWN}",
    LEFT: "{LEFT}",
    RIGHT: "{RIGHT}",
    HOME: "{HOME}",
    END: "{END}",
    PAGEUP: "{PGUP}",
    PAGEDOWN: "{PGDN}",
  };
  if (aliases[upper]) return aliases[upper];
  if (/^F([1-9]|1[0-2])$/.test(upper)) return `{${upper}}`;
  return sendKeysLiteral(value);
}

async function sendKeys(keys) {
  const encoded = Buffer.from(keys, "utf8").toString("base64");
  return await runPowerShell(`
Add-Type -AssemblyName System.Windows.Forms
$keys = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("${encoded}"))
[System.Windows.Forms.SendKeys]::SendWait($keys)
[Console]::Write('{"ok":true}')
`);
}

async function typeText(params) {
  return await sendKeys(sendKeysLiteral(textFrom(params)));
}

async function keypress(params) {
  return await sendKeys(normalizeKey(keyFrom(params)));
}

export class WindowsHelperTransport {
  constructor({ helperArgs = [], helperCommand = null } = {}) {
    this.helperArgs = helperArgs;
    this.helperCommand = helperCommand;
    log({ event: "transport-created", helperCommand, helperArgs }).catch(() => {});
  }

  async request(method, params = {}, options = {}) {
    await log({ event: "request", method, params, hasTurnMetadata: !!options?.codexTurnMetadata });
    const name = String(method || "").replace(/[-_]/g, "").toLowerCase();
    if (name === "ping") return "pong";
    if (["screenshot", "takescreenshot", "capture", "captureimage", "capturescreen", "screencapture"].includes(name)) return await screenshot(params);
    if (["screeninfo", "getscreeninfo", "displays", "getdisplays", "screenstate"].includes(name)) return await screenInfo(params);
    if (["movemouse", "mousemove", "move"].includes(name)) return await moveMouse(params);
    if (["click", "mouseclick", "clickmouse"].includes(name)) return await clickMouse(params, 1);
    if (["doubleclick", "mousedoubleclick"].includes(name)) return await clickMouse(params, 2);
    if (["drag", "mousedrag", "dragmouse"].includes(name)) return await dragMouse(params);
    if (["scroll", "mousescroll", "scrollmouse"].includes(name)) return await scrollMouse(params);
    if (["type", "typetext", "text"].includes(name)) return await typeText(params);
    if (["keypress", "presskey", "key", "sendkey"].includes(name)) return await keypress(params);
    if (["close", "shutdown"].includes(name)) return { ok: true };
    await log({ event: "unknown-method", method, params });
    throw new Error(`Unsupported local Computer Use helper method: ${method}`);
  }

  async close() {
    await log({ event: "transport-closed" });
  }
}
'@
}

function Patch-ComputerUseClientScript {
  param([string]$ClientPath)

  if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf)) {
    throw "Computer Use client script not found: $ClientPath"
  }

  $content = [System.IO.File]::ReadAllText($ClientPath)
  $marker = 'computer_use_client_base_file_url_patch'
  if ($content.Contains($marker)) {
    return
  }

  $oldImport = 'import { WindowsComputerUseClientBase } from "@oai/sky/dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js";'
  if (-not $content.Contains($oldImport)) {
    Write-Log "Computer Use client import anchor not found; leaving client script unchanged: $ClientPath"
    return
  }

  $replacement = @'
import { createRequire } from "node:module";
import { join, sep } from "node:path";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const skyIndexPath = require.resolve("@oai/sky");
const skyDistNeedle = `${sep}dist${sep}`;
const skyDistIndex = skyIndexPath.indexOf(skyDistNeedle);
if (skyDistIndex === -1) {
  throw new Error(`Unable to locate @oai/sky package root from ${skyIndexPath}`);
}
const skyPackageRoot = skyIndexPath.slice(0, skyDistIndex);
const { WindowsComputerUseClientBase } = await import(
  pathToFileURL(
    join(
      skyPackageRoot,
      "dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js",
    ),
  ).href,
);
// computer_use_client_base_file_url_patch
'@

  Write-Utf8NoBom $ClientPath ($content.Replace($oldImport, $replacement))
}

function Write-PluginTree {
  param([string]$Root)

  $pluginJsonPath = Join-Path $Root '.codex-plugin\plugin.json'
  $skillPath = Join-Path $Root 'skills\computer-use\SKILL.md'
  $clientPath = Join-Path $Root 'scripts\computer-use-client.mjs'
  $packagePath = Join-Path $Root 'node_modules\@oai\sky\package.json'
  $skyRoot = Split-Path -Parent $packagePath
  $distPath = Join-Path $skyRoot 'dist'
  $helperExePath = Join-Path $Root 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
  $helperTransportPath = Join-Path $Root 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  $runtimeSkyRoot = Get-CuaSkyRuntimeRoot
  $runtimeDistPath = Join-Path $runtimeSkyRoot 'dist'
  $runtimePackagePath = Join-Path $runtimeSkyRoot 'package.json'
  $runtimePackage = Get-Content -Raw -LiteralPath $runtimePackagePath | ConvertFrom-Json
  $runtimeVersion = [string]$runtimePackage.version
  if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
    $runtimeVersion = $PluginVersion
  }

  if (-not (Test-Path -LiteralPath $pluginJsonPath -PathType Leaf)) {
    ConvertTo-JsonFile $pluginJsonPath (Get-PluginJson)
  }
  if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
    Write-Utf8NoBom $skillPath ((Get-SkillMarkdown) + "`n")
  }
  Patch-ComputerUseSkillDocumentation $skillPath $runtimeSkyRoot
  if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
    Write-Log "descriptor-only Computer Use plugin uses the independent cua_node runtime: $Root"
    return
  }
  Patch-ComputerUseClientScript $clientPath

  Resolve-OrCreateDirectory $skyRoot | Out-Null
  if (Test-Path -LiteralPath $distPath) {
    Remove-ReparsePointOrDirectory $distPath
  }
  Copy-DirectoryDataOnly $runtimeDistPath $distPath

  ConvertTo-JsonFile $packagePath ([ordered]@{
    name = '@oai/sky'
    version = $runtimeVersion
    type = 'module'
    private = $true
    main = 'dist/project/cua/sky_js/src/index.js'
  })
  Write-Utf8NoBom $helperExePath "# Placeholder executable path for Codex Desktop Windows Computer Use resolution.`r`n# The local helper transport module implements the actual request handling.`r`n"
  Write-Utf8NoBom $helperTransportPath ((Get-HelperTransportJs) + "`n")
  Write-Log "overlayed Computer Use @oai/sky runtime files: $runtimeSkyRoot -> $skyRoot"
}

function Update-BundledMarketplaceManifest {
  param([string]$MarketplaceRoot)

  $manifestPath = Join-Path $MarketplaceRoot '.agents\plugins\marketplace.json'
  if (Test-Path -LiteralPath $manifestPath) {
    $json = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
  } else {
    $json = [pscustomobject]@{
      name = 'openai-bundled'
      interface = [pscustomobject]@{ displayName = 'OpenAI Bundled' }
      plugins = @()
    }
  }

  if (-not $json.name) {
    $json | Add-Member -NotePropertyName name -NotePropertyValue 'openai-bundled'
  }
  if (-not $json.interface) {
    $json | Add-Member -NotePropertyName interface -NotePropertyValue ([pscustomobject]@{ displayName = 'OpenAI Bundled' })
  }

  $entry = [pscustomobject]@{
    name = 'computer-use'
    source = [pscustomobject]@{
      source = 'local'
      path = './plugins/computer-use'
    }
    policy = [pscustomobject]@{
      installation = 'INSTALLED_BY_DEFAULT'
      authentication = 'ON_INSTALL'
    }
    category = 'Productivity'
  }

  $plugins = @($json.plugins | Where-Object { $_.name -ne 'computer-use' })
  $pluginNames = @{}
  foreach ($plugin in $plugins) {
    $pluginNames[[string]$plugin.name] = $true
  }

  $sourceRoot = Get-InstalledBundledMarketplaceRoot
  $sourceManifestPath = Join-Path $sourceRoot '.agents\plugins\marketplace.json'
  $sourceManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifestPath | ConvertFrom-Json
  foreach ($sourcePlugin in @($sourceManifest.plugins)) {
    $name = [string]$sourcePlugin.name
    if ($name -ne 'computer-use' -and -not $pluginNames.ContainsKey($name)) {
      $plugins += $sourcePlugin
      $pluginNames[$name] = $true
      Write-Log "restored bundled marketplace entry from installed package: $name"
    }
  }

  $json.plugins = @($entry) + $plugins
  ConvertTo-JsonFile $manifestPath $json
}

function Get-StableBundledMarketplaceRoot {
  param([string]$CodexHomeResolved)

  $tmpRoot = Join-Path $CodexHomeResolved '.tmp'
  if (Test-Path -LiteralPath $tmpRoot -PathType Container) {
    $tmpItem = Get-Item -LiteralPath $tmpRoot -Force
    if (($tmpItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      $target = [string](@($tmpItem.Target) | Select-Object -First 1)
      if (-not [string]::IsNullOrWhiteSpace($target)) {
        if (-not [System.IO.Path]::IsPathRooted($target)) {
          $target = Join-Path (Split-Path -Parent $tmpRoot) $target
        }
        $target = [System.IO.Path]::GetFullPath($target)
        return Join-Path (Split-Path -Parent $target) 'openai-bundled-marketplace'
      }
    }
  }

  return Join-Path $CodexHomeResolved 'marketplaces\openai-bundled-local'
}

function Get-NodeReplTrustedRoots {
  param([string]$MarketplaceRoot)

  return @($MarketplaceRoot, (Join-Path (Split-Path -Parent $MarketplaceRoot) 'openai-bundled-cache')) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
    Select-Object -Unique
}

function Get-ReservedBundledMarketplaceRoot {
  param([string]$CodexHomeResolved)

  return Join-Path $CodexHomeResolved '.tmp\bundled-marketplaces\openai-bundled'
}

function Test-BundledMarketplaceRootUsable {
  param([string]$Root)

  if ([string]::IsNullOrWhiteSpace($Root)) {
    return $false
  }
  $manifest = Join-Path $Root '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    return $false
  }
  try {
    $json = [System.IO.File]::ReadAllText($manifest, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  } catch {
    return $false
  }
  return ([string]$json.name -eq 'openai-bundled')
}

function Test-BundledMarketplaceLoadedWithCodexCli {
  $codexPath = $null
  try {
    $codexPath = Get-UsableCodexCliPath 'inspect loaded marketplaces'
  } catch {
    return $null
  }
  $output = @(& $codexPath plugin marketplace list --json 2>&1)
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  try {
    $json = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
  return [bool](@($json.marketplaces) | Where-Object { [string]$_.name -eq 'openai-bundled' })
}

function Get-ConfiguredBundledMarketplaceRoot {
  param([string]$StableMarketplaceRoot)

  # codex-cli 0.149 made `openai-bundled` a reserved marketplace name that is
  # only loaded from the Desktop-materialized root. Older CLIs load the stable
  # local copy. Probe the loaded marketplaces instead of guessing from a version
  # string: this must run after the stable source has been written, so a `false`
  # result means the CLI silently dropped that source and the reserved root is
  # the only one it will load.
  $reservedRoot = Get-ReservedBundledMarketplaceRoot (Resolve-OrCreateDirectory $CodexHome)
  if (-not (Test-BundledMarketplaceRootUsable $reservedRoot)) {
    return $StableMarketplaceRoot
  }
  if ([System.IO.Path]::GetFullPath($StableMarketplaceRoot) -eq [System.IO.Path]::GetFullPath($reservedRoot)) {
    return $StableMarketplaceRoot
  }
  if ((Test-BundledMarketplaceLoadedWithCodexCli) -eq $false) {
    return $reservedRoot
  }
  return $StableMarketplaceRoot
}

function Get-PreferredBundledMarketplaceRoot {
  param(
    [string]$ConfigPath,
    [string]$StableMarketplaceRoot
  )

  # Prefer whatever root the previous run settled on, so a machine that already
  # needs the reserved root does not get rewritten to the stable copy and back
  # on every call.
  $reservedRoot = Get-ReservedBundledMarketplaceRoot (Resolve-OrCreateDirectory $CodexHome)
  if (-not (Test-BundledMarketplaceRootUsable $reservedRoot)) {
    return $StableMarketplaceRoot
  }
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return $StableMarketplaceRoot
  }
  $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  $match = [regex]::Match($content, '(?ms)^\[marketplaces\.openai-bundled\]\s*\r?\n(?:(?!^\[).)*?^\s*source\s*=\s*[''"](?<value>[^''"]+)[''"]\s*$')
  if (-not $match.Success) {
    return $StableMarketplaceRoot
  }
  $current = $match.Groups['value'].Value
  if ($current.StartsWith('\\?\')) {
    $current = $current.Substring(4)
  }
  try {
    $current = [System.IO.Path]::GetFullPath($current)
  } catch {
    return $StableMarketplaceRoot
  }
  if ($current -eq [System.IO.Path]::GetFullPath($reservedRoot)) {
    return $reservedRoot
  }
  return $StableMarketplaceRoot
}

function Get-ComputerUsePipeConfigState {
  param([string]$ConfigPath)

  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return [pscustomobject]@{ Present = $false; Active = $false; PipePath = '' }
  }

  $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  $present = $content -match '(?m)^\s*SKY_CUA_NATIVE_PIPE(?:_DIRECTORY)?\s*='
  if (-not $present) {
    return [pscustomobject]@{ Present = $false; Active = $false; PipePath = '' }
  }

  $enabledMatch = [regex]::Match($content, '(?m)^\s*SKY_CUA_NATIVE_PIPE\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $directoryMatch = [regex]::Match($content, '(?m)^\s*SKY_CUA_NATIVE_PIPE_DIRECTORY\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $pipePath = if ($directoryMatch.Success) { $directoryMatch.Groups['value'].Value } else { '' }
  $active = (
    $enabledMatch.Success -and
    $enabledMatch.Groups['value'].Value -eq '1' -and
    $directoryMatch.Success -and
    $pipePath.StartsWith('\\.\pipe\codex-computer-use-', [StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $pipePath)
  )

  return [pscustomobject]@{ Present = $true; Active = $active; PipePath = $pipePath }
}

function Update-CodexConfig {
  param([string]$MarketplaceRoot)

  $configPath = Join-Path $CodexHome 'config.toml'
  $preferredRoot = Get-PreferredBundledMarketplaceRoot $configPath $MarketplaceRoot
  Set-TomlTable $configPath '[marketplaces.openai-bundled]' @{
    last_updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = '\\?\' + $preferredRoot
    source_type = 'local'
  }
  $effectiveRoot = Get-ConfiguredBundledMarketplaceRoot $preferredRoot
  if ([System.IO.Path]::GetFullPath($effectiveRoot) -ne [System.IO.Path]::GetFullPath($preferredRoot)) {
    Write-Log "codex-cli refused the local bundled marketplace source; repointing marketplaces.openai-bundled at the reserved root: $effectiveRoot"
    Set-TomlTable $configPath '[marketplaces.openai-bundled]' @{
      last_updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      source = '\\?\' + $effectiveRoot
      source_type = 'local'
    }
  }
  Set-TomlTable $configPath '[plugins."computer-use@openai-bundled"]' @{
    enabled = $true
  }
  Set-TomlTable $configPath '[plugins."browser@openai-bundled"]' @{
    enabled = $true
  }
  Set-TomlTable $configPath '[plugins."chrome@openai-bundled"]' @{
    enabled = $true
  }
  Set-TomlTable $configPath '[windows]' @{
    sandbox = 'unelevated'
  }
  $trustedRoots = @(Get-NodeReplTrustedRoots $MarketplaceRoot)
  if ($trustedRoots.Count -gt 0) {
    Set-TomlTableKey $configPath '[mcp_servers.node_repl.env]' 'NODE_REPL_TRUSTED_CODE_PATHS' ($trustedRoots -join ';') 'set-node-repl-trusted-code-paths'
  }
  $browserPluginRoot = Join-Path $MarketplaceRoot 'plugins\browser'
  if (Test-Path -LiteralPath $browserPluginRoot -PathType Container) {
    $browserVersion = Get-PluginVersion $browserPluginRoot
    $browserServicePath = Join-Path (Split-Path -Parent $MarketplaceRoot) "openai-bundled-cache\browser\$browserVersion\scripts\browser-service.mjs"
    if (Test-Path -LiteralPath $browserServicePath -PathType Leaf) {
      $trustedServices = '{"browser":"' + ($browserServicePath -replace '\\', '/') + '","sky":"@oai/sky/service"}'
      Set-TomlTableKey $configPath '[mcp_servers.node_repl.env]' 'NODE_REPL_TRUSTED_SERVICES' $trustedServices 'set-node-repl-trusted-services'
    }
  }
  $pipeState = Get-ComputerUsePipeConfigState $configPath
  if ($pipeState.Present -and $pipeState.Active) {
    Write-Log "preserving active Computer Use pipe config: $($pipeState.PipePath)"
  } else {
    Remove-TomlTableKeys $configPath '[mcp_servers.node_repl.env]' @(
      'SKY_CUA_NATIVE_PIPE',
      'SKY_CUA_NATIVE_PIPE_DIRECTORY'
    ) 'remove-stale-computer-use-pipe-env'
  }
}

function Test-TomlSyntax {
  param([string]$ConfigPath)

  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python not found; skipping tomllib syntax validation'
    return
  }

  $script = @'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
tomllib.loads(path.read_text(encoding="utf-8"))
'@
  $temp = Join-Path $env:TEMP ('codex-toml-validate-' + [guid]::NewGuid().ToString('N') + '.py')
  try {
    Write-Utf8NoBom $temp $script
    & $python.Source $temp $ConfigPath
    if ($LASTEXITCODE -ne 0) {
      throw "tomllib validation failed for $ConfigPath"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Get-CuaSkyRuntimeRoot {
  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  $candidates = @()

  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $candidates += foreach ($runtime in (Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue)) {
      $skyRoot = Join-Path $runtime.FullName 'bin\node_modules\@oai\sky'
      $basePath = Join-Path $skyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.js'
      $packagePath = Join-Path $skyRoot 'package.json'
      if ((Test-Path -LiteralPath $basePath -PathType Leaf) -and (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        $packageItem = Get-Item -LiteralPath $packagePath
        [pscustomobject]@{
          Path = $skyRoot
          LastWriteTime = $packageItem.LastWriteTime
          Priority = 0
        }
      }
    }
  }

  $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if ($pkg) {
    $packageSkyRoot = Join-Path $pkg.InstallLocation 'app\resources\cua_node\bin\node_modules\@oai\sky'
    $packageBasePath = Join-Path $packageSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.js'
    $packagePath = Join-Path $packageSkyRoot 'package.json'
    if ((Test-Path -LiteralPath $packageBasePath -PathType Leaf) -and (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
      $packageItem = Get-Item -LiteralPath $packagePath
      $candidates += [pscustomobject]@{
        Path = $packageSkyRoot
        LastWriteTime = $packageItem.LastWriteTime
        Priority = 1
      }
    }
  }

  # Prefer the extracted per-user runtime. Executables inside WindowsApps can
  # be readable yet fail to spawn with EPERM from an ordinary PowerShell/Node
  # process. The package copy remains a discovery fallback only.
  $selected = @($candidates | Sort-Object Priority, @{ Expression = 'LastWriteTime'; Descending = $true } | Select-Object -First 1)
  if ($selected.Count -eq 0) {
    throw "no usable Codex CUA @oai/sky runtime was found under $runtimeRoot or the installed Codex package"
  }

  return $selected[0].Path
}

function Get-ComputerUseNodeReplContextPatchStatus {
  param([string]$HelperTransportPath)

  $patcher = Join-Path $PSScriptRoot 'patch-computer-use-node-repl-context.ps1'
  if (-not (Test-Path -LiteralPath $patcher -PathType Leaf)) {
    throw "Computer Use node_repl context patcher is missing: $patcher"
  }

  $statusOutput = @(& $patcher -HelperTransportPath $HelperTransportPath -CodexHome $CodexHome -Json)
  $statusJson = [string]($statusOutput | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($statusJson)) {
    throw "Computer Use node_repl context patcher returned no status: $HelperTransportPath"
  }
  return $statusJson | ConvertFrom-Json
}

function Repair-ComputerUseNodeReplContext {
  $runtimeSkyRoot = Get-CuaSkyRuntimeRoot
  $helperTransportPath = Join-Path $runtimeSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  $status = Get-ComputerUseNodeReplContextPatchStatus $helperTransportPath
  $patcher = Join-Path $PSScriptRoot 'patch-computer-use-node-repl-context.ps1'

  if ($status.State -eq 'patched') {
    Write-Log "Computer Use node_repl request-context patch already installed: $($status.Sha256)"
    return
  }
  if ($status.State -eq 'original-patchable') {
    & $patcher -HelperTransportPath $helperTransportPath -CodexHome $CodexHome -Install
    $verified = Get-ComputerUseNodeReplContextPatchStatus $helperTransportPath
    if ($verified.State -ne 'patched') {
      throw "Computer Use node_repl request-context patch did not reach patched state: $($verified.State)"
    }
    Write-Log "Computer Use node_repl request-context patch installed: $($verified.Sha256)"
    return
  }
  if ($status.State -eq 'unsupported-modified') {
    throw "Computer Use helper transport contains an unrecognized request-context patch: $helperTransportPath / $($status.Sha256)"
  }
  if ($status.State -like 'patched-backup-*') {
    throw "Computer Use helper transport patch does not have its verified original backup: state=$($status.State) path=$($status.BackupPath)"
  }

  Write-Log "Computer Use node_repl request-context patch is not applicable to this runtime: sky=$($status.SkyVersion) sha256=$($status.Sha256)"
}

function Test-ComputerUseNodeReplContextPatch {
  param([string]$HelperTransportPath)

  $status = Get-ComputerUseNodeReplContextPatchStatus $HelperTransportPath
  if ($status.State -eq 'patched') {
    Write-Log "Computer Use node_repl request-context patch verification ok: $($status.Sha256)"
    return
  }
  if ($status.State -eq 'original-patchable') {
    throw "known Computer Use cross-call approval failure is unpatched: $HelperTransportPath / run -VerifyOnly to repair it"
  }
  if ($status.State -eq 'unsupported-modified') {
    throw "Computer Use helper transport has an unrecognized request-context patch: $HelperTransportPath / $($status.Sha256)"
  }
  if ($status.State -like 'patched-backup-*') {
    throw "Computer Use helper transport patch backup is missing or invalid: state=$($status.State) path=$($status.BackupPath)"
  }

  Write-Log "Computer Use node_repl request-context patch profile is not required for this runtime: sky=$($status.SkyVersion) sha256=$($status.Sha256)"
}

function Get-InstalledBundledMarketplaceRoot {
  $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $pkg) {
    throw 'OpenAI.Codex package is not installed; cannot sync openai-bundled marketplace'
  }

  $root = Join-Path $pkg.InstallLocation 'app\resources\plugins\openai-bundled'
  $manifestPath = Join-Path $root '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "installed openai-bundled marketplace manifest not found: $manifestPath"
  }

  return $root
}

function Stop-OpenAiBundledExtensionHosts {
  param([string[]]$Roots)

  $resolvedRoots = @()
  foreach ($rootPath in $Roots) {
    if ([string]::IsNullOrWhiteSpace($rootPath) -or -not (Test-Path -LiteralPath $rootPath)) {
      continue
    }
    $resolvedRoots += (Resolve-Path -LiteralPath $rootPath -ErrorAction Stop).ProviderPath.TrimEnd('\')
  }
  if ($resolvedRoots.Count -eq 0) {
    return
  }

  $timeoutMilliseconds = 15000L
  $quietMilliseconds = 2000L
  $pollMilliseconds = 100
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $quietStartedAt = -1L
  $seenIdentities = @{}
  $lastMatches = @()

  while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
    $matchedCount = 0
    $currentMatches = @()
    foreach ($process in @(Get-Process -Name 'extension-host' -ErrorAction SilentlyContinue)) {
      try {
        $null = $process.Handle
        $processPath = $process.Path
        if ([string]::IsNullOrWhiteSpace($processPath)) {
          throw "unable to inspect extension-host path: pid=$($process.Id)"
        }

        $matchesRoot = $false
        foreach ($rootPath in $resolvedRoots) {
          if ($processPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $matchesRoot = $true
            break
          }
        }
        if (-not $matchesRoot) {
          continue
        }

        $matchedCount += 1
        $startedTicks = $process.StartTime.ToUniversalTime().Ticks
        $identity = "$($process.Id):$startedTicks"
        $description = "pid=$($process.Id) startedTicks=$startedTicks path=$processPath"
        $currentMatches += $description
        if (-not $seenIdentities.ContainsKey($identity)) {
          $seenIdentities[$identity] = $true
          Write-Log "stopping bundled plugin lock holder: $description"
        }

        try {
          $process.Kill()
        } catch [System.InvalidOperationException] {
          # It exited after enumeration.
        } catch {
          $hasExited = $false
          try {
            $hasExited = $process.HasExited
          } catch {
            $hasExited = $false
          }
          if (-not $hasExited) {
            throw "failed to stop bundled plugin lock holder ${description}: $($_.Exception.Message)"
          }
        }
      } catch [System.InvalidOperationException] {
        # It exited while its handle, path, or start time was being acquired.
      } finally {
        $process.Dispose()
      }
    }

    if ($matchedCount -gt 0) {
      $quietStartedAt = -1L
      $lastMatches = $currentMatches
    } else {
      if ($quietStartedAt -lt 0) {
        $quietStartedAt = $stopwatch.ElapsedMilliseconds
      }
      if (($stopwatch.ElapsedMilliseconds - $quietStartedAt) -ge $quietMilliseconds) {
        return
      }
    }
    Start-Sleep -Milliseconds $pollMilliseconds
  }

  $detail = if ($lastMatches.Count -gt 0) {
    $lastMatches -join '; '
  } else {
    'no process was present in the final scan, but the required quiet window was not established'
  }
  throw "bundled plugin lock holders did not remain stopped for ${quietMilliseconds}ms within ${timeoutMilliseconds}ms: $detail"
}

function Remove-StaleChromeNativeHostEntries {
  $statePath = Join-Path $CodexHome 'chrome-native-hosts.json'
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    return
  }

  try {
    $json = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  } catch {
    Write-Log "warning: failed to parse chrome-native-hosts.json: $($_.Exception.Message)"
    return
  }

  $entries = @($json.chromeNativeHosts)
  if ($entries.Count -eq 0) {
    return
  }

  $kept = @()
  $removed = 0
  foreach ($entry in $entries) {
    $missingPaths = @()
    foreach ($propertyName in @('extensionHostPath', 'browserClientPath')) {
      $path = [string]$entry.$propertyName
      if (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path)) {
        $missingPaths += "${propertyName}=$path"
      }
    }

    if ($missingPaths.Count -gt 0) {
      Write-Log "removing stale Chrome native-host entry: $($missingPaths -join '; ')"
      $removed += 1
    } else {
      $kept += $entry
    }
  }

  if ($removed -eq 0) {
    return
  }

  $backupPath = "$statePath.stale.bak"
  if (-not (Test-Path -LiteralPath $backupPath)) {
    Copy-Item -LiteralPath $statePath -Destination $backupPath -Force
  }

  $json.chromeNativeHosts = @($kept)
  ConvertTo-JsonFile $statePath $json
}

function Get-PluginVersion {
  param([string]$PluginRoot)

  $pluginJson = Join-Path $PluginRoot '.codex-plugin\plugin.json'
  if (-not (Test-Path -LiteralPath $pluginJson -PathType Leaf)) {
    throw "missing plugin manifest: $pluginJson"
  }

  $plugin = Get-Content -Raw -LiteralPath $pluginJson | ConvertFrom-Json
  $version = [string]$plugin.version
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "plugin manifest has no version: $pluginJson"
  }

  return $version
}

function Test-BundledMarketplacePluginAvailable {
  param(
    [string]$MarketplaceRoot,
    [string]$PluginName
  )

  $pluginJson = Join-Path $MarketplaceRoot "plugins\$PluginName\.codex-plugin\plugin.json"
  if (-not (Test-Path -LiteralPath $pluginJson -PathType Leaf)) {
    return $false
  }

  $manifestPath = Join-Path $MarketplaceRoot '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    return $false
  }
  try {
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    return @($manifest.plugins | Where-Object { [string]$_.name -eq $PluginName }).Count -gt 0
  } catch {
    return $false
  }
}

function Get-BundledMarketplacePluginNames {
  param([string]$MarketplaceRoot)

  $manifestPath = Join-Path $MarketplaceRoot '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "missing bundled marketplace manifest: $manifestPath"
  }

  $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
  $pluginNames = @(
    $manifest.plugins |
      ForEach-Object { [string]$_.name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
  )
  if ($pluginNames.Count -eq 0) {
    throw "bundled marketplace has no plugin descriptors: $MarketplaceRoot"
  }

  $incomplete = @($pluginNames | Where-Object {
    -not (Test-BundledMarketplacePluginAvailable $MarketplaceRoot $_)
  })
  if ($incomplete.Count -gt 0) {
    throw "bundled marketplace has incomplete plugin descriptors: $($incomplete -join ',')"
  }

  return $pluginNames
}

function Get-BundledMarketplacePluginVersions {
  param(
    [string]$MarketplaceRoot,
    [string[]]$PluginNames
  )

  if (-not $PluginNames -or $PluginNames.Count -eq 0) {
    $PluginNames = @(Get-BundledMarketplacePluginNames $MarketplaceRoot)
  }

  $versions = @{}
  foreach ($pluginName in $PluginNames) {
    $pluginRoot = Join-Path $MarketplaceRoot "plugins\$pluginName"
    $versions[$pluginName] = Get-PluginVersion $pluginRoot
  }
  return $versions
}

function Get-UsableCodexCliPath {
  param([string]$FailureContext)

  $candidates = @(Get-Command codex -All -ErrorAction SilentlyContinue | Where-Object {
    $_.Source -and $_.Source -notmatch '(?i)\\WindowsApps\\'
  })
  $codex = $candidates | Where-Object { $_.Source.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
  if (-not $codex) {
    $codex = $candidates | Where-Object { $_.Source.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
  }
  if (-not $codex) {
    $codex = $candidates | Where-Object { $_.Source.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
  }
  $codexPath = if ($codex) { [string]$codex.Source } else { '' }
  if ([string]::IsNullOrWhiteSpace($codexPath)) {
    $localBinRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $localBinRoot -PathType Container) {
      $codexPath = [string](Get-ChildItem -LiteralPath $localBinRoot -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName)
      if (-not [string]::IsNullOrWhiteSpace($codexPath)) {
        Write-Log "using user-local Codex CLI: $codexPath"
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($codexPath)) {
    throw "Codex CLI not found; cannot $FailureContext"
  }
  return $codexPath
}

function Install-BundledMarketplacePluginWithCodexCli {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PluginName
  )

  $selector = "$PluginName@openai-bundled"
  $codexPath = Get-UsableCodexCliPath "register $selector"
  $output = @(& $codexPath plugin add $selector --json 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Codex CLI failed to register ${selector}: $detail"
  }

  Write-Log "registered bundled plugin with Codex CLI: $selector"
}

function Get-BundledMarketplacePluginListWithCodexCli {
  param([switch]$IncludeAvailable)

  $codexPath = Get-UsableCodexCliPath 'inspect bundled plugin availability'
  $args = @('plugin', 'list', '--marketplace', 'openai-bundled', '--json')
  if ($IncludeAvailable) {
    $args = @('plugin', 'list', '--marketplace', 'openai-bundled', '--available', '--json')
  }
  $output = @(& $codexPath @args 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Codex CLI failed to list bundled plugins: $detail"
  }

  $json = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  try {
    return $json | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Codex CLI returned invalid bundled plugin JSON: $json"
  }
}

function Test-BundledMarketplacePluginInstalledWithCodexCli {
  param([string]$PluginName)

  $pluginList = Get-BundledMarketplacePluginListWithCodexCli
  $selector = "$PluginName@openai-bundled"
  return @($pluginList.installed | Where-Object {
    [string]$_.pluginId -eq $selector -and [bool]$_.installed
  }).Count -gt 0
}

function Test-AllBundledMarketplacePluginsAvailableWithCodexCli {
  param(
    [string]$MarketplaceRoot,
    [string]$InstalledMarketplaceRoot
  )

  if ([string]::IsNullOrWhiteSpace($InstalledMarketplaceRoot)) {
    $InstalledMarketplaceRoot = Get-InstalledBundledMarketplaceRoot
  }
  $pluginNames = @(Get-BundledMarketplacePluginNames $InstalledMarketplaceRoot)
  $stablePluginNames = @(Get-BundledMarketplacePluginNames $MarketplaceRoot)
  $descriptorDrift = @(Compare-Object -ReferenceObject $pluginNames -DifferenceObject $stablePluginNames)
  if ($descriptorDrift.Count -gt 0) {
    $detail = @($descriptorDrift | ForEach-Object { "$($_.InputObject):$($_.SideIndicator)" }) -join ','
    throw "stable bundled marketplace descriptor set does not match the installed package: $detail"
  }

  $installedPluginVersions = Get-BundledMarketplacePluginVersions $InstalledMarketplaceRoot $pluginNames
  $stablePluginVersions = Get-BundledMarketplacePluginVersions $MarketplaceRoot $stablePluginNames
  foreach ($pluginName in $pluginNames) {
    $installedVersion = [string]$installedPluginVersions[$pluginName]
    $stableVersion = [string]$stablePluginVersions[$pluginName]
    if ($stableVersion -ne $installedVersion) {
      throw "stable bundled marketplace descriptor version does not match the installed package for ${pluginName}: installed=$installedVersion stable=$stableVersion"
    }
  }

  $pluginList = Get-BundledMarketplacePluginListWithCodexCli -IncludeAvailable
  $entries = @($pluginList.installed) + @($pluginList.available)
  foreach ($pluginName in $pluginNames) {
    $selector = "$pluginName@openai-bundled"
    $availablePlugins = @($entries | Where-Object {
      [string]$_.pluginId -eq $selector
    })
    if ($availablePlugins.Count -eq 0) {
      throw "bundled plugin is not discoverable as installed or available: $selector"
    }

    $installedVersion = [string]$installedPluginVersions[$pluginName]
    foreach ($availablePlugin in $availablePlugins) {
      $cliVersion = [string]$availablePlugin.version
      if ([string]::IsNullOrWhiteSpace($cliVersion)) {
        throw "bundled plugin CLI entry has no version: $selector"
      }
      if ($cliVersion -ne $installedVersion) {
        throw "bundled plugin CLI version does not match the installed package for ${selector}: installed=$installedVersion cli=$cliVersion"
      }
    }

    $sourcePath = [string]$availablePlugins[0].source.path
    $descriptorPath = if ([string]::IsNullOrWhiteSpace($sourcePath)) {
      $null
    } else {
      Join-Path $sourcePath '.codex-plugin\plugin.json'
    }
    if ([string]::IsNullOrWhiteSpace($descriptorPath) -or -not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
      throw "bundled plugin has no installable local source: $selector"
    }
  }
  Write-Log "all bundled marketplace plugins are available without changing install state: $($pluginNames -join ',')"
}

function Sync-OpenAiBundledPluginCache {
  param(
    [string]$MarketplaceRoot,
    [string]$PluginName
  )

  $sourcePluginRoot = Join-Path $MarketplaceRoot "plugins\$PluginName"
  $version = Get-PluginVersion $sourcePluginRoot
  $cacheRoot = Join-Path $CodexHome "plugins\cache\openai-bundled\$PluginName"
  $cacheVersionRoot = Join-Path $cacheRoot $version
  $latestPath = Join-Path $cacheRoot 'latest'

  Resolve-OrCreateDirectory $cacheRoot | Out-Null
  Assert-UnderPath $cacheVersionRoot $cacheRoot
  Assert-UnderPath $latestPath $cacheRoot

  Stop-OpenAiBundledExtensionHosts @($sourcePluginRoot, $cacheRoot)

  Write-Log "syncing bundled plugin cache: $PluginName@$version"
  if (Test-Path -LiteralPath $cacheVersionRoot) {
    Remove-ReparsePointOrDirectory $cacheVersionRoot
  }

  Copy-DirectoryDataOnly $sourcePluginRoot $cacheVersionRoot

  if (Test-Path -LiteralPath $latestPath) {
    Remove-ReparsePointOrDirectory $latestPath
  }
  New-Item -ItemType Junction -Path $latestPath -Target $cacheVersionRoot | Out-Null
  Write-Log "updated bundled plugin latest junction: $latestPath -> $cacheVersionRoot"

  return $cacheVersionRoot
}

function Get-ChromeNativeMessagingSettings {
  param([string]$ChromeCacheRoot)

  $extensionIdsPath = Join-Path $ChromeCacheRoot 'scripts\extension-ids.json'
  if (-not (Test-Path -LiteralPath $extensionIdsPath -PathType Leaf)) {
    throw "missing Chrome extension ID descriptor: $extensionIdsPath"
  }

  try {
    $extensionIdsDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $extensionIdsPath | ConvertFrom-Json
  } catch {
    throw "failed to parse Chrome extension ID descriptor ${extensionIdsPath}: $($_.Exception.Message)"
  }

  $extensionIds = @($extensionIdsDocument.extensionIds | ForEach-Object { ([string]$_).Trim() })
  if ($extensionIds.Count -eq 0) {
    throw "Chrome extension ID descriptor has no top-level extensionIds: $extensionIdsPath"
  }

  $seenExtensionIds = @{}
  $allowedOrigins = @()
  foreach ($extensionId in $extensionIds) {
    if ($extensionId -cnotmatch '^[a-p]{32}$') {
      throw "Chrome extension ID descriptor contains an invalid extension ID: $extensionId"
    }
    if ($seenExtensionIds.ContainsKey($extensionId)) {
      throw "Chrome extension ID descriptor contains a duplicate extension ID: $extensionId"
    }
    $seenExtensionIds[$extensionId] = $true
    $allowedOrigins += "chrome-extension://$extensionId/"
  }

  $hostName = [string]$extensionIdsDocument.extensionHostName
  $registryRoot = [string]$extensionIdsDocument.windowsNativeMessaging.registryRoot
  if ([string]::IsNullOrWhiteSpace($hostName)) {
    throw "Chrome extension ID descriptor has no extensionHostName: $extensionIdsPath"
  }
  if ([string]::IsNullOrWhiteSpace($registryRoot) -or -not $registryRoot.StartsWith('HKCU\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Chrome extension ID descriptor has an invalid HKCU native messaging registry root: $extensionIdsPath"
  }

  return [pscustomobject]@{
    AllowedOrigins = $allowedOrigins
    BrowserClientPath = (Join-Path $ChromeCacheRoot 'scripts\browser-client.mjs')
    ExtensionIds = $extensionIds
    ExtensionHostConfigPath = (Join-Path $ChromeCacheRoot 'extension-host\windows\x64\extension-host-config.json')
    ExtensionIdsPath = $extensionIdsPath
    HostExecutable = (Join-Path $ChromeCacheRoot 'extension-host\windows\x64\extension-host.exe')
    HostName = $hostName
    InstallManifestPath = (Join-Path $ChromeCacheRoot 'scripts\installManifest.mjs')
    ManifestPath = (Join-Path $env:LOCALAPPDATA "OpenAI\extension\$hostName.json")
    RegistryKey = "$registryRoot\$hostName"
  }
}

function Test-FilesMatchByContent {
  param(
    [string]$CandidatePath,
    [string]$ReferencePath
  )

  if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf) -or -not (Test-Path -LiteralPath $ReferencePath -PathType Leaf)) {
    return $false
  }
  if ((Get-Item -LiteralPath $CandidatePath).Length -ne (Get-Item -LiteralPath $ReferencePath).Length) {
    return $false
  }
  return (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $ReferencePath -Algorithm SHA256).Hash
}

function Get-CurrentCodexAppServerRuntimeInventory {
  param(
    [string]$PackageResourcesRoot,
    [string]$LocalCodexRoot = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'),
    [string]$CodexHomeRoot = $CodexHome
  )

  if ([string]::IsNullOrWhiteSpace($PackageResourcesRoot)) {
    $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
      Sort-Object Version -Descending |
      Select-Object -First 1
    if (-not $package) {
      throw 'OpenAI.Codex package is not installed; cannot discover app-server runtime paths'
    }
    $PackageResourcesRoot = Join-Path $package.InstallLocation 'app\resources'
  }

  $packageCodex = Join-Path $PackageResourcesRoot 'codex.exe'
  $packageCuaBin = Join-Path $PackageResourcesRoot 'cua_node\bin'
  $packageNode = Join-Path $packageCuaBin 'node.exe'
  $packageNodeRepl = Join-Path $packageCuaBin 'node_repl.exe'
  foreach ($requiredPath in @($packageCodex, $packageNode, $packageNodeRepl)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "current Codex package runtime is incomplete: $requiredPath"
    }
  }

  $codexCandidates = @()
  $localBinRoot = Join-Path $LocalCodexRoot 'bin'
  if (Test-Path -LiteralPath $localBinRoot -PathType Container) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $localBinRoot -Directory -ErrorAction SilentlyContinue)) {
      $candidate = Join-Path $directory.FullName 'codex.exe'
      if ($candidate -notmatch '(?i)[\\/]\.plugin-appserver[\\/]' -and (Test-FilesMatchByContent $candidate $packageCodex)) {
        $codexCandidates += [pscustomobject]@{ Path = $candidate; Priority = 0; LastWriteTime = (Get-Item $candidate).LastWriteTime }
      }
    }
  }
  $desktopManagedCodexCliPaths = @()
  $codexHomeForAppServer = $CodexHomeRoot
  if ([string]::IsNullOrWhiteSpace($codexHomeForAppServer)) {
    $codexHomeForAppServer = Join-Path $env:USERPROFILE '.codex'
  }
  $desktopManagedCodex = Join-Path $codexHomeForAppServer 'plugins\.plugin-appserver\codex.exe'
  if (Test-FilesMatchByContent $desktopManagedCodex $packageCodex) {
    $desktopManagedCodexCliPaths += [System.IO.Path]::GetFullPath($desktopManagedCodex)
  }
  $cuaCandidates = @()
  $localCuaRoot = Join-Path $LocalCodexRoot 'runtimes\cua_node'
  if (Test-Path -LiteralPath $localCuaRoot -PathType Container) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $localCuaRoot -Directory -ErrorAction SilentlyContinue)) {
      $binRoot = Join-Path $directory.FullName 'bin'
      $node = Join-Path $binRoot 'node.exe'
      $nodeRepl = Join-Path $binRoot 'node_repl.exe'
      if ((Test-FilesMatchByContent $node $packageNode) -and (Test-FilesMatchByContent $nodeRepl $packageNodeRepl)) {
        $cuaCandidates += [pscustomobject]@{ NodePath = $node; NodeReplPath = $nodeRepl; BinRoot = $binRoot; Priority = 0; LastWriteTime = (Get-Item $node).LastWriteTime }
      }
    }
  }
  if ($codexCandidates.Count -eq 0) {
    throw "no current user-local Codex CLI matches the installed package under $localBinRoot; launch Codex Desktop once so it can extract the current runtime"
  }
  if ($cuaCandidates.Count -eq 0) {
    throw "no current user-local CUA Node runtime matches the installed package under $localCuaRoot; launch Codex Desktop once so it can extract the current runtime"
  }

  $selectedCodex = @($codexCandidates | Sort-Object Priority, @{ Expression = 'LastWriteTime'; Descending = $true } | Select-Object -First 1)[0]
  $selectedCua = @($cuaCandidates | Sort-Object Priority, @{ Expression = 'LastWriteTime'; Descending = $true } | Select-Object -First 1)[0]
  $nodeVersionOutput = @(& $selectedCua.NodePath --version 2>&1)
  if ($LASTEXITCODE -ne 0 -or $nodeVersionOutput.Count -eq 0) {
    throw "current user-local CUA Node runtime is not executable: $($selectedCua.NodePath)"
  }
  return [pscustomobject]@{
    CodexCliPath = $selectedCodex.Path
    NodePath = $selectedCua.NodePath
    NodeReplPath = $selectedCua.NodeReplPath
    AllowedCodexCliPaths = @($codexCandidates | ForEach-Object { $_.Path })
    DesktopManagedCodexCliPaths = @($desktopManagedCodexCliPaths)
    AllowedCuaBinRoots = @($cuaCandidates | ForEach-Object { $_.BinRoot })
    ReferenceCodexCliPath = $packageCodex
    ReferenceNodePath = $packageNode
    ReferenceNodeReplPath = $packageNodeRepl
    PackageResourcesRoot = $PackageResourcesRoot
  }
}

function Resolve-ExistingFileProviderPath {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "required file does not exist: $Path"
  }
  return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Get-FinalFileIdentityPath {
  param([string]$Path)

  $providerPath = Resolve-ExistingFileProviderPath $Path
  if (-not ('CodexFinalPathResolver' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class CodexFinalPathResolver {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFile(
    string fileName,
    uint desiredAccess,
    FileShare shareMode,
    IntPtr securityAttributes,
    FileMode creationDisposition,
    uint flagsAndAttributes,
    IntPtr templateFile
  );

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern uint GetFinalPathNameByHandle(
    SafeFileHandle file,
    [Out] StringBuilder filePath,
    uint filePathSize,
    uint flags
  );

  public static string Resolve(string path) {
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    using (SafeFileHandle handle = CreateFile(
      path,
      0,
      FileShare.ReadWrite | FileShare.Delete,
      IntPtr.Zero,
      FileMode.Open,
      FILE_FLAG_BACKUP_SEMANTICS,
      IntPtr.Zero
    )) {
      if (handle.IsInvalid) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open path: " + path);
      }
      StringBuilder buffer = new StringBuilder(32768);
      uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
      if (length == 0 || length >= buffer.Capacity) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve final path: " + path);
      }
      string result = buffer.ToString();
      if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
        result = @"\\" + result.Substring(8);
      } else if (result.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) {
        result = result.Substring(4);
      }
      return Path.GetFullPath(result);
    }
  }
}
'@
  }
  return [CodexFinalPathResolver]::Resolve($providerPath)
}

function Test-PathMatchesAnyCurrentFile {
  param(
    [string]$ActualPath,
    [string[]]$ExpectedPaths
  )

  if (-not (Test-Path -LiteralPath $ActualPath -PathType Leaf)) {
    return $false
  }
  $actualResolved = Get-FinalFileIdentityPath $ActualPath
  foreach ($expectedPath in @($ExpectedPaths)) {
    if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
      continue
    }
    $expectedResolved = Get-FinalFileIdentityPath $expectedPath
    if ($actualResolved -ieq $expectedResolved) {
      return $true
    }
  }
  return $false
}

function Get-CurrentChromeManifestRoots {
  param([string]$ChromeCacheRoot)

  $version = Get-PluginVersion $ChromeCacheRoot
  $candidates = @($ChromeCacheRoot, (Join-Path (Split-Path -Parent $ChromeCacheRoot) 'latest'))
  try {
    $stableMarketplaceRoot = Get-StableBundledMarketplaceRoot (Resolve-OrCreateDirectory $CodexHome)
    $stableDataRoot = Split-Path -Parent $stableMarketplaceRoot
    $stableCacheRoot = Join-Path $stableDataRoot 'openai-bundled-cache\chrome'
    $candidates += (Join-Path $stableCacheRoot $version), (Join-Path $stableCacheRoot 'latest')
  } catch {
    Write-Log "warning: unable to discover secondary stable Chrome cache root: $($_.Exception.Message)"
  }

  $roots = @()
  $seen = @{}
  foreach ($candidate in $candidates) {
    $descriptor = Join-Path $candidate '.codex-plugin\plugin.json'
    if (-not (Test-Path -LiteralPath $descriptor -PathType Leaf)) {
      continue
    }
    try {
      if ((Get-PluginVersion $candidate) -ne $version) {
        continue
      }
    } catch {
      continue
    }
    $key = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\').ToLowerInvariant()
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $roots += $candidate
    }
  }
  return $roots
}

function Invoke-ChromeOfficialManifestInstall {
  param(
    [string]$ChromeCacheRoot,
    [object]$RuntimeInventory
  )

  $installManifestPath = Join-Path $ChromeCacheRoot 'scripts\installManifest.mjs'
  if (-not (Test-Path -LiteralPath $installManifestPath -PathType Leaf)) {
    throw "missing official Chrome manifest installer: $installManifestPath"
  }
  $driver = @'
import { pathToFileURL } from "node:url";
const installer = await import(pathToFileURL(process.argv[2]).href);
const appServerRuntimePaths = {
  codexCliPath: process.argv[3],
  nodePath: process.argv[4],
  nodeReplPath: process.argv[5],
  proxyHost: "127.0.0.1",
  proxyPort: 0,
};
await installer.install({ appServerRuntimePaths });
'@
  $driverPath = Join-Path $env:TEMP ('codex-chrome-install-manifest-' + [guid]::NewGuid().ToString('N') + '.mjs')
  try {
    Write-Utf8NoBom $driverPath $driver
    $output = @(& $RuntimeInventory.NodePath $driverPath $installManifestPath $RuntimeInventory.CodexCliPath $RuntimeInventory.NodePath $RuntimeInventory.NodeReplPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "official Chrome manifest installer failed: $($output -join [Environment]::NewLine)"
    }
    Write-Log "official Chrome native-host and app-server config installed: codex=$($RuntimeInventory.CodexCliPath) node=$($RuntimeInventory.NodePath)"
  } finally {
    Remove-Item -LiteralPath $driverPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ChromeNativeHostV2StatePaths {
  param([string]$CodexHomeResolved)

  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    $localAppData = Join-Path $env:USERPROFILE 'AppData\Local'
  }
  $candidates = @(
    (Join-Path $localAppData 'OpenAI\Codex\chrome-native-hosts-v2.json'),
    (Join-Path $CodexHomeResolved 'chrome-native-hosts-v2.json')
  )
  $seen = @{}
  $paths = @()
  foreach ($candidate in $candidates) {
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    $key = $fullPath.ToLowerInvariant()
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $paths += $fullPath
    }
  }
  return $paths
}

function Get-ChromeNativeHostV2Identity {
  param(
    [string]$Prefix,
    [string[]]$Values
  )

  $payload = (($Values | ForEach-Object { [string]$_ }) -join ([char]0)) + [char]0
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }
  return $Prefix + $hash.Substring(0, 32)
}

function Get-ChromeNativeHostV2ExpectedResource {
  param(
    [string]$ChromeCacheRoot,
    [pscustomobject]$RuntimeInventory,
    [string]$CodexHomeResolved,
    [string]$CodexCliPathOverride
  )

  $settings = Get-ChromeNativeMessagingSettings $ChromeCacheRoot
  if (-not (Test-Path -LiteralPath $settings.ManifestPath -PathType Leaf)) {
    throw "Chrome native messaging manifest is missing before v2 registration: $($settings.ManifestPath)"
  }
  try {
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $settings.ManifestPath | ConvertFrom-Json
  } catch {
    throw "failed to parse Chrome native messaging manifest before v2 registration $($settings.ManifestPath): $($_.Exception.Message)"
  }
  $extensionHostPath = [string]$manifest.path
  $hostConfigPath = Join-Path (Split-Path -Parent $extensionHostPath) 'extension-host-config.json'
  if (-not (Test-Path -LiteralPath $hostConfigPath -PathType Leaf)) {
    throw "Chrome app-server host config is missing before v2 registration: $hostConfigPath"
  }
  try {
    $hostConfig = Get-Content -Raw -Encoding UTF8 -LiteralPath $hostConfigPath | ConvertFrom-Json
  } catch {
    throw "failed to parse Chrome app-server host config before v2 registration ${hostConfigPath}: $($_.Exception.Message)"
  }

  $pluginVersion = Get-PluginVersion $ChromeCacheRoot
  if ($pluginVersion -cnotmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
    throw "Chrome plugin version is not valid for the v2 native-host manifest: $pluginVersion"
  }
  $nodeModuleRoot = Join-Path (Split-Path -Parent $RuntimeInventory.NodePath) 'node_modules'
  $browserClientPath = [string]$hostConfig.browserClientPath
  $browserServicePath = Join-Path (Split-Path -Parent $browserClientPath) 'browser-service.mjs'
  $appServerCliPath = $RuntimeInventory.CodexCliPath
  if (-not [string]::IsNullOrWhiteSpace($CodexCliPathOverride)) {
    $appServerCliPath = $CodexCliPathOverride
  }
  $requiredFiles = @(
    $extensionHostPath,
    $browserClientPath,
    $browserServicePath,
    $appServerCliPath,
    $RuntimeInventory.NodePath,
    $RuntimeInventory.NodeReplPath
  )
  foreach ($requiredPath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "Chrome v2 native-host resource has a missing required file: $requiredPath"
    }
  }
  foreach ($requiredDirectory in @($RuntimeInventory.PackageResourcesRoot, $nodeModuleRoot)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
      throw "Chrome v2 native-host resource has a missing required directory: $requiredDirectory"
    }
  }

  $paths = [ordered]@{
    browserClientPath = $browserClientPath
    browserServicePath = $browserServicePath
    codexCliPath = $appServerCliPath
    codexHome = $CodexHomeResolved
    extensionHostPath = $extensionHostPath
    nodePath = $RuntimeInventory.NodePath
    nodeModuleDirs = @($nodeModuleRoot)
    nodeReplPath = $RuntimeInventory.NodeReplPath
    resourcesPath = $RuntimeInventory.PackageResourcesRoot
  }
  $channel = 'prod'
  $entryIdentityValues = @($settings.HostName) + @($settings.ExtensionIds) + @(
    $channel,
    $pluginVersion,
    $paths.extensionHostPath,
    $paths.codexCliPath,
    $paths.codexHome,
    $paths.resourcesPath
  )
  $entryId = Get-ChromeNativeHostV2Identity -Prefix 'codex-runtime-' -Values $entryIdentityValues
  $installId = Get-ChromeNativeHostV2Identity 'codex-install-' @(
    $settings.HostName,
    $paths.resourcesPath,
    $paths.codexHome
  )
  $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
  $startedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)

  return [pscustomobject][ordered]@{
    schemaVersion = 2
    appServerProtocolVersion = 2
    appVersion = $pluginVersion
    channel = $channel
    cliVersion = $pluginVersion
    entryId = $entryId
    extensionBuildChannels = @($channel)
    extensionIds = @($settings.ExtensionIds)
    installId = $installId
    nativeHostNames = @($settings.HostName)
    nativeHostProtocolVersion = 2
    nativeHostVersion = $pluginVersion
    paths = [pscustomobject]$paths
    presence = [pscustomobject][ordered]@{
      lastSeenAt = $now
      pid = $PID
      startedAt = $startedAt
    }
    proxyHost = '127.0.0.1'
    proxyPort = 0
    updatedAt = $now
  }
}

function Get-ChromeNativeHostV2AcceptableResources {
  param(
    [string]$ChromeCacheRoot,
    [pscustomobject]$RuntimeInventory,
    [string]$CodexHomeResolved
  )

  $resources = @(Get-ChromeNativeHostV2ExpectedResource $ChromeCacheRoot $RuntimeInventory $CodexHomeResolved)
  foreach ($desktopManagedPath in @($RuntimeInventory.DesktopManagedCodexCliPaths)) {
    if ([string]::IsNullOrWhiteSpace($desktopManagedPath)) {
      continue
    }
    if (Test-PathMatchesAnyCurrentFile $desktopManagedPath @($resources[0].paths.codexCliPath)) {
      continue
    }
    $resources += (Get-ChromeNativeHostV2ExpectedResource `
      $ChromeCacheRoot $RuntimeInventory $CodexHomeResolved -CodexCliPathOverride $desktopManagedPath)
  }
  return @($resources)
}

function Test-ChromeNativeHostV2JsonObject {
  param([object]$Value)

  return $null -ne $Value -and (
    $Value -is [pscustomobject] -or
    $Value -is [System.Collections.IDictionary]
  )
}

function Test-ChromeNativeHostV2JsonInteger {
  param(
    [object]$Value,
    [decimal]$Minimum,
    [decimal]$Maximum
  )

  if ($null -eq $Value) {
    return $false
  }
  $numericTypeCodes = @(
    [System.TypeCode]::Byte,
    [System.TypeCode]::SByte,
    [System.TypeCode]::Int16,
    [System.TypeCode]::UInt16,
    [System.TypeCode]::Int32,
    [System.TypeCode]::UInt32,
    [System.TypeCode]::Int64,
    [System.TypeCode]::UInt64,
    [System.TypeCode]::Single,
    [System.TypeCode]::Double,
    [System.TypeCode]::Decimal
  )
  if ($numericTypeCodes -notcontains [System.Type]::GetTypeCode($Value.GetType())) {
    return $false
  }
  try {
    $number = [decimal]$Value
  } catch {
    return $false
  }
  return [decimal]::Truncate($number) -eq $number -and $number -ge $Minimum -and $number -le $Maximum
}

function Test-ChromeNativeHostV2JsonString {
  param([object]$Value)

  return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Test-ChromeNativeHostV2TimestampValue {
  param([object]$Value)

  if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
    return $true
  }
  return Test-ChromeNativeHostV2JsonString $Value
}

function Test-ChromeNativeHostV2JsonStringArray {
  param([object]$Value)

  if (-not ($Value -is [System.Array])) {
    return $false
  }
  foreach ($item in $Value) {
    if (-not (Test-ChromeNativeHostV2JsonString $item)) {
      return $false
    }
  }
  return $true
}

function Test-ChromeNativeHostV2DocumentSchema {
  param([object]$Document)

  if (-not (Test-ChromeNativeHostV2JsonObject $Document)) {
    return $false
  }
  $schemaVersionProperty = $Document.PSObject.Properties['schemaVersion']
  $entriesProperty = $Document.PSObject.Properties['entries']
  return $null -ne $schemaVersionProperty -and
    (Test-ChromeNativeHostV2JsonInteger $schemaVersionProperty.Value 2 2) -and
    $null -ne $entriesProperty -and
    $entriesProperty.Value -is [System.Array]
}

function Test-ChromeNativeHostV2EntrySchema {
  param([object]$Entry)

  if (-not (Test-ChromeNativeHostV2JsonObject $Entry)) {
    return $false
  }

  foreach ($specification in @(
    @('schemaVersion', 2, 2),
    @('appServerProtocolVersion', 2, 2),
    @('nativeHostProtocolVersion', 2, 2),
    @('proxyPort', 0, 65535)
  )) {
    $property = $Entry.PSObject.Properties[[string]$specification[0]]
    if ($null -eq $property -or -not (Test-ChromeNativeHostV2JsonInteger $property.Value $specification[1] $specification[2])) {
      return $false
    }
  }

  foreach ($propertyName in @(
    'appVersion',
    'channel',
    'cliVersion',
    'entryId',
    'installId',
    'nativeHostVersion',
    'proxyHost'
  )) {
    $property = $Entry.PSObject.Properties[$propertyName]
    if ($null -eq $property -or -not (Test-ChromeNativeHostV2JsonString $property.Value)) {
      return $false
    }
  }
  $updatedAtProperty = $Entry.PSObject.Properties['updatedAt']
  if ($null -eq $updatedAtProperty -or -not (Test-ChromeNativeHostV2TimestampValue $updatedAtProperty.Value)) {
    return $false
  }
  foreach ($propertyName in @('appVersion', 'cliVersion', 'nativeHostVersion')) {
    if ([string]$Entry.$propertyName -cnotmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
      return $false
    }
  }

  foreach ($propertyName in @('extensionBuildChannels', 'extensionIds', 'nativeHostNames')) {
    $property = $Entry.PSObject.Properties[$propertyName]
    if ($null -eq $property -or -not (Test-ChromeNativeHostV2JsonStringArray $property.Value)) {
      return $false
    }
  }

  $pathsProperty = $Entry.PSObject.Properties['paths']
  if ($null -eq $pathsProperty -or -not (Test-ChromeNativeHostV2JsonObject $pathsProperty.Value)) {
    return $false
  }
  $paths = $pathsProperty.Value
  foreach ($propertyName in @('codexCliPath', 'codexHome', 'extensionHostPath', 'nodePath', 'resourcesPath')) {
    $property = $paths.PSObject.Properties[$propertyName]
    if ($null -eq $property -or -not (Test-ChromeNativeHostV2JsonString $property.Value)) {
      return $false
    }
  }
  foreach ($propertyName in @('browserClientPath', 'browserServicePath', 'nodeReplPath')) {
    $property = $paths.PSObject.Properties[$propertyName]
    if ($null -ne $property -and -not (Test-ChromeNativeHostV2JsonString $property.Value)) {
      return $false
    }
  }
  $nodeModuleDirsProperty = $paths.PSObject.Properties['nodeModuleDirs']
  if ($null -ne $nodeModuleDirsProperty -and -not (Test-ChromeNativeHostV2JsonStringArray $nodeModuleDirsProperty.Value)) {
    return $false
  }

  $presenceProperty = $Entry.PSObject.Properties['presence']
  if ($null -ne $presenceProperty) {
    $presence = $presenceProperty.Value
    if (-not (Test-ChromeNativeHostV2JsonObject $presence)) {
      return $false
    }
    foreach ($propertyName in @('lastSeenAt', 'startedAt')) {
      $property = $presence.PSObject.Properties[$propertyName]
      if ($null -eq $property -or -not (Test-ChromeNativeHostV2TimestampValue $property.Value)) {
        return $false
      }
    }
    $pidProperty = $presence.PSObject.Properties['pid']
    if ($null -eq $pidProperty -or -not (Test-ChromeNativeHostV2JsonInteger $pidProperty.Value 1 ([long]::MaxValue))) {
      return $false
    }
  }
  return $true
}

function Test-ChromeNativeHostV2EntryCoreEqual {
  param(
    [object]$Actual,
    [object]$Expected
  )

  if (-not (Test-ChromeNativeHostV2EntrySchema $Actual) -or -not (Test-ChromeNativeHostV2EntrySchema $Expected)) {
    return $false
  }
  foreach ($propertyName in @('schemaVersion', 'appServerProtocolVersion', 'nativeHostProtocolVersion', 'proxyPort')) {
    if ([decimal]$Actual.$propertyName -ne [decimal]$Expected.$propertyName) {
      return $false
    }
  }
  foreach ($propertyName in @(
    'appVersion',
    'channel',
    'cliVersion',
    'entryId',
    'installId',
    'nativeHostVersion',
    'proxyHost'
  )) {
    if ([string]$Actual.$propertyName -cne [string]$Expected.$propertyName) {
      return $false
    }
  }
  foreach ($propertyName in @('extensionBuildChannels', 'extensionIds', 'nativeHostNames')) {
    if (-not (Test-OrdinalStringArrayEqual -Actual @($Actual.$propertyName) -Expected @($Expected.$propertyName))) {
      return $false
    }
  }
  foreach ($propertyName in @(
    'browserClientPath',
    'browserServicePath',
    'codexCliPath',
    'codexHome',
    'extensionHostPath',
    'nodePath',
    'nodeReplPath',
    'resourcesPath'
  )) {
    if ([string]$Actual.paths.$propertyName -cne [string]$Expected.paths.$propertyName) {
      return $false
    }
  }
  return Test-OrdinalStringArrayEqual -Actual @($Actual.paths.nodeModuleDirs) -Expected @($Expected.paths.nodeModuleDirs)
}

function Test-ChromeNativeHostV2EntryReplacedBy {
  param(
    [object]$Actual,
    [object]$Expected
  )

  $entryIdProperty = if (Test-ChromeNativeHostV2JsonObject $Actual) { $Actual.PSObject.Properties['entryId'] } else { $null }
  if ($null -ne $entryIdProperty -and $entryIdProperty.Value -is [string] -and
      [string]$entryIdProperty.Value -ceq [string]$Expected.entryId) {
    return $true
  }
  if (-not (Test-ChromeNativeHostV2EntrySchema $Actual)) {
    return $false
  }
  if ([string]$Actual.installId -cne [string]$Expected.installId -or [string]$Actual.channel -cne [string]$Expected.channel) {
    return $false
  }
  $extensionOverlap = @($Actual.extensionIds | Where-Object { @($Expected.extensionIds) -ccontains [string]$_ }).Count -gt 0
  $hostOverlap = @($Actual.nativeHostNames | Where-Object { @($Expected.nativeHostNames) -ccontains [string]$_ }).Count -gt 0
  return $extensionOverlap -and $hostOverlap
}

function Write-ChromeNativeHostV2State {
  param(
    [string]$StatePath,
    [pscustomobject]$ExpectedResource,
    [pscustomobject[]]$AcceptableResources
  )

  $acceptable = @($AcceptableResources | Where-Object { $null -ne $_ })
  if ($acceptable.Count -eq 0) {
    $acceptable = @($ExpectedResource)
  }
  $raw = $null
  $entries = @()
  if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    $raw = [System.IO.File]::ReadAllText($StatePath, [System.Text.UTF8Encoding]::new($false))
    try {
      $document = $raw | ConvertFrom-Json
      if (Test-ChromeNativeHostV2DocumentSchema $document) {
        $entries = @($document.entries)
      } else {
        Write-Log "warning: replacing invalid Chrome native-host v2 state: $StatePath"
      }
    } catch {
      Write-Log "warning: replacing invalid Chrome native-host v2 state: $StatePath"
    }
  }

  $existingCurrent = @($entries | Where-Object {
    $entry = $_
    @($acceptable | Where-Object { Test-ChromeNativeHostV2EntryCoreEqual $entry $_ }).Count -gt 0
  } | Select-Object -First 1)
  $resource = if ($existingCurrent.Count -gt 0) { $existingCurrent[0] } else { $ExpectedResource }
  $nextEntries = @($entries | Where-Object {
    -not (Test-ChromeNativeHostV2EntryReplacedBy $_ $ExpectedResource)
  }) + @($resource)
  $nextEntries = @($nextEntries | Sort-Object {
    $hostName = [string]@($_.nativeHostNames)[0]
    "$hostName`:$($_.channel)`:$($_.entryId)"
  })
  $entriesChanged = $entries.Count -ne $nextEntries.Count
  if (-not $entriesChanged) {
    for ($index = 0; $index -lt $entries.Count; $index++) {
      if (-not [object]::ReferenceEquals($entries[$index], $nextEntries[$index])) {
        $entriesChanged = $true
        break
      }
    }
  }
  if (-not $entriesChanged) {
    return $false
  }
  $nextDocument = [ordered]@{
    schemaVersion = 2
    entries = $nextEntries
  }
  $nextRaw = (($nextDocument | ConvertTo-Json -Depth 30) + "`n")
  if ($null -ne $raw -and $raw -ceq $nextRaw) {
    return $false
  }

  $parent = Split-Path -Parent $StatePath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  if ($null -ne $raw) {
    $backupPath = "$StatePath.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').bak"
    Copy-Item -LiteralPath $StatePath -Destination $backupPath -Force
    Write-Log "Chrome native-host v2 state backup: $backupPath"
  }
  $temporaryPath = "$StatePath.tmp-$([guid]::NewGuid().ToString('N'))"
  $replaceBackupPath = "$StatePath.replace-$([guid]::NewGuid().ToString('N')).bak"
  try {
    Write-Utf8NoBom $temporaryPath $nextRaw
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
      [System.IO.File]::Replace($temporaryPath, $StatePath, $replaceBackupPath)
    } else {
      [System.IO.File]::Move($temporaryPath, $StatePath)
    }
  } finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
  }
  Write-Log "updated Chrome native-host v2 state: $StatePath entry=$($resource.entryId)"
  return $true
}

function Update-ChromeNativeHostV2State {
  param(
    [string]$ChromeCacheRoot,
    [pscustomobject]$RuntimeInventory,
    [string]$CodexHomeResolved = (Resolve-OrCreateDirectory $CodexHome)
  )

  $acceptable = @(Get-ChromeNativeHostV2AcceptableResources $ChromeCacheRoot $RuntimeInventory $CodexHomeResolved)
  $expected = $acceptable[0]
  foreach ($statePath in @(Get-ChromeNativeHostV2StatePaths $CodexHomeResolved)) {
    Write-ChromeNativeHostV2State $statePath $expected -AcceptableResources $acceptable | Out-Null
  }
}

function Test-ChromeNativeHostV2State {
  param(
    [string]$ChromeCacheRoot,
    [pscustomobject]$RuntimeInventory,
    [string]$CodexHomeResolved = (Resolve-ExistingDirectory $CodexHome)
  )

  $acceptable = @(Get-ChromeNativeHostV2AcceptableResources $ChromeCacheRoot $RuntimeInventory $CodexHomeResolved)
  $expected = $acceptable[0]
  $verifiedPaths = @()
  $matchedEntryIds = @()
  foreach ($statePath in @(Get-ChromeNativeHostV2StatePaths $CodexHomeResolved)) {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
      throw "Chrome native-host v2 state is missing: $statePath"
    }
    try {
      $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
    } catch {
      throw "failed to parse Chrome native-host v2 state ${statePath}: $($_.Exception.Message)"
    }
    if (-not (Test-ChromeNativeHostV2DocumentSchema $document)) {
      throw "Chrome native-host v2 state has an invalid schemaVersion or entries array: $statePath"
    }
    $matching = @($document.entries | Where-Object {
      $entry = $_
      @($acceptable | Where-Object { Test-ChromeNativeHostV2EntryCoreEqual $entry $_ }).Count -gt 0
    } | Select-Object -First 1)
    if ($matching.Count -eq 0) {
      throw "Chrome native-host v2 state has no current app-server entry: $statePath expected=$($expected.entryId)"
    }
    $verifiedPaths += $statePath
    $matchedEntryIds += [string]$matching[0].entryId
  }
  $matchedSummary = @($matchedEntryIds | Sort-Object -Unique) -join ','
  Write-Log "Chrome native-host v2 state verification ok: entry=$matchedSummary files=$($verifiedPaths.Count)"
}

function Test-OrdinalStringArrayEqual {
  param(
    [object[]]$Actual,
    [object[]]$Expected
  )

  $actualStrings = @($Actual | ForEach-Object { [string]$_ })
  $expectedStrings = @($Expected | ForEach-Object { [string]$_ })
  if ($actualStrings.Count -ne $expectedStrings.Count) {
    return $false
  }
  for ($index = 0; $index -lt $expectedStrings.Count; $index++) {
    if (-not [string]::Equals($actualStrings[$index], $expectedStrings[$index], [System.StringComparison]::Ordinal)) {
      return $false
    }
  }
  return $true
}

function Convert-ChromeRegistryKeyToProviderPath {
  param([string]$RegistryKey)

  if ($RegistryKey.StartsWith('HKCU\', [System.StringComparison]::OrdinalIgnoreCase)) {
    return 'Registry::HKEY_CURRENT_USER\' + $RegistryKey.Substring(5)
  }
  throw "unsupported Chrome native messaging registry key: $RegistryKey"
}

function Get-ChromeNativeMessagingRegistryManifestPath {
  param([string]$RegistryKey)

  $providerPath = Convert-ChromeRegistryKeyToProviderPath $RegistryKey
  if (-not (Test-Path -LiteralPath $providerPath)) {
    return $null
  }
  $key = Get-Item -LiteralPath $providerPath
  return [string]$key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Test-ChromeNativeMessagingManifest {
  param([string]$ChromeCacheRoot)

  $settings = Get-ChromeNativeMessagingSettings $ChromeCacheRoot
  if (-not (Test-Path -LiteralPath $settings.HostExecutable -PathType Leaf)) {
    throw "missing Chrome extension host executable: $($settings.HostExecutable)"
  }
  if (-not (Test-Path -LiteralPath $settings.ManifestPath -PathType Leaf)) {
    throw "missing Chrome native messaging manifest: $($settings.ManifestPath)"
  }

  try {
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $settings.ManifestPath | ConvertFrom-Json
  } catch {
    throw "failed to parse Chrome native messaging manifest $($settings.ManifestPath): $($_.Exception.Message)"
  }
  if ([string]$manifest.name -cne $settings.HostName -or [string]$manifest.type -cne 'stdio') {
    throw "Chrome native messaging manifest identity or type is stale: $($settings.ManifestPath)"
  }
  $currentHostPaths = @(Get-CurrentChromeManifestRoots $ChromeCacheRoot | ForEach-Object {
    Join-Path $_ 'extension-host\windows\x64\extension-host.exe'
  })
  if (-not (Test-PathMatchesAnyCurrentFile ([string]$manifest.path) $currentHostPaths)) {
    throw "Chrome native messaging manifest does not point at the current stable cache host: $($settings.ManifestPath)"
  }
  if (-not (Test-OrdinalStringArrayEqual -Actual @($manifest.allowed_origins) -Expected @($settings.AllowedOrigins))) {
    throw "Chrome native messaging manifest allowed_origins do not match $($settings.ExtensionIdsPath): $($settings.ManifestPath)"
  }

  $registeredManifestPath = Get-ChromeNativeMessagingRegistryManifestPath $settings.RegistryKey
  if ([string]::IsNullOrWhiteSpace($registeredManifestPath) -or $registeredManifestPath -ine $settings.ManifestPath) {
    throw "Chrome native messaging registry does not point at the current manifest: $($settings.RegistryKey)"
  }
  Write-Log "Chrome native messaging manifest verification ok: origins=$($settings.AllowedOrigins.Count)"
}

function Test-ChromeAppServerHostConfig {
  param(
    [string]$ChromeCacheRoot,
    [pscustomobject]$ExpectedRuntimePaths
  )

  if (-not $ExpectedRuntimePaths) {
    $ExpectedRuntimePaths = Get-CurrentCodexAppServerRuntimeInventory
  }
  $settings = Get-ChromeNativeMessagingSettings $ChromeCacheRoot
  if (-not (Test-Path -LiteralPath $settings.ManifestPath -PathType Leaf)) {
    throw "Chrome native messaging manifest is missing: $($settings.ManifestPath)"
  }
  try {
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $settings.ManifestPath | ConvertFrom-Json
  } catch {
    throw "failed to parse Chrome native messaging manifest $($settings.ManifestPath): $($_.Exception.Message)"
  }
  $currentChromeRoots = @(Get-CurrentChromeManifestRoots $ChromeCacheRoot)
  $currentHostPaths = @($currentChromeRoots | ForEach-Object {
    Join-Path $_ 'extension-host\windows\x64\extension-host.exe'
  })
  $hostExecutable = [string]$manifest.path
  if (-not (Test-PathMatchesAnyCurrentFile $hostExecutable $currentHostPaths)) {
    throw "Chrome app-server host config is not beside a current stable cache host: $hostExecutable"
  }
  $configPath = Join-Path (Split-Path -Parent $hostExecutable) 'extension-host-config.json'
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Chrome app-server host config is missing: $configPath"
  }
  try {
    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
  } catch {
    throw "failed to parse Chrome app-server host config ${configPath}: $($_.Exception.Message)"
  }
  if ([int]$config.schemaVersion -ne 1) {
    throw "Chrome app-server host config has an unsupported schemaVersion: $configPath"
  }
  if ([string]$config.channel -cne 'prod') {
    throw "Chrome app-server host config has an unexpected channel: $configPath"
  }
  if ([string]$config.proxyHost -cne '127.0.0.1' -or [int]$config.proxyPort -ne 0) {
    throw "Chrome app-server host config has invalid proxy settings: $configPath"
  }

  $browserClientPath = [string]$config.browserClientPath
  $currentBrowserClientPaths = @($currentChromeRoots | ForEach-Object {
    Join-Path $_ 'scripts\browser-client.mjs'
  })
  if ($browserClientPath -match '(?i)\\\.tmp\\bundled-marketplaces\\' -or
      -not (Test-PathMatchesAnyCurrentFile $browserClientPath $currentBrowserClientPaths)) {
    throw "Chrome app-server host config browserClientPath does not point at a current stable cache: $browserClientPath"
  }

  $codexCliPath = [string]$config.codexCliPath
  if ([string]::IsNullOrWhiteSpace($codexCliPath) -or -not (Test-Path -LiteralPath $codexCliPath -PathType Leaf)) {
    throw "Chrome app-server host config is missing required path codexCliPath: $codexCliPath"
  }
  if ($codexCliPath -match '(?i)[\\/]WindowsApps[\\/]' -or $codexCliPath -match '(?i)[\\/]\.plugin-appserver[\\/]') {
    throw "Chrome app-server host config codexCliPath is not a supported user-local runtime: $codexCliPath"
  }
  if (-not (Test-PathMatchesAnyCurrentFile $codexCliPath @($ExpectedRuntimePaths.AllowedCodexCliPaths))) {
    throw "Chrome app-server host config codexCliPath does not match the current Codex runtime: $codexCliPath"
  }

  $nodePath = [string]$config.nodePath
  $nodeReplPath = [string]$config.nodeReplPath
  foreach ($runtimeEntry in @(
    [pscustomobject]@{ Label = 'nodePath'; Path = $nodePath },
    [pscustomobject]@{ Label = 'nodeReplPath'; Path = $nodeReplPath }
  )) {
    if ([string]::IsNullOrWhiteSpace($runtimeEntry.Path) -or -not (Test-Path -LiteralPath $runtimeEntry.Path -PathType Leaf)) {
      throw "Chrome app-server host config is missing required path $($runtimeEntry.Label): $($runtimeEntry.Path)"
    }
    if ($runtimeEntry.Path -match '(?i)[\\/]WindowsApps[\\/]') {
      throw "Chrome app-server host config runtime points at a protected WindowsApps executable: $($runtimeEntry.Path)"
    }
  }
  $matchedCuaRuntime = $false
  foreach ($binRoot in @($ExpectedRuntimePaths.AllowedCuaBinRoots)) {
    if ((Test-PathMatchesAnyCurrentFile $nodePath @((Join-Path $binRoot 'node.exe'))) -and
        (Test-PathMatchesAnyCurrentFile $nodeReplPath @((Join-Path $binRoot 'node_repl.exe')))) {
      $matchedCuaRuntime = $true
      break
    }
  }
  if (-not $matchedCuaRuntime) {
    throw "Chrome app-server host config nodePath and nodeReplPath do not match one current CUA runtime: $configPath"
  }
  Write-Log "Chrome app-server host config verification ok: $configPath"
}

function Sync-BundledMarketplaceFromInstalledApp {
  param(
    [string]$MarketplaceRoot,
    [string]$SourceRoot
  )

  $parent = Split-Path -Parent $MarketplaceRoot
  Resolve-OrCreateDirectory $parent | Out-Null
  Assert-UnderPath $MarketplaceRoot $parent
  Stop-OpenAiBundledExtensionHosts @(
    $MarketplaceRoot,
    (Join-Path $CodexHome 'plugins\cache\openai-bundled'),
    (Join-Path (Split-Path -Parent $MarketplaceRoot) 'openai-bundled-cache')
  )

  Write-Log "syncing installed openai-bundled marketplace: $SourceRoot -> $MarketplaceRoot"
  Copy-DirectoryDataOnly $SourceRoot $MarketplaceRoot
}

function Test-FileContainsAsciiText {
  param(
    [string]$Path,
    [string]$Needle
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "file not found for ASCII search: $Path"
  }
  if ([string]::IsNullOrEmpty($Needle)) {
    return $false
  }

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

function Get-ChromeBrowserClientTrustMode {
  param(
    [string]$AppAsarPath,
    [string]$BrowserClientSha256
  )

  if (Test-FileContainsAsciiText $AppAsarPath $BrowserClientSha256) {
    return 'asar-sha256'
  }

  $nativeHostMarkers = @(
    'browserClientPath',
    'browserServicePath',
    'codex-host-chunked-message-v1',
    'Chrome native host did not provide a browser-client path'
  )
  foreach ($marker in $nativeHostMarkers) {
    if (-not (Test-FileContainsAsciiText $AppAsarPath $marker)) {
      throw "installed app.asar contains neither the packaged Chrome browser client hash nor the complete native-host path contract: sha256=$BrowserClientSha256 missing=$marker"
    }
  }

  return 'native-host-paths'
}

function Get-InstalledChromeBrowserClientTrust {
  param([string]$InstalledMarketplaceRoot)

  $sourcePath = Join-Path $InstalledMarketplaceRoot 'plugins\chrome\scripts\browser-client.mjs'
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "installed Chrome browser client is missing: $sourcePath"
  }

  $sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $resourcesRoot = Split-Path -Parent (Split-Path -Parent $InstalledMarketplaceRoot)
  $appAsarPath = Join-Path $resourcesRoot 'app.asar'
  $trustMode = Get-ChromeBrowserClientTrustMode $appAsarPath $sha256
  Write-Log "installed Chrome browser client contract: mode=$trustMode sha256=$sha256"

  return [pscustomobject]@{
    SourcePath = $sourcePath
    Sha256 = $sha256
    AppAsarPath = $appAsarPath
    TrustMode = $trustMode
  }
}

function Assert-ChromeBrowserClientTrustedBytes {
  param(
    [string]$BrowserClientPath,
    [pscustomobject]$TrustedBrowserClient
  )

  if (-not (Test-Path -LiteralPath $BrowserClientPath -PathType Leaf)) {
    throw "Chrome browser client is missing: $BrowserClientPath"
  }
  $actualHash = (Get-FileHash -LiteralPath $BrowserClientPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $TrustedBrowserClient.Sha256) {
    throw "Chrome browser client differs from the installed trusted bytes: $BrowserClientPath / expected=$($TrustedBrowserClient.Sha256) actual=$actualHash"
  }
}

function Restore-ChromeBrowserClientTrustedBytes {
  param(
    [string]$ChromePluginRoot,
    [pscustomobject]$TrustedBrowserClient
  )

  $browserClientPath = Join-Path $ChromePluginRoot 'scripts\browser-client.mjs'
  if (-not (Test-Path -LiteralPath $browserClientPath -PathType Leaf)) {
    throw "missing Chrome browser client: $browserClientPath"
  }
  $actualHash = (Get-FileHash -LiteralPath $browserClientPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $TrustedBrowserClient.Sha256) {
    [System.IO.File]::Copy($TrustedBrowserClient.SourcePath, $browserClientPath, $true)
    Write-Log "restored trusted Chrome browser client bytes: $browserClientPath"
  }
  Assert-ChromeBrowserClientTrustedBytes $browserClientPath $TrustedBrowserClient
}

function Patch-ChromeWindowsRegistryParsing {
  param(
    [string]$ChromePluginRoot,
    [pscustomobject]$TrustedBrowserClient
  )

  $genericOld = 'if (match && match[1] === label) return stripRegistryString(match[2]);'
  $genericNew = 'if (match && (valueName == null || match[1] === label)) return stripRegistryString(match[2]);'
  foreach ($relativePath in @('scripts\open-chrome-window.js', 'scripts\installed-browsers.js')) {
    $path = Join-Path $ChromePluginRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "missing Chrome registry helper: $path"
    }
    $content = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    if ($content.Contains($genericNew)) {
      continue
    }
    if (-not $content.Contains($genericOld)) {
      throw "Chrome registry parser anchor not found: $path"
    }
    Write-Utf8NoBom $path ($content.Replace($genericOld, $genericNew))
  }

  $nativeHostPath = Join-Path $ChromePluginRoot 'scripts\check-native-host-manifest.js'
  $nativeOld = 'if (match && match[1] === valueName) return stripRegistryString(match[2]);'
  $nativeNew = 'if (match && (valueName === "(Default)" || match[1] === valueName)) return stripRegistryString(match[2]);'
  if (-not (Test-Path -LiteralPath $nativeHostPath -PathType Leaf)) {
    throw "missing Chrome native-host registry helper: $nativeHostPath"
  }
  $nativeContent = [System.IO.File]::ReadAllText($nativeHostPath, [System.Text.UTF8Encoding]::new($false))
  if (-not $nativeContent.Contains($nativeNew)) {
    if (-not $nativeContent.Contains($nativeOld)) {
      throw "Chrome native-host registry parser anchor not found: $nativeHostPath"
    }
    Write-Utf8NoBom $nativeHostPath ($nativeContent.Replace($nativeOld, $nativeNew))
  }

  Restore-ChromeBrowserClientTrustedBytes $ChromePluginRoot $TrustedBrowserClient
  Write-Log 'patched Chrome registry parsing and preserved trusted browser client bytes'
}

function Test-BundledMarketplaceMirror {
  param([string]$MarketplaceRoot)

  $sourceRoot = Get-InstalledBundledMarketplaceRoot
  $sourceManifestPath = Join-Path $sourceRoot '.agents\plugins\marketplace.json'
  $localManifestPath = Join-Path $MarketplaceRoot '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $localManifestPath -PathType Leaf)) {
    throw "local openai-bundled marketplace manifest not found: $localManifestPath"
  }

  $sourceManifest = Get-Content -Raw -LiteralPath $sourceManifestPath | ConvertFrom-Json
  $localManifest = Get-Content -Raw -LiteralPath $localManifestPath | ConvertFrom-Json
  $localEntries = @{}
  foreach ($entry in @($localManifest.plugins)) {
    $localEntries[[string]$entry.name] = $entry
  }

  $installedPackage = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  $allowedRuntimeOmissions = @{}
  if ($installedPackage -and [string]$installedPackage.Version -eq '26.707.3748.0') {
    $allowedRuntimeOmissions['deep-research'] = $true
  }

  foreach ($sourceEntry in @($sourceManifest.plugins)) {
    $name = [string]$sourceEntry.name
    if (-not $localEntries.ContainsKey($name)) {
      $sourceRelativePath = ([string]$sourceEntry.source.path) -replace '^[.][\/]', ''
      $sourcePluginJson = Join-Path (Join-Path $sourceRoot $sourceRelativePath) '.codex-plugin\plugin.json'
      $localPluginRoot = Join-Path $MarketplaceRoot $sourceRelativePath
      $sourcePluginComplete = Test-Path -LiteralPath $sourcePluginJson -PathType Leaf
      if ($name -eq 'deep-research' -and $installedPackage -and [string]$installedPackage.Version -eq '26.707.3748.0') {
        $requiredSourceFiles = @(
          '.codex-plugin\plugin.json',
          'assets\deep-research.svg',
          'skills\deep-research\SKILL.md',
          'skills\deep-research\agents\openai.yaml',
          'skills\deep-research\references\report-contract.md',
          'skills\deep-research\references\research-method.md'
        )
        $sourcePluginComplete = @(
          $requiredSourceFiles | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path (Join-Path $sourceRoot $sourceRelativePath) $_) -PathType Leaf)
          }
        ).Count -eq 0
      }
      if (
        $allowedRuntimeOmissions.ContainsKey($name) -and
        $sourcePluginComplete -and
        -not (Test-Path -LiteralPath $localPluginRoot)
      ) {
        Write-Log "warning: installed optional bundled plugin was omitted by Desktop runtime reconciliation: $name"
        continue
      }
      throw "local openai-bundled marketplace is missing installed plugin entry: $name"
    }

    $localPath = [string]$localEntries[$name].source.path
    $relativePath = $localPath -replace '^[.][\\/]', ''
    $pluginJson = Join-Path (Join-Path $MarketplaceRoot $relativePath) '.codex-plugin\plugin.json'
    if (-not (Test-Path -LiteralPath $pluginJson -PathType Leaf)) {
      throw "local openai-bundled plugin files are missing for ${name}: $pluginJson"
    }
  }
}

function Test-CodexConfig {
  param(
    [string]$ConfigPath,
    [string]$MarketplaceRoot
  )

  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "missing Codex config: $ConfigPath"
  }

  Test-TomlSyntax $ConfigPath
  $expectedSource = '\\?\' + $MarketplaceRoot
  $reservedRoot = Get-ReservedBundledMarketplaceRoot (Resolve-OrCreateDirectory $CodexHome)
  $reservedSource = if (Test-BundledMarketplaceRootUsable $reservedRoot) { '\\?\' + $reservedRoot } else { $expectedSource }
  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
    if ($content -notmatch '(?ms)^\[marketplaces\.openai-bundled\]\s*\r?\n(?:(?!^\[).)*source_type\s*=\s*[''"]local[''"]') {
      throw 'config.toml is missing marketplaces.openai-bundled source_type=local'
    }
    if ($content -notmatch '(?ms)^\[plugins\."computer-use@openai-bundled"\]\s*\r?\n(?:(?!^\[).)*enabled\s*=\s*true') {
      throw 'config.toml is missing plugins."computer-use@openai-bundled".enabled=true'
    }
    if ($content -notmatch '(?ms)^\[plugins\."browser@openai-bundled"\]\s*\r?\n(?:(?!^\[).)*enabled\s*=\s*true') {
      throw 'config.toml is missing plugins."browser@openai-bundled".enabled=true'
    }
    if ($content -notmatch '(?ms)^\[plugins\."chrome@openai-bundled"\]\s*\r?\n(?:(?!^\[).)*enabled\s*=\s*true') {
      throw 'config.toml is missing plugins."chrome@openai-bundled".enabled=true'
    }
    if ($content -notmatch '(?ms)^\[windows\]\s*\r?\n(?:(?!^\[).)*sandbox\s*=\s*[''"]unelevated[''"]') {
      throw 'config.toml is missing windows.sandbox=unelevated'
    }
    $pipeState = Get-ComputerUsePipeConfigState $ConfigPath
    if ($pipeState.Present -and -not $pipeState.Active) {
      throw 'config.toml contains stale SKY_CUA_NATIVE_PIPE environment override'
    }
    Write-Log 'warning: python not found; config source path was not semantically validated'
    return
  }

  $script = @'
import pathlib
import sys
import tomllib

config_path = pathlib.Path(sys.argv[1])
expected_sources = [source for source in sys.argv[2:] if source]
data = tomllib.loads(config_path.read_text(encoding="utf-8"))
errors = []

marketplace = data.get("marketplaces", {}).get("openai-bundled")
if not isinstance(marketplace, dict):
    errors.append("missing [marketplaces.openai-bundled]")
else:
    if marketplace.get("source_type") != "local":
        errors.append("marketplaces.openai-bundled.source_type must be local")
    if marketplace.get("source") not in expected_sources:
        errors.append("marketplaces.openai-bundled.source does not point at a loadable local bundled marketplace")

plugins = data.get("plugins", {})
plugin = plugins.get("computer-use@openai-bundled")
if not isinstance(plugin, dict):
    errors.append('missing [plugins."computer-use@openai-bundled"]')
elif plugin.get("enabled") is not True:
    errors.append('plugins."computer-use@openai-bundled".enabled must be true')

required_plugin_ids = ["browser@openai-bundled", "chrome@openai-bundled"]

for plugin_id in required_plugin_ids:
    plugin = plugins.get(plugin_id)
    if not isinstance(plugin, dict):
        errors.append(f'missing [plugins."{plugin_id}"]')
    elif plugin.get("enabled") is not True:
        errors.append(f'plugins."{plugin_id}".enabled must be true')

windows = data.get("windows", {})
if not isinstance(windows, dict):
    errors.append("missing [windows]")
elif windows.get("sandbox") != "unelevated":
    errors.append('windows.sandbox must be "unelevated"')

node_repl_env = data.get("mcp_servers", {}).get("node_repl", {}).get("env", {})
if isinstance(node_repl_env, dict):
    pipe_enabled = node_repl_env.get("SKY_CUA_NATIVE_PIPE")
    pipe_directory = node_repl_env.get("SKY_CUA_NATIVE_PIPE_DIRECTORY")
    if pipe_enabled is not None or pipe_directory is not None:
        if str(pipe_enabled) != "1":
            errors.append("mcp_servers.node_repl.env.SKY_CUA_NATIVE_PIPE must be 1")
        if not isinstance(pipe_directory, str) or not pipe_directory.startswith(r"\\.\pipe\codex-computer-use-"):
            errors.append("mcp_servers.node_repl.env.SKY_CUA_NATIVE_PIPE_DIRECTORY is not a Codex Computer Use pipe")
        elif not pathlib.Path(pipe_directory).exists():
            errors.append("mcp_servers.node_repl.env.SKY_CUA_NATIVE_PIPE_DIRECTORY is stale")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
'@
  $temp = Join-Path $env:TEMP ('codex-config-validate-' + [guid]::NewGuid().ToString('N') + '.py')
  try {
    Write-Utf8NoBom $temp $script
    & $python.Source $temp $ConfigPath $expectedSource $reservedSource
    if ($LASTEXITCODE -ne 0) {
      throw "semantic config validation failed for $ConfigPath"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }

  # A configured source is not proof the CLI accepts it: codex-cli 0.149 silently
  # drops reserved marketplace names loaded from a non-allowed root.
  if ((Test-BundledMarketplaceLoadedWithCodexCli) -eq $false) {
    throw 'codex-cli does not load the openai-bundled marketplace from the configured source'
  }
}

function Test-NodeReplTrustedPathRepair {
  param(
    [string]$ConfigPath,
    [string]$MarketplaceRoot,
    [string]$InstalledMarketplaceRoot,
    [string]$CodexHomeResolved
  )

  $trustedRoots = @(Get-NodeReplTrustedRoots $MarketplaceRoot)
  if ($trustedRoots.Count -eq 0) {
    return
  }

  $configContent = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  $configMatch = [regex]::Match($configContent, '(?m)^\s*NODE_REPL_TRUSTED_CODE_PATHS\s*=\s*[''"](?<value>[^''"]*)[''"]\s*$')
  if (-not $configMatch.Success) {
    throw 'config.toml is missing mcp_servers.node_repl.env.NODE_REPL_TRUSTED_CODE_PATHS'
  }
  $configRoots = @($configMatch.Groups['value'].Value -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $userRoots = @(([Environment]::GetEnvironmentVariable('NODE_REPL_TRUSTED_CODE_PATHS', 'User')) -split ';' |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

  foreach ($root in $trustedRoots) {
    if (-not ($configRoots | Where-Object { $_.TrimEnd('\') -ieq $root.TrimEnd('\') })) {
      throw "config.toml Node REPL trusted paths do not include the stable physical root: $root"
    }
    if (-not ($userRoots | Where-Object { $_.TrimEnd('\') -ieq $root.TrimEnd('\') })) {
      throw "user NODE_REPL_TRUSTED_CODE_PATHS does not include the stable physical root: $root"
    }
  }

  $codexHomePrefix = [System.IO.Path]::GetFullPath($CodexHomeResolved).TrimEnd('\') + '\'
  $externalRoots = @($trustedRoots | Where-Object {
      -not ([System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\').StartsWith(
        $codexHomePrefix,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    })
  if ($externalRoots.Count -gt 0) {
    $resourcesRoot = Split-Path -Parent (Split-Path -Parent $InstalledMarketplaceRoot)
    $asarPath = Join-Path $resourcesRoot 'app.asar'
    if (-not (Test-Path -LiteralPath $asarPath -PathType Leaf)) {
      throw "installed app.asar is missing: $asarPath"
    }
    if (-not (Test-FileContainsAsciiText $asarPath 'CODEX_NODE_REPL_TRUSTED_PATHS_V1')) {
      throw 'installed app.asar does not preserve external NODE_REPL_TRUSTED_CODE_PATHS across Desktop config regeneration'
    }
  }

  Write-Log "Node REPL trusted physical roots verification ok: $($trustedRoots -join ';')"
}

function Test-HelperTransport {
  param(
    [string]$HelperTransportPath,
    [string]$HelperCommandPath
  )

  $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $node) {
    throw 'node.exe not found; cannot verify local Computer Use helper transport'
  }

  $script = @'
import { pathToFileURL } from "node:url";

const modulePath = process.argv[2];
const mod = await import(pathToFileURL(modulePath).href);
if (typeof mod.WindowsHelperTransport !== "function") {
  throw new Error("WindowsHelperTransport export is missing");
}

const helperCommand = process.argv[3];
const transport = helperCommand
  ? new mod.WindowsHelperTransport({ helperCommand })
  : new mod.WindowsHelperTransport();
try {
  let result;
  let method;
  try {
    method = "list_windows";
    result = await transport.request(method, {});
  } catch (error) {
    if (!/unsupported.*method/i.test(String(error?.message ?? error))) {
      throw error;
    }
    method = "screenInfo";
    result = await transport.request(method, {});
  }
  if (result == null || typeof result !== "object") {
    throw new Error(`invalid ${method} response: ${JSON.stringify(result)}`);
  }
  console.log(JSON.stringify({ ok: true, method, resultType: Array.isArray(result) ? "array" : "object" }));
} finally {
  if (typeof transport.close === "function") {
    await transport.close();
  }
}
'@
  $temp = Join-Path $env:TEMP ('codex-computer-use-verify-' + [guid]::NewGuid().ToString('N') + '.mjs')
  try {
    Write-Utf8NoBom $temp $script
    $output = & $node.Source $temp $HelperTransportPath $HelperCommandPath
    if ($LASTEXITCODE -ne 0) {
      throw "Computer Use helper transport verification failed for $HelperTransportPath"
    }
    if ($output) {
      Write-Log "helper transport ok: $output"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Test-ComputerUseClientImport {
  param([string]$ClientPath)

  $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $node) {
    throw 'node.exe not found; cannot verify Computer Use client import'
  }

  $clientRoot = Split-Path -Parent (Split-Path -Parent $ClientPath)
  $runtimeNodeModules = Join-Path $clientRoot 'node_modules'
  if (-not (Test-Path -LiteralPath $runtimeNodeModules -PathType Container)) {
    $runtimeSkyRoot = Get-CuaSkyRuntimeRoot
    $runtimeNodeModules = Split-Path -Parent (Split-Path -Parent $runtimeSkyRoot)
    if (-not (Test-Path -LiteralPath $runtimeNodeModules -PathType Container)) {
      throw "Unable to locate CUA runtime node_modules for import verification: $runtimeNodeModules"
    }
  }

  $script = @'
import { pathToFileURL } from "node:url";

globalThis.nodeRepl = {
  config: {},
  nativePipe: {},
  env: {
    NODE_REPL_NODE_MODULE_DIRS:
      process.env.NODE_REPL_NODE_MODULE_DIRS ?? process.env.NODE_PATH ?? "",
  },
};

const mod = await import(pathToFileURL(process.argv[2]).href);
if (typeof mod.setupComputerUseRuntime !== "function") {
  throw new Error("setupComputerUseRuntime export is missing");
}
console.log(JSON.stringify({ ok: true, exports: Object.keys(mod).sort() }));
'@
  $temp = Join-Path $env:TEMP ('codex-computer-use-client-import-' + [guid]::NewGuid().ToString('N') + '.mjs')
  $tempClient = Join-Path $env:TEMP ('codex-computer-use-client-copy-' + [guid]::NewGuid().ToString('N') + '.mjs')
  $oldNodePath = [Environment]::GetEnvironmentVariable('NODE_PATH', 'Process')
  $oldNodeReplNodeModuleDirs = [Environment]::GetEnvironmentVariable('NODE_REPL_NODE_MODULE_DIRS', 'Process')
  try {
    Write-Utf8NoBom $temp $script
    Copy-Item -LiteralPath $ClientPath -Destination $tempClient -Force

    # The Codex Node REPL resolves bare packages from runtime search roots, not
    # from the imported plugin file's local node_modules. Verify that shape.
    [Environment]::SetEnvironmentVariable('NODE_PATH', $runtimeNodeModules, 'Process')
    [Environment]::SetEnvironmentVariable('NODE_REPL_NODE_MODULE_DIRS', $runtimeNodeModules, 'Process')
    $output = & $node.Source $temp $tempClient
    if ($LASTEXITCODE -ne 0) {
      throw "Computer Use client import verification failed for $ClientPath"
    }
    if ($output) {
      Write-Log "client import ok: $output"
    }
  } finally {
    if ($null -eq $oldNodePath) {
      Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable('NODE_PATH', $oldNodePath, 'Process')
    }
    if ($null -eq $oldNodeReplNodeModuleDirs) {
      Remove-Item Env:\NODE_REPL_NODE_MODULE_DIRS -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable('NODE_REPL_NODE_MODULE_DIRS', $oldNodeReplNodeModuleDirs, 'Process')
    }
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempClient -Force -ErrorAction SilentlyContinue
  }
}

function Test-ComputerUseRuntimeImport {
  param([string]$SkyRoot)

  $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $node) {
    throw 'node.exe not found; cannot verify the independent Computer Use runtime import'
  }

  $entryPath = Join-Path $SkyRoot 'dist\project\cua\sky_js\src\index.js'
  if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
    throw "independent Computer Use runtime entry is missing: $entryPath"
  }

  # Do not define globalThis.nodeRepl here. sky >= 0.6.24 branches three ways on
  # it: undefined falls back to the standalone create_client(load_options()),
  # which is exactly what an independent runtime import should exercise; defined
  # with an rpc function routes every call over that RPC channel; defined without
  # one throws "sky requires node_repl; configure NODE_REPL_TRUSTED_SERVICES" as
  # soon as a method is touched. The stub removed here was that third shape, so
  # this verification could never pass on 0.6.24. It only mirrored process.env
  # values back, so it carried no information the standalone loader cannot read
  # itself.
  $script = @'
const mod = await import(process.argv[2]);
if (typeof mod.sky !== "object" || mod.sky === null) {
  throw new Error("sky export is missing");
}
if (typeof mod.sky.list_windows !== "function") {
  throw new Error("sky.list_windows export is missing");
}
const windows = await mod.sky.list_windows();
if (!Array.isArray(windows)) {
  throw new Error(`sky.list_windows returned ${typeof windows}`);
}
console.log(JSON.stringify({
  ok: true,
  exports: Object.keys(mod).sort(),
  method: "list_windows",
  resultType: "array",
  count: windows.length,
}));
'@
  $entryUri = ([Uri]$entryPath).AbsoluteUri
  $temp = Join-Path $env:TEMP ('codex-computer-use-runtime-import-' + [guid]::NewGuid().ToString('N') + '.mjs')
  try {
    Write-Utf8NoBom $temp $script
    $output = & $node.Source $temp $entryUri
    if ($LASTEXITCODE -ne 0) {
      throw "independent Computer Use runtime import verification failed for $entryPath"
    }
    if ($output) {
      Write-Log "runtime import ok: $output"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Test-OfficialComputerUseCache {
  param(
    [string]$CodexHomeResolved,
    [string]$InstalledMarketplaceRoot
  )

  $sourceRoot = Join-Path $InstalledMarketplaceRoot 'plugins\computer-use'
  $version = Get-PluginVersion $sourceRoot
  $cacheVersionRoot = Join-Path $CodexHomeResolved "plugins\cache\openai-bundled\computer-use\$version"
  $runtimeSkyRoot = Get-CuaSkyRuntimeRoot
  $skillDocumentationProfile = Get-ComputerUseSkillDocumentationProfile $runtimeSkyRoot
  $sourceClientPath = Join-Path $sourceRoot 'scripts\computer-use-client.mjs'
  $cachedClientPath = Join-Path $cacheVersionRoot 'scripts\computer-use-client.mjs'
  $requiredCachePaths = @(
    (Join-Path $cacheVersionRoot '.codex-plugin\plugin.json')
  )
  if (Test-Path -LiteralPath $sourceClientPath -PathType Leaf) {
    $requiredCachePaths += $cachedClientPath
  }
  foreach ($path in $requiredCachePaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "official Computer Use cache is incomplete: $path"
    }
  }

  $mismatches = @()
  foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File)) {
    $relativePath = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
    if ($skillDocumentationProfile -and $relativePath -ieq 'skills\computer-use\SKILL.md') {
      # The local cache deliberately overlays this one stale upstream document.
      continue
    }
    $cacheFile = Join-Path $cacheVersionRoot $relativePath
    if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
      $mismatches += "missing:$relativePath"
      continue
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
    $cacheHash = (Get-FileHash -LiteralPath $cacheFile -Algorithm SHA256).Hash
    if ($sourceHash -ne $cacheHash) {
      $mismatches += "changed:$relativePath"
    }
  }
  if ($mismatches.Count -gt 0) {
    throw "official Computer Use cache differs from the installed package: $($mismatches -join ', ')"
  }

  $runtimeHelperTransportPath = Join-Path $runtimeSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  $runtimeRequired = @(
    (Join-Path $runtimeSkyRoot 'package.json'),
    (Join-Path $runtimeSkyRoot 'dist\project\cua\sky_js\src\index.js'),
    $runtimeHelperTransportPath
  )
  if (Test-Path -LiteralPath $sourceClientPath -PathType Leaf) {
    $runtimeRequired += @(
      (Join-Path $runtimeSkyRoot 'bin\windows\codex-computer-use.exe'),
      (Join-Path $runtimeSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.js'),
      (Join-Path $runtimeSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')
    )
  }
  foreach ($path in $runtimeRequired) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "official Computer Use runtime is incomplete: $path"
    }
  }

  Test-ComputerUseNodeReplContextPatch $runtimeHelperTransportPath

  if (Test-Path -LiteralPath $sourceClientPath -PathType Leaf) {
    $helperCommandPath = Join-Path $runtimeSkyRoot 'bin\windows\codex-computer-use.exe'
    $helperTransportPath = Join-Path $runtimeSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
    Test-ComputerUseClientImport $cachedClientPath
    Test-HelperTransport $helperTransportPath $helperCommandPath
  } else {
    Test-ComputerUseRuntimeImport $runtimeSkyRoot
  }

  $stableMarketplaceRoot = Get-StableBundledMarketplaceRoot $codexHomeResolved
  Test-ComputerUseSkillDocumentation (Join-Path $stableMarketplaceRoot 'plugins\computer-use\skills\computer-use\SKILL.md') $runtimeSkyRoot
  Test-ComputerUseSkillDocumentation (Join-Path $cacheVersionRoot 'skills\computer-use\SKILL.md') $runtimeSkyRoot
  $installedChromeRoot = Join-Path $InstalledMarketplaceRoot 'plugins\chrome'
  $chromeVersion = Get-PluginVersion $installedChromeRoot
  $trustedChromeBrowserClient = Get-InstalledChromeBrowserClientTrust $InstalledMarketplaceRoot
  $chromeBrowserClientPaths = @(
    (Join-Path $stableMarketplaceRoot 'plugins\chrome\scripts\browser-client.mjs'),
    (Join-Path $codexHomeResolved "plugins\cache\openai-bundled\chrome\$chromeVersion\scripts\browser-client.mjs")
  )
  foreach ($browserClientPath in $chromeBrowserClientPaths) {
    Assert-ChromeBrowserClientTrustedBytes $browserClientPath $trustedChromeBrowserClient
  }
  Write-Log "official lightweight cache verification ok: computer-use@$version / runtime=$runtimeSkyRoot / chrome-browser-client=$($trustedChromeBrowserClient.Sha256) / trust=$($trustedChromeBrowserClient.TrustMode)"
}

function Install-ComputerUse {
  $codexHomeResolved = Resolve-OrCreateDirectory $CodexHome
  $marketplaceRoot = Get-StableBundledMarketplaceRoot $codexHomeResolved
  $pluginSourceRoot = Join-Path $marketplaceRoot 'plugins\computer-use'
  $cacheRoot = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use'
  $latestPath = Join-Path $cacheRoot 'latest'

  Resolve-OrCreateDirectory $marketplaceRoot | Out-Null
  Resolve-OrCreateDirectory $cacheRoot | Out-Null
  Assert-UnderPath $pluginSourceRoot $marketplaceRoot
  Assert-UnderPath $latestPath $cacheRoot

  Remove-StaleChromeNativeHostEntries
  $installedMarketplaceRoot = Get-InstalledBundledMarketplaceRoot
  $trustedChromeBrowserClient = Get-InstalledChromeBrowserClientTrust $installedMarketplaceRoot
  Sync-BundledMarketplaceFromInstalledApp $marketplaceRoot $installedMarketplaceRoot
  Repair-ComputerUseNodeReplContext
  Patch-ChromeWindowsRegistryParsing (Join-Path $marketplaceRoot 'plugins\chrome') $trustedChromeBrowserClient
  Write-PluginTree $pluginSourceRoot
  Update-BundledMarketplaceManifest $marketplaceRoot
  Update-CodexConfig $marketplaceRoot
  Enable-UserEnvironment $marketplaceRoot

  $computerUseCacheRoot = Sync-OpenAiBundledPluginCache $installedMarketplaceRoot 'computer-use'
  Write-PluginTree $computerUseCacheRoot
  $browserCacheRoot = Sync-OpenAiBundledPluginCache $installedMarketplaceRoot 'browser'
  Stop-OpenAiBundledExtensionHosts @(
    (Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\chrome'),
    (Join-Path (Split-Path -Parent $marketplaceRoot) 'openai-bundled-cache\chrome')
  )
  $chromeCacheRoot = Sync-OpenAiBundledPluginCache $installedMarketplaceRoot 'chrome'
  Patch-ChromeWindowsRegistryParsing $chromeCacheRoot $trustedChromeBrowserClient
  $sitesInstalled = Test-BundledMarketplacePluginInstalledWithCodexCli 'sites'
  if ($sitesInstalled -and (Test-BundledMarketplacePluginAvailable $installedMarketplaceRoot 'sites')) {
    $sitesCacheRoot = Sync-OpenAiBundledPluginCache $installedMarketplaceRoot 'sites'
    Write-Log "refreshed existing optional plugin cache: $sitesCacheRoot"
  }

  $runtimeInventory = Get-CurrentCodexAppServerRuntimeInventory
  Invoke-ChromeOfficialManifestInstall $chromeCacheRoot $runtimeInventory
  Update-ChromeNativeHostV2State $chromeCacheRoot $runtimeInventory $codexHomeResolved

  # Desktop can reconcile the mutable mirror while caches are being copied.
  # Re-merge shipped descriptors immediately before final verification.
  Update-BundledMarketplaceManifest $marketplaceRoot
  Update-CodexConfig $marketplaceRoot

  # A cache plus a hand-written enabled entry is not an installed plugin to the
  # current CLI. Browser is part of this repair; unrelated optional plugins keep
  # their existing installed/enabled state.
  Install-BundledMarketplacePluginWithCodexCli 'browser'
  Update-CodexConfig $marketplaceRoot

  Write-Log "installed marketplace plugin: $pluginSourceRoot"
  Write-Log "installed cached plugin: $computerUseCacheRoot"
  Write-Log "updated latest junction: $latestPath"
}

function Test-ComputerUse {
  $codexHomeResolved = Resolve-ExistingDirectory $CodexHome
  $installedMarketplaceRoot = Get-InstalledBundledMarketplaceRoot
  $installedChromeRoot = Join-Path $installedMarketplaceRoot 'plugins\chrome'
  $installedChromeVersion = Get-PluginVersion $installedChromeRoot
  $installedChromeCacheRoot = Join-Path $codexHomeResolved "plugins\cache\openai-bundled\chrome\$installedChromeVersion"
  $runtimeInventory = Get-CurrentCodexAppServerRuntimeInventory
  Test-ChromeNativeMessagingManifest $installedChromeCacheRoot
  Test-ChromeAppServerHostConfig $installedChromeCacheRoot $runtimeInventory
  Test-ChromeNativeHostV2State $installedChromeCacheRoot $runtimeInventory $codexHomeResolved
  if ($VerifyAllBundledPluginsAvailable) {
    $stableMarketplaceRoot = Get-StableBundledMarketplaceRoot $codexHomeResolved
    Test-AllBundledMarketplacePluginsAvailableWithCodexCli $stableMarketplaceRoot $installedMarketplaceRoot
  }
  $officialCacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use\latest'
  $legacyLatestMarkers = @(
    (Join-Path $officialCacheLatest '.codex-plugin\plugin.json'),
    (Join-Path $officialCacheLatest 'node_modules\@oai\sky\package.json')
  )
  $hasLegacyLatestLayout = $true
  foreach ($marker in $legacyLatestMarkers) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
      $hasLegacyLatestLayout = $false
      break
    }
  }
  if (-not $hasLegacyLatestLayout) {
    # Current Codex builds can install a lightweight versioned plugin cache and
    # keep @oai/sky in the independent cua_node runtime. In that supported
    # layout `latest` can be absent or stale and has no usable node_modules.
    Test-OfficialComputerUseCache $codexHomeResolved $installedMarketplaceRoot
    $marketplaceRoot = Get-StableBundledMarketplaceRoot $codexHomeResolved
    Test-NodeReplTrustedPathRepair `
      (Join-Path $codexHomeResolved 'config.toml') `
      $marketplaceRoot `
      $installedMarketplaceRoot `
      $codexHomeResolved
    Write-Log 'verification ok'
    return
  }

  $marketplaceRoot = Get-StableBundledMarketplaceRoot $codexHomeResolved
  $manifestPath = Join-Path $marketplaceRoot '.agents\plugins\marketplace.json'
  $cacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use\latest'
  $browserPluginRoot = Join-Path $marketplaceRoot 'plugins\browser'
  $chromePluginRoot = Join-Path $marketplaceRoot 'plugins\chrome'
  $sitesPluginRoot = Join-Path $marketplaceRoot 'plugins\sites'
  $sitesInstalled = (Test-BundledMarketplacePluginAvailable $marketplaceRoot 'sites') -and
    (Test-BundledMarketplacePluginInstalledWithCodexCli 'sites')
  $browserVersion = Get-PluginVersion $browserPluginRoot
  $chromeVersion = Get-PluginVersion $chromePluginRoot
  $browserCacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\browser\latest'
  $chromeCacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\chrome\latest'
  $browserCacheVersionRoot = Join-Path $codexHomeResolved "plugins\cache\openai-bundled\browser\$browserVersion"
  $chromeCacheVersionRoot = Join-Path $codexHomeResolved "plugins\cache\openai-bundled\chrome\$chromeVersion"
  $sitesCacheLatest = $null
  $sitesCacheVersionRoot = $null
  if ($sitesInstalled) {
    $sitesVersion = Get-PluginVersion $sitesPluginRoot
    $sitesCacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\sites\latest'
    $sitesCacheVersionRoot = Join-Path $codexHomeResolved "plugins\cache\openai-bundled\sites\$sitesVersion"
  }
  $chromeHostPath = Join-Path $chromeCacheVersionRoot 'extension-host\windows\x64\extension-host.exe'
  $marketplaceBrowserClientPath = Join-Path $chromePluginRoot 'scripts\browser-client.mjs'
  $cachedBrowserClientPath = Join-Path $chromeCacheVersionRoot 'scripts\browser-client.mjs'
  $computerUseClientPath = Join-Path $cacheLatest 'scripts\computer-use-client.mjs'
  $runtimeSkyRoot = Get-CuaSkyRuntimeRoot
  $computerUseBasePath = Join-Path $cacheLatest 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.js'
  $helperTransportPath = Join-Path $cacheLatest 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  $required = @(
    $manifestPath,
    (Join-Path $marketplaceRoot 'plugins\computer-use\.codex-plugin\plugin.json'),
    (Join-Path $marketplaceRoot 'plugins\computer-use\scripts\computer-use-client.mjs'),
    (Join-Path $browserPluginRoot '.codex-plugin\plugin.json'),
    (Join-Path $chromePluginRoot '.codex-plugin\plugin.json'),
    (Join-Path $cacheLatest '.codex-plugin\plugin.json'),
    $computerUseClientPath,
    (Join-Path $browserCacheVersionRoot '.codex-plugin\plugin.json'),
    (Join-Path $chromeCacheVersionRoot '.codex-plugin\plugin.json'),
    $chromeHostPath,
    $marketplaceBrowserClientPath,
    $cachedBrowserClientPath,
    (Join-Path $cacheLatest 'node_modules\@oai\sky\package.json'),
    (Join-Path $cacheLatest 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'),
    $computerUseBasePath,
    $helperTransportPath
  )
  if ($sitesInstalled) {
    $required += @(
      (Join-Path $sitesPluginRoot '.codex-plugin\plugin.json'),
      (Join-Path $sitesCacheVersionRoot '.codex-plugin\plugin.json'),
      $sitesCacheLatest
    )
  }

  foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "missing required Computer Use path: $path"
    }
  }

  $trustedChromeBrowserClient = Get-InstalledChromeBrowserClientTrust $installedMarketplaceRoot
  foreach ($browserClientPath in @($marketplaceBrowserClientPath, $cachedBrowserClientPath)) {
    Assert-ChromeBrowserClientTrustedBytes $browserClientPath $trustedChromeBrowserClient
  }

  $cachedChromeScriptRoot = Join-Path $chromeCacheVersionRoot 'scripts'
  $chromeParserChecks = @(
    [pscustomobject]@{ Path = (Join-Path $cachedChromeScriptRoot 'open-chrome-window.js'); Marker = 'valueName == null || match[1] === label' },
    [pscustomobject]@{ Path = (Join-Path $cachedChromeScriptRoot 'installed-browsers.js'); Marker = 'valueName == null || match[1] === label' },
    [pscustomobject]@{ Path = (Join-Path $cachedChromeScriptRoot 'check-native-host-manifest.js'); Marker = 'valueName === "(Default)" || match[1] === valueName' }
  )
  foreach ($check in $chromeParserChecks) {
    if (-not (Test-Path -LiteralPath $check.Path -PathType Leaf)) {
      throw "missing Chrome registry helper: $($check.Path)"
    }
    $content = [System.IO.File]::ReadAllText($check.Path, [System.Text.UTF8Encoding]::new($false))
    if (-not $content.Contains($check.Marker)) {
      throw "Chrome localized registry parsing patch is missing: $($check.Path)"
    }
  }

  $latestPathsToCheck = @($cacheLatest)
  foreach ($optionalLatestPath in @($browserCacheLatest, $chromeCacheLatest)) {
    if (Test-Path -LiteralPath $optionalLatestPath) {
      $latestPathsToCheck += $optionalLatestPath
    } else {
      Write-Log "bundled plugin latest junction not present; verified versioned cache fallback: $optionalLatestPath"
    }
  }
  if ($sitesInstalled) {
    $latestPathsToCheck += $sitesCacheLatest
  }

  foreach ($latestPath in $latestPathsToCheck) {
    $item = Get-Item -LiteralPath $latestPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
      throw "bundled plugin latest path is not a junction: $latestPath"
    }
    $target = [string]($item.Target -join ';')
    if ($target.StartsWith($marketplaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "bundled plugin latest junction points at mutable marketplace mirror: $latestPath -> $target"
    }
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $entry = @($manifest.plugins | Where-Object { $_.name -eq 'computer-use' }) | Select-Object -First 1
  if (-not $entry) {
    throw 'computer-use is missing from openai-bundled marketplace manifest'
  }
  if ($entry.source.source -ne 'local' -or $entry.source.path -ne './plugins/computer-use') {
    throw 'computer-use marketplace entry does not point to ./plugins/computer-use'
  }

  Test-BundledMarketplaceMirror $marketplaceRoot
  Test-ComputerUseSkillDocumentation (Join-Path $marketplaceRoot 'plugins\computer-use\skills\computer-use\SKILL.md') $runtimeSkyRoot
  Test-ComputerUseSkillDocumentation (Join-Path $cacheLatest 'skills\computer-use\SKILL.md') $runtimeSkyRoot

  $userEnv = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', 'User')
  if ($userEnv -ne '1') {
    throw 'CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE is not enabled for the current user'
  }

  $detectedChromeUserDataDirectory = Get-ChromeUserDataDirectoryOverride
  if (-not $detectedChromeUserDataDirectory) {
    throw 'Chrome user data directory could not be detected'
  }
  $userChromeUserDataDirectory = [Environment]::GetEnvironmentVariable('CODEX_CHROME_USER_DATA_DIR', 'User')
  if ($userChromeUserDataDirectory -ine $detectedChromeUserDataDirectory) {
    throw "CODEX_CHROME_USER_DATA_DIR does not match the detected Chrome profile root: $detectedChromeUserDataDirectory"
  }

  Test-CodexConfig (Join-Path $codexHomeResolved 'config.toml') $marketplaceRoot
  Test-NodeReplTrustedPathRepair `
    (Join-Path $codexHomeResolved 'config.toml') `
    $marketplaceRoot `
    $installedMarketplaceRoot `
    $codexHomeResolved
  Test-ComputerUseClientImport $computerUseClientPath
  Test-HelperTransport $helperTransportPath
  Test-ComputerUseNodeReplContextPatch $helperTransportPath
  Write-Log 'verification ok'
}

if ($StrictVerifyOnly) {
  Test-ComputerUse
  exit 0
}

if ($VerifyOnly) {
  try {
    Test-ComputerUse
    exit 0
  } catch {
    Write-Log "verification failed: $($_.Exception.Message)"
    Write-Log 'repairing local Computer Use plugin and retrying verification'
    Install-ComputerUse
    Test-ComputerUse
    exit 0
  }
}

Install-ComputerUse
Test-ComputerUse
