#!/usr/bin/env bash
# gh-repo-settings.sh: assert the repo-level settings the tracking and
# attribution conventions depend on, across the org's non-archived repos.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer  — the operator (fleet rollout, DRY_RUN=0) and wt-new.sh, which
#               cannot file a work-spec in a repo with issues off (smaug, 2026-09-02).
#   gate      — attribution-off: with squash_merge_commit_message=COMMIT_MESSAGES
#               GitHub folds every branch commit's message, Co-authored-by
#               trailers included, into the main-branch commit (a private evals repository's #1227
#               reproduced it; smaug #5 carried 44 AI trailers). This is the one
#               path that also covers Cursor / droid / Codex commits, which no
#               Claude Code hook can see. PR_BODY makes the reviewed PR body the
#               squash message instead. dotfiles#854.
#   defect    — OBSERVED: all 60 org repos were on COMMIT_MESSAGES on 2026-09-02;
#               smaug (a fork) had issues disabled.
#   delete-when — GitHub offers org-level defaults for these four keys.
#
# Asserted: squash_merge_commit_title=PR_TITLE, squash_merge_commit_message=PR_BODY,
# delete_branch_on_merge=true, has_issues=true. Nothing else is touched (wiki,
# projects, merge-commit/rebase allowances, rulesets, templates).
#
# Env: DRY_RUN=1 (default) report drift only; DRY_RUN=0 PATCH drifted repos.
#      ORG=StartupBros-com   ONLY=<repo-name> limit to one repo.
# Summary line: "gh-repo-settings: ok:N drifted:N patched:N failed:N"
# Exit: 0 when every read and PATCH succeeded (drift alone is not a failure).
set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"
ORG="${ORG:-StartupBros-com}"
ONLY="${ONLY:-}"
WANT="PR_TITLE PR_BODY true true"

ok=0 drifted=0 patched=0 failed=0

read_settings() {
  gh api "repos/$ORG/$1" --jq '[.squash_merge_commit_title, .squash_merge_commit_message, (.delete_branch_on_merge|tostring), (.has_issues|tostring)] | join(" ")'
}

if [ -n "$ONLY" ]; then
  names="$ONLY"
else
  names=$(gh repo list "$ORG" --limit 200 --no-archived --json name --jq '.[].name' | sort) \
    || { echo "gh-repo-settings: repo list failed for $ORG" >&2; exit 1; }
fi

for name in $names; do
  cur=$(read_settings "$name") || { echo "$name: read failed"; failed=$((failed+1)); continue; }
  if [ "$cur" = "$WANT" ]; then ok=$((ok+1)); continue; fi
  drifted=$((drifted+1))
  if [ "$DRY_RUN" = 1 ]; then echo "$name: drift [$cur] -> [$WANT] (dry)"; continue; fi
  after=$(gh api -X PATCH "repos/$ORG/$name" \
    -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
    -F delete_branch_on_merge=true -F has_issues=true \
    --jq '[.squash_merge_commit_title, .squash_merge_commit_message, (.delete_branch_on_merge|tostring), (.has_issues|tostring)] | join(" ")') || after=""
  # Verify from the response, not the request: a 200 with unchanged values is a failure.
  if [ "$after" = "$WANT" ]; then echo "$name: patched [$cur] -> [$WANT]"; patched=$((patched+1))
  else echo "$name: PATCH did not take (got [$after])"; failed=$((failed+1)); fi
done

echo "gh-repo-settings: ok:$ok drifted:$drifted patched:$patched failed:$failed"
[ "$failed" -eq 0 ]
