"""eval-warm.py <runs.tsv> <grade.json> - apply warm-cache-batch.md's pass condition.

Thresholds are the ones written before batch 4 launched: a scored run with more
than 18,000 cache-creation tokens is cold and makes its cell invalid; in each valid
cell a9's median cost is at most 1.10 times a3's, a9's median turns at most a3's
plus 2, and both arms pass the hidden checks 3 of 3. PASS needs all five cells
valid and passing. Warm-ups (a1-bare) are reported and not scored.
"""
import json
import os
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runs import read_runlog  # noqa: E402

COLD = 18000
CELLS = [("sonnet", "t1"), ("sonnet", "t2"), ("sonnet", "t3"), ("opus", "t2"), ("opus", "t3")]


def main(runsf, gradef):
    hidden = {g["id"]: bool(g.get("hidden_pass")) for g in json.load(open(gradef, encoding="utf-8"))}
    runs = read_runlog(runsf)
    print("runs=%d total_cost_usd=%.2f (warm-ups included)" % (len(runs), sum(r["cost_usd"] for r in runs)))
    for r in runs:
        if r["base"] == "a1-bare":
            print("warm-up %s %s %s cache_creation=%d cost=%.3f" % (
                r["id"], r["family"], r["task"], r["cache_creation"], r["cost_usd"]))
    overall = True
    for fam, task in CELLS:
        inc = [r for r in runs if r["family"] == fam and r["task"] == task and r["base"] == "a3-incumbent"]
        trm = [r for r in runs if r["family"] == fam and r["task"] == task and r["base"] == "a9-trimmed"]
        cold = [r["id"] for r in inc + trm if r["cache_creation"] > COLD]
        valid = len(inc) == 3 and len(trm) == 3 and not cold
        mi, mt = st.median(r["cost_usd"] for r in inc), st.median(r["cost_usd"] for r in trm)
        ti, tt = st.median(r["num_turns"] for r in inc), st.median(r["num_turns"] for r in trm)
        hid = (sum(hidden.get(r["id"], False) for r in inc), sum(hidden.get(r["id"], False) for r in trm))
        ok = valid and mt <= 1.10 * mi and tt <= ti + 2 and hid == (3, 3)
        overall = overall and ok
        print("%s %s: valid=%s cold=%s cost a3=%.4f a9=%.4f ratio=%.3f turns a3=%s a9=%s hidden=%d/3,%d/3 -> %s" % (
            fam, task, valid, cold, mi, mt, mt / mi, ti, tt, hid[0], hid[1],
            "pass" if ok else ("invalid" if not valid else "fail")))
        for r in inc + trm:
            print("   %-13s r%d %s cost=%.4f turns=%d cache_creation=%d hidden=%s" % (
                r["base"], r["rep"], r["id"], r["cost_usd"], r["num_turns"], r["cache_creation"],
                hidden.get(r["id"], False)))
    print("OVERALL: %s" % ("PASS" if overall else "FAIL"))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: eval-warm.py <runs.tsv> <grade.json>")
    main(sys.argv[1], sys.argv[2])
