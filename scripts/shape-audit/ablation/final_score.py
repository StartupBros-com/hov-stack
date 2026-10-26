#!/usr/bin/env python3
"""Final scoring: corrected detectors, segmented BY MODEL.

rescore.py collapsed sonnet and opus into one bucket. That matters enormously here:
the Sonnet and Opus results for the worktree rule point in opposite directions.
"""
import os, json, glob, collections, importlib.util
from math import comb

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rs", os.path.join(ROOT, "rescore.py"))
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)


def fisher(a, b, c, d):
    return rs.fisher(a, b, c, d)


def main():
    agg = collections.defaultdict(collections.Counter)
    for fp in sorted(glob.glob(os.path.join(ROOT, "sweep_logs", "*.tools.json"))):
        base = os.path.basename(fp)[:-len(".tools.json")]
        rule, arm, model, rep = base.split("__")
        v, _ = rs.DET[rule](json.load(open(fp)))
        agg[(model, rule, arm)][v] += 1

    models = sorted({k[0] for k in agg})
    rules = ["astgrep", "conventional", "tests", "worktree", "worktree_remote"]

    for model in models:
        print("=" * 92)
        print(f"MODEL = {model}   (corrected detectors)")
        print("=" * 92)
        for rule in rules:
            cells = {a: agg[(model, rule, a)] for a in ("A_none", "B_full", "C_rule")
                     if sum(agg[(model, rule, a)].values())}
            if not cells:
                continue
            print(f"\n  {rule}")
            for arm, c in cells.items():
                n = sum(c.values())
                print(f"    {arm:7s} GOOD {c['GOOD']}/{n}  BAD {c['BAD']}  NONE {c['NONE']}")
            if "A_none" in cells and "B_full" in cells:
                a, b = cells["A_none"], cells["B_full"]
                na, nb = sum(a.values()), sum(b.values())
                p = fisher(a["GOOD"], na - a["GOOD"], b["GOOD"], nb - b["GOOD"])
                verdict = ("LOAD-BEARING" if p < 0.05 and b["GOOD"] > a["GOOD"]
                           else "REDUNDANT (baseline already complies)"
                           if a["GOOD"] / max(1, na) >= 0.8
                           else "NO EFFECT / inconclusive")
                print(f"    A_none vs B_full: p={p:.4f}   -> {verdict}")
            if "B_full" in cells and "C_rule" in cells:
                b, c = cells["B_full"], cells["C_rule"]
                # Use the REAL per-arm totals. Hardcoding 5 silently produced wrong
                # fractions and p-values for every cell run with reps != 5 (opus
                # astgrep/conventional ran 10).
                nb, nc = sum(b.values()), sum(c.values())
                p = fisher(b["BAD"], nb - b["BAD"], c["BAD"], nc - c["BAD"])
                print(f"    dilution (violation rate B {b['BAD']}/{nb} vs "
                      f"C {c['BAD']}/{nc}): p={p:.4f}"
                      f"{'  <-- SIG' if p < 0.05 else ''}")
        print()

    print("=" * 92)
    print("CROSS-MODEL: worktree_remote — the finding that did NOT replicate")
    print("=" * 92)
    for model in models:
        c = {a: agg[(model, "worktree_remote", a)] for a in ("A_none", "B_full", "C_rule")}
        if not sum(c["A_none"].values()):
            continue
        print(f"  {model:8s} A_none GOOD {c['A_none']['GOOD']}/5 | "
              f"B_full GOOD {c['B_full']['GOOD']}/5 (BAD {c['B_full']['BAD']}) | "
              f"C_rule GOOD {c['C_rule']['GOOD']}/5 (BAD {c['C_rule']['BAD']})")


if __name__ == "__main__":
    main()
