#!/usr/bin/env bash
# scripts/validate-data.sh must fail closed: malformed JSON or YAML under the given root
# fails the run. Kept from the standalone repo's tests/workflows.test.sh, whose other
# checks tested that repo's own workflow files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/data"
printf '{}\n' > "$TMP/data/good.json"
printf 'good: [yaml]\n' > "$TMP/data/good.yaml"
"$ROOT/scripts/validate-data.sh" "$TMP/data" >/dev/null 2>&1 || fail 'well-formed JSON and YAML pass validation'
pass 'well-formed JSON and YAML pass validation'

printf '{bad json\n' > "$TMP/data/bad.json"
if "$ROOT/scripts/validate-data.sh" "$TMP/data" >/dev/null 2>&1; then
  fail 'malformed JSON fails validation'
fi
pass 'malformed JSON fails validation'

printf '{}\n' > "$TMP/data/bad.json"
printf 'bad: [yaml\n' > "$TMP/data/bad.yaml"
if "$ROOT/scripts/validate-data.sh" "$TMP/data" >/dev/null 2>&1; then
  fail 'malformed YAML fails validation'
fi
pass 'malformed YAML fails validation'

printf 'validate-data: PASS\n'
