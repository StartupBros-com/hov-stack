---
title: "Poll long waits from a Monitor running a script file, not a sleeping background shell; Claude Code's own pressure reap killed the shell, not the harness watchdog"
date: "2026-09-13"
category: best-practices
module: claude-harness-background-waits
problem_type: developer_experience
component: development_workflow
severity: medium
applies_when:
  - "Waiting minutes for CI, a merge, or a release step while several Claude Code sessions run on the same machine"
  - "A background Bash watcher returns 'stopped because the system is running low on memory' before its condition is met (cause and opt-out: harness/wsl-memory-bounds.md)"
  - "The worktree shape guard refuses an inline polling loop because it contains command substitution or a gh --jq expression"
tags: [claude-code, background-tasks, monitor, pressure-reap, polling, worktree-guard, ci-wait]
---

# Poll long waits from a Monitor running a script file, not a sleeping background shell; Claude Code's own pressure reap killed the shell, not the harness watchdog

## Context

During the sign-it releases, two background shells of the form `sleep 150; gh pr checks --watch ...; gh pr view ...` were killed with "stopped because the system is running low on memory" while four Claude Code sessions and a gateway process held most of the machine's 40 GB. The wait was not the problem, and neither was the harness watchdog: `bin/wsl-watchdog.sh` kills only orphans (parent gone) and processes over 4 GB, and recorded no kills in the two weeks to 2026-09-28. The kill was Claude Code's own background-shell memory-pressure reap, decoded from the 2.1.284 binary on 2026-09-28 (`harness/wsl-memory-bounds.md`, "Claude Code's own background-shell reap"): when the host's memory PSI trigger fires with `MemAvailable` under 4 GiB, and the session has had no human input for 30 minutes with no turn running, Claude Code stops the session's running background task, whatever it is doing. The session load was context, not the trigger; the pressure came from short single-process bursts. Since dotfiles#1443 the reap is opted out for every new session (`CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` in the settings env). The merge it was waiting for happened anyway; the agent simply never heard.

## Guidance

1. **Put the poll in a script file.** The worktree shape guard refuses inline loops that carry `$( )` in argument position or a `gh --jq` expression inside a construct, so an inline `while true; do s=$(gh ...); ...; done` is rejected before it runs. A file under the job's scratch directory, run with `bash <file>`, passes and is reviewable.

2. **Run it under Monitor, bounded, emitting only terminal states.** Monitor treats each stdout line as an event and ends when the script exits. The script polls every 60 seconds, prints one line when the run or PR reaches a terminal state (success, failure, cancelled; merged, closed), then exits. No `tail -f`, no `while true` without an exit, no success-only filter: a failed run must produce a line too.

```bash
# poll-1141.sh: one line at the terminal state, then exit
R=startupbros-com/hov-stack
while true; do
  s=$(gh run view 34726022619 --repo "$R" --json status,conclusion --jq '.status + ":" + (.conclusion // "-")' 2>/dev/null || echo "query-failed:-")
  case "$s" in completed:*) echo "rerun $s"; gh pr view 1141 --repo "$R" --json state,mergeCommit --jq '"pr1141 " + .state + " sha=" + (.mergeCommit.oid // "null")'; exit 0;; esac
  sleep 60
done
```

3. **Do the follow-up in the script when it is mechanical.** The merge poll can run the worktree closeout itself once it sees `MERGED`, so the agent gets one notification carrying the activation line instead of a wake-up and another round trip.

4. **Know what actually stops a background shell.** The harness watchdog does not rank a session's shells by size; it kills only orphans and processes over 4 GB. The stop comes from Claude Code's own reap, which needs the memory trigger plus 30 idle minutes with no turn running, so it lands exactly while the model waits on a long background command. Sessions started after the #1443 activation (2026-09-28) no longer carry it; older sessions do. Whether a Monitor task is exempt has not been shown: the three survivals below are consistent with the reap's idle or no-turn conditions simply not holding at those moments.

## Why This Matters

A killed watcher is a silent failure: the notification says the command was stopped, not what happened to the thing it watched, and the agent's next step depends on that state. Two such kills in one release cost a re-query each and would have cost a missed merge if the agent had not re-checked. The Monitor form survived the same pressure for the remaining three waits, though the mechanism of that survival is not established (see guidance 4).

## When to Apply

- Any wait longer than a couple of minutes while other sessions are active.
- Any poll the shape guard refuses inline: move it to a file rather than simplifying it into something less specific.
- Never use a Monitor for a single "tell me when the build finishes" when a bounded `until` loop in a background Bash will exit in seconds; the Monitor is for waits measured in minutes under contention.

## Examples

- **Killed:** `sleep 150; gh pr checks 1141 --watch --interval 45 > log; gh pr view 1141 ...` as a background Bash, twice, at 27 GB used.
- **Survived:** the script above under `Monitor({ command: 'bash poll-1141.sh', timeout_ms: 1800000 })`, which reported `rerun completed:success` and then `pr1141 MERGED sha=606074f...`.

## Related

- `docs/solutions/best-practices/split-a-build-across-implementers-under-a-written-contract-and-let-reviewers-not-the-suite-find-the-blockers.md`: the release this happened in.
- `harness/wsl-memory-bounds.md`: what the reap is, its trigger conditions, and the fleet-wide opt-out (#1442, #1443).
