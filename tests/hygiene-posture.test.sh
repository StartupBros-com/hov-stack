#!/usr/bin/env bash
# Tests for lib/hygiene-posture.sh: the host-declared posture of the hygiene timers.
# Hermetic: HOV_STACK_OVERLAY points at a temp dir, and the systemd-analyze arms use a
# stub first on PATH, so nothing here reads the real overlay or the real systemd.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

unset XDG_CONFIG_HOME
OVERLAY=$TMP/overlay
mkdir -p "$OVERLAY"
export HOV_STACK_OVERLAY=$OVERLAY
# shellcheck source=lib/hygiene-posture.sh
. "$REPO/lib/hygiene-posture.sh"

# expect_eq LABEL EXPECTED ACTUAL
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1:"$'\n'"  expected: $(printf '%q' "$2")"$'\n'"  actual:   $(printf '%q' "$3")"; fi
}

# -- file location ------------------------------------------------------------
expect_eq "posture file path" "$OVERLAY/hygiene-posture" "$(hygiene_posture_file)"
expect_eq "drop-in name constant" "50-hygiene-posture.conf" "$HYGIENE_POSTURE_DROPIN"

# -- missing file: nothing, success -------------------------------------------
out=$(hygiene_posture_load 2>&1); rc=$?
expect_eq "missing file prints nothing" "" "$out"
expect_eq "missing file returns 0" "0" "$rc"
expect_eq "missing file: no declared stems" "" "$(hygiene_posture_declared)"

# -- valid file ----------------------------------------------------------------
printf '%s\n' \
  '# a comment' \
  '' \
  '   # an indented comment' \
  'wt-sweep DRY_RUN=0' \
  'wt-sweep OnCalendar=Thu *-*-* 01:15:00' \
  '  reclaim-sweep   RECLAIM_SWEEP_APPLY=1  ' \
  'reclaim-sweep OnCalendar=*:41' \
  'pkg-cache-prune' \
  'docker-hygiene DRY_RUN=1' \
  'docker-hygiene STOP_ORPHANS=0' \
  'docker-hygiene REAP_VOLUMES=1' \
  'wt-sweep PUSH=0' >"$OVERLAY/hygiene-posture"
rows=$(hygiene_posture_load 2>&1); rc=$?
expect_eq "valid file returns 0" "0" "$rc"
expected_rows=$(printf '%s\n' \
  $'wt-sweep\tDRY_RUN\t0' \
  $'wt-sweep\tOnCalendar\tThu *-*-* 01:15:00' \
  $'reclaim-sweep\tRECLAIM_SWEEP_APPLY\t1' \
  $'reclaim-sweep\tOnCalendar\t*:41' \
  $'pkg-cache-prune\t\t' \
  $'docker-hygiene\tDRY_RUN\t1' \
  $'docker-hygiene\tSTOP_ORPHANS\t0' \
  $'docker-hygiene\tREAP_VOLUMES\t1' \
  $'wt-sweep\tPUSH\t0')
expect_eq "normalized rows" "$expected_rows" "$rows"

# shellcheck disable=SC2034 # read by the sourced library
HYGIENE_POSTURE_ROWS=$rows
expect_eq "declared stems, file order, once each" \
  $'wt-sweep\nreclaim-sweep\npkg-cache-prune\ndocker-hygiene' "$(hygiene_posture_declared)"

expect_eq "service drop-in text" \
  "# Written by sync.sh install from the overlay's hygiene-posture file.
# Edit that file, not this one; install rewrites or removes this drop-in.
[Service]
Environment=DRY_RUN=0
Environment=PUSH=0" "$(hygiene_posture_render wt-sweep service)"
expect_eq "timer drop-in text (empty OnCalendar resets the shipped schedule)" \
  "# Written by sync.sh install from the overlay's hygiene-posture file.
# Edit that file, not this one; install rewrites or removes this drop-in.
[Timer]
OnCalendar=
OnCalendar=Thu *-*-* 01:15:00" "$(hygiene_posture_render wt-sweep timer)"
expect_eq "reclaim-sweep service drop-in" \
  "# Written by sync.sh install from the overlay's hygiene-posture file.
# Edit that file, not this one; install rewrites or removes this drop-in.
[Service]
Environment=RECLAIM_SWEEP_APPLY=1" "$(hygiene_posture_render reclaim-sweep service)"
expect_eq "bare stem renders no service drop-in" "" "$(hygiene_posture_render pkg-cache-prune service)"
expect_eq "bare stem renders no timer drop-in" "" "$(hygiene_posture_render pkg-cache-prune timer)"
expect_eq "kind with no settings renders nothing" "" "$(hygiene_posture_render docker-hygiene timer)"
expect_eq "undeclared stem renders nothing" "" "$(hygiene_posture_render nothing-here service)"
first=$(hygiene_posture_render wt-sweep service; hygiene_posture_render wt-sweep timer)
second=$(hygiene_posture_render wt-sweep service; hygiene_posture_render wt-sweep timer)
expect_eq "render is deterministic" "$first" "$second"
unset HYGIENE_POSTURE_ROWS

# render without preloaded rows loads the file itself
expect_eq "render loads the overlay file when no rows are preloaded" \
  "# Written by sync.sh install from the overlay's hygiene-posture file.
# Edit that file, not this one; install rewrites or removes this drop-in.
[Service]
Environment=RECLAIM_SWEEP_APPLY=1" "$(hygiene_posture_render reclaim-sweep service)"

# -- each error class returns 1, prints the reason and the line, applies nothing --
# expect_invalid LABEL REASON-FRAGMENT FILE-LINES...
expect_invalid() {
  local label=$1 reason=$2 stdout stderr rc
  shift 2
  printf '%s\n' "$@" >"$OVERLAY/hygiene-posture"
  stdout=$(hygiene_posture_load 2>"$TMP/err"); rc=$?
  stderr=$(cat "$TMP/err")
  expect_eq "$label: returns 1" "1" "$rc"
  expect_eq "$label: prints no rows" "" "$stdout"
  case $stderr in
    *"hygiene-posture: $reason"*) ok ;;
    *) bad "$label: stderr lacks 'hygiene-posture: $reason': $stderr" ;;
  esac
}
expect_invalid "unknown stem" "unknown unit stem: nonsense DRY_RUN=0" 'nonsense DRY_RUN=0'
expect_invalid "stem outside the four" "unknown unit stem: dcg-auto-update" 'dcg-auto-update'
expect_invalid "unknown key" "unknown key for wt-sweep: wt-sweep RECLAIM_SWEEP_APPLY=1" 'wt-sweep RECLAIM_SWEEP_APPLY=1'
expect_invalid "typo DRYRUN" "unknown key for wt-sweep: wt-sweep DRYRUN=0" 'wt-sweep DRYRUN=0'
expect_invalid "key valid for another stem" "unknown key for pkg-cache-prune: pkg-cache-prune PUSH=1" 'pkg-cache-prune PUSH=1'
expect_invalid "value 2" "value must be 0 or 1: wt-sweep DRY_RUN=2" 'wt-sweep DRY_RUN=2'
expect_invalid "empty value" "value must be 0 or 1: wt-sweep DRY_RUN=" 'wt-sweep DRY_RUN='
expect_invalid "missing equals" "expected KEY=value: wt-sweep DRY_RUN" 'wt-sweep DRY_RUN'
expect_invalid "OnCalendar bad character" "OnCalendar has a character outside" 'wt-sweep OnCalendar=daily;rm'
# shellcheck disable=SC2016 # a literal $, not an expansion
expect_invalid "OnCalendar dollar" "OnCalendar has a character outside" 'wt-sweep OnCalendar=$HOME'
expect_invalid "empty OnCalendar" "empty OnCalendar: wt-sweep OnCalendar=" 'wt-sweep OnCalendar='
expect_invalid "duplicate key" "duplicate key for wt-sweep: wt-sweep DRY_RUN=1" 'wt-sweep DRY_RUN=0' 'wt-sweep DRY_RUN=1'
expect_invalid "duplicate OnCalendar" "duplicate key for reclaim-sweep: reclaim-sweep OnCalendar=daily" \
  'reclaim-sweep OnCalendar=weekly' 'reclaim-sweep OnCalendar=daily'

# One bad line invalidates the whole file, and every error is printed.
printf '%s\n' 'wt-sweep DRY_RUN=0' 'wt-sweep DRYRUN=0' 'bogus' >"$OVERLAY/hygiene-posture"
stdout=$(hygiene_posture_load 2>"$TMP/err"); rc=$?
expect_eq "mixed file: returns 1" "1" "$rc"
expect_eq "mixed file: applies none of it" "" "$stdout"
expect_eq "mixed file: both errors printed" "2" "$(grep -c '^hygiene-posture: ' "$TMP/err")"

# The same key on different stems is not a duplicate.
printf '%s\n' 'wt-sweep DRY_RUN=0' 'docker-hygiene DRY_RUN=0' >"$OVERLAY/hygiene-posture"
hygiene_posture_load >/dev/null 2>&1; expect_eq "same key on two stems is valid" "0" "$?"

# Present but unreadable is invalid, not "nothing declared": an empty answer would let
# install remove the drop-ins the host declared. Root reads mode 000, so the arm runs
# only where the mode actually denies the read.
printf '%s\n' 'wt-sweep DRY_RUN=0' >"$OVERLAY/hygiene-posture"
chmod 000 "$OVERLAY/hygiene-posture"
if [ ! -r "$OVERLAY/hygiene-posture" ]; then
  stdout=$(hygiene_posture_load 2>"$TMP/err"); rc=$?
  expect_eq "unreadable file: returns 1" "1" "$rc"
  expect_eq "unreadable file: prints no rows" "" "$stdout"
  grep -qF 'hygiene-posture: cannot read the posture file:' "$TMP/err" && ok || bad "unreadable file: no cannot-read error: $(cat "$TMP/err")"
fi
chmod 600 "$OVERLAY/hygiene-posture"
rm -f "$OVERLAY/hygiene-posture"
mkdir "$OVERLAY/hygiene-posture"
stdout=$(hygiene_posture_load 2>"$TMP/err"); rc=$?
expect_eq "directory in place of the file: returns 1" "1" "$rc"
grep -qF 'hygiene-posture: cannot read the posture file:' "$TMP/err" && ok || bad "directory in place of the file: no cannot-read error: $(cat "$TMP/err")"
rmdir "$OVERLAY/hygiene-posture"

# -- systemd-analyze arms ------------------------------------------------------
STUB_BIN=$TMP/stub-bin
mkdir -p "$STUB_BIN"
# shellcheck disable=SC2016 # the stub's own variables
printf '%s\n' '#!/usr/bin/env bash' \
  '[ "${1:-}" = calendar ] || exit 64' \
  'printf "%s\n" "$2" >>"${ANALYZE_LOG:?}"' \
  'case "$2" in rejected-by-systemd*) exit 1 ;; esac' \
  'exit 0' >"$STUB_BIN/systemd-analyze"
chmod +x "$STUB_BIN/systemd-analyze"
export ANALYZE_LOG=$TMP/analyze.log
: >"$ANALYZE_LOG"
printf '%s\n' 'wt-sweep OnCalendar=Thu *-*-* 01:15:00' >"$OVERLAY/hygiene-posture"
PATH="$STUB_BIN:$PATH" hygiene_posture_load >/dev/null 2>&1; rc=$?
expect_eq "systemd-analyze present and accepting: valid" "0" "$rc"
expect_eq "systemd-analyze got the full value, spaces kept" "Thu *-*-* 01:15:00" "$(cat "$ANALYZE_LOG")"
printf '%s\n' 'wt-sweep OnCalendar=rejected-by-systemd' >"$OVERLAY/hygiene-posture"
err=$(PATH="$STUB_BIN:$PATH" hygiene_posture_load 2>&1 >/dev/null); rc=$?
expect_eq "systemd-analyze rejecting: invalid" "1" "$rc"
case $err in
  *"hygiene-posture: OnCalendar is not a valid calendar expression: wt-sweep OnCalendar=rejected-by-systemd"*) ok ;;
  *) bad "systemd-analyze rejection message missing: $err" ;;
esac
# Absent systemd-analyze: the character check alone applies. PATH holds only the
# tools the library uses, linked into a bin directory with no systemd-analyze.
NO_ANALYZE_BIN=$TMP/no-analyze-bin
mkdir -p "$NO_ANALYZE_BIN"
for t in dirname readlink cat; do ln -s "$(command -v "$t")" "$NO_ANALYZE_BIN/$t"; done
: >"$ANALYZE_LOG"
(
  PATH=$NO_ANALYZE_BIN
  command -v systemd-analyze >/dev/null 2>&1 && exit 7
  hygiene_posture_load >/dev/null 2>&1
) ; rc=$?
expect_eq "without systemd-analyze the character check alone applies (rejected-by-systemd passes)" "0" "$rc"
expect_eq "without systemd-analyze nothing was asked of it" "" "$(cat "$ANALYZE_LOG")"

# -- a relative overlay is ignored ---------------------------------------------
mkdir -p "$TMP/rel"
printf '%s\n' 'wt-sweep DRY_RUN=0' >"$TMP/rel/hygiene-posture"
(
  cd "$TMP" || exit 9
  HOV_STACK_OVERLAY=rel
  if hygiene_posture_file >/dev/null 2>&1; then exit 1; fi
  [ -z "$(hygiene_posture_load 2>&1)" ] || exit 2
  hygiene_posture_load >/dev/null 2>&1 || exit 3
); rc=$?
expect_eq "relative overlay is ignored (no file, no rows, success)" "0" "$rc"

if [ "$fail" -eq 0 ]; then
  echo "ok — hygiene-posture: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — hygiene-posture: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
