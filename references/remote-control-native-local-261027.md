# Desktop 26.1027 Native-Local Candidate

This is a version-pinned candidate, not a generally enabled full-phone profile.
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

Real installed-process connection, UI pairing and a phone message round trip
remain pending. Do not label this candidate a completed phone repair yet.
