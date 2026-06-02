---
name: codex-windows-fast-patch
description: Reapply the Windows Codex Desktop MSIX patch after Store upgrades, including Fast Mode, plugin UI gates, Goal command gates, Windows Computer Use availability gates, ASAR integrity repair, signing/installing the patched package, SDK cleanup, Fast Mode wire verification, and registering the local plugin marketplace openai-curated-local.
---

# Codex Windows Fast Patch

Use this skill when the user says Codex Desktop was upgraded and the Fast Mode / Plugins / Goal patch disappeared, asks to repatch Codex on Windows, asks to verify whether Fast Mode is really being sent, asks to restore/register the local plugin marketplace, or asks to enable Windows Computer Use in Codex Desktop. Also use it when the Computer Control settings page shows "Any App" / "任意应用" as disabled by organization or unavailable in the current region, or when the Connections / Codex mobile remote-control setup flow drops into an auth error loop on Windows.

## Platform Compatibility

This skill is Windows-only. It depends on the Windows Store/MSIX package layout, PowerShell, `Get-AppxPackage`, `makeappx.exe`, `signtool.exe`, Windows user environment variables, and Windows Computer Use helper paths.

Do not run this skill on macOS. A macOS adaptation needs a separate workflow for the Codex `.app` bundle, ASAR extraction and repacking, macOS code signing or quarantine handling, shell scripts, and macOS-specific Computer Use availability.

## Self-Update Preflight

Before doing substantive work with this skill, run the bundled self-update helper once, then reload this `SKILL.md` if it reports an update:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\update-skill-from-github.ps1"
```

The helper checks `chen0416ccc-cpu/codex-windows-fast-patch-skill` on GitHub and synchronizes only the skill allowlist: `SKILL.md`, `agents`, `scripts`, `references`, and `assets`. 如果无法更新到最新版，则不要中断当前任务；继续使用本机已安装的当前版本完成工作，并在结果中说明未能更新。

If the normal workflow does not explain a restriction, plugin gate, Computer Use failure, or Codex mobile entry failure, read `references/restriction-debug-cases.md` before editing scripts or repatching.

## Config Backup Rule

Before any action that can modify, regenerate, or overwrite `$env:USERPROFILE\.codex\config.toml`, create one timestamped backup of the current file for the task. This applies whether the agent uses bundled scripts, writes TOML manually, runs another helper, registers a marketplace, changes MCP servers, or repairs Computer Use.

The bundled scripts already back up an existing `config.toml` once per script run before their first write. If not using those scripts, do the backup explicitly before touching the file:

```powershell
$config = Join-Path $env:USERPROFILE '.codex\config.toml'
if (Test-Path -LiteralPath $config -PathType Leaf) {
  $backupDir = Join-Path (Split-Path -Parent $config) 'backups\config'
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  $backup = Join-Path $backupDir ('config.toml.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.manual.bak')
  Copy-Item -LiteralPath $config -Destination $backup -Force
  Write-Host "config.toml backup before overwrite: $backup"
}
```

Do not proceed with a config write if the backup of an existing config fails. After writing, validate TOML syntax with `tomllib` when Python is available.

## Default Workflow

1. If the task may modify `config.toml`, skills, marketplaces, or MCP server settings, create a state snapshot first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

2. Inspect current package status:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name,PackageFullName,Version,SignatureKind,InstallLocation
```

3. Run a dry run first after every Codex upgrade:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\repatch-codex-windows.ps1" -DryRun
```

4. If the dry run finds all patch targets, run the full repatch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\repatch-codex-windows.ps1"
```

The wrapper calls the bundled patch script at `scripts\patch_codex_fast_mode_windows_msix.ps1` with these defaults:

- `-InstallPrerequisites`
- `-Install`
- `-Launch`
- `-CleanupWindowsSdkAfterInstall`
- `-CleanupAfter`
- `-VerifyFastModeRequest`

It also verifies and writes the local marketplace config at `$env:USERPROFILE\.codex\marketplaces\openai-curated-local`, including `source_type = "local"` and the exact `source` path.
It also syncs the installed `openai-bundled` marketplace from the current Codex package into `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, overlays a local `computer-use@openai-bundled` compatibility plugin, writes that local marketplace into config, and enables `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1` for the current user so the Desktop app can expose Windows Computer Use after restart.
It also patches the Desktop webview gates that otherwise hide or disable Windows Computer Use behind the `computer_use` experimental feature and Statsig gate `1506311413`, and it writes `features.computer_use = true` into `$env:USERPROFILE\.codex\config.toml` without replacing the rest of the `[features]` table.
It also writes `[windows] sandbox = "unelevated"` into `$env:USERPROFILE\.codex\config.toml`. On Windows, this avoids the elevated sandbox setup refresh path that can fail with `spawn setup refresh` / OS error 740 and break Computer Use startup.
It also repairs local marketplace manifest layout when a local root has only a legacy root `marketplace.json`; the current Codex CLI expects `.agents\plugins\marketplace.json`, and missing that file can make `codex plugin list` fail for all configured marketplaces.
It also patches the Codex mobile / remote-control setup flow so a missing ChatGPT Desktop remote-control auth token does not force the settings modal to navigate to `/login` and become hard to exit; the flow falls back to a safe empty state instead. This does not replace real server-side remote-control enrollment when cross-device control is actually required.
Any bundled script write to an existing `config.toml` first creates one timestamped backup for that script run under `.codex\backups\config\`.

## Important Guardrails

- Do not modify `C:\Program Files\WindowsApps` in place. Use the MSIX repack script.
- Do not trust a response like `FAST_CHECK_OK` as proof of Fast Mode. Trust only the wrapper/script wire verification, which captures Codex's `/v1/responses` WebSocket request and checks `service_tier=priority`.
- If the app launches then immediately exits, run Electron logging and check for ASAR integrity failures:

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
$exe = Join-Path $pkg.InstallLocation 'app\Codex.exe'
$env:ELECTRON_ENABLE_LOGGING='1'
Push-Location (Split-Path -Parent $exe)
& $exe --enable-logging=stderr --v=1 2>&1 | Select-String -Pattern 'FATAL|Integrity|asar|ERROR'
Pop-Location
Remove-Item Env:ELECTRON_ENABLE_LOGGING -ErrorAction SilentlyContinue
```

- If `makeappx.exe` or `signtool.exe` is missing, run the wrapper normally; it installs Windows SDK temporarily and removes it afterward.
- If the local marketplace directory is missing, do not invent a marketplace. Report the missing path and ask whether to restore it from backup or re-extract it from a known source.
- For ccswitch-style backup or migration of user-level Codex state, use `scripts\manage-codex-backups.ps1`. It backs up `config.toml`, extracted `mcp_servers.json`, custom skills, marketplaces, and `chrome-native-hosts.json`. It excludes `.git`, `node_modules`, build output, and virtual environments by default; use `-IncludeDependencyDirs` only when an exact offline dependency copy is needed. Plugin cache and `.tmp\bundled-marketplaces` are also opt-in because they can be large.
- If `codex plugin list` fails with `failed to load configured marketplace snapshot(s)` and a local marketplace root contains only `marketplace.json`, copy that manifest to `.agents\plugins\marketplace.json` and re-run `codex plugin list` before diagnosing individual plugins.
- Do not depend on `Downloads\patch_codex_fast_mode_windows_msix.ps1`; the skill is intended to be self-contained. Use `scripts\patch_codex_fast_mode_windows_msix.ps1` unless the user explicitly passes `-PatchScript`.
- If the user's upstream is CPA, verify CPA override rules as part of Fast Mode validation: for the Codex-facing models, force `service_tier` as a string parameter with value `priority`. Local wire capture only proves Codex Desktop sent the field; CPA can still strip, ignore, or fail to apply it unless the override rule is configured.
- In Codex 26.519.11010+, `use-plugin-install-flow-*.js` may no longer contain `featureName:\`computer_use\``. For the Computer Use install-flow gate, locate the file with `installPlugin:async` and `openPluginInstall`, then patch the imported availability tuple so the first `.available` value for Computer Use is forced true.
- Do not modify `C:\Program Files\WindowsApps` in place to enable Computer Use. The Windows gate is controlled by `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`, and the helper paths are supplied through the local `computer-use@openai-bundled` plugin.
- If Computer Use or a `node_repl` Computer Use plugin fails on Windows with `windows sandbox failed: spawn setup refresh`, inspect `$env:USERPROFILE\.codex\.sandbox\sandbox.<date>.log`. If it shows `codex-windows-sandbox-setup.exe` failing with OS error 740, set `[windows] sandbox = "unelevated"`. Check `codex sandbox --help` before verification: if the help lists a `windows` command, verify with `codex sandbox windows "C:\Windows\System32\cmd.exe" /c echo OK`; only builds whose help accepts a direct command form should use `codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK`.
- If "任意应用" is visible but disabled as organization/region unavailable, inspect `webview\assets\use-is-plugins-enabled-*.js` in the extracted ASAR. The relevant local gates are `featureName:\`computer_use\`` and Statsig `1506311413`; reapply the MSIX patch rather than editing WindowsApps in place.
- If the Computer Control page says `Computer Use 插件不可用`, check the Desktop log for `computer-use native pipe startup failed` with `missing-helper-path`, then inspect `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled\.agents\plugins\marketplace.json` and `plugins\computer-use`. If they are missing or partial, stop bundled `extension-host` processes under `$env:USERPROFILE\.codex\plugins\cache\openai-bundled`, rerun `scripts\install-computer-use-local.ps1`, restart Codex Desktop, and confirm the log ends with `computer-use native pipe startup ready`.
- If the failure reappears after fully quitting and reopening Codex Desktop, inspect `$env:USERPROFILE\.codex\chrome-native-hosts.json`. Stale Chrome native-host entries whose `extensionHostPath` or `browserClientPath` no longer exists can make startup reconcile reinstall or tear down bundled plugins and lock `.tmp\bundled-marketplaces\openai-bundled`; rerun `scripts\install-computer-use-local.ps1` to remove stale entries and repair Computer Use.
- If the "Codex mobile" / "Codex 移动版" entry or Connections > Control This Computer > Set up opens then drops back, opens nothing, routes to login, or becomes hard to exit, check the Desktop logs under `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\<year>\<month>\<day>`. `load_remote_control_unauthed` or `refresh_local_remote_control_client_id_failed` with `Sign in to ChatGPT in Codex Desktop` means the local patch should prevent the UI loop, but real cross-device remote-control enrollment still requires a ChatGPT Desktop sign-in, not only an API-key Codex login.

## Useful Wrapper Options

- `-DryRun`: verify bundle targets only; no install.
- `-NoLaunch`: install but do not start Codex Desktop.
- `-SkipFastVerify`: skip the WebSocket `service_tier` capture.
- `-KeepBuild`: keep `Downloads\codex-msix-repack` for debugging.
- `-SkipSdkCleanup`: leave Windows SDK installed.
- `-RegisterMarketplaceOnly`: only register `openai-curated-local`; do not patch Codex.
- `-PatchScript <path>`: override the bundled patch script only when testing a newer patcher.
- `-SkipComputerUse`: skip installing/verifying the local Computer Use compatibility plugin.

## Computer Use Only

To refresh only the local Windows Computer Use files and environment gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1"
```

To verify and automatically repair missing local Computer Use files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -VerifyOnly
```

To verify without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -StrictVerifyOnly
```

## Backup Management

To back up local Codex config, MCP server entries, custom skills, marketplaces, and Chrome native-host state:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

To list or restore snapshots:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action List
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Restore -BackupPath "<backup path>"
```

## Success Criteria

- If an existing `config.toml` was modified, the log shows a timestamped backup under `.codex\backups\config\`.
- `Get-AppxPackage -Name OpenAI.Codex` shows `SignatureKind = Developer`.
- Codex Desktop processes stay alive from `...\WindowsApps\OpenAI.Codex_<version>...\app\Codex.exe`.
- Fast Mode verification logs `request wire service_tier=priority`.
- If upstream is CPA, CPA has an override rule for the Codex-facing models that sets `service_tier` to string value `priority`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-curated-local]`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-bundled]` pointing at `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, and that local mirror contains the installed bundled plugins plus `computer-use`.
- Any configured local marketplace used for personal plugins has a supported `.agents\plugins\marketplace.json`; root-level `marketplace.json` alone is not enough for the current plugin CLI.
- `$env:USERPROFILE\.codex\config.toml` contains `[plugins."computer-use@openai-bundled"]` with `enabled = true`.
- `codex plugin list` shows `computer-use@openai-bundled` as `installed, enabled`.
- `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` is set to `1` for the current user.
- `$env:USERPROFILE\.codex\config.toml` contains `[features]` with `computer_use = true`.
- `$env:USERPROFILE\.codex\config.toml` contains `[windows]` with `sandbox = "unelevated"`, and the sandbox command syntax shown by `codex sandbox --help` succeeds.
- `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js` exists and can return screen info/screenshot.
- The patched ASAR has `webview\assets\use-is-plugins-enabled-*.js` with the Computer Use availability gate forced local-available and `webview\assets\use-plugin-install-flow-*.js` with the Computer Use install gate unblocked.
- The patched ASAR has `webview\assets\codex-mobile-setup-flow-*.js` keeping ChatGPT auth failures inside a closable setup flow, and `.vite\build\main-*.js` maps remote-control unauthenticated state to a safe empty state instead of an auth loop.
- `makeappx.exe` and `signtool.exe` are missing again if SDK cleanup was enabled.
