#!/usr/bin/env bash
# The check runs that describe a head now (dotfiles#1595): the shared filter,
# its shell helper. The fixtures capture the members app's #4201
# head 7f734ce as GitHub returned it on 2026-10-05, slimmed to the fields the
# filter reads: a ready flip and a body edit each started a run of the same
# workflows, concurrency cancelled the older ones, and the PR owner read those
# cancellations as red and parked.
# No-Claim Boundary: no GitHub call; gh is a PATH stub answering from files.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$ROOT/scripts/lib/ci-current-check-runs.sh"
LIB_DIR=${LIB%/*}
FIX="$ROOT/tests/fixtures/ci-current-check-runs"
TMP=$(mktemp -d /tmp/ci-current-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() { local name=$1; shift; if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name" >&2; fi; }

# filter <checks-pages> <runs-pages> [<settle> <hold>]: the filtered array.
filter() {
  cat "$1" "$2" | jq -sc -L "$LIB_DIR" --argjson settle "${3:-0}" --argjson hold "${4:-false}" \
    'include "ci-current-check-runs"; current_check_runs_from_pages($settle; $hold)'
}
# The red test every consumer applies: completed and not a passing conclusion.
red_names() { jq -c '[.[] | select(.status == "completed" and (.conclusion | IN("success","neutral","skipped") | not)) | .name] | sort'; }
quiet() { "$@" >/dev/null; }
is() { [ "$1" = "$2" ] || { echo "  got: $1" >&2; echo "  want: $2" >&2; return 1; }; }
pages() { jq -c "[{$1: .}]" <<<"$2" > "$3"; }
CHECKS="$FIX/acme-app-4201-checks.json" RUNS="$FIX/acme-app-4201-runs.json"

# --- the members app's #4201, as it stood when the PR merged --------------------
check 'fixture: the head carries cancelled check runs' \
  test "$(jq '[.[].check_runs[] | select(.conclusion == "cancelled")] | length' "$CHECKS")" -gt 0
check 'fixture: unfiltered, those cancellations read red' \
  test "$(jq -c '[.[].check_runs[]]' "$CHECKS" | red_names)" != '[]'
OUT=$(filter "$CHECKS" "$RUNS")
check '#4201: nothing reads red once superseded suites drop' is "$(red_names <<<"$OUT")" '[]'
check '#4201: nothing pending' is "$(jq '[.[] | select(.status != "completed")] | length' <<<"$OUT")" 0
check '#4201: one suite per workflow survives, 15 check runs' is "$(jq length <<<"$OUT")" 15
check '#4201: every survivor belongs to its workflow'"'"'s newest-created run' quiet jq -se '
  (.[1] | [.[].workflow_runs[]] | group_by([.workflow_id, .event]) | map(max_by(.created_at).check_suite_id)) as $newest |
  all(.[0][]; .check_suite.id | IN($newest[]))' <(printf '%s\n' "$OUT") "$RUNS"
# Planted negative: the newest run of the main workflow fails one job.
jq -c --argjson suite "$(jq '[.[].workflow_runs[] | select(.workflow_id == 110174891)] | max_by(.created_at).check_suite_id' "$RUNS")" '
  (first(.[].check_runs[] | select(.check_suite.id == $suite) | .id)) as $id |
  map(.check_runs |= map(if .id == $id then .conclusion = "failure" else . end))' "$CHECKS" > "$TMP/4201-red.json"
check '#4201 PLANTED: the newest run'"'"'s failure stays red' \
  test "$(filter "$TMP/4201-red.json" "$RUNS" | red_names | jq length)" = 1

# --- synthetic shapes -----------------------------------------------------------
run() { # id workflow suite status conclusion created [event]
  jq -nc --argjson id "$1" --argjson wf "$2" --argjson suite "$3" --arg status "$4" --arg concl "$5" --arg created "$6" --arg event "${7:-pull_request}" \
    '{id:$id,workflow_id:$wf,event:$event,name:"Workflow \($wf)",check_suite_id:$suite,head_sha:"abc",status:$status,conclusion:(if $concl == "" then null else $concl end),created_at:$created}'
}
cr() { # id name suite status conclusion
  jq -nc --argjson id "$1" --arg name "$2" --argjson suite "$3" --arg status "$4" --arg concl "$5" \
    '{id:$id,name:$name,head_sha:"abc",status:$status,conclusion:(if $concl == "" then null else $concl end),check_suite:{id:$suite}}'
}
T0=2026-10-05T03:33:59Z T1=2026-10-05T13:54:24Z T2=2026-10-05T14:32:36Z

# A cancel with no newer run of its workflow is a real cancel.
pages workflow_runs "[$(run 1 7 100 completed cancelled $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 10 Test 100 completed cancelled)]" "$TMP/c.json"
check 'PLANTED: a cancelled run nothing superseded stays red' is "$(filter "$TMP/c.json" "$TMP/r.json" | red_names)" '["Test"]'

# The newest run is queued and has no check run yet: it stands in as pending,
# and the green suite it superseded cannot vouch for the head meanwhile.
pages workflow_runs "[$(run 2 7 200 queued '' $T1), $(run 1 7 100 completed success $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 10 Test 100 completed success)]" "$TMP/c.json"
OUT=$(filter "$TMP/c.json" "$TMP/r.json")
check 'queued newest run stands in as one pending entry' is "$(jq -c 'map({name, status})' <<<"$OUT")" '[{"name":"workflow run: Workflow 7","status":"queued"}]'
# Once its check runs exist, they speak for it; no stand-in beside them.
pages workflow_runs "[$(run 2 7 200 in_progress '' $T1), $(run 1 7 100 completed success $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 20 Test 200 in_progress ''), $(cr 10 Test 100 completed success)]" "$TMP/c.json"
check 'a running newest run is its own check runs, no stand-in' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[20]'
# A job that needs another has no check run until that job finishes, so a run
# can list only its finished green setup job: the head is still pending.
pages check_runs "[$(cr 21 Scope 200 completed success), $(cr 10 Test 100 completed success)]" "$TMP/c.json"
OUT=$(filter "$TMP/c.json" "$TMP/r.json")
check 'PLANTED: a running run listing only a green setup job holds the head pending' \
  is "$(jq -c 'map([.id, .status])' <<<"$OUT")" '[[21,"completed"],["workflow-run-2","in_progress"]]'
check 'PLANTED: that stand-in says how many jobs the run lists so far' \
  is "$(jq -r '.[] | select(.id == "workflow-run-2") | .output.summary' <<<"$OUT")" \
  'workflow run 2 (pull_request) is in_progress, and every job it lists so far (1) has finished'
check 'PLANTED: no consumer can read that head as green' \
  is "$(jq '(length > 0) and all(.[]; .status == "completed")' <<<"$OUT")" false
# While a listed job runs, that job holds the head and no stand-in joins it.
pages check_runs "[$(cr 21 Scope 200 completed success), $(cr 20 Test 200 in_progress ''), $(cr 10 Test 100 completed success)]" "$TMP/c.json"
check 'PLANTED: a running listed job holds the head alone' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[21,20]'
# The PR owner's stall clock restarts a row whenever its status or conclusion
# changes. A run still unfinished past that bound, while its jobs move, is not
# a stall; a stand-in unchanged past it is.
. "$ROOT/scripts/lib/pr-owner-state.sh"
stall_poll() { # <checks> <now> <old-tracks>: sets OUT and TRACKS
  pages check_runs "$1" "$TMP/c.json"
  OUT=$(filter "$TMP/c.json" "$TMP/r.json")
  TRACKS=$(pr_owner_ci_track "$TMP/owner-state" abc 0 "$3" "$OUT" "$2")
}
SETUP=$(cr 21 Scope 200 completed success) OLD=$(cr 10 Test 100 completed success)
stall_poll "[$SETUP, $OLD]" 0 '{}'
stall_poll "[$SETUP, $(cr 20 Test 200 in_progress ''), $OLD]" 3600 "$TRACKS"
stall_poll "[$SETUP, $(cr 20 Test 200 completed success), $OLD]" 25000 "$TRACKS"
check 'PLANTED: a run unfinished past the stall bound while its jobs move is no stall' \
  is "$(pr_owner_ci_stale "$OUT" "$TRACKS" 25000)" ''
stall_poll "[$SETUP, $OLD]" 0 '{}'
stall_poll "[$SETUP, $OLD]" 25000 "$TRACKS"
check 'a stand-in unchanged past the stall bound is a stall' \
  is "$(pr_owner_ci_stale "$OUT" "$TRACKS" 25000 | jq -r .id)" workflow-run-2
# Control: the same run finished green speaks through its check runs alone.
pages workflow_runs "[$(run 2 7 200 completed success $T1), $(run 1 7 100 completed success $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 22 Test 200 completed success), $(cr 21 Scope 200 completed success), $(cr 10 Test 100 completed success)]" "$TMP/c.json"
check 'a finished green run is its own check runs, no stand-in' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[22,21]'

# A re-run of the superseded run starts later but was created earlier: the run
# that replaced it still decides (a re-run replays the original, draft, event).
pages workflow_runs "[$(run 2 7 200 completed success $T1), $(run 1 7 100 completed failure $T0 | jq -c --arg t "$T2" '.run_started_at = $t | .run_attempt = 2')]" "$TMP/r.json"
pages check_runs "[$(cr 10 Test 100 completed failure), $(cr 20 Test 200 completed success)]" "$TMP/c.json"
check 'a later re-run of a superseded run does not displace its replacement' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[20]'

# One workflow file run by two events: both runs are current.
pages workflow_runs "[$(run 2 7 200 completed success $T1 pull_request_target), $(run 1 7 100 completed failure $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 20 Gate 200 completed success), $(cr 10 Test 100 completed failure)]" "$TMP/c.json"
check 'each event keeps its own newest run' is "$(filter "$TMP/c.json" "$TMP/r.json" | red_names)" '["Test"]'

# A newer run that skipped every job (an `edited` run filtering that action
# out) tested nothing: the older run still decides.
pages workflow_runs "[$(run 2 7 200 completed success $T1), $(run 1 7 100 completed failure $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 20 Test 200 completed skipped), $(cr 10 Test 100 completed failure)]" "$TMP/c.json"
check 'PLANTED: a newer run that skipped every job leaves the older failure red' is "$(filter "$TMP/c.json" "$TMP/r.json" | red_names)" '["Test"]'
pages check_runs "[$(cr 20 Test 200 completed skipped), $(cr 10 Test 100 completed success)]" "$TMP/c.json"
check 'a newer run that skipped every job leaves the older green standing' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[10]'
pages check_runs "[$(cr 21 Lint 200 completed success), $(cr 20 Test 200 completed skipped), $(cr 10 Test 100 completed failure)]" "$TMP/c.json"
check 'a newer run that ran one job decides, skipped jobs and all' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[21,20]'

# A newest run that failed before any job existed (a broken workflow file) is
# red, not absent, and says which run and why; one that finished green with
# none listed (a listing gap) holds the head pending, never an empty answer.
pages workflow_runs "[$(run 2 7 200 completed startup_failure $T1), $(run 1 7 100 completed success $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 10 Test 100 completed success)]" "$TMP/c.json"
check 'PLANTED: a newest run that failed with no check run reads red' is "$(filter "$TMP/c.json" "$TMP/r.json" | red_names)" '["workflow run: Workflow 7"]'
check 'PLANTED: that red stand-in names its run, event and conclusion for the fixer' \
  is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -r '.[] | select(.id == "workflow-run-2") | .output.summary')" \
  'workflow run 2 (pull_request) concluded startup_failure before any job ran'
pages workflow_runs "[$(run 1 7 100 completed success $T0)]" "$TMP/r.json"
pages check_runs '[]' "$TMP/c.json"
check 'PLANTED: a green run with no check run listed waits for its jobs' \
  is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map([.id, .status])')" '[["workflow-run-1","pending"]]'
# The same gap over an older failure: the failure no longer counts, and the
# head waits instead of reading as untested (an empty answer is "no CI" to
# pro-gate-loop's standalone wait).
pages workflow_runs "[$(run 2 7 200 completed success $T1), $(run 1 7 100 completed failure $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 10 Test 100 completed failure)]" "$TMP/c.json"
check 'PLANTED: a newer green run with no check run listed holds an older failure pending, not empty' \
  is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map([.id, .status])')" '[["workflow-run-2","pending"]]'

# Check runs no listed workflow run claims (another app, a missing suite) pass.
pages workflow_runs "[$(run 2 7 200 completed success $T1), $(run 1 7 100 completed cancelled $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 30 'Other app' 999 completed failure), $(cr 10 Test 100 completed cancelled), $(cr 20 Test 200 completed success), {\"id\":31,\"name\":\"No suite\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" "$TMP/c.json"
check 'check runs from other apps pass through unchanged' is "$(filter "$TMP/c.json" "$TMP/r.json" | jq -c 'map(.id)')" '[30,20,31]'

# The settle hold: after a ready flip at $T1, runs created before it cannot
# vouch for the head until a run created at or after it appears.
SETTLE=$(jq -n --arg t "$T1" '$t | fromdateiso8601')
pages workflow_runs "[$(run 1 7 100 completed success $T0)]" "$TMP/r.json"
pages check_runs "[$(cr 10 Test 100 completed success)]" "$TMP/c.json"
check 'settle hold: only older runs listed holds the head pending' is "$(filter "$TMP/c.json" "$TMP/r.json" "$SETTLE" true | jq -c '[.[] | select(.status != "completed") | .id]')" '["ready-flip-settle"]'
check 'settle hold released: the older green stands' is "$(filter "$TMP/c.json" "$TMP/r.json" "$SETTLE" false | jq -c '[.[] | select(.status != "completed")]')" '[]'
pages workflow_runs "[$(run 2 7 200 queued '' $T1), $(run 1 7 100 completed success $T0)]" "$TMP/r.json"
check 'settle hold: a run created at the flip ends it' is "$(filter "$TMP/c.json" "$TMP/r.json" "$SETTLE" true | jq -c 'map(.id)')" '["workflow-run-2"]'

# Strict input: anything but two page arrays is an error, never a shorter list.
check 'PLANTED: one document is an error' bash -c '! jq -sc -L "$1" "include \"ci-current-check-runs\"; current_check_runs_from_pages(0; false)" "$2" >/dev/null 2>&1' _ "$LIB_DIR" "$CHECKS"
check 'PLANTED: an object where a page array belongs is an error' bash -c '! printf "%s\n" "{}" "[]" | jq -sc -L "$1" "include \"ci-current-check-runs\"; current_check_runs_from_pages(0; false)" >/dev/null 2>&1' _ "$LIB_DIR"
check 'PLANTED: a check-runs page without its array is an error' bash -c '! printf "%s\n" "[{}]" "[{\"workflow_runs\":[]}]" | jq -sc -L "$1" "include \"ci-current-check-runs\"; current_check_runs_from_pages(0; false)" >/dev/null 2>&1' _ "$LIB_DIR"
check 'PLANTED: a workflow-runs page with a null array is an error' bash -c '! printf "%s\n" "[{\"check_runs\":[]}]" "[{\"workflow_runs\":null}]" | jq -sc -L "$1" "include \"ci-current-check-runs\"; current_check_runs_from_pages(0; false)" >/dev/null 2>&1' _ "$LIB_DIR"

# --- a workflow-runs listing that leaves an Actions suite unclaimed (#1636) -----
# The members app's #4284 head 38ae426 as GitHub returns it now, limited to the runs
# created before the PR owner's 08:15:27Z read on 2026-10-06, which sent a fix
# session for the cancelled `acme-schema-gate` although the run
# that replaced it had finished green ten minutes earlier.
C4284="$FIX/acme-app-4284-checks.json" R4284="$FIX/acme-app-4284-runs.json"
OUT=$(filter "$C4284" "$R4284")
check '#4284: the complete listing drops the cancelled Readback, nothing red' is "$(red_names <<<"$OUT")" '[]'
check '#4284: the green Readback that replaced it is kept' \
  is "$(jq -c '[.[] | select(.name == "acme-schema-gate") | .id]' <<<"$OUT")" '[112170265647]'
# no_verdict <checks> <runs>: the filter refuses, printing nothing.
no_verdict() { local out rc; out=$(filter "$1" "$2" 2>"$TMP/gap.err"); rc=$?; [ "$rc" -ne 0 ] && [ -z "$out" ]; }
jq -c 'map(.workflow_runs |= map(select(.id != 37433696414)) | .total_count = (.workflow_runs | length))' "$R4284" > "$TMP/4284-short.json"
check '#4284 PLANTED: a listing without the newer run gives no verdict' no_verdict "$C4284" "$TMP/4284-short.json"
check '#4284 PLANTED: the refusal names the unclaimed suite' grep -q '101394719140' "$TMP/gap.err"
jq -c 'map(.workflow_runs |= map(select(.id != 37433692811)) | .total_count = (.workflow_runs | length))' "$R4284" > "$TMP/4284-old-missing.json"
check '#4284 PLANTED: a listing without the older run gives no verdict' no_verdict "$C4284" "$TMP/4284-old-missing.json"
jq -c 'map(.workflow_runs = [] | .total_count = 0)' "$R4284" > "$TMP/4284-empty.json"
check '#4284 PLANTED: an empty listing gives no verdict' no_verdict "$C4284" "$TMP/4284-empty.json"
# Only GitHub Actions suites are listed as workflow runs. Another app's suite
# passes through as before, and so does a row naming no app at all.
acr() { cr "$@" | jq -c '.app = {slug: "github-actions"}'; }
pages workflow_runs "[$(run 2 7 200 completed success $T1)]" "$TMP/r.json"
pages check_runs "[$(acr 20 Test 200 completed success), $(cr 30 External 900 completed failure | jq -c '.app = {slug: "other-ci"}'), $(cr 31 Plain 901 completed success)]" "$TMP/c.json"
OUT=$(filter "$TMP/c.json" "$TMP/r.json")
check 'another app'"'"'s suite, and a row naming no app, pass through' is "$(jq -c 'map(.id)' <<<"$OUT"),$(red_names <<<"$OUT")" '[20,30,31],["External"]'

# --- the shell helper, over a stub gh ------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  *'/commits/'*'/check-runs '*) [ "${GH_FAIL:-}" != checks ] || exit 1; cat "$GH_CHECKS" ;;
  *'/actions/runs?head_sha='*) [ "${GH_FAIL:-}" != runs ] || exit 1; [ "${GH_EMPTY:-}" != runs ] || exit 0
    # GH_RUNS_SEQ: read N answers <dir>/N.json, or <dir>/last.json past them.
    if [ -n "${GH_RUNS_SEQ:-}" ]; then
      n=$(( $(cat "$GH_RUNS_SEQ/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_RUNS_SEQ/n"
      if [ -f "$GH_RUNS_SEQ/$n.json" ]; then cat "$GH_RUNS_SEQ/$n.json"; else cat "$GH_RUNS_SEQ/last.json"; fi
    else cat "$GH_RUNS"; fi ;;
  *) echo "unexpected gh: $*" >&2; exit 91 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/gh-calls" GH_CHECKS="$CHECKS" GH_RUNS="$RUNS"
helper() { PATH="$TMP/bin:$PATH" bash -c 'source "$1/ci-current-check-runs.sh" && ci_current_check_runs Org/repo 7f734ce "${@:2}"' _ "$LIB_DIR" "$@"; }
: > "$GH_CALLS"
OUT=$(helper)
check 'helper: #4201 through the stub keeps 15, none red' is "$(jq length <<<"$OUT"),$(red_names <<<"$OUT")" '15,[]'
check 'helper: both endpoints paginate and slurp' is "$(grep -c -- '--paginate --slurp' "$GH_CALLS")" 2
OUT=$(GH_FAIL=runs helper); RC=$?
check 'PLANTED helper: an unreadable workflow-runs endpoint fails, printing nothing' test "$RC" -ne 0 -a -z "$OUT"
OUT=$(GH_EMPTY=runs helper 2>/dev/null); RC=$?
check 'PLANTED helper: an empty workflow-runs answer fails, printing nothing' test "$RC" -ne 0 -a -z "$OUT"
FUTURE=$(( $(date +%s) + 600 ))
holds() { jq -c '[.[] | select(.id == "ready-flip-settle")] | length'; }
# #4201 lists runs created at $T1, so a settle point there is already met.
check 'helper: runs created at or after the settle point end the hold' is "$(helper "$SETTLE" "$FUTURE" | holds)" 0
LATE=$(jq -n '"2026-10-05T15:00:00Z" | fromdateiso8601')
check 'helper: a settle point after every listed run holds while the bound is live' is "$(helper "$LATE" "$FUTURE" | holds)" 1
check 'helper: a past bound holds nothing' is "$(helper "$LATE" 1 2>/dev/null | holds)" 0
# The bound passing with no run since the update is logged, once per read.
notice() { helper "$@" 2>&1 >/dev/null | grep -c '^ci-current: no workflow run at 7f734ce was created after the update at 2026-10-05T15:00:00Z'; }
check 'helper: a spent bound with no run since the update says so' is "$(notice "$LATE" 1)" 1
check 'PLANTED helper: a run since the update leaves nothing to report' is "$(helper "$SETTLE" 1 2>&1 >/dev/null | wc -l)" 0
check 'PLANTED helper: a live hold reports nothing yet' is "$(helper "$LATE" "$FUTURE" 2>&1 >/dev/null | wc -l)" 0

# A listing that leaves an Actions suite unclaimed is read again; one that
# stays short is a failed read, never a verdict (dotfiles#1636).
export CI_CURRENT_RETRY_SECS=0
SEQ="$TMP/runs-seq"; mkdir -p "$SEQ"
cp "$TMP/4284-short.json" "$SEQ/1.json"; cp "$R4284" "$SEQ/last.json"
: > "$GH_CALLS"
OUT=$(GH_CHECKS="$C4284" GH_RUNS_SEQ="$SEQ" helper 2>"$TMP/err"); RC=$?
check 'helper: a short listing is read again, and the complete one decides' is "$RC:$(red_names <<<"$OUT")" '0:[]'
check 'helper: both endpoints were read twice' is "$(grep -c -- '--paginate --slurp' "$GH_CALLS")" 4
check 'helper: the gap it read past is on stderr' \
  grep -q '^ci-current: read 1 of 3 at 7f734ce: no listed workflow run claims GitHub Actions suite 101394719140 (5 runs listed, total_count 5)' "$TMP/err"
rm -f "$SEQ/n" "$SEQ/1.json"; cp "$TMP/4284-short.json" "$SEQ/last.json"
: > "$GH_CALLS"
OUT=$(GH_CHECKS="$C4284" GH_RUNS_SEQ="$SEQ" helper 2>"$TMP/err"); RC=$?
check 'PLANTED helper: a listing short on every read fails, printing nothing' test "$RC" -ne 0 -a -z "$OUT"
check 'PLANTED helper: it reads three times by default' is "$(grep -c 'actions/runs' "$GH_CALLS")" 3
check 'PLANTED helper: the last line says the read failed and why' \
  grep -q '^ci-current: read 3 of 3 at 7f734ce: no listed workflow run claims GitHub Actions suite 101394719140 (5 runs listed, total_count 5); failing the read$' <(tail -n 1 "$TMP/err")
rm -f "$SEQ/n"; cp "$TMP/4284-empty.json" "$SEQ/last.json"
: > "$GH_CALLS"
OUT=$(GH_CHECKS="$C4284" GH_RUNS_SEQ="$SEQ" CI_CURRENT_READ_TRIES=1 helper 2>"$TMP/err"); RC=$?
check 'PLANTED helper: an empty listing fails after CI_CURRENT_READ_TRIES reads' is "$RC:$(grep -c 'actions/runs' "$GH_CALLS"):${OUT:-none}" '1:1:none'
check 'PLANTED helper: an empty listing names every unclaimed suite' \
  grep -q 'claims GitHub Actions suites 101394709050, 101394714822, 101394714841, 101394717919, 101394719140 (0 runs listed, total_count 0)' "$TMP/err"
# A read count that is not a number bounds the loop too; under timeout, so a
# helper that rereads forever fails here instead of hanging the suite.
rm -f "$SEQ/n"; cp "$TMP/4284-short.json" "$SEQ/last.json"
: > "$GH_CALLS"
OUT=$(GH_CHECKS="$C4284" GH_RUNS_SEQ="$SEQ" CI_CURRENT_READ_TRIES=three PATH="$TMP/bin:$PATH" timeout 20 \
  bash -c 'source "$1/ci-current-check-runs.sh" && ci_current_check_runs Org/repo 7f734ce' _ "$LIB_DIR" 2>"$TMP/err"); RC=$?
check 'PLANTED helper: a read count that is not a number fails after one read' is "$RC:$(grep -c 'actions/runs' "$GH_CALLS"):${OUT:-none}" '1:1:none'
check 'PLANTED helper: the malformed count is named on stderr' grep -q 'three: integer expression expected' "$TMP/err"

# --- a draft head's local suite record (dotfiles#1598) ---------------------------
# The runner is a stub answering --read from $FAKE/rec.json and recording each
# run; the real runner's --read and --applies are run-affected-suites' own tests.
FAKE="$TMP/local-suites"; mkdir -p "$FAKE/tree"
cat > "$FAKE/runner.py" <<'PY'
import json, os, shutil, sys
fake = os.environ["FAKE"]
args = sys.argv[1:]
if "--applies" in args:
    if os.path.exists(os.path.join(fake, "applies-broken")):
        sys.stderr.write("runner: cannot load the workflow\n")
        sys.exit(2)
    sys.exit(0 if os.path.exists(os.path.join(fake, "applies")) else 1)
if "--read" in args:
    path = os.path.join(fake, "rec.json")
    if os.path.exists(os.path.join(fake, "unreadable")):
        sys.stderr.write("affected-suites: unreadable record /fake/rec.json: Expecting value\n")
        sys.exit(2)
    if not os.path.exists(path):
        sys.exit(4)
    print(open(path).read().strip())
    sys.exit(0)
with open(os.path.join(fake, "calls"), "a") as fh:
    fh.write(" ".join(args) + " cwd=" + os.getcwd() + "\n")
print("runner output line")
nxt = os.path.join(fake, "next.json")
if os.path.exists(nxt):
    shutil.copy(nxt, os.path.join(fake, "rec.json"))
PY
git -C "$FAKE/tree" init -q && git -C "$FAKE/tree" -c user.email=t@e -c user.name=t commit -q --allow-empty -m one
TREE_SHA=$(git -C "$FAKE/tree" rev-parse HEAD)
beat() { echo "$*" >> "$FAKE/beats"; }
lsr() { local_suites_result "$@"; }
reset_fake() { rm -f "$FAKE/rec.json" "$FAKE/next.json" "$FAKE/calls" "$FAKE/beats" "$FAKE/unreadable"; }
# shellcheck source=../scripts/lib/ci-current-check-runs.sh
source "$LIB"
export FAKE
# shellcheck disable=SC2034  # read by the sourced lib's functions
LOCAL_SUITES_RUNNER="$FAKE/runner.py" LOCAL_SUITES_RUN_SECS=120

reset_fake; printf '{"outcome":"pass","sha":"%s","log":"/x.log"}\n' "$TREE_SHA" > "$FAKE/rec.json"
OUT=$(lsr "$FAKE/tree" "$TREE_SHA" beat 2>"$FAKE/err"); RC=$?
check 'record: pass is green and printed' is "$RC:$(jq -r .outcome <<<"$OUT")" 0:pass
check 'record: present, the runner never runs and no heartbeat is spent' test ! -e "$FAKE/calls" -a ! -e "$FAKE/beats"
check 'record: says which evidence it read' grep -q "draft: reading local result at ${TREE_SHA:0:7}" "$FAKE/err"
reset_fake; echo '{"outcome":"partial"}' > "$FAKE/rec.json"
lsr "$FAKE/tree" "$TREE_SHA" >/dev/null 2>&1; check 'record: partial is green' test "$?" -eq 0
reset_fake; echo '{"outcome":"fail"}' > "$FAKE/rec.json"
lsr "$FAKE/tree" "$TREE_SHA" >/dev/null 2>&1; check 'record: fail is red' test "$?" -eq 1
reset_fake; echo '{"outcome":"bogus"}' > "$FAKE/rec.json"
lsr "$FAKE/tree" "$TREE_SHA" >/dev/null 2>&1; check 'record: an unknown outcome is no evidence, never green' test "$?" -eq 2

reset_fake; echo '{"outcome":"pass"}' > "$FAKE/next.json"
OUT=$(lsr "$FAKE/tree" "$TREE_SHA" beat 2>"$FAKE/err"); RC=$?
check 'absent: runs once and reads what it recorded' is "$RC:$(jq -r .outcome <<<"$OUT"):$(wc -l < "$FAKE/calls")" "0:pass:1"
check 'absent: the heartbeat covers the run bound first' is "$(cat "$FAKE/beats")" 180
check 'absent: runs from the tree with its own workflow' grep -qF -- "--repo $FAKE/tree cwd=$FAKE/tree" "$FAKE/calls"
check 'absent: logs the invocation' grep -q 'draft: no local result at .*; running timeout 120 python3' "$FAKE/err"

reset_fake
lsr "$FAKE/tree" "$TREE_SHA" beat >/dev/null 2>"$FAKE/err"; RC=$?
check 'absent: a run that records nothing is no evidence, with its last lines' is "$RC:$(grep -c 'runner output line' "$FAKE/err")" 2:1

reset_fake; echo '{"outcome":"pass"}' > "$FAKE/next.json"
lsr "$FAKE/tree" "$(printf 'f%.0s' {1..40})" beat >/dev/null 2>"$FAKE/err"; RC=$?
check 'absent: a tree at another head never runs' is "$RC:$([ -e "$FAKE/calls" ] && echo ran || echo idle)" 2:idle

reset_fake; echo '{"outcome":"pass"}' > "$FAKE/next.json"
lsr "$FAKE/tree" "$TREE_SHA" false >/dev/null 2>&1; RC=$?
check 'absent: a failed heartbeat never starts the run' is "$RC:$([ -e "$FAKE/calls" ] && echo ran || echo idle)" 2:idle

# The runner's stderr is the cause of an unreadable record; it follows the
# lib's own line, so the last line a caller keeps (pr-owner's park reason)
# names it (CE review of #1612).
reset_fake; : > "$FAKE/unreadable"
lsr "$FAKE/tree" "$TREE_SHA" beat >/dev/null 2>"$FAKE/err"; RC=$?
check 'unreadable: no evidence, and the runner never runs' is "$RC:$([ -e "$FAKE/calls" ] && echo ran || echo idle)" 2:idle
check 'unreadable: the reader'"'"'s cause is the last line' is "$(tail -n 1 "$FAKE/err")" 'affected-suites: unreadable record /fake/rec.json: Expecting value'
check 'unreadable: the lib says which read failed first' grep -q "draft: cannot read the local result at ${TREE_SHA:0:7} (runner exit 2)" "$FAKE/err"

local_suites_applies "$FAKE/tree"
check 'applies: a repository without the gate is rejected' test "$?" -eq 1
: > "$FAKE/applies"
local_suites_applies "$FAKE/tree"
check 'applies: the runner'"'"'s predicate passes through' test "$?" -eq 0
: > "$FAKE/applies-broken"
local_suites_applies "$FAKE/tree" 2>"$FAKE/err"
check 'applies: a runner that cannot answer is neither answer' test "$?" -eq 2
check 'applies: the runner'"'"'s stderr is kept' grep -q 'runner: cannot load the workflow' "$FAKE/err"
rm -f "$FAKE/applies-broken"
local_suites_applies '' 2>"$FAKE/err"
check 'applies: no tree is a usage error, never a question to the runner' is "$?:$(cat "$FAKE/err")" '2:local_suites_applies: no tree given'

echo "ci-current-check-runs: $pass passed, $fail failed"
[ "$fail" = 0 ]
