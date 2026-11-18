#!/usr/bin/env python3
"""CLI contracts for plan-unit filing; gh is always a local shell stub."""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "plan-units-to-issues.py"
FIXTURES = REPO_ROOT / "tests" / "fixtures" / "plan-units"
CI_PLAN = FIXTURES / "2026-10-05-1421-feat-catalog-validation-plan.md"
RECOVERY_PLAN = FIXTURES / "2026-10-13-0112-feat-catalog-resume-plan.md"
REPO = "example/plans"

GH_HANDLER = r"""
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
config = json.loads(Path(os.environ["GH_TEST_CONFIG"]).read_text())
log = Path(os.environ["GH_TEST_LOG"])
previous = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
entry = {"args": args, "cwd": os.getcwd()}
if "--body-file" in args:
    entry["body"] = Path(args[args.index("--body-file") + 1]).read_text()
with log.open("a") as handle:
    handle.write(json.dumps(entry) + "\n")
if args[:len(config.get("fail", []))] == config.get("fail", ["never"]):
    sys.exit("stubbed gh failure")
if args == ["--version"]:
    print(config.get("version", "gh version 2.94.0 (fixture)"))
elif args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": config.get("repo", "example/plans")}))
elif args[:2] == ["issue", "list"]:
    print(json.dumps(config.get("existing" if "--search" in args else "recent", [])))
elif args[:2] == ["issue", "view"]:
    print(json.dumps({"blockedBy": config.get("blocked", {}).get(args[2], {"totalCount": 0, "nodes": []})}))
elif args[:2] == ["issue", "create"]:
    count = sum(item["args"][:2] == ["issue", "create"] for item in previous)
    print("https://github.com/" + config.get("repo", "example/plans") + "/issues/" + str(101 + count))
elif args[:2] == ["issue", "edit"]:
    print("https://github.com/example/plans/issues/" + args[2])
else:
    sys.exit("unexpected gh arguments: " + repr(args))
"""


class PlanUnitsToIssuesTests(unittest.TestCase):
    def setUp(self) -> None:
        tempdir = tempfile.TemporaryDirectory(prefix="plan-unit-tests-", dir="/tmp")
        self.addCleanup(tempdir.cleanup)
        self.tmp = Path(tempdir.name)
        self.log = self.tmp / "gh.jsonl"
        self.config = self.tmp / "config.json"
        self.configure()
        handler = self.tmp / "gh-handler.py"
        handler.write_text(GH_HANDLER, encoding="utf-8")
        stub = self.tmp / "gh"
        stub.write_text(
            '#!/bin/sh\nexec "$GH_TEST_PYTHON" "$GH_TEST_HANDLER" "$@"\n',
            encoding="utf-8",
        )
        stub.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.tmp) + os.pathsep + os.environ["PATH"],
            "GH_TEST_PYTHON": sys.executable,
            "GH_TEST_HANDLER": str(handler),
            "GH_TEST_LOG": str(self.log),
            "GH_TEST_CONFIG": str(self.config),
        }

    def configure(self, **config: object) -> None:
        self.config.write_text(json.dumps(config), encoding="utf-8")

    def calls(self, *prefix: str) -> list[dict]:
        entries = (
            [json.loads(line) for line in self.log.read_text().splitlines()]
            if self.log.exists()
            else []
        )
        return [item for item in entries if item["args"][: len(prefix)] == list(prefix)]

    def run_cli(self, plan: Path = CI_PLAN, *args: str) -> subprocess.CompletedProcess:
        if plan.is_relative_to(FIXTURES):
            plan = self.stage(plan)
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(plan), "--parent", "1805", *args],
            cwd=REPO_ROOT,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )

    def edges(self) -> dict[int, list[int]]:
        return {
            int(call["args"][2]): [
                int(n)
                for n in call["args"][call["args"].index("--add-blocked-by") + 1].split(
                    ","
                )
            ]
            for call in self.calls("issue", "edit")
        }

    def plan(
        self, text: str, name: str = "2026-10-14-1200-fix-fixture-plan.md"
    ) -> Path:
        root = self.tmp / "checkout"
        (root / ".git").mkdir(parents=True, exist_ok=True)
        docs = root / "docs" / "plans"
        docs.mkdir(parents=True, exist_ok=True)
        path = docs / name
        path.write_text(text, encoding="utf-8", newline="")
        return path

    def stage(self, fixture: Path) -> Path:
        """Place a committed fixture plan at docs/plans/<name> in the temp
        checkout, byte for byte, so its Plan: line and checkout discovery
        read exactly as they would for the live plan."""
        return self.plan(fixture.read_bytes().decode("utf-8"), fixture.name)

    def trailer(self, plan: Path = CI_PLAN, parent: int = 1805) -> str:
        """The two lines a create appends; reuse needs both to match."""
        return f"Part of #{parent}\nPlan: docs/plans/{plan.name}\n"

    def existing(self, plan: Path = CI_PLAN) -> list[dict]:
        return [
            {
                "number": 200 + n,
                "title": f"feat: U{n} Prior title",
                "state": "CLOSED" if n % 2 else "OPEN",
                "body": f"### U{n}. Prior title\n\n" + self.trailer(plan),
            }
            for n in range(1, 8)
        ]

    def test_recovery_plan_includes_forward_dependencies(self) -> None:
        result = self.run_cli(RECOVERY_PLAN, "--repo", REPO)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 6)
        self.assertEqual(
            self.edges(), {102: [101, 103], 104: [101, 103, 105], 106: [104]}
        )
        self.assertIn("unit\ttitle\tissue\tblocked-by", result.stdout)

    def test_absent_dependency_files_nothing_and_never_calls_gh(self) -> None:
        for line in ("**Dependencies:** U9.", "Dependencies: U9"):
            with self.subTest(line=line):
                plan = self.plan(f"### U1. First\n\n{line}\n\n## End\n")
                result = self.run_cli(plan)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dependency U9 names an absent unit", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_cycles_file_nothing_and_never_call_gh(self) -> None:
        for text in (
            "### U1. First\n**Dependencies:** U2\n### U2. Second\n**Dependencies:** U1\n## End\n",
            "### U1. Self\n**Dependencies:** U1\n## End\n",
        ):
            with self.subTest(text=text):
                result = self.run_cli(self.plan(text))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dependency cycle", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_no_units_is_a_clear_local_error(self) -> None:
        result = self.run_cli(self.plan("# A plan\n## Implementation\nNo units yet.\n"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no unit sections", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_ambiguous_sections_file_nothing(self) -> None:
        cases = {
            "malformed": "### U1.\n**Dependencies:** none\n## End\n",
            "fence": "### U1. First\n**Dependencies:** none\n```md\n### U2. Hidden\n## End\n",
            "level-one": "### U1. First\n**Dependencies:** none\n# Unexpected\n",
        }
        for name, text in cases.items():
            with self.subTest(name=name):
                result = self.run_cli(self.plan(text))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot bound", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_duplicate_units_or_dependencies_lines_file_nothing(self) -> None:
        cases = {
            "duplicate unit": "### U1. First\n**Dependencies:** none\n### U1. Again\n**Dependencies:** none\n",
            "missing line": "### U1. First\nSome text.\n## End\n",
            "duplicate line": "### U1. First\n**Dependencies:** none\n**Dependencies:** U2\n## End\n",
        }
        for name, text in cases.items():
            with self.subTest(name=name):
                result = self.run_cli(self.plan(text))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_rerun_reuses_open_and_closed_units_and_only_adds_missing_edges(
        self,
    ) -> None:
        self.configure(
            existing=self.existing(),
            blocked={
                "204": {"totalCount": 1, "nodes": [{"number": 202}]},
                "205": {
                    "totalCount": 3,
                    "nodes": [{"number": 202}, {"number": 203}, {"number": 204}],
                },
            },
        )
        result = self.run_cli(CI_PLAN, "--repo", REPO, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("issue", "create"), [])
        self.assertEqual(self.edges(), {204: [203], 207: [205]})
        self.assertEqual(
            json.loads(result.stdout)["U4"],
            {
                "number": 204,
                "url": "https://github.com/example/plans/issues/204",
                "blocked_by": [202, 203],
            },
        )
        listing = self.calls("issue", "list")[0]["args"]
        self.assertEqual(listing[listing.index("--state") + 1], "all")
        self.assertEqual(
            listing[listing.index("--search") + 1], '"Part of #1805" in:body'
        )
        self.assertEqual(
            listing[listing.index("--json") + 1], "number,title,body,state"
        )
        self.assertEqual(listing[listing.index("--limit") + 1], "200")
        self.assertEqual(len(self.calls("issue", "view")), 3)

    def test_complete_rerun_makes_no_writes(self) -> None:
        self.configure(
            existing=self.existing(),
            blocked={
                "204": {"totalCount": 2, "nodes": [{"number": 202}, {"number": 203}]},
                "205": {
                    "totalCount": 3,
                    "nodes": [{"number": 202}, {"number": 203}, {"number": 204}],
                },
                "207": {"totalCount": 1, "nodes": [{"number": 205}]},
            },
        )
        result = self.run_cli(CI_PLAN, "--repo", REPO)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("issue", "create"), [])
        self.assertEqual(self.calls("issue", "edit"), [])

    def test_lowercase_repo_records_all_units_and_preserves_canonical_blockers(
        self,
    ) -> None:
        canonical_repo = "example-org/example-repo"
        plan = self.plan(
            "### U1. First\n**Dependencies:** none\n"
            "### U2. Second\n**Dependencies:** U1\n"
            "### U3. Third\n**Dependencies:** none\n"
            "### U4. Fourth\n**Dependencies:** U2\n"
        )
        self.configure(
            repo=canonical_repo,
            existing=self.existing(plan)[:2],
            blocked={
                "202": {
                    "totalCount": 1,
                    "nodes": [
                        {
                            "number": 201,
                            "url": "https://github.com/example-org/example-repo/issues/201",
                        }
                    ],
                }
            },
        )
        result = self.run_cli(plan, "--repo", "example-org/example-repo", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 2)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "U1": {
                    "number": 201,
                    "url": "https://github.com/example-org/example-repo/issues/201",
                    "blocked_by": [],
                },
                "U2": {
                    "number": 202,
                    "url": "https://github.com/example-org/example-repo/issues/202",
                    "blocked_by": [201],
                },
                "U3": {
                    "number": 101,
                    "url": "https://github.com/example-org/example-repo/issues/101",
                    "blocked_by": [],
                },
                "U4": {
                    "number": 102,
                    "url": "https://github.com/example-org/example-repo/issues/102",
                    "blocked_by": [202],
                },
            },
        )
        self.assertEqual(self.edges(), {102: [202]})
        discovery = self.calls("repo", "view")
        self.assertEqual(len(discovery), 1)
        self.assertEqual(
            discovery[0]["args"],
            ["repo", "view", "example-org/example-repo", "--json", "nameWithOwner"],
        )
        for call in self.calls("issue"):
            args = call["args"]
            self.assertEqual(args[args.index("--repo") + 1], canonical_repo)

    def test_rerun_reuses_recent_issue_missing_from_search(self) -> None:
        plan = self.plan("### U1. First\n**Dependencies:** none\n")
        self.configure(
            existing=[],
            recent=[
                {
                    "number": 201,
                    "title": "fix: U1 First",
                    "body": "### U1. First\n**Dependencies:** none\n\n"
                    + self.trailer(plan),
                    "url": "https://github.com/example/plans/issues/201",
                },
                {
                    "number": 901,
                    "title": "fix: U1 Other parent",
                    "body": self.trailer(plan, parent=18050),
                },
                {
                    "number": 902,
                    "title": "fix: U1 Unrelated",
                    "body": "No parent marker\n",
                },
            ],
        )
        result = self.run_cli(plan, "--repo", REPO, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 0)
        self.assertEqual(self.calls("issue", "edit"), [])
        self.assertEqual(
            json.loads(result.stdout)["U1"],
            {
                "number": 201,
                "url": "https://github.com/example/plans/issues/201",
                "blocked_by": [],
            },
        )
        listings = self.calls("issue", "list")
        self.assertEqual(len(listings), 2)
        recent_listing = next(
            call["args"] for call in listings if "--search" not in call["args"]
        )
        self.assertEqual(recent_listing[recent_listing.index("--state") + 1], "all")
        self.assertEqual(
            recent_listing[recent_listing.index("--json") + 1], "number,title,body,url"
        )
        self.assertEqual(recent_listing[recent_listing.index("--limit") + 1], "200")

    def test_rerun_unions_search_and_recent_issues_without_duplicate_matches(
        self,
    ) -> None:
        plan = self.plan(
            "### U1. First\n**Dependencies:** none\n"
            "### U2. Second\n**Dependencies:** none\n"
        )
        self.configure(
            existing=self.existing(plan)[:1],
            recent=[
                {**item, "body": self.trailer(plan)} for item in self.existing()[:2]
            ],
        )
        result = self.run_cli(plan, "--repo", REPO, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 0)
        mapping = json.loads(result.stdout)
        self.assertEqual(mapping["U1"]["number"], 201)
        self.assertEqual(mapping["U2"]["number"], 202)

    def test_distinct_search_and_recent_matches_fail_before_writes(self) -> None:
        self.configure(
            existing=self.existing()[:1],
            recent=[
                {"number": 901, "title": "fix: U1 Duplicate", "body": self.trailer()}
            ],
        )
        result = self.run_cli(CI_PLAN, "--repo", REPO)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple existing issues match U1", result.stderr)
        self.assertEqual(self.calls("issue", "create"), [])
        self.assertEqual(self.calls("issue", "edit"), [])

    def test_partial_rerun_creates_only_absent_units(self) -> None:
        self.configure(existing=self.existing()[:3:2])
        result = self.run_cli(CI_PLAN, "--repo", REPO, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 5)
        mapping = json.loads(result.stdout)
        self.assertEqual(mapping["U1"]["number"], 201)
        self.assertEqual(mapping["U3"]["number"], 203)
        self.assertEqual(
            self.edges(), {102: [101, 203], 103: [101, 203, 102], 105: [103]}
        )

    def test_dry_run_prints_table_and_quoted_commands_without_gh_calls(self) -> None:
        result = self.run_cli(CI_PLAN, "--repo", REPO, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("unit\ttitle\tissue\tblocked-by", result.stdout)
        self.assertIn("U2, U3, U4", result.stdout)
        commands = [
            shlex.split(line)
            for line in result.stdout.splitlines()
            if line.startswith("gh ")
        ]
        creates = [cmd for cmd in commands if cmd[:3] == ["gh", "issue", "create"]]
        edits = [cmd for cmd in commands if cmd[:3] == ["gh", "issue", "edit"]]
        self.assertEqual(len(creates), 7)
        self.assertEqual(len(edits), 3)
        self.assertEqual(
            creates[0][creates[0].index("--title") + 1], "feat: U1 Workflow draft gate"
        )
        self.assertEqual(
            edits[0][edits[0].index("--add-blocked-by") + 1], "<U2-number>,<U3-number>"
        )
        for command in creates:
            self.assertFalse(Path(command[command.index("--body-file") + 1]).exists())

    def test_dry_run_with_default_repo_and_json_still_never_calls_gh(self) -> None:
        result = self.run_cli(CI_PLAN, "--dry-run", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("gh repo view --json nameWithOwner", result.stderr)
        self.assertIn("<plan-checkout-repo>", result.stderr)
        self.assertEqual(
            json.loads(result.stdout)["U4"],
            {"number": None, "url": None, "blocked_by": ["U2", "U3"]},
        )

    def test_default_repo_is_discovered_from_plans_checkout(self) -> None:
        plan = self.plan("### U1. First\n**Dependencies:** none\n")
        result = self.run_cli(plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls("repo", "view")[0]
        self.assertEqual(call["args"], ["repo", "view", "--json", "nameWithOwner"])
        self.assertEqual(call["cwd"], str(self.tmp / "checkout"))
        create = self.calls("issue", "create")[0]
        self.assertEqual(create["args"][create["args"].index("--repo") + 1], REPO)
        self.assertIn(
            "Plan: docs/plans/2026-10-14-1200-fix-fixture-plan.md\n", create["body"]
        )

    def test_body_preserves_prose_fences_deeper_headings_and_eof(self) -> None:
        section = (
            "### U1. Keep $(literal) and `backticks`\n\n"
            "**Dependencies:** none for the helper; U99 is only prose.\n"
            "#### Detail\nA body with Unicode: café.\n"
            "```md\n### U9. An example\n**Dependencies:** U88\n```\n"
        )
        plan = self.plan(section + "### Notes\nKeep this out of the issue.\n")
        result = self.run_cli(
            plan, "--repo", REPO, "--label", "custom label", "--label", "review"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        create = self.calls("issue", "create")[0]
        self.assertEqual(len(self.calls("issue", "create")), 1)
        self.assertEqual(
            create["body"],
            section
            + "\nPart of #1805\nPlan: docs/plans/2026-10-14-1200-fix-fixture-plan.md\n",
        )
        args = create["args"]
        self.assertEqual(
            [args[i + 1] for i, arg in enumerate(args) if arg == "--label"],
            ["custom label", "review"],
        )
        self.assertEqual(
            args[args.index("--title") + 1], "fix: U1 Keep $(literal) and `backticks`"
        )

    def test_dependency_tokens_are_deduplicated_and_prose_is_preserved(self) -> None:
        plan = self.plan(
            "### U1. First\n**Dependencies:** U2, U2 (fixtures drive it).\n### U2. Second\n**Dependencies:** none.\n"
        )
        result = self.run_cli(plan, "--repo", REPO)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.edges(), {101: [102]})
        self.assertIn(
            "**Dependencies:** U2, U2 (fixtures drive it).",
            self.calls("issue", "create")[0]["body"],
        )

    def test_title_keeps_literal_hash_and_strips_markdown_closing_hashes(self) -> None:
        plan = self.plan(
            "### U1. Interop with C# ###\n**Dependencies:** none\n### U2. More C#\n**Dependencies:** none"
        )
        result = self.run_cli(plan, "--repo", REPO)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [
                call["args"][call["args"].index("--title") + 1]
                for call in self.calls("issue", "create")
            ],
            ["fix: U1 Interop with C#", "fix: U2 More C#"],
        )

    def test_version_guard_rejects_old_or_unparseable_gh_before_writes(self) -> None:
        for version in ("gh version 2.93.9 (fixture)", "unknown version"):
            with self.subTest(version=version):
                self.configure(version=version)
                result = self.run_cli(CI_PLAN, "--repo", REPO)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("gh >= 2.94.0", result.stderr)
                self.assertEqual(self.calls("issue"), [])

    def test_ambiguous_existing_units_fail_before_writes(self) -> None:
        self.configure(
            existing=[
                self.existing()[0],
                {
                    "number": 901,
                    "title": "fix: U1 Duplicate",
                    "state": "CLOSED",
                    "body": self.trailer(),
                },
            ]
        )
        result = self.run_cli(CI_PLAN, "--repo", REPO)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple existing issues match U1", result.stderr)
        self.assertEqual(self.calls("issue", "create"), [])
        self.assertEqual(self.calls("issue", "edit"), [])

    def test_incomplete_blocker_read_fails_before_any_creation(self) -> None:
        self.configure(
            existing=[self.existing()[3]],
            blocked={"204": {"totalCount": 2, "nodes": [{"number": 202}]}},
        )
        result = self.run_cli(CI_PLAN, "--repo", REPO)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete blockedBy", result.stderr)
        self.assertEqual(self.calls("issue", "create"), [])
        self.assertEqual(self.calls("issue", "edit"), [])

    def test_gh_creation_failure_cleans_body_files_and_never_adds_edges(self) -> None:
        self.configure(fail=["issue", "create"])
        result = self.run_cli(CI_PLAN, "--repo", REPO)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stubbed gh failure", result.stderr)
        self.assertEqual(self.calls("issue", "edit"), [])
        call = self.calls("issue", "create")[0]
        self.assertFalse(
            Path(call["args"][call["args"].index("--body-file") + 1]).exists()
        )

    def test_gh_edge_failure_is_reported_and_cleans_body_files(self) -> None:
        self.configure(fail=["issue", "edit"])
        result = self.run_cli(CI_PLAN, "--repo", REPO)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stubbed gh failure", result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 7)
        for call in self.calls("issue", "create"):
            self.assertFalse(
                Path(call["args"][call["args"].index("--body-file") + 1]).exists()
            )

    def test_help_works_without_gh(self) -> None:
        result = self.run_cli(CI_PLAN, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--parent", result.stdout)
        self.assertIn("--dry-run", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_ci_once_plan_creates_seven_units_before_adding_edges(self) -> None:
        result = self.run_cli(CI_PLAN, "--repo", REPO, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        creates = self.calls("issue", "create")
        self.assertEqual(len(creates), 7)
        self.assertEqual(
            [call["args"][call["args"].index("--title") + 1] for call in creates],
            [
                "feat: U1 Workflow draft gate",
                "feat: U2 Local result record",
                "feat: U3 Shared head-checks helper and the ready-head readers",
                "feat: U4 Draft paths for the loop-driving readers",
                "feat: U5 Owner ready sequence",
                "feat: U6 Doctrine and vocabulary",
                "feat: U7 Measurement modes",
            ],
        )
        self.assertEqual(
            self.edges(), {104: [102, 103], 105: [102, 103, 104], 107: [105]}
        )
        mutations = [
            call["args"][1]
            for call in self.calls("issue")
            if call["args"][1] in {"create", "edit"}
        ]
        self.assertEqual(mutations, ["create"] * 7 + ["edit"] * 3)
        mapping = json.loads(result.stdout)
        self.assertEqual(mapping["U4"]["blocked_by"], [102, 103])
        self.assertEqual(mapping["U1"]["number"], 101)
        self.assertEqual(
            mapping["U1"]["url"], "https://github.com/example/plans/issues/101"
        )
        for call in creates:
            self.assertEqual(
                call["args"][call["args"].index("--label") + 1], "plan-unit"
            )
            body_path = Path(call["args"][call["args"].index("--body-file") + 1])
            self.assertTrue(body_path.is_relative_to("/tmp"))
            self.assertFalse(
                body_path.exists(), "temporary body must be removed on exit"
            )
        plan = CI_PLAN.read_text(encoding="utf-8")
        section = plan[plan.index("### U1.") : plan.index("### U2.")]
        self.assertTrue(creates[0]["body"].startswith(section))
        self.assertTrue(
            creates[0]["body"].endswith(
                "Part of #1805\nPlan: docs/plans/2026-10-05-1421-feat-catalog-validation-plan.md\n"
            )
        )

    def test_round2_same_parent_units_from_another_plan_are_not_reused(self) -> None:
        # pro-gate round 2 P1: reuse matched parent + unit ID only, so a
        # second plan under the same parent silently reused the first
        # plan's U<n> issues and hung its edges on them. Identity is now
        # parent + exact Plan: path + unit; the other plan's issues are
        # neither reused nor edited, whichever listing returns them.
        plan = self.plan(
            "### U1. First\n**Dependencies:** none\n"
            "### U2. Second\n**Dependencies:** U1\n"
        )
        other = Path("docs/plans/2026-10-01-0900-feat-earlier-plan.md")
        self.configure(
            existing=self.existing(other)[:2],
            recent=self.existing(other)[:2],
        )
        result = self.run_cli(plan, "--repo", REPO, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("issue", "create")), 2)
        self.assertEqual(self.edges(), {102: [101]})
        mapping = json.loads(result.stdout)
        self.assertEqual(mapping["U1"]["number"], 101)
        self.assertEqual(
            mapping["U2"],
            {
                "number": 102,
                "url": "https://github.com/example/plans/issues/102",
                "blocked_by": [101],
            },
        )
        self.assertEqual(self.calls("issue", "view"), [])
        search = next(
            call["args"]
            for call in self.calls("issue", "list")
            if "--search" in call["args"]
        )
        self.assertIn("body", search[search.index("--json") + 1].split(","))

    def test_round2_reuse_needs_the_exact_plan_line_in_either_listing(self) -> None:
        # pro-gate round 2 P1: a marker-only, other-plan, or prefix-path body
        # is a different identity, so it is skipped rather than counted as a
        # second match; the one issue carrying both exact lines is reused.
        plan = self.plan("### U1. First\n**Dependencies:** none\n")
        distractors = [
            {"number": 902, "title": "fix: U1 Marker only", "body": "Part of #1805\n"},
            {
                "number": 903,
                "title": "fix: U1 Other plan",
                "body": self.trailer(
                    Path("docs/plans/2026-10-01-0900-fix-other-plan.md")
                ),
            },
            {
                "number": 904,
                "title": "fix: U1 Prefix path",
                "body": f"Part of #1805\nPlan: docs/plans/{plan.name}.bak\n",
            },
        ]
        for listing in ("existing", "recent"):
            with self.subTest(listing=listing):
                if self.log.exists():
                    self.log.unlink()
                self.configure(
                    **{
                        listing: [
                            {
                                "number": 201,
                                "title": "fix: U1 First",
                                "body": "### U1. First\n**Dependencies:** none\n\n"
                                + self.trailer(plan),
                            },
                            *distractors,
                        ]
                    }
                )
                result = self.run_cli(plan, "--repo", REPO, "--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls("issue", "create"), [])
                self.assertEqual(self.calls("issue", "edit"), [])
                self.assertEqual(json.loads(result.stdout)["U1"]["number"], 201)

    def test_round2_listing_without_bodies_fails_before_writes(self) -> None:
        # pro-gate round 2 P1: the body is now the reuse evidence, so a
        # listing that omits it cannot be read as "not filed here" (that
        # would duplicate every unit) nor as a match (the old defect).
        for listing in ("existing", "recent"):
            with self.subTest(listing=listing):
                if self.log.exists():
                    self.log.unlink()
                self.configure(
                    **{listing: [{"number": 201, "title": "feat: U1 Prior title"}]}
                )
                result = self.run_cli(CI_PLAN, "--repo", REPO)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("without title or body", result.stderr)
                self.assertEqual(self.calls("issue", "create"), [])
                self.assertEqual(self.calls("issue", "edit"), [])


if __name__ == "__main__":
    unittest.main()
