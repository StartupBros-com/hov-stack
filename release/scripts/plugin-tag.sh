#!/usr/bin/env bash
set -euo pipefail

# Shared tag and plugin identity rules. Source this file; it performs no work.
tag_plugin_name() {
  local tag="$1" name version
  name="${tag%--v*}"; version="${tag##*--v}"
  if [[ "$tag" != *--v* || -z "$name" || "$version" != [0-9]* ]]; then
    printf 'error: %s is not a <name>--v<version> tag\n' "$tag" >&2
    return 1
  fi
  printf '%s\n' "$name"
}

tag_plugin_version() {
  tag_plugin_name "$1" >/dev/null || return 1
  printf '%s\n' "${1##*--v}"
}

is_release_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# True when release semver $1 is newer than release semver $2.
release_semver_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"; IFS=. read -r b1 b2 b3 <<<"$2"
  (( 10#$a1 > 10#$b1 || (10#$a1 == 10#$b1 && (10#$a2 > 10#$b2 || (10#$a2 == 10#$b2 && 10#$a3 > 10#$b3))) ))
}

# The skill pack ships several skills as skills/<skill>/SKILL.md and none named
# after itself; every other plugin's entry skill is skills/<name>/SKILL.md.
is_skill_pack() { [ "$1" = hov-stack ]; }

plugin_manifest_name() {
  local file="$1/.claude-plugin/plugin.json"
  jq -er '.name | select(type == "string" and length > 0)' "$file" \
    || { printf '::error::cannot read name from %s\n' "$file" >&2; return 1; }
}

plugin_manifest_version() {
  local file="$1/.claude-plugin/plugin.json"
  jq -er '.version | select(type == "string" and length > 0)' "$file" \
    || { printf '::error::cannot read version from %s\n' "$file" >&2; return 1; }
}

plugin_version_file() {
  local file="$1/VERSION"
  if [ ! -f "$file" ]; then
    printf '::error::missing %s\n' "$file" >&2; return 1
  fi
  jq -Rrs 'gsub("^\\s+|\\s+$"; "")' "$file"
}

commit_on_branch() { git merge-base --is-ancestor "$1" "$2"; }
