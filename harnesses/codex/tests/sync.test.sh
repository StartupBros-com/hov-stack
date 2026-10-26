#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYNC=$HERE/sync.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

export CODEX_HOME=$TMP/codex-home
mkdir -p "$CODEX_HOME"
printf '%s\n' 'model = "sentinel"' >"$CODEX_HOME/config.toml"
cp "$CODEX_HOME/config.toml" "$TMP/config-before.toml"
printf '%s\n' '{"hooks":{"Stop":[]},"liveOnly":true}' >"$CODEX_HOME/hooks.json"

"$SYNC" install >/dev/null
"$SYNC" check >/dev/null || fail "freshly installed hooks did not pass check"
cmp -s "$HERE/hooks.json" "$CODEX_HOME/hooks.json" || fail "canonical hooks were not installed byte-for-byte"
cmp -s "$TMP/config-before.toml" "$CODEX_HOME/config.toml" || fail "config.toml was modified"
[ "$(find "$CODEX_HOME/backups" -name hooks.json -type f | wc -l)" -eq 1 ] ||
  fail "differing hooks did not create exactly one backup"

"$SYNC" install >/dev/null
[ "$(find "$CODEX_HOME/backups" -name hooks.json -type f | wc -l)" -eq 1 ] ||
  fail "idempotent install created another backup"

jq '.unexpected = true' "$CODEX_HOME/hooks.json" >"$TMP/drift.json"
mv "$TMP/drift.json" "$CODEX_HOME/hooks.json"
if "$SYNC" check >/dev/null 2>&1; then
  fail "check did not detect hook drift"
fi

printf '%s\n' '{invalid' >"$CODEX_HOME/hooks.json"
"$SYNC" install >/dev/null
jq -e . "$CODEX_HOME/hooks.json" >/dev/null || fail "invalid live hooks were not safely replaced"
[ "$(find "$CODEX_HOME/backups" -name hooks.json -type f | wc -l)" -eq 2 ] ||
  fail "invalid live hooks were not backed up"
cmp -s "$TMP/config-before.toml" "$CODEX_HOME/config.toml" || fail "config.toml changed during repair"

echo "codex hook sync tests passed"
