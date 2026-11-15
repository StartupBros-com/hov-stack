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
  local name="$1" version="${2:-1.0.0}"
  mkdir -p "plugins/$name/.claude-plugin" "plugins/$name/skills/$name"
  printf '{"name":"%s","version":"%s"}\n' "$name" "$version" >"plugins/$name/.claude-plugin/plugin.json"
  printf '%s\n' "$version" >"plugins/$name/VERSION"
  printf 'fixture skill\n' >"plugins/$name/skills/$name/SKILL.md"
}
notes() {
  mkdir -p "plugins/$1/docs/release-notes"
  printf '## Highlights\n- Customers can install updates with a single command.\n' >"plugins/$1/docs/release-notes/v$2.md"
}

SCRIPT="$ROOT/release/scripts/ci-changed-plugins.sh"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
printf 'seed\n' >seed; commit
bash "$SCRIPT" '' HEAD >"$TMP/out"
{ grep -Fxq 'plugins=[]' "$TMP/out" && grep -Fxq any=false "$TMP/out"; } || die 'absent plugins'
pass 'absent plugins produces an empty matrix'
plugin a; plugin b; mkdir -p plugins/ignored; commit
base="$(git rev-parse HEAD)"
bash "$SCRIPT" 0000000000000000000000000000000000000000 HEAD >"$TMP/out" 2>"$TMP/err"
{ grep -Fxq 'plugins=["a","b"]' "$TMP/out" && grep -Fq '::notice::base' "$TMP/err"; } || die 'initial matrix and notice'
pass 'zero base selects every manifest directory with a notice'
for missing in '' deadbeef; do
  bash "$SCRIPT" "$missing" HEAD >"$TMP/out" 2>"$TMP/err"
  { grep -Fxq 'plugins=["a","b"]' "$TMP/out" && grep -Fq '::notice::' "$TMP/err"; } || die 'fallback base'
done
pass 'empty and unavailable bases select all plugins'
printf 'change\n' >plugins/a/file; mkdir release; touch release/outside; commit
bash "$SCRIPT" "$base" HEAD >"$TMP/out"
{ grep -Fxq 'plugins=["a"]' "$TMP/out" && grep -Fxq any=true "$TMP/out"; } || die 'path selection'
pass 'plugin and release changes select only the plugin'
base="$(git rev-parse HEAD)"
git mv plugins/a/file plugins/b/file; commit
bash "$SCRIPT" "$base" HEAD >"$TMP/out"
grep -Fxq 'plugins=["a","b"]' "$TMP/out" || die 'rename hid the source plugin'
pass 'a file moved between plugins selects both'
base="$(git rev-parse HEAD)"
rm -r plugins/a; commit
bash "$SCRIPT" "$base" HEAD >"$TMP/out"
grep -Fxq 'plugins=[]' "$TMP/out" || die 'deleted plugin selected'
pass 'deleted plugin has no matrix job'
base="$(git rev-parse HEAD)"
touch release/only; commit
bash "$SCRIPT" "$base" HEAD >"$TMP/out"
grep -Fxq 'plugins=[]' "$TMP/out" || die 'outside-only diff'
pass 'changes outside plugins add no jobs'
plugin 'bad name'; commit
reject 'invalid plugin directory name bad name' bash "$SCRIPT" "$base" HEAD
pass 'unsafe directory names fail'

printf '%s ci-changed-plugins checks passed\n' "$PASS"
