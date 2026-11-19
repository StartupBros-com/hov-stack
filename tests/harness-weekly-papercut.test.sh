#!/usr/bin/env bash
# Hermetic regression contract for the "papercuts rollup" section of
# scripts/harness-weekly.sh.
#
# THE DEFECT THIS EXISTS TO FIX: the section used to run papercut with
# 2>/dev/null. papercut's gh chokepoint emits one actionable diagnostic on
# stderr (gh missing, or present but unauthenticated) and STILL exits 0 with a
# normal-looking report, so an unattended weekly run on a box with broken gh
# printed a healthy-looking section while every remote-state read in it was
# unanswerable. Rehearsed 2026-08-29 against a copy of the live store with gh
# removed from PATH: flagged 140 -> 138, suppressed families 1 -> 3, and the
# only visible tell was a buried "disposition_unknown" line.
#
# EXTRACTION APPROACH: same as harness-weekly-tokscale.test.sh -- sed the real
# shipped section out of harness-weekly.sh and run that, so this exercises the
# shipped code rather than a hand-copied reimplementation. The sanity checks
# below fail loudly if the extraction comes back empty or stops invoking
# papercut, so renaming the section cannot silently turn this into a test of
# nothing.
#
# SEAM: the block invokes python3 "$HOME/.claude/bin/papercut.py", so pointing
# HOME at a scratch tree holding a stub CLI is the whole injection. No
# production seam was added for testability.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/scripts/harness-weekly.sh
TMP=$(mktemp -d /tmp/hw-papercut-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in
    *"$needle"*) ok ;;
    *) bad "$label: missing [$needle]"$'\n'"$output" ;;
  esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in
    *"$needle"*) bad "$label: unexpectedly contained [$needle]"$'\n'"$output" ;;
    *) ok ;;
  esac
}

# -- extract the shipped section --------------------------------------------
sed -n '/^  echo "## papercuts rollup/,/^  echo "## denial triage digest/p' "$SRC" \
  | sed '$d' > "$TMP/section.sh"
if [ ! -s "$TMP/section.sh" ]; then
  echo "FAIL: extraction produced nothing - did the section header change?" >&2
  exit 1
fi
grep -q 'papercut.py' "$TMP/section.sh" || {
  echo "FAIL: extracted section no longer invokes papercut.py" >&2
  exit 1
}
grep -q 'papercut-backfill.js' "$TMP/section.sh" || {
  echo "FAIL: extracted section no longer runs the transcript backfill" >&2
  exit 1
}

# -- stub CLI: stdout, stderr and exit code driven by env -------------------
make_home() {
  local home=$TMP/$1
  mkdir -p "$home/.claude/bin"
  {
    echo 'import os, sys'
    echo 'sys.stdout.write("## papercuts rollup\npapercuts-flagged:0\n")'
    echo 'sub = sys.argv[1] if len(sys.argv) > 1 else ""'
    echo 'key = "PC_STUB_STDERR_ROLLUP" if sub == "rollup" else "PC_STUB_STDERR_STALENESS"'
    echo 'err = os.environ.get(key, "")'
    echo 'if err:'
    echo '    sys.stderr.write(err + "\n")'
    echo 'sys.exit(int(os.environ.get("PC_STUB_EXIT", "0")))'
  } > "$home/.claude/bin/papercut.py"
  mkdir -p "$home/.claude/scripts"
  # The transcript backfill (dotfiles#1553) runs under node on its own seam.
  {
    echo 'process.stdout.write(process.env.PC_BACKFILL_STDOUT || "papercut backfill: 0 transcripts\n");'
    echo 'if (process.env.PC_BACKFILL_STDERR) process.stderr.write(process.env.PC_BACKFILL_STDERR + "\n");'
    echo 'process.exit(Number(process.env.PC_BACKFILL_EXIT || 0));'
  } > "$home/.claude/scripts/papercut-backfill.js"
  echo "$home"
}

run_section() {
  ( HOME="$1" PC_STUB_STDERR_ROLLUP="${PC_STUB_STDERR_ROLLUP:-}" \
      PC_STUB_STDERR_STALENESS="${PC_STUB_STDERR_STALENESS:-}" \
      PC_BACKFILL_STDERR="${PC_BACKFILL_STDERR:-}" \
      PC_BACKFILL_EXIT="${PC_BACKFILL_EXIT:-0}" \
      bash "$TMP/section.sh" 2>&1 )
}

DIAG="ERROR: GitHub CLI (gh) is unavailable: it is not installed, or not on PATH"

# 1. the defect: a diagnostic on stderr must reach the report
h=$(make_home diag)
out=$(PC_STUB_STDERR_ROLLUP="$DIAG" PC_STUB_EXIT=0 run_section "$h")
contains "$out" "$DIAG" "rollup stderr must be surfaced, not discarded"
contains "$out" "WARN papercut rollup diagnostics" "surfaced diagnostic must be labelled WARN"
contains "$out" "papercuts-flagged:0" "the normal report must still print"

# 2. planted negative: a clean run must not manufacture a warning
h=$(make_home clean)
out=$(PC_STUB_EXIT=0 run_section "$h")
omits "$out" "WARN papercut rollup diagnostics" "a silent run must stay silent"
omits "$out" "WARN papercut staleness diagnostics" "a silent staleness run must stay silent"
contains "$out" "papercuts-flagged:0" "the normal report must still print"

# 3. a hard crash keeps its existing WARN
h=$(make_home crash)
out=$(PC_STUB_EXIT=1 run_section "$h")
contains "$out" "WARN papercuts rollup crashed" "a non-zero exit keeps its own warning"

# 4. the staleness call surfaces its stderr too, under its own label
h=$(make_home both)
out=$(PC_STUB_STDERR_STALENESS="$DIAG" PC_STUB_EXIT=0 run_section "$h")
contains "$out" "WARN papercut staleness diagnostics" "staleness stderr is surfaced under its own label"

# 5. the transcript backfill runs BEFORE the rollup, so this week's rollup
#    counts what it recorded (dotfiles#1553)
h=$(make_home bforder)
out=$(run_section "$h")
case "$out" in
  *"papercut backfill: 0 transcripts"*"papercuts-flagged:0"*) ok ;;
  *) bad "backfill must run before the rollup"$'\n'"$out" ;;
esac
omits "$out" "WARN papercut transcript backfill crashed" "a clean backfill must not warn"
omits "$out" "WARN papercut backfill diagnostics" "a silent backfill must stay silent"

# 6. a backfill crash is a WARN, and the rollup still runs
h=$(make_home bfcrash)
out=$(PC_BACKFILL_EXIT=1 run_section "$h")
contains "$out" "WARN papercut transcript backfill crashed" "a backfill crash keeps its own warning"
contains "$out" "papercuts-flagged:0" "the rollup still runs after a backfill crash"

# 7. backfill stderr is surfaced under its own label
h=$(make_home bferr)
out=$(PC_BACKFILL_STDERR="papercut-backfill: skipped /x.jsonl: EACCES" run_section "$h")
contains "$out" "WARN papercut backfill diagnostics" "backfill stderr is surfaced under its own label"
contains "$out" "skipped /x.jsonl: EACCES" "the diagnostic text itself reaches the report"

# 8. the weekly report asks the doctor to run the (opt-in) test suites
if grep -qE '^ *"\$SCRIPTS/harness-doctor\.sh" --with-tests$' "$SRC"; then ok
else bad "harness-weekly.sh must invoke harness-doctor.sh with --with-tests"; fi

echo "harness-weekly papercut section: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
