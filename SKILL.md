---
name: codex-windows-fast-patch
description: Reapply and repair Windows Codex Desktop after Store upgrades, including custom provider models hidden by Statsig available_models filtering and the dependent blue-purple Power slider, Fast Mode request/UI gates, locale i18n, plugin UI gates, Chrome/browser_use gates, Goal command gates, Windows Computer Use availability gates and plugin/runtime repair, phone remote-control pairing under third-party/API-key main app usage, Desktop dynamicTools/inputSchema thread-start schema drift, local conversation visibility recovery after model_provider switches, restored-conversation missing-cwd continuation repair, ASAR integrity repair, signing/installing patched MSIX packages, SDK cleanup, Fast Mode wire verification, local plugin marketplace registration, and optional custom model_instructions_file setup.
---

# Codex Windows Fast Patch

Use this skill when the user says Codex Desktop was upgraded and the Fast Mode / Plugins / Goal patch disappeared, asks to repatch Codex on Windows, asks to verify whether Fast Mode is really being sent, asks to restore/register the local plugin marketplace, asks to enable Chrome browser use or Windows Computer Use in Codex Desktop, or asks to enable/repair phone remote control while keeping third-party/API-key model access. Also use it when a custom provider or `/v1/models` exposes a new model but Desktop still hides it, when GPT-5.6 Sol/Terra/Luna are missing from the model picker, or when the compact blue-purple Power slider falls back to the legacy Model / Reasoning / Speed menu because Statsig `available_models` filtering removed the required model combinations. Also use it when the language/locale setting reverts after restart, browser or plugin entries are hidden by availability gates, the Computer Control settings page shows "Any App" / "任意应用" as disabled by organization or unavailable in the current region, a Computer Use task reports native pipe, bundled plugin cache, helper path, package import, or runtime initialization errors, phone remote-control QR pairing spins/fails, post-pairing phone-created turns hit the wrong model API endpoint, Desktop new-chat/thread start fails with `missing field inputSchema`, local conversations disappear after switching `model_provider` / API account, restored conversations are visible but cannot continue because the current working directory is missing, or the user explicitly asks to configure the bundled custom `model_instructions_file` prompt asset.

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

Before choosing the full MSIX repack path, identify whether the current failure is a Desktop bundle gate or a local plugin/runtime repair. Do not treat a vague "Chrome/Computer Use is unavailable" report as enough evidence to run the full repatch.

- Use the Model Experience workflow for Fast Mode request/UI failures, new models hidden from the Desktop picker, the compact Power slider falling back to the legacy picker, or Ultra forcing Full access to switch modes or snapping back to a lower effort. These symptoms share the same service-tier/model-picker area. Run `scripts\patch_codex_fast_mode_windows_msix.ps1 -OnlyModelExperience -DryRun` first; it checks the Fast request gate, Fast UI gate, model visibility filter, Electron Power slider `harborEnabled` gate, Ultra confirmation gate, Ultra permission fallback, and Ultra model-setting read/write fallback independently, then repairs only the broken parts in one MSIX repack. `-OnlyCustomModels` remains a compatibility alias. Merge missing model metadata into `models_cache.json` only when read-only inspection proves the cache entry is absent; back up the cache first.
- Use the full repatch workflow for locale, plugin UI gates, browser_use Desktop gates, Goal gates, ASAR integrity, settings/UI availability gates, or when Model Experience repair is required together with those features.
- Use the Computer Use Only workflow first when evidence points to a local plugin/runtime problem: `codex plugin list` marketplace errors, missing `.agents\plugins\marketplace.json`, missing or partial `openai-bundled` plugin files, `bundled_plugins_marketplace_resolve_failed`, `EBUSY` on bundled plugin files, native pipe unavailable, `missing-helper-path`, stale Chrome native messaging host paths, bundled plugin cache drift, Chrome/browser cache link drift, stale `SKY_CUA_NATIVE_PIPE` config, `@oai/sky` import errors, or `setupComputerUseRuntime` import failure. This class does not require an MSIX uninstall/reinstall unless a later check also proves a Desktop gate is still closed.
- If app/window enumeration works but the first screenshot fails with `SetIsBorderRequired failed` and `0x80004002` on Windows 10, treat it as a native CUA screenshot-helper compatibility failure, not a cache path or Desktop gate. Read `references/win10-computer-use-screenshot-backend.md`, then use `scripts\patch-computer-use-helper-win10.ps1` only when its read-only status reports the exact supported original or patched hash. Unknown hashes require fresh analysis and must remain untouched.
- Use the Phone Remote Control workflow when the user needs mobile pairing/control, the Connections page hides the phone setup card, the QR dialog spins, remote-control setup jumps to ChatGPT auth, the Allow dialog fails, the phone says the Codex environment version expired, or phone-created turns reach Desktop but send model requests to the wrong API endpoint.
- Use the Missing inputSchema decision workflow when Codex Desktop cannot create a new conversation or local task and the newest Desktop log reports `method=thread/start` with the phrase `missing field inputSchema`. Do not assume this is always MCP. First compare CLI/app-server smoke tests against Desktop logs and inspect whether Desktop is sending non-null app dynamic tools. If the failure follows a suspect MCP server, isolate MCP. If CLI thread start succeeds while Desktop UI fails and extracted ASAR has `webview\assets\app-server-dynamic-tools-*.js` returning a namespace-wrapped `dynamicTools` object, use the Dynamic Tools Schema workflow. Do not run Phone Remote Control or Computer Use repair for this symptom unless separate evidence points there.
- Use the Provider History Sync workflow when old conversations disappear from the official Desktop sidebar after the user changes `model_provider`, API account, or provider config, but local `sessions`, `archived_sessions`, or `state_5.sqlite` data still exists. Also use it when the conversations reappear but opening/continuing one fails with `当前工作目录缺失`, `current working directory missing`, or `invalid codex request` caused by a missing historical `cwd`. This workflow is data-layer repair; it does not require third-party recovery tools, does not patch ASAR, and must not modify `config.toml`.
- Use the targeted bundled marketplace repair when the newest Desktop logs show the runtime marketplace reconciling only 4 bundled plugins instead of the expected `sites,browser,chrome,computer-use,latex`, or show `not_in_bundled_marketplace_plugin_names` uninstalling `sites@openai-bundled`, `browser@openai-bundled`, or `chrome@openai-bundled`. In newer Windows builds, `sites` can be present in the shipped marketplace but filtered out by `features.sites = false`; this should not trigger a broad repatch or Phone Remote Control workflow.
- If the user asks for Phone Remote Control and ordinary Desktop features in the same repair, patch Phone Remote Control first, then verify Fast Mode/browser/Chrome/Computer Use. If the remote-control MSIX install disturbs Computer Use or Chrome native-host state, immediately run the Computer Use Only workflow and re-run `-StrictVerifyOnly`.
- Do not infer that a new `resources\codex.exe` PE file means `app.asar` is gone or that Computer Use needs binary patching. Inspect the current package resources first. If `app.asar` still exists and the symptom is a plugin/runtime import or cache failure, run `scripts\install-computer-use-local.ps1` before considering MSIX or binary changes.
- After a Computer Use-only repair, always run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly`. Treat `client import ok` plus `helper transport ok` as the local repair success signal.
- Do not put Phone Remote Control into the default full repatch path unless the user asked for it. It is an opt-in workflow because it can require isolated remote-control OAuth, ASAR changes, a native app-server replacement binary, SQLite enrollment cleanup, and post-pairing API endpoint diagnosis.
- If evidence is mixed, use the lowest-disruption path first: run read-only triage, then `scripts\install-computer-use-local.ps1 -VerifyOnly` for local plugin evidence, restart Codex Desktop only if needed, and escalate to MSIX only when logs or extracted ASAR checks still show a closed gate.

## External Executor For Desktop-Restarting Repairs

If a repair can stop, uninstall, reinstall, repackage, or relaunch Codex Desktop, do not run it from the Codex Desktop session being repaired. Use an external Windows PowerShell session, the VS Code Codex extension, or another agent environment that will survive the Desktop restart.

The target state is the Desktop Codex home: normally `$env:USERPROFILE\.codex`. Do not use an isolated CLI entrypoint for Desktop repair decisions; if that wrapper sets `CODEX_HOME` to `$env:USERPROFILE\.codex-cli` or another isolated directory, it is not the Desktop plugin, marketplace, MCP, remote-control, or login state.

Before starting from VS Code Codex or external PowerShell, confirm no User-level or Machine-level `CODEX_HOME` is set. Do not set global `CODEX_HOME`, do not copy `.codex` into `.codex-cli`, and do not expose or commit `auth.json`, API keys, OAuth tokens, MCP credentials, browser profiles, or local credential stores. Start with a Desktop-state backup, run read-only package/config/log checks, then run the relevant `-DryRun`. Only use `-Install`, full `repatch-codex-windows.ps1`, or targeted `*-windows-msix.ps1 -Install -Launch -InstallPrerequisites` after the dry run finds and validates the intended targets.

## Default Workflow

1. If the task may modify `config.toml`, skills, marketplaces, or MCP server settings, create a state snapshot first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

2. Inspect current package status:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name,PackageFullName,Version,SignatureKind,InstallLocation
```

3. Run read-only feature triage before any package reinstall. Capture the decision evidence, especially for Chrome/Computer Use:

```powershell
codex plugin list
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -StrictVerifyOnly
```

If `-StrictVerifyOnly` fails on a missing marketplace manifest, missing plugin files, stale `latest` link, stale Chrome native messaging manifest, missing helper path, or `@oai/sky` import/runtime issue, run the Computer Use Only repair first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -VerifyOnly
```

This local repair may update config, plugin cache, Chrome native host paths, user environment, and helper runtime files, but it does not uninstall or reinstall the Codex MSIX package.

4. Before choosing a full MSIX repack, check whether this is the bundled marketplace fast path. If Desktop logs show `pluginNames=["sites","browser","chrome","computer-use","latex"]`, the expected bundled marketplace descriptor set is intact. If logs instead show only `browser,chrome,computer-use,latex`, or `not_in_bundled_marketplace_plugin_names` for `sites@openai-bundled`, run only the targeted bundled marketplace patch on a large local drive:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyBundledMarketplaceCopy -DryRun -OutputRoot "<large-local-build-root>"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyBundledMarketplaceCopy -Install -Launch -InstallPrerequisites -CleanupAfter -CleanupWindowsSdkAfterInstall -OutputRoot "<large-local-build-root>"
```

After relaunch, run `scripts\install-computer-use-local.ps1 -VerifyOnly` and `scripts\install-computer-use-local.ps1 -StrictVerifyOnly`. When the installed bundled marketplace provides `sites`, the local repair now re-enables it and rebuilds its stable cache automatically. Then confirm recent logs retain `pluginNames=["sites","browser","chrome","computer-use","latex"]` and do not contain `not_in_bundled_marketplace_plugin_names` for `sites`.

5. Escalate to MSIX only when the evidence points to package-gated Desktop code: Fast Mode request/UI gates, locale gate, Goal/plugin UI gate, browser_use availability with `reason=statsig-disabled`, Computer Use/Any App disabled by settings/UI availability gates after local repair, ASAR integrity failure, or Phone Remote Control package patches. Otherwise do not run the full repatch just because a plugin is unavailable.

Run a dry run first after every Codex upgrade when MSIX escalation is justified:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\repatch-codex-windows.ps1" -DryRun
```

6. If the dry run finds all patch targets, run the full repatch:

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
It also forces the configured custom model IDs through the Desktop model visibility filter. By default these are `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`. On builds containing the compact Power slider, it also opens the Electron-specific `harborEnabled` gate so the matching GPT-5.6 model and reasoning combinations use that slider instead of the legacy model/effort/speed-only menu.
It also removes the Desktop-only Ultra/Full access incompatibility gate in the composer selection handler, permission-mode resolver, and model-setting read/write resolver. This keeps Full access selected and preserves `ultra` instead of showing the forced-switch dialog, silently resolving to a non-Full-access fallback, or snapping back to the previous/default effort; it does not change the native Codex binary or phone remote control.
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
- An alternate build root is mandatory when the user says not to consume the system drive. Pass `-WorkRoot` / `-OutputRoot` on the requested large local drive and keep Cargo, Rustup, temp, target, MSIX, and source checkout under that root. Do not hard-code a drive letter into the workflow.

If `Settings -> Connections -> Control this computer` is visible but the device list says to sign in to ChatGPT again, verify the normal remote-control bearer before repatching MSIX again:

```powershell
python "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\refresh-remote-control-auth.py" --verify-only
```

If that reports `remote_json_disabled`, `access_token_expired`, `endpoint_http_error`, HTTP 401/403, or a token-refresh diagnosis such as `refresh_token_reused`, regenerate only `.codex\remote.json` with the same script. It uses the official Codex OAuth client, requests `openid profile email offline_access api.connectors.read api.connectors.invoke`, backs up the old `remote.json` under `.codex\backups\remote-control-auth`, defaults to proxy `http://127.0.0.1:10808`, and must not write `.codex\auth.json` or `config.toml`.

If `remote.json` verifies successfully but clicking `Add` or opening `Control this computer` falls back to a new conversation/main chat page, inspect `$env:USERPROFILE\.codex\remote-control-flow.log` and direct endpoint results for an expired `remote-control-oauth.json` enroll token shadowing the normal bearer. The ASAR patcher must skip expired JWTs before returning an isolated bearer and should verify `remote_control_auth_token_expired_skipped` in the patched ASAR. Do not delete `.codex\remote-control-oauth.json` blindly; keep it for fresh step-up/enroll flows and let valid `.codex\remote.json` satisfy read/MFA endpoints.

If the Allow dialog fails and the newest native app-server logs show `remote control requires ChatGPT authentication; API key auth is not supported`, ASAR patches and `.codex\remote.json` refresh are not enough. Build a patched native `app\resources\codex.exe` from the Codex Rust source with the reference native patch, using a large non-system work root when requested:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\build-remote-control-native-replacement.ps1" -WorkRoot "<large-local-build-root>\native-remote"
```

If the phone reports the Codex environment is expired after a native replacement, inspect the original installed native version before building. Use only an exact mapped Desktop/native/source-tag combination. For example, Desktop `26.715.2305.0` ships `codex-cli 0.145.0-alpha.18` and Desktop `26.707.3748.0` ships `codex-cli 0.144.0-alpha.4`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\build-remote-control-native-replacement.ps1" -WorkRoot "D:\CodexData\rc145" -CodexSourceRef "rust-v0.145.0-alpha.18" -AppServerVersion "0.145.0-alpha.18"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\build-remote-control-native-replacement.ps1" -WorkRoot "D:\CodexWork\phone-remote-26.707\native-remote-0.144.0-alpha.4" -CodexSourceRef "rust-v0.144.0-alpha.4" -AppServerVersion "0.144.0-alpha.4"
```

The build helper keeps the clone, Cargo cache, Rustup cache, temp directory, target directory, and any bootstrapped Windows SDK packages under `-WorkRoot`. When `-CodexSourceRef` and `-AppServerVersion` are omitted together, it copies the installed WindowsApps `app\resources\codex.exe` into `WorkRoot\tmp`, runs `--version` only on that copy, and selects a bundled version mapping; it never executes the WindowsApps binary in place. Desktop `26.715.2305.0` maps to `rust-v0.145.0-alpha.18`, `references\remote-control-native-replacement-0.145.0-alpha.18.patch`, and workspace version `0.145.0-alpha.18`. Desktop `26.707.3748.0` maps to `rust-v0.144.0-alpha.4`, `references\remote-control-native-replacement.patch`, and workspace version `0.144.0-alpha.4`. For historical `rust-v0.142.4`, matching parameters select `references\remote-control-native-replacement-0.142.4.patch`; that patch has passed clean patch-apply validation, but has not yet completed the same end-to-end native compilation validation as the newer mappings. Other source versions require matching explicit version parameters plus a validated `-PatchPathOverride`. Do not use GNU toolchain output for Windows MSIX replacement; use the MSVC target.

If MSVC is present but `kernel32.lib` is missing, the helper first searches for one coherent existing Windows SDK root/version containing matching x64 `kernel32.lib`, `ucrt.lib`, and headers; it does not mix independently discovered installed SDK versions. Only when no usable SDK exists, it downloads `Microsoft.Windows.SDK.CPP` and `Microsoft.Windows.SDK.CPP.x64` version `10.0.26100.4188` into `<WorkRoot>\cache\windows-sdk-cpp`. Downloads use `.partial` files, validate the archive and expected payloads, and replace the cache only after validation; corrupt cached packages are deleted and downloaded again. On Windows PowerShell 5.1, extract NuGet packages with checked `tar.exe`; `Expand-Archive` can fail while cleaning a deep `_rels\.rels` tree. The two packages use a split layout, so accept the matching NuGet roots `c\um\x64\kernel32.lib`, `c\ucrt\x64\ucrt.lib`, `c\Include\<version>\um\Windows.h`, and optionally `c\bin\<version>\x64\rc.exe` instead of requiring one traditional installed-Kits tree. Downloads honor existing `HTTPS_PROXY` / `HTTP_PROXY`; when neither is set, the helper uses `http://127.0.0.1:10808` only if that port is listening, otherwise it downloads directly.

Keep `-WorkRoot` short as well as off the system drive. A deeply nested D-drive root can still fail while Cargo checks out Git dependencies with `path too long`; the validated `0.145.0-alpha.18` build succeeded under `D:\CodexData\rc145`. When retrying after an interrupted or timed-out external run, first confirm the child PowerShell process has exited and use a unique `WorkRoot` / `OutputRoot`; a timed-out parent can leave a child cleaning the previous root.

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

When `makeappx.exe` / `signtool.exe` are missing, the install path downloads Windows SDK BuildTools from NuGet under `-OutputRoot\.remote-control-temp`, not `%TEMP%`. Do not hard-code a local proxy for this download. Use the default direct/env-proxy path first; only pass `-BuildToolsProxy "http://127.0.0.1:10808"` or set `CODEX_WINDOWS_SDK_BUILDTOOLS_PROXY` when that proxy is known to be listening. Proxy URIs and credentials are never printed. `curl download failed with exit code 7` usually means the selected proxy endpoint refused the connection.

Run disruptive install commands from an external PowerShell process and judge the child's actual exit code. Under Windows PowerShell 5.1, do not pipe `*>&1` through `Tee-Object` when `$ErrorActionPreference = 'Stop'`; npm warnings written to stderr can become terminating `RemoteException` records. Do not redirect child stdout and stderr to the same file. Use `Start-Process powershell.exe -Wait -PassThru -RedirectStandardOutput <stdout-file> -RedirectStandardError <stderr-file>`, check `ExitCode`, then merge or summarize the two logs after the process exits.

If an install attempt is interrupted after uninstall/signing and `Get-AppxPackage -Name OpenAI.Codex` returns no package, do not rebuild first. Install the existing patched MSIX from the selected `-OutputRoot` if it exists:

```powershell
Add-AppxPackage -Path "<large-local-build-root>\OpenAI.Codex_<version>_remote-control-patched.msix" -ForceApplicationShutdown -Verbose
```

Cleanup policy: successful remote-control script runs delete generated MSIX staging directories, ASAR extracts, script-local `npx` cache, installed patched `.msix` artifacts, and temporary Windows SDK BuildTools. If the user only asked for the repair and did not ask to keep reusable build outputs, also remove the native source checkout, Cargo/Rustup caches, target directory, temp directory, and generated patch/MSIX files created only for this repair. Keep the installed patched package, `.codex\remote.json`, `.codex\remote-control-oauth.json`, auth/config/sqlite state, logs, and explicit backups.

After installing Phone Remote Control, verify that ordinary features survived the remote-control repack. At minimum check live ASAR markers for remote control and browser local-patched availability, live native markers when a replacement binary was used, run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly`, run `codex plugin list`, run the Windows sandbox smoke test, and verify the Chrome native messaging manifest points at a stable cache version path rather than `.tmp` or `latest`. If the strict check reports a stale Chrome native-host manifest or missing bundled cache, run `scripts\install-computer-use-local.ps1 -VerifyOnly`, then rerun `-StrictVerifyOnly`.

When reading shared log databases, distinguish the running WindowsApps app-server process from old extension app-server processes. A stale Antigravity/VS Code extension `codex.exe` can continue logging `API key auth is not supported` after the WindowsApps package is fixed; filter by process path or `pid` before declaring the repair failed.

If phone-created turns reach Desktop but fail against the wrong model API endpoint, inspect the concrete request URL, `config.toml`, and the affected thread/session metadata before changing anything. Treat this as a post-pairing configuration diagnosis, not as part of remote-control pairing. Preserve conversation history and do not change `model_provider` ids just to change a URL.

## Dynamic Tools Schema

Use this targeted MSIX/ASAR path only for the Desktop dynamicTools variant of `missing field inputSchema`. Required evidence:

- Newest Desktop log shows `method=thread/start` with `missing field inputSchema`.
- CLI/app-server smoke tests can start a thread when they do not send Desktop app dynamic tools, for example `codex debug app-server send-message-v2 "只输出 OK"` or an equivalent `thread/start` path with `dynamicTools:null`.
- The Desktop log or extracted bundle shows the failure happens after Desktop app dynamic tools are assembled, not after MCP server startup.
- Extracted `webview\assets\app-server-dynamic-tools-*.js` returns the old namespace wrapper shape: `[{type:\`namespace\`, name, description, tools:[...]}]`.

When those conditions hold, patch the Desktop asset to return flat `DynamicToolSpec[]` entries with `namespace`, `name`, `description`, `inputSchema`, and optional `deferLoading`. Do not disable MCP servers for this variant unless a separate MCP-specific failure remains.

Run a dry run first. Use `-OutputRoot` on a large local drive when the system drive is low:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-dynamic-tools-windows-msix.ps1" -DryRun -OutputRoot "<large-local-build-root>"
```

If the dry run passes, install and relaunch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-dynamic-tools-windows-msix.ps1" -Install -Launch -InstallPrerequisites -OutputRoot "<large-local-build-root>"
```

After installation, verify with the actual Desktop UI or newest Desktop logs. A CLI-only smoke test is not sufficient because it can bypass Desktop `dynamicTools`. Confirm the latest `thread/start` entries do not report `missing field inputSchema`, then run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` and `codex plugin list` if Computer Use, Chrome, or browser use are in scope.

Cleanup policy: successful dynamic-tools script runs delete generated MSIX staging directories, ASAR extracts, script-local `npx` cache, temporary SDK cache under `-OutputRoot`, and installed patched `.msix` artifacts. Use `-KeepWorkDir` only for failed or actively debugged runs.

## Provider History Sync

Use this targeted workflow when Codex Desktop local conversations disappear after switching `model_provider`, API account, or provider config, while the actual local history files still exist. The root cause is usually that Codex filters the official sidebar by the active provider bucket; older thread rows and rollout metadata remain under a previous provider.

Also use this workflow for the second-stage failure where recovered conversations are visible in the official sidebar but cannot be continued because Desktop reports the working directory is missing. In that case the provider bucket may already be correct; the durable source of truth can still point at an old `session_meta.payload.cwd` directory that no longer exists.

This workflow uses the verified local-history mechanism directly; it does not install or require external recovery tools. It reads the current provider from `config.toml`, then aligns provider metadata in local history stores:

- `sessions` and `archived_sessions` rollout JSONL first line: `session_meta.payload.model_provider`
- App SQLite store: `$env:USERPROFILE\.codex\sqlite\state_5.sqlite`
- Legacy CLI SQLite store: `$env:USERPROFILE\.codex\state_5.sqlite`
- Missing thread rows from the legacy CLI store into the newer App store when the App store is missing rows that still exist in the legacy store.
- Missing historical `cwd` directories referenced by rollout first lines, when explicitly requested with `-RepairMissingCwdDirs`.

Important source-of-truth details:

- Codex 26.609+ can rebuild `state_5.sqlite` from rollout JSONL on startup. Treat rollout first-line `session_meta.payload` as durable metadata, not the App SQLite row alone.
- Do not repair `当前工作目录缺失` by changing only one SQLite store. That can make the UI look fixed until restart, then backfill or rollout reads can reintroduce the old value.
- Prefer recreating the original missing `cwd` directory as an empty directory before rewriting historical metadata. This keeps the rollout history intact and was verified to fix visible-but-uncontinuable restored conversations.

Before changing anything, run a dry run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\sync-codex-provider-history.ps1" -DryRun
```

Read the dry-run output before selecting the write path:

- If it shows mismatched provider buckets, close or stop Codex Desktop and run the sync.
- If the sidebar already shows recovered conversations but continuing a thread fails with missing working directory, look at `missing rollout cwd dirs before`. If missing cwd entries are listed, use `-RepairMissingCwdDirs`.
- If the missing cwd paths are outside the current user profile, do not create them by default. Review the paths first; pass `-AllowCwdOutsideUserProfile` only when they are expected local paths.

Provider sync write path:

```powershell
Get-Process Codex,ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\Codex.exe' -or $_.Path -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe' } | Stop-Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\sync-codex-provider-history.ps1"
```

Missing cwd repair path:

```powershell
Get-Process Codex,ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\Codex.exe' -or $_.Path -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe' } | Stop-Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\sync-codex-provider-history.ps1" -RepairMissingCwdDirs
```

This creates only the missing directories referenced by rollout first lines. It does not rewrite those `cwd` values, and it still verifies that `config.toml` is unchanged. By default it skips cwd paths outside `$env:USERPROFILE` to avoid creating unexpected roots on other drives or network shares.

Guardrails:

- Do not modify `config.toml`; the script checks the file hash before and after each run and fails if it changes.
- Do not install or launch external recovery tools for this workflow. The script implements the required local metadata repair directly.
- Do not patch ASAR or inject a floating session list for this symptom. A separate floating panel can show sessions but is not the official sidebar recovery mechanism and can introduce UI/encoding bugs.
- Do not sync `.codex-global-state.json` workspace/project roots by default. Doing so can expose many historical `cwd` values as empty project groups in the Desktop sidebar.
- Do not default to rewriting rollout `cwd` or forcing all missing cwd values to a fallback directory such as `Documents\Codex`. First try restoring the original missing directory path. Rewrite historical `cwd` only as a separately backed-up last resort after directory restoration fails.
- Backups are written under `$env:USERPROFILE\.codex\backups_state\history-sync-agent\<timestamp>` before SQLite or rollout writes.
- One unreadable or empty rollout first line may be skipped; treat that as a residual data issue, not a failure if SQLite and readable rollout counts align and the official sidebar shows the expected conversations.

Success criteria:

- The script logs the target provider from the current config.
- Both App and legacy SQLite stores, when present, report active and archived thread rows under that target provider.
- Rollout first-line provider counts under `sessions` and `archived_sessions` match the target provider for readable rollouts.
- `config.toml sha256 unchanged` is logged.
- Codex Desktop's official sidebar shows the recovered historical conversations after restart.
- If the symptom was a visible restored conversation that could not continue, `missing rollout cwd dirs after` reports zero or only reviewed/skipped paths, and the affected conversation can send a new turn after Desktop restart.
- The Projects/workspace area does not gain new empty project groups as a side effect.

## Important Guardrails

- The full MSIX install path removes the existing `OpenAI.Codex` package and installs a patched package. If run from inside Codex Desktop, the app can disappear or exit while the script continues. Use that path only when package-gated Desktop code must be patched; for local Chrome/Computer Use marketplace/cache/native-host/runtime failures, use the Computer Use Only workflow instead.
- The full wrapper verifies that the final package still matches the package version it patched and has `SignatureKind = Developer`. If Store replaces the package during repair, it retries once against the current package instead of reporting a false success; a second replacement fails with an actionable error.
- Do not modify `C:\Program Files\WindowsApps` in place. Use the MSIX repack script.
- Do not solve a Windows 10 `SetIsBorderRequired` / `0x80004002` screenshot failure by restoring an older Codex Desktop package or copying a helper from another runtime. The bundled helper patch profile is limited to one exact input/output hash pair, backs up the original, and refuses unknown binaries.
- Do not run the phone remote-control MSIX patch as a default repatch side effect. Use it only for phone remote-control tasks or when the user explicitly asks for that workflow.
- Do not treat every `missing field inputSchema` as an MCP problem. If CLI smoke tests pass while Desktop UI fails and the dynamic-tools ASAR asset still returns a namespace wrapper, use the Dynamic Tools Schema workflow instead of disabling unrelated MCP servers.
- Do not trust a response like `FAST_CHECK_OK` as proof of Fast Mode. Trust only the wrapper/script wire verification, which runs with an isolated temporary `CODEX_HOME`, serves the CLI's `/v1/models` probe, then captures a `/v1/responses` HTTP body or WebSocket frame and checks `service_tier=priority`. A models-only request is not proof. If `PATH` resolves only to the protected WindowsApps CLI, the patcher must use the copied work-package CLI; an explicit verification request must fail instead of silently skipping when no runnable CLI exists.
- If the app launches then immediately exits, run Electron logging and check for ASAR integrity failures:

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
$manifest = [xml](Get-Content -Raw -LiteralPath (Join-Path $pkg.InstallLocation 'AppxManifest.xml'))
$desktopExecutable = [string](($manifest.Package.Applications.Application | Select-Object -First 1).Executable)
$exe = Join-Path $pkg.InstallLocation $desktopExecutable
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
- In Codex 26.601.2237+, Fast Mode may be gated in `webview\assets\read-service-tier-for-request-*.js` as an async helper shaped like `return authMethod===\`chatgpt\` ? featureRequirements?.fast_mode !== false : false`. The patch should remove the `chatgpt`-only branch while still reading the model/host feature requirement, then verify with the wire capture.
- In Codex 26.601.2237+, Fast Mode may also stay invisible or disabled in the settings UI through `webview\assets\use-service-tier-settings-*.js`. The patch should connect the Fast UI patcher and log `fast-mode UI patch result`, not only patch the request helper.
- If the language selection reverts to English after restart, inspect the extracted webview assets for `enable_i18n`, `locale_source`, and `localeOverride`. The locale patch should log `locale i18n patch result`; do not treat a config-only language write as sufficient.
- If browser, Chrome, browser pane, or `browser_use` remains unavailable, inspect the Desktop log for `browser_use_availability_resolved`. `reason=statsig-disabled` means the local gate patch did not apply or the Store build introduced a new target shape; `reason=local-patched` means the availability gate is open and the next checks are the Chrome extension, native messaging host, and bundled plugin state.
- In Codex 26.601.2237+, the old plugin UI gate targets `533078438` and `pluginDeepLinkAuthBlocked` may be absent. Inspect `webview\assets\plugins-page-*.js` for `openPluginInstall`, `authMethod:`, and a compact assignment shaped like `{authMethod:x}=..., y=authBlocked(x),`; patch the auth-blocked variable to `false` instead of failing on missing old sidebar/skills/detail chunks.
- In Codex 26.616.3767+, `plugins-page-*.js` may insert an account-data hook between `authMethod` and the auth-blocked variable, shaped like `{authMethod:x}=authHook(),{data:y}=accountHook(),z=authBlocked(x),`. Preserve the inserted hook and patch only the auth-blocked variable to `false`.
- In Codex 26.616.3767+, the Goal slash command may no longer contain the old `3074100722` / `goals` config gate or `threadGoalObjective` anchor. If the composer computes goal availability from non-cloud/local state, for example `isGoalActionAvailable` passed through to `enabled`, treat that shape as already open instead of failing the MSIX dry run.
- In Codex 26.616.3767+, `use-is-plugins-enabled-*.js` may keep the same `featureName:\`browser_use\`` and `featureName:\`browser_use_external\`` semantics but use different minified helper names for the feature hook, statsig, and `runCodexInWsl` reads. Match the gate by shape around `featureName`, `enabled`, `isLoading`, `410262010`, and `runCodexInWsl`; do not depend on a fixed helper identifier such as `x`, `g`, or `u`.
- In Codex 26.707.3748.0, the Desktop feature sender can insert `findShortcuts` between `externalBrowserUseAllowed` and `computerUse`. Preserve that field while forcing the browser-use availability fields; do not require `computerUse` to immediately follow `externalBrowserUseAllowed`.
- In Codex 26.707.8479.0, the Electron feature receiver uses parameterized minified variables such as `o=r===\`win32\`&&n.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE...` instead of the older fixed `i` platform variable. Match the assignment, platform variable, environment object, and base feature object structurally; do not hard-code minified identifiers.
- In Codex 26.707.8479.0, `plugins-page-*.js` can place workspace/account derivations between `{authMethod:x}=...()` and the auth-blocked assignment. Locate the blocked assignment by the later `route.kind===\`manage\`` boundary and patch only that variable; preserve all intervening hooks and derived state.
- In Codex 26.519.11010+, `use-plugin-install-flow-*.js` may no longer contain `featureName:\`computer_use\``. For the Computer Use install-flow gate, locate the file with `installPlugin:async` and `openPluginInstall`, then patch the imported availability tuple so the first `.available` value for Computer Use is forced true.
- In Codex 26.707.8479.0, the Computer Use install flow can migrate into `plugin-detail-page-utils-*.js` and replace the literal `installPlugin:async` property with an `install-plugin` RPC inside a minified async mutation. Accept either anchor, require `openPluginInstall`, and patch only the first value in the three-entry availability tuple.
- In Codex 26.707.8479.0, the bundled marketplace copier can already route Windows through `copyDirectoryAllowDecryptedDestinationOnEncryptionFailure` from `windows-file-copy-*.js`. Treat that native Windows fallback as already repaired instead of replacing it with the older byte-stream fallback; still apply the independent bundled `sites` availability patch when needed.
- Do not modify `C:\Program Files\WindowsApps` in place to enable Computer Use. The Windows gate is controlled by `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`, and the helper paths are supplied through the local `computer-use@openai-bundled` plugin.
- If Computer Use or a `node_repl` Computer Use plugin fails on Windows with `windows sandbox failed: spawn setup refresh`, inspect `$env:USERPROFILE\.codex\.sandbox\sandbox.<date>.log`. If it shows `codex-windows-sandbox-setup.exe` failing with OS error 740, set `[windows] sandbox = "unelevated"`. Check `codex sandbox --help` before verification: if the help lists a `windows` command, verify with `codex sandbox windows "C:\Windows\System32\cmd.exe" /c echo OK`; only builds whose help accepts a direct command form should use `codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK`.
- If a Computer Use task fails before app interaction with `Package subpath ... is not defined by "exports"`, `Module not found: @oai/sky`, missing `setupComputerUseRuntime`, or an internal `@oai/sky` / `computer_use_client_base` import path error, treat it as local bundled plugin/runtime drift. Run `scripts\install-computer-use-local.ps1 -VerifyOnly`, then `-StrictVerifyOnly`. Do not patch `app.asar` or `resources\codex.exe` for this class unless Desktop logs also prove a UI availability gate is still closed.
- If "任意应用" is visible but disabled as organization/region unavailable, inspect `webview\assets\use-is-plugins-enabled-*.js` in the extracted ASAR. The relevant local gates are `featureName:\`computer_use\`` and Statsig `1506311413`; reapply the MSIX patch rather than editing WindowsApps in place.
- If the Computer Control page says `Computer Use 插件不可用`, check the Desktop log for `computer-use native pipe startup failed` with `missing-helper-path`, then inspect `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled\.agents\plugins\marketplace.json` and `plugins\computer-use`. If they are missing or partial, stop bundled `extension-host` processes under `$env:USERPROFILE\.codex\plugins\cache\openai-bundled`, rerun `scripts\install-computer-use-local.ps1`, restart Codex Desktop, and confirm the log ends with `computer-use native pipe startup ready`.
- If `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` fails because `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\.codex-plugin\plugin.json` is missing, run the same script with `-VerifyOnly` to repair the marketplace mirror, cached plugin copy, and `latest` link, then rerun `-StrictVerifyOnly`.
- If the failure reappears after fully quitting and reopening Codex Desktop, inspect `$env:USERPROFILE\.codex\chrome-native-hosts.json` and the real targets of `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\latest` and `browser\latest`. Stale Chrome native-host entries, or a `chrome\latest` junction that points at `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled\plugins\chrome`, can let Chrome native messaging lock the mutable marketplace mirror. The symptom is `bundled_plugins_marketplace_resolve_failed` with `EBUSY` on `plugins\chrome\extension-host\windows\x64`, followed by `helper paths changed` and `missing-helper-path`; rerun `scripts\install-computer-use-local.ps1` to stop the lock holder, rebuild stable browser/chrome cache copies, repoint the Chrome native messaging manifest to the stable cache path, and repair Computer Use.
- Do not build stable `browser`, `chrome`, `sites`, or base `computer-use` caches from the mutable `.tmp\bundled-marketplaces` mirror. Desktop can reconcile that mirror while files are being copied. Use the installed package marketplace as the stable source, then overlay the local Computer Use runtime directly into its versioned cache.
- If the failure reappears after restart with `plugin_marketplace_folder_write_failed` during `copy_plugins`, `bundled_plugins_marketplace_resolve_failed`, or `not_in_bundled_marketplace_plugin_names` uninstalling `sites@openai-bundled` / `browser@openai-bundled` / `chrome@openai-bundled`, patch only the bundled marketplace copy helper instead of running the full Fast/browser/Computer Use gate repatch. In builds where `features.sites` is false, the same targeted patch also forces the bundled `sites` descriptor locally available so the runtime marketplace keeps the full `sites,browser,chrome,computer-use,latex` set.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyBundledMarketplaceCopy -DryRun -OutputRoot "<large-local-build-root>"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyBundledMarketplaceCopy -Install -Launch -InstallPrerequisites -OutputRoot "<large-local-build-root>"
```

## Useful Wrapper Options

- `-DryRun`: verify bundle targets only; no install.
- `-NoLaunch`: install but do not start Codex Desktop.
- `-SkipFastVerify`: skip the local HTTP/WebSocket `service_tier` capture.
- `-CustomModels <id1,id2,...>`: custom model IDs forced through the Desktop model visibility filter; defaults to `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`.
- `-KeepBuild`: keep `Downloads\codex-msix-repack` for debugging.
- `-OutputRoot <path>`: optional large local build root; use it when the default output root is short on space, points at a broken junction, or should be kept off the system drive.
- `-OnlyBundledMarketplaceCopy`: patch only the Desktop bundled marketplace copy/helper availability path so Windows falls back to byte-stream copying when `fs.cp()` cannot copy bundled plugin files from WindowsApps-protected package paths, and so `sites` remains locally available when bundled availability filtering would otherwise remove it. Use this for restart-time bundled marketplace sync failures that uninstall `sites`, `browser`, or `chrome`, not for general Fast Mode or UI gates.
- `-OnlyModelExperience`: inspect and selectively repair the Fast Mode request gate, Fast Mode UI gate, and custom model visibility filter together. Use this for Fast Mode, hidden custom models, and the dependent compact Power slider. The legacy `-OnlyCustomModels` name is retained as an alias.
- `-SkipSdkCleanup`: leave Windows SDK installed.
- `-RegisterMarketplaceOnly`: only register `openai-curated-local`; do not patch Codex.
- `-PatchScript <path>`: override the bundled patch script only when testing a newer patcher.
- `-SkipComputerUse`: skip installing/verifying the local Computer Use compatibility plugin.
- `-InstallModelInstructionsFile`: optional; copy the bundled prompt asset to `$env:USERPROFILE\.codex\prompts\system-prompt.md` and set top-level `model_instructions_file` in `$env:USERPROFILE\.codex\config.toml`.
- `-ModelInstructionsSource <path>`: optional source override for `-InstallModelInstructionsFile`; defaults to `assets\system-prompt.md`.
- `-ModelInstructionsDestination <path>`: optional destination override for `-InstallModelInstructionsFile`; defaults to `$env:USERPROFILE\.codex\prompts\system-prompt.md`.

Phone remote-control script options:

- `scripts\build-remote-control-native-replacement.ps1 -WorkRoot <path>`: clone/patch/build the native replacement under the selected work root, keeping Cargo/Rustup/temp/target/source artifacts and the fallback Windows SDK C++ NuGet cache off the system drive. With both version parameters omitted, it auto-detects the installed native version from a temporary WorkRoot copy; if the detected version has no mapping, it requires explicit parameters instead of assuming 0.144.
- `-CodexSourceRef <rust-vX> -AppServerVersion <X>`: always supply these as an exact matching pair when overriding auto-detection. `0.145.0-alpha.18` is exact-tag build/install/phone end-to-end validated with Desktop `26.715.2305.0`; `0.144.0-alpha.4` has the same validation scope with Desktop `26.707.3748.0`; the dedicated `0.142.4` patch is patch-apply validated but not yet fully compiled in this workflow.
- `-PatchPathOverride <path>`: use only with an exact matching source-ref/app-server version pair, after validating that the supplied patch targets that exact source; patch apply is still checked before compilation.
- `-SkipBuild`: reuse only a previously generated binary accompanied by `codex.remote-control-build.json`. The helper verifies the exact Git commit, source ref, app-server version, patch SHA-256, Rust toolchain, target, profile, binary `--version`, and native markers; marker-only or unstamped stale binaries are rejected. It does not initialize or download the Windows SDK in this mode.
- `scripts\patch-remote-control-windows-msix.ps1 -DryRun`: patch and validate extracted package without installing, then clean successful generated artifacts.
- `-KeepWorkDir`: keep MSIX staging, ASAR extract, and script-local `npx` cache for debugging; avoid this on routine repairs because each kept run can consume multiple GB.
- `-OutputRoot <path>`: optional large local build root; use it when the default temp/output drive is short on space.
- `-ReplacementResourceCodexExe <path>`: copy in a patched native app-server binary and verify remote-control markers before packaging.
- `-Install -Launch -InstallPrerequisites`: sign, install, and relaunch the patched package after dry-run passes.

Dynamic tools schema script options:

- `scripts\patch-dynamic-tools-windows-msix.ps1 -DryRun`: extract current package, patch/verify `app-server-dynamic-tools-*.js`, run `node --check`, then clean successful generated artifacts without installing.
- `-OutputRoot <path>`: optional large local build root; use it when the system drive is short on space.
- `-Install -Launch -InstallPrerequisites`: sign, install, and relaunch the targeted dynamicTools patched package after dry-run passes.
- `-KeepWorkDir`: keep MSIX staging, ASAR extract, and script-local `npx` cache for debugging only.

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

Use this path for local Computer Use plugin/runtime repair without repacking the MSIX. It rebuilds the local `openai-bundled` marketplace mirror, repairs stable `computer-use` / `browser` / `chrome` / `sites` cache links from one pinned installed-package source, overlays the installed CUA `@oai/sky` runtime into the local Computer Use plugin, patches localized/default-value Chrome registry parsing and the Computer Use client import shape when needed, preserves a live `SKY_CUA_NATIVE_PIPE` configuration while removing stale overrides, updates the Chrome native messaging host to stable cache paths, and verifies both the client import and helper transport.

If Windows 10 reaches the native helper but screenshot capture fails specifically at `SetIsBorderRequired` with `0x80004002`, inspect the helper profile before rerunning the general local repair:

```powershell
$helperPatcher = "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-computer-use-helper-win10.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $helperPatcher
```

Only an `original-patchable` result for the documented complete `@oai/sky 0.4.20` helper SHA-256 authorizes the targeted write. Desktop `26.707.12708.0` is the end-to-end validation baseline, not a version gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $helperPatcher -Install
```

The patcher verifies the complete output hash, stores the original under `.codex\backups\computer-use-helper`, and supports `-Rollback`. After installation, continue with `-VerifyOnly`, `-StrictVerifyOnly`, and real Explorer/Task Manager Computer Use captures. Do not apply the profile to an unknown helper hash.

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
- The install log launches the patched Desktop package through its AppUserModelId, avoiding direct-executable access failures under `WindowsApps`.
- The manifest-declared Codex Desktop process stays alive from the installed package, currently `...\app\ChatGPT.exe` on newer builds and `...\app\Codex.exe` on older builds.
- Fast Mode verification reaches `/v1/responses` and logs `request wire service_tier=priority`; `/v1/models` probes alone do not pass verification.
- The patch log includes `fast-mode UI patch result` and `locale i18n patch result`, each either `patched` or `already-patched`.
- The patch log includes `custom models patch result`, and the patched model filter contains all configured custom model IDs.
- The patch log includes `browser-use gate patch result`, either `patched` or `already-patched`.
- Desktop logs show `browser_use_availability_resolved` with `available=true` and `reason=local-patched` after the patched app starts.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-curated-local]`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-bundled]` pointing at `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, and that local mirror contains the installed bundled plugins plus `computer-use`.
- Any configured local marketplace used for personal plugins has a supported `.agents\plugins\marketplace.json`; root-level `marketplace.json` alone is not enough for the current plugin CLI.
- `codex plugin list` shows `sites@openai-bundled`, `browser@openai-bundled`, `chrome@openai-bundled`, `computer-use@openai-bundled`, and `latex@openai-bundled` as `installed, enabled`.
- Recent Desktop logs show `pluginNames=["sites","browser","chrome","computer-use","latex"]` for the bundled marketplace reconcile and do not show `not_in_bundled_marketplace_plugin_names` for `sites@openai-bundled`.
- `$env:USERPROFILE\.codex\config.toml` contains `[plugins."computer-use@openai-bundled"]` with `enabled = true`.
- `codex plugin list` shows `computer-use@openai-bundled` as `installed, enabled`.
- If Chrome/browser use is required, `codex plugin list` shows `chrome@openai-bundled` and `browser@openai-bundled` as `installed, enabled`, the Chrome native messaging host manifest points to a stable cache path under `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\<version>\...` rather than `chrome\latest` or `.tmp\bundled-marketplaces`, `chrome\latest` and `browser\latest` point to stable cache version directories rather than the mutable marketplace mirror, and a smoke test can read a controlled tab title such as `Example Domain`.
- `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` is set to `1` for the current user.
- `$env:USERPROFILE\.codex\config.toml` contains `[features]` with `computer_use = true`.
- `$env:USERPROFILE\.codex\config.toml` contains `[windows]` with `sandbox = "unelevated"`, and the sandbox command syntax shown by `codex sandbox --help` succeeds.
- `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js` exists and can return screen info/screenshot.
- `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` logs `client import ok` and `helper transport ok`.
- For the supported Windows 10 screenshot-helper profile, `scripts\patch-computer-use-helper-win10.ps1` reports `patched` with SHA-256 `71A13CBC4BB333F0707D2311C99DBA54D8B24D1BBB9F7CE25C3B9386577FFDDA`, the original backup hash is `F2B2F56FCD1699B0FA32DEC3214A56A1D36B937A2ECF58CC822AB4A904551E03`, repeated static captures do not grow helper resources linearly, and dynamic captures produce changing image data.
- The patched ASAR has `webview\assets\use-is-plugins-enabled-*.js` with the Computer Use availability gate forced local-available and `webview\assets\use-plugin-install-flow-*.js` with the Computer Use install gate unblocked.
- The patched ASAR has `webview\assets\use-service-tier-settings-*.js` with the Fast Mode UI gate unblocked, the locale chunk with `enable_i18n` forced enabled, and browser_use feature chunks/main feature dispatch patched to report in-app and external browser availability locally.
- For phone remote-control repair, the patched ASAR contains `remote_control_desktop_fetch_override_used`, `remote_control_auth_token_expired_skipped`, `remote_control_mobile_setup_no_auth_redirect`, `remote_control_mobile_setup_authorize_before_enable`, `remote_control_mfa_info_403_nonblocking`, `remote_control_client_list_partial_failure_nonblocking`, `remote_control_settings_force_control_this_pc_visible`, `remote_control_settings_force_remote_control_section_visible`, and `remote_control_qm_start`.
- For phone remote-control repair with a native replacement, live `app\resources\codex.exe` contains `remote_control_app_server_isolated_oauth_used`, `remote_control_native_remote_json_first`, `remote_control_websocket_proxy_attempt`, `remote_control_websocket_proxy_connected`, `remote-control-oauth.json`, `remote.json`, and `codex.remote_control.enroll`.
- For phone remote-control device-list login errors, `scripts\refresh-remote-control-auth.py --verify-only` reports `ok: true` against `/backend-api/wham/remote/control/clients`; if the script regenerated auth, the previous `.codex\remote.json` was backed up and `.codex\auth.json` plus `config.toml` were not modified.
- For phone remote-control repair, `Settings -> Connections` shows the mobile/phone setup path, the QR code appears, phone scan no longer reports an expired Codex environment, PID/path-correlated native logs show `remote_control_websocket_proxy_connected` and status `Connected` without repeated Windows `os error 10060`, and phone-sent turns reach Desktop. Ping/Pong frame text is optional because some native versions handle those frames without logging them. If a phone-sent turn then targets the wrong model API endpoint, handle it as the post-pairing configuration case.
- For Dynamic Tools Schema repair, the patched ASAR has `webview\assets\app-server-dynamic-tools-*.js` returning flat entries containing `namespace`, `name`, `description`, and `inputSchema` instead of a namespace wrapper object, `node --check` passes for that asset, and actual Desktop new-chat/thread creation no longer logs `missing field inputSchema`.
- For Provider History Sync, both App and legacy SQLite stores report thread rows under the current provider, readable rollout first lines use the current provider, `config.toml sha256 unchanged` is logged, official Desktop conversations reappear, and no new empty project groups are introduced.
- `makeappx.exe` and `signtool.exe` are missing again if SDK cleanup was enabled.
