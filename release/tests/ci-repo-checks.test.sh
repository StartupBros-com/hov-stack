#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
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

SCRIPT="$ROOT/release/scripts/ci-repo-checks.sh"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
mkdir -p .github/workflows release/scripts .claude-plugin
printf seed >seed; commit
missing_helper="$(git rev-parse HEAD)"
printf helper >release/scripts/tool-drop-announce.sh; commit
script_only="$(git rev-parse HEAD)"
printf 'name: helper\n' >.github/workflows/hov-tool-drop-announce.yml
commit
export BASELINE_SHA
BASELINE_SHA="$(git rev-parse HEAD)"
pin="$BASELINE_SHA"
cp "$ROOT/.github/CODEOWNERS" .github/CODEOWNERS
printf '# no extra checks\n' >release/required-checks.tsv
pin_to() {
  printf 'name: train\njobs:\n  announce:\n    uses: acme/repo/.github/workflows/hov-tool-drop-announce.yml@%s\n' "$1" >.github/workflows/release-train.yml
}
pin_to "$pin"
commit
bash "$SCRIPT" >"$TMP/out" || die 'good baseline and helper'
pass 'ancestor baseline and helper pin pass without future plugin paths'
reject 'not an ancestor of HEAD' env BASELINE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$SCRIPT"
pass 'unavailable hardened baseline fails'
pin_to "$missing_helper"
reject "release/scripts/tool-drop-announce.sh is missing at the pinned sha $missing_helper" bash "$SCRIPT"
pass 'helper must exist in the pinned tree'
pin_to "$script_only"
reject ".github/workflows/hov-tool-drop-announce.yml is missing at the pinned sha $script_only" bash "$SCRIPT"
pass 'the reusable announce workflow must also exist in the pinned tree'
pin_to "$pin"
printf 'jobs:\n  announce:\n    uses: acme/repo/.github/workflows/hov-tool-drop-announce.yml@%s\n' "$missing_helper" >.github/workflows/other.yml
reject '2 distinct pinned shas' bash "$SCRIPT"
pass 'two different helper pins fail'
rm .github/workflows/other.yml
git switch -qc side
printf side >side; commit
side="$(git rev-parse HEAD)"
git switch -q main
pin_to "$side"
reject "pinned sha $side is not an ancestor of HEAD" bash "$SCRIPT"
pass 'helper pin from a side branch fails'
pin_to "$pin"
reject "hardened baseline $side is not an ancestor of HEAD" env BASELINE_SHA="$side" bash "$SCRIPT"
pass 'a hardened baseline on a side branch fails'
cp .github/CODEOWNERS "$TMP/owners"
sed '\|^/setup |d' "$TMP/owners" >.github/CODEOWNERS
reject 'missing required entry /setup' bash "$SCRIPT"
pass 'required owner entry is unconditional without plugins'
sed 's|^/hooks/ .*|/hooks/|' "$TMP/owners" >.github/CODEOWNERS
reject 'missing required entry /hooks/ with an @owner' bash "$SCRIPT"
pass 'an owner-less required entry fails'
cp "$TMP/owners" .github/CODEOWNERS
plugin hov-stack
mkdir -p hooks
reject 'CODEOWNERS lists /setup, which does not exist' bash "$SCRIPT"
pass 'future paths become mandatory when plugins exists'
touch setup
bash "$SCRIPT" >"$TMP/out" || die 'setup file should be allowed'
pass 'setup may be a file and existing plugin paths pass'
printf 'env:\n  RELEASE_PAT: nope\n' >.github/workflows/leak.yml
reject 'workflow .github/workflows/leak.yml contains forbidden user token RELEASE_PAT' bash "$SCRIPT"
pass 'user token error names workflow and token'
rm .github/workflows/leak.yml
for token in secrets.GH_PAT secrets.PAT secrets.GITHUB_PAT; do
  printf 'env:\n  TOKEN: %s\n' "$token" >.github/workflows/leak.yml
  reject "contains forbidden user token $token" bash "$SCRIPT"
done
pass 'all forbidden user token aliases fail'
printf 'env:\n  RELEASE_PATH: fine\n  OTHER: secrets.PATH_X\n' >.github/workflows/leak.yml
bash "$SCRIPT" >"$TMP/out" || die 'longer names false-positive'
pass 'longer names that merely contain a forbidden token pass'
for spelling in "secrets['GH_PAT']" 'secrets["PAT"]' secrets.gh_pat; do
  printf 'env:\n  TOKEN: %s\n' "$spelling" >.github/workflows/leak.yml
  reject 'contains forbidden user token' bash "$SCRIPT"
done
pass 'bracket and lowercase spellings of user tokens fail'
rm .github/workflows/leak.yml
printf 'jobs:\n  unsafe:\n    steps:\n      - uses: actions/create-github-app-token@pin\n' >.github/workflows/mint.yml
reject 'workflow .github/workflows/mint.yml job unsafe mints an App token outside environment: release' bash "$SCRIPT"
pass 'minting job without environment fails by job id'
for environment in 'release' '{name: release}'; do
  printf 'jobs:\n  safe:\n    environment: %s\n    steps:\n      - uses: actions/create-github-app-token@pin\n' "$environment" >.github/workflows/mint.yml
  bash "$SCRIPT" >"$TMP/out" || die 'release environment refused'
done
pass 'string and map release environments pass'
printf 'jobs: [\n' >.github/workflows/mint.yml
reject 'cannot parse jobs in workflow .github/workflows/mint.yml' bash "$SCRIPT"
pass 'an unparsable workflow fails closed'
printf 'jobs:\n  safe:\n    environment: release\n    steps:\n      - uses: actions/create-github-app-token@pin\n' >.github/workflows/mint.yml
touch plugins/junk
reject 'plugin path plugins/junk is not a directory carrying' bash "$SCRIPT"
pass 'non-plugin children fail'
rm plugins/junk
for row in 'ci.yml job' $'dir/ci.yml\tjob' $'ci.yml\tjob\textra' $'ci.yml\t'; do
  printf '%s\n' "$row" >release/required-checks.tsv
  reject 'exactly two non-empty tab-separated fields' bash "$SCRIPT"
done
pass 'required checks reject malformed fields and non-basenames'
printf '# extra check\n\nci.yml\tsetup, hooks, suites, secrets\n' >release/required-checks.tsv
bash "$SCRIPT" >"$TMP/out" || die 'valid TSV refused'
pass 'required checks accept comments blanks and a job with spaces'
pin_to "$pin"; rm .github/workflows/release-train.yml
reject '0 distinct pinned shas' bash "$SCRIPT"
pass 'missing helper pin fails'
pin_to "$pin"
mkdir -p docs/release
printf '#!/usr/bin/env bash\n# see docs/nowhere.md and plugins/x/docs/release-notes/v1.0.0.md\n' >release/scripts/doc-pointer.sh
reject 'release/scripts/doc-pointer.sh names docs/nowhere.md, which does not exist' bash "$SCRIPT"
pass 'a release script naming a missing repository docs path fails'
printf '#!/usr/bin/env bash\n# see docs/release/plugin-release-recipe.md and plugins/x/docs/release-notes/v1.0.0.md\n' >release/scripts/doc-pointer.sh
reject 'release/scripts/doc-pointer.sh names docs/release/plugin-release-recipe.md, which does not exist' bash "$SCRIPT"
printf '# recipe\n' >docs/release/plugin-release-recipe.md
bash "$SCRIPT" >"$TMP/out" || die 'existing docs path refused'
grep -q 'ok - repository release checks passed' "$TMP/out" || die 'docs path guard did not pass'
pass 'an existing repository docs path passes and a plugin notes path is not matched'
printf 'jobs:\n  safe:\n    steps:\n      - run: echo see docs/missing.md\n' >.github/workflows/doc.yml
reject '.github/workflows/doc.yml names docs/missing.md, which does not exist' bash "$SCRIPT"
pass 'a workflow naming a missing repository docs path fails'
rm .github/workflows/doc.yml
printf '#!/usr/bin/env bash\n# see ./docs/gone.md\n' >release/scripts/doc-pointer.sh
reject 'release/scripts/doc-pointer.sh names docs/gone.md, which does not exist' bash "$SCRIPT"
pass 'a ./docs path is checked without its prefix'
printf '#!/usr/bin/env bash\n# my-docs/none.md foo.docs/none.md {x}docs/none.md docs/none.mdx docs/none.md.bak https://example.com/docs/none.md\n' >release/scripts/doc-pointer.sh
bash "$SCRIPT" >"$TMP/out" || die 'non-root docs forms refused'
pass 'longer names, prefixes, suffixes and URLs are not matched'
printf '#!/usr/bin/env bash\n# see docs/gone.md.\n' >release/scripts/doc-pointer.sh
reject 'release/scripts/doc-pointer.sh names docs/gone.md, which does not exist' bash "$SCRIPT"
pass 'a sentence-ending period after .md is left out of the path that is resolved'
rm release/scripts/doc-pointer.sh

printf '%s ci-repo-checks checks passed\n' "$PASS"
