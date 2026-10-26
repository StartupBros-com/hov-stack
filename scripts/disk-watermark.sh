#!/usr/bin/env bash
# disk-watermark — alerts when a filesystem crosses a disk-fill watermark.
#
# WHY THIS EXISTS (2026-08-21 emergency-reset incident)
# The WSL drive filled up and forced the operator into an emergency reset.
# Every existing hygiene timer (wt-sweep, reclaim-sweep, docker-hygiene,
# pkg-cache-prune) watches its own domain — worktrees, package caches, docker
# images — but none of them watches the disk itself, the actual resource
# that ran out. This is that watch.
#
# Checks `/` (the WSL rootfs) and `/mnt/c` (the WSL VHD's host drive) — the
# two filesystems whose fill level actually caused the 2026-08-21 incident.
# `/` is itself a file living on the `/mnt/c` VHD, so a box can run out of
# room on the HOST drive while `/` still reports headroom; checking only `/`
# would have missed the real incident. DISK_WATERMARK_PATHS overrides the
# checked set (space-separated), mainly so tests can point this at fixture
# directories instead of real mountpoints.
#
#   WARN_PCT=85      % used at or above this -> WARN.
#   CRIT_PCT=92      % used at or above this -> CRIT.
#   MIN_FREE_GB=40   free-space floor in GB; breaching it -> CRIT regardless
#                    of % used, because a large disk can sit under CRIT_PCT
#                    with only a few GB left (the exact shape of the
#                    2026-08-21 incident), while a small, nearly-full disk
#                    can breach CRIT_PCT with plenty of GB still free. Either
#                    condition alone is a real emergency, so the floor is
#                    checked independently of the percentage thresholds.
#
# Breaching EITHER the %-used threshold OR the free-GB floor is a breach for
# that filesystem. Any breach: exit 1 (systemd failed-unit = visibility, same
# pattern as any failed-unit page) and ONE notify.sh call (not one per
# filesystem) summarizing every breach found this run — same invocation shape
# as pkg-cache-prune.sh's failure path (`$HERE/notify.sh "$msg" input`). This
# deliberately does not invent a new notification channel.
set -uo pipefail

WARN_PCT="${WARN_PCT:-85}"
CRIT_PCT="${CRIT_PCT:-92}"
MIN_FREE_GB="${MIN_FREE_GB:-40}"
FILESYSTEMS="${DISK_WATERMARK_PATHS:-/ /mnt/c}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
say() { [ -x "$HERE/notify.sh" ] && "$HERE/notify.sh" "$1" "${2:-default}" >/dev/null 2>&1; return 0; }

n_checked=0
n_flagged=0
BREACHES=""

for fs in $FILESYSTEMS; do
  if [ ! -d "$fs" ]; then
    echo "disk-watermark: $fs — not present on this host, skipping"
    continue
  fi

  # df -P: POSIX output format, always exactly one line per filesystem (the
  # default format wraps a long device name onto a second line, which would
  # break the positional read below). -k: 1024-byte blocks, so the GB math
  # here is exact and locale-independent — no -h suffix to parse.
  line=$(df -Pk "$fs" 2>/dev/null | tail -n1)
  if [ -z "$line" ]; then
    echo "disk-watermark: $fs — df failed, cannot evaluate"
    continue
  fi
  n_checked=$((n_checked + 1))

  # Filesystem 1024-blocks Used Available Capacity Mounted-on
  read -r _ _ _ avail_kb pct_str _ <<< "$line"
  pct=${pct_str%\%}
  case "$pct" in
    ''|*[!0-9]*) echo "disk-watermark: $fs — unparseable df output: $line"; continue ;;
  esac
  case "$avail_kb" in
    ''|*[!0-9]*) echo "disk-watermark: $fs — unparseable df output: $line"; continue ;;
  esac
  avail_gb=$(( avail_kb / 1024 / 1024 ))

  state=OK
  floor_breach=0
  if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then floor_breach=1; fi
  if [ "$pct" -ge "$CRIT_PCT" ] || [ "$floor_breach" -eq 1 ]; then
    state=CRIT
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    state=WARN
  fi

  echo "disk-watermark: $fs — ${pct}% used, ${avail_gb}GB free — $state"

  if [ "$state" != OK ]; then
    n_flagged=$((n_flagged + 1))
    reason="${pct}% used (WARN_PCT=$WARN_PCT CRIT_PCT=$CRIT_PCT)"
    [ "$floor_breach" -eq 1 ] && reason="$reason, ${avail_gb}GB free < ${MIN_FREE_GB}GB floor"
    BREACHES="${BREACHES}${fs}: $state — $reason"$'\n'
  fi
done

if [ "$n_flagged" -gt 0 ]; then
  echo
  echo "disk-watermark: $n_flagged of $n_checked filesystem(s) breached a watermark"
  printf '%s' "$BREACHES"
  echo "reclaim levers: docker-hygiene.sh, wt-sweep.sh, pkg-cache-prune.sh, or find the fattest directories with:"
  echo "  du -x --max-depth=2 ~ | sort -h | tail"
  say "disk-watermark: $n_flagged filesystem(s) breached a disk watermark — $(printf '%s' "$BREACHES" | tr '\n' ' ')" input
fi

echo "disk-watermark-flagged:$n_flagged"
[ "$n_flagged" -eq 0 ] && exit 0
exit 1
