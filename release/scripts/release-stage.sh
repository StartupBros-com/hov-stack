#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"
tag="${RELEASE_TAG:-}"; plugins="${PLUGINS_DIR:-plugins}"; branch="${DEFAULT_BRANCH:-main}"; remote="${REMOTE:-origin}"
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
name="$(tag_plugin_name "$tag")" || fail "$tag is not a <name>--v<version> tag"
version="$(tag_plugin_version "$tag")"; dir="$plugins/$name"
[ -f "$dir/.claude-plugin/plugin.json" ] || fail "unknown plugin $name: no $dir/ at $tag"
sha="$(git rev-list -n 1 "refs/tags/$tag" 2>/dev/null)" || fail "tag $tag does not exist"
[ "$(git rev-parse HEAD)" = "$sha" ] || fail "checkout HEAD is not $tag ($sha)"
git fetch "$remote" "$branch" || fail "could not fetch $remote/$branch for $tag"
commit_on_branch "$sha" "$remote/$branch" || fail "$tag ($sha) is not on $branch; refusing to stage a release from a side branch"
current="$(plugin_version_file "$dir")" || fail "$tag cannot read $dir/VERSION"
is_release_semver "$current" || fail "$tag VERSION $current is not release semver"
[ "$version" = "$current" ] || fail "tag $tag does not match VERSION $current"
manifest_version="$(plugin_manifest_version "$dir")" || fail "$tag cannot read manifest version"
[ "$manifest_version" = "$version" ] || fail "$tag manifest version $manifest_version does not match VERSION $current"
manifest_name="$(plugin_manifest_name "$dir")" || fail "$tag cannot read manifest name"
[ "$manifest_name" = "$name" ] || fail "$tag manifest name $manifest_name does not match plugin $name"
notes="$dir/docs/release-notes/v$version.md"
[ -f "$notes" ] || fail "$tag requires release notes $notes"
"$SCRIPT_DIR/check-release-notes.sh" "$notes" || fail "$tag release notes failed: $notes"
# A plugin that ships files beyond its source (pro-gate's runtime tarball) builds them with
# release/stage-assets.sh <outdir>. The reconciler publishes a draft whether or not it has
# assets, so a hook that fails, builds nothing, or loses an upload must stop the stage here.
hook="$dir/release/stage-assets.sh"; assets=(); expected=''
if [ -e "$hook" ]; then
  [ -x "$hook" ] || fail "$tag asset hook $hook is not executable"
  out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
  RELEASE_TAG="$tag" RELEASE_VERSION="$version" "$hook" "$out" || fail "$tag asset hook $hook failed"
  while IFS= read -r -d '' f; do assets+=("$f"); done < <(find "$out" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
  [ "${#assets[@]}" -gt 0 ] || fail "$tag asset hook $hook produced no files"
  expected="$(for f in "${assets[@]}"; do basename "$f"; done)"
fi
# Prints the hook-built asset names the release lacks, space-separated; fails if unreadable.
missing_assets() {
  local have
  have="$(gh release view "$tag" --json assets --jq '.assets[].name')" || return 1
  LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$have" | LC_ALL=C sort) | paste -sd ' ' -
}
# A hooked draft is created as a prerelease: card-source.sh, repin-migrate.sh and
# repin-publish.sh never select one, so no repin can pin it while its uploads land or
# after they fail. Only such a still-ineligible draft is ever deleted; once its assets
# check out the flag is cleared, and from then on nothing here touches it. Deleting a
# release keeps its tag, so a re-run stages the draft again from scratch.
staging_draft() {
  local s
  s="$(gh release view "$tag" --json isDraft,isPrerelease 2>/dev/null)" || return 1
  [ "$(jq -r '.isDraft and .isPrerelease' <<<"$s")" = true ]
}
drop_staging_draft() {
  staging_draft || return 1
  gh release delete "$tag" --yes
}
if state="$(gh release view "$tag" --json id,isDraft,isPrerelease 2>/dev/null)"; then
  id="$(jq -r .id <<<"$state")"; draft="$(jq -r .isDraft <<<"$state")"
  if [ -n "$expected" ] && [ "$(jq -r '.isDraft and .isPrerelease' <<<"$state")" = true ]; then
    # An earlier run died before clearing the flag; no repin can have pinned this draft.
    gh release delete "$tag" --yes || fail "release $tag is an unfinished staging draft (id $id) and could not be deleted; delete it before re-running"
    printf '::notice::deleted unfinished staging draft %s (id %s); staging it again\n' "$tag" "$id"
  else
    if [ -n "$expected" ]; then
      missing="$(missing_assets)" || fail "could not read the assets of release $tag"
      [ -z "$missing" ] || fail "release $tag already exists (id $id, draft $draft) but lacks $missing, which its asset hook builds; it may already be pinned, so it is left alone (see the recipe's delete-draft hazard)"
    fi
    printf '::notice::release %s already exists (id %s, draft %s); nothing to stage\n' "$tag" "$id" "$draft"
    exit 0
  fi
fi
"$SCRIPT_DIR/release-gate.sh" "$name" "$sha" || fail "$tag CI release gate failed on $sha"
if [ -z "$expected" ]; then
  gh release create "$tag" --draft --verify-tag --title "$name v$version" --notes-file "$notes" || fail "could not stage draft $tag"
else
  # gh keeps an explicitly requested draft when an upload fails, so a failed create may
  # still leave one behind; remove it here rather than let a re-run find it.
  if ! gh release create "$tag" "${assets[@]}" --draft --prerelease --verify-tag --title "$name v$version" --notes-file "$notes"; then
    if drop_staging_draft; then fail "could not stage draft $tag; the partial staging draft was deleted, re-run to stage it again"; fi
    fail "could not stage draft $tag"
  fi
  missing="$(missing_assets)" || missing='its assets (unreadable)'
  if [ -n "$missing" ]; then
    drop_staging_draft || fail "staging draft $tag lacks $missing and could not be deleted; delete it before re-running"
    fail "draft $tag lacked $missing after upload and was deleted; re-run to stage it again"
  fi
  gh release edit "$tag" --prerelease=false >/dev/null || fail "staging draft $tag has every asset but its prerelease flag could not be cleared; re-run to stage it again"
  pre="$(gh release view "$tag" --json isPrerelease --jq .isPrerelease)" || fail "could not confirm staging draft $tag left prerelease; check it before re-running"
  [ "$pre" = false ] || fail "staging draft $tag still reads prerelease $pre after clearing the flag; re-run to stage it again"
fi
id="$(gh release view "$tag" --json id --jq .id)" || fail "could not read staged draft $tag id"
printf '::notice::staged draft %s (id %s)\n' "$tag" "$id"
