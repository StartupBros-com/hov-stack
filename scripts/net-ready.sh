#!/usr/bin/env bash
# net-ready.sh: bounded network-readiness wait for systemd --user units.
#
# WHY: `After=network-online.target` plus `Wants=network-online.target` order
# nothing in the user manager. The target belongs to the system manager; in
# user scope it is LoadState=not-found (workstation, 2026-09-28), so a Persistent=true
# catch-up at login started a unit's script before connectivity, the exact
# race the two lines were written for. Twelve units carried the dead pair
# (dotfiles#1458, found by pro-gate on #1455 for the since-retired claim-reap.service).
#
# This is the user-scope replacement, wired per unit as
#   ExecStartPre=-%h/.claude/scripts/net-ready.sh --wait 300 --url https://api.github.com/
# It probes the host the unit is about to use every --interval seconds for
# up to --wait seconds and exits 0 as soon as one HTTP exchange completes
# (any status code: a 403 or a 404 still proves the path to that host is
# up). Two bounds keep the wait honest (pro-gate on #1465 reproduced both
# failures against the first version):
#   - Each attempt gets --attempt-timeout seconds (default 20) or the time
#     left, whichever is shorter. Giving one attempt all the time left let a
#     single stalled connection on a half-up link spend the whole wait while
#     fresh connections already worked.
#   - The deadline runs on /proc/uptime, which never steps backward, not on
#     `date +%s`. A backward wall-clock step (an NTP or WSL clock resync)
#     inflated the time left past --wait.
# A success that lands on the deadline is not accepted. On the deadline it
# prints a column-0 WARN and exits 1.
#
# The leading `-` in the unit is the contract: systemd ignores this exit
# status, so the unit's own script always runs and keeps its existing
# failure behaviour (a nonzero exit still pages through OnFailure=, a
# deliberate skip still exits 0). The probe adds only "wait for the network
# first, within a budget"; it never decides the run's outcome. ExecStartPre=
# time counts against TimeoutStartSec=, so each unit adds --wait to the
# budget its script had: tests/systemd-network-online.test.sh pins
# each unit's wait to at most half of its TimeoutStartSec.
#
# The one exit that is not a probe result is 3 (curl or timeout missing, or
# /proc/uptime unreadable): nothing was probed, the WARN says so, and the `-`
# prefix lets the script run as it would have without a probe.
#
# Usage: net-ready.sh --url URL [--wait SECONDS] [--interval SECONDS]
#                     [--attempt-timeout SECONDS]
# Exit: 0 reachable · 1 unreachable for the whole wait · 2 usage
#       · 3 curl, timeout or the uptime clock unavailable (nothing probed)
set -uo pipefail

WAIT=300
INTERVAL=15
ATTEMPT=20
URL=""
CLOCK=/proc/uptime

usage() {
  echo "usage: net-ready.sh --url URL [--wait SECONDS] [--interval SECONDS] [--attempt-timeout SECONDS]" >&2
  exit 2
}

is_positive_int() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

while [ $# -gt 0 ]; do
  case $1 in
    --url)             [ $# -ge 2 ] || usage; URL=$2; shift 2 ;;
    --wait)            [ $# -ge 2 ] || usage; WAIT=$2; shift 2 ;;
    --interval)        [ $# -ge 2 ] || usage; INTERVAL=$2; shift 2 ;;
    --attempt-timeout) [ $# -ge 2 ] || usage; ATTEMPT=$2; shift 2 ;;
    *) echo "net-ready: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$URL" ] || usage
is_positive_int "$WAIT" || { echo "net-ready: --wait must be a positive integer, got '$WAIT'" >&2; exit 2; }
is_positive_int "$INTERVAL" || { echo "net-ready: --interval must be a positive integer, got '$INTERVAL'" >&2; exit 2; }
is_positive_int "$ATTEMPT" || { echo "net-ready: --attempt-timeout must be a positive integer, got '$ATTEMPT'" >&2; exit 2; }
# Validation admits leading zeros, and bash arithmetic would read 08 as an
# invalid octal constant (the probe aborts before its first attempt) and
# 010 as 8 (pro-gate round 2 on #1465). Pin base 10 before any arithmetic.
WAIT=$((10#$WAIT))
INTERVAL=$((10#$INTERVAL))
ATTEMPT=$((10#$ATTEMPT))

for tool in curl timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "WARN net-ready: $tool not on PATH; nothing probed for $URL"
    exit 3
  fi
done

# now: whole seconds since boot into NOW, from a clock that never steps
# backward. The read is a builtin, so the probe needs no extra tool.
now() {
  local up rest
  read -r up rest < "$CLOCK" || return 1
  NOW=${up%%.*}
  case $NOW in
    ''|*[!0-9]*) return 1 ;;
  esac
}

if ! now 2>/dev/null; then
  echo "WARN net-ready: $CLOCK unreadable; nothing probed for $URL"
  exit 3
fi
start=$NOW
deadline=$(( start + WAIT ))
attempt=0
last_err=""
late=0
while now; do
  left=$(( deadline - NOW ))
  [ "$left" -gt 0 ] || break
  budget=$ATTEMPT
  if [ "$left" -lt "$budget" ]; then
    budget=$left
  fi
  attempt=$(( attempt + 1 ))
  # -sS: no progress bar, errors still reported. Any HTTP response is a
  # success (no -f): the question is whether the host is reachable, not
  # whether an unauthenticated GET of / is welcome there.
  if last_err=$(timeout -k 2 "$budget" curl -sS -o /dev/null --max-time "$budget" "$URL" 2>&1); then
    now || break
    if [ "$NOW" -lt "$deadline" ]; then
      if [ "$attempt" -gt 1 ]; then
        echo "net-ready: $URL reachable after $(( NOW - start ))s (attempt $attempt)"
      fi
      exit 0
    fi
    late=1
    break
  fi
  now || break
  left=$(( deadline - NOW ))
  [ "$left" -gt 0 ] || break
  # Sleep the interval or what remains, whichever is shorter.
  if [ "$INTERVAL" -lt "$left" ]; then
    sleep "$INTERVAL"
  else
    sleep "$left"
  fi
done
if [ "$late" -eq 1 ]; then
  echo "WARN net-ready: $URL answered only at the ${WAIT}s deadline ($attempt attempt(s)); a success that lands on the deadline is not accepted"
  exit 1
fi
last_err=$(printf '%s' "$last_err" | tr '\n' ' ' | cut -c1-200)
echo "WARN net-ready: $URL unreachable for ${WAIT}s ($attempt attempt(s); last error: ${last_err:-none})"
exit 1
