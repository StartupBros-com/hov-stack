---
title: "Routing metadata that says the alternative is broken outlives the outage"
date: "2026-09-08"
category: best-practices
module: skills-local
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "Writing or editing a skill description, tool description, AGENTS.md pointer, or README note that an agent uses to choose between options"
  - "An incident is in progress and the temptation is to record it where selection happens, so nobody picks the broken path"
  - "A description makes a claim about a DIFFERENT tool's current state -- broken, down, the only one working, prefer this over that"
  - "Closing out an incident and about to delete a banner that mixes a stale outage claim with a standing caveat"
symptoms:
  - "A description asserts another tool's fault instead of describing what this tool is for"
  - "The claim carries no falsifying condition and no command a reader could run to re-check it"
  - "The claim was true when written, during a real dated incident -- a snapshot frozen in present tense, not a fabrication"
  - "Routing silently narrows to one option and stays narrowed after the incident ends"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - "skills-local"
  - "skills-localize.sh"
  - "cass-vec"
  - "cass-rerank-local"
tags:
  - routing-metadata
  - skill-description
  - stale-claim
  - agent-selection
  - incident-closeout
  - falsifying-condition
---

# Routing metadata that says the alternative is broken outlives the outage

## Problem

Two `skills-local/*/SKILL.md` files encoded a real 2026-09-07 outage as a claim inside the one field an agent reads to choose between them.

`cass-vec`'s `description:` said it was *"Currently the ONLY working search over the session archive: cass's own lexical index is failing with query-fuel exhaustion, which also takes `cass search` and `cass-rerank` down silently."* `cass-rerank-local`'s body opened with *"BROKEN as of 2026-09-07 — prefer the `cass-vec` skill."*

Both were true when written. The index was repaired on 2026-09-08. Neither file named a condition that would make its claim false, so each kept asserting a fixed fact after the fact changed — and every session-search request kept routing to `cass-vec` and away from the other two, justified by an outage that had ended.

## Symptoms

- A description makes a claim about a *different* tool's state rather than about what this tool is for
- The claim carries no falsifying condition and no check command
- It was true when written, during a real dated incident — a snapshot frozen in present tense
- Routing narrows to one option and stays narrowed, with nothing in the text forcing a re-look

## What Didn't Work

**Deleting the banner outright.** Stripping "BROKEN as of 2026-09-07" and the "ONLY working" clause would also have deleted two things still true: `cass-rerank`'s permanent silent-failure mode (it reads `.get("hits", [])` from an error payload carrying no `hits` key, so a failure prints `no results`), and `cass-vec`'s fixed 5,600-character per-conversation ceiling. A stale claim and a durable caveat sit in the same paragraph; deleting on sight of the stale part risks taking the durable part with it.

**Softening the tense without adding a next step.** Rewriting "BROKEN" to "was broken" keeps the same defect in weaker language — it still gives the next reader no way to verify current state before acting on the sentence.

## Solution

PR #1084 rewrote both descriptions to state what each tool is *for*, not what a neighbour lacks.

- `cass-vec` dropped the "ONLY working" clause: *"Use when you remember what a past session was ABOUT but not the words in it… For an exact string you remember typing, use `cass search`."* It cites its own measured number rather than a competitor's fault.
- `cass-rerank-local`'s banner became *"Working again as of 2026-09-08"* — the outage narrated as closed and dated — immediately followed by the caveat that survives it, with a concrete next step: *"If it returns nothing, confirm with `cass search "..." --robot` before concluding the archive has no answer."*
- Both gained a positive three-way selection table (exact string → `cass search`; wording forgotten → `cass-vec`; single best hit → `cass-rerank`), so an agent picks by fit rather than elimination.

All three tools were re-verified on the repaired binary before the rewrite: four distinct queries returned four distinct result sets at the default fuel budget, hybrid returned `count=5`, `cass-rerank` returned three relevant hits with the gateway at 200, and relevance was spot-checked rather than counted (a query returned a relevant hit containing its term).

> **Update 2026-10-01.** The `cass-rerank` caveat this doc kept as durable was later removed by fixing the code, so the caveat no longer applies. PR #1496 made the wrapper report a retrieval failure instead of printing `no results`. Its JSON now carries `rerank_status`: `failed` (`scripts/cass-rerank:63`), `no_candidates` for a genuinely empty retrieval (`:198`), and `lexical_fallback` when scoring fails without `--require-rerank` (`:210`). So the "if it returns nothing, confirm with `cass search`" step quoted above is no longer in `skills-local/cass-rerank-local/SKILL.md`; a dated historical note replaces it. The lesson is unchanged. A caveat about a tool's own mechanism outlives an outage only until that mechanism is fixed, so the "two edits" in Prevention item 3 apply again when the caveat itself retires.

## Why This Works

An agent treats a description as an operative fact and acts on it immediately — it is not prose a human skims with time to notice it's dated. Whatever the text asserts converts directly into a routing decision, every time, with no human in the loop to catch drift.

A claim shaped "the alternative is broken" is a bet that an external condition stays fixed forever. When it stops being fixed, the sentence keeps steering, and it does so *confidently* — a false "X doesn't work" reads exactly like a true one. That is the asymmetry with ordinary stale prose: prose nobody reads goes inert, while stale routing metadata is read on every selection and actively misdirects.

A claim shaped "this tool is for Y" has no matching expiry. It stays true regardless of any other tool's state, because it never referenced another tool's state to begin with.

The kept caveats survive the rewrite for the same reason: they are standing facts about *this* tool's own mechanism — a specific bad code path, a fixed context ceiling — not elimination claims about a neighbour's transient breakage.

## Prevention

1. **State what the tool is for, not what a neighbour lacks.** "Use this when you need Y" makes no claim about another tool's state and needs no expiry.
2. **Before writing "currently broken" or "currently the only one" into routing metadata, name the check that falsifies it.** If no specific command or condition can be named, write it as a dated incident note instead, or keep it out of the selection field entirely.
3. **Treat closing an incident banner as two edits, not one deletion.** Separate "this outage claim is now false" from "this is a standing caveat about the tool's own mechanism."
4. **Prefer a positive selection table over an elimination sentence** when several tools cover related ground. A table keyed on fit survives every outage and repair; a sentence naming one tool's fault does not.
5. **Apply this beyond skill descriptions** — tool descriptions, `AGENTS.md` "use X instead of Y" pointers, README migration notes. Anywhere routing is driven by a description field, "the alternative is broken" needs a falsifying condition attached or should not be written that way.

## Related Issues

- `verify-a-pagination-sentinel-is-not-a-corpus-count-before-diagnosing.md` (best-practices) — same outage window, a different misreading caught by the same discipline of checking what a signal is coupled to.
- `fail-closed-gate-on-monotonically-degrading-input-becomes-a-permanent-latch.md` (logic-errors) — same root cause surfacing as a third symptom. All three are downstream of one incident but distinct shapes: a gate that latches, a metric that is misread, and metadata that misroutes.
- `verify-stale-memory-architecture-claims` (memory) — names the general anti-pattern for memory notes: treat an old note's state claims as hypotheses and verify before relying. This incident shows the same discipline applies to skill descriptions, where the cost is higher because selection is automatic.
- `silent-fallback-tools-hide-outages` (memory) — the inverse: there a live failure is invisible; here a fixed failure is still being asserted.
- The `writing-for-agents` skill's "Pruning and drift" section is the nearest existing precedent, on three counts: *"A line loses relevance… by going stale as the behaviour it describes changes"* (Relevance and sediment); *"That verdict expires… Re-run the test after every model or CLI upgrade, not once"* (No-op verdicts are time-relative); and most directly, its caching rule — *"cache what the agent cannot find by looking… leave the one-command lookups to the environment, where they cannot go stale."* A "the alternative is broken" claim is exactly a cache of a one-command lookup (`cass search '<term>' --robot`), which is the category that rule says not to cache. What none of the three covers is where the stale cache lives here: the selection-driving `description:` field of a *sibling* tool, where it is re-read on every routing decision rather than merely skimmed.
