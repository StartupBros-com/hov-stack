# Fixture B judge report (2026-09-02, rewritten module, six outputs, one judge)

Sonnet judge; saw answer-key.md, fixtureB-code.ts and the six `.md` outputs only.

## Scoring rule applied to all six

An edge scores PRESENT only if the output states the specific behavior/condition or explicitly annotates it in a diagram (e.g. "(await)", "not awaited", a `[condition]` guard, a diff +/- line). A bare function name in a tree (no annotation) does not establish await-ness, conditionality, or branch routing — the same standard the fixture applies to E1's rewrite behavior, extended uniformly. Compound facts (E4, E6, E8, E9, E12) need every sub-part shown; partial coverage = ABSENT, not WRONG. An annotation on one line (e.g. "not awaited" on `queueScan`) does not transfer to a neighboring line unless stated. Diff-format `+`/`-` removals count as explicitly shown.

## B-bare-1
E1 PRESENT "rewrites `#tag text` → `tag: text`" | E2 ABSENT | E3 PRESENT "fires **without await**" | E4 ABSENT | E5 PRESENT "computes digest, no existing match" | E6 PRESENT "returns the existing asset, counts `asset.dedup`, **skips** insert/store" | E7 PRESENT "inserts new `Asset` row, uploads blob" | E8 PRESENT "withRetries, 3 attempts... counts `asset.stored`" | E9 ABSENT (no verdict/failure pairing) | E10 PRESENT "returns immediately — no `go()`, no `watchProgress`" | E11 PRESENT "SPA nav via `go()`, then opens an `EventSource`" | E12 ABSENT (no onerror/close)
Q1 PRESENT "disables dedup even when a matching digest exists" | Q2 PRESENT "reload throws away JS state anyway"
T1/T2/T3 CLEAN. W=289. FORMS: prose. MERMAID=0. OPEN=no.

## B-bare-2
E1 PRESENT "rewrites `#tag foo` → `tag: foo`" | E2 ABSENT | E3 PRESENT "fires **unawaited**" | E4 ABSENT | E5 PRESENT "hashes the file, no digest match" | E6 PRESENT "returns early: no insert, no storeBlob" | E7 PRESENT "inserts a new Asset row and calls storeBlob" | E8 PRESENT "retried 3x via withRetries...then bumps asset.stored" | E9 PRESENT "calls `attachScan` or `markScanFailed` **on success/failure**" | E10 PRESENT "reload and `return`s before `go()`/`watchProgress` run" | E11 PRESENT "SPA nav via go(), then opens an EventSource" | E12 ABSENT
Q1 PRESENT "preview bypasses dedup entirely" | Q2 PRESENT "reload can tear down the page before .then/.catch resolves"
T1/T2/T3 CLEAN. W=310. FORMS: prose. MERMAID=0. OPEN=no.

## B-showme-upstream-1
E1 ABSENT (bare `normalizeLabel(label)`) | E2 ABSENT | E3 PRESENT "`[!preview] → queueScan(asset) // fire-and-forget, not awaited`" | E4 ABSENT | E5 PRESENT "`fingerprint(file) → digest` / `findByDigest(digest)`" | E6 PRESENT "`[found && !preview]→...return existing ← duplicate path, no store`" | E7 PRESENT | E8 ABSENT (no "3") | E9 ABSENT | E10 PRESENT "`STOP`" + "`watchProgress`/EventSource is never set up" | E11 PRESENT | E12 ABSENT
Q1 PRESENT "a fresh asset is inserted+stored every preview call" | Q2 ABSENT
T1/T2/T3 CLEAN. W=102. FORMS: call-tree. MERMAID=0. OPEN=no.

## B-showme-upstream-2
E1 ABSENT | E2 PRESENT "`registerAsset (await)`" | E3 PRESENT "`# not awaited`" + preview diff "skipped" | E4 ABSENT | E5 PRESENT "`fingerprint (await)` / `findByDigest → none`" | E6 PRESENT diff "+return existing # no insert, no blob write" | E7 PRESENT | E8 ABSENT (no "3") | E9 ABSENT ("`→ attachScan | markScanFailed`", no branch label) | E10 PRESENT "full page reload" + "return" + "SPA nav and watchProgress never run" | E11 PRESENT | E12 ABSENT
Q1 PRESENT "bypasses dedup entirely...fresh row + blob write" | Q2 PRESENT "the reload fetches fresh state instead"
T1/T2/T3 CLEAN. W=69. FORMS: call-tree + diff. MERMAID=0. OPEN=no.

## B-showme-adapted-1
E1 ABSENT ("label parsed") | E2 ABSENT | E3 PRESENT "`queueScan (fire-and-forget)`" + preview diff skip | E4 PRESENT "scan kicked off **without waiting**, then client-side navigation" | E5 PRESENT | E6 PRESENT diff "+return existing # skips insert + storeBlob" | E7 PRESENT | E8 ABSENT (no "3") | E9 ABSENT | E10 PRESENT "full reload, rest unreachable" | E11 PRESENT | E12 ABSENT
Q1 PRESENT "ignores an existing digest match and always inserts+stores a fresh asset" | Q2 PRESENT "the navigation abandons the JS context"
T1/T2/T3 CLEAN. W=134. FORMS: call-tree + diff. MERMAID=0. OPEN=no.

## B-showme-adapted-2
E1 ABSENT | E2 ABSENT | E3 PRESENT "`# fire-and-forget, not awaited`" + "(queueScan skipped — flags.preview is true)" | E4 ABSENT | E5 PRESENT | E6 PRESENT diff "+return existing asset" | E7 PRESENT | E8 PRESENT "`withRetries(putBlob, 3x)`" | E9 ABSENT | E10 PRESENT diff removes go/watchProgress/EventSource, adds "full page reload" | E11 PRESENT | E12 ABSENT (URL shown, no onmessage/onerror)
Q1 PRESENT "a re-upload of the same file inserts a **new** asset row instead of returning the existing one" | Q2 ABSENT
T1/T2/T3 CLEAN. W=70. FORMS: call-tree + diff. MERMAID=0. OPEN=no.

## Summary

| Output | Edges /12 | Quirks /2 | Total /14 | Traps | W | FORMS |
|---|---|---|---|---|---|---|
| B-bare-1 | 8 | 2 | 10 | 0 | 289 | prose |
| B-bare-2 | 9 | 2 | 11 | 0 | 310 | prose |
| B-showme-upstream-1 | 6 | 1 | 7 | 0 | 102 | call-tree |
| B-showme-upstream-2 | 7 | 2 | 9 | 0 | 69 | call-tree, diff |
| B-showme-adapted-1 | 7 | 2 | 9 | 0 | 134 | call-tree, diff |
| B-showme-adapted-2 | 7 | 1 | 8 | 0 | 70 | call-tree, diff |

Mean total: bare 10.5, showme-upstream 8.0, showme-adapted 8.5.

Edge class systematically lost by show-me: E1 (the `normalizeLabel` rewrite — both bare outputs state it; all four show-me outputs list the name with no description) and E9 (verdict→attachScan vs failure→markScanFailed — all four show-me outputs use an unlabelled `X | Y` pipe).

False claims: none. No edge scored WRONG and no trap sprung in any of the six outputs.
