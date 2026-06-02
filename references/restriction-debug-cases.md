# Restriction Debug Cases

Use this reference only when the main `SKILL.md` workflow does not explain the current Codex Desktop restriction, plugin gate, Computer Use failure, or mobile remote-control failure. Keep the investigation evidence-based: prefer package status, config, plugin list output, Desktop logs, sandbox logs, and captured network requests over assumptions.

## Fast Mode Is Visible But Not Actually Fast

Symptoms:

- The UI exposes Fast Mode, but requests do not receive priority behavior.
- A local smoke test returns an answer such as `FAST_CHECK_OK`.

Checks:

- Capture the actual `/v1/responses` request made by Codex Desktop and verify `service_tier=priority` on the wire.
- If the upstream is CPA or another proxy, inspect the proxy-side override rules. Local capture only proves Codex sent the parameter; the proxy can still drop, rewrite, or ignore it.

Action:

- For CPA, add an override rule for the Codex-facing model names and force `service_tier` as a string value of `priority`.
- Treat proxy configuration as part of Fast Mode validation, not as optional documentation.

## UI Gate Is Still Blocking A Feature

Symptoms:

- Plugins, Goal commands, Computer Use, or "Any App" / "任意应用" appear disabled even after config changes.
- A Store upgrade moved or renamed webview asset chunks.

Checks:

- Search extracted ASAR webview assets by stable code behavior instead of fixed filenames.
- For Computer Use, relevant patterns include `featureName:\`computer_use\``, Statsig gate `1506311413`, `installPlugin:async`, and `openPluginInstall`.

Action:

- Patch the extracted ASAR through the MSIX repack workflow.
- Do not edit `C:\Program Files\WindowsApps` in place.
- Update script search logic when asset filenames drift between Codex Desktop versions.

## Computer Use Settings Says Plugin Unavailable

Symptoms:

- Computer Control settings shows `Computer Use 插件不可用`.
- Desktop logs contain `computer-use native pipe startup failed` and `missing-helper-path`.
- `codex plugin list` may show bundled plugins missing, disabled, or marketplace load errors.
- The failure comes back after fully quitting Codex Desktop and reopening it.

Checks:

- Inspect `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled\.agents\plugins\marketplace.json`.
- Inspect `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled\plugins\computer-use`.
- Inspect running `extension-host` processes whose paths are under `%USERPROFILE%\.codex\plugins\cache\openai-bundled`.
- Inspect `%USERPROFILE%\.codex\chrome-native-hosts.json`; remove stale entries whose `extensionHostPath` or `browserClientPath` points to a missing file.

Action:

- Stop only those bundled `extension-host` processes when they are locking the bundled marketplace mirror.
- Rerun `scripts\install-computer-use-local.ps1`.
- Restart Codex Desktop.
- Confirm the latest Desktop log ends with `computer-use native pipe startup ready`.

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

## Codex Mobile Entry Opens Then Drops Back

Symptoms:

- The "Codex mobile" / "Codex 移动版" entry appears, but clicking it exits, drops back, or opens nothing.
- Connections > Control This Computer > Set up routes to login, repeatedly errors, or leaves a modal that is hard to exit.

Checks:

- Inspect Desktop logs under `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\<year>\<month>\<day>`.
- Look for `load_remote_control_unauthed` or `refresh_local_remote_control_client_id_failed`.
- Inspect extracted ASAR files `webview\assets\codex-mobile-setup-flow-*.js` and `.vite\build\main-*.js`.

Action:

- Patch `codex-mobile-setup-flow-*.js` so a remote-control auth error does not navigate the settings modal to `/login` and return `null`.
- Patch the main-process remote-control unauthenticated branch so it publishes a safe empty state instead of an auth-required loop.
- If logs still say `Sign in to ChatGPT in Codex Desktop`, the local patch can keep the UI usable, but real cross-device remote-control enrollment still requires ChatGPT Desktop sign-in, not only API-key Codex login.

## Self-Update Fails

Symptoms:

- The skill self-update helper cannot reach GitHub, cannot download the archive, or cannot resolve remote HEAD.

Action:

- Do not block the repair.
- Continue with the currently installed local skill.
- Mention that self-update was skipped, then rely on local scripts and local evidence.
