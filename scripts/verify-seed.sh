#!/usr/bin/env bash
# verify-seed.sh: seed the worktree's Definition-of-Done scratch file from a gh
# issue's Acceptance Criteria. Run once right after opening a worktree for
# issue-linked work (wt-new.sh --issue N && cd <wt> && verify-seed.sh N).
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer  — the implementing agent, reading .claude/scratch/VERIFY.md as its
#               Definition of Done while it works.
#   gate      — implementation. The issue's Acceptance Criteria, planted negative,
#               and No-Claim Boundary reach the worktree verbatim, or the
#               implementer proceeds with no contract in front of it.
#   defect    — OBSERVED: claims drifting from what was actually verified —
#               memory/fix-first-merge-premise-verification.md (merging on "the
#               PRs that passed review" when the PR body's claim was stale). The
#               contract has to sit in front of the implementer during the work,
#               not only in the tracker it was written into.
#   delete-when — the tracker renders the Definition of Done into the worktree
#               itself, or the VERIFY.md/NOTES.md scratch pair is retired.
#
# Scratch pair (.claude/scratch/VERIFY.md + NOTES.md) is globally gitignored;
# check items off during implementation, append rejected approaches to NOTES.md,
# and fold both into the PR body (Definition of Done / Rejected approaches
# sections) before the worktree is removed, so they survive wt-sweep.sh.
# Mechanism doc: harness/verification-architecture.md.
#
# Usage: verify-seed.sh <issue-number> [--force]
set -uo pipefail

N="${1:?usage: verify-seed.sh <issue-number> [--force]}"
FORCE="${2:-}"
mkdir -p .claude/scratch
if [ -s .claude/scratch/VERIFY.md ] && [ "$FORCE" != "--force" ]; then
  echo "VERIFY.md already exists and is non-empty (use --force to overwrite)" >&2
  exit 1
fi
BODY=$(gh issue view "$N" --json body --jq .body) \
  || { echo "could not fetch issue #$N (gh auth? wrong repo?)" >&2; exit 1; }
section() { # section <heading-regex>
  printf '%s\n' "$BODY" | HEAD_RE="$1" python3 -c '
import os, re, sys
text = sys.stdin.read()
m = re.search(r"^#{2,3} " + os.environ["HEAD_RE"] + r"[^\n]*\n(.*?)(?=^#{2,3} |\Z)",
              text, re.M | re.S)
print(m.group(1).strip() if m else "")
'
}
SECTION=$(section "Acceptance Criteria")
# The No-Claim Boundary is written before implementation precisely so it is in front of the
# implementer during it; carrying it into VERIFY.md is the whole point of writing it early.
NOCLAIM=$(section "No-Claim Boundary")
PLANTED=$(section "Planted negative")
{
  echo "<!-- seeded from issue #$N by verify-seed.sh; gitignored, do not commit -->"
  echo "# Definition of Done (issue #$N)"
  echo
  if [ -n "$SECTION" ]; then
    printf '%s\n' "$SECTION"
  else
    echo "- [ ] (no Acceptance Criteria section found on issue #$N; write the DoD here before starting)"
  fi
  if [ -n "$PLANTED" ]; then
    echo; echo "## Planted negatives (must FAIL before the fix, PASS after)"; echo
    printf '%s\n' "$PLANTED"
  fi
  echo; echo "## No-Claim Boundary — what green here will NOT prove"; echo
  if [ -n "$NOCLAIM" ]; then
    printf '%s\n' "$NOCLAIM"
  else
    echo "(none on issue #$N; write it BEFORE implementing — see harness/evidence-regime.md §3)"
  fi
} > .claude/scratch/VERIFY.md
if [ ! -f .claude/scratch/NOTES.md ]; then
  cat > .claude/scratch/NOTES.md <<EOF
# Lab notes (issue #$N)

## Rejected approaches

Outcome comes from this CLOSED set. The definitions live in ONE place —
\`harness/evidence-regime.md\` §5 — because a taxonomy restated in three files drifts,
and this copy already had:

  NEGATIVE(reverted) | NEGATIVE(retained-for-proof) | PROVISIONAL | NO_EVIDENCE | VOID

The one worth repeating at the point of use, because it is the one most often filed wrong:
**VOID** means the measurement COULD NOT have detected the thing (broken harness, dead flag,
wrong arm). It is not a rejection. Filing a VOID as a NEGATIVE invents a false do-not-retry
rule and forecloses a good option. Every entry ends with an explicit predicate. Never "later".

- <approach> -> <OUTCOME> -> Do-not-retry unless: <condition>

EOF
fi
echo "seeded .claude/scratch/VERIFY.md and NOTES.md from issue #$N"
