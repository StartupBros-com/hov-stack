### Normal path

```text
handleUpload
  normalizeLabel
  registerAsset
    fingerprint(file)
    findByDigest -> miss
    AssetStore.insert
    storeBlob
      withRetries(putBlob)
      metrics.count('asset.stored')
  queueScan(asset)            # not awaited
    ScanWorker.run -> attachScan | markScanFailed
  showAsset
    go(`/assets/:id`)
    watchProgress
      EventSource -> applyProgress
```

### Duplicate case

```diff
 registerAsset
   fingerprint(file)
   findByDigest
-  -> miss
-  insert + storeBlob
+  -> hit, and not preview
+  metrics.count('asset.dedup')
+  return existing            # insert/storeBlob skipped
```

Gotcha: `handleUpload` doesn't know it got a dedup hit — it still calls `queueScan(existing)`. Uploading a duplicate re-triggers a scan on an asset that may already be scanned.

### preview

The dedup check is `existing && !flags.preview`, so preview forces it false even on a hit:

```text
preview=true → registerAsset always inserts + storeBlob (no dedup, ever)
preview=true → handleUpload skips queueScan entirely
```

Net effect: preview always writes a fresh blob, never scans it — but `showAsset` still runs and opens `watchProgress`'s `EventSource`, listening for progress on a scan that was never queued.

### classicRedirect

```diff
 showAsset
+  if classicRedirect
+    window.location.assign(`/assets/:id`)   # full reload
+    return
   go(`/assets/:id`)
   watchProgress(id)
```

classicRedirect short-circuits before `watchProgress` — no EventSource, no live progress; the reloaded page is expected to source its own state.