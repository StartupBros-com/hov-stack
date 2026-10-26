I don't have tool access in this session — no repo grep, no read of `fingerprint.ts`/`store.ts`/`ScanWorker`, no git log/PR pull, no test runner. `submit.ts` is the only source I can see, and it's the *caller* of `fingerprint()`, not the function being changed. Everything below is reasoned from that file alone; anywhere I'd normally grep or execute, I've marked it unproven and said what check would close it.

## What it does

`fingerprint(file)` is called once, in `registerAsset`, to produce `digest`, which is used for exactly one thing in this module: `AssetStore.findByDigest(digest)` — content-based dedup that skips re-storing and re-scanning a file whose bytes were already uploaded.

Adding `lastModified` to the digest doesn't just add entropy for the stated case ("same bytes, different time"). It also changes what "different" means for two calls that used to be identical, and it does so silently downstream of a single call site whose entire job was collapsing those calls into one.

One thing worth flagging immediately: `UploadForm.file` is typed `Blob`, not `File`. `lastModified` only exists on `File` (a `Blob` subtype); plain `Blob`s don't have it. I can't see `fingerprint.ts` to know if it narrows the type or guards for `undefined` — that's the actual patch, not this module, and it's not shown.

## The one fact it's safe because of

**Claim:** within this module, `digest` has exactly one consumer that cares about content-stability — the dedup check in `registerAsset` — and nothing else here or in the wider codebase treats `digest` as a stable content-identity key (DB unique constraint used for something other than dedup, resumable/chunked upload matching, client-side integrity check, CDN/content-addressed storage key, cross-service comparison).

**How far I got it:**
- Step 2 (pointed at the line) for the *in-module* half: `registerAsset`'s only use of `digest` is
  ```
  const existing = AssetStore.findByDigest(digest)
  if (existing && !flags.preview) { ... return existing }
  ```
  and `Asset.digest` is stored via `AssetStore.insert({ label, digest })`. That's all `submit.ts` does with it.
- Unproven for the *cross-codebase* half: I have no way here to check `AssetStore`'s schema (is `digest` a unique key used for something besides this lookup?), whether anything else calls `fingerprint()` or reads `.digest` (a resumable-upload path, an admin dedup report, a signature/integrity check, a CDN key), or whether `fingerprint.ts` mixes the hash and timestamp in a way that's unambiguous (e.g. `sha256(bytes) + "-" + lastModified` vs. hashing the raw concatenation, which changes digest length/format and reopens collision-ambiguity between differently-sized inputs).

So: **not proven.** The in-module scope check is solid; the "nothing else depends on stability" claim is exactly the kind of thing that's invisible to this vantage point and needs an actual grep across the repo plus a read of `fingerprint.ts` and the `AssetStore` schema before anyone calls this safe.

## Risks

**1. Dedup silently stops working for the common case — provable by walking the code, not yet run.**
`apps/console/src/features/upload/submit.ts`, `registerAsset`:
```
const existing = AssetStore.findByDigest(digest)
if (existing && !flags.preview) { ... return existing }
const asset = AssetStore.insert({ label, digest })
await storeBlob(asset, file)
```
Once `digest` depends on time, `findByDigest` stops matching for the exact case the dedup path exists for (double-submit, retry-after-timeout-but-it-actually-succeeded, re-uploading a file you already have registered). Every such event now runs `AssetStore.insert` + `storeBlob` (with its 3 retries) + a brand-new `queueScan` (new `ScanWorker`, new async scan) + a new `EventSource` in `watchProgress`. Likelihood: high, this is the normal path, not an edge case. Cost: duplicate storage, duplicate scan-infra load, `asset.dedup` metric drops toward zero while `asset.stored` rises — any dashboard/alert built on that ratio moves without anything being "broken." Unproven whether this is intended; the prompt's stated goal ("different fingerprints for different-time uploads") *is* this behavior, so it may be the point — but it's worth confirming the author knows it also kills the scan-skip optimization for genuinely identical re-uploads, since that optimization currently means "already-scanned content doesn't get re-scanned." Check: a two-line test — call `registerAsset` twice with identical bytes and two `lastModified` values, assert whether `storeBlob`/`queueScan` fire once or twice. I wrote this as a script but could not execute it here (no runner available).

**2. `Blob` vs `File` — unproven, needs `fingerprint.ts`.**
`UploadForm.file: Blob`. `lastModified` isn't on `Blob`. If any caller constructs a plain `Blob` (canvas export, `fetch().blob()`, clipboard paste, drag-and-drop synthesized as Blob) rather than a `File` from `<input type=file>`, `file.lastModified` is `undefined` at that call site. Depending on how `fingerprint.ts` handles that: either every such Blob-sourced upload collapses onto one digest bucket regardless of real time (dedup accidentally still works there, defeating the stated goal for that path), or the implementation throws/produces `"undefined"` baked into the hash input (harmless but inconsistent). I can't see `fingerprint.ts`, so I can't say which. Check: read `fingerprint.ts`'s signature and its handling of a missing `lastModified`, and grep call sites of `handleUpload`/`UploadForm` for anything that isn't a real `<input>`-derived `File`.

**3. Digest format/length change — unproven, needs `fingerprint.ts`.**
If the change is "hash(bytes) then append lastModified as a string" rather than "hash(bytes ++ lastModified) with an unambiguous encoding," `digest`'s length and character set change from whatever fixed hex format it was. That's a problem if `AssetStore`'s digest column is fixed-width, if `digest` shows up in a URL path anywhere, or if any other system expects a specific hash format. I have no visibility into `store.ts` or the digest's actual shape (only that it's typed `string`). Check: read `fingerprint.ts`'s return construction and the DB column definition for `digest`.

**4. Asset identity changes for the user — visible in this module, low severity.**
`showAsset` → `go(/assets/${id})` or, with `classicRedirect`, `window.location.assign(/assets/${id})`. Since dedup no longer fires, resubmitting identical content now yields a new `id` each time instead of landing back on the same asset. If anything relies on "reselecting the same file always gets you to the same asset URL" (bookmarks, tests, user expectation), that's now false. Real but low-cost; flag rather than block on it.

## Cleared

- `flags.preview` path is untouched by this change: `if (existing && !flags.preview)` already skips dedup whenever `preview` is true, so preview-mode behavior is identical before and after. Confirmed directly from the line, no dependency on tools.
- `normalizeLabel` has no interaction with `digest` — cleared by inspection, unrelated code path.
- `withRetries`/`storeBlob` mechanics are unaffected structurally by this change; they just get called more often (covered under Risk 1, not a separate correctness risk).
- The hash algorithm itself isn't being weakened for security purposes by this change (not a crypto/security regression on its face) — the concern is content-identity stability, not hash strength.

## Before you merge

Cheapest real check, in order:
1. Open `fingerprint.ts` and answer: does it take `File` or `Blob`? How does it fold `lastModified` into the digest (hash of concatenation vs. string append)? What does it do when `lastModified` is `undefined`?
2. Grep the repo for other callers of `fingerprint(` and other readers of `Asset.digest` / `AssetStore.findByDigest` outside this module, to actually test the "one fact" above instead of assuming it.
3. A test I could write but not run here — call `registerAsset` (or `handleUpload`) twice with byte-identical `Blob`/`File` content and two different `lastModified` values, and assert on the call counts to `AssetStore.insert`, `storeBlob`, and `queueScan`. That single test converts "dedup breaks for this case" from a code-walk into a proven fact (step 4), which is the fact this whole change actually turns on.

I couldn't run any of the above in this session — no filesystem, grep, or test execution was available to me here.