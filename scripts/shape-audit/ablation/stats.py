#!/usr/bin/env python3
"""Exact statistics for the ablation. Fisher's exact test, stdlib only."""
import json, glob, os, collections
from math import comb

ROOT = os.path.dirname(os.path.abspath(__file__))


def fisher_2x2(a, b, c, d):
    """Two-tailed Fisher exact p for [[a,b],[c,d]]."""
    n = a + b + c + d
    r1, r2 = a + b, c + d
    c1 = a + c

    def prob(x):
        y, z, w = r1 - x, c1 - x, r2 - (c1 - x)
        if min(y, z, w) < 0:
            return 0.0
        return comb(r1, x) * comb(r2, z) / comb(n, c1)

    obs = prob(a)
    lo, hi = max(0, c1 - r2), min(r1, c1)
    return min(1.0, sum(prob(x) for x in range(lo, hi + 1) if prob(x) <= obs + 1e-12))


def load():
    rows = []
    for fp in glob.glob(os.path.join(ROOT, "results_*.jsonl")):
        for line in open(fp):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    return rows


def main():
    rows = load()
    # exclude harness errors (rc!=0 or verdict NONE with an is_error raw)
    clean = []
    for r in rows:
        if r["verdict"] == "NONE":
            raw = os.path.join(ROOT, "logs",
                               f"{r['task']}__{r['arm']}__{r['model']}__r{r['rep']}.raw.json")
            try:
                if json.load(open(raw)).get("is_error"):
                    continue  # harness failure, not a behavioral choice
            except Exception:
                pass
        clean.append(r)
    excluded = len(rows) - len(clean)
    print(f"loaded {len(rows)} runs, {len(clean)} kept, {excluded} excluded as harness errors")
    if excluded == 0:
        print("  NOTE: exclusion reads ablation/logs/*.raw.json, which is not committed.\n"
              "  With no logs/ present nothing is ever excluded -- prefer final_score.py.\n")

    agg = collections.defaultdict(collections.Counter)
    for r in clean:
        agg[(r["model"], r["task"], r["arm"])][r["verdict"]] += 1

    for model in sorted(set(r["model"] for r in clean)):
        for task in sorted(set(r["task"] for r in clean if r["model"] == model)):
            print("=" * 78)
            print(f"model={model}  task={task}")
            print("=" * 78)
            cell = {}
            for arm in ("A_none", "B_full", "C_rule"):
                c = agg[(model, task, arm)]
                n = sum(c.values())
                if not n:
                    continue
                cell[arm] = (c["GOOD"], n)
                print(f"  {arm:7s}  {c['GOOD']}/{n} compliant "
                      f"({100*c['GOOD']/n:5.1f}%)   BAD={c['BAD']}  NONE={c['NONE']}")
            for x, y, label in (("A_none", "B_full", "attribution: does the file cause it?"),
                                ("A_none", "C_rule", "attribution: does the rule alone cause it?"),
                                ("B_full", "C_rule", "dilution: does the bulk weaken the rule?")):
                if x in cell and y in cell:
                    gx, nx = cell[x]
                    gy, ny = cell[y]
                    p = fisher_2x2(gx, nx - gx, gy, ny - gy)
                    delta = 100 * (gy / ny - gx / nx)
                    mark = "  <-- SIGNIFICANT" if p < 0.05 else ""
                    print(f"    {x} vs {y}: {delta:+6.1f}pp   Fisher p={p:.4f}"
                          f"   [{label}]{mark}")
            print()

    tot = sum(r["cost_usd"] or 0 for r in rows)
    print(f"total spend across all runs: ${tot:.2f} ({len(rows)} runs)")


if __name__ == "__main__":
    main()
