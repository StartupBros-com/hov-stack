---
name: goal-brief
description: Draft a /goal contract body (Objective, Read first, Constraints, Validate, Document, Checkpoints, Stop when) from your stated intent, ready to paste after /goal. Always includes anti-reward-hacking and anti-scope-creep clauses.
disable-model-invocation: true
argument-hint: "<what you want the agent to accomplish>"
allowed-tools: Read, Grep, Bash
---

# Goal brief

<!-- Template adapted from davidondrej/skills goal-loop (template only; every
     product/feature claim in that source -- lifecycle states, pause/resume,
     create_goal, subscription auth -- is fabricated and discarded; LICENSE +
     UPSTREAM.md in this directory carry attribution). Our real `/goal <text>`
     is a Claude Code built-in: it installs a session-scoped Stop hook that
     blocks stopping until the condition holds and auto-clears on success
     (see memory: goal-command-sets-session-scoped-stop-hook). -->

Draft the contract body below from `$ARGUMENTS` (or the conversation's stated
intent if no argument was given). **Emit only the contract body** -- no
`/goal` prefix, no explanation before or after it. The user pastes `/goal`
in front of it themselves.

## Before drafting

- Identify the actual files/dirs the agent should read first -- list what
  really exists in this repo (`ls`, `grep`, or what's already open in
  context), never an invented path.
- Identify the real validation command for this project (`pnpm test`,
  `pytest -q`, etc. -- check `package.json`/`pyproject.toml`, don't guess).
- One objective, one stop condition -- this is a contract, not a backlog.
  If the objective needs more than ~4,000 characters, put the detail in a
  file (`PLAN.md`) and point the goal at it instead of inlining it.
- Use literal strings for paths, commands, and issue numbers -- exact, not
  paraphrased.

## Template

```
**Objective:** <one-sentence objective>
**Read first:** <files/dirs/PLAN.md/issue -- literal paths>
**Constraints:** <what must NOT change: public API, files, libs, conventions>. Do not refactor unrelated code. Do not add dependencies.
**Validate:** `<exact command>` after each change
**Document:** write concise, targeted documentation for the changes -- new .md files or focused updates to existing docs
**Checkpoints:** work in checkpoints; log progress briefly
**Stop when:** <verifiable condition>, OR when further changes require human/product input. Do not delete, skip, weaken, or narrow tests to make the goal pass.
```

The two appended sentences -- scope-creep in **Constraints**, reward-hacking
in **Stop when** -- are non-negotiable. Include them verbatim on every
contract, even when the user's stated intent doesn't mention them.

## Examples

**Migration:**
```
**Objective:** Migrate this project from Pydantic v1 to v2.
**Read first:** pyproject.toml, src/, tests/
**Constraints:** no public API changes; keep imports backwards-compatible via shims if needed; no new dependencies. Do not refactor unrelated code.
**Validate:** `pytest -q` after each change
**Document:** update the migration notes in docs/ as shims or behavior changes land
**Checkpoints:** work in checkpoints; log progress briefly
**Stop when:** full suite passes with zero deprecation warnings, OR when a change requires architecture decisions. Do not delete, skip, weaken, or narrow tests to make the goal pass.
```

**Coverage lift:**
```
**Objective:** Raise coverage in src/auth/ from ~38% to >=75%.
**Read first:** src/auth/, tests/auth/, AGENTS.md
**Constraints:** no new deps; mirror existing test style; do not modify production code unless strictly required for testability. Do not refactor unrelated code.
**Validate:** `pytest --cov=src/auth --cov-report=term-missing`
**Document:** note any testability seams added, in the module's README or docstrings
**Checkpoints:** work in checkpoints; log coverage delta each one
**Stop when:** coverage >=75% AND all tests pass, OR when uncovered code needs design changes. Do not delete, skip, weaken, or narrow tests to make the goal pass.
```
