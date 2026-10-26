#!/usr/bin/env bash
# Whether a head's red CI is only a runner stall (dotfiles#1605): the shared
# filter and its shell helper. The fixtures are real records from
# StartupBros-com/hov-stack: each job record (slimmed to the fields the filter
# reads) and its check run's annotations as GitHub returned them.
#   111987568844  #1597's core shard: every step success, `Complete job` at
#                 21:48:20Z, cancelled at 21:57:09Z; annotation "The job has
#                 exceeded the maximum execution time of 20m0s"
#   111996702903  the same run's `Harness suites` gate, red only because it
#                 requires every shard green; annotation "a harness shard
#                 concluded 'cancelled'"
#   111637998248  #1568's mid-step stall: step 175 still in_progress, the
#                 post steps pending; the same cap annotation
#   111626142608  #1568's cancelled core shard whose step 160 genuinely
#                 failed: the cap annotation and "Process completed with exit
#                 code 1." -- a live runner's verdict, never a stall
#   112732924539  #1660's core shard (run 37603350460), fetched 2026-10-13
#                 20:58Z: cancelled at 10:15:48Z with the cap annotation,
#                 step 129 in progress since 10:14:49Z, sixty later steps
#                 pending, every other step success -- the timeout while
#                 advancing that the owner's retry and the resume stage serve
#   112742237694  the same run's `Harness suites` gate, started 10:15:50Z
#   112732924539-no-steps  the same job as GitHub also served it, with an
#                 empty step list: five fetches within a minute of the
#                 189-step one (README-timeout-signatures.md)
#   112732924539-hung  SYNTHETIC: the 189-step record with step 129
#                 concluded `cancelled` by the cap, a live runner's hang
#   115594417972  a job that never started: `Install smoke` of run
#                 38484390722, cancelled while queued on 2026-10-13 when a
#                 newer run pre-empted it; no steps, runner 0, started at its
#                 queue time, annotation "Canceling since a higher priority
#                 waiting request ... exists"
#   112919103444  a job that never started with no runner at all: the core
#                 shard of run 37658273294, cancelled on 2026-10-07 as it was
#                 created (runner null, completed a second before created);
#                 no steps, no annotation
#   111637998248-no-steps  the #1568 mid-step stall as GitHub also served it
#                 on 2026-10-14 00:21Z: no steps, but its runner 110679 and a
#                 start 135 seconds after its creation (the captured glitch
#                 read, README-timeout-signatures.md)
# No-Claim Boundary: no GitHub call; gh is a PATH stub answering from files.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$ROOT/scripts/lib/ci-stall-classify.sh"
LIB_DIR=${LIB%/*}
FIX="$ROOT/tests/fixtures/ci-stall-classify"
TMP=$(mktemp -d /tmp/ci-stall-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() { local name=$1; shift; if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name" >&2; fi; }
is() { [ "$1" = "$2" ] || { echo "  got: $1" >&2; echo "  want: $2" >&2; return 1; }; }

# record <id>: the job record joined with its annotation messages, the shape
# ci-stall-classify.sh hands the filter.
record() {
  jq -s '.[0] + {annotations: [.[1][] | .message], annotation_records: .[1]}' "$FIX/job-$1.json" "$FIX/annotations-$1.json" > "$TMP/rec-$1.json"
  printf '%s\n' "$TMP/rec-$1.json"
}
STALL=$(record 111987568844) GATE=$(record 111996702903)
MIDSTEP=$(record 111637998248) FAILED=$(record 111626142608)
CORE1660=$(record 112732924539) GATE1660=$(record 112742237694)
HUNG1660=$(record 112732924539-hung) NEVER=$(record 115594417972)
NORUNNER=$(record 112919103444)

# stalled <record-file>: ci_stalled_job over one record.
stalled() { jq -c -L "$LIB_DIR" 'include "ci-stall-classify"; ci_stalled_job' "$1"; }
# only <record-file|null>...: ci_stall_only over one entry per red check.
only() {
  local f
  for f in "$@"; do if [ "$f" = null ]; then echo null; else cat "$f"; fi; done \
    | jq -sc -L "$LIB_DIR" 'include "ci-stall-classify"; ci_stall_only'
}

# --- the classifier over real records --------------------------------------------
check 'fixture: the #1597 core shard was cancelled with every step success' is \
  "$(jq -c '[.conclusion, ([.steps[].conclusion] | unique)]' "$STALL")" '["cancelled",["success"]]'
check 'fixture: the #1597 core shard carries the cap annotation' is \
  "$(jq -c '.annotations' "$STALL")" '["The job has exceeded the maximum execution time of 20m0s"]'
check '#1597 core shard: a finalize stall' is "$(stalled "$STALL")" true
check '#1597 gate: red, but not itself a stall' is "$(stalled "$GATE")" false
check '#1597 run: the stall and the gate it failed are stall-only' is "$(only "$STALL" "$GATE")" true
check '#1597 run: the stall alone (before the gate concluded) is stall-only' is "$(only "$STALL")" true
check 'fixture: #1568 mid-step stall has an open step with a start time' is \
  "$(jq -c '[.steps[] | select(.status == "in_progress") | (.started_at != null and .completed_at == null)]' "$MIDSTEP")" '[true]'
check '#1568 mid-step: a stall' is "$(stalled "$MIDSTEP")" true
check 'fixture: #1660 core shard has step 129 open and no verdict but success' is \
  "$(jq -c '[[.steps[] | select(.status == "in_progress") | .number], ([.steps[].conclusion] | unique)]' "$CORE1660")" '[[129],[null,"success"]]'
check '#1660 core shard: timeout while advancing is a stall' is "$(stalled "$CORE1660")" true
check '#1660 run: the stall and the gate it failed are stall-only' is "$(only "$CORE1660" "$GATE1660")" true
check 'fixture: the synthetic hang differs from #1660 only at step 129' is \
  "$(jq -sc '[.[0].steps, .[1].steps] | transpose | map(select(.[0] != .[1]) | .[1] | [.number, .conclusion])' "$CORE1660" "$HUNG1660")" '[[129,"cancelled"]]'

# --- planted negatives --------------------------------------------------------------
check 'PLANTED #1568: a capped job whose step failed is not a stall' is "$(stalled "$FAILED")" false
check 'PLANTED #1568: its run is not stall-only' is "$(only "$FAILED")" false
# A live runner marks the step the cap interrupted cancelled and still runs the
# post steps: the hung-test case, which a fix session must see.
jq '(.steps[] | select(.number == 160)) |= (.conclusion = "cancelled")' "$STALL" > "$TMP/hung.json"
check 'PLANTED hung step: a step the cap cancelled is not a stall' is "$(stalled "$TMP/hung.json")" false
check 'PLANTED #1660 hung: the cap cancelled the open step, not a stall' is "$(stalled "$HUNG1660")" false
check 'PLANTED #1660 hung run: with its gate, not stall-only' is "$(only "$HUNG1660" "$GATE1660")" false
# A person's cancel leaves no cap annotation, finished steps or an open one.
jq '.annotations = []' "$STALL" > "$TMP/manual.json"
check 'PLANTED manual cancel after the last step: no cap annotation, not a stall' is "$(stalled "$TMP/manual.json")" false
jq '.annotations = []' "$MIDSTEP" > "$TMP/manual-open.json"
check 'PLANTED manual cancel with a step open: no cap annotation, not a stall' is "$(stalled "$TMP/manual-open.json")" false
jq '.steps = []' "$STALL" > "$TMP/nosteps.json"
check 'PLANTED never started: no successful step is not a stall' is "$(stalled "$TMP/nosteps.json")" false
check 'PLANTED a non-Actions red check beside a stall run is not stall-only' is "$(only "$STALL" null)" false
jq '.run_id = 1 | .id = 2 | .conclusion = "failure"' "$GATE" > "$TMP/other-run.json"
check 'PLANTED a red job in another run beside a stall run is not stall-only' is "$(only "$STALL" "$TMP/other-run.json")" false
check 'PLANTED the gate alone, its stall not read, is not stall-only' is "$(only "$GATE")" false
check 'PLANTED nothing red is not stall-only' is "$(jq -nc -L "$LIB_DIR" 'include "ci-stall-classify"; [] | ci_stall_only')" false
# A shard that ran beside the stalled one and failed a step: same run, but it
# started before the stall ended, so its red is its own (adversarial round 1).
jq --argjson run "$(jq .run_id "$STALL")" '.run_id = $run | .started_at = "2026-10-05T21:34:40Z" | .completed_at = "2026-10-05T21:44:57Z"' "$FAILED" > "$TMP/beside.json"
check 'PLANTED a failed shard that ran beside the stall, same run, is not stall-only' is "$(only "$STALL" "$TMP/beside.json")" false
check 'PLANTED the same shard with the gate is still not stall-only' is "$(only "$STALL" "$GATE" "$TMP/beside.json")" false
jq '.started_at = "2026-10-05T21:57:00Z"' "$GATE" > "$TMP/gate-early.json"
check 'PLANTED a gate that started before the stall ended is not downstream of it' is "$(only "$STALL" "$TMP/gate-early.json")" false
# A job that merely started late, after the stall ended, and failed on its own
# evidence: no annotation attributes its red to a cancellation (CE review).
jq --argjson run "$(jq .run_id "$STALL")" '.run_id = $run | .id = 3 | .started_at = "2026-10-05T21:57:20Z" | .annotations = ["Process completed with exit code 1."]' "$GATE" > "$TMP/late-failure.json"
check 'PLANTED a job that started after the stall and failed on its own is not stall-only' is "$(only "$STALL" "$TMP/late-failure.json")" false

# Fractional seconds parse to the same decision.
jq '.started_at = "2026-10-05T21:57:26.400Z"' "$GATE" > "$TMP/gate-frac.json"
jq '.completed_at = "2026-10-05T21:57:09.123Z"' "$STALL" > "$TMP/stall-frac.json"
check 'fractional-second times: still stall-only' is "$(only "$TMP/stall-frac.json" "$TMP/gate-frac.json")" true

# A record served without steps (pro-gate rounds 1 and 2 P2 on #1766). Two
# readings need no steps: a job that never started, which GitHub serves with
# no runner and a start equal to its queue time, is read on that evidence (on
# its own it is no stall, a test red); and the filter never reads a downstream
# job's steps, so a never-started job queued after a stalled sibling of its
# own run ended is downstream of that stall. Every other step-less record,
# the finished job GitHub served without its steps first, is unreadable.
unreadable() {
  local f
  for f in "$@"; do if [ "$f" = null ]; then echo null; else cat "$f"; fi; done \
    | jq -sc -L "$LIB_DIR" 'include "ci-stall-classify"; ci_steps_unreadable'
}
never_started() { jq -c -L "$LIB_DIR" 'include "ci-stall-classify"; ci_never_started_job' "$1"; }
check 'fixture: the never-started job has no steps, runner 0, a start at its queue time, and a cancellation annotation' is \
  "$(jq -c '[.steps, .conclusion, .runner_id, .runner_name, .started_at == .created_at, (.annotations[0] | test("cancel"; "i"))]' "$NEVER")" '[[],"cancelled",0,"",true,true]'
check 'fixture: the job with no runner at all has no steps, runner null, a start at its queue time, and no annotation' is \
  "$(jq -c '[.steps, .conclusion, .runner_id, .runner_name, .started_at == .created_at, .annotations]' "$NORUNNER")" '[[],"cancelled",null,null,true,[]]'
jq --argjson run "$(jq .run_id "$STALL")" '.run_id = $run' "$NEVER" > "$TMP/never-after.json"
check 'P2: a never-started job queued after the stall ended is downstream of it, not unreadable' is \
  "$(unreadable "$STALL" "$TMP/never-after.json")/$(only "$STALL" "$TMP/never-after.json")" false/true
# Round 2: a never-started job alone is read, not unreadable, and is no stall.
check 'P2 round 2: the never-started job is read as never started' is "$(never_started "$NEVER")" true
check 'P2 round 2: the never-started job alone is readable, not unreadable' is "$(unreadable "$NEVER")" false
check 'P2 round 2: the never-started job alone is never a stall' is "$(only "$NEVER")" false
check 'P2 round 2: the job with no runner at all is read as never started' is "$(never_started "$NORUNNER")" true
check 'P2 round 2: the job with no runner at all, alone, is readable and no stall' is \
  "$(unreadable "$NORUNNER")/$(only "$NORUNNER")" false/false
check 'P2 round 2: a never-started job beside a failed shard is readable, and the red is not stall-only' is \
  "$(unreadable "$FAILED" "$NEVER")/$(only "$FAILED" "$NEVER")" false/false
jq '.created_at = "2026-10-05T21:34:40Z" | .started_at = .created_at' "$TMP/never-after.json" > "$TMP/never-before.json"
check 'P2 round 2: a never-started job queued before the stall ended is readable, not downstream, so not stall-only' is \
  "$(unreadable "$STALL" "$TMP/never-before.json")/$(only "$STALL" "$TMP/never-before.json")" false/false
# The captured glitch read: a finished job served without its steps keeps its
# runner and a start after its creation, so it is never read as never started.
jq -s '.[0] + {annotations: [.[1][] | .message], annotation_records: .[1]}' "$FIX/job-111637998248-no-steps.json" "$FIX/annotations-111637998248.json" > "$TMP/midstep-no-steps.json"
check 'fixture: the glitch read of the #1568 mid-step stall has no steps but its runner and a later start' is \
  "$(jq -c '[.steps, .conclusion, .runner_id, (.started_at > .created_at)]' "$TMP/midstep-no-steps.json")" '[[],"cancelled",110679,true]'
check 'P2 round 2: the glitch read is not a never-started job' is "$(never_started "$TMP/midstep-no-steps.json")" false
check 'P2 round 2: the glitch read alone is unreadable' is "$(unreadable "$TMP/midstep-no-steps.json")" true
jq -s '.[0] + {annotations: [.[1][] | .message], annotation_records: .[1]}' "$FIX/job-112732924539-no-steps.json" "$FIX/annotations-112732924539.json" > "$TMP/core1660-no-steps.json"
check 'P2: the #1660 core job served without steps is unreadable beside its gate' is \
  "$(unreadable "$TMP/core1660-no-steps.json" "$GATE1660")" true
check 'P2: a record with no steps key is unreadable' is "$(jq 'del(.steps)' "$STALL" | jq -sc -L "$LIB_DIR" 'include "ci-stall-classify"; ci_steps_unreadable')" true
check 'P2: records with their steps are never unreadable' is "$(unreadable "$STALL" "$GATE" "$FAILED" null)" false
# Each planted record changes one fact of the never-started shape: none is
# read as never started, and alone each stays unreadable.
for fault in runner-taken runner-named runner-key-missing started-later created-missing steps-key-missing failure-conclusion still-queued; do
  case "$fault" in
    runner-taken) expr='.runner_id = 110679' ;;
    runner-named) expr='.runner_name = "linux-x64-light-fssk9-runner-qv5hl"' ;;
    runner-key-missing) expr='del(.runner_id)' ;;
    started-later) expr='.started_at = "2026-10-13T23:27:56Z"' ;;
    created-missing) expr='del(.created_at) | .started_at = null' ;;
    steps-key-missing) expr='del(.steps)' ;;
    failure-conclusion) expr='.conclusion = "failure"' ;;
    still-queued) expr='.status = "queued" | .conclusion = null' ;;
  esac
  jq "$expr" "$NEVER" > "$TMP/never-$fault.json"
  check "PLANTED never-started $fault: not never started, and alone unreadable" is \
    "$(never_started "$TMP/never-$fault.json")/$(unreadable "$TMP/never-$fault.json")" false/true
done

# --- the shell helper ---------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
args=${args//acme-org\/announce-bot/Org\/repo}
case "$args" in
  "api repos/Org/repo/actions/jobs/"*)
    id=${args##*/}
    [ "${GH_FAIL:-}" != "$id" ] || exit 1
    cat "$GH_JOBS/job-$id.json" ;;
  "api repos/Org/repo/check-runs/"*"/annotations"*)
    id=${args#api repos/Org/repo/check-runs/}; id=${id%%/*}
    [ "${GH_FAIL_ANN:-}" != "$id" ] || exit 1
    jq -s . "$GH_JOBS/annotations-$id.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export GH_LOG="$TMP/gh.log" GH_JOBS="$TMP/jobs"
mkdir -p "$GH_JOBS"; cp "$FIX"/*.json "$GH_JOBS/"
jq 'del(.annotations)' "$TMP/late-failure.json" > "$GH_JOBS/job-3.json"
printf '[{"annotation_level":"failure","message":"Process completed with exit code 1.","title":""}]\n' > "$GH_JOBS/annotations-3.json"
# red <id>...: check-run lines as pr_owner_ci_red prints them.
red() {
  local id
  for id in "$@"; do
    if [ "$id" = none ]; then printf '{"name":"external","status":"completed","conclusion":"failure"}\n'
    else printf '{"id":%s,"name":"x","details_url":"https://github.com/Org/repo/actions/runs/9/job/%s","status":"completed","conclusion":"failure"}\n' "$id" "$id"; fi
  done
}
helper() { PATH="$TMP/bin:$PATH" bash -c 'source "$1/ci-stall-classify.sh" && ci_stall_only "$2" "$3"' _ "$LIB_DIR" "${1:-Org/repo}" "${2:-stall}"; }

OUT=$(red 111987568844 111996702903 | helper); RC=$?
check 'helper: #1597 stall run exits 0' is "$RC" 0
check 'helper: prints the decision and each job judged' is \
  "$(jq -c '[.stall_only, [.jobs[] | [.id, .capped, .stalled]]]' <<<"$OUT")" '[true,[[111987568844,true,true],[111996702903,false,false]]]'
check 'helper: one job record and one annotation read per red check' is \
  "$(grep -c 'actions/jobs/' "$GH_LOG")/$(grep -c '/annotations' "$GH_LOG")" 2/2
OUT=$(red 111626142608 | helper); RC=$?
check 'PLANTED helper: a failed step exits 1' is "$RC" 1
check 'PLANTED helper: and says why' is "$(jq -c '.stall_only' <<<"$OUT")" false
red 111987568844 3 | helper >/dev/null; RC=$?
check 'PLANTED helper: a late job with its own failure exits 1' is "$RC" 1
red 111987568844 none | helper >/dev/null; RC=$?
check 'PLANTED helper: a red check that is not an Actions job exits 1' is "$RC" 1
: | helper >/dev/null; RC=$?
check 'PLANTED helper: nothing red exits 1' is "$RC" 1
OUT=$(red 111987568844 | GH_FAIL=111987568844 helper); RC=$?
check 'PLANTED helper: an unreadable job record exits 1 and prints nothing' is "$RC/$OUT" 1/
OUT=$(red 111987568844 | GH_FAIL_ANN=111987568844 helper); RC=$?
check 'PLANTED helper: unreadable annotations exit 1 and print nothing' is "$RC/$OUT" 1/

# #1660's run in both modes: the shape the resume stage relaunches an owner
# for, the hang beside it, and the same job served without its steps.
for mode in stall retry; do
  OUT=$(red 112732924539 112742237694 | helper Org/repo "$mode"); RC=$?
  check "helper $mode: #1660's stall and gate exit 0" is "$RC" 0
  check "helper $mode: #1660's core job judged stalled, its gate not" is \
    "$(jq -c '[.jobs[] | [.id, .capped, .stalled]]' <<<"$OUT")" '[[112732924539,true,true],[112742237694,false,false]]'
  cp "$FIX/job-112732924539-hung.json" "$GH_JOBS/job-112732924539.json"
  OUT=$(red 112732924539 112742237694 | helper Org/repo "$mode"); RC=$?
  check "PLANTED helper $mode: the hang exits 1 with a decision" is "$RC/$(jq -c '.stall_only' <<<"$OUT")" 1/false
  cp "$FIX/job-112732924539-no-steps.json" "$GH_JOBS/job-112732924539.json"
  : > "$GH_LOG"
  OUT=$(red 112732924539 112742237694 | helper Org/repo "$mode"); RC=$?
  check "helper $mode: #1660's core job served without steps is unreadable, no decision" is "$RC/$OUT" 1/
  check "helper $mode: a job served without steps is still read whole before it is called unreadable" is \
    "$(grep -c 'actions/jobs/' "$GH_LOG")/$(grep -c '/annotations' "$GH_LOG")" 2/2
  jq 'del(.steps)' "$FIX/job-112732924539.json" > "$GH_JOBS/job-112732924539.json"
  OUT=$(red 112732924539 112742237694 | helper Org/repo "$mode"); RC=$?
  check "PLANTED helper $mode: a job record with no steps key is unreadable" is "$RC/$OUT" 1/
  cp "$FIX/job-112732924539.json" "$GH_JOBS/job-112732924539.json"
  # pro-gate round 1 P2 on #1766: a job that never started, cancelled while
  # queued behind the #1597 stall in its run, is downstream of that stall and
  # keeps the fleet verdict main's filter gave it.
  jq --argjson run "$(jq .run_id "$STALL")" '.run_id = $run' "$FIX/job-115594417972.json" > "$GH_JOBS/job-115594417972.json"
  OUT=$(red 111987568844 115594417972 | helper Org/repo "$mode"); RC=$?
  check "P2 helper $mode: the stall and a never-started job queued behind it exit 0" is "$RC" 0
  check "P2 helper $mode: the never-started job is judged, not stalled, with no failed step" is \
    "$(jq -c '[.stall_only, [.jobs[] | [.id, .stalled, .failed_steps]]]' <<<"$OUT")" '[true,[[111987568844,true,[]],[115594417972,false,[]]]]'
  # Round 2 P2: alone, or queued before the stall ended, a never-started job is
  # read on its evidence and the red is a decision (not stall-only), never an
  # unreadable read; the resume stage caches that verdict instead of reading
  # GitHub again every hour.
  OUT=$(red 115594417972 | helper Org/repo "$mode"); RC=$?
  check "P2 round 2 helper $mode: the never-started job alone exits 1 with a decision" is \
    "$RC/$(jq -c '[.stall_only, [.jobs[] | [.id, .stalled, .failed_steps]]]' <<<"$OUT")" '1/[false,[[115594417972,false,[]]]]'
  OUT=$(red 112919103444 | helper Org/repo "$mode"); RC=$?
  check "P2 round 2 helper $mode: the job with no runner at all, alone, exits 1 with a decision" is \
    "$RC/$(jq -c '.stall_only' <<<"$OUT")" 1/false
  jq '.id = 115594417973 | .created_at = "2026-10-05T21:34:40Z" | .started_at = .created_at' "$GH_JOBS/job-115594417972.json" > "$GH_JOBS/job-115594417973.json"
  cp "$FIX/annotations-115594417972.json" "$GH_JOBS/annotations-115594417973.json"
  OUT=$(red 111987568844 115594417973 | helper Org/repo "$mode"); RC=$?
  check "P2 round 2 helper $mode: a never-started job queued before the stall ended exits 1 with a decision" is \
    "$RC/$(jq -c '.stall_only' <<<"$OUT")" 1/false
  # The captured glitch read, a finished job served without its steps, keeps
  # its runner and a later start: still unreadable, no decision.
  cp "$FIX/job-111637998248-no-steps.json" "$GH_JOBS/job-111637998248.json"
  OUT=$(red 111637998248 | helper Org/repo "$mode"); RC=$?
  check "P2 round 2 helper $mode: the glitch read of the #1568 mid-step stall is unreadable, no decision" is "$RC/$OUT" 1/
  cp "$FIX/job-111637998248.json" "$GH_JOBS/job-111637998248.json"
  OUT=$(red 111637998248 | helper Org/repo "$mode"); RC=$?
  check "helper $mode: the #1568 mid-step stall read with its steps exits 0" is "$RC" 0
done


# #1722: synthetic lost-runner records. The default contract is deliberately
# unchanged: pro-gate-loop's head-moving recovery has not opted into retries.
OUT=$(red 172201 172202 172203 | helper acme-org/announce-bot retry); RC=$?
check 'lost runner: retry mode explains the full aggregate chain' is "$RC" 0
check 'lost runner: every leaf/aggregate is explicitly retryable' is "$(jq -c '[.jobs[].retryable]' <<<"$OUT")" '[true,true,true]'
OUT=$(red 172201 | helper Org/repo retry); RC=$?
check 'lost runner: a leaf alone needs no repository-specific aggregate rule' is "$RC" 0
red 172201 172202 172203 | helper acme-org/announce-bot >/dev/null; RC=$?
check 'lost runner: default head-moving contract stays unchanged' is "$RC" 1
red 172201 172202 172203 | helper Org/repo retry >/dev/null; RC=$?
check 'lost runner: acme-app aggregate policy does not apply to other repositories' is "$RC" 1
red 172202 172203 | helper acme-org/announce-bot retry >/dev/null; RC=$?
check 'lost runner: aggregate chain without a lost leaf is ineligible' is "$RC" 1
: > "$GH_LOG"
OUT=$(red 172201 172202 172203 | helper acme-org/announce-bot bogus); RC=$?
check 'lost runner: an unknown mode is refused before any read' is "$RC/$OUT/$(cat "$GH_LOG")" 1//

# Each negative changes one fact of the positive chain. Annotation severity
# is preserved by the shell reader; a warning cannot stand in for a failure.
for fault in failed-step cancelled-step timed-out-step warning-only mixed-annotation malformed-annotation missing-annotations unrelated-leaf other-run other-attempt other-head early-gate migration-failure wrong-judge extra-step wrong-message judge-extra-annotation gate-extra-annotation missing-steps null-step unknown-step unknown-step-status missing-step-name inconsistent-step; do
  cp "$FIX"/*-17220?.json "$GH_JOBS/"
  case "$fault" in
    failed-step) file=job-172201; expr='.steps[1].conclusion="failure"' ;;
    cancelled-step) file=job-172201; expr='.steps[1].conclusion="cancelled"' ;;
    timed-out-step) file=job-172201; expr='.steps[1].conclusion="timed_out"' ;;
    warning-only) file=annotations-172201; expr='.[0].annotation_level="warning"' ;;
    mixed-annotation) file=annotations-172201; expr='. + [{annotation_level:"failure",message:"a genuine failure"}]' ;;
    malformed-annotation) file=annotations-172201; expr='. + [{message:"unknown severity"}]' ;;
    missing-annotations) file=annotations-172201; expr='[]' ;;
    unrelated-leaf) file=job-172201; expr='.name="📜 Policy Docs"' ;;
    other-run) file=job-172203; expr='.run_id=901' ;;
    other-attempt) file=job-172203; expr='.run_attempt=2' ;;
    other-head) file=job-172203; expr='.head_sha="other"' ;;
    early-gate) file=job-172203; expr='.started_at="2026-10-11T03:34:00Z"' ;;
    migration-failure) file=job-172203; expr='.steps[1].conclusion="success" | .steps[2].conclusion="failure"' ;;
    wrong-judge) file=job-172202; expr='.steps[1].name="Run tests"' ;;
    extra-step) file=job-172203; expr='.steps[2].conclusion="failure"' ;;
    wrong-message) file=annotations-172203; expr='.[0].message="live PR lookup failed"' ;;
    judge-extra-annotation) file=annotations-172202; expr='. + [{annotation_level:"failure",message:"a genuine failure"}]' ;;
    gate-extra-annotation) file=annotations-172203; expr='. + [{annotation_level:"failure",message:"a genuine failure"}]' ;;
    missing-steps) file=job-172201; expr='del(.steps)' ;;
    null-step) file=job-172201; expr='.steps=[null]' ;;
    unknown-step) file=job-172201; expr='.steps[1].conclusion="unknown"' ;;
    unknown-step-status) file=job-172201; expr='.steps[1].status="unknown"' ;;
    missing-step-name) file=job-172201; expr='del(.steps[1].name)' ;;
    inconsistent-step) file=job-172201; expr='.steps[1].status="completed"' ;;
  esac
  jq "$expr" "$GH_JOBS/$file.json" > "$TMP/negative.json"
  cp "$TMP/negative.json" "$GH_JOBS/$file.json"
  red 172201 172202 172203 | helper acme-org/announce-bot retry >/dev/null; RC=$?
  check "lost runner negative $fault: no retry" is "$RC" 1
done
cp "$FIX"/*-17220?.json "$GH_JOBS/"
red 172201 172202 172203 111626142608 | helper acme-org/announce-bot retry >/dev/null; RC=$?
check 'lost runner: a genuine failed job beside the chain prevents retry' is "$RC" 1
red 172201 172202 172203 none | helper acme-org/announce-bot retry >/dev/null; RC=$?
check 'lost runner: a non-Actions red beside the chain prevents retry' is "$RC" 1
OUT=$(red 172201 172202 172203 | GH_FAIL_ANN=172201 helper acme-org/announce-bot retry); RC=$?
check 'lost runner: unreadable evidence fails closed without a decision' is "$RC/$OUT" 1/


# Retry-only ordering must retain fractional precision. The legacy capped
# classifier's timestamp behavior is left untouched by this opt-in contract.
for pair in '900 100 1' '100 900 0' '9 90 0' '900000001 900000000 1' '900000000 900000001 0' '9000000001 9000000002 1'; do
  read -r ended started want <<<"$pair"
  cp "$FIX"/*-17220?.json "$GH_JOBS/"
  jq --arg time "2026-10-11T03:35:08.${ended}Z" '.completed_at=$time' "$FIX/job-172201.json" > "$GH_JOBS/job-172201.json"
  jq --arg time "2026-10-11T03:35:08.${started}Z" '.started_at=$time' "$FIX/job-172202.json" > "$GH_JOBS/job-172202.json"
  red 172201 172202 172203 | helper acme-org/announce-bot retry >/dev/null; RC=$?
  check "lost runner fractional ordering $ended <= $started" is "$RC" "$want"
done
cp "$FIX"/*-17220?.json "$GH_JOBS/"

echo "ci-stall-classify: $pass passed, $fail failed"
[ "$fail" = 0 ]
