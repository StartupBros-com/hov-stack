#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"

MODE="${1:-syntax}"
MANIFEST="${MARKETPLACE_MANIFEST:-.claude-plugin/marketplace.json}"
BASE_REF="${BASE_REF:-}"
EXPECTED_PLUGIN_NAME="${EXPECTED_PLUGIN_NAME:-}"
EXPECTED_PLUGIN_VERSION="${EXPECTED_PLUGIN_VERSION:-}"
EXPECTED_RELEASE_ID="${EXPECTED_RELEASE_ID:-}"
EXPECTED_RELEASE_TAG="${EXPECTED_RELEASE_TAG:-}"
EXPECTED_SHA="${EXPECTED_SHA:-}"
EXPECTED_PAYLOAD_PATHS="${EXPECTED_PAYLOAD_PATHS:-}"
ALLOW_LOCAL_FILE_REMOTES="${ALLOW_LOCAL_FILE_REMOTES:-0}"
MARKETPLACE_TEST_REMOTE_ROOT="${MARKETPLACE_TEST_REMOTE_ROOT:-}"
# The one repository a git-subdir entry may point at: the monorepo that holds
# plugins/<name>/ (the renamed marketplace repo). A single configuration value,
# so the gate-2 rehearsal can aim the check at a scratch repository without
# editing the check itself.
MONOREPO_SOURCE_URL="${MONOREPO_SOURCE_URL:-https://github.com/StartupBros-com/hov-stack.git}"
# The shared announce workflow is referenced under either repository name
# during the rename window; GitHub redirects the old one.
ANNOUNCE_WORKFLOW_REPOSITORIES=(StartupBros-com/hov-marketplace StartupBros-com/hov-stack)
# Per-run cache of monorepo main checkouts (one full fetch per distinct remote),
# created on first use and removed at exit.
MONOREPO_CACHE_DIR=""
# Optional exact-pin override. Unset (the norm) means the pin is verified
# STRUCTURALLY: any 40-hex commit of THIS repo that actually carries the
# announce workflow is blessed. A frozen constant was wrong — when the shared
# workflow legitimately advanced (#34), six of eight repos re-pinned to the
# new SHA and the gate rejected the correct state while passing the two
# stragglers. A policy that fails on compliance teaches people to bypass it.
ANNOUNCE_WORKFLOW_PIN="${ANNOUNCE_WORKFLOW_PIN:-}"
# Where to resolve announce-workflow pins. The manifest under validation can
# live anywhere (fixtures use a temp repo), but pins are always commits of the
# marketplace repo this script ships in.
MARKETPLACE_REPO_DIR="${MARKETPLACE_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# A pin is blessed when it is a real commit in the marketplace repo's history
# AND that commit carries the announce workflow. Both halves matter: ancestry
# alone would accept any old commit from before the workflow existed, and file
# presence alone would accept a commit from a fork.
announce_pin_is_blessed() {
  local pin="$1"
  [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || return 1
  git -C "$MARKETPLACE_REPO_DIR" cat-file -e "$pin^{commit}" 2>/dev/null || return 1
  git -C "$MARKETPLACE_REPO_DIR" merge-base --is-ancestor "$pin" HEAD 2>/dev/null || return 1
  git -C "$MARKETPLACE_REPO_DIR" cat-file -e "$pin:.github/workflows/hov-tool-drop-announce.yml" 2>/dev/null
}

# The announce job must call the shared workflow by full path at a pin, under
# either repository name while the rename window is open.
announce_uses_is_shared_workflow() {
  local uses="$1" repository
  for repository in "${ANNOUNCE_WORKFLOW_REPOSITORIES[@]}"; do
    [[ "$uses" == "$repository/.github/workflows/hov-tool-drop-announce.yml@"* ]] && return 0
  done
  return 1
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

is_semver() {
  jq -en --arg value "$1" '$value | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")' >/dev/null
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

semver_gt() {
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"${1%%[-+]*}"
  IFS=. read -r right_major right_minor right_patch <<<"${2%%[-+]*}"
  (( left_major > right_major )) ||
    (( left_major == right_major && left_minor > right_minor )) ||
    (( left_major == right_major && left_minor == right_minor && left_patch > right_patch ))
}

expected_source_url() {
  case "$1" in
    token-eater) printf '%s\n' 'https://github.com/StartupBros-com/token-eater.git' ;;
    pro-gate) printf '%s\n' 'https://github.com/StartupBros-com/pro-gate.git' ;;
    skill-tuner) printf '%s\n' 'https://github.com/StartupBros-com/skill-tuner.git' ;;
    wsl-cdp) printf '%s\n' 'https://github.com/StartupBros-com/wsl-cdp.git' ;;
    memory-dream) printf '%s\n' 'https://github.com/StartupBros-com/memory-dream.git' ;;
    design-rails) printf '%s\n' 'https://github.com/StartupBros-com/design-rails.git' ;;
    harness-vet) printf '%s\n' 'https://github.com/StartupBros-com/harness-vet.git' ;;
    rent-check) printf '%s\n' 'https://github.com/StartupBros-com/rent-check.git' ;;
    papercut) printf '%s\n' 'https://github.com/StartupBros-com/papercut.git' ;;
    product-video) printf '%s\n' 'https://github.com/StartupBros-com/product-video.git' ;;
    sign-it) printf '%s\n' 'https://github.com/StartupBros-com/sign-it.git' ;;
    harness-optimizer) printf '%s\n' 'https://github.com/StartupBros-com/harness-optimizer.git' ;;
    *) return 1 ;;
  esac
}

# Names admitted as git-subdir entries: every plugin with an approved
# repository above, plus the skill pack, which has no repository of its own and
# so is never a url entry. This case list is the only place a name is admitted.
approved_subdir_plugin_name() {
  case "$1" in
    hov-stack) return 0 ;;
    *) expected_source_url "$1" >/dev/null ;;
  esac
}

# Each shape has its own tag rule: a url entry releases v<version> from its
# own repository; a git-subdir entry releases <name>--v<version> from the
# monorepo, where the prefix is what keeps twelve release trains apart.
expected_release_tag() {
  local name="$1" shape="$2" version="$3"
  case "$shape" in
    url) printf 'v%s\n' "$version" ;;
    git-subdir) printf '%s--v%s\n' "$name" "$version" ;;
    *) return 1 ;;
  esac
}

validate_expected_inputs() {
  local value
  for value in "$EXPECTED_PLUGIN_VERSION" "$EXPECTED_RELEASE_ID" "$EXPECTED_RELEASE_TAG" "$EXPECTED_SHA" "$EXPECTED_PAYLOAD_PATHS"; do
    if [[ -n "$value" && -z "$EXPECTED_PLUGIN_NAME" ]]; then
      fail "EXPECTED_PLUGIN_NAME is required with expected plugin or release metadata"
    fi
  done
  [[ -z "$EXPECTED_PLUGIN_VERSION" ]] || is_semver "$EXPECTED_PLUGIN_VERSION" || fail "EXPECTED_PLUGIN_VERSION is not semver"
  [[ -z "$EXPECTED_RELEASE_ID" ]] || is_uint "$EXPECTED_RELEASE_ID" || fail "EXPECTED_RELEASE_ID is not an unsigned integer"
  # The entry's shape is not known yet; either shape's tag form is accepted
  # here, and validate_shape applies the one the entry's shape demands.
  [[ -z "$EXPECTED_RELEASE_TAG" || -z "$EXPECTED_PLUGIN_VERSION" || "$EXPECTED_RELEASE_TAG" == "v$EXPECTED_PLUGIN_VERSION" || "$EXPECTED_RELEASE_TAG" == "$EXPECTED_PLUGIN_NAME--v$EXPECTED_PLUGIN_VERSION" ]] || fail "expected release tag does not match expected plugin version"
  [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "EXPECTED_SHA must be a full lowercase commit SHA"
}

validate_shape() {
  # The name regex below already refuses consecutive hyphens; this names the
  # reason, because "--" is the separator the prefixed tag rule splits on.
  local double_hyphen
  double_hyphen="$(jq -r '[.plugins[]? | .name? | strings | select(contains("--"))] | join(", ")' "$MANIFEST")"
  [[ -z "$double_hyphen" ]] || fail "plugin names must not contain --, the release tag separator: $double_hyphen"

  jq -e '
    type == "object" and
    ([keys[]] - ["name", "owner", "metadata", "plugins"] | length == 0) and
    (.name | type == "string" and length > 0) and
    (.owner | type == "object") and
    (.owner | keys | sort == ["name", "url"]) and
    (.owner.name | type == "string" and length > 0) and
    (.owner.url | type == "string" and test("^https://[^[:space:]]+$")) and
    (.metadata | type == "object") and
    (.metadata | keys | sort == ["description", "version"]) and
    (.metadata.description | type == "string" and length > 0) and
    (.metadata.version | type == "string") and
    (.plugins | type == "array" and length > 0) and
    all(.plugins[];
      type == "object" and
      ([keys[]] - ["name", "source", "description", "metadata", "card"] | length == 0) and
      (.name | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
      (.description | type == "string" and length > 0) and
      (.source | type == "object") and
      (
        ((.source | keys | sort == ["sha", "source", "url"]) and (.source.source == "url")) or
        ((.source | keys | sort == ["path", "sha", "source", "url"]) and (.source.source == "git-subdir") and
          (.source.path | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
          has("metadata"))
      ) and
      (.source.url | type == "string" and test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\.git$")) and
      (.source.sha | type == "string" and test("^[0-9a-f]{40}$")) and
      ((has("metadata") | not) or
        (.metadata | type == "object") and
        ([.metadata | keys[]] - ["version", "releaseId", "releaseTag"] | length == 0) and
        (.metadata.version | type == "string" and (test("[[:cntrl:]]") | not)) and
        (.metadata.releaseId | type == "number" and floor == . and . >= 0) and
        (.metadata.releaseTag | type == "string" and (test("[[:cntrl:]]") | not))) and
      ((has("card") | not) or
        (.card | type == "object") and
        ([.card | keys[]] - ["tagline", "rows", "run"] | length == 0) and
        (.card.rows | type == "array" and length == 3 and all(.[]; type == "string" and length > 0 and length <= 180)) and
        (.card.run | type == "string" and length > 0 and length <= 120) and
        ((.card | has("tagline") | not) or (.card.tagline | type == "string" and length > 0 and length <= 80))))
  ' "$MANIFEST" >/dev/null || fail "marketplace manifest has an invalid shape"

  local marketplace_version
  marketplace_version="$(jq -r '.metadata.version' "$MANIFEST")"
  is_semver "$marketplace_version" || fail "marketplace metadata.version is not semver"

  local duplicates
  duplicates="$(jq -r '[.plugins[].name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$MANIFEST")"
  [[ -z "$duplicates" ]] || fail "plugin names must be unique: $duplicates"

  # Records are joined with the unit separator, which the shape check above
  # keeps out of every field: a tab-separated read would collapse an empty
  # field in the middle of a record (a url entry has no path, an unreleased
  # entry no metadata) and shift the ones after it.
  while IFS=$'\x1f' read -r name shape url version release_id release_tag path; do
    local approved_url
    case "$shape" in
      url)
        approved_url="$(expected_source_url "$name")" || fail "plugin $name is not approved for this marketplace"
        [[ "$url" == "$approved_url" ]] || fail "plugin $name must use approved source $approved_url"
        ;;
      git-subdir)
        approved_subdir_plugin_name "$name" || fail "plugin $name is not approved for this marketplace"
        [[ "$url" == "$MONOREPO_SOURCE_URL" ]] || fail "plugin $name git-subdir entry must use the monorepo source $MONOREPO_SOURCE_URL"
        [[ "$path" == "plugins/$name" ]] || fail "plugin $name git-subdir entry path must be plugins/$name"
        [[ -n "$version" ]] || fail "plugin $name git-subdir entry must carry release metadata"
        [[ -n "$release_tag" ]] || fail "plugin $name git-subdir entry must carry a non-empty release tag"
        ;;
      *) fail "plugin $name has an unknown source shape $shape" ;;
    esac
    [[ -z "$version" ]] && continue
    is_semver "$version" || fail "plugin $name metadata.version is not semver"
    is_uint "$release_id" || fail "plugin $name metadata.releaseId is not an unsigned integer"
    [[ "$release_tag" == "$(expected_release_tag "$name" "$shape" "$version")" ]] || fail "plugin $name metadata.releaseTag does not match metadata.version for a $shape entry"
  done < <(jq -r '.plugins[] | [.name, .source.source, .source.url, (.metadata.version // ""), (.metadata.releaseId // "" | tostring), (.metadata.releaseTag // ""), (.source.path // "")] | join("\u001f")' "$MANIFEST")
}

validate_expected_entry() {
  [[ -n "$EXPECTED_PLUGIN_NAME" ]] || return 0
  local count
  count="$(jq --arg name "$EXPECTED_PLUGIN_NAME" '[.plugins[] | select(.name == $name)] | length' "$MANIFEST")"
  [[ "$count" == 1 ]] || fail "expected plugin $EXPECTED_PLUGIN_NAME is not present exactly once"

  local actual
  if [[ -n "$EXPECTED_PLUGIN_VERSION" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .metadata.version // empty' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_PLUGIN_VERSION" ]] || fail "plugin $EXPECTED_PLUGIN_NAME version mismatch: expected $EXPECTED_PLUGIN_VERSION, got ${actual:-missing}"
  fi
  if [[ -n "$EXPECTED_RELEASE_ID" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .metadata.releaseId // empty' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_RELEASE_ID" ]] || fail "plugin $EXPECTED_PLUGIN_NAME release id mismatch: expected $EXPECTED_RELEASE_ID, got ${actual:-missing}"
  fi
  if [[ -n "$EXPECTED_RELEASE_TAG" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .metadata.releaseTag // empty' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_RELEASE_TAG" ]] || fail "plugin $EXPECTED_PLUGIN_NAME release tag mismatch: expected $EXPECTED_RELEASE_TAG, got ${actual:-missing}"
  fi
  if [[ -n "$EXPECTED_SHA" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .source.sha' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_SHA" ]] || fail "plugin $EXPECTED_PLUGIN_NAME SHA mismatch: expected $EXPECTED_SHA, got $actual"
  fi
}

validate_monotonicity() {
  [[ -n "$BASE_REF" ]] || return 0
  local base_manifest
  base_manifest="$(mktemp)"
  trap 'rm -f "${base_manifest:-}"' RETURN
  git show "$BASE_REF:$MANIFEST" >"$base_manifest" 2>/dev/null || fail "could not read $MANIFEST from BASE_REF $BASE_REF"
  jq -e . "$base_manifest" >/dev/null 2>&1 || fail "base marketplace manifest is malformed"

  # The only shape change an entry may make is url to git-subdir, and only with
  # a new release id (checked with the tuple below). Rollback of a switched
  # entry is roll-forward: a new prefixed release, never a reversion (R50), so
  # git-subdir back to url is refused before any id is compared, whatever the
  # ids. An entry absent at the base is new, not a shape change.
  while IFS=$'\x1f' read -r name base_shape current_shape; do
    [[ -n "$current_shape" ]] || continue
    if [[ "$base_shape" == git-subdir && "$current_shape" == url ]]; then
      fail "plugin $name cannot change shape from git-subdir back to url (rollback is a new prefixed release)"
    fi
  done < <(jq -r --slurpfile current "$MANIFEST" '.plugins[] | .name as $name | [$name, .source.source, (($current[0].plugins[] | select(.name == $name) | .source.source) // "")] | join("\u001f")' "$base_manifest")

  # The tuple an existing release id may never change: version, sha, tag, url,
  # shape and path (empty for a url entry; the unit separator keeps an empty
  # field in place where a tab would collapse it).
  while IFS=$'\x1f' read -r name current_id base_id current_version base_version current_sha base_sha current_tag base_tag current_url base_url current_shape base_shape current_path base_path; do
    [[ -n "$current_id" ]] || fail "plugin $name removed release metadata present at $BASE_REF"
    if ! is_uint "$current_id" || ! is_uint "$base_id"; then
      fail "plugin $name has non-numeric release metadata"
    fi
    (( current_id >= base_id )) || fail "plugin $name releaseId rolled back from $base_id to $current_id"
    if (( current_id == base_id )); then
      [[ "$current_version|$current_sha|$current_tag|$current_url|$current_shape|$current_path" == "$base_version|$base_sha|$base_tag|$base_url|$base_shape|$base_path" ]] || fail "plugin $name changed immutable metadata for releaseId $current_id"
    else
      semver_gt "$current_version" "$base_version" || fail "plugin $name version must increase when releaseId advances"
    fi
  done < <(jq -r --slurpfile current "$MANIFEST" '.plugins[] | select(.metadata.releaseId != null) | .name as $name | ($current[0].plugins[] | select(.name == $name)) as $now | [$name, ($now.metadata.releaseId // "" | tostring), (.metadata.releaseId | tostring), ($now.metadata.version // ""), (.metadata.version // ""), $now.source.sha, .source.sha, ($now.metadata.releaseTag // ""), (.metadata.releaseTag // ""), $now.source.url, .source.url, $now.source.source, .source.source, ($now.source.path // ""), (.source.path // "")] | join("\u001f")' "$base_manifest")

  while IFS=$'\t' read -r name current_id base_id; do
    [[ -n "$base_id" ]] && continue
    is_uint "$current_id" || fail "plugin $name has non-numeric release metadata"
  done < <(jq -r --slurpfile base "$base_manifest" '.plugins[] | select(.metadata.releaseId != null) | .name as $name | [$name, (.metadata.releaseId | tostring), (($base[0].plugins[] | select(.name == $name) | .metadata.releaseId) // "" | tostring)] | @tsv' "$MANIFEST")
  rm -f "$base_manifest"
  trap - RETURN
  base_manifest=""
}

remote_for_url() {
  local url="$1"
  if [[ -z "$MARKETPLACE_TEST_REMOTE_ROOT" ]]; then
    printf '%s\n' "$url"
    return
  fi
  [[ "$ALLOW_LOCAL_FILE_REMOTES" == 1 ]] || fail "MARKETPLACE_TEST_REMOTE_ROOT requires ALLOW_LOCAL_FILE_REMOTES=1"
  local slug="${url#https://github.com/}"
  slug="${slug%.git}"
  local remote="$MARKETPLACE_TEST_REMOTE_ROOT/$slug.git"
  [[ -d "$remote" ]] || remote="$MARKETPLACE_TEST_REMOTE_ROOT/$slug"
  [[ -d "$remote" ]] || fail "local test remote not found for $url"
  printf '%s\n' "$remote"
}

# The announcement contract a release-train workflow must satisfy, whichever
# root it lives at: the plugin repository's (url entries) or the monorepo's
# (git-subdir entries). A failure removes the caller's scratch checkout when it
# names one, then exits.
check_release_train_contract() {
  local name="$1" release_workflow="$2" repo="$3"
  local release_workflow_json announce_uses announce_pin
  release_workflow_json="$(yq -o=json '.' <<<"$release_workflow")" || { discard_checkout "$repo"; fail "plugin $name release train is not valid YAML"; }
  jq -e '.on.release.types | type == "array" and sort == ["edited", "published"]' <<<"$release_workflow_json" >/dev/null || { discard_checkout "$repo"; fail "plugin $name release train must handle published and edited releases"; }
  announce_uses="$(jq -r '.jobs.announce.uses // ""' <<<"$release_workflow_json")"
  announce_pin="${announce_uses##*@}"
  announce_uses_is_shared_workflow "$announce_uses" || { discard_checkout "$repo"; fail "plugin $name announce job does not call the shared hov announce workflow"; }
  if [[ -n "$ANNOUNCE_WORKFLOW_PIN" ]]; then
    [[ "$announce_pin" == "$ANNOUNCE_WORKFLOW_PIN" ]] || { discard_checkout "$repo"; fail "plugin $name pins announce workflow $announce_pin, expected $ANNOUNCE_WORKFLOW_PIN"; }
  else
    announce_pin_is_blessed "$announce_pin" || { discard_checkout "$repo"; fail "plugin $name pins announce workflow $announce_pin, which is not a marketplace commit carrying that workflow (a tag or branch ref is never acceptable)"; }
  fi
  jq -e '((.jobs.announce.permissions // .permissions) | type) == "object" and ((.jobs.announce.permissions // .permissions) == {"contents": "read", "id-token": "write"})' <<<"$release_workflow_json" >/dev/null || { discard_checkout "$repo"; fail "plugin $name announce job must have only contents: read and id-token: write"; }
  ! grep -Fq 'TOOL_RELEASE_ANNOUNCE_SECRET' <<<"$release_workflow" || { discard_checkout "$repo"; fail "plugin $name release train still uses the static announce secret"; }
}

discard_checkout() {
  [[ -z "$1" ]] || rm -rf "$1"
}

# The release tag of an entry must resolve, at the remote, to its pinned
# commit: an annotated tag through its target, a lightweight tag directly.
remote_tag_resolves_to() {
  local remote="$1" tag="$2" sha="$3" resolved
  resolved="$(git ls-remote "$remote" "refs/tags/$tag^{}" | jq -Rrs 'split("\n") | map(select(length > 0) | split("\t")[0]) | first // empty')"
  [[ -n "$resolved" ]] || resolved="$(git ls-remote "$remote" "refs/tags/$tag" | jq -Rrs 'split("\n") | map(select(length > 0) | split("\t")[0]) | first // empty')"
  [[ "$resolved" == "$sha" ]]
}

# A git-subdir entry pins a commit of the monorepo. main is fetched in full,
# once per distinct remote per run, because ancestry cannot be answered by a
# depth-one fetch, and a reachable sha is not a main sha once the repository
# hosts forks' objects.
monorepo_main_checkout() {
  local remote="$1" key dir
  [[ -n "$MONOREPO_CACHE_DIR" ]] || return 1
  key="$(printf '%s' "$remote" | sha256sum | cut -c1-16)"
  dir="$MONOREPO_CACHE_DIR/$key"
  if [[ ! -d "$dir" ]]; then
    git init -q "$dir"
    if ! git -C "$dir" fetch -q --no-write-fetch-head "$remote" "+refs/heads/main:refs/announce/main"; then
      rm -rf "$dir"
      return 1
    fi
  fi
  printf '%s\n' "$dir"
}

# pin_has_pack_skill REPO SHA PATH: true when the pin carries at least one
# PATH/skills/<skill>/SKILL.md directly under skills/.
pin_has_pack_skill() {
  local repo="$1" sha="$2" path="$3" file rest
  while IFS= read -r file; do
    rest="${file#"$path"/skills/}"
    [[ "$rest" == */SKILL.md && "${rest%/SKILL.md}" != */* ]] && return 0
  done < <(git -C "$repo" ls-tree -r --name-only "$sha" -- "$path/skills")
  return 1
}

validate_remote_subdir_plugin() {
  local name="$1" url="$2" sha="$3" metadata_version="$4" metadata_tag="$5" path="$6"
  local remote repo manifest_json manifest_name manifest_version version_file release_workflow
  remote="$(remote_for_url "$url")"
  # The cache directory is created here, in the validator's own shell: a
  # command substitution runs in a subshell and would lose the assignment,
  # leaving nothing for the EXIT trap to remove and nothing to reuse.
  [[ -n "$MONOREPO_CACHE_DIR" ]] || MONOREPO_CACHE_DIR="$(mktemp -d)"
  repo="$(monorepo_main_checkout "$remote")" || fail "plugin $name monorepo main is not reachable from $url"
  # Only main is fetched, so an object missing here was not reachable from
  # main; the merge-base line below answers the same question when the cache
  # holds more than main.
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || fail "plugin $name pinned commit is not reachable from main at $url"
  git -C "$repo" merge-base --is-ancestor "$sha" refs/announce/main 2>/dev/null || fail "plugin $name pinned commit is not an ancestor of main at $url"

  # The plugin's layout lives under its path at the pinned commit.
  manifest_json="$(git -C "$repo" show "$sha:$path/.claude-plugin/plugin.json" 2>/dev/null)" || fail "plugin $name pin has no $path/.claude-plugin/plugin.json"
  jq -e 'type == "object" and (.name | type == "string" and length > 0) and (.version | type == "string" and length > 0)' <<<"$manifest_json" >/dev/null || fail "plugin $name pinned manifest has an invalid shape"
  manifest_name="$(jq -r '.name' <<<"$manifest_json")"
  manifest_version="$(jq -r '.version' <<<"$manifest_json")"
  [[ "$manifest_name" == "$name" ]] || fail "plugin $name pinned manifest name is $manifest_name"
  is_semver "$manifest_version" || fail "plugin $name pinned manifest version is not semver"
  [[ "$manifest_version" == "$metadata_version" ]] || fail "plugin $name marketplace and pinned manifest versions differ"
  if is_skill_pack "$name"; then
    pin_has_pack_skill "$repo" "$sha" "$path" || fail "plugin $name pin has no skill at $path/skills/<skill>/SKILL.md"
  else
    git -C "$repo" cat-file -e "$sha:$path/skills/$name/SKILL.md" 2>/dev/null || fail "plugin $name pin is missing $path/skills/$name/SKILL.md"
  fi

  # Lockstep on main, where the next bump is read: the plugin's VERSION equals
  # its manifest version. The per-repo root requirements (root VERSION, root
  # manifest, root skill directory) do not apply to a monorepo plugin.
  version_file="$(git -C "$repo" show "refs/announce/main:$path/VERSION" 2>/dev/null)" || fail "plugin $name main has no $path/VERSION required by the release train"
  version_file="$(tr -d '[:space:]' <<<"$version_file")"
  is_semver "$version_file" || fail "plugin $name main $path/VERSION is not semver"
  manifest_json="$(git -C "$repo" show "refs/announce/main:$path/.claude-plugin/plugin.json" 2>/dev/null)" || fail "plugin $name main has no $path/.claude-plugin/plugin.json"
  jq -e 'type == "object" and (.version | type == "string" and length > 0)' <<<"$manifest_json" >/dev/null || fail "plugin $name main manifest has an invalid version"
  manifest_version="$(jq -r '.version' <<<"$manifest_json")"
  is_semver "$manifest_version" || fail "plugin $name main manifest version is not semver"
  [[ "$version_file" == "$manifest_version" ]] || fail "plugin $name main $path/VERSION $version_file differs from manifest $manifest_version"

  # The root workflow set is the monorepo's own (U10). When main carries a
  # root release train it must satisfy the announce contract; a monorepo
  # plugin is not required to have one at its root, so absence is not a defect.
  if release_workflow="$(git -C "$repo" show refs/announce/main:.github/workflows/release-train.yml 2>/dev/null)"; then
    check_release_train_contract "$name" "$release_workflow" ""
  fi

  if [[ -n "$metadata_tag" ]]; then
    remote_tag_resolves_to "$remote" "$metadata_tag" "$sha" || fail "plugin $name release tag does not resolve to its pinned commit"
  fi

  if [[ "$name" == "$EXPECTED_PLUGIN_NAME" && -n "$EXPECTED_PAYLOAD_PATHS" ]]; then
    local payload
    IFS=',' read -r -a paths <<<"$EXPECTED_PAYLOAD_PATHS"
    for payload in "${paths[@]}"; do
      [[ -n "$payload" && "$payload" != /* && "$payload" != *..* ]] || fail "invalid expected payload path: $payload"
      git -C "$repo" cat-file -e "$sha:$path/$payload" 2>/dev/null || fail "plugin $name pin is missing expected payload $path/$payload"
    done
  fi
}

validate_remote_plugin() {
  local name="$1" url="$2" sha="$3" metadata_version="$4" metadata_tag="$5" shape="${6:-url}" path="${7:-}"
  if [[ "$shape" == git-subdir ]]; then
    validate_remote_subdir_plugin "$name" "$url" "$sha" "$metadata_version" "$metadata_tag" "$path"
    return
  fi
  local remote repo manifest_json manifest_name manifest_version resolved_tag version_file release_workflow
  remote="$(remote_for_url "$url")"
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  if ! git -C "$repo" fetch -q --depth=1 --no-write-fetch-head "$remote" "$sha"; then
    rm -rf "$repo"
    fail "plugin $name pinned commit is not reachable from $url"
  fi
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || { rm -rf "$repo"; fail "plugin $name pin is not a commit"; }
  git -C "$repo" update-ref refs/announce/pinned "$sha"

  manifest_json="$(git -C "$repo" show refs/announce/pinned:.claude-plugin/plugin.json 2>/dev/null)" || { rm -rf "$repo"; fail "plugin $name pin has no .claude-plugin/plugin.json"; }
  jq -e 'type == "object" and (.name | type == "string" and length > 0) and (.version | type == "string" and length > 0)' <<<"$manifest_json" >/dev/null || { rm -rf "$repo"; fail "plugin $name pinned manifest has an invalid shape"; }
  manifest_name="$(jq -r '.name' <<<"$manifest_json")"
  manifest_version="$(jq -r '.version' <<<"$manifest_json")"
  [[ "$manifest_name" == "$name" ]] || { rm -rf "$repo"; fail "plugin $name pinned manifest name is $manifest_name"; }
  is_semver "$manifest_version" || { rm -rf "$repo"; fail "plugin $name pinned manifest version is not semver"; }
  [[ -z "$metadata_version" || "$manifest_version" == "$metadata_version" ]] || { rm -rf "$repo"; fail "plugin $name marketplace and pinned manifest versions differ"; }
  git -C "$repo" cat-file -e "refs/announce/pinned:skills/$name/SKILL.md" 2>/dev/null || { rm -rf "$repo"; fail "plugin $name pin is missing skills/$name/SKILL.md"; }

  # Announcement contract is checked on the CURRENT DEFAULT BRANCH — the tree
  # the next tag will inherit. Historical release pins may legitimately predate
  # the policy (wsl-cdp v0.3.4 did); invalidating those would break installs
  # without improving the next release. A post-release failure is too late and
  # too quiet: design-rails lost twelve announcements to a missing VERSION.
  if ! git -C "$repo" fetch -q --depth=1 --no-write-fetch-head "$remote" HEAD:refs/announce/default; then
    rm -rf "$repo"
    fail "plugin $name default branch is not reachable from $url"
  fi
  version_file="$(git -C "$repo" show refs/announce/default:VERSION 2>/dev/null)" || { rm -rf "$repo"; fail "plugin $name default branch has no root VERSION required by the announce train"; }
  version_file="$(tr -d '[:space:]' <<<"$version_file")"
  is_semver "$version_file" || { rm -rf "$repo"; fail "plugin $name default-branch VERSION is not semver"; }
  manifest_json="$(git -C "$repo" show refs/announce/default:.claude-plugin/plugin.json 2>/dev/null)" || { rm -rf "$repo"; fail "plugin $name default branch has no plugin manifest"; }
  jq -e 'type == "object" and (.version | type == "string" and length > 0)' <<<"$manifest_json" >/dev/null || { rm -rf "$repo"; fail "plugin $name default-branch manifest has an invalid version"; }
  manifest_version="$(jq -r '.version' <<<"$manifest_json")"
  is_semver "$manifest_version" || { rm -rf "$repo"; fail "plugin $name default-branch manifest version is not semver"; }
  [[ "$version_file" == "$manifest_version" ]] || { rm -rf "$repo"; fail "plugin $name default-branch VERSION $version_file differs from manifest $manifest_version"; }
  release_workflow="$(git -C "$repo" show refs/announce/default:.github/workflows/release-train.yml 2>/dev/null)" || { rm -rf "$repo"; fail "plugin $name default branch has no release-train.yml"; }
  check_release_train_contract "$name" "$release_workflow" "$repo"

  if [[ -n "$metadata_tag" ]]; then
    resolved_tag="$(git ls-remote "$remote" "refs/tags/$metadata_tag^{}" | jq -Rrs 'split("\n") | map(select(length > 0) | split("\t")[0]) | first // empty')"
    [[ -n "$resolved_tag" ]] || resolved_tag="$(git ls-remote "$remote" "refs/tags/$metadata_tag" | jq -Rrs 'split("\n") | map(select(length > 0) | split("\t")[0]) | first // empty')"
    [[ "$resolved_tag" == "$sha" ]] || { rm -rf "$repo"; fail "plugin $name release tag does not resolve to its pinned commit"; }
  fi

  if [[ "$name" == "$EXPECTED_PLUGIN_NAME" && -n "$EXPECTED_PAYLOAD_PATHS" ]]; then
    local path
    IFS=',' read -r -a paths <<<"$EXPECTED_PAYLOAD_PATHS"
    for path in "${paths[@]}"; do
      [[ -n "$path" && "$path" != /* && "$path" != *..* ]] || { rm -rf "$repo"; fail "invalid expected payload path: $path"; }
      git -C "$repo" cat-file -e "refs/announce/pinned:$path" 2>/dev/null || { rm -rf "$repo"; fail "plugin $name pin is missing expected payload $path"; }
    done
  fi
  rm -rf "$repo"
}

validate_full() {
  while IFS=$'\x1f' read -r name url sha shape version tag path; do
    validate_remote_plugin "$name" "$url" "$sha" "$version" "$tag" "$shape" "$path"
  done < <(jq -r '.plugins[] | [.name, .source.url, .source.sha, .source.source, (.metadata.version // ""), (.metadata.releaseTag // ""), (.source.path // "")] | join("\u001f")' "$MANIFEST")
}

discard_monorepo_cache() {
  [[ -z "$MONOREPO_CACHE_DIR" ]] || rm -rf "$MONOREPO_CACHE_DIR"
}
trap discard_monorepo_cache EXIT

[[ "$MODE" == syntax || "$MODE" == full ]] || fail "usage: $0 [syntax|full]"
require_command jq
require_command yq
require_command git
[[ -f "$MANIFEST" ]] || fail "marketplace manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || fail "marketplace manifest is malformed JSON"
validate_expected_inputs
validate_shape
validate_expected_entry
validate_monotonicity
[[ "$MODE" == syntax ]] || validate_full
printf 'marketplace validation passed (%s)\n' "$MODE"
