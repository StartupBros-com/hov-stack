#!/usr/bin/env bash
# Pins dotfiles#1690: the sibling batch runners must not accept a failed model
# invocation. Same contract as emilkowalski-break-ui/run-arms.sh (pinned by
# run-arms-failed-invocation.test.sh), now shared through vet-fixtures/check-arms.py:
#
#   jakubkrehel-skills/run-arms.sh   ended its worker on a successful echo and used
#                                    an unqualified wait, so it always exited 0.
#   pstack-2026-09/run-arms.sh       counted non-zero exits and printed the count,
#                                    then continued and exited 0.
#   explainer-toolbox-2026-09/run-arms.sh  exited 1 on a non-zero exit but accepted
#                                    an is_error envelope or invalid JSON.
#
# A run is accepted only when every invocation exited 0 with is_error false and a
# non-empty result, and the successful count is exactly RUNS x the arms run.
#
# Hermetic: a PATH stub stands in for `claude`; every skill input the runners
# read from outside the repo is a stub under $TMP. The in-repo fixtures
# (fixture.html, invoice-code-bundle.md, fixtureB-code.ts, fixtureA-source.md)
# are read in place. No network, no writes outside $TMP.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$REPO/harness/vet-fixtures"
JAKUB="$FIX/jakubkrehel-skills/run-arms.sh"
PSTACK="$FIX/pstack-2026-09/run-arms.sh"
EXPLAINER="$FIX/explainer-toolbox-2026-09/run-arms.sh"
CHECK="$FIX/check-arms.py"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

for s in "$JAKUB" "$PSTACK" "$EXPLAINER"; do
  [ -f "$s" ] || { echo "FAIL: script not found at $s" >&2; exit 1; }
  bash -n "$s" || { echo "FAIL: $s does not parse" >&2; exit 1; }
done
[ -f "$CHECK" ] || { echo "FAIL: shared validator not found at $CHECK" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- stub claude: reads the prompt on stdin, writes a JSON envelope ---
# STUB_FAIL_HAS / STUB_FAIL_LACKS pick the slot that fails by a substring the
# prompt contains or lacks; STUB_MODE picks how it fails.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
fail=0
if [ -n "${STUB_FAIL_HAS:-}" ] && [[ "$prompt" == *"$STUB_FAIL_HAS"* ]]; then fail=1; fi
if [ -n "${STUB_FAIL_LACKS:-}" ] && [[ "$prompt" != *"$STUB_FAIL_LACKS"* ]]; then fail=1; fi
if [ "$fail" -eq 1 ]; then
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
printf '%s\n' '{"is_error": false, "result": "| 1 | h1 | UI | finding | fix |", "num_turns": 1, "total_cost_usd": 0, "usage": {}, "modelUsage": {"stub": {}}}'
exit 0
STUB
chmod +x "$TMP/bin/claude"

# --- stub skill inputs ---
mkdir -p "$TMP/jk/cand/better-interface" "$TMP/jk/inc/ux-audit" "$TMP/jk/inc/emil-design-eng"
for s in better-interface better-accessibility better-layout better-writing better-typography better-colors better-ui; do
  mkdir -p "$TMP/jk/cand/$s"
  printf 'skill %s\n' "$s" >"$TMP/jk/cand/$s/SKILL.md"
done
printf 'review format\n' >"$TMP/jk/cand/better-interface/review-format.md"
printf 'ux-audit\n' >"$TMP/jk/inc/ux-audit/SKILL.md"
printf 'emil\n' >"$TMP/jk/inc/emil-design-eng/SKILL.md"

mkdir -p "$TMP/ps/cand/interrogate/references" "$TMP/ps/cand/how/references" "$TMP/ps/cand/blast-radius" \
         "$TMP/ps/codeslop/rules"
printf 'interrogate\n' >"$TMP/ps/cand/interrogate/SKILL.md"
for r in reviewer-prompt rubric code-quality-review lead-judgment; do
  printf '%s\n' "$r" >"$TMP/ps/cand/interrogate/references/$r.md"
done
printf 'how\n' >"$TMP/ps/cand/how/SKILL.md"
printf 'explorer\n' >"$TMP/ps/cand/how/references/explorer-prompt.md"
printf 'explainer\n' >"$TMP/ps/cand/how/references/explainer-prompt.md"
printf 'blast\n' >"$TMP/ps/cand/blast-radius/SKILL.md"
printf 'thermo\n' >"$TMP/ps/thermo.md"
printf 'codeslop\n' >"$TMP/ps/codeslop/SKILL.md"
printf 'rule\n' >"$TMP/ps/codeslop/rules/one.md"
printf 'showme\n' >"$TMP/ps/showme.md"
printf 'ceexplain\n' >"$TMP/ps/ceexplain.md"

mkdir -p "$TMP/ex"
printf 'install preamble\n---\nname: eli5-for-grownups\n---\nbody\n' >"$TMP/ex/grace.txt"
printf 'incumbent eli5\n' >"$TMP/ex/inc-eli5.md"
printf 'hybrid eli5\n' >"$TMP/ex/hyb.md"
printf 'showme upstream\n' >"$TMP/ex/sm-up.md"
printf 'showme adapted\n' >"$TMP/ex/sm-ad.md"

# run_jakub <out> <runs> <mode> <lacks-needle>
run_jakub() {
  PATH="$TMP/bin:$PATH" CAND="$TMP/jk/cand" INC="$TMP/jk/inc" OUT="$1" RUNS="$2" \
    STUB_MODE="$3" STUB_FAIL_LACKS="$4" STUB_FAIL_HAS= bash "$JAKUB"
}
# run_pstack <out> <runs> <arms> <mode> <has-needle>
run_pstack() {
  PATH="$TMP/bin:$PATH" CAND="$TMP/ps/cand" INC_THERMO="$TMP/ps/thermo.md" INC_CODESLOP_DIR="$TMP/ps/codeslop" \
    INC_SHOWME="$TMP/ps/showme.md" INC_CEEXPLAIN="$TMP/ps/ceexplain.md" OUT="$1" RUNS="$2" ARMS="$3" \
    STUB_MODE="$4" STUB_FAIL_HAS="$5" STUB_FAIL_LACKS= bash "$PSTACK"
}
# run_explainer <out> <runs> <arms> <mode> <has-needle>
run_explainer() {
  PATH="$TMP/bin:$PATH" GRACE="$TMP/ex/grace.txt" INC_ELI5="$TMP/ex/inc-eli5.md" HYB="$TMP/ex/hyb.md" \
    SM_UP="$TMP/ex/sm-up.md" SM_AD="$TMP/ex/sm-ad.md" OUT="$1" RUNS="$2" ARMS="$3" \
    STUB_MODE="$4" STUB_FAIL_HAS="$5" STUB_FAIL_LACKS= bash "$EXPLAINER"
}

# expect_reject <name> <needle> <results-banner> -- <command...>
# The run must exit nonzero, name the failed slot, and must not print the
# results summary.
expect_reject() {
  local name="$1" needle="$2" banner="$3"; shift 3
  local output rc=0
  output=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$name: runner exited 0 (a failed invocation was accepted)"
    printf '%s\n' "$output" >&2
    return
  fi
  case "$output" in
    *"$needle"*) ;;
    *) bad "$name: output lacked '$needle'"; printf '%s\n' "$output" >&2; return ;;
  esac
  case "$output" in
    *"$banner"*) bad "$name: printed the results summary after a failed invocation"; return ;;
  esac
  ok
  echo "PASS: $name"
}

# expect_accept <name> <acceptance-line> <results-banner> -- <command...>
expect_accept() {
  local name="$1" accept="$2" banner="$3"; shift 3
  local output rc=0
  output=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name: runner exited $rc on a full successful set"
    printf '%s\n' "$output" >&2
    return
  fi
  case "$output" in
    *"$accept"*) ;;
    *) bad "$name: output lacked '$accept'"; printf '%s\n' "$output" >&2; return ;;
  esac
  case "$output" in
    *"$banner"*) ;;
    *) bad "$name: did not print the results summary on a full successful set"; return ;;
  esac
  ok
  echo "PASS: $name"
}

# ---------------------------------------------------------------- jakubkrehel
# The bare prompt is the only one without inlined skill material.
JK_BARE_LACKS='===== skill:'
expect_reject jakub_nonzero_exit_is_not_a_successful_run 'run-arms: bare-1: exit=7' '--- results ---' \
  run_jakub "$TMP/jk/out-exit" 1 exit "$JK_BARE_LACKS"
expect_reject jakub_is_error_is_not_a_successful_run 'run-arms: bare-1: is_error=true' '--- results ---' \
  run_jakub "$TMP/jk/out-is-error" 1 is_error "$JK_BARE_LACKS"
expect_reject jakub_invalid_result_is_not_a_successful_run 'run-arms: bare-1: lacks a valid result' '--- results ---' \
  run_jakub "$TMP/jk/out-invalid" 1 invalid "$JK_BARE_LACKS"
expect_reject jakub_empty_result_is_not_a_successful_run 'run-arms: bare-1: lacks a valid result' '--- results ---' \
  run_jakub "$TMP/jk/out-empty" 1 empty "$JK_BARE_LACKS"
expect_accept jakub_exactly_runs_times_3_successes_accepts_the_run 'run-arms: 6 successful results (RUNS x 3)' '--- results ---' \
  run_jakub "$TMP/jk/out-ok" 2 ok ''

# jakub_refuses_an_out_dir_that_already_holds_results: a stale result file
# would be scored, so the runner stops before launching any arm.
mkdir -p "$TMP/jk/out-stale"
printf '%s\n' '{"is_error": false, "result": "stale"}' >"$TMP/jk/out-stale/stale.json"
rc=0
output=$(run_jakub "$TMP/jk/out-stale" 1 ok '' 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  bad "jakub_refuses_an_out_dir_that_already_holds_results: exited 0"
elif ls "$TMP/jk/out-stale"/*.rc >/dev/null 2>&1; then
  bad "jakub_refuses_an_out_dir_that_already_holds_results: launched an arm anyway"
else
  case "$output" in
    *'already holds result files'*) ok; echo "PASS: jakub_refuses_an_out_dir_that_already_holds_results" ;;
    *) bad "jakub_refuses_an_out_dir_that_already_holds_results: output lacked the refusal"; printf '%s\n' "$output" >&2 ;;
  esac
fi

# --------------------------------------------------------------------- pstack
# H prompts carry 'User request:'; R prompts carry the review task.
PS_ALL="R-bare R-interrogate R-thermo R-codeslop H-bare H-how H-showme H-ceexplain B-bare B-blast"
expect_reject pstack_nonzero_exit_is_not_a_successful_run 'run-arms: H-bare-1: exit=7' '--- results (' \
  run_pstack "$TMP/ps/out-exit" 1 "R-bare H-bare" exit 'User request:'
expect_reject pstack_is_error_is_not_a_successful_run 'run-arms: R-bare-1: is_error=true' '--- results (' \
  run_pstack "$TMP/ps/out-is-error" 1 "R-bare" is_error 'Task: review the code bundle'
expect_reject pstack_invalid_result_is_not_a_successful_run 'run-arms: R-bare-1: lacks a valid result' '--- results (' \
  run_pstack "$TMP/ps/out-invalid" 1 "R-bare" invalid 'Task: review the code bundle'
expect_reject pstack_empty_result_is_not_a_successful_run 'run-arms: R-bare-1: lacks a valid result' '--- results (' \
  run_pstack "$TMP/ps/out-empty" 1 "R-bare" empty 'Task: review the code bundle'
expect_accept pstack_exactly_runs_times_arms_successes_accepts_the_run 'run-arms: 10 successful results (RUNS x 10)' '--- results (10 runs, 0 non-zero exits) ---' \
  run_pstack "$TMP/ps/out-ok" 1 "$PS_ALL" ok ''
expect_accept pstack_arms_subset_accepts_exactly_runs_times_subset 'run-arms: 4 successful results (RUNS x 2)' '--- results (4 runs, 0 non-zero exits) ---' \
  run_pstack "$TMP/ps/out-ok-subset" 2 "R-bare B-blast" ok ''

# ------------------------------------------------------------------ explainer
# B prompts carry the module; A prompts carry the source note. The is_error
# and invalid cases are the part the issue called related: a nonzero exit
# already failed this runner, these two did not.
EX_ALL="A-bare A-incumbent A-candidate A-hybrid B-bare B-showme-upstream B-showme-adapted"
expect_reject explainer_nonzero_exit_is_not_a_successful_run 'run-arms: B-bare-1: exit=7' '--- results (' \
  run_explainer "$TMP/ex/out-exit" 1 "A-bare B-bare" exit '<module path='
expect_reject explainer_is_error_is_not_a_successful_run 'run-arms: A-bare-1: is_error=true' '--- results (' \
  run_explainer "$TMP/ex/out-is-error" 1 "A-bare B-bare" is_error '<source>'
expect_reject explainer_invalid_result_is_not_a_successful_run 'run-arms: B-bare-1: lacks a valid result' '--- results (' \
  run_explainer "$TMP/ex/out-invalid" 1 "A-bare B-bare" invalid '<module path='
expect_reject explainer_empty_result_is_not_a_successful_run 'run-arms: A-bare-1: lacks a valid result' '--- results (' \
  run_explainer "$TMP/ex/out-empty" 1 "A-bare" empty '<source>'
expect_accept explainer_exactly_runs_times_arms_successes_accepts_the_run 'run-arms: 7 successful results (RUNS x 7)' '--- results (7 runs, 0 non-zero exits) ---' \
  run_explainer "$TMP/ex/out-ok" 1 "$EX_ALL" ok ''

# ----------------------------------------------------------- shared validator
# check_arms_counts_only_expected_slots: a result file outside the expected
# set is a problem even when every expected slot succeeded, and a missing .rc
# is named rather than inferred from the envelope.
mkdir -p "$TMP/chk"
printf '0\n' >"$TMP/chk/a-1.rc"
printf '%s\n' '{"is_error": false, "result": "fine"}' >"$TMP/chk/a-1.json"
printf '%s\n' '{"is_error": false, "result": "stale"}' >"$TMP/chk/zz-9.json"
printf '%s\n' '{"is_error": false, "result": "no rc"}' >"$TMP/chk/b-1.json"
rc=0
output=$(python3 -I "$CHECK" "$TMP/chk" 1 a b 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  bad "check_arms_counts_only_expected_slots: exited 0"
else
  case "$output" in
    *'run-arms: zz-9.json: unexpected result file'*'run-arms: b-1: missing exit status'*'run-arms: 1 successful results, expected 2'*)
      ok; echo "PASS: check_arms_counts_only_expected_slots" ;;
    *) bad "check_arms_counts_only_expected_slots: output was: $output" ;;
  esac
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
