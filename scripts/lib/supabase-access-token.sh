#!/usr/bin/env bash
# supabase-access-token.sh: the SUPABASE_ACCESS_TOKEN resolution for
# migration-apply.sh and any other migration script, in the order the
# supabase-api wrapper uses: the environment, then the bws record
# SUPABASE_ACCESS_TOKEN, then ~/.secrets (sourced, as migration-apply.sh
# always did).
#
# Sourced, never executed; it carries no exec bit by design. Callers under
# `set -e` are safe: every external call is guarded. bws is optional: an absent
# binary, missing bws config, a listing without the record, or a bws failure
# (retried once after 2 s, each attempt bounded to 30 s) falls through to
# ~/.secrets. Only a record that is present but not an sbp_ token (a malformed
# or empty string, or a non-string value such as a number or null, dotfiles#1960) stops
# the resolution, because a broken canonical record is a configuration error
# that sourcing an older ~/.secrets would hide.
#
# Overrides for callers that pin trusted binaries (migration-apply.sh):
#   BWS_BIN      set but empty means "no bws" even when one is on PATH
#   JQ_BIN, TIMEOUT_BIN
#
# resolve_supabase_access_token sets SUPABASE_ACCESS_TOKEN (not exported; the
# caller decides) and SUPABASE_ACCESS_TOKEN_SOURCE (env | bws | ~/.secrets).
# Returns 0 on a token, 1 when no source holds one, 2 on a bws record that is
# present but unusable (malformed, empty, or not a string).

supabase_bws_token() {
  # Prints the bws record's value (nothing when the record is absent). Returns
  # 0 when bws answered, 1 when bws is absent, unconfigured or could not be
  # read, 2 when the record is present but its value is not a non-empty string;
  # then the printed text describes the value ("a number", "null", ...), never
  # the value itself.
  local bws jq timeout_bin access project listing record tab attempt
  tab=$'\t'
  bws=${BWS_BIN-$(command -v bws 2>/dev/null || true)}
  [ -n "$bws" ] && [ -x "$bws" ] || return 1
  jq=${JQ_BIN-$(command -v jq 2>/dev/null || true)}
  [ -n "$jq" ] && [ -x "$jq" ] || return 1
  timeout_bin=${TIMEOUT_BIN-$(command -v timeout 2>/dev/null || true)}
  [ -n "$timeout_bin" ] && [ -x "$timeout_bin" ] || return 1
  access=${BWS_ACCESS_TOKEN:-}
  if [ -z "$access" ] && [ -f "$HOME/.config/bws/token" ]; then
    access=$(tr -d '[:space:]' <"$HOME/.config/bws/token")
  fi
  project=${BWS_PROJECT_ID:-}
  if [ -z "$project" ] && [ -f "$HOME/.config/bws/sb-project-id" ]; then
    project=$(tr -d '[:space:]' <"$HOME/.config/bws/sb-project-id")
  fi
  [ -n "$access" ] && [ -n "$project" ] || return 1
  # One retry: a transient bws failure (rate limit, network) must not read as
  # a missing record, whose fix (re-seeding) would overwrite a live value.
  for attempt in 1 2; do
    if listing=$(BWS_ACCESS_TOKEN="$access" "$timeout_bin" 30 "$bws" --color no secret list "$project"); then
      # A here-string, not a pipe: jq reads all of its input, but the pipefail
      # SIGPIPE trap documented in migration-apply-prewrite-gates.test.sh is
      # not worth re-learning here.
      # The value's shape is decided inside first(): a raw null or false reaching
      # `//` would read as an absent record, the fall-through dotfiles#1960 closes.
      # shellcheck disable=SC2016
      record=$("$jq" -r --arg k SUPABASE_ACCESS_TOKEN '
        first(.[]? | select(type == "object" and .key == $k) | .value
          | if type == "string" and length > 0 then "string\t\(.)"
            elif type == "string" then "unusable\tan empty string"
            elif type == "null" then "unusable\tnull"
            elif type == "array" or type == "object" then "unusable\tan \(type)"
            else "unusable\ta \(type)" end) // empty' <<<"$listing") \
        || return 1
      case $record in
        '') return 0 ;;
        "string${tab}"*) printf '%s' "${record#*"$tab"}"; return 0 ;;
        "unusable${tab}"*) printf '%s' "${record#*"$tab"}"; return 2 ;;
        *) return 1 ;;
      esac
    fi
    if [ "$attempt" = 1 ]; then sleep 2; fi
  done
  return 1
}

# shellcheck disable=SC2034,SC2088,SC2209
resolve_supabase_access_token() {
  local value rc
  if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    SUPABASE_ACCESS_TOKEN_SOURCE=env
    return 0
  fi
  rc=0
  value=$(supabase_bws_token) || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "supabase-access-token: the bws record SUPABASE_ACCESS_TOKEN is present but its value is $value, which is not a personal access token (sbp_...); fix the record, ~/.secrets is not consulted" >&2
    return 2
  fi
  if [ "$rc" -eq 0 ] && [ -n "$value" ]; then
    if [[ ! $value =~ ^sbp_[A-Za-z0-9_]{20,200}$ ]]; then
      echo "supabase-access-token: the bws record SUPABASE_ACCESS_TOKEN is not a personal access token (sbp_...); fix the record, ~/.secrets is not consulted" >&2
      return 2
    fi
    SUPABASE_ACCESS_TOKEN=$value
    SUPABASE_ACCESS_TOKEN_SOURCE=bws
    return 0
  fi
  if [ -f "$HOME/.secrets" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.secrets"
    if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
      SUPABASE_ACCESS_TOKEN_SOURCE='~/.secrets'
      return 0
    fi
  fi
  return 1
}
