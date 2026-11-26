#!/usr/bin/env bash
# Exercise the real launcher and runner with a synthetic Claude executable.
# The grading dispatcher uses an inert grade callback, not the arm's code.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -I - "$REPO/harness/vet-fixtures/no-comments-2026-11" <<'PY'
import json
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

FIXTURE = Path(sys.argv[1])
SUCCESS = '{"is_error": false, "result": "fixture response"}'


class TestRunRecord(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "test root"
        self.runs = self.root / "runs"
        self.runs.mkdir(parents=True)
        # Only these local tools and the stub are visible to launch.sh/run_arm.sh.
        bin_dir = Path(temp.name) / "bin"
        bin_dir.mkdir()
        for name in ("bash", "cat", "dirname", "env", "find", "mkdir", "sort", "timeout", "xargs"):
            (bin_dir / name).symlink_to(shutil.which(name))
        (bin_dir / "python3").symlink_to(sys.executable)
        claude = bin_dir / "claude"
        claude.write_text("""#!/bin/bash
set -eu
printf 'called\n' >> ../calls
printf 'synthetic stderr without a newline' >&2
case "$2" in
  failed) printf '%s\n' '{"is_error": false, "result": "fixture response"}'; exit 7 ;;
  *)      printf '%s\n' '{"is_error": false, "result": "fixture response"}' ;;
esac
""")
        claude.chmod(0o700)
        self.env = {"PATH": str(bin_dir), "HOME": temp.name, "LC_ALL": "C"}

    def slot(self, name, prompt="ok"):
        run = self.runs / name
        (run / "repo").mkdir(parents=True)
        (run / "config").mkdir()
        (run / "prompt.txt").write_text(prompt)
        return run

    def legacy(self, name, result=SUCCESS, receipt="EXIT_CODE=0\n"):
        run = self.slot(name)
        (run / "result.json").write_text(result)
        if receipt is not None:
            (run / "stderr.txt").write_text(receipt)
        return run

    def launch(self):
        return subprocess.run(
            ["bash", str(FIXTURE / "launch.sh"), str(self.root), "2"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def grade_dispatch(self, output, *ids):
        grade = runpy.run_path(str(FIXTURE / "grader" / "grade.py"))["main"]
        visited = []

        def inert_grade(repo):
            visited.append(repo)
            return {"synthetic": True}

        with (
            patch.object(sys, "argv", ["grade.py", str(self.root), str(output), *ids]),
            patch.dict(grade.__globals__, grade_repo=inert_grade, summarize=dict),
        ):
            grade()
        return visited, json.loads(output.read_text())

    def test_fresh_success_and_subsequent_skip(self):
        run = self.slot("two words")
        first = self.launch()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("launch: done", first.stdout)
        self.assertEqual((run / "stderr.txt").read_text().splitlines()[-1], "EXIT_CODE=0")
        self.assertEqual((run / "calls").read_text(), "called\n")
        second = self.launch()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((run / "calls").read_text(), "called\n")

    def test_failure_propagates_even_if_envelope_looks_successful(self):
        bad = self.slot("bad", "failed")
        good = self.slot("good")
        first = self.launch()
        self.assertNotEqual(first.returncode, 0)
        self.assertNotIn("launch: done", first.stdout)
        self.assertIn("claude exited 7", first.stderr)
        self.assertEqual((bad / "stderr.txt").read_text().splitlines()[-1], "EXIT_CODE=7")
        originals = {p: (p / "result.json").read_bytes() for p in (bad, good)}
        second = self.launch()
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("bad: not-run", second.stderr)
        self.assertNotIn("launch: done", second.stdout)
        for run in (bad, good):
            self.assertEqual((run / "calls").read_text(), "called\n")
            self.assertEqual((run / "result.json").read_bytes(), originals[run])

    def test_existing_partial_and_error_artifacts_never_launch(self):
        existing = {
            "empty": self.legacy("empty", ""),
            "error": self.legacy("error", '{"is_error": true, "result": "failure"}'),
            "malformed": self.legacy("malformed", "{"),
            "missing-rc": self.legacy("missing-rc", receipt=None),
            "working": self.legacy("working"),
            "completed": self.legacy("completed"),
            "stderr-only": self.slot("stderr-only"),
            "reserved": self.slot("reserved"),
        }
        (existing["working"] / ".launch-attempt").mkdir()
        (existing["reserved"] / ".launch-attempt").mkdir()
        (existing["stderr-only"] / "stderr.txt").write_text("partial")
        before = {
            p: p.read_bytes() for run in existing.values() for p in run.iterdir() if p.is_file()
        }
        output = self.launch()
        self.assertNotEqual(output.returncode, 0)
        self.assertNotIn("launch: done", output.stdout)
        for name, run in existing.items():
            with self.subTest(name=name):
                self.assertFalse((run / "calls").exists())
                if name == "completed":
                    self.assertNotIn("completed: not-run", output.stderr)
                else:
                    self.assertIn(f"{name}: not-run", output.stderr)
        self.assertTrue(all(p.read_bytes() == data for p, data in before.items()))

    def test_interruption_before_runner_output_cannot_retry(self):
        run = self.slot("timeout")
        timeout = Path(self.env["PATH"]) / "timeout"
        timeout.unlink()
        timeout.write_text('#!/bin/bash\nprintf "timed out\\n" >> "$4/timeouts"\nexit 124\n')
        timeout.chmod(0o700)
        first = self.launch()
        self.assertNotEqual(first.returncode, 0)
        self.assertNotIn("launch: done", first.stdout)
        self.assertEqual((run / "timeouts").read_text(), "timed out\n")
        self.assertTrue((run / ".launch-attempt").is_dir())
        self.assertFalse((run / "result.json").exists())
        second = self.launch()
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual((run / "timeouts").read_text(), "timed out\n")

    def test_missing_runs_directory_does_not_print_success(self):
        self.runs.rmdir()
        output = self.launch()
        self.assertNotEqual(output.returncode, 0)
        self.assertNotIn("launch: done", output.stdout)

    def test_dispatcher_preserves_success_and_removes_stale_scores_for_invalid_runs(self):
        legacy = self.legacy("legacy-complete")
        recent = self.legacy("new-complete")
        (recent / ".launch-attempt" / "complete").mkdir(parents=True)
        self.legacy("failed", receipt="EXIT_CODE=0\nEXIT_CODE=7\n")
        self.legacy("error", '{"is_error": true, "result": "failed"}')
        self.legacy("malformed", "{")
        self.legacy("empty", "")
        self.legacy("nonstring", '{"is_error": false, "result": {"not": "a response"}}')
        self.legacy("no-exit", receipt=None)
        interrupted = self.legacy("interrupted")
        (interrupted / ".launch-attempt").mkdir()
        self.slot("unstarted")
        output = self.root / "grade.json"
        stale = {"summary": {"stale": True}}
        output.write_text(json.dumps({p.name: stale for p in self.runs.iterdir()}))
        visited, records = self.grade_dispatch(output)
        self.assertEqual(visited, [legacy / "repo", recent / "repo"])
        self.assertEqual(set(records), {"legacy-complete", "new-complete"})
        for record in records.values():
            self.assertEqual(record["report"], "fixture response")
            self.assertTrue(record["summary"]["synthetic"])

    def test_explicit_subset_prunes_unselected_bad_cache_without_regrading_good(self):
        selected = self.legacy("selected")
        self.legacy("cached-good")
        self.legacy("cached-bad", receipt="EXIT_CODE=7\n")
        output = self.root / "grade.json"
        cached = {"summary": {"cached": True}}
        output.write_text(json.dumps({"cached-good": cached, "cached-bad": cached}))
        visited, records = self.grade_dispatch(output, "selected")
        self.assertEqual(visited, [selected / "repo"])
        self.assertEqual(set(records), {"selected", "cached-good"})
        self.assertEqual(records["cached-good"], cached)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
