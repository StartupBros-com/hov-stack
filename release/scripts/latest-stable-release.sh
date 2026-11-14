#!/usr/bin/env bash
set -euo pipefail

# Latest-stable guard for the reusable Tool Drop announce workflow
# (.github/workflows/hov-tool-drop-announce.yml, step "Resolve latest stable
# release"). It answers one question for the release that fired the event:
# which stable release is the newest one in this release's tag family?
#
# A shared repository holds many plugins, each releasing on <name>--v<version>
# tags, so the repository-wide "latest" release says nothing about any one
# plugin. This guard lists every release (paginated), keeps the published,
# non-draft, non-prerelease ones whose tag shares the current tag's family
# under the announce helper's rule (split on the LAST "--v"; a plain
# v<digit...> tag has the empty family; any other tag belongs to no family
# and is ignored), and orders them by numeric major.minor.patch, never by
# creation or publication time.
#
# Environment: REPOSITORY (GitHub repository name, for the marker), RELEASE_ID,
# RELEASE_TAG, GITHUB_REPOSITORY (owner/name, the API path), GITHUB_OUTPUT, and
# GH_TOKEN for gh. Output: `id=<release id>` of the family's newest stable
# release, appended to GITHUB_OUTPUT. When that is not RELEASE_ID the guard
# prints the helper's not-announced marker and exits 0; the announce helper
# then no-ops on LATEST_STABLE_ID. Malformed data fails: a stable same-family
# release whose version does not parse could otherwise make an older release
# look current and announce the wrong artifact.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

is_positive_uint() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

readonly CANONICAL_VERSION='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly PLUGIN_NAME_SHAPE='^[a-z0-9][a-z0-9-]{0,63}$'

GUARD_TMP_DIR=''

cleanup_tmp_dir() {
  local -r tmp_dir="${GUARD_TMP_DIR:-}"
  [[ -n "$tmp_dir" ]] || return 0
  rm -f -- "$tmp_dir/releases.json"
  rmdir -- "$tmp_dir"
  GUARD_TMP_DIR=''
}

# Mirrors derive_plugin_identity in tool-drop-announce.sh: FAMILY is the plugin
# name for a <name>--v<version> tag and empty for a v<version> tag; PLUGIN_NAME
# is what the marker reports (the family, else the repository name).
derive_family() {
  require REPOSITORY
  require RELEASE_TAG
  if [[ "$RELEASE_TAG" == *--v* ]]; then
    FAMILY="${RELEASE_TAG%--v*}"
    [[ "$FAMILY" != *--* ]] || fail "plugin name derived from release tag $RELEASE_TAG contains --, the release tag separator: $FAMILY"
    [[ "$FAMILY" =~ $PLUGIN_NAME_SHAPE ]] || fail "plugin name derived from release tag $RELEASE_TAG has an invalid shape: $FAMILY"
    [[ "${RELEASE_TAG##*--v}" =~ $CANONICAL_VERSION ]] || fail "release tag $RELEASE_TAG has no canonical major.minor.patch version after its last --v"
    PLUGIN_NAME="$FAMILY"
  elif [[ "$RELEASE_TAG" == v* && "${RELEASE_TAG#v}" =~ $CANONICAL_VERSION ]]; then
    FAMILY=''
    PLUGIN_NAME="$REPOSITORY"
  else
    fail "release tag $RELEASE_TAG is neither <name>--v<major.minor.patch> nor v<major.minor.patch>"
  fi
}

list_releases() {
  require GITHUB_REPOSITORY
  GUARD_TMP_DIR="$(mktemp -d)" || fail "could not create a temp directory for the release list"
  trap cleanup_tmp_dir EXIT
  # Every page lands in the file before anything reads it, and the status is
  # checked here, on its own line: a failure on page two must fail the guard,
  # not leave a truncated list that looks complete.
  if ! gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" >"$GUARD_TMP_DIR/releases.json"; then
    fail "listing releases of $GITHUB_REPOSITORY failed"
  fi
}

# Prints "<id>\t<tag>" of the newest stable release in FAMILY. Each page is one
# JSON array; -s slurps every page before filtering, so an older page can
# still hold the family's newest version.
family_winner() {
  jq -ser -e \
    --arg family "$FAMILY" \
    --arg release_id "$RELEASE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    '
      def valid_release:
        type == "object" and
        has("id") and (.id | type == "number") and (.id > 0) and (.id == (.id | floor)) and
        has("tag_name") and (.tag_name | type == "string") and
        has("draft") and (.draft | type == "boolean") and
        has("prerelease") and (.prerelease | type == "boolean");
      def family_of:
        if test("--v") then
          (capture("^(?<name>.*)--v(?<version>.*)$") // null)
          | if . == null then null else {family: .name, version: .version} end
        elif test("^v[0-9]") then
          {family: "", version: .[1:]}
        else
          null
        end;
      # capture yields nothing on a non-match, and an empty value would drop
      # the record from the list; a non-match must become null and fail.
      # A v-prefixed tag joins the repository family only when a digit
      # follows the v: vendor-2024 is ignored, v2 is a version that must
      # parse and fails loudly when it does not.
      def canonical_version:
        (capture("^(?<major>0|[1-9][0-9]*)\\.(?<minor>0|[1-9][0-9]*)\\.(?<patch>0|[1-9][0-9]*)$") // null)
        | if . == null then null else [(.major | tonumber), (.minor | tonumber), (.patch | tonumber)] end;
      if any(.[]; type != "array") then error("release list page is not an array") else . end
      | [.[][]] as $all
      | if any($all[]; valid_release | not) then error("release list record failed validation") else . end
      | [ $all[]
          | select(.draft == false and .prerelease == false)
          | (.tag_name | family_of) as $parsed
          | select($parsed != null and $parsed.family == $family)
          | {id, tag_name, version: ($parsed.version | canonical_version)}
        ] as $stable
      | ($stable | map(select(.version == null))) as $malformed
      | if ($malformed | length) > 0 then
          error("stable release " + $malformed[0].tag_name + " in the family of " + $release_tag + " has a non-canonical version")
        elif ($stable | length) == 0 then
          error("no stable release in the family of " + $release_tag)
        elif ($stable | map(select((.id | tostring) == $release_id)) | length) != 1 then
          error("release " + $release_id + " is not a stable release in the family of " + $release_tag)
        elif ($stable | map(select((.id | tostring) == $release_id)) | .[0].tag_name) != $release_tag then
          error("release " + $release_id + " is listed under a tag other than " + $release_tag)
        else
          ($stable | sort_by(.version) | last | "\(.id)\t\(.tag_name)")
        end
    ' "$GUARD_TMP_DIR/releases.json"
}

main() {
  [[ $# -eq 0 ]] || fail "this guard accepts no arguments"
  require RELEASE_ID
  is_positive_uint "$RELEASE_ID" || fail "RELEASE_ID must be a positive canonical decimal integer"
  require GITHUB_OUTPUT
  derive_family
  list_releases

  local winner winner_id winner_tag family_label
  if ! winner="$(family_winner)"; then
    fail "resolving the latest stable release in the family of $RELEASE_TAG failed"
  fi
  winner_id="${winner%%$'\t'*}"
  winner_tag="${winner#*$'\t'}"
  is_positive_uint "$winner_id" || fail "latest stable release id is not a positive integer: $winner_id"
  [[ -n "$winner_tag" && "$winner_tag" != *$'\t'* ]] || fail "latest stable release tag is malformed"

  if [[ -n "$FAMILY" ]]; then
    family_label="plugin $FAMILY"
  else
    family_label="repository $REPOSITORY"
  fi

  if [[ "$winner_id" == "$RELEASE_ID" ]]; then
    printf 'release %s (%s) is the latest stable release of %s\n' "$RELEASE_ID" "$RELEASE_TAG" "$family_label"
  else
    printf '::notice title=Not announced::Release %s is not the latest stable release of %s; %s (release %s) is\n' \
      "$RELEASE_TAG" "$family_label" "$winner_tag" "$winner_id"
    printf 'hov-drop-announce: status=not-announced reason=not-latest repository=%s tag=%s plugin=%s\n' \
      "$REPOSITORY" "$RELEASE_TAG" "$PLUGIN_NAME"
  fi
  printf 'id=%s\n' "$winner_id" >>"$GITHUB_OUTPUT"
}

main "$@"
