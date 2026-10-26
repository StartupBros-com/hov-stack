#!/usr/bin/env bash
# wt-roots.test.sh — root discovery shared by wt-sweep.sh and wt-new.sh.
#
# THE REGRESSION THIS GUARDS (issue #511)
#   Both tools independently hardcoded `ROOT="${ROOT:-$HOME/SITES}"`, so every git
#   repo outside ~/SITES was invisible to both — including `dotfiles`, the repo the
#   harness itself is developed in and the largest worktree pile on the box.
#   wt-sweep.service runs weekly (the author's copy with DRY_RUN=0; the shipped
#   unit is plan-only) and no ROOT, so the automated
#   worktree GC had never once swept it. Nothing errored: the sweep printed
#   `removed:8` across ~/SITES and read as healthy, while `ROOT=/home/user` on the
#   same box planned 31. A tool whose target is out of scope reports success either
#   way, which is why it went unnoticed for 15 days and silently undid the
#   2026-08-12 manual reclaim (528 -> 72 worktrees, ~46 GB).
#
#   The load-bearing case is therefore NOT "discovery works" — it is "a repo
#   outside ~/SITES is discovered". So the fixture plants one there and the last
#   check re-runs the same assertion pinned to a single root, which is precisely
#   the old behaviour: the out-of-SITES repo must DISAPPEAR. Without that pairing
#   this suite would pass just as happily against the bug it exists to catch.
#
#   wt-roots.sh is a sourceable lib rather than a block inside wt-sweep.sh
#   specifically so this can test it directly — sourcing wt-sweep.sh would sweep.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../scripts/lib/wt-roots.sh"
[ -f "$LIB" ] || { echo "FAIL: cannot find $LIB"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"
declare -F wt_roots >/dev/null || { echo "FAIL: wt_roots not defined by $LIB"; exit 1; }
declare -F wt_repo_candidates >/dev/null || { echo "FAIL: wt_repo_candidates not defined"; exit 1; }

pass=0; fail=0
check(){ # name expected actual
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "  ok: $name"; pass=$((pass+1))
  else echo "  FAIL: $name"; echo "        want: [$want]"; echo "        got:  [$got]"; fail=$((fail+1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture: one repo inside SITES, one directly in HOME, one non-repo dir ---
FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME/SITES/in-sites-repo" "$FAKEHOME/outside-repo" "$FAKEHOME/not-a-repo" "$FAKEHOME/SITES/plain-dir"
for r in "$FAKEHOME/SITES/in-sites-repo" "$FAKEHOME/outside-repo"; do
  git -C "$r" init -q 2>/dev/null || { echo "FAIL: git init failed in $r"; exit 1; }
done

echo "wt_roots — default and override"
got=$(HOME="$FAKEHOME" ROOT= wt_roots | tr '\n' ' ')
check "default is SITES then HOME, in that order" "$FAKEHOME/SITES $FAKEHOME " "$got"

got=$(HOME="$FAKEHOME" ROOT="$FAKEHOME/SITES" wt_roots | tr '\n' ' ')
check "explicit ROOT pins to exactly one root" "$FAKEHOME/SITES " "$got"

got=$(HOME="$FAKEHOME" ROOT="$FAKEHOME/SITES/" wt_roots | tr '\n' ' ')
check "explicit ROOT drops a trailing slash" "$FAKEHOME/SITES " "$got"

echo "wt_repo_candidates — discovery"
# LC_ALL=C so the comparison does not depend on the runner's collation (the box
# and the CI image disagreed on where uppercase SITES sorts).
got=$(HOME="$FAKEHOME" ROOT= wt_repo_candidates | LC_ALL=C sort | tr '\n' ' ')
check "finds the in-SITES repo AND the out-of-SITES repo" \
  "$FAKEHOME/SITES/in-sites-repo $FAKEHOME/outside-repo " "$got"

got=$(HOME="$FAKEHOME" ROOT= wt_repo_candidates | grep -cF 'not-a-repo')
check "a plain directory is not a candidate" "0" "$got"

got=$(HOME="$FAKEHOME" ROOT= wt_repo_candidates | grep -cF 'plain-dir')
check "a plain directory inside SITES is not a candidate either" "0" "$got"

# A root that does not exist must be skipped, not fatal: a box with no ~/SITES
# should still sweep $HOME rather than dying on the missing directory.
got=$(HOME="$TMP/nonexistent" ROOT= wt_repo_candidates | wc -l | tr -d ' ')
check "a missing root is skipped, not fatal" "0" "$got"

# --- the inversion probe -------------------------------------------------------
# Same assertion, pinned to a single root == the pre-#511 behaviour. If this
# still found the out-of-SITES repo, the check above would be proving nothing.
echo "inversion probe — the old single-root behaviour must NOT find it"
got=$(HOME="$FAKEHOME" ROOT="$FAKEHOME/SITES" wt_repo_candidates | grep -cF 'outside-repo')
check "single-root discovery misses the out-of-SITES repo" "0" "$got"

got=$(HOME="$FAKEHOME" ROOT="$FAKEHOME/SITES" wt_repo_candidates | grep -cF 'in-sites-repo')
check "single-root discovery still finds the in-SITES repo" "1" "$got"

echo
echo "wt-roots: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
