#!/usr/bin/env bash
# Contract test for harness-doctor's check_attribution_off (check 11, dotfiles#820).
#
# PLANTED NEGATIVE: fixture A is today's live shape — `includeCoAuthoredBy: false`
# and no `attribution` object. It must WARN, because that key is deprecated
# (Claude Code 2.0.62+) and a release that drops it silently re-enables the
# `Co-Authored-By: Claude ...` trailer on every commit. Remove the helper's jq
# assertion and fixture A passes silently, which is exactly the drift the check
# exists to catch. Fixtures C/D pin fail-closed behaviour on a non-empty
# attribution string and on an unreadable file.
#
# Hermetic: the helper is extracted from harness-doctor.sh by its function
# boundaries and evaluated here; nothing under ~/.claude is read or written.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# HARNESS_DOCTOR lets the inverted-state proof point at a doctored copy.
DOCTOR=${HARNESS_DOCTOR:-$REPO/scripts/harness-doctor.sh}
TMP=$(mktemp -d /tmp/doctor-attribution.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
good() { pass=$((pass + 1)); }

# Minimal stand-ins for the doctor's reporting helpers.
WARNS=0
warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }

helper=$(sed -n '/^check_attribution_off() {/,/^}/p' "$DOCTOR")
[ -n "$helper" ] || { echo "FAIL: check_attribution_off not found in $DOCTOR" >&2; exit 1; }
eval "$helper"

# Run in the current shell (not a $( ) subshell) so the WARNS counter the
# doctor's summary relies on is observed to move, not just the text.
expect_warn() {
  local file=$1 label=$2 before=$WARNS out
  check_attribution_off "$file" "$label" > "$TMP/out"
  out=$(cat "$TMP/out")
  if [ "$WARNS" -gt "$before" ] && [[ "$out" == *"WARN: $label"* ]]; then good; else bad "$label: expected a WARN naming the label, got: $out"; fi
}
expect_quiet() {
  local file=$1 label=$2 before=$WARNS out
  check_attribution_off "$file" "$label" > "$TMP/out"
  out=$(cat "$TMP/out")
  if [ "$WARNS" -eq "$before" ] && [ -z "$out" ]; then good; else bad "$label: expected silence, got: $out"; fi
}

# A: planted negative — deprecated key only (the live shape before #820).
printf '%s\n' '{"includeCoAuthoredBy": false, "permissions": {"allow": []}}' > "$TMP/a.json"
expect_warn "$TMP/a.json" "fixture A deprecated-key-only"

# B: the shape #820 lands — deprecated key plus attribution fully off.
printf '%s\n' '{"includeCoAuthoredBy": false, "attribution": {"commit": "", "pr": "", "sessionUrl": false}}' > "$TMP/b.json"
expect_quiet "$TMP/b.json" "fixture B attribution-off"

# F: commit and pr hidden but sessionUrl left at its default (true) — cloud and
# Remote Control commits would still carry the claude.ai link.
printf '%s\n' '{"attribution": {"commit": "", "pr": ""}}' > "$TMP/f.json"
expect_warn "$TMP/f.json" "fixture F sessionUrl-default"

# C: attribution present but re-enabling a commit byline.
printf '%s\n' '{"includeCoAuthoredBy": false, "attribution": {"commit": "Generated with AI", "pr": ""}}' > "$TMP/c.json"
expect_warn "$TMP/c.json" "fixture C commit-byline-set"

# D: unreadable / malformed file must fail closed (warn), never pass silently.
printf '%s\n' '{"attribution": {"commit": ""' > "$TMP/d.json"
expect_warn "$TMP/d.json" "fixture D malformed-json"
expect_warn "$TMP/missing.json" "fixture D2 missing-file"

# E: pr set while commit empty is still a leak (PR bodies).
printf '%s\n' '{"attribution": {"commit": "", "pr": "🤖 Generated with Claude Code"}}' > "$TMP/e.json"
expect_warn "$TMP/e.json" "fixture E pr-byline-set"

echo "harness-doctor-attribution: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
