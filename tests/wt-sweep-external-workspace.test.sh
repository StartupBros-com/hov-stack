#!/usr/bin/env bash
# wt-sweep's external-workspace advisory. A plain workspace gets the bundle advice. A workspace
# whose sub-folders are git checkouts gets the check-each-is-pushed advice, is dated by its
# newest checkout, and is reported once however many links name it.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
TMP=$(readlink -f "$TMP")
export WT_CLAUDE_HOME="$TMP/claude-home" WT_HOLD_CACHE_DIR="$TMP/hold-cache" HOME="$TMP/home" TZ=UTC
S="$TMP/sites"
mkdir -p "$HOME" "$S/plain__demonolith_workspace/bundle" "$S/proj__campaign_workspace" "$S/live__campaign_workspace"
for c in proj__campaign_workspace/one proj__campaign_workspace/two live__campaign_workspace/c; do
  git init -q "$S/$c"
done
ln -s proj__campaign_workspace "$S/proj__other-name_workspace"
# Everything is a month old except the live campaign's checkout, which committed today.
touch -d '30 days ago' "$S/plain__demonolith_workspace" "$S/proj__campaign_workspace" \
  "$S/proj__campaign_workspace/one/.git" "$S/proj__campaign_workspace/two/.git" "$S/live__campaign_workspace"

fail() { echo "FAIL: $*" >&2; printf '%s\n' "$out" >&2; exit 1; }
out=$(ROOT="$S" DRY_RUN=1 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 "$HERE/scripts/wt-sweep.sh" 2>&1)

grep -qF "external workspace $S/plain__demonolith_workspace is 30d old (>14d): bundle its history" <<<"$out" \
  || fail "the plain workspace lost its bundle advice"
n=$(grep -cF "external workspace $S/proj__campaign_workspace is 30d old (>14d) and holds 2 git checkout(s)" <<<"$out" || true)
[ "$n" = 1 ] || fail "the workspace of checkouts was reported $n times, want once with the checkout advice"
grep -qF "check each is pushed" <<<"$out" || fail "the checkout advice does not say to check each is pushed"
if grep -qF "proj__campaign_workspace is 30d old (>14d): bundle" <<<"$out"; then
  fail "the workspace of checkouts got the bundle advice"
fi
if grep -qF "other-name_workspace" <<<"$out"; then fail "the link was reported as a workspace of its own"; fi
if grep -qF "live__campaign_workspace" <<<"$out"; then fail "a workspace whose checkout committed today was called stale"; fi
grep -qE "stale-workspaces:2( |$)" <<<"$out" || fail "the summary does not count exactly two stale workspaces"
echo "ok: external-workspace advisory (plain, checkouts, link, live)"
