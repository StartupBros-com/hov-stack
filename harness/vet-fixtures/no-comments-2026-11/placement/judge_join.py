"""judge_join.py <journal.jsonl> <graded.json> <judged.json> - join blind judge verdicts to runs and tabulate by arm."""
import collections
import json
import sys

journal, graded_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
judged = collections.defaultdict(list)
for line in open(journal, encoding="utf-8"):
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get("type") != "result":
        continue
    val = rec.get("result") or rec.get("value") or {}
    if isinstance(val, str):
        try:
            val = json.loads(val)
        except ValueError:
            continue
    for v in (val.get("verdicts") or []) if isinstance(val, dict) else []:
        judged[v["id"]].append({"names_reason": bool(v["names_reason"]), "quote": v.get("quote", ""),
                                "pushed_back": bool(v.get("pushed_back"))})
json.dump(judged, open(out, "w"), indent=1)
rows = {r["id"]: r for r in json.load(open(graded_path))}
print("judged ids", len(judged), "verdicts per id", dict(collections.Counter(len(v) for v in judged.values())))
print("judges disagree on names_reason:", [i for i, v in judged.items() if len({j["names_reason"] for j in v}) > 1])
print("pushed_back by any judge:", [(i, rows[i]["arm"], rows[i]["task"]) for i, v in judged.items() if any(j["pushed_back"] for j in v)])
ARMS = ["comment", "none", "tests", "doc", "claudemd", "history"]
print("\nconflict tasks, Sonnet: final message names the project's own reason (both judges) / runs")
print(f"  {'arm':9} {'pending':>8} {'negative':>9} {'pooled':>7}")
for arm in ARMS:
    cells = []
    tot = [0, 0]
    for task in ("pending", "negative"):
        ids = [i for i, r in rows.items() if r["arm"] == arm and r["task"] == task and i in judged]
        yes = sum(1 for i in ids if all(j["names_reason"] for j in judged[i]))
        cells.append(f"{yes}/{len(ids)}")
        tot[0] += yes
        tot[1] += len(ids)
    print(f"  {arm:9} {cells[0]:>8} {cells[1]:>9} {tot[0]}/{tot[1]:>3}")
print("\nper run:")
for i, r in sorted(rows.items(), key=lambda kv: (kv[1]["task"], ARMS.index(kv[1]["arm"]) if kv[1]["arm"] in ARMS else 9)):
    if i in judged:
        c = r["consulted"]
        print(f"  {r['task']:8} {r['arm']:9} {i} reason={[j['names_reason'] for j in judged[i]]} delivered={r['done']['result']} "
              f"shown_fact={c['shown_fact']} docs={c['shown_docs']} hist={c['asked_history']} dtest={c['shown_decisions_test']} | {judged[i][0]['quote'][:70]}")
