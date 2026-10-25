#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
# shellcheck source=release/scripts/card-source.sh
. "$ROOT/release/scripts/card-source.sh"
export FIX="$TMP/fix" CALLS="$TMP/calls"
mkdir -p "$TMP/bin" "$FIX/acme/mono" "$TMP/temps"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
[ "$1" = api ] || exit 90
shift
paginate=false path='' filter=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --jq) filter="$2"; shift 2 ;;
    repos/*) path="$1"; shift ;;
    *) exit 91 ;;
  esac
done
emit() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
case "$path" in
  repos/*/releases\?per_page=100)
    repo="${path#repos/}"; repo="${repo%/releases*}"
    if [ "$paginate" = false ]; then cat "$FIX/$repo/page-1.json"; exit 0; fi
    n=0
    for page in "$FIX/$repo"/page-*.json; do
      n=$((n + 1))
      [ "$n" != "${FAKE_GH_FAIL_AT_PAGE:-}" ] || exit 1
      cat "$page"
    done ;;
  repos/acme/mono/git/ref/tags/*) printf '{"object":{"type":"tag","sha":"tag-object"}}\n' | emit ;;
  repos/acme/mono/git/tags/tag-object) printf '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' | emit ;;
  *) exit 92 ;;
esac
STUB
chmod 755 "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

: > "$CALLS"
flags_before="$-"
traps_before="$(trap -p)"
# shellcheck source=release/scripts/card-source.sh
. "$ROOT/release/scripts/card-source.sh" > "$TMP/source-out"
[ "$-" = "$flags_before" ] && [ "$(trap -p)" = "$traps_before" ] || die 'sourcing changed flags or traps'
[ ! -s "$TMP/source-out" ] && [ ! -s "$CALLS" ] || die 'sourcing executed work'
pass 'sourcing under set -euo pipefail is silent and preserves shell flags and traps'

for url in https://github.com/acme/widget.git https://github.com/acme/gadget.git https://github.com/acme/mono.git \
  https://github.com/StartupBros-com/pro-gate.git https://github.com/StartupBros-com/hov-stack.git https://github.com/acme/mono; do
  expected="${url#https://github.com/}"; expected="${expected%.git}"
  [ "$(repo_from_url "$url")" = "$expected" ] || die "URL resolution: $url"
  pass "repo_from_url accepts $url"
done
for url in https://github.com/acme/mono/tree https://elsewhere.com/acme/mono.git git@github.com:acme/mono.git; do
  if repo_from_url "$url"; then die "accepted $url"; fi
  pass "repo_from_url refuses $url"
done
fields="$(card_source <<<'{"name":"widget","source":{"source":"url","url":"https://github.com/acme/widget.git"}}')"
[ "$fields" = $'url\tacme/widget\t\tv\thttps://github.com/acme/widget.git' ] || die 'url fields shifted'
pass 'url card preserves an empty path and the v prefix'
fields="$(card_source <<<'{"name":"gadget","source":{"source":"git-subdir","url":"https://github.com/acme/mono.git","path":"plugins/gadget"}}')"
[ "$fields" = $'git-subdir\tacme/mono\tplugins/gadget\tgadget--v\thttps://github.com/acme/mono.git' ] || die 'subdir fields wrong'
pass 'git-subdir card has the exact plugin prefix'
for card in '{"source":{"source":"unknown"}}' '{"name":"gadget","source":{"source":"git-subdir","path":"","url":"https://github.com/acme/mono.git"}}' \
  '{"source":{"source":"url"}}' '{"source":{"source":"url","url":"https://elsewhere.com/acme/mono.git"}}'; do
  if card_source <<<"$card" >"$TMP/out" 2>"$TMP/err"; then die "accepted invalid card $card"; fi
  [ -s "$TMP/err" ] || die 'missing card refusal reason'
  pass "card_source refuses $card with a reason"
done
printf '[{"id":1}]\n' > "$FIX/acme/mono/page-1.json"
printf '[{"id":2}]\n' > "$FIX/acme/mono/page-2.json"
[ "$(list_releases acme/mono | jq -c 'map(.id)')" = '[1,2]' ] || die 'pages not flattened'
pass 'list_releases flattens two array pages'
if TMPDIR="$TMP/temps" FAKE_GH_FAIL_AT_PAGE=2 list_releases acme/mono >"$TMP/out" 2>"$TMP/err"; then die 'partial page read succeeded'; fi
[ ! -s "$TMP/out" ] || die 'partial read printed releases'
[ -z "$(ls -A "$TMP/temps")" ] || die 'failed list leaked its temp file'
pass 'page-two gh failure returns no partial releases and removes its temp file'
printf '{}\n' > "$FIX/acme/mono/page-2.json"
if TMPDIR="$TMP/temps" list_releases acme/mono >"$TMP/out" 2>"$TMP/err"; then die 'object page accepted'; fi
[ -z "$(ls -A "$TMP/temps")" ] || die 'invalid page leaked its temp file'
pass 'a non-array page is refused and its temp file removed'
jq -n '[
  {id:1,tag_name:"gadget--v1.0.0",draft:false,prerelease:false,created_at:"2026-01-01"},
  {id:2,tag_name:"gadgets--v9.0.0",draft:false,prerelease:false,created_at:"2026-02-01"},
  {id:3,tag_name:"gizmo--v9.0.0",draft:false,prerelease:false,created_at:"2026-02-02"},
  {id:4,tag_name:"v9.0.0",draft:false,prerelease:false,created_at:"2026-02-03"},
  {id:5,tag_name:"gadget--v3.0.0-rc1",draft:false,prerelease:true,created_at:"2026-03-01"},
  {id:0,tag_name:"gadget--v99.0.0",draft:false,prerelease:false,created_at:"2026-04-01"},
  {id:1.5,tag_name:"gadget--v98.0.0",draft:false,prerelease:false,created_at:"2026-04-02"}
]' > "$FIX/acme/mono/page-1.json"
printf '[]\n' > "$FIX/acme/mono/page-2.json"
[ "$(newest_release acme/mono gadget--v)" = $'gadget--v1.0.0\t1\tfalse' ] || die 'another family or prerelease won'
pass 'exact gadget--v prefix excludes newer adjacent families, prereleases and invalid ids'
printf '[{"id":6,"tag_name":"gadget--v2.0.0","draft":true,"prerelease":false,"created_at":"2026-02-04"}]\n' > "$FIX/acme/mono/page-2.json"
[ "$(newest_release acme/mono gadget--v)" = $'gadget--v2.0.0\t6\ttrue' ] || die 'page-two draft did not win'
pass 'newest_release includes drafts and finds its winner on page two'
[ -z "$(newest_release acme/mono missing--v)" ] || die 'missing family returned a release'
pass 'a prefix with no releases prints nothing'
[ "$(tag_commit acme/mono gadget--v1.0.0)" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] || die 'annotated tag was not dereferenced'
pass 'tag_commit dereferences an annotated tag'
printf '%s card source checks passed\n' "$PASS"
