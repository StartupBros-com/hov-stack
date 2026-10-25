#!/usr/bin/env bash

# Shared interpretation of marketplace cards and their release tag families.
MONOREPO_SOURCE_URL="${MONOREPO_SOURCE_URL:-https://github.com/StartupBros-com/hov-stack.git}"

# Keep the canonical URL rule identical for every caller.
repo_from_url() {
  local url="$1" path
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  case "$path" in
    */*/*|'') return 1 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

card_source() {
  local card name shape url repo path='' prefix
  card="$(jq -ce 'if type == "object" then . else error("not a card object") end')" \
    || { printf 'error: could not read card object\n' >&2; return 1; }
  name="$(jq -r '.name // ""' <<<"$card")"
  shape="$(jq -r '.source.source // ""' <<<"$card")"
  case "$shape" in
    url) prefix=v ;;
    git-subdir)
      path="$(jq -er '.source.path | select(type == "string" and length > 0)' <<<"$card")" \
        || { printf 'error: %s git-subdir card has an empty or invalid path\n' "$name" >&2; return 1; }
      prefix="$name--v" ;;
    *) printf 'error: %s has an unknown source shape: %s\n' "$name" "$shape" >&2; return 1 ;;
  esac
  url="$(jq -er '.source.url | select(type == "string" and length > 0)' <<<"$card")" \
    || { printf 'error: %s has no source.url\n' "$name" >&2; return 1; }
  repo="$(repo_from_url "$url")" \
    || { printf 'error: %s has an unresolvable source.url: %s\n' "$name" "$url" >&2; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$shape" "$repo" "$path" "$prefix" "$url"
}

list_releases() {
  local repo="$1" tmp status=0
  tmp="$(mktemp)" || return 1
  # Check the complete paginated read before parsing, including failures on later pages.
  if ! gh api --paginate "repos/$repo/releases?per_page=100" >"$tmp"; then
    printf 'error: listing releases of %s failed\n' "$repo" >&2
    rm -f -- "$tmp"
    return 1
  fi
  jq -s 'if all(.[]; type == "array") then add // [] else error("release list page is not an array") end' "$tmp" || status=1
  rm -f -- "$tmp"
  return "$status"
}

newest_release() {
  local repo="$1" prefix="$2" releases
  releases="$(list_releases "$repo")" || return 1
  # Drafts need pinning before publication; prereleases are never distributed.
  jq -r --arg prefix "$prefix" '
    [ .[] | select(type == "object")
          | select(.prerelease == false)
          | select((.tag_name | type) == "string" and (.tag_name | length) > 0)
          | select(.tag_name | startswith($prefix))
          | select((.id | type) == "number" and .id > 0 and (.id | floor) == .id) ]
    | sort_by(.created_at) | reverse | first // empty
    | [.tag_name, .id, (.draft == true)] | @tsv
  ' <<<"$releases"
}

tag_commit() {
  local repo="$1" tag="$2" sha obj_type
  sha="$(gh api "repos/$repo/git/ref/tags/$tag" --jq '.object.sha' 2>/dev/null)" \
    || { printf 'error: could not resolve tag %s in %s\n' "$tag" "$repo" >&2; return 1; }
  obj_type="$(gh api "repos/$repo/git/ref/tags/$tag" --jq '.object.type' 2>/dev/null)" \
    || { printf 'error: could not read the tag type of %s in %s\n' "$tag" "$repo" >&2; return 1; }
  if [ "$obj_type" = tag ]; then
    sha="$(gh api "repos/$repo/git/tags/$sha" --jq '.object.sha' 2>/dev/null)" \
      || { printf 'error: could not dereference annotated tag %s in %s\n' "$tag" "$repo" >&2; return 1; }
  fi
  printf '%s\n' "$sha"
}

default_branch() {
  gh api "repos/$1" --jq '.default_branch' 2>/dev/null \
    || { printf 'error: could not read the default branch of %s\n' "$1" >&2; return 1; }
}

compare_status() {
  gh api "repos/$1/compare/$2...$3" --jq '.status' 2>/dev/null \
    || { printf 'error: could not compare %s against %s in %s\n' "$3" "$2" "$1" >&2; return 1; }
}
