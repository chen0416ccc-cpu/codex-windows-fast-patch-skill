# Windows startup delays and renderer reloads

The pinned `26.1029.7803.0` and `26.1029.9216.0` assets support a bounded Statsig startup wait and local renderer exit diagnostics. The full desktop patch preserves existing model, Fast, Ultra, browser and explicit project patches. Model Experience-only repair does not add the startup edits, and preserves them when already present.

## Evidence and behavior

- An unavailable post-login bootstrap endpoint previously caused six 10-second attempts with 500 ms retry delays: 62.5 seconds before SDK fallback. Real renderer route-mount logs showed delays of 68–98 seconds while host startup completed in about 0.9 seconds.
- Windows bootstrap now shares a 5-second deadline across retries. The actual request timer aborts the request. Successful responses, eligible authentication refresh, and the non-retryable `ip_not_authorized` error retain their behavior.
- On Windows, the SDK's existing `initializeAsync({timeoutMs:2000})` option releases its network wait, retains cached values and lets the network refresh finish in the background. This bounds the network stage, not identity lookup, storage readiness or total application startup.
- Other platforms keep their original request/SDK timeouts. Restore accepts the exact older complete patch and requires the original full SHA-256 after reversing edits; unknown or partial assets fail before writing.
- `windows_renderer_process_gone` records reason, exit code and window identifiers in the local desktop log. It contains no message text, credentials or URL. Clean exits and app shutdown stay silent, and the existing crash reporting/reload path remains unchanged.
- An independent installer using Idle priority and one CPU can pass those settings to Desktop through the activation child. The activation helper now restores Normal priority and the current Windows processor group's system affinity only in that short-lived child, before COM activation. The installer retains its limits. Job CPU/memory limits are not removed: launch outside the build job as required by the external-executor workflow.

## Verification

Run against the original extracted asset set, or the exact supported previously patched shared asset. The shared asset is `24191.589dcc9878.js` on 7803 and `24191.dc3ed2d869.js` on 9216:

```powershell
node scripts/test-statsig-startup.cjs '<asar>\webview\assets\async\<shared-asset>'
node scripts/test-renderer-diagnostics.cjs '<asar>'
node scripts/test-desktop-261029.cjs '<asar>'
```

The startup regression executes the shipped retry function, request abort timer, SDK adapter timeout and React hook. It checks 5-second offline failure, online success, authentication refresh, denied-IP handling, cached fallback, continuing background fetch, non-Windows behavior, legacy upgrade, idempotence and rejection of drift. `--original` reproduces the 62.5-second failure. The diagnostic regression covers crashes, OOM, killed renderers, clean exit and app shutdown.

`test-appx-launch.ps1 -TemporaryRoot <dir>` runs the actual activation child from an Idle, single-core parent, replacing only COM activation with a scheduling assertion. It also verifies that the parent's restrictions remain, including a real 32-bit parent on 64-bit Windows. Live activation after correcting the installer showed Normal priority and all 32 available CPUs; host startup changed from 4.5 s to 0.9 s and routes mounted in 6 s instead of 14 s. These individual samples establish scheduling recovery, not a general benchmark or a renderer crash fix.

## Deployment and acceptance

Build a higher-revision signed MSIX and an independently validated recovery package, then follow the external-executor installation workflow. Verify package payload blocks and Electron ASAR integrity before and after installation. Record actual route-mount timing, active process identities and real tool calls after restart.

After restart, run `scripts/install-computer-use-local.ps1 -OnlyExecutorRuntime -StrictVerifyOnly` and confirm that every configured MCP `command` still exists. A Store update can leave `CODEX_CLI_PATH` (User and `node_repl.env`) pinned to an older `OpenAI\Codex\bin\<id>` directory that holds only `codex.exe`; Desktop then starts an older app-server, and every code-mode tool fails with `failed to spawn code-mode host` while the window looks healthy. The same update can retire the `runtimes\cua_node\<id>` directory that existing MCP commands point at. Repair those with [executor runtime repair](executor-runtime-repair.md) and the retired CUA Node case in [restriction debug cases](restriction-debug-cases.md), then accept only after a real code-mode tool call in the restarted Desktop.

A renderer crash followed by reload is distinct from a main-process restart or the exit/reopen race. Do not describe this timeout repair as a native crash fix. Retain local exit evidence and a crash dump when available; a clean observation interval alone does not establish the crash cause. Whole-system restarts must be assessed separately.
