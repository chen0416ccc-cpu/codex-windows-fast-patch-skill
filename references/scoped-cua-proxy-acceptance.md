# Scoped Computer Use and proxy diagnostics

Use this route when native Windows Computer Use is already exposed and the requested package repair is limited to child-process proxy inheritance. Follow the skill's backup, remote review and independent signed-installation rules. This reference adds no patch mode, availability override, helper profile or permission to take over the desktop.

## Interpret each diagnostic result

| Check | What a passing result establishes | What remains separate |
| --- | --- | --- |
| `install-computer-use-local.ps1 -StrictVerifyOnly` | Current core cache/runtime, trusted-client and native-host contracts, including the official helper's window enumeration | Real screenshots/input, browser navigation and all optional bundled descriptors |
| The same command with `-VerifyAllBundledPluginsAvailable` | Core checks plus discoverability of every current bundled descriptor | Installation/enabling of optional plugins, their business backends and visible interaction |
| `codex-after-update.ps1` | The diagnostic ran and produced a report; read its JSON `status`, `pluginExitCode` and `app.Status` | Process exit 0 alone is not `verified-contracts`; `not-checked` is not an application-gate pass |
| `-OnlyNodeReplProxyEnv -DryRun` | The selected source has a unique supported proxy target and passes the targeted static checks | Installed payload, fresh child environments and real interaction |

Keep the combined readiness check and its failures intact. A manually coordinated proxy-only installation does not create the full recoverable runner's accepted checkpoint. Do not edit transaction JSON, suppress a descriptor failure or substitute an old checkpoint to make the combined report green. A scoped result can be accepted for the requested repair while the broader report remains incomplete, provided both are stated explicitly.

## Evidence-driven sequence

1. Identify the actual persistent Desktop root, app-server, CUA MCP, Node REPL hosts and any trusted workers. Use `probe-node-repl-proxy-env.py --pid <actual-pid>` on the parent and affected children. Require `complete=true` before claiming a variable is absent, and check the required proxy names as a subset. Inspect separately configured stdio MCP launcher/server processes too. Parent environment or a finite connection sample alone does not establish child inheritance.

2. Run the core strict check first. If it identifies stale browser AX/cache assets or runtime/native-host path drift, use the existing local repair after taking the required backup, then rerun strict verification independently. Preserve the packaged trusted browser-client bytes. Do not escalate a cache failure to an MSIX or native-helper patch without separate package evidence.

3. When the parent has the intended environment and the native builder drops it from the children, use the existing proxy-only DryRun. Confirm the exact source package, unique target, JavaScript syntax and integrity host. Before installation, compare the complete ASAR entry set/content and program payload against that source: only the selected proxy asset and the expected ASAR/integrity carrier may change. Preserve native CUA readiness/plugin guards and unrelated model controls. Follow the existing signed update, original-content recovery and external-executor workflow.

4. After relaunch, match the registered package, running root, launch record and installed payload hashes to the candidate. Read fresh child environments and attribute sampled connections to their actual owners. Run core strict and provider/config diagnostics. Compare the original state baseline with the final configuration; record intentional marketplace, trusted-path, proxy-allowlist and pipe changes. Report unrelated provider/model, custom MCP, plugin and protected-file preservation separately.

5. Keep ordinary native acceptance non-interactive: enumerate windows. Only for an explicitly authorized screenshot/input diagnostic, select a unique returned window and use a disposable editable surface. Keep the observed Raise action, or another documented activation API when AX is absent, adjacent to capture. Inspect the actual image and current focus before coordinate or text input. If another app obscures the target, stop input and reobserve. Verify the literal text on screen, undo it and close only the test documents. A null AX result is neither proof of a failed screenshot nor proof that semantic accessibility works. A cross-process dialog rejected by target ownership must not be acted on using a fabricated window or stale coordinates.

6. Verify the in-app browser and Chrome independently through the current documented browser APIs. Record the actual operation, final URL, title and meaningful page content. If Chrome is installed but undiscoverable, run its four packaged read-only diagnostics with the matching runtime. Use the official profile-specific launcher when the enabled-extension profile differs from the open window, within the existing launch authorization. A valid manifest alone does not establish a working extension session. A page-specific failure stays a failed page observation; it does not replace the results from other tested operations.

## Contributor verification on Desktop 26.1103.4239

The existing upstream proxy-only workflow was exercised on Windows 11 with Store source `26.1103.4239.0`, CLI `0.167.0-alpha.3.2`, bundled plugins `26.1103.32239` and Sky `0.7.17`, using skill base `e9a21942134ce513f61498bc38cc0784c781216b`. This is an independent scoped verification, not validation of another full-layout PR or of Windows 10 helper profiles.

| Stage | Observed result |
| --- | --- |
| Before repair | Native APIs and enumeration worked. Core strict identified mixed browser AX assets. Complete environment reads found proxy names in the parent/backend but absent from three CUA MCP and eight Node REPL hosts. |
| Local repair and preparation | Cache refresh followed by independent core strict passed. Proxy-only DryRun, syntax/integrity checks, proxy behavior/quote guards, targeted orchestration and complete-read regressions passed. |
| Candidate scope | All 19,793 ASAR entries retained the same set; only `early-bootstrap.js` changed. Across 3,757 program files, only ASAR and its integrity-bearing launcher changed. Signed update/recovery payloads and original-content recovery files were verified. |
| Installed acceptance | Proxy-only revision `26.1103.4239.1` launched without recovery; installed ASAR/launcher hashes matched the candidate. Eleven core process and eight custom Node environments retained the required proxy names. All 70 sampled connections used the intended proxy. Config/provider reachability and core strict passed. |
| Authorized native interaction | Correct foreground captures showed a new blank Notepad document, coordinate focus, bilingual input and successful undo. Both test tabs were closed and the original tab restored without saving a test file. Static and text-updated captures passed. |
| Browser interaction | The in-app browser and Chrome each navigated a public HTTPS page and read its title and meaningful AX content. Chrome discovery succeeded after opening the enabled-extension profile. Temporary test tabs were closed. |
| Combined diagnostic | A fresh default `codex-after-update.ps1` invocation completed with process exit 0 but correctly reported `status=plugin-repair-needed`, `pluginExitCode=1` and `app.Status=not-checked`. The missing optional descriptor was `deep-research`; there was no accepted full-runner checkpoint. This is not `verified-contracts`. |

Limits: AX was null in the two tested native editors, and one obscured capture was discarded before the verified foreground sequence. One browser target remained unverified. Full model/feature gates, optional-plugin backend behavior, Windows 10 capture, animated/resource-soak acceptance and long-term stability were not established. Keep any corresponding validation fields unset.

Publish only the reusable procedure and bounded results. Keep credentials, proxy values, account/catalog contents, process identifiers, machine-specific paths, user documents, screenshots and generated packages outside the repository.
