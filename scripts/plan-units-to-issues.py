#!/usr/bin/env python3
"""File one GitHub issue per implementation unit, then add native blockers.

Usage: plan-units-to-issues.py PLAN.md --parent NUMBER [--repo OWNER/NAME]
                             [--label NAME ...] [--dry-run] [--json]

Units start at ``### U<n>. Title`` and end at the next level-two or
level-three heading, or EOF. Deeper headings stay in the section; headings
and dependency lines inside fenced code are ignored. Each unit must have
one ``**Dependencies:**`` line (plain ``Dependencies:`` also works).
Leading ``none`` means no blockers, even when its rationale mentions units;
otherwise distinct U<n> tokens on that line name dependencies. Section text
is preserved verbatim. Duplicate/malformed units, unclosed fences, missing
units, and cycles are rejected before any gh call. The type prefix comes
from ``[YYYY-MM-DD-[HHMM-]]<type>-...md`` in the filename.

The plan's nearest enclosing .git checkout supplies the repo-relative path
and the cwd for default ``gh repo view --json nameWithOwner`` discovery.
Open AND closed issues are reused when their body carries this parent's
``Part of #N`` line and this plan's ``Plan:`` line: another plan under the
same parent may reuse unit names, so parent and unit alone never identify an
issue. Native edges require gh >= 2.94.0, as in wt-new.sh; existing edges
are read before any creation. Rerun after a partial failure to reuse issues
already filed.

Dry-run makes no subprocess calls. Its table/commands assume no existing
issues; <U<n>-number> and <plan-checkout-repo> stand for remote values that
cannot be known offline. Printed /tmp body previews are removed on exit.
With --json the mapping alone goes to stdout (dry-run numbers/URLs are
null and blocked_by contains unit IDs; its preview goes to stderr).
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO
from urllib.parse import urlsplit

MIN_GH = (2, 94, 0)
HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
UNIT = re.compile(r"(U\d+)\.[ \t]+(\S.*)")
DEPENDENCIES = re.compile(r"^(?:\*\*Dependencies:\*\*|Dependencies:)[ \t]*(.*)$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


class FilingError(Exception):
    """An invalid plan or failed/incomplete GitHub operation."""


@dataclass(frozen=True)
class Unit:
    name: str
    title: str
    section: str
    dependencies: tuple[str, ...]


def parse_plan(text: str) -> list[Unit]:
    units: list[Unit] = []
    current: tuple[str, str, int] | None = None
    dependency_lines: list[str] = []
    fence = ""
    offset = 0

    def finish(end: int) -> None:
        if current is None:
            return
        name, title, start = current
        if len(dependency_lines) != 1:
            raise FilingError(f"{name}: expected exactly one Dependencies line")
        rationale = dependency_lines[0]
        deps = (
            ()
            if re.match(r"none\b", rationale, re.IGNORECASE)
            else tuple(dict.fromkeys(re.findall(r"\bU\d+\b", rationale)))
        )
        units.append(Unit(name, title, text[start:end], deps))

    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        marker = FENCE.match(content)
        if fence:
            if re.fullmatch(
                r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}[ \t]*",
                content,
            ):
                fence = ""
        elif marker:
            fence = marker[1]
        else:
            heading = HEADING.match(content)
            if heading and len(heading[1]) <= 3:
                if len(heading[1]) == 1 and current:
                    raise FilingError(
                        f"cannot bound {current[0]} section: unexpected level-one heading"
                    )
                finish(offset)
                current = None
                dependency_lines = []
                if len(heading[1]) == 3:
                    match = UNIT.fullmatch(heading[2])
                    if match:
                        if any(unit.name == match[1] for unit in units):
                            raise FilingError(f"duplicate unit {match[1]}")
                        current = (match[1], match[2], offset)
                    elif re.match(r"U\d+\b", heading[2]):
                        raise FilingError(
                            f"cannot bound unit section: expected '### U<n>. Title', got {content!r}"
                        )
            elif current:
                dependency = DEPENDENCIES.match(content)
                if dependency:
                    dependency_lines.append(dependency[1])
        offset += len(line)
    if fence and current:
        raise FilingError(f"cannot bound {current[0]} section: unclosed code fence")
    finish(len(text))
    if not units:
        raise FilingError("no unit sections found (expected '### U<n>. Title')")
    graph = {unit.name: unit.dependencies for unit in units}
    for name, deps in graph.items():
        for dep in deps:
            if dep not in graph:
                raise FilingError(f"{name}: dependency {dep} names an absent unit")
    visited: set[str] = set()
    visiting: list[str] = []

    def visit(name: str) -> None:
        if name in visiting:
            raise FilingError("dependency cycle: " + " -> ".join(visiting + [name]))
        if name in visited:
            return
        visiting.append(name)
        for dep in graph[name]:
            visit(dep)
        visiting.pop()
        visited.add(name)

    for name in graph:
        visit(name)
    return units


def checkout_root(plan: Path) -> Path:
    for candidate in plan.parents:
        if (candidate / ".git").exists():
            return candidate
    raise FilingError(f"plan is outside a Git checkout: {plan}")


def gh(cwd: Path, *args: str) -> str:
    command = ["gh", *args]
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise FilingError(
            f"{shlex.join(command)} failed: {result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout.strip()


def gh_json(cwd: Path, *args: str) -> object:
    try:
        return json.loads(gh(cwd, *args))
    except json.JSONDecodeError as exc:
        raise FilingError(f"gh {shlex.join(args)} returned invalid JSON") from exc


def require_gh_version(cwd: Path) -> None:
    output = gh(cwd, "--version")
    match = re.search(r"\bgh version v?(\d+)\.(\d+)\.(\d+)\b", output)
    if not match or tuple(map(int, match.groups())) < MIN_GH:
        raise FilingError(
            f"native dependency edges need gh >= 2.94.0 (detected: {output}); nothing was filed"
        )


def resolve_repo(cwd: Path, repo: str | None) -> str:
    command = ["repo", "view"]
    if repo is not None:
        command.append(repo)
    payload = gh_json(cwd, *command, "--json", "nameWithOwner")
    canonical = payload.get("nameWithOwner") if isinstance(payload, dict) else None
    if not isinstance(canonical, str) or not re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", canonical
    ):
        raise FilingError("gh repo view returned no valid nameWithOwner")
    return canonical


def issue_number(value: object) -> int:
    if type(value) is not int or value <= 0:
        raise FilingError(f"gh returned an invalid issue number: {value!r}")
    return value


def existing_issues(
    cwd: Path, repo: str, parent: int, plan_path: str, names: set[str]
) -> dict:
    payload = gh_json(cwd, *list_command(repo, parent))
    if not isinstance(payload, list):
        raise FilingError("gh issue list returned a non-list response")
    if len(payload) >= 200:
        raise FilingError(
            "parent issue search reached the 200-issue limit; refusing to risk duplicate issues"
        )
    # Search can lag successful creates; also read the recent issues directly.
    recent = gh_json(cwd, *list_command(repo))
    if not isinstance(recent, list):
        raise FilingError("gh issue list returned a non-list response")
    # An issue is this plan's unit only when its body carries both lines the
    # create wrote: another plan under the same parent can reuse U<n> names.
    marker = re.compile(rf"(?m)^Part of #{parent}[ \t]*\r?$")
    plan_line = re.compile(rf"(?m)^Plan: {re.escape(plan_path)}[ \t]*\r?$")
    found = {}
    seen = set()
    for item in payload + recent:
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("title"), str)
            or not isinstance(item.get("body"), str)
        ):
            raise FilingError("gh issue list returned an issue without title or body")
        if not marker.search(item["body"]) or not plan_line.search(item["body"]):
            continue
        match = re.match(r"^(?:[^:]+:\s*)?(U\d+)(?:[.\s]|$)", item["title"])
        if match and match[1] in names:
            name = match[1]
            number = issue_number(item.get("number"))
            if number in seen:
                continue
            seen.add(number)
            if name in found:
                raise FilingError(
                    f"multiple existing issues match {name} for parent #{parent}"
                )
            found[name] = {
                "number": number,
                "url": f"https://github.com/{repo}/issues/{number}",
            }
    return found


def blockers(cwd: Path, repo: str, number: int) -> set[int]:
    payload = gh_json(
        cwd, "issue", "view", str(number), "--repo", repo, "--json", "blockedBy"
    )
    if not isinstance(payload, dict) or "blockedBy" not in payload:
        raise FilingError(f"#{number}: gh returned no blockedBy field")
    connection = payload["blockedBy"]
    if isinstance(connection, dict):
        nodes = connection.get("nodes")
        count = connection.get("totalCount")
        if not isinstance(nodes, list) or type(count) is not int or count != len(nodes):
            raise FilingError(
                f"#{number}: incomplete blockedBy response; refusing to guess missing edges"
            )
    elif isinstance(connection, list):
        nodes = connection
    else:
        raise FilingError(f"#{number}: invalid blockedBy response")
    result = set()
    for node in nodes:
        if not isinstance(node, dict):
            raise FilingError(f"#{number}: invalid blockedBy node")
        if (
            node.get("url")
            and urlsplit(node["url"]).path.rsplit("/issues/", 1)[0] != f"/{repo}"
        ):
            continue
        result.add(issue_number(node.get("number")))
    return result


def list_command(repo: str, parent: int | None = None) -> list[str]:
    command = [
        "issue",
        "list",
        "--repo",
        repo,
        "--state",
        "all",
    ]
    if parent is not None:
        command += ["--search", f'"Part of #{parent}" in:body']
    return command + [
        "--json",
        "number,title,body,state" if parent is not None else "number,title,body,url",
        "--limit",
        "200",
    ]


def create_command(repo: str, title: str, labels: list[str], body: Path) -> list[str]:
    command = ["issue", "create", "--repo", repo, "--title", title]
    for label in labels:
        command.extend(["--label", label])
    return command + ["--body-file", str(body)]


def edit_command(repo: str, number: object, dependencies: list) -> list[str]:
    return [
        "issue",
        "edit",
        str(number),
        "--repo",
        repo,
        "--add-blocked-by",
        ",".join(map(str, dependencies)),
    ]


def table(
    units: list[Unit], titles: dict[str, str], mapping: dict, stream: TextIO
) -> None:
    print("unit\ttitle\tissue\tblocked-by", file=stream)
    for unit in units:
        item = mapping[unit.name]
        print(
            f"{unit.name}\t{titles[unit.name]}\t{item['number'] or '(new)'}\t{', '.join(map(str, item['blocked_by'])) or 'none'}",
            file=stream,
        )


def positive_number(value: str) -> int:
    if not value.isascii() or not value.isdecimal() or int(value) <= 0:
        raise argparse.ArgumentTypeError("must be a positive issue number")
    return int(value)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("plan", type=Path)
    parser.add_argument("--parent", required=True, type=positive_number)
    parser.add_argument(
        "--repo", help="OWNER/NAME; default: gh repo view in the plan's checkout"
    )
    parser.add_argument(
        "--label", action="append", help="repeatable; default: plan-unit"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print an offline preview; execute nothing",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print the unit/issue/blocker mapping as JSON",
    )
    args = parser.parse_args()
    try:
        plan = args.plan.resolve(strict=True)
        with plan.open(encoding="utf-8", newline="") as handle:
            units = parse_plan(handle.read())
        match = re.match(r"^(?:\d{4}-\d{2}-\d{2}-(?:\d{4}-)?)?([a-z]+)-", plan.name)
        if not match:
            raise FilingError(
                f"cannot infer type prefix from plan filename: {plan.name}"
            )
        titles = {unit.name: f"{match[1]}: {unit.name} {unit.title}" for unit in units}
        root = checkout_root(plan)
        plan_path = plan.relative_to(root).as_posix()
        repo = args.repo
        if repo and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise FilingError("--repo must be OWNER/NAME")
        mapping = {}
        known_blockers = {}
        if not args.dry_run:
            require_gh_version(root)
            repo = resolve_repo(root, repo)
            mapping = existing_issues(
                root, repo, args.parent, plan_path, {unit.name for unit in units}
            )
            for unit in units:
                if unit.name in mapping and unit.dependencies:
                    known_blockers[unit.name] = blockers(
                        root, repo, mapping[unit.name]["number"]
                    )
        with tempfile.TemporaryDirectory(prefix="plan-units-", dir="/tmp") as scratch:
            commands = {}
            for unit in units:
                body = Path(scratch) / f"{unit.name}.md"
                separator = "\n" if unit.section.endswith("\n") else "\n\n"
                body.write_text(
                    unit.section
                    + separator
                    + f"Part of #{args.parent}\nPlan: {plan_path}\n",
                    encoding="utf-8",
                    newline="",
                )
                commands[unit.name] = create_command(
                    repo or "<plan-checkout-repo>",
                    titles[unit.name],
                    args.label or ["plan-unit"],
                    body,
                )
            if args.dry_run:
                mapping = {
                    unit.name: {
                        "number": None,
                        "url": None,
                        "blocked_by": list(unit.dependencies),
                    }
                    for unit in units
                }
                stream = sys.stderr if args.json else sys.stdout
                table(units, titles, mapping, stream)
                print(
                    "\n# Offline preview: existing issues/edges are unknown; <U<n>-number> is the captured issue number.",
                    file=stream,
                )
                print(
                    "# /tmp body previews are removed on exit. gh commands run from "
                    + str(root),
                    file=stream,
                )
                print("gh --version", file=stream)
                if args.repo is None:
                    print("gh repo view --json nameWithOwner", file=stream)
                print(
                    shlex.join(
                        [
                            "gh",
                            *list_command(repo or "<plan-checkout-repo>", args.parent),
                        ]
                    ),
                    file=stream,
                )
                for unit in units:
                    print(shlex.join(["gh", *commands[unit.name]]), file=stream)
                for unit in units:
                    if unit.dependencies:
                        print(
                            shlex.join(
                                [
                                    "gh",
                                    *edit_command(
                                        repo or "<plan-checkout-repo>",
                                        f"<{unit.name}-number>",
                                        [
                                            f"<{dep}-number>"
                                            for dep in unit.dependencies
                                        ],
                                    ),
                                ]
                            ),
                            file=stream,
                        )
            else:
                for unit in units:
                    if unit.name in mapping:
                        continue
                    url = gh(root, *commands[unit.name])
                    parsed = urlsplit(url)
                    number_match = re.fullmatch(
                        re.escape(f"/{repo}/issues/") + r"([1-9]\d*)", parsed.path
                    )
                    if (
                        parsed.scheme not in {"http", "https"}
                        or not parsed.netloc
                        or not number_match
                    ):
                        raise FilingError(
                            f"gh issue create returned an invalid URL: {url!r}; inspect the parent search before rerunning"
                        )
                    mapping[unit.name] = {"number": int(number_match[1]), "url": url}
                for unit in units:
                    deps = [mapping[dep]["number"] for dep in unit.dependencies]
                    missing = [
                        dep
                        for dep in deps
                        if dep not in known_blockers.get(unit.name, set())
                    ]
                    if missing:
                        gh(
                            root,
                            *edit_command(repo, mapping[unit.name]["number"], missing),
                        )
                    mapping[unit.name]["blocked_by"] = deps
                mapping = {unit.name: mapping[unit.name] for unit in units}
                if not args.json:
                    table(units, titles, mapping, sys.stdout)
            if args.json:
                print(json.dumps(mapping, indent=2))
        return 0
    except (FilingError, OSError, UnicodeError) as exc:
        print(f"plan-units-to-issues: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
