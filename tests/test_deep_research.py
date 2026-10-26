#!/usr/bin/env python3
"""Discovery/deployment contracts for the owned coordinator, not research-quality tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CLAUDE = Path(__file__).resolve().parents[1]
PACK = CLAUDE / "plugins" / "hov-stack" / "skills"
SKILL = PACK / "deep-research"
LOCALIZER = CLAUDE / "scripts" / "skills-localize.sh"


class DeepResearchTests(unittest.TestCase):
    def test_owned_skill_remains_slash_invocable_without_codex_deployment(self):
        # Generic YAML validity and name matching are covered by test_skill_frontmatter.py.
        text = (SKILL / "SKILL.md").read_text()
        frontmatter = text.split("---\n", 2)[1]
        self.assertIn("name: deep-research\n", frontmatter)
        keys = {line.split(":", 1)[0].strip() for line in frontmatter.splitlines()}
        self.assertNotIn("disable-model-invocation", keys)
        self.assertNotIn("user-invocable", keys)
        codex_names = {
            line.split("#", 1)[0].strip()
            for line in (CLAUDE / "codex-skills.txt").read_text().splitlines()
        }
        self.assertNotIn("deep-research", codex_names)

    def test_upstream_is_model_invocable_and_owned_is_opt_in(self):
        settings = json.loads((CLAUDE / "settings.json").read_text())
        overrides = settings["skillOverrides"]
        # Keep the established agent workflow; the owned coordinator is an opt-in trial.
        self.assertEqual(overrides["anthropic-skills:deep-research"], "on")
        self.assertEqual(overrides["deep-research"], "user-invocable-only")

    def test_referenced_harness_documents_exist(self):
        text = (SKILL / "SKILL.md").read_text()
        # The skill finds the checkout four levels above its own resolved directory, not
        # through a home path a plugin install does not have (#47).
        self.assertIn("`<checkout>/harness/`", text)
        self.assertIn("`<checkout>/plugins/hov-stack/skills/deep-research`", text)
        self.assertNotIn("~/hov-stack/", text)
        # The references are optional: a plugin install has no checkout, so the skill names
        # its guard and what it does without them. Compared with line breaks folded.
        flat = " ".join(text.split())
        for guard in (
            "run `realpath` on the directory that holds this `SKILL.md`",
            "Use the references only if `<checkout>/harness/cc-mcp-architecture.md` exists.",
            "Without that file, as in a plugin install,",
            "Without them, write the report where the human asks.",
        ):
            with self.subTest(guard=guard):
                self.assertIn(guard, flat)
        self.assertEqual(SKILL.relative_to(CLAUDE), Path("plugins/hov-stack/skills/deep-research"))
        self.assertEqual(SKILL.parents[3], CLAUDE)
        for name in (
            "cc-mcp-architecture.md",
            "research-delegation.md",
            "deliverable-locations.md",
        ):
            with self.subTest(reference=name):
                self.assertIn(name, text)
                self.assertTrue((CLAUDE / "harness" / name).is_file())
        self.assertTrue(
            (PACK / "data-source-clis" / "SKILL.md").is_file()
        )

    def test_evaluation_cases_keep_the_predeclared_scope(self):
        fixtures = CLAUDE / "tests" / "fixtures" / "deep-research"
        routing = json.loads((fixtures / "routing.json").read_text())
        self.assertEqual(len({case["case_id"] for case in routing}), 12)
        positive = [
            case for case in routing if case["kind"] in {"obvious", "paraphrase"}
        ]
        negative = [case for case in routing if case["kind"] == "near_miss"]
        self.assertEqual(len(positive), 6)
        self.assertEqual(len(negative), 6)
        for case in positive:
            self.assertEqual(case["target_id"], "deep-research")
        for case in negative:
            self.assertIsNone(case["target_id"])
        for case in routing:
            self.assertNotIn("deep-research", case["prompt"].lower())
            self.assertNotIn("deep research", case["prompt"].lower())
        pilot = json.loads((fixtures / "pilot.json").read_text())
        self.assertEqual(len(set(pilot["arms"])), 3)
        self.assertEqual(len({case["id"] for case in pilot["cases"]}), 4)
        for case in pilot["cases"]:
            self.assertEqual(len(case["required_questions"]), 4)
            self.assertTrue(case["critical_checks"])
        for boundary in (
            "private_data_allowed",
            "repository_clones_allowed",
            "retrieved_code_execution_allowed",
            "budget_bypass_allowed",
        ):
            self.assertIs(pilot["controls"][boundary], False)

    def test_localizer_deploys_only_owned_target_and_preserves_synced_skill(self):
        with tempfile.TemporaryDirectory(prefix="deep-research-deploy-") as directory:
            root = Path(directory)
            harness = root / "harness"
            script = harness / "scripts" / LOCALIZER.name
            script.parent.mkdir(parents=True)
            shutil.copy2(LOCALIZER, script)
            local = harness / "plugins" / "hov-stack" / "skills"
            shutil.copytree(SKILL, local / "deep-research")
            # No global retirements, overlays, or Codex adoption in this fixture.
            (harness / "retired-skills.txt").write_text("")
            (harness / "codex-skills.txt").write_text("")
            home = root / "home"
            skills = home / ".claude" / "skills"
            codex = home / ".codex" / "skills"
            codex.mkdir(parents=True)
            upstream = skills / "synced" / "fixture" / "deep-research" / "SKILL.md"
            upstream.parent.mkdir(parents=True)
            upstream.write_text("Upstream fixture: must remain untouched.\n")
            neighbor = skills / "neighbor" / "SKILL.md"
            neighbor.parent.mkdir()
            neighbor.write_text("Neighbor fixture: must remain untouched.\n")
            upstream_before = upstream.read_bytes()
            neighbor_before = neighbor.read_bytes()
            env = dict(
                os.environ,
                HOME=str(home),
                SKILLS_LOCAL_DIR=str(local),
                SKILLS_DIR=str(skills),
                CODEX_SKILLS_DIR=str(codex),
                CODEX_SKILLS_LIST=str(harness / "codex-skills.txt"),
            )

            def run(mode: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    ["bash", str(script), mode],
                    env=env,
                    cwd=root,
                    text=True,
                    capture_output=True,
                    check=False,
                )

            preview = run("--dry-run")
            self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
            self.assertFalse((skills / "deep-research").exists())
            applied = run("apply")
            self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
            deployed = skills / "deep-research" / "SKILL.md"
            self.assertEqual(deployed.read_bytes(), (SKILL / "SKILL.md").read_bytes())
            self.assertEqual(upstream.read_bytes(), upstream_before)
            self.assertEqual(neighbor.read_bytes(), neighbor_before)
            self.assertFalse((codex / "deep-research").exists())
            checked = run("check")
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            repeated = run("apply")
            self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
            self.assertEqual(deployed.read_bytes(), (SKILL / "SKILL.md").read_bytes())
            self.assertEqual(upstream.read_bytes(), upstream_before)
            deployed.write_text(deployed.read_text() + "\nfixture drift\n")
            drift = run("check")
            self.assertEqual(drift.returncode, 1, drift.stdout + drift.stderr)
            self.assertIn("DRIFT", drift.stdout)


if __name__ == "__main__":
    unittest.main()
