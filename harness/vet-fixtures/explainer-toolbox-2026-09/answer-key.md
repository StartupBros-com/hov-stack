# Answer key (judge-only; never paste into an arm prompt)

## Fixture A — "gsc row-limit truncation" (explainer niche)

Source passage: fixtureA-source.md (one bullet from the harness CLAUDE.md).

Facts (score each PRESENT / ABSENT / DISTORTED; PRESENT requires the specific value or the specific behavior, paraphrase allowed):
- F1  GSC data lags about 2 days.
- F2  `gsc` backs off automatically; the flag is `--lag`, default 2.
- F3  The row limit truncates silently (no error/warning).
- F4  The fix is server-side filtering with `--contains` or `--page` (either flag named counts; both = full).
- F5  Failure mode: low-traffic URLs vanish and read as ZERO (not "fewer").
- F6  Measurement date 2026-08-05.
- F7  The page reported 13,834 impressions.
- F8  The `page,query` pull returned "query rows totalling 22". The source is ambiguous (22 rows, or rows summing to 22 impressions): accept EITHER reading as PRESENT; DISTORTED only if the 22 is attached to a different quantity (clicks, queries, pages).
- F9  `--page` returned 285 queries / 9,772 impressions (both numbers = full, one = half).
- F10 Rule: never diagnose a page's queries without `--page`.

Traps (score SPRUNG / CLEAN):
- T1  The row-limit NUMBER is unstated in the source. Any specific limit (1,000 rows, 5,000, 25,000, "top 100") = SPRUNG. (Watch for false positives: "1000" inside an HTML entity or CSS is not a claim.)
- T2  "Now fixed" / "has been fixed" / "the bug was patched" framing = SPRUNG. The behavior is a standing property of the tool.
- T3  "impressions" relabelled as visits / visitors / clicks / traffic-that-arrived = SPRUNG (a semantic distortion; "views" is borderline, count as SPRUNG only if it says people visited).

Register markers (count occurrences):
- R1  Defines an adult-known word (what a search engine is, what a spreadsheet/row is, what a website is, what a command line is) — count each.
- R2  Toddler analogy (toy box, magic helper, lemonade stand, cookie jar, "like when you were little") — count.
- R3  Preamble ("Great question", "Let's dive in", "So glad you asked", "Sure!") — count.
- R4  Opens with or includes an explicit calibration/assumption line ("Assuming you know X but not Y") — yes/no.

Form metrics:
- W   Visible prose word count EXCLUDING any HTML/SVG/code blocks.
- V   Number of distinct visual scenes/panels/SVGs emitted (0 if none).
- H   Emitted an HTML document (yes/no).
- SAVE-CLAIM  Claimed a file was saved/written/opened (yes/no). An explicit statement that no file was written is "no".

## Fixture B — "handleUpload flow" (compact code-explanation niche)

Source: fixtureB-code.ts. Identifiers were chosen to share nothing with the examples inside
show-me's SKILL.md (the first version of this fixture reused that skill's own call-tree
example names and was withdrawn on code review).

Call edges / ordering facts (PRESENT / ABSENT / WRONG):
- E1  handleUpload calls normalizeLabel first (rewrites a leading "#tag " into "tag: ").
- E2  handleUpload awaits registerAsset.
- E3  queueScan runs only when preview is falsy, and is NOT awaited (fire-and-forget).
- E4  showAsset always runs, and does not wait for the scan result.
- E5  registerAsset fingerprints the file (await fingerprint) and looks up AssetStore.findByDigest.
- E6  Duplicate found AND not preview: returns the existing asset, counts metrics 'asset.dedup', skips insert/storeBlob.
- E7  Otherwise: AssetStore.insert then storeBlob.
- E8  storeBlob wraps AssetStore.putBlob in withRetries with attempts: 3, then counts 'asset.stored'.
- E9  queueScan: new ScanWorker(asset).run(); verdict -> AssetStore.attachScan; failure -> AssetStore.markScanFailed.
- E10 showAsset with classicRedirect: window.location.assign full reload and RETURN (no progress watch).
- E11 showAsset otherwise: go(...) then watchProgress.
- E12 watchProgress: EventSource on /api/assets/{id}/progress; onmessage -> AssetStore.applyProgress; onerror closes the stream.

Quirks (PRESENT / ABSENT) — the two non-obvious consequences:
- Q1  preview bypasses dedup: a new asset is inserted and its blob stored even when a duplicate already exists.
- Q2  classicRedirect never watches progress (and the full reload drops in-memory store state).

Traps (SPRUNG / CLEAN):
- T1  Invents withRetries internals (exponential schedule, jitter, base delay ms) — the source shows only attempts: 3.
- T2  Invents a step that does not exist: validation, auth check, size/type check, a scan verdict returned inline, loading spinner, toast, cache invalidation.
- T3  Claims the redirect waits for / happens after the scan finishes, or that handleUpload returns the scan verdict.

Form metrics:
- W   Visible prose word count EXCLUDING fenced code/diagram blocks.
- FORMS  Which visual forms appear: call-tree (indented names), pseudocode, mermaid block, component tree, file tree, diff-shaped block, HTML file, table. List.
- MERMAID  Number of ```mermaid blocks (these do NOT render in a terminal; count as a cost on this harness).
- OPEN  Did it emit or attempt an `open`/Bash step (yes/no).

## Scoring rule
Per arm-run: facts PRESENT count (/10 for A; /12 edges + /2 quirks for B, reported as N/14), traps SPRUNG count, register markers, form metrics. Quote the sentence for every PRESENT/DISTORTED/SPRUNG call. Do not award PRESENT for a vague gesture ("some rows get cut off" is NOT F8). Compare arms only within one judge's report: judges differ on whether contrastive wording ("launchAgent is not awaited", with nothing said about the others) makes a neighbouring "awaited" edge PRESENT.
