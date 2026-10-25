#!/usr/bin/env bash
set -euo pipefail

# Generalized announce-only Tool Drop train, called by the reusable workflow
# .github/workflows/hov-tool-drop-announce.yml for EVERY catalog plugin and for
# each product listed in PRODUCTS below.
#
# The marketplace manifest in this repo is the single source of truth: a
# release announces only when the manifest already lists this exact release
# tuple AND carries a card block for the plugin. This script never writes to
# the marketplace (repins are merged PRs) and holds no deploy key.
#
# Auth: a GitHub Actions OIDC token (Authorization: Bearer) minted only after
# every preflight passes. Its audience binds the token to the SHA-256 digest of
# the exact request bytes sent to the one fixed Tool Drop endpoint.
#
# Soft exits (loud in the run UI, green in the checks list): marketplace not
# yet repinned to this release, or no card block registered — both resolve
# with a marketplace PR, then editing the release re-fires the announce.
#
# Products differ from plugins. A product (HoV Router) is software released from
# its own repository that is not a marketplace plugin: it has no VERSION file,
# no .claude-plugin/plugin.json, no marketplace manifest entry and no card in
# the manifest (the announce service's own product registry holds its card). It is recognised
# by the caller's full repository name AND repository id in PRODUCTS, never by
# the bare repository name. For a product release this helper keeps the
# argument and environment checks, the draft/prerelease skip, the published or
# edited action check and the latest-stable guard, then requires a plain
# v<major.minor.patch> tag, takes the announced name from the table, skips
# verify_release and both marketplace checks, and announces exactly as a plugin
# does. Every plugin release behaves as before. The announce service re-verifies every token
# claim and the live release itself; the table only decides which local checks
# apply.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

readonly TOOL_RELEASES_ENDPOINT='https://members.startupbros.com/api/internal/ops/tool-releases'
# Six current caller repositories, one inherited same-release lease, and one
# spare bounded window can all clear without turning a transient queue into loss.
readonly ANNOUNCE_MAX_ATTEMPTS=8
readonly RETRY_LEASE_EXPIRY_CUSHION_SECONDS=2
readonly RETRY_JITTER_MAX_SECONDS=3
readonly RESPONSE_CONTEXT_MAX_BYTES=2048
# The ONE retryable 403. main() reaches announce() only after marketplace_lists_release()
# has matched the manifest on all five identity fields (name, source.sha, metadata.version,
# metadata.releaseId, metadata.releaseTag), so this rejection means the client proved the card
# names this exact release and the service's own view had not caught up yet. That is a
# propagation lag, not an authorization refusal. Matching the exact message keeps every other
# 403 -- a bad audience, a revoked app, a genuinely absent promotion -- terminal on attempt one,
# and a reworded server message falls back to that terminal path rather than looping.
readonly PROMOTION_LAG_ERROR='release does not match the marketplace promotion'
# No Retry-After accompanies this one, so the wait is ours to choose. Two observations on
# 2026-09-09 (pro-gate): a 61s repin-to-POST gap failed, a 77s gap succeeded, and a re-run
# ~100 minutes later succeeded. 30s across the existing 8-attempt budget covers ~3.5 minutes,
# which brackets both samples. If the real mechanism turns out to be a longer cache TTL, raise
# THIS rather than the attempt count -- the attempt budget is shared with the 409/429 lease path.
readonly PROMOTION_LAG_RETRY_SECONDS=30

# Products that may call the workflow, one row each: "<owner/name> <repository id>
# <product name>". This script runs from the trusted workflow SHA, so a new row
# is reviewed code. The product name is what the request body announces; the announce service
# independently verifies the repository, owner, repository id, workflow ref and
# lineage claims of the OIDC token and the live GitHub release, so a wrong row
# cannot make the announce service accept a repository it does not know.
readonly PRODUCTS=(
  'StartupBros/hov-router 1278801682 hov-router'
)
# A product releases on plain v<major.minor.patch> tags with canonical numbers,
# the same rule latest-stable-release.sh applies to a repository-family tag.
readonly PRODUCT_TAG_SHAPE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

ANNOUNCE_RESPONSE_DIR=''

cleanup_response_dir() {
  local -r response_dir="${ANNOUNCE_RESPONSE_DIR:-}"
  [[ -n "$response_dir" ]] || return 0
  rm -f -- "$response_dir/response-body" "$response_dir/response-headers"
  rmdir -- "$response_dir"
  ANNOUNCE_RESPONSE_DIR=''
}

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

is_positive_uint() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

load_current_release() {
  require CURRENT_RELEASE_FILE
  local current_release

  if ! current_release="$(jq -ces \
    --arg expected_id "$RELEASE_ID" \
    --arg expected_tag "$RELEASE_TAG" \
    '
      if length == 1 and
        (.[0] |
          type == "object" and
          has("id") and
          (.id | type == "number") and
          (.id > 0) and
          (.id == (.id | floor)) and
          ((.id | tostring) == $expected_id) and
          has("tag_name") and
          (.tag_name | type == "string") and
          (.tag_name | length > 0) and
          (.tag_name == $expected_tag) and
          has("body") and
          (.body == null or (.body | type == "string")) and
          has("draft") and
          (.draft | type == "boolean") and
          has("prerelease") and
          (.prerelease | type == "boolean"))
      then .[0]
      else error("current release record failed validation")
      end
    ' -- "$CURRENT_RELEASE_FILE")"; then
    fail "current release record is invalid or does not match expected identity"
  fi

  CURRENT_RELEASE_NOTES="$(jq -jr 'if .body == null then "" else .body end' <<<"$current_release")"
  CURRENT_RELEASE_DRAFT="$(jq -r '.draft' <<<"$current_release")"
  CURRENT_RELEASE_PRERELEASE="$(jq -r '.prerelease' <<<"$current_release")"
  readonly CURRENT_RELEASE_NOTES CURRENT_RELEASE_DRAFT CURRENT_RELEASE_PRERELEASE
}

notes_summary() {
  # Card-ready release bullets. Preference order: author-written "## Highlights"
  # section; GitHub's auto "What's Changed" bullets, cleaned; first paragraph.
  # Up to 3 bullets, each <=180 chars, total <=600.
  local notes bullets
  notes="$(printf '%s' "${CURRENT_RELEASE_NOTES:-}" | tr -d '\r')"
  [[ -n "$notes" ]] || return 0
  bullets="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -E '^[*•-][[:space:]]' || true)"
  if [[ -z "$bullets" ]]; then
    if grep -qE '^##[[:space:]]*What.?.?s Changed' <<<"$notes"; then
      bullets="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*What.\{0,2\}s Changed/,/^## /p' | grep -E '^\*[[:space:]]' || true)"
    elif [[ "$(awk 'NF { print; exit }' <<<"$notes")" == \** ]]; then
      bullets="$(awk '/^[[:space:]]*$/{exit} /^\*[[:space:]]/{print}' <<<"$notes")"
    fi
  fi
  if [[ -n "$bullets" ]]; then
    # Character-safe slicing: cut -c is BYTES under GNU coreutils and can split
    # multibyte characters; python3 is guaranteed on the Actions runner.
    printf '%s\n' "$bullets" \
      | sed -E 's/^[*•-][[:space:]]+//; s/[[:space:]]+by @[A-Za-z0-9_[:punct:]]+ in http[^[:space:]]*[[:space:]]*$//; s/^(feat|fix|perf|chore|docs|refactor|test|ci|build)(\([^)]*\))?!?:[[:space:]]*//; s/[[:space:]]*\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$//' \
      | python3 -c 'import sys

def utf16_prefix(value, limit):
    used = 0
    out = []
    for char in value:
        width = 2 if ord(char) > 0xFFFF else 1
        if used + width > limit:
            break
        out.append(char)
        used += width
    return "".join(out)

out = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if line:
        out.append(utf16_prefix(line, 180))
    if len(out) == 3:
        break
print(utf16_prefix("\n".join(out), 600))'
    return 0
  fi
  # Prose fallback: the drop card gets an excerpt instead of a what's-new list.
  # Warn loudly so a degraded card is visible in the release run.
  printf '::warning title=No release highlights::%s %s has no "## Highlights" bullets; the drop card falls back to a prose excerpt. See docs/release/plugin-release-recipe.md.\n' \
    "${REPOSITORY:-plugin}" "${RELEASE_TAG:-release}" >&2
  printf '%s' "$notes" \
    | awk 'BEGIN{RS=""} NR==1' \
    | tr '\n' ' ' \
    | python3 -c 'import sys
value = sys.stdin.read()
used = 0
out = []
for char in value:
    width = 2 if ord(char) > 0xFFFF else 1
    if used + width > 600:
        break
    out.append(char)
    used += width
print("".join(out), end="")'
}

sha256_bytes() {
  local digest
  digest="$(printf '%s' "$1" | sha256sum)"
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute request body SHA-256"
  printf '%s\n' "$digest"
}

retry_jitter_seconds() {
  local -r jitter_repository="$1" jitter_release_id="$2" jitter_attempt="$3"
  local digest
  digest="$(sha256_bytes "$jitter_repository:$jitter_release_id:$jitter_attempt")"
  printf '%d\n' "$((16#${digest:0:8} % (RETRY_JITTER_MAX_SECONDS + 1)))"
}

mint_oidc_token() {
  local -r audience="$1"
  require ACTIONS_ID_TOKEN_REQUEST_URL
  require ACTIONS_ID_TOKEN_REQUEST_TOKEN
  curl --disable --fail-with-body --silent --show-error --get \
    -H "authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    --data-urlencode "audience=$audience" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL" \
    | jq -er '.value | select(type == "string" and length > 0)'
}

report_response_context() {
  local -r message="$1" response_body="$2"
  local body_size
  printf 'error: %s\n' "$message" >&2
  if [[ ! -s "$response_body" ]]; then
    printf 'response body: <empty>\n' >&2
    return
  fi

  body_size="$(wc -c <"$response_body")"
  body_size="${body_size//[[:space:]]/}"
  printf 'response body (first %d bytes):\n' "$RESPONSE_CONTEXT_MAX_BYTES" >&2
  head -c "$RESPONSE_CONTEXT_MAX_BYTES" "$response_body" >&2
  if ((body_size > RESPONSE_CONTEXT_MAX_BYTES)); then
    printf '\n... response body truncated ...\n' >&2
  else
    printf '\n' >&2
  fi
}

retry_after_seconds() {
  local -r response_headers="$1" expected_status="$2"
  local line value final_status='' in_header_block=false saw_folded_line=false
  local -a values=()

  [[ "$expected_status" == 409 || "$expected_status" == 429 ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^HTTP/[0-9]+(\.[0-9]+)?[[:blank:]]+([0-9][0-9][0-9])([[:blank:]].*)?$ ]]; then
      final_status="${BASH_REMATCH[2]}"
      values=()
      in_header_block=true
      saw_folded_line=false
      continue
    fi
    if [[ -z "$line" ]]; then
      in_header_block=false
      continue
    fi
    if [[ "$in_header_block" == true && "$line" == [[:blank:]]* ]]; then
      saw_folded_line=true
      continue
    fi
    if [[ "$in_header_block" == true && "${line,,}" == retry-after:* ]]; then
      value="${line#*:}"
      value="${value#"${value%%[![:blank:]]*}"}"
      value="${value%"${value##*[![:blank:]]}"}"
      values+=("$value")
    fi
  done <"$response_headers"

  [[ "$final_status" == "$expected_status" ]] || return 1
  [[ "$saw_folded_line" == false ]] || return 1
  [[ ${#values[@]} -eq 1 ]] || return 1
  [[ "${values[0]}" =~ ^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$ ]] || return 1
  printf '%s\n' "${values[0]}"
}

send_request() {
  local -r request_body="$1" expected_sha="$2" oidc_token="$3"
  local -r response_body="$4" response_headers="$5" http_status_name="$6"
  local actual_sha curl_http_code curl_exit=0

  : >"$response_body"
  : >"$response_headers"
  actual_sha="$(sha256_bytes "$request_body")"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "request body changed after OIDC mint"

  curl_http_code="$(curl --disable --silent --show-error \
    --request POST \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $oidc_token" \
    --data-binary "$request_body" \
    --output "$response_body" \
    --dump-header "$response_headers" \
    --write-out '%{http_code}' \
    "$TOOL_RELEASES_ENDPOINT")" || curl_exit=$?
  printf -v "$http_status_name" '%s' "$curl_http_code"

  if ((curl_exit != 0)); then
    report_response_context "Tool Drop POST transport failure (curl exit $curl_exit)" "$response_body"
    return 1
  fi
  if [[ ! "$curl_http_code" =~ ^[0-9][0-9][0-9]$ ]]; then
    report_response_context "Tool Drop POST returned an invalid HTTP status" "$response_body"
    return 1
  fi
}

# 0 only when this response is the promotion-propagation 403. A non-JSON, empty, or
# differently-shaped body makes jq exit non-zero, which reads as "not retryable" -- the
# failure direction that keeps an unrecognized 403 terminal.
promotion_lag_403() { # <http-status> <response-body-file>
  [[ "$1" == 403 ]] || return 1
  jq -e --arg m "$PROMOTION_LAG_ERROR" \
    'if type == "object" then (.error? == $m) else false end' "$2" >/dev/null 2>&1
}

announce() {
  local notes request_body request_sha audience oidc_token
  local response_body response_headers http_status retry_after retry_delay retry_jitter
  local promotion_lag
  local attempt result=1
  notes="$(notes_summary)"
  request_body="$(jq -cn \
    --arg operation announce \
    --arg repository "$PLUGIN_NAME" \
    --arg releaseId "$RELEASE_ID" \
    --arg notesSummary "$notes" \
    '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)')"
  readonly request_body
  request_sha="$(sha256_bytes "$request_body")"
  audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"
  readonly request_sha audience

  ANNOUNCE_RESPONSE_DIR="$(mktemp -d)" || fail "could not create response capture directory"
  response_body="$ANNOUNCE_RESPONSE_DIR/response-body"
  response_headers="$ANNOUNCE_RESPONSE_DIR/response-headers"
  trap cleanup_response_dir EXIT

  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do
    http_status=''
    if ! oidc_token="$(mint_oidc_token "$audience")"; then
      fail "could not mint OIDC token"
    fi
    printf '::add-mask::%s\n' "$oidc_token"
    if ! send_request "$request_body" "$request_sha" "$oidc_token" \
      "$response_body" "$response_headers" http_status; then
      break
    fi

    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
      command cat "$response_body"
      result=0
      break
    fi
    promotion_lag=false
    if promotion_lag_403 "$http_status" "$response_body"; then promotion_lag=true; fi
    if [[ "$http_status" != 409 && "$http_status" != 429 && "$promotion_lag" == false ]]; then
      report_response_context "Tool Drop POST failed with HTTP $http_status" "$response_body"
      break
    fi
    if [[ "$promotion_lag" == true ]]; then
      retry_after="$PROMOTION_LAG_RETRY_SECONDS"
    elif ! retry_after="$(retry_after_seconds "$response_headers" "$http_status")"; then
      report_response_context "HTTP $http_status lacked one canonical Retry-After value from 1 through 600" "$response_body"
      break
    fi
    if ((attempt == ANNOUNCE_MAX_ATTEMPTS)); then
      report_response_context "Tool Drop POST exhausted $ANNOUNCE_MAX_ATTEMPTS attempts (last HTTP $http_status)" "$response_body"
      break
    fi

    retry_jitter="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" "$attempt")"
    retry_delay=$((10#$retry_after + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + retry_jitter))
    sleep "$retry_delay"
  done

  cleanup_response_dir
  trap - EXIT
  return "$result"
}

# Derive the plugin identity from the release tag, once, before the release is
# verified. A tag carrying "--v" is a monorepo release: the text before its LAST
# "--v" is the plugin name and the plugin lives under plugins/<name>/. A plain
# v<version> tag is a per-plugin repository: the plugin is the repository and
# lives at the source root. The request body's repository field carries the
# plugin name, because the announce endpoint looks the marketplace entry up by
# that name; REPOSITORY stays the GitHub repository name for the workflow's
# concurrency group and the retry jitter seed. Splitting with "%--v*" (shortest
# suffix removal) lands on the last separator by definition, so a prefix that
# still contains "--" is a name the marketplace refuses, not a second split.
# The text after that separator must start with a digit, so a tag such as
# foo--vbar is refused here with the rule named, not by a later mismatch.
derive_plugin_identity() {
  require REPOSITORY
  require RELEASE_TAG
  if [[ "$RELEASE_TAG" == *--v* ]]; then
    PLUGIN_NAME="${RELEASE_TAG%--v*}"
    [[ "$PLUGIN_NAME" != *--* ]] || fail "plugin name derived from release tag $RELEASE_TAG contains --, the release tag separator: $PLUGIN_NAME"
    [[ "$PLUGIN_NAME" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "plugin name derived from release tag $RELEASE_TAG has an invalid shape: $PLUGIN_NAME"
    [[ "${RELEASE_TAG##*--v}" == [0-9]* ]] || fail "release tag $RELEASE_TAG has no version after its last --v"
    PLUGIN_DIR="plugins/$PLUGIN_NAME"
    TAG_PREFIX="$PLUGIN_NAME--"
  else
    PLUGIN_NAME="$REPOSITORY"
    PLUGIN_DIR=''
    TAG_PREFIX=''
  fi
}

# Decide whether the caller is a listed product. The caller's identity is the
# default Actions variables GITHUB_REPOSITORY (owner/name) and
# GITHUB_REPOSITORY_ID, never REPOSITORY, the bare name any repository can share.
# GITHUB_REPOSITORY_ID is consulted only once the full name matches a row, so a
# caller that is not a listed product never needs it. A matching full name with
# a different id is a deleted-and-recreated or transferred repository: refused,
# never announced. Returns 0 with PRODUCT_NAME set for a product, 1 otherwise.
resolve_product() {
  local row full_name product_id product_name
  PRODUCT_NAME=''
  for row in "${PRODUCTS[@]}"; do
    read -r full_name product_id product_name <<<"$row"
    [[ "${GITHUB_REPOSITORY:-}" == "$full_name" ]] || continue
    if [[ "${GITHUB_REPOSITORY_ID:-}" != "$product_id" ]]; then
      printf '::error title=Product repository mismatch::%s has repository id %s, not the registered %s; refusing to announce.\n' \
        "$full_name" "${GITHUB_REPOSITORY_ID:-<unset>}" "$product_id"
      exit 1
    fi
    PRODUCT_NAME="$product_name"
    return 0
  done
  return 1
}

require_product_release_tag() {
  [[ "$RELEASE_TAG" =~ $PRODUCT_TAG_SHAPE ]] || fail "product release tag $RELEASE_TAG is not a plain v<major.minor.patch> tag"
}

verify_release() {
  require SOURCE_ROOT
  require SOURCE_SHA
  require PLUGIN_NAME
  local plugin_root version manifest_version expected_tag
  plugin_root="$SOURCE_ROOT${PLUGIN_DIR:+/$PLUGIN_DIR}"
  [[ -f "$plugin_root/VERSION" ]] || fail "no VERSION file at $plugin_root for release tag $RELEASE_TAG"
  [[ -f "$plugin_root/.claude-plugin/plugin.json" ]] || fail "no plugin manifest at $plugin_root for release tag $RELEASE_TAG"
  version="$(tr -d '[:space:]' < "$plugin_root/VERSION")"
  manifest_version="$(jq -er '.version' "$plugin_root/.claude-plugin/plugin.json")"
  expected_tag="${TAG_PREFIX}v$version"
  [[ "$RELEASE_TAG" == "$expected_tag" ]] || fail "release tag $RELEASE_TAG does not match VERSION $version"
  [[ "$manifest_version" == "$version" ]] || fail "plugin manifest version $manifest_version does not match VERSION $version"
  [[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$SOURCE_SHA" ]] || fail "checked-out source does not match release commit"
  [[ "$(git -C "$SOURCE_ROOT" rev-list -n 1 "refs/tags/$RELEASE_TAG")" == "$SOURCE_SHA" ]] || fail "release tag does not resolve to the exact release commit"
  printf '%s\n' "$version"
}

marketplace_lists_release() {
  require MARKETPLACE_MANIFEST
  jq -e \
    --arg name "$PLUGIN_NAME" \
    --arg sha "$SOURCE_SHA" \
    --arg version "$RELEASE_VERSION" \
    --argjson release_id "$RELEASE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    'any(.plugins[]; .name == $name and .source.sha == $sha and .metadata.version == $version and .metadata.releaseId == $release_id and .metadata.releaseTag == $release_tag)' \
    "$MARKETPLACE_MANIFEST" >/dev/null
}

marketplace_has_card() {
  jq -e \
    --arg name "$PLUGIN_NAME" \
    --arg sha "$SOURCE_SHA" \
    --arg version "$RELEASE_VERSION" \
    --argjson release_id "$RELEASE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    'any(.plugins[]; .name == $name and .source.sha == $sha and .metadata.version == $version and .metadata.releaseId == $release_id and .metadata.releaseTag == $release_tag and (.card | type == "object"))' \
    "$MARKETPLACE_MANIFEST" >/dev/null
}

# Report a release that finished WITHOUT posting a drop card. Deliberately
# louder than the ::notice:: this replaced: a silent skip on a green run is the
# failure mode the release recipe currently works around by telling readers to
# grep the log. Emits an error annotation, a step-summary line, and a stable
# machine-readable marker so callers can assert on it.
report_not_announced() {
  local reason="$1" message="$2"
  printf '::error title=Not announced::%s\n' "$message"
  printf 'hov-drop-announce: status=not-announced reason=%s repository=%s tag=%s plugin=%s\n' \
    "$reason" "${REPOSITORY:-?}" "${RELEASE_TAG:-?}" "${PLUGIN_NAME:-?}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### Not announced (%s)\n\n' "$reason"
      printf '%s\n' "$message"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

main() {
  [[ $# -eq 0 ]] || fail "this helper accepts no arguments"
  require EVENT_ACTION
  require REPOSITORY
  require RELEASE_ID
  require RELEASE_TAG
  is_positive_uint "$RELEASE_ID" || fail "RELEASE_ID must be a positive canonical decimal integer"
  [[ "$REPOSITORY" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "REPOSITORY has an invalid shape"

  require CURRENT_RELEASE_FILE
  load_current_release
  if [[ "$CURRENT_RELEASE_PRERELEASE" == true || "$CURRENT_RELEASE_DRAFT" == true ]]; then
    printf 'prerelease or draft release ignored\n'
    return
  fi
  [[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"

  require LATEST_STABLE_ID
  is_positive_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be a positive canonical decimal integer"
  if [[ "$RELEASE_ID" != "$LATEST_STABLE_ID" ]]; then
    printf 'release %s is not latest stable %s; no-op\n' "$RELEASE_ID" "$LATEST_STABLE_ID"
    return
  fi

  # A listed product announces without plugin verification or marketplace
  # entry. The check sits after every no-op, and before the plugin path, which
  # stays exactly as it was.
  if resolve_product; then
    require_product_release_tag
    PLUGIN_NAME="$PRODUCT_NAME"
    announce
    return
  fi

  derive_plugin_identity
  RELEASE_VERSION="$(verify_release)"

  if ! marketplace_lists_release; then
    # NOT a notice. A skipped announce leaves the job green, which is
    # indistinguishable from a successful post — that is why the release recipe
    # has to tell readers to grep the run log instead of trusting the run's
    # conclusion. An ::error:: annotation makes the run visibly not-announced
    # while still returning 0, because plugins that publish BEFORE repinning
    # legitimately reach this state on every release; failing here would turn
    # their normal flow red. Once every plugin stages draft-first (so the card
    # is always current at publish), this should become a hard failure.
    report_not_announced 'not-listed' \
      "hov-marketplace does not yet list $PLUGIN_NAME $RELEASE_TAG at $SOURCE_SHA. Merge the repin PR, then edit the release to re-fire the announce."
    return
  fi

  if ! marketplace_has_card; then
    report_not_announced 'no-card' \
      "$PLUGIN_NAME has no card block in hov-marketplace. Add one (card: {rows, run}) in a marketplace PR, then edit the release to re-fire."
    return
  fi

  announce
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
