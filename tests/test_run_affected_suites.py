#!/usr/bin/env python3
"""Hermetic tests for scripts/run-affected-suites.py (dotfiles#1586).

A scratch repository carries a CI workflow fragment, and fake suites that record every invocation,
so each case proves what the runner executed, not only what it printed.
"""

from __future__ import annotations

import os
import re
import runpy
import shutil
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

import yaml

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parents[0]
RUNNER = REPO_ROOT / "scripts" / "run-affected-suites.py"
RUNNER_MODULE = runpy.run_path(str(RUNNER))

WORKFLOW = """\
name: CI
jobs:
  core:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
      - name: third party
        uses: example/tool@v1
      - name: provision a tool (never run locally)
        run: sudo apt-get install -y nothing
      - name: gamma
        if: ${{ !cancelled() }}
        run: bash tests/gamma.test.sh
      - name: alpha
        env:
          ALPHA_MARK: "from-step-env"
        run: bash tests/alpha.test.sh
      - name: beta
        working-directory: tests
        run: bash beta.test.sh
      - name: multi
        run: |
          set -euo pipefail
          bash tests/multi.test.sh
      - name: delta
        run: bash tests/delta.test.sh && sudo -n true
      - name: push only
        if: github.event_name == 'push'
        run: bash tests/push.test.sh
"""

STEP_INDENT = "      "


def write(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if mode is not None:
        path.chmod(mode)


def process_gone(pid: int, seconds: float = 3.0) -> bool:
    """True once the pid is unknown or a zombie (killed, reaping pending)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        try:
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        except OSError:
            return True
        if state == "Z":
            return True
        time.sleep(0.05)
    return False


def read_pid(path: Path, seconds: float = 10.0) -> int:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            text = path.read_text().strip()
        except OSError:
            text = ""
        if text:
            return int(text)
        time.sleep(0.05)
    raise AssertionError(f"{path} never carried a pid")


class ScratchRepo:
    def __init__(self, root: Path):
        self.root = root
        self.scratch_dirs: set[Path] = set()
        self.calls = root / "calls.log"
        write(root / ".github" / "workflows" / "ci.yml", WORKFLOW)
        for name in ("alpha", "beta", "multi", "delta", "gamma"):
            write(root / "scripts" / f"{name}.sh", "#!/usr/bin/env bash\n")
        write(
            root / "tests" / "alpha.test.sh",
            f'#!/usr/bin/env bash\necho "alpha ran env=${{ALPHA_MARK:-unset}} cwd=$PWD" >> "{self.calls}"\nexit 0\n',
        )
        write(
            root / "tests" / "beta.test.sh",
            f'#!/usr/bin/env bash\necho "beta ran cwd=$PWD" >> "{self.calls}"\necho "BETA_FAILURE_MARKER: planted" >&2\nexit 3\n',
        )
        for name in ("multi", "delta", "gamma"):
            write(
                root / "tests" / f"{name}.test.sh",
                f'#!/usr/bin/env bash\necho "{name} ran" >> "{self.calls}"\nexit 0\n',
            )
        write(root / "docs" / "notes.md", "notes\n")
        write(root / "README.md", "fixture readme\n")
        # A fake sudo on PATH records any provisioning attempt.
        self.bin = root / "fakebin"
        self.sudo_calls = root / "sudo.log"
        write(
            self.bin / "sudo",
            f'#!/usr/bin/env bash\necho "sudo $*" >> "{self.sudo_calls}"\nexit 0\n',
            0o755,
        )

    def args(self, *extra: str, lint: bool = False) -> list[str]:
        args = [
            "python3",
            str(RUNNER),
            "--repo",
            str(self.root),
            "--jobs",
            "2",
        ]
        if not lint:
            args.append("--no-lint")
        return args + list(extra)

    def env(self) -> dict:
        env = dict(os.environ)
        # A fenced fix session runs this file with CLAUDE_LOOP_GUARD=1, which
        # stops the runner under test from recording (dotfiles#1618). The
        # fixture keeps CI's shape; the guarded case sets the guard itself.
        env.pop("CLAUDE_LOOP_GUARD", None)
        env["PATH"] = f"{self.bin}:{env.get('PATH', '')}"
        return env

    def run(self, *extra: str, lint: bool = False) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            self.args(*extra, lint=lint),
            cwd=self.root,
            env=self.env(),
            capture_output=True,
            text=True,
            check=False,
        )
        self.track_scratch(proc.stdout)
        return proc

    def track_scratch(self, output: str) -> Path | None:
        for line in output.splitlines():
            if line.startswith("running ") and "; logs under " in line:
                scratch = Path(line.split("; logs under ", 1)[1])
                assert scratch.parent == Path("/tmp")
                assert scratch.name.startswith("run-affected-suites.")
                self.scratch_dirs.add(scratch)
                return scratch
        return None

    def cleanup_scratch(self) -> None:
        # Only directories named by our own runner subprocesses, never a glob.
        for scratch in self.scratch_dirs:
            if scratch.is_dir():
                shutil.rmtree(scratch)

    def calls_text(self) -> str:
        return self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""

    def edit_workflow(self, old: str, new: str) -> None:
        wf = self.root / ".github" / "workflows" / "ci.yml"
        text = wf.read_text(encoding="utf-8")
        assert old in text, old
        wf.write_text(text.replace(old, new), encoding="utf-8")

    def append_steps(self, steps_yaml: str) -> None:
        wf = self.root / ".github" / "workflows" / "ci.yml"
        wf.write_text(
            wf.read_text(encoding="utf-8")
            + textwrap.indent(textwrap.dedent(steps_yaml), STEP_INDENT),
            encoding="utf-8",
        )

    def keep_steps(self, *names: str) -> None:
        wf = self.root / ".github/workflows/ci.yml"
        text = wf.read_text()
        starts = list(re.finditer(r"^      - ", text, re.M))
        chunks = []
        for i, match in enumerate(starts):
            chunk = text[
                match.start() : starts[i + 1].start()
                if i + 1 < len(starts)
                else len(text)
            ]
            st = yaml.safe_load(chunk)[0]
            if st.get("name") in names or st.get("uses", "").startswith("actions/"):
                chunks.append(chunk)
        wf.write_text(text[: starts[0].start()] + "".join(chunks))

    def init_git(self) -> None:
        def git(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(
                ["git", *args],
                cwd=self.root,
                check=True,
                capture_output=True,
                text=True,
            )

        git("init", "-q", "-b", "main")
        git("-c", "user.email=t@example.com", "-c", "user.name=t", "add", ".")
        git(
            "-c",
            "user.email=t@example.com",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "-m",
            "base",
        )


class RunAffectedSuitesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(
            prefix="run-affected-suites-test.", dir="/tmp"
        )
        self.repo = ScratchRepo(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.repo.cleanup_scratch()
        self.tmp.cleanup()

    def test_a_passing_run_removes_only_its_own_scratch(self) -> None:
        self.repo.keep_steps("alpha", "gamma")
        before = set(Path("/tmp").glob("run-affected-suites.*"))
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        scratch = self.repo.track_scratch(proc.stdout)
        self.assertIsNotNone(scratch, proc.stdout)
        after = set(Path("/tmp").glob("run-affected-suites.*"))
        # Concurrent runs may create other directories; check this run's own.
        self.assertNotIn(scratch, before)
        self.assertNotIn(scratch, after - before)
        self.assertFalse(scratch.exists())

    def test_keep_scratch_preserves_logs_on_a_passing_run(self) -> None:
        self.repo.keep_steps("alpha", "gamma")
        proc = self.repo.run("--keep-scratch")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        scratch = self.repo.track_scratch(proc.stdout)
        self.assertIsNotNone(scratch, proc.stdout)
        self.assertTrue(scratch.is_dir())
        self.assertEqual(len(list(scratch.glob("*.log"))), 2)

    def test_default_timeout_is_1800_and_help_documents_it(self) -> None:
        self.assertEqual(RUNNER_MODULE["parse_args"]([]).timeout, 1800)
        proc = self.repo.run("--help")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("seconds per suite (default: 1800)", proc.stdout)
        self.assertIn("--keep-scratch", proc.stdout)

    def test_a_failing_suite_fails_the_run_and_its_output_is_shown(self) -> None:
        self.repo.keep_steps("beta", "gamma")
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("BETA_FAILURE_MARKER: planted", proc.stdout)
        self.assertIn("FAIL", proc.stdout)
        scratch = self.repo.track_scratch(proc.stdout)
        self.assertIsNotNone(scratch, proc.stdout)
        self.assertTrue(scratch.is_dir())
        log = next(scratch.glob("*beta.test.sh.log"))
        self.assertIn(str(log), proc.stdout)
        self.assertIn("BETA_FAILURE_MARKER: planted", log.read_text())
        # working-directory from the CI step is honoured
        self.assertIn(
            "beta ran cwd=" + str(self.repo.root / "tests"), self.repo.calls_text()
        )

    def test_a_pipeline_fails_as_it_would_under_ci_s_shell(self) -> None:
        # CI runs a run: step under `bash -eo pipefail`; a suite piped into a
        # pager-like consumer must still fail the run, not take cat's status
        self.repo.keep_steps("beta", "gamma")
        self.repo.edit_workflow(
            "run: bash beta.test.sh", "run: bash beta.test.sh | cat"
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("FAIL", proc.stdout)
        self.assertIn("beta ran", self.repo.calls_text())

    def test_a_multi_line_ci_step_is_reported_not_run(self) -> None:
        self.repo.keep_steps("multi", "gamma")
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            "not run locally: set -euo pipefail (multi-line CI step)", proc.stdout
        )
        self.assertNotIn("multi ran", self.repo.calls_text())

    def test_a_single_line_step_that_hands_off_to_sudo_or_actions_is_reported_not_run(
        self,
    ) -> None:
        self.repo.keep_steps("delta", "gamma")
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn(
            "not run locally: bash tests/delta.test.sh && sudo", proc.stdout
        )
        self.assertNotIn("delta ran", self.repo.calls_text())
        self.assertFalse(self.repo.sudo_calls.exists(), "the fake sudo recorded a call")
        # the same for a $GITHUB_* handoff, which only CI can satisfy
        self.repo.edit_workflow(
            "bash tests/delta.test.sh && sudo -n true",
            'bash tests/delta.test.sh "$GITHUB_OUTPUT"',
        )
        proc = self.repo.run()
        self.assertIn(
            'not run locally: bash tests/delta.test.sh "$GITHUB_OUTPUT" (CI step uses $GITHUB_)',
            proc.stdout,
        )
        self.assertNotIn("delta ran", self.repo.calls_text())

    def test_everything_reported_is_not_a_pass(self) -> None:
        # The workflow has two multi-line steps and lint is off,
        # and the exit must be 3, never 0.
        self.repo.keep_steps("multi", "gamma")
        self.repo.edit_workflow(
            "run: bash tests/gamma.test.sh",
            "run: |\n              set -e\n              bash tests/gamma.test.sh",
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertIn("nothing runnable on this host", proc.stdout)
        self.assertIn(
            "not run locally: set -euo pipefail (multi-line CI step)", proc.stdout
        )
        # Every unrun step is listed by its first run line;
        # a provisioning step (sudo, apt-get, an installer) is CI's own
        self.assertIn(
            "not run locally: set -e (multi-line CI step)",
            proc.stdout,
        )
        self.assertNotIn("provision a tool", proc.stdout)
        self.assertEqual(self.repo.calls_text(), "")

    def test_suites_run_under_ci_s_umask(self) -> None:
        # dotfiles#1598: CI creates files under umask 022; a group-writable
        # host default (0002) reds suites that refuse group-writable parents.
        self.repo.keep_steps("alpha", "gamma")
        test = self.repo.root / "tests" / "alpha.test.sh"
        test.write_text(
            '#!/usr/bin/env bash\n[ "$(umask)" = 0022 ] || { echo "UMASK_MARKER: $(umask)"; exit 1; }\n',
            encoding="utf-8",
        )
        proc = subprocess.run(
            self.repo.args(),
            cwd=self.repo.root,
            env=self.repo.env(),
            capture_output=True,
            text=True,
            check=False,
            preexec_fn=lambda: os.umask(0o002),
        )
        self.repo.track_scratch(proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("UMASK_MARKER", proc.stdout)

    def test_a_suite_reading_ci_exported_env_is_reported_not_run(self) -> None:
        # dotfiles#1598: a step appending to $GITHUB_ENV is CI's own; a suite
        # reading what it exports would run here without it and read red.
        self.repo.keep_steps("alpha", "gamma")
        self.repo.append_steps(
            """\
            - name: Prepare alpha reader
              run: |
                printf '%s\\n' "ALPHA_READER_BIN=/opt/alpha" >> "$GITHUB_ENV"
            """
        )
        test = self.repo.root / "tests" / "alpha.test.sh"
        test.write_text(
            test.read_text(encoding="utf-8") + "# reads ALPHA_READER_BIN\n",
            encoding="utf-8",
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("2 not run locally", proc.stdout)
        self.assertIn(
            "not run locally: bash tests/alpha.test.sh (needs ALPHA_READER_BIN, which CI step 'Prepare alpha reader' exports; not set here)",
            proc.stdout,
        )
        self.assertNotIn("alpha ran", self.repo.calls_text())
        # Set on this host, the suite runs as CI would run it.
        proc = subprocess.run(
            self.repo.args(),
            cwd=self.repo.root,
            env={**self.repo.env(), "ALPHA_READER_BIN": "/opt/alpha"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.repo.track_scratch(proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("alpha ran", self.repo.calls_text())

    def test_a_step_env_with_an_actions_expression_is_reported_not_run(self) -> None:
        self.repo.keep_steps("alpha", "gamma")
        self.repo.edit_workflow(
            'ALPHA_MARK: "from-step-env"', "ALPHA_MARK: ${{ secrets.MARK }}"
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            "not run locally: bash tests/alpha.test.sh (step env ALPHA_MARK uses an Actions expression)",
            proc.stdout,
        )
        self.assertNotIn("alpha ran", self.repo.calls_text())

    def test_lint_commands_are_taken_from_the_workflow_text(self) -> None:
        # a bash -n loop and a shellcheck line, in the workflow's own shape;
        # the operand lists reach the plan verbatim and shellcheck runs alone
        self.repo.keep_steps("alpha", "gamma")
        self.repo.append_steps(
            """\
            - name: Shell syntax check (bash -n)
              run: |
                set -euo pipefail
                for f in scripts/*.sh; do
                  bash -n "$f"
                done
            - name: Shellcheck (errors only)
              run: |
                if ! command -v shellcheck >/dev/null 2>&1; then
                  sudo apt-get install -y shellcheck
                fi
                shellcheck -S error scripts/*.sh
            """
        )
        # a fake shellcheck on PATH records its operands instead of linting
        sc_calls = self.repo.root / "shellcheck.log"
        write(
            self.repo.bin / "shellcheck",
            f'#!/usr/bin/env bash\necho "shellcheck $*" >> "{sc_calls}"\nexit 0\n',
            0o755,
        )
        proc = self.repo.run(lint=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        # the glob is the workflow's; bash expands it at run time, as on CI
        self.assertIn(
            "shellcheck -S error scripts/alpha.sh scripts/beta.sh scripts/delta.sh scripts/gamma.sh scripts/multi.sh",
            sc_calls.read_text(encoding="utf-8"),
        )
        self.assertIn("  bash -n", proc.stdout)
        self.assertIn("  shellcheck", proc.stdout)
        # the lint steps were consumed, not listed as unrun
        self.assertNotIn("not run locally: Shell syntax check", proc.stdout)
        self.assertNotIn("not run locally: Shellcheck", proc.stdout)
        self.assertFalse(
            self.repo.sudo_calls.exists(),
            "the provisioning preamble of the shellcheck step must never run",
        )
        # dry-run shows the operand list came from the workflow, not a copy
        proc = self.repo.run("--dry-run", lint=True)
        self.assertIn(
            'would run: bash -n: for f in scripts/*.sh; do bash -n "$f" || exit 1; done',
            proc.stdout,
        )

    def test_a_timed_out_suite_is_killed_with_its_children(self) -> None:
        # the suite backgrounds a sleeper that would outlive a plain kill of bash
        self.repo.keep_steps("alpha", "gamma")
        slow = self.repo.root / "tests" / "alpha.test.sh"
        slow.write_text(
            f'#!/usr/bin/env bash\necho "alpha ran" >> "{self.repo.calls}"\nsleep 30 & echo $! > "{self.repo.root}/sleeper.pid"\nwait\n',
            encoding="utf-8",
        )
        proc = self.repo.run("--timeout", "1")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("timed out after 1s; process group killed", proc.stdout)
        scratch = self.repo.track_scratch(proc.stdout)
        self.assertIsNotNone(scratch, proc.stdout)
        self.assertTrue(scratch.is_dir())
        pid = read_pid(self.repo.root / "sleeper.pid")
        self.assertTrue(
            process_gone(pid), "the backgrounded sleeper survived the timeout"
        )

    def test_an_interrupt_kills_both_running_suites_and_exits_130(self) -> None:
        # a suite in its own session never sees the terminal's Ctrl-C; the
        # runner must kill its process group itself, children included.
        # Both planned suites (alpha and the always-run gamma) block until
        # killed: when gamma exited at once, whether it still counted as
        # running at the interrupt was a scheduling race (1 or 2 killed),
        # which turned CI red on PR #1603. A suite that already finished is
        # deliberately not exercised here.
        self.repo.keep_steps("alpha", "gamma")
        sleepers = []
        for name in ("alpha", "gamma"):
            sleeper = self.repo.root / f"{name}-sleeper.pid"
            (self.repo.root / "tests" / f"{name}.test.sh").write_text(
                f'#!/usr/bin/env bash\necho "{name} ran" >> "{self.repo.calls}"\nsleep 30 & echo $! > "{sleeper}"\nwait\n',
                encoding="utf-8",
            )
            sleepers.append(sleeper)
        proc = subprocess.Popen(
            self.repo.args("--timeout", "60"),
            cwd=self.repo.root,
            env=self.repo.env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            pids = [read_pid(sleeper) for sleeper in sleepers]
            proc.send_signal(signal.SIGINT)
            out, _ = proc.communicate(timeout=15)
            scratch = self.repo.track_scratch(out)
        finally:
            if proc.poll() is None:
                proc.kill()
        self.assertEqual(proc.returncode, 130, out)
        self.assertIn(
            "interrupted: 2 running suite(s) killed, 0 queued suite(s) not started", out
        )
        self.assertIn("nothing is proven", out)
        self.assertIsNotNone(scratch, out)
        self.assertTrue(scratch.is_dir())
        for pid in pids:
            self.assertTrue(
                process_gone(pid),
                f"a backgrounded sleeper ({pid}) survived the interrupt",
            )

    def test_provisioning_steps_are_never_executed(self) -> None:
        # The full fixture includes provisioning and a sudo handoff.
        proc = self.repo.run()
        self.assertIn("affected-suites:", proc.stdout, proc.stdout + proc.stderr)
        self.assertFalse(
            self.repo.sudo_calls.exists(),
            "the fake sudo recorded a call: "
            + (
                self.repo.sudo_calls.read_text()
                if self.repo.sudo_calls.exists()
                else ""
            ),
        )

    def test_dry_run_prints_the_plan_and_runs_nothing(self) -> None:
        self.repo.keep_steps("alpha", "multi", "gamma")
        proc = self.repo.run("--dry-run")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            "would run: bash tests/alpha.test.sh: bash tests/alpha.test.sh", proc.stdout
        )
        self.assertIn("not run locally: set -euo pipefail", proc.stdout)
        self.assertEqual(self.repo.calls_text(), "")

    def test_step_env_is_applied(self) -> None:
        self.repo.keep_steps("alpha")
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("alpha ran env=from-step-env", self.repo.calls_text())

    def test_actions_conditions_and_provisioning_are_classified(self) -> None:
        self.repo.keep_steps(
            "gamma", "third party", "push only", "provision a tool (never run locally)"
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("gamma ran", self.repo.calls_text())
        self.assertIn(
            "not run locally: third party (`uses: example/tool@v1` runs only in CI)",
            proc.stdout,
        )
        self.assertIn(
            "runs only when github.event_name == 'push', which CI evaluates",
            proc.stdout,
        )
        self.assertNotIn("actions/checkout", proc.stdout)
        self.assertNotIn("actions/setup-", proc.stdout)
        self.assertNotIn("provision a tool", proc.stdout)
        self.assertFalse(self.repo.sudo_calls.exists())

    def test_identical_run_text_in_two_jobs_runs_once(self) -> None:
        self.repo.keep_steps("alpha")
        wf = self.repo.root / ".github/workflows/ci.yml"
        wf.write_text(
            wf.read_text()
            + "  other:\n    steps:\n      - run: bash tests/alpha.test.sh\n"
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.repo.calls_text().count("alpha ran"), 1)
        self.assertIn("1 pass / 0 fail / 0 not run locally", proc.stdout)

    def test_conditional_duplicate_does_not_hide_an_unconditional_step(self) -> None:
        self.repo.keep_steps("alpha")
        self.repo.edit_workflow(
            "      - name: alpha",
            "      - if: github.event_name == 'push'\n        name: alpha",
        )
        self.repo.append_steps("- run: bash tests/alpha.test.sh\n")
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.repo.calls_text().count("alpha ran"), 1)
        self.assertIn("1 pass / 0 fail / 1 not run locally", proc.stdout)

    def test_missing_working_directory_is_reported(self) -> None:
        self.repo.keep_steps("alpha")
        self.repo.append_steps(
            "- run: bash tests/gamma.test.sh\n  working-directory: missing\n"
        )
        proc = self.repo.run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("working-directory", proc.stdout)
        self.assertIn("does not exist", proc.stdout)
        self.assertNotIn("gamma ran", self.repo.calls_text())

    def test_shell_and_job_conditions_are_reported(self) -> None:
        self.repo.keep_steps("alpha")
        self.repo.append_steps("- run: bash tests/gamma.test.sh\n  shell: python\n")
        wf = self.repo.root / ".github/workflows/ci.yml"
        wf.write_text(
            wf.read_text()
            + "  other:\n    if: github.event_name == 'push'\n    steps:\n      - run: bash tests/beta.test.sh\n"
        )
        proc = self.repo.run("--dry-run")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("shell python", proc.stdout)
        self.assertIn(
            "runs only when github.event_name == 'push', which CI evaluates",
            proc.stdout,
        )
        self.assertEqual(self.repo.calls_text(), "")

    def test_unconditional_condition_spellings_run(self) -> None:
        self.repo.keep_steps("alpha")
        wf = self.repo.root / ".github/workflows/ci.yml"
        original = wf.read_text()
        for condition in (
            "!cancelled()",
            "always()",
            "success()",
            " ${{ !cancelled() }} ",
            "${{ always() }}",
            "${{ success() }}",
        ):
            with self.subTest(condition=condition):
                wf.write_text(
                    original.replace(
                        "      - name: alpha",
                        "      - if: '" + condition + "'\n        name: alpha",
                    )
                )
                proc = self.repo.run()
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn("1 pass / 0 fail / 0 not run locally", proc.stdout)

    def test_real_checkout_plan_and_gate(self) -> None:
        proc = subprocess.run(
            ["python3", str(RUNNER), "--repo", str(REPO_ROOT), "--dry-run"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("would run: bash tests/run-claude-tests.sh", proc.stdout)
        self.assertIn(
            'not run locally: archive="$RUNNER_TEMP/gitleaks_8.30.1_linux_x64.tar.gz" (multi-line CI step)',
            proc.stdout,
        )
        applies = subprocess.run(["python3", str(RUNNER), "--applies", str(REPO_ROOT)])
        self.assertEqual(applies.returncode, 1)


class ScratchCleanupGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(
            prefix="affected-suites-cleanup-test.", dir="/tmp"
        )
        self.addCleanup(self.tmp.cleanup)
        self.scratch = Path(tempfile.mkdtemp(prefix="run-affected-suites.", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.created = self.scratch.stat()

    def test_cleanup_rejects_a_path_outside_tmp(self) -> None:
        with mock.patch("shutil.rmtree") as remove:
            RUNNER_MODULE["remove_scratch"](
                Path("/var/run-affected-suites.unrelated"), self.created
            )
        remove.assert_not_called()

    def test_cleanup_rejects_the_wrong_prefix(self) -> None:
        unrelated = Path(self.tmp.name)
        RUNNER_MODULE["remove_scratch"](unrelated, unrelated.stat())
        self.assertTrue(unrelated.is_dir())

    def test_cleanup_rejects_a_replacement_directory(self) -> None:
        original = Path(self.tmp.name) / "original"
        self.scratch.rename(original)
        self.scratch.mkdir()
        RUNNER_MODULE["remove_scratch"](self.scratch, self.created)
        self.assertTrue(self.scratch.is_dir())
        self.assertTrue(original.is_dir())

    def test_cleanup_rejects_a_symlink_to_another_directory(self) -> None:
        original = Path(self.tmp.name) / "original"
        self.scratch.rename(original)
        self.scratch.symlink_to(original, target_is_directory=True)
        self.addCleanup(self.scratch.unlink)
        RUNNER_MODULE["remove_scratch"](self.scratch, self.created)
        self.assertTrue(self.scratch.is_symlink())
        self.assertTrue(original.is_dir())


class LocalResultRecordTests(unittest.TestCase):
    """dotfiles#1598: the runner records its result against the commit it
    tested, and readers find it with --read and ask --applies first."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(
            prefix="run-affected-suites-record.", dir="/tmp"
        )
        base = Path(self.tmp.name)
        self.home = base / "home"
        self.home.mkdir()
        self.repo = ScratchRepo(base / "repo")
        self.repo.keep_steps("alpha", "gamma")
        self.repo.init_git()
        self.git("remote", "add", "origin", "git@github.com:Example-Org/Scratch.git")
        self.git("checkout", "-q", "-b", "feature")
        self.record_dir = (
            self.home
            / ".claude"
            / ".loop-state"
            / "local-suites"
            / "example-org--scratch"
        )

    def tearDown(self) -> None:
        self.repo.cleanup_scratch()
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
            cwd=self.repo.root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def commit_change(
        self, path: str, text: str = "#!/usr/bin/env bash\n# changed\n"
    ) -> str:
        target = self.repo.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        self.git("add", path)
        self.git("commit", "-q", "-m", f"change {path}")
        return self.git("rev-parse", "HEAD")

    def env(self) -> dict:
        env = self.repo.env()
        env["HOME"] = str(self.home)
        return env

    def run_runner(self, *extra: str) -> subprocess.CompletedProcess:
        # No --no-lint: a run without CI's lint steps records nothing. The
        # scratch workflow carries no lint step, so the plan is the same.
        args = [
            "python3",
            str(RUNNER),
            "--repo",
            str(self.repo.root),
            "--jobs",
            "2",
            "--base-ref",
            "main",
            *extra,
        ]
        proc = subprocess.run(
            args,
            cwd=self.repo.root,
            env=self.env(),
            capture_output=True,
            text=True,
            check=False,
        )
        self.repo.track_scratch(proc.stdout)
        return proc

    def record(self, sha: str) -> dict:
        import json

        return json.loads((self.record_dir / f"{sha}.json").read_text(encoding="utf-8"))

    def test_a_passing_run_records_pass_at_head_and_read_returns_it(self) -> None:
        import json

        sha = self.commit_change("scripts/alpha.sh")
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            f"local result recorded: pass at {self.record_dir / (sha + '.json')}",
            proc.stdout,
        )
        rec = self.record(sha)
        self.assertEqual(rec["outcome"], "pass")
        self.assertEqual(rec["sha"], sha)
        self.assertEqual(rec["repo"], "example-org--scratch")
        self.assertEqual(
            rec["selected"], ["bash tests/gamma.test.sh", "bash tests/alpha.test.sh"]
        )
        self.assertEqual(rec["failed"], [])
        self.assertEqual(rec["not_run"], [])
        log = Path(rec["log"]).read_text(encoding="utf-8")
        self.assertIn("=== bash tests/alpha.test.sh (exit 0", log)
        self.assertNotIn("(log unreadable)", log)
        self.assertFalse(self.repo.track_scratch(proc.stdout).exists())
        self.assertEqual(oct(self.record_dir.stat().st_mode & 0o777), "0o700")
        read = self.run_runner("--read", "HEAD")
        self.assertEqual(read.returncode, 0, read.stderr)
        self.assertEqual(json.loads(read.stdout)["sha"], sha)

    def test_a_failed_record_write_keeps_the_suite_scratch(self) -> None:
        # PR #1808 review: when the record cannot be written, the scratch logs
        # are the only evidence a green run leaves behind, so the cleanup must
        # not run on that exit path. A regular file where the record root
        # belongs makes the recorder's mkdir raise a plain OSError.
        self.commit_change("scripts/alpha.sh")
        root = self.record_dir.parent
        root.parent.mkdir(parents=True)
        root.write_text("not a directory\n", encoding="utf-8")
        proc = self.run_runner()
        scratch = self.repo.track_scratch(proc.stdout)
        self.assertIsNotNone(scratch, proc.stdout)
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("2 pass / 0 fail", proc.stdout)
        self.assertNotIn("local result recorded", proc.stdout)
        self.assertIn("NotADirectoryError", proc.stderr)
        self.assertTrue(scratch.is_dir(), proc.stdout + proc.stderr)
        self.assertTrue(
            any("alpha.test.sh" in p.name for p in scratch.glob("*.log")),
            sorted(p.name for p in scratch.iterdir()),
        )

    def test_covers_ae8_a_suite_that_cannot_run_here_records_partial(self) -> None:
        self.repo.append_steps(
            "- run: |\n    set -euo pipefail\n    bash tests/multi.test.sh\n"
        )
        self.git("add", ".github/workflows/ci.yml")
        self.git("commit", "-qm", "add subject step")
        sha = self.commit_change("scripts/multi.sh")
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        rec = self.record(sha)
        self.assertEqual(rec["outcome"], "partial")
        self.assertEqual(
            rec["not_run"],
            [{"suite": "set -euo pipefail", "reason": "multi-line CI step"}],
        )

    def test_a_failing_suite_records_fail_with_the_suite_and_its_log(self) -> None:
        self.repo.append_steps("- run: bash beta.test.sh\n  working-directory: tests\n")
        self.git("add", ".github/workflows/ci.yml")
        self.git("commit", "-qm", "add subject step")
        sha = self.commit_change("scripts/beta.sh")
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        rec = self.record(sha)
        self.assertEqual(rec["outcome"], "fail")
        self.assertEqual(rec["failed"], ["bash beta.test.sh"])
        log = Path(rec["log"]).read_text(encoding="utf-8")
        self.assertIn("=== bash beta.test.sh (exit 3", log)
        self.assertIn("BETA_FAILURE_MARKER: planted", log)

    def test_a_dirty_tree_records_nothing_and_says_why(self) -> None:
        sha = self.commit_change("scripts/alpha.sh")
        (self.repo.root / "scripts" / "alpha.sh").write_text(
            "#!/usr/bin/env bash\n# uncommitted\n", encoding="utf-8"
        )
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            "local result not recorded: the working tree has uncommitted or untracked changes",
            proc.stdout,
        )
        self.assertFalse((self.record_dir / f"{sha}.json").exists())

    def test_a_run_under_the_loop_guard_records_nothing_and_says_why(self) -> None:
        sha = self.commit_change("scripts/alpha.sh")
        args = [
            "python3",
            str(RUNNER),
            "--repo",
            str(self.repo.root),
            "--jobs",
            "2",
            "--base-ref",
            "main",
        ]
        proc = subprocess.run(
            args,
            cwd=self.repo.root,
            env={**self.env(), "CLAUDE_LOOP_GUARD": "1"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.repo.track_scratch(proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("local result not recorded: CLAUDE_LOOP_GUARD=1", proc.stdout)
        self.assertFalse((self.record_dir / f"{sha}.json").exists())

    def test_an_inherited_loop_guard_never_reaches_the_fixture(self) -> None:
        sha = self.commit_change("scripts/alpha.sh")
        with mock.patch.dict(os.environ, {"CLAUDE_LOOP_GUARD": "1"}):
            proc = self.run_runner()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            f"local result recorded: pass at {self.record_dir / (sha + '.json')}",
            proc.stdout,
        )

    def test_a_run_without_the_lint_steps_records_nothing_and_says_why(self) -> None:
        # The record stands in for CI's suites at this commit, lint included:
        # pr-owner marks ready on it (CE review of #1612).
        sha = self.commit_change("scripts/alpha.sh")
        proc = self.run_runner("--no-lint")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn(
            "local result not recorded: --no-lint skips the lint steps CI runs at this commit",
            proc.stdout,
        )
        self.assertFalse((self.record_dir / f"{sha}.json").exists())

    def test_a_write_prunes_records_older_than_14_days_and_keeps_newer_ones(
        self,
    ) -> None:
        self.record_dir.mkdir(parents=True)
        old = self.record_dir / ("a" * 40 + ".json")
        old_log = self.record_dir / ("a" * 40 + ".log")
        recent = self.record_dir / ("b" * 40 + ".json")
        for path in (old, old_log, recent):
            path.write_text("{}\n", encoding="utf-8")
        stale = time.time() - 15 * 86400
        os.utime(old, (stale, stale))
        os.utime(old_log, (stale, stale))
        self.commit_change("scripts/alpha.sh")
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(old.exists())
        self.assertFalse(old_log.exists())
        self.assertTrue(recent.exists())

    def test_read_with_no_record_exits_4_and_prints_nothing(self) -> None:
        self.commit_change("scripts/alpha.sh")
        proc = self.run_runner("--read", "HEAD")
        self.assertEqual(proc.returncode, 4, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "")

    def test_nothing_runnable_records_partial_with_every_selected_suite_not_run(
        self,
    ) -> None:
        self.repo.keep_steps("gamma")
        self.repo.edit_workflow(
            "run: bash tests/gamma.test.sh",
            "run: |\n              set -e\n              bash tests/gamma.test.sh",
        )
        self.git("add", ".github/workflows/ci.yml")
        self.git("commit", "-q", "-m", "gamma multi-line")
        self.repo.append_steps(
            "- run: |\n    set -euo pipefail\n    bash tests/multi.test.sh\n"
        )
        self.git("add", ".github/workflows/ci.yml")
        self.git("commit", "-qm", "add subject step")
        sha = self.commit_change("scripts/multi.sh")
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        rec = self.record(sha)
        self.assertEqual(rec["outcome"], "partial")
        self.assertIn(
            {"suite": "set -euo pipefail", "reason": "multi-line CI step"},
            rec["not_run"],
        )
        self.assertEqual(rec["ran"], [])

    def test_applies_finds_a_draft_named_job_in_the_tree(self) -> None:
        self.assertEqual(
            self.run_runner("--applies", str(self.repo.root)).returncode, 1
        )
        self.repo.append_steps("")
        wf = self.repo.root / ".github" / "workflows" / "ci.yml"
        wf.write_text(
            wf.read_text(encoding="utf-8")
            + "  test:\n"
            + "    name: ${{ github.event.pull_request.draft && 'Harness suites (draft)' || 'Harness suites' }}\n"
            + "    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n",
            encoding="utf-8",
        )
        self.assertEqual(
            self.run_runner("--applies", str(self.repo.root)).returncode, 0
        )

    def test_applies_reads_the_base_workflow_a_pull_request_runs(self) -> None:
        """CI runs a pull_request workflow from the merge ref, so a branch cut
        before the draft gate still gets the base's draft red (#1632)."""
        wf = self.repo.root / ".github" / "workflows" / "ci.yml"
        self.git("checkout", "-q", "main")
        wf.write_text(
            wf.read_text(encoding="utf-8")
            + "  test:\n"
            + "    name: ${{ github.event.pull_request.draft && 'Harness suites (draft)' || 'Harness suites' }}\n"
            + "    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n",
            encoding="utf-8",
        )
        self.git("commit", "-qam", "base gains the draft gate")
        self.git("checkout", "-q", "feature")
        self.assertNotIn("Harness suites (draft)", wf.read_text(encoding="utf-8"))
        self.assertEqual(
            self.run_runner("--applies", str(self.repo.root)).returncode, 0
        )
        # An unreadable base leaves the tree's answer.
        self.assertEqual(
            self.run_runner(
                "--applies", str(self.repo.root), "--base-ref", "no/such/ref"
            ).returncode,
            1,
        )

    def test_third_party_action_records_partial_in_workflow_order(self) -> None:
        self.repo.append_steps(
            "- name: third party\n  uses: example/tool@v1\n- uses: example/unnamed@v1\n"
        )
        self.git("add", ".github/workflows/ci.yml")
        self.git("commit", "-qm", "add action steps")
        sha = self.git("rev-parse", "HEAD")
        proc = self.run_runner()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        rec = self.record(sha)
        self.assertEqual(rec["outcome"], "partial")
        self.assertEqual(
            rec["selected"],
            [
                "bash tests/gamma.test.sh",
                "bash tests/alpha.test.sh",
                "third party",
                "example/unnamed@v1",
            ],
        )
        self.assertEqual(
            rec["not_run"],
            [
                {
                    "suite": "third party",
                    "reason": "`uses: example/tool@v1` runs only in CI",
                },
                {
                    "suite": "example/unnamed@v1",
                    "reason": "`uses: example/unnamed@v1` runs only in CI",
                },
            ],
        )

    def test_head_moving_during_run_refuses_record(self) -> None:
        args = RUNNER_MODULE["parse_args"]([])
        with mock.patch.dict(os.environ, self.env(), clear=True):
            recorder = RUNNER_MODULE["Recorder"](self.repo.root, args)
            self.assertIsNone(recorder.why_not)
            sha = self.commit_change("scripts/alpha.sh")
            recorder.write([], [], [])
        self.assertFalse((self.record_dir / f"{sha}.json").exists())
        self.assertFalse(self.record_dir.exists())

    def test_dry_run_records_nothing(self) -> None:
        sha = self.commit_change("scripts/alpha.sh")
        self.assertEqual(self.run_runner("--dry-run").returncode, 0)
        self.assertFalse((self.record_dir / f"{sha}.json").exists())


if __name__ == "__main__":
    unittest.main()
