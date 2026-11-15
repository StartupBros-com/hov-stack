# Claude Code mods: incubator

Mods are resident TypeScript hook modules that ship inside Claude Code plugins
(Claude Code 2.1.287 and later). This folder incubates mods before each gets
its own repository and a card in the House of Vibe marketplace.

| Mod | What it does |
| --- | --- |
| [loop-breaker](loop-breaker/) | Stops Claude repeating the same failing tool call: hint, then refuse, with a face band and Stop and rethink |
| [install-preflight](install-preflight/) | `/preflight <folder or repo>` shows in plain language what a plugin or mod can do before you install it. Not wired globally since 2026-10-04 (see below) |
| [agent-radar](agent-radar/) | Band line per running subagent in this session (elapsed time, tool count, last tool), and per piece of delegated work it started outside itself (Codex, a Pro review, CE's peer, a headless Claude), with a toast when each ends; `/radar` opens a pane of every agent and its messages. Third-party, vendored at a pinned commit with local fixes and additions; see its `NOTICE.md` |
| [read-ceiling-pager](read-ceiling-pager/) | A Read whose explicit window would exceed the token cap is clamped to the lines that fit, and the result says which lines came back and where to continue; a Read the engine refuses anyway gets a retry window from the engine's own numbers that the read-ceiling-chunk hook admits after a first refusal |
| [x-mcp-budget](x-mcp-budget/) | Caps what the X (Twitter) MCP's reads cost: list, search and timeline calls ask for at most 10 results, each post and user returned is priced once per UTC day in a ledger every session on the machine shares, and once the day reaches the budget (default $1) further X MCP calls are refused until 00:00 UTC, naming the free oEmbed route for a single post |
| [idle-compact](idle-compact/) | Compacts a session whose main loop has had no turn for 50 minutes, ten minutes before its one-hour prompt cache expires, so the first turn back does not re-read the whole conversation uncached; a conversation under 100,000 tokens (the floor set here) is left alone. Third-party, vendored unchanged at a pinned commit; see its `NOTICE.md` |

Each house mod's README carries its `hooks:` and `calls:` lines as printed by
`claude plugin validate`, its options, and its limits. where-am-i and
next-steps, both vendored community mods, and lookout and reminder-diet, both
house mods, were removed (see below).

The house mods were chosen from a ranked backlog, `IDEAS.md`, generated on
2026-10-01. It also held the community-mod evaluations that brought in
agent-radar, where-am-i and next-steps. It was retired on 2026-11-15 on the
operator's go, once a survey of the published mods on 2026-11-14 had superseded
its rankings. Its two standing rules are under "Before building one" below, and
its last version is in git history at `b07b90e` (`mods/IDEAS.md`). The backlog
ids below (M04, M33) are rows in it.

## Before building one

Two operator rules, each from a real-use verdict recorded under "Load one":

- No mod that blocks or asks on a guess. A guard earns a place only by removing
  friction for long-running agents, never by adding a stop to their work
  (secret-stop, 2026-10-03).
- No next-prompt picker (next-steps, 2026-10-06).

Claude Code loads its built-in guard on this host (`cc-plugin-sec-default`; its
docs give the machine's managed settings as the reason). The guard skips a hook
that a mod loaded from a plugin folder registers on any of these events:
`classic.*`, `prompt.compose`, `prompt.section`, `prompt.context`,
`prompt.attachment`, `skill.prompt`, `attribution.text`, `session.compact`,
`settings.read`, and `session.append` for the attachment, hook-context and
compaction rows (Anthropic's mods admin page, "Know which hooks of a user's mod
don't run", read 2026-11-14). The mod still loads, with a note in `/plugin` and
no error, and the hook never runs, so check a mod's events against that list
before building it.

A session's debug log names each skip as `<mod>: <event> bypassed by
cc-plugin-sec-default`. The list is narrower than the events the guard itself
hooks, which the debug log prints on the line `hooks module
cc-plugin-sec-default@builtin loaded`: agent-radar's `agent.spawn` hook is on
that line and ran in a session checked on 2026-11-14. The page adds that the
guard passes over a user's hooks in a few other cases with no note, such as
`tool.describe` for an organization's tools.

## Load one

For one session:

```text
claude --plugin-dir ~/.claude/mods/loop-breaker --plugin-dir ~/.claude/mods/install-preflight
```

For every session, `CLAUDE_CODE_PLUGIN_DIRS` in `settings.json` `env` names the
folders joined by `:` (absolute paths; the engine expands a leading `~`). The
harness wires five of them this way, all but install-preflight: `sync.sh install`
links this folder at `~/.claude/mods` (a `STABLE_DIRS` entry, like `hooks`),
the canonical `settings.json` names them as
`~/.claude/mods/<mod>`, and `reconcile-runtime-env` writes that list
into the live settings mapped through `CLAUDE_HOME`, refusing a list with an
empty or relative entry or a folder with no `.claude-plugin/plugin.json`;
`sync.sh check` reports a manifest that disappears later as drift. Because the
path goes through the symlink, an install run from a worktree re-points the
link the way it does for hooks and never writes its own path into a live file.
To unload a mod everywhere, drop its path from that list. Deleting the mod's
folder from git does not remove the files the engine wrote beside it
(`<mod>/.claude-plugin/types/` and `<mod>/tsconfig.json`, both gitignored; see
"Check one"): a checkout that loaded the mod keeps them, and the folder with
them, until someone removes them by hand, as was done for reminder-diet on
2026-11-14.

agent-radar was wired on 2026-10-03 by operator decision, in place of a staged
trial, and is judged by real use; `/radar` had answered in one live session
before that. where-am-i and next-steps followed the same day on the same terms,
picked from the backlog's ranked shortlist for returning to a session and
for the typing a follow-up costs; neither had been loaded live before the wiring
PR, and each makes one small Haiku completion per main turn, none when nothing
draws the session. secret-stop was wired with agent-radar and retired the same
evening on the operator's real-use verdict: blocking git commands on a guess
stopped agent fleets mid-work, friction this harness removes rather than adds.
Its last version is in git history at `d0d32c12` (`mods/secret-stop/`).

next-steps was unwired and deleted on 2026-10-06 on the operator's real-use
verdict: the numbered list of next prompts above the input (`1` to `3` to draft
one, `0` to dismiss) was unwanted. Claude Code's own prompt suggestions stay off
too (`promptSuggestionEnabled: false`). The mod's last version is in git
history at `3cbe3ef3` (`mods/next-steps/`).

where-am-i was unwired and deleted on 2026-10-07 on the operator's real-use
verdict that it was too much: its four-line recap above the prompt (goal, now,
next, waiting on you) mostly restated the last reply, at four rows above every
prompt and one Haiku completion per main turn. `/where` went with it. The mod's
last version is in git history at `772c5e15` (`mods/where-am-i/`).

install-preflight was unwired on 2026-10-04 on the operator's review. `/preflight`
is a command only a person can type (a mod's commands are not offered to the
model), it had no runs after it was wired on 2026-10-03, and an agent vetting a
plugin runs `claude plugin validate`, the authority it explains, directly. It
stays here for the marketplace; `claude --plugin-dir ~/.claude/mods/install-preflight`
loads it for one session.

read-ceiling-pager was wired the same day on the same terms as agent-radar,
built from the backlog (M04) against a measured defect: 147 Reads failed the
token cap across 20 sessions in the week before, every one an explicit window
the engine does not paginate; the papercut count of that failure is how its
value is read. On 2026-10-04 the harness raised the engine's cap itself to 50,000
tokens (`CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS`, see `HARNESS.md`): 86% of
the refused windows in the 14 days before fit under it. The pager reads the same
value, so it now handles the tail above 50,000.

reminder-diet was wired on 2026-10-04 and removed on 2026-11-14 on the
operator's verdict. Built from the backlog (M33), it was meant to leave out an
engine task reminder that repeated, word for word, the last one the same loop
was sent. On this host it could not: the built-in guard skips the three hooks
it worked through (see "Before building one" above). In the 14 days to
2026-11-14 the stored sessions hold 1,893 notices that one of its hooks was
skipped, and 16,107 of 23,922 main-loop task reminders (67%) still repeated the
one before. Nothing of it is kept. The engine has its own switch,
`CLAUDE_CODE_TODO_REMINDER_MODE=off`, which turns off every task reminder, not
only repeats; it is not set here and not tried. The mod's last version is in
git history at `10ea7da` (`mods/reminder-diet/`).

lookout was wired on 2026-10-06 and removed on 2026-11-14 on the operator's
verdict. Every six main-thread model steps it asked one tool-less fork of the
session whether there was something the operator should know and might miss, and
showed a yes above the prompt: a house-written stand-in for Claude Code's
built-in you-should-know, which is enabled in `enabledPlugins` but never loads
on this host. The operator retired it once before, on 2026-10-26 in the repo
this stack was copied from, about 14 hours after the copy was taken, so the copy
kept it registered and it loaded in every session until this removal. Its last
version is in git history at `3dbbb6e` (`mods/lookout/`). `sync.sh
reconcile-runtime-env` rewrites the live mod list to the tracked one, so a host
that still names it drops it at the next install; the smoke test holds that.

x-mcp-budget was wired on 2026-11-04 by operator decision, against a measured
defect: agent sessions reading X through the hosted X MCP were most of the X
developer account's pay-per-use spend. Most of the posts they were billed for
came from search, timeline and quote-list pages at the tools' default page size,
in ad-hoc research rather than any scheduled job. The account's spend limit is
shared by every app on it, so that research could also stop the account's
production X readers. Before wiring, a live headless session with the mod loaded
had a 100-result search lowered to 10, priced a real single-post read into the
ledger, and was refused an X MCP call at a $0 budget. How it is judged is the
account's daily X MCP spend in the X developer console, against the 30 days
before. As with the other mods, the operator's verdict from real use decides. A
budget that keeps refusing useful research is raised under `pluginConfigs`, not
worked around.

idle-compact was wired on 2026-11-15 on the operator's go, out of the
2026-11-14 survey of published mods. It is davidar/claude-idle-compact,
vendored unchanged at one pinned commit; its `NOTICE.md` has the provenance and
what was checked. Sessions here are often left waiting overnight or for days,
and the first turn back then re-reads the whole conversation at the uncached
price. When a session's main loop has had no turn for 50 minutes, the mod
compacts it through `$.session.compact`, the same model request `/compact`
makes, while the one-hour cache (`promptCacheTtl`) is still warm. Compaction is
lossy: the session comes back to a summary. A main loop that has ended its turn
and is waiting on a subagent, a background shell or a scheduled wake-up counts
as idle. Two settings are this harness's own. `pluginConfigs` sets `minTokens`
to 100000 (upstream's default is 40000), so a small session is never compacted
for being idle. And `hooks/PreCompact/compact-preserve.js` gives the mod's
compaction the preserve-list, which it withholds from any other manual compact
that carries instructions. Before wiring, a throwaway session with the floor
lowered compacted after a minute idle (18k tokens to a 3k summary, 71% of the
request read from cache), and two more left at the 100,000 floor each logged
that the conversation was under it. A fourth, with the floor lowered, was
compacted while a background shell it had started was still running: the hook
added the preserve-list, and the shell's completion started the session's next
turn afterwards. Not seen before wiring: a compaction at the real 50-minute
mark, and one while a subagent was still running. As with the other mods, the operator's verdict from real use decides;
the cost to watch for is a session that came back to a summary missing
something it needed. `idleMinutes` and `minTokens` under `pluginConfigs` change
when it fires, and dropping its path from the list unloads it.

harness-optimizer loaded from this folder between 2026-10-18 and 2026-10-22 as a
link to an in-tree copy of the plugin. It now ships on its own from the House of
Vibe marketplace (`harness-optimizer@hov`: `/plugin install harness-optimizer@hov`,
then `/harness-optimizer:harness-optimizer`), so `CLAUDE_CODE_PLUGIN_DIRS` no longer
names it and this folder holds mods only.

## Check one

Three checks, each reproducible from this folder:

```text
claude plugin validate ./loop-breaker     # the hooks: and calls: lines are the audit authority
claude plugin test ./loop-breaker         # *.test.ts against the real mods runtime
```

The type-check needs the build's API declarations, which the engine writes
beside a mod the first time it loads it (`<mod>/.claude-plugin/types/`, with a
`tsconfig.json` at the mod root that extends them; both are gitignored here).
Load the mod once, for example with `claude --plugin-dir ./loop-breaker` or a
headless `claude -p "ok" --plugin-dir ./loop-breaker`, then:

```text
tsc -p ./loop-breaker
```

Results are recorded on the pull request that lands a change, at the commit
it checked, not in this file.

## Graduate one

Each marketplace plugin lives in its own `StartupBros-com/<name>` repository
with the three release workflows, a `VERSION` file and `docs/release-notes/`.
The onboarding steps, including the two organization-owner UI steps, are in
`docs/release/plugin-release-recipe.md` in `StartupBros-com/hov-stack`.
