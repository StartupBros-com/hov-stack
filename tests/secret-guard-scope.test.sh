#!/usr/bin/env bash
# sync.sh's guard_no_credentials: what it scans and what it skips.
#
# It refuses when credential material sits in the harness tree. Run from a main
# checkout it used to sweep .claude/worktrees (other agents' separate checkouts)
# and their node_modules, and refused on a dependency README's example key, so
# install never reached its own steps. It now prunes .git anywhere, every
# node_modules and exactly .claude/worktrees, and still refuses everywhere else.
#
# The function is lifted out of sync.sh and run against fixture trees, so the
# real checkout is never scanned. Key signatures are built from fragments so
# this file itself never matches the guard or a secrets scanner.
set -uo pipefail

HERE_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

sed -n '/^guard_no_credentials() {/,/^}/p' "$HERE_REPO/sync.sh" > "$TMP/guard.sh"
grep -q 'SECRET GUARD' "$TMP/guard.sh" || { echo "FAIL: could not lift guard_no_credentials out of sync.sh" >&2; exit 1; }

PEM="-----BEGIN RSA PRIV""ATE KEY-----"
SA="{\"type\": \"service""_account\", \"project_id\": \"x\"}"

# guard <tree>: run the lifted guard with HERE=<tree>; prints its stderr, returns its status.
guard() {
  # shellcheck disable=SC2034  # read by the sourced guard_no_credentials
  ( HERE=$1
    # shellcheck disable=SC1091
    . "$TMP/guard.sh"
    guard_no_credentials 2>&1 )
}
# plant <tree> <relative path> <content>
plant() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }

# 1. A clean tree passes.
t=$TMP/clean; plant "$t" README.md "nothing here"
out=$(guard "$t") && ok || bad "a clean tree was refused: $out"

# 2. Another agent's worktree and its node_modules are not part of this tree.
t=$TMP/worktrees; plant "$t" README.md "x"
plant "$t" .claude/worktrees/other/node_modules/dotenv/README.md "$PEM"
plant "$t" .claude/worktrees/other/keys/sa.json "$SA"
out=$(guard "$t") && ok || bad "a key inside .claude/worktrees was refused: $out"

# 3. node_modules at any depth is skipped.
t=$TMP/node-modules; plant "$t" mods/pager/node_modules/pkg/README.md "$PEM"
out=$(guard "$t") && ok || bad "a key inside a nested node_modules was refused: $out"

# 4. .git stays skipped.
t=$TMP/dotgit; plant "$t" .git/objects/leak "$PEM"
out=$(guard "$t") && ok || bad "a key inside .git was refused: $out"

# 5. A key anywhere else in the tree is refused and named.
t=$TMP/leak; plant "$t" skills/x/leak.pem "$PEM"
out=$(guard "$t"); rc=$?
[ "$rc" -eq 1 ] && ok || bad "a key in the tree was not refused (rc=$rc)"
case $out in *"SECRET GUARD"*"skills/x/leak.pem"*) ok ;; *) bad "the refusal does not name the file: $out" ;; esac

# 6. Only the exact .claude/worktrees path is pruned: the rest of .claude, and a
#    directory merely named worktrees elsewhere, are still scanned.
t=$TMP/claude-other; plant "$t" .claude/settings/sa.json "$SA"
out=$(guard "$t"); [ $? -eq 1 ] && ok || bad "a key in .claude outside worktrees was not refused"
t=$TMP/named-worktrees; plant "$t" docs/worktrees/leak.pem "$PEM"
out=$(guard "$t"); [ $? -eq 1 ] && ok || bad "a key under a docs/worktrees directory was not refused"

# 7. A file named like a pruned directory is still scanned.
t=$TMP/file-named; plant "$t" scripts/node_modules "$PEM"
out=$(guard "$t"); [ $? -eq 1 ] && ok || bad "a FILE named node_modules was skipped"

echo "secret guard scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
