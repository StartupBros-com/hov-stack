"""Tests for what hov needs from the host it runs on (0.1.6): a mailbox other local users cannot read, and one
clear error when this Python or its SQLite cannot run hov. Stdlib unittest only.

Run: python3 -m unittest discover -s plugins/hov/tests -v
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

from test_hov import HOV, SID_A, HovFixture

FTS5_MISSING = "hov needs an SQLite with FTS5"


def mode(p: Path) -> int:
    return stat.S_IMODE(os.stat(p).st_mode)


def load_hov(tag: str):
    spec = importlib.util.spec_from_loader(tag, SourceFileLoader(tag, str(HOV)))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def prompt_payload(event: str) -> str:
    return json.dumps({"session_id": SID_A, "cwd": "/tmp/x", "permission_mode": "default", "hook_event_name": event})


@unittest.skipUnless(os.name == "posix", "file modes are POSIX")
class StateModes(HovFixture):
    """The default mailbox folder, `$XDG_STATE_HOME/hov`, under the common umask 022."""

    def setUp(self):
        super().setUp()
        self.old_umask = os.umask(0o022)  # subprocesses inherit it
        self.xdg = Path(self.tmp.name) / "xdg"
        self.box = self.xdg / "hov"
        self.default_env = {k: v for k, v in self.env.items() if k != "HOV_STATE_DIR"}
        self.default_env["XDG_STATE_HOME"] = str(self.xdg)

    def tearDown(self):
        os.umask(self.old_umask)
        super().tearDown()

    def run_default(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
        res = subprocess.run([sys.executable, "-I", str(HOV), *args], input=stdin, capture_output=True, text=True,
                             env=self.default_env)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stderr, "")
        return res

    def test_a_new_mailbox_is_private(self):
        """Before 0.1.6 the folder came out 0755 and mail.db and hov.log 0644: any local user could read the mail."""
        self.run_default("send", "--as", "ceo", "--to", "alpha", "x")
        out = self.run_default("hook", "UserPromptSubmit", stdin=prompt_payload("UserPromptSubmit")).stdout
        self.assertIn("<hov-mail", out, "it delivered, so it also wrote the log")
        self.assertEqual(mode(self.box), 0o700)
        self.assertEqual(mode(self.box / "mail.db"), 0o600)
        self.assertEqual(mode(self.box / "hov.log"), 0o600)

    def test_the_wal_and_shm_files_of_an_open_mailbox_are_private_too(self):
        """SQLite creates `-wal` and `-shm` itself, with the database file's mode. They exist only while a
        connection is open, so this holds hov's own connection open after a write and looks at them."""
        mod = load_hov("hov_under_test_wal_modes")
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(self.xdg)}):
            os.environ.pop("HOV_STATE_DIR", None)
            con = mod.db()
            try:
                with con:
                    con.execute("CREATE TABLE IF NOT EXISTS mode_probe(x)")
                    con.execute("INSERT INTO mode_probe(x) VALUES (1)")
                for f in ("mail.db", "mail.db-wal", "mail.db-shm"):
                    self.assertEqual(mode(self.box / f), 0o600, f)
            finally:
                con.close()

    def test_a_looser_mailbox_from_an_older_version_is_narrowed_by_the_next_hook(self):
        """Shaped like a 0.1.5 host while a session has the mailbox open: folder 0755, every file 0644, `-wal` and
        `-shm` present. One tool hook narrows all of them, exits 0 and prints nothing to stderr."""
        self.run_default("send", "--as", "ceo", "--to", "alpha", "x")
        db_file = self.box / "mail.db"
        reader = sqlite3.connect(db_file)  # holds -wal and -shm open, as a running session does
        try:
            reader.execute("SELECT count(*) FROM messages").fetchone()
            (self.box / "hov.log").touch()
            os.chmod(self.box, 0o755)
            files = [self.box / f for f in ("mail.db", "mail.db-wal", "mail.db-shm", "hov.log")]
            for f in files:
                self.assertTrue(f.exists(), f)
                os.chmod(f, 0o644)
            self.run_default("hook", "PostToolUse", stdin=prompt_payload("PostToolUse"))
            self.assertEqual(mode(self.box), 0o700)
            for f in files:
                self.assertEqual(mode(f), 0o600, f.name)
        finally:
            reader.close()

    def test_a_folder_named_by_HOV_STATE_DIR_keeps_its_mode_and_its_files_are_narrowed(self):
        """A folder the user named may be shared or watched on purpose, so hov leaves its mode alone."""
        self.state.mkdir()
        os.chmod(self.state, 0o755)
        self.hov("send", "--as", "ceo", "--to", "alpha", "x")
        self.assertEqual(mode(self.state), 0o755)
        self.assertEqual(mode(self.state / "mail.db"), 0o600)

    def test_a_mode_it_cannot_change_never_fails_the_hook(self):
        """A file it cannot chmod (say, owned by another user) is left as it is, and the hook carries on."""
        self.run_default("send", "--as", "ceo", "--to", "alpha", "x")
        os.chmod(self.box / "mail.db", 0o644)
        mod = load_hov("hov_under_test_chmod_refused")
        refused = PermissionError(1, "Operation not permitted")
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, self.default_env, clear=True), \
                mock.patch.object(mod.os, "chmod", side_effect=refused), \
                mock.patch.object(sys, "stdin", io.StringIO(prompt_payload("PostToolUse"))), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mod.main(["hook", "PostToolUse"])
        self.assertEqual((rc, err.getvalue()), (0, ""))
        self.assertEqual(mode(self.box / "mail.db"), 0o644)


class RequirementErrors(HovFixture):
    """What a host whose Python or SQLite cannot run hov sees. Simulated: no Python older than 3.9 or SQLite
    without FTS5 is at hand, so these patch the version check or the database open, in process."""

    def setUp(self):
        super().setUp()
        self.mod = load_hov("hov_under_test_requirements")
        patcher = mock.patch.dict(os.environ, self.env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_main(self, argv: list[str], stdin: str = "") -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(stdin)), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            rc = self.mod.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def test_missing_fts5_is_one_clear_line_at_session_start_and_quiet_after(self):
        """`no such module: fts5` is what SQLite raises when the schema's FTS5 table cannot be created. Claude Code
        shows a SessionStart hook's exit 1 as a hook error with the first stderr line, so that line names the fix.
        The prompt and tool hooks log it and stay quiet, so the session gets one notice, not one per tool call."""
        boom = sqlite3.OperationalError("no such module: fts5")
        with mock.patch.object(self.mod, "db", side_effect=boom):
            rc, out, err = self.run_main(["hook", "SessionStart"], json.dumps(self.session_start_payload(SID_A, "alpha")))
            self.assertEqual((rc, out), (1, ""))
            lines = err.splitlines()
            self.assertEqual(len(lines), 1, err)
            self.assertTrue(lines[0].startswith(FTS5_MISSING), err)
            self.assertIn(sqlite3.sqlite_version, lines[0])
            self.assertIn("first on PATH", lines[0])
            for event in ("UserPromptSubmit", "PostToolUse"):
                self.assertEqual(self.run_main(["hook", event], prompt_payload(event)), (0, "", ""))
            self.assertEqual((self.state / "hov.log").read_text().count(FTS5_MISSING), 3)
            rc, out, err = self.run_main(["inbox", "--as", "alpha"])
            self.assertEqual(rc, 1)
            self.assertTrue(err.startswith(FTS5_MISSING), err)
            res = self.mod.McpServer("codex").handle("tools/call", {"name": "inbox", "arguments": {}})
            self.assertTrue(res["isError"])
            self.assertTrue(res["content"][0]["text"].startswith(f"inbox: {FTS5_MISSING}"), res)

    def test_an_ordinary_database_error_keeps_its_old_handling(self):
        """Only an FTS5 error is a requirement problem; a locked or full database is still logged by the hook."""
        boom = sqlite3.OperationalError("database is locked")
        with mock.patch.object(self.mod, "db", side_effect=boom):
            self.assertEqual(self.run_main(["hook", "SessionStart"], json.dumps(self.session_start_payload(SID_A, "alpha"))),
                             (0, "", ""))
            rc, _, err = self.run_main(["inbox", "--as", "alpha"])
            self.assertEqual((rc, err), (1, "hov: database error: database is locked\n"))

    def test_a_python_older_than_3_9_is_named(self):
        self.assertIsNone(self.mod.python_problem())
        self.assertIsNone(self.mod.python_problem((3, 9, 6)))
        why = self.mod.python_problem((3, 8, 10))
        self.assertIn("Python 3.9 or newer", why)
        self.assertIn("is 3.8", why)
        with mock.patch.object(self.mod, "python_problem", return_value=why):
            rc, out, err = self.run_main(["hook", "SessionStart"], json.dumps(self.session_start_payload(SID_A, "alpha")))
            self.assertEqual((rc, out, err), (1, "", why + "\n"))
            self.assertEqual(self.run_main(["hook", "PostToolUse"], prompt_payload("PostToolUse")), (0, "", ""))

    def test_the_stop_hooks_watcher_exits_0_with_nothing_on_stderr_whatever_cannot_run(self):
        """`hov wake` is the `Stop` hook's watcher (0.1.7). An old Python, an SQLite without FTS5 and an ordinary
        database error each leave it at exit 0 with empty stdout and stderr and one `wake-error` log line, so a host
        that cannot run hov shows no hook error at every turn's end and wakes nothing."""
        log = self.state / "hov.log"
        why = self.mod.python_problem((3, 8, 10))
        with mock.patch.object(self.mod, "python_problem", return_value=why):
            self.assertEqual(self.run_main(["wake"]), (0, "", ""))
        self.assertEqual(log.read_text().count(f"wake-error err={why}"), 1)
        for boom, logged in ((sqlite3.OperationalError("no such module: fts5"), FTS5_MISSING),
                             (sqlite3.OperationalError("database is locked"), "database is locked")):
            with self.subTest(err=str(boom)), mock.patch.object(self.mod, "cmd_wake", side_effect=boom):
                self.assertEqual(self.run_main(["wake"]), (0, "", ""))
                self.assertEqual(log.read_text().count(f"wake-error err={logged}"), 1)


@unittest.skipUnless(os.path.exists("/bin/sh") and os.path.exists("/bin/cat"), "runs the hook commands under /bin/sh")
class HookCommandsWithoutPython(unittest.TestCase):
    """The commands in hooks.json, run the way Claude Code runs them (`sh -c`, with CLAUDE_PLUGIN_ROOT set), on a
    host with no `python3` on PATH. Without a guard each one exited 127 with `python3: not found`, which Claude Code
    shows as a hook error on every prompt and every tool call. SessionStart now names the problem once and the prompt
    and tool hooks stay quiet, the way `cannot_run` treats an old Python. The Stop command already exits 0."""

    ROOT = HOV.parents[1]
    EVENTS = ("SessionStart", "UserPromptSubmit", "PostToolUse")

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        hooks = json.loads((self.ROOT / "hooks" / "hooks.json").read_text())["hooks"]
        self.commands = {ev: hooks[ev][0]["hooks"][0]["command"] for ev in self.EVENTS}

    def run_hook(self, event: str, path: Path, stdin: str = "") -> subprocess.CompletedProcess:
        env = {"PATH": str(path), "CLAUDE_PLUGIN_ROOT": str(self.ROOT)}
        return subprocess.run(["/bin/sh", "-c", self.commands[event]], input=stdin, capture_output=True, text=True,
                              env=env, timeout=10)

    def test_no_python3_on_path_is_one_line_at_session_start_and_quiet_after(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        res = self.run_hook("SessionStart", empty)
        self.assertEqual((res.returncode, res.stdout), (1, ""), res.stderr)
        lines = res.stderr.splitlines()
        self.assertEqual(len(lines), 1, res.stderr)
        self.assertTrue(lines[0].startswith("hov needs Python 3.9 or newer"), res.stderr)
        self.assertIn("python3", lines[0])
        self.assertIn("PATH", lines[0])
        for event in ("UserPromptSubmit", "PostToolUse"):
            with self.subTest(event=event):
                res = self.run_hook(event, empty)
                self.assertEqual((res.returncode, res.stdout, res.stderr), (0, "", ""))

    def test_with_python3_on_path_each_command_still_runs_hov_hook_with_its_input(self):
        """A stub `python3` that prints its arguments and then its stdin shows the guarded command still hands the
        event to `python3 -I <root>/scripts/hov hook <Event>` and passes the hook payload through."""
        bindir = self.tmp / "bin"
        bindir.mkdir()
        stub = bindir / "python3"
        stub.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\nexec /bin/cat\n")
        stub.chmod(0o755)
        for event in self.EVENTS:
            with self.subTest(event=event):
                res = self.run_hook(event, bindir, stdin='{"payload": 1}')
                self.assertEqual((res.returncode, res.stderr), (0, ""))
                self.assertEqual(res.stdout, "\n".join(["-I", str(self.ROOT / "scripts" / "hov"), "hook", event])
                                 + '\n{"payload": 1}')


if __name__ == "__main__":
    unittest.main()
