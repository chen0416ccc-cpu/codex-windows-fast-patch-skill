# Restriction Debug Cases

Use this reference only when the main `SKILL.md` workflow does not explain the current Codex Desktop restriction, plugin gate, Computer Use failure, browser_use failure, or Model Experience failure. Model Experience covers Fast Mode request/UI behavior, custom models hidden by the Desktop model filter, and the dependent compact Power slider. Keep the investigation evidence-based: prefer package status, config, plugin list output, Desktop logs, sandbox logs, and captured network requests over assumptions.

## Model Experience Is Partially Broken

Symptoms:

- The UI exposes Fast Mode, but requests do not receive priority behavior.
- A local smoke test returns an answer such as `FAST_CHECK_OK`.
- CLI or `/v1/models` exposes a model, but the Desktop picker still hides it.
- The compact blue-purple Power slider falls back to the legacy Model / Reasoning / Speed picker because the required Sol/Terra model and reasoning combinations were filtered out.

Checks:

- Capture the actual `/v1/responses` request made by Codex Desktop and verify `service_tier=priority` on the wire.
- If the bundled verifier reports that it did not find `service_tier`, check whether the current CLI removed `responses_websockets`. Newer CLIs can probe `/v1/models` before sending the verification request over HTTP, so the capture helper must return a usable model list, read the later `/v1/responses` body, and reject a models-only capture instead of treating it as proof of Fast Mode.
- If the upstream is CPA or another proxy, inspect the proxy-side override rules. Local capture only proves Codex sent the parameter; the proxy can still drop, rewrite, or ignore it.
- In newer Codex builds, inspect `webview\assets\read-service-tier-for-request-*.js`. A shape like `return authMethod===\`chatgpt\` ? featureRequirements?.fast_mode !== false : false` means API-key/local requests are still forced out of Fast Mode.
- Inspect `webview\assets\use-service-tier-settings-*.js` independently; Fast request wiring can be correct while the UI gate remains closed, or the UI can be open while request wiring is still wrong.
- Inspect `webview\assets\model-list-filter-*.js` for Statsig-driven `available_models` filtering. Provider discovery can succeed while the frontend still removes the model before the Power slider calculates its available combinations.

Action:

- For CPA, add an override rule for the Codex-facing model names and force `service_tier` as a string value of `priority`.
- Patch the Fast Mode gate by removing the `chatgpt`-only branch while preserving the feature-requirement lookup, then rerun wire capture.
- Run the unified Model Experience dry run so the request gate, UI gate, and model filter are checked separately and only broken components are changed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyModelExperience -DryRun -OutputRoot "<large-local-build-root>"
```

- If the dry run reports any `patched` result, install the same targeted workflow from an external executor. If all three results are `already-patched`, do not rebuild the package; continue with provider/proxy and model-cache diagnosis.
- Treat proxy configuration as part of Fast Mode validation, not as optional documentation.

## UI Gate Is Still Blocking A Feature

Symptoms:

- Plugins, Goal commands, Computer Use, or "Any App" / "任意应用" appear disabled even after config changes.
- A Store upgrade moved or renamed webview asset chunks.

Checks:

- Search extracted ASAR webview assets by stable code behavior instead of fixed filenames.
- For Computer Use, relevant patterns include `featureName:\`computer_use\``, Statsig gate `1506311413`, `installPlugin:async`, and `openPluginInstall`.
- If old plugin gate markers such as `533078438` or `pluginDeepLinkAuthBlocked` are gone, inspect `webview\assets\plugins-page-*.js` for `openPluginInstall`, `authMethod:`, and an auth-blocked assignment shaped like `{authMethod:x}=..., y=authBlocked(x),`.

Action:

- Patch the extracted ASAR through the MSIX repack workflow.
- Do not edit `C:\Program Files\WindowsApps` in place.
- Update script search logic when asset filenames drift between Codex Desktop versions.
- For the newer plugin page auth shape, force only the local auth-blocked variable to `false`; do not require the old sidebar, skills-page, and detail-page chunks to exist.

## New Chat Fails With Missing inputSchema

Symptoms:

- Codex Desktop cannot create a new conversation or local task.
- The UI shows errors such as `创建任务时出错`, `启动对话时出错`, or the phrase `missing field inputSchema`.
- The newest Desktop log contains `method=thread/start` and the phrase `missing field inputSchema`.
- The failure happens before model sampling, before Computer Use app interaction, and before phone remote-control transport.

Checks:

- Inspect the newest non-empty Desktop log under `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\<year>\<month>\<day>`.
- Check whether CLI/app-server smoke tests exercise the same path as Desktop. If `codex debug app-server send-message-v2 "只输出 OK"` or an equivalent `thread/start` smoke succeeds because it sends `dynamicTools:null`, it does not prove the Desktop UI path is healthy.
- Inspect whether the Desktop log mentions BrowserUseThreadConfig, app dynamic tools, or another Desktop-only setup step immediately before the failing `thread/start`.
- Extract or inspect the current ASAR and search `webview\assets\app-server-dynamic-tools-*.js`. If it returns `[{type:\`namespace\`, name, description, tools:[...]}]`, the Desktop frontend is sending the old namespace wrapper shape.
- Search the extracted asset for the flat target marker `namespace:yr,name:e.name,description:e.description,inputSchema:e.inputSchema`. If present, the dynamicTools schema patch is already applied and the root cause is elsewhere.
- Run `codex mcp list` and identify recently added or custom MCP servers, especially local servers that expose many tools. Do this before changing config, but do not disable MCP servers merely because the error text contains `inputSchema`.
- Back up `%USERPROFILE%\.codex\config.toml` before changing MCP sections.
- If evidence points to MCP, disable one suspect MCP server at a time by commenting or removing only its `[mcp_servers.<name>]` block and any `[mcp_servers.<name>.env]` subtable, then validate the TOML with Python `tomllib`.
- Run `codex exec --skip-git-repo-check --ephemeral --json "只输出 OK"` as a low-cost thread-start smoke test after each MCP isolation step.
- If CLI thread start succeeds but Desktop still fails, either Desktop is using stale app-server/MCP child processes or Desktop-only dynamicTools are malformed. Fully quit and relaunch Codex Desktop before escalating, then inspect the dynamic-tools ASAR asset.

Action:

- Treat `missing field inputSchema` as a decision point, not a single root cause. The two known branches are MCP schema incompatibility and Desktop frontend dynamicTools schema drift.
- For the MCP branch, keep the disabled MCP block commented in `config.toml` with a short dated note so it can be restored after the MCP server or adapter is repaired.
- For the Desktop dynamicTools branch, run the targeted script instead of the full default repatch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-dynamic-tools-windows-msix.ps1" -DryRun -OutputRoot "<large-local-build-root>"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-dynamic-tools-windows-msix.ps1" -Install -Launch -InstallPrerequisites -OutputRoot "<large-local-build-root>"
```

- After the dynamicTools branch, verify actual Desktop new-chat/thread creation or newest Desktop logs. CLI-only success is insufficient because CLI smoke tests can bypass Desktop `dynamicTools`.
- Do not run Phone Remote Control or Computer Use repair for this symptom unless separate logs prove those workflows are also broken.
- If a remote OAuth MCP such as Cloudflare also reports an `invalid_grant` during smoke tests, fix that separately; it is not the same failure as `missing field inputSchema` unless thread start still fails.

## Browser Use Or Chrome Still Shows Unavailable

Symptoms:

- Chrome or browser use appears installed but Codex Desktop says it is unavailable.
- The plugin list shows `chrome@openai-bundled` as installed/enabled, but browser actions do not appear or do not run.
- Desktop logs contain `browser_use_availability_resolved` with `available=false`, commonly with a reason such as `statsig-disabled`.

Checks:

- Confirm the patch script logged `browser-use gate patch result` as `patched` or `already-patched`.
- Inspect the newest Desktop log under `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\<year>\<month>\<day>`.
- If the log says `reason=local-patched`, the Desktop availability gate is open; continue by checking the Chrome extension, native host manifest, and plugin cache.
- If the log still says `statsig-disabled`, re-extract the ASAR and inspect targets for `featureName:\`browser_use_external\``, `featureName:\`browser_use\``, `browser-sidebar-availability-*.js`, `browser_use_availability_resolved`, and `.vite\build\main-*.js`.
- In Codex 26.707.3748.0, inspect whether the sender object includes `findShortcuts` between `externalBrowserUseAllowed` and `computerUse`. The patcher must preserve that field instead of requiring those fields to be adjacent.
- In Codex 26.707.8479.0, the Electron receiver can compute the Windows override with parameterized minified variables instead of the older fixed `i` platform variable. Match the `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` conditional by structure and preserve its Computer Use behavior while adding the browser-use overrides.
- In Codex 26.707.8479.0, the plugin page can insert workspace/account-derived assignments between the `authMethod` hook and the auth-blocked variable. Use the subsequent `kind===\`manage\`` route assignment as a bounded structural anchor instead of requiring the blocked call to be adjacent to `authMethod`.
- Check the native messaging host manifest at `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json` and the registry key `HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`.
- Check that `codex plugin list` reports `chrome@openai-bundled` as `installed, enabled`, and that the cached plugin path under `%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome` exists.

Action:

- Reapply the MSIX patch when `browser_use_availability_resolved` is still `statsig-disabled`.
- Reinstall or repair the Chrome plugin/native host when the log is `local-patched` but the browser smoke test cannot reach Chrome.
- Validate with a real browser smoke test, not just plugin-list output. A good minimal test opens a controlled tab such as `https://example.com/`, asks the extension backend for the active tab, confirms the title `Example Domain`, and then closes the temporary tab.
- Keep the distinction explicit: `local-patched` proves the Desktop gate is open; it does not prove Chrome native messaging or the extension backend is healthy.

## Computer Use Settings Says Plugin Unavailable

Symptoms:

- Computer Control settings shows `Computer Use 插件不可用`.
- Desktop logs contain `computer-use native pipe startup failed` and `missing-helper-path`.
- `codex plugin list` may show bundled plugins missing, disabled, or marketplace load errors.
- The failure comes back after fully quitting Codex Desktop and reopening it.
- A previous repair attempt made Codex Desktop exit or disappear because the agent ran the full MSIX repack for a local plugin/cache problem.

Checks:

- Run `codex plugin list` before package operations. If `sites@openai-bundled`, `chrome@openai-bundled`, `browser@openai-bundled`, or `computer-use@openai-bundled` are missing, disabled, or blocked by a marketplace snapshot error, treat that as local bundled marketplace evidence first.
- Run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` before package operations. A failure on a stale Chrome native messaging manifest, missing `latest` link, missing helper path, missing plugin file, or `@oai/sky` import/runtime path is local repair evidence.
- Inspect `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled\.agents\plugins\marketplace.json`; in current Windows builds it should retain `sites`, `browser`, `chrome`, `computer-use`, and `latex`.
- Inspect `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled\plugins\computer-use`.
- Inspect running `extension-host` processes whose paths are under `%USERPROFILE%\.codex\plugins\cache\openai-bundled`.
- Inspect `%USERPROFILE%\.codex\chrome-native-hosts.json`; remove stale entries whose `extensionHostPath` or `browserClientPath` points to a missing file.

Action:

- Do not start with the full MSIX repack for this symptom class. The full repack removes and reinstalls the `OpenAI.Codex` package and can make the running Desktop app disappear; use it only after evidence shows a Desktop ASAR/UI gate is still closed.
- Stop only those bundled `extension-host` processes when they are locking the bundled marketplace mirror.
- Rerun `scripts\install-computer-use-local.ps1`.
- If the copy fails because a file under `.tmp\bundled-marketplaces\openai-bundled` disappears mid-read, treat it as Desktop reconciliation racing the repair. Stable plugin caches must be sourced from the installed package; only the locally modified Computer Use runtime is overlaid afterward.
- Restart Codex Desktop.
- Confirm the latest Desktop log ends with `computer-use native pipe startup ready`.
- If `-StrictVerifyOnly` fails because `plugins\cache\openai-bundled\computer-use\latest\.codex-plugin\plugin.json` is missing, run `-VerifyOnly` once to rebuild the cached plugin and `latest` link, then rerun `-StrictVerifyOnly`.
- In Codex 26.707.8479.0, the Computer Use install-flow gate can move to `plugin-detail-page-utils-*.js`, where the install operation is identified by the `install-plugin` RPC rather than a literal `installPlugin:async` property. Use `openPluginInstall` plus the three-entry `.available` tuple to locate the gate.
- In Codex 26.707.8479.0, the main bundle can ship a native Windows copy path through `copyDirectoryAllowDecryptedDestinationOnEncryptionFailure` in `windows-file-copy-*.js`. Do not inject the legacy byte-stream fallback when this helper is present; only patch the separate `sites` descriptor availability if it remains gated.
- If Desktop logs show `not_in_bundled_marketplace_plugin_names` uninstalling `sites@openai-bundled`, inspect whether bundled descriptor filtering dropped `sites` because `features.sites` is false. Use the targeted bundled marketplace copy patch; do not run the phone remote-control workflow or a broad MSIX repatch for this symptom alone.
- Escalate to the MSIX workflow only if local repair succeeds but logs or extracted ASAR checks still show settings/UI availability gates are blocking Computer Use or browser_use, such as `browser_use_availability_resolved` with `reason=statsig-disabled` or Computer Use/Any App disabled by a Desktop gate.

## Bundled Marketplace Drops Sites After Restart

Symptoms:

- `sites@openai-bundled` disappears or is disabled after Codex Desktop restarts.
- Desktop logs show `not_in_bundled_marketplace_plugin_names` for `sites@openai-bundled`.
- Desktop logs show bundled marketplace `pluginNames` without `sites`, commonly `["browser","chrome","computer-use","latex"]`, even though the package resources contain a `sites` plugin.
- `browser`, `chrome`, or `computer-use` may still be present, so a Computer Use-only verification can pass while the bundled marketplace still keeps uninstalling `sites`.

Checks:

- Inspect newest Desktop logs for both the expected and broken plugin-name sets:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs'
Get-ChildItem -LiteralPath $root -Recurse -File |
  Sort-Object LastWriteTime -Descending |
  Select-String -SimpleMatch -Pattern 'pluginNames=["sites","browser","chrome","computer-use","latex"]','pluginNames=["browser","chrome","computer-use","latex"]','not_in_bundled_marketplace_plugin_names' |
  Select-Object -First 20
```

- Inspect the extracted main bundle or live ASAR for `isAvailable:({features:e})=>e.sites` near the bundled plugin descriptors. That shape means package resources can contain `sites`, but runtime filtering can still remove it when `features.sites` is false.
- Confirm that the local mirror under `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled` has five plugin directories after repair: `sites`, `browser`, `chrome`, `computer-use`, and `latex`.

Action:

- Use the targeted bundled marketplace patch with `-OnlyBundledMarketplaceCopy` and a non-system `-OutputRoot` when the user is avoiding C: drive pressure.
- After install and relaunch, run `scripts\install-computer-use-local.ps1 -VerifyOnly` to rebuild the local mirror/cache, then `-StrictVerifyOnly`.
- If `sites` was already uninstalled, rerun `install-computer-use-local.ps1 -VerifyOnly`; when the installed bundled marketplace provides `sites`, the repair re-enables it and rebuilds its stable cache automatically.
- Verify recent logs show the five-plugin set and no new `not_in_bundled_marketplace_plugin_names` for `sites`.
- Do not run Phone Remote Control scripts for this class. Do not run a full Fast/browser/Computer Use repatch unless separate logs show a closed Desktop gate such as `reason=statsig-disabled`.

## Computer Use Task Fails Before App Interaction

Symptoms:

- A Computer Use task stops before touching any app or window.
- The visible result says `Computer Use native pipe is unavailable`.
- The plugin or Node REPL error mentions `Package subpath ... is not defined by "exports"`.
- The plugin or Node REPL error mentions `Module not found: @oai/sky`, missing `setupComputerUseRuntime`, or an internal `computer_use_client_base` import failure.
- The failure starts immediately after a Codex Desktop or bundled plugin update.

Checks:

- Inspect the installed package with `Get-AppxPackage -Name OpenAI.Codex | Select-Object Version,SignatureKind,InstallLocation`.
- Check both `app\resources\app.asar` and `app\resources\codex.exe` under the current `InstallLocation`. Do not assume `codex.exe` being a PE file means the ASAR route is gone.
- Inspect `%USERPROFILE%\.codex\plugins\cache\openai-bundled\computer-use\latest\scripts\computer-use-client.mjs`.
- Inspect `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\*\bin\node_modules\@oai\sky\package.json`, especially the `exports` map. Newer runtime packages may export only `"."`, which breaks deep bare imports from plugin scripts.
- Inspect `%USERPROFILE%\.codex\config.toml` for stale `[mcp_servers.node_repl.env]` entries named `SKY_CUA_NATIVE_PIPE` or `SKY_CUA_NATIVE_PIPE_DIRECTORY`.

Action:

- Run `scripts\install-computer-use-local.ps1 -VerifyOnly` to rebuild the local bundled plugin mirror, stable cache links, CUA runtime overlay, Chrome native host paths, and config cleanup.
- Run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` immediately after. Treat `client import ok` and `helper transport ok` as the local repair success signal.
- If `-StrictVerifyOnly` fails because a cache link or plugin file is missing, rerun `-VerifyOnly` once, then rerun `-StrictVerifyOnly`.
- In 26.609-style caches, `browser\latest` or `chrome\latest` may be absent while the versioned cache directory still exists. Do not treat that as a Computer Use failure by itself; require the versioned browser/chrome plugin manifests and only validate a support-plugin `latest` junction when it exists.
- If verification succeeds but Desktop still reports native pipe unavailable, fully quit and relaunch Codex Desktop, then inspect the newest Desktop log for `computer-use native pipe startup ready`.
- Only consider a full MSIX repack when Desktop logs or UI evidence show a closed feature gate. Do not patch `resources\codex.exe` or the ASAR just because the immediate failure is an `@oai/sky` package export/import error.

## Sandbox Setup Refresh Fails With OS Error 740

Symptoms:

- Computer Use or node-based helpers fail with `windows sandbox failed: spawn setup refresh`.
- Sandbox logs show `codex-windows-sandbox-setup.exe` failed with OS error 740.

Checks:

- Inspect `%USERPROFILE%\.codex\.sandbox\sandbox.<date>.log`.
- Verify the configured sandbox mode in `%USERPROFILE%\.codex\config.toml`.

Action:

- Set `[windows] sandbox = "unelevated"`.
- Check `codex sandbox --help` before verification.
- If the help lists a `windows` command, verify with `codex sandbox windows "C:\Windows\System32\cmd.exe" /c echo OK`.
- Only builds whose help accepts a direct command form should use `codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK`.

## Self-Update Fails

Symptoms:

- The skill self-update helper cannot reach GitHub, cannot download the archive, or cannot resolve remote HEAD.

Action:

- Do not block the repair.
- Continue with the currently installed local skill.
- Mention that self-update was skipped, then rely on local scripts and local evidence.

## Manual ASAR Extraction Leaves Temp Directory

Symptoms:

- A manual `asar extract` verification succeeds, but deleting the extracted temp tree fails.
- PowerShell reports a missing nested file such as `InfoPlist.strings` while deleting extracted `node_modules`.

Action:

- First verify the target directory is under the intended temp root and has the expected `codex-*` prefix.
- If normal `Remove-Item -Recurse -Force` fails, use .NET deletion with a Windows long-path prefix: `[System.IO.Directory]::Delete("\\?\C:\path\to\temp-dir", $true)`.
- Do not use this cleanup pattern on an unverified or computed path.
