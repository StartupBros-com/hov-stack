#!/usr/bin/env python3
"""proc_liveness — the shared "is this path held by a live process?" check.

WHY ONE IMPLEMENTATION (issue #378; incident 2026-08-06)
  wt-sweep.sh learned the hard way that /proc/*/cwd alone is not liveness: a
  daemon can hold a directory via a --cwd FLAG while detached (own cwd
  elsewhere, reparented to init), and sweeping under one left an orphan that
  wrote ~400 GiB over 15 days. Its alive() gained a /proc/*/cmdline fallback.
  reclaim-sweep.py meanwhile checked only /proc/*/fd. Each sweeper saw a
  different third of the picture, and the next sweeper would have grown a
  fourth variant. This module is the single implementation of all four
  signals, in the order the incidents taught us to trust them:

    fd       a process holds an open file at/inside the path
    cwd      a process has its working directory at/inside the path
    environ  a process carries the path in its environment (a background job
             holds its scratch dir as CLAUDE_JOB_DIR for its whole life while
             idle between writes — fd/cwd/cmdline are all blind to that)
    cmdline  a process names the path in its argv (the --cwd flag shape)

FAILURE DIRECTION
  Erring toward "alive" only defers a sweep by a cycle; erring toward "dead"
  deletes live state. So ambiguity resolves to alive, and a scan that cannot
  read procfs at all is an ERROR (exit 2), never "nothing is alive" — a gate
  that cannot compare must fail, not skip-green.

  The scanning process excludes itself: its own argv necessarily names the
  paths it was asked about. Unreadable per-pid entries (other users'
  fds/cwd/environ) are skipped best-effort, same as every prior
  implementation; cmdline is world-readable so that signal survives
  permission boundaries. environ and cmdline can only produce false ALIVES
  (a stale path in some process's env defers a sweep by a cycle) — never a
  false dead, which is the direction that deletes live state.

CLI (the bash callers' entry point, e.g. wt-sweep.sh alive()):
    proc_liveness.py [--quiet] [--procfs DIR] [--comm NAME] [--alias-roots DIRS]
                     -- PATH [PATH...]
  --comm NAME counts only processes whose /proc/<pid>/comm is NAME, for a
  caller that asks "is a git on this gitdir" rather than "is anything"
  (wt-unlock.sh, dotfiles#1590); a pid with no readable comm never matches.
  --alias-roots DIR[:DIR...] also matches environ/cmdline against each PATH
  spelled through a symlink sitting directly in one of those directories
  (wt-sweep.sh passes its repo roots; hov-stack#661). It only adds holds.
  exit 0  at least one PATH is held (each holder printed unless --quiet)
  exit 1  no PATH is held
  exit 2  cannot answer (unreadable procfs, bad usage) — treat as held

  Hand-debugging trap: invoking this through any `sh -c`-style wrapper that
  embeds the path in ITS command text (agent tool shells, ssh host "...",
  watch) reads as a false ALIVE — the wrapper is an ancestor, not this
  process, so self-exclusion cannot hide its argv. Assemble the path at
  runtime (p=/some/pre; p="$p"fix) or invoke the CLI directly.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Sequence
from typing import NamedTuple, Optional


NAME_MAX = 255  # longest single path component Linux allows


def alias_spellings(real: str, roots: Sequence[str]) -> list:
    """`real` as reached through each symlink sitting directly in one of `roots`
    that points at `real` or an ancestor of it.

    A checkout renamed with a link left at its old name (hov-stack#661) gives a
    process two ways to be handed a worktree: one started before the rename
    carries the old spelling, while git lists a worktree added after it under
    the real one. environ/cmdline match text, so without this the old spelling
    reads as "not held". wt_session_hold.py applies the same rule to session
    records; it keeps its own copy because a failed import there would read as
    "not held". Only absolute roots count, an unreadable root is skipped, and a
    link to / is ignored: it would spell every path.
    """
    out = []
    for root in roots:
        if not os.path.isabs(root):
            continue
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
                if target == os.sep or not (real == target or real.startswith(target + os.sep)):
                    continue
                s = os.path.normpath(e.path + real[len(target):])
                if s != real and s not in out:
                    out.append(s)
    return out


class Holder(NamedTuple):
    signal: str  # "fd" | "cwd" | "environ" | "cmdline"
    pid: int


class ProcSnapshot:
    """One pass over procfs; then any number of holder() queries against it.

    A snapshot is taken BEFORE a sweep plan and consulted per candidate, so a
    single scan serves the whole run. `exclude_pids` defaults to the current
    process; pass an explicit set (possibly empty) in tests.
    """

    def __init__(self, procfs: str = "/proc", exclude_pids=None):
        self.procfs = procfs
        self.pids_scanned = 0
        self._fd_targets: list[tuple[str, int]] = []
        self._cwds: list[tuple[str, int]] = []
        self._environs: list[tuple[str, int]] = []
        self._cmdlines: list[tuple[str, int]] = []
        self._comm: dict[int, str] = {}
        excl = {os.getpid()} if exclude_pids is None else set(exclude_pids)
        try:
            entries = os.listdir(procfs)
        except OSError:
            entries = []
        for entry in entries:
            if not entry.isdigit():
                continue
            pid = int(entry)
            # An excluded pid still counts as scanned: `ok` reports "could the
            # scan answer", and a listing that found only ourselves did answer.
            self.pids_scanned += 1
            if pid in excl:
                continue
            base = os.path.join(procfs, entry)
            try:
                with open(os.path.join(base, "comm"), encoding="utf-8", errors="replace") as fh:
                    self._comm[pid] = fh.read().strip()
            except OSError:
                pass
            try:
                self._cwds.append((os.readlink(os.path.join(base, "cwd")), pid))
            except OSError:
                pass
            # A path cannot contain NUL, so a substring match can never falsely
            # span two argv entries / env vars — same property grep -F had.
            for fname, dest in (("environ", self._environs), ("cmdline", self._cmdlines)):
                try:
                    with open(os.path.join(base, fname), "rb") as fh:
                        raw = fh.read()
                    if raw:
                        dest.append((raw.decode("utf-8", "surrogateescape"), pid))
                except OSError:
                    pass
            fdd = os.path.join(base, "fd")
            try:
                fds = os.listdir(fdd)
            except OSError:
                continue
            for fd in fds:
                try:
                    self._fd_targets.append((os.readlink(os.path.join(fdd, fd)), pid))
                except OSError:
                    continue

    @property
    def ok(self) -> bool:
        """False when the scan saw no processes at all — an answerless scan."""
        return self.pids_scanned > 0

    def holder(self, path: str, comm: Optional[str] = None,
               alias_roots: Sequence[str] = ()) -> Optional[Holder]:
        """First live holder of `path` (itself or anything under it), or None.

        `comm` restricts holders to processes whose comm is that name.
        `alias_roots` adds the spellings of `path` reached through symlinks
        sitting directly in those directories (see alias_spellings).
        """
        real = os.path.realpath(path)
        pref = real + os.sep
        # fd and cwd targets come kernel-resolved, so compare against realpath.
        # environ/cmdline hold whatever the process was HANDED, so also match
        # the caller's unresolved spelling — absolute only: a relative query
        # would make everything "alive" by matching its short substring anywhere.
        handed = [real]
        if os.path.isabs(path) and path != real:
            handed.append(path)
        for s in alias_spellings(real, alias_roots):
            if s not in handed:
                handed.append(s)
        for tgt, pid in self._fd_targets:
            if comm is not None and self._comm.get(pid) != comm:
                continue
            if tgt == real or tgt.startswith(pref):
                return Holder("fd", pid)
        for tgt, pid in self._cwds:
            if comm is not None and self._comm.get(pid) != comm:
                continue
            if tgt == real or tgt.startswith(pref):
                return Holder("cwd", pid)
        for signal, blobs in (("environ", self._environs), ("cmdline", self._cmdlines)):
            for blob, pid in blobs:
                if comm is not None and self._comm.get(pid) != comm:
                    continue
                if any(s in blob for s in handed):
                    return Holder(signal, pid)
        return None

    def held_children(self, root: str) -> dict[str, Holder]:
        """Every direct child of `root` that holder() would call held, in one pass.

        holder() is linear in the snapshot, so asking it once per entry of a
        283,000-entry /tmp never finishes (#2002). This inverts the query:
        each fd/cwd target under root names the one child it sits in, and
        each environ/cmdline occurrence of "root/" names every child that
        holder()'s substring match would accept there — including its false
        alives ("root/foo-other" holds "fo" and "foo"), because this must
        never be stricter than holder(). Children that are themselves
        symlinks are out of scope: their realpath leaves root, and the sweep
        never removes a symlink. Keys are child names; values the first
        holder seen, fd and cwd before environ and cmdline.
        """
        real = os.path.realpath(root)
        pref = real + os.sep
        spellings = [pref]
        if os.path.isabs(root) and root.rstrip(os.sep) != real:
            spellings.append(root.rstrip(os.sep) + os.sep)
        held: dict[str, Holder] = {}
        for signal, targets in (("fd", self._fd_targets), ("cwd", self._cwds)):
            for tgt, pid in targets:
                if tgt.startswith(pref):
                    name = tgt[len(pref):].split(os.sep, 1)[0]
                    if name:
                        held.setdefault(name, Holder(signal, pid))
        for signal, blobs in (("environ", self._environs), ("cmdline", self._cmdlines)):
            for blob, pid in blobs:
                for sp in spellings:
                    i = blob.find(sp)
                    while i != -1:
                        start = i + len(sp)
                        end = start
                        # A child name cannot contain the separator or NUL, nor
                        # exceed NAME_MAX, so these bound every name holder()
                        # could match here.
                        stop = min(len(blob), start + NAME_MAX)
                        while end < stop and blob[end] not in (os.sep, "\0"):
                            end += 1
                        for k in range(start + 1, end + 1):
                            held.setdefault(blob[start:k], Holder(signal, pid))
                        i = blob.find(sp, i + 1)
        return held


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1].strip())
    ap.add_argument("--quiet", action="store_true", help="no per-holder output")
    ap.add_argument("--procfs", default="/proc", help="procfs root (tests)")
    ap.add_argument("--comm", default=None, metavar="NAME",
                    help="count only processes whose /proc/<pid>/comm is NAME")
    ap.add_argument("--alias-roots", default="", metavar="DIR[:DIR...]",
                    help="also match each PATH as spelled through symlinks "
                         "sitting directly in these directories")
    ap.add_argument("paths", nargs="+", metavar="PATH")
    args = ap.parse_args(argv)
    roots = [r for r in args.alias_roots.split(":") if r]

    snap = ProcSnapshot(procfs=args.procfs)
    if not snap.ok:
        print(f"proc_liveness: cannot read any process under {args.procfs} — "
              "refusing to answer (treat as held)", file=sys.stderr)
        return 2

    any_held = False
    for p in args.paths:
        h = snap.holder(p, comm=args.comm, alias_roots=roots)
        if h:
            any_held = True
            if not args.quiet:
                print(f"{p}\t{h.signal}\tpid:{h.pid}")
    return 0 if any_held else 1


if __name__ == "__main__":
    sys.exit(main())
