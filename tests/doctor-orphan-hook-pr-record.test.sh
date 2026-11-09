#!/usr/bin/env bash
# harness-doctor check 8 (orphaned hook files) must not flag the retired,
# deliberately unregistered no-op hooks/PostToolUse/pr-record.js, and must still
# flag every other unreferenced hook, including a same-named file in another
# event directory. Proven by RUNNING the shipped section 8 against a scratch HOME
# (sed-extracted, same approach as doctor-papercut-coverage-and-stray-git.test.sh).
# Delete this test with the pr-record exception in harness-doctor.sh once
# hooks/PostToolUse/pr-record.js itself is deleted.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-orphan-prrec-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

sed -n '/^echo "== 8\. /,/^echo "== 8a\. /p' "$DOCTOR" | sed '$d' > "$TMP/check8.sh"
grep -q 'orphaned hooks' "$TMP/check8.sh" || { echo "FAIL: check 8 extraction failed" >&2; exit 1; }

HOME_DIR=$TMP/home
mkdir -p "$HOME_DIR/.claude/hooks/PostToolUse" "$HOME_DIR/.claude/hooks/PreToolUse" "$HOME_DIR/.claude/scripts"
echo '{}' > "$HOME_DIR/.claude/settings.json"
: > "$HOME_DIR/.claude/hooks/PostToolUse/pr-record.js"

run_check() {
  ( export HOME=$HOME_DIR
    unset CLAUDE_INSTALLED_PLUGINS
    WARNS=0
    warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
    ok()   { echo "  ok: $*"; }
    # shellcheck disable=SC1090
    . "$TMP/check8.sh" 2>&1 )
}

# 1. pr-record alone: no warning.
out=$(run_check)
case $out in *WARN*) bad "retired pr-record no-op still warns:"$'\n'"$out" ;; *) ok_ ;; esac
case $out in *"no orphaned hooks"*) ok_ ;; *) bad "expected the ok line:"$'\n'"$out" ;; esac

# 2. Planted negatives: an unexpected file beside it, and a same-named file in
#    another event directory, both still warn; pr-record stays quiet.
: > "$HOME_DIR/.claude/hooks/PostToolUse/stray-hook.js"
: > "$HOME_DIR/.claude/hooks/PreToolUse/pr-record.js"
out=$(run_check)
case $out in *"PostToolUse/stray-hook.js"*) ok_ ;; *) bad "unexpected orphan did not warn:"$'\n'"$out" ;; esac
case $out in *"PreToolUse/pr-record.js"*) ok_ ;; *) bad "same-named pr-record.js in another dir did not warn:"$'\n'"$out" ;; esac
case $out in *"PostToolUse/pr-record.js"*) bad "retired pr-record warned alongside others:"$'\n'"$out" ;; *) ok_ ;; esac

echo "doctor-orphan-hook-pr-record: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
