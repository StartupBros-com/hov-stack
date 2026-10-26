#!/usr/bin/env python3
"""Unit tests for scripts/review-rounds.py (dotfiles#1362, U1 of
docs/plans/2026-09-23-1741-feat-review-round-red-gate-and-breaker-plan.md).

Covers:
  - `read`: out-of-order creation times numbered by parsed time; a broken-
    JSON marker comment beside two good ones gives two rounds and one
    ledger_errors entry naming the comment id; a repeated head, and
    separately a repeated patch_id with different heads, each give one
    round plus one re-run (the earlier record is the round); unrelated
    comments give empty rounds and no errors; a runner failure propagates
    as a non-zero exit with stderr intact, never an empty history.
  - author trust: only the authenticated operator's numeric ID and explicit
    additional IDs can score history; forged or missing authors are ledger
    errors, identity failures exit non-zero, and reads retain API author IDs.
  - edge cases the marker/fence parsing must not silently misread: an
    empty body, the marker present but not on the first line, and a
    comment that is only the marker line with no JSON block at all.
  - `validate_record`: every pinned-shape violation named in the plan
    (schema, hex fields, enums, bounds, the FROZEN-only residual_classes
    rule, the red_first.tests and red_first.unchanged shapes, full-SHA RED
    baselines) reports the offending field.
  - `record`: a valid record posts a body starting with the marker,
    containing the table and the exact JSON, with the runner invoked with
    `pr comment` and `--body-file`; an invalid record, or one whose body
    exceeds the 65536-character comment limit, exits non-zero naming
    the cause with no runner call at all; prior rounds are counted with the
    same extra trusted author IDs `read` and `confirm` accept.

The `gh` boundary is replaced with a fake runner/gh callable throughout, as
tests/test_ci_queue_waits.py does for ci-queue-waits.py -- these are
identity, arithmetic and shape fixtures, not live `gh` proof.
"""
from __future__ import annotations

import contextlib
import io
import json
import runpy
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parents[0]
SCRIPT = REPO_ROOT / "scripts" / "review-rounds.py"
OPERATOR_ID = 101


def load_module():
    return runpy.run_path(str(SCRIPT))


def comment(comment_id, body, created_at, *, author_id=OPERATOR_ID):
    return {
        "id": comment_id, "body": body, "created_at": created_at,
        "user": {"id": author_id, "login": "operator"},
    }


class FakeGh:
    """Stands in for gh_lines(path, jq): serves comments and an explicit
    operator ID, and records every call to assert the request shape."""

    def __init__(self, comments=None, fail_stderr=None, *, operator_id=OPERATOR_ID,
                 user_fail_stderr=None):
        self.comments = comments or []
        self.fail_stderr = fail_stderr
        self.operator_id = operator_id
        self.user_fail_stderr = user_fail_stderr
        self.calls = []

    def __call__(self, path, jq):
        self.calls.append((path, jq))
        if path == "user":
            if self.user_fail_stderr is not None:
                raise RuntimeError(f"gh api user: {self.user_fail_stderr}")
            if jq != ".id":
                raise AssertionError(f"unexpected user query: {jq}")
            return [self.operator_id]
        if self.fail_stderr is not None:
            raise RuntimeError(f"gh api {path}: {self.fail_stderr}")
        return list(self.comments)

    def run(self, argv, **kwargs):
        """Exercise the CLI's real gh_lines decoding via its subprocess seam."""
        if argv[:3] != ["gh", "api", "--paginate"] or argv[4] != "--jq":
            raise AssertionError(f"unexpected gh argv: {argv}")
        try:
            rows = self(argv[3], argv[5])
        except RuntimeError as exc:
            return subprocess.CompletedProcess(argv, 1, "", str(exc))
        return subprocess.CompletedProcess(argv, 0, "\n".join(json.dumps(row) for row in rows), "")


class FakeRunner:
    """Stands in for subprocess.run: records argv, returns a canned result.
    When the argv carries --body-file, the file's content is captured at
    call time (into `bodies`, parallel to `calls`) because the real script
    deletes its scratch body file right after a successful post."""

    def __init__(self, stdout="", stderr="", returncode=0, *, history=None):
        self.calls = []
        self.bodies = []
        self.stdout, self.stderr, self.returncode = stdout, stderr, returncode
        # With `history`, `gh api` reads are served from a FakeGh (not recorded
        # in calls) and each successful post becomes a trusted marker comment.
        self.gh = None if history is None else FakeGh(list(history))

    def __call__(self, argv, **kwargs):
        if self.gh is not None and argv[:2] == ["gh", "api"]:
            return self.gh.run(argv, **kwargs)
        self.calls.append(list(argv))
        if "--body-file" in argv:
            body_path = Path(argv[argv.index("--body-file") + 1])
            self.bodies.append(body_path.read_text(encoding="utf-8") if body_path.exists() else None)
        else:
            self.bodies.append(None)
        if self.gh is not None and self.returncode == 0 and self.bodies[-1] is not None:
            self.gh.comments.append(comment(len(self.gh.comments) + 1, self.bodies[-1],
                                            f"2026-09-25T03:{len(self.gh.comments):02d}:00Z"))
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, self.stderr)


def valid_record(**overrides):
    """A minimal, fully-valid round record. Every mandatory field is
    present so a test can override exactly the field it wants to break."""
    record = {
        "schema": "review-adversarial-first/round/v1",
        "round": 1,
        "head": "a" * 40,
        "patch_id": "b" * 40,
        "diff_lines": 12,
        "verdict": "CLEAN",
        "underlying_verdict": "CLEAN",
        "live": {"P1": 0, "P2": 0, "P3": 0},
        "findings": [],
        "red_first": {"status": "not-applicable", "tests": []},
        "streak": 0,
        "override": False,
        "rerun": False,
        "ledger_errors": [],
    }
    record.update(overrides)
    return record


def valid_red_first_test(**overrides):
    """A valid entry in the exact shape emitted by red-first.sh."""
    test = {
        "path": "tests/suite.test.sh",
        "pre_fix": "c" * 40,
        "status": "ran",
        "command": "bash tests/suite.test.sh",
        "reason": None,
        "exempt": False,
        "exempt_reason": None,
        "cases": [
            {
                "name": "unresolved_case",
                "pre_fix": "unresolved",
                "head": "pass",
                "status": "inconclusive",
            },
        ],
    }
    test.update(overrides)
    return test


def valid_ordinary_prose():
    """Authored shape fixtures, not model proof of ordinary-prose semantics."""
    return {
        "base": "c" * 40,
        "head": "a" * 40,
        "patch_sha256": "d" * 64,
        "evidence": [
            {
                "lens": lens,
                "consumer_evidence": "Inspected build inputs; guide is not consumed.",
            }
            for lens in ("own-doctrine", "strongest-lever", "no-op-or-regression")
        ],
    }


def invalid_enum_records():
    """Every enum field rejects both array and object JSON values."""
    records = []
    for value in ([], {}):
        records.extend([
            ("verdict", valid_record(verdict=value)),
            ("underlying_verdict", valid_record(underlying_verdict=value)),
            ("findings", valid_record(findings=[{"file": "a", "severity": value, "title": "x"}])),
            ("residual_classes", valid_record(
                verdict="FROZEN", residual_classes=[{"file": "a", "severity": value, "titles": ["x"]}],
            )),
            ("red_first.status", valid_record(red_first={"status": value, "tests": []})),
            ("red_first.tests", valid_record(
                red_first={"status": "verified", "tests": [valid_red_first_test(status=value)]},
            )),
        ])
        for field in ("pre_fix", "head", "status"):
            case = valid_red_first_test()["cases"][0].copy()
            case[field] = value
            records.append(("red_first.tests", valid_record(
                red_first={"status": "verified", "tests": [valid_red_first_test(cases=[case])]},
            )))
    return records


def marker_body(record, marker="<!-- review-adversarial-first:round:v1 -->"):
    return f"{marker}\n\nsome table\n\n```json\n{json.dumps(record)}\n```\n"


class ValidateRecordTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()
        self.validate = self.m["validate_record"]

    def test_valid_record_has_no_errors(self):
        self.assertEqual(self.validate(valid_record()), [])

    def test_ordinary_prose_optional_positive_and_strict_shape(self):
        prose = valid_ordinary_prose()
        self.assertEqual(self.validate(valid_record(ordinary_prose=prose)), [])
        for bad in (None, {}, {**prose, "base": "main"}, {**prose, "head": "d" * 40},
                    {**prose, "evidence": prose["evidence"][:2]},
                    {**prose, "evidence": [prose["evidence"][0]] * 3},
                    {**prose, "evidence": [{"lens": "own-doctrine", "consumer_evidence": " "}]},
                    {**prose, "eligible": True}):
            with self.subTest(bad=bad):
                self.assertTrue(self.validate(valid_record(ordinary_prose=bad)))
        for change in ({"override": True}, {"verdict": "FROZEN"}, {"underlying_verdict": "DIRTY"},
                       {"live": {"P1": 1, "P2": 0, "P3": 0}}, {"ledger_errors": ["incomplete"]},
                       {"findings": [{"file": "README.md", "severity": "P1", "title": "live despite zero count"}]}):
            with self.subTest(change=change):
                self.assertTrue(self.validate(valid_record(ordinary_prose=prose, **change)))

    def test_ordinary_prose_requires_patch_digest_without_upgrading_old_attestation(
        self,
    ):
        prose = valid_ordinary_prose()
        del prose["patch_sha256"]
        record = valid_record(ordinary_prose=prose)
        self.assertTrue(
            any(e.startswith("ordinary_prose:") for e in self.validate(record))
        )
        self.assertNotIn("patch_sha256", record["ordinary_prose"])
        self.assertEqual(self.validate(valid_record()), [])

    def test_ordinary_prose_patch_digest_requires_64_lowercase_hex_characters(self):
        for value in (
            None,
            True,
            1,
            [],
            {},
            "",
            "a" * 63,
            "a" * 65,
            "A" * 64,
            "g" * 64,
            "a" * 64 + "\n",
        ):
            with self.subTest(value=value):
                prose = {**valid_ordinary_prose(), "patch_sha256": value}
                errors = self.validate(valid_record(ordinary_prose=prose))
                self.assertTrue(
                    any(e.startswith("ordinary_prose.patch_sha256:") for e in errors),
                    errors,
                )

    def test_not_a_dict(self):
        errors = self.validate(["nope"])
        self.assertTrue(any("must be a JSON object" in e for e in errors))

    def test_wrong_schema(self):
        errors = self.validate(valid_record(schema="something-else"))
        self.assertTrue(any(e.startswith("schema:") for e in errors))

    def test_head_not_hex(self):
        errors = self.validate(valid_record(head="not-hex"))
        self.assertTrue(any(e.startswith("head:") for e in errors))

    def test_head_wrong_length(self):
        errors = self.validate(valid_record(head="a" * 39))
        self.assertTrue(any(e.startswith("head:") for e in errors))

    def test_head_uppercase_rejected(self):
        errors = self.validate(valid_record(head="A" * 40))
        self.assertTrue(any(e.startswith("head:") for e in errors))

    def test_hex_fields_trailing_newline_rejected(self):
        for field in ("head", "patch_id"):
            with self.subTest(field=field):
                errors = self.validate(valid_record(**{field: "a" * 40 + "\n"}))
                self.assertTrue(any(e.startswith(f"{field}:") for e in errors))

    def test_patch_id_not_hex(self):
        errors = self.validate(valid_record(patch_id="z" * 40))
        self.assertTrue(any(e.startswith("patch_id:") for e in errors))

    def test_round_must_be_positive_int(self):
        for bad in (0, -1, "1", 1.5, True):
            errors = self.validate(valid_record(round=bad))
            self.assertTrue(any(e.startswith("round:") for e in errors), bad)

    def test_diff_lines_must_be_non_negative_int(self):
        for bad in (-1, "12", 1.5, True):
            errors = self.validate(valid_record(diff_lines=bad))
            self.assertTrue(any(e.startswith("diff_lines:") for e in errors), bad)

    def test_verdict_enum(self):
        errors = self.validate(valid_record(verdict="WEIRD"))
        self.assertTrue(any(e.startswith("verdict:") for e in errors))

    def test_underlying_verdict_excludes_frozen(self):
        errors = self.validate(valid_record(underlying_verdict="FROZEN"))
        self.assertTrue(any(e.startswith("underlying_verdict:") for e in errors))

    def test_live_requires_exactly_p1_p2_p3(self):
        errors = self.validate(valid_record(live={"P1": 0, "P2": 0}))
        self.assertTrue(any(e.startswith("live:") for e in errors))

    def test_live_rejects_negative(self):
        errors = self.validate(valid_record(live={"P1": -1, "P2": 0, "P3": 0}))
        self.assertTrue(any(e.startswith("live:") for e in errors))

    def test_findings_over_bound(self):
        findings = [{"file": "a", "severity": "P1", "title": "x"} for _ in range(201)]
        errors = self.validate(valid_record(findings=findings))
        self.assertTrue(any(e.startswith("findings:") for e in errors))

    def test_findings_at_bound_is_valid(self):
        findings = [{"file": "a", "severity": "P1", "title": "x"} for _ in range(200)]
        self.assertEqual(self.validate(valid_record(findings=findings)), [])

    def test_findings_bad_severity(self):
        errors = self.validate(valid_record(findings=[{"file": "a", "severity": "P9", "title": "x"}]))
        self.assertTrue(any(e.startswith("findings:") for e in errors))

    def test_findings_missing_field(self):
        errors = self.validate(valid_record(findings=[{"file": "a", "severity": "P1"}]))
        self.assertTrue(any(e.startswith("findings:") for e in errors))

    def test_residual_classes_forbidden_unless_frozen(self):
        record = valid_record(residual_classes=[{"file": "a", "severity": "P1", "titles": ["x"]}])
        errors = self.validate(record)
        self.assertTrue(any("present only when verdict is FROZEN" in e for e in errors))

    def test_residual_classes_allowed_when_frozen(self):
        record = valid_record(
            verdict="FROZEN",
            residual_classes=[{"file": "a", "severity": "P1", "titles": ["x", "y"]}],
        )
        self.assertEqual(self.validate(record), [])

    def test_residual_classes_over_bound(self):
        residual = [{"file": "a", "severity": "P1", "titles": ["x"]} for _ in range(201)]
        errors = self.validate(valid_record(verdict="FROZEN", residual_classes=residual))
        self.assertTrue(any(e.startswith("residual_classes:") for e in errors))

    def test_residual_classes_titles_must_be_strings(self):
        record = valid_record(verdict="FROZEN", residual_classes=[{"file": "a", "severity": "P1", "titles": [1]}])
        errors = self.validate(record)
        self.assertTrue(any(e.startswith("residual_classes:") for e in errors))

    def test_red_first_status_enum(self):
        errors = self.validate(valid_record(red_first={"status": "nope", "tests": []}))
        self.assertTrue(any(e.startswith("red_first.status:") for e in errors))

    def test_unhashable_json_values_in_every_enum_are_validation_errors(self):
        for field, record in invalid_enum_records():
            with self.subTest(field=field):
                errors = self.validate(record)
                self.assertTrue(any(e.startswith(f"{field}:") for e in errors), errors)

    def test_red_first_runner_output_shape_is_valid(self):
        record = valid_record(red_first={"status": "inconclusive", "tests": [valid_red_first_test()]})
        self.assertEqual(self.validate(record), [])

    def test_red_first_optional_exempt_reason_preserves_pinned_shape(self):
        test = valid_red_first_test()
        del test["exempt_reason"]
        record = valid_record(red_first={"status": "inconclusive", "tests": [test]})
        self.assertEqual(self.validate(record), [])

    def test_red_first_all_runner_vocabularies_and_nullable_fields_are_valid(self):
        cases = [
            {"name": "red", "pre_fix": "fail", "head": "pass", "status": "verified"},
            {"name": "green", "pre_fix": "pass", "head": "pass", "status": "never-red"},
            {"name": "unknown", "pre_fix": "unresolved", "head": "unresolved", "status": "inconclusive"},
            {"name": "regression", "pre_fix": "pass", "head": "fail", "status": "fails-at-head"},
            {"name": "unsupported", "pre_fix": "unsupported", "head": "unsupported", "status": "unsupported"},
        ]
        tests = [
            valid_red_first_test(cases=cases),
            valid_red_first_test(status="file-level", cases=cases[:1], exempt=True, exempt_reason="rename"),
            valid_red_first_test(status="unsupported", command=None, reason="unsupported", cases=cases[-1:]),
            # red-first.sh refuses a non-SHA manifest revision before any
            # fetch, so an unfetchable baseline is still a full SHA.
            valid_red_first_test(
                status="unverifiable", pre_fix="e" * 40, command=None,
                reason="revision not fetchable", cases=[],
            ),
        ]
        record = valid_record(red_first={"status": "inconclusive", "tests": tests})
        self.assertEqual(self.validate(record), [])
        parsed, reason = self.m["parse_record_from_body"](marker_body(record))
        self.assertIsNone(reason)
        self.assertEqual(parsed, record)
        runner = FakeRunner(history=[])
        self.assertEqual(self.m["record_command"]("o/r", 42, record, runner=runner), (0, None))
        self.assertEqual(len(runner.calls), 1)

    def test_red_first_tests_and_cases_at_bounds_are_valid(self):
        test = valid_red_first_test(cases=valid_red_first_test()["cases"] * 200)
        record = valid_record(red_first={"status": "inconclusive", "tests": [test] * 100})
        self.assertEqual(self.validate(record), [])

    def test_red_first_tests_over_bound(self):
        errors = self.validate(valid_record(
            red_first={"status": "verified", "tests": [valid_red_first_test(cases=[])] * 101},
        ))
        self.assertTrue(any(e.startswith("red_first.tests:") for e in errors))

    def test_red_first_tests_missing_key(self):
        errors = self.validate(valid_record(red_first={"status": "verified", "tests": [{"path": "p"}]}))
        self.assertTrue(any(e.startswith("red_first.tests:") for e in errors))

    def test_red_first_each_required_nested_field_is_checked(self):
        for field in ("path", "pre_fix", "status", "command", "reason", "exempt", "cases"):
            with self.subTest(test_field=field):
                test = valid_red_first_test()
                del test[field]
                errors = self.validate(valid_record(red_first={"status": "verified", "tests": [test]}))
                self.assertTrue(any(e.startswith("red_first.tests:") and field in e for e in errors), errors)
        for field in ("name", "pre_fix", "head", "status"):
            with self.subTest(case_field=field):
                test = valid_red_first_test()
                del test["cases"][0][field]
                errors = self.validate(valid_record(red_first={"status": "verified", "tests": [test]}))
                self.assertTrue(any(e.startswith("red_first.tests:") and field in e for e in errors), errors)

    def test_red_first_test_path_and_pre_fix_must_be_strings(self):
        for field, value in (("path", []), ("path", None), ("pre_fix", {}), ("pre_fix", None)):
            with self.subTest(field=field):
                errors = self.validate(valid_record(
                    red_first={"status": "verified", "tests": [valid_red_first_test(**{field: value})]},
                ))
                self.assertTrue(any(e.startswith("red_first.tests:") for e in errors), errors)

    def test_red_first_test_pre_fix_must_be_a_full_lowercase_sha(self):
        # A trusted record's pre_fix seeds a later round's RED baseline, so a
        # ref name or abbreviated SHA would let an edited comment pick the tree.
        for value in ("refs/remotes/origin/attacker-branch", "c" * 7, "C" * 40, "c" * 40 + "\n"):
            with self.subTest(value=value):
                errors = self.validate(valid_record(
                    red_first={"status": "verified", "tests": [valid_red_first_test(pre_fix=value)]},
                ))
                self.assertIn("red_first.tests: item 0: pre_fix must be 40 lowercase hex characters", errors)

    def test_red_first_unexecuted_entry_keeps_the_runners_raw_revision(self):
        # red-first.sh reports an out-of-range Red-first-base trailer verbatim
        # on an entry that ran nothing. It seeds no baseline (the workflow
        # carries only earlier recorded heads), so refusing it would only make
        # the whole round unrecordable.
        unexecuted = dict(status="unverifiable", pre_fix="refs/heads/side", command=None,
                          reason="Red-first-base refs/heads/side is outside merge-base..head", cases=[])
        record = valid_record(red_first={"status": "unverifiable", "tests": [valid_red_first_test(**unexecuted)]})
        self.assertEqual(self.validate(record), [])
        for name, overrides in {
            "a command": {"command": "bash tests/suite.test.sh"},
            "cases": {"cases": valid_red_first_test()["cases"]},
            "another status": {"status": "unsupported"},
            "an empty revision": {"pre_fix": ""},
        }.items():
            with self.subTest(executed=name):
                errors = self.validate(valid_record(red_first={"status": "unverifiable", "tests": [
                    valid_red_first_test(**dict(unexecuted, **overrides))]}))
                self.assertIn("red_first.tests: item 0: pre_fix must be 40 lowercase hex characters", errors)

    def unchanged_record(self, unchanged):
        return valid_record(red_first={
            "status": "verified", "tests": [valid_red_first_test()], "unchanged": unchanged,
        })

    def test_red_first_unchanged_in_runner_shape_is_valid(self):
        unchanged = [{"path": "tests/other.test.sh", "pre_fix": "f" * 40}]
        self.assertEqual(self.validate(self.unchanged_record(unchanged)), [])
        at_bound = [{"path": f"tests/t{i}.test.sh", "pre_fix": "f" * 40} for i in range(100)]
        self.assertEqual(self.validate(self.unchanged_record(at_bound)), [])

    def test_red_first_unchanged_tampered_items_are_rejected(self):
        good = {"path": "tests/other.test.sh", "pre_fix": "f" * 40}
        cases = {
            "ref-name baseline": ([dict(good, pre_fix="refs/remotes/origin/attacker-branch")],
                                  "red_first.unchanged: item 0: pre_fix must be 40 lowercase hex characters"),
            "short baseline": ([dict(good, pre_fix="f" * 7)],
                               "red_first.unchanged: item 0: pre_fix must be 40 lowercase hex characters"),
            "path not a string": ([dict(good, path=["tests/other.test.sh"])],
                                  "red_first.unchanged: item 0: path must be a string"),
            "extra key": ([dict(good, status="ran")],
                          "red_first.unchanged: item 0 must be an object with exactly path and pre_fix"),
            "missing key": ([{"path": "tests/other.test.sh"}],
                            "red_first.unchanged: item 0 must be an object with exactly path and pre_fix"),
            "not an object": (["tests/other.test.sh"],
                              "red_first.unchanged: item 0 must be an object with exactly path and pre_fix"),
            "not an array": ({"path": "tests/other.test.sh"},
                             "red_first.unchanged: must be an array of at most 100 items"),
            "over bound": ([good] * 101, "red_first.unchanged: must be an array of at most 100 items"),
        }
        for name, (unchanged, message) in cases.items():
            with self.subTest(name=name):
                self.assertIn(message, self.validate(self.unchanged_record(unchanged)))

    def test_red_first_test_status_uses_closed_vocabulary(self):
        errors = self.validate(valid_record(
            red_first={"status": "verified", "tests": [valid_red_first_test(status="verified")]},
        ))
        self.assertTrue(any(e.startswith("red_first.tests:") for e in errors))

    def test_red_first_test_nullable_strings_reject_other_values(self):
        for field, value in (("command", []), ("reason", {}), ("exempt_reason", 1)):
            with self.subTest(field=field):
                errors = self.validate(valid_record(
                    red_first={"status": "verified", "tests": [valid_red_first_test(**{field: value})]},
                ))
                self.assertTrue(any(e.startswith("red_first.tests:") for e in errors), errors)

    def test_red_first_tests_exempt_must_be_bool(self):
        errors = self.validate(valid_record(
            red_first={"status": "verified", "tests": [valid_red_first_test(exempt="no")]},
        ))
        self.assertTrue(any(e.startswith("red_first.tests:") for e in errors))

    def test_red_first_tests_cases_must_be_bounded_array(self):
        invalid_values = ("none", valid_red_first_test()["cases"] * 201)
        for value in invalid_values:
            with self.subTest(value_type=type(value).__name__, length=len(value)):
                errors = self.validate(valid_record(
                    red_first={"status": "verified", "tests": [valid_red_first_test(cases=value)]},
                ))
                self.assertTrue(any(e.startswith("red_first.tests:") for e in errors), errors)

    def test_red_first_case_must_be_object_with_all_fields(self):
        bad_cases = ["case", None, [], {"name": "partial"}]
        for case in bad_cases:
            with self.subTest(case=case):
                errors = self.validate(valid_record(
                    red_first={"status": "verified", "tests": [valid_red_first_test(cases=[case])]},
                ))
                self.assertTrue(any(e.startswith("red_first.tests:") for e in errors), errors)

    def test_red_first_case_name_must_be_string(self):
        case = valid_red_first_test()["cases"][0].copy()
        case["name"] = []
        errors = self.validate(valid_record(
            red_first={"status": "verified", "tests": [valid_red_first_test(cases=[case])]},
        ))
        self.assertTrue(any(e.startswith("red_first.tests:") for e in errors))

    def test_red_first_case_enums_use_closed_vocabularies(self):
        for field, value in (("pre_fix", "error"), ("head", "error"), ("status", "ran")):
            with self.subTest(field=field):
                case = valid_red_first_test()["cases"][0].copy()
                case[field] = value
                errors = self.validate(valid_record(
                    red_first={"status": "verified", "tests": [valid_red_first_test(cases=[case])]},
                ))
                self.assertTrue(any(e.startswith("red_first.tests:") for e in errors), errors)

    def test_streak_must_be_non_negative_int(self):
        errors = self.validate(valid_record(streak=-1))
        self.assertTrue(any(e.startswith("streak:") for e in errors))

    def test_override_and_rerun_must_be_bool(self):
        errors = self.validate(valid_record(override="yes", rerun=1))
        self.assertTrue(any(e.startswith("override:") for e in errors))
        self.assertTrue(any(e.startswith("rerun:") for e in errors))

    def test_ledger_errors_must_be_list(self):
        errors = self.validate(valid_record(ledger_errors={}))
        self.assertTrue(any(e.startswith("ledger_errors:") for e in errors))


class ReadRoundsAuthorTests(unittest.TestCase):
    """Only API author IDs trusted by the caller may affect scored history."""

    def setUp(self):
        self.m = load_module()
        self.read_rounds = self.m["read_rounds"]

    def test_marker_errors_are_typed_by_authenticated_numeric_author_trust(self):
        untrusted = comment(10, self.m["MARKER"], "2026-09-21T21:00:00Z", author_id=999)
        untrusted["user"]["login"] = "operator"
        untrusted["author_association"] = "OWNER"
        invalid = comment(11, self.m["MARKER"], "2026-09-21T21:01:00Z", author_id="101")
        malformed = comment(12, self.m["MARKER"], "2026-09-21T21:02:00Z", author_id=202)
        bad_timestamp = comment(13, marker_body(valid_record()), "invalid timestamp")
        gh = FakeGh([untrusted, invalid, malformed, bad_timestamp])

        result = self.read_rounds("o/r", 5, gh=gh, trusted_author_ids=[202])

        self.assertEqual(result["rounds"], [])
        self.assertEqual(
            [(error["comment_id"], error.get("kind")) for error in result["ledger_errors"]],
            [(10, "untrusted-author"), (11, "invalid-author"),
             (12, "invalid-record"), (13, "invalid-record")],
        )
        self.assertIn("untrusted author ID 999", result["ledger_errors"][0]["reason"])
        self.assertIn("author user.id", result["ledger_errors"][1]["reason"])
        self.assertIn("no fenced", result["ledger_errors"][2]["reason"])
        self.assertIn("unparseable created_at", result["ledger_errors"][3]["reason"])

    def test_forged_clean_cannot_make_trusted_dirty_a_rerun(self):
        forged = valid_record(author_id=OPERATOR_ID, trusted_author_ids=[999])
        trusted = valid_record(
            verdict="DIRTY", underlying_verdict="DIRTY", live={"P1": 1, "P2": 0, "P3": 0},
        )
        comments = [
            comment(10, marker_body(forged), "2026-09-21T21:00:00Z", author_id=999),
            comment(20, marker_body(trusted), "2026-09-21T22:00:00Z"),
        ]
        # Neither the matching display name nor association confers trust.
        comments[0]["author_association"] = "OWNER"
        comments[1]["author_association"] = "NONE"
        gh = FakeGh(comments, operator_id=OPERATOR_ID)

        result = self.read_rounds("o/r", 5, gh=gh)

        self.assertEqual([r["comment_id"] for r in result["rounds"]], [20])
        only_round = result["rounds"][0]
        self.assertEqual((only_round["round"], only_round["rerun"]), (1, False))
        self.assertEqual(only_round["record"], trusted)
        self.assertEqual(only_round["author_id"], OPERATOR_ID)
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0]["comment_id"], 10)
        self.assertEqual(result["ledger_errors"][0].get("kind"), "untrusted-author")
        self.assertIn("untrusted author", result["ledger_errors"][0]["reason"])
        self.assertIn("999", result["ledger_errors"][0]["reason"])
        self.assertIn(("user", ".id"), gh.calls)

    def test_missing_author_markers_are_errors_and_do_not_consume_rounds(self):
        for user in (None, {}, [], {"login": "operator"}):
            with self.subTest(user=user):
                missing = comment(10, marker_body(valid_record()), "2026-09-21T21:00:00Z")
                missing["user"] = user
                trusted = comment(20, marker_body(valid_record()), "2026-09-21T22:00:00Z")
                result = self.read_rounds("o/r", 5, gh=FakeGh([missing, trusted]))
                self.assertEqual([r["comment_id"] for r in result["rounds"]], [20])
                self.assertEqual((result["rounds"][0]["round"], result["rounds"][0]["rerun"]), (1, False))
                self.assertEqual(len(result["ledger_errors"]), 1)
                self.assertEqual(result["ledger_errors"][0]["comment_id"], 10)
                self.assertEqual(result["ledger_errors"][0].get("kind"), "invalid-author")
                self.assertIn("author", result["ledger_errors"][0]["reason"])

    def test_absent_author_field_is_a_ledger_error(self):
        missing = comment(10, marker_body(valid_record()), "2026-09-21T21:00:00Z")
        del missing["user"]
        result = self.read_rounds("o/r", 5, gh=FakeGh([missing]))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0]["comment_id"], 10)
        self.assertIn("author", result["ledger_errors"][0]["reason"])

    def test_malformed_api_author_ids_are_never_scored(self):
        for author_id in (True, False, 0, -1, "101", 101.0, [], {}, None):
            with self.subTest(author_id=author_id):
                candidate = comment(10, marker_body(valid_record()), "2026-09-21T21:00:00Z",
                                    author_id=author_id)
                operator_id = 1 if isinstance(author_id, bool) else OPERATOR_ID
                result = self.read_rounds("o/r", 5, gh=FakeGh([candidate], operator_id=operator_id))
                self.assertEqual(result["rounds"], [])
                self.assertEqual(len(result["ledger_errors"]), 1)
                self.assertEqual(result["ledger_errors"][0]["comment_id"], 10)
                self.assertEqual(result["ledger_errors"][0].get("kind"), "invalid-author")
                self.assertIn("author", result["ledger_errors"][0]["reason"])

    def test_author_identity_comes_from_api_not_record_body(self):
        record = valid_record(author_id=999, user={"id": 999})
        candidate = comment(10, marker_body(record), "2026-09-21T21:00:00Z", author_id=707)
        candidate["user"]["login"] = "renamed-operator"
        result = self.read_rounds("o/r", 5, gh=FakeGh([candidate], operator_id=707))
        self.assertEqual(result["ledger_errors"], [])
        self.assertEqual(result["rounds"][0]["author_id"], 707)
        self.assertEqual(result["rounds"][0]["record"], record)

    def read_cli(self, gh, *extra_args):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(subprocess, "run", gh.run), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.m["main"](["read", "--repo", "o/r", "--pr", "5", *extra_args])
        return rc, out.getvalue(), err.getvalue()

    def test_repeatable_trusted_ids_add_to_operator_trust(self):
        comments = [
            comment(i, marker_body(valid_record(head=str(i) * 40, patch_id=str(i) * 40)),
                    f"2026-09-21T21:0{i}:00Z", author_id=author_id)
            for i, author_id in enumerate((OPERATOR_ID, 202, 303, 404), start=1)
        ]
        gh = FakeGh(comments, operator_id=OPERATOR_ID)
        rc, out, err = self.read_cli(gh, "--trusted-author-id", "202", "--trusted-author-id", "303")
        self.assertEqual((rc, err), (0, ""))
        result = json.loads(out)
        self.assertEqual([r["author_id"] for r in result["rounds"]], [OPERATOR_ID, 202, 303])
        self.assertEqual([r["round"] for r in result["rounds"]], [1, 2, 3])
        self.assertEqual([r["rerun"] for r in result["rounds"]], [False, False, False])
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0]["comment_id"], 4)
        self.assertIn("untrusted author", result["ledger_errors"][0]["reason"])
        self.assertIn(("user", ".id"), gh.calls)

    def test_malformed_configured_ids_are_rejected_before_gh(self):
        for author_id in ("0", "-1", "1.0", "operator", "true", "", " 101", "+101", "١٠١"):
            with self.subTest(author_id=author_id):
                gh = FakeGh()
                out, err = io.StringIO(), io.StringIO()
                with mock.patch.object(subprocess, "run", gh.run), \
                        contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                        self.assertRaises(SystemExit) as ctx:
                    self.m["main"](["read", "--repo", "o/r", "--pr", "5", f"--trusted-author-id={author_id}"])
                self.assertEqual(ctx.exception.code, 2)
                self.assertIn("--trusted-author-id", err.getvalue())
                self.assertIn("positive integer", err.getvalue())
                self.assertEqual(out.getvalue(), "")
                self.assertEqual(gh.calls, [])

    def test_malformed_caller_ids_are_not_coerced_into_trust(self):
        for author_id in (True, False, 0, -1, "101", 101.0, [], {}, None):
            with self.subTest(author_id=author_id):
                gh = FakeGh()
                with self.assertRaisesRegex(RuntimeError, "trusted author ID.*positive integer"):
                    self.read_rounds("o/r", 5, gh=gh, trusted_author_ids=[author_id])
                self.assertEqual(gh.calls, [])

    def test_user_resolution_failure_is_visible_even_with_explicit_trust(self):
        comments = [comment(10, marker_body(valid_record()), "2026-09-21T21:00:00Z")]
        for extra_args in ((), ("--trusted-author-id", "202")):
            with self.subTest(extra_args=extra_args):
                gh = FakeGh(comments, user_fail_stderr="HTTP 403: user lookup denied")
                rc, out, err = self.read_cli(gh, *extra_args)
                self.assertEqual(rc, 1)
                self.assertEqual(out, "")
                self.assertIn("gh api user", err)
                self.assertIn("HTTP 403: user lookup denied", err)

    def test_comment_failure_after_user_resolution_is_not_empty_history(self):
        gh = FakeGh(fail_stderr="HTTP 404: comments unavailable", operator_id=OPERATOR_ID)
        rc, out, err = self.read_cli(gh)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("gh api repos/o/r/issues/5/comments", err)
        self.assertIn("HTTP 404: comments unavailable", err)
        self.assertIn(("user", ".id"), gh.calls)

    def test_unrelated_comments_need_no_author(self):
        unrelated = comment(10, "Ordinary discussion", "2026-09-21T21:00:00Z")
        del unrelated["user"]
        rc, out, err = self.read_cli(FakeGh([unrelated]))
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(json.loads(out), {
            "target": {"repo": "o/r", "pr": 5}, "rounds": [], "ledger_errors": [],
        })

    def test_invalid_operator_ids_fail_instead_of_returning_empty_history(self):
        for operator_id in (True, False, 0, -1, "101", 101.0, [], {}, None):
            with self.subTest(operator_id=operator_id):
                rc, out, err = self.read_cli(FakeGh(operator_id=operator_id))
                self.assertEqual(rc, 1)
                self.assertEqual(out, "")
                self.assertIn("gh api user", err)
                self.assertIn("positive integer", err)

    def test_missing_or_invalid_user_json_is_a_visible_cli_error(self):
        for stdout in ("", "not-json", "101\n202\n"):
            with self.subTest(stdout=stdout):
                runner = FakeRunner(stdout=stdout)
                out, err = io.StringIO(), io.StringIO()
                with mock.patch.object(subprocess, "run", runner), \
                        contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    rc = self.m["main"](["read", "--repo", "o/r", "--pr", "5"])
                self.assertEqual(rc, 1)
                self.assertEqual(out.getvalue(), "")
                self.assertIn("gh api user", err.getvalue())


class ReadRoundsOrderingTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()
        self.read_rounds = self.m["read_rounds"]

    def test_out_of_order_creation_times_numbered_by_parsed_time(self):
        r1 = valid_record(round=1, head="a" * 40, patch_id="1" * 40)
        r2 = valid_record(round=2, head="b" * 40, patch_id="2" * 40)
        r3 = valid_record(round=3, head="c" * 40, patch_id="3" * 40)
        # Posted out of order: r3's comment is oldest, r1's is newest.
        comments = [
            comment(30, marker_body(r3), "2026-09-21T21:00:00Z"),
            comment(10, marker_body(r1), "2026-09-23T21:00:00Z"),
            comment(20, marker_body(r2), "2026-09-22T21:00:00Z"),
        ]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["ledger_errors"], [])
        numbers = [(item["round"], item["comment_id"]) for item in result["rounds"]]
        self.assertEqual(numbers, [(1, 30), (2, 20), (3, 10)])
        self.assertEqual(result["target"], {"repo": "o/r", "pr": 5})

    def test_broken_json_beside_two_good_comments(self):
        r1 = valid_record(round=1, head="a" * 40, patch_id="1" * 40)
        r2 = valid_record(round=2, head="b" * 40, patch_id="2" * 40)
        broken = "<!-- review-adversarial-first:round:v1 -->\n\n```json\n{not valid json\n```\n"
        comments = [
            comment(1, marker_body(r1), "2026-09-21T21:00:00Z"),
            comment(2, broken, "2026-09-21T22:00:00Z"),
            comment(3, marker_body(r2), "2026-09-21T23:00:00Z"),
        ]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(len(result["rounds"]), 2)
        self.assertEqual([r["round"] for r in result["rounds"]], [1, 2])
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0]["comment_id"], 2)
        self.assertEqual(result["ledger_errors"][0].get("kind"), "invalid-record")
        self.assertIn("invalid JSON", result["ledger_errors"][0]["reason"])

    def test_unhashable_enum_values_become_ledger_errors_beside_good_comments(self):
        first = valid_record(round=1, head="a" * 40, patch_id="1" * 40)
        last = valid_record(round=2, head="b" * 40, patch_id="2" * 40)
        comments = [comment(1, marker_body(first), "2026-09-21T21:00:00Z")]
        for i, (field, record) in enumerate(invalid_enum_records(), start=2):
            comments.append(comment(i, marker_body(record), f"2026-09-21T21:{i:02}:00Z"))
        comments.append(comment(99, marker_body(last), "2026-09-21T21:59:00Z"))

        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))

        self.assertEqual([r["comment_id"] for r in result["rounds"]], [1, 99])
        self.assertEqual(len(result["ledger_errors"]), len(invalid_enum_records()))
        for error, (field, _record) in zip(result["ledger_errors"], invalid_enum_records()):
            self.assertIn(field, error["reason"])

    def test_same_head_twice_is_one_round_and_one_rerun(self):
        head = "a" * 40
        r1 = valid_record(round=1, head=head, patch_id="1" * 40)
        r2 = valid_record(round=2, head=head, patch_id="2" * 40)
        comments = [
            comment(1, marker_body(r1), "2026-09-21T21:00:00Z"),
            comment(2, marker_body(r2), "2026-09-21T22:00:00Z"),
        ]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(len(result["rounds"]), 2)
        first, second = result["rounds"]
        self.assertEqual((first["round"], first["rerun"]), (1, False))
        self.assertEqual((second["round"], second["rerun"]), (2, True))
        self.assertEqual(result["ledger_errors"], [])

    def test_non_adjacent_repeated_head_is_a_rerun(self):
        comments = [
            comment(1, marker_body(valid_record(head="a" * 40, patch_id="1" * 40)), "2026-09-21T21:00:00Z"),
            comment(2, marker_body(valid_record(head="b" * 40, patch_id="2" * 40)), "2026-09-21T22:00:00Z"),
            comment(3, marker_body(valid_record(head="a" * 40, patch_id="3" * 40)), "2026-09-21T23:00:00Z"),
        ]

        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))

        self.assertEqual([r["rerun"] for r in result["rounds"]], [False, False, True])

    def test_same_patch_id_different_heads_is_one_round_and_one_rerun(self):
        patch_id = "9" * 40
        r1 = valid_record(round=1, head="a" * 40, patch_id=patch_id)
        r2 = valid_record(round=2, head="b" * 40, patch_id=patch_id)
        comments = [
            comment(1, marker_body(r1), "2026-09-21T21:00:00Z"),
            comment(2, marker_body(r2), "2026-09-21T22:00:00Z"),
        ]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        first, second = result["rounds"]
        self.assertEqual((first["round"], first["rerun"]), (1, False))
        self.assertEqual((second["round"], second["rerun"]), (2, True))

    def test_patch_id_only_compares_with_previous_scored_round(self):
        comments = [
            comment(1, marker_body(valid_record(head="a" * 40, patch_id="1" * 40)), "2026-09-21T21:00:00Z"),
            comment(2, marker_body(valid_record(head="b" * 40, patch_id="2" * 40)), "2026-09-21T22:00:00Z"),
            comment(3, marker_body(valid_record(head="c" * 40, patch_id="1" * 40)), "2026-09-21T23:00:00Z"),
        ]

        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))

        self.assertEqual([r["rerun"] for r in result["rounds"]], [False, False, False])

    def test_reruns_preserve_patch_comparison_and_still_add_seen_heads(self):
        # B first appears as a patch-id rerun, but must still be remembered
        # when revisited after C. Neither rerun moves the scored patch-id.
        identities = [("a", "1"), ("b", "1"), ("c", "2"), ("b", "3"), ("d", "2"), ("e", "3")]
        comments = [
            comment(i, marker_body(valid_record(head=head * 40, patch_id=patch * 40)),
                    f"2026-09-21T21:{i:02}:00Z")
            for i, (head, patch) in enumerate(identities, start=1)
        ]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual([r["rerun"] for r in result["rounds"]], [False, True, False, True, True, False])
        self.assertEqual([r["round"] for r in result["rounds"]], [1, 2, 3, 4, 5, 6])
        self.assertEqual(result["ledger_errors"], [])

    def test_unrelated_comments_only_give_empty_rounds_and_no_errors(self):
        comments = [
            comment(1, "just chatting, no marker here", "2026-09-21T21:00:00Z"),
            comment(2, "LGTM", "2026-09-21T22:00:00Z"),
        ]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(result["ledger_errors"], [])

    def test_gh_failure_propagates_and_is_never_an_empty_history(self):
        gh = FakeGh(fail_stderr="gh: not logged in")
        with self.assertRaises(RuntimeError) as ctx:
            self.read_rounds("o/r", 5, gh=gh)
        self.assertIn("not logged in", str(ctx.exception))


class ReadRoundsEdgeCaseTests(unittest.TestCase):
    """Edge cases the task calls out explicitly: empty body, marker not on
    the first line, and a comment that is only the marker."""

    def setUp(self):
        self.m = load_module()
        self.read_rounds = self.m["read_rounds"]

    def test_empty_body_is_ignored_not_an_error(self):
        comments = [comment(1, "", "2026-09-21T21:00:00Z")]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(result["ledger_errors"], [])

    def test_marker_not_on_first_line_is_ignored_not_an_error(self):
        body = "Some preamble.\n<!-- review-adversarial-first:round:v1 -->\n\n```json\n{}\n```\n"
        comments = [comment(1, body, "2026-09-21T21:00:00Z")]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(result["ledger_errors"], [])

    def test_marker_only_comment_is_a_ledger_error(self):
        body = "<!-- review-adversarial-first:round:v1 -->"
        comments = [comment(1, body, "2026-09-21T21:00:00Z")]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0]["comment_id"], 1)
        self.assertIn("no fenced", result["ledger_errors"][0]["reason"])

    def test_marker_comment_with_shape_invalid_json_is_a_ledger_error(self):
        record = valid_record()
        del record["schema"]
        comments = [comment(1, marker_body(record), "2026-09-21T21:00:00Z")]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0].get("kind"), "invalid-record")
        self.assertIn("shape-invalid", result["ledger_errors"][0]["reason"])

    def test_trusted_marker_with_a_ref_name_baseline_is_a_ledger_error(self):
        # An edited operator comment keeps its author ID; its baseline must
        # still never reach a later RED manifest as a trusted round.
        red = {"status": "verified", "tests": [valid_red_first_test()],
               "unchanged": [{"path": "tests/x.test.sh", "pre_fix": "refs/remotes/origin/attacker-branch"}]}
        comments = [comment(1, marker_body(valid_record(red_first=red)), "2026-09-21T21:00:00Z")]
        result = self.read_rounds("o/r", 5, gh=FakeGh(comments))
        self.assertEqual(result["rounds"], [])
        self.assertEqual(len(result["ledger_errors"]), 1)
        self.assertEqual(result["ledger_errors"][0].get("kind"), "invalid-record")
        self.assertIn("red_first.unchanged: item 0: pre_fix must be 40 lowercase hex characters",
                      result["ledger_errors"][0]["reason"])


class RecordCommandTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()
        self.record_command = self.m["record_command"]
        self.MARKER = self.m["MARKER"]

    def test_valid_record_posts_marker_table_and_exact_json(self):
        record = valid_record()
        runner = FakeRunner(history=[])
        code, errors = self.record_command("o/r", 42, record, runner=runner)
        self.assertEqual((code, errors), (0, None))
        self.assertEqual(len(runner.calls), 1)
        argv = runner.calls[0]
        self.assertIn("pr", argv)
        self.assertIn("comment", argv)
        self.assertIn("--body-file", argv)
        body_file = Path(argv[argv.index("--body-file") + 1])
        body = runner.bodies[0]
        self.assertIsNotNone(body, "runner must be called with a body file that exists at call time")
        self.assertFalse(body_file.exists(), "scratch body file must be deleted after posting")
        self.assertTrue(body.startswith(self.MARKER))
        self.assertIn("| round | head | verdict |", body)
        exact_json = json.dumps(record, indent=2, sort_keys=True)
        self.assertIn(exact_json, body)
        self.assertEqual(argv[:3], ["gh", "pr", "comment"])
        self.assertIn("42", argv)
        self.assertIn("--repo", argv)
        self.assertIn("o/r", argv)

    def test_ordinary_prose_digest_survives_record_and_compact_read(self):
        record = valid_record(ordinary_prose=valid_ordinary_prose())
        runner = FakeRunner(history=[])
        self.assertEqual(
            self.record_command("o/r", 42, record, runner=runner), (0, None)
        )
        full = self.m["read_rounds"]("o/r", 42, gh=runner.gh)
        compact = self.m["compact_ledger"](full)
        self.assertEqual(full["ledger_errors"], [])
        self.assertEqual(full["rounds"][0]["record"], record)
        self.assertEqual(
            compact["rounds"][0]["record"]["ordinary_prose"], record["ordinary_prose"]
        )

    def test_invalid_head_exits_nonzero_naming_field_no_runner_call(self):
        record = valid_record(head="short")
        runner = FakeRunner()
        code, errors = self.record_command("o/r", 42, record, runner=runner)
        self.assertEqual(code, 1)
        self.assertTrue(any(e.startswith("head:") for e in errors))
        self.assertEqual(runner.calls, [])

    def test_findings_over_bound_exits_nonzero_naming_field_no_runner_call(self):
        findings = [{"file": "a", "severity": "P1", "title": "x"} for _ in range(201)]
        record = valid_record(findings=findings)
        runner = FakeRunner()
        code, errors = self.record_command("o/r", 42, record, runner=runner)
        self.assertEqual(code, 1)
        self.assertTrue(any(e.startswith("findings:") for e in errors))
        self.assertEqual(runner.calls, [])

    def test_unhashable_enum_values_exit_nonzero_without_runner_call(self):
        for field, record in invalid_enum_records():
            with self.subTest(field=field):
                runner = FakeRunner()
                code, errors = self.record_command("o/r", 42, record, runner=runner)
                self.assertEqual(code, 1)
                self.assertTrue(any(e.startswith(f"{field}:") for e in errors), errors)
                self.assertEqual(runner.calls, [])

    def test_invalid_nested_shape_exits_nonzero_without_runner_call(self):
        entries = [
            valid_red_first_test(path=None),
            valid_red_first_test(pre_fix=None),
            valid_red_first_test(command=False),
            valid_red_first_test(reason=1),
            valid_red_first_test(exempt=1),
            valid_red_first_test(exempt_reason=[]),
            valid_red_first_test(cases=[None]),
            valid_red_first_test(cases=valid_red_first_test()["cases"] * 201),
        ]
        for entry in entries:
            with self.subTest(entry=entry):
                runner = FakeRunner()
                record = valid_record(red_first={"status": "inconclusive", "tests": [entry]})
                code, errors = self.record_command("o/r", 42, record, runner=runner)
                self.assertEqual(code, 1)
                self.assertTrue(any(e.startswith("red_first.tests:") for e in errors), errors)
                self.assertEqual(runner.calls, [])

    def test_runner_failure_propagates(self):
        record = valid_record()
        runner = FakeRunner(stderr="HTTP 404: Not Found", returncode=1, history=[])
        with self.assertRaises(RuntimeError) as ctx:
            self.record_command("o/r", 42, record, runner=runner)
        self.assertIn("404", str(ctx.exception))

    def test_repeated_record_command_does_not_append_the_same_round_twice(self):
        # PR #1390 live round 2: an agent re-ran a successful record command,
        # and the non-idempotent post appended the same round twice.
        runner = FakeRunner(history=[])
        first = self.record_command("o/r", 42, valid_record(), runner=runner)
        second = self.record_command("o/r", 42, valid_record(), runner=runner)
        self.assertEqual(first, (0, None))
        self.assertEqual(len(runner.calls), 1, "a repeated record command must not post a duplicate round")
        self.assertEqual(second[0], 1)
        self.assertTrue(any("found 1" in e for e in second[1] or []), second)

    def test_record_refuses_when_trusted_history_moved_past_its_round(self):
        prior = [comment(1, marker_body(valid_record()), "2026-09-25T03:00:00Z"),
                 comment(2, marker_body(valid_record(round=2, head="c" * 40)), "2026-09-25T03:01:00Z")]
        runner = FakeRunner(history=prior)
        code, errors = self.record_command("o/r", 42, valid_record(round=2, head="d" * 40), runner=runner)
        self.assertEqual(code, 1)
        self.assertTrue(any("found 2" in e for e in errors or []), errors)
        self.assertEqual(runner.calls, [])

    def test_record_history_read_failure_never_posts(self):
        runner = FakeRunner(history=[])
        runner.gh.fail_stderr = "gh: not logged in"
        with self.assertRaises(RuntimeError):
            self.record_command("o/r", 42, valid_record(), runner=runner)
        self.assertEqual(runner.calls, [])

    def body_sized_record(self, length):
        """A valid record whose composed comment body is exactly `length`
        characters, padded through one ASCII finding title."""
        record = valid_record(findings=[{"file": "a", "severity": "P1", "title": ""}])
        record["findings"][0]["title"] = "x" * (length - len(self.m["compose_body"](record)))
        self.assertEqual(len(self.m["compose_body"](record)), length)
        return record

    def test_over_limit_body_is_refused_before_any_gh_call(self):
        # Bodies over the 65536-character limit are refused locally before any
        # gh call, so an oversized round never pays for a doomed post.
        runner = FakeRunner(history=[])
        code, errors = self.record_command("o/r", 42, self.body_sized_record(65537), runner=runner)
        self.assertEqual(code, 1)
        self.assertEqual(len(errors), 1, errors)
        self.assertTrue(errors[0].startswith("ledger-record-too-large:"), errors)
        self.assertIn("65537", errors[0])
        self.assertEqual(runner.calls, [])
        self.assertEqual(runner.gh.calls, [], "the size refusal must precede the history read too")

    def test_at_limit_body_posts(self):
        runner = FakeRunner(history=[])
        self.assertEqual(self.record_command("o/r", 42, self.body_sized_record(65536), runner=runner), (0, None))
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(len(runner.bodies[0]), 65536)

    def test_ref_name_baselines_are_refused_without_runner_call(self):
        tampered = {
            "tests": valid_record(red_first={"status": "verified", "tests": [
                valid_red_first_test(pre_fix="refs/remotes/origin/attacker-branch")]}),
            "unchanged": valid_record(red_first={"status": "verified", "tests": [valid_red_first_test()],
                                                 "unchanged": [{"path": "p", "pre_fix": "HEAD~1"}]}),
        }
        for field, record in tampered.items():
            with self.subTest(field=field):
                runner = FakeRunner(history=[])
                code, errors = self.record_command("o/r", 42, record, runner=runner)
                self.assertEqual(code, 1)
                self.assertTrue(any(e.startswith(f"red_first.{field}:") and "pre_fix" in e for e in errors), errors)
                self.assertEqual((runner.calls, runner.gh.calls), ([], []))

    def test_record_counts_prior_rounds_with_the_same_extra_trusted_ids_as_read(self):
        # `read` and `confirm` admit rounds from --trusted-author-id; a record
        # counting with operator-only trust would refuse every later post.
        prior = [comment(1, marker_body(valid_record()), "2026-09-25T02:00:00Z", author_id=202)]
        pending = valid_record(round=2, head="d" * 40, patch_id="e" * 40)
        runner = FakeRunner(history=prior)
        code, errors = self.record_command("o/r", 42, pending, runner=runner)
        self.assertEqual(code, 1)
        self.assertTrue(any("found 0" in e for e in errors or []), errors)
        self.assertEqual(runner.calls, [])
        self.assertEqual(self.record_command("o/r", 42, pending, runner=runner, trusted_author_ids=[202]),
                         (0, None))
        self.assertEqual(len(runner.calls), 1)


class MainCliTests(unittest.TestCase):
    """End-to-end through main(), argv in and stdout/stderr out, with
    subprocess.run replaced -- as test_ci_queue_waits.py's GhBoundaryTests
    class does for main()'s default path."""

    def setUp(self):
        self.m = load_module()
        self.main = self.m["main"]

    def test_read_reports_runner_failure_and_exits_nonzero(self):
        import contextlib
        import io
        from unittest import mock

        runner = FakeRunner(stderr="gh: not logged in", returncode=1)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(subprocess, "run", runner), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.main(["read", "--repo", "o/r", "--pr", "5"])
        self.assertEqual(rc, 1)
        self.assertIn("not logged in", err.getvalue())
        self.assertEqual(out.getvalue(), "")

    def test_record_invalid_file_exits_nonzero_no_runner_call(self):
        import contextlib
        import io
        from unittest import mock

        record = valid_record(head="short")
        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as tmp:
            record_path = Path(tmp) / "record.json"
            record_path.write_text(json.dumps(record), encoding="utf-8")
            err = io.StringIO()
            with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stderr(err):
                rc = self.main(["record", "--repo", "o/r", "--pr", "42", "--record", str(record_path)])
        self.assertEqual(rc, 1)
        self.assertIn("head:", err.getvalue())
        self.assertEqual(runner.calls, [])

    def test_record_cli_second_invocation_refuses_duplicate_without_posting(self):
        import contextlib
        import io
        from unittest import mock

        runner = FakeRunner(history=[])
        with tempfile.TemporaryDirectory() as tmp:
            record_path = Path(tmp) / "record.json"
            record_path.write_text(json.dumps(valid_record()), encoding="utf-8")
            err = io.StringIO()
            argv = ["record", "--repo", "o/r", "--pr", "42", "--record", str(record_path)]
            with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stderr(err):
                rcs = (self.main(argv), self.main(argv))
        self.assertEqual(rcs, (0, 1))
        self.assertEqual(len(runner.calls), 1)
        self.assertIn("found 1", err.getvalue())

    def test_record_not_json_exits_nonzero_no_runner_call(self):
        import contextlib
        import io
        from unittest import mock

        runner = FakeRunner()
        with tempfile.TemporaryDirectory() as tmp:
            record_path = Path(tmp) / "record.json"
            record_path.write_text("{not json", encoding="utf-8")
            err = io.StringIO()
            with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stderr(err):
                rc = self.main(["record", "--repo", "o/r", "--pr", "42", "--record", str(record_path)])
        self.assertEqual(rc, 1)
        self.assertEqual(runner.calls, [])

    def test_record_valid_file_posts_and_exits_zero(self):
        import contextlib
        import io
        from unittest import mock

        record = valid_record()
        runner = FakeRunner(history=[])
        with tempfile.TemporaryDirectory() as tmp:
            record_path = Path(tmp) / "record.json"
            record_path.write_text(json.dumps(record), encoding="utf-8")
            out = io.StringIO()
            with mock.patch.object(subprocess, "run", runner), contextlib.redirect_stdout(out):
                rc = self.main(["record", "--repo", "o/r", "--pr", "42", "--record", str(record_path)])
        self.assertEqual(rc, 0)
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(runner.calls[0][:3], ["gh", "pr", "comment"])

    def record_cli(self, runner, record, *extra_args):
        with tempfile.TemporaryDirectory() as tmp:
            record_path = Path(tmp) / "record.json"
            record_path.write_text(json.dumps(record), encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(subprocess, "run", runner), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = self.main(["record", "--repo", "o/r", "--pr", "42", "--record", str(record_path),
                                    *extra_args])
                except SystemExit as exc:  # argparse refusals exit 2
                    rc = exc.code
        return rc, out.getvalue(), err.getvalue()

    def test_record_cli_reports_oversized_body_and_exits_nonzero(self):
        record = valid_record(findings=[{"file": "a", "severity": "P1", "title": "x" * 70000}])
        runner = FakeRunner(history=[])
        rc, out, err = self.record_cli(runner, record)
        self.assertEqual((rc, out), (1, ""))
        self.assertTrue(err.startswith("ledger-record-too-large:"), err)
        self.assertIn(str(len(self.m["compose_body"](record))), err)
        self.assertEqual((runner.calls, runner.gh.calls), ([], []))

    def test_record_cli_accepts_repeatable_trusted_author_ids(self):
        prior = [comment(1, marker_body(valid_record()), "2026-09-25T02:00:00Z", author_id=202),
                 comment(2, marker_body(valid_record(round=2, head="c" * 40, patch_id="c" * 40)),
                         "2026-09-25T02:01:00Z", author_id=303)]
        pending = valid_record(round=3, head="d" * 40, patch_id="e" * 40)
        runner = FakeRunner(history=prior)
        rc, _, err = self.record_cli(runner, pending, "--trusted-author-id", "202", "--trusted-author-id", "303")
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(len(runner.calls), 1)

    def test_record_cli_rejects_malformed_trusted_author_id_before_gh(self):
        runner = FakeRunner(history=[])
        rc, out, err = self.record_cli(runner, valid_record(), "--trusted-author-id", "0")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("positive integer", err)
        self.assertEqual((runner.calls, runner.gh.calls), ([], []))


class CompactReadTests(unittest.TestCase):
    """`read --compact` is what the workflow's agents transport. The full
    ledger embeds each RED test's command, reason (test output) and case list;
    on PR #1390 a Collect agent abbreviated that 22.5 KB history instead of
    echoing it, and the workflow correctly refused the round."""

    def setUp(self):
        self.m = load_module()

    def test_digestless_attestation_is_a_ledger_error_but_legacy_round_remains_valid(
        self,
    ):
        prose = valid_ordinary_prose()
        del prose["patch_sha256"]
        comments = [
            comment(1, marker_body(valid_record()), "2026-09-24T00:01:00Z"),
            comment(
                2,
                marker_body(valid_record(ordinary_prose=prose)),
                "2026-09-24T00:02:00Z",
            ),
        ]
        compact = self.m["compact_ledger"](
            self.m["read_rounds"]("o/r", 5, gh=FakeGh(comments))
        )
        self.assertEqual(len(compact["rounds"]), 1)
        self.assertNotIn("ordinary_prose", compact["rounds"][0]["record"])
        self.assertEqual(len(compact["ledger_errors"]), 1)
        self.assertEqual(compact["ledger_errors"][0]["comment_id"], 2)
        self.assertIn("ordinary_prose", compact["ledger_errors"][0]["reason"])

    def full_ledger(self):
        red = {
            "status": "inconclusive", "head": "d" * 40, "base_branch": "e" * 40,
            "overlay": ["tests/suite.test.sh"], "exempt": [],
            "unchanged": [{"path": "tests/other.test.sh", "pre_fix": "f" * 40}],
            "requested": [{"path": "tests/suite.test.sh", "pre_fix": "c" * 40}],
            "tests": [valid_red_first_test(
                reason='pre-fix exit 1: Traceback (most recent call last): "x"\\n')],
        }
        entries = [valid_record(), valid_record(round=2, head="1" * 40, patch_id="2" * 40, red_first=red)]
        return {
            "target": {"repo": "o/r", "pr": 5}, "ledger_errors": [],
            "rounds": [
                {"round": n, "rerun": False, "comment_id": n, "author_id": OPERATOR_ID,
                 "created_at": f"2026-09-24T00:0{n}:00Z", "record": record}
                for n, record in enumerate(entries, start=1)
            ],
        }

    def test_compact_ledger_drops_only_red_test_transcripts(self):
        compact_ledger = self.m.get("compact_ledger")
        self.assertIsNotNone(compact_ledger, "review-rounds.py must define compact_ledger")
        full = self.full_ledger()
        untouched = json.loads(json.dumps(full))
        compact = compact_ledger(full)
        expected = json.loads(json.dumps(full))
        expected["view"] = "compact"
        for entry in expected["rounds"]:
            for test in entry["record"]["red_first"]["tests"]:
                for key in ("command", "reason"):
                    del test[key]
                # Case names stay: the workflow's never-red carry reads them (Pro gate at e2688e9f).
                test["cases"] = [{"name": case["name"]} for case in test["cases"]]
        self.assertTrue(any(test["cases"] for entry in expected["rounds"]
                            for test in entry["record"]["red_first"]["tests"]),
                        "the fixture must hold at least one case for the name check to bite")
        self.assertEqual(compact, expected)
        self.assertEqual(full, untouched, "compacting must not mutate the full ledger")

    def read_cli(self, *extra_args):
        record = valid_record(red_first={"status": "inconclusive", "tests": [valid_red_first_test()]})
        gh = FakeGh([comment(1, marker_body(record), "2026-09-24T00:00:00Z")])
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(subprocess, "run", gh.run), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = self.m["main"](["read", "--repo", "o/r", "--pr", "5", *extra_args])
            except SystemExit as exc:  # an unknown flag exits 2 from argparse
                rc = exc.code
        return rc, out.getvalue(), err.getvalue()

    def test_read_cli_compact_prints_the_compact_view(self):
        rc, out, err = self.read_cli("--compact")
        self.assertEqual((rc, err), (0, ""))
        result = json.loads(out)
        self.assertEqual(result["view"], "compact")
        self.assertEqual(result["rounds"][0]["record"]["red_first"]["tests"], [{
            "path": "tests/suite.test.sh", "pre_fix": "c" * 40, "status": "ran",
            "exempt": False, "exempt_reason": None, "cases": [{"name": "unresolved_case"}],
        }])

    def test_read_cli_default_view_stays_full(self):
        rc, out, err = self.read_cli()
        self.assertEqual((rc, err), (0, ""))
        result = json.loads(out)
        self.assertNotIn("view", result)
        self.assertEqual(result["rounds"][0]["record"]["red_first"]["tests"], [valid_red_first_test()])


class ConfirmRoundTests(unittest.TestCase):
    """`confirm` is the deterministic readback after a posting attempt. On PR
    #1390 round 4 the Readback agent re-typed the transported history and
    "corrected" the duplicate round 3 (inner round 2, rerun false) to match its
    envelope, so a correct post failed as a history conflict."""

    def setUp(self):
        self.m = load_module()
        self.confirm = self.m.get("confirm_round")
        red = {"status": "verified", "tests": [valid_red_first_test(reason="pre-fix exit 1: \"x\"")]}
        self.r1 = valid_record(head="1" * 40, patch_id="a" * 40)
        self.r2 = valid_record(round=2, head="2" * 40, patch_id="b" * 40, red_first=red)
        self.pending = valid_record(round=4, head="4" * 40, patch_id="d" * 40, red_first=red)
        # The live shape: round 3 is an exact duplicate post of round 2.
        self.history = [comment(n, marker_body(r), f"2026-09-25T03:0{n}:00Z")
                        for n, r in enumerate((self.r1, self.r2, self.r2), start=1)]
        self.captured = self.m["compact_ledger"](self.m["read_rounds"]("o/r", 5, gh=FakeGh(self.history)))

    def check(self, comments, **overrides):
        self.assertIsNotNone(self.confirm, "review-rounds.py must define confirm_round")
        args = {"captured": self.captured, "record": self.pending, **overrides}
        return self.confirm("o/r", 5, args["captured"], args["record"], gh=FakeGh(comments))

    def posted(self, record, n=4):
        return comment(n, marker_body(record), f"2026-09-25T04:0{n}:00Z")

    def test_exact_single_append_confirms_despite_duplicate_prior_round(self):
        self.assertEqual(self.captured["rounds"][2]["record"]["round"], 2)
        result = self.check(self.history + [self.posted(self.pending)])
        self.assertEqual(result, {"status": "appended", "rounds": 4, "round": 4, "comment_id": 4, "reason": None})

    def test_no_append_is_unchanged(self):
        self.assertEqual(self.check(self.history),
                         {"status": "unchanged", "rounds": 3, "round": None, "comment_id": None, "reason": None})

    def test_conflicts_name_the_changed_evidence(self):
        edited = [*self.history[:1], comment(2, marker_body(dict(self.r2, diff_lines=99)), "2026-09-25T03:02:00Z"),
                  *self.history[2:]]
        corrupt = self.history + [comment(9, "<!-- review-adversarial-first:round:v1 -->\nno json",
                                          "2026-09-25T03:09:00Z")]
        cases = {
            "different record": (self.history + [self.posted(dict(self.pending, diff_lines=13))], "differs"),
            "prior round edited": (edited + [self.posted(self.pending)], "before the pending round"),
            "new ledger error": (corrupt + [self.posted(self.pending)], "ledger errors"),
            "two appends": (self.history + [self.posted(self.pending), self.posted(self.pending, n=5)],
                            "more than one"),
            "round removed": (self.history[:2], "before the pending round"),
        }
        for name, (comments, reason) in cases.items():
            with self.subTest(name=name):
                result = self.check(comments)
                self.assertEqual(result["status"], "conflict")
                self.assertIn(reason, result["reason"])

    def test_inputs_that_cannot_anchor_a_readback_raise(self):
        self.assertIsNotNone(self.confirm, "review-rounds.py must define confirm_round")
        full = self.m["read_rounds"]("o/r", 5, gh=FakeGh(self.history))
        not_compact = "--ledger must be this PR's `read --compact` output"
        for name, (overrides, message) in {
            "full view": ({"captured": full}, not_compact),
            "other PR": ({"captured": dict(self.captured, target={"repo": "o/r", "pr": 6})}, not_compact),
            "wrong round": ({"record": dict(self.pending, round=3)},
                            "--record round 3 does not follow the 3 captured round(s)"),
            "invalid record": ({"record": dict(self.pending, head="short")},
                               "--record is invalid: head: must be 40 lowercase hex characters"),
        }.items():
            with self.subTest(name=name):
                args = {"captured": self.captured, "record": self.pending, **overrides}
                gh = FakeGh(self.history)
                with self.assertRaises(RuntimeError) as ctx:
                    self.confirm("o/r", 5, args["captured"], args["record"], gh=gh)
                self.assertEqual(str(ctx.exception), message)
                self.assertEqual(gh.calls, [], "an unanchored readback must refuse before reading history")

    def test_confirm_cli_reads_both_files_and_prints_the_outcome(self):
        gh = FakeGh(self.history + [self.posted(self.pending)])
        with tempfile.TemporaryDirectory() as tmp:
            ledger_path, record_path = Path(tmp) / "ledger.json", Path(tmp) / "round.json"
            ledger_path.write_text(json.dumps(self.captured), encoding="utf-8")
            record_path.write_text(json.dumps(self.pending), encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(subprocess, "run", gh.run), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = self.m["main"](["confirm", "--repo", "o/r", "--pr", "5",
                                         "--ledger", str(ledger_path), "--record", str(record_path)])
                except SystemExit as exc:  # an unknown subcommand exits 2 from argparse
                    rc = exc.code
        self.assertEqual((rc, err.getvalue()), (0, ""))
        self.assertEqual(json.loads(out.getvalue())["status"], "appended")


if __name__ == "__main__":
    unittest.main()
