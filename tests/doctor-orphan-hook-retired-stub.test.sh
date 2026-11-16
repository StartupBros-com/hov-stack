#!/usr/bin/env bash
# harness-doctor check 8 (orphaned hook files) must not flag a retired hook stub, an
# unregistered file marked hov-stack:retired-hook-stub (hooks/PostToolUse/pr-record.js),
# and must still flag every other unreferenced hook, including an unmarked file of the
# same name in another event directory. Proven by RUNNING the shipped section 8 against a
# scratch HOME (sed-extracted, as doctor-papercut-coverage-and-stray-git.test.sh does).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

sed -n '/^echo "== 8\. /,/^echo "== 8a\. /p' "$DOCTOR" | sed '$d' > "$TMP/check8.sh"
grep -q 'orphaned hooks' "$TMP/check8.sh" || { echo "FAIL: check 8 extraction failed" >&2; exit 1; }

HOME_DIR=$TMP/home
mkdir -p "$HOME_DIR/.claude/hooks/PostToolUse" "$HOME_DIR/.claude/hooks/PreToolUse" "$HOME_DIR/.claude/scripts"
echo '{}' > "$HOME_DIR/.claude/settings.json"
cp "$REPO/hooks/PostToolUse/pr-record.js" "$HOME_DIR/.claude/hooks/PostToolUse/pr-record.js"

run_check() {
  ( export HOME=$HOME_DIR
    unset CLAUDE_INSTALLED_PLUGINS
    WARNS=0
    warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
    ok()   { echo "  ok: $*"; }
    # shellcheck disable=SC1090
    . "$TMP/check8.sh" 2>&1 )
}

# 1. The shipped stub alone: no warning.
out=$(run_check)
case $out in *WARN*) bad "the retired stub still warns:"$'\n'"$out" ;; *) ok_ ;; esac
case $out in *"no orphaned hooks"*) ok_ ;; *) bad "expected the ok line:"$'\n'"$out" ;; esac

# 2. Planted negatives: an unmarked file beside it, and an unmarked file of the same
#    name in another event directory, both still warn; the stub stays quiet.
: > "$HOME_DIR/.claude/hooks/PostToolUse/stray-hook.js"
: > "$HOME_DIR/.claude/hooks/PreToolUse/pr-record.js"
out=$(run_check)
case $out in *"PostToolUse/stray-hook.js"*) ok_ ;; *) bad "unexpected orphan did not warn:"$'\n'"$out" ;; esac
case $out in *"PreToolUse/pr-record.js"*) ok_ ;; *) bad "an unmarked pr-record.js in another dir did not warn:"$'\n'"$out" ;; esac
case $out in *"PostToolUse/pr-record.js"*) bad "the retired stub warned alongside others:"$'\n'"$out" ;; *) ok_ ;; esac

echo "doctor-orphan-hook-retired-stub: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
