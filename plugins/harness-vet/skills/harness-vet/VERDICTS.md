# Verdicts

## Vocabulary: component by target

Keep verdict, placement, activation and evidence status separate. A skill can
be SKIP globally and ADOPT in a project without contradicting itself. Include
an unresolved target row when no destination is defensible; missing scope is
not an empty assessment.

- **ADOPT**: use as-is at the recorded supported placement; verified utility
  exceeds target-specific cost. A native project install is ADOPT, not ADAPT
  merely because it is narrower than global.
- **ADAPT**: utility is demonstrated but delivery must change. Name the exact
  change: select permitted components, remove an updater, alter activation,
  patch/fork packaging, or convert a global-only installer to project-local.
  Prefer a native scoped plugin install when it suffices. If per-component
  controls are unavailable, price the whole enabled bundle or explicitly
  adapt it; never invent a per-skill switch or assume all platforms lack one.
  A copied-out component runs standalone in the phase-4 sandbox, every
  outside-directory reference resolved, before ADAPT is rendered.
- **EXTRACT**: port a useful pattern, not the candidate's implementation, into
  the target's idiom. Behavior-shaping ports need a live-task result before
  landing or an explicit unverified-value marker with its deciding measurement.
  Absence from the incumbent is not itself evidence of value.
- **SKIP**: equivalent capability is already usable for the target task, no
  demonstrated need exists, or costs exceed benefit. A broad topic/name match
  alone is not duplication. Callable global on-demand tools count; disabled,
  inaccessible or other-project-only copies do not automatically count. Judge
  coverage at the grain of the target task's capabilities, not the candidate's
  packaging: a server spanning several data sources is covered only where each
  needed capability is. A copy of the candidate itself at another scope is a
  placement question, not an incumbent: where the copies diverge, or the
  operator asked to narrow where it loads, reconcile (ADAPT); only an
  undiverged copy verified to serve this target, with no narrowing asked, is
  recorded as covered. "Covered" ends the comparison only after every
  contender the digest slates has run in the same phase-4 arms, or is
  recorded PARTIAL with its deciding run named; a PARTIAL contender backs
  neither SKIP-as-covered nor ADOPT/ADAPT, for itself or for the candidate
  over it (SKIP pending the named run). Insufficient verification may
  mean SKIP pending evidence, never a fabricated negative benchmark or a
  security REJECT.
- **REJECT**: an affirmative disqualifier supported by evidence, such as unsafe
  code, materially refuted claims or dead maintenance. State confidence,
  affected revision/components and the actual defect. Project scope is no
  sandbox.

Depending on an upstream entirely is ADOPT with the eval note's upstream pin
and update owner set to that upstream; vendoring it is ADAPT with the local
adaptation recorded; cherry-picking is EXTRACT. A slated contender gets
phase 3's full read of its instructions and executables before its arm
runs, and one that reaches ADOPT or ADAPT passes the same phase-5 checks as
a supplied candidate; a dropped hit gets no verdict because nothing of it is
adopted. Verdicts may mix across upstreams — ADOPT one and EXTRACT from
another — when the evidence does.

Roll up counts **per target**, with separate delivery and content verdicts.
Roll up only the targets this run was asked about or inferred; a prior verdict
or another scope's state belongs in the explanation, never as an extra rollup
row that reads as a verdict nobody requested.
A multi-target run shares artifact checks; it does not duplicate every reader.
Triaged-only entries are not deep-vet approvals. Proposed, tested, landed and
runtime-verified are different states, not synonyms for ADOPT.

## Prior verdicts and re-evaluation

Search by candidate/source identity across discovered note locations FIRST,
then check applicability by revision, component, task, scope and runtime.
Reuse verified shared findings, not necessarily a previous fit conclusion.

Every SKIP/REJECT records `Do-not-retry unless:` with observable predicates:
changed candidate behavior, demonstrated new task need, unavailable incumbent,
changed delivery cost, or a supported placement that solves the recorded
objection. Bare time, enthusiasm and repeated asks alone are not evidence.
A new target or task reopens **fit** when it changes those premises: a global
SKIP for cost or no need does not veto a new project. Security findings remain
applicable across targets until their cause is demonstrably removed.

Legacy unscoped notes are evidence leads, not fleet-wide fit verdicts. Record
search gaps and uncertain applicability; do not assert "never vetted" just
because this project's memory has no note. Preserve prior notes and append
corrections with dates rather than silently rewriting their history.

ADOPT/ADAPT also record the inspected revision/content digest and a bounded
review trigger: changed instructions, dependencies, capabilities or permissions;
a changed target task, incumbent or model/runtime that invalidates the test.
Review the changed assumptions, not the entire fleet at every model update.

## Eval note

Land the note where a future vet of that target will search: the target's
discoverable note system, or a stated committed report location when none
exists. The agent's private per-project memory carries a pointer, not the
note, unless the digest verified it is what that target's vets search.
Index/cross-link it. Do not copy private project material into a public
report or global memory.

1. Source identity/revision, evidence links, target(s), concrete use case, and
   run choices: scope chosen/inferred, sweep coverage, landing depth, and the
   external-discovery record: each lane/source searched or `not searched`,
   each pass's seed and queries, and the stop that fired.
2. `Measured, not inferred:` commands/results, model/runtime, tested vs
   inferred controls, incomplete checks and limits of the evidence.
3. Table: component | target | verdict | placement | activation | evidence |
   state. For skipped/rejected rows use no installation as the destination.
   Discovered contenders get rows too, including those triaged and not
   deep-vetted, with the lane/pass that found each.
4. For proposed changes: rationale, exact permitted files/config, provenance,
   upstream pin, local adaptation, update owner and rollback.
5. Shared artifact findings versus target-specific fit findings, prior notes
   reused, applicability changes and searched/unavailable note locations;
   discovery hits dropped at triage, each with its one-line reason.
6. Audit dividend and scoped `Do-not-retry unless:` or re-audit triggers.

## Closing checklist

- [ ] Every evaluated component/target has a verdict, evidence status and
      placement/activation or explicit no-install recommendation.
- [ ] Applicable safety findings were retained across targets; overlap claims
      name a covering mechanism actually available in each target.
- [ ] Intended landings were tested with the relevant global/project/nested
      inputs and matching runtime. Visibility, collision and invocation checks
      ran in target and unrelated controls, or are explicitly PARTIAL/unshipped.
- [ ] Applied changes passed the target's review/testing conventions, with
      adversarial review for behavior-shaping ports and measured value or its
      explicit marker. Record proposed/PR/merged/runtime-verified separately.
- [ ] Security-posture proposals — including a target's first
      instruction-loading surface — name their target/config and await required
      authorization. No global enabling, secret access or incidental cleanup
      followed merely from a local adoption recommendation.
- [ ] Diverged copies were diffed and an authoritative copy named; no SKIP
      rests on a diverged or unverified copy of the candidate at another scope.
- [ ] The eval note and triggers exist where promised. Report-only/dry-run
      has no mandatory installs or external issues; issue-only/PR-only work
      records its actual unshipped state. Deferred work is tracked only within
      the authorized landing mode.
- [ ] Claims of shipment cite merged artifacts; tests, drafts and release
      preparation are not deployment evidence.
- [ ] The discovery record names every lane/source as searched or `not
      searched`, each pass's seed and queries, and the stop that fired; every
      triaged contender has a row with its lane/pass and every dropped hit a
      one-line reason; no recommendation claims exhaustive coverage, and no
      slated contender is missing from the phase-4 arms without a PARTIAL row
      naming its deciding run.
