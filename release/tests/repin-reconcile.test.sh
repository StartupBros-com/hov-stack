#!/usr/bin/env bash
set -euo pipefail

# Tests for release/scripts/repin-reconcile.sh.
#
# The reconciler's whole value is that it is safe to run repeatedly, so the two
# properties worth proving are: it converges on the released state, and running
# it again from that state does nothing at all — including no formatting churn,
# which would otherwise rewrite every plugin's card and bury the real change.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin"

# Stub gh: serves per-plugin and shared release/tag/repo metadata from fixtures.
# It honours --jq, because the script relies on gh applying that filter; a stub
# that ignored it would hand back raw JSON and test a shape production never sees.
write_gh_stub() { # $1 = compare status to report
  cat > "$TMP/bin/gh" <<STUBGH
#!/usr/bin/env bash
set -e
printf '%s\n' "\$*" >> "\$CALLS"
[ "\$1" = api ] || exit 90
shift
path="" jqexpr="" paginate=false
while [ \$# -gt 0 ]; do
  case "\$1" in
    --paginate) paginate=true; shift ;;
    --jq) jqexpr="\$2"; shift 2 ;;
    repos/*) path="\$1"; shift ;;
    *) exit 91 ;;
  esac
done
emit() { if [ -n "\$jqexpr" ]; then jq -r "\$jqexpr"; else cat; fi; }
repo="\${path#repos/}"; repo="\${repo%/releases*}"
case "\$path" in
  repos/acme/widget/releases*|repos/acme/mono/releases*)
    if [ -f "\$FIX/\$repo/page-1.json" ]; then
      if [ "\$paginate" = true ]; then
        for page in "\$FIX/\$repo"/page-*.json; do cat "\$page"; done
      else cat "\$FIX/\$repo/page-1.json"; fi
    else emit < "\$FIX/releases.json"; fi ;;
  repos/acme/widget/git/ref/tags/*|repos/acme/mono/git/ref/tags/*) emit < "\$FIX/tagref.json" ;;
  repos/acme/widget/compare/*|repos/acme/mono/compare/*) if [ "$1" = FAIL ]; then printf '{"message":"rate limited"}\n' >&2; exit 1; fi; printf '{"status":"$1"}\n' | emit ;;
  repos/acme/widget|repos/acme/mono) printf '{"default_branch":"main"}\n' | emit ;;
  *) printf 'unexpected gh api: %s\n' "\$path" >&2; exit 1 ;;
esac
STUBGH
  chmod +x "$TMP/bin/gh"
}
write_gh_stub identical

export FIX="$TMP/fix" CALLS="$TMP/calls"
export MONOREPO_SOURCE_URL=https://github.com/acme/mono.git
mkdir -p "$FIX"

NEW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

printf '[{"id":900,"tag_name":"v2.0.0","draft":false,"prerelease":false,"created_at":"2026-08-20T00:00:00Z"},{"id":800,"tag_name":"v1.0.0","draft":false,"prerelease":false,"created_at":"2026-08-01T00:00:00Z"}]\n' > "$FIX/releases.json"
printf '{"object":{"sha":"%s","type":"commit"}}\n' "$NEW_SHA" > "$FIX/tagref.json"

make_manifest() { # $1 = version, $2 = tag, $3 = id, $4 = sha, $5 = dest
  jq -a --indent 2 -n \
    --arg v "$1" --arg t "$2" --argjson i "$3" --arg s "$4" '
    {plugins: [{
      name: "widget",
      source: {source: "url", url: "https://github.com/acme/widget.git", sha: $s},
      description: "unicode check — an em dash and ⚡ a bolt",
      metadata: {version: $v, releaseId: $i, releaseTag: $t},
      card: {rows: ["⚡ one", "🛡️ two"], run: "go"}
    }]}' > "$5"
}

run_reconcile() { # $1 = manifest path
  : > "$CALLS"
  PATH="$TMP/bin:$PATH" FIX="$FIX" MANIFEST="$1" PLAN_FILE="$TMP/plan.tsv" \
    bash "$ROOT/release/scripts/repin-reconcile.sh" 2>"$TMP/err"
}

# --- converges on the released state -----------------------------------------
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/stale.json"
run_reconcile "$TMP/stale.json" >"$TMP/out" || die 'reconciler failed on a stale manifest'
grep -q 'repinned 1' "$TMP/out" || die 'stale manifest was not reported as repinned'
pass 'a stale card is repinned to the newest release'

got="$(jq -r '.plugins[0] | "\(.metadata.version) \(.metadata.releaseTag) \(.metadata.releaseId) \(.source.sha)"' "$TMP/stale.json")"
[ "$got" = "2.0.0 v2.0.0 900 $NEW_SHA" ] || die "repinned tuple is wrong: $got"
pass 'the repinned tuple matches the newest release exactly'

# --- idempotent: a second run changes nothing --------------------------------
cp "$TMP/stale.json" "$TMP/after-first.json"
run_reconcile "$TMP/stale.json" >"$TMP/out2" || die 'second run failed'
grep -q 'already matches' "$TMP/out2" || die 'second run did not report convergence'
pass 'a second run reports the manifest already matches'

diff -q "$TMP/after-first.json" "$TMP/stale.json" >/dev/null \
  || die 'second run modified an already-current manifest'
pass 'a second run leaves the manifest byte-identical'

# --- no formatting churn ------------------------------------------------------
# The card carries \uXXXX escapes. A jq round-trip that drops -a would rewrite
# every one of them, producing a diff across cards nobody touched.
grep -q '\\u26a1' "$TMP/stale.json" || die 'unicode escapes were rewritten by the reconciler'
pass 'unicode escaping in untouched cards is preserved'

# --- a current manifest is left completely alone ------------------------------
make_manifest '2.0.0' 'v2.0.0' 900 "$NEW_SHA" "$TMP/current.json"
cp "$TMP/current.json" "$TMP/current.orig.json"
run_reconcile "$TMP/current.json" >"$TMP/out3" || die 'reconciler failed on a current manifest'
diff -q "$TMP/current.orig.json" "$TMP/current.json" >/dev/null \
  || die 'a current manifest was modified'
[ ! -f "$TMP/plan.tsv" ] || die 'a plan file was left behind with no drift'
pass 'a current manifest is untouched and leaves no plan file'

# --- dry run never writes -----------------------------------------------------
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/dry.json"
cp "$TMP/dry.json" "$TMP/dry.orig.json"
PATH="$TMP/bin:$PATH" FIX="$FIX" MANIFEST="$TMP/dry.json" PLAN_FILE="$TMP/plan.tsv" DRY_RUN=1 \
  bash "$ROOT/release/scripts/repin-reconcile.sh" >"$TMP/out4" 2>&1 || die 'dry run failed'
diff -q "$TMP/dry.orig.json" "$TMP/dry.json" >/dev/null || die 'dry run modified the manifest'
grep -q 'dry run' "$TMP/out4" || die 'dry run did not say so'
pass 'DRY_RUN reports drift without writing'

# --- a tag off the default branch is never pinned -----------------------------
write_gh_stub diverged
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/side.json"
cp "$TMP/side.json" "$TMP/side.orig.json"
run_reconcile "$TMP/side.json" >"$TMP/out5" || die 'reconciler failed on a diverged tag'
diff -q "$TMP/side.orig.json" "$TMP/side.json" >/dev/null \
  || die 'a tag off the default branch was pinned into the manifest'
pass 'a tag that is not on the default branch is never pinned'

# --- a compare read failure is a failure, not a skip -------------------------
write_gh_stub FAIL
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/readfail.json"
cp "$TMP/readfail.json" "$TMP/readfail.orig.json"
if run_reconcile "$TMP/readfail.json" >"$TMP/out6"; then
  die 'a failed compare read was treated as success'
fi
grep -q 'could not compare' "$TMP/err" || die 'compare read failure was not named'
diff -q "$TMP/readfail.orig.json" "$TMP/readfail.json" >/dev/null \
  || die 'a failed compare read modified the manifest'
pass 'a compare read failure exits nonzero and leaves the manifest untouched'

write_gh_stub identical
mkdir -p "$FIX/acme/mono"
jq -n '[
  {id:1000,tag_name:"gadget--v1.2.3",draft:true,prerelease:false,created_at:"2026-08-21"},
  {id:1001,tag_name:"gadgets--v9.0.0",draft:false,prerelease:false,created_at:"2026-08-22"},
  {id:1002,tag_name:"gizmo--v9.0.0",draft:false,prerelease:false,created_at:"2026-08-23"},
  {id:1003,tag_name:"v9.0.0",draft:false,prerelease:false,created_at:"2026-08-24"}
]' > "$FIX/acme/mono/page-1.json"
mixed_manifest() {
  make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/url.json"
  jq --arg s "$OLD_SHA" '.plugins += [{name:"gadget",source:{source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/gadget",sha:$s},description:"Gadget",metadata:{version:"0.1.0",releaseId:700,releaseTag:"gadget--v0.1.0"}}]' "$TMP/url.json" > "$TMP/mixed.json"
}
mixed_manifest
run_reconcile "$TMP/mixed.json" >"$TMP/out" || die 'mixed reconcile failed'
expected="$(printf 'widget\t2.0.0\tv2.0.0\t900\t%s\tfalse\ngadget\t1.2.3\tgadget--v1.2.3\t1000\t%s\ttrue' "$NEW_SHA" "$NEW_SHA")"
[ "$(cat "$TMP/plan.tsv")" = "$expected" ] || die 'mixed plan rows differ'
jq -e '.plugins[1].metadata.version == "1.2.3" and .plugins[1].source.source == "git-subdir" and .plugins[0].source.source == "url"' "$TMP/mixed.json" >/dev/null || die 'mixed tuple or shape wrong'
pass 'mixed url and git-subdir cards repin with exact plan rows and unprefixed versions'
jq -e '.plugins[1].metadata.releaseTag == "gadget--v1.2.3" and .plugins[1].metadata.releaseId == 1000' "$TMP/mixed.json" >/dev/null || die 'a sibling or bare prefix won'
pass 'gadget--v ignores newer gadgets--v, gizmo--v and v releases'
cp "$TMP/mixed.json" "$TMP/mixed.orig"
run_reconcile "$TMP/mixed.json" >"$TMP/out" || die 'mixed rerun failed'
grep -q 'manifest already matches every newest release' "$TMP/out" || die 'mixed convergence not reported'
cmp -s "$TMP/mixed.orig" "$TMP/mixed.json" || die 'mixed rerun changed bytes'
pass 'a mixed second run reports convergence and leaves the manifest byte-identical'
printf '[{"id":1100,"tag_name":"gadget--v2.0.0","draft":true,"prerelease":false,"created_at":"2026-08-25"}]\n' > "$FIX/acme/mono/page-2.json"
run_reconcile "$TMP/mixed.json" >"$TMP/out" || die 'page-two reconcile failed'
jq -e '.plugins[1].metadata.releaseTag == "gadget--v2.0.0"' "$TMP/mixed.json" >/dev/null || die 'page-two winner lost'
[ "$(grep -c 'repos/acme/mono/releases?per_page=100' "$CALLS")" -eq 1 ] || die 'more than one mono list call'
grep -Fxq 'api --paginate repos/acme/mono/releases?per_page=100' "$CALLS" || die 'list not paginated'
pass 'a page-two gadget release is pinned with exactly one paginated list call'
mixed_manifest
before="$(jq -c '.plugins[0]' "$TMP/mixed.json")"
ONLY_PLUGIN=gadget run_reconcile "$TMP/mixed.json" >"$TMP/out" || die 'targeted reconcile failed'
[ "$(jq -c '.plugins[0]' "$TMP/mixed.json")" = "$before" ] || die 'targeted reconcile touched widget'
jq -e '.plugins[1].metadata.version == "2.0.0"' "$TMP/mixed.json" >/dev/null || die 'targeted reconcile missed gadget'
pass 'ONLY_PLUGIN=gadget touches only the gadget card'

# Literal shell/Actions expressions are the workflow contract.
# shellcheck disable=SC2016
workflow_contract() {
  local workflow="$ROOT/.github/workflows/repin-reconcile.yml" run identity
  [ "$(yq -r '.jobs.reconcile.steps[] | select(.id == "app") | .with.repositories' "$workflow")" = '${{ vars.HOV_RELEASE_APP_REPOSITORIES }}' ] || die 'App repositories not configured by variable'
  [ "$(yq -r '.jobs.reconcile.steps[] | select(.id == "identity") | .env.APP_REPOSITORIES' "$workflow")" = '${{ vars.HOV_RELEASE_APP_REPOSITORIES }}' ] || die 'identity step does not read the repository variable'
  [ "$(yq -r '.jobs.reconcile.steps[] | select(.id == "reconcile") | .env.MIGRATE_PLUGIN' "$workflow")" = '${{ inputs.migrate_plugin }}' ] || die 'reconcile step does not bind migrate_plugin'
  [ "$(yq -r '.jobs.reconcile.steps[] | select(.name == "Open the repin PR") | .env.MIGRATE_PLUGIN' "$workflow")" = '${{ inputs.migrate_plugin }}' ] || die 'open-PR step does not bind migrate_plugin'
  if grep -Fq 'harness-vet,token-eater' "$workflow"; then die 'literal repositories remain'; fi
  [ "$(yq -r '.on.workflow_dispatch.inputs.migrate_plugin.required' "$workflow")" = false ] || die 'optional migrate_plugin missing'
  run="$(yq -r '.jobs.reconcile.steps[] | select(.id == "reconcile") | .run' "$workflow")"
  grep -Fq 'repin-migrate.sh "$MIGRATE_PLUGIN"' <<<"$run" || die 'migration dispatch missing'
  grep -Fxq '  key="$( { cat "$PLAN_FILE"; git rev-parse HEAD; } | sha256sum | cut -c1-12)"' <<<"$run" || die 'branch key changed'
  [ "$(yq -r '.jobs.reconcile.steps[] | select(.run == "./release/scripts/repin-land.sh") | .env.ONLY_PLUGIN' "$workflow")" = '${{ inputs.migrate_plugin || inputs.only_plugin }}' ] || die 'land targeting missing'
  [ "$(yq -r '.jobs.reconcile.steps[] | select(.name == "Publish staged releases the card on main already pins") | .env.ONLY_PLUGIN' "$workflow")" = '${{ inputs.migrate_plugin || inputs.only_plugin }}' ] || die 'publish targeting missing'
  pass 'workflow uses repository configuration, migration dispatch, exact key and targeted land/publish'
  # The wake-ups (hov-stack#438). workflow_run names its upstream by display name, so a
  # renamed release.yml would silently stop the staged-draft wake-up; a branches filter
  # would be matched against Release's tag and never fire; a job-level if would let a
  # skipped run cancel a pending one through the workflow-level concurrency group.
  [ "$(yq -o=json -I=0 '.on.workflow_run' "$workflow")" = '{"workflows":["Release"],"types":["completed"]}' ] || die 'staged-draft wake-up missing or filtered'
  [ "$(yq -r '.name' "$ROOT/.github/workflows/release.yml")" = Release ] || die 'release.yml is no longer named Release'
  [ "$(yq -o=json -I=0 '.on.push' "$workflow")" = '{"branches":["main"]}' ] || die 'push wake-up narrowed'
  [ "$(yq -r '.on.schedule[0].cron' "$workflow")" = '8,23,38,53 * * * *' ] || die 'schedule fallback missing'
  [ "$(yq -r '.jobs.reconcile.if' "$workflow")" = null ] || die 'reconcile job gained a condition'
  pass 'workflow wakes on a finished Release run, every push to main, and the schedule'
  identity="$(yq -r '.jobs.reconcile.steps[] | select(.id == "identity") | .run' "$workflow")"
  : > "$TMP/github-output"
  if HOV_RELEASE_APP_ID=123 HOV_RELEASE_APP_PRIVATE_KEY=key APP_REPOSITORIES='' GITHUB_OUTPUT="$TMP/github-output" bash -c "$identity" >"$TMP/probe" 2>&1; then die 'empty App repository variable accepted'; fi
  grep -Fq '::error::repository variable HOV_RELEASE_APP_REPOSITORIES is empty;' "$TMP/probe" || die 'empty repository error missing'
  if grep -q 'have_app=true' "$TMP/github-output"; then die 'empty list enabled App'; fi
  pass 'identity probe refuses secrets with an empty repository variable'
  : > "$TMP/github-output"
  HOV_RELEASE_APP_ID=123 HOV_RELEASE_APP_PRIVATE_KEY=key APP_REPOSITORIES=mono GITHUB_OUTPUT="$TMP/github-output" bash -c "$identity" >"$TMP/probe" 2>&1 || die 'configured identity failed'
  grep -Fxq 'have_app=true' "$TMP/github-output" || die 'configured App not enabled'
  pass 'identity probe enables the App with secrets and a non-empty repository variable'
  : > "$TMP/github-output"
  HOV_RELEASE_APP_ID='' HOV_RELEASE_APP_PRIVATE_KEY='' APP_REPOSITORIES='' GITHUB_OUTPUT="$TMP/github-output" bash -c "$identity" >"$TMP/probe" 2>&1 || die 'missing secrets should warn'
  grep -Fxq 'have_app=false' "$TMP/github-output" || die 'missing secrets enabled App'
  grep -Fxq '::warning::release App secrets are not visible to this repository; reads use GITHUB_TOKEN and cannot see staged DRAFT releases, so draft-first repins will not be opened automatically.' "$TMP/probe" || die 'missing secrets warning changed'
  pass 'identity probe with no secrets preserves the warning and disables the App'
}
workflow_contract
printf '%s repin reconcile checks passed\n' "$PASS"
