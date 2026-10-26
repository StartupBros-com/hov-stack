---
title: "Stop an adversarial review loop on measured prevalence, not on waiting for a CLEAN round"
date: "2026-09-23"
category: best-practices
module: adversarial-review-loop-stopping-rule
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "Running repeated adversarial/refute-by-default review rounds on a guard, hook, or other gating mechanism, and a DIRTY round's fix keeps exposing a new, more structural finding class"
  - "Deciding whether to run another review round or to freeze and ship a guard/hook PR that still has open findings"
  - "A finding is about a heuristic or advisory (warn-only, not enforced) component rather than a hard blocking gate"
  - "About to accept a fix's regression test as proof a finding is closed"
tags:
  - adversarial-review
  - review-loop-convergence
  - measured-prevalence
  - warn-only-vs-blocking
  - process-porn
  - ceremony
  - regression-test-red-first
---

# Stop an adversarial review loop on measured prevalence, not on waiting for a CLEAN round

> **Retired machinery (2026-10-18).** The default review ladder was retired
> by #1862: a PR now gets at most one `/pro-gate` review, only for billing,
> auth, migrations or CI diffs, and `/review-adversarial-first` runs only
> when the operator names it (`CLAUDE.md`, "Merge-and-end"). The
> skill, `review-rounds.py` and `red-first.sh` still exist, so what follows
> about rounds, freezes and the automatic red-first check applies to an
> operator-named run. The stopping rule holds for any multi-round
> adversarial review.

## Context

The first production use of a refute-by-default adversarial review lens
(dotfiles issue #1285, its live run described in this repo's own review
tooling as the "adversarial-first ladder") ran across five guard/hook PRs on
2026-09-21 and 2026-09-22. The initial working assumption was that review
rounds would converge: fix what a DIRTY round finds, run another round, and
eventually reach CLEAN. That assumption did not hold. Three of the five PRs
(a fan-out admission hook, a shape-rewrite PreToolUse hook, and a claude-loop
resume denylist) were still DIRTY at round 7 and round 8, each with at least
one unrefuted P1. Each round's fix did not converge the PR; it exposed the
next, usually more structural, finding class in the same code — a
single-match regex became an every-match loop, an exact-verb match became a
basename-normalization gap, leaf sanitizing became a nonce-delimited
containment problem. A static analyzer over arbitrary JavaScript, or any
heuristic reviewing an adversarially-shaped input space, does not run out of
edge cases on its own; a round that finds one will always be followed by a
round that finds the next.

On 2026-09-22 the operator interrupted a 17-commit review→fix loop on the
fan-out admission hook and asked whether the work had become "process porn
and ceremony." The measurements that should have triggered the stop earlier,
once actually taken: the hook was warn-only (no host armed it as a blocking
gate); on a real sample of 3,345 scripts it already warned on 39% for the
class of finding under discussion; the redesign under discussion would have
changed at most 0.9% of scripts; and the review pipeline's own convergence
signal had already reported "rounds not converging." The same shape repeated
on two more PRs the same day: over 30 days and 580,412 real Bash invocations
(a second, independent session reproduced the count), each additional bypass
shape chased in a later round occurred at most 16 times in 30 days, and most
of those hits were the review's own repro scripts and fixtures rather than
organic traffic (see the companion lesson on self-referential transcript
corpora, filed separately in this directory). One PR had zero real escapes
among 300 newly rewritable commands; another PR's round-2 fix denied the
operator's own routine command idiom on about 11% of realistic invocations
while covering only one of the three fields it was meant to protect — an
over-denial cost nobody had measured until asked.

A separate, sharper defect surfaced inside the same rounds: three times on
one PR, a round closed a finding by adding a regression test that could not
structurally reach the code path the finding described (a test for the
nested-shape variant of a bug whose flat-shape variant was the one still
broken; a timing test with zero `const` bindings that never reached the
function under test; added scanning breadth with no lexical-scope awareness).
Each of those tests passed in CI and looked like proof, and each time the
next round found the same underlying defect still live. That is documented
as its own, narrower lesson (see Related) because it recurs independently of
the stopping-rule question this doc is about.

## Guidance

1. **Do not budget "a few rounds" for a guard/hook/gating-mechanism review;
   budget until a stopping condition is met.** A refute-by-default lens over
   an adversarial input space earns its keep — it substantially out-produces
   a single topic-focused reviewer pass — but "the lens found something" is
   not itself a signal to keep going or to stop; only measurement is.

2. **Before paying for another round, measure two things over the real
   corpus, not the synthetic test suite:** (a) the finding's prevalence — how
   often the specific bypass, edge case, or defect shape actually occurs in
   real traffic, not in a crafted adversarial probe; and (b) what the
   finding's component actually gates — is it enforced (a blocking check that
   denies an action) or advisory (a warning, a disclosed limit, a metric
   nobody acts on)? A warn-only component with near-zero real prevalence for
   the remaining finding class is a stop signal even with open findings.

3. **For a warn-only or advisory component, stop when prevalence is near
   zero (a low single-digit percent of real inputs, or fewer than roughly a
   dozen occurrences across a multi-week sample) and disclose the
   residual.** "Freeze and ship" means: fix what is already cheap and clearly
   right, write the remaining finding classes and their measured prevalence
   into the change's own disclosure/limitations section, and stop the loop.
   This is not skipping review — it is treating the measurement, not another
   round, as the terminal signal. **An enforced gate is different:** a known,
   unrefuted bypass of a control that denies actions is not frozen on low
   prevalence alone. Fix it, narrow the gate to what it can actually enforce,
   or downgrade it to warn-only and disclose the gap before shipping.

4. **Do not treat a green suite after a DIRTY-round fix as evidence the area
   is clean.** The suite was green before every one of the DIRTY rounds too.
   A fix's own regression test must be checked, not trusted: run it against
   the pre-fix revision and confirm it fails there. A test that was never red
   proves nothing about whether the fix closed the finding (see the
   cross-linked lesson below for three concrete ways a regression test
   structurally missed its own finding's path). When the operator
   names `/review-adversarial-first` (it is no longer a default step), it
   runs this check automatically from a PR's second recorded round; the
   cross-linked lesson lists what it does not catch. Otherwise run the
   check by hand.

5. **Re-verify a fixer's own numbers before accepting a round as closed.**
   On one PR a pre-fix baseline measurement was found to be slightly worse
   than what the fixer reported; on another, an initial misattribution of a
   regression to the wrong author was disproved on re-reading. Cross-model
   review (a different model family reviewing the same diff) caught real P1s
   the in-process lens rounds missed on at least one of these PRs — it is not
   redundant with the same-model ladder.

### The adversarial tier now freezes itself (2026-09-27)

Since dotfiles #1390, `/review-adversarial-first` records each PR round in a
PR-comment ledger (`scripts/review-rounds.py`). It returns **FROZEN**
when, for two consecutive scored rounds, live P1+P2 stays positive and
neither that count nor the diff size falls (`harness/evidence-regime.md`
§8).
- **What FROZEN does:** it names the residual P1/P2 classes and the round
  table, and it stops further adversarial rounds. The higher review tiers
  still run.
- **How it relates to this doc:** FROZEN is the "rounds not converging"
  signal this doc treats as a stop. The prevalence measurement above still
  decides what happens next: ship with the residual disclosed, or have the
  operator authorize one more round with `continue_past_freeze`.
- **Calibration:** the streak-2 threshold was not calibrated against the
  2026-09-21/22 histories, because their saved returns pin no reviewed
  heads. The only live freeze so far, #1390's fourth round, drew half its
  live P1+P2 from never-red flags on test edits that were not regression
  tests.

## Why This Matters

An adversarial review loop that only ever escalates ("find something, fix it,
review again") has no natural end state for a component whose input space is
adversarial by construction (arbitrary shell commands, arbitrary JS a hook
must parse, an operator's own routine command idioms that look like the thing
being denied). Treating "found nothing this round" as the only valid stop
condition means the loop runs until someone interrupts it, and by then it has
often produced ceremony — commits, tests, and review rounds — with no
user-visible change in shipped behavior. Worse, the later rounds in these
five PRs hardened against inputs that occurred at most 16 times in 30 days of
real traffic, while the over-denial cost of the "fix" (denying an operator's
routine idiom on ~11% of real commands, in one case) went unmeasured until
asked. Measuring prevalence and gate-strength turns "when do we stop" from a
judgment call made under review fatigue into a number anyone can check.

## When to Apply

- Any multi-round adversarial or refute-by-default review on a guard, hook,
  denylist, or other gating mechanism where round N's fix is expected to
  create round N+1's finding. The stop-with-open-findings rule covers
  warn-only components; for an enforced gate, apply the limit in guidance
  point 3.
- Before declining to run another round too: if the governor or convergence
  signal reports "not converging," or a finding's component is warn-only and
  already at meaningful real-world coverage, that is itself the measurement
  that ends the loop — it does not require running one more round first to
  confirm.
- Not a license to skip review altogether, and not a substitute for fixing a
  finding that is cheap, clearly correct, and does not require further
  investigation — "freeze and ship" fixes what is already known-good and
  measures the rest, it does not skip the known-good fixes.

## Examples

**Converged only after measurement, not after a clean round (PR touching a
fan-out admission hook):** 17 commits of review→fix rounds, interrupted at
the operator's question. Measured: warn-only, already at 39% real-corpus
warning coverage for the finding class in play, the proposed redesign would
touch at most 0.9% of scripts, and the review pipeline itself reported
rounds not converging. Frozen and shipped with the residual finding classes
disclosed, rather than continuing to a round that never came back clean
through round 8+.

**Real prevalence near zero despite "found something" every round (a
shape-rewrite PreToolUse hook and a claude-loop resume denylist):** across
580,412 real Bash invocations over 30 days, each additional bypass shape
chased in a later round occurred at most 16 times, and most of those hits
were the review's own repro artifacts rather than organic traffic. One PR had
zero real escapes among 300 newly rewritable commands.

**Unmeasured over-denial cost surfaced only on asking (the resume
denylist):** a round-2 fix aimed at a "disguised git push" bypass denied the
operator's own routine `git -C … push` idiom, matching about 11% of
realistic commands, while covering only one of the three fields the finding
said it needed to protect.

## Related

- [A regression test can structurally miss the path its own finding described — run it red first](regression-test-must-structurally-reach-the-path-its-finding-described.md)
  — cross-linked, not folded in: three concrete cases from the same review
  wave (a nested-shape test for a flat-shape bug, a timing test with zero
  `const` bindings that never reached the function under test, and added
  scanning breadth with no lexical-scope awareness). Filed separately so the
  two lessons — when to stop, and how to tell a regression test actually
  proves closure — stay independently discoverable.
- [A shape detector run over the whole transcript corpus counts the review that measured it](transcript-corpus-detectors-count-the-review-itself.md)
  — the measurement technique this lesson depends on (real-corpus prevalence
  counts) is itself vulnerable to counting the review's own artifacts; hand-read
  a sample before trusting a "16 times in 30 days" style prevalence number.
- dotfiles issue #1285 — the adversarial-first review ladder this lesson's
  evidence was measured against.
