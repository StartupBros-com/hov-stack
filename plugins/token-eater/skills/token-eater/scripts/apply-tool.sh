#!/usr/bin/env bash
# apply-tool.sh <worktree> <fixer-command> [allowed-files-file]
#
# Run a DETERMINISTIC fixer directly — `prettier --write`, `eslint --fix`, `ruff --fix`,
# `ruff format`, `gofmt -w`, etc. No model, no credits, zero model-error risk. Use this
# instead of a delegate-*.sh runner for chores a tool performs perfectly (formatting,
# lint --fix). The credit-burn belongs on JUDGMENT chores (dead-code, deslop, refactor),
# not on work a tool already does correctly.
#
# Emits the SAME JSON result shape + exit codes as the delegate-*.sh runners, so the harvest
# loop treats it identically and the deterministic gate still decides keep/rollback:
#   0 ok | 2 invoke-error (fixer failed) | 4 scope-violation (touched a file outside the list)
set -euo pipefail

WT="${1:?worktree dir required}"
FIXER="${2:?fixer command required, e.g. 'pnpm exec prettier --write .'}"
ALLOWED="${3:-}"

[ -d "$WT" ] || { echo '{"adapter":"tool","ok":false,"error":"worktree not found"}'; exit 2; }
WT="$(cd "$WT" && pwd)"
RUNDIR="$(mktemp -d -t te-tool-XXXXXX)"; LOG="$RUNDIR/log"

# run the fixer in the worktree
set +e
( cd "$WT" && eval "$FIXER" ) >"$LOG" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  printf '{"adapter":"tool","ok":false,"made_changes":false,"summary":"fixer exited %s; see %s","fixer":"%s"}\n' "$RC" "$LOG" "$FIXER"
  exit 2
fi

# ground truth: what changed (skip symlinks, like the delegate runners)
mapfile -t CHANGED < <(cd "$WT" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u | grep -v '^$' | while IFS= read -r f; do [ -L "$f" ] || printf '%s\n' "$f"; done)
MADE=false; [ "${#CHANGED[@]}" -gt 0 ] && MADE=true

SCOPE=false; OFF=()
if [ -n "$ALLOWED" ] && [ -f "$ALLOWED" ] && [ "$MADE" = true ]; then
  for f in "${CHANGED[@]}"; do
    grep -qxF "$f" "$ALLOWED" || { SCOPE=true; OFF+=("$f"); }
  done
fi
if [ "$MADE" = true ]; then SUMMARY="ran '$FIXER'; changed ${#CHANGED[@]} file(s)"; else SUMMARY="ran '$FIXER'; no changes needed"; fi

if command -v jq >/dev/null; then
  jq -n --arg adapter tool --argjson ok true --argjson made "$MADE" --argjson scope "$SCOPE" \
     --arg fixer "$FIXER" --arg summary "$SUMMARY" \
     --argjson files "$(printf '%s\n' "${CHANGED[@]}" | jq -R . | jq -s 'map(select(length>0))')" \
     --argjson off "$(printf '%s\n' "${OFF[@]}" | jq -R . | jq -s 'map(select(length>0))')" \
     '{adapter:$adapter, ok:$ok, made_changes:$made, files_modified:$files, scope_violation:$scope, scope_offenders:$off, fixer:$fixer, summary:$summary}'
else
  printf '{"adapter":"tool","ok":true,"made_changes":%s,"scope_violation":%s,"summary":"%s"}\n' "$MADE" "$SCOPE" "$SUMMARY"
fi

[ "$SCOPE" = true ] && exit 4
exit 0
