---
title: "A per-turn Stop-hook counter measures turns, not hand-backs; check what the flagged units did later before acting on it"
date: "2026-09-17"
category: best-practices
module: positive-handoff-shadow-ledger
problem_type: best_practice
component: development_workflow
severity: medium
applies_when:
  - "A metric is produced by a hook that fires on every assistant turn (Stop, PostToolUse) rather than at task completion"
  - "A weekly counter derived from that hook is being read as an incident rate, such as work handed back or tasks abandoned"
  - "Someone proposes switching a shadow-mode observer to a blocking mode on the strength of that counter"
symptoms:
  - "The weekly report shows handback-flagged in the hundreds while agents are visibly merging their own PRs"
  - "Nearly every recorded row carries the same condition (no-tag), which is what any mid-task turn produces"
related_components:
  - "verify-on-stop-hook"
  - "harness-doctor"
  - "harness-weekly"
tags:
  - stop-hook
  - shadow-mode
  - hand-back
  - metric-denominator
  - false-positive
---

# A per-turn Stop-hook counter measures turns, not hand-backs; check what the flagged units did later before acting on it

## Context

On 2026-09-17, the positive handoff protocol ran in shadow mode inside `hooks/Stop/verify-on-stop.js`: when a Stop fired, a session PR was open and green, and the final message carried no `result:` or `needs input:` tag, the hook appended one row per PR to `~/.claude/logs/handback-ledger.jsonl` and never blocked. Harness-doctor check 26 summed recent rows into the weekly `handback-flagged:N` line. Issue #409 tracked the residuals before flipping the mode to enforce. The counter read 183, and read as "hand-backs" it argued for enforcement. This is the historical measurement context, not the current predicate.

One bounded look at the ledger settled it. The file held 633 rows since 2026-08-18, one per distinct PR, 542 of them `no-tag`. Of the 44 dotfiles PRs recorded in the preceding 14 days, 40 had been merged since, none were still open, and 4 were closed. The hook was recording a Stop in the middle of a session that went on to finish. Enforce mode would have blocked nearly all of those sessions mid-task.

## Current implementation boundary

The current `handbackGate()` in `hooks/Stop/verify-on-stop.js` checks the state of session-authored PRs. Merged PRs and PRs with auto-merge armed resolve the handback check; an open, gate-green PR is not resolved merely by writing `result:` or `failed:`. A `needs input:` claim must reference a matching open, `needs-human`-labeled issue. Missing tags are therefore not the sole condition for an unresolved result.

Shadow ledger rows are deduplicated per session and PR, not appended for every Stop event. That bounds duplicate counting; it does not establish abandonment.

Mode determines the effect: `shadow` logs unresolved PRs without blocking; `enforce` can block the initial Stop; `off` skips the lookup. Inconclusive lookups neither block nor write the ledger. The outer `gate()` now composes verification and handback feedback on the initial Stop and skips both when `stop_hook_active` is true. This is one-shot feedback, not persistent per-gate retry enforcement.

These changes do not turn a Stop observation into proof that a task was abandoned. The historical counts below must not be presented as measurements of the current predicate, and a current shadow row still needs its event denominator and later PR state before it can support an incident-rate claim.

## Guidance

Before acting on a counter that a hook emits, do two things:

1. Name the event that fires the hook. A Stop hook fires at the end of every assistant turn, including turns in ordinary back-and-forth, not when a task is complete. A row per turn-with-an-open-PR is a count of turns, whatever the row is called.
2. Check the later state of a sample of the flagged units. If the PRs the counter flagged were merged by the same sessions shortly after, the counter is not measuring abandonment. A short read-only pass with `jq` over the ledger plus `gh pr view --json state` per flagged PR is enough; do not build a dashboard for it.

Then record the decision where the counter is read (the closing comment on #409 here), keep the observer non-blocking, and either change what the hook counts or stop treating the count as an incident rate. Do not tune a threshold on a number whose denominator is wrong.

## Why This Matters

Using a per-turn false-positive count as evidence for enforcement can punish normal work. The historical observer flagged 40 of 44 sessions that finished on their own; that is not a measurement of the current one-shot gate's blocking rate. The observer's real defects were narrower and were fixed without enforcement in PR #1188: lookups share one bounded budget, drafts and empty check rollups do not count as green, and escalation references must match the PR exactly.

## When to Apply

- Reading any `*-flagged:N` line in the weekly report whose producer is a per-turn hook.
- Deciding whether to move any shadow-mode observer to a blocking mode.
- Designing a new hook-emitted metric: decide at design time which event is the denominator and whether the healthy path also produces rows.

## Examples

The read that decided it, run against the live ledger:

```bash
jq -r '.condition // "-"' ~/.claude/logs/handback-ledger.jsonl | sort | uniq -c | sort -rn
jq -r 'select(.ts >= "2026-09-03")
       | select((.repo // "") | ascii_downcase == "startupbros-com/hov-stack") | .pr' \
   ~/.claude/logs/handback-ledger.jsonl | sort -un
# then, per PR: gh pr view "$n" -R startupbros-com/hov-stack --json state --jq .state
```

Result on 2026-09-17: 542 no-tag, 48 needs-input-artifact-invalid, 43 result-invalid; 40 merged, 0 open, 4 closed.

## Related

- Issue #409 (closed not planned, with the residual list) and PR #1188 (the hardening that was worth doing).
- `CONCEPTS.md` entries Hand-back and Shadow mode define the terms; a shadow row is evidence of a turn, not of a hand-back.
