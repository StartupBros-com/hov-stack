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

SCRIPT="$ROOT/release/scripts/plugin-ci.sh"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
printf 'seed\n' >seed; commit
export BASE_SHA
BASE_SHA="$(git rev-parse HEAD)"
plugin a
bash "$SCRIPT" plugins/a >"$TMP/out" || die 'added VERSION needs no notes'
pass 'an added VERSION needs no notes'
commit; BASE_SHA="$(git rev-parse HEAD)"
plugin a 2.0.0
reject 'VERSION bump requires release notes' bash "$SCRIPT" plugins/a
pass 'untagged bump requires notes'
git tag a--v2.0.0
bash "$SCRIPT" plugins/a >"$TMP/out" || die 'tagged version required notes'
pass 'existing tag exempts bump notes'
git tag -d a--v2.0.0 >/dev/null
notes a 2.0.0
bash "$SCRIPT" plugins/a >"$TMP/out" || die 'good bump notes'
pass 'customer-ready bump notes pass'
printf '## Highlights\n- feat: developer copy\n' >plugins/a/docs/release-notes/v2.0.0.md
reject 'raw commit subject' bash "$SCRIPT" plugins/a
pass 'bad release notes fail CI'
notes a 2.0.0
printf '3.0.0\n' >plugins/a/VERSION
reject 'VERSION 3.0.0 does not match manifest version 2.0.0' bash "$SCRIPT" plugins/a
pass 'lockstep mismatch names both versions'
plugin a 2.0.0
printf '{"name":"wrong","version":"2.0.0"}\n' >plugins/a/.claude-plugin/plugin.json
reject 'manifest name wrong does not match directory a' bash "$SCRIPT" plugins/a
pass 'manifest name must match directory'
plugin a 2.0.0; rm plugins/a/skills/a/SKILL.md
reject 'missing plugins/a/skills/a/SKILL.md' bash "$SCRIPT" plugins/a
pass 'missing skill is named'
plugin a 2.0.0; mkdir -p plugins/a/tests
cat >plugins/a/tests/ci.sh <<'CI'
#!/usr/bin/env bash
set -euo pipefail
test "$PWD" = "$EXPECTED_DIR" || exit 43
exit 42
CI
export EXPECTED_DIR="$PWD/plugins/a"
chmod +x plugins/a/tests/ci.sh
reject 'a tests/ci.sh failed' bash "$SCRIPT" plugins/a
pass 'failing plugin suite fails CI'
cat >plugins/a/tests/ci.sh <<'CI'
#!/usr/bin/env bash
set -euo pipefail
test "$PWD" = "$EXPECTED_DIR"
CI
bash "$SCRIPT" plugins/a >"$TMP/out" || die 'successful suite'
pass 'suite runs in the plugin directory'
chmod -x plugins/a/tests/ci.sh
reject 'plugins/a/tests/ci.sh exists but is not executable' bash "$SCRIPT" plugins/a
pass 'a non-executable suite is a failure, not a skip'
chmod +x plugins/a/tests/ci.sh
plugin a 2.0.0-rc1
reject 'is not release semver' bash "$SCRIPT" plugins/a
pass 'prerelease VERSION is refused'
rm plugins/a/VERSION plugins/a/skills/a/SKILL.md
reject 'missing plugins/a/VERSION' bash "$SCRIPT" plugins/a
grep -Fq 'missing plugins/a/skills/a/SKILL.md' "$TMP/err" || die 'did not run all checks'
pass 'missing files do not stop other checks'

# The skill pack ships several skills and none named after itself; it still
# needs at least one skill directly under skills/.
plugin hov-stack 0.1.0; rm -r plugins/hov-stack/skills/hov-stack
mkdir -p plugins/hov-stack/skills/alpha; printf 'fixture skill\n' >plugins/hov-stack/skills/alpha/SKILL.md
bash "$SCRIPT" plugins/hov-stack >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'skill pack without a self-named skill'; }
pass 'the skill pack needs no skill named after itself'
rm -r plugins/hov-stack/skills/alpha; mkdir -p plugins/hov-stack/skills/alpha/nested
printf 'fixture skill\n' >plugins/hov-stack/skills/alpha/nested/SKILL.md
reject 'missing plugins/hov-stack/skills/<skill>/SKILL.md' bash "$SCRIPT" plugins/hov-stack
pass 'a skill pack with no top-level skill is named'
plugin b; rm plugins/b/skills/b/SKILL.md
mkdir -p plugins/b/skills/other; printf 'fixture skill\n' >plugins/b/skills/other/SKILL.md
reject 'missing plugins/b/skills/b/SKILL.md' bash "$SCRIPT" plugins/b
pass 'only the skill pack is exempt from the self-named skill'

# A bump while the previous version has not reached members (#702): the marketplace at
# the base still lists 1.0.0 while VERSION says 1.1.0, so the 1.2.0 notes must carry
# 1.1.0's Highlights. Notes older than the listed version (hov kept six drafts behind
# its published release) are never demanded.
git init -q -b main "$TMP/inflight"; cd "$TMP/inflight"
printf 'seed\n' >seed; commit
mkdir -p .claude-plugin plugins/c/docs/release-notes
printf '{"plugins":[{"name":"c","metadata":{"version":"1.0.0"}}]}\n' >.claude-plugin/marketplace.json
plugin c 1.1.0
printf '## Highlights\n- Customers can read the old changelog from the menu.\n' >plugins/c/docs/release-notes/v0.9.0.md
printf '## Highlights\n- Customers can roll back an update with one command.\n' >plugins/c/docs/release-notes/v1.1.0.md
commit; BASE_SHA="$(git rev-parse HEAD)"
plugin c 1.2.0
printf '## Highlights\n- Customers can pin an update to one version.\n\nChanges since v1.1.0:\n' >plugins/c/docs/release-notes/v1.2.0.md
reject 'v1.1.0 has not reached members' bash "$SCRIPT" plugins/c
grep -Fq "'Changes since v1.1.0' names a version members do not have" "$TMP/err" || { cat "$TMP/err"; die 'baseline line not checked through plugin-ci'; }
grep -Fq 'the marketplace at' "$TMP/err" || { cat "$TMP/err"; die 'the pin and base read are not named'; }
pass 'a bump over a version members do not have yet must carry its Highlights'
printf '## Highlights\n- Customers can pin an update to one version.\n- Customers can roll back an update with one command.\n\nChanges since v1.0.0:\n' >plugins/c/docs/release-notes/v1.2.0.md
bash "$SCRIPT" plugins/c >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'carried notes rejected'; }
pass 'carried Highlights pass, and notes older than the listed version are not demanded'
plugin c 1.1.0
printf '{"plugins":[]}\n' >.claude-plugin/marketplace.json
commit; BASE_SHA="$(git rev-parse HEAD)"
plugin c 1.2.0
printf '## Highlights\n- Customers can pin an update to one version.\n' >plugins/c/docs/release-notes/v1.2.0.md
bash "$SCRIPT" plugins/c >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'an unlisted plugin was asked to carry'; }
pass 'a plugin the marketplace does not list yet carries nothing'
plugin c 1.1.0
printf 'not json\n' >.claude-plugin/marketplace.json
commit; BASE_SHA="$(git rev-parse HEAD)"
plugin c 1.2.0
reject 'cannot read the version members have' bash "$SCRIPT" plugins/c
pass 'an unreadable marketplace fails the bump instead of skipping the check'

printf '%s plugin-ci checks passed\n' "$PASS"
