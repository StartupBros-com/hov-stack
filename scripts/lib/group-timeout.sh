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
#   exit: the command's own status; 124 when SECS elapsed (whatever status the command
#   chose on TERM, as `timeout` reports); 137 when the grace elapsed and the group had to
#   be killed. SECS and GRACE accept the
#   fractions and `s` suffix `timeout` accepts. Without setsid (not Linux), falls back to
#   `timeout`.
group_timeout() {
  local grace='' secs pid watcher rc=0 fired
  while [ $# -gt 0 ]; do
    case "$1" in
      -k) grace=$2; shift 2 ;;
      --kill-after=*) grace=${1#--kill-after=}; shift ;;
      --kill-after) grace=$2; shift 2 ;;
      *) break ;;
    esac
  done
  secs=$1; shift
  grace=${grace%s}; secs=${secs%s}
  case "$grace" in 0 | 0.0) grace='' ;; esac
  if ! command -v setsid >/dev/null 2>&1; then
    if [ -n "$grace" ]; then timeout --kill-after="$grace" "$secs" "$@"; else timeout "$secs" "$@"; fi
    return
  fi
  fired=$(mktemp "${TMPDIR:-/tmp}/group-timeout.XXXXXX") || return 125
  # setsid makes the command a session and group leader (pgid == pid) so one signal
  # reaches every descendant; <&0 keeps the caller's stdin (a bare & would use /dev/null).
  setsid "$@" <&0 &
  pid=$!
  (
    sleep "$secs" & s=$!
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    wait "$s" || exit 0
    : >"$fired.term"
    kill -TERM -- "-$pid" 2>/dev/null
    [ -n "$grace" ] || exit 0
    # Give the whole group the grace to leave, then kill whatever remains.
    whole=${grace%%.*}; tenth=0
    case "$grace" in *.*) tenth=${grace#*.}; tenth=${tenth:0:1} ;; esac
    ticks=$((10#${whole:-0} * 10 + 10#${tenth:-0}))
    while kill -0 -- "-$pid" 2>/dev/null; do
      [ "$ticks" -gt 0 ] || { : >"$fired.kill"; kill -KILL -- "-$pid" 2>/dev/null; break; }
      ticks=$((ticks - 1)); sleep 0.1
    done
  ) >/dev/null 2>&1 </dev/null &
  watcher=$!
  wait "$pid" || rc=$?
  # Once the command is gone a pending grace still runs out (it reaps stragglers); an
  # unfired watcher is stopped.
  if [ ! -e "$fired.term" ]; then kill "$watcher" 2>/dev/null; fi
  wait "$watcher" 2>/dev/null || true
  if [ -e "$fired.kill" ]; then
    rc=137
  elif [ -e "$fired.term" ]; then
    # As `timeout` without --preserve-status: once SECS elapsed the answer is 124, whatever
    # status a TERM handler chose on the way out. red-first reads 124/137 as unresolved; a
    # handler's `exit 1` must not read as a genuine failure.
    rc=124
  fi
  rm -f "$fired" "$fired.term" "$fired.kill"
  return "$rc"
}
