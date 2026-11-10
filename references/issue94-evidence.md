# Issue #94: Windows 10 screenshot helper 58FFF5E2

Original: `58FFF5E2359AA09528F48EF37651B9013B204F99E2FD381F0D3D980CF9D2E88D`

Candidate: `A7EF05E4DABAD5E9ED22709C3A7928A21D40689DB274276206EF25E87456670C`

Sample: bundled helper from Codex Desktop 26.1007.21434, build 13901, @oai/sky 0.7.6 on Windows 10 x64 build 19045.

| Region | File offset | Bytes | Compared with 63C98C4D |
|---|---:|---:|---|
| pe-section-count | 0x86 | 2 | Matched |
| pe-size-of-code | 0x9c | 4 | Matched |
| pe-size-of-image | 0xd0 | 4 | Matched |
| pe-checksum | 0xd8 | 4 | Adapted |
| pe-certificate-directory | 0x128 | 8 | Adapted |
| mta-section-header | 0x318 | 40 | Matched |
| mta-wrapper-and-unwind | 0x176e00 | 512 | Adapted |
| frame-arrived-busy-return | 0x418be | 6 | Matched |
| frame-arrived-once-flag | 0x418cf | 2 | Matched |
| frame-arrived-vtable | 0x12c8c8 | 8 | Matched |
| pe-exception-directory-size | 0x124 | 4 | Matched |
| pdata-virtual-size | 0x208 | 4 | Matched |
| mta-runtime-functions | 0x1574d8 | 24 | Matched |

The candidate was rebuilt from the exact original hash and matched the saved candidate byte for byte. The patch adds a profile and leaves the shared platform checks, unknown-input rejection, backup and rollback code untouched. The modified helper does not retain a valid original signature.

Runtime checks on this candidate: repeated Notepad capture, indexed Format menu click and Escape, repeated after a desktop app restart. A full Windows reboot and a game-specific test were not independently verified for this candidate. An original backup was retained.

## Integration tests

On Windows build 19045, using isolated copies and a separate backup directory, candidate hash computation, install, backup hash verification, byte-for-byte rollback and rejection of a one-byte modified input without modifying it all passed. The test harness substituted only Appx desktop version discovery because Appx was unavailable in the test shell. No helper executable was launched.
