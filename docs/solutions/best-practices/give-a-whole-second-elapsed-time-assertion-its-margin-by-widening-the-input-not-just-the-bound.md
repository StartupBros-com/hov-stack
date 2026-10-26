---
title: "Give a whole-second elapsed-time assertion its margin by widening the input, not just the bound"
date: "2026-09-17"
category: best-practices
module: dispatcher-tick-tests
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A shell test measures elapsed time with date +%s (whole seconds) and asserts it stays under a bound"
  - "The bound sits within about a second of the time a wrong implementation would take"
  - "The suite runs on a shared self-hosted runner where several jobs contend for one small host"
  - "A planted negative proves a hang is bounded by timeout, so the assertion must still fail the unbounded implementation"
symptoms:
  - "A CI shard goes red with 171 of 172 assertions passing and the failing one reads 'tick took 12s, expected bounded near the ~11s ceiling'"
  - "The same test passes on every local run and on the next re-run of the same commit"
related_components:
  - "dispatcher-tick"
  - "harness-tests-ci"
tags:
  - flaky-test
  - timing-assertion
  - planted-negative
  - ci-runner-load
  - date-quantization
---

# Give a whole-second elapsed-time assertion its margin by widening the input, not just the bound

> **Retired machinery (2026-10-18).** The dispatcher was removed by #1873 (teardown move 3, 2026-10-17), and `tests/dispatcher-tick.test.sh` (T28) and `dispatcher-tick.sh` no longer exist. The example is history only. The lesson still holds for any whole-second timing assertion on a shared runner.

## Context

T28 in `tests/dispatcher-tick.test.sh` proves that a hung health check is bounded by `timeout`: the ceiling is `PRO_LANE_DOCTOR_TIMEOUT=1` plus the script's fixed 10-second margin, the stub health check slept 12 seconds, and the assertion was elapsed under 12 seconds, measured with `date +%s` before and after the tick. That leaves one second between the correct path (about 11 seconds) and the wrong path (the full 12-second sleep). On 2026-09-17 the assertion flipped twice on the shared CI runner, once on the run for PR #1186 and once on a re-run for PR #1188, with every other assertion in the suite passing. Whole-second timestamps can round an 11.x-second run up to 12, and a loaded runner adds tick overhead on top.

## Guidance

Move the two outcomes apart at the input, then place the bound between them with margin on the side that matters:

1. Make the wrong implementation slower: raise the stub's sleep well past the ceiling (12 to 20 seconds here).
2. Set the bound between the correct time plus realistic overhead and the wrong time (16 seconds here: five seconds above the 11-second ceiling, four seconds below the 20-second sleep).
3. Verify both sides before merging. Remove the `timeout` wrapper in a scratch copy and confirm the test measures the full sleep and fails; run the correct implementation several times and confirm the measurement sits at the ceiling.
4. Record the reason in the test next to the numbers, so nobody shortens the sleep back "to make the test faster".

Widening only the bound is the tempting one-line change and it is the wrong one: with a 12-second wrong path and a 16-second bound, the unbounded implementation passes and the planted negative stops being falsifiable.

## Why This Matters

A timing assertion is a threshold over a quantity that runner load moves. The exit code hides how close the quantity sits to the line, so a suite can be green for weeks and then block unrelated merges the day the runner is busy. Here it blocked two unrelated PRs in one afternoon and cost three re-runs before the fix landed as PR #1195. The fix keeps the guarantee the test exists for, that a hang is cut at the ceiling, while making the measurement robust to the second of noise the environment adds.

## When to Apply

- Any assertion that compares `date +%s` differences, or any integer-second clock, against a bound.
- Any bound within about one second of the time a wrong implementation would take.
- Any suite that runs on the shared runner pool, where several jobs and the host's other work contend for CPU.

## Examples

Before:

```bash
export PRO_LANE_HEALTH_SLEEP=12    # longer than the ~11s ceiling above
...
[ "$T28_ELAPSED" -lt 12 ] && ok || bad "tick took ${T28_ELAPSED}s ..."
```

After (PR #1195):

```bash
export PRO_LANE_HEALTH_SLEEP=20    # well past the ~11s ceiling above
...
[ "$T28_ELAPSED" -lt 16 ] && ok || bad "tick took ${T28_ELAPSED}s ... not the full 20s stub sleep ..."
```

Measured while verifying: the correct implementation read 11 seconds on four runs; with the `timeout` wrapper removed in a scratch copy it read 20 and failed.

## Related

- `docs/solutions/best-practices/make-test-assertions-falsifiable-by-the-defect-they-guard.md`: the bound must still fail the defect; this note is about keeping that property under timing noise.
- PR #1195.
