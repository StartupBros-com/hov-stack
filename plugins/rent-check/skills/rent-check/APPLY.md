# Follow-through: applying a rent-check report

Discipline for the session that applies the verdicts — validated by a real
follow-through that shipped an auth fix and a CI gate from one audit, and
by the two deviations it also produced. The audit stays report-only; this
file governs what happens after the operator says go.

## Ship shape

- One worktree + PR per repository touched. A shared or main checkout
  carries no work: if you find yourself with uncommitted edits there,
  rescue them as a byte-exact copy committed through a worktree PR (the
  dirty checkout then fast-forwards cleanly, since content matches).
- Batch the edits per file; every PR names which verdict numbers it
  implements, so the report is the review artifact.
- File issues for everything you deliberately don't fix inline; a verdict
  with neither an edit nor an issue silently evaporates.

## Gates and guards

- Before deleting or renaming any file that a CI gate reads, open the
  gate's checker first and rework it in the same PR — then prove the
  known-bad fixtures still fail. A gate that passes because its input
  vanished is a gate you just deleted.
- Any new lint/CI rule ships mutation-proofed: run it against the unfixed
  tree first and quote the firing in the PR. A gate never seen firing is
  a paper tiger from birth.
- PROMOTE verdicts are evidence-sized: sweep every call site before
  writing the gate's scope, fix the violations the sweep finds in the
  same PR, and state the sweep numbers (N sites, M violations) in the PR
  body.

## Boundaries that survive the apply phase

- Memory-index verdicts route to the consolidator (P3). The
  hand-compaction fallback needs all three: the operator's explicit ask,
  both P3 gates passed (link parity + fidelity spot-check), and a
  verbatim backup of the original written first.
- Config values you raise rather than flag get the rationale inline as a
  comment, with the measurement that justified it.
- Code-touching PRs go through the host harness's review tier before
  merge; hand the merge back only where the operator's conventions say
  so. Doc-only PRs follow the harness's routine-merge rule.
