## Normal path

1. `normalizeLabel` rewrites `#tag text` → `tag: text`.
2. `registerAsset`: fingerprints the file, no existing digest match → `AssetStore.insert` creates a new `Asset`, then `storeBlob` uploads via `withRetries` (3 attempts) and counts `asset.stored`.
3. Back in `handleUpload`, `queueScan` fires a `ScanWorker` **without awaiting it** — result later lands via `attachScan`/`markScanFailed`.
4. `showAsset`: SPA nav via `go()`, then opens an `EventSource` to stream progress into `AssetStore.applyProgress`.

## Duplicate case

- `fingerprint` matches an existing digest, and `!flags.preview` → short-circuits: counts `asset.dedup`, returns the **existing** asset. No insert, no `storeBlob` call (no re-upload).
- Caveat: `handleUpload` doesn't know a dedup happened — it still calls `queueScan(existing)`, so a scan is re-queued for an asset that may already have a scan verdict. Worth checking if `ScanWorker`/`attachScan` handle re-scans idempotently.

## Preview

- In `registerAsset`, the dedup check is gated on `!flags.preview` — so **preview mode never dedupes**, even if the digest already exists. It always inserts a new `Asset` row and uploads the blob. That's a bit counter-intuitive for something called "preview."
- `handleUpload` skips `queueScan` entirely when `preview` is true — no scan is queued for the freshly-stored preview asset.
- `showAsset` still runs normally (SPA nav + `EventSource`), so you get a progress stream open for an asset that will never emit scan-driven progress unless something else feeds it.

## classicRedirect

- Only affects `showAsset`. Whatever happened upstream (insert/dedup, scan queued or not) already occurred by this point.
- If `classicRedirect` is set: `window.location.assign(...)` does a full page reload and returns immediately — no `go()`, no `EventSource`/progress watcher gets set up client-side.
- Since `queueScan` is fire-and-forget and not tied to the page lifecycle, a scan already in flight will keep running server/worker-side, but the reload means this tab won't see live progress — the next page load has to pick up state from wherever `Asset`/scan status is persisted, not from the in-memory `AssetStore` progress stream.