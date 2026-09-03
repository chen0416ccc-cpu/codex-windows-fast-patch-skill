# Codex Windows Fast Patch Skill

Language: [中文](README.md) | English

This is the public version of the `codex-windows-fast-patch` skill. It helps Agent-Skills-capable agents repair common Windows Codex Desktop features that break after Desktop updates.

## Features

Use this skill when Windows Codex Desktop updates cause issues like these:

- Fix missing Fast Mode, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna models, the blue-purple Power slider, and its disabled Ultra toggle under custom providers.
- Repair the UI language resetting to English after restart.
- Repair plugin entries, plugin install buttons, and plugin marketplace lists.
- Repair the in-app browser, browser pane, Chrome, or browser_use when they are unavailable.
- Repair Computer Use / computer control / Any App when it is unavailable.
- Repair Computer Use when window enumeration succeeds but a later independent call fails because the persistent helper's app-approval callback loses the `node_repl` execution context; apply the patch only to the exact documented `@oai/sky` source hash.
- Repair the exact supported Windows 10 CUA helper when screenshots fail because `SetIsBorderRequired` returns `0x80004002`, followed by a `FrameArrived` synchronous-wait deadlock after the optional interface is skipped.
- Repair native phone remote control under a third-party API login state when the entry is hidden, the QR code keeps spinning, setup redirects to ChatGPT login, Allow fails, or the phone says the Codex version is expired.
- Repair Goal entries, settings entries, or feature buttons that disappear or become disabled after updates.
- Restore local conversations in the official sidebar after switching `model_provider` / API config when the local history data still exists; if a restored conversation is visible but cannot continue because its working directory is missing, recreate the missing empty directory from the rollout `cwd`.
- Repair broken local plugin marketplace config or `codex plugin list` errors.
- Safely remove exact stale plugin and hook-state tables left in `config.toml` after a marketplace/plugin is removed. Classification is read-only by default, and writes require an absent marketplace plus no plugin evidence in bounded cache locations.
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
- `scripts/build-remote-control-native-replacement.ps1`: Builds the patched native `app\resources\codex.exe` replacement under a caller-selected work root when the native app-server rejects API-key main auth. By default it detects the installed native version from a copied executable; bundled mappings cover `0.145.0-alpha.18`, exact-tag built, installed, and phone end-to-end validated with Desktop `26.715.2305.0`; `0.144.0-alpha.4`, equivalently validated with Desktop `26.707.3748.0`; and historical patch-apply-only validated `0.142.4`. Any other version requires an exact `-CodexSourceRef` / `-AppServerVersion` pair plus a validated `-PatchPathOverride`.
- `scripts/install-computer-use-local.ps1`: Windows Computer Use and Chrome local-runtime repair reference implementation. It supports both the legacy `latest` plus plugin-local `node_modules` layout and the current versioned cache plus independent `%LOCALAPPDATA%` `cua_node` runtime, and synchronizes the outer Chrome native-host manifest, `extension-host-config.json`, and both schema-2 app-server state files.
- `scripts/patch-computer-use-node-repl-context.ps1`: Exact-hash read-only classification, installation, full-hash verification, and rollback for the supported `@oai/sky 0.6.2` helper-transport cross-call app-approval context fix.
- `scripts/patch-computer-use-helper-win10.ps1`: Read-only classification, exact-hash installation, and rollback for the supported `@oai/sky 0.4.20`, `0.5.2`, `0.6.6`, `0.6.11`, `0.6.16`, and `0.6.17` helper hashes; `26.707.12708.0`, `26.721.4979.0`, `26.803.10989.0`, `26.810.6296.0`, `26.810.7004.0`, `26.814.5167.0`, `26.814.5517.0`, `26.818.2872.0`, and `26.818.3698.0` are their end-to-end validation baselines, not version gates. Two Desktop builds ship different helper binaries under the same `0.6.16` family, and the two `0.6.17` helpers even report an identical version string while differing in whole-file hash, so profiles are selected by the complete hash and never by a version prefix. The latest `0.6.17` baseline includes eight unique static frames, twenty unique dynamic frames, and post-warm-up resource-stability checks.
- `scripts/sync-codex-provider-history.ps1`: Sync local conversation provider metadata so conversations hidden after a `model_provider` switch reappear in the official list; `-RepairMissingCwdDirs` can also repair restored conversations that cannot continue because the recorded `cwd` directory is missing. It does not modify `config.toml` or workspace/project roots by default.
- `scripts/cleanup-orphaned-plugin-config.ps1`: Classifies and removes orphaned `config.toml` plugin/hook tables for one explicit `plugin@marketplace` ID. It is read-only by default, checks the marketplace and bounded disk locations, and makes a SHA-256-verified backup before writing.
- `scripts/install-model-instructions-file.ps1`: Optional installer for the bundled `model_instructions_file` prompt asset.
- `scripts/manage-codex-backups.ps1`: Backup manager for local Codex config, MCP, skills, and marketplaces.
- `scripts/lib/asar-integrity.ps1`: Shared Electron ASAR integrity-table library used by all three MSIX patchers. It finds the launcher by content instead of by name (`Codex.exe` before 26.9xx, `ChatGPT.exe` after), rewrites the embedded hash after `asar pack`, and re-reads the executable to assert the result. An executable that references `app.asar` but exposes no parsable table is a hard failure, so a package that cannot start is never shipped.
- `scripts/lib/appx-launch.ps1`: Shared AppUserModelId launch helper for an installed package. Never start an executable inside the install directory: on 26.9xx `app\Codex.exe` is only a CLI shim and launching it produces no desktop window.
- `scripts/test-asar-integrity.ps1`: Regression suite for `lib/asar-integrity.ps1`, entirely on synthetic fixtures. It covers launcher discovery by content, the header-hash algorithm, tamper detection, repair, idempotence, multi-archive tables, read-only launchers, and the loud-failure path. `-CheckInstalledPackage` adds a read-only self-consistency check of the installed package.
- `scripts/test-staged-package-selection.ps1`: Regression suite for package selection after a Store update.
- `assets/system-prompt.md`: Bundled prompt asset used only when optional model instructions setup is requested.
- `references/restriction-debug-cases.md`: On-demand cases for restriction gates, Chrome/browser_use, Computer Use, and Fast Mode.
- `references/win10-computer-use-screenshot-backend.md`: Root cause, binary boundary, guarded workflow, and validation evidence for the Windows 10 screenshot backend.
- `references/remote-control-debug-cases.md`: On-demand cases for phone remote-control pairing, isolated auth, native app-server networking, version-expired state, and post-pairing API endpoint diagnosis.
- `references/remote-control-native-replacement.patch`: Reference Rust source patch for the phone remote-control native app-server replacement.
- `references/remote-control-native-replacement-0.145.0-alpha.18.patch`: `rust-v0.145.0-alpha.18`-specific Rust patch built, installed, and phone end-to-end validated with Desktop `26.715.2305.0`.
- `references/remote-control-native-replacement-0.142.4.patch`: Historical `rust-v0.142.4`-specific Rust patch with clean patch-apply validation only; it is not claimed as fully compiled or end-to-end validated.

## Install

The skill directory is a clone of this repository, so `git clone` it straight into your agent's skills directory. The destination depends on the harness you use; the skill itself does not care which harness it lives under:

```powershell
# Codex
git clone https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"

# Claude Code
git clone https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git "$env:USERPROFILE\.claude\skills\codex-windows-fast-patch"
```

Any other agent that supports Agent Skills works the same way: point the destination at its own skills root. The full history takes about 800 KB, less than the working tree itself.

Restart the agent afterwards so it reloads skill metadata.

If your harness installs skills through a plugin or marketplace mechanism, that copy is not a git working tree and cannot self-update; everything else keeps working.

## Usage

After installation, ask an agent that supports Agent Skills to use the `codex-windows-fast-patch` workflow for the Codex Desktop issue on the current machine.

Updating this skill is `git pull`. Before substantive work the agent runs a cheap check — `git fetch` plus `git rev-list --count 'HEAD..@{u}'` (PowerShell needs the single quotes, otherwise `@{u}` is parsed as a hashtable) — and skips the rest when the count is `0`; only a non-zero count makes it read `git log` and decide whether to pull. It checks again when a patch step fails (a missing helper profile, a pattern that no longer matches, an unrecognized Desktop build), because that is exactly the case where upstream may already carry the fix.

Local edits are not wiped out. When your edits and the update touch different files, `git pull --ff-only` fast-forwards and keeps your edits in place. When they touch the same file, git refuses the pull, names the blocking file, and leaves your edit on disk — resolve it with `git stash`, then `git pull --ff-only`, then `git stash pop` (expect conflict markers from `stash pop` if your edit and the update changed the same lines). Local commits make the branches diverge, so `--ff-only` refuses and `git pull --rebase` replays them on top of the update. Helper profiles and repair guards you added yourself are therefore safe. Change the update source with `git remote set-url origin <your-fork>`, and roll back with `git checkout <older-commit>`. When the network is unavailable the update step is skipped, the agent continues with the currently installed local version, and it states in the conclusion that the update did not run.

The scripts are reference implementations and operational templates, not a one-command fix that is guaranteed to work on every machine. A real run should first read `SKILL.md`, inspect the current Codex installation method, MSIX package path, ASAR contents, signing tools, plugin directories, and Computer Use file state, then decide whether to execute, adapt, or only borrow steps from the scripts.

## Which Runner To Use

Some repairs reinstall Codex Desktop. During reinstall, the current Codex Desktop process is closed. Do not ask the same Codex Desktop session to reinstall itself unless you are fine with the session being interrupted.

The current Codex Desktop session can usually repair these without another agent:

- Computer Use says the plugin is unavailable, shows `native pipe unavailable` or `missing-helper-path`, or breaks again after restart.
- Computer Use `list_windows` succeeds but the next `get_window_state` or `activate_window` reports `node_repl exec context not found`; classify the exact source hash first and stop on unknown hashes.
- Computer Use can enumerate windows but Windows 10 screenshots fail with `SetIsBorderRequired ... 0x80004002`; run the helper patcher only for its exact supported hash and stop on unknown hashes.
- Chrome / browser_use helper paths, plugin cache, or native-host files are broken.
- Plugin marketplace config is broken, or `codex plugin list` fails because of marketplace manifests.
- A local marketplace is missing `.agents\plugins\marketplace.json`.
- A removed personal plugin still has `[plugins."...@marketplace"]` or matching `[hooks.state."...:..."]` tables, while that marketplace is no longer configured and bounded cache locations contain no plugin directory or descriptor. Run read-only classification first, then add `-Install` explicitly.
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

Before starting from the external executor, confirm there is no global `CODEX_HOME`. Do not copy or migrate `.codex` into `.codex-cli`, and do not commit or display `auth.json`, API keys, OAuth tokens, MCP credentials, browser profiles, or other local credentials. The recommended order is: back up Desktop state with `scripts\manage-codex-backups.ps1 -Action Backup`, run read-only checks and log triage, run the relevant script with `-DryRun`, and only then use the install path such as `repatch-codex-windows.ps1` or a targeted `*-windows-msix.ps1 -Install -Launch -InstallPrerequisites` after the dry run finds and validates the intended targets. A newly downloaded Store package may be Staged only for SYSTEM; the patcher selects current-user or SYSTEM-Staged registrations from `-AllUsers` and falls back to WindowsApps directories only when that query is unavailable. Verify the `selected Codex app` log before proceeding, and use `-AppPath` only to force a specific source.

The phone remote-control install path downloads Windows SDK BuildTools from NuGet when `makeappx.exe` / `signtool.exe` are missing and keeps the cache under `-OutputRoot\.remote-control-temp`; a D-drive output root no longer falls back to `%TEMP%`. It does not force a local proxy by default; if the machine must use one, pass `-BuildToolsProxy "http://127.0.0.1:10808"` or set `CODEX_WINDOWS_SDK_BUILDTOOLS_PROXY`. Proxy URIs and credentials are not logged. If `curl download failed with exit code 7` appears, first check whether an explicitly configured local proxy is not listening.

Keep the native replacement `-WorkRoot` on the requested large non-system drive and prefer a short root. During the validated `26.715.2305.0 / 0.145.0-alpha.18` build, a long D-drive root caused a Windows path-too-long failure while Cargo checked out a Git dependency; shortening the root to a shape such as `D:\CodexData\rc145` fixed the build. On PowerShell 5.1, the helper extracts SDK NuGet packages with checked `tar.exe` and supports the actual split `c\um\x64`, `c\ucrt\x64`, `c\Include\<version>`, and `c\bin\<version>\x64` layouts.

Example request: `Use the codex-windows-fast-patch skill to inspect and repair Codex Desktop Fast Mode, language/locale, Chrome browser_use, plugin marketplace, and Computer Use availability on this Windows machine.`

Phone remote-control example request: `Use the codex-windows-fast-patch skill to repair Windows Codex Desktop phone remote control while preserving my third-party API provider and current conversation history. If large build artifacts are needed, keep them on D:\ or another non-system drive.`

Classify an orphaned plugin config in read-only mode first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\cleanup-orphaned-plugin-config.ps1" -PluginId "obsolete-helper@personal"
```

Only after it reports that the marketplace is not configured and bounded disk locations have no plugin evidence, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\cleanup-orphaned-plugin-config.ps1" -PluginId "obsolete-helper@personal" -Install
```

Expected verification after a full run:

- The `selected Codex app` and `source package` log lines identify the intended highest version; a newer Store package Staged only for SYSTEM must not be silently hidden by an older user-installed package.
- The patch log includes `fast-mode UI patch result`, `locale i18n patch result`, and `browser-use gate patch result`, each as `patched` or `already-patched`.
- Fast Mode local wire verification captures `service_tier=priority` from the `/v1/responses` HTTP body or WebSocket frame. If `codex exec` sends no request, the verifier falls back to app-server and also requires `thread/start serviceTier=priority`.
- For Browser and Computer Use repair, `codex plugin list` shows `browser`, `chrome`, and `computer-use` from `openai-bundled` as `installed, enabled`; unrelated optional plugins such as `sites`, `latex`, `deep-research`, and `visualize` retain the user's prior state. Add `-VerifyAllBundledPluginsAvailable` to the main wrapper to append an availability assertion to its normal repair or DryRun flow. It verifies that stable descriptor names and versions match the current installed package and that the CLI JSON reports those same versions. The assertion performs no network download, does not call `plugin add`, and does not enable optional plugins, but the wrapper's other repair steps may still write state. For a fully read-only check, run `install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable` directly. The assertion compares against the package's own `app\resources\plugins\openai-bundled` manifest, so it fails with `stable bundled marketplace descriptor set does not match the installed package` whenever account-side feature flags make Desktop materialize fewer descriptors than the package ships. On a third-party provider or API-key account that is expected rather than a repair target: Desktop `26.825.6671.0` ships ten descriptors while such an account materializes eight, and the missing `unified-computer-use` (gated on `browserUseTinysky`, also `hidden` and empty on Windows) and `user-writing` (gated on `userWriting` plus a ChatGPT-account user setting) are unreachable there. Verify the plugins the requested repair actually needs instead, and record the gap and its cause in the report.
- For a `node_repl exec context not found` repair, `StrictVerifyOnly` reports the verified helper-transport patch hash. Then, after the call that starts the helper, at least two later independent calls must activate and capture the same stable window, and the image content must match that target. `list_windows`, a screenshot count, or a PNG file alone is not acceptance.
- When the repair runs from external PowerShell, VS Code, or another environment without a Desktop `node_repl` kernel, real Computer Use acceptance can instead use several short-lived processes started from the current `cua_node` runtime's own `node.exe`: import the official sky entry and touch an export while `globalThis.nodeRepl` is still `undefined`, then assign `{ config: {}, createElicitation }` to answer the helper's approval request, then capture with `activate_window({ window: { app, id } })` and `get_window_state({ window, include_screenshot: true, include_text: true })`. Images arrive as `screenshots[].url` data URLs, commonly `image/jpeg`; sky has no separate screenshot method. State in the report that this substitute path did not exercise the in-app approval UI. Chrome/browser smoke tests cannot be substituted this way, because `browser-client.mjs` requires `globalThis.nodeRepl.rpc` and only the Desktop Node REPL provides that trusted channel; a hand-written `rpc` has no browser service behind it, and since `sky.js` picks its transport from the same property, defining `rpc` also moves Computer Use off the local helper client onto that fake channel. In that case report the browser layer as gate-open with configuration, manifest, cache, and registry verified, and say plainly that the tab read was not run.
- Desktop logs retain the current package's bundled descriptor names and do not use `not_in_bundled_marketplace_plugin_names` to remove a plugin the user had already installed. Descriptor presence does not mean the plugin is installed.
- Desktop logs show `browser_use_availability_resolved` with `available=true` and `reason=local-patched` when browser use is part of the repair.
- If the Windows 10 screenshot helper is in scope, the patcher reports the validated patched SHA-256, and real Explorer first/repeated captures, dynamic Task Manager frames, accessibility text, window enumeration, and post-warm-up resource stability all pass.
- If Chrome control is required, `codex plugin list` shows `chrome@openai-bundled` as `installed, enabled`; the native messaging host manifest path and registry value point to the current stable cache; `allowed_origins` exactly matches the top-level IDs in the cache's `scripts\extension-ids.json`; and `extension-host-config.json` contains a user-local `codex.exe` matching the current package plus `node.exe` / `node_repl.exe` from the same current runtime. Both `%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json` and `%USERPROFILE%\.codex\chrome-native-hosts-v2.json` must also contain the current version, official identity hashes, and existing cache/runtime paths. The stable marketplace and versioned-cache `browser-client.mjs` files must exactly match the installed package SHA-256. Trust must then validate through either the legacy `app.asar` hash list, the current `NODE_REPL_TRUSTED_SERVICES` plus `browserServicePath` service contract, or the complete `26.814` native-host path contract. If the stable cache resolves through a junction outside `CODEX_HOME`, both the user-level and Desktop-generated `NODE_REPL_TRUSTED_CODE_PATHS` values must contain the resolved physical marketplace/cache roots, and the installed ASAR must contain `CODEX_NODE_REPL_TRUSTED_PATHS_V1`. `setupBrowserRuntime()` must succeed, and `agent.browsers.get("chrome")` must return the real Chrome extension backend. A smoke test can then read a controlled tab title such as `Example Domain`. When Chrome is not running, launch it automatically without requesting additional user authorization, then validate `https://example.com/`, its `Example Domain` title, and its single matching `h1`.
- If phone remote control is repaired, Connections shows the phone setup path, QR appears, phone scan does not report an expired Codex environment, WindowsApps PID/path-correlated native logs show `remote_control_websocket_proxy_connected` and `Connected` without repeated `os error 10060`, and phone-created turns reach Desktop. Some native versions handle Ping/Pong silently, so frame log text is not the sole success criterion.
- If conversation visibility is repaired, `sync-codex-provider-history.ps1` shows App/legacy SQLite stores and readable rollouts aligned to the current `model_provider`, logs `config.toml sha256 unchanged`, official Desktop conversations reappear, and no empty project groups are introduced. If repairing visible-but-uncontinuable conversations, `missing rollout cwd dirs after` is zero or contains only reviewed skipped paths, and the affected conversation can send a new message after Desktop restart.
- For orphaned plugin config cleanup, the log first reports read-only classification or an explicit refusal reason. A successful `-Install` run reports the SHA-256-verified backup, valid TOML, no UTF-8 BOM, and absence of exact plugin/hook tables while preserving similar IDs and unrelated tables.

## Backup Management

Repair scripts automatically back up the previous `config.toml` into `.codex\backups\config\` before writing it. To manually back up or migrate important local Codex state, use the standalone backup manager:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\manage-codex-backups.ps1" -Action Backup
```

List existing backups:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\manage-codex-backups.ps1" -Action List
```

Restore from a backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\manage-codex-backups.ps1" -Action Restore -BackupPath "<backup path>"
```

By default, the backup includes custom skills, marketplaces, `config.toml`, extracted `mcp_servers.json`, and `chrome-native-hosts.json`, while excluding easy-to-grow directories such as `.git`, `node_modules`, build outputs, and virtual environments. Use `-IncludeDependencyDirs` only when an exact offline dependency copy is needed; plugin cache and `.tmp\bundled-marketplaces` can also be large, so include them only when needed with `-IncludePluginCache` or `-IncludeTmpBundledMarketplaces`.

## Acknowledgements

Thanks to the [LinuxDo community](https://linux.do/) for the discussions and feedback around this workflow.
