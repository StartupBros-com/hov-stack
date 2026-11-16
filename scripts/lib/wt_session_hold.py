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

A worktree can be spelled more than one way. Records keep whatever path their
session saw, and a checkout reached through a link, or renamed with a compat link
left at the old name (hov-stack#661), has two spellings. Every check here matches
any of the worktree's spellings, and every slug check accepts each spelling's
slug. The spellings are the path as given, its real path, and the same real path
under each symlink that sits directly in an alias root and points at the worktree
or one of its ancestors. The alias roots are WT_ALIAS_ROOTS (colon-separated);
wt-sweep passes its repo roots (wt-roots.sh). Without it they default to ~/SITES
and ~, the same as REPO_ROOTS's default. The paths a record names are compared as
written, never resolved: a link inside a worktree may point outside it. The given
spelling is always one of them, so an extra spelling can only add a hold.

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
(keyed by device, inode and the offset of the last complete line). The cache keeps,
per transcript, each path with the newest record time naming it, and the last
recorded cwd. A transcript that is replaced or shrinks is read again from the
start. An entry is dropped once its transcript is gone, or is no longer a
candidate and was last written more than RETAIN_DAYS ago, so calls with and
without --idle-hours do not evict each other's entries. A cache that cannot be
read or written costs time, never an answer.

--exclude-session ID ignores that session's job, session record and transcripts:
wt-done passes its caller's id, since the session closing a worktree out is the
one whose transcript names it. wt-sweep passes none, so a sweep never removes the
worktree its own caller is driving.

--idle-hours H (0, the default, turns it off) lets the transcript hold lapse. A
job that failed or was blocked stays "not done" for good, so its transcript held
every worktree it ever named for good too: 41 GiB of merged worktrees on the
author's host on 2026-11-14 (hov-stack#644). With H set, a worktree held only by
a transcript is reported idle (exit 3) when no record naming a path under it is
newer than H hours, in the candidates or in any transcript written within H
hours, and no candidate session's own transcript last recorded its cwd there (a
resume would carry on in it). A record's time is its `timestamp`; a record
without a readable one counts as written at its file's mtime, which is never
earlier. The job, live-session and project-directory holds never lapse.

Exit 0: held; one line on stdout names the holder.
Exit 1: not held; stdout may carry `resumable:` lines naming finished jobs whose
        transcripts live under this worktree (a resume would find it gone).
Exit 2: bad arguments.
Exit 3: idle (only with --idle-hours); one line on stdout, `idle: <holder>; last
        named <N>h ago`.
Exit 4: the check failed; stderr says why. Callers treat any exit other than 1
        as held (wt-preserve.sh reads 3 as idle only when asked to).

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
from datetime import datetime

# v2 maps each path to the newest record time naming it (v1 kept a bare list). The
# file name carries the version, so an installed v1 helper and this one never
# throw each other's index away.
CACHE_VERSION = 2
RETAIN_DAYS = 3
_CWD = re.compile(rb'"cwd":"((?:[^"\\]|\\.)*)"')
_TS = b'"timestamp":"'
# An absolute (or ~/) path token in a shell command, after a separator a shell or
# an option would put before it (`git -C /x`, `--cd=/x`, `cd "/x"`, `(cd /x`).
_TOKEN = re.compile(r"""(?:^|(?<=[\s'"=:(]))(~?/[^\s'"`;|&<>(){}$\\,]+)""")
_PATH_FIELDS = ("file_path", "path", "notebook_path")


def slug(path: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def inside(child: str, root: str) -> bool:
    child, root = os.path.normpath(child), os.path.normpath(root)
    return child == root or child.startswith(root.rstrip("/") + "/")


def _alias_roots() -> list:
    raw = os.environ.get("WT_ALIAS_ROOTS")
    if raw is None:
        home = os.path.expanduser("~")
        return [os.path.join(home, "SITES"), home]
    return [r for r in raw.split(":") if r]


def spellings(wt: str) -> list:
    """The worktree as given, then its real path, then that real path under each
    symlink directly in an alias root that points at it or an ancestor of it."""
    given = os.path.normpath(wt)
    out = [given]
    real = os.path.realpath(given)
    if real not in out:
        out.append(real)
    for root in _alias_roots():
        try:
            it = os.scandir(root)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if not e.is_symlink():
                        continue
                    target = os.path.realpath(e.path)
                except OSError:
                    continue
                if target == "/" or not (real == target or real.startswith(target + "/")):
                    continue
                s = os.path.normpath(e.path + real[len(target):])
                if s not in out:
                    out.append(s)
    return out


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


def _when(line: bytes, d, fallback: float) -> float:
    """The record's own time, or `fallback` (its file's mtime, never earlier) when it
    has none that parses. The byte grab is used only when the key occurs once: on
    2026-11-15 it matched the parsed top-level value on all 1,319,139 such records
    in 200 transcripts; a line with nested timestamps is parsed instead."""
    ts = None
    if d is None and line.count(_TS) == 1:
        i = line.index(_TS) + len(_TS)
        ts = line[i:line.find(b'"', i)].decode("ascii", "replace")
    else:
        if d is None:
            try:
                d = json.loads(line)
            except ValueError:
                d = None
        ts = d.get("timestamp") if isinstance(d, dict) else None
    if isinstance(ts, str):
        try:
            t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            return fallback
        if t.tzinfo is not None:
            return t.timestamp()
    return fallback


def _record_paths(line: bytes, found: dict, fallback: float):
    """Note in `found` each path `line` drives, with the newest record time naming
    it, and return the record's cwd (None if it has none)."""
    paths, cwd = [], None
    m = _CWD.search(line)
    if m:
        try:
            v = json.loads(b'"' + m.group(1) + b'"')
        except ValueError:
            v = None
        if isinstance(v, str) and v.startswith("/"):
            cwd = _norm(v)
            paths.append(cwd)
    d = None
    if b'"tool_use"' in line:
        try:
            d = json.loads(line)
        except ValueError:
            d = None
        msg = d.get("message") if isinstance(d, dict) else None
        content = msg.get("content") if isinstance(msg, dict) else None
        for c in content if isinstance(content, list) else ():
            if not (isinstance(c, dict) and c.get("type") == "tool_use"):
                continue
            inp = c.get("input")
            if not isinstance(inp, dict):
                continue
            for k in _PATH_FIELDS:
                v = inp.get(k)
                if isinstance(v, str) and v.startswith(("/", "~/")):
                    paths.append(_norm(v))
            cmd = inp.get("command")
            if isinstance(cmd, str):
                paths.extend(_norm(t) for t in _TOKEN.findall(cmd))
    if paths:
        when = _when(line, d, fallback)
        for p in paths:
            if when > found.get(p, float("-inf")):
                found[p] = when
    return cwd


def scan(path: str, offset: int, found: dict, transient: dict, fallback: float):
    """Add the driven paths in `path` from `offset` on; return the offset after the
    last complete line and the last cwd recorded there (None if none). A trailing
    line still being written goes to `transient`, which is used now but never
    cached."""
    last = None
    with open(path, "rb") as f:
        f.seek(offset)
        for line in f:
            if not line.endswith(b"\n"):
                _record_paths(line, transient, fallback)
                break
            last = _record_paths(line, found, fallback) or last
            offset += len(line)
    return offset, last


def _cache_path(cache_dir: str, home: str) -> str:
    # One file per Claude home, so a test's fixture home never evicts the real index.
    return os.path.join(cache_dir, slug(os.path.realpath(home)).strip("-") + f".v{CACHE_VERSION}.json")


def _entry_ok(e, st) -> bool:
    if not (isinstance(e, dict) and e.get("dev") == st.st_dev and e.get("ino") == st.st_ino
            and isinstance(e.get("offset"), int) and 0 <= e["offset"] <= st.st_size
            and isinstance(e.get("paths"), dict) and (e.get("cwd") is None or isinstance(e["cwd"], str))):
        return False
    return all(isinstance(w, (int, float)) and not isinstance(w, bool) for w in e["paths"].values())


def driven_paths(transcripts: dict, cache_file: str) -> dict:
    """Map each readable transcript (a dict of path -> owning session id) to
    (paths, last cwd): each path its records drive with the newest record time
    naming it, and the last cwd it recorded.

    The cache also keeps entries for transcripts that are not asked about now but
    were written within RETAIN_DAYS: wt-sweep (no exclusion, an idle window) and
    wt-done (its caller excluded, no window) alternate calls in one sweep, and
    dropping each other's entries would re-read those transcripts from the start
    every time. The excluded session's own transcript is being written by the
    caller, so retention keeps it too."""
    cache = load(cache_file) if cache_file else None
    entries = cache.get("entries") if isinstance(cache, dict) and cache.get("version") == CACHE_VERSION else None
    if not isinstance(entries, dict):
        entries = {}
    kept, out, dirty = {}, {}, False
    horizon = time.time() - RETAIN_DAYS * 86400
    for t, e in entries.items():
        if t in transcripts or not isinstance(e, dict):
            continue
        try:
            if os.stat(t).st_mtime >= horizon:
                kept[t] = e
        except OSError:
            continue
    for t in sorted(transcripts):
        try:
            st = os.stat(t)
        except OSError:
            continue
        e = entries.get(t)
        offset, found, cwd = 0, {}, None
        if _entry_ok(e, st):
            offset, found, cwd = e["offset"], dict(e["paths"]), e.get("cwd")
        transient = {}
        if offset < st.st_size:
            try:
                new_offset, last = scan(t, offset, found, transient, st.st_mtime)
            except OSError as err:
                print(f"wt_session_hold: skipped unreadable {t}: {err}", file=sys.stderr)
                continue
            dirty = dirty or new_offset != offset or e is None
            offset, cwd = new_offset, last or cwd
        kept[t] = {"owner": transcripts[t], "dev": st.st_dev, "ino": st.st_ino,
                   "offset": offset, "paths": found, "cwd": cwd}
        merged = dict(found)
        for p, w in transient.items():
            merged[p] = max(w, merged.get(p, w))
        out[t] = (merged, cwd)
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


def check(wt: str, home: str, active_min: int, procfs: str, cache_dir: str = "", exclude: str = "",
          idle_hours: float = 0.0):
    """Return (holder or None, [resumable lines], idle). `idle` is True only when
    idle_hours is set and the one hold left is a transcript hold that lapsed."""
    names = spellings(wt)
    wt = names[0]
    slugs = list(dict.fromkeys(slug(s) for s in names))

    def within(p: str) -> bool:
        return any(inside(p, s) for s in names)

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
        if not (any(within(p) for p in named) or project in slugs):
            continue
        if state == "done":
            resumable.append(f"resumable: {label} is done; resuming it would find this worktree gone")
            continue
        return f'{label} is {state or "in an unknown state"}', resumable, False

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
        if isinstance(cwd, str) and cwd and within(cwd):
            return f"{label} has its cwd here", resumable, False
        if isinstance(sid, str) and sid:
            owners.append((sid, f"{label} is live"))

    now = time.time()
    newest, newest_dir = 0.0, ""
    for wt_slug in slugs:
        project_dir = os.path.join(home, "projects", wt_slug)
        for path in glob.glob(os.path.join(glob.escape(project_dir), "**", "*.jsonl"), recursive=True):
            rel = os.path.relpath(path, project_dir).split(os.sep)
            if exclude and (rel[0][:-6] if len(rel) == 1 else rel[0]) == exclude:
                continue
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            if mtime > newest:
                newest, newest_dir = mtime, project_dir
    if newest:
        age_min = (now - newest) / 60
        if age_min < active_min:
            return f"a transcript under {newest_dir} was written {int(age_min)}m ago", resumable, False

    # Transcripts filed under any project: those of a job not done or a live
    # session, and any written within active_min (hov-stack#394). With an idle
    # window, also every transcript written within it: a session that named the
    # worktree there keeps it in use even if it is neither. The window is never
    # shorter than active_min.
    window = max(idle_hours * 3600, active_min * 60) if idle_hours > 0 else 0
    by_owner, recent, fresh = {}, [], {}
    for path, owner, mtime in walk_transcripts(os.path.join(home, "projects")):
        if exclude and owner == exclude:
            continue
        by_owner.setdefault(owner, []).append(path)
        if (now - mtime) / 60 < active_min:
            recent.append((path, owner, int((now - mtime) / 60)))
        if window and now - mtime < window:
            fresh[path] = owner
    why = {}  # transcript -> why its session can hold a worktree
    candidates = {}  # transcript -> owning session id
    for sid, label in owners:
        for t in by_owner.get(sid, ()):
            why.setdefault(t, label)
            candidates[t] = sid
    for path, owner, age in sorted(recent):
        why.setdefault(path, f"a transcript written {age}m ago")
        candidates[path] = owner

    prefixes = tuple(s.rstrip("/") + "/" for s in names)

    def here(p: str) -> bool:
        return p in names or p.startswith(prefixes)

    cache_file = _cache_path(cache_dir, home) if cache_dir else ""
    driven = driven_paths({**fresh, **candidates}, cache_file)
    holder = None
    for t in sorted(candidates):
        hit = sorted(p for p in driven.get(t, ({}, None))[0] if here(p))
        if hit:
            holder = f"{why[t]}; its transcript {t} names {hit[0]}"
            break
    if holder is None:
        return None, resumable, False
    if not window:
        return holder, resumable, False
    last = max((w for found, _ in driven.values() for p, w in found.items() if here(p)), default=now)
    if now - last < window:
        return holder, resumable, False
    for t, sid in sorted(candidates.items()):
        cwd = driven.get(t, ({}, None))[1]
        if cwd and within(cwd) and transcript_owner(t) == sid:
            return f"{holder}; its session last recorded its cwd at {cwd}", resumable, False
    return f"idle: {holder}; last named {int((now - last) // 3600)}h ago", resumable, True


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--active-min", type=int, default=120, help="transcript recency window, minutes")
    ap.add_argument("--claude-home", default=os.environ.get("WT_CLAUDE_HOME") or os.path.expanduser("~/.claude"))
    ap.add_argument("--procfs", default="/proc", help="procfs root (tests)")
    ap.add_argument("--cache-dir", default=os.environ.get("WT_HOLD_CACHE_DIR") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "hov-stack-wt-session-hold"),
        help="where the per-transcript path index is kept ('' = no cache)")
    ap.add_argument("--exclude-session", default="", help="a session id that never counts as a holder")
    ap.add_argument("--idle-hours", type=float, default=0.0,
                    help="report a transcript-only hold idle after this many hours unnamed (0 = never)")
    ap.add_argument("worktree")
    args = ap.parse_args(argv)
    if not args.idle_hours >= 0:
        ap.error("--idle-hours must be 0 or more")
    try:
        holder, resumable, idle = check(args.worktree, args.claude_home, args.active_min, args.procfs,
                                        args.cache_dir, args.exclude_session, args.idle_hours)
    except Exception as err:  # any failure reads as held: exit 1 would let a sweep remove it
        print(f"wt_session_hold: check failed, treat as held: {err!r}", file=sys.stderr)
        return 4
    if holder:
        print(holder)
        return 3 if idle else 0
    for line in resumable:
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
