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

SCRIPT="$ROOT/release/scripts/release-train-verify.sh"
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
git remote add origin "$TMP/origin.git"
plugin a; commit; git tag a--v1.0.0
git push -q origin main
export RELEASE_TAG=a--v1.0.0
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || die 'good tag'
grep -Fq 'is on main and names plugin a' "$TMP/out" || die 'good tag notice'
pass 'main tag with matching manifest passes'
printf '{"name":"dirty-checkout"}\n' >plugins/a/.claude-plugin/plugin.json
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || die 'read checkout instead of tag'
pass 'manifest is read from the tag tree'
plugin a
git switch -qc side
plugin a 2.0.0; commit; git tag a--v2.0.0
export RELEASE_TAG=a--v2.0.0
reject 'a--v2.0.0' bash "$SCRIPT"
grep -Fq 'not on main' "$TMP/err" || die 'missing ancestry reason'
pass 'side-branch release tag fails'
git switch -q main
printf '{"name":"other","version":"1.0.1"}\n' >plugins/a/.claude-plugin/plugin.json
commit; git tag a--v1.0.1; git push -q origin main
export RELEASE_TAG=a--v1.0.1
reject 'a--v1.0.1 manifest name other does not match plugin a' bash "$SCRIPT"
pass 'mismatched name at tag fails'
git tag ghost--v1.0.0
export RELEASE_TAG=ghost--v1.0.0
reject 'ghost--v1.0.0 has no plugin manifest plugins/ghost/.claude-plugin/plugin.json' bash "$SCRIPT"
pass 'absent plugin at tag fails'
export RELEASE_TAG=v1.0.0
reject 'v1.0.0 is not a <name>--v<version> tag' bash "$SCRIPT"
pass 'malformed release tag fails'

printf '%s release-train-verify checks passed\n' "$PASS"
