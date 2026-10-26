---
title: "Backstop a best-effort upstream stop with an unbroken-run counter that resets in one place"
date: 2026-09-28
category: best-practices
module: pro-gate-loop
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "An upstream computes its stop for a repeating action from a record it writes best effort, so a failed write reads back as zero failures"
  - "A caller loop is about to retire its own repeat detection because the upstream now ships a typed stop for the same failure"
  - "A caller-side counter has to survive every branch of a dispatch loop, not just the branch that first needed it"
  - "Deciding whether a counter stops right after the Nth failed attempt or at the next dispatch of the same action"
symptoms:
  - "The loop deferred to the runtime's typed stop, and an unwritable record let the same failing review be granted again without bound"
  - "Stopping right after the third fruitless effect abandoned a review the runtime had kept durable"
  - "The first grant after a fix stopped the loop because the fixer path never reset the count"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - pro-gate-loop
  - pro-gate-runtime
tags:
  - pro-gate
  - review-loop
  - backstop-counter
  - best-effort-record
  - reset-at-dispatch
  - unbroken-run
  - retry-loop
  - delivery-failed-unchanged
---

# Backstop a best-effort upstream stop with an unbroken-run counter that resets in one place

## Context

pro-gate v0.58.0 (StartupBros-com/pro-gate PR #239, issue #204) stops re-granting a review whose delivery failed twice under an unchanged condition. Its reducer returns `stop-without-new-review` with reason `delivery-failed-unchanged` when `facts.delivery.failed_unchanged` is 2 or more and no override is set (pro-gate `lib/pro-gate-lib.sh:4068-4071` at v0.58.0).

The count comes from a per-attempt record that the runtime writes best effort:

- The writer, `pg_fresh_dispatch_record_undelivered` (pro-gate `bin/oracle-review.sh:2219-2232`), prints "could not record this attempt's delivery condition; an unchanged repeat will not be stopped (#204)" when the write fails, and carries on.
- The reader, `pg_delivery_facts_json` (pro-gate `lib/pro-gate-lib.sh:1343-1364`), returns a count of 0 when no record exists. A record that was never written therefore reads as zero with no message at query time. The reader warns only when a record exists but cannot be read, or when Oracle's version cannot be read so the condition cannot be matched; both of those also count from zero.

So when the write fails, or the condition reads differently on the next query, the typed stop never fires and the runtime grants the same review again.

Dotfiles PR #1432 moved `scripts/pro-gate-loop.sh` onto that stop. At runtime 0.58.0 or later (`TYPED_DELIVERY_STOP`, `scripts/pro-gate-loop.sh:473-474`) the loop no longer greps its effect log for "did not finish uploading" and no longer stops itself after two such stalls. The code review of #1432 raised a P1: with an unwritable record the loop had no bound of its own and would repeat until its round or time cap. Whether the runtime should fail closed instead is an open operator question on pro-gate#204. The loop could not wait for that answer, so it gained its own counter, `fruitless`.

The counter took three external review rounds. Rounds 1 and 2 each found one edge, and both edges had the same cause: resets placed on particular paths instead of stated as one rule.

- **First design.** Count a granted review that ended with nothing (no artifact, not a throttle, not exit 9, not exits 7 or 8), stop right after the third, and reset in the branches that count a review. Round 1 found that `pg_publish_fail` (pro-gate `bin/oracle-review.sh:2307`) can end an effect with exit 6 and no `--out` while keeping the captured review durable. Stopping right after the third such effect abandoned a finished review before anything collected it. The fix left the increment after the effect but moved the stop to the next dispatch of `run-granted-review`, so the runtime's collect or recover action (`collect-existing-result` or `recover-existing-review`, one branch at `scripts/pro-gate-loop.sh:1651`) runs first. Test G9i4 scripts the recover path.
- **Second design.** Another worker collected that retained review, and the runtime's next decision was `fix-review-findings`. The fixer path read the review through `review_text` and never reset the count, so the first grant after the fix stopped the loop. The fix replaced the per-path resets with one line at dispatch. Tests G9i5 (the fixer path) and G9i6 (the cooldown keeps the count). Round 3 returned SHIP.

## Since v0.59.0: durable upstream evidence does not retire the caller bound

pro-gate v0.59.0 ([pro-gate #243](https://github.com/StartupBros-com/pro-gate/pull/243), tracked by pro-gate #240) changed the upstream failure mode described above. Its consumer side shipped in dotfiles #1441, which pins v0.59.0 and closed dotfiles #1434. The v0.58.0 history above stays accurate for runtimes older than 0.59.0.

- New proven no-send attempts retain their attempt-time delivery condition and count, or an explicit unavailable state, in the **required durable disposition before refund and cleanup**. The old delivery sidecar remains compatible, but its write failure no longer discards the new attempt's evidence. Cleanup retries reuse the published snapshot.
- `delivery-state-unavailable` stops fresh admission with a null count when history or build identity cannot be established. Unknown-to-known Oracle identity alone is not proof that the build changed. A known independent condition change can permit admission again, subject to the other guards.
- A missing sidecar beside an old v1 disposition is `legacy-untracked`, also with a null count. That historical absence cannot distinguish an old untracked attempt from a failed best-effort write; v0.59.0 preserves its legacy admission behavior rather than inventing evidence.

Keep the caller's unbroken-run counter. It bounds the sequence of grants the caller actually receives, including legacy ambiguity and future producer regressions; it is not a second source of delivery truth. Do not remove its collect/recover opportunity, dispatch reset, or pre-0.58 compatibility path merely because the new runtime can refuse uncertain delivery state. This update does not address the external-head carry-over tracked in dotfiles #1437.

The v0.59.0 fault tests exercise sidecar publication/read failures, unavailable build identity, interrupted disposition cleanup, immutable replay, and stale effect rechecks. Those are isolated regression proofs, not live delivery evidence. The caller's existing stub tests retain their narrower wiring claim.

## Guidance

When an upstream's stop for a repeating action rests on a record the upstream writes best effort, keep a bound in the caller, with four properties.

1. **Count only an unbroken run of the action.** The counter answers one question: does the upstream keep granting the same thing while nothing comes of it?
2. **Reset in one place, at dispatch.** Before branching on the upstream's decision, reset on any decision other than the repeating action and the upstream's own stop. Apart from rule 1's reset when the repeating action itself produces a result, add no resets inside the branches for other decisions, such as the ones that collect or recover a result. Those branches cover only the paths you thought of; the upstream's decision table is larger, and the path you missed is where the bound breaks.
3. **Decide at the next dispatch of the action, not right after the failed attempt.** Increment when the attempt ends; check the threshold only when about to dispatch the action again. The upstream may still hold that attempt's result, and one more query lets it hand the result over.
4. **Leave out deferrals and unresolved work.** A known pre-dispatch deferral is not counted, and neither is an attempt the upstream reports as still in progress, whose outcome is not known yet. A waitable state such as a throttle or cooldown is not counted and is not the upstream moving on, so it does not reset the count either. This is a fruitless-effect counter, not a quota ledger: a proven no-send can return exit 6 after refunding its round and still count as a failed delivery attempt.

The shape:

```sh
count=0
while :; do
  action=$(query_upstream)
  case "$action" in repeat|upstream-stop) ;; *) count=0 ;; esac    # rule 2
  case "$action" in
    repeat)
      [ "$count" -ge 3 ] && stop_with_own_reason                    # rule 3
      run_action; rc=$?
      if produced_result; then count=0                              # rule 1: a result breaks the run
      elif is_waitable || still_in_progress "$rc" || deferred_before_attempt "$rc"; then :   # rule 4
      else count=$((count + 1)); fi ;;
    upstream-stop) is_waitable && { wait_it_out; continue; }; exit ;;   # rule 4: no reset
    *) handle "$action" ;;                                           # already reset above
  esac
done
```

The loop's own lines: `fruitless=0` before the loop (`scripts/pro-gate-loop.sh:1475`), the dispatch reset (`:1553`), the stop at the next grant (`:1578`), the reset when a review completes (`:1596-1597`), the throttle and exit-9 branches that count nothing (`:1602`, `:1612`), and the increment, which skips exits 7 and 8 and runs only at runtime 0.58.0 or later (`:1647`):

```sh
case "$ACTION" in run-granted-review|stop-without-new-review) ;; *) fruitless=0 ;; esac
...
case "$RC" in 7|8) ;; *) [ "$TYPED_DELIVERY_STOP" = 0 ] || fruitless=$((fruitless + 1)) ;; esac
```

Every `stop-without-new-review` other than the account cooldown ends the loop, so keeping the count through that action matters only for the cooldown.

## Why This Matters

Under the v0.58.0 best-effort behavior, a caller that relies wholly on the upstream's stop is one failed write away from an unbounded repeat. The caller cannot see the record; it sees only the same grant again. Each repeat launches another external-browser attempt and consumes time; it does not necessarily spend a Pro slot. Positive no-send proof refunds the round, whereas an unknown submission fate remains charged.

The resets are the lasting lesson. Both misses were resets written where a review happened to finish or a result happened to be collected, when the real rule is "the upstream returned something other than this grant". It is the same point as instrumenting the one chokepoint instead of every call site: one reset at dispatch also covers paths nobody listed, such as `fix-review-findings` reached only because a different worker collected first.

The bound is per loop run. `fruitless` starts at zero each time the loop starts (`scripts/pro-gate-loop.sh:1475`), so a relaunched loop gets three more fruitless grants. A prior session found the loop's round counter has the same per-run scope (session history); bounding a PR across runs belongs to the runtime. The count is also not keyed to the head. When a decision names a head the loop has not validated, the loop restarts validation (`continue` at `scripts/pro-gate-loop.sh:1545`) before the dispatch reset at `:1553`, so a grant for a head pushed from outside keeps the old head's count. That fails safe, by stopping early, and needs three fruitless grants first.

## When to Apply

- The upstream computes its stop from a record it writes best effort: a failed write warns and carries on.
- The caller loops on the upstream's decisions and would otherwise repeat the action until an unrelated cap ends it.
- An attempt that failed by one measure can still leave a result the upstream holds for collection.
- Some outcomes defer before an attempt, are waits to sit out, or retain work for collection.
- Not when the caller writes the record itself, or when the upstream refuses outright if it cannot record. Fix the write path there instead of adding a parallel counter.

## Examples

The tests in `tests/pro-gate-loop.test.sh` each run the loop against a stub runtime that plays the broken upstream:

- G9i: a runtime that grants again after every fruitless effect is stopped at its fourth grant, after 3 effects, with exit 4.
- G9i2: a completed review between stalls resets the count.
- G9i3: exits 7 and 8 are not counted.
- G9i4: a third empty effect whose review the runtime retained is collected, not stopped.
- G9i5: after a retained review, `fix-review-findings` resets the count, and the grant after the fix proceeds.
- G9i6: the waitable cooldown between stalls keeps the count.

#1432's verification section records the red runs: G9i failed on the loop before the counter existed, and G9i4 and G9i5 failed at the heads before their fixes. It records the rest failing against deliberately broken variants, all killed: no reset after a completed review, exit 7 or 8 counted, stopping at two, no dispatch reset, and a reset on the cooldown. It records the suite at 626 passed, 0 failed. None of this was re-run for this doc.

## Related

- [Verify a loop-breaking remedy by counting repeats and naming the shapes it covers](verify-loop-breaking-remedies-by-counting-repeats-not-occurrences.md) also counts repeats, for a different job: judging after the fact, from papercut records, whether a shipped fix regressed. This doc is about the live counter inside the loop.
- [Instrument at the one chokepoint that already sees the cause, not at every call site](instrument-at-the-chokepoint-that-already-sees-the-cause.md): the same one-place principle, applied to instrumentation.
- [A stub proves the wiring; only a live run proves a cooperative contract](a-stub-proves-wiring-only-a-live-run-proves-a-cooperative-contract.md) names the gap left here: the G9i tests use a stub runtime, and no test runs the loop against the real runtime with an unwritable record. At #1432's review, the producer tests covered reader failures but not writer failure; pro-gate v0.59.0 (#243) added writer fault tests at the real disposition seam, not a live cooperative delivery proof.
- pro-gate#204 (open): broader delivery capability. The narrower durable-history repair shipped in v0.59.0 (pro-gate#240, via #243, which superseded #241); it does not close #204. dotfiles#1431 was closed by #1432; #1437 separately tracks the caller's external-head carry-over.
