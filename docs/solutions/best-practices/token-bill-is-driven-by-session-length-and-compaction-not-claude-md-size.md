---
title: "The token bill is driven by session length and the compaction window, not CLAUDE.md size"
date: "2026-09-23"
last_updated: "2026-10-15"
category: best-practices
module: harness-context-budget-measurement
problem_type: best_practice
component: development_workflow
severity: medium
applies_when:
  - "Deciding what to cut when asked to reduce Claude Code token spend or cost"
  - "About to shrink or reorganize CLAUDE.md, a memory index, or always-on instructions in the name of cost"
  - "Reading a percentage or token figure from a prior efficiency measurement and treating it as still current"
  - "Choosing whether a fix targets always-on context size vs session length or the compaction window"
  - "Changing, rolling out or reverting `autoCompactWindow` (global, per-model or the environment override)"
tags:
  - token-budget
  - compaction-window
  - compaction-floor
  - session-length
  - claude-loop
  - message-id-dedupe
  - transcript-mining
  - context-budget
---

# The token bill is driven by session length and the compaction window, not CLAUDE.md size

## Context

A 2026-09-20 measurement of 14 days of this repo's Claude Code transcripts (dotfiles
PR #1255) went looking for "where is the token bloat" and found the intuitive
answer wrong. CLAUDE.md plus the memory index measured about 18.8k tokens per
request, but came to under 1% of the total token bill, because the system
prompt prefix is cached and Anthropic's prompt caching only bills the
uncached delta on a cache hit. The bill instead concentrated in sessions that
ran long: sessions over roughly 1,000 turns were about 90% of total spend, at
a per-request context cost 30-40% higher than short sessions, because a long
session keeps re-sending an ever-larger transcript prefix as context on every
turn.

A second, related measurement on the same corpus found live settings had no
`autoCompactWindow` configured, so the CLI's own default (roughly 967k tokens
on a 1M-context model) applied: auto-compaction fired at a median context of
about 901k tokens (p90 999k). Shipping `CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000`
in `bin/claude-loop.sh` (the line is still there today, defaulted with
`${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-300000}`) moved the median compaction
trigger down substantially in later re-measurements for loop-launched
sessions only; the 14 days to 2026-10-05 still showed 1,110 typed `/compact`
against 35 auto-compactions fleet-wide. Dotfiles PR #1577 (2026-10-05)
added the same 300k window through `modelSettings.<model>.autoCompactWindow`
for four named models, not every model ID. `sync.sh` reconciles those
canonical per-model windows into the live file, with the env var retained as
the loop's per-launch override. Issue #1591 tracked whether those settings
were honored and closed on 2026-10-14 with the probe evidence below;
the configuration alone was not runtime evidence.

PR #1716, merged on
2026-10-10 UTC, added the native top-level `autoCompactWindow=300000` fallback
for model IDs without a per-model window, including gateway aliases. Native
model limits and settings precedence still apply: the environment override
outranks settings, and a per-model window takes precedence over the global
fallback. Existing valid live global windows survive reconciliation; absent
or null globals adopt the canonical default. No global environment override
was added. The ownership and runtime-evidence contract is recorded in
[`HARNESS.md`](../../../HARNESS.md#config-surfaces).

Issue #1715's acceptance
records an actual automatic boundary during real work, from 433,387 to
41,926 tokens, followed by a distinct API input of 85,385 tokens. That proves
compaction in the observed session, not an exact 267k trigger, causality from
the fallback alone, coverage of every alias or a measured reduction in the
fleet's bill. Re-run the cost measurement before assigning savings to this
rollout. The lever remains how long a session runs before it compacts or
ends, not the size of the context loaded and cached identically on every turn.

Issue #1591's closing probe
records headless `claude -p "/context"` runs on Claude Code 2.1.299 on
2026-10-14: Opus reported a 300k window from settings and 200k with an explicit
environment override; Sonnet and Haiku reported 300k, with Haiku exercising
the global fallback rather than a per-model entry. These are applied-window
reports on the tested host/version, not observed compactions. A headless run
using the subagent model does not by itself prove inheritance in a spawned
subagent. The reported 33k autocompact buffer helps explain why the
October 13 census
observed main-session automatic boundaries near 268k rather than exactly
300k. Its before/after cohorts describe different populations and durations;
they do not establish causal savings or resolve the missing loop and
compaction-attribution countermetrics.

On 2026-10-15 the window was briefly lowered instead.
PR #1831 proposed
200k with issue #1830
to measure it for a week. It was pitched on a count of 217 manual
compactions that had counted quoted mentions; the local transcripts for
October 8-15 held 27 in 14 sessions, and those did not support it (see
Examples). It also never reconciled with the round-6 throughput ideation,
which had already measured and rejected a 200k window (see Related). The value
reached the live `~/.claude/settings.json` (top level and the four per-model
entries) from 19:12:52 to 19:26:14 UTC, about 13 minutes, before it was
reverted; the PR closed unmerged and the issue closed the same evening. On
Claude Code 2.1.301 on one host, the local transcripts show the window being
read when a process starts or resumes, in both directions:

- Two Opus 5.5 sessions resumed at 19:24, while 200k was live, kept
  compacting automatically at 167k-181k long after the revert. One compacted
  three times in about two minutes, twice (19:32-19:34 and 19:47-19:49 UTC),
  and Claude Code reported "Autocompact is thrashing: the context refilled
  to the limit within 3 turns of the previous compact, 3 times in a row."
  The other compacted every 3-5 minutes and was still doing so at 20:13,
  47 minutes after the revert.
- Three sessions whose processes started before the change kept compacting
  near 268k (19:17-19:23 UTC) while 200k was live, and stayed there after the
  revert. A fourth session compacted at 167,770 during the window but its
  start or resume time could not be recovered, so it is left out.

The opposite case is not settled. After PR #1716 set the fallback on
October 10, a session that was already running compacted from 433,387
tokens without a restart (the #1715 observation above), and #1715 itself says
that does not establish causality from the fallback. Whether a running
session picks up a window that was previously unset remains unproven.

A separate defect compounds any measurement here: the two historical mining
scripts originally counted raw JSONL records, not requests. Claude Code
writes one JSONL record per assistant *content block*, and a single request
commonly emits several blocks (thinking, tool calls, text). The measured
inflation was roughly 2.44x in the #1313 corpus, not a universal correction
factor. That fix deduplicated by `message.id`; remeasure other corpora rather
than dividing their raw totals by the historical ratio.

## Guidance

When asked to cut Claude Code token spend, or reviewing a claim about where
the spend goes, measure before acting rather than reasoning from the
intuition that a large CLAUDE.md or memory index is the cost driver:

1. **Choose the profiler mode for the question; don't trust old percentages.**
   `compaction-profile.py` has two modes. For the historical long-session
   floor report, use positional `[DAYS] [MIN_REQUESTS]` (defaults 14 and 1000):

   ```bash
   python3 scripts/compaction-profile.py 14 1000
   ```

   This selects main-session files by modification time and includes their
   records; it is not a half-open event-time census. The minimum-request
   floor excludes short sessions. Its marker-adjacent context report is not
   limited to native automatic boundaries; the separate automatic-floor
   composition rows are. Summary tokens are a chars/4 estimate, and a resumed
   session's first request may overstate its fixed prefix.

   For rollout comparisons, use the event-time JSON census added by
   PR #1758. This
   example uses the three ranges reported in the October 13 census:

   ```bash
   python3 scripts/compaction-profile.py \
     --since 2026-09-21T13:56:32Z --until 2026-10-13T04:00:00Z \
     --split-at 2026-10-05T13:56:32Z --split-at 2026-10-10T00:42:32Z
   ```

   Times require an explicit timezone; intervals include their start and
   exclude their end. This mode includes main sessions and subagents, has
   no request-count floor, and ignores file modification time. It retains
   the earliest observation of each activity identity across relocated
   copies before resolving per-session chronology. Equal timestamps have a
   deterministic tie order, not proof of the real order of simultaneous
   events. The event range is fixed, not the filesystem: inspect the quality
   counts for malformed, untimed and unreadable input before interpreting
   totals. Both modes default to retained local transcripts under
   `~/.claude/projects`; neither measures the monetary bill.

   `transcript-mine.py` was retired on 2026-09-29 (dotfiles#1429), not a
   second current command to run. For historical investigation,
   `git log --diff-filter=D --format=%h -- scripts/transcript-mine.py`
   names its deleting commit, and
   `git show <that commit>^:scripts/transcript-mine.py` prints it.

2. **Attribute cost to session length and the compaction window first.**
   The event-time census separates native automatic `preTokens`/`postTokens`
   from the context of the next measured request. A second boundary or the
   census's `--until` endpoint can leave that next-request observation unavailable.
   Resolve the environment window, per-model window and top-level
   `autoCompactWindow` fallback before
   attributing a session's behavior to the CLI default. When all three are
   unset, native model limits and controls determine that default; on a
   1M-context model, a high window can let a long session climb toward near-1M
   context before compaction. The shipped global fallback covers otherwise
   unset model IDs, but a saved window is not proof that compaction engaged.
   `transcript-mine.py`, retired in dotfiles#1429
   (step 1 says how to restore it), reported per-request context cost broken
   out by session length band; look at whether cost per request rises with
   turn count before looking anywhere else.

3. **Do not treat cached always-on context as the lever.** CLAUDE.md, the
   memory index, and any other content that is identical across a session's
   requests is cache-eligible; a healthy cache-read ratio (check
   `~/.config/better-ccflare/better-ccflare.db` if it exists — gateway
   request logs are ground truth for token totals, independent of any
   transcript miner) means that content is close to free on every request
   after the first. Shrinking it saves at most the small uncached fraction,
   not the bulk of the bill.

4. **When you find a bloated-looking number, check whether it is a record
   count or a request count** before citing it. A miner or ad hoc `wc -l`
   over `*.jsonl` counts content-block records; only `message.id`-deduped
   counts are requests. If you write a new transcript-mining script for a
   related question, dedupe by session and `message.id` from the start.
   For context rather than billing, use the last complete main-model usage
   iteration, with the profiler's top-level fallback when it is incomplete;
   summed server-tool iterations are not one request's context. See the
   [iterations learning](../integration-issues/a-responses-summed-usage-iterations-is-not-its-context-size.md).

5. **Read cohort rates with their denominators and unknowns.** Sessions are
   distinct within each cohort; active session-days are distinct UTC
   session/date pairs, not elapsed days. Eligibility uses measured request
   context or native boundary `preTokens` reaching 300k in that population.
   The auto rate divides automatic boundaries in eligible sessions by
   eligible sessions, not by only the sessions that compacted. Retain all-auto
   totals too: the October 13 named-model strata had automatic boundaries
   below 300k but no eligible sessions, so their eligibility rate was null,
   not evidence that the window failed. Keep main/subagent and requested-model
   strata separate; response labels are not verified routing, and entrypoint
   metadata alone does not establish headless inheritance.

   Requests require measured positive context. Interruption IDs are counted
   separately even when usage is absent or zero or the request was already
   seen. They are all-cause observations, not evidence that compaction cut a
   turn short. The profiler leaves compaction-caused interruptions, loop
   fence stops and handoff rotations null; obtain those from operational
   evidence rather than converting unavailable counters to zero. The posted
   census lacks true loop-session-day denominators, handoff-rotation records
   and identifiers joining compaction to interrupted turns. Its known
   incomplete filesystem coverage also prevents treating it as a full fleet
   census; later runs over the same dates may differ as retained files change.

6. **Change the window only on per-model measurement, and roll it out to
   running sessions on purpose.** Say where any proposed value comes from.
   Re-run the floor report from step 1 for the models it will apply to, and
   check the earlier rejections in both directions (Related) before proposing
   one. Too low is as costly as too high:

   - The automatic trigger sits about 33k below the window: 300k fires near
     267k-268k, and 200k fired at 167k-181k on October 15.
   - The compact summary itself is small (`postTokens` of 22k-36k in the
     two resumed sessions' boundaries), but the first request after a
     compaction also carries the cached system and tool prefix (median about
     75k in round 6) and a remainder round 6 did not break down. Round 6 put the context a long session returns to
     after an automatic compaction at a median of about 137k-142k.
   - A 300k window therefore leaves about 125k-130k of working room between that
     floor and the trigger; a 200k window leaves about 25k-30k. Round 6
     estimated 2.7 times more compactions at 200k by measuring room from the
     window rather than the trigger; from the trigger the ratio is closer to
     four or five. Each extra compaction spends a summarization request and
     starts the cached conversation over, and when the context refills within
     three turns three times in a row, Claude Code reports the thrashing
     error quoted in Context. How soon a session hits it depends on how much
     it re-reads, so this is a range, not a fixed rule.

   On Claude Code 2.1.301 on one host, a settings edit did not reach
   sessions that were already running (see Context); plan for that until a
   newer version is observed to behave otherwise. After changing the window, list the Claude processes that
   started before the edit with `ps -eo pid,lstart,args`, and in each run
   `/autocompact` or restart it. On October 15, `/autocompact` with no
   argument printed `Auto-compact window for Opus 5.5 set to 300k tokens`,
   and the session's next automatic compaction came at 267,790 instead of
   about 170k. Because the default and the live setting were both 300k, that
   run did not show which of the two it applied.
   To find sessions still on an old value, look for automatic
   `compact_boundary` records whose `preTokens` sit well away from the
   trigger the current window implies: below it after a raise or a revert
   upward, above it after a cut.

## Why This Matters

Cutting CLAUDE.md or memory-index size in the name of cost trades a real,
concrete capability (instructions and vocabulary the agent needs) for a
token saving that is mostly illusory, because that content was cached and
barely billed to begin with. The actual cost driver — session length driving
up per-request context, and a compaction window that lets that growth run
too long before cutting it back — survives the CLAUDE.md diet untouched, so
the bill does not move and the next person re-derives the same wrong
hypothesis. Fixing the real lever (bounding session length, setting the
compaction window from per-model measurement) addresses sessions across the
whole fleet at once rather than trimming one file. The window cuts both ways:
set close to the post-compaction floor, it makes sessions compact every few
turns instead of saving anything, and a running session keeps whatever value
it started with until someone tells it otherwise.

The record-vs-request bug is the same shape of mistake one level down:
without request-level deduplication, raw transcript totals can be inflated
by a corpus-dependent, non-obvious factor, and look authoritative because
they are specific numbers.

## When to Apply

- Before any change proposed to reduce Claude Code cost or context usage —
  measure compaction with the appropriate profiler mode and cost separately,
  rather than assuming the fix is "make CLAUDE.md smaller."
- When citing a token or percentage figure from a prior measurement (in a
  memory note, an issue, a PR description) — re-run the measurement rather
  than repeating the frozen number, since both the fleet's usage pattern and
  the settings (like the compaction window) change over time.
- When writing or reviewing a new transcript-mining script — dedupe by
  session and `message.id`, matching the event-time profiler, rather than
  counting raw JSONL lines.
- Before changing, rolling out or reverting `autoCompactWindow` — measure
  the floor per model first (step 6), and plan how sessions that are already
  running will pick up the new value.
- Not a substitute for inspecting a specific session that seems unusually
  expensive; aggregate profiles do not diagnose its tool-call pattern.

## Examples

**Wrong instinct:** "CLAUDE.md is 24KB, let's cut it in half to save tokens."
Measured effect (2026-09-20 baseline): CLAUDE.md + memory index at ~18.8k
tokens/request was under 1% of the 14-day token bill, because it is cached;
halving it would save well under 0.5% of spend while removing instructions
agents rely on.

**Right instinct:** "Which sessions are actually expensive?" Measured effect:
sessions over roughly 1,000 turns were ~90% of the 14-day bill at a
meaningfully higher per-request context cost than short sessions, and a
too-high compaction window meant those sessions climbed to near-1M context
before ever cutting back. Setting `CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000`
for `claude-loop`-launched sessions lowered where compaction fires there, and
PR #1577 added per-model windows for four named models. PR #1716 added the
native global fallback for model IDs without a per-model window while
preserving intentional overrides. Re-run `compaction-profile.py` to measure
the current trigger distribution; it does not calculate monetary cost. Measure
the bill separately before assigning fleet-wide savings to a configured
window or one successful compaction.

**Too-low window (2026-10-15):** "Agents keep needing a manual `/compact`, so
compact sooner: drop the window to 200k." The manual compactions did not
support it. Of the 27 in the local transcripts for October 8-15, all 11 at or
above 300k were October 8-9 sessions on GPT-family models through the
gateway, before PR #1716's fallback existed, and five more on October 9
were below 300k. The 11 after it (October 11-14)
were at 178k-264k except one of 4.6k, almost all in sessions that had already
compacted automatically near 268k; one October 11 session had been
compacting automatically near 169k, for reasons not traced. Compactions
below the trigger in sessions where the trigger already works are elective,
typically at a task boundary, and a lower window would not have removed
them. The change it did make was the thrashing described in Context. These
counts come from a one-off local script over retained transcripts; re-run
the profiler rather than cite them.

**Record-vs-request trap:** a raw `grep -c` over a day of `*.jsonl` files
counts every assistant content-block record. In the #1313 corpus, request
counts were roughly 2.44x lower after deduplication; another day's multiplier
may differ. A total that does not say how it deduplicated is not established
as a request count.

## Related

- `scripts/compaction-profile.py` — re-run it rather than citing frozen
  numbers; its docstring carries its own most recent re-baseline.
  `scripts/transcript-mine.py` was retired in dotfiles#1429; step 1 says
  how to restore it.
- `bin/claude-loop.sh` — sets
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-300000}"`
  for launcher-started sessions. That per-launch override outranks the four
  canonical per-model windows from PR #1577 and the native global fallback
  from PR #1716; caller overrides and disable controls still apply.
- `settings.json` and `sync.sh` — canonical per-model windows
  plus the top-level fallback, with valid live global and live-only per-model
  overrides preserved. Installation tests do not establish runtime compaction.
- dotfiles PR #1577 and issue #1591 — the per-model window, the posted
  event-time census and the October 14 headless applied-window/override probe
  that closed acceptance. PR #1758 shipped the census implementation.
- dotfiles PR #1831 and issue #1830 — the 200k proposal of 2026-10-15, its
  recount of manual compactions and the close comments; both closed, the PR
  unmerged.
- `docs/ideation/2026-10-12-harness-throughput-and-ceremony-round-6-ideation.html`
  — idea 9, "Interactive sessions get a 200k window", refuted on the measured
  floor, with the trigger, floor and prefix medians step 6 uses.
- `docs/ideation/2026-10-14-harness-throughput-and-ceremony-round-7-ideation.html`
  — rejected the opposite move, deriving a window of about 435k from the floor
  plus a working budget, because the floor inputs were never verified.
- `tests/test_compaction_cohorts.py` — synthetic regressions for event
  boundaries, partial relocation, timestamp order and missing-usage
  interruptions; not proof of live coverage or runtime inheritance.
- dotfiles issue #1313 — the message-id dedupe fix for both scripts (records
  vs requests, ~2.44x inflation).
- dotfiles PR #1255 — the 2026-09-20 measurement that established CLAUDE.md's
  cached, sub-1% share of the bill.
