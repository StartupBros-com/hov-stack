#!/usr/bin/env bash

# Replay command text through DCG robot mode. Nothing in this file is executed
# as a candidate shell command.
set -euo pipefail

DCG_BIN=${DCG_BIN:-$HOME/.local/bin/dcg}
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/dcg"
cp "$TEST_DIR/../allowlist.toml" "$TMP/home/.config/dcg/allowlist.toml"
failures=0

check_decision() {
  local expected=$1 command=$2 status
  set +e
  (cd / && env -i HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" PATH=/usr/bin:/bin \
    "$DCG_BIN" --robot test --config /dev/null "$command") >"$TMP/result.json" 2>"$TMP/result.err"
  status=$?
  set -e
  if [ "$status" -ne "$expected" ]; then
    echo "FAIL: expected exit $expected, got $status: $command" >&2
    sed -n '1,8p' "$TMP/result.json" >&2
    sed -n '1,8p' "$TMP/result.err" >&2
    failures=$((failures + 1))
  fi
}

# Blank lines and #-comments are ignored, matching the convention the maintained
# corpus in scripts/dcg-contract/ already documents. The heredocs are
# quoted, so without this every comment line would be replayed as a command.
while IFS= read -r command; do
  case "$command" in '' | '#'*) continue ;; esac
  check_decision 0 "$command"
done <<'ALLOW'
ls -la
git status
git diff -- .
git log -1
git add README.md
git push --force-with-lease origin feature

# Moved deny -> warn in dcg 0.9.2 (rule core.git:stash-drop). `warn` exits 0, so
# it belongs in the allow set now. Defensible: CLAUDE.md's history-loss list is
# reset --hard / push --force / clean -f / branch -D, and stash drop is not on it.
git stash drop
rm -rf /tmp/dcg-scratch
rm -rf node_modules/.cache
rm -rf .next/cache
rg -n "rm -rf /" .
printf '%s\n' 'git reset --hard'
ALLOW

while IFS= read -r command; do
  case "$command" in '' | '#'*) continue ;; esac
  check_decision 1 "$command"
done <<'DENY'
# Lowercase `-d` is DELIBERATELY blocked, not a false positive. An earlier
# revision of this comment called it one; that was wrong, corrected 2026-08-06.
#
# Upstream issue #209 (filed by a third party 2026-07-15, accepted and fixed in
# 8702338 for v0.6.9) asked dcg to start denying it. The maintainer's own words:
# "a real policy gap, and the existing behavior was intentional but too
# permissive for an agent-side user-intent boundary." dcg's README (~L2775)
# gives the reasoning: `-d` verifies the branch is merged, but still removes the
# branch name, upstream-tracking configuration, and reflog reference — user
# state that outlives the merge — so every branch ref deletion is an approval
# boundary. `DCG_BYPASS=1` and `dcg allow-once` exist but are meant for a human;
# the block message says agents must not cross that boundary unasked.
#
# So this case is pinned as deny to lock in INTENDED behavior. It now guards the
# opposite direction from what the old comment implied: it fails if a future dcg
# silently loosens `-d` back to allow.
#
# Known divergence, recorded here because nothing else records it: our own
# hooks/PreToolUse/git-guard.js still offers "git branch -d (refuses unless
# merged)" as the safe alternative when it blocks `-D`, i.e. it recommends a
# command dcg then denies. Harmless (the agent gets a second clear block, never
# silent data loss) but the advice text is stale.
git branch -d merged-feature

git reset --hard HEAD~1
git clean -fd
git checkout -- .
git restore --worktree .
git push --force origin main
git branch -D feature
rm -rf /
rm -rf "$HOME"
find /home/user -delete
mkfs.ext4 /dev/sda
dd if=/dev/zero of=/dev/sda
env git reset --hard HEAD~1
/usr/bin/git reset --hard HEAD~1
bash -lc 'git reset --hard HEAD~1'
DENY

[ "$failures" -eq 0 ] || {
  echo "DCG policy replay failed: $failures mismatched decision(s)" >&2
  exit 1
}

echo "DCG policy replay passed for expected allow and deny commands"
