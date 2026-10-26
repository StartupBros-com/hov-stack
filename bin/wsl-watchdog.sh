#!/bin/bash
# WSL Memory Watchdog v8
#
# ALWAYS (every run, no pressure threshold):
#   - Kill orphaned dev servers (parent dead = agent crashed/finished)
#
# Tiered response (memory PRESSURE — kernel PSI, not swap fill; see below):
#   Tier 1 (PSI full avg60 >= PSI_FULL_PCT, or MemAvailable < AVAIL_MIN_PCT):
#   kill leaky dev servers >4GB + forensic logging
#   Also: orphaned Claude + MCP processes (from an IDE or terminal crash)
#
# ORPHANS, NOT ZOMBIES — these are opposite problems and this script only does
# the first. An ORPHAN is alive, has ppid=1 because its parent died, and is
# holding real RAM: killable, and worth gigabytes. A ZOMBIE has already exited
# and is a ~200-byte exit-status receipt its parent never collected: it holds no
# memory, and signals to it are discarded, so `kill` here would be a no-op. Do
# not extend this script to "reap zombies" — that is not something any script
# can do. Only the parent calling wait(), or the parent exiting, clears one.
# Container zombies (Supabase health-check probes reparented to a non-init
# PID 1) are handled by recycling their container: scripts/docker-hygiene.sh.

HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
LOG="${HOME}/.local/log/wsl-watchdog.log"
mkdir -p "$(dirname "$LOG")"
# Tier-1 gates. PSI_FULL_PCT: share of the last minute in which EVERY runnable
# task was stalled on memory (5 = three seconds of full stall per minute, which
# is the box visibly thrashing). AVAIL_MIN_PCT: MemAvailable floor for kernels
# without PSI.
PSI_FULL_PCT="${PSI_FULL_PCT:-5}"
AVAIL_MIN_PCT="${AVAIL_MIN_PCT:-5}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# === ALWAYS: Kill orphaned processes (ppid=1 means parent died) ===
# When the host IDE or terminal crashes, Claude Code + its 18 MCP servers become
# orphans. (Measured against the Antigravity IDE, retired 2026-08-07; the ppid=1
# mechanism below is generic and fires for any parent, so this stayed useful.)
# ~2 GB of live, still-resident orphans per crash. This catches them within 5
# minutes. Note the ppid=1 test is the HOST pid namespace, so a process orphaned
# inside a container is invisible here by construction, not by oversight.
ps -eo pid,ppid,rss,etimes,comm --no-headers 2>/dev/null \
    | awk '$2 == 1 && ($5 == "claude" || $5 == "next-server" || $5 ~ /next.*start/)' \
    | while read -r pid ppid rss etimes comm; do
        rss_mb=$(( rss / 1024 ))
        echo "$(ts) KILL-ORPHAN($comm): pid=$pid rss=${rss_mb}MB up=${etimes}s" >> "$LOG"
        kill "$pid" 2>/dev/null
    done
# Orphaned MCP servers (npm exec) whose parent is dead
ps -eo pid,ppid,args --no-headers 2>/dev/null \
    | awk '$2 == 1' \
    | grep -E 'npm exec.*(mcp|shadcn|stripe|magicui|supabase|posthog|sentry|chrome-devtools|lighthouse|browsermcp|context7|fetch|vercel|discord|youtube|seo|grafana|google)' \
    | while read -r pid ppid args; do
        rss=$(ps -p "$pid" -o rss --no-headers 2>/dev/null | tr -d ' ')
        rss_mb=$(( ${rss:-0} / 1024 ))
        name=$(echo "$args" | head -c 80)
        echo "$(ts) KILL-ORPHAN(mcp): pid=$pid rss=${rss_mb}MB cmd=$name" >> "$LOG"
        kill "$pid" 2>/dev/null
    done

# === ALWAYS: Reap leaked WSL vsock relays (microsoft/WSL#40650) ===
# Orphaned /init relays pin unmovable order-7 VMBus ring buffers; enough of
# them and every NEW WSL session/interop call dies with "accept4 failed 110"
# while existing sessions keep working (2026-08-03 outage: 615 orphans, WezTerm
# panes open-and-close, git push hangs). Guards + SIGKILL live in the reaper.
"$HERE/wsl-relay-reap.sh" 2>/dev/null

# === ALWAYS: Re-register WSL interop if binfmt_misc was flushed (#1643) ===
# A privileged systemd container or a sibling distro stopping empties the
# kernel-global binfmt_misc table; every .exe then fails with "Exec format
# error" until WSLInterop is registered again (2026-10-02: four days down).
# Guards, sudo and the failure alert live in the healer. Its stderr lands here,
# so a failure it could not write to its own log still leaves a trace.
"$HERE/wsl-interop-heal.sh" 2>>"$LOG"

# === Pressure check — exit early unless the kernel reports a memory stall ===
# The trigger is PSI, the kernel's own stall accounting: /proc/pressure/memory
# "full avg60" is the share of the last minute in which EVERY runnable task was
# blocked on memory (reclaim, swap-in, compaction) — what the box actually
# feels. The previous trigger was swap-used%, which measures how much swap is
# CONFIGURED, not pressure: on 2026-09-16 a stale 48 GB scratch swapfile had
# inflated SwapTotal to 84 GB, so 18 GB in swap read as 21% and the 85% gate
# was unreachable while the host was paging. PSI does not move when someone
# adds a swap device. MemAvailable is the secondary gate for the no-PSI case.
psi_full=$(awk '/^full/ { sub("avg60=", "", $3); print $3 }' /proc/pressure/memory 2>/dev/null)
psi_full=${psi_full:-0}
mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
swap_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
avail_pct=$(( mem_avail * 100 / mem_total ))
psi_hot=$(awk -v v="$psi_full" -v t="$PSI_FULL_PCT" 'BEGIN { print (v + 0 >= t + 0) ? 1 : 0 }')

[ "$psi_hot" = 0 ] && [ "$avail_pct" -ge "$AVAIL_MIN_PCT" ] && exit 0

mem_used_gb=$(awk "BEGIN {printf \"%.1f\", ($mem_total - $mem_avail) / 1048576}")
swap_used_gb=$(awk "BEGIN {printf \"%.1f\", ($swap_total - $swap_free) / 1048576}")

echo "$(ts) WARN: psi_full60=${psi_full}% mem_avail=${avail_pct}% ram_used=${mem_used_gb}GB swap_used=${swap_used_gb}GB" >> "$LOG"

# === FORENSICS: dump top 15 processes by RSS ===
echo "$(ts) TOP-PROCS:" >> "$LOG"
ps -eo pid,rss,comm --no-headers 2>/dev/null \
    | awk '$2 > 51200 {printf "  pid=%-8s rss=%dMB cmd=%s\n", $1, $2/1024, $3}' \
    | sort -t= -k2 -rn \
    | head -15 >> "$LOG"

# === TIER 1 (memory pressure): Kill leaky processes >4GB ===
ps -eo pid,rss,args --no-headers 2>/dev/null \
    | awk '$2 > 4194304' \
    | grep -E 'next-server|astro.*dev|webpack-dev-server|vite.*dev|opencode' \
    | while read -r pid rss args; do
        rss_gb=$(awk "BEGIN {printf \"%.1f\", $rss / 1048576}")
        name=$(echo "$args" | head -c 80)
        echo "$(ts) KILL-T1(leaked>4GB): pid=$pid rss=${rss_gb}GB cmd=$name" >> "$LOG"
        kill "$pid"
    done

# Claude Code is NEVER killed by the watchdog. User manages their own sessions.

# Post-action status
sleep 2
psi_full_after=$(awk '/^full/ { sub("avg60=", "", $3); print $3 }' /proc/pressure/memory 2>/dev/null)
mem_avail_after=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
avail_pct_after=$(( mem_avail_after * 100 / mem_total ))
echo "$(ts) POST: psi_full60=${psi_full_after:-0}% mem_avail=${avail_pct_after}%" >> "$LOG"
