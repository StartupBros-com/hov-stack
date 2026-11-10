#!/usr/bin/env bash
# claude-env.sh's per-command memory scope (harness/wsl-memory-bounds.md, "Agent tool commands").
#
# The logic cases drive the prelude through its test seams (HOV_STACK_TOOL_SCOPE_TEST_MODE=1): a
# fake cgroup root, a fake /proc/self/cgroup, and a fake busctl that records its argv and
# "moves" the shell by rewriting the fake proc file. They prove what the prelude decides and
# what it asks systemd for, not that systemd honours it. The live cases do that, and each one
# prints a skip line naming what this host lacks:
#   - re-scope: a real move out of /init.scope, a real OOM kill under the cap, and the heavy
#     wrapper's own scope started from inside the moved shell. It needs an uncapped
#     /init.scope shell and a user bus, so it runs from a WSL session's Bash tool only until
#     this prelude is live there (after that the session's shells are already in a scope).
#   - pool: a delegated cgroup named claude-code-bash, entered the way Claude Code's MCP spawn
#     path enters its pool. The swap bound turns a RAM-cap overflow into a kill, and an
#     off-word control survives the same allocation. It needs a user manager that delegates
#     the memory controller.
#
# shellcheck disable=SC2016 # the single-quoted strings are code for the inner shell
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENVFILE=$REPO/claude-env.sh
HEADROOM=$REPO/scripts/heavy-job-headroom.js
HEAVY_RUN=$REPO/hooks/lib/heavy-job-admission-run.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0 skipped=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
skip() { skipped=$((skipped + 1)); echo "skip: $*"; }
is_eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }
has() { case $1 in *"$2"*) ok ;; *) bad "$3 ('$1' lacks '$2')" ;; esac; }
lacks() { case $1 in *"$2"*) bad "$3 ('$1' has '$2')" ;; *) ok ;; esac; }

ROOT=$TMP/root        # the fake /sys/fs/cgroup
PROC=$TMP/proc-cgroup # the fake /proc/self/cgroup
RT=$TMP/rt            # a runtime directory holding a bus socket
ARGV=$TMP/busctl.argv # the fake busctl's arguments, one per line
FENV=$TMP/busctl.env  # the bus environment the fake busctl saw
FAKE=$TMP/bin/busctl
OUT=$TMP/out
ERR=$TMP/err
USER_SVC=/user.slice/user-1000.slice/user@1000.service
POOL=$ROOT$USER_SVC/claude-code-bash
mkdir -p "$TMP/home" "$TMP/bin" "$RT" "$TMP/rt-nobus"
if ! python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$RT/bus"; then
  echo "FAIL — claude-env tool scope: cannot create the fake bus socket" >&2
  exit 1
fi

# The fake busctl answers the way the real one does: the job path on stdout, then the move.
cat >"$FAKE" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_ARGV"
printf 'DBUS_SESSION_BUS_ADDRESS=%s\nXDG_RUNTIME_DIR=%s\n' "${DBUS_SESSION_BUS_ADDRESS-}" "${XDG_RUNTIME_DIR-}" >"$FAKE_ENV"
moved="0::/user.slice/user-1000.slice/user@1000.service/app.slice/$9"
case ${FAKE_MODE-move} in
  move) echo 'o "/org/freedesktop/systemd1/job/42"'; printf '%s\n' "$moved" >"$FAKE_PROC" ;;
  late) { sleep 0.03; printf '%s\n' "$moved" >"$FAKE_PROC"; } </dev/null >/dev/null 2>&1 & ;;
  stay) echo 'o "/org/freedesktop/systemd1/job/42"' ;;
  fail) echo 'Failed to start transient scope unit: Access denied' >&2; echo 'second line' >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE"

# fresh CGROUP: an empty cgroup v2 root with this shell in CGROUP and an unbounded init.scope.
fresh() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/init.scope"
  : >"$ROOT/cgroup.controllers"
  printf 'max\n' >"$ROOT/init.scope/memory.max"
  printf '0::%s\n' "$1" >"$PROC.init"
}
# pool MEMORY_MAX SWAP_MAX: the shell sits in a native claude-code-bash pool.
pool() {
  fresh "$USER_SVC/claude-code-bash"
  mkdir -p "$POOL"
  printf '%s\n' "$1" >"$POOL/memory.max"
  printf '%s\n' "$2" >"$POOL/memory.swap.max"
}
# src SHELL PRE CMD [NAME=value...]: in a clean SHELL with only HOME, PATH, the runtime
# directory, the test seams and the named assignments, run PRE, source claude-env.sh, then run
# CMD. Every call starts from the cgroup file fresh() or a case wrote to $PROC.init, so a move
# the fake made in one case never leaks into the next. Stdout lands in $OUT, stderr in $ERR,
# the exit status in $RC.
src() {
  local sh=$1 pre=$2 cmd=$3
  shift 3
  rm -f "$ARGV" "$FENV"
  cp "$PROC.init" "$PROC"
  env -i HOME="$TMP/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$RT" \
    HOV_STACK_TOOL_SCOPE_TEST_MODE=1 HOV_STACK_TOOL_SCOPE_TEST_CGROUP_ROOT="$ROOT" \
    HOV_STACK_TOOL_SCOPE_TEST_PROC_CGROUP="$PROC" HOV_STACK_TOOL_SCOPE_TEST_BUSCTL="$FAKE" \
    FAKE_ARGV="$ARGV" FAKE_ENV="$FENV" FAKE_PROC="$PROC" "$@" \
    "$sh" -c '__t_env=$1 __t_cmd=$2; eval "$3"; . "$__t_env"; eval "$__t_cmd"' _ "$ENVFILE" "$cmd" "$pre" \
    >"$OUT" 2>"$ERR"
  RC=$?
}
out() { cat "$OUT"; }
err() { cat "$ERR"; }
called() { if [ -e "$ARGV" ]; then echo yes; else echo no; fi; }
swapmax() { cat "$POOL/memory.swap.max"; }
# The arguments after the unit name, joined with '|'.
props() { tail -n +10 "$ARGV" | paste -sd'|' -; }
LIMIT4G=CLAUDE_CODE_TOOL_MEMORY_LIMIT=4G

is_eq "$(bash -n "$ENVFILE" 2>&1; echo "rc=$?")" "rc=0" "claude-env.sh parses"

# -- /init.scope: the move into a capped scope ---------------------------------------------
fresh /init.scope
src bash : 'echo "$$"' "$LIMIT4G"
pid=$(out)
is_eq "$RC:$(err)" "0:" "re-scope: the command runs and nothing reaches stderr"
is_eq "$(called)" yes "re-scope: an uncapped /init.scope shell with a size limit asks for a scope"
is_eq "$(head -n 8 "$ARGV" | paste -sd'|' -)" \
  "--user|--timeout=2|call|org.freedesktop.systemd1|/org/freedesktop/systemd1|org.freedesktop.systemd1.Manager|StartTransientUnit|ssa(sv)a(sa(sv))" \
  "re-scope: one bounded StartTransientUnit call on the user bus"
unit=$(sed -n 9p "$ARGV")
case $unit in
  "hov-tool-$pid-"*.scope) ok ;;
  *) bad "re-scope: the unit is named for the shell (got '$unit', pid $pid)" ;;
esac
is_eq "$(props)" \
  "fail|7|PIDs|au|1|$pid|MemoryMax|t|4294967296|TasksMax|t|18446744073709551615|CollectMode|s|inactive-or-failed|OOMPolicy|s|continue|Description|s|hov-stack capped tool command|MemorySwapMax|t|4294967296|0" \
  "re-scope: the shell's own pid, the cap as MemoryMax, swap bounded at the cap, no task limit, the shell survives an OOM kill"
is_eq "$(cat "$FENV")" "DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus
XDG_RUNTIME_DIR=$RT" "re-scope: busctl talks to the runtime directory's bus"

src bash : 'echo "$$"' "$LIMIT4G" HOV_STACK_TOOL_SWAP_LIMIT=off
is_eq "$(props)" \
  "fail|6|PIDs|au|1|$(out)|MemoryMax|t|4294967296|TasksMax|t|18446744073709551615|CollectMode|s|inactive-or-failed|OOMPolicy|s|continue|Description|s|hov-stack capped tool command|0" \
  "re-scope: an off swap limit drops MemorySwapMax and the property count"
fresh /init.scope
src bash : 'echo "$$"' CLAUDE_CODE_TOOL_MEMORY_LIMIT=1.5G HOV_STACK_TOOL_SWAP_LIMIT=512MiB
has "$(props)" "MemoryMax|t|1610612736|" "re-scope: a fractional cap converts to bytes"
has "$(props)" "MemorySwapMax|t|536870912|" "re-scope: an explicit swap limit wins over the default"

fresh /init.scope
src bash 'set -- a b' 'echo "$#:$*"' "$LIMIT4G"
is_eq "$(called):$(out)" "yes:2:a b" "re-scope: the caller's positional parameters survive"
fresh /init.scope
src bash : 'declare -F _hov_tool_scope _hov_tool_size; compgen -v _ht_; compgen -v _hs_; echo end' "$LIMIT4G"
is_eq "$(out)" end "re-scope: no helper function or variable outlives the env file"
fresh /init.scope
src bash 'set -euo pipefail' 'echo after' "$LIMIT4G"
is_eq "$RC:$(out):$(err)" "0:after:" "re-scope: set -euo pipefail before sourcing still reaches the command"
fresh /init.scope
src bash 'unset XDG_RUNTIME_DIR; set -u' 'echo after' "$LIMIT4G"
is_eq "$RC:$(out)" "0:after" "re-scope: an unset runtime directory under set -u is not an error"
lacks "$(err)" unbound "re-scope: no unbound variable under set -u"
fresh /init.scope
printf '0::/init.scope' >"$PROC.init"
src bash : 'echo after' "$LIMIT4G"
is_eq "$(called)" yes "re-scope: a cgroup line without a trailing newline still counts"

# The move lands a few milliseconds after the reply; the shell waits up to 250 ms for it.
fresh /init.scope
src bash : 'echo after' "$LIMIT4G" FAKE_MODE=late
is_eq "$(out):$(err)" "after:" "re-scope: a move that lands 30 ms late is waited for, silently"
fresh /init.scope
t0=${EPOCHREALTIME/[.,]/}
src bash : 'echo after' "$LIMIT4G" FAKE_MODE=stay
waited=$(((${EPOCHREALTIME/[.,]/} - t0) / 1000))
is_eq "$(out)" after "re-scope: a move that never lands still runs the command"
has "$(err)" "did not take this shell within 250 ms" "re-scope: a move that never lands is reported"
if [ "$waited" -ge 200 ] && [ "$waited" -lt 3000 ]; then ok; else bad "re-scope: the wait is bounded near 250 ms (took ${waited} ms)"; fi

fresh /init.scope
src bash : 'echo after' "$LIMIT4G" FAKE_MODE=fail
is_eq "$RC:$(out)" "0:after" "re-scope: a failed busctl call still runs the command"
is_eq "$(wc -l <"$ERR" | tr -d ' ')" 1 "re-scope: a failed busctl call prints one stderr line"
has "$(err)" "busctl: Failed to start transient scope unit: Access denied" "re-scope: the line carries busctl's first error line"
fresh /init.scope
src bash 'set -euo pipefail' 'echo after' "$LIMIT4G" FAKE_MODE=fail
is_eq "$RC:$(out)" "0:after" "re-scope: a failed busctl call under set -e still runs the command"

# -- /init.scope: every reason not to move -------------------------------------------------
noop() { # noop MESSAGE [NAME=value...]: the shell is left where it is, silently
  local msg=$1
  shift
  src bash : 'echo after' "$@"
  is_eq "$RC:$(called):$(out):$(err)" "0:no:after:" "$msg"
}
fresh /init.scope
noop "no move: CLAUDE_CODE_TOOL_MEMORY_LIMIT unset"
noop "no move: CLAUDE_CODE_TOOL_MEMORY_LIMIT blank" 'CLAUDE_CODE_TOOL_MEMORY_LIMIT=  '
for word in 0 off OFF none false No; do
  noop "no move: CLAUDE_CODE_TOOL_MEMORY_LIMIT=$word" "CLAUDE_CODE_TOOL_MEMORY_LIMIT=$word"
done
for word in off 0 NO false none; do
  noop "no move: HOV_STACK_TOOL_RESCOPE=$word" "$LIMIT4G" "HOV_STACK_TOOL_RESCOPE=$word"
done
src bash : 'echo after' "$LIMIT4G" HOV_STACK_TOOL_RESCOPE=on
is_eq "$(called)" yes "re-scope: HOV_STACK_TOOL_RESCOPE=on is not an off word"
noop "no move: busctl is not installed" "$LIMIT4G" "HOV_STACK_TOOL_SCOPE_TEST_BUSCTL=$TMP/bin/nope"
noop "no move: no bus socket" "$LIMIT4G" "XDG_RUNTIME_DIR=$TMP/rt-nobus"
printf '8589934592\n' >"$ROOT/init.scope/memory.max"
noop "no move: init.scope already has a finite memory.max" "$LIMIT4G"
rm "$ROOT/init.scope/memory.max"
src bash : 'echo after' "$LIMIT4G"
is_eq "$(called)" yes "re-scope: an unreadable init.scope memory.max does not block the move"
for cg in /system.slice/cron.service "$USER_SVC/app.slice/foo.scope" /x/claude-code-bash/sub /x/claude-code-bash-2; do
  fresh "$cg"
  noop "no move: a shell in $cg is left alone" "$LIMIT4G"
done
fresh /init.scope
printf '1:name=systemd:/init.scope\n0::/init.scope\n' >"$PROC.init"
noop "no move: a hybrid cgroup hierarchy" "$LIMIT4G"
printf '12:memory:/init.scope\n' >"$PROC.init"
noop "no move: a cgroup v1 line" "$LIMIT4G"
: >"$PROC.init"
noop "no move: an empty cgroup file" "$LIMIT4G"
fresh /init.scope
rm "$ROOT/cgroup.controllers"
noop "no move: no unified hierarchy at the cgroup root" "$LIMIT4G"
fresh /init.scope
src dash : 'echo after' "$LIMIT4G"
is_eq "$RC:$(called):$(out):$(err)" "0:no:after:" "no move: a non-bash shell skips the prelude"

fresh /init.scope
src bash : 'echo after' CLAUDE_CODE_TOOL_MEMORY_LIMIT=lots
is_eq "$(called):$(out)" "no:after" "no move: a malformed CLAUDE_CODE_TOOL_MEMORY_LIMIT"
is_eq "$(wc -l <"$ERR" | tr -d ' ')" 1 "a malformed CLAUDE_CODE_TOOL_MEMORY_LIMIT prints one stderr line"
has "$(err)" "CLAUDE_CODE_TOOL_MEMORY_LIMIT is not a size" "the line names the malformed variable"

# -- the native claude-code-bash pool: its swap bound ---------------------------------------
pool 4294967296 max
src bash : 'echo after'
is_eq "$(swapmax):$(out):$(err)" "4294967296:after:" "pool: the swap bound defaults to the pool's RAM cap, silently"
pool 4294967296 4294967296
touch -d @946684800 "$POOL/memory.swap.max"
src bash : 'echo after'
is_eq "$(stat -c %Y "$POOL/memory.swap.max")" 946684800 "pool: an unchanged bound is not rewritten"
pool 4294967296 max
src bash : 'echo after' HOV_STACK_TOOL_SWAP_LIMIT=1G
is_eq "$(swapmax)" 1073741824 "pool: HOV_STACK_TOOL_SWAP_LIMIT sets the bound"
pool 4294967296 777
src bash : 'echo after' HOV_STACK_TOOL_SWAP_LIMIT=off
is_eq "$(swapmax):$(err)" "777:" "pool: an off word leaves the existing bound"
pool 4294967296 max
src bash : 'echo after' HOV_STACK_TOOL_SWAP_LIMIT=lots
is_eq "$(swapmax)" 4294967296 "pool: a malformed swap limit keeps the default"
has "$(err)" "HOV_STACK_TOOL_SWAP_LIMIT is not a size" "pool: a malformed swap limit is reported"
pool max 777
src bash : 'echo after'
is_eq "$(swapmax):$(err)" "777:" "pool: an uncapped pool is left alone"
pool 4294967296 max
src bash 'set -o noclobber' 'echo after'
is_eq "$(swapmax):$(out)" "4294967296:after" "pool: noclobber does not stop the write"
pool 4294967296 max
src bash 'set -euo pipefail' 'echo after' HOV_STACK_TOOL_RESCOPE=off CLAUDE_CODE_TOOL_MEMORY_LIMIT=off
is_eq "$(swapmax):$(out)" "4294967296:after" "pool: the bound does not depend on the move switches, and set -e still reaches the command"
if [ "$(id -u)" -ne 0 ]; then
  pool 4294967296 777
  chmod 444 "$POOL/memory.swap.max"
  src bash : 'echo after'
  is_eq "$(swapmax):$(out):$(err)" "777:after:" "pool: a read-only swap bound is left alone, silently"
else
  skip "pool: the read-only case needs a non-root user"
fi

# -- size grammar: the prelude reads every value the JS normalizer reads, the same way ------
# The heavy wrapper normalizes HOV_STACK_TOOL_SWAP_LIMIT with heavy-job-headroom.js; the pool
# write shows what the prelude made of the same value.
if command -v node >/dev/null 2>&1; then
  while IFS= read -r v; do
    v=${v//\\t/$'\t'}
    js=$(node "$HEADROOM" --normalize-swap-limit "$v" 4294967296 2>/dev/null)
    js_rc=$?
    pool 4294967296 max
    src bash : : "HOV_STACK_TOOL_SWAP_LIMIT=$v"
    if [ "$js_rc" -ne 0 ]; then
      want="4294967296:warn" # malformed: warn and keep the default
    elif [ -z "$js" ]; then
      want="max:" # an off word: no bound written
    else
      want="$js:"
    fi
    got="$(swapmax):"
    [ -s "$ERR" ] && got="${got}warn"
    is_eq "$got" "$want" "parity with heavy-job-headroom.js for '$v'"
  done <<'EOF'


4G
4g
4GB
4gib
4GiB
4 G
4 GB
 2g
\t1G\t
512M
512MiB
1.5G
1.05G
1.08G
2.009M
0.09k
0.5k
1k
1K
1024
1
4b
4ib
4 kib
08G
1.000001T
999999T
0
off
OFF
None
false
No
00
0.0001
lots
4X
-1
4.G
.5G
1..2G
4i
4gi
4bb
4 k ib
b
1e3
0x10
EOF
  # Two documented limits of shell arithmetic, where the prelude refuses what the JS reads:
  # more than six decimals, and a value past 2^63 bytes. Both warn and keep the default.
  for v in 1.1234567G 99999999T; do
    pool 4294967296 max
    src bash : : "HOV_STACK_TOOL_SWAP_LIMIT=$v"
    is_eq "$(swapmax)" 4294967296 "documented limit: '$v' keeps the default"
    has "$(err)" "not a size" "documented limit: '$v' is reported"
  done
else
  skip "size parity: node is not installed"
fi

# -- live: a real move out of /init.scope ---------------------------------------------------
LIVE_RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
case $LIVE_RT in /*) ;; *) LIVE_RT=/run/user/$(id -u) ;; esac
live_cg=$(bash -c 'read -r l </proc/self/cgroup; printf %s "$l"')
swap_free_kb=$(awk '$1 == "SwapFree:" { print $2 }' /proc/meminfo)
# live_env CMD [NAME=value...]: CMD in a clean bash that sourced the real claude-env.sh.
live_env() {
  local cmd=$1
  shift
  env -i HOME="$TMP/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$LIVE_RT" "$@" \
    timeout 120 bash -c '. "$1"; eval "$2"' _ "$ENVFILE" "$cmd"
}
ALLOC='python3 -c "b = bytearray(b\"\\x01\") * (200 << 20)"'
if [ "$live_cg" != 0::/init.scope ]; then
  skip "live re-scope: this shell is in ${live_cg#0::}, not /init.scope"
elif [ "$(cat /sys/fs/cgroup/init.scope/memory.max 2>/dev/null)" != max ]; then
  skip "live re-scope: init.scope already has a memory cap"
elif [ ! -S "$LIVE_RT/bus" ] || ! command -v busctl >/dev/null 2>&1; then
  skip "live re-scope: no user bus or no busctl"
else
  report='read -r cg </proc/self/cgroup; d=/sys/fs/cgroup${cg#0::}; printf "%s %s %s %s\n" "${cg##*/}" "$(cat "$d/memory.max")" "$(cat "$d/memory.swap.max")" "$(cat "$d/pids.max")"'
  got=$(live_env "$report" CLAUDE_CODE_TOOL_MEMORY_LIMIT=64M 2>"$ERR")
  case $got in
    "hov-tool-"*".scope 67108864 67108864 max") ok ;;
    *) bad "live re-scope: the shell moved into a 64M scope with swap bounded at 64M (got '$got')" ;;
  esac
  is_eq "$(err)" "" "live re-scope: silent"
  # The heavy wrapper, started from inside a moved shell, puts its command in its own scope
  # with the same cap and swap bound. It runs before the allocations below, whose swapping
  # would otherwise raise memory PSI enough for admission to defer it.
  if command -v node >/dev/null 2>&1; then
    got=$(live_env 'read -r o </proc/self/cgroup; echo "outer ${o##*/}"; bash "$HV_RUN" "$HV_NODE" "$HV_HEADROOM" "$HV_CMD"; echo "rc=$?"' \
      CLAUDE_CODE_TOOL_MEMORY_LIMIT=64M HV_RUN="$HEAVY_RUN" HV_NODE="$(command -v node)" \
      HV_HEADROOM="$HEADROOM" HV_CMD="$report" 2>"$ERR")
    if grep -qF 'admission deferred' "$ERR"; then
      skip "live nested heavy scope: admission deferred on host pressure ($(head -n 1 "$ERR"))"
    else
      outer=$(printf '%s\n' "$got" | sed -n 's/^outer //p')
      inner=$(printf '%s\n' "$got" | sed -n '2p')
      case $outer in hov-tool-*.scope) ok ;; *) bad "live nested heavy scope: the wrapper starts in a moved shell (got '$outer')" ;; esac
      case $inner in
        hov-tool-*) bad "live nested heavy scope: the heavy command has its own scope (got '$inner')" ;;
        *".scope 67108864 67108864 "*) ok ;;
        *) bad "live nested heavy scope: the heavy command runs in a 64M scope with swap bounded at 64M (got '$inner'; stderr '$(err)')" ;;
      esac
      has "$got" "rc=0" "live nested heavy scope: the wrapper exits 0"
    fi
  else
    skip "live nested heavy scope: node is not installed"
  fi
  got=$(live_env "$ALLOC; echo \"rc=\$?\"; read -r cg </proc/self/cgroup; grep -F oom_kill \"/sys/fs/cgroup\${cg#0::}/memory.events\"" \
    CLAUDE_CODE_TOOL_MEMORY_LIMIT=64M 2>/dev/null)
  has "$got" "rc=137" "live re-scope: 200M under a 64M cap and 64M of swap is killed"
  case $got in
    *"oom_kill 0"* | "") bad "live re-scope: the kill is the scope's own OOM kill (got '$got')" ;;
    *oom_kill*) ok ;;
  esac
  if [ "${swap_free_kb:-0}" -ge 1048576 ]; then
    got=$(live_env "$ALLOC; echo \"rc=\$?\"" CLAUDE_CODE_TOOL_MEMORY_LIMIT=64M HOV_STACK_TOOL_SWAP_LIMIT=off 2>/dev/null)
    is_eq "$got" "rc=0" "live re-scope control: with no swap bound the same allocation swaps and survives"
  else
    skip "live re-scope control: under 1 GiB of free swap"
  fi
fi

# -- live: the native pool's swap bound -----------------------------------------------------
cat >"$TMP/pool-run.sh" <<'EOF'
#!/bin/bash
# Inside a Delegate=yes service: build a claude-code-bash pool as Claude Code does, enter it as
# its MCP spawn path does, and source the env file there.
envfile=$1 swap=$2
read -r cg </proc/self/cgroup
d=/sys/fs/cgroup${cg#0::}
mkdir "$d/leader" && echo $$ >"$d/leader/cgroup.procs" || exit 3
echo +memory >"$d/cgroup.subtree_control" || exit 3
mkdir "$d/claude-code-bash" && echo 67108864 >"$d/claude-code-bash/memory.max" || exit 3
exec /bin/sh -c '{ echo 0 > "$0"/cgroup.procs; } 2>/dev/null; exec "$@"' "$d/claude-code-bash" \
  env -i HOME=/nonexistent PATH=/usr/bin:/bin HOV_STACK_TOOL_SWAP_LIMIT="$swap" bash -c '
    . "$1"
    read -r cg </proc/self/cgroup
    d=/sys/fs/cgroup${cg#0::}
    printf "%s swap.max=%s\n" "${cg##*/}" "$(cat "$d/memory.swap.max")"
    python3 -c "b = bytearray(b\"\\x01\") * (200 << 20)"
    printf "rc=%s\n" "$?"
    printf "swap.peak=%s\n" "$(cat "$d/memory.swap.peak" 2>/dev/null || echo none)"
  ' _ "$envfile"
EOF
user_run() {
  XDG_RUNTIME_DIR="$LIVE_RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$LIVE_RT/bus" \
    timeout 120 systemd-run --user --pipe --wait --quiet -p Delegate=yes "$@"
}
deleg=
if command -v systemd-run >/dev/null 2>&1 && [ -S "$LIVE_RT/bus" ]; then
  deleg=$(user_run /bin/bash -c 'read -r cg </proc/self/cgroup; cat "/sys/fs/cgroup${cg#0::}/cgroup.controllers"' 2>/dev/null </dev/null)
fi
case " $deleg " in
  *" memory "*)
    got=$(user_run /bin/bash "$TMP/pool-run.sh" "$ENVFILE" "" 2>&1 </dev/null)
    has "$got" "claude-code-bash swap.max=67108864" "live pool: the env file bounds the pool's swap at its RAM cap"
    has "$got" "rc=137" "live pool: 200M in a 64M pool with that bound is killed"
    peak=$(printf '%s\n' "$got" | sed -n 's/^swap\.peak=//p')
    case $peak in
      '' | none) skip "live pool: memory.swap.peak is not available" ;;
      *) if [ "$peak" -le 67108864 ]; then ok; else bad "live pool: swap stayed under the bound (peak $peak)"; fi ;;
    esac
    if [ "${swap_free_kb:-0}" -ge 1048576 ]; then
      got=$(user_run /bin/bash "$TMP/pool-run.sh" "$ENVFILE" off 2>&1 </dev/null)
      has "$got" "claude-code-bash swap.max=max" "live pool control: an off word leaves the pool's swap unbounded"
      has "$got" "rc=0" "live pool control: the same allocation swaps and survives"
    else
      skip "live pool control: under 1 GiB of free swap"
    fi
    ;;
  *) skip "live pool: no user manager that delegates the memory controller" ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "ok — claude-env tool scope: $pass/$((pass + fail)) assertions passed, $skipped skipped"
else
  echo "FAIL — claude-env tool scope: $fail of $((pass + fail)) assertions failed, $skipped skipped" >&2
  exit 1
fi
