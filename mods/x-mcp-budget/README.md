# x-mcp-budget

Caps what Claude's X (Twitter) MCP reads cost: at most 10 results a page, and a
daily budget after which X MCP calls are refused until midnight UTC.

A Claude Code mod. The hosted X MCP (`api.x.com/mcp`) bills pay-per-use against
the X developer account behind its credential: each post a call returns is a
post read ($0.005), each user a user read ($0.010), and each resource is billed
once per UTC day. Its list, search and timeline tools take a `max_results` that
runs to 100 or more, and an X account has one spend limit shared by every app on
it, so a few broad searches from an agent session spend the same money as the
account's other X apps, and can exhaust the limit for them too.

Before an X MCP call (any tool named `mcp__x__*`) runs:

- **Past the budget it is refused.** Once today's estimated X MCP spend has
  reached `dailyUsd`, the call is not sent. The refusal says when the budget
  resets (00:00 UTC), that one post's text and author are free from
  `https://publish.x.com/oembed?url=<post URL>` without the X MCP, and which
  setting raises the budget. Other tools are untouched.
- **`max_results` is capped.** A `max_results` above `maxResults` is lowered to
  it. A list, search or timeline tool that returns posts or users by the page
  (`search_posts_all`, `get_users_posts`, `get_users_timeline`, follower and
  liker lists, and the rest in `PAGED`) is given `maxResults` when the call names
  none, since X's own default page there can be 100. Any other tool's
  `max_results` is never added. The result carries one line saying what was
  changed and what today has spent so far.

After the call answers, the mod prices what came back, from the X API JSON in
the result:

- each post in `data` and each post in `includes.tweets`: $0.005;
- each user in `data`: $0.010;
- `includes.users` (an author expansion): nothing. An expansion's users were
  observed to bill nothing;
- any other resource with an id (a list, space, story or chat event): $0.005.

Each resource is written once per UTC day to this session's own ledger file. A
resource read again the same day costs nothing more, which matches how X bills.
From 75% of the budget on, each X MCP result says what the day has spent. The
call that crosses the budget is answered, and says that the next X MCP call will
be refused.

## The ledger

`$XDG_STATE_HOME/x-mcp-budget/<YYYY-MM-DD>/` (else
`~/.local/state/x-mcp-budget/<YYYY-MM-DD>/`) holds one JSON file per session,
mapping each resource it was billed for (`post:<id>`, `user:<id>`) to its price.
Each process writes only its own file, and calls within a process (the main
loop, subagents, workflow agents) are written one at a time. Today's spend is
the union of every file in today's folder, each resource counted once. So every
session on the machine, headless runs included, shares one daily budget, and a
post two sessions read counts once. Old day folders are not removed. They are
small, and deleting the folder resets nothing but the record.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `dailyUsd` | `1` | The day's estimated X MCP spend at which further X MCP calls are refused, in USD (UTC day, every session on this machine). `0` refuses every X MCP call. |
| `maxResults` | `10` | The most results a list, search or timeline call may ask for, and what such a call naming none is given. At least 10, the lowest every X MCP tool accepts (`search_posts_all` and `get_posts_quoted_posts` start at 10). |

A mod loaded through `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS` reads them from
`settings.json`:

```json
{ "pluginConfigs": { "x-mcp-budget": { "options": { "dailyUsd": 2 } } } }
```

## Limits

- **An estimate, and a soft stop.** The mod prices what it sees in the result.
  X's console is the record of what was billed. The call that crosses the budget
  still runs, so a day can end past it by one call's worth. The account's own
  spend limit, set in the X developer console, is the hard stop and covers
  every app.
- **What the mod cannot read is not counted.** A result that is not X API JSON
  is passed through with a line saying it was not counted, as is a call whose
  ledger cannot be written (no home folder, a write refused). `includes.tweets`
  is priced as posts, which may be more than X bills.
- **Only this machine's X MCP calls.** Other X apps on the account, and X MCP
  use from other machines, are not seen.
- **Fails open.** If the hook itself fails, the call runs as asked
  (`.catch` replays `next`).
- **Two sessions near the budget at once** can both pass the check before
  either records. Each process re-reads every ledger before each call, so the
  overshoot is bounded by the calls already in flight.

## What `claude plugin validate` reports

```text
./register.ts hooks: tool.call
./register.ts gating hook with .catch: tool.call
./register.ts calls: $.clock.now, $.env.get (via dirFor), $.fs.list (via spentIn), $.fs.read (via readLedger), $.fs.write (via record), $.session.id (via record)
./register.ts env reads: HOME, USERPROFILE, XDG_STATE_HOME
```

## Install

```text
claude --plugin-dir ./x-mcp-budget
```

The harness loads it in every session through `CLAUDE_CODE_PLUGIN_DIRS` (see
`../README.md`).

## Check

```text
claude plugin validate ./x-mcp-budget
claude plugin test ./x-mcp-budget
tsc -p ./x-mcp-budget
```
