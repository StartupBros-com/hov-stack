#!/usr/bin/env bash
# Static mutation needles quote shell/Actions expressions, and the fake HTTP
# plan is intentionally addressed through dynamically named variables.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/hov-tool-drop-announce.yml"
HELPER="$ROOT/release/scripts/tool-drop-announce.sh"
GUARD="$ROOT/release/scripts/latest-stable-release.sh"
FIXED_ENDPOINT='https://members.startupbros.com/api/internal/ops/tool-releases'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass_count=0

die() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
  pass_count=$((pass_count + 1))
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in git jq python3 sha256sum yq; do
  require_command "$command_name"
done

check_contract() {
  local workflow="$1" helper="$2" guard="${3:-$GUARD}"
  local input_count secret_count fixed_count disable_count
  local current_index release_index ancestry_index trusted_index manifest_index stable_index announce_index
  local release_ref trusted_repository trusted_ref trusted_path trusted_credentials
  local manifest_repository manifest_ref manifest_path manifest_credentials
  local current_run stable_run expected_stable ancestry_run expected_ancestry announce_run expected_announce manifest_env
  local current_env_count stable_env_count announce_env_count current_release_file step_count gated_step_count
  local concurrency_group concurrency_cancel concurrency_cancel_tag
  local send_block announce_block header_count mask_line send_line utf16_width_count
  local retry_loop_line mint_line retry_loop_end_line

  input_count="$(yq -r '.on.workflow_call.inputs // {} | length' "$workflow")" || return 1
  secret_count="$(yq -r '.on.workflow_call.secrets // {} | length' "$workflow")" || return 1
  [[ "$input_count" == 1 && "$secret_count" == 0 ]] || return 1
  # The one input names the manifest repository. An old-shape caller passes
  # nothing and the manifest checkout falls back to the workflow's home
  # repository; that fallback is a static pin on the expression below, which
  # GitHub evaluates, not this test.
  [[ "$(yq -r '.on.workflow_call.inputs | keys | .[0]' "$workflow")" == marketplace-repository ]] || return 1
  [[ "$(yq -r '.on.workflow_call.inputs."marketplace-repository".type' "$workflow")" == string ]] || return 1
  [[ "$(yq -r '.on.workflow_call.inputs."marketplace-repository".required' "$workflow")" == false ]] || return 1
  [[ "$(yq -r '.on.workflow_call.inputs."marketplace-repository" | has("default")' "$workflow")" == false ]] || return 1
  ! grep -Fq 'StartupBros-com/' "$workflow" || return 1
  # Latest is judged per tag family by the trusted guard, never by the
  # repository-wide latest release, anywhere in the workflow or the guard.
  ! grep -Fq 'releases/latest' "$workflow" "$guard" || return 1
  grep -Fq -- 'gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100"' "$guard" || return 1
  grep -Fq 'sort_by(.version)' "$guard" || return 1
  ! grep -Eq 'sort_by\(\.(created_at|published_at)\)|fromdateiso8601' "$guard" || return 1
  grep -Fq 'hov-drop-announce: status=not-announced reason=not-latest repository=%s tag=%s plugin=%s' "$guard" || return 1
  ! grep -Eq 'announce-url|x-tool-release-announce-secret' "$workflow" "$helper" || return 1
  ! grep -Fq 'ANNOUNCE_URL' "$workflow" || return 1
  ! grep -Fq 'ANNOUNCE_SECRET' "$workflow" || return 1
  ! grep -Fq 'OIDC_TOKEN' "$workflow" || return 1
  ! grep -Eq '\b(LEGACY_MODE|LEGACY_OIDC_AUDIENCE|ANNOUNCE_URL|ANNOUNCE_SECRET|OIDC_TOKEN|RELEASE_NAME|RELEASE_URL|RELEASE_NOTES|RELEASE_PRERELEASE|RELEASE_DRAFT)\b' "$helper" || return 1
  ! grep -Fq 'https://github.com/StartupBros-com' "$helper" || return 1
  [[ "$(yq -r 'has("concurrency")' "$workflow")" == false ]] || return 1

  concurrency_group="$(yq -r '.jobs.announce.concurrency.group' "$workflow")" || return 1
  concurrency_cancel="$(yq -r '.jobs.announce.concurrency.cancel-in-progress' "$workflow")" || return 1
  concurrency_cancel_tag="$(yq -r '.jobs.announce.concurrency.cancel-in-progress | tag' "$workflow")" || return 1
  [[ "$concurrency_group" == 'hov-tool-drop-announce-${{ github.repository }}-${{ github.event.release.id }}' ]] || return 1
  [[ "$concurrency_cancel" == true && "$concurrency_cancel_tag" == '!!bool' ]] || return 1
  [[ "$(yq -r '.jobs.announce | has("if")' "$workflow")" == false ]] || return 1

  fixed_count="$({ grep -Fo "$FIXED_ENDPOINT" "$helper" || true; } | wc -l)"
  [[ "$fixed_count" == 1 ]] || return 1
  grep -Fxq "readonly TOOL_RELEASES_ENDPOINT='$FIXED_ENDPOINT'" "$helper" || return 1
  ! grep -Fq "$FIXED_ENDPOINT" "$workflow" || return 1

  current_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Resolve current release eligibility") | .key' "$workflow")" || return 1
  release_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out release commit") | .key' "$workflow")" || return 1
  ancestry_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Require release commit on default branch") | .key' "$workflow")" || return 1
  trusted_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out trusted workflow helper") | .key' "$workflow")" || return 1
  manifest_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out current marketplace manifest") | .key' "$workflow")" || return 1
  stable_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Resolve latest stable release") | .key' "$workflow")" || return 1
  announce_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Announce release") | .key' "$workflow")" || return 1
  [[ "$current_index" == 0 && "$release_index" =~ ^[0-9]+$ && "$ancestry_index" =~ ^[0-9]+$ && "$trusted_index" =~ ^[0-9]+$ && "$manifest_index" =~ ^[0-9]+$ && "$stable_index" =~ ^[0-9]+$ && "$announce_index" =~ ^[0-9]+$ ]] || return 1
  ((current_index < release_index && release_index + 1 == ancestry_index && ancestry_index < trusted_index && trusted_index < manifest_index && manifest_index < stable_index && stable_index < announce_index)) || return 1

  step_count="$(yq -r '.jobs.announce.steps | length' "$workflow")" || return 1
  gated_step_count="$(yq -r '[.jobs.announce.steps[] | select(.name != "Resolve current release eligibility" and .["if"] == "steps.current.outputs.eligible == '\''true'\''")] | length' "$workflow")" || return 1
  [[ "$gated_step_count" == "$((step_count - 1))" ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[0] | has("if")' "$workflow")" == false ]] || return 1

  release_ref="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out release commit") | .with.ref' "$workflow")" || return 1
  [[ "$release_ref" == 'refs/tags/${{ github.event.release.tag_name }}' ]] || return 1
  ancestry_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Require release commit on default branch") | .run' "$workflow")" || return 1
  expected_ancestry=$'git fetch origin "$DEFAULT_BRANCH"\nrelease_sha="$(git rev-list -n 1 "refs/tags/$RELEASE_TAG")"\ngit merge-base --is-ancestor "$release_sha" "origin/$DEFAULT_BRANCH"'
  [[ "$ancestry_run" == "$expected_ancestry" ]] || return 1

  trusted_repository="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.repository' "$workflow")" || return 1
  trusted_ref="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.ref' "$workflow")" || return 1
  trusted_path="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.path' "$workflow")" || return 1
  trusted_credentials="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.persist-credentials' "$workflow")" || return 1
  [[ "$trusted_repository" == '${{ job.workflow_repository }}' ]] || return 1
  [[ "$trusted_ref" == '${{ job.workflow_sha }}' ]] || return 1
  [[ -n "$trusted_path" && "$trusted_credentials" == false ]] || return 1

  manifest_repository="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.repository' "$workflow")" || return 1
  manifest_ref="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.ref' "$workflow")" || return 1
  manifest_path="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.path' "$workflow")" || return 1
  manifest_credentials="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.persist-credentials' "$workflow")" || return 1
  [[ "$manifest_repository" == '${{ inputs.marketplace-repository || job.workflow_repository }}' && "$manifest_ref" == main ]] || return 1
  [[ -n "$manifest_path" && "$manifest_path" != "$trusted_path" && "$manifest_credentials" == false ]] || return 1

  current_release_file='${{ runner.temp }}/hov-tool-drop-current-release.json'
  current_env_count="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env | length' "$workflow")" || return 1
  [[ "$current_env_count" == 4 ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.GH_TOKEN' "$workflow")" == '${{ github.token }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.RELEASE_ID' "$workflow")" == '${{ github.event.release.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.RELEASE_TAG' "$workflow")" == '${{ github.event.release.tag_name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.CURRENT_RELEASE_FILE' "$workflow")" == "$current_release_file" ]] || return 1
  current_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .run' "$workflow")" || return 1
  [[ "$current_run" == *'gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$CURRENT_RELEASE_FILE"'* ]] || return 1
  [[ "$current_run" == *'((.id | tostring) == $expected_id)'* ]] || return 1
  [[ "$current_run" == *'(.tag_name == $expected_tag)'* ]] || return 1
  [[ "$current_run" == *'(.body == null or (.body | type == "string"))'* ]] || return 1
  [[ "$current_run" == *'then ((.draft | not) and (.prerelease | not))'* ]] || return 1
  [[ "$current_run" == *'echo "eligible=$eligible" >> "$GITHUB_OUTPUT"'* ]] || return 1
  [[ "$current_run" != *'releases/latest'* && "$current_run" != *'${{'* ]] || return 1

  stable_env_count="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env | length' "$workflow")" || return 1
  [[ "$stable_env_count" == 4 ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env.GH_TOKEN' "$workflow")" == '${{ github.token }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env.REPOSITORY' "$workflow")" == '${{ github.event.repository.name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env.RELEASE_ID' "$workflow")" == '${{ github.event.release.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env.RELEASE_TAG' "$workflow")" == '${{ github.event.release.tag_name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .id' "$workflow")" == stable ]] || return 1
  stable_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .run' "$workflow")" || return 1
  expected_stable="./$trusted_path/release/scripts/latest-stable-release.sh"
  [[ "$stable_run" == "$expected_stable" && "$stable_run" != *'${{'* ]] || return 1

  announce_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .run' "$workflow")" || return 1
  manifest_env="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.MARKETPLACE_MANIFEST' "$workflow")" || return 1
  announce_env_count="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env | length' "$workflow")" || return 1
  expected_announce=$'source_sha="$(git rev-list -n 1 "refs/tags/$RELEASE_TAG")"\nexport SOURCE_SHA="$source_sha"\n'
  expected_announce+="./$trusted_path/release/scripts/tool-drop-announce.sh"
  [[ "$announce_run" == "$expected_announce" ]] || return 1
  [[ "$announce_env_count" == 8 ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.EVENT_ACTION' "$workflow")" == '${{ github.event.action }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.REPOSITORY' "$workflow")" == '${{ github.event.repository.name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.RELEASE_ID' "$workflow")" == '${{ github.event.release.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.RELEASE_TAG' "$workflow")" == '${{ github.event.release.tag_name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.CURRENT_RELEASE_FILE' "$workflow")" == "$current_release_file" ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.LATEST_STABLE_ID' "$workflow")" == '${{ steps.stable.outputs.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.SOURCE_ROOT' "$workflow")" == '${{ github.workspace }}' ]] || return 1
  [[ "$manifest_env" == '${{ github.workspace }}'"/$manifest_path/.claude-plugin/marketplace.json" ]] || return 1
  ! grep -Eq 'github\.event\.release\.(body|draft|prerelease)' "$workflow" || return 1
  ! grep -Fq 'ACTIONS_ID_TOKEN_REQUEST_URL' "$workflow" || return 1

  grep -Fq 'readonly request_body' "$helper" || return 1
  [[ "$({ grep -Fo -- '--arg releaseId "$RELEASE_ID"' "$helper" || true; } | wc -l)" == 1 ]] || return 1
  grep -Fq '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)' "$helper" || return 1
  # The body's repository field and both manifest predicates use the plugin name
  # derived from the tag, never the GitHub repository name. The derivation splits
  # on the LAST "--v", refuses a name that still carries the separator, reads
  # VERSION and the plugin manifest from the derived directory, and expects the
  # tag under the derived prefix. Each pin is one mutant in the harness below.
  grep -Fq -- '--arg repository "$PLUGIN_NAME"' "$helper" || return 1
  ! grep -Fq -- '--arg repository "$REPOSITORY"' "$helper" || return 1
  [[ "$({ grep -Fo -- '--arg name "$PLUGIN_NAME"' "$helper" || true; } | wc -l)" == 2 ]] || return 1
  ! grep -Fq -- '--arg name "$REPOSITORY"' "$helper" || return 1
  grep -Fq 'PLUGIN_NAME="${RELEASE_TAG%--v*}"' "$helper" || return 1
  grep -Fq '[[ "$PLUGIN_NAME" != *--* ]] || fail' "$helper" || return 1
  grep -Fq 'plugin_root="$SOURCE_ROOT${PLUGIN_DIR:+/$PLUGIN_DIR}"' "$helper" || return 1
  grep -Fq 'expected_tag="${TAG_PREFIX}v$version"' "$helper" || return 1
  grep -Fq '[[ "$PLUGIN_NAME" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail' "$helper" || return 1
  grep -Fq '[[ "${RELEASE_TAG##*--v}" == [0-9]* ]] || fail' "$helper" || return 1
  grep -Fq 'PLUGIN_DIR="plugins/$PLUGIN_NAME"' "$helper" || return 1
  grep -Fq 'TAG_PREFIX="$PLUGIN_NAME--"' "$helper" || return 1
  grep -Fq '[[ -f "$plugin_root/VERSION" ]] || fail' "$helper" || return 1
  # Derivation is called once, after the latest-stable no-op and immediately
  # before release verification, so a draft or non-latest release with a
  # malformed tag stays a no-op instead of failing.
  local noop_line derive_line verify_line
  noop_line="$(grep -n -F 'is not latest stable %s; no-op' "$helper" | cut -d: -f1)"
  derive_line="$(grep -n -x -F '  derive_plugin_identity' "$helper" | cut -d: -f1)"
  verify_line="$(grep -n -F 'RELEASE_VERSION="$(verify_release)"' "$helper" | cut -d: -f1)"
  [[ -n "$noop_line" && -n "$derive_line" && -n "$verify_line" ]] || return 1
  [[ "$noop_line" != *$'\n'* && "$derive_line" != *$'\n'* && "$verify_line" != *$'\n'* ]] || return 1
  (( noop_line < derive_line && derive_line + 1 == verify_line )) || return 1
  grep -Fq 'local -r request_body="$1" expected_sha="$2" oidc_token="$3"' "$helper" || return 1
  grep -Fq 'request_sha="$(sha256_bytes "$request_body")"' "$helper" || return 1
  grep -Fq 'audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"' "$helper" || return 1
  grep -Fq -- '--data-urlencode "audience=$audience"' "$helper" || return 1
  grep -Fq 'send_request "$request_body" "$request_sha" "$oidc_token"' "$helper" || return 1
  grep -Fq 'actual_sha="$(sha256_bytes "$request_body")"' "$helper" || return 1
  grep -Fq '[[ "$actual_sha" == "$expected_sha" ]] || fail "request body changed after OIDC mint"' "$helper" || return 1
  grep -Fq -- '--data-binary "$request_body"' "$helper" || return 1
  grep -Fq '"$TOOL_RELEASES_ENDPOINT"' "$helper" || return 1
  grep -Fq '[[ $# -eq 0 ]] || fail "this helper accepts no arguments"' "$helper" || return 1
  grep -Fq '[[ "$1" =~ ^[1-9][0-9]*$ ]]' "$helper" || return 1
  grep -Fq 'is_positive_uint "$RELEASE_ID" || fail "RELEASE_ID must be a positive canonical decimal integer"' "$helper" || return 1
  grep -Fq 'is_positive_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be a positive canonical decimal integer"' "$helper" || return 1
  grep -Fq 'require CURRENT_RELEASE_FILE' "$helper" || return 1
  [[ "$({ grep -Fo 'require CURRENT_RELEASE_FILE' "$helper" || true; } | wc -l)" == 2 ]] || return 1
  grep -Fq '((.id | tostring) == $expected_id)' "$helper" || return 1
  grep -Fq '(.tag_name == $expected_tag)' "$helper" || return 1
  grep -Fq 'has("body")' "$helper" || return 1
  grep -Fq '(.body == null or (.body | type == "string"))' "$helper" || return 1
  grep -Fq '(.draft | type == "boolean")' "$helper" || return 1
  grep -Fq '(.prerelease | type == "boolean")' "$helper" || return 1
  grep -Fq 'CURRENT_RELEASE_NOTES="$(jq -jr' "$helper" || return 1
  grep -Fq 'notes="$(printf '\''%s'\'' "${CURRENT_RELEASE_NOTES:-}" | tr -d '\''\r'\'')"' "$helper" || return 1
  utf16_width_count="$({ grep -Fo 'width = 2 if ord(char) > 0xFFFF else 1' "$helper" || true; } | wc -l)"
  [[ "$utf16_width_count" == 2 ]] || return 1
  grep -Fq 'out.append(utf16_prefix(line, 180))' "$helper" || return 1
  grep -Fq 'print(utf16_prefix("\n".join(out), 600))' "$helper" || return 1
  grep -Fq 'if used + width > 600:' "$helper" || return 1
  grep -Fq '[[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"' "$helper" || return 1
  ! grep -Eq '(^|[[:space:]])(eval|source)[[:space:]].*CURRENT_RELEASE' "$helper" || return 1
  ! grep -Fq -- '--location' "$helper" || return 1
  ! grep -Eq -- '(^|[[:blank:]])-L([[:blank:]]|$)' "$helper" || return 1
  ! grep -Fq -- '--retry' "$helper" || return 1
  ! grep -Fq -- '--config' "$helper" || return 1
  ! grep -Eq -- '(^|[[:blank:]])-K([[:blank:]]|$)' "$helper" || return 1
  grep -Fq 'ANNOUNCE_RESPONSE_DIR="$(mktemp -d)"' "$helper" || return 1
  grep -Fq 'trap cleanup_response_dir EXIT' "$helper" || return 1
  grep -Fxq 'readonly ANNOUNCE_MAX_ATTEMPTS=8' "$helper" || return 1
  grep -Fxq 'readonly RETRY_JITTER_MAX_SECONDS=3' "$helper" || return 1
  grep -Fq '[[ "$expected_status" == 409 || "$expected_status" == 429 ]] || return 1' "$helper" || return 1
  grep -Fq '[[ "$final_status" == "$expected_status" ]] || return 1' "$helper" || return 1
  grep -Fq 'if [[ "$http_status" != 409 && "$http_status" != 429 && "$promotion_lag" == false ]]; then' "$helper" || return 1
  # The 403 widening is deliberately narrow. Only a response that PARSES as a JSON object and
  # whose .error is this exact server message is retryable; every other 403 -- a bad audience, a
  # revoked app, a genuinely absent promotion, an HTML error page -- stays terminal on attempt
  # one. Pin the message, the status guard and the jq shape so a later edit cannot quietly turn
  # this into "any 403 is retryable" without editing this contract.
  grep -Fxq "readonly PROMOTION_LAG_ERROR='release does not match the marketplace promotion'" "$helper" || return 1
  grep -Fq '[[ "$1" == 403 ]] || return 1' "$helper" || return 1
  grep -Fq 'if type == "object" then (.error? == $m) else false end' "$helper" || return 1
  grep -Fq '[[ "${values[0]}" =~ ^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$ ]]' "$helper" || return 1
  grep -Fq 'retry_after="$(retry_after_seconds "$response_headers" "$http_status")"' "$helper" || return 1
  grep -Fq 'digest="$(sha256_bytes "$jitter_repository:$jitter_release_id:$jitter_attempt")"' "$helper" || return 1
  grep -Fq '16#${digest:0:8} % (RETRY_JITTER_MAX_SECONDS + 1)' "$helper" || return 1
  grep -Fq 'retry_jitter="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" "$attempt")"' "$helper" || return 1
  grep -Fq 'retry_delay=$((10#$retry_after + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + retry_jitter))' "$helper" || return 1
  grep -Fq 'sleep "$retry_delay"' "$helper" || return 1
  ! grep -Fq 'sleep "$retry_after"' "$helper" || return 1

  send_block="$(sed -n '/^send_request() {/,/^}/p' "$helper")"
  header_count="$(printf '%s\n' "$send_block" | grep -cE '^[[:space:]]+-H ' || true)"
  [[ "$header_count" == 2 ]] || return 1
  grep -Fq -- "-H 'content-type: application/json'" <<<"$send_block" || return 1
  grep -Fq -- '-H "authorization: Bearer $oidc_token"' <<<"$send_block" || return 1
  grep -Fq -- '--output "$response_body"' <<<"$send_block" || return 1
  grep -Fq -- '--dump-header "$response_headers"' <<<"$send_block" || return 1
  grep -Fq -- "--write-out '%{http_code}'" <<<"$send_block" || return 1
  ! grep -Fq -- '--fail-with-body' <<<"$send_block" || return 1
  grep -Fq 'curl --disable --silent --show-error' <<<"$send_block" || return 1

  disable_count="$({ grep -Fo -- '--disable' "$helper" || true; } | wc -l)"
  [[ "$disable_count" == 2 ]] || return 1
  grep -Fq 'curl --disable --fail-with-body --silent --show-error --get' "$helper" || return 1

  announce_block="$(sed -n '/^announce() {/,/^}/p' "$helper")"
  retry_loop_line="$({ grep -nFx '  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do' <<<"$announce_block" || true; } | cut -d: -f1)"
  mint_line="$({ grep -nF 'oidc_token="$(mint_oidc_token "$audience")"' <<<"$announce_block" || true; } | cut -d: -f1)"
  retry_loop_end_line="$({ grep -nFx '  done' <<<"$announce_block" || true; } | cut -d: -f1)"
  [[ "$retry_loop_line" =~ ^[0-9]+$ && "$mint_line" =~ ^[0-9]+$ && "$retry_loop_end_line" =~ ^[0-9]+$ ]] || return 1
  ((retry_loop_line < mint_line && mint_line < retry_loop_end_line)) || return 1

  mask_line="$({ grep -nF "printf '::add-mask::%s\\n' \"\$oidc_token\"" "$helper" || true; } | cut -d: -f1)"
  send_line="$({ grep -nF 'send_request "$request_body" "$request_sha" "$oidc_token"' "$helper" || true; } | cut -d: -f1)"
  [[ "$mask_line" =~ ^[0-9]+$ && "$send_line" =~ ^[0-9]+$ ]] || return 1
  ((mask_line < send_line)) || return 1
}

replace_once() {
  local source="$1" destination="$2" old="$3" new="$4"
  python3 - "$source" "$destination" "$old" "$new" <<'PY'
from pathlib import Path
import sys

source, destination, old, new = sys.argv[1:]
text = Path(source).read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one mutation target, found {count}: {old!r}")
Path(destination).write_text(text.replace(old, new, 1))
PY
}

swap_once() {
  local source="$1" destination="$2" first="$3" second="$4"
  python3 - "$source" "$destination" "$first" "$second" <<'PY'
from pathlib import Path
import sys

source, destination, first, second = sys.argv[1:]
text = Path(source).read_text()
for needle in (first, second):
    count = text.count(needle)
    if count != 1:
        raise SystemExit(f"expected one swap target, found {count}: {needle!r}")
start, end = text.index(first), text.index(second)
if start >= end:
    raise SystemExit("first swap target must precede the second")
Path(destination).write_text(
    text[:start] + second + text[start + len(first):end] + first + text[end + len(second):]
)
PY
}

expect_contract_reject() {
  local label="$1" workflow="$2" helper="$3"
  if check_contract "$workflow" "$helper" >/dev/null 2>&1; then
    die "$label mutation escaped the static contract"
  fi
  pass "$label mutation rejected"
}

check_contract "$WORKFLOW" "$HELPER" || die "trusted workflow/helper static contract"
pass "trusted workflow/helper static contract"

mutant="$TMP/workflow-input.yml"
replace_once "$WORKFLOW" "$mutant" $'    inputs:\n      marketplace-repository:\n' $'    inputs:\n      announce-url:\n        type: string\n        required: false\n      marketplace-repository:\n'
expect_contract_reject "caller URL input" "$mutant" "$HELPER"

mutant="$TMP/workflow-second-input.yml"
replace_once "$WORKFLOW" "$mutant" $'        type: string\n        required: false\n\npermissions: {}\n' \
  $'        type: string\n        required: false\n      marketplace-ref:\n        type: string\n        required: false\n\npermissions: {}\n'
expect_contract_reject "second workflow input" "$mutant" "$HELPER"

mutant="$TMP/workflow-required-input.yml"
replace_once "$WORKFLOW" "$mutant" $'        type: string\n        required: false\n\npermissions: {}\n' \
  $'        type: string\n        required: true\n\npermissions: {}\n'
expect_contract_reject "manifest repository input made required" "$mutant" "$HELPER"

mutant="$TMP/workflow-input-caller-default.yml"
replace_once "$WORKFLOW" "$mutant" $'        type: string\n        required: false\n\npermissions: {}\n' \
  $'        type: string\n        required: false\n        default: ${{ github.repository }}\n\npermissions: {}\n'
expect_contract_reject "manifest repository input defaulting to the caller" "$mutant" "$HELPER"

mutant="$TMP/workflow-no-concurrency-cancel.yml"
replace_once "$WORKFLOW" "$mutant" $'      cancel-in-progress: true\n' ''
expect_contract_reject "missing release concurrency cancellation" "$mutant" "$HELPER"

mutant="$TMP/workflow-wrong-concurrency-key.yml"
replace_once "$WORKFLOW" "$mutant" \
  'hov-tool-drop-announce-${{ github.repository }}-${{ github.event.release.id }}' \
  'hov-tool-drop-announce-${{ github.repository }}-${{ github.event.release.tag_name }}'
expect_contract_reject "release ID removed from concurrency key" "$mutant" "$HELPER"

mutant="$TMP/workflow-root-concurrency.yml"
replace_once "$WORKFLOW" "$mutant" $'permissions: {}\n' \
  $'permissions: {}\n\nconcurrency:\n  group: hov-tool-drop-announce\n  cancel-in-progress: true\n'
expect_contract_reject "root concurrency can cancel unrelated releases" "$mutant" "$HELPER"

mutant="$TMP/workflow-stale-job-filter.yml"
replace_once "$WORKFLOW" "$mutant" $'  announce:\n    concurrency:' \
  $'  announce:\n    if: github.event.release.draft == false && github.event.release.prerelease == false\n    concurrency:'
expect_contract_reject "stale event job filter" "$mutant" "$HELPER"

mutant="$TMP/workflow-missing-current-release-fetch.yml"
replace_once "$WORKFLOW" "$mutant" \
  'gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$CURRENT_RELEASE_FILE"' \
  ': >"$CURRENT_RELEASE_FILE"'
expect_contract_reject "missing current release fetch" "$mutant" "$HELPER"

mutant="$TMP/workflow-latest-as-current.yml"
replace_once "$WORKFLOW" "$mutant" \
  'gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$CURRENT_RELEASE_FILE"' \
  'gh api "repos/$GITHUB_REPOSITORY/releases/latest" >"$CURRENT_RELEASE_FILE"'
expect_contract_reject "current release fetch weakened to latest" "$mutant" "$HELPER"

mutant="$TMP/workflow-force-current-eligible.yml"
replace_once "$WORKFLOW" "$mutant" \
  'then ((.draft | not) and (.prerelease | not))' \
  'then true'
expect_contract_reject "draft and prerelease eligibility bypass" "$mutant" "$HELPER"

mutant="$TMP/workflow-unguarded-latest-stable.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'      - name: Resolve latest stable release\n        if: steps.current.outputs.eligible == '\''true'\''' \
  $'      - name: Resolve latest stable release'
expect_contract_reject "latest stable lookup before eligibility" "$mutant" "$HELPER"

mutant="$TMP/workflow-stale-event-body.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          EVENT_ACTION: ${{ github.event.action }}\n          REPOSITORY: ${{ github.event.repository.name }}\n          RELEASE_ID: ${{ github.event.release.id }}\n' \
  $'          EVENT_ACTION: ${{ github.event.action }}\n          REPOSITORY: ${{ github.event.repository.name }}\n          RELEASE_ID: ${{ github.event.release.id }}\n          RELEASE_NOTES: ${{ github.event.release.body }}\n'
expect_contract_reject "stale event body authority" "$mutant" "$HELPER"

mutant="$TMP/workflow-missing-helper-current-file.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          RELEASE_TAG: ${{ github.event.release.tag_name }}\n          CURRENT_RELEASE_FILE: ${{ runner.temp }}/hov-tool-drop-current-release.json\n          LATEST_STABLE_ID:' \
  $'          RELEASE_TAG: ${{ github.event.release.tag_name }}\n          LATEST_STABLE_ID:'
expect_contract_reject "current release file not passed to helper" "$mutant" "$HELPER"

mutant="$TMP/workflow-published-only-announce-step.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'      - name: Announce release\n        if: steps.current.outputs.eligible == '\''true'\''' \
  $'      - name: Announce release\n        if: steps.current.outputs.eligible == '\''true'\'' && github.event.action == '\''published'\'''
expect_contract_reject "published-only announce step" "$mutant" "$HELPER"

mutant="$TMP/workflow-mutable-ref.yml"
replace_once "$WORKFLOW" "$mutant" 'ref: ${{ job.workflow_sha }}' 'ref: main'
expect_contract_reject "mutable helper checkout" "$mutant" "$HELPER"

mutant="$TMP/workflow-ancestry-bypass.yml"
replace_once "$WORKFLOW" "$mutant" 'git merge-base --is-ancestor "$release_sha" "origin/$DEFAULT_BRANCH"' 'true'
expect_contract_reject "release ancestry bypass" "$mutant" "$HELPER"

mutant="$TMP/workflow-mutable-helper.yml"
replace_once "$WORKFLOW" "$mutant" './trusted-workflow/release/scripts/tool-drop-announce.sh' './marketplace-data/release/scripts/tool-drop-announce.sh'
expect_contract_reject "mutable-main helper execution" "$mutant" "$HELPER"

mutant="$TMP/workflow-inline-latest-stable.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'        run: ./trusted-workflow/release/scripts/latest-stable-release.sh\n' \
  $'        run: |\n          latest_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .id)"\n          test -n "$latest_id"\n          echo "id=$latest_id" >> "$GITHUB_OUTPUT"\n'
expect_contract_reject "repository-wide latest stable lookup" "$mutant" "$HELPER"

mutant="$TMP/workflow-mutable-guard.yml"
replace_once "$WORKFLOW" "$mutant" './trusted-workflow/release/scripts/latest-stable-release.sh' './marketplace-data/release/scripts/latest-stable-release.sh'
expect_contract_reject "mutable-main guard execution" "$mutant" "$HELPER"

mutant="$TMP/workflow-guard-without-tag.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          RELEASE_ID: ${{ github.event.release.id }}\n          RELEASE_TAG: ${{ github.event.release.tag_name }}\n        run: ./trusted-workflow/release/scripts/latest-stable-release.sh\n' \
  $'          RELEASE_ID: ${{ github.event.release.id }}\n        run: ./trusted-workflow/release/scripts/latest-stable-release.sh\n'
expect_contract_reject "release tag not passed to the guard" "$mutant" "$HELPER"

mutant="$TMP/workflow-extra-guard-env.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          RELEASE_TAG: ${{ github.event.release.tag_name }}\n        run: ./trusted-workflow/release/scripts/latest-stable-release.sh\n' \
  $'          RELEASE_TAG: ${{ github.event.release.tag_name }}\n          RELEASE_NOTES: ${{ github.event.release.body }}\n        run: ./trusted-workflow/release/scripts/latest-stable-release.sh\n'
expect_contract_reject "extra guard environment key" "$mutant" "$HELPER"

mutant="$TMP/workflow-literal-manifest-repository.yml"
replace_once "$WORKFLOW" "$mutant" \
  'repository: ${{ inputs.marketplace-repository || job.workflow_repository }}' \
  'repository: StartupBros-com/hov-marketplace'
expect_contract_reject "literal manifest repository" "$mutant" "$HELPER"

mutant="$TMP/workflow-caller-manifest-repository.yml"
replace_once "$WORKFLOW" "$mutant" \
  'repository: ${{ inputs.marketplace-repository || job.workflow_repository }}' \
  'repository: ${{ inputs.marketplace-repository || github.repository }}'
expect_contract_reject "manifest read from the caller repository" "$mutant" "$HELPER"

mutant="$TMP/workflow-reordered-stable-step.yml"
swap_once "$WORKFLOW" "$mutant" \
  $'      - name: Check out current marketplace manifest\n        if: steps.current.outputs.eligible == \'true\'\n        uses: actions/checkout@ac593985615ec2ede58e132d2e21d2b1cbd6127c\n        with:\n          repository: ${{ inputs.marketplace-repository || job.workflow_repository }}\n          ref: main\n          path: marketplace-data\n          persist-credentials: false\n' \
  $'      - name: Resolve latest stable release\n        if: steps.current.outputs.eligible == \'true\'\n        id: stable\n        env:\n          GH_TOKEN: ${{ github.token }}\n          REPOSITORY: ${{ github.event.repository.name }}\n          RELEASE_ID: ${{ github.event.release.id }}\n          RELEASE_TAG: ${{ github.event.release.tag_name }}\n        run: ./trusted-workflow/release/scripts/latest-stable-release.sh\n'
expect_contract_reject "latest stable step reordered before the manifest checkout" "$mutant" "$HELPER"

mutant="$TMP/workflow-ancestry-literal-branch.yml"
replace_once "$WORKFLOW" "$mutant" \
  'git merge-base --is-ancestor "$release_sha" "origin/$DEFAULT_BRANCH"' \
  'git merge-base --is-ancestor "$release_sha" "origin/main"'
expect_contract_reject "ancestry check against a literal branch" "$mutant" "$HELPER"

mutant="$TMP/workflow-extra-announce-env.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          MARKETPLACE_MANIFEST: ${{ github.workspace }}/marketplace-data/.claude-plugin/marketplace.json\n' \
  $'          MARKETPLACE_MANIFEST: ${{ github.workspace }}/marketplace-data/.claude-plugin/marketplace.json\n          MARKETPLACE_REPOSITORY: ${{ inputs.marketplace-repository }}\n'
expect_contract_reject "extra announce environment key" "$mutant" "$HELPER"

mutant="$TMP/guard-latest-endpoint.sh"
replace_once "$GUARD" "$mutant" \
  'gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100"' \
  'gh api "repos/$GITHUB_REPOSITORY/releases/latest"'
if check_contract "$WORKFLOW" "$HELPER" "$mutant" >/dev/null 2>&1; then
  die "guard using the repository-wide latest release escaped the static contract"
fi
pass "guard using the repository-wide latest release mutation rejected"

mutant="$TMP/guard-creation-order.sh"
replace_once "$GUARD" "$mutant" 'sort_by(.version)' 'sort_by(.created_at)'
if check_contract "$WORKFLOW" "$HELPER" "$mutant" >/dev/null 2>&1; then
  die "guard ordering by creation time escaped the static contract"
fi
pass "guard ordering by creation time mutation rejected"

mutant="$TMP/helper-caller-url.sh"
replace_once "$HELPER" "$mutant" "readonly TOOL_RELEASES_ENDPOINT='$FIXED_ENDPOINT'" 'readonly TOOL_RELEASES_ENDPOINT="${ANNOUNCE_URL:?}"'
expect_contract_reject "caller-controlled helper endpoint" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-secret-header.sh"
replace_once "$HELPER" "$mutant" "-H 'content-type: application/json'" "-H 'x-tool-release-announce-secret: fixture'"
expect_contract_reject "secret header" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-generic-audience.sh"
replace_once "$HELPER" "$mutant" 'audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"' 'audience="$TOOL_RELEASES_ENDPOINT"'
expect_contract_reject "generic OIDC audience" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-omitted-release-id.sh"
replace_once "$HELPER" "$mutant" \
  '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)' \
  '{operation: $operation, repository: $repository} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)'
expect_contract_reject "omitted release ID body field" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-numeric-release-id.sh"
replace_once "$HELPER" "$mutant" \
  $'    --arg releaseId "$RELEASE_ID" \\\n    --arg notesSummary "$notes" \\' \
  $'    --argjson releaseId "$RELEASE_ID" \\\n    --arg notesSummary "$notes" \\'
expect_contract_reject "numeric release ID body field" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-zero-release-id.sh"
replace_once "$HELPER" "$mutant" '[[ "$1" =~ ^[1-9][0-9]*$ ]]' '[[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]'
expect_contract_reject "zero-permitting release ID validation" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-current-id-mismatch-accepted.sh"
replace_once "$HELPER" "$mutant" \
  '((.id | tostring) == $expected_id)' \
  '((.id | tostring) != $expected_id)'
expect_contract_reject "current release ID match removed" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-stale-event-notes.sh"
replace_once "$HELPER" "$mutant" \
  'notes="$(printf '\''%s'\'' "${CURRENT_RELEASE_NOTES:-}" | tr -d '\''\r'\'')"' \
  'notes="$(printf '\''%s'\'' "${RELEASE_NOTES:-}" | tr -d '\''\r'\'')"'
expect_contract_reject "stale event notes restored" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-codepoint-only-limit.sh"
python3 - "$HELPER" "$mutant" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
old = "width = 2 if ord(char) > 0xFFFF else 1"
if text.count(old) != 2:
    raise SystemExit("expected both UTF-16 width guards")
destination.write_text(text.replace(old, "width = 1"))
PY
expect_contract_reject "code-point-only notes limit" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-published-only.sh"
replace_once "$HELPER" "$mutant" \
  '[[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"' \
  '[[ "$EVENT_ACTION" == published ]] || fail "unsupported release action: $EVENT_ACTION"'
expect_contract_reject "edited release action removed" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-mutable-send-body.sh"
replace_once "$HELPER" "$mutant" \
  'local -r request_body="$1" expected_sha="$2" oidc_token="$3"' \
  'local request_body="$1" expected_sha="$2" oidc_token="$3"'
expect_contract_reject "mutable send body" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-post-check-body.sh"
replace_once "$HELPER" "$mutant" '--data-binary "$request_body"' '--data-binary "${request_body}x"'
expect_contract_reject "body alteration after digest guard" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-mask-order.sh"
mask_statement="    printf '::add-mask::%s\\n' \"\$oidc_token\""
send_statement=$'    if ! send_request "$request_body" "$request_sha" "$oidc_token" \\\n      "$response_body" "$response_headers" http_status; then\n      break\n    fi'
replace_once "$HELPER" "$mutant" \
  "$mask_statement"$'\n'"$send_statement" \
  "$send_statement"$'\n'"$mask_statement"
expect_contract_reject "token mask ordering" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-stale-retry-token.sh"
fresh_mint_block=$'  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do\n    http_status=\'\'\n    if ! oidc_token="$(mint_oidc_token "$audience")"; then\n      fail "could not mint OIDC token"\n    fi'
stale_mint_block=$'  if ! oidc_token="$(mint_oidc_token "$audience")"; then\n    fail "could not mint OIDC token"\n  fi\n  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do\n    http_status=\'\''
replace_once "$HELPER" "$mutant" "$fresh_mint_block" "$stale_mint_block"
expect_contract_reject "OIDC mint outside retry loop" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-unbounded-retry.sh"
replace_once "$HELPER" "$mutant" \
  'for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do' \
  'while true; do'
expect_contract_reject "unbounded retry loop" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-wider-attempt-budget.sh"
replace_once "$HELPER" "$mutant" 'readonly ANNOUNCE_MAX_ATTEMPTS=8' 'readonly ANNOUNCE_MAX_ATTEMPTS=9'
expect_contract_reject "widened retry attempt budget" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-incomplete-jitter-key.sh"
replace_once "$HELPER" "$mutant" \
  'sha256_bytes "$jitter_repository:$jitter_release_id:$jitter_attempt"' \
  'sha256_bytes "$jitter_repository:$jitter_release_id"'
expect_contract_reject "incomplete retry jitter key" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-wide-retry-after.sh"
replace_once "$HELPER" "$mutant" \
  '^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$' \
  '^[1-9][0-9]*$'
expect_contract_reject "widened Retry-After validation" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-wide-retry-status.sh"
replace_once "$HELPER" "$mutant" \
  'if [[ "$http_status" != 409 && "$http_status" != 429 && "$promotion_lag" == false ]]; then' \
  'if [[ "$http_status" != 409 && "$http_status" != 429 && "$http_status" != 503 && "$promotion_lag" == false ]]; then'
expect_contract_reject "widened retry status set" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-any-403-retryable.sh"
replace_once "$HELPER" "$mutant" \
  'if type == "object" then (.error? == $m) else false end' \
  'if type == "object" then true else false end'
expect_contract_reject "any-403 treated as promotion lag" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-dropped-403-status-guard.sh"
replace_once "$HELPER" "$mutant" \
  '  [[ "$1" == 403 ]] || return 1' \
  '  : "$1"'
expect_contract_reject "promotion-lag detector without its status guard" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-raw-retry-sleep.sh"
raw_header_parse='retry_after="$(sed -n "s/^Retry-After: //p" "$response_headers")"'
replace_once "$HELPER" "$mutant" \
  'retry_after="$(retry_after_seconds "$response_headers" "$http_status")"' \
  "$raw_header_parse"
expect_contract_reject "raw Retry-After sleep" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-ambient-curl-config.sh"
replace_once "$HELPER" "$mutant" \
  'curl --disable --silent --show-error' \
  'curl --silent --show-error'
expect_contract_reject "ambient curl configuration" "$WORKFLOW" "$mutant"

WORKFLOW_PROBE_BIN="$TMP/workflow-bin"
WORKFLOW_PROBE_CALLS="$TMP/workflow-gh-calls"
WORKFLOW_PROBE_OUTPUT="$TMP/workflow-output"
WORKFLOW_PROBE_RELEASE="$TMP/workflow-current-release.json"
mkdir -p "$WORKFLOW_PROBE_BIN"
cat >"$WORKFLOW_PROBE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$WORKFLOW_PROBE_CALLS"
[[ "$*" == "api repos/fixture-owner/fixture-tool/releases/42" ]] || exit 120
printf '%s\n' '{"id":42,"tag_name":"v1.2.3","body":"prerelease notes","draft":false,"prerelease":true}'
FAKE_GH
chmod +x "$WORKFLOW_PROBE_BIN/gh"
: >"$WORKFLOW_PROBE_CALLS"
: >"$WORKFLOW_PROBE_OUTPUT"
workflow_current_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .run' "$WORKFLOW")"
if ! env \
  PATH="$WORKFLOW_PROBE_BIN:$PATH" \
  GH_TOKEN=fixture-token \
  GITHUB_REPOSITORY=fixture-owner/fixture-tool \
  GITHUB_OUTPUT="$WORKFLOW_PROBE_OUTPUT" \
  RELEASE_ID=42 \
  RELEASE_TAG=v1.2.3 \
  CURRENT_RELEASE_FILE="$WORKFLOW_PROBE_RELEASE" \
  WORKFLOW_PROBE_CALLS="$WORKFLOW_PROBE_CALLS" \
  bash -c "$workflow_current_run" >"$TMP/workflow-probe-log" 2>&1; then
  command cat "$TMP/workflow-probe-log" >&2
  die "prerelease eligibility workflow probe"
fi
[[ "$(<"$WORKFLOW_PROBE_OUTPUT")" == 'eligible=false' ]] || die "prerelease eligibility did not emit false"
[[ "$(<"$WORKFLOW_PROBE_CALLS")" == 'api repos/fixture-owner/fixture-tool/releases/42' ]] || die "prerelease eligibility touched latest stable or another release"
grep -Fq 'Current release is draft or prerelease' "$TMP/workflow-probe-log" || die "prerelease eligibility did not report its soft no-op"
pass "prerelease-only repository resolves in current-state step without latest-stable lookup"

# The stable step's one-line run reaches the trusted guard with exactly the
# environment the contract pins: each pinned key maps to a fixture value and
# any other key fails the probe. A guard copy under the mutable manifest
# checkout exits 125 so running it there would be caught.
STABLE_PROBE_DIR="$TMP/stable-probe"
STABLE_PROBE_CALLS="$TMP/stable-gh-calls"
STABLE_PROBE_OUTPUT="$TMP/stable-output"
mkdir -p "$STABLE_PROBE_DIR/bin" "$STABLE_PROBE_DIR/trusted-workflow/release/scripts" "$STABLE_PROBE_DIR/marketplace-data/release/scripts"
cp "$GUARD" "$STABLE_PROBE_DIR/trusted-workflow/release/scripts/latest-stable-release.sh"
printf '#!/usr/bin/env bash\nexit 125\n' >"$STABLE_PROBE_DIR/marketplace-data/release/scripts/latest-stable-release.sh"
chmod +x "$STABLE_PROBE_DIR/trusted-workflow/release/scripts/latest-stable-release.sh" "$STABLE_PROBE_DIR/marketplace-data/release/scripts/latest-stable-release.sh"
cat >"$STABLE_PROBE_DIR/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STABLE_PROBE_CALLS"
[[ "$*" == "api --paginate repos/fixture-owner/fixture-monorepo/releases?per_page=100" ]] || exit 120
printf '%s\n' '[{"id":9,"tag_name":"pro-gate--v2.0.0","draft":false,"prerelease":false},{"id":8,"tag_name":"hov-stack--v0.1.0","draft":false,"prerelease":false},{"id":7,"tag_name":"pro-gate--v1.9.0","draft":false,"prerelease":false}]'
FAKE_GH
chmod +x "$STABLE_PROBE_DIR/bin/gh"
: >"$STABLE_PROBE_CALLS"
: >"$STABLE_PROBE_OUTPUT"
stable_env_args=()
while IFS= read -r key; do
  case "$key" in
    GH_TOKEN) stable_env_args+=("GH_TOKEN=fixture-token") ;;
    REPOSITORY) stable_env_args+=("REPOSITORY=fixture-monorepo") ;;
    RELEASE_ID) stable_env_args+=("RELEASE_ID=7") ;;
    RELEASE_TAG) stable_env_args+=("RELEASE_TAG=pro-gate--v1.9.0") ;;
    *) die "latest stable step carries an unexpected environment key: $key" ;;
  esac
done < <(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env | keys | .[]' "$WORKFLOW")
[[ "${#stable_env_args[@]}" == 4 ]] || die "latest stable step does not carry its four environment keys"
workflow_stable_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .run' "$WORKFLOW")"
if ! (cd "$STABLE_PROBE_DIR" && env \
  PATH="$STABLE_PROBE_DIR/bin:$PATH" \
  GITHUB_REPOSITORY=fixture-owner/fixture-monorepo \
  GITHUB_OUTPUT="$STABLE_PROBE_OUTPUT" \
  STABLE_PROBE_CALLS="$STABLE_PROBE_CALLS" \
  "${stable_env_args[@]}" \
  bash -c "$workflow_stable_run") >"$TMP/stable-probe-log" 2>&1; then
  command cat "$TMP/stable-probe-log" >&2
  die "latest stable workflow probe"
fi
[[ "$(<"$STABLE_PROBE_OUTPUT")" == 'id=9' ]] || die "latest stable probe did not resolve the family winner"
[[ "$(<"$STABLE_PROBE_CALLS")" == 'api --paginate repos/fixture-owner/fixture-monorepo/releases?per_page=100' ]] || die "latest stable probe made unexpected gh calls"
grep -Fxq 'hov-drop-announce: status=not-announced reason=not-latest repository=fixture-monorepo tag=pro-gate--v1.9.0 plugin=pro-gate' "$TMP/stable-probe-log" \
  || die "latest stable probe did not print the not-announced marker"
pass "latest stable step runs the trusted guard with its pinned environment and skips an older same-prefix release with the marker"

FIXTURE_REPOSITORY='fixture-tool'
FIXTURE_VERSION='1.2.3'
FIXTURE_TAG="v$FIXTURE_VERSION"
FIXTURE_RELEASE_ID='42'
SOURCE_ROOT="$TMP/source"
MANIFEST="$TMP/marketplace.json"
CURRENT_RELEASE_FILE="$TMP/current-release.json"
FAKE_BIN="$TMP/bin"
CALLS_FILE="$TMP/curl-calls"
BODY_FILE="$TMP/request-body"
HEADERS_FILE="$TMP/request-headers"
URL_FILE="$TMP/request-url"
AUDIENCE_FILE="$TMP/oidc-audience"
MINTED_TOKENS_FILE="$TMP/minted-tokens"
POST_TOKENS_FILE="$TMP/post-tokens"
SLEEP_DELAYS_FILE="$TMP/sleep-delays"
RESPONSE_PATHS_FILE="$TMP/response-paths"
OIDC_URL='https://token.actions.test/oidc?api-version=fixture'
ORIGINAL_PATH="$PATH"
# run_helper's release identity. Every existing case uses the per-plugin fixture;
# the monorepo cases at the end override these through dynamic scope.
RUN_REPOSITORY="$FIXTURE_REPOSITORY"
RUN_TAG="$FIXTURE_TAG"
RUN_SOURCE_ROOT="$SOURCE_ROOT"
# The caller's default Actions variables. Empty for every plugin case, which
# never sets them; the product cases override them through dynamic scope.
RUN_GITHUB_REPOSITORY=''
RUN_GITHUB_REPOSITORY_ID=''
readonly FAKE_MAX_ATTEMPTS=8
mkdir -p "$SOURCE_ROOT/.claude-plugin" "$FAKE_BIN"

printf '%s\n' "$FIXTURE_VERSION" >"$SOURCE_ROOT/VERSION"
jq -n --arg name "$FIXTURE_REPOSITORY" --arg version "$FIXTURE_VERSION" \
  '{name: $name, version: $version}' >"$SOURCE_ROOT/.claude-plugin/plugin.json"
git -C "$SOURCE_ROOT" init -q
git -C "$SOURCE_ROOT" config user.name Fixture
git -C "$SOURCE_ROOT" config user.email fixture@example.com
git -C "$SOURCE_ROOT" add VERSION .claude-plugin/plugin.json
git -C "$SOURCE_ROOT" commit -qm fixture
git -C "$SOURCE_ROOT" tag "$FIXTURE_TAG"
SOURCE_SHA="$(git -C "$SOURCE_ROOT" rev-list -n 1 "$FIXTURE_TAG")"

jq -n \
  --arg name "$FIXTURE_REPOSITORY" \
  --arg sha "$SOURCE_SHA" \
  --arg version "$FIXTURE_VERSION" \
  --arg tag "$FIXTURE_TAG" \
  --argjson release_id "$FIXTURE_RELEASE_ID" \
  '{plugins: [{name: $name, source: {sha: $sha}, metadata: {version: $version, releaseId: $release_id, releaseTag: $tag}, card: {rows: ["one", "two", "three"], run: "Run it"}}]}' \
  >"$MANIFEST"

cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --disable ]] || exit 89
headers=()
request_body=''
audience_option=''
method=''
url=''
is_get=false
fail_with_body=false
output_file=''
dump_header_file=''
write_out=''
while (($# > 0)); do
  case "$1" in
    --disable)
      shift
      ;;
    -H|--header)
      headers+=("$2")
      shift 2
      ;;
    --data-binary)
      request_body="$2"
      shift 2
      ;;
    --data-urlencode)
      audience_option="$2"
      shift 2
      ;;
    --request|-X)
      method="$2"
      shift 2
      ;;
    --get)
      is_get=true
      shift
      ;;
    --fail-with-body)
      fail_with_body=true
      shift
      ;;
    --output|-o)
      output_file="$2"
      shift 2
      ;;
    --dump-header|-D)
      dump_header_file="$2"
      shift 2
      ;;
    --write-out|-w)
      write_out="$2"
      shift 2
      ;;
    --silent|--show-error)
      shift
      ;;
    -*)
      printf 'unexpected curl option: %s\n' "$1" >&2
      exit 90
      ;;
    *)
      [[ -z "$url" ]] || { printf 'multiple curl URLs\n' >&2; exit 91; }
      url="$1"
      shift
      ;;
  esac
done

if [[ "$url" == "$ACTIONS_ID_TOKEN_REQUEST_URL" ]]; then
  printf 'mint\n' >>"$FAKE_CURL_CALLS_FILE"
  mint_index="$(grep -c '^mint$' "$FAKE_CURL_CALLS_FILE")"
  [[ "$is_get" == true && "$fail_with_body" == true && -z "$method" && -z "$request_body" ]] || exit 92
  [[ -z "$output_file" && -z "$dump_header_file" && -z "$write_out" ]] || exit 102
  [[ ${#headers[@]} -eq 1 && "${headers[0]}" == "authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" ]] || exit 93
  [[ "$audience_option" == audience=* ]] || exit 94
  audience="${audience_option#audience=}"
  [[ "$audience" == "$EXPECTED_ENDPOINT#sha256="* ]] || exit 95
  digest="${audience##*#sha256=}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 96
  printf '%s' "$audience" >"$FAKE_CURL_AUDIENCE_FILE"
  printf '%s' "$audience" >"$FAKE_CURL_AUDIENCE_FILE.$mint_index"
  token="fixture-token-$mint_index-$digest"
  printf '%s\n' "$token" >>"$FAKE_CURL_MINTED_TOKENS_FILE"
  printf '{"value":"%s"}' "$token"
  exit 0
fi

if [[ "$url" == "$EXPECTED_ENDPOINT" ]]; then
  printf 'post\n' >>"$FAKE_CURL_CALLS_FILE"
  post_index="$(grep -c '^post$' "$FAKE_CURL_CALLS_FILE")"
  [[ "$is_get" == false && "$method" == POST && -z "$audience_option" ]] || exit 97
  [[ ${#headers[@]} -eq 2 ]] || exit 98
  [[ "${headers[0]}" == 'content-type: application/json' ]] || exit 99
  expected_token="$(sed -n "${post_index}p" "$FAKE_CURL_MINTED_TOKENS_FILE")"
  [[ -n "$expected_token" && "${headers[1]}" == "authorization: Bearer $expected_token" ]] || exit 100
  printf '%s\n' "${headers[1]#authorization: Bearer }" >>"$FAKE_CURL_POST_TOKENS_FILE"
  printf '%s' "$request_body" >"$FAKE_CURL_BODY_FILE"
  printf '%s' "$request_body" >"$FAKE_CURL_BODY_FILE.$post_index"
  printf '%s\n' "${headers[@]}" >"$FAKE_CURL_HEADERS_FILE"
  printf '%s' "$url" >"$FAKE_CURL_URL_FILE"

  status_var="FAKE_POST_STATUS_$post_index"
  response_var="FAKE_RESPONSE_BODY_$post_index"
  retry_present_var="FAKE_RETRY_AFTER_PRESENT_$post_index"
  retry_value_var="FAKE_RETRY_AFTER_$post_index"
  retry_count_var="FAKE_RETRY_AFTER_COUNT_$post_index"
  informational_present_var="FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_$post_index"
  informational_value_var="FAKE_INFORMATIONAL_RETRY_AFTER_$post_index"
  transport_var="FAKE_TRANSPORT_EXIT_$post_index"
  status="${!status_var:-200}"
  response_body="${!response_var-}"
  retry_after_present="${!retry_present_var:-false}"
  retry_after="${!retry_value_var-}"
  retry_after_count="${!retry_count_var:-1}"
  informational_retry_after_present="${!informational_present_var:-false}"
  informational_retry_after="${!informational_value_var-}"
  transport_exit="${!transport_var:-0}"

  if [[ -n "$output_file" || -n "$dump_header_file" || -n "$write_out" ]]; then
    [[ -n "$output_file" && -n "$dump_header_file" && "$write_out" == '%{http_code}' ]] || exit 103
    printf '%s\n%s\n' "$output_file" "$dump_header_file" >>"$FAKE_CURL_RESPONSE_PATHS_FILE"
    printf '%s' "$response_body" >"$output_file"
    : >"$dump_header_file"
    if [[ "$informational_retry_after_present" == true ]]; then
      printf 'HTTP/1.1 103 Early Hints\r\n' >>"$dump_header_file"
      printf 'Retry-After: %s\r\n\r\n' "$informational_retry_after" >>"$dump_header_file"
    fi
    printf 'HTTP/1.1 %s Fixture\r\n' "$status" >>"$dump_header_file"
    if [[ "$retry_after_present" == true ]]; then
      [[ "$retry_after_count" =~ ^[1-9][0-9]*$ ]] || exit 104
      for ((header_index = 0; header_index < retry_after_count; header_index += 1)); do
        printf 'Retry-After: %s\r\n' "$retry_after" >>"$dump_header_file"
      done
    fi
    printf '\r\n' >>"$dump_header_file"
    if [[ "$transport_exit" != 0 ]]; then
      printf '000'
      exit "$transport_exit"
    fi
    printf '%s' "$status"
    exit 0
  fi

  printf '%s' "$response_body"
  if [[ "$fail_with_body" == true && ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    exit 22
  fi
  exit "$transport_exit"
fi

printf 'unexpected:%s\n' "$url" >>"$FAKE_CURL_CALLS_FILE"
printf 'unexpected curl URL: %s\n' "$url" >&2
exit 101
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || exit 110
printf 'sleep\n' >>"$FAKE_CURL_CALLS_FILE"
printf '%s\n' "$1" >>"$FAKE_SLEEP_DELAYS_FILE"
FAKE_SLEEP
chmod +x "$FAKE_BIN/sleep"

reset_capture() {
  local attempt
  : >"$CALLS_FILE"
  : >"$MINTED_TOKENS_FILE"
  : >"$POST_TOKENS_FILE"
  : >"$SLEEP_DELAYS_FILE"
  : >"$RESPONSE_PATHS_FILE"
  rm -f "$BODY_FILE" "$BODY_FILE".* "$HEADERS_FILE" "$URL_FILE" "$AUDIENCE_FILE" "$AUDIENCE_FILE".*
  for ((attempt = 1; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
    printf -v "FAKE_POST_STATUS_$attempt" '%s' 200
    printf -v "FAKE_RESPONSE_BODY_$attempt" '%s' '{"ok":true}'
    printf -v "FAKE_RETRY_AFTER_PRESENT_$attempt" '%s' false
    printf -v "FAKE_RETRY_AFTER_$attempt" '%s' ''
    printf -v "FAKE_RETRY_AFTER_COUNT_$attempt" '%s' 1
    printf -v "FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_$attempt" '%s' false
    printf -v "FAKE_INFORMATIONAL_RETRY_AFTER_$attempt" '%s' ''
    printf -v "FAKE_TRANSPORT_EXIT_$attempt" '%s' 0
  done
  write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$VALID_NOTES" false false
}

write_current_release() {
  jq -n \
    --argjson id "$1" --arg tag_name "$2" --arg body "$3" \
    --argjson draft "$4" --argjson prerelease "$5" \
    '{id: $id, tag_name: $tag_name, body: $body, draft: $draft, prerelease: $prerelease}' \
    >"$CURRENT_RELEASE_FILE"
}

run_helper() {
  local helper="$1" manifest="$2" release_id="$3" latest_id="$4" source_sha="$5"
  local current_release_file="$6" event_action="$7"
  local attempt variable
  local -a fake_response_env=()
  shift 7
  for ((attempt = 1; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
    for variable in FAKE_POST_STATUS FAKE_RESPONSE_BODY FAKE_RETRY_AFTER_PRESENT \
      FAKE_RETRY_AFTER FAKE_RETRY_AFTER_COUNT FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT \
      FAKE_INFORMATIONAL_RETRY_AFTER FAKE_TRANSPORT_EXIT; do
      variable="${variable}_$attempt"
      fake_response_env+=("$variable=${!variable}")
    done
  done
  env \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    EVENT_ACTION="$event_action" \
    REPOSITORY="$RUN_REPOSITORY" \
    GITHUB_REPOSITORY="$RUN_GITHUB_REPOSITORY" \
    GITHUB_REPOSITORY_ID="$RUN_GITHUB_REPOSITORY_ID" \
    RELEASE_ID="$release_id" \
    RELEASE_TAG="$RUN_TAG" \
    CURRENT_RELEASE_FILE="$current_release_file" \
    RELEASE_NOTES="$HYPOTHETICAL_EVENT_NOTES" \
    RELEASE_PRERELEASE=true \
    RELEASE_DRAFT=true \
    LATEST_STABLE_ID="$latest_id" \
    SOURCE_ROOT="$RUN_SOURCE_ROOT" \
    SOURCE_SHA="$source_sha" \
    MARKETPLACE_MANIFEST="$manifest" \
    ACTIONS_ID_TOKEN_REQUEST_URL="$OIDC_URL" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=fixture-request-token \
    EXPECTED_ENDPOINT="$FIXED_ENDPOINT" \
    FAKE_CURL_CALLS_FILE="$CALLS_FILE" \
    FAKE_CURL_BODY_FILE="$BODY_FILE" \
    FAKE_CURL_HEADERS_FILE="$HEADERS_FILE" \
    FAKE_CURL_URL_FILE="$URL_FILE" \
    FAKE_CURL_AUDIENCE_FILE="$AUDIENCE_FILE" \
    FAKE_CURL_MINTED_TOKENS_FILE="$MINTED_TOKENS_FILE" \
    FAKE_CURL_POST_TOKENS_FILE="$POST_TOKENS_FILE" \
    FAKE_CURL_RESPONSE_PATHS_FILE="$RESPONSE_PATHS_FILE" \
    FAKE_SLEEP_DELAYS_FILE="$SLEEP_DELAYS_FILE" \
    "${fake_response_env[@]}" \
    TOOL_RELEASES_ENDPOINT=https://attacker.invalid/constant \
    ANNOUNCE_URL=https://attacker.invalid/env \
    ANNOUNCE_SECRET=legacy-secret-must-be-ignored \
    OIDC_TOKEN=legacy-token-must-be-ignored \
    "$helper" "$@"
}

sha256_file_bytes() {
  local digest
  digest="$(sha256sum "$1")"
  printf '%s\n' "${digest%% *}"
}

assert_response_capture_cleaned() {
  local expected_path_count="$1" label="$2" response_dir response_path
  local -a response_paths
  mapfile -t response_paths <"$RESPONSE_PATHS_FILE"
  [[ ${#response_paths[@]} -eq "$expected_path_count" ]] || die "$label did not capture the expected bounded response context"
  response_dir="$(dirname "${response_paths[0]}")"
  for response_path in "${response_paths[@]}"; do
    [[ "$(dirname "$response_path")" == "$response_dir" ]] || die "$label used response files from different directories"
  done
  [[ ! -e "$response_dir" ]] || die "$label left its response directory behind"
}

assert_one_bound_request() {
  local expected_keys="$1" body_sha
  local -a calls headers
  mapfile -t calls <"$CALLS_FILE"
  [[ ${#calls[@]} -eq 2 && "${calls[0]}" == mint && "${calls[1]}" == post ]] || die "valid fixture did not mint once and POST once"
  [[ "$(<"$URL_FILE")" == "$FIXED_ENDPOINT" ]] || die "request was redirected away from the fixed endpoint"
  mapfile -t headers <"$HEADERS_FILE"
  [[ ${#headers[@]} -eq 2 ]] || die "POST did not have exactly two explicit headers"
  [[ "${headers[0]}" == 'content-type: application/json' && "${headers[1]}" == authorization:\ Bearer\ fixture-token-* ]] || die "POST headers were not content-type plus bearer authentication"
  body_sha="$(sha256_file_bytes "$BODY_FILE")"
  [[ "$(<"$AUDIENCE_FILE")" == "$FIXED_ENDPOINT#sha256=$body_sha" ]] || die "OIDC audience did not bind the exact request bytes"
  [[ "$(jq -c 'keys | sort' "$BODY_FILE")" == "$expected_keys" ]] || die "request body had unexpected keys"
  grep -Fq "::add-mask::fixture-token-1-$body_sha" "$TMP/run-output" || die "OIDC token was not masked before send"
  grep -Fq "$FAKE_RESPONSE_BODY_1" "$TMP/run-output" || die "successful response body was not printed"
  assert_response_capture_cleaned 2 "single-attempt success"
}

VALID_NOTES=$'## Highlights\n- First safe improvement\n- Second exact detail'
HYPOTHETICAL_EVENT_NOTES=$'## Highlights\n- Stale event notes must never win'
reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "valid fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
expected_valid_body='{"operation":"announce","repository":"fixture-tool","releaseId":"42","notesSummary":"First safe improvement\nSecond exact detail"}'
[[ "$(<"$BODY_FILE")" == "$expected_valid_body" ]] || die "valid request body bytes did not contain the exact release ID string"
jq -e \
  --arg repository "$FIXTURE_REPOSITORY" \
  --arg release_id "$FIXTURE_RELEASE_ID" \
  --arg notes $'First safe improvement\nSecond exact detail' \
  '.operation == "announce" and .repository == $repository and .releaseId == $release_id and (.releaseId | type == "string") and .notesSummary == $notes and (.notesSummary | length <= 600)' \
  "$BODY_FILE" >/dev/null || die "valid request body values"
! grep -Fq 'Stale event notes' "$BODY_FILE" || die "hypothetical event notes overrode the current release file"
pass "validated current notes override stale event state in one exact fixed-endpoint request"

baseline_audience="$(<"$AUDIENCE_FILE")"
CHANGED_RELEASE_ID='43'
CHANGED_MANIFEST="$TMP/release-43.json"
jq --argjson release_id "$CHANGED_RELEASE_ID" \
  '(.plugins[0].metadata.releaseId) = $release_id' \
  "$MANIFEST" >"$CHANGED_MANIFEST"
reset_capture
write_current_release "$CHANGED_RELEASE_ID" "$FIXTURE_TAG" "$VALID_NOTES" false false
if ! run_helper "$HELPER" "$CHANGED_MANIFEST" "$CHANGED_RELEASE_ID" "$CHANGED_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "changed release ID fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
expected_changed_body='{"operation":"announce","repository":"fixture-tool","releaseId":"43","notesSummary":"First safe improvement\nSecond exact detail"}'
[[ "$(<"$BODY_FILE")" == "$expected_changed_body" ]] || die "changed request body bytes did not contain the exact release ID string"
changed_audience="$(<"$AUDIENCE_FILE")"
[[ "$changed_audience" != "$baseline_audience" ]] || die "changing releaseId did not change the OIDC audience digest"
pass "changing the exact releaseId string changes the bound OIDC audience digest"

reset_capture
current_release_tmp="$TMP/current-release-null.json"
jq '.body = null' "$CURRENT_RELEASE_FILE" >"$current_release_tmp"
mv "$current_release_tmp" "$CURRENT_RELEASE_FILE"
FAKE_POST_STATUS_1=299
FAKE_RESPONSE_BODY_1='{"ok":true,"status":299}'
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "empty notes fixture"
fi
assert_one_bound_request '["operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == '{"operation":"announce","repository":"fixture-tool","releaseId":"42"}' ]] || die "empty-notes request body was not the exact reduced contract"
pass "empty notes omit notesSummary and a non-200 2xx response succeeds"

LONG_NOTES="$(python3 -c 'print("é" * 700, end="")')"
reset_capture
write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$LONG_NOTES" false false
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "bounded notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
jq -e '.notesSummary | length == 600' "$BODY_FILE" >/dev/null || die "notesSummary was not bounded to 600 BMP characters"
pass "notesSummary is character-safe and bounded"

ASTRAL_NOTES="$(python3 -c 'print("😀" * 301, end="")')"
reset_capture
write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$ASTRAL_NOTES" false false
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "UTF-16 bounded astral notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
python3 - "$BODY_FILE" <<'PY' || die "astral notes exceeded the endpoint UTF-16 limit"
import json
from pathlib import Path
import sys

notes = json.loads(Path(sys.argv[1]).read_text())["notesSummary"]
assert len(notes) == 300
assert len(notes.encode("utf-16-le")) // 2 == 600
PY
pass "astral notes are bounded to the endpoint's 600 UTF-16 units"

plan_response() {
  local attempt="$1" status="$2" retry_after="${3:-}"
  printf -v "FAKE_POST_STATUS_$attempt" '%s' "$status"
  printf -v "FAKE_RESPONSE_BODY_$attempt" '%s' "{\"status\":$status,\"attempt\":$attempt}"
  if [[ -n "$retry_after" ]]; then
    printf -v "FAKE_RETRY_AFTER_PRESENT_$attempt" '%s' true
    printf -v "FAKE_RETRY_AFTER_$attempt" '%s' "$retry_after"
  fi
}

assert_successful_retry() {
  local attempts="$1" label="$2" expected_delays="$3" attempt body_sha response_var token
  local -a calls expected_calls tokens
  mapfile -t calls <"$CALLS_FILE"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    expected_calls+=(mint post)
    ((attempt == attempts)) || expected_calls+=(sleep)
  done
  [[ "${calls[*]}" == "${expected_calls[*]}" ]] || die "$label call order or attempt bound changed"
  [[ "$(<"$SLEEP_DELAYS_FILE")" == "$expected_delays" ]] || die "$label sleep sequence changed"
  mapfile -t tokens <"$MINTED_TOKENS_FILE"
  [[ ${#tokens[@]} -eq "$attempts" && "$(sort -u "$MINTED_TOKENS_FILE" | wc -l)" -eq "$attempts" ]] || die "$label reused an OIDC token"
  cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "$label POST token did not match each fresh mint"
  for token in "${tokens[@]}"; do
    grep -Fq "::add-mask::$token" "$TMP/run-output" || die "$label left a token unmasked"
  done
  for ((attempt = 2; attempt <= attempts; attempt += 1)); do
    cmp -s "$BODY_FILE.1" "$BODY_FILE.$attempt" || die "$label changed request body bytes"
    cmp -s "$AUDIENCE_FILE.1" "$AUDIENCE_FILE.$attempt" || die "$label changed the body-bound audience"
  done
  body_sha="$(sha256_file_bytes "$BODY_FILE.1")"
  [[ "$(<"$AUDIENCE_FILE.1")" == "$FIXED_ENDPOINT#sha256=$body_sha" ]] || die "$label audience did not bind the immutable bytes"
  [[ ! -e "$BODY_FILE.$((attempts + 1))" && ! -e "$AUDIENCE_FILE.$((attempts + 1))" ]] || die "$label created an extra-attempt artifact"
  response_var="FAKE_RESPONSE_BODY_$attempts"
  grep -Fq "${!response_var}" "$TMP/run-output" || die "$label did not print its successful response"
  assert_response_capture_cleaned "$((attempts * 2))" "$label"
}

expect_three_attempt_recovery() {
  local label="$1" action="$2" first_status="$3" second_status="$4"
  reset_capture
  plan_response 1 "$first_status" 4
  plan_response 2 "$second_status" 3
  plan_response 3 200
  if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" "$action" >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  assert_successful_retry 3 "$label" $'8\n5'
  pass "$label succeeds with immutable bytes and fresh corresponding tokens"
}

expect_three_attempt_recovery "repeated 429 -> 429 -> 200 recovery" published 429 429
expect_three_attempt_recovery "repeated 409 -> 409 -> 200 recovery" published 409 409
expect_three_attempt_recovery "mixed 409 -> 429 -> 200 recovery" published 409 429

expect_first_post_failure() {
  local label="$1" status="$2" retry_present="$3" retry_value="$4"
  local retry_count="$5" transport_exit="$6" expected_message="$7" response_body="$8"
  local -a calls minted_tokens

  reset_capture
  FAKE_POST_STATUS_1="$status"
  FAKE_RESPONSE_BODY_1="$response_body"
  FAKE_RETRY_AFTER_PRESENT_1="$retry_present"
  FAKE_RETRY_AFTER_1="$retry_value"
  FAKE_RETRY_AFTER_COUNT_1="$retry_count"
  FAKE_TRANSPORT_EXIT_1="$transport_exit"
  if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
    die "$label unexpectedly succeeded"
  fi

  mapfile -t calls <"$CALLS_FILE"
  [[ "${calls[*]}" == 'mint post' ]] || die "$label caused an unintended retry, mint, or sleep"
  [[ ! -s "$SLEEP_DELAYS_FILE" ]] || die "$label slept before failing"
  mapfile -t minted_tokens <"$MINTED_TOKENS_FILE"
  [[ ${#minted_tokens[@]} -eq 1 ]] || die "$label did not mint exactly once"
  cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "$label POST did not use its freshly minted token"
  grep -Fq "$expected_message" "$TMP/run-output" || die "$label did not print useful failure context"
  assert_response_capture_cleaned 2 "$label"
  pass "$label"
}

expect_invalid_retry_after_table() {
  local status="$1"
  expect_first_post_failure "HTTP $status missing Retry-After" "$status" false '' 1 0 'canonical Retry-After' '{"error":"missing retry delay"}'
  expect_first_post_failure "HTTP $status malformed Retry-After" "$status" true seven 1 0 'canonical Retry-After' '{"error":"malformed delay"}'
  expect_first_post_failure "HTTP $status duplicate Retry-After" "$status" true 7 2 0 'canonical Retry-After' '{"error":"duplicate delay"}'
  expect_first_post_failure "HTTP $status folded Retry-After" "$status" true $'7\r\n 00' 1 0 'canonical Retry-After' '{"error":"obsolete folded value"}'
  expect_first_post_failure "HTTP $status date Retry-After" "$status" true 'Wed, 21 Oct 2015 07:28:00 GMT' 1 0 'canonical Retry-After' '{"error":"HTTP date"}'
  expect_first_post_failure "HTTP $status zero Retry-After" "$status" true 0 1 0 'canonical Retry-After' '{"error":"zero delay"}'
  expect_first_post_failure "HTTP $status leading-zero Retry-After" "$status" true 07 1 0 'canonical Retry-After' '{"error":"leading zero"}'
  expect_first_post_failure "HTTP $status Retry-After above 600" "$status" true 601 1 0 'canonical Retry-After' '{"error":"delay too large"}'
}

for retry_status in 409 429; do
  expect_invalid_retry_after_table "$retry_status"
done

reset_capture
FAKE_POST_STATUS_1=429
FAKE_RESPONSE_BODY_1='{"error":"final response has no delay"}'
FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_1=true
FAKE_INFORMATIONAL_RETRY_AFTER_1=7
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "informational Retry-After unexpectedly authorized a retry"
fi
mapfile -t informational_calls <"$CALLS_FILE"
[[ "${informational_calls[*]}" == 'mint post' ]] || die "an informational Retry-After authorized a retry for the final 429"
[[ ! -s "$SLEEP_DELAYS_FILE" ]] || die "an informational Retry-After reached sleep"
grep -Fq 'canonical Retry-After' "$TMP/run-output" || die "missing final-response Retry-After did not print useful context"
assert_response_capture_cleaned 2 "informational Retry-After"
pass "Retry-After from an earlier HTTP block cannot authorize a final 429 retry"

reset_capture
plan_response 1 409 4
plan_response 2 200
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" edited >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "canonical 409 recovery fixture"
fi
assert_successful_retry 2 "canonical edited 409 recovery" 8
pass "an edited event accepts canonical 409 recovery"

reset_capture
for ((attempt = 1; attempt < FAKE_MAX_ATTEMPTS; attempt += 1)); do
  if ((attempt == 1)); then
    plan_response "$attempt" 409 3
  else
    plan_response "$attempt" 429 3
  fi
done
plan_response "$FAKE_MAX_ATTEMPTS" 200
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" edited >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "edited exact attempt-eight success fixture"
fi
assert_successful_retry 8 "edited 409 + six 429 + attempt-eight success" $'7\n5\n8\n7\n8\n5\n5'
pass "an edited event succeeds exactly on attempt eight without ninth-attempt artifacts"

expect_first_post_failure \
  "HTTP 401 is rejected without retry" \
  401 false '' 1 0 'HTTP 401' '{"error":"unauthorized"}'
expect_first_post_failure \
  "HTTP 403 is rejected without retry" \
  403 false '' 1 0 'HTTP 403' '{"error":"forbidden"}'
expect_first_post_failure \
  "redirect response is rejected without following or retrying" \
  302 false '' 1 0 'HTTP 302' '{"error":"redirect refused"}'

bounded_503_body="prefix-visible-$(python3 -c 'print("x" * 3000, end="")')-tail-must-not-print"
expect_first_post_failure \
  "HTTP 503 is rejected without retry and with bounded context" \
  503 false '' 1 0 'HTTP 503' "$bounded_503_body"
grep -Fq 'prefix-visible-' "$TMP/run-output" || die "HTTP 503 context omitted the bounded response prefix"
grep -Fq 'response body truncated' "$TMP/run-output" || die "HTTP 503 context did not report truncation"
! grep -Fq 'tail-must-not-print' "$TMP/run-output" || die "HTTP 503 context exceeded its fixed bound"

expect_first_post_failure \
  "curl transport failure is rejected without retry" \
  200 false '' 1 7 'transport failure (curl exit 7)' '{"error":"partial transport body"}'

reset_capture
for ((attempt = 1; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
  printf -v "FAKE_POST_STATUS_$attempt" '%s' 429
  printf -v "FAKE_RESPONSE_BODY_$attempt" '%s' "{\"error\":\"lease $attempt\"}"
  printf -v "FAKE_RETRY_AFTER_PRESENT_$attempt" '%s' true
  printf -v "FAKE_RETRY_AFTER_$attempt" '%s' 3
done
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "eight retryable responses unexpectedly succeeded"
fi
mapfile -t exhausted_calls <"$CALLS_FILE"
[[ "${exhausted_calls[*]}" == 'mint post sleep mint post sleep mint post sleep mint post sleep mint post sleep mint post sleep mint post sleep mint post' ]] || die "retry exhaustion crossed the eight-attempt boundary"
[[ "$(<"$SLEEP_DELAYS_FILE")" == $'7\n5\n8\n7\n8\n5\n5' ]] || die "retry exhaustion jitter sequence was not deterministic and bounded"
mapfile -t exhausted_tokens <"$MINTED_TOKENS_FILE"
[[ ${#exhausted_tokens[@]} -eq 8 && "$(sort -u "$MINTED_TOKENS_FILE" | wc -l)" -eq 8 ]] || die "retry exhaustion did not mint eight distinct tokens"
cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "retry exhaustion POST token did not match each fresh mint"
for ((attempt = 2; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
  cmp -s "$BODY_FILE.1" "$BODY_FILE.$attempt" || die "retry exhaustion changed request body bytes"
  cmp -s "$AUDIENCE_FILE.1" "$AUDIENCE_FILE.$attempt" || die "retry exhaustion changed the body-bound audience"
done
[[ ! -e "$BODY_FILE.9" && ! -e "$AUDIENCE_FILE.9" ]] || die "retry exhaustion created ninth-attempt artifacts"
grep -Fq 'exhausted 8 attempts' "$TMP/run-output" || die "retry exhaustion did not print the attempt budget"
assert_response_capture_cleaned 16 "retry exhaustion"
pass "eight retryable responses exhaust the budget without a ninth mint, POST, or sleep"

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published 'https://attacker.invalid/argument' >"$TMP/run-output" 2>&1; then
  die "alternate URL argument unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "alternate URL argument reached curl"
pass "alternate URL argument is rejected before mint or send"

expect_invalid_id_no_http() {
  local label="$1" release_id="$2" latest_id="$3" expected_message="$4"
  reset_capture
  if run_helper "$HELPER" "$MANIFEST" "$release_id" "$latest_id" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
    die "$label unexpectedly succeeded"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  grep -Fxq "error: $expected_message" "$TMP/run-output" || die "$label did not emit the deterministic validation error"
  pass "$label fails before mint or send"
}

release_id_error='RELEASE_ID must be a positive canonical decimal integer'
latest_id_error='LATEST_STABLE_ID must be a positive canonical decimal integer'
expect_invalid_id_no_http "zero RELEASE_ID" 0 "$FIXTURE_RELEASE_ID" "$release_id_error"
expect_invalid_id_no_http "leading-zero RELEASE_ID" 042 "$FIXTURE_RELEASE_ID" "$release_id_error"
expect_invalid_id_no_http "malformed RELEASE_ID" invalid "$FIXTURE_RELEASE_ID" "$release_id_error"
expect_invalid_id_no_http "zero LATEST_STABLE_ID" "$FIXTURE_RELEASE_ID" 0 "$latest_id_error"
expect_invalid_id_no_http "leading-zero LATEST_STABLE_ID" "$FIXTURE_RELEASE_ID" 042 "$latest_id_error"
expect_invalid_id_no_http "malformed LATEST_STABLE_ID" "$FIXTURE_RELEASE_ID" invalid "$latest_id_error"

expect_current_release_noop() {
  local label="$1" draft="$2" prerelease="$3"
  reset_capture
  write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$VALID_NOTES" "$draft" "$prerelease"
  if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" edited >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  grep -Fq 'prerelease or draft release ignored' "$TMP/run-output" || die "$label did not report its soft no-op"
  pass "$label soft-no-ops before mint or send"
}

expect_invalid_current_release() {
  local label="$1" filter="$2" invalid_file="$TMP/invalid-current-release.json"
  reset_capture
  jq "$filter" "$CURRENT_RELEASE_FILE" >"$invalid_file"
  mv "$invalid_file" "$CURRENT_RELEASE_FILE"
  if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
    die "$label unexpectedly succeeded"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  grep -Fq 'current release record is invalid or does not match expected identity' "$TMP/run-output" || die "$label did not fail closed"
  pass "$label fails before mint or send"
}

expect_current_release_noop "current prerelease" false true
expect_current_release_noop "current draft" true false
expect_invalid_current_release "mismatched current release ID" '.id = 43'
expect_invalid_current_release "mismatched current release tag" '.tag_name = "v9.9.9"'
expect_invalid_current_release "nonobject current release" '[.]'
expect_invalid_current_release "zero current release ID" '.id = 0'
expect_invalid_current_release "missing current release body" 'del(.body)'
expect_invalid_current_release "nonstring current release body" '.body = {}'
expect_invalid_current_release "nonboolean current release draft" '.draft = "false"'
expect_invalid_current_release "nonboolean current release prerelease" '.prerelease = 0'
expect_invalid_current_release "multiple current release records" '., .'

reset_capture
json_code_marker="$TMP/current-release-code-ran"
json_code_bullet="\$(touch $json_code_marker)"
write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "## Highlights
- $json_code_bullet" false false
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "current release code-like notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
[[ ! -e "$json_code_marker" ]] || die "executable code came from current release JSON"
jq -e --arg notes "$json_code_bullet" '.notesSummary == $notes' "$BODY_FILE" >/dev/null || die "code-like current notes were not inert data"
pass "current release JSON remains inert data and cannot change endpoint or audience"

expect_soft_no_http() {
  local label="$1" manifest="$2" latest_id="$3" reason="${4:-}"
  reset_capture
  if ! run_helper "$HELPER" "$manifest" "$FIXTURE_RELEASE_ID" "$latest_id" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  # A skip that returns 0 is indistinguishable from a successful post unless it
  # says so loudly. Assert BOTH the human-visible error annotation and the
  # stable machine-readable marker, so this can never quietly regress to the
  # ::notice:: that made "green run, no card posted" the default outcome.
  if [[ -n "$reason" ]]; then
    grep -q "status=not-announced reason=$reason" "$TMP/run-output" \
      || die "$label did not emit the not-announced marker for reason=$reason"
    grep -q '::error title=Not announced::' "$TMP/run-output" \
      || die "$label skipped the announce without an error annotation"
    pass "$label reports not-announced loudly (reason=$reason)"
  fi
  pass "$label does not mint or send"
}

jq '(.plugins[0].name) = "other-tool"' "$MANIFEST" >"$TMP/mismatch-name.json"
expect_soft_no_http "manifest name mismatch" "$TMP/mismatch-name.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].source.sha) = "0000000000000000000000000000000000000000"' "$MANIFEST" >"$TMP/mismatch-sha.json"
expect_soft_no_http "manifest source SHA mismatch" "$TMP/mismatch-sha.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].metadata.version) = "9.9.9"' "$MANIFEST" >"$TMP/mismatch-version.json"
expect_soft_no_http "manifest version mismatch" "$TMP/mismatch-version.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].metadata.releaseId) = 43' "$MANIFEST" >"$TMP/mismatch-release-id.json"
expect_soft_no_http "manifest release ID mismatch" "$TMP/mismatch-release-id.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].metadata.releaseTag) = "v9.9.9"' "$MANIFEST" >"$TMP/mismatch-release-tag.json"
expect_soft_no_http "manifest release tag mismatch" "$TMP/mismatch-release-tag.json" "$FIXTURE_RELEASE_ID" not-listed

jq 'del(.plugins[0].card) | .plugins += [(.plugins[0] | .source.sha = "0000000000000000000000000000000000000000" | .card = {rows: ["wrong", "tuple", "card"], run: "No"})]' "$MANIFEST" >"$TMP/mismatch-card.json"
expect_soft_no_http "card on a nonmatching tuple" "$TMP/mismatch-card.json" "$FIXTURE_RELEASE_ID" no-card

expect_soft_no_http "non-latest stable release" "$MANIFEST" 43

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" '0000000000000000000000000000000000000000' "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "tag/source SHA mismatch unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "tag/source SHA mismatch minted or sent a request"
pass "tag-resolved source SHA mismatch fails before mint or send"

body_mutant="$TMP/helper-altered-body.sh"
replace_once "$HELPER" "$body_mutant" \
  'send_request "$request_body" "$request_sha" "$oidc_token"' \
  'send_request "${request_body}x" "$request_sha" "$oidc_token"'
chmod +x "$body_mutant"
expect_contract_reject "post-mint body substitution" "$WORKFLOW" "$body_mutant"
reset_capture
if run_helper "$body_mutant" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "post-mint body mutation unexpectedly succeeded"
fi
mapfile -t mutation_calls <"$CALLS_FILE"
[[ ${#mutation_calls[@]} -eq 1 && "${mutation_calls[0]}" == mint ]] || die "post-mint body mutation reached the endpoint"
grep -Fq 'request body changed after OIDC mint' "$TMP/run-output" || die "post-mint body mutation did not hit the digest guard"
pass "post-mint body alteration is rejected before POST"

# --- Monorepo releases on <name>--v<version> tags -----------------------------
# One repository hosts several plugins under plugins/<name>/ and releases each on
# a <name>--v<version> tag. REPOSITORY stays the repository name (the workflow's
# concurrency group and the retry jitter seed); the helper derives the plugin
# name and directory from the tag, verifies the release against that directory,
# matches the marketplace entry by plugin name and sends the plugin name in the
# request body. The monorepo root deliberately has no VERSION and no plugin
# manifest, so a root read cannot pass by accident.
MONOREPO_REPOSITORY='fixture-monorepo'
MONOREPO="$TMP/monorepo"
MONO_MANIFEST="$TMP/monorepo-marketplace.json"
PRO_GATE_VERSION='0.66.0'
HOVSTACK_VERSION='0.1.0'
PLANTED_VERSION='1.0.0'
PRO_GATE_RELEASE_ID='7'
HOVSTACK_RELEASE_ID='8'
PLANTED_RELEASE_ID='9'
BADSHAPE_VERSION='2.0.0'
BADSHAPE_RELEASE_ID='10'
write_monorepo_plugin() {
  local name="$1" version="$2"
  mkdir -p "$MONOREPO/plugins/$name/.claude-plugin"
  printf '%s\n' "$version" >"$MONOREPO/plugins/$name/VERSION"
  jq -n --arg name "$name" --arg version "$version" \
    '{name: $name, version: $version}' >"$MONOREPO/plugins/$name/.claude-plugin/plugin.json"
}
write_monorepo_plugin pro-gate "$PRO_GATE_VERSION"
write_monorepo_plugin hov-stack "$HOVSTACK_VERSION"
# Planted: a directory whose name carries the tag separator, complete with a
# VERSION, a plugin manifest, a tag and (below) a carded marketplace entry, so
# the name rule is the only thing between it and an announce.
write_monorepo_plugin x--v1 "$PLANTED_VERSION"
# Planted: a name the endpoint's shape rule refuses (an underscore), likewise
# complete, so the shape rule is the only thing between it and an announce.
write_monorepo_plugin pro_gate "$BADSHAPE_VERSION"
git -C "$MONOREPO" init -q
git -C "$MONOREPO" config user.name Fixture
git -C "$MONOREPO" config user.email fixture@example.com
git -C "$MONOREPO" add plugins
git -C "$MONOREPO" commit -qm 'monorepo fixture'
git -C "$MONOREPO" tag "pro-gate--v$PRO_GATE_VERSION"
git -C "$MONOREPO" tag "hov-stack--v$HOVSTACK_VERSION"
git -C "$MONOREPO" tag "x--v1--v$PLANTED_VERSION"
git -C "$MONOREPO" tag "pro_gate--v$BADSHAPE_VERSION"
# The same commit under a tag whose version disagrees with plugins/pro-gate/VERSION.
git -C "$MONOREPO" tag 'pro-gate--v0.67.0'
MONOREPO_SHA="$(git -C "$MONOREPO" rev-parse HEAD)"
jq -n \
  --arg sha "$MONOREPO_SHA" \
  --arg pro_gate_version "$PRO_GATE_VERSION" --argjson pro_gate_release_id "$PRO_GATE_RELEASE_ID" \
  --arg hovstack_version "$HOVSTACK_VERSION" --argjson hovstack_release_id "$HOVSTACK_RELEASE_ID" \
  --arg planted_version "$PLANTED_VERSION" --argjson planted_release_id "$PLANTED_RELEASE_ID" \
  --arg badshape_version "$BADSHAPE_VERSION" --argjson badshape_release_id "$BADSHAPE_RELEASE_ID" \
  'def entry($name; $version; $release_id):
     {name: $name,
      source: {source: "git-subdir", url: "https://github.com/fixture-owner/fixture-monorepo.git", path: ("plugins/" + $name), sha: $sha},
      metadata: {version: $version, releaseId: $release_id, releaseTag: ($name + "--v" + $version)},
      card: {rows: ["one", "two", "three"], run: "Run it"}};
   {plugins: [
     entry("pro-gate"; $pro_gate_version; $pro_gate_release_id),
     entry("hov-stack"; $hovstack_version; $hovstack_release_id),
     entry("x--v1"; $planted_version; $planted_release_id),
     entry("pro_gate"; $badshape_version; $badshape_release_id)
   ]}' >"$MONO_MANIFEST"

# Runs the helper as the monorepo's release workflow would: REPOSITORY is the
# repository, the tag selects the plugin. Dynamic scope hands the overrides to
# run_helper and restores the per-plugin fixture on return. reset_capture
# rewrites the current-release file for the per-plugin fixture, so the
# monorepo release is written after it. The optional draft, prerelease and
# latest-stable id arguments reach the helper's no-op branches.
run_monorepo() {
  local helper="$1" tag="$2" release_id="$3" manifest="$4"
  local draft="${5:-false}" prerelease="${6:-false}" latest_id="${7:-$3}"
  local RUN_REPOSITORY="$MONOREPO_REPOSITORY" RUN_TAG="$tag" RUN_SOURCE_ROOT="$MONOREPO"
  reset_capture
  write_current_release "$release_id" "$tag" "$VALID_NOTES" "$draft" "$prerelease"
  run_helper "$helper" "$manifest" "$release_id" "$latest_id" "$MONOREPO_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1
}

PRO_GATE_BODY='{"operation":"announce","repository":"pro-gate","releaseId":"7","notesSummary":"First safe improvement\nSecond exact detail"}'
HOVSTACK_BODY='{"operation":"announce","repository":"hov-stack","releaseId":"8","notesSummary":"First safe improvement\nSecond exact detail"}'
PLANTED_REFUSAL='contains --, the release tag separator: x--v1'
PLANTED_BODY='{"operation":"announce","repository":"x--v1","releaseId":"9","notesSummary":"First safe improvement\nSecond exact detail"}'
BADSHAPE_BODY='{"operation":"announce","repository":"pro_gate","releaseId":"10","notesSummary":"First safe improvement\nSecond exact detail"}'
BADSHAPE_REFUSAL='has an invalid shape: pro_gate'

if ! run_monorepo "$HELPER" "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$MONO_MANIFEST"; then
  command cat "$TMP/run-output" >&2
  die "monorepo pro-gate fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == "$PRO_GATE_BODY" ]] || die "monorepo request body did not carry the plugin name pro-gate"
pass "pro-gate--v$PRO_GATE_VERSION on the monorepo verifies plugins/pro-gate/VERSION and sends repository=pro-gate while REPOSITORY is $MONOREPO_REPOSITORY"

if ! run_monorepo "$HELPER" "hov-stack--v$HOVSTACK_VERSION" "$HOVSTACK_RELEASE_ID" "$MONO_MANIFEST"; then
  command cat "$TMP/run-output" >&2
  die "monorepo hov-stack fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == "$HOVSTACK_BODY" ]] || die "monorepo request body did not carry the skill pack name hov-stack"
pass "hov-stack--v$HOVSTACK_VERSION on the monorepo names the skill pack from plugins/hov-stack/VERSION"

if run_monorepo "$HELPER" 'pro-gate--v0.67.0' "$PRO_GATE_RELEASE_ID" "$MONO_MANIFEST"; then
  die "a prefixed tag whose version disagrees with plugins/pro-gate/VERSION unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "version disagreement minted or sent a request"
grep -Fq "release tag pro-gate--v0.67.0 does not match VERSION $PRO_GATE_VERSION" "$TMP/run-output" \
  || die "version disagreement did not name the version read from plugins/pro-gate/VERSION"
pass "a prefixed tag whose version disagrees with the plugin directory's VERSION fails before mint, naming that VERSION"

if run_monorepo "$HELPER" "x--v1--v$PLANTED_VERSION" "$PLANTED_RELEASE_ID" "$MONO_MANIFEST"; then
  die "the planted x--v1 directory was announced"
fi
[[ ! -s "$CALLS_FILE" ]] || die "the planted x--v1 directory minted or sent a request"
grep -Fq "$PLANTED_REFUSAL" "$TMP/run-output" || die "the planted x--v1 directory was not refused by name"
pass "x--v1--v$PLANTED_VERSION is refused as a plugin name although plugins/x--v1 and its carded entry exist"

if run_monorepo "$HELPER" "pro_gate--v$BADSHAPE_VERSION" "$BADSHAPE_RELEASE_ID" "$MONO_MANIFEST"; then
  die "the planted pro_gate directory was announced"
fi
[[ ! -s "$CALLS_FILE" ]] || die "the planted pro_gate directory minted or sent a request"
grep -Fq "plugin name derived from release tag pro_gate--v$BADSHAPE_VERSION $BADSHAPE_REFUSAL" "$TMP/run-output" \
  || die "the planted pro_gate directory was not refused by the shape rule"
pass "pro_gate--v$BADSHAPE_VERSION is refused by the endpoint's name shape although plugins/pro_gate and its carded entry exist"

if run_monorepo "$HELPER" '--v1.0.0' "$PRO_GATE_RELEASE_ID" "$MONO_MANIFEST"; then
  die "a tag with nothing before its separator was announced"
fi
[[ ! -s "$CALLS_FILE" ]] || die "a tag with nothing before its separator minted or sent a request"
grep -Fq 'plugin name derived from release tag --v1.0.0 has an invalid shape' "$TMP/run-output" \
  || die "a tag with nothing before its separator was not refused by the shape rule"
pass "--v1.0.0 derives an empty name and is refused by the shape rule before mint"

if run_monorepo "$HELPER" 'pro-gate--vnext' "$PRO_GATE_RELEASE_ID" "$MONO_MANIFEST"; then
  die "a prefixed tag with no version after its separator was announced"
fi
[[ ! -s "$CALLS_FILE" ]] || die "a prefixed tag with no version after its separator minted or sent a request"
grep -Fq 'release tag pro-gate--vnext has no version after its last --v' "$TMP/run-output" \
  || die "a prefixed tag with no version after its separator was not refused by name"
pass "pro-gate--vnext is refused before mint because nothing numeric follows its last --v"

if run_monorepo "$HELPER" "pro-gates--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$MONO_MANIFEST"; then
  die "a tag naming a plugin directory that does not exist was announced"
fi
[[ ! -s "$CALLS_FILE" ]] || die "a tag naming a missing plugin directory minted or sent a request"
grep -Fq "no VERSION file at $MONOREPO/plugins/pro-gates for release tag pro-gates--v$PRO_GATE_VERSION" "$TMP/run-output" \
  || die "a tag naming a missing plugin directory did not fail with the directory named"
pass "pro-gates--v$PRO_GATE_VERSION fails before mint naming the missing plugins/pro-gates/VERSION"

if ! run_monorepo "$HELPER" "x--v1--v$PLANTED_VERSION" "$PLANTED_RELEASE_ID" "$MONO_MANIFEST" true false; then
  command cat "$TMP/run-output" >&2
  die "a draft release with the planted tag did not stay a no-op"
fi
[[ ! -s "$CALLS_FILE" ]] || die "a draft release with the planted tag minted or sent a request"
grep -Fq 'prerelease or draft release ignored' "$TMP/run-output" || die "a draft release with the planted tag was not reported as ignored"
! grep -Fq "$PLANTED_REFUSAL" "$TMP/run-output" || die "a draft release with the planted tag was refused as a plugin name"
pass "a draft release tagged x--v1--v$PLANTED_VERSION is ignored before the name is derived"

if ! run_monorepo "$HELPER" "x--v1--v$PLANTED_VERSION" "$PLANTED_RELEASE_ID" "$MONO_MANIFEST" false false "$PRO_GATE_RELEASE_ID"; then
  command cat "$TMP/run-output" >&2
  die "a non-latest release with the planted tag did not stay a no-op"
fi
[[ ! -s "$CALLS_FILE" ]] || die "a non-latest release with the planted tag minted or sent a request"
grep -Fq "release $PLANTED_RELEASE_ID is not latest stable $PRO_GATE_RELEASE_ID; no-op" "$TMP/run-output" \
  || die "a non-latest release with the planted tag was not reported as a no-op"
! grep -Fq "$PLANTED_REFUSAL" "$TMP/run-output" || die "a non-latest release with the planted tag was refused as a plugin name"
pass "a non-latest release tagged x--v1--v$PLANTED_VERSION is a no-op before the name is derived"

jq '(.plugins[] | select(.name == "pro-gate") | .name) = "fixture-monorepo"' "$MONO_MANIFEST" >"$TMP/monorepo-by-repository-name.json"
if ! run_monorepo "$HELPER" "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$TMP/monorepo-by-repository-name.json"; then
  command cat "$TMP/run-output" >&2
  die "monorepo entry under the repository name"
fi
[[ ! -s "$CALLS_FILE" ]] || die "an entry listed under the repository name minted or sent a request"
grep -Fq "status=not-announced reason=not-listed repository=$MONOREPO_REPOSITORY tag=pro-gate--v$PRO_GATE_VERSION plugin=pro-gate" "$TMP/run-output" \
  || die "an entry listed under the repository name was not reported as not-listed with both names"
pass "an entry listed under the repository name instead of the plugin name is not-listed, and the marker carries both names"

# Each mutant disables one derivation rule in a copy of the helper. The static
# contract must reject the copy, and the monorepo case it targets must change
# against it in the way the rule's removal predicts: an announce case no longer
# produces the exact body; a refusal case either announces the planted
# directory with the exact body, or fails later for a named different reason
# with nothing minted.
expect_mutant_breaks_announce() {
  local label="$1" old="$2" new="$3" tag="$4" release_id="$5" expected_body="$6"
  local mutant="$TMP/helper-$label.sh"
  replace_once "$HELPER" "$mutant" "$old" "$new"
  chmod +x "$mutant"
  expect_contract_reject "$label" "$WORKFLOW" "$mutant"
  if run_monorepo "$mutant" "$tag" "$release_id" "$MONO_MANIFEST" && [[ -s "$BODY_FILE" && "$(<"$BODY_FILE")" == "$expected_body" ]]; then
    die "$label mutant still announced the exact monorepo body for $tag"
  fi
  pass "$label mutant no longer announces $tag with the exact body"
}

# The guard that refuses a planted directory is removed; the planted case must
# then announce with the exact body, which proves that the guard alone refuses
# it and that nothing downstream would catch it.
expect_mutant_announces() {
  local label="$1" old="$2" new="$3" tag="$4" release_id="$5" expected_body="$6"
  local mutant="$TMP/helper-$label.sh"
  replace_once "$HELPER" "$mutant" "$old" "$new"
  chmod +x "$mutant"
  expect_contract_reject "$label" "$WORKFLOW" "$mutant"
  if ! run_monorepo "$mutant" "$tag" "$release_id" "$MONO_MANIFEST"; then
    command cat "$TMP/run-output" >&2
    die "$label mutant did not announce $tag"
  fi
  assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
  [[ "$(<"$BODY_FILE")" == "$expected_body" ]] || die "$label mutant announced $tag with an unexpected body"
  pass "$label mutant announces $tag with the exact body, so that rule alone refuses it"
}

# The rule is removed and the case still fails, but later and for a different
# reason: the named reason must be absent, the other reason present and nothing
# minted, so a weaker rule cannot hide behind a later failure.
expect_mutant_fails_elsewhere() {
  local label="$1" old="$2" new="$3" tag="$4" release_id="$5" named_reason="$6" other_reason="$7"
  local mutant="$TMP/helper-$label.sh"
  replace_once "$HELPER" "$mutant" "$old" "$new"
  chmod +x "$mutant"
  expect_contract_reject "$label" "$WORKFLOW" "$mutant"
  if run_monorepo "$mutant" "$tag" "$release_id" "$MONO_MANIFEST"; then
    die "$label mutant announced $tag"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label mutant minted or sent a request for $tag"
  ! grep -Fq "$named_reason" "$TMP/run-output" || die "$label mutant still refused $tag for the named reason"
  grep -Fq "$other_reason" "$TMP/run-output" || die "$label mutant did not fail $tag for the expected other reason"
  pass "$label mutant fails $tag later and for a different reason, so the named rule is what refuses it"
}

expect_mutant_breaks_announce body-on-repository-name \
  $'    --arg repository "$PLUGIN_NAME" \\' \
  $'    --arg repository "$REPOSITORY" \\' \
  "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$PRO_GATE_BODY"
expect_mutant_breaks_announce listed-on-repository-name \
  $'  require MARKETPLACE_MANIFEST\n  jq -e \\\n    --arg name "$PLUGIN_NAME" \\' \
  $'  require MARKETPLACE_MANIFEST\n  jq -e \\\n    --arg name "$REPOSITORY" \\' \
  "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$PRO_GATE_BODY"
expect_mutant_breaks_announce root-version-read \
  'plugin_root="$SOURCE_ROOT${PLUGIN_DIR:+/$PLUGIN_DIR}"' \
  'plugin_root="$SOURCE_ROOT"' \
  "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$PRO_GATE_BODY"
expect_mutant_breaks_announce unprefixed-expected-tag \
  'expected_tag="${TAG_PREFIX}v$version"' \
  'expected_tag="v$version"' \
  "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$PRO_GATE_BODY"
expect_mutant_breaks_announce plugin-dir-on-repository-name \
  '    PLUGIN_DIR="plugins/$PLUGIN_NAME"' \
  '    PLUGIN_DIR="plugins/$REPOSITORY"' \
  "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$PRO_GATE_BODY"
expect_mutant_breaks_announce empty-tag-prefix \
  '    TAG_PREFIX="$PLUGIN_NAME--"' \
  '    TAG_PREFIX=""' \
  "pro-gate--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" "$PRO_GATE_BODY"
expect_mutant_announces double-hyphen-name-allowed \
  '    [[ "$PLUGIN_NAME" != *--* ]] || fail "plugin name derived from release tag $RELEASE_TAG contains --, the release tag separator: $PLUGIN_NAME"' \
  '    true' \
  "x--v1--v$PLANTED_VERSION" "$PLANTED_RELEASE_ID" "$PLANTED_BODY"
expect_mutant_announces shape-rule-removed \
  '    [[ "$PLUGIN_NAME" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "plugin name derived from release tag $RELEASE_TAG has an invalid shape: $PLUGIN_NAME"' \
  '    true' \
  "pro_gate--v$BADSHAPE_VERSION" "$BADSHAPE_RELEASE_ID" "$BADSHAPE_BODY"
expect_mutant_fails_elsewhere split-on-first-separator \
  'PLUGIN_NAME="${RELEASE_TAG%--v*}"' \
  'PLUGIN_NAME="${RELEASE_TAG%%--v*}"' \
  "x--v1--v$PLANTED_VERSION" "$PLANTED_RELEASE_ID" "$PLANTED_REFUSAL" \
  "no VERSION file at $MONOREPO/plugins/x for release tag x--v1--v$PLANTED_VERSION"
expect_mutant_fails_elsewhere version-digit-rule-removed \
  '    [[ "${RELEASE_TAG##*--v}" == [0-9]* ]] || fail "release tag $RELEASE_TAG has no version after its last --v"' \
  '    true' \
  'pro-gate--vnext' "$PRO_GATE_RELEASE_ID" 'has no version after its last --v' \
  "release tag pro-gate--vnext does not match VERSION $PRO_GATE_VERSION"
expect_mutant_fails_elsewhere version-file-guard-removed \
  '  [[ -f "$plugin_root/VERSION" ]] || fail "no VERSION file at $plugin_root for release tag $RELEASE_TAG"' \
  '  true' \
  "pro-gates--v$PRO_GATE_VERSION" "$PRO_GATE_RELEASE_ID" 'no VERSION file at' \
  "no plugin manifest at $MONOREPO/plugins/pro-gates for release tag pro-gates--v$PRO_GATE_VERSION"

# Moving derivation ahead of the no-ops would make a draft release with a
# malformed tag fail instead of being ignored. Two replacements move the call
# to just after the current release is loaded.
ordering_mutant="$TMP/helper-derive-before-no-ops.sh"
replace_once "$HELPER" "$TMP/helper-derive-before-no-ops.step1" \
  $'  require CURRENT_RELEASE_FILE\n  load_current_release\n' \
  $'  require CURRENT_RELEASE_FILE\n  load_current_release\n  derive_plugin_identity\n'
replace_once "$TMP/helper-derive-before-no-ops.step1" "$ordering_mutant" \
  $'  derive_plugin_identity\n  RELEASE_VERSION="$(verify_release)"' \
  $'  RELEASE_VERSION="$(verify_release)"'
chmod +x "$ordering_mutant"
expect_contract_reject derive-before-no-ops "$WORKFLOW" "$ordering_mutant"
if run_monorepo "$ordering_mutant" "x--v1--v$PLANTED_VERSION" "$PLANTED_RELEASE_ID" "$MONO_MANIFEST" true false; then
  die "derive-before-no-ops mutant still ignored a draft release with the planted tag"
fi
[[ ! -s "$CALLS_FILE" ]] || die "derive-before-no-ops mutant minted or sent a request for a draft release"
grep -Fq "$PLANTED_REFUSAL" "$TMP/run-output" || die "derive-before-no-ops mutant did not refuse the draft release's planted tag"
pass "derive-before-no-ops mutant refuses a draft release with the planted tag, so the no-ops stay ahead of derivation"

# ---------------------------------------------------------------------------
# Product lane. A product (HoV Router) is a repository named in the helper's
# product table by full name and repository id. It has no VERSION file, no
# plugin manifest and no marketplace entry, and releases on plain vX.Y.Z tags.
# Detection keys on GITHUB_REPOSITORY plus GITHUB_REPOSITORY_ID, never on the
# bare REPOSITORY name that any repository can share.
# ---------------------------------------------------------------------------
PRODUCT_FULL_NAME='StartupBros/hov-router'
PRODUCT_REPO_ID='1278801682'
PRODUCT_NAME='hov-router'
PRODUCT_TAG='v3.7.1'
PRODUCT_RELEASE_ID='2001'
PRODUCT_SOURCE="$TMP/product-source"
PRODUCT_MANIFEST="$TMP/product-marketplace.json"
mkdir -p "$PRODUCT_SOURCE"
printf '%s\n' '{"plugins":[]}' >"$PRODUCT_MANIFEST"
[[ ! -e "$PRODUCT_SOURCE/VERSION" && ! -e "$PRODUCT_SOURCE/.claude-plugin" ]] || die "product fixture must have no VERSION or plugin manifest"
PRODUCT_BODY='{"operation":"announce","repository":"hov-router","releaseId":"2001","notesSummary":"First safe improvement\nSecond exact detail"}'

# Positional: tag, GITHUB_REPOSITORY, GITHUB_REPOSITORY_ID, then optional draft,
# prerelease, latest-stable id, event action and REPOSITORY (the bare name).
run_product() {
  local tag="$1" github_repository="$2" github_repository_id="$3"
  local draft="${4:-false}" prerelease="${5:-false}" latest_id="${6:-$PRODUCT_RELEASE_ID}"
  local action="${7:-published}" bare_name="${8:-$PRODUCT_NAME}"
  local helper="${PRODUCT_HELPER:-$HELPER}"
  local RUN_REPOSITORY="$bare_name" RUN_TAG="$tag" RUN_SOURCE_ROOT="$PRODUCT_SOURCE"
  local RUN_GITHUB_REPOSITORY="$github_repository" RUN_GITHUB_REPOSITORY_ID="$github_repository_id"
  reset_capture
  write_current_release "$PRODUCT_RELEASE_ID" "$tag" "$VALID_NOTES" "$draft" "$prerelease"
  run_helper "$helper" "$PRODUCT_MANIFEST" "$PRODUCT_RELEASE_ID" "$latest_id" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" "$action" >"$TMP/run-output" 2>&1
}

assert_no_request() {
  [[ ! -s "$CALLS_FILE" ]] || die "$1 minted or sent a request"
}

if ! run_product "$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID"; then
  command cat "$TMP/run-output" >&2
  die "product release fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == "$PRODUCT_BODY" ]] || die "product request body did not carry repository=hov-router and the release id"
pass "a latest-stable $PRODUCT_TAG release of $PRODUCT_FULL_NAME announces as hov-router with no VERSION, plugin.json or manifest entry"

if ! run_product "$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID" false false "$PRODUCT_RELEASE_ID" edited; then
  command cat "$TMP/run-output" >&2
  die "edited product release fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == "$PRODUCT_BODY" ]] || die "edited product request body drifted"
pass "an edited product release announces too"

# Planted: the same bare name under another owner is never a product, even when
# it copies the real repository id. It takes the plugin path and fails there.
for impostor in StartupBros-com/hov-router another-owner/hov-router; do
  if run_product "$PRODUCT_TAG" "$impostor" "$PRODUCT_REPO_ID"; then
    die "$impostor announced as a product"
  fi
  assert_no_request "$impostor"
  grep -Fq "no VERSION file at $PRODUCT_SOURCE for release tag $PRODUCT_TAG" "$TMP/run-output" \
    || die "$impostor did not take the plugin path and fail its plugin checks"
  pass "$impostor takes the plugin path and fails its plugin checks instead of announcing as a product"
done

# Planted: a missing GITHUB_REPOSITORY (every older plugin fixture) is the plugin path.
if run_product "$PRODUCT_TAG" '' ''; then
  die "a caller with no GITHUB_REPOSITORY announced as a product"
fi
assert_no_request "a caller with no GITHUB_REPOSITORY"
grep -Fq "no VERSION file at $PRODUCT_SOURCE" "$TMP/run-output" || die "a caller with no GITHUB_REPOSITORY did not take the plugin path"
pass "a caller without GITHUB_REPOSITORY takes the plugin path"

# Planted: the right full name with a different repository id is a deleted and
# recreated or transferred repository. It is refused outright.
for wrong_id in 1278801683 1 ''; do
  if run_product "$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$wrong_id"; then
    die "$PRODUCT_FULL_NAME with repository id '$wrong_id' announced"
  fi
  assert_no_request "$PRODUCT_FULL_NAME with repository id '$wrong_id'"
  grep -Fq '::error' "$TMP/run-output" || die "repository id '$wrong_id' mismatch did not emit an ::error::"
  grep -Fq "$PRODUCT_FULL_NAME" "$TMP/run-output" || die "repository id '$wrong_id' mismatch did not name the repository"
  ! grep -Fq 'no VERSION file' "$TMP/run-output" || die "repository id '$wrong_id' mismatch fell through to the plugin path"
  pass "$PRODUCT_FULL_NAME with repository id '${wrong_id:-<unset>}' is refused, not announced and not routed to the plugin path"
done

# Planted: a product releases on plain tags only.
if run_product "hov-router--$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID"; then
  die "a hov-router--v tag announced in the product repository"
fi
assert_no_request "a hov-router--v tag"
grep -Fq 'is not a plain v<major.minor.patch> tag' "$TMP/run-output" || die "a hov-router--v tag was not refused by the plain tag rule"
pass "hov-router--$PRODUCT_TAG in the product repository is refused loudly"

for bad_tag in v3.7.1-rc.1 v3.7.1+build v3.7 v03.7.1 3.7.1 v3.7.1.1; do
  if run_product "$bad_tag" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID"; then
    die "product tag $bad_tag announced"
  fi
  assert_no_request "product tag $bad_tag"
  grep -Fq 'is not a plain v<major.minor.patch> tag' "$TMP/run-output" || die "product tag $bad_tag was not refused by the plain tag rule"
  pass "product tag $bad_tag is refused"
done

if ! run_product "$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID" false false 2002; then
  command cat "$TMP/run-output" >&2
  die "a non-latest product release did not stay a no-op"
fi
assert_no_request "a non-latest product release"
grep -Fq "release $PRODUCT_RELEASE_ID is not latest stable 2002; no-op" "$TMP/run-output" || die "a non-latest product release was not reported as a no-op"
pass "a product release that is not the latest stable one is a no-op"

for state in "true false" "false true"; do
  read -r draft prerelease <<<"$state"
  if ! run_product "$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID" "$draft" "$prerelease"; then
    command cat "$TMP/run-output" >&2
    die "a product release with draft=$draft prerelease=$prerelease did not stay a no-op"
  fi
  assert_no_request "a product release with draft=$draft prerelease=$prerelease"
  grep -Fq 'prerelease or draft release ignored' "$TMP/run-output" || die "a product release with draft=$draft prerelease=$prerelease was not ignored"
  pass "a product release with draft=$draft prerelease=$prerelease is skipped"
done

# A draft release with an unfit tag or a stale id stays a no-op: the product
# checks sit behind the same no-ops the plugin path honours.
if ! run_product "hov-router--$PRODUCT_TAG" "$PRODUCT_FULL_NAME" 1 true false; then
  command cat "$TMP/run-output" >&2
  die "a draft product release with a bad tag and id did not stay a no-op"
fi
assert_no_request "a draft product release with a bad tag and id"
pass "a draft product release is ignored before the product checks run"

# Each mutant disables one product rule in a copy of the helper; the case that
# pins the rule must then announce, which proves the rule alone refuses it.
expect_product_mutant_announces() {
  local label="$1" old="$2" new="$3" tag="$4" github_repository="$5" github_repository_id="$6" bare_name="$7"
  local mutant="$TMP/helper-$label.sh"
  replace_once "$HELPER" "$mutant" "$old" "$new"
  chmod +x "$mutant"
  if ! PRODUCT_HELPER="$mutant" run_product "$tag" "$github_repository" "$github_repository_id" false false "$PRODUCT_RELEASE_ID" published "$bare_name"; then
    command cat "$TMP/run-output" >&2
    die "$label mutant did not announce $tag for $github_repository"
  fi
  assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
  [[ "$(<"$BODY_FILE")" == "$PRODUCT_BODY" ]] || die "$label mutant announced with an unexpected body"
  pass "$label mutant announces the planted case, so that rule alone refuses it"
}

expect_product_mutant_announces product-id-comparison-removed \
  '    if [[ "${GITHUB_REPOSITORY_ID:-}" != "$product_id" ]]; then' \
  '    if false; then' \
  "$PRODUCT_TAG" "$PRODUCT_FULL_NAME" 1278801683 "$PRODUCT_NAME"
expect_product_mutant_announces product-keyed-on-bare-name \
  '    [[ "${GITHUB_REPOSITORY:-}" == "$full_name" ]] || continue' \
  '    [[ "${GITHUB_REPOSITORY:-}" == "$full_name" || "${REPOSITORY:-}" == "$product_name" ]] || continue' \
  "$PRODUCT_TAG" another-owner/hov-router "$PRODUCT_REPO_ID" "$PRODUCT_NAME"
expect_product_mutant_announces product-plain-tag-rule-removed \
  '  [[ "$RELEASE_TAG" =~ $PRODUCT_TAG_SHAPE ]] || fail "product release tag $RELEASE_TAG is not a plain v<major.minor.patch> tag"' \
  '  true' \
  "hov-router--$PRODUCT_TAG" "$PRODUCT_FULL_NAME" "$PRODUCT_REPO_ID" "$PRODUCT_NAME"

# The table is reviewed code: exactly one row.
[[ "$(sed -n '/^readonly PRODUCTS=(/,/^)/p' "$HELPER" | grep -c "^  '")" == 1 ]] || die "product table does not hold exactly one row"
grep -Fxq "  'StartupBros/hov-router 1278801682 hov-router'" "$HELPER" || die "product table row drifted"
pass "the product table holds exactly one row: StartupBros/hov-router 1278801682 hov-router"

printf '%d Tool Drop announce checks passed\n' "$pass_count"
