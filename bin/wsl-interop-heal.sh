#!/bin/bash
# WSL interop healer: re-register the WSLInterop binfmt_misc entry (#1643)
#
# Windows .exe files run from WSL only because /init is registered as their
# binfmt_misc interpreter. On WSL kernels before 6.7 binfmt_misc is ONE
# kernel-global table, so any systemd that boots or stops with write access to
# it empties the table for every distro: a --privileged /sbin/init container
# (the install-smoke image did this on 2026-10-02) or a sibling systemd distro
# terminating (rancher-desktop#10049, microsoft/WSL#13885). WSL re-registers
# only at boot and when systemd-binfmt.service restarts, so the outage lasted
# four days, until someone ran that restart by hand.
#
# No-op unless: the kernel is WSL, /init exists, /etc/wsl.conf does not set
# [interop] enabled = false, and neither WSLInterop nor WSLInterop-late (the
# newer WSL name) is registered. Then it writes WSL's own registration line
# through `sudo -n tee` and checks that the entry appeared. It registers only
# the missing entry, so other handlers (qemu, python) are left alone.
#
# A heal is logged to $LOG and the journal and alerts nobody: nothing is left
# for the operator to do. A failed heal (sudo -n refused, binfmt_misc not
# mounted, the write left no entry) alerts through discord-notify.sh, at most
# once per $COOLDOWN seconds per outage. A failed send is not stamped, so the
# next run retries. Exit 0 healthy or healed, 1 heal failed. Anything it cannot
# log to $LOG goes to stderr, which the watchdog appends to its own log.
#
# Runs every 5 min from wsl-watchdog.sh's cron entry, before its memory-pressure
# early exit. WSL_INTEROP_* override every path for the hermetic test
# (tests/wsl-interop-heal.test.sh).

BINFMT_DIR="${WSL_INTEROP_BINFMT_DIR:-/proc/sys/fs/binfmt_misc}"
OSRELEASE="${WSL_INTEROP_OSRELEASE:-/proc/sys/kernel/osrelease}"
WSL_CONF="${WSL_INTEROP_WSL_CONF:-/etc/wsl.conf}"
INIT="${WSL_INTEROP_INIT:-/init}"
LOG="${WSL_INTEROP_LOG:-$HOME/.local/log/wsl-interop-heal.log}"
STATE_DIR="${WSL_INTEROP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wsl-interop-heal}"
# Where the cooldown stamp goes when $STATE_DIR cannot be written: a stamp that
# never persists would let a failing heal alert on every 5-minute run.
STATE_FALLBACK="${WSL_INTEROP_STATE_FALLBACK:-/tmp/wsl-interop-heal-$(id -u)}"
LOCK="${WSL_INTEROP_LOCK:-/tmp/wsl-interop-heal.lock}"
NOTIFY="${WSL_INTEROP_NOTIFY:-$HOME/.claude/scripts/discord-notify.sh}"
COOLDOWN="${WSL_INTEROP_ALERT_COOLDOWN:-21600}"
# WSL's own line (its systemd-binfmt generator override writes the same one):
# magic MZ, interpreter /init, flag P to keep argv[0].
LINE=':WSLInterop:M::MZ::/init:P'
STAMP="$STATE_DIR/alert.stamp"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*" >> "$LOG"; }
healthy() { [ -e "$BINFMT_DIR/WSLInterop" ] || [ -e "$BINFMT_DIR/WSLInterop-late" ]; }
clear_stamps() { rm -f "$STATE_DIR/alert.stamp" "$STATE_FALLBACK/alert.stamp"; }

grep -qi microsoft "$OSRELEASE" 2>/dev/null || exit 0
[ -e "$INIT" ] || exit 0
# The value of `enabled` inside [interop] only; other sections have their own.
interop_off=$(awk '
  /^[[:space:]]*\[/ { s = tolower($0); gsub(/[[:space:]]/, "", s); sect = s; next }
  sect == "[interop]" {
    l = tolower($0); sub(/#.*/, "", l); gsub(/[[:space:]]/, "", l)
    if (l == "enabled=false") off = 1
    else if (l == "enabled=true") off = 0
  }
  END { print off + 0 }' "$WSL_CONF" 2>/dev/null)
[ "$interop_off" = 1 ] && exit 0

if healthy; then
  clear_stamps
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
  logger -t wsl-interop-heal -p user.warning "state dir $STATE_DIR is not writable; keeping the alert cooldown in $STATE_FALLBACK"
  mkdir -p "$STATE_FALLBACK"
  STAMP="$STATE_FALLBACK/alert.stamp"
fi
# Single instance (cron overlap guard). A lock this user cannot open (another
# user's file in sticky /tmp, refused under fs.protected_regular) must not stop
# the heal for good: run unlocked, which risks only the EEXIST race below.
if { exec 9>"$LOCK"; } 2>/dev/null; then
  flock -n 9 || exit 0
else
  logger -t wsl-interop-heal -p user.warning "cannot open lock $LOCK; healing without it"
fi
# Another run, or WSL itself (WSLInterop-late), may have registered the entry
# since the check above; writing now would add a second handler.
if healthy; then
  clear_stamps
  exit 0
fi

found=$(find "$BINFMT_DIR" -mindepth 1 -maxdepth 1 ! -name register ! -name status -printf '%f ' 2>/dev/null)
found=${found% }
reason=""
if [ ! -e "$BINFMT_DIR/register" ]; then
  reason="binfmt_misc is not mounted at $BINFMT_DIR"
else
  err=$(printf '%s\n' "$LINE" | sudo -n tee "$BINFMT_DIR/register" 2>&1 >/dev/null)
  rc=$?
  if healthy; then
    log "HEALED: WSLInterop was missing (table held: ${found:-nothing}); registered '$LINE' (sudo rc=$rc)"
    logger -t wsl-interop-heal -p user.notice "re-registered missing WSLInterop binfmt entry (table held: ${found:-nothing})"
    clear_stamps
    exit 0
  fi
  reason="sudo -n tee rc=$rc: ${err:-the write reported success but no WSLInterop entry appeared}"
fi

log "FAILED: WSLInterop missing (table held: ${found:-nothing}) and not re-registered: $reason"
logger -t wsl-interop-heal -p user.err "WSLInterop binfmt entry missing and re-registration failed: $reason"

now=$(date +%s)
last=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
if [ "$last" -le "$now" ] && [ $((now - last)) -lt "$COOLDOWN" ]; then
  log "alert suppressed: one was sent $((now - last))s ago (cooldown ${COOLDOWN}s)"
  exit 1
fi
msg="WSL interop is down on $(hostname): the WSLInterop binfmt entry is missing and the 5-minute watchdog could not re-register it ($reason). Every Windows .exe fails with 'Exec format error' (toasts, open-deliverable, wezterm.exe) until it is back. Restore: sudo systemctl restart systemd-binfmt.service"
if "$NOTIFY" --title "WSL interop down" -- "$msg" >/dev/null 2>&1; then
  touch "$STAMP" 2>/dev/null ||
    logger -t wsl-interop-heal -p user.err "could not write the alert cooldown stamp $STAMP; the next run will alert again"
else
  log "alert send failed (rc=$?): will retry next run"
fi
exit 1
