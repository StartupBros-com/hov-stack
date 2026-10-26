#!/usr/bin/env bash
# needs-human.sh: files the escalation artifact R7 requires for a `needs
# input:` exit -- a gh issue labeled `needs-human`, citing a category from the
# CLOSED table at escalation-exceptions.json (KD4/R8), and referencing the
# gated PR. Prints the artifact URL on success.
#
# Usage: needs-human.sh --category <id> --pr <number> [--repo owner/name] --reason "<text>"
#
# The category table is closed: agents cite a category, they never add one.
# An unknown id is rejected before any gh call is made (not just before the
# issue-create call) -- this is the closed-table guarantee, and it must not
# depend on gh being reachable to hold.
#
# --repo defaults to the current directory's origin remote, resolved via
# gh-repo-helpers.sh's owner_repo_of() (the same helper wt-new.sh uses)
# -- pass --repo explicitly when running outside the
# target repo's checkout.
#
# A category whose table entry carries `proof` may be filed only after this
# script confirms the condition itself (dotfiles#1418). No category is
# proof-gated today: review-gate-exhausted, the one that was, retired on
# 2026-10-05 (operator ruling 2026-10-04: no person decides a stopped review
# gate; an owned PR merges or parks at the stop by itself, pr-owner.sh
# merge_at_stop). A `proof` this script does not implement refuses.
#
# Exit codes: 0 success (issue read back OPEN and labeled needs-human), 1
# precondition/gh failure (unknown category, gh unauthenticated, issue create
# failed, or the post-create read-back failed or came back closed/unlabeled --
# dotfiles#1202, pstack vet 2026-09-18), 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/gh-repo-helpers.sh"

TABLE="$HERE/escalation-exceptions.json"

usage() {
  echo 'usage: needs-human.sh --category <id> --pr <number> [--repo owner/name] --reason "<text>"' >&2
  exit 2
}

CATEGORY="" PR="" REPO_ARG="" REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --category) CATEGORY="${2:?--category needs an id}"; shift 2 ;;
    --pr)       PR="${2:?--pr needs a number}"; shift 2 ;;
    --repo)     REPO_ARG="${2:?--repo needs owner/name}"; shift 2 ;;
    --reason)   REASON="${2:?--reason needs text}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$CATEGORY" ] && [ -n "$PR" ] && [ -n "$REASON" ] || usage
case "$PR" in *[!0-9]*) echo "--pr must be a PR number, got: $PR" >&2; usage ;; esac

command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "escalation table not found: $TABLE" >&2; exit 1; }

# Closed-table guard (KD4): validated before ANY gh invocation, including
# `gh auth status`, so an unknown category can never be blamed on gh being
# unreachable and can never reach the issue-create call either.
LABEL_TEXT=$(jq -r --arg id "$CATEGORY" \
  '.categories[] | select(.id == $id) | .label' "$TABLE" 2>/dev/null)
[ -n "$LABEL_TEXT" ] || {
  echo "unknown escalation category: $CATEGORY (closed table -- see $TABLE; new categories require operator sign-off, agents cite a category and never add one)" >&2
  exit 1
}

# Resolved before any gh call: owner_repo_of() reads the git remote, not gh.
if [ -n "$REPO_ARG" ]; then
  OWNER_REPO="$REPO_ARG"
else
  OWNER_REPO="$(owner_repo_of "$PWD")"
  [ -n "$OWNER_REPO" ] || { echo "no origin remote in $PWD; pass --repo owner/name" >&2; exit 1; }
fi

# A `proof` this script does not implement refuses before any gh call, for
# the same reason the closed-table guard does: a gate that cannot check must
# not pass, and a refusal must never be mistaken for gh being unreachable.
PROOF=$(jq -r --arg id "$CATEGORY" \
  '.categories[] | select(.id == $id) | .proof // empty' "$TABLE" 2>/dev/null)
if [ -n "$PROOF" ]; then
  echo "unknown proof kind '$PROOF' on category $CATEGORY in $TABLE; refusing to file" >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "gh not found on PATH" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || {
  echo "gh is unauthenticated or unavailable (gh auth status failed); refusing to claim success without a filed issue" >&2
  exit 1
}

# Best-effort, idempotent: an already-existing label is not an error (wt-new.sh's
# `gh label create ... || true` idiom -- no shared helper exists for this yet).
gh label create needs-human --repo "$OWNER_REPO" --color B60205 \
  --description "escalation requiring operator sign-off; see scripts/needs-human.sh" 2>/dev/null || true

BODY="Category: ${CATEGORY} (${LABEL_TEXT})
Gated PR: #${PR}

${REASON}

Filed by needs-human.sh. Per R7, a \`needs input:\` exit is valid only while
this issue stays open and continues to reference the gated PR above."

ISSUE_URL=$(gh issue create --repo "$OWNER_REPO" \
  --title "needs-human: ${LABEL_TEXT} (PR #${PR})" \
  --label needs-human \
  --body "$BODY") || { echo "gh issue create failed" >&2; exit 1; }

# Read the issue back rather than trusting the create call's own report: a
# `needs input:` exit must never be claimed for an issue that did not actually
# land open and labeled (dotfiles#1202, pstack vet 2026-09-18). One retry
# absorbs a transient gh/API hiccup; never delete or re-create the issue on
# failure here -- report the URL and the mismatch, and exit 1, so the caller
# never treats the escalation as filed.
VIEW_JSON=$(gh issue view "$ISSUE_URL" --json state,labels 2>/dev/null)
VIEW_RC=$?
if [ "$VIEW_RC" -ne 0 ]; then
  sleep 2
  VIEW_JSON=$(gh issue view "$ISSUE_URL" --json state,labels 2>/dev/null)
  VIEW_RC=$?
fi
if [ "$VIEW_RC" -ne 0 ]; then
  echo "$ISSUE_URL" >&2
  echo "needs-human read-back failed: gh issue view exited $VIEW_RC after one retry" >&2
  exit 1
fi

STATE=$(printf '%s' "$VIEW_JSON" | jq -r '.state // empty' 2>/dev/null)
HAS_LABEL=$(printf '%s' "$VIEW_JSON" | jq -r 'any(.labels[]?; .name == "needs-human")' 2>/dev/null)
if [ "$STATE" != "OPEN" ] || [ "$HAS_LABEL" != "true" ]; then
  echo "$ISSUE_URL" >&2
  echo "needs-human read-back mismatch: state=${STATE:-<unreadable>} has-needs-human-label=${HAS_LABEL:-<unreadable>}" >&2
  exit 1
fi

echo "$ISSUE_URL"
exit 0
