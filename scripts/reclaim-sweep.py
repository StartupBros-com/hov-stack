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

  Agent SCRATCH is the same gap, at speed (issue #2002): see the SCRATCH
  section below. Residue waits weeks; scratch is reclaimed hourly once the
  evidence says the work that made it is over.

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
  reclaim-sweep.py --free-gb 30 # plan scratch as if / had 30 GB free
"""

from __future__ import annotations

import argparse
import ctypes
import fnmatch
import glob
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime
from typing import NamedTuple, Optional

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
    def __init__(self, name, pattern, min_age_days, keep_newest=0, why="", dirs_only=False,
                 restorable=None):
        self.name = name
        # One glob, or several that share this rule's keep_newest.
        self.patterns = (pattern,) if isinstance(pattern, str) else tuple(pattern)
        self.min_age_days = min_age_days
        self.keep_newest = keep_newest
        self.why = why
        # A `<dir>/*` glob catches sibling FILES that are real state, not scratch.
        # The first live run of this script proposed deleting ~/.claude/jobs/pins.json
        # — pinned-job state — alongside the job directories. Rules whose unit of
        # residue is a directory must say so.
        self.dirs_only = dirs_only
        # For a rule over copies of one thing: whether a match is a copy that
        # could be restored. keep_newest is spent only on those, and a copy's
        # age floor runs from when a newer one appeared, so the one it replaced
        # stays min_age_days as a fallback.
        self.restorable = restorable


# A copy that never finished, or a rollback journal whose database is gone, can't
# be restored, so keep_newest never spends a keep on one: from 2026-07-17 to
# 09-05 the two newest entries of ccflare's backups/ were a failed .partial pair.
NOT_RESTORABLE = re.compile(r"\.partial(?:-journal)?$|-journal$")

SQLITE_MAGIC = b"SQLite format 3\0"


def _whole_sqlite(path: str, live) -> bool:
    """A regular file holding a complete SQLite database other than the live
    one: its header's page count (trusted only when the change counter matches
    version-valid-for) times its page size fits in the file. A hardlink to the
    live DB is not a copy of it."""
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or (st.st_dev, st.st_ino) == live:
            return False
        with open(path, "rb") as fh:
            h = fh.read(100)
    except OSError:
        return False
    if len(h) < 100 or h[:16] != SQLITE_MAGIC:
        return False
    page = int.from_bytes(h[16:18], "big")
    page = 65536 if page == 1 else page
    if page < 512 or page & (page - 1):
        return False
    pages, change, valid_for = (int.from_bytes(h[i:i + 4], "big") for i in (28, 24, 92))
    if pages and change == valid_for:
        return st.st_size >= pages * page
    return st.st_size > 0 and st.st_size % page == 0


def sqlite_copy_of(live_db: str):
    """`Rule.restorable` for copies of the SQLite DB at live_db: a file that is
    one, or a directory with one anywhere inside (symlinks not followed)."""
    def holds(path: str) -> bool:
        try:
            st = os.stat(live_db)
            live = (st.st_dev, st.st_ino)
        except OSError:
            live = None
        if os.path.islink(path):
            return False
        if not os.path.isdir(path):
            return _whole_sqlite(path, live)
        for root, _, files in os.walk(path, onerror=lambda e: None):
            if any(_whole_sqlite(os.path.join(root, f), live) for f in files):
                return True
        return False
    return holds


CCFLARE = f"{HOME}/.config/better-ccflare"


# Ordered most- to least-valuable. Age floors are deliberately generous: this runs
# unattended, so the cost of waiting another week is zero and the cost of
# deleting something still wanted is not.
RULES = [
    Rule(
        "cass-broken-index",
        f"{HOME}/.local/share/*.broken-*",
        min_age_days=14,
        why="index tree renamed aside by a self-heal path that never cleans up",
    ),
    # Every copy of ccflare's DB, wherever it was put, is one pool with one
    # keep: the newest complete copy. Agents snapshot the DB by hand before a
    # risky change, each naming it its own way (on 2026-10-25, 21 GB matched no
    # rule), so backups/ is ruled by location. migrations.ts writes its own
    # `.backup.<ms>` before a destructive migration and prunes those to 3 only
    # when it writes another; nothing reads them back. Held apart, each name
    # kept its own newest: four full copies of a 5 GB DB on 10-25, and nothing
    # off the live disk (backup-harness doesn't carry it). And `backups/*` gave
    # its keep to the newest entry of any kind: a 24 KB scripts dir there was
    # five minutes from taking it from both DB snapshots.
    Rule(
        "ccflare-db-copy",
        (f"{CCFLARE}/*.db.bak-*", f"{CCFLARE}/pre-*-backup-*.db",
         f"{CCFLARE}/*.db.backup*", f"{CCFLARE}/backups/*"),
        min_age_days=14,
        keep_newest=1,
        restorable=sqlite_copy_of(f"{CCFLARE}/better-ccflare.db"),
        why="copy of ccflare's DB, or a recovery point beside it; the newest complete copy is kept",
    ),
    # A 7-day floor, under the 14 days everything else waits: the operator's
    # call on 2026-10-25 that ccflare doesn't need so many logs. The trace
    # feeds cache-telemetry reports and holds no state; ~150 MB a day.
    Rule(
        "ccflare-codex-trace",
        f"{CCFLARE}/codex-traces/codex-trace-*.jsonl",
        min_age_days=7,
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


def _rule_root(pattern: str) -> str:
    """The fixed directory a rule's glob lies under."""
    return os.path.dirname(re.split(r"[*?\[]", pattern, maxsplit=1)[0])


SIDECARS = ("-wal", "-shm", "-journal")


def _beyond_keep(rule, dated: list):
    """(path, when its age floor starts) for each match the rule's keep_newest
    leaves, newest first. `dated` is (mtime, path), newest first."""
    if rule.restorable is None:
        kept = 0
        for mtime, path in dated:
            if kept < rule.keep_newest and not NOT_RESTORABLE.search(os.path.basename(path)):
                kept += 1
                continue
            yield path, mtime
        return
    copies = [(mtime, path) for mtime, path in dated
              if not NOT_RESTORABLE.search(os.path.basename(path)) and rule.restorable(path)]
    keep = {path for _, path in copies[:rule.keep_newest]}
    # A copy is the fallback from the moment a newer one displaced it from the keep.
    displaced = {path: copies[i - rule.keep_newest][0]
                 for i, (_, path) in enumerate(copies) if i >= rule.keep_newest}
    for mtime, path in dated:
        if path in keep or any(path.endswith(s) and path[:-len(s)] in keep for s in SIDECARS):
            continue
        yield path, displaced.get(path, mtime)


def plan(now: float, snap) -> list[dict]:
    out = []
    # A path two globs match is the first rule's: planned twice, its second
    # removal would fail on a file already gone.
    claimed: set = set()
    cited = _cited_paths({_rule_root(p) for r in RULES for p in r.patterns})[0]
    for rule in RULES:
        matches = sorted({m for p in rule.patterns for m in glob.glob(p)})
        # newest-first by mtime so keep_newest preserves the most recent
        dated = []
        for m in matches:
            if m in claimed:
                continue
            claimed.add(m)
            try:
                dated.append((os.path.getmtime(m), m))
            except OSError:
                continue
        dated.sort(reverse=True)
        for path, since in _beyond_keep(rule, dated):
            age_days = (now - since) / DAY
            if age_days < rule.min_age_days:
                continue
            if rule.dirs_only and not os.path.isdir(path):
                continue
            if not is_safe_target(path):
                continue
            holder = snap.holder(path)
            skip = f"held by a live process ({holder.signal}, pid {holder.pid})" if holder else None
            if not skip and any(c == path or c.startswith(path + "/") for c in cited):
                skip = "cited by a memory note"
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


# ---------------------------------------------------------------------------
# SCRATCH (issue #2002)
#
# The root fs filled three times in a month (2026-09-28, 10-06, 10-24), and not
# from residue: from agent scratch — per-experiment CUDA venvs, monorepo copies
# with node_modules, raw video frames — written to /tmp/<dir> and
# $CLAUDE_JOB_DIR/tmp at up to ~159 GB a day. Nothing ends scratch when the
# session that made it ends, and every reclaimer ran on a calendar (weekly,
# 14-30 day floors) that one day's burst outruns. So scratch is judged by
# evidence that its work is over, against floors that shrink as / fills, on an
# hourly timer:
#
#   job-scratch  the CONTENTS of $CLAUDE_JOB_DIR/tmp once Claude Code itself
#                calls the job settled (done/failed/stopped, tempo not active),
#                its session is not in the live registry, and it has been
#                quiet for the floor. "done" is per-turn — 2b5a4195 went done
#                at 04:30Z and was resumed at 05:46Z on 2026-10-25, and seven
#                done jobs sat waiting on the operator that day — so state.json
#                and the registry are read again right before removal, and
#                tmp/ itself stays for a resumed job to write into.
#   tmp-scratch  a direct child of /tmp or /tmp/claude-<uid> (Claude Code's
#                TMPDIR) that this user owns, nothing holds, and whose whole
#                tree has been write-idle for the floor. Claude Code's own
#                <project-slug>/ dirs there are never units: one holds every
#                session of a project, so it is the session dirs inside it
#                that are judged, and only while the session registry says no
#                live process owns them. A live session idle between tool
#                calls holds its dir by no procfs signal; the registry is what
#                knows. Anything else in a project dir (rerooted/) is kept.
#
# Either way only bulk is this sweep's (BULK_MIN_BYTES). The 271,520 smaller
# candidates of 2026-10-25 held 4 GiB of 164; in /tmp, systemd-tmpfiles already
# ages them at 14 days, and a job's stay with its job dir. Two owners outlive
# any session and are asked every run: a memory note that names a path keeps
# its unit (61 units, 24 GiB, that day, among them a cass backup kept while an
# upstream bug is open), and so does a docker bind mount (exited Supabase
# stacks mounted /tmp/sbl-stacks/*; a container runs as root, out of sight of
# the procfs check). Docker failing to answer keeps everything.
#
# A tree holding a git repository goes only when git says nothing in it lives
# nowhere else (issue #2003): every repository clean, every commit on a
# remote-tracking ref of a remote that still exists, and no worktree it
# registers or belongs to outside the tree. A .git dir git cannot open counts
# for nothing either way. A dry run on 2026-10-25 asked git of 125 bulk idle
# /tmp trees (48 GB): 52 go (21 GB), 33 of them (12 GB) holding only .git dirs
# systemd-tmpfiles had taken HEAD from. The rest stay: 46 with commits no
# remote has (25 GB), 11 dirty (0.6 GB), 10 worktrees of a repo elsewhere
# (1.4 GB, wt-sweep's to judge), 5 pushed to a remote that is gone, 1 git could
# not read. Not counted as unpushed: a commit only a reflog reaches, which
# every amend and rebase leaves behind.
#
# Those keeps for the tree's own work (OWN_WORK: commits, changes, a vanished
# remote, a linked worktree of a repo elsewhere) end once the whole tree is
# write-idle past GIT_WORK_HORIZON_H, 14 days (#2010): none of the 72 kept on
# 2026-10-25 (21.8 GB) held work found nowhere else. A tree something outside
# depends on (a worktree it registers, a work tree or git dir it serves) and
# one git could not answer for keep for good.
#
# Still a closed set: fixed roots, whole entries only, never a symlink, never
# across a mount, never a tree holding a socket. The roots
# are constants, not configuration, so no setting can aim this at $HOME (tests
# patch them the way they patch RULES). Removal walks each tree again first:
# a file rewritten two levels down moves no timestamp on the entry itself.
# ---------------------------------------------------------------------------

GB = 1024 ** 3
HOUR = 3600

CC_TMPDIR = f"/tmp/claude-{os.getuid()}"
SCRATCH_ROOTS = ("/tmp", CC_TMPDIR)
JOBS_ROOT = f"{HOME}/.claude/jobs"
# Claude Code's registry of running sessions: <pid>.json, each naming its sessionId.
SESSIONS_ROOT = f"{HOME}/.claude/sessions"
SESSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

# Children of a scratch root that belong to a daemon or to the system rather
# than to a session that ended. Dot-names and other owners are refused apart.
DAEMON_NAMES = ("claude-{uid}", "cc-daemon-{uid}", "tmux-{uid}",
                "systemd-private-*", "snap-private-tmp")

# Most severe first: (level, below this many GB free on /, job floor h, tmp floor h).
# The job floor never drops under 6h: the 76-minute resume above, with margin.
# /tmp never drops under 24h: 6h instead of 24h measured only ~14 GiB more du on
# 2026-10-25, and would take scratch a session left that morning.
PRESSURE_LEVELS = (
    ("critical", 40, 6, 24),
    ("high", 75, 24, 48),
    ("low", 150, 48, 72),
)
NORMAL_FLOORS_H = (72, 168)

# Planning stops examining new candidates after this long. What it skipped is
# counted and printed, never read as clean; TimeoutStartSec leaves removal the rest.
PLAN_BUDGET_S = 1200

# Git gets this long to judge one tree, or the tree is kept. The slowest tree of
# 2026-10-25 took 166 s: 19,386 fixture repositories.
GIT_TREE_BUDGET_S = 300
# -c overrides the repository's own config: a core.fsmonitor there names a
# command, and status would run it.
GIT_CMD = ("git", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false")
# What git said keeps each tree, so a kept tree is asked once per state, not
# every hour: git status lists every directory, under relatime that moves each
# one's atime daily, and systemd-tmpfiles, which ages /tmp by atime, would never
# take a tree this sweep keeps. It holds keep verdicts only, so losing it costs
# a re-ask and can never remove anything. Delete it if /tmp goes noatime.
GIT_KEEPS_PATH = f"{HOME}/.cache/reclaim-sweep/git-keeps.json"
# A failure ("git: no answer") is remembered too, or a tree git times out on
# would cost its whole bound every hour, but only this long, so a transient one
# keeps no tree for good. Longer than /tmp's 14 days on purpose: a repository
# there that no git opens that long loses its HEAD to systemd-tmpfiles, and
# with no HEAD it holds nothing git could give back.
GIT_RETRY_S = 30 * DAY
# Past this many write-idle hours, work only the tree holds no longer keeps it
# (#2010). The host already calls /tmp 14-day scratch (tmpfiles.d/tmp.conf),
# but systemd-tmpfiles ages by atime too, and a tree something reads never
# ages out under it: on 2026-10-25, 72 trees (21.8 GB) were kept for their own
# work, the oldest write-idle a month with its HEAD intact, and none held a
# commit or a change found nowhere else. Write evidence alone counts here, and
# pressure never lowers it. What something outside depends on is kept
# regardless (git_keeps).
GIT_WORK_HORIZON_H = 14 * 24
# The keeps that horizon ends: work only the tree holds, or a tie to a
# repository outside that loses nothing when the tree goes. A linked worktree's
# branch is its repository's; deleting the worktree leaves that repository one
# prunable entry (wt-sweep.sh prunes it), and a commit made there on a detached
# HEAD is work only the tree holds, like an unpushed one. A reason missing here
# keeps its tree past the horizon.
OWN_WORK = frozenset({
    "git: unpushed commits", "git: commits and no remote", "git: a remote that no longer exists",
    "git: uncommitted changes", "git: files status is told to skip", "git: a .git symlink",
    "git: a worktree of a repository outside it",
})

# Removal re-checks every item against a liveness scan at most this old. A scan
# costs ~30 ms; one per item would take 2.3 h for the 276,128 entries the first
# plan on 2026-10-25 found. What started holding an entry inside this window
# goes unseen, the same order as the time one rmtree takes anyway.
SNAPSHOT_MAX_AGE_S = 2.0

# The text report lists the largest scratch items and sums the rest (--json has all).
SHOW_SCRATCH_ITEMS = 20

# A session registry entry that does not parse and has not been written for this
# long has no writer: on 2026-10-25 the 18 live sessions' entries were at most
# 3.8 h old. Without this, a reused pid would revive a dead crash leftover.
UNPARSED_ENTRY_STALE_S = 3 * 24 * HOUR

SETTLED_STATES = frozenset({"done", "failed", "stopped"})

# Below this many bytes an entry (or a job's tmp child) is not this sweep's to
# take: 2026-10-25's 6,032 candidates of 1 MiB or more held 97.6% of the bytes.
BULK_MIN_BYTES = 1024 ** 2

# Memory notes; a scratch path one of them names is kept.
MEMORY_ROOT = f"{HOME}/.claude/projects"
# What ends a cited path: whitespace, quotes, brackets, and shell or Markdown punctuation.
CITED_PATH_CHARS = r"[^\s'\"`()\[\]<>,;|*${}]"

DOCKER = "docker"
DOCKER_TIMEOUT_S = 30

# Directory reads that leave atime alone where the kernel allows it.
O_NOATIME = getattr(os, "O_NOATIME", 0)
# What a bare repository has instead of a .git entry.
BARE_REPO_NAMES = frozenset({"HEAD", "objects", "refs"})


def pressure(free: int) -> tuple:
    """(level, job-scratch floor h, tmp-scratch floor h) for `free` bytes on /."""
    for level, below_gb, job_h, tmp_h in PRESSURE_LEVELS:
        if free < below_gb * GB:
            return level, job_h, tmp_h
    return ("normal",) + NORMAL_FLOORS_H


def free_bytes(path: str = "/") -> int:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def _free_by_fs() -> dict:
    """Free bytes on each distinct filesystem this sweep removes from."""
    out = {}
    for p in ("/", HOME, *SCRATCH_ROOTS):
        try:
            out.setdefault(os.stat(p).st_dev, free_bytes(p))
        except OSError:
            continue
    return out


def _write_time(st) -> float:
    """Write evidence from one lstat: the whole rule for a scan's top entry,
    and for the entries below it where _inner_write_time has no birth time.

    A directory's mtime and ctime both count, and a file's mtime always.
    ctime must count: npm/tar extraction restores ancient mtimes, and only the
    inode change time says the tree was written today (62 GB of /tmp had that
    shape on 2026-10-06). But a multi-link file's ctime moves whenever ANY link
    to its inode is made or removed anywhere — a finished job's hardlinked
    node_modules showed 196,278 minutes-old ctimes, every one nlink>1, on
    2026-10-25 — so it counts only for single-link files. Nothing real is lost:
    the directories record every create, rename and delete. atime never counts:
    one bulk reader had touched 14,802 idle entries (26 GiB) 35-38 h before the
    2026-10-25 plan, and nothing about them had been written.
    """
    if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
        return st.st_mtime
    return max(st.st_mtime, st.st_ctime)


# statx(2), for the birth time os.stat_result does not carry on Linux.
_AT_FDCWD = -100
_AT_SYMLINK_NOFOLLOW = 0x100
_STATX_BTIME = 0x800
_statx = None  # libc's statx, looked up on first use; False where there is none


class _StatxTime(ctypes.Structure):
    _fields_ = [("sec", ctypes.c_int64), ("nsec", ctypes.c_uint32), ("_reserved", ctypes.c_int32)]


class _Statx(ctypes.Structure):
    """struct statx (include/uapi/linux/stat.h) through stx_btime, padded to its fixed 256 bytes."""
    _fields_ = [("mask", ctypes.c_uint32), ("blksize", ctypes.c_uint32), ("attributes", ctypes.c_uint64),
                ("nlink", ctypes.c_uint32), ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32),
                ("mode", ctypes.c_uint16), ("_spare0", ctypes.c_uint16), ("ino", ctypes.c_uint64),
                ("size", ctypes.c_uint64), ("blocks", ctypes.c_uint64), ("attributes_mask", ctypes.c_uint64),
                ("atime", _StatxTime), ("btime", _StatxTime), ("_rest", ctypes.c_uint8 * 160)]


def _birth_time(path: str, ino: int) -> Optional[float]:
    """When inode `ino` at `path` was created; None where the filesystem or
    libc cannot say, or `path` is no longer that inode. Nothing in userspace
    sets it: tar, cp -p and rsync -t restore mtimes, never this."""
    global _statx
    if _statx is None:
        try:
            _statx = ctypes.CDLL(None, use_errno=True).statx
            _statx.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint,
                               ctypes.POINTER(_Statx))
        except (AttributeError, OSError):
            _statx = False
    if not _statx:
        return None
    buf = _Statx()
    if _statx(_AT_FDCWD, os.fsencode(path), _AT_SYMLINK_NOFOLLOW, _STATX_BTIME, ctypes.byref(buf)):
        return None
    if not buf.mask & _STATX_BTIME or buf.ino != ino:
        return None
    return buf.btime.sec + buf.btime.nsec / 1e9


def _inner_write_time(path: str, st) -> float:
    """Write evidence for an entry below the one a scan starts from: its birth
    time stands in for the ctime _write_time would count.

    Two things move those ctimes without writing anything. systemd-tmpfiles
    restores a directory's times after deleting in it (idle trees' directory
    ctimes cluster at 23:5x, its nightly run). And dropping a file's other
    links leaves it single-link with a new ctime: 13,196 entries of a tree last
    written 09-26 had 10-25 04:3x and 10-26 19:55 ctimes. Each reset restarted
    the floors and the 14-day git horizon, so idle trees never aged out and /
    fell to 9.6 GB free on 2026-10-27 (#2033). An extraction is still seen,
    because its inodes are born the day it writes them (#2002).

    The top entry keeps ctime: a tree renamed into scratch has nothing else to
    show it arrived. Given up: an in-place overwrite that then restores an old
    mtime (cp -p onto an existing file, rsync --inplace -t) shows only in
    ctime; a job doing that is still covered by the holder and session checks.
    """
    w = _write_time(st)
    if w <= st.st_mtime:
        return w
    born = _birth_time(path, st.st_ino)
    return w if born is None else max(st.st_mtime, born)


def _identity(st) -> tuple:
    """What an entry looked like at plan time, under the same ctime rule."""
    noisy = stat.S_ISREG(st.st_mode) and st.st_nlink > 1
    return (st.st_dev, st.st_ino, st.st_mtime_ns, None if noisy else st.st_ctime_ns)


class TreeScan(NamedTuple):
    newest: float          # newest write evidence seen before the walk stopped
    veto: Optional[str]    # why this tree must never be swept, if any
    apparent: int          # bytes seen (all of them only when complete)
    unshared: int          # bytes in single-link files: a floor on what removal frees
    complete: bool         # walked to the end with nothing fresh and no veto
    ident: tuple = ()      # _identity() of the top entry
    repos: tuple = ()      # (kind, path) of each git repository a complete walk found


def _entries(path: str) -> list:
    """(name, lstat) of each entry of directory `path`, None for one that went
    between listing and stat. Read without moving the directory's atime:
    systemd-tmpfiles ages a directory by its atime too, and under relatime a
    readdir moves it once a day, so an hourly walk would keep alive every tree
    it leaves to tmpfiles."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(path, flags | O_NOATIME)
    except PermissionError:
        fd = os.open(path, flags)  # O_NOATIME is for the directory's owner only
    try:
        out = []
        with os.scandir(fd) as it:
            for e in it:
                try:
                    out.append((e.name, e.stat(follow_symlinks=False)))
                except OSError:
                    out.append((e.name, None))
        return out
    finally:
        os.close(fd)


FOREIGN_DIR_VETO = "has a directory it cannot empty"


def _can_empty(d: str, dst: os.stat_result, uid: int) -> bool:
    """Whether `uid` can surely unlink every entry of directory `d`, decided
    without reading it. A directory of its own, always: removal grants itself
    owner-write first (_rmtree). Anyone else's must be writable and searchable
    by this process, and not sticky. /tmp/tmp.kCnF9EYpYY held a root-owned copy
    of /etc/systemd/system: the first live run (2026-10-25) removed part of the
    tree, failed on the rest and paged, and would have every hour after.

    Asked before the listing, because a readdir of a directory not ours can't
    use O_NOATIME: an hourly walk would refresh its atime daily, and
    systemd-tmpfiles, the one owner able to remove root's files, would never
    age the kept tree out. So an empty one of these vetoes too, and so does a
    sticky one holding only our entries; both are rare."""
    if dst.st_uid == uid:
        return True
    return not dst.st_mode & stat.S_ISVTX and os.access(d, os.W_OK | os.X_OK)


def _git_opens(git_dir: str) -> bool:
    """git's own test for a git dir (is_git_directory, setup.c): a HEAD, and
    objects/ and refs/ unless a commondir file puts them elsewhere. In /tmp,
    systemd-tmpfiles takes them from a repository no git has read in 14 days,
    while text searches keep the work tree's files alive. One something still
    reads keeps them, so tmpfiles never ends a tree kept for its own work;
    GIT_WORK_HORIZON_H does."""
    def has(name):
        return os.path.lexists(os.path.join(git_dir, name))
    return has("HEAD") and (has("commondir") or (has("objects") and has("refs")))


def scan_tree(path: str, cutoff: float, uid: Optional[int] = None) -> TreeScan:
    """Walk `path` for write evidence newer than `cutoff`, for vetoes, and for
    the git repositories it holds.

    Stops at the first fresh entry or veto, so a live tree costs a few lstats
    and only a tree about to be reclaimed is walked in full. Never follows a
    symlink or crosses a mount. A repository's .git is walked like the rest,
    because a commit or a fetch is a write; what git says about it is asked
    apart (git_keeps), and only of a tree that is otherwise reclaimable.
    """
    try:
        top = os.lstat(path)
    except OSError:
        return TreeScan(math.inf, "vanished", 0, 0, False)
    ident = _identity(top)
    newest = _write_time(top)
    if newest > cutoff:
        return TreeScan(newest, None, 0, 0, False, ident)
    if stat.S_ISREG(top.st_mode):
        size = top.st_blocks * 512
        return TreeScan(newest, None, size, size if top.st_nlink == 1 else 0, True, ident)
    if not stat.S_ISDIR(top.st_mode):
        return TreeScan(newest, "is not a regular file or directory", 0, 0, False, ident)
    uid = os.getuid() if uid is None else uid
    apparent = unshared = 0
    repos = []
    # in_git: inside a .git dir or a bare repository. A dir shaped like a bare
    # repository in there is a submodule's git dir (modules/<name>), the only
    # copy of its commits once the submodule is deinitialised. A .git entry is a
    # repo wherever it is: git never makes one in there.
    stack = [(path, top, False)]
    while stack:
        d, dst, in_git = stack.pop()
        if not _can_empty(d, dst, uid):
            return TreeScan(newest, FOREIGN_DIR_VETO, apparent, unshared, False, ident)
        try:
            entries = _entries(d)
        except OSError:
            return TreeScan(newest, "has an unreadable subdirectory", apparent, unshared, False, ident)
        # A bare repository has no .git entry: /tmp/push-tracking-origin-* was
        # a remote other clones pushed to (2026-10-25).
        if BARE_REPO_NAMES <= {name for name, _ in entries}:
            if not in_git:
                repos.append(("bare", d))
                in_git = True
            elif os.path.basename(d) != ".git":
                repos.append(("module", d))
        subdirs = []
        for name, st in entries:
            if st is None:
                # listed, then gone: something is deleting in here right now
                return TreeScan(math.inf, None, apparent, unshared, False, ident)
            if name == ".git":
                if stat.S_ISDIR(st.st_mode):
                    kind = "dir" if _git_opens(os.path.join(d, name)) else "unopenable"
                elif stat.S_ISREG(st.st_mode):
                    kind = "file" if st.st_size else None  # uv marks its cache dirs with an empty one
                else:
                    kind = "link"
                if kind:
                    repos.append((kind, d))
            newest = max(newest, _inner_write_time(os.path.join(d, name), st))
            if newest > cutoff:
                return TreeScan(newest, None, apparent, unshared, False, ident)
            if stat.S_ISDIR(st.st_mode):
                if st.st_dev != top.st_dev:
                    return TreeScan(newest, "crosses a mount point", apparent, unshared, False, ident)
                subdirs.append((os.path.join(d, name), st, in_git or name == ".git"))
            elif stat.S_ISREG(st.st_mode):
                apparent += st.st_blocks * 512
                if st.st_nlink == 1:
                    unshared += st.st_blocks * 512
            elif not stat.S_ISLNK(st.st_mode):
                return TreeScan(newest, "contains a socket, fifo or device node",
                                apparent, unshared, False, ident)
        stack.extend(subdirs)
    return TreeScan(newest, None, apparent, unshared, True, ident, tuple(sorted(repos)))


class _GitOutOfTime(Exception):
    """The plan budget ran out before git answered."""


def _git_env() -> dict:
    """No GIT_* the caller set, no config but the repository's own, and no
    optional lock: a status that refreshed the index would be a write the next
    walk reads as fresh."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1", LC_ALL="C")
    return env


def _git(args: list, git_dir: str, work_tree: Optional[str], until: float, deadline: float):
    """stdout of one read-only git call, or None when git fails or `until`
    passes first. Raises _GitOutOfTime when the plan's `deadline` comes first."""
    cmd = [*GIT_CMD, f"--git-dir={git_dir}"]
    if work_tree is not None:
        cmd.append(f"--work-tree={work_tree}")
    left = min(until, deadline) - time.monotonic()
    p = None
    try:
        if left <= 0:
            raise subprocess.TimeoutExpired(cmd, 0)
        # Its own process group, so a timeout also ends what git started
        # (a submodule's git, a filter).
        p = subprocess.Popen(cmd + args, cwd=work_tree or git_dir, env=_git_env(),
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        out, _ = p.communicate(timeout=left)
    except subprocess.TimeoutExpired:
        if p is not None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.communicate()
        if deadline <= until:
            raise _GitOutOfTime from None
        return None
    except OSError:
        return None
    return out if p.returncode == 0 else None


def _inside(path: str, tree: str) -> bool:
    path, tree = os.path.realpath(path), os.path.realpath(tree)
    return path == tree or path.startswith(tree + "/")


def _gone_local_remote(remotes: bytes, root: str) -> bool:
    """Whether a remote `git remote -v` lists is a local path that no longer
    exists: a commit "pushed" there lives only in this tree now."""
    for line in remotes.splitlines():
        url = os.fsdecode(line.split(b"\t", 1)[-1].rsplit(b" (", 1)[0])
        if url.startswith("file://"):
            url = url[len("file://"):]
        elif "://" in url or ":" in url.split("/", 1)[0]:
            continue  # a network remote: host:path or scheme://
        if url and not os.path.exists(os.path.join(root, url)):
            return True
    return False


def git_keeps(tree: str, repos: tuple, deadline: float) -> tuple:
    """(why git says `tree` holds work that lives nowhere else, outside paths
    that verdict rests on), or (None, []) when every repository in it is clean
    and pushed. Raises _GitOutOfTime when the plan budget runs out first.

    What something outside depends on, or git failing to say, ends the asking.
    Work only the tree holds (OWN_WORK) does not: GIT_WORK_HORIZON_H ends that
    keep, so the first one found only stops the questions about the tree's own
    work, and every repository is still asked what depends on it."""
    until = time.monotonic() + GIT_TREE_BUDGET_S
    own_work = None

    def no_answer():
        late = time.monotonic() >= until
        return (f"git: no answer within {GIT_TREE_BUDGET_S}s" if late else "git: no answer"), []

    for kind, root in repos:
        if kind == "unopenable":
            continue  # git cannot open it, so it holds nothing git could give back
        if kind == "link":
            own_work = own_work or "git: a .git symlink"
            continue
        own = kind in ("bare", "module")  # root is the git dir itself
        git_dir = root if own else os.path.join(root, ".git")
        work = None if own else root
        if kind == "file":
            try:
                with open(git_dir, "rb") as f:
                    head = f.read(4096)
            except OSError:
                return no_answer()
            if not head.startswith(b"gitdir:"):
                return no_answer()  # a .git file git cannot open
            if not _inside(os.path.join(root, os.fsdecode(head[7:].strip())), tree):
                own_work = own_work or "git: a worktree of a repository outside it"
                continue

        def ask(*args):
            # A git dir asked alone is its own work tree: a core.worktree left
            # behind (a submodule dir removed by hand) fails every call.
            return _git(list(args), git_dir, git_dir if own else work, until, deadline)

        if kind == "bare":
            # Bare-shaped but not bare: the git dir of a work tree that names it
            # from wherever it is (git init --separate-git-dir); git keeps no
            # record of where.
            out = ask("config", "--bool", "--default=false", "--get", "core.bare")
            if out is None:
                return no_answer()
            if out.strip() != b"true":
                return "git: the git dir of a work tree elsewhere", []
        elif kind == "dir":
            # worktree list names root even when core.worktree points elsewhere.
            out = ask("config", "--default=", "--get", "core.worktree")
            if out is None:
                return no_answer()
            if out.strip():
                work = os.path.join(git_dir, os.fsdecode(out.strip()))  # relative to the git dir
                if not _inside(work, tree):
                    return "git: its work tree is outside it", [work]
        if kind != "file":  # a linked worktree's list is its main repository's
            out = ask("worktree", "list", "--porcelain", "-z")
            if out is None:
                return no_answer()
            outside = [p for p in (os.fsdecode(f[len(b"worktree "):]) for f in out.split(b"\0")
                                   if f.startswith(b"worktree "))
                       if not _inside(p, tree) and os.path.lexists(p)]
            if outside:
                return "git: registers a worktree outside it", outside
        if own_work:
            continue
        out = ask("rev-list", "-n1", "--all", "--not", "--remotes")
        remotes = ask("remote", "-v")
        if out is None or remotes is None:
            return no_answer()
        if out.strip():
            own_work = "git: unpushed commits" if remotes.strip() else "git: commits and no remote"
            continue
        if _gone_local_remote(remotes, root):
            own_work = "git: a remote that no longer exists"
            continue
        if work is not None:
            out = ask("status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none")
            if out is None:
                return no_answer()
            if out.strip():
                own_work = "git: uncommitted changes"
                continue
            # An edit to a file marked assume-unchanged (lowercase tag) or
            # skip-worktree (S) is one status never shows. A sparse checkout
            # marks the files it leaves out S too, but those are not there.
            out = ask("ls-files", "-v", "-z")
            if out is None:
                return no_answer()
            top = os.fsencode(work)
            if any(e[:1].islower() or (e[:1] == b"S" and os.path.lexists(os.path.join(top, e[2:])))
                   for e in out.split(b"\0")):
                own_work = "git: files status is told to skip"
    return own_work, []


class GitVerdict(NamedTuple):
    """git's answer for one tree: `keep` says why it stays; `let_go` names the
    keep GIT_WORK_HORIZON_H ended. Neither: every repository is clean and pushed."""
    keep: Optional[str] = None
    let_go: Optional[str] = None


class _GitKeeps:
    """git_keeps, remembering each keep verdict until its tree changes
    (GIT_KEEPS_PATH), and a failure no longer than GIT_RETRY_S. A tree it says
    to remove is asked afresh every time. A keep for the tree's own work
    (OWN_WORK) lets the tree go once it is write-idle past GIT_WORK_HORIZON_H,
    remembered or freshly asked."""

    def __init__(self, path: str):
        self.path = path
        try:
            with open(path) as f:
                old = json.load(f)
        except (OSError, ValueError):
            old = {}
        self.old = old if isinstance(old, dict) else {}
        self.new: dict = {}
        self.judged: set = set()
        self.asked = self.remembered = self.let_go = 0
        self.save_error: Optional[str] = None

    def _still_holds(self, was, fp, now: float) -> bool:
        if not (isinstance(was, dict) and was.get("fp") == fp and isinstance(was.get("keep"), str)):
            return False
        # Verdicts saved before #2010 stopped at the first keep, so one for the
        # tree's own work may hide something outside that depends on it.
        if was.get("soft") is not (was["keep"] in OWN_WORK):
            return False
        if was["keep"].startswith("git: no answer"):
            asked = was.get("asked")
            if not isinstance(asked, (int, float)) or not 0 <= now - asked < GIT_RETRY_S:
                return False
        outside = was.get("outside")
        if not outside:
            return True
        # Kept for a worktree elsewhere: holds while one of them is still there.
        return isinstance(outside, list) and any(isinstance(p, str) and os.path.lexists(p) for p in outside)

    def keeps(self, tree: str, scan: TreeScan, now: float, deadline: float) -> GitVerdict:
        fp = [list(scan.ident), scan.newest, scan.apparent, [list(r) for r in scan.repos]]
        was = self.old.get(tree)
        if self._still_holds(was, fp, now):
            self.judged.add(tree)
            self.new[tree] = was
            self.remembered += 1
            why = was["keep"]
        else:
            why, outside = git_keeps(tree, scan.repos, deadline)
            self.judged.add(tree)
            self.asked += 1
            if not why:
                return GitVerdict()
            self.new[tree] = {"fp": fp, "keep": why, "outside": outside, "soft": why in OWN_WORK,
                              "asked": now}
        if why in OWN_WORK and now - scan.newest >= GIT_WORK_HORIZON_H * HOUR:
            self.let_go += 1
            return GitVerdict(let_go=why)
        return GitVerdict(keep=why)

    def save(self) -> None:
        out = {p: e for p, e in self.old.items() if p not in self.judged and os.path.lexists(p)}
        out.update(self.new)
        if out == self.old:
            return
        tmp = f"{self.path}.{os.getpid()}"
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(tmp, "w") as f:
                json.dump(out, f)
            os.replace(tmp, self.path)
        except OSError as e:
            self.save_error = str(e)

    def evidence(self) -> str:
        said = f"{self.asked} tree(s) asked, {self.remembered} verdict(s) remembered"
        if self.let_go:
            said += f", {self.let_go} let go past the {GIT_WORK_HORIZON_H // 24}d horizon"
        return f"{said}; not saved: {self.save_error}" if self.save_error else said


def _mtime(path: str) -> float:
    try:
        return os.stat(path).st_mtime
    except OSError:
        return 0.0


def _iso_epoch(value) -> float:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _job_state(job: str):
    """(fingerprint, state.json) — the fingerprint moves on any rewrite."""
    p = os.path.join(job, "state.json")
    try:
        st = os.stat(p)
        with open(p, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None, None
    if not isinstance(doc, dict):
        return None, None
    return (st.st_ino, st.st_mtime_ns, st.st_size,
            doc.get("state"), doc.get("tempo"), doc.get("lastTerminalAt")), doc


def _pins_text(jobs_root: str) -> Optional[str]:
    """pins.json's raw text ("" when absent); None when it exists but cannot be
    read, and then every job counts as pinned. A job id that appears anywhere in
    the text is pinned, which holds whatever shape Claude Code gives the file."""
    try:
        with open(os.path.join(jobs_root, "pins.json"), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""
    except OSError:
        return None


def _live_sessions() -> Optional[set]:
    """Session ids Claude Code's registry says a running process owns; None
    when that cannot be told, and then every session dir counts as live. A
    dead pid reused by another process keeps its session — the safe
    direction — and an entry from another pid namespace is taken as live.
    An entry that does not parse names no session, so it is skipped when no
    one has written it for UNPARSED_ENTRY_STALE_S, or when the pid its file
    is named for is not running here and no entry is from another namespace
    (where that pid would mean nothing); 10-25, one zero-byte entry an 08-21
    crash left kept all 2,573 session dirs."""
    try:
        names = [n for n in os.listdir(SESSIONS_ROOT) if n.endswith(".json")]
        ns = os.readlink("/proc/self/ns/pid")
    except OSError:
        return None
    live, unparsed, foreign = set(), [], False
    for name in names:
        try:
            with open(os.path.join(SESSIONS_ROOT, name), encoding="utf-8") as fh:
                doc = json.load(fh)
            pid, sid = int(doc["pid"]), str(doc["sessionId"])
        except FileNotFoundError:
            continue  # that session exited while we listed
        except (ValueError, KeyError, TypeError):
            try:
                if time.time() - os.stat(os.path.join(SESSIONS_ROOT, name)).st_mtime > UNPARSED_ENTRY_STALE_S:
                    continue  # a live session rewrites its entry; this one's writer is gone
            except FileNotFoundError:
                continue
            unparsed.append(name[:-len(".json")])
            continue
        except OSError:
            return None
        domain = str(doc.get("pidDomain") or "")
        if domain and not domain.endswith(ns):
            foreign = True
            live.add(sid)
        elif os.path.exists(f"/proc/{pid}"):
            live.add(sid)
    if unparsed and (foreign or not all(p.isdigit() and not os.path.exists(f"/proc/{p}")
                                        for p in unparsed)):
        return None
    return live


def _all_roots() -> set:
    return {os.path.normpath(r) for r in (*SCRATCH_ROOTS, JOBS_ROOT)}


def _scratch_unit(path: str) -> Optional[str]:
    """The unit this sweep judges that `path` lies in: a job dir for anything
    in its tmp/, a session dir inside a Claude Code project dir, otherwise the
    scratch root's child. None for a root itself, a project dir, or a path
    outside every root: naming one of those keeps nothing."""
    path = os.path.normpath(path)
    jobs = os.path.normpath(JOBS_ROOT)
    if path.startswith(jobs + "/"):
        parts = path[len(jobs) + 1:].split("/")
        return os.path.join(jobs, parts[0]) if len(parts) > 1 and parts[1] == "tmp" else None
    cc = os.path.normpath(CC_TMPDIR)
    for root in sorted({os.path.normpath(r) for r in SCRATCH_ROOTS}, key=len, reverse=True):
        if not path.startswith(root.rstrip("/") + "/"):
            continue
        parts = path[len(root.rstrip("/")) + 1:].split("/")
        if root == cc and parts[0].startswith("-"):
            if len(parts) > 1 and SESSION_ID.fullmatch(parts[1]):
                return os.path.join(root, parts[0], parts[1])
            return None
        return os.path.join(root, parts[0])
    return None


def _citation_pattern(roots):
    """Any path under one of `roots`, spelled out or from ~, $HOME or ${HOME}."""
    spellings = set()
    for root in roots:
        spellings.add(re.escape(root))
        if root.startswith(HOME + "/"):
            rest = re.escape(root[len(HOME):])
            spellings.update(p + rest for p in ("~", r"\$HOME", r"\$\{HOME\}"))
    alts = "|".join(sorted(spellings, key=len, reverse=True))
    return re.compile(rf"(?<![\w.~/-])(?:{alts})(?:/{CITED_PATH_CHARS}*)?")


def _cited_paths(roots) -> tuple:
    """(paths under `roots` a memory note names, notes read, notes unreadable)."""
    pattern = _citation_pattern(roots)
    paths, read, unreadable = set(), 0, 0
    for note in glob.glob(os.path.join(glob.escape(MEMORY_ROOT), "*", "memory", "**", "*.md"),
                          recursive=True):
        try:
            with open(note, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            unreadable += 1
            continue
        read += 1
        for cited in pattern.findall(text):
            for spelling in ("${HOME}", "$HOME", "~"):
                if cited.startswith(spelling):
                    cited = HOME + cited[len(spelling):]
                    break
            paths.add(os.path.normpath(cited.rstrip(".:")))
    return paths, read, unreadable


def _cited_units() -> tuple:
    """(units a memory note names, notes read, notes unreadable)."""
    paths, read, unreadable = _cited_paths(_all_roots())
    return {u for u in map(_scratch_unit, paths) if u}, read, unreadable


def _docker_mounts() -> tuple:
    """(bind-mount sources of every container, running or exited; what docker
    said). The sources are None when docker could not say."""
    def docker(*args):
        return subprocess.run([DOCKER, *args], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=DOCKER_TIMEOUT_S)

    try:
        ps = docker("ps", "-aq", "--no-trunc")
        if ps.returncode != 0:
            if "Cannot connect to the Docker daemon" in ps.stderr:
                return [], "no daemon"
            return None, f"unknown: docker ps exited {ps.returncode}: {ps.stderr.strip()[-200:]}"
        ids = ps.stdout.split()
        if not ids:
            return [], "0 container(s) asked"
        inspect = docker("inspect", "--format", "{{json .Mounts}}", *ids)
    except FileNotFoundError:
        return [], "not installed"
    except (OSError, subprocess.SubprocessError) as e:
        return None, f"unknown: {e}"
    # A container removed between the two calls is "No such object"; the rest still answer.
    errors = [ln for ln in inspect.stderr.splitlines() if ln.strip() and "No such object" not in ln]
    if errors or (inspect.returncode != 0 and not inspect.stdout.strip()):
        return None, f"unknown: docker inspect exited {inspect.returncode}: {' '.join(errors)[-200:]}"
    sources = []
    try:
        for line in inspect.stdout.splitlines():
            for m in (json.loads(line) if line.strip() else None) or ():
                if m.get("Type") == "bind" and m.get("Source"):
                    sources.append(str(m["Source"]))
    except (ValueError, TypeError, AttributeError):
        return None, "unknown: docker inspect printed something other than mounts"
    return sources, f"{len(ids)} container(s) asked"


def _mounted_units(sources: list) -> set:
    """The units a bind mount reaches into, or {"*"} when one mounts a root or
    a directory above one."""
    roots, units = _all_roots(), set()
    for s in sources:
        s = os.path.normpath(s)
        if any(r == s or r.startswith(s.rstrip("/") + "/") for r in roots):
            return {"*"}
        units.add(_scratch_unit(s) or s)  # a mounted project dir covers its session dirs
    return units


def _covered(path: str, units: set) -> bool:
    return "*" in units or path in units or os.path.dirname(path) in units


class ScratchPlan(NamedTuple):
    items: list
    kept: Counter        # reason -> how many entries it kept
    unexamined: int      # left unwalked when the plan budget ran out
    evidence: dict       # what the owners outside this run said: docker, memory notes


def plan_scratch(now: float, snap, job_floor_h: float, tmp_floor_h: float,
                 budget_s: float = PLAN_BUDGET_S, uid: Optional[int] = None) -> ScratchPlan:
    uid = os.getuid() if uid is None else uid
    deadline = time.monotonic() + budget_s
    items: list = []
    kept: Counter = Counter()
    unexamined = 0
    live = _live_sessions()
    mounts, docker_said = _docker_mounts()
    mounted = _mounted_units(mounts) if mounts is not None else set()
    cited, notes_read, notes_unreadable = _cited_units()
    evidence = {"docker": docker_said, "memory notes read": notes_read,
                "memory notes unreadable": notes_unreadable}
    gitk = _GitKeeps(GIT_KEEPS_PATH)

    def owner(path):
        """Why an owner that outlives every session keeps `path`, if one does."""
        path = os.path.normpath(path)
        if mounts is None:
            return "docker mounts unknown"
        if _covered(path, mounted):
            return "bind-mounted into a docker container"
        if path in cited:
            return "cited by a memory note"
        return None

    # job-scratch: cheap checks first (state, pins, registry, liveness, quiet,
    # owners), then the walk.
    job_cutoff = now - job_floor_h * HOUR
    try:
        job_ids = sorted(e.name for e in os.scandir(JOBS_ROOT) if e.is_dir(follow_symlinks=False))
    except OSError:
        job_ids = []
    pins = _pins_text(JOBS_ROOT) if job_ids else ""
    # Asked of the JOB dir, never of its tmp: a job's tool children carry
    # CLAUDE_JOB_DIR=<job dir>, and "<job>/tmp" is not a substring of that.
    held_jobs = snap.held_children(JOBS_ROOT) if job_ids else {}
    for jid in job_ids:
        job = os.path.join(JOBS_ROOT, jid)
        tmp = os.path.join(job, "tmp")
        if os.path.islink(tmp) or not os.path.isdir(tmp):
            continue
        try:
            children = sorted(os.listdir(tmp))
        except OSError:
            kept["job tmp unreadable"] += 1
            continue
        if not children:
            continue
        fp, state = _job_state(job)
        if state is None:
            kept["job has no readable state.json"] += 1
            continue
        if state.get("state") not in SETTLED_STATES or state.get("tempo") == "active":
            kept["job not settled"] += 1
            continue
        if pins is None or jid in pins:
            kept["job pinned"] += 1
            continue
        sessions = {str(v) for v in (state.get("sessionId"), state.get("resumeSessionId")) if v}
        if live is None:
            kept["claude session registry unreadable"] += 1
            continue
        if sessions & live:
            kept["job session live"] += 1
            continue
        if jid in held_jobs:
            kept["job held"] += 1
            continue
        newest = max(_mtime(os.path.join(job, "state.json")),
                     _mtime(os.path.join(job, "timeline.jsonl")),
                     _iso_epoch(state.get("lastTerminalAt")))
        if newest > job_cutoff:
            kept["job not quiet"] += 1
            continue
        why = owner(job)
        if why:
            kept[why] += 1
            continue
        if time.monotonic() >= deadline:
            unexamined += 1
            continue
        scans, fresh = [], False
        for name in children:
            path = os.path.join(tmp, name)
            scan = scan_tree(path, job_cutoff, uid)
            if scan.veto:
                kept[scan.veto] += 1
                continue
            if not scan.complete:
                fresh = True
                break
            if scan.apparent < BULK_MIN_BYTES:
                kept["small: kept while its job dir is"] += 1
                continue
            if is_safe_target(path):
                scans.append((path, scan))
        if fresh:
            kept["job not quiet"] += 1
            continue
        # git only once the whole job is known quiet: its answers cost more.
        targets, apparent, unshared, clean, let_go = [], 0, 0, [], ""
        try:
            for path, scan in scans:
                git = gitk.keeps(path, scan, now, deadline) if scan.repos else GitVerdict()
                if git.keep:
                    kept[git.keep] += 1
                    continue
                newest = max(newest, scan.newest)
                targets.append((path, scan.ident))
                apparent += scan.apparent
                unshared += scan.unshared
                if git.let_go:
                    let_go += f"; {os.path.basename(path)}: {_past_horizon(git.let_go)}"
                else:
                    clean += scan.repos
        except _GitOutOfTime:
            unexamined += 1
            continue
        if targets:
            idle_h = (now - newest) / HOUR
            items.append({
                "rule": "job-scratch", "path": tmp, "bytes": apparent,
                "unshared_bytes": unshared, "entries": len(targets),
                "idle_hours": round(idle_h, 1), "age_days": round(idle_h / 24, 1),
                "why": f"scratch of a job Claude Code reports {state.get('state')} and no live "
                       f"session owns, quiet past the {job_floor_h}h floor; tmp/ itself is kept"
                       + _clean_repos(clean) + let_go,
                "skip": None, "_job": job, "_state_fp": fp, "_targets": targets,
                "_sessions": sessions, "_cutoff": job_cutoff,
            })

    # tmp-scratch: one lstat and an index lookup per entry; walks go oldest first.
    tmp_cutoff = now - tmp_floor_h * HOUR
    roots = {os.path.normpath(r) for r in SCRATCH_ROOTS}
    daemon = [pat.format(uid=uid) for pat in DAEMON_NAMES]
    candidates = []

    def consider(path, name, st, held, dev, session=None):
        why = None
        if st is None:
            return
        if stat.S_ISLNK(st.st_mode):
            why = "symlink"
        elif not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
            why = "not a file or directory"
        elif st.st_uid != uid:
            why = "not ours"
        elif st.st_dev != dev:
            why = "mount point"
        elif name in held:
            why = "held"
        elif _write_time(st) > tmp_cutoff:
            why = "fresh"
        else:
            why = owner(path)
        if why:
            kept[why] += 1
        else:
            candidates.append((_write_time(st), path, session))

    for root in SCRATCH_ROOTS:
        try:
            rst = os.lstat(root)
            if not stat.S_ISDIR(rst.st_mode):
                continue
            entries = _entries(root)
        except OSError:
            continue
        held = snap.held_children(root)
        cc_root = os.path.normpath(root) == os.path.normpath(CC_TMPDIR)
        for name, st in entries:
            path = os.path.join(root, name)
            if name.startswith("."):
                kept["hidden"] += 1
                continue
            if any(fnmatch.fnmatchcase(name, p) for p in daemon) or os.path.normpath(path) in roots:
                kept["daemon or system dir"] += 1
                continue
            if not (cc_root and name.startswith("-") and st is not None and stat.S_ISDIR(st.st_mode)):
                consider(path, name, st, held, rst.st_dev)
                continue
            # A Claude Code project dir: judge the session dirs inside it.
            try:
                sessions = _entries(path)
            except OSError:
                kept["has an unreadable subdirectory"] += 1
                continue
            # Nothing under a project dir can be held unless the project dir is.
            inner = snap.held_children(path) if name in held else {}
            for sname, sst in sessions:
                if not SESSION_ID.fullmatch(sname):
                    kept["claude code internal"] += 1
                elif live is None:
                    kept["claude session registry unreadable"] += 1
                elif sname in live:
                    kept["live claude session"] += 1
                else:
                    consider(os.path.join(path, sname), sname, sst, inner, rst.st_dev, session=sname)
    candidates.sort()
    for _, path, session in candidates:
        if time.monotonic() >= deadline:
            unexamined += 1
            continue
        scan = scan_tree(path, tmp_cutoff, uid)
        if scan.veto:
            kept[scan.veto] += 1
            continue
        if not scan.complete:
            kept["fresh"] += 1
            continue
        if scan.apparent < BULK_MIN_BYTES:
            kept["small: systemd-tmpfiles ages it"] += 1
            continue
        git = GitVerdict()
        if scan.repos:
            try:
                git = gitk.keeps(path, scan, now, deadline)
            except _GitOutOfTime:
                unexamined += 1
                continue
            if git.keep:
                kept[git.keep] += 1
                continue
        idle_h = (now - scan.newest) / HOUR
        whose = "an exited Claude Code session's" if session else "unheld"
        items.append({
            "rule": "tmp-scratch", "path": path, "bytes": scan.apparent,
            "unshared_bytes": scan.unshared,
            "idle_hours": round(idle_h, 1), "age_days": round(idle_h / 24, 1),
            "why": f"{whose} scratch, whole tree write-idle past the {tmp_floor_h}h floor"
                   + (f"; {_past_horizon(git.let_go)}" if git.let_go else _clean_repos(scan.repos)),
            "skip": None, "_ident": scan.ident, "_session": session, "_cutoff": tmp_cutoff,
        })
    gitk.save()
    evidence["git"] = gitk.evidence()
    return ScratchPlan(items, kept, unexamined, evidence)


def _past_horizon(why: str) -> str:
    """What a tree GIT_WORK_HORIZON_H let go says of the keep it no longer honours."""
    said = (f"write-idle past the {GIT_WORK_HORIZON_H // 24}d horizon, so git's "
            f"\"{why[len('git: '):]}\" no longer keeps it")
    if why == "git: a worktree of a repository outside it":
        said += "; a linked worktree's branch stays in its repository"
    return said


def _clean_repos(repos) -> str:
    """What git said of the repositories in a tree it let go."""
    n = sum(kind != "unopenable" for kind, _ in repos)
    m = len(repos) - n
    said = f"; its {n} git repositor{'y is' if n == 1 else 'ies are'} clean and pushed" if n else ""
    if m:
        said += (f"; {m} .git dir{' lacks' if m == 1 else 's lack'} the HEAD, objects or refs"
                 f" git needs to open {'it' if m == 1 else 'them'}")
    return said


def _rmtree(path: str) -> None:
    def retry(func, p, exc):
        # Test fixtures and Go's module cache leave 0555/0500 dirs behind,
        # which refuse unlinking their entries. Grant the parent owner-write and
        # retry once; a parent we don't own refuses the chmod, and that failure
        # and any other propagate.
        if func not in (os.unlink, os.remove, os.rmdir):
            raise exc if isinstance(exc, BaseException) else exc[1]
        parent = os.path.dirname(p)
        os.chmod(parent, stat.S_IMODE(os.lstat(parent).st_mode) | stat.S_IRWXU)
        func(p)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=retry)
    else:
        shutil.rmtree(path, onerror=retry)


def _rewritten(targets: list, cutoff: float) -> Optional[str]:
    """Why a target no longer looks as the plan saw it, walking each again;
    None when all still do."""
    for path, ident in targets:
        scan = scan_tree(path, cutoff)
        if scan.veto == "vanished":
            continue
        if scan.ident != ident:
            return f"{path}: changed since the plan"
        if scan.veto or not scan.complete:
            return f"{path}: {scan.veto or 'written to since the plan'}"
    return None


def apply_scratch(items: list, take_snapshot) -> tuple:
    """Remove planned scratch. Each item's trees are walked again first, and
    must still be write-idle and veto-free; then it must clear a liveness scan
    (`take_snapshot()`) and a session-registry read no older than
    SNAPSHOT_MAX_AGE_S, and a job must still have the state.json it was planned
    on. Returns (removed, failed, aborted); an abort is not a failure, the next
    run judges it afresh."""
    removed, failed, aborted = [], [], []
    snap, live, held_by_parent, taken = None, None, {}, -math.inf

    def holder_of(path):
        parent, name = os.path.split(path)
        if parent not in held_by_parent:
            held_by_parent[parent] = snap.held_children(parent)
        return held_by_parent[parent].get(name)

    for item in items:
        job = item["rule"] == "job-scratch"
        if job and not os.path.lexists(item["_job"]):
            continue  # a residue rule removed the whole job dir this run
        targets = item["_targets"] if job else [(item["path"], item["_ident"])]
        # The walk is the slow part, so it goes first and liveness stays the
        # last thing asked before anything is removed.
        stale = _rewritten(targets, item["_cutoff"])
        if stale:
            aborted.append(stale)
            continue
        if time.monotonic() - taken > SNAPSHOT_MAX_AGE_S:
            snap = take_snapshot()
            if not snap.ok:
                failed.append("scratch: a pre-removal liveness scan saw no processes — removed nothing further")
                break
            taken = time.monotonic()
            held_by_parent.clear()
            live = _live_sessions()
        if job:
            h = holder_of(item["_job"])
            if h is None and _job_state(item["_job"])[0] != item["_state_fp"]:
                aborted.append(f"{item['path']}: the job's state changed since the plan")
                continue
            if h is None and (live is None or item["_sessions"] & live):
                aborted.append(f"{item['path']}: its Claude Code session is live again")
                continue
        else:
            h = holder_of(item["path"])
            if h is None and item["_session"]:
                if live is None or item["_session"] in live:
                    aborted.append(f"{item['path']}: its Claude Code session is live again")
                    continue
        if h is not None:
            aborted.append(f"{item['path']}: held since the plan ({h.signal}, pid {h.pid})")
            continue
        for path, ident in targets:
            try:
                st = os.lstat(path)
            except FileNotFoundError:
                continue
            except OSError as e:
                failed.append(f"{path}: {e}")
                continue
            if _identity(st) != ident:
                aborted.append(f"{path}: changed since the plan")
                continue
            try:
                if stat.S_ISDIR(st.st_mode):
                    _rmtree(path)
                else:
                    os.unlink(path)
                removed.append(path)
            except OSError as e:
                failed.append(f"{path}: {e}")
    return removed, failed, aborted


def _public(item: dict) -> dict:
    return {k: v for k, v in item.items() if not k.startswith("_")}


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
    ap.add_argument("--free-gb", type=float, default=None, metavar="GB",
                    help="judge scratch pressure as if / had this much free; with --apply "
                         "it really removes at that pressure (every item still re-checked)")
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

    free = free_bytes() if args.free_gb is None else int(args.free_gb * GB)
    level, job_h, tmp_h = pressure(free)
    scratch = plan_scratch(now, snap, job_h, tmp_h)
    actionable += scratch.items
    total = sum(i["bytes"] for i in actionable)

    removed, failed, aborted, freed = [], [], [], None
    if args.apply:
        before = _free_by_fs()
        for i in actionable:
            if i["rule"] in ("job-scratch", "tmp-scratch"):
                continue
            try:
                if os.path.isdir(i["path"]) and not os.path.islink(i["path"]):
                    _rmtree(i["path"])
                else:
                    os.remove(i["path"])
                removed.append(i["path"])
            except FileNotFoundError:
                pass  # its owner pruned it first (migrations.ts does its own .backup.<ms>)
            except OSError as e:
                failed.append(f"{i['path']}: {e}")
        if scratch.items:
            # Planning can take minutes and removal longer; whatever started
            # using an entry since is caught by a scan taken right before that
            # entry goes, not by the plan's.
            r, f, a = apply_scratch(
                scratch.items, lambda: proc_liveness.ProcSnapshot(exclude_pids=frozenset()))
            removed += r
            failed += f
            aborted += a
        # du over hardlinked trees overstates what deleting them frees, so the
        # only yield claimed is what statvfs saw change (other writers included).
        after = _free_by_fs()
        freed = sum(after.get(dev, b) - b for dev, b in before.items())

    if args.json:
        print(json.dumps({
            "actionable": [_public(i) for i in actionable], "skipped": skipped,
            "total_bytes": total, "removed": removed, "failed": failed,
            "applied": args.apply, "freed_bytes": freed,
            "scratch": {
                "pressure": level, "free_bytes": free, "free_measured": args.free_gb is None,
                "floors_h": {"job": job_h, "tmp": tmp_h},
                "kept": dict(scratch.kept), "unexamined": scratch.unexamined,
                "aborted": aborted, "evidence": scratch.evidence,
            },
        }, indent=2))
    else:
        mode = "APPLIED" if args.apply else "PLAN (nothing removed — pass --apply)"
        print(f"reclaim-sweep [{mode}]")
        assumed = "" if args.free_gb is None else " (assumed via --free-gb)"
        print(f"  scratch pressure: {level} — {human(free)} free on /{assumed}; "
              f"floors: job {job_h}h, /tmp {tmp_h}h")
        if not actionable and not skipped:
            print("  nothing to reclaim")
        for i in actionable:
            if i["rule"] not in ("job-scratch", "tmp-scratch"):
                print(f"  {human(i['bytes']):>9}  {i['age_days']:>6.0f}d  {i['rule']:<28} {i['path']}")
                print(f"             {i['why']}")
        ranked = sorted(scratch.items, key=lambda i: i["bytes"], reverse=True)
        for i in ranked[:SHOW_SCRATCH_ITEMS]:
            note = f"  ({human(i['unshared_bytes'])} unshared)" if i["unshared_bytes"] < i["bytes"] else ""
            print(f"  {human(i['bytes']):>9}  {i['idle_hours']:>6.0f}h  {i['rule']:<28} {i['path']}{note}")
            print(f"             {i['why']}")
        rest = ranked[SHOW_SCRATCH_ITEMS:]
        if rest:
            print(f"  {human(sum(i['bytes'] for i in rest)):>9}  in {len(rest)} smaller scratch item(s) "
                  "not listed (--json lists every one)")
        if scratch.items:
            print(f"  scratch: {human(sum(i['bytes'] for i in scratch.items))} apparent, "
                  f"{human(sum(i['unshared_bytes'] for i in scratch.items))} in single-link files "
                  "(the least removal frees; hardlinks shared elsewhere stay)")
        for i in skipped:
            print(f"  {'SKIP':>9}  {i['rule']:<28} {i['path']} — {i['skip']}")
        if scratch.kept:
            print("  scratch kept: " + ", ".join(f"{n} {why}" for why, n in scratch.kept.most_common()))
        ev = scratch.evidence
        print(f"  scratch evidence: docker {ev['docker']}; {ev['memory notes read']} memory note(s) read, "
              f"{ev['memory notes unreadable']} unreadable; git: {ev['git']}")
        if scratch.unexamined:
            print(f"  scratch unexamined: {scratch.unexamined} entr(ies) left for the next run "
                  f"(plan budget {PLAN_BUDGET_S}s spent)")
        for a in aborted:
            print(f"  ABORTED: {a}")
        if failed:
            for f in failed:
                print(f"  FAILED: {f}")
        if freed is not None:
            print(f"  freed (df): {human(freed)}")
        print(f"  total reclaimable: {human(total)} across {len(actionable)} item(s)")
        # Trailing counter for the harness-weekly toast gate, same contract as
        # docker-flagged:N / agent-write-flagged:N.
        print(f"reclaim-flagged:{len(actionable)}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
