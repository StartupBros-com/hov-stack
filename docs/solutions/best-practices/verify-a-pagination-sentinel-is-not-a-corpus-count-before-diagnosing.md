---
title: "Verify a pagination sentinel is not a corpus count before diagnosing a hollow index"
date: "2026-09-08"
category: best-practices
module: cass-search-total-matches
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A search, list, or query API response includes a total-like field (total, total_matches, count, has_more) and several structurally different queries all return the exact same value"
  - "That value equals the request's page size, or limit+1, consistent with a has-more pagination sentinel rather than a true match count"
  - "The near-identical count is about to be used as evidence that a corpus, index, or backend is empty, hollow, or degraded -- especially when it resembles a known upstream bug report"
  - "The system exposes an authoritative state surface (a build/index manifest, a status --json, a doc-count field) that has not yet been read before concluding the corpus is empty"
  - "The actual returned hits have not yet been checked for whether their content matches the query term"
symptoms:
  - "Every diagnostic query, on unrelated subjects, returns the identical total_matches value"
  - "That value tracks the query's --limit flag: raising the limit raises the reported total by the same amount"
  - "A confident diagnosis of a hollow corpus is drafted and matched to an external bug-tracker issue with a similar-sounding symptom, on the way to being filed upstream"
  - "The manifest reporting the real indexed document count sits unread in the filesystem the whole time"
  - "The returned hits, when actually inspected, do contain the query term -- directly contradicting the hollow-index theory"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - "cass-cli"
  - "quill-lexical-index"
  - "lexical-generation-manifest"
  - "coding_agent_session_search#457"
tags:
  - pagination-sentinel
  - has-more-count
  - fictional-diagnosis
  - falsification-test
  - search-verification
  - state-surface
  - upstream-issue-misfile
---

# Verify a pagination sentinel is not a corpus count before diagnosing a hollow index

## Problem

`cass search --robot` returns a `total_matches` field. Every diagnostic query in this incident ran at `--limit 3` and got back `total_matches: 4` — for four unrelated queries (`supabase RLS policy`, `docker`, `checkpoint_incomplete`, `stripe webhook signature`). Four different queries returning the identical small number read as one thing: the index holds only a handful of documents.

That "hollow index" diagnosis was built out, reported to the operator as a confirmed fault, and turned into a plan to file a reproduction upstream — before anyone checked whether the number meant what it looked like it meant.

It didn't. `total_matches` is a has-more sentinel: `limit + 1` whenever more results exist. `--limit 3` → `4`; `--limit 25` → `26`. It answers "is there at least one more page", not "how many documents matched".

The real figure was one command away the whole time. `~/.local/share/coding-agent-search/index/*/lexical-generation-manifest.json` carried `indexed_doc_ct: 1121666`, with `build_state: validated` and `publish_state: published` — a fully healthy index, not a hollow one.

## Symptoms

- The same small number recurs across structurally different queries, and reads as corroboration rather than as a hint the number isn't tracking query content at all
- A "the corpus is hollow" diagnosis is built entirely from a response envelope field, without inspecting the hits
- The diagnosis matches an existing upstream issue closely enough to feel confirmed, supplying false confidence instead of independent evidence
- Nobody asks whether the returned hits actually contain the query term

## What Didn't Work

**Treating a repeated small number as confirmation.** Repetition across queries only rules out per-query noise. It says nothing about whether the field being repeated is the right field to read. Every call used the same `--limit`, and the field tracks the limit.

**Pattern-matching to an upstream issue before independently reproducing it.** The symptom resembled `coding_agent_session_search#457` closely enough that the plan moved straight to filing. Matching a known bug report substitutes someone else's stated symptom for a check of your own instrument.

**Building on an instrument reading without falsifying it.** The whole diagnosis rested on one field, from one tool, at one settings value. Nothing forced a check of whether that field would look identical whether the index held 4 documents or 1.1 million.

## Solution

The question that should have come first: **do the returned hits contain the query term?** They did — each query returned a relevant hit containing its term. Search was working. That reframed "why is the index hollow" into "why does this number look small", which points straight at the pagination parameter.

Two independent one-command falsifications converge:

- **Vary the suspect input and see whether the reading tracks it.** Re-running the same query at a different `--limit` moved `total_matches` in lockstep (`3`→`4`, `25`→`26`). A true corpus count is invariant to page size; a value that moves with `--limit` is describing pagination.
- **Read the instrument's own source of truth instead of a derived response field.** The generation manifest reports `indexed_doc_ct` directly with a build/publish state attached. Read once, it settles the question without reasoning about `total_matches` at all.

Either check alone would have caught this before anything reached upstream.

## Why This Works

A reading taken from an instrument is a claim about that instrument's output, not yet a claim about the world it measures. The claim only transfers once you know what produced the number.

`total_matches` is downstream of two different processes that both emit small integers: "there are few matching documents" and "there is at least one more page beyond what you asked for". Only one says anything about the corpus. Without isolating which is running, the same output is compatible with two contradictory diagnoses — and confidence from repetition doesn't discriminate, because it is equally consistent with both.

Each check removes exactly the confound. Varying `--limit` holds the query fixed and moves the one parameter only a has-more sentinel would respond to. Reading the manifest bypasses the derived field for a number whose definition is stated in the artifact itself. Inspecting hits tests the thing actually in question — did search work — rather than a metadata field never guaranteed to answer it.

## Prevention

1. **Find out what produces a number, not just what it's named.** A field called `total_matches` inviting a "how many matched" reading is not evidence that it means that.
2. **Vary one suspected input and watch what moves.** If a reading should reflect the corpus, changing something unrelated to the corpus — page size, offset, sort order — must not change it. If it does, the reading tracks what you varied. One command, cheaper than every step built on the wrong reading.
3. **Prefer a ground-truth artifact over a derived response field.** A count stamped by the system that owns the data is harder to misread than a field emitted as a side effect of pagination.
4. **Check the payload, not just the envelope, before diagnosing "nothing is there."** A hollow-index diagnosis that arrives without inspecting a single hit skipped the cheapest disconfirming check available.
5. **Matching an existing upstream issue is a hypothesis, not a confirmation.** Treat a similar-looking known bug as a reason to reproduce independently, not licence to skip falsification.

## Related Issues

- `verify-subagent-counts-before-classification` (memory) — nearest cousin: a number trusted for a classification without independent verification. Distinct fix, though: recompute from another source, versus perturb an input and check functional dependence.
- `assert-the-precondition-not-just-the-outcome` (memory) — sibling discipline. That trap is asserting an outcome without confirming the code path ran; this is asserting a value's meaning without confirming what it represents.
- `silent-fallback-tools-hide-outages` (memory) — there a tool failed silently and looked healthy; here a tool succeeded and its output was misread. Both trust surface meaning over provenance.
- `dont-narrate-intended-behavior-as-observed-progress` (memory) — same family of ungrounded confidence.
- `docs/solutions/logic-errors/fail-closed-gate-on-monotonically-degrading-input-becomes-a-permanent-latch.md` — same workstream and same instrument; a different misclassification, same discipline of checking what a signal is coupled to.
- `Dicklesworthstone/coding_agent_session_search#457` — the upstream issue this was headed toward. Never filed, because falsification caught it first.
