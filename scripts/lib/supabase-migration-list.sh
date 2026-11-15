#!/usr/bin/env bash
# supabase-migration-list.sh: the remote-history parse shared by both remote
# reads in migration-apply.sh (preflight and post-verify). Every caller runs
# `supabase migration list --linked --output-format json` and pipes stdout here.
#
# Why the flag is pinned and the table is never read: the table is for humans
# and changed under the script. CLI v2.122.0 wraps every cell in backticks
# (`20250721000000`), so the old awk parse read zero versions from a valid
# listing and migration-apply.sh stopped at preflight (#366). The same CLI
# prints JSON instead of the table when CLAUDECODE or AI_AGENT is set, so an
# agent session and a terminal got different formats from one command. Vendor
# bytes for both forms: tests/fixtures/supabase-migration-list/.
#
# Sourced, never executed; it carries no exec bit by design. JQ_BIN overrides
# jq for callers that pin trusted binaries (migration-apply.sh).
#
# supabase_remote_versions reads the CLI's stdout on stdin and prints each
# remote-applied version, one per line, sorted and unique. A version is 8-14
# digits, the bound the caller also applies to local filenames; an asymmetric
# bound manufactures phantom pending rows. Returns 0 for migration-list JSON
# even when it holds no remote version (prints nothing; each caller decides
# what an empty history means). Returns 1, with a one-line reason on stderr,
# when stdin is not migration-list JSON: empty, a table, malformed, or without
# a migrations array.

supabase_remote_versions() {
  local jq input versions
  jq=${JQ_BIN-$(command -v jq 2>/dev/null || true)}
  [ -n "$jq" ] || { echo "supabase_remote_versions: jq not found" >&2; return 1; }
  input=$(cat)
  # Here-strings, not pipes: jq reads all of its input, and a pipefail SIGPIPE
  # race is not worth re-learning (see supabase-access-token.sh).
  if ! "$jq" -e 'type == "object" and (.migrations | type == "array")' >/dev/null 2>&1 <<<"$input"; then
    echo "supabase_remote_versions: input is not migration-list JSON (${#input} bytes)" >&2
    return 1
  fi
  # \A and \z, not ^ and $: Oniguruma's ^ and $ match at line breaks, which
  # would accept a value with an embedded newline.
  versions=$("$jq" -r '.migrations[] | (.remote? // empty) | select(type == "string" and test("\\A[0-9]{8,14}\\z"))' <<<"$input") \
    || { echo "supabase_remote_versions: jq could not read the migrations array" >&2; return 1; }
  [ -z "$versions" ] || printf '%s\n' "$versions" | sort -u
}

# supabase_cli_redact copies stdin to stdout with credentials masked: sbp_
# access tokens, URL userinfo (postgresql://user:password@host), JWTs and libpq
# password= values. Every caller passes CLI text through it before that text
# reaches a log, the journal or an alert.
supabase_cli_redact() {
  sed -E 's/sbp_[A-Za-z0-9_]+/sbp_[redacted]/g
    s#(://)[^/@[:space:]]+@#\1[redacted]@#g
    s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/[redacted-jwt]/g
    s/(password=)[^[:space:]&]+/\1[redacted]/g'
}

# supabase_cli_error reads a failed CLI call's stdout on stdin. With
# --output-format json, CLI v2.122.0 reports its own failure there, not on
# stderr: {"_tag":"Error","error":{"code":…,"message":…,"suggestion":…}}, with
# stderr empty or holding only progress text ("Connecting to remote
# database..."). Vendor bytes: fixtures/supabase-migration-list/v2.122.0-error.json.
# Prints the error's code, message, detail and suggestion as one redacted line of
# at most 300 characters and returns 0. Returns 1, printing nothing, when stdin
# holds no such object, so the caller can fall back to the CLI's stderr.
supabase_cli_error() {
  local jq input reason
  jq=${JQ_BIN-$(command -v jq 2>/dev/null || true)}
  [ -n "$jq" ] || return 1
  input=$(cat)
  reason=$("$jq" -rn '
    first(inputs | select(type == "object" and ._tag == "Error" and (.error | type == "object")) | .error)
    | [.code, .message, .detail, .suggestion | strings | select(length > 0)]
    | join("; ") | gsub("\\s+"; " ")' 2>/dev/null <<<"$input") || return 1
  [ -n "$reason" ] || return 1
  printf '%s\n' "$reason" | supabase_cli_redact | cut -c1-300
}
