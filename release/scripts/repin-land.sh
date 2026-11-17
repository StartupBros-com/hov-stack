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
# already matches every release. Left open with auto-merge requested, it would pin
# an older release: main's merge queue (since 2026-11-15) lands a green PR that is
# behind main, where the up-to-date rule alone used to leave it stalled.
#
# A card is kept while main moves, because its key holds as long as the plan and main's
# copy of the file do. So a card whose required checks failed would wait for good on a
# fix that lands on main without touching either: the run finds the card already open,
# and the merge queue admits only a PR whose checks passed. Last of all, when this run's
# PR has finished its required checks with at least one failed, and main has commits its
# head lacks, the bot merges main into it (GitHub's update-branch, pinned to the head
# proved above), so the checks run again with main's fix. A card whose checks pass or are
# still running is left behind main for the merge queue, and after a refresh the next
# one comes only when main moves again. The merge adds main's commits and nothing else to
# the proved head; if main changed the file meanwhile, the next run's key differs and
# that run supersedes this card.
#
# The same proof and close loop serve any bot-opened, single-file PR family. LAND_PATH
# names the one file the PR may change, BRANCH_PREFIX the family's branch prefix, and
# REQUEST_AUTO_MERGE=false runs the proof but leaves the merge to the owner, cancelling
# an auto-merge request a bot made on the PR (one a person made stays). Each family
# closes only PRs under its own prefix, so a pins run never closes a repin PR and the
# reverse.
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
#                   proves the PR, cancels an auto-merge request a bot made on it, and
#                   leaves it waiting for the owner to merge it
#   ONLY_PLUGIN     set for a targeted run: its PR covers one plugin, so nothing is closed
#   GH_TOKEN        the marketplace bot's token
#   CHECKS_TOKEN    a token that can read check runs (the workflow's own, with checks: read);
#                   the bot App has no checks permission. Unset, GH_TOKEN is used.
#
# Exit codes:
#   0  the PR is queued for auto-merge (or already was, or REQUEST_AUTO_MERGE=false),
#      superseded PRs are closed, and a failed PR is refreshed from main when main moved
#   1  a read failure, this run's PR is not provably the reconciler's output, a bot's
#      auto-merge request could not be cancelled with REQUEST_AUTO_MERGE=false, or the
#      PR's checks could not be read or the PR not refreshed (after the merge request and
#      the closes, which stand)

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

LAND_PATH="${LAND_PATH:-.claude-plugin/marketplace.json}"
BRANCH_PREFIX="${BRANCH_PREFIX:-repin/auto-}"
REQUEST_AUTO_MERGE="${REQUEST_AUTO_MERGE:-true}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
BOT_SLUG="${BOT_SLUG:-}"
DESIRED_BRANCH="${DESIRED_BRANCH:-}"
EXPECTED_BLOB="${EXPECTED_BLOB:-}"
ONLY_PLUGIN="${ONLY_PLUGIN:-}"
CHECKS_TOKEN="${CHECKS_TOKEN:-}"

# The card's check runs are read with CHECKS_TOKEN; every other call uses the bot's.
checks_api() {
  if [ -n "$CHECKS_TOKEN" ]; then GH_TOKEN="$CHECKS_TOKEN" gh api "$@"; else gh api "$@"; fi
}

# Merge main into this run's PR when its required checks finished with a failure and
# main has commits its head lacks (see the header). Reads keep gh's own error on stderr,
# so a token that cannot read check runs says so in the run's log.
refresh_failed_card() {
  local base required runs verdict failed ahead
  base="$(jq -r '.baseRefName // "main"' <<<"$pr")"
  required="$(gh api "repos/$REPO/rules/branches/$base?per_page=100" \
      --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | unique')" \
    || fail "could not read the required checks of $base"
  # filter=latest keeps the newest run of each name, so a rerun that is still going
  # reads as running, not as the failure it replaces.
  runs="$(checks_api "repos/$REPO/commits/$head/check-runs?filter=latest&per_page=100" --paginate \
      --jq '.check_runs[] | {name, status, conclusion}')" \
    || fail "could not read the check runs of #$desired_pr at ${head:0:12}"
  # One verdict per required check that has runs: running, passed, or failed (finished,
  # and no run passed). A required check with no run yet decides nothing.
  verdict="$(jq -sc --argjson req "$required" '
      [ $req[] as $name | [ .[] | select(.name == $name) ] | select(length > 0)
        | {name: $name,
           v: (if any(.status != "completed") then "running"
               elif any(.conclusion | IN("success", "neutral", "skipped")) then "pass"
               else "fail" end)} ]' <<<"$runs")" \
    || fail "could not read the check runs of #$desired_pr"
  if jq -e 'any(.v == "running")' <<<"$verdict" >/dev/null; then
    printf '#%s: required checks are still running at %s\n' "$desired_pr" "${head:0:12}"
    return 0
  fi
  failed="$(jq -r '[.[] | select(.v == "fail") | .name] | join(", ")' <<<"$verdict")"
  if [ -z "$failed" ]; then
    # Counted, so a log shows the read worked, and an empty rules read or a renamed
    # check (no required check reported) is visible instead of silently refreshing nothing.
    printf '#%s: %s required check(s), %s reported, none failed at %s\n' \
      "$desired_pr" "$(jq 'length' <<<"$required")" "$(jq 'length' <<<"$verdict")" "${head:0:12}"
    return 0
  fi
  ahead="$(gh api "repos/$REPO/compare/$head...$base" --jq '.ahead_by')" \
    || fail "could not compare #$desired_pr at ${head:0:12} with $base"
  case "$ahead" in ''|*[!0-9]*) fail "compare of #$desired_pr with $base gave no commit count: '$ahead'" ;; esac
  if [ "$ahead" -eq 0 ]; then
    printf '#%s: %s failed at %s, and %s has nothing newer to retry it with\n' \
      "$desired_pr" "$failed" "${head:0:12}" "$base"
    return 0
  fi
  gh api "repos/$REPO/pulls/$desired_pr/update-branch" -X PUT -f "expected_head_sha=$head" >/dev/null \
    || fail "could not merge $base into #$desired_pr at ${head:0:12}"
  printf '#%s: %s failed at %s; merged %s new commit(s) from %s into it, so its checks run again\n' \
    "$desired_pr" "$failed" "${head:0:12}" "$ahead" "$base"
}

[ -n "$REPO" ] || fail 'REPO is not set'
[ -n "$BOT_SLUG" ] || fail 'BOT_SLUG is not set'
case "$REQUEST_AUTO_MERGE" in true|false) ;; *) fail "REQUEST_AUTO_MERGE must be true or false, not '$REQUEST_AUTO_MERGE'" ;; esac
[ -n "$BRANCH_PREFIX" ] || fail 'BRANCH_PREFIX is empty'

# Open repin PRs the bot opened from this repository. Same-named branches on a fork
# or PRs by anyone else are not ours to merge or close. gh reports an App author as
# app/<slug> (observed on #205-#207); the REST spelling <slug>[bot] is accepted too,
# since both name the same App account.
open_prs="$(gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,headRefName,headRefOid,baseRefName,author,isCrossRepository,autoMergeRequest 2>/dev/null)" \
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
    # A request an earlier run made (with auto-merge on then) still merges the PR as the
    # bot once the checks pass, so a run with it off cancels that request. A request a
    # person enabled is that person's merge and stays. A request whose requester GitHub
    # did not report is treated as the bot's.
    requester="$(jq -r 'if .autoMergeRequest == null then "none"
                        elif .autoMergeRequest.enabledBy.is_bot == false then "person"
                        else "bot" end' <<<"$pr")"
    case "$requester" in
      bot)
        gh pr merge "$desired_pr" --repo "$REPO" --disable-auto \
          || fail "could not cancel the auto-merge request on #$desired_pr; it would merge as the bot"
        printf '#%s: auto-merge is off for this run; cancelled the request an earlier run made, so the PR waits for the owner to merge it\n' "$desired_pr"
        ;;
      person)
        printf '#%s: auto-merge is off for this run; leaving the auto-merge %s requested\n' \
          "$desired_pr" "$(jq -r '.autoMergeRequest.enabledBy.login' <<<"$pr")"
        ;;
      *)
        printf '#%s: auto-merge is off for this run; the PR waits for the owner to merge it\n' "$desired_pr"
        ;;
    esac
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
else
  if [ -n "$desired_pr" ]; then
    reason="Superseded by #$desired_pr, which carries the current plan."
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
fi

[ -z "$desired_pr" ] || refresh_failed_card
