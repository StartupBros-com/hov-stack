---
title: "Measure an always-on rule's exact shipped wording on a closing-report fixture; phrase human-only steps as a decision to ask for"
date: 2026-09-03
category: best-practices
module: claude-harness-always-on-rules
problem_type: best_practice
component: documentation
severity: medium
applies_when:
  - "Editing an always-loaded instruction file (CLAUDE.md, AGENTS.md) in a way that governs how a session ends a task or what it may hand to the operator"
  - "A judge panel or reviewer proposes wording changes to a rule that has already been behaviorally tested"
  - "A rule needs an exception for genuinely human-only steps (a credential, sudo, a policy call) without licensing hand-backs"
related_components:
  - claude-global-instructions
  - rent-check
  - shape-audit
tags:
  - always-loaded-context
  - agent-instructions
  - behavioral-fixture
  - hand-back
  - rule-wording
  - measurement
---

# Measure an always-on rule's exact shipped wording on a closing-report fixture; phrase human-only steps as a decision to ask for

## Context

The always-loaded file reaches every session and subagent, so its lines are edited under the harness's rule bar: a line earns its tokens only when the behavior it targets measurably occurred before it and measurably changed after (`docs/solutions/best-practices/demote-always-loaded-context-without-losing-authority.md` carries the load-class side of that bar). Landing the no-hand-back line for issue #918 (PR #920) showed that the bar applies to the *exact wording that ships*, not to the draft a review panel scored.

Three judges preferred a draft plus two grafts on argument. The grafted wording measured no better than having no rule at all. The tested draft had measured better. Only re-running the fixture on the final text caught the regression before it reached every agent.

## Guidance

Run a closing-report fixture on the final wording before pushing an edit to a rule that governs how a task ends:

1. Write four closing-report scenarios with an answer key: a blocked case that needs one human decision, a clean success, a success with a residual the agent cannot resolve itself (running sessions caching old settings), and a genuine human-only credential. The last scenario exists to catch over-refusal.
2. Give Sonnet arms only the always-on excerpt (current text vs proposed) and the scenario; ask for the closing report verbatim.
3. Judge with the key: hand-back (the report requires the human to run a command to finish the agent's task), wrong-live claim, correct signal line (`result:` / `needs input:`), over-refusal. A named credential login for the credential scenario is not a hand-back.
4. Ship only wording that measured; re-run after every graft, because a graft is a new text.

Phrase the human-only exception as something to ask for plus what the agent does next. Measured on 2026-09-03 (workflows `wf_4814873f-aa8`, `wf_57734721-2d0`, `wf_5291ea0b-2f4`; Sonnet arms, session-model judge):

| Line 23 wording | Hand-backs | Wrong-live | Correct signal |
|---|---|---|---|
| current: "the next command, not 'let me know how you'd like to proceed'" | 3/8 | 0 | 8/8 |
| draft: "one you take yourself, not one you hand the human to run... if genuinely unclear, or the remaining step is human-only, say so" | 1/8 | 0 | 8/8 |
| draft plus grafts: "...if the remaining step is genuinely human-only (auth, sudo, a policy call), **name that one step**" | 3/8 | 0 | 8/8 |
| shipped: "...when the remaining step is genuinely human-only (a credential, sudo, a policy call), **ask for that decision or credential and say what you will do once you have it**" | 0/12 | 0 | 11/12 |

"Name that one step" is satisfied by writing the command; "ask for the decision and say what you will do next" is satisfied only by a question plus an agent-owned follow-through. The shipped text is `CLAUDE.md:24`; the matching receipt rule for merges is `CLAUDE.md:83`.

Keep the anti-"let me know" intent by construction: a question with a promised follow-through is not a deferral, so the rule needs no extra clause for it. The shipped line has four clauses to two caveats; the old line had three to three, which the harness's armor test treats as already failing.

## Why This Matters

An always-on line is read by the model as an instruction template, so its verbs are executed literally. A wording that reviewers find clearer can move behavior the wrong way, and nothing but a fixture on the final text shows it. The cost of the check is minutes of Sonnet time; the cost of skipping it is a regression delivered to every session until the next audit. Recurrence before the rule was small but real: 2 genuine hand-backs among 21 command-shaped final messages across 203 sessions, plus three named incidents (#355, #508/#510, #893).

## When to Apply

- Any edit to a line in `CLAUDE.md` or `~/.codex/AGENTS.md` that governs turn-end, hand-backs, or completion claims; re-run the fixture on the exact final text after every wording change, including grafts from a review.
- Not needed for mechanism docs (HARNESS.md, runbooks) that agents load on read; the bar there is accuracy, not behavior.

## Examples

Refused-activation scenario, the case where the words matter. Under the grafted wording, both trials ended with `rm` / `mv` / `systemctl` for the operator to run. Under the shipped wording, all three trials asked "keep, move, or discard this file?" and said the agent would re-run the closeout itself:

```
needs input: dotup refused to activate PR #931's merge — one decision needed.
...
Decision needed: is hooks/PreToolUse/new-guard.js deliberate uncommitted work you want kept, or safe to discard?
- Keep it: I'll move it aside before re-running wt-done.
- Discard it: I'll delete it and re-run wt-done.
Tell me which and I'll run wt-done.sh myself and report the activation result — not a command for you to run.
```

The credential scenario stayed correct in every arm (`needs input:` naming `! gcloud auth login`), which is the over-refusal check passing.

## Related

- dotfiles#918 and PR #920 (the landed line, with the full measurement trail in the issue comments); dotfiles#909 and PR #915 (the mechanism the receipt rule points at); the sibling learning `docs/solutions/integration-issues/drive-post-merge-activation-instead-of-handing-back.md`.
- Memory note `always-on-rule-human-only-step-as-decision` (auto memory [claude]) records the same numbers; this doc is the repo-visible copy.
- Tooling for the field measurement the delete-when names: `scripts/shape-audit/` (denominator-corrected, model-matched), `/rent-check` for the always-loaded budget.
