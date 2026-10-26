#!/usr/bin/env bash
# sync.sh — fx harness ⇄ dotfiles backup.
#
# fx has no plugin system of its own. This script bridges Claude Code plugin
# skills into ~/.fx/skills/ (via sync-skills.sh) and seeds the runtime settings
# file (~/.fx/settings.json) so the skill catalog cap is large enough for all
# bridged skills to surface on a fresh install.
#
#   STABLE parts   (sync-skills.sh — the skill bridge script)
#       lives IN THIS REPO, called by install() below.
#   VOLATILE parts (settings.json — fx rewrites this atomically, which would
#       break a symlink; it also carries credentials, model, and permission mode
#       that are per-machine)
#       are copy-synced: seed-only on install (never clobber a live config),
#       pulled back into the repo by `push`.
#
# Usage:
#   sync.sh install   Seed volatile parts where missing, refresh skill bridge.
#                     Idempotent; never overwrites a live settings.json.
#   sync.sh push      Refresh volatile copies into the repo (run before commit).
#   sync.sh check     Exit 1 + DRIFT lines if live harness differs from repo
#                     (consumed by harness-doctor check 10f).
#
# Exit codes: 0 clean/success, 1 drift or audit findings, 2 usage/runtime error.
#
# NOT managed here: credentials (fx login), sessions, usage, traces, MCP config.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # …/harnesses/fx
FX_HOME=${FX_HOME:-$HOME/.fx}
LIVE_SETTINGS=$FX_HOME/settings.json
REPO_SETTINGS=$HERE/settings.json
SKILL_BRIDGE=$HERE/sync-skills.sh

MODE=${1:-check}

# ── install: seed settings + refresh skill bridge ──
install() {
  mkdir -p "$FX_HOME" || { echo "fx: cannot create $FX_HOME" >&2; return 2; }

  # Sweep merge temp files leaked by a previous killed run: the bridge's
  # recover_leftovers() only covers $FX_SKILLS, and nothing else ever globs
  # this pattern — without the sweep a kill mid-merge leaks them forever.
  rm -f "$FX_HOME"/.settings.json.fx.* 2>/dev/null

  # Seed settings.json only where missing — the live copy is authoritative
  # once it exists (same doctrine as sync.sh volatile files).
  if [ ! -f "$LIVE_SETTINGS" ] && [ -f "$REPO_SETTINGS" ]; then
    cp "$REPO_SETTINGS" "$LIVE_SETTINGS" && echo "  seeded settings.json"
  fi

  # Converge context_limits into an existing live settings.json. fx rewrites
  # this file atomically and carries credentials/model/permission mode, so we
  # never clobber it; but an existing install that predates this feature (or
  # whose context_limits drifted) would otherwise stay stuck below the skill
  # catalog cap with no command that converges it. Merge ONLY the
  # context_limits subtree from the repo copy, preserving every other field,
  # via the same atomic temp-file + mv pattern as sync.sh's
  # reconcile_hook_group. If jq is missing or the live file is invalid, skip
  # silently — a settings merge is not worth failing an install over.
  if [ -f "$LIVE_SETTINGS" ] && [ -f "$REPO_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    if jq -e . "$LIVE_SETTINGS" >/dev/null 2>&1 && jq -e '.context_limits // empty' "$REPO_SETTINGS" >/dev/null 2>&1; then
      local repo_cl
      repo_cl=$(jq -c '.context_limits' "$REPO_SETTINGS" 2>/dev/null)
      if [ -n "$repo_cl" ] && [ "$repo_cl" != "null" ]; then
        local live_cl tmp
        live_cl=$(jq -c '.context_limits // null' "$LIVE_SETTINGS" 2>/dev/null)
        if [ "$live_cl" != "$repo_cl" ]; then
          tmp=$(mktemp "$FX_HOME/.settings.json.fx.XXXXXX") 2>/dev/null
          if [ -n "$tmp" ] && jq --argjson cl "$repo_cl" '.context_limits = $cl' "$LIVE_SETTINGS" > "$tmp" 2>/dev/null \
             && jq -e . "$tmp" >/dev/null 2>&1; then
            local mode
            mode=$(stat -c '%a' "$LIVE_SETTINGS" 2>/dev/null || echo 600)
            if chmod "$mode" "$tmp" 2>/dev/null && mv -f "$tmp" "$LIVE_SETTINGS"; then
              echo "  merged context_limits into settings.json"
            else
              rm -f "$tmp"
              echo "  WARN: could not atomically replace settings.json; context_limits not merged" >&2
            fi
          else
            rm -f "$tmp" 2>/dev/null
            echo "  WARN: context_limits merge failed; live settings.json unchanged" >&2
          fi
        fi
      fi
    fi
  fi

  # Refresh the skill bridge (rsync copies, not symlinks — fx does not follow
  # symlinks for skill discovery).
  #
  # exec, not a nested `bash` call: the SessionStart hook enforces its timeout
  # by killing its DIRECT child only (Node execFileSync does not kill process
  # groups — verified by repro in review). A nested bash layer would orphan
  # the bridge, its rsyncs, AND its install lock past that kill. exec makes
  # the bridge BE the hook's direct child. Nothing may run after this line.
  if [ -f "$SKILL_BRIDGE" ]; then
    exec bash "$SKILL_BRIDGE" install
  else
    echo "  WARN: sync-skills.sh not found at $SKILL_BRIDGE" >&2
  fi
}

# ── push: copy live settings back into the repo ──
push() {
  # Same leak sweep as install(): a killed push leaves its temp file behind.
  rm -f "$HERE"/.settings.json.push.* 2>/dev/null
  if [ -f "$LIVE_SETTINGS" ]; then
    # Extract only the durable, repo-worthy keys. fx settings.json carries
    # credentials, model, permission mode, and other per-machine state that
    # should not be version-controlled. We pull back only context_limits
    # (the skill catalog cap that makes bridged skills surface).
    if ! command -v jq >/dev/null 2>&1; then
      # FAIL CLOSED: a full copy would leak credentials, model, permission
      # mode, etc. into the tracked repo file. jq is required for a safe
      # extraction; without it, refuse rather than copy machine-specific state.
      echo "  ERROR: jq is required to push settings.json safely (would leak per-machine config); not pushed" >&2
      return 1
    fi
    # Render into a temp file first, validate context_limits is non-null with
    # `jq -e`, then atomically move into place. Writing `jq ... > $REPO_SETTINGS`
    # directly would truncate the canonical file before jq runs, so a failing
    # or null-emitting jq (e.g. live file lacks context_limits) would zero it.
    local tmp
    tmp=$(mktemp "$HERE/.settings.json.push.XXXXXX") 2>/dev/null
    if [ -z "$tmp" ]; then
      echo "  ERROR: could not create temp file; settings.json not pushed" >&2
      return 1
    fi
    if jq '{context_limits: .context_limits} | select(.context_limits != null)' \
        "$LIVE_SETTINGS" > "$tmp" 2>/dev/null \
       && jq -e '.context_limits != null' "$tmp" >/dev/null 2>&1; then
      if mv -f "$tmp" "$REPO_SETTINGS"; then
        echo "  pushed settings.json (context_limits only)"
      else
        rm -f "$tmp"
        echo "  ERROR: atomic replace of $REPO_SETTINGS failed; not pushed" >&2
        return 1
      fi
    else
      rm -f "$tmp"
      echo "  ERROR: live settings.json has no usable context_limits (or is invalid); not pushed" >&2
      return 1
    fi
  else
    echo "  no live settings.json to push"
  fi
}

# ── check: drift detection for harness-doctor §10f ──
check() {
  local drift=0

  # Skill bridge check
  if [ -x "$SKILL_BRIDGE" ] || [ -f "$SKILL_BRIDGE" ]; then
    bash "$SKILL_BRIDGE" check || drift=1
  fi

  # Settings check: only verify context_limits is present and matches.
  # The live file carries machine-specific keys we don't track; we compare
  # only the context_limits subtree (same approach as sync.sh's
  # settings.json check that excludes ad-daemon-owned keys).
  if [ ! -f "$LIVE_SETTINGS" ]; then
    echo "DRIFT: ~/.fx/settings.json is missing (run sync.sh install)"
    drift=1
  elif [ -f "$REPO_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    if ! cmp -s \
      <(jq -S '.context_limits // {}' "$LIVE_SETTINGS" 2>/dev/null) \
      <(jq -S '.context_limits // {}' "$REPO_SETTINGS" 2>/dev/null); then
      echo "DRIFT: ~/.fx/settings.json context_limits differs from repo (sync.sh push or install)"
      drift=1
    fi
  fi

  if [ "$drift" -eq 0 ]; then
    echo "in sync"
  fi
  return "$drift"
}

case "$MODE" in
  install) install ;;
  push)    push ;;
  check)   check ;;
  *) echo "usage: sync.sh install|push|check" >&2; exit 2 ;;
esac
