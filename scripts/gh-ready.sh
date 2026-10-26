#!/usr/bin/env bash
# gh-ready.sh: robot-mode ready-work query over GitHub issues.
# Ready = open AND not labeled `blocked`
#         AND not blocked by any OPEN issue in the native dependency graph.
#
# Contract (native edges, issue #431): the blocked-by graph is authoritative
# for issue-to-issue dependencies. The `blocked` label remains a manual
# override for blockers that are not issues. (Issue claiming was retired in
# fleet teardown move 7, 2026-10-17, so there is no `claimed` filter.)
#
# Mechanism notes (measured 2026-08-21, gh 2.97.0; corrected the same day by
# the inward vet after the first measurement proved to be a probe artifact):
#   - PROBE TRAP: never pass a multi-qualifier string as ONE quoted positional
#     to `gh search issues`. The CLI folds everything after the first
#     `is:`/`-is:` token into that qualifier's quoted value (GH_DEBUG=api
#     shows q=( is:"open -is:blocked" )) -- a lexical phrase matching nothing,
#     so ANY two-qualifier string returns [], including ones with no blocked
#     qualifier at all. An earlier version of this header blamed `is:blocked`
#     itself on the strength of exactly that broken probe (and its "control"
#     count of 30 was `gh search issues`' default --limit 30, not the real
#     open count).
#   - Correctly composed, POSITIVE `is:blocked` works on both backends
#     (verified against a repo with live edges). Ready-work needs the
#     NEGATION, and `-is:blocked` is not trustworthy there: via GraphQL
#     search it NO-OPS to the full unfiltered set -- blocked issues included
#     -- and `gh issue list --search` rides GraphQL. The qualifier is also
#     absent from GitHub's documented `is:` values. A filter that silently
#     serves blocked work as ready is the worst available failure shape, so
#     search-level negation stays out regardless of which backend honors it
#     on a given day.
#   - So blocking state is read from blockedBy nodes (documented,
#     schema-introspectable, each carries .state) fetched inside the SAME
#     single query: repo mode via `gh issue list --json ...,blockedBy`; org
#     mode via one GraphQL search with nested blockedBy (cursor-paginated
#     past GraphQL's 100/page).
#   - Fail-closed truncation rule: if blockedBy.totalCount exceeds the nodes
#     returned, the unseen blockers cannot be state-checked, so the issue is
#     treated as NOT ready (a gate that cannot compare must not pass).
#   - Requires gh >= 2.94.0 (dependency fields). Below that this script exits
#     1 loudly; it NEVER falls back to label-only filtering silently.
#
# Usage: gh-ready.sh [--repo OWNER/NAME | --all] [--org ORG] [--limit N] [--format json|text]
# Defaults: repo inferred from cwd origin; org StartupBros-com; limit 200; json.
#
# Rate-limit hygiene: exactly ONE search-bucket call per invocation (the
# 30/min search bucket is shared across all concurrent sessions). Repo mode is
# one `issue list`; org mode is one GraphQL search whose pagination pages draw
# GraphQL points, not REST search quota. Call at session start or before a
# claim; never in a polling loop.
# Output is deterministic for an unchanged issue set: items sorted by
# (repo, number), keys sorted, and data_hash = sha256 over (repo,number,updated_at).
set -uo pipefail

REPO="" ALL=0 ORG="StartupBros-com" LIMIT=200 FORMAT=json
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:?}"; shift 2 ;;
    --all)    ALL=1; shift ;;
    --org)    ORG="${2:?}"; shift 2 ;;
    --limit)  LIMIT="${2:?}"; shift 2 ;;
    --format) FORMAT="${2:?}"; shift 2 ;;
    *) echo "usage: gh-ready.sh [--repo OWNER/NAME | --all] [--org ORG] [--limit N] [--format json|text]" >&2; exit 2 ;;
  esac
done

# Version guard: the blockedBy JSON field and dependency flags shipped in gh
# 2.94.0. Fail loudly rather than degrade -- a label-only answer that LOOKS
# like a ready list is worse than no answer (the exact silent-fallback shape
# issue #431's planted negative forbids).
MIN_GH="2.94.0"
GH_VER=$(gh --version 2>/dev/null | sed -n '1s/.*[[:space:]]v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
if [ -z "$GH_VER" ] || [ "$(printf '%s\n%s\n' "$MIN_GH" "$GH_VER" | sort -V | head -n1)" != "$MIN_GH" ]; then
  echo "gh-ready: native dependency edges need gh >= $MIN_GH (detected: ${GH_VER:-unparseable}); refusing to fall back to label-only filtering" >&2
  exit 1
fi

if [ "$ALL" = 0 ] && [ -z "$REPO" ]; then
  REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')
  [ -n "$REPO" ] || { echo "not in a git repo; pass --repo OWNER/NAME or --all" >&2; exit 2; }
fi

# Shared jq preamble: ready = zero OPEN blockers AND a complete node list.
READY_DEFS='
  def open_blockers: [(.blockedBy.nodes // [])[] | select(.state == "OPEN")] | length;
  def truncated_blockers: ((.blockedBy.totalCount // 0) > ((.blockedBy.nodes // []) | length));
  def ready: (open_blockers == 0) and (truncated_blockers | not);
'

if [ "$ALL" = 1 ]; then
  # One GraphQL search, cursor-paginated. `is:issue` in the query string plus
  # the `... on Issue` fragment means non-issue nodes arrive as {} -- the
  # select(.number != null) drops them instead of emitting null rows.
  GQL='query($q:String!,$n:Int!,$cursor:String){
    search(query:$q, type:ISSUE, first:$n, after:$cursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ ... on Issue {
        number title url updatedAt
        repository{ nameWithOwner }
        labels(first:50){ nodes{ name } }
        blockedBy(first:50){ totalCount nodes{ state } }
      } }
    } }'
  Q="org:$ORG is:issue is:open -label:blocked"
  RAW='[]' CURSOR="" LEFT=$LIMIT
  while [ "$LEFT" -gt 0 ]; do
    PAGE=$(( LEFT < 100 ? LEFT : 100 ))
    ARGS=(-f query="$GQL" -f q="$Q" -F n="$PAGE")
    [ -n "$CURSOR" ] && ARGS+=(-f cursor="$CURSOR")
    RESP=$(gh api graphql "${ARGS[@]}") || exit 1
    PAGE_NODES=$(printf '%s' "$RESP" | jq '[.data.search.nodes[]
      | select(.number != null)
      | {repo: .repository.nameWithOwner, number, title, url,
         labels: [.labels.nodes[].name], updated_at: .updatedAt, blockedBy}]') || exit 1
    RAW=$(jq -n --argjson a "$RAW" --argjson b "$PAGE_NODES" '$a + $b')
    LEFT=$(( LEFT - PAGE ))
    [ "$(printf '%s' "$RESP" | jq -r '.data.search.pageInfo.hasNextPage')" = true ] || break
    CURSOR=$(printf '%s' "$RESP" | jq -r '.data.search.pageInfo.endCursor')
  done
  SCOPE=$(jq -n --arg org "$ORG" '{scope:"org", org:$org}')
else
  RAW=$(gh issue list --repo "$REPO" --state open --search "-label:blocked" \
    --json number,title,url,labels,updatedAt,blockedBy --limit "$LIMIT" \
    | jq --arg repo "$REPO" '[.[] | {repo: $repo, number, title, url,
        labels: [.labels[].name], updated_at: .updatedAt, blockedBy}]') || exit 1
  SCOPE=$(jq -n --arg repo "$REPO" '{scope:"repo", repo:$repo}')
fi

ITEMS=$(printf '%s' "$RAW" | jq "$READY_DEFS [.[] | select(ready) | del(.blockedBy)]")
EXCLUDED=$(printf '%s' "$RAW" | jq "$READY_DEFS [.[] | select(ready | not)] | length")
# truncated must reflect the RAW fetch against the limit, not the post-filter
# ready count: with the cap hit and some fetched issues excluded as blocked,
# comparing the filtered count would report truncated:false on a scan that
# provably stopped early (inward-vet finding, 2026-08-21).
RAW_COUNT=$(printf '%s' "$RAW" | jq length)

SORTED=$(printf '%s' "$ITEMS" | jq 'sort_by(.repo, .number)')
COUNT=$(printf '%s' "$SORTED" | jq length)
HASH=$(printf '%s' "$SORTED" | jq -cS '[.[] | {repo, number, updated_at}]' | sha256sum | cut -d' ' -f1)

if [ "$FORMAT" = text ]; then
  # Contract line on stderr so `ready:N`/item parsing on stdout is unchanged.
  echo "contract:native-edges+labels gh:$GH_VER excluded_blocked:$EXCLUDED" >&2
  printf '%s' "$SORTED" | jq -r '.[] | "\(.repo)#\(.number): \(.title) (\(.url))"'
  echo "ready:$COUNT"
else
  jq -Sn --argjson items "$SORTED" --argjson query "$SCOPE" \
    --arg hash "sha256:$HASH" --arg gen "$(date -Iseconds)" --argjson limit "$LIMIT" \
    --arg ghv "$GH_VER" --argjson excluded "$EXCLUDED" --argjson rawc "$RAW_COUNT" \
    '{schema:"gh-ready.v2", generated_at:$gen, query:$query, data_hash:$hash,
      contract:"native-edges+labels", gh_version:$ghv, excluded_blocked:$excluded,
      count: ($items|length), truncated: ($rawc >= $limit), items:$items}'
fi
