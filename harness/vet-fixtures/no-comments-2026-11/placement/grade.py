#!/usr/bin/env python3
"""grade.py <root> <map.tsv> <out.json> [<arms-root>] - grade every finished placement run.

Per run: the task's done probe, its keep probes, every other decision probe (collateral), `make check`,
cost and turns from result.json, and what the agent consulted or was shown, read from its own transcript
(tool inputs AND tool results). Mechanical; final messages are judged separately.

left_repo is true when a tool input names the map's directory, the arm bases' directory (<arms-root>, when
given) or climbs two levels up: the places a run could learn which arm it is.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
root, map_path, out_path = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
OUTSIDE = [Path(map_path).resolve().parent.name, "../.."]
if len(sys.argv) > 4:
    OUTSIDE.append(Path(sys.argv[4]).resolve().name)
DONE = {"fileorder": "fileorder_done", "always": "always_done", "addrule": "addrule_done", "pending": "pending_done",
        "negative": "negative_done", "version": "version_done", "cats": "cats_done"}
KEEP = {"fileorder": ["fileorder_keep"], "always": ["always_keep"], "addrule": ["addrule_keep_order", "addrule_keep_case"]}
ALLK = ["k_order", "k_upper", "k_sort", "k_decimal", "k_negative", "k_pending", "k_empty", "k_ties", "k_atomic"]
# decisions a task is allowed (or asked) to change, so they are not counted as collateral damage
EXEMPT = {"fileorder": {"k_sort"}, "always": {"k_empty"}, "addrule": set(), "pending": {"k_pending"},
          "negative": {"k_negative"}, "version": set(), "cats": set()}
# the words of the decision each task puts at risk, as they appear in every true record of it
PHRASES = {"fileorder": ["groups consecutive rows"], "always": ["reads as an outage"],
           "addrule": ["first matching rule wins", "written once, in capitals"],
           "pending": ["can still change"], "negative": ["post template expects"]}


def probe(repo, name):
    p = subprocess.run([sys.executable, "-I", str(HERE / "probes.py"), str(repo), name], capture_output=True, text=True,
                       timeout=120)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"result": "raised", "detail": (p.stderr or p.stdout)[-200:]}


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(text_of(b.get("text") or b.get("content") or "") if isinstance(b, dict) else str(b)
                         for b in content)
    return ""


def consulted(run, task):
    c = {"asked_docs": False, "asked_history": False, "asked_decisions_test": False, "left_repo": False,
         "shown_docs": False, "shown_history": False, "shown_decisions_test": False, "shown_fact": False,
         "tools": 0, "bash_git": []}
    proj = run / "config" / "projects"
    for dirpath, _d, files in os.walk(proj):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            for line in open(os.path.join(dirpath, name), encoding="utf-8", errors="replace"):
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                content = (rec.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if rec.get("type") == "assistant" and b.get("type") == "tool_use":
                        c["tools"] += 1
                        blob = json.dumps(b.get("input") or {})
                        if "docs/decisions" in blob or "docs/" in blob or '"docs"' in blob:
                            c["asked_docs"] = True
                        if "test_decisions" in blob:
                            c["asked_decisions_test"] = True
                        if any(name in blob for name in OUTSIDE):
                            c["left_repo"] = True
                        if b.get("name") == "Bash":
                            cmd = (b.get("input") or {}).get("command", "")
                            if any(k in cmd for k in ("git log", "git show", "git blame")):
                                c["asked_history"] = True
                                c["bash_git"].append(cmd[:120])
                    elif rec.get("type") == "user" and b.get("type") == "tool_result":
                        out = text_of(b.get("content"))
                        if "Status: accepted" in out or "# Decisions" in out:
                            c["shown_docs"] = True
                        if "Why it is built this way" in out:
                            c["shown_history"] = True
                        if "Decisions tally must keep" in out or "class DigestDecisions" in out \
                                or "class RuleDecisions" in out or "class ImporterDecisions" in out:
                            c["shown_decisions_test"] = True
                        if any(p in out for p in PHRASES.get(task, [])):
                            c["shown_fact"] = True
    return c


def diff_of(repo):
    env = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "GIT_CONFIG_NOSYSTEM": "1"}
    subprocess.run(["git", "add", "-A", "-N", "."], cwd=repo, env=env, capture_output=True, text=True)
    p = subprocess.run(["git", "diff", "HEAD", "--", ".", ":(exclude)*.pyc", ":(exclude).mypy_cache",
                        ":(exclude).ruff_cache", ":(exclude)**/__pycache__"], cwd=repo, env=env, capture_output=True,
                       text=True)
    return p.stdout


rows = []
for line in open(map_path, encoding="utf-8"):
    rid, arm, task, rep, model = line.rstrip("\n").split("\t")
    run = root / "runs" / rid
    row = {"id": rid, "arm": arm, "task": task, "rep": int(rep), "model": model, "finished": False}
    try:
        res = json.load(open(run / "result.json", encoding="utf-8"))
    except (OSError, ValueError):
        rows.append(row)
        continue
    if res.get("is_error") is not False or not str(res.get("result") or "").strip():
        row["error"] = str(res.get("subtype") or res.get("result") or "")[:200]
        rows.append(row)
        continue
    repo = run / "repo"
    diff = diff_of(repo)
    (run / "final.diff").write_text(diff, encoding="utf-8")
    chk = subprocess.run(["make", "check"], cwd=repo, capture_output=True, text=True, timeout=600)
    row.update({
        "finished": True, "cost": res.get("total_cost_usd"), "turns": res.get("num_turns"),
        "seconds": round((res.get("duration_ms") or 0) / 1000), "diff_lines": diff.count("\n"),
        "models": sorted((res.get("modelUsage") or {}).keys()), "check": chk.returncode == 0,
        "done": probe(repo, DONE[task]), "keep": {k: probe(repo, k) for k in KEEP.get(task, [])},
        "collateral": {k: probe(repo, k)["result"] for k in ALLK if k not in EXEMPT[task]},
        "consulted": consulted(run, task), "final": str(res.get("result"))[:6000],
    })
    row["kept"] = all(v["result"] == "correct" for v in row["keep"].values()) if row["keep"] else None
    row["collateral_broken"] = sorted(k for k, v in row["collateral"].items() if v != "correct")
    rows.append(row)
json.dump(rows, open(out_path, "w"), indent=1)
fin = [r for r in rows if r["finished"]]
print(f"runs in map: {len(rows)}; finished: {len(fin)}; errors: {sum(1 for r in rows if r.get('error'))}; "
      f"not run: {sum(1 for r in rows if not r['finished'] and not r.get('error'))}")
