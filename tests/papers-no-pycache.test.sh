#!/usr/bin/env bash
# Hermetic regression test for the papers entry-point overlay. A scratch local
# paper_search_lib proves the bytecode flag is set before import and preserves
# upstream main()/SystemExit behavior without touching an installed skill tree.
set -uo pipefail

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OVERLAY=$CLAUDE_DIR/skills-patches/papers/scripts/paper_search.py
[ -f "$OVERLAY" ] || { echo "FAIL: papers overlay not found at $OVERLAY" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SKILL=$TMP/home/.claude/skills/papers
ENTRYPOINT=$SKILL/scripts/paper_search.py
mkdir -p "$SKILL/scripts/paper_search_lib"
cp "$OVERLAY" "$ENTRYPOINT"

cat >"$SKILL/scripts/paper_search_lib/__init__.py" <<'PY'
import sys

if not sys.dont_write_bytecode:
    raise RuntimeError("paper_search.py imported the local library before disabling bytecode")


def main():
    if sys.argv[1:] == ["--help"]:
        print("fake papers help")
        return 0
    if sys.argv[1:] == ["--probe-exit"]:
        return 23
    return 64
PY

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

if cmp -s "$OVERLAY" "$ENTRYPOINT"; then ok; else bad "scratch entry point differs from repository overlay"; fi

# -E ignores ambient PYTHON* variables and -S avoids sitecustomize, so only the
# entry point itself can suppress cache writes before the local import.
help_out=$(HOME="$TMP/home" python3 -E -S "$ENTRYPOINT" --help 2>&1)
help_rc=$?
if [ "$help_rc" -eq 0 ]; then ok; else bad "--help exited $help_rc: $help_out"; fi
if [ "$help_out" = "fake papers help" ]; then ok; else bad "--help output differs: $help_out"; fi

probe_out=$(HOME="$TMP/home" python3 -E -S "$ENTRYPOINT" --probe-exit 2>&1)
probe_rc=$?
if [ "$probe_rc" -eq 23 ]; then ok; else bad "main return was not propagated (exit $probe_rc): $probe_out"; fi
if [ -z "$probe_out" ]; then ok; else bad "exit probe unexpectedly wrote output: $probe_out"; fi

pycache_dir=$(find "$SKILL" -type d -name __pycache__ -print -quit)
pyc_file=$(find "$SKILL" -type f -name '*.pyc' -print -quit)
if [ -z "$pycache_dir" ]; then ok; else bad "__pycache__ created at $pycache_dir"; fi
if [ -z "$pyc_file" ]; then ok; else bad "bytecode file created at $pyc_file"; fi

assertion_floor=7
assertion_total=$((pass + fail))
if [ "$assertion_total" -lt "$assertion_floor" ]; then
  bad "assertion floor: ran $assertion_total, expected at least $assertion_floor"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — papers no-pycache: $pass/$((pass + fail)) assertions passed (floor $assertion_floor)"
else
  echo "FAIL — papers no-pycache: $fail of $((pass + fail)) assertions failed (floor $assertion_floor)" >&2
  exit 1
fi
