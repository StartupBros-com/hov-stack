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

SCRIPT="$ROOT/release/scripts/auto-release-decide.sh"
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
git remote add origin "$TMP/origin.git"
export GITHUB_OUTPUT="$TMP/output"
# The runner exports the ref name of the run; a pull_request run of this suite would
# otherwise trip the side-branch guard. Pin the value a push to main carries.
export GITHUB_REF_NAME=main
printf 'seed\n' >seed; commit
bash "$SCRIPT" >"$TMP/out"
{ [ ! -s "$TMP/out" ] && grep -Fxq due=false "$GITHUB_OUTPUT"; } || die 'root commit due'
pass 'HEAD without a parent has nothing due'
plugin a; mkdir -p plugins/ghost; printf '1.0.0\n' >plugins/ghost/VERSION; commit
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
{ [ ! -s "$TMP/out" ] && grep -Fq 'was added, not bumped; no tag' "$TMP/err"; } || die 'added VERSION tagged'
pass 'adding VERSION never tags an initial import'
plugin a 1.0.1; printf '1.0.1\n' >plugins/ghost/VERSION; commit
: >"$GITHUB_OUTPUT"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
sha="$(git rev-parse HEAD)"
grep -Fxq "$(printf 'a\t1.0.1\ta--v1.0.1\t%s' "$sha")" "$TMP/out" || die 'bump due row'
grep -Fq 'no plugin manifest for ghost; nothing to release' "$TMP/err" || die 'missing manifest notice'
{ [ "$(wc -l <"$TMP/out")" -eq 1 ] && grep -Fxq due=true "$GITHUB_OUTPUT"; } || die 'extra due rows'
pass 'bump emits a row; no manifest emits only a notice'
PUSH_URL="$TMP/origin.git" bash "$ROOT/release/scripts/auto-release-tag.sh" "$TMP/out" >"$TMP/push" 2>"$TMP/err"
[ "$(git -C "$TMP/origin.git" tag -l)" = a--v1.0.1 ] || die 'prefixed tag absent at bare origin'
[ "$(git -C "$TMP/origin.git" rev-list -n 1 a--v1.0.1)" = "$sha" ] || die 'wrong remote tag sha'
pass 'bump decision pushes the prefixed tag at the exact sha'
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
{ [ ! -s "$TMP/out" ] && grep -Fq 'a--v1.0.1 already exists; nothing to do' "$TMP/err"; } || die 'not idempotent'
pass 'second decision has no rows and nothing to push'
for parent in '' 0000000000000000000000000000000000000000 deadbeef; do
  PARENT="$parent" bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
  grep -Fq 'already exists' "$TMP/err" || die 'parent fallback'
done
pass 'empty zero and unavailable parent fall back to first parent'
printf ' 1.0.1 \n' >plugins/a/VERSION; commit
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
[ ! -s "$TMP/out" ] || die 'whitespace-only bump'
pass 'trimmed VERSION comparison ignores whitespace-only edits'
plugin a 1.0.2; commit
before_bump="$(git rev-parse HEAD^1)"
printf 'later\n' >plugins/a/later; commit
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
[ ! -s "$TMP/out" ] || die 'first parent saw an older bump'
PARENT="$before_bump" bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
grep -Fxq "$(printf 'a\t1.0.2\ta--v1.0.2\t%s' "$(git rev-parse HEAD)")" "$TMP/out" || die 'valid PARENT ignored'
pass 'a valid PARENT older than the first parent finds the bump at the push tip'
plugin b 2.0.0; commit
plugin a 1.0.3-rc1; plugin b 2.0.1; commit
reject 'a VERSION 1.0.3-rc1 is not release semver' bash "$SCRIPT"
grep -Fq 'b--v2.0.1' "$TMP/out" || die 'one invalid plugin stopped others'
pass 'invalid semver fails after evaluating other plugins'
reject 'a VERSION bump was invalid (see the decide step); valid bumps were still tagged' bash "$SCRIPT" --fail-invalid
pass 'the fail-invalid mode fails the run after the valid rows were tagged'
plugin a 1.0.4
printf '{"name":"wrong","version":"0.0.0"}\n' >plugins/a/.claude-plugin/plugin.json
commit
reject 'manifest version 0.0.0 does not match VERSION 1.0.4' bash "$SCRIPT"
grep -Fq 'manifest name wrong does not match directory' "$TMP/err" || die 'missing name failure'
pass 'manifest version and name mismatches are both reported'
reject 'auto-release only runs from main' env GITHUB_REF_NAME=side bash "$SCRIPT"
pass 'side branch dispatch is refused'
plugin a 1.0.5; commit
reject 'cannot read remote absent for tag a--v1.0.5' env REMOTE=absent bash "$SCRIPT"
pass 'unreadable remote is not treated as an absent tag'

printf '%s auto-release-decide checks passed\n' "$PASS"
