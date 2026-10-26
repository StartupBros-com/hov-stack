---
title: "Attribute a push to the actor that made it by the tracking ref's reflog, not by HEAD ancestry"
date: 2026-10-05
category: logic-errors
module: pro-gate-loop-fixer-push-attribution
problem_type: logic_error
component: development_workflow
symptoms:
  - "Pro round 1 on #1551 (P1): any move of the PR head while a context-fenced fixer ran counted as the fixer's push, including another actor's concurrent push"
  - "Pro round 2 on #1551 (P1): a fenced fixer that committed nothing and only `git pull`ed another actor's push still counted as having pushed, so the loop charged a second review and went on toward the merge handoff"
  - "`git reflog show --format=x` dies with `fatal: invalid --pretty format: x`; behind `2>/dev/null` every reflog count read 0 and two checks failed with no visible cause"
root_cause: logic_error
resolution_type: code_fix
severity: medium
related_components:
  - pro-gate-loop.sh
  - pro-gate-loop.test.sh
  - pr-owner.sh
tags: [git-reflog, push-attribution, remote-tracking-ref, provenance, pro-gate-loop, fixer-fence, concurrent-push, git-pull]
---

# Attribute a push to the actor that made it by the tracking ref's reflog, not by HEAD ancestry

Status note (2026-10-18, revised the same day): the lesson still holds for any driver that has to say which actor moved a PR head, but the mechanism it describes is gone. `push_marks`, `fixer_pushes` and `fixer_pushed`, their `fix()` call sites in `scripts/pro-gate-loop.sh`, and the fixture, stub push and G12j case in `tests/pro-gate-loop.test.sh` were removed by dotfiles #1913 (1bb7f311, teardown move 5), which retired the context fence and the fenced fixer stops that needed push attribution. The 01:55 revision of this note (#1905) cited their positions; #1913 merged at 07:06 and those citations no longer resolve. Every `file:line` citation below dates from the 2026-10-05 tree, so read it as history. #1873 also deleted `pr-owner.sh` (listed in `related_components`) and `pr-handoff.sh`, the owner and merge handoff this write-up mentions.

## Problem

`fix()` in `scripts/pro-gate-loop.sh` runs a fixer session. When the context fence stops that session, `fix()` has to decide whether the fixer itself pushed to the PR branch. A fenced fixer that pushed has completed its round. One that did not is a `fixer-fence` stop. Two inferences from the PR head and the local HEAD each gave the wrong answer when another actor pushed while the fixer ran. Each one cost a Pro round on #1551 before the fix read git's own record of the push (issue #1545, closed by PR #1551).

## Symptoms

- Another actor's push during the fixer's run made a fenced round read as completed.
- A fixer that only pulled that push, and committed nothing, also read as completed. The loop then charged a second review and went on toward the merge handoff. Test G12j shows exactly that against the round-2 code.
- While the fix was being built, an invalid reflog format silently returned 0 entries.

## What Didn't Work

- **"The PR head moved."** Another actor's concurrent push moves it too. Pro round 1 flagged this as a P1.
- **"The fixer's final local HEAD holds a commit the old head did not, and the moved head or the tracking ref holds it."** That was the round-1 fix, and it describes a pull just as well as a push. A fixer that runs `git pull` ends with the other actor's commit in its HEAD, and that commit is in the moved head. Pro round 2 flagged it as a P1. The fixer of round 2 produced no diff, and the session that authored #1551 fixed it.
- **`git reflog show --format=x`** (meant as "one line per entry, content irrelevant"). git reads `x` as the name of a pretty format and exits 128 with `fatal: invalid --pretty format: x`. With `2>/dev/null` on that read, `wc -l` counted 0 for every ref. The suite then failed G12e and G12i with no message pointing at the cause. `--format=%H` works, and the reads no longer silence stderr.

## Solution

Read the push from the log git writes for the remote-tracking ref, and keep only entries that git itself names as a push (`scripts/pro-gate-loop.sh:601-645`):

```bash
# before the fixer: each refs/remotes/*/<branch> and its reflog length
push_marks() {
  local ref
  git for-each-ref --format='%(refname)' "refs/remotes/*/$1" 2>/dev/null | while IFS= read -r ref; do
    printf '%s %s\n' "$ref" "$(git reflog show --format=%H "$ref" -- | wc -l)"
  done
}
# after the fixer: only the new entries whose message is exactly "update by push"
fixer_pushes() {
  ...
    git reflog show --format='%gs%x09%H' "$ref" -- \
      | sed -n "1,$((n - ${was:-0}))p" | awk -F '\t' '$1 == "update by push" { print $2 }'
  ...
}
```

`fix()` writes the marks before the fixer runs (`:1578`) and the pushes after it (`:1637`). `fixer_pushed` then accepts a pushed commit only when all three of these hold (`:633-645`):

- the fixer's HEAD holds it;
- the old PR head did not;
- the moved head or the tracking ref holds it.

## Why This Works

git names each remote-tracking reflog entry after the command that wrote it. On git 2.43.0, a scratch repository shows:

| Command | Reflog entry on `refs/remotes/origin/main` |
|---|---|
| `git push` | `update by push` |
| `git fetch -q origin` | `fetch -q origin: storing head` |
| `git pull -q --ff-only origin main` | `pull -q --ff-only origin main: fast-forward` |

So a push this clone made since the snapshot is exactly a new `update by push` entry, and pulling or fetching someone else's push can never produce one. Reading only the entries added after the snapshot keeps earlier pushes out of the count.

## Prevention

- **Take provenance from the tool's own log.** When the question is who did something, use the record the tool writes when that actor does it. Inferring it from end state cannot tell "made it" from "received it".
- **Test against real operations.** The fixture now has a bare remote (`tests/pro-gate-loop.test.sh:925-928`). The stub fixer really runs `git push` (`:870`), and G12j really runs `git pull`, so the reflog entries the loop reads are git's own.
- **Plant the negative and assert its precondition.** G12j (`:1336`) first checks that the fixture really pulled: HEAD is the pulled commit, and the tracking ref's newest entry starts with `pull `. Only then does it assert exit 4. Against the round-2 loop, G12j fails four checks (the planted-negative run in #1551's description), which is how the fix was shown to be needed.
- **Never silence stderr on a read whose result is evidence.** The `--format=x` failure surfaced only because the counts were wrong. If a failed read can look like an empty answer, let it fail loudly.
- **Known limits:**
  - A push to a URL instead of a named remote moves no tracking ref. That round reads as fenced.
  - Worktrees of one clone share the remote-tracking reflogs. A push from another worktree of the same clone to the same branch would count, which the one-task-per-worktree rule makes unlikely.
  - The method needs reflogs, which git keeps by default for remote-tracking refs in a non-bare clone (`core.logAllRefUpdates`).

## Related Issues

- [Agent View refuses to close squash-merged worktrees](../integration-issues/agent-view-refuses-to-close-squash-merged-worktrees.md): another case where "a remote ref holds it" is only a proxy for "this actor pushed it".
- Issue #1545, closed by PR #1551. Issue #1558 was a separate `fixer-no-change` misread in the same decision; it was closed as moot on 2026-10-17 when #1873 removed the owner fleet it was filed against, with a note to reopen if the behavior shows up in session-mode `pro-gate-loop.sh`.
