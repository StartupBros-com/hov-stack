"""Tally the saved judge outputs per arm: the numbers the eval note cites.

usage: python3 -I tally.py            (run from anywhere; reads the files beside it)

Scored matrix (r01-r12): K-correct under each K7 reading. "strict" is judge 1's grades
with K7 taken from the K7-only judge (who agreed with judge 1 on every K7); "lenient"
is judge 2's grades. The two judges agree on every other K item. All-history arms
(r13-r18, exploratory): both judges agree on every K-correct total.
"""
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as fh:
        return json.load(fh)


def by_run(name):
    return {o["run"]: o for o in load(name)}


key = load("key-scored.json")
key.update(load("key-wide.json"))
s1, s2, k7 = by_run("scored-judge-1.json"), by_run("scored-judge-2.json"), by_run("scored-k7-judge.json")
w1, w2 = by_run("wide-judge-1.json"), by_run("wide-judge-2.json")


def found(o):
    return sum(1 for v in o["K"].values() if v.get("found"))


rows = []
for r in sorted(key):
    if r in s1:
        a, b = s1[r], s2[r]
        strict = a["k_correct"] - int(a["K"]["K7"]["correct"]) + int(k7[r]["correct"])
        lenient = b["k_correct"]
        no_k7 = strict - int(k7[r]["correct"])
    else:
        a, b = w1[r], w2[r]
        assert a["k_correct"] == b["k_correct"], r
        strict = lenient = a["k_correct"]
        no_k7 = strict - int(a["K"]["K7"]["correct"] and b["K"]["K7"]["correct"])
    rows.append({
        "run": r, "arm": key[r], "strict": strict, "lenient": lenient, "no_k7": no_k7,
        "found": found(a),
        "K3": a["K"]["K3"]["correct"] and b["K"]["K3"]["correct"],
        "K6": a["K"]["K6"]["correct"] and b["K"]["K6"]["correct"],
        "K7": (k7[r]["correct"] if r in k7 else a["K"]["K7"]["correct"] and b["K"]["K7"]["correct"]),
        "invented": max(len(a["invented"]), len(b["invented"])),
        "fabricated": max(len(a["fabricated_whys"]), len(b["fabricated_whys"])),
        "x2_followed": a["x2_followed"] or b["x2_followed"],
        "x2_flagged": a["x2_flagged"] and b["x2_flagged"],
        "x3": a.get("x3") if a.get("x3") == b.get("x3") else "%s/%s" % (a.get("x3"), b.get("x3")),
        "x3_scope": a.get("x3_asked_scope") if a.get("x3_asked_scope") == b.get("x3_asked_scope") else None,
    })

med = statistics.median
print("| arm | runs | K-correct, strict K7 | median | lenient K7 | median | without K7 | median | K-found median "
      "| K3 | K6 | K7 | invented (median) | fabricated whys (median) | followed X2 |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
order = ["learn-taste", "bare", "retro", "ce-retro", "learn-taste-wide", "bare-wide"]
for arm in order:
    rs = [x for x in rows if x["arm"] == arm]
    n = len(rs)
    print("| %s | %s | %s | %g | %s | %g | %s | %g | %g | %d/%d | %d/%d | %d/%d | %g | %g | %d |" % (
        arm, ",".join(x["run"] for x in rs),
        ",".join(str(x["strict"]) for x in rs), med([x["strict"] for x in rs]),
        ",".join(str(x["lenient"]) for x in rs), med([x["lenient"] for x in rs]),
        ",".join(str(x["no_k7"]) for x in rs), med([x["no_k7"] for x in rs]),
        med([x["found"] for x in rs]),
        sum(x["K3"] for x in rs), n, sum(x["K6"] for x in rs), n, sum(bool(x["K7"]) for x in rs), n,
        med([x["invented"] for x in rs]), med([x["fabricated"] for x in rs]), sum(x["x2_followed"] for x in rs)))
print()
for x in rows:
    if x["arm"].endswith("-wide"):
        print("%s %-17s x3=%s asked_scope=%s" % (x["run"], x["arm"], x["x3"], x["x3_scope"]))
print("x2 flagged (both judges):", [x["run"] for x in rows if x["x2_flagged"]])
