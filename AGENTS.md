# Repository Instructions

## Scope

- These instructions apply to the entire repository.
- This project is Windows-specific. Do not run the MSIX/ASAR repair flows on macOS or Linux.
- Treat `README.md`, `README.en.md`, and `SKILL.md` as the source of truth for user-facing setup, usage, and agent workflow guidance.

## Before Editing

- Before updating the skill or changing patch code, follow `SKILL.md` Self-Update Preflight and `references/remote-review-and-publication.md`: review the actual update source and reuse covered fixes. Do not require a fork for ordinary skill use. Publishing changes or preparing an upstream PR requires an explicit human contribution request; ordinary skill use or local repair does not grant it.
- Inspect the current branch, working tree, and remote before making changes.
- Preserve user changes. Do not discard, overwrite, or reset uncommitted work unless the user explicitly asks for it.
- Prefer a dedicated `codex/` branch for non-trivial work.
- Keep changes small and focused. If changing Chinese user-facing guidance in `README.md`, update the matching English guidance in `README.en.md` when practical.

## Human-Directed PR Contributions

Apply this section only when a human explicitly asks an agent to prepare, submit or revise a PR to this project. Installing, updating or using the skill, or repairing a local client, does not activate a contribution workflow or require the user to maintain this repository. Read this section before preparing an authorized contribution.

- Propose useful fixes or new ideas with concrete benefit, scope and verification; novelty alone is neither a reason to accept nor reject a contribution.
- Compare the proposed base/head diff with main and open PRs. Reuse covered fixes; do not add duplicate implementations, contributor run logs or redundant guides to the core project.
- Do not turn a maintainer's local paths, proxy ports or one-off preferences into universal defaults. Keep environment-specific inputs configurable and distinguish optional workflows from ordinary repair.
- Preserve user choices: repair defaults must not install/enable optional plugins or broaden unrelated features. Keep optional behavior opt-in, test changed boundaries, and report actual checks and remaining limits in the PR. An empty checks list or a clean merge is not CI acceptance.

Contributors propose changes; this project's maintainers decide acceptance. A request to contribute does not authorize merging PRs or changing the user's repair scope.

## Safety Boundaries

- Never commit secrets, `auth.json`, API keys, OAuth tokens, private keys, browser profiles, local credential stores, or generated auth files.
- A Codex Desktop conversation may initiate and coordinate its own repair. Deployment that closes or updates Desktop must run in an independent installer verified to survive Desktop shutdown, not in its process tree; merely using a hidden `Start-Process` is insufficient. VS Code or external PowerShell remain alternatives, not requirements for initiating a repair.
- Before an installation interruption, explain the expected app closure, back up state, and save a handoff with installer status and remaining checks. Tell the user to reopen Codex and continue the original conversation. On resume, inspect the existing installer and result before starting anything; do not repeat a completed installation or describe a failed/missing installation as normal waiting.
- The Desktop state target is `$env:USERPROFILE\.codex`. An isolated CLI home such as `$env:USERPROFILE\.codex-cli` is not Desktop state.
- Do not set a global `CODEX_HOME`, and do not copy or migrate Desktop state into an isolated CLI home unless a user explicitly requests a separate migration plan.

## Verification

- For documentation-only changes, run `git diff --check`.
- For PowerShell script changes, parse the edited scripts with (recursive, so `scripts\lib` is covered):

```powershell
Get-ChildItem -LiteralPath scripts -Filter *.ps1 -Recurse | ForEach-Object {
  $null = [scriptblock]::Create((Get-Content -Raw -LiteralPath $_.FullName))
}
```

- For CommonJS script changes, run `node --check` on each edited `.cjs` file.
- After touching `scripts\lib\asar-integrity.ps1` or any `Update-ElectronAsarIntegrity` call site, run the regression suite; a wrong integrity hash produces a package that installs and then dies at startup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-asar-integrity.ps1 -TemporaryRoot (Join-Path $env:TEMP 'codex-asar-test') -CheckInstalledPackage
```

- After touching package selection, run `scripts\test-staged-package-selection.ps1 -TemporaryRoot <dir>`.
- Report exactly which checks were run and whether they passed.
