# Desktop 26.1027 Native-Local Repair

This is a version-pinned repair, not a generally enabled full-phone profile.
The settings-only repair remains separate. Do not use a prior 0.154 executable
or force pairing/upgrade gates for this layout.

## Native Boundary

- Source: official `rust-v0.166.0-alpha.5.1`, commit
  `f79b26ccbb3116b052544666a181012fb45dc49b`.
- Patch: `remote-control-native-replacement-0.166.0-alpha.5.1.patch`.
- Windows only: when main auth is absent or an API key, read `remote.json` from
  the auth manager's actual Codex home. Do not change the main auth manager.
- Preserve account/principal owner binding and network policy. Managed, forced,
  external/workload auth requirements fail closed rather than using this fallback.
- Admit the issuer, audience, expiry, scopes, account and HTTP header shape; the
  official backend remains responsible for signature and authorization validation.
- Bind the connection owner to file SHA-256 and expiry. Replacement, removal,
  expiry or policy changes revoke the old owner. Do not automatically refresh
  or perform main-account recovery for isolated credentials.
- Existing native server enrollment and server-token pairing are unchanged.
  Official transport retains its network-policy-aware WebSocket connector.

The published source tag has workspace packages at `0.166.0-alpha.5.1` but
170 local workspace lock entries at `0.0.0`. The validated local build changed
only those workspace lock versions, not third-party versions/checksums. Do not
run a general `generate-lockfile` upgrade as a substitute.

The generic native build helper has NOT acquired an automatic 0.166 mapping:
its legacy binary-marker acceptance contract is not this transport contract.
Do not invoke it and silently substitute old patches. A future integration
must preserve these owner-lifetime and policy checks and test the lock handling.

## Frontend Boundary

`scripts/patch-remote-control-native-local-261027.cjs` only accepts the complete
original `app-initial-4267e52fe5b0.js` hash:
`23ced6d1a2456e0a669c3dd69cc8abc387a476c8e51fbb528b85da19240c95ac`.
It writes a separate candidate, refusing source overwrite or an existing output.
Run with Node's `--experimental-vm-modules` for full module parsing.

In API/null-main mode, device listing and setup resume use native local RPC.
Only a Connected status with the expected environment permits pairing preflight.
Automatic legacy browser MFA queries return no MFA result in that mode: this
is not a claim that MFA is enabled or unnecessary; native server enrollment
and pairing still decide authorization. ChatGPT-main MFA checks are unchanged.
Remote HTTP 401 remains an error but does not invalidate the main login.
The generic fetch path and token exposure to the renderer are unchanged.

No changes to `codex-mobile-setup-flow` are needed in the inspected layout:
the device query key depends on the catalog environment ID and is refreshed
when native identity updates it. Pairing still uses both official rollout and
upgrade gates and waits for Connected before requesting a server pairing code.
SSH host routing remains native to that host.

If the user requires all newly materialized native cache data off C:,
`patch-remote-control-native-cache-261027.cjs` accepts only resolver hash
`a785e3304e4e229cb5779d952475483e306bcf9ca7b34b8f21df15cea55c648a`
from `early-bootstrap-824-e56448c7829c41c2.js`. It changes only the Windows
Codex executable destination, leaving hash verification, sibling copying,
atomic staging, other components and non-Windows behavior intact. Supply an
explicit D:-Z: ordinary local destination and verify its ancestors are not
reparse points; restrict its root ACL to the user, SYSTEM and administrators.
Do not move the global CLI cache or edit global environment variables.

```powershell
node --experimental-vm-modules scripts/test-remote-control-native-local-261027.cjs <original-app-initial-asset>
node --experimental-vm-modules scripts/patch-remote-control-native-local-261027.cjs <original-app-initial-asset> <new-candidate-file>
```

## Validation And Deployment

The exact source patch passed the full app-server-transport library suite:
171 tests passed, including 10 new tests. This clean run cleared inherited
proxy variables only in the test process and ran serially; the first inherited-
proxy parallel run was 169/171. The complete CLI built and reports the matching
version. Frontend tests pass 22 cases, including automatic MFA query behavior,
catalog query-key invalidation and unmodified pairing gates.

A complete-CLI stdio RPC test against a local HTTP/WebSocket fixture passed
list, enrollment version, Connected status, pairing, missing/mismatched auth,
credential-file replacement revocation, unchanged main API auth/config and
no isolated bearer on unrelated plugin requests. Those tests use fictitious
tokens; they do not prove real backend connection or phone acceptance.

For deployment, create a higher-revision signed recovery MSIX containing the
current program, then a lower-revision patch containing only manifest, launcher
ASAR integrity, the frontend asset, optional native-cache resolver asset and
the exact native replacement. Compare
all package files and every ASAR entry, validate signatures/block maps, back up
user data and compare config semantics before/after. Desktop may legitimately
regenerate its CUA command path and native pipe directory: preserve them rather
than restoring stale paths. Use ordinary UAC and an independent executor.
Keep transaction checkpoints before relaunch so app interruption cannot erase
the observed deployment state.

## System Proxy And Restart

Native 0.166 already supports `features.respect_system_proxy = true`. When
isolated auth is accepted but WebSocket connections fail with Windows
`os error 10060`, inspect the current Desktop/native process environments and
Windows proxy settings before rebuilding. The default WebSocket policy can
inherit environment proxies without consulting the Windows system proxy.
HTTP reachability alone does not establish a working WebSocket connection.

If the Windows proxy is configured and a read-only native probe using that
feature reaches the official remote API, back up the existing config on the
user's requested work drive, add only that boolean to the existing features
table, and validate TOML plus all other config semantics. Do not append a
second features table. Confirm the actual native `features list` reports it
enabled, then perform one authorized controlled restart, not another MSIX
install. Explain that the option affects the whole native HTTP/proxy policy,
including model traffic; it is not a remote-only proxy switch. Preserve the
provider, endpoint, credentials, existing NO_PROXY and global environment.

An isolated read-only probe must disable remote transport, never enroll or
enable it merely to test HTTP, keep all temporary files on the requested
drive, and remove its credential copy when it exits. Do not repeat browser
OAuth if the existing isolated credential is still valid.

Windows PowerShell 5.1 can remove nested quotes in `python -c` arguments. Use
a saved script file for protected config checks and test the actual 5.1
invocation before scheduling a restart. Save a deployment checkpoint before
closing Desktop. If the helper exits without its final record, inspect the
registered package, new process pair, payload hashes and protected state; do
not keep waiting on a dead PID or repeat an observed successful deployment.

The regenerated `node_repl.env.CODEX_CLI_PATH` can also change when using the
optional non-system cache. Accept only the configured destination's exact
hash child and the complete verified native executable hash, rather than
ignoring arbitrary CLI paths. A verifier that only searches the old C: cache
has a tooling limitation; never copy another executable to C: to hide it.

## Point-In-Time Acceptance

On 2026-11-02, Desktop `26.1027.3384.4` with native `0.166.0-alpha.5.1`
was installed in place. Installed ASAR integrity and the packaged/running
native hashes matched the validated candidates. The user explicitly
confirmed the phone was connected and usable after the system-proxy feature
and restart. Main provider/config semantics and isolated credential hashes
were preserved, no main `auth.json` was created, and `plugin list --json`
succeeded. This is real user acceptance of that exact version pair.

Keep evidence layers separate: an official native read-only client-list
request succeeded, but the repair run did not independently capture a fresh
WebSocket Connected event for the final process, a phone-message round trip,
or its model sampling request URL. Do not fabricate those checks from the
user report or the local fixture. The legacy strict verifier's C:-only CLI
lookup and the pre-existing independent CUA proxy check were not repaired.
Unknown future versions still fail closed, and no automatic generic 0.166
builder mapping is implied by this acceptance.

## Cleanup

After acceptance, remove task-created extraction/source/build/test/cache
trees and duplicate candidates. Keep the current native cache and active
isolated auth: deleting them breaks the installed repair. Normally retain
explicit backups and recovery packages; if the user explicitly requests no
repair artifacts, they may be removed after publication/merge and final
protected-state checks. Verify exact absolute targets, reject reparse paths
and live process references, and preserve pre-existing files and unrelated
local skill overlays. Do not claim byte-for-byte pre-repair cleanliness:
updated skill/program/config/auth and normal app state remain necessary.
