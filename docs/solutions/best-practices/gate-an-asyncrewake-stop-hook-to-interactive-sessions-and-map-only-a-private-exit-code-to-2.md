---
title: "Gate an asyncRewake Stop hook to interactive sessions, and let its wrapper map only a private exit code to 2"
date: "2026-11-13"
category: best-practices
module: hov-idle-wake
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A plugin adds a Claude Code hook with `\"asyncRewake\": true`, so the hook keeps running after the turn and its exit 2 starts a new turn"
  - "The plugin is installed on machines that also run `claude -p`, the Agent SDKs, IDE extensions or CI, where nobody sits at a prompt"
  - "The hook command calls a subcommand of a script that can drift from hooks.json, such as an older script with no handler for the new subcommand"
  - "The hook relies on Claude Code backgrounding it, which an older Claude Code does not do"
symptoms:
  - "A headless `claude -p` run with the plugin loaded would start another turn each time the hook exits 2, so the run would never end"
  - "Python argparse exits 2 on an unknown subcommand, the same code that wakes the session, so a script and hooks.json out of step would read as a wake"
related_components:
  - "hov-plugin"
  - "claude-code-hooks"
tags: [stop-hook, async-rewake, claude-p, headless, hook-exit-codes, claude-code-entrypoint, hov, idle-wake]
---

# Gate an asyncRewake Stop hook to interactive sessions, and let its wrapper map only a private exit code to 2

## Context

hov 0.1.7 (#561) wakes a Claude Code session that is idle at its prompt when direct mail arrives. It does so with a `Stop` hook marked `"asyncRewake": true` (`plugins/hov/hooks/hooks.json:36-45`). Claude Code leaves that hook running in the background after the turn ends. When the hook exits 2, Claude Code starts a turn in the idle session from the hook's `rewakeMessage` followed by its stderr (`plugins/hov/scripts/hov:944-947`).

The easy belief is that exit 2 "wakes the human's session". In fact it starts a turn in *whatever* Claude Code ran the hook. Under `claude -p`, an exit-2 Stop hook starts another turn, and the run never ends (`plugins/hov/scripts/hov:959-960`). That reading came from this session's study of Claude Code's hook runner (2.1.3xx). It was not reproduced with a looping run, because the gate below keeps the watcher from starting there. A plugin installs on every machine that enables it, and a watcher that blocks on a mailbox and then exits 2 would turn every headless script and SDK job on those machines into a run that never stops.

A second trap sits in the exit code itself. Python's argparse exits 2 on an unknown subcommand, which is the wake code. If hooks.json names `hov wake` and the installed script is an older one with no `wake` command, the argparse error would read as a wake.

## Guidance

1. **Start the watcher only where a session can sit idle and end cleanly.** hov's watcher returns 0 straight away unless `CLAUDE_CODE_ENTRYPOINT` is `cli` (`plugins/hov/scripts/hov:1277-1280`). Per this session's reading of the Claude Code binary and a live `claude -p` probe, Claude Code sets `cli` for an interactive or `--bg` session and `sdk-cli` under `-p`, and turns an inherited `cli` into `sdk-cli` under `-p`. The SDKs and IDE extensions set their own values. Allow `cli` alone rather than deny a list of known values, so an entrypoint added later gets no watcher.

2. **Check the Claude process's argv for print mode too.** An inherited entrypoint that is not `cli`, such as an IDE extension's, survives `-p` unchanged (per the same binary reading). hov reads the Claude Code ancestor's `/proc/<pid>/cmdline` and does not start the watcher on `-p`, `--print` or `--print=` (`plugins/hov/scripts/hov:1064`, `:1286-1287`). The Stop hook payload has no field that says print mode, so the hook cannot learn it from its input.

3. **Exit a private sentinel, and map only that to 2 in the hook command.** The watcher exits 86 (`WAKE_EXIT`, `plugins/hov/scripts/hov:966`). The hook command is a shell wrapper that turns 86, and nothing else, into 2:

   ```json
   "command": "sh -c 'python3 -I \"$0\" wake; [ $? -eq 86 ] && exit 2; exit 0' \"${CLAUDE_PLUGIN_ROOT}/scripts/hov\""
   ```

   An argparse error (2), a crash (1), a kill or a clean 0 all become 0, which wakes nothing (`plugins/hov/scripts/hov:948-950`). The `args` exec form, with Python as the hook's direct child, was rejected. There the 86→2 mapping would have to live inside the script, so the old-script argparse 2 would pass straight through as a wake.

4. **Gate on the Claude Code version whose runner backgrounds the hook.** A Claude Code without `asyncRewake` runs the hook in the foreground, and the turn would not end until the hook's timeout, which is four hours here. hov starts the watcher only on 2.1.319 and later (`WAKE_MIN_CLAUDE`, `plugins/hov/scripts/hov:975`, `:1289-1294`) and logs `wake-skip` otherwise.

5. **Make every other way out exit 0.** Missing session id, no Claude Code ancestor, no `/proc` (macOS), `HOV_WAKE=0`: each path returns 0 before waiting (`plugins/hov/scripts/hov:1273-1288`).

## Why This Matters

Exit 2 from a Claude Code hook is never a neutral "error". For an `asyncRewake` hook it starts a model turn, so every path that can reach exit 2 by accident spends turns with nobody watching. A version skew, a crash or a headless entrypoint can each hit one, and none shows up in an interactive test. Both wrong outcomes are silent. A print run that never ends looks like a slow job, and a woken session looks like the agent decided to act.

## When to Apply

- Any hook marked `asyncRewake`, in hov or any other plugin in this marketplace.
- Any hook whose exit 2 means something to Claude Code. For most events it blocks the action or feeds stderr back to the model instead of waking a session. Map only a private code to 2 whenever the hook calls a script that can fall out of step with hooks.json.
- Any hook that waits for something before exiting: decide first which entrypoints may wait at all.

## Examples

hov pins this shape with tests that run the real `hooks.json` command against stub scripts and a fake Claude Code process:

- `plugins/hov/tests/test_wake.py:221-230` runs the Stop command against stubs that exit 86, 2, 1 and 0, and expects 2, 0, 0, 0.
- `plugins/hov/tests/test_wake.py:234-253` expects no watcher to start or wait for an `sdk-cli` entrypoint, `HOV_WAKE=0`, a `-p` argv, a Claude Code older than 2.1.319, a session id that is not a plain file name, and a parent that is not Claude Code.
- `plugins/hov/tests/ci.sh:19` and `:28-31` assert the Stop hook's exact command, `asyncRewake: true` without `async`, a timeout 60 s past the watcher's own lifetime, and a `rewakeMessage` and `rewakeSummary`.

A new `asyncRewake` hook elsewhere should copy that pair of tests, not just the wrapper. The wrapper keeps a stray 2 from waking anything, and the tests keep the wrapper from drifting.

Related: [isolate headless claude arms with the env switch, not bare mode](isolate-headless-claude-arms-with-the-env-switch-not-bare-mode.md) covers the same `claude -p` surface from the instruction-isolation side. [A stub proves wiring only; a live run proves a cooperative contract](a-stub-proves-wiring-only-a-live-run-proves-a-cooperative-contract.md) applies here: the stub tests pin hov's side, while the exit-2-starts-a-turn behavior belongs to Claude Code.
