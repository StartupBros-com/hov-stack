#!/usr/bin/env bash
# Exercise real sync writes only in disposable homes. Each negative is independent.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
export SETTINGS_APPLY_TREE=${SETTINGS_APPLY_TREE:-$HERE}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMPDIR=$TMP
source_state() {
  { git -C "$SETTINGS_APPLY_TREE" diff --binary 2>/dev/null; git -C "$SETTINGS_APPLY_TREE" status --short 2>/dev/null; } | sha256sum
}
before=$(source_state)
node "$HERE/tests/settings-apply-integration.js"
status=$?
if [ "$(source_state)" != "$before" ]; then
  echo 'FAIL: settings apply tests modified the selected checkout' >&2
  exit 1
fi
exit "$status"
