#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
# An unguarded command that fails under set -e would otherwise end the suite with no
# reason in the CI log; name the line and show the stderr the last case captured.
trap 'printf "not ok - unguarded command failed at line %s\n" "$LINENO" >&2; [ ! -s "$TMP/err" ] || cat "$TMP/err" >&2' ERR
PASS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass() { printf 'ok - %s\n' "$*"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
reject() {
  local reason="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then die "accepted: $reason"; fi
  grep -Fq -- "$reason" "$TMP/err" || { cat "$TMP/err"; die "missing reason: $reason"; }
}

SCRIPT="$ROOT/release/scripts/ci-aggregate.sh"
export EVENT_NAME=push HEAD_REPO_IS_FORK=false HEAD_REPO=acme/repo REPO=acme/repo PLUGINS_TOUCHED=false
export NEEDS_JSON='{"changes":{"result":"skipped"},"plugin":{"result":"skipped"}}'
bash "$SCRIPT" >"$TMP/out" || die 'all skipped'
pass 'all skipped needs pass when no plugin changed'
export PLUGINS_TOUCHED=true
for event in push merge_group pull_request; do
  export EVENT_NAME="$event" NEEDS_JSON='{"changes":{"result":"success"},"plugin":{"result":"skipped"}}'
  reject "plugins changed but the plugin job was skipped on this $event run; its checks did not run" bash "$SCRIPT"
  export NEEDS_JSON='{"changes":{"result":"success"},"plugin":{"result":"success"}}'
  bash "$SCRIPT" >"$TMP/out" || die "$event with plugin checks run"
  export PLUGINS_TOUCHED=false NEEDS_JSON='{"changes":{"result":"success"},"plugin":{"result":"skipped"}}'
  bash "$SCRIPT" >"$TMP/out" || die "$event with no plugin changed"
  export PLUGINS_TOUCHED=true
  pass "$event: changed plugins need the plugin job to have run; unchanged ones may skip it"
done
export EVENT_NAME=push
export NEEDS_JSON='{"changes":{"result":"success"},"plugin":{"result":"success"}}'
bash "$SCRIPT" >"$TMP/out" || die 'all success'
pass 'successful needs pass'
for result in failure cancelled; do
  export NEEDS_JSON="{\"changes\":{\"result\":\"success\"},\"plugin\":{\"result\":\"$result\"}}"
  reject "job plugin concluded $result" bash "$SCRIPT"
  pass "$result names the failing job"
done
export NEEDS_JSON='{"changes":{"result":"success"},"plugin":{"result":"skipped"}}'
export EVENT_NAME=pull_request HEAD_REPO_IS_FORK=true HEAD_REPO=outsider/repo
reject 'plugin checks do not run for pull requests from forks; a maintainer pushes the branch to this repository' bash "$SCRIPT"
pass 'fork PR touching plugins fails'
export PLUGINS_TOUCHED=false
bash "$SCRIPT" >"$TMP/out" || die 'fork without plugin changes'
pass 'fork PR without plugin changes passes'
export PLUGINS_TOUCHED=true HEAD_REPO_IS_FORK=false
reject 'plugin checks do not run for pull requests from forks' bash "$SCRIPT"
pass 'different head repository fails without fork flag'
export HEAD_REPO=acme/repo NEEDS_JSON='{"changes":{"result":"success"},"plugin":{"result":"success"}}'
bash "$SCRIPT" >"$TMP/out" || die 'same repo PR'
pass 'same repository PR whose plugin checks ran passes'
export NEEDS_JSON='{}'
bash "$SCRIPT" >"$TMP/out" || die 'empty needs object'
pass 'empty needs object has no failures'
export NEEDS_JSON='[]'
reject 'cannot read needed jobs from NEEDS_JSON' bash "$SCRIPT"
pass 'non-object needs fails closed'

printf '%s ci-aggregate checks passed\n' "$PASS"
