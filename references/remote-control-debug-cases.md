# Phone Remote Control Cases

Use this reference when the user asks to enable or repair Codex Desktop phone remote control on Windows, especially while keeping a third-party/API-key main model provider. Keep the investigation evidence-based: inspect the installed MSIX, extracted ASAR markers, native `resources\codex.exe` markers, `$env:USERPROFILE\.codex\remote-control-flow.log`, Desktop logs, SQLite state, and the actual post-pairing model request endpoint when phone-created turns reach Desktop.

## Core Invariant

- Keep the user's main Codex model provider state intact. Do not switch the global app into ChatGPT login just to enable phone remote control.
- Treat remote-control auth as isolated ChatGPT backend auth. Use `$env:USERPROFILE\.codex\remote.json` for normal connection/read authorization and keep `$env:USERPROFILE\.codex\remote-control-oauth.json` separate for fresh MFA/step-up/enroll flows. Never use `$env:USERPROFILE\.codex\auth.json` for remote-control bearer injection.
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

6. If the Allow dialog fails and native logs show `remote control requires ChatGPT authentication; API key auth is not supported`, build a patched native app-server binary first. Use a work root on a large local drive if the user does not want system-drive space consumed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\build-remote-control-native-replacement.ps1" -WorkRoot "D:\CodexData\rc145" -CodexSourceRef "rust-v0.145.0-alpha.18" -AppServerVersion "0.145.0-alpha.18"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\build-remote-control-native-replacement.ps1" -WorkRoot "D:\CodexWork\phone-remote-26.707\native-remote-0.144.0-alpha.4" -CodexSourceRef "rust-v0.144.0-alpha.4" -AppServerVersion "0.144.0-alpha.4"
```

Use the printed `ReplacementResourceCodexExe` value with `patch-remote-control-windows-msix.ps1 -ReplacementResourceCodexExe`. With both version parameters omitted, the helper copies the installed WindowsApps native binary into `WorkRoot\tmp`, runs `--version` on the copy, and chooses a known mapping without executing the package binary in place. Desktop `26.715.2305.0` ships native `codex-cli 0.145.0-alpha.18`, which maps to `references\remote-control-native-replacement-0.145.0-alpha.18.patch`. Desktop `26.707.3748.0` ships native `codex-cli 0.144.0-alpha.4`, which maps to `references\remote-control-native-replacement.patch`. For historical `rust-v0.142.4`, matching parameters select `references\remote-control-native-replacement-0.142.4.patch`; this older patch has passed clean patch-apply validation but has not yet completed an end-to-end native compilation validation. Any other version requires exact matching version parameters and an explicitly validated `-PatchPathOverride`. The helper checks patch applicability before compilation and keeps all build/cache/temp output under `-WorkRoot`.

Point-in-time validation: Codex Desktop `26.707.3748.0` with native `0.144.0-alpha.4` completed native build, patched MSIX install, manifest-derived AppUserModelId launch, isolated `remote.json` verification, proxied remote-control connection, enabled enrollment, and an actual phone-to-Desktop message round trip on Windows on 2026-07-11. Treat this as evidence for that exact version pair, not as forward-compatibility proof for later Store or Rust releases.

Point-in-time validation: Desktop `26.715.2305.0` with native `0.145.0-alpha.18` at exact source commit `f84f9a6406cc55b210395f71b4c6aed236fc7ebb` completed the native MSVC `dev-small` build, patched MSIX install, manifest-derived AppUserModelId launch, isolated `remote.json` HTTP 200 verification, proxied native WebSocket connection, persisted enrollment reuse, and a user-confirmed phone end-to-end test on Windows on 2026-07-18. Post-install live evidence was correlated to the WindowsApps native PID/path and showed `remote_control_native_remote_json_first`, `remote_control_app_server_isolated_oauth_used`, `remote_control_websocket_proxy_attempt`, `remote_control_websocket_proxy_connected`, and `Connected`. Treat this as evidence for that exact package/native/source pair, not as forward-compatibility proof.

When MSVC is installed but `kernel32.lib` is unavailable, the helper accepts either one coherent installed SDK root/version or the validated split NuGet package layout. If no installed SDK is usable, it downloads `Microsoft.Windows.SDK.CPP` plus `Microsoft.Windows.SDK.CPP.x64` `10.0.26100.4188` under `<WorkRoot>\cache\windows-sdk-cpp`. NuGet downloads go to `.partial`, are extracted with checked `tar.exe`, and are checked for expected payloads before replacing the formal cache. Do not use PowerShell 5.1 `Expand-Archive` here; it can fail while cleaning a deep `_rels\.rels` tree. The NuGet layout can separate `c\um\x64\kernel32.lib`, `c\ucrt\x64\ucrt.lib`, `c\Include\<version>\um\Windows.h`, and `c\bin\<version>\x64\rc.exe`, so do not require the two packages to look like one traditional installed Windows Kits root. It honors `HTTPS_PROXY` / `HTTP_PROXY`, otherwise uses `http://127.0.0.1:10808` only if listening, and falls back to direct download. Point `-WorkRoot` at a short path on the requested large drive; a deeply nested D-drive path caused Cargo's Git dependency checkout to fail with `path too long`, while `D:\CodexData\rc145` succeeded. `-SkipBuild` requires the matching build-stamp JSON and skips SDK initialization entirely.

When an external executor runs the install, use a unique `OutputRoot` for each attempt and confirm no child PowerShell process survived a parent timeout before retrying. Under PowerShell 5.1 with `$ErrorActionPreference = 'Stop'`, do not use `*>&1 | Tee-Object`; child npm stderr warnings can be promoted to terminating `RemoteException` records. Do not redirect stdout and stderr to the same file. Use `Start-Process powershell.exe -Wait -PassThru` with separate `-RedirectStandardOutput` and `-RedirectStandardError` files, judge the actual child `ExitCode`, and merge logs only after exit.

7. After dry-run succeeds, rerun with `-Install -Launch -InstallPrerequisites`. Stop only WindowsApps Codex Desktop processes; do not kill Antigravity/extension-host Codex sessions unless the user explicitly asks. The install script must launch the registered package through the AppUserModelId derived from `Get-AppxPackageManifest` and `PackageFamilyName`; directly starting `WindowsApps\...\app\Codex.exe` can return access denied even after a successful install. Treat a launch error as a separate warning and preserve the successful installation result.

8. If the install is interrupted after signing/uninstall and `Get-AppxPackage -Name OpenAI.Codex` is empty, install the already generated patched MSIX from the selected output root instead of rebuilding:

```powershell
Add-AppxPackage -Path "<large-local-build-root>\OpenAI.Codex_<version>_remote-control-patched.msix" -ForceApplicationShutdown -Verbose
```

9. After successful remote-control install, verify that the ordinary patched features survived. At minimum run `install-computer-use-local.ps1 -StrictVerifyOnly`, `codex plugin list`, and a Windows sandbox smoke test. If strict verification reports a stale Chrome native-host manifest or a missing/stale bundled cache link, run `install-computer-use-local.ps1 -VerifyOnly`, then rerun `-StrictVerifyOnly` twice. Desktop `26.707.3748.0` ships a `deep-research` descriptor that its runtime can intentionally remove from the local marketplace; the strict verifier allows only that exact version/name omission under its existing completeness conditions. On `26.715.2305.0`, a missing local `deep-research` descriptor was repaired from the installed package by `-VerifyOnly`, after which two strict checks passed; do not broaden the older exception to this version.

10. After successful repair, delete or let the script delete generated MSIX staging, ASAR extraction, temporary patched `.msix`, script-local `npx` cache, live verification extracts, copied SQLite/log probes, and temporary Windows SDK BuildTools. If the user only asked for the repair, also remove source checkouts, Cargo/Rustup caches, target directories, temp directories, and generated patch files created only for this repair. Keep the installed repaired package, `.codex\remote.json`, `.codex\remote-control-oauth.json`, config, sqlite state, logs, and explicit backups.

## ASAR Patch Expectations

The ASAR patch script targets behavior, not fixed filenames. Dry-run and live package verification should find these markers:

- `remote_control_desktop_fetch_override_used`
- `remote_control_auth_token_expired_skipped`
- `remote_control_appserver_bh_isolated_auth_fallback`
- `remote_control_connection_auth_fallback_used`
- `remote_control_mobile_setup_no_auth_redirect`
- `remote_control_mfa_info_403_nonblocking`
- `remote_control_client_list_partial_failure_nonblocking`
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

In 26.616.3767, the main bundle may no longer expose the older `desktop_fetch_auth_401`, `ZZ`, or `pP(...)` anchors. Known verified anchors are:

- Main file shape: `.vite\build\main-*.js` with `CODEX_API_BASE_URL`, `async function v_({action:e,appServerClient:t`, `async function P_({action:e,appServerClient:t,desktopApiOptions:n`, and `async function c$`.
- Client id var `QQ` and enroll scope vars `K_` / `i$`.
- App-server auth function `v_`, auth header helper `y_`, HTTP request function `P_`, step-up functions `c$` / `m$`, authorize flow `Q_`, enrollment request `rv`, auth headers `nv`, device-key creation `jv`, and device-key client factory `L$`.
- Mobile setup flow local-enable function `async function F(e,t,n)` must authorize before `set-local-remote-control-enabled`.
- Remote connection settings visibility gates can be `nt=Ne&&!0,` for the local tab and `Ne=Xe(),X=!T,` for the whole remote-control section. Patch both; otherwise `Control this computer` can appear but clicking it keeps the SSH page.

In Desktop `26.715.2305.0`, the exact verified main bundle was `.vite\build\main-FGp_fjyX.js`. Its remote-control auth functions were split across `lN` / `Nv` / `ey`, step-up used `v4` / `w4`, and authorization/device-key paths used `Mv` / `Xv` / `ky` / `B4`. The verified webview files included `selectable-remote-connections-signal-BHda4Eip.js`, `codex-mobile-setup-flow-BwII7M5w.js`, and `remote-connections-settings-C0nTFTK8.js`. Treat these identifiers as version-scoped recognition evidence only; preserve older behavior-based branches and fail closed on unknown later shapes. The `mfa_info` 403 fallback must test the bundle's actual HTTP error class (`se` in this build), not an assumed generic minified identifier.

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
- For 26.623.9142, the replacement native must report an app-server version accepted by the phone/backend. A `0.133.0` replacement can fix the API-key main-auth rejection but still leave the phone stuck on `Update desktop app to connect` / version-expired UI. When the package reports `codex-cli 0.142.4`, use matching `rust-v0.142.4` / `0.142.4`; its dedicated patch is patch-apply validated, but full native compilation remains to be verified before treating that historical path as end-to-end proven.

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

### Control This Computer Shows Device List Login Error

Symptoms:

- `Settings -> Connections -> Control this computer` is visible and the local toggles may appear enabled.
- Clicking `Add` or opening the local control-computer page unexpectedly falls back to a new conversation or main chat page.
- The page shows `Couldn’t load device list` / `无法加载设备列表` with `Sign in to ChatGPT again, then retry`.
- `$env:USERPROFILE\.codex\sqlite\state_5.sqlite` has table `remote_control_enrollments`, but the count is `0`.
- `$env:USERPROFILE\.codex\remote-control-flow.log` shows only `check remote control authorization`, shows `/backend-api/wham/remote/control/clients` using `remote-control-oauth.json` with only `codex.remote_control.enroll` scope, or shows `remote-control-oauth.json` being tried before `.codex\remote.json` for read/MFA endpoints.

Action:

- Do not treat visible `Control this computer` tabs as proof of working remote control. Verify `remote_control_enrollments` has a row after authorization.
- In 26.616-style bundles, patch the new desktop fetch auth path around `async function KF({appServerClient:e,...})`, not only the older `PN/eP/pP` fetch anchors.
- For `/wham/remote/control/clients` and environment-list read endpoints, prefer isolated `remote.json` before `remote-control-oauth.json`; the step-up/enroll token may have only `codex.remote_control.enroll` and can trigger the device-list login error.
- For `/wham/remote/control/mfa_requirement` and other remote-control read/MFA endpoints, skip expired JWTs from either isolated auth file before returning a bearer. An expired `remote-control-oauth.json` step-up token can otherwise shadow a valid `.codex\remote.json` and produce a 401 `token_expired` path even though normal remote auth verifies successfully. Verify the ASAR contains `remote_control_auth_token_expired_skipped`.
- Keep `remote-control-oauth.json` for MFA/step-up/enroll flows and keep `remote.json` for normal connection/read authorization. Never fall back to global `auth.json`.
- In 26.616-style settings, the device list query can still fail even when `/backend-api/wham/remote/control/clients` returns HTTP 200. Check `/backend-api/wham/remote/control/mfa_requirement` and `/backend-api/accounts/mfa_info`: `mfa_requirement` may return `{"requirement":"required"}` while `accounts/mfa_info` returns 403 HTML. Patch the mobile setup query so that a 403 from `/accounts/mfa_info` is non-fatal for this remote-control UI path and verify `remote_control_mfa_info_403_nonblocking`.
- The same device list view merges browser clients from `/wham/remote/control/clients` with local app-server clients from `list-remote-control-clients-for-host`. A failing app-server subquery must not discard the successful browser client list. Patch the mobile setup query merge to tolerate app-server list failures and verify `remote_control_client_list_partial_failure_nonblocking`.
- A fully patched ASAR/native binary can still fail here when `.codex\remote-control-oauth.json` is valid for enroll but `.codex\remote.json` is disabled, expired, or has a reused refresh token. The normal read token needs `api.connectors.read` and `api.connectors.invoke`; the enroll-only token is not enough for `/backend-api/wham/remote/control/clients`.
- Verify the normal bearer without modifying files:

```powershell
python "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\refresh-remote-control-auth.py" --verify-only
```

- If verify-only reports disabled/expired/401/403, or manual refresh failed with `refresh_token_reused`, run the same script without `--verify-only` and finish the browser PKCE flow. The script writes only `$env:USERPROFILE\.codex\remote.json`, backs up the old file under `.codex\backups\remote-control-auth`, and must not write `.codex\auth.json` or `config.toml`.
- Direct token exchange can fail with `unsupported_country_region_territory`; keep the default `http://127.0.0.1:10808` proxy unless there is evidence another route works. Use `--proxy ""` only when intentionally testing the direct path.
- After `--verify-only` returns `ok: true`, refresh the Connections page or restart only WindowsApps Codex Desktop/app-server, then scan the QR code again.

### Allow Dialog Fails With API-key Main Auth

Symptoms:

- User clicks Allow after MFA or after opening `Settings -> Connections -> Control this computer`.
- Desktop reports `Couldn't enable remote control. Try again` or the localized equivalent.
- Native app-server logs show `remote control requires ChatGPT authentication; API key auth is not supported`.
- The main Codex Desktop auth is intentionally a third-party/API-key provider, while isolated `.codex\remote.json` verifies successfully against `/backend-api/wham/remote/control/clients`.

Action:

- Do not switch global `model_provider` or global Desktop auth to ChatGPT. That can hide history or break the user's API routing.
- Do not repeat ASAR-only repacks after this log appears. The native app-server rejects API-key main auth before remote-control connection can use the isolated bearer.
- For Desktop `26.715.2305.0`, use the short-root mapping `-WorkRoot "<short-large-drive-root>" -CodexSourceRef "rust-v0.145.0-alpha.18" -AppServerVersion "0.145.0-alpha.18"`. For Desktop `26.707.3748.0`, use `-CodexSourceRef "rust-v0.144.0-alpha.4" -AppServerVersion "0.144.0-alpha.4"`. Historical `0.142.4` has a separate patch-apply-validated patch but is not yet fully compilation-validated; any other version needs exact matching parameters plus a validated `-PatchPathOverride`.
- Install it through `scripts\patch-remote-control-windows-msix.ps1 -ReplacementResourceCodexExe "<built-codex.exe>" -Install -Launch -InstallPrerequisites`.
- Verify the live installed `app\resources\codex.exe` contains `remote_control_app_server_isolated_oauth_used` and `remote_control_native_remote_json_first`, then verify logs from the WindowsApps app-server process show isolated remote auth from `.codex\remote.json`.
- If the same `API key auth is not supported` string remains in `logs_2.sqlite`, filter by `pid` and process path. Old Antigravity/VS Code extension app-server processes can keep logging the old failure after the WindowsApps package is fixed.

### Allow Dialog Fails After MFA

Symptoms:

- User completes browser MFA and clicks allow.
- Desktop still shows `Couldn't enable remote control. Try again`.

Checks:

- Check native logs in `%USERPROFILE%\.codex\sqlite\logs_2.sqlite`.
- If logs show `wss://chatgpt.com/backend-api/wham/remote/control/server` ending with Windows `os error 10060`, the failure is remote-control WebSocket networking, not OAuth.
- If the user runs v2rayN, check whether `127.0.0.1:10808` is listening.

Action:

- Use a native binary with WebSocket proxy support. After relaunch, correlate the WindowsApps native PID/path and verify `remote_control_websocket_proxy_connected`, a status transition to `Connected`, no repeated `os error 10060`, and an actual phone message round trip. Some source versions handle Ping/Pong without logging those frames, so do not require frame log text when the source has no such logging.

### Phone Says Codex Version Expired

Symptoms:

- QR scan works and phone discovers the desktop environment.
- Phone displays `Restart Codex` / `Codex version expired`.

Action:

- Check the replacement native `codex.exe --version`.
- If it reports `0.0.0`, or an older app-server version than the bundled native from the installed Desktop package, identify the matching Codex Rust source ref and workspace package version. The helper has distinct bundled mappings for `rust-v0.142.4`, `rust-v0.144.0-alpha.4`, and `rust-v0.145.0-alpha.18`; use `-PatchPathOverride` only after validating another version-specific patch.
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
- PID/path-correlated native logs show `remote_control_websocket_proxy_connected` and status `Connected` without repeated `os error 10060`; Ping/Pong frame logs are optional because some native versions handle them silently.
- Phone-sent chat reaches Desktop.
- After the phone message reaches Desktop, the model sampling request targets the user's intended current API endpoint. If it does not, handle that as the post-pairing configuration case above.
