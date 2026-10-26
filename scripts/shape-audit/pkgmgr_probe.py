#!/usr/bin/env python3
"""Feasibility probe for the highest-value UNTESTED rule: package managers.

CLAUDE.md marks this CRITICAL:
    Python packages -> uv pip install   (NEVER pip, pip3)
    Python apps     -> pipx install     (NEVER pip install --user)
    Node packages   -> pnpm install/add (NEVER npm, yarn)

Unlike the response-shape detectors, this has ~perfect precision: it is a string
match on an actual executed command, not a semantic judgment about prose. This is
the same measurement Gloaguen et al. used to show policy directives ARE followed
(uv calls went <0.01 -> 1.6 per instance when named in a context file).

Counts Bash tool_use commands across all transcripts.
"""
import os, sys, json, re, time, collections, datetime as _dt
from concurrent.futures import ProcessPoolExecutor

P = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
NOW = time.time()
WINDOW_DAYS = 25

# Anchor at a command position: start of line, or after && || ; | ( or shell kw.
def cmd_rx(pat):
    return re.compile(r"(?:^|[;&|(]\s*|\b(?:then|do|else)\s+)" + pat, re.M)

RULES = {
    "node": {
        "good": {"pnpm": cmd_rx(r"pnpm\s+(?:i|install|add|remove|up|update|dlx|run|exec)\b")},
        "bad": {
            "npm": cmd_rx(r"npm\s+(?:i|install|add|ci|uninstall|update|run)\b"),
            "yarn": cmd_rx(r"yarn\s+(?:add|install|remove|up|upgrade)\b"),
        },
    },
    "python-pkg": {
        "good": {"uv pip": cmd_rx(r"uv\s+pip\s+install\b"), "uv add": cmd_rx(r"uv\s+add\b")},
        "bad": {"pip install": cmd_rx(r"pip3?\s+install\b(?!\s+--user)")},
    },
    "python-app": {
        "good": {"pipx": cmd_rx(r"pipx\s+install\b")},
        "bad": {"pip --user": cmd_rx(r"pip3?\s+install\s+--user\b")},
    },
}
# relaxed / explicitly allowed by CLAUDE.md
NEUTRAL = {
    "npx": cmd_rx(r"npx\s+"),
    "pnpx": cmd_rx(r"pnpx\s+"),
    "python -m venv": cmd_rx(r"python3?\s+-m\s+venv\b"),
    "uv venv": cmd_rx(r"uv\s+venv\b"),
}


def scan(fp):
    counts = collections.Counter()
    samples = collections.defaultdict(list)
    try:
        with open(fp, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"tool_use"' not in line or '"Bash"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message") or {}
                c = msg.get("content")
                if not isinstance(c, list):
                    continue
                for blk in c:
                    if not isinstance(blk, dict) or blk.get("type") != "tool_use":
                        continue
                    if blk.get("name") != "Bash":
                        continue
                    cmd = (blk.get("input") or {}).get("command") or ""
                    if not cmd:
                        continue
                    for fam, sides in RULES.items():
                        for side, pats in sides.items():
                            for nm, rx in pats.items():
                                if rx.search(cmd):
                                    counts[(fam, side, nm)] += 1
                                    if len(samples[nm]) < 4:
                                        samples[nm].append(cmd.strip().replace("\n", " ")[:120])
                    for nm, rx in NEUTRAL.items():
                        if rx.search(cmd):
                            counts[("neutral", "neutral", nm)] += 1
    except Exception:
        return collections.Counter(), {}
    return counts, dict(samples)


def main():
    files = []
    for root, _, fns in os.walk(P):
        for fn in fns:
            if fn.endswith(".jsonl"):
                fp = os.path.join(root, fn)
                try:
                    if (NOW - os.stat(fp).st_mtime) < WINDOW_DAYS * 86400:
                        files.append(fp)
                except OSError:
                    pass
    print(f"scanning {len(files)} transcripts for Bash tool calls", file=sys.stderr)
    total = collections.Counter()
    allsamp = collections.defaultdict(list)
    with ProcessPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as ex:
        for c, s in ex.map(scan, files, chunksize=8):
            total.update(c)
            for k, v in s.items():
                if len(allsamp[k]) < 4:
                    allsamp[k].extend(v[: 4 - len(allsamp[k])])

    print("\n" + "=" * 92)
    print("PACKAGE-MANAGER RULE ADHERENCE  (CLAUDE.md 'Package Managers - CRITICAL')")
    print("=" * 92)
    for fam in ("node", "python-pkg", "python-app"):
        good = {k[2]: v for k, v in total.items() if k[0] == fam and k[1] == "good"}
        bad = {k[2]: v for k, v in total.items() if k[0] == fam and k[1] == "bad"}
        g, b = sum(good.values()), sum(bad.values())
        n = g + b
        rate = (100.0 * g / n) if n else float("nan")
        print(f"\n  {fam.upper()}   adherence {rate:5.1f}%   ({g:,} compliant / {n:,} total)")
        for k, v in sorted(good.items(), key=lambda x: -x[1]):
            print(f"      OK   {k:14s} {v:6,d}")
        for k, v in sorted(bad.items(), key=lambda x: -x[1]):
            print(f"      VIOL {k:14s} {v:6,d}")
            for s in allsamp.get(k, [])[:3]:
                print(f"            e.g. {s}")

    print("\n  NEUTRAL (CLAUDE.md relaxed these 2026-07-23 — either form is fine):")
    for k, v in sorted(((k[2], v) for k, v in total.items() if k[0] == "neutral"), key=lambda x: -x[1]):
        print(f"      {k:16s} {v:6,d}")
    print("\n  NOTE: repo-level AGENTS.md/CLAUDE.md may legitimately override (e.g. pi-lens is npm")
    print("  by design), so a nonzero violation count is an upper bound, not a verdict.")


if __name__ == "__main__":
    main()
