#!/usr/bin/env python3
"""Load and filter ce-code-review findings for forensic verification.

Usage:
    load-findings.py [run-id]

Discovers the artifact directory (defaulting to the most recently modified run),
aggregates findings across every per-agent JSON file, applies the same confidence
gate ce-code-review uses, drops the categories not worth a forensic pass, dedupes
cross-reviewer flags, and returns structured JSON on stdout.

The script never mutates the artifact directory. It is safe to run repeatedly.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

RUN_ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]+$")
ARTIFACT_ROOT = Path(".context/compound-engineering/ce-code-review")


def die(msg: str, code: int = 1) -> None:
    json.dump({"ok": False, "error": msg}, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(code)


def git(*args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", *args], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def git_is_ancestor(ancestor: str, descendant: str) -> bool:
    try:
        subprocess.check_call(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def sibling_worktrees_with_artifacts() -> list[dict[str, str]]:
    """If cwd has no artifacts, surface any other worktrees that do.

    Uses `git worktree list --porcelain` so this works whether the user lives in
    the main checkout or in a worktree under `.claude/worktrees/`.
    """
    raw = git("worktree", "list", "--porcelain")
    if not raw:
        return []
    cwd = Path.cwd().resolve()
    out: list[dict[str, str]] = []
    path: str | None = None
    branch: str | None = None
    for line in raw.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree ") :].strip()
            branch = None
        elif line.startswith("branch "):
            branch = line[len("branch ") :].strip().removeprefix("refs/heads/")
        elif line == "" and path:
            wt = Path(path)
            if wt.resolve() != cwd and (wt / ARTIFACT_ROOT).is_dir():
                runs = [
                    p for p in (wt / ARTIFACT_ROOT).iterdir()
                    if p.is_dir() and RUN_ID_RE.match(p.name)
                ]
                if runs:
                    latest = max(runs, key=lambda p: p.stat().st_mtime)
                    out.append({
                        "path": str(wt),
                        "branch": branch or "",
                        "latest_run_id": latest.name,
                    })
            path, branch = None, None
    return out


def resolve_run_dir(arg: str | None) -> Path:
    missing_hint = (
        f"No ce-code-review artifacts under {ARTIFACT_ROOT} in current worktree "
        f"({Path.cwd()}). Run /ce-code-review here first, or cd into the worktree "
        "where the review was run."
    )

    def _die_with_siblings(base_msg: str) -> None:
        siblings = sibling_worktrees_with_artifacts()
        payload = {"ok": False, "error": base_msg}
        if siblings:
            payload["sibling_worktrees"] = siblings
            payload["hint"] = (
                "Other worktrees in this repo have review artifacts. "
                "cd into one and re-run, or pass its run-id explicitly."
            )
        json.dump(payload, sys.stdout)
        sys.stdout.write("\n")
        sys.exit(1)

    if not ARTIFACT_ROOT.is_dir():
        _die_with_siblings(missing_hint)
    if arg and arg not in {"latest", "-"}:
        candidate = ARTIFACT_ROOT / arg
        if not candidate.is_dir():
            _die_with_siblings(
                f"Run-id {arg!r} not found under {ARTIFACT_ROOT} in current worktree."
            )
        return candidate
    runs = [
        p
        for p in ARTIFACT_ROOT.iterdir()
        if p.is_dir() and RUN_ID_RE.match(p.name)
    ]
    if not runs:
        _die_with_siblings(f"{ARTIFACT_ROOT} has no run-id subdirectories.")
    runs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return runs[0]


def load_metadata(run_dir: Path) -> dict[str, Any]:
    meta_path = run_dir / "metadata.json"
    if meta_path.is_file():
        try:
            return json.loads(meta_path.read_text())
        except (OSError, json.JSONDecodeError):
            return {}
    return {}


def iter_agent_files(run_dir: Path):
    for path in sorted(run_dir.glob("*.json")):
        if path.name == "metadata.json":
            continue
        try:
            yield path, json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue


def normalize_title(title: str) -> str:
    return re.sub(r"\s+", " ", title.strip().lower())[:80]


def line_bucket(line: Any, window: int = 3) -> int:
    try:
        n = int(line)
    except (TypeError, ValueError):
        return -1
    return n // (window * 2 + 1)


def should_verify(finding: dict[str, Any]) -> bool:
    """Keep only findings worth a forensic pass.

    safe_auto fixes are already applied; advisory is report-only; pre_existing
    is not this session's work; P3 is rarely worth the time. A P0 scraping by
    at 0.50 confidence survives the gate just like ce-code-review does.
    """
    if finding.get("pre_existing"):
        return False
    severity = finding.get("severity")
    if severity not in {"P0", "P1", "P2"}:
        return False
    autofix = finding.get("autofix_class")
    if autofix not in {"gated_auto", "manual"}:
        return False
    confidence = float(finding.get("confidence") or 0.0)
    threshold = 0.50 if severity == "P0" else 0.60
    return confidence >= threshold


def dedupe(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    buckets: dict[tuple, dict[str, Any]] = {}
    for f in findings:
        key = (
            (f.get("file") or "").strip().lower(),
            line_bucket(f.get("line")),
            normalize_title(f.get("title") or ""),
        )
        existing = buckets.get(key)
        if existing is None:
            f["reviewers"] = sorted({f["_reviewer"]})
            buckets[key] = f
            continue
        # Merge: keep highest severity, highest confidence, union reviewers.
        sev_rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
        if sev_rank.get(f["severity"], 9) < sev_rank.get(existing["severity"], 9):
            existing["severity"] = f["severity"]
        if float(f.get("confidence") or 0) > float(existing.get("confidence") or 0):
            existing["confidence"] = f["confidence"]
            existing["why_it_matters"] = f.get("why_it_matters") or existing.get(
                "why_it_matters"
            )
            existing["evidence"] = f.get("evidence") or existing.get("evidence")
            existing["suggested_fix"] = f.get("suggested_fix") or existing.get(
                "suggested_fix"
            )
        existing["reviewers"] = sorted(set(existing["reviewers"]) | {f["_reviewer"]})
    return list(buckets.values())


def main() -> None:
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    run_dir = resolve_run_dir(arg)
    metadata = load_metadata(run_dir)

    raw: list[dict[str, Any]] = []
    reviewer_count = 0
    for path, payload in iter_agent_files(run_dir):
        reviewer_count += 1
        reviewer = payload.get("reviewer") or path.stem
        for finding in payload.get("findings") or []:
            finding["_reviewer"] = reviewer
            raw.append(finding)

    filtered = [f for f in raw if should_verify(f)]
    deduped = dedupe(filtered)
    sev_rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
    deduped.sort(
        key=lambda f: (
            sev_rank.get(f.get("severity"), 9),
            -float(f.get("confidence") or 0),
            f.get("file") or "",
            int(f.get("line") or 0),
        )
    )
    for f in deduped:
        f.pop("_reviewer", None)

    current_branch = git("branch", "--show-current")
    current_head = git("rev-parse", "HEAD")

    drift = None
    if metadata.get("branch") and current_branch and metadata["branch"] != current_branch:
        drift = {
            "kind": "branch",
            "artifact": metadata.get("branch"),
            "current": current_branch,
        }
    elif metadata.get("head_sha") and current_head and metadata["head_sha"] != current_head:
        # Forward progress on the same branch (e.g. autofix commits after the
        # review ran) is not drift — the artifact head is an ancestor of HEAD.
        # True drift is a rebase, reset, or branch switch that makes the
        # artifact head no longer reachable from HEAD.
        if not git_is_ancestor(metadata["head_sha"], current_head):
            drift = {
                "kind": "head_sha",
                "artifact": metadata.get("head_sha"),
                "current": current_head,
            }

    out = {
        "ok": True,
        "run_id": run_dir.name,
        "artifact_dir": str(run_dir),
        "reviewer_count": reviewer_count,
        "counts": {
            "raw": len(raw),
            "after_filter": len(filtered),
            "after_dedup": len(deduped),
        },
        "metadata": metadata,
        "current": {"branch": current_branch, "head_sha": current_head},
        "drift": drift,
        "findings": deduped,
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
