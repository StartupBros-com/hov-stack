#!/usr/bin/env bash
# pr-land.sh: land one pull request and come back once.
#
# The Merge-and-end rule (CLAUDE.md) used to be a sequence the model ran by hand: poll
# `gh pr view` / `gh pr checks` with sleeps, merge, poll again for the merge, then run
# wt-done. Each poll woke the model and cost a turn. This script does the waiting outside
# the model. Its stdout is exactly one line, the verdict:
#
#   merged <sha>[ (<note>)]      the PR merged (and, from its worktree, wt-done ran)
#   red: <check> <url>[; ...]    a check failed at the head; nothing merged
#   blocked: <reason>            refused before or at the merge; nothing merged
#   pending: <reason>            still waiting, or a read failed; nothing merged, safe to re-run
#   unconfirmed: <reason>        a merge was requested but did not show as merged yet
#
# Progress and wt-done's own output (its `activation:` lines) go to stderr. Run it in the
# background: the default waits are longer than a foreground shell call may last.
#
# Green means every reported check at the exact head passed (SUCCESS, SKIPPED or NEUTRAL),
# every check the base branch requires (rulesets and classic protection, unioned) is among
# them, and every workflow run at that head has completed, on two reads in a row. A red
# check blocks whether or not the base requires it.
#
# Its wait-and-merge core is marketplace-repin-merge.sh's, without that script's bot-repin
# identity checks.
#
# It refuses to merge when a Pro round is due and has not finished clean. A round is due
# when the diff touches .github/ or a migrations directory, or when --pro says so (billing,
# auth, real money or user data: paths alone cannot show those). The pro-gate rounds record
# for the PR must exist (absent is unknown, not zero) and show 0 open P0 and 0 open P1, or,
# with --pro-fixed, the PR must have a non-merge commit newer than that round: the "fix its
# P0/P1, push, no second round" path. That merge is reported as such, never as a Pro pass.
# It also refuses under CLAUDE_LOOP_GUARD=1: loop-guard fences `gh pr merge` by its command
# text, which it cannot see inside this script.
#
# Right before each merge attempt it reads the PR body and the issues GitHub will close
# (closingIssuesReferences), prints them, and refuses when one of them is not named on a
# closing line: a body line that starts with close, fix or resolve (or a variant, in any case,
# after an optional list marker) followed by a reference, or that has a capitalized Closes,
# Fixes or Resolves right before one ("Operator go. Closes #12."). GitHub also reads the
# lower-case words mid-sentence: "the fix owner/repo#N asks for" and "still not closed: #439"
# each closed an issue nobody meant to close (#821). A failed read refuses too.
#
# Then it asks merge-freeze.sh whether another session holds a merge freeze on the repository
# (a deploy or a release that needs the base to stand still). While one is active it waits for
# the freeze to end, up to --wait, and re-reads the checks before merging; past that it exits
# pending, naming the holder, the end time and the reason. A PR the freeze allows, or one run by
# the freeze's own holder, merges through it. A freeze file that does not parse holds the merge.
#
# Usage: pr-land.sh [<pr>] [--repo OWNER/NAME] [--pro] [--pro-fixed] [--wait SECONDS]
#                   [--queue-wait SECONDS] [--updates N] [--no-closeout] [--allow-no-checks]
#                   [--allow-prose-closes]
#   <pr>               PR number (default: the open, else merged, PR of the current branch)
#   --repo             default: the current checkout's GitHub repo
#   --pro              a Pro round is due for a reason the paths cannot show
#   --pro-fixed        the due round left open P0/P1 and the fixes are pushed (no second round)
#   --wait N           wait up to N seconds for the checks (default 3600)
#   --queue-wait N     wait up to N seconds for a merge queue to land the PR (default 3600)
#   --updates N        branch updates allowed when the base requires up-to-date branches (default 2)
#   --no-closeout      do not run wt-done after the merge
#   --allow-no-checks  merge even when no check reports and the base requires none
#   --allow-prose-closes  merge even when an issue it closes is not on a closing-keyword line
#                      (a deliberate close written mid-sentence, or one linked in the sidebar)
# Exit: 0 merged; 1 red or blocked; 2 pending; 3 unconfirmed; 4 merged but wt-done failed;
# 64 usage
set -euo pipefail
POLL=${PR_LAND_POLL_SECONDS:-30}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT_DONE=${PR_LAND_WT_DONE:-$HERE/wt-done.sh}
FREEZE=${PR_LAND_MERGE_FREEZE:-$HERE/merge-freeze.sh}
say() { printf 'pr-land: %s\n' "$1" >&2; }
finish() { local rc=$1; shift; printf '%s\n' "$*"; exit "$rc"; }
refuse() { finish 1 "blocked: $1"; }
retry() { finish 2 "pending: $1"; }
unconfirmed() { finish 3 "unconfirmed: $1"; }
usage() {
  say 'usage: pr-land.sh [<pr>] [--repo OWNER/NAME] [--pro] [--pro-fixed] [--wait S] [--queue-wait S] [--updates N] [--no-closeout] [--allow-no-checks] [--allow-prose-closes]'
  exit 64
}

PR="" REPO="" PRO=0 PRO_FIXED=0 WAIT=3600 QUEUE_WAIT=3600 MAX_UPDATES=2 CLOSEOUT=1 ALLOW_NO_CHECKS=0 ALLOW_PROSE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage; REPO=$2; shift 2 ;;
    --pro) PRO=1; shift ;;
    --pro-fixed) PRO_FIXED=1; shift ;;
    --wait) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; WAIT=$2; shift 2 ;;
    --queue-wait) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; QUEUE_WAIT=$2; shift 2 ;;
    --updates) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; MAX_UPDATES=$2; shift 2 ;;
    --no-closeout) CLOSEOUT=0; shift ;;
    --allow-no-checks) ALLOW_NO_CHECKS=1; shift ;;
    --allow-prose-closes) ALLOW_PROSE=1; shift ;;
    -h|--help) usage ;;
    *) [[ "$1" =~ ^[1-9][0-9]*$ ]] && [ -z "$PR" ] || usage; PR=$1; shift ;;
  esac
done
[ "${CLAUDE_LOOP_GUARD:-}" != 1 ] \
  || refuse 'CLAUDE_LOOP_GUARD=1: an autonomous loop run may not merge; leave the PR open for the operator'
S=$(mktemp -d "${TMPDIR:-/tmp}/pr-land.XXXXXX") || exit 2
trap 'rm -rf "$S"' EXIT

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || refuse 'no --repo given and the current directory is not a GitHub checkout'
fi
if [ -z "$PR" ]; then
  # `gh pr view --repo X` needs an explicit PR, so look the branch up instead.
  BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || refuse 'no PR number given and no git branch here'
  PR=$(gh pr list --repo "$REPO" --head "$BR" --state all --json number,state \
    --jq '(map(select(.state == "OPEN")) + map(select(.state == "MERGED"))) | .[0].number // empty') \
    || retry "looking up the PR for branch $BR failed"
  [ -n "$PR" ] || refuse "branch $BR has no open or merged PR in $REPO; open one with gh pr create"
fi

# 1. The PR itself.
gh pr view "$PR" --repo "$REPO" --json state,isDraft,baseRefName,headRefName,headRefOid,mergeStateStatus,mergeCommit \
  >"$S/pr.json" || retry "PR #$PR read failed"
STATE=$(jq -r .state "$S/pr.json") BASE=$(jq -r .baseRefName "$S/pr.json")
HEAD_BRANCH=$(jq -r .headRefName "$S/pr.json") HEAD=$(jq -r .headRefOid "$S/pr.json")
MERGED="" NOTE="" UPDATES=0

closeout() {
  # wt-done only from the PR's own worktree: it closes out the branch it is run on.
  if [ "$CLOSEOUT" = 0 ]; then say 'closeout skipped (--no-closeout)'; return 0; fi
  local cur origin
  cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  origin=$(git remote get-url origin 2>/dev/null || true)
  if [ "$cur" != "$HEAD_BRANCH" ] || [[ "$origin" != *"$REPO" && "$origin" != *"$REPO.git" ]]; then
    say "closeout skipped: not run from PR #$PR's worktree (branch $HEAD_BRANCH); run wt-done there"
    return 0
  fi
  if [ "$(git rev-parse HEAD)" != "$HEAD" ]; then
    # The branch moved on GitHub (an update from the base): wt-done proves "merged this exact
    # tip" only once the local tip is the head that merged.
    git fetch -q origin "refs/pull/$PR/head" >&2 && git merge -q --ff-only --no-autostash FETCH_HEAD >&2 \
      || { say "closeout: the local tip is not PR #$PR's merged head ${HEAD:0:12} and cannot fast-forward to it"; return 1; }
  fi
  DRY_RUN=0 "$WT_DONE" >&2
}
land_done() {
  local rc=0 tail=""
  [ -z "$NOTE" ] || tail=" ($NOTE)"
  closeout || rc=$?
  [ "$rc" = 0 ] || finish 4 "merged $MERGED$tail; wt-done failed, exit $rc"
  finish 0 "merged $MERGED$tail"
}

case "$STATE" in
  MERGED) MERGED=$(jq -r '.mergeCommit.oid // ""' "$S/pr.json")
          [ -n "$MERGED" ] || retry "PR #$PR reads merged but has no merge commit yet"
          say "PR #$PR is already merged"; land_done ;;
  CLOSED) refuse "PR #$PR is closed" ;;
esac
[ "$(jq -r .isDraft "$S/pr.json")" = false ] || refuse "PR #$PR is a draft; mark it ready (gh pr ready $PR) first"
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || retry 'PR head unreadable'

# 2. A due Pro round must have finished with no open P0 or P1, or have its fixes pushed.
gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" --jq '.[].filename' >"$S/files.txt" \
  || retry "PR #$PR file list unreadable"
WHY=""
if grep -q -E '^\.github/' "$S/files.txt"; then WHY=".github/"; fi
if grep -q -E '(^|/)migrations?/' "$S/files.txt"; then WHY="${WHY:+$WHY, }a migrations directory"; fi
if [ "$PRO" = 1 ]; then WHY="${WHY:+$WHY, }--pro"; fi
if [ -n "$WHY" ]; then
  REC="${PRO_GATE_ROUNDS_DIR:-${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/rounds}/${REPO/\//-}-$PR.last"
  [ -f "$REC" ] || refuse "a Pro round is due ($WHY) and none has finished for PR #$PR; run /pro-gate, fix its P0/P1, push, then re-run"
  EPOCH="" P0="" P1=""
  IFS=$'\t' read -r EPOCH P0 P1 <"$REC" || true
  [[ "$EPOCH" =~ ^[0-9]+$ && "$P0" =~ ^[0-9]+$ && "$P1" =~ ^[0-9]+$ ]] || refuse "the Pro rounds record $REC is unreadable"
  if [ "$P0" = 0 ] && [ "$P1" = 0 ]; then
    say "Pro round due ($WHY): the last completed round left 0 open P0/P1"
  elif [ "$PRO_FIXED" = 1 ]; then
    # Committer dates of the PR's own (non-merge) commits; a base update is a merge and
    # does not count as a fix.
    gh api --paginate "repos/$REPO/pulls/$PR/commits?per_page=100" \
      --jq '.[] | select((.parents | length) == 1) | .commit.committer.date' >"$S/dates.txt" \
      || retry "PR #$PR commit list unreadable"
    NEWER=0
    while IFS= read -r d; do
      t=$(date -d "$d" +%s 2>/dev/null) || continue
      [ "$t" -le "$EPOCH" ] || NEWER=$((NEWER + 1))
    done <"$S/dates.txt"
    [ "$NEWER" -gt 0 ] || refuse "--pro-fixed, but PR #$PR has no commit newer than its Pro round ($(date -u -d "@$EPOCH" +%FT%TZ)); push the fixes first"
    NOTE="the Pro round left $P0 P0 and $P1 P1 open; fixes pushed after it, no second round; not a Pro pass"
    say "Pro round due ($WHY): $NOTE"
  else
    refuse "the last Pro round on PR #$PR left $P0 open P0 and $P1 open P1; fix them, push (no second round), then re-run with --pro-fixed"
  fi
fi

# 3. What the base branch requires: rulesets and classic protection, unioned (either alone
# undercounts). A 404 from classic protection means none; anything else is not a "none",
# with one exception. A private repo on a plan without branch protection (a free personal
# account) cannot carry rulesets or protection at all, and GitHub answers both reads with a
# 403 naming the plan. That exact message is a determinate "none". Any other 403 (rate
# limit, SSO, missing scope) stays unreadable.
plan_gated() { grep -q -F 'Upgrade to GitHub Pro or make this repository public' "$1" && grep -q -F 'HTTP 403' "$1"; }
GATED=0
if gh api "repos/$REPO/rules/branches/$BASE" >"$S/rules.json" 2>"$S/rules.err"; then :
elif plan_gated "$S/rules.err"; then echo '[]' >"$S/rules.json"; GATED=1
else retry "rules for $BASE unreadable: $(tr '\n' ' ' <"$S/rules.err" | cut -c1-200)"; fi
if gh api "repos/$REPO/branches/$BASE/protection/required_status_checks" >"$S/classic.json" 2>"$S/classic.err"; then :
elif grep -q -F 'HTTP 404' "$S/classic.err"; then echo '{}' >"$S/classic.json"
elif plan_gated "$S/classic.err"; then echo '{}' >"$S/classic.json"; GATED=1
else retry "classic protection for $BASE unreadable: $(tr '\n' ' ' <"$S/classic.err" | cut -c1-200)"; fi
[ "$GATED" = 0 ] || say "$BASE cannot carry rulesets or branch protection on this repo's plan (GitHub's plan-gated 403), so it requires no checks"
REQUIRED=$(jq -cn --slurpfile r "$S/rules.json" --slurpfile c "$S/classic.json" \
  '([$r[0][] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]
    + ($c[0].contexts // []) + [($c[0].checks // [])[].context]) | unique')
STRICT=$(jq -rn --slurpfile r "$S/rules.json" --slurpfile c "$S/classic.json" \
  '[$r[0][] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy] + [$c[0].strict // false] | any')
QUEUE=$(jq -r 'any(.[]; .type == "merge_queue")' "$S/rules.json")

# Every reported check and every required one. A check passes on SUCCESS, SKIPPED or
# NEUTRAL, as GitHub's merge does. Within one workflow a not-yet-finished run (a queued
# re-run) is pending; otherwise the last to complete stands, so a re-run replaces the
# failure it re-ran. A required check that has not reported is pending.
VERDICT='
  def verdict: if .__typename == "StatusContext" then
      (if .state == "SUCCESS" then "pass" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "fail" end)
    elif .status != "COMPLETED" then "pending"
    elif (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL") then "pass"
    else "fail" end;
  def checkname: (.name // .context);
  (.statusCheckRollup // []) as $all
  | [ (($req + [$all[] | checkname]) | unique)[] as $n
      | [ $all[] | select(checkname == $n) ] as $runs
      | if ($runs | length) == 0 then {name: $n, v: "pending", url: ""}
        else
          [ $runs | group_by(.workflowName // "")[]
            | if any(.[]; verdict == "pending") then {v: "pending", url: ""}
              else (sort_by(.completedAt // "") | last | {v: verdict, url: (.detailsUrl // .targetUrl // "")}) end ] as $g
          | if any($g[]; .v == "fail") then {name: $n, v: "fail", url: ([$g[] | select(.v == "fail") | .url] | first)}
            elif any($g[]; .v == "pending") then {name: $n, v: "pending", url: ""}
            else {name: $n, v: "pass", url: ""} end
        end ]'

wait_checks() {
  local deadline=$((SECONDS + WAIT)) grace=$((SECONDS + (WAIT < 180 ? WAIT : 180))) told=0 seen=0 n runs pend
  while :; do
    gh pr view "$PR" --repo "$REPO" --json headRefOid,mergeable,statusCheckRollup >"$S/checks.json" \
      || retry "checks on PR #$PR unreadable"
    [ "$(jq -r .headRefOid "$S/checks.json")" = "$HEAD" ] \
      || retry "PR #$PR's head moved from ${HEAD:0:12} while waiting; re-run to land the new head"
    [ "$(jq -r .mergeable "$S/checks.json")" != CONFLICTING ] \
      || refuse "PR #$PR conflicts with $BASE (a conflicting PR gets no CI); merge $BASE into it in its worktree, push, re-run"
    jq -c --argjson req "$REQUIRED" "$VERDICT" "$S/checks.json" >"$S/verdict.json" || retry 'checks unparseable'
    if jq -e 'any(.[]; .v == "fail")' "$S/verdict.json" >/dev/null; then
      finish 1 "red: $(jq -r 'map(select(.v == "fail") | "\(.name) \(.url)") | join("; ")' "$S/verdict.json")"
    fi
    # Workflow runs still going at this head: jobs behind `needs:` show up only when they start.
    runs=$(gh api "repos/$REPO/actions/runs?head_sha=$HEAD&per_page=100" \
      --jq '[.workflow_runs[] | select(.status != "completed") | .name] | unique | join(", ")') \
      || retry "workflow runs at ${HEAD:0:12} unreadable"
    n=$(jq 'length' "$S/verdict.json")
    pend=$(jq -r 'map(select(.v == "pending") | .name) | join(", ")' "$S/verdict.json")
    [ -z "$runs" ] || pend="${pend:+$pend, }workflow runs: $runs"
    if [ -z "$pend" ] && [ "$n" -gt 0 ]; then
      if [ "$seen" = 1 ]; then say "$n check(s) green at ${HEAD:0:12}"; return 0; fi
      seen=1   # one more read, for a workflow that registers late
    else
      seen=0
      if [ "$n" = 0 ] && [ -z "$runs" ] && [ "$SECONDS" -ge "$grace" ]; then
        [ "$ALLOW_NO_CHECKS" = 0 ] \
          || { say "no checks reported at ${HEAD:0:12}; merging (--allow-no-checks)"; return 0; }
        retry "no checks reported at ${HEAD:0:12} and $BASE requires none; pass --allow-no-checks to merge without any"
      fi
      [ "$SECONDS" -lt "$deadline" ] || retry "checks still pending after ${WAIT}s at ${HEAD:0:12}: ${pend:-none reported}"
      if [ "$told" = 0 ]; then say "waiting up to ${WAIT}s for checks at ${HEAD:0:12}: ${pend:-none reported yet}"; told=1; fi
    fi
    sleep "$POLL"
  done
}

update_branch() {
  [ "$UPDATES" -lt "$MAX_UPDATES" ] || refuse "PR #$PR is still behind $BASE after $UPDATES update(s); $BASE keeps moving, re-run later"
  gh pr update-branch "$PR" --repo "$REPO" >&2 || retry "updating PR #$PR's branch from $BASE failed"
  UPDATES=$((UPDATES + 1))
  local new=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    new=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid) || new=""
    [ -z "$new" ] || [ "$new" = "$HEAD" ] || break
    sleep "$((POLL / 10 + 1))"
  done
  [ -n "$new" ] && [ "$new" != "$HEAD" ] || retry "PR #$PR's head did not move after the branch update"
  say "merged $BASE into PR #$PR's branch ($UPDATES of $MAX_UPDATES); new head ${new:0:12}"
  HEAD=$new
}

# The issues a merge will close, each as owner/name#N, and those no closing line (header
# comment) names. A closing line names an issue as #N (this repo), owner/name#N or an issues
# URL, matched without case.
CLOSES='
  ($self | ascii_downcase) as $me
  | ":?\\s*(?:#[0-9]|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]|https?://github\\.com/)" as $ref
  | [ (.body // "") | split("\n")[] | rtrimstr("\r")
      | select(test("^\\s*(?:[-*+]\\s+|[0-9]+[.)]\\s+)?(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)" + $ref; "i")
          or test("\\b(?:Close[sd]?|Fix(?:e[sd])?|Resolve[sd]?)" + $ref))
      | ( (scan("github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/([0-9]+)"; "i") | "\(.[0])#\(.[1])"),
          (scan("([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)") | "\(.[0])#\(.[1])"),
          (scan("(?<![A-Za-z0-9_./-])#([0-9]+)") | "\($me)#\(.[0])") )
      | ascii_downcase ] as $named
  | [ .closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name)#\(.number)" ] as $all
  | {all: $all, prose: [ $all[] | select(ascii_downcase | IN($named[]) | not) ]}'

check_closes() {
  gh pr view "$PR" --repo "$REPO" --json body,closingIssuesReferences >"$S/closes.json" \
    || retry "PR #$PR's body and closing issues unreadable; nothing merged"
  jq -c --arg self "$REPO" "$CLOSES" "$S/closes.json" >"$S/closes.verdict.json" || retry 'closing issues unparseable'
  local all prose
  all=$(jq -r '.all | join(", ")' "$S/closes.verdict.json")
  prose=$(jq -r '.prose | join(", ")' "$S/closes.verdict.json")
  [ -z "$all" ] || say "PR #$PR will close: $all"
  [ -n "$prose" ] || return 0
  if [ "$ALLOW_PROSE" = 1 ]; then say "closing $prose though no closing-keyword line names it (--allow-prose-closes)"; return 0; fi
  refuse "PR #$PR would close $prose, which the body names only in prose (a lower-case close, fix or resolve mid-sentence) or not at all (a sidebar link); reword it (Refs #N) or write the close as its own Closes #N line and re-run, or re-run with --allow-prose-closes if the close is meant"
}

# A merge freeze another session holds (merge-freeze.sh). Returns 0 once a freeze that held the
# merge has ended, so the caller re-reads the checks (the head may have moved meanwhile), and 1
# when none held it. All the freezes one run meets share one --wait.
FREEZE_DEADLINE=""
wait_freeze() {
  local line rc held=0
  while :; do
    rc=0
    line=$(bash "$FREEZE" check --repo "$REPO" --pr "$PR") || rc=$?
    case "$rc" in
      0) [ "$held" = 0 ] || return 0; return 1 ;;
      1) ;;
      *) retry "${line:-the merge-freeze check failed (exit $rc)}; nothing merged" ;;
    esac
    [ -n "$FREEZE_DEADLINE" ] || FREEZE_DEADLINE=$((SECONDS + WAIT))
    [ "$SECONDS" -lt "$FREEZE_DEADLINE" ] || retry "$line; nothing merged, re-run once it ends"
    [ "$held" = 1 ] || say "waiting up to ${WAIT}s for a merge freeze to end: $line"
    held=1
    sleep "$POLL"
  done
}

# 4. Wait, merge the exact head; on a strict base with no queue, update a behind branch first.
if [ "$STRICT" = true ] && [ "$QUEUE" = false ] && [ "$(jq -r .mergeStateStatus "$S/pr.json")" = BEHIND ]; then
  update_branch
fi
while :; do
  wait_checks
  check_closes
  if wait_freeze; then continue; fi
  if gh pr merge "$PR" --repo "$REPO" --squash --match-head-commit "$HEAD" >"$S/merge.out" 2>&1; then break; fi
  # The command can fail after GitHub merged (a client timeout): read the state before deciding.
  POST=$(gh pr view "$PR" --repo "$REPO" --json state,mergeStateStatus --jq '"\(.state) \(.mergeStateStatus)"') \
    || unconfirmed "the merge command failed and PR #$PR's state is unreadable"
  case "$POST" in
    MERGED\ *) say "the merge command failed, but PR #$PR is merged"; break ;;
    *\ BEHIND) update_branch ;;
    *\ DIRTY) refuse "PR #$PR conflicts with $BASE; merge $BASE into it in its worktree, push, re-run" ;;
    *) refuse "GitHub refused the merge of PR #$PR at ${HEAD:0:12} ($POST): $(tr '\n' ' ' <"$S/merge.out" | cut -c1-300)" ;;
  esac
done

# 5. Wait for the merge. A PR seen in a merge queue is waited on until --queue-wait runs out;
# out of the queue and still open twice in a row means the queue dropped it.
STATE_QUERY='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){state isInMergeQueue mergeCommit{oid}}}}'
QUEUED=0 GONE=0 TRIES=0
QUEUE_DEADLINE=$((SECONDS + QUEUE_WAIT))
while :; do
  POST=$(gh api graphql -f owner="${REPO%/*}" -f name="${REPO#*/}" -F number="$PR" -f query="$STATE_QUERY" \
    --jq '.data.repository.pullRequest | "\(.state) \(.isInMergeQueue) \(.mergeCommit.oid // "")"') || POST=""
  case "$POST" in
    MERGED\ *) MERGED=${POST##* }; [ -z "$MERGED" ] || break ;;
    CLOSED\ *) refuse "PR #$PR was closed without merging after the merge was requested" ;;
    OPEN\ true\ *)
      [ "$QUEUED" = 1 ] || say "PR #$PR is in $BASE's merge queue; waiting up to ${QUEUE_WAIT}s for it to land"
      QUEUED=1 GONE=0 ;;
    OPEN\ false\ *)
      if [ "$QUEUED" = 1 ]; then
        GONE=$((GONE + 1))
        [ "$GONE" -lt 2 ] || refuse "PR #$PR left $BASE's merge queue without merging; read the merge group's checks"
      fi ;;
  esac
  TRIES=$((TRIES + 1))
  if [ "$QUEUED" = 1 ]; then
    [ "$SECONDS" -lt "$QUEUE_DEADLINE" ] \
      || unconfirmed "PR #$PR is still in $BASE's merge queue after ${QUEUE_WAIT}s; it lands by itself once its checks pass there"
    sleep "$POLL"
  else
    [ "$TRIES" -lt 6 ] || break
    sleep "$((POLL / 6 + 1))"
  fi
done
[ -n "$MERGED" ] || unconfirmed "PR #$PR is not shown as merged yet"
say "merged PR #$PR as ${MERGED:0:12}"
land_done
