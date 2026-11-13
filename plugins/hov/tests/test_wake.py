"""Tests for idle wake (hov-stack#529, PR 4): the Stop hook's `hov wake` watcher.

Every watcher here runs the way Claude Code runs it. A fake Claude Code process (a Python whose process name is a
Claude Code version, as the native installer's is) runs the Stop command from hooks.json through `sh -c`, with the
hook's JSON on stdin. So the shell wrapper, the walk up to the session's process, the version and print-mode gates
and the exit-code mapping are the shipped ones. Nothing here talks to a model; the live runs are recorded in the PR.
Linux only, like the watcher.

Run: python3 -m unittest discover -s plugins/hov/tests -v
"""

import importlib.util
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

from test_hov import HOV, SID_A, SID_B, SID_C, HovFixture

ROOT = HOV.parents[1]
BODY = "wake-body-that-must-never-be-shown-91c2"
SUBJECT = "wake-subject-not-shown-5d0e"

# A fake Claude Code: runs the plugin's hooks as Claude Code does (`sh -c` the command, JSON on stdin), all from
# this one process, so a hook's walk up the process tree ends here. argv's last item is the plan, a JSON list of steps:
# a hook to run (a Stop hook runs in the background, and this process exits with its code), a file to wait for, or
# a file to create.
FAKE_CLAUDE = r'''
import json, os, subprocess, sys, time
hooks = json.load(open(os.path.join(os.environ["CLAUDE_PLUGIN_ROOT"], "hooks", "hooks.json")))["hooks"]
bg, held = None, []
for step in json.loads(sys.argv[-1]):
    if "wait_for" in step:
        end = time.monotonic() + 15
        while not os.path.exists(step["wait_for"]) and time.monotonic() < end:
            time.sleep(0.01)
        continue
    if "touch" in step:
        open(step["touch"], "w").close()
        continue
    cmd = hooks[step["event"]][0]["hooks"][0]["command"]
    p = subprocess.Popen(["/bin/sh", "-c", cmd], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    p.stdin.write(json.dumps(step["payload"]).encode())
    p.stdin.flush()
    if step.get("hold_stdin"):
        held.append(p.stdin)
    else:
        p.stdin.close()
    if step["event"] == "Stop":
        bg = p
    else:
        p.wait()
sys.exit(bg.wait() if bg else 0)
'''


def proc_start(pid):
    """A process's start time from /proc, the field the watcher stamps next to its session's pid."""
    raw = Path(f"/proc/{pid}/stat").read_text()
    return int(raw.rpartition(")")[2].split()[19])


@unittest.skipUnless(Path("/proc/self/stat").exists(), "idle wake reads /proc (Linux only)")
class WakeCase(HovFixture):
    def setUp(self):
        super().setUp()
        tmp = Path(self.tmp.name)
        self.bin = tmp / "bin"
        self.bin.mkdir()
        self.fake = tmp / "fake_claude.py"
        self.fake.write_text(FAKE_CLAUDE)
        self.env.update({
            "CLAUDE_PLUGIN_ROOT": str(ROOT),
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "HOV_WAKE_TICK_MS": "20",
            "HOV_WAKE_TTL_S": "30",
        })
        self.procs = []

    def tearDown(self):
        for p in self.procs:  # each fake session leads its own process group, its watcher included
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            if p.stderr is not None and not p.stderr.closed:
                p.communicate()
            else:
                p.wait()
        super().tearDown()

    # ------------------------------------------------------------ helpers

    def claude(self, steps, version="2.1.323", print_mode=False, env_extra=None):
        exe = self.bin / version
        if not exe.exists():
            exe.symlink_to(sys.executable)
        env = dict(self.env)
        env.update(env_extra or {})
        argv = [str(exe), "-I", str(self.fake), *(["-p"] if print_mode else []), json.dumps(steps)]
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                             text=True, env=env, start_new_session=True)
        self.procs.append(p)
        return p

    def stop(self, sid=SID_A, **kw):
        payload = {"session_id": sid, "cwd": "/tmp/x", "hook_event_name": "Stop",
                   "permission_mode": "bypassPermissions", "stop_hook_active": False}
        return {"event": "Stop", "payload": payload, **kw}

    def arm(self, sid=SID_A, env_extra=None, **kw):
        """A fake session whose Stop hook runs the watcher, returned once the watcher has armed."""
        n = self.count("wake-arm")
        p = self.claude([self.stop(sid, **kw)], env_extra=env_extra)
        self.wait_until(lambda: self.count("wake-arm") > n, "the watcher armed")
        return p

    def log(self):
        path = self.state / "hov.log"
        return path.read_text() if path.exists() else ""

    def count(self, what):
        return self.log().count(what)

    def wait_until(self, pred, what, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting until {what}\n{self.log()}")

    def finish(self, p, timeout=15):
        """(exit code, stderr) of a fake session: its Stop hook's code, as Claude Code would see it."""
        try:
            _, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            self.fail(f"the watcher was still running after {timeout}s\n{self.log()}")
        return p.returncode, err

    def assert_waiting(self, p, seconds=0.5):
        """The watcher had `seconds` of 20 ms ticks to see what was sent before this, and did not wake."""
        fired = self.count("wake-fire")
        time.sleep(seconds)
        self.assertIsNone(p.poll(), self.log())
        self.assertEqual(self.count("wake-fire"), fired)

    def wake_file(self, sid):
        return self.state / "wake" / sid

    def send(self, to, body="x", *args, sender="carol"):
        self.hov("send", "--as", sender, "--to", to, *args, body)

    # ------------------------------------------------------------ waking

    def test_direct_mail_wakes_the_idle_session_once_with_a_count_and_no_body(self):
        p = self.arm()
        self.assertTrue(self.wake_file(SID_A).exists())
        self.send("alpha", BODY, "--subject", SUBJECT, sender="beta")
        rc, err = self.finish(p)
        self.assertEqual(rc, 2, err)  # `hov wake` exits 86, and the hook's wrapper turns that into the 2 that wakes
        self.assertIn('mode="wake"', err)
        self.assertIn('count="1"', err)
        self.assertIn("from testhost:beta", err)
        self.assertIn("No user is waiting on this turn", err)
        self.assertNotIn(BODY, err)
        self.assertNotIn(SUBJECT, err)
        self.assertFalse(self.wake_file(SID_A).exists())
        self.assertEqual(self.count("wake-fire"), 1)
        # The next idle spell's watcher is not woken again for the same message.
        p = self.arm(env_extra={"HOV_WAKE_TTL_S": "1"})
        self.assertEqual(self.finish(p), (0, ""))
        self.assertEqual(self.count("wake-expired"), 1)
        self.assertEqual(self.count("wake-fire"), 1)
        # The wake neither handed the message over nor marked it read: the woken turn's prompt hook delivers it.
        ctx = self.hook("UserPromptSubmit", SID_A)["hookSpecificOutput"]["additionalContext"]
        self.assertIn(BODY, ctx)

    def test_only_direct_mail_from_another_agent_wakes(self):
        p = self.arm()
        self.send("*", "everyone")
        self.send("testhost:*", "this host")
        self.send("alpha", "fyi", "--importance", "low")
        self.send("alpha", "progress", "--kind", "status")
        self.send("alpha", "note to self", sender="alpha")
        self.send("beta", "not yours")
        self.assert_waiting(p)
        self.send("alpha", "now this", "--importance", "high")
        rc, err = self.finish(p)
        self.assertEqual(rc, 2, err)
        self.assertIn('count="1"', err)
        self.assertIn("from testhost:carol", err)

    def test_mail_already_read_or_handed_over_does_not_wake(self):
        self.send("alpha", "read in the inbox")
        self.hov("inbox", "--as", "alpha")
        self.send("alpha", "handed over as a count")
        ctx = self.hook("UserPromptSubmit", SID_A, permission_mode="bypassPermissions")["hookSpecificOutput"]["additionalContext"]
        self.assertIn("(1 new, from testhost:carol)", ctx)
        p = self.arm(env_extra={"HOV_WAKE_TTL_S": "1"})
        self.assertEqual(self.finish(p), (0, ""))
        self.assertEqual(self.count("wake-expired"), 1)
        self.assertEqual(self.count("wake-fire"), 0)

    def test_the_watcher_arms_when_its_runner_leaves_stdin_open(self):
        t = time.monotonic()
        p = self.arm(hold_stdin=True)
        self.assertLess(time.monotonic() - t, 4, "it read the payload without waiting for EOF")
        self.send("alpha")
        self.assertEqual(self.finish(p)[0], 2)

    def test_only_the_watchers_own_exit_code_wakes_the_session(self):
        """An argparse error (2) from a script that has no `wake`, a crash (1) or nothing (0) must not wake anyone."""
        stop = json.loads((ROOT / "hooks" / "hooks.json").read_text())["hooks"]["Stop"][0]["hooks"][0]["command"]
        for code, want in ((86, 2), (2, 0), (1, 0), (0, 0)):
            root = Path(self.tmp.name) / f"stub{code}"
            (root / "scripts").mkdir(parents=True)
            (root / "scripts" / "hov").write_text(f"import sys\nsys.exit({code})\n")
            res = subprocess.run(["/bin/sh", "-c", stop], env={**self.env, "CLAUDE_PLUGIN_ROOT": str(root)},
                                 capture_output=True, text=True, timeout=30)
            self.assertEqual(res.returncode, want, (code, res.stderr))

    # ------------------------------------------------------------ bounds

    def test_no_watcher_where_a_wake_could_not_end_cleanly(self):
        """Each of these would leave a watcher holding a turn open or looping a print run: none arms, none waits."""
        for what, kw in (
            ("an entrypoint other than cli", {"env_extra": {"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"}}),
            ("HOV_WAKE=0", {"env_extra": {"HOV_WAKE": "0"}}),
            ("claude -p", {"print_mode": True}),
            ("a Claude Code older than 2.1.319", {"version": "2.1.300"}),
        ):
            with self.subTest(what):
                self.assertEqual(self.finish(self.claude([self.stop()], **kw), timeout=10), (0, ""))
        with self.subTest("a session id that is not a plain file name"):
            self.assertEqual(self.finish(self.claude([self.stop("../escape")]), timeout=10), (0, ""))
        with self.subTest("a parent that is not Claude Code"):
            res = self.hov("wake", stdin=json.dumps(self.stop()["payload"]))
            self.assertEqual((res.returncode, res.stderr), (0, ""))
        log = self.log()
        self.assertEqual(log.count("wake-arm"), 0, log)
        self.assertIn("claude=2.1.300", log)
        self.assertIn("claude=unknown", log)
        self.assertFalse((self.state / "wake").exists())

    def test_the_hourly_cap_and_the_cooldown_hold_wakes_back(self):
        p = self.arm(env_extra={"HOV_WAKE_CAP": "0", "HOV_WAKE_TTL_S": "2"})
        self.send("alpha", "one")
        self.assertEqual(self.finish(p), (0, ""))
        self.assertEqual(self.count("wake-spent"), 1)
        self.assertEqual(self.count("wake-fire"), 0)
        once = {"HOV_WAKE_CAP": "1", "HOV_WAKE_COOLDOWN_S": "0"}
        p = self.arm(env_extra=once)  # "one" is still pending, so this watcher wakes at once
        rc, err = self.finish(p)
        self.assertEqual(rc, 2, err)
        p = self.arm(env_extra={**once, "HOV_WAKE_TTL_S": "2"})
        self.send("alpha", "two")
        self.assertEqual(self.finish(p), (0, ""))
        self.assertEqual(self.count("wake-spent"), 2)
        self.assertEqual(self.count("wake-fire"), 1)

    def test_a_wake_held_by_the_cooldown_and_then_a_lock_fires_once_both_clear(self):
        p = self.arm()
        self.send("alpha", "first")
        first = time.monotonic()
        self.assertEqual(self.finish(p)[0], 2)
        p = self.arm(env_extra={"HOV_WAKE_COOLDOWN_S": "3"})
        self.send("alpha", "second")
        con = sqlite3.connect(self.state / "mail.db", isolation_level=None, timeout=10)
        con.execute("BEGIN IMMEDIATE")
        try:
            # The cooldown ends about 3 s after the first wake; the lock outlasts it, so the watcher's claims fail.
            while time.monotonic() < first + 5.5:
                self.assertIsNone(p.poll(), self.log())
                time.sleep(0.05)
            self.assertEqual(self.count("wake-fire"), 1)
        finally:
            con.rollback()
            con.close()
        rc, err = self.finish(p)
        self.assertEqual(rc, 2, err)
        self.assertEqual(self.count("wake-fire"), 2)
        self.assertNotIn("wake-error", self.log())

    def load(self):
        spec = importlib.util.spec_from_loader("hov_wake_under_test", SourceFileLoader("hov_wake_under_test", str(HOV)))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_wake_budget_per_hour_and_per_day_and_a_clock_step_back_adds_no_wake(self):
        self.send("alpha", "creates the mailbox")
        knobs = {"HOV_STATE_DIR": str(self.state), "HOV_HOST": "testhost",
                 "HOV_WAKE_COOLDOWN_S": "30", "HOV_WAKE_CAP": "2", "HOV_WAKE_DAY_CAP": "3"}
        with mock.patch.dict(os.environ, knobs):
            mod = self.load()
            clock = [10**12]
            mod.now_ms = lambda: clock[0]
            t0, s, h = clock[0], 1000, 3_600_000

            def at(ms):
                clock[0] = t0 + ms
                con = mod.db()
                try:
                    return mod.wake_budget(con, SID_A, clock[0])
                finally:
                    con.close()

            def claim(ms, mid):
                clock[0] = t0 + ms
                return [r["id"] for r in mod.claim_wake(SID_A, [{"id": mid}])]

            self.assertEqual(at(0), ("ok", 0))
            self.assertEqual(claim(0, "m1"), ["m1"])
            self.assertEqual(at(10 * s), ("wait", 20 * s))
            self.assertEqual(claim(10 * s, "m2"), [], "a claim inside the cooldown takes nothing")
            self.assertEqual(claim(31 * s, "m1"), [], "nor does one for a message that already woke the session")
            self.assertEqual(claim(31 * s, "m2"), ["m2"])
            self.assertEqual(at(62 * s), ("spent", h - 62 * s))
            self.assertEqual(at(h + 1 * s), ("ok", 0))
            self.assertEqual(claim(h + 1 * s, "m3"), ["m3"])
            self.assertEqual(at(h + 32 * s), ("spent", 24 * h - (h + 32 * s)))  # the day's third, with two left this hour
            self.assertEqual(at(24 * h), ("ok", 0))
            self.assertEqual(at(-5 * s), ("wait", 30 * s), "a clock that stepped back is inside the cooldown")
            os.environ["HOV_WAKE_COOLDOWN_S"] = "0"
            self.assertEqual(at(-5 * s), ("spent", 24 * h), "and inside the day, whose wakes are used")
            os.environ["HOV_WAKE_DAY_CAP"] = "0"
            self.assertEqual(at(24 * h)[0], "spent")
            con = mod.db()
            try:
                rows = con.execute("SELECT msg_id FROM wakes ORDER BY msg_id").fetchall()
                budget = con.execute("SELECT window_n, day_n FROM wake_budget WHERE session_id=?", (SID_A,)).fetchone()
            finally:
                con.close()
        self.assertEqual([r[0] for r in rows], ["m1", "m2", "m3"])
        self.assertEqual(tuple(budget), (1, 3))

    # ------------------------------------------------------------ standing down

    def test_a_prompt_or_a_main_thread_tool_call_retires_the_watcher_and_a_subagent_tool_call_does_not(self):
        p = self.arm()
        self.hook("UserPromptSubmit", SID_A)
        self.assertEqual(self.finish(p), (0, ""))
        p = self.arm()
        self.hook_raw("PostToolUse", {"session_id": SID_A, "cwd": "/tmp/x", "permission_mode": "default",
                                      "hook_event_name": "PostToolUse", "tool_name": "Read",
                                      "agent_id": "a-sub-1", "agent_type": "Explore"})
        self.assert_waiting(p)
        self.hook("PostToolUse", SID_A)
        self.assertEqual(self.finish(p), (0, ""))
        older, newer = self.arm(), self.arm()
        self.assertEqual(self.finish(older), (0, ""), "a newer Stop's watcher replaces the older")
        self.assertIsNone(newer.poll())
        self.send("alpha")
        self.assertEqual(self.finish(newer)[0], 2)
        self.assertEqual(self.count("wake-fire"), 1)

    def test_a_new_session_id_in_the_same_process_retires_the_old_ids_watcher(self):
        other = self.arm(SID_B)  # another session's watcher, in another process
        mark = Path(self.tmp.name) / "compacted"
        same_id = {**self.session_start_payload(SID_A, "alpha"), "source": "compact"}
        p = self.claude([self.stop(SID_A), {"wait_for": str(self.wake_file(SID_A))},
                         {"event": "SessionStart", "payload": same_id}, {"touch": str(mark)}])
        self.wait_until(mark.exists, "the same id's SessionStart ran")
        self.assert_waiting(p, 0.2)
        self.assertTrue(self.wake_file(SID_A).exists(), "the session's own id keeps its watcher")
        self.hook("UserPromptSubmit", SID_A)
        self.assertEqual(self.finish(p), (0, ""))
        # /clear: the same process starts again under a new id, and the old id's watcher stands down.
        new_id = {**self.session_start_payload(SID_C, "gamma"), "source": "clear"}
        p = self.claude([self.stop(SID_A), {"wait_for": str(self.wake_file(SID_A))},
                         {"event": "SessionStart", "payload": new_id}])
        self.assertEqual(self.finish(p), (0, ""))
        self.assertFalse(self.wake_file(SID_A).exists())
        self.assertIsNone(other.poll(), "a watcher of another process is left alone")
        self.assertTrue(self.wake_file(SID_B).exists())
        self.send("beta")
        self.assertEqual(self.finish(other)[0], 2)

    def test_session_start_removes_the_files_of_watchers_whose_session_is_gone(self):
        wake = self.state / "wake"
        wake.mkdir(parents=True)
        (wake / "gone").write_text("1.ab 2147483647 1")  # above Linux's pid_max, so no such process
        (wake / "elsewhere").write_text(f"2.cd 1 {proc_start(1)}")  # a live process that is not this session's
        (wake / "this-process").write_text(f"3.ef {os.getpid()} {proc_start(os.getpid())}")
        (wake / SID_A).write_text(f"4.gh {os.getpid()} {proc_start(os.getpid())}")
        # `hov hook` runs as this test's child, so this test's process is the session that is starting.
        self.hook_raw("SessionStart", self.session_start_payload(SID_A, "alpha"))
        self.assertEqual(sorted(p.name for p in wake.iterdir()), sorted(["elsewhere", SID_A]))

    def test_a_watcher_whose_session_is_gone_stands_down(self):
        p = self.arm()
        os.kill(p.pid, signal.SIGKILL)  # the session alone: its watcher lives on, reparented
        p.communicate()
        self.wait_until(lambda: self.count("wake-orphan") == 1, "the watcher saw its session go")
        self.wait_until(lambda: not self.wake_file(SID_A).exists(), "it removed its file")
        self.send("alpha", "too late")
        time.sleep(0.3)
        self.assertEqual(self.count("wake-fire"), 0)

    def test_a_stop_signal_ends_the_watcher_with_no_wake_and_removes_its_file(self):
        p = self.arm()
        watcher = int(self.wake_file(SID_A).read_text().split(".")[0])  # the token starts with the watcher's pid
        os.kill(watcher, signal.SIGTERM)
        code, _ = self.finish(p)
        self.assertEqual(code, 0)  # the wrapper saw 0: no wake
        self.assertIn(f"wake-stopped session={SID_A} signal={int(signal.SIGTERM)}", self.log())
        self.assertFalse(self.wake_file(SID_A).exists())

        p = self.arm(SID_B)
        watcher = int(self.wake_file(SID_B).read_text().split(".")[0])
        os.killpg(p.pid, signal.SIGTERM)  # the whole session at once, the session process included
        p.communicate()
        self.wait_until(lambda: self.count("wake-stopped") == 2, "the watcher took the signal")
        self.wait_until(lambda: not Path(f"/proc/{watcher}").exists(), "the watcher exited")
        self.assertFalse(self.wake_file(SID_B).exists())
        self.send("alpha", "after the stop")
        time.sleep(0.3)
        self.assertEqual(self.count("wake-fire"), 0)


if __name__ == "__main__":
    unittest.main()
