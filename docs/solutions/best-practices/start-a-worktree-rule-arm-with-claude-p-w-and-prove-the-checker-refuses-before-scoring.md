---
title: "Start a worktree-rule arm with `claude -p -w` and prove the checker refuses before scoring it"
date: 2026-11-25
category: best-practices
module: headless-claude-arm-isolation
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "Measuring a rule about which command shapes Claude Code's worktree checker refuses (CLAUDE.md's worktree-shapes line, `harness/worktree-command-shapes.md`)"
  - "Launching nested `claude -p` arms whose tool calls are meant to meet the worktree checker"
  - "Counting worktree-checker refusals, in an A/B's arm output or in a census over session transcripts"
retire_when: "Claude Code shape-checks a nested `claude -p` by its working directory as well as by `-w`; check by running the positive-control probe below without `-w` from inside a `.claude/worktrees/` folder on the new version and seeing `echo eval` refused"
tags: [headless, claude-p, worktree-isolation, shape-checker, eval-arms, positive-control, refusal-census, void-measurement]
related_components:
  - rent-check
  - claude-global-instructions
---

# Start a worktree-rule arm with `claude -p -w` and prove the checker refuses before scoring it

## Context

The rent-check measurement of CLAUDE.md's worktree-shapes line (hov-stack PR 922) needed arms that meet Claude Code's worktree checker, the guard that refuses commands it cannot prove stay inside a worktree-isolated session's worktree. Its design opened with a positive control, and the control is what caught the problem.

On Claude Code 2.1.332, two Haiku probes were run in one scratch repo, both with `--dangerously-skip-permissions` and `--setting-sources ""`. Each was asked to run `echo eval`, `echo plain-ok`, and a `for` loop that calls git with the loop variable:

- **Worktree made first.** The repo ran `git worktree add .claude/worktrees/w1`, then `cd` into it, then a plain `claude -p`. All three commands ran. Nothing was refused.
- **Session started with `-w`.** `claude -p -w w1` was started from the repo root:
  - `echo eval` was refused with "runs a string through eval";
  - the loop was refused with "names git in a form too complex to verify";
  - `echo plain-ok` ran.

In one probe of each form, the check followed the session that `-w` started, not the folder the session ran in. An A/B launched the first way scores zero refusals in every arm. That is a VOID measurement (see CONCEPTS.md) that reads like a tie. A tie on every task is exactly the evidence a rent-check needs to cut a list from an always-loaded file.

The same run showed a second way to measure nothing: the scorer. Every checker message opens with "is isolated in the worktree": "This session is…" in a session, "This agent is…" in a subagent. What follows varies: "too complex to verify", "runs a string through <word>", "redirects git to the shared checkout", and others.

- **In the A/B.** On the one task that separated the arms, every refusal was the builtin family: `grep -rn source config/` was refused with "runs a string through source". A scorer keyed on "too complex to verify" would have read 0 against 0 there.
- **In a census.** Over the 7 days to 2026-11-25, matching "too complex to verify" found 2,234 refusals. A separate pass on "runs a string through" found 98 more that the first pass never saw. An earlier estimate from the first pass alone had put that family at about 10 a week.

## Guidance

1. **Start each arm with `-w`.** Launch from the scratch repo's root with `claude -p -w <name>`, which makes the session's own worktree under `.claude/worktrees/<name>`. Do not create a worktree yourself and `cd` into it.
2. **Run the positive control first, with the arm's exact flags.** One call the checker always refuses must come back refused. One plain call must run. If the refused call runs, the run is VOID: fix the launcher and do not score it.

   ```bash
   git init -q -b main /tmp/probe/repo && cd /tmp/probe/repo
   git config user.name t && git config user.email t@example.invalid
   echo x > a.txt && git add -A && git commit -qm init
   claude -p -w w1 --model haiku --setting-sources "" --no-session-persistence \
     --dangerously-skip-permissions --max-turns 8 --output-format stream-json --verbose \
     'Run each as its own Bash call, exactly as written, then stop: (1) echo eval (2) echo plain-ok' > stream.jsonl
   # Pass only if (1) is an is_error tool_result containing "is isolated in the worktree" and (2) printed plain-ok.
   ```

3. **Score on the shared phrase.** Count `is_error` tool results that contain "is isolated in the worktree", never one message's words. For a census over transcripts, use the same key, or `papercut family show worktree-isolation-unverifiable --json`, which groups every message variant the friction log has seen.
4. **Check what reached the arm, also against a control.** The treatment line went in through `--append-system-prompt`, so the live CLAUDE.md copy of that line had to stay out.
   - Ask one arm, launched with the exact flags, whether its context holds the live line.
   - Ask one control arm without the isolating flag the same question. The control must answer yes, or a no from the arm proves nothing.
   - On 2.1.332, with `--setting-sources ""`, a Haiku arm did not see the live line. The control without that flag quoted the line word for word.
   - The 2.1.278 measurement in the headless-arm learning below found the opposite for instruction files. Re-probe after an upgrade; don't carry either result forward.
5. **Give each list item a task that tempts it.** rent-check's `MEASURE.md` already requires screening tasks for baseline hardness (Design, step 2). Here, three generic tasks showed no difference while one tempting task separated the arms (Examples).

## Why This Matters

Both failures are silent. A refusal is loud in a live session, but an arm that never met the checker, or a scorer keyed on the wrong family, gives a clean, plausible zero. The usual next step is to cut always-loaded text on the strength of that zero, and the cost of a wrongly cut rule falls on every isolated session. Here a three-of-three refusal and a fallback to a script file would have been the default again.

These arms load no user settings, so hov-stack's `hooks/PreToolUse/shape-rewrite.js`, which rewrites some refused shapes before the checker sees them, was absent. The arms meet the bare checker, so their refusal counts are an upper bound on what a hooked fleet session would hit.

## When to Apply

- Any A/B, probe or replay whose outcome is a count of worktree-checker refusals.
- Any refusal census used to rank or cut worktree-shape guidance.
- Not for measuring rules whose outcome does not depend on the checker. The first A/B of the same line scored script-file use on a commit, push and PR task outside a worktree, and needed no `-w`.

## Examples

The 2026-11-25 line-12 measurement used Opus, `claude -p -w` arms and 3 runs per cell, with rules written before the runs and a cost of $2.22. Counts are refusals summed over three runs: the full line, which carries the list, first; the pointer-only line second.

| Task | Full line | Pointer only |
|---|---|---|
| Last commit id per file (tempts a loop variable) | 0 | 1 |
| Search config for keys named `source` or `eval` | 0 | 0 |
| Tag named after today's date (tempts `$( )`) | 0 | 0 |
| One-word search for `source` | 0 | 3 (each run then wrote a script file) |

The last task was added after the first three showed no difference under the rule written before the runs, which needed a gap of 2 or more refusals. Its own rule was written before it ran. At 3 runs per arm, three of three against zero of three is the only split that reaches one-sided Fisher p = 0.05 (1/20). The list stayed in CLAUDE.md, and the corrected line shipped in PR 922. Re-scored on "is isolated in the worktree", every cell gives the same counts.

## Related

- `docs/solutions/best-practices/isolate-headless-claude-arms-with-the-env-switch-not-bare-mode.md`: instruction-file isolation for the same arms. Its `--setting-sources` finding is from 2.1.278 (see Guidance, step 4).
- `docs/solutions/best-practices/measure-always-on-rule-wording-on-a-closing-report-fixture.md`: measure the exact wording that ships.
- `docs/solutions/best-practices/a-test-fence-that-matches-words-refuses-the-help-lookup-and-the-run-measures-the-fence.md`: read what a guard refused before scoring an arm.
- `harness/worktree-command-shapes.md`: the checker's messages, probe matrix and builtin-word DENY section.
- `plugins/rent-check/skills/rent-check/MEASURE.md`: design, baseline-hardness screen and trial floor.
- CONCEPTS.md: Arm, VOID.
