#!/usr/bin/env bash
# wt-anchor.sh — merged-PR anchors, shared by wt-done.sh and wt-sweep.sh.
#
# After a squash merge plus branch deletion, the only server ref still holding a
# worktree's tip is GitHub's permanent refs/pull/<N>/head, and Claude Code's close
# gate (2.1.280, Rbn) is `git rev-list HEAD --not --remotes`. Once wt-done has proven
# the PR merged that tip and confirmed refs/pull/<N>/head names the same commit, it
# records that commit at refs/remotes/pr-merged/<branch>, which is what lets Agent
# View close the worktree. Nothing is written there before both checks pass.
#
# One anchor per local branch, named after it, so its lifetime is the branch's:
# the disposal paths drop it with the branch, and an anchor whose branch is gone
# (Agent View, ExitWorktree, or a human deleted the branch) is an orphan that both
# scripts prune. Deleting an anchor never loses work: it mirrors a server ref.
# The namespace sits outside refs/remotes/origin/ because `fetch --prune` deletes
# anything there whose source branch is gone.
#
# Sourced, never executed. Callers must fail closed if this file is missing.

WT_ANCHOR_NS="pr-merged"

wt_anchor_ref() { printf 'refs/remotes/%s/%s\n' "$WT_ANCHOR_NS" "$1"; }

# Commits on HEAD of worktree $1 that no genuine remote ref holds. Anchors are
# excluded: they make a tip closable, but only wt-done's proof may dispose of the
# branch, so both scripts must still count those commits as unshipped. Before
# --remotes, --exclude takes a pattern relative to refs/remotes/ (the full-ref form
# silently excludes nothing).
wt_unshipped_count() {
  git -C "$1" rev-list --count HEAD --not --exclude="$WT_ANCHOR_NS/*" --remotes 2>/dev/null
}

# The same count with anchors included: exactly the commits Claude Code's close
# gate sees, so 0 means Agent View / `claude rm` will close worktree $1.
wt_gate_count() {
  git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null
}

# Full refnames of anchors whose same-named local branch no longer exists.
wt_orphan_anchors() {
  LC_ALL=C comm -23 \
    <(git -C "$1" for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/$WT_ANCHOR_NS/" 2>/dev/null | LC_ALL=C sort) \
    <(git -C "$1" for-each-ref --format='%(refname:lstrip=2)' refs/heads/ 2>/dev/null | LC_ALL=C sort) |
    while IFS= read -r b; do [ -n "$b" ] && wt_anchor_ref "$b"; done
}
