#!/usr/bin/env bash
# delegate-claude.sh — run ONE token-eater chore on the claude adapter.
#
# claude enforces the schema and returns it in the stdout envelope's
# .structured_output (reliable). The envelope also reports .total_cost_usd and
# .usage, so this adapter can self-meter spend (useful when no balance oracle is
# present). files_modified + scope are still derived from git (ground truth); the
# deterministic gate stays authoritative for keep/rollback.
#
# Usage:
#   delegate-claude.sh <worktree-dir> <prompt-file> <schema-file> [allowed-files-file]
#
# Emits a JSON object on stdout. Exit codes (same contract as delegate-grok.sh):
#   0 ok   2 invoke-error   3 circuit-breaker (park)   4 scope-violation (rollback)
set -euo pipefail

# shellcheck source=skills/token-eater/scripts/lib/delegate-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/delegate-common.sh"
export TOKEN_EATER_DELEGATED=1   # marker so a worker that re-invokes token-eater is refused (recursion guard)

WT="${1:?worktree dir required}"
PROMPT="${2:?prompt file required}"
SCHEMA="${3:-}"          # OPTIONAL: the new self-contained-recipe model passes no schema (claude runs the
                        # recipe agentically and opens its own draft PR). When given, structured output is enforced.
ALLOWED="${4:-}"

[ -d "$WT" ]     || { echo '{"adapter":"claude","ok":false,"error":"worktree not found"}'; exit 2; }
[ -f "$PROMPT" ] || { echo '{"adapter":"claude","ok":false,"error":"prompt file not found"}'; exit 2; }
[ -z "$SCHEMA" ] || [ -f "$SCHEMA" ] || { echo '{"adapter":"claude","ok":false,"error":"schema file not found"}'; exit 2; }
command -v claude >/dev/null || { echo '{"adapter":"claude","ok":false,"error":"claude not installed"}'; exit 2; }

WT="$(cd "$WT" && pwd)"
RUNDIR="$(mktemp -d -t te-claude-XXXXXX)"
ENVRAW="$RUNDIR/stdout.json"; ERRLOG="$RUNDIR/stderr.log"
CB_REGEX='(usage limit|rate.?limit|429|All accounts are temporarily unavailable)'

# --- run the claude contract, cwd = worktree (inline prompt; schema only if supplied) ---
# Permissions: the recipe REQUIRES Bash (run the gate, git add/commit/push). Under headless
# `-p`, un-allowlisted tools are DENIED (no prompt is possible), so on a fresh user machine
# plain acceptEdits means claude can edit but never run the gate or commit — masked on dev
# boxes whose user settings carry broad Bash allow rules. The explicit allowlist below makes
# behavior deterministic on every host. Bash must be broad because the gate command is
# repo-specific (pnpm/pytest/cargo/make/...), and running the target repo's own code under
# the user's OS account is already token-eater's documented trust boundary (explicit
# --trust-repo consent; grok runs --always-approve, codex workspace-write). This is tighter
# than --dangerously-skip-permissions only in TOOL surface (no WebFetch/WebSearch/MCP) — Bash
# itself can still reach the network and $HOME, exactly like grok's shell and the gate command.
# That shared shell exposure IS the documented v1 trust boundary; OS-level sandboxing
# (bwrap/sandbox-exec) remains the tracked pre-public hardening (DISTRIBUTION-READINESS.md).
SCHEMA_ARGS=(); [ -n "$SCHEMA" ] && SCHEMA_ARGS=(--json-schema "$(cat "$SCHEMA")")
set +e
( cd "$WT" && claude -p "$(cat "$PROMPT")" --output-format json ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
    --permission-mode acceptEdits --allowedTools "Bash" "Skill" "Task" ) >"$ENVRAW" 2>"$ERRLOG"
CLAUDE_EXIT=$?
set -e

if grep -qiE "$CB_REGEX" "$ENVRAW" "$ERRLOG" 2>/dev/null; then
  printf '{"adapter":"claude","ok":false,"circuit_breaker":true,"claude_exit":%s,"summary":"claude signalled credit/rate-limit exhaustion"}\n' "$CLAUDE_EXIT"
  exit 3
fi

# --- isolate the JSON envelope (skip any leading warning lines) ---
ENV="$RUNDIR/envelope.json"
awk 'f||/^[[:space:]]*\{/{f=1; print}' "$ENVRAW" > "$ENV"
if ! { command -v jq >/dev/null && jq -e . "$ENV" >/dev/null 2>&1; }; then
  printf '{"adapter":"claude","ok":false,"claude_exit":%s,"summary":"claude produced no parseable JSON envelope; see %s"}\n' "$CLAUDE_EXIT" "$ERRLOG"
  exit 2
fi

# --- ground truth: what changed in the worktree ---
delegate_collect_changes_and_scope "$WT" "$ALLOWED"

# --- claude self-report from .structured_output (reliable) + spend from envelope ---
SELF_STATUS="$(jq -r '.structured_output.status // ""' "$ENV")"
case "$SELF_STATUS" in success|ok|done) SELF_STATUS="completed";; error) SELF_STATUS="failed";; esac
SUMMARY="$(jq -r '.structured_output.summary // ""' "$ENV")"
ISSUES_JSON="$(jq -c '(.structured_output.issues // []) | if type=="array" then . else [] end' "$ENV")"
VERIF="$(jq -r '.structured_output.verification_summary // ""' "$ENV")"
COST="$(jq -r '.total_cost_usd // 0' "$ENV")"
IS_ERROR="$(jq -r '.is_error // false' "$ENV")"
if [ -z "$SUMMARY" ]; then
  if [ "$MADE_CHANGES" = true ]; then SUMMARY="claude modified ${#CHANGED[@]} file(s): ${CHANGED[*]}"; else SUMMARY="claude made no changes"; fi
fi

jq -n \
  --arg adapter claude --argjson ok true --argjson cb false \
  --argjson made "$MADE_CHANGES" --argjson scope "$SCOPE_VIOLATION" \
  --arg self "$SELF_STATUS" --arg summary "$SUMMARY" --arg verif "$VERIF" \
  --argjson issues "$ISSUES_JSON" --argjson cost "$COST" --argjson iserror "$IS_ERROR" --arg raw "$ENV" \
  --argjson files "$(printf '%s\n' ${CHANGED[@]+"${CHANGED[@]}"} | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson offenders "$(printf '%s\n' ${OFFENDERS[@]+"${OFFENDERS[@]}"} | jq -R . | jq -s 'map(select(length>0))')" \
  '{adapter:$adapter, ok:$ok, circuit_breaker:$cb, made_changes:$made, files_modified:$files,
    scope_violation:$scope, scope_offenders:$offenders, self_status:$self, summary:$summary,
    verification_summary:$verif, issues:$issues, cost_usd:$cost, is_error:$iserror, raw_envelope:$raw}'

[ "$SCOPE_VIOLATION" = true ] && exit 4
exit 0
