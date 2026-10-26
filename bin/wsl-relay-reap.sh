#!/bin/bash
# WSL vsock relay reaper — continuous GC for microsoft/WSL#40650
#
# WSL leaks orphaned /init relay processes (interop/session bridges). Each pins
# ~6 sockets + an order-7 (512KB) VMBus ring buffer that is UNMOVABLE — kernel
# compaction cannot reclaim it. Enough leaked relays and every new WSL session
# or interop call dies with "UtilAcceptVsock: accept4 failed 110" while existing
# sessions keep working. This hit a full outage on 2026-08-03 (615 orphans,
# 987 vsocks, zero free order-7 blocks; WezTerm panes open-and-close).
#
# A relay is reaped ONLY if ALL guards pass, re-checked live per PID
# (validated 2026-08-03: adversarial verify + 525 kills, zero collateral):
#   1. cmdline is exactly "/init"
#   2. ppid == 1 (orphaned)
#   3. zero children
#   4. no /run/WSL/<pid>_interop socket — LITERAL filename check, never an fd
#      scan (all relays hold an fd to the shared 2_interop listener)
#   5. session leader dead (no /proc/<sid>)
#   6. older than MIN_AGE seconds (default 600)
#
# SIGKILL is required: relays set SIG_IGN on SIGTERM (SigIgn bit 14).
# Runs every 5 min from wsl-watchdog.sh's cron entry. DRY_RUN=1 to preview.

LOG="${HOME}/.local/log/wsl-relay-reap.log"
mkdir -p "$(dirname "$LOG")"
MIN_AGE="${MIN_AGE:-600}"
DRY_RUN="${DRY_RUN:-0}"
WARN_THRESHOLD=200   # leak-rate alarm: this many orphans in <MIN_AGE*2 means a hot leaker

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Single instance (cron overlap guard)
exec 9>/tmp/wsl-relay-reap.lock
flock -n 9 || exit 0

order7() { awk -v z="$1" '$0 ~ z {print $12}' /proc/buddyinfo; }

is_candidate() {
    local p=$1 stat rest sid age
    [ -d "/proc/$p" ] || return 1
    [ "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | sed 's/ *$//')" = "/init" ] || return 1
    stat=$(cat "/proc/$p/stat" 2>/dev/null) || return 1
    rest=${stat#*') '}
    # shellcheck disable=SC2086
    set -- $rest                          # $1=state $2=ppid $3=pgrp $4=session
    [ "$2" = "1" ] || return 1
    [ -z "$(pgrep -P "$p" 2>/dev/null)" ] || return 1
    [ ! -S "/run/WSL/${p}_interop" ] || return 1
    [ ! -d "/proc/$4" ] || return 1
    age=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$age" ] && [ "$age" -ge "$MIN_AGE" ] || return 1
    return 0
}

# Enumerate orphaned relays, then apply full guards per PID.
# comm is exactly "Relay" for leaked ones; live session relays name themselves
# "Relay(<pid>)" — the exact match excludes them before the guards even run.
mapfile -t cands < <(
    ps -eo pid=,ppid=,comm= 2>/dev/null \
        | awk '$2 == 1 && $3 == "Relay" {print $1}' \
        | while read -r p; do is_candidate "$p" && echo "$p"; done
)

n=${#cands[@]}
[ "$n" -eq 0 ] && exit 0

if [ "$n" -ge "$WARN_THRESHOLD" ]; then
    echo "$(ts) WARN: $n orphaned relays pending — something is leaking interop sessions fast" >> "$LOG"
    logger -t wsl-relay-reap -p user.warning "$n orphaned WSL relays pending reap (leak-rate alarm)"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "$(ts) DRY-RUN: would reap $n relays: ${cands[*]:0:20}..." >> "$LOG"
    echo "would reap $n relays"
    exit 0
fi

killed=0
for p in "${cands[@]}"; do
    is_candidate "$p" || continue         # atomic re-check at kill time (TOCTOU)
    sudo -n kill -KILL "$p" 2>/dev/null && killed=$((killed+1))
    (( killed % 50 == 0 )) && sleep 1     # gentle on the interop subsystem
done

sleep 1
o7d=$(order7 DMA32); o7n=$(order7 Normal)
vs=$(ss --vsock 2>/dev/null | grep -c ESTAB)
echo "$(ts) REAPED: $killed/$n relays | order7 DMA32=$o7d Normal=$o7n | vsock=$vs" >> "$LOG"

# If we reaped and order-7 is still exhausted, fragmentation has another cause
if [ "$killed" -gt 0 ] && [ "${o7d:-0}" -eq 0 ] && [ "${o7n:-0}" -eq 0 ]; then
    echo "$(ts) ALERT: order-7 still exhausted after reap — investigate before interop dies" >> "$LOG"
    logger -t wsl-relay-reap -p user.err "order-7 blocks still exhausted after relay reap"
fi
exit 0
