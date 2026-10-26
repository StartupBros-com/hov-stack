---
title: "A fail-closed selector that falls back silently looks exactly like a selected run"
date: "2026-10-05"
category: logic-errors
module: ci-suite-scope
problem_type: logic_error
component: testing_framework
symptoms:
  - "A CI scope job reports 176 run / 0 skip on a two-file PR and nothing in the log says which file forced that"
  - "The PR's Harness Tests runs take the full 30 minutes on every push for its whole life; the checks UI is green and identical to a scoped run"
  - "A local dry-run of the same diff prints `selected: 176 suite(s)` for two changed paths with no reason"
  - "The unregistered paths are the selector's own new runner script and its test, added by the same PR that was testing the selector"
root_cause: logic_error
resolution_type: code_fix
severity: medium
related_components:
  - "scripts/ci-suite-scope.py"
  - "scripts/run-affected-suites.py"
  - "tests/suite-paths.yml"
  - ".github/workflows/harness-tests.yml"
  - "dotfiles#1587"
  - "dotfiles#1283"
tags:
  - fail-closed
  - silent-fallback
  - test-impact-analysis
  - suite-selection
  - ci-scope
  - manifest-gap
  - green-check-states-what-it-covered
---

# A fail-closed selector that falls back silently looks exactly like a selected run

## Context

`scripts/ci-suite-scope.py` decides, per suite, whether a PR's changed
files require it to run, from the manifest `tests/suite-paths.yml`
(dotfiles#1283). Its second rule is fail-closed by design: a changed path
that no specific manifest entry claims, and that is not listed inert, makes
every suite run, because an unmapped path is a manifest gap and not a reason
to skip. That rule is correct and stays.

PR #1587 added a local runner that consumes the same scope decision so a
session can run the affected suites before pushing. The runner's own two
files, `scripts/run-affected-suites.py` and its test, had no manifest
entry. Every push of that PR therefore matched no specific entry, fell
through to "every suite runs", and ran all 176 suites on CI for the PR's
whole life. The checks stayed green. A review round even declined to add a
manifest key on the grounds that the python discovery entry "already covers
`scripts`", which was wrong: that entry is a bare prefix plus a
`tests/test_*.py` glob, and rule 2 deliberately does not let a bare
prefix count as coverage.

The gap was found only because the runner printed a count: a dry-run of the
two-path diff said `selected: 176 suite(s)`. Nothing on CI had said it. The
scope job's `decide()` returned the all-run dictionary from inside the loop
and dropped the path that caused it, so the step log, the step summary and
the payload all looked identical to a PR that legitimately needed every
suite.

## Problem

A fail-closed fallback has two outputs that look the same from the outside:
"every suite ran because this change needs every suite" and "every suite ran
because the selector could not account for a path". The second is a defect
in the manifest, fixable in one line, and it costs the full run on every push
until someone notices. When the selector does not name the path, nobody
notices, because the failure mode is a green check that took longer. The
long runs get attributed to the queue, the runners, or the suites, and the
manifest gap compounds: the review that declined the manifest key reasoned
from the wrong rule because the log gave it nothing to reason from.

## Solution

`decide_with_reason()` returns the decisions plus the reason when every suite
runs, naming the path or paths that forced it (bounded to eight, then "and N
more"), for both fall-back rules:

- `trust boundary: <paths> (a workflow, a ci-* script, or
  tests/suite-paths.yml itself changed)`
- `manifest gap: <paths> matches no specific entry in
  tests/suite-paths.yml and is not listed inert; add it under the
  suite(s) that read it, or under inert`

`decide()` stays as a wrapper returning the decisions alone, so the proof
replay and the existing tests are untouched. The reason travels three ways,
because the scope job captures stdout as the payload and nothing else:

1. stderr, as `::warning title=suite scope::every suite runs: ...` under
   GitHub Actions (an annotation on the run) and as `scope: every suite
   runs: ...` locally;
2. a `reason` key in the payload, which `--summarize` appends to the one-line
   narration that already lands in the step log and `$GITHUB_STEP_SUMMARY`;
3. the local runner's first line: `changed: 2 path(s); relevant: yes;
   selected: 176 suite(s); every suite runs: manifest gap: ...`.

A selected run and `--run-all` carry no reason and print nothing extra, so
the common case is byte-identical to before. Tests cover each rule's reason,
the path bound, the narration, the stderr and payload paths with and without
`GITHUB_ACTIONS`, and the runner's dry-run line.

## Guidance

1. **When a selector, gate or scoper has a fail-closed branch, make the
   branch name its input.** The decision alone is not evidence; the same
   all-run dictionary means two different things. Return the reason with the
   decision and print it where a reader of the normal output will see it.
2. **Register a new script and its test in the same commit that adds them,
   and read the rule before declining.** Rule 2 says a bare prefix does not
   account for a path; "the discovery entry covers it" is exactly the claim
   the rule was written to reject (PR #1300's finding 2/5, in the module
   docstring).
3. **Treat a run that selected everything as a question, not a result.**
   The scope summary now says why. If it says manifest gap, the fix is one
   manifest line and it is cheaper than the next full run.
4. **A green check that states what it covered is the standard this repo
   already set** for the `relevant=false` branch (PR #1300 round 2, finding
   4/6). The fall-back branch had the same obligation and did not meet it.

## Related

- `docs/solutions/logic-errors/fail-closed-gate-on-monotonically-degrading-input-becomes-a-permanent-latch.md`:
  the sibling failure, where fail-closed latches instead of staying silent.
- `scripts/ci-suite-scope.py` module docstring: the three rules and
  why a bare prefix never counts for another suite's dependency.
- dotfiles#1587 round 4 PR body, "Correction to round 2": the review that
  declined the manifest key, and the dry-run count that exposed the gap.
- dotfiles#1567 round-5 ideation, idea 3: the local affected-suites runner.
