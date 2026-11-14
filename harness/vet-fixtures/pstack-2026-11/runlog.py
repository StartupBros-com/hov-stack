"""runlog.py <root> <map.tsv> - one TSV row per run from each run's result.json.

Columns: id arm task rep model start end duration_ms num_turns cost_usd
cache_creation cache_read input output is_error. `start` is the result.json
mtime minus duration_ms, in whole epoch seconds; `end` is the mtime. Read the
recorded copies in results/ instead of a scratch root when re-checking the note.
"""
import json
import os
import sys

COLS = ["id", "arm", "task", "rep", "model", "start", "end", "duration_ms", "num_turns",
        "cost_usd", "cache_creation", "cache_read", "input", "output", "is_error"]


def main(root, mapf):
    print("\t".join(COLS))
    for line in open(mapf, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 4 or not p[3].isdigit():
            continue
        rid, arm, task, rep = p[:4]
        path = os.path.join(root, "runs", rid, "result.json")
        try:
            res = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError) as exc:
            sys.exit(f"runlog: {rid}: no usable result.json ({exc})")
        end = os.path.getmtime(path)
        dur = res.get("duration_ms") or 0
        u = res.get("usage") or {}
        row = [rid, arm, task, rep, ",".join(sorted(res.get("modelUsage") or {})),
               str(round(end - dur / 1000.0)), str(round(end)), str(dur),
               str(res.get("num_turns") or 0), repr(res.get("total_cost_usd") or 0.0),
               str(u.get("cache_creation_input_tokens") or 0),
               str(u.get("cache_read_input_tokens") or 0),
               str(u.get("input_tokens") or 0), str(u.get("output_tokens") or 0),
               str(bool(res.get("is_error")))]
        print("\t".join(row))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: runlog.py <root> <map.tsv>")
    main(sys.argv[1], sys.argv[2])
