import json, os, re, subprocess, glob

R = "/tmp/hv-correct-2026-10-07"
ARMS = ["a1-1", "a1-2", "a1-3", "a2-1", "a2-2", "a2-3", "a3-1", "a3-2", "a3-3"]
BASELINE = 24
SKILL = "highest level that works"
HOUSE = "one guard in the shared function"


def transcripts_contain(cfg, needle):
    for p in glob.glob(os.path.join(cfg, "projects", "**", "*.jsonl"), recursive=True):
        with open(p, encoding="utf-8", errors="replace") as fh:
            if needle in fh.read():
                return True
    return False


out = []
for a in ARMS:
    d = os.path.join(R, "arms", a)
    rec = {"arm_dir": d}
    try:
        res = json.load(open(os.path.join(d, "result.json"), encoding="utf-8"))
    except Exception as e:
        res = {}
        rec["error"] = "result.json: %s" % e
    with open(os.path.join(d, "report.md"), "w", encoding="utf-8") as fh:
        fh.write(res.get("result") or "")
    rec["cost_usd"] = res.get("total_cost_usd")
    rec["turns"] = res.get("num_turns")
    ec = None
    try:
        for line in open(os.path.join(d, "stderr.txt"), encoding="utf-8", errors="replace"):
            m = re.match(r"EXIT_CODE=(\d+)", line)
            if m:
                ec = int(m.group(1))
    except OSError:
        pass
    rec["exit_code"] = ec
    n = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=os.path.join(d, "repo"),
                       capture_output=True, text=True)
    rec["commits_made"] = int(n.stdout.strip()) - BASELINE if n.stdout.strip() else None
    try:
        rec["tools"] = "; ".join(open(os.path.join(d, "tools.txt")).read().split("\n")[:8]).strip("; ")
    except OSError:
        rec["tools"] = ""
    cfg = os.path.join(d, "config")
    rec["skill_phrase_seen"] = transcripts_contain(cfg, SKILL)
    rec["house_phrase_seen"] = transcripts_contain(cfg, HOUSE)
    out.append(rec)

os.makedirs(os.path.join(R, "out"), exist_ok=True)  # added after the recorded run (PR #1684 review)
json.dump(out, open(os.path.join(R, "out", "collect.json"), "w"), indent=1)
print(json.dumps(out, indent=1))
