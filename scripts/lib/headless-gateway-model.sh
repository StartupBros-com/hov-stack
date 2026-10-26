#!/usr/bin/env bash
# Default managed headless roots to gateway Auto; exact caller routes stay exact.
# The gateway owns quota admission and provider failover, never this launcher.

headless_gateway_model_args() {
  HEADLESS_GATEWAY_MODEL_ARGS=()
  case "${ANTHROPIC_BASE_URL:-}" in
    http://127.0.0.1:8788|http://127.0.0.1:8788/|http://localhost:8788|http://localhost:8788/|http://\[::1\]:8788|http://\[::1\]:8788/) ;;
    *) return 0 ;;
  esac
  local key header
  for key in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS \
    CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY; do
    [ -z "${!key:-}" ] || return 0
  done
  while IFS= read -r header; do
    header=${header%%:*}
    header=${header//[[:space:]]/}
    [ "${header,,}" != x-better-ccflare-account-id ] || return 0
  done <<< "${ANTHROPIC_CUSTOM_HEADERS:-}"
  headless_gateway_scope_allows_auto || return 0
  HEADLESS_GATEWAY_MODEL_ARGS=(--model claude-bccf-quality-auto)
  # Model choice changes, but the operator's existing context opt-in does not.
  if jq -e '.model | type == "string" and endswith("[1m]")' \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" >/dev/null 2>&1; then
    HEADLESS_GATEWAY_MODEL_ARGS[1]+='[1m]'
  fi
}

# This is a conservative opt-out, not a replacement for Claude's resolver.
# A global picker model is inherited UI state; scoped model/transport pins are not.
headless_gateway_scope_allows_auto() {
  local config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" root="$PWD" common file scope
  [ -z "${CLAUDE_CODE_PROJECT_DIR_NAME:-}${CLAUDE_CODE_HOST_GATEWAY_LINEAGE:-}" ] || return 1
  [ ! -e "$config/remote-settings.json" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local -a files=("$config/settings.json" /etc/claude-code/managed-settings.json /etc/claude-code/managed-settings.d/*.json)
  while [ -n "$root" ]; do
    files+=("$root/.claude/settings.json" "$root/.claude/settings.local.json")
    [ "$root" != / ] || break
    root=${root%/*}; [ -n "$root" ] || root=/
  done
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=''
  case "$common" in
    */.git) files+=("${common%/.git}/.claude/settings.json" "${common%/.git}/.claude/settings.local.json") ;;
    '') ;;
    *) return 1 ;;
  esac
  for file in "${files[@]}"; do
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then continue; fi
    [ -f "$file" ] || return 1
    scope=project; [ "$file" != "$config/settings.json" ] || scope=user
    jq -se --arg scope "$scope" --arg base "${ANTHROPIC_BASE_URL%/}" '
      length == 1 and (.[0] | type) == "object" and
      (.[0] | (.env == null or (.env | type) == "object") and
        ($scope == "user" or (has("model") | not)) and
        ((.env // {}) as $env |
          ((($env | has("ANTHROPIC_BASE_URL")) | not) or
            ($env.ANTHROPIC_BASE_URL | type == "string" and rtrimstr("/") == $base)) and
          ($env | with_entries(select(.key | IN("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
            "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_GATEWAY"))) |
            all(.[]; . == null or . == "")) and
          (($env.ANTHROPIC_CUSTOM_HEADERS // "") | type == "string" and
            (split("\n") | all(.[]; (split(":")[0] | ascii_downcase | gsub("[[:space:]]"; "")) != "x-better-ccflare-account-id")))))
    ' "$file" >/dev/null 2>&1 || return 1
  done
}
