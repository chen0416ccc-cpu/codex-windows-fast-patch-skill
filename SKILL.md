---
name: codex-windows-fast-patch
description: Reapply and repair Windows Codex Desktop after Store upgrades, including Fast Mode request/UI gates, locale i18n, plugin UI gates, Chrome/browser_use gates, Goal command gates, Windows Computer Use availability gates and plugin/runtime repair, phone remote-control pairing under third-party/API-key main app usage, ASAR integrity repair, signing/installing patched MSIX packages, SDK cleanup, Fast Mode wire verification, local plugin marketplace registration, and optional custom model_instructions_file setup.
---

# Codex Windows Fast Patch

Use this skill when the user says Codex Desktop was upgraded and the Fast Mode / Plugins / Goal patch disappeared, asks to repatch Codex on Windows, asks to verify whether Fast Mode is really being sent, asks to restore/register the local plugin marketplace, asks to enable Chrome browser use or Windows Computer Use in Codex Desktop, or asks to enable/repair phone remote control while keeping third-party/API-key model access. Also use it when the language/locale setting reverts after restart, browser or plugin entries are hidden by availability gates, the Computer Control settings page shows "Any App" / "任意应用" as disabled by organization or unavailable in the current region, a Computer Use task reports native pipe, bundled plugin cache, helper path, package import, or runtime initialization errors, phone remote-control QR pairing spins/fails, post-pairing phone-created turns hit the wrong model API endpoint, or the user explicitly asks to configure the bundled custom `model_instructions_file` prompt asset.

## Platform Compatibility

This skill is Windows-only. It depends on the Windows Store/MSIX package layout, PowerShell, `Get-AppxPackage`, `makeappx.exe`, `signtool.exe`, Windows user environment variables, and Windows Computer Use helper paths.

Do not run this skill on macOS. A macOS adaptation needs a separate workflow for the Codex `.app` bundle, ASAR extraction and repacking, macOS code signing or quarantine handling, shell scripts, and macOS-specific Computer Use availability.

## Self-Update Preflight

Before doing substantive work with this skill, run the bundled self-update helper once, then reload this `SKILL.md` if it reports an update:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\update-skill-from-github.ps1"
```

The helper checks `chen0416ccc-cpu/codex-windows-fast-patch-skill` on GitHub and synchronizes only the skill allowlist: `SKILL.md`, `agents`, `scripts`, `references`, and `assets`. 如果无法更新到最新版，则不要中断当前任务；继续使用本机已安装的当前版本完成工作，并在结果中说明未能更新。

If the normal workflow does not explain a restriction, plugin gate, Computer Use failure, browser_use failure, or Fast Mode failure, read `references/restriction-debug-cases.md` before editing scripts or repatching.
If the task is phone remote control, QR pairing, mobile setup, isolated remote OAuth, remote-control WebSocket, or post-pairing API endpoint diagnosis, read `references/remote-control-debug-cases.md` before editing scripts or repatching.

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

## Workflow Selection

Before choosing the full MSIX repack path, identify whether the current failure is a Desktop bundle gate or a local plugin/runtime repair.

- Use the full repatch workflow for Fast Mode, locale, plugin UI gates, browser_use Desktop gates, Goal gates, ASAR integrity, and settings/UI availability gates.
- Use the Computer Use Only workflow first when the visible failure is a Computer Use task/runtime problem: native pipe unavailable, missing helper path, bundled plugin cache drift, Chrome/browser cache link drift, stale `SKY_CUA_NATIVE_PIPE` config, `@oai/sky` import errors, or `setupComputerUseRuntime` import failure.
- Use the Phone Remote Control workflow when the user needs mobile pairing/control, the Connections page hides the phone setup card, the QR dialog spins, remote-control setup jumps to ChatGPT auth, the Allow dialog fails, the phone says the Codex environment version expired, or phone-created turns reach Desktop but send model requests to the wrong API endpoint.
- If the user asks for Phone Remote Control and ordinary Desktop features in the same repair, patch Phone Remote Control first, then verify Fast Mode/browser/Chrome/Computer Use. If the remote-control MSIX install disturbs Computer Use or Chrome native-host state, immediately run the Computer Use Only workflow and re-run `-StrictVerifyOnly`.
- Do not infer that a new `resources\codex.exe` PE file means `app.asar` is gone or that Computer Use needs binary patching. Inspect the current package resources first. If `app.asar` still exists and the symptom is a plugin/runtime import or cache failure, run `scripts\install-computer-use-local.ps1` before considering MSIX or binary changes.
- After a Computer Use-only repair, always run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly`. Treat `client import ok` plus `helper transport ok` as the local repair success signal.
- Do not put Phone Remote Control into the default full repatch path unless the user asked for it. It is an opt-in workflow because it can require isolated remote-control OAuth, ASAR changes, a native app-server replacement binary, SQLite enrollment cleanup, and post-pairing API endpoint diagnosis.

## Default Workflow

1. If the task may modify `config.toml`, skills, marketplaces, or MCP server settings, create a state snapshot first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

2. Inspect current package status:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name,PackageFullName,Version,SignatureKind,InstallLocation
```

3. If Workflow Selection points to a Computer Use-only failure, skip the MSIX dry run and go directly to the Computer Use Only section. Otherwise, run a dry run first after every Codex upgrade:

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
It also syncs the installed `openai-bundled` marketplace from the current Codex package into `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, overlays a local `computer-use@openai-bundled` compatibility plugin, writes that local marketplace into config, repairs stable `browser` / `chrome` plugin cache copies so their `latest` junctions do not point at the mutable `.tmp` marketplace mirror, and enables `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1` for the current user so the Desktop app can expose Windows Computer Use after restart.
It patches Fast Mode in both the request path and the settings UI path. The request patch removes the ChatGPT-only branch while still reading host/model feature requirements; the UI patch removes the matching ChatGPT-only availability check in service-tier settings.
It patches the locale i18n gate that can force the Desktop UI back to English after restart when `enable_i18n` is disabled in the shipped webview bundle.
It patches Chrome/browser_use gates in both the webview assets and the main Electron feature sender/receiver path, covering in-app browser, browser pane, and external browser availability. This only unlocks the local Desktop gates; Chrome extension and native messaging files still need to exist and should be verified separately.
It also patches the Desktop webview gates that otherwise hide or disable Windows Computer Use behind the `computer_use` experimental feature and Statsig gate `1506311413`, and it writes `features.computer_use = true` into `$env:USERPROFILE\.codex\config.toml` without replacing the rest of the `[features]` table.
It also writes `[windows] sandbox = "unelevated"` into `$env:USERPROFILE\.codex\config.toml`. On Windows, this avoids the elevated sandbox setup refresh path that can fail with `spawn setup refresh` / OS error 740 and break Computer Use startup.
It also repairs local marketplace manifest layout when a local root has only a legacy root `marketplace.json`; the current Codex CLI expects `.agents\plugins\marketplace.json`, and missing that file can make `codex plugin list` fail for all configured marketplaces.
It does not install the bundled custom `model_instructions_file` prompt by default. Only install it when the user explicitly requests that optional configuration.
Any bundled script write to an existing `config.toml` first creates one timestamped backup for that script run under `.codex\backups\config\`.

## Phone Remote Control

Before repairing phone remote control, read `references/remote-control-debug-cases.md`. Keep these boundaries explicit:

- Remote-control pairing/control transport can legitimately call `https://chatgpt.com/backend-api/wham/remote/control/...`. Do not rewrite that transport to a third-party model API endpoint.
- After phone pairing works, verify the actual model sampling request URL. If it goes to the wrong model API endpoint, treat that as a post-pairing configuration diagnosis, not as part of the remote-control pairing implementation.
- Remote-control OAuth is isolated: use `.codex\remote-control-oauth.json` and `.codex\remote.json`; never use `.codex\auth.json` for the remote-control bearer injection path.
- An alternate build root is only an optional `-OutputRoot` choice for machines with low system-drive space. Do not hard-code a drive letter into the workflow.

Run a dry run first. Do not pass `-KeepWorkDir` unless you need to inspect failed patch artifacts; successful dry-runs should clean generated package and ASAR extraction output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -DryRun
```

If the machine needs a larger temporary build location, pass it explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -DryRun -OutputRoot "<large-local-build-root>"
```

If a patched native `app\resources\codex.exe` was built from the Codex Rust source, pass it explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -DryRun -ReplacementResourceCodexExe "<path-to-built-codex.exe>"
```

Only after dry-run markers pass, install and relaunch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -Install -Launch -InstallPrerequisites -ReplacementResourceCodexExe "<path-to-built-codex.exe>"
```

Cleanup policy: successful remote-control script runs delete generated MSIX staging directories, ASAR extracts, script-local `npx` cache, installed patched `.msix` artifacts, and temporary Windows SDK BuildTools. Keep only reusable inputs such as the patched native `codex.exe` build, source checkout, auth/config/sqlite state, and explicit backups. Use `-KeepWorkDir` only for a failed or actively debugged run.

After installing Phone Remote Control, verify that ordinary features survived the remote-control repack. At minimum check live ASAR markers for remote control and browser local-patched availability, run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly`, run `codex plugin list`, run the Windows sandbox smoke test, and verify the Chrome native messaging manifest points at a stable cache version path rather than `.tmp` or `latest`. If the strict check reports a stale Chrome native-host manifest or missing bundled cache, run `scripts\install-computer-use-local.ps1 -VerifyOnly`, then rerun `-StrictVerifyOnly`.

If phone-created turns reach Desktop but fail against the wrong model API endpoint, inspect the concrete request URL, `config.toml`, and the affected thread/session metadata before changing anything. Treat this as a post-pairing configuration diagnosis, not as part of remote-control pairing. Preserve conversation history and do not change `model_provider` ids just to change a URL.

## Important Guardrails

- Do not modify `C:\Program Files\WindowsApps` in place. Use the MSIX repack script.
- Do not run the phone remote-control MSIX patch as a default repatch side effect. Use it only for phone remote-control tasks or when the user explicitly asks for that workflow.
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
- If the dry run or repack fails early with `robocopy failed with exit code 16`, inspect the configured `-OutputRoot` before changing patch targets. A common Windows failure is a broken junction such as `Downloads\codex-msix-repack` pointing at a deleted build directory. The patch script now recreates a missing reparse target when possible and otherwise fails early with an actionable `OutputRoot is a broken reparse point` message. Pass a valid `-OutputRoot` on a large local drive if the default cannot be repaired.
- If the local marketplace directory is missing, do not invent a marketplace. Report the missing path and ask whether to restore it from backup or re-extract it from a known source.
- For user-level Codex state backup or migration, use `scripts\manage-codex-backups.ps1`. It backs up `config.toml`, extracted `mcp_servers.json`, custom skills, marketplaces, and `chrome-native-hosts.json`. It excludes `.git`, `node_modules`, build output, and virtual environments by default; use `-IncludeDependencyDirs` only when an exact offline dependency copy is needed. Plugin cache and `.tmp\bundled-marketplaces` are also opt-in because they can be large.
- If `codex plugin list` fails with `failed to load configured marketplace snapshot(s)` and a local marketplace root contains only `marketplace.json`, copy that manifest to `.agents\plugins\marketplace.json` and re-run `codex plugin list` before diagnosing individual plugins.
- Do not depend on `Downloads\patch_codex_fast_mode_windows_msix.ps1`; the skill is intended to be self-contained. Use `scripts\patch_codex_fast_mode_windows_msix.ps1` unless the user explicitly passes `-PatchScript`.
- Do not enable the bundled custom `model_instructions_file` prompt unless the user explicitly asks for it. Treat `assets\system-prompt.md` as an opaque asset; copy/configure it, but do not inspect or summarize its content unless the user separately asks to review the prompt.
- If the user's upstream is CPA, verify CPA override rules as part of Fast Mode validation: for the Codex-facing models, force `service_tier` as a string parameter with value `priority`. Local wire capture only proves Codex Desktop sent the field; CPA can still strip, ignore, or fail to apply it unless the override rule is configured.
- In Codex 26.601.2237+, Fast Mode may be gated in `webview\assets\read-service-tier-for-request-*.js` as an async helper shaped like `return authMethod===\`chatgpt\` ? featureRequirements?.fast_mode !== false : false`. The patch should remove the `chatgpt`-only branch while still reading the model/host feature requirement, then verify with the wire capture.
- In Codex 26.601.2237+, Fast Mode may also stay invisible or disabled in the settings UI through `webview\assets\use-service-tier-settings-*.js`. The patch should connect the Fast UI patcher and log `fast-mode UI patch result`, not only patch the request helper.
- If the language selection reverts to English after restart, inspect the extracted webview assets for `enable_i18n`, `locale_source`, and `localeOverride`. The locale patch should log `locale i18n patch result`; do not treat a config-only language write as sufficient.
- If browser, Chrome, browser pane, or `browser_use` remains unavailable, inspect the Desktop log for `browser_use_availability_resolved`. `reason=statsig-disabled` means the local gate patch did not apply or the Store build introduced a new target shape; `reason=local-patched` means the availability gate is open and the next checks are the Chrome extension, native messaging host, and bundled plugin state.
- In Codex 26.601.2237+, the old plugin UI gate targets `533078438` and `pluginDeepLinkAuthBlocked` may be absent. Inspect `webview\assets\plugins-page-*.js` for `openPluginInstall`, `authMethod:`, and a compact assignment shaped like `{authMethod:x}=..., y=authBlocked(x),`; patch the auth-blocked variable to `false` instead of failing on missing old sidebar/skills/detail chunks.
- In Codex 26.519.11010+, `use-plugin-install-flow-*.js` may no longer contain `featureName:\`computer_use\``. For the Computer Use install-flow gate, locate the file with `installPlugin:async` and `openPluginInstall`, then patch the imported availability tuple so the first `.available` value for Computer Use is forced true.
- Do not modify `C:\Program Files\WindowsApps` in place to enable Computer Use. The Windows gate is controlled by `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`, and the helper paths are supplied through the local `computer-use@openai-bundled` plugin.
- If Computer Use or a `node_repl` Computer Use plugin fails on Windows with `windows sandbox failed: spawn setup refresh`, inspect `$env:USERPROFILE\.codex\.sandbox\sandbox.<date>.log`. If it shows `codex-windows-sandbox-setup.exe` failing with OS error 740, set `[windows] sandbox = "unelevated"`. Check `codex sandbox --help` before verification: if the help lists a `windows` command, verify with `codex sandbox windows "C:\Windows\System32\cmd.exe" /c echo OK`; only builds whose help accepts a direct command form should use `codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK`.
- If a Computer Use task fails before app interaction with `Package subpath ... is not defined by "exports"`, `Module not found: @oai/sky`, missing `setupComputerUseRuntime`, or an internal `@oai/sky` / `computer_use_client_base` import path error, treat it as local bundled plugin/runtime drift. Run `scripts\install-computer-use-local.ps1 -VerifyOnly`, then `-StrictVerifyOnly`. Do not patch `app.asar` or `resources\codex.exe` for this class unless Desktop logs also prove a UI availability gate is still closed.
- If "任意应用" is visible but disabled as organization/region unavailable, inspect `webview\assets\use-is-plugins-enabled-*.js` in the extracted ASAR. The relevant local gates are `featureName:\`computer_use\`` and Statsig `1506311413`; reapply the MSIX patch rather than editing WindowsApps in place.
- If the Computer Control page says `Computer Use 插件不可用`, check the Desktop log for `computer-use native pipe startup failed` with `missing-helper-path`, then inspect `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled\.agents\plugins\marketplace.json` and `plugins\computer-use`. If they are missing or partial, stop bundled `extension-host` processes under `$env:USERPROFILE\.codex\plugins\cache\openai-bundled`, rerun `scripts\install-computer-use-local.ps1`, restart Codex Desktop, and confirm the log ends with `computer-use native pipe startup ready`.
- If `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` fails because `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\.codex-plugin\plugin.json` is missing, run the same script with `-VerifyOnly` to repair the marketplace mirror, cached plugin copy, and `latest` link, then rerun `-StrictVerifyOnly`.
- If the failure reappears after fully quitting and reopening Codex Desktop, inspect `$env:USERPROFILE\.codex\chrome-native-hosts.json` and the real targets of `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\latest` and `browser\latest`. Stale Chrome native-host entries, or a `chrome\latest` junction that points at `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled\plugins\chrome`, can let Chrome native messaging lock the mutable marketplace mirror. The symptom is `bundled_plugins_marketplace_resolve_failed` with `EBUSY` on `plugins\chrome\extension-host\windows\x64`, followed by `helper paths changed` and `missing-helper-path`; rerun `scripts\install-computer-use-local.ps1` to stop the lock holder, rebuild stable browser/chrome cache copies, repoint the Chrome native messaging manifest to the stable cache path, and repair Computer Use.

## Useful Wrapper Options

- `-DryRun`: verify bundle targets only; no install.
- `-NoLaunch`: install but do not start Codex Desktop.
- `-SkipFastVerify`: skip the WebSocket `service_tier` capture.
- `-KeepBuild`: keep `Downloads\codex-msix-repack` for debugging.
- `-OutputRoot <path>`: optional large local build root; use it when the default output root is short on space, points at a broken junction, or should be kept off the system drive.
- `-SkipSdkCleanup`: leave Windows SDK installed.
- `-RegisterMarketplaceOnly`: only register `openai-curated-local`; do not patch Codex.
- `-PatchScript <path>`: override the bundled patch script only when testing a newer patcher.
- `-SkipComputerUse`: skip installing/verifying the local Computer Use compatibility plugin.
- `-InstallModelInstructionsFile`: optional; copy the bundled prompt asset to `$env:USERPROFILE\.codex\prompts\system-prompt.md` and set top-level `model_instructions_file` in `$env:USERPROFILE\.codex\config.toml`.
- `-ModelInstructionsSource <path>`: optional source override for `-InstallModelInstructionsFile`; defaults to `assets\system-prompt.md`.
- `-ModelInstructionsDestination <path>`: optional destination override for `-InstallModelInstructionsFile`; defaults to `$env:USERPROFILE\.codex\prompts\system-prompt.md`.

Phone remote-control script options:

- `scripts\patch-remote-control-windows-msix.ps1 -DryRun`: patch and validate extracted package without installing, then clean successful generated artifacts.
- `-KeepWorkDir`: keep MSIX staging, ASAR extract, and script-local `npx` cache for debugging; avoid this on routine repairs because each kept run can consume multiple GB.
- `-OutputRoot <path>`: optional large local build root; use it when the default temp/output drive is short on space.
- `-ReplacementResourceCodexExe <path>`: copy in a patched native app-server binary and verify remote-control markers before packaging.
- `-Install -Launch -InstallPrerequisites`: sign, install, and relaunch the patched package after dry-run passes.

## Optional Model Instructions File

This workflow has an optional custom model instructions installer. It is not part of the default repatch flow and should only run when the user asks for that extra configuration.

To install only the bundled prompt asset and configure Codex:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-model-instructions-file.ps1"
```

The installer copies `assets\system-prompt.md` to `$env:USERPROFILE\.codex\prompts\system-prompt.md`, writes this top-level TOML entry, validates TOML syntax when Python is available, and logs a timestamped backup of any existing `config.toml`:

```toml
model_instructions_file = 'C:\Users\<user>\.codex\prompts\system-prompt.md'
```

To combine it with the main wrapper, add `-InstallModelInstructionsFile` explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\repatch-codex-windows.ps1" -InstallModelInstructionsFile
```

To verify the current machine without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-model-instructions-file.ps1" -VerifyOnly
```

After configuring `model_instructions_file`, restart Codex CLI/Desktop or start a new session so the new model instructions file is loaded.

## Computer Use Only

Use this path for local Computer Use plugin/runtime repair without repacking the MSIX. It rebuilds the local `openai-bundled` marketplace mirror, repairs stable `computer-use` / `browser` / `chrome` cache links, overlays the installed CUA `@oai/sky` runtime into the local Computer Use plugin, patches the Computer Use client import shape when needed, removes stale `SKY_CUA_NATIVE_PIPE` overrides from `config.toml`, updates the Chrome native messaging host to stable cache paths, and verifies both the client import and helper transport.

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

If `-StrictVerifyOnly` fails because a cache path is missing or stale, run `-VerifyOnly` once, then rerun `-StrictVerifyOnly`. If `-VerifyOnly` succeeds but Desktop still reports native pipe unavailable, restart Codex Desktop and inspect the newest Desktop log for `computer-use native pipe startup ready`.

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
- The patch log includes `fast-mode UI patch result` and `locale i18n patch result`, each either `patched` or `already-patched`.
- The patch log includes `browser-use gate patch result`, either `patched` or `already-patched`.
- Desktop logs show `browser_use_availability_resolved` with `available=true` and `reason=local-patched` after the patched app starts.
- If upstream is CPA, CPA has an override rule for the Codex-facing models that sets `service_tier` to string value `priority`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-curated-local]`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-bundled]` pointing at `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, and that local mirror contains the installed bundled plugins plus `computer-use`.
- Any configured local marketplace used for personal plugins has a supported `.agents\plugins\marketplace.json`; root-level `marketplace.json` alone is not enough for the current plugin CLI.
- `$env:USERPROFILE\.codex\config.toml` contains `[plugins."computer-use@openai-bundled"]` with `enabled = true`.
- `codex plugin list` shows `computer-use@openai-bundled` as `installed, enabled`.
- If Chrome/browser use is required, `codex plugin list` shows `chrome@openai-bundled` and `browser@openai-bundled` as `installed, enabled`, the Chrome native messaging host manifest points to a stable cache path under `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\<version>\...` rather than `chrome\latest` or `.tmp\bundled-marketplaces`, `chrome\latest` and `browser\latest` point to stable cache version directories rather than the mutable marketplace mirror, and a smoke test can read a controlled tab title such as `Example Domain`.
- `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` is set to `1` for the current user.
- `$env:USERPROFILE\.codex\config.toml` contains `[features]` with `computer_use = true`.
- `$env:USERPROFILE\.codex\config.toml` contains `[windows]` with `sandbox = "unelevated"`, and the sandbox command syntax shown by `codex sandbox --help` succeeds.
- `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js` exists and can return screen info/screenshot.
- `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` logs `client import ok` and `helper transport ok`.
- The patched ASAR has `webview\assets\use-is-plugins-enabled-*.js` with the Computer Use availability gate forced local-available and `webview\assets\use-plugin-install-flow-*.js` with the Computer Use install gate unblocked.
- The patched ASAR has `webview\assets\use-service-tier-settings-*.js` with the Fast Mode UI gate unblocked, the locale chunk with `enable_i18n` forced enabled, and browser_use feature chunks/main feature dispatch patched to report in-app and external browser availability locally.
- For phone remote-control repair, the patched ASAR contains `remote_control_desktop_fetch_override_used`, `remote_control_mobile_setup_no_auth_redirect`, `remote_control_mobile_setup_authorize_before_enable`, `remote_control_settings_force_control_this_pc_visible`, `remote_control_settings_force_remote_control_section_visible`, and `remote_control_qm_start`.
- For phone remote-control repair with a native replacement, live `app\resources\codex.exe` contains `remote_control_app_server_isolated_oauth_used`, `remote_control_native_remote_json_first`, `remote_control_websocket_proxy_attempt`, `remote_control_websocket_proxy_connected`, `remote-control-oauth.json`, `remote.json`, and `codex.remote_control.enroll`.
- For phone remote-control repair, `Settings -> Connections` shows the mobile/phone setup path, the QR code appears, phone scan no longer reports an expired Codex environment, native logs show remote-control WebSocket ping/pong/ack instead of repeated Windows `os error 10060`, and phone-sent turns reach Desktop. If a phone-sent turn then targets the wrong model API endpoint, handle it as the post-pairing configuration case.
- `makeappx.exe` and `signtool.exe` are missing again if SDK cleanup was enabled.
