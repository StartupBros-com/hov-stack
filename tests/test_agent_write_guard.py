#!/usr/bin/env python3
"""Tests for agent-write-guard.py.

The fixtures below are VERBATIM from the 2026-08-06 incident (openai/codex#28224
shape, reproduced locally by our own orphaned broker), so a regression here means
the guard would miss the exact event it was written for.
"""

import contextlib
import importlib.util
import io
import re
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
GUARD = CLAUDE / "scripts" / "agent-write-guard.py"

_spec = importlib.util.spec_from_file_location("agent_write_guard_module", GUARD)
G = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(G)


# The real cmdline of the broker that ran orphaned for 15 days and wrote ~400 GiB.
# Its --cwd worktree had already been removed by wt-sweep.
REAL_LEAK = (
    "/home/user/.local/share/mise/installs/node/24.12.0/bin/node "
    "/home/user/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/app-server-broker.mjs "
    "serve --endpoint unix:/tmp/cxc-gOhtgd/broker.sock "
    "--cwd /nonexistent/SITES/acme-app/.claude/worktrees/agent-a9de979ef74101af2 "
    "--pid-file /tmp/cxc-gOhtgd/broker.pid"
)

# First draft of the guard flagged this: a `bash -c` wrapper whose SCRIPT BODY
# quotes a --cwd path. It is not a daemon and must not be reported.
SHELL_WRAPPER_FALSE_POSITIVE = (
    "/bin/bash -c source /home/user/.claude/shell-snapshots/snap.sh 2>/dev/null || true "
    "&& export CODEX_COMPANION_SESSION_ID='6aff955e-x' "
    "&& eval 'cd --cwd /nonexistent/jobs/50993da2/tmp/atomic-supabase-v2'"
)

HEALTHY_DAEMON = "/home/user/.config/better-ccflare/better-ccflare-v3.5.44 --serve --port 8789"


class OrphanDetectionTests(unittest.TestCase):
    def test_flags_the_real_leaked_broker(self):
        """The regression that matters: this exact process burned ~400 GiB unnoticed."""
        self.assertEqual(
            G.is_orphan_candidate(REAL_LEAK),
            "/nonexistent/SITES/acme-app/.claude/worktrees/agent-a9de979ef74101af2",
        )

    def test_ignores_shell_wrapper_quoting_a_cwd_flag(self):
        self.assertIsNone(G.is_orphan_candidate(SHELL_WRAPPER_FALSE_POSITIVE))

    def test_ignores_healthy_daemon_with_no_cwd_flag(self):
        self.assertIsNone(G.is_orphan_candidate(HEALTHY_DAEMON))

    def test_ignores_daemon_whose_cwd_still_exists(self):
        cmd = f"node app-server-broker.mjs serve --cwd {CLAUDE}"
        self.assertIsNone(G.is_orphan_candidate(cmd))

    def test_ignores_non_agent_process(self):
        self.assertIsNone(G.is_orphan_candidate("/usr/bin/rsync --cwd /nonexistent/x"))

    def test_strips_shell_quoting_from_the_captured_path(self):
        cmd = "node app-server-broker.mjs serve --cwd '/nonexistent/quoted-path'"
        self.assertEqual(G.is_orphan_candidate(cmd), "/nonexistent/quoted-path")


class ChurnSignatureTests(unittest.TestCase):
    def test_detects_the_observed_incident_ratio(self):
        """Measured on the live box: 1,000 retained rows, max rowid 2,653,846,524."""
        self.assertEqual(G.churn_severity(1_000, 2_653_846_524, 337 * 1024 * 1024), "crit")

    def test_healthy_db_is_clean(self):
        """codex 0.145.0's own DB on the same box: 3,382 rows / 171,709 rowids."""
        self.assertIsNone(G.churn_severity(3_382, 171_709, 13 * 1024 * 1024))

    def test_large_but_unchurned_db_is_only_a_warning(self):
        self.assertEqual(G.churn_severity(1_000_000, 1_200_000, 512 * 1024 * 1024), "warn")

    def test_empty_table_does_not_divide_by_zero(self):
        self.assertIsNone(G.churn_severity(0, 0, 1024))


class VersionGateTests(unittest.TestCase):
    def test_flags_the_build_that_actually_leaked(self):
        self.assertLess(G.parse_version("@openai+codex@0.142.5-linux-x64"), G.CODEX_FIXED)

    def test_accepts_the_fixed_build(self):
        self.assertGreaterEqual(G.parse_version("@openai+codex@0.145.0"), G.CODEX_FIXED)

    def test_fix_boundary_is_inclusive(self):
        self.assertGreaterEqual(G.parse_version("codex@0.143.0"), G.CODEX_FIXED)

    def test_unparseable_returns_none(self):
        self.assertIsNone(G.parse_version("codex-nightly"))


class ZombieUnitTests(unittest.TestCase):
    """The second orphan: onwatch ran 10 days with its unit disabled AND inactive."""

    # Real `systemctl --user show -p ExecStart -p ActiveState onwatch.service` shape.
    SHOW = (
        "ExecStart={ path=/home/op/.onwatch/bin/onwatch ; argv[]=/home/op/.onwatch/bin/onwatch "
        "--debug ; ignore_errors=no }\nActiveState=inactive\n"
    )

    def test_extracts_full_argv_not_just_binary(self):
        self.assertEqual(
            G.unit_exec_cmd(self.SHOW), "/home/op/.onwatch/bin/onwatch --debug"
        )

    def test_newer_systemd_indexed_form(self):
        s = ("ExecStart[0]={ path=/usr/bin/foo ; argv[]=/usr/bin/foo --serve }\n"
             "ActiveState=inactive\n")
        self.assertEqual(G.unit_exec_cmd(s), "/usr/bin/foo --serve")

    def test_returns_none_when_absent(self):
        self.assertIsNone(G.unit_exec_cmd("ActiveState=active\n"))

    def test_bare_interpreter_is_rejected_as_unmatchable(self):
        """The 5-to-1 false-positive bug: a unit starting bare /usr/bin/python3
        matched every unrelated python process on the box."""
        for interp in ("/usr/bin/python3", "/bin/sh", "/usr/bin/ssh", "/usr/bin/node"):
            s = f"ExecStart={{ path={interp} ; argv[]={interp} }}\nActiveState=inactive\n"
            self.assertIsNone(G.unit_exec_cmd(s), f"{interp} should be rejected")

    def test_interpreter_with_real_args_is_kept(self):
        s = ("ExecStart={ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 -m mytool --serve }\n"
             "ActiveState=inactive\n")
        self.assertEqual(G.unit_exec_cmd(s), "/usr/bin/python3 -m mytool --serve")

    def test_check_runs_without_raising(self):
        """Must degrade quietly on hosts with no systemd rather than crash the guard."""
        self.assertIsInstance(G.check_zombie_units(), list)

    def test_cgroup_identifies_the_supervising_unit(self):
        """The misdiagnosis: a disabled USER unit shadowed an active SYSTEM unit
        whose ExecStart was a wrapper that exec'd the real binary, so argv
        cross-referencing could not connect them. The cgroup can."""
        self.assertEqual(
            G.parse_cgroup("0::/system.slice/onwatch.service\n"), "onwatch.service"
        )

    def test_cgroup_of_a_user_scope_unit(self):
        self.assertEqual(
            G.parse_cgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/foo.service\n"),
            "foo.service",
        )

    def test_orphan_in_init_scope_has_no_supervisor(self):
        """WSL reparents orphans into /init.scope — the real leaked-daemon shape."""
        self.assertIsNone(G.parse_cgroup("0::/init.scope\n"))

    def test_bare_session_scope_has_no_supervisor(self):
        self.assertIsNone(G.parse_cgroup("0::/user.slice/user-1000.slice/session-3.scope\n"))


class PortabilityTests(unittest.TestCase):
    """The guard is meant to be published; it must not be wired to one operator's box."""

    def test_no_hardcoded_operator_paths_in_source(self):
        src = GUARD.read_text()
        # Any named profile under a Linux or Windows home root, not one
        # operator's: /home/<name> and /mnt/c/Users/<name> stay out of the
        # source entirely (a docstring's /mnt/c/Users/<name> is not a name).
        hit = re.search(r"(?:/home|/mnt/c/Users)/[A-Za-z][\w.-]*", src)
        self.assertIsNone(hit, f"hardcoded operator path {hit and hit.group(0)!r} would break for anyone else")

    def test_log_db_globs_are_rooted_in_the_current_home(self):
        pats = G.log_db_globs()
        self.assertTrue(any(p.startswith(str(Path.home())) for p in pats))

    def test_windows_homes_excludes_system_profiles(self):
        for p in G.windows_homes():
            self.assertNotIn(Path(p).name, ("Public", "Default", "All Users"))

    def test_codex_pkg_roots_are_deduped_and_exist(self):
        roots = G.codex_pkg_roots()
        self.assertEqual(len(roots), len(set(roots)))
        for r in roots:
            self.assertTrue(Path(r).is_dir())

    def test_ps_snapshot_returns_pid_ppid_cmd_triples(self):
        rows = G._ps_snapshot()
        self.assertTrue(rows, "no processes found — snapshot is broken")
        pid, ppid, cmd = rows[0]
        self.assertTrue(pid.isdigit() and ppid.isdigit())
        self.assertIsInstance(cmd, str)


class ReaperDetectionTests(unittest.TestCase):
    def test_pid_1_is_always_a_reaper(self):
        """WSL reparents to /init, so the set must be discovered, but 1 is the floor."""
        self.assertIn("1", G.reaper_pids())


class ExitContractTests(unittest.TestCase):
    def test_skip_rate_run_returns_an_int_exit_code(self):
        """harness-doctor consumes the exit code; it must never raise."""
        # Swallow the report: this suite runs inside `unittest discover`, and a
        # findings dump on stdout buries the test summary it shares a stream with.
        with contextlib.redirect_stdout(io.StringIO()):
            rc = G.main(["--skip-rate", "--json"])
        self.assertIn(rc, (0, 1))


if __name__ == "__main__":
    unittest.main()
