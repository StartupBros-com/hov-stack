---
title: "Recover a review from validated artifacts, not a new synthesis"
date: "2026-09-24"
category: best-practices
module: ce-code-review-recovery
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - "A review has synthesis, validator input, and verdict artifacts, but reporting remains incomplete"
  - "A recovery attempt changes the candidate set or renumbers findings after validation"
  - "A recovered report must retain its reviewed revision despite later implementation changes"
tags:
  - ce-code-review
  - review-recovery
  - finding-identity
  - validation
  - workflow
  - pinned-revision
---

# Recover a review from validated artifacts, not a new synthesis

## Context

During the review of PR #1356,
validation had completed but the final report still needed recovery. The original
`synthesized-findings.json` and `validator-input.json` agreed on one primary P2:
**#1, “Missing dotfiles path is audited as a real repo.”** The validator confirmed
that claim at the recorded reviewed revision, reproducing missing-path and
regular-file cases against a valid-directory control. A separate jq-diagnostic
concern remained an informational advisory.

The attempted recovery extended the earlier workflow, retaining its reviewer
and merge calls and appending a report leaf. The preserved extension script and
workflow journal show that construction and another merge-leaf launch. That
rerun produced three primary findings: the missing-repository claim moved to #2,
while #1 became an empty-message claim the original synthesis had rejected.
Both versions named the same reviewed revision. Reusing the old verdict by
number would therefore have confirmed a different claim.

Worktree relocation preceded this event, but the surviving evidence does not
establish it as the cause. This incident does not prove that Workflow resume
generally reruns completed calls or that correctly keyed cached resume is invalid.

Recovery preserved the alternate synthesis and validator input, then restored
the original pair with the existing deterministic `merge-synthesize.py` script.
That script checked the probe revision against the review scope and asserted
that the synthesized findings equaled the validator input. The original verdict
remained attached to that input. A fresh report-only workflow returned the
original single confirmed P2; its returned text matches the report subsequently
saved by the parent. The report leaf did not itself persist the Markdown file,
so recovering its text was not proof that all artifact bookkeeping completed.

## Guidance

1. **Identify the missing stage from surviving evidence.** Read the review scope,
   synthesis, actual validator input, verdict, and relevant journal returns.
   A saved filename or run ID alone does not establish that artifacts still
   belong together. If a worker may still be writing them, establish a single
   writer before starting a replacement.
2. **Preserve unexpected output before restoring the validated state.** Keep the
   alternate synthesis and input distinguishable from the original pair. Do not
   silently replace admission decisions or translate old verdict numbers onto
   newly synthesized findings.
3. **Bind a verdict to its revision and claim input.** Check the exact revision
   and diff scope, then the original finding's file, location, failure condition,
   evidence, and requested correction. Match the verdict's reasoning and dispatch
   evidence to that input. The same number and revision are insufficient if the
   claim changed. If the binding cannot be established, validate the intended
   input again rather than borrowing a verdict.
4. **Run only the missing stage when reporting is all that remains.** Here, a
   fresh report-only leaf consumed the restored synthesis and matching verdict;
   another synthesis pass was unnecessary. A cached continuation is reasonable
   when its input bindings and reuse can be established, not merely assumed from
   unchanged call text.
5. **Check the report and retain its No-Claim Boundary.** Verify that it contains
   the validated claim, preserves the disposition of rejected claims and
   advisories, and names the reviewed scope. Recovery is not approval of later
   code changes, terminal Pro approval, or live-provider success.

## Why This Matters

Synthesis includes judgment: admitting candidates, rejecting others, changing
severity, and assigning numbers. Repeating it can change what a finding ID means
without changing the code under review. The validator can remain correct while
a report built from mismatched artifacts becomes false.

The lesson is the binding between evidence and claim, not a new recovery service
or permanent artifact store. The existing artifacts were sufficient. Repeated
review work is not additional independent evidence or implementation progress.

## When to Apply

Use this approach when a validated review's report was interrupted, lost, or
unexpectedly regenerated, or when a continuation encounters differing claim
inputs. When new evidence actually requires fresh review, treat its synthesis
and validation as a new set rather than presenting it as recovery of the old one.

## Examples

The decisive comparison in PR #1356 was semantic, not numeric. Both syntheses
named the **same reviewed revision**:

| Artifact set | Finding #1 | Missing-repository claim | Existing validator verdict |
|---|---|---|---|
| Original synthesis and input | Missing path counted as checked | #1 | Confirmed this original input |
| Unexpected rerun and input | Empty finding message bypassed warning | #2, with changed wording and evidence | Did not validate this new input set |
| Restored original pair | Missing path counted as checked | #1 | Reused with its original revision and claim input |

Joining the old `{ "#": 1, "status": "confirmed" }` onto the rerun's #1 would
have been wrong. Checking the revision alone would not have caught it. Recovery
restored the original finding data, checked its correspondence with the
validator's missing-path reasoning, and rendered that matched set.

The recovered verdict was **“Ready with fixes” for the reviewed revision only**:
one P2 confirmed in isolated fixtures, installed-host incidence unmeasured, and
subsequent implementation changes outside its scope. It was not approval of the
later implementation or completion of the terminal gate.

## Related

- [Merging a plugin version bump is the ship moment](merging-a-plugin-version-bump-is-the-ship-moment.md)
  covers binding a review to the intended source range; this incident additionally
  required binding each verdict to the original claim input.
- [Split a build across implementers under a written contract](split-a-build-across-implementers-under-a-written-contract-and-let-reviewers-not-the-suite-find-the-blockers.md)
  covers file ownership when replacement or concurrent workers could overlap.
