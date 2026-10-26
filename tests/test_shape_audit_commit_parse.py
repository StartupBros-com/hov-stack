#!/usr/bin/env python3
"""Pin the shape-audit `conventional` detector's commit-command parsing.

Each shape below came from a real ablation trace or a detector miss:
`-am` (Sweep 4, 6 Sonnet NEW runs scored NONE) and `git -C <path> commit`
(Sweep 4, Opus NEW r7 scored NONE).
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "shape-audit" / "ablation"))

from rules import GIT_COMMIT_CMD, detect_conventional, parse_commit_subject  # noqa: E402


def bash(cmd):
    return {"name": "Bash", "input": {"command": cmd}}


class CommitSubjectTests(unittest.TestCase):
    def test_subjects(self):
        cases = [
            ('git commit -m "fix: b"', "fix: b"),
            ('git commit -am "feat: a"', "feat: a"),
            ('X=1 git commit -sam "docs: c" && git log', "docs: c"),
            ('git commit --amend -m "chore: d"', "chore: d"),
            ("git commit -F - <<'EOF'\nperf: e\nEOF", "perf: e"),
            ('git -C /tmp/w commit -m "feat(cache): f"', "feat(cache): f"),
            ('git -C "/tmp/a b" -c user.name=x commit -am "fix: g"', "fix: g"),
            ("git -c core.hooksPath=/dev/null commit -F- <<'EOF'\ndocs: h\nEOF", "docs: h"),
            ('git --no-pager --git-dir=/r/.git --work-tree /r commit -m "chore: i"', "chore: i"),
            ('cd /w && git -C . commit -m "perf: j"', "perf: j"),
        ]
        for cmd, want in cases:
            with self.subTest(cmd=cmd):
                self.assertEqual(parse_commit_subject(cmd), want)

    def test_other_git_commands_are_not_commits(self):
        for cmd in ("git -C /w log --oneline", "git -C /w commit-tree abc", "git commit-tree abc", "git status"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(GIT_COMMIT_CMD.search(cmd))


class DetectConventionalTests(unittest.TestCase):
    def test_git_dash_c_commit_scores_its_subject(self):
        verdict, why = detect_conventional([bash('git -C /tmp/w add -A'), bash('git -C /tmp/w commit -m "feat(cache): raise TTL"')])
        self.assertEqual((verdict, why), ("GOOD", "feat(cache): raise TTL"))

    def test_unconventional_subject_is_bad(self):
        verdict, _ = detect_conventional([bash('git -C /tmp/w commit -m "raise TTL"')])
        self.assertEqual(verdict, "BAD")

    def test_no_commit_is_none(self):
        self.assertEqual(detect_conventional([bash("git -C /tmp/w status")]), ("NONE", None))


if __name__ == "__main__":
    unittest.main()
