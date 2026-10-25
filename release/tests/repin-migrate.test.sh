#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
export FIX="$TMP/fix" CALLS="$TMP/calls" MONOREPO_SOURCE_URL=https://github.com/acme/mono.git
mkdir -p "$TMP/bin" "$FIX/acme/mono"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
[ "$1" = api ] || exit 90
shift
path='' filter='' paginate=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --jq) filter="$2"; shift 2 ;;
    -H) shift 2 ;;
    repos/*) path="$1"; shift ;;
    *) exit 91 ;;
  esac
done
emit() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
case "$path" in
  repos/acme/mono/releases\?per_page=100)
    if [ "$paginate" = true ]; then
      for page in "$FIX/acme/mono"/page-*.json; do cat "$page"; done
    else cat "$FIX/acme/mono/page-1.json"; fi ;;
  repos/acme/mono/git/ref/tags/*) printf '{"object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' | emit ;;
  repos/acme/mono/compare/*) jq -n --arg s "$(cat "$FIX/status")" '{status:$s}' | emit ;;
  repos/acme/mono) printf '{"default_branch":"main"}\n' | emit ;;
  'repos/acme/mono/contents/plugins/hov-stack/.claude-plugin/plugin.json?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') cat "$FIX/plugin.json" ;;
  *) exit 92 ;;
esac
STUB
chmod 755 "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

base_manifest() {
  jq -a --indent 2 -n --arg s "$SHA" '{name:"hov",owner:{name:"House of Vibe",url:"https://houseofvibe.ai"},metadata:{description:"Tools",version:"1.0.0"},plugins:[
    {name:"widget",description:"Keep ⚡ this description",source:{source:"url",url:"https://github.com/acme/widget.git",sha:$s},metadata:{version:"1.0.0",releaseId:10,releaseTag:"v1.0.0"},card:{rows:["one","two","three"],run:"Run it"}},
    {name:"gadget",description:"Gadget",source:{source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/gadget",sha:$s},metadata:{version:"1.0.0",releaseId:20,releaseTag:"gadget--v1.0.0"}}
  ]}' > "$TMP/m.json"
  printf 'behind\n' > "$FIX/status"
  printf '{"name":"hov-stack","description":"The skill pack ⚡"}\n' > "$FIX/plugin.json"
}
releases() { # name [version]
  jq -n --arg tag "$1--v${2:-2.0.0}" '[{id:900,tag_name:$tag,draft:true,prerelease:false,created_at:"2026-10-21"}]' > "$FIX/acme/mono/page-1.json"
}
run_migrate() {
  env MANIFEST="$TMP/m.json" PLAN_FILE="$TMP/plan.tsv" "$@" >"$TMP/out" 2>"$TMP/err"
}
migrate() { run_migrate bash "$ROOT/release/scripts/repin-migrate.sh" "$@"; }
refuse() {
  local name="$1" reason="$2"
  cp "$TMP/m.json" "$TMP/before"
  if migrate "$name"; then die "migration accepted $name"; fi
  grep -Fq "$reason" "$TMP/err" || die "missing reason $reason: $(cat "$TMP/err")"
  cmp -s "$TMP/before" "$TMP/m.json" || die 'refusal modified manifest'
  pass "$name refused: $reason; manifest untouched"
}
base_manifest
releases widget
refuse nonesuch 'only hov-stack may be created'
refuse gadget 'already a git-subdir entry'
: > "$CALLS"
refuse bad--name 'invalid plugin name'
[ ! -s "$CALLS" ] || die 'bad name made a read'
cp "$TMP/m.json" "$TMP/before"
if MANIFEST="$TMP/missing" PLAN_FILE="$TMP/plan.tsv" bash "$ROOT/release/scripts/repin-migrate.sh" bad--name >"$TMP/out" 2>"$TMP/err"; then die 'bad name accepted with missing manifest'; fi
grep -Fq 'invalid plugin name' "$TMP/err" || die 'bad name read manifest first'
pass 'bad--name is refused before even reading the manifest'
jq '.plugins += [.plugins[0]]' "$TMP/m.json" > "$TMP/duplicate"
mv "$TMP/duplicate" "$TMP/m.json"
refuse widget 'more than one entry'
base_manifest
printf '[]\n' > "$FIX/acme/mono/page-1.json"
refuse widget 'no non-prerelease release with prefix widget--v in acme/mono; drafts are invisible unless GH_TOKEN is a release App token scoped to acme/mono'
releases widget
printf 'diverged\n' > "$FIX/status"
refuse widget 'is not on main (compare status: diverged)'
base_manifest
original="$(jq -c '.plugins[0] | {name,description,card}' "$TMP/m.json")"
other="$(jq -c '.plugins[1]' "$TMP/m.json")"
migrate widget || die "widget migration failed: $(cat "$TMP/err")"
[ "$(jq -c '.plugins[0] | {name,description,card}' "$TMP/m.json")" = "$original" ] || die 'copy or position changed'
[ "$(jq -c '.plugins[1]' "$TMP/m.json")" = "$other" ] || die 'other entry changed'
[ "$(cat "$TMP/plan.tsv")" = "$(printf 'widget\t2.0.0\twidget--v2.0.0\t900\t%s\ttrue' "$SHA")" ] || die 'migration plan differs'
jq -e --arg s "$SHA" '.plugins[0].source == {source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/widget",sha:$s} and .plugins[0].metadata == {version:"2.0.0",releaseId:900,releaseTag:"widget--v2.0.0"}' "$TMP/m.json" >/dev/null || die 'migration tuple wrong'
[ "$(jq -c '.plugins[0].source | keys_unsorted' "$TMP/m.json")" = '["source","url","path","sha"]' ] || die 'source key order changed'
[ "$(jq -c '.plugins[0].metadata | keys_unsorted' "$TMP/m.json")" = '["version","releaseId","releaseTag"]' ] || die 'metadata key order changed'
grep -Fq '\u26a1' "$TMP/m.json" || die 'ascii escapes lost'
pass 'url widget migrates in place with exact tuple, plan, key order, copy, card, position and escapes'
if MARKETPLACE_MANIFEST="$TMP/m.json" BASE_REF='' "$ROOT/release/scripts/validate-marketplace.sh" syntax >"$TMP/validate" 2>&1; then
  die 'the fictional widget fixture bypassed the validator approval list'
fi
grep -Fq 'plugin widget is not approved for this marketplace' "$TMP/validate" || die 'widget syntax failed for an unrelated reason'
pass 'the unchanged validator explicitly refuses the fictional widget name'

# Sibling and bare prefixes never satisfy a migration, however new they are.
base_manifest
jq -n '[
  {id:901,tag_name:"widgets--v9.0.0",draft:false,prerelease:false,created_at:"2026-10-22"},
  {id:902,tag_name:"gizmo--v9.0.0",draft:false,prerelease:false,created_at:"2026-10-23"},
  {id:903,tag_name:"v9.0.0",draft:false,prerelease:false,created_at:"2026-10-24"}
]' > "$FIX/acme/mono/page-1.json"
refuse widget 'no non-prerelease release with prefix widget--v in acme/mono'
printf '[{"id":900,"tag_name":"widget--v2.0.0","draft":true,"prerelease":false,"created_at":"2026-10-21"}]\n' > "$FIX/acme/mono/page-2.json"
migrate widget || die "widget migration behind foreign prefixes failed: $(cat "$TMP/err")"
[ "$(cat "$TMP/plan.tsv")" = "$(printf 'widget\t2.0.0\twidget--v2.0.0\t900\t%s\ttrue' "$SHA")" ] || die 'a newer sibling or bare prefix won the migration'
jq -e '.plugins[0].metadata == {version:"2.0.0",releaseId:900,releaseTag:"widget--v2.0.0"}' "$TMP/m.json" >/dev/null || die 'foreign-prefix migration tuple wrong'
pass 'newer widgets--v, gizmo--v and v releases on page one lose to the older widget--v draft on page two'
rm -f -- "$FIX/acme/mono/page-2.json"
releases widget

base_manifest
cp "$TMP/m.json" "$TMP/before"
run_migrate DRY_RUN=1 bash "$ROOT/release/scripts/repin-migrate.sh" widget || die 'dry run failed'
cmp -s "$TMP/before" "$TMP/m.json" || die 'dry run changed manifest'
[ "$(cat "$TMP/plan.tsv")" = "$(printf 'widget\t2.0.0\twidget--v2.0.0\t900\t%s\ttrue' "$SHA")" ] || die 'dry plan differs'
grep -Fxq 'dry run: manifest untouched' "$TMP/out" || die 'dry output differs'
pass 'DRY_RUN writes the exact plan and leaves the manifest byte-identical'

# widget/gadget are deliberately fictional. Exercise the unchanged validator
# with an approved url plugin as well, and with the newly appended skill pack.
base_manifest
jq '.plugins = [.plugins[0] | .name = "pro-gate" | .source.url = "https://github.com/StartupBros-com/pro-gate.git"]' "$TMP/m.json" > "$TMP/approved"
mv "$TMP/approved" "$TMP/m.json"
# The PR the workflow opens is validated against main, so the url-to-git-subdir
# transition is checked here with BASE_REF, not syntax alone: the base manifest is
# the committed url entry and the migrated manifest is the working tree.
WORK="$TMP/work"
mkdir -p "$WORK/.claude-plugin"
cp "$TMP/m.json" "$WORK/.claude-plugin/marketplace.json"
git -C "$WORK" init -q -b main
git -C "$WORK" config user.name Fixture
git -C "$WORK" config user.email fixture@example.com
git -C "$WORK" config commit.gpgsign false
git -C "$WORK" config core.hooksPath /dev/null
git -C "$WORK" add .claude-plugin/marketplace.json
git -C "$WORK" commit -qm base
validate_against_base() {
  (cd "$WORK" && BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json "$ROOT/release/scripts/validate-marketplace.sh" syntax) >"$TMP/validate" 2>&1
}
releases pro-gate 1.0.0
env MANIFEST="$WORK/.claude-plugin/marketplace.json" PLAN_FILE="$TMP/plan.tsv" bash "$ROOT/release/scripts/repin-migrate.sh" pro-gate >"$TMP/out" 2>"$TMP/err" || die "equal-version migration failed: $(cat "$TMP/err")"
if validate_against_base; then die 'a migration to an equal version passed the base comparison'; fi
grep -Fq 'version must increase when releaseId advances' "$TMP/validate" || die "equal version failed for another reason: $(cat "$TMP/validate")"
pass 'a migration to an equal version is refused by the validator against the base manifest'
cp "$TMP/m.json" "$WORK/.claude-plugin/marketplace.json"
releases pro-gate
env MANIFEST="$WORK/.claude-plugin/marketplace.json" PLAN_FILE="$TMP/plan.tsv" bash "$ROOT/release/scripts/repin-migrate.sh" pro-gate >"$TMP/out" 2>"$TMP/err" || die "approved plugin migration failed: $(cat "$TMP/err")"
validate_against_base || die "migrated url output fails against the base manifest: $(cat "$TMP/validate")"
pass 'the migrated url output passes the unchanged validator against the base manifest, transition and monotonicity included'
cp "$WORK/.claude-plugin/marketplace.json" "$TMP/m.json"
cp "$TMP/m.json" "$TMP/approved-migrated"
releases hov-stack 0.1.0
migrate hov-stack || die "hov-stack creation failed: $(cat "$TMP/err")"
jq -e '.plugins | length == 2 and .[0].name == "pro-gate" and .[-1].name == "hov-stack" and .[-1].description == "The skill pack ⚡" and (.[-1] | has("card") | not)' "$TMP/m.json" >/dev/null || die 'skill pack not appended correctly'
jq -e --arg s "$SHA" '.plugins[-1].source == {source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/hov-stack",sha:$s} and .plugins[-1].metadata == {version:"0.1.0",releaseId:900,releaseTag:"hov-stack--v0.1.0"}' "$TMP/m.json" >/dev/null || die 'skill pack tuple wrong'
[ "$(cat "$TMP/plan.tsv")" = "$(printf 'hov-stack\t0.1.0\thov-stack--v0.1.0\t900\t%s\ttrue' "$SHA")" ] || die 'skill pack plan differs'
grep -Fq "contents/plugins/hov-stack/.claude-plugin/plugin.json?ref=$SHA" "$CALLS" || die 'plugin description not read at pinned sha'
cp "$TMP/m.json" "$WORK/.claude-plugin/marketplace.json"
validate_against_base || die "created hov-stack output fails against the base manifest: $(cat "$TMP/validate")"
pass 'hov-stack is appended with its exact tuple, plan row and pinned description, and passes the validator against the base manifest'
cp "$TMP/approved-migrated" "$TMP/m.json"
printf '{"name":"hov-stack","description":""}\n' > "$FIX/plugin.json"
refuse hov-stack 'non-empty description'
printf '{"name":"other","description":"valid description"}\n' > "$FIX/plugin.json"
refuse hov-stack 'must name hov-stack'
printf '%s repin migrate checks passed\n' "$PASS"
