#!/usr/bin/env bash

# Exercise DCG's real hook protocols. Candidate commands are passed as JSON
# strings to DCG and are never evaluated by a shell.
set -euo pipefail

DCG_BIN=${DCG_BIN:-$HOME/.local/bin/dcg}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$DCG_BIN" ] || fail "DCG binary is not executable: $DCG_BIN"
command -v jq >/dev/null 2>&1 || fail "jq is required"

claude_payload='{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"tool_use_id":"call-1"}'
set +e
printf '%s\n' "$claude_payload" | env -i \
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" DCG_CONFIG=/dev/null PATH=/usr/bin:/bin \
  "$DCG_BIN" >"$TMP/claude.out" 2>"$TMP/claude.err"
claude_status=$?
set -e
if [ "$claude_status" -ne 0 ]; then
  echo "Claude stdout:" >&2
  sed -n '1,20p' "$TMP/claude.out" >&2
  echo "Claude stderr:" >&2
  sed -n '1,20p' "$TMP/claude.err" >&2
  fail "Claude protocol returned $claude_status instead of 0"
fi
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/claude.out" >/dev/null ||
  fail "Claude protocol did not emit a structured denial"

codex_payload='{"session_id":"s","turn_id":"turn-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"tool_use_id":"call-1"}'
set +e
printf '%s\n' "$codex_payload" | env -i \
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" DCG_CONFIG=/dev/null PATH=/usr/bin:/bin \
  "$DCG_BIN" >"$TMP/codex.out" 2>"$TMP/codex.err"
codex_status=$?
set -e
# dcg 0.9.2 unified the two hook protocols: a Codex payload (turn_id present) now
# gets the SAME structured-JSON denial on stdout at exit 0 that Claude gets, not
# the old exit-2 + stderr-only shape this test was written against in 0.6.5.
# It still branches on the payload -- the Codex reply is deliberately trimmed
# (no allowOnceCode / ruleId / severity / remediation), which is how we know the
# differentiation is intentional rather than the Codex path having been lost.
# Asserted below: the DECISION must still be deny, and the reply must stay trimmed.
if [ "$codex_status" -ne 0 ]; then
  echo "Codex stdout:" >&2
  sed -n '1,20p' "$TMP/codex.out" >&2
  echo "Codex stderr:" >&2
  sed -n '1,20p' "$TMP/codex.err" >&2
  fail "Codex protocol returned $codex_status instead of 0"
fi
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/codex.out" >/dev/null ||
  fail "Codex protocol did not emit a structured denial"
jq -e '.hookSpecificOutput.permissionDecisionReason | test("BLOCKED by dcg")' "$TMP/codex.out" >/dev/null ||
  fail "Codex denial omitted its block reason"
jq -e '.hookSpecificOutput | has("allowOnceCode") | not' "$TMP/codex.out" >/dev/null ||
  fail "Codex reply is no longer trimmed — protocol branching may have been lost"

safe_payload='{"session_id":"s","turn_id":"turn-2","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"tool_use_id":"call-2"}'
printf '%s\n' "$safe_payload" | env -i \
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" DCG_CONFIG=/dev/null PATH=/usr/bin:/bin \
  "$DCG_BIN" >"$TMP/safe.out" 2>"$TMP/safe.err" ||
  fail "safe Codex protocol probe was not allowed"
[ ! -s "$TMP/safe.out" ] || fail "safe probe wrote unexpected stdout"

repo=$TMP/sentinel-repo
git init -q "$repo"
printf '%s\n' modified-but-preserved >"$repo/sentinel.txt"
before_hash=$(sha256sum "$repo/sentinel.txt")
before_status=$(git -C "$repo" status --porcelain)
set +e
(cd "$repo" && printf '%s\n' "$claude_payload" | env -i \
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" DCG_CONFIG=/dev/null PATH=/usr/bin:/bin \
  "$DCG_BIN" >"$TMP/sentinel.out" 2>"$TMP/sentinel.err")
sentinel_status=$?
set -e
[ "$sentinel_status" -eq 0 ] || fail "sentinel classification returned $sentinel_status"
[ "$before_hash" = "$(sha256sum "$repo/sentinel.txt")" ] || fail "sentinel content changed"
[ "$before_status" = "$(git -C "$repo" status --porcelain)" ] || fail "repository state changed"

echo "DCG Claude/Codex protocol and unchanged-repository sentinel tests passed"
