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
# that filesystem.
#
# ALERT ONLY WHEN IT GETS WORSE (hov-stack#644). The timer runs hourly, so a
# breach that sits still would otherwise toast every hour and train the
# operator to ignore it. A breached filesystem alerts when:
#   - it was not in breach at the last run (or its state file is unreadable),
#   - its level rose (WARN -> CRIT),
#   - it fell below the MIN_FREE_GB floor for the first time, or
#   - it has DISK_WATERMARK_STEP_GB (10) GB less free than at its last alert,
#     or half as much free when that comes sooner, so a nearly full disk
#     keeps alerting on its way to zero.
# Otherwise the run prints a `suppressed` line for it and does not notify.
# Only free space that recovers by the step changes the record: it moves the
# baseline up and lowers the remembered level and floor flag, and a filesystem
# back under every watermark with that much recovered loses its record, so
# its next breach is new. A disk hovering at a watermark or at the floor
# (39 GB, 41 GB, 39 GB) therefore alerts once, not on every crossing.
# State lives in one small file per filesystem under
# DISK_WATERMARK_STATE_DIR (default ~/.local/state/hov-stack/disk-watermark).
# If that cannot be written, every breach alerts, as before.
#
# A run that alerted exits 1 (systemd failed-unit = visibility) and makes ONE
# notify.sh call (not one per filesystem) summarizing what alerted — same
# invocation shape as pkg-cache-prune.sh's failure path
# (`$HERE/notify.sh "$msg" input`). A run with only suppressed breaches exits
# 0, so an hourly timer does not mark the unit failed every hour.
#
# A RUN THAT COULD NOT DO ITS JOB EXITS 2 (dotfiles#1999), never 0 or 1, and
# prints disk-watermark-errors:N:
#   - df failed or printed something unparseable for a filesystem that exists,
#     or no filesystem could be checked at all: an unknown fill level is not a
#     healthy one;
#   - an alert was due but not delivered: notify.sh is missing or returned
#     non-zero. Its stderr is kept for the journal, and the alert records are
#     written only after a delivery, so the next run alerts again.
# Exit 2 outranks exit 1: a run that alerted on one filesystem and could not
# read another still exits 2.
set -uo pipefail

WARN_PCT="${WARN_PCT:-85}"
CRIT_PCT="${CRIT_PCT:-92}"
MIN_FREE_GB="${MIN_FREE_GB:-40}"
STEP_GB="${DISK_WATERMARK_STEP_GB:-10}"
FILESYSTEMS="${DISK_WATERMARK_PATHS:-/ /mnt/c}"
STATE_DIR="${DISK_WATERMARK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hov-stack/disk-watermark}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# send <message> <sound>: notify.sh's own status, 127 when it is missing. Its
# stderr goes to the journal with this script's.
send() {
  [ -x "$HERE/notify.sh" ] || { echo "disk-watermark: no notifier at $HERE/notify.sh"; return 127; }
  "$HERE/notify.sh" "$1" "${2:-default}" >/dev/null
}

level_name() { case "$1" in 2) echo CRIT ;; 1) echo WARN ;; *) echo OK ;; esac; }

# state_file <fs>: one file per filesystem, named after its path.
state_file() { printf '%s/fs%s' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }

# write_state <file> <level> <floor> <avail_gb>: atomic; 1 when it cannot.
write_state() {
  local tmp="$1.tmp.$$"
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s %s %s\n' "$2" "$3" "$4" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$1" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

n_checked=0
n_flagged=0
n_alerted=0
n_suppressed=0
n_errors=0
state_failed=0
BREACHES=""
# Alert records to write once the alert is delivered: file, level, floor, GB.
P_SF=() P_LV=() P_FL=() P_AV=()

for fs in $FILESYSTEMS; do
  if [ ! -d "$fs" ]; then
    echo "disk-watermark: $fs — not present on this host, skipping"
    continue
  fi

  # df -P: POSIX output format, always exactly one line per filesystem (the
  # default format wraps a long device name onto a second line, which would
  # break the positional read below). -k: 1024-byte blocks, so the GB math
  # here is exact and locale-independent — no -h suffix to parse. df's stderr
  # is not captured, so it reaches the journal; pipefail makes df_rc df's own.
  line=$(df -Pk "$fs" | tail -n1); df_rc=$?
  if [ "$df_rc" -ne 0 ] || [ -z "$line" ]; then
    echo "disk-watermark: $fs — df failed (exit $df_rc), cannot evaluate"
    n_errors=$((n_errors + 1))
    continue
  fi

  # Filesystem 1024-blocks Used Available Capacity Mounted-on
  read -r _ _ _ avail_kb pct_str _ <<< "$line"
  pct=${pct_str%\%}
  parsed=1
  case "$pct" in ''|*[!0-9]*) parsed=0 ;; esac
  case "$avail_kb" in ''|*[!0-9]*) parsed=0 ;; esac
  if [ "$parsed" -eq 0 ]; then
    echo "disk-watermark: $fs — unparseable df output, cannot evaluate: $line"
    n_errors=$((n_errors + 1))
    continue
  fi
  n_checked=$((n_checked + 1))
  avail_gb=$(( avail_kb / 1024 / 1024 ))

  state=OK
  level=0
  floor_breach=0
  if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then floor_breach=1; fi
  if [ "$pct" -ge "$CRIT_PCT" ] || [ "$floor_breach" -eq 1 ]; then
    state=CRIT; level=2
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    state=WARN; level=1
  fi

  echo "disk-watermark: $fs — ${pct}% used, ${avail_gb}GB free — $state"

  # Last alert's level, floor flag and free GB. have: 0 no record, 1 a
  # readable one, 2 an unreadable one.
  sf=$(state_file "$fs")
  have=0 p_level="" p_floor="" p_avail="" p_extra=""
  if [ -e "$sf" ]; then
    have=2
    read -r p_level p_floor p_avail p_extra 2>/dev/null <"$sf"
    case "$p_level:$p_floor:$p_avail:$p_extra" in
      [012]:[01]:[0-9]*:) case "$p_avail" in *[!0-9]*) ;; *) have=1 ;; esac ;;
    esac
  fi

  if [ "$state" = OK ]; then
    if [ "$have" -eq 1 ] && [ "$avail_gb" -lt $(( p_avail + STEP_GB )) ]; then
      echo "disk-watermark: $fs — under every watermark; its last alert stands until $(( p_avail + STEP_GB ))GB free"
    else
      rm -f "$sf" 2>/dev/null
    fi
    continue
  fi
  n_flagged=$((n_flagged + 1))

  why=""
  [ "$have" -eq 0 ] && why="new breach"
  [ "$have" -eq 2 ] && why="state file unreadable"
  if [ -z "$why" ]; then
    # Alerts again at STEP_GB less free, or at half as much free if sooner.
    next=$(( p_avail - STEP_GB ))
    [ $(( p_avail / 2 )) -gt "$next" ] && next=$(( p_avail / 2 ))
    if [ "$level" -gt "$p_level" ]; then
      why="rose from $(level_name "$p_level") to $state"
    elif [ "$floor_breach" -eq 1 ] && [ "$p_floor" -eq 0 ]; then
      why="fell below the ${MIN_FREE_GB}GB floor"
    elif [ "$avail_gb" -le "$next" ]; then
      why="free space fell from ${p_avail}GB to ${avail_gb}GB since the last alert"
    fi
  fi

  if [ -z "$why" ]; then
    n_suppressed=$((n_suppressed + 1))
    echo "disk-watermark: $fs — suppressed: no worse than at the last alert (${p_avail}GB free then; alerts again at ${next}GB free or a higher level)"
    # Only a recovery by the step rewrites the record (see the header).
    if [ "$avail_gb" -ge $(( p_avail + STEP_GB )) ]; then
      write_state "$sf" "$level" "$floor_breach" "$avail_gb" || state_failed=1
    fi
    continue
  fi

  n_alerted=$((n_alerted + 1))
  P_SF+=("$sf") P_LV+=("$level") P_FL+=("$floor_breach") P_AV+=("$avail_gb")
  reason="${pct}% used (WARN_PCT=$WARN_PCT CRIT_PCT=$CRIT_PCT)"
  [ "$floor_breach" -eq 1 ] && reason="$reason, ${avail_gb}GB free < ${MIN_FREE_GB}GB floor"
  BREACHES="${BREACHES}${fs}: $state — $reason ($why)"$'\n'
done

if [ "$n_checked" -eq 0 ] && [ "$n_errors" -eq 0 ]; then
  echo "disk-watermark: no filesystem in '$FILESYSTEMS' could be checked"
  n_errors=1
fi

if [ "$n_alerted" -gt 0 ]; then
  echo
  echo "disk-watermark: $n_alerted of $n_checked filesystem(s) breached a watermark or got worse"
  printf '%s' "$BREACHES"
  echo "reclaim levers: docker-hygiene.sh, wt-sweep.sh, pkg-cache-prune.sh, or find the fattest directories with:"
  echo "  du -x --max-depth=2 ~ | sort -h | tail"
  # du also counts files hard-linked from outside a tree (uv and pnpm caches,
  # their venvs and node_modules), so its figure overstates what deleting the
  # tree frees: docs/solutions/best-practices/du-overstates-what-deleting-a-hard-linked-tree-frees.md
  echo "du counts files hard-linked from elsewhere too; size what deleting DIR frees by its single-link bytes (a floor):"
  printf '%s\n' "  find DIR -xdev -type f -links 1 -printf '%b\n' | awk '{s+=\$1} END {printf \"%.2f GiB\n\", s*512/2^30}'"
  send "disk-watermark: $n_alerted filesystem(s) breached a disk watermark or got worse — $(printf '%s' "$BREACHES" | tr '\n' ' ')" input
  send_rc=$?
  if [ "$send_rc" -eq 0 ]; then
    for i in "${!P_SF[@]}"; do
      write_state "${P_SF[$i]}" "${P_LV[$i]}" "${P_FL[$i]}" "${P_AV[$i]}" || state_failed=1
    done
  else
    echo "disk-watermark: the alert was not delivered (notifier exit $send_rc); no alert recorded, so the next run alerts again"
    n_errors=$((n_errors + 1))
  fi
fi
[ "$n_suppressed" -gt 0 ] && echo "disk-watermark: $n_suppressed breach(es) no worse than at their last alert; not alerted again"

if [ "$state_failed" -eq 1 ]; then
  echo "disk-watermark: cannot keep alert state in $STATE_DIR; every breach alerts until it can"
fi

echo "disk-watermark-flagged:$n_flagged"
echo "disk-watermark-alerted:$n_alerted"
echo "disk-watermark-errors:$n_errors"
[ "$n_errors" -gt 0 ] && exit 2
[ "$n_alerted" -eq 0 ] && exit 0
exit 1
