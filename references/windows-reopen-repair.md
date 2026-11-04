# Windows reopen during exit

Use this workflow when reopening Codex immediately after exit produces no window,
while a previous process is still shutting down or both processes disappear.
Distinguish this from a startup crash using exit status, Desktop logs and the
installed package path before applying a bundle repair.

## Supported repair

Desktop `26.1029.7803` registers a `second-instance` handler that always forwards
interactive arguments to the existing window controller. During asynchronous
quit cleanup that controller is already closing. The new instance exits normally
after forwarding, then the old instance exits without reopening a window.

`scripts/patch-windows-reopen.cjs` pins the complete original asset:

- File: `.vite/build/early-bootstrap-339-f66dad1753c54789.js`
- SHA-256: `862a1b283e239cda5eb840e39b822b8dfbfffe12427dc765539579ecc526cca0`
- Log marker: `windows_reopen_queued_during_quit`

On Windows, an interactive `second-instance` event after `will-quit` queues one
Electron relaunch with the incoming arguments. Repeated activations and an
already scheduled updater relaunch do not queue additional launches. Normal
activation, cancellation before `will-quit`, startup-task activation and other
platforms retain their existing behavior. Unknown or partially modified assets
are rejected; an exact patched asset is idempotent.

The full `26.1029` patch plan includes this repair. A targeted repair can call
the script against a copied package's ASAR without changing other assets:

```powershell
node "$SkillRoot\scripts\patch-windows-reopen.cjs" $CopiedAsar $PatchedAsar
```

Input and output must differ. Replace only the copied package's ASAR after the
command succeeds, then run `Update-ElectronAsarIntegrity -AppRoot $CopiedAppRoot`.
For explicit verification, enumerate `Test-AsarIntegrityTargets -AppRoot ...`
and call `Assert-AsarIntegrityConsistent -ExePath $record.ExePath -AppRoot ...`
for each returned host. Its first argument is an executable, not an app directory.
Use the normal signed MSIX workflow and independent, recoverable installer;
never replace files in the running WindowsApps package.

## Acceptance

1. Run `node scripts/test-windows-reopen.cjs <original-asset>` and the full
   `test-desktop-261029.cjs` suite against the matching extracted source. The
   first test exercises the original event handler to show the dropped request,
   then tests the injected handler, deduplication and preserved paths.
2. Verify the candidate signature and all uncompressed MSIX payload blocks
   before installation. Prepare a higher-revision recovery package with the
   previous content. Back up Desktop configuration and conversation state.
3. After installation, verify the actual process path and extract the installed
   asset; `transform` must return `already-patched`. Confirm authentication,
   conversation metadata and database integrity. A regenerated native pipe path
   is an expected configuration difference.
4. With an independent observer, quit normally and activate the AUMID while the
   old process is still alive but its window has closed. Require the log marker,
   old-process exit and one naturally reopened responsive window. Repeat with
   multiple activations. A recovery watcher must not create the passing window.
5. Separately exercise the user's taskbar-close and original-shortcut path.
   Record user-operated acceptance as such when UI automation cannot target the
   taskbar reliably. Window-close behavior may hide and restore an existing
   process, so a process-ID change is not required for this separate path.

Observed on Windows 10 with installed patch revision `26.1029.7803.6`:

- Before: a new activation exited with code 0 while the old process was in
  cleanup; the old process then exited with code 0 and no window remained.
- After: two actual quit races passed, including three activations during one
  shutdown. Each race logged one queued relaunch and ended with one responsive
  window stable for at least 10 seconds, without recovery activation.
- The user separately confirmed taskbar right-click close followed by reopening
  from the original icon worked. The current window and shell tools responded.
- All 52 conversation metadata rows and authentication hashes were preserved;
  both database snapshots passed integrity checks. Only the generated CUA pipe
  directory differed in configuration.

This acceptance covers the captured shutdown race, not unrelated future crashes
or unknown Desktop builds. If the symptom recurs, preserve the live processes and
logs before choosing the next repair.
