---
name: measure
description: >-
  Turn a vague question, intangible, or unknown quantity into a decision-grade
  estimate (Hubbard's method: measurement as uncertainty reduction for a
  decision). Use when sizing or estimating anything, or when something feels
  immeasurable.
argument-hint: "<question, intangible, or quantity to estimate>"
disable-model-invocation: true
---

**Measurement is uncertainty reduction for a decision** — that framing does
the work in every step below. Run all seven steps for a full estimate; steps
1-2 alone answer "make X measurable".

## 1. Decision

State the decision this number informs and its **action bound**: "at or above
V we do A; below V we do B." A question with no bound gets one proposed before
anything else happens. If no plausible value of the target changes any action,
stop and report exactly that — the measurement would be theater, and saying so
is the deliverable.

Done when: decision + action bound are written, or the run ended at "no
decision depends on this."

## 2. Observables

For an intangible target, chain it to observation: *if this changed, what
would someone see?* List indicators and classify each:

- **Input indicator** — the state of the thing itself (survey answers,
  configuration facts, behavior you can watch).
- **Output indicator** — results of having it (retention, tickets, incidents).

For every indicator, name one **gaming path** — a way the metric improves
while the real thing doesn't — and the cross-check metric that catches it.
Keep whatever composite scores, targets, or cadences you would naturally
propose; this step adds classification and cross-checks, it replaces nothing.

Done when: every indicator carries its class and its gaming cross-check.

## 3. Prior

Before any lookup or decomposition, write a 90% CI for the target from what
you know right now. This pre-registered prior is what later measurement gets
judged against, and it trains calibration: intervals that turn out to contain
the truth far more than 90% of the time are too wide, far less — too narrow.

Done when: the prior interval is written and marked "pre-registered".

## 4. Decompose

Break the target into factors that multiply or add to it. Each factor gets a
90% CI and one mark: **lookupable** (someone publishes this number),
**countable** (you can sample or query it), or **estimable only** — for
those, bound the CI against a known comparable (reference-class analogy is
the remedy when neither lookup nor sampling exists).

Done when: every factor has a CI, a mark, and the combining formula is written
with consistent units.

## 5. Combine — sample, never multiply endpoints

Multiplying the low ends and high ends of factor CIs produces an interval much
wider than 90% — the corners are jointly improbable. Sample instead, and keep
the seed in the output so the run reproduces:

```python
import random, math
random.seed(7)                      # any fixed seed; report it
def draw(lo, hi):                   # 90% CI -> lognormal draw
    mu = (math.log(lo) + math.log(hi)) / 2
    sigma = (math.log(hi) - math.log(lo)) / (2 * 1.645)
    return math.exp(random.gauss(mu, sigma))
xs = sorted(<your formula, each factor a draw(lo, hi)> for _ in range(10000))
print(xs[499], xs[4999], xs[9499])  # P5, P50, P95
```

Lognormal fits positive real-world quantities; use `random.uniform` for
genuinely bounded shares (rates between known limits). Report P5 / P50 / P95.

Done when: the reported interval came from an executed run, seed shown.

## 6. Value of information

Put the action bound from step 1 against the P5-P95 band:

- Bound outside the band → **act now, measure nothing further**, and say so.
- Bound inside the band → rank factors by (CI width × influence on the
  result) / cost to measure. Measure only the top one or two, then re-run
  step 5 with the narrowed CI.

When a factor is countable, the **Rule of Five** is often the cheapest
instrument: the range (min to max) of 5 random samples brackets the
population median with 93.75% confidence (1 − 2·(1/2)⁵).

Done when: every factor carries measure-now or leave-fuzzy, and each
measure-now factor names its instrument.

## 7. Sanity and instruments

Ask what would have to be true for the answer to be 10x higher and 10x lower;
a plausible answer to either means a factor is missing — return to step 4.
Then land every measure-now metric on a real collector: this harness's data
CLIs and telemetry (the data-source section of the global CLAUDE.md lists
them) or a named sampling protocol. End with the runnable command where one
exists.

Done when: the 10x check is written both directions and every measure-now
metric has a command or protocol.

## Output format

Decision & bound · Indicators + gaming cross-checks (intangible targets) ·
Prior (pre-registered) · Decomposition + factor table · Monte Carlo
P5/P50/P95 + seed · VoI verdict per factor · Sanity · Instruments.

## Worked example (all figures reproduce; seed 7)

**Decision**: buy a second CI runner (~$700) if flaky-rerun waste exceeds
$2,500/yr. **Prior** (pre-registered): $1K-$20K/yr.

**Decomposition**: cost/yr = reruns/wk × 52 × (min lost/rerun)/60 × $/hr.

| Factor | 90% CI | Mark |
|---|---|---|
| Flaky reruns/week | 2-10 | countable |
| Minutes lost per rerun | 5-25 | estimable |
| Operator value $/hr | 60-150 | estimable |

**Central** (geometric medians 4.47 × 52 × 11.18/60 × 94.87): ≈ **$4,111/yr**.
**Monte Carlo** (seed 7, 10,000 draws): **P5 $1,223 / P50 $4,132 / P95
$14,008**.

**VoI**: the $2,500 bound sits inside the band → don't act yet. Reruns/week
has the widest CI (5x) and is exactly countable from CI logs in minutes —
highest VoI per minute spent; measure it and re-run step 5. The $/hr factor
can stay fuzzy: holding the other two factors at their central values, even
$60/hr lands at ≈ $2,600/yr, already past the bound — its uncertainty cannot
flip the decision alone.

**Sanity**: 10x higher (~$41K) needs ~45 reruns/wk at central minutes —
implausible at this PR volume; 10x lower (~$411) needs under one rerun/wk —
refuted by a glance at the Actions tab.

**Instrument**:

```bash
gh api 'repos/OWNER/REPO/actions/runs?per_page=100' \
  -q '[.workflow_runs[] | select(.run_attempt > 1)] | length'
```
