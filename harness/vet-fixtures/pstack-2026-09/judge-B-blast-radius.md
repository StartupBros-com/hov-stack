# Judge report: fixture B, blast-radius smoke test (2026-09-18)

Judge = a separate session-model agent that derived its own reference answer from
`../explainer-toolbox-2026-09/fixtureB-code.ts` before opening any arm output and never saw the
arm prompts. Arms = Sonnet, `claude -p --bare --tools ""`, two trials each. Question: make
`fingerprint()` include `lastModified`; what else could this break and which one fact makes it safe.

## Reference answer (written before scoring)

`fingerprint()` is called once (line 40, inside `registerAsset`). Its `digest` has five in-module
consumers and one persisted field:

| # | Consumer | Line(s) | Effect of the change |
|---|---|---|---|
| C1 | `AssetStore.findByDigest(digest)` | 41 | Dedup no longer matches same-bytes-different-time uploads |
| C2 | `metrics.count('asset.dedup')` | 43 | Undercounts as a consequence of C1 |
| C3 | `AssetStore.insert({ label, digest })` | 46 | Fires for every content-duplicate reupload |
| C4 | `storeBlob` via `withRetries(... attempts: 3)` | 47-52 | Redundant blob writes and retries |
| C5 | `metrics.count('asset.stored')` | 53 | Overcounts as a consequence of C4 |
| C6 | `Asset.digest` field (line 22), persisted | outside module | Meaning changes from content hash to content+time hash; any external consumer is suspected, not shown |

Unaffected: `normalizeLabel`, both `showAsset` branches (`classicRedirect`, `go()` + `watchProgress`,
keyed on `asset.id`), `queueScan`/`ScanWorker` mechanism (volume rises as a side effect of C3),
`watchProgress`, `withRetries` mechanics, the `flags.preview` gate.

Safety fact: whether `findByDigest` dedup is meant to match identical content "ever" or only the
same submission. Secondary: `UploadForm.file` is `Blob`, not `File`, so `lastModified` may not exist.

Traps: inventing retry internals, extra validation or scan steps, "redirect waits for the scan",
a scan-skip optimization for deduped assets (the code queues a scan unconditionally when not preview),
`ScanWorker` or `AssetStore` internals asserted as fact, server-side dedup.

## Scores

| Arm | Trial | Correct consumers /5 | Missed | False positives | Invented | Safety fact | No-tools honesty | Prose words |
|---|---|---|---|---|---|---|---|---|
| bare | 1 | 5 | C6 loosely | 1 (implies scan verdicts are reused on dedup hits today) | 1 (same claim) | present, correct, conflated with the scan-reuse claim | absent | 440 |
| bare | 2 | 4 | C5 metric name, C6 | 0 | 0 | present, correct, checkable, cleanest framing | absent | 461 |
| blast | 1 | 5 | none | 0 | 1 ("kills the scan-skip optimization", fabricated) | present, correct, split proven vs unproven | explicit, repeated | 1215 |
| blast | 2 | 5 | none | 0 | 0 (hedged Risk C as unproven; bonus true catch: line 44 `return existing` discards a new label) | present, correct, checkable | explicit, repeated | 1005 |

| Metric | bare mean | blast mean |
|---|---|---|
| Correct consumers /5 | 4.5 | 5.0 |
| Missed | 0.5 | 0.0 |
| False positives | 0.5 | 0.0 |
| Invented | 0.5 | 0.5 |
| Safety fact present/correct/checkable | 2/2 | 2/2 |
| Honest about no tools | 0/2 | 2/2 |
| Prose words | 450 | 1110 |

Structure the doctrine visibly imposed (blast only, both trials): an opening no-tools disclaimer;
"The one fact it's safe because of" with proven/unproven split; "Risks" with per-item Likelihood and
Check fields; a "Cleared" section; a ranked "Before you merge" checklist (blast-2 with runnable-shaped
test code). Bare trials had none of these.

## Verdict (smoke test)

The doctrine text improved completeness and honesty, not correctness. Both arms fabricated the same
nonexistent scan-reuse optimization once; the doctrine's Cleared and Check scaffolding did not catch it
in blast-1. Where blast wins is explicit no-tools disclosure (2/2 vs 0/2), full consumer recall, and
proven-vs-unproven bookkeeping, at roughly 2.5x the prose for a question with a short correct answer.
n=2 per arm, judge-derived key, no execution: evidence for better epistemic bookkeeping, not for better
first-pass code reading.
