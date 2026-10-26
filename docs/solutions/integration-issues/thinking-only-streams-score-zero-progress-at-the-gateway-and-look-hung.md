---
title: Thinking-only streams score zero progress at the gateway and long-thinking Claude Code sessions look hung
date: 2026-09-20
category: integration-issues
module: claude-harness-ccflare-thinking-timeout
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A heavy-thinking subagent at xhigh or max effort looks hung for hours; --debug-file shows one [API REQUEST] then only [Stall] stream_idle_partial lines with bytesTotal climbing by 38 bytes every ~25 s, and the subagent transcript stops at its last tool_result"
  - "After ~480 s the client logs api_error No compatible account route committed before the recovery deadline, then issues a fresh request; CLAUDE_CODE_MAX_RETRIES=20 turns that into a multi-hour loop"
  - "The gateway journal carries WARN anthropic_precommit_stall with reason meaningful_progress_timeout and counts like framesSeen=374, structural=373, meaningful=0"
  - "Passing --settings with a thinkingDisplay key, or --forward-subagent-text, changes nothing; only the --thinking-display CLI flag reaches the launch-time display decision"
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - better-ccflare
  - anthropic-sse-frame-classifier
  - claude-loop
  - loop-quality-sessions
  - claude-code-cli
tags: [thinking-display, ccflare, meaningful-progress-timeout, thinking-delta, sse-frame-classifier, subagent, claude-code-cli, silent-failure]
---

# Thinking-only streams score zero progress at the gateway and long-thinking Claude Code sessions look hung

> **Retired machinery (2026-10-18).** The loop_quality pipeline was removed by #1916 and the always-on dispatcher by #1873 (teardown 2026-10-17/18), so `scripts/lib/loop_quality/sessions.py`, `THINKING_DISPLAY_ARGS` and `tests/loop-quality-sessions.test.sh` no longer resolve, and the dispatcher is no longer a launch path. `bin/claude-loop.sh` still passes `--thinking-display summarized` and `settings.json` still sets `showThinkingSummaries`; their line numbers below were re-checked on 2026-10-18, and the loop_quality references below are kept as history. The lesson still holds for any headless `claude -p` launcher: pass the literal CLI flag.

## Problem

Claude Code headless (`claude -p`) sessions default `thinking.display` to "omitted", and interactive sessions do the same unless `showThinkingSummaries` is set, so the upstream API streams `thinking_delta` frames with an empty `thinking` string during long reasoning phases. better-ccflare's SSE classifier treats an empty-text `thinking_delta` as "structural", not "meaningful" progress, so any step that thinks past the gateway's meaningful-progress deadline is aborted, retried on the next pooled account from zero, and, amplified by `CLAUDE_CODE_MAX_RETRIES=20`, can hang silently for hours with no error output.

Paths under `packages/proxy/src/` and `scripts/deploy-ccflare.sh` below live in the better-ccflare repository (StartupBros/hov-router); every other path is in dotfiles.

## Symptoms

- Client side: `claude -p` produces no output and no error for an unexpectedly long time (observed: multi-hour hangs); when it finally exits it does so only after exhausting client-side retries, never with a clear timeout message.
- Debug-file shape (`claude -p ... --debug-file <path>`): one `[API REQUEST] /v1/messages`, then only `[Stall] stream_idle_partial ... bytesTotal=38,76,114...` lines (38-byte keepalive pings every ~25 s), then after ~480 s `[ERROR] Error streaming, falling back to non-streaming mode: {"type":"api_error","message":"No compatible account route committed before the recovery deadline"}` and a fresh `[API REQUEST]`. The subagent transcript stops at its last `tool_result` and `subagent_stats.completed` stays 0.
- Stream-json shape (`experiments/lean-reader-2026-09-19/diag-stream.sh`): long stretches with no `TEXT` or `TOOL_USE` lines for the active subagent, meaning frames are arriving upstream but none register as progress.
- Reproduced frame counts (`experiments/lean-reader-2026-09-19/RESULTS.md`): headless runs at xhigh and high effort buffered 374 and 340 `thinking_delta` frames respectively with zero classified meaningful.
- Gateway journal shape (`journalctl -u ccflare-stack.service`, or `ccflare-precommit.py <since> <until>` from the same experiment directory): a WARN `[ProxyOperations] anthropic_precommit_stall` record with `reason: "meaningful_progress_timeout"`, `framesSeen=374, structural=373, meaningful=0`, `semanticTimeoutMs=420000`. That reason is distinct from the separate, resetting `semantic_timeout` reason; both are enumerated in `AnthropicPreCommitStallReason` (`packages/proxy/src/anthropic-semantic-preflight.ts:200-208`).
- Proxy event rows (`ccflare-journal.py <since> <until>`): elapsed climbing toward the meaningful-progress ceiling, an aborting outcome, then a fresh row for the next pooled account repeating the climb, up to `CLAUDE_CODE_MAX_RETRIES` times. The provenance endpoint (`ccflare-provenance.py <session-id>`) shows requested, applied and upstream model all equal: no model rewrite is involved.
- better-ccflare issue #356 (cited in `packages/proxy/src/anthropic-precommit-rescue.ts:25-35`) recorded the concrete pre-fix failure: 374 frames, 0 meaningful, aborted at 480,070 ms, an 8-minute budget aborting a legitimate long non-interactive thinking phase.

## What Didn't Work

- Claimed interactive reproduction, retracted. An early draft of `RESULTS.md` asserted the stall also reproduced in an interactive session. It did not: the interactive control run was stopped after four minutes and showed only `client_aborted` in the gateway journal, no stall record at all. `RESULTS.md` now states that an interactive reproduction is not established. Interactive sessions are exposed by the same mechanism (their display is "summarized" only when `showThinkingSummaries` is true), but the exposure was reasoned from the bundle, not reproduced.
- `--forward-subagent-text` and `--settings '{"thinkingDisplay":"summarized"}'`, presented as fixes then withdrawn. Two high-effort judge runs using these flags completed without stalling and were initially read as proof the flags kept thinking visible (dotfiles PR #1224 records the retraction). They had finished inside the 450 s window by variance: a same-day direct probe with thinking forced on (`MAX_THINKING_TOKENS=4000`, raw partial-message streaming) showed both flags produce the same empty `thinking_delta` frames as passing no flag at all. Only the undocumented `--thinking-display summarized` CLI flag produced text-bearing deltas (27 of 27), because only the CLI flag reaches the launch-time display decision; a `--settings thinkingDisplay` key does not (Claude Code 2.1.277; comments at `bin/claude-loop.sh:609-618` and, until #1916 removed it, `scripts/lib/loop_quality/sessions.py:41-45`).
- Pinning `--effort medium` avoided the stall but degraded the task, and `high` alone overran the window (340 empty frames, 52 KB buffered). Effort is not the lever.
- Treating the two gateway deadlines as one. Early analysis conflated the meaningful-progress deadline with the protocol-idle (semantic) deadline. They are distinct: `protocolIdleDeadline` resets on every valid protocol frame including pings (`packages/proxy/src/anthropic-semantic-preflight.ts:636-638`), while `meaningfulProgressDeadline` is computed once at request start and never resets (`packages/proxy/src/anthropic-semantic-preflight.ts:673-689`). A fix aimed at "keep the connection alive" via pings would not have helped; only a frame classified meaningful, or a larger budget, extends the deadline that matters here.

## Solution

Three fixes, each closing a different launch path:

1. better-ccflare PR #357 raises the Claude Code pre-commit rescue commitment budget from 8 to 14 minutes (maximum 15), so a legitimate long thinking phase has room to finish even when every delta is empty. This is the backstop for clients that pass neither switch below:

```typescript
// packages/proxy/src/anthropic-precommit-rescue.ts:36-37
export const CLAUDE_CODE_PRECOMMIT_RESCUE_COMMITMENT_DEADLINE_MS = 14 * 60 * 1000;
```

14 minutes leaves 60 s of headroom under the 900 s client `API_TIMEOUT_MS` (`settings.json`, `env.API_TIMEOUT_MS: "900000"`) while clearing the 480,070 ms abort observed in issue #356. Deployed 2026-09-20 via `scripts/deploy-ccflare.sh`; verified by production `proxy_response` records completing at 557 s and 793 s elapsed, past the old deadline. Trade-off: ping-only content-dead streams now fail over at about 810 s instead of about 450 s; true silence still fails at 420 s through the protocol-idle deadline.

2. dotfiles PR #1226 (issue #1225) makes every headless launch path request text-bearing thinking deltas, which is the root-cause fix for dispatched runs. Before: no explicit display flag (or the withdrawn `--forward-subagent-text` and `--settings thinkingDisplay` attempts, both no-ops for this purpose). After, in both headless call sites of the time (only `claude-loop.sh` remains since #1916 removed loop_quality):

```
bin/claude-loop.sh:620-626 (abridged)
env -u ANTHROPIC_API_KEY claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --max-budget-usd "$MAX_USD" \
  --thinking-display summarized \
  --disallowedTools "Bash(git push --force:*),Bash(gh pr merge:*)" \
  2>&1 | tee -a "$LOG"
```

```python
# scripts/lib/loop_quality/sessions.py:46 (removed by #1916)
THINKING_DISPLAY_ARGS = ("--thinking-display", "summarized")
# used in SessionRuntime.build_argv, sessions.py:567-581
argv += [
    "--model", model,
    "--permission-mode", "bypassPermissions",
    "--max-budget-usd", max_budget_usd,
    "--disallowedTools", disallowed_tools,
    *THINKING_DISPLAY_ARGS,
]
```

The flag propagates to subagents spawned inside that run (their transcripts then store thinking text).

3. dotfiles PR #1246 sets `showThinkingSummaries: true`, the only setting that makes an interactive session's display "summarized"; the CLI flag never reaches interactive sessions and the setting never reaches `claude -p`, so both are needed:

```json
// settings.json:909
"showThinkingSummaries": true,
```

## Why This Works

Root cause: the upstream API emits non-empty `thinking` text in `thinking_delta` events only when the client's requested display mode calls for it (measured, not documented: "summarized" yielded 27 of 27 deltas with text, "omitted" yielded none). Headless `claude -p` defaults that mode to "omitted", so the API streams delta events with an empty `thinking` string (signature-only). better-ccflare's classifier codes exactly that case as structural, not meaningful:

```typescript
// packages/proxy/src/anthropic-sse-frame-classifier.ts:136-140
case "thinking_delta":
    return typeof parsed.delta.thinking === "string" &&
        parsed.delta.thinking.length > 0
        ? "meaningful"
        : "structural";
```

Because `meaningfulProgressDeadline` is an absolute deadline set once at request start and never reset by structural or ping activity (`anthropic-semantic-preflight.ts:673-689`), a step that only ever produces structural thinking frames looks identical, to the gate, to a step producing no output at all. It is aborted, handed to the next pooled account under the `pool-exhaustion-finite-recovery-v1` policy (auto memory [claude]), and retried by the client, turning one long-thinking step into up to 20 repeated aborts (the retry count configured in `settings.json` env; the CLI's own cap is not sourceable here), each restarting the thinking from zero.

- Fix 2 addresses the root cause for dispatched runs: `--thinking-display summarized` is the only launch-time switch that makes the CLI request a mode where the upstream emits non-empty `thinking` text, so the classifier marks those frames meaningful.
- Fix 3 does the same for interactive sessions and the subagents they spawn.
- Fix 1 is the backstop: for any client that passes neither switch, or for genuinely slow meaningful-frame cadence, the 14-minute budget keeps the gate from firing on legitimate long reasoning. The guard layer's own `GUARD_TOTAL_DEADLINE_MS` (600 s) does not cap it, because that guard only aborts a request whose response has not begun, and rescue pings begin the response at 135 s (auto memory [claude]).

Residual exposure: a thinking phase longer than about 13.5 minutes before its first text delta, on a client that passes neither switch, still restarts and retries.

## Prevention

- Detect fast: a subagent whose only signs of life are 38-byte pings for more than a few minutes is this bug until the journal says otherwise. `ccflare-precommit.py <since> <until>` (`experiments/lean-reader-2026-09-19/`) prints the stall records; `reason: "meaningful_progress_timeout"` is this bug, `reason: "semantic_timeout"` is the unrelated, resetting protocol-idle deadline. Cross-check with `ccflare-journal.py <since> <until>` for the climb-and-retry pattern, and `ccflare-provenance.py <session-id>` to rule out a model rewrite.
- What to pass to headless runs: always launch with the literal `--thinking-display summarized` CLI flag. Do not rely on a `--settings` thinkingDisplay key or `--forward-subagent-text`; both were shown to be no-ops for this purpose, and only the CLI flag reaches the launch-time decision. The retired loop-quality pipeline centralized it once in `THINKING_DISPLAY_ARGS` rather than per call site; since #1916, `bin/claude-loop.sh` is the only harness launcher that passes it. A new headless launcher anywhere in the harness inherits the bug unless it passes the flag.
- Test assertions that guard it:
  - `tests/claude-loop-budget-stop.test.sh` (around lines 221-222) greps the recorded `claude` argv for `--thinking-display summarized`.
  - `tests/loop-quality-sessions.test.sh` (deleted with the pipeline in #1916) asserted `--thinking-display summarized` on both the first-launch and stdin-prompt argv variants, and asserted a `--settings` flag is absent, guarding against a future edit reintroducing the withdrawn, non-working flag.
- Diagnostic script for a fresh repro: `diag-stream.sh` (`experiments/lean-reader-2026-09-19/diag-stream.sh`) runs one headless launch with `--output-format stream-json --verbose` and prints per-frame `TOOL_USE`, `TOOL_RESULT` and `TEXT` lines tagged MAIN or SUB; a long gap with no new lines during a thinking-heavy task, on a launch path missing `--thinking-display summarized`, is the signature to check first.
- Not yet built: the classifier-side fix proposed on better-ccflare issue #356 (count empty `thinking_delta` frames as progress, or reset the meaningful-progress clock on structural frames, under the existing absolute budget) was not implemented as of this writing (auto memory [claude]). The current fix set relies on every launch path requesting non-empty thinking text plus the larger budget, not on changing how the classifier scores empty deltas.

## Related Issues

- dotfiles #1221 (the lean-reader measurement that surfaced the stall), #1223 (retraction of the in-session claim, PR #1224), #1225 (loop flag, PR #1226), and PR #1246 (interactive setting); better-ccflare #356 (root-cause issue) and PR #357 (14-minute budget).
- `docs/solutions/logic-errors/a-run-ledgers-mtime-is-not-a-liveness-signal-for-an-idle-dispatcher.md`: the same shape of error, a liveness proxy that legitimately produces no signal during healthy work, in the dispatcher.
- `docs/solutions/best-practices/poll-long-waits-from-a-monitor-running-a-script-file-not-a-sleeping-background-shell.md`: another long-running Claude Code operation killed silently by infrastructure, with a different killer.
- `docs/solutions/best-practices/verify-schema-bound-claude-code-controllers-with-a-real-provider.md`: headless Claude Code behaviour that differs by flag in ways invisible until checked against the real provider.
- Memory note `ccflare-meaningful-progress-timeout-kills-long-thinking` (auto memory [claude]) carries the journal excerpts and the deploy verification.
