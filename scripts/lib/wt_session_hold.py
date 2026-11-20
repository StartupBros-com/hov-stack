#!/usr/bin/env python3
"""Report whether a Claude Code session is holding a git worktree.

A session that entered a worktree and then sat idle holds it without any process
showing it: a background job records its launch checkout as `cwd`, and edits deep
in the tree leave the worktree's top-directory mtime alone. On 2026-11-03 wt-sweep
removed such a worktree from under a working job (hov-stack#384). This reads what
Claude Code itself records, under the Claude home directory:

  jobs/<id>/state.json    a job that is not `done` holds the worktree it names in
                          `worktreePath` or `cwd`, or whose transcript project
                          directory (`linkScanPath`) is the worktree's slug; a
                          `done` job holds it too while it can be resumed (below);
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
per transcript, each path with the newest record time naming it, the last
recorded cwd, and the time of the last dated record read (`ts`, which dates an
undated record after the offset). A transcript that is replaced or shrinks is read again from the
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
resume would carry on in it). A record's time is its `timestamp`; one whose
timestamp does not parse counts as written at its file's mtime, which is never
earlier. One with no timestamp at all, Claude Code's copy of an earlier message as
it sends it again (`api-request-blob`), takes the time of the last dated record
before it in the same transcript, so a rebuilt index dates it as the incremental
one does (hov-stack#795: the scan-time mtime made every worktree such a copy ever
named look freshly named after a rebuild). With no dated record before it, it names
its paths but never makes them recent. The live-session and project-directory holds
never lapse.

With H set, a job that is not done lapses too once it is dead and stale
(hov-stack#403): no running session record carries its `sessionId`,
`resumeSessionId` or transcript id, and its state.json was last written more than
H hours ago. On 2026-11-16 every `working` job on the author's host had such a
record, and five `blocked` jobs had none and held their own merged worktrees for
up to 21 days. A lapsed job no longer holds the worktree it names; its state.json
counts as a record naming that worktree at the file's mtime; and its own
transcript's last cwd no longer holds either (a resume of it would find the
worktree gone, as a done job's would). Such a worktree is reported idle, never
unheld, so a sweep releases it only if it is clean, cache-only and shipped.

A `done` job is one whose last turn has ended: the state of every background job
left waiting for its user, overnight for instance. Its process is gone by then and
so, by the time a sweep runs, is the worktree's `git worktree lock`, but resuming
the job re-enters the worktree it is bound to, and finding it gone the session
carries on in the launch checkout (hov-stack#793: 27 such removals on the author's
host in three days, every job resumed within 24 hours of its last turn). So a done
job holds the worktree it is bound to while its last turn ended less than
--resumable-hours ago (default 24, or WT_RESUMABLE_HOURS; 0 turns it off). Bound
means `worktreePath` or `cwd` in its state.json is inside the worktree, its
transcript project directory is the worktree's slug, or the last `worktree-state`
record of its own transcript (`linkScanPath`, or `<sessionId>.jsonl`) names it; an
earlier record that a later one replaced or cleared binds nothing. The clock is
`lastTerminalAt`, not the file's mtime, which Claude Code rewrites without the job
doing anything; only a job without a readable `lastTerminalAt` falls back to the
mtime, which errs toward holding. Inside the window a done job whose own transcript could not be read holds
every worktree under its `cwd` or `originCwd`, since its binding is unknown. The
hold never lapses into `idle:`; once the window has passed the job only warns again
and the worktree takes the caller's normal path. The default lives here, so wt-sweep
and wt-done, which both call through lib/wt-preserve.sh, always agree on it.

Nothing is reported idle when a job or session record, or a candidate transcript,
could not be read (hov-stack#660), or when the sessions, jobs or projects
directory, or one under it, exists but could not be listed: unread bytes may name
the worktree inside the window, and a failed listing is not an empty one. No job
lapses unless every session record was read, since its running session may be
among the unread, and a session whose process status cannot be read counts as
live (hov-stack#695). Each such path is reported on stderr and the hold stays. It never
makes a hold where none exists: a worktree nothing readable names stays unheld,
as before, and takes the sweep's normal path, which commits, bundles or pushes
its work before any removal; holding every worktree on one bad file would stop
the sweep for as long as the file stays bad. A transcript
whose new bytes cannot be read still holds through what its cache entry had
recorded. Without --idle-hours the skip described below stands. A session record
that cannot be read, from a pid (its file name) that is not running, holds nothing
either way, so it is skipped without a note and without this effect.

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
import json
import math
import os
import re
import sys
import tempfile
import time
from datetime import datetime

# v2 maps each path to the newest record time naming it (v1 kept a bare list). The
# file name carries the version, so an installed older helper and this one never
# throw each other's index away. Since hov-stack#793 an entry also carries `bind`,
# its transcript's last `worktree-state` binding. An entry without one, written by
# an older helper, is read once more for bindings alone when a done job needs it,
# keeping every path's recorded time. Since hov-stack#795 an entry also carries
# `ts`, the time of the last dated record before its offset; an entry without one
# finds it in its own bytes the first time an undated record after the offset needs
# it. Neither is a version bump. Until #795 a full re-read dated each record without
# a timestamp by the transcript's current mtime, and on 2026-11-19 a rebuilt index
# called 44 idle worktrees live again; that is fixed, but a bump still re-reads
# every transcript once (about 40 s on the author's host). Paths indexed before
# #806 lost a trailing `.`, so such an entry still cannot hold a worktree whose
# name ends in one, as it could not before; none on that host did.
CACHE_VERSION = 2
DEFAULT_RESUMABLE_HOURS = 24.0
FUTURE_SKEW = 3600.0  # seconds a done job's last-turn time may run ahead of now
RETAIN_DAYS = 3
_CWD = re.compile(rb'"cwd":"((?:[^"\\]|\\.)*)"')
_TS = b'"timestamp":"'
_TS_KEY = b'"timestamp"'
_TOOL_USE = b'"tool_use"'
_NOT_PARSED = object()  # a line no caller has parsed yet
_WS = b'"worktree-state"'
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


_BAD = object()  # load()'s answer for a file that exists but cannot be read or parsed


def load(path: str, quiet: bool = False):
    """The JSON in `path`; None if there is no such file; _BAD, after a note on
    stderr unless `quiet`, if it exists but cannot be read or parsed."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        if not quiet:
            print(f"wt_session_hold: skipped unreadable {path}: {e}", file=sys.stderr)
        return _BAD


def _record(path: str, quiet: bool, bad: list):
    """A job or session record as a dict, or None. One that exists but is not a
    readable JSON object is skipped, and unless `quiet` it is noted on stderr and
    appended to `bad`."""
    d = load(path, quiet)
    if d is None or isinstance(d, dict):
        return d
    if not quiet:
        if d is not _BAD:
            print(f"wt_session_hold: skipped unreadable {path}: not a JSON object", file=sys.stderr)
        bad.append(path)
    return None


def _unlisted(path: str, err: OSError, bad: list) -> None:
    print(f"wt_session_hold: could not list {path}: {err}", file=sys.stderr)
    bad.append(path)


def _entries(path: str, bad: list) -> list:
    """The entries of directory `path`, sorted by name: none if it is missing or
    not a directory. One that exists but cannot be listed is not an empty one
    (hov-stack#695): it is noted on stderr, appended to `bad`, and yields none."""
    try:
        with os.scandir(path) as it:
            return sorted(it, key=lambda e: e.name)
    except (FileNotFoundError, NotADirectoryError):
        return []
    except OSError as err:
        _unlisted(path, err, bad)
        return []


def _is_dir(e, bad: list, follow: bool = True) -> bool:
    try:
        return e.is_dir(follow_symlinks=follow)
    except FileNotFoundError:
        return False
    except OSError as err:
        _unlisted(e.path, err, bad)
        return False


def pid_running(pid, proc_start, procfs: str):
    """True if process `pid` runs (and, given `proc_start`, is the one started then);
    False if it does not; None if its status could not be read. A process whose
    status is unknown is not called stopped (hov-stack#695)."""
    try:
        path = os.path.join(procfs, str(int(pid)), "stat")
    except (ValueError, TypeError):
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            stat = f.read()
    except (FileNotFoundError, ProcessLookupError):
        return False
    except OSError:
        return None
    if proc_start in (None, ""):
        return True
    # Field 22 (starttime). comm may contain spaces, so split after its ')'.
    fields = stat.rsplit(")", 1)[-1].split()
    return len(fields) > 19 and fields[19] == str(proc_start)


def transcript_owner(path: str) -> str:
    """Session id of a session transcript, `projects/<slug>/<sid>.jsonl`."""
    return os.path.splitext(os.path.basename(path))[0]


def _norm(p: str) -> str:
    """`p` as a path, `~/` expanded. A trailing `.` is kept: `x.` and `x` are two
    directories (hov-stack#806)."""
    if p.startswith("~/"):
        p = os.path.expanduser(p)
    return os.path.normpath(p)


def _parse(line: bytes):
    """`line` as JSON, or None when it is not (one still being written)."""
    try:
        return json.loads(line)
    except ValueError:
        return None


def _stamp(line: bytes, d=_NOT_PARSED):
    """(whether the record carries a top-level `timestamp`, its time or None when
    that does not parse). `d` is the record when the caller has parsed it already.
    A tool use is always parsed, so a timestamp in a tool's input is never taken for
    the record's. Otherwise the byte grab is used when the key occurs once, written
    as Claude Code writes it (`"timestamp":"`): on 2026-11-15 it matched the parsed
    top-level value on all 1,319,139 such records in 200 transcripts. Any other line
    naming the key is parsed, so a timestamp that is null, a number or spaced
    otherwise is still present and never taken for a missing one. A line that is
    not JSON (torn, or still being written) gets the byte grab too when the key
    occurs once that way, and otherwise counts as one that does not parse."""
    if _TS_KEY not in line:
        return False, None
    once = line.count(_TS_KEY) == 1 and line.count(_TS) == 1
    if d is _NOT_PARSED:
        d = _parse(line) if _TOOL_USE in line or not once else None
    if d is None:
        if not once:
            return True, None
        i = line.index(_TS) + len(_TS)
        d = {"timestamp": line[i:line.find(b'"', i)].decode("ascii", "replace")}
    if not (isinstance(d, dict) and "timestamp" in d):
        return False, None
    ts = d["timestamp"]
    if isinstance(ts, str):
        try:
            t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            return True, None
        if t.tzinfo is not None:
            return True, t.timestamp()
    return True, None


def _instant(v):
    """A job record's time as epoch seconds: an ISO 8601 string with a zone, or a
    number of milliseconds (of seconds when too small to be milliseconds). None when
    it is neither, or not finite."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        try:
            t = v / 1000.0 if v > 1e11 else float(v)
        except OverflowError:  # an int too large for a float: one bad file must not fail every check
            return None
    elif isinstance(v, str):
        try:
            d = datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError:
            return None
        if d.tzinfo is None:
            return None
        t = d.timestamp()
    else:
        return None
    return t if math.isfinite(t) else None


def last_turn_age(d: dict, state_path: str, now: float) -> float:
    """Seconds since a done job's last turn ended: from `lastTerminalAt`, else from
    its state.json mtime. The mtime is rewritten without the job doing anything, so
    it can only make the job look more recent than it is: a fallback that errs
    toward holding. A time more than FUTURE_SKEW ahead of now is not believed (a
    bad clock or a wrong unit would otherwise hold until that time), so the mtime
    is tried instead; with no believable time the job holds nothing (math.inf)."""
    for t in (_instant(d.get("lastTerminalAt")), None):
        if t is None:
            try:
                t = os.stat(state_path).st_mtime
            except OSError:
                return math.inf
        if t <= now + FUTURE_SKEW:
            return max(0.0, now - t)
    return math.inf


def _record_paths(line: bytes, found: dict, when, d=_NOT_PARSED):
    """Note in `found` each path `line` drives, with the newest record time naming
    it (`when()`, asked only if it names one), and return the record's cwd (None if
    it has none). `d` is the record when the caller has parsed it already."""
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
    if _TOOL_USE in line:
        if d is _NOT_PARSED:
            d = _parse(line)
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
                for t in _TOKEN.findall(cmd):
                    p = _norm(t)
                    paths.append(p)
                    # A command's text cannot tell a name ending in `.` from a
                    # sentence's full stop: such a token names both.
                    if p.endswith("."):
                        paths.append(p.rstrip(".") or "/")
    if paths:
        w = when()
        for p in paths:
            if w > found.get(p, float("-inf")):
                found[p] = w
    return cwd


def _binding(line: bytes):
    """The worktree a `worktree-state` record binds its session to: the path, or ""
    when the record clears the binding. None when `line` is no such record."""
    if _WS not in line:
        return None
    try:
        d = json.loads(line)
    except ValueError:
        return None
    if not (isinstance(d, dict) and d.get("type") == "worktree-state"):
        return None
    ws = d.get("worktreeSession")
    p = ws.get("worktreePath") if isinstance(ws, dict) else None
    return _norm(p) if isinstance(p, str) and p.startswith("/") else ""


_UNKNOWN = object()  # an entry an older helper wrote: the time before its offset was not kept


def scan(path: str, offset: int, found: dict, transient: dict, mtime: float, prior=None, recover=None):
    """Add the driven paths in `path` from `offset` on. A record's time is its
    `timestamp`; one whose timestamp does not parse counts as written at `mtime`,
    the file's, never earlier. One with no timestamp at all, Claude Code's copy of an
    earlier message as it sends it again (`api-request-blob`), takes the time of the
    last dated record before it (hov-stack#795): `prior` at `offset` (None if there is
    none; _UNKNOWN for an entry an older helper wrote, and then `recover()` works it
    out the first time it is needed), then each one read. With none before it, it
    gets 0: it names its paths but never makes them recent. Return the offset after
    the last complete line, the last cwd and the last `worktree-state` binding
    recorded there (each None if none), and `prior` at that offset. A trailing line
    still being written goes to `transient`, which is used now but never cached; it
    counts as written at `mtime` unless its own timestamp is already there and parses."""
    last = bind = None

    def before() -> float:
        nonlocal prior
        if prior is _UNKNOWN:
            prior = recover() if recover else None
        return 0.0 if prior is None else prior

    with open(path, "rb") as f:
        f.seek(offset)
        for line in f:
            d = _parse(line) if _TOOL_USE in line else _NOT_PARSED
            present, t = _stamp(line, d)
            when = before if not present else (lambda: mtime) if t is None else (lambda t=t: t)
            if not line.endswith(b"\n"):
                _record_paths(line, transient, (lambda: mtime) if t is None else when, d)
                break
            last = _record_paths(line, found, when, d) or last
            if t is not None:
                prior = t
            b = _binding(line)
            if b is not None:
                bind = b
            offset += len(line)
    return offset, last, bind, prior


def _cache_path(cache_dir: str, home: str) -> str:
    # One file per Claude home, so a test's fixture home never evicts the real index.
    return os.path.join(cache_dir, slug(os.path.realpath(home)).strip("-") + f".v{CACHE_VERSION}.json")


def _time_ok(w) -> bool:
    return isinstance(w, (int, float)) and not isinstance(w, bool) and math.isfinite(w)


def _entry_ok(e, st) -> bool:
    if not (isinstance(e, dict) and e.get("dev") == st.st_dev and e.get("ino") == st.st_ino
            and isinstance(e.get("offset"), int) and 0 <= e["offset"] <= st.st_size
            and isinstance(e.get("paths"), dict) and (e.get("cwd") is None or isinstance(e["cwd"], str))
            and (e.get("bind") is None or isinstance(e["bind"], str))
            and (e.get("ts") is None or _time_ok(e["ts"]))):
        return False
    return all(_time_ok(w) for w in e["paths"].values())


def last_stamp(path: str, end: int):
    """The time of the last dated record in the first `end` bytes of `path` (a line
    boundary), or None if there is none: what an entry an older helper wrote did
    not keep."""
    t, n = None, 0
    with open(path, "rb") as f:
        for line in f:
            n += len(line)
            if n > end:
                break
            s = _stamp(line)[1]
            if s is not None:
                t = s
    return t


def last_binding(path: str, end: int):
    """The last `worktree-state` binding in the first `end` bytes of `path` (a line
    boundary), as _binding() spells it, or None if there is none."""
    bind, n = None, 0
    with open(path, "rb") as f:
        for line in f:
            n += len(line)
            if n > end:
                break
            b = _binding(line)
            if b is not None:
                bind = b
    return bind


def driven_paths(transcripts: dict, cache_file: str, need_bind=()):
    """Map each readable transcript (a dict of path -> owning session id) to
    (paths, last cwd, binding): each path its records drive with the newest record
    time naming it, the last cwd it recorded, and the worktree its last
    `worktree-state` record binds it to ("" if that record cleared the binding,
    None if it has none, or if it is unknown and the transcript is not in
    `need_bind`). Return that map and the list of
    transcripts that could not be read. One whose new bytes cannot be read keeps
    what its cache entry, and any lines read before the error, recorded; the rest
    of it is unknown, so the caller must not call a worktree idle on it.

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
    kept, out, skipped, dirty = {}, {}, [], False
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
        except FileNotFoundError:
            continue
        except OSError as err:
            print(f"wt_session_hold: skipped unreadable {t}: {err}", file=sys.stderr)
            skipped.append(t)
            continue
        e = entries.get(t)
        offset, found, cwd, bind, known, prior = 0, {}, None, None, True, None
        cached = _entry_ok(e, st)
        if cached:
            offset, found, cwd = e["offset"], dict(e["paths"]), e.get("cwd")
            bind, known = e.get("bind"), "bind" in e  # an older helper's entry has no binding
            prior = e.get("ts", _UNKNOWN)  # nor the time of its last dated record
        transient = {}
        try:
            if not known and t in need_bind:
                bind, known, dirty = last_binding(t, offset), True, True
            if offset < st.st_size:
                new_offset, last, new_bind, prior = scan(t, offset, found, transient, st.st_mtime, prior,
                                                         lambda t=t, end=offset: last_stamp(t, end))
                dirty = dirty or new_offset != offset or e is None
                offset, cwd = new_offset, last or cwd
                bind = bind if new_bind is None else new_bind
        except OSError as err:
            print(f"wt_session_hold: skipped unreadable {t}: {err}", file=sys.stderr)
            skipped.append(t)
            if cached:
                kept[t] = e
            for p, w in transient.items():
                found[p] = max(w, found.get(p, w))
            if found or bind is not None:
                out[t] = (found, cwd, bind if known else None)
            continue
        kept[t] = {"owner": transcripts[t], "dev": st.st_dev, "ino": st.st_ino,
                   "offset": offset, "paths": found, "cwd": cwd}
        if known:
            kept[t]["bind"] = bind
        if prior is not _UNKNOWN:
            kept[t]["ts"] = prior
        merged = dict(found)
        for p, w in transient.items():
            merged[p] = max(w, merged.get(p, w))
        out[t] = (merged, cwd, bind)
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
    return out, skipped


def _jsonl(e, owner: str, out: list, bad: list) -> None:
    try:
        out.append((e.path, owner, e.stat().st_mtime))
    except FileNotFoundError:
        pass
    except OSError as err:
        _unlisted(e.path, err, bad)


def _jsonl_under(top: str, owner: str, out: list, bad: list, follow: bool = False) -> None:
    """Every `.jsonl` under `top` as (path, owner, mtime). Directory symlinks are
    followed only with `follow`, and then each directory is walked once."""
    stack, seen = [top], set()
    while stack:
        d = stack.pop()
        if follow:
            try:
                st = os.stat(d)
            except OSError:
                pass  # _entries notes it if it exists and cannot be listed
            else:
                if (st.st_dev, st.st_ino) in seen:
                    continue
                seen.add((st.st_dev, st.st_ino))
        for e in _entries(d, bad):
            if _is_dir(e, bad, follow=follow):
                stack.append(e.path)
            elif e.name.endswith(".jsonl"):
                _jsonl(e, owner, out, bad)


def walk_transcripts(projects: str, bad: list) -> list:
    """(path, session id, mtime) for every transcript under projects/: a session's
    own `<slug>/<sid>.jsonl`, and every file under `<slug>/<sid>/subagents/` (agents
    and workflow agents, owned by that session). One walk, one stat each. A
    directory on the way that cannot be listed is appended to `bad`."""
    out = []
    for s in _entries(projects, bad):
        if not _is_dir(s, bad, follow=False):
            continue
        for e in _entries(s.path, bad):
            if _is_dir(e, bad, follow=False):
                _jsonl_under(os.path.join(e.path, "subagents"), e.name, out, bad)
            elif e.name.endswith(".jsonl"):
                _jsonl(e, e.name[:-6], out, bad)
    return out


def check(wt: str, home: str, active_min: int, procfs: str, cache_dir: str = "", exclude: str = "",
          idle_hours: float = 0.0, resumable_hours: float = DEFAULT_RESUMABLE_HOURS):
    """Return (holder or None, [resumable lines], idle). `idle` is True only when
    idle_hours is set and the holds left are transcript holds, or dead and stale
    jobs (hov-stack#403), that lapsed. A done job inside resumable_hours holds
    and is never idle (hov-stack#793)."""
    names = spellings(wt)
    wt = names[0]
    slugs = list(dict.fromkeys(slug(s) for s in names))

    def within(p: str) -> bool:
        return any(inside(p, s) for s in names)

    resumable = []
    owners = []  # (session id, why) of every job not done and every live session
    unreadable = []  # records and transcripts that could not be read: nothing is idle
    now = time.time()
    window = max(idle_hours * 3600, active_min * 60) if idle_hours > 0 else 0
    resume_window = resumable_hours * 3600 if resumable_hours > 0 else 0

    # Session records first: a job's liveness is read from them (hov-stack#403).
    live, live_ids = [], set()
    for e in _entries(os.path.join(home, "sessions"), unreadable):
        if e.name.startswith(".") or not e.name.endswith(".json"):
            continue
        path, stem = e.path, e.name[:-5]
        gone = stem.isdigit() and pid_running(stem, None, procfs) is False
        d = _record(path, gone, unreadable)
        if d is None:
            continue
        running = pid_running(d.get("pid"), d.get("procStart"), procfs)
        if running is None:
            print(f"wt_session_hold: could not read the status of pid {d.get('pid')} ({path}); counted as live",
                  file=sys.stderr)
        elif not running:
            continue
        live.append(d)
        sid = d.get("sessionId")
        if isinstance(sid, str) and sid:
            live_ids.add(sid)
    # A job's session is called stopped only when every session record was read.
    sessions_read = not unreadable

    lapsed_here = []  # (why, state.json mtime) of each lapsed job naming this worktree
    lapsed_ids, held_ids = set(), set()
    bound = []  # (why, session ids, transcript, launch dirs) of each resumable done job not matched by name
    for e in _entries(os.path.join(home, "jobs"), unreadable):
        if e.name.startswith(".") or not _is_dir(e, unreadable):
            continue
        path = os.path.join(e.path, "state.json")
        d = _record(path, False, unreadable)
        if d is None:
            continue
        if exclude and d.get("sessionId") == exclude:
            continue
        job = os.path.basename(os.path.dirname(path))
        label = f'job {job} "{d.get("name") or ""}"'
        state = d.get("state")
        link = d.get("linkScanPath")
        link = link if isinstance(link, str) else ""
        lapsed, mtime = False, 0.0
        if state != "done":
            why = f'{label} is {state or "in an unknown state"}'
            ids = {v for v in (d.get("sessionId"), d.get("resumeSessionId"), transcript_owner(link) if link else None)
                   if isinstance(v, str) and v}
            if window and sessions_read and not ids & live_ids:
                try:
                    mtime = os.stat(path).st_mtime
                except OSError:
                    mtime = now
                lapsed = now - mtime >= window
            if lapsed:
                why += " and its session is not running"
                lapsed_ids |= ids
            else:
                held_ids |= ids
            for sid in {d.get("sessionId"), transcript_owner(link) if link else None}:
                if isinstance(sid, str) and sid and sid != exclude:
                    owners.append((sid, why))
        named = [p for p in (d.get("worktreePath"), d.get("cwd")) if isinstance(p, str) and p]
        project = os.path.basename(os.path.dirname(link)) if link else ""
        matched = any(within(p) for p in named) or project in slugs
        if state == "done":
            # Resuming a done job re-enters the worktree it is bound to (hov-stack#793).
            # The caller may carry any of its ids (its transcript's name can differ
            # from its sessionId), so any one excludes it.
            if exclude and exclude in (d.get("resumeSessionId"), transcript_owner(link) if link else None):
                continue
            age = last_turn_age(d, path, now)
            if resume_window and age < resume_window:
                why = f"{label} is done and can be resumed: its last turn ended {age / 3600:.1f}h ago"
                if matched:
                    return why, resumable, False
                ids = {v for v in (d.get("sessionId"), d.get("resumeSessionId")) if isinstance(v, str) and v}
                dirs = [p for p in (d.get("cwd"), d.get("originCwd")) if isinstance(p, str) and p.startswith("/")]
                bound.append((why, ids, link if link.endswith(".jsonl") else "", dirs))
            elif matched:
                resumable.append(f"resumable: {label} is done; resuming it would find this worktree gone")
            continue
        if not matched:
            continue
        if lapsed:
            lapsed_here.append((why, mtime))
            continue
        return why, resumable, False
    # A session id that another job still holds by, or a live session carries, never lapses.
    lapsed_ids -= held_ids | live_ids

    for d in live:
        sid = d.get("sessionId")
        if exclude and sid == exclude:
            continue
        label = f'session pid {d.get("pid")} "{d.get("name") or ""}"'
        cwd = d.get("cwd")
        if isinstance(cwd, str) and cwd and within(cwd):
            return f"{label} has its cwd here", resumable, False
        if isinstance(sid, str) and sid:
            owners.append((sid, f"{label} is live"))

    newest, newest_dir = 0.0, ""
    for wt_slug in slugs:
        project_dir = os.path.join(home, "projects", wt_slug)
        own = []
        _jsonl_under(project_dir, "", own, unreadable, follow=True)  # as the ** glob it replaced did
        for path, _, mtime in own:
            rel = os.path.relpath(path, project_dir).split(os.sep)
            if exclude and (rel[0][:-6] if len(rel) == 1 else rel[0]) == exclude:
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
    by_owner, recent, fresh = {}, [], {}
    for path, owner, mtime in walk_transcripts(os.path.join(home, "projects"), unreadable):
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

    # A resumable done job's own transcripts (never its agents'): their last
    # `worktree-state` record is the worktree resuming it re-enters.
    binds = {}  # transcript -> owning session id
    bound_ts = []  # (why, [transcripts], launch dirs)
    for why_b, ids, link, dirs in bound:
        ts = [p for sid in sorted(ids) for p in by_owner.get(sid, ()) if os.path.basename(p) == sid + ".jsonl"]
        if link and transcript_owner(link) != exclude and link not in ts:
            ts.append(link)
        for t in ts:
            binds[t] = transcript_owner(t)
        bound_ts.append((why_b, ts, dirs))

    cache_file = _cache_path(cache_dir, home) if cache_dir else ""
    driven, skipped = driven_paths({**binds, **fresh, **candidates}, cache_file, need_bind=set(binds))
    # A done job's transcript that cannot be read holds below; it must not also
    # stop every other worktree from being called idle.
    unreadable += [t for t in skipped if t in fresh or t in candidates]
    for why_b, ts, dirs in bound_ts:
        for t in ts:
            b = driven.get(t, ({}, None, None))[2]
            if b and here(b):
                return f"{why_b}; its transcript {t} binds it to {b}", resumable, False
            if t in skipped and any(inside(s, d) for s in names for d in dirs):
                unread = f"{why_b}; its transcript {t} could not be read and this worktree is under its launch directory"
                return unread, resumable, False
    holder = None
    for t in sorted(candidates):
        hit = sorted(p for p in driven.get(t, ({}, None, None))[0] if here(p))
        if hit:
            holder = f"{why[t]}; its transcript {t} names {hit[0]}"
            break
    if holder is None:
        if not lapsed_here:
            return None, resumable, False
        holder = lapsed_here[0][0]  # a lapse needs a window, so this is never reported unheld
    if not window:
        return holder, resumable, False
    # Only the transcripts asked about before #793: a done job's own transcript is
    # read for its binding alone and never moves the idle clock.
    named_at = [w for t, (found, *_) in driven.items() if t in fresh or t in candidates
                for p, w in found.items() if here(p)]
    last = max(named_at + [m for _, m in lapsed_here], default=now)
    if now - last < window:
        return holder, resumable, False
    if unreadable:
        return (f"{holder}; not called idle: {len(unreadable)} record(s) or transcript(s) could not be read",
                resumable, False)
    for t, sid in sorted(candidates.items()):
        cwd = driven.get(t, ({}, None, None))[1]
        if cwd and within(cwd) and transcript_owner(t) == sid and sid not in lapsed_ids:
            return f"{holder}; its session last recorded its cwd at {cwd}", resumable, False
    ago = f"{int((now - last) // 3600)}h ago" if last > 0 else "only by records with no time"
    return f"idle: {holder}; last named {ago}", resumable, True


def _env_hours(name: str, default: float) -> float:
    """Hours from the environment, or `default` (with a note) when it is not a
    finite number of 0 or more: a typo there must not stop every sweep."""
    v = os.environ.get(name, "")
    if not v:
        return default
    try:
        h = float(v)
    except ValueError:
        h = -1.0
    if h >= 0 and math.isfinite(h):
        return h
    print(f"wt_session_hold: ignored {name}={v!r} (not a number of hours, 0 or more); using {default:g}",
          file=sys.stderr)
    return default


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
    ap.add_argument("--resumable-hours", type=float,
                    default=_env_hours("WT_RESUMABLE_HOURS", DEFAULT_RESUMABLE_HOURS),
                    help="a done job holds the worktree it is bound to for this many hours after its last"
                         f" turn (default {DEFAULT_RESUMABLE_HOURS:g}, or WT_RESUMABLE_HOURS; 0 = never)")
    ap.add_argument("worktree")
    args = ap.parse_args(argv)
    if not args.idle_hours >= 0:
        ap.error("--idle-hours must be 0 or more")
    if not (args.resumable_hours >= 0 and math.isfinite(args.resumable_hours)):
        ap.error("--resumable-hours must be a finite number, 0 or more")
    try:
        holder, resumable, idle = check(args.worktree, args.claude_home, args.active_min, args.procfs,
                                        args.cache_dir, args.exclude_session, args.idle_hours,
                                        args.resumable_hours)
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
