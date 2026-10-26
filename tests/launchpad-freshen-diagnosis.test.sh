#!/usr/bin/env bash
# Tests launchpad-freshen.sh's failed-merge diagnosis (dotfiles#484).
#
# Why this suite exists separately from repo-update.test.sh: launchpad-freshen has
# the SAME blind spot as dotup did, reached by a different path. Its pre-merge
# guard counts only TRACKED modifications (`status --porcelain | grep -c -v '^??'`),
# so a checkout whose only dirt is untracked files sails past the guard, fails the
# ff-only merge, and used to report "local $def diverged or untracked collision" —
# a message that names two causes, commits to neither, and lists no files. On the
# real box that message scrolled past in a SessionStart hook for weeks.
#
# The load-bearing assertion is that the diagnosis is SHARED. launchpad-freshen
# sources lib/repo-update.sh fail-soft, so a broken source path degrades silently
# to the old vague sentence — exactly the failure this suite has to catch, since
# nothing else would.
#
# Hermetic: a non-bare seed repo acts as origin (no push, no network), the route
# resolver is stubbed to a permissive verdict so the route fence — tested in
# repo-route-maintenance.test.sh — is not what is under test here.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FRESHEN="$REPO/scripts/launchpad-freshen.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# A permissive stand-in for repo-route.py. The real resolver needs host registration
# and a route config; this suite is about the merge diagnosis, not the fence.
cat >"$TMP/route-stub.py" <<'STUB'
import json, sys
print(json.dumps({"classification": "unregistered", "mode": "observe",
                  "route": "", "canonical_path": "", "canonical_missing": False}))
STUB
export REPO_ROUTE_RESOLVER="$TMP/route-stub.py"

# $1 = fixture name; echoes the launchpad clone path. Origin gains NEWFILE after
# the clone, so NEWFILE is a path the update writes and the clone does not track.
fixture() {
  # Two statements, not one: bash expands every word of a `local` before any of
  # its assignments take effect, so `local n=$1 seed=$TMP/$n.seed` reads an empty
  # (here, under set -u, an unbound) $n.
  local n=$1
  local seed=$TMP/$n.seed c=$TMP/$n
  git init -q -b main "$seed"
  printf 'v1\n' >"$seed/tracked"
  git -C "$seed" add tracked
  git -C "$seed" commit -qm first
  git clone -q "$seed" "$c" 2>/dev/null
  printf 'INCOMING\n' >"$seed/NEWFILE"
  git -C "$seed" add NEWFILE
  git -C "$seed" commit -qm "origin adds NEWFILE"
  echo "$c"
}

run_freshen() { FRESHEN_FETCH_TIMEOUT=10 bash "$FRESHEN" --repo "$1" 2>&1; }

# ── 1. an untracked collision is named, with the file and its classification ─────
C=$(fixture untracked-same)
printf 'INCOMING\n' >"$C/NEWFILE"          # byte-identical to the incoming blob
before=$(git -C "$C" rev-parse HEAD)
out=$(run_freshen "$C")
case "$out" in *"ff-only merge failed"*) ok ;; *) bad "did not report the failed merge: $out" ;; esac
case "$out" in *NEWFILE*) ok ;; *) bad "did not name the colliding file: $out" ;; esac
case "$out" in *"byte-identical"*) ok ;; *) bad "did not classify the collision: $out" ;; esac
# The fail-soft source degrading to the old sentence is the silent failure mode.
case "$out" in *"diverged, or untracked files sit on incoming paths"*)
  bad "fell back to the vague message — lib/repo-update.sh did not load: $out" ;; *) ok ;; esac
[ -f "$C/NEWFILE" ] && ok || bad "the untracked file was deleted rather than reported"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite the failure"

# ── 2. a differing collision is flagged for inspection, not called safe ──────────
C=$(fixture untracked-diff)
printf 'MY OWN UNSAVED DRAFT\n' >"$C/NEWFILE"
out=$(run_freshen "$C")
case "$out" in *"differs   NEWFILE"*) ok ;; *) bad "differing collision not flagged: $out" ;; esac
grep -q 'MY OWN UNSAVED DRAFT' "$C/NEWFILE" && ok || bad "the untracked draft was DESTROYED"

# ── 3. NEGATIVE CONTROL: a clean launchpad still fast-forwards ──────────────────
# If the new diagnosis widened into a guard, every launch pad would stop freshening
# and this change would be a worse outage than the bug it fixes.
C=$(fixture clean)
printf 'scratch\n' >"$C/UNRELATED-UNTRACKED"
out=$(run_freshen "$C")
case "$out" in *"fast-forwarded 1 commit"*) ok ;; *) bad "clean launchpad did not fast-forward: $out" ;; esac
[ -f "$C/NEWFILE" ] && ok || bad "fast-forward did not deliver the incoming file"
grep -q scratch "$C/UNRELATED-UNTRACKED" && ok || bad "unrelated untracked file was destroyed"

# ── 4-7. a tracked modification only blocks when it is IN THE WAY (#1094) ───────
# The pre-#1094 guard refused on a blanket count of dirty tracked files, so a launch
# pad whose own writers keep a file dirty could never be freshened at all: ai-hedge-
# fund's SEC watchers must run in the main checkout and rewrite their cursor JSON on
# every poll, so that checkout sat 6 commits behind across four merged PRs with no
# way for a session to heal it. These cases pin the distinction the count could not
# make — "dirty" is not "in the way".

# Like fixture() but origin REWRITES an already-tracked file, so a local edit to the
# same path is a genuine collision rather than merely unrelated dirt.
fixture_touching_tracked() {
  local n=$1
  local seed=$TMP/$n.seed c=$TMP/$n
  git init -q -b main "$seed"
  printf 'v1\n' >"$seed/SHARED-FILE"
  git -C "$seed" add SHARED-FILE
  git -C "$seed" commit -qm first
  git clone -q "$seed" "$c" 2>/dev/null
  printf 'v2\n' >"$seed/SHARED-FILE"
  git -C "$seed" add SHARED-FILE
  git -C "$seed" commit -qm "origin rewrites SHARED-FILE"
  echo "$c"
}

run_freshen_dry() { DRY_RUN=1 FRESHEN_FETCH_TIMEOUT=10 bash "$FRESHEN" --repo "$1" 2>&1; }

# ── 4. tracked modification NOT on an incoming path: ff proceeds, edit survives ──
C=$(fixture carry-unrelated)
printf 'MY LOCAL WATCHER CURSOR\n' >"$C/tracked"   # origin only adds NEWFILE
out=$(run_freshen "$C")
case "$out" in *"fast-forwarded 1 commit"*) ok ;; *) bad "unrelated dirty file blocked the ff: $out" ;; esac
grep -q 'MY LOCAL WATCHER CURSOR' "$C/tracked" && ok || bad "the unrelated local edit was lost"
[ -f "$C/NEWFILE" ] && ok || bad "fast-forward did not deliver the incoming file"

# ── 5. PLANTED NEGATIVE: a tracked modification ON an incoming path must refuse ──
# This is the assertion that fails if the fix is implemented by simply deleting the
# guard. merge.autoStash is turned ON in the fixture to reproduce the 2026-09-03
# papercut, where a plain --ff-only pull stashed 35 tracked mods and lost the
# re-apply: the script's own `-c merge.autostash=false` must win over it.
C=$(fixture_touching_tracked collide)
git -C "$C" config merge.autoStash true
printf 'MY UNSAVED WORK\n' >"$C/SHARED-FILE"
before=$(git -C "$C" rev-parse HEAD)
stash_before=$(git -C "$C" stash list | wc -l)
out=$(run_freshen "$C")
case "$out" in *"ff-only merge failed"*) ok ;; *) bad "colliding tracked edit was not refused: $out" ;; esac
case "$out" in *SHARED-FILE*) ok ;; *) bad "refusal did not name the colliding path: $out" ;; esac
grep -q 'MY UNSAVED WORK' "$C/SHARED-FILE" && ok || bad "the colliding local edit was DESTROYED"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite the collision"
[ "$(git -C "$C" stash list | wc -l)" = "$stash_before" ] && ok \
  || bad "work was stashed behind the caller's back instead of refusing"

# ── 6. DRY_RUN predicts a carry rather than assuming it, and mutates nothing ─────
C=$(fixture dry-carry)
printf 'LOCAL EDIT\n' >"$C/tracked"
before=$(git -C "$C" rev-parse HEAD)
out=$(run_freshen_dry "$C")
case "$out" in *"would fast-forward"*) ok ;; *) bad "DRY_RUN did not predict the ff: $out" ;; esac
case "$out" in *"unrelated local edit"*) ok ;; *) bad "DRY_RUN did not say the edit is carried: $out" ;; esac
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "DRY_RUN mutated the checkout"
if [ -f "$C/NEWFILE" ]; then bad "DRY_RUN actually fast-forwarded"; else ok; fi

# ── 7. DRY_RUN predicts the refusal, with the colliding-path count ──────────────
C=$(fixture_touching_tracked dry-collide)
printf 'MY UNSAVED WORK\n' >"$C/SHARED-FILE"
out=$(run_freshen_dry "$C")
case "$out" in *"would REFUSE"*) ok ;; *) bad "DRY_RUN did not predict the refusal: $out" ;; esac
case "$out" in *"collide with incoming changes"*) ok ;; *) bad "DRY_RUN did not name the cause: $out" ;; esac
grep -q 'MY UNSAVED WORK' "$C/SHARED-FILE" && ok || bad "DRY_RUN touched the working tree"

# ── 8. SCOPE FENCE: the heal/switch path keeps its clean-tree requirement ───────
# #1094 relaxed the blanket tracked-file refusal on the FAST-FORWARD path only.
# Switching branches under a dirty tree is a different question with a different
# answer — git would carry the edits onto the destination branch, which is exactly
# the "stranded work quietly moved" failure the parked warning exists to prevent.
# Nothing pinned this before, so the scoping was a claim rather than a test.
run_freshen_heal() { FRESHEN_FETCH_TIMEOUT=10 bash "$FRESHEN" --repo "$1" --heal 2>&1; }

C=$(fixture heal-dirty)
git -C "$C" switch -q -c parked
printf 'DIRTY\n' >"$C/tracked"
out=$(run_freshen_heal "$C")
case "$out" in *"parked on 'parked' with 1 tracked modification(s)"*) ok ;;
  *) bad "dirty parked checkout was not refused by --heal: $out" ;; esac
[ "$(git -C "$C" branch --show-current)" = parked ] && ok || bad "--heal switched a DIRTY parked checkout"
grep -q DIRTY "$C/tracked" && ok || bad "the parked checkout's local edit was lost"

# Positive control for the same path: clean and parked still heals, so the fence
# above is a fence and not an outage.
C=$(fixture heal-clean)
git -C "$C" switch -q -c parked
out=$(run_freshen_heal "$C")
case "$out" in *"healed, switched 'parked' -> main"*) ok ;; *) bad "clean parked checkout did not heal: $out" ;; esac
[ "$(git -C "$C" branch --show-current)" = main ] && ok || bad "--heal did not switch a clean parked checkout"

if [ "$fail" -eq 0 ]; then
  echo "ok — launchpad-freshen diagnosis: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — launchpad-freshen diagnosis: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
