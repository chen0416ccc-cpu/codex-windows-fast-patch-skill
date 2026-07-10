[CmdletBinding()]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$PluginVersion = '0.1.0-local',
  [switch]$VerifyOnly,
  [switch]$StrictVerifyOnly,
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

function Copy-DirectoryDataOnly {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "copy source directory not found: $Source"
  }

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
}

function Copy-DirectoryMissingOnly {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "copy source directory not found: $Source"
  }

  Resolve-OrCreateDirectory $Destination | Out-Null
  $sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath
  $destinationRoot = (Resolve-Path -LiteralPath $Destination).ProviderPath

  $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($robocopy) {
    & $robocopy.Source $sourceRoot $destinationRoot /E /XC /XN /XO /R:0 /W:0 /NFL /NDL /NP | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
      throw "robocopy missing-only overlay failed with exit code $exitCode"
    }
    return
  }

  foreach ($dir in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory -Force) {
    $relative = $dir.FullName.Substring($sourceRoot.Length).TrimStart('\')
    Resolve-OrCreateDirectory (Join-Path $destinationRoot $relative) | Out-Null
  }

  foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $target = Join-Path $destinationRoot $relative
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
      $targetParent = Split-Path -Parent $target
      Resolve-OrCreateDirectory $targetParent | Out-Null
      [System.IO.Directory]::CreateDirectory($targetParent) | Out-Null
      [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($file.FullName))
      [System.IO.File]::SetLastWriteTime($target, $file.LastWriteTime)
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

function Enable-UserEnvironment {
  if ($SkipUserEnvironment) {
    Write-Log 'skipping user environment update'
    return
  }

  [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', '1', 'User')
  $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = '1'

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

function Normalize-SkyDistPnpmImportPaths {
  param([string]$DistPath)

  if (-not (Test-Path -LiteralPath $DistPath -PathType Container)) {
    return
  }

  $pattern = '(/\.pnpm/)([^/]+)(/node_modules/)'
  $changedFiles = 0
  foreach ($file in (Get-ChildItem -LiteralPath $DistPath -Recurse -File -Include *.js,*.mjs -ErrorAction SilentlyContinue)) {
    $before = [System.IO.File]::ReadAllText($file.FullName)
    $after = [regex]::Replace($before, $pattern, {
        param($match)
        $segment = [string]$match.Groups[2].Value
        if (-not $segment.Contains('@')) {
          return $match.Value
        }
        return $match.Groups[1].Value + ($segment -replace '@', '%40') + $match.Groups[3].Value
      })
    if ($after -ne $before) {
      Write-Utf8NoBom $file.FullName $after
      $changedFiles += 1
    }
  }

  if ($changedFiles -gt 0) {
    Write-Log "normalized encoded .pnpm import paths in Computer Use runtime dist: $changedFiles file(s)"
  }
}

function Ensure-SkyDistPnpmDirectoryAliases {
  param([string]$DistPath)

  $pnpmRoot = Join-Path $DistPath 'node_modules\.pnpm'
  if (-not (Test-Path -LiteralPath $pnpmRoot -PathType Container)) {
    return
  }

  $aliasCount = 0
  foreach ($entry in (Get-ChildItem -LiteralPath $pnpmRoot -Directory -Force -ErrorAction SilentlyContinue)) {
    if (-not $entry.Name.Contains('%40')) {
      continue
    }

    $aliasName = $entry.Name -replace '%40', '@'
    if ($aliasName -eq $entry.Name) {
      continue
    }

    $aliasPath = Join-Path $pnpmRoot $aliasName
    if (Test-Path -LiteralPath $aliasPath) {
      $aliasItem = Get-Item -LiteralPath $aliasPath -Force
      if (($aliasItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        $existingChildren = @(Get-ChildItem -LiteralPath $aliasPath -Force -ErrorAction SilentlyContinue)
        if ($existingChildren.Count -gt 0) {
          continue
        }
      } else {
        continue
      }
    }

    Copy-DirectoryDataOnly $entry.FullName $aliasPath
    $aliasCount += 1
  }

  if ($aliasCount -gt 0) {
    Write-Log "created decoded .pnpm directory mirrors for Computer Use runtime dist: $aliasCount alias(es)"
  }
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
  if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
    throw "installed Computer Use client script is missing: $clientPath"
  }
  Patch-ComputerUseClientScript $clientPath

  Resolve-OrCreateDirectory $skyRoot | Out-Null
  if (Test-Path -LiteralPath $distPath) {
    Remove-ReparsePointOrDirectory $distPath
  }
  Copy-DirectoryDataOnly $runtimeDistPath $distPath
  Normalize-SkyDistPnpmImportPaths $distPath
  Ensure-SkyDistPnpmDirectoryAliases $distPath

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
  $json.plugins = @($entry) + $plugins
  ConvertTo-JsonFile $manifestPath $json
}

function Update-CodexConfig {
  param([string]$MarketplaceRoot)

  $configPath = Join-Path $CodexHome 'config.toml'
  $source = '\\?\' + $MarketplaceRoot
  Set-TomlTable $configPath '[marketplaces.openai-bundled]' @{
    last_updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = $source
    source_type = 'local'
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
  Remove-TomlTableKeys $configPath '[mcp_servers.node_repl.env]' @(
    'SKY_CUA_NATIVE_PIPE',
    'SKY_CUA_NATIVE_PIPE_DIRECTORY'
  ) 'remove-stale-computer-use-pipe-env'
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
  $skyRelativeRoots = @(
    'bin\node_modules\@oai\sky',
    'bin\node_modules\%40oai\sky'
  )

  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $candidates += foreach ($runtime in (Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue)) {
      foreach ($relativeRoot in $skyRelativeRoots) {
        $skyRoot = Join-Path $runtime.FullName $relativeRoot
        $basePath = Join-Path $skyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.js'
        $packagePath = Join-Path $skyRoot 'package.json'
        if ((Test-Path -LiteralPath $basePath -PathType Leaf) -and (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
          $packageItem = Get-Item -LiteralPath $packagePath
          [pscustomobject]@{
            Path = $skyRoot
            LastWriteTime = $packageItem.LastWriteTime
          }
        }
      }
    }
  }

  $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if ($pkg) {
    foreach ($relativeRoot in @(
      'app\resources\cua_node\bin\node_modules\@oai\sky',
      'app\resources\cua_node\bin\node_modules\%40oai\sky'
    )) {
      $packageSkyRoot = Join-Path $pkg.InstallLocation $relativeRoot
      $packageBasePath = Join-Path $packageSkyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.js'
      $packagePath = Join-Path $packageSkyRoot 'package.json'
      if ((Test-Path -LiteralPath $packageBasePath -PathType Leaf) -and (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        $packageItem = Get-Item -LiteralPath $packagePath
        $candidates += [pscustomobject]@{
          Path = $packageSkyRoot
          LastWriteTime = $packageItem.LastWriteTime
        }
      }
    }
  }

  $selected = @($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($selected.Count -eq 0) {
    throw "no usable Codex CUA @oai/sky runtime was found under $runtimeRoot or the installed Codex package"
  }

  return $selected[0].Path
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

  $stopped = 0
  foreach ($process in (Get-Process -Name 'extension-host' -ErrorAction SilentlyContinue)) {
    $processPath = $null
    try {
      $processPath = $process.Path
    } catch {
      continue
    }
    if ([string]::IsNullOrWhiteSpace($processPath)) {
      continue
    }

    foreach ($rootPath in $resolvedRoots) {
      if ($processPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "stopping bundled plugin lock holder: extension-host pid=$($process.Id)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $stopped += 1
        break
      }
    }
  }

  if ($stopped -gt 0) {
    Start-Sleep -Seconds 2
  }
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
  $useMissingOnlyOverlay = $false
  if (Test-Path -LiteralPath $cacheVersionRoot) {
    try {
      Remove-ReparsePointOrDirectory $cacheVersionRoot
    } catch {
      $useMissingOnlyOverlay = $true
      Write-Log "warning: bundled plugin cache is locked; overlaying missing files only: $cacheVersionRoot"
      Write-Log "warning: cache delete failure: $($_.Exception.Message)"
    }
  }

  if ($useMissingOnlyOverlay) {
    Copy-DirectoryMissingOnly $sourcePluginRoot $cacheVersionRoot
  } else {
    Copy-DirectoryDataOnly $sourcePluginRoot $cacheVersionRoot
  }

  if (Test-Path -LiteralPath $latestPath) {
    Remove-ReparsePointOrDirectory $latestPath
  }
  New-Item -ItemType Junction -Path $latestPath -Target $cacheVersionRoot | Out-Null
  Write-Log "updated bundled plugin latest junction: $latestPath -> $cacheVersionRoot"

  return $cacheVersionRoot
}

function Update-ChromeNativeMessagingManifest {
  param([string]$ChromeCacheRoot)

  $hostExe = Join-Path $ChromeCacheRoot 'extension-host\windows\x64\extension-host.exe'
  if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) {
    throw "missing Chrome extension host executable: $hostExe"
  }

  $manifestPath = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $json = [PSCustomObject]@{
      allowed_origins = @('chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/')
      description = 'Codex chrome native messaging host'
      name = 'com.openai.codexextension'
      path = $hostExe
      type = 'stdio'
    }
    ConvertTo-JsonFile $manifestPath $json
    & reg.exe add 'HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension' /ve /t REG_SZ /d $manifestPath /f | Out-Null
    Write-Log "created Chrome native messaging manifest: $manifestPath"
    return
  }

  try {
    $json = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  } catch {
    Write-Log "warning: failed to parse Chrome native messaging manifest: $($_.Exception.Message)"
    return
  }

  if ([string]$json.path -eq $hostExe) {
    return
  }

  $backupPath = "$manifestPath.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').bak"
  Copy-Item -LiteralPath $manifestPath -Destination $backupPath -Force
  $json.path = $hostExe
  ConvertTo-JsonFile $manifestPath $json
  & reg.exe add 'HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension' /ve /t REG_SZ /d $manifestPath /f | Out-Null
  Write-Log "updated Chrome native messaging manifest: $manifestPath"
  Write-Log "Chrome native messaging manifest backup: $backupPath"
}

function Sync-BundledMarketplaceFromInstalledApp {
  param([string]$MarketplaceRoot)

  $sourceRoot = Get-InstalledBundledMarketplaceRoot
  $parent = Split-Path -Parent $MarketplaceRoot
  Resolve-OrCreateDirectory $parent | Out-Null
  Assert-UnderPath $MarketplaceRoot $parent
  Stop-OpenAiBundledExtensionHosts @(
    $MarketplaceRoot,
    (Join-Path $CodexHome 'plugins\cache\openai-bundled')
  )

  Write-Log "syncing installed openai-bundled marketplace: $sourceRoot -> $MarketplaceRoot"
  Copy-DirectoryDataOnly $sourceRoot $MarketplaceRoot
}

function Test-BundledMarketplaceMirror {
  param(
    [string]$MarketplaceRoot,
    [string[]]$RequiredPluginNames = @()
  )

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

  $requiredNameSet = @{}
  foreach ($requiredName in @($RequiredPluginNames)) {
    if (-not [string]::IsNullOrWhiteSpace($requiredName)) {
      $requiredNameSet[[string]$requiredName] = $true
    }
  }

  foreach ($sourceEntry in @($sourceManifest.plugins)) {
    $name = [string]$sourceEntry.name
    if ($requiredNameSet.Count -gt 0 -and -not $requiredNameSet.ContainsKey($name)) {
      continue
    }
    if (-not $localEntries.ContainsKey($name)) {
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
    if ($content -match '(?m)^\s*SKY_CUA_NATIVE_PIPE(?:_DIRECTORY)?\s*=') {
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
expected_source = sys.argv[2]
data = tomllib.loads(config_path.read_text(encoding="utf-8"))
errors = []

marketplace = data.get("marketplaces", {}).get("openai-bundled")
if not isinstance(marketplace, dict):
    errors.append("missing [marketplaces.openai-bundled]")
else:
    if marketplace.get("source_type") != "local":
        errors.append("marketplaces.openai-bundled.source_type must be local")
    if marketplace.get("source") != expected_source:
        errors.append("marketplaces.openai-bundled.source does not point at the local bundled marketplace")

plugins = data.get("plugins", {})
plugin = plugins.get("computer-use@openai-bundled")
if not isinstance(plugin, dict):
    errors.append('missing [plugins."computer-use@openai-bundled"]')
elif plugin.get("enabled") is not True:
    errors.append('plugins."computer-use@openai-bundled".enabled must be true')

for plugin_id in ("browser@openai-bundled", "chrome@openai-bundled"):
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
    for key in ("SKY_CUA_NATIVE_PIPE", "SKY_CUA_NATIVE_PIPE_DIRECTORY"):
        if key in node_repl_env:
            errors.append(f"remove stale mcp_servers.node_repl.env.{key}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
'@
  $temp = Join-Path $env:TEMP ('codex-config-validate-' + [guid]::NewGuid().ToString('N') + '.py')
  try {
    Write-Utf8NoBom $temp $script
    & $python.Source $temp $ConfigPath $expectedSource
    if ($LASTEXITCODE -ne 0) {
      throw "semantic config validation failed for $ConfigPath"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Test-HelperTransport {
  param([string]$HelperTransportPath)

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

const transport = new mod.WindowsHelperTransport();
try {
  const info = await transport.request("screenInfo", {});
  if (!info || typeof info.width !== "number" || typeof info.height !== "number" || info.width <= 0 || info.height <= 0) {
    throw new Error(`invalid screenInfo response: ${JSON.stringify(info)}`);
  }

  const screenshot = await transport.request("screenshot", {});
  if (!screenshot || screenshot.mimeType !== "image/png" || typeof screenshot.data !== "string" || screenshot.data.length < 100) {
    throw new Error("invalid screenshot response");
  }

  console.log(JSON.stringify({ ok: true, width: info.width, height: info.height, screenshotBytesApprox: Math.floor(screenshot.data.length * 3 / 4) }));
} finally {
  if (typeof transport.close === "function") {
    await transport.close();
  }
}
'@
  $temp = Join-Path $env:TEMP ('codex-computer-use-verify-' + [guid]::NewGuid().ToString('N') + '.mjs')
  try {
    Write-Utf8NoBom $temp $script
    $output = & $node.Source $temp $HelperTransportPath
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

function Install-ComputerUse {
  $codexHomeResolved = Resolve-OrCreateDirectory $CodexHome
  $marketplaceRoot = Join-Path $codexHomeResolved '.tmp\bundled-marketplaces\openai-bundled'
  $pluginSourceRoot = Join-Path $marketplaceRoot 'plugins\computer-use'
  $cacheRoot = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use'
  $latestPath = Join-Path $cacheRoot 'latest'

  Resolve-OrCreateDirectory $marketplaceRoot | Out-Null
  Resolve-OrCreateDirectory $cacheRoot | Out-Null
  Assert-UnderPath $pluginSourceRoot $marketplaceRoot
  Assert-UnderPath $latestPath $cacheRoot

  Remove-StaleChromeNativeHostEntries
  Sync-BundledMarketplaceFromInstalledApp $marketplaceRoot
  Write-PluginTree $pluginSourceRoot
  Update-BundledMarketplaceManifest $marketplaceRoot
  Update-CodexConfig $marketplaceRoot
  Enable-UserEnvironment

  $computerUseCacheRoot = Sync-OpenAiBundledPluginCache $marketplaceRoot 'computer-use'
  $browserCacheRoot = Sync-OpenAiBundledPluginCache $marketplaceRoot 'browser'
  $chromeCacheRoot = Sync-OpenAiBundledPluginCache $marketplaceRoot 'chrome'

  Update-ChromeNativeMessagingManifest $chromeCacheRoot

  Write-Log "installed marketplace plugin: $pluginSourceRoot"
  Write-Log "installed cached plugin: $computerUseCacheRoot"
  Write-Log "updated latest junction: $latestPath"
}

function Test-ComputerUse {
  $codexHomeResolved = Resolve-ExistingDirectory $CodexHome
  $marketplaceRoot = Join-Path $codexHomeResolved '.tmp\bundled-marketplaces\openai-bundled'
  $manifestPath = Join-Path $marketplaceRoot '.agents\plugins\marketplace.json'
  $cacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use\latest'
  $browserPluginRoot = Join-Path $marketplaceRoot 'plugins\browser'
  $chromePluginRoot = Join-Path $marketplaceRoot 'plugins\chrome'
  $browserVersion = Get-PluginVersion $browserPluginRoot
  $chromeVersion = Get-PluginVersion $chromePluginRoot
  $browserCacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\browser\latest'
  $chromeCacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\chrome\latest'
  $browserCacheVersionRoot = Join-Path $codexHomeResolved "plugins\cache\openai-bundled\browser\$browserVersion"
  $chromeCacheVersionRoot = Join-Path $codexHomeResolved "plugins\cache\openai-bundled\chrome\$chromeVersion"
  $chromeNativeManifest = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
  $chromeHostPath = Join-Path $chromeCacheVersionRoot 'extension-host\windows\x64\extension-host.exe'
  $chromeLatestHostPath = Join-Path $chromeCacheLatest 'extension-host\windows\x64\extension-host.exe'
  $computerUseClientPath = Join-Path $cacheLatest 'scripts\computer-use-client.mjs'
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
    (Join-Path $cacheLatest 'node_modules\@oai\sky\package.json'),
    (Join-Path $cacheLatest 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'),
    $computerUseBasePath,
    $helperTransportPath
  )

  foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "missing required Computer Use path: $path"
    }
  }

  $latestPathsToCheck = @($cacheLatest)
  foreach ($optionalLatestPath in @($browserCacheLatest, $chromeCacheLatest)) {
    if (Test-Path -LiteralPath $optionalLatestPath) {
      $latestPathsToCheck += $optionalLatestPath
    } else {
      Write-Log "warning: bundled plugin latest junction not present; using versioned cache path: $optionalLatestPath"
    }
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

  if (Test-Path -LiteralPath $chromeNativeManifest -PathType Leaf) {
    $nativeManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $chromeNativeManifest | ConvertFrom-Json
    $acceptableChromeHostPaths = @($chromeHostPath)
    if (Test-Path -LiteralPath $chromeCacheLatest) {
      $acceptableChromeHostPaths += $chromeLatestHostPath
    }
    if ([string]$nativeManifest.path -notin $acceptableChromeHostPaths) {
      throw "Chrome native messaging manifest does not point at stable cache path: $chromeNativeManifest"
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

  Test-BundledMarketplaceMirror $marketplaceRoot @('computer-use', 'browser', 'chrome')

  $userEnv = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', 'User')
  if ($userEnv -ne '1') {
    throw 'CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE is not enabled for the current user'
  }

  Test-CodexConfig (Join-Path $codexHomeResolved 'config.toml') $marketplaceRoot
  Test-ComputerUseClientImport $computerUseClientPath
  Test-HelperTransport $helperTransportPath
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
