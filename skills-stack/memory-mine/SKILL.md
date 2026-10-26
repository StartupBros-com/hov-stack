---
name: memory-mine
description: Run one deterministic, budgeted directed-capture batch for an explicit Claude Code project store. Use manual workspace mode only when cross-agent cass sessions are intentionally in scope.
argument-hint: <project-slug> [workspace:/absolute/path]
disable-model-invocation: true
allowed-tools: Bash, Read
---

# Memory Mine: one bounded capture batch

Mining expands project memory with session-derived notes; `/memory-dream:dream` later
consolidates them. `memory-mine-controller.py` owns scope, admission, one restricted
drafter, deterministic validation/application, checkpoints, and body-free receipts.
Do not reproduce those stages in this skill.

## Prerequisite: a model proxy

The drafter child gets no credential variables from the environment. The controller
sets its `ANTHROPIC_BASE_URL` to `MEMORY_MINE_PROXY_URL`, default
`http://localhost:8788`, so an Anthropic-compatible proxy must answer there. An empty
or non-http URL is refused before the launch is recorded and costs nothing. A launch
whose proxy does not answer is recorded first and counts against the ISO-week budget
in step 2. Without a proxy, do not run this skill.

## 1. Require one explicit project

The first argument is exactly one Claude Code project slug such as
`-home-user-SITES-acme-app`. Reject `all`, lists, globs, and a missing slug. When the
slug begins with `-`, pass it using `--project=<slug>` so argparse cannot treat it
as an option.

An optional second argument may be `workspace:/absolute/path`. This is a manual-only
request to include cass-discovered cross-agent sessions for that exact workspace.
The controller validates the workspace and still selects exactly one two-session
batch. Scheduled runs never accept a workspace and never guess one from the slug.

## 2. Invoke the controller once

Without a workspace:

```bash
python3 ~/.claude/scripts/memory-mine-controller.py --project=<slug>
```

With an explicit workspace:

```bash
python3 ~/.claude/scripts/memory-mine-controller.py \
  --project=<slug> --workspace /absolute/path
```

Run one command only. The controller is the sole owner of model launch, drafting,
validation/application, retry policy, and store scope. Its ISO-week budget includes
failed and interrupted launches.

## 3. Report the body-free result

- `complete`: report the run ID; the private final receipt carries counts and usage.
- `no-work`: the explicit store has fewer than two settled unmined sessions.
- `budget-exhausted`: three drafter attempts already started in this ISO week.
- nonzero exit: report only the controller's closed failure code and private run ID
  when present. Never print frozen session content, candidate note bodies, or raw
  child output.

A successful batch may write candidate-maturity notes or mark a reviewed session
`no-durable-knowledge`; both are deterministic progress. If accumulated candidate
notes later overlap or decay, hand consolidation to `/memory-dream:dream` rather than
merging or archiving here.
