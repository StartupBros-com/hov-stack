"""Portable structural checks; these do not establish model behavior."""

import json
from pathlib import Path
import re
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def validate(root):
    manifest = json.loads((root / ".claude-plugin/plugin.json").read_text())
    if manifest["name"] != "harness-optimizer":
        raise ValueError("plugin name")
    if manifest["version"] != (root / "VERSION").read_text().strip():
        raise ValueError("version mismatch")
    if any(key in manifest for key in ("hooks", "mcpServers", "dependencies")):
        raise ValueError("implicit integration")
    skill = root / "skills/harness-optimizer/SKILL.md"
    text = skill.read_text()
    frontmatter = text.split("---", 2)[1]
    if "disable-model-invocation: true" not in frontmatter.splitlines():
        raise ValueError("explicit invocation required")
    if "allowed-tools:" in frontmatter:
        raise ValueError("skill must inherit permissions")
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError("external resource link")
        if path.suffix == ".md":
            content = path.read_text()
            if "/home/" in content or "/Users/" in content or "~/.claude" in content:
                raise ValueError("private path")
            for target in re.findall(r"\]\(([^)]+)\)", content):
                if "://" in target or target.startswith("#"):
                    continue
                resource = (path.parent / target.split("#")[0]).resolve()
                if (
                    not resource.is_relative_to(root.resolve())
                    or not resource.is_file()
                ):
                    raise ValueError("unresolved reference: " + target)
    for name in ("README.md", "LICENSE", "VERSION"):
        if not (root / name).is_file():
            raise ValueError("missing " + name)
    for name in ("settings.json", ".mcp.json", "hooks"):
        if (root / name).exists():
            raise ValueError("activation surface")


class PackageTests(unittest.TestCase):
    def test_boundary_remainder_and_dispatch_instructions(self):
        contracts = {
            "agents/harness-optimizer-investigator.md": (
                "enumeration and search",
                "never broaden then filter",
                "Direct-read named files",
            ),
            "skills/harness-optimizer/references/discovery.md": (
                "authorized files/subtrees",
                "enumeration/search",
                "never broaden then filter",
                "complete shared discovery packet before launching any investigator",
                "unassigned, placeholder or probe agents",
                "no replenishment",
                "no useful increment",
            ),
            "skills/harness-optimizer/references/checkpoints.md": (
                "complete assignment before Agent dispatch",
                "unassigned, placeholder or probe agents of any role",
                "consume the existing review budget",
                "Freeze the shared subject fields once before either lens",
                "authority and atomicity facts in both application lenses",
                "outside the shared evidence",
            ),
            "skills/harness-optimizer/SKILL.md": (
                "An asynchronous launch acknowledgment is not a result",
                "end the turn without further tool calls",
                "pending, not the final reviewed report",
                "lack of supporting evidence alone is not refutation",
                "Retain known unresolved unsupported work and decisions",
                "Resolved or refuted candidates belong in inspection evidence",
            ),
        }
        for path, requirements in contracts.items():
            text = " ".join((ROOT / path).read_text().split())
            for requirement in requirements:
                with self.subTest(path=path, requirement=requirement):
                    self.assertIn(requirement, text)

    def test_package_contract(self):
        validate(ROOT)

    def copied(self):
        tmp = tempfile.TemporaryDirectory(prefix="optimizer-package-")
        self.addCleanup(tmp.cleanup)
        target = Path(tmp.name) / "unrelated" / "plugin"
        shutil.copytree(ROOT, target, ignore=shutil.ignore_patterns("__pycache__"))
        return target

    def test_relocated(self):
        validate(self.copied())

    def test_discovery_package_identity(self):
        target = self.copied()
        manifest = json.loads((target / ".claude-plugin/plugin.json").read_text())
        self.assertEqual(manifest["version"], "0.2.1")
        self.assertEqual((target / "VERSION").read_text().strip(), "0.2.1")
        validate(target)

    def test_readme_discovery_and_evidence_contract(self):
        text = " ".join((ROOT / "README.md").read_text().split())
        for requirement in (
            "/harness-optimizer:harness-optimizer",
            "six evidence lanes",
            "fresh read-only contexts",
            "central deduplication",
            "importance separately from readiness",
            "at most six investigator launches",
            "at most three causal families",
            "18 reviewer attempts",
            "not a total model-call or billing ceiling",
            "temporary diagnostic script",
            "do not establish new discovery conformance",
            "six scenario groups / eleven runs",
            "compatibility with other runtimes is untested",
            "The task supplies no expected verdict",
            "Blanket refusal fails the matched positive control",
            "source-processing failure",
            "no usable coverage",
            "not runtime crash or timeout recovery",
            "exact required case-ID set",
            "outside Claude Code's protected `.claude/` directories",
            "never bypass permissions to force a pass",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)
        for lane in (
            "friction",
            "memory",
            "instructions",
            "context",
            "permissions",
            "tooling",
        ):
            with self.subTest(lane=lane):
                self.assertIn("`" + lane + "`", text)
        self.assertNotIn("skill and its two references", text)
        self.assertNotIn("These traces still pass the stricter current grader", text)

    def test_mismatched_version(self):
        target = self.copied()
        (target / "VERSION").write_text("999.0.0\n")
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            validate(target)

    def test_broken_reference(self):
        target = self.copied()
        skill = target / "skills/harness-optimizer/SKILL.md"
        skill.write_text(skill.read_text() + "\n[required](missing.md)\n")
        with self.assertRaisesRegex(ValueError, "unresolved reference"):
            validate(target)

    def test_private_path(self):
        target = self.copied()
        (target / "README.md").write_text("Load /home/private/tool\n")
        with self.assertRaisesRegex(ValueError, "private path"):
            validate(target)

    def test_user_only(self):
        target = self.copied()
        skill = target / "skills/harness-optimizer/SKILL.md"
        skill.write_text(
            skill.read_text().replace(
                "disable-model-invocation: true", "disable-model-invocation: false"
            )
        )
        with self.assertRaisesRegex(ValueError, "explicit invocation"):
            validate(target)

    def test_read_only_reviewer_and_relative_resources(self):
        agent = (ROOT / "agents/harness-optimizer-reviewer.md").read_text()
        frontmatter = agent.split("---", 2)[1]
        self.assertIn("tools: Read, Glob, Grep", frontmatter.splitlines())
        self.assertNotIn("model:", frontmatter)
        skill = ROOT / "skills/harness-optimizer"
        for name in ("integrations.md", "checkpoints.md"):
            self.assertTrue((skill / "references" / name).is_file())

    def test_reviewer_conditional_format_preserves_material_objections(self):
        path = ROOT / "agents/harness-optimizer-reviewer.md"
        text = " ".join(path.read_text().split())
        for requirement in (
            "When the coordinator requests a machine-readable response",
            "return only the requested format and fields",
            "without Markdown fences or surrounding prose",
            "otherwise use readable prose",
            "empty `objections` array",
            "Formatting never overrides evidence, refutation or consent requirements",
            "preserve every material objection and its required support",
            "explicitly report any format conflict rather than silently dropping them",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)

    def test_read_only_investigator_and_relocated_discovery(self):
        target = self.copied()
        agent = target / "agents/harness-optimizer-investigator.md"
        self.assertTrue(agent.is_file(), "missing lane investigator")
        frontmatter = agent.read_text().split("---", 2)[1]
        fields = dict(line.split(":", 1) for line in frontmatter.splitlines() if line)
        self.assertEqual(set(fields), {"name", "description", "tools"})
        self.assertEqual(fields["name"].strip(), "harness-optimizer-investigator")
        self.assertEqual(fields["tools"].strip(), "Read, Glob, Grep")
        reference = target / "skills/harness-optimizer/references/discovery.md"
        self.assertTrue(reference.is_file(), "missing discovery contract")
        self.assertIn(
            "(../skills/harness-optimizer/references/discovery.md)", agent.read_text()
        )
        integrations = reference.with_name("integrations.md").read_text()
        self.assertIn("(discovery.md)", integrations)
        validate(target)

    def test_skill_links_discovery_and_orders_reviewed_selection(self):
        text = (ROOT / "skills/harness-optimizer/SKILL.md").read_text()
        self.assertIn("(references/discovery.md)", text)
        headings = re.findall(r"^\d+\. \*\*([^*]+)\*\*", text, re.MULTILINE)
        self.assertEqual(
            headings,
            [
                "Establish scope and coverage.",
                "Collect selected lanes.",
                "Reconcile and propose a batch.",
                "Review diagnosis and accept the batch.",
                "Prepare remedies.",
                "Apply and check eligible work.",
                "Challenge the observed result.",
                "Report and stop.",
            ],
        )
        normalized = " ".join(text.split())
        for requirement in (
            "provisional selection",
            "deduplicated evidence, coverage and remainder",
            "Accept the reviewed batch only after diagnosis reconciliation",
            "Direct-user invocation, where required, precedes preparation",
            "Before emission reconcile latest targets and applicable checks",
            "matching scope, sources and revisions",
            "Carry attempts, objections, declines and missing checks",
            "Unrecoverable continuity is unknown",
            "does not erase old declines or authorize unchanged retry",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, normalized)

    def test_diagnosis_packet_preserves_applicability_and_review_budget(self):
        path = ROOT / "skills/harness-optimizer/references/checkpoints.md"
        text = " ".join(path.read_text().split())
        for requirement in (
            "provisional selection plus deduplicated evidence, coverage and remainder",
            "not every raw record",
            "never per-lane reviews",
            "none supports a current problem or useful change",
            "no evidence available to inspect makes diagnosis inapplicable",
            "inapplicable is not passed",
            "one follow-up per stage",
            "18 calls maximum",
            "including failed/time-out calls",
            "original lenses",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)

    def test_complete_report_is_prepared_before_outcome_review(self):
        path = ROOT / "skills/harness-optimizer/SKILL.md"
        text = " ".join(path.read_text().split())
        for requirement in (
            "Prepare the report with all reporting requirements from step 8 before outcome review",
            "When a machine-readable response is requested",
            "without surrounding prose or Markdown fences",
            "If the requested schema cannot represent required facts",
            "identify the conflict before outcome review",
            "do not silently omit facts or append an unreviewed explanation",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)

    def test_async_observations_preserve_exact_report_acceptance(self):
        path = ROOT / "skills/harness-optimizer/references/checkpoints.md"
        text = " ".join(path.read_text().split())
        for requirement in (
            "Code and completed checks bind exact content revisions",
            "Release review, CI, owner handoff and activation are separate observations",
            "source, time and associated revision",
            "pending or unknown",
            "harmless timestamped draft/ready or queue observation may remain historical",
            "does not prove merge, activation or benefit",
            "does not satisfy pending required checks or release gates",
            "later failed check, changed target, new concrete pending decision",
            "refresh affected evidence with the original lenses",
            "stronger activation claim requires applicable outcome review",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)

    def test_existing_mutation_boundaries_remain_explicit(self):
        path = ROOT / "skills/harness-optimizer/SKILL.md"
        text = " ".join(path.read_text().split())
        for requirement in (
            "A required reviewer that is unavailable leaves dependent writes incomplete",
            "unresolved disputes remain unapplied",
            "actual target content, patch identity and effective component version",
            "a content read followed by a write is not atomic protection",
            "supported scoped recovery",
            "post-preview human consent",
            "Do not retry refused changes through another specialist",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)

    def test_scenario_acceptance_inventory(self):
        scenarios = json.loads((ROOT / "tests/scenarios.json").read_text())
        self.assertEqual(len({case["id"] for case in scenarios}), len(scenarios))
        self.assertLessEqual(len(scenarios), 20)
        covered = {item for case in scenarios for item in case["covers"]}
        self.assertTrue({"AE" + str(n) for n in range(1, 11)} <= covered)
        self.assertTrue({"R16", "R17"} <= covered)

    def test_implicit_installer(self):
        target = self.copied()
        path = target / ".claude-plugin/plugin.json"
        manifest = json.loads(path.read_text())
        manifest["dependencies"] = ["private-installer"]
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "implicit integration"):
            validate(target)


if __name__ == "__main__":
    unittest.main()
