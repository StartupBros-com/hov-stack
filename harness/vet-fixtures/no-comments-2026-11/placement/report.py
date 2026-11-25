#!/usr/bin/env python3
"""report.py <graded.json> [judged.json] - tables for the placement test, per model."""
import collections
import json
import statistics
import sys

rows = json.load(open(sys.argv[1]))
judged = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
ARMS = ["comment", "none", "tests", "doc", "claudemd", "history", "stale"]
TRAPS = ["fileorder", "always", "addrule"]


def cell(rs, pred):
    rs = [r for r in rs if r["finished"] and r["done"]["result"] == "correct"]
    return f"{sum(1 for r in rs if pred(r))}/{len(rs)}"


for model in sorted({r["model"] for r in rows}):
    mr = [r for r in rows if r["model"] == model]
    fin = [r for r in mr if r["finished"]]
    print(f"\n================ {model}: {len(fin)}/{len(mr)} finished, errors {sum(1 for r in mr if r.get('error'))}, "
          f"served by {sorted({m for r in fin for m in r['models']})}, cost ${sum(r['cost'] or 0 for r in fin):.2f}")
    print("\nrequest delivered (done probe) / make check green, all tasks")
    for arm in ARMS:
        a = [r for r in fin if r["arm"] == arm]
        if a:
            print(f"  {arm:9} delivered {sum(1 for r in a if r['done']['result'] == 'correct')}/{len(a)}  "
                  f"check green {sum(1 for r in a if r['check'])}/{len(a)}")
    print("\ntrap tasks: decision kept (runs that delivered the request)")
    print(f"  {'arm':9} " + " ".join(f"{t:>10}" for t in TRAPS) + f" {'pooled':>8} | addrule order / case")
    for arm in ARMS:
        a = [r for r in mr if r["arm"] == arm and r["task"] in TRAPS]
        if not a:
            continue
        per = " ".join(f"{cell([r for r in a if r['task'] == t], lambda r: r['kept']):>10}" for t in TRAPS)
        ar = [r for r in a if r["task"] == "addrule"]
        print(f"  {arm:9} {per} {cell(a, lambda r: r['kept']):>8} | "
              f"{cell(ar, lambda r: r['keep']['addrule_keep_order']['result'] == 'correct')} / "
              f"{cell(ar, lambda r: r['keep']['addrule_keep_case']['result'] == 'correct')}")
    print("\ntrap tasks: record consulted (asked) / decision text shown in any tool result")
    for arm in ARMS:
        a = [r for r in fin if r["arm"] == arm and r["task"] in TRAPS]
        if not a:
            continue
        c = [r["consulted"] for r in a]
        print(f"  {arm:9} n={len(a)} asked docs {sum(x['asked_docs'] for x in c)} history {sum(x['asked_history'] for x in c)} "
              f"decisions-test {sum(x['asked_decisions_test'] for x in c)} | shown docs {sum(x['shown_docs'] for x in c)} "
              f"history {sum(x['shown_history'] for x in c)} decisions-test {sum(x['shown_decisions_test'] for x in c)} "
              f"fact {sum(x['shown_fact'] for x in c)} | left repo {sum(x['left_repo'] for x in c)}")
    print("\ncollateral: other decisions broken, any task")
    for arm in ARMS:
        a = [r for r in fin if r["arm"] == arm]
        bad = collections.Counter(k for r in a for k in r["collateral_broken"])
        if a:
            print(f"  {arm:9} runs with any {sum(1 for r in a if r['collateral_broken'])}/{len(a)} {dict(bad)}")
    print("\ncost: median dollars and turns by task kind")
    for arm in ARMS:
        a = [r for r in fin if r["arm"] == arm]
        if not a:
            continue
        parts = []
        for kind, tasks in (("control", ["version", "cats"]), ("trap", TRAPS), ("conflict", ["pending", "negative"])):
            k = [r for r in a if r["task"] in tasks]
            if k:
                parts.append(f"{kind} ${statistics.median(r['cost'] for r in k):.3f} / {statistics.median(r['turns'] for r in k):.0f}t (n={len(k)})")
        print(f"  {arm:9} " + " | ".join(parts))
    if judged:
        print("\nfinal message names the project's own reason (both judges yes / either yes / n)")
        for kind, tasks in (("conflict", ["pending", "negative"]), ("trap, decision broken", TRAPS)):
            print(f"  -- {kind}")
            for arm in ARMS:
                a = [r for r in fin if r["arm"] == arm and r["task"] in tasks and r["id"] in judged
                     and (kind == "conflict" or r["kept"] is False)]
                if not a:
                    continue
                both = sum(1 for r in a if all(j["names_reason"] for j in judged[r["id"]]))
                either = sum(1 for r in a if any(j["names_reason"] for j in judged[r["id"]]))
                per = " ".join(f"{t}:{sum(1 for r in a if r['task'] == t and all(j['names_reason'] for j in judged[r['id']]))}/{sum(1 for r in a if r['task'] == t)}" for t in tasks)
                print(f"     {arm:9} {both} / {either} / {len(a)}   {per}")
