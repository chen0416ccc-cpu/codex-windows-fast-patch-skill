# Remote review and publication

## Before each update or patch

1. Inspect the installed skill path, `.skill-version` / `.skill-local-overlay` / `.skill-update-source.json` when present, source checkout branch, status and remote URLs. Use the configured fork for `origin` and verify `upstream` is `https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git`. A plain copy still needs a persistent Git source checkout. Back up its overlay before synchronizing files; keep unrelated or unreviewed local additions.
2. Fetch both remotes before changing patch code. Inspect recent commits, symmetric history and file diffs against both main refs and the installed overlay. Record both full SHAs and the symptom/evidence each local increment addresses. Check existing upstream PRs for an effective fix.
3. Fast-forward a clean checkout when possible. For divergence, integrate the needed upstream changes on a `codex/` branch and review conflicts semantically, including automatically merged embedded JavaScript. Preserve local history and work; use no forced reset or force push. Reload the resulting `SKILL.md` before running repairs.
4. Reuse remote behavior that already covers the observed failure. Only implement a missing fix or optimization supported by actual bundle/runtime evidence. Keep binary profiles pinned to complete hashes and keep unverified acceptance fields null.

```powershell
git -C "$SourceRoot" status --short
git -C "$SourceRoot" remote -v
git -C "$SourceRoot" fetch origin
git -C "$SourceRoot" fetch upstream
git -C "$SourceRoot" log --oneline --left-right HEAD...origin/main
git -C "$SourceRoot" log --oneline --left-right HEAD...upstream/main
git -C "$SourceRoot" diff upstream/main -- scripts references SKILL.md
```

Set `$SourceRoot` to the actual persistent checkout. Missing tracking refs require explicit inspection; do not infer repository freshness from an absent ref or compare only the fork.

## Publish a necessary increment

1. Run the changed behavior regressions, required PowerShell parsing, changed-CJS syntax checks and `git diff --check`. Keep generated packages, credentials, user state and local evidence outside Git. Record failures and limitations accurately.
2. Commit reviewed files, fast-forward the user's local main to the validated result and push normally to `origin/main`. If remote main advanced, fetch/review/integrate it and rerun affected checks before retrying; preserve both histories.
3. Create or update one upstream PR with the exact validated changes. A focused branch based on current upstream can omit already-covered fork history; record its base/head SHAs and verify its diff. Check for an existing PR first. A task with no necessary increment can reuse an existing commit or PR and should record that result instead of creating an empty change.
4. Verify GitHub main SHA and PR base/head, describe the observed before/after behavior and validation, attach the PR to the current chat when the tool is available, and put the commit/PR URL in the repair record. Synchronize reviewed source files into a non-Git installed skill without deleting other local additions; record its source commit and retained overlay.

For this user's patch-maintenance workflow, validated increments are complete only after commit, fork-main push and upstream PR publication. A local repair or commit alone is not publication. Network/authentication/permission blocks must name the pending operation and preserve the working tree for continuation. PR creation does not authorize merging upstream.
