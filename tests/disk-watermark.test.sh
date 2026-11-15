#!/usr/bin/env bash
# Tests for scripts/disk-watermark.sh -- the disk-fill watchdog added
# for the 2026-08-21 emergency-reset incident (dotfiles#428), which alerts only
# when a breach is new or worse since hov-stack#644 made its timer hourly.
#
# Hermetic, same shape as sync-install-smoke.test.sh: copies disk-watermark.sh
# into a scratch $TMP/scripts alongside a stub notify.sh, so `$HERE/notify.sh`
# (resolved relative to the SCRIPT's own directory, not $PATH -- see the
# say() helper in disk-watermark.sh and its siblings pkg-cache-prune.sh /
# dcg-update.sh / cass-release-promote.sh) resolves to the stub instead of the
# real Windows-toast notifier. `df` is stubbed on $PATH instead, since it IS
# looked up via PATH in the script.
#
# DISK_WATERMARK_PATHS points the script at two fixture directories rather
# than real `/` and `/mnt/c` -- required for portability, since `/mnt/c` does
# not exist on the Blacksmith Linux CI runner this suite runs on (WSL-only),
# and because the real box's own `/` and `/mnt/c` fill levels are outside this
# test's control. The stub `df` returns canned pct/avail values per fixture
# directory, driven by env vars the test sets per scenario.
# DISK_WATERMARK_STATE_DIR keeps the alert state under $TMP, never the real
# ~/.local/state.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# -- fixture layout -----------------------------------------------------------
mkdir -p "$TMP/scripts" "$TMP/bin" "$TMP/fs/root" "$TMP/fs/mntc"
cp "$REPO/scripts/disk-watermark.sh" "$TMP/scripts/disk-watermark.sh"
chmod +x "$TMP/scripts/disk-watermark.sh"

# Stub notify.sh -- same directory as the copied script, so $HERE/notify.sh
# resolves here rather than to the real notifier. Logs one line per call.
NOTIFY_LOG="$TMP/notify-calls.log"
cat > "$TMP/scripts/notify.sh" <<EOF
#!/usr/bin/env bash
echo "\$1|\${2:-default}" >> "$NOTIFY_LOG"
exit 0
EOF
chmod +x "$TMP/scripts/notify.sh"

# Stub df -- driven by DW_STUB_PCT_ROOT/DW_STUB_AVAIL_ROOT_KB and the _MNTC
# equivalents, keyed off the fixture directory name in the queried path (the
# real script always invokes `df -Pk "$fs"`, so the last arg is the path).
cat > "$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
path="${*: -1}"
case "$path" in
  */root) pct="$DW_STUB_PCT_ROOT"; avail="$DW_STUB_AVAIL_ROOT_KB" ;;
  */mntc) pct="$DW_STUB_PCT_MNTC"; avail="$DW_STUB_AVAIL_MNTC_KB" ;;
  *) exit 1 ;;
esac
echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
echo "/dev/stub          9999999    111111    ${avail}      ${pct}% ${path}"
EOF
chmod +x "$TMP/bin/df"

export DISK_WATERMARK_PATHS="$TMP/fs/root $TMP/fs/mntc"
export DISK_WATERMARK_STATE_DIR="$TMP/state"
export PATH="$TMP/bin:$PATH"

gb() { echo $(( $1 * 1024 * 1024 )); }   # GB -> the KB df -k reports
root() { export DW_STUB_PCT_ROOT="$1" DW_STUB_AVAIL_ROOT_KB; DW_STUB_AVAIL_ROOT_KB=$(gb "$2"); }
mntc() { export DW_STUB_PCT_MNTC="$1" DW_STUB_AVAIL_MNTC_KB; DW_STUB_AVAIL_MNTC_KB=$(gb "$2"); }
fresh() { rm -rf "$TMP/state"; }

# run_case <label> <exit> <flagged> <alerted> <notify calls>: runs the script in
# this shell (no command substitution around the call), so ok/bad counts land;
# leaves the output in $OUT for the caller's own checks.
OUT=""
run_case() {
  local label="$1" expect_exit="$2" expect_flagged="$3" expect_alerted="$4" expect_calls="$5"
  local status calls
  : > "$NOTIFY_LOG"
  OUT=$("$TMP/scripts/disk-watermark.sh" 2>&1); status=$?
  calls=$(wc -l < "$NOTIFY_LOG")
  [ "$status" -eq "$expect_exit" ] && ok || bad "$label: exit $status, expected $expect_exit"$'\n'"$OUT"
  grep -qx "disk-watermark-flagged:$expect_flagged" <<<"$OUT" && ok \
    || bad "$label: expected disk-watermark-flagged:$expect_flagged"$'\n'"$OUT"
  grep -qx "disk-watermark-alerted:$expect_alerted" <<<"$OUT" && ok \
    || bad "$label: expected disk-watermark-alerted:$expect_alerted"$'\n'"$OUT"
  [ "$calls" -eq "$expect_calls" ] && ok || bad "$label: notifier fired $calls time(s), expected $expect_calls"
}
has() { grep -qF -- "$2" <<<"$OUT" && ok || bad "$1: expected output to contain: $2"$'\n'"$OUT"; }

# -- clear: both filesystems well under every threshold -----------------------
echo "=== case: clear ===" >&2
fresh; root 50 476; mntc 40 572
run_case clear 0 0 0 0
grep -q ' — OK$' <<<"$OUT" && ok || bad "clear: expected an OK line in output"

# -- warn: root crosses WARN_PCT but not CRIT_PCT, floor untouched ------------
echo "=== case: warn ===" >&2
fresh; root 87 476; mntc 40 572
run_case warn 1 1 1 1
grep -q ' — WARN$' <<<"$OUT" && ok || bad "warn: expected a WARN line in output"
has warn "(new breach)"

# -- crit: root crosses CRIT_PCT ----------------------------------------------
echo "=== case: crit ===" >&2
fresh; root 95 476; mntc 40 572
run_case crit 1 1 1 1
grep -q ' — CRIT$' <<<"$OUT" && ok || bad "crit: expected a CRIT line in output"

# -- floor-breach: pct is fine but free space is below MIN_FREE_GB ------------
# 28GB is under the default 40GB floor, while 50% used stays below WARN_PCT
# entirely -- this is the case a pct-only check would miss.
echo "=== case: floor-breach ===" >&2
fresh; root 50 28; mntc 40 572
run_case floor 1 1 1 1
grep -q ' — CRIT$' <<<"$OUT" && ok || bad "floor-breach: expected the floor breach to read as CRIT"
has floor-breach "28GB free < 40GB floor"

# -- repeat: the same breach on the next run is suppressed, exit 0 -------------
echo "=== case: repeat ===" >&2
fresh; root 87 400; mntc 40 572
run_case repeat-first 1 1 1 1
run_case repeat-again 0 1 0 0
has repeat "suppressed: no worse than at the last alert (400GB free then; alerts again at 390GB free"
has repeat "1 breach(es) no worse than at their last alert"
[ -f "$TMP/state/fs${TMP//[^A-Za-z0-9._-]/_}_fs_root" ] && ok || bad "repeat: no state file for the root fixture: $(ls "$TMP/state" 2>&1)"

# -- fall: under 10GB lost stays quiet; 10GB lost alerts, from the alert's baseline
echo "=== case: fall ===" >&2
root 87 391
run_case fall-9 0 1 0 0
root 87 390
run_case fall-10 1 1 1 1
has fall "free space fell from 400GB to 390GB since the last alert"

# -- rebase: free space up by 10GB moves the baseline, so the next 10 lost alert
echo "=== case: rebase ===" >&2
root 87 405
run_case rebase-up 0 1 0 0
root 87 396
run_case rebase-9 0 1 0 0
root 87 395
run_case rebase-10 1 1 1 1
has rebase "free space fell from 405GB to 395GB"

# -- level: WARN -> CRIT alerts; CRIT -> WARN is quiet and remembered ----------
echo "=== case: level ===" >&2
root 95 395
run_case level-rise 1 1 1 1
has level-rise "(rose from WARN to CRIT)"
root 87 395
run_case level-drop 0 1 0 0
root 95 395
run_case level-rerise 1 1 1 1
has level-rerise "(rose from WARN to CRIT)"

# -- floor after CRIT: the first floor breach alerts though the level holds ----
echo "=== case: floor-new ===" >&2
root 95 39
run_case floor-new 1 1 1 1
has floor-new "(fell below the 40GB floor)"
run_case floor-repeat 0 1 0 0

# -- near full: the step shrinks to half of what was free at the last alert ----
echo "=== case: near-full ===" >&2
fresh; root 99 9
run_case near-first 1 1 1 1
root 99 5
run_case near-5 0 1 0 0
root 99 4
run_case near-4 1 1 1 1
has near-4 "free space fell from 9GB to 4GB"

# -- reset: back under every watermark clears state; the next breach is new ----
echo "=== case: reset ===" >&2
fresh; root 87 400
run_case reset-first 1 1 1 1
root 50 400
run_case reset-clear 0 0 0 0
[ -z "$(ls -A "$TMP/state" 2>/dev/null)" ] && ok || bad "reset: state left after clearing: $(ls -A "$TMP/state")"
root 87 400
run_case reset-again 1 1 1 1
has reset-again "(new breach)"

# -- corrupt state alerts and is rewritten -------------------------------------
echo "=== case: corrupt ===" >&2
for f in "$TMP"/state/*; do printf 'garbage here\n' >"$f"; done
run_case corrupt 1 1 1 1
has corrupt "(state file unreadable)"
run_case corrupt-after 0 1 0 0

# -- unwritable state: every breach alerts, and the run says why ---------------
echo "=== case: no-state ===" >&2
: >"$TMP/not-a-dir"
DISK_WATERMARK_STATE_DIR="$TMP/not-a-dir" run_case no-state-1 1 1 1 1
has no-state "cannot keep alert state in $TMP/not-a-dir"
DISK_WATERMARK_STATE_DIR="$TMP/not-a-dir" run_case no-state-2 1 1 1 1

# -- mixed: one filesystem alerts, one is suppressed; one notify names only the first
echo "=== case: mixed ===" >&2
fresh; root 87 400; mntc 40 572
run_case mixed-root 1 1 1 1
mntc 95 400
run_case mixed-both 1 2 1 1
grep -qF "$TMP/fs/mntc: CRIT" "$NOTIFY_LOG" && ok || bad "mixed: notify should name the mntc fixture: $(cat "$NOTIFY_LOG")"
grep -qF "$TMP/fs/root:" "$NOTIFY_LOG" && bad "mixed: notify should not name the suppressed root fixture: $(cat "$NOTIFY_LOG")" || ok
has mixed "$TMP/fs/root — suppressed"

if [ "$fail" -eq 0 ]; then
  echo "ok — disk-watermark: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — disk-watermark: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
