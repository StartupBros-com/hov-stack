#!/usr/bin/env bash
# Sourced. The check runs that describe a head now, without the suites a
# newer run of the same workflow superseded (ci-current-check-runs.jq).
# Both responses reach jq on stdin: a ready PR's full check-run set exceeds
# the per-argument limit that --argjson hits (dotfiles#1584).

CI_CURRENT_LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# A ready flip or body edit waits this long, on the local clock, for the run
# it starts before trusting green.
CI_CURRENT_SETTLE_SECS=${CI_CURRENT_SETTLE_SECS:-90}
# A workflow-runs listing that leaves a GitHub Actions suite unclaimed is no
# verdict (ci-current-check-runs.jq, dotfiles#1636): both endpoints are read
# this many times in all, this many seconds apart, before the read fails. A
# count that is not a number fails the read after one, never reads forever.
CI_CURRENT_READ_TRIES=${CI_CURRENT_READ_TRIES:-3}
CI_CURRENT_RETRY_SECS=${CI_CURRENT_RETRY_SECS:-5}

# ci_current_check_runs <owner/repo> <sha> [<settle-epoch> <hold-until>]: one
# JSON array. <settle-epoch> is GitHub's time of the PR update that may start
# runs; <hold-until> is the local epoch after which it stops holding the head.
# Past that bound with no run created since the update, it says so on stderr.
# Fails, printing nothing, when either endpoint cannot be read, or when the
# workflow-runs listing still leaves an Actions suite unclaimed after
# CI_CURRENT_READ_TRIES reads; each such read says why on stderr.
ci_current_check_runs() {
  local checks workflows gap try=0 hold=false spent=false
  if [ "${3:-0}" -gt 0 ]; then
    if [ "$(date +%s)" -lt "${4:-0}" ]; then hold=true; else spent=true; fi
  fi
  while :; do
    try=$((try + 1))
    checks=$(gh api "repos/$1/commits/$2/check-runs" --paginate --slurp) || return 1
    workflows=$(gh api "repos/$1/actions/runs?head_sha=$2&per_page=100" --paginate --slurp) || return 1
    gap=$(printf '%s\n' "$checks" "$workflows" | jq -sr -L "$CI_CURRENT_LIB" \
      'include "ci-current-check-runs"; listing_gap_from_pages') || return 1
    [ -n "$gap" ] || break
    if ! [ "$try" -lt "$CI_CURRENT_READ_TRIES" ]; then
      printf 'ci-current: read %s of %s at %s: %s; failing the read\n' "$try" "$CI_CURRENT_READ_TRIES" "${2:0:7}" "$gap" >&2
      return 1
    fi
    printf 'ci-current: read %s of %s at %s: %s; reading again in %ss\n' \
      "$try" "$CI_CURRENT_READ_TRIES" "${2:0:7}" "$gap" "$CI_CURRENT_RETRY_SECS" >&2
    sleep "$CI_CURRENT_RETRY_SECS"
  done
  if [ "$spent" = true ] && [ "$(jq --argjson settle "$3" \
      'any(.[].workflow_runs[]?; (.created_at | fromdateiso8601) >= $settle)' <<<"$workflows" 2>/dev/null)" = false ]; then
    printf 'ci-current: no workflow run at %s was created after the update at %s within the settle bound; reading the runs listed\n' \
      "${2:0:7}" "$(date -u -d "@$3" +%FT%TZ)" >&2
  fi
  printf '%s\n' "$checks" "$workflows" | jq -sce -L "$CI_CURRENT_LIB" \
    --argjson settle "${3:-0}" --argjson hold "$hold" \
    'include "ci-current-check-runs"; current_check_runs_from_pages($settle; $hold)'
}

# --- A draft head's suite evidence (dotfiles#1598) ----------------------------
# Where the required CI runs only at the head marked ready for review, a draft
# head's suite evidence is the record run-affected-suites.py writes for each
# commit. The runner and its bound are overridable for tests; a caller's
# heartbeat is extended past the bound before a run starts.
LOCAL_SUITES_RUNNER=${LOCAL_SUITES_RUNNER:-$CI_CURRENT_LIB/../run-affected-suites.py}
LOCAL_SUITES_RUN_SECS=${LOCAL_SUITES_RUN_SECS:-3600}

# local_suites_applies <tree>: 0 when the repository at <tree> carries the
# draft gate, the one predicate every draft path asks first; 1 when it does
# not; any other code when the runner could not answer (its stderr is kept).
# Callers act only on 0 or 1, so a runner that is missing or crashes never
# reads as "no gate".
local_suites_applies() {
  [ -n "${1:-}" ] || { echo 'local_suites_applies: no tree given' >&2; return 2; }
  python3 "$LOCAL_SUITES_RUNNER" --applies "$1" >/dev/null
}

# local_suites_read <tree> <sha>: the runner's --read. The record goes in
# LOCAL_SUITES_REC, its code in LOCAL_SUITES_RC (0 read, 4 absent, else
# unreadable), its stderr in LOCAL_SUITES_READ_ERR: a record that exists but
# cannot be read says why there, and the caller prints it after its own line
# so pr-owner's park reason ends with the cause.
local_suites_read() {
  local f
  LOCAL_SUITES_REC='' LOCAL_SUITES_READ_ERR=''
  f=$(mktemp "${TMPDIR:-/tmp}/local-suites-read.XXXXXX") || { LOCAL_SUITES_RC=2 LOCAL_SUITES_READ_ERR='mktemp failed'; return; }
  LOCAL_SUITES_REC=$(python3 "$LOCAL_SUITES_RUNNER" --repo "$1" --read "$2" 2>"$f"); LOCAL_SUITES_RC=$?
  LOCAL_SUITES_READ_ERR=$(cat "$f"); rm -f "$f"
}

# local_suites_result <tree> <sha> [<heartbeat command>...]: print the record
# for <sha>. With none, and <tree> at <sha>, call the heartbeat command with
# the run bound in seconds appended, run the runner from <tree> once, and read
# again. 0 for pass or partial, 1 for fail, 2 when no record can be had (why,
# on stderr). Says on stderr which evidence it used.
local_suites_result() {
  local tree=$1 sha=$2 rec rc out head
  shift 2
  printf 'draft: reading local result at %s\n' "${sha:0:7}" >&2
  local_suites_read "$tree" "$sha"; rec=$LOCAL_SUITES_REC rc=$LOCAL_SUITES_RC
  if [ "$rc" = 4 ]; then
    head=$(git -C "$tree" rev-parse HEAD 2>/dev/null)
    if [ "$head" != "$sha" ]; then
      printf 'draft: no local result at %s, and %s is at %s, not that head\n' "${sha:0:7}" "$tree" "${head:0:7}" >&2
      return 2
    fi
    [ "$#" = 0 ] || "$@" "$((LOCAL_SUITES_RUN_SECS + 60))" || return 2
    out=$(mktemp "${TMPDIR:-/tmp}/local-suites.XXXXXX") || return 2
    printf 'draft: no local result at %s; running timeout %s python3 %s --repo %s\n' \
      "${sha:0:7}" "$LOCAL_SUITES_RUN_SECS" "$LOCAL_SUITES_RUNNER" "$tree" >&2
    (cd "$tree" && timeout --kill-after=30 "$LOCAL_SUITES_RUN_SECS" \
      python3 "$LOCAL_SUITES_RUNNER" --repo "$tree") >"$out" 2>&1
    local_suites_read "$tree" "$sha"; rec=$LOCAL_SUITES_REC rc=$LOCAL_SUITES_RC
    if [ "$rc" != 0 ]; then
      printf 'draft: the runner recorded no result at %s; its last lines:\n' "${sha:0:7}" >&2
      tail -n 20 "$out" >&2
      # Absent is what the line above says; anything else is the reader's own cause.
      [ "$rc" = 4 ] || [ -z "$LOCAL_SUITES_READ_ERR" ] || printf '%s\n' "$LOCAL_SUITES_READ_ERR" >&2
      rm -f "$out"
      return 2
    fi
    rm -f "$out"
  elif [ "$rc" != 0 ]; then
    printf 'draft: cannot read the local result at %s (runner exit %s)\n' "${sha:0:7}" "$rc" >&2
    [ -z "$LOCAL_SUITES_READ_ERR" ] || printf '%s\n' "$LOCAL_SUITES_READ_ERR" >&2
    return 2
  fi
  printf 'draft: local result at %s is %s; log %s\n' "${sha:0:7}" \
    "$(jq -r '.outcome // "unknown"' <<<"$rec")" "$(jq -r '.log // "none"' <<<"$rec")" >&2
  printf '%s\n' "$rec"
  case "$(jq -r '.outcome // ""' <<<"$rec")" in
    pass|partial) return 0 ;;
    fail) return 1 ;;
    *) return 2 ;;
  esac
}
