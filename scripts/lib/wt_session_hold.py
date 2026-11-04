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
  projects/<slug>/        a transcript written there within --active-min minutes;
  projects/**/*.jsonl     a transcript filed under ANY project holds a worktree its
                          records drive (hov-stack#394), if it belongs to a job that
                          is not done, to a live session, or was written within
                          --active-min minutes. A transcript stays filed under the
                          project its session launched from, so a session that
                          entered a worktree, or works in one with `git -C` or `cd`,
                          is seen only here.

The slug is the worktree path with every character outside [A-Za-z0-9] replaced
by `-`, which is how Claude Code names transcript project directories.

What drives a worktree is a record's `cwd` (it follows EnterWorktree) and the
paths a tool call is given: `file_path`, `path`, `notebook_path`, and every
absolute path in a Bash `command`. Tool results and the text a tool writes
(`content`, `old_string`, ...) do not count, so a session that lists or reports on
worktrees holds none of them. A path the session reached only by a relative `cd`
is not seen.

Reading every candidate transcript in full costs about 40 s (4,044 transcripts,
7.1 GB of 34 GB, on the author's host on 2026-11-03), and a sweep asks once per
worktree, so the paths found are cached per transcript under --cache-dir (a later
call took about 0.5 s) and only bytes appended since are read
(keyed by device, inode and the offset of the last complete line). A transcript
that is replaced or shrinks is read again from the start. Entries for transcripts
that are no longer candidates are dropped. A cache that cannot be read or written
costs time, never an answer.

--exclude-session ID ignores that session's job, session record and transcripts:
wt-done passes its caller's id, since the session closing a worktree out is the
one whose transcript names it. wt-sweep passes none, so a sweep never removes the
worktree its own caller is driving.

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
import tempfile
import time

CACHE_VERSION = 1
_CWD = re.compile(rb'"cwd":"((?:[^"\\]|\\.)*)"')
# An absolute (or ~/) path token in a shell command, after a separator a shell or
# an option would put before it (`git -C /x`, `--cd=/x`, `cd "/x"`, `(cd /x`).
_TOKEN = re.compile(r"""(?:^|(?<=[\s'"=:(]))(~?/[^\s'"`;|&<>(){}$\\,]+)""")
_PATH_FIELDS = ("file_path", "path", "notebook_path")


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


def transcript_owner(path: str) -> str:
    """Session id of a session transcript, `projects/<slug>/<sid>.jsonl`."""
    return os.path.splitext(os.path.basename(path))[0]


def _norm(p: str) -> str:
    if p.startswith("~/"):
        p = os.path.expanduser(p)
    p = os.path.normpath(p).rstrip(".")
    return p or "/"


def _record_paths(line: bytes, found: set) -> None:
    m = _CWD.search(line)
    if m:
        try:
            cwd = json.loads(b'"' + m.group(1) + b'"')
        except ValueError:
            cwd = None
        if isinstance(cwd, str) and cwd.startswith("/"):
            found.add(_norm(cwd))
    if b'"tool_use"' not in line:
        return
    try:
        d = json.loads(line)
    except ValueError:
        return
    msg = d.get("message") if isinstance(d, dict) else None
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return
    for c in content:
        if not (isinstance(c, dict) and c.get("type") == "tool_use"):
            continue
        inp = c.get("input")
        if not isinstance(inp, dict):
            continue
        for k in _PATH_FIELDS:
            v = inp.get(k)
            if isinstance(v, str) and v.startswith(("/", "~/")):
                found.add(_norm(v))
        cmd = inp.get("command")
        if isinstance(cmd, str):
            for t in _TOKEN.findall(cmd):
                found.add(_norm(t))


def scan(path: str, offset: int, found: set, transient: set) -> int:
    """Add the driven paths in `path` from `offset` on; return the offset after the
    last complete line. A trailing line still being written goes to `transient`,
    which is used now but never cached."""
    with open(path, "rb") as f:
        f.seek(offset)
        for line in f:
            if not line.endswith(b"\n"):
                _record_paths(line, transient)
                break
            _record_paths(line, found)
            offset += len(line)
    return offset


def _cache_path(cache_dir: str, home: str) -> str:
    # One file per Claude home, so a test's fixture home never evicts the real index.
    return os.path.join(cache_dir, slug(os.path.realpath(home)).strip("-") + ".json")


def driven_paths(transcripts: dict, cache_file: str, exclude: str = "") -> dict:
    """Map each readable transcript (a dict of path -> owning session id) to the set
    of paths its records drive.

    The cache keeps entries for these transcripts and for the excluded session's:
    wt-sweep (no exclusion) and wt-done (its caller excluded) alternate calls in one
    sweep, and dropping the caller's entry on every other call would re-read its
    transcript from the start each time."""
    cache = load(cache_file) if cache_file else None
    entries = cache.get("entries") if isinstance(cache, dict) and cache.get("version") == CACHE_VERSION else None
    if not isinstance(entries, dict):
        entries = {}
    kept, out, dirty = {}, {}, False
    if exclude:
        for t, e in entries.items():
            if t not in transcripts and isinstance(e, dict) and e.get("owner") == exclude and os.path.exists(t):
                kept[t] = e
    for t in sorted(transcripts):
        try:
            st = os.stat(t)
        except OSError:
            continue
        e = entries.get(t)
        offset, found = 0, set()
        if (isinstance(e, dict) and e.get("dev") == st.st_dev and e.get("ino") == st.st_ino
                and isinstance(e.get("offset"), int) and 0 <= e["offset"] <= st.st_size
                and isinstance(e.get("paths"), list)):
            offset, found = e["offset"], set(e["paths"])
        transient = set()
        if offset < st.st_size:
            try:
                new_offset = scan(t, offset, found, transient)
            except OSError as err:
                print(f"wt_session_hold: skipped unreadable {t}: {err}", file=sys.stderr)
                continue
            dirty = dirty or new_offset != offset or e is None
            offset = new_offset
        kept[t] = {"owner": transcripts[t], "dev": st.st_dev, "ino": st.st_ino,
                   "offset": offset, "paths": sorted(found)}
        out[t] = found | transient
    if cache_file and kept and (dirty or set(kept) != set(entries)):
        tmp = ""
        try:
            os.makedirs(os.path.dirname(cache_file), exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cache_file), prefix=".wt-hold-")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(json.dumps({"version": CACHE_VERSION, "entries": kept}, separators=(",", ":")))
            os.replace(tmp, cache_file)
        except OSError as err:
            print(f"wt_session_hold: cache not saved ({cache_file}): {err}", file=sys.stderr)
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
    return out


def _jsonl_under(top: str, owner: str, out: list) -> None:
    stack = [top]
    while stack:
        try:
            it = os.scandir(stack.pop())
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    elif e.name.endswith(".jsonl"):
                        out.append((e.path, owner, e.stat().st_mtime))
                except OSError:
                    continue


def walk_transcripts(projects: str) -> list:
    """(path, session id, mtime) for every transcript under projects/: a session's
    own `<slug>/<sid>.jsonl`, and every file under `<slug>/<sid>/subagents/` (agents
    and workflow agents, owned by that session). One walk, one stat each."""
    out = []
    try:
        slugs = list(os.scandir(projects))
    except OSError:
        return out
    for s in slugs:
        try:
            if not s.is_dir(follow_symlinks=False):
                continue
            it = os.scandir(s.path)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        _jsonl_under(os.path.join(e.path, "subagents"), e.name, out)
                    elif e.name.endswith(".jsonl"):
                        out.append((e.path, e.name[:-6], e.stat().st_mtime))
                except OSError:
                    continue
    return out


def check(wt: str, home: str, active_min: int, procfs: str, cache_dir: str = "", exclude: str = ""):
    """Return (holder or None, [resumable lines])."""
    wt = os.path.normpath(wt)
    wt_slug = slug(wt)
    resumable = []
    owners = []  # (session id, why) of every job not done and every live session

    for path in sorted(glob.glob(os.path.join(home, "jobs", "*", "state.json"))):
        d = load(path)
        if not isinstance(d, dict):
            continue
        if exclude and d.get("sessionId") == exclude:
            continue
        job = os.path.basename(os.path.dirname(path))
        label = f'job {job} "{d.get("name") or ""}"'
        state = d.get("state")
        link = d.get("linkScanPath")
        link = link if isinstance(link, str) else ""
        if state != "done":
            why = f'{label} is {state or "in an unknown state"}'
            for sid in {d.get("sessionId"), transcript_owner(link) if link else None}:
                if isinstance(sid, str) and sid and sid != exclude:
                    owners.append((sid, why))
        named = [p for p in (d.get("worktreePath"), d.get("cwd")) if isinstance(p, str) and p]
        project = os.path.basename(os.path.dirname(link)) if link else ""
        if not (any(inside(p, wt) for p in named) or project == wt_slug):
            continue
        if state == "done":
            resumable.append(f"resumable: {label} is done; resuming it would find this worktree gone")
            continue
        return f'{label} is {state or "in an unknown state"}', resumable

    for path in sorted(glob.glob(os.path.join(home, "sessions", "*.json"))):
        d = load(path)
        if not isinstance(d, dict):
            continue
        sid = d.get("sessionId")
        if exclude and sid == exclude:
            continue
        if not pid_running(d.get("pid"), d.get("procStart"), procfs):
            continue
        label = f'session pid {d.get("pid")} "{d.get("name") or ""}"'
        cwd = d.get("cwd")
        if isinstance(cwd, str) and cwd and inside(cwd, wt):
            return f"{label} has its cwd here", resumable
        if isinstance(sid, str) and sid:
            owners.append((sid, f"{label} is live"))

    now = time.time()
    project_dir = os.path.join(home, "projects", wt_slug)
    newest = 0.0
    for path in glob.glob(os.path.join(glob.escape(project_dir), "**", "*.jsonl"), recursive=True):
        rel = os.path.relpath(path, project_dir).split(os.sep)
        if exclude and (rel[0][:-6] if len(rel) == 1 else rel[0]) == exclude:
            continue
        try:
            newest = max(newest, os.stat(path).st_mtime)
        except OSError:
            continue
    if newest:
        age_min = (now - newest) / 60
        if age_min < active_min:
            return f"a transcript under {project_dir} was written {int(age_min)}m ago", resumable

    # Transcripts filed under any project: those of a job not done or a live
    # session, and any written within active_min (hov-stack#394).
    by_owner, recent = {}, []
    for path, owner, mtime in walk_transcripts(os.path.join(home, "projects")):
        if exclude and owner == exclude:
            continue
        by_owner.setdefault(owner, []).append(path)
        if (now - mtime) / 60 < active_min:
            recent.append((path, owner, int((now - mtime) / 60)))
    why = {}  # transcript -> why its session can hold a worktree
    candidates = {}  # transcript -> owning session id
    for sid, label in owners:
        for t in by_owner.get(sid, ()):
            why.setdefault(t, label)
            candidates[t] = sid
    for path, owner, age in sorted(recent):
        why.setdefault(path, f"a transcript written {age}m ago")
        candidates[path] = owner

    prefix = wt.rstrip("/") + "/"
    cache_file = _cache_path(cache_dir, home) if cache_dir else ""
    for t, found in driven_paths(candidates, cache_file, exclude).items():
        hit = sorted(p for p in found if p == wt or p.startswith(prefix))
        if hit:
            return f"{why[t]}; its transcript {t} names {hit[0]}", resumable

    return None, resumable


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--active-min", type=int, default=120, help="transcript recency window, minutes")
    ap.add_argument("--claude-home", default=os.environ.get("WT_CLAUDE_HOME") or os.path.expanduser("~/.claude"))
    ap.add_argument("--procfs", default="/proc", help="procfs root (tests)")
    ap.add_argument("--cache-dir", default=os.environ.get("WT_HOLD_CACHE_DIR") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "hov-stack-wt-session-hold"),
        help="where the per-transcript path index is kept ('' = no cache)")
    ap.add_argument("--exclude-session", default="", help="a session id that never counts as a holder")
    ap.add_argument("worktree")
    args = ap.parse_args(argv)
    holder, resumable = check(args.worktree, args.claude_home, args.active_min, args.procfs,
                              args.cache_dir, args.exclude_session)
    if holder:
        print(holder)
        return 0
    for line in resumable:
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
