#!/usr/bin/env bash
# Contract test for harness-doctor's check_enter_plan_mode_denied (check 11,
# dotfiles#1392): the standing presence check for the bare "EnterPlanMode"
# deny. Exact element equality, so ExitPlanMode, a parameterized spelling, or a
# different case must each still warn. A missing file, unreadable JSON, or a
# non-array deny warns instead of aborting the doctor run (fail closed).
#
# Hermetic: the helper is extracted from harness-doctor.sh by its function
# boundaries and evaluated here; nothing under ~/.claude is read or written.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# HARNESS_DOCTOR lets the inverted-state proof point at a doctored copy.
DOCTOR=${HARNESS_DOCTOR:-$REPO/scripts/harness-doctor.sh}
TMP=$(mktemp -d /tmp/doctor-plan-mode-deny.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
good() { pass=$((pass + 1)); }

# Minimal stand-ins for the doctor's reporting helpers.
WARNS=0
warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }

helper=$(sed -n '/^check_enter_plan_mode_denied() {/,/^}/p' "$DOCTOR")
[ -n "$helper" ] || { echo "FAIL: check_enter_plan_mode_denied not found in $DOCTOR" >&2; exit 1; }
eval "$helper"

REMEDY="run sync.sh install (never push)"

# Run in the current shell (not a $( ) subshell) so the WARNS counter the
# doctor's summary relies on is observed to move, not just the text.
expect_warn() {
  local file=$1 label=$2 before=$WARNS out
  check_enter_plan_mode_denied "$file" "$label" "$REMEDY" > "$TMP/out"
  out=$(cat "$TMP/out")
  if [ "$WARNS" -eq "$((before + 1))" ] && [[ "$out" == *"WARN: $label"* ]] && [[ "$out" == *"EnterPlanMode"* ]]; then
    good
  else
    bad "$label: expected exactly one WARN naming the label and EnterPlanMode, got: $out (WARNS $before -> $WARNS)"
  fi
}
expect_quiet() {
  local file=$1 label=$2 before=$WARNS out
  check_enter_plan_mode_denied "$file" "$label" "$REMEDY" > "$TMP/out"
  out=$(cat "$TMP/out")
  if [ "$WARNS" -eq "$before" ] && [ -z "$out" ]; then good; else bad "$label: expected silence, got: $out"; fi
}

# Both fixtures carry the bare entry (among other deny rules, or alone) — quiet.
printf '%s\n' '{"permissions": {"deny": ["Bash(rm -rf /*)", "EnterPlanMode", "Bash(sudo su:*)"]}}' > "$TMP/live-ok.json"
expect_quiet "$TMP/live-ok.json" "live settings"
printf '%s\n' '{"permissions": {"deny": ["EnterPlanMode"]}}' > "$TMP/repo-ok.json"
expect_quiet "$TMP/repo-ok.json" "tracked settings"

# AE6: live fixture lacks the entry — one WARN naming the live label and
# EnterPlanMode, WARNS incrementing by exactly one.
printf '%s\n' '{"permissions": {"deny": ["Bash(rm -rf /*)"]}}' > "$TMP/live-missing.json"
expect_warn "$TMP/live-missing.json" "live settings"

# Tracked fixture lacks the entry — one WARN naming the tracked label.
printf '%s\n' '{"permissions": {"deny": []}}' > "$TMP/repo-missing.json"
expect_warn "$TMP/repo-missing.json" "tracked settings"

# Exact element equality only: ExitPlanMode, a parameterized spelling, and a
# different case must each still warn.
printf '%s\n' '{"permissions": {"deny": ["ExitPlanMode"]}}' > "$TMP/exit-only.json"
expect_warn "$TMP/exit-only.json" "fixture exit-plan-mode-only"
printf '%s\n' '{"permissions": {"deny": ["EnterPlanMode(foo)"]}}' > "$TMP/paren.json"
expect_warn "$TMP/paren.json" "fixture parameterized-spelling"
printf '%s\n' '{"permissions": {"deny": ["enterplanmode"]}}' > "$TMP/lowercase.json"
expect_warn "$TMP/lowercase.json" "fixture lowercase-spelling"

# Fail-closed: permissions missing, deny a string (not an array), and
# unreadable JSON must each warn, and the helper returns without aborting —
# proven by every later fixture in this file still running to completion.
printf '%s\n' '{}' > "$TMP/no-permissions.json"
expect_warn "$TMP/no-permissions.json" "fixture no-permissions-key"
printf '%s\n' '{"permissions": {"deny": "EnterPlanMode"}}' > "$TMP/deny-string.json"
expect_warn "$TMP/deny-string.json" "fixture deny-is-a-string"
printf '%s\n' '{"permissions": {"deny": ["EnterPlanMode"' > "$TMP/malformed.json"
expect_warn "$TMP/malformed.json" "fixture malformed-json"

# A file path that does not exist must warn too.
expect_warn "$TMP/missing-file.json" "fixture missing-file"

# Wiring: check 11's block invokes the helper for both $LIVE_SETTINGS and
# $REPO_SETTINGS. Structural, not behavioural -- scoped to the check-11 block
# so some later check couldn't satisfy this by accident.
block=$(sed -n '/^echo "== 11\. /,/^echo "== 11b\. /p' "$DOCTOR")
if [[ -n "$block" ]] \
  && grep -qF 'check_enter_plan_mode_denied "$LIVE_SETTINGS"' <<<"$block" \
  && grep -qF 'check_enter_plan_mode_denied "$REPO_SETTINGS"' <<<"$block"; then
  good
else
  bad "check 11 block does not call check_enter_plan_mode_denied for both \$LIVE_SETTINGS and \$REPO_SETTINGS"
fi

# Windows break-glass wiring: check 1 invokes the helper for the Windows live
# settings and for the tracked Windows stub.
win_block=$(sed -n '/^echo "== 1\. /,/^echo "== 2\. /p' "$DOCTOR")
if [[ -n "$win_block" ]] \
  && grep -qF 'check_enter_plan_mode_denied "$WIN/settings.json"' <<<"$win_block" \
  && grep -qF 'check_enter_plan_mode_denied "$HD_ROOT/windows-stub/settings.json"' <<<"$win_block"; then
  good
else
  bad "check 1 block does not call check_enter_plan_mode_denied for both the Windows live settings and the tracked Windows stub"
fi

echo "harness-doctor-plan-mode-deny: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
