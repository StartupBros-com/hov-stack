---
title: "Instrument at the one chokepoint that already sees the cause, not at every call site"
date: "2026-09-04"
category: best-practices
module: pro-gate-ledger-instrumentation
problem_type: best_practice
component: development_workflow
severity: medium
resolution_type: code_fix
applies_when:
  - "A terminal/shared function in a shell (or similar) runtime is called from many exit paths, and every one of those paths already computes or receives a human-readable cause string immediately before calling it"
  - "A log or ledger row written by that terminal function is byte-identical across many distinct real failure causes, because the terminal function itself never received the cause"
  - "The instinct is to edit every call site (or every branch) to pass richer data through, rather than adding one capture point in the function all of them already call"
  - "A closed-enum classification (not free-text) can be derived mechanically from flags/state the run already set, avoiding any risk of model output, prompt text, or URLs leaking into a structured field"
  - "Some exit paths run before the chokepoint function is even defined or established (e.g. an early-exit recovery mode) -- those are out of instrumentation's reach by design and must be documented as such rather than forced"
symptoms:
  - "Hundreds of ledger/log rows share one generic failure phase with no distinguishing detail, even though the process clearly failed for many different reasons over time"
  - "A first attempt to add detail at the true root-cause site (e.g. an exit-6 branch) works for that one path but leaves every other failure site still writing the same undifferentiated row"
related_components:
  - pro-gate-reservation-ledger
  - pro-gate-daemon-runtime
  - pro-gate-oracle-review
tags:
  - pro-gate
  - instrumentation
  - chokepoint
  - ledger
  - shell-scripting
  - root-cause-capture
  - closed-enum
  - observability
---

# Instrument at the one chokepoint that already sees the cause, not at every call site
## Context

pro-gate's ledger (`~/.pro-review-daemon/ledger.jsonl`) accumulated 311 all-time rows with `outcome:"failed"` that were byte-identical after the fact: every one `exit:6`, `salvaged:0`, no reason field at all. Measured 2026-09-04: those 311 rows represented 181.5 hours of Pro oracle time — 22% of all-time spend — sitting in one undifferentiated bucket. Nobody could tell, from the ledger alone, whether a given failure was a browser crash mid-run, an infra fault, a round that was refunded because the prompt never reached ChatGPT, or a round that stayed charged because the prompt landed but the tab died before the answer could be salvaged. Those are operationally different problems with different fixes, and the engine already knew which was which at the moment of failure — it just never wrote the answer down.

Every failure site in `bin/oracle-review.sh` calls `pg_status failed "<why>"` immediately before exiting; the `<why>` string is human-readable and already computed. The exit-6 site specifically builds a `FAIL_DETAIL`-shaped message with five distinguishable phrasings (no usable review after salvage / infrastructure error, round retained, round refunded, fate uncertain, browser restarted mid-run). None of that reached the ledger: `pg_finish` (`bin/oracle-review.sh:2216`) wrote its row from `outcome`, `exit`, and a fixed set of counters, and discarded the detail string entirely.

## Guidance

The general pattern, independent of pro-gate:

1. **Find the function every failure path already passes through with the cause in hand.** Not the write site — the call site that's closest to the failure, that every branch reaches, and that already has a human-readable (or flag-shaped) explanation as a local variable or argument.
2. **Capture there, don't reconstruct later.** Add one line that stashes the value somewhere the write site can read it. Do not try to re-derive "why" from state at write time if the chokepoint already had it fresher.
3. **Classify at the single write site, from flags already set, into a closed enum.** The classifier must never copy raw captured text (model output, a URL, a stack trace) into the persisted field — only pattern-match on strings/flags the *engine itself* set, and emit one of a fixed set of tokens. This is what keeps the new field greppable and immune to injected bytes; the raw text can still ride along in a second field (e.g. `detail`) if it's already been sanitized for a different write path (the status file, here), but the classification decision itself is closed-vocabulary.
4. **Enumerate and document the paths that bypass the chokepoint, rather than instrumenting them ad hoc.** Some failure paths exit before the chokepoint is even defined, or have a stricter output contract than the chokepoint respects (see below). Trying to force them through the capture point can break their contract; the correct move is a comment at each bypass site naming why it's exempt, not a workaround.
5. **Verify every reader tolerates the new field before shipping into a live measurement window.** A ledger/log is usually read by more than one consumer (a report script, a test suite, a human `jq` one-liner); confirm each one uses key-presence access (`.get()`, `has()`) rather than key-set equality, so an additive field can't break them.

Generic shell shape:

```sh
# chokepoint every failure path already calls
note_failure() {  # $1 phase, $2 detail
  [ "$1" = failed ] && CAPTURED_DETAIL="$2"
  ...existing status-write logic...
}

# single write site
write_record() {
  local reason=""
  if [ "$outcome" = failed ]; then
    if [ "${FLAG_A:-0}" = 1 ]; then reason=cause-a
    elif [ "${FLAG_B:-0}" = 1 ]; then reason=cause-b
    else reason=cause-unknown
    fi
  fi
  # reason is closed-enum; $CAPTURED_DETAIL rides along already-sanitized, never raw model/user bytes
  emit_json --arg reason "$reason" --arg detail "$CAPTURED_DETAIL" ...
}
```

pro-gate's concrete instance (pro-gate#144, shipped v0.40.0):

- `pg_status()` gained one capture line, `bin/oracle-review.sh:1756`: `[ "$phase" = failed ] && PG_FAIL_DETAIL="$detail"`. The comment directly above it, `bin/oracle-review.sh:1753-1755`, names the chokepoint explicitly: *"#143: every failure site calls `pg_status failed "<why>"` right before it exits, so this is the ONE chokepoint that sees the human-readable cause. Remember it for the ledger row; pg_finish otherwise wrote 311 exit-6 rows that were byte-identical after the fact."*
- `pg_finish()` (`bin/oracle-review.sh:2216`) gained a classifier at `bin/oracle-review.sh:2344-2368`, introduced by the comment at `2344-2348`: *"#143: classify a failed row from flags the run already set. `reason` is a CLOSED enum derived mechanically — never from model output, the prompt, or a URL — so it stays greppable and structurally cannot leak response bytes into the ledger."* The classifier itself (`2349-2368`):
  - `local reason="" fail_detail=""` (`2349`)
  - `if [ "$outcome" = failed ]; then` (`2350`) → `fail_detail="${PG_FAIL_DETAIL:-}"` (`2351`)
  - `_svc_restarted` → `reason=browser-restart` (`2352-2353`)
  - `SALVAGE_TERMINAL_INFRA` → `reason=infra-error` (`2354-2355`)
  - `SALVAGE_RAN`, sub-cased on `$fail_detail`'s text → `reason=refunded-unsubmitted` (`2358`, matches `*"round refunded"*`), `reason=fate-uncertain` (`2359`, matches `*"fate uncertain"*`), else `reason=salvage-empty` (`2360`)
  - `HARVEST` → `reason=harvest-failed` (`2362-2363`)
  - `RUN_MARKER` set with `attempt>0` → `reason=post-dispatch` (`2364-2365`), else `reason=pre-dispatch` (`2366-2367`)
  - Two new `--arg reason "$reason" --arg detail "$fail_detail"` additions to the existing `jq -nc` construction that builds the ledger line, and the matching printf fallback branch — no other field, no other write site, changed.
  - That replaced what would otherwise have been roughly 15 per-site edits (every `pg_finish 6` call site plus every bare `exit 6` site), for zero change to salvage, retry, refund, reservation, lock, or ramp behaviour.
- Both fields are empty-string, not absent, on every non-failed row — the comment at `bin/oracle-review.sh:2370-2372` states the precedent explicitly: *"v0.27: marker and round_key make every row independently recoverable. Failures before identity derivation carry empty values — present, not absent."* `reason`/`detail` follow the same convention the `marker`/`round_key` fields set in v0.27.

**The boundary that makes this a practice, not a trick.** `--recover`'s three `Browser needs attention` exits at `bin/oracle-review.sh:912`, `:914`, and `:919` — the three the in-file scope note names; the branch holds eight bare `exit 6` sites in all, measured 2026-09-04 — run entirely before the chokepoint exists: `pg_status()` isn't defined until `bin/oracle-review.sh:1749`, which is 830 lines later in the file than the last of those three exits. They exit bare (`exit 6`, never routed through `pg_finish`), so they write no ledger row at all — there is nothing for the classifier to see. They also promise a stricter contract than the rest of the engine: exactly one plain line on stderr, asserted by the test suite (`tests/engine.test.sh:4474-4476`, `'recover guard contention still prints exactly one plain state line'`, checking `wc -l` on stderr equals 1). A first draft of this change instrumented those three sites with `pg_status failed ...` to get them into the ledger too; the suite failed because `pg_status` isn't sourced/defined in that code path and the shell's `command not found` line leaked onto stderr as an unplanned second line, violating the one-line contract. That attempt was reverted. The scope comment now sitting at `bin/oracle-review.sh:908-911` records the decision: *"#143 scope note: these three exit-6 sites are out of the ledger's reach by design — --recover exits bare (never pg_finish), writes no ledger row, and runs before pg_status is even defined. Its one-plain-state-line stderr contract (asserted by the suite) must not grow a second line, so they stay undifferentiated here."* A chokepoint only covers the paths that actually flow through it; the practice includes naming, in a comment at the bypass site, the ones that do not — not silently leaving them unreasoned-about, and not forcing them through at the cost of a different contract.

**Verification that made it safe to ship into a live measurement window.** The ledger write (`pg_ledger_append "$line"`, `bin/oracle-review.sh:2395`, defined at `lib/pro-gate-lib.sh:1692`) is the last observable action `pg_finish` takes before its terminal `exit`, downstream of `pg_ramp_update` (called at `bin/oracle-review.sh:2337-2338`, defined at `lib/pro-gate-lib.sh:1727`) — and `pg_ramp_update` reads and writes only its own ramp state file (`ramp.state` under the runtime home), never the ledger, so adding fields to the ledger row cannot perturb the ramp governor. Every reader was checked before shipping:
- `scripts/pro-lane-report.py` (this repo) uses `row.get()` throughout its ledger scan (e.g. lines 164-165, 204, 208-209, 212-213), and its new reason-tally code at lines 214-222 explicitly handles rows written before the field existed: `key = row.get("reason") if "reason" in row else "(pre-v0.40, unclassified)"`. It never assumes key-set equality.
- `tests/engine.test.sh` asserts ledger shape with `has()` and per-field `jq -r`, never key-set equality: `tests/engine.test.sh:626` (`'happy-path ledger row carries pre_slot_secs + post_slot_secs'`, using `has(...)`) and `tests/engine.test.sh:628-629` (`'#143 clean ledger row carries empty reason and detail (present, not absent)'`, asserting `has("reason") and has("detail") and .reason == "" and .detail == ""`).
- The suite's never-landed (refunded) and landed-but-lost (charged) fixtures share exit code 6 and now assert DIFFERENT reasons — this is the entire point of the change. `tests/engine.test.sh:1307-1308` (`'#143 never-landed ledger row carries reason=refunded-unsubmitted'`) and `tests/engine.test.sh:1334-1338` (`'#143 landed-but-lost ledger row carries reason=salvage-empty (not the refund reason)'`, plus `'#143 two exit-6 rows with different fates carry different reasons'`, comparing `jq -r .reason` between the two fixture rows).

## Why This Matters

A ledger, log, or audit trail that only ever records *that* something failed — never *why*, when the "why" was known at the moment of failure — turns every retrospective into archaeology. 22% of a scarce, expensive resource (Pro oracle time, as measured 2026-09-04) sat unclassified for the ledger's entire history, not because the information didn't exist, but because it was computed once (for a human-facing status file) and then thrown away before the second consumer (the ledger) ever got a look. The fix cost one capture line and one classifier function; the alternative — instrumenting every failure call site individually — would have been roughly 15x the diff, with 15x the chances to miss a site, diverge in phrasing, or leak raw text into a field meant to be greppable. Concentrating the decision at the one chokepoint and the one write site is what makes the enum closed (auditable, greppable, safe to feed into automated summaries) instead of a grab-bag of ad hoc strings that happen to differ per call site.

## When to Apply

- A structured record (ledger row, log line, span, event) has an outcome/status field but no reason, and every producer of that outcome already computes a human-readable or flag-shaped cause immediately before it terminates or transitions.
- You're tempted to edit N call sites individually to add "why" information — that's the signal to instead find the shared function they all pass through.
- The record is read by more than one consumer (a report, a test suite, a human query) and you need confidence that adding a field won't break any of them.
- Some producers of the outcome genuinely bypass the shared function (different code path, different lifecycle stage, different output contract) — apply the pattern to the paths that flow through the chokepoint, and document the exceptions rather than force-fitting them.
- Do not apply this when the "why" needs to include free-form/untrusted content in the classified field itself (model output, user input, external text) — that content can ride along in a separate, already-sanitized string field, but the classification token must stay derived from engine-controlled flags only.

## Examples

Before (ledger row, exit 6, no way to distinguish causes):
```json
{"outcome":"failed","exit":6,"secs":42,"kind":"fresh","attempts":2,"salvaged":0,"out":"/path/o.md","marker":"pg-run-acme-91-...","round_key":"acme-91"}
```

After (pro-gate#144 / v0.40.0 — same failure class, now distinguishable):
```json
{"outcome":"failed","exit":6,"secs":42,"kind":"fresh","attempts":2,"salvaged":0,"out":"/path/o.md","marker":"pg-run-acme-91-...","round_key":"acme-91","reason":"salvage-empty","detail":"no usable review after salvage"}
```
And the sibling refunded case, same exit code, different reason:
```json
{"outcome":"failed","exit":6,"salvaged":0,"reason":"refunded-unsubmitted","detail":"round refunded — submission never landed"}
```
Non-failed rows carry the fields empty, not absent:
```json
{"outcome":"clean","exit":0,"reason":"","detail":""}
```

The one-line capture (`bin/oracle-review.sh:1756`, inside `pg_status()`):
```sh
[ "$phase" = failed ] && PG_FAIL_DETAIL="$detail"
```

The classifier shape (`bin/oracle-review.sh:2349-2368`, inside `pg_finish()`):
```sh
local reason="" fail_detail=""
if [ "$outcome" = failed ]; then
  fail_detail="${PG_FAIL_DETAIL:-}"
  if [ "${_svc_restarted:-0}" = 1 ]; then
    reason=browser-restart
  elif [ "${SALVAGE_TERMINAL_INFRA:-0}" = 1 ]; then
    reason=infra-error
  elif [ "${SALVAGE_RAN:-0}" = 1 ]; then
    case "$fail_detail" in
      *"round refunded"*)          reason=refunded-unsubmitted ;;
      *"fate uncertain"*)          reason=fate-uncertain ;;
      *)                           reason=salvage-empty ;;
    esac
  elif [ "${HARVEST:-0}" = 1 ]; then
    reason=harvest-failed
  elif [ -n "${RUN_MARKER:-}" ] && [ "${attempt:-0}" -gt 0 ]; then
    reason=post-dispatch
  else
    reason=pre-dispatch
  fi
fi
```

And the report reading it defensively (`scripts/pro-lane-report.py:218-222`):
```python
if row.get("outcome") != "failed":
    continue
key = row.get("reason") if "reason" in row else "(pre-v0.40, unclassified)"
key = key or "(empty)"
reasons[key] = reasons.get(key, 0) + 1
```
surfaced as `scripts/pro-lane-report.py:435`: `lines.append("failed by reason: " + ", ".join("%s=%d" % kv for kv in summary["reasons"].items()))`.

## Related

- `docs/solutions/best-practices/make-test-assertions-falsifiable-by-the-defect-they-guard.md` — the suite catching the leaked `pg_status: command not found` second line on `--recover`'s stderr (the reverted first draft, see Guidance above) is exactly a falsifiable assertion doing its job: `tests/engine.test.sh:4474-4476` pins a line count, not a substring match, so a real regression couldn't hide behind a passing `grep`.
- `docs/solutions/best-practices/verify-a-ledger-inferred-backlog-against-the-engines-state-surface.md` — `scripts/pro-lane-report.py` is the consumer of the new `reason` field; verifying it reads defensively (`.get()`, explicit pre-v0.40 fallback) before shipping is the same discipline that doc argues for when treating a ledger as an inferred backlog rather than the engine's authoritative state.
- pro-gate#143 (the tracking issue: 311 byte-identical failed rows, 181.5 hours unclassified, measured 2026-09-04) and pro-gate#144 (the shipped fix, merged as v0.40.0).
- dotfiles#990 — companion PR adding the `failed by reason:` line to the weekly pro-lane report (`scripts/pro-lane-report.py`), the first consumer of the new field, live-tested against the production ledger before the field existed everywhere (`(pre-v0.40, unclassified)=32` at merge time).
