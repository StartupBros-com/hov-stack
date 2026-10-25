#!/usr/bin/env bash
# Tests release/scripts/latest-stable-release.sh, the reusable announce
# workflow's latest-stable guard, against a fake gh that serves fixture pages.
#
# The fake gh records every call, serves every page only under --paginate
# (one page otherwise, so a guard that drops the flag loses the winner on page
# two), can fail on a chosen page, and exits non-zero on releases/latest.
#
# Static needles quote shell expressions on purpose.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/release/scripts/latest-stable-release.sh"
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

require_command jq

[[ -x "$GUARD" ]] || die "guard is not executable: $GUARD"

FAKE_BIN="$TMP/bin"
CALLS="$TMP/gh-calls"
OUTPUT="$TMP/github-output"
RUN_OUTPUT="$TMP/run-output"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
case "$*" in
  *releases/latest*) printf 'fake gh: repository-wide latest release requested\n' >&2; exit 120 ;;
esac
[[ "${1:-}" == api ]] || exit 121
shift
paginate=false
path=''
for arg in "$@"; do
  case "$arg" in
    --paginate) paginate=true ;;
    repos/*) [[ -z "$path" ]] || exit 122; path="$arg" ;;
    *) printf 'fake gh: unexpected argument %s\n' "$arg" >&2; exit 123 ;;
  esac
done
[[ "$path" == "repos/$FAKE_GH_REPOSITORY/releases?per_page=100" ]] || { printf 'fake gh: unexpected path %s\n' "$path" >&2; exit 124; }
if [[ "$paginate" != true ]]; then
  cat "$FAKE_GH_PAGES/page-1.json"
  exit 0
fi
page_number=0
for page in "$FAKE_GH_PAGES"/page-*.json; do
  page_number=$((page_number + 1))
  if [[ -n "${FAKE_GH_FAIL_AT_PAGE:-}" && "$page_number" == "$FAKE_GH_FAIL_AT_PAGE" ]]; then
    printf 'fake gh: HTTP 502 on page %s\n' "$page_number" >&2
    exit 1
  fi
  cat "$page"
done
FAKE_GH

chmod +x "$FAKE_BIN/gh"

# release <id> <tag> [draft] [prerelease] [created_at]
release() {
  jq -cn \
    --argjson id "$1" \
    --arg tag "$2" \
    --argjson draft "${3:-false}" \
    --argjson prerelease "${4:-false}" \
    --arg created "${5:-2026-10-20T10:00:00Z}" \
    '{id: $id, tag_name: $tag, draft: $draft, prerelease: $prerelease, created_at: $created, published_at: $created}'
}

# page <pages_dir> <n> <release-json>...
page() {
  local pages_dir="$1" number="$2"
  shift 2
  mkdir -p "$pages_dir"
  printf '%s\n' "$@" | jq -s '.' >"$pages_dir/page-$number.json"
}

# run_guard <pages_dir> <release_id> <release_tag> [repository_name] [fail_at_page]
run_guard() {
  local pages_dir="$1" release_id="$2" release_tag="$3" repository="${4:-hov-stack}" fail_at_page="${5:-}"
  : >"$CALLS"
  : >"$OUTPUT"
  env \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_GH_CALLS="$CALLS" \
    FAKE_GH_PAGES="$pages_dir" \
    FAKE_GH_REPOSITORY="fixture-owner/$repository" \
    FAKE_GH_FAIL_AT_PAGE="$fail_at_page" \
    GH_TOKEN=fixture-token \
    GITHUB_REPOSITORY="fixture-owner/$repository" \
    GITHUB_OUTPUT="$OUTPUT" \
    REPOSITORY="$repository" \
    RELEASE_ID="$release_id" \
    RELEASE_TAG="$release_tag" \
    bash "$GUARD" >"$RUN_OUTPUT" 2>&1
}

expect_latest() {
  local label="$1" pages_dir="$2" release_id="$3" release_tag="$4" repository="${5:-hov-stack}"
  if ! run_guard "$pages_dir" "$release_id" "$release_tag" "$repository"; then
    command cat "$RUN_OUTPUT" >&2
    die "$label: guard failed"
  fi
  [[ "$(<"$OUTPUT")" == "id=$release_id" ]] || die "$label: GITHUB_OUTPUT is $(<"$OUTPUT"), expected id=$release_id"
  ! grep -Fq 'status=not-announced' "$RUN_OUTPUT" || die "$label: the latest release printed the not-announced marker"
  grep -Fq "release $release_id ($release_tag) is the latest stable release of" "$RUN_OUTPUT" || die "$label: the latest release was not reported"
  [[ "$(<"$CALLS")" == "api --paginate repos/fixture-owner/$repository/releases?per_page=100" ]] || die "$label: unexpected gh calls: $(<"$CALLS")"
  pass "$label"
}

expect_not_latest() {
  local label="$1" pages_dir="$2" release_id="$3" release_tag="$4" winner_id="$5" winner_tag="$6" plugin="$7" repository="${8:-hov-stack}"
  if ! run_guard "$pages_dir" "$release_id" "$release_tag" "$repository"; then
    command cat "$RUN_OUTPUT" >&2
    die "$label: guard failed"
  fi
  [[ "$(<"$OUTPUT")" == "id=$winner_id" ]] || die "$label: GITHUB_OUTPUT is $(<"$OUTPUT"), expected id=$winner_id"
  grep -Fxq "hov-drop-announce: status=not-announced reason=not-latest repository=$repository tag=$release_tag plugin=$plugin" "$RUN_OUTPUT" \
    || die "$label: the not-announced marker is missing or wrong"
  grep -Fq "::notice title=Not announced::Release $release_tag is not the latest stable release of" "$RUN_OUTPUT" || die "$label: no notice"
  grep -Fq "$winner_tag (release $winner_id) is" "$RUN_OUTPUT" || die "$label: the winner was not named"
  [[ "$(<"$CALLS")" == "api --paginate repos/fixture-owner/$repository/releases?per_page=100" ]] || die "$label: unexpected gh calls: $(<"$CALLS")"
  pass "$label"
}

expect_failure() {
  local label="$1" pages_dir="$2" release_id="$3" release_tag="$4" reason="$5" repository="${6:-hov-stack}" fail_at_page="${7:-}"
  if run_guard "$pages_dir" "$release_id" "$release_tag" "$repository" "$fail_at_page"; then
    command cat "$RUN_OUTPUT" >&2
    die "$label: guard succeeded"
  fi
  grep -Fq "$reason" "$RUN_OUTPUT" || { command cat "$RUN_OUTPUT" >&2; die "$label: reason not reported: $reason"; }
  [[ ! -s "$OUTPUT" ]] || die "$label: GITHUB_OUTPUT was written on failure: $(<"$OUTPUT")"
  ! grep -Fq 'releases/latest' "$CALLS" || die "$label: fell back to the repository-wide latest release"
  pass "$label"
}

# --- Two families released the same day: each release is latest in its own.
SAME_DAY="$TMP/same-day"
page "$SAME_DAY" 1 \
  "$(release 42 pro-gate--v2.0.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 41 hov-stack--v0.1.0 false false 2026-10-21T09:00:00Z)" \
  "$(release 40 pro-gate--v1.9.0 false false 2026-10-20T10:00:00Z)" \
  "$(release 39 hov-stack--v0.0.9 false false 2026-10-19T10:00:00Z)"
expect_latest "pro-gate--v2.0.0 is latest in its own family on a day hov-stack also released" "$SAME_DAY" 42 pro-gate--v2.0.0
expect_latest "hov-stack--v0.1.0 is latest in its own family on a day pro-gate also released" "$SAME_DAY" 41 hov-stack--v0.1.0

# --- Re-run of the earlier release: skip with the helper's marker.
expect_not_latest "a re-run of pro-gate--v1.9.0 after 2.0.0 skips and prints the marker" "$SAME_DAY" 40 pro-gate--v1.9.0 42 pro-gate--v2.0.0 pro-gate
expect_not_latest "a re-run of hov-stack--v0.0.9 after 0.1.0 skips and prints the marker" "$SAME_DAY" 39 hov-stack--v0.0.9 41 hov-stack--v0.1.0 hov-stack

# --- Semver order, not creation order.
LATER_LOWER="$TMP/later-lower"
page "$LATER_LOWER" 1 \
  "$(release 52 pro-gate--v1.9.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 51 pro-gate--v1.10.0 false false 2026-10-20T10:00:00Z)" \
  "$(release 50 pro-gate--v1.2.0 false false 2026-10-19T10:00:00Z)"
expect_latest "pro-gate--v1.10.0 stays latest when 1.9.0 is created later with a higher id" "$LATER_LOWER" 51 pro-gate--v1.10.0
expect_not_latest "pro-gate--v1.9.0 created after 1.10.0 does not win" "$LATER_LOWER" 52 pro-gate--v1.9.0 51 pro-gate--v1.10.0 pro-gate

# --- Drafts and prereleases never block.
DRAFTS="$TMP/drafts"
page "$DRAFTS" 1 \
  "$(release 63 pro-gate--v3.0.0 true false 2026-10-22T10:00:00Z)" \
  "$(release 62 pro-gate--v2.1.0-rc.1 false true 2026-10-22T09:00:00Z)" \
  "$(release 61 pro-gate--v2.0.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 60 pro-gate--v1.9.0 false false 2026-10-20T10:00:00Z)"
expect_latest "a newer same-family draft and prerelease do not block pro-gate--v2.0.0" "$DRAFTS" 61 pro-gate--v2.0.0

# --- Old shape: a per-plugin repository on v<version> tags.
OLD_SHAPE="$TMP/old-shape"
page "$OLD_SHAPE" 1 \
  "$(release 73 v1.2.3 false false 2026-10-21T10:00:00Z)" \
  "$(release 72 v1.2.2 false false 2026-10-20T10:00:00Z)" \
  "$(release 71 v1.3.0 true false 2026-10-22T10:00:00Z)"
expect_latest "v1.2.3 is latest in a per-plugin repository" "$OLD_SHAPE" 73 v1.2.3 fixture-tool
expect_not_latest "v1.2.2 re-run in a per-plugin repository skips with the repository as the plugin" "$OLD_SHAPE" 72 v1.2.2 73 v1.2.3 fixture-tool fixture-tool

# --- Families do not mix: a plain v tag and a prefixed tag in one repository.
MIXED="$TMP/mixed"
page "$MIXED" 1 \
  "$(release 83 v9.0.0 false false 2026-10-22T10:00:00Z)" \
  "$(release 82 pro-gate--v1.0.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 81 release-2024 false false 2026-10-20T10:00:00Z)"
expect_latest "pro-gate--v1.0.0 ignores a plain v9.0.0 tag and a tag of no family" "$MIXED" 82 pro-gate--v1.0.0
expect_latest "v9.0.0 ignores pro-gate--v1.0.0 and a tag of no family" "$MIXED" 83 v9.0.0

# --- The repository family is exactly the plain v<digit...> tags: a higher
# prefixed release never wins over it, a v-prefixed non-version tag is
# ignored, and a prefixed release loses only to its own family.
ISOLATED="$TMP/isolated"
page "$ISOLATED" 1 \
  "$(release 103 foo--v5.0.0 false false 2026-10-22T10:00:00Z)" \
  "$(release 102 v1.0.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 101 vendor-2024 false false 2026-10-20T10:00:00Z)" \
  "$(release 100 foo--v0.5.0 false false 2026-10-19T10:00:00Z)"
expect_latest "v1.0.0 stays latest beside a higher foo--v5.0.0 and a stable vendor-2024 tag" "$ISOLATED" 102 v1.0.0 fixture-tool
expect_not_latest "foo--v0.5.0 loses to foo--v5.0.0, not to the repository family" "$ISOLATED" 100 foo--v0.5.0 103 foo--v5.0.0 foo fixture-tool

# --- A v-prefixed tag that starts a version must parse, or the guard fails.
V_LIKE="$TMP/v-like"
page "$V_LIKE" 1 \
  "$(release 106 v1.0.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 105 v2 false false 2026-10-20T10:00:00Z)"
expect_failure "a stable v2 tag in a per-plugin repository fails loudly" "$V_LIKE" 106 v1.0.0 'stable release v2 in the family of v1.0.0 has a non-canonical version' fixture-tool

# --- Family names that are prefixes or suffixes of one another never match.
PREFIXED="$TMP/prefixed"
page "$PREFIXED" 1 \
  "$(release 114 extra-pro-gate--v9.5.0 false false 2026-10-23T10:00:00Z)" \
  "$(release 113 pro-gate-extra--v9.0.0 false false 2026-10-22T10:00:00Z)" \
  "$(release 112 pro-gate--v1.0.0 false false 2026-10-21T10:00:00Z)" \
  "$(release 111 pro--v8.0.0 false false 2026-10-20T10:00:00Z)"
expect_latest "pro-gate--v1.0.0 ignores pro-gate-extra--v9.0.0 and extra-pro-gate--v9.5.0" "$PREFIXED" 112 pro-gate--v1.0.0
expect_latest "pro--v8.0.0 ignores every family whose name contains pro" "$PREFIXED" 111 pro--v8.0.0

# --- 120 releases across two pages; the family's newest version sits on page
# two with the lowest id, where a single page or a creation-order sort loses.
PAGINATED="$TMP/paginated"
mkdir -p "$PAGINATED"
jq -n '[range(0; 100) | {id: (300 - .), tag_name: ("pro-gate--v1." + (99 - . | tostring) + ".0"), draft: false, prerelease: false, created_at: "2026-10-20T10:00:00Z", published_at: "2026-10-20T10:00:00Z"}]' >"$PAGINATED/page-1.json"
jq -n '[
  {id: 24, tag_name: "hov-stack--v0.50.0", draft: false, prerelease: false, created_at: "2026-01-02T10:00:00Z", published_at: "2026-01-02T10:00:00Z"},
  (range(0; 18) | {id: (23 - .), tag_name: ("hov-stack--v0." + (17 - . | tostring) + ".0"), draft: false, prerelease: false, created_at: "2026-01-01T10:00:00Z", published_at: "2026-01-01T10:00:00Z"}),
  {id: 5, tag_name: "pro-gate--v9.0.0", draft: false, prerelease: false, created_at: "2025-12-01T10:00:00Z", published_at: "2025-12-01T10:00:00Z"}
]' >"$PAGINATED/page-2.json"
[[ "$(jq -s 'map(length) | add' "$PAGINATED"/page-*.json)" == 120 ]] || die "pagination fixture does not hold 120 releases"
expect_latest "pro-gate--v9.0.0 on page two of 120 releases is latest" "$PAGINATED" 5 pro-gate--v9.0.0
expect_not_latest "pro-gate--v1.50.0 on page one loses to 9.0.0 on page two" "$PAGINATED" 251 pro-gate--v1.50.0 5 pro-gate--v9.0.0 pro-gate
expect_latest "hov-stack--v0.50.0 on page two is latest among 19 hov-stack releases" "$PAGINATED" 24 hov-stack--v0.50.0
grep -Fq -- '--paginate' "$CALLS" || die "the guard listed releases without --paginate"
[[ "$(grep -c 'releases?per_page=100' "$CALLS")" == 1 ]] || die "the guard listed releases more than once"
pass "one paginated list call resolves 120 releases"

# --- Failures: never a silent wrong answer.
expect_failure "a gh failure on page two fails the guard and writes no output" "$PAGINATED" 5 pro-gate--v9.0.0 'listing releases of fixture-owner/hov-stack failed' hov-stack 2
expect_failure "a current tag x--v1--v1.0.0 is refused before the listing is read" "$SAME_DAY" 42 x--v1--v1.0.0 'contains --, the release tag separator: x--v1'
[[ ! -s "$CALLS" ]] || die "a malformed current tag still listed releases"
pass "a malformed current tag makes no gh call"
expect_failure "a current tag without a canonical version is refused" "$SAME_DAY" 42 pro-gate--v2.0 'has no canonical major.minor.patch version'
expect_failure "a current tag of no family is refused" "$SAME_DAY" 42 release-2024 'is neither <name>--v<major.minor.patch> nor v<major.minor.patch>'
expect_failure "a current tag with an upper-case plugin name is refused" "$SAME_DAY" 42 Pro-Gate--v2.0.0 'has an invalid shape: Pro-Gate'
expect_failure "a current tag with a leading-zero version is refused" "$SAME_DAY" 42 pro-gate--v2.00.0 'has no canonical major.minor.patch version'
expect_failure "a current release absent from its family fails" "$SAME_DAY" 99 pro-gate--v2.0.0 'release 99 is not a stable release in the family of pro-gate--v2.0.0'
expect_failure "a current release listed under another tag fails" "$SAME_DAY" 42 pro-gate--v1.9.0 'release 42 is listed under a tag other than pro-gate--v1.9.0'

MALFORMED="$TMP/malformed"
page "$MALFORMED" 1 \
  "$(release 92 pro-gate--v1.10 false false 2026-10-21T10:00:00Z)" \
  "$(release 91 pro-gate--v1.9.0 false false 2026-10-20T10:00:00Z)"
expect_failure "a stable same-family release tagged pro-gate--v1.10 fails loudly" "$MALFORMED" 91 pro-gate--v1.9.0 'stable release pro-gate--v1.10 in the family of pro-gate--v1.9.0 has a non-canonical version'

MALFORMED_OTHER="$TMP/malformed-other"
page "$MALFORMED_OTHER" 1 \
  "$(release 94 hov-stack--v0.1 false false 2026-10-21T10:00:00Z)" \
  "$(release 93 pro-gate--v1.9.0 false false 2026-10-20T10:00:00Z)"
expect_latest "a non-canonical tag in another family does not affect pro-gate--v1.9.0" "$MALFORMED_OTHER" 93 pro-gate--v1.9.0

MALFORMED_DRAFT="$TMP/malformed-draft"
page "$MALFORMED_DRAFT" 1 \
  "$(release 96 pro-gate--vnext true false 2026-10-21T10:00:00Z)" \
  "$(release 95 pro-gate--v1.9.0 false false 2026-10-20T10:00:00Z)"
expect_latest "a same-family draft with a garbage tag is ignored, not parsed" "$MALFORMED_DRAFT" 95 pro-gate--v1.9.0

INVALID="$TMP/invalid-record"
mkdir -p "$INVALID"
printf '[{"id":"97","tag_name":"pro-gate--v1.9.0","draft":false,"prerelease":false}]\n' >"$INVALID/page-1.json"
expect_failure "a release record with a string id fails validation" "$INVALID" 97 pro-gate--v1.9.0 'release list record failed validation'

NOT_ARRAY="$TMP/not-array"
mkdir -p "$NOT_ARRAY"
printf '{"message":"Not Found"}\n' >"$NOT_ARRAY/page-1.json"
expect_failure "an error object in place of a page fails" "$NOT_ARRAY" 42 pro-gate--v2.0.0 'release list page is not an array'

# --- Environment contract.
: >"$CALLS"
: >"$OUTPUT"
# GitHub Actions exports GITHUB_OUTPUT to every run step, so the variable
# must be removed explicitly or this case runs the guard for real in CI.
if env -u GITHUB_OUTPUT PATH="$FAKE_BIN:$PATH" FAKE_GH_CALLS="$CALLS" FAKE_GH_PAGES="$SAME_DAY" FAKE_GH_REPOSITORY=fixture-owner/hov-stack \
  GH_TOKEN=fixture-token GITHUB_REPOSITORY=fixture-owner/hov-stack REPOSITORY=hov-stack RELEASE_ID=42 RELEASE_TAG=pro-gate--v2.0.0 \
  bash "$GUARD" >"$RUN_OUTPUT" 2>&1; then
  die "the guard ran without GITHUB_OUTPUT"
fi
grep -Fq 'GITHUB_OUTPUT is required' "$RUN_OUTPUT" || die "missing GITHUB_OUTPUT was not named"
[[ ! -s "$CALLS" ]] || die "the guard listed releases without GITHUB_OUTPUT"
pass "an unset GITHUB_OUTPUT fails before any gh call"

if run_guard "$SAME_DAY" 042 pro-gate--v2.0.0; then
  die "a non-canonical RELEASE_ID was accepted"
fi
grep -Fq 'RELEASE_ID must be a positive canonical decimal integer' "$RUN_OUTPUT" || die "non-canonical RELEASE_ID was not named"
pass "a non-canonical RELEASE_ID is refused"

if env PATH="$FAKE_BIN:$PATH" FAKE_GH_CALLS="$CALLS" FAKE_GH_PAGES="$SAME_DAY" FAKE_GH_REPOSITORY=fixture-owner/hov-stack \
  GH_TOKEN=fixture-token GITHUB_REPOSITORY=fixture-owner/hov-stack GITHUB_OUTPUT="$OUTPUT" REPOSITORY=hov-stack RELEASE_ID=42 RELEASE_TAG=pro-gate--v2.0.0 \
  bash "$GUARD" extra-argument >"$RUN_OUTPUT" 2>&1; then
  die "the guard accepted an argument"
fi
grep -Fq 'this guard accepts no arguments' "$RUN_OUTPUT" || die "an argument was not refused by name"
pass "the guard accepts no arguments"

! grep -Fq 'releases/latest' "$GUARD" || die "the guard names the repository-wide latest release"
grep -Fq -- 'gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100"' "$GUARD" || die "the guard does not paginate the release list"
grep -Fq 'sort_by(.version)' "$GUARD" || die "the guard does not order by version"
! grep -Eq 'sort_by\(\.(created_at|published_at)\)|fromdateiso8601' "$GUARD" || die "the guard orders by time"
grep -Fq 'hov-drop-announce: status=not-announced reason=not-latest repository=%s tag=%s plugin=%s\n' "$GUARD" || die "the guard does not print the helper marker shape"
pass "guard static contract: paginated listing, semver order, no latest endpoint, helper marker"

printf '%s latest stable guard checks passed\n' "$pass_count"
