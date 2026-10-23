# Windows Store download fallback

On Desktop package `26.928.1915.0` (app `26.928.20755`), the Store updater can fetch a newer official manifest and then receive `hasUpdate=false`, `canSilentlyDownload=true`, `completed=false`, `overallState=NoUpdates`. The same symptom was observed before manually updating from package `26.924.2738.1`.

The shipped `performCheck()` reports `handled / up-to-date` whenever `hasUpdate` is false. The combined updater therefore skips its existing official MSIX download fallback. This proves a Codex control-flow defect; it does not establish why Store's API and its interactive UI disagree.

Use `-PatchWindowsStoreUpdateFallback` on the full patcher or wrapper after reproducing this signature. Run `-DryRun` first. The patch requires a valid local build version and a strictly newer manifest before returning the fallback decision. Current or missing manifests, completed Store downloads, Store errors and callers that disallow fallback retain their existing paths. Unsupported bundle shapes and partial patches fail before writing the asset. No Store task, Windows policy, update interval or download host is changed.

The existing fallback derives an HTTPS `ChatGPT-x64.msix` URL from the official Windows manifest and hands it to the native package staging operation. It preserves the package identity, publisher and Windows signature checks. No unsigned download or private endpoint is introduced.

Validate the extracted target with:

```powershell
node scripts/test-windows-store-update-fallback.cjs '<extracted>/.vite/build/bootstrap-Bj_1Kfw1.js'
```

This regression executes the real Store/coordinator classes with boundary doubles. It covers automatic/manual fallback, current/missing manifests, completed downloads, unavailable silent download, Store errors, Store-only callers, idempotence and ambiguous patch rejection. It does not perform a real future-version download or installation. Separately, the `26.928.1915.0` official package was downloaded in full (HTTP 200, 905731855 bytes); its signature, publisher and all payload blocks were valid. The installed `26.928.1915.1` patch was extracted again and passed the same regression; its startup log reported the in-app update policy enabled. A later-version automatic download remains a separate future-update acceptance check.

## Later exact layouts

The logger-renamed `26.1002` and `26.1013` layouts have separate exact profiles. `26.1016.8622.0` instead separates discovery and download state into `windows-offers`: both discovery NoUpdates and silent-download NoUpdates must retain the strictly newer official manifest offer. The patch updates all three guarded branches together; a partial or duplicate patch fails before writing. `test-windows-store-update-fallback.cjs` dispatches to `test-windows-store-offers-fallback.cjs` for this layout.

The offers regression executes the extracted Store, Offers and combined-updater classes. It reproduces the original newer-manifest NoUpdates failure and checks automatic/manual discovery, silent-download fallback, cached offers, throttle preservation, current/missing manifests, completed downloads, invalid build versions, package identity/publisher mismatches, Store-only callers and unavailable direct feeds. An unreachable feed retains `waiting-for-store`; it does not fabricate an available download. These isolated checks do not establish a live future-version update.

On the exact `26.1016` offers layout, the shipped comparator is `fn`; `un` returns an appcast URL. A previous local overlay referenced `un` and could pass structural checks without selecting fallback. The patch now requires both shipped `fn` witnesses, uses `fn` in both added comparisons and repairs only the complete known stale overlay. The regression executes the real version comparator/parser and rejects mismatched witnesses. An already-installed stale overlay requires this repair during a later authorized repatch; a skill-source update alone does not modify the running Desktop.
