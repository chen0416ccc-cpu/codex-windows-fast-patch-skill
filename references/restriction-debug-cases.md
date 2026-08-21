# Restriction Debug Cases

Use this reference only when the main `SKILL.md` workflow does not explain the current Codex Desktop restriction, plugin gate, Computer Use failure, browser_use failure, or Model Experience failure. Model Experience covers Fast Mode request/UI behavior, custom models hidden by the Desktop model filter, and the dependent compact Power slider. Keep the investigation evidence-based: prefer package status, config, plugin list output, Desktop logs, sandbox logs, and captured network requests over assumptions.

## Model Experience Is Partially Broken

Symptoms:

- The UI exposes Fast Mode, but requests do not receive priority behavior.
- A local smoke test returns an answer such as `FAST_CHECK_OK`.
- CLI or `/v1/models` exposes a model, but the Desktop picker still hides it.
- The compact blue-purple Power slider falls back to the legacy Model / Reasoning / Speed picker because the required Sol/Terra model and reasoning combinations were filtered out.
- The compact slider is present and models advertise Ultra, but Settings -> Configuration -> "Ultra in model picker slider" is disabled under `openai-custom`. In current builds the control can still depend on ChatGPT `userSettings()` and `setUltraEffortEnabled()` even though the models themselves come from the local app-server.

Checks:

- Capture the actual `/v1/responses` request made by Codex Desktop and verify `service_tier=priority` on the wire.
- If the bundled verifier reports that it did not find `service_tier`, check whether the current CLI removed `responses_websockets`. Newer CLIs can probe `/v1/models` before sending the verification request over HTTP, so the capture helper must return a usable model list, read the later `/v1/responses` body, and reject a models-only capture instead of treating it as proof of Fast Mode.
- If the upstream is CPA or another proxy, inspect the proxy-side override rules. Local capture only proves Codex sent the parameter; the proxy can still drop, rewrite, or ignore it.
- In newer Codex builds, inspect `webview\assets\read-service-tier-for-request-*.js`. A shape like `return authMethod===\`chatgpt\` ? featureRequirements?.fast_mode !== false : false` means API-key/local requests are still forced out of Fast Mode.
- Inspect `webview\assets\use-service-tier-settings-*.js` independently; Fast request wiring can be correct while the UI gate remains closed, or the UI can be open while request wiring is still wrong.
- Inspect `webview\assets\model-list-filter-*.js` for Statsig-driven `available_models` filtering. Provider discovery can succeed while the frontend still removes the model before the Power slider calculates its available combinations.
- Inspect the asset containing `chatgpt-user-settings`, `model_picker_persists_ultra_effort`, and `showUltraInModelPickerSlider`. A settings control shaped like `disabled: data == null || mutation.isPending` is permanently disabled when a custom provider has no ChatGPT account user-settings response. The local TOML key alone is not enough if the build uses it only as a one-time migration flag.
- Codex Desktop `26.721.3996.0` can merge the Fast UI gate and model-list filter into `webview\assets\app-initial-*.js`. Match the same stable behavior (`isServiceTierAllowed`, `available_models`, `useHiddenModels`, and `supportedReasoningEfforts`) before concluding that the gate was removed.
- Codex Desktop `26.810.4967.0` adds a `model !== codex-auto-review` guard before the hidden-model ternary: `available?.has(model.model) === true || model.model !== codex-auto-review && (showHidden && !customProvider && authMethod !== amazonBedrock ? availableModels.has(model.model) : !model.hidden)`. An older patcher that only recognizes the parenthesized `amazonBedrock` form fails with `could not find custom model visibility filter in extracted assets`; treat that as matcher drift, not evidence that custom-model filtering disappeared.

Action:

- For CPA, add an override rule for the Codex-facing model names and force `service_tier` as a string value of `priority`.
- Patch the Fast Mode gate by removing the `chatgpt`-only branch while preserving the feature-requirement lookup, then rerun wire capture.
- Patch Ultra persistence with a guarded fallback: keep the official account API for successful ChatGPT user-settings queries, but on query failure return a local-backed state, write `show-ultra-in-model-picker-slider` locally, and do not let the one-time migration clear that local value after a failed remote write. Verify both the toggle state after restart and Ultra's presence in the actual compact slider.
- When adding support for the `26.810` visibility predicate, retain the historical conditional and `amazonBedrock` predicate shapes. Run `scripts\test-custom-model-visibility-patterns.ps1 -TemporaryRoot <D-drive-child>` before a real-package dry run so old Store builds remain patchable.
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
- In Codex Desktop `26.721.3996.0`, Browser sidebar availability can also move into `webview\assets\app-initial-*.js`; identify it by `in_app_browser`, the experimental-features query, and the `enabled !== false` result rather than by the old `browser-sidebar-availability-*` filename.
- For Computer Use, relevant patterns include `featureName:\`computer_use\``, Statsig gate `1506311413`, `installPlugin:async`, and `openPluginInstall`.
- If old plugin gate markers such as `533078438` or `pluginDeepLinkAuthBlocked` are gone, inspect `webview\assets\plugins-page-*.js` for `openPluginInstall`, `authMethod:`, and an auth-blocked assignment shaped like `{authMethod:x}=..., y=authBlocked(x),`.

Action:

- Patch the extracted ASAR through the MSIX repack workflow.
- Do not edit `C:\Program Files\WindowsApps` in place.
- Update script search logic when asset filenames drift between Codex Desktop versions.
- If the unified command registry scores `title`, `id`, and `searchAliases`, `/goal` already matches the Goal command id and the legacy slash-command scorer does not need patching.
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
- In Codex 26.818.2872.0, the sender and the Electron receiver both insert `browserExtensions` between `browserPane` and `externalBrowserUse`. The sender rewrite is value-only, so the new key survives into the patched text and the old adjacency-based patched-state literal stops matching: a second patch run on an already-patched install reports `browser-use-desktop-feature-sender-patch-target-not-found` even though the install is correct. Keep a bounded key slot on both sides of `browserPane` in the rewrite, the patched-state check, and the candidate-file detector. `scripts/test-desktop-feature-slot-patterns.ps1` pins the slot and no-slot shapes.
- In Codex 26.707.8479.0, the Electron receiver can compute the Windows override with parameterized minified variables instead of the older fixed `i` platform variable. Match the `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` conditional by structure and preserve its Computer Use behavior while adding the browser-use overrides.
- In Codex 26.707.8479.0, the plugin page can insert workspace/account-derived assignments between the `authMethod` hook and the auth-blocked variable. Use the subsequent `kind===\`manage\`` route assignment as a bounded structural anchor instead of requiring the blocked call to be adjacent to `authMethod`.
- Check the native messaging host manifest at `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json` and the registry key `HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`.
- Check that `codex plugin list` reports `chrome@openai-bundled` as `installed, enabled`, and that the cached plugin path under `%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome` exists.

Action:

- Reapply the MSIX patch when `browser_use_availability_resolved` is still `statsig-disabled`.
- When the log is `local-patched` but browser setup fails before discovery, check the browser-client trusted hash before reinstalling an already healthy extension or native host.
- Validate with a real browser smoke test, not just plugin-list output. A good minimal test opens a controlled tab such as `https://example.com/`, asks the extension backend for the active tab, confirms the title `Example Domain`, and then closes the temporary tab.
- Keep the distinction explicit: `local-patched` proves the Desktop gate is open; it does not prove Chrome native messaging or the extension backend is healthy.

## Browser Client Lacks Privileged Node REPL Capabilities

Symptoms:

- Importing the current bundled `scripts\browser-client.mjs` fails immediately with `Browser use requires privileged node_repl capabilities` before browser discovery, tab listing, or Chrome native-host communication.
- The model-written JavaScript cell exposes ordinary `nodeRepl` fields such as `cwd`, `env`, `requestMeta`, `write`, `setResponseMeta`, and `emitImage`; that root object intentionally does not expose `nodeRepl.config`.
- Chrome can still be installed and running while the extension, native-host manifest, registry entry, and app-server paths all pass their official diagnostics.

Checks:

- Do not classify the task as unprivileged from the root cell's `nodeRepl` properties alone. Legacy Node REPL builds inject the privileged bridge only into a browser-client module whose SHA-256 matches `NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S`; `26.814`-style Desktop builds instead deliver the packaged client path through the official Chrome native host.
- Compare the installed package's `plugins\chrome\scripts\browser-client.mjs` SHA-256 with the active stable marketplace and versioned cache copies. Any byte rewrite changes the hash and makes the browser client run in the ordinary untrusted module context.
- On a legacy build, confirm the packaged browser-client SHA-256 appears in the current installed `app.asar` trusted browser-client list. In Codex 26.803.10989.0, the packaged hash was `8676FACA...C3B8FC`; a prior local rewrite that replaced `import{env as ...}from"node:process"` with `processShim.env` produced `0E1F364D...6AFF7A0` and caused this exact failure.
- On a `26.814`-style build with no ASAR hash, require all native-host contract markers (`browserClientPath`, `browserServicePath`, `codex-host-chunked-message-v1`, and the native-host missing-path diagnostic). Then verify that `extension-host-config.json` points to the stable current-version packaged client and that both schema-2 state files bind `browserClientPath` plus `browserServicePath` to that same stable cache. A partial marker set or client-only v2 entry is not enough.
- If the failure names `Trusted RPC dependency must resolve within a configured trusted code path` and the named C-drive cache is a junction, resolve the junction target before comparing roots. Node validates the physical D-drive target, while an unpatched `26.814` Desktop regenerates `NODE_REPL_TRUSTED_CODE_PATHS` from only `CODEX_HOME` and runtime `node_modules`, overwriting a one-time config edit on restart.
- Run the current Chrome plugin's read-only diagnostics with the matching current CUA Node runtime: `scripts\chrome-is-running.js --browser chrome --check`, `scripts\installed-browsers.js --json`, `scripts\check-extension-installed.js --browser chrome --json`, and `scripts\check-native-host-manifest.js --browser chrome --json`.
- If the side panel previously reported a missing `nodePath`, separately verify the current `extension-host-config.json` contains existing `codexCliPath`, `nodePath`, and `nodeReplPath` values, and rerun `install-computer-use-local.ps1 -StrictVerifyOnly`.
- Keep this error distinct from `Chrome browser is unavailable`, a missing or disabled extension, a bad native-host registry path, missing origins, and the side-panel `nodePath` manifest error. A missing privileged task capability occurs before those transports are used.

Action:

- Do not patch `browser-client.mjs`, fabricate `nodeRepl.config`, or add the modified hash to `app.asar`. Preserve the vendor trust contract instead.
- Run `install-computer-use-local.ps1 -VerifyOnly`. The repair restores the exact packaged browser-client bytes into the stable marketplace and versioned cache; `-StrictVerifyOnly` requires those hashes to match and validates either the legacy ASAR hash contract or the complete `26.814` native-host path contract.
- For an external physical cache root, require the installer to set the resolved marketplace/cache roots in the user-level `NODE_REPL_TRUSTED_CODE_PATHS`, then run the full MSIX patcher and require `CODEX_NODE_REPL_TRUSTED_PATHS_V1` in the installed ASAR. After restart, the Desktop-generated config must contain the original roots plus the physical external roots; only then retry browser setup.
- Reset the current Node REPL kernel after repair, import the active cached browser client, require `setupBrowserRuntime()` to succeed, and confirm `agent.browsers.get("chrome")` returns the real Chrome extension backend.
- Finish with a real controlled page smoke test: open `https://example.com/`, verify the final URL, title `Example Domain`, exactly one `h1`, and heading text `Example Domain`, then close the temporary tab.
- If the official diagnostics fail, repair the concrete extension/native-host problem instead and rerun the same diagnostics before attempting browser-client setup again.

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
- Read `[marketplaces.openai-bundled].source` from `config.toml`, then inspect `.agents\plugins\marketplace.json` under that stable root and compare its names with the current package manifest. Descriptor presence means available, not installed.
- Inspect `plugins\computer-use` under the configured stable marketplace. Do not use the Desktop-owned `.tmp\bundled-marketplaces` copy as the final configured source.
- Inspect running `extension-host` processes whose paths are under `%USERPROFILE%\.codex\plugins\cache\openai-bundled`.
- Inspect `%USERPROFILE%\.codex\chrome-native-hosts.json`; remove stale entries whose `extensionHostPath` or `browserClientPath` points to a missing file.
- If the browser files and versioned cache exist but `codex plugin list` still reports `browser@openai-bundled` as `not installed`, do not treat another direct TOML write as a durable install. Desktop reconciliation can prune that enabled entry again because the CLI install record was never created.
- If `codex plugin marketplace add` fails with `invalid marketplace file ...marketplace.json: expected value at line 1 column 1`, read the first three bytes of that file before suspecting its contents. A UTF-8 BOM makes the Rust JSON parser reject the whole document, and comparing the file with its source is misleading because PowerShell reads a BOM-prefixed file back without complaint.

Action:

- Do not start with the full MSIX repack for this symptom class. The full repack removes and reinstalls the `OpenAI.Codex` package and can make the running Desktop app disappear; use it only after evidence shows a Desktop ASAR/UI gate is still closed.
- Stop only those bundled `extension-host` processes when they are locking the bundled marketplace mirror.
- Rerun `scripts\install-computer-use-local.ps1`.
- Let the repair register `browser@openai-bundled` through `codex plugin add ... --json` after the local marketplace is complete. On Windows, invoke a user-accessible CLI shim such as the npm `codex.cmd`; do not execute the protected `WindowsApps\...\resources\codex.exe` path directly.
- Write every marketplace JSON as BOM-less UTF-8. `Set-Content -Encoding UTF8` emits a BOM on PowerShell 5.1, so a rewrite step can corrupt the registered copy while the source file stays valid; use `[System.IO.File]::WriteAllText` with `UTF8Encoding($false)`.
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
- Confirm that every descriptor declared by the current package has a matching plugin directory and identical descriptor version under the stable root, and that the CLI installed-or-available JSON reports that same version. Do not install or enable optional plugins merely to make this check pass; use `-StrictVerifyOnly -VerifyAllBundledPluginsAvailable` for structured availability validation.
- For Chrome native-host failures, compare the manifest's `allowed_origins` with the top-level `extensionIds` in the current versioned Chrome cache's `scripts\extension-ids.json`, even when the manifest host `path` is already correct. If the side panel says `Codex app-server manifest entry is missing required path nodePath`, require `extension-host-config.json` beside the current `extension-host.exe`; its `codexCliPath` must match the installed package CLI by content, and `nodePath` / `nodeReplPath` must come from the same current `cua_node` runtime. Then inspect both `%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json` and `%USERPROFILE%\.codex\chrome-native-hosts-v2.json`: each must have a schema-2 entry for the current Chrome plugin version, both current extension IDs, the official per-field NUL-separated SHA-256 identity, installed-package `resourcesPath`, and all required existing runtime/cache paths. Old-only v2 files or a current-looking entry with an incorrectly flattened identity can reproduce this error even when the outer manifest and host config are correct. Normal repair must call the current plugin's official `installManifest.mjs` and atomically synchronize both v2 files; `-StrictVerifyOnly` must reject origin, registry, config-schema, v2-schema, identity, missing-path, stale-runtime, and mutable-cache drift.

Action:

- Use the targeted bundled marketplace patch with `-OnlyBundledMarketplaceCopy` and a non-system `-OutputRoot` when the user is avoiding C: drive pressure.
- After install and relaunch, run `scripts\install-computer-use-local.ps1 -VerifyOnly` to rebuild the local mirror/cache, then `-StrictVerifyOnly`.
- If `sites` is available but not installed, `install-computer-use-local.ps1 -VerifyOnly` must leave it uninstalled. If it was already installed, the repair may refresh its stable cache while preserving that state.
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
- Inspect the installed Computer Use descriptor first. If it ships `scripts\computer-use-client.mjs`, inspect the matching cache copy; if it is descriptor-only, inspect the versioned `.codex-plugin\plugin.json` and independent `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` `@oai/sky` entry instead.
- Inspect `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\*\bin\node_modules\@oai\sky\package.json`, especially the `exports` map. Newer runtime packages may export only `"."`, which breaks deep bare imports from plugin scripts.
- Inspect `%USERPROFILE%\.codex\config.toml` for stale `[mcp_servers.node_repl.env]` entries named `SKY_CUA_NATIVE_PIPE` or `SKY_CUA_NATIVE_PIPE_DIRECTORY`.

Action:

- Run `scripts\install-computer-use-local.ps1 -VerifyOnly` to rebuild the local bundled plugin mirror, stable cache links, CUA runtime overlay, Chrome native host paths, and config cleanup.
- Run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` immediately after. Legacy layouts require `client import ok` and `helper transport ok`; descriptor-only layouts require `runtime import ok` with a real `sky.list_windows` array result.
- If `-StrictVerifyOnly` fails because a cache link or plugin file is missing, rerun `-VerifyOnly` once, then rerun `-StrictVerifyOnly`.
- In 26.609-style caches, `browser\latest` or `chrome\latest` may be absent while the versioned cache directory still exists. Do not treat that as a Computer Use failure by itself; require the versioned browser/chrome plugin manifests and only validate a support-plugin `latest` junction when it exists.
- If verification succeeds but Desktop still reports native pipe unavailable, fully quit and relaunch Codex Desktop, then inspect the newest Desktop log for `computer-use native pipe startup ready`.
- Only consider a full MSIX repack when Desktop logs or UI evidence show a closed feature gate. Do not patch `resources\codex.exe` or the ASAR just because the immediate failure is an `@oai/sky` package export/import error.

## Bundled Computer Use Skill Calls A Missing Sky Documentation API

Symptoms:

- A new Computer Use task stops at its initialization guidance before it reads or controls a window.
- The bundled `computer-use` skill tells the agent to call a Sky documentation helper, but the JavaScript call reports that the method is not a function or undefined.
- The installed descriptor-only plugin has a working `sky.list_windows()` export while its bundled skill names a different, unavailable method.

Checks:

- Import the current `@oai/sky` package from `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\*\bin\node_modules` and enumerate the actual `sky` methods. Do not infer the API from a cached skill alone.
- Treat the bundled Computer Use skill and its referenced `docs\api.md` as one contract. Newer descriptor-only bundles can keep only initialization in `SKILL.md` and move `list_windows`, `get_window_state`, and `activate_window` signatures into `docs\api.md`; do not force an older overlay merely because those call examples are absent from the skill entrypoint.
- For the documented `@oai/sky` 0.6.2 Window2 profile, the supported read path is `sky.list_windows()` followed by `sky.get_window_state({ window, include_screenshot, include_text })`; `window` is the object returned by `list_windows`, not just its id.
- Read `dist\project\cua\sky_js\src\targets\windows\internal\computer_use_client_base.d.ts` when the runtime API is uncertain. It is the local contract for `activate_window`, `get_window_state`, and `list_windows` in this profile.
- Keep this distinct from `node_repl exec context not found`, native-pipe startup, screenshot-helper, or Chrome native-host failures. A stale skill can block an agent before any of those runtime paths are exercised.

Action:

- Run `scripts\install-computer-use-local.ps1 -VerifyOnly`. For the exact recognized `@oai/sky` 0.6.2 type profile, it applies a local skill overlay in the stable marketplace and versioned cache that uses the real Window2 calls. The overlay is not applied to an unknown future profile or a skill that no longer contains the recognized stale prompt.
- Run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` afterward. Strict verification permits only this one intentional cache difference from the installed package and requires the current `list_windows`, `get_window_state`, and `activate_window` workflow; a future upstream skill that already has that workflow is accepted without a local marker.
- Do not edit the protected WindowsApps copy. The next local repair rebuilds the stable cache from the package and reapplies the guarded overlay.

## Computer Use Cross-Call Approval Loses Node REPL Context

Symptoms:

- `sky.list_windows()` succeeds, but a later `sky.get_window_state()` or `sky.activate_window()` call fails with `Error: node_repl exec context not found`.
- Resetting the JavaScript kernel appears ineffective when the agent again enumerates windows in one `node_repl` call and captures the selected window in a later call.
- A fresh kernel can enumerate and capture in one combined call, while the same persistent helper fails when capture or app approval moves to the next call.
- `include_screenshot:false, include_text:true` can fail with the same error, so this is not necessarily image decoding, PNG writing, or the Windows Graphics Capture backend.

Checks:

- Reproduce against a stable, visible, restored window and record its current HWND owner, title, process ID, and non-trivial bounds. Do not use an exited process, a stale handle, or a minimized `160x28` window as the deciding test.
- Compare a combined `list_windows` plus `get_window_state` call with two separate calls in the same persistent JavaScript kernel. On the affected `@oai/sky 0.6.2` transport, the long-lived helper's stdout listener inherits the first call's `AsyncLocalStorage` store; a later app-approval callback then reaches `nodeRepl.config.createElicitation` with a stale execution ID.
- Run `scripts\patch-computer-use-node-repl-context.ps1` without `-Install`. The documented source profile is original SHA-256 `6423BA83...702B7C` and patched SHA-256 `3600AC24...5BB60A`. Treat any other hash as unknown even when a nearby source fragment looks similar.
- Test `nodeRepl.emitImage` independently when useful. A working direct image emission plus text-only Computer Use failure points away from the outer image-return channel.
- Keep this separate from the Windows 10 `SetIsBorderRequired` / `0x80004002` helper profile, invalid window geometry, a target process that exited, and Chrome native-host state.

Action:

- Run `scripts\install-computer-use-local.ps1 -VerifyOnly`. For the exact known original transport, normal repair installs the hash-guarded source patch and stores the verified original under `.codex\backups\computer-use-node-repl-context`; `-StrictVerifyOnly` remains read-only and rejects the known unpatched state.
- Reset the current `node_repl` JavaScript kernel after installation so the next `@oai/sky` import loads the patched module. The patch captures `AsyncLocalStorage.snapshot()` for each helper request and restores that request context before running its app-approval callback.
- Validate in separate calls: enumerate a controlled window, then in at least two later calls activate it and request screenshot plus accessibility state. Require real images with the expected target title/content and normal dimensions; the existence of a PNG or a returned `Window` object is not enough.
- Re-check the foreground window immediately before capture. The current native helper can return visible pixels from an occluding foreground window when focus drifts, so activate the intended target immediately before the state request and inspect the image content rather than trusting metadata alone.
- Unknown helper transport hashes remain untouched. Do not copy this source transformation onto another `@oai/sky` build, edit WindowsApps in place, run a full MSIX repack, repair Chrome, or enter the Phone Remote Control workflow unless separate evidence requires it.

## Existing MCP Commands Point At A Retired CUA Node Runtime

Symptoms:

- After a Codex Desktop Store update, one or more already-configured local MCP servers fail to start.
- The affected `[mcp_servers.<name>].command` points under `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<old-runtime-id>\bin\node.exe`.
- That executable is missing, or its runtime directory belongs to an earlier package while the current user-local CUA runtime uses another versioned directory.

Checks:

- Back up `%USERPROFILE%\.codex\config.toml` before changing any MCP entry, then parse the file as TOML and enumerate only the MCP servers actually configured on the machine. Do not assume a fixed server list or count.
- Treat only missing commands inside the Codex-managed `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` tree, or existing commands whose startup failure is reproduced and attributed to a retired Codex-managed runtime, as migration candidates. Leave an older but working runtime unchanged. Do not rewrite commands that use a system, user-managed, or project-managed Node installation.
- Require the replacement `node.exe` and adjacent `node_repl.exe` to come from the same user-local runtime directory and to match the current installed package files by length and SHA-256. Resolve the final identity of both the expected CUA runtime root and each candidate; the candidate must remain under that resolved root. Reject candidates that land in WindowsApps, `.plugin-appserver`, or an unrelated root, while allowing the whole expected runtime root to be intentionally junctioned to another local drive.
- Never execute the protected WindowsApps `node.exe` or `node_repl.exe` as a fallback. If no matching user-local runtime exists, launch Codex Desktop once to let it extract the runtime and retry; otherwise stop without changing MCP configuration.

Action:

- Update only an affected, already-configured MCP whose command is missing or whose startup failure is proven to follow the retired Codex-managed runtime. Replace only its `command` value; do not perform a file-wide runtime-ID replacement.
- Preserve the MCP name, arguments, entry script, environment, working directory, timeouts, enabled state, and credentials. Do not install or enable MCP servers, modify their source trees, or migrate a working MCP merely because a newer CUA runtime exists.
- Reparse `config.toml`, verify the MCP name set and every non-target field are unchanged, then use a user-accessible local Codex CLI whose content matches the installed package to run `codex mcp list`; never fall back to the protected WindowsApps CLI. Perform a real stdio JSON-RPC `initialize` plus `tools/list` smoke test for each migrated server. `node --version` alone is insufficient.
- If initialization succeeds but an external backend is unavailable, report that dependency separately rather than calling the MCP fully healthy. If a migrated server fails its smoke test, restore the backup or revert that target mapping.

`install-computer-use-local.ps1` does not automatically rewrite arbitrary `[mcp_servers.*].command` values. Its Chrome and Computer Use inventory supplies the current package-content matching rule, while this targeted MCP procedure adds the final-path containment check. Third-party MCP migration remains a separate configuration repair.

## Computer Use Screenshot Fails With 0x80004002 On Windows 10

Symptoms:

- App/window enumeration works, but the first real screenshot fails with `SetIsBorderRequired failed: The requested interface is not supported (0x80004002)`.
- Skipping only the border-interface call changes the failure into `FrameArrived timed out`.
- The machine is Windows 10 and the failing binary is the user-level CUA `codex-computer-use.exe`, not the Desktop ASAR or `resources\codex.exe`.

Checks:

- Run `scripts\install-computer-use-local.ps1 -StrictVerifyOnly` and keep the exact helper error.
- Resolve the selected helper under `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node`, then calculate its SHA-256 and read the adjacent `@oai/sky\package.json` version.
- Use `scripts\patch-computer-use-helper-win10.ps1` without `-Install` to classify the helper as `original-patchable`, `patched`, or `unsupported`.
- Treat the Windows 10 build check, the exact `SetIsBorderRequired / 0x80004002` failure, the `@oai/sky` version, and the complete helper hash as separate requirements. A matching hash on Windows 11 is classification evidence only and does not authorize installation.
- `-ComputeCandidateHash` is a read-only regression path for an exact original helper fixture. It can prove that the guarded regions reconstruct the documented output hash on a non-Windows-10 test host, but `-Install` must still reject that host and leave the helper unchanged.
- If a browser capture stops because the runtime cannot determine the current URL with enough confidence, the native screenshot helper was not reached. Repeat later with a controlled non-browser window instead of attributing that policy stop to this profile.
- Do not treat this native screenshot failure as a missing plugin/cache path or a Desktop feature gate.

Action:

- Read `references/win10-computer-use-screenshot-backend.md` before writing the helper.
- For an exact documented original helper hash (`@oai/sky 0.4.20`, `0.5.2`, or `0.6.6`), run the hash-guarded patcher with `-Install`, then rerun `install-computer-use-local.ps1 -VerifyOnly` and `-StrictVerifyOnly`. Desktop `26.707.12708.0`, `26.721.4979.0`, and `26.803.10989.0` are the respective end-to-end validation baselines, not the compatibility boundary.
- Validate through the real Computer Use client against a controlled non-browser window with recognizable, non-sensitive content. Use independent calls for enumeration, activation, and capture; inspect the returned pixels and dimensions, then add repeated static captures, dynamic captures spaced about two seconds apart, accessibility text, `list_windows`, and post-warm-up resource counts.
- The `0.6.6` / Desktop `26.803.10989.0` baseline passed a cold Explorer capture, two batches of ten static captures, stable helper resources after twenty captures, and three distinct Task Manager performance frames. This validates only the documented complete helper hash pair; it is not a generic version rule.
- Use the patcher's `-Rollback` mode to restore the verified original backup.
- If the helper hash is unknown, stop. Do not reuse offsets, restore an older Codex Desktop package, copy a helper from another version, or edit `C:\Program Files\WindowsApps`.

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

## Self-Update Reports A New Commit But Acceptance Criteria Are Stale

Symptoms:

- Self-update logs `updated skill from GitHub: <sha>` and `.skill-version` holds that commit, but the installed `README.md` / `README.en.md` still describe the previous acceptance criteria.
- A verification step that the upstream commit added is missing from the installed checklist, so a real defect is never checked and the run is reported as complete.

Checks:

- Compare the installed top-level files with the commit in `.skill-version`, not just `SKILL.md` and `scripts`.
- Confirm the self-update copy list covers every tracked top-level file. Only `agents`, `scripts`, `references`, and `assets` are mirrored as directories; top-level files are copied one by one from an explicit list.
- Read `.skill-version` as bytes. A UTF-8 BOM makes non-PowerShell tooling compare the marker as unequal even when the skill is current.

Action:

- Sync the missing top-level files from the commit recorded in `.skill-version` before trusting any acceptance checklist.
- Keep the copy list and the tracked top-level file set aligned, and cover it with `scripts/test-skill-self-update-file-coverage.ps1`.
- Write `.skill-version` as UTF-8 without BOM, and tolerate a BOM left by an older install when comparing against remote HEAD.

## Manual ASAR Extraction Leaves Temp Directory

Symptoms:

- A manual `asar extract` verification succeeds, but deleting the extracted temp tree fails.
- PowerShell reports a missing nested file such as `InfoPlist.strings` while deleting extracted `node_modules`.

Action:

- First verify the target directory is under the intended temp root and has the expected `codex-*` prefix.
- If normal `Remove-Item -Recurse -Force` fails, use .NET deletion with a Windows long-path prefix: `[System.IO.Directory]::Delete("\\?\C:\path\to\temp-dir", $true)`.
- Do not use this cleanup pattern on an unverified or computed path.
