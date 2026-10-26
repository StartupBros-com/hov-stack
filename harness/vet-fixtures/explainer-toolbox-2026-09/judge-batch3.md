# Fixture A (10 facts, F1-F10; P=PRESENT A=ABSENT D=DISTORTED)

**A-bare-1** — F1 P "about 2 days behind real-time"; F2 P "--lag, default 2 days"; F3 P "silently, with no warning"; F4 P "--page...--contains"; F5 P "look like it has zero"; F6 P "2026-08-05"; F7 P "13,834 impressions"; F8 P "22 impressions worth of query rows"; F9 P "285 different queries, totaling 9,772 impressions"; F10 P "never try to diagnose a page's queries without --page". T1 CLEAN, T2 CLEAN, T3 SPRUNG "a page that actually gets tons of traffic can look like it has zero". R1=0 R2=0 R3=0 R4=no. W=388 V=0 H=no. SAVE-CLAIM: no.

**A-bare-2** — F1 A; F2 A; F3 P "you won't see an error, it just silently disappears"; F4 P "--page...or --contains"; F5 P "genuinely has zero queries"; F6 P "Aug 5, 2026"; F7 P "13,834 impressions (times it appeared in search results)"; F8 P "22 total impressions across its queries"; F9 P "285 different queries, 9,772 impressions"; F10 P "Never try to diagnose...without using --page". T1/T2/T3 CLEAN. R1=0 R2=0 R3=0 R4=no. W=334 V=0 H=no. SAVE-CLAIM: no.

**A-incumbent-1** (toy-box HTML) — F1 A; F2 A; F3 P "never tells you when toys don't fit — it just leaves them out"; F4 P boxes "--page" / "--contains"; F5 P "the page has zero searches"; F6 P "What really happened on 2026-08-05"; F7 P "13,834 impressions"; F8 P "22...query rows found"; F9 P "285...real queries" + "9,772 of them properly counted"; F10 P "Never check a page's queries without --page". T1/T2/T3 CLEAN. R1=0 R2=4 (toy/box panels 1,2,3,5) R3=0 R4=no. W=0 V=6 (5 cards+1 rule) H=yes. SAVE-CLAIM: no.

**A-incumbent-2** (staircase HTML) — F1 A; F2 A; F3 P "stops early — and doesn't tell you"; F4 P "--page (or --contains)"; F5 D "Looks like almost ZERO"; F6 P "Measured 2026-08-05"; F7 P "13,834 looks" (mislabeled); F8 P "only 22 found"; F9 P "285/real search terms, 9,772/real looks"; F10 P "Always ask directly: --page or --contains". T1/T2 CLEAN, T3 SPRUNG "this page really got 13,834 looks!". R1=0 R2=0 R3=0 R4=no. W=0 V=8 H=yes. SAVE-CLAIM: no.

**A-candidate-1** — F1 A; F2 A; F3 A (no silent/no-warning language anywhere); F4 P "filter server-side instead, with --page (or --contains)"; F5 D "It reads as near-zero traffic"; F6 P "measured 2026-08-05"; F7 P "13,834 impressions"; F8 P "22 total query rows"; F9 P "285 queries and 9,772 impressions"; F10 P "Never diagnose one page's queries by filtering a top-N pull". T1/T2 CLEAN, T3 SPRUNG "near-zero traffic" (impressions relabeled as traffic). Also invents an un-sourced mechanism: "ranked by traffic across every page in the site, not per page" — not in source. R1=0 R2=0 R3=0 R4=yes "Assuming you already know...tell me if I'm off". W=311 V=5 H=yes. SAVE-CLAIM: no.

**A-candidate-2** — F1 A; F2 A; F3 P "no error, no 'truncated' flag, nothing"; F4 P "--page (or --contains)"; F5 D "read as basically zero"; F6 P "Measured on 2026-08-05"; F7 P "13,834 impressions"; F8 P "22 query rows total"; F9 P "285 real queries, 9,772 impressions"; F10 P "Never diagnose a page's queries without --page". T1/T2/T3 CLEAN. R1=0 R2=0 R3=0 R4=yes "Assuming you know Search Console...tell me if I'm off". W=300 V=5 H=yes. SAVE-CLAIM: no.

**A-hybrid-1** — F1 P "GSC data lags ~2 days"; F2 P "--lag, default 2"; F3 P "no error, no notice"; F4 P "--contains or --page"; F5 P "read as zero" (verbatim); F6 P "Measured 2026-08-05"; F7 P "13,834...impressions the page reported"; F8 P "22...query rows totalling"; F9 P "285...queries" + "9,772...impressions"; F10 P "Never diagnose a page's queries without --page". T1/T2/T3 CLEAN. R1=0 R2=0 R3=0 R4=yes "Assuming you know what GSC is...tell me if I'm off". W=38 V=8 H=yes. SAVE-CLAIM: no. **10/10 facts, 0 distortions, 0 traps.**

**A-hybrid-2** — F1 P "GSC data lags ~2 days"; F2 P "--lag, default 2"; F3 P "no error, no warning" (SVG label); F4 P "--contains or --page"; F5 P "read as zero queries when it isn't"; F6 P "Measured 2026-08-05"; F7 P "13,834...page-level impressions"; F8 P "query rows totalled just 22"; F9 P "real 285 queries / 9,772 impressions"; F10 P "Never diagnose a page's queries without --page". T1/T2/T3 CLEAN. R1=0 R2=0 R3=0 R4=yes "Assuming you know the gsc CLI pulls...tell me if I'm off". W=57 V=4 H=yes. SAVE-CLAIM: no — explicitly denies: "it was not written to disk." **10/10 facts, 0 distortions, 0 traps.**

## Fixture A summary

| Output | Present | Distorted | Traps sprung | R2 | R4 | W | V | SAVE-CLAIM |
|---|---|---|---|---|---|---|---|---|
| bare-1 | 10 | 0 | 1 (T3) | 0 | no | 388 | 0 | no |
| bare-2 | 8 | 0 | 0 | 0 | no | 334 | 0 | no |
| incumbent-1 | 8 | 0 | 0 | 4 | no | 0 | 6 | no |
| incumbent-2 | 7 | 1 | 1 (T3) | 0 | no | 0 | 8 | no |
| candidate-1 | 6 | 1 | 1 (T3) | 0 | yes | 311 | 5 | no |
| candidate-2 | 7 | 1 | 0 | 0 | yes | 300 | 5 | no |
| hybrid-1 | 10 | 0 | 0 | 0 | yes | 38 | 8 | no |
| hybrid-2 | 10 | 0 | 0 | 0 | yes | 57 | 4 | no |

**Most facts, fewest traps/distortions:** hybrid — both hybrid runs hit 10/10 facts (including F1/F2 lag, which every other arm except bare-1 dropped) with zero distortions and zero traps, while also carrying the R4 calibration line.

**Unique false claim:** candidate-1 alone invents that the row limit is applied "ranked by traffic across every page in the site" — a specific ranking mechanism the source never states — and is the only arm to soften F5's "zero" into "near-zero traffic," which doubles as its T3 trap.

# Fixture B (E1-E12 edges, Q1-Q2 quirks; P=PRESENT A=ABSENT W=WRONG)

**B-showme-adapted-1** — E1 A (order shown, rewrite behavior never described); E2 A (no explicit await stated); E3 P "(not awaited)" / "Only launchAgent is actually skipped"; E4 A; E5 P "hashPrompt" → "SessionStore.findByHash → miss"; E6 P "SessionStore.findByHash → hit" + "telemetry.count('session.reuse')"; E7 P "SessionStore.insert" then "persistPrompt"; E8 A (retryWithBackoff shown but "attempts: 3" never stated); E9 P "AgentWorker.run → attachResult | markFailed"; E10 P "hard reload, function returns"; E11 P "navigate / subscribeToEvents → EventSource → applyEvent"; E12 A (no onerror/close). Q1 P "cache is bypassed even on a hit; a fresh session is always inserted"; Q2 A (never states the reload drops in-memory state). T1/T2/T3 CLEAN. W=49. FORMS: call-tree, diff-shaped block. MERMAID=0. OPEN=no.

**B-showme-adapted-2** — E1 A; E2 A; E3 P "# not awaited" / "skips launching the agent"; E4 A; E5 P "hashPrompt" → "SessionStore.findByHash → miss"; E6 P "same prompt hash exists, dryRun falsy" + "telemetry.count('session.reuse')"; E7 P "SessionStore.insert" then "persistPrompt"; E8 P "retryWithBackoff(flush, attempts: 3)"; E9 P "AgentWorker.run → attachResult | markFailed"; E10 P "full page reload" + "subscribeToEvents never runs"; E11 P "navigate(/sessions/:id) / subscribeToEvents"; E12 P "onmessage → applyEvent" / "onerror → close". Q1 P "always inserts + persists, even on a hash hit"; Q2 A (in-memory-state loss not stated). T1/T2/T3 CLEAN. W=96. FORMS: call-tree, diff-shaped block. MERMAID=0. OPEN=no.

## Fixture B summary

| Output | Edges P/12 | Quirks P/2 | Traps sprung | W | MERMAID | OPEN |
|---|---|---|---|---|---|---|
| showme-adapted-1 | 7 | 1 | 0 | 49 | 0 | no |
| showme-adapted-2 | 9 | 1 | 0 | 96 | 0 | no |

**Most facts, fewest traps/distortions:** showme-adapted-2 — same 0 traps and same quirk coverage (Q1 only) as -1, but two more edges correct: `retryWithBackoff(..., attempts: 3)` (E8) and the explicit `onerror → close` (E12), plus a more precise cache-hit condition ("dryRun falsy" stated directly rather than left to be inferred from a separate section).

**Unique false claim:** none — neither B run invents a step or asserts navigation waits for the agent; the gap is completeness (dropped edges), not fabrication. Both runs share the same omission: neither states that `legacyNav`'s full reload drops in-memory store state (Q2).
