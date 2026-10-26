#!/usr/bin/env python3
"""Report-only drift check for the beads-to-gh skill sweep (2026-07-22).

Scans a FIXED ALLOWLIST of 8 jsm-managed skills for live beads/br/bv/bd worked
examples the sweep should have replaced with gh equivalents:
  CRITICAL: a fenced code block containing an executable br/bv/bd command with
            no `gh issue|pr` alternative in the same block.
  WARN:     a dead check-skills.sh REFERENCED array entry (beads-workflow/br/bv),
            or a dangling beads-only markdown link (unless the target text says
            Retired/superseded).

Scope is deliberately an allowlist, not an estate-wide scan: 15+ unrelated
skills cite beads_rust as an example/corpus codebase (EXEMPLARS, session
evidence), which is fine and must not be flagged.

Usage: skills-beads-sweep-check.py [--skills-dir PATH] [--json] [--gate]
  --gate  exit 1 if critical_count > 0 (PR completion proof); default exit 0
          so harness-doctor (which parses the JSON) never sees a hard failure.
"""

import argparse
import json
import os
import re
import sys

SCOPE = [
    "codebase-audit",
    "documentation-website-for-software-project",
    "mock-code-finder",
    "saas-billing-patterns-for-stripe-and-paypal",
    "security-audit-for-saas",
    "seo-for-saas-businesses",
    "user-support-triage-for-saas-and-open-source-projects",
    "papers",
]

GH_RE = re.compile(r"\bgh (issue|pr)\b")
CMD_RE = re.compile(
    r"(?:^|[^A-Za-z0-9_-])"
    r"(br (create|ready|list|close|update|dep)"
    r"|bv (--robot|prioritize)"
    r"|bd (onboard|ready|show|update|close|sync))"
    r"(?:[^A-Za-z0-9_-]|$)"
)
ARRAY_OPEN_RE = re.compile(r"(REFERENCED_SKILLS|REFERENCED)\s*=\s*\(")
LINK_RE = re.compile(r"\]\(([^)]*beads[^)]*)\)", re.IGNORECASE)
SUPPRESS_RE = re.compile(r"retired|superseded", re.IGNORECASE)


def scan_file(path):
    findings = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return findings

    in_fence = False
    fence_buf = []  # (lineno, text)
    fence_has_gh = False
    in_array = False
    is_check_skills = os.path.basename(path) == "check-skills.sh"

    def flush_fence():
        nonlocal fence_buf, fence_has_gh
        if not fence_has_gh:
            for ln, text in fence_buf:
                if CMD_RE.search(text):
                    findings.append(
                        {"severity": "CRITICAL", "line": ln, "text": text.strip()}
                    )
        fence_buf = []
        fence_has_gh = False

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            if in_fence:
                flush_fence()
                in_fence = False
            else:
                in_fence = True
                fence_buf = []
                fence_has_gh = False
            continue
        if in_fence:
            if GH_RE.search(line):
                fence_has_gh = True
            fence_buf.append((i, line))
            continue
        if is_check_skills:
            if in_array:
                if stripped == ")":
                    in_array = False
                    continue
                bare = stripped.strip("\"'")
                if bare in ("beads-workflow", "br", "bv"):
                    findings.append(
                        {"severity": "WARN", "line": i, "text": stripped}
                    )
                continue
            if ARRAY_OPEN_RE.search(line):
                in_array = True
                continue
        m = LINK_RE.search(line)
        if m and not SUPPRESS_RE.search(line):
            findings.append({"severity": "WARN", "line": i, "text": stripped})
    if in_fence:
        flush_fence()
    return findings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--skills-dir",
        default=os.environ.get(
            "CLAUDE_SKILLS_DIR", os.path.expanduser("~/.claude/skills")
        ),
    )
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--gate", action="store_true")
    args = ap.parse_args()

    files = []
    critical = warn = 0
    for skill in SCOPE:
        skill_dir = os.path.join(args.skills_dir, skill)
        if not os.path.isdir(skill_dir):
            continue
        for root, _dirs, names in os.walk(skill_dir):
            if os.sep + ".trash" + os.sep in root + os.sep:
                continue
            for name in sorted(names):
                if not (name.endswith(".md") or name == "check-skills.sh"):
                    continue
                path = os.path.join(root, name)
                findings = scan_file(path)
                if findings:
                    rel = os.path.relpath(path, args.skills_dir)
                    files.append({"path": rel, "findings": findings})
                    critical += sum(
                        1 for f in findings if f["severity"] == "CRITICAL"
                    )
                    warn += sum(1 for f in findings if f["severity"] == "WARN")

    report = {
        "scope": SCOPE,
        "files": files,
        "critical_count": critical,
        "warn_count": warn,
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(
            f"skills-beads-sweep-check: {critical} CRITICAL, {warn} WARN "
            f"across {len(SCOPE)} scoped skills"
        )
        for entry in files:
            print(f"  {entry['path']}")
            for f in entry["findings"]:
                print(f"    {f['severity']} L{f['line']}: {f['text'][:120]}")
    if args.gate and critical > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
