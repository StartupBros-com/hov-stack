#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
CHECKER = CLAUDE / "scripts" / "skill-collision-check.py"

_spec = importlib.util.spec_from_file_location("skill_collision_check_module", CHECKER)
SC = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SC)

FLAKY = "Find and fix flaky tests in a CI pipeline. Use when tests intermittently fail."
UNRELATED = "Provision Postgres read replicas across regions with automatic failover."


def write_skill(root: Path, dirname: str, description: str, *, name: str | None = None,
                self_disabled: bool = False) -> Path:
    d = root / dirname
    d.mkdir(parents=True, exist_ok=True)
    lines = ["---", f"name: {name or dirname}", f"description: {description}"]
    if self_disabled:
        lines.append("disable-model-invocation: true")
    lines += ["---", "", "body"]
    (d / "SKILL.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return d


def analyze(root: Path, overrides: dict[str, str] | None = None,
            threshold: float = 0.75) -> tuple[list[dict], list[dict]]:
    """Mirror main()'s classification without invoking argparse/stdout."""
    skills = SC.discover([root])
    for s in skills:
        s["visible"], s["visibility_reason"] = SC.visibility(s, overrides or {})
        s["words"] = SC.content_words(s["description"])

    findings = []
    by_name: dict[str, list[dict]] = {}
    for s in skills:
        by_name.setdefault(s["name"], []).append(s)
    for name, group in by_name.items():
        if len(group) > 1:
            findings.append({"kind": "duplicate-name", "severity": "LIVE",
                             "skills": sorted(g["dir"] for g in group)})

    from itertools import combinations
    for a, b in combinations(skills, 2):
        if a["name"] == b["name"]:
            continue
        score = SC.jaccard(a["words"], b["words"])
        if score < threshold:
            continue
        findings.append({
            "kind": "description-collision",
            "severity": "LIVE" if (a["visible"] and b["visible"]) else "LATENT",
            "skills": sorted([a["dir"], b["dir"]]),
            "score": score,
        })
    return ([f for f in findings if f["severity"] == "LIVE"],
            [f for f in findings if f["severity"] == "LATENT"])


class SeverityModelTests(unittest.TestCase):
    """The whole point of this checker: a demoted side neutralizes a collision."""

    def test_two_visible_identical_descriptions_are_LIVE(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            write_skill(root, "beta", FLAKY)
            live, latent = analyze(root)
            self.assertEqual(len(live), 1)
            self.assertEqual(live[0]["skills"], ["alpha", "beta"])
            self.assertEqual(latent, [])

    def test_demoted_side_downgrades_collision_to_LATENT(self):
        """The real roster case: base is user-invocable-only, fork is always-on."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "thing", FLAKY)
            write_skill(root, "thing-local", FLAKY)
            live, latent = analyze(root, {"thing": "user-invocable-only"})
            self.assertEqual(live, [])
            self.assertEqual(len(latent), 1)

    def test_off_override_also_downgrades_to_LATENT(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            write_skill(root, "beta", FLAKY)
            live, latent = analyze(root, {"beta": "off"})
            self.assertEqual(live, [])
            self.assertEqual(len(latent), 1)

    def test_disable_model_invocation_downgrades_to_LATENT(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            write_skill(root, "beta", FLAKY, self_disabled=True)
            live, latent = analyze(root)
            self.assertEqual(live, [])
            self.assertEqual(len(latent), 1)

    def test_name_only_override_stays_LIVE(self):
        """`name-only` still shows the model a name, so it can still misroute."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            write_skill(root, "beta", FLAKY)
            live, _ = analyze(root, {"beta": "name-only"})
            self.assertEqual(len(live), 1)


class DetectionTests(unittest.TestCase):
    def test_unrelated_descriptions_do_not_collide(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            write_skill(root, "gamma", UNRELATED)
            live, latent = analyze(root)
            self.assertEqual((live, latent), ([], []))

    def test_duplicate_name_is_always_LIVE_even_with_different_descriptions(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "dir-one", FLAKY, name="samename")
            write_skill(root, "dir-two", UNRELATED, name="samename")
            live, _ = analyze(root)
            self.assertEqual(len(live), 1)
            self.assertEqual(live[0]["kind"], "duplicate-name")

    def test_boilerplate_alone_does_not_trigger_a_collision(self):
        """'Use when ...' phrasing is in nearly every description; stopwords must eat it."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", "Use this skill when the user asks to do the thing.")
            write_skill(root, "beta", "Use this skill when the user asks for another matter.")
            live, latent = analyze(root)
            self.assertEqual((live, latent), ([], []))

    def test_symlinked_duplicate_is_not_a_self_collision(self):
        """~/.codex/skills symlinks into ~/.claude/skills; one skill, not two."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            real = write_skill(root, "alpha", FLAKY)
            try:
                os.symlink(real, root / "alpha-link", target_is_directory=True)
            except (OSError, NotImplementedError):
                self.skipTest("symlinks unavailable on this filesystem")
            live, latent = analyze(root)
            self.assertEqual((live, latent), ([], []))

    def test_skill_without_frontmatter_is_skipped_not_crashed(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            bad = root / "broken"
            bad.mkdir()
            (bad / "SKILL.md").write_text("no frontmatter here\n", encoding="utf-8")
            self.assertEqual([s["dir"] for s in SC.discover([root])], ["alpha"])

    def test_dot_dirs_are_skipped(self):
        """jsm parks removed skills under .trash/ — those must not be scanned."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            write_skill(root, "alpha", FLAKY)
            write_skill(root, ".trash", FLAKY)
            self.assertEqual([s["dir"] for s in SC.discover([root])], ["alpha"])


class CliFloorTests(unittest.TestCase):
    def run_checker(self, root: Path) -> subprocess.CompletedProcess:
        settings = root.parent / "settings.json"
        settings.write_text("{}\n", encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(CHECKER), "--sources", str(root),
             "--settings", str(settings)],
            capture_output=True, text=True, check=False,
        )

    def test_empty_existing_source_is_unverified(self):
        """PLANTED NEGATIVE: this was 'no skills found' with exit 0."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "skills"
            root.mkdir()
            result = self.run_checker(root)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("skill collision corpus", result.stderr)
            self.assertIn("examined 0 item(s), expected at least 1", result.stderr)

    def test_populated_source_has_no_false_floor_warning(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "skills"
            write_skill(root, "alpha", FLAKY)
            write_skill(root, "gamma", UNRELATED)
            result = self.run_checker(root)
            self.assertEqual(result.returncode, 0)
            self.assertIn("scanned 2 skills", result.stdout)
            self.assertNotIn("refusing to report clean", result.stderr)


class FrontmatterParsingTests(unittest.TestCase):
    def test_folded_block_description_is_flattened(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            d = root / "folded"
            d.mkdir()
            (d / "SKILL.md").write_text(
                "---\nname: folded\ndescription: >-\n  Find and fix flaky tests in a CI\n"
                "  pipeline. Use when tests intermittently fail.\n---\nbody\n",
                encoding="utf-8")
            write_skill(root, "plain", FLAKY)
            live, _ = analyze(root)
            self.assertEqual(len(live), 1, "folded scalar should compare equal to plain")

    def test_quoted_description_is_unwrapped(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            d = root / "quoted"
            d.mkdir()
            (d / "SKILL.md").write_text(
                f'---\nname: quoted\ndescription: "{FLAKY}"\n---\nbody\n', encoding="utf-8")
            skills = SC.discover([root])
            self.assertEqual(skills[0]["description"], FLAKY)

    def test_missing_settings_file_yields_empty_overrides(self):
        self.assertEqual(SC.load_overrides(Path("/nonexistent/settings.json")), {})

    def test_malformed_settings_file_yields_empty_overrides(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "settings.json"
            p.write_text("{not json", encoding="utf-8")
            self.assertEqual(SC.load_overrides(p), {})

    def test_overrides_are_read_from_settings(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "settings.json"
            p.write_text(json.dumps({"skillOverrides": {"a": "off"}}), encoding="utf-8")
            self.assertEqual(SC.load_overrides(p), {"a": "off"})


class JaccardTests(unittest.TestCase):
    def test_empty_sets_score_zero(self):
        self.assertEqual(SC.jaccard(frozenset(), frozenset({"a"})), 0.0)

    def test_identical_sets_score_one(self):
        self.assertEqual(SC.jaccard(frozenset({"a", "b"}), frozenset({"a", "b"})), 1.0)

    def test_disjoint_sets_score_zero(self):
        self.assertEqual(SC.jaccard(frozenset({"a"}), frozenset({"b"})), 0.0)


if __name__ == "__main__":
    unittest.main()
