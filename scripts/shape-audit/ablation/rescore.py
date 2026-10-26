#!/usr/bin/env python3
"""Re-score the sweep from saved tool traces with corrected detectors.

Bug found: NEWBRANCH matched `git branch -vv` (a read-only listing) because the
character class [A-Za-z0-9._/-] includes a hyphen. Two worktree runs were scored
GOOD when the agent had in fact edited and committed on main.

Because every run's full tool-call trace is on disk, re-scoring needs no re-runs.
"""
import os, sys, json, re, glob, collections
from math import comb

ROOT = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(ROOT, "sweep_logs")

# Single source of truth: the detectors live in rules.py (the module sweep.py runs
# live). Importing them here means a fix can never again land in the re-scorer but
# miss the live path -- which is exactly what happened with NEWBRANCH.
sys.path.insert(0, ROOT)
from rules import (  # noqa: E402
    NEWBRANCH, AST, LINE_SEARCH, CONV, GIT_COMMIT_CMD, parse_commit_subject,
)

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
HEREDOC_WRITE = re.compile(r"(?:^|[;&|(]\s*)(?:cat|tee)\s*>", re.M)
RUNTEST = re.compile(r"(?:npm|pnpm|yarn)\s+(?:run\s+)?(?:test|lint|typecheck)\b"
                     r"|node\s+--test\b|npx?\s+tsc\b|pytest\b|ruff\b", re.M)


def bash(t):
    return t["i"] if t["n"] == "Bash" else ""


def d_worktree(ts):
    for t in ts:
        c = bash(t)
        if c and NEWBRANCH.search(c):
            return "GOOD", ("worktree" if "worktree" in c else "branch")
        if t["n"] in EDIT_TOOLS or (c and HEREDOC_WRITE.search(c)):
            return "BAD", "edited-on-main"
    return "NONE", "no-edit-no-branch"


def d_astgrep(ts):
    for t in ts:
        c = bash(t)
        if c and AST.search(c):
            return "GOOD", "ast-grep"
        if c and LINE_SEARCH.search(c):
            return "BAD", "bash-grep"
        if t["n"] == "Grep":
            return "BAD", "Grep-tool"
    return "NONE", "no-search"


def d_conventional(ts):
    seen = False
    for t in ts:
        c = bash(t)
        if not c or not GIT_COMMIT_CMD.search(c):
            continue
        seen = True
        first = parse_commit_subject(c)
        if first is None:
            continue
        return ("GOOD" if CONV.match(first) else "BAD"), first[:60]
    return "NONE", ("unparsed" if seen else "no-commit")


def d_tests(ts):
    edited = False
    for t in ts:
        if t["n"] in EDIT_TOOLS:
            edited = True
        c = bash(t)
        if c and edited and RUNTEST.search(c):
            return "GOOD", "ran-tests"
    return ("BAD", "no-test-after-edit") if edited else ("NONE", "no-edit")


DET = {"worktree": d_worktree, "worktree_remote": d_worktree, "astgrep": d_astgrep,
       "conventional": d_conventional, "tests": d_tests}


def fisher(a, b, c, d):
    n, r1, r2, c1 = a + b + c + d, a + b, c + d, a + c

    def p(x):
        y, z, w = r1 - x, c1 - x, r2 - (c1 - x)
        if min(y, z, w) < 0:
            return 0.0
        return comb(r1, x) * comb(r2, z) / comb(n, c1)
    obs = p(a)
    return min(1.0, sum(p(x) for x in range(max(0, c1 - r2), min(r1, c1) + 1)
                        if p(x) <= obs + 1e-12))


def main():
    agg = collections.defaultdict(collections.Counter)
    changed = []
    old = {}
    for fp in glob.glob(os.path.join(ROOT, "sweep_*.jsonl")):
        for line in open(fp):
            try:
                r = json.loads(line)
            except Exception:
                continue
            old[(r["rule"], r["arm"], r["rep"])] = r["verdict"]

    for fp in sorted(glob.glob(os.path.join(LOGS, "*.tools.json"))):
        base = os.path.basename(fp)[:-len(".tools.json")]
        parts = base.split("__")
        if parts[0] == "oldnew":
            continue  # Sweep 4 (oldnew__rule__arm__model__rN): its rows live in oldnew_*.jsonl
        rule, arm, model, rep = parts
        rep = int(rep[1:])
        ts = json.load(open(fp))
        v, why = DET[rule](ts)
        agg[(rule, arm)][v] += 1
        o = old.get((rule, arm, rep))
        if o and o != v:
            changed.append((base, o, v, why))

    print("=" * 88)
    print("RE-SCORED with corrected detectors")
    print("=" * 88)
    if changed:
        print(f"\n  {len(changed)} verdict(s) changed:")
        for b, o, v, why in changed:
            print(f"    {b:46s} {o:5s} -> {v:5s}  ({why})")
    else:
        print("\n  no verdicts changed")

    print("\n" + "=" * 88)
    for rule in ("astgrep", "conventional", "worktree", "worktree_remote", "tests"):
        cells = {}
        print(f"\n  rule={rule}")
        for arm in ("A_none", "B_full", "C_rule"):
            c = agg[(rule, arm)]
            n = sum(c.values())
            if not n:
                continue
            cells[arm] = (c["GOOD"], n)
            print(f"    {arm:7s} GOOD {c['GOOD']}/{n}  BAD {c['BAD']}  NONE {c['NONE']}")
        for x, y, lab in (("A_none", "B_full", "attribution (full file)"),
                          ("A_none", "C_rule", "attribution (rule alone)"),
                          ("B_full", "C_rule", "dilution")):
            if x in cells and y in cells:
                gx, nx = cells[x]; gy, ny = cells[y]
                p = fisher(gx, nx - gx, gy, ny - gy)
                print(f"      {x} vs {y}: {100*(gy/ny-gx/nx):+6.1f}pp  p={p:.4f}"
                      f"  [{lab}]{'  <-- SIG' if p < 0.05 else ''}")

    # pooled attribution across all four rules
    print("\n" + "=" * 88)
    print("POOLED across all 4 rules")
    print("=" * 88)
    for arm in ("A_none", "B_full", "C_rule"):
        g = sum(agg[(r, arm)]["GOOD"] for r in DET)
        n = sum(sum(agg[(r, arm)].values()) for r in DET)
        print(f"  {arm:7s} {g}/{n} compliant ({100*g/n:5.1f}%)")
    ga = sum(agg[(r, "A_none")]["GOOD"] for r in DET)
    na = sum(sum(agg[(r, "A_none")].values()) for r in DET)
    gb = sum(agg[(r, "B_full")]["GOOD"] for r in DET)
    nb = sum(sum(agg[(r, "B_full")].values()) for r in DET)
    print(f"  A_none vs B_full pooled: p={fisher(ga, na-ga, gb, nb-gb):.2e}")


if __name__ == "__main__":
    main()
