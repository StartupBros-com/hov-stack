# loop-breaker

Stops Claude repeating the same failing tool call.

A Claude Code mod. When the exact same tool call (same tool, same arguments) fails
or is refused again and again, loop-breaker steps in:

- **2 identical failures**: the tool result carries a hint Claude reads: change
  the arguments or the approach, the next identical attempt will be refused.
- **3 identical failures**: the next identical attempt is refused before it
  runs, with a reason Claude can act on (state what you tried, read the error,
  take a different approach or ask the user).
- **Above the prompt**: a face that goes from `(o_o)` to `(O_O)` to `(>_<)` as
  the run gets worse, with `r` **Stop and rethink** (ends the turn and asks
  Claude to say what it tried and what it will do differently) and `d`
  **Dismiss**.

A success clears the count, so a retry that works is never punished. Each
subagent is counted on its own. Everything resets at the start of each turn.

## Why a mod and not a hook

A settings hook sees one call at a time and can only refuse. loop-breaker needs
the result of the previous call, adds a hint to a result, refuses before the
permission prompt, and draws above the prompt. Those are mod-only moves.

## Install

```text
claude --plugin-dir ./loop-breaker
```

Or from a marketplace once it is published there:

```text
/plugin install loop-breaker@hov
```

## Options

Set in `/config` under the plugin, or in `settings.json` `pluginConfigs`:

| Option | Default | What it does |
| --- | --- | --- |
| `threshold` | `3` | Identical failures allowed before the next identical attempt is refused (2 to 20) |
| `allow` | `""` | Comma-separated tool names loop-breaker never refuses, for example `Bash,Read` |
| `retryLater` | `deferred\|try again later\|retry after\|rate limit\|...` | A case-insensitive regular expression matched against the first 400 characters of a failed call's text; a match is "try again later", not a loop, and is not counted. Covers admission guards that defer a job, rate limits and dropped connections. Only the head is read, so a `503` buried in a test log still counts as a failure. Empty counts every failure. |

## What it can touch

`claude plugin validate ./loop-breaker` prints the authority:

```text
hooks: turn.start, turn.complete, tool.call, ui.render{component=AbovePrompt}
calls: $.prompt.submit, $.state.get, $.state.set, $.turn.abort, $.ui.resolve, $.ui.toast
```

It reads no files, runs no programs, makes no network calls and calls no model.
It sees every tool call's arguments and result, which is how it tells one call
from another; it stores none of them past the turn.

## Limits

A seatbelt, not a boundary. It matches calls on exact arguments, so a retry
with a trivially different command (an added space inside a string, a new flag)
counts as a new call. It cannot tell a legitimate poll loop from a stuck one
unless the failure says so in its first 400 characters (`deferred`, a rate
limit): for a command that polls on purpose, such as `gh pr checks` while
checks are pending, allowlist the tool, add its wording to `retryLater`, or
raise `threshold`. A refused call stays refused until the next turn starts or
a different call succeeds; `d` Dismiss clears the band, not the count.

## Develop

```text
claude plugin validate ./loop-breaker
claude plugin test ./loop-breaker
```

MIT. StartupBros / House of Vibe.
