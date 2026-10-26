#!/usr/bin/env python3
"""scripts/repin-kill-ai-slop.py re-applies exactly the local changes UPSTREAM.md lists.

WHY: the script wrote its re-pull beside itself, into scripts/, not into the skill directory,
so a repin would have landed upstream's files in the wrong place and left the vendored copy
stale. Its local-change step also predates the Apache-2.0 section 4(b) notice line. No
network: the vendored SKILL.md minus its two local lines must be upstream's blob at the pin.
"""

import hashlib
import runpy
import unittest
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "repin-kill-ai-slop.py"
SKILL_DIR = REPO_ROOT / "plugins" / "hov-stack" / "skills" / "kill-ai-slop"
# yetone/kill-ai-slop skill/SKILL.md at the pin UPSTREAM.md records (f6e2ae3). On a repin:
# gh api 'repos/yetone/kill-ai-slop/contents/skill/SKILL.md?ref=<pin>' --jq .sha
UPSTREAM_PIN = "f6e2ae32b30443ec7bd0da4da971ee18d8f8ffcb"
UPSTREAM_SKILL_BLOB = "13f0e474995d5e0e0533de8dcdc260f6a4c9901c"


def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def frontmatter(text: str) -> dict:
    return yaml.safe_load(text.split("---", 2)[1])


class RepinKillAiSlopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = runpy.run_path(str(SCRIPT))
        cls.vendored = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
        lines = cls.vendored.split("\n")
        cls.upstream = "\n".join(l for l in lines if l not in (cls.mod["NOTICE"], cls.mod["POSTURE"]))

    def test_writes_into_the_skill_directory(self):
        target = Path(self.mod["SKILL_DIR"]).resolve()
        self.assertEqual(target, SKILL_DIR.resolve())
        self.assertTrue((target / "UPSTREAM.md").is_file())

    def test_upstream_md_records_the_pin_this_test_checks(self):
        self.assertIn(UPSTREAM_PIN, (SKILL_DIR / "UPSTREAM.md").read_text(encoding="utf-8"))

    def test_the_two_local_lines_are_the_only_change_from_upstream(self):
        self.assertEqual(len(self.upstream.split("\n")), len(self.vendored.split("\n")) - 2)
        self.assertEqual(git_blob_sha(self.upstream.encode("utf-8")), UPSTREAM_SKILL_BLOB)

    def test_upstream_text_becomes_the_vendored_file(self):
        self.assertEqual(self.mod["apply_local_changes"](self.upstream), self.vendored)

    def test_notice_first_and_posture_last_in_the_frontmatter(self):
        fm = self.vendored.split("---", 2)[1].strip("\n").split("\n")
        self.assertEqual(fm[0], self.mod["NOTICE"])
        self.assertEqual(fm[-1], self.mod["POSTURE"])

    def test_idempotent(self):
        once = self.mod["apply_local_changes"](self.upstream)
        self.assertEqual(self.mod["apply_local_changes"](once), once)

    def test_frontmatter_still_parses_with_upstream_name_and_description(self):
        local, upstream = frontmatter(self.vendored), frontmatter(self.upstream)
        self.assertEqual(local["name"], "kill-ai-slop")
        self.assertEqual(local["description"], upstream["description"])
        self.assertIs(local["disable-model-invocation"], True)
        self.assertNotIn("disable-model-invocation", upstream)


if __name__ == "__main__":
    unittest.main()
