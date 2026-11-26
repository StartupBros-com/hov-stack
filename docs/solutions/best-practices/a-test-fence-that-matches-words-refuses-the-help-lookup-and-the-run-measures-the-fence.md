---
title: "A test fence that matches words refuses the help lookup too, and the run then measures the fence"
date: "2026-11-25"
category: best-practices
module: headless-arm-side-effect-fence
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "Fresh headless sessions are run behind a PreToolUse hook that refuses commands with real effects (messaging, restarting, posting, writing), and the score is whether a session tried one of those commands"
  - "A refusal rule is about to be widened from a command pattern to the words themselves because one form of the command slipped past it"
  - "Two models, or two wordings of a rule, are compared on how often sessions reach a command the fence refuses"
  - "A fenced run missed a pass line set beforehand and the refusal log has not been read yet"
tags: [headless, claude-p, eval-arms, pretooluse-hook, test-fence, false-positive, rule-wording, measurement]
related_components:
  - hov
  - claude-global-instructions
---

# A test fence that matches words refuses the help lookup too, and the run then measures the fence

## Context

hov 0.1.14 (PR #910, tracked in issue #902) gave sessions two commands that reach a finished session: `hov ask` and `hov send`. The acceptance run asked whether fresh sessions would use them: 24 headless sessions, two wordings of the peer-lookup rule, two models, six sessions per cell. Each session was told to get one answer from four finished sessions. A session counted as having reached one when it ran `hov ask` or `hov send` naming one of the four.

Nothing in such a run may really be asked, sent or restarted, so every session ran behind a fence: a PreToolUse hook, passed with `--settings`, that refused the calls with real effects and logged every decision. For the two commands under test its rule was:

```python
if re.search(r"\bhov\b", cmd) and re.search(r"\bask\b", cmd):
    deny("hov ask is switched off for this run; nothing was asked.")
```

That rule was itself a fix. An earlier pattern of the form `\bhov\s+send\b` had let through a call that quoted the tool's full path, so the match was widened to the two words wherever they sat in the command.

The line set before the run was 5 of 6 on each model. The result:

| | rule as on main | fuller rule |
|---|---|---|
| default model | 6 of 6 | 6 of 6 |
| Opus | 2 of 6 | 0 of 6 |

The refusal log explained the Opus row. Nine of the twelve Opus sessions had first run `hov ask --help`, were told the command was switched off, and stopped there. The widened rule refused the help lookup for the command under test. The two models learn a new command by different routes: the default model opened the hov skill in 12 of 12 sessions and Opus in 6 of 24 across both runs (the count is on issue #844), and the fence closed only the `--help` route. That is the likely explanation for the row, and it is not a proven one: this record does not say whether the default model's sessions also ran help lookups, and the size of any real difference between the two models is unknown. What the log does settle is that the row cannot be read as a measure of either rule wording, because nine of its twelve sessions were stopped by the fence before the wording could matter.

One follow-up was declared after the first run was scored and before it started: 12 Opus sessions behind a copy of the fence that let a command through when every use of the two commands in it was a `--help` lookup at the end of a statement. It scored 3 of 6 and 5 of 6, and it still refused too much in 4 of the 12 sessions, because it was still a word match with one carve-out:

- a documentation search for the string `hov ask`;
- a help lookup chained with such a search;
- a help lookup run after a `cd` into a folder whose name contained the word;
- `hov ask --help > file`, which the carve-out's "end of a statement" test did not cover.

Two 12-session runs on that model therefore produced no clean measure of the wording. The rule change that shipped (PR #915) was the smallest edit, and that edit was never run on its own.

## Guidance

1. **Refuse the call that has the effect, found by parsing.** Split the command into its calls, and refuse a call only when its first word is the tool and its second is an effect subcommand, with no `--help` or `-h` among its arguments. A help lookup, a search for the command's name, a path containing the word and text that quotes the command are not calls to it.
2. **When a form slips past, add it as a case and teach the parser. Do not widen to words.** The quoted full path that started the widening is one `shlex` call away from being handled (see the example). A word match closes every disguise at once, and it closes the lookups a session makes on the way to the command as well.
3. **Put a second layer where the effect happens, so the hook does not have to be the only barrier.** No command parser sees a subcommand held in a variable or a call made from inside a script file. This run already had the second layer: a scratch state folder (`HOV_STATE_DIR`), and a stand-in that starts nothing both as `HOV_CLAUDE_CMD` and as the `claude` first on `PATH`. With that in place the hook's job is to count attempts and to stop what the stand-ins cannot, which leaves it free to be narrow.
4. **Test the fence in both directions, starting from the command under test.** Harmless neighbours that must pass: its help lookup (plain, piped, and redirected to a file), a documentation search for its name, a statement that mentions a path containing the word, and text that quotes it. Disguises that must be refused: full path, quoted path, through an interpreter (with and without an option of its own, as in `python3 -I <script>`), behind an environment assignment, in a loop, on a second line, in a command substitution, inside `sh -c`, and after a help lookup in the same command. A self-test that records a refusal of a harmless command as "known" is recording the defect.
5. **Read the refusal log before reading the score.** List the refusals by reason, and for each session that did not reach the outcome, find the last call before it gave up. A session whose last call was a refused harmless command is void for the outcome. It is not a failure.
6. **Pilot one free-form session per cell before the counted run.** This run's setup check told its session exactly which five steps to take, so it could show that the fence and the environment were wired, and it could never show a session reaching for `--help`.
7. **Say beforehand what a fence-caused void buys.** No rerun had been declared for the first run, so its Opus row could only be reported as an instrument flaw, and the follow-up had to be declared as a separate run with its own line.

## Why This Matters

A fence that refuses too little is the failure everyone tests for, because a missed refusal sends a real message. A fence that refuses too much is silent: the session reads "switched off for this run", reports the command as unavailable, and scores as a session that did not try. Nothing in the score separates that from a rule wording that failed to send the session to the command.

The damage is not spread evenly, which is what makes it look like a result. Here it fell on the model that looks a command up before using it, so a difference in how two models learn a command was scored as a difference in how often they "reached" it: 12 of 12 against 2 of 12. With help lookups let through, that model reached the commands in 8 of 12 sessions while the fence still refused too much in 4 of them. So the fence is the likely cause of most of the gap, and how much of it is a real difference between the models was never measured.

The self-test did not catch it because it tested one direction. It passed, and it held no help lookup for the two commands until the follow-up. The follow-up's self-test then added four help-lookup cases (one piped, two chained with a second help lookup, one through the script path) and none of the shapes that were refused in the counted sessions: no search, no `cd`, no redirect to a file.

## When to Apply

- Building or reusing a fence for any run where the outcome is "the session tried command X" and X is refused.
- Reviewing a fenced run's result before it is quoted: ask for the refusal log by reason first.
- Any time a fence rule is edited after something slipped past it.

It does not apply to a fence whose refused commands are not the behaviour being measured, such as a blanket refusal of GitHub writes in a run that scores a closing report. Over-refusal there costs little, and a broad match is the safer choice.

## Examples

A parser that refuses only the effect. It was checked on 22 commands and got all 22 right. Ten were harmless: the six neighbours in guidance 4, another subcommand of the tool, two help lookups in one command, a search chained with a help lookup, and a help lookup through an interpreter that takes an option. Twelve were effects: the plain call, the nine disguises in guidance 4 (the interpreter one both ways), and a question that contains the text `--help`. The words-anywhere rule got 13 right: it refused 9 of the 10 harmless ones.

The parser was written after the runs and has not been used in a counted session. Its first draft let `python3 -I <script> send` through, because the interpreter's own option sat where the script was expected. That case was added and the parser taught to skip such options, which is guidance 2 applied to the example itself.

```python
import os, re, shlex

EFFECT = {"ask", "send"}
SEPARATORS = {";", "&", "&&", "|", "||", "(", ")", "|&", ";;"}
PREFIX = {"env", "command", "exec", "time", "nohup", "do", "then", "else", "{", "!",
          "python3", "python", "bash", "sh"}

def effect_calls(cmd, tool="hov"):
    """The calls in a shell command that run one of the tool's effect subcommands.
    An unparseable command comes back whole, so the caller refuses it."""
    lex = shlex.shlex(cmd.replace("\n", " ; ").replace("`", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        return [cmd]
    calls, argv = [], []
    for tok in tokens + [";"]:
        if tok not in SEPARATORS:
            argv.append(tok)
            continue
        while argv and (re.fullmatch(r"\w+=.*", argv[0]) or os.path.basename(argv[0]) in PREFIX):
            if os.path.basename(argv[0]) in {"bash", "sh"} and argv[1:2] == ["-c"]:
                calls += effect_calls(" ".join(argv[2:3]), tool)  # the quoted program of `sh -c`
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                argv = argv[1:]  # the prefix word's own options, as in `python3 -I <script>`
        if len(argv) >= 2 and os.path.basename(argv[0]) == tool and argv[1] in EFFECT:
            if not {"--help", "-h"} & set(argv[2:]):
                calls.append(" ".join(argv))
        argv = []
    return calls
```

| Command | Words anywhere | Parser |
|---|---|---|
| `hov ask --help > /tmp/x/help.txt` | refused | passes |
| `rg -n "hov ask" docs/ harness/` | refused | passes |
| `cd /tmp/x/notes-ask-me && hov ask --help` | refused | passes |
| `"/opt/tools/hov/scripts/hov" send --to worker-a "text"` | refused | refused |
| `python3 -I /opt/tools/hov/scripts/hov send --to worker-a "text"` | refused | refused |
| `hov ask --help; hov ask worker-a "q"` | refused | refused |
| `hov ask worker-a "what does --help print?"` | refused | refused |
| `c="hov ask"; $c worker-a "q"` | refused | **passes** (left to the second layer) |

The last row is the price of parsing, and the reason guidance 3 is not optional.

## Related

- `docs/solutions/best-practices/isolate-headless-claude-arms-with-the-env-switch-not-bare-mode.md`: another way a headless arm's envelope changes the measurement; the fence is part of the same envelope.
- `docs/solutions/best-practices/agent-bakeoff-eval-discrimination-failure.md`: prove the instrument can show the result before trusting the score.
- `docs/solutions/best-practices/make-test-assertions-falsifiable-by-the-defect-they-guard.md`: the self-test rule in guidance 4 is this, applied to the fence.
- `docs/solutions/best-practices/measure-always-on-rule-wording-on-a-closing-report-fixture.md`: scoring rule wording in fresh sessions; that fixture has no fence, so it does not meet this problem.
- Issue #902 (the run's results) and PR #915 (the rule change that shipped).
