#!/usr/bin/env bash
# Tests notes_summary() extraction, fallback visibility, and endpoint UTF-16 limits.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$HERE")")"
PASS=0
FAIL=0
export REPOSITORY="stub-plugin" RELEASE_TAG="v1.2.3"
# shellcheck source=/dev/null
source "$REPO_ROOT/release/scripts/tool-drop-announce.sh"

report() {
  if [[ "$2" == 0 ]]; then
    printf 'ok - %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

(
  CURRENT_RELEASE_NOTES=$'## Highlights\n\n- feat: first thing\n- second thing\n- third thing\n- fourth thing\n\n## Details\nprose here'
  export CURRENT_RELEASE_NOTES
  out="$(notes_summary 2>/dev/null)"
  [[ "$(printf '%s' "$out" | wc -l)" == 2 ]] || exit 1
  grep -q '^first thing$' <<<"$out" || exit 1
  ! grep -q 'fourth thing\|prose here' <<<"$out" || exit 1
)
report "Highlights bullets are capped at three and prefixes are stripped" $?

(
  CURRENT_RELEASE_NOTES=$'Born from a live outage: the thing wedged mid-session.\n\nMore detail below.'
  export CURRENT_RELEASE_NOTES
  err_file="$(mktemp)" || exit 1
  out="$(notes_summary 2>"$err_file")"
  grep -q 'Born from a live outage' <<<"$out" || exit 1
  grep -q '::warning title=No release highlights::' "$err_file" || exit 1
  grep -q 'stub-plugin v1.2.3' "$err_file" || exit 1
)
report "prose fallback emits a visible warning" $?

(
  CURRENT_RELEASE_NOTES=$'## What\'s Changed\n* fix: a real fix by @someone in https://github.com/o/r/pull/1\n\n**Full Changelog**: https://example.invalid'
  export CURRENT_RELEASE_NOTES
  [[ "$(notes_summary 2>/dev/null)" == "a real fix" ]]
)
report "What's Changed bullets strip author and URL noise" $?

(
  CURRENT_RELEASE_NOTES=""
  export CURRENT_RELEASE_NOTES
  [[ -z "$(notes_summary 2>/dev/null)" ]]
)
report "empty release body yields an empty summary" $?

(
  CURRENT_RELEASE_NOTES="$(python3 -c 'print("😀" * 301, end="")')"
  export CURRENT_RELEASE_NOTES
  out="$(notes_summary 2>/dev/null)"
  python3 - "$out" <<'PY'
import sys
value = sys.argv[1]
assert len(value) == 300
assert len(value.encode("utf-16-le")) // 2 == 600
PY
)
report "astral prose is bounded to 600 JavaScript UTF-16 units" $?

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
