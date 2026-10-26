---
title: "A 'no reader' verdict on a store needs the consumer's own definitions searched and a usage sample before work is filed"
date: "2026-09-28"
category: best-practices
module: harness-vet-no-consumer-verdicts
problem_type: best_practice
component: development_workflow
severity: high
resolution_type: workflow_improvement
applies_when:
  - "A vet, audit, ideation or cleanup concludes that a store, script, log or doc has no reader or no consumer and proposes work on the strength of that absence"
  - "A grep for the store's literal path is the only evidence, and the consuming system is a plugin or tool whose prompts and references are markdown"
  - "The consumer may spell the path differently from the repo, such as <root>/solutions/ for docs/solutions"
  - "The verdict's own text carries a not-searched caveat that names a surface the verdict depends on"
  - "An issue or plan inherits a no-consumer claim from an earlier report without re-checking it"
symptoms:
  - "Issue #1450 proposed bridging docs/solutions into memory because the store supposedly had no reader, while ce-plan, ce-ideate and ce-code-review all dispatch learnings-researcher against it"
  - "The round-3 ideation's no-consumer search for four orphan candidates had to be redone with markdown included"
  - "The vet's own Not searched list disclosed the plugin agent list as a gap before the verdict was acted on"
related_components:
  - compound-engineering
  - learnings-researcher
  - docs-solutions
  - harness-vet
tags:
  - no-consumer
  - no-reader
  - absence-verdict
  - path-spelling
  - usage-sample
  - consumer-search
  - vet
  - transcript-sweep
---

# A 'no reader' verdict on a store needs the consumer's own definitions searched and a usage sample before work is filed

## Context

The Ground Truth vet (`docs/vets/2026-09-28-groundtruth-self-coordinating-agents-harness-vet.md`) rated V4, "retrieval of compounded learnings", EXTRACT. Its premise was that `docs/solutions/` had no reader (V4 row, line 250). Issue #1450 inherited that premise as a work item: add a `reference` memory note per solution so that something would read the store.

The premise was wrong. The vet's own section 5 disclosed the gap when it was written. Its "Not searched" line named "the compound-engineering plugin's own agent list (relevant to V4)" and called it "a gap, not evidence of absence" (vet lines 532-535). The verdict shipped anyway, and the work item was filed on top of it.

The correction landed in PR #1451, in the vet's "Corrections after merge" section (the "V4 and X2, corrected" paragraph, line 471). The #1450 item was withdrawn on 2026-09-28 (PR #1454). The first grep had searched for the literal `docs/solutions`. Compound-engineering 3.29.0 spells the path `<root>/solutions/`, so the grep matched nothing.

A second instance turned up in round 3. `docs/ideation/2026-09-26-harness-throughput-and-ceremony-round-3-ideation.html` (line 444) records a ceremony sweep whose consumer search was redone with markdown included. The first pass had left markdown out, which is where a skill or reference doc would name a script; one of that run's own ideation frames raised the exclusion before the search was redone (session history: the 2026-09-27 round-3 refinement session). The redone search confirmed the orphans there.

## Guidance

Before filing any work against a "no reader" or "no consumer" verdict:

1. **Enumerate readers through the consumer's own definitions.** Read the agent, prompt and reference files of the system that would consume the store. Do not rely on skill names, an index, or a listing. Here the readers live in `skills/*/references/`, not in `SKILL.md` titles.
2. **Search every spelling of the path or identifier.** Cover the literal repo path, the `<root>`-relative form, the basename or directory name, and the variable or config key that holds it. A grep for the full repo path only finds callers that spell it that way. Include markdown; it is where prompts and references live.
3. **Take a usage sample** from transcripts or logs. Report it as an upper bound with its denominator. A transcript corpus contains the review's own reads, so exclude the reviewing session and any sessions that worked on the component (`docs/solutions/best-practices/transcript-corpus-detectors-count-the-review-itself.md`). Count `tool_use` blocks, not records: Claude Code writes one record per assistant content block, so record counts run about 2.45x the request count while `tool_use` counts are unaffected (the header of `scripts/transcript-mine.py` states this and dedupes on message id). Retired 2026-09-29 (dotfiles#1429): that script is deleted, and `scripts/compaction-profile.py` dedupes on message id the same way. `git log --diff-filter=D --format=%h -- scripts/transcript-mine.py` names the deleting commit, and `git show <that commit>^:scripts/transcript-mine.py` prints the script.
4. **Treat a disclosed "not searched" surface as blocking.** If the verdict's own caveat names a surface the verdict depends on, search that surface first. A verdict cannot rest on a gap it has admitted to.
5. **Only then file work against the absence.** If a reader turns up, the work item changes shape or disappears.

Commands that would have found the reader here:

```
rg -l 'solutions/' ~/.claude/plugins/cache/every-marketplace/compound-engineering/3.29.0/skills
rg -n 'learnings-researcher' ~/.claude/plugins/cache/every-marketplace/compound-engineering/3.29.0/skills
find ~/.claude/plugins/cache/every-marketplace/compound-engineering/3.29.0 -name 'learnings-researcher*'
```

For the transcript sample, count only `tool_use` blocks whose file path falls under `docs/solutions`, dedupe by session, and state the total session count.

## Why This Matters

An absence verdict is cheap to state and expensive to act on. This one turned into a filed issue (#1450) that proposed bridging a store into memory. The store already had a live reader, and the proposed index lines would not have fit in the memory index's remaining headroom (vet lines 471-490 give 52 lines against 430 bytes). Left unchecked, the result would have been a bypass or bridge built for a problem that did not exist.

The repo's `CONCEPTS.md` defines a *State surface* as the query a system exposes over what currently exists, answered from current state and not reconstructed from history. For the question "who reads this store", the consumer's agent and reference definitions are that state surface. An index, a skill-name grep or a path-literal grep is a proxy, the same kind of reconstruction from a weaker source that `verify-a-ledger-inferred-backlog-against-the-engines-state-surface.md` describes for ledger rows. That entry covers counting outstanding units. This one covers the reader side of a store. Both say to ask the authoritative surface, not infer from what a proxy fails to show. `CONCEPTS.md` names this claim an *Absence verdict*.

It also bears on the *Ceremony Test* in `CONCEPTS.md`, which requires an artifact to name its consumer. That test presupposes an honest consumer search. If the search is shallow, the test either rejects real consumers or approves phantom gaps.

The nearest sibling, `a-grepped-implementation-string-in-a-test-is-an-invisible-caller.md`, covers callers that a rename sweep misses. This entry is the same failure at the level of a whole store: a caller that a single-spelling search cannot see.

## When to Apply

- Any "no consumer", "orphan", "dead store", "nothing reads X" or "write-only" claim in a vet, an ideation's ceremony sweep, or a cleanup pass.
- A plan to bridge, mirror or index a store into another surface so that something will read it.
- A proposal to delete a store, script or log on the grounds that it is unused.
- Any time the verdict's own text carries a "not searched" caveat.

## Examples

**Before (vet, first pass).** The grep searched for the literal `docs/solutions`. It found no reader in the plugin, so the vet concluded "no reader" (V4 row, line 250). The plugin's agent list was disclosed as unsearched (vet lines 532-535) and the verdict shipped anyway. Issue #1450 carried it forward.

**After (second follow-up).** Reading the plugin's reference files found three dispatch sites in compound-engineering 3.29.0. The paths in this example are relative to the plugin's install directory, `~/.claude/plugins/cache/every-marketplace/compound-engineering/3.29.0/`, not to this repo; the version pin matters because a plugin update can move them:

- `skills/ce-plan/references/research.md:53`: "`references/agents/learnings-researcher.md` — pass the planning context summary, the search-root list from **Pack discovery**, and `$SCRATCH_DIR/learnings.md`."
- `skills/ce-ideate/references/grounding.md:57`: "**Learnings search** — read `references/agents/learnings-researcher.md` and dispatch a generic subagent seeded with that local prompt plus a brief summary of the ideation focus."
- `skills/ce-code-review/references/select-and-route.md:18`: "`learnings-researcher` — there is institutional knowledge to check the change against: `<root>/solutions/` exists and a cheap path/title search finds a plausible match..."

Agent definitions exist for four skills: `skills/ce-plan/references/agents/`, `skills/ce-ideate/references/agents/`, `skills/ce-optimize/references/agents/` and `skills/ce-code-review/references/personas/`. Each spells the store `<root>/solutions/`. For example, `skills/ce-plan/references/agents/learnings-researcher.md:37` reads "The `<root>/solutions/` directory contains documented learnings with YAML frontmatter." That spelling explains why the `docs/solutions` grep missed every one of them.

**Usage sample (upper bounds).** Per the vet's second follow-up (vet lines 471-490): a 30-day sweep of dotfiles session transcripts counted only `tool_use` blocks under `docs/solutions`. Of 258 top-level sessions, with the sweeping job excluded, 65 read the store. Of those, 42 came right after a CE skill invocation, 52 were bulk reads (five or more files, the researcher's shape) and 13 were small ad hoc reads. The vet flags these as upper bounds, because Bash-shaped counts and mixed sessions over-attribute to CE. The sweep was not re-run for this entry; the numbers are the vet's.

**Second instance (round 3, line 444).** The first consumer search for the ceremony sweep's orphan candidates did not include markdown. The redone search, markdown included, "confirms all four orphans": `transcript-mine.py` is named only by tests and learnings, `memory-access.jsonl` has one writer and no reader, and the HARNESS.md permission summary and the dispatcher ledger's `cost_usd` field were confirmed the same way. The verdict there survived the wider search. The redo did what the first vet skipped: it widened the surface before filing items (a) to (d) as #1429. Absence verdicts need this check whichever way it comes out.

## Related

- `docs/solutions/best-practices/verify-a-ledger-inferred-backlog-against-the-engines-state-surface.md`: the same discipline for counts inferred from ledger rows.
- `docs/solutions/best-practices/a-grepped-implementation-string-in-a-test-is-an-invisible-caller.md`: a caller that a single-spelling search misses, at the level of one rename.
- `docs/solutions/best-practices/transcript-corpus-detectors-count-the-review-itself.md`: how to read a transcript usage sample.
- `docs/solutions/best-practices/key-a-ci-candidate-pins-move-rule-to-every-surface-its-consumers-read.md`: consumers read more surfaces than one check covers.
- `docs/vets/2026-09-28-groundtruth-self-coordinating-agents-harness-vet.md`: the source incident and its corrections.
- `docs/ideation/2026-09-26-harness-throughput-and-ceremony-round-3-ideation.html`: the second instance (line 444).
- Issues: #1450 (open; its docs/solutions item withdrawn), #1429 (the round-3 orphans). PRs: #1451 (correction), #1454 (withdrawal).
