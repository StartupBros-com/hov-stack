---
title: "A fail-closed gate on monotonically degrading input becomes a permanent latch"
date: "2026-09-08"
category: logic-errors
module: cass-release-promote
problem_type: logic_error
component: development_workflow
symptoms:
  - "A release-promotion gate refuses the same candidate every night for a week, always at the same read-only smoke step"
  - "The gate's own verdict correctly says the fault is environmental, not the candidate's, and refuses anyway"
  - "The refused candidate is the release that fixes the condition causing the refusal"
  - "No retry, wait, or human action clears the block, because the blocking input can only get worse"
  - "A shared-runtime fault (rc=1, indeterminate) is routed into the same fail-and-exit path as a genuine candidate refusal (rc=2)"
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - "cass-release-promote.sh"
  - "cass-cli"
  - "quill-lexical-index"
  - "coding_agent_session_search#441"
  - "coding_agent_session_search#403"
tags:
  - fail-closed
  - self-latching-gate
  - release-promotion
  - smoke-test
  - candidate-attributable
  - advisory-vs-blocking
  - hermetic-isolation
  - monotonic-degradation
---

# A fail-closed gate on monotonically degrading input becomes a permanent latch

## Problem

`scripts/cass-release-promote.sh` is the verified, candidate-first promotion lane for the `cass` binary. Its read-only smoke refused candidate `v0.7.1` on every nightly run from roughly 2026-08-31 through 2026-09-07 — and `v0.7.1` was the release carrying the fix for the exact condition causing the refusal. The broken input blocked the upgrade that repaired the broken input, and because that input only degrades, the gate could never clear itself.

## Symptoms

```
cass: candidate v0.7.1@19336ea7... (cass-linux-amd64.tar.gz)
     archive checksum verified: 9f8201a2...
    smoke step FAILED: search probe (exit 9)
    output: scalar Quill query fuel exhausted after 10000000/10000000 units
            (segments=605, dictionary_blocks=9992030, ...)
FAIL — shared runtime fault (index lock, tunnel, or archive), NOT a candidate refusal
```

The gate diagnosed itself correctly every single night. Correct diagnosis did not help.

## What Didn't Work

- **Waiting.** The trigger is segment count on an append-only Quill index, which upstream describes as growing "monotonically on append-only archives, so it worsens daily" (`coding_agent_session_search#441`). Retrying a check whose input only degrades is not a recovery strategy.
- **Trusting the fault classification to be enough.** The script already split `reject()` (bad candidate) from `fail()` (broken promoter/environment), and correctly returned the environment class. But both paths still stopped the promotion, so the distinction bought diagnosis without buying a way out.
- **Making the live-archive checks purely advisory (first cut, `fc25b37`).** This removed the block but also removed the only operator-visible signal a wedged archive produced — a red unit. Review caught it; see Solution.

## Solution

PR #1050 (`fc25b37`, then `acb8526`; squash-merged as `d2e3e4f4`) changed *what the checks are pointed at*, not the pass/fail logic around them.

- `status` and `search` now run against a `mktemp -d` scratch `--db`, never the live archive. Upstream `#403` makes a scratch `--db` outside the default data dir carry its own lexical index, raw-mirror, checkpoints and locks, so the probe exercises the real code paths hermetically.
- Because those checks are now candidate-attributable, they return `2` (refuse) instead of `1` (environment error). The gating surface grew from two hermetic checks to four.
- The probe asserts `jq -e --arg d "$scratch" '.data_dir == $d'` to prove isolation actually held, rather than silently falling back to the live archive if `--db` isolation ever regresses.
- The live archive is still probed by a new `live_archive_advisory()`, but advisory **to the exit code only** — it still calls `say()` so a degraded archive still reaches the operator.
- `1` is now reserved for the promoter failing to *construct* the test (e.g. `mktemp` failing), not for degraded shared state.

Pinned by regression assertions across three suites: `cass-smoke-classification.test.sh` (a wedged live archive must not block promotion, and must still notify), `cass-smoke-diagnostics.test.sh` (scratch failures classify as `2`), and `cass-release-promote.test.sh`.

## Why This Works

The original checks were classified by *what invoked them* (a local binary call) rather than by *what they were coupled to* (shared, mutable, monotonically degrading state). `status` and `search` looked like candidate probes; their real dependency was live index health, which the candidate cannot influence.

Isolating the fixture makes the coupling match the classification. A scratch-db failure genuinely is the candidate's fault, so refusing on it is honest. A live-archive failure is not, so it informs without gating.

## Prevention

1. **Ask whether a check's input can only get worse.** Shared, append-only, or accumulating state — a growing index, an unrotated log, a lock never cleared — cannot be trusted to self-clear. Fail-closed is right for an input that can recover, and a latch for one that cannot.
2. **Look for circularity explicitly.** If the change a gate refuses is also the remedy for the condition causing the refusal, the gate has built its own permanent lock. Ask this of any gate guarding an *upgrade* path, where the candidate is disproportionately likely to be the fix.
3. **Give each gating check a hermetic fixture.** Isolate before you gate, so failure is attributable to the thing under test rather than ambient state it happens to touch. Assert the isolation held.
4. **Where a check must read live state, make it advisory but keep it loud.** Downgrading authority is not the same as deleting visibility; a degradation that reaches nobody is its own failure mode.
5. **Keep three outcomes distinct, not two:** the input is bad, the environment is degraded, and the gate could not construct its own test. Collapsing them discards the evidence a future run needs.

## Related Issues

- `fail-closed-self-updater-can-lock-itself-out` (memory) — the closest prior sibling and the same failure class: a self-updater whose repair path runs *through* the broken step can never install its own fix. That note is single-incident with an out-of-band manual remedy; this doc names the shape and supplies a structural fix.
- `fail-closed-on-every-input-gets-switched-off` (memory) — contrast: a gate refuses *every* input because of a wiring bug, and a human disables it. Here the gate is correct, the condition is real, and nobody disables it — it just never clears.
- `a-gate-that-cannot-compare-must-fail` (memory) — contrast: the opposite defect, a gate that *skips* and reads as a pass.
- `silent-fallback-tools-hide-outages` (memory) — why the fix keeps the live-archive check notifying rather than dropping it.
- `cass-lexical-fuel-exhaustion-empties-cass-rerank` (memory) — the same upstream root cause surfacing as a second, independent symptom.
- Upstream `Dicklesworthstone/coding_agent_session_search#441` (the degrading input) and `#403` (the `--db` isolation the fix depends on).
