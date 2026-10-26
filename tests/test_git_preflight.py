#!/usr/bin/env python3
"""Contract tests for the read-only git-preflight PATH command."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parents[0]
SCRIPT = REPO_ROOT / "bin" / "git-preflight"
MANIFEST = REPO_ROOT / "lib" / "manifest.sh"


class GitPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.repo = Path(self.tempdir.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        (self.repo / "tracked.txt").write_text("clean\n", encoding="utf-8")
        self.git("add", "tracked.txt")
        self.git(
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-qm",
            "fixture",
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            text=True,
            capture_output=True,
        )

    def run_preflight(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), "-C", str(self.repo), *args],
            check=False,
            text=True,
            capture_output=True,
        )

    def test_clean_human_report_runs_all_three_checks(self) -> None:
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("## status", result.stdout)
        self.assertIn("## diff --stat\n(clean)", result.stdout)
        self.assertIn("## diff --check\nOK", result.stdout)

    def test_json_matches_the_three_manual_commands(self) -> None:
        (self.repo / "tracked.txt").write_text("changed\n", encoding="utf-8")
        result = self.run_preflight("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)

        manual_status = self.git("status", "--short", "--branch").stdout.rstrip("\n")
        manual_stat = self.git("diff", "--stat").stdout.rstrip("\n")
        manual_check = self.git("diff", "--check").stdout.rstrip("\n")
        self.assertEqual(payload["status"], manual_status)
        self.assertEqual(payload["diff_stat"], manual_stat)
        self.assertEqual(payload["diff_check"], manual_check)
        self.assertTrue(payload["dirty"])
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["exit_code"], 0)

    def test_whitespace_error_is_reported_and_returns_one(self) -> None:
        (self.repo / "tracked.txt").write_text("trailing space \n", encoding="utf-8")
        result = self.run_preflight("--json")
        self.assertEqual(result.returncode, 1, result.stderr)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["exit_code"], 1)
        self.assertIn("trailing whitespace", payload["diff_check"])

    def test_dry_run_is_json_and_leaves_repository_unchanged(self) -> None:
        (self.repo / "tracked.txt").write_text("changed\n", encoding="utf-8")
        before = self.git("status", "--porcelain=v1").stdout
        result = self.run_preflight("--dry-run", "--json")
        after = self.git("status", "--porcelain=v1").stdout

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["dry_run"])
        self.assertEqual(len(payload["commands"]), 3)
        self.assertEqual(before, after)

    def test_outside_a_repository_fails_loudly(self) -> None:
        outside = Path(self.tempdir.name) / "outside"
        outside.mkdir()
        result = subprocess.run(
            [str(SCRIPT), "-C", str(outside), "--json"],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("not inside a Git worktree", result.stderr)

    def test_path_install_is_declared_in_the_manifest(self) -> None:
        declaration = '"bin/git-preflight|.local/bin/git-preflight"'
        self.assertIn(declaration, MANIFEST.read_text(encoding="utf-8"))
        self.assertTrue(SCRIPT.exists())


if __name__ == "__main__":
    unittest.main()
