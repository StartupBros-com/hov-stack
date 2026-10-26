#!/usr/bin/env bash
# stash-reap.test.sh: exercises scripts/stash-reap.sh against throwaway
# repos. Every fixture is a fresh `git init` under its own mktemp dir driven
# through REPO=, so no stash command ever touches a real checkout.
#
# The load-bearing cases are the ones only a test catches:
#   - a drop must be addressed by SHA and re-verified at its index, because the
#     shared stack shifts under concurrent sessions (17 -> 15 mid-run, measured
#     2026-08-27);
#   - DRY_RUN=1 must mutate NOTHING, including creating no backup refs;
#   - a wrong STASH_REAP_CONFIRM must drop nothing at all, not a prefix.
set -uo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts" && pwd)/stash-reap.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find stash-reap.sh at $SRC"; exit 1; }
[ -x "$SRC" ] || { echo "FAIL: $SRC is not executable"; exit 1; }

TMP=$(mktemp -d /tmp/stash-reap-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { # ck <desc> <haystack> <needle>
  if grep -qF -- "$3" <<<"$2"; then pass=$((pass + 1));
  else fail=$((fail + 1)); echo "FAIL: $1"; echo "  wanted substring: $3"; echo "  got: $2"; fi
}
ck_not() {
  if grep -qF -- "$3" <<<"$2"; then fail=$((fail + 1)); echo "FAIL: $1"; echo "  did NOT want: $3"; echo "  got: $2";
  else pass=$((pass + 1)); fi
}
ck_eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1));
  else fail=$((fail + 1)); echo "FAIL: $1 (got '$2', want '$3')"; fi
}

# Builds a repo with $1 stashes; echoes the repo path.
mkrepo() {
  local d n; d=$(mktemp -d "$TMP/repo.XXXXXX"); n="$1"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base > "$d/f.txt"; git -C "$d" add f.txt
  git -C "$d" commit -qm base
  for i in $(seq 1 "$n"); do
    echo "change $i" > "$d/f.txt"
    git -C "$d" stash push -qm "stash number $i"
  done
  printf '%s' "$d"
}

nstash() { git -C "$1" stash list | wc -l | tr -d ' '; }
shaof()  { git -C "$1" rev-parse "stash@{$2}"; }

# --- not a git repo -------------------------------------------------------
out=$(REPO="$TMP/nope" bash "$SRC" deadbeef 2>&1); rc=$?
ck "not-a-repo WARNs" "$out" "WARN stash-reap:"
ck "not-a-repo still prints summary" "$out" "stash-reap: candidates:0"
ck_eq "not-a-repo exits nonzero" "$rc" "1"

# --- no SHAs given --------------------------------------------------------
R=$(mkrepo 2)
out=$(REPO="$R" bash "$SRC" </dev/null 2>&1); rc=$?
ck "no SHAs is an error" "$out" "no SHAs given"
ck_eq "no SHAs exits nonzero" "$rc" "1"
ck_eq "no SHAs dropped nothing" "$(nstash "$R")" "2"

# --- DRY_RUN=1 is inert ---------------------------------------------------
R=$(mkrepo 3)
S1=$(shaof "$R" 1)
out=$(REPO="$R" bash "$SRC" "$S1" 2>&1)
ck "dry run marks it ready" "$out" "ready    ${S1:0:12}"
ck "dry run shows its index" "$out" "stash@{1}"
ck "dry run names the message" "$out" "stash number 2"
ck "dry run counts one candidate" "$out" "candidates:1"
ck "dry run dropped none" "$out" "dropped:0"
ck "dry run prints the real next command" "$out" "STASH_REAP_CONFIRM=1"
ck "dry run only *would* create the backup" "$out" "would create"
ck_eq "dry run left the stack alone" "$(nstash "$R")" "3"
ck_eq "dry run created no backup refs" \
  "$(git -C "$R" for-each-ref refs/stash-backup/ | wc -l | tr -d ' ')" "0"

# --- the displayed message must be the one `git stash list` shows ---------
# `git stash store` writes a BARE reflog subject over a commit whose own
# subject is "WIP on main: ...". The operator authorizes a drop by matching the
# string they see in `git stash list`, so printing the commit subject here
# showed a message that appears nowhere in that listing.
R=$(mkrepo 1)
echo stored > "$R/f.txt"
CREATED=$(git -C "$R" stash create)
git -C "$R" stash store -m autostash "$CREATED"
git -C "$R" checkout -q -- f.txt
out=$(REPO="$R" bash "$SRC" "$CREATED" 2>&1)
ck "shows the bare reflog subject" "$out" "autostash"
ck_not "does not show the commit subject" "$out" "WIP on main"
ck_eq "reflog subject is what stash list shows" \
  "$(git -C "$R" stash list --format='%gs' | head -1)" "autostash"

# --- unknown SHA / not-on-stack SHA --------------------------------------
R=$(mkrepo 2)
HEADSHA=$(git -C "$R" rev-parse HEAD)
out=$(REPO="$R" bash "$SRC" 0000000000000000000000000000000000000000 2>&1)
ck "unknown SHA reported" "$out" "unknown"
ck "unknown SHA is not a candidate" "$out" "candidates:0"
out=$(REPO="$R" bash "$SRC" "$HEADSHA" 2>&1)
ck "a real commit that is not stashed reads as gone" "$out" "gone"
ck "not-on-stack is not a candidate" "$out" "candidates:0"
ck_eq "neither touched the stack" "$(nstash "$R")" "2"

# --- wrong CONFIRM drops nothing -----------------------------------------
R=$(mkrepo 3)
S0=$(shaof "$R" 0); S2=$(shaof "$R" 2)
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=7 REPO="$R" bash "$SRC" "$S0" "$S2" 2>&1); rc=$?
ck "wrong confirm refuses" "$out" "refusing"
ck "wrong confirm names the mismatch" "$out" "!= candidate count 2"
ck_eq "wrong confirm exits nonzero" "$rc" "1"
ck_eq "wrong confirm dropped nothing" "$(nstash "$R")" "3"

# --- empty CONFIRM is not treated as a match -----------------------------
R=$(mkrepo 2)
S0=$(shaof "$R" 0)
out=$(DRY_RUN=0 REPO="$R" bash "$SRC" "$S0" 2>&1)
ck "missing confirm refuses" "$out" "refusing"
ck_eq "missing confirm dropped nothing" "$(nstash "$R")" "2"

# --- the real drop --------------------------------------------------------
R=$(mkrepo 4)
S0=$(shaof "$R" 0); S1=$(shaof "$R" 1); S3=$(shaof "$R" 3)
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=2 REPO="$R" bash "$SRC" "$S3" "$S1" 2>&1)
ck "drop reports each" "$out" "dropped  ${S3:0:12}"
ck "drop counts both" "$out" "dropped:2"
ck_eq "stack shrank by exactly 2" "$(nstash "$R")" "2"
# The survivors must be the two we did NOT name -- this is the assertion that
# fails if the script ever drops by stale index instead of re-resolved SHA.
left=$(git -C "$R" stash list --format='%H')
ck "named stash 3 is gone" "$(printf '%s' "$left" | grep -cF "$S3")" "0"
ck "named stash 1 is gone" "$(printf '%s' "$left" | grep -cF "$S1")" "0"
ck "unnamed stash 0 survived" "$(printf '%s' "$left" | grep -cF "$S0")" "1"
# Dropped work must remain reachable through its backup ref.
ck_eq "backup ref kept the dropped commit alive" \
  "$(git -C "$R" rev-parse --verify --quiet "refs/stash-backup/${S3:0:12}")" "$S3"
ck_eq "dropped commit is still a readable commit" \
  "$(git -C "$R" cat-file -t "$S3")" "commit"

# --- bundle byte-match gate ----------------------------------------------
R=$(mkrepo 2)
S0=$(shaof "$R" 0)
B="$TMP/bundle"; mkdir -p "$B/diffs"
echo "this is not the diff you are looking for" > "$B/diffs/${S0:0:12}.diff"
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=1 BUNDLE="$B" REPO="$R" bash "$SRC" "$S0" 2>&1)
ck "bundle mismatch refuses" "$out" "does not byte-match"
ck "bundle mismatch counts" "$out" "mismatch:1"
ck_eq "bundle mismatch dropped nothing" "$(nstash "$R")" "2"
# A matching bundle entry must let it through.
git -C "$R" stash show -p --binary "$S0" > "$B/diffs/${S0:0:12}.diff"
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=1 BUNDLE="$B" REPO="$R" bash "$SRC" "$S0" 2>&1)
ck "matching bundle drops" "$out" "dropped:1"
ck_eq "matching bundle shrank the stack" "$(nstash "$R")" "1"

# A bundle that does not cover the stash must fail, not silently skip the check.
R=$(mkrepo 2)
S0=$(shaof "$R" 0)
BE="$TMP/bundle-empty"; mkdir -p "$BE/diffs"
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=1 BUNDLE="$BE" REPO="$R" bash "$SRC" "$S0" 2>&1)
ck "missing bundle entry refuses" "$out" "refusing to drop it unverified"
ck "missing bundle entry counts as mismatch" "$out" "mismatch:1"
ck_not "missing bundle entry did not drop" "$out" "dropped:1"
ck_eq "missing bundle entry left the stack" "$(nstash "$R")" "2"

# --- bundle in the /stash-mining skill's <NNN>.diff layout ----------------
# The skill numbers each diff by its row in manifest.txt rather than by SHA.
# Resolving that layout is what keeps BUNDLE usable at all: before it, every
# skill-produced bundle refused every stash, and the operator's only way
# forward was to unset BUNDLE and drop with no comparison running.
R=$(mkrepo 3)
S1=$(shaof "$R" 1)
BM="$TMP/bundle-manifest"; mkdir -p "$BM/diffs"
git -C "$R" stash list --format='%gd|%H|%ct|%ci|%gs' > "$BM/manifest.txt"
n=0
while IFS= read -r h; do
  git -C "$R" stash show -p --binary "$h" > "$(printf '%s/diffs/%03d.diff' "$BM" "$n")"
  n=$((n + 1))
done < <(git -C "$R" stash list --format='%H')
ck_eq "this bundle has no short-sha-named diff" \
  "$([ -f "$BM/diffs/${S1:0:12}.diff" ] && echo present || echo absent)" "absent"
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=1 BUNDLE="$BM" REPO="$R" bash "$SRC" "$S1" 2>&1)
ck "manifest layout verifies and drops" "$out" "dropped:1"
ck "manifest layout reports no mismatch" "$out" "mismatch:0"
ck_eq "manifest layout shrank the stack" "$(nstash "$R")" "2"

# The manifest resolves a path; it must not weaken the byte-match itself.
R=$(mkrepo 3)
S1=$(shaof "$R" 1)
BC="$TMP/bundle-corrupt"; mkdir -p "$BC/diffs"
git -C "$R" stash list --format='%gd|%H|%ct|%ci|%gs' > "$BC/manifest.txt"
echo "not the diff" > "$BC/diffs/001.diff"
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=1 BUNDLE="$BC" REPO="$R" bash "$SRC" "$S1" 2>&1)
ck "manifest layout still byte-checks" "$out" "does not byte-match"
ck_eq "corrupt manifest entry dropped nothing" "$(nstash "$R")" "3"

# Lookup is BY SHA, never by live stack position. Here diffs/000.diff holds the
# correct diff for S0 and S0 sits at position 0, so a positional fallback would
# sail through; the manifest does not list S0, so it must refuse instead.
R=$(mkrepo 3)
S0=$(shaof "$R" 0)
BA="$TMP/bundle-absent"; mkdir -p "$BA/diffs"
printf 'stash@{0}|%s|0|x|y\n' "$(printf '0%.0s' $(seq 1 40))" > "$BA/manifest.txt"
git -C "$R" stash show -p --binary "$S0" > "$BA/diffs/000.diff"
out=$(DRY_RUN=0 STASH_REAP_CONFIRM=1 BUNDLE="$BA" REPO="$R" bash "$SRC" "$S0" 2>&1)
ck "SHA absent from manifest refuses" "$out" "refusing to drop it unverified"
ck "SHA absent from manifest counts as mismatch" "$out" "mismatch:1"
ck_eq "SHA absent from manifest left the stack" "$(nstash "$R")" "3"

# The suggested drop command must carry BUNDLE through. Printing it without
# BUNDLE told the operator to re-run with the byte-match switched off, right
# after the plan had passed it.
R=$(mkrepo 2)
S0=$(shaof "$R" 0)
BS="$TMP/bundle-suggest"; mkdir -p "$BS/diffs"
git -C "$R" stash show -p --binary "$S0" > "$BS/diffs/${S0:0:12}.diff"
out=$(DRY_RUN=1 BUNDLE="$BS" REPO="$R" bash "$SRC" "$S0" 2>&1)
ck "suggested command keeps BUNDLE" "$out" "BUNDLE=$BS"
out=$(DRY_RUN=1 REPO="$R" bash "$SRC" "$S0" 2>&1)
ck_not "suggested command omits BUNDLE when unset" "$out" "BUNDLE="

# --- stdin input form -----------------------------------------------------
R=$(mkrepo 3)
S0=$(shaof "$R" 0)
out=$(printf '%s # a trailing comment\n\n' "$S0" | REPO="$R" bash "$SRC" 2>&1)
ck "stdin form parses the SHA" "$out" "ready    ${S0:0:12}"
ck "stdin form ignores comments and blanks" "$out" "candidates:1"

echo
if [ "$fail" -eq 0 ]; then
  echo "ok — stash-reap: $pass/$pass assertions passed"
  exit 0
fi
echo "FAILED — stash-reap: $fail failed, $pass passed"
exit 1
