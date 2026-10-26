#!/usr/bin/env bash
# wt-sweep-reconcile.test.sh — head-proof disposal via the sweep (issue #842).
#
# THE DEFECT THIS GUARDS
#   wt-done.sh has two exact shipment proofs. Proof B (tree equality) moves the
#   branch pointer, so the sweep's `rev-list --not --remotes` reads 0 and its
#   clean-removal path fires. Proof A (GitHub's headRefOid == HEAD, trees differ
#   because main moved on) deliberately leaves the pointer alone — so before this
#   fix the sweep re-read a non-zero count, scored the shipped branch as value,
#   and parked the worktree in its preserve path: worktree removed, branch kept as
#   litter (re-pushed under PUSH=1). wt-done's inside run then told the OPERATOR
#   to "re-run from OUTSIDE", a human step for something the timer already owns.
#
#   Now --reconcile-only prints one whole line, WT_DONE_PROOF=head, and the sweep
#   matches it with `grep -x`: worktree removed AND branch -D, counted as dropped.
#
#   Planted negatives, without which this suite would pass against a sweep that
#   force-deletes every branch it sees: (1) the old prose with NO machine line, on
#   a branch whose NAME contains the token — the first draft matched a substring
#   of free text and the inward vet force-deleted exactly such a branch; (2) the
#   /tmp skip must stay on unless WT_SWEEP_ALLOW_TMP=1 is set explicitly.
#
#   Hermetic: bare origin + repo + worktree under mktemp; wt-done stubbed via
#   WT_DONE_BIN; the repo-route resolver stubbed to a verified empty scan; ROOT
#   pointed at the fixture. Never touches the operator's tree, remotes, or gh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/wt-sweep.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (output lacked '$3')";; esac; }
hasnot(){ case "$2" in *"$3"*) no "$1 (output contained '$3')";; *) ok "$1";; esac; }

# Route resolver stub: a verified scan with no routes, so no repo is skipped by
# the authority/collision guard and the sweep reaches its removal decision.
cat >"$TMP/scan-ok.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"schema": "repo-route-scan.v1", "verified": True, "routes": []}))
PY
chmod +x "$TMP/scan-ok.py"

# wt-done stubs. Both echo the branch name in prose, as the real script does;
# only the "head" variant prints the whole-line machine token.
cat >"$TMP/wt-done-head" <<'STUB'
#!/usr/bin/env bash
wt="${2:-}"
echo "  • $(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)  ($wt)"
echo "      PR #7 merged this exact tip (0000000); the default branch has since moved on"
echo "      => shipped, but left in place (trees differ; removal is the safe disposal)"
echo "WT_DONE_PROOF=head"
exit 0
STUB
cat >"$TMP/wt-done-prose" <<'STUB'
#!/usr/bin/env bash
wt="${2:-}"
echo "  • $(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)  ($wt)"
echo "      PR #7 merged this exact tip (0000000); the default branch has since moved on"
echo "      => shipped, but left in place (trees differ; removal is the safe disposal)"
exit 0
STUB
chmod +x "$TMP/wt-done-head" "$TMP/wt-done-prose"

# Builds ROOT=$TMP/$1 holding one repo, its bare origin outside the root, and one
# feature worktree on branch $2. main moves on, the feature is squash-merged, main
# is pushed: the feature commit is then reachable from no remote ref (proof-A state).
mkfix(){
  local d="$TMP/$1" br="$2"
  {
    mkdir -p "$d"
    git init --bare -q -b main "$TMP/$1-origin.git"
    git init -q -b main "$d/repo"
    git -C "$d/repo" remote add origin "$TMP/$1-origin.git"
    echo base >"$d/repo/base.txt"; git -C "$d/repo" add -A; git -C "$d/repo" commit -qm base
    git -C "$d/repo" push -q -u origin main
    git -C "$d/repo" worktree add -q "$d/repo-wt" -b "$br" main
    echo one >"$d/repo-wt/one.txt"; git -C "$d/repo-wt" add -A; git -C "$d/repo-wt" commit -qm one
    echo mainextra >"$d/repo/mainextra.txt"; git -C "$d/repo" add -A; git -C "$d/repo" commit -qm mainextra
    git -C "$d/repo" merge --squash -q "$br"; git -C "$d/repo" commit -qm "squash (#7)"
    git -C "$d/repo" push -q origin main
  } >/dev/null 2>&1
}
unp(){ git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null; }
sweep(){ # $1 root  $2 wt-done stub  $3 DRY_RUN
  DRY_RUN="$3" ROOT="$1" WT_DONE_BIN="$2" REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" \
    WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 PUSH=0 bash "$SCRIPT" 2>&1
}
# Same sweep with WT_SWEEP_ALLOW_TMP genuinely UNSET (not "0"): the default the
# timer runs under, so the /tmp skip is proven from the absent-variable path.
sweep_default_tmp(){ # $1 root  $2 wt-done stub  $3 DRY_RUN
  DRY_RUN="$3" ROOT="$1" WT_DONE_BIN="$2" REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" \
    ACTIVE_MIN=0 PUSH=0 env -u WT_SWEEP_ALLOW_TMP bash "$SCRIPT" 2>&1
}

# --- 1. fixture honesty: the branch really is on no remote ref -----------------
mkfix head feat
chk "fixture: feature commit outside every remote ref" 1 "$(unp "$TMP/head/repo-wt")"

# --- 2. DRY_RUN=1 plans both steps and touches nothing -------------------------
out=$(sweep "$TMP/head" "$TMP/wt-done-head" 1)
has "plan reports the reconcile" "$out" "merge-anchored reconcile"
has "plan lists the worktree removal" "$out" "would: git -C '$TMP/head/repo' worktree remove --force '$TMP/head/repo-wt'"
has "plan lists the branch deletion" "$out" "would: git -C '$TMP/head/repo' branch -D 'feat'"
[ -d "$TMP/head/repo-wt" ] && ok "dry run left the worktree" || no "dry run left the worktree"
git -C "$TMP/head/repo" rev-parse --verify -q refs/heads/feat >/dev/null && ok "dry run left the branch" || no "dry run left the branch"

# --- 3. DRY_RUN=0 disposes of it: worktree gone, branch gone, counted as dropped -
out=$(sweep "$TMP/head" "$TMP/wt-done-head" 0)
[ -d "$TMP/head/repo-wt" ] && no "worktree removed" || ok "worktree removed"
git -C "$TMP/head/repo" rev-parse --verify -q refs/heads/feat >/dev/null && no "branch deleted" || ok "branch deleted"
has "counted as dropped, not preserved" "$out" "removed:1  preserved-local:0  dropped:1"
has "the -D is attributed to the reconcile" "$out" "ok: git -C '$TMP/head/repo' branch -D 'feat'"

# --- 4. planted negative: prose only, branch NAME contains the token ------------
# The first draft matched `*shipped-exact-tip*` against free text and the inward
# vet force-deleted a proof-B branch named to contain it. The whole-line match
# must ignore an echoed branch name and leave this branch alone.
mkfix decoy 'feat-WT_DONE_PROOF=head-decoy'
chk "fixture: decoy branch outside every remote ref" 1 "$(unp "$TMP/decoy/repo-wt")"
out=$(sweep "$TMP/decoy" "$TMP/wt-done-prose" 0)
has "stub echoed the decoy name (the collision surface exists)" "$out" "feat-WT_DONE_PROOF=head-decoy"
hasnot "no branch -D without the machine line" "$out" "branch -D"
git -C "$TMP/decoy/repo" rev-parse --verify -q 'refs/heads/feat-WT_DONE_PROOF=head-decoy' >/dev/null \
  && ok "decoy branch preserved" || no "decoy branch preserved"
has "old behaviour pinned: preserve path, nothing dropped" "$out" "dropped:0"

# --- 5. planted negative: the /tmp skip stays on unless asked ------------------
mkfix tmpskip feat
out=$(sweep_default_tmp "$TMP/tmpskip" "$TMP/wt-done-head" 0)
has "worktree under /tmp is skipped when the flag is unset" "$out" "skip (job/tmp)"
[ -d "$TMP/tmpskip/repo-wt" ] && ok "nothing removed without WT_SWEEP_ALLOW_TMP" || no "nothing removed without WT_SWEEP_ALLOW_TMP"

# --- 6. stale tracked edits are never captured during preview ------------------
# This must reach the age/behind bundle branch, not just the clean removal path.
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' mkfix stale stale-feature
parent=$(git -C "$TMP/stale/repo" rev-parse HEAD)
tree=$(git -C "$TMP/stale/repo" rev-parse 'HEAD^{tree}')
for ((i=0; i<151; i++)); do
  parent=$(printf 'advance %s\n' "$i" | git -C "$TMP/stale/repo" commit-tree "$tree" -p "$parent")
done
git -C "$TMP/stale/repo" update-ref refs/heads/main "$parent"
git -C "$TMP/stale/repo" push -q origin main
printf 'tracked work must survive\n' >"$TMP/stale/repo-wt/one.txt"
objects_before=$(git -C "$TMP/stale/repo" count-objects -v)
refs_before=$(git -C "$TMP/stale/repo" show-ref)
index_path=$(git -C "$TMP/stale/repo-wt" rev-parse --git-path index)
cp "$index_path" "$TMP/stale-index-before"
out=$(sweep "$TMP/stale" "$TMP/wt-done-prose" 1)
has "stale preview reaches the bundle path" "$out" "bundle create"
chk "stale preview writes no stash objects" "$objects_before" "$(git -C "$TMP/stale/repo" count-objects -v)"
chk "stale preview leaves refs unchanged" "$refs_before" "$(git -C "$TMP/stale/repo" show-ref)"
cmp -s "$index_path" "$TMP/stale-index-before" && ok "stale preview leaves index unchanged" || no "stale preview leaves index unchanged"
grep -qx 'tracked work must survive' "$TMP/stale/repo-wt/one.txt" && ok "stale preview preserves tracked edits" || no "stale preview preserves tracked edits"

# A failed or empty capture must never let HEAD-only bundling erase tracked edits.
REAL_GIT=$(command -v git); export REAL_GIT
mkdir -p "$TMP/git-fail-bin" "$TMP/stale-home"
cat >"$TMP/git-fail-bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "${3:-}" = stash ] && [ "${4:-}" = create ]; then
  printf 'test: tracked capture unavailable\n' >&2
  exit "${CAPTURE_FAILURE_RC:-1}"
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$TMP/git-fail-bin/git"
for capture_rc in 1 0; do
  out=$(HOME="$TMP/stale-home" PATH="$TMP/git-fail-bin:$PATH" CAPTURE_FAILURE_RC="$capture_rc" sweep "$TMP/stale" "$TMP/wt-done-prose" 0)
  [ -d "$TMP/stale/repo-wt" ] && ok "capture rc=$capture_rc with no object preserves worktree" || no "capture rc=$capture_rc with no object preserves worktree"
  if [ -f "$TMP/stale/repo-wt/one.txt" ] && grep -qx 'tracked work must survive' "$TMP/stale/repo-wt/one.txt"; then
    ok "capture rc=$capture_rc preserves tracked edits"
  else
    no "capture rc=$capture_rc preserves tracked edits"
  fi
  has "capture rc=$capture_rc names preservation" "$out" "SKIP (tracked changes could not be captured"
done

# Positive counterpart: a real capture permits disposal only with recoverable edits.
out=$(HOME="$TMP/stale-home" sweep "$TMP/stale" "$TMP/wt-done-prose" 0)
[ ! -d "$TMP/stale/repo-wt" ] && ok "successful tracked capture permits stale disposal" || no "successful tracked capture permits stale disposal"
bundle="$TMP/stale-home/.claude/git-archive/repo/$(date +%Y%m%d)/repo-wt.bundle"
if [ -f "$bundle" ]; then
  # Raw commit arguments are packed but are not advertised as bundle refs. Unpack
  # into a fresh object store and discover the retained stash commit with fsck.
  git init -q "$TMP/recovered"
  git -C "$TMP/recovered" bundle unbundle "$bundle"
  restored=""
  while read -r _state kind oid; do
    if [ "$kind" = commit ]; then
      content=$(git -C "$TMP/recovered" show "$oid:one.txt")
      [ "$content" = 'tracked work must survive' ] && restored="$content"
    fi
  done < <(git -C "$TMP/recovered" fsck --full --no-reflogs --unreachable)
  chk "archived bundle restores the unique tracked edits" "tracked work must survive" "$restored"
else
  no "successful stale disposal created a recovery bundle"
fi

# --- 7. an anchored proof-A tip still goes through wt-done and loses its branch -
# wt-done anchors a proven tip at refs/remotes/pr-merged/<N> so Agent View's
# `HEAD --not --remotes` gate passes. If the sweep counted that anchor, `unp` would
# read 0, wt-done would never be asked, and the branch would survive as litter in
# the preserve bucket. The anchor namespace is excluded from `unp`, so the sweep
# re-asks wt-done and only its machine line authorises the -D.
mkfix anch feat
git -C "$TMP/anch/repo" update-ref refs/remotes/pr-merged/feat "$(git -C "$TMP/anch/repo-wt" rev-parse HEAD)"
chk "fixture: anchor satisfies Agent View's gate" "" \
  "$(git -C "$TMP/anch/repo-wt" rev-list --max-count=1 HEAD --not --remotes)"
out=$(sweep "$TMP/anch" "$TMP/wt-done-head" 0)
has "anchored worktree still reconciled by wt-done" "$out" "merge-anchored reconcile"
[ -d "$TMP/anch/repo-wt" ] && no "anchored worktree removed" || ok "anchored worktree removed"
git -C "$TMP/anch/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && no "anchored branch deleted" || ok "anchored branch deleted"
has "anchored branch counted as dropped" "$out" "removed:1  preserved-local:0  dropped:1"
chk "anchor pruned with the dropped branch" "" \
  "$(git -C "$TMP/anch/repo" for-each-ref refs/remotes/pr-merged)"
has "anchor pruning counted" "$out" "anchors-pruned:1"

# Planted negative: the anchor alone never authorises -D. wt-done that proves
# nothing (prose only) leaves the branch in the preserve path.
mkfix anchneg feat
git -C "$TMP/anchneg/repo" update-ref refs/remotes/pr-merged/feat "$(git -C "$TMP/anchneg/repo-wt" rev-parse HEAD)"
out=$(sweep "$TMP/anchneg" "$TMP/wt-done-prose" 0)
hasnot "no branch -D on the anchor alone" "$out" "branch -D"
git -C "$TMP/anchneg/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && ok "branch preserved without wt-done's proof" || no "branch preserved without wt-done's proof"
has "anchor-only branch not counted as dropped" "$out" "dropped:0"
git -C "$TMP/anchneg/repo" rev-parse -q --verify refs/remotes/pr-merged/feat >/dev/null \
  && ok "a preserved branch keeps its anchor" || no "a preserved branch keeps its anchor"
has "nothing pruned while the branch lives" "$out" "anchors-pruned:0"

# --- 8. orphan anchors: planned under DRY_RUN, pruned on apply -----------------
# The branch is gone (Agent View, ExitWorktree, or a human deleted it), so the
# anchor protects nothing. Deleting it never loses work: it mirrors a server ref.
mkfix orph feat
git -C "$TMP/orph/repo" update-ref refs/remotes/pr-merged/ghost "$(git -C "$TMP/orph/repo" rev-parse HEAD)"
out=$(sweep "$TMP/orph" "$TMP/wt-done-prose" 1)
has "dry run plans the orphan prune" "$out" "would: git -C '$TMP/orph/repo' update-ref -d 'refs/remotes/pr-merged/ghost'"
git -C "$TMP/orph/repo" rev-parse -q --verify refs/remotes/pr-merged/ghost >/dev/null \
  && ok "dry run left the orphan" || no "dry run left the orphan"
has "dry run counts the orphan once" "$out" "anchors-pruned:1"
out=$(sweep "$TMP/orph" "$TMP/wt-done-prose" 0)
git -C "$TMP/orph/repo" rev-parse -q --verify refs/remotes/pr-merged/ghost >/dev/null \
  && no "orphan anchor pruned on apply" || ok "orphan anchor pruned on apply"
has "apply counts the orphan" "$out" "anchors-pruned:1"
# 8b. A repo with no linked worktree left still sheds its orphans (the prune runs
# before the no-worktrees `continue`).
mkfix orph2 feat
git -C "$TMP/orph2/repo" worktree remove --force "$TMP/orph2/repo-wt" >/dev/null 2>&1
git -C "$TMP/orph2/repo" update-ref refs/remotes/pr-merged/ghost "$(git -C "$TMP/orph2/repo" rev-parse HEAD)"
out=$(sweep "$TMP/orph2" "$TMP/wt-done-prose" 0)
git -C "$TMP/orph2/repo" rev-parse -q --verify refs/remotes/pr-merged/ghost >/dev/null \
  && no "orphan pruned in a repo with no linked worktree" || ok "orphan pruned in a repo with no linked worktree"

# --- 9. PLANTED NEGATIVE: the anchor lib is missing -> refuse to sweep -----------
# This script has no errexit: an unguarded source would leave wt_unshipped_count
# undefined, every count would read empty, and the clean path would force-remove.
# The lib dir here is the real one minus wt-anchor.sh.
mkfix nolib feat
mkdir -p "$TMP/badlib"; cp "$HERE/../scripts/lib/"* "$TMP/badlib/" 2>/dev/null; rm -f "$TMP/badlib/wt-anchor.sh"
out=$(DRY_RUN=0 ROOT="$TMP/nolib" WT_DONE_BIN="$TMP/wt-done-prose" REPO_ROUTE_RESOLVER="$TMP/scan-ok.py" \
  WT_SWEEP_LIB="$TMP/badlib" WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 PUSH=0 bash "$SCRIPT" 2>&1); rc=$?
chk "missing lib exits 1" 1 "$rc"
has "names the missing lib" "$out" "wt-sweep: cannot load $TMP/badlib/wt-anchor.sh"
[ -d "$TMP/nolib/repo-wt" ] && ok "missing lib removed nothing" || no "missing lib removed nothing"

# --- 10. PLANTED NEGATIVE: the worktree changes after wt-done's proof ------------
# On the proof path unp is zeroed by wt-done's word, not counted. These stubs print
# the machine line after a commit or a new file lands (a session still working),
# so the proof no longer describes the worktree: nothing removed, nothing dropped.
cat >"$TMP/wt-done-commit" <<'STUB'
#!/usr/bin/env bash
git -C "$2" commit -q --allow-empty -m "landed after the proof" >/dev/null 2>&1
echo "WT_DONE_PROOF=head"
STUB
cat >"$TMP/wt-done-edit" <<'STUB'
#!/usr/bin/env bash
echo "written after the proof" >"$2/late.txt"
echo "WT_DONE_PROOF=head"
STUB
chmod +x "$TMP/wt-done-commit" "$TMP/wt-done-edit"
mkfix late feat
out=$(sweep "$TMP/late" "$TMP/wt-done-commit" 0)
has "a commit after the proof is named" "$out" "worktree changed after wt-done's proof"
[ -d "$TMP/late/repo-wt" ] && ok "worktree with a post-proof commit kept" || no "worktree with a post-proof commit kept"
chk "the post-proof commit is still on the branch" 2 \
  "$(git -C "$TMP/late/repo" rev-list --count main..refs/heads/feat 2>/dev/null)"
has "nothing dropped on a stale proof" "$out" "dropped:0"
mkfix lateedit feat
out=$(sweep "$TMP/lateedit" "$TMP/wt-done-edit" 0)
has "a file after the proof is named" "$out" "worktree changed after wt-done's proof"
[ -f "$TMP/lateedit/repo-wt/late.txt" ] && ok "file written after the proof survives" \
  || no "file written after the proof survives"

# --- 11. PLANTED NEGATIVE: an unreadable count is not zero ------------------------
# The branch ref names an object that does not exist, so rev-list fails. Reading
# that as 0 would send the worktree down the force-removing clean path.
mkfix badref feat
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 >"$TMP/badref/repo/.git/refs/heads/feat"
out=$(sweep "$TMP/badref" "$TMP/wt-done-prose" 0)
has "unreadable count is skipped, not scored 0" "$out" "cannot count unshipped commits"
[ -d "$TMP/badref/repo-wt" ] && ok "unreadable count removed nothing" || no "unreadable count removed nothing"

# --- 12. a refused removal says why ------------------------------------------------
# run() used to discard git's output, so the journal said "!! FAILED" and nothing
# else. `--force` once does not override a lock, so a locked worktree refuses.
mkfix locked feat
git -C "$TMP/locked/repo" worktree lock --reason "fixture lock" "$TMP/locked/repo-wt"
out=$(sweep "$TMP/locked" "$TMP/wt-done-head" 0)
has "names the failed removal" "$out" "!! FAILED: git -C '$TMP/locked/repo' worktree remove --force"
has "and git's own reason" "$out" "cannot remove a locked working tree"
[ -d "$TMP/locked/repo-wt" ] && ok "locked worktree left in place" || no "locked worktree left in place"
git -C "$TMP/locked/repo" rev-parse --verify -q refs/heads/feat >/dev/null \
  && ok "branch kept when its worktree could not be removed" || no "branch kept when its worktree could not be removed"

echo
echo "wt-sweep-reconcile: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
