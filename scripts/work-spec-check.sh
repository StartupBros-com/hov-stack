#!/usr/bin/env bash
# work-spec-check.sh: refuse a work-spec issue body that is missing a required section.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer  — wt-new.sh, immediately before `gh issue create`; also runnable by hand.
#   gate      — work-spec issue creation. Non-zero exit means do not file it.
#   defect    — OBSERVED (dotfiles#173, review finding #6): GitHub issue-form `required:` is
#               enforced ONLY in the web New Issue UI. It is never enforced by
#               `gh issue create --body-file`, which is the path wt-new.sh and therefore
#               every agent takes, so the two required work-spec fields were decorative
#               exactly where they mattered.
#   delete-when — GitHub enforces issue-form validation through the API.
#
# Scope, stated up front: this buys STRUCTURE, NOT SINCERITY. It proves a section exists and
# has something under it. It cannot prove the content is any good, and a lazy one-liner will
# satisfy it. What it removes is the silent case — a required section simply absent, with no
# signal at all. Do not read a pass here as evidence the spec is well written.
#
# The section regex deliberately mirrors verify-seed.sh's extractor, so a body that passes
# here is one verify-seed.sh will actually be able to extract downstream. Keep them in step.
#
# Usage: work-spec-check.sh <body-file>
# Exit:  0 every required section present and non-empty · 1 one or more missing · 2 usage
set -uo pipefail

case "${1:-}" in
  -h|--help) echo 'usage: work-spec-check.sh <body-file>'; exit 0 ;;
esac
[ $# -ge 1 ] || { echo 'usage: work-spec-check.sh <body-file>' >&2; exit 2; }
[ -r "$1" ] || { echo "work-spec-check: cannot read $1" >&2; exit 2; }

WS_BODY="$1" python3 -c '
import os, re, sys

REQUIRED = ("Acceptance Criteria", "Planted negative", "No-Claim Boundary")

body = open(os.environ["WS_BODY"], encoding="utf-8", errors="replace").read()

missing = []
for name in REQUIRED:
    # Same shape as verify-seed.sh section(): a level-2/3 heading, then everything up to the
    # next one. A heading with nothing under it counts as missing - an empty section is the
    # same unstated requirement as no section.
    m = re.search(r"^#{2,3} +" + re.escape(name) + r"[^\n]*\n(.*?)(?=^#{2,3} |\Z)",
                  body, re.M | re.S)
    if not m or not m.group(1).strip():
        missing.append(name)

if missing:
    print("work-spec-check: body is missing required section(s):", file=sys.stderr)
    for name in missing:
        print(f"  - {name}", file=sys.stderr)
    print("", file=sys.stderr)
    print("A work-spec is the contract an implementer works from, so a missing section is an",
          file=sys.stderr)
    print("unstated requirement. Add the heading(s) with real content, or file a quick-capture",
          file=sys.stderr)
    print("issue instead if this work is trivial.", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
'
