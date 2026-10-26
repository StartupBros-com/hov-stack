---
title: "Agent View refuses to close squash-merged worktrees"
date: 2026-09-23
category: integration-issues
module: worktree-closeout
problem_type: integration_issue
component: development_workflow
symptoms:
  - "Agent View refuses to close a worktree whose PR merged, saying it has commits that are not pushed anywhere, and force does not bypass it"
  - "git rev-list --count HEAD --not --remotes is non-zero in the worktree, and its upstream shows [gone] after a pruning fetch"
  - "wt-done refuses a shipped worktree because the merge commit is not an ancestor of origin/main, in a clone that has silently gone shallow"
  - "A GitHub 404 body from gh api is read as a PR line"
root_cause: logic_error
resolution_type: code_fix
severity: high
framework_version: "claude-code 2.1.280"
related_components:
  - wt-done
  - wt-sweep
  - claude-code-agent-view
  - gh-cli
tags:
  - wt-done
  - worktree-closeout
  - agent-view
  - squash-merge
  - shallow-clone
  - gh-api
  - git-remote-refs
  - false-refusal
---

# Agent View refuses to close squash-merged worktrees

## Problem

After a PR was squash-merged, Claude Code's Agent View refused to close the worktree that produced it ("has commits that are not pushed anywhere"), so shipped worktrees piled up: 304 were refused on this host on 2026-09-23 (session history). The fix had to prove each tip shipped and make it count as pushed without moving a branch or touching a file. On the way, two false refusals in the proof code had to be removed, one of which was first misdiagnosed.

## Symptoms

- Agent View and `claude rm` refuse a worktree whose PR `gh pr view` reports as MERGED, with "has commits that are not pushed anywhere". `force` does not get past it (auto memory [claude]).
- `git rev-list --count HEAD --not --remotes` in that worktree is non-zero, and after a pruning fetch the branch's upstream shows `[gone]`.
- While fixing it, `wt-done.sh` refused two shipped worktrees with `REFUSE (PR #1188 merge commit ... is not an ancestor of origin/main)`, and the same for PR #886.
- An earlier PR lookup read a GitHub 404 body as a PR line: "a 404 once arrived as PR #{"message":"Not ..." (`scripts/wt-done.sh:204-205`).

## What Didn't Work

- **Content heuristics.** `rev-list --cherry-pick` against main and tree equality against main were both measured failing on the same branch on 2026-08-28 (`scripts/wt-done.sh:4-32`). A squash collapses N commits into one patch-id, so `--cherry-pick` never matches a multi-commit branch, and main moves on after the merge, so tree equality against main stops holding.
- **Tree equality with the merge commit alone (proof B).** A squash commit is the base branch at merge time plus the branch's changes, so any unrelated PR landing in between makes the trees differ. B alone reconciled 43 of 69 stuck worktrees (`scripts/wt-done.sh:422-425`).
- **Moving the pointer when only proof A or C holds.** The trees differ, so `reset --soft` leaves the old files in place, `status` reads dirty, and the post-reset check rolls it back; `reset --hard` would rewrite the operator's files (`scripts/wt-done.sh:454-460`).
- **A blanket `+refs/pull/*/head` fetch refspec.** It would make every PR head reachable from a remote ref, including closed-unmerged ones, and Claude Code's automatic `cleanupStaleAgentWorktrees` gates on the same predicate, so unshipped work would become reapable (`scripts/wt-done.sh:53-56`).
- **`ExitWorktree`.** It only covers worktrees the session itself created (`scripts/wt-done.sh:74`), not ones made by `wt-new.sh`.
- **Explaining a refusal without checking its premise.** After #1364 shipped, `pr-1188` (PR #1188) and a second worktree (PR #886) still refused as "not an ancestor of origin/main". They were explained as stacked children (PRs merged into a parent branch, whose merge commit is not on main), and that explanation went into #1364's code comment and test 28's commentary. It fitted the base filter being written at that moment, but both PRs had `base=main`. The real cause was that the canonical checkout had silently become a shallow clone: `git rev-parse --is-shallow-repository` returned `true`, `.git/shallow` had been written on 2026-09-22 at 04:08 with its boundary at #1224, and `origin/main` walked back only 92 commits locally. GitHub's compare API had main ahead of both merge commits with `behind_by 0`. What made the depth-limited fetch is still unidentified (session history). #1369 removed the wrong comment and the test commentary.

## Solution

Three changes, one per PR, each with planted negatives in `tests/wt-done.test.sh`.

**1. Anchor a proven tip under `refs/remotes/` (#1361).** The gate is `git rev-list HEAD --not --remotes` (`scripts/wt-done.sh:47-49`; Claude Code 2.1.280, function `Rbn`), so any ref under `refs/remotes/` holding the tip satisfies it. After proof A, the tip equals GitHub's `headRefOid` (`scripts/wt-done.sh:438`), or proof C, the tip is an ancestor of that head (`scripts/wt-done.sh:440-443`). wt-done then reads GitHub's permanent `refs/pull/<N>/head` and writes the anchor only if it names the same commit:

```bash
srv=$(git -C "$repo" ls-remote --exit-code origin "refs/pull/$pr/head" 2>/dev/null); rc=$?
# ... rc 2: not GitHub; other nonzero: offline; either way no anchor
srv="${srv%%[[:space:]]*}"
if [ "$srv" != "$oid" ]; then
  echo "      !! refs/pull/$pr/head is ${srv:-missing}, but PR #$pr records $oid as merged; no anchor written"
  return 1
fi
if ! git -C "$repo" update-ref "$ref" "$oid" >/dev/null 2>&1; then
```

(`scripts/wt-done.sh:278-291`). The ref is `refs/remotes/pr-merged/<branch>` (`scripts/lib/wt-anchor.sh:20-22`), outside `refs/remotes/origin/` because `fetch --prune` deletes anything there whose source branch is gone (`scripts/wt-done.sh:51-52`). Both wt-done and wt-sweep exclude anchors from their unshipped count, so an anchored branch still needs wt-done's proof before it is deleted (`scripts/lib/wt-anchor.sh:24-31`). The anchor-inclusive count is exactly what the gate sees (`scripts/lib/wt-anchor.sh:35-37`).

**2. Read `gh` output only on exit 0 and only in the expected shape (#1364).** On an HTTP error `gh api` prints the error body to stdout, exits 1, and skips `--jq` (`scripts/wt-done.sh:202-207`). So a PR line counts only if `gh` exited 0 and the line matches what the filter produces:

```bash
prline_ok() {
  local oid='([0-9a-f]{40}|[0-9a-f]{64})'
  local re="^[0-9]+ $oid( $oid| )?\$"
  [[ $1 =~ $re ]]
}
# out=$(cd "$repo" && gh "${args[@]}" 2>/dev/null) && prline_ok "$out" || out=""
```

(`scripts/wt-done.sh:208-212`, used at `:189` and `:197`). Both lookups, by branch name and by GitHub's commit-to-PR endpoint, keep only PRs merged into the default branch (`scripts/wt-done.sh:185`, `:195`), so a stacked child falls through to its parent.

**3. In a shallow clone, ask GitHub instead of refusing (#1369).** A failed local walk still refuses as before in a full clone (`scripts/wt-done.sh:400-403`). In a shallow one, `on_default_remote` asks GitHub's compare API and accepts only an exact `ahead 0` or `identical 0` produced by `--jq` with exit 0:

```bash
out=$(cd "$repo" && gh api "repos/${slug:-"{owner}/{repo}"}/compare/$mc...$def?per_page=1" \
  --jq '"\(.status) \(.behind_by)"' 2>/dev/null); rc=$?
# rc != 0 -> "compare call failed: gh exit N, <message>"
case "$out" in "ahead 0"|"identical 0") return 0 ;; esac
```

(`scripts/wt-done.sh:224-242`). A default-branch name that a URL path cannot carry literally (`#` starts a fragment) is refused before any call (`scripts/wt-done.sh:228-230`). Proof B is not offered in a shallow clone that cannot reach the merge commit (`scripts/wt-done.sh:439`, `:444-447`), because its pointer move is verified by local walks (the post-reset count, `branch -d`, Agent View's own gate) that stop at the same boundary. The clone itself was repaired with `git fetch --unshallow origin`, and `origin/main` went from 92 to 983 local commits (session history).

**Outcome on 2026-09-23** (session history): 266 anchors written with zero pointer moves, and 262 of the 304 refused worktrees now pass the gate. The two numbers come from separate passes, the anchor backfill and the gate census, and were not reconciled one-to-one. The other 42 are refused correctly: 28 never had a PR, 6 are dirty, 5 have commits after the merge, 1 PR is open, 1 closed unmerged, and 1 repo's GitHub remote returns 404.

## Why This Works

The gate asks one question: is every commit on HEAD reachable from some ref under `refs/remotes/`? It never fetches (auto memory [claude]). A squash merge puts the shipped content on main as a new commit. `delete_branch_on_merge` then deletes `origin/<branch>`, and `fetch.prune` deletes the local tracking ref. After that nothing under `refs/remotes/` reaches the tip, though its content is on main. GitHub keeps `refs/pull/<N>/head` permanently, but nothing fetches it by default. The anchor puts that same commit under `refs/remotes/`, and only after GitHub's two records agree: the API's merged head and the server ref. So "reachable from a remote ref" still means "shipped" to every tool that trusts it, including cleanup the harness does not control. Proof A holds by construction: if the tip is the head GitHub merged, the squash captured every commit on the branch, however far main has moved.

The two false-refusal fixes share one rule: an answer that could not be obtained is never read as a yes.
- **The PR-lookup fix only refuses safely.** A `gh` error is no longer read as a PR. It still prints the same "no MERGED PR" line as a genuine no (`scripts/wt-done.sh:385`), so that line alone does not tell you which one happened.
- **The shallow-clone check goes further.** It separates "no" from "could not tell" and prints what it saw: GitHub's literal status, or `compare call failed: gh exit 1, Not Found` (`scripts/wt-done.sh:236`). It never offers an explanation inferred from the symptom.

## Prevention

- **Check the premise before explaining a failed ancestry check.** Run `git rev-parse --is-shallow-repository` first.
  - One `git fetch --depth=N` run in any worktree writes the shared `.git/shallow` and makes the whole repo shallow.
  - Every object stays: `cat-file -e` still resolves the old commit, while `merge-base --is-ancestor` flips from yes to no. This was reproduced with a probe this session (auto memory [claude]).
  - `git fetch --unshallow origin` repairs it cheaply when the objects are already present.
- **Treat `gh api` stdout as data only when `gh` exited 0 and the output has the shape your `--jq` emits.** Never trust stdout after `|| true` or `2>/dev/null`. Guarded by test 29, an error body is not a PR line (`tests/wt-done.test.sh:702`); test 31, a partial OID is not a PR line (`:728`); and test 34, a failing compare call refuses and names the failure (`:798`).
- **Refuse, rather than guess, when an input cannot be carried to the source of truth.** Test 36 covers a `main#release` default branch (`tests/wt-done.test.sh:830`).
- **Publish a remote-tracking ref only after an independent proof.** Tools you do not control read such a ref as "shipped", so never publish one through a blanket refspec. The guarding tests:
  - test 19: the anchor passes the gate and touches nothing (`tests/wt-done.test.sh:467`)
  - test 22: GitHub's two records disagree, so no anchor is written (`:575`)
  - test 25: the anchor library is missing, so wt-done refuses (`:620`)
  - test 26: a commit lands while GitHub answers (`:638`)
  - wt-sweep-reconcile tests 7 and 8: an anchored tip is still re-proven before its branch is dropped, and orphan anchors are pruned (`tests/wt-sweep-reconcile.test.sh:210`, `:243`)
- **Mind the `--exclude` trap.** Before `--remotes`, `git rev-list --exclude` takes a pattern relative to `refs/remotes/`; the full-ref form silently excludes nothing (`scripts/lib/wt-anchor.sh:26-28`).
- **Keep stacked children and shallow clones as separate tested cases.**
  - Test 28 covers a stacked child found by name falling through to its parent (`tests/wt-done.test.sh:680`).
  - Tests 32 to 35 cover the shallow cases (`:752-829`): GitHub confirms, GitHub does not confirm, the call fails, and only proof B would hold. Their fixture is made shallow by a real `fetch --depth=1`.
- **Treat an explanation that matches the fix you are writing as a reason to check again.** The stacked-child story was wrong in exactly that way. A check that warns on a shallow canonical checkout was proposed in a papercut and has not been built (session history).

## Related Issues

- dotfiles #1360 (issue) and PR #1361 (anchors), PR #1364 (`gh` error bodies, base filter), PR #1369 (shallow clones, and the correction of #1364's comment).
- Earlier steps in the same closeout: #589 (merge-anchored closeout, proof B), #596 (proof A), #843 (`WT_DONE_PROOF=head` disposal through wt-sweep).
- Upstream: anthropics/claude-code#78355, recorded as open with no maintainer workaround (`scripts/wt-done.sh:14-17`).
- The mechanism in full: `HARNESS.md:19` ("Merge-anchored closeout"). What happens after closeout: [Drive and verify post-merge activation instead of handing the operator a command](drive-post-merge-activation-instead-of-handing-back.md).
- Same surface, different failure: [The Agents View `@` picker only durably lists repos one level below its launch directory](agents-view-at-picker-only-durably-lists-repos-one-level-below-launch-directory.md), also diagnosed by reading the tool's exact internal rule rather than guessing from the symptom.
