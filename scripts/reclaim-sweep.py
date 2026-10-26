#!/usr/bin/env python3
"""reclaim-sweep — reclaim self-heal and backup residue left by agent tooling.

WHY THIS EXISTS (audit 2026-08-06)
  ~45 GB of dead weight had accumulated on this box, and every byte of it came from
  the same habit: **tools self-heal or back up by RENAMING or COPYING, never by
  deleting, and nothing ever collects the corpses.**

    22.0 GB  ~/.local/share/coding-agent-search.broken-20260703234413/
             an ONNX bug corrupted the cass index on 2026-07-03; its recover.sh
             renamed the whole tree aside and rebuilt. The rename is documented.
             The cleanup is not, because there isn't one.
    16.6 GB  better-ccflare pre-migration snapshots (.db.bak-*, pre-*-backup-*.db)
     4.5 GB  ~/.claude/jobs/ — no age-out at all; `cleanupPeriodDays` is unset
     0.3 GB  statusline-stack .bak/.broken recovery points back to 2026-06-19

  None of it is a bug in any single tool. Each rename was correct in isolation.
  The gap is that nobody owns the second half of the transaction.

DESIGN
  Rules are declarative and closed: a path is a candidate ONLY if it matches a
  rule's glob AND clears that rule's age floor AND is not among the newest N the
  rule preserves. Anything unmatched is invisible to this script — it can never
  "discover" something to delete.

  DRY_RUN is the default and `--apply` is required to remove anything, matching
  wt-sweep.sh / docker-hygiene.sh. Held paths are skipped — held meaning any live
  process has an open fd inside, its cwd inside, or the path in its environment or
  argv (shared check in lib/proc_liveness.py, issue #378): a 22 GB directory that
  some process still holds is not residue, it is live state.

Usage:
  reclaim-sweep.py              # plan only (default)
  reclaim-sweep.py --apply      # actually remove
  reclaim-sweep.py --json       # machine-readable
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import sys
import time

# Shared liveness check (fd + cwd + cmdline), one implementation for every
# sweeper — see lib/proc_liveness.py and issue #378 for why fd-only was a hole.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
import proc_liveness  # noqa: E402

HOME = os.path.expanduser("~")
DAY = 86400

# A path must live at least this deep to be touchable, so a malformed glob can
# never resolve to $HOME or a top-level config directory.
MIN_DEPTH_BELOW_HOME = 2


class Rule:
    def __init__(self, name, pattern, min_age_days, keep_newest=0, why="", dirs_only=False):
        self.name = name
        self.pattern = pattern
        self.min_age_days = min_age_days
        self.keep_newest = keep_newest
        self.why = why
        # A `<dir>/*` glob catches sibling FILES that are real state, not scratch.
        # The first live run of this script proposed deleting ~/.claude/jobs/pins.json
        # — pinned-job state — alongside the job directories. Rules whose unit of
        # residue is a directory must say so.
        self.dirs_only = dirs_only


# Ordered most- to least-valuable. Age floors are deliberately generous: this runs
# weekly and unattended, so the cost of waiting another week is zero and the cost of
# deleting something still wanted is not.
RULES = [
    Rule(
        "cass-broken-index",
        f"{HOME}/.local/share/*.broken-*",
        min_age_days=14,
        why="index tree renamed aside by a self-heal path that never cleans up",
    ),
    Rule(
        "ccflare-db-backup",
        f"{HOME}/.config/better-ccflare/*.db.bak-*",
        min_age_days=14,
        keep_newest=1,
        why="pre-migration DB snapshot; the app never reads these at runtime",
    ),
    Rule(
        "ccflare-version-backup",
        f"{HOME}/.config/better-ccflare/pre-*-backup-*.db",
        min_age_days=14,
        keep_newest=1,
        why="pre-upgrade DB snapshot; superseded once the upgrade is proven",
    ),
    Rule(
        "ccflare-named-backup",
        f"{HOME}/.config/better-ccflare/backups/*.db",
        min_age_days=30,
        keep_newest=1,
        why="named recovery point; keep the most recent only",
    ),
    Rule(
        "ccflare-codex-trace",
        f"{HOME}/.config/better-ccflare/codex-traces/codex-trace-*.jsonl",
        min_age_days=14,
        keep_newest=2,
        why="unbounded append trace with no retention code in trace.ts",
    ),
    Rule(
        "statusline-recovery-point",
        f"{HOME}/.config/statusline-stack/*.bak.*",
        min_age_days=30,
        why="dated recovery point from a statusline migration",
    ),
    Rule(
        "statusline-broken-snapshot",
        f"{HOME}/.config/statusline-stack/*.broken.*",
        min_age_days=30,
        why="snapshot of a settings.json that was already repaired",
    ),
    Rule(
        "claude-job-dir",
        f"{HOME}/.claude/jobs/*",
        min_age_days=30,
        dirs_only=True,
        why="background-job scratch; no age-out exists anywhere else",
    ),
    Rule(
        "inspect-ai-samplebuffer",
        f"{HOME}/.local/share/inspect_ai/samplebuffer/*",
        min_age_days=30,
        dirs_only=True,
        why="eval sample buffer from a finished run",
    ),
]


def dir_size(path: str) -> int:
    if os.path.islink(path):
        return 0
    if os.path.isfile(path):
        try:
            return os.path.getsize(path)
        except OSError:
            return 0
    total = 0
    for root, dirs, files in os.walk(path, onerror=lambda e: None):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        for f in files:
            fp = os.path.join(root, f)
            try:
                if not os.path.islink(fp):
                    total += os.path.getsize(fp)
            except OSError:
                continue
    return total


def is_safe_target(path: str) -> bool:
    """Refuse anything shallow enough to be a real config root, or outside $HOME."""
    real = os.path.realpath(path)
    home = os.path.realpath(HOME)
    if real == home or not real.startswith(home + os.sep):
        return False
    depth = real[len(home) + 1:].count(os.sep) + 1
    return depth >= MIN_DEPTH_BELOW_HOME


def plan(now: float, snap) -> list[dict]:
    out = []
    for rule in RULES:
        matches = sorted(glob.glob(rule.pattern))
        # newest-first by mtime so keep_newest preserves the most recent
        dated = []
        for m in matches:
            try:
                dated.append((os.path.getmtime(m), m))
            except OSError:
                continue
        dated.sort(reverse=True)
        for idx, (mtime, path) in enumerate(dated):
            age_days = (now - mtime) / DAY
            if idx < rule.keep_newest:
                continue
            if age_days < rule.min_age_days:
                continue
            if rule.dirs_only and not os.path.isdir(path):
                continue
            if not is_safe_target(path):
                continue
            holder = snap.holder(path)
            skip = f"held by a live process ({holder.signal}, pid {holder.pid})" if holder else None
            out.append({
                "rule": rule.name,
                "path": path,
                "bytes": dir_size(path),
                "age_days": round(age_days, 1),
                "why": rule.why,
                "skip": skip,
            })
    return out


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}PB"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # RECLAIM_SWEEP_APPLY=1 mirrors the DRY_RUN=0 convention the other hygiene
    # scripts (wt-sweep.sh, docker-hygiene.sh) use for systemd Environment=
    # staging, so a timer can be shipped observe-only and later graduated to
    # auto-apply by flipping one unit-file line instead of editing ExecStart.
    # --apply on the command line always wins; interactive/manual runs are
    # unaffected unless that env var is explicitly exported.
    ap.add_argument(
        "--apply", action="store_true",
        default=os.environ.get("RECLAIM_SWEEP_APPLY") == "1",
        help="actually remove (default: plan only; or set RECLAIM_SWEEP_APPLY=1)",
    )
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--now", type=float, default=None, help="override clock (tests)")
    args = ap.parse_args(argv)

    now = args.now if args.now is not None else time.time()
    # An answerless liveness scan must abort BOTH modes, not degrade to
    # "nothing is held": an apply would delete live state, and a plan would
    # print a lie that later graduates to an apply. Fail closed (issue #378).
    #
    # exclude_pids=frozenset(): unlike the CLI (whose argv necessarily names
    # the queried paths, so it must exclude itself), reclaim-sweep's own argv
    # carries no candidate paths — and excluding self once blinded it to its
    # OWN cwd, so an operator who cd'd into a target dir and ran --apply by
    # hand would have had it rmtree'd out from under their shell (#384 vet).
    snap = proc_liveness.ProcSnapshot(exclude_pids=frozenset())
    if not snap.ok:
        print("reclaim-sweep: liveness scan saw no processes — refusing to plan or apply",
              file=sys.stderr)
        return 1
    items = plan(now, snap)
    actionable = [i for i in items if not i["skip"]]
    skipped = [i for i in items if i["skip"]]
    total = sum(i["bytes"] for i in actionable)

    removed, failed = [], []
    if args.apply:
        for i in actionable:
            try:
                if os.path.isdir(i["path"]) and not os.path.islink(i["path"]):
                    shutil.rmtree(i["path"])
                else:
                    os.remove(i["path"])
                removed.append(i["path"])
            except OSError as e:
                failed.append(f"{i['path']}: {e}")

    if args.json:
        print(json.dumps({
            "actionable": actionable, "skipped": skipped,
            "total_bytes": total, "removed": removed, "failed": failed,
            "applied": args.apply,
        }, indent=2))
    else:
        mode = "APPLIED" if args.apply else "PLAN (nothing removed — pass --apply)"
        print(f"reclaim-sweep [{mode}]")
        if not actionable and not skipped:
            print("  nothing to reclaim")
        for i in actionable:
            print(f"  {human(i['bytes']):>9}  {i['age_days']:>6.0f}d  {i['rule']:<28} {i['path']}")
            print(f"             {i['why']}")
        for i in skipped:
            print(f"  {'SKIP':>9}  {i['rule']:<28} {i['path']} — {i['skip']}")
        if failed:
            for f in failed:
                print(f"  FAILED: {f}")
        print(f"  total reclaimable: {human(total)} across {len(actionable)} item(s)")
        # Trailing counter for the harness-weekly toast gate, same contract as
        # docker-flagged:N / agent-write-flagged:N.
        print(f"reclaim-flagged:{len(actionable)}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
