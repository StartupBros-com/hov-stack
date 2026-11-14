"""cold-runs.py <runs.tsv> [threshold] - cold-cache runs and their predecessors.

Per model: how many runs wrote more than <threshold> cache-creation tokens
(default 18000), by arm; for each such run, whether a same-model run had finished
in the 300 s before it started; how many runs under the threshold had one; and,
per arm and task holding such a run, the median cache-creation and cache-read
difference between its runs over and under the threshold.
Backs section 2.4 of the 2026-11-14 eval note.
"""
import os
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runs import read_runlog  # noqa: E402


def main(runsf, thr):
    runs = read_runlog(runsf)
    print("runs=%d total_cost_usd=%.2f" % (len(runs), sum(r["cost_usd"] for r in runs)))
    for model in sorted({r["model"] for r in runs}):
        rs = sorted((r for r in runs if r["model"] == model), key=lambda r: r["start"])

        def warm_before(x):
            return any(r["end"] <= x["start"] and x["start"] - r["end"] <= 300 for r in rs if r is not x)

        cold = [r for r in rs if r["cache_creation"] > thr]
        print("\n== %s: %d runs, %d over %d" % (model, len(rs), len(cold), thr))
        for arm in sorted({r["arm"] for r in rs}):
            n = sum(1 for r in rs if r["arm"] == arm)
            c = sum(1 for r in cold if r["arm"] == arm)
            print("   %-22s cold %d/%d" % (arm, c, n))
        for r in cold:
            print(" cold %s %s %s r%d cache_creation=%d cache_read=%d cost=%.3f warm predecessor in 300 s: %s" % (
                r["id"], r["arm"], r["task"], r["rep"], r["cache_creation"], r["cache_read"], r["cost_usd"],
                warm_before(r)))
        rest = [r for r in rs if r["cache_creation"] <= thr]
        print(" runs under the threshold with a warm predecessor: %d/%d" % (
            sum(1 for r in rest if warm_before(r)), len(rest)))
        # Within one arm and task: median of the runs over the threshold minus median of
        # the runs under it, for cache creation and cache reads.
        for arm, task in sorted({(r["arm"], r["task"]) for r in cold}):
            cell = [r for r in rs if r["arm"] == arm and r["task"] == task]
            hi = [r for r in cell if r["cache_creation"] > thr]
            lo = [r for r in cell if r["cache_creation"] <= thr]
            if not lo:
                print(" cell %s %s: %d over, none under" % (arm, task, len(hi)))
                continue
            print(" cell %s %s: %d over, %d under, creation %+d, reads %+d" % (
                arm, task, len(hi), len(lo),
                st.median(r["cache_creation"] for r in hi) - st.median(r["cache_creation"] for r in lo),
                st.median(r["cache_read"] for r in hi) - st.median(r["cache_read"] for r in lo)))


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: cold-runs.py <runs.tsv> [threshold]")
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) == 3 else 18000)
