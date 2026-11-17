"""Score the ui-design-2026-11 runs and apply the pre-registered rules (README).

usage: python3 -I tally.py <runs-root> --key key.json --grades <dir> --tailwind <dir> --out <results-dir>

<dir> for --grades holds build-judge-a.json, build-judge-b.json, review-judge-a.json and
review-judge-b.json, plus optional build-adjudicated.json and review-adjudicated.json
({rid: {item: {"value": ..., "quote": "..."}}}). The tally refuses while any grade is missing,
split or unknown, while a run is void, or while an arm and task lack four counted runs.
Writes scores.json, skill-loads.txt and tally.md into --out.
"""

import argparse
import json
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BD = os.path.join(HERE, "..", "build-design-2026-11")
sys.path.insert(0, BD)
import score_runs as bds  # noqa: E402  (score_run, changes, result_text, OUTCOME)

REPS = 4
PACK, ENTRY = "pack", "pack+ui-design"
BUILD_TASKS = ("t1", "t4")
LOAD_TASKS = ("t1", "t4", "rv", "p1")
NEG_TASKS = ("c2", "c3")
OUTCOME = [n for n in bds.OUTCOME if n not in ("O2_no_build_from_a_guess",)]
BUILD_ITEMS = ("R1", "R2", "R3", "R5")
DEFECTS = ("D1", "D2", "D3", "D4", "D5", "D6a", "D6b", "D7", "D8a", "D8b", "D9")
CONTROLS = tuple("C%d" % i for i in range(1, 11))
SKILL_READ = re.compile(r"plugins/hov-stack/skills/([\w-]+)/SKILL\.md$")


def run_record(run, rid, twdir):
    """One run's script items, cost, skill loads and voids. Build tasks reuse the build-design scorer."""
    task = open(os.path.join(run, "task.txt")).read().strip()
    out = os.path.join(run, "out")
    if task in BUILD_TASKS:
        s = bds.score_run(run, rid, twdir)
    else:
        repo = os.path.join(run, "user", "code", "acme-console")
        status, added = bds.changes(repo)
        r1, r2 = bds.result_text(out, "t1"), bds.result_text(out, "t2")
        st = open(os.path.join(out, "status.txt")).read() if os.path.exists(os.path.join(out, "status.txt")) else ""
        overall = re.search(r"^run=(\S+)$", st, re.M)
        overall = overall.group(1) if overall else "missing"
        tools = open(os.path.join(out, "tools.txt")).read() if os.path.exists(os.path.join(out, "tools.txt")) else ""
        outside = re.search(r"^paths_outside_run=(.*)$", tools, re.M)
        reasons = []
        if outside and outside.group(1).strip():
            reasons.append("paths outside the run dir")
        if overall not in ("ok", "arm-stop"):
            reasons.append("run status %s" % overall)
        s = {"rid": rid, "task": task, "turn2_sent": os.path.exists(os.path.join(out, "turn2-sent.txt")),
             "cost_usd": round(sum(float(r.get("total_cost_usd") or 0) for r in (r1, r2)), 4),
             "added_lines": sum(len(v) for v in added.values()), "changed": ["%s %s" % c for c in status],
             "status": overall, "void": bool(reasons), "void_reason": "; ".join(reasons), "items": {}, "notes": {}}
        if task == "rv":
            s["items"]["RV_no_edit"] = not status
    tools = open(os.path.join(out, "tools.txt")).read() if os.path.exists(os.path.join(out, "tools.txt")) else ""
    skills = re.search(r"^skills=(.*)$", tools, re.M)
    reads = re.search(r"^reads=(.*)$", tools, re.M)
    s["skills"] = [x for x in (skills.group(1).split("|") if skills else []) if x]
    s["skill_files_read"] = sorted({m.group(1) for p in (reads.group(1).split("|") if reads else [])
                                    for m in [SKILL_READ.search(p)] if m})
    s["loaded"] = "hov-stack:ui-design" in s["skills"]
    return s


def load_judged(grades_dir, kind, items, kinds_ok, problems):
    """{rid: {item: settled value}} for one packet set, two judges, with adjudication."""
    vals = {}
    for j in ("a", "b"):
        path = os.path.join(grades_dir, "%s-judge-%s.json" % (kind, j))
        if not os.path.exists(path):
            problems.append("missing %s" % os.path.basename(path))
            continue
        for rid, got in json.load(open(path)).items():
            for label, v in got.items():
                if label == "why":
                    continue
                if label not in items:
                    problems.append("%s: %s: unknown item %r" % (os.path.basename(path), rid, label))
                elif not kinds_ok(label, v):
                    problems.append("%s: %s: %s is %r" % (os.path.basename(path), rid, label, v))
                else:
                    vals.setdefault(rid, {}).setdefault(label, []).append(v)
    adj = {}
    apath = os.path.join(grades_dir, "%s-adjudicated.json" % kind)
    if os.path.exists(apath):
        for rid, got in json.load(open(apath)).items():
            for label, rec in got.items():
                if label not in items or not kinds_ok(label, rec.get("value")) or not rec.get("quote"):
                    problems.append("%s: %s: %r needs a known item, a valid value and a quote"
                                    % (os.path.basename(apath), rid, label))
                else:
                    adj.setdefault(rid, {})[label] = rec["value"]
    settled = {}
    for rid, got in vals.items():
        for label, vs in got.items():
            if label in adj.get(rid, {}):
                settled.setdefault(rid, {})[label] = adj[rid][label]
            elif len(vs) != 2:
                problems.append("%s %s: %s has %d grade(s), needs 2" % (kind, rid, label, len(vs)))
            elif vs[0] != vs[1]:
                problems.append("%s %s: %s split %s; settle it in %s-adjudicated.json with the quote"
                                % (kind, rid, label, vs, kind))
            else:
                settled.setdefault(rid, {})[label] = vs[0]
    return settled


def join(scores, key, grades_dir):
    """[(arm, record)] with judged items merged in; SystemExit listing every gap."""
    problems = []
    build = load_judged(grades_dir, "build", BUILD_ITEMS + ("J5",),
                        lambda l, v: isinstance(v, bool), problems)
    review = load_judged(grades_dir, "review", DEFECTS + CONTROLS,
                         lambda l, v: (v in (0, 0.5, 1) and not isinstance(v, bool)) if l in DEFECTS
                         else isinstance(v, bool), problems)
    rows = []
    for s in scores:
        meta = key.get(s["rid"])
        if meta is None:
            problems.append("%s: not in the key" % s["rid"])
            continue
        if s["void"]:
            continue
        items = dict(s["items"])
        if s["task"] in BUILD_TASKS:
            need = list(BUILD_ITEMS)
            if s["task"] == "t1" and items.get(bds.D5) is None:
                need.append("J5")
            got = build.get(s["rid"], {})
            for n in need:
                if n not in got:
                    problems.append("build %s (%s): %s not graded" % (s["rid"], s["task"], n))
            for n in sorted(set(got) - set(need)):
                problems.append("build %s (%s): graded %s, which does not apply" % (s["rid"], s["task"], n))
            for n in BUILD_ITEMS:
                items[bds.SHORT[n]] = got.get(n)
            if "J5" in need:
                items[bds.D5] = got.get("J5")
            if items.get("G_built") is False:
                for n in BUILD_ITEMS:
                    items[bds.SHORT[n]] = False
        elif s["task"] == "rv":
            got = review.get(s["rid"], {})
            missing = [n for n in DEFECTS + CONTROLS if n not in got]
            if missing:
                problems.append("review %s: not graded: %s" % (s["rid"], ", ".join(missing)))
            items["TP"] = sum(got.get(n, 0) for n in DEFECTS)
            items["FA"] = sum(1 for n in CONTROLS if got.get(n) is True)
        rows.append((meta["arm"], s, items))
    counts = {}
    for arm, s, _ in rows:
        counts[(arm, s["task"])] = counts.get((arm, s["task"]), 0) + 1
    want = {(arm, t) for arm, t in {(m["arm"], m["task"]) for m in key.values()}}
    for cell in sorted(want):
        if counts.get(cell, 0) != REPS:
            problems.append("%s on %s has %d counted run(s), needs %d (re-run each void under a new number)"
                            % (cell[0], cell[1], counts.get(cell, 0), REPS))
    if problems:
        raise SystemExit("tally refused (%d problem(s)):\n- " % len(problems) + "\n- ".join(problems))
    return rows


def rules(rows):
    """[(rule, detail, ok)] for the pre-registered rules, from joined rows."""
    by = lambda arm, task: [(s, it) for a, s, it in rows if a == arm and s["task"] == task]
    out = []
    loads = {t: sum(s["loaded"] for s, _ in by(ENTRY, t)) for t in LOAD_TASKS + NEG_TASKS + ("c1",)}
    low = [t for t in LOAD_TASKS if loads[t] < 3]
    out.append(("L1 loads on t1, t4, rv, p1 (>= 3 of 4 each)",
                ", ".join("%s %d/4" % (t, loads[t]) for t in LOAD_TASKS), not low))
    neg = loads["c2"] + loads["c3"]
    out.append(("L2 quiet on c2 and c3 (<= 1 of 8)", "%d of 8 (c1, reported only: %d of 4)" % (neg, loads["c1"]),
                neg <= 1))

    def fails(arm, item, task):
        return sum(1 for s, it in by(arm, task) if it.get(item) is not True)

    regress = ["%s (%s) %d vs %d fails" % (n, t, fails(ENTRY, n, t), fails(PACK, n, t))
               for t in BUILD_TASKS for n in OUTCOME
               if any(n in it for _, it in by(ENTRY, t) + by(PACK, t))
               and fails(ENTRY, n, t) - fails(PACK, n, t) >= 2]
    out.append(("Q1 no build regression", ", ".join(regress) or "none", not regress))
    r2 = {a: sum(1 for t in BUILD_TASKS for _, it in by(a, t) if it.get(bds.SHORT["R2"]) is True) for a in (PACK, ENTRY)}
    out.append(("Q2 R2 gain >= 3", "%d vs %d of 8 (%+d)" % (r2[ENTRY], r2[PACK], r2[ENTRY] - r2[PACK]),
                r2[ENTRY] - r2[PACK] >= 3))
    r5 = sum(fails(ENTRY, bds.SHORT["R5"], t) for t in BUILD_TASKS)
    r3 = {a: sum(fails(a, bds.SHORT["R3"], t) for t in BUILD_TASKS) for a in (PACK, ENTRY)}
    out.append(("Q3 no false match (R5 fails <= 1; R3 fails <= pack + 1)",
                "R5 fails %d; R3 fails %d vs %d" % (r5, r3[ENTRY], r3[PACK]), r5 <= 1 and r3[ENTRY] <= r3[PACK] + 1))
    tp = {a: sum(it["TP"] for _, it in by(a, "rv")) for a in (PACK, ENTRY)}
    fa = {a: sum(it["FA"] for _, it in by(a, "rv")) for a in (PACK, ENTRY)}
    ed = {a: sum(1 for _, it in by(a, "rv") if it.get("RV_no_edit") is not True) for a in (PACK, ENTRY)}
    out.append(("Q4 review no worse (TP >= pack - 2; FA <= pack + 1; edits <= pack + 1)",
                "TP %.1f vs %.1f of 44; FA %d vs %d of 40; edited %d vs %d of 4"
                % (tp[ENTRY], tp[PACK], fa[ENTRY], fa[PACK], ed[ENTRY], ed[PACK]),
                tp[ENTRY] >= tp[PACK] - 2 and fa[ENTRY] <= fa[PACK] + 1 and ed[ENTRY] <= ed[PACK] + 1))
    for t in BUILD_TASKS:
        lines = {a: statistics.median([s["added_lines"] for s, _ in by(a, t)]) for a in (PACK, ENTRY)}
        out.append(("C %s median added lines <= 1.5x pack" % t, "%s vs %s" % (lines[ENTRY], lines[PACK]),
                    lines[ENTRY] <= 1.5 * lines[PACK]))
    cost = {a: statistics.median([s["cost_usd"] for t in BUILD_TASKS + ("rv",) for s, _ in by(a, t)])
            for a in (PACK, ENTRY)}
    out.append(("C median cost on t1, t4, rv <= 2x pack", "%.3f vs %.3f" % (cost[ENTRY], cost[PACK]),
                cost[ENTRY] <= 2 * cost[PACK]))
    ask = {a: sum(1 for t in BUILD_TASKS for s, _ in by(a, t) if s["turn2_sent"]) for a in (PACK, ENTRY)}
    out.append(("C stopped to ask on t1, t4 <= pack + 1", "%d vs %d of 8" % (ask[ENTRY], ask[PACK]),
                ask[ENTRY] <= ask[PACK] + 1))
    return out


def table(rows):
    arms = (PACK, ENTRY)
    lines = ["| item (task) | pack | pack+ui-design |", "|---|---|---|"]
    for t in BUILD_TASKS:
        for n in OUTCOME + [bds.SHORT[x] for x in BUILD_ITEMS]:
            cells = []
            for a in arms:
                vals = [it.get(n) for arm, s, it in rows if arm == a and s["task"] == t and n in it]
                cells.append("%d/%d" % (sum(v is True for v in vals), len(vals)) if vals else "n/a")
            if cells != ["n/a", "n/a"]:
                lines.append("| %s (%s) | %s |" % (n, t, " | ".join(cells)))
    for n in ("TP", "FA", "RV_no_edit"):
        cells = []
        for a in arms:
            vals = [it.get(n) for arm, s, it in rows if arm == a and s["task"] == "rv"]
            cells.append(("%d/%d" % (sum(v is True for v in vals), len(vals))) if n == "RV_no_edit"
                         else " ".join("%g" % v for v in vals))
        lines.append("| %s (rv) | %s |" % (n, " | ".join(cells)))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--key", required=True)
    ap.add_argument("--grades", required=True)
    ap.add_argument("--tailwind", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    key = json.load(open(a.key))
    scores = [run_record(os.path.join(a.root, rid), rid, os.path.abspath(a.tailwind))
              for rid in sorted(os.listdir(a.root)) if os.path.isfile(os.path.join(a.root, rid, "prompt.txt"))]
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "scores.json"), "w", encoding="utf-8") as fh:
        json.dump(scores, fh, indent=1)
    with open(os.path.join(a.out, "skill-loads.txt"), "w", encoding="utf-8") as fh:
        for s in scores:
            fh.write("%s %s %s skills=%s read=%s void=%s\n" % (
                s["rid"], key.get(s["rid"], {}).get("arm", "?"), s["task"], "|".join(s["skills"]),
                "|".join(s["skill_files_read"]), s["void_reason"] or "no"))
    voids = ["%s (%s)" % (s["rid"], s["void_reason"]) for s in scores if s["void"]]
    rows = join(scores, key, a.grades)
    res = rules(rows)
    text = table(rows) + ["", "Void, not counted: %s" % ("; ".join(voids) or "none"), "",
                          "| rule | measured | result |", "|---|---|---|"]
    text += ["| %s | %s | %s |" % (r, d, "MET" if ok else "not met") for r, d, ok in res]
    text += ["", "Ships model-invoked: %s" % ("yes, every rule met" if all(ok for _, _, ok in res)
                                             else "no (README, \"If a rule fails\")")]
    with open(os.path.join(a.out, "tally.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(text) + "\n")
    print("\n".join(text))


if __name__ == "__main__":
    sys.exit(main())
