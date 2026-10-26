#!/usr/bin/env bash
# cass-index-rebuild.sh — full lexical rebuild, bounded so it survives this host.
#
# WHY THIS EXISTS
# A full `cass index --full` on the workstation archive (~31k conversations, ~15 GiB
# agent_search.db, 2.6M docs) peaked at 24.5 GiB RSS with stock settings and was
# killed four times across 2026-09-08..10 before completing. The values below are
# what actually worked, at 14.1 GiB peak. They are not guesses.
#
# THE THREE FAILURE MODES, in the order they bit:
#
# 1. Kernel OOM. 2026-09-08: anon-rss 22.4 GiB / total-vm 52.6 GiB, killed while
#    swap was exhausted. Only one of the four kills was a true kernel OOM.
#
# 2. earlyoom. Runs as `-m 6,3 -s 6,3`: SIGTERM to the largest non-avoided
#    process once available RAM *and* free swap are BOTH under 6%. cass is always
#    the fattest process here, so it is the default target. It killed a run at
#    "mem avail: 0.00%, swap free: 5.82%" — a fifth of a percent under the line.
#    It sends SIGTERM, not SIGKILL, so NOTHING appears in dmesg. Its receipts are
#    in the journal, and `journalctl -u earlyoom` shows nothing useful without
#    sudo: an unprivileged journalctl silently hides other users' and system
#    units' messages, which is how three kills looked causeless for two days.
#
# 3. The agent harness. BASH_MAX_TIMEOUT_MS is 1800000 (30 min) and applies to
#    background tasks too, so `run_in_background` is NOT detached — two runs died
#    at ~29 min with last_error:null and were misread as memory failures. This
#    script must be launched detached; see USAGE.
#
# SWAP IS THE REAL LEVER. 20 of this host's 36 GiB of swap was zram — compressed
# RAM, which competes for the memory cass needs rather than relieving it. Adding
# 48 GiB of *disk* swap took total free swap far above earlyoom's 6% floor, so its
# kill condition could not be met, WITHOUT disabling the guard. Fix the resource,
# not the safety net.
#
# USAGE (detached — do not run this straight from an agent Bash call):
#   setsid nohup bash ~/.claude/scripts/cass-index-rebuild.sh \
#     > /tmp/cass-rebuild-$(date +%s)/index.log 2>&1 < /dev/null &
#
# Expect 90+ minutes. Watch with `cass status --json`, not by tailing the log.
set -u

# --- memory bounds ----------------------------------------------------------
# Halved from a first attempt that still reached 19.4 GiB. Every value is an
# upstream-documented env var; see src/indexer/ in the cass tree.

# Caps the single biggest previously-unbounded allocation: the in-memory buffer
# for one concat-merge fold output, which used to scale with the WHOLE lexical
# index (upstream measured 1,605 segments folded into one 6.75 GB file).
# Added upstream 2026-09-08 for GH#456/#457; default 1 GiB.
export CASS_LEXICAL_MERGE_MAX_OUTPUT_BYTES=${CASS_LEXICAL_MERGE_MAX_OUTPUT_BYTES:-134217728}   # 128 MiB

# Hard ceiling on producer-side in-flight bytes, applied even at full governor
# capacity. Default computes to available_memory/32 clamped [512MiB,16GiB],
# i.e. ~600 MB on a 20 GB host.
export CASS_RESPONSIVENESS_MAX_INFLIGHT_BYTES=${CASS_RESPONSIVENESS_MAX_INFLIGHT_BYTES:-134217728}  # 128 MiB

# One live Tantivy writer heap at a time. The default is memory-aware and
# already floors to 1 on a 20 GB host; set explicitly so a bigger machine does
# not silently raise it mid-incident.
export CASS_TANTIVY_REBUILD_STAGED_SHARD_BUILDERS=${CASS_TANTIVY_REBUILD_STAGED_SHARD_BUILDERS:-1}

# Writer heap is ~128 MB per thread.
export CASS_TANTIVY_MAX_WRITER_THREADS=${CASS_TANTIVY_MAX_WRITER_THREADS:-1}

# How much raw message content one shard's writer accumulates before flush.
export CASS_TANTIVY_REBUILD_STAGED_SHARD_MAX_MESSAGE_BYTES=${CASS_TANTIVY_REBUILD_STAGED_SHARD_MAX_MESSAGE_BYTES:-16777216}  # 16 MiB

# Stops one outlier conversation (image/base64-heavy) from forcing an
# OOM -> bisect -> quarantine cycle. Upstream default 8 MiB.
export CASS_LEXICAL_MAX_CONVERSATION_CONTENT_BYTES=${CASS_LEXICAL_MAX_CONVERSATION_CONTENT_BYTES:-4194304}  # 4 MiB

# The live admission controller re-reads /proc/meminfo MemAvailable and throttles
# concurrent shard builds in real time. Raised above stock so cass PAUSES while
# headroom is thin instead of consuming the last of RAM — which is what let the
# host collapse (loadavg 919, journald SIGABRT) on the first attempt.
export CASS_TANTIVY_REBUILD_STAGED_SHARD_BUILD_MEMORY_RESERVE_BYTES=${CASS_TANTIVY_REBUILD_STAGED_SHARD_BUILD_MEMORY_RESERVE_BYTES:-6442450944}        # 6 GiB
export CASS_TANTIVY_REBUILD_STAGED_SHARD_BUILD_EMERGENCY_MEMORY_RESERVE_BYTES=${CASS_TANTIVY_REBUILD_STAGED_SHARD_BUILD_EMERGENCY_MEMORY_RESERVE_BYTES:-3221225472}  # 3 GiB

# --- preflight --------------------------------------------------------------
printf '=== cass-index-rebuild %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cass --version 2>&1 | head -1
free -m | head -3
printf -- '--- swap devices (zram is compressed RAM, not offload) ---\n'
swapon --show 2>/dev/null || true

# earlyoom needs BOTH conditions; ample free swap alone keeps it disarmed.
swap_free_mb=$(free -m | awk '/^Swap:/ {print $4}')
swap_total_mb=$(free -m | awk '/^Swap:/ {print $2}')
if [ "${swap_total_mb:-0}" -gt 0 ]; then
  pct=$(( swap_free_mb * 100 / swap_total_mb ))
  printf -- '--- free swap: %s MB of %s MB (%s%%) ---\n' "$swap_free_mb" "$swap_total_mb" "$pct"
  if [ "$pct" -lt 20 ]; then
    printf 'WARN: free swap under 20%%. earlyoom SIGTERMs the largest process once\n'
    printf '      RAM and swap are both under 6%%, and that is this job. Consider\n'
    printf '      adding disk swap before continuing:\n'
    printf '        sudo fallocate -l 48G /swapfile-cass && sudo chmod 600 /swapfile-cass\n'
    printf '        sudo mkswap /swapfile-cass && sudo swapon --priority -1 /swapfile-cass\n'
  fi
fi

if pgrep -x cass >/dev/null 2>&1; then
  printf 'REFUSING: a cass process is already running; a second index run would contend for the lock.\n'
  pgrep -a cass | head -3
  exit 1
fi

printf '=== starting: cass index --full --json ===\n'
exec cass index --full --json
