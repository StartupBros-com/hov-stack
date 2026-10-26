---
title: "A stub proves the wiring; only a live run proves a cooperative contract"
date: "2026-09-04"
category: best-practices
module: pro-gate-oracle-review
problem_type: best_practice
component: testing_framework
severity: high
last_updated: "2026-09-04"
applies_when:
  - "The acceptance criterion is that an external party you don't control (a model, a third-party service) complies with instructions your code appends or composes"
  - "Every test exercising the new code path substitutes a stub or mock for that external party instead of the real one"
  - "The change adds a size or format cap on caller-supplied input and treats that as sufficient input validation"
  - "A closed-enum classification field is derived from evidence an external process's own output artifacts must carry, and every suite fixture that exercises it was hand-written to supply exactly that evidence"
  - "A merged-but-unreleased change ships a classification field and every check so far ran the suite's own fixtures against a stub, never a plainer substitute or the real, merged engine end to end"
tags:
  - test-doubles
  - live-verification
  - cooperative-contract
  - pro-gate
  - oracle-review
  - edge-case-selection
  - evidence-dependent-classification
  - merged-engine-smoke

---

# A stub proves the wiring; only a live run proves a cooperative contract

## Context

pro-gate v0.39.0 (PR #137, StartupBros-com/pro-gate) added `oracle-review.sh --brief <task-file>`:
a caller-supplied task body substitutes for the engine's built-in reviewer persona, while the
engine always appends its own output contract afterward — findings format, the terminal
`VERDICT:` line, and the run marker (`pro-gate bin/oracle-review.sh:2959-2966`). The whole feature was
verified against a stub oracle swapped in via `PRO_GATE_ORACLE_BIN` (`pro-gate bin/oracle-review.sh:2900`,
`pro-gate lib/pro-gate-lib.sh:2941`) — `pro-gate tests/engine.test.sh:2071-2075` points it at
`"$TDIR/bin/oracle-evidence"` and asserts the brief body lands in the captured argv, the default
persona is absent, and the footer (`OUTPUT FORMAT`, the closed verdict vocabulary, `run marker:`)
survives (`pro-gate tests/engine.test.sh:2078-2091`). Every check passed; the PR reported "Engine suite:
909 ok / 0 FAIL."

None of that suite could catch the actual defect, because a stub oracle cannot decide whether to
cooperate — it always does, by construction. The engine's own comment names the real risk: "the
footer is a COOPERATIVE contract, not an enforced one" (`pro-gate bin/oracle-review.sh:2966`) — the brief
and the footer are instructions at the same authority level, so a brief can request an
incompatible format or preselect a verdict, and `pg_extract_verdict` only greps the terminal line.
That property is only observable by watching a real model choose whether to comply.

One live run against a real ChatGPT Pro session, deliberately given a non-review brief (a database
migration/architecture risk assessment, not a code review), returned `FIX-FIRST` with three
high-confidence findings (issue #138) — all real, all fixed before release in PR #139. Cost: one
Pro slot, and per PR #139's own report, "`ENGINE_RC=0`, 6m24s, no pinned slot." The findings:

1. The "brief chooses the question, never the answer's shape" claim in the README and PR #137 was
   overstated — a brief *can* dictate the answer's shape, and nothing in the pipeline could tell a
   reasoned verdict from a dictated one.
2. The 64 KiB cap on brief size (`pro-gate bin/oracle-review.sh:211-213`) validates bytes, not
   answerability — an ambiguous brief that invites a clarifying question completes with no
   findings and no verdict, fails `pg_is_review`, and holds its reservation until recovery, turning
   ordinary ambiguity into a shared-capacity denial path (comment now at
   `pro-gate bin/oracle-review.sh:2979-2983`).
3. A `--brief` run passed together with `--pr` silently spent that PR's own round budget and could
   be handed back by `--recover <PR>` in place of the canonical review.

All three were fixed in PR #139: the footer now instructs the model to state assumptions instead
of asking a clarifying question and pins the run to one turn (`pro-gate bin/oracle-review.sh:2984-2989`,
pinned by `pro-gate tests/engine.test.sh` check `'brief footer forbids a clarifying question and pins one
turn'`), and `--brief` combined with `--pr` is now refused outright
(`pro-gate bin/oracle-review.sh:190-196`).

## Guidance

### Recognize when a stub cannot cover the criterion

A stub/mock proves the code around an external call: the right bytes were assembled and handed
off, and the right bytes were parsed back. It cannot prove anything about a criterion whose
answer depends on the external party's judgment — "the model treats this as a hard boundary,"
"the model doesn't preselect the answer," "the model asks vs. states an assumption." If the
acceptance criterion is stated as "party X complies with instructions we appended," no amount of
stub coverage answers it, because the stub was written to comply.

### Budget one live run, chosen at the edge, not the middle

Before release, spend one real invocation of the external system on the *hardest* case the new
capability opens up, not a representative one — the representative case is what the stub already
covers. Here that meant a brief that was deliberately *not* a code review, testing whether the
appended contract footer would still be honored when the task body pulled in a different
direction. A same-shape brief ("review this diff") would have looked like success and proven
nothing new.

### Size/format validation is not answerability validation

A byte cap, a schema check, or a well-formedness guard on caller-supplied input answers "is this
input structurally acceptable," not "can the external party produce a complete, contract-shaped
answer from it in one turn." Those are different questions with different failure modes — the
second one, unaddressed, turns ambiguous input into a stuck, resource-holding request rather than
a clean rejection. If the system holds a scarce reservation across the call (a slot, a lock, a
budget line), name this failure mode explicitly in review and give the external party an
instruction that forces a terminal state (state an assumption; don't defer; don't ask).

### Keep the live probe cheap and once

This is not a call to add live E2E coverage to every run — the whole value of the stub suite is
that it's free and fast, and it should stay the day-to-day gate. The live run is a one-time,
pre-release check against a scarce, costed resource (here, a Pro reasoning-model slot), spent
once per capability addition, at the edge case, immediately before shipping.

### A stub cannot reveal evidence-dependent classification

pro-gate v0.40.0 (PR #144, StartupBros-com/pro-gate) added a closed-enum `reason` field to every
failed ledger row, derived mechanically from run-state flags and a `fail_detail` substring match
(`bin/oracle-review.sh:2349-2367`): `refunded-unsubmitted` when the run's own no-spend refund fired,
`salvage-empty` otherwise. CI reported `trusted check: SUCCESS`, and a full local run of
`tests/engine.test.sh` alone (2026-09-04) passed 917 `ok -` assertions with 0 `FAIL -` and printed
`ALL PASS`, including the suite's own `#143` fixtures
(`tests/engine.test.sh:1307-1308`, `:1334-1338`), which assert the two failure shapes carry
different reasons — but only because their fake oracle binary hand-writes the exact evidence
`pg_attempt_provably_unsubmitted` demands: a session `meta.json` with
`browser.runtime.promptSubmitted:false` (`tests/engine.test.sh:1289`). That predicate
(`bin/oracle-review.sh:3608-3621`) is the one gate between a failure and a refund; its own comment
states the bar plainly: "Missing, conflicting, or promptSubmitted=true metadata is ambiguous and
therefore remains charged" (`bin/oracle-review.sh:3606-3607`). A live smoke driving the merged
engine directly, with a plainer stub oracle that never wrote that metadata, produced `salvage-empty`
for both a never-landed and a landed-but-lost run. A follow-up live A/B run, holding that same
evidence-free stub fixed and toggling only `--diff` vs. `--pr`, reproduced the identical collapse in
both modes: the split is evidence-dependent, not mode-dependent, even though
`pg_fresh_dispatch_refund` (`bin/oracle-review.sh:1951-1965`) does separately bifurcate on PR
identity for HOW a proven refund gets persisted (a durable per-PR transition vs. an in-place
round-file decrement) — a distinct question from whether one is attempted at all.

## Applicability

Applies to any change whose acceptance criterion routes through a party you don't control and
can't fully specify: an LLM asked to follow appended instructions, a third-party webhook consumer
expected to honor a contract, a plugin host expected to respect a declared capability boundary.
It does not apply to contracts enforced by code on both ends (schema validation against a fixed
parser, a typed RPC) — those are exactly the kind of boundary a stub *can* prove, per
[Verify schema-bound Claude Code controllers with a real provider](verify-schema-bound-claude-code-controllers-with-a-real-provider.md),
whose guidance #4 makes the adjacent, narrower point that a mocked subprocess test proves
assembly, not provider compatibility, for a schema-typed structured-output route. This learning
generalizes that same shape to a *cooperative* (natural-language, unenforced) contract, and adds
the two findings specific to that case: choose the live probe's input at the capability's edge, and
treat a byte/format cap as size validation only, never as proof the input is answerable.

It also applies with no external party in the picture at all, when the classification a stub-driven
suite asserts depends on evidence the stub itself was authored to supply:

- A closed-enum classification field (a `reason`, `outcome`, or `kind` column) whose value depends
  on evidence assembled from a stubbed external process's own output artifacts — a log line, a
  session file, a status field — not just its exit code or a caller-visible flag.
- A test suite's fixture is hand-crafted to satisfy an internal predicate exactly; passing CI proves
  that fixture clears the bar, never that a plausible simpler substitute, or a differently-authored
  live rehearsal of the same scenario, would clear it too.
- The dimension a live smoke's author assumes gates an outcome (a mode, a flag, an input shape) may
  not be the one that actually does — verify by holding the suspected variable constant and toggling
  only fixture fidelity, per run, before writing up an attribution.
- When "production always runs mode X, so this has no blast radius" is offered as the reason a gap
  is safe, confirm mode X's own code path — not just its outcome — was the one actually exercised;
  the collapse may trace to a predicate neither mode's fixture stresses differently.

## Related

- [Verify schema-bound Claude Code controllers with a real provider](verify-schema-bound-claude-code-controllers-with-a-real-provider.md) — the schema-typed sibling of this learning; its guidance #4 states the same "mock proves assembly, not compatibility" principle for a provider-validated JSON contract rather than a cooperative natural-language one.
- [Verify a parity claim by exercising both sides, never by reading a design table](verify-parity-claims-by-exercising-both-sides.md) — a related but distinct trap: trusting a design artifact over executed code, rather than trusting a test double over a live external party.
- [Capture the payload through a test's stub seam to prove a refactor is safe, not by sampling](capture-payload-through-stub-seam-to-prove-refactor-safe.md) — the sibling lesson on the same `PRO_GATE_ORACLE_BIN` seam: it proves a refactor didn't change what gets SENT to the oracle; this addition is about what a stub can prove comes BACK, and shows a hand-authored fixture's fidelity to the real oracle's own output contract is itself something no CI run of that same fixture can verify.
