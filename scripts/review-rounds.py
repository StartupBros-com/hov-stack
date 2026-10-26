#!/usr/bin/env python3
"""PR round ledger: read and record adversarial-first review rounds as
marker comments on a PR through `gh`, with the record shape pinned here.

Creation gate (plan KTD7, docs/plans/2026-09-23-1741-feat-review-round-red-
gate-and-breaker-plan.md):
  consumer  -- the review-adversarial-first workflow's RedFirst and Record
               stages, and any session closing a finding by hand.
  gate      -- whether a finding may close, and whether another round runs.
  defect    -- one never-red regression test that closed on PR #1294, and
               three review loops only the operator ended by hand.
  deletion  -- when the review ladder entry tier is retired, or after three
               consecutive calendar months that each contain at least one
               scored round (re-runs excluded) whose red_first.tests include
               a path with status ran or file-level (RED executed), and in
               which no round records a never-red finding or a freeze. A
               round whose RED was unverifiable or not applicable does not
               qualify; a month without a qualifying round does not count.

Usage:
  review-rounds.py read --repo OWNER/REPO --pr N [--trusted-author-id ID ...] [--compact]
  review-rounds.py record --repo OWNER/REPO --pr N --record FILE [--trusted-author-id ID ...]
  review-rounds.py confirm --repo OWNER/REPO --pr N --ledger FILE --record FILE [--trusted-author-id ID ...]

`read` resolves the authenticated operator's numeric ID through `gh api
user` and trusts that ID plus any repeatable `--trusted-author-id` caller
options. Only those authors' API `user.id` values can admit marker comments;
body fields, logins and author associations never confer trust. Missing,
malformed or untrusted authors become `ledger_errors` naming the comment ID,
without affecting round numbers or reruns. Accepted rounds retain the API
identity as `author_id` outside the record body. Identity lookup failure is
a non-zero error, even with explicit trusted IDs, never an empty history.

`read` lists the PR's issue comments, keeps the trusted ones whose body starts
with MARKER, parses each one's first fenced ```json block, sorts by parsed
`created_at`, and numbers every valid record 1..n in that order. A record
whose `head` equals any earlier record's, or whose `patch_id` equals the
previous NON-RERUN record's, is a re-run (the earlier record is the round it
re-runs); it still gets its own sequential number but is flagged `rerun: true`
so a streak computation can skip it (R7). A marker comment whose body has no
fenced JSON block, invalid JSON, or a JSON object that fails `validate_record`
is never silently dropped: it becomes a `ledger_errors` entry naming the
comment id and the reason.

`read --compact` prints the same envelope plus `view: "compact"`, with each
RED test's `command` and `reason` omitted and each case reduced to its `name`.
No round decision reads those transcripts or per-case statuses, and they stay
on the PR comment; the workflow's never-red carry does read case names, to find
the revision a case was first attributed against. The workflow's agents
transport this view because a Collect agent abbreviated the full history
(22.5 KB at three rounds) on PR #1390 instead of echoing it.

`confirm` is the readback after a posting attempt. It re-reads the trusted
history, compares it with the captured `read --compact` file and the pending
record file, and prints `unchanged`, `appended` or `conflict` (with a reason),
so no agent has to re-type history: on PR #1390 a Readback agent "corrected"
a duplicate round while re-typing it and turned a correct post into a failure.

`record` validates a JSON file against the pinned shape (`validate_record`)
before ever calling `gh`; on any violation it exits non-zero naming the
field on stderr and makes no runner call. Every RED `pre_fix` naming a
tree the runner executed or proved unchanged is a full 40-hex SHA, because
a trusted record's baselines seed later RED manifests; an unverifiable
entry that ran nothing keeps the runner's raw value. It then composes the comment body (the marker line, a short
table, then the exact JSON in a fenced block); a body over MAX_COMMENT_BODY
(65536 characters) is refused as `ledger-record-too-large:`, again with no
runner call. Otherwise it posts the body with `gh pr comment --body-file`.

The `gh` boundary is a runner function injected the way
scripts/ci-queue-waits.py's gh_lines does it: looked up at call time
so a patched subprocess.run is honoured on the default path too.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import TypeGuard

MARKER = "<!-- review-adversarial-first:round:v1 -->"

SCHEMA = "review-adversarial-first/round/v1"
VERDICTS = {"CLEAN", "BORDERLINE", "DIRTY", "FROZEN"}
UNDERLYING_VERDICTS = {"CLEAN", "BORDERLINE", "DIRTY"}
SEVERITIES = {"P1", "P2", "P3"}
RED_FIRST_STATUSES = {"not-applicable", "verified", "never-red", "inconclusive", "unverifiable"}
RED_FIRST_PATH_STATUSES = {"ran", "file-level", "unsupported", "unverifiable"}
RED_FIRST_REVISION_STATUSES = {"pass", "fail", "unresolved", "unsupported"}
RED_FIRST_CASE_STATUSES = {"verified", "never-red", "inconclusive", "fails-at-head", "unsupported"}
RED_FIRST_TEST_KEYS = ("path", "pre_fix", "status", "command", "reason", "exempt", "cases")
RED_FIRST_CASE_KEYS = ("name", "pre_fix", "head", "status")
RED_FIRST_UNCHANGED_KEYS = ("path", "pre_fix")
COMPACT_DROPPED_TEST_KEYS = ("command", "reason")
# A compact case keeps only its name: the workflow's never-red carry finds the
# revision a case was first attributed against by name (Pro gate at e2688e9f).
COMPACT_CASE_KEYS = ("name",)

MAX_FINDINGS = 200
MAX_RESIDUAL_CLASSES = 200
MAX_RED_FIRST_TESTS = 100
MAX_RED_FIRST_CASES = 200
# Comment-body limit. Not in GitHub's published API docs: taken from
# papercut's local refusal of issue bodies past it, added on an issue #527
# review finding (tests/test_papercut.py); no comment post has been
# observed failing at it.
MAX_COMMENT_BODY = 65536

HEX40_RE = re.compile(r"[0-9a-f]{40}")
FENCE_RE = re.compile(r"```json\r?\n(.*?)\r?\n```", re.DOTALL)


def _is_int(value: object) -> TypeGuard[int]:
    """True for a real int, false for a bool (bool is an int subclass) or
    anything else -- every bound below is an integer, never a boolean."""
    return isinstance(value, int) and not isinstance(value, bool)


def _is_author_id(value: object) -> TypeGuard[int]:
    return _is_int(value) and value > 0


def parse_author_id(value: str) -> int:
    """CLI IDs are positive ASCII decimal integers, not names or floats."""
    if not re.fullmatch(r"[0-9]+", value) or int(value) < 1:
        raise argparse.ArgumentTypeError("trusted author ID must be a positive integer")
    return int(value)


def _is_hex40(value) -> bool:
    return isinstance(value, str) and bool(HEX40_RE.fullmatch(value))


def _is_string_enum(value, choices) -> bool:
    """Safely test a JSON value against a closed string vocabulary."""
    return isinstance(value, str) and value in choices


def _is_nullable_string(value) -> bool:
    return value is None or isinstance(value, str)


def parse_ts(value):
    """GitHub API timestamps are `YYYY-MM-DDTHH:MM:SSZ`; anything else is
    None (never a raised exception -- an unparseable timestamp is the
    caller's problem to report, not this function's to crash on)."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def validate_record(record) -> list[str]:
    """Validate `record` against the pinned review-adversarial-first round
    shape. Returns a list of `field: reason` strings, empty when valid.
    Exposed as a function (not folded into the CLI) so the workflow's own
    test suite in a later PR can round-trip records through the same
    check the ledger script itself uses to gate a post."""
    if not isinstance(record, dict):
        return ["record: must be a JSON object"]

    errors: list[str] = []

    def err(field: str, msg: str) -> None:
        errors.append(f"{field}: {msg}")

    if record.get("schema") != SCHEMA:
        err("schema", f"must equal {SCHEMA!r}")

    for field in ("head", "patch_id"):
        if not _is_hex40(record.get(field)):
            err(field, "must be 40 lowercase hex characters")

    round_no = record.get("round")
    if not _is_int(round_no) or round_no < 1:
        err("round", "must be an integer >= 1")

    diff_lines = record.get("diff_lines")
    if not _is_int(diff_lines) or diff_lines < 0:
        err("diff_lines", "must be an integer >= 0")

    if not _is_string_enum(record.get("verdict"), VERDICTS):
        err("verdict", f"must be one of {sorted(VERDICTS)}")

    if not _is_string_enum(record.get("underlying_verdict"), UNDERLYING_VERDICTS):
        err("underlying_verdict", f"must be one of {sorted(UNDERLYING_VERDICTS)}")

    live = record.get("live")
    if (
        not isinstance(live, dict)
        or set(live) != {"P1", "P2", "P3"}
        or any(not _is_int(v) or v < 0 for v in live.values())
    ):
        err("live", "must be an object with non-negative integer P1, P2, P3")

    findings = record.get("findings")
    if not isinstance(findings, list) or len(findings) > MAX_FINDINGS:
        err("findings", f"must be an array of at most {MAX_FINDINGS} items")
    else:
        for i, item in enumerate(findings):
            if (
                not isinstance(item, dict)
                or not isinstance(item.get("file"), str)
                or not _is_string_enum(item.get("severity"), SEVERITIES)
                or not isinstance(item.get("title"), str)
            ):
                err("findings", f"item {i} must be {{file, severity in P1|P2|P3, title}}")

    residual_classes = record.get("residual_classes")
    if residual_classes is not None:
        if not isinstance(residual_classes, list) or len(residual_classes) > MAX_RESIDUAL_CLASSES:
            err("residual_classes", f"must be an array of at most {MAX_RESIDUAL_CLASSES} items")
        else:
            for i, item in enumerate(residual_classes):
                titles = item.get("titles") if isinstance(item, dict) else None
                if (
                    not isinstance(item, dict)
                    or not isinstance(item.get("file"), str)
                    or not _is_string_enum(item.get("severity"), SEVERITIES)
                    or not isinstance(titles, list)
                    or not all(isinstance(t, str) for t in titles)
                ):
                    err("residual_classes", f"item {i} must be {{file, severity, titles: [str, ...]}}")
        if record.get("verdict") != "FROZEN":
            err("residual_classes", "present only when verdict is FROZEN")

    red_first = record.get("red_first")
    if not isinstance(red_first, dict):
        err("red_first", "must be an object")
    else:
        if not _is_string_enum(red_first.get("status"), RED_FIRST_STATUSES):
            err("red_first.status", f"must be one of {sorted(RED_FIRST_STATUSES)}")
        tests = red_first.get("tests")
        if not isinstance(tests, list) or len(tests) > MAX_RED_FIRST_TESTS:
            err("red_first.tests", f"must be an array of at most {MAX_RED_FIRST_TESTS} items")
        else:
            for i, test in enumerate(tests):
                if not isinstance(test, dict):
                    err("red_first.tests", f"item {i} must be an object")
                    continue
                missing = [k for k in RED_FIRST_TEST_KEYS if k not in test]
                if missing:
                    err("red_first.tests", f"item {i} missing {missing}")
                    continue
                if not isinstance(test.get("path"), str):
                    err("red_first.tests", f"item {i}: path must be a string")
                # A trusted record's pre_fix seeds a later round's RED
                # baseline, so only a full SHA may name a tree the runner
                # executed. An entry that ran nothing (an out-of-range
                # Red-first-base trailer) keeps the runner's raw value.
                pre_fix = test.get("pre_fix")
                ran_nothing = (test.get("status") == "unverifiable" and test.get("command") is None
                               and test.get("cases") == [])
                if not (_is_hex40(pre_fix) or (ran_nothing and isinstance(pre_fix, str) and pre_fix)):
                    err("red_first.tests", f"item {i}: pre_fix must be 40 lowercase hex characters")
                if not _is_string_enum(test.get("status"), RED_FIRST_PATH_STATUSES):
                    err("red_first.tests", f"item {i}: status must be one of {sorted(RED_FIRST_PATH_STATUSES)}")
                for field in ("command", "reason", "exempt_reason"):
                    if not _is_nullable_string(test.get(field)):
                        err("red_first.tests", f"item {i}: {field} must be a string or null")
                if not isinstance(test.get("exempt"), bool):
                    err("red_first.tests", f"item {i}: exempt must be a boolean")
                cases = test.get("cases")
                if not isinstance(cases, list) or len(cases) > MAX_RED_FIRST_CASES:
                    err(
                        "red_first.tests",
                        f"item {i}: cases must be an array of at most {MAX_RED_FIRST_CASES} items",
                    )
                    continue
                for j, case in enumerate(cases):
                    if not isinstance(case, dict):
                        err("red_first.tests", f"item {i} case {j} must be an object")
                        continue
                    case_missing = [k for k in RED_FIRST_CASE_KEYS if k not in case]
                    if case_missing:
                        err("red_first.tests", f"item {i} case {j} missing {case_missing}")
                        continue
                    if not isinstance(case.get("name"), str):
                        err("red_first.tests", f"item {i} case {j}: name must be a string")
                    for field in ("pre_fix", "head"):
                        if not _is_string_enum(case.get(field), RED_FIRST_REVISION_STATUSES):
                            err(
                                "red_first.tests",
                                f"item {i} case {j}: {field} must be one of "
                                f"{sorted(RED_FIRST_REVISION_STATUSES)}",
                            )
                    if not _is_string_enum(case.get("status"), RED_FIRST_CASE_STATUSES):
                        err(
                            "red_first.tests",
                            f"item {i} case {j}: status must be one of "
                            f"{sorted(RED_FIRST_CASE_STATUSES)}",
                        )
        # red-first.sh's equal-blob paths; carried forward as baselines too.
        if "unchanged" in red_first:
            unchanged = red_first["unchanged"]
            if not isinstance(unchanged, list) or len(unchanged) > MAX_RED_FIRST_TESTS:
                err("red_first.unchanged", f"must be an array of at most {MAX_RED_FIRST_TESTS} items")
            else:
                for i, item in enumerate(unchanged):
                    if not isinstance(item, dict) or set(item) != set(RED_FIRST_UNCHANGED_KEYS):
                        err("red_first.unchanged", f"item {i} must be an object with exactly path and pre_fix")
                        continue
                    if not isinstance(item["path"], str):
                        err("red_first.unchanged", f"item {i}: path must be a string")
                    if not _is_hex40(item["pre_fix"]):
                        err("red_first.unchanged", f"item {i}: pre_fix must be 40 lowercase hex characters")

    streak = record.get("streak")
    if not _is_int(streak) or streak < 0:
        err("streak", "must be an integer >= 0")

    for field in ("override", "rerun"):
        if not isinstance(record.get(field), bool):
            err(field, "must be a boolean")

    if not isinstance(record.get("ledger_errors"), list):
        err("ledger_errors", "must be an array")

    # Optional positive semantic attestation. Omission preserves legacy records
    # but cannot authorize an ordinary-prose terminal exemption.
    if "ordinary_prose" in record:
        prose = record["ordinary_prose"]
        lenses = {"own-doctrine", "strongest-lever", "no-op-or-regression"}
        if not isinstance(prose, dict) or set(prose) != {
            "base",
            "head",
            "patch_sha256",
            "evidence",
        }:
            err(
                "ordinary_prose",
                "must contain exactly base, head, patch_sha256, evidence",
            )
        else:
            if not _is_hex40(prose["base"]):
                err("ordinary_prose.base", "must be 40 lowercase hex characters")
            if not _is_hex40(prose["head"]) or prose["head"] != record.get("head"):
                err("ordinary_prose.head", "must equal record head")
            if not isinstance(prose["patch_sha256"], str) or not re.fullmatch(
                r"[0-9a-f]{64}", prose["patch_sha256"]
            ):
                err(
                    "ordinary_prose.patch_sha256", "must be 64 lowercase hex characters"
                )
            evidence = prose["evidence"]
            if (not isinstance(evidence, list) or len(evidence) != 3
                    or any(not isinstance(e, dict) or set(e) != {"lens", "consumer_evidence"}
                           or not isinstance(e["lens"], str)
                           or not isinstance(e["consumer_evidence"], str)
                           or not e["consumer_evidence"].strip()
                           or len(e["consumer_evidence"]) > 1000 for e in evidence)
                    or {e["lens"] for e in evidence} != lenses):
                err("ordinary_prose.evidence", "requires all three distinct lenses with nonblank consumer evidence <=1000 characters")
        if (record.get("verdict") != "CLEAN" or record.get("underlying_verdict") != "CLEAN"
                or record.get("override") is not False or record.get("ledger_errors") != []
                or not isinstance(live, dict) or live.get("P1") != 0 or live.get("P2") != 0
                or (isinstance(findings, list) and any(isinstance(f, dict) and f.get("severity") in ("P1", "P2")
                                                     for f in findings))):
            err("ordinary_prose", "requires CLEAN without override, ledger errors or live P1/P2")

    return errors


def gh_lines(path, jq, runner=None):
    """`gh api --paginate PATH --jq JQ`, one JSON object per output line.
    `runner` stands in for subprocess.run under test; looked up at call
    time so a patched subprocess.run is honoured on the default path too."""
    proc = (runner or subprocess.run)(
        ["gh", "api", "--paginate", path, "--jq", jq],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh api {path}: {proc.stderr.strip()[:300]}")
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def fetch_comments(owner_repo, pr, gh=gh_lines):
    path = f"repos/{owner_repo}/issues/{pr}/comments"
    return gh(path, ".[]")


def authenticated_author_id(gh=gh_lines) -> int:
    """Resolve identity at the same injected boundary as comment reads."""
    try:
        ids = gh("user", ".id")
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"gh api user: cannot resolve authenticated author ID: {exc}") from exc
    if len(ids) != 1 or not _is_author_id(ids[0]):
        raise RuntimeError("gh api user: authenticated author ID must be one positive integer")
    return ids[0]


def post_comment(owner_repo, pr, body_file, runner=None):
    proc = (runner or subprocess.run)(
        ["gh", "pr", "comment", str(pr), "--repo", owner_repo, "--body-file", str(body_file)],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh pr comment {pr}: {proc.stderr.strip()[:300]}")
    return proc


def parse_record_from_body(body: str):
    """Extract and validate the first fenced ```json block in a marker
    comment's body. Returns (record, None) on success, or (None, reason)
    naming why the comment could not be read as a round record -- the
    caller turns that into a ledger_errors entry, never a silent drop."""
    match = FENCE_RE.search(body)
    if not match:
        return None, "no fenced ```json block found"
    try:
        parsed = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON in fenced block: {exc}"
    if not isinstance(parsed, dict):
        return None, "fenced JSON block is not an object"
    errors = validate_record(parsed)
    if errors:
        return None, "shape-invalid: " + "; ".join(errors)
    return parsed, None


def read_rounds(owner_repo, pr, gh=gh_lines, *, trusted_author_ids=()):
    """Read every marker comment on the PR, in parsed creation order, and
    return {target, rounds, ledger_errors}. Pure apart from the injected
    `gh` calls: all trust checks, ordering, numbering and re-run detection
    happen here. Caller-supplied IDs add to (never replace) operator trust."""
    trusted_ids = set()
    for author_id in trusted_author_ids:
        if not _is_author_id(author_id):
            raise RuntimeError("trusted author ID must be a positive integer")
        trusted_ids.add(author_id)
    trusted_ids.add(authenticated_author_id(gh=gh))
    comments = fetch_comments(owner_repo, pr, gh=gh)
    marker_comments = [
        c for c in comments
        if isinstance(c, dict) and isinstance(c.get("body"), str) and c["body"].startswith(MARKER)
    ]

    parsed = []
    for comment in marker_comments:
        comment_id = comment.get("id")
        created = parse_ts(comment.get("created_at"))
        user = comment.get("user")
        author_id = user.get("id") if isinstance(user, dict) else None
        if not _is_author_id(author_id):
            kind = "invalid-author"
            record, reason = None, "missing or invalid author user.id: must be a positive integer"
        elif author_id not in trusted_ids:
            kind = "untrusted-author"
            record, reason = None, f"untrusted author ID {author_id}"
        else:
            kind = "invalid-record"
            record, reason = parse_record_from_body(comment["body"])
        if record is not None and created is None:
            record, reason = None, "unparseable created_at"
        parsed.append((created, comment_id, author_id, record, reason, kind))

    parsed.sort(key=lambda item: (
        item[0] is None,
        item[0] or datetime.min.replace(tzinfo=timezone.utc),
        item[1] if item[1] is not None else 0,
    ))

    rounds = []
    ledger_errors = []
    seen_heads = set()
    previous_scored_patch_id = None
    n = 0
    for created, comment_id, author_id, record, reason, kind in parsed:
        if record is None:
            ledger_errors.append({"comment_id": comment_id, "reason": reason, "kind": kind})
            continue
        n += 1
        head = record.get("head")
        patch_id = record.get("patch_id")
        is_rerun = head in seen_heads or (
            previous_scored_patch_id is not None and patch_id == previous_scored_patch_id
        )
        rounds.append({
            "round": n,
            "rerun": is_rerun,
            "comment_id": comment_id,
            "author_id": author_id,
            "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "record": record,
        })
        seen_heads.add(head)
        if not is_rerun:
            previous_scored_patch_id = patch_id

    return {
        "target": {"repo": owner_repo, "pr": pr},
        "rounds": rounds,
        "ledger_errors": ledger_errors,
    }


def compact_record(record):
    """A validated record without each RED test's execution transcript
    (COMPACT_DROPPED_TEST_KEYS) and with each case reduced to its name
    (COMPACT_CASE_KEYS). Returns a new object."""
    red_first = record["red_first"]
    tests = [{k: ([{ck: case[ck] for ck in COMPACT_CASE_KEYS} for case in v] if k == "cases" else v)
              for k, v in test.items() if k not in COMPACT_DROPPED_TEST_KEYS}
             for test in red_first["tests"]]
    return {**record, "red_first": {**red_first, "tests": tests}}


def compact_ledger(ledger):
    """The `read --compact` envelope: every round's record compacted, marked
    `view: "compact"` so a consumer can refuse the full view."""
    rounds = [{**entry, "record": compact_record(entry["record"])} for entry in ledger["rounds"]]
    return {**ledger, "rounds": rounds, "view": "compact"}


def confirm_round(owner_repo, pr, captured, record, gh=gh_lines, *, trusted_author_ids=()):
    """Readback after one posting attempt, compared here rather than by an
    agent re-typing history. `captured` is the `read --compact` envelope the
    round was scored on and `record` the pending record file. Returns status
    `unchanged` (no new round), `appended` (exactly one new round whose full
    record, number and re-run flag equal the pending record) or `conflict`
    with a reason; inputs that cannot anchor a comparison raise."""
    if not (isinstance(captured, dict) and captured.get("view") == "compact"
            and captured.get("target") == {"repo": owner_repo, "pr": pr}
            and isinstance(captured.get("rounds"), list) and isinstance(captured.get("ledger_errors"), list)):
        raise RuntimeError("--ledger must be this PR's `read --compact` output")
    errors = validate_record(record)
    if errors:
        raise RuntimeError("--record is invalid: " + "; ".join(errors))
    n = len(captured["rounds"])
    if record["round"] != n + 1:
        raise RuntimeError(f"--record round {record['round']} does not follow the {n} captured round(s)")
    fresh = read_rounds(owner_repo, pr, gh=gh, trusted_author_ids=trusted_author_ids)
    current = compact_ledger(fresh)
    total = len(fresh["rounds"])
    outcome = {"status": "conflict", "rounds": total, "round": None, "comment_id": None, "reason": None}
    if current["ledger_errors"] != captured["ledger_errors"]:
        outcome["reason"] = "trusted ledger errors changed since capture"
    elif current["rounds"][:n] != captured["rounds"]:
        outcome["reason"] = "trusted history before the pending round changed since capture"
    elif total == n:
        outcome["status"] = "unchanged"
    elif total > n + 1:
        outcome["reason"] = f"more than one round appended since capture ({total - n})"
    else:
        appended = fresh["rounds"][n]
        if appended["record"] != record or appended["round"] != record["round"] \
                or appended["rerun"] != record["rerun"]:
            outcome["reason"] = f"appended round {appended['round']} differs from the pending record"
        else:
            outcome.update(status="appended", round=appended["round"], comment_id=appended["comment_id"])
    return outcome


def render_table(record) -> str:
    """Short markdown table: round, head short, verdict, live P1/P2/P3,
    diff lines, streak, red-first status -- one header row, one data row."""
    live = record.get("live") or {}
    red_first_status = (record.get("red_first") or {}).get("status")
    header = "| round | head | verdict | P1 | P2 | P3 | diff lines | streak | red-first |"
    sep = "|---|---|---|---|---|---|---|---|---|"
    row = (
        f"| {record.get('round')} | {str(record.get('head', ''))[:7]} | {record.get('verdict')} "
        f"| {live.get('P1', 0)} | {live.get('P2', 0)} | {live.get('P3', 0)} "
        f"| {record.get('diff_lines')} | {record.get('streak')} | {red_first_status} |"
    )
    return "\n".join([header, sep, row])


def compose_body(record) -> str:
    table = render_table(record)
    fenced_json = json.dumps(record, indent=2, sort_keys=True)
    return f"{MARKER}\n\n{table}\n\n```json\n{fenced_json}\n```\n"


def record_command(owner_repo, pr, record, runner=None, *, trusted_author_ids=()):
    """Validate `record`; on success compose the comment body, write it to
    a scratch file under the system temp dir, post it with `gh pr comment`,
    and delete the scratch file. Returns (exit_code, errors_or_None). On
    any validation failure, or a body over MAX_COMMENT_BODY characters that
    GitHub would reject on every retry, `runner` is never called.

    Posting is not idempotent, so a record posts only while the trusted
    history holds exactly `round - 1` rounds: re-running the same command
    after it succeeded (observed live on PR #1390) refuses instead of
    appending a duplicate. That history is read with the same extra trusted
    IDs `read` and `confirm` accept. A failed history read raises before
    posting."""
    errors = validate_record(record)
    if errors:
        return 1, errors
    body = compose_body(record)
    if len(body) > MAX_COMMENT_BODY:
        return 1, [f"ledger-record-too-large: comment body is {len(body)} characters, over "
                   f"the {MAX_COMMENT_BODY}-character comment limit; refusing to post"]
    history = read_rounds(owner_repo, pr, gh=lambda path, jq: gh_lines(path, jq, runner=runner),
                          trusted_author_ids=trusted_author_ids)
    found = len(history["rounds"])
    if found != record["round"] - 1:
        return 1, [f"round: record round {record['round']} expects {record['round'] - 1} prior "
                   f"trusted round(s) but found {found}; refusing to post (already recorded or "
                   "history changed)"]

    fd, tmp_path = tempfile.mkstemp(prefix="review-round-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(body)
        post_comment(owner_repo, pr, tmp_path, runner=runner)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
    return 0, None


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)

    read_p = sub.add_parser("read", help="read the round ledger for a PR")
    read_p.add_argument("--repo", required=True, help="OWNER/REPO")
    read_p.add_argument("--pr", required=True, type=int)
    read_p.add_argument(
        "--trusted-author-id", dest="trusted_author_ids", action="append", type=parse_author_id,
        default=[], metavar="ID",
        help="also trust this GitHub numeric author ID (repeatable; operator is always trusted)",
    )
    read_p.add_argument(
        "--compact", action="store_true",
        help="omit each RED test's command and reason and keep only case names (the workflow's transport view)",
    )

    record_p = sub.add_parser("record", help="validate and post a round record")
    record_p.add_argument("--repo", required=True, help="OWNER/REPO")
    record_p.add_argument("--pr", required=True, type=int)
    record_p.add_argument("--record", required=True, dest="record_file", metavar="FILE")
    record_p.add_argument(
        "--trusted-author-id", dest="trusted_author_ids", action="append", type=parse_author_id,
        default=[], metavar="ID", help="the same extra trusted IDs the captured read used",
    )

    confirm_p = sub.add_parser("confirm", help="compare trusted history with a captured ledger and pending record")
    confirm_p.add_argument("--repo", required=True, help="OWNER/REPO")
    confirm_p.add_argument("--pr", required=True, type=int)
    confirm_p.add_argument("--ledger", required=True, dest="ledger_file", metavar="FILE",
                           help="the `read --compact` output the round was scored on")
    confirm_p.add_argument("--record", required=True, dest="record_file", metavar="FILE")
    confirm_p.add_argument(
        "--trusted-author-id", dest="trusted_author_ids", action="append", type=parse_author_id,
        default=[], metavar="ID", help="the same extra trusted IDs the captured read used",
    )

    return ap


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "read":
        try:
            result = read_rounds(args.repo, args.pr, trusted_author_ids=args.trusted_author_ids)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        if args.compact:
            result = compact_ledger(result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    if args.command == "record":
        path = Path(args.record_file)
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"--record file {path}: {exc}", file=sys.stderr)
            return 1
        try:
            code, errors = record_command(args.repo, args.pr, record,
                                         trusted_author_ids=args.trusted_author_ids)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        if errors:
            for e in errors:
                print(e, file=sys.stderr)
            return 1
        return code

    if args.command == "confirm":
        try:
            captured = json.loads(Path(args.ledger_file).read_text(encoding="utf-8"))
            record = json.loads(Path(args.record_file).read_text(encoding="utf-8"))
            outcome = confirm_round(args.repo, args.pr, captured, record,
                                    trusted_author_ids=args.trusted_author_ids)
        except (OSError, json.JSONDecodeError, RuntimeError) as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(json.dumps(outcome, indent=2, sort_keys=True))
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main())
