# Windows 10 Computer Use Screenshot Backend

> These are hash-specific native helper compatibility profiles, not a generic binary patch. They support only the exact `@oai/sky` helper SHA-256 pairs listed below. Unknown hashes must remain untouched.

## When to use this profile

Use this profile only when all of the following are true:

- The machine is Windows 10, normally build `19045`.
- Computer Use can enumerate apps or windows, but screenshot capture fails with `SetIsBorderRequired failed: The requested interface is not supported (0x80004002)`.
- The selected runtime helper is `codex-computer-use.exe` from the user-level CUA runtime, not a file under `C:\Program Files\WindowsApps`.
- Its SHA-256 is either the supported original hash or the already-patched hash. The Desktop package number is evidence, but the complete helper hash is the compatibility boundary.

| `@oai/sky` | End-to-end validated Desktop | Original SHA-256 | Patched SHA-256 |
| --- | --- | --- | --- |
| `0.4.20` | `26.707.12708.0` | `F2B2F56FCD1699B0FA32DEC3214A56A1D36B937A2ECF58CC822AB4A904551E03` | `71A13CBC4BB333F0707D2311C99DBA54D8B24D1BBB9F7CE25C3B9386577FFDDA` |
| `0.5.2` | `26.721.4979.0` | `2C4CAC168200520C2752058177EA9FE7D1CCF9A26B7287DDDFF669D41CA9AF16` | `D816B14A80370697380BA702863DA9528AA5B73ED34C2B189ACE2BF9E103BEFF` |
| `0.6.6` | `26.803.10989.0` | `BE488E66C38E12FA46850EE48C1F5E44ECDB0A3A64042E064E3A1A1DA286AC42` | `34D6EB4F23630AD6E7211898AA7678472C9ED7ACFD972C78B7D9E575A1C5C640` |

The `0.4.20` original helper was also observed in Desktop `26.715.2305.0` by package inspection. That observation did not create a separate end-to-end profile. The patcher is `scripts/patch-computer-use-helper-win10.ps1`.

Do not use this profile for a plugin import error, missing helper path, stale native-host manifest, disabled Desktop feature gate, or an unsupported helper hash. Those cases still follow the normal Computer Use Only or MSIX routing in `SKILL.md`.

## Root cause

Two independent Windows 10 compatibility failures were confirmed.

1. The helper treats `IGraphicsCaptureSession3::IsBorderRequired` as mandatory. Windows 10 does not expose that optional interface, so `QueryInterface` returns `E_NOINTERFACE` (`0x80004002`) and the helper aborts an otherwise valid capture session.
2. Skipping the optional border call exposes a second failure. The `FrameArrived` delegate starts `SoftwareBitmap.CreateCopyFromSurfaceAsync`, installs its completion handler, and then waits synchronously. On Windows 10 the asynchronous surface copy cannot complete until the `FrameArrived` callback returns, so the callback and copy operation deadlock each other.

Debug evidence showed that session setup itself was healthy: `StartCapture`, `add_FrameArrived`, `FrameArrived`, and `TryGetNextFrame` all returned successfully before the synchronous wait stalled.

## Patch design

The patch keeps the existing frame acquisition, SoftwareBitmap conversion, JPEG encoding, result channel, and error handling. It changes only the Windows 10-incompatible boundaries:

- Failure to obtain the optional border-control interface continues into normal capture setup.
- The callback vtable points to a small wrapper in an existing executable padding region.
- The wrapper uses a byte in the existing closure as a one-shot scheduling flag, retains the delegate, creates one worker thread, and returns immediately.
- The worker initializes WinRT as MTA, calls the original callback body, uninitializes WinRT, releases the delegate, and exits.
- Re-entry while a request is already scheduled follows the original normal return path instead of the error path.

No executable is stored in this repository. The patcher reconstructs the validated result from guarded byte ranges and refuses to write unless the complete input and output hashes match the profile.

| `@oai/sky` | File offset | Virtual address | Purpose |
| --- | --- | --- | --- |
| `0.4.20` | `0x000BB5D1` | `0x1400BC1D1` | Skip the optional border-interface failure path. |
| `0.4.20` | `0x000BFA4F` | `0x1400C064F` | Send the busy/re-entry branch to the normal return tail. |
| `0.4.20` | `0x000BFA60` | `0x1400C0660` | Continue after the existing one-shot flag check. |
| `0.4.20` | `0x0012C94E-0x0012C9FC` | `0x14012D54E-0x14012D5FC` | Wrapper, thread creation/failure cleanup, and MTA worker. |
| `0.4.20` | `0x0013C050` | `0x14013D650` | Redirect the `FrameArrived` delegate vtable entry to the wrapper. |
| `0.5.2` | `0x000BC7C1` | `0x1400BD3C1` | Skip the optional border-interface failure path. |
| `0.5.2` | `0x000C0C3F` | `0x1400C183F` | Send the busy/re-entry branch to the normal return tail. |
| `0.5.2` | `0x000C0C50` | `0x1400C1850` | Continue after the existing one-shot flag check. |
| `0.5.2` | `0x0012DF37-0x0012DFE5` | `0x14012EB37-0x14012EBE5` | Wrapper, thread creation/failure cleanup, and MTA worker. |
| `0.5.2` | `0x0013D918` | `0x14013E918` | Redirect the `FrameArrived` delegate vtable entry to the wrapper. |
| `0.6.6` | `0x00047E01` | `0x140048A01` | Skip the optional border-interface failure path. |
| `0.6.6` | `0x0004CF86` | `0x14004DB86` | Send the busy/re-entry branch to the normal return tail. |
| `0.6.6` | `0x0004CF97` | `0x14004DB97` | Continue after the existing one-shot flag check. |
| `0.6.6` | `0x0014868F-0x0014873D` | `0x14014928F-0x14014933D` | Wrapper, thread creation/failure cleanup, and MTA worker. |
| `0.6.6` | `0x0014B128` | `0x14014C928` | Redirect the `FrameArrived` delegate vtable entry to the wrapper. |

## Apply and verify

First run the script without a write mode. It reports `original-patchable`, `patched`, or `unsupported`:

```powershell
$patcher = "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-computer-use-helper-win10.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $patcher
```

For an exact original helper fixture, `-ComputeCandidateHash` performs the guarded byte transformation in memory and returns the complete candidate SHA-256 without writing the helper. This regression path is intentionally usable on a non-Windows-10 development host; it does not bypass the Windows 10 gate for `-Install`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $patcher -HelperPath "<fixture-helper>" -ComputeCandidateHash
```

Install only after the reported path, version, build, and hash match the supported profile:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $patcher -Install
```

The installer writes a verified original backup under:

```text
%USERPROFILE%\.codex\backups\computer-use-helper\<desktop-version>-sky-<sky-version>-<original-hash-prefix>\codex-computer-use.exe.original
```

Then run the existing local plugin checks:

```powershell
$localRepair = "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $localRepair -VerifyOnly
powershell -NoProfile -ExecutionPolicy Bypass -File $localRepair -StrictVerifyOnly
```

Finally validate the real Computer Use route, not a separate screenshot utility:

- First Explorer screenshot after a helper restart.
- Repeated screenshots of the same static window.
- A dynamic Task Manager performance view with captures spaced about two seconds apart.
- Accessibility text and `list_windows`.
- Thread and handle counts after warm-up and after repeated batches.

## Roll back

Rollback is also hash guarded. It accepts only the validated patched helper and the matching original backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $patcher -Rollback
```

After rollback, the helper SHA-256 must be the original profile hash. A later Store or runtime update with a different helper hash requires a fresh analysis; do not migrate these offsets by assumption.

## Validated evidence

The helper profile passed the following Windows 10 tests on Desktop `26.707.12708.0`:

| Test | Result |
| --- | --- |
| Cold Explorer capture | Passed; first capture about `629 ms`. |
| Repeated static capture | Two batches of ten, all successful; subsequent captures about `31-96 ms`. |
| Resource stability | Warm-up baseline `24` threads / `506` handles; batches settled at `18/501` and `19/503`, with no linear growth. |
| Dynamic capture | Three Task Manager performance frames two seconds apart produced three distinct image-data hashes. |
| Accessibility | Explorer tree length `8708`, including `Antigravity`. |
| Window enumeration | Explorer and Task Manager both returned by `list_windows`. |
| Local plugin verification | `client import ok`, `helper transport ok`, and `verification ok`. |

### `@oai/sky 0.5.2` / Desktop 26.721 validation

Desktop `26.721.4979.0` introduced `@oai/sky 0.5.2` with original helper SHA-256 `2C4CAC168200520C2752058177EA9FE7D1CCF9A26B7287DDDFF669D41CA9AF16`. The old offsets were not reused. Migration evidence was rebuilt on Windows 10 build `19045`:

- The exact `0.4.20` original/patched pair differed by `169` bytes. The `0.5.2` `FrameArrived` callback and normal-return tail matched the old implementation and moved by `+0x11F0`; the vtable uniquely pointed to the new callback.
- The optional-interface path, callback guards, import slots, and executable tail padding were independently located in `0.5.2`. The reconstructed offline result remained a valid x64 PE, differed by the same `169` bytes, and produced complete output SHA-256 `D816B14A80370697380BA702863DA9528AA5B73ED34C2B189ACE2BF9E103BEFF`.
- Disassembly of the reconstructed wrapper resolved to the new `CreateThread`, `CloseHandle`, `RoInitialize`, and `RoUninitialize` IAT slots and the new original callback address. No `WindowsApps` file was edited in place.
- An isolated lifecycle test passed `original -> patched -> idempotent install -> rollback -> idempotent rollback`. The live install stored the original at `.codex\backups\computer-use-helper\26.721.4979.0-sky-0.5.2-2C4CAC16\codex-computer-use.exe.original`, then verified the complete patched hash. A transient first install attempt encountered a still-closing helper image lock and left the live hash unchanged; the patcher now waits up to five seconds for each stopped helper process before replacement.
- `install-computer-use-local.ps1 -VerifyOnly` and `-StrictVerifyOnly` both returned `client import ok`, `helper transport ok`, and `verification ok`, without replacing the patched helper.

| Test | Result |
| --- | --- |
| Cold Explorer capture | Passed through the plugin's `computer-use-client.mjs`; `945x639` image returned and the previous `SetIsBorderRequired / 0x80004002` error disappeared. |
| Repeated static capture | Two batches of ten succeeded. Captures were about `25-50 ms`; all ten data URLs within each unchanged foreground batch had an identical SHA-256. |
| Screenshot resource stability | Main helper baseline after the first capture was `59` threads / `658` handles, plus the expected one-thread cursor-manager child at `162` handles. After twenty static captures and a two-second settle it was `55/665` plus `1/162`, with no linear growth. |
| Dynamic capture | Three Task Manager performance frames spaced two seconds apart completed in `32-39 ms` and produced three distinct SHA-256 values. A further ten screenshot-only captures completed in `24-37 ms`. |
| Accessibility | Explorer tree length `5723`, including `Antigravity`. |
| Window enumeration | Explorer and Task Manager were returned by `list_windows`; the test-created Task Manager window was closed afterward. |
| Session cleanup | Both the main helper and cursor-manager child exited when the Computer Use validation session ended; no helper process remained. |

The helper captures a monitor-backed window region on this Windows 10 route. Activate the target before deterministic content validation; if another foreground window overlaps it, the returned region can contain that occluder even though transport itself remains healthy.

### `@oai/sky 0.6.6` / Desktop 26.803 validation

Desktop `26.803.10989.0` ships `@oai/sky 0.6.6` with original helper SHA-256 `BE488E66C38E12FA46850EE48C1F5E44ECDB0A3A64042E064E3A1A1DA286AC42`. The prior profiles were not reused. A fresh Windows 10 build `19045` analysis located the new optional-interface path, callback guards, import slots, executable padding, and vtable target:

- The exact guarded rewrite changes five regions: optional-border path at file offset `0x47E01` (`4889c34189d6eb50` -> `e980000000909090`), busy return at `0x4CF86` (`0f85f5340000` -> `0f85d8340000`), one-shot flag at `0x4CF97` (`740d` -> `eb0d`), a 175-byte MTA wrapper at `0x14868F`, and the callback vtable pointer at `0x14B128` (`43db044001000000` -> `8f92144001000000`).
- IDA/radare2 resolution confirmed the wrapper's `CreateThread`, `CloseHandle`, `RoInitialize`, and `RoUninitialize` IAT calls and the original `FrameArrived` callback at `0x14004DB43`. The wrapper VA is `0x14014928F`; no executable under `WindowsApps` was modified.
- On Windows 10, the isolated regression script `scripts/test-computer-use-helper-win10-patch.ps1` passed `original -> patched -> idempotent install -> rollback -> idempotent rollback`, complete input/output SHA-256 checks, and rejection of an unknown hash. On newer Windows builds, the same script verifies the in-memory candidate hash, proves that `-Install` is rejected without changing the fixture, and still checks unknown-hash rejection. The live Windows 10 install stored the original at `.codex\backups\computer-use-helper\26.803.10989.0-sky-0.6.6-BE488E66\codex-computer-use.exe.original`.
- After installation, `install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable` returned `runtime import ok` and `verification ok`. A persistent Node REPL was reset; `sky.list_windows()` ran in one call, then independent calls activated the `D:\Program Files\IDA.PRO` Explorer window and returned a `1125x639` screenshot. The inspected image showed the expected `kg_patch`, `misc`, and `portable_win` entries, and the repeated independent screenshot also returned normally. The former `SetIsBorderRequired / 0x80004002` failure did not recur.
- Cold capture completed in about `452 ms`; two later batches of ten unchanged Explorer captures all succeeded in about `31-48 ms`, with one stable SHA-256 per batch. Accessibility text length was `3419`.
- Main-helper resources were `58` threads / `661` handles after the first capture and `55/662` after twenty static captures plus a two-second settle. The cursor-manager child remained at one thread / `166` handles, with no linear growth.
- In a fresh helper session, three CPU Performance-page Task Manager captures spaced about `2.1` seconds apart were each `666x593`, completed in `50-51 ms`, and produced three distinct SHA-256 values: `42764DC1...A68C1`, `6AB486EA...B787`, and `6845A929...7A361`. The test-created Task Manager window was closed afterward.

This profile has a complete hash guard plus real cold, repeated-static, dynamic-image-change, accessibility, enumeration, and post-warm-up resource-stability validation. It has not been promoted to a generic cross-version rule; any later helper update must be analyzed and validated independently. Unknown hashes remain untouched.

### Desktop 26.715 upgrade-repair regressions

The Store upgrade to Desktop `26.715.2305.0` (`codex-cli 0.145.0-alpha.18`) was also checked after a full MSIX repatch on Windows 10 build `19045`:

- The live package was restored from `SignatureKind=Store` to `SignatureKind=Developer`, and a second full dry run reported every patch target as `already-patched`.
- Fast Mode wire verification reached `/v1/responses` with `service_tier=priority`.
- The Fast verifier used the copied work-package CLI because the installed WindowsApps CLI was not directly executable under the package ACL; no manual `PATH` override was required after the verifier fallback was added.
- The selected `@oai/sky 0.4.20` runtime helper remained at the documented patched SHA-256; no binary rewrite or cross-version helper copy was needed.
- `install-computer-use-local.ps1 -StrictVerifyOnly` passed with `client import ok`, `helper transport ok`, and a `1920x1080` screenshot transport.
- Current-startup Desktop logs reported `computer-use native pipe startup ready`, browser availability as `reason=local-patched`, and all seven bundled plugins in the runtime marketplace, without the documented negative marketplace/helper-path markers.

The later Store upgrade to Desktop `26.715.3651.0` (the same `codex-cli 0.145.0-alpha.18`) was rechecked on 2026-07-18. No new ASAR patch target was required:

- The package was restored from `SignatureKind=Store` to `SignatureKind=Developer`; the signed patched MSIX SHA-256 was `3E010051AA8E21CF92E6531FE5EEE9B0941A890C8FB7AA5AFC639165E3D28A8C`, and a full idempotency dry run reported every target as `already-patched`.
- A missing `computer-use` cache manifest and a five-plugin runtime marketplace were repaired locally. After restart, all seven bundled plugins were installed and enabled, browser availability reported `reason=local-patched`, the native pipe was ready, and no documented marketplace/helper-path/integrity failure marker appeared.
- Fast wire verification again reached `/v1/responses` with `service_tier=priority`; strict Computer Use verification returned a `1920x1080` screenshot while the helper retained the documented patched SHA-256.
- Chrome extension, native-host manifest, launch dry run, and the Windows sandbox smoke test passed.

These are upgrade-repair regression checks for the `0.4.20` profile. The deeper end-to-end helper validations were performed on Desktop `26.707.12708.0` for `0.4.20`, Desktop `26.721.4979.0` for `0.5.2`, and Desktop `26.803.10989.0` for `0.6.6`; each complete helper hash pair, not a Desktop version by itself, remains the compatibility boundary.

Repeated static captures can appear as alternating complete/black composites in the conversation renderer. In the validated run, every underlying static image data URL had the same length and SHA-256, so that presentation artifact was not a corrupted helper frame.
