#!/usr/bin/env bash
# Pins dotfiles#1690 item 3: the single-arm runner must not exit 0 after a
# failed model invocation. It used to record EXIT_CODE=$? onto stderr.txt and
# continue, so its own exit status was the tool-log pass's, never `claude`'s,
# and nothing checked is_error or that result.json held a result.
#
# Two byte-equivalent copies carry the same defect and the same fix, because
# each fixture vendors the runner and copies it into scratch at run time
# (retro's setup-arms.sh is a 2026-09-20 record that still names the author's
# experiments template, which this repo does not carry; the copy tested here
# is the one vendored beside it):
#   harness/vet-fixtures/retro-2026-09/run_arm.sh        (prefix vet-arm-run)
#   harness/vet-fixtures/correct-2026-10/run_arm.sh      (prefix run_arm)
#
# Hermetic: a PATH stub stands in for `claude`; the arm dir, its config and
# result files live under $TMP. No network, no writes outside $TMP.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- stub claude: ignores its arguments, writes a JSON envelope per STUB_MODE ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "${STUB_MODE:-ok}" in
  exit)
    printf '%s\n' '{"is_error": false, "result": "should not count"}'
    echo "stub: auth failed" >&2
    exit 7
    ;;
  is_error)
    printf '%s\n' '{"type": "result", "subtype": "error_max_turns", "is_error": true}'
    exit 0
    ;;
  invalid)
    printf '%s\n' '{truncated'
    exit 0
    ;;
  empty)
    printf '%s\n' '{"is_error": false, "result": "  "}'
    exit 0
    ;;
esac
printf '%s\n' '{"type": "result", "subtype": "success", "is_error": false, "result": "finding one", "num_turns": 3}'
exit 0
STUB
chmod +x "$TMP/bin/claude"

# run_arm <script> <arm-dir> <mode>
run_arm() {
  local script="$1" arm="$2" mode="$3"
  rm -rf "$arm"
  mkdir -p "$arm"
  printf 'report on ./repo\n' >"$arm/prompt.txt"
  PATH="$TMP/bin:$PATH" STUB_MODE="$mode" bash "$script" "$arm"
}

# expect_reject <script> <prefix> <mode> <needle> <exit-code-line>
# The run must exit nonzero, name the failure, keep the EXIT_CODE line and
# still write tools.txt (a failed arm keeps its forensics).
expect_reject() {
  local script="$1" prefix="$2" mode="$3" needle="$4" ecline="$5"
  local name="${prefix}_${mode}_is_not_a_successful_run"
  local arm="$TMP/arm-$prefix-$mode" output rc=0
  output=$(run_arm "$script" "$arm" "$mode" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$name: runner exited 0 (a failed invocation was accepted)"
    printf '%s\n' "$output" >&2
    return
  fi
  case "$output" in
    *"$needle"*) ;;
    *) bad "$name: output lacked '$needle'"; printf '%s\n' "$output" >&2; return ;;
  esac
  if ! grep -qx "$ecline" "$arm/stderr.txt"; then
    bad "$name: stderr.txt lacked '$ecline'"
    return
  fi
  if [ ! -s "$arm/tools.txt" ]; then
    bad "$name: tools.txt was not written for the failed arm"
    return
  fi
  ok
  echo "PASS: $name"
}

# expect_accept <script> <prefix>
expect_accept() {
  local script="$1" prefix="$2"
  local name="${prefix}_usable_result_exits_0"
  local arm="$TMP/arm-$prefix-ok" output rc=0
  output=$(run_arm "$script" "$arm" ok 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name: runner exited $rc on a usable result"
    printf '%s\n' "$output" >&2
    return
  fi
  for f in result.json stderr.txt tools.txt; do
    [ -e "$arm/$f" ] || { bad "$name: $f was not written"; return; }
  done
  if ! grep -qx 'EXIT_CODE=0' "$arm/stderr.txt"; then
    bad "$name: stderr.txt lacked EXIT_CODE=0"
    return
  fi
  case "$output" in
    *"$prefix: wrote result.json, stderr.txt, tools.txt in "*) ;;
    *) bad "$name: output lacked the wrote line"; printf '%s\n' "$output" >&2; return ;;
  esac
  ok
  echo "PASS: $name"
}

check_copy() {
  local script="$1" prefix="$2"
  [ -f "$script" ] || { bad "script not found at $script"; return; }
  bash -n "$script" || { bad "$script does not parse"; return; }
  expect_reject "$script" "$prefix" exit "$prefix: claude exited 7" 'EXIT_CODE=7'
  expect_reject "$script" "$prefix" is_error "$prefix: result.json: is_error=true" 'EXIT_CODE=0'
  expect_reject "$script" "$prefix" invalid "$prefix: result.json lacks a valid result (" 'EXIT_CODE=0'
  expect_reject "$script" "$prefix" empty "$prefix: result.json lacks a valid result" 'EXIT_CODE=0'
  expect_accept "$script" "$prefix"
}

check_copy "$REPO/harness/vet-fixtures/retro-2026-09/run_arm.sh" vet-arm-run
check_copy "$REPO/harness/vet-fixtures/correct-2026-10/run_arm.sh" run_arm

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
