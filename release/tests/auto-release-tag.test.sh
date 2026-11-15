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

SCRIPT="$ROOT/release/scripts/auto-release-tag.sh"
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
printf 'seed\n' >seed; commit
sha="$(git rev-parse HEAD)"
printf 'a\t1.2.3\ta--v1.2.3\t%s\nb\t2.0.0\tb--v2.0.0\t%s\n' "$sha" "$sha" >"$TMP/due"
export GITHUB_OUTPUT="$TMP/outputs"
HOV_RELEASE_APP_ID='' HOV_RELEASE_APP_PRIVATE_KEY='' bash "$SCRIPT" --identity "$TMP/due" >"$TMP/out"
{ grep -Fxq have_app=false "$GITHUB_OUTPUT" && grep -Fq 'push a--v1.2.3' "$TMP/out" && grep -Fq 'push b--v2.0.0' "$TMP/out"; } || die 'manual notices'
pass 'missing secrets report every manual tag and succeed'
: >"$GITHUB_OUTPUT"
HOV_RELEASE_APP_ID=123 HOV_RELEASE_APP_PRIVATE_KEY=private bash "$SCRIPT" --identity "$TMP/due" >"$TMP/out"
{ grep -Fxq have_app=true "$GITHUB_OUTPUT" && [ ! -s "$TMP/out" ]; } || die 'app identity'
pass 'complete App identity sets have_app'
reject 'tag push requires RELEASE_TOKEN' env -u PUSH_URL -u RELEASE_TOKEN bash "$SCRIPT" "$TMP/due"
pass 'tag write refuses without a push identity'
PUSH_URL="$TMP/origin.git" DRY_RUN=1 bash "$SCRIPT" "$TMP/due" >"$TMP/out"
{ [ -z "$(git tag -l)" ] && [ -z "$(git -C "$TMP/origin.git" tag -l)" ]; } || die 'dry run wrote tags'
pass 'dry run changes neither local nor remote tags'
PUSH_URL="$TMP/origin.git" bash "$SCRIPT" <"$TMP/due" >"$TMP/out"
for tag in a--v1.2.3 b--v2.0.0; do
  [ "$(git -C "$TMP/origin.git" rev-list -n 1 "$tag")" = "$sha" ] || die 'remote target'
  [ "$(git cat-file -t "refs/tags/$tag")" = tag ] || die 'not annotated'
done
grep -Fq '::notice::pushed a--v1.2.3' "$TMP/out" || die 'push notice'
pass 'stdin rows create and push annotated tags'
[ "$(git config user.name)" = 'github-actions[bot]' ] || die 'default tag identity'
pass 'unset git identity receives the bot identity'
PUSH_URL="$TMP/origin.git" bash "$SCRIPT" "$TMP/due" >"$TMP/out" || die 'same sha retry'
pass 'retry reuses a local tag at the intended sha'
printf 'bad\t1.0.0\tbad--v1.0.0\tdeadbeef\nc\t1.0.0\tc--v1.0.0\t%s\n' "$sha" >"$TMP/due"
reject 'cannot create tag bad--v1.0.0' env PUSH_URL="$TMP/origin.git" bash "$SCRIPT" "$TMP/due"
[ "$(git -C "$TMP/origin.git" rev-list -n 1 c--v1.0.0)" = "$sha" ] || die 'failed row stopped rest'
pass 'failed row is reported while later tags still push'
# Production URL path: a git wrapper fails the https push the way git does,
# naming the authenticated URL, so the script's own output must never relay it.
export REAL_GIT GIT_CALLS="$TMP/git-calls"
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'WRAP'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_CALLS"
if [ "${1:-}" = push ] && [[ "${2:-}" == https://* ]]; then
  printf "fatal: unable to access '%s/': Could not resolve host: github.com\n" "$2" >&2
  exit 128
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$TMP/bin/git"
: >"$GIT_CALLS"
reject 'could not push tag c--v1.0.0' env -u PUSH_URL RELEASE_TOKEN=secret-never-print GITHUB_REPOSITORY=acme/repo PATH="$TMP/bin:$PATH" bash "$SCRIPT" < <(tail -n 1 "$TMP/due")
grep -Fxq 'push https://x-access-token:secret-never-print@github.com/acme/repo.git refs/tags/c--v1.0.0' "$GIT_CALLS" || die 'token URL was not pushed'
if grep -Fq 'secret-never-print' "$TMP/err" "$TMP/out"; then die 'token leaked'; fi
pass 'a failed authenticated push names the tag and never prints the token'

printf '%s auto-release-tag checks passed\n' "$PASS"
