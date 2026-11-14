#!/usr/bin/env bash
set -euo pipefail

# Publish every staged DRAFT release that the marketplace manifest already names.
#
# Draft-first staging leaves a plugin release as a draft until the card in this
# manifest carries its releaseId, because publishing fires the announcement and an
# announcement must find the card already current. Once the repin lands, the draft
# has to be published. That used to be a hand-run "Publish staged release"
# workflow in each plugin repository; this script is the same convergence step,
# run from here: it observes the card and the release, and publishes only when
# the two agree.
#
# Only the release a card pins by releaseId is ever touched. Older drafts that no
# card names (a superseded staging run, an abandoned version) can never match and
# are left alone.
#
# Before publishing it re-checks, against the release itself, everything the
# per-repository publish workflow checked: the tag, the version, the tag commit,
# and that the commit is on the default branch. It also refuses while assets are
# still uploading: a release can be created as a draft before its assets finish
# (pro-gate's runtime tarball), and the reconciler may pin it inside that window.
#
# Usage:
#   release/scripts/repin-publish.sh            # publish matching drafts
#   DRY_RUN=1 release/scripts/repin-publish.sh  # report only
#
# MANIFEST is this run's snapshot. Right before each publish the card is re-read
# from live main: a newer repin, or a revert that holds a release back, may have
# landed since the run started, and a publish cannot be taken back.
#
# Env:
#   MANIFEST           path to marketplace.json (default: .claude-plugin/marketplace.json)
#   MARKETPLACE_REPO   owner/name holding the live manifest (default: $GITHUB_REPOSITORY)
#   MARKETPLACE_REF    branch the live manifest is read from (default: main)
#   MARKETPLACE_TOKEN  token for that read (default: GH_TOKEN)
#   ONLY_PLUGIN        restrict to one plugin name
#   GH_TOKEN           must see the plugin repositories' drafts (push-capable)
#
# Exit codes:
#   0  every pinned release is already published, was published now, is still uploading,
#      or is no longer pinned on live main
#   1  a read failure or a card/release disagreement on at least one plugin;
#      the other plugins are still processed

warn() { printf 'error: %s\n' "$*" >&2; }

MANIFEST="${MANIFEST:-.claude-plugin/marketplace.json}"
MARKETPLACE_REPO="${MARKETPLACE_REPO:-${GITHUB_REPOSITORY:-}}"
MARKETPLACE_REF="${MARKETPLACE_REF:-main}"
MARKETPLACE_TOKEN="${MARKETPLACE_TOKEN:-}"
DRY_RUN="${DRY_RUN:-0}"
ONLY_PLUGIN="${ONLY_PLUGIN:-}"

[ -s "$MANIFEST" ] || { warn "manifest not found: $MANIFEST"; exit 1; }
[ -n "$MARKETPLACE_REPO" ] || { warn 'MARKETPLACE_REPO is not set'; exit 1; }

# The pin fields a publish depends on, as one comparable line. Empty input (no
# such card) yields an empty line, which never equals a real card's.
pin_tuple() {
  jq -r '[.source.url, .source.sha, .metadata.version, .metadata.releaseTag,
          (.metadata.releaseId | tostring)] | join("\t")'
}

live_card() {
  local name="$1" live
  if [ -n "$MARKETPLACE_TOKEN" ]; then
    live="$(GH_TOKEN="$MARKETPLACE_TOKEN" gh api -H 'Accept: application/vnd.github.raw' \
      "repos/$MARKETPLACE_REPO/contents/.claude-plugin/marketplace.json?ref=$MARKETPLACE_REF" 2>/dev/null)" || return 1
  else
    live="$(gh api -H 'Accept: application/vnd.github.raw' \
      "repos/$MARKETPLACE_REPO/contents/.claude-plugin/marketplace.json?ref=$MARKETPLACE_REF" 2>/dev/null)" || return 1
  fi
  jq -c --arg n "$name" '
      [ .plugins[] | select(type == "object" and .name == $n) ]
      | if length == 1 then .[0] else empty end' <<<"$live"
}

# One rule for shape, repo, path and prefix instead of three copies.
# shellcheck source=release/scripts/card-source.sh
. "$(dirname "${BASH_SOURCE[0]}")/card-source.sh"

# Returns 1 on any read failure or disagreement. Called in an || list, so set -e
# is off in here and every command that can fail says so explicitly.
publish_card() {
  local name="$1" card source_fields shape repo _path prefix _url card_version card_tag card_id card_sha latest_args
  local rel tag is_draft is_pre sha default_branch compare_status
  local pending have_assets prev_assets releases live

  card="$(jq -ce --arg n "$name" '
      [ .plugins[] | select(type == "object" and .name == $n) ] as $c
      | if ($c | length) != 1 then error("not exactly one card") else $c[0] end
    ' "$MANIFEST")" || { warn "manifest does not hold exactly one card for $name"; return 1; }

  card_id="$(jq -r '.metadata.releaseId // ""' <<<"$card")"
  if [ -z "$card_id" ]; then
    printf 'skip %s: the card pins no releaseId\n' "$name"
    return 0
  fi
  card_version="$(jq -r '.metadata.version // ""' <<<"$card")"
  card_tag="$(jq -r '.metadata.releaseTag // ""' <<<"$card")"
  card_sha="$(jq -r '.source.sha // ""' <<<"$card")"
  source_fields="$(card_source <<<"$card")" || { warn "could not resolve the source of $name"; return 1; }
  IFS=$'\x1f' read -r shape repo _path prefix _url <<<"${source_fields//$'\t'/$'\x1f'}"

  rel="$(gh api "repos/$repo/releases/$card_id" 2>/dev/null)" \
    || { warn "could not read release $card_id of $repo"; return 1; }
  is_draft="$(jq -r '.draft' <<<"$rel")"
  tag="$(jq -r '.tag_name // ""' <<<"$rel")"
  if [ "$is_draft" = false ]; then
    # Not "published": every push to main walks every card, and a bare
    # "published" per plugin read like a release of all of them.
    printf 'already published %s: %s\n' "$name" "$tag"
    return 0
  fi
  [ "$is_draft" = true ] || { warn "release $card_id of $repo has no draft flag"; return 1; }

  is_pre="$(jq -r '.prerelease' <<<"$rel")"
  [ "$is_pre" = false ] || { warn "$name pins prerelease $tag; the marketplace never publishes one"; return 1; }
  [ "$tag" = "$card_tag" ] \
    || { warn "$name: release $card_id is tagged '$tag' but the card says '$card_tag'"; return 1; }
  case "$tag" in
    "$prefix"*) ;;
    *) warn "$name: tag $tag does not start with prefix $prefix"; return 1 ;;
  esac
  [ "$card_version" = "${tag#"$prefix"}" ] \
    || { warn "$name: card version '$card_version' does not match tag $tag with prefix $prefix"; return 1; }

  sha="$(tag_commit "$repo" "$tag")" \
    || { warn "could not resolve tag $tag in $repo"; return 1; }
  [ "$sha" = "$card_sha" ] \
    || { warn "$name: $tag is commit ${sha:0:12} but the card pins ${card_sha:0:12}"; return 1; }

  default_branch="$(default_branch "$repo")" \
    || { warn "could not read the default branch of $repo"; return 1; }
  compare_status="$(compare_status "$repo" "$default_branch" "$sha")" \
    || { warn "could not compare $tag (${sha:0:8}) against $default_branch in $repo"; return 1; }
  case "$compare_status" in
    identical|behind) ;;
    *) warn "$name: $tag (${sha:0:8}) is not on $default_branch (compare status: ${compare_status:-empty})"; return 1 ;;
  esac

  # Assets: every one finished uploading, and at least as many as the newest
  # published release carried. Fewer means the staging run is still uploading,
  # or failed partway; either way the next run decides again.
  pending="$(jq '[.assets[]? | select(.state != "uploaded")] | length' <<<"$rel")" \
    || { warn "could not read the assets of $tag in $repo"; return 1; }
  have_assets="$(jq '[.assets[]? | select(.state == "uploaded")] | length' <<<"$rel")"
  releases="$(list_releases "$repo")" \
    || { warn "could not read the published releases of $repo"; return 1; }
  prev_assets="$(jq --arg prefix "$prefix" '
      [ .[] | select(type == "object" and .draft == false and .prerelease == false)
            | select((.tag_name | type) == "string")
            | select(.tag_name | startswith($prefix)) ]
      | sort_by(.published_at) | last | (.assets // []) | length
    ' <<<"$releases")" \
    || { warn "could not read the published releases of $repo"; return 1; }
  if [ "$pending" -ne 0 ] || [ "$have_assets" -lt "$prev_assets" ]; then
    printf '::notice::%s %s is pinned but its assets are incomplete (%s uploaded, %s pending, previous release had %s); not publishing yet\n' \
      "$name" "$tag" "$have_assets" "$pending" "$prev_assets"
    return 0
  fi

  live="$(live_card "$name")" \
    || { warn "could not read the live manifest of $MARKETPLACE_REPO at $MARKETPLACE_REF"; return 1; }
  if [ "$(pin_tuple <<<"$live")" != "$(pin_tuple <<<"$card")" ]; then
    printf 'skip %s: %s no longer pins %s (releaseId %s); not publishing\n' \
      "$name" "$MARKETPLACE_REF" "$tag" "$card_id"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf 'would publish %s: %s (releaseId %s, dry run)\n' "$name" "$tag" "$card_id"
    return 0
  fi
  # GitHub marks a newly published release the repository's latest unless told not to.
  # The shared repository holds every plugin's releases, so a publish there says
  # make_latest=false and the badge never moves between plugins (R13). A plugin's own
  # repository keeps GitHub's default, which is the behaviour it always had.
  latest_args=()
  [ "$shape" != git-subdir ] || latest_args=(-f make_latest=false)
  is_draft="$(gh api -X PATCH "repos/$repo/releases/$card_id" -F draft=false ${latest_args[@]+"${latest_args[@]}"} --jq '.draft' 2>/dev/null)" \
    || { warn "could not publish $tag in $repo"; return 1; }
  [ "$is_draft" = false ] || { warn "publishing $tag in $repo left it a draft"; return 1; }
  printf 'published now %s: %s (releaseId %s)\n' "$name" "$tag" "$card_id"
}

plugins="$(jq -r '.plugins[] | select(type == "object") | .name' "$MANIFEST")" \
  || { warn "could not read plugin names from $MANIFEST"; exit 1; }

failed=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -n "$ONLY_PLUGIN" ] && [ "$name" != "$ONLY_PLUGIN" ]; then
    continue
  fi
  publish_card "$name" || failed=$((failed + 1))
done <<<"$plugins"

if [ "$failed" -ne 0 ]; then
  warn "$failed plugin(s) could not be checked or published; see above"
  exit 1
fi
