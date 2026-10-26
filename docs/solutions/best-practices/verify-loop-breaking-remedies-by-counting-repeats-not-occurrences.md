---
title: "Verify a loop-breaking remedy by counting repeats and naming the shapes it covers"
date: 2026-09-03
category: best-practices
module: papercut-loop-remedy-verification
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A shipped remedy breaks a RETRY loop (a guard that denies the second attempt, a hook that rewrites the retry) rather than preventing the first failure"
  - "Verification reads post-closure records of the same signature to decide whether the fix regressed"
  - "The remedy covers one class of shape-coded targets while the signature fires on every shape"
  - "A closed family reads regressed on a single, non-repeating post-fix occurrence"
symptoms:
  - "A family reads regressed on first failures alone, and can never reach verifying while its remedy works"
  - "A family reads regressed on a genuine retry loop whose shape the remedy never claimed"
  - "The record that tripped the read is the author's own probe"
root_cause: logic_error
resolution_type: tooling_addition
related_components:
  - papercut-cli
  - read-ceiling-guard
  - structured-output-unwrap-hook
tags:
  - papercut
  - verification
  - loop-breaking-remedy
  - repeats-only
  - target-prefix
  - claim-boundary
  - retry-loop
  - regression-detection
---

# Verify a loop-breaking remedy by counting repeats and naming the shapes it covers

## Context

`papercut family show` and `rollup` judge a closed family's fix from the
post-closure records that match its member signatures (`verification_details`
and `member_record` in `bin/papercut.py`). Until dotfiles #880 every
matching record counted, so a fix was "regressed" the moment its signature
fired once after closure. That was the design as specified: the 2026-08-26
session that built the verification lifecycle (issue #536, PR #537) wrote
"any post-boundary member record reports `regressed`" and never raised a
repeat-aware alternative (session history). The same session did catch a
different false-regression vector, quarantined records leaking into the raw
read, and fixed it by narrowing the read to live members; it also rejected a
family-scoped exposure floor for a store-wide one because a busy store would
trivially clear a small family's bar (session history). Both were about which
records to count, never about whether a first attempt is evidence.

Occurrence counting is the wrong measure for a remedy that breaks a retry
loop instead of preventing the first failure. Two shipped fixes have that
shape: the Read ceiling guard (`hooks/PreToolUse/read-ceiling-chunk.js`)
denies the *second* oversize attempt, and the StructuredOutput unwrap hook
(`hooks/PreToolUse/structured-output-unwrap.js`) rewrites the retry.
Neither stops the first failure by design, so the signature keeps firing once
per caller and file while the fix works, and on 2026-09-02 both families
(`whole-transcript-reads`, `structured-output-schema-drift`) read `regressed`
on first failures alone. One of the two "regressions" was the author's own
probe record. The gap had been named in a memory note before it bit; naming
it was not fixing it.

The first fix, `--repeats-only` (#880), was incomplete on its own. The
structured-output family regressed again on a genuine loop of a *different*
shape: an agent sending `{summary: "<prose>"}` three times against a schema
that required `claims`. The unwrap remedy never claimed that shape. Every
wrapped shape codes its target as `keys:input=...`, so a prefix names the
class the remedy covers; that became `--target-prefix` (#891).

## Guidance

Verification of a remedy must measure what the remedy changes, and the claim
boundary stored on the family is where that measure is declared. Three rules:

1. **Count repeats, not occurrences.** A loop-breaking remedy changes the
   second and later attempts, so only those are evidence. `repeat_marks()` in
   `bin/papercut.py` marks a record when it is the second or later
   occurrence of the same signature for the same session, agent and target,
   in time order, and `member_record()` counts a repeats-only member only
   when it is marked:

   ```
   papercut family scope <family> <sig> --repeats-only
   ```

2. **Name the shape class the remedy covers.** When the signature fires on
   every shape but the remedy rewrites one class of shape-coded targets, the
   prefix is the class. It combines with the existing `--target-suffix`, and a
   scope event replaces the whole boundary (the CLI prints what it replaced):

   ```
   papercut family scope <family> <sig> --target-prefix "keys:input=" --repeats-only
   ```

3. **Order by parsed time and ignore subject-less records.** The hook writes
   millisecond timestamps with `Z` and the CLI writes microseconds with an
   offset, so raw string order inverts them; `repeat_marks()` sorts by the
   parsed instant. A record with no target and no command, or an unparseable
   timestamp, neither counts as a repeat nor seeds one. Fail closed: a record
   that cannot prove it is in scope is not evidence.

The doctrine as written in `skills-local/papercut/SKILL.md` (Claim
boundaries):

> A remedy that breaks retry loops (a guard that denies the second attempt, a
> hook that rewrites it) never stops the first failure, so its signature keeps
> firing while the fix works; add `--repeats-only` and only the second and
> later occurrences for the same session, agent and target count. When targets
> are shape-coded (`keys:input=object`, `keys:input=json`), `--target-prefix`
> names the class the remedy covers. The flags combine, and a scope event
> replaces the whole boundary.

## Why This Matters

Occurrence counting manufactures a permanent false `regressed` for any fix
whose success mode is "the loop stops after the first try" rather than "the
failure never happens". The family can never reach `verifying`, the operator
is sent digging through self-inflicted probe noise, and a real regression of
the same signature hides inside the same number. The fix belongs in the
shared predicate (`repeat_marks()` and `member_record()`), so every family of
this shape gets the correct read from one change rather than a carve-out each.

The second rule is the same lesson applied to shape: a signature that is a
superset of the remedy's claim regresses on volume the remedy never touched.
The dossier's No-Claim Boundary already says what a green result does not
prove; the stored scope is that sentence made machine-enforced.

## When to Apply

- Apply `--repeats-only` when the remedy denies or rewrites the retry and the
  first failure is expected to keep happening once per caller.
- Do **not** apply it when the remedy stops the first failure outright (a
  validation fix, a guard that blocks the action before it runs). There the
  occurrence count should fall to zero, and requiring a second occurrence
  would hide a genuine regression.
- Apply `--target-prefix`, alone or combined, whenever the remedy covers only
  a class of the signature's targets. The class must come from the dossier's
  No-Claim Boundary, not from the records that happened to trip the read.
- When a family reads `regressed`, check the first post-closure record it
  names against the claim before treating the read as a regression. Twice on
  2026-09-02 the record was out of claim.

## Examples

**Read ceiling guard (`whole-transcript-reads`)**

- Before: every oversize `.jsonl` read counted, first attempt and retry
  alike; the family read `regressed`.
- Applied: `papercut family scope whole-transcript-reads <ceiling sig> --target-suffix .jsonl --repeats-only`
- After: `verifying`. Only second-and-later denials for the same session,
  agent and transcript count.

**StructuredOutput unwrap (`structured-output-schema-drift`)**

- Before #880: every schema mismatch counted, including first attempts;
  `regressed`.
- After #880 with `--repeats-only` alone: first attempts no longer counted,
  but a genuine three-try loop of `{summary: "<prose>"}` against a schema
  requiring `claims` still did, and the unwrap hook never claimed that shape.
- Applied (#891): `papercut family scope structured-output-schema-drift structuredoutput_schema_mismatch --target-prefix "keys:input=" --repeats-only`
- After: `verifying`. Only repeats among `keys:input=`-coded targets count,
  which is exactly what the hook rewrites.

## Related

- Early verdict (dotfiles #885): `verified` once exposure crosses the floor
  after a seven-day minimum, instead of waiting out the closure-scaled window.
  Orthogonal to this learning: it changes *when* a clean window proves, not
  *what* counts as a recurrence.
- `--target-suffix` (dotfiles #785) is the claim-boundary mechanism this
  extends; it shipped first for superset signatures, and #880 and #891 reuse
  the same scope event.
- The verification lifecycle itself (regressed, verifying, verified,
  provisional) was introduced by dotfiles issue #536.
- Sibling learnings on papercut verification:
  [verify-parity-claims-by-exercising-both-sides](verify-parity-claims-by-exercising-both-sides.md)
  (the evidence class was wrong) and
  [diagnose-against-installed-versions-not-plugin-caches](diagnose-against-installed-versions-not-plugin-caches.md)
  (the probed version was wrong). This one: the counted event was wrong.
