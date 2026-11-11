# hov

Fleet mailbox for coding agents. Decision record: `docs/decisions/2026-11-10-fleet-interaction-layer.md`. Umbrella issue: hov-stack#529. This directory is PR 1 of that build order: one host, one mailbox, delivery into Claude Code sessions as hook text.

Stdlib Python 3.10+ with an SQLite that has FTS5 (3.12 on Ubuntu 24.04 does). No daemon, no listener, no settings edits. The plugin is inert until a host enables it; nothing here runs on its own.

## Try it for one session

```bash
claude --bg -n hov-spike --plugin-dir plugins/hov
plugins/hov/scripts/hov send --to hov-spike --subject "ping" "hello from the operator session"
plugins/hov/scripts/hov ls
```

`--plugin-dir` loads the plugin for that session only. A `--bg` session starts idle (Claude Code 2.1.322 drops the positional prompt there), so hand it its first task from a peer session with the SendMessage tool, or with `claude attach`. The message reaches the session at its next hook event (prompt, tool call, or session start) as a `<hov-mail>` block in `additionalContext`.

The launcher lives in `scripts/`, not `bin/`, because claude.ai plugin distribution rejects a top-level `bin/` (see papercut). Link it into `~/.local/bin` as `hov` when the plugin is enabled.

Observed on 2026-11-11 with exactly that sequence: the spike session's transcript carries a `hook_additional_context` attachment from `UserPromptSubmit` whose content is the `<hov-mail host="wm" to="hov-spike" count="1" mode="count">` block (count mode because the host's default permission mode is bypass), and `hov.log` shows the matching `deliver event=UserPromptSubmit ... mode=count n=1` line.

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
- Delivers each message to a session once (`deliveries` table), and marks it read for the recipient name when the body was injected.
- Stays silent (empty stdout) when there is no mail or no session id, and logs rather than fails on a database error.

## Tests

```bash
plugins/hov/tests/ci.sh
```

That is what `release/scripts/plugin-ci.sh plugins/hov` runs in CI: the hook manifest check (three events, commands pointing at `scripts/hov`, a timeout on each), the VERSION match, then the unit tests.

Fifteen tests: mailbox round trip, threads, FTS5 search, ULID ordering, `ls`, the hook's output shape, once-per-session delivery, name resolution at SessionStart, count-only in bypass sessions with its default-mode twin, slash-line stripping and the body cap, tag escaping, silence without a session id, the one-second hook budget at 1,000 messages, and the log line per delivery.

## Not in this PR

Cross-host relay, remote launch, idle wake, the Codex/OMP MCP server, claims, and the router columns are PRs 2 to 8 in hov-stack#529. The schema already carries `origin_host` and `meta` for the relay.
