#!/usr/bin/env bash
# Merge a bot repin PR on StartupBros-com/hov-stack on its required checks, with no
# review round (operator ruling 2026-10-15, dotfiles#1832; HARNESS.md "PR ownership").
#
# A repin only moves pins: "Pinned sources" (validate-marketplace.sh full) already proves the
# approved source URL, that the release tag resolves to the pinned commit, card version ==
# manifest version and a rising releaseId. What a review would add is proof that the PR is the
# bot's and changes nothing else. This script proves exactly that, then merges the exact head.
#
# Usage: marketplace-repin-merge.sh <pr> [--check-only] [--wait SECONDS]
#   --check-only  stop after the identity and diff checks
#   --wait N      wait up to N seconds for pending required checks (default 900)
# Exit: 0 merged, or eligible under --check-only
#       1 refused: not a bot repin, a required check failed, main no longer requires
#         "Pinned sources", or GitHub refused the merge
#       2 could not read, checks still pending, or the PR is behind main: nothing merged,
#         safe to re-run
#       3 a merge was requested but its outcome or main's card is unconfirmed: do not
#         re-run blindly; check the PR and main's card by hand
set -euo pipefail
REPO=StartupBros-com/hov-stack
BOT=app/startupbros-hov-marketplace-bot
MANIFEST=.claude-plugin/marketplace.json
POLL=${REPIN_MERGE_POLL_SECONDS:-30}
say() { printf 'marketplace-repin-merge: %s\n' "$1" >&2; }
refuse() { say "refused: $1"; exit 1; }
retry() { say "not merged, re-run: $1"; exit 2; }
unconfirmed() { say "merge requested, outcome unconfirmed; check by hand before re-running: $1"; exit 3; }

PR=${1:-}
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || { say 'usage: marketplace-repin-merge.sh <pr> [--check-only] [--wait SECONDS]'; exit 2; }
shift
CHECK_ONLY=0 WAIT=900
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --wait) [[ "${2:-}" =~ ^[0-9]+$ ]] || { say 'usage: --wait needs seconds'; exit 2; }; WAIT=$2; shift 2 ;;
    *) say "usage: unknown option $1"; exit 2 ;;
  esac
done
S=$(mktemp -d /tmp/marketplace-repin-merge.XXXXXX) || exit 1
trap 'rm -rf "$S"' EXIT

# 1. Identity and scope.
gh pr view "$PR" --repo "$REPO" --json state,isDraft,author,baseRefName,headRefOid,files >"$S/pr.json" \
  || retry "PR #$PR read failed"
jq -e '.state == "OPEN"' "$S/pr.json" >/dev/null || refuse "PR #$PR is not open"
jq -e '.isDraft == false' "$S/pr.json" >/dev/null || refuse "PR #$PR is a draft"
jq -e --arg bot "$BOT" '.author.login == $bot' "$S/pr.json" >/dev/null \
  || refuse "PR #$PR is not by $BOT; it takes the normal review ladder"
jq -e '.baseRefName == "main"' "$S/pr.json" >/dev/null || refuse "PR #$PR does not target main"
jq -e --arg m "$MANIFEST" '[.files[].path] == [$m]' "$S/pr.json" >/dev/null \
  || refuse "PR #$PR changes files other than $MANIFEST; it takes the normal review ladder"
HEAD=$(jq -r '.headRefOid' "$S/pr.json")
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || retry 'PR head unreadable'

# 2. Only pin fields of existing plugin entries change, between the merge base and the head.
BASE=$(gh api "repos/$REPO/compare/main...$HEAD" --jq '.merge_base_commit.sha') || retry 'merge base unreadable'
[[ "$BASE" =~ ^[0-9a-f]{40}$ ]] || retry 'merge base unreadable'
gh api -H 'Accept: application/vnd.github.raw+json' "repos/$REPO/contents/$MANIFEST?ref=$BASE" >"$S/base.json" \
  || retry 'base manifest unreadable'
gh api -H 'Accept: application/vnd.github.raw+json' "repos/$REPO/contents/$MANIFEST?ref=$HEAD" >"$S/head.json" \
  || retry 'head manifest unreadable'
jq -e '.plugins | type == "array"' "$S/base.json" >/dev/null 2>&1 || retry 'base manifest is not a plugin list'
jq -e '.plugins | type == "array"' "$S/head.json" >/dev/null 2>&1 || retry 'head manifest is not a plugin list'
PINS_ONLY='
  def pinless: del(.source.sha, .metadata.version, .metadata.releaseId, .metadata.releaseTag);
  $b[0] as $base | $h[0] as $head
  | ($base | del(.plugins)) == ($head | del(.plugins))
    and ($base.plugins | length) == ($head.plugins | length)
    and ([range(0; $base.plugins | length) as $i | ($base.plugins[$i] | pinless) == ($head.plugins[$i] | pinless)] | all)
    and ([range(0; $base.plugins | length) as $i | $base.plugins[$i] != $head.plugins[$i]] | any)'
jq -ne --slurpfile b "$S/base.json" --slurpfile h "$S/head.json" "$PINS_ONLY" >/dev/null \
  || refuse "PR #$PR changes more than plugin pins (source.sha, metadata.version/releaseId/releaseTag); it takes the normal review ladder"
CHANGED=$(jq -nc --slurpfile b "$S/base.json" --slurpfile h "$S/head.json" \
  '[range(0; $b[0].plugins | length) as $i | select($b[0].plugins[$i] != $h[0].plugins[$i]) | $h[0].plugins[$i]
    | {name, url: .source.url, sha: .source.sha, version: .metadata.version, releaseId: .metadata.releaseId, tag: .metadata.releaseTag}]')
say "PR #$PR is a bot repin at $HEAD: $(jq -r 'map("\(.name) \(.version)") | join(", ")' <<<"$CHANGED")"
[ "$CHECK_ONLY" = 0 ] || exit 0

# 3. Every required check on main's ruleset is SUCCESS at this exact head.
REQUIRED=$(gh api "repos/$REPO/rules/branches/main" \
  --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]') \
  || retry 'required checks unreadable'
jq -e 'type == "array" and length > 0' <<<"$REQUIRED" >/dev/null 2>&1 \
  || retry 'main names no required checks; refusing to merge on none'
# The no-review rule rests on "Pinned sources" proving the tag resolves to the pin.
jq -e 'any(.[]; . == "Pinned sources")' <<<"$REQUIRED" >/dev/null \
  || refuse "main's ruleset no longer requires \"Pinned sources\"; the no-review rule rests on it (dotfiles#1832)"
VERDICT='
  [ $req[] as $name
    | [ .statusCheckRollup[] | select((.name // .context) == $name)
        | if .__typename == "StatusContext" then
            (if .state == "SUCCESS" then "pass" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "fail" end)
          elif .status != "COMPLETED" then "pending"
          elif .conclusion == "SUCCESS" then "pass" else "fail" end ]
    | if length == 0 then "pending" elif all(. == "pass") then "pass" elif any(. == "pending") then "pending" else "fail" end
    | {name: $name, v: .} ]'
DEADLINE=$((SECONDS + WAIT))
while :; do
  gh pr view "$PR" --repo "$REPO" --json headRefOid,statusCheckRollup >"$S/checks.json" || retry 'checks unreadable'
  [ "$(jq -r '.headRefOid' "$S/checks.json")" = "$HEAD" ] || retry "PR #$PR head moved since it was checked"
  jq -c --argjson req "$REQUIRED" "$VERDICT" "$S/checks.json" >"$S/verdict.json" || retry 'checks unparseable'
  if jq -e 'any(.v == "fail")' "$S/verdict.json" >/dev/null; then
    refuse "required check failed at $HEAD: $(jq -r 'map(select(.v == "fail") | .name) | join(", ")' "$S/verdict.json")"
  fi
  jq -e 'all(.v == "pass")' "$S/verdict.json" >/dev/null && break
  [ "$SECONDS" -lt "$DEADLINE" ] \
    || retry "required checks still pending at $HEAD: $(jq -r 'map(select(.v == "pending") | .name) | join(", ")' "$S/verdict.json")"
  sleep "$POLL"
done

# 4. Merge the exact head, then confirm main's card carries the new pins.
if ! gh pr merge "$PR" --repo "$REPO" --squash --match-head-commit "$HEAD" >&2; then
  # The command can fail after GitHub merged (a client timeout): read the state before deciding.
  POST=$(gh pr view "$PR" --repo "$REPO" --json state,mergeStateStatus --jq '"\(.state) \(.mergeStateStatus)"') \
    || unconfirmed "the merge command failed and PR #$PR's state is unreadable"
  case "$POST" in
    MERGED\ *) say "the merge command failed, but PR #$PR is merged; confirming the card" ;;
    *\ BEHIND) retry "PR #$PR is behind main and main requires up-to-date branches; update its branch, then re-run" ;;
    *) refuse "GitHub refused the merge of PR #$PR at $HEAD ($POST)" ;;
  esac
fi
MERGED=""
for _ in 1 2 3 4 5 6; do
  MERGED=$(gh pr view "$PR" --repo "$REPO" --json state,mergeCommit --jq 'select(.state == "MERGED") | .mergeCommit.oid') || MERGED=""
  [ -z "$MERGED" ] || break
  sleep "$((POLL / 6 + 1))"
done
[ -n "$MERGED" ] || unconfirmed "PR #$PR is not shown as merged yet"
gh api -H 'Accept: application/vnd.github.raw+json' "repos/$REPO/contents/$MANIFEST?ref=main" >"$S/live.json" \
  || unconfirmed "merged as $MERGED, but main's manifest is unreadable; check the card"
jq -ne --slurpfile l "$S/live.json" --argjson c "$CHANGED" \
  '[$c[] as $p | any($l[0].plugins[]; .name == $p.name and .source.sha == $p.sha and .metadata.releaseId == $p.releaseId)] | all' >/dev/null \
  || unconfirmed "merged as $MERGED, but main's card does not carry every new pin; check main"
say "merged PR #$PR as $MERGED; main's card carries the new pins"
# Since hov-stack#209 the merge's push re-runs repin-reconcile, which publishes the draft
# the new card pins, so the plugin's own publish workflow is no longer a manual step.
jq -r '.[] | (.url | capture("github\\.com/(?<r>[^/]+/[^/]+?)(\\.git)?$").r) as $r
  | "next: repin-reconcile publishes \($r) \(.tag) after this merge; if it is still a draft, run gh workflow run repin-reconcile.yml --repo StartupBros-com/hov-stack"' <<<"$CHANGED" >&2
