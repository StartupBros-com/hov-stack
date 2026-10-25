#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/release/scripts/validate-marketplace.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REMOTE_ROOT="$TMP/remotes"
WORK="$TMP/work"
mkdir -p "$REMOTE_ROOT/StartupBros-com" "$WORK/.claude-plugin"

pass_count=0
fail_count=0

expect_pass() {
  local label="$1"
  shift
  if "$@" >"$TMP/output" 2>&1; then
    printf 'ok - %s\n' "$label"
    pass_count=$((pass_count + 1))
  else
    printf 'not ok - %s\n' "$label" >&2
    command cat "$TMP/output" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"$TMP/output" 2>&1; then
    printf 'not ok - %s unexpectedly passed\n' "$label" >&2
    exit 1
  else
    printf 'ok - %s\n' "$label"
    fail_count=$((fail_count + 1))
  fi
}

# expect_fail_reason LABEL NEEDLE CMD...: the command must fail, and its
# output must name the rule that refused it, so a planted negative cannot be
# carried by some other check.
expect_fail_reason() {
  local label="$1" needle="$2"
  shift 2
  if "$@" >"$TMP/output" 2>&1; then
    printf 'not ok - %s unexpectedly passed\n' "$label" >&2
    exit 1
  elif ! grep -Fq -- "$needle" "$TMP/output"; then
    printf 'not ok - %s failed for another reason\n' "$label" >&2
    command cat "$TMP/output" >&2
    exit 1
  else
    printf 'ok - %s\n' "$label"
    fail_count=$((fail_count + 1))
  fi
}

write_valid_release_workflow() {
  local repo="$1"
  cat >"$repo/.github/workflows/release-train.yml" <<'EOF'
name: Release train
on:
  release:
    types: [published, edited]
permissions:
  contents: read
  id-token: write
jobs:
  announce:
    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@c981b872ebf650805200ad72c8b7142232f8b3f6
EOF
}

make_plugin() {
  local name="$1" version="$2" tag="$3"
  local repo="$TMP/$name"
  git init -q "$repo"
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.com
  mkdir -p "$repo/.claude-plugin" "$repo/skills/$name" "$repo/.github/workflows"
  jq -n --arg name "$name" --arg version "$version" '{name: $name, version: $version}' >"$repo/.claude-plugin/plugin.json"
  printf '%s\n' "$version" >"$repo/VERSION"
  printf '# fixture\n' >"$repo/skills/$name/SKILL.md"
  write_valid_release_workflow "$repo"
  git -C "$repo" add .claude-plugin/plugin.json "skills/$name/SKILL.md" VERSION .github/workflows/release-train.yml
  git -C "$repo" commit -qm fixture
  git -C "$repo" branch -M main
  git -C "$repo" tag "$tag"
  git clone -q --bare "$repo" "$REMOTE_ROOT/StartupBros-com/$name.git"
  git -C "$repo" rev-parse HEAD
}

TOKEN_SHA="$(make_plugin token-eater 1.2.3 v1.2.3)"
PRO_SHA="$(make_plugin pro-gate 2.0.0 v2.0.0)"
OPTIMIZER_SHA="$(make_plugin harness-optimizer 0.2.0 v0.2.0)"

write_manifest() {
  local token_sha="$1" pro_sha="$2" token_id="$3" token_name="${4:-token-eater}" token_version="${5:-1.2.3}" token_tag="${6:-v1.2.3}"
  jq -n \
    --arg token_name "$token_name" --arg token_sha "$token_sha" --arg token_version "$token_version" --arg token_tag "$token_tag" --argjson token_id "$token_id" \
    --arg pro_sha "$pro_sha" \
    '{
      name: "hov",
      owner: {name: "House of Vibe", url: "https://houseofvibe.ai"},
      metadata: {description: "Tools for builders.", version: "1.0.0"},
      plugins: [
        {name: $token_name, source: {source: "url", url: "https://github.com/StartupBros-com/token-eater.git", sha: $token_sha}, description: "Token eater.", metadata: {version: $token_version, releaseId: $token_id, releaseTag: $token_tag}},
        {name: "pro-gate", source: {source: "url", url: "https://github.com/StartupBros-com/pro-gate.git", sha: $pro_sha}, description: "Pro gate.", metadata: {version: "2.0.0", releaseId: 20, releaseTag: "v2.0.0"}}
      ]
    }' >"$WORK/.claude-plugin/marketplace.json"
}

# One full fetch per distinct monorepo remote per run, and nothing left under
# the validator's TMPDIR once it exits, pass or fail. The traced run sets
# TMPDIR and GIT_TRACE on the expect_* call; the trace is reset here.
assert_monorepo_cache() {
  local label="$1" fetches leftovers
  fetches="$(grep -c -F -- '+refs/heads/main:refs/announce/main' "$TMP/git-trace" || true)"
  leftovers="$(find "$TMP/validator-tmp" -mindepth 1 -maxdepth 1 | wc -l)"
  : >"$TMP/git-trace"
  if [[ "$fetches" == 1 && "$leftovers" == 0 ]]; then
    printf 'ok - %s\n' "$label"
    pass_count=$((pass_count + 1))
  else
    printf 'not ok - %s (fetches=%s leftovers=%s)\n' "$label" "$fetches" "$leftovers" >&2
    exit 1
  fi
}

validate() {
  (cd "$WORK" && MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" ALLOW_LOCAL_FILE_REMOTES=1 "$VALIDATOR" "$@")
}

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
expect_pass "valid syntax" validate syntax
expect_pass "valid full fixture and U7 expectations" env EXPECTED_PLUGIN_NAME=token-eater EXPECTED_PLUGIN_VERSION=1.2.3 EXPECTED_RELEASE_ID=10 EXPECTED_RELEASE_TAG=v1.2.3 EXPECTED_SHA="$TOKEN_SHA" EXPECTED_PAYLOAD_PATHS=.claude-plugin/plugin.json,skills/token-eater/SKILL.md bash -c 'cd "$1" && MARKETPLACE_TEST_REMOTE_ROOT="$2" ALLOW_LOCAL_FILE_REMOTES=1 "$3" full' _ "$WORK" "$REMOTE_ROOT" "$VALIDATOR"

jq --arg sha "$OPTIMIZER_SHA" '.plugins += [{name: "harness-optimizer", source: {source: "url", url: "https://github.com/StartupBros-com/harness-optimizer.git", sha: $sha}, description: "Evidence-backed harness repairs.", metadata: {version: "0.2.0", releaseId: 30, releaseTag: "v0.2.0"}}]' "$WORK/.claude-plugin/marketplace.json" >"$TMP/optimizer.json"
mv "$TMP/optimizer.json" "$WORK/.claude-plugin/marketplace.json"
expect_pass "harness-optimizer approved source passes full validation" validate full
jq '(.plugins[] | select(.name == "harness-optimizer") | .source.url) = "https://github.com/attacker/harness-optimizer.git"' "$WORK/.claude-plugin/marketplace.json" >"$TMP/optimizer-wrong-source.json"
mv "$TMP/optimizer-wrong-source.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "harness-optimizer cannot change repository owner" validate syntax

# Announcement-contract failures are pinned-tree defects. Omit release metadata
# on these fixtures so the failure is the contract itself, never tag resolution.
write_unreleased_manifest() {
  local sha="$1"
  write_manifest "$sha" "$PRO_SHA" 10
  jq 'del(.plugins[0].metadata)' "$WORK/.claude-plugin/marketplace.json" >"$TMP/unreleased.json"
  mv "$TMP/unreleased.json" "$WORK/.claude-plugin/marketplace.json"
}
publish_fixture_commit() {
  git -C "$TMP/token-eater" add -A
  git -C "$TMP/token-eater" commit -qm "$1"
  git -C "$TMP/token-eater" push -q "$REMOTE_ROOT/StartupBros-com/token-eater.git" HEAD:main
}
restore_valid_token_fixture() {
  jq -n '{name: "token-eater", version: "1.2.3"}' >"$TMP/token-eater/.claude-plugin/plugin.json"
  printf '1.2.3\n' >"$TMP/token-eater/VERSION"
  write_valid_release_workflow "$TMP/token-eater"
}
validate_default_branch_failure() {
  write_unreleased_manifest "$TOKEN_SHA"
  expect_fail "$1" validate full
}

git -C "$TMP/token-eater" rm -q VERSION
publish_fixture_commit 'missing version'
validate_default_branch_failure "default branch without VERSION rejected before release"

restore_valid_token_fixture
printf '9.9.9\n' >"$TMP/token-eater/VERSION"
publish_fixture_commit 'mismatched version'
validate_default_branch_failure "VERSION must match default-branch plugin manifest"

restore_valid_token_fixture
jq '.version = null' "$TMP/token-eater/.claude-plugin/plugin.json" >"$TMP/null-version.json"
mv "$TMP/null-version.json" "$TMP/token-eater/.claude-plugin/plugin.json"
printf '1.2.3\n' >"$TMP/token-eater/VERSION"
publish_fixture_commit 'null manifest version'
validate_default_branch_failure "default-branch manifest version must be a semver string"

restore_valid_token_fixture
cat >"$TMP/token-eater/.github/workflows/release-train.yml" <<'EOF'
name: Release train
on:
  release:
    types: [published, edited]
permissions:
  contents: read
  id-token: write
jobs:
  decoy:
    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@c981b872ebf650805200ad72c8b7142232f8b3f6
  announce:
    uses: attacker/other/.github/workflows/hov-tool-drop-announce.yml@c981b872ebf650805200ad72c8b7142232f8b3f6
EOF
publish_fixture_commit 'blessed pin in unrelated job'
validate_default_branch_failure "blessed pin in an unrelated job cannot authorize announce"

restore_valid_token_fixture
yq -i '.on.release.types = ["published"]' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'missing edited trigger'
validate_default_branch_failure "release train requires published and edited triggers"

restore_valid_token_fixture
yq -i '.jobs.announce.permissions = {"contents": "read"}' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'announce job shadows oidc permission'
validate_default_branch_failure "announce job requires effective OIDC permission"

restore_valid_token_fixture
printf '\n# TOOL_RELEASE_ANNOUNCE_SECRET must never return\n' >>"$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'static announce secret'
validate_default_branch_failure "static announce secret is forbidden"

# --- plugin eval suites (claude plugin eval, v2.1.269+) are inert to the contract ---
# A catalog plugin that ships evals/ and the experimental.evals manifest key must
# validate exactly like one that does not (hov-marketplace#163).
restore_valid_token_fixture
mkdir -p "$TMP/token-eater/evals/smoke/graders"
printf -- '---\nmax_turns: 2\n---\nSay hi.\n' >"$TMP/token-eater/evals/smoke/prompt.md"
printf -- '---\ntype: regex\npattern: hi\n---\n' >"$TMP/token-eater/evals/smoke/graders/says-hi.md"
jq '. + {experimental: {evals: "evals"}}' "$TMP/token-eater/.claude-plugin/plugin.json" >"$TMP/evals-manifest.json"
mv "$TMP/evals-manifest.json" "$TMP/token-eater/.claude-plugin/plugin.json"
publish_fixture_commit 'ship a plugin eval suite'
write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
expect_pass "default branch carrying evals/ and experimental.evals accepted" validate full
rm -rf "$TMP/token-eater/evals"

# --- announce-workflow pin: verified structurally, not against one constant ---
# A frozen SHA allowlist rejected the CORRECT state the moment the shared
# workflow advanced (#34 re-pinned six of eight repos). The pin must be a real
# marketplace commit that carries the announce workflow; anything else fails.

restore_valid_token_fixture
yq -i '.jobs.announce.uses = "StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@main"' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'branch ref instead of a commit pin'
validate_default_branch_failure "a branch ref is never an acceptable announce pin"

restore_valid_token_fixture
yq -i '.jobs.announce.uses = "StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@v1.0.0"' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'tag ref instead of a commit pin'
validate_default_branch_failure "a tag ref is never an acceptable announce pin"

restore_valid_token_fixture
yq -i '.jobs.announce.uses = "StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@0123456789abcdef0123456789abcdef01234567"' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'well-formed but nonexistent commit'
validate_default_branch_failure "a SHA that is not a marketplace commit is rejected"

# The live successor pin (#34) must pass exactly like the original: this is the
# regression that a frozen constant caused.
restore_valid_token_fixture
yq -i '.jobs.announce.uses = "StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@08f7d22f3a5b59b1658ab2e96a20d0d3c352869c"' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'advanced announce pin'
write_unreleased_manifest "$TOKEN_SHA"
expect_pass "an advanced-but-real announce pin is blessed" validate full

# An exact pin can still be demanded explicitly (release-time verification).
write_unreleased_manifest "$TOKEN_SHA"
expect_fail "explicit ANNOUNCE_WORKFLOW_PIN still enforces one exact SHA" env ANNOUNCE_WORKFLOW_PIN=c981b872ebf650805200ad72c8b7142232f8b3f6 MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" ALLOW_LOCAL_FILE_REMOTES=1 bash -c 'cd "$1" && "$2" full' _ "$WORK" "$VALIDATOR"

restore_valid_token_fixture
publish_fixture_commit 'restore valid announcement contract'
write_unreleased_manifest "$TOKEN_SHA"
expect_pass "restored default branch announcement contract" validate full

printf '{broken\n' >"$WORK/.claude-plugin/marketplace.json"
expect_fail "malformed JSON" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
expect_pass "private sources stay syntax-only and network-free" env MARKETPLACE_MANIFEST="$WORK/.claude-plugin/marketplace.json" "$VALIDATOR" syntax
expect_fail "local file remotes require explicit override" env MARKETPLACE_MANIFEST="$WORK/.claude-plugin/marketplace.json" MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" "$VALIDATOR" full

BAD_SHA="0000000000000000000000000000000000000000"
write_manifest "$BAD_SHA" "$PRO_SHA" 10
expect_fail "unreachable SHA" validate full

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
(cd "$WORK" && git init -q && git config user.name Fixture && git config user.email fixture@example.com && git add .claude-plugin/marketplace.json && git commit -qm base)
write_manifest "$TOKEN_SHA" "$PRO_SHA" 9
expect_fail "release metadata rollback" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" ALLOW_LOCAL_FILE_REMOTES=1 bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$TOKEN_SHA" "$PRO_SHA" 11 token-eater 1.2.2 v1.2.2
expect_fail "newer release id cannot downgrade semver" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$TOKEN_SHA" "$PRO_SHA" 11 token-eater 1.2.3 v1.2.3
expect_fail "newer release id requires semver increase" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$PRO_SHA" "$PRO_SHA" 10
expect_fail "equal release id cannot change source" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '(.plugins[] | select(.name == "token-eater") | .source.url) = "https://github.com/attacker/token-eater.git"' "$WORK/.claude-plugin/marketplace.json" > "$TMP/wrong-source.json"
mv "$TMP/wrong-source.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "approved plugin cannot change repository owner" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10 wrong-name
expect_fail "pinned manifest name mismatch" validate full

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10 token-eater 1.2.4 v1.2.4
expect_fail "pinned manifest version mismatch" validate full

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10 token-eater 1.2.3 v9.9.9
expect_fail "release tag mismatch" validate syntax

write_manifest "${TOKEN_SHA^^}" "$PRO_SHA" 10
expect_fail "uppercase SHA rejected" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins += [.plugins[0]]' "$WORK/.claude-plugin/marketplace.json" >"$TMP/duplicate.json"
mv "$TMP/duplicate.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "duplicate plugin names" validate syntax

# --- card block (Tool Drop copy lives in the manifest; shape-gated here) ---

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two", "three"], run: "Then run it"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-ok.json"
mv "$TMP/card-ok.json" "$WORK/.claude-plugin/marketplace.json"
expect_pass "valid card block accepted" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two"], run: "Then run it"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-tworows.json"
mv "$TMP/card-tworows.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "card must carry exactly three rows" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq --arg long "$(printf 'x%.0s' $(seq 1 181))" '.plugins[0].card = {rows: [$long, "two", "three"], run: "Then run it"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-longrow.json"
mv "$TMP/card-longrow.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "card row over 180 chars rejected" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two", "three"], run: "Then run it", banner: "nope"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-unknown.json"
mv "$TMP/card-unknown.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "unknown card key rejected" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two", "three"]}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-norun.json"
mv "$TMP/card-norun.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "card without run line rejected" validate syntax

# --- both entry shapes (U6): git-subdir entries pin plugins/<name>/ in one monorepo ---
# One local monorepo remote stands in for the renamed repository, so no case
# needs the network. Its root carries only the workflow set: no root VERSION,
# no root plugin manifest, no root skill directory.

MONOREPO="$TMP/hov-stack"
MONOREPO_REMOTE="$REMOTE_ROOT/StartupBros-com/hov-stack.git"
MONOREPO_URL="https://github.com/StartupBros-com/hov-stack.git"
git init -q "$MONOREPO"
git -C "$MONOREPO" config user.name Fixture
git -C "$MONOREPO" config user.email fixture@example.com
mkdir -p "$MONOREPO/.github/workflows"
write_valid_release_workflow "$MONOREPO"
git -C "$MONOREPO" add .github/workflows/release-train.yml
git -C "$MONOREPO" commit -qm 'root workflow set'
git -C "$MONOREPO" branch -M main
git init -q --bare "$MONOREPO_REMOTE"

publish_monorepo() {
  git -C "$MONOREPO" push -q "$MONOREPO_REMOTE" main --tags
}

# add_subdir_plugin NAME VERSION: commits plugins/NAME/ on main, tags
# NAME--vVERSION, publishes, prints the commit.
add_subdir_plugin() {
  local name="$1" version="$2"
  local dir="$MONOREPO/plugins/$name"
  mkdir -p "$dir/.claude-plugin" "$dir/skills/$name"
  jq -n --arg name "$name" --arg version "$version" '{name: $name, version: $version}' >"$dir/.claude-plugin/plugin.json"
  printf '%s\n' "$version" >"$dir/VERSION"
  printf '# fixture\n' >"$dir/skills/$name/SKILL.md"
  git -C "$MONOREPO" add "plugins/$name"
  git -C "$MONOREPO" commit -qm "$name $version"
  git -C "$MONOREPO" tag "$name--v$version"
  publish_monorepo
  git -C "$MONOREPO" rev-parse HEAD
}

# add_pack_plugin VERSION: commits the skill pack in its real layout, several
# skills under skills/<skill>/ and none named after the pack, tags
# hov-stack--vVERSION, publishes, prints the commit.
add_pack_plugin() {
  local version="$1" skill
  local dir="$MONOREPO/plugins/hov-stack"
  mkdir -p "$dir/.claude-plugin"
  jq -n --arg version "$version" '{name: "hov-stack", version: $version}' >"$dir/.claude-plugin/plugin.json"
  printf '%s\n' "$version" >"$dir/VERSION"
  for skill in alpha beta; do
    mkdir -p "$dir/skills/$skill"
    printf '# fixture\n' >"$dir/skills/$skill/SKILL.md"
  done
  git -C "$MONOREPO" add plugins/hov-stack
  git -C "$MONOREPO" commit -qm "hov-stack $version"
  git -C "$MONOREPO" tag "hov-stack--v$version"
  publish_monorepo
  git -C "$MONOREPO" rev-parse HEAD
}

SIGN_SHA="$(add_subdir_plugin sign-it 0.5.0)"
PACK_SHA="$(add_pack_plugin 0.1.0)"
PRO_SUBDIR_SHA="$(add_subdir_plugin pro-gate 2.1.0)"

# The url fixtures (token-eater 10, pro-gate 20) plus two git-subdir entries.
write_mixed_manifest() {
  write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
  jq --arg url "$MONOREPO_URL" --arg sign_sha "$SIGN_SHA" --arg pack_sha "$PACK_SHA" '.plugins += [
    {name: "sign-it", source: {source: "git-subdir", url: $url, path: "plugins/sign-it", sha: $sign_sha}, description: "Sign it.", metadata: {version: "0.5.0", releaseId: 40, releaseTag: "sign-it--v0.5.0"}},
    {name: "hov-stack", source: {source: "git-subdir", url: $url, path: "plugins/hov-stack", sha: $pack_sha}, description: "The stack.", metadata: {version: "0.1.0", releaseId: 50, releaseTag: "hov-stack--v0.1.0"}}
  ]' "$WORK/.claude-plugin/marketplace.json" >"$TMP/mixed.json"
  mv "$TMP/mixed.json" "$WORK/.claude-plugin/marketplace.json"
}

# mutate_manifest [jq options] FILTER: rewrites the working manifest in place.
mutate_manifest() {
  jq "$@" "$WORK/.claude-plugin/marketplace.json" >"$TMP/mutated.json"
  mv "$TMP/mutated.json" "$WORK/.claude-plugin/marketplace.json"
}

validate_against_base() {
  (cd "$WORK" && BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json "$VALIDATOR" syntax)
}

write_mixed_manifest
expect_pass "mixed manifest passes syntax validation" validate syntax
mkdir -p "$TMP/validator-tmp"
TMPDIR="$TMP/validator-tmp" GIT_TRACE="$TMP/git-trace" expect_pass "mixed manifest passes full validation" validate full
assert_monorepo_cache "full validation fetches main once for two git-subdir entries and removes its cache"
TMPDIR="$TMP/validator-tmp" GIT_TRACE="$TMP/git-trace" expect_pass "git-subdir entry accepts the prefixed expected tag and payload paths under its path" env EXPECTED_PLUGIN_NAME=sign-it EXPECTED_PLUGIN_VERSION=0.5.0 EXPECTED_RELEASE_ID=40 EXPECTED_RELEASE_TAG=sign-it--v0.5.0 EXPECTED_SHA="$SIGN_SHA" EXPECTED_PAYLOAD_PATHS=.claude-plugin/plugin.json,skills/sign-it/SKILL.md bash -c 'cd "$1" && MARKETPLACE_TEST_REMOTE_ROOT="$2" ALLOW_LOCAL_FILE_REMOTES=1 "$3" full' _ "$WORK" "$REMOTE_ROOT" "$VALIDATOR"
assert_monorepo_cache "an expected-inputs full run also fetches main once and removes its cache"
expect_fail_reason "the monorepo url is one configuration value: another literal refuses every git-subdir entry" "git-subdir entry must use the monorepo source https://github.com/StartupBros-com/scratch.git" env MONOREPO_SOURCE_URL=https://github.com/StartupBros-com/scratch.git bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

# Twin: a git-subdir entry needs no root VERSION, root manifest or root skill
# directory (the fixture has none) and no root release train either.
git -C "$MONOREPO" rm -q .github/workflows/release-train.yml
git -C "$MONOREPO" commit -qm 'no root release train'
publish_monorepo
expect_pass "git-subdir entry is not required to have a root release train" validate full
mkdir -p "$MONOREPO/.github/workflows"
write_valid_release_workflow "$MONOREPO"
git -C "$MONOREPO" add .github/workflows/release-train.yml
git -C "$MONOREPO" commit -qm 'restore root release train'
publish_monorepo

# Negative: a root release train that is present must satisfy the contract.
printf '\n# TOOL_RELEASE_ANNOUNCE_SECRET must never return\n' >>"$MONOREPO/.github/workflows/release-train.yml"
git -C "$MONOREPO" commit -qam 'static secret at the monorepo root'
publish_monorepo
expect_fail_reason "static announce secret in the monorepo root release train rejected" "release train still uses the static announce secret" validate full
write_valid_release_workflow "$MONOREPO"
git -C "$MONOREPO" commit -qam 'restore root release train contract'
publish_monorepo

# Negative: lockstep on main for the plugin's own VERSION.
printf '9.9.9\n' >"$MONOREPO/plugins/sign-it/VERSION"
git -C "$MONOREPO" commit -qam 'sign-it VERSION off lockstep'
publish_monorepo
expect_fail_reason "git-subdir plugins/<name>/VERSION must match the plugin manifest on main" "main plugins/sign-it/VERSION 9.9.9 differs from manifest 0.5.0" validate full
printf '0.5.0\n' >"$MONOREPO/plugins/sign-it/VERSION"
git -C "$MONOREPO" commit -qam 'restore sign-it lockstep'
publish_monorepo

# Negative: the skill pack's pin must carry at least one skill directly under
# skills/; a SKILL.md two levels down does not count.
git -C "$MONOREPO" rm -rq plugins/hov-stack/skills
mkdir -p "$MONOREPO/plugins/hov-stack/skills/alpha/nested"
printf '# fixture\n' >"$MONOREPO/plugins/hov-stack/skills/alpha/nested/SKILL.md"
git -C "$MONOREPO" add plugins/hov-stack
git -C "$MONOREPO" commit -qm 'hov-stack with no top-level skill'
publish_monorepo
BARE_PACK_SHA="$(git -C "$MONOREPO" rev-parse HEAD)"
write_mixed_manifest
mutate_manifest --arg sha "$BARE_PACK_SHA" '(.plugins[] | select(.name == "hov-stack") | .source.sha) = $sha'
expect_fail_reason "skill pack pin with no top-level skill rejected" "plugin hov-stack pin has no skill at plugins/hov-stack/skills/<skill>/SKILL.md" validate full
git -C "$MONOREPO" revert --no-edit HEAD >/dev/null
publish_monorepo

# Twin: only the pack is exempt. Any other git-subdir plugin still needs
# skills/<name>/SKILL.md, even with another skill beside it.
git -C "$MONOREPO" rm -q plugins/sign-it/skills/sign-it/SKILL.md
mkdir -p "$MONOREPO/plugins/sign-it/skills/other"
printf '# fixture\n' >"$MONOREPO/plugins/sign-it/skills/other/SKILL.md"
git -C "$MONOREPO" add plugins/sign-it
git -C "$MONOREPO" commit -qm 'sign-it without its own skill'
publish_monorepo
NO_SELF_SKILL_SHA="$(git -C "$MONOREPO" rev-parse HEAD)"
write_mixed_manifest
mutate_manifest --arg sha "$NO_SELF_SKILL_SHA" '(.plugins[] | select(.name == "sign-it") | .source.sha) = $sha'
expect_fail_reason "a non-pack git-subdir pin without skills/<name>/SKILL.md rejected" "plugin sign-it pin is missing plugins/sign-it/skills/sign-it/SKILL.md" validate full
git -C "$MONOREPO" revert --no-edit HEAD >/dev/null
publish_monorepo

# Negative: a prefixed tag on a commit that is not on main is reachable at
# the remote but is not a main sha. The second git-subdir entry carries the
# bad pin: the first entry's fetch must be reused for the traced count to
# read one on the fail path, so a per-entry cache would read two here too.
git -C "$MONOREPO" checkout -q -b side
printf '0.2.0\n' >"$MONOREPO/plugins/hov-stack/VERSION"
jq '.version = "0.2.0"' "$MONOREPO/plugins/hov-stack/.claude-plugin/plugin.json" >"$TMP/side-manifest.json"
mv "$TMP/side-manifest.json" "$MONOREPO/plugins/hov-stack/.claude-plugin/plugin.json"
git -C "$MONOREPO" commit -qam 'hov-stack 0.2.0 on a side branch'
git -C "$MONOREPO" tag hov-stack--v0.2.0
SIDE_SHA="$(git -C "$MONOREPO" rev-parse HEAD)"
git -C "$MONOREPO" push -q "$MONOREPO_REMOTE" side hov-stack--v0.2.0
git -C "$MONOREPO" checkout -q main
write_mixed_manifest
mutate_manifest --arg sha "$SIDE_SHA" '(.plugins[] | select(.name == "hov-stack")) |= (.source.sha = $sha | .metadata = {version: "0.2.0", releaseId: 51, releaseTag: "hov-stack--v0.2.0"})'
TMPDIR="$TMP/validator-tmp" GIT_TRACE="$TMP/git-trace" expect_fail_reason "git-subdir pinned commit must be reachable from main" "plugin hov-stack pinned commit is not reachable from main at" validate full
assert_monorepo_cache "a failing full run reuses the first entry's fetch and still removes its cache"

# Twin: a url entry's release train may reference the shared workflow under
# the new repository name during the window.
yq -i '.jobs.announce.uses = "StartupBros-com/hov-stack/.github/workflows/hov-tool-drop-announce.yml@c981b872ebf650805200ad72c8b7142232f8b3f6"' "$TMP/token-eater/.github/workflows/release-train.yml"
publish_fixture_commit 'announce reference under the new repository name'
write_mixed_manifest
expect_pass "url entry may reference the shared workflow under the new repository name" validate full
restore_valid_token_fixture
publish_fixture_commit 'restore announce reference'

# Syntax negatives: each is the valid mixed manifest with one field changed.
write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .source.url) = "https://github.com/StartupBros-com/sign-it.git"'
expect_fail_reason "git-subdir url under another repository of the same owner rejected" "plugin sign-it git-subdir entry must use the monorepo source" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it")) |= (.name = "sign--it" | .source.path = "plugins/sign--it" | .metadata.releaseTag = "sign--it--v0.5.0")'
expect_fail_reason "plugin name containing -- rejected" "plugin names must not contain --, the release tag separator: sign--it" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "hov-stack")) |= (.source = {source: "url", url: "https://github.com/StartupBros-com/hov-stack.git", sha: .source.sha} | .metadata.releaseTag = "v0.1.0")'
expect_fail_reason "hov-stack is admitted only as a git-subdir entry" "plugin hov-stack is not approved for this marketplace" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .metadata.releaseTag) = "v0.5.0"'
expect_fail_reason "git-subdir entry with a v-tag rejected" "plugin sign-it metadata.releaseTag does not match metadata.version for a git-subdir entry" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .source.path) = "plugins/sign-it-old"'
expect_fail_reason "git-subdir path must be plugins/<name>" "plugin sign-it git-subdir entry path must be plugins/sign-it" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it")) |= del(.metadata)'
expect_fail_reason "git-subdir entry must carry release metadata" "marketplace manifest has an invalid shape" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .metadata.releaseTag) = ""'
expect_fail_reason "git-subdir entry must carry a non-empty release tag" "plugin sign-it git-subdir entry must carry a non-empty release tag" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .metadata.version) = ""'
expect_fail_reason "git-subdir entry with an empty version rejected before the tag rule" "plugin sign-it git-subdir entry must carry release metadata" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .source.path) = "plugins/sign-it\u001f"'
expect_fail_reason "control character in a git-subdir path rejected by the schema" "marketplace manifest has an invalid shape" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .metadata.version) = "0.5.0\u001f"'
expect_fail_reason "control character in metadata.version rejected by the schema" "marketplace manifest has an invalid shape" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .metadata.releaseTag) = "sign-it--v0.5.0\u001f"'
expect_fail_reason "control character in metadata.releaseTag rejected by the schema" "marketplace manifest has an invalid shape" validate syntax

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it")) |= (.name = "scratch" | .source.path = "plugins/scratch" | .metadata.releaseTag = "scratch--v0.5.0")'
expect_fail_reason "git-subdir entry with an unapproved name rejected" "plugin scratch is not approved for this marketplace" validate syntax

# Transition cases against a committed mixed base: the only permitted shape
# change is url to git-subdir with a new release id and the prefixed tag.
write_mixed_manifest
(cd "$WORK" && git add .claude-plugin/marketplace.json && git commit -qm 'mixed base')

write_mixed_manifest
mutate_manifest --arg url "$MONOREPO_URL" --arg sha "$PRO_SUBDIR_SHA" '(.plugins[] | select(.name == "pro-gate")) |= (.source = {source: "git-subdir", url: $url, path: "plugins/pro-gate", sha: $sha} | .metadata = {version: "2.1.0", releaseId: 21, releaseTag: "pro-gate--v2.1.0"})'
expect_pass "url to git-subdir with a new release id and the prefixed tag passes" validate_against_base

write_mixed_manifest
mutate_manifest --arg url "$MONOREPO_URL" --arg sha "$PRO_SUBDIR_SHA" '(.plugins[] | select(.name == "pro-gate")) |= (.source = {source: "git-subdir", url: $url, path: "plugins/pro-gate", sha: $sha} | .metadata = {version: "2.0.0", releaseId: 20, releaseTag: "pro-gate--v2.0.0"})'
expect_fail_reason "same-id shape change rejected" "plugin pro-gate changed immutable metadata for releaseId 20" validate_against_base

write_mixed_manifest
mutate_manifest '(.plugins[] | select(.name == "sign-it") | .source.path) = "plugins/sign-it-old"'
# The path rule refuses this before the tuple is compared; the tuple's path
# component is exercised only with that rule disabled (mutation proof).
expect_fail_reason "same-id path change rejected" "plugin sign-it git-subdir entry path must be plugins/sign-it" validate_against_base

write_mixed_manifest
mutate_manifest --arg url "$MONOREPO_URL" --arg sha "$PRO_SUBDIR_SHA" '(.plugins[] | select(.name == "pro-gate")) |= (.source = {source: "git-subdir", url: $url, path: "plugins/pro-gate", sha: $sha} | .metadata = {version: "2.1.0", releaseId: 21, releaseTag: "v2.1.0"})'
expect_fail_reason "new-id shape change with a v-tag rejected" "plugin pro-gate metadata.releaseTag does not match metadata.version for a git-subdir entry" validate_against_base

write_mixed_manifest
mutate_manifest --arg url "$MONOREPO_URL" --arg sha "$PRO_SUBDIR_SHA" '(.plugins[] | select(.name == "pro-gate")) |= (.source = {source: "git-subdir", url: $url, path: "plugins/pro-gate-old", sha: $sha} | .metadata = {version: "2.1.0", releaseId: 21, releaseTag: "pro-gate--v2.1.0"})'
expect_fail_reason "new-id shape change with the wrong path rejected" "plugin pro-gate git-subdir entry path must be plugins/pro-gate" validate_against_base

write_mixed_manifest
mutate_manifest --arg sha "$TOKEN_SHA" '(.plugins[] | select(.name == "sign-it")) |= (.source = {source: "url", url: "https://github.com/StartupBros-com/sign-it.git", sha: $sha} | .metadata = {version: "0.5.1", releaseId: 41, releaseTag: "v0.5.1"})'
expect_fail_reason "git-subdir back to url rejected even with a new release id" "plugin sign-it cannot change shape from git-subdir back to url" validate_against_base

# The validator reads no author: the same change fails identically whoever
# opened the PR, bot or human.
bot_twin_label="the same manifest change fails identically for a bot actor"
back_switch_needle="plugin sign-it cannot change shape from git-subdir back to url"
if human_verdict="$( (validate_against_base) 2>&1)"; then
  printf 'not ok - %s: the human run passed\n' "$bot_twin_label" >&2
  exit 1
fi
if bot_verdict="$( (GITHUB_ACTOR='hov-repin-bot[bot]' validate_against_base) 2>&1)"; then
  printf 'not ok - %s: the bot run passed\n' "$bot_twin_label" >&2
  exit 1
fi
if [[ "$human_verdict" == *"$back_switch_needle"* && "$bot_verdict" == *"$back_switch_needle"* && "$human_verdict" == "$bot_verdict" ]]; then
  printf 'ok - %s\n' "$bot_twin_label"
  pass_count=$((pass_count + 1))
else
  printf 'not ok - %s\n' "$bot_twin_label" >&2
  printf '%s\n---\n%s\n' "$human_verdict" "$bot_verdict" >&2
  exit 1
fi

printf '%d passing cases, %d expected failures\n' "$pass_count" "$fail_count"
