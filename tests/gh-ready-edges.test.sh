#!/usr/bin/env bash
# Tests for scripts/gh-ready.sh's native dependency-edge contract
# (issue #431). Hermetic: a PATH-prepended gh stub serves canned fixtures and
# a configurable version string; no network, no real gh, no ~/.claude.
#
# The load-bearing pair is planted-negative C1: two issues identical except
# for their blocker's state (OPEN vs CLOSED). A label-only implementation, or
# one that reads edges but ignores their state, returns BOTH as ready;
# correct output returns only the closed-blocker one. C2 pins the version
# guard's fail-loud contract (a gh too old for dependency fields must produce
# NO ready list at all, never a label-only one). C3 pins fail-closed
# truncation (blockedBy.totalCount > returned nodes = cannot verify = not
# ready). C4 covers org-mode GraphQL, including dropping the empty {} node a
# non-Issue search hit produces.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
SCRIPT="$HERE/scripts/gh-ready.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: not found: $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1" in
  --version) echo "gh version ${GH_STUB_VERSION:-2.97.0} (2026-01-01)"; exit 0 ;;
  issue)
    [ "$2" = list ] || exit 1
    cat "${GH_STUB_LIST_FILE:?}" ;;
  api)
    [ "$2" = graphql ] || exit 1
    cat "${GH_STUB_GQL_FILE:?}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALLS="$TMP/gh-calls.log"

# Repo-mode fixture (`gh issue list --json` shape):
#   101 blocked by an OPEN issue   -> NOT ready
#   102 blocked by a CLOSED issue  -> ready (differs from 101 ONLY in state)
#   103 no blockers                -> ready
#   104 truncated blocker list     -> NOT ready (fail-closed)
cat >"$TMP/list.json" <<'JSON'
[
 {"number":101,"title":"open-blocked","url":"u101","labels":[],"updatedAt":"2026-08-01T00:00:00Z",
  "blockedBy":{"totalCount":1,"nodes":[{"number":9,"state":"OPEN"}]}},
 {"number":102,"title":"closed-blocked","url":"u102","labels":[],"updatedAt":"2026-08-01T00:00:00Z",
  "blockedBy":{"totalCount":1,"nodes":[{"number":9,"state":"CLOSED"}]}},
 {"number":103,"title":"unblocked","url":"u103","labels":[],"updatedAt":"2026-08-01T00:00:00Z",
  "blockedBy":{"totalCount":0,"nodes":[]}},
 {"number":104,"title":"truncated","url":"u104","labels":[],"updatedAt":"2026-08-01T00:00:00Z",
  "blockedBy":{"totalCount":3,"nodes":[{"number":9,"state":"CLOSED"}]}}
]
JSON
export GH_STUB_LIST_FILE="$TMP/list.json"

echo "== C1 + C3: repo mode planted-negative pair, fail-closed truncation =="
OUT=$(bash "$SCRIPT" --repo fake/fake); RC=$?
[ "$RC" = 0 ] && ok || bad "repo mode exited $RC"
nums=$(printf '%s' "$OUT" | jq -c '[.items[].number]')
[ "$nums" = "[102,103]" ] && ok \
  || bad "ready set wrong: $nums (want [102,103] -- 101 open-blocked and 104 truncated must be excluded)"
[ "$(printf '%s' "$OUT" | jq -r .schema)" = "gh-ready.v2" ] && ok || bad "schema not gh-ready.v2"
[ "$(printf '%s' "$OUT" | jq -r .contract)" = "native-edges+labels" ] && ok || bad "contract field missing/wrong"
[ "$(printf '%s' "$OUT" | jq -r .gh_version)" = "2.97.0" ] && ok || bad "gh_version not logged in envelope"
[ "$(printf '%s' "$OUT" | jq -r .excluded_blocked)" = "2" ] && ok || bad "excluded_blocked != 2"

echo "== C6: truncated reflects the RAW fetch vs limit, not the post-filter count =="
# 4 raw issues fetched with --limit 4 = cap hit, so truncated MUST be true
# even though only 2 survive the ready filter. The wrong implementation
# (comparing the post-filter count 2 >= 4) reports truncated:false -- a capped
# scan silently presented as a complete ready list (inward-vet finding).
OUT=$(bash "$SCRIPT" --repo fake/fake --limit 4); RC=$?
[ "$RC" = 0 ] && ok || bad "limit-4 run exited $RC"
[ "$(printf '%s' "$OUT" | jq -r .truncated)" = "true" ] && ok \
  || bad "truncated=false on a cap-hit fetch with exclusions (must compare raw count to limit)"
[ "$(printf '%s' "$OUT" | jq -r .count)" = "2" ] && ok || bad "count wrong on limit-4 run"
# Control: an uncapped fetch (default limit 200) of the same 4 issues is not truncated.
OUT=$(bash "$SCRIPT" --repo fake/fake)
[ "$(printf '%s' "$OUT" | jq -r .truncated)" = "false" ] && ok || bad "truncated=true on an uncapped fetch"

echo "== C2: version guard fails loudly, emits NO ready list =="
ERR="$TMP/c2.err"
OUT=$(GH_STUB_VERSION=2.83.1 bash "$SCRIPT" --repo fake/fake 2>"$ERR"); RC=$?
[ "$RC" = 1 ] && ok || bad "old gh exited $RC (want 1)"
[ -z "$OUT" ] && ok || bad "old gh still produced stdout (silent label-only fallback?): $OUT"
grep -q "2.94" "$ERR" && ok || bad "version-guard error does not name the 2.94 floor"

echo "== C5: text mode keeps stdout parseable, contract goes to stderr =="
ERR="$TMP/c5.err"
OUT=$(bash "$SCRIPT" --repo fake/fake --format text 2>"$ERR"); RC=$?
[ "$RC" = 0 ] && ok || bad "text mode exited $RC"
grep -q "ready:2" <<<"$OUT" && ok || bad "text mode ready count wrong: $OUT"
grep -q "#101" <<<"$OUT" && bad "text mode leaked open-blocked #101" || ok
grep -q "contract:native-edges+labels" "$ERR" && ok || bad "text mode stderr lacks contract line"

echo "== C4: org mode GraphQL search, non-Issue {} node dropped =="
cat >"$TMP/gql.json" <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":"X"},
 "nodes":[
  {"number":201,"title":"org-open-blocked","url":"u201","updatedAt":"2026-08-01T00:00:00Z",
   "repository":{"nameWithOwner":"fake/a"},"labels":{"nodes":[]},
   "blockedBy":{"totalCount":1,"nodes":[{"state":"OPEN"}]}},
  {"number":202,"title":"org-clear","url":"u202","updatedAt":"2026-08-01T00:00:00Z",
   "repository":{"nameWithOwner":"fake/b"},"labels":{"nodes":[{"name":"x"}]},
   "blockedBy":{"totalCount":0,"nodes":[]}},
  {}
 ]}}}
JSON
export GH_STUB_GQL_FILE="$TMP/gql.json"
OUT=$(bash "$SCRIPT" --all --org fake-org); RC=$?
[ "$RC" = 0 ] && ok || bad "org mode exited $RC"
refs=$(printf '%s' "$OUT" | jq -c '[.items[] | "\(.repo)#\(.number)"]')
[ "$refs" = '["fake/b#202"]' ] && ok \
  || bad "org ready set wrong: $refs (201 open-blocked must be excluded; {} node dropped)"
grep -q "api graphql" "$GH_CALLS" && ok || bad "org mode never called GraphQL"

echo
echo "gh-ready-edges: $pass passed, $fail failed"
[ "$fail" = 0 ]
