#!/usr/bin/env bash
# Tests for scripts/disk-watermark.sh -- the disk-fill watchdog added
# for the 2026-08-21 emergency-reset incident (dotfiles#428).
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
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
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
export PATH="$TMP/bin:$PATH"

run_case() {
  # $1 = label, $2 = expected exit code, $3 = expected flagged count
  local label="$2_ignored" expect_exit="$2" expect_flagged="$3"
  : > "$NOTIFY_LOG"
  local out status
  out=$("$TMP/scripts/disk-watermark.sh" 2>&1); status=$?
  local counter
  counter=$(printf '%s\n' "$out" | grep -o 'disk-watermark-flagged:[0-9]*' | tail -n1)
  local calls
  calls=$(wc -l < "$NOTIFY_LOG" 2>/dev/null || echo 0)

  if [ "$status" -eq "$expect_exit" ]; then ok; else bad "$1: exit $status, expected $expect_exit"$'\n'"$out"; fi
  if [ "$counter" = "disk-watermark-flagged:$expect_flagged" ]; then
    ok
  else
    bad "$1: counter line '$counter', expected 'disk-watermark-flagged:$expect_flagged'"$'\n'"$out"
  fi
  echo "$out|$calls"
}

# -- clear: both filesystems well under every threshold -----------------------
echo "=== case: clear ===" >&2
export DW_STUB_PCT_ROOT=50 DW_STUB_AVAIL_ROOT_KB=500000000
export DW_STUB_PCT_MNTC=40 DW_STUB_AVAIL_MNTC_KB=600000000
result=$(run_case clear 0 0)
calls=${result##*|}
if [ "$calls" -eq 0 ]; then ok; else bad "clear: notifier fired $calls time(s), expected 0"; fi
if grep -q ' — OK$' <<<"$result"; then ok; else bad "clear: expected an OK line in output"; fi

# -- warn: root crosses WARN_PCT but not CRIT_PCT, floor untouched ------------
echo "=== case: warn ===" >&2
export DW_STUB_PCT_ROOT=87 DW_STUB_AVAIL_ROOT_KB=500000000
export DW_STUB_PCT_MNTC=40 DW_STUB_AVAIL_MNTC_KB=600000000
result=$(run_case warn 1 1)
calls=${result##*|}
if [ "$calls" -eq 1 ]; then ok; else bad "warn: notifier fired $calls time(s), expected exactly 1"; fi
if grep -q ' — WARN$' <<<"$result"; then ok; else bad "warn: expected a WARN line in output"; fi

# -- crit: root crosses CRIT_PCT ----------------------------------------------
echo "=== case: crit ===" >&2
export DW_STUB_PCT_ROOT=95 DW_STUB_AVAIL_ROOT_KB=500000000
export DW_STUB_PCT_MNTC=40 DW_STUB_AVAIL_MNTC_KB=600000000
result=$(run_case crit 1 1)
calls=${result##*|}
if [ "$calls" -eq 1 ]; then ok; else bad "crit: notifier fired $calls time(s), expected exactly 1"; fi
if grep -q ' — CRIT$' <<<"$result"; then ok; else bad "crit: expected a CRIT line in output"; fi

# -- floor-breach: pct is fine but free space is below MIN_FREE_GB ------------
# 30,000,000 KB =~ 28.6GB, under the default 40GB floor, while 50% used stays
# below WARN_PCT entirely -- this is the case a pct-only check would miss.
echo "=== case: floor-breach ===" >&2
export DW_STUB_PCT_ROOT=50 DW_STUB_AVAIL_ROOT_KB=30000000
export DW_STUB_PCT_MNTC=40 DW_STUB_AVAIL_MNTC_KB=600000000
result=$(run_case floor 1 1)
calls=${result##*|}
if [ "$calls" -eq 1 ]; then ok; else bad "floor-breach: notifier fired $calls time(s), expected exactly 1"; fi
if grep -q ' — CRIT$' <<<"$result"; then ok; else bad "floor-breach: expected the floor breach to read as CRIT"; fi
if grep -q 'free < .*GB floor' <<<"$result"; then ok; else bad "floor-breach: expected the floor-breach reason text in output"; fi

if [ "$fail" -eq 0 ]; then
  echo "ok — disk-watermark: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — disk-watermark: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
