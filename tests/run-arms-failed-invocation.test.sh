#!/usr/bin/env bash
# Pins pro-gate round 1 P2 on PR #1683 (run-arms.sh:95): a failed model
# invocation must not leave the experiment exiting 0.
#
# The worker used to capture the CLI status and then end on a successful
# echo, and an unqualified wait returns 0 even when a child failed. Auth
# failures, is_error envelopes, and truncated output were therefore accepted.
#
# Hermetic: a PATH stub stands in for `claude`. No network, no real CLI, no
# writes outside $TMP. The fixture component is read in place; the runner
# resolves it from its own directory.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/harness/vet-fixtures/emilkowalski-break-ui/run-arms.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/cand" "$TMP/inc/break" "$TMP/inc/better-typography" "$TMP/inc/better-layout" "$TMP/bin"
printf 'skill\n' >"$TMP/cand/SKILL.md"
printf 'catalog\n' >"$TMP/cand/CATALOG.md"
printf 'skill\n' >"$TMP/inc/break/SKILL.md"
printf 'scenarios\n' >"$TMP/inc/break/scenarios.md"
printf 'typo\n' >"$TMP/inc/better-typography/SKILL.md"
printf 'layout\n' >"$TMP/inc/better-layout/SKILL.md"
printf '{}\n' >"$TMP/settings.json"

cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
arm=bare
case "$prompt" in
  *'skill: break-ui'*) arm=breakui ;;
  *'skill: break ('*) arm=break ;;
esac
if [ "$arm" = "${STUB_FAIL_ARM:-}" ]; then
  case "${STUB_MODE:-ok}" in
    exit)
      printf '%s\n' '{"is_error": false, "result": "should not count"}'
      echo "stub: auth failed" >&2
      exit 7
      ;;
    is_error)
      printf '%s\n' '{"is_error": true, "result": "rate limited"}'
      exit 0
      ;;
    invalid)
      printf '%s\n' '{truncated'
      exit 0
      ;;
    empty)
      printf '%s\n' '{"is_error": false, "result": ""}'
      exit 0
      ;;
  esac
fi
printf '%s\n' '{"is_error": false, "result": "found a break", "num_turns": 1, "total_cost_usd": 0, "usage": {}}'
exit 0
STUB
chmod +x "$TMP/bin/claude"

# run_arms <out> <runs> <mode> <fail-arm>
# Prints the runner's combined output. Exit status is the runner's.
run_arms() {
  local out="$1" runs="$2" mode="$3" fail_arm="$4"
  mkdir -p "$out"
  PATH="$TMP/bin:$PATH" \
    CAND="$TMP/cand" \
    INC="$TMP/inc" \
    OUT="$out" \
    SETTINGS="$TMP/settings.json" \
    RUNS="$runs" \
    MODEL=stub \
    STUB_MODE="$mode" \
    STUB_FAIL_ARM="$fail_arm" \
    bash "$SCRIPT"
}

# expect_reject <case> <mode> <needle>
# One arm fails; the other two write a valid envelope. The run must exit
# nonzero, name the failed slot, and must not print the acceptance banner.
expect_reject() {
  local name="$1" mode="$2" needle="$3"
  local out="$TMP/out-$name" output rc=0
  rm -rf "$out"
  output=$(run_arms "$out" 1 "$mode" bare 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$name: runner exited 0 (a failed invocation was accepted)"
    return
  fi
  case "$output" in
    *"$needle"*) ;;
    *) bad "$name: output lacked '$needle'"; return ;;
  esac
  case "$output" in
    *'--- results ---'*) bad "$name: accepted the experiment after a failed invocation"; return ;;
  esac
  ok
  echo "PASS: $name"
}

# p2_nonzero_exit_is_not_a_successful_run: CLI exit 7 with a well-formed
# envelope must not be accepted.
expect_reject p2_nonzero_exit_is_not_a_successful_run exit 'run-arms: bare-1: exit=7'

# p2_is_error_is_not_a_successful_run: exit 0 plus is_error true is still a
# failed invocation.
expect_reject p2_is_error_is_not_a_successful_run is_error 'run-arms: bare-1: is_error=true'

# p2_invalid_result_is_not_a_successful_run: truncated JSON lacks a valid result.
expect_reject p2_invalid_result_is_not_a_successful_run invalid 'run-arms: bare-1: lacks a valid result'

# p2_empty_result_is_not_a_successful_run: an empty result string is not data.
expect_reject p2_empty_result_is_not_a_successful_run empty 'run-arms: bare-1: lacks a valid result'

# p2_exactly_runs_times_3_successes_accepts_the_run: a full set is accepted,
# and the accepted count is RUNS x 3, not a constant.
expect_accept() {
  local runs="$1" expected="$2"
  local name="p2_exactly_runs_times_3_successes_accepts_the_run_runs${runs}"
  local out="$TMP/out-ok-$runs" output rc=0 needle
  needle="run-arms: ${expected} successful results (RUNS x 3)"
  rm -rf "$out"
  output=$(run_arms "$out" "$runs" ok none 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name: runner exited $rc on a full successful set"
    printf '%s\n' "$output" >&2
    return
  fi
  case "$output" in
    *"$needle"*) ;;
    *) bad "$name: output lacked '$needle'"; return ;;
  esac
  if [ "$runs" -gt 0 ]; then
    case "$output" in
      *'--- results ---'*) ;;
      *) bad "$name: did not accept a full successful set"; return ;;
    esac
  fi
  ok
  echo "PASS: $name"
}

expect_accept 1 3
expect_accept 2 6
expect_accept 0 0

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
