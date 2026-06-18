# Phone Remote Control Cases

Use this reference when the user asks to enable or repair Codex Desktop phone remote control on Windows, especially while keeping a third-party/API-key main model provider. Keep the investigation evidence-based: inspect the installed MSIX, extracted ASAR markers, native `resources\codex.exe` markers, `$env:USERPROFILE\.codex\remote-control-flow.log`, Desktop logs, SQLite state, and the actual post-pairing model request endpoint when phone-created turns reach Desktop.

## Core Invariant

- Keep the user's main Codex model provider state intact. Do not switch the global app into ChatGPT login just to enable phone remote control.
- Treat remote-control auth as isolated ChatGPT backend auth. Prefer `$env:USERPROFILE\.codex\remote-control-oauth.json`, then `$env:USERPROFILE\.codex\remote.json`, and never use `$env:USERPROFILE\.codex\auth.json` for remote-control bearer injection.
- The pairing/control transport may still call `https://chatgpt.com/backend-api/wham/remote/control/...`; that is expected.
- After phone-sent messages reach Desktop, verify the actual model sampling request URL. If it points to the wrong model API endpoint, treat that as post-pairing configuration diagnosis based on evidence from the request URL, `config.toml`, and affected thread/session metadata. Do not present it as part of the remote-control pairing implementation.
- Do not switch `model_provider` ids just to change an endpoint. That can hide conversation history. Only alter provider config after proving what provider id and endpoint the user intentionally uses.

## Workflow

1. Read the current installed package:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name,PackageFullName,Version,SignatureKind,InstallLocation
```

2. Run the normal skill preflight and backup rules before touching `config.toml`, SQLite, or MSIX files.

3. If the settings page hides the phone setup entry, QR spins forever, setup redirects to ChatGPT login, or the allow dialog says `Couldn't enable remote control`, use the remote-control MSIX patch script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -DryRun
```

4. If the system drive is tight, pass an alternate output root on any drive with enough free space. This is optional; do not hard-code a drive letter in the workflow:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -DryRun -OutputRoot "<large-local-build-root>"
```

5. If a patched native app-server binary is available, pass it explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-remote-control-windows-msix.ps1" -DryRun -ReplacementResourceCodexExe "<path-to-built-codex.exe>"
```

6. After dry-run succeeds, rerun with `-Install -Launch -InstallPrerequisites`. Stop only WindowsApps Codex Desktop processes; do not kill Antigravity/extension-host Codex sessions unless the user explicitly asks.

7. After successful remote-control install, verify that the ordinary patched features survived. At minimum run `install-computer-use-local.ps1 -StrictVerifyOnly`, `codex plugin list`, and a Windows sandbox smoke test. If strict verification reports a stale Chrome native-host manifest or a missing/stale bundled cache link, run `install-computer-use-local.ps1 -VerifyOnly`, then rerun `-StrictVerifyOnly`.

8. After successful repair, delete or let the script delete generated MSIX staging, ASAR extraction, temporary patched `.msix`, script-local `npx` cache, live verification extracts, copied SQLite/log probes, and temporary Windows SDK BuildTools. Keep reusable native build outputs and source checkouts if they avoid a costly rebuild next time. Keep auth/config/sqlite state and explicit backups unless the user asks for backup pruning.

## ASAR Patch Expectations

The ASAR patch script targets behavior, not fixed filenames. Dry-run and live package verification should find these markers:

- `remote_control_desktop_fetch_override_used`
- `remote_control_appserver_bh_isolated_auth_fallback`
- `remote_control_connection_auth_fallback_used`
- `remote_control_mobile_setup_no_auth_redirect`
- `remote_control_mobile_setup_authorize_before_enable`
- `remote_control_settings_force_control_this_pc_visible`
- `remote_control_settings_force_remote_control_section_visible`
- `remote_control_qm_start`
- `software_device_key_async_fallback`

In 26.611-style bundles, the no-auth 401 redirect can live in multiple chunks, including `codex-mobile-setup-queries-*` and `codex-mobile-setup-flow-*`, not only in `codex-mobile-setup-dialog-*`. Patch every matching chunk with `ChatGPT auth is required to load remote control environments.` or the `J&&u('/login')` effect; do not return a single mobile setup file from the patcher when multiple chunks match.

In 26.611.8604, the main bundle shape changed again. Detect the main bundle by behavior markers such as `desktop_fetch_auth_401`, `authorize remote control environments`, `app_EMoamEEZ73f0CkXaXp7hrann`, and `codex.remote_control.enroll`, not by old fixed function names. Known 26.611.8604 anchors are:

- Step-up function `ZZ`, token exchange `rQ`, client id var `VZ`, and scope var `qZ`.
- Desktop fetch path `pP({desktopOriginator:this.options.desktopOriginator,headers:t,state:e})` with auth attached through `Cg(...)` and surface headers through `wg(...)`.
- App-server auth function `Sg`, wrapper `zg`, and request function `Rg`.
- Authorize flow `n_`, device-key creation `F_`, and device-key client factory `EQ`.

The patched mobile setup chunks must not still contain forced redirect shapes:

```text
e.status===401?(J(),new Se(
e.status===401?(v(),new C(
```

Run `node --check` on the patched main bundle, mobile setup dialog, mobile setup flow, and remote connections settings chunk.

## Native App-Server Expectations

The native `app\resources\codex.exe` part is separate from the Electron ASAR. The replacement binary must include these markers before MSIX install:

- `remote_control_app_server_isolated_oauth_used`
- `remote_control_native_remote_json_first`
- `remote_control_websocket_proxy_attempt`
- `remote_control_websocket_proxy_connected`
- `remote-control-oauth.json`
- `remote.json`
- `codex.remote_control.enroll`

For 26.609-style Windows builds, the known native fixes are:

- In `app-server-transport/src/transport/remote_control/auth.rs`, load isolated remote-control auth when the main app auth is API-key/non-ChatGPT. The connection bearer should prefer `remote.json`, with the enroll step-up token sourced separately from `remote-control-oauth.json` when it has `codex.remote_control.enroll` and recent MFA freshness.
- Do not invert the `uses_codex_backend()` check in `auth.rs`. A candidate isolated auth is usable only when `auth.uses_codex_backend()` is true; accepting non-Codex-backend auth there reintroduces `remote control requires ChatGPT authentication; API key auth is not supported`.
- Try real Codex home candidates for isolated auth: `auth_manager.codex_home()`, `CODEX_HOME`, `%USERPROFILE%\.codex`, and `%HOME%\.codex`. Log candidate paths so a future failure proves whether the native app-server looked in the actual user home.
- In `app-server-transport/src/transport/remote_control/websocket.rs`, enable the `tungstenite` proxy feature and connect remote-control WebSockets through `HTTPS_PROXY`/`HTTP_PROXY` when set, with a local optional v2rayN fallback at `http://127.0.0.1:10808`. The fallback must be disableable with `CODEX_REMOTE_CONTROL_DISABLE_V2RAYN_PROXY_FALLBACK=1`.
- In workspace `Cargo.toml`, make sure `env!("CARGO_PKG_VERSION")` used by server enrollment is not `0.0.0`. For the verified 26.609.41114 build, `0.140.0-alpha.2` avoided the phone-side `Codex version expired` state.

Do not claim a binary is fixed because it was rebuilt. Check markers in the actual file that will be copied to `app\resources\codex.exe`.

## Known Failure Modes

### Settings Shows Only SSH

Symptoms:

- `Settings -> Connections` shows only SSH.
- `Settings -> Connections` displays the `Control this computer` / `控制此电脑` tab, but clicking it does nothing or the content stays SSH.
- The mobile setup page's `Manage connections` / `管理连接` link opens the Connections page on SSH instead of the local control-computer section.
- No new remote-control log lines appear when opening the page.

Action:

- Patch both remote connections settings gates and verify `remote_control_settings_force_control_this_pc_visible` plus `remote_control_settings_force_remote_control_section_visible`.
- In 26.611-style settings chunks, `showControlThisMacTab` alone is insufficient. The tab normalizer in `use-plugin-install-flow-*` returns `ssh` when `showRemoteControlConnectionsSection` is false, so force the section variable too, e.g. the `be=qe(),X=!f,` shape must become section-visible before `Je({ selectedConnectionsTab, ... })` runs.

### QR Spinner Or ChatGPT Redirect

Symptoms:

- Phone setup modal spins forever.
- Clicking `Connections` or setup jumps back to the main chat/login flow.
- Logs show remote-control preflight 401 without token.

Action:

- Patch `desktop_fetch` so only `/backend-api/wham/remote/control/*`, `/wham/remote/control/*`, `/backend-api/accounts/mfa_info`, and `/accounts/mfa_info` receive the isolated remote bearer.
- Patch the setup dialog 401 catch so it stays inside remote-control UI instead of calling the global ChatGPT login redirect.

### Allow Dialog Fails After MFA

Symptoms:

- User completes browser MFA and clicks allow.
- Desktop still shows `Couldn't enable remote control. Try again`.

Checks:

- Check native logs in `%USERPROFILE%\.codex\sqlite\logs_2.sqlite`.
- If logs show `wss://chatgpt.com/backend-api/wham/remote/control/server` ending with Windows `os error 10060`, the failure is remote-control WebSocket networking, not OAuth.
- If the user runs v2rayN, check whether `127.0.0.1:10808` is listening.

Action:

- Use a native binary with WebSocket proxy support and verify `remote_control_websocket_proxy_connected` plus ping/pong/ack frames after relaunch.

### Phone Says Codex Version Expired

Symptoms:

- QR scan works and phone discovers the desktop environment.
- Phone displays `Restart Codex` / `Codex version expired`.

Action:

- Check the replacement native `codex.exe --version`.
- If it reports `0.0.0`, rebuild with a valid workspace package version.
- Back up `%USERPROFILE%\.codex\sqlite\state_5.sqlite`, clear stale `remote_control_enrollments`, relaunch Desktop, and generate a fresh QR. Do not reuse an enrollment created by a version-broken binary.

### Phone Message Reaches Desktop But Model Request Hits The Wrong API Endpoint

Symptoms:

- Phone can connect and send a chat message.
- Desktop thread fails with API authentication or routing errors.
- Error text shows a model request URL that does not match the user's intended current API endpoint.

Checks:

- Capture the concrete failed request URL from the visible error, Desktop logs, proxy logs, or local wire capture.
- Inspect `%USERPROFILE%\.codex\config.toml` and identify the active provider id and intended endpoint.
- Inspect affected thread/session metadata only if UI history or thread routing changed unexpectedly.

Action:

- If the active provider id is intentionally `openai` but the user is using a third-party endpoint, the usual fix is to ensure the intended top-level endpoint setting is present while keeping `model_provider = "openai"`.
- Do not switch to `model_provider = "openai-custom"` merely to change the URL; that can hide existing conversation history.
- If a prior manual mistake already changed thread provider ids, back up `%USERPROFILE%\.codex\sqlite\state_5.sqlite` before any SQLite repair and only change rows that are proven to be affected by that mistake.

## Live Verification

After install, verify the live installed files, not only the dry-run output:

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
$asar = Join-Path $pkg.InstallLocation 'app\resources\app.asar'
$native = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'
```

Then extract/check ASAR markers, binary markers, and Desktop logs. Final acceptance should include:

- `Settings -> Connections` shows phone/mobile remote setup.
- QR code appears.
- Phone scan no longer reports expired Codex version.
- Native logs show remote-control WebSocket ping/pong/ack without repeated `os error 10060`.
- Phone-sent chat reaches Desktop.
- After the phone message reaches Desktop, the model sampling request targets the user's intended current API endpoint. If it does not, handle that as the post-pairing configuration case above.
