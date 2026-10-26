---
name: verification-architecture
description: "Two routes to a Definition of Done: ce-plan's native Verification Contract for planned work, VERIFY.md/NOTES.md scratch pair (verify-seed.sh) for ad hoc work, folded into the PR body"
metadata:
  node_type: memory
  type: project
  originSessionId: d2d7491f-67a4-491e-bcb6-4641e7c5f28e
---

# Verification architecture

Ports the convergent frontier finding (Factory's validation contracts,
OpenAI's strong goals, LangChain's forced pre-completion checklist) into the
harness with minimal machinery: every non-trivial unit of work carries a
testable Definition of Done authored BEFORE implementation, and it survives
the worktree's deletion by living in the PR body.

## Two routes to a Definition of Done

Planned work (route B): ce-plan already ships a Verification Contract +
Definition of Done inside the unified plan artifact
(`artifact_contract: ce-unified-plan/v1`) and ce-work runs those gates per
unit. Nothing is duplicated here; when a plan exists, its DoD is what gets
pasted into the PR body's Definition of Done section.

Ad hoc work (route A): the work-spec issue's Acceptance Criteria are the
contract. `verify-seed.sh <issue-number>` (run in the worktree right after
`wt-new.sh`) copies them into `.claude/scratch/VERIFY.md`, together with the
issue's Planted negatives and its No-Claim Boundary — both are written before
implementation precisely so they sit in front of the implementer during it.
Failed approaches go to `.claude/scratch/NOTES.md` as they happen (the
Anthropic lab-notes pattern: recording dead ends stops the next session from
repeating them), and their outcome now comes from a closed set rather than
free text, because free text loses the two cases that matter most —
`VOID` (the measurement could not have detected the thing) and `NO_EVIDENCE`
(the gate could not be evaluated). Filing either as a plain rejection invents
a false do-not-retry rule. Schema and rationale:
[evidence-regime](evidence-regime.md) §5.

## The scratch-pair lifecycle

`.claude/scratch/` is globally gitignored (`~/.gitignore_global`), so the pair
never pollutes a diff. Before requesting review, fold VERIFY.md into the PR
body's Definition of Done section and NOTES.md into Rejected approaches (the
PR template has both sections). wt-sweep.sh deleting the worktree then loses
nothing: the PR body is the durable copy.

## Independent validation norm

The implementer never judges its own work at the contract level (Factory's
self-evaluation-bias finding: 34% of their features were validator-triggered
fixes). For PR-sized work, a fresh-context subagent checks the diff against
the DoD before the PR is marked ready; below that (typo-class diffs), the PR
template's pre-completion checklist alone is enough. CI, plus the one
`/pro-gate` review on billing, auth, migration or CI diffs (merge-and-end in
`CLAUDE.md`), judges code quality; the DoD check judges "did it do
what it said"; different questions, don't stack tiers.

## Workflow/background runs

Long pipelines end with a completion-gate stage: DoD assertions checked with
evidence, verify command exits 0, no stray debug output in the diff; on
failure route back to implementation, capped at 2 retries, then surface.
Iteration and time budgets stay with the existing claude-loop.sh +
loop-guard.js fence; the gate does not reimplement them.

## The Stop gate is change-gated and environment-aware (v2, 2026-07-23)

`hooks/Stop/verify-on-stop.js` no longer verifies unconditionally. When armed
via trusted root, it first derives the session's plausible change set with no
extra state: dirty files count only when their mtime is at or after the
session start (read from the transcript's first timestamp), commits only when
made since session start, both filtered to files the verify command actually
covers (ts/js + toolchain config for typecheck, py for ruff, everything for a
repo's own verify.sh). Provably irrelevant sessions (read-only, docs-only,
sessions launched in a parked dirty checkout) stop cleanly. Any uncertainty
falls back to verifying, and the explicit `CLAUDE_VERIFY_ON_STOP=1` arm from
claude-loop.sh always verifies. Separately, `package.json` present with
`node_modules` missing short-circuits to a precise "deps were never installed
in this fresh worktree, run <install cmd>" block instead of a wall of fake
type errors (the pattern behind ~92% of historical gate failures), and the
verify command runs with `CI=1` so package managers cannot stall on TTY
prompts. Motivating data: 2026-07-23 transcript audit, 83 gate-failure
sessions, 76 environmental.

Repos can (and monorepos should) ship a `.claude/verify.sh` so the gate runs
an affected-only check instead of the auto-detected repo-wide typecheck;
prbot's calls `turbo run typecheck --filter="...[merge-base]"`.

## Proposed, not yet enabled

A VERIFY.md-aware extension to `hooks/Stop/verify-on-stop.js` (block "done"
while unchecked `- [ ]` lines remain in `.claude/scratch/VERIFY.md`; strict
no-op when the file is absent) is designed but ships only with operator
sign-off, since it changes a globally-wired hook's behavior.

Related: [[gh-tracking-and-claims]].
