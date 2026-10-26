# reminder-diet

Leaves out a task reminder that repeats, word for word, the last one the same
loop was sent.

A Claude Code mod. Every few turns in which no task tool ran, Claude Code injects
a task reminder ("The task tools haven't been used recently ..."), followed by the
current task list when there is one. The engine sends it again and again whether
or not anything changed, and each copy stays in the context until the next
compaction, which it brings sooner.

reminder-diet lets the engine render each task reminder, then compares that text
with the last task reminder the same loop (the main conversation, or one
subagent) was sent:

- **The same text**: the reminder is left out of the request. The model already
  has that exact copy in its context.
- **Different text, or the loop's first**: it goes through as the engine made it,
  and becomes the one later reminders are compared with. A task list that changed
  is always sent.
- **After a compaction or `/clear`**: the loop's comparison starts over, so the
  next reminder goes through, because the earlier copy is no longer in context.

Every other injected message (instructions, listings, mentioned files, the
background-session nudges) passes through untouched. The transcript keeps the
engine's record of every reminder; only the request leaves the repeat out.

## Why

In this harness's transcripts over the 14 days to 2026-10-04 there were 27,432
stored task reminders across 3,509 loops. 19,794 of them (72%) carried a task
list identical to the previous reminder in the same loop: about 241M characters,
roughly 69M tokens of context at 3.5 characters a token, most of it in
long-running loops (one loop was sent 995). That count compares the stored rows
(the task list the engine renders from), not the rendered text, so the mod's
own drop rate is what live use will show.

The saving is context, not price: the reminders sit in the cached prefix, so
each repeat costs a cache write once and a cache read on every later request,
and more to the point it fills the window and brings compaction sooner.

How it is judged: TaskCreate and TaskUpdate calls per loop over the 14 days
after wiring, against the 14 days before. A drop would mean the repeated nudge
was doing work, and the mod comes back out: drop its path from
`CLAUDE_CODE_PLUGIN_DIRS` in `settings.json`. As with the other mods, the
operator's verdict from real use decides; there is no fixed threshold.

## What `claude plugin validate` reports

```text
./register.ts hooks: prompt.attachment, session.compact, prompt.context
./register.ts calls: nothing on $
```

## How it decides

- The engine asks `prompt.attachment` once per attachment and keeps the answer
  for the process, so a reminder left out stays out of every later request and
  the prompt cache is not disturbed.
- The comparison is on the text as rendered beneath the mod, so a plugin beneath
  that rewrites the reminder is compared on what the model would read. A reminder
  a plugin beneath already left out is not remembered.
- Matching is by attachment type name: `task_reminder` (this build's
  transcripts) and `todo_reminder` (the API's docs). A build that renames the
  reminder again makes the mod a no-op until the name is added.
- At most 256 loops are remembered at once; past that, the least recently
  reminded loop is forgotten and its next reminder goes through.

## Limits

- **Re-asking.** On resume the engine asks again for every attachment, and the
  mod starts with nothing remembered, so asking in conversation order reaches
  the same answers. A plugin that calls `$.ui.invalidate("prompt.attachment")`
  mid-session would re-ask with the latest text already remembered, and then
  every copy of an unchanged reminder, the first included, would be left out
  until the list changed. No mod wired in this harness calls it.
- **`/rewind`** to before a reminder leaves the mod remembering a copy the
  conversation no longer holds, so every identical reminder after it is left
  out until the task list changes or the loop compacts or clears. The engine
  gives a mod no rewind signal; rewinding is something a person does at the
  terminal, and what it costs is the nag, not the task list, which reappears
  with its next change.
- **The `/clear` signal** is the engine computing the context blocks again
  (`prompt.context`), which carries no loop id. Main starts over on every such
  computation; if it also fires for subagent conversations, main only sends an
  extra reminder, never fewer.

## Install

```text
claude --plugin-dir ./reminder-diet
```

The harness loads it in every session through `CLAUDE_CODE_PLUGIN_DIRS` (see
`../README.md`).

## Check

```text
claude plugin validate ./reminder-diet
claude plugin test ./reminder-diet
```
