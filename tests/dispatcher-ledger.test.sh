#!/usr/bin/env bash
# Tests for scripts/dispatcher-ledger.sh (issue #444, always-on work
# dispatcher plan, KTD3/KTD4). Hermetic: DISPATCHER_LEDGER_FILE points every
# invocation at a scratch file under mktemp, and HOME is also redirected to
# scratch as a second belt (nothing here should ever touch the operator's
# real ~/.claude/logs/dispatcher-ledger.jsonl even if a call forgets the env
# override). No network, no gh, no real pids beyond throwaway `sleep` children
# this suite spawns and kills itself.
#
# Planted negatives (contract + inward-vet shape):
#  - T2 (AE9): a launched row's pid must be probed with real kill -0
#    liveness, not assumed dead/alive -- a dead-child fixture (spawn, kill,
#    wait) is the only way to prove the probe actually ran.
#  - T3: an orphaned claim (no launched sibling) must age out on WALL TIME
#    from its OWN ts, not tick count -- the fixture plants a ts far in the
#    past directly, bypassing `date -u now`, so a reconcile that ignores ts
#    and only checks "no launched row" would over-fire on every fresh claim.
#  - T4: FIRST-TERMINAL-WINS is the ledger's core invariant. A naive
#    reconcile that trusts --pr-state over ledger state would flip a kept run
#    to waste on a stale/wrong PR-state row; a naive append would let a
#    second terminal event silently overwrite the first disposition.
#  - T6: a hand-corrupted line (not valid JSON) must not abort the read loop
#    -- one bad line is not licence to blind the whole summary.
#  - T7: a transition row (e.g. `launched`) with no prior `claimed` sibling
#    must be surfaced, not silently ignored or crashed on -- it is evidence
#    of a lost/never-written claim row.
#  - T8 (R16 equality): keep-rate and cost-per-kept must equal the EXACT
#    hand-computed values from a fixture chosen so the arithmetic has no
#    rounding ambiguity (kept=3,waste=1 -> 75%; two clean $2/$4 kept rows ->
#    $3 cost-per-kept; one contaminated (overlap:true) kept row is excluded
#    from that average and its count reported separately).
#  - T9: an unwritable ledger path must fail with ONE diagnostic line and a
#    nonzero exit, never an uncaught bash error / stack-trace-shaped output
#    that could abort a caller's own `set -e` flow (best-effort-silent).
#  - T10 (GAP1): `append --pr` must actually land on the claimed row (not
#    silently dropped), and reconcile's existing --pr-state handling must
#    keep working unchanged once a claimed row carries one.
#  - T14/T15 (issue #584): an `ended` row exempts a run from BOTH of
#    reconcile's liveness rules (dead-pid and orphaned-claim age) -- a
#    completed run awaiting its PR verdict is not broken, and a reconcile
#    pass right after a clean end must be a byte-for-byte no-op. T14 also
#    re-proves the narrowed rule still fires (dead pid + NO ended row ->
#    broken; T2 is the from-scratch version of that same negative).
#  - T16/T17 (issue #584): audit-correction repairs a mis-marked terminal
#    WITHOUT weakening first-terminal-wins -- the wrong row stays, a second
#    terminal append stays refused, and summary counts the run by the
#    correction's disposition (or as undispositioned while it is pending).
#  - T19-T25 (issue #1428, KTD5/AE4, U4): a run whose PR shows up AFTER its
#    claimed row (via the new pr-opened event) still reconciles, and a run
#    that never gets a PR still terminalizes. T19 pins pr-opened's own
#    --pr requirement. T20 disposes an empty-delivery ended run waste
#    immediately, with no TTL wait. T21/T23b are UNDER-TTL controls (stay
#    non-terminal); T22/T23 cross the default 48h and an explicit
#    --claim-ttl-hours override respectively -- both waste. T24 proves the
#    no-pr rules' own pr accessor scans EVERY row for the run (a pr-opened
#    row satisfies it exactly like claimed --pr did), so a run that got its
#    PR late is correctly left alone rather than wasted out from under it.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
SCRIPT="$HERE/scripts/dispatcher-ledger.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: not found: $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

run() { bash "$SCRIPT" "$@"; }   # under the current DISPATCHER_LEDGER_FILE

# Build a full claimed->launched->ended->DISPOSITION run in one call, used by
# several sections below where the exact cost/overlap/disposition values are
# the point of the test.
mk_run() { # run_id cost overlap disposition
  local rid="$1" cost="$2" overlap="$3" disp="$4"
  run append --event claimed --run-id "$rid" >/dev/null
  run append --event launched --run-id "$rid" --pid 1 >/dev/null
  run append --event ended --run-id "$rid" --exit 0 --cost "$cost" --tokens 100 --overlap "$overlap" >/dev/null
  run append --event "$disp" --run-id "$rid" >/dev/null
}

echo "== T1: happy path -- claimed/launched/ended/kept (A) + sibling waste (B) =="
export DISPATCHER_LEDGER_FILE="$TMP/t1.jsonl"
run append --event claimed --run-id A --issue 100 --repo o/r --config-k 1 --config-yield 5 --config-ratchets "none"
[ $? -eq 0 ] && ok || bad "T1 claimed A failed"
run append --event launched --run-id A --pid 111
run append --event ended --run-id A --exit 0 --cost 1.50 --tokens 1000 --overlap false
run append --event kept --run-id A
run append --event claimed --run-id B --issue 101 --repo o/r
run append --event launched --run-id B --pid 222
run append --event ended --run-id B --exit 1 --cost 2.50 --tokens 2000 --overlap false
run append --event waste --run-id B
OUT=$(run summary)
grep -qF "kept: 1   waste: 1   broken: 0" <<<"$OUT" && ok || bad "T1 disposition counts wrong:
$OUT"
grep -qF "keep-rate: 50% (1/2)" <<<"$OUT" && ok || bad "T1 keep-rate wrong:
$OUT"
grep -qF "cost-per-kept (clean, gateway window, upper bound): \$1.5 (n=1)" <<<"$OUT" && ok || bad "T1 cost-per-kept wrong:
$OUT"
grep -qF "dispatcher-flagged:0" <<<"$OUT" && ok || bad "T1 dispatcher-flagged should be 0:
$OUT"

echo "== T1b (dotfiles#1429): ended rows carry window_cost_usd; a pre-rename cost_usd row still summarizes =="
export DISPATCHER_LEDGER_FILE="$TMP/t1b.jsonl"
mk_run NEW1 2 false kept
ENDED_ROW=$(jq -R -c 'fromjson? | select(.run_id=="NEW1" and .event=="ended")' "$DISPATCHER_LEDGER_FILE")
echo "$ENDED_ROW" | jq -e 'has("window_cost_usd") and (has("cost_usd") | not) and .window_cost_usd == 2' >/dev/null 2>&1 && ok || bad "T1b ended row must carry window_cost_usd, not cost_usd: $ENDED_ROW"
# A row in the pre-rename writer's exact shape, between real claimed and kept rows.
run append --event claimed --run-id OLD1 >/dev/null
printf '{"fp":1,"ts":"%s","run_id":"OLD1","issue":null,"repo":null,"pr":null,"event":"ended","exit":0,"cost_usd":4,"tokens":1,"overlap":false,"cost_source":"ccflare-bracket"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DISPATCHER_LEDGER_FILE"
run append --event kept --run-id OLD1 >/dev/null
OUT=$(run summary)
# (2 + 4) / 2 = 3 across both keys. Without the reader's default to the old
# key, OLD1 drops out of the clean set and this reads $2 (n=1).
grep -qF "cost-per-kept (clean, gateway window, upper bound): \$3 (n=2)" <<<"$OUT" && ok || bad "T1b a pre-rename row and a new row must both summarize:
$OUT"

echo "== T2 (AE9): dead-pid launched run -> reconcile appends broken in one pass =="
export DISPATCHER_LEDGER_FILE="$TMP/t2.jsonl"
sleep 30 & DEADPID=$!
kill "$DEADPID" 2>/dev/null
wait "$DEADPID" 2>/dev/null
run append --event claimed --run-id DEAD1 >/dev/null
run append --event launched --run-id DEAD1 --pid "$DEADPID" >/dev/null
BEFORE=$(run summary)
grep -qF "undispositioned: 1" <<<"$BEFORE" && ok || bad "T2 setup: expected 1 undispositioned before reconcile:
$BEFORE"
: > "$TMP/t2-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t2-prstate.tsv")
grep -qF "DEAD1 -> broken" <<<"$RECON_OUT" && ok || bad "T2 reconcile did not report DEAD1 -> broken:
$RECON_OUT"
AFTER=$(run summary)
grep -qF "broken: 1" <<<"$AFTER" && ok || bad "T2 broken count did not reach 1:
$AFTER"
grep -qF "undispositioned: 0" <<<"$AFTER" && ok || bad "T2 undispositioned did not drop to 0:
$AFTER"

echo "== T2b control: a LIVE pid must NOT be marked broken =="
sleep 30 & LIVEPID=$!
run append --event claimed --run-id LIVE1 >/dev/null
run append --event launched --run-id LIVE1 --pid "$LIVEPID" >/dev/null
run reconcile --pr-state "$TMP/t2-prstate.tsv" >/dev/null
LIVE_OUT=$(run summary)
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null
grep -qF "broken: 1" <<<"$LIVE_OUT" && ok || bad "T2b live pid was wrongly marked broken:
$LIVE_OUT"
grep -qF "undispositioned: 1" <<<"$LIVE_OUT" && ok || bad "T2b live run should stay undispositioned:
$LIVE_OUT"

echo "== T3: orphaned claim (no launched sibling, ts far in the past) -> broken =="
export DISPATCHER_LEDGER_FILE="$TMP/t3.jsonl"
printf '{"fp":1,"ts":"2020-01-01T00:00:00Z","run_id":"ORPHAN1","issue":null,"repo":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}\n' >> "$DISPATCHER_LEDGER_FILE"
RECON_OUT=$(run reconcile --pr-state "$TMP/t2-prstate.tsv" --cadence-mins 20)
grep -qF "ORPHAN1 -> broken (orphaned claim" <<<"$RECON_OUT" && ok || bad "T3 orphaned claim was not flagged broken:
$RECON_OUT"

echo "== T3b control: a claim younger than cadence must NOT be flagged =="
export DISPATCHER_LEDGER_FILE="$TMP/t3b.jsonl"
run append --event claimed --run-id FRESH1 >/dev/null
RECON_OUT=$(run reconcile --pr-state "$TMP/t2-prstate.tsv" --cadence-mins 20)
grep -q "FRESH1" <<<"$RECON_OUT" && bad "T3b fresh claim was wrongly flagged:
$RECON_OUT" || ok

echo "== T4: FIRST-TERMINAL-WINS planted negatives =="
export DISPATCHER_LEDGER_FILE="$TMP/t4.jsonl"
run append --event claimed --run-id ALREADY >/dev/null
run append --event kept --run-id ALREADY >/dev/null
LINES_BEFORE=$(wc -l < "$DISPATCHER_LEDGER_FILE")
printf 'ALREADY\tclosed\n' > "$TMP/t4-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t4-prstate.tsv")
LINES_AFTER=$(wc -l < "$DISPATCHER_LEDGER_FILE")
[ "$LINES_BEFORE" = "$LINES_AFTER" ] && ok || bad "T4 reconcile appended a contradicting row for an already-kept run (before=$LINES_BEFORE after=$LINES_AFTER):
$RECON_OUT"
grep -q "ALREADY" <<<"$RECON_OUT" && bad "T4 reconcile must print nothing for a refused transition:
$RECON_OUT" || ok
run append --event waste --run-id ALREADY 2>"$TMP/t4-err.txt"
RC=$?
[ "$RC" = 1 ] && ok || bad "T4 direct second-terminal append exit $RC (want 1)"
LINES_AFTER2=$(wc -l < "$DISPATCHER_LEDGER_FILE")
[ "$LINES_AFTER" = "$LINES_AFTER2" ] && ok || bad "T4 direct second-terminal append wrote a row (before=$LINES_AFTER after=$LINES_AFTER2)"

echo "== T4b: unknown --event enum is rejected (usage error), nothing written =="
export DISPATCHER_LEDGER_FILE="$TMP/t4b.jsonl"
run append --event bogus --run-id Z >/dev/null 2>&1
RC=$?
[ "$RC" = 64 ] && ok || bad "T4b unknown event exit $RC (want 64)"
[ -f "$DISPATCHER_LEDGER_FILE" ] && bad "T4b unknown event created a ledger file" || ok

echo "== T5: audit-flip appends a ratchet row; summary surfaces it =="
export DISPATCHER_LEDGER_FILE="$TMP/t5.jsonl"
run audit-flip --ratchet auto-merge --keep-rate 0.5 --cost-per-kept 1.5
[ $? -eq 0 ] && ok || bad "T5 audit-flip append failed"
OUT=$(run summary)
grep -qF "ratchet-flip: auto-merge keep_rate=0.5 cost_per_kept=1.5" <<<"$OUT" && ok || bad "T5 summary did not surface the audit row:
$OUT"

echo "== T6: a malformed line is skipped; summary still computes =="
export DISPATCHER_LEDGER_FILE="$TMP/t6.jsonl"
run append --event claimed --run-id GOOD1 >/dev/null
run append --event launched --run-id GOOD1 --pid 1 >/dev/null
run append --event ended --run-id GOOD1 --exit 0 --cost 1 --tokens 1 --overlap false >/dev/null
run append --event kept --run-id GOOD1 >/dev/null
printf 'this is not json\n' >> "$DISPATCHER_LEDGER_FILE"
printf '{"broken": "json"\n' >> "$DISPATCHER_LEDGER_FILE"
OUT=$(run summary)
RC=$?
[ "$RC" = 0 ] && ok || bad "T6 summary crashed (rc=$RC) on a malformed line:
$OUT"
grep -qF "kept: 1" <<<"$OUT" && ok || bad "T6 summary did not still compute past the malformed line:
$OUT"

echo "== T7: a transition row with no prior claimed row is WARNED, not a crash =="
export DISPATCHER_LEDGER_FILE="$TMP/t7.jsonl"
printf '{"fp":1,"ts":"2026-08-22T00:00:00Z","run_id":"NOCLAIM1","issue":null,"repo":null,"event":"launched","pid":999999999}\n' >> "$DISPATCHER_LEDGER_FILE"
OUT=$(run summary)
RC=$?
[ "$RC" = 0 ] && ok || bad "T7 summary crashed (rc=$RC) on a claimless transition row:
$OUT"
grep -qF "WARN dispatcher-ledger: run NOCLAIM1 has a transition row but no claimed row" <<<"$OUT" && ok || bad "T7 no warning surfaced for claimless run:
$OUT"

echo "== T8 (R16 equality): exact keep-rate + cost-per-kept from a rounding-free fixture =="
export DISPATCHER_LEDGER_FILE="$TMP/t8.jsonl"
mk_run K1 2.00 false kept    # clean
mk_run K2 4.00 false kept    # clean
mk_run K3 999   true kept    # contaminated: overlap true
mk_run W1 1.00 false waste
OUT=$(run summary)
# hand-computed: kept=3 waste=1 -> keep-rate 75% (3/4); clean cost-per-kept
# = (2.00+4.00)/2 = 3; contaminated-kept = 3 - 2 = 1.
grep -qF "kept: 3   waste: 1   broken: 0" <<<"$OUT" && ok || bad "T8 disposition counts wrong:
$OUT"
grep -qF "keep-rate: 75% (3/4)" <<<"$OUT" && ok || bad "T8 keep-rate not exactly 75% (3/4):
$OUT"
grep -qF "cost-per-kept (clean, gateway window, upper bound): \$3 (n=2)   contaminated-kept: 1" <<<"$OUT" && ok || bad "T8 cost-per-kept/contaminated-kept wrong:
$OUT"

echo "== T9: an unwritable ledger path fails with one diagnostic, never a raw crash =="
BLOCKER="$TMP/t9-blocker"
: > "$BLOCKER"   # a FILE where reconcile/append expects to mkdir -p a directory
DISPATCHER_LEDGER_FILE="$BLOCKER/sub/ledger.jsonl" run append --event claimed --run-id Q >"$TMP/t9-out.txt" 2>"$TMP/t9-err.txt"
RC=$?
[ "$RC" != 0 ] && ok || bad "T9 append against an unwritable path exited 0"
[ ! -s "$TMP/t9-out.txt" ] && ok || bad "T9 unwritable-path append wrote to stdout: $(cat "$TMP/t9-out.txt")"
grep -qF "dispatcher-ledger:" "$TMP/t9-err.txt" && ok || bad "T9 no diagnostic message on unwritable path"
grep -Eiq "traceback|line [0-9]+:.*unbound|segmentation fault" "$TMP/t9-err.txt" && bad "T9 stderr looks like a raw crash, not a clean diagnostic:
$(cat "$TMP/t9-err.txt")" || ok

echo "== T10 (GAP1): claimed row carries --pr; reconcile --pr-state merged -> kept =="
export DISPATCHER_LEDGER_FILE="$TMP/t10.jsonl"
run append --event claimed --run-id PRRUN1 --issue 200 --repo o/r --pr 321 >/dev/null
CLAIMED_ROW=$(jq -R -c 'fromjson? | select(.run_id=="PRRUN1" and .event=="claimed")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
echo "$CLAIMED_ROW" | jq -e '.pr == 321' >/dev/null 2>&1 && ok || bad "T10 claimed row should carry pr:321:
$CLAIMED_ROW"
printf 'PRRUN1\tmerged\n' > "$TMP/t10-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t10-prstate.tsv")
grep -qF "PRRUN1 -> kept" <<<"$RECON_OUT" && ok || bad "T10 reconcile did not report PRRUN1 -> kept:
$RECON_OUT"
OUT=$(run summary)
grep -qF "kept: 1" <<<"$OUT" && ok || bad "T10 summary should show kept:1 after PR-state-driven reconcile:
$OUT"

echo "== T11 (F-F): a run_id with whitespace/control/backslash is rejected, nothing written =="
# The ledger keys every row on run_id and greps for it during reconcile; a
# run_id carrying whitespace, a control char, or a backslash would corrupt the
# JSONL grammar / let one row's id be mistaken for another. Reject at the door.
export DISPATCHER_LEDGER_FILE="$TMP/t11.jsonl"
run append --event claimed --run-id "has space" >/dev/null 2>&1
RC=$?
[ "$RC" = 64 ] && ok || bad "T11 whitespace run_id exit $RC (want 64)"
[ -f "$DISPATCHER_LEDGER_FILE" ] && bad "T11 whitespace run_id created a ledger file" || ok
run append --event claimed --run-id $'tab\there' >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T11 tab run_id not rejected"
run append --event claimed --run-id 'back\slash' >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T11 backslash run_id not rejected"
# a clean id on the same path still writes -- the guard rejects only bad chars
run append --event claimed --run-id OK-run_id.1 >/dev/null 2>&1
[ $? = 0 ] && ok || bad "T11 a well-formed run_id was wrongly rejected"

echo "== T12 (F-J): reconcile --cadence-mins rejects non-numeric / oversized values =="
# Assert the cadence-specific error, not just exit 64 -- reconcile also exits
# 64 on a missing --pr-state, so a bare exit-code check would false-pass even
# if the F-J guard were removed.
export DISPATCHER_LEDGER_FILE="$TMP/t12.jsonl"
ERR=$(run reconcile --cadence-mins abc 2>&1); RC=$?
[ "$RC" = 64 ] && ok || bad "T12 non-numeric --cadence-mins exit $RC (want 64)"
grep -qF "must be a non-negative integer" <<<"$ERR" && ok || bad "T12 non-numeric did not fire the cadence guard: $ERR"
ERR=$(run reconcile --cadence-mins -5 2>&1); RC=$?
{ [ "$RC" = 64 ] && grep -qF "must be a non-negative integer" <<<"$ERR"; } && ok || bad "T12 negative --cadence-mins not rejected by the guard: $ERR"
ERR=$(run reconcile --cadence-mins 1234567890 2>&1); RC=$?
{ [ "$RC" = 64 ] && grep -qF "implausibly large" <<<"$ERR"; } && ok || bad "T12 >9-digit --cadence-mins not rejected by the guard: $ERR"
# a plausible integer is accepted: reconcile with a valid cadence + an empty
# pr-state file (reconcile requires --pr-state) exits 0 with nothing to do.
: > "$TMP/t12-prstate.tsv"
run reconcile --cadence-mins 30 --pr-state "$TMP/t12-prstate.tsv" >/dev/null 2>&1
[ $? = 0 ] && ok || bad "T12 a valid --cadence-mins 30 was wrongly rejected"

echo "== T13 (issue #562): stopped:budget lands on ended rows only when asked; summary counts budget-stops =="
export DISPATCHER_LEDGER_FILE="$TMP/t13.jsonl"
run append --event claimed --run-id BS1 >/dev/null
run append --event ended --run-id BS1 --exit 97 --cost 3 --tokens 10 --overlap false --stopped budget
[ $? -eq 0 ] && ok || bad "T13 --stopped budget append failed"
ROW=$(jq -R -c 'fromjson? | select(.run_id=="BS1" and .event=="ended")' "$DISPATCHER_LEDGER_FILE")
echo "$ROW" | jq -e '.stopped == "budget" and .exit == 97' >/dev/null 2>&1 && ok || bad "T13 ended row lacks stopped:budget/exit 97: $ROW"
# A clean ended row must NOT grow a stopped key — clean rows and pre-#562
# rows share one shape, so a reader never has to special-case null.
run append --event claimed --run-id CLEAN1 >/dev/null
run append --event ended --run-id CLEAN1 --exit 0 --cost 1 --tokens 10 --overlap false >/dev/null
CLEANROW=$(jq -R -c 'fromjson? | select(.run_id=="CLEAN1" and .event=="ended")' "$DISPATCHER_LEDGER_FILE")
echo "$CLEANROW" | jq -e 'has("stopped") | not' >/dev/null 2>&1 && ok || bad "T13 clean ended row grew a stopped field: $CLEANROW"
OUT=$(run summary)
grep -qF "cut-short: 1 (budget: 1, background-tasks: 0)" <<<"$OUT" && ok || bad "T13 summary did not count exactly one budget cut-short:
$OUT"
# Closed enum + ended-only binding: both misuses are caller bugs that must
# fail loud at the door (exit 64), never be silently recorded.
run append --event ended --run-id BS2 --stopped bogus >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T13 --stopped bogus was not rejected"
run append --event kept --run-id BS1 --stopped budget >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T13 --stopped on a non-ended event was not rejected"

echo "== T14 (issue #584 planted negative): clean-ended run + dead pid + open PR survives reconcile untouched; merging afterwards -> kept =="
# The bug this pins: reconcile step 2 stamped `broken` on ANY dead-pid
# non-terminal run, including one that had already written `ended` (exit 0)
# and was simply awaiting its PR verdict -- and first-terminal-wins then made
# the mis-mark permanent. An `ended` row means the pid being gone is the
# EXPECTED state.
export DISPATCHER_LEDGER_FILE="$TMP/t14.jsonl"
sleep 30 & DEAD14=$!
kill "$DEAD14" 2>/dev/null
wait "$DEAD14" 2>/dev/null
run append --event claimed --run-id ENDED1 --issue 500 --repo o/r --pr 900 >/dev/null
run append --event launched --run-id ENDED1 --pid "$DEAD14" >/dev/null
run append --event ended --run-id ENDED1 --exit 0 --cost 2 --tokens 10 --overlap false >/dev/null
printf 'ENDED1\topen\n' > "$TMP/t14-prstate.tsv"   # what build_pr_state emits for an open PR
cp "$DISPATCHER_LEDGER_FILE" "$TMP/t14.snap"
RECON_OUT=$(run reconcile --pr-state "$TMP/t14-prstate.tsv")
cmp -s "$DISPATCHER_LEDGER_FILE" "$TMP/t14.snap" && ok || bad "T14 reconcile changed ledger bytes for a clean-ended awaiting-verdict run:
$RECON_OUT"
grep -q "ENDED1" <<<"$RECON_OUT" && bad "T14 reconcile touched ENDED1:
$RECON_OUT" || ok
# the timer's cadence (AC line 4): the immediate next tick's reconcile, PR
# still open, must ALSO be a no-op -- this is exactly the pass that used to
# mis-fire seconds after a clean end.
RECON_OUT=$(run reconcile --pr-state "$TMP/t14-prstate.tsv")
{ cmp -s "$DISPATCHER_LEDGER_FILE" "$TMP/t14.snap" && [ -z "$RECON_OUT" ]; } && ok || bad "T14 second reconcile pass was not a byte-for-byte no-op:
$RECON_OUT"
OUT=$(run summary)
grep -qF "undispositioned: 1" <<<"$OUT" && ok || bad "T14 ended-but-open run must land in undispositioned:
$OUT"
# the exemption keys on the ended ROW, not its exit code (scope rule 1):
# a run that ended nonzero still ended -- its PR verdict decides it.
run append --event claimed --run-id ENDED2 >/dev/null
run append --event launched --run-id ENDED2 --pid "$DEAD14" >/dev/null
run append --event ended --run-id ENDED2 --exit 1 --cost 1 --tokens 1 --overlap false >/dev/null
RECON_OUT=$(run reconcile --pr-state "$TMP/t14-prstate.tsv")
grep -q "ENDED2" <<<"$RECON_OUT" && bad "T14 nonzero-exit ended run was wrongly dispositioned:
$RECON_OUT" || ok
# merging the PR afterwards still yields kept (AC line 1)
printf 'ENDED1\tmerged\n' > "$TMP/t14-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t14-prstate.tsv")
grep -qF "ENDED1 -> kept" <<<"$RECON_OUT" && ok || bad "T14 merged PR did not yield kept:
$RECON_OUT"
OUT=$(run summary)
grep -qF "kept: 1" <<<"$OUT" && ok || bad "T14 summary should count ENDED1 kept after the merge:
$OUT"
# second planted negative (AC line 2): launched + dead pid + NO ended row is
# STILL broken -- the fix narrowed the rule, it did not disable it. (T2
# proves this from a fresh ledger; this re-proves it against a ledger that
# also carries ended-exempted runs.)
run append --event claimed --run-id NOEND1 >/dev/null
run append --event launched --run-id NOEND1 --pid "$DEAD14" >/dev/null
: > "$TMP/t14-empty.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t14-empty.tsv")
grep -qF "NOEND1 -> broken" <<<"$RECON_OUT" && ok || bad "T14 dead-pid run with NO ended row must still go broken:
$RECON_OUT"

echo "== T15 (issue #584 + #1428): the orphaned-claim age rule must not fire on an ended run, but the no-pr-after-ttl rule (step 4) correctly does =="
# A claimed+ended run with no launched row (the budget-stop shape, or a lost
# launched append) COMPLETED; wall time since its CLAIM is not evidence of an
# orphaned claim, so the issue #584 age rule (keyed on claimed_ts, steps 2/3)
# must stay silent for it -- proven below by asserting it is never marked
# "broken". T3 keeps proving that rule still fires on a claim-ONLY run.
#
# But this fixture also has no pr on any row and its ENDED row is from 2020
# -- obviously past any --claim-ttl-hours -- so as of issue #1428/KTD5's step
# 4 it now correctly terminalizes as waste via the no-pr-after-ttl rule (a
# DIFFERENT rule, keyed on ended_ts, not claimed_ts). That is the intended
# behavior change this unit ships ("a run that never gets a PR still
# terminalizes"): before step 4 existed this run stayed undispositioned
# forever; #584's exemption only ever promised steps 2/3 would leave ended
# runs alone, not that no rule ever would.
export DISPATCHER_LEDGER_FILE="$TMP/t15.jsonl"
printf '{"fp":1,"ts":"2020-01-01T00:00:00Z","run_id":"OLDEND1","issue":null,"repo":null,"pr":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}\n' >> "$DISPATCHER_LEDGER_FILE"
printf '{"fp":1,"ts":"2020-01-01T01:00:00Z","run_id":"OLDEND1","issue":null,"repo":null,"pr":null,"event":"ended","exit":0,"cost_usd":1,"tokens":1,"overlap":false,"cost_source":"ccflare-bracket"}\n' >> "$DISPATCHER_LEDGER_FILE"
: > "$TMP/t15-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t15-prstate.tsv" --cadence-mins 20)
grep -q "OLDEND1 -> broken" <<<"$RECON_OUT" && bad "T15 ended run was wrongly aged out as an orphaned claim (issue #584 regression):
$RECON_OUT" || ok
grep -qF "OLDEND1 -> waste (no-pr-after-ttl" <<<"$RECON_OUT" && ok || bad "T15 ended run with no pr, obviously past the TTL, must terminalize as waste (issue #1428 step 4):
$RECON_OUT"

echo "== T16 (issue #584): audit-correction voids a mis-marked broken run without weakening first-terminal-wins =="
export DISPATCHER_LEDGER_FILE="$TMP/t16.jsonl"
# reconstruct the damage shape: a clean-ended run mis-marked broken (as the
# pre-fix reconcile did), plus one honest waste run for exact arithmetic.
run append --event claimed --run-id MISS1 --issue 543 --repo o/r --pr 579 >/dev/null
run append --event launched --run-id MISS1 --pid 1 >/dev/null
run append --event ended --run-id MISS1 --exit 0 --cost 2.00 --tokens 10 --overlap false >/dev/null
run append --event broken --run-id MISS1 >/dev/null
mk_run W2 1.00 false waste
OUT=$(run summary)
grep -qF "kept: 0   waste: 1   broken: 1" <<<"$OUT" && ok || bad "T16 pre-correction counts wrong:
$OUT"
run audit-correction --run-id MISS1 --voids broken --disposition kept --reason "mis-marked by the #584 reconcile dead-pid bug; PR 579 merged"
[ $? -eq 0 ] && ok || bad "T16 audit-correction append failed"
CORR_ROW=$(jq -R -c 'fromjson? | select(.run_id=="MISS1" and .event=="audit-correction")' "$DISPATCHER_LEDGER_FILE")
echo "$CORR_ROW" | jq -e '.voids == "broken" and .disposition == "kept" and ((.reason | length) > 0)' >/dev/null 2>&1 && ok || bad "T16 correction row shape wrong: $CORR_ROW"
OUT=$(run summary)
# folded: MISS1 leaves broken and counts kept -> kept=1 waste=1, 50% (1/2);
# its clean \$2 ended row now feeds cost-per-kept.
grep -qF "kept: 1   waste: 1   broken: 0" <<<"$OUT" && ok || bad "T16 corrected counts wrong:
$OUT"
grep -qF "keep-rate: 50% (1/2)" <<<"$OUT" && ok || bad "T16 corrected keep-rate wrong:
$OUT"
grep -qF "audit-corrected: 1" <<<"$OUT" && ok || bad "T16 summary must name the corrected-run count:
$OUT"
grep -qF "cost-per-kept (clean, gateway window, upper bound): \$2 (n=1)" <<<"$OUT" && ok || bad "T16 corrected kept run's clean cost not folded:
$OUT"
grep -qF "audit-correction: run MISS1 voided broken -> kept" <<<"$OUT" && ok || bad "T16 summary must surface the correction row:
$OUT"
grep -qF "dispatcher-flagged:0" <<<"$OUT" && ok || bad "T16 corrected run must leave the flagged count:
$OUT"
# first-terminal-wins is NOT weakened by a correction: a real terminal
# append for MISS1 is still refused, nothing written.
LINES_T16=$(wc -l < "$DISPATCHER_LEDGER_FILE")
run append --event kept --run-id MISS1 >/dev/null 2>&1
RC=$?
LINES_T16B=$(wc -l < "$DISPATCHER_LEDGER_FILE")
{ [ "$RC" = 1 ] && [ "$LINES_T16" = "$LINES_T16B" ]; } && ok || bad "T16 corrected run accepted a second terminal row (rc=$RC before=$LINES_T16 after=$LINES_T16B)"
# first disposition wins: a second correction cannot re-decide it.
run audit-correction --run-id MISS1 --voids broken --disposition waste --reason x >/dev/null 2>&1
[ $? = 1 ] && ok || bad "T16 second disposition-carrying correction was not refused"
# nothing to void: W2's terminal is waste, not broken.
run audit-correction --run-id W2 --voids broken --disposition kept --reason x >/dev/null 2>&1
[ $? = 1 ] && ok || bad "T16 correction against a non-broken run was not refused"
# a genuinely broken run (dead pid, NO ended row) cannot be "corrected":
# broken+ended is the mis-mark signature; without an ended row the broken
# verdict is presumed true, and a correction would falsify the keep-rate
# (inward-vet lens-2 finding, 2026-08-28).
run append --event claimed --run-id TRUEBRK >/dev/null
run append --event launched --run-id TRUEBRK --pid 1 >/dev/null
run append --event broken --run-id TRUEBRK >/dev/null
run audit-correction --run-id TRUEBRK --voids broken --disposition kept --reason x >/dev/null 2>&1
[ $? = 1 ] && ok || bad "T16 correction of a never-ended broken run was not refused"
# closed enums + required reason fail at the door (usage, 64): voiding a
# kept/waste row would let corrections rewrite OPERATOR verdicts.
run audit-correction --run-id MISS1 --voids kept --disposition waste --reason x >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T16 --voids kept was not rejected (closed enum)"
run audit-correction --run-id MISS1 --voids broken --disposition bogus --reason x >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T16 --disposition bogus was not rejected"
run audit-correction --run-id MISS1 --voids broken --disposition kept >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T16 missing --reason was not rejected"

echo "== T17 (issue #584): a dispositionless correction parks the run as undispositioned until a completing correction lands =="
export DISPATCHER_LEDGER_FILE="$TMP/t17.jsonl"
run append --event claimed --run-id MISS2 --pr 700 >/dev/null
run append --event launched --run-id MISS2 --pid 1 >/dev/null
run append --event ended --run-id MISS2 --exit 0 --cost 1 --tokens 1 --overlap false >/dev/null
run append --event broken --run-id MISS2 >/dev/null
run audit-correction --run-id MISS2 --voids broken --reason "mis-marked by the #584 bug; PR 700 still open"
[ $? -eq 0 ] && ok || bad "T17 pending correction append failed"
PEND_ROW=$(jq -R -c 'fromjson? | select(.run_id=="MISS2" and .event=="audit-correction")' "$DISPATCHER_LEDGER_FILE")
echo "$PEND_ROW" | jq -e 'has("disposition") | not' >/dev/null 2>&1 && ok || bad "T17 pending correction must not carry a disposition key: $PEND_ROW"
OUT=$(run summary)
grep -qF "kept: 0   waste: 0   broken: 0" <<<"$OUT" && ok || bad "T17 pending-corrected run must leave broken without gaining a disposition:
$OUT"
grep -qF "undispositioned: 1" <<<"$OUT" && ok || bad "T17 pending-corrected run must count as undispositioned (awaiting verdict):
$OUT"
grep -qF "audit-corrected: 1" <<<"$OUT" && ok || bad "T17 audit-corrected count missing:
$OUT"
# a duplicate pending correction is refused
run audit-correction --run-id MISS2 --voids broken --reason dup >/dev/null 2>&1
[ $? = 1 ] && ok || bad "T17 duplicate pending correction was not refused"
# the PR verdict arrives: a completing correction carries it
run audit-correction --run-id MISS2 --voids broken --disposition waste --reason "PR 700 closed unmerged"
[ $? -eq 0 ] && ok || bad "T17 completing correction failed"
OUT=$(run summary)
grep -qF "kept: 0   waste: 1   broken: 0" <<<"$OUT" && ok || bad "T17 completed correction must count the run waste:
$OUT"
grep -qF "keep-rate: 0% (0/1)" <<<"$OUT" && ok || bad "T17 completed-correction keep-rate wrong:
$OUT"
grep -qF "audit-corrected: 1" <<<"$OUT" && ok || bad "T17 audit-corrected must count RUNS, not correction rows:
$OUT"

echo "== T16 (issue #583): stopped:background-tasks + empty:true land on ended rows; summary counts cut-short by reason =="
export DISPATCHER_LEDGER_FILE="$TMP/t14.jsonl"
run append --event claimed --run-id CS1 >/dev/null
run append --event ended --run-id CS1 --exit 96 --cost 2 --tokens 10 --overlap false --stopped background-tasks --empty true
[ $? -eq 0 ] && ok || bad "T16 --stopped background-tasks --empty true append failed"
ROW=$(jq -R -c 'fromjson? | select(.run_id=="CS1" and .event=="ended")' "$DISPATCHER_LEDGER_FILE")
echo "$ROW" | jq -e '.stopped == "background-tasks" and .empty == true and .exit == 96' >/dev/null 2>&1 && ok || bad "T16 ended row lacks stopped:background-tasks/empty:true/exit 96: $ROW"
# An empty CLEAN run (exit 0, no stopped key) still carries empty:true -- the
# backstop is independent of any kill detection.
run append --event claimed --run-id CS2 >/dev/null
run append --event ended --run-id CS2 --exit 0 --cost 1 --tokens 5 --overlap false --empty true >/dev/null
ROW=$(jq -R -c 'fromjson? | select(.run_id=="CS2" and .event=="ended")' "$DISPATCHER_LEDGER_FILE")
echo "$ROW" | jq -e '.empty == true and (has("stopped") | not)' >/dev/null 2>&1 && ok || bad "T16 clean-but-empty row wrong: $ROW"
run append --event claimed --run-id CS3 >/dev/null
run append --event ended --run-id CS3 --exit 97 --cost 3 --tokens 9 --overlap false --stopped budget >/dev/null
OUT=$(run summary)
grep -qF "cut-short: 2 (budget: 1, background-tasks: 1)" <<<"$OUT" && ok || bad "T16 summary cut-short counts wrong:
$OUT"
grep -qF "empty-delivery: 2" <<<"$OUT" && ok || bad "T16 summary empty-delivery count wrong:
$OUT"
# Closed enums, ended-only binding: every misuse fails loud at the door.
run append --event ended --run-id CS4 --stopped background-jobs >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T16 unknown --stopped reason was not rejected"
run append --event ended --run-id CS4 --empty false >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T16 --empty false was not rejected (omit the flag instead)"
run append --event kept --run-id CS1 --empty true >/dev/null 2>&1
[ $? = 64 ] && ok || bad "T16 --empty on a non-ended event was not rejected"

echo "== T19 (KTD5, U4): pr-opened requires --pr (usage error); with --pr the row carries it =="
export DISPATCHER_LEDGER_FILE="$TMP/t19.jsonl"
run append --event pr-opened --run-id PRO1 >/dev/null 2>&1
RC=$?
[ "$RC" = 64 ] && ok || bad "T19 pr-opened without --pr exit $RC (want 64)"
[ -f "$DISPATCHER_LEDGER_FILE" ] && bad "T19 pr-opened without --pr created a ledger file" || ok
run append --event pr-opened --run-id PRO1 --pr 12 >/dev/null
[ $? -eq 0 ] && ok || bad "T19 pr-opened with --pr was rejected"
ROW=$(jq -R -c 'fromjson? | select(.run_id=="PRO1" and .event=="pr-opened")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
echo "$ROW" | jq -e '.pr == 12' >/dev/null 2>&1 && ok || bad "T19 pr-opened row should carry pr:12: $ROW"

echo "== T20 (KTD5, U4): ended --empty true with no pr on any row -> reconcile disposes waste immediately (empty-delivery-no-pr) =="
export DISPATCHER_LEDGER_FILE="$TMP/t20.jsonl"
run append --event claimed --run-id EMPTY1 >/dev/null
run append --event launched --run-id EMPTY1 --pid 1 >/dev/null
run append --event ended --run-id EMPTY1 --exit 0 --cost 1 --tokens 1 --overlap false --empty true >/dev/null
: > "$TMP/t20-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t20-prstate.tsv")
grep -qF "EMPTY1 -> waste (empty-delivery-no-pr)" <<<"$RECON_OUT" && ok || bad "T20 empty-delivery-no-pr run was not disposed waste with the expected reason:
$RECON_OUT"
OUT=$(run summary)
grep -qF "waste: 1" <<<"$OUT" && ok || bad "T20 summary should count EMPTY1 waste:
$OUT"

echo "== T21 (KTD5, U4) control: ended (no empty), no pr, age under the claim TTL -> stays non-terminal =="
export DISPATCHER_LEDGER_FILE="$TMP/t21.jsonl"
run append --event claimed --run-id NOPR1 >/dev/null
run append --event ended --run-id NOPR1 --exit 0 --cost 1 --tokens 1 --overlap false >/dev/null
: > "$TMP/t21-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t21-prstate.tsv")
grep -q "NOPR1" <<<"$RECON_OUT" && bad "T21 a fresh no-pr ended run (well under the default 48h TTL) was wrongly disposed:
$RECON_OUT" || ok
OUT=$(run summary)
grep -qF "undispositioned: 1" <<<"$OUT" && ok || bad "T21 NOPR1 should remain undispositioned:
$OUT"

echo "== T22 (KTD5, U4): ended (no empty), no pr, ended row obviously past the default 48h TTL -> waste (no-pr-after-ttl) =="
export DISPATCHER_LEDGER_FILE="$TMP/t22.jsonl"
printf '{"fp":1,"ts":"2020-01-01T00:00:00Z","run_id":"OLDNOPR1","issue":null,"repo":null,"pr":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}\n' >> "$DISPATCHER_LEDGER_FILE"
printf '{"fp":1,"ts":"2020-01-01T01:00:00Z","run_id":"OLDNOPR1","issue":null,"repo":null,"pr":null,"event":"ended","exit":0,"cost_usd":1,"tokens":1,"overlap":false,"cost_source":"ccflare-bracket"}\n' >> "$DISPATCHER_LEDGER_FILE"
: > "$TMP/t22-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t22-prstate.tsv")
grep -qF "OLDNOPR1 -> waste (no-pr-after-ttl" <<<"$RECON_OUT" && ok || bad "T22 an obviously-stale no-pr ended run was not disposed waste with the expected reason:
$RECON_OUT"
OUT=$(run summary)
grep -qF "waste: 1" <<<"$OUT" && ok || bad "T22 summary should count OLDNOPR1 waste:
$OUT"

echo "== T23 (KTD5, U4): --claim-ttl-hours overrides the default -- a 2h-old no-pr ended run crosses a 1h TTL =="
export DISPATCHER_LEDGER_FILE="$TMP/t23.jsonl"
OLD_TS=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
printf '{"fp":1,"ts":"%s","run_id":"TTLRUN1","issue":null,"repo":null,"pr":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}\n' "$OLD_TS" >> "$DISPATCHER_LEDGER_FILE"
printf '{"fp":1,"ts":"%s","run_id":"TTLRUN1","issue":null,"repo":null,"pr":null,"event":"ended","exit":0,"cost_usd":1,"tokens":1,"overlap":false,"cost_source":"ccflare-bracket"}\n' "$OLD_TS" >> "$DISPATCHER_LEDGER_FILE"
: > "$TMP/t23-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t23-prstate.tsv" --claim-ttl-hours 1)
grep -qF "TTLRUN1 -> waste (no-pr-after-ttl" <<<"$RECON_OUT" && ok || bad "T23 a 2h-old no-pr ended run was not wasted under --claim-ttl-hours 1:
$RECON_OUT"

echo "== T23b (KTD5, U4) control: the SAME 2h-old shape stays non-terminal under the default 48h TTL =="
export DISPATCHER_LEDGER_FILE="$TMP/t23b.jsonl"
printf '{"fp":1,"ts":"%s","run_id":"TTLRUN2","issue":null,"repo":null,"pr":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}\n' "$OLD_TS" >> "$DISPATCHER_LEDGER_FILE"
printf '{"fp":1,"ts":"%s","run_id":"TTLRUN2","issue":null,"repo":null,"pr":null,"event":"ended","exit":0,"cost_usd":1,"tokens":1,"overlap":false,"cost_source":"ccflare-bracket"}\n' "$OLD_TS" >> "$DISPATCHER_LEDGER_FILE"
: > "$TMP/t23b-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t23b-prstate.tsv")
grep -q "TTLRUN2" <<<"$RECON_OUT" && bad "T23b a 2h-old no-pr ended run was wrongly wasted under the default 48h TTL:
$RECON_OUT" || ok

echo "== T24 (KTD5, U4): a pr-opened row satisfies the no-pr rules' pr check -- step4 leaves it alone even when obviously stale =="
export DISPATCHER_LEDGER_FILE="$TMP/t24.jsonl"
printf '{"fp":1,"ts":"2020-01-01T00:00:00Z","run_id":"HASPRO1","issue":null,"repo":null,"pr":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}\n' >> "$DISPATCHER_LEDGER_FILE"
run append --event pr-opened --run-id HASPRO1 --pr 900 >/dev/null
printf '{"fp":1,"ts":"2020-01-01T01:00:00Z","run_id":"HASPRO1","issue":null,"repo":null,"pr":null,"event":"ended","exit":0,"cost_usd":1,"tokens":1,"overlap":false,"cost_source":"ccflare-bracket"}\n' >> "$DISPATCHER_LEDGER_FILE"
: > "$TMP/t24-prstate.tsv"
RECON_OUT=$(run reconcile --pr-state "$TMP/t24-prstate.tsv")
grep -q "HASPRO1" <<<"$RECON_OUT" && bad "T24 a run with a pr-opened row was wrongly touched by the no-pr terminal rules:
$RECON_OUT" || ok
OUT=$(run summary)
grep -qF "undispositioned: 1" <<<"$OUT" && ok || bad "T24 HASPRO1 should remain undispositioned (awaiting its own PR verdict):
$OUT"

echo "== T25 (KTD5, U4): reconcile --claim-ttl-hours rejects non-numeric/negative/oversized, accepts a valid integer =="
export DISPATCHER_LEDGER_FILE="$TMP/t25.jsonl"
ERR=$(run reconcile --claim-ttl-hours abc 2>&1); RC=$?
[ "$RC" = 64 ] && ok || bad "T25 non-numeric --claim-ttl-hours exit $RC (want 64)"
grep -qF "must be a non-negative integer" <<<"$ERR" && ok || bad "T25 non-numeric did not fire the claim-ttl-hours guard: $ERR"
ERR=$(run reconcile --claim-ttl-hours -5 2>&1); RC=$?
{ [ "$RC" = 64 ] && grep -qF "must be a non-negative integer" <<<"$ERR"; } && ok || bad "T25 negative --claim-ttl-hours not rejected by the guard: $ERR"
ERR=$(run reconcile --claim-ttl-hours 1234567890 2>&1); RC=$?
{ [ "$RC" = 64 ] && grep -qF "implausibly large" <<<"$ERR"; } && ok || bad "T25 >9-digit --claim-ttl-hours not rejected by the guard: $ERR"
: > "$TMP/t25-prstate.tsv"
run reconcile --claim-ttl-hours 48 --pr-state "$TMP/t25-prstate.tsv" >/dev/null 2>&1
[ $? = 0 ] && ok || bad "T25 a valid --claim-ttl-hours 48 was wrongly rejected"

echo "== T26 (issue #1428, U5): claimed row carries --branch, and omitting it leaves the field null =="
export DISPATCHER_LEDGER_FILE="$TMP/t26.jsonl"
run append --event claimed --run-id BRANCHRUN1 --issue 300 --repo o/r --branch "loop/issue-300-1234" >/dev/null
CLAIMED_ROW=$(jq -R -c 'fromjson? | select(.run_id=="BRANCHRUN1" and .event=="claimed")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
echo "$CLAIMED_ROW" | jq -e '.branch == "loop/issue-300-1234"' >/dev/null 2>&1 && ok || bad "T26 claimed row should carry branch:\"loop/issue-300-1234\":
$CLAIMED_ROW"
run append --event claimed --run-id BRANCHRUN2 --issue 301 --repo o/r >/dev/null
CLAIMED_ROW2=$(jq -R -c 'fromjson? | select(.run_id=="BRANCHRUN2" and .event=="claimed")' "$DISPATCHER_LEDGER_FILE" 2>/dev/null)
echo "$CLAIMED_ROW2" | jq -e '.branch == null' >/dev/null 2>&1 && ok || bad "T26 a claimed row with no --branch should leave the field null, not an empty string or absent key:
$CLAIMED_ROW2"

echo
echo "dispatcher-ledger: $pass passed, $fail failed"
[ "$fail" = 0 ]
