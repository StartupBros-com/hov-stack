**No tools available this turn** — everything below is inspection of the module as given, plus general knowledge of the DOM `File`/`Blob` spec. I did not run, execute, or grep anything, and I don't have `fingerprint.ts`, `store.ts`, `ScanWorker`, the upload-form component, or any backend. Where the answer depends on those, I say so and mark it unproven rather than settled.

## What it does

`fingerprint(file)` currently produces (presumably) a content hash. The change adds the source's `lastModified` timestamp into that hash. Inside this module, `digest` has exactly one job: `registerAsset` (`submit.ts:39-49`) uses it as an equality key —

```
const existing = AssetStore.findByDigest(digest)   // :41
if (existing && !flags.preview) {                  // :42
  metrics.count('asset.dedup')
  return existing                                   // :44
}
```

— to decide "have we already stored these bytes." Salting the digest with time doesn't add information alongside that check, it **replaces the check's meaning**: from "same bytes" to "same bytes at the same instant/metadata-timestamp." That's not a side effect, it's the stated goal, and it collides head-on with the one place `digest` is used in this file.

## The one fact it's safe because of

I couldn't find one. What I can state with confidence (by direct read of `registerAsset`, no execution needed — this is step 3, "walked the failure and it happens," not step 4):

> Any two uploads whose bytes are identical but whose `lastModified` differs will **always** miss `AssetStore.findByDigest` and fall through to `insert` + `storeBlob` + a fresh `queueScan`. That's not conditional — it follows directly from `digest` being part of the hash input and part of the equality key at `submit.ts:41`.

Whether that's *harmless* depends on a fact I can't see from this module: does anything require `digest` to stay a pure content hash across time? That includes the dedup branch itself, and possibly code outside this file. I have no way to check those from here — see Risks A and C. So: **unproven that the change is safe; proven by inspection that it changes the dedup branch's hit rate.**

## Risks

**A. Dedup silently stops firing for a real class of uploads.** `File.lastModified` is stable metadata of the file *on disk* — reselecting the same unmodified file later gives the same value, so plain "pick the same file from the file picker twice" still dedupes fine. But `UploadForm.file: Blob` (`submit.ts:15`), not `File` — this signature accepts anything a `Blob`, including ones built at runtime: `canvas.toBlob()`, `fetch(...).then(r => r.blob())`, clipboard paste, or `new File([bytes], name)` without an explicit `lastModified` (defaults to `Date.now()` per spec). Any of those, for identical bytes uploaded twice, will now get different digests every time. Effect: `insert`/`storeBlob`/`queueScan` (`submit.ts:46-48`, `56-61`) run again for content already stored and already scanned — extra storage, extra retries via `withRetries`, extra scan cost, and `metrics.count('asset.dedup')` (`submit.ts:43`) stops reflecting reality.
*Likelihood*: depends entirely on where `form.file` comes from — not in this module, not checked. *Check*: find the upload form component and see if `form.file` is ever a synthesized Blob/File rather than a raw disk-backed `File`.

**B. Type mismatch between what's declared and what the change needs.** `UploadForm.file: Blob` (`submit.ts:15`) and `registerAsset(file: Blob, ...)` (`submit.ts:39`) are typed `Blob`, and standard `Blob` has no `lastModified` — only `File extends Blob` does. If `fingerprint()` is edited to read `file.lastModified` directly, it either (a) fails to type-check unless the type is widened to `File` and that widening is threaded back through `UploadForm.file` and every caller of `handleUpload` (not visible here), or (b) is written with a cast/duck-check, in which case genuine `Blob` inputs get `undefined` folded in — a constant — so those uploads stay content-only-hashed while `File`-sourced ones get time-salted. That's an inconsistency invisible from outside `fingerprint.ts`.
*Check*: read `fingerprint.ts`'s new implementation; not shown, not checked.

**C. Highest cost, most speculative — flag this one first.** `queueScan` (`submit.ts:56-61`) hands `asset` (including `digest`) to `ScanWorker`, whose internals aren't shown. If any scan/threat-intel logic matches `digest` against a hash list — a prior-known-clean cache, or a known-malicious blocklist — direction matters: if it's "skip scanning something already known clean," this change just means more scanning (costs money, not safety). If it's "flag something matching a known-bad hash," this change means identical malicious bytes uploaded again evade the match because the salted digest never repeats. I cannot see `ScanWorker`'s source and have no tool to fetch it — this is exactly the kind of thing grep on this module won't show, and it stays unproven either way. Given the cost if true, I'd check this before anything else in this list.

**D. Metrics drift.** `asset.dedup` (`submit.ts:43`) undercounts, `asset.stored` (`submit.ts:53`) overcounts. Low cost, easy to explain away, but any dashboard tuned to current rates will look broken the day this ships.

## Cleared

- `normalizeLabel` (`submit.ts:34-37`) never touches `fingerprint`/`digest` — no interaction.
- `storeBlob`/`putBlob` (`submit.ts:51-54`) is keyed by `asset.id`, not `digest` — the blob storage key scheme can't be corrupted by a change to what goes into the digest, only the *decision* to call it changes (covered in Risk A).
- Routing and progress-watching (`showAsset`, `watchProgress`, `submit.ts:64-77`) are keyed by `id`, never reference `digest` — no interaction.
- `AssetStore.findByDigest(digest)` (`submit.ts:41`) takes a plain `string`; nothing here breaks type-wise regardless of what goes into that string, as long as `fingerprint()`'s return type stays `Promise<string>` (assumption, not verified since `fingerprint.ts` isn't shown).

One design note, not a risk: today, re-uploading identical bytes with a *new* label silently discards that label — `return existing` (`submit.ts:44`) keeps the old one. If that's the actual complaint motivating this change, salting the digest with time "fixes" it as a side effect of breaking dedup generally. A narrower fix (update `existing.label` instead of returning it untouched) would get the wanted behavior without touching what `digest` means.

## Before you merge

I couldn't run these — no execution tool this turn — but they're the cheap way to turn A/B/C from unproven to proven or disproven:

```ts
// fingerprint.spec.ts — would need to actually run against the real fingerprint()
test('same bytes, two plain Blobs (no lastModified) still hash equal', async () => {
  const a = new Blob(['hello'])
  const b = new Blob(['hello'])
  expect(await fingerprint(a)).toBe(await fingerprint(b))   // if this fails, digest is undefined-safe but inconsistent (Risk B)
})

test('same bytes, same lastModified (reselecting an unmodified disk file) still hash equal', async () => {
  const a = new File(['hello'], 'x.txt', { lastModified: 1000 })
  const b = new File(['hello'], 'x.txt', { lastModified: 1000 })
  expect(await fingerprint(a)).toBe(await fingerprint(b))   // proves routine re-upload dedup survives
})

test('same bytes, freshly constructed Files (default lastModified) hash differently', async () => {
  const a = new File(['hello'], 'x.txt')
  await new Promise(r => setTimeout(r, 5))
  const b = new File(['hello'], 'x.txt')
  expect(await fingerprint(a)).not.toBe(await fingerprint(b)) // this is Risk A made concrete
})
```

Plus, since I can't grep: someone should check (1) what actually constructs `form.file` in the upload UI, (2) whether `ScanWorker` or anything downstream matches `digest` against a hash list, and (3) whether any other caller of `handleUpload`/`UploadForm` exists outside this file. None of that is visible from `submit.ts` alone.