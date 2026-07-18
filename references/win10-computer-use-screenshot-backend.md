# Windows 10 Computer Use Screenshot Backend

> This is a hash-specific native helper compatibility profile, not a generic binary patch. It supports only `@oai/sky 0.4.20` with the exact original helper SHA-256 listed below. Unknown hashes must remain untouched.

## When to use this profile

Use this profile only when all of the following are true:

- The machine is Windows 10, normally build `19045`.
- Computer Use can enumerate apps or windows, but screenshot capture fails with `SetIsBorderRequired failed: The requested interface is not supported (0x80004002)`.
- The selected runtime helper is `codex-computer-use.exe` from the user-level CUA runtime, not a file under `C:\Program Files\WindowsApps`.
- Its SHA-256 is either the supported original hash or the already-patched hash. The Desktop package number is evidence, but the complete helper hash is the compatibility boundary.

| Field | Value |
| --- | --- |
| End-to-end validated Desktop | `26.707.12708.0` |
| Same original helper observed in | `26.715.2305.0` (package inspection only; not a new end-to-end claim) |
| `@oai/sky` | `0.4.20` |
| Original SHA-256 | `F2B2F56FCD1699B0FA32DEC3214A56A1D36B937A2ECF58CC822AB4A904551E03` |
| Patched SHA-256 | `71A13CBC4BB333F0707D2311C99DBA54D8B24D1BBB9F7CE25C3B9386577FFDDA` |
| Patcher | `scripts/patch-computer-use-helper-win10.ps1` |

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

| File offset | Virtual address | Purpose |
| --- | --- | --- |
| `0x000BB5D1` | `0x1400BC1D1` | Skip the optional border-interface failure path. |
| `0x000BFA4F` | `0x1400C064F` | Send the busy/re-entry branch to the normal return tail. |
| `0x000BFA60` | `0x1400C0660` | Continue after the existing one-shot flag check. |
| `0x0012C94E-0x0012C9FC` | `0x14012D54E-0x14012D5FC` | Wrapper, thread creation/failure cleanup, and MTA worker. |
| `0x0013C050` | `0x14013D650` | Redirect the `FrameArrived` delegate vtable entry to the wrapper. |

## Apply and verify

First run the script without a write mode. It reports `original-patchable`, `patched`, or `unsupported`:

```powershell
$patcher = "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\patch-computer-use-helper-win10.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $patcher
```

Install only after the reported path, version, build, and hash match the supported profile:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $patcher -Install
```

The installer writes a verified original backup under:

```text
%USERPROFILE%\.codex\backups\computer-use-helper\<desktop-version>-sky-0.4.20-F2B2F56F\codex-computer-use.exe.original
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

This is an upgrade-repair regression check. The repeated static captures, dynamic-frame checks, accessibility/window tests, and resource-stability run in the table above remain the deeper end-to-end helper validation performed on Desktop `26.707.12708.0`; the helper hash pair, not either Desktop version, remains the compatibility boundary.

Repeated static captures can appear as alternating complete/black composites in the conversation renderer. In the validated run, every underlying static image data URL had the same length and SHA-256, so that presentation artifact was not a corrupted helper frame.
