"""Structural prompt-contract checks, not dispatch or model-compliance proof."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "skills/harness-optimizer/references/discovery.md"


class DiscoveryContractTests(unittest.TestCase):
    def test_scope_and_lane_catalog(self):
        self.assertTrue(REFERENCE.is_file(), "missing discovery contract")
        text = REFERENCE.read_text()
        lanes = re.findall(r"^\| `([^`]+)` +\|", text, re.MULTILINE)
        self.assertEqual(
            lanes,
            ["friction", "memory", "instructions", "context", "permissions", "tooling"],
        )
        for requirement in (
            "Explicit scope and lane selection wins",
            "Papercut-only selects only `friction`",
            "account for all six lanes",
            "ask one scope question",
            "does not imply global scope",
            "before substantive investigation",
            "fresh read-only context",
            "supplied evidence without private infrastructure",
        ):
            with self.subTest(requirement=requirement):
                self.assertTrue(requirement in text, f"missing contract: {requirement}")

    def assert_contract(self, *requirements):
        text = " ".join(REFERENCE.read_text().split())
        for requirement in requirements:
            with self.subTest(requirement=requirement):
                self.assertTrue(requirement in text, f"missing contract: {requirement}")

    def test_specialist_and_unavailable_coverage_boundaries(self):
        self.assert_contract(
            "(integrations.md) remains authoritative",
            "not an invocation chain or compatibility claim",
            "discovery cannot clone restricted audit, mining or apply workflows",
            "An operation called audit is not automatically read-only",
            "user-only or unavailable",
            "independently authorized supplied evidence",
            "state the missing coverage",
            "Source absence is not completed investigation",
            "Low use is not removal evidence",
            "CLI doctor adoption remains unsupported",
        )

    def test_packet_source_bounds_and_provenance(self):
        self.assert_contract(
            "lane ID, selected scope, exact source handles/revisions",
            "allowed read boundary, lane brief and common return contract",
            "one declared source batch per lane",
            "smallest sufficient authorized source batch",
            "claim and a plausible refutation",
            "supplied authoritative sources before broader diagnostics",
            "ceilings, not collection targets",
            "producing operation/source identity",
            "at most 20 named files or 100 event records",
            "latest 7 days",
            "Smaller specialist bounds win",
            "Declare sampling and omissions before collection",
            "coordinator obtains necessary CLI evidence through supported read operations",
            "not replace orchestration or expand sources",
            "origin event IDs or source locator plus version/time",
            "operator corrections, execution friction, investigation-generated evidence and synthetic fixtures",
        )

    def test_measurement_contract_and_outcome_lens_stay_connected(self):
        skill = " ".join(
            (ROOT / "skills/harness-optimizer/SKILL.md").read_text().split()
        )
        for requirement in (
            "equivalent scope, population, enabled checks, sampling basis, outcome definition",
            "window/exposure",
            "separate observations",
            "comparable subset",
            "removed checks are lost coverage, not benefit",
        ):
            self.assertIn(requirement, skill)
        from run_behavioral import LENS_INSTRUCTIONS

        checkpoints = (
            ROOT / "skills/harness-optimizer/references/checkpoints.md"
        ).read_text()
        lens = LENS_INSTRUCTIONS["outcome"]["attribution-regression"]
        self.assertIn(lens.lower(), checkpoints.lower())
        self.assertIn("lost coverage", lens)

    def test_return_distinguishes_empty_partial_malformed_and_over_limit(self):
        self.assert_contract(
            "Four required fields",
            "`lane`",
            "`status`",
            "`coverage`",
            "`findings`",
            "`complete`",
            "`partial`",
            "`unavailable`",
            "`failed`",
            "actual sources, revision, window, sample boundary, omissions and reasons",
            "zero to three candidates",
            "bounded claim, target, evidence locators/provenance",
            "causal hypothesis or uncertainty, and a refuting observation",
            "expected behavioral benefit",
            "recurrence/exposure when known",
            "existing work references when found",
            "Malformed is not successful empty",
            "Empty findings require actual coverage",
            "Supported partial candidates may be used with omissions visible",
            "Over-limit returns are partial",
            "do not claim extras examined",
            "No invented patch, global priority or callability",
        )

    def test_collection_barrier_precedes_central_selection(self):
        self.assert_contract(
            "Freeze the selected-lane packets before launch",
            "Launch independent lanes together within host capacity",
            "queue the remainder",
            "all launched terminal results or explicit failures/unavailability",
            "before ranking or selecting families",
            "18 candidates before deduplication",
            "24 discovery-plus-review attempts is not a total model-call or billing ceiling",
        )

    def test_cross_lane_event_and_cause_deduplication(self):
        self.assert_contract(
            "same origin event cited by multiple lanes counts once",
            "one malformed invocation appearing in friction and permissions",
            "one event and one causal family",
            "same mechanism and repair boundary",
            "filename or word similarity is insufficient",
            "Attach findings to known work",
            "not independent recurrence",
        )

    def test_importance_does_not_collapse_into_readiness(self):
        self.assert_contract(
            "correctness/data-loss and blocked eligible work first",
            "evidence strength, organic recurrence/exposure",
            "expected benefit versus regression risk and effort",
            "No fabricated scores",
            "Harmless high-volume telemetry does not automatically outrank a reproduced failure",
            "missing recurrence does not erase a single reproduced correctness defect",
            "ready / concrete human decision / unsupported-or-insufficiently-evidenced",
            "all higher-priority blocked findings",
            "independent ready work",
            "no replenishment after batch acceptance",
        )

    def test_diagnostic_scripts_are_bounded_exceptions(self):
        self.assert_contract(
            "supported public operations and bundled collectors",
            "question, bounded inputs, expected output and limits before writing",
            "cannot answer the named hypothesis",
            "unselected histories, refused operations",
            "restricted-specialist reimplementation or a new consent store",
            "separately tested helper candidates, not automatic additions",
        )

    def test_launch_budget_is_separate_and_not_replenished(self):
        self.assert_contract(
            "at most 6 launched investigators",
            "one per active lane",
            "A launched failure consumes an attempt",
            "no same-batch redispatch",
            "Capacity rejection before launch remains queued",
            "eventual unavailability explicitly",
            "separate from repairs and review",
            "Do not replenish the discovery budget",
            "Host cancellation and limits",
            "not hard runtime enforcement",
        )


if __name__ == "__main__":
    unittest.main()
