---
title: "Prove the baseline can fail before trusting an agent bake-off's tie"
date: 2026-08-11
category: best-practices
module: agent-eval-methodology
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "Running a controlled bake-off between agent mechanisms where a difficulty ladder must reach a real failure regime before results are trusted"
  - "All compared arms score identically (e.g. 100%) across every escalation -- treat as an eval-blindness alarm, not a settled verdict"
  - "The treatment mechanism itself was never instrumented to prove it fired before the headline comparison ran"
  - "A paired bootstrap or resampling CI returns zero width because every paired observation is identical (degenerate, not precise)"
  - "A mandated comparative-performance gate (e.g. a cv-threshold gate) is applied to a workload whose variance is inherent model stochasticity, not host noise"
related_components:
  - "rlm-bakeoff-scripts"
  - "ab-pair-gate"
  - "evidence-regime"
tags:
  - eval-discrimination
  - ceiling-effect
  - degenerate-statistics
  - paired-mcnemar
  - bake-off-methodology
  - entry-criteria
  - rule-of-three
  - ab-pair-gate
---

# Prove the baseline can fail before trusting an agent bake-off's tie

## Context

We ran two controlled bake-offs (issue #356 / PR #357, then issue #361 / PR #362) to
decide whether to adopt a persistent-kernel "external state" mechanism (the pattern
popularized by the Prime Agent project) into a daily-driver Claude Code harness. The
adoption decision itself is not the durable part — it is recorded once, as an ADR, at
`harness/rlm-external-state-decision.md` (merged as PR #372), and a future
engineer evaluating an unrelated mechanism should cite that note rather than re-derive
it.

What is durable is the shape of the mistake the first round made and the fix the second
round applied, because the same failure mode recurs in any "does mechanism X help our
agent" eval: **round 1 produced 141 runs across five difficulty escalations (22 KB to
20 MB corpora, `scripts/rlm-bakeoff/gen_corpus.py` defines sizes `small`=400 rows
through `xxl`=400,000 rows) and every single arm scored 100% on every escalation**
(`scripts/rlm-bakeoff/RESULTS.md`). A 100%-vs-100% tie looks like "the mechanism
doesn't matter" and is instead frequently "the eval never got hard enough to see a
difference" — and those two states are indistinguishable from the top-line number alone.
The operator's pushback — "a 100% tie is equally consistent with 'mechanism useless' and
'eval blind'" — is the thing worth generalizing, not the specific verdict about kernels.

Independent corroboration for the general failure class showed up the same day in an
unrelated repo: a private evals repository's task suite was found saturated at 262/262 passing runs,
binary entropy zero, from a completely different root cause (grader false-negative
repair loop), and the applied lesson there was the same — retire or redesign a
saturated task rather than let it vote in a ranking (machine-local memory note
`premise-integrity-saturated-zero-discrimination`, a private evals repository's project store). Two
unrelated causes converging on "a ceiling metric carries no information" is why this is
filed as a reusable methodology note, not a one-off incident report.

## Guidance

**1. Difficulty is an entry criterion, not an outcome you discover after running the
matrix.** Round 2's tournament design states this explicitly: a family does not enter
the tournament until the baseline measurably fails on it — see
`scripts/rlm-bakeoff/RESULTS-TOURNAMENT.md`, with the concrete 30-70% baseline
success target pre-registered in the work-spec (issue #361). That target was never
actually hit — the baseline went 19/19 under compaction across the tournament and
calibration runs — and the write-up reports that honestly as a limitation rather than
treating "we escalated five times and it still tied" as sufficient rigor. The
generalizable rule: before you trust an eval's contrast between two treatments, first
prove the *control* arm can lose on that task. If the baseline cannot fail, no
comparison run on top of it can produce information, no matter how many reps you buy.

**2. Instrument the treatment before the headline runs, not after.** Round 1 shipped a
kernel-usage audit trail in a commit *after* the 90 measured-matrix runs, so none of
those rows carry per-run kernel evidence — the field is absent, not zero
(`scripts/rlm-bakeoff/RESULTS.md`). An adversarial "inward vet" pass blocked on
exactly this gap. Round 2 fixed it structurally: every run streams
`--output-format stream-json`, so tool calls are parsed inline
(`scripts/rlm-bakeoff/run_tournament.py`, `parse_stream`), and each record
carries a computed `mechanism_engaged` flag:

```python
# run_tournament.py
rec["mechanism_engaged"] = (
    True if arm == "A_default"
    else rec["pyk_calls"] > 0 if arm == "K_kernel"
    else rec["delegations"] > 0)
```

A null result is worthless unless you can also show the treatment fired. Build the
"did the mechanism actually engage" signal into the harness that produces the headline
number, not as a follow-up query against logs someone happened to keep.

**3. A saturated (or degenerate) contrast is not a precise contrast — detect it and
report a bound instead of a confidence interval.** When every arm agrees on every task,
a naive bootstrap resamples identical values and returns a zero-width CI. That reads as
"we know the effect to within ±0.0pp" when it actually means the data carry zero
information about the tail. `scripts/rlm-bakeoff/stats_paired.py` names this
explicitly and flags it:

```python
def paired_bootstrap_ci(pairs, iters=20000, seed=17, alpha=0.05):
    """CI for mean(y) - mean(x) over paired observations, resampling tasks.

    Returns (lo, hi, degenerate). `degenerate` is True when the resampled
    statistic never moves, which happens when the two arms agree on every task
    -- there the interval is not evidence of precision.
    """
    ...
    return (lo, hi, lo == hi == 0.0)
```

and replaces it with a rule-of-three bound when triggered:

```python
def rule_of_three(n, conf=0.95):
    """Upper bound on an unobserved failure rate after n clean trials."""
    if n <= 0:
        return 1.0
    return min(1.0, -math.log(1 - conf) / n)
```

`main()` computes `max_hidden_effect_pp` only when `degenerate` is true, and the CLI
report prints an explicit `DEGENERATE:` line rather than a clean-looking CI. Round 1
reported the bound at 10.0pp with n=30 pairs; round 2 reported 37.4pp with n=8. Both
numbers are honest precisely because they are wide — a tight-looking interval on
ties-everywhere data is the artifact to distrust.

**4. A paired design needs a paired test, or you throw away the pairing's power.**
`stats_paired.py`'s module docstring records why it does not reuse the repo's existing
(unpaired) Fisher's-exact helper from `scripts/shape-audit/ablation/stats.py`:
using it here would throw away the pairing and lose power. It ships McNemar's exact test
on discordant pairs instead:

```python
def mcnemar_exact(b, c):
    """Two-sided exact McNemar on discordant counts (binomial at p=0.5).

    b = first arm right / second wrong, c = the reverse. Concordant pairs carry
    no information about a difference and are correctly ignored.
    """
```

A planted test case in the instrument's own test suite demonstrates the concrete
difference: paired McNemar reaches p=0.031 on data where unpaired Fisher misses at
p>0.05. If your two arms answer the *same* set of tasks, pick the test that conditions
on that pairing — reaching for whatever statistical test already lives in the repo is
not a safe default.

**5. Making the eval hard enough to be informative can also make it accidentally easy to
game — check for that before trusting the "hard" numbers either.** Round 2's own
calibration run for its new "carryover" task family finished in 20 turns with 0 file
reads and 0 compactions, $0.22 total, because the agent grepped keyphrases and generated
plausible-looking summaries programmatically instead of doing the review the task was
supposed to force. Deterministic grading had implied scriptability, and scriptability
let the agent dodge the exact regime under test. The fix was not a harder task, but a
uniform constraint applied identically to every arm ("open and read each note file in
full with your file-reading tool... Do not grep, head, sed or script your way around
reading them", `scripts/rlm-bakeoff/gen_carryover.py`) — after which every arm
actually compacted 2-3 times per run, peak context 164k-184k tokens against a 200k
window, 60-87 file reads, 69-110 turns. When an eval reports a suspiciously cheap
"pass," check whether the model found a shortcut around the mechanism you meant to
exercise before you trust the harder numbers that come after the fix.

**6. Route a comparative-performance claim through a real refusal gate, and accept when
the gate cannot adjudicate your workload class instead of overriding it.** This repo
mandates `bin/ab-pair.sh` for paired perf claims — interleaved ABBA ordering,
`--metric`, a coefficient-of-variation refusal gate (`harness/evidence-regime.md`
§6). It was invoked three times across both rounds and refused all three: cost cv
5.31%/22.26% at an 86.4% median gap, latency cv 19.20%/26.38% at a 23.4% gap, turns cv
18.22%/11.13% at a 61.4% gap. The 5% cv gate is calibrated for microbenchmarks;
agent-run variance here is model stochasticity, and the gate's own remedy ("quiet the
host and re-run") has nothing to act on for that kind of noise. The honest response was
not to weaken the gate inline — a change to a gate never rides along in the PR it gates
— but to file a follow-up issue (#367) and mark the context-cost finding
**PROVISIONAL**, not landable. If your performance gate refuses your workload class,
that is information about the gate's domain of validity, not a bug to route around under
deadline pressure — and the write-up still owes you the honest caveat about which
invocation the gate's own remedy would have helped: the 23% latency gap under 19-26% cv
is genuinely not distinguishable from noise, and there the gate is simply doing its job.

**7. Fixing a misleading figure in the write-up once is not fixing it — check every
location it appears, and don't replace one cherry-pick with another.** Three separate
inward-vet passes over this workstream's write-ups each caught a different number that
did not reconcile with its own receipts: a quoted-but-uncommitted ab-pair receipt; a
"gaps of 61-87%" range that silently dropped the inconvenient 23% latency case (the
fixed version lists all three gaps individually instead of a range); a replacement "cv
floor 11-26%" claim that dropped the 5.31% low value on its way to being fixed (the
current text states the full six-value set without selection, noting the lowest is
within 0.31pp of *passing*); and a "34 baseline attempts" count that wrongly folded in
16 non-baseline runs and survived in a second location after being fixed in the first.
The write-up now states its baseline-attempt count with its arithmetic shown so the
reader can check it: 8 tournament + 10 calibration + 1 read-requirement probe = 19.
Treat every summary statistic in a results write-up as a claim to re-derive from the
receipts, not a number to trust because it was already corrected once — a corrected
figure that appears in two places is only actually fixed when both places agree.

## Why This Matters

An eval that cannot discriminate between "the mechanism helps" and "the mechanism does
nothing" is not neutral — it is actively dangerous, because a 100%-vs-100% tie is easy
to misreport as "no benefit" (a real finding) when the true state is "the eval never
exercised the failure mode" (no finding at all). Round 1 of this workstream nearly
shipped exactly that: it disclaimed compaction in its own No-Claim Boundary and then
treated the null as having settled the adoption question anyway. Left uncorrected, that
pattern produces a portfolio of "verified" negative results that are actually just
unfalsifiable ceiling effects, each one quietly foreclosing a genuinely useful mechanism
that a harder version of the same eval would have found value in.

The cost asymmetry is what makes the discipline worth the friction. The two rounds
described here cost roughly $120 combined and several hours of engineering time to
build the entry-criterion check, the inline mechanism-engagement instrumentation, the
degeneracy detector, and the paired test (a modest cost for round 1's 141 runs, roughly six times as much for
round 2's 36 runs). Skipping all of that and trusting round 1's headline number would
have cost nothing up front and produced a wrong decision — either declining a mechanism
that actually works, or (the more expensive failure mode) adopting one that measurably
harms the thing it claims to help, since round 2 found the kernel used **more** context
in 8 of 8 paired tasks (sign-test p=0.0078, ratios 1.12x-3.14x) for identical answers. A
cheap, well-intentioned "parse programmatically, don't read big files" doctrine line was
the plausible-looking alternative on the table, and it too measured as no-benefit and
directionally worse (431k vs 230k context tokens at the `xl` tier) — the discriminating
eval is what caught a regression that looked, on priors, like an obviously good idea.

The reusable asset is not the kernel verdict; it is the instrument. `stats_paired.py`'s
degeneracy flag and rule-of-three bound, `run_tournament.py`'s inline stream-json
mechanism-engagement capture and transcript-based compaction counting, and the
"difficulty is an entry criterion" discipline all transfer to the next "should we adopt
mechanism X" question this harness faces, regardless of what X is.

## When to Apply

- You are running an A/B (or A/B/C) comparison between agent-harness treatments —
  system-prompt rules, tool grants, delegation mechanisms, retrieval strategies — and the
  candidate task set is something you generated or chose yourself, rather than an
  external fixed benchmark.
- Your control/baseline arm might plausibly already solve the tasks at or near 100%
  before you've run a single comparison — i.e., you have not independently verified the
  baseline can fail on this task family with sealed, recomputed ground truth.
- The mechanism under test only matters under a specific triggering condition (context
  compaction, cache eviction, retry, cold start, concurrent access) and your task
  generator does not guarantee that condition is reached — check for it explicitly
  (transcript-level `compact_boundary` counting is the pattern here; the equivalent for
  your domain is whatever internal event the mechanism claims to help with).
- You are about to report a paired comparison (same tasks, multiple arms) — reach for a
  paired test (McNemar, paired bootstrap with degeneracy detection) rather than an
  unpaired one, and check whether an existing `stats.py` in your repo is unpaired before
  reusing it by default.
- You are about to write up a comparative performance number (cost, latency, tokens,
  turns) for agent or LLM-driven work — run it through a real refusal gate rather than
  eyeballing medians, and if the gate refuses, report PROVISIONAL / not-landable rather
  than overriding the gate inline in the same change that would benefit from a looser
  one.
- You are reviewing (or writing) the results write-up for any of the above and a summary
  statistic (a range, a "floor", a count) appears more than once — re-derive each
  occurrence from the receipts rather than trusting that fixing it in one place fixed it
  everywhere.
- You encounter another eval — anywhere in the fleet, any domain — reporting suspiciously
  saturated results (all green, zero discriminative power) with no evidence the
  contrasted conditions were ever actually distinguishable; treat that as a signal to
  redesign or retire the task, not to bank the tie as a finding.

## Examples

**1. Ceiling effect caught only by an escalation-and-instrumentation discipline, not by
inspection.** Round 1's pre-registered task family (`agg`, small/medium/large) returned
6/6 correct in calibration — obviously a ceiling — so before the measured matrix ran, the
design was amended to add a harder `chain` family and `xl`/`xxl` sizes. Even after five
escalations up to 400,000-row / 20 MB corpora, the measured matrix still went 90/90
across three arms. The lesson generalizes past this specific corpus size: escalating
difficulty is necessary but was not sufficient here, because the mechanism's actual
claim (survives context loss) was never exercised by any of the five escalations — the
real fix in round 2 was not "go bigger" but "force the specific condition (compaction)
the mechanism claims to help with."

**2. The eval's own generator asserting its planted negatives are actually
distinguishable from the true answer**, so silent grading failures can't hide behind an
unreachable target. `gen_carryover.py` raises at generation time if the true answer would
be indistinguishable from either failure mode it is trying to detect:

```python
if truth["answer"] == truth["decoy"]:
    raise AssertionError("constraint loss is undetectable: answer == decoy")
if truth["answer"] == truth["forgot_holds"]:
    raise AssertionError("hold loss is undetectable: answer == forgot_holds")
```

This is the generalizable pattern for "planted negatives" from
`harness/evidence-regime.md` §4: every task instance should assert, at
construction time, that a plausible wrong answer an arm could produce by failing in the
targeted way is numerically distinct from the correct answer — otherwise a grader that
accidentally accepts the wrong-but-close answer would never be caught.

**3. Graded (not binary) failure classification, because *how* an arm fails is the
diagnostic signal.** `run_tournament.py`'s `grade_carryover` returns six distinct
non-passing grades rather than a single pass/fail bit: `tag_lost` (prompt-borne
constraint forgotten), `hold_lost` (mid-run-discovered fact forgotten — the failure mode
the family exists to detect), `constraint_lost`, `decoy` (fell back to the corpus's own
written rules), `nofmt`, and `wrong`. A binary "did the answer match" comparison anywhere in this pipeline would have
collapsed all of these into one undifferentiated failure category and made the "which
specific piece of state got lost" analysis impossible.

**4. A mechanism given every opportunity to fire and simply not firing — scored as VOID,
not as a loss.** `R_retained` (the delegation arm) was told exactly how to spawn a
persistent background specialist and reattach to it, and did so in 0 of 8 tournament
runs. Per the pre-registered taxonomy this is scored `VOID` rather than `NEGATIVE`: no
evidence either way about delegation's performance, because the treatment never
happened. The taxonomy definition in `harness/evidence-regime.md` §5 is explicit —
the measurement could not have detected the thing; not a rejection, re-run. Confusing a
mechanism that never engaged with a mechanism that engaged and lost is exactly the kind
of degenerate-tie mistake this whole methodology note exists to prevent, just at the
level of a single arm instead of the whole eval.

**5. The mechanistic explanation, found by reading raw logs rather than trusting the
aggregate.** Rather than stopping at "baseline ties the kernel," round 2 read all 8
baseline transcripts and found the baseline arm was, unprompted, writing the exact kind
of durable external state the kernel was supposed to provide — one run's own Python
heredoc comments annotate its two evidence sources inline: `# investigation` and
`# settlement hold vendors from notes` (excerpts committed at
`scripts/rlm-bakeoff/results/baseline-externalization-excerpts.txt`). This is the
difference between a null result ("no measurable difference") and a mechanistic finding
("no measurable difference, and here is why: the baseline already does the thing the
treatment claims to add") — the latter is what makes the do-not-retry condition in the
ADR falsifiable ("the subject model changes to one that does not spontaneously write
state to files when handed a filesystem") instead of a permanent, untestable verdict.

## Related

- `harness/rlm-external-state-decision.md` — the ADR this methodology produced
  (the adoption verdict itself; cite that, not this, for "should we adopt a persistent
  kernel").
- `harness/evidence-regime.md` — the doctrine this note operationalizes: the
  closed negative-evidence taxonomy (`VOID` / `NO_EVIDENCE` / `PROVISIONAL`), planted
  negatives, No-Claim Boundary, and the `ab-pair.sh` mandate.
- `scripts/rlm-bakeoff/RESULTS.md` and `RESULTS-TOURNAMENT.md` — primary evidence
  and per-run receipts for every number cited above.
- `scripts/rlm-bakeoff/` — the reusable instrument (`stats_paired.py`,
  `run_tournament.py`, `gen_carryover.py`, `gen_corpus.py`). Every `rlm-bakeoff` path in
  this note left the tree after its decision closed; read one with
  `git show 070682e5:<path>`, or restore a directory with `git checkout 070682e5 -- <dir>`.
- Issue #367 — `ab-pair.sh`'s cv gate is unreachable for agent-workload comparisons;
  settling the PROVISIONAL context-cost finding depends on it.
- Machine-local memory note `premise-integrity-saturated-zero-discrimination` (a private evals repository's
  project store) — an independent, same-day instance of the saturation failure class
  from an unrelated cause.
