#!/usr/bin/env bash
# group-timeout.sh: a drop-in for `timeout [-k|--kill-after=GRACE] SECS CMD...` that bounds
# the command's whole process group, so a descendant that outlives the command cannot hold
# a pipe open (`out=$(group_timeout ...)` returns on time) or keep running afterwards.
#
# Why not plain `timeout`: GNU coreutils sends both the TERM and the kill-after KILL to the
# command's process group. uutils coreutils 0.10 (the `timeout` on Ubuntu 26.04) delivers
# the TERM to the group but the KILL to the command alone, so a descendant that ignores
# TERM survives the kill-after and holds the caller's stdout open until it ends (#450;
# measured on ubuntu:24.04 with GNU 9.4 and ubuntu:26.04 with uutils 0.10.0).
#
# group_timeout [-k GRACE | --kill-after=GRACE | --kill-after GRACE] SECS CMD [ARG...]
#   SECS and GRACE take what `timeout` takes: a non-negative number as strtod reads it
#   (5, 2.5, .5, 1e2, inf) with an optional s, m, h or d suffix. 0 disables that limit.
#   exit: the command's own status; 124 when SECS elapsed (whatever status the command
#   chose on TERM, as `timeout` reports); 137 when the grace elapsed and the group had to
#   be killed; 125 without running the command for an invalid duration or a missing
#   command, and 125 after stopping it if the deadline timer itself failed.
#   Without setsid (not Linux), falls back to `timeout`.
group_timeout() {
  local grace='' kill_after=0 secs secs_ms grace_ms=0 secs_arg ticks='' pid watcher ready rc=0 fired
  # Read here: in the arguments of a backgrounded command, $BASHPID is the child's own pid.
  local caller=$BASHPID
  while [ $# -gt 0 ]; do
    case "$1" in
      -k | --kill-after)
        [ $# -ge 2 ] || { echo 'group_timeout: missing operand' >&2; return 125; }
        grace=$2; kill_after=1; shift 2 ;;
      --kill-after=*) grace=${1#--kill-after=}; kill_after=1; shift ;;
      *) break ;;
    esac
  done
  [ $# -ge 2 ] || { echo 'group_timeout: missing operand' >&2; return 125; }
  secs=$1; shift
  # Refuse a bad duration before anything starts, as `timeout` does. Checked later, a bad
  # duration would leave the command running with no deadline at all.
  if ! _group_timeout_ms secs_ms "$secs"; then
    printf "group_timeout: invalid time interval '%s'\n" "$secs" >&2; return 125
  fi
  if [ "$kill_after" = 1 ] && ! _group_timeout_ms grace_ms "$grace"; then
    printf "group_timeout: invalid time interval '%s'\n" "$grace" >&2; return 125
  fi
  if ! command -v setsid >/dev/null 2>&1; then
    if [ "$kill_after" = 1 ]; then timeout --kill-after="$grace" "$secs" "$@"; else timeout "$secs" "$@"; fi
    return
  fi
  # As with `timeout`, a zero (or unbounded) SECS sets no deadline, and a zero (or
  # unbounded) GRACE sends no KILL. Otherwise the grace is counted in tenths, rounded up.
  case "$secs_ms" in 0 | inf) "$@"; return ;; esac
  case "$grace_ms" in 0 | inf) ;; *) ticks=$(((grace_ms + 99) / 100)) ;; esac
  printf -v secs_arg '%d.%03d' $((secs_ms / 1000)) $((secs_ms % 1000))
  fired=$(mktemp "${TMPDIR:-/tmp}/group-timeout.XXXXXX") || return 125
  # setsid makes the command a session and group leader (pgid == pid) so one signal
  # reaches every descendant; <&0 keeps the caller's stdin (a bare & would use /dev/null).
  setsid "$@" <&0 &
  pid=$!
  # The deadline gets a session of its own too. Left in the caller's process group, it
  # would die with the caller when something cancels that group (an enclosing timeout, a
  # Ctrl-C), while the command, safe in its own session, ran on with no deadline at all.
  # Plain `timeout` keeps a process group of its own for the same reason.
  # The watcher writes its pid on the pipe once its TERM trap is set, and the pipe ends
  # when it exits. It is never signalled before that line: until it execs it is a fork of
  # this shell, and bash runs this shell's EXIT trap in a fork that a signal kills (or drops
  # the signal, leaving the deadline to run out). #509's CI saw the test's `rm -rf` run so.
  exec {ready}< <(exec setsid "$BASH" -c "$(declare -f _group_timeout_watch)"'
_group_timeout_watch "$@"' group-timeout "$secs_arg" "$ticks" "$pid" "$fired" "$caller" \
    2>/dev/null </dev/null)
  wait "$pid" || rc=$?
  # Once the command is gone a pending grace still runs out (it reaps stragglers); an
  # unfired watcher is stopped.
  if [ ! -e "$fired.term" ] && read -r -u "$ready" watcher; then kill "$watcher" 2>/dev/null; fi
  while read -r -u "$ready" _; do :; done
  exec {ready}<&-
  if [ -e "$fired.err" ]; then
    echo 'group_timeout: the deadline timer failed, so the command was stopped' >&2
    rc=125
  elif [ -e "$fired.kill" ]; then
    rc=137
  elif [ -e "$fired.term" ]; then
    # As `timeout` without --preserve-status: once SECS elapsed the answer is 124, whatever
    # status a TERM handler chose on the way out. red-first reads 124/137 as unresolved; a
    # handler's `exit 1` must not read as a genuine failure.
    rc=124
  fi
  rm -f "$fired" "$fired.term" "$fired.kill" "$fired.err"
  return "$rc"
}

# _group_timeout_ms VAR DURATION: set VAR to DURATION in whole milliseconds, or to "inf"
# when it is too long to count; fail for anything `timeout` rejects.
_group_timeout_ms() {
  local d=$2 mult=1 n
  case "$d" in
    *s) d=${d%s} ;;
    *m) d=${d%m}; mult=60 ;;
    *h) d=${d%h}; mult=3600 ;;
    *d) d=${d%d}; mult=86400 ;;
  esac
  [ -n "$d" ] || return 1
  LC_ALL=C printf -v n '%.3f' "$d" 2>/dev/null || return 1
  case "$n" in
    -* | *nan*) return 1 ;;
    # inf, or past about 30 years: no limit.
    *[!0-9.]* | ??????????????*) printf -v "$1" '%s' inf ;;
    *) n=${n/./}; printf -v "$1" '%s' "$((10#$n * mult))" ;;
  esac
}

# _group_timeout_watch SECS TICKS PID FIRED CALLER: the deadline for one group_timeout call,
# run in its own session (see group_timeout). TICKS is the grace in tenths, empty for none.
_group_timeout_watch() {
  local secs=$1 ticks=$2 pid=$3 fired=$4 caller=$5 s=''
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  # A cancelled caller has closed the pipe; writing to it must not end the deadline.
  trap '' PIPE
  sleep "$secs" >/dev/null & s=$!
  # Safe to signal from here (see group_timeout).
  echo "$$"
  # A timer that fails must not leave the command unbounded: record it and stop the group.
  wait "$s" || : >"$fired.err"
  # Firing: a late stop from group_timeout must not cut the grace short.
  trap '' TERM
  : >"$fired.term"
  kill -TERM -- "-$pid" 2>/dev/null
  if [ -n "$ticks" ]; then
    # Give the whole group the grace to leave, then kill whatever remains.
    while kill -0 -- "-$pid" 2>/dev/null; do
      [ "$ticks" -gt 0 ] || { : >"$fired.kill"; kill -KILL -- "-$pid" 2>/dev/null; break; }
      ticks=$((ticks - 1)); sleep 0.1
    done
  fi
  # A cancelled caller cannot remove its scratch files; remove them here.
  kill -0 "$caller" 2>/dev/null || rm -f "$fired" "$fired.term" "$fired.kill" "$fired.err"
}
