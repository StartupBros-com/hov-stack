# install-preflight

See what a plugin or mod can do before you install it.

A Claude Code mod. Mods run with your permissions: they can read your files,
start programs, reach the internet and spend your plan. `/preflight` reads a
plugin the way Claude Code will, with `claude plugin validate --json`, and
turns its `hooks:` and `calls:` lines into plain language:

```text
/preflight owner/some-mod

Can start programs, reach the internet and read environment variables.
some-mod 0.3.1 by Someone

! Can start programs on your machine, with your permissions (from: $.process.run)
! Can send data to and fetch from the internet (from: $.http.fetch)
! Can read your environment variables, where API keys often live (from: $.env.get)
~ Sees every tool call and can change or refuse it (from: tool.call)
- Draws in the interface (from: ui.render, $.ui.resolve)

./register.ts hooks: session.start, tool.call, ui.render{component=Pane}
./register.ts calls: $.env.get, $.http.fetch, $.process.run, $.ui.resolve

A list of powers, not a verdict. Read the code before you install: mods run with your permissions.
```

The same report opens in a pane with `c` **Copy install command** and `x`
**Close**. Nothing is installed.

It takes a local folder, a GitHub `owner/repo`, or a git URL. A repo is cloned
shallow into `/tmp/install-preflight/` and reused next time. Point it at a
marketplace repo and it lists the plugins so you can preflight one.

## What `!`, `~` and `-` mean

- `!` high: starts programs, reaches the internet, reads environment variables,
  writes files, approves or refuses tool calls before you are asked, refuses or
  alters other mods, or runs shell commands from settings hooks.
- `~` medium: sees or changes tool calls, prompts or the system prompt, reads
  files or your transcript, spends your plan on model calls, messages other
  sessions, starts subagents.
- `-` info: draws in the interface, adds a command or tool, keeps state, asks
  you questions.

The raw `hooks:` and `calls:` lines underneath are what Claude Code read from
the code and are the authority; the rows above only explain them. When
`claude plugin validate` itself reports the plugin as failed, the answer leads
with "Validation failed" and its errors instead of a verdict, because a failed
scan may be missing hooks or calls. Static reading cannot tell you what the
code does with a power, only that it has it. Read the code.

## Install

```text
claude --plugin-dir ./install-preflight
```

Or from a marketplace once it is published there:

```text
/plugin install install-preflight@hov
```

## What it can touch

`claude plugin validate ./install-preflight` prints the authority:

```text
hooks: session.start, command.run{command=preflight}, ui.render{component=Pane}
calls: $.command.register, $.fs.exists, $.fs.read, $.process.run, $.state.get, $.state.set, $.ui.close, $.ui.copy, $.ui.open, $.ui.resolve, $.ui.toast
```

It runs `git clone --depth 1` for a repo you name and `claude plugin validate
--json` on the folder. It reads that plugin's `plugin.json` and `hooks.json`
and nothing else, makes no network calls of its own, and calls no model.

## Limits

A list of powers, not a verdict. It reads the code statically, the same way
`claude plugin validate` does, so a mod that hides a call behind indirection
may show fewer powers than it has; the `hooks:` and `calls:` lines are only as
good as that scan. It complements `harness-vet`, which vets skills.

## Develop

```text
claude plugin validate ./install-preflight
claude plugin test ./install-preflight
```

MIT. StartupBros / House of Vibe.
