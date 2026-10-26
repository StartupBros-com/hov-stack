## Normal path

1. `normalizeLabel` rewrites `#tag text` → `tag: text`.
2. `registerAsset`: hash the file (`fingerprint`), no existing digest match → `AssetStore.insert` + `storeBlob` (retried put, `asset.stored` metric).
3. `queueScan(asset)` fires **without awaiting** — scan runs in the background and later calls `attachScan`/`markScanFailed`.
4. `showAsset`: SPA nav via `go()`, then opens an `EventSource` to stream progress into the store.

## Duplicate case (`digest` already exists, `preview` false)

- `registerAsset` short-circuits: bumps `asset.dedup`, returns the **existing** asset — no insert, no blob write.
- Back in `handleUpload`, `flags.preview` is still falsy, so `queueScan(asset)` runs again **on the existing asset**. This re-triggers a scan (and re-`attachScan`s) for an asset that may already have a verdict — worth checking whether that's intended or a redundant-scan bug.
- `showAsset` proceeds as normal.

## Preview

- The dedup guard is `existing && !flags.preview` — with `preview: true` this is always false, so **preview never returns the existing asset even on a digest match**. It falls through to `insert` + `storeBlob` just like a fresh upload. So "preview" is not a dry run: it still writes a new row and a new blob (and can create duplicate storage for content that already exists).
- The one thing preview *does* skip is `queueScan` (guarded by `if (!flags.preview)`), so no scan is queued.
- `showAsset` still runs — preview gets a real navigation/EventSource just like a committed upload.

## `classicRedirect`

- Only affects `showAsset`: instead of SPA nav + `watchProgress`, it does `window.location.assign(...)` and returns — a full page reload, no progress subscription ever opens.
- Because `queueScan` in the normal/duplicate paths is fire-and-forget and unawaited, a full-page reload can tear down the JS context before the scan promise resolves — the `attachScan`/`markScanFailed` callback may never run. That's a real race: `classicRedirect` + background scan is a likely place to lose scan results silently.

**Bottom line surprises to flag**: `preview` doesn't prevent storage (only skips scan), the dedup path still kicks off a scan on the pre-existing asset, and `classicRedirect` can silently drop the fire-and-forget scan outcome due to the page unloading mid-flight.