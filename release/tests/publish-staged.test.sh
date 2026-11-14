#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
# An unguarded command that fails under set -e would otherwise end the suite with no
# reason in the CI log; name the line and show the stderr the last case captured.
trap 'printf "not ok - unguarded command failed at line %s\n" "$LINENO" >&2; [ ! -s "$TMP/err" ] || cat "$TMP/err" >&2' ERR
PASS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass() { printf 'ok - %s\n' "$*"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
reject() {
  local reason="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then die "accepted: $reason"; fi
  grep -Fq -- "$reason" "$TMP/err" || { cat "$TMP/err"; die "missing reason: $reason"; }
}

SCRIPT="$ROOT/release/scripts/publish-staged.sh"
mkdir -p "$TMP/bin"
export CALLS="$TMP/calls" PATH="$TMP/bin:$PATH"
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
if [ "$1 $2" = 'release view' ]; then printf '%s\n' "${DRAFT_STATE:-false}"; exit 0; fi
exit 99
GH
chmod +x "$TMP/bin/gh"
: >"$CALLS"
export MANIFEST="$TMP/manifest.json" RELEASE_TAG=a--v1.2.3 PUBLISHER="$TMP/publisher"
cat >"$PUBLISHER" <<'PUBLISH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$ONLY_PLUGIN|$MANIFEST|$GH_TOKEN|$MARKETPLACE_TOKEN|$MARKETPLACE_REPO|$MARKETPLACE_REF|$DRY_RUN" >"$RECEIVED"
PUBLISH
chmod +x "$PUBLISHER"
export RECEIVED="$TMP/received" GH_TOKEN=app MARKETPLACE_TOKEN=job MARKETPLACE_REPO=acme/market MARKETPLACE_REF=main DRY_RUN=1
printf '{"plugins":[{"name":"a","source":{"source":"url"},"metadata":{"releaseTag":"a--v1.2.3"}}]}\n' >"$MANIFEST"
reject 'a url card is published from its own repository' bash "$SCRIPT"
pass 'url card is refused'
printf '{"plugins":[{"name":"a","source":{"source":"git-subdir"},"metadata":{"releaseTag":"a--v1.2.2","releaseId":77}}]}\n' >"$MANIFEST"
reject 'card for a pins a--v1.2.2, not a--v1.2.3; merge the repin first' bash "$SCRIPT"
pass 'stale card names both tags'
printf '{"plugins":[{"name":"a","source":{"source":"git-subdir"},"metadata":{"releaseTag":"a--v1.2.3"}}]}\n' >"$MANIFEST"
reject 'card for a pins a--v1.2.3 but no releaseId; the reconciler has not recorded the draft' bash "$SCRIPT"
[ ! -e "$RECEIVED" ] || die 'publisher ran without a releaseId'
pass 'a card without a releaseId never reaches the publisher'
printf '{"plugins":[{"name":"a","source":{"source":"git-subdir"},"metadata":{"releaseTag":"a--v1.2.3","releaseId":77}}]}\n' >"$MANIFEST"
bash "$SCRIPT" || die 'matching card refused'
[ "$(cat "$RECEIVED")" = "a|$MANIFEST|app|job|acme/market|main|1" ] || die 'publisher env'
[ ! -s "$CALLS" ] || die 'wrapper called gh'
pass 'matching card runs the publisher with ONLY_PLUGIN and pass-through env; a dry run never consults gh'
DRY_RUN=0 bash "$SCRIPT" || die 'live publish refused'
grep -Fxq 'release view a--v1.2.3 --json isDraft --jq .isDraft' "$CALLS" || die 'post-publish check'
pass 'a live publish confirms the release left draft state'
reject 'a--v1.2.3 is still a draft after the publisher ran' env DRAFT_STATE=true DRY_RUN=0 bash "$SCRIPT"
pass 'a publisher skip that leaves the draft in place fails the job'
printf '#!/usr/bin/env bash\nexit 7\n' >"$TMP/failing"; chmod +x "$TMP/failing"
reject 'publisher failed for a--v1.2.3' env PUBLISHER="$TMP/failing" DRY_RUN=0 bash "$SCRIPT"
pass 'a publisher failure is relayed'
reject 'refuses without an identity' env HOV_RELEASE_APP_ID='' HOV_RELEASE_APP_PRIVATE_KEY='' bash "$SCRIPT" --identity
pass 'identity check refuses absent secrets'
HOV_RELEASE_APP_ID=123 HOV_RELEASE_APP_PRIVATE_KEY=private bash "$SCRIPT" --identity || die 'complete identity refused'
pass 'identity check accepts the release App'
printf '{"plugins":[]}\n' >"$MANIFEST"
reject 'does not contain exactly one card for a' bash "$SCRIPT"
pass 'missing card fails'

printf '%s publish-staged checks passed\n' "$PASS"
