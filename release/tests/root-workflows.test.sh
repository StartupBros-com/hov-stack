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

cd "$ROOT"
files=(plugins-ci.yml auto-release.yml release.yml publish-staged-release.yml release-train.yml)
for file in "${files[@]}"; do yq -o=json '.' ".github/workflows/$file" >"$TMP/$file.json"; done
jq -e '.name == "ci" and (.on | keys == ["pull_request","push"]) and .on.push.branches == ["main"]
  and (.on.push | has("paths") | not) and (.on.pull_request | . == null)
  and .jobs.changes.name == "changed plugins" and .jobs.ci.name == "ci"
  and .jobs.ci.needs == ["changes","plugin"] and .jobs.ci.if == "always()"
  and .jobs.plugin.strategy["fail-fast"] == false
  and (.jobs.plugin.if | contains("head.repo.fork == false"))' "$TMP/plugins-ci.yml.json" >/dev/null || die 'CI trigger/aggregate contract'
pass 'plugin CI always runs the aggregate with the trusted matrix guard'
jq -e '.on | keys == ["push","workflow_dispatch"]' "$TMP/auto-release.yml.json" >/dev/null || die 'auto events'
jq -e --arg due "steps.decide.outputs.due == 'true'" \
  --arg tagif "steps.decide.outputs.due == 'true' && steps.identity.outputs.have_app == 'true'" \
  --arg failif "steps.decide.outcome == 'failure'" '
  .on.push == {"branches":["main"],"paths":["plugins/*/VERSION"]}
  and (.on.workflow_dispatch == null) and .concurrency == {"group":"auto-release-${{ github.sha }}","cancel-in-progress":false}
  and .jobs.release.permissions.contents == "read"
  and any(.jobs.release.steps[]; .id == "decide" and .["continue-on-error"] == true and .env.PARENT == "${{ github.event.before }}")
  and any(.jobs.release.steps[]; .id == "identity" and .if == $due)
  and any(.jobs.release.steps[]; .id == "mint" and .if == $tagif and .with.owner == "StartupBros-com" and .with["permission-contents"] == "write")
  and any(.jobs.release.steps[]; .id == "tag" and .if == $tagif and .env.RELEASE_TOKEN == "${{ steps.mint.outputs.token }}")
  and (.jobs.release.steps[-1] | .if == $failif and (.run | endswith("auto-release-decide.sh --fail-invalid")))' "$TMP/auto-release.yml.json" >/dev/null || die 'auto trigger/identity contract'
pass 'auto-release triggers only on VERSION paths or no-input dispatch, tags valid bumps before failing on an invalid one'
jq -e --arg ref "\${{ inputs.tag && format('refs/tags/{0}', inputs.tag) || github.ref }}" '
  .on.push.tags == ["*--v*"] and .on.workflow_dispatch.inputs.tag.required == true
  and .on.workflow_dispatch.inputs.tag.type == "string"
  and .jobs.stage.permissions == {"contents":"write","actions":"read"}
  and .jobs.stage.steps[0].with.ref == $ref
  and .jobs.stage.steps[-1].env.RELEASE_TAG == "${{ inputs.tag || github.ref_name }}"
  and .jobs.stage.steps[-1].env.GH_TOKEN == "${{ github.token }}"' "$TMP/release.yml.json" >/dev/null || die 'release tags and permissions'
pass 'staging checks out the tag and stages it with the job token under minimal permissions'
jq -e '.on | keys == ["workflow_dispatch"]' "$TMP/publish-staged-release.yml.json" >/dev/null || die 'publish trigger'
jq -e '.jobs.publish.steps[0].with.ref == "${{ github.event.repository.default_branch }}"
  and .jobs.publish.steps[-1].env.GH_TOKEN == "${{ steps.mint.outputs.token }}"
  and .jobs.publish.steps[-1].env.MARKETPLACE_TOKEN == "${{ github.token }}"' "$TMP/publish-staged-release.yml.json" >/dev/null || die 'publish checkout/token contract'
pass 'publish reads default branch and uses App token for publication'
for file in "${files[@]}" repin-reconcile.yml release-pins-refresh.yml; do
  if grep -Eq -- 'RELEASE_PAT|--latest|--generate-notes|raw\.githubusercontent\.com' ".github/workflows/$file"; then die "forbidden workflow text: $file"; fi
  yq -o=json '.' ".github/workflows/$file" | jq -e '[.jobs[] | select(any(.steps[]?; (.uses // "") | startswith("actions/create-github-app-token")))
    | (.environment | if type == "object" then .name else . end)] | all(. == "release")' >/dev/null || die "mint environment $file"
done
pass 'seven workflows have no forbidden release shortcuts and mint only in release'
for file in auto-release.yml publish-staged-release.yml repin-reconcile.yml release-pins-refresh.yml; do
  yq -o=json '.' ".github/workflows/$file" | jq -e '[.jobs[] | select(any(.steps[]?; (.uses // "") | startswith("actions/create-github-app-token")))] | length >= 1' >/dev/null || die "no minting job: $file"
done
pass 'the four token-minting workflows each carry a minting job'
pins="$(grep -rhoE 'hov-tool-drop-announce\.yml@[0-9a-f]{40}' .github/workflows)"
[ "$pins" = hov-tool-drop-announce.yml@41bb6f811f1c1ad65f62c1ef32e696c60fb1d8c3 ] || die 'announce pin count/value'
jq -e --arg uses "StartupBros-com/hov-stack/.github/workflows/hov-tool-drop-announce.yml@41bb6f811f1c1ad65f62c1ef32e696c60fb1d8c3" \
  --arg announce "github.event.release.draft == false && github.event.release.prerelease == false && needs.verify.result == 'success'" '
  (.jobs.announce | has("with") | not)
  and .jobs.announce.permissions == {"contents":"read","id-token":"write"}
  and .jobs.announce.uses == $uses and .jobs.announce.needs == "verify" and .jobs.announce.if == $announce
  and .jobs.verify.if == "github.event.release.draft == false"
  and .on.release.types == ["published","edited"]' "$TMP/release-train.yml.json" >/dev/null || die 'announce caller contract'
grep -Fq '# U7-U9: prefix-aware announce guard, card-source helper, prefix-scoped releases' .github/workflows/release-train.yml || die 'announce pin comment'
pass 'exactly one canonical announce pin has the required comment and OIDC'
for file in "${files[@]}"; do
  jq -e '.permissions == {"contents":"read"} and all(.jobs[]; (has("uses") or .["runs-on"] == "ubuntu-24.04"))
    and all(.jobs[].steps[]? | select(.uses? | startswith("actions/checkout")?);
      .uses == "actions/checkout@ac593985615ec2ede58e132d2e21d2b1cbd6127c" and .with["persist-credentials"] == false)
    and all(.jobs[].steps[]? | select(.uses? | startswith("actions/create-github-app-token")?);
      .uses == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1")
    and all(.jobs[].steps[]? | select(has("run")); (.run | rtrimstr("\n") | split("\n") | length) <= 2
      and (.run | test("^(bash )?(\\./)?release/scripts/")))' "$TMP/$file.json" >/dev/null || die "scripts/action pins/permissions: $file"
done
pass 'every run is a short script call; runners, pins and checkouts are hardened'
# The pins refresh runs downloaded programs, so only a read-only job with no secret may
# run them, and the job holding the bot's key takes nothing from it but rows that apply
# checks against the default branch it checked out itself.
yq -o=json '.' .github/workflows/release-pins-refresh.yml >"$TMP/release-pins-refresh.yml.json"
jq -e --arg main '${{ github.event.repository.default_branch }}' '
  .permissions == {"contents":"read"} and (.jobs | keys == ["land","refresh"])
  and .jobs.refresh.permissions == {"contents":"read"} and (.jobs.refresh | has("environment") | not)
  and (.jobs.refresh | tostring | contains("secrets.") | not)
  and (.jobs.refresh.outputs | keys == ["rows"])
  and .jobs.land.needs == "refresh" and .jobs.land.environment == "release"
  and all(.jobs[].steps[] | select((.uses // "") | startswith("actions/checkout"));
    .uses == "actions/checkout@ac593985615ec2ede58e132d2e21d2b1cbd6127c"
    and .with.ref == $main and .with["persist-credentials"] == false)
  and ([.jobs[] | .steps[] | select((.uses // "") | startswith("actions/checkout"))] | length == 2)
  and all(.jobs.land.steps[] | select(has("uses"));
    .uses == "actions/checkout@ac593985615ec2ede58e132d2e21d2b1cbd6127c"
    or .uses == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1")
  and all(.jobs.land.steps[]; (.run // "") | test("release-pins\\.sh +(verify|refresh)") | not)
  and any(.jobs.land.steps[]; (.run // "") | test("release-pins\\.sh apply "))
  and any(.jobs.refresh.steps[]; (.run // "") | test("release-pins\\.sh verify"))' \
  "$TMP/release-pins-refresh.yml.json" >/dev/null || die 'pins refresh job split'
pass 'pins refresh: downloaded programs run only in a read-only job with no secret; the land job applies rows to the default branch it checked out'

# The land job's branch key, run as the workflow writes it: the same rows on the same main
# repeat the key (a rerun opens nothing), and rows that differ only in their bytes (a
# publisher replaced a release's assets at the same version) change it, or the old branch
# would fail repin-land.sh's blob proof on every run. The blob output is the new table's.
jq -r '.jobs.land.steps[] | select(.id == "apply") | .run' "$TMP/release-pins-refresh.yml.json" >"$TMP/apply-step.sh"
[ -s "$TMP/apply-step.sh" ] || die 'no apply step in the land job'
SB="$TMP/apply-sandbox"
INSTALLER=plugins/hov-stack/skills/hov-setup/scripts/install-release.sh
mkdir -p "$SB/release/scripts" "$SB/${INSTALLER%/*}"
printf 'table v1\n' >"$SB/$INSTALLER"
# apply as the step uses it: the rows become the table, and PLAN_FILE gets the plan, which
# names versions only, so both row sets below produce the same plan.
cat >"$SB/release/scripts/release-pins.sh" <<'FAKEAPPLY'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = apply ] || exit 2
cp "$2" "$INSTALL_RELEASE"
printf 'gh\t2.1.0\t2.2.0\tlinux-x86_64\n' >"$PLAN_FILE"
FAKEAPPLY
chmod +x "$SB/release/scripts/release-pins.sh"
# The scratch repository must not inherit the caller's: a git hook exports GIT_INDEX_FILE
# (and the exec-bit mutant below sets it), and these commands would then write the scratch
# tree into that index.
GIT_REPO_VARS=(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR)
sbgit() { env "${GIT_REPO_VARS[@]/#/-u}" git -C "$SB" "$@"; }
sbgit init -q
sbgit add -A
sbgit -c user.name=t -c user.email=t@example.invalid commit -qm base
apply_key() { # $1 = rows; prints "<key> <blob>"
  printf '%s\n' "$1" >"$TMP/rows"
  sbgit checkout -q -- "$INSTALLER"
  : >"$TMP/apply-out"
  ( unset "${GIT_REPO_VARS[@]}"
    cd "$SB" && ROWS_B64="$(base64 <"$TMP/rows" | tr -d '\n')" PLAN_FILE="$TMP/plan" \
      INSTALL_RELEASE="$INSTALLER" RUNNER_TEMP="$TMP" GITHUB_OUTPUT="$TMP/apply-out" \
      bash "$TMP/apply-step.sh" ) >/dev/null || die 'the apply step failed in the sandbox'
  grep -qx 'drift=true' "$TMP/apply-out" || die 'the apply step saw no drift'
  printf '%s %s\n' "$(sed -n 's/^key=//p' "$TMP/apply-out")" "$(sed -n 's/^blob=//p' "$TMP/apply-out")"
}
first="$(apply_key 'table v2 sha256 aaaa')"
again="$(apply_key 'table v2 sha256 aaaa')"
replaced="$(apply_key 'table v2 sha256 bbbb')"
[ -n "${first%% *}" ] && [ -n "${first#* }" ] || die "the apply step wrote no key or blob: $first"
[ "$first" = "$again" ] || die "the same rows on the same main gave two keys: $first / $again"
[ "${first%% *}" != "${replaced%% *}" ] || die "rows that differ only in bytes kept the key ${first%% *}"
[ "${replaced#* }" = "$(sbgit hash-object "$INSTALLER")" ] || die 'the blob output is not the new table'
pass 'pins branch key: the same rows on the same main repeat it; replaced bytes at the same version change it'

# A script a workflow runs as ./release/scripts/X needs its exec bit in git, or the step
# fails with "Permission denied" on the first scheduled run.
grep -ohE '(run: |^[[:space:]]+)\./release/scripts/[A-Za-z0-9_.-]+' .github/workflows/*.yml | sed 's#.*\./##' | sort -u >"$TMP/run-scripts"
[ -s "$TMP/run-scripts" ] || die 'no ./release/scripts/ calls found in the workflows'
while IFS= read -r script; do
  [ "$(git ls-files -s -- "$script" | awk '{ print $1 }')" = 100755 ] || die "not executable in git: $script"
done <"$TMP/run-scripts"
pass "every ./release/scripts/ program a workflow runs is executable in git ($(wc -l <"$TMP/run-scripts" | tr -d ' ') scripts)"

if command -v actionlint >/dev/null; then
  workflows=()
  for file in "${files[@]}" release-pins-refresh.yml; do workflows+=(".github/workflows/$file"); done
  actionlint -config-file .github/actionlint.yaml "${workflows[@]}" || die 'actionlint root workflows'
  pass 'actionlint accepts the five root workflows and the pins refresh'
fi

printf '%s root-workflows checks passed\n' "$PASS"
