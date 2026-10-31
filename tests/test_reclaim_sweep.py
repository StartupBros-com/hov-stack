#!/usr/bin/env python3
"""Tests for reclaim-sweep.py.

The dangerous failure for a sweeper is not "missed something" — it is "deleted
something live". Every test here is a refusal test except the ones proving it
still finds real residue.
"""

import contextlib
import fnmatch
import importlib.util
import io
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
SWEEP = CLAUDE / "scripts" / "reclaim-sweep.py"

_spec = importlib.util.spec_from_file_location("reclaim_sweep_module", SWEEP)
R = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(R)

DAY = 86400


HOUR = 3600
GB = 1024 ** 3


class _NoHolders:
    """Liveness stub for rule-mechanics tests: nothing is ever held."""
    ok = True

    def holder(self, _path):
        return None

    def held_children(self, _root):
        return {}


class _DeadSnapshot:
    """Liveness stub for the fail-closed test: the scan could not answer."""
    ok = False

    def holder(self, _path):
        return None

    def held_children(self, _root):
        return {}


class _HoldsNames:
    """Liveness stub that holds the named children of any root."""
    ok = True

    def __init__(self, *names):
        self.names = set(names)

    def holder(self, path):
        return R.proc_liveness.Holder("cwd", 4242) if os.path.basename(path) in self.names else None

    def held_children(self, _root):
        return {n: R.proc_liveness.Holder("cwd", 4242) for n in self.names}


_NO_HOLDERS = _NoHolders()


def _scratch_root() -> str:
    """A scratch parent under $HOME, deep enough to clear is_safe_target."""
    root = os.path.join(R.HOME, ".cache", "reclaim-sweep-tests")
    os.makedirs(root, exist_ok=True)
    return root


_REAL_ROOTS = None


_ROOT_NAMES = ("SCRATCH_ROOTS", "JOBS_ROOT", "CC_TMPDIR", "SESSIONS_ROOT")
_HERMETIC_NAMES = _ROOT_NAMES + ("MEMORY_ROOT", "DOCKER", "BULK_MIN_BYTES", "GIT_KEEPS_PATH")
NO_CC_TMPDIR = "/nonexistent/claude-tmpdir"  # no fixture root is Claude Code's TMPDIR


def setUpModule():
    # main() walks the real scratch roots; point every test at empty fixtures
    # so none of them reads (or, under --apply, touches) the host's /tmp, nor
    # reads the host's memory notes or remembered git verdicts, or asks its
    # docker daemon.
    global _REAL_ROOTS, _EMPTY
    _REAL_ROOTS = tuple(getattr(R, n) for n in _HERMETIC_NAMES)
    _EMPTY = tempfile.TemporaryDirectory(dir=_scratch_root())
    for d in ("tmp", "jobs", "sessions", "projects"):
        os.makedirs(os.path.join(_EMPTY.name, d))
    R.SCRATCH_ROOTS = (os.path.join(_EMPTY.name, "tmp"),)
    R.JOBS_ROOT = os.path.join(_EMPTY.name, "jobs")
    R.CC_TMPDIR = NO_CC_TMPDIR
    R.SESSIONS_ROOT = os.path.join(_EMPTY.name, "sessions")
    R.MEMORY_ROOT = os.path.join(_EMPTY.name, "projects")
    R.DOCKER = os.path.join(_EMPTY.name, "no-docker")  # not installed: no containers
    R.GIT_KEEPS_PATH = os.path.join(_EMPTY.name, "git-keeps.json")
    # Fixture files are a few KiB; the size gate has its own tests (BulkGateTests).
    R.BULK_MIN_BYTES = 0


def tearDownModule():
    for n, v in zip(_HERMETIC_NAMES, _REAL_ROOTS):
        setattr(R, n, v)
    _EMPTY.cleanup()


@contextlib.contextmanager
def _roots(scratch_roots, jobs_root, cc_tmpdir=NO_CC_TMPDIR, sessions_root=None):
    saved = tuple(getattr(R, n) for n in _ROOT_NAMES)
    R.SCRATCH_ROOTS, R.JOBS_ROOT, R.CC_TMPDIR = tuple(scratch_roots), jobs_root, cc_tmpdir
    if sessions_root is not None:
        R.SESSIONS_ROOT = sessions_root
    try:
        yield
    finally:
        for n, v in zip(_ROOT_NAMES, saved):
            setattr(R, n, v)


@contextlib.contextmanager
def _patched(**values):
    saved = {k: getattr(R, k) for k in values}
    for k, v in values.items():
        setattr(R, k, v)
    try:
        yield
    finally:
        for k, v in saved.items():
            setattr(R, k, v)


class _Snapshots:
    """A snapshot factory that hands out the given snapshots in turn and counts calls."""

    def __init__(self, *snaps):
        self.snaps, self.calls = list(snaps), 0

    def __call__(self):
        self.calls += 1
        return self.snaps[min(self.calls, len(self.snaps)) - 1]


def _age(path, seconds_ago):
    t = time.time() - seconds_ago
    os.utime(path, (t, t), follow_symlinks=False)


# Fixture repositories are built with none of the host's git config.
_GIT_ENV = {**{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
_GIT = ("git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main",
        "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false")


def _git(*args, cwd=None):
    subprocess.run([*_GIT, *args], cwd=cwd, env=_GIT_ENV, check=True, capture_output=True)


class SafetyBoundaryTests(unittest.TestCase):
    """A malformed glob must never resolve to something structural."""

    def test_home_itself_is_never_a_target(self):
        self.assertFalse(R.is_safe_target(R.HOME))

    def test_shallow_path_under_home_is_refused(self):
        self.assertFalse(R.is_safe_target(os.path.join(R.HOME, ".config")))

    def test_path_outside_home_is_refused(self):
        self.assertFalse(R.is_safe_target("/etc/passwd"))
        self.assertFalse(R.is_safe_target("/"))

    def test_deep_path_under_home_is_allowed(self):
        self.assertTrue(R.is_safe_target(os.path.join(R.HOME, ".config", "foo", "bar.db")))

    def test_sibling_prefix_is_not_treated_as_inside_home(self):
        """A sibling path that shares the home directory as a string prefix must not pass."""
        self.assertFalse(R.is_safe_target(R.HOME + "-other/x/y"))


class HeldPathTests(unittest.TestCase):
    """A 22 GB directory something still holds is live state, not residue.

    Signal mechanics live in test_proc_liveness.py; these tests prove plan()
    actually consults the shared check, end-to-end against the real /proc,
    including the cwd shape that motivated issue #378. Holders must be child
    processes — the snapshot rightly excludes the test process itself.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=_scratch_root())
        self.child = None

    def tearDown(self):
        if self.child is not None:
            self.child.kill()
            self.child.wait()
        self.tmp.cleanup()

    def _aged_dir(self, name, age_days=90):
        d = os.path.join(self.tmp.name, name)
        os.makedirs(d)
        t = time.time() - age_days * DAY
        os.utime(d, (t, t))
        return d

    def _plan_now(self, rule):
        original = R.RULES
        R.RULES = [rule]
        try:
            # Mirror main()'s snapshot construction exactly (self INCLUDED) —
            # the self-exclusion policy is part of what these tests pin.
            return R.plan(time.time(), R.proc_liveness.ProcSnapshot(exclude_pids=frozenset()))
        finally:
            R.RULES = original

    def test_plan_skips_a_directory_held_as_cwd(self):
        """THE #378 gap: a job dir held only as a live process's cwd."""
        d = self._aged_dir("jobdir")
        self.child = subprocess.Popen(["sleep", "30"], cwd=d)
        time.sleep(0.2)
        got = self._plan_now(R.Rule("t", f"{self.tmp.name}/*", min_age_days=30, dirs_only=True))
        self.assertEqual(len(got), 1)
        self.assertIsNotNone(got[0]["skip"])
        self.assertIn("cwd", got[0]["skip"])

    def test_plan_skips_a_directory_with_a_held_file(self):
        d = self._aged_dir("index")
        fh = open(os.path.join(d, "held.db"), "w")
        try:
            self.child = subprocess.Popen(["sleep", "30"], cwd="/", stdout=fh)
        finally:
            fh.close()
        # creating held.db refreshed the dir mtime; re-age it past the floor
        t = time.time() - 90 * DAY
        os.utime(d, (t, t))
        time.sleep(0.2)
        got = self._plan_now(R.Rule("t", f"{self.tmp.name}/*", min_age_days=30, dirs_only=True))
        self.assertEqual(len(got), 1)
        self.assertIsNotNone(got[0]["skip"])
        self.assertIn("fd", got[0]["skip"])

    def test_plan_does_not_skip_an_unheld_directory(self):
        self._aged_dir("cold")
        got = self._plan_now(R.Rule("t", f"{self.tmp.name}/*", min_age_days=30, dirs_only=True))
        self.assertEqual(len(got), 1)
        self.assertIsNone(got[0]["skip"])

    def test_plan_sees_the_sweepers_own_cwd(self):
        """#384 vet finding: the sweeper must not blind itself to its OWN cwd.
        An operator cd'd into a target dir running --apply by hand would have
        the directory rmtree'd out from under their shell if the snapshot
        excluded the sweeping process itself."""
        d = self._aged_dir("own-cwd")
        old = os.getcwd()
        os.chdir(d)
        try:
            got = self._plan_now(R.Rule("t", f"{self.tmp.name}/*", min_age_days=30, dirs_only=True))
        finally:
            os.chdir(old)
        self.assertEqual(len(got), 1)
        self.assertIsNotNone(got[0]["skip"])
        self.assertIn("cwd", got[0]["skip"])


class RuleSelectionTests(unittest.TestCase):
    """Age floor and keep_newest must both bind, independently."""

    def setUp(self):
        # Fixtures MUST live under $HOME: is_safe_target refuses anything outside it,
        # so a /tmp fixture would silently exercise nothing. (Caught by this suite's
        # first run, which reported 0 candidates for a 40-day-old file.)
        self.tmp = tempfile.TemporaryDirectory(dir=_scratch_root())
        self.now = 1_000_000_000.0

    def tearDown(self):
        self.tmp.cleanup()

    def _mk(self, name, age_days, size=16):
        p = os.path.join(self.tmp.name, name)
        Path(p).write_text("x" * size)
        t = self.now - age_days * DAY
        os.utime(p, (t, t))
        return p

    def _plan_with(self, rule):
        original = R.RULES
        R.RULES = [rule]
        try:
            return R.plan(self.now, _NO_HOLDERS)
        finally:
            R.RULES = original

    def test_too_young_is_not_swept(self):
        self._mk("a.db.bak-1", age_days=3)
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14)
        self.assertEqual(self._plan_with(rule), [])

    def test_old_enough_is_swept(self):
        self._mk("a.db.bak-1", age_days=40)
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14)
        got = self._plan_with(rule)
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0]["path"].endswith("a.db.bak-1"))

    def test_keep_newest_preserves_the_most_recent(self):
        self._mk("old.db.bak-1", age_days=90)
        self._mk("new.db.bak-2", age_days=40)
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14, keep_newest=1)
        got = self._plan_with(rule)
        self.assertEqual([os.path.basename(g["path"]) for g in got], ["old.db.bak-1"])

    def test_keep_newest_can_preserve_everything(self):
        self._mk("a.db.bak-1", age_days=90)
        self._mk("b.db.bak-2", age_days=90)
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14, keep_newest=5)
        self.assertEqual(self._plan_with(rule), [])

    def test_unmatched_path_is_invisible(self):
        """Closed rule set: a file no rule names can never be discovered."""
        self._mk("precious-database.db", age_days=999)
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14)
        self.assertEqual(self._plan_with(rule), [])

    def test_dirs_only_rule_skips_sibling_files(self):
        """The pins.json regression: the first live run of this script proposed
        deleting ~/.claude/jobs/pins.json — real pinned-job state — because a
        `<dir>/*` glob matches sibling FILES as well as job directories."""
        self._mk("pins.json", age_days=90)
        d = os.path.join(self.tmp.name, "5576b6d3")
        os.makedirs(d)
        t = self.now - 90 * DAY
        os.utime(d, (t, t))
        rule = R.Rule("t", f"{self.tmp.name}/*", min_age_days=30, dirs_only=True)
        got = [os.path.basename(g["path"]) for g in self._plan_with(rule)]
        self.assertEqual(got, ["5576b6d3"])
        self.assertNotIn("pins.json", got)

    def test_without_dirs_only_the_sibling_file_is_caught(self):
        """Proves the flag is what protects it, not some incidental filter."""
        self._mk("pins.json", age_days=90)
        rule = R.Rule("t", f"{self.tmp.name}/*", min_age_days=30)
        got = [os.path.basename(g["path"]) for g in self._plan_with(rule)]
        self.assertIn("pins.json", got)

    def test_keep_newest_is_never_spent_on_a_copy_that_cannot_be_restored(self):
        """2026-07-17 to 09-05: the two newest entries of ccflare's backups/ were
        a failed .partial pair, and the newest real snapshot was older."""
        self._mk("good.db", age_days=90)
        self._mk("retry.db.partial", age_days=40)
        self._mk("retry.db-journal", age_days=30)
        rule = R.Rule("t", f"{self.tmp.name}/*", min_age_days=14, keep_newest=1)
        got = sorted(os.path.basename(g["path"]) for g in self._plan_with(rule))
        self.assertEqual(got, ["retry.db-journal", "retry.db.partial"])

    def test_a_path_two_rules_match_is_planned_once(self):
        """Planned twice, its second removal fails on a file already gone, and
        a failure exits 1 and pages."""
        self._mk("a.db.backup-1", age_days=90)
        original = R.RULES
        R.RULES = [R.Rule("first", f"{self.tmp.name}/*.db.backup*", min_age_days=14),
                   R.Rule("second", f"{self.tmp.name}/*", min_age_days=14)]
        try:
            got = R.plan(self.now, _NO_HOLDERS)
        finally:
            R.RULES = original
        self.assertEqual([(g["rule"], os.path.basename(g["path"])) for g in got],
                         [("first", "a.db.backup-1")])

    def _plan_citing(self, rule, text):
        notes = os.path.join(self.tmp.name, "projects", "-home-user-dotfiles", "memory")
        os.makedirs(notes, exist_ok=True)
        Path(notes, "keep.md").write_text(text)
        original = R.MEMORY_ROOT
        R.MEMORY_ROOT = os.path.join(self.tmp.name, "projects")
        try:
            return self._plan_with(rule)
        finally:
            R.MEMORY_ROOT = original

    def test_a_residue_path_a_memory_note_names_is_skipped(self):
        self._mk("a.db.bak-1", age_days=40)
        self._mk("b.db.bak-2", age_days=40)
        home_form = "~" + self.tmp.name[len(R.HOME):]
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14)
        got = self._plan_citing(rule, f"Keep `{home_form}/a.db.bak-1` until #9 closes.\n")
        self.assertEqual({os.path.basename(g["path"]): g["skip"] for g in got},
                         {"a.db.bak-1": "cited by a memory note", "b.db.bak-2": None})

    def test_a_note_naming_a_file_inside_a_residue_dir_keeps_the_dir(self):
        d = os.path.join(self.tmp.name, "pre-cancel-history-550-d46jep72")
        os.makedirs(d)
        Path(d, "snapshot.sqlite3").write_text("x")
        t = self.now - 40 * DAY
        os.utime(d, (t, t))
        rule = R.Rule("t", f"{self.tmp.name}/*", min_age_days=14)
        got = self._plan_citing(rule, f"Restore from {d}/snapshot.sqlite3 if counts drift.\n")
        self.assertEqual([g["skip"] for g in got if g["path"] == d], ["cited by a memory note"])

    def test_a_note_naming_only_the_rule_directory_keeps_nothing(self):
        self._mk("a.db.bak-1", age_days=40)
        rule = R.Rule("t", f"{self.tmp.name}/*.bak-*", min_age_days=14)
        got = self._plan_citing(rule, f"Snapshots live in {self.tmp.name}/ now.\n")
        self.assertEqual([g["skip"] for g in got], [None])

    def test_apply_removes_a_residue_dir_holding_a_read_only_tree(self):
        """Go leaves its module cache read-only (0555 dirs). Job 2b5a4195 held one
        in its tmp on 2026-10-30, and a plain rmtree under the claude-job-dir
        rule would fail on it every hour once the job turned 30 days old."""
        if os.geteuid() == 0:
            self.skipTest("root writes through mode 0555")
        job = os.path.join(self.tmp.name, "jobs", "2b5a4195")
        ro = os.path.join(job, "tmp", "modcache", "golang.org", "x", "text@v0.31.0")
        os.makedirs(ro)
        Path(ro, "go.mod").write_text("module golang.org/x/text\n")
        os.chmod(os.path.join(ro, "go.mod"), 0o444)
        os.chmod(ro, 0o555)
        t = self.now - 40 * DAY
        os.utime(job, (t, t))
        original = R.RULES
        R.RULES = [R.Rule("jobs", f"{self.tmp.name}/jobs/*", min_age_days=30, dirs_only=True)]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = R.main(["--apply", "--json", "--free-gb", "500", "--now", str(self.now)])
        finally:
            R.RULES = original
        doc = json.loads(out.getvalue())
        self.assertEqual((doc["failed"], doc["removed"], rc), ([], [job], 0))
        self.assertFalse(os.path.exists(job))


def _sqlite_db(path, rows=1):
    """A real, complete SQLite database file at path."""
    con = sqlite3.connect(path)
    try:
        con.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT)")
        con.executemany("INSERT INTO accounts (name) VALUES (?)", [("a" * 200,)] * rows)
        con.commit()
    finally:
        con.close()
    return path


class DbCopyPoolTests(unittest.TestCase):
    """One keep over every copy of a database, spent only on a whole copy."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=_scratch_root())
        self.d = self.tmp.name
        self.now = 1_000_000_000.0
        self.live = _sqlite_db(os.path.join(self.d, "app.db"))
        os.makedirs(os.path.join(self.d, "backups"))

    def tearDown(self):
        self.tmp.cleanup()

    def _age(self, path, days):
        t = self.now - days * DAY
        os.utime(path, (t, t))
        return path

    def _db(self, rel, days):
        return self._age(_sqlite_db(os.path.join(self.d, rel)), days)

    def _dir(self, rel, days, files):
        p = os.path.join(self.d, rel)
        os.makedirs(p)
        for name, make in files.items():
            make(os.path.join(p, name))
        return self._age(p, days)

    def _rule(self):
        return R.Rule("pool", (f"{self.d}/*.db.backup*", f"{self.d}/backups/*"),
                      min_age_days=14, keep_newest=1,
                      restorable=R.sqlite_copy_of(self.live))

    def _planned(self):
        original = R.RULES
        R.RULES = [self._rule()]
        try:
            return {os.path.relpath(g["path"], self.d): g["age_days"]
                    for g in R.plan(self.now, _NO_HOLDERS)}
        finally:
            R.RULES = original

    def test_one_keep_spans_every_glob(self):
        """10-25: four 1-5 GB copies of ccflare's DB under four names, each its
        own rule's newest. One pool keeps one."""
        self._db("app.db.backup.1787781424330", 60)
        self._db("app.db.backup-pre541", 40)
        self._dir("backups/pre-cancel-a", 30, {"snapshot.sqlite3": _sqlite_db})
        self._dir("backups/pre-cancel-b", 20, {"snapshot.sqlite3": _sqlite_db})
        self.assertEqual(sorted(self._planned()), [
            "app.db.backup-pre541", "app.db.backup.1787781424330", "backups/pre-cancel-a"])

    def test_the_keep_skips_a_newer_entry_that_holds_no_database(self):
        """10-19: a 24 KB scripts dir landed in backups/ five minutes before the
        last DB snapshot; five minutes later and it would have taken the keep."""
        self._dir("backups/pre-cancel-b", 20, {"snapshot.sqlite3": _sqlite_db})
        self._dir("backups/pre-deploy-local-files", 19,
                  {"SHA256SUMS": lambda p: Path(p).write_text("abc  x\n")})
        self.assertEqual(sorted(self._planned()), ["backups/pre-deploy-local-files"])

    def test_a_truncated_copy_never_takes_the_keep(self):
        good = self._db("app.db.backup.1", 40)
        bad = _sqlite_db(os.path.join(self.d, "app.db.backup.2"), rows=400)
        with open(bad, "r+b") as fh:
            fh.truncate(os.path.getsize(bad) // 2)
        self._age(bad, 20)
        self.assertEqual(R._whole_sqlite(good, None), True)
        self.assertEqual(R._whole_sqlite(bad, None), False)
        self.assertEqual(sorted(self._planned()), ["app.db.backup.2"])

    def test_a_file_that_only_starts_like_sqlite_never_takes_the_keep(self):
        self._db("app.db.backup.1", 40)
        fake = os.path.join(self.d, "app.db.backup.2")
        Path(fake).write_bytes(R.SQLITE_MAGIC + b"\0" * 84)
        self._age(fake, 20)
        self.assertEqual(sorted(self._planned()), ["app.db.backup.2"])

    def test_a_file_without_the_sqlite_magic_never_takes_the_keep(self):
        self._db("app.db.backup.1", 40)
        other = _sqlite_db(os.path.join(self.d, "app.db.backup.2"))
        with open(other, "r+b") as fh:
            fh.write(b"\0" * 16)
        self._age(other, 20)
        self.assertEqual(sorted(self._planned()), ["app.db.backup.2"])

    def test_a_stale_header_count_falls_back_to_whole_pages(self):
        """The in-header page count is only valid while the change counter
        matches version-valid-for; an older writer leaves it stale."""
        self._db("app.db.backup.1", 40)
        p = _sqlite_db(os.path.join(self.d, "app.db.backup.2"))
        with open(p, "r+b") as fh:
            h = bytearray(fh.read(100))
            h[28:32] = (10 ** 6).to_bytes(4, "big")
            h[92:96] = (int.from_bytes(h[24:28], "big") + 1).to_bytes(4, "big")
            fh.seek(0)
            fh.write(h)
        self._age(p, 20)
        self.assertTrue(R._whole_sqlite(p, None))
        self.assertEqual(sorted(self._planned()), ["app.db.backup.1"])

    def test_a_hardlink_to_the_live_db_is_not_a_copy_of_it(self):
        """Unlinking the name loses nothing; keeping it as the copy would lose
        the only real one."""
        self._db("app.db.backup.1", 40)
        link = os.path.join(self.d, "app.db.backup.2")
        os.link(self.live, link)
        self._age(link, 20)
        self.assertFalse(R.sqlite_copy_of(self.live)(link))
        self.assertEqual(sorted(self._planned()), ["app.db.backup.2"])

    def test_the_copy_a_newer_one_replaces_stays_its_floor_from_then(self):
        """A copy older than the floor is still the fallback for a fresh one's
        first days: its floor runs from when the newer copy appeared."""
        self._db("app.db.backup.1", 60)
        self._db("app.db.backup.2", 3)
        self.assertEqual(self._planned(), {})
        self.now += 12 * DAY
        self.assertEqual(self._planned(), {"app.db.backup.1": 15.0})

    def test_with_no_whole_copy_the_rest_go_on_their_own_floors(self):
        """A copy that never finished is no fallback, so it never holds the keep."""
        p = os.path.join(self.d, "app.db.backup.9.partial")
        Path(p).write_bytes(b"x" * 64)
        self._age(p, 20)
        self._dir("backups/notes", 10, {"README": lambda q: Path(q).write_text("x")})
        self.assertEqual(sorted(self._planned()), ["app.db.backup.9.partial"])

    def test_the_kept_copys_sidecars_stay_with_it(self):
        """A copy taken with its -wal holds committed pages only that file has."""
        self._db("app.db.backup.1", 40)
        for s in ("-wal", "-shm"):
            p = os.path.join(self.d, "app.db.backup.1" + s)
            Path(p).write_bytes(b"")
            self._age(p, 40)
        self.assertEqual(self._planned(), {})

    def test_a_copy_symlinked_in_is_not_followed(self):
        target = _sqlite_db(os.path.join(self.d, "elsewhere.sqlite3"))
        d = os.path.join(self.d, "backups", "linked")
        os.makedirs(d)
        os.symlink(target, os.path.join(d, "snapshot.sqlite3"))
        self.assertFalse(R.sqlite_copy_of(self.live)(d))
        real = self._dir("elsewhere", 0, {"snapshot.sqlite3": _sqlite_db})
        os.symlink(real, os.path.join(self.d, "backups", "linked-dir"))
        self.assertFalse(R.sqlite_copy_of(self.live)(os.path.join(self.d, "backups", "linked-dir")))

    def test_a_copy_its_owner_prunes_first_is_not_a_failure(self):
        """migrations.ts prunes its own `.backup.<ms>` after it writes one; if it
        gets there first the sweep's removal finds nothing, which is no fault."""
        self._db("app.db.backup.1", 60)
        gone = self._db("app.db.backup.2", 40)
        self._db("app.db.backup.3", 20)
        original_rules, original_remove = R.RULES, R.os.remove
        R.RULES = [self._rule()]

        def owner_first(path):
            if path == gone:
                original_remove(path)
            original_remove(path)
        R.os.remove = owner_first
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = R.main(["--apply", "--json", "--free-gb", "500", "--now", str(self.now)])
        finally:
            R.RULES, R.os.remove = original_rules, original_remove
        doc = json.loads(out.getvalue())
        self.assertEqual(rc, 0)
        self.assertEqual(doc["failed"], [])
        self.assertEqual(doc["removed"], [os.path.join(self.d, "app.db.backup.1")])
        self.assertFalse(os.path.exists(gone))
        self.assertTrue(os.path.exists(os.path.join(self.d, "app.db.backup.3")))


class DryRunContractTests(unittest.TestCase):
    def test_default_run_removes_nothing(self):
        with tempfile.TemporaryDirectory(dir=_scratch_root()) as d:
            p = os.path.join(d, "victim.db.bak-1")
            Path(p).write_text("x")
            t = time.time() - 90 * DAY
            os.utime(p, (t, t))
            original = R.RULES
            R.RULES = [R.Rule("t", f"{d}/*.bak-*", min_age_days=14)]
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    R.main(["--json"])
            finally:
                R.RULES = original
            self.assertTrue(os.path.exists(p), "DRY RUN must not delete")

    def test_emits_the_harness_weekly_counter(self):
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            R.main([])
        self.assertIn("reclaim-flagged:", buf.getvalue())

    def test_answerless_liveness_scan_refuses_even_apply(self):
        """Fail closed (issue #378): if liveness is unknowable, neither plan nor
        apply may proceed — 'saw nothing' must never read as 'nothing is held'."""
        with tempfile.TemporaryDirectory(dir=_scratch_root()) as d:
            p = os.path.join(d, "victim.db.bak-1")
            Path(p).write_text("x")
            t = time.time() - 90 * DAY
            os.utime(p, (t, t))
            original_rules, original_snap = R.RULES, R.proc_liveness.ProcSnapshot
            R.RULES = [R.Rule("t", f"{d}/*.bak-*", min_age_days=14)]
            R.proc_liveness.ProcSnapshot = lambda *a, **k: _DeadSnapshot()
            try:
                with contextlib.redirect_stderr(io.StringIO()) as err:
                    rc = R.main(["--apply"])
            finally:
                R.RULES, R.proc_liveness.ProcSnapshot = original_rules, original_snap
            self.assertEqual(rc, 1)
            self.assertIn("refusing", err.getvalue())
            self.assertTrue(os.path.exists(p), "refusal must remove nothing")


class RealRuleSanityTests(unittest.TestCase):
    """The shipped rules must be well-formed and none may target a bare directory."""

    def test_every_rule_is_deep_enough_to_be_safe(self):
        for rule in R.RULES:
            for pattern in rule.patterns:
                self.assertTrue(
                    R.is_safe_target(pattern.replace("*", "x")),
                    f"rule {rule.name} could resolve to an unsafe depth: {pattern}",
                )

    # Named exceptions to the 14-day floor, each an operator call recorded at the rule.
    SHORT_FLOORS = {"ccflare-codex-trace": 7}

    def test_every_rule_has_an_age_floor(self):
        for rule in R.RULES:
            floor = self.SHORT_FLOORS.get(rule.name, 14)
            self.assertGreaterEqual(rule.min_age_days, floor, f"{rule.name} age floor too low")

    def test_the_ccflare_rules_never_reach_live_state(self):
        """The rules beside ccflare's live DB, named from its directory on
        2026-10-25. The app's own `.backup.<ms>` copies joined the DB-copy pool
        on 10-25: migrations.ts prunes them to 3 only when it writes another,
        and nothing reads them back."""
        ccf = f"{R.HOME}/.config/better-ccflare"
        live = ["better-ccflare.db", "better-ccflare.db-wal", "better-ccflare.db-shm",
                "better-ccflare.db-journal", "better-ccflare.json",
                "better-ccflare-v3.7.0-79a95752-5e16ca57", "runners", "guards", "backups",
                "codex-traces", "stack-supervisor.log"]
        copies = ["better-ccflare.db.backup-pre541-20261019-012755",
                  "better-ccflare.db.backup.1789092886052",
                  "better-ccflare.db.backup.1789089943418.partial",
                  "better-ccflare.db.backup.1789089943418.partial-journal",
                  "better-ccflare.db.bak-20260801",
                  "pre-v3-backup-20260801.db",
                  "backups/pre-native-quota-20260906T002330Z-c1fc60cd.db",
                  "backups/predeploy-10a40371-20260717T0737Z.db.partial",
                  "backups/pre-cancel-history-550-d46jep72"]

        def ruled(name):
            path = f"{ccf}/{name}"
            # fnmatch's * crosses "/", glob's doesn't: only a direct child of the root counts.
            return {r.name for r in R.RULES for p in r.patterns
                    if fnmatch.fnmatchcase(path, p)
                    and "/" not in path[len(R._rule_root(p)) + 1:]}

        for name in live:
            self.assertEqual(ruled(name), set(), f"{name} is live state")
        for name in copies:
            self.assertEqual(ruled(name), {"ccflare-db-copy"}, f"{name} is a DB copy")

    def test_the_ccflare_pool_keeps_a_copy_of_the_live_db(self):
        """The one keep is spent on a whole copy of the DB the app runs on."""
        (rule,) = [r for r in R.RULES if r.name == "ccflare-db-copy"]
        self.assertEqual((rule.keep_newest, rule.min_age_days), (1, 14))
        self.assertIsNotNone(rule.restorable)

    def test_every_rule_explains_itself(self):
        for rule in R.RULES:
            self.assertTrue(rule.why, f"{rule.name} has no rationale")

    def test_rule_names_are_unique(self):
        names = [r.name for r in R.RULES]
        self.assertEqual(len(names), len(set(names)))


class _FixtureTree(unittest.TestCase):
    """A per-test scratch area under $HOME, with chmod restored before cleanup."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=_scratch_root())
        self.root = os.path.join(self.tmp.name, "tmp")
        self.jobs = os.path.join(self.tmp.name, "jobs")
        os.makedirs(self.root)
        os.makedirs(self.jobs)
        self.child = None

    def tearDown(self):
        if self.child is not None:
            self.child.kill()
            self.child.wait()
        for root, dirs, _ in os.walk(self.tmp.name):
            for x in dirs:
                p = os.path.join(root, x)
                if not os.path.islink(p):
                    os.chmod(p, 0o700)
        self.tmp.cleanup()


class PressureTests(unittest.TestCase):
    """Floors shrink as free space on / falls; every boundary is pinned."""

    def test_levels_at_each_boundary(self):
        cases = [(0, "critical"), (39.9, "critical"), (40, "high"), (74.9, "high"),
                 (75, "low"), (149.9, "low"), (150, "normal"), (900, "normal")]
        for gb, level in cases:
            self.assertEqual(R.pressure(int(gb * GB))[0], level, f"{gb} GB free")

    def test_more_pressure_never_lengthens_a_floor(self):
        floors = [R.pressure(int(gb * GB))[1:] for gb in (900, 100, 50, 10)]
        for looser, tighter in zip(floors, floors[1:]):
            self.assertLess(tighter[0], looser[0])
            self.assertLess(tighter[1], looser[1])

    def test_floors_never_drop_below_the_measured_minimums(self):
        """6h job floor: a done job was resumed 76 minutes later (2b5a4195,
        2026-10-25). 24h /tmp floor: going lower bought ~14 GiB of du."""
        _, job_h, tmp_h = R.pressure(0)
        self.assertGreaterEqual(job_h, 6)
        self.assertGreaterEqual(tmp_h, 24)


class TreeScanTests(_FixtureTree):
    """The idle predicate: what counts as a write, and what makes a tree untouchable."""

    def setUp(self):
        super().setUp()
        self.d = os.path.join(self.root, "tree")
        os.makedirs(os.path.join(self.d, "sub"))
        Path(self.d, "sub", "f.txt").write_text("x" * 5000)

    def _mark(self):
        """A timestamp strictly between everything so far and anything next."""
        time.sleep(0.05)
        mark = time.time()
        time.sleep(0.05)
        return mark

    def test_old_mtime_with_recent_ctime_is_not_idle(self):
        """Planted negative (#2002): npm/tar extraction restores ancient mtimes,
        and only the inode change time records that the tree was written today."""
        for root, dirs, files in os.walk(self.d, topdown=False):
            for x in files + dirs:
                _age(os.path.join(root, x), 400 * DAY)
        _age(self.d, 400 * DAY)
        scan = R.scan_tree(self.d, cutoff=time.time() - HOUR)
        self.assertFalse(scan.complete)
        self.assertIsNone(scan.veto)

    def test_a_tree_older_than_the_cutoff_is_idle_and_measured(self):
        scan = R.scan_tree(self.d, cutoff=time.time() + 60)
        self.assertTrue(scan.complete)
        self.assertIsNone(scan.veto)
        self.assertGreaterEqual(scan.apparent, 5000)
        self.assertEqual(scan.unshared, scan.apparent)

    def test_a_multi_link_files_ctime_is_not_a_write(self):
        """2026-10-25: 196,278 files in a finished job's tmp had minutes-old
        ctimes, every one nlink>1 — linking that inode anywhere else moves it."""
        f = os.path.join(self.d, "sub", "f.txt")
        mark = self._mark()
        os.link(f, os.path.join(self.tmp.name, "elsewhere"))
        self.assertGreater(os.lstat(f).st_ctime, mark, "fixture: the link moved ctime")
        scan = R.scan_tree(self.d, cutoff=mark)
        self.assertTrue(scan.complete, f"newest={scan.newest} mark={mark}")
        self.assertEqual(scan.unshared, 0, "a file with another link frees nothing")

    def _needs_birth_time(self):
        if R._birth_time(self.d, os.lstat(self.d).st_ino) is None:
            self.skipTest("this filesystem reports no birth time")

    def test_birth_time_is_creation_and_survives_restored_times(self):
        """struct statx is read by hand; a wrong offset would turn every ctime
        into garbage, so pin the value and the inode check."""
        before = time.time() - 1
        f = os.path.join(self.d, "born.txt")
        Path(f).write_text("x")
        ino = os.lstat(f).st_ino
        born = R._birth_time(f, ino)
        if born is None:
            self.skipTest("this filesystem reports no birth time")
        self.assertLessEqual(before, born)
        self.assertLessEqual(born, time.time() + 1)
        _age(f, 400 * DAY)
        self.assertEqual(R._birth_time(f, ino), born)
        self.assertIsNone(R._birth_time(f, ino + 1), "another inode at the path is not this one")
        self.assertIsNone(R._birth_time(os.path.join(self.d, "gone"), ino))

    def test_an_extraction_below_the_top_with_ancient_mtimes_is_not_idle(self):
        """Planted negative (#2002, #2033): with the top entry untouched, only
        the extracted inodes' birth times say the tree was written today."""
        mark = self._mark()
        pkg = os.path.join(self.d, "sub", "pkg")
        os.makedirs(os.path.join(pkg, "lib"))
        Path(pkg, "lib", "index.js").write_text("x")
        for p in (os.path.join(pkg, "lib", "index.js"), os.path.join(pkg, "lib"), pkg,
                  os.path.join(self.d, "sub")):
            _age(p, 400 * DAY)
        self.assertLess(os.lstat(self.d).st_ctime, mark, "fixture: the top entry is untouched")
        scan = R.scan_tree(self.d, cutoff=mark)
        self.assertFalse(scan.complete)
        self.assertIsNone(scan.veto)

    def test_a_tree_renamed_into_scratch_is_not_idle(self):
        """Planted negative: a whole old tree moved in shows its arrival only in
        the top entry's ctime, which keeps counting."""
        src = os.path.join(self.tmp.name, "elsewhere-tree")
        os.makedirs(os.path.join(src, "sub"))
        Path(src, "sub", "f.txt").write_text("x")
        for p in (os.path.join(src, "sub", "f.txt"), os.path.join(src, "sub"), src):
            _age(p, 400 * DAY)
        mark = self._mark()
        dst = os.path.join(self.root, "moved-in")
        os.rename(src, dst)
        self.assertFalse(R.scan_tree(dst, cutoff=mark).complete)

    def test_a_directorys_restored_times_are_not_a_write(self):
        """#2033: systemd-tmpfiles deletes aged files, then puts the directory's
        times back; that moves its ctime and nothing else."""
        self._needs_birth_time()
        sub = os.path.join(self.d, "sub")
        Path(sub, "aged.txt").write_text("x")
        _age(sub, 400 * DAY)
        was = os.lstat(sub)
        mark = self._mark()
        os.unlink(os.path.join(sub, "aged.txt"))
        os.utime(sub, ns=(was.st_atime_ns, was.st_mtime_ns))
        self.assertGreater(os.lstat(sub).st_ctime, mark, "fixture: the restore moved ctime")
        scan = R.scan_tree(self.d, cutoff=mark)
        self.assertTrue(scan.complete, f"newest={scan.newest} mark={mark}")

    def test_a_dropped_link_or_a_chmod_is_not_a_write(self):
        """#2033: deleting a file's other link leaves it single-link with a new
        ctime (13,196 entries of a tree last written 09-26 had 10-25 and 10-26
        ones); a chmod moves ctime the same way. Neither writes the file."""
        self._needs_birth_time()
        f = os.path.join(self.d, "sub", "f.txt")
        g = os.path.join(self.d, "sub", "g.txt")
        Path(g).write_text("y")
        other = os.path.join(self.tmp.name, "other-link")
        os.link(f, other)
        mark = self._mark()
        os.unlink(other)
        os.chmod(g, 0o600)
        self.assertEqual(os.lstat(f).st_nlink, 1)
        self.assertGreater(os.lstat(f).st_ctime, mark, "fixture: the unlink moved ctime")
        self.assertGreater(os.lstat(g).st_ctime, mark, "fixture: the chmod moved ctime")
        scan = R.scan_tree(self.d, cutoff=mark)
        self.assertTrue(scan.complete, f"newest={scan.newest} mark={mark}")

    def test_without_a_birth_time_a_single_link_files_ctime_still_counts(self):
        """Where the filesystem cannot say when an inode was born, ctime is the
        only sign of an extraction, so it counts as before #2033."""
        mark = self._mark()
        os.chmod(os.path.join(self.d, "sub", "f.txt"), 0o600)
        with _patched(_birth_time=lambda path, ino: None):
            self.assertFalse(R.scan_tree(self.d, cutoff=mark).complete)

    def test_a_git_repository_is_reported_not_vetoed(self):
        """#2003: git says whether a repository's work lives elsewhere; the walk
        only finds the repositories, a .git file (a worktree) as one too."""
        Path(self.d, "sub", ".git").write_text("gitdir: /x/.git/worktrees/x\n")
        clone = os.path.join(self.d, "clone")
        _git("init", "-q", clone)
        scan = R.scan_tree(self.d, cutoff=time.time() + 60)
        self.assertIsNone(scan.veto)
        self.assertTrue(scan.complete)
        self.assertEqual(scan.repos, (("dir", clone), ("file", os.path.join(self.d, "sub"))))

    def test_a_uv_marker_is_not_a_repository_and_a_git_dir_git_cannot_open_is_named(self):
        """uv marks its cache dirs with an empty .git file (5 of 120 .git files
        on 2026-10-25). systemd-tmpfiles took HEAD from 35 .git dirs (12.2 GB)
        that text searches kept the rest of alive, and a test fixture's .git
        held a HEAD alone; git opens neither (is_git_directory wants HEAD,
        objects/ and refs/, or a commondir naming where those are)."""
        Path(self.d, "sub", ".git").write_bytes(b"")
        repos = {}
        for name in ("whole", "no-head", "no-refs", "head-only", "common"):
            repos[name] = os.path.join(self.d, name)
            if name in ("head-only", "common"):
                os.makedirs(os.path.join(repos[name], ".git"))
                Path(repos[name], ".git", "HEAD").write_text("ref: refs/heads/main\n")
            else:
                _git("init", "-q", repos[name])
        os.unlink(os.path.join(repos["no-head"], ".git", "HEAD"))
        shutil.rmtree(os.path.join(repos["no-refs"], ".git", "refs"))
        Path(repos["common"], ".git", "commondir").write_text("../../whole/.git\n")
        scan = R.scan_tree(self.d, cutoff=time.time() + 60)
        self.assertTrue(scan.complete)
        self.assertEqual(sorted(scan.repos), sorted([
            ("dir", repos["whole"]), ("dir", repos["common"]), ("unopenable", repos["no-head"]),
            ("unopenable", repos["no-refs"]), ("unopenable", repos["head-only"])]))

    def test_a_bare_repository_and_a_submodules_git_dir_are_reported(self):
        """/tmp/push-tracking-origin-Q2JKQG (2026-10-25) is a bare remote other
        clones push to; it has no .git entry, only HEAD, objects/ and refs/. A
        submodule's git dir (.git/modules/<name>) has the same shape, and once
        the submodule is deinitialised it is the only copy of its commits."""
        bare = os.path.join(self.d, "sub", "origin.git")
        clone = os.path.join(self.d, "clone")
        _git("init", "-q", "--bare", bare)
        _git("init", "-q", "--bare", os.path.join(bare, "modules", "m"))
        _git("init", "-q", clone)
        _git("init", "-q", "--bare", os.path.join(clone, ".git", "modules", "m", "modules", "n"))
        _git("init", "-q", "--bare", os.path.join(clone, ".git", "modules", "m"))
        scan = R.scan_tree(self.d, cutoff=time.time() + 60)
        self.assertTrue(scan.complete)
        self.assertEqual(sorted(scan.repos), [
            ("bare", bare), ("dir", clone),
            ("module", os.path.join(clone, ".git", "modules", "m")),
            ("module", os.path.join(clone, ".git", "modules", "m", "modules", "n")),
            ("module", os.path.join(bare, "modules", "m"))])

    def test_a_write_inside_git_is_a_write(self):
        """A commit or a fetch touches only .git; the walk must see it."""
        clone = os.path.join(self.d, "clone")
        _git("init", "-q", clone)
        mark = self._mark()
        Path(clone, ".git", "refs", "heads", "new").write_text("0" * 40 + "\n")
        self.assertFalse(R.scan_tree(self.d, cutoff=mark).complete)

    def test_a_walk_leaves_directory_atime_alone(self):
        """systemd-tmpfiles ages a directory by its atime, and a readdir moves it
        once a day under relatime: an hourly walk would keep every dir it hands
        to tmpfiles alive forever."""
        old = time.time() - 10 * DAY
        for p in (os.path.join(self.d, "sub"), self.d):
            os.utime(p, (old, old))
        R.scan_tree(self.d, cutoff=time.time() + 60)
        for p in (self.d, os.path.join(self.d, "sub")):
            self.assertAlmostEqual(os.lstat(p).st_atime, old, delta=1, msg=p)

    def test_a_socket_vetoes(self):
        s = socket.socket(socket.AF_UNIX)
        try:
            s.bind(os.path.join(self.d, "sub", "s.sock"))
            scan = R.scan_tree(self.d, cutoff=time.time() + 60)
        finally:
            s.close()
        self.assertIn("socket", scan.veto)

    def test_symlinks_are_not_followed(self):
        os.symlink("/", os.path.join(self.d, "sub", "to-root"))
        scan = R.scan_tree(self.d, cutoff=time.time() + 60)
        self.assertTrue(scan.complete)
        self.assertLess(scan.apparent, 1024 * 1024)

    def test_an_unreadable_subtree_vetoes(self):
        if os.geteuid() == 0:
            self.skipTest("root reads through mode 0")
        locked = os.path.join(self.d, "sub", "locked")
        os.makedirs(locked)
        os.chmod(locked, 0)
        self.assertIn("unreadable", R.scan_tree(self.d, cutoff=time.time() + 60).veto)

    def test_a_directory_of_another_user_we_cannot_write_vetoes(self):
        """/tmp/tmp.kCnF9EYpYY held a root-owned copy of /etc/systemd/system. The
        first live run (2026-10-25) removed part of it, failed on the rest and
        paged, and would have every hour after. A test can't chown, so it poses
        as another user instead."""
        if os.geteuid() == 0:
            self.skipTest("root writes through mode 0555")
        os.chmod(os.path.join(self.d, "sub"), 0o555)
        other = os.getuid() + 1
        self.assertIn("cannot empty", R.scan_tree(self.d, time.time() + 60, uid=other).veto)
        self.assertIsNone(R.scan_tree(self.d, time.time() + 60).veto,
                          "a read-only dir of ours: removal grants itself write")

    def test_a_sticky_directory_of_another_user_vetoes(self):
        os.chmod(os.path.join(self.d, "sub"), 0o1777)
        other = os.getuid() + 1
        self.assertIn("cannot empty", R.scan_tree(self.d, time.time() + 60, uid=other).veto)
        self.assertIsNone(R.scan_tree(self.d, time.time() + 60).veto)

    def test_a_directory_of_another_user_is_judged_without_reading_it(self):
        """A readdir of a directory not ours can't use O_NOATIME, so listing it
        hourly would refresh its atime daily, and systemd-tmpfiles would never
        age the kept tree out. So even an empty one vetoes unread."""
        if os.geteuid() == 0:
            self.skipTest("root writes through mode 0555")
        sub = os.path.join(self.d, "sub")
        os.remove(os.path.join(sub, "f.txt"))
        os.chmod(sub, 0o555)
        listed, real = [], R._entries
        R._entries = lambda p: listed.append(p) or real(p)
        try:
            veto = R.scan_tree(self.d, time.time() + 60, uid=os.getuid() + 1).veto
        finally:
            R._entries = real
        self.assertIn("cannot empty", veto)
        self.assertEqual(listed, [self.d], "only the directory of ours was read")


class TmpScratchTests(_FixtureTree):
    """Direct children of a scratch root: what is reclaimed, and every refusal."""

    FAR = 30 * DAY  # plan this far ahead and everything in a fixture is idle

    def _entry(self, name, files=("a.bin",)):
        d = os.path.join(self.root, name)
        os.makedirs(d)
        for f in files:
            Path(d, f).write_text("x" * 4096)
        return d

    def _plan(self, snap=_NO_HOLDERS, ahead=FAR, tmp_floor_h=168, **kw):
        with _roots([self.root], self.jobs):
            return R.plan_scratch(time.time() + ahead, snap, 72, tmp_floor_h, **kw)

    @staticmethod
    def _names(plan):
        return sorted(os.path.basename(i["path"]) for i in plan.items)

    def test_an_idle_unheld_entry_is_a_candidate(self):
        self._entry("capacity-local-build-07")
        Path(self.root, "frames.raw").write_text("x" * 4096)
        plan = self._plan()
        self.assertEqual(self._names(plan), ["capacity-local-build-07", "frames.raw"])
        self.assertEqual({i["rule"] for i in plan.items}, {"tmp-scratch"})

    def test_a_fresh_entry_is_kept(self):
        self._entry("still-writing")
        plan = self._plan(ahead=0, tmp_floor_h=24)
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("fresh"), 1)

    def test_hidden_symlinked_and_daemon_entries_are_kept(self):
        uid = os.getuid()
        for name in (".X11-unix", f"cc-daemon-{uid}", f"tmux-{uid}", f"claude-{uid}"):
            self._entry(name)
        os.symlink(self.tmp.name, os.path.join(self.root, "ccfs-link"))
        plan = self._plan()
        self.assertEqual(plan.items, [])
        self.assertEqual((plan.kept.get("hidden"), plan.kept.get("daemon or system dir"),
                          plan.kept.get("symlink")), (1, 3, 1))

    def test_another_owners_entry_is_kept(self):
        self._entry("someone-elses")
        plan = self._plan(uid=os.getuid() + 1)
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("not ours"), 1)

    def test_a_held_entry_is_kept_against_the_real_proc(self):
        d = self._entry("live-server")
        self.child = subprocess.Popen(["sleep", "30"], cwd=d)
        time.sleep(0.2)
        plan = self._plan(snap=R.proc_liveness.ProcSnapshot(exclude_pids=frozenset()))
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("held"), 1)

    def test_a_registered_git_worktree_is_kept(self):
        """Planted negative (#2002): inside the git horizon a worktree in /tmp
        must not be rm -rf'd out from under its repo's worktree list (44 sat in
        scratch on 2026-10-25)."""
        repo = os.path.join(self.tmp.name, "repo")
        git = ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main",
               "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]
        subprocess.run(git + ["init", "-q", repo], check=True)
        subprocess.run(git + ["-C", repo, "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        subprocess.run(git + ["-C", repo, "worktree", "add", "-q", "-b", "wt",
                              os.path.join(self.root, "wt")], check=True)
        plan = self._plan(ahead=10 * DAY)
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("git: a worktree of a repository outside it"), 1, plan.kept)

    def test_a_registered_git_worktree_idle_past_the_git_horizon_goes_and_its_branch_stays(self):
        """Past 14 write-idle days nothing outside depends on a linked worktree:
        its branch is its repository's, which is left one prunable entry
        (wt-sweep prunes it). Five had sat in /tmp 17 to 29 days on 2026-10-26."""
        repo, wt = os.path.join(self.tmp.name, "repo"), os.path.join(self.root, "wt")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        _git("worktree", "add", "-q", "-b", "wt", wt, cwd=repo)
        Path(wt, "f.txt").write_text("x" * 4096)
        _git("add", "f.txt", cwd=wt)
        _git("commit", "-q", "-m", "made in the worktree", cwd=wt)
        tip = subprocess.run([*_GIT, "rev-parse", "HEAD"], cwd=wt, env=_GIT_ENV, check=True,
                             capture_output=True, text=True).stdout.strip()
        plan = self._plan(ahead=15 * DAY)
        self.assertEqual(self._names(plan), ["wt"], plan.kept)
        self.assertIn("a linked worktree's branch stays in its repository", plan.items[0]["why"])
        removed, failed, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, failed, aborted), ([wt], [], []))
        _git("worktree", "prune", cwd=repo)
        branch = subprocess.run([*_GIT, "rev-parse", "wt"], cwd=repo, env=_GIT_ENV, check=True,
                                capture_output=True, text=True).stdout.strip()
        self.assertEqual(branch, tip)

    def test_an_exhausted_budget_counts_what_it_did_not_examine(self):
        """No silent caps: an unexamined entry is counted, never read as clean."""
        self._entry("a")
        self._entry("b")
        plan = self._plan(budget_s=0)
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.unexamined, 2)

    def test_apply_removes_the_entry_and_keeps_the_root(self):
        self._entry("done-experiment", files=("weights.bin", "log.txt"))
        removed, failed, aborted = R.apply_scratch(self._plan().items, lambda: _NO_HOLDERS)
        self.assertEqual((len(removed), failed, aborted), (1, [], []))
        self.assertEqual(os.listdir(self.root), [])

    def test_apply_removes_a_read_only_tree(self):
        """Fixtures leave 0555/0500 dirs in /tmp (gw-cancel-1392, pg-repro-claim2
        on 2026-10-25), and a plain rmtree fails on them every hour."""
        d = self._entry("readonly-fixture")
        ro = os.path.join(d, "snapshot")
        os.makedirs(ro)
        Path(ro, "f").write_text("x")
        os.chmod(ro, 0o555)
        _, failed, _ = R.apply_scratch(self._plan().items, lambda: _NO_HOLDERS)
        self.assertEqual(failed, [])
        self.assertFalse(os.path.exists(d))

    def test_apply_aborts_an_entry_written_since_the_plan(self):
        d = self._entry("resumed")
        plan = self._plan()
        time.sleep(0.05)
        Path(d, "new.log").write_text("back at it")
        removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.exists(os.path.join(d, "new.log")))

    def test_apply_aborts_an_entry_written_deep_inside_since_the_plan(self):
        """Rewriting a file two levels down moves no timestamp on the entry
        itself, so only walking the tree again right before removal sees it."""
        d = self._entry("deep")
        os.makedirs(os.path.join(d, "run", "out"))
        Path(d, "run", "out", "results.json").write_text("{}")
        time.sleep(0.05)
        mark = time.time()
        time.sleep(0.05)
        with _roots([self.root], self.jobs):
            plan = R.plan_scratch(mark + 168 * HOUR, _NO_HOLDERS, 72, 168)
        self.assertEqual(self._names(plan), ["deep"])
        Path(d, "run", "out", "results.json").write_text('{"done": true}')
        removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertIn("written", aborted[0])
        self.assertTrue(os.path.isfile(os.path.join(d, "run", "out", "results.json")))

    def test_apply_aborts_an_entry_written_while_liveness_is_asked(self):
        """The walk comes first and liveness last, so what is written in
        between is caught by one more lstat right before removal."""
        d = self._entry("late")
        plan = self._plan()

        def snapshot():
            time.sleep(0.05)
            Path(d, "late.log").write_text("x")
            return _NO_HOLDERS

        removed, _, aborted = R.apply_scratch(plan.items, snapshot)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isfile(os.path.join(d, "late.log")))

    def test_apply_aborts_an_entry_held_since_the_plan(self):
        d = self._entry("picked-up")
        plan = self._plan()
        removed, _, aborted = R.apply_scratch(plan.items, lambda: _HoldsNames("picked-up"))
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isdir(d))

    def test_apply_rescans_liveness_once_its_scan_is_stale(self):
        """A holder that appears while earlier items are being removed is seen."""
        self._entry("first")
        self._entry("second")
        plan = self._plan()
        snaps = _Snapshots(_NO_HOLDERS, _HoldsNames("first", "second"))
        with _patched(SNAPSHOT_MAX_AGE_S=0):
            removed, _, aborted = R.apply_scratch(plan.items, snaps)
        self.assertEqual((len(removed), len(aborted), snaps.calls), (1, 1, 2))

    def test_apply_reuses_a_fresh_scan_across_items(self):
        """276,128 entries at one ~30 ms scan each would outlast the unit's timeout."""
        for name in ("a", "b", "c"):
            self._entry(name)
        snaps = _Snapshots(_NO_HOLDERS)
        removed, _, _ = R.apply_scratch(self._plan().items, snaps)
        self.assertEqual((len(removed), snaps.calls), (3, 1))

    def test_apply_stops_when_a_scan_cannot_answer(self):
        self._entry("a")
        removed, failed, _ = R.apply_scratch(self._plan().items, lambda: _DeadSnapshot())
        self.assertEqual((removed, len(failed)), ([], 1))
        self.assertTrue(os.path.isdir(os.path.join(self.root, "a")))


class GitScratchTests(_FixtureTree):
    """#2003: a tree holding git repositories goes only when git says every one
    is clean and every commit sits on a remote that still exists. Real
    repositories, real git; each keep below is a planted negative.

    Past GIT_WORK_HORIZON_H (#2010) work the tree holds no longer keeps it; only
    something outside that depends on it does. Keeps are proven at FAR, inside
    the horizon; what the horizon lets go is planned at SHORT and BEYOND."""

    FAR = 10 * DAY     # past the 168h /tmp floor, inside the horizon
    SHORT = 13 * DAY   # a day short of the horizon
    BEYOND = 15 * DAY  # a day past it

    def setUp(self):
        super().setUp()
        self.keeps = os.path.join(self.tmp.name, "git-keeps.json")
        horizon = R.GIT_WORK_HORIZON_H * HOUR
        self.assertTrue(168 * HOUR < self.FAR < self.SHORT < horizon < self.BEYOND,
                        "fixture: the plan offsets must straddle the horizon")

    def _plan(self, ahead=FAR, **kw):
        with _patched(GIT_KEEPS_PATH=self.keeps), _roots([self.root], self.jobs):
            return R.plan_scratch(time.time() + ahead, _NO_HOLDERS, 72, 168, **kw)

    def _clone(self, name="clone", push=True):
        """A clone, under the scratch root, of a bare origin outside it, with one
        tracked file committed and (by default) pushed."""
        origin = os.path.join(self.tmp.name, f"{name}-origin.git")
        clone = os.path.join(self.root, name)
        _git("init", "-q", "--bare", origin)
        _git("clone", "-q", origin, clone)
        Path(clone, "tracked.txt").write_text("x" * 4096)
        _git("add", "tracked.txt", cwd=clone)
        _git("commit", "-q", "-m", "x", cwd=clone)
        if push:
            _git("push", "-q", "origin", "main", cwd=clone)
        return clone

    def _kept_by(self, plan, why):
        self.assertEqual(plan.items, [], plan.kept)
        self.assertEqual(plan.kept.get(why), 1, plan.kept)

    def test_a_clean_pushed_clone_is_reclaimed(self):
        clone = self._clone()
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
        self.assertIn("its 1 git repository is clean and pushed", plan.items[0]["why"])
        removed, failed, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((len(removed), failed, aborted), (1, [], []))
        self.assertFalse(os.path.lexists(clone))

    def test_a_commit_not_on_the_remote_is_kept(self):
        clone = self._clone()
        _git("commit", "-q", "--allow-empty", "-m", "ahead", cwd=clone)
        self._kept_by(self._plan(), "git: unpushed commits")

    def test_commits_with_no_remote_are_kept(self):
        repo = os.path.join(self.root, "repo")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        self._kept_by(self._plan(), "git: commits and no remote")

    def test_uncommitted_work_is_kept(self):
        for change in ("untracked", "modified", "staged"):
            with self.subTest(change=change):
                clone = self._clone(f"clone-{change}")
                if change == "untracked":
                    Path(clone, "new.txt").write_text("y")
                else:
                    Path(clone, "tracked.txt").write_text("y")
                    if change == "staged":
                        _git("add", "tracked.txt", cwd=clone)
                self._kept_by(self._plan(), "git: uncommitted changes")
                shutil.rmtree(clone)

    def test_a_stash_is_kept(self):
        clone = self._clone()
        Path(clone, "tracked.txt").write_text("y")
        _git("stash", "-q", cwd=clone)
        self._kept_by(self._plan(), "git: unpushed commits")

    def test_a_bare_origin_inside_the_tree_is_kept(self):
        """Its branches are on no remote: once the tree goes, so do they."""
        tree = os.path.join(self.root, "tree")
        origin, clone = os.path.join(tree, "origin.git"), os.path.join(tree, "clone")
        _git("init", "-q", "--bare", origin)
        _git("clone", "-q", origin, clone)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=clone)
        _git("push", "-q", "origin", "main", cwd=clone)
        self._kept_by(self._plan(), "git: commits and no remote")

    def test_an_empty_repository_is_reclaimed(self):
        repo = os.path.join(self.root, "repo")
        _git("init", "-q", repo)
        self.assertEqual([i["path"] for i in self._plan().items], [repo])

    def test_a_remote_that_no_longer_exists_is_kept(self):
        """Pushed to a local path that is gone: the commits live only here now."""
        self._clone()
        shutil.rmtree(os.path.join(self.tmp.name, "clone-origin.git"))
        self._kept_by(self._plan(), "git: a remote that no longer exists")

    def test_a_worktree_registered_outside_is_kept_until_it_goes(self):
        clone = self._clone()
        outside = os.path.join(self.tmp.name, "wt-outside")
        _git("worktree", "add", "-q", "-b", "wt", outside, cwd=clone)
        self._kept_by(self._plan(), "git: registers a worktree outside it")
        shutil.rmtree(outside)  # its registration in clone/.git stays: no write here
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
        self.assertEqual(plan.evidence["git"], "1 tree(s) asked, 0 verdict(s) remembered")

    def test_a_separate_git_dir_is_kept(self):
        """git init --separate-git-dir leaves a bare-shaped git dir that records
        nothing of its work tree; only core.bare=false gives it away."""
        outside = os.path.join(self.tmp.name, "w")
        _git("init", "-q", f"--separate-git-dir={os.path.join(self.root, 'store.git')}", outside)
        self._kept_by(self._plan(), "git: the git dir of a work tree elsewhere")

    def test_a_git_dir_serving_a_work_tree_outside_is_kept(self):
        repo, outside = os.path.join(self.root, "r"), os.path.join(self.tmp.name, "w")
        os.makedirs(outside)
        _git("init", "-q", repo)
        _git("config", "core.worktree", outside, cwd=repo)
        self._kept_by(self._plan(), "git: its work tree is outside it")

    def test_status_looks_in_the_work_tree_core_worktree_names(self):
        """tree/r/.git serves tree/w: an untracked file there is work, though
        status run in tree/r would see nothing."""
        tree = os.path.join(self.root, "tree")
        repo, work = os.path.join(tree, "r"), os.path.join(tree, "w")
        os.makedirs(work)
        _git("init", "-q", repo)
        _git("config", "core.worktree", "../../w", cwd=repo)
        Path(work, "notes.md").write_text("y")
        self._kept_by(self._plan(), "git: uncommitted changes")

    def test_a_uv_style_empty_git_file_is_not_a_repository(self):
        """uv marks its cache dirs with an empty .git file (/tmp/uv-cache/sdists-v9,
        2026-10-25); git calls it an invalid gitfile, not work."""
        d = os.path.join(self.root, "uv-cache", "sdists-v9")
        os.makedirs(d)
        Path(d, ".git").write_bytes(b"")
        Path(d, "pkg.tar.gz").write_text("x" * 4096)
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [os.path.join(self.root, "uv-cache")])
        self.assertNotIn("repositor", plan.items[0]["why"])

    def test_a_git_file_git_cannot_read_is_kept(self):
        d = os.path.join(self.root, "d")
        os.makedirs(d)
        Path(d, ".git").write_text("not a gitfile\n")
        Path(d, "f.txt").write_text("x" * 4096)
        self._kept_by(self._plan(), "git: no answer")

    def test_a_git_dir_git_cannot_open_is_reclaimed_and_said(self):
        """systemd-tmpfiles takes HEAD from a repository no git opened in 14
        days while text searches keep its work files alive (35 trees, 12.2 GB,
        2026-10-25). git cannot open what is left; asked, it fails every time,
        and kept, it would stay forever."""
        tree = os.path.join(self.root, "tree")
        headless, no_refs = os.path.join(tree, "repo"), os.path.join(tree, "repo2")
        for repo in (headless, no_refs):
            _git("init", "-q", repo)
            _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        os.unlink(os.path.join(headless, ".git", "HEAD"))
        shutil.rmtree(os.path.join(no_refs, ".git", "refs"))
        clone = self._clone()
        os.rename(clone, os.path.join(tree, "clone"))
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [tree], plan.kept)
        self.assertIn("; its 1 git repository is clean and pushed"
                      "; 2 .git dirs lack the HEAD, objects or refs git needs to open them",
                      plan.items[0]["why"])

    def _with_submodule(self, push_sub=True):
        """A pushed clone with one submodule, cloned from an origin outside the
        tree, then deinitialised: .git/modules/sub is all that is left of it."""
        sub_origin = os.path.join(self.tmp.name, "sub-origin")
        _git("init", "-q", sub_origin)
        _git("commit", "-q", "--allow-empty", "-m", "sub", cwd=sub_origin)
        clone = self._clone()
        _git("-c", "protocol.file.allow=always", "submodule", "add", "-q", sub_origin, "sub", cwd=clone)
        _git("commit", "-q", "-m", "sub", cwd=clone)
        _git("push", "-q", "origin", "main", cwd=clone)
        if not push_sub:
            _git("commit", "-q", "--allow-empty", "-m", "only here", cwd=os.path.join(clone, "sub"))
        _git("submodule", "deinit", "-q", "-f", "sub", cwd=clone)
        return clone

    def test_a_deinitialised_submodules_commits_are_kept(self):
        """deinit empties the submodule's dir; its commits stay only in the
        superproject's .git/modules."""
        self._with_submodule(push_sub=False)
        self._kept_by(self._plan(), "git: unpushed commits")

    def test_a_deinitialised_pushed_submodule_is_reclaimed(self):
        clone = self._with_submodule()
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
        self.assertIn("its 2 git repositories are clean and pushed", plan.items[0]["why"])

    def test_a_submodule_git_dir_whose_work_tree_is_gone_is_still_read(self):
        """git rm takes the submodule from the superproject and leaves its git
        dir. With core.worktree still naming the gone dir (git before 2.43 left
        it, a hand edit can), git run on the module dir alone dies: "cannot
        chdir to '../../../sub'"."""
        clone = self._with_submodule(push_sub=False)
        _git("rm", "-q", "-f", "sub", cwd=clone)
        _git("commit", "-q", "-m", "no sub", cwd=clone)
        _git("push", "-q", "origin", "main", cwd=clone)
        module = os.path.join(clone, ".git", "modules", "sub")
        _git(f"--git-dir={module}", "config", "core.worktree", "../../../sub")
        self.assertFalse(os.path.lexists(os.path.join(clone, "sub")), "fixture: the dir is gone")
        self._kept_by(self._plan(), "git: unpushed commits")

    def test_an_edit_status_is_told_to_skip_is_kept(self):
        """assume-unchanged and skip-worktree hide an edited file from status."""
        for flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(flag=flag):
                clone = self._clone(f"clone{flag}")
                _git("update-index", flag, "tracked.txt", cwd=clone)
                Path(clone, "tracked.txt").write_text("y")
                self._kept_by(self._plan(), "git: files status is told to skip")
                shutil.rmtree(clone)

    def test_a_sparse_checkout_is_reclaimed(self):
        """A sparse checkout marks what it leaves out skip-worktree too, but
        those files are not there to hold an edit."""
        clone = self._clone()
        for d in ("a", "b"):
            os.makedirs(os.path.join(clone, d))
            Path(clone, d, "f.txt").write_text(d)
        _git("add", "a", "b", cwd=clone)
        _git("commit", "-q", "-m", "ab", cwd=clone)
        _git("push", "-q", "origin", "main", cwd=clone)
        _git("sparse-checkout", "set", "a", cwd=clone)
        self.assertFalse(os.path.lexists(os.path.join(clone, "b")), "fixture: b/ is left out")
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)

    def _holding(self, reason, n):
        """A tree under the scratch root that git keeps for `reason`: work only
        it holds, or a tie from it to a repository nothing of which lives here."""
        if reason == "git: commits and no remote":
            repo = os.path.join(self.root, f"repo{n}")
            _git("init", "-q", repo)
            _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
            return repo
        if reason == "git: a .git symlink":
            linked, d = os.path.join(self.tmp.name, f"linked{n}"), os.path.join(self.root, f"d{n}")
            _git("init", "-q", linked)
            os.makedirs(d)
            os.symlink(os.path.join(linked, ".git"), os.path.join(d, ".git"))
            Path(d, "f.txt").write_text("x" * 4096)
            return d
        if reason == "git: a worktree of a repository outside it":
            main, wt = os.path.join(self.tmp.name, f"main{n}"), os.path.join(self.root, f"wt{n}")
            _git("init", "-q", main)
            _git("commit", "-q", "--allow-empty", "-m", "x", cwd=main)
            _git("worktree", "add", "-q", "-b", f"wt{n}", wt, cwd=main)
            return wt
        clone = self._clone(f"clone{n}")
        if reason == "git: unpushed commits":
            _git("commit", "-q", "--allow-empty", "-m", "ahead", cwd=clone)
        elif reason == "git: a remote that no longer exists":
            shutil.rmtree(os.path.join(self.tmp.name, f"clone{n}-origin.git"))
        elif reason == "git: uncommitted changes":
            Path(clone, "new.txt").write_text("y")
        elif reason == "git: files status is told to skip":
            _git("update-index", "--skip-worktree", "tracked.txt", cwd=clone)
            Path(clone, "tracked.txt").write_text("y")
        return clone

    SOFT = ("git: unpushed commits", "git: commits and no remote", "git: a remote that no longer exists",
            "git: uncommitted changes", "git: files status is told to skip", "git: a .git symlink",
            "git: a worktree of a repository outside it")

    def test_past_the_horizon_work_only_the_tree_holds_no_longer_keeps_it(self):
        """#2010: 72 trees (21.8 GB) were kept with no end on 2026-10-25, none
        holding work found nowhere else. The host ages /tmp at 14 days by atime,
        which any read moves; here the write clock decides."""
        for n, reason in enumerate(self.SOFT):
            with self.subTest(reason=reason):
                tree = self._holding(reason, n)
                let_go = f'write-idle past the 14d horizon, so git\'s "{reason[5:]}" no longer keeps it'
                for ahead, said in ((self.BEYOND, "1 tree(s) asked, 0 verdict(s) remembered"),
                                    (self.BEYOND, "0 tree(s) asked, 1 verdict(s) remembered")):
                    plan = self._plan(ahead=ahead)
                    self.assertEqual([i["path"] for i in plan.items], [tree], plan.kept)
                    self.assertIn(let_go, plan.items[0]["why"])
                    self.assertNotIn("clean and pushed", plan.items[0]["why"])
                    self.assertFalse([k for k in plan.kept if k.startswith("git")], plan.kept)
                    self.assertEqual(plan.evidence["git"], f"{said}, 1 let go past the 14d horizon")
                plan = self._plan(ahead=self.SHORT)
                self._kept_by(plan, reason)
                self.assertEqual(plan.evidence["git"], "0 tree(s) asked, 1 verdict(s) remembered")
                shutil.rmtree(tree)

    def test_unpushed_commits_do_not_hide_a_worktree_registered_outside(self):
        """Planted negative: the outside worktree's git dir is in this tree.
        git_keeps once stopped at the first keep, and unpushed commits come
        first; past the horizon that verdict would let the tree go."""
        clone = self._clone()
        _git("commit", "-q", "--allow-empty", "-m", "ahead", cwd=clone)
        outside = os.path.join(self.tmp.name, "wt-outside")
        _git("worktree", "add", "-q", "-b", "wt", outside, cwd=clone)
        said = []
        for ahead in (self.BEYOND, self.FAR + 2 * R.GIT_RETRY_S):  # a definite keep has no retry window
            plan = self._plan(ahead=ahead)
            self._kept_by(plan, "git: registers a worktree outside it")
            said.append(plan.evidence["git"])
        self.assertEqual(said, ["1 tree(s) asked, 0 verdict(s) remembered",
                                "0 tree(s) asked, 1 verdict(s) remembered"])
        self.assertEqual(json.loads(Path(self.keeps).read_text())[clone]["outside"], [outside])

    def test_a_later_repository_that_something_outside_depends_on_is_not_hidden(self):
        """Planted negative: repositories are asked in path order, so tree/a's
        own work must not end the asking before tree/b, which serves a work
        tree outside."""
        cases = [(own, dependent) for own in ("uncommitted", "no remote") for dependent in ("work tree", "worktree")]
        for n, (own, dependent) in enumerate(cases):
            with self.subTest(own=own, dependent=dependent):
                tree = os.path.join(self.root, f"tree{n}")
                a, b = os.path.join(tree, "a"), os.path.join(tree, "b")
                outside = os.path.join(self.tmp.name, f"outside{n}")
                _git("init", "-q", a)
                if own == "uncommitted":
                    Path(a, "notes.md").write_text("y")
                else:
                    _git("commit", "-q", "--allow-empty", "-m", "x", cwd=a)
                _git("init", "-q", b)
                if dependent == "work tree":
                    os.makedirs(outside)
                    _git("config", "core.worktree", outside, cwd=b)
                    why = "git: its work tree is outside it"
                else:
                    _git("commit", "-q", "--allow-empty", "-m", "x", cwd=b)
                    _git("worktree", "add", "-q", "-b", "wt", outside, cwd=b)
                    why = "git: registers a worktree outside it"
                self._kept_by(self._plan(ahead=self.BEYOND), why)
                shutil.rmtree(tree)

    def test_a_separate_git_dir_is_kept_past_the_horizon(self):
        outside = os.path.join(self.tmp.name, "w")
        _git("init", "-q", f"--separate-git-dir={os.path.join(self.root, 'store.git')}", outside)
        _git("commit", "-q", "--allow-empty", "-m", "only here", cwd=outside)
        self._kept_by(self._plan(ahead=self.BEYOND), "git: the git dir of a work tree elsewhere")

    def test_a_verdict_remembered_before_the_horizon_is_asked_again(self):
        """Verdicts saved before #2010 stopped at the first keep, so a
        remembered "unpushed commits" may hide an outside dependency: one
        without the soft mark is never trusted to let a tree go."""
        clone = self._clone()
        _git("commit", "-q", "--allow-empty", "-m", "ahead", cwd=clone)
        _git("worktree", "add", "-q", "-b", "wt", os.path.join(self.tmp.name, "wt-outside"), cwd=clone)
        self._plan()
        entry = json.loads(Path(self.keeps).read_text())[clone]
        old = {k: v for k, v in entry.items() if k != "soft"}
        old.update(keep="git: unpushed commits", outside=[])
        Path(self.keeps).write_text(json.dumps({clone: old}))
        plan = self._plan(ahead=self.BEYOND)
        self._kept_by(plan, "git: registers a worktree outside it")
        self.assertEqual(plan.evidence["git"], "1 tree(s) asked, 0 verdict(s) remembered")

    def test_a_git_failure_is_remembered_only_for_the_retry_window(self):
        """A failure is remembered, or a tree git times out on would cost its
        whole bound every hour, but not for good: it may have been transient.
        It is no work git found, so the horizon never lets it go."""
        clone = self._clone()
        with _patched(GIT_CMD=(sys.executable, "-c", "raise SystemExit(1)")):
            self._kept_by(self._plan(), "git: no answer")
        plan = self._plan(ahead=self.BEYOND)
        self._kept_by(plan, "git: no answer")
        self.assertEqual(plan.evidence["git"], "0 tree(s) asked, 1 verdict(s) remembered")
        plan = self._plan(ahead=self.FAR + R.GIT_RETRY_S)
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
        self.assertEqual(plan.evidence["git"], "1 tree(s) asked, 0 verdict(s) remembered")

    def test_asking_git_writes_nothing(self):
        """A status that saw a touched file would refresh the index; that write
        would be the next walk's evidence the tree is live."""
        clone = self._clone()
        index = os.path.join(clone, ".git", "index")
        _age(os.path.join(clone, "tracked.txt"), 3 * DAY)  # stat no longer matches the index
        before = os.lstat(index)
        before_names = sorted(os.listdir(os.path.join(clone, ".git")))
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
        after = os.lstat(index)
        self.assertEqual((after.st_mtime_ns, after.st_ctime_ns, after.st_ino),
                         (before.st_mtime_ns, before.st_ctime_ns, before.st_ino))
        self.assertEqual(sorted(os.listdir(os.path.join(clone, ".git"))), before_names)

    def test_a_repository_local_fsmonitor_hook_never_runs(self):
        clone = self._clone()
        marker = os.path.join(self.tmp.name, "hook-ran")
        hook = os.path.join(self.tmp.name, "fsmonitor-hook")
        Path(hook).write_text(f"#!/bin/sh\ntouch {marker}\n")
        os.chmod(hook, 0o755)
        _git("config", "core.fsmonitor", hook, cwd=clone)
        self._plan()
        self.assertFalse(os.path.exists(marker), "the repository's own fsmonitor hook ran")

    def test_a_git_that_does_not_answer_is_kept(self):
        self._clone()
        with _patched(GIT_CMD=(sys.executable, "-c", "import time; time.sleep(30)"), GIT_TREE_BUDGET_S=0.5):
            t0 = time.monotonic()
            plan = self._plan()
        self.assertLess(time.monotonic() - t0, 10)
        self._kept_by(plan, "git: no answer within 0.5s")

    def test_the_plan_budget_running_out_in_git_leaves_it_unexamined(self):
        """Not a keep and not remembered: the next run asks again."""
        self._clone()
        started = os.path.join(self.tmp.name, "git-started")
        slow = f"open({started!r}, 'w').close(); import time; time.sleep(30)"
        with _patched(GIT_CMD=(sys.executable, "-c", slow)):
            plan = self._plan(budget_s=1.5)
        self.assertTrue(os.path.exists(started), "fixture: git was asked")
        self.assertEqual((plan.items, plan.unexamined), ([], 1), plan.kept)
        self.assertFalse([k for k in plan.kept if k.startswith("git")], plan.kept)
        self.assertFalse(os.path.exists(self.keeps) and json.loads(Path(self.keeps).read_text()))

    def test_a_kept_tree_is_asked_once_until_it_changes(self):
        """An hourly status reads .git files and so moves their atimes, and
        systemd-tmpfiles would never age the tree (relatime, 14d)."""
        repo = os.path.join(self.root, "repo")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        said = []
        for ahead in (self.FAR, self.SHORT):
            plan = self._plan(ahead=ahead)
            self._kept_by(plan, "git: commits and no remote")
            said.append(plan.evidence["git"])
        Path(repo, "new.txt").write_text("y")
        plan = self._plan()
        self._kept_by(plan, "git: commits and no remote")
        said.append(plan.evidence["git"])
        self.assertEqual(said, ["1 tree(s) asked, 0 verdict(s) remembered",
                                "0 tree(s) asked, 1 verdict(s) remembered",
                                "1 tree(s) asked, 0 verdict(s) remembered"])

    def test_a_damaged_memory_is_asked_past_and_never_removes(self):
        clone = self._clone()
        repo = os.path.join(self.root, "repo")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        self._plan()
        good = json.loads(Path(self.keeps).read_text())
        self.assertEqual(list(good), [repo], "only keep verdicts are remembered")
        no_keep = {repo: {k: v for k, v in good[repo].items() if k != "keep"}}
        wrong_fp = {clone: {**good[repo], "fp": ["stale"]}}
        for name, text in (("garbage", "{not json"), ("a list", "[]"), ("no keep", json.dumps(no_keep)),
                           ("keep not text", json.dumps({repo: {**good[repo], "keep": 1}})),
                           ("another tree's print", json.dumps(wrong_fp))):
            with self.subTest(memory=name):
                Path(self.keeps).write_text(text)
                plan = self._plan()
                self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
                self.assertEqual(plan.kept.get("git: commits and no remote"), 1, plan.kept)
                self.assertEqual(plan.evidence["git"], "2 tree(s) asked, 0 verdict(s) remembered")

    def test_a_memory_that_cannot_be_saved_says_so(self):
        repo = os.path.join(self.root, "repo")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        Path(self.tmp.name, "a-file").write_text("")
        self.keeps = os.path.join(self.tmp.name, "a-file", "git-keeps.json")
        plan = self._plan()
        self._kept_by(plan, "git: commits and no remote")
        self.assertIn("not saved:", plan.evidence["git"])

    def test_git_is_asked_only_of_an_otherwise_reclaimable_tree(self):
        repo = os.path.join(self.root, "repo")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        with self.subTest(case="fresh"):
            plan = self._plan(ahead=0)
            self.assertEqual(plan.kept.get("fresh"), 1, plan.kept)
            self.assertEqual(plan.evidence["git"], "0 tree(s) asked, 0 verdict(s) remembered")
        with self.subTest(case="small"), _patched(BULK_MIN_BYTES=GB):
            plan = self._plan()
            self.assertEqual(plan.kept.get("small: systemd-tmpfiles ages it"), 1, plan.kept)
            self.assertEqual(plan.evidence["git"], "0 tree(s) asked, 0 verdict(s) remembered")

    def test_a_commit_between_plan_and_apply_aborts(self):
        """Planned clean, then committed to: the re-walk sees the write in .git."""
        clone = self._clone()
        time.sleep(0.05)
        plan = self._plan(ahead=168 * HOUR)  # cutoff: now
        self.assertEqual(len(plan.items), 1, plan.kept)
        time.sleep(0.05)
        _git("commit", "-q", "--allow-empty", "-m", "late", cwd=clone)
        removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isdir(os.path.join(clone, ".git")))

    def test_a_commit_between_plan_and_apply_aborts_a_tree_the_horizon_let_go(self):
        """The horizon only plans; removal re-walks against the floor's cutoff
        like any other item. The floor sits at BEYOND here so that cutoff is now."""
        clone = self._clone()
        _git("commit", "-q", "--allow-empty", "-m", "ahead", cwd=clone)
        time.sleep(0.05)
        with _patched(GIT_KEEPS_PATH=self.keeps), _roots([self.root], self.jobs):
            plan = R.plan_scratch(time.time() + self.BEYOND, _NO_HOLDERS, 72, self.BEYOND / HOUR)
        self.assertEqual([i["path"] for i in plan.items], [clone], plan.kept)
        self.assertIn('"unpushed commits" no longer keeps it', plan.items[0]["why"])
        time.sleep(0.05)
        _git("commit", "-q", "--allow-empty", "-m", "late", cwd=clone)
        removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isdir(os.path.join(clone, ".git")))


class ClaudeTmpdirTests(_FixtureTree):
    """/tmp/claude-<uid>: project dirs hold every session of a project, so the
    session dirs inside them are the units, kept while their session is live."""

    FAR = 30 * DAY
    SLUG = "-home-user-SITES-app"
    EXITED = "2b5a4195-acb4-41ae-a97e-89b145b9fbee"
    LIVE = "c99ab8d4-375d-459b-98b6-d36c68ca2129"

    def setUp(self):
        super().setUp()
        self.sessions = os.path.join(self.tmp.name, "sessions")
        os.makedirs(self.sessions)
        for sid in (self.EXITED, self.LIVE):
            os.makedirs(os.path.join(self.root, self.SLUG, sid, "tasks"))
            Path(self.root, self.SLUG, sid, "tasks", "b8h092rqi.output").write_text("x" * 4096)
        os.makedirs(os.path.join(self.root, self.SLUG, "rerooted"))
        Path(self.root, self.SLUG, "rerooted", "bi22hf69d.output").write_text("x")
        self._register(self.LIVE, os.getpid())

    def _register(self, sid, pid, domain=None):
        doc = {"pid": pid, "sessionId": sid}
        if domain:
            doc["pidDomain"] = domain
        Path(self.sessions, f"{pid}.json").write_text(json.dumps(doc))

    def _dead_pid(self):
        p = subprocess.Popen(["true"])
        p.wait()
        return p.pid

    def _plan(self, snap=_NO_HOLDERS, sessions_root=None):
        with _roots([self.root], self.jobs, cc_tmpdir=self.root,
                    sessions_root=sessions_root or self.sessions):
            return R.plan_scratch(time.time() + self.FAR, snap, 72, 168)

    def _path(self, *parts):
        return os.path.join(self.root, self.SLUG, *parts)

    def test_an_exited_sessions_dir_is_the_unit_and_the_project_dir_stays(self):
        plan = self._plan()
        self.assertEqual([i["path"] for i in plan.items], [self._path(self.EXITED)])
        self.assertEqual((plan.kept.get("live claude session"), plan.kept.get("claude code internal")),
                         (1, 1))
        with _patched(SESSIONS_ROOT=self.sessions):
            removed, failed, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((len(removed), failed, aborted), (1, [], []))
        self.assertEqual(sorted(os.listdir(self._path())), sorted([self.LIVE, "rerooted"]))

    def test_a_registry_entry_whose_pid_is_gone_does_not_keep_its_session(self):
        self._register(self.EXITED, self._dead_pid())
        self.assertEqual([i["path"] for i in self._plan().items], [self._path(self.EXITED)])

    def test_an_unreadable_registry_keeps_every_session(self):
        Path(self.sessions, f"{os.getpid()}.json").write_text("")  # a running session's entry mid-write
        for label, root in (("missing", os.path.join(self.tmp.name, "absent")),
                            ("a running pid's entry unreadable", self.sessions)):
            with self.subTest(label):
                plan = self._plan(sessions_root=root)
                self.assertEqual(plan.items, [])
                self.assertEqual(plan.kept.get("claude session registry unreadable"), 2)

    def test_an_unreadable_entry_of_a_dead_pid_is_skipped(self):
        # 10-25: one zero-byte entry an 08-21 crash left behind kept all 2,573 session dirs
        Path(self.sessions, f"{self._dead_pid()}.json").write_text("")
        Path(self.sessions, f"{self._dead_pid()}.json").write_text("{not json")
        self.assertEqual([i["path"] for i in self._plan().items], [self._path(self.EXITED)])

    def test_a_long_unwritten_unreadable_entry_is_skipped_even_if_its_pid_was_reused(self):
        self.child = subprocess.Popen(["sleep", "30"])
        stale = Path(self.sessions, f"{self.child.pid}.json")
        stale.write_text("")
        old = time.time() - R.UNPARSED_ENTRY_STALE_S - HOUR
        os.utime(stale, (old, old))
        self.assertEqual([i["path"] for i in self._plan().items], [self._path(self.EXITED)])

    def test_an_unreadable_entry_not_named_for_a_pid_keeps_every_session(self):
        Path(self.sessions, "lock.json").write_text("")
        self.assertEqual(self._plan().kept.get("claude session registry unreadable"), 2)

    def test_beside_another_pid_namespace_an_unreadable_entry_keeps_every_session(self):
        # its file name's pid means nothing here, so it may name a running session
        self._register("0dd5e55e-0000-4000-8000-000000000000", 1, domain="pid:[1]")
        Path(self.sessions, f"{self._dead_pid()}.json").write_text("")
        self.assertEqual(self._plan().kept.get("claude session registry unreadable"), 2)

    def test_a_session_resumed_between_plan_and_apply_is_kept(self):
        plan = self._plan()
        self._register(self.EXITED, os.getpid())
        with _patched(SESSIONS_ROOT=self.sessions):
            removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isdir(self._path(self.EXITED)))

    def test_a_process_inside_a_session_dir_holds_it(self):
        self.child = subprocess.Popen(["sleep", "30"], cwd=self._path(self.EXITED, "tasks"))
        time.sleep(0.2)
        plan = self._plan(snap=R.proc_liveness.ProcSnapshot(exclude_pids=frozenset()))
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("held"), 1)

    def test_loose_scratch_beside_the_project_dirs_is_judged_like_tmp(self):
        Path(self.root, "pr4049-body-v2.md").write_text("x")
        names = sorted(os.path.basename(i["path"]) for i in self._plan().items)
        self.assertEqual(names, [self.EXITED, "pr4049-body-v2.md"])


class JobScratchTests(_FixtureTree):
    """$CLAUDE_JOB_DIR/tmp of jobs that Claude Code itself calls settled."""

    FAR = 10 * DAY

    def _state(self, j, state, tempo="idle", terminal_ago=DAY, **ids):
        doc = {"state": state, "tempo": tempo, **ids}
        if state in ("done", "failed", "stopped"):
            doc["lastTerminalAt"] = time.strftime(
                "%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - terminal_ago))
        Path(j, "state.json").write_text(json.dumps(doc))

    def _job(self, jid="2b5a4195", state="done", tempo="idle", terminal_ago=DAY, **ids):
        j = os.path.join(self.jobs, jid)
        os.makedirs(os.path.join(j, "tmp", "u5-attempt-3", "node_modules"))
        Path(j, "tmp", "capacity-bridge-tests.log").write_text("x" * 4096)
        Path(j, "tmp", "u5-attempt-3", "node_modules", "index.js").write_text("x" * 4096)
        Path(j, "timeline.jsonl").write_text("{}\n")
        self._state(j, state, tempo, terminal_ago, **ids)
        return j

    def _plan(self, snap=_NO_HOLDERS, ahead=FAR, job_floor_h=72, sessions_root=None):
        with _roots([self.root], self.jobs, sessions_root=sessions_root):
            return R.plan_scratch(time.time() + ahead, snap, job_floor_h, 168)

    def _sessions(self, *live_ids):
        """A session registry in which this (running) process owns each id."""
        root = os.path.join(self.tmp.name, "sessions")
        os.makedirs(root, exist_ok=True)
        for n, sid in enumerate(live_ids):
            Path(root, f"{os.getpid()}-{n}.json").write_text(json.dumps({"pid": os.getpid(), "sessionId": sid}))
        return root

    def test_a_settled_quiet_jobs_tmp_is_emptied_and_kept(self):
        j = self._job()
        before = os.lstat(j).st_mtime_ns
        plan = self._plan()
        self.assertEqual([i["rule"] for i in plan.items], ["job-scratch"])
        removed, failed, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((failed, aborted), ([], []))
        self.assertEqual(os.listdir(os.path.join(j, "tmp")), [])
        self.assertTrue(os.path.isfile(os.path.join(j, "state.json")))
        self.assertEqual(os.lstat(j).st_mtime_ns, before,
                         "the job dir's own mtime is Claude Code's 30-day clock")

    def test_unsettled_jobs_are_kept(self):
        for jid, state, tempo in (("aaaa0001", "working", "idle"),
                                  ("aaaa0002", "blocked", "idle"),
                                  ("aaaa0003", "done", "active")):
            self._job(jid, state, tempo)
        plan = self._plan()
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("job not settled"), 3)

    def test_a_recently_settled_job_is_kept(self):
        """2b5a4195 went done at 04:30Z and was resumed at 05:46Z (2026-10-25),
        its scratch hours older than that. So the planning clock sits FAR ahead,
        where every tmp child is idle, and each of the job's own quiet signals in
        turn is put 76 minutes before it: only that signal can keep the job."""
        settled = time.time() + self.FAR - 76 * 60
        for signal in ("lastTerminalAt", "state.json", "timeline.jsonl"):
            with self.subTest(signal=signal):
                j = self._job(f"job-{signal}".replace(".", "-"),
                              terminal_ago=time.time() - settled if signal == "lastTerminalAt" else DAY)
                if signal != "lastTerminalAt":
                    os.utime(os.path.join(j, signal), (settled, settled))
                plan = self._plan(job_floor_h=6)
                self.assertEqual(plan.items, [])
                self.assertEqual(plan.kept.get("job not quiet"), 1)
                shutil.rmtree(j)

    def test_a_job_a_residue_rule_already_removed_is_skipped_quietly(self):
        """claude-job-dir (30d) runs first in the same --apply; its job must not
        come back every hour as an ABORTED 'state changed' line."""
        j = self._job()
        plan = self._plan()
        shutil.rmtree(j)
        self.assertEqual(R.apply_scratch(plan.items, lambda: _NO_HOLDERS), ([], [], []))

    def test_a_pinned_job_is_kept(self):
        self._job("5576b6d3")
        Path(self.jobs, "pins.json").write_text('["5576b6d3"]')
        self.assertEqual(self._plan().items, [])

    def test_unreadable_pins_keep_every_job(self):
        self._job()
        os.makedirs(os.path.join(self.jobs, "pins.json"))
        self.assertEqual(self._plan().items, [])

    def test_an_environ_holder_of_the_job_dir_protects_its_tmp(self):
        """A job's tool children carry CLAUDE_JOB_DIR=<job dir>, and '<job>/tmp'
        is not a substring of that, so liveness must be asked of the job dir."""
        j = self._job()
        env = {k: v for k, v in os.environ.items() if j not in v}
        env["CLAUDE_JOB_DIR"] = j
        self.child = subprocess.Popen(["sleep", "30"], cwd="/", env=env)
        time.sleep(0.2)
        snap = R.proc_liveness.ProcSnapshot(exclude_pids=frozenset())
        self.assertIsNone(snap.holder(os.path.join(j, "tmp")), "the trap this test pins")
        self.assertIsNotNone(snap.holder(j))
        plan = self._plan(snap=snap)
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("job held"), 1)

    def test_a_job_resumed_between_plan_and_apply_is_untouched(self):
        """Planted negative (#2002): "done" is per-turn, so state.json is re-read
        right before removal."""
        j = self._job()
        plan = self._plan()
        self.assertEqual(len(plan.items), 1)
        self._state(j, "working")
        removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isfile(os.path.join(j, "tmp", "capacity-bridge-tests.log")))

    def test_a_git_worktree_in_job_tmp_survives_its_siblings(self):
        j = self._job()
        wt = os.path.join(j, "tmp", "wt")
        os.makedirs(wt)
        Path(wt, ".git").write_text("gitdir: /x/.git/worktrees/wt\n")
        plan = self._plan()
        self.assertEqual(plan.kept.get("git: a worktree of a repository outside it"), 1, plan.kept)
        R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual(os.listdir(os.path.join(j, "tmp")), ["wt"])

    def test_a_repository_with_work_in_job_tmp_survives_its_siblings(self):
        j = self._job()
        repo = os.path.join(j, "tmp", "repo")
        _git("init", "-q", repo)
        Path(repo, "notes.md").write_text("x" * 4096)
        _git("add", "notes.md", cwd=repo)
        _git("commit", "-q", "-m", "x", cwd=repo)
        plan = self._plan()
        self.assertEqual(plan.kept.get("git: commits and no remote"), 1, plan.kept)
        R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual(os.listdir(os.path.join(j, "tmp")), ["repo"])

    def test_past_the_git_horizon_a_childs_own_work_no_longer_keeps_it(self):
        """#2010, through the same keeps() as tmp-scratch: a child holding work
        only it has goes past 14 write-idle days; one a work tree outside
        depends on stays."""
        j = self._job()
        repo, keep = os.path.join(j, "tmp", "repo"), os.path.join(j, "tmp", "keep")
        _git("init", "-q", repo)
        _git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        outside = os.path.join(self.tmp.name, "w")
        os.makedirs(outside)
        _git("init", "-q", keep)
        _git("config", "core.worktree", outside, cwd=keep)
        plan = self._plan(ahead=13 * DAY)
        self.assertEqual((plan.kept.get("git: commits and no remote"),
                          plan.kept.get("git: its work tree is outside it")), (1, 1), plan.kept)
        self.assertNotIn("horizon", plan.items[0]["why"])
        plan = self._plan(ahead=15 * DAY)
        self.assertEqual(plan.kept.get("git: its work tree is outside it"), 1, plan.kept)
        self.assertIsNone(plan.kept.get("git: commits and no remote"), plan.kept)
        self.assertEqual(len(plan.items), 1, plan.kept)
        self.assertIn('; repo: write-idle past the 14d horizon, so git\'s "commits and no remote"'
                      " no longer keeps it", plan.items[0]["why"])
        self.assertNotIn("clean and pushed", plan.items[0]["why"])
        removed, failed, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((failed, aborted), ([], []))
        self.assertEqual(os.listdir(os.path.join(j, "tmp")), ["keep"])

    def test_a_clean_pushed_clone_in_job_tmp_goes_with_the_rest(self):
        j = self._job()
        origin = os.path.join(self.tmp.name, "origin.git")
        clone = os.path.join(j, "tmp", "clone")
        _git("init", "-q", "--bare", origin)
        _git("clone", "-q", origin, clone)
        Path(clone, "f.txt").write_text("x" * 4096)
        _git("add", "f.txt", cwd=clone)
        _git("commit", "-q", "-m", "x", cwd=clone)
        _git("push", "-q", "origin", "main", cwd=clone)
        plan = self._plan()
        self.assertEqual(len(plan.items), 1, plan.kept)
        self.assertIn("its 1 git repository is clean and pushed", plan.items[0]["why"])
        removed, failed, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((failed, aborted), ([], []))
        self.assertEqual(os.listdir(os.path.join(j, "tmp")), [])

    def test_the_plan_budget_running_out_in_git_leaves_the_job_unexamined(self):
        j = self._job()
        _git("init", "-q", os.path.join(j, "tmp", "repo"))
        with _patched(GIT_CMD=(sys.executable, "-c", "import time; time.sleep(30)")):
            with _roots([self.root], self.jobs):
                plan = R.plan_scratch(time.time() + self.FAR, _NO_HOLDERS, 72, 168, budget_s=1.5)
        self.assertEqual((plan.items, plan.unexamined), ([], 1), plan.kept)

    def test_a_done_job_whose_session_still_runs_is_kept(self):
        """2026-10-25: seven jobs read done/idle while their process waited on the
        operator, one (51130664) with 20 GiB in tmp/. "done" ends a turn, not
        the session; the registry is what knows the session is still open."""
        sid = "51130664-6b0e-4c38-9a4c-2f0c1d1e7a10"
        for field in ("sessionId", "resumeSessionId"):
            with self.subTest(field=field):
                j = self._job(**{field: sid})
                plan = self._plan(sessions_root=self._sessions(sid))
                self.assertEqual(plan.items, [])
                self.assertEqual(plan.kept.get("job session live"), 1)
                shutil.rmtree(j)

    def test_an_unreadable_registry_keeps_every_job(self):
        self._job(sessionId="011eb686-fecb-4fb3-8f51-f3e9302ca70c")
        plan = self._plan(sessions_root=os.path.join(self.tmp.name, "absent"))
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("claude session registry unreadable"), 1)

    def test_a_job_whose_session_comes_back_before_apply_is_untouched(self):
        sid = "424c85b9-eab2-46ef-a7f2-4f92934e633c"
        j = self._job(sessionId=sid)
        empty = self._sessions()
        plan = self._plan(sessions_root=empty)
        self.assertEqual(len(plan.items), 1)
        with _patched(SESSIONS_ROOT=self._sessions(sid)):
            removed, _, aborted = R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual((removed, len(aborted)), ([], 1))
        self.assertTrue(os.path.isfile(os.path.join(j, "tmp", "capacity-bridge-tests.log")))


class BulkGateTests(_FixtureTree):
    """Only bulk is this sweep's: smaller entries keep the owners they already
    had, systemd-tmpfiles' 14 days in /tmp and claude-job-dir's 30 for a job."""

    FAR = 30 * DAY
    GATE = 64 * 1024

    def _write(self, path, size):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(os.urandom(size))  # real blocks: the gate counts allocated bytes

    def _plan(self):
        with _roots([self.root], self.jobs), _patched(BULK_MIN_BYTES=self.GATE):
            return R.plan_scratch(time.time() + self.FAR, _NO_HOLDERS, 72, 168)

    def test_a_small_tmp_entry_is_left_to_tmpfiles(self):
        """2026-10-25: a 149 KB plan another session still read sat among
        271,520 sub-MiB entries that held 4 of the candidates' 164 GiB."""
        self._write(os.path.join(self.root, "webinar-plan-2b5a", "plan.md"), 4096)
        self._write(os.path.join(self.root, "sp10-face", "frames", "f0001.raw"), 2 * self.GATE)
        plan = self._plan()
        self.assertEqual([os.path.basename(i["path"]) for i in plan.items], ["sp10-face"])
        self.assertEqual(plan.kept.get("small: systemd-tmpfiles ages it"), 1)

    def test_a_jobs_small_files_stay_and_its_bulk_goes(self):
        j = os.path.join(self.jobs, "49935384")
        self._write(os.path.join(j, "tmp", "pr-body.md"), 4096)
        self._write(os.path.join(j, "tmp", "build", "out.bin"), 2 * self.GATE)
        Path(j, "state.json").write_text(json.dumps({"state": "done", "tempo": "idle"}))
        plan = self._plan()
        self.assertEqual([i["entries"] for i in plan.items], [1])
        self.assertEqual(plan.kept.get("small: kept while its job dir is"), 1)
        R.apply_scratch(plan.items, lambda: _NO_HOLDERS)
        self.assertEqual(os.listdir(os.path.join(j, "tmp")), ["pr-body.md"])


class CitedScratchTests(_FixtureTree):
    """A memory note that names a scratch path is a durable owner of it."""

    FAR = 30 * DAY

    def setUp(self):
        super().setUp()
        self.notes = os.path.join(self.tmp.name, "projects", "-home-user-dotfiles", "memory")
        os.makedirs(self.notes)
        for name in ("cass-archive-orig-0929", "sp11-sam3"):
            os.makedirs(os.path.join(self.root, name))
            Path(self.root, name, "agent_search.db").write_text("x" * 4096)

    def _note(self, name, text):
        Path(self.notes, name).write_text(text)

    def _plan(self, cc_tmpdir=NO_CC_TMPDIR):
        with _roots([self.root], self.jobs, cc_tmpdir=cc_tmpdir), \
                _patched(MEMORY_ROOT=os.path.join(self.tmp.name, "projects")):
            return R.plan_scratch(time.time() + self.FAR, _NO_HOLDERS, 72, 168)

    def test_an_entry_a_note_names_is_kept(self):
        """2026-10-25: notes named 61 candidates (24 GiB), among them the 09-29
        cass backup kept while upstream #494 is open."""
        self._note("cass-lexical-lane-down-upstream-494.md",
                   f"Backup: `{self.root}/cass-archive-orig-0929/agent_search.db` (cmp-verified).\n")
        plan = self._plan()
        self.assertEqual([os.path.basename(i["path"]) for i in plan.items], ["sp11-sam3"])
        self.assertEqual(plan.kept.get("cited by a memory note"), 1)

    def test_a_note_naming_only_a_root_or_a_project_dir_keeps_nothing(self):
        """Measured: a note that named /tmp/claude-1001 itself would have kept
        all 3,895 entries under it."""
        os.makedirs(os.path.join(self.root, "-home-user-dotfiles", "2b5a4195-acb4-41ae-a97e-89b145b9fbee"))
        self._note("toolchain.md", f"Scratch lives in {self.root}/ and {self.root}/-home-user-dotfiles .\n")
        plan = self._plan(cc_tmpdir=self.root)
        self.assertNotIn("cited by a memory note", plan.kept)
        self.assertEqual(len(plan.items), 3)

    def test_a_note_naming_a_jobs_file_keeps_the_whole_jobs_scratch(self):
        j = os.path.join(self.jobs, "e9194f0c")
        os.makedirs(os.path.join(j, "tmp", "drafts"))
        Path(j, "tmp", "drafts", "email-3.md").write_text("x")
        Path(j, "tmp", "run.log").write_text("x")
        Path(j, "state.json").write_text(json.dumps({"state": "done", "tempo": "idle"}))
        home_form = "~" + j[len(R.HOME):]
        self._note("pro-gate-can-exit-zero.md", f"Evidence: {home_form}/tmp/drafts/email-3.md\n")
        plan = self._plan()
        self.assertNotIn("job-scratch", [i["rule"] for i in plan.items])
        self.assertEqual(plan.kept.get("cited by a memory note"), 1)

    def test_an_unreadable_note_is_counted_and_the_rest_still_count(self):
        if os.geteuid() == 0:
            self.skipTest("root reads through mode 0")
        self._note("cass.md", f"{self.root}/cass-archive-orig-0929\n")
        self._note("locked.md", "x")
        os.chmod(os.path.join(self.notes, "locked.md"), 0)
        plan = self._plan()
        self.assertEqual(plan.evidence.get("memory notes unreadable"), 1)
        self.assertEqual(plan.kept.get("cited by a memory note"), 1)


class DockerMountTests(_FixtureTree):
    """Containers run as another uid, so the procfs walk cannot see what they
    hold; their bind mounts are asked of docker itself."""

    FAR = 30 * DAY

    def setUp(self):
        super().setUp()
        for name in ("sbl-stacks", "sp11-sam3"):
            os.makedirs(os.path.join(self.root, name, "supabase"))
            Path(self.root, name, "supabase", "otp.html").write_text("x" * 4096)

    def _docker(self, mounts=(), ps_rc=0, ps_err="", inspect_rc=0, inspect_err=""):
        """A stand-in docker CLI: `ps` answers with one id per container, or
        fails as given; `inspect` prints one Mounts JSON list per container."""
        d = os.path.join(self.tmp.name, "fake-docker")
        os.makedirs(d, exist_ok=True)
        Path(d, "ps.out").write_text("".join(f"c{n}\n" for n in range(len(mounts))))
        Path(d, "ps.err").write_text(ps_err)
        Path(d, "inspect.out").write_text("".join(json.dumps(m) + "\n" for m in mounts))
        Path(d, "inspect.err").write_text(inspect_err)
        script = Path(d, "docker")
        script.write_text(f'#!/bin/sh\nif [ "$1" = ps ]; then cat "{d}/ps.out"; cat "{d}/ps.err" >&2; '
                          f'exit {ps_rc}; fi\ncat "{d}/inspect.out"; cat "{d}/inspect.err" >&2; exit {inspect_rc}\n')
        script.chmod(0o755)
        return str(script)

    def _bind(self, source):
        return [{"Type": "bind", "Source": source, "Destination": "/etc/templates/otp.html"}]

    def _plan(self, docker):
        with _roots([self.root], self.jobs), _patched(DOCKER=docker):
            return R.plan_scratch(time.time() + self.FAR, _NO_HOLDERS, 72, 168)

    @staticmethod
    def _names(plan):
        return sorted(os.path.basename(i["path"]) for i in plan.items)

    def test_a_bind_mounted_entry_is_kept(self):
        """2026-10-25: exited Supabase stacks bind-mounted /tmp/sbl-stacks/*."""
        docker = self._docker([self._bind(os.path.join(self.root, "sbl-stacks", "supabase", "otp.html")),
                               [{"Type": "volume", "Source": os.path.join(self.root, "sp11-sam3")}]])
        plan = self._plan(docker)
        self.assertEqual(self._names(plan), ["sp11-sam3"])
        self.assertEqual(plan.kept.get("bind-mounted into a docker container"), 1)
        self.assertEqual(plan.evidence.get("docker"), "2 container(s) asked")

    def test_a_mount_into_a_jobs_tmp_keeps_the_job(self):
        """2026-10-25: 71 mounts from running containers pointed into 1aa97e5f's tmp/."""
        j = os.path.join(self.jobs, "1aa97e5f")
        os.makedirs(os.path.join(j, "tmp", "purchase-stack", "supabase"))
        Path(j, "tmp", "purchase-stack", "supabase", "otp.html").write_text("x")
        Path(j, "state.json").write_text(json.dumps({"state": "done", "tempo": "idle"}))
        plan = self._plan(self._docker([self._bind(os.path.join(j, "tmp", "purchase-stack", "supabase"))]))
        self.assertNotIn("job-scratch", [i["rule"] for i in plan.items])
        self.assertEqual(plan.kept.get("bind-mounted into a docker container"), 1)

    def test_a_mount_of_a_whole_root_keeps_everything_under_it(self):
        plan = self._plan(self._docker([self._bind(self.root)]))
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("bind-mounted into a docker container"), 2)

    def test_no_daemon_means_no_containers(self):
        plan = self._plan(self._docker(ps_rc=1, ps_err="Cannot connect to the Docker daemon at "
                                                      "unix:///var/run/docker.sock. Is the docker daemon running?\n"))
        self.assertEqual(self._names(plan), ["sbl-stacks", "sp11-sam3"])
        self.assertEqual(plan.evidence.get("docker"), "no daemon")

    def test_a_docker_that_cannot_answer_keeps_everything(self):
        plan = self._plan(self._docker(ps_rc=1, ps_err="permission denied while trying to connect\n"))
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("docker mounts unknown"), 2)

    def test_a_container_removed_between_ps_and_inspect_still_lets_the_rest_answer(self):
        docker = self._docker([self._bind(os.path.join(self.root, "sbl-stacks"))],
                              inspect_rc=1, inspect_err="Error: No such object: c9\n")
        self.assertEqual(self._names(self._plan(docker)), ["sp11-sam3"])

    def test_an_inspect_that_fails_otherwise_keeps_everything(self):
        docker = self._docker([self._bind(os.path.join(self.root, "sbl-stacks"))],
                              inspect_rc=1, inspect_err="error during connect: EOF\n")
        plan = self._plan(docker)
        self.assertEqual(plan.items, [])
        self.assertEqual(plan.kept.get("docker mounts unknown"), 2)


class MainScratchTests(_FixtureTree):
    """End to end through main(): pressure picks the floor, plan mode removes nothing."""

    def setUp(self):
        super().setUp()
        d = os.path.join(self.root, "two-days-idle")
        os.makedirs(d)
        Path(d, "venv.bin").write_text("x" * 4096)
        self.later = str(time.time() + 2 * DAY)

    def _main(self, *argv):
        saved = R.RULES
        # Residue rules name real host paths; an --apply here must touch only fixtures.
        R.RULES = []
        try:
            with _roots([self.root], self.jobs), \
                    contextlib.redirect_stdout(io.StringIO()) as buf:
                rc = R.main(list(argv))
        finally:
            R.RULES = saved
        return rc, buf.getvalue()

    def _scratch_names(self, out):
        doc = json.loads(out)
        return doc, [os.path.basename(i["path"]) for i in doc["actionable"]
                     if i["rule"] == "tmp-scratch"]

    def test_floors_tighten_as_free_space_falls(self):
        """Acceptance (#2002): one 2-day-idle entry waits at normal pressure
        (168h floor) and is reclaimable at critical pressure (24h floor)."""
        doc, names = self._scratch_names(self._main("--json", "--now", self.later, "--free-gb", "500")[1])
        self.assertEqual((doc["scratch"]["pressure"], names), ("normal", []))
        doc, names = self._scratch_names(self._main("--json", "--now", self.later, "--free-gb", "30")[1])
        self.assertEqual((doc["scratch"]["pressure"], names), ("critical", ["two-days-idle"]))
        self.assertTrue(os.path.isdir(os.path.join(self.root, "two-days-idle")),
                        "plan mode removes nothing")

    def test_apply_removes_scratch_and_reports_measured_free_space(self):
        rc, out = self._main("--apply", "--now", self.later, "--free-gb", "30")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(os.path.join(self.root, "two-days-idle")))
        self.assertIn("freed (df)", out)
        self.assertIn("reclaim-flagged:1", out)

    def test_the_text_report_lists_the_largest_and_sums_the_rest(self):
        """The first host plan found 276,128 items, and harness-weekly pastes
        this report whole: list the largest, name what is not listed."""
        for name in ("small-a", "small-b"):
            os.makedirs(os.path.join(self.root, name))
        with _patched(SHOW_SCRATCH_ITEMS=1):
            _, out = self._main("--now", self.later, "--free-gb", "30")
        listed = [ln for ln in out.splitlines() if "tmp-scratch" in ln]
        self.assertEqual(len(listed), 1, out)
        self.assertIn("two-days-idle", listed[0])
        self.assertIn("in 2 smaller scratch item(s) not listed", out)
        self.assertIn("reclaim-flagged:3", out)

    def test_the_report_says_what_it_asked_and_read(self):
        """A keep that rests on docker or on the notes is only as good as the
        answer; the report says which answer it got."""
        doc = json.loads(self._main("--json", "--now", self.later, "--free-gb", "30")[1])
        self.assertEqual(doc["scratch"]["evidence"],
                         {"docker": "not installed", "memory notes read": 0, "memory notes unreadable": 0,
                          "git": "0 tree(s) asked, 0 verdict(s) remembered"})
        _, out = self._main("--now", self.later, "--free-gb", "30")
        self.assertIn("scratch evidence: docker not installed; 0 memory note(s) read, 0 unreadable; "
                      "git: 0 tree(s) asked, 0 verdict(s) remembered", out)

    def test_json_never_leaks_private_recheck_fields(self):
        doc = json.loads(self._main("--json", "--now", self.later, "--free-gb", "30")[1])
        for item in doc["actionable"]:
            self.assertFalse([k for k in item if k.startswith("_")], item)


if __name__ == "__main__":
    unittest.main()
