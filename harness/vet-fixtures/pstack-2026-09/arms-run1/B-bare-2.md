## What the change would touch

The only visible consumer of `fingerprint()`'s output is:

```ts
const digest = await fingerprint(file)
const existing = AssetStore.findByDigest(digest)
if (existing && !flags.preview) {
  metrics.count('asset.dedup')
  return existing
}
```

So `digest` is currently acting as a **content-identity key** — "have we seen these exact bytes before, ever." Adding `lastModified` into the hash changes its meaning to "have we seen these exact bytes at this exact moment before," which is a different guarantee.

## What could break

1. **Dedup becomes dead code.** Re-uploading a file you already uploaded (same bytes, later time) will now almost never match `findByDigest`. Every such upload falls through to `AssetStore.insert` + `storeBlob`, silently duplicating storage that was previously being avoided. This is the direct, intended-by-you consequence, but it's worth stating plainly since "dedup" is a named metric/feature here, not incidental.

2. **`asset.dedup` metric goes to ~zero regardless of actual duplicate-content rate.** Anything downstream (dashboards, alerts, capacity planning) that reads this counter as a proxy for "how often users re-upload the same file" will misreport — it'll look like duplicate uploads stopped happening, when really the detection just stopped working.

3. **`lastModified` isn't a reliable input.** The parameter type is `Blob`, not `File`. Plain `Blob`s (e.g., built from an `ArrayBuffer`, clipboard paste, or fetch response) don't carry `lastModified` at all. If `fingerprint()` has to synthesize a value in that case (e.g., `Date.now()`), you'd get non-deterministic digests even for the *same* file uploaded twice in the same request — breaking dedup harder than today, not just weakening it for cross-time cases.

4. **Legitimate "same content, different provenance" cases stop deduping.** Re-saving, re-exporting, copying, or re-downloading a file typically changes `lastModified` even though bytes are identical. If part of the product intent is "don't store the same PDF/image twice," those cases now silently bypass that intent.

Nothing else in this module reacts to `digest` (scan queuing, routing, progress watching are all keyed off `asset.id`, not digest), so the blast radius *within this file* is fully contained to the dedup branch and its metric.

## The one fact that would make it safe

Whether **`findByDigest` is meant to detect "same content, ever" or only "same submission, right now."**

If the actual product requirement for dedup is narrow — e.g., it exists only to catch a double-click/double-submit of the *same* file-picker selection within one interaction, not to catch a user uploading an identical file next week — then folding `lastModified` in is not just safe, it's arguably more correct, since two independently-submitted uploads of coincidentally-identical bytes may deserve to be treated as distinct assets (separate audit trail, separate scan, separate lifecycle).

If instead the requirement is "never store the same bytes twice, no matter when," then this change quietly defeats that feature, and you'd want the timestamp disambiguation to live somewhere else (e.g., in `Asset.id` or a separate "uploadedAt" field) rather than in the content digest itself.