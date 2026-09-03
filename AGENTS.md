# Repository Instructions

## Scope

- These instructions apply to the entire repository.
- This project is Windows-specific. Do not run the MSIX/ASAR repair flows on macOS or Linux.
- Treat `README.md`, `README.en.md`, and `SKILL.md` as the source of truth for user-facing setup, usage, and agent workflow guidance.

## Before Editing

- Inspect the current branch, working tree, and remote before making changes.
- Preserve user changes. Do not discard, overwrite, or reset uncommitted work unless the user explicitly asks for it.
- Prefer a dedicated `codex/` branch for non-trivial work.
- Keep changes small and focused. If changing Chinese user-facing guidance in `README.md`, update the matching English guidance in `README.en.md` when practical.

## Safety Boundaries

- Never commit secrets, `auth.json`, API keys, OAuth tokens, private keys, browser profiles, local credential stores, or generated auth files.
- Repairs that stop, uninstall, reinstall, repackage, or relaunch Codex Desktop must be run from an external executor such as Windows PowerShell or the VS Code Codex extension, not from the Codex Desktop session being repaired.
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
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-asar-integrity.ps1 -TemporaryRoot D:\tmp\asar-test -CheckInstalledPackage
```

- After touching package selection, run `scripts\test-staged-package-selection.ps1 -TemporaryRoot <dir>`.
- Report exactly which checks were run and whether they passed.
