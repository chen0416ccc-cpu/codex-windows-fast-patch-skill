# Remote review and publication

## Before updating the skill or changing patch code

1. Inspect the installed skill path, `.skill-version` / `.skill-local-overlay` / `.skill-update-source.json` when present, source checkout branch, status and remote URLs. This project's URL is `https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git`. A direct clone may use it as `origin`; an existing fork may use `upstream` for it. Do not create a fork, rewrite remotes or require a second remote for ordinary use. For a plain copy, check its recorded source/version and use a persistent source checkout when source comparison or code changes are needed. Back up its overlay before synchronizing files; keep unrelated or unreviewed local additions.
2. Fetch the relevant configured main refs before changing patch code. For a fork, also compare this project's main through a verified upstream remote or read-only inspection of the project URL; an absent `upstream` must not be treated as evidence that the fork is current. Inspect recent commits, symmetric history and file diffs against the installed overlay. Record the full SHAs actually reviewed and the symptom/evidence each local increment addresses. Check existing upstream PRs for an effective fix.
3. Fast-forward a clean checkout when possible. For divergence, integrate the needed upstream changes on a `codex/` branch and review conflicts semantically, including automatically merged embedded JavaScript. Preserve local history and work; use no forced reset or force push. Reload the resulting `SKILL.md` before running repairs.
4. Reuse remote behavior that already covers the observed failure. Only implement a missing fix or optimization supported by actual bundle/runtime evidence. Keep binary profiles pinned to complete hashes and keep unverified acceptance fields null.

```powershell
git -C "$SourceRoot" status --short
git -C "$SourceRoot" remote -v
git -C "$SourceRoot" fetch origin
git -C "$SourceRoot" log --oneline --left-right HEAD...origin/main
git -C "$SourceRoot" diff origin/main -- scripts references SKILL.md
```

Set `$SourceRoot` to the actual persistent checkout. The example covers a direct clone of this project. If `origin` is a fork and a verified `upstream` exists, also fetch `upstream` and compare `upstream/main`. Missing tracking refs require explicit inspection; do not infer repository freshness from an absent ref or compare only the fork. Ordinary diagnosis with installed scripts does not itself require Git or network access. If remote review is unavailable, report that limit separately from local verification.

## Publish a human-requested contribution

Follow this section only when a human explicitly asks an agent to prepare, submit or revise a contribution to this project. Ordinary skill installation, update or local client repair is not such a request. Keep the read-only remote review above, but do not push branches or open PRs merely because a repair revealed a possible improvement. Read `AGENTS.md`'s human-directed contribution rules before preparing the PR; do not broaden the repair to create one.

1. Run the changed behavior regressions, required PowerShell parsing, changed-CJS syntax checks and `git diff --check`. Keep generated packages, credentials, user state and local evidence outside Git. Record failures and limitations accurately.
2. Prepare a focused branch from the reviewed base. Commit or push only when included in the human's request, using the authorized repository and branch; do not require a fork-main push or write to upstream main by default. If the target base advanced, fetch/review/integrate it and rerun affected checks before publishing; preserve both histories.
3. Create or update one upstream PR with the exact validated changes when submission is requested. Record its base/head SHAs and verify its diff. Check for an existing PR first. A task with no necessary increment can reuse an existing commit or PR and should record that result instead of creating an empty change. If `origin` is already the maintainer's upstream repository, follow the human-requested maintainer workflow rather than inventing a fork or a redundant PR.
4. Verify the requested remote branch and PR base/head, describe the observed before/after behavior and validation, attach the PR to the current chat when the tool is available, and put the commit/PR URL in the contribution record. Synchronizing a local installed skill is a separate repair/update action, not a requirement for submitting a PR; preserve its overlay if that synchronization is requested.

For a human-requested contribution, a local repair or commit alone is not completed publication: verify the requested push and PR operations. If publication was not requested, do not label an otherwise verified local repair incomplete for lacking a PR. Network/authentication/permission blocks must name the pending authorized operation and preserve the working tree for continuation. PR creation does not authorize merging upstream; maintainers retain that decision.
