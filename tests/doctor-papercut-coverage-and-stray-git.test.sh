#!/usr/bin/env bash
# harness-doctor check 19 (papercut capture coverage) and check 34 (stray .git
# on Claude Code's session anchors), proven by RUNNING the shipped sections
# (dotfiles#1553).
#
# WHY. Check 19 used to verify that capture was REGISTERED, which stayed green
# while ~2,080 Write/Edit refusals left zero papercut records: Claude Code
# fires no PostToolUseFailure for a call it rejects before running it. The
# coverage branch reads the weekly transcript backfill's per-tool counts; the
# failure directions pinned here are a blind tool reading as covered, a corrupt
# file reading as clean, and a near-threshold gap tripping a false WARN.
# Check 34 is the read-only backstop for the SessionStart stray-.git heal: it
# must report a stray and must never move it.
#
# EXTRACTION: same approach as failed-unit-sweep.test.sh -- sed the real
# sections out of harness-doctor.sh; sourcing the whole doctor would audit this
# machine. HOME points at a scratch tree, and STRAY_DOT_GIT_FS_ROOT at a
# scratch filesystem root, so neither the live store nor the host's /tmp is
# read.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-pc-sdg-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok_()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  case "$1" in *"$2"*) ok_ ;; *) bad "$3: missing [$2]"$'\n'"$1" ;; esac
}
omits() {
  case "$1" in *"$2"*) bad "$3: unexpectedly contained [$2]"$'\n'"$1" ;; *) ok_ ;; esac
}

sed -n '/^echo "== 19\. /,/^echo "== 20\. /p' "$DOCTOR" | sed '$d' > "$TMP/check19.sh"
sed -n '/^echo "== 34\. /,/^echo$/p' "$DOCTOR" | sed '$d' > "$TMP/check34.sh"
grep -q 'backfill-coverage.json' "$TMP/check19.sh" || { echo "FAIL: check 19 extraction lost the coverage branch" >&2; exit 1; }
grep -q 'stray-dot-git.js' "$TMP/check34.sh" || { echo "FAIL: check 34 extraction failed" >&2; exit 1; }

# A HOME that passes every pre-existing line of check 19, so only the new
# branch can warn.
make_home() {
  local home=$TMP/$1
  mkdir -p "$home/.claude/hooks/PostToolUseFailure" "$home/.claude/bin" "$home/.claude/scripts" \
    "$home/.claude/papercuts" "$home/.claude/hooks/lib"
  : > "$home/.claude/hooks/PostToolUseFailure/papercut-log.js"
  : > "$home/.claude/bin/papercut.py"
  chmod +x "$home/.claude/bin/papercut.py"
  printf '%s\n' '{"hooks":{"PostToolUseFailure":[{"hooks":[{"command":"node papercut-log.js"}]}]}}' \
    > "$home/.claude/settings.json"
  printf '%s\n' '"$HOME/.claude/bin/papercut.py" rollup' '"$HOME/.claude/bin/papercut.py" staleness' \
    'papercuts-flagged:[0-9]' 'node "$HOME/.claude/scripts/papercut-backfill.js" --days 14' \
    > "$home/.claude/scripts/harness-weekly.sh"
  ln -s "$REPO/hooks/lib/stray-dot-git.js" "$home/.claude/hooks/lib/stray-dot-git.js"
  echo "$home"
}

# coverage <home> <tools-json> [dropped]
coverage() {
  printf '{"days":8,"totals":{"dropped":%s},"tools":%s}\n' "${3:-0}" "$2" \
    > "$1/.claude/papercuts/.backfill-coverage.json"
}

run_check() {
  # $1 = home, $2 = section file, $3 = fs root for the stray scan
  ( export HOME=$1 STRAY_DOT_GIT_FS_ROOT=${3:-$TMP/empty-root}
    unset PAPERCUT_STORE CLAUDE_CONFIG_DIR
    WARNS=0
    warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
    ok()   { echo "  ok: $*"; }
    # shellcheck disable=SC1090
    . "$2" 2>&1 )
}
mkdir -p "$TMP/empty-root"

T='{"Bash":{"visible":100,"visible_captured":99},"Write":{"visible":1,"visible_captured":0}}'

# ---- check 19 -------------------------------------------------------------
# 1. healthy: full coverage, small noise below the floor -> clean
h=$(make_home healthy); coverage "$h" "$T"
out=$(run_check "$h" "$TMP/check19.sh")
omits "$out" "WARN" "healthy coverage must not warn"
contains "$out" "per-tool capture covered" "healthy run prints the ok line"

# 2. no coverage file: the backfill never ran
h=$(make_home missing)
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "no transcript-backfill coverage file" "a missing file is a finding"

# 3. stale file: noted with the refresh command, never a WARN -- nothing
#    schedules the backfill since harness-weekly.timer retired (2026-10-17)
h=$(make_home stale); coverage "$h" "$T"
touch -d '10 days ago' "$h/.claude/papercuts/.backfill-coverage.json"
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "over 9 days old" "a stale file is noted"
omits "$out" "WARN" "a stale file alone is not a finding"

# 4. a blind tool is named with its counts
h=$(make_home blind)
coverage "$h" '{"Read":{"visible":50,"visible_captured":5},"Bash":{"visible":100,"visible_captured":100}}'
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "capture blind to Read: 45 of 50" "a blind tool is named"
omits "$out" "capture blind to Bash" "a covered tool is not"

# 5. thresholds: gap >= 20 AND under half captured, both required
h=$(make_home edge)
coverage "$h" '{"SmallGap":{"visible":30,"visible_captured":11},"Half":{"visible":40,"visible_captured":20},"JustUnder":{"visible":40,"visible_captured":19}}'
out=$(run_check "$h" "$TMP/check19.sh")
omits "$out" "SmallGap" "a gap under 20 is noise, not a finding"
omits "$out" "Half:" "exactly half captured is not blind"
contains "$out" "capture blind to JustUnder: 21 of 40" "just under half with a 21 gap is blind"

# 6. dropped records are a finding
h=$(make_home dropped); coverage "$h" "$T" 3
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "dropped 3 record(s)" "drops are surfaced"

# 6b. counts over a tree the backfill could not read are a finding, not a clean
# week; an explicit zero stays clean
h=$(make_home incomplete)
printf '{"days":8,"scan_errors":2,"totals":{"dropped":0},"tools":%s}\n' "$T" > "$h/.claude/papercuts/.backfill-coverage.json"
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "could not read 2 transcript director(ies) or file(s)" "an incomplete scan is surfaced"
h=$(make_home complete)
printf '{"days":8,"scan_errors":0,"totals":{"dropped":0},"tools":%s}\n' "$T" > "$h/.claude/papercuts/.backfill-coverage.json"
out=$(run_check "$h" "$TMP/check19.sh")
omits "$out" "WARN" "scan_errors 0 is clean"

# 7. a corrupt file is one finding, never a stream of fake tool names
h=$(make_home corrupt)
printf 'not json\n' > "$h/.claude/papercuts/.backfill-coverage.json"
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "coverage file unreadable" "a corrupt file is reported"
omits "$out" "capture blind to" "jq's error text is not read as tool gaps"

# 8. the weekly not running the backfill is a finding
h=$(make_home unwired); coverage "$h" "$T"
sed -i '/papercut-backfill/d' "$h/.claude/scripts/harness-weekly.sh"
out=$(run_check "$h" "$TMP/check19.sh")
contains "$out" "papercut transcript backfill not wired" "an unwired backfill is a finding"

# ---- check 34 -------------------------------------------------------------
# 9. clean host
h=$(make_home sdg-clean)
out=$(run_check "$h" "$TMP/check34.sh")
omits "$out" "WARN" "a clean host does not warn"
contains "$out" "no .git on /, /tmp" "clean host prints the ok line"

# 10. a stray is reported and NOT moved
root=$TMP/root-stray; mkdir -p "$root/tmp/.git"
out=$(run_check "$h" "$TMP/check34.sh" "$root")
contains "$out" "WARN: stray-dot-git: stray /tmp/.git (empty directory" "a stray is reported"
contains "$out" "--heal" "the report names the fix"
[ -d "$root/tmp/.git" ] && ok_ || bad "doctor must never move the stray"

# 11. a real repository is reported as one, not as a stray
root=$TMP/root-repo; mkdir -p "$root/tmp"; git init -q "$root/tmp"
out=$(run_check "$h" "$TMP/check34.sh" "$root")
contains "$out" "git repository at /tmp/.git" "a real repository is reported"
omits "$out" "stray /tmp/.git" "a real repository is not called a stray"

# 12. a missing library is a finding, not a silent pass
h=$(make_home sdg-missing); rm "$h/.claude/hooks/lib/stray-dot-git.js"
out=$(run_check "$h" "$TMP/check34.sh")
contains "$out" "stray-dot-git.js missing" "a missing library is reported"

echo "doctor papercut coverage + stray .git: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
