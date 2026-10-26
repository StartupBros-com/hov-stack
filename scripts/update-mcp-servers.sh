#!/usr/bin/env bash
# Update the one supported host MCP checkout and its dependencies.
# Scheduled by mcp-servers-update.timer (Sunday 04:00).
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin"

MCP_TARGET="${MCP_TARGET:-$HOME/SITES/discord-mcp}"
NPX_CACHE_PATH="${NPX_CACHE_PATH:-$HOME/.npm/_npx}"
GIT_BIN="${GIT_BIN:-git}"
UV_BIN="${UV_BIN:-uv}"
RM_BIN="${RM_BIN:-rm}"
REALPATH_BIN="${REALPATH_BIN:-realpath}"
# No built-in origin: the checkout this updater may fast-forward is deployment-specific
# (systemd/mcp-servers-update.service sets it). Unset, the updater refuses before git.
EXPECTED_ORIGIN="${EXPECTED_ORIGIN:-}"
if [ -z "$EXPECTED_ORIGIN" ]; then
  printf 'ERROR: EXPECTED_ORIGIN is not set; export the <owner>/<name> the MCP checkout must match\n' >&2
  exit 2
fi

failures=0

required_failure() {
  printf 'ERROR: %s\n' "$1" >&2
  failures=$((failures + 1))
}

normalized_github_identity() {
  local remote=$1 identity

  case "$remote" in
    git@github.com:*) identity=${remote#git@github.com:} ;;
    ssh://git@github.com/*) identity=${remote#ssh://git@github.com/} ;;
    https://github.com/*) identity=${remote#https://github.com/} ;;
    *) return 1 ;;
  esac

  identity=${identity%/}
  identity=${identity%.git}
  case "$identity" in
    */*/*|*[$'\t\r\n ']*|'') return 1 ;;
  esac
  printf '%s\n' "$identity"
}

update_target() {
  local target=$1 remote identity upstream

  if [ ! -d "$target" ]; then
    required_failure "MCP target is missing"
    return
  fi

  if ! remote=$("$GIT_BIN" -C "$target" remote get-url origin 2>/dev/null); then
    required_failure "MCP target origin is missing or unreadable"
    return
  fi
  if ! identity=$(normalized_github_identity "$remote"); then
    required_failure "MCP target origin is malformed or unsupported"
    return
  fi
  if [ "$identity" != "$EXPECTED_ORIGIN" ]; then
    required_failure "MCP target origin is not approved"
    return
  fi

  # fetch + `merge --ff-only --no-autostash <upstream>`, not `pull --ff-only`
  # (dotfiles#481). The global git config (git/config.shared) sets pull.rebase
  # and both autoStash keys; under it `pull --ff-only` on a checkout whose local
  # edit overlaps the incoming diff does not refuse — it stashes, fast-forwards,
  # pops with conflict markers and still exits 0, so this script would count a
  # conflicted tree as a successful update. merge --no-autostash keeps the
  # contract lib/repo-update.sh documents for dotup: unrelated local edits are
  # tolerated, an overlapping one is refused with git's own message in the
  # journal. (`pull --no-autostash` would instead refuse on ANY dirt under
  # pull.rebase=true, before fetching.)
  #
  # The upstream is resolved first and must live on origin. A bare `pull`
  # followed whatever remote the branch tracked — a remote the origin-identity
  # check above never vetted — and merging `@{u}` after `fetch origin` would
  # silently stay stale if the branch tracked another remote. Named, refused.
  upstream=$("$GIT_BIN" -C "$target" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream=
  case "$upstream" in
    '')
      required_failure "MCP target has no upstream branch to fast-forward from (detached HEAD or no tracking branch)"
      ;;
    origin/*)
      if ! "$GIT_BIN" -C "$target" fetch origin; then
        required_failure "MCP target fetch failed"
      elif ! "$GIT_BIN" -C "$target" merge --ff-only --no-autostash "$upstream"; then
        required_failure "MCP target fast-forward merge failed"
      fi
      ;;
    *)
      required_failure "MCP target branch tracks $upstream, not origin"
      ;;
  esac

  # Preserve the established uv invocation shape used by this checkout.
  if ! "$UV_BIN" --directory "$target" sync; then
    required_failure "MCP target dependency sync failed"
  fi
}

reset_npx_cache() {
  local cache_path=$1 cache_canonical home_canonical

  case "$cache_path" in
    /*) ;;
    *)
      required_failure "npx cache path must be absolute"
      return
      ;;
  esac

  if ! cache_canonical=$("$REALPATH_BIN" -m -- "$cache_path" 2>/dev/null) ||
    ! home_canonical=$("$REALPATH_BIN" -m -- "$HOME" 2>/dev/null); then
    required_failure "npx cache path could not be resolved safely"
    return
  fi
  if [ "$cache_canonical" = / ] || [ "$cache_canonical" = "$home_canonical" ]; then
    required_failure "refusing unsafe npx cache path"
    return
  fi

  # Cache clearing must stay local and deterministic: never download or invoke
  # a package for this operation.
  if ! "$RM_BIN" -rf -- "$cache_canonical"; then
    required_failure "npx cache reset failed"
  fi
}

update_target "$MCP_TARGET"

# This cleanup is useful but does not invalidate a successful repo update.
if ! "$UV_BIN" cache clean; then
  printf 'WARN: optional uv tool-cache cleanup failed\n' >&2
fi

reset_npx_cache "$NPX_CACHE_PATH"

if [ "$failures" -ne 0 ]; then
  printf 'ERROR: MCP update completed with %s required failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'MCP update completed successfully\n'
