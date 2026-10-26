---
title: "Verify staged paths before committing -- a multi-pathspec git add aborts entirely on one unmatched path"
date: 2026-09-04
category: best-practices
module: release-commit-staging
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A single git add (or git rm) command lists more than one pathspec in one invocation, including a path that might not exist in the working tree right now -- a rename source, a typo, a path from another branch"
  - "A git mv, git rm --cached, or other staging command already ran earlier in the same sequence, so the index already holds staged content before the multi-path add runs"
  - "Stderr from a staging command is redirected to /dev/null or otherwise suppressed inside a script or one-liner"
  - "A commit is about to run right after a multi-path git add without first checking git diff --cached --name-only"
tags:
  - git-add
  - pathspec
  - silent-failure
  - staged-changes
  - release-commit
---

# Verify staged paths before committing -- a multi-pathspec git add aborts entirely on one unmatched path

## Context

A release commit was prepared by renaming a docs file with `git mv A B`, editing two other tracked files, then staging everything with one `git add` that listed the new path *and* the old, now-nonexistent path -- with stderr redirected to `/dev/null`.

Verified in a scratch repo under `/tmp` (no tracked repo touched): `git add existing1.txt existing2.txt nonexistent.txt` exits `128` with `fatal: pathspec 'nonexistent.txt' did not match any files`, and `existing1.txt`/`existing2.txt` come back **unstaged** -- `git diff --cached --name-only` prints nothing, and `git status --short` shows both with a leading space (` M`: empty staged column, `M` in the working-tree column). A second test put the unmatched path second in a four-path list (`git add new old-renamed-away VERSION other.txt`) and got the identical result: exit `128`, nothing from the list staged. The unmatched pathspec voids the whole command regardless of where in the list it sits.

That alone would produce an obviously-empty commit and get noticed fast. What made this incident silent is the interaction with `git mv`: `git mv` stages its own rename immediately, as an operation separate from `git add`. Reproducing the exact sequence -- `git mv old new`, edit two other tracked files, then a single `git add new old VERSION other.txt` where `old` no longer exists -- confirms the `git add` still exits 128 and stages nothing new, but the rename `git mv` already staged survives untouched (`git diff --cached --name-only` shows only the renamed file). The `git commit` that follows succeeds and contains *only* the rename; the two edited files are left modified-but-unstaged in the working tree, indistinguishable at a glance from "already committed."

The resulting commit's message described a version bump that was not in it. A required CI check caught it precisely -- it compared VERSION against the existence of its matching release-notes file, and the renamed-away file made them disagree -- but the round trip cost a full 30-minute CI cycle on a release PR, purely because stderr from the failed `git add` was discarded and nobody checked the index before committing.

## Guidance

1. **Confirm what's actually staged, every time, right before `git commit`.** Run `git diff --cached --name-only` (or `git status --short`, reading the staged column specifically) after any multi-path staging command and before the commit that follows it. This one check would have caught the incident at zero cost, before the commit ever existed.
2. **Never discard stderr on a staging command.** `git add ... 2>/dev/null` turns a loud `fatal: pathspec '...' did not match any files` into total silence. The working tree is unaffected by the failure, so there is no other visible symptom -- nothing appears anywhere the operator or agent is looking.
3. **Know the `git mv` interaction specifically.** `git mv` stages its rename immediately and independently of any later `git add`. A failed multi-path `git add` after a `git mv` does not produce an empty, obviously-wrong commit -- it produces a *partial* commit that already contains the rename and looks intentional, which is what let the wrong commit message ship.
4. **Don't list a maybe-gone path defensively.** If a path might already be renamed, deleted, or removed by an earlier command in the same sequence, listing it "just in case" is exactly the pattern that aborts the whole command. Stage the rename's destination and the edited files as separate `git add` calls, or check each path first (`git status --porcelain=v1 -- <path>`).

## Applicability

This applies to any command or script that stages more than one explicit pathspec in a single `git add` (or `git rm`) invocation -- release-automation scripts, agent-authored commits, CI steps that assemble a commit from a list of changed files. The all-or-nothing abort is not specific to renames; any stale, typo'd, or already-removed path in the list triggers it. The `git mv` interaction is the sharpest version of the trap because it's the one case where the failure produces a plausible commit instead of an obviously empty one.
