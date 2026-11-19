#!/usr/bin/env bash
# Review exclusion and the predeclared no-Send upload gate. Hand-started only.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in "$SELF/lib.sh" "$SELF/../lib/pro-gate-lib.sh" "${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/lib.sh"; do
  # Runtime library location depends on installed versus source layout.
  # shellcheck source=/dev/null
  [ -f "$c" ] && { . "$c"; break; }
done
type pg_fd_open >/dev/null 2>&1 || { echo 'ERROR: lib.sh not found' >&2; exit 1; }
usage() { echo 'usage: oracle-bump-gate.sh --interface | hold [--budget-seconds N] -- cmd... | trial --candidate-root pkg --control-root pkg --out dir [--count N]' >&2; exit 2; }
defer() { echo "oracle-bump-gate: $*" >&2; exit 4; }
broken() { echo "oracle-bump-gate: $*" >&2; exit 1; }

[ "$#" -gt 0 ] || usage
MODE=$1; shift
if [ "$MODE" = --interface ]; then [ "$#" = 0 ] || usage; echo 1; exit 0; fi
case "$MODE" in hold|trial) ;; *) usage;; esac
pg_load_env
LOCKFILE="${PRO_GATE_LOCKFILE:-$PRO_GATE_HOME/oracle.lock}"
MAX_CONC="${PRO_GATE_MAX_CONCURRENCY:-1}"
LOCK_WAIT="$(pg_int_or "${PRO_GATE_LOCK_WAIT:-3900}" 3900)"
LOCK_WAIT=$((10#$LOCK_WAIT))
NODE="${PRO_GATE_NODE_BIN:-node}"
TRIAL="${PRO_GATE_UPLOAD_TRIAL:-$SELF/oracle-upload-trial.mjs}"

if [ "$MODE" = hold ]; then
  BUDGET=$((LOCK_WAIT - 300))
  if [ "${1:-}" = --budget-seconds ]; then
    [ "$#" -ge 2 ] || usage
    case "$2" in ''|*[!0-9]*) broken 'budget must be positive';; esac
    REQUESTED=$((10#$2)); shift 2
    [ "$REQUESTED" -ge "$BUDGET" ] || BUDGET=$REQUESTED
  fi
  [ "${1:-}" = -- ] || usage; shift
  [ "$#" -gt 0 ] || usage
  [ "$BUDGET" -gt 0 ] || broken 'budget must be positive (LOCK_WAIT minus 300)'
  case "$MAX_CONC" in ''|*[!0-9]*) broken 'invalid maximum concurrency';; esac
  MAX_CONC=$((10#$MAX_CONC))
  [ "$MAX_CONC" -gt 0 ] || broken 'invalid maximum concurrency'
  mkdir -p "$PRO_GATE_HOME" || broken 'cannot create runtime directory'
  pg_reservation_guard_acquire || defer 'reservation guard is busy'
  for f in "$(pg_reservation_dir)"/*; do
    if pg_reservation_holds_capacity "$f"; then defer 'a reservation holds review capacity'; fi
  done
  for f in "$LOCKFILE".pr-*; do
    if pg_fd_lock_busy "$f"; then defer 'a per-change review lock is busy'; fi
  done
  i=1
  while [ "$i" -le "$MAX_CONC" ]; do
    pg_fd_open "$LOCKFILE.slot$i" || broken 'cannot open slot lock'
    pg_fd_lock "$PG_FD" 0 || defer "review slot $i is busy"
    i=$((i+1))
  done
  pg_reservation_guard_release
  export PRO_GATE_BUMP_HOLD=1 PRO_GATE_BUMP_DEADLINE="$(($(date +%s) + BUDGET))"
  # GNU timeout and coreutils gtimeout both support the kill grace. The grace is inside
  # the reserved 300 seconds, so a TERM-ignoring child cannot outlive the queue budget.
  # timeout runs the command in its own process group, so a terminal's Ctrl-C or a TERM
  # sent to this shell alone would never reach it: forward them, and timeout passes the
  # TERM on and still kills after the grace.
  timeout -k 15 "$BUDGET" "$@" &
  HELD=$!
  GOT=''
  # shellcheck disable=SC2329 # invoked by the traps below
  forward() { GOT=$1; kill -TERM "$HELD" 2>/dev/null; }
  trap 'forward INT' INT
  trap 'forward TERM' TERM
  trap 'forward HUP' HUP
  while :; do
    wait "$HELD"
    rc=$?
    # A trapped signal ends wait early, with the command still running.
    kill -0 "$HELD" 2>/dev/null || break
  done
  trap - INT TERM HUP
  [ -z "$GOT" ] || broken "interrupted by $GOT; the held command exited $rc"
  case "$rc" in 124|137) broken 'held command timed out';; *) exit "$rc";; esac
fi

CANDIDATE='' CONTROL='' OUT='' COUNT=20
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --candidate-root) CANDIDATE=$2;;
    --control-root) CONTROL=$2;;
    --out) OUT=$2;;
    --count) COUNT=$2;;
    *) usage;;
  esac
  shift 2
done
[ -n "$CANDIDATE" ] && [ -n "$CONTROL" ] && [ -n "$OUT" ] || usage
case "$COUNT" in ''|*[!0-9]*) usage;; esac
[ "$COUNT" -gt 0 ] || usage
if ! [ "${PRO_GATE_BUMP_HOLD:-}" = 1 ] || ! pg_fd_lock_busy "$LOCKFILE.slot1"; then broken 'trial requires hold and a busy slot 1'; fi
case "${PRO_GATE_BUMP_DEADLINE:-}" in ''|*[!0-9]*) broken 'hold deadline missing';; esac
mkdir -p "$OUT" || broken 'cannot create trial output directory'
verdict_broken() {
  jq -cn --arg reason "$1" '{verdict:"broken",reason:$reason,candidate:null,control:null}' > "$OUT/verdict.json" || exit 1
  cat "$OUT/verdict.json"
  exit 1
}
# The control is the live build reviews already run, so only risky lines and manifest
# entries the candidate adds need a reviewer. A reviewed set passes with its digest in
# PRO_GATE_BUMP_AUDIT_ACK, which also binds the candidate and live versions.
AUDIT_ARGS=(audit --oracle-root "$CANDIDATE" --baseline-root "$CONTROL")
[ -n "${PRO_GATE_BUMP_AUDIT_ACK:-}" ] && AUDIT_ARGS+=(--ack "$PRO_GATE_BUMP_AUDIT_ACK")
if ! "$NODE" "$TRIAL" "${AUDIT_ARGS[@]}" > "$OUT/audit.json" \
  || ! jq -e '.ok == true and (.missing | length) == 0' "$OUT/audit.json" >/dev/null 2>&1; then
  reason="$(jq -r --arg f "$OUT/audit.json" '
    if (.missing | length) > 0 then
      "audit: Oracle functions the trial calls are missing: " + ([.missing[] | (.function? // tostring)] | join(", "))
    elif .digest then
      "audit: \(.hits | length) risky lines or manifest entries are new since the live build; read \($f), then rerun with PRO_GATE_BUMP_AUDIT_ACK=\(.digest) to accept exactly that set"
    else "candidate audit failed" end' "$OUT/audit.json" 2>/dev/null)" || reason=''
  verdict_broken "${reason:-candidate audit failed}"
fi
run_trial() {
  "$NODE" "$TRIAL" run --oracle-root "$1" --out "$OUT/$2" --count "$COUNT" \
    --stop-at-failures 3 --deadline-epoch "$PRO_GATE_BUMP_DEADLINE" \
    --host 127.0.0.1 --port "${ORACLE_BROWSER_PORT:-9222}" --model "${ORACLE_MODEL:-gpt-5.6}" \
    > "$OUT/$2.log"
}
run_trial "$CANDIDATE" candidate || verdict_broken 'candidate run broken'
"$NODE" "$TRIAL" decide --candidate "$OUT/candidate/summary.json" > "$OUT/verdict.json" || verdict_broken 'candidate decision failed'
if [ "$(jq -r '.verdict' "$OUT/verdict.json" 2>/dev/null)" = needs-control ]; then
  run_trial "$CONTROL" control || verdict_broken 'control run broken'
  "$NODE" "$TRIAL" decide --candidate "$OUT/candidate/summary.json" --control "$OUT/control/summary.json" > "$OUT/verdict.json" || verdict_broken 'control decision failed'
fi
result="$(jq -r '.verdict' "$OUT/verdict.json" 2>/dev/null)"
case "$result" in pass) rc=0;; reject) rc=3;; defer) rc=4;; broken) rc=1;; *) verdict_broken 'invalid verdict';; esac
cat "$OUT/verdict.json"
exit "$rc"
