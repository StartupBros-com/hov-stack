#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE=$ROOT/bin/oracle-bump-gate.sh
T=$(mktemp -d /tmp/bump-gate-test.XXXXXX) || exit 1
BG=""
cleanup() { for p in $BG; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
export PRO_GATE_HOME="$T/runtime" PRO_GATE_MAX_CONCURRENCY=4 PRO_GATE_LOCK_WAIT=305
mkdir -p "$PRO_GATE_HOME/in-progress"
# shellcheck source=/dev/null
. "$ROOT/lib/pro-gate-lib.sh"
fail=0
check() { local name=$1; shift; if "$@"; then echo "ok - $name"; else echo "FAIL - $name"; fail=$((fail+1)); fi; }
run() { bash "$GATE" "$@" >"$T/out" 2>"$T/err"; rc=$?; }
waitfor() { local n=0; while [ ! -e "$1" ]; do sleep 0.05; n=$((n+1)); [ "$n" -lt 100 ] || return 1; done; }
run --interface
check 'interface 1' test "$(cat "$T/out")" = 1
for lock in oracle.lock.slot3 oracle.lock.pr-fixture; do
 (pg_fd_open "$PRO_GATE_HOME/$lock" && pg_fd_lock "$PG_FD" 0 && touch "$T/ready" && exec sleep 30) & p=$!; BG="$BG $p"; waitfor "$T/ready"
 run hold -- touch "$T/ran"
 check "busy $lock defers" test "$rc" = 4
 check 'busy hold did not run command' test ! -e "$T/ran"
 check 'defer gives a reason' test -s "$T/err"
 kill "$p"; wait "$p" 2>/dev/null || true; rm "$T/ready"
done
printf 'marker\t1\t0\toutput\t1\tmodel\t0\tgenerating\n' > "$PRO_GATE_HOME/in-progress/reservation"
run hold -- touch "$T/ran"
check 'capacity-holding reservation defers' test "$rc" = 4
check 'reservation prevents command' test ! -e "$T/ran"
rm "$PRO_GATE_HOME/in-progress/reservation"
run hold --budget-seconds 5 -- bash -c 'touch "$1"; exec sleep 2' _ "$T/ready" & waiter=$!; BG="$BG $waiter"; waitfor "$T/ready"
for i in 1 2 3 4; do check "slot $i busy from outside" pg_fd_lock_busy "$PRO_GATE_HOME/oracle.lock.slot$i"; done
wait "$waiter"
for i in 1 2 3 4; do if pg_fd_lock_busy "$PRO_GATE_HOME/oracle.lock.slot$i"; then check "slot $i released" false; else check "slot $i released" true; fi; done
run hold --budget-seconds 0 -- true; check 'zero budget fails' test "$rc" = 1
PRO_GATE_LOCK_WAIT=300 run hold -- true; check 'configured nonpositive budget fails' test "$rc" = 1
run hold --budget-seconds 1 -- sleep 10; check 'timeout is broken' test "$rc" = 1
run hold -- bash -c 'exit 7'; check 'command status propagated' test "$rc" = 7
run hold -- bash -c '[ "$PRO_GATE_BUMP_HOLD" = 1 ] && [ "$PRO_GATE_BUMP_DEADLINE" -gt "$(date +%s)" ]'
check 'hold exports its deadline and marker' test "$rc" = 0
# PLANTED NEGATIVE: timeout runs the held command in its own process group, so a signal sent
# to the gate alone reaches it only if the gate forwards it. A background job of this shell
# starts with INT ignored, which no trap can undo, so INT needs env --default-signal.
for sig in TERM HUP INT; do
 launch=(bash)
 if [ "$sig" = INT ]; then
  if env --default-signal=INT true 2>/dev/null; then launch=(env --default-signal=INT bash)
  else echo "skip - INT forwarding (env lacks --default-signal)"; continue; fi
 fi
 rm -f "$T/ready" "$T/got"
 "${launch[@]}" "$GATE" hold --budget-seconds 20 -- bash -c 'trap "touch \"\$1\"; exit 9" TERM; touch "$2"; while :; do sleep 0.1; done' _ "$T/got" "$T/ready" >"$T/out" 2>"$T/err" & g=$!; BG="$BG $g"
 waitfor "$T/ready"
 kill -s "$sig" "$g"
 n=0; while kill -0 "$g" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n+1)); done
 wait "$g" 2>/dev/null; rc=$?
 check "$sig reaches the held command" test -e "$T/got"
 check "$sig to the gate is broken" test "$rc" = 1
 check "$sig is named" grep -q "interrupted by $sig" "$T/err"
 if pg_fd_lock_busy "$PRO_GATE_HOME/oracle.lock.slot1"; then check "$sig releases slot 1" false; else check "$sig releases slot 1" true; fi
done
# Fake Node CLI implements the public commands without loading Oracle.
cat > "$T/trial.mjs" <<'FAKE'
import { appendFileSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
const [cmd,...args]=process.argv.slice(2), get=k=>args[args.indexOf(k)+1];
appendFileSync(process.env.FAKE_LOG,cmd+' '+args.join(' ')+'\n');
if(cmd==='audit'&&process.env.FAKE_VERDICT==='audit-new'){const ok=args.includes('--ack')&&get('--ack')==='d1';console.log(JSON.stringify({ok,hits:[{function:'f',text:'x.click();'}],known:0,missing:[],digest:'d1',acknowledged:ok}));process.exit(ok?0:1);}
if(cmd==='audit'){console.log(JSON.stringify({ok:process.env.FAKE_VERDICT!=='broken',hits:process.env.FAKE_VERDICT==='broken'?['click']:[],missing:[]}));process.exit(process.env.FAKE_VERDICT==='broken'?1:0);}
if(cmd==='run'){const control=get('--oracle-root')==='control'; const failures=['pass','audit-new'].includes(process.env.FAKE_VERDICT)?0:control&&process.env.FAKE_VERDICT==='reject'?0:3;mkdirSync(get('--out'),{recursive:true});writeFileSync(get('--out')+'/summary.json',JSON.stringify({counted:20,failures,inconclusive:0,broken:null,stopped:'count'}));}
if(cmd==='decide'){const candidate=JSON.parse(readFileSync(get('--candidate'))); const control=args.includes('--control')?JSON.parse(readFileSync(get('--control'))):null;console.log(JSON.stringify({verdict:candidate.failures<3?'pass':!control?'needs-control':control.failures<3?'reject':'defer',reason:'fixture',candidate,control}));}
FAKE
export PRO_GATE_UPLOAD_TRIAL="$T/trial.mjs" FAKE_LOG="$T/trial.log"
run trial --candidate-root candidate --control-root control --out "$T/nohold"
check 'trial refuses outside hold' test "$rc" = 1
PRO_GATE_BUMP_HOLD=1 run trial --candidate-root candidate --control-root control --out "$T/forged"
check 'trial refuses marker without a busy slot' test "$rc" = 1
for verdict in pass reject defer broken; do
 : > "$FAKE_LOG"
 export FAKE_VERDICT=$verdict
 run hold -- "$GATE" trial --candidate-root candidate --control-root control --out "$T/$verdict"
 case $verdict in pass) expected=0;; reject) expected=3;; defer) expected=4;; broken) expected=1;; esac
 check "$verdict exit contract" test "$rc" = "$expected"
 check "$verdict printed and saved" cmp -s "$T/out" "$T/$verdict/verdict.json"
 check "$verdict JSON verdict" test "$(jq -r .verdict "$T/out")" = "$verdict"
 if [ "$verdict" = pass ]; then
  check 'passing candidate never runs control' bash -c '! grep -q -- "run --oracle-root control" "$1"' _ "$FAKE_LOG"
  check 'audit compares the candidate with the live control' grep -q -- 'audit --oracle-root candidate --baseline-root control' "$FAKE_LOG"
 fi
done
# PLANTED NEGATIVE: risky lines new since the live build stop the gate until that exact set is acknowledged.
: > "$FAKE_LOG"; export FAKE_VERDICT=audit-new
run hold -- "$GATE" trial --candidate-root candidate --control-root control --out "$T/audit-new"
check 'new audit lines are broken' test "$rc" = 1
check 'broken audit names the acknowledgement' grep -q 'PRO_GATE_BUMP_AUDIT_ACK=d1' "$T/out"
check 'broken audit never runs a trial' bash -c '! grep -q "^run " "$1"' _ "$FAKE_LOG"
: > "$FAKE_LOG"
PRO_GATE_BUMP_AUDIT_ACK=d1 run hold -- "$GATE" trial --candidate-root candidate --control-root control --out "$T/audit-ack"
check 'acknowledged audit lines proceed to the trial' test "$rc" = 0
check 'acknowledgement reaches the audit' grep -q -- '--ack d1' "$FAKE_LOG"
echo "$fail failures"
exit "$((fail>0))"
