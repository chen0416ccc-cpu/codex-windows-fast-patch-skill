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
| `0.6.11` | `26.810.6296.0` | `DE07F17A7206588687A8F722E4EBFC5A4FB1BD87F91DF2C60BB5C777C6D5CDCD` | `40530E628C91EF510F81A02FD3394C18E0D322C3D68D4A0277F0B0C56A2D43CC` |
| `0.6.11` | `26.810.7004.0` | `7A95D14EBF992955D8AB8E6C57A75545ED7D18E864B0F5C1B9FE7F47685BD897` | `E84A4ECB473CF9D3B4B65BB27A298DE6602AD8A1A11B21EE0BA7BC9209FE4DA9` |
| `0.6.16` | `26.814.5167.0` | `E40BE6145157885F0E155A4247DF3B64BD5D3455A04E276503B0E2821B3EA39E` | `F35CA6D89959EDEFB4DF46A5ECC6202091AB3C63E885E6CD6CF9824D92B66EB7` |
| `0.6.16-202608171739-pr-1311460-c66628846294` | `26.814.5517.0` | `BEB498C287889D807DCCB0E1FAD8A39ED9BE6BDF084D10313B5D52BA26C1E370` | `AF7D14EE6E2B850E06798EC14117D29F1C839DB5C135A7F515DE37074DB66A23` |
| `0.6.17-202608171537-pr-1300023-7efba775c041` | `26.818.2872.0` | `29D5E113A5D24A1DD3F3CCA4245CE5AE82A56E88AF5AFCD8E0AE4CC2E5C94992` | `DC83663FBF8DEF6749296B84EAE66054D2C07530CC42A87CA4503ECF86AD3767` |
| `0.6.17-202608171537-pr-1300023-7efba775c041` | `26.818.3698.0` | `DB8F4486D527C91B80266FAF77FDC38266B1D3960EFBBA35D0A6AAB4CAAF6AEE` | `6495168DC16A35CDC33230E6512D64E660B56D13E99FE239426D228B9F86E157` |

One `@oai/sky` version can ship more than one helper binary across Desktop builds, so the table is keyed by the complete hash pair, not by the version string alone. Both `0.6.11` rows use the same five guarded regions at the same offsets; `0.6.16` and `0.6.17` keep the same callback paths and guarded bytes, but each build family has distinct whole-file hashes. Identical reported versions can still cover different binaries, so a version comparison cannot tell them apart.

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
| `0.6.11` | `0x00047E01` | `0x140048A01` | Skip the optional border-interface failure path. |
| `0.6.11` | `0x0004CF86` | `0x14004DB86` | Send the busy/re-entry branch to the normal return tail. |
| `0.6.11` | `0x0004CF97` | `0x14004DB97` | Continue after the existing one-shot flag check. |
| `0.6.11` | `0x0014868F-0x0014873D` | `0x14014928F-0x14014933D` | Wrapper, thread creation/failure cleanup, and MTA worker. |
| `0.6.11` | `0x0014B128` | `0x14014C928` | Redirect the `FrameArrived` delegate vtable entry to the wrapper. |
| `0.6.16` | `0x00047E01` | `0x140048A01` | Skip the optional border-interface failure path. |
| `0.6.16` | `0x0004CF86` | `0x14004DB86` | Send the busy/re-entry branch to the normal return tail. |
| `0.6.16` | `0x0004CF97` | `0x14004DB97` | Continue after the existing one-shot flag check. |
| `0.6.16` | `0x001486AF-0x0014875D` | `0x1401492AF-0x14014935D` | Wrapper, thread creation/failure cleanup, and MTA worker. |
| `0.6.16` | `0x0014B128` | `0x14014C928` | Redirect the `FrameArrived` delegate vtable entry to the wrapper. |

The `0.6.16` rows apply unchanged to the `0.6.16-202608171739-pr-1311460-c66628846294` helper shipped with Desktop `26.814.5517.0`, and to both `0.6.17-202608171537-pr-1300023-7efba775c041` helpers shipped with Desktop `26.818.2872.0` and `26.818.3698.0`: same offsets, same original bytes, same patched bytes.

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
| Accessibility | Explorer tree length `8708`, including the expected folder name. |
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
| Accessibility | Explorer tree length `5723`, including the expected folder name. |
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

### `@oai/sky 0.6.11` / Desktop 26.810 validation

Desktop `26.810.6296.0` ships `@oai/sky 0.6.11` with original helper SHA-256 `DE07F17A7206588687A8F722E4EBFC5A4FB1BD87F91DF2C60BB5C777C6D5CDCD`. On Windows 10 build `19045`, window enumeration succeeded but screenshot capture reproduced `SetIsBorderRequired failed: 不支持此接口 (0x80004002)`.

- The `0.6.11` helper has the same `1,895,728`-byte image size as the validated `0.6.6` helper. Binary comparison found `5,596` changed bytes in `126` ranges, limited to the PE header and version/signing resources; the five guarded code/data regions above are byte-identical.
- IDA confirmed the same optional-interface failure path, original `FrameArrived` callback at `0x14004DB43`, one-shot/busy guards, vtable entry, executable padding, and unchanged IAT slots for `CreateThread`, `CloseHandle`, `RoInitialize`, and `RoUninitialize`.
- Applying the five guarded transformations in memory produced complete candidate SHA-256 `40530E628C91EF510F81A02FD3394C18E0D322C3D68D4A0277F0B0C56A2D43CC`. The isolated regression passed install, idempotent install, rollback, idempotent rollback, and unknown-hash rejection for both `0.6.11` and the prior `0.6.6` fixture.
- Live installation stored the original at `.codex\backups\computer-use-helper\26.810.6296.0-sky-0.6.11-DE07F17A\codex-computer-use.exe.original`. Both local verification modes passed afterward.

| Test | Result |
| --- | --- |
| Cold Explorer capture | Passed; `1125x639` image returned and the previous `0x80004002` error disappeared. |
| Repeated static capture | Ten identical Explorer frames completed in `32-47 ms`, followed by twenty more captures in `30-53 ms` (`35 ms` average). |
| Dynamic capture | Three Task Manager frames spaced two seconds apart completed; the second and third frames differed from their predecessor. |
| Accessibility | Explorer tree length `6588`, including the expected folder name. |
| Resource stability | After warm-up and repeated batches the main helper remained near `54-55` threads and `788-794` handles; no linear growth was observed. |
| Window enumeration | Explorer and Task Manager were both returned by `list_windows`; the test-created Task Manager window was closed afterward. |

As with every prior profile, this is an exact input/output hash pair. A later helper hash must be analyzed independently even when the guarded regions appear unchanged.

### `@oai/sky 0.6.11` helper `7A95D14E` / Desktop 26.810.7004.0 validation

Desktop `26.810.7004.0` ships `@oai/sky 0.6.11` again, but with a different helper binary: original SHA-256 `7A95D14EBF992955D8AB8E6C57A75545ED7D18E864B0F5C1B9FE7F47685BD897`. The version string alone was therefore not sufficient to select a profile, and the prior `DE07F17A` profile was correctly rejected as an unsupported hash before any patch attempt.

- Both helpers are `1,895,728` bytes. Binary comparison found `4,266` changed bytes across `75` ranges. Mapping every changed offset onto the PE section table placed `2` bytes in the PE header and `4,264` bytes in the overlay, with zero differences in `.text`, `.rdata`, `.data`, `.pdata`, `.fptable`, and `.reloc`. The new helper is code-identical to the validated one; the differences are the PE timestamp, version resource, and Authenticode signature.
- All five guarded regions were re-read from the new binary and matched the profile's original bytes exactly at the same offsets.
- Applying the five guarded transformations in memory produced complete candidate SHA-256 `E84A4ECB473CF9D3B4B65BB27A298DE6602AD8A1A11B21EE0BA7BC9209FE4DA9`, which the live install then reproduced exactly.
- Live installation stored the original at `.codex\backups\computer-use-helper\26.810.7004.0-sky-0.6.11-7A95D14E\codex-computer-use.exe.original`.
- The isolated regression passed `original -> patched -> idempotent install -> rollback -> idempotent rollback` plus unknown-hash rejection.

| Test | Result |
| --- | --- |
| Cold Explorer capture | Passed; `1125x639` image returned and no `0x80004002` error appeared. |
| Repeated static capture | Ten identical Explorer frames; first capture `476 ms` cold, remaining nine `31-45 ms`. |
| Dynamic capture | Eight Task Manager Performance-tab frames spaced `1.1 s` apart were all distinct (`8/8`), proving live frames rather than a cached first frame. |
| Accessibility | Explorer tree length `8234`; Task Manager tree resolved the tab control and `性能` tab item. |
| Resource stability | One helper process across `20` post-warm-up captures: threads `21 -> 23 -> 23`, handles `527 -> 542 -> 544`; both plateaued with no linear growth. |
| Window enumeration | Explorer, Task Manager, VS Code, and Clash Verge returned by `list_windows`; test-created windows were closed afterward. |

Because the Processes tab does not repaint while backgrounded, a dynamic-capture check must activate the window and select a continuously animating view; otherwise identical frames are expected and prove nothing about the `FrameArrived` patch.

### `@oai/sky 0.6.16` / Desktop 26.814.5167.0 validation

Desktop `26.814.5167.0` ships `@oai/sky 0.6.16` with a new `1,895,728`-byte helper. The original helper SHA-256 is `E40BE6145157885F0E155A4247DF3B64BD5D3455A04E276503B0E2821B3EA39E`; the previous profile was not reused by version number alone. Static analysis revalidated the optional-interface path, busy/one-shot guards, import slots, original `FrameArrived` callback, and a separate executable padding region at file offset `0x1486AF` (virtual address `0x1401492AF`). The vtable entry at `0x14B128` redirects from `43db044001000000` to `af92144001000000`.

- The guarded in-memory rewrite produces complete candidate SHA-256 `F35CA6D89959EDEFB4DF46A5ECC6202091AB3C63E885E6CD6CF9824D92B66EB7`. Integration testing independently reproduced that hash from a second exact-hash fixture without modifying the live helper.
- The wrapper retains the existing `CreateThread`, `CloseHandle`, `RoInitialize`, and `RoUninitialize` import slots and the original callback at `0x14004DB43`. No executable under `WindowsApps` is modified.
- The contributor's Windows 10 regression passed `original -> patched -> idempotent install -> rollback -> idempotent rollback`, complete input/output hash checks, and unknown-hash rejection. Integration testing on Windows build `26200` reproduced the candidate hash from a D-drive fixture, confirmed that the platform guard rejected `-Install` without changing the fixture, and repeated unknown-hash rejection. The contributed live run stored its original backup under `.codex\backups\computer-use-helper\26.814.5167.0-sky-0.6.16-E40BE614`.

The contributor's Windows 10 validation reported:

| Test | Result |
| --- | --- |
| Cold Explorer capture | Passed through the real Computer Use route; `1125x639` image returned and no `SetIsBorderRequired / 0x80004002` error recurred. |
| Repeated static capture | Ten unchanged Explorer captures succeeded; all underlying image data URLs had the same SHA-256 `49dd0400f32004013d8cd2854799d140e8d4b554a28dfd19bb57bafa265e9368`. |
| Dynamic capture | Eight Task Manager Performance-tab frames spaced about `1.2 s` apart were all distinct (`8/8`); each was `666x593`. |
| Accessibility | Task Manager text exposed the tab control with the `性能` item and live CPU, memory, disk, network, and GPU nodes; the captured tree was `4764` characters. |
| Resource stability | During twenty warm-up captures, the single main helper stayed at `51` threads / `784` handles across repeated half-second samples; no linear growth was observed. |
| Window enumeration | Explorer and Task Manager were returned by `list_windows`; the validation session used the existing helper and cursor-manager child. |

As with every other profile, this is an exact input/output hash pair. A later helper hash requires independent PE/code analysis and real static/dynamic Computer Use validation.

### `@oai/sky 0.6.17-202608171537-pr-1300023-7efba775c041` helper `29D5E113` / Desktop 26.818.2872.0 validation

Desktop `26.818.2872.0` reports `@oai/sky 0.6.17-202608171537-pr-1300023-7efba775c041` and ships a helper whose complete SHA-256 is `29D5E113A5D24A1DD3F3CCA4245CE5AE82A56E88AF5AFCD8E0AE4CC2E5C94992`. The `0.6.16` profiles were not reused, because the patcher requires the reported version string to equal the profile's declared `SkyVersion` and the whole-file hash to match. Region analysis found the five guarded regions unchanged from both `0.6.16` profiles: same file offsets, same original bytes, and the same patched bytes, including the `0x14B128` vtable redirect from `43db044001000000` to `af92144001000000`. Three consecutive Desktop builds now share one guarded-code layout while each ships a distinct whole-file hash.

- The guarded rewrite produces complete candidate SHA-256 `DC83663FBF8DEF6749296B84EAE66054D2C07530CC42A87CA4503ECF86AD3767`.
- The original backup is stored under `.codex\backups\computer-use-helper\26.818.2872.0-sky-0.6.17-202608171537-pr-1300023-7efba775c041-29D5E113`, so no two helper profiles share a backup directory.
- No executable under `WindowsApps` is modified. The helper lives in the user-level `cua_node` runtime at `bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe`.
- `scripts/test-computer-use-helper-win10-patch.ps1 -SkyVersion 0.6.17-29D5E113` passed `original -> patched -> idempotent install -> rollback -> idempotent rollback` with complete input/output hash checks and unknown-hash rejection, reporting `ALL_TESTS_PASSED`. Re-running the harness for `0.6.16` and `0.6.11-7A95D14E` still reports `ALL_TESTS_PASSED`.
- A read-only run of the patcher reports `State: patched`, `EndToEndValidatedDesktopVersion` equal to `CurrentDesktopVersion` (`26.818.2872.0`), and Windows build `19045`.

Windows 10 validation on build `19045` reported:

| Test | Result |
| --- | --- |
| Runtime import | `runtime import ok` with `method=list_windows` returning the animated capture target. |
| Static capture | Eight captures, all eight frames unique; no cached first frame was returned. |
| Dynamic capture | Twenty captures of a continuously animating view, all twenty frames unique; twenty-eight unique frames across both batches. |
| Resource stability | Helper worker threads went `57 -> 59` and then stayed at `59` for every later capture; handles went `693 -> 699` and then oscillated between `697` and `699`; working set stayed at `56 MB`; the broker process stayed flat at `4` threads / `164` handles. No linear growth. |
| Error signature | No `SetIsBorderRequired`, `0x80004002`, or `E_NOINTERFACE` occurred in any capture, and the helper wrote nothing to stderr. |

Two capture-target constraints were confirmed while building that evidence, and both are independent of this patch:

- Computer Use refuses to act on a browser window on Windows and ends the turn with `could not determine the current browser URL on Windows with enough confidence to enforce policy`. A dynamic-capture target must therefore be a non-browser window.
- `list_windows` does not enumerate a window hosted by `powershell.exe`; it attributes windows to the owning image and reports an unknown owner as `process:<full path>`. A dynamic-capture fixture must be a real executable.

As with every other profile, this is an exact input/output hash pair. A later helper hash requires independent PE/code analysis and real static/dynamic Computer Use validation.

### `@oai/sky 0.6.17-202608171537-pr-1300023-7efba775c041` helper `DB8F4486` / Desktop 26.818.3698.0 validation

Desktop `26.818.3698.0` reports the same `@oai/sky 0.6.17-202608171537-pr-1300023-7efba775c041` version string as Desktop `26.818.2872.0` but ships a different helper binary, complete SHA-256 `DB8F4486D527C91B80266FAF77FDC38266B1D3960EFBBA35D0A6AAB4CAAF6AEE`. The `29D5E113` profile was correctly rejected as an unsupported hash before any patch attempt, which is the first case where two Desktop builds report an identical version string and still require separate profiles. PE analysis proved the new helper is code-identical:

- Both helpers are `1,895,728` bytes with an identical section table (`.text` raw `0x400-0x148800`, `.rdata` `0x148800-0x1B5A00`, `.data`, `.pdata`, `.fptable`, `.reloc` ending at `0x1CB000`).
- Binary comparison found `966` changed bytes across `47` ranges. Mapping every changed offset onto the PE section table placed `2` bytes in the PE header (the optional-header `CheckSum` field at file offset `0x158`) and `964` bytes in the overlay, with zero differences in `.text`, `.rdata`, `.data`, `.pdata`, `.fptable`, and `.reloc`. Unlike the `7A95D14E` migration, even the version resource is unchanged: the only differences are the PE checksum and the Authenticode signature, so this build is a re-signed copy of the validated code.
- All five guarded regions were re-read from the new binary and matched the profile's original bytes exactly at the same offsets, including the `0x14B128` vtable redirect from `43db044001000000` to `af92144001000000`.
- Applying the profile's patched bytes to the `29D5E113` original reproduced its published candidate hash `DC83663FBF8DEF6749296B84EAE66054D2C07530CC42A87CA4503ECF86AD3767` exactly, which validates the transformation before it is applied to the new binary.
- The guarded rewrite produces complete candidate SHA-256 `6495168DC16A35CDC33230E6512D64E660B56D13E99FE239426D228B9F86E157`.
- The original backup directory is keyed by the helper hash prefix, so the `29D5E113` and `DB8F4486` profiles never share a backup directory even though their version strings are identical.
- `scripts/test-computer-use-helper-win10-patch.ps1 -SkyVersion 0.6.17-DB8F4486` passed `original -> patched -> idempotent install -> rollback -> idempotent rollback` with complete input/output hash checks and unknown-hash rejection, reporting `ALL_TESTS_PASSED`. Re-running the harness for `0.6.17-29D5E113`, `0.6.16`, and `0.6.11-7A95D14E` still reports `ALL_TESTS_PASSED`.

As with every other profile, this is an exact input/output hash pair. Code-identity evidence justifies reusing the guarded regions; it does not remove the hash guard.

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

These are upgrade-repair regression checks for the `0.4.20` profile. The deeper end-to-end helper validations were performed on Desktop `26.707.12708.0` for `0.4.20`, Desktop `26.721.4979.0` for `0.5.2`, Desktop `26.803.10989.0` for `0.6.6`, Desktop `26.810.6296.0` and `26.810.7004.0` for the two `0.6.11` hashes, and Desktop `26.814.5167.0` for `0.6.16`; each complete helper hash pair, not a Desktop version by itself, remains the compatibility boundary.

Repeated static captures can appear as alternating complete/black composites in the conversation renderer. In the validated run, every underlying static image data URL had the same length and SHA-256, so that presentation artifact was not a corrupted helper frame.
