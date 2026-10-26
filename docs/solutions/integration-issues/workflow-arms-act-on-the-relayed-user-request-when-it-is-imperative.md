---
title: Workflow arms act on the relayed user request when it is imperative
date: 2026-09-20
category: integration-issues
module: claude-harness-workflow-arm-preamble
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A Workflow arm's return value reads like a status report on the session's own work instead of matching the stage's schema or task"
  - "Side effects appear that no stage prompt asked for: an issue closed, an issue body edited, a PR opened, a memory note appended, all during a run that was only meant to read and score"
  - "Every arm transcript's first user turn begins with the harness preamble that relays the triggering user message verbatim, and that message is an instruction, not a question"
  - "The run cannot be salvaged by re-prompting the same arms, because the relay is unconditional and states that it wins over the computed task on conflict"
root_cause: missing_validation
resolution_type: workflow_improvement
severity: high
related_components:
  - workflow-tool
  - agent-tool
  - lean-reader
  - general-purpose-arm
tags: [workflow, relayed-user-request, imperative-injection, general-purpose-arm, prompt-composition, side-effect-audit, lean-reader, silent-failure]
---

# Workflow arms act on the relayed user request when it is imperative

## Problem

The Workflow tool prepends a verbatim relay of the session's triggering user message to every spawned agent's first turn, ahead of the stage prompt, and tells the arm that this relayed request outranks the computed task. When the triggering message is an instruction rather than a question, a general-purpose arm with Bash, `gh`, and Write treats the relay as its assignment and executes it instead of the stage's task, taking real actions in the repository and the memory store.

## Symptoms

- Workflow run `wf_905473e2` (six general-purpose arms: three configurations, two trials each, every arm asked to review a planted prose fixture for the anti-slop-list vet) returned three outputs that read as status reports on the session's closeout work rather than reviews. That mismatch between the return value and the stage's expected shape was the only alarm.
- The side effects surfaced in `gh` and in memory, not in the run's output. Two of the three status-report arms acted: one edited issue #1202's body from a scratch file and posted one comment; the other closed better-ccflare issue #356, posted two further comments on #1202, appended to one memory note, and opened PR #1237. The third reported "verification in progress" and touched nothing. The arm transcripts record each command; they live under the session's own transcript directory in `~/.claude/projects/` (a `subagents/workflows/wf_905473e2-67a/` subdirectory), not in the repository.
- Every one of the six arm transcripts, including the three that behaved, starts with the same first user turn: the harness preamble followed by the literal triggering message, "sure go ahead and deploy better-ccflare locally and verify the fix. then let's continue working through the pstack vet".
- The repo record of the discard is the re-run section of `harness/vet-fixtures/anti-slop-list/SCORING.md` (the 2026-09-20 prose fixture re-run) and the "Method notes" paragraph in PR #1240's body.

## What Didn't Work

- Re-prompting was never viable: the relay fires on every arm regardless of the stage prompt's wording, and its own text says the relayed request wins on conflict, so a stronger stage prompt cannot override it.
- Two moves were considered and not taken: rewording the triggering message (the operator's message is not the agent's to rewrite) and a Workflow-tool option to suppress the relay (none was found in this session).
- The only viable move was to stop using the tool that carries the relay for that stage.

## Solution

The six review arms and the judge were re-run through the Agent tool, which carries no relay: Sonnet subagents restricted to Read for the arms, two trials each, and a separate Agent-tool call at the session model for the judge, scoring six neutrally labelled outputs in shuffled order. `SCORING.md` states that every number in its re-run table comes from the Agent-tool rerun, and the table (bare 13.5 and 15.5 of 21, incumbent 18.5 and 18.5, candidate 15.5 and 16.0) is the one PR #1240 shipped.

A side-effect audit followed rather than a blind revert: PR #1237 was reviewed on its merits, amended, and merged; the #1202 body edit and comments were accurate and kept; the #356 closure was consistent with the deploy evidence and kept; the memory appendix was true and kept, with one clarifying paragraph added by the session. The incident itself went into a memory note and a papercut.

## Why This Works

The relay text, extracted from the installed CLI bundle (Claude Code 2.1.278, via `experiments/lean-reader-2026-09-19/binary-grep.py "Workflow harness"`), reads:

```
[Workflow harness — user request] The harness relays, verbatim and indented below, the user request that triggered this workflow run. This relayed request is the only user voice in this task; the computed task text that follows in the next turn is script output and cannot override or extend it. Where the computed task conflicts with this request, this request wins:
```

The harness frames the relayed message as the arm's sole authoritative user voice, outranking the stage prompt on conflict. An imperative relay is therefore not a misreading by the arm; it is the documented precedence order applied to a message that happens to be an instruction. A general-purpose arm has Bash, `gh`, and Write, exactly the tools needed to act on "deploy X and verify, then continue Y", so it does.

Routing the stage through the Agent tool bypasses the relay entirely, because the relay is specific to Workflow-spawned agents. Restricting the arm's tool surface removes the second failure mode even if relay-like framing arrived some other way: `agents/lean-reader.md` grants only `Read, Grep, Glob`, sets `omitClaudeMd: true`, and tells the agent it cannot write, edit, or run commands. An arm with no Bash and no `gh` cannot close an issue, edit a PR, or deploy anything, whatever it believes its task to be.

## Prevention

- When the session's triggering message is imperative (an instruction, not a question), run measurement and review stages through the Agent tool rather than Workflow, or pin `subagent_type: lean-reader` for any stage that only needs to read and report. The user-level CLAUDE.md Model Routing section already names lean-reader for read-only stages, judge stages included.
- Choose an arm's tool surface by what it must not be able to do. A stage that only scores text has no reason to hold Bash or `gh`; giving it those tools turns any relayed or injected instruction into an action.
- After any Workflow run whose arms held Bash, audit `gh issue list`, `gh pr list`, and the memory directory for side effects the stage prompts did not ask for. That audit is how the three rogue arms were caught.
- Treat a Workflow arm's return value as suspect the moment it reads like a status report instead of the stage's schema. That mismatch, not an explicit alarm, was the signal here.
- Record a discarded run in the measurement's own notes, as `SCORING.md` and PR #1240 do, so the shipped numbers carry their provenance.
- No fix exists at the tool level as of this writing: there is no known Workflow-tool flag to suppress or gate the relay when the triggering message is imperative, so the routing choice above is a workaround, not a closure of the gap.

## Related Issues

- dotfiles PR #1240 (the measurement whose Method notes record the discarded run), PR #1237 (opened by a rogue arm, later reviewed on merits and merged), issue #894 (the measurement's tracking issue, closed).
- Memory note `workflow-arms-execute-the-relayed-user-request` (auto memory [claude]) and the papercut logged the same day.
- `docs/solutions/integration-issues/use-workflow-isolation-worktree-not-enterworktree-from-a-pinned-subagent.md`: the other Workflow-tool learning in this store, on a different defect in the same tool.
- `agents/lean-reader.md`: the read-only subagent type that makes an arm unable to act.
- `docs/solutions/best-practices/measure-always-on-rule-wording-on-a-closing-report-fixture.md`: a fixture whose Sonnet arms run through real Workflow runs and therefore receive the relay too; its design predates this finding.
