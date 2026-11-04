#!/usr/bin/env bash
set -euo pipefail

# Land the reconciler's repin PR without a human, and close the repin PRs it
# superseded.
#
# The repin PR changes one file, the card pins, to values the reconciler derived
# from the plugins' own releases; its required checks re-validate those pins. A
# human merge added typing, not judgement, and when nobody typed, releases sat as
# drafts. So this asks GitHub to squash-merge the PR once its required checks
# pass, after proving the PR is still exactly what the reconciler produced: the
# marketplace bot opened it from this repository, it changes only the manifest,
# and the manifest at its head is byte-identical to the reconciler's output.
#
# A repin PR from an earlier run is closed once a newer one exists, or once main
# already matches every release. Left open, it either stalls (the required checks
# demand an up-to-date branch) or, rebased by hand, would pin an older release.
#
# The same proof and close loop serve any bot-opened, single-file PR family. LAND_PATH
# names the one file the PR may change, BRANCH_PREFIX the family's branch prefix, and
# REQUEST_AUTO_MERGE=false runs the proof but leaves the merge to the owner. Each
# family closes only PRs under its own prefix, so a pins run never closes a repin PR
# and the reverse.
#
# Usage (from the reconcile workflow, with the marketplace bot's token):
#   DESIRED_BRANCH=repin/auto-<key> EXPECTED_BLOB=<blob sha> release/scripts/repin-land.sh
#   DESIRED_BRANCH= release/scripts/repin-land.sh   # no drift: close every open repin PR
#   LAND_PATH=<file> BRANCH_PREFIX=<prefix> REQUEST_AUTO_MERGE=false \
#     DESIRED_BRANCH=<prefix><key> EXPECTED_BLOB=<blob sha> release/scripts/repin-land.sh
#
# Env:
#   REPO            owner/name of this repository (default: $GITHUB_REPOSITORY)
#   BOT_SLUG        the marketplace bot App's slug (create-github-app-token's app-slug)
#   DESIRED_BRANCH  head branch of this run's repin PR; empty when there is no drift
#   EXPECTED_BLOB   git blob sha of the reconciler's manifest (needed with DESIRED_BRANCH)
#   LAND_PATH       the one file the PR may change (default .claude-plugin/marketplace.json)
#   BRANCH_PREFIX   head-branch prefix of this PR family (default repin/auto-)
#   REQUEST_AUTO_MERGE  true (default) requests auto-merge after the proof; false only
#                   proves the PR and leaves it waiting for the owner to merge it
#   ONLY_PLUGIN     set for a targeted run: its PR covers one plugin, so nothing is closed
#   GH_TOKEN        the marketplace bot's token
#
# Exit codes:
#   0  the PR is queued for auto-merge (or already was, or REQUEST_AUTO_MERGE=false), and superseded PRs are closed
#   1  a read failure, or this run's PR is not provably the reconciler's output

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

LAND_PATH="${LAND_PATH:-.claude-plugin/marketplace.json}"
BRANCH_PREFIX="${BRANCH_PREFIX:-repin/auto-}"
REQUEST_AUTO_MERGE="${REQUEST_AUTO_MERGE:-true}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
BOT_SLUG="${BOT_SLUG:-}"
DESIRED_BRANCH="${DESIRED_BRANCH:-}"
EXPECTED_BLOB="${EXPECTED_BLOB:-}"
ONLY_PLUGIN="${ONLY_PLUGIN:-}"

[ -n "$REPO" ] || fail 'REPO is not set'
[ -n "$BOT_SLUG" ] || fail 'BOT_SLUG is not set'
case "$REQUEST_AUTO_MERGE" in true|false) ;; *) fail "REQUEST_AUTO_MERGE must be true or false, not '$REQUEST_AUTO_MERGE'" ;; esac
[ -n "$BRANCH_PREFIX" ] || fail 'BRANCH_PREFIX is empty'

# Open repin PRs the bot opened from this repository. Same-named branches on a fork
# or PRs by anyone else are not ours to merge or close. gh reports an App author as
# app/<slug> (observed on #205-#207); the REST spelling <slug>[bot] is accepted too,
# since both name the same App account.
open_prs="$(gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,headRefName,headRefOid,author,isCrossRepository,autoMergeRequest 2>/dev/null)" \
  || fail "could not list open pull requests in $REPO"
repins="$(jq -c --arg slug "$BOT_SLUG" --arg prefix "$BRANCH_PREFIX" '
    [ .[] | select((.headRefName | startswith($prefix))
                   and (.author.login == "app/\($slug)" or .author.login == "\($slug)[bot]")
                   and .isCrossRepository == false) ]' <<<"$open_prs")" \
  || fail "could not parse the open pull requests of $REPO"

desired_pr=''
if [ -n "$DESIRED_BRANCH" ]; then
  [ -n "$EXPECTED_BLOB" ] || fail 'EXPECTED_BLOB is required with DESIRED_BRANCH'
  pr="$(jq -c --arg b "$DESIRED_BRANCH" '[ .[] | select(.headRefName == $b) ] | first // empty' <<<"$repins")"
  [ -n "$pr" ] || fail "no open repin PR by app/$BOT_SLUG for $DESIRED_BRANCH"
  desired_pr="$(jq -r '.number' <<<"$pr")"
  head="$(jq -r '.headRefOid' <<<"$pr")"

  files="$(gh pr view "$desired_pr" --repo "$REPO" --json files --jq '[.files[].path] | join(",")' 2>/dev/null)" \
    || fail "could not read the files of #$desired_pr"
  [ "$files" = "$LAND_PATH" ] \
    || fail "#$desired_pr changes more than $LAND_PATH ($files); not requesting auto-merge"
  blob="$(gh api "repos/$REPO/contents/$LAND_PATH?ref=$head" --jq '.sha' 2>/dev/null)" \
    || fail "could not read $LAND_PATH at ${head:0:12}"
  [ "$blob" = "$EXPECTED_BLOB" ] \
    || fail "#$desired_pr head ${head:0:12} carries manifest $blob, not the reconciler's $EXPECTED_BLOB"

  if [ "$REQUEST_AUTO_MERGE" != true ]; then
    printf '#%s: auto-merge is off for this run; the PR waits for the owner to merge it\n' "$desired_pr"
  elif [ "$(jq -r '.autoMergeRequest != null' <<<"$pr")" = true ]; then
    printf '#%s already has auto-merge requested\n' "$desired_pr"
  else
    gh pr merge "$desired_pr" --repo "$REPO" --auto --squash --match-head-commit "$head" \
      || fail "could not request auto-merge on #$desired_pr"
    printf '#%s: auto-merge requested at %s\n' "$desired_pr" "${head:0:12}"
  fi
fi

if [ -n "$ONLY_PLUGIN" ]; then
  printf 'targeted run for %s: leaving other repin PRs open\n' "$ONLY_PLUGIN"
  exit 0
fi

if [ -n "$desired_pr" ]; then
  reason="Superseded by #$desired_pr, the reconciler's repin against current main."
else
  reason='Closed by the repin reconciler: main already matches every plugin release.'
fi
stale="$(jq -r --arg b "$DESIRED_BRANCH" '.[] | select(.headRefName != $b) | .number' <<<"$repins")"
closed=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  gh pr close "$n" --repo "$REPO" --delete-branch --comment "$reason" \
    || fail "could not close superseded repin PR #$n"
  closed=$((closed + 1))
done <<<"$stale"
printf 'closed %s superseded repin PR(s)\n' "$closed"
