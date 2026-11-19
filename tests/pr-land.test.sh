#!/usr/bin/env bash
# pr-land.sh against a stubbed gh, git and wt-done. Every gh call is logged; the landing cases
# assert exactly one merge of the exact head, and every planted negative asserts no merge call
# at all. No network, no real GitHub.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_SRC="$ROOT/scripts/pr-land.sh"
TMP=$(mktemp -d /tmp/pr-land-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
check() { local name=$1; shift; if "$@"; then ok; else bad "$name"; fi; }
has() { [[ "$1" == *"$2"* ]]; }
[ -f "$SCRIPT_SRC" ] || { echo "missing $SCRIPT_SRC" >&2; exit 1; }

H=1111111111111111111111111111111111111111
H2=6666666666666666666666666666666666666666
M=3333333333333333333333333333333333333333
R=StartupBros-com/hov-stack
export H H2 M R FIX="$TMP/fix" GH_LOG="$TMP/gh.log" GIT_LOG="$TMP/git.log" WT_LOG="$TMP/wt.log"
mkdir -p "$TMP/bin" "$FIX"

cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Serve fixtures by exact argument shape; apply --jq like gh does (raw output).
printf '%s\n' "$*" >>"$GH_LOG"
jqexpr="" args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --jq ]; then jqexpr=$2; shift 2; else args+=("$1"); shift; fi
done
set -- "${args[@]}"
serve() {
  [ -f "$1" ] || { echo "fixture missing: $1" >&2; exit 1; }
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi
}
count() { local n; n=$(($(cat "$FIX/$1.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FIX/$1.count"; echo "$n"; }
head_now() { cat "$FIX/head"; }
case "$*" in
  "repo view --json nameWithOwner") printf '{"nameWithOwner":"%s"}\n' "$R" >"$FIX/repo.json"; serve "$FIX/repo.json" ;;
  "pr list --repo $R --head pr-land --state all --json number,state") serve "$FIX/list.json" ;;
  "pr view 7 --repo $R --json state,isDraft,baseRefName,headRefName,headRefOid,mergeStateStatus,mergeCommit")
    jq --arg h "$(head_now)" '.headRefOid = $h' "$FIX/pr.json" >"$FIX/pr.now.json"; serve "$FIX/pr.now.json" ;;
  "api --paginate repos/$R/pulls/7/files?per_page=100") serve "$FIX/files.json" ;;
  "api --paginate repos/$R/pulls/7/commits?per_page=100") serve "$FIX/commits.json" ;;
  "api repos/$R/rules/branches/main") serve "$FIX/rules.json" ;;
  "api repos/$R/branches/main/protection/required_status_checks")
    case "${STUB_CLASSIC:-404}" in
      404) echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
      502) echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1 ;;
      file) serve "$FIX/classic.json" ;;
    esac ;;
  "pr view 7 --repo $R --json headRefOid,mergeable,statusCheckRollup")
    n=$(count checks); f="$FIX/checks.json"; [ -f "$FIX/checks.$n.json" ] && f="$FIX/checks.$n.json"
    h=$(head_now); [ "${STUB_HEAD_MOVED:-0}" = 0 ] || h=$H2
    jq --arg h "$h" '.headRefOid = $h' "$f" >"$FIX/checks.now.json"; serve "$FIX/checks.now.json" ;;
  "api repos/$R/actions/runs?head_sha="*"&per_page=100")
    n=$(count runs); f="$FIX/runs.json"; [ -f "$FIX/runs.$n.json" ] && f="$FIX/runs.$n.json"; serve "$f" ;;
  "pr merge 7 --repo $R --squash --match-head-commit "*)
    all="$*"; sha=${all##* }
    [ "$sha" = "$(head_now)" ] || { echo "head mismatch: $sha" >&2; exit 1; }
    if [ -f "$FIX/behind" ]; then rm -f "$FIX/behind"; touch "$FIX/behind.seen"; echo 'head branch is not up to date' >&2; exit 1; fi
    if [ "${STUB_MERGE_RC:-0}" != 0 ]; then
      [ "${STUB_MERGE_LANDED:-0}" = 0 ] || touch "$FIX/merged"   # GitHub merged, the client errored
      echo 'merge blocked by ruleset' >&2; exit 1
    fi
    if [ -n "${STUB_QUEUE_READS:-}" ]; then touch "$FIX/queued"; else touch "$FIX/merged"; fi ;;
  "pr view 7 --repo $R --json state,mergeStateStatus")
    if [ -f "$FIX/merged" ]; then printf '{"state":"MERGED","mergeStateStatus":"UNKNOWN"}\n' >"$FIX/mstate.json"
    elif [ -f "$FIX/behind.seen" ]; then rm -f "$FIX/behind.seen"; printf '{"state":"OPEN","mergeStateStatus":"BEHIND"}\n' >"$FIX/mstate.json"
    else printf '{"state":"OPEN","mergeStateStatus":"%s"}\n' "${STUB_MERGE_STATE:-BLOCKED}" >"$FIX/mstate.json"; fi
    serve "$FIX/mstate.json" ;;
  "pr update-branch 7 --repo $R") echo "$H2" >"$FIX/head"; echo 'branch updated' ;;
  "pr view 7 --repo $R --json headRefOid")
    printf '{"headRefOid":"%s"}\n' "$(head_now)" >"$FIX/headonly.json"; serve "$FIX/headonly.json" ;;
  "api graphql -f owner=StartupBros-com -f name=hov-stack -F number=7 -f query="*)
    # A queued PR reads OPEN and in the queue for STUB_QUEUE_READS reads; then STUB_QUEUE_THEN:
    # landed (default), dropped or closed.
    n=$(count state)
    state=OPEN inq=false oid=null
    if [ -f "$FIX/queued" ] && [ ! -f "$FIX/merged" ]; then
      if [ "$n" -le "$STUB_QUEUE_READS" ]; then inq=true
      else
        case "${STUB_QUEUE_THEN:-landed}" in
          landed) touch "$FIX/merged" ;;
          dropped) ;;
          closed) state=CLOSED ;;
        esac
      fi
    fi
    if [ -f "$FIX/merged" ]; then state=MERGED oid="{\"oid\":\"$M\"}"; fi
    printf '{"data":{"repository":{"pullRequest":{"state":"%s","isInMergeQueue":%s,"mergeCommit":%s}}}}\n' \
      "$state" "$inq" "$oid" >"$FIX/state.json"
    serve "$FIX/state.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 91 ;;
esac
STUB
cat >"$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"
case "$*" in
  "rev-parse --abbrev-ref HEAD") echo "${STUB_GIT_BRANCH:-main}" ;;
  "remote get-url origin") echo "https://github.com/$R.git" ;;
  "rev-parse HEAD") echo "${STUB_GIT_TIP:-$H}" ;;
  "fetch -q origin refs/pull/7/head") exit 0 ;;
  "merge -q --ff-only --no-autostash FETCH_HEAD") exit "${STUB_GIT_FF_RC:-0}" ;;
  *) echo "unexpected git call: $*" >&2; exit 92 ;;
esac
STUB
cat >"$TMP/bin/wt-done" <<'STUB'
#!/usr/bin/env bash
printf 'DRY_RUN=%s\n' "${DRY_RUN:-unset}" >>"$WT_LOG"
echo "      activation: settings applied"
exit "${STUB_WTDONE_RC:-0}"
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/git" "$TMP/bin/wt-done"
# Closed PATH: only the tools the script and the stubs use.
for name in bash jq mktemp rm cat sleep touch grep tr cut dirname date; do
  ln -s "$(command -v "$name")" "$TMP/bin/$name"
done
cp "$SCRIPT_SRC" "$TMP/pr-land.sh"
SCRIPT="$TMP/pr-land.sh"

check_run() {   # name status conclusion [workflow] [completedAt]
  jq -nc --arg n "$1" --arg s "$2" --arg c "$3" --arg w "${4:-CI}" --arg t "${5:-2026-11-19T10:00:00Z}" \
    '{__typename: "CheckRun", name: $n, status: $s, conclusion: (if $c == "" then null else $c end),
      workflowName: $w, completedAt: (if $s == "COMPLETED" then $t else "0001-01-01T00:00:00Z" end),
      detailsUrl: "https://github.com/x/actions/runs/1/job/\($n | length)"}'
}
rollup() { jq -s '{headRefOid: "x", mergeable: "MERGEABLE", statusCheckRollup: .}'; }
runs_done() { echo '{"workflow_runs":[{"name":"CI","status":"completed"}]}'; }
runs_going() { echo '{"workflow_runs":[{"name":"CI","status":"completed"},{"name":"Deploy preview","status":"in_progress"}]}'; }
green() {
  { check_run 'Trusted syntax and policy' COMPLETED SUCCESS; check_run 'Pinned sources' COMPLETED SUCCESS
    check_run 'Public PR data check' COMPLETED SKIPPED; } | rollup
}

reset_case() {
  rm -rf "$FIX"; mkdir -p "$FIX"; : >"$GH_LOG"; : >"$GIT_LOG"; : >"$WT_LOG"
  unset STUB_CLASSIC STUB_HEAD_MOVED STUB_MERGE_RC STUB_MERGE_LANDED STUB_MERGE_STATE STUB_QUEUE_READS STUB_QUEUE_THEN
  unset STUB_GIT_BRANCH STUB_GIT_TIP STUB_GIT_FF_RC STUB_WTDONE_RC CLAUDE_LOOP_GUARD
  export PR_LAND_POLL_SECONDS=0 PR_LAND_WT_DONE="$TMP/bin/wt-done" PRO_GATE_ROUNDS_DIR="$FIX/rounds"
  mkdir -p "$FIX/rounds"
  echo "$H" >"$FIX/head"
  jq -n '{state: "OPEN", isDraft: false, baseRefName: "main", headRefName: "pr-land", headRefOid: "x",
    mergeStateStatus: "CLEAN", mergeCommit: null}' >"$FIX/pr.json"
  echo '[{"filename":"scripts/pr-land.sh"},{"filename":"tests/pr-land.test.sh"}]' >"$FIX/files.json"
  jq -n '[{type: "deletion"}, {type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
    required_status_checks: [{context: "Trusted syntax and policy"}, {context: "Pinned sources"}]}}]' >"$FIX/rules.json"
  green >"$FIX/checks.json"
  runs_done >"$FIX/runs.json"
}
run() { OUT=$(PATH="$TMP/bin" bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
merges() { grep -c -F -- 'pr merge' "$GH_LOG" || true; }
merges_at() { grep -c -F -- "--match-head-commit $1" "$GH_LOG" || true; }
gh_calls() { wc -l <"$GH_LOG" | tr -d ' '; }
reads() { cat "$FIX/$1.count" 2>/dev/null || echo 0; }
one_line() { [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]; }
landed() {   # name: exit 0, one stdout line "merged <M>", exactly one merge of $2 (default H)
  local name=$1 at=${2:-$H}
  check "$name: exit 0 (got $RC; $OUT; $ERR)" test "$RC" -eq 0
  check "$name: stdout is the one verdict line" one_line
  check "$name: verdict names the merge commit" has "$OUT" "merged $M"
  check "$name: exactly one merge call" test "$(merges)" = 1
  check "$name: the merge matched head ${at:0:6}" test "$(merges_at "$at")" = 1
}
refused() {  # name rc reason [args...]: that exit, the reason on stdout, no merge call
  local name=$1 want=$2 reason=$3; shift 3
  run "$@"
  check "$name: exit $want (got $RC; $OUT; $ERR)" test "$RC" -eq "$want"
  check "$name: names the reason" has "$OUT" "$reason"
  check "$name: one stdout line" one_line
  check "$name: no merge call" test "$(merges)" = 0
}

# --- Landing cases.
reset_case; run 7 --repo "$R"
landed 'green, not in the worktree'
check 'not in the worktree: wt-done not run' test ! -s "$WT_LOG"
check 'not in the worktree: says closeout skipped' has "$ERR" 'closeout skipped'
check 'green needs two green reads' test "$(reads checks)" = 2

reset_case; export STUB_GIT_BRANCH=pr-land; run 7 --repo "$R"
landed 'from its worktree'
check 'worktree: wt-done ran once with DRY_RUN=0' test "$(cat "$WT_LOG")" = 'DRY_RUN=0'
check 'worktree: activation line kept on stderr' has "$ERR" 'activation: settings applied'
check 'worktree: tip already the head, no fetch' bash -c '! grep -q -F fetch "$1"' _ "$GIT_LOG"

reset_case; export STUB_GIT_BRANCH=pr-land STUB_GIT_TIP=$H2; run 7 --repo "$R"
landed 'worktree tip behind the merged head'
check 'tip behind: fast-forwarded to the PR head' grep -q -F 'merge -q --ff-only --no-autostash FETCH_HEAD' "$GIT_LOG"
check 'tip behind: then wt-done' test "$(cat "$WT_LOG")" = 'DRY_RUN=0'

reset_case; export STUB_GIT_BRANCH=pr-land STUB_GIT_TIP=$H2 STUB_GIT_FF_RC=1; run 7 --repo "$R"
check 'tip cannot fast-forward: exit 4' test "$RC" -eq 4
check 'tip cannot fast-forward: still says merged' has "$OUT" "merged $M"
check 'tip cannot fast-forward: wt-done not run' test ! -s "$WT_LOG"

reset_case; export STUB_GIT_BRANCH=pr-land STUB_WTDONE_RC=3; run 7 --repo "$R"
check 'wt-done fails: exit 4' test "$RC" -eq 4
check 'wt-done fails: verdict says so' has "$OUT" 'wt-done failed, exit 3'

reset_case; export STUB_QUEUE_READS=2
jq '. + [{type: "merge_queue"}]' "$FIX/rules.json" >"$FIX/r.json" && mv "$FIX/r.json" "$FIX/rules.json"
run 7 --repo "$R"
landed 'merge queue: queued, then landed'
check 'merge queue: said it waited in the queue' has "$ERR" 'merge queue'

reset_case; export STUB_QUEUE_READS=2 STUB_QUEUE_THEN=dropped
run 7 --repo "$R"
check 'merge queue dropped the PR: exit 1' test "$RC" -eq 1
check 'merge queue dropped the PR: says it left the queue' has "$OUT" "blocked: PR #7 left main's merge queue"
check 'merge queue dropped the PR: one merge request, not retried' test "$(merges)" = 1
reset_case; export STUB_QUEUE_READS=50
run 7 --repo "$R" --queue-wait 0
check 'still queued at the deadline: exit 3' test "$RC" -eq 3

# A strict base with no queue and a behind PR: update once, wait at the new head, merge it.
reset_case
jq '.[1].parameters.strict_required_status_checks_policy = true' "$FIX/rules.json" >"$FIX/r.json" && mv "$FIX/r.json" "$FIX/rules.json"
jq '.mergeStateStatus = "BEHIND"' "$FIX/pr.json" >"$FIX/p.json" && mv "$FIX/p.json" "$FIX/pr.json"
run 7 --repo "$R"
landed 'behind on a strict base' "$H2"
check 'behind: never merged the old head' test "$(merges_at "$H")" = 0
check 'behind: one branch update' test "$(grep -c -F 'pr update-branch' "$GH_LOG")" = 1

# GitHub says BEHIND only at the merge: update, re-wait, merge the new head.
reset_case; touch "$FIX/behind"; run 7 --repo "$R"
check 'behind at merge: exit 0' test "$RC" -eq 0
check 'behind at merge: last merge at the new head' test "$(merges_at "$H2")" = 1
reset_case; touch "$FIX/behind"
run 7 --repo "$R" --updates 0
check 'behind, no updates allowed: exit 1' test "$RC" -eq 1
check 'behind, no updates allowed: says behind' has "$OUT" 'still behind'
check 'behind, no updates allowed: no branch update' bash -c '! grep -q -F update-branch "$1"' _ "$GH_LOG"

reset_case
jq --arg m "$M" '.state = "MERGED" | .mergeCommit = {oid: $m}' "$FIX/pr.json" >"$FIX/p.json" && mv "$FIX/p.json" "$FIX/pr.json"
run 7 --repo "$R"
check 'already merged: exit 0' test "$RC" -eq 0
check 'already merged: names the merge' has "$OUT" "merged $M"
check 'already merged: no merge call' test "$(merges)" = 0

reset_case; export STUB_MERGE_RC=1 STUB_MERGE_LANDED=1; run 7 --repo "$R"
check 'merge command failed but GitHub merged: exit 0' test "$RC" -eq 0
check 'merge command failed but GitHub merged: names the merge' has "$OUT" "merged $M"

# Checks pending at first, then green.
reset_case
{ check_run 'Trusted syntax and policy' IN_PROGRESS ''; check_run 'Pinned sources' QUEUED ''; } | rollup >"$FIX/checks.1.json"
run 7 --repo "$R"
landed 'pending, then green'
check 'pending, then green: three reads' test "$(reads checks)" = 3

# A re-run that passed replaces the failure it re-ran.
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED FAILURE CI 2026-11-19T09:00:00Z
  check_run 'Trusted syntax and policy' COMPLETED SUCCESS CI 2026-11-19T09:30:00Z
  check_run 'Pinned sources' COMPLETED SUCCESS; } | rollup >"$FIX/checks.json"
run 7 --repo "$R"
landed 'a passing re-run replaces its failure'

# A classic-protection-only required context that reports green.
reset_case; export STUB_CLASSIC=file
echo '{"strict": false, "contexts": ["contract"], "checks": [{"context": "contract", "app_id": 1}]}' >"$FIX/classic.json"
{ check_run 'Trusted syntax and policy' COMPLETED SUCCESS; check_run 'Pinned sources' COMPLETED SUCCESS
  check_run contract COMPLETED SUCCESS; } | rollup >"$FIX/checks.json"
run 7 --repo "$R"
landed 'classic-only required check, green'

reset_case
echo '[]' >"$FIX/rules.json"; rollup </dev/null >"$FIX/checks.json"; echo '{"workflow_runs":[]}' >"$FIX/runs.json"
run 7 --repo "$R" --wait 0 --allow-no-checks
landed 'no checks, --allow-no-checks'

# The default PR is the current branch's, found by name.
reset_case; echo '[{"number": 7, "state": "OPEN"}]' >"$FIX/list.json"; export STUB_GIT_BRANCH=pr-land
run
landed 'no PR or repo given: found by branch'
check 'no PR given: never asked gh pr view without a number' bash -c '! grep -q -x -F "pr view --repo $2" "$1"' _ "$GH_LOG" "$R"

# Pro round due (.github/) and finished clean.
reset_case; echo '[{"filename":".github/workflows/ci.yml"}]' >"$FIX/files.json"
printf '1795000000\t0\t0\n' >"$FIX/rounds/StartupBros-com-hov-stack-7.last"
run 7 --repo "$R"
landed 'Pro due, last round clean'

# Pro round left a P1; the fix was pushed after it; --pro-fixed lands it, never as a Pro pass.
reset_case; echo '[{"filename":".github/workflows/ci.yml"}]' >"$FIX/files.json"
printf '1795000000\t0\t1\n' >"$FIX/rounds/StartupBros-com-hov-stack-7.last"
echo '[{"parents":[{}],"commit":{"committer":{"date":"2026-11-18T00:00:00Z"}}},
       {"parents":[{}],"commit":{"committer":{"date":"2026-11-19T12:00:00Z"}}}]' >"$FIX/commits.json"
run 7 --repo "$R" --pro-fixed
landed 'Pro P1 fixed and pushed, --pro-fixed'
check '--pro-fixed: verdict says not a Pro pass' has "$OUT" 'not a Pro pass'

# --- Planted negatives: no merge call in any of them.
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED SUCCESS; check_run 'Pinned sources' COMPLETED SUCCESS
  check_run 'lint (optional)' COMPLETED FAILURE Lint; } | rollup >"$FIX/checks.json"
refused 'red check the base does not require' 1 'red: lint (optional) https://' 7 --repo "$R"
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED FAILURE; check_run 'Pinned sources' COMPLETED SUCCESS; } | rollup >"$FIX/checks.json"
refused 'red required check' 1 'red: Trusted syntax and policy' 7 --repo "$R"
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED CANCELLED; check_run 'Pinned sources' COMPLETED SUCCESS; } | rollup >"$FIX/checks.json"
refused 'cancelled required check counts as red' 1 'red: Trusted syntax and policy' 7 --repo "$R"
reset_case
check_run 'Trusted syntax and policy' COMPLETED SUCCESS | rollup >"$FIX/checks.json"
refused 'required check never reported' 2 'pending: checks still pending after 0s' 7 --repo "$R" --wait 0
check 'required check never reported: names it' has "$OUT" 'Pinned sources'
reset_case; export STUB_CLASSIC=file
echo '{"strict": false, "contexts": ["contract"]}' >"$FIX/classic.json"
refused 'classic-only required check missing' 2 'contract' 7 --repo "$R" --wait 0
reset_case; export STUB_CLASSIC=502
refused 'classic protection unreadable (502)' 2 'classic protection for main unreadable' 7 --repo "$R"
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED SUCCESS CI 2026-11-19T09:00:00Z
  check_run 'Trusted syntax and policy' QUEUED '' CI
  check_run 'Pinned sources' COMPLETED SUCCESS; } | rollup >"$FIX/checks.json"
refused 'old pass plus a queued re-run' 2 'Trusted syntax and policy' 7 --repo "$R" --wait 0
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED FAILURE CI 2026-11-19T09:00:00Z
  check_run 'Trusted syntax and policy' IN_PROGRESS '' CI
  check_run 'Pinned sources' COMPLETED SUCCESS; } | rollup >"$FIX/checks.json"
refused 'old failure plus a running re-run: pending, not red' 2 'pending:' 7 --repo "$R" --wait 0
reset_case; runs_going >"$FIX/runs.json"
refused 'checks green, a workflow run still going' 2 'workflow runs: Deploy preview' 7 --repo "$R" --wait 0
# A check that registers after the first green read is still caught.
reset_case
{ check_run 'Trusted syntax and policy' COMPLETED SUCCESS; check_run 'Pinned sources' COMPLETED SUCCESS
  check_run 'late gate' COMPLETED FAILURE Late; } | rollup >"$FIX/checks.2.json"
refused 'late red check after one green read' 1 'red: late gate' 7 --repo "$R"
reset_case; export CLAUDE_LOOP_GUARD=1
refused 'CLAUDE_LOOP_GUARD=1' 1 'CLAUDE_LOOP_GUARD=1' 7 --repo "$R"
check 'CLAUDE_LOOP_GUARD=1: zero gh calls' test "$(gh_calls)" = 0
reset_case; echo '[{"filename":".github/workflows/ci.yml"}]' >"$FIX/files.json"
refused 'Pro due, no round finished' 1 'a Pro round is due (.github/)' 7 --repo "$R"
reset_case; echo '[{"filename":"db/migrations/0042_add.sql"}]' >"$FIX/files.json"
refused 'Pro due by a migrations path' 1 'a migrations directory' 7 --repo "$R"
reset_case
refused 'Pro due by --pro' 1 '(--pro)' 7 --repo "$R" --pro
reset_case; echo '[{"filename":".github/workflows/ci.yml"}]' >"$FIX/files.json"
printf '1795000000\t0\t1\n' >"$FIX/rounds/StartupBros-com-hov-stack-7.last"
refused 'Pro left a P1, no --pro-fixed' 1 'left 0 open P0 and 1 open P1' 7 --repo "$R"
# --pro-fixed with nothing newer than the round, or only a base merge newer: refused.
echo '[{"parents":[{}],"commit":{"committer":{"date":"2026-11-18T00:00:00Z"}}},
       {"parents":[{},{}],"commit":{"committer":{"date":"2026-11-19T12:00:00Z"}}}]' >"$FIX/commits.json"
refused '--pro-fixed, only a base merge after the round' 1 'no commit newer than its Pro round' 7 --repo "$R" --pro-fixed
reset_case; echo '[{"filename":".github/x.yml"}]' >"$FIX/files.json"
printf 'garbage\n' >"$FIX/rounds/StartupBros-com-hov-stack-7.last"
refused 'Pro record unreadable' 1 'unreadable' 7 --repo "$R"
reset_case; jq '.isDraft = true' "$FIX/pr.json" >"$FIX/p.json" && mv "$FIX/p.json" "$FIX/pr.json"
refused 'draft PR' 1 'is a draft' 7 --repo "$R"
reset_case; jq '.state = "CLOSED"' "$FIX/pr.json" >"$FIX/p.json" && mv "$FIX/p.json" "$FIX/pr.json"
refused 'closed PR' 1 'is closed' 7 --repo "$R"
reset_case; jq '.mergeable = "CONFLICTING"' "$FIX/checks.json" >"$FIX/c.json" && mv "$FIX/c.json" "$FIX/checks.json"
refused 'conflicting PR' 1 'conflicts with main' 7 --repo "$R"
reset_case; export STUB_HEAD_MOVED=1
refused 'head moved while waiting' 2 'head moved' 7 --repo "$R"
reset_case
echo '[]' >"$FIX/rules.json"; rollup </dev/null >"$FIX/checks.json"; echo '{"workflow_runs":[]}' >"$FIX/runs.json"
refused 'no checks at all, no --allow-no-checks' 2 'no checks reported' 7 --repo "$R" --wait 0
reset_case; echo '[]' >"$FIX/list.json"; export STUB_GIT_BRANCH=pr-land
refused 'branch has no PR' 1 'has no open or merged PR' --repo "$R"
reset_case
run 7 --repo "$R" --wait soon
check 'usage error: exit 64' test "$RC" -eq 64
check 'usage error: no gh calls' test "$(gh_calls)" = 0
reset_case; export STUB_MERGE_RC=1 STUB_MERGE_STATE=BLOCKED
run 7 --repo "$R"
check 'GitHub refused the merge: exit 1' test "$RC" -eq 1
check 'GitHub refused the merge: says so' has "$OUT" 'blocked: GitHub refused the merge'
check 'GitHub refused the merge: one attempt' test "$(merges)" = 1

printf 'pr-land: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
