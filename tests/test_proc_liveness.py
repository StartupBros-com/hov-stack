#!/usr/bin/env python3
"""Tests for lib/proc_liveness.py — the shared sweep liveness check (issue #378).

Signal coverage runs against a FAKE procfs so each signal is exercised in
isolation and deterministically; a small integration block then proves the
same answers against the real /proc with real child processes, because a fake
can drift from what the kernel actually publishes.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
LIB = CLAUDE / "scripts" / "lib" / "proc_liveness.py"

_spec = importlib.util.spec_from_file_location("proc_liveness_module", LIB)
PL = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PL)

NO_EXCLUDES = frozenset()


def _fake_proc(root: str, pid: int, cwd=None, fd_targets=(), argv=(), env=(), comm=None):
    """Materialize one /proc/<pid> entry in a fake procfs tree.

    `comm` is written only when given: an entry without one is what every
    older fake looked like, and it must keep its unfiltered meaning.
    """
    base = os.path.join(root, str(pid))
    os.makedirs(os.path.join(base, "fd"), exist_ok=True)
    if comm is not None:
        Path(os.path.join(base, "comm")).write_text(comm + "\n")
    if cwd is not None:
        os.symlink(cwd, os.path.join(base, "cwd"))
    for i, tgt in enumerate(fd_targets):
        os.symlink(tgt, os.path.join(base, "fd", str(i)))
    Path(os.path.join(base, "cmdline")).write_bytes(
        b"\0".join(a.encode() for a in argv) + (b"\0" if argv else b"")
    )
    Path(os.path.join(base, "environ")).write_bytes(
        b"\0".join(e.encode() for e in env) + (b"\0" if env else b"")
    )


class FakeProcfsSignalTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.proc = os.path.join(self._tmp.name, "proc")
        self.target = os.path.join(self._tmp.name, "target-dir")
        os.makedirs(self.proc)
        os.makedirs(self.target)

    def tearDown(self):
        self._tmp.cleanup()

    def _snap(self):
        return PL.ProcSnapshot(procfs=self.proc, exclude_pids=NO_EXCLUDES)

    def test_fd_holder_detected(self):
        _fake_proc(self.proc, 101, cwd="/", fd_targets=[os.path.join(self.target, "x.db")])
        h = self._snap().holder(self.target)
        self.assertEqual((h.signal, h.pid), ("fd", 101))

    def test_cwd_holder_detected(self):
        """THE #378 gap: cwd inside the target, no fd, no argv mention."""
        _fake_proc(self.proc, 102, cwd=self.target, argv=["sleep", "30"])
        h = self._snap().holder(self.target)
        self.assertEqual((h.signal, h.pid), ("cwd", 102))

    def test_cwd_below_target_counts(self):
        sub = os.path.join(self.target, "deep", "er")
        os.makedirs(sub)
        _fake_proc(self.proc, 103, cwd=sub)
        self.assertIsNotNone(self._snap().holder(self.target))

    def test_cmdline_holder_detected(self):
        """The 2026-08-06 shape: path appears only as a --cwd flag in argv."""
        _fake_proc(self.proc, 104, cwd="/", argv=["daemon", "--cwd", self.target])
        h = self._snap().holder(self.target)
        self.assertEqual((h.signal, h.pid), ("cmdline", 104))

    def test_environ_holder_detected(self):
        """The idle-background-job shape (#378's concrete trigger): the job dir
        lives ONLY in the process environment (CLAUDE_JOB_DIR), no fd between
        writes, cwd elsewhere, argv silent."""
        _fake_proc(self.proc, 107, cwd="/", argv=["claude"],
                   env=[f"CLAUDE_JOB_DIR={self.target}", "TERM=xterm"])
        h = self._snap().holder(self.target)
        self.assertEqual((h.signal, h.pid), ("environ", 107))

    def test_unheld_path_is_not_flagged(self):
        _fake_proc(self.proc, 105, cwd="/", fd_targets=["/var/log/x"], argv=["sleep", "1"])
        self.assertIsNone(self._snap().holder(self.target))

    def test_sibling_prefix_is_not_inside(self):
        """/x/target-dir2 must not read as inside /x/target-dir."""
        sibling = self.target + "2"
        os.makedirs(sibling)
        _fake_proc(self.proc, 106, cwd=sibling, fd_targets=[os.path.join(sibling, "f")])
        self.assertIsNone(self._snap().holder(self.target))

    def test_own_pid_is_excluded_by_default(self):
        """The checker's own argv names the queried path; it must not self-match."""
        _fake_proc(self.proc, os.getpid(), cwd="/", argv=["checker", self.target])
        snap = PL.ProcSnapshot(procfs=self.proc)  # default excludes os.getpid()
        self.assertIsNone(snap.holder(self.target))
        self.assertTrue(snap.ok, "an excluded pid still counts as scanned")

    def test_comm_filter_counts_only_the_named_program(self):
        """wt-unlock asks "is a git on this gitdir", not "is anything" (#1590)."""
        _fake_proc(self.proc, 201, cwd=self.target, comm="bash")
        _fake_proc(self.proc, 202, cwd=self.target, comm="git")
        snap = self._snap()
        self.assertIn(snap.holder(self.target).pid, (201, 202),
                      "unfiltered: either process counts; procfs order is not pinned")
        self.assertEqual(snap.holder(self.target, comm="git").pid, 202)
        self.assertIsNone(snap.holder(self.target, comm="python3"))

    def test_comm_filter_applies_to_every_signal(self):
        held = os.path.join(self.target, "x.db")
        _fake_proc(self.proc, 211, cwd="/", fd_targets=[held], comm="bash")
        _fake_proc(self.proc, 212, cwd="/", argv=["x", self.target], comm="bash")
        _fake_proc(self.proc, 213, cwd="/", env=["D=" + self.target], comm="bash")
        snap = self._snap()
        self.assertIsNotNone(snap.holder(self.target))
        self.assertIsNone(snap.holder(self.target, comm="git"))

    def test_comm_filter_never_matches_a_process_without_comm(self):
        """An unreadable comm cannot satisfy a filter; without one it still counts."""
        _fake_proc(self.proc, 221, cwd=self.target)
        self.assertIsNone(self._snap().holder(self.target, comm="git"))
        self.assertIsNotNone(self._snap().holder(self.target))

    def test_empty_procfs_is_not_ok(self):
        self.assertFalse(self._snap().ok)

    def test_unreadable_procfs_is_not_ok(self):
        snap = PL.ProcSnapshot(procfs=os.path.join(self._tmp.name, "absent"),
                               exclude_pids=NO_EXCLUDES)
        self.assertFalse(snap.ok)


class HeldChildrenTests(unittest.TestCase):
    """held_children(root) is holder() inverted for a 283k-entry /tmp (#2002).

    Its whole safety argument is that it says "held" for every child holder()
    would, so the core test is that property over a fake procfs built to hit
    each signal and each matching edge, not a handful of hand-picked answers.
    """

    NAMES = ["foo", "foobar", "fo", "bar", "deep", "job", "baz qux", "cold", "x (deleted)"]

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = self._tmp.name
        self.proc = os.path.join(base, "proc")
        self.root = os.path.join(base, "scratch")
        self.link = os.path.join(base, "scratch-link")
        os.makedirs(self.proc)
        for n in self.NAMES:
            os.makedirs(os.path.join(self.root, n))
        os.symlink(self.root, self.link)
        r = self.root
        _fake_proc(self.proc, 301, cwd="/", fd_targets=[f"{r}/foobar/held.db"])
        _fake_proc(self.proc, 302, cwd=f"{r}/deep/er")
        # environ names the job dir itself — the CLAUDE_JOB_DIR shape
        _fake_proc(self.proc, 303, cwd="/", env=[f"CLAUDE_JOB_DIR={r}/job", "TERM=x"])
        # argv substring: "{r}/fo" is inside "{r}/foo-other", so holder() calls
        # "fo" held too; the batch form must not be stricter than that
        _fake_proc(self.proc, 304, cwd="/", argv=["tool", f"--out={r}/foo-other/x"])
        # raw (unresolved) spelling through a symlinked root, environ only
        _fake_proc(self.proc, 305, cwd="/", env=[f"D={self.link}/baz qux"])
        # a deleted-file fd target and a holder of the root itself, not a child
        _fake_proc(self.proc, 306, cwd=r, fd_targets=[f"{r}/x (deleted)"])
        # /var<root>/bar contains "<root>/bar" as a substring
        _fake_proc(self.proc, 307, cwd="/", argv=["cat", f"/var{r}/bar/f"])

    def tearDown(self):
        self._tmp.cleanup()

    def _snap(self):
        return PL.ProcSnapshot(procfs=self.proc, exclude_pids=NO_EXCLUDES)

    def test_agrees_with_holder_for_every_child(self):
        snap = self._snap()
        for root in (self.root, self.link):
            batch = snap.held_children(root)
            for name in self.NAMES:
                single = snap.holder(os.path.join(root, name))
                self.assertEqual(name in batch, single is not None,
                                 f"{root}/{name}: batch={batch.get(name)} holder={single}")

    def test_the_fixture_exercises_both_answers(self):
        """The property above is vacuous if every child were held or none were."""
        batch = self._snap().held_children(self.root)
        self.assertIn("job", batch)
        self.assertNotIn("cold", batch)

    def test_reports_the_signal_that_held_it(self):
        batch = self._snap().held_children(self.root)
        self.assertEqual(batch["foobar"], PL.Holder("fd", 301))
        self.assertEqual(batch["deep"], PL.Holder("cwd", 302))
        self.assertEqual(batch["job"], PL.Holder("environ", 303))

    def test_holding_the_root_holds_no_child(self):
        """cwd AT the root (every shell in /tmp) must not pin all of /tmp."""
        batch = self._snap().held_children(self.root)
        self.assertNotIn("", batch)
        self.assertNotIn("cold", batch)


class CliContractTests(unittest.TestCase):
    """Exit codes are the bash callers' entire interface: 0 held, 1 not, 2 error."""

    def _run(self, *args):
        return subprocess.run([sys.executable, str(LIB), *args],
                              capture_output=True, text=True)

    def test_held_path_exits_0_and_names_the_holder(self):
        with tempfile.TemporaryDirectory() as d:
            proc = os.path.join(d, "proc"); os.makedirs(proc)
            tgt = os.path.join(d, "t"); os.makedirs(tgt)
            _fake_proc(proc, 201, cwd=tgt)
            r = self._run("--procfs", proc, "--", tgt)
            self.assertEqual(r.returncode, 0)
            self.assertIn("cwd", r.stdout)

    def test_unheld_path_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            proc = os.path.join(d, "proc"); os.makedirs(proc)
            _fake_proc(proc, 202, cwd="/")
            tgt = os.path.join(d, "t"); os.makedirs(tgt)
            r = self._run("--procfs", proc, "--", tgt)
            self.assertEqual(r.returncode, 1)

    def test_comm_filter_on_the_cli(self):
        with tempfile.TemporaryDirectory() as d:
            proc = os.path.join(d, "proc"); os.makedirs(proc)
            tgt = os.path.join(d, "t"); os.makedirs(tgt)
            _fake_proc(proc, 231, cwd=tgt, comm="git")
            r = self._run("--procfs", proc, "--comm", "git", "--", tgt)
            self.assertEqual(r.returncode, 0)
            self.assertIn("pid:231", r.stdout)
            r = self._run("--procfs", proc, "--comm", "bash", "--", tgt)
            self.assertEqual(r.returncode, 1)

    def test_answerless_scan_exits_2_not_1(self):
        """A scan that saw nothing must ERROR — the fail-closed contract."""
        with tempfile.TemporaryDirectory() as d:
            proc = os.path.join(d, "proc"); os.makedirs(proc)
            tgt = os.path.join(d, "t"); os.makedirs(tgt)
            r = self._run("--procfs", proc, "--", tgt)
            self.assertEqual(r.returncode, 2)


class RealProcIntegrationTests(unittest.TestCase):
    """The fake can drift from the kernel; prove each signal on the real /proc."""

    def _wait_for(self, predicate, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            got = predicate()
            if got:
                return got
            time.sleep(0.1)
        return predicate()

    def test_child_cwd_holder(self):
        with tempfile.TemporaryDirectory() as d:
            child = subprocess.Popen(["sleep", "30"], cwd=d)
            try:
                h = self._wait_for(lambda: PL.ProcSnapshot().holder(d))
                self.assertIsNotNone(h)
                self.assertEqual((h.signal, h.pid), ("cwd", child.pid))
            finally:
                child.kill(); child.wait()

    def test_child_environ_holder(self):
        with tempfile.TemporaryDirectory() as d:
            env = {k: v for k, v in os.environ.items() if d not in v}
            env["PROBE_JOB_DIR"] = d
            child = subprocess.Popen(["sleep", "30"], cwd="/", env=env)
            try:
                h = self._wait_for(lambda: PL.ProcSnapshot().holder(d))
                self.assertIsNotNone(h)
                self.assertEqual((h.signal, h.pid), ("environ", child.pid))
            finally:
                child.kill(); child.wait()

    def test_child_cmdline_holder(self):
        with tempfile.TemporaryDirectory() as d:
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)", "--cwd", d], cwd="/")
            try:
                h = self._wait_for(lambda: PL.ProcSnapshot().holder(d))
                self.assertIsNotNone(h)
                self.assertEqual((h.signal, h.pid), ("cmdline", child.pid))
            finally:
                child.kill(); child.wait()

    def test_child_fd_holder(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "held.log"), "w") as fh:
                child = subprocess.Popen(["sleep", "30"], cwd="/", stdout=fh)
            try:
                h = self._wait_for(lambda: PL.ProcSnapshot().holder(d))
                self.assertIsNotNone(h)
                self.assertEqual((h.signal, h.pid), ("fd", child.pid))
            finally:
                child.kill(); child.wait()

    def test_child_comm_filter_on_real_proc(self):
        """The kernel's comm is the basename of the executable, newline-terminated."""
        with tempfile.TemporaryDirectory() as d:
            child = subprocess.Popen(["sleep", "30"], cwd=d)
            try:
                got = self._wait_for(lambda: PL.ProcSnapshot().holder(d, comm="sleep"))
                self.assertEqual((got.signal, got.pid), ("cwd", child.pid))
                self.assertIsNone(PL.ProcSnapshot().holder(d, comm="git"))
            finally:
                child.kill(); child.wait()

    def test_gone_child_no_longer_holds(self):
        with tempfile.TemporaryDirectory() as d:
            child = subprocess.Popen(["sleep", "30"], cwd=d)
            child.kill()
            child.wait()  # reaped -> its /proc entry is gone
            self.assertIsNone(PL.ProcSnapshot().holder(d))


if __name__ == "__main__":
    unittest.main()
