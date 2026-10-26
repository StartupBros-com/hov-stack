#!/usr/bin/env bash
# Tests for scripts/deferral-watch.sh (issue #432). Hermetic: fixture
# TSVs under mktemp, no network, no real crontab/loop-logs (the founding
# entries' commands never run here — fixtures carry their own commands, and
# T7 runs the committed arena command only under a stubbed crontab).
#
# Planted negatives from the issue plus the inward vet:
#  - fired detection: two near-identical entries whose trigger_check differs
#    ONLY in exit code (0 vs 1). Swallowed exit codes or a first-row
#    short-circuit misclassifies one.
#  - check-broken: a missing binary must classify broken, DISTINCT from quiet
#    — silent skip == green is the failure shape this mechanism exists to
#    prevent. Same for an unknown status column and an EMPTY trigger_check
#    (bash -c "" exits 0 and would otherwise read as FIRED).
#  - T6: a final row with no trailing newline must still be classified —
#    plain `read` drops it silently (both vet lenses reproduced a fired
#    trigger vanishing with a clean exit 0).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
SCRIPT="$HERE/scripts/deferral-watch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: not found: $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

T=$'\t'

echo "== T1: fired vs quiet (exit-code planted-negative pair) + manual + resolved-skip + comments + source column =="
cat >"$TMP/wl1.tsv" <<EOF
# comment line must be ignored
fires${T}active${T}2026-08-21${T}-${T}src-f${T}true${T}differs from quiets only in exit code
quiets${T}active${T}2026-08-21${T}-${T}src-q${T}false${T}differs from fires only in exit code
handsy${T}active${T}2026-08-21${T}-${T}src-m${T}MANUAL: operator judgment${T}manual entry must be listed, never run
oldone${T}resolved${T}2026-07-01${T}2026-08-01${T}src-r${T}true${T}resolved rows are history, never run — this one would fire if run
EOF
OUT=$(bash "$SCRIPT" --file "$TMP/wl1.tsv"); RC=$?
[ "$RC" = 1 ] && ok || bad "T1 exit $RC (want 1: fired present, nothing broken)"
[ "$OUT" = "fires${T}fired${T}src-f
quiets${T}quiet${T}src-q
handsy${T}manual${T}src-m" ] && ok || bad "T1 output wrong (3 columns id/outcome/source expected):
$OUT"
grep -q "oldone" <<<"$OUT" && bad "T1 resolved entry was not skipped" || ok

echo "== T2: broken is DISTINCT from quiet (missing binary, weird exit, unknown status, EMPTY check) =="
{
  printf '%s\n' "nobin${T}active${T}2026-08-21${T}-${T}src${T}this-binary-does-not-exist-431x${T}127 must classify broken, not quiet"
  printf '%s\n' "weird${T}active${T}2026-08-21${T}-${T}src${T}exit 7${T}nonstandard exit must classify broken"
  printf '%s\n' "quiets${T}active${T}2026-08-21${T}-${T}src${T}false${T}the control that must stay quiet"
  printf '%s\n' "badstatus${T}someday${T}2026-08-21${T}-${T}src${T}true${T}unknown status column is a data error, fail closed"
  printf '%s\n' "shortrow${T}active"
} >"$TMP/wl2.tsv"
OUT=$(bash "$SCRIPT" --file "$TMP/wl2.tsv"); RC=$?
[ "$RC" = 2 ] && ok || bad "T2 exit $RC (want 2: broken present)"
[ "$(printf '%s\n' "$OUT" | grep -c "broken")" = 4 ] && ok || bad "T2 wants 4 broken (nobin, weird, badstatus, shortrow — an empty check must NOT run bash -c '' and read as fired):
$OUT"
grep -q "^quiets${T}quiet" <<<"$OUT" && ok || bad "T2 control entry not quiet:
$OUT"
grep -q "^shortrow${T}fired" <<<"$OUT" && bad "T2 short row classified FIRED (bash -c '' trap)" || ok

echo "== T3: broken dominates fired in the exit code =="
cat >"$TMP/wl3.tsv" <<EOF
fires${T}active${T}2026-08-21${T}-${T}src${T}true${T}fired
nobin${T}active${T}2026-08-21${T}-${T}src${T}this-binary-does-not-exist-431x${T}broken
EOF
bash "$SCRIPT" --file "$TMP/wl3.tsv" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "T3 exit $RC (want 2: broken must dominate fired)"

echo "== T4: all quiet/manual exits 0; missing file exits 64 =="
cat >"$TMP/wl4.tsv" <<EOF
quiets${T}active${T}2026-08-21${T}-${T}src${T}false${T}quiet
handsy${T}active${T}2026-08-21${T}-${T}src${T}MANUAL: reason${T}manual
EOF
bash "$SCRIPT" --file "$TMP/wl4.tsv" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "T4 exit $RC (want 0: nothing fired or broken)"
bash "$SCRIPT" --file "$TMP/does-not-exist.tsv" 2>/dev/null; RC=$?
[ "$RC" = 64 ] && ok || bad "T4 missing-file exit $RC (want 64)"

echo "== T5: the committed watchlist parses — every row classifies, none unparseable =="
# Run against the REAL committed file but under a scratch HOME (so the
# circuit-breaker entry reads this test's empty ~, not the operator's) and
# with crontab successfully empty, the timer disabled, and gh unauthenticated.
# Never consult the real user manager or a developer's authenticated gh.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/crontab"
printf '#!/usr/bin/env bash\nprintf "disabled\\n"\nexit 1\n' >"$TMP/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/gh"
chmod +x "$TMP/bin/crontab" "$TMP/bin/systemctl" "$TMP/bin/gh"
OUT=$(PATH="$TMP/bin:$PATH" bash "$SCRIPT" --file "$HERE/harness/deferral-watchlist.tsv"); RC=$?
[ "$(printf '%s\n' "$OUT" | grep -cE "^[a-z0-9-]+${T}(fired|quiet|broken|manual)${T}.+$")" = "$(printf '%s\n' "$OUT" | grep -c .)" ] \
  && ok || bad "T5 committed watchlist produced unclassifiable lines (3 columns incl. source required):
$OUT"
# One output line per ACTIVE row, pinned by id INDEPENDENTLY of the file under
# test (review finding on PR 1186: deriving the expected count from the same
# file made an accidental resolve or a dropped row invisible). Resolving or
# adding a row must update this list on purpose.
T5_EXPECTED="arena-crontab-rot ce-upstream-1711 linear-adoption-triggers"
T5_GOT=$(printf '%s\n' "$OUT" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')
[ "$T5_GOT" = "$T5_EXPECTED" ] && ok || bad "T5 active rows differ from the pinned set: got [$T5_GOT] want [$T5_EXPECTED]"
grep -q "broken" <<<"$OUT" && bad "T5 committed watchlist has a BROKEN check under stubbed env:
$OUT" || ok

echo "== T6: a final row with NO trailing newline is still classified (read-loop EOF trap) =="
printf '%s\n%s' \
  "rowone${T}active${T}2026-08-21${T}-${T}src${T}false${T}newline-terminated control" \
  "lastrow${T}active${T}2026-08-21${T}-${T}src-l${T}true${T}must not be dropped" >"$TMP/wl6.tsv"
OUT=$(bash "$SCRIPT" --file "$TMP/wl6.tsv"); RC=$?
grep -q "^lastrow${T}fired${T}src-l" <<<"$OUT" && ok \
  || bad "T6 last row without trailing newline was dropped or misclassified:
$OUT"
[ "$RC" = 1 ] && ok || bad "T6 exit $RC (want 1: the un-terminated last row FIRED)"

echo "== T7: the committed arena-crontab command fires on ANY stale occurrence (duplicate keys) =="
ARENA_CMD=$(awk -F'\t' '$1=="arena-crontab-rot"{print $6}' "$HERE/harness/deferral-watchlist.tsv")
[ -n "$ARENA_CMD" ] && ok || bad "T7 could not extract arena-crontab-rot trigger_check from committed watchlist"
run_arena() { # $1 = crontab -l stdout fixture
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$1" >"$TMP/bin/crontab"
  chmod +x "$TMP/bin/crontab"
  PATH="$TMP/bin:$PATH" timeout 30 bash -c "$ARENA_CMD" >/dev/null 2>&1
}
run_arena "@reboot x ARENA_SEASON_END=2099-01-01T00:00:00Z cmd"; RC=$?
[ "$RC" = 1 ] && ok || bad "T7 future-only date should be quiet, got $RC"
run_arena "@reboot x ARENA_SEASON_END=2020-01-01T00:00:00Z cmd"; RC=$?
[ "$RC" = 0 ] && ok || bad "T7 stale date should fire, got $RC"
run_arena "@reboot x ARENA_SEASON_END=2099-01-01T00:00:00Z cmd
@daily y ARENA_SEASON_END=2020-01-01T00:00:00Z cmd2"; RC=$?
[ "$RC" = 0 ] && ok || bad "T7 stale SECOND occurrence must fire (first-match-wins trap), got $RC"

echo
echo "deferral-watchlist: $pass passed, $fail failed"
[ "$fail" = 0 ]
