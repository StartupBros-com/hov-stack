#!/usr/bin/env python3
"""Per-arm table for the no-comments fixture: validity from transcripts first, then scores.

usage: python3 analyze_arms.py <map.tsv> <grade.json> <runs-root>
Validity (Amendment A item 5) is decided from the transcript before any score is printed.
"""
import json
import statistics as st
import sys
from pathlib import Path

MAP, GRADE, ROOT = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
CMD = {
    "a2-pstack": "pstack:no-comments",
    "a3-ce": "compound-engineering:ce-simplify-code",
    "a4-codeslop": "hov-stack:code-slop",
    "a5-ratchet": "comment-ratchet:delete-comment",
    "a6-audit": "comment-audit:comment-audit-skill",
    "a7-routing": "code-comments:code-comments",
}


def transcript_facts(run):
    """slash commands, subagent types, and Agent prompts' first 200 chars from every transcript file."""
    cmds, subs, prompts, bash = [], [], [], []
    for p in (run / "config" / "projects").rglob("*.jsonl") if (run / "config" / "projects").exists() else []:
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            content = (rec.get("message") or {}).get("content")
            if rec.get("type") == "user" and isinstance(content, str) and "<command-name>" in content:
                cmds.append(content.split("<command-name>", 1)[1].split("</command-name>", 1)[0].strip())
            if rec.get("type") == "user" and isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "text" and "<command-name>" in str(b.get("text")):
                        t = b["text"]
                        cmds.append(t.split("<command-name>", 1)[1].split("</command-name>", 1)[0].strip())
            if rec.get("type") != "assistant" or not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    if b.get("name") in ("Agent", "Task"):
                        subs.append(str(inp.get("subagent_type", "general")))
                        prompts.append(str(inp.get("prompt", ""))[:400])
                    if b.get("name") == "Bash":
                        bash.append(str(inp.get("command", ""))[:160])
    return cmds, subs, prompts, bash


def valid(arm, run):
    cmds, subs, prompts, _ = transcript_facts(run)
    if arm in ("a1-bare", "a8-extract"):
        return (not cmds and not subs), f"cmds={cmds} subs={subs}"
    want = CMD[arm]
    ok = any(c.lstrip("/") == want for c in cmds)
    why = f"cmd={'ok' if ok else 'MISSING ' + str(cmds)}"
    if arm == "a2-pstack":
        sicko = any("comment-sicko" in s for s in subs)
        ok = ok and sicko
        why += f" sicko={'ok' if sicko else 'MISSING'} subs={subs}"
    if arm == "a3-ce":
        persona = any("Comment Reviewer" in p for p in prompts)
        ok = ok and persona
        why += f" persona={'ok' if persona else 'MISSING'} subs={len(subs)}"
    return ok, why


def med(xs):
    return st.median(xs) if xs else None


arms = {}
for line in MAP.read_text().splitlines():
    rid, arm, _task, rep = line.split("\t")
    arms.setdefault(arm, []).append(rid)
grades = json.loads(GRADE.read_text())

print("== validity (decided before scores)")
validity = {}
for arm, ids in arms.items():
    for rid in ids:
        ok, why = valid(arm, ROOT / "runs" / rid)
        validity[rid] = ok
        print(f"{arm:12} {rid} valid={ok} {why}")

print("\n== per run")
rows = {}
for arm, ids in arms.items():
    for rid in ids:
        g = grades.get(rid)
        if not g:
            print(f"{arm:12} {rid} UNGRADED")
            continue
        s = g["summary"]
        rows.setdefault(arm, []).append((rid, s, g.get("cost_usd"), g.get("num_turns"), validity[rid]))
        print(f"{arm:12} {rid} valid={validity[rid]} checks={s['checks_pass']} sep={s['sep_score']} {s['sep']} "
              f"clutter={s['clutter_removed']}/13 lost={s['lost_total']} (D{s['D_lost']} K{s['K_lost']}) "
              f"D_strict_gone={s['D_strict_gone']} enf/dis={s['D_enforced_or_dissolved']} unk={s['D_unknown']} "
              f"cost={g.get('cost_usd')} turns={g.get('num_turns')}")

print("\n== per arm (valid runs only)")
summ = {}
for arm, rs in rows.items():
    v = [r for r in rs if r[4]]
    sep = [r[1]["sep_score"] for r in v]
    lost = [r[1]["lost_total"] for r in v]
    clut = [r[1]["clutter_removed"] for r in v]
    strict = [r[1]["D_strict_gone"] for r in v]
    cost = [r[2] for r in v if r[2] is not None]
    turns = [r[3] for r in v if r[3] is not None]
    summ[arm] = {"n": len(v), "sep": sep, "sep_med": med(sep), "sep_max": max(sep) if sep else None,
                 "lost": lost, "lost_med": med(lost), "clutter": clut, "strict": strict,
                 "cost_med": med(cost), "cost": cost, "turns_med": med(turns)}
    print(f"{arm:12} n={len(v)} sep={sep} med={med(sep)} | lost={lost} med={med(lost)} | clutter={clut} | "
          f"D_strict_gone={strict} | cost med={med(cost)} {['%.2f' % c for c in cost]} | turns med={med(turns)}")

print("\n== rule (prereg + Amendment A; Amendment C for a8-extract)")
b = summ.get("a1-bare", {})
inc = summ.get("a3-ce", {})
for arm, s in summ.items():
    if arm == "a1-bare" or not s["n"]:
        continue
    gain = None
    if b.get("sep_med") is not None and s["sep_med"] is not None and b["sep_med"] < 12:
        gain = (s["sep_med"] - b["sep_med"]) / (12 - b["sep_med"])
    if arm == "a3-ce":
        beats = "n/a"
    elif not inc.get("n"):
        beats = "not evaluable (incumbent not-run)"
    else:
        beats = (s["sep_med"] > inc["sep_max"] and s["lost_med"] <= inc["lost_med"])
    # Amendment A line (b): a skill arm whose median lost exceeds bare's median is a finding against it.
    worse_than_bare = s["lost_med"] is not None and b.get("lost_med") is not None and s["lost_med"] > b["lost_med"]
    print(f"{arm:12} sep_med={s['sep_med']} vs bare {b.get('sep_med')} (norm gain {gain}) | "
          f"beats-incumbent rule: {beats} | line (b) median-lost finding: {worse_than_bare}")
    if arm == "a8-extract":
        v = [r for r in rows[arm] if r[4]]
        c1 = s["sep_med"] is not None and b.get("sep_max") is not None and s["sep_med"] > b["sep_max"]
        c2 = all(r[1]["lost_total"] == 0 for r in v)
        c3 = all(r[1]["checks_pass"] for r in v)
        print(f"{'':12} Amendment C (per run): (1) sep_med {s['sep_med']} > bare max {b.get('sep_max')}: {c1} | "
              f"(2) lost 0 in every run {[r[1]['lost_total'] for r in v]}: {c2} | (3) checks every run: {c3} | "
              f"rule met: {c1 and c2 and c3}")
