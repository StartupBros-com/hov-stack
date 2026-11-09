#!/usr/bin/env bash
# group-timeout.test.sh: scripts/lib/group-timeout.sh behaves as a drop-in for `timeout`,
# bounds the command's whole process group, and keeps its deadline when the caller is
# cancelled (#450; the outer-cancellation and duration cases come from #509's review).
#
# Timing cases put bounds of seconds around sub-second deadlines, so a loaded runner does
# not flake them.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=$ROOT/scripts/lib/group-timeout.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The helper's scratch files land here, so the leftover checks below can count them.
export TMPDIR=$TMP
# shellcheck source=SCRIPTDIR/../scripts/lib/group-timeout.sh
. "$LIB"

pass=0 failed=0
ok() { pass=$((pass + 1)); }
bad() { failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$3" = "$2" ]; then ok; else bad "$1: want $2, got $3"; fi; }
within() { if [ "$3" -le "$2" ]; then ok; else bad "$1: took $3 ms, bound $2 ms"; fi; }
now_ms() { local ns; ns=$(date +%s%N); printf '%s\n' "${ns%??????}"; }

# The command's own status passes through.
group_timeout 5 bash -c 'exit 3'
check 'the command status passes through' 3 $?

# SECS elapsed: 124, promptly.
t0=$(now_ms); group_timeout 0.3 sleep 5; rc=$?; t1=$(now_ms)
check 'an elapsed deadline returns 124' 124 "$rc"
within 'an elapsed deadline returns promptly' 3000 $((t1 - t0))

# A TERM handler's exit status does not replace 124; red-first relies on that.
group_timeout 0.3 bash -c 'trap "exit 1" TERM; sleep 5 & wait'
check 'a TERM handler status does not replace 124' 124 $?

# A descendant that ignores TERM cannot hold the caller's stdout past the grace (#450).
t0=$(now_ms)
out=$(group_timeout -k 0.3 0.3 bash -c 'trap "" TERM; echo started; sleep 5 & wait')
rc=$?; t1=$(now_ms)
check 'a group that outlives the grace is killed, 137' 137 "$rc"
check 'output from before the deadline is kept' started "$out"
within 'a TERM-ignoring descendant cannot hold stdout' 3000 $((t1 - t0))

# Cancelling the caller's process group keeps the command's own deadline. The enclosing
# timeout ends the caller at 0.3 s; the command must still stop at its 0.8 s deadline,
# before it writes a marker at 2 s.
cat >"$TMP/caller.sh" <<'EOF'
. "$1"
group_timeout 0.8 bash -c ': >"$1/started"; sleep 2; : >"$1/late"' _ "$2"
EOF
timeout 0.3 bash "$TMP/caller.sh" "$LIB" "$TMP"
check 'the enclosing timeout ends the caller first' 124 $?
sleep 2.5
if [ -e "$TMP/started" ]; then ok; else bad 'outer cancellation: the command never started'; fi
if [ ! -e "$TMP/late" ]; then ok; else bad 'outer cancellation: the command outlived its own 0.8 s deadline'; fi
leftover=$(find "$TMP" -maxdepth 1 -name 'group-timeout.*' | wc -l)
check 'a cancelled call leaves no scratch files' 0 "$leftover"

# A bad duration is refused before the command starts, as `timeout` refuses it.
for d in invalid '' -1 5S nan 5x; do
  rm -f "$TMP/ran"
  # shellcheck disable=SC2016 # $1 belongs to the inner bash
  group_timeout "$d" bash -c ': >"$1/ran"' _ "$TMP" 2>"$TMP/err"
  check "SECS '$d' is refused" 125 $?
  if [ ! -e "$TMP/ran" ]; then ok; else bad "SECS '$d': the command ran"; fi
  if grep -qF 'invalid time interval' "$TMP/err"; then ok; else bad "SECS '$d': no diagnostic"; fi
done
rm -f "$TMP/ran"
# shellcheck disable=SC2016 # $1 belongs to the inner bash
group_timeout -k bogus 5 bash -c ': >"$1/ran"' _ "$TMP" 2>/dev/null
check "GRACE 'bogus' is refused" 125 $?
if [ ! -e "$TMP/ran" ]; then ok; else bad "GRACE 'bogus': the command ran"; fi
group_timeout 5 2>/dev/null
check 'a missing command is refused' 125 $?

# Every form `timeout` reads is accepted.
for d in 5 5s 2.5 .5 5. 1e1 0x10 0.1m 1h 1d inf; do
  group_timeout "$d" bash -c 'exit 4'
  check "SECS '$d' is accepted" 4 $?
done

# 0 disables a limit, as in `timeout`.
group_timeout 0 bash -c 'sleep 0.5; exit 7'
check 'SECS 0 sets no deadline' 7 $?
group_timeout -k 0 0.3 bash -c 'trap "" TERM; sleep 1; exit 5'
check 'GRACE 0 sends no KILL, so the TERM-ignoring command finishes (124)' 124 $?

# A timer that cannot run stops the command and reports 125 rather than leaving it unbounded.
if command -v setsid >/dev/null 2>&1; then
  real_sleep=$(command -v sleep)
  mkdir -p "$TMP/stub"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/stub/sleep"
  chmod +x "$TMP/stub/sleep"
  t0=$(now_ms)
  PATH="$TMP/stub:$PATH" group_timeout 5 "$real_sleep" 5 2>"$TMP/err"
  rc=$?; t1=$(now_ms)
  check 'a failed timer returns 125' 125 "$rc"
  within 'a failed timer stops the command' 3000 $((t1 - t0))
  if grep -qF 'timer failed' "$TMP/err"; then ok; else bad 'a failed timer: no diagnostic'; fi
fi

leftover=$(find "$TMP" -maxdepth 1 -name 'group-timeout.*' | wc -l)
check 'no scratch files are left behind' 0 "$leftover"

printf '%d/%d passed\n' "$pass" $((pass + failed))
[ "$failed" -eq 0 ]
