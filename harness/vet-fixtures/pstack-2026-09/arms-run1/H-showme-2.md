**Normal path** — the full call tree:

```text
handleUpload
  normalizeLabel
  registerAsset
    fingerprint
    AssetStore.findByDigest      → none
    AssetStore.insert
    storeBlob
      withRetries(putBlob)
      metrics: asset.stored
  queueScan                       (fire-and-forget, not awaited)
    ScanWorker.run → attachScan | markScanFailed
  showAsset
    go(/assets/:id)
    watchProgress
      EventSource → applyProgress
```

**Duplicate** — `findByDigest` hits, so storage is skipped, but the scan still re-runs on the existing asset:

```diff
 registerAsset
   fingerprint
   AssetStore.findByDigest        → hit
-  AssetStore.insert
-  storeBlob
+  metrics: asset.dedup
+  return existing
 queueScan(existing)              ← still fires, unchanged
```

**Preview** — dedup is bypassed (`existing && !flags.preview`), so a preview *always* inserts+stores a fresh asset, but the scan is skipped entirely:

```diff
 registerAsset
   fingerprint
   AssetStore.findByDigest        → hit is ignored, preview forces a new asset
   AssetStore.insert
   storeBlob
-queueScan(asset)                 ← skipped because flags.preview
 showAsset
```

**classicRedirect** — short-circuits before `go`/SSE setup, full page reload:

```diff
 showAsset
-  go(/assets/:id)
-  watchProgress
-    EventSource → applyProgress
+  window.location.assign(/assets/:id)   // full reload
+  return
```

⚠️ Because `queueScan` in `handleUpload` is never awaited, a `classicRedirect` (or even the fast client nav) can beat it to the punch — `attachScan`/`markScanFailed` may lose the race against the page unload, silently dropping the scan result for that load.