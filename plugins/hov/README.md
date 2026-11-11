# hov

Fleet mailbox for coding agents. Decision record: `docs/decisions/2026-11-10-fleet-interaction-layer.md`. Umbrella issue: hov-stack#529. This directory is PR 1 of that build order: one host, one mailbox, delivery into Claude Code sessions as hook text.

Stdlib Python 3.10+ with an SQLite that has FTS5 (3.12 on Ubuntu 24.04 does). No daemon, no listener, no settings edits. The plugin is inert until a host enables it; nothing here runs on its own.

## Try it for one session

```bash
claude --bg -n hov-spike --plugin-dir plugins/hov
plugins/hov/scripts/hov send --to hov-spike --subject "ping" "hello from the operator session"
plugins/hov/scripts/hov ls
```

`--plugin-dir` loads the plugin for that session only. A `--bg` session starts idle (Claude Code 2.1.322 drops the positional prompt there), so hand it its first task from a peer session with the SendMessage tool, or with `claude attach`. The message reaches the session at its next prompt or tool call as a `<hov-mail>` block in `additionalContext`. The session-start event only resolves the session's name: Claude Code's `SessionStart` payload carries no `permission_mode`, so the hook cannot know there whether bodies may be injected.

The launcher lives in `scripts/`, not `bin/`, because claude.ai plugin distribution rejects a top-level `bin/` (see papercut). Link it into `~/.local/bin` as `hov` when the plugin is enabled.

Observed on 2026-11-11 in two `--bg` sessions loaded through `--plugin-dir`, both with permissions bypassed. The first had a peer's message waiting before its first prompt and got the `<hov-mail host="<host>" to="hov-spike" count="1" mode="count">` block as a `hook_additional_context` attachment at `UserPromptSubmit`. The second sent itself a message as a Bash tool call and got the block at `PostToolUse` of that same call, then ran the inbox command the block named (`python3 -I` plus the script's absolute path, since `hov` was not on `PATH`) and read the body back under the untrusted-peer framing line. A trivial tool call after that had nothing attached: each message reaches a session once. `hov.log` carries the matching `deliver event=... mode=count n=1` lines. A session that bypasses permissions only ever gets the count; the block always names a runnable inbox command.

Observed the same day, with the plugin enabled through settings on two hosts: a session launched with mail already waiting got the bodies at `SessionStart` although it bypassed permissions, because that event's payload has no `permission_mode` and 0.1.0 treated an unknown mode as full. Since 0.1.1 an event that states no mode delivers nothing and records nothing, and the first prompt or tool call delivers in the mode it states (`UserPromptSubmit` and `PostToolUse` both carry it).

## Commands

| Command | What it does |
| --- | --- |
| `hov send --to ADDR [--to ADDR] [--subject S] [--thread ID] [--kind note\|task\|handoff\|reply\|status] [--importance low\|normal\|high\|urgent] BODY` | Send. `ADDR` is `name`, `host:name`, `host:*` or `*`. `-` reads the body from stdin. |
| `hov inbox [--all] [--keep] [--json]` | Your unread mail; marks it read unless `--keep`. |
| `hov thread ID` | Every message in a thread. |
| `hov search QUERY` | FTS5 full-text search over subject and body. |
| `hov ls` | Sessions on this host (from `claude agents --json`) and known mailboxes, with unread counts. |
| `hov whoami` | Your address and how it was resolved. |
| `hov hook EVENT` | The hook entry point; reads Claude Code's hook JSON on stdin. |

Identity: `--as NAME`, else `$HOV_AS`, else the session named in `claude agents --json` for `$CLAUDE_CODE_SESSION_ID` (Claude Code exports it into tool shells), else the first eight characters of the session id, else `shell`.

State: `$HOV_STATE_DIR`, else `$XDG_STATE_HOME/hov`, else `~/.local/state/hov`. Files: `mail.db` (WAL) and `hov.log` (one line per send, read and delivery). `$HOV_HOST` overrides the host label; `$HOV_AGENTS_CMD` overrides the agents-list command (tests point it at a fixture).

## What the hook does, and does not do

- Returns `{"hookSpecificOutput": {"hookEventName": ..., "additionalContext": ...}}` and nothing else. Never `permissionDecision`, `decision` or `continue`. `tests/test_hov.py` asserts the key set.
- Frames mail as untrusted peer text, caps bodies at 4,000 characters, removes slash-command-shaped lines and neutralises `<hov-mail>` tags inside a body.
- In a session whose hook stdin says `permission_mode: bypassPermissions`, injects sender and count only; the body arrives through `hov inbox`.
- When the hook stdin states no `permission_mode` at all (Claude Code's `SessionStart` payload), delivers nothing and records nothing, so the first event that states the mode delivers in it.
- Delivers each message to a session once (`deliveries` table), and marks it read for the recipient name when the body was injected.
- Stays silent (empty stdout) when there is no mail or no session id, and logs rather than fails on a database error.

## Tests

```bash
plugins/hov/tests/ci.sh
```

That is what `release/scripts/plugin-ci.sh plugins/hov` runs in CI: the hook manifest check (three events, commands pointing at `scripts/hov`, a timeout on each), the VERSION match, then the unit tests.

Nineteen tests: mailbox round trip, threads, FTS5 search, ULID ordering, `ls`, the hook's output shape, once-per-session delivery, name resolution at SessionStart with delivery held until the first prompt, the session-name cache surviving a `whoami` with no agents list (it was never committed before 0.1.1), nothing delivered when the payload states no mode (the 0.1.0 fail-open as a planted negative), count-only in bypass sessions with its default-mode twin, slash-line stripping and the body cap, tag escaping, silence without a session id, the one-second hook budget at 1,000 messages, the log line per delivery, the untrusted-peer framing on `hov inbox` output, and a runnable command in every hook hint (plain `hov` when it is on `PATH`, else `python3 -I` and the script's absolute path).

## Not in this PR

Cross-host relay, remote launch, idle wake, the Codex/OMP MCP server, claims, and the router columns are PRs 2 to 8 in hov-stack#529. The schema already carries `origin_host` and `meta` for the relay.
