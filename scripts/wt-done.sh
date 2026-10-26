#!/usr/bin/env bash
# wt-done.sh — close out a worktree whose PR has already merged.
#
# THE DEFECT THIS EXISTS TO FIX (issue #589)
#   `gh pr merge --squash` plus GitHub's delete_branch_on_merge leaves a branch's
#   commits reachable from NO durable ref. The content shipped; only the commit
#   graph is orphaned. Every downstream consumer then has to guess whether the
#   worktree is safe to drop -- and on 2026-08-28 all four guesses were measured
#   WRONG on the same feature branch (squash
#   commit 562b9bc, tree byte-identical to the branch tip):
#
#     Claude Code Agent View / `claude rm`
#         `HEAD --not --remotes` = 9  -> refuses: "has commits that are not
#         pushed anywhere". No force path exists on that surface. Upstream
#         anthropics/claude-code#78355 is open, unassigned, with no maintainer
#         workaround; v2.1.248 fixed only the adjacent case (merged into an
#         UNPUSHED LOCAL default branch), which is not this one.
#     Claude Code retention sweep
#         `rev-list --cherry-pick --right-only --no-merges origin/main...HEAD`
#         listed all 5 commits -> not recognized as shipped.
#     wt-sweep.sh
#         same `--not --remotes` count -> scores the worktree as "has value".
#     branch-triage.sh TREE-SAME
#         `git diff --quiet origin/main...HEAD` -> non-empty.
#
#   The two failures are structural, not tunable. Squash collapses N commits into
#   one, so no patch-id survives and --cherry-pick can never match a multi-commit
#   branch. And main moves on after the merge, so tree equality against main dies
#   too. The ONLY surviving proof that the work shipped is the PR's own
#   mergeCommit. That is why this script anchors there, and why you will not find
#   a diff-against-main heuristic anywhere below: every one of them is a measured
#   dead end.
#
# WHAT IT DOES
#   Resolves the merged PR for the worktree's branch, proves
#   `git diff <mergeCommit> HEAD` is empty, then moves the branch pointer to
#   <mergeCommit> with `git reset --soft`. The branch becomes an ancestor of
#   origin/<default>, so all four consumers above agree it shipped -- with no
#   change to any of them. wt-sweep's existing clean-removal path then fires on
#   its own, which is the whole point: this adds no reaper, no timer, no ledger.
#
#   When the trees differ (main moved on before the merge) but GitHub's own record
#   proves the tip shipped -- the PR's merged head IS the tip, or contains it -- the
#   pointer cannot move without rewriting files. Instead, once `ls-remote` shows the
#   PR's permanent server ref refs/pull/<N>/head names that same commit, it records
#   it at refs/remotes/pr-merged/<branch> in one update-ref (lib/wt-anchor.sh).
#   Claude Code's close gate is `git rev-list HEAD --not --remotes` (2.1.280,
#   function Rbn), so a remote-tracking ref holding the tip is exactly what lets
#   Agent View / `claude rm` close the worktree: no branch move, no file touched,
#   nothing pushed. Measured 2026-09-23: 254 of 304 worktrees Agent View refused
#   on this host were in this state. The namespace sits outside refs/remotes/origin/
#   because `fetch --prune` deletes anything there whose source branch is gone.
#   Anchors are written only after the proof, never for an open or rejected PR, so
#   "reachable from a remote ref" keeps meaning "shipped" for every consumer that
#   reads it -- including Claude Code's automatic cleanupStaleAgentWorktrees. That
#   is why this is not a blanket `+refs/pull/*/head` fetch refspec.
#
# WHY --soft AND NOT --hard
#   The trees are proven identical before the reset, so --soft moves the pointer
#   and touches zero files. If that proof were ever wrong, --soft surfaces the
#   delta as staged changes instead of destroying it, and the verification step
#   below catches the non-empty `status --porcelain` and rolls the pointer back.
#   --hard would have deleted the very work this script exists to protect. It is
#   also why git-guard's `reset --hard` rule is not in play: nothing here needs
#   an ALLOW_DESTRUCTIVE_GIT escape.
#
# WHY IT WILL NOT REMOVE THE WORKTREE IT IS STANDING IN
#   Removing $PWD's own worktree leaves the calling shell (and a Claude Code
#   session) on a deleted inode. When invoked from inside the target, it stops
#   after the reconcile and says so; the removal is then done by wt-sweep on its
#   weekly timer -- proof B via the moved pointer, proof A via the
#   WT_DONE_PROOF=head line printed under --reconcile-only -- or by Claude Code's
#   cleanup where it applies (Agent View once the pointer moved or the pr-merged
#   anchor landed; ExitWorktree only for worktrees the session itself created).
#   Never by a human re-running this script from somewhere else.
#
# USAGE
#   wt-done.sh [<worktree>...]        default target: the worktree holding $PWD
#   wt-done.sh --all [--repo <dir>]   every linked worktree of that repo
#   --reconcile-only                  move the pointer or anchor the tip, never remove anything
#   DRY_RUN=1 (default) prints the plan; DRY_RUN=0 executes.
#
#   Exit 0 when every target was reconciled, was already reconciled, or would be
#   under DRY_RUN. Exit 1 if any target was refused or was not eligible.
set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"
# Preview is cached-state-only: no fetch, no optional index refresh. If cached
# objects cannot prove shipment, close_one() follows its existing refusal paths.
[ "$DRY_RUN" = 1 ] && export GIT_OPTIONAL_LOCKS=0
# Merged-PR anchors (see WHAT IT DOES): namespace, unshipped count, orphan listing.
# Shared with wt-sweep.sh. Missing lib = refuse to run: without it the unshipped
# count would read empty, i.e. "already reconciled", and remove the worktree.
_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/wt-anchor.sh"
# shellcheck source=SCRIPTDIR/lib/wt-anchor.sh
. "$_lib" 2>/dev/null || { echo "wt-done: cannot load $_lib" >&2; exit 1; }
RECONCILE_ONLY=0
ALL=0
REPO_ARG=""
TARGETS=()
rc_overall=0
declare -A _fetched
declare -A _activated

usage() {
  sed -n '2,84p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --reconcile-only) RECONCILE_ONLY=1 ;;
    --all)            ALL=1 ;;
    --repo)           REPO_ARG="${2:-}"; shift ;;
    -h|--help)        usage 0 ;;
    -*)               echo "wt-done: unknown flag: $1" >&2; usage 1 ;;
    *)                TARGETS+=("$1") ;;
  esac
  shift
done

run() {
  local out
  if [ "$DRY_RUN" = 1 ]; then echo "      would: $*"; return 0; fi
  # eval is deliberate and matches wt-sweep.sh's run(): callers pass ONE string
  # with inner-quoted paths ("git -C '$repo' worktree remove '$wt'") so the same
  # text is what DRY_RUN prints and what DRY_RUN=0 executes. Dropping eval would
  # let the printed plan and the executed command drift apart.
  # The output is kept only to explain a failure: a bare "!! FAILED" left the closing
  # session guessing why `worktree remove` refused (papercut, 2026-09). It is
  # indented and capped at five lines.
  # shellcheck disable=SC2294
  if out=$(eval "$@" 2>&1); then echo "      ok: $*"; return 0; fi
  echo "      !! FAILED: $*"
  [ -n "$out" ] && printf '%s\n' "$out" | head -n 5 | sed 's/^/         /'
  return 1
}

# Default branch name for a repo, same resolution order wt-sweep.sh uses.
def_of() {
  local r="$1" d
  d=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
  if [ -z "$d" ]; then
    for c in main master; do
      git -C "$r" rev-parse --verify -q "origin/$c" >/dev/null 2>&1 && { d="$c"; break; }
    done
  fi
  echo "${d:-main}"
}

# owner/repo, but ONLY for a real github.com remote. A non-GitHub or local-path
# remote yields "", and the gh call below then omits --repo and resolves from cwd
# -- which is exactly what lets the hermetic test point a fixture at a bare repo
# on disk without teaching the stub about slugs.
slug_of() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  case "$url" in
    *github.com[:/]*)
      url="${url#*github.com}"; url="${url#:}"; url="${url#/}"; echo "${url%.git}" ;;
    *) echo "" ;;
  esac
}

# Echoes "<pr-number> <merge-commit-sha> <head-sha>" for a MERGED PR, else "".
# Isolated in one function so the test suite can stub `gh` wholesale and so the
# no-merged-PR refusal has a single, obvious origin.
#
# First by branch name, then by commit. The name lookup misses every tip that was
# pushed under a different name (`git push origin HEAD:<pr-branch>`, a fixer
# worktree joining someone else's PR -- a private app repository's change, two papercuts). GitHub's
# commit->PR endpoint returns merged and open PRs containing a commit that is not
# on the default branch, which is exactly a squash-merged tip; merged ones only,
# into the default branch only, preferring the PR whose head IS the tip. The base
# filter matters for stacks: a child PR whose head is this tip but which merged
# into its parent's branch would otherwise win, and its merge commit (not on the
# default branch) would refuse a tip the parent's squash provably shipped. The
# name lookup filters on the same base for the same reason, so a stacked child
# found by name falls through to the commit lookup instead of stopping there.
merged_pr_commit() {
  local repo="$1" br="$2" tip="${3:-}" def="${4:-}" slug api_slug out
  local -a args=(pr list --head "$br" --state merged --limit 1)
  slug=$(slug_of "$repo")
  [ -n "$slug" ] && args+=(--repo "$slug")
  [ -n "$def" ] && args+=(--base "$def")
  # shellcheck disable=SC2054  # the comma belongs to gh's --json VALUE, not the array
  args+=(--json number,mergeCommit,headRefOid
         --jq '.[0] | select(.mergeCommit != null) | "\(.number) \(.mergeCommit.oid) \(.headRefOid // "")"')
  out=$(cd "$repo" && gh "${args[@]}" 2>/dev/null) && prline_ok "$out" || out=""
  if [ -z "$out" ] && [ -n "$tip" ]; then
    # {owner}/{repo} is gh's own placeholder, resolved from cwd like `pr list`
    # without --repo, so a non-GitHub fixture remote needs no slug here either.
    api_slug="${slug:-"{owner}/{repo}"}"
    out=$(cd "$repo" && gh api "repos/$api_slug/commits/$tip/pulls" --jq \
      "[.[] | select(.merged_at != null and .merge_commit_sha != null and .base.ref == \"$def\")]
       | (map(select(.head.sha == \"$tip\")) + .) | .[0] // empty
       | \"\(.number) \(.merge_commit_sha) \(.head.sha // \"\")\"" 2>/dev/null) && prline_ok "$out" || out=""
  fi
  printf '%s' "$out"
}

# Only a line the --jq filter itself produced counts: "<pr> <merge-sha> [<head-sha>]".
# On an HTTP error `gh api` prints the error body to stdout and exits non-zero, and
# its --jq is not applied, so that body must never be read as a PR line (a 404 once
# arrived as PR #{"message":"Not ...). Also rejects an empty or partial answer.
# OIDs are whole: 40 hex (SHA-1) or 64 (SHA-256). Anything in between would reach
# git as an abbreviation and could name some other local commit.
prline_ok() {
  local oid='([0-9a-f]{40}|[0-9a-f]{64})'
  local re="^[0-9]+ $oid( $oid| )?\$"
  [[ $1 =~ $re ]]
}

# GitHub's answer to "is this merge commit on the default branch", asked only when
# the local walk failed in a shallow clone. A depth-limited fetch into a full clone
# leaves every object in place but cuts the walk at its boundary (dotfiles, from
# 2026-09-22: PR #1188 and #886 refused as "not an ancestor" while GitHub had main
# ahead of both). compare <mc>...<def> reads "ahead" with behind_by 0 exactly when
# mc is an ancestor of def, "identical" when it is def. Same rule as prline_ok:
# only a line the --jq produced, with gh exiting 0, counts; an error body is not one.
# On a refusal it leaves what GitHub said in the caller's cmp_said, so an outage never
# reads like "not on main". That text is cut to one line of plain characters: it is
# echoed into output wt-sweep scans for a whole-line machine token.
on_default_remote() {
  local repo="$1" mc="$2" def="$3" slug out rc msg
  # A ref name may hold what a URL path cannot carry literally ('#' starts a fragment,
  # '?' a query), and GitHub would then be asked about some other ref.
  case "$def" in ""|*[!A-Za-z0-9._/-]*)
    cmp_said="default branch name cannot be sent to GitHub unencoded"; return 1 ;;
  esac
  slug=$(slug_of "$repo")
  out=$(cd "$repo" && gh api "repos/${slug:-"{owner}/{repo}"}/compare/$mc...$def?per_page=1" \
    --jq '"\(.status) \(.behind_by)"' 2>/dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    msg=$(printf '%s' "$out" | jq -r '.message? // empty' 2>/dev/null | tr -cd 'A-Za-z0-9 ._-' | cut -c1-80)
    cmp_said="compare call failed: gh exit $rc${msg:+, $msg}"
    return 1
  fi
  case "$out" in "ahead 0"|"identical 0") return 0 ;; esac
  cmp_said="GitHub reports '$(printf '%s' "$out" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-40)'"
  return 1
}

# The PR head's commit object, made local without writing any ref (FETCH_HEAD
# only). Preview never fetches, so a head that is not cached cannot prove
# containment there and the caller refuses, as for an uncached merge commit.
have_pr_head() {
  local repo="$1" pr="$2" oid="$3"
  git -C "$repo" cat-file -e "${oid}^{commit}" 2>/dev/null && return 0
  [ "$DRY_RUN" = 1 ] && return 1
  git -C "$repo" fetch --quiet --no-tags --no-prune origin "refs/pull/$pr/head" >/dev/null 2>&1
  git -C "$repo" cat-file -e "${oid}^{commit}" 2>/dev/null
}

# Make the proven tip reachable from a remote-tracking ref Claude Code's close gate
# counts. GitHub's permanent refs/pull/<N>/head must name the same commit the PR API
# recorded as merged, and it is READ (ls-remote) before anything is written: a
# refs/remotes/ ref is itself the "shipped" claim Agent View and cleanup trust, so it
# is published once, by one update-ref of the verified OID. An interrupted run leaves
# no anchor rather than an unverified one. The object is already local: it is the tip
# (A), or have_pr_head fetched it (C); update-ref refuses a missing object anyway.
# Returns 0 only when the worktree's HEAD then reads 0 commits outside remote refs.
anchor_pr() {
  local repo="$1" wt="$2" pr="$3" oid="$4" br="$5" ref srv rc left orphan n=0
  ref=$(wt_anchor_ref "$br")
  if [ "$DRY_RUN" = 1 ]; then
    echo "      would: git -C '$repo' update-ref $ref $oid (once refs/pull/$pr/head is read and names it)"
    return 0
  fi
  # Orphans first. An anchor whose branch is gone protects nothing, and a stale
  # pr-merged/<x> would make this write fail for a branch named <x>/<y> (ref D/F
  # conflict). Here rather than only in wt-sweep: the sweep skips route-collision
  # repos entirely, and those hold the most worktrees.
  while IFS= read -r orphan; do
    git -C "$repo" update-ref -d "$orphan" >/dev/null 2>&1 && n=$((n+1))
  done < <(wt_orphan_anchors "$repo")
  [ "$n" -gt 0 ] && echo "      ok: pruned $n orphan anchor(s) (branch gone)"
  srv=$(git -C "$repo" ls-remote --exit-code origin "refs/pull/$pr/head" 2>/dev/null); rc=$?
  if [ "$rc" = 2 ]; then
    echo "      note: origin has no refs/pull/$pr/head (not GitHub?); no anchor, so Agent View still refuses this worktree"
    return 1
  elif [ "$rc" != 0 ]; then
    echo "      note: could not read refs/pull/$pr/head (offline?); no anchor, so Agent View still refuses this worktree"
    return 1
  fi
  srv="${srv%%[[:space:]]*}"
  if [ "$srv" != "$oid" ]; then
    echo "      !! refs/pull/$pr/head is ${srv:-missing}, but PR #$pr records $oid as merged; no anchor written"
    return 1
  fi
  if ! git -C "$repo" update-ref "$ref" "$oid" >/dev/null 2>&1; then
    echo "      !! could not write $ref; no anchor, so Agent View still refuses this worktree"
    return 1
  fi
  left=$(wt_gate_count "$wt")
  if [ "${left:-1}" != 0 ]; then
    echo "      !! anchored $ref, but $left commit(s) are still outside remote refs"
    return 1
  fi
  echo "      ok: anchored $ref -> ${oid:0:12} (0 commits outside remote refs; Agent View can close it)"
  return 0
}

# Proof A and C are about $tip, captured before the GitHub lookup, the anchor step and
# (full mode) activation: network round trips and a bounded checkout freshen. A
# commit or an edit made in that window is work no PR saw, so the proof must not be
# spent on it. Checked immediately before the proof is handed to wt-sweep and before
# removal; remove_worktree re-checks the branch OID itself right before -D. The
# already-reconciled path activates too, so it re-checks its tip the same way: a plain
# `worktree remove` still succeeds on a clean tree after a new commit. Proof B checks
# its new identity (the merge commit) after activation, before spending that proof.
still_proven() {
  local wt="$1" br="$2" tip="$3" now_br now
  now_br=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)
  now=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null)
  if [ "$now_br" != "$br" ] || [ "$now" != "$tip" ] || [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    echo "      => REFUSE (worktree changed during closeout: ${tip:0:12} on $br was proven, now ${now:0:12} on ${now_br:-detached}, or it has local changes)"
    return 1
  fi
}

# Proof A and C leave the pointer where it is (see close_one); B moves it.
pointer_kept() { case "$1" in head|contained) return 0 ;; esac; return 1; }

close_one() {
  local wt="$1" repo cdir br porc unp def prline pr mc head_oid tip proof orig unreach=0 cmp_said=""

  wt="${wt%/}"
  [ -d "$wt" ] || { echo "  ! not a directory: $wt"; return 1; }
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || { echo "  ! not a git worktree: $wt"; return 1; }

  cdir=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)
  case "$cdir" in /*) ;; *) cdir="$wt/$cdir" ;; esac
  cdir=$(realpath -m "$cdir" 2>/dev/null)
  repo=$(dirname "$cdir")

  br=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || br=""
  [ -z "$br" ] && { echo "  ~ skip (detached HEAD): $wt"; return 1; }

  def=$(def_of "$repo")
  [ "$br" = "$def" ] && { echo "  ~ skip (default branch): $br"; return 1; }

  echo "  • $br  ($wt)"

  # Refuse on ANY local modification. A merged PR says nothing about files
  # written after the merge, and this script must never be the reason an edit
  # disappears. wt-sweep's WIP-commit path exists for that case; this one stops.
  porc=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$porc" ]; then
    echo "      => REFUSE (worktree has local changes; wt-done never discards)"
    return 1
  fi

  # Apply mode freshens remote refs once per shared object store. Preview never
  # fetches: it uses cached refs and objects, then refuses conservatively if the
  # merge proof is unavailable locally.
  if [ -z "${_fetched[$repo]:-}" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "      note: dry run uses cached refs (no fetch)"
    else
      git -C "$repo" fetch --quiet origin 2>/dev/null || \
        echo "      note: fetch failed (offline?); proceeding on cached refs"
    fi
    _fetched[$repo]=1
  fi

  # Read before the count, never after: a commit landing between the two is then either
  # counted or caught by still_proven, rather than becoming the tip the re-check trusts.
  tip=$(git -C "$wt" rev-parse HEAD)
  # Anchors are excluded here on purpose: a tip held only by a pr-merged anchor is
  # closable, but its branch still needs this script's proof to be deleted (plain
  # `branch -d` can never agree after a squash), so it takes the proof path again
  # rather than the already-reconciled one.
  unp=$(wt_unshipped_count "$wt"); unp="${unp:-0}"
  if [ "$unp" = 0 ]; then
    echo "      => already reconciled (0 commits outside remote refs)"
    [ "$RECONCILE_ONLY" = 1 ] && return 0
    activate_reconciled "$repo" "$br" "$tip" "$def"
    still_proven "$wt" "$br" "$tip" || return 1
    remove_worktree "$repo" "$wt" "$br" "$def"
    return $?
  fi

  prline=$(merged_pr_commit "$repo" "$br" "$tip" "$def")
  if [ -z "$prline" ]; then
    echo "      => not eligible ($unp commit(s) outside remote refs, no MERGED PR for $br or ${tip:0:12})"
    return 1
  fi
  read -r pr mc head_oid <<<"$prline"

  if ! git -C "$repo" cat-file -e "${mc}^{commit}" 2>/dev/null; then
    echo "      => REFUSE (merge commit $mc for PR #$pr not present locally)"
    return 1
  fi

  # The merge commit must actually be on the default branch. Without this a PR
  # merged into some other base would read as "shipped to main" and the pointer
  # move would strand the branch somewhere it was never merged. A shallow clone's
  # walk stops at its boundary, so there a failed walk proves nothing either way
  # and GitHub's own history answers instead (on_default_remote).
  if ! git -C "$repo" merge-base --is-ancestor "$mc" "origin/$def" 2>/dev/null; then
    if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
      echo "      => REFUSE (PR #$pr merge commit $mc is not an ancestor of origin/$def)"
      return 1
    fi
    if ! on_default_remote "$repo" "$mc" "$def"; then
      echo "      => REFUSE (shallow clone cannot reach PR #$pr merge commit $mc from origin/$def, and GitHub did not confirm it is on $def: $cmp_said)"
      return 1
    fi
    echo "      note: shallow clone cannot reach $mc from origin/$def; GitHub confirms it is on $def"
    unreach=1
  fi

  # THE PROOF. Two independent ways a branch can be shown to hold nothing the PR
  # did not ship. Neither is a heuristic; both are exact identities.
  #
  #   A (headRefOid, general) — GitHub records the exact commit the PR merged. If
  #     the tip is still that commit, the squash captured every commit on the
  #     branch BY CONSTRUCTION, no matter how far the default branch has moved.
  #   B (tree equality) — the tip's tree matches the merge commit's byte for byte.
  #
  # B alone was the original test (issue #589) and it silently under-covers: a
  # squash commit is base-main-at-merge-time PLUS the branch's changes, so any
  # OTHER PR that landed in between makes the trees differ even though nothing on
  # this branch is unshipped. Measured on this repo: B alone reconciled 43 of 69
  # stuck worktrees; wt-done.sh's own worktree was one of the 26 it refused.
  #
  #   C (containment) — the tip is an ANCESTOR of the head GitHub merged: more
  #     commits landed on the PR after this worktree pushed (a fixer joining a
  #     shared PR branch, a teammate's follow-up). Every commit here is inside what
  #     the squash captured, by the same construction as A. A tip that is AHEAD of
  #     the merged head holds work the PR never saw and matches none of A/B/C.
  #
  # B moves the pointer onto the merge commit and then relies on LOCAL walks to agree
  # it shipped: the post-reset count below, `branch -d`, and Agent View's own gate. A
  # shallow clone that cannot reach the merge commit ($unreach) can satisfy none of
  # them, so B is not offered there; A and C anchor instead and need no walk.
  proof=""
  [ -n "$head_oid" ] && [ "$head_oid" = "$tip" ] && proof="head"
  if [ -z "$proof" ] && [ "$unreach" = 0 ] && git -C "$wt" diff --quiet "$mc" HEAD 2>/dev/null; then proof="tree"; fi
  if [ -z "$proof" ] && [ -n "$head_oid" ] && have_pr_head "$repo" "$pr" "$head_oid" &&
     git -C "$repo" merge-base --is-ancestor "$tip" "$head_oid" 2>/dev/null; then
    proof="contained"
  fi
  if [ -z "$proof" ] && [ "$unreach" = 1 ] && git -C "$wt" diff --quiet "$mc" HEAD 2>/dev/null; then
    echo "      => REFUSE (content matches PR #$pr's merge commit $mc, but this shallow clone cannot reach it, so a pointer move could not be verified; closing it needs the full history)"
    return 1
  fi
  if [ -z "$proof" ]; then
    echo "      => REFUSE (tip is not, and is not contained in, the commit PR #$pr merged, and content differs from $mc):"
    git -C "$wt" diff --stat "$mc" HEAD 2>/dev/null | sed 's/^/         /'
    return 1
  fi

  # Proof A or C without B means the branch shipped but the working tree does NOT
  # match the merge commit. `reset --soft` is then the wrong move: it would leave the
  # old files in place, `status` would read dirty, and the post-reset check below would
  # roll it straight back. `reset --hard` would fix that by rewriting the operator's
  # files, which this script will not do on its own say-so. So the pointer stays put,
  # the tip is anchored to the PR's server-side ref instead, and removal (which needs
  # no pointer move to be correct) is the disposal.
  if pointer_kept "$proof"; then
    if [ "$proof" = "head" ]; then
      echo "      PR #$pr merged this exact tip ($tip); the default branch has since moved on"
    else
      echo "      PR #$pr merged $head_oid, which contains this tip ($tip)"
    fi
    # A missing anchor (offline, not GitHub) leaves the proof standing; only Agent
    # View's closability depends on it. still_proven below is what guards disposal.
    anchor_pr "$repo" "$wt" "$pr" "$head_oid" "$br"
    if [ "$RECONCILE_ONLY" = 1 ]; then
      still_proven "$wt" "$br" "$tip" || return 1
      echo "      => shipped, but left in place (trees differ; removal is the safe disposal)"
      # Machine line for wt-sweep.sh, its only programmatic consumer. The pointer stays
      # put, and wt-sweep counts unshipped commits with the pr-merged anchors excluded,
      # so without this line it would park the worktree in its preserve path.
      # GitHub naming this tip (A) or a descendant of it (C) as the commit it merged is
      # the disposal authority, the same rule as the full-mode removal below. Whole
      # line, matched with grep -x, so a branch name echoed elsewhere in the output can
      # never collide with it. The token keeps its original name for that contract.
      # Delete when: wt-done and wt-sweep share one exit-code contract.
      echo "WT_DONE_PROOF=head"
      return 0
    fi
    activate "$repo" "$mc"
    if [ "$DRY_RUN" = 1 ]; then
      echo "      would: remove worktree + delete branch $br"
      return 0
    fi
    still_proven "$wt" "$br" "$tip" || return 1
    remove_worktree "$repo" "$wt" "$br" "$def" "$proof" "$tip"
    return $?
  fi

  echo "      PR #$pr merged as $mc; tree identical ($unp commit(s) to reconcile)"
  orig="$tip"

  if [ "$DRY_RUN" = 1 ]; then
    echo "      would: git -C '$wt' reset --soft $mc"
    [ "$RECONCILE_ONLY" = 1 ] || echo "      would: remove worktree + delete branch $br"
    [ "$RECONCILE_ONLY" = 1 ] || activate "$repo" "$mc"
    return 0
  fi

  if ! git -C "$wt" reset --soft "$mc" >/dev/null 2>&1; then
    echo "      !! FAILED: reset --soft $mc"
    return 1
  fi

  # Verify, then roll back on any surprise. --soft cannot lose a file, so a
  # non-empty status here means the equality proof was wrong and the honest move
  # is to put the pointer back and refuse rather than to remove anything.
  porc=$(git -C "$wt" status --porcelain 2>/dev/null)
  unp=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null); unp="${unp:-0}"
  if [ -n "$porc" ] || [ "$unp" != 0 ]; then
    echo "      !! post-reset check failed (dirty:$([ -n "$porc" ] && echo yes || echo no) unpushed:$unp) — rolling back to $orig"
    git -C "$wt" reset --soft "$orig" >/dev/null 2>&1
    return 1
  fi
  echo "      => reconciled to $mc (0 commits outside remote refs)"

  [ "$RECONCILE_ONLY" = 1 ] && return 0
  activate "$repo" "$mc"
  still_proven "$wt" "$br" "$mc" || return 1
  remove_worktree "$repo" "$wt" "$br" "$def"
}

# ---- activation (issue #909) ----------------------------------------------------
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — close_one(), right after proof of shipment, in full mode only, and
#                 activate_reconciled() on the already-reconciled path.
#                 --reconcile-only (wt-sweep's triage call) never activates: it moves
#                 pointers, it does not deploy.
#   gate        — none. A refused or failed activation never fails the closeout; the
#                 checkout is reported as current or not current and the next safe
#                 fast-forward is the backstop.
#   defect      — OBSERVED (dotfiles#909, 2026-09-02): PR #893 merged 19:53:47; the
#                 canonical checkout that ~/.claude/* symlinks into sat one commit behind
#                 until 20:01:51, and the session that merged it closed by telling the
#                 operator to run sync.sh install (same shape as #355 and #508/#510).
#   delete-when — a merge event on the host itself refreshes the canonical checkout
#                 (webhook or a path unit on the fetch), so no caller has to ask for it.
#
# No git write command other than the safe fast-forward helper runs against $repo
# from here. That checkout may carry unrelated local state, and a stash-pop conflict
# once froze one (memory: stash-pop-conflict-froze-dotfiles-checkout), so activation
# is: is the merge commit already an ancestor of the checkout's HEAD; if not, run
# launchpad-freshen.sh under its own route, in-progress-state and ff-only guards and
# wait (bounded); re-check; say which it is.

# There is no common runtime deploy contract. Only freshen the checkout,
# using the installed sibling's route, in-progress-state and ff-only/autostash=false
# guards. No --heal: a closeout must not switch an active off-default checkout.
# The helper deliberately exits 0 even on refusal, so its output is retained and
# HEAD ancestry, independently re-read afterward, is the only success evidence.
activate_checkout() {
  local repo="$1" mc="$2" head rc freshener
  freshener="$(dirname "$_lib")/../launchpad-freshen.sh"
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || {
    echo "      !! activation: checkout not current (cannot read HEAD of $repo)"
    return 0
  }
  if git -C "$repo" merge-base --is-ancestor "$mc" "$head" 2>/dev/null; then
    echo "      activation: checkout current ($repo at $head; includes $mc)"
    return 0
  fi
  echo "      activation: checkout NOT current ($repo at $head; merge $mc not applied)"
  if [ "$DRY_RUN" = 1 ]; then
    # Even the freshener's own dry run fetches. Preview must not invoke it at all.
    echo "      would: $freshener --repo '$repo' (safe fast-forward; no branch switch)"
    return 0
  fi
  if [ ! -x "$freshener" ]; then
    echo "      !! activation: checkout not current (safe freshener missing: $freshener)"
    return 0
  fi
  echo "      activating checkout: $freshener --repo '$repo' (waits up to ${WT_DONE_ACTIVATE_TIMEOUT:-90}s)"
  timeout --kill-after=5 "${WT_DONE_ACTIVATE_TIMEOUT:-90}" "$freshener" --repo "$repo"; rc=$?
  [ "$rc" = 0 ] || echo "      !! activation: checkout freshener did not finish cleanly (rc=$rc; 124 means timeout)"
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || {
    echo "      !! activation: checkout not current (cannot re-read HEAD of $repo after freshening)"
    return 0
  }
  if git -C "$repo" merge-base --is-ancestor "$mc" "$head" 2>/dev/null; then
    echo "      activation: checkout current ($repo at $head; includes $mc)"
  else
    echo "      !! activation: checkout not current ($repo still at $head; merge $mc not applied; freshener output above)"
  fi
  return 0
}

activate() {
  local repo="$1" mc="$2"
  [ -n "${_activated[$repo]:-}" ] && return 0
  _activated[$repo]=1
  # Said once per repo rather than left silent: the closing session is told to report
  # the activation line, and its absence read as a skipped step (seven papercuts
  # from five repos, 2026-09).
  activate_checkout "$repo" "$mc"
  return 0
}

# The already-reconciled path proved nothing through a PR, so it has no merge commit to
# hand activate(). It is the usual path when wt-done runs in the same command as
# `gh pr merge`: GitHub has not deleted the branch yet, so origin/<branch> still holds
# the tip, and PRs #966 and #969 closed that way without their merge ever going live.
# Ordinary repos need that same proof before a safe checkout refresh, too: a tip
# merely being pushed says nothing about whether its PR merged.
activate_reconciled() {
  local repo="$1" br="$2" tip="$3" def="$4" prline pr mc head cmp_said=""
  prline=$(merged_pr_commit "$repo" "$br" "$tip" "$def")
  if [ -z "$prline" ]; then
    echo "      activation: n/a (no merged PR for $br, so no merge to activate)"
    return 0
  fi
  read -r pr mc head <<<"$prline"
  # The name lookup is not tied to this tip: a reused branch name finds an earlier PR,
  # and its merge says nothing about this work. Require this exact merged head or an
  # ancestor of it. A prior tree-proof reconciliation may instead
  # have moved the tip to this exact merge commit; its default-branch proof is below.
  if [ "$head" != "$tip" ] && ! { [ -n "$head" ] && git -C "$repo" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; }; then
    if [ "$tip" != "$mc" ]; then
      echo "      activation: n/a (merged PR #$pr for $br merged ${head:0:12}, not this tip ${tip:0:12})"
      return 0
    fi
  fi
  # The unreconciled path already checked this. A merely pushed ordinary tip
  # bypassed that path, so require a real local merge object on origin/<default>
  # before any refresh.
  if ! git -C "$repo" cat-file -e "${mc}^{commit}" 2>/dev/null; then
    echo "      activation: n/a (merge commit $mc for PR #$pr not present locally)"
    return 0
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$mc" "origin/$def" 2>/dev/null; then
    if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
      echo "      activation: n/a (PR #$pr merge commit $mc is not an ancestor of origin/$def)"
      return 0
    fi
    if ! on_default_remote "$repo" "$mc" "$def"; then
      echo "      activation: n/a (shallow clone cannot reach PR #$pr merge commit $mc from origin/$def, and GitHub did not confirm it is on $def: $cmp_said)"
      return 0
    fi
  fi
  activate "$repo" "$mc"
}

remove_worktree() {
  local repo="$1" wt="$2" br="$3" def="$4" proof="${5:-}" tip="${6:-}" here inside=0
  here=$(realpath -m "$PWD" 2>/dev/null)
  case "$here" in
    "$(realpath -m "$wt" 2>/dev/null)"|"$(realpath -m "$wt" 2>/dev/null)"/*) inside=1 ;;
  esac
  if [ "$inside" = 1 ]; then
    # Under proof A/C the pointer was deliberately NOT moved. With the pr-merged anchor
    # in place Agent View / `claude rm` can close the worktree; if the anchor could not
    # be written (offline) they still refuse on their unpushed-commit count, and
    # ExitWorktree only covers worktrees the session created itself. Either way
    # disposal is also wt-sweep's job (it reads WT_DONE_PROOF=head from
    # --reconcile-only). Never print a task for a human here: the operator's standing
    # rule is that no command is ever handed back.
    if pointer_kept "$proof"; then
      if [ "$(wt_gate_count "$wt")" = 0 ]; then
        echo "      => shipped; pointer intentionally not moved, tip anchored to the merged PR's ref."
        echo "         Agent View can close this worktree now; wt-sweep also removes it once its liveness gates clear."
      else
        echo "      => shipped (PR merged this tip); pointer intentionally not moved, anchor not written."
        echo "         wt-sweep removes worktree + branch once its liveness gates clear. Nothing to do by hand."
      fi
    else
      echo "      => safe to close (running from inside; not removing the ground underfoot)"
    fi
    return 0
  fi
  run "git -C '$repo' worktree remove '$wt'" || return 1
  # Plain -d, never -D. It succeeds only if git independently agrees the branch
  # is merged, so a clean exit here is a second, independent confirmation of the
  # reconcile rather than a force applied on our own say-so.
  if [ "$DRY_RUN" = 1 ]; then
    echo "      would: git -C '$repo' branch -d '$br'"
  elif git -C "$repo" branch -d "$br" >/dev/null 2>&1; then
    echo "      ok: branch -d $br"
  else
    # -d also refuses when the repo's own checked-out default branch lags the
    # remote. That is a stale local ref, not unmerged work, so re-prove it
    # against origin/<def> and say which of the two happened.
    if git -C "$repo" merge-base --is-ancestor "$br" "origin/$def" 2>/dev/null; then
      git -C "$repo" branch -D "$br" >/dev/null 2>&1 &&
        echo "      ok: branch -D $br (merged into origin/$def; local $def is behind)"
    elif pointer_kept "$proof"; then
      # Under proof A/C git can NEVER agree the branch is merged — the squash gave
      # its content a new identity — so -d could only ever refuse here. The force
      # is authorised by GitHub's own record that this tip (A), or a descendant of
      # it (C), is the commit it merged, which is a stronger claim than ancestry to
      # the default branch, not a weaker one. It covers that tip only: a branch that
      # moved after the proof keeps its commits (the worktree is already gone, so
      # the branch is where they survive).
      if [ -z "$tip" ] || [ "$(git -C "$repo" rev-parse -q --verify "refs/heads/$br" 2>/dev/null)" != "$tip" ]; then
        echo "      !! branch $br kept (no longer at the proven tip ${tip:0:12})"
        return 1
      fi
      if git -C "$repo" branch -D "$br" >/dev/null 2>&1; then
        if [ "$proof" = "head" ]; then echo "      ok: branch -D $br (PR merged this exact tip)"
        else echo "      ok: branch -D $br (PR merged a descendant of this tip)"; fi
      fi
    else
      echo "      !! branch $br kept (not an ancestor of origin/$def)"
      return 1
    fi
  fi
  # The anchor lives exactly as long as its branch (lib/wt-anchor.sh).
  local aref; aref=$(wt_anchor_ref "$br")
  if git -C "$repo" rev-parse -q --verify "$aref" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "      would: git -C '$repo' update-ref -d '$aref'"
    elif ! git -C "$repo" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1 &&
         git -C "$repo" update-ref -d "$aref" >/dev/null 2>&1; then
      echo "      ok: dropped anchor $aref with its branch"
    fi
  fi
  return 0
}

# ---- target selection ----
if [ "$ALL" = 1 ]; then
  repo_root="${REPO_ARG:-$PWD}"
  cdir=$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null) || {
    echo "wt-done: not a git repository: $repo_root" >&2; exit 1; }
  case "$cdir" in /*) ;; *) cdir="$repo_root/$cdir" ;; esac
  repo_root=$(dirname "$(realpath -m "$cdir")")
  mapfile -t _paths < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  TARGETS=("${_paths[@]:1}")
  echo "wt-done: $repo_root — ${#TARGETS[@]} linked worktree(s)"
elif [ "${#TARGETS[@]}" = 0 ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "wt-done: not inside a git worktree, and no target given" >&2; exit 1; }
  TARGETS=("$top")
fi

for _wt in ${TARGETS[@]+"${TARGETS[@]}"}; do
  close_one "$_wt" || rc_overall=1
done

[ "$DRY_RUN" = 1 ] && echo "(dry run — re-run with DRY_RUN=0 to apply)"
exit "$rc_overall"
