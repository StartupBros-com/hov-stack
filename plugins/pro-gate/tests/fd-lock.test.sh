#!/usr/bin/env bash
# The one lock primitive (#322) through the real library, under both lock tools: flock(1), and
# perl's flock() on the inherited descriptor, which is what stock macOS runs. No mocks: every
# holder is a real process holding a real flock(2), and every release is the kernel's.
#
# Portable to macOS /bin/bash 3.2 on purpose (no {var} redirection, no BASHPID, no wait -n), so the
# same file is the macOS proof: `/bin/bash tests/fd-lock.test.sh` on a Mac exercises the perl path
# with the shell that has no flock(1).
#
# Planted negatives, run when this file was written: with pg_fd_lock's body replaced by `return 0`,
# 34 checks fail across the three modes (every race, wait, probe, stacking, re-entry, slot, interop
# and no-tool check) and the suite exits 1. With pg_lock's re-entry test removed, the "returns 0
# at once" check fails in both tool modes; with it loosened from same-inode to path-exists, the
# "recreated lock file" check does. A green run on Linux says nothing about bash 3.2; that needs
# the macOS run above.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TDIR="$(mktemp -d "${TMPDIR:-/tmp}/pg-fd-lock.XXXXXX")" || exit 2
BG=""
cleanup() {
  local p
  for p in $BG; do kill -9 "$p" 2>/dev/null; done
  for p in $BG; do wait "$p" 2>/dev/null; done
  rm -rf "$TDIR"
}
trap cleanup EXIT
FAILURES=0
. "$ROOT/lib/pro-gate-lib.sh"

ok() { printf 'ok - [%s] %s\n' "$MODE" "$1"; }
no() { printf 'not ok - [%s] %s\n' "$MODE" "$1"; FAILURES=$(( FAILURES + 1 )); }
# t <name> <condition>: the condition is a literal string from this file, evaluated in place.
t() { if eval "$2"; then ok "$1"; else no "$1"; fi; }
waitfor() { local i=0; while [ ! -e "$1" ]; do i=$(( i + 1 )); [ "$i" -ge 100 ] && return 1; sleep 0.1; done; }
reap() { local p; for p in "$@"; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; }
# A holder takes the lock, says so, then BECOMES sleep: no shell child inherits the descriptor,
# so SIGKILL of $! closes the last one and the kernel drops the lock.
hold() { ( pg_lock "$1" 5 && : > "$2" && exec sleep 60 ) & HOLDER=$!; BG="$BG $HOLDER"; waitfor "$2"; }
nfds() { ls /dev/fd 2>/dev/null | wc -l | tr -d ' '; }

contend() { # path log go
  while [ ! -e "$3" ]; do :; done
  if pg_lock "$1" 0 2>/dev/null; then printf 'enter\n' >> "$2"; exec sleep 30; fi
  printf 'lost\n' >> "$2"
}

run_mode() {
  local d="$TDIR/${MODE%%:*}" i n a b t0 el rc fds0 fds1 slots re1 re2 rel
  mkdir -p "$d" || return 1

  # #155, kept as an assertion: after an owner dies holding the lock, two contenders racing for it
  # never both enter. The mkdir lock admitted both in about 5 of 100 runs (#322).
  hold "$d/race" "$d/race.held"; reap "$HOLDER"
  n=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    rm -f "$d/race.log" "$d/race.go"
    ( contend "$d/race" "$d/race.log" "$d/race.go" ) & a=$!
    ( contend "$d/race" "$d/race.log" "$d/race.go" ) & b=$!
    BG="$BG $a $b"
    : > "$d/race.go"
    # Both have decided once two lines are in: enter+lost, or a double entry's enter+enter.
    t0=0; while [ "$(cat "$d/race.log" 2>/dev/null | wc -l | tr -d ' ')" != 2 ]; do t0=$(( t0 + 1 )); [ "$t0" -ge 30 ] && break; sleep 0.1; done
    [ "$(grep -c enter "$d/race.log" 2>/dev/null)" = 1 ] && n=$(( n + 1 ))
    reap "$a" "$b"
  done
  t "two contenders after a SIGKILLed owner: exactly one enters, 20 of 20 races" '[ "$n" = 20 ]'

  # A waiter blocked behind a live holder enters once the holder is SIGKILLed, inside its wait.
  hold "$d/kill" "$d/kill.held"
  ( pg_lock "$d/kill" 10 && date +%s > "$d/kill.entered" ) & a=$!; BG="$BG $a"
  sleep 1
  t "a waiter does not enter while the holder lives" '[ ! -e "$d/kill.entered" ]'
  t0=$(date +%s); reap "$HOLDER"; wait "$a" 2>/dev/null
  el=$(( $(cat "$d/kill.entered" 2>/dev/null || echo 99) - t0 ))
  t "SIGKILL of the holder lets the waiter in within 2s" '[ "$el" -le 2 ]'

  # Bounded waits, and the descriptor of a losing attempt is closed.
  hold "$d/busy" "$d/busy.held"
  fds0=$(nfds)
  t0=$(date +%s); pg_lock "$d/busy" 2 2>/dev/null; rc=$?; el=$(( $(date +%s) - t0 ))
  fds1=$(nfds)
  t "a 2s wait on a held lock returns 1" '[ "$rc" = 1 ]'
  t "a 2s wait gives up after 1-4s (took ${el}s)" '[ "$el" -ge 1 ] && [ "$el" -le 4 ]'
  t "a timed-out attempt leaks no descriptor ($fds0 -> $fds1)" '[ "$fds0" = "$fds1" ]'
  t0=$(date +%s); pg_lock "$d/busy" 0 2>/dev/null; rc=$?; el=$(( $(date +%s) - t0 ))
  t "a 0s wait on a held lock returns 1 at once" '[ "$rc" = 1 ] && [ "$el" -le 1 ]'
  t0=$(date +%s); pg_lock "$d/busy" 02 2>/dev/null; rc=$?; el=$(( $(date +%s) - t0 ))
  t "a zero-padded wait (02) is decimal seconds, not an abort" '[ "$rc" = 1 ] && [ "$el" -ge 1 ]'
  ( pg_lock "$d/free08" 08 ) ; rc=$?
  t "a zero-padded wait (08) takes a free lock" '[ "$rc" = 0 ]'

  # The liveness probe: busy only while held, never creates the file, never keeps the lock.
  t "probe reads a held lock as busy" 'pg_fd_lock_busy "$d/busy"'
  reap "$HOLDER"
  if pg_fd_lock_busy "$d/busy"; then no "probe reads a released lock as free"; else ok "probe reads a released lock as free"; fi
  ( pg_lock "$d/busy" 0 ) ; rc=$?
  t "the probe did not keep the lock" '[ "$rc" = 0 ]'
  pg_fd_lock_busy "$d/absent"; rc=$?
  t "probe of an absent lock is free and creates nothing" '[ "$rc" = 1 ] && [ ! -e "$d/absent" ]'

  # Two pg_lock calls in one shell hold both (the fixed fd 9 released the first).
  ( pg_lock "$d/stackA" 0 && pg_lock "$d/stackB" 0 && : > "$d/stack.held" && exec sleep 60 ) & a=$!; BG="$BG $a"
  waitfor "$d/stack.held"
  ( pg_lock "$d/stackA" 0 ) ; rc=$?
  t "a second pg_lock in one shell keeps the first lock held" '[ "$rc" = 1 ]'
  reap "$a"

  # Re-entrant per file: locking a file this process already holds, by the same spelling or
  # another one, returns 0 at once instead of waiting out the budget on its own lock.
  mkdir -p "$d/re"
  ( pg_lock "$d/re/lk" 0 || exit 9
    t0=$SECONDS; pg_lock "$d/re/lk" 3; r1=$?; pg_lock "$d/re/../re/lk" 3; r2=$?
    printf '%s %s %s\n' "$r1" "$r2" "$(( SECONDS - t0 ))" > "$d/re.out"
    : > "$d/re.held"; exec sleep 60 ) & a=$!; BG="$BG $a"
  waitfor "$d/re.held"
  read -r re1 re2 rel < "$d/re.out"
  t "pg_lock on a file this process holds returns 0 at once, by either spelling" \
    '[ "$re1" = 0 ] && [ "$re2" = 0 ] && [ "$rel" -le 1 ]'
  ( pg_lock "$d/re/lk" 0 ) ; rc=$?
  t "the re-entered lock is still held" '[ "$rc" = 1 ]'
  reap "$a"
  # A lock file unlinked and recreated (by anyone) is a different file, so it is locked afresh.
  ( pg_lock "$d/re/lk2" 0 || exit 9; rm -f "$d/re/lk2"; : > "$d/re/lk2"; pg_lock "$d/re/lk2" 0; echo "$?" > "$d/re2.out"
    : > "$d/re2.held"; exec sleep 60 ) & a=$!; BG="$BG $a"
  waitfor "$d/re2.held"
  ( pg_lock "$d/re/lk2" 0 ) ; rc=$?
  t "a recreated lock file is locked afresh, not taken as already held" \
    '[ "$(cat "$d/re2.out")" = 0 ] && [ "$rc" = 1 ]'
  reap "$a"

  # The counting semaphore: two slots hold two holders, a third waits, a freed slot is reused,
  # and an excluded slot is never taken.
  ( pg_lock_n "$d/acct" 2 0 && printf '%s\n' "$PG_SLOT_ACQUIRED" > "$d/slotA" && exec sleep 60 ) & a=$!; BG="$BG $a"
  waitfor "$d/slotA"
  ( pg_lock_n "$d/acct" 2 0 && printf '%s\n' "$PG_SLOT_ACQUIRED" > "$d/slotB" && exec sleep 60 ) & b=$!; BG="$BG $b"
  waitfor "$d/slotB"
  slots="$(cat "$d/slotA" "$d/slotB" | sort | tr '\n' ' ')"
  t "two holders take slots 1 and 2" '[ "$slots" = "1 2 " ]'
  ( pg_lock_n "$d/acct" 2 0 ) ; rc=$?
  t "a third contender finds no free slot" '[ "$rc" = 1 ]'
  if [ "$(cat "$d/slotA")" = 1 ]; then reap "$a"; else reap "$b"; fi
  ( pg_lock_n "$d/acct" 2 0 2 && [ "$PG_SLOT_ACQUIRED" = 1 ] ) ; rc=$?
  t "a SIGKILLed slot holder's slot is taken again" '[ "$rc" = 0 ]'
  ( pg_lock_n "$d/acct" 2 0 1 ) ; rc=$?
  t "an excluded free slot is never taken" '[ "$rc" = 1 ]'
  reap "$a" "$b"

  # An unwritable lock path proceeds unlocked, as it has where flock(1) existed.
  pg_lock "$d/missing-dir/x" 1 2>/dev/null; rc=$?
  t "an unwritable lock path proceeds unlocked" '[ "$rc" = 0 ]'

  # The two tools exclude each other: a flock(1) holder blocks the perl path and back.
  if [ "$MODE" = perl ] && command -v flock >/dev/null 2>&1; then
    ( exec 9>>"$d/mix"; flock 9; : > "$d/mix.held"; exec sleep 60 ) & a=$!; BG="$BG $a"
    waitfor "$d/mix.held"
    ( pg_lock "$d/mix" 0 ) ; rc=$?
    t "a flock(1) holder blocks the perl path" '[ "$rc" = 1 ]'
    reap "$a"
    hold "$d/mix2" "$d/mix2.held"
    ( exec 9>>"$d/mix2"; flock -n 9 ) ; rc=$?
    t "a perl-path holder blocks flock(1)" '[ "$rc" = 1 ]'
    reap "$HOLDER"
  fi
}

MODE="native:$(pg_have flock && echo flock || echo perl)"
run_mode
pg_have() { [ "$1" = flock ] && return 1; command -v "$1" >/dev/null 2>&1; }
MODE=perl
if command -v perl >/dev/null 2>&1; then run_mode; else no "perl is installed"; fi

# With neither tool, nothing is locked and nothing runs as though it were.
pg_have() { case "$1" in flock|perl) return 1;; esac; command -v "$1" >/dev/null 2>&1; }
MODE=none
: > "$TDIR/none"
pg_fd_open "$TDIR/none"; pg_fd_lock "$PG_FD" 0; rc=$?; pg_fd_close "$PG_FD"
t "pg_fd_lock reports no lock tool as 2" '[ "$rc" = 2 ]'
err="$(pg_lock "$TDIR/none" 0 2>&1 >/dev/null)"; rc=$?
t "pg_lock refuses (1) with no lock tool" '[ "$rc" = 1 ]'
case "$err" in *"neither flock(1) nor perl"*) ok "pg_lock names the missing tools";; *) no "pg_lock names the missing tools";; esac
( pg_lock_n "$TDIR/none-acct" 2 0 ) 2>/dev/null; rc=$?
t "pg_lock_n refuses (1) with no lock tool" '[ "$rc" = 1 ]'

printf '%s on bash %s\n' "$( [ "$FAILURES" = 0 ] && echo 'ok - fd-lock suite passed' || echo "not ok - $FAILURES fd-lock checks failed")" "$BASH_VERSION"
[ "$FAILURES" = 0 ]
