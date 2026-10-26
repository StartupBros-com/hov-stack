#!/usr/bin/env python3
"""Tests for reclaim-sweep.py.

The dangerous failure for a sweeper is not "missed something" — it is "deleted
something live". Every test here is a refusal test except the ones proving it
still finds real residue.
"""

import contextlib
import importlib.util
import io
import os
import subprocess
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


class _NoHolders:
    """Liveness stub for rule-mechanics tests: nothing is ever held."""
    ok = True

    def holder(self, _path):
        return None


class _DeadSnapshot:
    """Liveness stub for the fail-closed test: the scan could not answer."""
    ok = False

    def holder(self, _path):
        return None


_NO_HOLDERS = _NoHolders()


def _scratch_root() -> str:
    """A scratch parent under $HOME, deep enough to clear is_safe_target."""
    root = os.path.join(R.HOME, ".cache", "reclaim-sweep-tests")
    os.makedirs(root, exist_ok=True)
    return root


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
            concrete = rule.pattern.replace("*", "x")
            self.assertTrue(
                R.is_safe_target(concrete),
                f"rule {rule.name} could resolve to an unsafe depth: {rule.pattern}",
            )

    def test_every_rule_has_an_age_floor(self):
        for rule in R.RULES:
            self.assertGreaterEqual(rule.min_age_days, 14, f"{rule.name} age floor too low")

    def test_every_rule_explains_itself(self):
        for rule in R.RULES:
            self.assertTrue(rule.why, f"{rule.name} has no rationale")

    def test_rule_names_are_unique(self):
        names = [r.name for r in R.RULES]
        self.assertEqual(len(names), len(set(names)))


if __name__ == "__main__":
    unittest.main()
