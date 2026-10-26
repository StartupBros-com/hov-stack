#!/usr/bin/env bash
# The reader for dcg-update's promote-outcome record.
#
# Recording an outcome that nothing reads is a gesture, not a check -- so this
# suite drives the REAL detector block, lifted out of harness-weekly.sh, against
# synthetic histories. It exists because the first reader was wrong in two ways
# that a passing weekly run could never surface:
#
#   1. It counted REFUSED only, "since the last successful promote" -- but a
#      successful promote recorded NOTHING, so the count never reset. Three
#      correct refusals followed by a healthy promote kept the WARN on forever,
#      and a WARN that is always on is one that gets muted.
#   2. A history alternating REFUSED / SKIPPED / ERROR left every per-tag streak
#      at 1 and stayed silent, which is precisely the state worth warning about:
#      the guard is not advancing for any reason at all.
#
# Both are asserted below as histories, not as claims about the code.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WEEKLY=$REPO/scripts/harness-weekly.sh
UPDATE=$REPO/scripts/dcg-update.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# Lift the detector out of the weekly script rather than restating it here. A
# restated copy would pass forever after the original drifted.
sed -n '/_stall=\$(tac/,/^      fi$/p' "$WEEKLY" > "$TMP/detect.sh"
grep -q 'PROMOTED' "$TMP/detect.sh" || {
  echo "FAIL: could not extract the stall detector from harness-weekly.sh" >&2; exit 1; }

# detect <line>... -> the WARN line, or empty
detect() {
  # %b, not %s: these fixtures carry \t escapes, and a history whose fields are
  # not really tab-separated makes every awk field test vacuously false -- the
  # detector would look correct while matching nothing at all.
  printf '%b\n' "$@" > "$TMP/history.tsv"
  { echo '_dcg_state='"$TMP"; cat "$TMP/detect.sh"; } > "$TMP/run.sh"
  bash "$TMP/run.sh" 2>/dev/null
}

want_warn() {  # want_warn <label> <expected-count> <history-line>...
  local label=$1 want=$2; shift 2
  local out; out=$(detect "$@")
  case "$out" in
    *"not promoted a candidate in $want consecutive runs"*) ok ;;
    "") bad "$label: expected a WARN naming $want runs, got silence" ;;
    *)  bad "$label: expected $want runs, got :: $out" ;;
  esac
}

want_silence() {  # want_silence <label> <history-line>...
  local label=$1; shift
  local out; out=$(detect "$@")
  [ -z "$out" ] && ok || bad "$label: expected silence, got :: $out"
}

R="t\tREFUSED\tv1\tno"
S="t\tSKIPPED\tv1\toffline"
E="t\tERROR\tv1\tbroke"
P="t\tPROMOTED\tv2\tyes"

want_warn "three straight refusals" 3 "$R" "$R" "$R"
want_warn "mixed stall, the case the old reader missed" 4 "$R" "$S" "$E" "$R"
want_warn "three offline nights" 3 "$S" "$S" "$S"

# Newest record is LAST in the file.
#
# HONEST SCOPE: these three are read-side. The old detector also stayed silent on
# them, because its `{exit}` stopped at the first non-REFUSED line whatever that
# line was. The defect that made its WARN permanent was on the WRITE side -- a
# promote recorded nothing, so the history never contained a PROMOTED row to stop
# at -- and that half is covered by the wiring assertion at the bottom, not here.
want_silence "a promote resets the streak" "$R" "$R" "$R" "$P"
want_silence "one refusal after a promote" "$R" "$P" "$R"
want_silence "nothing but a promote" "$P"

# Below the threshold: two is not a week of nightly runs saying no.
want_silence "two refusals is under the threshold" "$R" "$R"

# ---- wiring: the record the reader depends on --------------------------------
# The reader above is only true if a successful promote actually writes PROMOTED.
# Assert the call exists and sits on the promote path, after the announcement.
_echo_ln=$(grep -n 'PROMOTED v\$cur -> v\$latest' "$UPDATE" | head -1 | cut -d: -f1)
_rec_ln=$(grep -n '^record_outcome PROMOTED' "$UPDATE" | head -1 | cut -d: -f1)
if [ -n "$_echo_ln" ] && [ -n "$_rec_ln" ] && [ "$_rec_ln" -gt "$_echo_ln" ]; then ok
else bad "a successful promote does not record PROMOTED (echo=$_echo_ln record=$_rec_ln)"; fi

# The offline record used to tag every entry a literal `v?`: $cur is parsed from
# the JSON the branch has just failed to fetch, so it does not exist yet.
grep -q 'record_outcome SKIPPED "v\${cur' "$UPDATE" &&
  bad 'the SKIPPED record still reads $cur, which is unset on that branch' || ok

if [ "$fail" -eq 0 ]; then
  echo "ok — dcg outcome streak reader: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — dcg outcome streak reader: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
