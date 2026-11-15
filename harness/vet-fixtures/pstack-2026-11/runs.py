"""Shared reader for runlog.py output (results/runs-*.tsv)."""


def read_runlog(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        if header[:4] != ["id", "arm", "task", "rep"]:
            raise SystemExit(f"{path}: not a runlog.py file")
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) != len(header):
                continue
            r = dict(zip(header, p))
            r["rep"] = int(r["rep"])
            for k in ("start", "end", "duration_ms", "num_turns", "cache_creation",
                      "cache_read", "input", "output"):
                r[k] = int(r[k])
            r["cost_usd"] = float(r["cost_usd"])
            r["is_error"] = r["is_error"] == "True"
            r["base"] = r["arm"].split("@")[0]
            r["family"] = "opus" if r["arm"].endswith("@opus") else "sonnet"
            rows.append(r)
    return rows
