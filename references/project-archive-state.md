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

`scripts/patch-project-archive-state.cjs` pins full SHA-256 hashes for three assets in Desktop `26.1027.6604.0` and the observed patched `.6604.1` combination. The membership asset has two accepted hashes because the earlier client patch changed the same chunk. Unknown or partial content is rejected before any target is written; backups must match the exact original input.

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

This mode is opt-in and separate from ordinary full repairs. It skips unrelated Chrome registry and runtime repairs. Build and sign a higher-revision original-content recovery package before deployment, validate signatures and every payload block, and use the independent-installer workflow in [post-update verification](post-update-verification.md). Save a handoff, validate user/session/admin/ancestry/Job independence, request normal app exit and apply `Add-AppxPackage -Path` in place. After reopening Desktop, inspect the existing transaction before resuming.

## Acceptance

Run against original extracted assets from each supported source combination:

```powershell
node "$SkillRoot\scripts\test-project-archive-state.cjs" '<original extracted ASAR>'
```

The 34 checks execute the shipped state loader, assignment writer and archive-error render/memo code. They reproduce all three original defects and verify backup/temporary recovery, valid-empty-primary precedence, durable writes, Windows backend requests, unsupported-backend/non-Windows guards, cached error invalidation, retry for empty failures, source hashes, dry-run immutability, exact backups and idempotence.

After installation, verify the registered package, actual responsive Desktop process and installed payload against the signed package. Re-read active and archived memberships through app tools and SQLite after restart, check state/checkpoint consistency, and exercise a known assignment through the app interface to prove backend persistence. Keep archive row retrieval, execution of the installed render code, and actual visual observation as separate evidence. Function tests do not prove an independently observed settings screen. Record any unobserved visual acceptance explicitly.
