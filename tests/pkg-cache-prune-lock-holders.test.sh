#!/usr/bin/env bash
# pkg-cache-prune's lock_holders(), against real flock(2) holders, and its wiring:
# a BUSY uv prune names the processes holding uv's cache lock (#697).
#
# The holders are python3 processes calling flock(2) themselves, as uv does, so
# /proc/locks reports their own pid. flock(1) would report its helper's pid, or
# leave a forked child holding the lock after the test kills the parent.
#
# Linux only: lock_holders reads /proc/locks. CI and this host are Linux, so a
# missing /proc/locks fails here rather than passing as a quiet skip.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/pkg-cache-prune.sh
TMP=$(mktemp -d) || exit 1
pids=()
cleanup() { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -r /proc/locks ] || { echo "FAIL: /proc/locks is not readable; this suite needs Linux" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required for the lock holders" >&2; exit 1; }

# Extract the function alone; running the whole script would prune this machine's caches.
sed -n '/^lock_holders() {/,/^}/p' "$SCRIPT" > "$TMP/fn.sh"
grep -q '^lock_holders() {' "$TMP/fn.sh" || { echo "FAIL: could not extract lock_holders()" >&2; exit 1; }
# shellcheck source=/dev/null
. "$TMP/fn.sh"

# hold <SH|EX> <file>: start a process that takes flock(2) on <file> and sleeps; print its pid.
hold() {
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[2], "a")
fcntl.flock(f, getattr(fcntl, "LOCK_" + sys.argv[1]))
time.sleep(300)' "$1" "$2" >/dev/null 2>&1 &
  echo $!
}

# await <pid> <file> <held|waiting>: block until /proc/locks shows it, up to 10s.
# Reads fixed columns on purpose, independently of the field search under test.
await() {
  local maj min ino key _
  read -r maj min ino < <(stat -Lc '%Hd %Ld %i' "$2")
  key=$(printf '%02x:%02x:%s' "$maj" "$min" "$ino")
  for _ in $(seq 100); do
    if [ "$3" = held ]; then
      awk -v p="$1" -v k="$key" '$2 != "->" && $5 == p && $6 == k { f = 1 } END { exit !f }' /proc/locks && return 0
    else
      awk -v p="$1" -v k="$key" '$2 == "->" && $6 == p && $7 == k { f = 1 } END { exit !f }' /proc/locks && return 0
    fi
    sleep 0.1
  done
  echo "FAIL: pid $1 never showed as $3 on $2 in /proc/locks" >&2; exit 1
}

: > "$TMP/a.lock"; : > "$TMP/b.lock"
a1=$(hold SH "$TMP/a.lock"); pids+=("$a1")
a2=$(hold SH "$TMP/a.lock"); pids+=("$a2")
b1=$(hold SH "$TMP/b.lock"); pids+=("$b1")
await "$a1" "$TMP/a.lock" held; await "$a2" "$TMP/a.lock" held; await "$b1" "$TMP/b.lock" held
# An exclusive request blocks behind the shared holders: a "->" waiter line, which holds nothing.
w=$(hold EX "$TMP/a.lock"); pids+=("$w")
await "$w" "$TMP/a.lock" waiting

out=$(lock_holders "$TMP/a.lock"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "lock_holders returned $rc with holders present"
for p in "$a1" "$a2"; do
  printf '%s\n' "$out" | grep -q "^     holder: pid $p, running [0-9:-]*: python3 -c import fcntl" && ok \
    || bad "holder $p not named with its uptime and command line; got: $out"
done
printf '%s\n' "$out" | grep -q "pid ${w}[,:]" && bad "the blocked waiter $w was named as a holder" || ok
printf '%s\n' "$out" | grep -q "pid ${b1}[,:]" && bad "the holder of a different file ($b1) was named" || ok
[ "$(printf '%s\n' "$out" | grep -c '^     holder: ')" -eq 2 ] && ok || bad "want exactly 2 holder lines; got: $out"

out=$(lock_holders "$TMP/b.lock")
printf '%s\n' "$out" | grep -q "^     holder: pid $b1, " && ok || bad "b.lock's holder not named; got: $out"

: > "$TMP/free.lock"
out=$(lock_holders "$TMP/free.lock"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "     holders: none left in /proc/locks" ] && ok \
  || bad "an unheld lock should report none left, rc 0; got rc=$rc: $out"
out=$(lock_holders "$TMP/missing.lock"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok || bad "a missing lock file should print nothing, rc 0; got rc=$rc: $out"

# ---- wiring: the whole script with stubbed package managers -------------------
# pnpm and npm stubs succeed so the real ones never run; uv reports lock contention,
# as uv does after its lock timeout, so the uv lane comes back BUSY.
mkdir -p "$TMP/bin" "$TMP/home/.cache/uv" "$TMP/alt"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/pnpm"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/npm"
printf '#!/bin/sh\necho "error: Timeout (1s) when waiting for lock on $HOME/.cache/uv at .cache/uv/.lock" >&2\nexit 2\n' > "$TMP/bin/uv"
chmod +x "$TMP/bin/pnpm" "$TMP/bin/npm" "$TMP/bin/uv"
: > "$TMP/home/.cache/uv/.lock"; : > "$TMP/alt/.lock"
u=$(hold SH "$TMP/home/.cache/uv/.lock"); pids+=("$u")
v=$(hold SH "$TMP/alt/.lock"); pids+=("$v")
await "$u" "$TMP/home/.cache/uv/.lock" held; await "$v" "$TMP/alt/.lock" held

prune() { env -u UV_CACHE_DIR -u XDG_CACHE_HOME HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$@" bash "$SCRIPT" 2>&1; }

out=$(prune DRY_RUN=0); rc=$?
[ "$rc" -eq 0 ] && ok || bad "a BUSY uv prune must still exit 0; got $rc"
printf '%s\n' "$out" | grep -q '~~ BUSY (cache in use; next run will retry): uv cache prune' && ok || bad "no uv BUSY line; got: $out"
printf '%s\n' "$out" | grep -q "^     holder: pid $u, " && ok || bad "the BUSY uv lane did not name holder $u; got: $out"
printf '%s\n' "$out" | grep -q "pid ${v}[,:]" && bad "the default lock lookup named the UV_CACHE_DIR holder $v" || ok
printf '%s\n' "$out" | grep -q 'busy:1' && ok || bad "the summary should count one busy lane; got: $out"

out=$(prune DRY_RUN=0 UV_CACHE_DIR="$TMP/alt")
printf '%s\n' "$out" | grep -q "^     holder: pid $v, " && ok || bad "UV_CACHE_DIR's lock holder $v not named; got: $out"

out=$(prune DRY_RUN=1)
printf '%s\n' "$out" | grep -q 'holder' && bad "a dry run printed lock holders; got: $out" || ok

printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/uv"
out=$(prune DRY_RUN=0)
printf '%s\n' "$out" | grep -q 'holder' && bad "a successful uv prune printed lock holders; got: $out" || ok

if [ "$fail" -eq 0 ]; then
  echo "ok — pkg-cache-prune lock holders: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — pkg-cache-prune lock holders: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
