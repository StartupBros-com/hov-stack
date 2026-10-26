---
title: "The Agents View `@` picker only durably lists repos one level below its launch directory"
date: 2026-09-09
category: integration-issues
module: claude-harness-agents-view
problem_type: integration_issue
component: development_workflow
symptoms:
  - "Repos at `~/SITES/<repo>` silently drop out of the `claude agents` `@` picker every few days, with no error or warning"
  - "Workaround that keeps recurring: cd into the repo, run `claude agents` there, start one chat -- the repo becomes `@`-taggable again for a while, then vanishes again"
  - "The job store (`~/.claude/jobs/*/state.json`) held only 8 distinct cwds -- 6 of them SITES repos -- out of 73 repos on disk"
  - "None of the 73 `~/SITES` repos can satisfy the picker's non-recursive one-level-below-launch-cwd scan, because they sit two levels below `~` and `~/SITES` is not itself a git repo"
root_cause: config_error
resolution_type: tooling_addition
severity: high
framework_version: claude-code v2.1.263
related_components:
  - cad
  - claude-agents-view
  - claude-jobs-store
tags:
  - agents-view
  - at-picker
  - repo-discovery
  - job-store-ttl
  - cleanup-period-days
  - cad-function
  - silent-failure
---

# The Agents View `@` picker only durably lists repos one level below its launch directory

## Problem

Claude Code's Agents View (`claude agents`) has an `@` picker for choosing which repo to launch a new agent in. Repos under `~/SITES/<repo>` kept dropping out of it every few days. The habitual workaround was to open a terminal, `cd` into the repo, run `claude agents` from inside it, and start any chat — after which the repo was `@`-taggable again for a while, then silently vanished. Nobody had traced *why*, so each recurrence was re-solved by hand instead of fixed once.

## Symptoms

- A repo that obviously still exists is simply absent from the `@` picker, with no error, warning, or empty-state explanation.
- The absence is intermittent over time: present shortly after activity in that repo, gone after a quiet stretch.
- The `cd`-and-launch ritual reliably restores it, which makes the behavior read like a cache that needs warming.
- Measured at investigation time: the job store held 50 entries spanning only **8 distinct cwds**, of which **6** were SITES repos — against **73** git repos under `~/SITES`.

## What Didn't Work

Every candidate below was traced to code or measured on disk, not assumed, and each was ruled out:

- **`~/.claude.json`'s `projects` map** — the obvious "known projects" store, and the first suspect. Ruled out because it is durable: it held entries with `lastStartTime` values 60 days old and has no age-pruning path at all. A store that keeps 60-day-old entries cannot be what forgets a repo in days.
- **`githubRepoPaths`** (also in `~/.claude.json`) — a second directory index, and it *does* contain worktree paths, which made it look promising. Ruled out: no age-based pruning anywhere in its read/write path.
- **The session-registry PID reaper** — plausible on name alone. Ruled out twice over: it is liveness-based (dead-PID detection) rather than a day-scale TTL, *and* it is structurally disabled on WSL, which is the affected platform.
- **`agentLastUsed`** — ruled out as a pure sort comparator; it orders suggestions and never gates membership.
- **`FORMER_NAME_HINT_TTL_MS`** — a real TTL, which is why it surfaced, but it is 10 minutes and governs peer-session rename hints. Right shape, wrong domain and three orders of magnitude off.

The deeper mistake underneath all of these: they were searches for *what expires*, when the actual question was *what grants membership in the first place*.

## Solution

Launch Agents View from the SITES root rather than from `~`, so every repo qualifies structurally. dotfiles PR #1090 added an `--all` flag to the existing `cad` function in `.bashrc` (the function itself came from issue #658):

```
$ cad --dry-run --all
( builtin cd -P -- /home/user/SITES && .../direnv exec . claude agents --dangerously-skip-permissions )
```

`--all` reuses the function's existing target-resolution path — direnv detection, symlink resolution, `--dry-run`, `--cad-json` — rather than adding a parallel code path. The reasoning is recorded inline at the fix site, next to the `--all` case arm in `.bashrc`, so the next reader does not have to rediscover it.

Existing behavior is preserved by design and by test: bare `cad` still launches in the current directory, `cad <project>` still resolves under `~/SITES`, and `cad <project> --all` still forwards `--all` to `claude` like any other unrecognized flag (target-then-flag ordering means the target claims the arg-forwarding path first). `tests/cad-project-launch.test.sh` covers the new flag with assertions for the launch cwd, forwarded claude args, `--dry-run --all`, `--cad-help`, and three error paths (missing SITES root, `--all` combined with a target, repeated `--all`).

**Recorded trade-off:** launching from `~/SITES` makes `~/dotfiles` and `~/acme-intel` siblings of the launch directory rather than children, so they no longer qualify structurally from this launch mode and hold their slot only via the transient job-store source. `--all` is opt-in per invocation precisely so this is a choice rather than a silent global default.

## Why This Works

The picker's backing set is the union of exactly three sources. The official doc at `code.claude.com/docs/en/agent-view` lists all three — paraphrased below, not quoted in full — and binary analysis of Claude Code v2.1.263 located all three code paths, confirming there is no fourth.

1. **Git repos one level below the launch directory** — a non-recursive `readdir` + `.git` probe of direct children only.
2. **Worktrees of the repo you launched from**, that live inside its directory tree.
3. **Every entry in the job store** (`~/.claude/jobs/*/state.json`, keyed by `originCwd`), unfiltered by job state, so completed and terminal jobs count too.

Two further exclusions in that doc are easy to miss and each produces the same "it's just not there" symptom: worktrees added **outside** the repo's own directory tree are not listed, and **directory names containing a space are never listed at all**. Check both before concluding a directory should have qualified.

Launched from `~`, sources 1 and 2 are **structural dead ends** for `~/SITES/<repo>`: source 1 would require `~/SITES` itself to be a git repo (it is not, so the repos sit two levels down), and source 2 would require `~` to be a repo (it is not). Only source 3 ever reached them — and source 3 is transient, swept on a `cleanupPeriodDays`-derived cutoff whose default is 30 days.

That is the entire mechanism: the `cd`-and-launch ritual was unknowingly re-seeding the one temporary source, which is exactly why it worked and exactly why it decayed. Moving the launch directory to `~/SITES` makes all 73 repos permanent children under source 1, so membership no longer depends on retention at all.

**Open gap, stated rather than guessed:** terminal jobs clear sooner than the nominal 30 days. `~/.claude/tasks/` and `~/.claude/session-env/` both showed oldest surviving entries at 29.98d and 29.99d, confirming the ~30-day sweep fires as designed — but the oldest surviving *terminal* job was 13.6 days, while state-less job directories (which the sweep explicitly skips) reached 18.9 days. This session confirmed the effect and did not isolate the shorter path. Issue #396 covers adjacent retention drift in the transcript store. The gap does not affect this fix, which removes the dependence on job entries entirely.

The binary offsets behind these claims are version-pinned artifacts of reverse-engineering a 215MB Bun-compiled binary at v2.1.263. They will drift across CLI versions and are **not** a stable API — they are recorded as evidence the mechanism was traced rather than guessed, not as something to code against.

## Prevention

When a tool surface silently forgets an entry — a picker, autocomplete set, recently-used list, or `@`-mention target set — enumerate its **membership rule** before treating the behavior as a cache or staleness bug:

1. **Find what defines membership, not just what reproduces the symptom.** Start with official docs before reaching for a binary or source read; here one sentence of documentation named all three sources.
2. **For each source, ask whether your layout can *ever* satisfy it — structurally, not just currently.** No amount of retrying, re-launching, or "priming" changes a structural non-match.
3. **Identify which source is actually carrying the item, and whether it is durable or transient.** An item held only by a transient source will always look like a flaky cache.
4. **Fix the structural mismatch, not the transient symptom.** If the proposed fix is "do the workaround, but on a schedule," the real fix has not been found yet — that is a manual cron job disguised as a resolution.
5. **Check for a second, independent cause before declaring it fixed.** Membership and search are different gates: this picker also matches **prefix-only**, so `@ja` finds `java-eth` while nothing finds `eth-java`. Both produce the identical "I typed it and nothing showed up" report.

Not every list-membership bug is structural — some genuinely are stale caches. The distinguishing test is whether the durable sources can ever match your case; if none can, retention is not the primary problem even when it looks like one.

## Related Issues

- dotfiles PR #1090 — added `cad --all` (the fix documented here).
- dotfiles issue #658 — created the `cad` named-repo launcher this flag extends.
- dotfiles issue #396 — transcript-store retention drift; adjacent to the unresolved sub-30-day job clearing noted above.
- `anthropics/claude-code#79456` — the `@` picker matches prefix-only, not substring.
- `anthropics/claude-code#87779` — open request to add a project folder without relaunching Claude Code in it.
- `anthropics/claude-code#90098` — open request for persistent cwd filtering in the Agents view.
- Related practice: [Diagnose against installed versions, not plugin caches](../best-practices/diagnose-against-installed-versions-not-plugin-caches.md) — the same instinct (name the live mechanism before diagnosing decay) applied to plugin routing.
