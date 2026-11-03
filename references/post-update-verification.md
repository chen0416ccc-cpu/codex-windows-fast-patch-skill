# Resume and verify after a Desktop update

Use this procedure when Codex closes during a recoverable repair, the user returns with "continue", or a further Store update arrives before acceptance. It supplements the guarded installer; it does not authorize a new deployment.

## Repository entry point

`scripts/codex-after-update.ps1` defaults to checks of the current package's
transaction, live model inventory, and strict plugin/runtime contracts. It
does not launch an installer or modify plugin/config state without repair
switches. Optional reports are explicit new files and contain model names,
capabilities and local checkpoint paths, never auth/config contents.

| JSON status | Meaning / next step |
| --- | --- |
| `installer-busy-or-unknown` | Wait or resolve the existing transaction; no new repair is dispatched. |
| `resume-verification` | `-RepairApp` invokes the exact existing finalizer, not a second deployment. |
| `model-probe-failed` | Resolve catalog/CLI failure; do not substitute old default models. |
| `plugin-repair-needed` | Use `-RepairPlugins`; repair is followed by a separate strict pass. |
| `app-check-needed` | No accepted current-package checkpoint; run `-CheckApp`. |
| `app-repair-needed` | The complete dry run found known missing patches. `-RepairApp` can dispatch the recoverable installer. |
| `unsupported-app-layout` | Missing, duplicate or unknown patch results, a failed dry run, or unsupported Ultra filtering. Inspect the new shipped layout before repair. |
| `verified-contracts` | Current accepted checkpoint plus live checks, or a passing full static check plus live checks. This does not establish visible menus, screenshots/input or upstream speed. |
| `awaiting-installation-and-acceptance` | Installer dispatched; deployment and acceptance are still outstanding. |

`-CheckApp` runs the existing full dry-run patcher against the explicit current
package and the live model IDs, inside a uniquely named scratch directory.
The source package is never changed. All feature results must be present once;
unsupported results are rejected. Ultra `not-applicable` cannot pass when the
active catalog advertises Ultra. Both stdout/stderr are collected without
PowerShell 5.1 stderr promotion. Scratch cleanup verifies its exact parent,
sentinel and absence of reparse points before removal. Choose `-CheckRoot` on a
drive with room for a temporary complete package copy.

The model probe calls only initialize/model-list, retains per-model declared
efforts/tiers, excludes hidden models unless selected as default, and rejects
partial paginated results or malformed identifiers. The launcher uses that
inventory when CustomModels is omitted. Explicit CustomModels bypasses default
resolution in the launcher; it cannot invent capabilities.

`-WhatIf` still performs diagnostics and temporary scratch cleanup, but skips
plugin repair, finalization, installer dispatch and report writes. No scheduler
or automatic restart is installed. Store replacement is expected to invalidate
the previous package's checkpoint, even if the old transaction remains accepted
in its historical record. Unknown future versions require reviewed adaptation.

Maintainers should run `test-post-update-readiness.ps1` under Windows PowerShell
5.1 and PowerShell 7, `node scripts/test-probe-repair-models.cjs`, and the existing
deployment-state/recoverable guard suites. Public-entry fixtures cover locale
loss, future model IDs, separate plugin repair, busy/unknown state, resumable
acceptance, unsupported output, WhatIf, reports and diagnostic cleanup without
deploying any package.

## Inspect the existing attempt first

`start-model-experience-repair.ps1` prints the transcript and state paths. Once identity, session, source package, elevation and executor ancestry have been validated, the runner atomically writes `<transcript>.state.json` in the log directory. It records the source and intended target identities, installer PID and UTC start time, phase, acceptance and cleanup separately. It contains no credentials or configuration contents and survives successful build cleanup.

```powershell
& "$SkillRoot\scripts\get-model-experience-repair-status.ps1" -StatePath '<transcript>.state.json'
# Use -Json for machine-readable output. This query never launches or installs Codex.
```

The query compares the current user's registration and the process's PID **and start time**; a reused PID does not establish a running installer. Process access errors produce an unknown result, not proof that the process exited. Interpret results as follows:
`RecordedAcceptancePassed` describes the saved attempt; `AcceptancePassed` is true only for a verified result on the still-current target, never for a superseding update or unknown installer state.

| Result | Next action |
| --- | --- |
| `installer-running` | Read the transcript and wait. Do not start a second installer, even if the target is already registered. |
| `installer-status-unknown` | Resolve the process/session visibility problem before deciding whether deployment ended. |
| `installed-needs-verification` | Continue acceptance against the registered target. Registration or an interrupted `verifying` phase is not success. |
| `verified-complete` / `verified-cleanup-needed` | The recorded launch, model/list tier and strict runtime checks passed for the still-current target; finish only any pending cleanup. These checks do not establish native screenshot/input acceptance. |
| `superseded` | Keep the old evidence. Inspect the newer package, update the skill, and run a new source-bound dry run; do not install or resume the obsolete candidate. |
| `recovered-original-content` / `failed-original-retained` | The repair failed. Inspect the transcript; neither recovery nor retention of the original package is patch acceptance. |
| `interrupted-not-installed`, `package-changed`, `package-missing`, `different-user` | Diagnose the reported state before selecting any new repair. |

For `installed-needs-verification`, first inspect the existing transcript and state, then run the evidence-bound finalizer instead of deploying again:

```powershell
& "$SkillRoot\scripts\complete-model-experience-repair.ps1" -StatePath '<transcript>.state.json'
```

It never installs Codex. It requires the exact current target, the original installer to have exited, a visible Desktop window from that package, a passing Fast wire line in the retained transcript, `model/list` with `priority` on the default model, and strict installed-runtime/plugin verification. Only then does it atomically record acceptance and request exact-run cleanup. Use `-KeepArtifacts` to record acceptance while retaining the build. If cleanup fails, keep the accepted checkpoint and diagnose cleanup separately; do not hand-edit state JSON. Finalizer cleanup is explicit-target-only and does not sweep unrelated aged runs.

If the state file is absent (including older runs or failure before initial validation), inspect the saved installer PID/start time, transcript, current package and artifacts manually. Missing state is not evidence that installation is safe to repeat. The runner must persist its pre-deployment checkpoint before the app can close. A later cleanup failure must retain the passed acceptance result and report cleanup separately. Do not manually edit a state file to declare success.

`-ResumePreparedBuild` is still restricted to the documented pre-deployment failures and exact original source identity. The status query does not relax sentinels, signature, payload, recovery, UAC or ancestry checks.

## PowerShell 5.1 model-probe false rollback

On Desktop `26.1023.6123`, the patched `.1` package launched and logged browser availability plus native-pipe readiness, but the installer then reported `[eval]:4` in its model-list acceptance step and installed the original-content `.2` recovery package. The installer passed double-quoted JavaScript through `node -e`; Windows PowerShell 5.1 altered those native arguments before Node could run the model query. The same extracted acceptance function passed under PowerShell 7.

Both the runner and finalizer now write a unique UTF-8 `.cjs` probe beside their run evidence, execute that file with a separate CLI-path argument, capture native errors without losing their exit code, and remove only that probe file in `finally`. Model-tier and runtime acceptance requirements remain unchanged. Run `scripts/test-model-list-probe-transport.ps1 -TemporaryRoot <local-test-root>` under PowerShell 5.1 and 7; it exercises the real acceptance functions with an offline app-server fixture, a space/non-ASCII path, positive tier metadata, missing-priority rejection, and probe cleanup. Then rerun the extracted function against the current user-local CLI before deployment.

A completed recovery is a failed repair, not an installation still in progress. Keep its state and artifacts, diagnose the validation error, and prepare a new source-bound candidate from the currently registered recovery version. Do not reinstall the older patch or use `-ResumePreparedBuild` to bypass the source-version boundary.

The recovery's new revision also changes the native-host `resourcesPath` identity. A strict check on the observed `.2` recovery reported `Chrome native-host v2 state has no current app-server entry`; the ordinary local `-VerifyOnly` refresh addresses this package-path drift. The recoverable installer now runs that local refresh against the installed target before a separate `-StrictVerifyOnly -VerifyAllBundledPluginsAvailable` pass. Both passes must succeed; original-content recovery launches do not run or accept patched-package verification.

## Keep both audit baselines

Before the first mutation, retain the task's initial backup/snapshot. If another Store update or setup operation occurs, also retain a new snapshot immediately before that repair, without replacing the initial one. Compare initial-to-final for the complete user-visible changes; use intermediate snapshots only to attribute phases.

Record the selected provider/model/reasoning/speed and relevant plugin/MCP/marketplace settings with secrets redacted. Hash protected authentication/remote-control files when needed without copying their contents into reports. A missing original file is a distinct state, not an empty hash. Report intentional changes such as marketplace paths/timestamps or trusted Node paths, rather than saying "nothing changed" because selected settings survived. Preserve unrelated profiles, credentials, data and phone configuration.

If a plugin appears between snapshots, report the first snapshot/log that proves its presence. Timing alone does not establish whether a Store upgrade, an installer, or another process installed it. Availability in a bundled marketplace and installation/enabling are separate facts.

## Match claims to acceptance evidence

- Read `model/list` per model. A `service_tier=priority` wire check proves that request, not support for every model or an unadvertised `ultrafast` tier.
- Run `install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable` for current package/runtime/plugin contracts. Report optional plugins as available or installed according to evidence.
- Verify Chrome and the in-app browser separately when browser acceptance is requested. One browser's success does not establish the other's. Use temporary background tabs and report the operation actually performed.
- Window enumeration proves transport/enumeration only. Keep the ordinary background-only verification boundary: native screenshots and input require the existing explicit authorization described in `SKILL.md`.
- Do not promote an isolated pattern test, signed package or successful dry run to installed/runtime acceptance. Preserve the exact tested versions and outstanding limits in the handoff.

## Maintainer regression

Run `scripts/test-repair-deployment-state.ps1 -TemporaryRoot <local-test-root>` with Windows PowerShell 5.1 and a current PowerShell 7 when available. The suite executes atomic file writes, the public read-only query and the runner's transaction/cleanup tail with fixture deployment functions; it never installs a package. It covers PID reuse, session mismatch, JSON timestamp precision, missing/invalid state, failed atomic replacement, recovery, supersession, cleanup errors, and checkpoint I/O failures before and after deployment. Use a test root containing spaces and non-ASCII characters to exercise path transport. These fixtures supplement the existing recoverable-installer and MSIX safety suites; they do not replace real post-install acceptance.
