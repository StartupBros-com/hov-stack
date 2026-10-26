# Cross-session messaging

Claude Code ≥ 2.1.224 lets sessions on one machine message each other: Claude
discovers peers with `ListAgents` and sends with `SendMessage`; the operator
surface is `/list-agents` (alias `/peers`) and `/rename` / `--name` for
addressable names. A message is plain text only — never history or files. Each
session binds a per-session unix inbox socket (`/status` → "Peer address" row),
restricted to the OS user. Docs: https://code.claude.com/docs/en/cross-session-messaging

## Decision 2026-08-08: removed `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`

The flag sat in `settings.json` env with **zero recorded rationale** — it
predates this repo (already present in the first backup commit `4bf8058`,
2026-07-02) and was never mentioned in any doc or memory. It disables the
GrowthBook feature-flag fetch that cross-session messaging *and* Remote Control
require, and there is **no narrower switch**: `DISABLE_TELEMETRY`,
`DO_NOT_TRACK`, and `DISABLE_GROWTHBOOK` each also kill feature-flag fetching
(env-vars docs, verified 2026-08-08). Beware the trap on two of them: any
non-empty value counts, including `0`/`false` — only *unsetting* re-enables.

- **Cost accepted**: telemetry, auto-update checks, release notes, `/feedback`,
  and fast-mode availability checks come back. Telemetry excludes code, file
  paths, and bash commands per docs.
- **Kept the narrow slice**: `DISABLE_ERROR_REPORTING=1` (error reporting only;
  no feature-flag effect).
- **Contradiction removed**: the old flag also disabled gateway model discovery
  refreshes while `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` asked for them.

## Inbound posture

- `crossSessionInbound: accept`, user-wide, since 2026-09-28 (operator
  decision after the Ground Truth vet follow-up). Applied by hand to the
  live `~/.claude/settings.json` and mirrored in the tracked copy, because
  `settings.json` is volatile and `sync.sh install` never copies it. With no
  value set, Claude Code decides per message from the two sessions'
  permission-mode classes (bypass versus prompting, per the messaging docs):
  a prompting receiver delivers unless the sender bypasses, and a bypass
  receiver holds unless the sender also bypasses. During the 2026-09-28
  investigation, the fleet was mixed: interactive sessions defaulted to
  `acceptEdits` (settings `defaultMode`; not sampled live),
  `claude-loop.sh` workers ran `bypassPermissions` (the
  `claude -p` launch at `bin/claude-loop.sh:1585-1586`), and most sampled
  `claude --bg` jobs did too (five of six live background sessions on
  2026-09-28; one `acceptEdits`). So under the default every message between
  an interactive session and a background job or loop worker was held for an
  operator who, on the headless side, cannot approve. Measured 2026-09-28 on
  2.1.284 with `-p` workers, one run per configuration: with no value set on
  the receiver, `acceptEdits` to bypass held (the sender got `[Cross-session
  delivery notice] Your message to another session was held for the
  recipient user's approval`; #1451's run) and bypass to `acceptEdits` held
  (the flag run below, where the `acceptEdits` side had no value set and
  the bypass sender's own `--settings` governs only its own inbound), while
  bypass to bypass delivered; with `accept` in the live user settings and no
  flags, both cross-class legs delivered (each side's report carried the
  message verbatim, no notice); with only
  `--settings '{"crossSessionInbound":"accept"}'` on the bypass receiver,
  the `acceptEdits`-to-bypass leg delivered and the reverse leg stayed held.
  The current WSL startup default is documented in
  [Autonomy & permission model](../HARNESS.md#autonomy--permission-model);
  the historical mode mix above does not describe every current session.
  What `accept` keeps and what it trades away. Kept: the inbox socket is
  restricted to the OS user, so every sender runs as the operator's user
  (not necessarily operator-authored content: a session that has read
  injected content is a compromised sender); a delivered message still
  cannot approve a permission prompt, change settings or `CLAUDE.md`, or run
  a slash command, and prompts still fire for any permission the receiver
  does not already hold (messaging docs, "How a session treats an incoming
  message"); upstream caps bound volume, not content (per-sender rate
  limit, duplicate drop, 50-message read queue, 100 held). Traded away: the
  human approval step. A bypass worker holds every permission, so for
  workers the gate is deny rules, the PreToolUse hooks (git-guard, dcg, the
  shape guard) and the CLAUDE.md rule that a peer message is untrusted
  content (the gate in `CLAUDE.md`, Harness section; rescoped from a
  same-turn gate on 2026-10-09, ruling in `HARNESS.md`, "Autonomy &
  permission model"). That rule is
  model-followed, so a session that fails to recognize a relay as the
  injected payload can still copy it to every reachable bypass worker with
  no approval, where the default would have held each copy and a headless
  receiver would have dropped it. The same applies in reverse: the operator
  no longer sees an approval dialog on a worker-to-interactive message, so
  an interactive session treats a worker message as untrusted too. Inside
  the OS user the boundary also moves: a session or child whose own rules
  would have blocked editing settings or hooks can still post to the socket
  (no guard blocks `curl --unix-socket`, see Plumbing facts), and a raw post
  that Claude Code cannot attribute to a session or to the receiver's own
  child, which a bypass receiver holds under the default, is delivered now.
  Against outside principals (other OS users, the Windows side, containers)
  nothing changes. The operator took this trade for always-on collaborating
  workers on a single-user machine. Deletion condition: any incident where
  a peer message preceded an unintended action, judged from the session
  transcript, sends this back to the default, and workers that must not
  take unattended messages get `refuse` via `--settings` (`hold` on a
  headless worker is a silent drop). Precedence: managed, then
  `--settings`, then user, first found wins; project and local settings can
  only tighten (`accept` < `hold` < `refuse`), so a repo can set `refuse`
  in its own `.claude/settings.json` for sessions started in that repo
  (read at session start; sessions in other repos still inherit `accept`).
- `isolatePeerMachines: true` set explicitly in `settings.json`: any send
  beyond this machine (transits Anthropic servers, Remote Control path) prompts
  first, even in bypass mode. Codifies CLAUDE.md's "pause before external
  sends"; a `true` from any scope wins, so no project file can loosen it.
  Cross-machine is reply-only anyway — a local session can never initiate.
- Headless `claude -p` workers bind an inbox but cannot show the approval
  dialog. Under the class default a message held there is dropped after
  `dialogExpiry` (five minutes by default; a sender it can reach is told it
  expired),
  and an unattached `claude --bg` session keeps the dialog open until someone
  attaches, then drops the message after one more expiry period (messaging
  docs, "Non-interactive sessions" and "Control inbound messages"). That is
  why the user-wide `accept` above exists: every `claude-loop.sh` worker is
  bypass-class, so before 2026-09-28 the CLAUDE.md "message that session"
  rule silently failed for every interactive-to-worker message (Ground Truth
  vet X3,
  `docs/vets/2026-09-28-groundtruth-self-coordinating-agents-harness-vet.md`;
  the first correction that day read the hold as one-directional and called
  the per-worker flag the only fix). If a repo tightens back to `hold`, the
  sender's delivery notice is the signal: fall back to a PR or issue comment.
  Bare-mode sessions bind no socket and are unreachable by design.
- Remote Control (phone or web steering of a local session) is refused while
  `ANTHROPIC_BASE_URL` points at ccflare: on 2.1.284 `claude remote-control`
  refuses with "Remote Control is only available when using Claude via
  api.anthropic.com. ANTHROPIC_BASE_URL is set and does not point at
  api.anthropic.com" (verified 2026-09-28; the 2026-08-08 probe agrees). The
  documented way out is to unset the variable for that one session
  (`env -u ANTHROPIC_BASE_URL claude --remote-control`, not run here): by
  construction that session then talks to api.anthropic.com directly, with
  no ccflare account pool and no guard in front of it. Not adopted; no
  stated need (Ground Truth vet X5).

## Plumbing facts

- Socket path is exported to hooks and Bash as `CLAUDE_CODE_MESSAGING_SOCKET`
  (before any hook runs, own socket never inherited; a settings `env` block
  cannot set it). Presence of the var doubles as the cheapest "is messaging on
  in this session" probe.
- No guard blocks socket access: dcg 0.10.0 allows `curl --unix-socket` and
  `node -e "require('net').connect(...)"` (tested 2026-08-08); only bare
  `nc`/`ncat`/`netcat` are name-denied in `settings.json`. Upstream throttling
  (per-sender rate limit, duplicate drop, 50-message read cap, 100-message
  hold cap) bounds any hook-driven or looping sender.
- Sandbox is off (`sandbox.enabled: false`). If it is ever enabled on
  Linux/WSL2, the **only** unix-socket lever is
  `sandbox.network.allowAllUnixSockets: true` — the path allowlist
  (`allowUnixSockets`) is macOS-only, and on WSL2 the blanket flag also
  reopens the Windows-interop socket. Revisit this trade then.
- Same-machine reach requires a shared filesystem: a container session and a
  host session cannot see each other's registration files.

## Security model

Upstream enforcement on the receiver: a peer message cannot approve permission
prompts, cannot change settings/CLAUDE.md/config, slash commands in it arrive
as inert text, and the receiver's own permission rules still gate anything the
message asks for. Our convention on top: a peer message's *claims* are data,
not ground truth — verify against gh/PR/file state before destructive or
outbound action. The laundering path to worry about is a peer session that
consumed injected content relaying "act now" (CLAUDE.md → Harness, untrusted
content rule).

## Retrofit candidates (not built — build on evidence, Ceremony Test applies)

- Nothing detects two sessions on the same issue any more (the
  `worktree-claim-advisory.js` hook retired 2026-10-17, move 7); messaging
  the *other* live session is the missing half (motivating incident:
  2026-08-07 dup work, issue 553 / PRs 552+550).
