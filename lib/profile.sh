#!/usr/bin/env bash
# shellcheck shell=bash
#
# profile.sh — resolve this machine's declared role from hosts.tsv.
#
# Consumers: sync.sh (timer enable-set, push authority),
#            scripts/harness-doctor.sh (flags an unmapped host).
#
# Fails CLOSED. An unmapped machine gets no role, and callers must treat that as
# an error rather than guessing: guessing "satellite" would silently disable a
# workstation's timers, and guessing "workstation" would let a second machine
# publish over the canonical one. Both failures are quiet, which is exactly the
# shape this repo keeps getting bitten by.

# Resolved from THIS FILE's own location, not from $HOME/dotfiles. A hermetic
# tree, a worktree, or any checkout that is not the canonical clone would
# otherwise read a table belonging to a different tree — or none — and the role
# would silently resolve wrong. An explicit DOTFILES_ROLE_FILE, then $DOTFILES,
# still override, in that order, for callers that genuinely mean elsewhere.
#
# A tree that carries no table (the public repository carries none; docs/layout.md)
# falls back to <overlay>/hosts.tsv (lib/overlay.sh), the host's own copy of the
# fleet table. The tree's own table comes first, so a hermetic fixture keeps the
# table it wrote. When neither is readable, DOTFILES_ROLE_FILE names the overlay
# copy, so a refusal points at the one place a switched host may add its row.
_profile_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The overlay library is the sibling found through any symlink, as lib/foreign-units.sh
# finds it. A fixture that copies this file alone keeps the chain without the overlay.
_profile_overlay_lib=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/overlay.sh
if [ -r "$_profile_overlay_lib" ]; then
  # shellcheck source=lib/overlay.sh
  . "$_profile_overlay_lib"
fi
unset _profile_overlay_lib
DOTFILES_ROLE_FILE=${DOTFILES_ROLE_FILE:-${DOTFILES:+$DOTFILES/hosts.tsv}}
if [ -z "$DOTFILES_ROLE_FILE" ]; then
  if [ -r "$_profile_self_dir/../hosts.tsv" ]; then
    DOTFILES_ROLE_FILE=$_profile_self_dir/../hosts.tsv
  elif command -v overlay_dir >/dev/null 2>&1 && _profile_overlay=$(overlay_dir); then
    DOTFILES_ROLE_FILE=$_profile_overlay/hosts.tsv
  else
    DOTFILES_ROLE_FILE=$_profile_self_dir/../hosts.tsv
  fi
  unset _profile_overlay
fi

# profile_role [hostname] -> prints the role, or nothing and returns 1.
#
# A role comes only from this host's hosts.tsv row. An undeclared host has
# no role, regardless of its environment; callers must fail closed.
profile_role() {
  local host=${1:-$(hostname -s 2>/dev/null || hostname)} declared=""
  if [ -r "$DOTFILES_ROLE_FILE" ]; then
    declared=$(awk -F'\t' -v h="$host" '!/^[[:space:]]*#/ && $1==h {print $2; exit}' \
                 "$DOTFILES_ROLE_FILE" 2>/dev/null)
  fi
  if [ -n "$declared" ]; then
    printf '%s\n' "$declared"
    return 0
  fi

  return 1
}

# profile_is <role> — true when this machine holds <role>.
profile_is() { [ "$(profile_role 2>/dev/null)" = "$1" ]; }

# profile_assert_known — one clear message instead of each caller inventing one.
profile_assert_known() {
  local r
  if ! r=$(profile_role); then
    printf 'no role declared for %s in %s\n' \
      "$(hostname -s 2>/dev/null || hostname)" "$DOTFILES_ROLE_FILE" >&2
    printf 'add a line: <hostname>\\t<workstation|satellite>\n' >&2
    return 1
  fi
  case "$r" in
    workstation|satellite) printf '%s\n' "$r" ;;
    *) printf 'unknown role %s (expected workstation or satellite)\n' "$r" >&2; return 1 ;;
  esac
}
