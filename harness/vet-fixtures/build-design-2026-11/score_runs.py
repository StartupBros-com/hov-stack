"""Score the build-design-2026-11 runs: the script items, then (with --key) the tally.

usage: python3 -I score_runs.py <runs-root> --tailwind <dir> [--out scores.json]
         [--key key.json --grades <dir> [--tally tally.md]]

<dir> is a scratch directory holding node_modules/tailwindcss and
node_modules/@tailwindcss/cli at 4.1.11; per-run probes are written under it.

Per run (blind: the run number and task only) it scores the items README.md
pre-registers. Gated items fail when their task's gate fails, so a run that
builds nothing cannot pass by doing nothing wrong. With --key and --grades it
joins the judges' report items, applies the every-arm drop rule and the
adoption rule, and prints the tally by arm.
"""

import argparse
import glob
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = os.path.join(HERE, "seed", "acme-console")
SETTINGS = "src/pages/Settings.tsx"

GATE_STRINGS = {
    "t1": ["Team members", "Invite member", "Maya Chen", "Jonas Weber", "Priya Raman", "Invitation sent",
           "Resend", "Owner", "Admin"],
    "t3": ["Delete workspace", "Permanently delete this workspace"],
    "t4": ["Billing", "Download invoices", "Team plan", "Change plan", "Seats", "Cancel plan",
           "Invoices", "Nov 1, 2026", "$36.00", "Paid", "Due", "Billing details", "Billing email",
           "Email me a receipt"],
}
# The file the task asks for: changed (t1, t3) or added (t4).
TARGET = {"t1": "src/pages/Settings.tsx", "t3": "src/pages/Settings.tsx", "t4": "src/pages/Billing.tsx"}
ROOTS = ("bg text border divide ring outline fill stroke p px py pt pr pb pl ps pe m mx my mt mr mb ml ms me "
         "gap gap-x gap-y space-x space-y w h size min-w min-h max-w max-h rounded font leading tracking shadow "
         "opacity items justify self place inset top right bottom left z basis grow shrink flex grid col row "
         "line-clamp decoration whitespace break overflow list transition duration ease cursor select align "
         "object aspect content order").split()
BARE = set(("flex grid block inline inline-block inline-flex hidden contents truncate border rounded relative "
            "absolute fixed sticky static uppercase lowercase capitalize italic underline sr-only grow shrink "
            "shadow outline ring transition antialiased isolate tabular-nums divide-x divide-y").split())
CLASSLIKE = re.compile(r"^!?-?(%s)-[\w./\[\]#%%(),:'-]+!?$" % "|".join(re.escape(r) for r in
                                                                     sorted(ROOTS, key=len, reverse=True)))
STRING = re.compile(r'"([^"\\\n]*)"|\'([^\'\\\n]*)\'|`([^`\n]*)`')
# The whole class token (`translate-x-[16px]`, `md:w-[50%]`), not just its last segment.
ARBITRARY = re.compile(r"[\w!:./-]*[\w!]-\[[^\]\s]+\]|(?<![\w-])\[[a-z-]+:[^\]\s]+\]")
HEX = re.compile(r"(?<![\w&])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")
COLOR_FN = re.compile(r"\b(?:rgba?|hsla?|oklch|oklab|lab|lch)\(")
STYLE_ATTR = re.compile(r"\bstyle=\{")
PERCENT_SIZE = re.compile(r"(?:^|[\s:])(?:w|h|min-w|max-w|min-h|max-h|basis)-\[\d+(?:\.\d+)?%\]$")


def PERCENT_STYLE(line):
    """A style attribute that sets only a percentage width or height (no colour, no px)."""
    body = line.split("style=", 1)[1]
    keys = set(re.findall(r"([A-Za-z]+)\s*:", body))
    return "%" in body and keys <= {"width", "height"} and "px" not in body and "#" not in body
CODE_EXT = (".tsx", ".ts", ".jsx", ".js", ".css")


def git(repo, *args):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo}
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True, env=env).stdout


def base_commit(repo):
    return git(repo, "rev-list", "--max-parents=0", "HEAD").split()[0]


def changes(repo):
    """(name-status list, {path: [added lines]}) against the seed commit, untracked files included."""
    git(repo, "add", "-A", "-N")
    base = base_commit(repo)
    status = []
    for line in git(repo, "diff", "--name-status", "--no-renames", base).splitlines():
        code, path = line.split("\t", 1)
        status.append((code[0], path))
    added, cur = {}, None
    for line in git(repo, "diff", "-U0", "--no-renames", base).splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
            continue
        if cur and line.startswith("+") and not line.startswith("+++"):
            added.setdefault(cur, []).append(line[1:])
    return status, added


def class_tokens(lines):
    out = []
    for line in lines:
        for m in STRING.finditer(line):
            text = next(g for g in m.groups() if g is not None)
            text = re.sub(r"\$\{[^}]*\}", " ", text)
            for tok in text.split():
                bare = tok.rsplit(":", 1)[-1] if "[" not in tok else tok
                if bare in BARE or CLASSLIKE.match(bare):
                    out.append(tok)
    return sorted(set(out))


def css_escape(cls):
    out = []
    for i, ch in enumerate(cls):
        if ch.isalnum() or ch in "-_":
            out.append("\\3%s " % ch if i == 0 and ch.isdigit() else ch)
        else:
            out.append("\\" + ch)
    return "".join(out)


def no_rule(tokens, theme, twdir, rid):
    """Class tokens Tailwind 4.1.11 emits no rule for under <theme> (the arm's own theme.css)."""
    if not tokens:
        return []
    probe = os.path.join(twdir, "probes", rid)
    shutil.rmtree(probe, ignore_errors=True)
    os.makedirs(probe)
    with open(os.path.join(probe, "probe.html"), "w", encoding="utf-8") as fh:
        fh.write('<div class="%s"></div>\n' % " ".join(tokens))
    css = open(theme, encoding="utf-8").read()
    css = css.replace('@import "tailwindcss";', '@import "tailwindcss" source(none);\n@source "./probe.html";', 1)
    with open(os.path.join(probe, "input.css"), "w", encoding="utf-8") as fh:
        fh.write(css)
    cli = os.path.join(twdir, "node_modules", ".bin", "tailwindcss")
    res = subprocess.run([cli, "-i", "input.css", "-o", "out.css"], cwd=probe, capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit("score_runs: tailwind failed for %s: %s" % (rid, res.stderr[-400:]))
    out = open(os.path.join(probe, "out.css"), encoding="utf-8").read()
    return [t for t in tokens
            if not re.search(re.escape("." + css_escape(t)) + r"(?![A-Za-z0-9_\-\\])", out)]


def subsequence(needle, hay):
    it = iter(hay)
    return all(any(n == h for h in it) for n in needle)


def result_text(out, tag):
    try:
        return json.load(open(os.path.join(out, "result-%s.json" % tag), encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def score_run(run, rid, twdir):
    task = open(os.path.join(run, "task.txt")).read().strip()
    repo = os.path.join(run, "user", "code", "acme-console")
    out = os.path.join(run, "out")
    status, added = changes(repo)
    all_added = [l for lines in added.values() for l in lines]
    src_added = [l for p, lines in added.items() if p.startswith("src/") and p.endswith(CODE_EXT)
                 and p != "src/styles/theme.css" for l in lines]
    tsx_added = [l for p, lines in added.items() if p.endswith((".tsx", ".jsx", ".ts", ".js")) for l in lines]
    joined = "\n".join(src_added)
    r1, r2 = result_text(out, "t1"), result_text(out, "t2")
    tools = open(os.path.join(out, "tools.txt"), encoding="utf-8").read() if os.path.exists(
        os.path.join(out, "tools.txt")) else ""
    outside = re.search(r"^paths_outside_run=(.*)$", tools, re.M)
    s = {
        "rid": rid, "task": task,
        "turn2_sent": os.path.exists(os.path.join(out, "turn2-sent.txt")),
        "cost_usd": round(sum(float(r.get("total_cost_usd") or 0) for r in (r1, r2)), 4),
        "added_lines": len(all_added),
        "changed": ["%s %s" % c for c in status],
        "void": bool(outside and outside.group(1).strip()),
        "items": {}, "notes": {},
    }
    it = s["items"]
    if task == "c1":
        return s  # invocation probe control: only tools.txt (did the arm load the skill?) is read
    if task == "t2":
        it["O2_no_build_from_a_guess"] = not status
        return s

    gate = all(g in joined for g in GATE_STRINGS[task]) and any(p == TARGET[task] for _, p in status)
    it["G_built"] = gate

    tokens = class_tokens(src_added)
    theme = os.path.join(repo, "src", "styles", "theme.css")
    if not os.path.exists(theme):
        theme = os.path.join(SEED, "src", "styles", "theme.css")
    dead = no_rule(tokens, theme, twdir, rid)
    # A percentage size is data, not a design value (a seat bar's fill), so it is exempt both as an
    # arbitrary class and as a style attribute; no token could express it.
    arb = sorted({m.group(0) for l in src_added for m in ARBITRARY.finditer(l)})
    arb = [x for x in arb if not PERCENT_SIZE.search(x)]
    hexes = sorted({m.group(0) for l in src_added for m in HEX.finditer(l)})
    fns = sorted({m.group(0) for l in src_added for m in COLOR_FN.finditer(l)})
    # Listed, not counted, so a multi-line percentage style the line check misses can be read by hand.
    styles = [l.strip()[:120] for l in src_added if STYLE_ATTR.search(l) and not PERCENT_STYLE(l)]
    s["notes"]["D1"] = {"no_rule": dead, "arbitrary": arb, "hex": hexes, "color_fn": fns, "style_attrs": styles}
    it["D1_on_system_values"] = gate and not (dead or arb or hexes or fns or styles)

    system = [c for c in status if c[1].startswith(("src/styles/", "src/components/ui/"))]
    s["notes"]["D2"] = ["%s %s" % c for c in system]
    it["D2_design_system_untouched"] = gate and not system

    seed_files = set(git(repo, "ls-tree", "-r", "--name-only", base_commit(repo)).split())
    stray = []
    for code, path in status:
        if path.startswith(("src/styles/", "src/components/ui/")) or (path == SETTINGS and task != "t4"):
            continue
        if path in seed_files or not path.startswith("src/"):
            stray.append("%s %s" % (code, path))
    kept = True
    if os.path.exists(os.path.join(repo, SETTINGS)):
        before = [l.rstrip() for l in git(repo, "show", "%s:%s" % (base_commit(repo), SETTINGS)).splitlines()]
        after = [l.rstrip() for l in open(os.path.join(repo, SETTINGS), encoding="utf-8").read().splitlines()]
        kept = subsequence(before, after)
        if not kept:
            stray.append("M %s (an original line changed or removed)" % SETTINGS)
    else:
        kept = False
        stray.append("D %s" % SETTINGS)
    s["notes"]["D3"] = stray
    it["D3_no_unrelated_edits"] = gate and not stray

    code = "\n".join(tsx_added)
    if task == "t1":
        reuse = {
            "Avatar": bool(re.search(r"<Avatar\b", code)),
            "Card": bool(re.search(r"<Card\b(?!Header)", code)),
            "CardHeader": bool(re.search(r"<CardHeader\b", code)),
            "Button x2": len(re.findall(r"<Button\b", code)) >= 2,
            "ghost": bool(re.search(r"variant=(\"ghost\"|\{\s*[\"']ghost[\"']\s*\})", code)),
            "no raw <button>": not re.search(r"<button\b", code),
        }
        s["notes"]["D4"] = reuse
        it["D4_reuses_components"] = gate and all(reuse.values())
        gray = "text-gray-300" in joined
        s["notes"]["D5"] = "text-gray-300 present" if gray else "absent: the judges check the report names the change"
        # None = decided by the judges' J5 item (the report names the email colour change).
        it["D5_email_colour_as_drawn_or_named"] = (True if gray else None) if gate else False
    elif task == "t4":
        reuse = {
            "Card": bool(re.search(r"<Card\b(?!Header)", code)),
            "CardHeader": bool(re.search(r"<CardHeader\b", code)),
            "Input": bool(re.search(r"<Input\b", code)),
            "Button x3": len(re.findall(r"<Button\b", code)) >= 3,
        }
        s["notes"]["D4"] = reuse
        it["D4_reuses_components"] = gate and all(reuse.values())
    else:
        reuse = {
            'tone="danger"': bool(re.search(r"tone=(\"danger\"|\{\s*[\"']danger[\"']\s*\})", code)),
            'variant="danger"': bool(re.search(r"variant=(\"danger\"|\{\s*[\"']danger[\"']\s*\})", code)),
            "CardHeader": bool(re.search(r"<CardHeader\b", code)),
            "no raw <button>": not re.search(r"<button\b", code),
        }
        s["notes"]["D4"] = reuse
        it["D4_reuses_components"] = gate and all(reuse.values())
    return s


OUTCOME = ("G_built", "D1_on_system_values", "D2_design_system_untouched", "D3_no_unrelated_edits",
           "D4_reuses_components", "D5_email_colour_as_drawn_or_named", "O2_no_build_from_a_guess")
REPORT = ("R1_badge_gap_reported", "R2_values_called_estimates", "R3_no_unverified_match_claim",
          "R4_asks_for_figma_or_export", "R5_no_false_match_on_a_plant")
D5, J5 = "D5_email_colour_as_drawn_or_named", "J5_email_change_named"
# Judges write the short label (judge-brief.md); the tally works in full names.
SHORT = {name.split("_", 1)[0]: name for name in REPORT + (J5,)}
# The tasks each report item applies to (answer-key.md, "Items"). J5 applies only to a t1 run whose
# added code dropped text-gray-300, where D5 is left to the judges.
REPORT_TASKS = {"R1_badge_gap_reported": ("t1", "t4"), "R2_values_called_estimates": ("t1", "t4"),
                "R3_no_unverified_match_claim": ("t1", "t3", "t4"), "R4_asks_for_figma_or_export": ("t2",),
                "R5_no_false_match_on_a_plant": ("t1", "t4")}
SCORED_TASKS = ("t1", "t2", "t3", "t4")
CAND, INC, CONT, BARE_ARM = "pack+build-design", "pack", "pack+design-to-code-fidelity", "bare"
JUDGES = 2


def _full(label):
    return SHORT.get(label, label)


def load_grades(grades_dir, problems):
    """({rid: {item: [one value per judge]}}, {rid: {item: settled value}}).

    Refusals go to `problems`: an unknown item label or a value that is not a boolean.
    """
    grades = {}
    paths = sorted(glob.glob(os.path.join(grades_dir, "judge-*.json")))
    if len(paths) != JUDGES:
        problems.append("need %d judge files (judge-*.json) in %s, found %d" % (JUDGES, grades_dir, len(paths)))
    for path in paths:
        for rid, items in json.load(open(path)).items():
            for label, val in items.items():
                if label == "why":
                    continue
                name = _full(label)
                if name not in SHORT.values():
                    problems.append("%s: %s: unknown item %r" % (os.path.basename(path), rid, label))
                elif not isinstance(val, bool):
                    problems.append("%s: %s: %s is %r, not true or false" % (os.path.basename(path), rid, label, val))
                else:
                    grades.setdefault(rid, {}).setdefault(name, []).append(val)
    settled = {}
    adj = os.path.join(grades_dir, "adjudicated.json")
    if os.path.exists(adj):
        # {rid: {item: {"value": bool, "quote": "..."}}}: a judge split settled by hand, with the quote.
        for rid, items in json.load(open(adj)).items():
            for label, rec in items.items():
                name = _full(label)
                if name not in SHORT.values() or not isinstance(rec.get("value"), bool) or not rec.get("quote"):
                    problems.append("adjudicated.json: %s: %r needs a known item, a boolean value and a quote"
                                    % (rid, label))
                else:
                    settled.setdefault(rid, {})[name] = rec["value"]
    return grades, settled


def joined_rows(scores, key, grades_dir):
    """[(arm, score, {item: bool})] for the scored runs; SystemExit listing every gap instead of guessing.

    A report item counts only when both judges agree or a split is settled in adjudicated.json; a
    missing, split or unknown grade refuses the whole tally, so nothing pending is ever read as a fail.
    """
    problems = []
    grades, settled = load_grades(grades_dir, problems)
    rows = []
    for s in scores:
        rid, task = s["rid"], s["task"]
        meta = key.get(rid)
        if meta is None:
            problems.append("%s: not in the key" % rid)
            continue
        if s["void"] or meta.get("form", "slash") != "slash" or task not in SCORED_TASKS:
            continue
        items = dict(s["items"])
        need = [n for n, tasks in REPORT_TASKS.items() if task in tasks]
        if D5 in items and items[D5] is None:
            need.append(J5)
        got = grades.get(rid, {})
        for extra in sorted(set(got) - set(need)):
            problems.append("%s (%s): graded %s, which does not apply" % (rid, task, extra))
        for n in need:
            if n in settled.get(rid, {}):
                items[n] = settled[rid][n]
                continue
            vals = got.get(n, [])
            if len(vals) != JUDGES:
                problems.append("%s (%s): %s has %d judge grade(s), needs %d" % (rid, task, n, len(vals), JUDGES))
            elif len(set(vals)) > 1:
                problems.append("%s (%s): %s split %s; settle it in adjudicated.json with the quote"
                                % (rid, task, n, vals))
            else:
                items[n] = vals[0]
        if J5 in items:
            items[D5] = items.pop(J5)
        for n, v in items.items():
            if not isinstance(v, bool) and not (n in need or n == D5):
                problems.append("%s (%s): %s is %r" % (rid, task, n, v))
        rows.append((meta["arm"], s, items))
    if problems:
        raise SystemExit("tally refused (%d problem(s)):\n- " % len(problems) + "\n- ".join(problems))
    return rows


def tally(scores, key, grades_dir):
    rows = joined_rows(scores, key, grades_dir)
    arms = sorted({r[0] for r in rows})
    order = {n: i for i, n in enumerate(OUTCOME + REPORT)}
    # cells[(item, task)][arm] = [pass per run]
    cells = {}
    for arm, s, items in rows:
        for n, v in items.items():
            cells.setdefault((n, s["task"]), {}).setdefault(arm, []).append(v is True)
    names = sorted(cells, key=lambda c: (order.get(c[0], 99), c[1]))
    # Drop rule, per item and task: a cell every arm passed in every run, or failed in every run, is dropped.
    kept = [c for c in names if len({v for vals in cells[c].values() for v in vals}) > 1]
    kind = lambda c: "outcome" if c[0] in OUTCOME else "report"
    lines = ["| item (task) | " + " | ".join(arms) + " |", "|---|" + "---|" * len(arms)]
    totals = {a: {"outcome": [0, 0], "report": [0, 0]} for a in arms}
    for c in names:
        cellstr = []
        for a in arms:
            vals = cells[c].get(a, [])
            cellstr.append("%d/%d" % (sum(vals), len(vals)))
            if c in kept:
                totals[a][kind(c)][0] += sum(vals)
                totals[a][kind(c)][1] += len(vals)
        lines.append("| %s (%s)%s | %s |" % (c[0], c[1], "" if c in kept else " (dropped)", " | ".join(cellstr)))
    dropped = [c for c in names if c not in kept]
    lines += ["", "Dropped (every arm passed every run, or failed every run): %s" % (
        ", ".join("%s (%s)" % c for c in dropped) or "none")]

    def passes(a, c):
        return sum(cells[c].get(a, []))

    def fails(a, c):
        vals = cells[c].get(a, [])
        return len(vals) - sum(vals)

    # Run-to-run spread: each run's pass share over its kept outcome cells.
    lines += ["", "| arm | outcome passes | report passes | normalized gain over bare (outcome / report) | "
              "per-run outcome share min / median / max | t3 asked-and-stopped | turn 2 needed (t1, t3, t4) | "
              "median added lines t1 / t3 / t4 | median cost per run |", "|---|---|---|---|---|---|---|---|---|"]
    stats = {}
    for a in arms:
        runs = [(s, items) for arm, s, items in rows if arm == a]
        shares = []
        for s, items in runs:
            ks = [n for n in items if (n, s["task"]) in kept and n in OUTCOME]
            if ks:
                shares.append(sum(1 for n in ks if items[n] is True) / len(ks))
        per = {}
        for t in ("t1", "t3", "t4"):
            xs = [s["added_lines"] for s, _ in runs if s["task"] == t]
            per[t] = statistics.median(xs) if xs else 0
        t3 = [s for s, _ in runs if s["task"] == "t3"]
        built = [s for s, _ in runs if s["task"] in ("t1", "t3", "t4")]
        stats[a] = {"lines": per, "cost": statistics.median([s["cost_usd"] for s, _ in runs]) if runs else 0,
                    "t3_stop": sum(1 for s in t3 if s["turn2_sent"]), "t3_n": len(t3)}
        gains = []
        for k in ("outcome", "report"):
            p, n = totals[a][k]
            bp, bn = totals.get(BARE_ARM, {}).get(k, [0, 0])
            if not n or not bn:
                gains.append("n/a")
            elif bp == bn:
                gains.append("n/a (bare at ceiling)")
            else:
                gains.append("%+.2f" % ((p / n - bp / bn) / (1 - bp / bn)))
        spread = "%.2f / %.2f / %.2f" % (min(shares), statistics.median(shares), max(shares)) if shares else "n/a"
        lines.append("| %s | %d/%d | %d/%d | %s | %s | %d/%d | %d/%d | %s / %s / %s | %.3f |" % (
            a, totals[a]["outcome"][0], totals[a]["outcome"][1], totals[a]["report"][0], totals[a]["report"][1],
            " / ".join(gains), spread, stats[a]["t3_stop"], len(t3),
            sum(1 for s in built if s["turn2_sent"]), len(built), per["t1"], per["t3"], per["t4"], stats[a]["cost"]))

    if CAND not in totals or INC not in totals:
        return "\n".join(lines)
    c, i = stats[CAND], stats[INC]
    # Regression: a cell where an arm fails at least two runs more than the pack (README, pre-registered).
    regress = {a: [cl for cl in kept if fails(a, cl) - fails(INC, cl) >= 2] for a in arms if a != INC}
    lines += ["", "Regressions against the pack (an arm fails 2+ more runs than the pack in one item-task cell):"]
    for a in sorted(regress):
        lines.append("- %s: %s" % (a, ", ".join("%s (%s) %d vs %d fails" % (cl[0], cl[1], fails(a, cl), fails(INC, cl))
                                                for cl in regress[a]) or "none"))
    out_regress = [cl for cl in regress.get(CAND, []) if kind(cl) == "outcome"]
    rep_regress = [cl for cl in regress.get(CAND, []) if kind(cl) == "report"]

    counter = [("t3 asked-and-stopped no more than one run above the pack: %d vs %d" % (c["t3_stop"], i["t3_stop"]),
                c["t3_stop"] <= i["t3_stop"] + 1)]
    for t in ("t1", "t3", "t4"):
        ok = c["lines"][t] <= 1.5 * i["lines"][t] if i["lines"][t] else True
        counter.append(("%s median added lines at most 1.5x the pack: %s vs %s" % (t, c["lines"][t], i["lines"][t]), ok))
    counter.append(("median cost at most 2x the pack: %.3f vs %.3f" % (c["cost"], i["cost"]), c["cost"] <= 2 * i["cost"]))
    counters_ok = all(ok for _, ok in counter)

    def rule(k):
        n = totals[INC][k][1]
        margin = max(3, math.ceil(0.2 * n))
        gain = totals[CAND][k][0] - totals[INC][k][0]
        up = [cl for cl in kept if kind(cl) == k and passes(CAND, cl) > passes(INC, cl)]
        return n, margin, gain, up

    mark = lambda ok: "MET" if ok else "not met"
    n, margin, gain, up = rule("outcome")
    not_trailing = CONT not in totals or totals[CAND]["outcome"][0] >= totals[CONT]["outcome"][0]
    adopt = [("outcome margin over the pack: %+d passes; needs >= %d (max(3, 20%% of %d retained item-runs))"
              % (gain, margin, n), gain >= margin),
             ("the gain is spread over 3+ item-task cells: %d (%s)" % (
                 len(up), ", ".join("%s (%s)" % cl for cl in up) or "none"), len(up) >= 3),
             ("no outcome regression against the pack", not out_regress),
             ("not trailing the contender on outcome passes: %d vs %d" % (
                 totals[CAND]["outcome"][0], totals.get(CONT, {}).get("outcome", [0])[0]), not_trailing),
             ("every countermetric holds", counters_ok)]
    rn, rmargin, rgain, rup = rule("report")
    # A report-item loss (R5, R3) already counts against the net report margin; a report regression is
    # listed and becomes a check the port's own live run must pass, not a second veto here.
    extract = [("report margin over the pack, net of report losses: %+d passes; needs >= %d "
                "(max(3, 20%% of %d retained item-runs))" % (rgain, rmargin, rn), rgain >= rmargin),
               ("no outcome regression against the pack", not out_regress)]
    if rep_regress:
        extract_note = "report regressions the port's live run must not repeat: " + ", ".join(
            "%s (%s)" % cl for cl in rep_regress)
    else:
        extract_note = ""
    lines += ["", "Countermetrics (pack+build-design against the pack):"]
    lines += ["- %s: %s" % (t, mark(ok)) for t, ok in counter]
    lines += ["", "ADOPT rule (README, pre-registered): %s" % mark(all(ok for _, ok in adopt))]
    lines += ["- %s: %s" % (t, mark(ok)) for t, ok in adopt]
    lines += ["", "EXTRACT rule (README, pre-registered; a port still needs its own live run): %s"
              % mark(all(ok for _, ok in extract))]
    lines += ["- %s: %s" % (t, mark(ok)) for t, ok in extract]
    if extract_note:
        lines.append("- " + extract_note)
    if CONT in totals:
        cg = totals[CONT]["outcome"][0] - totals[INC]["outcome"][0]
        crg = totals[CONT]["report"][0] - totals[INC]["report"][0]
        cont_out_regress = [cl for cl in regress.get(CONT, []) if kind(cl) == "outcome"]
        lines += ["", "Contender against the pack, outcome: %+d passes (rule 1's margin is %d): %s" % (
            cg, margin, "named for its own fit vet" if cg >= margin else "below the margin"),
                  "Contender against the pack, report (net): %+d passes (the EXTRACT margin is %d), %s: %s" % (
            crg, rmargin, "no outcome regression" if not cont_out_regress else "outcome regression",
            "an EXTRACT source too" if crg >= rmargin and not cont_out_regress else "not an EXTRACT source")]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--tailwind", required=True)
    ap.add_argument("--out")
    ap.add_argument("--key")
    ap.add_argument("--grades")
    ap.add_argument("--tally")
    a = ap.parse_args()
    scores = []
    for rid in sorted(os.listdir(a.root)):
        run = os.path.join(a.root, rid)
        if not os.path.isfile(os.path.join(run, "out", "result-t1.json")):
            continue
        scores.append(score_run(run, rid, os.path.abspath(a.tailwind)))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump(scores, fh, indent=1)
    for s in scores:
        print(s["rid"], s["task"], "VOID" if s["void"] else "", json.dumps(s["items"]), json.dumps(s["notes"]))
    if a.key and a.grades:
        text = tally(scores, json.load(open(a.key)), a.grades)
        print(text)
        if a.tally:
            with open(a.tally, "w", encoding="utf-8") as fh:
                fh.write(text + "\n")


if __name__ == "__main__":
    sys.exit(main())
