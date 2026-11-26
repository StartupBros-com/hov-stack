#!/usr/bin/env python3
"""record_upkeep.py <graded.json> <runs-root> - after a run changed a recorded decision, was the record updated?

Post hoc: this measure is not in prereg.md. Tasks where the record must change: pending and negative (the
request reverses the decision) and fileorder (the sort the record explains is removed). For each run it looks
at the final tree and reports whether the arm's record still carries a phrase from the old sentence, and
whether the record file was edited. A surviving phrase is a prompt to read the line, not a verdict: a
rewritten sentence can reuse the phrase and be true of the new code.
"""
import collections
import json
import os
import sys

rows = json.load(open(sys.argv[1]))
root = sys.argv[2]
OLD = {
    "pending": ["Skip pending rows", "pending rows are left out", "reports settled spending only"],
    "negative": ["keeps its sign in front", "post template expects"],
    "fileorder": ["groups consecutive rows", "relies on this order", "Sort by date"],
}
WHERE = {
    "comment": lambda repo: [os.path.join(dp, f) for dp, _d, fs in os.walk(os.path.join(repo, "tally")) for f in fs
                             if f.endswith(".py")],
    "doc": lambda repo: [os.path.join(dp, f) for dp, _d, fs in os.walk(os.path.join(repo, "docs")) for f in fs
                         if f.endswith(".md")],
    "claudemd": lambda repo: [os.path.join(repo, "CLAUDE.md")],
    "tests": lambda repo: [os.path.join(repo, "tests", "test_decisions.py")],
}
TOUCH = {"doc": "diff --git a/docs/", "claudemd": "diff --git a/CLAUDE.md", "tests": "diff --git a/tests/test_decisions.py"}
table = collections.defaultdict(collections.Counter)
left = []
for r in rows:
    if r["arm"] not in WHERE or r["task"] not in OLD or not r["finished"]:
        continue
    run = os.path.join(root, "runs", r["id"])
    text = ""
    for p in WHERE[r["arm"]](os.path.join(run, "repo")):
        try:
            text += open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            pass
    still = [p for p in OLD[r["task"]] if p in text]
    diff = open(os.path.join(run, "final.diff"), encoding="utf-8", errors="replace").read()
    key = (r["model"], r["arm"], r["task"])
    table[key]["n"] += 1
    table[key]["old_phrase"] += bool(still)
    if r["arm"] in TOUCH:
        table[key]["edited"] += TOUCH[r["arm"]] in diff
    if still:
        left.append((r["model"], r["arm"], r["task"], r["id"], still[:2]))
for key in sorted(table):
    c = table[key]
    print(f"{key[0]:7} {key[1]:9} {key[2]:10} n={c['n']} old phrase still in the record: {c['old_phrase']}"
          + (f" | record file edited: {c['edited']}" if key[1] in TOUCH else ""))
print()
for row in sorted(left):
    print("  read by eye:", row)
