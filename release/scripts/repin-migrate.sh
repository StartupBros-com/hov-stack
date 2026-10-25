#!/usr/bin/env bash
set -euo pipefail

# Migrate one card to the shared repository's newest prefixed release.
#
# The validator admits the url-to-git-subdir transition once per plugin. The
# reconciler never changes a card's shape; this script writes that one transition
# (or creates the hov-stack skill pack's first entry), and the workflow opens the PR.
#
# Usage:
#   release/scripts/repin-migrate.sh <name>
#   DRY_RUN=1 release/scripts/repin-migrate.sh <name>
#
# Env:
#   MANIFEST             marketplace.json (default: .claude-plugin/marketplace.json)
#   PLAN_FILE            TSV plan (default: repin-plan.tsv)
#   DRY_RUN              1 writes the plan only (default: 0)
#   GH_TOKEN             release App token for draft-visible reads
#   MONOREPO_SOURCE_URL  shared source URL (default: StartupBros-com/hov-stack.git)
#
# Exit codes:
#   0  migration written, or a dry-run plan written
#   1  invalid input, refusal, or read/write failure; manifest untouched

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# One rule for shape, repo, path and prefix instead of three copies.
# shellcheck source=release/scripts/card-source.sh
. "$(dirname "${BASH_SOURCE[0]}")/card-source.sh"

MANIFEST="${MANIFEST:-.claude-plugin/marketplace.json}"
PLAN_FILE="${PLAN_FILE:-repin-plan.tsv}"
DRY_RUN="${DRY_RUN:-0}"

[ "$#" -eq 1 ] || fail 'usage: repin-migrate.sh <name>'
name="$1"
[[ "$name" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]] || fail "invalid plugin name: $name (names must not contain --)"
[ -s "$MANIFEST" ] || fail "manifest not found: $MANIFEST"
count="$(jq -er --arg n "$name" '[.plugins[] | select(type == "object" and .name == $n)] | length' "$MANIFEST")" \
  || fail "could not read entries from $MANIFEST"
origin='url entry'
case "$count" in
  0)
    [ "$name" = hov-stack ] || fail "$name has no entry; only hov-stack may be created"
    origin='new entry' ;;
  1)
    shape="$(jq -r --arg n "$name" '.plugins[] | select(type == "object" and .name == $n) | .source.source' "$MANIFEST")" \
      || fail "could not read the source shape of $name"
    [ "$shape" != git-subdir ] || fail "$name is already a git-subdir entry"
    [ "$shape" = url ] || fail "$name must be a url entry (found $shape)" ;;
  *) fail "manifest holds more than one entry for $name" ;;
esac

monorepo="$(repo_from_url "$MONOREPO_SOURCE_URL")" || fail "unresolvable monorepo source url: $MONOREPO_SOURCE_URL"
prefix="$name--v"
rel="$(newest_release "$monorepo" "$prefix")" || fail "could not read releases for $monorepo"
[ -n "$rel" ] || fail "no non-prerelease release with prefix $prefix in $monorepo; drafts are invisible unless GH_TOKEN is a release App token scoped to $monorepo"
IFS=$'\t' read -r tag rel_id is_draft <<<"$rel"
case "$tag" in "$prefix"*) ;; *) fail "tag $tag does not start with prefix $prefix" ;; esac
version="${tag#"$prefix"}"
sha="$(tag_commit "$monorepo" "$tag")" || fail "could not resolve tag $tag in $monorepo"
branch="$(default_branch "$monorepo")" || fail "could not read the default branch of $monorepo"
status="$(compare_status "$monorepo" "$branch" "$sha")" || fail "could not compare $tag against $branch in $monorepo"
case "$status" in
  identical|behind) ;;
  *) fail "$name: $tag (${sha:0:8}) is not on $branch (compare status: ${status:-empty})" ;;
esac

description=''
if [ "$count" -eq 0 ]; then
  plugin="$(gh api "repos/$monorepo/contents/plugins/hov-stack/.claude-plugin/plugin.json?ref=$sha" -H 'Accept: application/vnd.github.raw')" \
    || fail "could not read hov-stack plugin.json at $sha in $monorepo"
  description="$(jq -er 'select(.name == "hov-stack") | .description | select(type == "string" and length > 0)' <<<"$plugin")" \
    || fail 'hov-stack plugin.json must name hov-stack and carry a non-empty description'
fi

: > "$PLAN_FILE"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$tag" "$rel_id" "$sha" "$is_draft" >> "$PLAN_FILE"
printf 'migrate %s: %s -> %s (%s, draft=%s)\n' "$name" "$origin" "$tag" "$rel_id" "$is_draft" >&2
if [ "$DRY_RUN" = 1 ]; then
  printf 'dry run: manifest untouched\n'
  exit 0
fi

tmp="$(mktemp)" || fail 'could not create manifest temp file'
if ! jq -a --indent 2 \
  --arg n "$name" --arg v "$version" --arg t "$tag" --arg s "$sha" --argjson i "$rel_id" \
  --arg url "$MONOREPO_SOURCE_URL" --arg d "$description" --argjson count "$count" '
    {source: "git-subdir", url: $url, path: ("plugins/" + $n), sha: $s} as $source
    | {version: $v, releaseId: $i, releaseTag: $t} as $metadata
    | if $count == 0 then
        .plugins += [{name: $n, source: $source, description: $d, metadata: $metadata}]
      else
        .plugins |= map(if type == "object" and .name == $n then
          .source = $source | .metadata = $metadata
        else . end)
      end
  ' "$MANIFEST" > "$tmp"; then
  rm -f -- "$tmp"
  fail "failed to migrate the card for $name"
fi
if ! mv -- "$tmp" "$MANIFEST"; then
  rm -f -- "$tmp"
  fail "failed to replace $MANIFEST"
fi
printf 'migrated %s: %s (releaseId %s)\n' "$name" "$tag" "$rel_id"
