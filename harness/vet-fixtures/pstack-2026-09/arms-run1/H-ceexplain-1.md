## Flow overview

`handleUpload` always does the same three steps in order — normalize label → `registerAsset` → (maybe) `queueScan` → `showAsset` — and the four scenarios you asked about are just different branches inside `registerAsset` and `showAsset`. Everything below is read directly off the pasted module; `fingerprint`, `AssetStore`, `ScanWorker`, `go`, and `withRetries` are imported from other packages not shown here, so their exact internals are inferred from how they're called, not verified.

### Normal path (no flags)
1. `normalizeLabel` rewrites a leading `#tag ` into `tag: ` (per the inline comment).
2. `registerAsset` hashes the file (`fingerprint`), finds no existing digest, `AssetStore.insert`s a new `Asset`, then `storeBlob` uploads it via `withRetries` (3 attempts) and bumps `asset.stored`.
3. `queueScan` fires — a `ScanWorker` is created and `.run()` is called but **not awaited**; its result later calls `attachScan` (success) or `markScanFailed` (failure) on `AssetStore`, whenever it resolves.
4. `showAsset` does an SPA nav (`go('/assets/:id')`) and opens an `EventSource` on `/api/assets/:id/progress`, piping each message into `AssetStore.applyProgress`.

### Duplicate case (digest already exists, `preview` falsy)
- In `registerAsset`, `existing && !flags.preview` is true, so it **short-circuits**: bumps `asset.dedup`, returns the existing `Asset`, and skips `insert`/`storeBlob` entirely.
- Note: the newly normalized `label` computed in step 1 is discarded — the duplicate keeps its original stored label.
- Back in `handleUpload`, `flags.preview` is still falsy, so `queueScan` **still runs**, against the existing asset. A duplicate upload therefore re-triggers a fresh scan/verdict on the same asset id — nothing in this module skips scanning for dedup'd assets.
- `showAsset` navigates to `/assets/:id`, which is the *original* asset's id.

### Preview (`flags.preview = true`)
- The dedup check requires `!flags.preview`, so it's **bypassed even if a duplicate digest exists** — `registerAsset` always inserts a new row and uploads a new blob in preview mode. This is a real asymmetry worth flagging: previewing identical content still stores a second copy, rather than reusing the existing asset the way the non-preview duplicate path does.
- `queueScan` is skipped (`if (!flags.preview)`), so no scan worker runs and no verdict is ever attached for a preview asset.
- `showAsset` isn't preview-aware — unless `classicRedirect` is also set, it still SPA-navigates and opens the progress `EventSource`. What (if anything) the backend emits on that channel for a preview-only asset isn't shown in this module.

### classicRedirect (`flags.classicRedirect = true`)
- Only affects `showAsset`: instead of `go(...)` + `watchProgress`, it does `window.location.assign('/assets/:id')` — a full page reload — and returns before ever creating the `EventSource`.
- Because `registerAsset`/`queueScan` run *before* `showAsset`, the fire-and-forget scan (if not preview) is already kicked off pre-redirect. Whether that in-flight `ScanWorker.run()` promise actually resolves and reaches `attachScan`/`markScanFailed` after the browser starts unloading the page is a runtime question this module doesn't answer — it's a plausible risk (unawaited async work racing a full navigation), not a guarantee either way from the source shown.
- `classicRedirect` composes with the other flags unchanged: e.g. `preview + classicRedirect` still forces a fresh insert (no dedup), still skips scanning, and then reloads instead of using the SPA route.

### Open questions this file alone can't settle
- Whether `AssetStore.insert`/`findByDigest` are consistent enough to avoid a race between two concurrent uploads of the same content (not visible here).
- Whether the `/progress` SSE stream carries scan-verdict data, upload-blob progress, or both — `watchProgress` is generic across all these branches.
- Exact fate of the unawaited `queueScan` promise chain during a `classicRedirect` unload, per above.