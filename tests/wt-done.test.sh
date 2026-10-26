#!/usr/bin/env bash
# wt-done.test.sh — merge-anchored worktree closeout (issue #589).
#
# THE DEFECT THIS GUARDS
#   A squash merge plus GitHub's delete_branch_on_merge leaves a branch's commits
#   reachable from no durable ref. Claude Code's Agent View then refuses to remove
#   the worktree ("has commits that are not pushed anywhere") and wt-sweep scores
#   it as unshipped work, forever — measured 2026-08-28 at 69 stuck worktrees in
#   this repo alone. wt-done.sh reconciles the branch pointer to the PR's merge
#   commit so every consumer agrees the work landed.
#
#   The load-bearing property is NOT "it moves the pointer" — it is that it moves
#   the pointer ONLY when the branch tip is byte-identical to the commit GitHub
#   actually created. So the fixture below deliberately reproduces the state that
#   defeats every content-based heuristic (squash collapses the commits, THEN main
#   moves on), and half these checks are planted negatives: content drift, a dirty
#   worktree, no merged PR, and a merge commit that is not on the default branch
#   must each REFUSE and leave the pointer where it was. Without that pairing this
#   suite would pass just as happily against a script that reset unconditionally.
#
#   Hermetic: builds its own origin/repo/worktrees under mktemp and stubs `gh` on
#   PATH. It never touches the operator's tree, real remotes, or real gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-done.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# `gh` stub: wt-done funnels every GitHub read through one function that prints
# "<pr> <merge-sha> <head-sha>". `pr list` (lookup by branch name) answers with
# STUB_GH_OUT. `api` (the commit->PR fallback) runs wt-done's own --jq filter, with
# real jq, over STUB_GH_API_JSON, a raw API-shaped response: the query is under
# test, not a canned answer to it. STUB_GH_CALLS records argv. STUB_GH_RACE names
# a worktree to commit to while "GitHub" answers, as a concurrent session would.
# STUB_GH_PR_BASE is the base the name-lookup PR merged into: like gh, `pr list
# --base <other>` then finds nothing. STUB_GH_API_FAIL makes `api` behave like gh on
# an HTTP error: the error body on stdout, --jq not applied, exit 1; STUB_GH_PR_FAIL
# does the same to `pr list`. STUB_GH_COMPARE_JSON is the raw compare response a
# shallow clone's ancestry fallback reads, again through wt-done's own --jq.
mkdir -p "$TMP/bin"
REAL_GIT=$(command -v git); export REAL_GIT
cat >"$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GIT_CALLS:-}" ]; then
  printf 'GIT_OPTIONAL_LOCKS=%s %s\n' "${GIT_OPTIONAL_LOCKS-}" "$*" >>"$GIT_CALLS"
fi
exec "$REAL_GIT" "$@"
STUB
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_GH_CALLS:-}" ] && printf '%s\n' "$*" >>"$STUB_GH_CALLS"
[ -n "${STUB_GH_RACE:-}" ] && git -C "$STUB_GH_RACE" commit -q --allow-empty -m raced >/dev/null 2>&1
case "${1:-}" in
  api) if [ -n "${STUB_GH_API_FAIL:-}" ]; then
         printf '%s\n' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
         exit 1
       fi
       path="${2:-}"; jqf=""
       while [ $# -gt 0 ]; do [ "$1" = --jq ] && { jqf="$2"; break; }; shift; done
       case "$path" in
         */compare/*) printf '%s' "${STUB_GH_COMPARE_JSON:-null}" | jq -r "${jqf:-.}" ;;
         *)           printf '%s' "${STUB_GH_API_JSON:-[]}" | jq -r "${jqf:-.}" ;;
       esac ;;
  *)   if [ -n "${STUB_GH_PR_FAIL:-}" ]; then
         printf '%s\n' '{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}'
         exit 1
       fi
       base=""; prev=""
       for a in "$@"; do [ "$prev" = --base ] && base="$a"; prev="$a"; done
       [ -n "${STUB_GH_PR_BASE:-}" ] && [ -n "$base" ] && [ "$base" != "$STUB_GH_PR_BASE" ] && exit 0
       printf '%s' "${STUB_GH_OUT:-}" ;;
esac
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/gh"

# `systemctl` stub: wt-done.sh must never call it (activation is a checkout
# fast-forward, not a unit start), so the stub only records its argv and exits
# with STUB_SYSTEMCTL_RC. A recorded call is a regression.
cat >"$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_SYSTEMCTL_CALLS:-/dev/null}"
exit "${STUB_SYSTEMCTL_RC:-0}"
STUB
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

# Exercise the actual sibling freshener and its shared diagnosis library, but never
# consult the host's route registration for fixture repositories. Route refusal is
# also exercised below by changing the stub's classification (no guard is bypassed).
cat >"$TMP/route-stub.py" <<'STUB'
import json, os
print(json.dumps({"classification": os.environ.get("STUB_ROUTE_CLASS", "unregistered"),
                  "mode": "enforce", "route": "", "canonical_missing": False}))
STUB
export REPO_ROUTE_RESOLVER="$TMP/route-stub.py"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3')";; esac; }
hasnot(){ case "$2" in *"$3"*) no "$1 (output contained '$3')";; *) ok "$1";; esac; }

# Builds origin + repo + one feature worktree, squash-merges the feature onto
# main, then moves main ON — the exact end state that defeats every
# content-based heuristic (no patch-id survives the squash; no tree matches main
# any more). $2=1 adds a commit the squash never saw, for the drift negative.
# Echoes the squash commit sha.
mkfix(){
  local extra="${2:-0}" mainfirst="${3:-0}" d="$TMP/$1" s
  # Every fixture command is muted wholesale rather than per-command: `git merge
  # --squash` prints "Squash commit -- not updating HEAD" on STDOUT even under
  # -q, which the sha capture below would otherwise swallow, handing every test a
  # two-line garbage revision. Assignments inside the block still take effect.
  {
    mkdir -p "$d"
    git init --bare -q -b main "$d/origin.git"
    git init -q -b main "$d/repo"
    git -C "$d/repo" remote add origin "$d/origin.git"
    echo base >"$d/repo/base.txt"
    git -C "$d/repo" add -A && git -C "$d/repo" commit -qm base
    git -C "$d/repo" push -q -u origin main
    git -C "$d/repo" worktree add -q "$d/wt" -b feat main
    echo one >"$d/wt/one.txt";  git -C "$d/wt" add -A && git -C "$d/wt" commit -qm one
    echo two >"$d/wt/two.txt";  git -C "$d/wt" add -A && git -C "$d/wt" commit -qm two
    # $3=1 lands an unrelated commit on main BEFORE the squash, so the squash
    # commit is base+mainextra+feat while the branch tip is only base+feat. The
    # trees then differ although nothing on the branch is unshipped — exactly the
    # case tree equality alone cannot clear (issue #596).
    if [ "$mainfirst" = 1 ]; then
      echo mainextra >"$d/repo/mainextra.txt"
      git -C "$d/repo" add -A && git -C "$d/repo" commit -qm mainextra
    fi
    git -C "$d/repo" merge -q --squash feat
    git -C "$d/repo" commit -qm "squash: feat (#7)"
    s=$(git -C "$d/repo" rev-parse HEAD)
    echo later >"$d/repo/later.txt"
    git -C "$d/repo" add -A && git -C "$d/repo" commit -qm later
    git -C "$d/repo" push -q origin main
    git -C "$d/repo" fetch -q origin
    if [ "$extra" = 1 ]; then
      echo drift >"$d/wt/drift.txt"
      git -C "$d/wt" add -A && git -C "$d/wt" commit -qm drift
    fi
  } >/dev/null 2>&1
  echo "$s"
}

echo "wt-done.sh — merge-anchored closeout"

# --- fixture sanity: the state under test must actually be the broken one ------
S=$(mkfix sanity)
chk "fixture: branch tip is byte-identical to the squash commit" "" \
    "$(git -C "$TMP/sanity/wt" diff --stat "$S" HEAD)"
chk "fixture: yet 2 commits sit outside every remote ref (the bug)" 2 \
    "$(git -C "$TMP/sanity/wt" rev-list --count HEAD --not --remotes)"
# Pin that the heuristics measured on 2026-08-28 really do fail here, so this
# suite fails loudly if a future git makes one of them start working.
git -C "$TMP/sanity/wt" diff --quiet origin/main...HEAD \
  && no "fixture: TREE-SAME should NOT match after main moves on" \
  || ok "fixture: TREE-SAME does not match (why anchoring on main fails)"
chk "fixture: --cherry-pick does not match a squashed multi-commit branch" 2 \
    "$(git -C "$TMP/sanity/wt" rev-list --count --cherry-pick --right-only --no-merges origin/main...HEAD)"

# --- 1. dry run plans but never mutates ---------------------------------------
S=$(mkfix dry); export STUB_GH_OUT="7 $S"
before=$(git -C "$TMP/dry/wt" rev-parse HEAD)
: >"$TMP/dry.git-calls"
out=$(GIT_CALLS="$TMP/dry.git-calls" DRY_RUN=1 bash "$SCRIPT" "$TMP/dry/wt" 2>&1); rc=$?
chk "dry run exits 0" 0 "$rc"
chk "dry run leaves the pointer alone" "$before" "$(git -C "$TMP/dry/wt" rev-parse HEAD)"
has "dry run plans the reset" "$out" "reset --soft"
[ -d "$TMP/dry/wt" ] && ok "dry run leaves the worktree" || no "dry run leaves the worktree"
if grep -E -- ' (fetch|reset|update-ref)( |$)|worktree (prune|remove)| branch -[dD]( |$)' "$TMP/dry.git-calls" >/dev/null; then
  no "dry run invokes no mutating Git command"
else
  ok "dry run invokes no mutating Git command"
fi
if grep -v '^GIT_OPTIONAL_LOCKS=0 ' "$TMP/dry.git-calls" >/dev/null; then
  no "dry-run Git reads disable optional locks"
else
  ok "dry-run Git reads disable optional locks"
fi

# Cached state is the dry-run ceiling. Publish a fresh commit from a second clone
# whose tree exactly matches the feature tip, but do not fetch it into the fixture
# repo. A preview must refuse on the absent object; apply must fetch that real proof
# and reconcile without losing the worktree's content.
S=$(mkfix cachemiss)
git clone -q "$TMP/cachemiss/origin.git" "$TMP/cachemiss/updater"
git -C "$TMP/cachemiss/updater" config user.email test@example.test
git -C "$TMP/cachemiss/updater" config user.name test
git -C "$TMP/cachemiss/updater" rm -q later.txt
git -C "$TMP/cachemiss/updater" commit -qm "fresh remote merge proof"
git -C "$TMP/cachemiss/updater" push -q origin main
UNCACHED=$(git -C "$TMP/cachemiss/updater" rev-parse HEAD)
export STUB_GH_OUT="7 $UNCACHED"
git -C "$TMP/cachemiss/repo" cat-file -e "$UNCACHED^{commit}" 2>/dev/null \
  && no "fixture: remote merge proof starts absent locally" \
  || ok "fixture: remote merge proof starts absent locally"
: >"$TMP/cachemiss.git-calls"
out=$(GIT_CALLS="$TMP/cachemiss.git-calls" DRY_RUN=1 bash "$SCRIPT" --reconcile-only "$TMP/cachemiss/wt" 2>&1); rc=$?
chk "dry run refuses when proof is absent from cached objects" 1 "$rc"
has "cached-only refusal names the unavailable merge commit" "$out" "not present locally"
if grep -E -- ' (fetch|reset|update-ref)( |$)' "$TMP/cachemiss.git-calls" >/dev/null; then
  no "cached-only dry run performs no Git mutation"
else
  ok "cached-only dry run performs no Git mutation"
fi

: >"$TMP/cachemiss.git-calls"
out=$(GIT_CALLS="$TMP/cachemiss.git-calls" DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/cachemiss/wt" 2>&1); rc=$?
chk "apply fetches uncached proof and reconciles" 0 "$rc"
if grep -E -- ' fetch( |$)' "$TMP/cachemiss.git-calls" >/dev/null; then
  ok "apply performs a real fetch for uncached proof"
else
  no "apply performs a real fetch for uncached proof"
fi
chk "uncached proof moves HEAD to the remote merge commit" "$UNCACHED" \
    "$(git -C "$TMP/cachemiss/wt" rev-parse HEAD)"
has "uncached reconciliation reports tree proof" "$out" "tree identical"
has "uncached reconciliation reports success" "$out" "=> reconciled to $UNCACHED"
[ -d "$TMP/cachemiss/wt" ] && ok "uncached reconciliation keeps the worktree" \
                              || no "uncached reconciliation keeps the worktree"
chk "uncached reconciliation leaves tracked content intact" "one
two" \
    "$(printf '%s\n%s' "$(cat "$TMP/cachemiss/wt/one.txt")" "$(cat "$TMP/cachemiss/wt/two.txt")")"
chk "uncached reconciliation leaves the worktree clean" "" \
    "$(git -C "$TMP/cachemiss/wt" status --porcelain)"

# --- 2. reconcile-only moves the pointer and stops -----------------------------
S=$(mkfix rec); export STUB_GH_OUT="7 $S"
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/rec/wt" 2>&1); rc=$?
chk "reconcile exits 0" 0 "$rc"
chk "HEAD is now the merge commit" "$S" "$(git -C "$TMP/rec/wt" rev-parse HEAD)"
chk "0 commits outside remote refs (the guard now passes)" 0 \
    "$(git -C "$TMP/rec/wt" rev-list --count HEAD --not --remotes)"
chk "worktree still clean (--soft touched no files)" "" "$(git -C "$TMP/rec/wt" status --porcelain)"
[ -d "$TMP/rec/wt" ] && ok "--reconcile-only keeps the worktree" || no "--reconcile-only keeps the worktree"
chk "no file was lost: tree still matches the squash commit" "" \
    "$(git -C "$TMP/rec/wt" diff --stat "$S" HEAD)"

# --- 3. PLANTED NEGATIVE: content drift must refuse ----------------------------
S=$(mkfix drift 1); export STUB_GH_OUT="7 $S"
before=$(git -C "$TMP/drift/wt" rev-parse HEAD)
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/drift/wt" 2>&1); rc=$?
chk "refuses when the branch has content the PR never shipped" 1 "$rc"
chk "pointer unmoved after refusal" "$before" "$(git -C "$TMP/drift/wt" rev-parse HEAD)"
has "refusal names the reason" "$out" "content differs from"

# --- 4. PLANTED NEGATIVE: a dirty worktree must refuse -------------------------
S=$(mkfix dirty); export STUB_GH_OUT="7 $S"
echo scratch >"$TMP/dirty/wt/scratch.txt"
before=$(git -C "$TMP/dirty/wt" rev-parse HEAD)
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/dirty/wt" 2>&1); rc=$?
chk "refuses on local changes" 1 "$rc"
chk "pointer unmoved" "$before" "$(git -C "$TMP/dirty/wt" rev-parse HEAD)"
[ -f "$TMP/dirty/wt/scratch.txt" ] && ok "the local file survives" || no "the local file survives"

# --- 5. PLANTED NEGATIVE: no merged PR must refuse -----------------------------
S=$(mkfix nopr); export STUB_GH_OUT=""
before=$(git -C "$TMP/nopr/wt" rev-parse HEAD)
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/nopr/wt" 2>&1); rc=$?
chk "refuses when no MERGED PR exists for the branch" 1 "$rc"
chk "pointer unmoved" "$before" "$(git -C "$TMP/nopr/wt" rev-parse HEAD)"
has "refusal names the reason" "$out" "no MERGED PR"

# --- 6. PLANTED NEGATIVE: merge commit not on the default branch ----------------
# A PR merged into some OTHER base would otherwise read as "shipped to main".
S=$(mkfix side)
echo unpushed >"$TMP/side/repo/unpushed.txt"
git -C "$TMP/side/repo" add -A && git -C "$TMP/side/repo" commit -qm unpushed
NS=$(git -C "$TMP/side/repo" rev-parse HEAD)
export STUB_GH_OUT="7 $NS" STUB_GH_CALLS="$TMP/side.calls"; : >"$STUB_GH_CALLS"
before=$(git -C "$TMP/side/wt" rev-parse HEAD)
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/side/wt" 2>&1); rc=$?
chk "refuses a merge commit that is not an ancestor of origin/main" 1 "$rc"
chk "pointer unmoved" "$before" "$(git -C "$TMP/side/wt" rev-parse HEAD)"
has "refusal names the reason" "$out" "not an ancestor of origin/main"
# A full clone's walk is the answer; only a shallow one asks GitHub (test 32).
hasnot "a full clone never asks GitHub about ancestry" "$(cat "$STUB_GH_CALLS")" "/compare/"
unset STUB_GH_CALLS

# --- 7. full closeout from outside removes worktree AND branch -----------------
S=$(mkfix full); export STUB_GH_OUT="7 $S"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/full/wt" 2>&1); rc=$?
chk "full closeout exits 0" 0 "$rc"
[ -d "$TMP/full/wt" ] && no "worktree removed" || ok "worktree removed"
git -C "$TMP/full/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && no "branch deleted" || ok "branch deleted with plain -d (git agreed it merged)"

# --- 8. never removes the ground underfoot ------------------------------------
# Also exercises the no-argument default target (the worktree holding $PWD).
S=$(mkfix inside); export STUB_GH_OUT="7 $S"
out=$(cd "$TMP/inside/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "invoked from inside, exits 0" 0 "$rc"
[ -d "$TMP/inside/wt" ] && ok "worktree preserved when invoked from inside" \
                        || no "worktree preserved when invoked from inside"
chk "but it still reconciled" 0 "$(git -C "$TMP/inside/wt" rev-list --count HEAD --not --remotes)"
has "says it is safe to close" "$out" "safe to close"

# --- 9. idempotent: a second run is a no-op, not an error ----------------------
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/rec/wt" 2>&1); rc=$?
chk "re-running on a reconciled worktree exits 0" 0 "$rc"
has "and says so" "$out" "already reconciled"

# --- 10. headRefOid proof carries a branch tree equality cannot clear ----------
# The gap that shipped in #589: an unrelated PR landing on main before the merge
# makes the trees differ, so proof B refuses a branch with nothing unshipped.
S=$(mkfix headonly 0 1)
TIP=$(git -C "$TMP/headonly/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP"
git -C "$TMP/headonly/wt" diff --quiet "$S" HEAD \
  && no "fixture: trees should DIFFER when main moved before the squash" \
  || ok "fixture: trees differ (tree equality alone would refuse this branch)"
out=$(DRY_RUN=0 bash "$SCRIPT" --reconcile-only "$TMP/headonly/wt" 2>&1); rc=$?
chk "headRefOid proof accepts it" 0 "$rc"
chk "pointer deliberately NOT moved (a reset would read dirty)" "$TIP" \
    "$(git -C "$TMP/headonly/wt" rev-parse HEAD)"
chk "worktree left clean" "" "$(git -C "$TMP/headonly/wt" status --porcelain)"
has "names the proof" "$out" "merged this exact tip"
has "emits the whole-line machine line wt-sweep reads" "$out" "WT_DONE_PROOF=head"

# --- 11. and full mode disposes of it -----------------------------------------
S=$(mkfix headrm 0 1)
TIP=$(git -C "$TMP/headrm/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/headrm/wt" 2>&1); rc=$?
chk "full closeout under headRefOid proof exits 0" 0 "$rc"
[ -d "$TMP/headrm/wt" ] && no "worktree removed" || ok "worktree removed"
git -C "$TMP/headrm/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && no "branch deleted" || ok "branch deleted"
has "force is attributed to GitHub's record" "$out" "PR merged this exact tip"

# --- 12. PLANTED NEGATIVE: work committed AFTER the merge must refuse ----------
# The one case where a branch really does hold unshipped work. headRefOid names
# the OLD tip, so neither proof may fire.
S=$(mkfix after 0 1)
OLDTIP=$(git -C "$TMP/after/wt" rev-parse HEAD)
echo post >"$TMP/after/wt/post.txt"
git -C "$TMP/after/wt" add -A && git -C "$TMP/after/wt" commit -qm "work after the merge"
NEWTIP=$(git -C "$TMP/after/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $OLDTIP"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/after/wt" 2>&1); rc=$?
chk "refuses when commits landed after the PR merged" 1 "$rc"
chk "pointer unmoved" "$NEWTIP" "$(git -C "$TMP/after/wt" rev-parse HEAD)"
[ -d "$TMP/after/wt" ] && ok "worktree NOT removed" || no "worktree NOT removed"
[ -f "$TMP/after/wt/post.txt" ] && ok "the unshipped work survives" || no "the unshipped work survives"
# Also the planted negative for proof C: the merged head is an ANCESTOR of this tip,
# not a descendant, so containment must not fire either.
has "refusal names all three failed proofs" "$out" "is not, and is not contained in, the commit PR #7 merged"
[ -z "$(git -C "$TMP/after/repo" for-each-ref refs/remotes/pr-merged)" ] \
  && ok "no anchor written for work the PR never saw" \
  || no "no anchor written for work the PR never saw"

# --- 12. inside run under headRefOid proof never asks a human for an outside run --
# Proof A cannot move the pointer, and the worktree it stands in cannot be removed
# from inside; disposal belongs to wt-sweep (via the WT_DONE_PROOF=head line),
# never to an operator re-running this script elsewhere (issue #842).
S=$(mkfix headin 0 1)
TIP=$(git -C "$TMP/headin/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP"
out=$(cd "$TMP/headin/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "inside run under headRefOid proof exits 0" 0 "$rc"
[ -d "$TMP/headin/wt" ] && ok "worktree preserved (not removing the ground underfoot)" \
                        || no "worktree preserved (not removing the ground underfoot)"
chk "pointer still NOT moved" "$TIP" "$(git -C "$TMP/headin/wt" rev-parse HEAD)"
has "names the sweep as the disposer" "$out" "wt-sweep removes worktree + branch"
hasnot "never asks for an outside re-run" "$out" "OUTSIDE"

# --- 13. activation: a checkout that already includes the merge is left alone --
S=$(mkfix actlive 0 1); TIP=$(git -C "$TMP/actlive/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP" STUB_SYSTEMCTL_CALLS="$TMP/actlive.calls"
: >"$STUB_SYSTEMCTL_CALLS"
out=$(cd "$TMP/actlive/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "already-live closeout exits 0" 0 "$rc"
has "reports the checkout as current" "$out" "activation: checkout current"
hasnot "never runs the freshener when already current" "$out" "activating checkout:"
chk "never calls systemctl" "" "$(cat "$STUB_SYSTEMCTL_CALLS")"

# --- 16. DRY_RUN plans the freshen and touches nothing ------------------------
S=$(mkfix actdry 0 1); TIP=$(git -C "$TMP/actdry/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP" STUB_SYSTEMCTL_CALLS="$TMP/actdry.calls"
: >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actdry/repo" reset -q --hard "$S~1"
before=$(git -C "$TMP/actdry/repo" rev-parse HEAD)
out=$(cd "$TMP/actdry/wt" && DRY_RUN=1 bash "$SCRIPT" 2>&1)
has "dry run names the checkout as not current" "$out" "activation: checkout NOT current"
has "dry run plans the freshener" "$out" "would: "
has "dry run plans the real freshener for this repo" "$out" "launchpad-freshen.sh --repo '$TMP/actdry/repo'"
chk "dry run moves nothing" "$before" "$(git -C "$TMP/actdry/repo" rev-parse HEAD)"
chk "dry run never calls systemctl" "" "$(cat "$STUB_SYSTEMCTL_CALLS")"

# --- 17. --reconcile-only (wt-sweep's call) never activates ---------------------
S=$(mkfix actrec 0 1); TIP=$(git -C "$TMP/actrec/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP" STUB_SYSTEMCTL_CALLS="$TMP/actrec.calls"
: >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actrec/repo" reset -q --hard "$S~1"
before=$(git -C "$TMP/actrec/repo" rev-parse HEAD)
out=$(cd "$TMP/actrec/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1)
hasnot "reconcile-only prints no activation line" "$out" "activation:"
chk "reconcile-only moves the checkout nowhere" "$before" "$(git -C "$TMP/actrec/repo" rev-parse HEAD)"

# --- 18. ordinary checkout: real safe fast-forward carries unrelated local state --
# Checkout currency is all this proves, not service restart or runtime deployment.
S=$(mkfix actnone 0 1); TIP=$(git -C "$TMP/actnone/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP" STUB_SYSTEMCTL_CALLS="$TMP/actnone.calls"; : >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actnone/repo" reset -q --keep "$S~1"
printf 'LOCAL WATCHER CURSOR\n' >"$TMP/actnone/repo/base.txt"
printf 'LOCAL UNTRACKED STATE\n' >"$TMP/actnone/repo/scratch.txt"
out=$(cd "$TMP/actnone/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "ordinary closeout exits 0" 0 "$rc"
has "ordinary checkout reports its exact current identity" "$out" \
  "activation: checkout current ($TMP/actnone/repo at $(git -C "$TMP/actnone/repo" rev-parse HEAD); includes $S)"
chk "ordinary checkout reports proven success once" 1 "$(grep -c -F 'activation: checkout current' <<<"$out")"
if git -C "$TMP/actnone/repo" merge-base --is-ancestor "$S" HEAD; then
  ok "canonical HEAD independently contains the known merge"
else
  no "canonical HEAD independently contains the known merge"
fi
has "real freshener carried an unrelated tracked edit" "$out" "carried 1 unrelated local edit(s)"
chk "unrelated tracked bytes survive" "LOCAL WATCHER CURSOR" "$(cat "$TMP/actnone/repo/base.txt")"
chk "unrelated untracked bytes survive" "LOCAL UNTRACKED STATE" "$(cat "$TMP/actnone/repo/scratch.txt")"
chk "branch worktree pointer remains the proven tip" "$TIP" "$(git -C "$TMP/actnone/wt" rev-parse HEAD)"
chk "ordinary repo never calls systemctl" "" "$(cat "$STUB_SYSTEMCTL_CALLS")"
unset STUB_SYSTEMCTL_CALLS

# ---- pr-merged anchors -----------------------------------------------------------
# Agent View / `claude rm` keep a worktree while `git rev-list HEAD --not --remotes`
# prints anything (Claude Code 2.1.280, function Rbn; `force` does not bypass it).
# Proof A/C cannot move the pointer, so wt-done mirrors GitHub's permanent
# refs/pull/<N>/head into refs/remotes/pr-merged/<N>. agate() is that exact gate.
agate(){ git -C "$1" rev-list --max-count=1 HEAD --not --remotes 2>/dev/null; }
# Publishes a commit as the fixture origin's refs/pull/<N>/head, the way GitHub
# holds a PR head after its branch is deleted. refs/pull/* is outside the fetch
# refspec, so the push leaves no remote-tracking ref behind in the fixture repo.
pullref(){ git -C "$TMP/$1/wt" push -q origin "$2:refs/pull/$3/head" >/dev/null 2>&1; }
anchors(){ git -C "$1" for-each-ref --format='%(refname)' refs/remotes/pr-merged; }

# --- 19. proof A: the anchor makes Agent View's gate pass, touching nothing ------
S=$(mkfix anch 0 1); TIP=$(git -C "$TMP/anch/wt" rev-parse HEAD)
pullref anch "$TIP" 7
export STUB_GH_OUT="7 $S $TIP"
[ -n "$(agate "$TMP/anch/wt")" ] && ok "fixture: Agent View gate refuses before" \
  || no "fixture: Agent View gate refuses before"
out=$(cd "$TMP/anch/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "inside run under proof A exits 0" 0 "$rc"
chk "anchor names the merged head" "$TIP" \
  "$(git -C "$TMP/anch/repo" rev-parse -q --verify refs/remotes/pr-merged/feat)"
chk "Agent View gate passes after the anchor" "" "$(agate "$TMP/anch/wt")"
chk "pointer unmoved" "$TIP" "$(git -C "$TMP/anch/wt" rev-parse HEAD)"
chk "no file touched" "" "$(git -C "$TMP/anch/wt" status --porcelain)"
has "tells the session Agent View can close it" "$out" "Agent View can close this worktree now"
[ -d "$TMP/anch/wt" ] && ok "inside run leaves its own worktree" || no "inside run leaves its own worktree"
# The bug is born at a prune (fetch.prune=true on this host), so the anchor must
# outlive exactly that.
git -C "$TMP/anch/repo" -c fetch.prune=true fetch -q origin >/dev/null 2>&1
git -C "$TMP/anch/repo" remote prune origin >/dev/null 2>&1
chk "anchor survives fetch --prune and remote prune" "" "$(agate "$TMP/anch/wt")"

# --- 20. an anchored tip still re-proves for disposal ----------------------------
# The anchor makes the tip closable, but plain `branch -d` can never agree after a
# squash, so a later run must reach the proof again rather than the
# already-reconciled path: the unshipped count excludes pr-merged/*.
out=$(cd "$TMP/anch/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
chk "reconcile-only on an anchored tip exits 0" 0 "$rc"
grep -qx 'WT_DONE_PROOF=head' <<<"$out" \
  && ok "anchored tip still yields the sweep's machine line" \
  || no "anchored tip still yields the sweep's machine line"
hasnot "anchored tip not mistaken for already reconciled" "$out" "already reconciled"
out=$(cd "$TMP" && DRY_RUN=0 bash "$SCRIPT" "$TMP/anch/wt" 2>&1); rc=$?
chk "outside run on an anchored tip exits 0" 0 "$rc"
[ -d "$TMP/anch/wt" ] && no "anchored worktree removed" || ok "anchored worktree removed"
git -C "$TMP/anch/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && no "anchored branch deleted" || ok "anchored branch deleted"
has "-D attributed to the exact-tip record" "$out" "branch -D feat (PR merged this exact tip)"
# The anchor lives exactly as long as its branch (review P2: no unbounded refs).
chk "anchor dropped with its branch" "" "$(anchors "$TMP/anch/repo")"
has "says the anchor went with the branch" "$out" "dropped anchor refs/remotes/pr-merged/feat with its branch"

# --- 21. proof C via the commit lookup: pushed under another name, PR grew --------
# acme-app PR 2382: the worktree pushed HEAD:<shared PR branch> under a different
# local name, then more commits landed on the PR before it merged. `gh pr list
# --head <local branch>` finds nothing; the commit->PR endpoint finds the PR, whose
# merged head is a DESCENDANT of this tip and exists only on the server.
S=$(mkfix cont 0 1); TIP=$(git -C "$TMP/cont/wt" rev-parse HEAD)
pullref cont "$TIP" 7
PRHEAD=$(git -C "$TMP/cont/origin.git" commit-tree "$TIP^{tree}" -p "$TIP" -m "follow-up on the PR")
git -C "$TMP/cont/origin.git" update-ref refs/pull/7/head "$PRHEAD"
git -C "$TMP/cont/repo" cat-file -e "$PRHEAD" 2>/dev/null \
  && no "fixture: merged head starts absent locally" || ok "fixture: merged head starts absent locally"
# Anchor lifecycle plants. An orphan (its branch is gone, as after an Agent View
# close) and a stale pr-merged/feat/old whose D/F conflict would make the
# pr-merged/feat fetch fail must both be pruned before the fetch; an anchor whose
# branch still exists must survive.
git -C "$TMP/cont/repo" update-ref refs/remotes/pr-merged/ghost "$S"
git -C "$TMP/cont/repo" update-ref refs/remotes/pr-merged/feat/old "$S"
git -C "$TMP/cont/repo" branch -q keepme "$S"
git -C "$TMP/cont/repo" update-ref refs/remotes/pr-merged/keepme "$S"
# The commit->PR endpoint's raw answer, run through wt-done's real filter. Both
# decoys have head == this tip, so the head-match preference would pick either if
# its guard were gone: #9 was closed unmerged (GitHub still fills merge_commit_sha
# with a test merge), and #8 is a stacked child that merged into its parent's
# branch, whose merge commit is not on main and would refuse. #7, the parent that
# squash-merged into main, is the only PR that proves anything.
STUB_GH_API_JSON=$(printf '[%s,%s,%s]' \
  "{\"number\":9,\"merged_at\":null,\"merge_commit_sha\":\"$S\",\"head\":{\"sha\":\"$TIP\"},\"base\":{\"ref\":\"main\"}}" \
  "{\"number\":8,\"merged_at\":\"2026-09-20T00:00:00Z\",\"merge_commit_sha\":\"$TIP\",\"head\":{\"sha\":\"$TIP\"},\"base\":{\"ref\":\"stack-parent\"}}" \
  "{\"number\":7,\"merged_at\":\"2026-09-21T00:00:00Z\",\"merge_commit_sha\":\"$S\",\"head\":{\"sha\":\"$PRHEAD\"},\"base\":{\"ref\":\"main\"}}")
export STUB_GH_OUT="" STUB_GH_API_JSON STUB_GH_CALLS="$TMP/cont.calls"; : >"$STUB_GH_CALLS"
# Preview is cached-state-only: it cannot see the descendant, so it refuses and
# fetches nothing, the same contract as an uncached merge commit.
out=$(cd "$TMP/cont/wt" && DRY_RUN=1 bash "$SCRIPT" 2>&1); rc=$?
chk "preview refuses when the merged head is not cached" 1 "$rc"
git -C "$TMP/cont/repo" cat-file -e "$PRHEAD" 2>/dev/null \
  && no "preview fetched nothing" || ok "preview fetched nothing"
chk "preview wrote no anchor" "" \
  "$(git -C "$TMP/cont/repo" rev-parse -q --verify refs/remotes/pr-merged/feat)"
chk "preview pruned nothing either" 3 "$(anchors "$TMP/cont/repo" | wc -l | tr -d ' ')"
out=$(cd "$TMP/cont/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
chk "apply proves containment" 0 "$rc"
has "names the containment proof" "$out" "which contains this tip"
has "picked the PR merged into main, not the unmerged or stacked decoy" "$out" "PR #7 merged $PRHEAD"
grep -qF "api repos/{owner}/{repo}/commits/$TIP/pulls" "$STUB_GH_CALLS" \
  && ok "fell back to the commit->PR lookup for this tip" \
  || no "fell back to the commit->PR lookup for this tip"
chk "anchor names the merged head" "$PRHEAD" \
  "$(git -C "$TMP/cont/repo" rev-parse -q --verify refs/remotes/pr-merged/feat)"
chk "Agent View gate passes under proof C" "" "$(agate "$TMP/cont/wt")"
chk "pointer unmoved under proof C" "$TIP" "$(git -C "$TMP/cont/wt" rev-parse HEAD)"
grep -qx 'WT_DONE_PROOF=head' <<<"$out" \
  && ok "sweep machine line printed under proof C" || no "sweep machine line printed under proof C"
has "reports the orphans it pruned" "$out" "pruned 2 orphan anchor(s)"
chk "orphan and D/F-conflicting anchors pruned; live-branch anchor kept" \
  "$(printf 'refs/remotes/pr-merged/feat\nrefs/remotes/pr-merged/keepme')" "$(anchors "$TMP/cont/repo")"

# --- 21b. and full mode disposes of a proof-C worktree -----------------------------
# The containment path's own -D branch, which only the outside run reaches.
out=$(cd "$TMP" && DRY_RUN=0 bash "$SCRIPT" "$TMP/cont/wt" 2>&1); rc=$?
chk "outside run under proof C exits 0" 0 "$rc"
[ -d "$TMP/cont/wt" ] && no "proof-C worktree removed" || ok "proof-C worktree removed"
git -C "$TMP/cont/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && no "proof-C branch deleted" || ok "proof-C branch deleted"
has "-D attributed to the containment record" "$out" "branch -D feat (PR merged a descendant of this tip)"
chk "anchor dropped with its branch; the live one stays" "refs/remotes/pr-merged/keepme" "$(anchors "$TMP/cont/repo")"
unset STUB_GH_API_JSON STUB_GH_CALLS

# --- 22. PLANTED NEGATIVE: GitHub's two records disagree -> no anchor, ever -------
# The PR API says it merged this tip, but the server's refs/pull/7/head names
# another commit. The anchor is the one claim Agent View reads, so it is never
# written -- not even transiently, since a run killed between a write and its
# rollback would leave the unproven claim behind. The git call log proves no
# command targeted the anchor ref. The disposal proof (A) is unaffected.
S=$(mkfix anchbad 0 1); TIP=$(git -C "$TMP/anchbad/wt" rev-parse HEAD)
git -C "$TMP/anchbad/origin.git" update-ref refs/pull/7/head "$S"
export STUB_GH_OUT="7 $S $TIP" GIT_CALLS="$TMP/anchbad.gitcalls"; : >"$GIT_CALLS"
out=$(cd "$TMP/anchbad/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset GIT_CALLS
chk "record mismatch still exits 0 under proof A" 0 "$rc"
has "names the disagreement" "$out" "refs/pull/7/head is $S"
has "says no anchor was written" "$out" "no anchor written"
chk "no git command ever targeted the anchor ref" 0 \
  "$(grep -c 'refs/remotes/pr-merged/feat' "$TMP/anchbad.gitcalls")"
chk "no anchor left behind" "" "$(anchors "$TMP/anchbad/repo")"
[ -n "$(agate "$TMP/anchbad/wt")" ] && ok "Agent View gate still refuses without an anchor" \
  || no "Agent View gate still refuses without an anchor"

# --- 23. no server ref (non-GitHub) or no server (offline): says which, writes nothing
S=$(mkfix anchoff 0 1); TIP=$(git -C "$TMP/anchoff/wt" rev-parse HEAD)
export STUB_GH_OUT="7 $S $TIP"
out=$(cd "$TMP/anchoff/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "missing server ref still exits 0 under proof A" 0 "$rc"
has "names the missing server ref" "$out" "origin has no refs/pull/7/head"
has "says Agent View still refuses" "$out" "no anchor, so Agent View still refuses"
has "inside message does not claim closability" "$out" "anchor not written"
hasnot "never claims Agent View can close it" "$out" "Agent View can close"
chk "no anchor without a server ref" "" "$(anchors "$TMP/anchoff/repo")"
git -C "$TMP/anchoff/repo" remote set-url origin "$TMP/anchoff/nowhere.git"
out=$(cd "$TMP/anchoff/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
chk "unreachable origin still exits 0 under proof A" 0 "$rc"
has "says the server could not be read" "$out" "could not read refs/pull/7/head (offline?)"
chk "no anchor while offline" "" "$(anchors "$TMP/anchoff/repo")"

# --- 24. preview under proof A plans the anchor and writes nothing ---------------
S=$(mkfix anchdry 0 1); TIP=$(git -C "$TMP/anchdry/wt" rev-parse HEAD)
pullref anchdry "$TIP" 7
export STUB_GH_OUT="7 $S $TIP"
out=$(cd "$TMP/anchdry/wt" && DRY_RUN=1 bash "$SCRIPT" 2>&1); rc=$?
chk "preview under proof A exits 0" 0 "$rc"
has "preview plans the verified anchor write" "$out" "update-ref refs/remotes/pr-merged/feat $TIP (once refs/pull/7/head is read and names it)"
chk "preview wrote no anchor" "" "$(anchors "$TMP/anchdry/repo")"

# --- 25. PLANTED NEGATIVE: the anchor lib is missing -> refuse, touch nothing -----
# Without it the unshipped count reads empty, "already reconciled", and the worktree
# would be removed. A copy of the script with no lib/ beside it is exactly that
# install state; the same fixture is then disposed by the intact script, so the
# refusal is the guard's doing and not the fixture's.
S=$(mkfix nolib 0 1); TIP=$(git -C "$TMP/nolib/wt" rev-parse HEAD)
mkdir -p "$TMP/nolibbin"; cp "$SCRIPT" "$TMP/nolibbin/wt-done.sh"
export STUB_GH_OUT="7 $S $TIP"
out=$(cd "$TMP" && DRY_RUN=0 bash "$TMP/nolibbin/wt-done.sh" "$TMP/nolib/wt" 2>&1); rc=$?
chk "missing lib exits 1" 1 "$rc"
has "names the missing lib" "$out" "wt-done: cannot load "
has "at the path beside the script" "$out" "nolibbin/lib/wt-anchor.sh"
[ -d "$TMP/nolib/wt" ] && ok "missing lib left the worktree" || no "missing lib left the worktree"
chk "missing lib left the branch" "$TIP" "$(git -C "$TMP/nolib/repo" rev-parse -q --verify refs/heads/feat)"
out=$(cd "$TMP" && DRY_RUN=0 bash "$SCRIPT" "$TMP/nolib/wt" 2>&1); rc=$?
[ -d "$TMP/nolib/wt" ] && no "same fixture is disposable with the lib present" \
  || ok "same fixture is disposable with the lib present"

# --- 26. PLANTED NEGATIVE: a commit lands while GitHub answers ---------------------
# The proof is about the tip read before the lookup. A session committing during the
# lookup made work no PR saw: no machine line for the sweep, nothing removed, and the
# new commit still on the branch.
S=$(mkfix race 0 1); TIP=$(git -C "$TMP/race/wt" rev-parse HEAD)
pullref race "$TIP" 7
export STUB_GH_OUT="7 $S $TIP" STUB_GH_RACE="$TMP/race/wt"
out=$(cd "$TMP/race/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_RACE
chk "reconcile-only refuses a tip that moved mid-closeout" 1 "$rc"
has "names the change" "$out" "worktree changed during closeout"
grep -qx 'WT_DONE_PROOF=head' <<<"$out" \
  && no "no machine line for a moved tip" || ok "no machine line for a moved tip"
S=$(mkfix race2 0 1); TIP=$(git -C "$TMP/race2/wt" rev-parse HEAD)
pullref race2 "$TIP" 7
export STUB_GH_OUT="7 $S $TIP" STUB_GH_RACE="$TMP/race2/wt"
out=$(cd "$TMP" && DRY_RUN=0 bash "$SCRIPT" "$TMP/race2/wt" 2>&1); rc=$?
unset STUB_GH_RACE
chk "full mode refuses a tip that moved mid-closeout" 1 "$rc"
[ -d "$TMP/race2/wt" ] && ok "moved worktree not removed" || no "moved worktree not removed"
chk "the commit made during closeout is still on the branch" 1 \
  "$(git -C "$TMP/race2/repo" rev-list --count "$TIP..refs/heads/feat" 2>/dev/null)"

# --- 27. PLANTED NEGATIVE: proof C whose merged head cannot be fetched -------------
# The merged head exists on the server but under no ref this repo can fetch, so
# containment cannot be checked: refuse, write nothing, move nothing.
S=$(mkfix contoff 0 1); TIP=$(git -C "$TMP/contoff/wt" rev-parse HEAD)
# The tip's objects must reach the bare origin for commit-tree to build on them;
# the ref that carried them is then deleted, so the head is present but unfetchable.
pullref contoff "$TIP" 7
PRHEAD=$(git -C "$TMP/contoff/origin.git" commit-tree "$TIP^{tree}" -p "$TIP" -m "follow-up on the PR")
git -C "$TMP/contoff/origin.git" update-ref -d refs/pull/7/head
[ -n "$PRHEAD" ] && ok "fixture: merged head exists on the server" || no "fixture: merged head exists on the server"
STUB_GH_API_JSON=$(printf '[{"number":7,"merged_at":"2026-09-21T00:00:00Z","merge_commit_sha":"%s","head":{"sha":"%s"},"base":{"ref":"main"}}]' "$S" "$PRHEAD")
export STUB_GH_OUT="" STUB_GH_API_JSON
out=$(cd "$TMP/contoff/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_API_JSON
chk "unfetchable merged head refuses" 1 "$rc"
has "refuses on containment, not on lookup" "$out" "is not contained in, the commit PR #7 merged"
chk "no anchor for an unchecked containment" "" "$(anchors "$TMP/contoff/repo")"
chk "pointer unmoved" "$TIP" "$(git -C "$TMP/contoff/wt" rev-parse HEAD)"

# --- 28. a stacked child found BY NAME falls through to the parent -----------------
# The local branch name matches a child PR (#8, head == tip) that merged into its
# parent's branch, not main. Found by name, its merge commit refuses the tip; the
# name lookup filters on the default branch, so the commit lookup finds the parent
# (#7, squash-merged into main, head a descendant of this tip) and proves C.
S=$(mkfix stackname 0 1); TIP=$(git -C "$TMP/stackname/wt" rev-parse HEAD)
pullref stackname "$TIP" 7
PRHEAD=$(git -C "$TMP/stackname/origin.git" commit-tree "$TIP^{tree}" -p "$TIP" -m "parent follow-up")
git -C "$TMP/stackname/origin.git" update-ref refs/pull/7/head "$PRHEAD"
[ -n "$PRHEAD" ] && ok "fixture: parent's merged head exists on the server" \
  || no "fixture: parent's merged head exists on the server"
STUB_GH_API_JSON=$(printf '[{"number":7,"merged_at":"2026-09-21T00:00:00Z","merge_commit_sha":"%s","head":{"sha":"%s"},"base":{"ref":"main"}}]' "$S" "$PRHEAD")
export STUB_GH_OUT="8 $TIP $TIP" STUB_GH_PR_BASE=stack-parent STUB_GH_API_JSON STUB_GH_CALLS="$TMP/stackname.calls"; : >"$STUB_GH_CALLS"
out=$(cd "$TMP/stackname/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
chk "stacked child by name: parent proves containment" 0 "$rc"
has "the name lookup asked for main only" "$(cat "$STUB_GH_CALLS")" "--base main"
has "proved through the parent PR" "$out" "PR #7 merged $PRHEAD, which contains this tip"
hasnot "never stopped at the child's merge commit" "$out" "is not an ancestor of origin/main"
chk "anchor names the parent's merged head" "$PRHEAD" \
  "$(git -C "$TMP/stackname/repo" rev-parse -q --verify refs/remotes/pr-merged/feat)"
unset STUB_GH_PR_BASE STUB_GH_API_JSON STUB_GH_CALLS

# --- 29. PLANTED NEGATIVE: a GitHub error body is not a PR line ---------------------
# On an HTTP error gh prints the error JSON to stdout, skips --jq, and exits 1. That
# once reached close_one as PR #{"message":"Not ... (hermes-profiles, #1361
# backfill). It must read as "no merged PR", never as a PR to reason about.
S=$(mkfix apierr 0 1); TIP=$(git -C "$TMP/apierr/wt" rev-parse HEAD)
export STUB_GH_OUT="" STUB_GH_API_FAIL=1
out=$(cd "$TMP/apierr/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_API_FAIL
chk "an API error refuses" 1 "$rc"
has "reads as no merged PR" "$out" "not eligible"
hasnot "the error body never becomes a PR number" "$out" 'PR #{'
chk "no anchor on an API error" "" "$(anchors "$TMP/apierr/repo")"

# --- 30. a failing NAME lookup falls through to the commit lookup ------------------
# The same guard on the other lookup: an error body from `pr list` is not a PR line,
# so the commit lookup still runs and proves the tip (A, via PR #7).
S=$(mkfix nameerr 0 1); TIP=$(git -C "$TMP/nameerr/wt" rev-parse HEAD)
pullref nameerr "$TIP" 7
STUB_GH_API_JSON=$(printf '[{"number":7,"merged_at":"2026-09-21T00:00:00Z","merge_commit_sha":"%s","head":{"sha":"%s"},"base":{"ref":"main"}}]' "$S" "$TIP")
export STUB_GH_OUT="" STUB_GH_PR_FAIL=1 STUB_GH_API_JSON
out=$(cd "$TMP/nameerr/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_PR_FAIL STUB_GH_API_JSON
chk "a name-lookup error still reaches the commit lookup" 0 "$rc"
has "proved through the commit lookup" "$out" "PR #7 merged this exact tip"
hasnot "the name-lookup error body never becomes a PR" "$out" 'PR #{'

# --- 31. PLANTED NEGATIVE: an OID that is not whole is not a PR line ---------------
# 41 hex is neither SHA-1 (40) nor SHA-256 (64). In a SHA-256 repo git would take it
# as an abbreviation of some other commit, so it must be rejected before git sees it.
S=$(mkfix shortoid 0 1); TIP=$(git -C "$TMP/shortoid/wt" rev-parse HEAD)
export STUB_GH_OUT="7 ${S}0 $TIP"
out=$(cd "$TMP/shortoid/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
chk "a 41-hex merge OID refuses" 1 "$rc"
has "reads as no merged PR" "$out" "not eligible"
hasnot "the malformed OID never reaches git" "$out" "${S}0"

# Shallows a fixture the way dotfiles was shallowed live: one depth-limited fetch
# into a full clone. Every object stays, but the walk from origin/main now stops at
# the fetched tip, so the squash commit behind it is unreachable locally.
shallowfix(){
  local d="$TMP/$1"
  {
    git clone -q "$d/origin.git" "$d/other"
    echo newer >"$d/other/newer.txt"
    git -C "$d/other" add -A && git -C "$d/other" commit -qm newer
    git -C "$d/other" push -q origin main
    git -C "$d/repo" fetch -q --depth=1 origin main
  } >/dev/null 2>&1
}

# --- 32. a shallow clone's failed walk is not a refusal when GitHub confirms ------
# dotfiles, 2026-09-23: a depth-limited fetch had cut the walk at #1224, so PR #1188
# and #886 refused as "not an ancestor of origin/main" while GitHub had main 106 and
# 272 commits ahead of their merge commits. Only a shallow clone asks GitHub, and it
# takes nothing but an exact "ahead 0" or "identical 0" from --jq.
S=$(mkfix shal 0 1); TIP=$(git -C "$TMP/shal/wt" rev-parse HEAD)
pullref shal "$TIP" 7
shallowfix shal
chk "fixture: the clone is shallow" true "$(git -C "$TMP/shal/repo" rev-parse --is-shallow-repository)"
git -C "$TMP/shal/repo" cat-file -e "$S^{commit}" \
  && ok "fixture: the squash commit is still local" || no "fixture: the squash commit is still local"
git -C "$TMP/shal/repo" merge-base --is-ancestor "$S" origin/main \
  && no "fixture: the local walk should NOT reach the squash commit" \
  || ok "fixture: the local walk cannot reach the squash commit (the live state)"
export STUB_GH_OUT="7 $S $TIP" STUB_GH_COMPARE_JSON='{"status":"ahead","ahead_by":2,"behind_by":0}'
export STUB_GH_CALLS="$TMP/shal.calls"; : >"$STUB_GH_CALLS"
out=$(cd "$TMP/shal/wt" && DRY_RUN=1 bash "$SCRIPT" 2>&1); rc=$?
chk "shallow preview exits 0" 0 "$rc"
has "preview plans the anchor" "$out" "update-ref refs/remotes/pr-merged/feat $TIP"
out=$(cd "$TMP/shal/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
chk "shallow clone, GitHub confirms: proof A closes it" 0 "$rc"
has "asked GitHub about this merge commit" "$(cat "$STUB_GH_CALLS")" "/compare/$S...main"
has "says where the answer came from" "$out" "GitHub confirms it is on main"
hasnot "never claims it is not an ancestor" "$out" "not an ancestor"
chk "anchor written" "$TIP" "$(git -C "$TMP/shal/repo" rev-parse -q --verify refs/remotes/pr-merged/feat)"
chk "Agent View gate passes" "" "$(agate "$TMP/shal/wt")"
unset STUB_GH_COMPARE_JSON STUB_GH_CALLS

# --- 33. PLANTED NEGATIVE: shallow, and GitHub does not confirm -> honest refusal --
# "diverged" is what GitHub says of a commit that is not on main. The refusal names
# the shallow clone, and nothing is anchored or moved.
S=$(mkfix shalno 0 1); TIP=$(git -C "$TMP/shalno/wt" rev-parse HEAD)
pullref shalno "$TIP" 7
shallowfix shalno
export STUB_GH_OUT="7 $S $TIP" STUB_GH_COMPARE_JSON='{"status":"diverged","ahead_by":2,"behind_by":3}'
out=$(cd "$TMP/shalno/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_COMPARE_JSON
chk "shallow, not confirmed: refuses" 1 "$rc"
has "names the shallow clone as the reason" "$out" "shallow clone cannot reach PR #7 merge commit $S"
has "and that GitHub did not confirm" "$out" "GitHub did not confirm it is on main"
has "with what GitHub actually answered" "$out" "GitHub reports 'diverged 3'"
grep -qx 'WT_DONE_PROOF=head' <<<"$out" \
  && no "no machine line when unconfirmed" || ok "no machine line when unconfirmed"
chk "no anchor when unconfirmed" "" "$(anchors "$TMP/shalno/repo")"
chk "pointer unmoved" "$TIP" "$(git -C "$TMP/shalno/wt" rev-parse HEAD)"

# --- 34. PLANTED NEGATIVE: shallow, and the compare call errors -> refusal --------
# The error body arrives on stdout with exit 1; it must never read as confirmation.
S=$(mkfix shalerr 0 1); TIP=$(git -C "$TMP/shalerr/wt" rev-parse HEAD)
pullref shalerr "$TIP" 7
shallowfix shalerr
export STUB_GH_OUT="7 $S $TIP" STUB_GH_API_FAIL=1
out=$(cd "$TMP/shalerr/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_API_FAIL
chk "shallow, compare errors: refuses" 1 "$rc"
has "names the unconfirmed ancestry" "$out" "GitHub did not confirm it is on main"
has "says the call failed, not that the commit is off main" "$out" "compare call failed: gh exit 1, Not Found"
chk "no anchor on a compare error" "" "$(anchors "$TMP/shalerr/repo")"

# --- 35. PLANTED NEGATIVE: shallow, and only tree equality (B) would hold ---------
# B moves the pointer onto the merge commit, then needs local walks (the post-reset
# count, branch -d, Agent View's gate) to agree it shipped; a clone that cannot reach
# the merge commit satisfies none of them. So even with GitHub's confirmation B is
# not attempted: an honest refusal, and the git call log shows no reset at all.
S=$(mkfix shaltree); TIP=$(git -C "$TMP/shaltree/wt" rev-parse HEAD)
shallowfix shaltree
chk "fixture: tip's tree still equals the squash commit's" "" "$(git -C "$TMP/shaltree/wt" diff --stat "$S" HEAD)"
export STUB_GH_OUT="7 $S" STUB_GH_COMPARE_JSON='{"status":"ahead","ahead_by":2,"behind_by":0}'
export GIT_CALLS="$TMP/shaltree.gitcalls"; : >"$GIT_CALLS"
out=$(DRY_RUN=0 bash "$SCRIPT" "$TMP/shaltree/wt" 2>&1); rc=$?
unset STUB_GH_COMPARE_JSON GIT_CALLS
chk "shallow, B only: refuses" 1 "$rc"
has "says the content matches but the clone cannot verify a move" "$out" "this shallow clone cannot reach it, so a pointer move could not be verified"
chk "no reset was attempted" 0 "$(grep -c 'reset --soft' "$TMP/shaltree.gitcalls")"
chk "pointer unmoved" "$TIP" "$(git -C "$TMP/shaltree/wt" rev-parse HEAD)"
[ -d "$TMP/shaltree/wt" ] && ok "worktree kept" || no "worktree kept"
chk "branch kept" "$TIP" "$(git -C "$TMP/shaltree/repo" rev-parse -q --verify refs/heads/feat)"

# --- 36. PLANTED NEGATIVE: a default branch the compare URL cannot carry ------------
# 'main#release' is a valid ref name, but in a URL path '#' starts a fragment, so
# GitHub would be asked about 'main'. The stub would confirm (ahead 0), so only the
# name guard makes this refuse, and no compare call is ever made.
S=$(mkfix shalhash 0 1); TIP=$(git -C "$TMP/shalhash/wt" rev-parse HEAD)
pullref shalhash "$TIP" 7
shallowfix shalhash
git -C "$TMP/shalhash/repo" update-ref 'refs/remotes/origin/main#release' refs/remotes/origin/main
git -C "$TMP/shalhash/repo" symbolic-ref refs/remotes/origin/HEAD 'refs/remotes/origin/main#release'
export STUB_GH_OUT="7 $S $TIP" STUB_GH_COMPARE_JSON='{"status":"ahead","ahead_by":2,"behind_by":0}'
export STUB_GH_CALLS="$TMP/shalhash.calls"; : >"$STUB_GH_CALLS"
out=$(cd "$TMP/shalhash/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1); rc=$?
unset STUB_GH_COMPARE_JSON
chk "a '#' default branch refuses" 1 "$rc"
has "names why GitHub was not asked" "$out" "default branch name cannot be sent to GitHub unencoded"
hasnot "no compare call was made" "$(cat "$STUB_GH_CALLS")" "/compare/"
chk "no anchor for an unasked ancestry" "" "$(anchors "$TMP/shalhash/repo")"
unset STUB_GH_CALLS

# --- 38. PLANTED NEGATIVE: reconciled, but no merged PR -> n/a ------
# A pushed branch whose PR is still open (or was never opened) has nothing to activate.
S=$(mkfix actrecnopr 0 1)
git -C "$TMP/actrecnopr/wt" push -q origin feat >/dev/null 2>&1
export STUB_GH_OUT="" STUB_SYSTEMCTL_CALLS="$TMP/actrecnopr.calls"
: >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actrecnopr/repo" reset -q --hard "$S~1"
before=$(git -C "$TMP/actrecnopr/repo" rev-parse HEAD)
out=$(cd "$TMP/actrecnopr/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "no-PR reconciled closeout exits 0" 0 "$rc"
has "says there is no merge to activate" "$out" "activation: n/a (no merged PR for feat"
chk "never freshens without a merge" "$before" "$(git -C "$TMP/actrecnopr/repo" rev-parse HEAD)"

# --- 39. reconciled tip still resolves its PR and freshens the checkout --
S=$(mkfix actrecnone 0 1); TIP=$(git -C "$TMP/actrecnone/wt" rev-parse HEAD)
git -C "$TMP/actrecnone/wt" push -q origin feat >/dev/null 2>&1
git -C "$TMP/actrecnone/repo" reset -q --keep "$S~1"
export STUB_GH_OUT="7 $S $TIP" STUB_GH_CALLS="$TMP/actrecnone.gh"; : >"$STUB_GH_CALLS"
out=$(cd "$TMP/actrecnone/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
chk "ordinary reconciled closeout exits 0" 0 "$rc"
has "ordinary closeout takes the reconciled path" "$out" "already reconciled"
has "reconciled path first names the checkout as not current" "$out" "activation: checkout NOT current"
has "ordinary reconciled closeout resolves its merged PR" "$(cat "$STUB_GH_CALLS")" "pr list --head feat --state merged"
has "ordinary reconciled closeout proves checkout currency" "$out" "activation: checkout current"
if git -C "$TMP/actrecnone/repo" merge-base --is-ancestor "$S" HEAD; then
  ok "reconciled path's canonical HEAD contains the merge"
else
  no "reconciled path's canonical HEAD contains the merge"
fi
unset STUB_GH_CALLS

# --- 40. --reconcile-only on the reconciled path still never activates ------------
S=$(mkfix actrecrec 0 1); TIP=$(git -C "$TMP/actrecrec/wt" rev-parse HEAD)
git -C "$TMP/actrecrec/wt" push -q origin feat >/dev/null 2>&1
export STUB_GH_OUT="7 $S $TIP" STUB_SYSTEMCTL_CALLS="$TMP/actrecrec.calls"
: >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actrecrec/repo" reset -q --hard "$S~1"
before=$(git -C "$TMP/actrecrec/repo" rev-parse HEAD)
out=$(cd "$TMP/actrecrec/wt" && DRY_RUN=0 bash "$SCRIPT" --reconcile-only 2>&1)
has "reconcile-only took the reconciled path" "$out" "already reconciled"
hasnot "reconcile-only prints no activation line there either" "$out" "activation:"
chk "reconcile-only moves the checkout nowhere there either" "$before" "$(git -C "$TMP/actrecrec/repo" rev-parse HEAD)"
unset STUB_SYSTEMCTL_CALLS

# --- 41. a refused removal says why ---------------------------------------------
# run() used to discard git's output, so a refused `worktree remove` printed only
# "!! FAILED" and the closing session had to guess. A locked worktree is a
# deterministic refusal; running from the main checkout reaches the removal.
S=$(mkfix rmlocked 0 1)
git -C "$TMP/rmlocked/wt" push -q origin feat >/dev/null 2>&1
git -C "$TMP/rmlocked/repo" worktree lock --reason "fixture lock" "$TMP/rmlocked/wt"
export STUB_GH_OUT=""
out=$(cd "$TMP/rmlocked/repo" && DRY_RUN=0 bash "$SCRIPT" "$TMP/rmlocked/wt" 2>&1); rc=$?
chk "a refused removal fails the closeout" 1 "$rc"
has "names the failed command" "$out" "!! FAILED: git -C '$TMP/rmlocked/repo' worktree remove"
has "and git's own reason" "$out" "cannot remove a locked working tree"
[ -d "$TMP/rmlocked/wt" ] && ok "locked worktree left in place" || no "locked worktree left in place"

# --- 42. PLANTED NEGATIVE: a commit lands while the reconciled path activates -------
# Activation puts a GitHub lookup and a bounded checkout freshen between the
# reconciled check and the removal. A plain `worktree remove` still succeeds on a clean
# tree after a new commit, so without a re-check the directory went with it.
S=$(mkfix recrace 0 1); TIP=$(git -C "$TMP/recrace/wt" rev-parse HEAD)
git -C "$TMP/recrace/wt" push -q origin feat >/dev/null 2>&1
export STUB_GH_OUT="7 $S $TIP" STUB_GH_RACE="$TMP/recrace/wt"
out=$(cd "$TMP" && DRY_RUN=0 bash "$SCRIPT" "$TMP/recrace/wt" 2>&1); rc=$?
unset STUB_GH_RACE
chk "fixture: the lookup raced a commit in" 1 \
  "$(git -C "$TMP/recrace/repo" rev-list --count "$TIP..refs/heads/feat" 2>/dev/null)"
chk "reconciled closeout refuses a tip that moved during activation" 1 "$rc"
has "took the already-reconciled path" "$out" "already reconciled"
has "names the change" "$out" "worktree changed during closeout"
[ -d "$TMP/recrace/wt" ] && ok "moved worktree not removed" || no "moved worktree not removed"

# --- 43. PLANTED NEGATIVE: a reused branch name finds an earlier merged PR ----------
# The name lookup is not tied to the tip. PR #7 merged some other head, and this tip is
# neither that head nor inside it, so that merge says nothing about this work: n/a, and
# never "live" for someone else's merge.
S=$(mkfix actrecold 0 1); TIP=$(git -C "$TMP/actrecold/wt" rev-parse HEAD)
git -C "$TMP/actrecold/wt" push -q origin feat >/dev/null 2>&1
git -C "$TMP/actrecold/repo" merge-base --is-ancestor "$TIP" "$S" \
  && no "fixture: the PR's head does not contain this tip" || ok "fixture: the PR's head does not contain this tip"
export STUB_GH_OUT="7 $S $S" STUB_SYSTEMCTL_CALLS="$TMP/actrecold.calls"
: >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actrecold/repo" reset -q --hard "$S~1"
before=$(git -C "$TMP/actrecold/repo" rev-parse HEAD)
out=$(cd "$TMP/actrecold/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1)
has "took the already-reconciled path" "$out" "already reconciled"
has "says the PR merged another tip" "$out" "activation: n/a (merged PR #7 for feat merged ${S:0:12}, not this tip ${TIP:0:12})"
hasnot "never reports an unrelated merge" "$out" "activation: checkout"
chk "never freshens for an unrelated merge" "$before" "$(git -C "$TMP/actrecold/repo" rev-parse HEAD)"

# --- 44. the merged head contains this tip: still this branch's merge --------------
# A follow-up commit pushed to the PR after this worktree's tip: the head GitHub merged
# descends from the tip, so its merge is this work's merge and is activated.
S=$(mkfix actrecdesc 0 1); TIP=$(git -C "$TMP/actrecdesc/wt" rev-parse HEAD)
git -C "$TMP/actrecdesc/wt" push -q origin feat >/dev/null 2>&1
PRHEAD=$(git -C "$TMP/actrecdesc/repo" commit-tree "$TIP^{tree}" -p "$TIP" -m "follow-up on the PR")
export STUB_GH_OUT="7 $S $PRHEAD" STUB_SYSTEMCTL_CALLS="$TMP/actrecdesc.calls"
: >"$STUB_SYSTEMCTL_CALLS"
git -C "$TMP/actrecdesc/repo" reset -q --keep "$S~1"
out=$(cd "$TMP/actrecdesc/wt" && DRY_RUN=0 bash "$SCRIPT" 2>&1); rc=$?
unset STUB_SYSTEMCTL_CALLS
chk "a head containing the tip exits 0" 0 "$rc"
has "took the already-reconciled path" "$out" "already reconciled"
has "names the checkout as not current first" "$out" "activation: checkout NOT current"
has "activates the containing PR's merge" "$out" "activation: checkout current"
chk "checkout now includes the merge" "$(git -C "$TMP/actrecdesc/repo" rev-parse origin/main)" "$(git -C "$TMP/actrecdesc/repo" rev-parse HEAD)"

# --- 45+. ordinary activation handoff: same public command, real fixture repos ---
# A temporary installed layout lets a logging sibling delegate to the REAL helper.
# Only the no-op/timeout negative controls substitute it; neither is live proof.
INSTALLED="$TMP/installed/scripts"
mkdir -p "$INSTALLED/lib"
cp "$SCRIPT" "$INSTALLED/wt-done.sh"
cp "$HERE/../scripts/lib/wt-anchor.sh" "$INSTALLED/lib/wt-anchor.sh"
export REAL_FRESHEN="$HERE/../scripts/launchpad-freshen.sh"
export FRESHEN_CALLS="$TMP/freshen.calls" STUB_SYSTEMCTL_CALLS="$TMP/ordinary.systemctl"
cat >"$INSTALLED/launchpad-freshen.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FRESHEN_CALLS"
case "${STUB_FRESHEN_MODE:-}" in
  no-op) echo 'fixture freshener: deliberately exits 0 without updating'; exit 0 ;;
  timeout) exec sleep 10 ;;
esac
if [ -n "${STUB_FRESHEN_RACE:-}" ]; then
  printf 'POST-PROOF WORK\n' >"$STUB_FRESHEN_RACE/post-proof.txt"
  git -C "$STUB_FRESHEN_RACE" add post-proof.txt
  git -C "$STUB_FRESHEN_RACE" commit -qm 'concurrent commit during activation'
fi
exec bash "$REAL_FRESHEN" "$@"
STUB
chmod +x "$INSTALLED/launchpad-freshen.sh"
ORDINARY_SCRIPT="$INSTALLED/wt-done.sh"
ordinaryfix(){
  S=$(mkfix "$1" 0 1)
  C="$TMP/$1/repo"; W="$TMP/$1/wt"
  TIP=$(git -C "$W" rev-parse HEAD)
  git -C "$W" push -q origin feat
  git -C "$C" reset -q --keep "$S~1"
  before=$(git -C "$C" rev-parse HEAD)
  export STUB_GH_OUT="7 $S $TIP"
  : >"$FRESHEN_CALLS"; : >"$STUB_SYSTEMCTL_CALLS"
}
runordinary(){ (cd "$W" && DRY_RUN=0 bash "$ORDINARY_SCRIPT" "$@" 2>&1); }

# A collision is a refusal even with merge.autostash enabled. Retain the shared
# helper's path-level diagnosis, and verify neither HEAD, bytes nor stash moved.
ordinaryfix ordinary-conflict
# mainextra.txt is already tracked at the lagging base. Publish a later rewrite
# from another clone, so the dirty canonical path genuinely blocks the incoming ff.
git clone -q "$TMP/ordinary-conflict/origin.git" "$TMP/ordinary-conflict/updater"
printf 'INCOMING CODE\n' >"$TMP/ordinary-conflict/updater/mainextra.txt"
git -C "$TMP/ordinary-conflict/updater" add mainextra.txt
git -C "$TMP/ordinary-conflict/updater" commit -qm 'rewrite tracked file after merge'
git -C "$TMP/ordinary-conflict/updater" push -q origin main
printf 'LOCAL UNSAVED CODE\n' >"$C/mainextra.txt"
git -C "$C" config merge.autoStash true
stash_before=$(git -C "$C" stash list)
out=$(runordinary); rc=$?
chk "tracked collision never fails the closeout itself" 0 "$rc"
has "tracked collision retains real helper refusal" "$out" "ff-only merge failed"
has "tracked collision names its actual path" "$out" "mainextra.txt"
has "tracked collision reports not current" "$out" "!! activation: checkout not current"
hasnot "tracked collision never claims current" "$out" "activation: checkout current"
chk "tracked collision leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"
chk "tracked collision leaves local bytes unchanged" "LOCAL UNSAVED CODE" "$(cat "$C/mainextra.txt")"
chk "tracked collision never autostashes" "$stash_before" "$(git -C "$C" stash list)"
chk "ordinary helper gets --repo only, never --heal" "--repo $C" "$(cat "$FRESHEN_CALLS")"
chk "ordinary refusal never starts a service" "" "$(cat "$STUB_SYSTEMCTL_CALLS")"

ordinaryfix ordinary-untracked
printf 'LOCAL UNTRACKED DRAFT\n' >"$C/one.txt"
out=$(runordinary)
has "untracked collision retains differing-path diagnosis" "$out" "differs   one.txt"
has "untracked collision reports not current" "$out" "!! activation: checkout not current"
hasnot "untracked collision never claims current" "$out" "activation: checkout current"
chk "untracked collision leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"
chk "untracked collision leaves bytes unchanged" "LOCAL UNTRACKED DRAFT" "$(cat "$C/one.txt")"

ordinaryfix ordinary-nopr
export STUB_GH_OUT=""
out=$(runordinary)
has "ordinary reconciled tip without a PR says why" "$out" "no merged PR for feat"
chk "no merged PR never invokes the freshener" "" "$(cat "$FRESHEN_CALLS")"
chk "no merged PR leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"
hasnot "no merged PR never claims current" "$out" "activation: checkout current"

ordinaryfix ordinary-oldpr
export STUB_GH_OUT="7 $S $S"
out=$(runordinary)
has "ordinary reused branch rejects unrelated merged head" "$out" "not this tip ${TIP:0:12}"
chk "unrelated PR never invokes the freshener" "" "$(cat "$FRESHEN_CALLS")"
chk "unrelated PR leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-missing-merge
export STUB_GH_OUT="7 0000000000000000000000000000000000000000 $TIP"
out=$(runordinary)
has "reconciled tip rejects an absent merge object" "$out" "not present locally"
chk "absent merge never invokes the freshener" "" "$(cat "$FRESHEN_CALLS")"
chk "absent merge leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-merge-tip
# A previous --reconcile-only tree proof already moved this branch to its merge.
git -C "$W" reset -q --keep "$S"
out=$(runordinary)
has "merge-tip closeout takes the already-reconciled path" "$out" "already reconciled"
has "already-reconciled merge tip still freshens the checkout" "$out" "activation: checkout current"
if git -C "$C" merge-base --is-ancestor "$S" HEAD; then
  ok "merge-tip canonical HEAD independently contains its known merge"
else
  no "merge-tip canonical HEAD independently contains its known merge"
fi
chk "merge-tip proof invokes the normal helper once" "--repo $C" "$(cat "$FRESHEN_CALLS")"

ordinaryfix ordinary-offbase
export STUB_GH_OUT="7 $TIP $TIP"
out=$(runordinary)
has "reconciled tip rejects merge off the default branch" "$out" "not an ancestor of origin/main"
chk "off-default merge never invokes the freshener" "" "$(cat "$FRESHEN_CALLS")"
chk "off-default merge leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-false-success
out=$(STUB_FRESHEN_MODE=no-op runordinary)
has "false-success control really invoked the helper" "$out" "deliberately exits 0 without updating"
has "zero exit without ancestry still reports not current" "$out" "!! activation: checkout not current"
hasnot "zero exit alone never proves current" "$out" "activation: checkout current"
chk "false-success helper leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-timeout
out=$(WT_DONE_ACTIVATE_TIMEOUT=0.1 STUB_FRESHEN_MODE=timeout runordinary); rc=$?
chk "freshener timeout never fails closeout itself" 0 "$rc"
has "freshener timeout reports its real exit code" "$out" "rc=124"
has "freshener timeout reports not current" "$out" "!! activation: checkout not current"
hasnot "freshener timeout never claims current" "$out" "activation: checkout current"
chk "timeout leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-dry
: >"$TMP/ordinary-dry.gitcalls"
out=$(cd "$W" && GIT_CALLS="$TMP/ordinary-dry.gitcalls" DRY_RUN=1 bash "$ORDINARY_SCRIPT" 2>&1)
has "ordinary preview prints the planned freshener" "$out" "would: $INSTALLED/lib/../launchpad-freshen.sh --repo '$C'"
chk "ordinary preview never invokes even the helper's dry run" "" "$(cat "$FRESHEN_CALLS")"
chk "ordinary preview leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"
if grep -E -- ' (fetch|reset|update-ref)( |$)|worktree (prune|remove)| branch -[dD]( |$)' "$TMP/ordinary-dry.gitcalls" >/dev/null; then
  no "ordinary preview invokes no mutating Git command"
else
  ok "ordinary preview invokes no mutating Git command"
fi
out=$(runordinary --reconcile-only)
hasnot "ordinary reconcile-only prints no activation" "$out" "activation:"
chk "ordinary reconcile-only never invokes the helper" "" "$(cat "$FRESHEN_CALLS")"
chk "ordinary reconcile-only leaves canonical HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-current
git -C "$C" merge --ff-only -q origin/main
CURRENT=$(git -C "$C" rev-parse HEAD)
out=$(runordinary)
has "already-contained merge reports exact identity" "$out" "activation: checkout current ($C at $CURRENT; includes $S)"
chk "already-contained merge never invokes the helper" "" "$(cat "$FRESHEN_CALLS")"
chk "already-current HEAD is unchanged" "$CURRENT" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-descendant
PRHEAD=$(git -C "$C" commit-tree "$TIP^{tree}" -p "$TIP" -m 'follow-up on same PR')
export STUB_GH_OUT="7 $S $PRHEAD"
out=$(runordinary)
has "reconciled ordinary descendant head activates its merge" "$out" "activation: checkout current"
if git -C "$C" merge-base --is-ancestor "$S" HEAD; then
  ok "descendant proof leaves canonical HEAD containing merge"
else
  no "descendant proof leaves canonical HEAD containing merge"
fi
chk "descendant proof invokes the normal helper once" "--repo $C" "$(cat "$FRESHEN_CALLS")"

ordinaryfix ordinary-route
out=$(STUB_ROUTE_CLASS=ambiguous runordinary)
has "ordinary activation preserves route refusal" "$out" "repo route ambiguous; skipped before mutation"
hasnot "route refusal never claims current" "$out" "activation: checkout current"
chk "route refusal leaves HEAD unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"

ordinaryfix ordinary-parked
git -C "$C" switch -q -c active-work
out=$(runordinary)
has "ordinary activation retains parked-branch refusal" "$out" "parked on 'active-work'"
chk "ordinary activation never switches an active checkout" active-work "$(git -C "$C" branch --show-current)"
chk "parked checkout HEAD is unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"
hasnot "parked checkout never claims current" "$out" "activation: checkout current"

# Tree-proof reconciliation moves the branch before activation. A new commit in
# the helper's network window must not let that now-stale proof remove the tree.
S=$(mkfix ordinary-tree-race)
C="$TMP/ordinary-tree-race/repo"; W="$TMP/ordinary-tree-race/wt"
git -C "$C" reset -q --keep "$S~1"
export STUB_GH_OUT="7 $S"
out=$(cd "$TMP" && STUB_FRESHEN_RACE="$W" DRY_RUN=0 bash "$ORDINARY_SCRIPT" "$W" 2>&1); rc=$?
chk "tree-proof closeout refuses a commit during activation" 1 "$rc"
has "tree-proof race names the stale proof" "$out" "worktree changed during closeout"
if [ -d "$W" ]; then
  ok "tree-proof race preserves the worktree"
  chk "tree-proof race preserves local work" "POST-PROOF WORK" "$(cat "$W/post-proof.txt")"
else
  no "tree-proof race preserves the worktree"
  no "tree-proof race preserves local work"
fi
chk "tree-proof race leaves the new commit on its branch" 1 "$(git -C "$C" rev-list --count "$S..refs/heads/feat")"

ordinaryfix ordinary-progress
printf '%s\n' "$S" >"$C/.git/MERGE_HEAD"
out=$(runordinary)
has "ordinary activation retains in-progress refusal" "$out" "rebase/merge in progress, not touched"
chk "in-progress checkout HEAD is unchanged" "$before" "$(git -C "$C" rev-parse HEAD)"
chk "in-progress state is untouched" "$S" "$(cat "$C/.git/MERGE_HEAD")"
hasnot "in-progress checkout never claims current" "$out" "activation: checkout current"
unset STUB_SYSTEMCTL_CALLS

echo
echo "wt-done: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
