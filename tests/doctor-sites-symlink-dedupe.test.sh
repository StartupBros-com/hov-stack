#!/usr/bin/env bash
# harness-doctor's sites_repos helper lists each ~/SITES entry once: a compat
# symlink (SITES/old-name -> SITES/new-name) must not be visited as a second repo.
#
# EXTRACTION: the real helper is sed-extracted from harness-doctor.sh (sourcing
# the whole doctor would audit this machine); HOME is a scratch tree. The
# static checks fail if a section goes back to globbing SITES directly, so
# the helper cannot silently stop being used.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-sites-dedupe.XXXXXX) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
# count_of <haystack> <line>: how many lines equal <line>
count_of() { printf '%s\n' "$1" | grep -cxF -- "$2"; }
expect_once() {
  local n; n=$(count_of "$1" "$2")
  [ "$n" -eq 1 ] && ok_ || bad "$3: expected exactly one '$2', got $n in: $1"
}
expect_absent() {
  local n; n=$(count_of "$1" "$2")
  [ "$n" -eq 0 ] && ok_ || bad "$3: '$2' should be absent, got $n in: $1"
}

sed -n '/^sites_repos() {/,/^}/p' "$DOCTOR" > "$TMP/helper.sh"
grep -q '^sites_repos() {' "$TMP/helper.sh" || { echo "FAIL: sites_repos not found in $DOCTOR" >&2; exit 1; }

cat > "$TMP/run.sh" <<'SH'
. "$1"
sites_repos
SH

home=$TMP/home
mkdir -p "$home/SITES/alpha/.git" "$home/SITES/beta/.git" "$TMP/outside/gamma"
ln -s alpha "$home/SITES/alpha-old"             # relative compat link to a sibling
ln -s "$home/SITES/beta" "$home/SITES/beta-old" # absolute compat link to a sibling
ln -s "$TMP/outside/gamma" "$home/SITES/gamma"  # points outside SITES: kept
ln -s "$TMP/nowhere" "$home/SITES/dangling"     # dangling: not matched by the dir glob

list=$(HOME=$home bash "$TMP/run.sh" "$TMP/helper.sh")
S=$home/SITES
expect_once "$list" "$S/alpha/" "real repo alpha"
expect_once "$list" "$S/beta/" "real repo beta"
expect_once "$list" "$S/gamma/" "symlink to a dir outside SITES is kept"
expect_absent "$list" "$S/alpha-old/" "relative alias of alpha is skipped"
expect_absent "$list" "$S/beta-old/" "absolute alias of beta is skipped"
n=$(printf '%s\n' "$list" | grep -c .)
[ "$n" -eq 3 ] && ok_ || bad "expected 3 entries, got $n: $list"

# SITES missing and SITES empty: nothing printed, success.
out=$(HOME=$TMP/nosites bash "$TMP/run.sh" "$TMP/helper.sh"); rc=$?
{ [ -z "$out" ] && [ "$rc" -eq 0 ]; } && ok_ || bad "missing SITES: rc=$rc out=$out"
mkdir -p "$TMP/emptyhome/SITES"
out=$(HOME=$TMP/emptyhome bash "$TMP/run.sh" "$TMP/helper.sh"); rc=$?
{ [ -z "$out" ] && [ "$rc" -eq 0 ]; } && ok_ || bad "empty SITES: rc=$rc out=$out"

# The doctor uses the list everywhere it used to glob SITES.
if grep -qF 'mapfile -t SITES_REPOS < <(sites_repos)' "$DOCTOR"; then ok_; else bad "doctor does not compute SITES_REPOS once"; fi
n=$(grep -cF 'for repo in "${SITES_REPOS[@]}"; do' "$DOCTOR")
# Check 5's four loops read check5_repos (SITES plus home-level own repos); the
# worktree-count section is the one loop left on SITES_REPOS.
[ "$n" -eq 1 ] && ok_ || bad "expected 1 SITES_REPOS repo loop, got $n"
if grep -F 'for repo in "$HOME"/SITES/' "$DOCTOR" >/dev/null; then bad "a repo loop still globs SITES directly"; else ok_; fi
if grep -F '"$HOME"/SITES/*/.' "$DOCTOR" | grep -v '^ *#' >/dev/null; then bad "a file glob still reads SITES directly"; else ok_; fi

echo "doctor sites symlink dedupe: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
