#!/usr/bin/env python3
"""Read-only ordinary-prose exemption: trusted semantic round AND full git diff.

Exit 0 means exempt; 1 means required/uncertain; 2 means usage/operational error.
The sibling review-rounds.py is trusted installed code, never code from --tree.
Path exclusions only reject known operational surfaces; the existing lenses'
consumer inspection must establish ordinary prose, including custom repo roles.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location("review_rounds", Path(__file__).with_name("review-rounds.py"))
rounds = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rounds)
HEX40 = re.compile(r"[0-9a-f]{40}")
# Match Collect's CANONICAL_DIFF in review-adversarial-first.js exactly. git()
# supplies --no-replace-objects; hash these bytes, never a patch-id or a raw list.
CANONICAL_PATCH_ARGS = (
    "-c",
    "core.quotePath=true",
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-renames",
    "--ignore-submodules=none",
    "--full-index",
    "--binary",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    "--no-relative",
    "--patch",
    "--diff-algorithm=myers",
    "--no-indent-heuristic",
    "--unified=3",
    "--inter-hunk-context=0",
    "--submodule=short",
    "--output-indicator-new=+",
    "--output-indicator-old=-",
    "--output-indicator-context= ",
    "--line-prefix=",
    "-O/dev/null",
)
OPERATIONAL = re.compile(
    r"(^|[-_.])(skills?|agents?|commands?|workflows?|prompts?|memory|memories|tests?|fixtures?|"
    r"security|credentials?|secrets?|permissions?|guards?|config|configuration|instructions?|doctrine)([-_.]|$)",
    re.IGNORECASE,
)


class Required(Exception):
    """Evidence is absent, incomplete or not eligible."""


def git(tree, *args):
    # No replacement objects or lazy fetching: only locally available real objects.
    p = subprocess.run(["git", "--no-replace-objects", "-C", str(tree), *args],
                       env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}, capture_output=True)
    if p.returncode:
        raise Required("git evidence unavailable: " + p.stderr.decode("utf-8", "replace").strip()[:300])
    return p.stdout


def metadata(repo, pr):
    p = subprocess.run(["gh", "api", f"repos/{repo}/pulls/{pr}"], capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError("PR metadata read failed: " + p.stderr.strip()[:300])
    try:
        return json.loads(p.stdout)
    except ValueError as exc:
        raise Required("invalid PR metadata JSON") from exc


def revisions(meta, repo, pr):
    if not isinstance(meta, dict) or meta.get("number") != pr or meta.get("state") != "open":
        raise Required("missing or mismatched open PR identity")
    shas = []
    ids = []
    for side in ("base", "head"):
        entry = meta.get(side)
        if not isinstance(entry, dict) or not isinstance(entry.get("repo"), dict):
            raise Required("missing PR repository identity")
        sha = entry.get("sha")
        if not isinstance(sha, str) or not HEX40.fullmatch(sha):
            raise Required("missing or invalid PR revision")
        full_name = entry["repo"].get("full_name")
        if not isinstance(full_name, str) or full_name.lower() != repo.lower():
            raise Required("PR repository identity differs from requested repository")
        rid = entry["repo"].get("id")
        if not isinstance(rid, int) or isinstance(rid, bool) or rid <= 0:
            raise Required("missing PR numeric repository identity")
        shas.append(sha)
        ids.append(rid)
    if ids[0] != ids[1]:
        raise Required("PR head/base repositories differ")
    return tuple(shas)


def prose_path(raw):
    try:
        path = raw.decode("utf-8")
    except UnicodeError:
        return False
    parts = path.split("/")
    return (bool(path) and path.lower().endswith(".md")
            and all(part and not part.startswith(".") and not OPERATIONAL.search(part) for part in parts)
            and parts[-1].lower() not in {"claude.md", "agents.md", "harness.md", "skill.md"}
            and "harness/" not in path.lower())


def mechanical(tree, repo, base, head):
    remote = git(tree, "remote", "get-url", "origin").decode().strip()
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?/?", remote)
    if not match or match[1].lower() != repo.lower():
        raise Required("local origin does not identify requested repository")
    if git(tree, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise Required("shallow repository cannot prove complete PR diff")
    for sha in (base, head):
        if git(tree, "cat-file", "-t", sha).strip() != b"commit":
            raise Required("PR revision is not a local commit")
    if len(git(tree, "merge-base", "--all", base, head).splitlines()) != 1:
        raise Required("PR has no unique merge base")
    raw = git(
        tree,
        "diff",
        "--raw",
        "-z",
        "--no-abbrev",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
        "--ignore-submodules=none",
        "--no-relative",
        base + "..." + head,
        "--",
    )
    if not raw or not raw.endswith(b"\0"):
        raise Required("empty or incomplete PR diff")
    fields = raw[:-1].split(b"\0")
    if len(fields) % 2:
        raise Required("incomplete raw diff entries")
    for header, path in zip(fields[::2], fields[1::2]):
        match = re.fullmatch(rb":([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMD])", header)
        if not match or not prose_path(path):
            raise Required("non-prose or unknown changed path/status")
        oldmode, newmode, oldoid, newoid, status = match.groups()
        sides = [(oldmode, oldoid), (newmode, newoid)]
        absent = (b"000000", b"0" * 40)
        if ((status == b"A" and sides[0] != absent) or (status == b"D" and sides[1] != absent)
                or (status == b"M" and absent in sides)):
            raise Required("inconsistent raw diff status/modes")
        for index, (mode, oid) in enumerate(sides):
            if (status == b"A" and index == 0) or (status == b"D" and index == 1):
                continue
            if mode != b"100644" or oid == b"0" * 40:
                raise Required("changed side is not regular non-executable prose")
            content = git(tree, "cat-file", "blob", oid.decode("ascii"))
            if b"\0" in content:
                raise Required("binary Markdown is not prose")
            try:
                content.decode("utf-8")
            except UnicodeError as exc:
                raise Required("unknown Markdown encoding") from exc


def assess(args, result):
    base, head = revisions(metadata(args.repo, args.pr), args.repo, args.pr)
    result.update(base=base, head=head)
    if args.head and args.head != head:
        raise Required("CI-validated head differs from current PR head")
    ledger = rounds.read_rounds(args.repo, args.pr)
    history = ledger["rounds"]
    if ledger["ledger_errors"] or not history:
        raise Required("missing or invalid trusted review history")
    if any(entry["record"]["round"] != entry["round"] or entry["record"]["ledger_errors"] for entry in history):
        raise Required("incomplete trusted review history")
    record = history[-1]["record"]
    prose = record.get("ordinary_prose")
    if (record["head"] != head or record["verdict"] != "CLEAN" or record["underlying_verdict"] != "CLEAN"
            or record["override"] or record["live"]["P1"] or record["live"]["P2"]
            or not prose or prose["base"] != base or prose["head"] != head):
        raise Required("latest trusted round lacks current CLEAN ordinary-prose attestation")
    mechanical(args.tree, args.repo, base, head)
    patch = git(args.tree, *CANONICAL_PATCH_ARGS, base + "..." + head, "--")
    if hashlib.sha256(patch).hexdigest() != prose["patch_sha256"]:
        raise Required("reviewed patch SHA-256 differs from canonical PR patch")
    if revisions(metadata(args.repo, args.pr), args.repo, args.pr) != (base, head):
        raise Required("PR revisions changed during evidence collection")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", required=True, type=Path)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--head")
    args = parser.parse_args(argv)
    if (args.pr <= 0 or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo)
            or (args.head is not None and not HEX40.fullmatch(args.head))):
        parser.error("require OWNER/REPO, positive PR and optional lowercase 40-hex head")
    result = {"status": "required", "reason": "", "repo": args.repo, "pr": args.pr}
    code = 1
    try:
        assess(args, result)
    except Required as exc:
        result["reason"] = str(exc)
    except (RuntimeError, OSError, ValueError) as exc:
        result["reason"] = "evidence read failed: " + str(exc)
        print(result["reason"], file=sys.stderr)
        code = 2
    else:
        result.update(status="exempt", reason="current trusted CLEAN semantic attestation and full regular-prose diff")
        code = 0
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
