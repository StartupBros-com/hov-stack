---
title: "Make a test assertion falsifiable by the defect it guards, not just green"
date: "2026-09-04"
category: best-practices
module: pro-gate-brief-hardening
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "A test asserts a count of container-level artifacts (files, records, rows) as a proxy for the value that actually changes (lines, fields, timestamps inside those artifacts)"
  - "A guard test for a new refusal branch asserts only the exit code, and other refusal branches already share that code"
  - "A new validation check is being inserted earlier in an argument-parsing order than existing checks the test fixtures already exercise"
  - "Reviewing a green test suite before trusting it as evidence a specific defect cannot recur"
related_components:
  - "pro-gate-engine"
  - "pro-gate-round-accounting"
tags:
  - vacuous-assertion
  - falsifiable
  - test-design
  - shared-exit-code
  - round-accounting
  - pro-gate
  - bash-tests
  - verification

---

# Make a test assertion falsifiable by the defect it guards, not just green

## Context

pro-gate PR #137 shipped `--brief` (a caller-supplied task body substituted
for the engine's default reviewer persona) with a green test suite, verified
against a stub oracle. A live Pro slot spent against the change itself (#139,
closing #138) returned `FIX-FIRST` with three design findings, and fixing
them also surfaced two pre-existing test defects in the same file — one in
the round-accounting assertion `#137` had shipped, one in the guard tests for
`--brief`'s exit-2 refusal paths. Both defects were invisible in a green
run; both were caught only by reasoning about what each assertion actually
measured, not by re-running the suite.

**Trap 1 — measuring the container instead of the content.** `#137`'s round
test asserted that a `--brief` run "spends a round" by checking for the
presence of one file in the rounds directory. But a round is not a file: it
is an appended epoch line inside a per-key file. `pg_round_record`
(`pro-gate lib/pro-gate-lib.sh:1881`) prunes stale entries out of `$dir/$key` and
appends `now`; `pg_round_count` (`pro-gate lib/pro-gate-lib.sh:1868`) counts lines in
that same file within the rolling window. Because an earlier test in the same
`PRO_GATE_HOME` had already created that key's file, the file-existence
assertion was invariant whether or not the new charge landed — it would have
passed identically had the round genuinely not been charged. The fix (PR
#139) counts lines across the rounds directory before and after
(`pro-gate tests/engine.test.sh:2072`, `:2099`-`:2101`), so the check now fails if the
charge disappears.

**Trap 2 — asserting the exit code where several paths share it.** The
original `--brief` guard tests (`--brief /nonexistent-brief.md`, an empty
brief file, an oversized brief file) asserted only `rc -eq 2`. #139 added a
new, earlier-firing refusal: `--brief` combined with `--pr` is now rejected
at `pro-gate bin/oracle-review.sh:194`-`195`, before the file-existence and
size checks that follow it. The pre-existing guard fixtures happened to pass
`--pr 102` alongside `--brief`, so after the hardening those tests would
still exit 2 — but from the new `--pr` refusal, never reaching the
file-not-found or empty-file branches they were written to guard. The fix
makes each guard assert its own distinct stderr message
(`pro-gate tests/engine.test.sh:2107`-`2113`, e.g. `grep -qF 'brief file not found'`),
so a wrong-branch pass is no longer possible even if a fixture is
mis-specified.

## Guidance

### Ask what would have to change for the assertion to fail

Before trusting a green assertion as evidence against a specific defect,
name the defect and check whether the assertion's actual failure condition
overlaps it. If the honest answer is "nothing I care about could make this
fail," the assertion is vacuous regardless of what it currently reads.

- Trap 1's assertion could only fail if the *file* were missing, never if the
  *round* were missing — the two came apart the moment a sibling test shared
  the same home directory and key.
- Trap 2's assertion could only fail if the process exited 0, never if it
  exited 2 for the wrong reason — the two came apart the moment a second
  exit-2 branch was inserted earlier in validation order.

### Count the quantity that actually mutates, not its container

When a test's job is "prove N grew by one," count the thing the code under
test increments, not a file-or-record-level proxy for it. A per-key file
that accumulates appended lines needs a line count across the whole
directory (`cat "$RHOME"/rounds/* | wc -l`), taken before and after, not a
file-existence check — file existence is a one-time event that a prior test
run can already have satisfied.

### When several usage-error paths share one exit code, assert the message

A CLI with more than one `exit 2` usage-error path cannot be distinguished
by return code alone. Once a second refusal is added anywhere earlier in the
validation order than an existing guard's target branch, every existing
`rc -eq 2`-only assertion downstream of the new branch silently starts
passing for the wrong reason. Assert the specific stderr text
(`grep -qF '<this guard's own message>' "$TDIR/stderr"`) so each guard proves
it reached its own branch, not merely that the process refused to run.

## Why This Matters

Both traps produce the same outcome — a suite that reports green while the
specific regression it was written to catch could recur undetected — and
both are structurally invisible from outside the assertion: `check 'name'
"$rc"` output looks identical whether the assertion is falsifiable or not.
Trap 1 was only caught because the round was genuinely charged and a
human traced *why* the before/after counts (`before=29 after=29`) hadn't
moved, rather than accepting the numbers at face value. Trap 2 would have
shipped a hardening commit that silently broke test coverage for three
pre-existing guards at the same moment it added a fourth. On pro-gate
specifically, that risk is not abstract: these are the exit-2 usage-error
paths of the merge-gate engine itself, and a broken guard test means the
next regression in that engine ships past the suite that exists to catch it.

## When to Apply

- Writing a test that asserts a count against a shared/rolling-window store
  (any store other tests may also have touched): count the mutating unit
  (line, record, timestamp) across the whole store, not presence/absence of
  a container the store happens to key by.
- Adding a new `exit 2` (or any shared-code) refusal ahead of existing
  guard tests in validation order: re-audit every existing test whose
  fixture could now trip the new branch first, and convert `rc`-only
  assertions for that shared code to message-specific ones.
- Reviewing someone else's green test before relying on it as proof a fix
  works: pick the specific defect it claims to guard, and check whether the
  assertion's failure condition is that defect or something merely
  correlated with it.

## Related

- [verify-loop-breaking-remedies-by-counting-repeats-not-occurrences](verify-loop-breaking-remedies-by-counting-repeats-not-occurrences.md) —
  a distinct "count the right thing" lesson in a different domain: it is
  about papercut's post-closure regression verdict counting occurrences vs.
  repeats, not about test-assertion design. Read in full; kept separate
  because the mechanism, subsystem, and failure mode differ (records
  double-counted as regressions vs. test assertions structurally unable to
  fail).
- [enable-consent-gated-daemons-with-two-keys-not-one](enable-consent-gated-daemons-with-two-keys-not-one.md) —
  another pro-gate runtime learning from the same period, unrelated
  mechanism (consent-record gating vs. test-assertion design).
- pro-gate PR #139 ("fix: harden --brief after a live pre-release run
  returned FIX-FIRST", closing #138) is the source commit for both traps and
  their fixes, on top of PR #137 ("feat: --brief, a custom task body for
  the Pro slot") which introduced the original defects.

