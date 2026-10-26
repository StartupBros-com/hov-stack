#!/usr/bin/env bash
# Hermetic regression contract for the "stash pile-up" section of
# scripts/harness-weekly.sh.
#
# EXTRACTION APPROACH: harness-weekly.sh runs harness-doctor.sh, notify.sh,
# `gh search`, `pnpm outdated` and more at the top, so running the whole file
# per scenario would be slow, network-dependent, and would mutate the
# operator's own ~/.claude/logs. This test sed-extracts ONLY the section under
# test out of the REAL shipped script into a scratch file and executes that,
# so it exercises the shipped block rather than a hand-copied reimplementation.
# A sanity check below fails loudly if the extraction ever comes back empty or
# the HW_TEST_STASH_REPO seam disappears, so renaming or restructuring the
# section in harness-weekly.sh cannot silently turn this suite into a test of
# nothing -- the failure mode that let cass-release-promote.test.sh sit green
# and unlisted in CI for weeks.
#
# WHY THIS SECTION EXISTS: nothing in the harness reaps stashes, and the
# dotfiles stack is shared by every worktree and every live session, so entries
# outlive the session that shelved them. Measured 2026-08-27: 17 entries, the
# oldest 53 days, five bare autostashes left by rebase.autoStash=true. Dropping
# is deliberately NOT automated (git-guard blocks it; /stash-mining requires a
# verified backup ref and per-entry operator authorization), so surfacing the
# count is the whole job -- which makes the counter contract the thing to test.
#
# EVERY FIXTURE IS A THROWAWAY REPO UNDER $TMP. This suite never runs a stash
# command against the real repository.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/scripts/harness-weekly.sh
TMP=$(mktemp -d /tmp/hw-stash-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle'"$'\n'"$output" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'"$'\n'"$output" ;; *) ok ;; esac
}

# -- extract the section under test from the REAL shipped script -------------
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  sed -n '/## stash pile-up/,/## ready-work digest/p' "$SRC" | sed '$d'
} > "$TMP/block.sh"
chmod +x "$TMP/block.sh"

if [ -s "$TMP/block.sh" ]; then ok; else
  echo "FAIL: sed extraction produced an empty block.sh -- the '## stash pile-up' header in harness-weekly.sh may have changed" >&2
  exit 1
fi
bash -n "$TMP/block.sh" || { echo "FAIL: extracted block.sh has a syntax error" >&2; exit 1; }
if grep -q 'HW_TEST_STASH_REPO' "$TMP/block.sh"; then ok; else
  bad "extraction sanity: HW_TEST_STASH_REPO seam missing from extracted block -- extraction is testing stale/wrong code"
fi
if grep -q 'stash-flagged:' "$TMP/block.sh"; then ok; else
  bad "extraction sanity: stash-flagged counter missing from extracted block"
fi

# -- fixture helpers ---------------------------------------------------------
mkrepo() { # $1 = dir
  local d=$1
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email harness-test@example.invalid
  git -C "$d" config user.name "harness test"
  printf 'base\n' > "$d/f.txt"
  git -C "$d" add f.txt
  git -C "$d" commit -qm base
}

# A tagged operator stash, dated $2 days ago.
add_tagged() { # $1 = dir, $2 = days ago, $3 = tag
  local d=$1 days=$2 tag=$3 ts
  ts=$(date -d "$days days ago" +%s)
  printf 'change %s\n' "$tag" >> "$d/f.txt"
  GIT_COMMITTER_DATE="$ts +0000" GIT_AUTHOR_DATE="$ts +0000" \
    git -C "$d" stash push -q -m "$tag"
}

# A BARE "autostash" entry -- the shape `git rebase --autostash` leaves behind.
# `stash push -m autostash` would record "On main: autostash" instead, which is
# a different string and deliberately must NOT be counted as abandoned rebase
# state, so this uses stash create + stash store the way git itself does.
add_autostash() { # $1 = dir, $2 = days ago
  local d=$1 days=$2 ts sha
  ts=$(date -d "$days days ago" +%s)
  printf 'auto change\n' >> "$d/f.txt"
  sha=$(GIT_COMMITTER_DATE="$ts +0000" GIT_AUTHOR_DATE="$ts +0000" git -C "$d" stash create)
  git -C "$d" stash store -m autostash "$sha"
  printf 'base\n' > "$d/f.txt"
}

FIXTURE_HOME=$TMP/home
mkdir -p "$FIXTURE_HOME"

run_block() { # $1 = repo path to point the check at
  HOME="$FIXTURE_HOME" HW_TEST_STASH_REPO="$1" bash "$TMP/block.sh" 2>&1
}

# -- case a: empty stash stack ----------------------------------------------
mkrepo "$TMP/a"
out=$(run_block "$TMP/a")
contains "$out" "stash stack: empty"  "a1: empty stack reported"
contains "$out" "stash-flagged:0"     "a2: empty stack flags zero"
omits    "$out" "WARN"                "a3: empty stack does not WARN"

# -- case b: under threshold (4 entries) ------------------------------------
mkrepo "$TMP/b"
add_tagged "$TMP/b" 1 t1
add_tagged "$TMP/b" 2 t2
add_tagged "$TMP/b" 3 t3
add_tagged "$TMP/b" 4 t4
out=$(run_block "$TMP/b")
contains "$out" "stash stack: 4 entries" "b1: counts 4 entries"
contains "$out" "stash-flagged:0"        "b2: under threshold flags zero"
omits    "$out" "WARN"                   "b3: under threshold does not WARN"
# 4 is the last quiet value; the boundary itself is case c.
contains "$out" "oldest 4d"              "b4: reports age of the OLDEST entry, not the newest"

# -- case c: exactly at the threshold (5 entries) ---------------------------
# The boundary is the whole point of a threshold, so it is asserted directly
# rather than inferred from a comfortably-over value.
mkrepo "$TMP/c"
add_tagged "$TMP/c" 1 t1
add_tagged "$TMP/c" 2 t2
add_tagged "$TMP/c" 3 t3
add_tagged "$TMP/c" 4 t4
add_tagged "$TMP/c" 5 t5
out=$(run_block "$TMP/c")
contains "$out" "WARN stash stack: 5 entries" "c1: WARNs at exactly 5"
contains "$out" "stash-flagged:5"             "c2: counter carries the real count, not a bare 1"
contains "$out" "oldest 5d"                   "c3: oldest age reported at threshold"
contains "$out" "/stash-mining"               "c4: names the sanctioned drop path"
# The toast gate greps '^WARN'; an indented WARN would log but never notify.
case "$out" in
  *$'\n'"WARN "*|"WARN "*) ok ;;
  *) bad "c5: WARN is not at line start, so the '^WARN' toast gate would miss it"$'\n'"$out" ;;
esac

# -- case d: autostash entries counted, and only the bare ones --------------
mkrepo "$TMP/d"
add_autostash "$TMP/d" 10
add_autostash "$TMP/d" 11
add_tagged    "$TMP/d" 1 "pre-pull autostash"   # ends in "autostash" but is NOT one
add_tagged    "$TMP/d" 2 t2
add_tagged    "$TMP/d" 3 t3
out=$(run_block "$TMP/d")
contains "$out" "2 abandoned autostash" "d1: counts exactly the two bare autostash entries"
omits    "$out" "3 abandoned autostash" "d2: does not miscount a tagged stash whose name ends in 'autostash'"
contains "$out" "stash-flagged:5"       "d3: total still counts every entry"

# -- case e: not a git repo -------------------------------------------------
mkdir -p "$TMP/e-not-a-repo"
out=$(run_block "$TMP/e-not-a-repo")
contains "$out" "WARN stash check failed" "e1: unreadable repo WARNs"
contains "$out" "stash-flagged:1"         "e2: unreadable repo flags nonzero"
# A silent zero here would read as "no stashes" and make the check inert --
# the a-gate-that-cannot-compare-must-fail failure mode.
omits    "$out" "stash-flagged:0"         "e3: a failed check never reports a clean zero"

# -- case f: a nonexistent path is a failure, not an empty stack ------------
out=$(run_block "$TMP/does-not-exist-at-all")
contains "$out" "WARN stash check failed" "f1: missing path WARNs"
omits    "$out" "stash stack: empty"      "f2: missing path is not reported as an empty stack"

# -- case g: the counter is actually wired into the toast gate --------------
# The block can be perfectly correct and still never notify anyone if the
# STASH counter is not read and OR-ed into the notify condition. That wiring
# lives outside the extracted block, so assert it against the real script.
if grep -q "STASH=\$(grep -oE 'stash-flagged:\[0-9\]+'" "$SRC"; then ok; else
  bad "g1: harness-weekly.sh does not read a STASH counter from the report"
fi
if grep -q '\${STASH:-0}" -gt 0 \]; then' "$SRC"; then ok; else
  bad "g2: STASH is not OR-ed into the notify gate, so the WARN would never toast"
fi
if grep -q 'unreaped stash(es)' "$SRC"; then ok; else
  bad "g3: the toast message does not name the stash count"
fi

# -- report -----------------------------------------------------------------
total=$((pass + fail))
if [ "$fail" -gt 0 ]; then
  echo "FAILED — harness-weekly stash pile-up: $fail of $total assertions failed" >&2
  exit 1
fi
echo "ok — harness-weekly stash pile-up: $pass/$total assertions passed"
