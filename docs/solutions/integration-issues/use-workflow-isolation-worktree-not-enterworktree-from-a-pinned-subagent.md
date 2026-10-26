---
title: "Use Workflow isolation: 'worktree', not EnterWorktree, from a pinned subagent"
date: "2026-09-04"
category: integration-issues
module: claude-harness-worktree-isolation
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A pinned subagent's `cd <sibling-worktree> && git status` is refused by the background worktree-isolation guard, even though the sibling worktree is a legitimate git worktree the subagent needs to act on"
  - "EnterWorktree(path=<sibling-worktree>) reports success and moves the SDK cwd, but the guard never honors the switch -- every subsequent Bash call is refused, including a plain `cd` back to the original pin"
  - "ExitWorktree is also refused, with 'cannot be called from a subagent with a cwd override', leaving no in-session command that restores a working shell"
  - "The only recovery is calling EnterWorktree a second time with the subagent's *original* pinned path, at which point the subagent has run zero commands against the target worktree"
  - "The guard's pin smears from a session onto its subagents (dotfiles#436, reproduced 5x), so a subagent inherits a worktree restriction it never chose and cannot lift from inside the session"
root_cause: wrong_api
resolution_type: workflow_improvement
severity: high
framework_version: "claude-code (2026-09-04 build)"
related_components:
  - EnterWorktree
  - ExitWorktree
  - Workflow
  - worktree-isolation-guard
  - cc-worktree-guard-smears-concurrent-subagents
tags:
  - worktree
  - enterworktree
  - workflow-isolation
  - subagent
  - pinned-cwd
  - silent-failure
  - claude-code-guard
  - dotfiles-436
---

# Use Workflow isolation: 'worktree', not EnterWorktree, from a pinned subagent
## Problem

Claude Code's background worktree-isolation guard pins a session's Bash/Edit/Write to
one worktree. That guard smears the MAIN session's pin onto its subagents — a defect
tracked as dotfiles#436 and reproduced five times as of 2026-09-04. On 2026-09-04, a
pinned session (the `compound-session-learnings` worktree) created a sibling worktree
`ideation-988-correction` via `wt-new.sh` and dispatched a general-purpose subagent to
commit a one-file doc fix from that sibling. The subagent had no route from a plain Bash
call, `EnterWorktree`, or `ExitWorktree` to a live shell in the sibling — every path either
inherited the wrong pin or landed the session in a dead state that accepted no further
tool calls in either direction.

## Symptoms

Observed by the subagent, in order:

1. `cd <sibling> && git status --short` — refused, citing the *main session's* worktree,
   not the sibling:

   > This session is isolated in the worktree `<main>`, but this command['s working
   > directory resolved to the shared checkout / is too complex to verify]…

   (verbatim family per dotfiles#436's opening report and `harness/worktree-command-shapes.md`'s
   "too-complex" and "working directory escaped" messages).

2. `EnterWorktree(path=<sibling>)` — **reported success**: "working directory and write
   access now point at the worktree."

3. Every Bash call after that — `pwd`, `git -C <sibling> status`, `cat` of an unrelated
   file, even `cd <main> && pwd` to force it back — refused, now citing the *new* cwd
   (the sibling) as the violation. The SDK-level cwd had moved; the guard never honored
   it. The session was dead in both directions.

4. `ExitWorktree(action="keep")` — refused: "cannot be called from a subagent with a cwd
   override… this agent is already isolated."

5. `EnterWorktree(path=<original pin>)` — recovered a working Bash session.

Net effect: zero commands ran against the sibling worktree. The subagent reported this
honestly, which is the only reason nothing was corrupted — it never got far enough to
write, stage, or commit anything in the wrong place.

## What Didn't Work

- **Plain Bash with `cd`/`-C` into the sibling** — refused at step 1 with the main
  session's pin, not the sibling's. Consistent with dotfiles#436's original report: "the
  guard attributes the parent/sibling session's isolation state to the subagent."
- **`EnterWorktree(path=<sibling>)`** — reported success (step 2) but produced the dead
  state in step 3: the tool's own success message was not evidence of a usable session.
- **`ExitWorktree(action="keep")`** — refused outright once the subagent was in the dead
  state (step 4); it is not a valid escape from a cwd-override subagent.
- **`git -C <sibling>` from the main session itself** — also refused; the guard treats
  `-C` to another worktree as a redirect regardless of which session issues it (matches
  the "redirects git to the shared checkout via `-C`" denial documented in
  `harness/worktree-command-shapes.md` under the "Git redirected out of the worktree" label).

## Solution

Recover first, then route around the defect entirely rather than fighting it:

1. From the dead subagent, `EnterWorktree(path=<original pin>)` to restore a working
   Bash session (step 5 above) — this is the only exit from the dead state.
2. Launch a **new** agent via the `Workflow` tool with `isolation: 'worktree'`. That
   creates the agent's own fresh worktree and pin from birth, so it is never subject to
   the smear — it is not the sibling, and it does not need to become the sibling.
3. From that freshly-pinned agent: `git fetch origin <branch> && git checkout -B
   <branch> origin/<branch>` to land on the PR's branch directly (no need to ever touch
   the sibling worktree's files).
4. Re-apply the correction with a deterministic Python edit script that asserts exactly
   one match per replacement and refuses otherwise — this makes the result provably
   identical to what sat, uncommitted, in the sibling's working copy, without requiring
   filesystem access to that copy.
5. Validate, `git commit -F <message file>`, and `git push` (a normal, non-force push).
   The PR (dotfiles#996, "docs(ideation): correct idea 3 — keep the connector's contents
   write, drop only workflows/actions write", merged 2026-09-04T23:26:15Z, closing #995)
   merged from this route.
6. Leave the sibling worktree `ideation-988-correction` with its dirty, uncommitted copy
   for `wt-sweep` to dispose of on its normal cadence — the merged commit on `main` is
   authoritative, and no correctness depends on ever reconciling the sibling's working
   tree.

## Why This Works

The guard keys off the pin a session is launched with, not off any mid-life mutation.
`isolation: 'worktree'` on the `Workflow` tool sets that pin correctly at launch time for
a brand-new agent. `EnterWorktree` called mid-life on an already-pinned subagent instead
mutates the SDK-visible cwd without updating whatever internal state the guard actually
reads — the two go out of sync, and every subsequent call fails the check regardless of
direction. Routing around the sibling worktree by checking out its branch from a
freshly-pinned agent sidesteps the disagreement entirely: there is no cwd mutation to
desync, because the pin and the cwd were consistent from the first tool call.

This is a defect in the Claude Code CLI's own background-isolation guard, not a dotfiles
hook: `grep -rn "isolated in the worktree" hooks/PreToolUse/` returns no matches
(directory contents: `canonical-worktree-route-guard.js`, `codex-quota-guard.js`,
`git-guard.js`, `grep-cost-guard.js`, `heavy-job-admission.js`, `loop-guard.js`,
`read-ceiling-chunk.js`, `runner-guard.js`, `settings-guard.js`,
`structured-output-unwrap.js`, `whatsapp-guard.js`; none emits the string). The only repo
hits for that string are documentation in `harness/worktree-command-shapes.md`
(lines 31, 38, 45, 53), quoting the verifier's own denial messages for reference — not a
hook that produces them. `harness/worktree-command-shapes.md` itself documents a
related but distinct failure mode: static command-shape verification *within* an already
successfully isolated session (denied for using `$( )`, `-C` to the shared checkout,
package-manager operands, etc.). That doc's scope stops at "the isolation succeeded, now
which command shapes pass" — it does not cover the case documented here, where
`EnterWorktree` itself leaves the session in a state that accepts no commands in any
shape.

## Prevention

- Never call `EnterWorktree` from a subagent that is already pinned (background job,
  Workflow subagent, or any cwd-override agent). Treat its "success" message as
  unverified until a subsequent command actually runs.
- If a sibling worktree must be written from a pinned session's fan-out, launch the
  writer with `isolation: 'worktree'` from the start and have it check out the target
  branch — never attempt to redirect an existing pinned agent onto the sibling.
- Carry edits as a deterministic, assertion-checked script (exact match count per
  replacement) rather than assuming the sibling's working tree will ever be reachable
  from the agent that has to commit the change.
- A subagent that finds itself in the dead state (every command refused, citing a cwd
  that does not match the original pin) should immediately
  `EnterWorktree(path=<original pin>)` to recover, then report the failure rather than
  retrying forward — retrying in the dead state burns turns for zero effect, as steps 1–4
  above show.
- Per `CLAUDE.md`'s worktree-isolated-sessions rule (line 13): "commands are
  shape-checked before running; nothing from inside the session relaxes it" — this
  extends to `EnterWorktree`/`ExitWorktree` state transitions, which are equally
  unrelaxable once a session is wedged.

Recorded: dotfiles#436 (5th reproduction comment, 2026-09-04, "the dead-state shape after
a pinned subagent calls `EnterWorktree`"), papercut
`self:enterworktree-from-a-pinned-subagent-reports-success-but-the`, and memory note
`cc-worktree-guard-smears-concurrent-subagents` (addendum 2026-09-04).

## Related Issues

- **dotfiles#436** — "CC worktree-isolation guard smears one session's worktree pin onto
  concurrent subagents" (open, 5 reproductions 2026-08-16 through 2026-09-04; the issue's
  own title still says "4x" — the fifth lives in its 2026-09-04 comment). This solution
  documents the 5th reproduction's new detail: the dead-state shape after
  `EnterWorktree` from an already-pinned subagent.
- **dotfiles#996** — "docs(ideation): correct idea 3 — keep the connector's contents
  write, drop only workflows/actions write" (merged 2026-09-04T23:26:15Z, closes #995).
  The PR that landed via the `Workflow isolation: 'worktree'` route described above,
  after the sibling-worktree approach failed.
- Memory note **`cc-worktree-guard-smears-concurrent-subagents`** — standing record of
  the guard's cross-session pin-smearing behavior; this incident is its 2026-09-04
  addendum.
- `docs/solutions/integration-issues/drive-post-merge-activation-instead-of-handing-back.md`
  and
  `docs/solutions/integration-issues/open-html-deliverables-with-a-real-launcher-not-open-xdg-open.md`
  share this incident's shape — a platform primitive reports success or a clean exit code
  while the underlying state it claims to have changed has not actually changed
  (`wt-done.sh` reporting shipped code that isn't live; `open`/`xdg-open` exiting 0 while
  nothing opens). `EnterWorktree` reporting "working directory and write access now point
  at the worktree" while the guard leaves every subsequent call refused is the same
  failure family: don't trust a platform primitive's own success report as proof of the
  state it claims — verify with an independent, cheap follow-up call before relying on it.
