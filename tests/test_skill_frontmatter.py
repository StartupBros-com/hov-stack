#!/usr/bin/env python3
"""Frontmatter conformance for every locally-owned skill and agent.

WHY: a skill's or agent's frontmatter is parsed as YAML. One unquoted
metacharacter silently takes the WHOLE block down, not just its own key — and
the failure is invisible, because the file still looks fine. Live instances:

  * 2026-07, memory notes: an unquoted `#` in a `description:` started a YAML
    comment and truncated the value. 100+ notes were affected before the audit
    caught it (see CLAUDE.md, "Memory frontmatter").
  * 2026-08-05, the memory-dream skill: an unquoted `(default: all live
    projects...)` in `argument-hint:` made YAML read `default:` as a nested
    mapping. The entire block failed to parse, taking name, description,
    disable-model-invocation and allowed-tools with it.
  * 2026-11-12, agents/: lean-reader's description lost its tail at ` #1322`
    (the live agent roster showed it cut), and lean-collector's `Measured
    …: 1,880` was a parse error. Agents were outside this guard until then.

All were found by hand. This test is the guard so the next one isn't. Delete it
when `claude plugin validate` rejects these defects itself (on 2026-11-13 it
passed both broken agents unchanged; see PR #567).
"""

import glob
import os
import re
import unittest
from pathlib import Path

import yaml

CLAUDE = Path(__file__).resolve().parents[1]
PACK = "plugins/hov-stack/skills"
PATTERNS = (
    f"{PACK}/*/SKILL.md",
    "skills-stack/*/SKILL.md",
    "skills-patches/*/SKILL.md",
    "harnesses/codex/skills/*/SKILL.md",
)
# Agent definitions: ~/.claude/agents resolves to agents/, and plugin agents
# load through their plugin. An agent is named by its file stem, not its folder.
AGENT_PATTERNS = (
    "agents/*.md",
    "plugins/*/agents/*.md",
)
# The licence-file names test_skill_pack.py accepts.
LICENCE_FILE = re.compile(r"^(LICENSE(-.+)?|LICENSE\.(md|txt)|COPYING)$")
# A top-level `key: value` line whose value is a plain (unquoted, non-block) scalar.
# Only top-level single-line values are checked; nested values, list items and
# continuation lines are not.
PLAIN_SCALAR = re.compile(r"""^([A-Za-z][\w-]*):[ \t]+([^"'|>\s].*)$""")


def _glob(patterns) -> list[Path]:
    out: list[Path] = []
    for pat in patterns:
        out.extend(Path(p) for p in sorted(glob.glob(str(CLAUDE / pat))))
    return out


def skill_files() -> list[Path]:
    return _glob(PATTERNS)


def agent_files() -> list[Path]:
    return _glob(AGENT_PATTERNS)


def all_files() -> list[Path]:
    return skill_files() + agent_files()


def label(path: Path) -> str:
    return str(path.relative_to(CLAUDE))


def expected_name(path: Path) -> str:
    return path.parent.name if path.name == "SKILL.md" else path.stem


def frontmatter(path: Path) -> str | None:
    """The raw YAML block, or None when the file has no frontmatter at all."""
    text = path.read_text()
    if not text.startswith("---\n"):
        return None
    try:
        end = text.index("\n---\n", 3)
    except ValueError:
        return ""  # opened a block and never closed it — always a failure
    return text[4:end]


class SkillFrontmatterTests(unittest.TestCase):
    def test_at_least_one_skill_is_discovered(self):
        """Guard the guard: a bad glob would make every other test vacuously pass."""
        self.assertGreater(len(skill_files()), 0, f"no SKILL.md found under {CLAUDE}")
        self.assertGreater(len(agent_files()), 0, f"no agent .md found under {CLAUDE}")

    def test_every_frontmatter_parses_as_yaml(self):
        for path in all_files():
            with self.subTest(file=label(path)):
                fm = frontmatter(path)
                self.assertIsNotNone(fm, "missing frontmatter block")
                self.assertNotEqual(fm, "", "frontmatter opened but never closed")
                try:
                    yaml.safe_load(fm)
                except yaml.YAMLError as exc:
                    self.fail(
                        f"frontmatter does not parse: {str(exc).splitlines()[0]}\n"
                        "Quote any value containing ':', '#', '{', '[' or a leading '*'."
                    )

    def test_required_keys_survive_the_parse(self):
        """A truncated value parses fine but arrives empty — check the result, not just the parse."""
        for path in all_files():
            with self.subTest(file=label(path)):
                data = yaml.safe_load(frontmatter(path) or "") or {}
                self.assertTrue(str(data.get("name", "")).strip(), "empty or missing name")
                self.assertTrue(
                    str(data.get("description", "")).strip(), "empty or missing description"
                )

    def test_no_unquoted_hash_truncates_a_value(self):
        """` #` in a plain scalar starts a comment: the value parses, shortened, with no error."""
        for path in all_files():
            with self.subTest(file=label(path)):
                for line in (frontmatter(path) or "").splitlines():
                    m = PLAIN_SCALAR.match(line)
                    if m and (" #" in m.group(2) or "\t#" in m.group(2)):
                        self.fail(
                            f"`{m.group(1)}:` is cut at its ' #'; double-quote the whole value"
                        )

    def test_name_matches_directory(self):
        """A mismatch means `/<dir-name>` (or the agent's file name) silently invokes nothing."""
        for path in all_files():
            with self.subTest(file=label(path)):
                data = yaml.safe_load(frontmatter(path) or "") or {}
                self.assertEqual(data.get("name"), expected_name(path))

    def test_third_party_snapshots_record_provenance(self):
        """A vendored skill without UPSTREAM.md is unauditable: no repo, no commit, no licence.

        Every pack skill carries a licence file (test_skill_pack.py); a first-party one is a
        byte-identical copy of the root LICENSE, so any other licence text marks a vendored skill.
        """
        root = (CLAUDE / "LICENSE").read_bytes()
        for path in skill_files():
            if not path.is_relative_to(CLAUDE / PACK):
                continue
            licences = [
                p for p in path.parent.iterdir()
                if p.is_file() and LICENCE_FILE.match(p.name) and p.read_bytes() != root
            ]
            if not licences:
                continue  # locally authored — provenance file not expected
            with self.subTest(skill=path.parent.name):
                upstream = path.parent / "UPSTREAM.md"
                self.assertTrue(
                    upstream.exists(), "a licence differs from the root LICENSE but there is no UPSTREAM.md"
                )
                body = upstream.read_text()
                self.assertIn("github.com", body, "UPSTREAM.md names no source repo")
                self.assertRegex(
                    body, r"\b[0-9a-f]{40}\b", "UPSTREAM.md pins no full commit SHA"
                )


if __name__ == "__main__":
    unittest.main()
