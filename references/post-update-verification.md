# Resume and verify after a Desktop update

Use this procedure when Codex closes during a recoverable repair, the user returns with "continue", or a further Store update arrives before acceptance. It supplements the guarded installer; it does not authorize a new deployment.

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
