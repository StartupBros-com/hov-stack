## What `handleUpload` does, end to end

Every call starts the same way regardless of flags:

1. `normalizeLabel` rewrites a leading `#tag` prefix into `tag: ` (pure string op, no side effects).
2. `registerAsset` computes `fingerprint(file)` (algorithm lives outside this file, not shown) and looks up `AssetStore.findByDigest(digest)` — a synchronous call at this site, so it must return a value directly, not a promise.

What happens next branches on the digest match and `flags.preview`.

## Normal path (no existing digest match, no flags)

- `findByDigest` returns nothing → `AssetStore.insert({ label, digest })` creates the asset record, then `storeBlob` writes the bytes via `withRetries(..., { attempts: 3 })` (retry/backoff logic lives in `@console/net`, not visible here) and bumps `metrics.count('asset.stored')`.
- Back in `handleUpload`, `!flags.preview` is true, so `queueScan(asset)` fires: it builds a `ScanWorker`, calls `.run()`, and attaches `.then(attachScan, markScanFailed)` **without awaiting**. `handleUpload` does not wait for the scan to finish or even start meaningfully — it proceeds immediately.
- `showAsset` runs the SPA branch: `go('/assets/:id')` (client-side nav) then `watchProgress` opens an `EventSource` to `/api/assets/:id/progress`, applying each message via `AssetStore.applyProgress`. Note: `onerror` just closes the stream — there's no reconnect, so a dropped connection ends progress updates silently.

So the promise returned by `handleUpload` resolves once the blob is stored and navigation is triggered — not once scanning or progress streaming finishes.

## Duplicate case (digest already exists, `preview` not set)

- `existing && !flags.preview` is true, so `registerAsset` short-circuits: it counts `asset.dedup`, **returns the pre-existing asset**, and never calls `insert`/`storeBlob`/`putBlob`. The newly uploaded bytes are discarded — nothing about the original stored blob changes.
- Because the returned asset is treated identically downstream, `queueScan` still runs — on the **existing** asset id. That means a duplicate upload re-triggers a scan and, on completion, will call `attachScan`/`markScanFailed` again, overwriting whatever verdict was already attached. Nothing in the code guards against this.
- Navigation/progress behavior is unchanged from the normal path.

## `preview: true`

- The dedupe check is bypassed entirely: `existing && !flags.preview` is false even when a match exists, so `registerAsset` **always inserts a new asset and stores a new blob**, regardless of duplicate content. "Preview" here does not mean "don't persist" — it still writes to `AssetStore` and calls `putBlob` with the same retry logic.
- The only difference preview makes in `handleUpload` itself is skipping `queueScan` — no scan is started, so the asset never gets a verdict from this call.
- Navigation still proceeds per `classicRedirect` (see below), so a preview asset is fully stored and shown, just unscanned.

## `classicRedirect: true`

- In `showAsset`, this branch takes priority: `window.location.assign('/assets/:id')` does a full page reload and returns immediately — `watchProgress` is never called, so no `EventSource` is opened by this code path at all.
- This is independent of preview/duplicate: it only changes how the already-registered (or deduped) asset is shown, not whether it was stored or scanned.

## Composing flags

`preview` and `classicRedirect` are orthogonal: e.g. `preview + classicRedirect` together means a new asset+blob is always created (dedupe skipped), no scan is queued, and the user is sent via full page reload with no progress subscription ever established.

**Not shown / assumed from usage, not documented:** `fingerprint`'s hash algorithm, `withRetries`'s backoff behavior, and `go`'s router semantics all live outside this file; `findByDigest`/`insert` are treated as synchronous only because the call sites don't `await` them.