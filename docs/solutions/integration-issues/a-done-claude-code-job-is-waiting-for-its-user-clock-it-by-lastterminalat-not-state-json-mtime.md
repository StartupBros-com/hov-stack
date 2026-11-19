---
title: A done Claude Code background job is waiting for its user, so clock it by lastTerminalAt, not state.json's mtime
date: 2026-11-19
category: integration-issues
module: claude-code-background-jobs
problem_type: integration_issue
component: development_workflow
symptoms:
  - "Resuming a background job prints \"Your worktree … no longer exists … The worktree binding has been cleared\" and carries on in the launch checkout"
  - A sweep or reaper removes what a finished job left behind, and the job is resumed within a day
  - A job's state.json mtime or updatedAt is hours or weeks newer than its last turn
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [claude-code, background-jobs, job-state, done-state, last-terminal-at, wt-sweep, reclaim-sweep, resumable-hold]
---

# A done Claude Code background job is waiting for its user, so clock it by lastTerminalAt, not state.json's mtime

## Problem

Code that reads Claude Code's job store (`~/.claude/jobs/<id>/state.json`) took `"state": "done"` to mean the job was over. It only means the job's latest turn has ended. The job is at rest, waiting for its user, who can resume it into the same worktree and scratch directory.

wt-sweep acted on the wrong reading. On one host it removed 27 worktrees in 3.5 days. Of the 13 jobs whose timeline survived, every one was resumed within 24 hours of its last turn (hov-stack#793).

## Symptoms

- Resuming a job prints "Your worktree … no longer exists, so this session is working in the current directory without worktree isolation. The worktree binding has been cleared." Several overnight jobs showed it each morning.
- 25 of the 27 removals came about a second after wt-sweep printed `resumable:` for the same job. That warning was the only effect a done job had on the sweep.
- A job's state.json is rewritten while it does nothing, so its mtime and `updatedAt` read as recent activity long after the last turn.

## What Didn't Work

- **Process or lock liveness.** By the time a sweep runs, a done job's process has exited and its `git worktree lock` is gone, so neither check sees it. Why the lock is gone by then was not established, and the fix does not rely on it.
- **The state.json mtime or `updatedAt` as the job's last activity.** On 2026-11-19 this host had 47 settled jobs (done, failed or stopped):
  - state.json's mtime ran more than 6 hours past `lastTerminalAt` for 16 of them, more than 3 days past for 8, and at most 699 hours past;
  - timeline.jsonl's mtime was within a minute of `lastTerminalAt` for all 47.
  A mutant of the hold that took its clock from the mtime turned 10 cases red in `tests/wt-session-hold-resumable.test.sh`.
- **Recognising the caller's own job by `sessionId` alone.** wt-done must not refuse to close the worktree of the job that runs it. A caller can carry the job's `resumeSessionId`, or its transcript's id when that differs from `sessionId`. The adversarial review of PR #796 found the first gap and its Pro review the second. In each case the job's own closeout was refused.
- **Learning it in one consumer.** reclaim-sweep's comment has said "done" is per-turn since a job went done at 04:30Z and was resumed at 05:46Z on 2026-10-25 (`scripts/reclaim-sweep.py:358`). The fact lived only in that script. The session hold in `scripts/lib/wt_session_hold.py` let a done job do no more than print a `resumable:` warning until #796.

## Solution

PR #796 changed `scripts/lib/wt_session_hold.py` so a done job holds the worktree it is bound to for `WT_RESUMABLE_HOURS` (default 24) after its last turn. "Resumable hold" in `harness/worktree-fleet-hygiene.md` describes the hold and what binds a job to a worktree. Two parts carry beyond the sweep:

- **Clock.** `last_turn_age` (`scripts/lib/wt_session_hold.py:358`) reads `lastTerminalAt`. It falls back to the state.json mtime only when that field is absent or unusable, which errs toward holding. A time more than an hour ahead of now is not believed (`FUTURE_SKEW`, `:157`). An unparseable or overflowing value never fails the whole check.
- **Identity.** The caller is excluded by any of the job's ids:

```python
if state == "done":
    # Resuming a done job re-enters the worktree it is bound to (hov-stack#793).
    # The caller may carry any of its ids (its transcript's name can differ
    # from its sessionId), so any one excludes it.
    if exclude and exclude in (d.get("resumeSessionId"), transcript_owner(link) if link else None):
        continue
```

(`scripts/lib/wt_session_hold.py:704-709`; the `sessionId` match comes earlier, at `:675`.)

## Why This Works

A background job cycles through working, done, and working again when its user resumes it. `done` marks the end of a turn, not of the job. `lastTerminalAt` is the one field that moves only when a turn ends: on all 47 jobs measured it matched the job's last timeline entry within a minute. Every other clock on the file moves without the job doing anything.

A hold keyed to the last turn, scoped to the worktree the job will re-enter and bounded by a window, protects the resumes that happen without pinning a job's worktrees for good.

## Prevention

- **One owner for the job store (recommended, not done here).** Two hov-stack scripts interpret `done` today: `scripts/reclaim-sweep.py` and `scripts/lib/wt_session_hold.py`. Each has its own reading of state, clock and identity. A shared reader would answer three questions for both: is the job resting or finished, when did its last turn end, and which ids are its own.
  - reclaim-sweep's quiet clock still takes the newest of state.json's mtime, timeline.jsonl's mtime and `lastTerminalAt` (`scripts/reclaim-sweep.py:1462`). A rewritten state.json therefore restarts the clock, which can delay reclaiming a done job's scratch by as much as the skew above (up to 699 hours here). This was inferred from the code, not observed in a reclaim run.
  - That errs toward keeping: the 16 skewed jobs held 0.02 GiB, so no issue was filed.
  - The session hold's own lapse rule for a dead, unfinished job (#403) also reads state.json's mtime (`scripts/lib/wt_session_hold.py:689`). That errs toward holding in the same way.
- **Any new reader of `~/.claude/jobs`:**
  - Treat `done` as resumable.
  - Clock the last turn by `lastTerminalAt`, with timeline.jsonl's mtime as a cross-check, never state.json's mtime or `updatedAt`.
  - Match "is this my own job" against `sessionId`, `resumeSessionId` and the transcript's id.
- **Tests that pin the hold.** `tests/wt-session-hold-resumable.test.sh` covers:
  - the clock, killing the mtime mutant;
  - a bad `lastTerminalAt` (case 12c);
  - exclusion by `resumeSessionId` (12d);
  - exclusion by the transcript's id (12f).

## Related Issues

- hov-stack#793 (the incident) and PR #796 (the fix).
- #451 and #453: reclaim-sweep keeps a done job's scratch to the 72-hour floor when its last turn delivered no result. Its per-turn comment predates them.
- #403: the not-done job hold this extends.
- `harness/worktree-fleet-hygiene.md`: the Resumable hold paragraph.
- `docs/solutions/best-practices/diff-installed-and-patched-sweep-plans-on-the-real-host-before-shipping-a-session-hold-change.md`: the countermetric that checked #796 on the real host.
