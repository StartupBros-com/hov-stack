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
| [lookout](lookout/) | Every six main-thread model steps, one tool-less fork of the session (served from the prompt cache) is asked whether there is something you should know and might miss; a yes shows above the prompt until `ok` or two prompts on. No model call while nothing draws the session. `/lookout` for status and cost, `now`, `off`, `on`. Written from scratch as a host-compatible take on Claude Code's built-in you-should-know, which does not load behind the gateway |
| [reminder-diet](reminder-diet/) | Leaves out an engine task reminder that repeats, word for word, the last one the same loop was sent; the first, and any reminder whose task list changed, still goes through, and the comparison starts over after a compaction or `/clear` |

Each house mod's README carries its `hooks:` and `calls:` lines as printed by
`claude plugin validate`, its options, and its limits. `IDEAS.md` is the ranked
backlog the house mods were chosen from and records the community-mod
evaluations that brought in agent-radar, where-am-i and next-steps (the last
two removed, see below).

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
To unload a mod everywhere, drop its path from that list.

agent-radar was wired on 2026-10-03 by operator decision, in place of a staged
trial, and is judged by real use; `/radar` had answered in one live session
before that. where-am-i and next-steps followed the same day on the same terms,
picked from the ranked shortlist in `IDEAS.md` for returning to a session and
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

reminder-diet was wired on 2026-10-04 on the same terms, built from the backlog
(M33) and narrowed to the one repeat the measurement found worth removing: in the
14 days before, 19,794 of 27,432 stored task reminders (72%) carried the same
task list as the previous one in the same loop, about 241M characters, most of
them in long-running loops. Every other injected reminder is either real context
sent about once a loop or too small to matter, and is left alone. How often task
tools are called per loop is the measure that would show the repeats were doing
work; a drop takes the mod back out of `CLAUDE_CODE_PLUGIN_DIRS`.

lookout was wired on 2026-10-06 on the same terms, after the operator asked for
a version of Claude Code's built-in you-should-know that works here. The
built-in is enabled in `enabledPlugins` but never loads on this host (it waits
on a compliance check the gateway setup cannot settle; see lookout's README), and its
code is not licensed for copying, so lookout is written from scratch on the
public mod API. Before wiring, a live fork through the gateway answered from a
user-tier mod, and the mod's own question drew `none` on routine steps and a
correct flag on a failed migration buried in a log (figures in its README). Each
check reads the whole conversation from the prompt cache, so it sends none while
nothing draws the session; `/lookout` shows what this session's checks cost, and
`/lookout off` stops them in later sessions too.

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
