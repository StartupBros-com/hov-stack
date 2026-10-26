# lookout

A second pair of eyes while Claude works.

A Claude Code mod. Every few model steps of the main thread, lookout asks one
question of a tool-less fork of the session: is there one thing the person
running it would want to know now and could easily miss? The fork carries the
main thread's own transcript, system prompt and model, so the API serves almost
all of it from the prompt cache. A yes shows above the prompt:

```text
 ✦ lookout The deploy did finish, but deploy.log line 3 shows migration 0042_add_orders_index failed after a lock timeout and was rolled back, so the deploy went out without that index.  ok
```

`ok` (or `o` once the band has focus) dismisses it; otherwise it stays for one
more prompt and clears on the second. The question asks for things that would
change what the person does: a failed, skipped or cut-short check the work
carried on past, a guess stated as fact, a change beyond what was asked, work
against an instruction they gave, a decision of theirs being made without them,
time or cost well past what the task needs. It leaves out progress reports and
anything the assistant already told them plainly. Most checks answer `none` and
show nothing.

## Why it exists

Claude Code 2.1.292 ships a built-in plugin with the same idea,
`cc-plugin-you-should-know`. It does not load on this host: the engine enables
it only once it has settled the account's compliance status (HIPAA, zero or
limited data retention), and it treats a session behind a gateway
(`ANTHROPIC_BASE_URL` not `api.anthropic.com`) or with an `x-api-key` custom
header as unsettled, so the plugin stays off. In the 2.1.292 bundle the gate is
`bn`, which needs `R0n()`, that is `verdict.complianceTaintsSettled()`; the
check behind it, `pur()`, returns false on `nx()` (an `x-api-key` custom header)
and on `!xg()` (an `ANTHROPIC_BASE_URL` that is not first-party), among other
conditions. Its code is Anthropic's and not licensed for copying; lookout is
written from scratch against the public mod API and copies none of it. It also
leaves out what the built-in has for Anthropic: answer buttons that send
telemetry, and a page it publishes to explain a card.

## Cost, and when it asks nothing

Each check is one `$.model.fork`: a cache read of the whole conversation, a few
hundred uncached tokens, and about 70 to 350 output tokens at the session's own
model and effort. Measured on this host through the gateway (2026-10-06, Opus
5.5, a session of about 69,000 tokens): 69,294 to 69,463 tokens read from the
cache, 356 to 476 uncached and 73 to 202 output per warm check; the one fork
timed took 11 seconds. The first check of each of the three measured sessions
read 37,532 tokens from the cache and paid about 32,000 uncached.

No check is sent while nothing draws the session (`$.session.surfaces()` is
empty: a `claude -p` run, a background job no client is attached to), so the
fleet's unattended work costs nothing. A check that comes due while the last is
still out is skipped. `/lookout` reports how many checks this session sent and
what they read and wrote.

## Commands and options

```text
/lookout        on or off, the last check, what the checks cost, the flags so far
/lookout now    check at once
/lookout off    stop checking, in this session and later ones
/lookout on     start again
```

| Option | Default | |
| --- | --- | --- |
| `every` | 6 | Main-thread model steps between checks. 0 turns the automatic checks off; `/lookout now` still asks. |

Set it in `settings.json` under `pluginConfigs.lookout.options`.

## What `claude plugin validate` reports

```text
./register.tsx hooks: session.start, session.end, turn.step, prompt.submit, command.run{command=lookout}, ui.render{component=AbovePrompt}
./register.tsx calls: $.command.register, $.model.fork (via check), $.session.surfaces (via isWatched), $.state.get, $.state.set, $.store.delete, $.store.get, $.store.set, $.ui.resolve
```

## How it decides

- Only main-thread steps count (`turn.step` with no `agentId`). The fork reads
  the main thread's transcript, so counting a subagent's steps would only ask
  about the same conversation more often.
- The fork is sent after the step's stream has ended and is not awaited, so the
  step and the turn never wait on it. It sees the main thread's last request,
  which holds every tool result before that step.
- A reply is read only in the shape asked for: a line beginning `Lookout:`, or
  `none`. Anything else, a failed fork (`api-error`, `empty-reply`, `aborted`)
  and `nothing-to-fork` (before the first response, after `/clear`) show
  nothing. `/lookout` names the last outcome.
- Terminal escape sequences and control characters are removed from a flag, and
  a flag is cut at 280 characters.
- A flag that differs from one already shown this session only in case, spacing
  or punctuation is not shown again, and the last five flags go into the
  question so the fork leaves them out.
- `/lookout off` also stops a check already under way: one that has not sent its
  fork yet sends none, and one that has shows no flag, even if lookout is back
  on when the reply comes.
- A `/clear` or a resume goes on in the same process under another
  conversation, with no new `session.start`, so lookout starts that one over at
  `session.end`: the flags, the step count, the totals and the flag on screen
  go, and a check still out sends, counts and shows nothing after it, and does
  not hold back the new conversation's checks. The on/off switch carries over. Compaction keeps the same conversation, so it
  changes none of this.
- An off switch that cannot be read from `$.store` at session start counts as
  off, since each check reads the whole transcript; `/lookout` says why, and
  `/lookout on` turns it on. When `/lookout off` or `on` cannot save the switch,
  it still holds in this session, and the reply and `/lookout` say a later
  session may start the other way.

## Limits

- **Main thread only.** A long subagent run is seen only through what it hands
  back to the main thread.
- **Timing.** A check runs on the transcript as of the step before it, so it can
  flag something the assistant goes on to mention in its next reply.
- **One check at a time.** A conversation has at most one check out, and lookout
  puts no time limit on a fork, so one that never comes back stops that
  conversation's checks (`/lookout now` says a check is out). A `/clear` or a
  resume starts a conversation that checks again.
- **Surfaces.** Where nothing draws the `AbovePrompt` band, a flag is kept but
  not shown; `/lookout` lists it.
- **State.** The flags, the step count and the totals live in the module, so a
  hot reload starts them over, as does a `/clear` or a resume. The flag on
  screen survives a hot reload (`$.state`); the off switch survives all three
  (`$.store`).

## Check it

```text
claude plugin validate ./lookout
claude plugin test ./lookout
tsc -p ./lookout        # after the engine has loaded it once
```

## License

MIT.
