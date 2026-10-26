# Research delegation: prompt template + query-count discipline

Habits for research handed to a subagent or run through
exa-cli/Firecrawl. (Adapted from davidondrej/skills research-prompt +
pi-web-search, MIT, vendor execution paths dropped; fan-out-sizing +
red-flag sections adapted 2026-08-11 from Anthropic's multi-agent research
prompts, claude-cookbooks `patterns/agents/prompts/`, MIT, product tool
contracts dropped.)

## Research-prompt template

One self-contained paragraph a researcher (subagent, deep-research tool,
or human) with zero prior context can act on with no back-and-forth:

> [1-2 plain-English sentences: what the project is, why it exists,
> current situation.] Research [TOPIC + identifying facts] to answer one
> question: [THE QUESTION] -- for [DECISION / END USE]. Find: (1)...;
> (2)...; (3)...; (4).... [Constraints: include X, avoid Y.] Prefer
> primary sources (official docs, GitHub, filings, changelogs); treat
> forums/X/Reddit as weak signal only. If sources conflict, separate fact
> from inference and flag what needs verification. Don't stop at the
> first plausible answer -- corroborate each key claim with multiple
> independent primary sources where they exist (say so explicitly where
> they don't), continuing until every numbered question is covered.
> Before finishing, self-critique: list gaps, contradictions,
> single-source claims, then run another round to close them. For each
> finding: source link + specific claim + one-line "why it matters."
> Output into a single markdown file [or: report back inline].

Rules: one paragraph, no bullet list in the deliverable itself; 3-6
numbered sub-questions, one mission per prompt; embed all context so the
researcher never has to ask; verifiable/citable facts only, no opinions.

An implementation brief (a worker that edits or runs things rather than
researches) uses the labeled worker-brief schema in `agent-swarm/SKILL.md`
instead: GOAL, CONTEXT, SCOPE, ACCEPTANCE, VERIFY, TIMEBOX, FORBIDDEN,
REPORT, STANDING, with TIMEBOX and FORBIDDEN never empty (dotfiles#1202).

## Sizing the fan-out

Classify the mission, then let the unit count size the dispatch — one
subagent per unit, no more; going past ~5 means the mission genuinely
contains that many independent units:

- **Straightforward** — one factual answer, a single good source settles
  it: one researcher, minimum-query tier from the table below.
- **Breadth-first** — the mission decomposes into independent
  sub-questions (compare X/Y/Z, survey a landscape): the unit is the
  sub-question; each brief carries a different sub-question.
- **Depth-first** — one question that must not be decomposed (is this
  library maintained? is this claim true?): the unit is the method or
  perspective; each brief carries the SAME question worked a different
  way (docs trawl, code read, maintainer-activity check).

More subagents than distinct units is spend, not thoroughness. Dispatch
independent subagents — and independent query batches within one
researcher — in parallel, never serially. The query minimums below are
per researcher; fan-out sizing is a separate axis, not a substitute.

## Source-quality red flags

Add these to the brief's "weak signal" clause. Treat as weak: news
aggregators over the outlets they aggregate; false authority (confident
prose, no named author or method); passive-voice claims with nameless
sources ("experts say"); marketing or spin language for a product;
speculation presented as fact; cherry-picked data with no denominator.

## Minimum query-count discipline

Hard minimums, independent of which tool executes the search
(`exa-cli search`, `firecrawl-cli search`) -- count queries before
synthesizing, don't stop short. Native `WebSearch` is not one of those tools
(see "Native WebSearch" below):

| Ask | Minimum queries |
|---|---|
| "web search" | 2, varied keywords/angles |
| "extensive web research" | 4, distinct keywords/angles |
| "deep research" | 8+, across 2-3 successive batches, refining angles each batch |

A batched multi-query call counts every query in the batch toward the
total. If the first batch is under the minimum, fire another batch before
synthesizing.

## Native WebSearch

Native `WebSearch` works through better-ccflare since better-ccflare#441
(deployed 2026-10-05, one live search confirmed that day): the search runs
natively on a first-party Anthropic account. It is a lane for one bounded
single-fact lookup with no attribution, comparison or discovery intent (the
"Web retrieval routing" table in `cc-mcp-architecture.md`). Research briefs,
and every query counted toward the minimums above, use `exa-cli` /
`firecrawl-cli`.

Only a Claude Code session the operator started may use it, in its main loop
or in a subagent it spawns. Scripted traffic must not reach Anthropic-backed
accounts (better-ccflare `AGENTS.md`). So anything a script, timer, cron job,
daemon or loop launches (headless `claude -p`, `claude-loop`,
`pro-review-daemon`) uses `exa-cli` / `firecrawl-cli`, and so does every
subagent such a run spawns, even when `WebSearch` is in its tool list.
Codex, non-Claude scripts, and lean-reader / lean-collector stages have no
`WebSearch`.

It returns a tool error in two cases:
- No first-party Anthropic account can serve it: a 400 when none is
  configured, a 503 when all are excluded.
- The session is pinned to an exact-account route profile. Soft capability
  profiles serve it since better-ccflare#447, deployed 2026-10-05.

On a `WebSearch` tool error, or on the per-session search-cap notice,
continue on `exa-cli search` and say so.
