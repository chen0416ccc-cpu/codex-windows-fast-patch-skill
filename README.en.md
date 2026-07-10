# Codex Windows Fast Patch Skill

Language: [中文](README.md) | English

This is the public version of the `codex-windows-fast-patch` skill. It helps Agent-Skills-capable agents repair common Windows Codex Desktop features that break after Desktop updates.

## Features

Use this skill when Windows Codex Desktop updates cause issues like these:

- Repair Fast Mode / Priority Mode when it is hidden, disabled, or does not actually take effect.
- Repair the UI language resetting to English after restart.
- Repair plugin entries, plugin install buttons, and plugin marketplace lists.
- Repair the in-app browser, browser pane, Chrome, or browser_use when they are unavailable.
- Repair Computer Use / computer control / Any App when it is unavailable.
- Repair Computer Use errors such as `native pipe unavailable`, `missing-helper-path`, broken plugin cache, or broken helper paths.
- Repair `openai-bundled` marketplace drift where the runtime marketplace drops `sites` or keeps uninstalling `sites@openai-bundled` after restart.
- Repair native phone remote control under a third-party API login state when the entry is hidden, the QR code keeps spinning, setup redirects to ChatGPT login, Allow fails, or the phone says the Codex version is expired.
- Repair Goal entries, settings entries, or feature buttons that disappear or become disabled after updates.
- Repair Desktop new-chat/thread-start failures caused by `dynamicTools` schema drift, including `missing field inputSchema` when the CLI smoke path still works.
- Restore local conversations in the official sidebar after switching `model_provider` / API config when the local history data still exists; if a restored conversation is visible but cannot continue because its working directory is missing, recreate the missing empty directory from the rollout `cwd`.
- Repair a specifically identified old conversation whose local `model` / `reasoning_effort` remains stale while Desktop already displays or requests a new model. This tool does not repair server-side model stream disconnects.
- Repair broken local plugin marketplace config or `codex plugin list` errors.
- Optionally back up and restore local Codex config, skills, marketplaces, and related state.
- Automatically update this skill to the latest version before each repair attempt.

## Platform Support

This skill supports Windows only.

It depends on the Windows Store / MSIX package layout, PowerShell, `Get-AppxPackage`, `makeappx.exe`, `signtool.exe`, Windows user environment variables, and Windows Computer Use helper paths.

Do not run it on macOS. A macOS version needs a separate workflow for the Codex `.app` bundle, ASAR extraction and repacking, `codesign` or quarantine handling, shell scripts, and macOS-specific Computer Use availability gates.

## Files

- `SKILL.md`: Agent skill entrypoint.
- `agents/openai.yaml`: Agent configuration.
- `scripts/repatch-codex-windows.ps1`: Workflow reference script.
- `scripts/patch_codex_fast_mode_windows_msix.ps1`: MSIX / ASAR patch reference implementation.
- `scripts/patch-dynamic-tools-windows-msix.ps1`: Targeted MSIX / ASAR repair for Desktop `dynamicTools` schema drift that causes `missing field inputSchema` on new chat/thread start.
- `scripts/patch-dynamic-tools-schema.cjs`: Electron bundle patcher used by the dynamicTools MSIX script.
- `scripts/patch-remote-control-windows-msix.ps1`: Phone remote-control MSIX / ASAR patch and marker verification reference implementation.
- `scripts/patch-remote-control-asar.cjs`: Phone remote-control Electron bundle patcher used by the MSIX script.
- `scripts/build-remote-control-native-replacement.ps1`: Builds the patched native `app\resources\codex.exe` replacement under a caller-selected work root when the native app-server rejects API-key main auth; use `-CodexSourceRef` and `-AppServerVersion` to build a replacement whose app-server version matches the original native binary when the phone reports a version-expired state.
- `scripts/install-computer-use-local.ps1`: Windows Computer Use local compatibility reference implementation.
- `scripts/sync-codex-provider-history.ps1`: Sync local conversation provider metadata so conversations hidden after a `model_provider` switch reappear in the official list; `-RepairMissingCwdDirs` can also repair restored conversations that cannot continue because the recorded `cwd` directory is missing. It does not modify `config.toml` or workspace/project roots by default.
- `scripts/sync-codex-thread-model.ps1`: Synchronize local `model` and `reasoning_effort` state for explicitly selected active user threads. It previews by default; `-Apply` is required to write SQLite and the matching rollout after creating timestamped backups.
- `scripts/install-model-instructions-file.ps1`: Optional installer for the bundled `model_instructions_file` prompt asset.
- `scripts/manage-codex-backups.ps1`: Backup manager for local Codex config, MCP, skills, and marketplaces.
- `scripts/update-skill-from-github.ps1`: Best-effort self-update script that syncs the latest GitHub version before use.
- `assets/system-prompt.md`: Bundled prompt asset used only when optional model instructions setup is requested.
- `references/restriction-debug-cases.md`: On-demand cases for restriction gates, Chrome/browser_use, Computer Use, and Fast Mode.
- `references/remote-control-debug-cases.md`: On-demand cases for phone remote-control pairing, isolated auth, native app-server networking, version-expired state, and post-pairing API endpoint diagnosis.
- `references/remote-control-native-replacement.patch`: Reference Rust source patch for the phone remote-control native app-server replacement.

## Install

Clone this repository, open PowerShell in the repository root, then copy only the skill files:

```powershell
$source = (Get-Location).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
  throw 'Run this command from the codex-windows-fast-patch-skill repository root.'
}

$dest = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Copy-Item -Force -LiteralPath (Join-Path $source 'SKILL.md') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'agents') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'scripts') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'references') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'assets') -Destination $dest
```

After installing into Codex, restart Codex so it reloads skill metadata.

## Usage

After installation, ask an agent that supports Agent Skills to use the `codex-windows-fast-patch` workflow for the Codex Desktop issue on the current machine.

This skill supports self-updating: before each substantive use, the agent first tries to check GitHub and sync the latest version, so you do not need to repeatedly return to GitHub and pull updates manually. This keeps the local skill as close as possible to the latest known workflow for newly discovered issues; if the network is unavailable, GitHub cannot be reached, or the download fails, that update step is skipped and the agent should continue with the currently installed local version.

The scripts are reference implementations and operational templates, not a one-command fix that is guaranteed to work on every machine. A real run should first read `SKILL.md`, inspect the current Codex installation method, MSIX package path, ASAR contents, signing tools, plugin directories, and Computer Use file state, then decide whether to execute, adapt, or only borrow steps from the scripts.

## Which Runner To Use

Some repairs reinstall Codex Desktop. During reinstall, the current Codex Desktop process is closed. Do not ask the same Codex Desktop session to reinstall itself unless you are fine with the session being interrupted.

The current Codex Desktop session can usually repair these without another agent:

- Computer Use says the plugin is unavailable, shows `native pipe unavailable` or `missing-helper-path`, or breaks again after restart.
- Chrome / browser_use helper paths, plugin cache, or native-host files are broken.
- Plugin marketplace config is broken, or `codex plugin list` fails because of marketplace manifests.
- A local marketplace is missing `.agents\plugins\marketplace.json`.
- Old local conversations disappear after switching `model_provider` / API config, but `sessions`, `archived_sessions`, or `state_5.sqlite` still contain the data. Use provider history sync first; this does not require an MSIX reinstall.
- Old conversations are visible again, but continuing one reports a missing current working directory or `invalid codex request`. First run the provider history sync dry-run and inspect `missing rollout cwd dirs before`, then use `-RepairMissingCwdDirs` to recreate the original missing directories recorded in rollout metadata.
- You only need backup/restore work or the optional custom model instructions setup.
- Phone remote control already pairs, but phone-created turns hit the wrong model API endpoint. Treat this as a post-pairing configuration diagnosis: inspect the actual request URL and current config before changing anything.

Use another agent, external PowerShell, the Codex extension inside VS Code/Antigravity, or any environment that will not be closed by the Codex Desktop reinstall for these:

- Fast Mode / Priority Mode is hidden or not taking effect.
- The UI language resets to English after restart.
- Plugin entries, install buttons, Goal entries, or Computer Control `Any App` are greyed out or missing.
- The in-app browser, browser pane, Chrome, or browser_use is hidden or disabled by Desktop-side gates.
- The bundled runtime marketplace keeps dropping `sites`, or Desktop logs show `pluginNames` without `sites` plus `not_in_bundled_marketplace_plugin_names` for `sites@openai-bundled`.
- Phone remote control is hidden, the QR keeps spinning, setup redirects to ChatGPT login, Allow fails, or the phone reports an expired Codex version.
- Any repair that needs a full repatch, MSIX repack, Developer-signed package install, `app.asar` replacement, or `resources\codex.exe` replacement.

Simple rule: if the repair stops, uninstalls, reinstalls, or relaunches Codex Desktop, run it from another agent or external PowerShell. If it only changes local config, plugin cache, marketplace files, backups, or verification, the current Codex Desktop session can usually handle it.

## Using The VS Code Codex Extension As An External Executor

On Windows, if a repair will stop, uninstall, reinstall, repackage the MSIX, replace `app.asar`, replace `resources\codex.exe`, or restart Codex Desktop, run it from the VS Code Codex extension, external PowerShell, or another agent environment that will not be interrupted by the Desktop restart.

The target is always the Codex Desktop state directory: by default `$env:USERPROFILE\.codex`. Do not treat an isolated CLI wrapper as the Desktop execution environment. If a wrapper sets `CODEX_HOME` to `$env:USERPROFILE\.codex-cli` or another isolated directory, that is CLI state, not Desktop plugin, marketplace, MCP, remote-control, or login state.

Before starting from the external executor, confirm there is no global `CODEX_HOME`. Do not copy or migrate `.codex` into `.codex-cli`, and do not commit or display `auth.json`, API keys, OAuth tokens, MCP credentials, browser profiles, or other local credentials. The recommended order is: back up Desktop state with `scripts\manage-codex-backups.ps1 -Action Backup`, run read-only checks and log triage, run the relevant script with `-DryRun`, and only then use the install path such as `repatch-codex-windows.ps1` or a targeted `*-windows-msix.ps1 -Install -Launch -InstallPrerequisites` after the dry run finds and validates the intended targets.

The phone remote-control install path downloads Windows SDK BuildTools from NuGet when `makeappx.exe` / `signtool.exe` are missing. It does not force a local proxy by default; if the machine must use one, pass `-BuildToolsProxy "http://127.0.0.1:10808"` or set `CODEX_WINDOWS_SDK_BUILDTOOLS_PROXY`. If `curl download failed with exit code 7` appears, first check whether an explicitly configured local proxy is not listening.

Example request: `Use the codex-windows-fast-patch skill to inspect and repair Codex Desktop Fast Mode, language/locale, Chrome browser_use, plugin marketplace, and Computer Use availability on this Windows machine.`

Phone remote-control example request: `Use the codex-windows-fast-patch skill to repair Windows Codex Desktop phone remote control while preserving my third-party API provider and current conversation history. If large build artifacts are needed, keep them on D:\ or another non-system drive.`

Expected verification after a full run:

- The patch log includes `fast-mode UI patch result`, `locale i18n patch result`, and `browser-use gate patch result`, each as `patched` or `already-patched`.
- Fast Mode wire verification captures `service_tier=priority` in Codex Desktop's `/v1/responses` request.
- `codex plugin list` shows `sites`, `browser`, `chrome`, `computer-use`, and `latex` from `openai-bundled` as `installed, enabled` when bundled plugins are part of the repair.
- Desktop logs show the bundled marketplace retaining `pluginNames=["sites","browser","chrome","computer-use","latex"]` and no new `not_in_bundled_marketplace_plugin_names` entry for `sites`.
- Desktop logs show `browser_use_availability_resolved` with `available=true` and `reason=local-patched` when browser use is part of the repair.
- If Chrome control is required, `codex plugin list` shows `chrome@openai-bundled` as `installed, enabled`, the native messaging host manifest points to existing files, and a smoke test can read a controlled tab title such as `Example Domain`.
- If phone remote control is repaired, Connections shows the phone setup path, QR appears, phone scan does not report an expired Codex environment, native logs show remote-control WebSocket ping/pong/ack, and phone-created turns reach Desktop.
- If conversation visibility is repaired, `sync-codex-provider-history.ps1` shows App/legacy SQLite stores and readable rollouts aligned to the current `model_provider`, logs `config.toml sha256 unchanged`, official Desktop conversations reappear, and no empty project groups are introduced. If repairing visible-but-uncontinuable conversations, `missing rollout cwd dirs after` is zero or contains only reviewed skipped paths, and the affected conversation can send a new message after Desktop restart.

## Backup Management

Repair scripts automatically back up the previous `config.toml` into `.codex\backups\config\` before writing it. To manually back up or migrate important local Codex state, use the standalone backup manager:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

List existing backups:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action List
```

Restore from a backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Restore -BackupPath "<backup path>"
```

By default, the backup includes custom skills, marketplaces, `config.toml`, extracted `mcp_servers.json`, and `chrome-native-hosts.json`, while excluding easy-to-grow directories such as `.git`, `node_modules`, build outputs, and virtual environments. Use `-IncludeDependencyDirs` only when an exact offline dependency copy is needed; plugin cache and `.tmp\bundled-marketplaces` can also be large, so include them only when needed with `-IncludePluginCache` or `-IncludeTmpBundledMarketplaces`.

## Acknowledgements

Thanks to the [LinuxDo community](https://linux.do/) for the discussions and feedback around this workflow.
