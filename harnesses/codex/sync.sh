#!/usr/bin/env bash
# Manage only Codex's stable global hooks file. Runtime state, credentials, and
# config.toml deliberately remain owned by Codex.
#
# The tracked hooks.json is a template: every home path is spelled with a
# literal `$HOME/`. Whether Codex expands that in a hook command is not
# documented, so install renders it to this machine's home before writing the
# live file, and check compares the live file against the rendered form.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
H=${CODEX_HOME:-$HOME/.codex}
REF=$HERE/hooks.json
LIVE=$H/hooks.json
MODE=${1:-check}
RENDERED=""

# The reference with every `$HOME/` rendered to this machine's home, as a file
# that lives for the run. Rendering touches nothing but that prefix.
render_reference() {
  [ -n "$RENDERED" ] && return 0
  RENDERED=$(mktemp "${TMPDIR:-/tmp}/codex-hooks-rendered.XXXXXX") || return 1
  jq --arg home "$HOME" '
    walk(if type == "string" then gsub("\\$HOME/"; $home + "/") else . end)
  ' "$REF" > "$RENDERED" || return 1
}
trap '[ -n "$RENDERED" ] && rm -f "$RENDERED"' EXIT

validate_reference() {
  command -v jq >/dev/null 2>&1 || {
    echo "codex hook sync requires jq" >&2
    return 1
  }
  jq -e . "$REF" >/dev/null 2>&1 || {
    echo "canonical codex/hooks.json is invalid" >&2
    return 1
  }
  jq -e --arg cmd '$HOME/.local/bin/dcg' '
    .hooks.PreToolUse[0].matcher == "Bash"
    and ([.hooks.PreToolUse[0].hooks[]?
          | select(.type == "command" and .command == $cmd)] | length == 1)
  ' "$REF" >/dev/null || {
    echo "canonical DCG hook must be the first Codex PreToolUse Bash group, naming the literal \$HOME/.local/bin/dcg" >&2
    return 1
  }
  render_reference || {
    echo "could not render canonical codex/hooks.json for this home" >&2
    return 1
  }
}

check() {
  validate_reference || return 1
  [ -f "$LIVE" ] || {
    echo "DRIFT: $LIVE is missing or not a regular file"
    return 1
  }
  jq -e . "$LIVE" >/dev/null 2>&1 || {
    echo "DRIFT: $LIVE is invalid JSON"
    return 1
  }
  if ! cmp -s <(jq -S . "$RENDERED") <(jq -S . "$LIVE"); then
    echo "DRIFT: $LIVE differs from canonical codex/hooks.json (rendered for this home)"
    return 1
  fi
  echo "in sync"
}

install_hooks() {
  local tmp backup
  validate_reference || return 1
  mkdir -p "$H" || return 1

  if [ -f "$LIVE" ] && jq -e . "$LIVE" >/dev/null 2>&1 \
      && cmp -s <(jq -S . "$RENDERED") <(jq -S . "$LIVE"); then
    echo "Codex hooks already in sync"
    return 0
  fi
  if [ -e "$LIVE" ] && [ ! -f "$LIVE" ]; then
    echo "$LIVE exists but is not a regular file; refusing to replace it" >&2
    return 1
  fi

  if [ -e "$LIVE" ]; then
    mkdir -p "$H/backups" || return 1
    backup=$(mktemp -d "$H/backups/dotfiles-hooks-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    cp -a "$LIVE" "$backup/hooks.json" || return 1
    echo "Backed up existing hooks to $backup/hooks.json"
  fi

  tmp=$(mktemp "$H/.hooks.json.XXXXXX") || return 1
  install -m 0600 "$RENDERED" "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! mv -f "$tmp" "$LIVE"; then
    rm -f "$tmp"
    echo "atomic Codex hooks replacement failed" >&2
    return 1
  fi
  echo "Installed canonical Codex hooks at $LIVE (home paths rendered for $HOME)"
  echo "Open a new Codex session and review/trust the hook with /hooks; this script never changes trust state."
}

case "$MODE" in
  check) check ;;
  install) install_hooks ;;
  *) echo "usage: sync.sh check|install" >&2; exit 2 ;;
esac
