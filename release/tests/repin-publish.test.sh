#!/usr/bin/env bash
set -euo pipefail

# Tests for release/scripts/repin-publish.sh.
#
# The publish is the one step here that writes outside this repository, and it
# fires an announcement, so the properties worth proving are: it publishes the
# pinned draft exactly once when card and release agree; it never publishes when
# they disagree or a read fails; it waits while assets are still uploading; and
# one plugin's failure does not stop another plugin's publish.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin"
export FIX="$TMP/fix" CALLS="$TMP/calls"

# Stub gh api: serves each fake repository acme/<name> from $FIX/<name>/ and
# records every PATCH in $CALLS. It honours --jq, because the script relies on gh
# applying that filter; a stub that ignored it would test a shape production never sees.
# The live marketplace manifest (acme/market) is $FIX/live.json, raw as the
# Accept: raw read returns it; a file holding FAIL makes that read fail. Each live
# read records the token it used in $FIX/live-tokens.
cat > "$TMP/bin/gh" <<'STUBGH'
#!/usr/bin/env bash
set -e
[ "$1" = api ] || { printf 'unexpected gh command: %s\n' "$*" >&2; exit 1; }
shift
method=GET path='' jqexpr='' paginate=false fields=''
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    --paginate) paginate=true; shift ;;
    -F|-f) fields="$fields $2"; shift 2 ;;
    -H) shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
case "$path" in
  'repos/acme/market/contents/.claude-plugin/marketplace.json?ref=main')
    printf '%s\n' "${GH_TOKEN:-}" >> "$FIX/live-tokens"
    if [ "$(cat "$FIX/live.json")" = FAIL ]; then printf '{"message":"Server Error"}\n' >&2; exit 1; fi
    emit < "$FIX/live.json"; exit 0 ;;
esac
repo="${path#repos/acme/}"; name="${repo%%/*}"; rest="${repo#"$name"}"
dir="$FIX/$name"
[ -d "$dir" ] || { printf '{"message":"Not Found"}\n' >&2; exit 1; }
case "$method $rest" in
  'PATCH /releases/'*) printf 'PATCH %s%s\n' "$path" "$fields" >> "$CALLS"; printf '{"draft":false}\n' | emit ;;
  'GET /releases/'*)
    [ -s "$dir/release.json" ] || { printf '{"message":"Not Found"}\n' >&2; exit 1; }
    emit < "$dir/release.json" ;;
  'GET /releases?per_page=100')
    if [ -f "$dir/page-1.json" ]; then
      if [ "$paginate" = true ]; then
        for page in "$dir"/page-*.json; do cat "$page"; done
      else cat "$dir/page-1.json"; fi
    else emit < "$dir/releases.json"; fi ;;
  'GET /git/ref/tags/'*) emit < "$dir/tagref.json" ;;
  'GET /compare/'*)
    status="$(cat "$dir/compare")"
    if [ "$status" = FAIL ]; then printf '{"message":"rate limited"}\n' >&2; exit 1; fi
    printf '{"status":"%s"}\n' "$status" | emit ;;
  'GET ') printf '{"default_branch":"main"}\n' | emit ;;
  *) printf 'unexpected gh api: %s %s\n' "$method" "$path" >&2; exit 1 ;;
esac
STUBGH
chmod +x "$TMP/bin/gh"

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
UP='{"name":"a.tar.gz","state":"uploaded"}'

# fixture <name> <draft> <assets json array> [compare status] [tag commit]
# The release is id 900 tagged v2.0.0; the newest published release before it carried
# two uploaded assets, as pro-gate's runtime tarball and checksum do.
fixture() {
  local d="$FIX/$1"
  mkdir -p "$d"
  jq -n --argjson draft "$2" --argjson assets "$3" \
    '{id: 900, tag_name: "v2.0.0", draft: $draft, prerelease: false, assets: $assets}' > "$d/release.json"
  jq -n --argjson assets "[$UP,$UP]" \
    '[{id: 800, tag_name: "v1.0.0", draft: false, prerelease: false,
       published_at: "2026-08-01T00:00:00Z", assets: $assets}]' > "$d/releases.json"
  printf '%s\n' "${4:-behind}" > "$d/compare"
  printf '{"object":{"sha":"%s","type":"commit"}}\n' "${5:-$SHA}" > "$d/tagref.json"
}

# manifest <dest> <name>... : one card per name, each pinning v2.0.0 / 900 / $SHA.
manifest() {
  local dest="$1"; shift
  printf '%s\n' "$@" | jq -R . | jq -s --arg s "$SHA" '{plugins: map({
      name: .,
      source: {source: "url", url: "https://github.com/acme/\(.).git", sha: $s},
      metadata: {version: "2.0.0", releaseId: 900, releaseTag: "v2.0.0"}})}' > "$dest"
}

# Live main matches this run's snapshot unless a case wrote its own live.json first.
run_publish() { # extra env as arguments
  : > "$CALLS"
  [ -e "$FIX/live.json" ] || cp "$TMP/m.json" "$FIX/live.json"
  env PATH="$TMP/bin:$PATH" MANIFEST="$TMP/m.json" MARKETPLACE_REPO=acme/market "$@" \
    bash "$ROOT/release/scripts/repin-publish.sh" >"$TMP/out" 2>"$TMP/err"
}

reset() { rm -rf "$FIX"; mkdir -p "$FIX"; }

# --- an already-published release is left alone ------------------------------
reset; fixture widget false "[$UP,$UP]"; manifest "$TMP/m.json" widget
run_publish || die 'a published release made the run fail'
[ ! -s "$CALLS" ] || die 'an already-published release was patched'
grep -q '^already published widget: v2.0.0' "$TMP/out" || die 'the published release was not reported'
# A bare "published" line reads like a publish; on every push to main that made
# a docs-only merge look like a release of every listed plugin.
! grep -q '^published' "$TMP/out" || die 'an already-published release was reported as a publish'
pass 'an already-published release is reported as already published and never patched'

# --- a pinned, complete draft is published exactly once -----------------------
reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
run_publish GH_TOKEN=app-token MARKETPLACE_TOKEN=job-token || die 'publishing a matching draft failed'
[ "$(cat "$CALLS")" = 'PATCH repos/acme/widget/releases/900 draft=false' ] \
  || die "expected exactly one PATCH of release 900, got: $(cat "$CALLS")"
grep -q '^published now widget: v2.0.0' "$TMP/out" || die 'the publish was not reported'
pass 'a pinned draft whose card matches is published exactly once'
[ "$(cat "$FIX/live-tokens")" = job-token ] \
  || die "live main was not read with MARKETPLACE_TOKEN: $(cat "$FIX/live-tokens")"
pass 'live main is read with MARKETPLACE_TOKEN, not the plugin-repositories token'

# --- dry run never writes ----------------------------------------------------
run_publish DRY_RUN=1 || die 'dry run failed'
[ ! -s "$CALLS" ] || die 'dry run patched a release'
grep -q 'would publish widget' "$TMP/out" || die 'dry run did not say what it would publish'
pass 'DRY_RUN reports the publish without making it'

# --- assets still uploading: wait, do not fail --------------------------------
reset; fixture widget true "[$UP]"; manifest "$TMP/m.json" widget
run_publish || die 'a draft mid-upload made the run fail'
[ ! -s "$CALLS" ] || die 'a draft with fewer assets than the last release was published'
grep -q 'assets are incomplete' "$TMP/out" || die 'the incomplete upload was not reported'
pass 'a draft with fewer assets than the last release waits'

reset; fixture widget true "[$UP,$UP,{\"name\":\"b\",\"state\":\"starter\"}]"; manifest "$TMP/m.json" widget
run_publish || die 'a draft with an unfinished asset made the run fail'
[ ! -s "$CALLS" ] || die 'a draft with an unfinished asset was published'
pass 'a draft with an asset not yet uploaded waits'

# --- disagreements and read failures never publish, and exit nonzero ----------
reset; fixture widget true "[$UP,$UP]" behind "$OTHER_SHA"; manifest "$TMP/m.json" widget
if run_publish; then die 'a tag on a different commit than the card was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a draft whose tag commit differs from the card was published'
grep -q 'but the card pins' "$TMP/err" || die 'the commit disagreement was not named'
pass 'a tag commit that differs from the card pin is refused'

reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
jq '.plugins[0].metadata.releaseTag = "v2.0.1"' "$TMP/m.json" > "$TMP/m2.json" && mv "$TMP/m2.json" "$TMP/m.json"
if run_publish; then die 'a tag disagreement was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a draft tagged differently from the card was published'
grep -q "but the card says 'v2.0.1'" "$TMP/err" || die 'the tag disagreement was not named'
pass 'a release tagged differently from the card is refused'

reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
jq '.plugins[0].metadata.version = "2.0.1"' "$TMP/m.json" > "$TMP/m2.json" && mv "$TMP/m2.json" "$TMP/m.json"
if run_publish; then die 'a version disagreement was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a draft whose version differs from the card was published'
pass 'a card version that does not match the release tag is refused'

reset; fixture widget true "[$UP,$UP]" diverged; manifest "$TMP/m.json" widget
if run_publish; then die 'a tag off the default branch was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a draft off the default branch was published'
pass 'a draft whose commit is not on the default branch is refused'

reset; fixture widget true "[$UP,$UP]" FAIL; manifest "$TMP/m.json" widget
if run_publish; then die 'a failed compare read was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a draft was published over a failed compare read'
grep -q 'could not compare' "$TMP/err" || die 'the compare read failure was not named'
pass 'a compare read failure exits nonzero without publishing'

reset; fixture widget true "[$UP,$UP]"; rm "$FIX/widget/release.json"; manifest "$TMP/m.json" widget
if run_publish; then die 'an unreadable release was treated as success'; fi
grep -q 'could not read release 900' "$TMP/err" || die 'the release read failure was not named'
pass 'an unreadable pinned release exits nonzero'

# --- live main moved on since the snapshot: never publish the old pin ---------
# A newer repin (or a revert holding the release back) merged after this run read main.
reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
jq '.plugins[0].metadata.releaseId = 901' "$TMP/m.json" > "$FIX/live.json"
run_publish || die 'a live pin that moved on made the run fail'
[ ! -s "$CALLS" ] || die 'a draft live main no longer pins was published'
grep -q '^skip widget: main no longer pins v2.0.0' "$TMP/out" || die 'the moved pin was not reported'
pass 'a draft that live main no longer pins is not published'

reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
jq '.plugins = []' "$TMP/m.json" > "$FIX/live.json"
run_publish || die 'a card missing from live main made the run fail'
[ ! -s "$CALLS" ] || die 'a draft whose card is gone from live main was published'
pass 'a draft whose card is gone from live main is not published'

reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
printf 'FAIL\n' > "$FIX/live.json"
if run_publish; then die 'a failed live-main read was treated as success'; fi
[ ! -s "$CALLS" ] || die 'a draft was published over a failed live-main read'
grep -q 'could not read the live manifest' "$TMP/err" || die 'the live read failure was not named'
pass 'a live-main read failure exits nonzero without publishing'

# --- one plugin's failure does not block another's publish --------------------
reset
fixture widget true "[$UP,$UP]" FAIL
fixture gadget true '[]'
jq '.[0].assets = []' "$FIX/gadget/releases.json" > "$FIX/gadget/r.json" && mv "$FIX/gadget/r.json" "$FIX/gadget/releases.json"
manifest "$TMP/m.json" widget gadget
if run_publish; then die 'a run with one failing plugin exited zero'; fi
[ "$(cat "$CALLS")" = 'PATCH repos/acme/gadget/releases/900 draft=false' ] \
  || die "the healthy plugin was not published past the failing one: $(cat "$CALLS")"
pass 'a failing plugin still lets the next plugin publish, and the run exits nonzero'

# Every PATCH argument is recorded. A plugin's own repository keeps GitHub's default
# (no latest argument at all); the shared repository is told make_latest=false, because
# GitHub's default would hand the repository-wide badge to whichever plugin published last.
reset; fixture widget true "[$UP,$UP]"; manifest "$TMP/m.json" widget
run_publish || die 'url publish failed'
[ "$(cat "$CALLS")" = 'PATCH repos/acme/widget/releases/900 draft=false' ] || die "url PATCH fields differ: $(cat "$CALLS")"
pass 'a url publish sends draft=false and no make_latest argument'

mono_fixture() { # <version> <assets> [card version]
  reset
  fixture mono true "$2"
  jq --arg tag "gadget--v$1" '.tag_name = $tag' "$FIX/mono/release.json" > "$TMP/rel.json"
  mv "$TMP/rel.json" "$FIX/mono/release.json"
  jq -n --arg s "$SHA" --arg tag "gadget--v$1" --arg v "${3:-$1}" '{plugins:[{
    name:"gadget",source:{source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/gadget",sha:$s},
    metadata:{version:$v,releaseTag:$tag,releaseId:900}}]}' > "$TMP/m.json"
  printf '[]\n' > "$FIX/mono/releases.json"
}
mono_fixture 1.2.3 '[]'
run_publish || die 'git-subdir publish failed'
[ "$(cat "$CALLS")" = 'PATCH repos/acme/mono/releases/900 draft=false make_latest=false' ] || die "git-subdir PATCH fields differ: $(cat "$CALLS")"
if grep -q 'make_latest=true' "$CALLS"; then die 'git-subdir publish claimed latest'; fi
pass 'a git-subdir publish sends draft=false and make_latest=false, never make_latest=true'

for bad_version in gadget--1.2.3 v1.2.3; do
  mono_fixture 1.2.3 '[]' "$bad_version"
  if run_publish; then die "accepted prefixed card version $bad_version"; fi
  [ ! -s "$CALLS" ] || die 'invalid version published'
  grep -Fq 'prefix gadget--v' "$TMP/err" || die 'version refusal omitted prefix'
  pass "git-subdir version $bad_version is refused with its prefix and no PATCH"
done

# The prefix guard itself, not only the version comparison behind it: a git-subdir card
# whose version and tag agree but carry no prefix is refused by name, before any PATCH.
mono_fixture 1.2.3 '[]'
jq '.tag_name = "v1.2.3"' "$FIX/mono/release.json" > "$TMP/rel.json"
mv "$TMP/rel.json" "$FIX/mono/release.json"
jq '.plugins[0].metadata.releaseTag = "v1.2.3"' "$TMP/m.json" > "$TMP/m2.json"
mv "$TMP/m2.json" "$TMP/m.json"
if run_publish; then die 'accepted an unprefixed tag on a git-subdir card'; fi
[ ! -s "$CALLS" ] || die 'unprefixed tag published'
grep -Fq 'tag v1.2.3 does not start with prefix gadget--v' "$TMP/err" || die 'prefix guard not reached'
pass 'a git-subdir release tagged v1.2.3 is refused by the prefix guard before the version check'

mono_fixture 1.0.0 '[]'
jq -n --argjson assets "[$UP,$UP]" '[{id:800,tag_name:"widget--v3.0.0",draft:false,prerelease:false,published_at:"2026-08-01",assets:$assets}]' > "$FIX/mono/releases.json"
run_publish || die 'other family raised asset floor'
grep -Fxq 'PATCH repos/acme/mono/releases/900 draft=false make_latest=false' "$CALLS" || die 'zero-floor release not published'
pass 'other plugins published assets do not raise the gadget floor above zero'

mono_fixture 2.0.0 "[$UP]"
jq -n --argjson assets "[$UP,$UP]" '[{id:800,tag_name:"gadget--v1.0.0",draft:false,prerelease:false,published_at:"2026-08-01",assets:$assets}]' > "$FIX/mono/releases.json"
run_publish || die 'incomplete same-family assets should wait'
[ ! -s "$CALLS" ] || die 'same-family floor was ignored'
grep -q 'previous release had 2' "$TMP/out" || die 'wrong same-family asset floor'
pass 'a gadget draft with one asset waits for the two-asset gadget floor'
mv "$FIX/mono/releases.json" "$FIX/mono/page-2.json"
printf '[]\n' > "$FIX/mono/page-1.json"
run_publish || die 'page-two asset floor failed'
[ ! -s "$CALLS" ] || die 'page-two asset floor ignored'
grep -q 'previous release had 2' "$TMP/out" || die 'wrong page-two asset floor'
pass 'the published floor release is honoured when it appears only on page two'

mono_fixture 2.0.0 '[]'
rm "$FIX/mono/releases.json"
if run_publish; then die 'an unreadable asset floor was treated as zero'; fi
[ ! -s "$CALLS" ] || die 'published over an unreadable asset floor'
grep -q 'could not read the published releases of acme/mono' "$TMP/err" || die 'asset floor read failure not named'
pass 'an asset floor read failure fails the plugin without publishing'

printf '%s repin publish checks passed\n' "$PASS"
