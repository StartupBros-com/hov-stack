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
# would silently resolve wrong. $DOTFILES and an explicit DOTFILES_ROLE_FILE
# still override, in that order, for callers that genuinely mean elsewhere.
_profile_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOTFILES_ROLE_FILE=${DOTFILES_ROLE_FILE:-${DOTFILES:+$DOTFILES/hosts.tsv}}
DOTFILES_ROLE_FILE=${DOTFILES_ROLE_FILE:-$_profile_self_dir/../hosts.tsv}

# profile_role [hostname] -> prints the role, or nothing and returns 1.
#
# THE TABLE WINS FOR A DECLARED HOST. DOTFILES_ROLE used to be consulted first,
# which meant any process on any machine could claim `workstation` with one
# environment variable and push canonical state -- defeating the single feature
# this file exists to provide. The override now applies ONLY to a host that
# hosts.tsv does not declare: a rebuild under a temporary hostname, a container,
# the test suite. A machine that IS declared cannot be talked out of its role.
#
# The narrower hatch is still a hatch, and deliberately so: an undeclared host
# with no way to state its role could not install at all. But it can no longer
# override a decision the repo has already recorded, which is the case that
# mattered.
profile_role() {
  local host=${1:-$(hostname -s 2>/dev/null || hostname)} declared=""
  if [ -r "$DOTFILES_ROLE_FILE" ]; then
    declared=$(awk -F'\t' -v h="$host" '!/^[[:space:]]*#/ && $1==h {print $2; exit}' \
                 "$DOTFILES_ROLE_FILE" 2>/dev/null)
  fi
  if [ -n "$declared" ]; then
    # An override that CONTRADICTS the table is reported, never silently obeyed.
    if [ -n "${DOTFILES_ROLE:-}" ] && [ "${DOTFILES_ROLE}" != "$declared" ]; then
      printf 'profile: ignoring DOTFILES_ROLE=%s — %s is declared %s in %s\n' \
        "$DOTFILES_ROLE" "$host" "$declared" "$DOTFILES_ROLE_FILE" >&2
    fi
    printf '%s\n' "$declared"
    return 0
  fi
  # WORKSTATION REQUIRES A ROW, unconditionally. An unregistered host may
  # self-declare only as `satellite`, which is harmless: it fails DOWN, enabling
  # the minimal timer set and holding no push authority. `workstation` is the
  # canonical-push authority, so allowing an unregistered host to claim it by
  # environment variable would leave exactly the hole the table exists to close
  # -- a fresh machine, a CI runner, or any third box could assert it.
  #
  # The earlier fix made the table win for DECLARED hosts. This closes the other
  # half: undeclared hosts cannot reach the privileged role at all.
  if [ -n "${DOTFILES_ROLE:-}" ]; then
    if [ "$DOTFILES_ROLE" = workstation ]; then
      printf 'profile: refusing DOTFILES_ROLE=workstation for undeclared host %s\n' "$host" >&2
      printf '         the workstation role requires a row in %s\n' "$DOTFILES_ROLE_FILE" >&2
      return 1
    fi
    printf '%s\n' "$DOTFILES_ROLE"; return 0
  fi
  [ -r "$DOTFILES_ROLE_FILE" ] || return 1
  local h r
  while IFS=$'\t' read -r h r; do
    case "$h" in ''|\#*) continue ;; esac
    [ "$h" = "$host" ] || continue
    [ -n "$r" ] || return 1
    printf '%s\n' "$r"
    return 0
  done < "$DOTFILES_ROLE_FILE"
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
