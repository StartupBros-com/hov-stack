#!/usr/bin/env python3
"""Report whether a Claude Code session is holding a git worktree.

A session that entered a worktree and then sat idle holds it without any process
showing it: a background job records its launch checkout as `cwd`, and edits deep
in the tree leave the worktree's top-directory mtime alone. On 2026-11-03 wt-sweep
removed such a worktree from under a working job (hov-stack#384). This reads what
Claude Code itself records, under the Claude home directory:

  jobs/<id>/state.json    a job that is not `done` holds the worktree it names in
                          `worktreePath` or `cwd`, or whose transcript project
                          directory (`linkScanPath`) is the worktree's slug;
  sessions/<pid>.json     a session whose `cwd` is inside the worktree holds it
                          while that pid runs (`procStart` guards pid reuse);
  projects/<slug>/        a transcript written there within --active-min minutes.

The slug is the worktree path with every character outside [A-Za-z0-9] replaced
by `-`, which is how Claude Code names transcript project directories.

Not seen: a session that works in a worktree only from elsewhere (`git -C`, or a
`cd` recorded inside a transcript filed under another project). No record above
names that worktree, so the caller's mtime gate and process scan are its only
cover.

Exit 0: held; one line on stdout names the holder.
Exit 1: not held; stdout may carry `resumable:` lines naming finished jobs whose
        transcripts live under this worktree (a resume would find it gone).
Exit 2: bad arguments. Callers treat any exit other than 1 as held.

A missing Claude home, or a missing jobs/sessions/projects directory, means no
sessions. A record that cannot be parsed is reported on stderr and skipped: a
half-written state file must not stop every sweep, and a session that is really
working keeps writing its transcript.
"""

import argparse
import glob
import json
import os
import re
import sys
import time


def slug(path: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def inside(child: str, root: str) -> bool:
    child, root = os.path.normpath(child), os.path.normpath(root)
    return child == root or child.startswith(root.rstrip("/") + "/")


def load(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        print(f"wt_session_hold: skipped unreadable {path}: {e}", file=sys.stderr)
        return None


def pid_running(pid, proc_start, procfs: str) -> bool:
    try:
        with open(os.path.join(procfs, str(int(pid)), "stat"), encoding="utf-8") as f:
            stat = f.read()
    except (OSError, ValueError, TypeError):
        return False
    if proc_start in (None, ""):
        return True
    # Field 22 (starttime). comm may contain spaces, so split after its ')'.
    fields = stat.rsplit(")", 1)[-1].split()
    return len(fields) > 19 and fields[19] == str(proc_start)


def check(wt: str, home: str, active_min: int, procfs: str):
    """Return (holder or None, [resumable lines])."""
    wt = os.path.normpath(wt)
    wt_slug = slug(wt)
    resumable = []

    for path in sorted(glob.glob(os.path.join(home, "jobs", "*", "state.json"))):
        d = load(path)
        if not isinstance(d, dict):
            continue
        job = os.path.basename(os.path.dirname(path))
        named = [p for p in (d.get("worktreePath"), d.get("cwd")) if isinstance(p, str) and p]
        link = d.get("linkScanPath")
        project = os.path.basename(os.path.dirname(link)) if isinstance(link, str) and link else ""
        if not (any(inside(p, wt) for p in named) or project == wt_slug):
            continue
        label = f'job {job} "{d.get("name") or ""}"'
        if d.get("state") == "done":
            resumable.append(f"resumable: {label} is done; resuming it would find this worktree gone")
            continue
        return f'{label} is {d.get("state") or "in an unknown state"}', resumable

    for path in sorted(glob.glob(os.path.join(home, "sessions", "*.json"))):
        d = load(path)
        if not isinstance(d, dict):
            continue
        cwd = d.get("cwd")
        if isinstance(cwd, str) and cwd and inside(cwd, wt) and pid_running(d.get("pid"), d.get("procStart"), procfs):
            return f'session pid {d.get("pid")} "{d.get("name") or ""}" has its cwd here', resumable

    project_dir = os.path.join(home, "projects", wt_slug)
    newest = 0.0
    for path in glob.glob(os.path.join(project_dir, "**", "*.jsonl"), recursive=True):
        try:
            newest = max(newest, os.stat(path).st_mtime)
        except OSError:
            continue
    if newest:
        age_min = (time.time() - newest) / 60
        if age_min < active_min:
            return f"a transcript under {project_dir} was written {int(age_min)}m ago", resumable

    return None, resumable


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--active-min", type=int, default=120, help="transcript recency window, minutes")
    ap.add_argument("--claude-home", default=os.environ.get("WT_CLAUDE_HOME") or os.path.expanduser("~/.claude"))
    ap.add_argument("--procfs", default="/proc", help="procfs root (tests)")
    ap.add_argument("worktree")
    args = ap.parse_args(argv)
    holder, resumable = check(args.worktree, args.claude_home, args.active_min, args.procfs)
    if holder:
        print(holder)
        return 0
    for line in resumable:
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
