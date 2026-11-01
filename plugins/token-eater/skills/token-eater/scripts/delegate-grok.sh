#!/usr/bin/env bash
# delegate-grok.sh — run ONE token-eater chore on the grok adapter and derive a
# trustworthy result from ground truth (git-observed changes + scope check),
# treating grok's self-report as best-effort only.
#
# Why: grok's --json-schema is soft. In practice it returns .structuredOutput=null
# and buries its result in a ```json fence inside .text (often with a non-enum
# status). So we DERIVE files_modified from git and let the caller's gate decide
# keep/rollback. grok's job is to make the edits; we observe what it did.
#
# Usage:
#   delegate-grok.sh <worktree-dir> <prompt-file> [schema-file] [allowed-files-file]
#     worktree-dir       a git worktree the chore runs in (its diff is the ground truth)
#     prompt-file        the scope-fenced chore prompt
#     schema-file        optional: JSON schema to pass inline via --json-schema
#     allowed-files-file optional: newline list of repo-relative paths grok may modify;
#                        any change outside the list is a scope violation
#
# Emits a JSON object on stdout. Exit codes:
#   0 ok            grok ran and produced a parseable envelope
#   2 invoke-error  grok exited non-zero or no JSON envelope was produced
#   3 circuit-break credit/rate-limit signal detected (caller parks grok — R16)
#   4 scope-viol    grok modified a file outside the allowed list (caller rolls back)
set -euo pipefail

# shellcheck source=skills/token-eater/scripts/lib/delegate-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/delegate-common.sh"
export TOKEN_EATER_DELEGATED=1   # marker so a worker that re-invokes token-eater is refused (recursion guard)

WT="${1:?worktree dir required}"
PROMPT="${2:?prompt file required}"
SCHEMA="${3:-}"
ALLOWED="${4:-}"

[ -d "$WT" ]      || { echo '{"adapter":"grok","ok":false,"error":"worktree not found"}'; exit 2; }
[ -f "$PROMPT" ]  || { echo '{"adapter":"grok","ok":false,"error":"prompt file not found"}'; exit 2; }
command -v grok >/dev/null || { echo '{"adapter":"grok","ok":false,"error":"grok not installed"}'; exit 2; }

WT="$(cd "$WT" && pwd)"
RUNDIR="$(mktemp -d -t te-grok-XXXXXX)"
ENVRAW="$RUNDIR/stdout.json"
ERRLOG="$RUNDIR/stderr.log"
CB_REGEX='(usage limit reached|rate.?limit|out of credits|429|All accounts are temporarily unavailable)'

# --- build + run the verified grok contract, cwd = worktree ---
set +e
if [ -n "$SCHEMA" ] && [ -f "$SCHEMA" ]; then
  ( cd "$WT" && grok --prompt-file "$PROMPT" --json-schema "$(cat "$SCHEMA")" --always-approve ) >"$ENVRAW" 2>"$ERRLOG"
else
  ( cd "$WT" && grok --prompt-file "$PROMPT" --always-approve ) >"$ENVRAW" 2>"$ERRLOG"
fi
GROK_EXIT=$?
set -e

# --- circuit breaker: credit/rate-limit signal anywhere in output ---
if grep -qiE "$CB_REGEX" "$ENVRAW" "$ERRLOG" 2>/dev/null; then
  printf '{"adapter":"grok","ok":false,"circuit_breaker":true,"grok_exit":%s,"raw_envelope":"%s","summary":"grok signalled credit/rate-limit exhaustion"}\n' "$GROK_EXIT" "$ENVRAW"
  exit 3
fi

# --- isolate the JSON envelope (skip any leading warning lines) ---
ENV="$RUNDIR/envelope.json"
awk 'f||/^[[:space:]]*\{/{f=1; print}' "$ENVRAW" > "$ENV"

# --- ground truth: what changed in the worktree (the authoritative file list) ---
delegate_collect_changes_and_scope "$WT" "$ALLOWED"

# --- best-effort self-report from the .text ```json fence (advisory only) ---
STOP_REASON=""; GROK_STATUS=""; ISSUES_JSON="[]"
# Default summary is GROUND TRUTH — grok's prose is inconsistent (fenced JSON, inline
# JSON, or none), so never let it become the summary unless it parses cleanly.
if [ "$MADE_CHANGES" = true ]; then
  SUMMARY="grok modified ${#CHANGED[@]} file(s): ${CHANGED[*]}"
else
  SUMMARY="grok made no changes"
fi
if command -v jq >/dev/null && jq -e . "$ENV" >/dev/null 2>&1; then
  STOP_REASON="$(jq -r '.stopReason // ""' "$ENV")"
  TEXT="$(jq -r '.text // ""' "$ENV")"
  # grok's self-report: a ```json fence first, else a flat inline {...} containing "summary"
  CAND="$(printf '%s' "$TEXT" | awk '/```json/{f=1;next} /```/{f=0} f')"
  [ -n "$CAND" ] && ! printf '%s' "$CAND" | jq -e . >/dev/null 2>&1 && CAND=""
  [ -z "$CAND" ] && CAND="$(printf '%s' "$TEXT" | grep -oE '\{[^{}]*"summary"[^{}]*\}' | tail -1 || true)"
  if [ -n "$CAND" ] && printf '%s' "$CAND" | jq -e . >/dev/null 2>&1; then
    RAWSTATUS="$(printf '%s' "$CAND" | jq -r '.status // ""')"
    case "$RAWSTATUS" in completed|success|ok|done) GROK_STATUS="completed";; partial) GROK_STATUS="partial";; failed|error) GROK_STATUS="failed";; *) GROK_STATUS="$RAWSTATUS";; esac
    GSUM="$(printf '%s' "$CAND" | jq -r '.summary // ""')"
    [ -n "$GSUM" ] && SUMMARY="$GSUM"
    ISSUES_JSON="$(printf '%s' "$CAND" | jq -c '(.issues // []) | if type=="array" then . else [] end')"
  fi
fi

# --- assemble the derived result (status/verification are the caller's gate job) ---
if command -v jq >/dev/null; then
  jq -n \
    --arg adapter grok \
    --argjson ok true \
    --argjson cb false \
    --argjson made "$MADE_CHANGES" \
    --argjson scope "$SCOPE_VIOLATION" \
    --arg stop "$STOP_REASON" \
    --arg gstatus "$GROK_STATUS" \
    --arg summary "$SUMMARY" \
    --argjson issues "$ISSUES_JSON" \
    --arg raw "$ENV" \
    --argjson files "$(printf '%s\n' ${CHANGED[@]+"${CHANGED[@]}"} | jq -R . | jq -s 'map(select(length>0))')" \
    --argjson offenders "$(printf '%s\n' ${OFFENDERS[@]+"${OFFENDERS[@]}"} | jq -R . | jq -s 'map(select(length>0))')" \
    '{adapter:$adapter, ok:$ok, circuit_breaker:$cb, made_changes:$made, files_modified:$files,
      scope_violation:$scope, scope_offenders:$offenders, stop_reason:$stop,
      grok_self_status:$gstatus, summary:$summary, issues:$issues, raw_envelope:$raw}'
else
  printf '{"adapter":"grok","ok":true,"circuit_breaker":false,"made_changes":%s,"scope_violation":%s,"summary":"(install jq for full parsing)","raw_envelope":"%s"}\n' "$MADE_CHANGES" "$SCOPE_VIOLATION" "$ENV"
fi

[ "$SCOPE_VIOLATION" = true ] && exit 4
exit 0
