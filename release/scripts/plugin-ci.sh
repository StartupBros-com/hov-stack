#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"
dir="${1:?usage: plugin-ci.sh <plugin-dir>}"; dir="${dir%/}"
name="${dir##*/}"; failed=0
ok() { printf 'ok - %s\n' "$*"; }
problem() { printf '::error::%s\n' "$*" >&2; failed=1; }

for file in "$dir/.claude-plugin/plugin.json" "$dir/VERSION"; do
  if [ -f "$file" ]; then ok "$file exists"; else problem "missing $file"; fi
done
version=''; manifest_version=''; manifest_name=''
if version="$(plugin_version_file "$dir")"; then
  if is_release_semver "$version"; then ok "$name VERSION is release semver"; else problem "$name VERSION '$version' is not release semver"; fi
else failed=1; fi
if manifest_version="$(plugin_manifest_version "$dir")"; then
  if [ "$version" = "$manifest_version" ]; then ok "$name VERSION matches manifest version"; else problem "$name VERSION $version does not match manifest version $manifest_version"; fi
else failed=1; fi
if manifest_name="$(plugin_manifest_name "$dir")"; then
  if [ "$manifest_name" = "$name" ]; then ok "$name manifest name matches directory"; else problem "$name manifest name $manifest_name does not match directory $name"; fi
else failed=1; fi
if is_skill_pack "$name"; then
  if compgen -G "$dir/skills/*/SKILL.md" >/dev/null; then ok "$name ships at least one skill"; else problem "missing $dir/skills/<skill>/SKILL.md"; fi
elif [ -f "$dir/skills/$name/SKILL.md" ]; then ok "$name SKILL.md exists"
else problem "missing $dir/skills/$name/SKILL.md"; fi

base="${BASE_SHA:-}"
if [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null \
   && previous="$(git show "$base:$dir/VERSION" 2>/dev/null)"; then
  previous="$(jq -Rrs 'gsub("^\\s+|\\s+$"; "")' <<<"$previous")"
  if [ "$previous" != "$version" ] && ! git rev-parse -q --verify "refs/tags/$name--v$version" >/dev/null; then
    notes="$dir/docs/release-notes/v$version.md"
    # What members have is the version the marketplace lists at the base; only the
    # release bot's card PRs move it, and validate-marketplace.sh refuses a changed
    # version under an existing release id. Every version between it and this one has
    # not reached members, so these notes must carry their Highlights (#702). A plugin
    # the marketplace does not list yet has nothing to carry.
    members=''; checks=()
    if manifest="$(git show "$base:.claude-plugin/marketplace.json" 2>/dev/null)"; then
      if ! members="$(jq -r --arg n "$name" 'first(.plugins[] | select(.name == $n) | .metadata.version // empty) // empty' <<<"$manifest")" \
         || { [ -n "$members" ] && ! is_release_semver "$members"; }; then
        problem "$name cannot read the version members have from .claude-plugin/marketplace.json at $base"; members=''
      fi
    fi
    if [ -n "$members" ]; then
      checks+=(--members-version "$members")
      for older in "$dir"/docs/release-notes/v*.md; do
        v="${older##*/v}"; v="${v%.md}"
        if is_release_semver "$v" && release_semver_gt "$v" "$members" && release_semver_gt "$version" "$v"; then
          checks+=(--carry "$older")
          printf '  ! %s\n' "$name v$v has not reached members (the marketplace at ${base:0:12} lists v$members); v$version must carry its Highlights" >&2
        fi
      done
    fi
    if [ ! -f "$notes" ]; then problem "$name VERSION bump requires release notes $notes";
    elif "$SCRIPT_DIR/check-release-notes.sh" "$notes" ${checks[@]+"${checks[@]}"}; then ok "$name bump release notes pass";
    else problem "$name release notes failed: $notes"; fi
  fi
fi
if [ -e "$dir/tests/ci.sh" ]; then
  if [ ! -x "$dir/tests/ci.sh" ]; then problem "$dir/tests/ci.sh exists but is not executable";
  elif (cd "$dir" && ./tests/ci.sh); then ok "$name tests/ci.sh passed"; else problem "$name tests/ci.sh failed"; fi
fi
exit "$failed"
