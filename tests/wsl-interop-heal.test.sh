#!/usr/bin/env bash
# Hermetic tests for bin/wsl-interop-heal.sh (issue #1643).
#
# On WSL kernels before 6.7 binfmt_misc is one kernel-global table. A systemd
# booting or stopping anywhere on the kernel (the install-smoke --privileged
# /sbin/init container on 2026-10-02, or a sibling distro terminating) empties
# it, and every Windows .exe then fails with "Exec format error" until the
# WSLInterop entry is registered again. The healer runs from wsl-watchdog.sh's
# 5-minute cron and re-registers it.
#
# Nothing real is touched: WSL_INTEROP_* points every path at a temp tree, and
# PATH stubs stand in for `sudo` (acting as the kernel: it creates the entry
# named in the registration line), `logger` and the Discord notifier.
#
# Planted negatives:
#  - case 2: only WSLInterop-late exists (newer WSL's name). A healer that
#    tests WSLInterop alone registers a duplicate; this must write nothing.
#  - case 3: the exact line, flags P. `PF`, or no flags, fails here.
#  - case 9 vs 10: `[interop] enabled = false` must skip the heal, and the
#    near-identical `enabled = true` (case 10) must still heal, as must
#    `enabled = false` under another section (case 11).
#  - case 7: a sudo that exits 0 but registers nothing must take the failure
#    path; a healer that trusts the exit status reports success.
#  - case 5: a second failing run inside the cooldown must not alert again.
#  - every stub records its calls, so a stub never invoked cannot make an
#    "it did not alert" assertion pass on a healer that died early (case 4
#    asserts the alert fired before case 5 asserts it did not repeat).
#  - case 17: a lock file this user cannot open must not stop the heal.
#  - case 18: WSLInterop-late registered between the first check and the
#    write (WSL booting) must not get a second handler next to it.
#  - case 19: an unwritable state dir must not turn the 6-hour cooldown into
#    an alert every run.
#  - every case executes the healer the way cron does, by path, so a lost
#    execute bit fails the suite.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
SCRIPT="$HERE/bin/wsl-interop-heal.sh"
WATCHDOG="$HERE/bin/wsl-watchdog.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT does not exist" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is not executable; the watchdog runs it by path" >&2; exit 1; }
REAL_FLOCK=$(command -v flock) || { echo "FAIL: flock is not installed" >&2; exit 1; }

LINE=':WSLInterop:M::MZ::/init:P'
STUBS="$TMP/stubs"
mkdir -p "$STUBS"

# Fake `sudo -n tee <dir>/register`, acting as the kernel per SUDO_MODE:
#   ok      register the entry named in the line
#   refuse  sudo -n wants a password
#   noop    exit 0, register nothing
#   eexist  another writer registered it first; the write itself fails
cat > "$STUBS/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUDO_CALLS:?}"
[ "${1:-}" = "-n" ] || exit 64
shift
if [ "${SUDO_MODE:-ok}" = refuse ]; then
  echo "sudo: a password is required" >&2
  exit 1
fi
[ "${1:-}" = "tee" ] || exit 65
target=$2
line=$(cat)
printf '%s\n' "$line" >> "${SUDO_LINES:?}"
case "${SUDO_MODE:-ok}" in
  ok)
    name=${line#:}
    name=${name%%:*}
    : > "$(dirname "$target")/$name"
    ;;
  noop) ;;
  eexist)
    : > "$(dirname "$target")/WSLInterop"
    echo "tee: $target: File exists" >&2
    exit 1
    ;;
esac
exit 0
STUB
cat > "$STUBS/logger" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOGGER_CALLS:?}"
STUB
cat > "$STUBS/notify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_CALLS:?}"
exit "${NOTIFY_RC:-0}"
STUB
# The real flock, after creating $FLOCK_REGISTERS when set: another writer
# registering an entry while the healer takes its lock.
cat > "$STUBS/flock" <<'STUB'
#!/usr/bin/env bash
[ -n "${FLOCK_REGISTERS:-}" ] && : > "$FLOCK_REGISTERS"
exec "${REAL_FLOCK:?}" "$@"
STUB
chmod +x "$STUBS/sudo" "$STUBS/logger" "$STUBS/notify" "$STUBS/flock"

# new_case NAME: a fresh WSL-looking tree with an empty binfmt table.
new_case() {
  C="$TMP/$1"
  mkdir -p "$C/binfmt" "$C/state"
  : > "$C/binfmt/register"
  echo enabled > "$C/binfmt/status"
  echo '6.6.114.1-microsoft-standard-WSL2' > "$C/osrelease"
  printf '[boot]\nsystemd = true\n' > "$C/wsl.conf"
  : > "$C/init"
}

# heal [VAR=value ...]: run the healer against $C; sets RC.
heal() {
  env PATH="$STUBS:$PATH" \
    WSL_INTEROP_BINFMT_DIR="$C/binfmt" \
    WSL_INTEROP_OSRELEASE="$C/osrelease" \
    WSL_INTEROP_WSL_CONF="$C/wsl.conf" \
    WSL_INTEROP_INIT="$C/init" \
    WSL_INTEROP_LOG="$C/heal.log" \
    WSL_INTEROP_STATE_DIR="$C/state" \
    WSL_INTEROP_STATE_FALLBACK="$C/fallback" \
    WSL_INTEROP_LOCK="$C/heal.lock" \
    WSL_INTEROP_NOTIFY="$STUBS/notify" \
    SUDO_CALLS="$C/sudo.calls" SUDO_LINES="$C/sudo.lines" \
    LOGGER_CALLS="$C/logger.calls" NOTIFY_CALLS="$C/notify.calls" \
    REAL_FLOCK="$REAL_FLOCK" \
    "$@" "$SCRIPT" > "$C/out" 2> "$C/err"
  RC=$?
}

count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# 1. A registered WSLInterop is healthy: no write, no alert, no log line.
new_case healthy
: > "$C/binfmt/WSLInterop"
heal
if [ "$RC" -eq 0 ] && [ "$(count "$C/sudo.calls")" = 0 ] && [ "$(count "$C/notify.calls")" = 0 ] && [ ! -s "$C/heal.log" ]; then ok; else bad "healthy table: rc=$RC sudo=$(count "$C/sudo.calls") notify=$(count "$C/notify.calls")"; fi

# 2. Only WSLInterop-late (newer WSL) counts as healthy too.
new_case late
: > "$C/binfmt/WSLInterop-late"
heal
if [ "$RC" -eq 0 ] && [ "$(count "$C/sudo.calls")" = 0 ] && [ ! -e "$C/binfmt/WSLInterop" ]; then ok; else bad "WSLInterop-late present: rc=$RC sudo=$(count "$C/sudo.calls")"; fi

# 3. A flushed table is healed with WSL's own line, through sudo -n, and logged.
new_case heal
: > "$C/binfmt/python3.12"
heal
if [ "$RC" -eq 0 ] && [ "$(cat "$C/sudo.calls" 2>/dev/null)" = "-n tee $C/binfmt/register" ]; then ok; else bad "heal call: rc=$RC calls=$(cat "$C/sudo.calls" 2>/dev/null) err=$(cat "$C/err")"; fi
if [ "$(cat "$C/sudo.lines" 2>/dev/null)" = "$LINE" ]; then ok; else bad "registration line: got '$(cat "$C/sudo.lines" 2>/dev/null)', want '$LINE'"; fi
if [ -e "$C/binfmt/WSLInterop" ] && grep -q 'HEALED' "$C/heal.log" 2>/dev/null && grep -qF 'python3.12' "$C/heal.log"; then ok; else bad "heal not logged with the entries it found: $(cat "$C/heal.log" 2>/dev/null)"; fi
if [ "$(count "$C/notify.calls")" = 0 ] && [ "$(count "$C/logger.calls")" = 1 ]; then ok; else bad "a successful heal alerts nobody and logs one journal line: notify=$(count "$C/notify.calls") logger=$(count "$C/logger.calls")"; fi

# 4. sudo -n refuses: failure is logged, alerted once, and exits 1.
new_case refuse
heal SUDO_MODE=refuse
if [ "$RC" -eq 1 ] && [ "$(count "$C/notify.calls")" = 1 ] && grep -q 'FAILED' "$C/heal.log" 2>/dev/null; then ok; else bad "sudo refused: rc=$RC notify=$(count "$C/notify.calls") log=$(cat "$C/heal.log" 2>/dev/null)"; fi
if grep -qF 'password is required' "$C/notify.calls" 2>/dev/null && grep -qF 'systemctl restart systemd-binfmt.service' "$C/notify.calls"; then ok; else bad "alert lacks the reason or the restore command: $(cat "$C/notify.calls" 2>/dev/null)"; fi

# 5. A second failure inside the cooldown does not alert again.
heal SUDO_MODE=refuse
if [ "$RC" -eq 1 ] && [ "$(count "$C/notify.calls")" = 1 ] && grep -q 'suppressed' "$C/heal.log"; then ok; else bad "cooldown: rc=$RC notify=$(count "$C/notify.calls")"; fi

# 6. Once the cooldown has passed, the next failure alerts again.
touch -d '@1000000000' "$C/state/alert.stamp"
heal SUDO_MODE=refuse
if [ "$(count "$C/notify.calls")" = 2 ]; then ok; else bad "expired cooldown did not re-alert: notify=$(count "$C/notify.calls")"; fi

# 7. A write that exits 0 but registers nothing is a failure, not a heal.
new_case noop
heal SUDO_MODE=noop
if [ "$RC" -eq 1 ] && [ "$(count "$C/notify.calls")" = 1 ] && ! grep -q 'HEALED' "$C/heal.log" 2>/dev/null; then ok; else bad "silent no-op write: rc=$RC notify=$(count "$C/notify.calls") log=$(cat "$C/heal.log" 2>/dev/null)"; fi

# 8. Another writer won the race (EEXIST): the entry exists, so it is healthy.
new_case eexist
heal SUDO_MODE=eexist
if [ "$RC" -eq 0 ] && [ "$(count "$C/notify.calls")" = 0 ] && [ -e "$C/binfmt/WSLInterop" ]; then ok; else bad "EEXIST race: rc=$RC notify=$(count "$C/notify.calls")"; fi

# 9. [interop] enabled = false: interop is off on purpose, so leave it off.
new_case disabled
printf '[boot]\nsystemd = true\n\n[interop]\n# off on purpose\nenabled = false\nappendWindowsPath = false\n' > "$C/wsl.conf"
heal
if [ "$RC" -eq 0 ] && [ "$(count "$C/sudo.calls")" = 0 ] && [ "$(count "$C/notify.calls")" = 0 ]; then ok; else bad "interop disabled: rc=$RC sudo=$(count "$C/sudo.calls")"; fi

# 10. Near-identical enabled = true still heals.
new_case enabled
printf '[boot]\nsystemd = true\n\n[interop]\n# off on purpose\nenabled = true\nappendWindowsPath = false\n' > "$C/wsl.conf"
heal
if [ "$RC" -eq 0 ] && [ -e "$C/binfmt/WSLInterop" ]; then ok; else bad "interop enabled=true did not heal: rc=$RC"; fi

# 11. enabled = false under another section is not the interop switch.
new_case othersection
printf '[automount]\nenabled = false\n' > "$C/wsl.conf"
heal
if [ "$RC" -eq 0 ] && [ -e "$C/binfmt/WSLInterop" ]; then ok; else bad "[automount] enabled=false blocked the heal: rc=$RC"; fi

# 12. Off WSL, or without /init, there is nothing to heal.
new_case notwsl
echo '6.8.0-45-generic' > "$C/osrelease"
heal
if [ "$RC" -eq 0 ] && [ "$(count "$C/sudo.calls")" = 0 ]; then ok; else bad "non-WSL kernel: rc=$RC sudo=$(count "$C/sudo.calls")"; fi
new_case noinit
rm -f "$C/init"
heal
if [ "$RC" -eq 0 ] && [ "$(count "$C/sudo.calls")" = 0 ]; then ok; else bad "no /init: rc=$RC sudo=$(count "$C/sudo.calls")"; fi

# 13. binfmt_misc not mounted: cannot heal by registering, so alert.
new_case unmounted
rm -f "$C/binfmt/register"
heal
if [ "$RC" -eq 1 ] && [ "$(count "$C/sudo.calls")" = 0 ] && [ "$(count "$C/notify.calls")" = 1 ]; then ok; else bad "unmounted binfmt_misc: rc=$RC sudo=$(count "$C/sudo.calls") notify=$(count "$C/notify.calls")"; fi

# 14. A failed send leaves no stamp, so the next run retries the alert.
new_case sendfail
heal SUDO_MODE=refuse NOTIFY_RC=1
heal SUDO_MODE=refuse NOTIFY_RC=1
if [ "$(count "$C/notify.calls")" = 2 ] && [ ! -e "$C/state/alert.stamp" ]; then ok; else bad "failed send was stamped: notify=$(count "$C/notify.calls")"; fi

# 15. Recovery clears the stamp, so the next outage alerts at once.
new_case recover
heal SUDO_MODE=refuse
heal SUDO_MODE=ok
rm -f "$C/binfmt/WSLInterop"
heal SUDO_MODE=refuse
if [ "$(count "$C/notify.calls")" = 2 ]; then ok; else bad "recovery did not clear the alert stamp: notify=$(count "$C/notify.calls")"; fi

# 16. The watchdog runs the healer on every tick, before its memory-pressure
# early exit (the first `exit` after the ALWAYS sections), and keeps its
# stderr. Each anchor must resolve before the order is compared.
heal_call=$(grep -n '^"\$HERE/wsl-interop-heal\.sh"' "$WATCHDOG" | head -1)
heal_line=${heal_call%%:*}
exit_line=$(grep -n '^[[:space:]]*exit\b\|&& exit\b\||| exit\b' "$WATCHDOG" | head -1 | cut -d: -f1)
if [ -n "$heal_line" ]; then ok; else bad "wsl-watchdog.sh has no line calling \"\$HERE/wsl-interop-heal.sh\" (its own directory, since #18)"; fi
if [ -n "$exit_line" ]; then ok; else bad "wsl-watchdog.sh has no exit: the anchor for the pressure early exit is lost"; fi
if [ -n "$heal_line" ] && [ -n "$exit_line" ] && [ "$heal_line" -lt "$exit_line" ]; then ok; else bad "wsl-watchdog.sh does not call the healer before its first exit: heal=${heal_line:-none} exit=${exit_line:-none}"; fi
case "$heal_call" in
  *'2>/dev/null'*|*'2>&-'*) bad "the watchdog discards the healer's stderr: ${heal_call#*:}" ;;
  *) ok ;;
esac

# 17. A lock file that cannot be opened does not stop the heal.
new_case lockdenied
heal WSL_INTEROP_LOCK="$C/no-such-dir/heal.lock"
if [ "$RC" -eq 0 ] && [ -e "$C/binfmt/WSLInterop" ] && grep -qF 'cannot open lock' "$C/logger.calls" 2>/dev/null; then ok; else bad "unopenable lock: rc=$RC healed=$([ -e "$C/binfmt/WSLInterop" ] && echo yes || echo no) logger=$(cat "$C/logger.calls" 2>/dev/null)"; fi

# 18. WSLInterop-late appearing while the healer takes its lock (WSL booting)
# is healthy: no write, so no second handler beside it.
new_case latelate
heal FLOCK_REGISTERS="$C/binfmt/WSLInterop-late"
if [ "$RC" -eq 0 ] && [ "$(count "$C/sudo.calls")" = 0 ] && [ ! -e "$C/binfmt/WSLInterop" ] && [ -e "$C/binfmt/WSLInterop-late" ]; then ok; else bad "late registration during the lock: rc=$RC sudo=$(count "$C/sudo.calls") WSLInterop=$([ -e "$C/binfmt/WSLInterop" ] && echo written || echo absent)"; fi

# 19. An unwritable state dir keeps the cooldown in the fallback, and a
# healthy table clears that stamp too.
new_case statero
: > "$C/blocker"
heal SUDO_MODE=refuse WSL_INTEROP_STATE_DIR="$C/blocker/state"
heal SUDO_MODE=refuse WSL_INTEROP_STATE_DIR="$C/blocker/state"
if [ "$(count "$C/notify.calls")" = 1 ] && [ -e "$C/fallback/alert.stamp" ] && grep -qF 'not writable' "$C/logger.calls" 2>/dev/null; then ok; else bad "unwritable state dir: notify=$(count "$C/notify.calls") fallback_stamp=$([ -e "$C/fallback/alert.stamp" ] && echo yes || echo no)"; fi
: > "$C/binfmt/WSLInterop"
heal WSL_INTEROP_STATE_DIR="$C/blocker/state"
if [ "$RC" -eq 0 ] && [ ! -e "$C/fallback/alert.stamp" ]; then ok; else bad "a healthy table left the fallback stamp: rc=$RC"; fi

if [ "$fail" -eq 0 ]; then
  echo "ok — wsl-interop-heal: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — wsl-interop-heal: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
