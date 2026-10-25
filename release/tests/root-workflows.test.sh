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
for file in "${files[@]}" repin-reconcile.yml; do
  if grep -Eq -- 'RELEASE_PAT|--latest|--generate-notes|raw\.githubusercontent\.com' ".github/workflows/$file"; then die "forbidden workflow text: $file"; fi
  yq -o=json '.' ".github/workflows/$file" | jq -e '[.jobs[] | select(any(.steps[]?; (.uses // "") | startswith("actions/create-github-app-token")))
    | (.environment | if type == "object" then .name else . end)] | all(. == "release")' >/dev/null || die "mint environment $file"
done
pass 'six workflows have no forbidden release shortcuts and mint only in release'
for file in auto-release.yml publish-staged-release.yml repin-reconcile.yml; do
  yq -o=json '.' ".github/workflows/$file" | jq -e '[.jobs[] | select(any(.steps[]?; (.uses // "") | startswith("actions/create-github-app-token")))] | length >= 1' >/dev/null || die "no minting job: $file"
done
pass 'the three token-minting workflows each carry a minting job'
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
if command -v actionlint >/dev/null; then
  workflows=()
  for file in "${files[@]}"; do workflows+=(".github/workflows/$file"); done
  actionlint -config-file .github/actionlint.yaml "${workflows[@]}" || die 'actionlint root workflows'
  pass 'actionlint accepts all five root workflows'
fi

printf '%s root-workflows checks passed\n' "$PASS"
