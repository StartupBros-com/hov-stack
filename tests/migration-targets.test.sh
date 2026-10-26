#!/usr/bin/env bash
# Hermetic contract test for the sourceable migration target registry.
set -euo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REGISTRY="$HERE/scripts/migration-targets.sh"
APPLY="$HERE/scripts/migration-apply.sh"
[ -f "$REGISTRY" ] || { echo "FAIL: registry not found at $REGISTRY" >&2; exit 1; }
[ -f "$APPLY" ] || { echo "FAIL: apply controller not found at $APPLY" >&2; exit 1; }

HOME=/fixture-home
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The repository and app/ref map are overlay data; this suite supplies its own fixture map.
TARGET_TABLE='acme-web:abcdefghijklmnopqrst
acme-shop:bcdefghijklmnopqrstu
acme-partners:cdefghijklmnopqrstuv
acme-help:defghijklmnopqrstuvw'
HOV_STACK_MIGRATION_TARGETS_FILE="$TMP/migration-targets.json"
export HOV_STACK_MIGRATION_TARGETS_FILE
printf '%s\n' "$TARGET_TABLE" | jq -R -s \
  '{repository: "acme-org/app", apps: (split("\n") | map(select(length > 0) | split(":") | {(.[0]): .[1]}) | add)}' \
  >"$HOV_STACK_MIGRATION_TARGETS_FILE"
jq --slurpfile fixture "$HERE/tests/fixtures/migration-targets.json" \
  '.legacy_identities = $fixture[0].legacy_identities' "$HOV_STACK_MIGRATION_TARGETS_FILE" >"$TMP/targets.json"
mv "$TMP/targets.json" "$HOV_STACK_MIGRATION_TARGETS_FILE"
# shellcheck source=/dev/null
. "$REGISTRY"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ "$(migration_default_repo)" = "/fixture-home/SITES/app" ] \
  || fail "default repository is not HOME/SITES/app"

expected_apps='acme-web acme-shop acme-partners acme-help'
expected_entries=$TARGET_TABLE
[ "$(migration_target_apps | paste -sd' ' -)" = "$expected_apps" ] \
  || fail "supported app set differs from '$expected_apps'"
[ "$(migration_target_entries)" = "$expected_entries" ] \
  || fail "migration target entries differ from reviewed app/ref set"

expected_config=$(printf 'repo=/fixture-home/SITES/app\n%s\n' "$expected_entries")
[ "$(HOME=/fixture-home MIGRATION_CONFIG_ONLY=1 bash "$APPLY")" = "$expected_config" ] \
  || fail "apply controller does not consume the maintained default checkout and registry"
apply_override=$(HOME=/fixture-home REPO=/override MIGRATION_CONFIG_ONLY=1 bash "$APPLY")
[ "${apply_override%%$'\n'*}" = 'repo=/override' ] \
  || fail "apply controller REPO override no longer wins"

while IFS=: read -r app ref; do
  [ "$(migration_target_ref "$app")" = "$ref" ] \
    || fail "$app does not resolve to $ref"
done <<<"$TARGET_TABLE"

# The shipped example parses as a target map, and a missing map fails closed naming the variable.
[ "$(HOV_STACK_MIGRATION_TARGETS_FILE="$HERE/config/migration-targets.example.json" migration_target_apps | paste -sd' ' -)" = "$expected_apps" ] \
  || fail "shipped example target map does not list the expected apps"
if missing_err=$(HOV_STACK_MIGRATION_TARGETS_FILE="$TMP/absent.json" migration_default_repo 2>&1 >/dev/null); then
  fail "missing target map unexpectedly resolved"
fi
case "$missing_err" in
  *HOV_STACK_MIGRATION_TARGETS_FILE*) ;;
  *) fail "missing target map message does not name HOV_STACK_MIGRATION_TARGETS_FILE" ;;
esac

if migration_target_ref unknown >/dev/null 2>&1; then
  fail "unknown app unexpectedly resolves to a project ref"
fi

check_legacy() {
  local app="$1" version="$2" remote="$3" local_name="$4"
  [ "$(migration_legacy_identity "$app" "$version")" = "$remote"$'\t'"$local_name" ] \
    || fail "legacy identity differs for $app:$version"
}
check_legacy acme-web 20250501000003 create_example_1 'create_example_1 copy'
check_legacy acme-web 20250823000000 create_example_2 create_example_2_copy
check_legacy acme-web 20250829000000 create_example_3 create_example_3_copy
check_legacy acme-web 20261462000000 create_example_4 create_example_4_copy
check_legacy acme-web 20261471000000 create_example_5 create_example_5_copy
check_legacy acme-web 20270610000100 create_example_6 create_example_6_copy
check_legacy acme-shop 20260331030000 create_example_7 create_example_7_copy
check_legacy acme-help 20260805000300 '<unnamed>' create_example_8_copy
check_legacy acme-help 20260805000400 '<unnamed>' create_example_9_copy
check_legacy acme-help 20260806000100 '<unnamed>' create_example_10_copy
check_legacy acme-help 20260806000200 '<unnamed>' create_example_11_copy
check_legacy acme-help 20260806000300 '<unnamed>' create_example_12_copy

if migration_legacy_identity acme-partners 20990101000000 >/dev/null 2>&1; then
  fail "unknown legacy identity unexpectedly resolves"
fi

[ "$(jq '[.legacy_identities[][]] | length' "$HOV_STACK_MIGRATION_TARGETS_FILE")" = 12 ] \
  || fail "registry legacy identity count differs from the 12 reviewed rows"

for absent in "$TMP/absent.json" "$HERE/config/supabase-projects.example.json"; do
  if HOV_STACK_MIGRATION_TARGETS_FILE="$absent" migration_legacy_identity acme-web 20250501000003; then
    fail "missing file or legacy_identities key unexpectedly resolved"
  fi
done

# Fail-closed: without a map, the list and lookup accessors return non-zero, print nothing on
# stdout, and name the missing path and the variable on stderr (a loop over a failed query
# used to answer an empty list at exit 0).
MISSING_DIR=$(mktemp -d "$TMP/empty.XXXXXX")
missing_err="$TMP/missing.err"
without_map() { unset HOV_STACK_MIGRATION_TARGETS_FILE; "$@"; } # runs inside the $( ) subshell
without_overlay() { unset HOV_STACK_MIGRATION_TARGETS_FILE HOV_STACK_OVERLAY; "$@"; } # the XDG default
if out=$(XDG_CONFIG_HOME="$MISSING_DIR" without_overlay migration_target_apps 2>"$missing_err"); then
  fail "migration_target_apps succeeded without a target map"
fi
[ -z "$out" ] || fail "migration_target_apps printed an app list without a target map: $out"
grep -q -F "no target map at $MISSING_DIR/hov-stack/migration-targets.json" "$missing_err" \
  || fail "missing-map message does not name the expected path: $(cat "$missing_err")"
grep -q -F "HOV_STACK_MIGRATION_TARGETS_FILE" "$missing_err" \
  || fail "missing-map message does not name the variable: $(cat "$missing_err")"
if out=$(XDG_CONFIG_HOME="$MISSING_DIR" without_overlay migration_target_ref acme-help 2>/dev/null); then
  fail "migration_target_ref resolved an app without a target map"
fi
[ -z "$out" ] || fail "migration_target_ref printed a ref without a target map: $out"
# A malformed map fails the same way (not an empty list).
printf '%s\n' '{"apps": "not-an-object"}' >"$TMP/malformed.json"
if HOV_STACK_MIGRATION_TARGETS_FILE="$TMP/malformed.json" migration_target_apps >/dev/null 2>&1; then
  fail "migration_target_apps succeeded on a malformed target map"
fi
# The overlay directory holds the map when the variable is unset: HOV_STACK_OVERLAY first, then
# $XDG_CONFIG_HOME/hov-stack, the same order as the other overlay readers; the explicit variable
# still wins over both, and an overlay without the map fails closed naming the overlay path
# rather than falling through to the XDG directory.
OVERLAY=$(mktemp -d "$TMP/overlay.XXXXXX")
cp "$HOV_STACK_MIGRATION_TARGETS_FILE" "$OVERLAY/migration-targets.json"
XDG_DIR=$(mktemp -d "$TMP/xdg.XXXXXX")
mkdir -p "$XDG_DIR/hov-stack"
cp "$HOV_STACK_MIGRATION_TARGETS_FILE" "$XDG_DIR/hov-stack/migration-targets.json"
[ "$(HOV_STACK_OVERLAY="$OVERLAY" XDG_CONFIG_HOME="$MISSING_DIR" without_map migration_targets_file)" = "$OVERLAY/migration-targets.json" ] \
  || fail "HOV_STACK_OVERLAY does not select the overlay's map"
[ "$(HOV_STACK_OVERLAY="$OVERLAY" XDG_CONFIG_HOME="$MISSING_DIR" without_map migration_target_apps | paste -sd' ' -)" = "$expected_apps" ] \
  || fail "the overlay's map does not resolve the app set"
[ "$(XDG_CONFIG_HOME="$XDG_DIR" without_overlay migration_targets_file)" = "$XDG_DIR/hov-stack/migration-targets.json" ] \
  || fail "without HOV_STACK_OVERLAY the map is not read from XDG_CONFIG_HOME/hov-stack"
[ "$(XDG_CONFIG_HOME="$XDG_DIR" without_overlay migration_target_ref acme-help)" = "$(migration_target_ref acme-help)" ] \
  || fail "the XDG map does not resolve a ref"
[ "$(HOV_STACK_OVERLAY="$OVERLAY" XDG_CONFIG_HOME="$XDG_DIR" HOV_STACK_MIGRATION_TARGETS_FILE="$TMP/explicit.json" migration_targets_file)" = "$TMP/explicit.json" ] \
  || fail "HOV_STACK_MIGRATION_TARGETS_FILE no longer wins over the overlay"
EMPTY_OVERLAY=$(mktemp -d "$TMP/empty-overlay.XXXXXX")
if out=$(HOV_STACK_OVERLAY="$EMPTY_OVERLAY" XDG_CONFIG_HOME="$XDG_DIR" without_map migration_target_apps 2>"$missing_err"); then
  fail "an overlay without the map fell through to the XDG directory"
fi
[ -z "$out" ] || fail "migration_target_apps printed an app list from an empty overlay: $out"
grep -q -F "no target map at $EMPTY_OVERLAY/migration-targets.json" "$missing_err" \
  || fail "the empty-overlay message does not name the overlay path: $(cat "$missing_err")"
# The shipped example parses through the same accessors (its refs are 20 lowercase letters).
[ "$(HOV_STACK_MIGRATION_TARGETS_FILE="$HERE/config/migration-targets.example.json" migration_target_apps | sort | paste -sd, -)" = "acme-help,acme-partners,acme-shop,acme-web" ] \
  || fail "the example map does not parse through migration_target_apps"
[ "$(HOV_STACK_MIGRATION_TARGETS_FILE="$HERE/config/migration-targets.example.json" migration_origin_repo)" = "acme-org/app" ] \
  || fail "the example map's repository does not parse"

echo "ok — migration targets: default + 4 mappings + 12 exact legacy identities + unknown rejection + missing/malformed map fails closed + overlay then XDG resolution + example parses"
