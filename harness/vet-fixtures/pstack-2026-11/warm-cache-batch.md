# Batch 4: warm-cache cost retest (pass condition written before launch)

Written 2026-11-14, before any batch-4 run started. Nothing below was changed after
the runs began; the results are reported in the eval note against this text.

## Why

Batches 1 to 3 launched runs four at a time. A run that starts while no run on the same
model has finished in the previous five minutes writes the whole prompt prefix to the
cache: 20k to 26k cache-creation tokens instead of 8k to 15k. That cost lands on whichever
arm the launch order puts in a batch's first wave. In batches 2 and 3 it hit 6 of 24 Opus
runs, all first-wave (incumbent 0 of 6, port 2 of 6, trimmed port 3 of 6), and 18 of 18
non-spike Opus runs had a warm predecessor. So "cost per run", the predeclared
countermetric, could not separate the rule text from launch order.

No noise band was predeclared for batches 1 to 3. Read literally, the port variants fail
the cost countermetric in some cells there, and that record stands. This batch does not
replace it. It asks one question: with every scored run on a warm cache, does the trimmed
port cost more per run than the incumbent?

## Design

- Arms: `a3-incumbent` and `a9-trimmed`, unchanged from batches 1 to 3.
- Cells: Sonnet t1, t2, t3; Opus t2, t3. Three reps per arm per cell: 30 scored runs.
- Two warm-up runs, `a1-bare` on t3, one per model, run first in each model's block and
  discarded.
- One run at a time (`launch-seq.sh`), Opus block then Sonnet block. Within a cell the
  arms alternate, incumbent first: a3 r1, a9 r1, a3 r2, a9 r2, a3 r3, a9 r3.
- Fresh scratch root, the same `run_arm.sh`, the same `grade.py`.

## Pass condition

1. Validity: a scored run with more than 18,000 cache-creation tokens is cold. A cell
   holding a cold run is reported as invalid. No run is re-run selectively.
2. Cost: in each valid cell, the median `total_cost_usd` of `a9-trimmed` is at most 1.10
   times the incumbent's median in the same cell.
3. Turns: in each valid cell, the median `num_turns` of `a9-trimmed` is at most the
   incumbent's median plus 2.
4. Hidden checks: both arms pass the hidden tests in 3 of 3 runs of every cell.

PASS needs all five cells valid and passing 2, 3 and 4. Any other outcome leaves the cost
countermetric failed, and the proposal carries that.

The primary metrics (fix location on t2, root-fix class on t3, false deletions on t1) are
reported for this batch beside batches 1 to 3. They are not part of this pass condition;
the primary result rests on batches 1 to 3.
