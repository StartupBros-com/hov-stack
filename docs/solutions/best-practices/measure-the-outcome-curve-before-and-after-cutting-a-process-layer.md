---
title: "Measure the product repo's outcome curve before cutting a process layer, and re-run the same curve after"
date: "2026-10-18"
category: best-practices
module: harness-teardown-outcome-curve
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "An agent harness or CI pipeline has grown process layers (review tiers, owner or dispatcher units, claims, guards) and someone proposes keeping, adding or cutting one"
  - "The only evidence that a layer is worth its cost is what the layer itself reports catching"
  - "Merge throughput or open-to-merge latency in the product repo has moved and nobody has lined it up against the dates each layer landed"
  - "A teardown has shipped and someone has to say whether it worked"
symptoms:
  - "the members app weekly merges fell from 199-240 (weeks of Sep 7-21) to 97 (week of Oct 12) while median open-to-merge latency rose from 0.9-1.5 h to 14.5 h, and no harness tool reported it"
  - "Every incident a layer cited as its catch was a code comment or an agent-written memory, never a counted outcome"
  - "A per-tier yield study on 2026-10-05 kept the review ladder intact while the weekly curve was already falling"
tags:
  - outcome-metric
  - throughput
  - merge-latency
  - harness-teardown
  - process-layer
  - ceremony
  - review-ladder
  - measure-before-cut
---

# Measure the product repo's outcome curve before cutting a process layer, and re-run the same curve after

## Context

Between Sep 4 and Oct 4 2026 the dotfiles harness stacked three layers on the members app merge
path:

- **Sep 4:** `pro-gate-loop.sh`.
- **Sep 21-24:** the review ladder (adversarial-first, review-rounds, red-first,
  shape-rewrite, fanout-admission, the loop-guard family).
- **Oct 4:** the owner fleet (pr-handoff, pr-owner, pr-owner-recover).

Each layer was argued for by what it catches. Nothing measured what the product repo
actually shipped. On 2026-10-17 a read-only "harness pipeline map" did. It is archived as
`experiments/harness-teardown-2026-10/baseline-map-2026-10-17.txt`. Its curve, which
the kit's scripts reproduced on 2026-10-18:

| Week of | Merged | Median h | p90 h |
|---|---|---|---|
| Aug 24 | 208 | 1.1 | 13.4 |
| Aug 31 | 158 | 2.2 | 16.7 |
| Sep 7 | 240 | 1.5 | 18.1 |
| Sep 14 | 199 | 0.9 | 4.4 |
| Sep 21 | 231 | 0.9 | 11.2 |
| Sep 28 | 144 | 2.9 | 38.5 |
| Oct 5 | 107 | 5.5 | 30.8 |
| Oct 12 (through Oct 17) | 97 | 14.5 | 234.7 |

The map reads it carefully: the ladder and the owner fleet each landed "at the start of a
step down. That is correlation on eight data points; the mechanism sections below are what
make the case."

The earlier attempt looked inside the layers. The 2026-10-05 yield study
(`measure-per-tier-review-yield-before-cutting-a-ladder.md`) measured each review tier from
its own records. It found real first-pass catches and shipped #1578 with "The ladder itself
is intact." That answered whether each tier finds things. It did not ask what the whole
stack cost the product repo, and its own Applicability section says it "does not measure
review quality downstream (defects that reached production)." By then the Sep 28 week was
already down to 144 merges at a 2.9 h median.

Before the map, the session went at the problem one lane at a time (session history):

- It built a CI change that took the browser suites off the PR path.
- It noted that defects found in a gate had been fixed by making the gate stricter.

The operator stopped both and asked for every step to be mapped and judged.

The teardown that followed, 2026-10-17/18:

- #1862: merge-and-end replaced the ladder and pr-handoff.
- #1873: the owner fleet and dispatcher retired.
- #1902: issue claims retired.
- #1913: the context fence retired.
- #1916: the loop-quality layer retired.

## Guidance

1. **Measure the outcome curve first, in the product repo, not the harness.** For each
   merge week:
   - PRs merged;
   - PRs opened, which is the demand signal;
   - product share;
   - median and p90 open-to-merge hours.

   GitHub's search REST endpoint gives all of it read-only. The scripts are
   `merge-rate.py`, `latency.py` and `pr-mix.py` in `experiments/harness-teardown-2026-10/`.
   Compare whole weeks. A partial week has to say it is partial: the map's Oct 12 row was 59
   merges taken partway through Oct 17, and the whole week was 97.

2. **Overlay the date each layer first appeared, taken from the harness repo's history**
   (`intro-dates.py` reads the first commit per file), not from memory. That turns "the
   harness feels slow" into a dated claim you can check. Say what it is: eight weekly
   points are correlation, not mechanism. The mechanism has to come from walking the steps.

3. **Give every step a verdict: keep, cut or simplify.** Each verdict carries:
   - what the step costs;
   - what it has demonstrably caught;
   - an evidence tag on each claim.

   The map's tags were M (measured this session and reproducible), L (counted from a ledger
   or log) and C (a claim from a code comment, memory note or skill file, not checked). Most
   "it caught X" statements were C. Its appendix lists the adversarial-first skill's "4 of 4
   P1s" claim as unverified, because the run data could not be found. Keep only gates with a
   named catch: "Every gate that stays has a named catch. A gate with no catch is cost."

4. **Cut in reversible moves, each waiting for the operator's word.** Every move is a PR or
   a documented command, "so each is a revert away".
   - Build the replacement path first. The merge-and-end rule went in additively, before
     anything was removed.
   - Then remove what nothing calls any more.
   - Cuts that only save cost go last.

   Disable, do not purge: no ledger, reservation file or running PR's state is deleted.

5. **Re-run the same curve after the cut, and decide how to read it before you see it.**
   The kit's README sets two bands:
   - **Pre-ladder (Aug 24 - Sep 21):** 158-240 merged, median 0.9-2.2 h.
   - **Ladder era (Sep 28 - Oct 12):** 97-144 merged, median 2.9-14.5 h.

   Inside the pre-ladder band means the curve has recovered. Inside the ladder band means
   the cut did not move it: look elsewhere before restoring anything. In between is
   "inconclusive". Product share overlaps across the two bands (0.59-0.84 against
   0.59-0.79), so it is reported but not decided on.

   For this teardown, run the commands in the kit's README on or after 2026-11-02 with
   `--end 2026-11-01`. **The verdict is pending as of this writing. Nothing schedules the
   re-run.**

6. **Expect the backlog to drain through the first post-cut weeks.** Of the 50 PRs merged on
   Oct 17, 13 had been open 223 to 289 h. Old PRs merging push up p90 and max without saying
   anything about new work, so read the median first.

7. **Check a target against the curve before chasing it.** A target of 250 merges a day was
   tested against the best of the eight weeks measured (session history). That week opened 260 PRs and
   merged 240, about 37 and 34 a day. Removing every gate at that rate still gives the
   mid-30s a day, so the rest of the gap is how much work gets started, not the harness.

## The gap: no outcome metric for quality

The curve says faster or slower, not better or worse. No count of defects reaching
production by week exists in the harness's docs, memory, CONCEPTS.md or scripts. The map
says it directly: "A count of defects that reached production, by week, which is the only
number that would say whether any of this was worth it." In its verdict table, both
advocates conceded that "every incident citation above is a code comment or an
agent-written memory, and no downstream production-defect measure exists."

So a layer's case has two halves that cannot be netted against each other:

- what it costs, from the curve;
- what it reports catching, from its tier yield.

What the catching is supposed to prevent is never counted. A layer cannot prove it is worth
keeping, and a cut cannot prove it is safe.

One candidate proxy is product merges per week whose title starts `fix` or `revert`. It is
not a metric:

- it cannot attribute a defect to the cut;
- it rises and falls with throughput.

Report it next to the curve and never decide on it alone. A real metric, such as production
incidents or reverted deploys per week, would replace the kit.

## Why This Matters

Layers were added on per-layer arguments, each one catches something, and none was checked
against the product repo's output. Nearly four weeks of ladder and owner fleet ran while weekly
merges fell from 231 to 97. The one study that measured the ladder looked inside it and kept
it.

The check that would have caught this is a weekly curve anyone can re-run in a few minutes.
Skipping the re-run repeats the mistake in reverse: a cut justified by an argument, never by
an outcome.

Measurement hygiene matters as much as the metric (session history):

- A 5-day sample suggested one runner label was slow. An unsampled week of 815 runs put
  only 1 of 3 checks past the 1.5x slowdown rule.
- A collector's hook-timing figure was replaced by a peer's re-measurement, tagged "not
  re-run by me".

Unsampled counts and tagged provenance are what let the verdict table hold up.

## When to Apply

- Before adding a process layer: record the curve, so there is a "before" to compare with.
- Before cutting one: build the curve, the dated overlay and the verdict table. Do not
  start from the layer's own reports.
- After a cut: re-run the same scripts, read the result against bands written down before
  the run, and record the verdict here.
- Whenever a layer's case rests on C-tagged claims.

## Examples

**Yield only (2026-10-05).** Pro's first review found an open P1 on 27 percent of PRs, and
re-reviews rarely found new blocking defects. Result: two sentences shipped (#1578) and the
ladder stayed. The curve was not consulted.

**Curve plus verdict table (2026-10-17).** The same ladder showed as a dated step down in
merges and a rise in latency. The verdict table kept Pro as a single review, since it was
the tier with named catches. #1862 then took the other tiers off the default path. Ten
reversible moves followed, each a PR or a documented command, each on the operator's word.

**The re-run (pending).** From `experiments/harness-teardown-2026-10/`:

```bash
python3 -I merge-rate.py --end 2026-11-01
python3 -I latency.py --end 2026-11-01
python3 -I pr-mix.py --end 2026-11-01
```

Compare the Oct 19 and Oct 26 rows with the bands in the README, then add the verdict to
this doc.

## Related

- `docs/solutions/best-practices/measure-per-tier-review-yield-before-cutting-a-ladder.md`:
  per-tier yield, the benefit side of the same decision. It is complementary, not a
  duplicate: it measures what each tier reports, and this doc measures what the stack costs
  the product repo.
- `docs/solutions/best-practices/stop-adversarial-review-loops-on-measured-prevalence-not-a-clean-round.md`:
  the same keep-only-what-is-measured stance, applied to one review loop.
- `experiments/harness-teardown-2026-10/README.md`: the baseline table, the bands,
  the re-run commands and the kit's deletion condition.
- `CLAUDE.md`, Honest Work: a process artifact must name its consumer, the feature
  it gates, its defect class and its deletion condition. The kit's README carries all four.
