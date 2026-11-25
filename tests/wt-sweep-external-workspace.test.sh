#!/usr/bin/env bash
# wt-sweep's external-workspace advisory. A workspace that is a repo gets the bundle advice; one
# with no git anywhere gets an archive-a-copy advice. A workspace whose sub-folders are git
# checkouts is dated by its newest checkout, is reported once however many links name it, and
# states each sub-folder's state: a campaign record pushes without setting an upstream, so pushed
# state is read against the remote-tracking refs, and a plain folder beside them is called out.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
TMP=$(readlink -f "$TMP")
export WT_CLAUDE_HOME="$TMP/claude-home" WT_HOLD_CACHE_DIR="$TMP/hold-cache" HOME="$TMP/home" TZ=UTC
S="$TMP/sites"
W="$S/proj__campaign_workspace"
mkdir -p "$HOME" "$S/repo__demonolith_workspace/bundle" "$S/loose__campaign_workspace/notes" "$W/scratch" \
  "$S/live__campaign_workspace"
git init -q "$S/repo__demonolith_workspace"   # de-monolithize git-inits its workspace
commit() { git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m "$2"; }
# pushed: on a remote the way record.py pushes it (no upstream set); ahead: pushed, then one more
# commit and an uncommitted file; local: never had a remote.
git init -q --bare "$TMP/remote.git"
for c in pushed ahead; do
  git init -q -b "campaign/$c" "$W/$c"
  commit "$W/$c" one
  git -C "$W/$c" remote add origin "$TMP/remote.git"
  git -C "$W/$c" push -q origin "HEAD:refs/heads/campaign/$c"
  git -C "$W/$c" fetch -q origin
done
commit "$W/ahead" two
printf 'x\n' >"$W/ahead/notes.md"
git init -q -b campaign/local "$W/local"
commit "$W/local" one
commit "$W/local" two
git init -q "$S/live__campaign_workspace/c"
ln -s proj__campaign_workspace "$S/proj__other-name_workspace"
# Everything is a month old except the live campaign's checkout, which committed today.
touch -d '30 days ago' "$S/repo__demonolith_workspace" "$S/loose__campaign_workspace" "$W" "$W/pushed/.git" \
  "$W/ahead/.git" "$W/local/.git" "$S/live__campaign_workspace"

fail() { echo "FAIL: $*" >&2; printf '%s\n' "$out" >&2; exit 1; }
out=$(ROOT="$S" DRY_RUN=1 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 "$HERE/scripts/wt-sweep.sh" 2>&1)

grep -qF "external workspace $S/repo__demonolith_workspace is 30d old (>14d): bundle its history" <<<"$out" \
  || fail "the workspace that is a repo lost its bundle advice"
grep -qF "external workspace $S/loose__campaign_workspace is 30d old (>14d) and is not in git, so it exists only here: archive a copy (tar -czf" <<<"$out" \
  || fail "a workspace with no git got advice that needs git"
grep -qxF "      scratch: not in git, so it exists only here" <<<"$out" \
  || fail "a plain folder beside the checkouts was not called out"
n=$(grep -cF "external workspace $W is 30d old (>14d) and holds 3 git checkout(s): push what is not pushed" <<<"$out" || true)
[ "$n" = 1 ] || fail "the workspace of checkouts was reported $n times, want once with the checkout advice"
grep -qxF "      pushed: origin has every commit; 0 uncommitted path(s)" <<<"$out" \
  || fail "a checkout pushed without an upstream was not read as pushed"
grep -qxF "      ahead: origin lacks 1 commit(s); 1 uncommitted path(s)" <<<"$out" \
  || fail "the unpushed commit or the uncommitted file was not counted"
grep -qxF "      local: no remote, so its 2 commit(s) exist only here; 0 uncommitted path(s)" <<<"$out" \
  || fail "a checkout with no remote was not called out"
if grep -qF '@{u}' <<<"$out"; then fail "the advice still names @{u}, which a record never sets"; fi
if grep -qF "proj__campaign_workspace is 30d old (>14d): bundle" <<<"$out"; then
  fail "the workspace of checkouts got the bundle advice"
fi
if grep -qF "other-name_workspace" <<<"$out"; then fail "the link was reported as a workspace of its own"; fi
if grep -qF "live__campaign_workspace" <<<"$out"; then fail "a workspace whose checkout committed today was called stale"; fi
grep -qE "stale-workspaces:3( |$)" <<<"$out" || fail "the summary does not count exactly three stale workspaces"
echo "ok: external-workspace advisory (repo, loose, pushed, ahead, local, plain folder, link, live)"
