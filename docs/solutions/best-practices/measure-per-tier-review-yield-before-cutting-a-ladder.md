---
title: "Measure each review tier's per-round yield before cutting a review ladder; review volume is not waste"
date: "2026-10-05"
category: best-practices
module: review-ladder-tier-yield
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "Sessions or PRs spend days in review rounds and someone proposes removing a tier, raising a verdict threshold, or skipping later tiers on an early verdict"
  - "A review tier's round count (ce-code-review runs per session, pro-gate rounds per PR) is being cited as evidence that the tier is ceremony"
  - "Deciding whether a re-review after a fix pays for itself, or whether a fix round may re-review only its changed hunks"
  - "A gate blocks on findings below P1 and the proposal is to make those findings non-blocking"
symptoms:
  - "Multi-day background sessions with dozens of compactions and up to 26 ce-code-review invocations in one session, read as one PR looping"
  - "A terminal gate returning FIX-FIRST round after round with no P0 or P1 ever open"
  - "A first-tier verdict that routes nearly every PR onward, so the first tier looks like it decides nothing"
tags:
  - review-ladder
  - review-yield
  - pro-gate
  - ce-code-review
  - review-adversarial-first
  - re-review
  - fix-round-scope
  - measured-recurrence
  - ceremony
---

# Measure each review tier's per-round yield before cutting a review ladder; review volume is not waste

> **Retired machinery (2026-10-18).** The default review ladder this doc
> measured was retired by #1862: a PR now gets at most one `/pro-gate`
> review, only for billing, auth, migrations or CI diffs, and
> `/review-adversarial-first` and `/ce-code-review` run only when the
> operator names them (`CLAUDE.md`, "Merge-and-end"). "The ladder
> itself is intact" below describes #1578 and no longer holds. The
> tools, `review-rounds.py` and the RESULTS.md path still resolve, and the
> measure-each-tier-first method still holds for any future tier decision.

## Context

On 2026-10-05 the operator reported that every long-running agent session looped for days without shipping and asked for the harness's friction to be cut. The first diagnosis counted volume: eight sessions of 2.5 to 16 days with 28 to 67 compactions each and up to 26 `ce-code-review` runs, 8 adversarial-first runs and 7 pro-gate rounds in a single session, with 35 to 60 percent of wall time idle on Codex peer waits, Pro rounds and merge waiters. On that count the first cut removed the review ladder from `CLAUDE.md` outright, deleted the pro-gate governor paragraph, and turned off the ultracode fan-out, as the first revision of dotfiles #1578.

The operator pushed back the same day: agents must not be under-reviewed and must not lose capability, and nobody had measured whether the review rounds were finding anything. Measuring them changed the answer three times.

**The volume was not one PR looping.** In the nine sessions the yield pass read, the five that ran 2.6 to 7.0 days each had review rounds on 10 to 19 PRs, and 64 of the 65 PRs the transcripts mention most merged, at a median 2.5 hours from open to merge. The 23 `ce-code-review` runs in the five-day session covered 19 PRs, about one per PR. The days were the ladder restarting from the top after every fix, plus tiers failing for infrastructure reasons (136 failed Pro runs in a fortnight costing 41 hours, `ce-code-review` failing on hosts without a bounded collector) that the old `result:` lock made sessions wait out.

**Each tier's first pass finds defects the others do not.** From pro-gate's own saved reviews over 14 days (215 PRs, 446 readable reviews): the terminal Pro tier's first review found an open P1 on 27 percent of PRs and an open P0 on 1 percent, and all three P0s of the fortnight were found at round 1. From adversarial-first's trusted PR ledgers (47 PRs): a P1 on 4 PRs, 39 P2s and 90 P3s at round 1. From the sessions' own summaries, `ce-code-review` blocked on 11 of 85 rounds.

**Re-reviews rarely find new blocking defects.** 231 Pro re-review rounds found a new P0 zero times, a new P1 after a clean predecessor 13 times, and sat on an unchanged open count 69 times. Re-reviews cost 24.7 hours of Pro time against 20.6 for first reviews.

Two further cuts were proposed on the numbers and refuted by following them through:

- *Make FIX-FIRST require an open P0 or P1.* 96 of 245 FIX-FIRST verdicts had nothing open above P2, which read as a calibration bug. Reading the 121 open P2s in the 95 of them that carried P2s: four were hygiene; the rest were correctness defects (a failed send returning exit 0, a retry rerunning an uninspected attempt, same-day title collisions silently overwriting exports). The pro-gate repo's own solutions note on P2-only chains records a 12-round chain where every finding was real. Raising the threshold would have shipped those.
- *Route a P3-only adversarial-first verdict as CLEAN and skip the later tiers.* 16 of 33 BORDERLINE round-1 verdicts were P3-only with no security or CI domain, and BORDERLINE routes onward, so a third of PRs paid a `ce-code-review` tier on nits. Following those 16 PRs downstream, a later tier found an open P1 or P2 on eleven: Pro found P1s on three and P2s on six more, and `ce-code-review` a P2 on two more. Two reached SHIP with nothing above P3, and three had no readable later verdict. The first tier's verdict did not predict what the deeper tiers would find.

What shipped as #1578 (merged as `b3ad5d9c`) was two sentences: a session may end once the ladder has completed or stopped, and a fix round re-reviews only the changed hunks. The ladder itself is intact. The measurement is archived as `experiments/review-yield-2026-10-05/RESULTS.md`, with `run-all.sh --pro-gate` re-reading the live store.

## Guidance

Before removing a tier, raising a verdict threshold, or skipping a tier on an earlier tier's verdict, measure three things per tier, from the tier's own records rather than from session summaries:

1. **First-pass yield.** Of the PRs the tier reviewed, how many got an open blocking finding (P0 or P1) at round 1, and how many of the fleet's P0s did it find first. pro-gate keeps this in its ledger (`ledger.jsonl` under the runtime home) and the saved review texts it points at, one `[Pn] file:line — title` line per finding with `RESOLVED` marks and a `VERDICT:` line; adversarial-first keeps it as marker comments on the PR, read with `scripts/review-rounds.py read --repo OWNER/REPO --pr N`. A tier whose first pass finds blocking defects the others did not is not ceremony, whatever its round count.

2. **Re-review yield.** Of rounds two and later, how many surfaced a blocking finding not listed in any earlier round, how many confirmed a shrinking open count, and how many sat on the same count. Report the new-finding count two ways, by count after a clean predecessor and by finding key (severity, path, first 40 title characters), because the key method cannot tell a relocated repeat from a new edge; the two numbers bound the truth. Low re-review yield supports scoping fix rounds to the changed hunks, not removing the tier.

3. **Downstream yield of the PRs a shortcut would skip.** Take the exact set of PRs the proposed rule would have stopped early and read what the later tiers found on them, from PR verdict comments and saved reviews. This is the check that refuted the P3-only shortcut: a verdict that looks decisive at round 1 is only decisive if the deeper tiers agree, and on 11 of 16 they did not.

When the numbers point at a threshold, read the findings below it before moving it. A keyword split of the 121 P2s said 52 were failure-class and 65 "other"; the "other" bucket was correctness defects under different words. Classifier output on finding titles is a prompt to read, not a verdict.

Separate the loop from the tier. The multi-day sessions were a ladder re-run per fix head plus tiers that stopped for infrastructure reasons the doctrine forbade the session from reporting. Those are fixed by a `result:` rule that accepts a stopped tier and by scoping fix rounds, with no change to what gets reviewed. Count PRs per session before reading a session's review count as a loop.

Predeclare the countermetric for any cut you do make. For scoped fix rounds it is P1s first found by a later full read that a scoped round would have passed clean; the confirming-pass yield (7 of 12 passes raised something new, 5 a new P0 or P1, since `--confirm` landed on 2026-10-03) is its first reading and the reason the confirming re-review itself was left in place pending two more weeks of data.

## Applicability

This applies to any multi-tier automated review where the tiers keep their own records and the cost of a round is visible but the yield is not. It does not measure review quality downstream (defects that reached production) or the cost of a defect a tier missed; it measures what each tier reported, and a tier can report real findings and still be the wrong tool for a diff class. The related learning `docs/solutions/best-practices/stop-adversarial-review-loops-on-measured-prevalence-not-a-clean-round.md` covers when to stop a loop on one PR; this one covers whether a tier earns its place in the ladder at all.
