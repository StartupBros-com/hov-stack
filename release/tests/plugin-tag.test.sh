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

source "$ROOT/release/scripts/plugin-tag.sh"
[ "$(tag_plugin_name a--vpart--v1.2.3)" = a--vpart ] || die 'last separator name'
[ "$(tag_plugin_version a--vpart--v1.2.3)" = 1.2.3 ] || die 'last separator version'
pass 'tag splits at the last --v'
for tag in v1.2.3 --v1.2.3 a--vx a--v; do
  reject 'is not a <name>--v<version> tag' tag_plugin_name "$tag"
  reject 'is not a <name>--v<version> tag' tag_plugin_version "$tag"
done
pass 'bad shape, empty name and non-digit versions are refused'
for version in 0.0.0 1.2.3 12.30.40; do is_release_semver "$version" || die "$version rejected"; done
for version in 1.2 1.2.3-rc1 1.2.3+build v1.2.3 1x2x3 ' 1.2.3'; do
  if is_release_semver "$version"; then die "$version accepted"; fi
done
pass 'release semver has exactly three numeric components'
mkdir -p "$TMP/plugin/.claude-plugin"
printf '{"name":"example","version":"1.2.3"}\n' >"$TMP/plugin/.claude-plugin/plugin.json"
printf ' \t1.2.3\r\n \n' >"$TMP/plugin/VERSION"
[ "$(plugin_manifest_name "$TMP/plugin")" = example ] || die 'manifest name'
[ "$(plugin_manifest_version "$TMP/plugin")" = 1.2.3 ] || die 'manifest version'
[ "$(plugin_version_file "$TMP/plugin")" = 1.2.3 ] || die 'trim VERSION'
pass 'readers use the plugin directory and trim VERSION'
printf '{}\n' >"$TMP/plugin/.claude-plugin/plugin.json"
reject "$TMP/plugin/.claude-plugin/plugin.json" plugin_manifest_name "$TMP/plugin"
reject "$TMP/plugin/.claude-plugin/plugin.json" plugin_manifest_version "$TMP/plugin"
reject "$TMP/missing/VERSION" plugin_version_file "$TMP/missing"
pass 'reader errors name the file'
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
printf 'one\n' >file; commit
first="$(git rev-parse HEAD)"
printf 'two\n' >file; commit
commit_on_branch "$first" HEAD || die 'ancestor refused'
if commit_on_branch HEAD "$first"; then die 'descendant accepted'; fi
pass 'commit_on_branch uses ancestry'

printf '%s plugin-tag checks passed\n' "$PASS"
