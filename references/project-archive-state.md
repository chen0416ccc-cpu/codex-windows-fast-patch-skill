# Project and archive state repair

Use this branch when a Windows restart leaves existing chats outside their project, or archived-chat management returns rows while displaying a load failure. This is separate from provider-history filtering and missing working directories.

## Diagnose and recover

1. Review fork and upstream main and the installed overlay. Back up `.codex-global-state.json`, its `.bak`, `config.toml` and relevant SQLite stores. Use SQLite's backup API for live databases.
2. Read local projects and active/archived chats through app tools. Compare `local-projects`, `thread-project-assignments`, the host's legacy-to-app-server project map, migration checkpoint, `projects`, `project_roots` and `threads.project_id`. These identifiers can differ between the sidebar and backend.
3. Inspect complete interrupted-write siblings matching `.<state basename>.tmp-` or `.<state basename>.bak.tmp-`. Preserve them as evidence. A valid primary state file takes precedence, including `{}`; restoring an old whole file can overwrite newer settings.
4. Recover only memberships supported by previous assignments or matching backend project roots and existing membership. `cwd` alone does not establish original project ownership. Preserve thread rows, archived flags, rollout paths and other fields. App-tool moves on the affected build can update sidebar state without updating SQLite.
5. Stop Desktop normally through an independent installer before synchronizing global state. Back up that stopped state again, merge the verified assignments, and update only migration entries whose backend associations have been checked. Flush and atomically replace primary/backup files. Keep unrelated state and checkpoints intact.

The shipped patcher changes application code only. It does not guess or rewrite user memberships, provider metadata, configuration or rollout history.

## Supported patch

Desktop `26.1103.4239.0` has a complete three-asset profile. Its state loader
recovers missing primary files and flushes temporary writes. Re-selecting the
same null renderer owner preserves local project state; switching to a different
account still stashes and isolates its state. Windows assignments reach the
backend while retaining its support check. The archive asset is shared with
3517. Run `test-project-state-2611034239.cjs` (34 checks), the archive regression,
and `test-desktop-project-composition.cjs` (1068 checks) against this layout.
Recovery must also remove only verified restored IDs from `projectless-thread-ids`
and preserve the new `threadAssignmentsReadMigrated` checkpoint semantics.

Desktop `26.1103.3517` uses an archive-only profile for
`webview/assets/async/678916.8bc60ed422.js` (source SHA-256
`d9a4fe97ef219d81dfa3d810734b038a56b38b81b5645967bfa93500380f549c`).
The existing `-OnlyProjectArchiveState` entrypoint changes only this asset on
that layout; global-state recovery and membership persistence are not included.
The parent suppresses stale errors when its source already has rows. The child
requires an empty combined list and tracks its length in the memo cache. Run
`node scripts/test-archive-261103.cjs <original-extracted-asar>` (26 checks).
Package deployment and live UI acceptance must be recorded separately.

`scripts/patch-project-archive-state.cjs` selects one complete three-asset layout and pins full SHA-256 hashes for Desktop `26.1027.6604.0`, the observed patched `.6604.1` combination, and `26.1029.7803.0`. The old membership asset has two accepted hashes because the earlier client patch changed the same chunk. The new membership asset also accepts the precisely restored full-patch combination containing the Deep Research gate, whether or not the membership edit is already present. Desktop and project/archive patches preserve each other's edits in either order; project/archive repair remains opt-in. Unknown or partial content is rejected before any target is written; backups must match the exact original input.

- Global state: try primary, `.bak`, then complete interrupted-write siblings in descending modification order. Skip invalid JSON and unrelated files. Flush synchronous and asynchronous temporary writes before rename.
- Project membership: enable Windows local-project assignment writes while retaining the backend support check and non-Windows feature gate.
- Archived chats: scope errors to their selected sources and remove the ChatGPT error row when the combined archive list contains rows. Include row count in the React memo dependencies so a previously cached error disappears when chats arrive. An empty failing list retains retry.

Run the targeted dry run first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyProjectArchiveState -DryRun
```

Build without installing, using a separate output directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\patch_codex_fast_mode_windows_msix.ps1" -OnlyProjectArchiveState -OutputRoot 'D:\CodexPatch\project-archive' -KeepWorkDir
```

The targeted mode is opt-in and skips unrelated Chrome registry and runtime repairs. The ordinary pinned `26.1029.7803` full repair excludes these project/archive code fixes; request the targeted mode explicitly. Build and sign a higher-revision original-content recovery package before deployment, validate signatures and every payload block, and use the independent-installer workflow in [post-update verification](post-update-verification.md). Save a handoff, validate user/session/admin/ancestry/Job independence, request normal app exit and apply `Add-AppxPackage -Path` in place. After reopening Desktop, inspect the existing transaction before resuming.

The targeted repacker reads the original ASAR header, replaces only its three pinned packed assets, and preserves unpacked native entries, links and shared data extents. This matters for previously patched packages whose extracted native bytes differ from the original header metadata: a plain `asar pack` can move native modules into the archive. Native files remain in the package's existing `app.asar.unpacked` directory. The repacker rejects source gaps, overlaps and trailing bytes, flushes a separate output and leaves the source archive untouched.

## Acceptance

Run against original extracted assets from each supported source combination:

```powershell
node "$SkillRoot\scripts\test-project-archive-state.cjs" '<original extracted ASAR>'
node "$SkillRoot\scripts\test-desktop-project-composition.cjs" '<original extracted 26.1029 ASAR>'
node "$SkillRoot\scripts\test-project-archive-asar.cjs"
```

The old layout runs 34 checks; the new layout runs 39. They execute the shipped state loader, assignment writer and archive-error render/memo code, reproduce all three original defects, and verify backup/temporary recovery, valid-empty-primary precedence, durable writes, Windows backend requests, unsupported-backend/non-Windows guards, cached error invalidation, retry for empty failures, source hashes, dry-run immutability, exact backups and idempotence. The new archive tests cover both parent source-error props and the child's combined-row memo; testing only the account error source misses the durable/local error path seen beside six loaded chats. The composition suite also checks both patch orders, model-only updates, exact project backups, no-write rejection and idempotence on the pinned 26.1029 assets.

The 14 ASAR layout checks verify a modified file sharing an extent with an unchanged file, preserved native/link entries, an identical no-change rebuild, source immutability and rejection before output when a target or source layout is invalid. Full `--all` repacking compares the complete extracted file set and preserves byte-identical unpacked files, including vendor certificate bytes beyond recorded header sizes. Compare the actual output header to the source and independently verify its packed extents before signing.

After installation, verify the registered package, actual responsive Desktop process and installed payload against the signed package. Re-read active and archived memberships through app tools and SQLite after restart, check state/checkpoint consistency, and exercise a known assignment through the app interface to prove backend persistence. Keep archive row retrieval, execution of the installed render code, and actual visual observation as separate evidence. Function tests do not prove an independently observed settings screen. Record any unobserved visual acceptance explicitly.
