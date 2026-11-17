#!/usr/bin/env bash
# harness-doctor reads ~/.claude/cache/plugin-update-check.json only while a loaded
# plugin's hooks/hooks.json names plugin-auto-update.js (#670 option 3: the template
# stopped registering it). Without such a plugin, a cache the old template hook left
# behind must not warn forever; with one, a stale cache and a recorded bridge error
# must still warn. Proven by RUNNING the shipped block against a scratch HOME
# (sed-extracted, as doctor-orphan-hook-retired-stub.test.sh does).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required (the block under test needs it)" >&2; exit 1; }

sed -n '/^# The SessionStart plugin-auto-update hook records/,/^echo "== 11\. /p' "$DOCTOR" | sed '$d' > "$TMP/block.sh"
grep -q 'plugin-update-check.json' "$TMP/block.sh" || { echo "FAIL: block extraction failed" >&2; exit 1; }

H=$TMP/home
mkdir -p "$H/.claude/cache" "$H/owner/hooks" "$H/other/hooks"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}/hooks/plugin-auto-update.js\""}]}]}}' > "$H/owner/hooks/hooks.json"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}/hooks/other.js\""}]}]}}' > "$H/other/hooks/hooks.json"
now=$(date +%s)
stale_cache() { printf '{"checked":%s,"bridgeError":"bridge broke"}\n' "$((now - 100 * 3600))" > "$H/.claude/cache/plugin-update-check.json"; }
fresh_cache() { printf '{"checked":%s,"bridgeError":null,"fxBridgeError":null}\n' "$now" > "$H/.claude/cache/plugin-update-check.json"; }
settings_dirs() { jq -n --arg d "$1" '{env:{CLAUDE_CODE_PLUGIN_DIRS:$d}}' > "$H/.claude/settings.json"; }

run_block() {  # $1 = process CLAUDE_CODE_PLUGIN_DIRS ("" leaves it unset)
  ( export HOME=$H
    unset CLAUDE_CODE_PLUGIN_DIRS
    [ -n "$1" ] && export CLAUDE_CODE_PLUGIN_DIRS=$1
    WARNS=0
    warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
    ok()   { echo "  ok: $*"; }
    # shellcheck disable=SC1090
    . "$TMP/block.sh" 2>&1 )
}

# 1. No plugin runs the hook: a stale cache with a recorded error says nothing.
settings_dirs '$HOME/other'; stale_cache
out=$(run_block "")
case $out in *WARN*) bad "no loaded plugin runs the hook, yet the old cache warned:"$'\n'"$out" ;; *) ok_ ;; esac

# 2. The settings env loads a plugin that runs it (literal $HOME form, as the
#    template spells it): the stale cache and the bridge error both warn.
settings_dirs '$HOME/other:$HOME/owner'; stale_cache
out=$(run_block "")
case $out in *"cache is stale"*) ok_ ;; *) bad "a stale cache with a writer did not warn:"$'\n'"$out" ;; esac
case $out in *"codex bridge failed on last run: bridge broke"*) ok_ ;; *) bad "the recorded bridge error was not named:"$'\n'"$out" ;; esac

# 3. The process env alone loads it (absolute path), the cache is fresh and clean.
settings_dirs ''; fresh_cache
out=$(run_block "$H/owner")
case $out in *WARN*) bad "a fresh clean cache warned:"$'\n'"$out" ;; *) ok_ ;; esac
case $out in *"recorded no errors (cache fresh)"*) ok_ ;; *) bad "expected the ok line:"$'\n'"$out" ;; esac

# 4. Planted: the process env names only a plugin with a different hook.
settings_dirs ''; stale_cache
out=$(run_block "$H/other")
case $out in *WARN*) bad "a plugin without the hook counted as a writer:"$'\n'"$out" ;; *) ok_ ;; esac

echo "doctor-plugin-update-cache-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
