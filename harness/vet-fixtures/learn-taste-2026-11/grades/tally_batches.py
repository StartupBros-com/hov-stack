"""Tally a later grading batch: both full judges, the K7-only judge, the key.

usage: python3 -I tally_batches.py reflect|added      (reads the files beside it)

reflect: packets r31-r36, claude-reflect r20-r22 plus drift re-grades of r07, r03, r01
         (seed 20261117). added: packets r51-r59, self-review and context-lens r40-r45
         plus drift re-grades of r09, r04, r11 (seed 20261118). Drift rows are reported,
         never re-scored.
"""
import json, os, statistics, sys

d = os.path.dirname(os.path.abspath(__file__))
ld = lambda n: json.load(open(os.path.join(d, n), encoding="utf-8"))
batch = sys.argv[1]
key = ld("key-%s.json" % batch)
A = {o["run"]: o for o in ld("%s-judge-a.json" % batch)}
B = {o["run"]: o for o in ld("%s-judge-b.json" % batch)}
K7 = {o["run"]: o for o in ld("%s-k7-judge.json" % batch)}
assert set(A) == set(B) == set(K7) == set(key), (sorted(A), sorted(B), sorted(K7), sorted(key))

rows = []
for r in sorted(key):
    a, b, k = A[r], B[r], K7[r]
    for o in (a, b):
        assert o["k_correct"] == sum(int(v["correct"]) for v in o["K"].values()), (r, "k_correct mismatch")
    split = [i for i in a["K"] if a["K"][i]["correct"] != b["K"][i]["correct"]]
    # strict: judge A's grades with K7 from the K7-only judge; lenient: judge B's as given
    other = lambda o: o["k_correct"] - int(o["K"]["K7"]["correct"])
    rows.append({"run": r, "arm": key[r], "a": a["k_correct"], "b": b["k_correct"],
                 "a_k7judge": other(a) + int(k["correct"]), "b_k7judge": other(b) + int(k["correct"]),
                 "no_k7_a": other(a), "no_k7_b": other(b),
                 "found_a": sum(int(v["found"]) for v in a["K"].values()),
                 "found_b": sum(int(v["found"]) for v in b["K"].values()),
                 "K3": (a["K"]["K3"]["correct"], b["K"]["K3"]["correct"]),
                 "K6": (a["K"]["K6"]["correct"], b["K"]["K6"]["correct"]),
                 "K7": (a["K"]["K7"]["correct"], b["K"]["K7"]["correct"], k["correct"]),
                 "invented": (len(a["invented"]), len(b["invented"])),
                 "fabricated": (len(a["fabricated_whys"]), len(b["fabricated_whys"])),
                 "x2": (a["x2_followed"], b["x2_followed"], a["x2_flagged"], b["x2_flagged"]),
                 "dest": (a["t2_destination"], b["t2_destination"]),
                 "split": split, "inv_ids": [x["id"] for x in a["invented"]] + ["|"] + [x["id"] for x in b["invented"]]})

print("| run | arm | K-correct A | B | A w/ K7 judge | B w/ K7 judge | w/o K7 A/B | found A/B | K3 A/B | K6 A/B | K7 A/B/K7j "
      "| invented A/B | fabricated A/B | X2 followed A/B, flagged A/B | t2 dest | items split |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for x in rows:
    print("| %s | %s | %d | %d | %d | %d | %d/%d | %d/%d | %s | %s | %s | %s %s | %d/%d | %s | %s | %s |" % (
        x["run"], x["arm"], x["a"], x["b"], x["a_k7judge"], x["b_k7judge"], x["no_k7_a"], x["no_k7_b"],
        x["found_a"], x["found_b"], x["K3"], x["K6"], x["K7"], x["invented"], x["inv_ids"],
        x["fabricated"][0], x["fabricated"][1], x["x2"], x["dest"], ",".join(x["split"]) or "-"))
med = statistics.median
arms = sorted({x["arm"].rsplit(" ", 1)[0] for x in rows if "(drift)" not in x["arm"]})
print()
for arm in arms:
    cr = [x for x in rows if x["arm"].rsplit(" ", 1)[0] == arm]
    for f in ("a", "b", "a_k7judge", "b_k7judge", "no_k7_a", "no_k7_b", "found_a", "found_b"):
        print("%s median %-10s %g  (%s)" % (arm, f, med([x[f] for x in cr]), ",".join(str(x[f]) for x in cr)))
    print("%s median invented A/B %g/%g" % (arm, med([x["invented"][0] for x in cr]), med([x["invented"][1] for x in cr])))
    print("%s median fabricated A/B %g/%g" % (arm, med([x["fabricated"][0] for x in cr]), med([x["fabricated"][1] for x in cr])))
