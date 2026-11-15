"""order-warm.py <map.tsv> - print run ids in warm-cache batch order (warm-cache-batch.md).

Per model block (Opus, then Sonnet): the bare warm-up, then per task the arms
alternating incumbent first (a3 r1, a9 r1, a3 r2, a9 r2, a3 r3, a9 r3).
"""
import sys

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4 and p[3].isdigit():
        rows.append((p[0], p[1], p[2], int(p[3])))


def find(arm, task, rep):
    hits = [r[0] for r in rows if r[1] == arm and r[2] == task and r[3] == rep]
    if len(hits) != 1:
        sys.exit(f"order-warm: expected one run for {arm} {task} r{rep}, found {len(hits)}")
    return hits[0]


for suffix, tasks in (("@opus", ["t2", "t3"]), ("", ["t1", "t2", "t3"])):
    print(find("a1-bare" + suffix, "t3", 1))
    for task in tasks:
        for rep in (1, 2, 3):
            print(find("a3-incumbent" + suffix, task, rep))
            print(find("a9-trimmed" + suffix, task, rep))
