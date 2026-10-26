#!/usr/bin/env bash
# Every git package in the tracked Pi settings (harnesses/pi/agent/settings.json) names a
# github.com repository that resolves anonymously at its pinned ref. A placeholder owner, a
# private repository or a deleted fork fails: that is the shape a public-safety rewrite can
# leave behind (a fork reference swapped for a placeholder, or a fork that no longer exists),
# and Pi then fails to install the package on a fresh host.
#
# The static checks run anywhere. The probe runs `git ls-remote` with no credential helper, no
# terminal prompt and no user or system git config (a global url.insteadOf could turn the https
# probe into an authenticated ssh one), from a scratch directory outside the checkout (a
# checkout's own .git/config may carry an auth header, as actions/checkout leaves one). Without
# a network path to github.com the probe is reported as not run and the suite exits 0.
set -euo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SETTINGS=$HERE/harnesses/pi/agent/settings.json
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"
[ -f "$SETTINGS" ] || fail "no Pi settings at $SETTINGS"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# git_sources FILE: one git: package source per line, from both the bare-string and the
# {"source": ...} package shapes.
git_sources() {
  jq -r '.packages[] | (if type == "object" then .source else . end)
         | select(type == "string" and startswith("git:"))' "$1"
}

# parse SOURCE: prints "<owner> <name> <ref>" (ref empty when unpinned); exits 1 with the
# reason on stderr for a non-github.com source, a malformed path or a placeholder owner.
parse() {
  local src=$1 rest owner name ref=""
  rest=${src#git:github.com/}
  [ "$rest" != "$src" ] || { echo "$src: not a git:github.com/<owner>/<name>[@<ref>] source" >&2; return 1; }
  case "$rest" in *@*) ref=${rest#*@}; rest=${rest%%@*} ;; esac
  owner=${rest%%/*}; name=${rest#*/}
  if [ -z "$owner" ] || [ -z "$name" ] || [ "$name" != "${name%%/*}" ] || [ "$owner" = "$rest" ]; then
    echo "$src: expected git:github.com/<owner>/<name>[@<ref>]" >&2; return 1
  fi
  case "$owner" in
    acme-org|acme|example|example-org|owner|user|your-org|placeholder)
      echo "$src: placeholder owner '$owner'; a tracked package must name its real public repository" >&2; return 1 ;;
  esac
  printf '%s %s %s\n' "$owner" "$name" "$ref"
}

# classify ERRFILE: the class of a failed ls-remote from its stderr. 1 refused (private,
# missing, or no such ref: --exit-code with no matching ref exits 2 and prints nothing), 2 no
# network path, 3 a transient HTTP status from github.com (429 or 5xx). An HTTP status is
# read before the network patterns because git words both as "unable to access".
classify() {
  if grep -q -E 'returned error: (429|5[0-9][0-9])' "$1"; then return 3; fi
  if grep -q -E 'returned error: [0-9]+|could not read Username|Repository not found|Authentication failed|not found|Permission denied' "$1"; then
    return 1
  fi
  if grep -q -E 'Could not resolve host|Failed to connect|Connection (refused|timed out|reset)|Network is unreachable|Operation timed out|unable to access' "$1"; then
    return 2
  fi
  return 1
}

# probe_once OWNER NAME REF: 0 when the ref (HEAD when unpinned) resolves anonymously, else
# classify's code. stderr of the attempt is left in $SCRATCH/probe.err.
probe_once() {
  local url="https://github.com/$1/$2.git" want=${3:-HEAD} err=$SCRATCH/probe.err
  if (cd "$SCRATCH" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        git -c credential.helper= -c core.askPass= ls-remote --exit-code "$url" "$want" >"$SCRATCH/probe.out" 2>"$err"); then
    [ -s "$SCRATCH/probe.out" ] || return 1
    return 0
  fi
  local rc=0
  classify "$err" || rc=$?
  return "$rc"
}

# probe OWNER NAME REF: probe_once, retried after each backoff in BACKOFF while the failure is
# a network or transient one; a refusal is final at once.
BACKOFF=(2 5)
probe() {
  local rc=0 delay
  probe_once "$@" || rc=$?
  for delay in "${BACKOFF[@]}"; do
    case "$rc" in 2|3) ;; *) return "$rc" ;; esac
    sleep "$delay"
    rc=0
    probe_once "$@" || rc=$?
  done
  return "$rc"
}

# offline_ok: whether a run with no network path to github.com may report the probe as not run
# and pass. Not on CI, where the check exists to run.
offline_ok() { [ "${CI:-}" != "true" ] && [ "${GITHUB_ACTIONS:-}" != "true" ]; }

# ---- planted negatives for the static checks ---------------------------------------------
if parse "git:github.com/acme-org/pi-lens@v1" >/dev/null 2>&1; then fail "a placeholder owner passed the static check"; fi
if parse "git:github.com/only-owner" >/dev/null 2>&1; then fail "a source without a name passed the static check"; fi
if parse "git:gitlab.com/x/y" >/dev/null 2>&1; then fail "a non-github source passed the static check"; fi
msg=$(parse "git:github.com/acme-org/x" 2>&1 >/dev/null) || true
case "$msg" in *"placeholder owner 'acme-org'"*) ;; *) fail "the placeholder refusal does not name the owner: $msg" ;; esac
[ "$(parse "git:github.com/some-owner/some-repo@v2.0.0")" = "some-owner some-repo v2.0.0" ] \
  || fail "parse does not split owner, name and ref"
[ "$(parse "git:github.com/some-owner/some-repo")" = "some-owner some-repo " ] \
  || fail "parse does not leave the ref empty for an unpinned source"
printf '{"packages": [{"source": "git:github.com/o/a"}, "git:github.com/o/b@v1", "npm:x", "extensions/y.ts"]}\n' >"$SCRATCH/shapes.json"
[ "$(git_sources "$SCRATCH/shapes.json" | paste -sd' ' -)" = "git:github.com/o/a git:github.com/o/b@v1" ] \
  || fail "git_sources misses one of the two package shapes or keeps a non-git source"

# ---- planted negatives for the failure classes, the retry and the CI rule ----------------
# want_class CODE STDERR: classify must put that stderr in that class.
want_class() {
  local rc=0
  printf '%s\n' "$2" >"$SCRATCH/class.err"
  classify "$SCRATCH/class.err" || rc=$?
  [ "$rc" -eq "$1" ] || fail "classify put '$2' in class $rc, want $1"
}
want_class 3 "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 503"
want_class 3 "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 429"
want_class 1 "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403"
want_class 2 "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com"
want_class 1 "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
want_class 1 "remote: Repository not found."
want_class 1 ""
# Two transient failures then a success resolves; a refusal is not retried.
(
  sleep() { :; }
  printf '' >"$SCRATCH/attempts"
  probe_once() { printf x >>"$SCRATCH/attempts"; [ "$(wc -c <"$SCRATCH/attempts")" -ge 3 ] && return 0; return 3; }
  probe o r v1 || fail "probe gave up on a transient failure before its retries ran out"
  [ "$(wc -c <"$SCRATCH/attempts")" -eq 3 ] || fail "probe made $(wc -c <"$SCRATCH/attempts") attempts, want 3"
  printf '' >"$SCRATCH/attempts"
  probe_once() { printf x >>"$SCRATCH/attempts"; return 1; }
  rc=0; probe o r v1 || rc=$?
  [ "$rc" -eq 1 ] && [ "$(wc -c <"$SCRATCH/attempts")" -eq 1 ] || fail "probe retried a refusal or changed its class (rc=$rc)"
) || exit 1
# No network path passes only off CI.
( CI=true; GITHUB_ACTIONS=""; offline_ok ) && fail "offline_ok let a CI run skip the probe"
( CI=""; GITHUB_ACTIONS=true; offline_ok ) && fail "offline_ok let a GitHub Actions run skip the probe"
( CI=""; GITHUB_ACTIONS=""; offline_ok ) || fail "offline_ok refused a run off CI"

# ---- the tracked settings ----------------------------------------------------------------
jq -e . "$SETTINGS" >/dev/null || fail "$SETTINGS is not valid JSON"
SOURCES=()
while IFS= read -r src; do SOURCES+=("$src"); done < <(git_sources "$SETTINGS")
[ "${#SOURCES[@]}" -gt 0 ] || fail "no git packages in $SETTINGS (the packages shape changed?)"
PARSED=()
for src in "${SOURCES[@]}"; do
  line=$(parse "$src") || fail "static check: $(parse "$src" 2>&1 >/dev/null)"
  PARSED+=("$line")
done

# ---- resolvability ------------------------------------------------------------------------
# A repository that cannot exist proves the probe fails closed; its stderr also tells a network
# outage from a refusal, so the planted negative decides whether the real probes run.
rc=0
probe acme-org "no-such-repository-$$" "" || rc=$?
[ "$rc" -ne 0 ] || fail "the probe resolved a repository that does not exist"
if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
  why="no answer from github.com after $(( ${#BACKOFF[@]} + 1 )) attempts ($(head -c 160 "$SCRATCH/probe.err" | tr '\n' ' '))"
  offline_ok || fail "resolvability could not be probed on CI: $why"
  echo "ok — pi packages: ${#SOURCES[@]} git sources pass the static checks; resolvability NOT probed: $why"
  exit 0
fi
# A real public repository at a ref it does not carry must fail too: a probe that only checked
# the repository exists would pass a pin to a deleted branch or a mistyped tag. The first tracked
# source's repository stands in, so the case needs no name of its own.
read -r owner name _ <<<"${PARSED[0]}"
rc=0
probe "$owner" "$name" "refs/tags/v0.0.0-no-such-tag-$$" || rc=$?
[ "$rc" -eq 1 ] || fail "a ref $owner/$name does not carry passed the probe or hit a network error (rc=$rc)"
resolved=0
for line in "${PARSED[@]}"; do
  read -r owner name ref <<<"$line"
  rc=0
  probe "$owner" "$name" "$ref" || rc=$?
  err_text=$(head -c 200 "$SCRATCH/probe.err" | tr '\n' ' ')
  case "$rc" in
    0) resolved=$((resolved + 1)) ;;
    2|3) fail "no answer from github.com for $owner/$name after $(( ${#BACKOFF[@]} + 1 )) attempts: $err_text" ;;
    *) fail "git:github.com/$owner/$name${ref:+@$ref} does not resolve anonymously (private, deleted, or the ref is not on it): ${err_text:-the repository answered but has no such ref}" ;;
  esac
done
echo "ok — pi packages: ${#SOURCES[@]} git sources pass the static checks and resolve anonymously at their refs ($resolved probed, 2 planted negatives refused)"
