# read-ceiling-pager

Turns a Read that would fail the token cap into a partial read that says where
to continue.

A Claude Code mod. The Read tool refuses a window whose content counts past the
cap (25,000 tokens, or `CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS`) with an error
telling the model to use `offset` and `limit`. The engine already paginates a
Read with no limit; an explicit window that is too big still fails, and every
such failure costs a round: the call, the error, a smaller retry. In this
harness that was 147 failed Reads across 20 sessions in one week (papercut,
2026-10-03), after a guard hook that already shapes the retries.

read-ceiling-pager runs before the Read:

- **A window the estimate says is over the cap is clamped** to the largest
  prefix of it that fits. The model gets the engine's own numbered lines for
  that prefix, plus one context line: the file's line count, the lines
  returned, the lines of the window left, and the `offset` and `limit` that
  continue. The line is built from the engine's own record of the lines it
  returned, so it stays right when a hook beneath the mod shortens the window
  further; an explicit window that comes back short for any other reason gets
  the same line. Nothing the mod clamps comes back partial without saying so.
- **A window that fits, a Read with no limit, a PDF page range, a path the mod
  cannot stat or read, and a file over 4 MiB** (the most a mod may read at
  once) pass through untouched, a refused PDF page range included.
- **A Read the engine refuses anyway** (the estimate is an estimate; the engine
  counts exactly) gets a window to retry with, computed from the engine's own
  numbers in the error and no larger than the read-ceiling-chunk hook admits
  after a first refusal of the file (below). The count is also spread over the
  window's characters, so the advice stops before a line far longer than the
  rest. When the first line alone outweighs its share, the retry is that line
  alone: density varies from line to line, so only the engine refusing a
  one-line window shows a line is over the cap, and that refusal's note points
  at Grep or a Bash extract. So does a window whose lines average past 80% of
  the cap each, where the count leaves no retry window with room to spare.

## How the estimate works

Characters divided by 3.5 per token, with the 8-character line-number prefix
the Read tool adds to every line and a long line counted whole, as the engine
counts it (one 450,000-character line came to 300,008 tokens at `limit: 1`,
probed 2026-10-04), aiming at 90% of the cap. For typical code
and English prose 3.5 is a conservative figure, so the clamp errs toward a
slightly smaller page than would fit, at the cost of one more continuation.
Dense text (minified JSON, numeric data, CJK) can run below the 3.15
characters per token the 90% aim tolerates (that probe's repeated `ab ` ran at
1.5); there a window the estimate passes
can still be refused, and the refusal path above names the window that fits. A
file whose whole size plus prefixes fits is not read by the mod before the
call; a bigger one is read once per Read that needs the measure. A refused
Read the mod let through unread is read once after the refusal, to count the
lines the engine actually returned before it gives a window.

## Install

```text
claude --plugin-dir ./read-ceiling-pager
```

Or from a marketplace once it is published there:

```text
/plugin install read-ceiling-pager@hov
```

## Options

None. The cap follows the engine's own `CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS`
when that is set; this harness sets it to 50,000.

## What it can touch

`claude plugin validate ./read-ceiling-pager` prints the authority:

```text
hooks: tool.call{tool=Read}
calls: $.env.get, $.fs.read, $.fs.stat
```

It reads the file a Read names (and only when the file is big enough to matter),
reads one environment variable by literal name, runs no programs, makes no
network calls, calls no model and draws nothing. It changes one thing about a
Read call: its `limit`, downward, and it says so in the result.

## Alongside the read-ceiling-chunk hook

The harness's `read-ceiling-chunk.js` PreToolUse hook denies a retry that would
fail again, naming the window that fits, from the failures already recorded. It
leaves a first attempt alone on purpose, and its header says why it denies
rather than rewrites: a limited Read returns numbered lines and nothing else,
so a silently clamped window hands the model a partial file it cannot tell is
partial, and the first attempt's error is what teaches the agent the ceiling
exists. This mod clamps the first attempt, but not silently: its context line
comes back with the result, naming the file's length, the lines returned and
the call that continues, which tells the model about the ceiling without a
failed round.

The two work together. A clamped Read that succeeds never feeds the hook's
store. One the engine refuses anyway is an ordinary failure: the hook records
it and guards the retry as before. The mod's note names a retry window no
larger than the one the hook admits after one refusal (its 0.8 headroom on the
error's own count, at most half the window that failed, and never more than
1,000 lines), so following the note after a first refusal is not denied. After
repeated refusals of the same file the hook's window can be smaller still; then
it denies once, and its denial names the window.
When the hook runs an oversize call it has denied three times at its own
window, the result is shorter than the mod asked for; the mod's line comes from
the engine's record of the lines returned, so it names those lines and where to
continue.
