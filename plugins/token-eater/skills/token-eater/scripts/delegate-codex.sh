#!/usr/bin/env bash
# delegate-codex.sh — run ONE token-eater chore on the codex adapter.
#
# codex enforces the schema (--output-schema) and writes a trustworthy 5-field
# result to its -o file, so its self-report is reliable. We STILL derive
# files_modified from git (ground truth) and enforce the scope fence against it —
# defense in depth — and the deterministic gate stays authoritative for keep/rollback.
#
# Usage:
#   delegate-codex.sh <worktree-dir> <prompt-file> <schema-file> [allowed-files-file]
#
# Emits a JSON object on stdout. Exit codes (same contract as delegate-grok.sh):
#   0 ok   2 invoke-error   3 circuit-breaker (park)   4 scope-violation (rollback)
set -euo pipefail

# shellcheck source=skills/token-eater/scripts/lib/delegate-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/delegate-common.sh"
export TOKEN_EATER_DELEGATED=1   # marker so a worker that re-invokes token-eater is refused (recursion guard)

WT="${1:?worktree dir required}"
PROMPT="${2:?prompt file required}"
SCHEMA="${3:-}"          # OPTIONAL: the self-contained-recipe model passes no schema (codex runs the recipe
                        # agentically and opens its own draft PR). When given, structured output is enforced.
ALLOWED="${4:-}"

[ -d "$WT" ]     || { echo '{"adapter":"codex","ok":false,"error":"worktree not found"}'; exit 2; }
[ -f "$PROMPT" ] || { echo '{"adapter":"codex","ok":false,"error":"prompt file not found"}'; exit 2; }
[ -z "$SCHEMA" ] || [ -f "$SCHEMA" ] || { echo '{"adapter":"codex","ok":false,"error":"schema file not found"}'; exit 2; }
command -v codex >/dev/null || { echo '{"adapter":"codex","ok":false,"error":"codex not installed"}'; exit 2; }

WT="$(cd "$WT" && pwd)"
RUNDIR="$(mktemp -d -t te-codex-XXXXXX)"
RESULT="$RUNDIR/result.json"; STDOUT="$RUNDIR/stdout.log"; ERRLOG="$RUNDIR/stderr.log"
CB_REGEX='(usage limit reached|rate.?limit|429 too many requests|All accounts are temporarily unavailable)'

# --- run the codex contract, cwd = worktree (output-schema only if supplied) ---
SCHEMA_ARGS=(); [ -n "$SCHEMA" ] && SCHEMA_ARGS=(--output-schema "$SCHEMA")
set +e
( cd "$WT" && codex exec -s workspace-write ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} -o "$RESULT" - < "$PROMPT" ) >"$STDOUT" 2>"$ERRLOG"
CODEX_EXIT=$?
set -e

# --- circuit breaker: credit/rate-limit signal anywhere in output ---
if grep -qiE "$CB_REGEX" "$STDOUT" "$ERRLOG" 2>/dev/null; then
  printf '{"adapter":"codex","ok":false,"circuit_breaker":true,"codex_exit":%s,"summary":"codex signalled credit/rate-limit exhaustion"}\n' "$CODEX_EXIT"
  exit 3
fi

# --- non-zero exit without a circuit-breaker match is an invoke/CLI failure ---
if [ "$CODEX_EXIT" -ne 0 ] && [ ! -s "$RESULT" ]; then
  printf '{"adapter":"codex","ok":false,"codex_exit":%s,"summary":"codex exited %s with no result; see %s"}\n' "$CODEX_EXIT" "$CODEX_EXIT" "$ERRLOG"
  exit 2
fi

# --- ground truth: what changed in the worktree (authoritative file list) ---
delegate_collect_changes_and_scope "$WT" "$ALLOWED"

# --- codex self-report from the -o result file (reliable when present) ---
SELF_STATUS=""; SUMMARY=""; ISSUES_JSON="[]"; VERIF=""
if [ -s "$RESULT" ] && command -v jq >/dev/null && jq -e . "$RESULT" >/dev/null 2>&1; then
  SELF_STATUS="$(jq -r '.status // ""' "$RESULT")"
  case "$SELF_STATUS" in success|ok|done) SELF_STATUS="completed";; error) SELF_STATUS="failed";; esac
  SUMMARY="$(jq -r '.summary // ""' "$RESULT")"
  ISSUES_JSON="$(jq -c '(.issues // []) | if type=="array" then . else [] end' "$RESULT")"
  VERIF="$(jq -r '.verification_summary // ""' "$RESULT")"
fi
# ground-truth default summary when codex did not give one
if [ -z "$SUMMARY" ]; then
  if [ "$MADE_CHANGES" = true ]; then SUMMARY="codex modified ${#CHANGED[@]} file(s): ${CHANGED[*]}"; else SUMMARY="codex made no changes"; fi
fi

# --- assemble result (status/keep decided by the caller's gate) ---
if command -v jq >/dev/null; then
  jq -n \
    --arg adapter codex --argjson ok true --argjson cb false \
    --argjson made "$MADE_CHANGES" --argjson scope "$SCOPE_VIOLATION" \
    --arg self "$SELF_STATUS" --arg summary "$SUMMARY" --arg verif "$VERIF" \
    --argjson issues "$ISSUES_JSON" --arg raw "$RESULT" \
    --argjson files "$(printf '%s\n' ${CHANGED[@]+"${CHANGED[@]}"} | jq -R . | jq -s 'map(select(length>0))')" \
    --argjson offenders "$(printf '%s\n' ${OFFENDERS[@]+"${OFFENDERS[@]}"} | jq -R . | jq -s 'map(select(length>0))')" \
    '{adapter:$adapter, ok:$ok, circuit_breaker:$cb, made_changes:$made, files_modified:$files,
      scope_violation:$scope, scope_offenders:$offenders, self_status:$self, summary:$summary,
      verification_summary:$verif, issues:$issues, raw_envelope:$raw}'
else
  printf '{"adapter":"codex","ok":true,"circuit_breaker":false,"made_changes":%s,"scope_violation":%s,"summary":"(install jq for full parsing)","raw_envelope":"%s"}\n' "$MADE_CHANGES" "$SCOPE_VIOLATION" "$RESULT"
fi

[ "$SCOPE_VIOLATION" = true ] && exit 4
exit 0
