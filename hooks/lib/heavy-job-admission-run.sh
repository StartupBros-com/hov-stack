#!/usr/bin/env bash
# heavy-job-admission-run.sh <node> <headroom-script> <command>
#
# The admission wrapper that heavy-job-admission.js used to inline into the
# rewritten Bash command. It lives in a file because Claude Code's
# worktree-isolation verifier refuses any command text carrying `$( )` in
# argument position, and the inline preamble carried six of them -- so in an
# isolated session every command the gate ADMITTED became un-runnable, the
# agent saw a refusal naming the wrapper's substitutions instead of its own
# command, and retried (dotfiles #864: 312 refusals in one day, 27 deep in one
# session). A script run by absolute path is never parsed internally (measured
# in harness/worktree-command-shapes.md and re-probed 2026-09-02 with
# quoted operands as arguments). The wrapper retains the original fail-closed
# tool resolution, user-owned 0700 runtime directory, lock guards, and
# process-group drain; an enabled native memory-limit value also puts only the
# admitted command in a transient user scope with a finite MemoryMax.
#
# Runner-generated exit 75 means failed closed / deferred. An admitted command's
# own exit 75 is preserved unchanged.

__claude_heavy_fail() { echo "heavy-job admission failed closed: $1" >&2; exit 75; }
[ "$#" -eq 3 ] || __claude_heavy_fail "usage: heavy-job-admission-run.sh <node> <headroom-script> <command>"
__claude_heavy_node=$1
__claude_heavy_headroom=$2
__claude_heavy_cmd=$3

__claude_heavy_flock="$(type -P flock)"
__claude_heavy_bash="$(type -P bash)"
__claude_heavy_setsid="$(type -P setsid)"
__claude_heavy_sleep="$(type -P sleep)"
__claude_heavy_stat="$(type -P stat)"
__claude_heavy_id="$(type -P id)"
__claude_heavy_ps="$(type -P ps)"
__claude_heavy_systemd_run="$(type -P systemd-run)"
for __claude_heavy_tool in "$__claude_heavy_flock" "$__claude_heavy_bash" "$__claude_heavy_setsid" "$__claude_heavy_sleep" "$__claude_heavy_stat" "$__claude_heavy_id" "$__claude_heavy_ps"; do
  [ -x "$__claude_heavy_tool" ] || __claude_heavy_fail "required admission executable is unavailable"
done
__claude_heavy_uid="$("$__claude_heavy_id" -u)" || __claude_heavy_fail "cannot resolve uid"
__claude_heavy_runtime_safe() {
  [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] \
    && [ "$("$__claude_heavy_stat" -c %u -- "$1" 2>/dev/null)" = "$__claude_heavy_uid" ] \
    && [ "$("$__claude_heavy_stat" -c %a -- "$1" 2>/dev/null)" = 700 ]
}
if [ "${CLAUDE_HEAVY_JOB_TEST_MODE:-0}" = 1 ]; then
  __claude_heavy_runtime=${CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR:-}
else
  __claude_heavy_runtime=${XDG_RUNTIME_DIR:-}
  __claude_heavy_runtime_safe "$__claude_heavy_runtime" || __claude_heavy_runtime="/run/user/$__claude_heavy_uid"
fi
__claude_heavy_runtime_safe "$__claude_heavy_runtime" || __claude_heavy_fail "runtime directory must be a real user-owned 0700 directory"
__claude_heavy_lock="$__claude_heavy_runtime/claude-heavy-job-admission.lock"
[ ! -L "$__claude_heavy_lock" ] || __claude_heavy_fail "unsafe lock symlink"
if [ -e "$__claude_heavy_lock" ]; then
  [ -f "$__claude_heavy_lock" ] && [ "$("$__claude_heavy_stat" -c %u -- "$__claude_heavy_lock" 2>/dev/null)" = "$__claude_heavy_uid" ] || __claude_heavy_fail "unsafe lock target"
fi
umask 077

# One Bash supervisor owns the lock and the workload lifetime. Signals become
# pending state before admission starts, then TERM is forwarded only after the
# setsid workload's process-group identity has been observed. The lock and stdin
# use separate dynamic descriptors; the child bootstrap closes both extras.
__claude_heavy_cancel_pending=0
__claude_heavy_cancel_status=143
__claude_heavy_cancel_generation=0
__claude_heavy_child=
__claude_heavy_pgid=
__claude_heavy_cancel() {
  if [ "$__claude_heavy_cancel_pending" -eq 0 ]; then
    __claude_heavy_cancel_status=$1
  fi
  __claude_heavy_cancel_pending=1
  ((__claude_heavy_cancel_generation++)) || true
  if [ -n "$__claude_heavy_pgid" ]; then
    builtin kill -TERM -- "-$__claude_heavy_pgid" 2>/dev/null || true
  fi
}
trap '__claude_heavy_cancel 129' HUP
trap '__claude_heavy_cancel 130' INT
trap '__claude_heavy_cancel 143' TERM

exec {__claude_heavy_lock_fd}>"$__claude_heavy_lock" || __claude_heavy_fail "cannot open lock target"
[ -f "$__claude_heavy_lock" ] && [ "$("$__claude_heavy_stat" -c %u -- "$__claude_heavy_lock" 2>/dev/null)" = "$__claude_heavy_uid" ] || __claude_heavy_fail "unsafe lock target"
"$__claude_heavy_flock" -n -E 200 "$__claude_heavy_lock_fd"
__claude_heavy_lock_status=$?
[ "$__claude_heavy_cancel_pending" -eq 0 ] || exit "$__claude_heavy_cancel_status"
if [ "$__claude_heavy_lock_status" -eq 200 ]; then
  echo "heavy-job admission deferred: another heavy job is already running; retry after it finishes" >&2
  exit 75
fi
[ "$__claude_heavy_lock_status" -eq 0 ] || __claude_heavy_fail "lock acquisition failed"

"$__claude_heavy_node" "$__claude_heavy_headroom"
__claude_heavy_headroom_status=$?
[ "$__claude_heavy_cancel_pending" -eq 0 ] || exit "$__claude_heavy_cancel_status"
[ "$__claude_heavy_headroom_status" -eq 0 ] || exit 75
export TURBO_CONCURRENCY=1
__claude_heavy_limit="$("$__claude_heavy_node" "$__claude_heavy_headroom" --normalize-memory-limit "${CLAUDE_CODE_TOOL_MEMORY_LIMIT-}")"
__claude_heavy_limit_status=$?
[ "$__claude_heavy_cancel_pending" -eq 0 ] || exit "$__claude_heavy_cancel_status"
[ "$__claude_heavy_limit_status" -eq 0 ] || exit 75
exec {__claude_heavy_stdin_fd}<&0 || __claude_heavy_fail "cannot preserve command stdin"
[ "$__claude_heavy_cancel_pending" -eq 0 ] || exit "$__claude_heavy_cancel_status"

__claude_heavy_direct_bootstrap='builtin kill -STOP "$BASHPID"; exec "$1" -c "$2"'
__claude_heavy_scoped_bootstrap='builtin kill -STOP "$BASHPID"; exec "$1" --user --scope --quiet --collect --property "$2" -- "$3" -c "$4"'
if [ -n "$__claude_heavy_limit" ]; then
  [ -x "$__claude_heavy_systemd_run" ] || __claude_heavy_fail "systemd-run is required for the configured memory limit"
  [ "$__claude_heavy_cancel_pending" -eq 0 ] || exit "$__claude_heavy_cancel_status"
  (
    exec {__claude_heavy_lock_fd}>&-
    exec "$__claude_heavy_setsid" "$__claude_heavy_bash" -c "$__claude_heavy_scoped_bootstrap" claude-heavy-bootstrap "$__claude_heavy_systemd_run" "MemoryMax=$__claude_heavy_limit" "$__claude_heavy_bash" "$__claude_heavy_cmd" <&"$__claude_heavy_stdin_fd" {__claude_heavy_stdin_fd}<&-
  ) &
else
  [ "$__claude_heavy_cancel_pending" -eq 0 ] || exit "$__claude_heavy_cancel_status"
  (
    exec {__claude_heavy_lock_fd}>&-
    exec "$__claude_heavy_setsid" "$__claude_heavy_bash" -c "$__claude_heavy_direct_bootstrap" claude-heavy-bootstrap "$__claude_heavy_bash" "$__claude_heavy_cmd" <&"$__claude_heavy_stdin_fd" {__claude_heavy_stdin_fd}<&-
  ) &
fi
__claude_heavy_child=$!
exec {__claude_heavy_stdin_fd}<&-

# The bootstrap stops itself only after setsid has established the owned group.
# Require both facts before acknowledging readiness; PGID alone can be visible
# before STOP, where an early CONT would be lost and strand the workload. Bound
# the observation loop so an early setsid failure cannot poll forever.
__claude_heavy_observation_failed=0
for ((__claude_heavy_attempt = 0; __claude_heavy_attempt < 200; __claude_heavy_attempt++)); do
  __claude_heavy_identity="$("$__claude_heavy_ps" -o stat= -o ppid= -o pgid= -p "$__claude_heavy_child")"
  __claude_heavy_ps_status=$?
  if [ "$__claude_heavy_ps_status" -ne 0 ] || [ -z "$__claude_heavy_identity" ]; then
    if builtin kill -0 "$__claude_heavy_child" 2>/dev/null; then
      __claude_heavy_observation_failed=1
    fi
    break
  fi
  read -r __claude_heavy_state __claude_heavy_parent __claude_heavy_observed_pgid <<<"$__claude_heavy_identity"
  if [ "$__claude_heavy_parent" != "$$" ]; then
    break
  fi
  if [ "$__claude_heavy_observed_pgid" = "$__claude_heavy_child" ] && [[ $__claude_heavy_state == T* ]]; then
    __claude_heavy_pgid=$__claude_heavy_observed_pgid
    break
  fi
  case $__claude_heavy_state in
    Z*) break ;;
  esac
  "$__claude_heavy_sleep" 0.01
done

if [ "$__claude_heavy_observation_failed" -ne 0 ]; then
  builtin kill -TERM "$__claude_heavy_child" 2>/dev/null || true
  builtin kill -CONT "$__claude_heavy_child" 2>/dev/null || true
  builtin wait "$__claude_heavy_child" || true
  __claude_heavy_fail "cannot inspect workload process identity"
elif [ -n "$__claude_heavy_pgid" ]; then
  if [ "$__claude_heavy_cancel_pending" -ne 0 ]; then
    builtin kill -TERM -- "-$__claude_heavy_pgid" 2>/dev/null || true
  fi
  builtin kill -CONT -- "-$__claude_heavy_pgid" 2>/dev/null || true
else
  __claude_heavy_identity="$("$__claude_heavy_ps" -o stat= -o ppid= -p "$__claude_heavy_child")"
  __claude_heavy_ps_status=$?
  if [ "$__claude_heavy_ps_status" -ne 0 ]; then
    if builtin kill -0 "$__claude_heavy_child" 2>/dev/null; then
      builtin kill -TERM "$__claude_heavy_child" 2>/dev/null || true
      builtin kill -CONT "$__claude_heavy_child" 2>/dev/null || true
      builtin wait "$__claude_heavy_child" || true
      __claude_heavy_fail "cannot inspect workload process identity"
    fi
  elif [ -n "$__claude_heavy_identity" ]; then
    read -r __claude_heavy_state __claude_heavy_parent <<<"$__claude_heavy_identity"
    if [ "$__claude_heavy_parent" = "$$" ] && [[ $__claude_heavy_state != Z* ]]; then
      builtin kill -TERM "$__claude_heavy_child" 2>/dev/null || true
      builtin kill -CONT "$__claude_heavy_child" 2>/dev/null || true
      builtin wait "$__claude_heavy_child" || true
      __claude_heavy_fail "cannot establish owned workload process group"
    fi
  fi
fi

# A signal trap interrupts wait before the child has necessarily exited. Repeat
# when a trap ran during that wait so the child's actual final status wins over
# the interrupted status (for example, a TERM handler that exits 42).
__claude_heavy_status=0
while :; do
  __claude_heavy_wait_generation=$__claude_heavy_cancel_generation
  builtin wait "$__claude_heavy_child"
  __claude_heavy_wait_status=$?
  if [ "$__claude_heavy_cancel_generation" -ne "$__claude_heavy_wait_generation" ]; then
    continue
  fi
  __claude_heavy_status=$__claude_heavy_wait_status
  break
done

while [ -n "$__claude_heavy_pgid" ] && builtin kill -0 -- "-$__claude_heavy_pgid" 2>/dev/null; do
  "$__claude_heavy_sleep" 0.05
done
exit "$__claude_heavy_status"
