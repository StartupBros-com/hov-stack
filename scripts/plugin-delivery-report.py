#!/usr/bin/env python3
"""Which marketplace cards ship files that no release has reached yet.

A change under plugins/<name>/ that merges without a plugins/<name>/VERSION
change is merged, not released: the release workflow fires only on a VERSION
change, and a card's `sha` moves only when a release repins it. So an install
keeps the pinned tree while main moves on. #612 and #635 fixed shipped files of
four plugins that way, CI and the post-merge receipt were green, and no install
changed (#645).

For every card in .claude-plugin/marketplace.json this compares the card's
plugin directory at its pinned commit with the same directory at the compared
ref, using this checkout's git. A card is AHEAD when a shipped file differs:
any file except README.md, CHANGELOG.md and files under a tests, test, docs or
fixtures directory. A card is UNKNOWN when it cannot be compared: it is not a
git-subdir pin into this repository, its pin is not a full commit id, not in
this checkout or not an ancestor of the ref, or its path is missing at the pin.

Both AHEAD and UNKNOWN print a line starting with WARN, so harness-weekly's
`grep -c '^WARN'` counts them. It reports and never fails a merge: some
differences are deliberate (hov-stack's install-release.sh is refreshed on main
without a bump by release-pins-refresh.yml), and whether to release is the
plugin owner's call. A matching tree says the pin carries main's files; it does
not say any host has installed that pin.

Exit codes: 0 every card current, 1 a card is ahead, 2 a card or the manifest
could not be compared (2 wins over 1).

Usage: plugin-delivery-report.py [--repo DIR] [--ref REF]
  --repo  checkout to read (default: the checkout this file lives in)
  --ref   what to compare the pins against (default: origin/main when it
          resolves, else HEAD)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

MANIFEST = ".claude-plugin/marketplace.json"
NOT_SHIPPED_DIRS = frozenset({"tests", "test", "docs", "fixtures"})
NOT_SHIPPED_FILES = frozenset({"README.md", "CHANGELOG.md"})
FULL_SHA = re.compile(r"[0-9a-f]{40}")
COMMITS_SHOWN = 8


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)


def repo_key(url: str) -> str:
    """host/owner/name, lowercased, for an https, ssh or scp-style git URL."""
    u = url.strip().lower()
    u = re.sub(r"^[a-z+]+://", "", u)
    u = re.sub(r"^[^@/]+@", "", u)
    u = re.sub(r"^([^/:]+):(?!\d+/)", r"\1/", u)
    u = re.sub(r"^([^/:]+):\d+/", r"\1/", u)
    return u.rstrip("/").removesuffix(".git")


def shipped(rel: str) -> bool:
    parts = PurePosixPath(rel).parts
    if parts[-1] in NOT_SHIPPED_FILES:
        return False
    return not any(p in NOT_SHIPPED_DIRS for p in parts[:-1])


def default_ref(repo: Path) -> str:
    return "origin/main" if git(repo, "rev-parse", "-q", "--verify", "origin/main^{commit}").returncode == 0 else "HEAD"


def compare_card(repo: Path, ref: str, here: str | None, card) -> tuple[str, list[str]]:
    """('current' | 'ahead' | 'unknown', detail lines) for one card."""
    if not isinstance(card, dict):
        return "unknown", ["the card is not an object"]
    src = card.get("source")
    if not isinstance(src, dict) or src.get("source") != "git-subdir":
        return "unknown", ["the card is not a git-subdir pin, so this checkout cannot answer for it"]
    url, path, sha = src.get("url"), src.get("path"), src.get("sha")
    if not isinstance(url, str) or here is None or repo_key(url) != here:
        return "unknown", [f"the card pins another repository ({url!r}), so this checkout cannot answer for it"]
    if (not isinstance(path, str) or not path or path.startswith("/")
            or ".." in PurePosixPath(path).parts):
        return "unknown", [f"the card's path {path!r} is not a relative path inside this repository"]
    if not isinstance(sha, str) or not FULL_SHA.fullmatch(sha):
        return "unknown", [f"the card's sha {sha!r} is not a full commit id"]
    if git(repo, "cat-file", "-e", f"{sha}^{{commit}}").returncode != 0:
        return "unknown", [f"the pin {sha[:8]} is not in this checkout (fetch it, or the card names a commit this repository never had)"]
    if git(repo, "merge-base", "--is-ancestor", sha, ref).returncode != 0:
        return "unknown", [f"the pin {sha[:8]} is not an ancestor of {ref}, so there is no forward diff to read"]
    if git(repo, "cat-file", "-e", f"{sha}:{path}").returncode != 0:
        return "unknown", [f"{path} does not exist at the pin {sha[:8]}"]
    diff = git(repo, "diff", "--no-renames", "--name-only", sha, ref, "--", f"{path}/")
    if diff.returncode != 0:
        return "unknown", [f"git diff {sha[:8]} {ref} failed: {diff.stderr.strip()}"]
    prefix = path.rstrip("/") + "/"
    files = sorted(f[len(prefix):] for f in diff.stdout.splitlines() if f.startswith(prefix))
    ahead = [f for f in files if shipped(f)]
    if not ahead:
        return "current", []
    log = git(repo, "log", "--no-merges", "--format=%h %s", f"{sha}..{ref}", "--",
              *(prefix + f for f in ahead))
    commits = log.stdout.splitlines() if log.returncode == 0 else []
    lines = [f"  {f}" for f in ahead]
    if commits:
        lines.append("  commits since the pin that touch them:")
        lines += [f"    {c}" for c in commits[:COMMITS_SHOWN]]
        if len(commits) > COMMITS_SHOWN:
            lines.append(f"    and {len(commits) - COMMITS_SHOWN} more")
    return "ahead", lines


def report(repo: Path, ref: str, out=sys.stdout) -> int:
    rev = git(repo, "rev-parse", "-q", "--verify", f"{ref}^{{commit}}")
    if rev.returncode != 0:
        print(f"WARN plugin delivery: UNKNOWN for every card: {ref} does not resolve in {repo}", file=out)
        return 2
    show = git(repo, "show", f"{ref}:{MANIFEST}")
    try:
        cards = json.loads(show.stdout)["plugins"] if show.returncode == 0 else None
    except (ValueError, KeyError, TypeError):
        cards = None
    if not isinstance(cards, list) or not cards:
        print(f"WARN plugin delivery: UNKNOWN for every card: cannot read a plugins list from {MANIFEST} at {ref}", file=out)
        return 2
    origin = git(repo, "remote", "get-url", "origin")
    here = repo_key(origin.stdout) if origin.returncode == 0 and origin.stdout.strip() else None
    print(f"plugin delivery: {len(cards)} cards against {ref} ({rev.stdout.strip()[:8]})", file=out)
    counts = {"current": 0, "ahead": 0, "unknown": 0}
    for i, card in enumerate(cards):
        name = card.get("name") if isinstance(card, dict) else None
        label = name if isinstance(name, str) and name else f"card {i + 1}"
        state, lines = compare_card(repo, ref, here, card)
        counts[state] += 1
        if state == "ahead":
            pin = card["source"]["sha"][:8]
            print(f"WARN plugin delivery: {label} ships files that changed since its pin {pin} "
                  "(merged, not released):", file=out)
            for line in lines:
                print(line, file=out)
        elif state == "unknown":
            print(f"WARN plugin delivery: UNKNOWN for {label}: {lines[0]}", file=out)
    print(f"plugin delivery: {counts['current']} current, {counts['ahead']} ahead of their pin, "
          f"{counts['unknown']} could not be compared", file=out)
    if counts["unknown"]:
        return 2
    return 1 if counts["ahead"] else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--ref")
    args = ap.parse_args(argv)
    return report(args.repo, args.ref or default_ref(args.repo))


if __name__ == "__main__":
    sys.exit(main())
