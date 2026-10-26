---
title: "A response's summed usage over iterations is not its context size; count the last message iteration"
date: 2026-10-05
category: integration-issues
module: context-fence-token-accounting
problem_type: integration_issue
component: development_workflow
symptoms:
  - "An owner fix session at about 200k context read as 398,630, and the context fence hard-stopped it under a 300000 fence after 10 edits, before any test or commit (#1540's fix session)"
  - "On an advisor response, top-level `message.usage` equals the two main-model `message` iterations added together; the `advisor_message` iteration is not part of it"
  - "Fix sessions that called the advisor tripped the fence at about half its real size"
root_cause: wrong_api
resolution_type: code_fix
severity: high
related_components:
  - context-fence.js
  - compaction-profile.py
  - dispatcher-ratchets.md
tags: [usage-iterations, advisor, context-fence, token-accounting, transcript-usage, context-size, compaction]
---

# A response's summed usage over iterations is not its context size; count the last message iteration

> **Retired machinery (2026-10-18).** The context fence, `hooks/lib/context-fence.js` and its Stop handoff, was removed by dotfiles #1913 (teardown move 5), so the `context-fence.js:76-86` citation below no longer resolves and `related_components` names a deleted file. The lesson stands for every transcript reader: `scripts/compaction-profile.py` still counts the last message iteration, and a `usage` summed over iterations is still not the context size.

## Problem

The context fence measured a session's context as the top-level `message.usage` of its last assistant line: input, cache-creation and cache-read tokens added together. A response that runs a server-side tool such as the advisor reports that usage *summed over its main-model iterations*. Each of those iterations re-reads the same context, so one advisor call roughly doubles the reading. The fence then stopped fix sessions at about half the size it was set to allow (issue #1544, closed by PR #1550).

## Symptoms

- #1540's owner fix session was at about 200k context. It read as 398,630 and was hard-stopped under the 300000 fence after 10 edits, before any test or commit.
- That response's `usage.iterations`, per #1550's description (transcript `358d70bf`):

  | Iteration | input + cache_creation + cache_read |
  |---|---|
  | `message` | 32 + 502 + 197,732 = 198,266 |
  | `advisor_message` | 199,528 |
  | `message` | 2 + 2,128 + 198,234 = 200,364 |

  The top-level sum, 398,630, is exactly the two `message` iterations added together. The advisor's own iteration is not in it.

## What Didn't Work

- **Treating top-level usage as "one request's context".** The fence's formula was copied from `scripts/compaction-profile.py`, which profiles the CLI's own auto-compaction. For a plain response it is right, because that response carries one message iteration equal to its top-level usage. It goes wrong only when a server-side tool runs, so nothing flagged it until an advisor-using fixer was stopped.
- **Taking the last message iteration unconditionally.** An earlier revision of #1550 did this. A partial iteration then reads as too small a context: a missing counter counts as zero, and a negative, non-numeric or non-finite one distorts the sum. A fence that undercounts lets a session run past its limit. The incomplete-iteration checks in #1550 fail against that revision.

## Solution

When `usage.iterations` is present, count the last `type:"message"` iteration. Fall back to the top-level sum when there are no iterations, or when that iteration is empty or incomplete (`hooks/lib/context-fence.js:76-86`):

```js
function contextTokensOf(usage) {
  const iterations = Array.isArray(usage.iterations) ? usage.iterations : [];
  for (let i = iterations.length - 1; i >= 0; i -= 1) {
    const iteration = iterations[i];
    if (!iteration || iteration.type !== 'message') continue;
    const tokens = completeIteration(iteration) ? sumInputTokens(iteration) : 0;
    if (tokens) return tokens;
    break;
  }
  return sumInputTokens(usage);
}
```

`scripts/compaction-profile.py` applies the same rule (its docstring, lines 17-19), and `harness/dispatcher-ratchets.md` describes it.

## Why This Works

Each main-model iteration is one full read of the conversation so far. The last one is the model's final read, and so it is the context the next request starts from. The advisor iteration is a different model's read and is not part of this session's context. Summing iterations counts the same context once per iteration. That is correct for **billing**, because each iteration is billed input, but wrong for **size**.

The fallback keeps the fence safe in both directions:
- with no iterations, a plain response's count is unchanged;
- with an untrustworthy iteration, the fence overcounts rather than undercounts.

## Prevention

- **Decide what each reader of transcript usage is measuring.** #1550's description classifies the repository's usage readers, apart from experiment and vet-fixture scripts:
  - Context-size readers take the last message iteration: the fence and `compaction-profile.py`.
  - Billing and copied-metrics readers keep the sum, because advisor iterations are real billed input.
  - Readers of Claude Code's own `context_window` (the statusline) or of run-level `claude -p` usage do not read per-request transcript usage at all.

  Classify any new reader the same way.
- **Pin the counted value with a boundary test, using real numbers.** #1550's fixture is the real response above. The fence trips at exactly 200,364 and does not trip at 200,365, which proves the counted value is the last iteration rather than something else under the cap. The fixture also asserts its own precondition: the top-level sum really is 398,630 and really is over the fence.
- **When a fence must choose between under- and overcounting, overcount.** Fall back to the larger reading whenever the smaller one cannot be trusted.
- **A related pitfall in the same transcripts:** assistant lines are content blocks, and several lines of one request share a `message.id` and its usage. Totals over a transcript must dedupe by `message.id` (auto memory [claude]).

## Related Issues

- [The token bill is driven by session length and the compaction window, not CLAUDE.md size](../best-practices/token-bill-is-driven-by-session-length-and-compaction-not-claude-md-size.md): reads per-request context through `compaction-profile.py`, written before this rule.
- [Attribute a push by the tracking ref's reflog, not by HEAD ancestry](../logic-errors/attribute-a-push-by-the-tracking-refs-reflog-not-by-head-ancestry.md): how a fenced fix session's round is then judged.
- Issue #1544, closed by PR #1550.
