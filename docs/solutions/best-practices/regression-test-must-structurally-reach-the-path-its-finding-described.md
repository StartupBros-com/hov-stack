---
title: "A regression test can structurally miss the path its own finding described — run it red first"
date: "2026-09-23"
category: best-practices
module: adversarial-review-regression-fixture-scope
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "Accepting a fix for an adversarial-review or bug-report finding as closed because its new regression test passes"
  - "A fix's test fixture uses a shape (nested vs. flat, a specific variable-binding form, a narrow input) that differs from the shape the original finding described"
  - "Scanning breadth was added to a fix (more call sites, more patterns matched) without also checking whether the new matches share the same scope as the ones already handled"
  - "A prior round's fix is being reused as the reference implementation for a new, similar-looking finding"
tags:
  - regression-test
  - red-first
  - falsifiable-assertion
  - fixture-shape
  - lexical-scope
  - adversarial-review
  - testing-conformance
---

# A regression test can structurally miss the path its own finding described — run it red first

> **Retired machinery (2026-10-18).** The default review ladder was retired
> by #1862, so `/review-adversarial-first` and its automatic red/green check
> run only when the operator names the skill (`CLAUDE.md`,
> "Merge-and-end"). `red-first.sh` and `evidence-regime.md` still exist and
> resolve. By default the manual check below is the only red-first check;
> the lesson itself is unchanged.

## Context

Across one PR's adversarial-review loop (a fan-out admission hook, dotfiles
issue/PR #1294, part of the same 2026-09-21/22 review wave documented in this
directory's stopping-rule lesson), a round closing a finding with a green
regression test failed to actually close it three separate times, and each
time the next review round found the same underlying defect still live in
the shipped code.

1. **Round 5** fixed a quadratic-time path and added a regression test that
   exercised only the *nested*-script call shape. The *flat*-script shape —
   syntactically different, same underlying quadratic behavior — was left
   unfixed, and stayed quadratic. Round 7 found it, because the round-5 test
   could not have failed on it: the flat shape never reached the code the
   nested-shape test exercised.

2. **Round 8** fixed the flat-shape variant round 7 found, and added a
   regression test for it — but that new test's fixture contained zero
   `const` bindings and zero nested function calls, so it never reached
   `isVerifierCall()`, the function where a fourth quadratic path actually
   lived. The test was green because it never executed the code path it was
   meant to guard, not because the path was fixed. Round 8's own review
   found this fourth path.

3. **The same round** also fixed a cap-resolution defect by adding scanning
   *breadth* — a function to find all declaration positions across a file,
   rather than the first one — without adding lexical-scope awareness. The
   same unsoundness the fix was meant to close survived intact under a
   function-scoped shadow of the same identifier, because "more matches"
   is not "the right matches": broadening a search's breadth changes how
   much it scans, not whether it scans the correct scope.

In every case, the regression test suite reported green, and reading only
the diff's test-pass/test-fail summary gave no signal that anything was
wrong. Each defect was only caught because a subsequent adversarial review
round independently re-derived the finding and traced why the "fixed" code
still misbehaved on a variant input.

## Guidance

**Before accepting any regression test as proof a finding is closed, run it
against the pre-fix revision and require it to fail there.** A test that
was never observed to fail (never red) proves nothing about whether the fix
actually addresses the defect — it may simply never execute the code path
in question, on either revision. Concretely:

```
git show HEAD~1:path/to/file.js > /tmp/<unique-dir>/pre-fix-file.js   # or: check out the pre-fix commit
# run the new test against the pre-fix source, confirm it FAILS
# restore the fixed source, run the new test again, confirm it PASSES
```

Beyond the red/green check itself, verify the test's *shape* actually
matches the finding's shape:

1. **Match every shape the finding covers, not just one.** If a finding
   describes a bug present in both a nested and a flat form of the same
   construct (or any other "this pattern in two syntactic shapes" finding),
   the regression test needs a case for each shape the finding named, not
   only the one that happens to be easiest to reproduce.

2. **Trace the fixture through to the exact function the fix changed.** A
   timing- or path-based regression test needs, at minimum, one case whose
   structure (variable bindings, call nesting, argument shape) is
   sufficient to reach every function the fix touches. If the fix changed
   `isVerifierCall()`, the fixture needs a `const` binding and a nested call
   if that is what `isVerifierCall()` requires to trigger — read the
   function's own entry condition, don't infer it from the finding's prose.

3. **When a fix adds scanning breadth, add scope awareness in the same
   change, and test both.** A fix that goes from "match the first
   occurrence" to "match every occurrence" needs a test case where two
   occurrences share a name but live in different lexical scopes (e.g. a
   function-local shadow of an outer identifier), because breadth without
   scope will happily match the wrong one once there is more than one to
   choose from.

4. **When reusing a prior round's fix as a template for a new finding,
   re-derive the fixture from the new finding's own description, not from
   the old fixture with names swapped.** Two of the three misses above were
   variations on an earlier fix; carrying the earlier fixture's shape
   forward is exactly how a nested-only test or a no-`const` timing test
   gets written without anyone noticing it never reaches the target
   function.

### Where the red/green check now runs automatically (2026-09-27)

Since dotfiles #1373 and #1390, when the operator names it,
`/review-adversarial-first` runs the red/green check itself on PR review
rounds. `scripts/red-first.sh`
runs each added or changed test case twice: on the effective pre-fix source
with the head's test files overlaid, then at the reviewed head. A case that
passes on both runs is reported **never-red**, a P1 that keeps its finding
open (`harness/evidence-regime.md` §4).

Three limits keep the rest of this doc manual:

- **It catches only never-red tests.** Of the three #1294 misses above, only
  the round-8 timing test was never-red. The other two tests were red before
  their fix and still covered only one shape, and `evidence-regime.md` §8
  states those are outside this gate. Points 1-4 above stay the reviewer's
  job.
- **It proves that the case failed before the fix, not why.** A test that is
  red for an unrelated reason passes.
- **It runs only from a PR's second recorded round onward.** The first round
  reports `red_first.status: not-applicable`, and branch or path targets run
  no ledger and no RED check. Anywhere else, run the snippet above by hand.

A test edit that is not a regression test, such as a fixture realignment or
a positive control, also reads as never-red: it passes on both revisions by
construction. Add a `Red-first-exempt: <path> -- <reason>` trailer to a
commit in the PR, which lowers the flag to a visible P3. On #1390's own
fourth review round, 5 of the 10 live P1+P2 findings that froze the loop
were exactly such unexempted edits.

## Why This Matters

A green CI run is the strongest-looking signal a fix works, and it is also
completely silent about whether the test it ran could ever have failed. All
three misses here produced identical-looking `PASS` output whether the
underlying defect was fixed or not, because the test simply never touched
the code path where the defect lived. Trusting "tests pass" as proof of
closure, without checking that the test is falsifiable by the specific
defect, lets the same class of bug ship past the exact review process built
to catch it — three times in one PR, each one caught only because a
subsequent, independent review round re-derived the finding from scratch.
That is expensive in review rounds and erodes trust in "closed" findings
generally: a finding marked closed on the strength of a test that was never
proven red is not actually verified closed.

## When to Apply

- Any time a review round or bug fix ships with a new regression test, before
  marking the finding closed — run the new test against the pre-fix revision
  and confirm it fails there. An operator-named `/review-adversarial-first`
  does this automatically from a PR's second recorded round; by default and
  everywhere else, do it by hand.
- Especially when the finding describes a pattern with multiple syntactic
  shapes (nested/flat, single/multiple, shadowed/unshadowed) — check the test
  covers every shape named, not the one shape that was easiest to write a
  fixture for.
- Especially when a fix widens a search from "first match" to "every match" —
  add and test lexical-scope discrimination in the same change, not as a
  follow-up.
- Not a requirement to re-litigate a fixture that is already known to have
  been red pre-fix and green post-fix on the exact shape the finding
  described — the check is about verifying that trace, not about writing
  more tests than a finding needs.

## Examples

**Shape mismatch (round 5 → round 7):** finding described a quadratic-time
bug present in both nested- and flat-script call forms. The round-5 fix's
regression test covered only the nested form. Running that same test against
the flat-form pre-fix code would have shown it passing regardless of whether
the flat-form bug was fixed — the test could never distinguish the two,
because it never exercised the flat-form code path at all. Round 7 rediscovered
the flat-form bug independently.

**Entry-condition mismatch (round 8):** the fix targeted `isVerifierCall()`,
which requires a `const` binding and a nested call to trigger. The new
timing-regression fixture contained neither. Run against either the pre-fix
or post-fix revision, the test never entered `isVerifierCall()`, so it was
green on both — a test that cannot go red on the pre-fix revision proves
nothing about the fix.

**Breadth without scope (round 8, same PR):** the fix for cap resolution
added a function scanning every declaration position in a file. No test case
put two same-named declarations in different lexical scopes, so the fix's
"same unsoundness survives under a function-scoped shadow" defect shipped
undetected until the next round found it independently.

## Related

- Cross-link (kept separate — related failure mode, different root cause):
  [Make a test assertion falsifiable by the defect it guards, not just green](make-test-assertions-falsifiable-by-the-defect-they-guard.md).
  That lesson is about an assertion whose failure condition never overlapped
  the defect at all (counting a container instead of its content, or a
  shared exit code masking which branch actually fired) — the test executes
  the right code but asserts the wrong thing. This lesson is about a test
  whose fixture never reaches the changed code path in the first place — the
  assertion would be fine if the code under test ever ran. Both produce the
  same visible symptom (green suite, defect still live) from different
  causes; check for both when auditing a "closed" finding's test.
- [Stop an adversarial review loop on measured prevalence, not on waiting for a CLEAN round](stop-adversarial-review-loops-on-measured-prevalence-not-a-clean-round.md)
  — the broader lesson from the same review wave: this doc is the sharper,
  narrower finding about *why* a "clean round" signal is unreliable (a green
  regression test does not mean the finding closed), which is part of why
  waiting for CLEAN is the wrong stopping condition in the first place.
- dotfiles issue/PR #1294 — the fan-out admission hook PR where all three
  misses occurred.
