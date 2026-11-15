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

commit() { git add -A; git -c user.name=t -c user.email=t@t commit -qm "${1:-fixture}"; }
plugin() {
  mkdir -p "plugins/$1/.claude-plugin"
  printf '{"name":"%s","version":"1.0.0"}\n' "$1" >"plugins/$1/.claude-plugin/plugin.json"
  printf '%s\n' "${2:-seed}" >"plugins/$1/file"
}
# base_for <event>: the script's one output line with the prefix removed, stderr in $TMP/err.
base_for() {
  EVENT_NAME="$1" bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || return 1
  [ "$(wc -l <"$TMP/out" | tr -d ' ')" = 1 ] || return 1
  grep -q '^base=' "$TMP/out" || return 1
  sed 's/^base=//' "$TMP/out"
}

SCRIPT="$ROOT/release/scripts/ci-base-sha.sh"
CHANGED="$ROOT/release/scripts/ci-changed-plugins.sh"
unset EVENT_NAME HEAD_SHA PR_BASE_SHA MERGE_GROUP_BASE_SHA PUSH_BEFORE_SHA

# A pull request opened on main at `stale`, touching nothing under plugins/. main then gains a
# plugin change, and GitHub builds the test merge of the pull request into the moved main.
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
plugin a; plugin b; commit seed
stale="$(git rev-parse HEAD)"
git checkout -q -b feature
printf 'docs\n' >README.md; commit 'pull request'
pr_head="$(git rev-parse HEAD)"
git checkout -q main
plugin a moved; commit 'main moved'
moved="$(git rev-parse HEAD)"
git checkout -q --detach main
git -c user.name=t -c user.email=t@t merge -q --no-ff -m 'test merge' feature
merge="$(git rev-parse HEAD)"

export HEAD_SHA="$merge" PR_BASE_SHA="$stale"
[ "$(base_for pull_request)" = "$moved" ] || die 'pull request base is not the first parent of the test merge'
[ ! -s "$TMP/err" ] || die 'a normal pull request run warned'
pass 'pull request: the base is the first parent of the test merge, not the base the event names'

bash "$CHANGED" "$(base_for pull_request)" "$merge" >"$TMP/changed"
{ grep -Fxq 'plugins=[]' "$TMP/changed" && grep -Fxq any=false "$TMP/changed"; } || die 'a later plugin change on main was counted as part of the pull request'
bash "$CHANGED" "$stale" "$merge" >"$TMP/changed"
grep -Fxq 'plugins=["a"]' "$TMP/changed" || die 'the fixture no longer reproduces the stale base selecting a plugin'
pass 'a pull request that touches no plugin selects none after main moves; the event base selected one'

export HEAD_SHA="$pr_head"
[ "$(base_for pull_request)" = "$stale" ] || die 'non-merge head did not fall back to the event base'
grep -Fq '::warning::' "$TMP/err" || die 'fallback to the event base was silent'
pass 'pull request: a head that is not a merge commit falls back to the event base with a warning'
export HEAD_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$(base_for pull_request)" = "$stale" ] || die 'unknown head did not fall back to the event base'
grep -Fq '::warning::' "$TMP/err" || die 'unknown head fallback was silent'
pass 'pull request: an unknown head falls back to the event base with a warning'

export HEAD_SHA="$merge" MERGE_GROUP_BASE_SHA="$moved" PUSH_BEFORE_SHA="$stale"
[ "$(base_for merge_group)" = "$moved" ] || die 'merge group base'
pass 'merge group: the base is the parent commit of the group'
[ "$(base_for push)" = "$stale" ] || die 'push base'
pass 'push: the base is the commit before the push'
export PUSH_BEFORE_SHA=0000000000000000000000000000000000000000
[ "$(base_for push)" = 0000000000000000000000000000000000000000 ] || die 'zero push base'
pass 'push: an all-zero before is passed through for the selector to handle'

unset MERGE_GROUP_BASE_SHA
[ "$(base_for merge_group)" = '' ] || die 'empty merge group base'
grep -Fq '::warning::this merge_group run has no base commit; every plugin is selected' "$TMP/err" || die 'empty base was silent'
pass 'an empty base prints an empty value and says every plugin is selected'

export EVENT_NAME=merge_group MERGE_GROUP_BASE_SHA="$moved"$'\n''any=false'
reject 'the merge_group base is not a commit id' bash "$SCRIPT"
[ ! -s "$TMP/out" ] || die 'a rejected base still wrote output'
export MERGE_GROUP_BASE_SHA=main
reject 'the merge_group base is not a commit id' bash "$SCRIPT"
[ ! -s "$TMP/out" ] || die 'a rejected base still wrote output'
pass 'a base that is not a commit id fails and writes nothing'

export EVENT_NAME=workflow_dispatch MERGE_GROUP_BASE_SHA="$moved"
reject 'no base commit is defined for the workflow_dispatch event' bash "$SCRIPT"
unset EVENT_NAME
reject 'no base commit is defined for the <unset> event' bash "$SCRIPT"
pass 'an event with no defined base fails'

printf '%s ci-base-sha checks passed\n' "$PASS"
