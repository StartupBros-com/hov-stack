# Fixture: emilkowalski `break-ui` vs the installed `/break`, 2026-10-07

Planted-defect fixture for the harness-vet of emilkowalski/skills round 3
(`docs/vets/2026-10-07-emilkowalski-skills-harness-vet.md`, dotfiles #1678).
It measures DETECTION: how many latent defects an arm finds in a React
component from source alone, how many honest controls it falsely accuses, and
how good its worst-case dataset is.

## Files

| File | Role | Seen by |
|---|---|---|
| `MemberList.tsx` | One page of workspace members; 11 planted latent defects, 11 controls | every arm |
| `member-list.css` | Its stylesheet; carries the CSS half of the defects and controls | every arm |
| `answer-key.md` | D1-D11, C1-C11, Q1-Q10, the plausibility flag and the scoring rules, plus dated corrections | judges only |
| `run-arms.sh` | Assembles three prompts and runs each arm twice, isolated | operator |
| `parse-results.py` | Turns each `claude -p` JSON result into markdown and one summary line | operator |

## Arms and isolation

Three arms, each run twice with `--model sonnet`, one turn, no tools:

- **bare**: the task plus the component.
- **breakui**: the candidate's `SKILL.md` and `CATALOG.md` inlined as the governing skill, then the task.
- **break**: the installed `/break` (`SKILL.md`, `scenarios.md`) plus the two sibling skills it hands breaks to (`better-typography`, `better-layout`), then the task.

Every run gets its own empty `CLAUDE_CONFIG_DIR`, `--bare` (no hooks, plugins,
CLAUDE.md or operator skills), `--tools ""` and `--no-session-persistence`.
Auth comes from a settings file holding only the `ANTHROPIC_*` env block. With
no tools, `num_turns` is the confound record: every run reported 1.

Blinding: the arm prompts carry no harness-authored label, file name or line
with eval, test, judge, rubric, score, compare, benchmark, candidate or arena.
`grep -c 'answer-key' prompt-*.txt` printed 0 for all three, and `run-arms.sh` now
refuses to launch any arm when a prompt file mentions the key. Two `lean-reader`
sonnet judges scored the six outputs against the key without seeing any prompt.
The key lives beside the component only because no arm has tools. An arm that
gets file tools or a checkout (a rendering arm, a `/break` invocation) must run
from a scratch copy of this directory with `answer-key.md` removed, or it can
read its own grading sheet.

Skill text is inlined rather than invoked because `claude -p --bare` loads no
skills from `CLAUDE_CONFIG_DIR` (verified: 73 input tokens, "doesn't match any
command"); inlining is what a `/break` invocation does anyway.

## Results (n=2 per arm, sonnet, 2026-10-07)

| Run | TP / 11 (judge 1, judge 2) | FA as keyed | FA with C2 reclassified | Q / 10 (judge 1, judge 2) | Plausibility | Cost |
|---|---|---|---|---|---|---|
| bare-1 | 11, 11 | 1 (C2) | 0 | 10, 10 | FAIL (repeated-character URL and bio) | $0.14 |
| bare-2 | 10, 10 (D5 missed) | 1 (C2) | 0 | 10, 10 | PASS | $0.16 |
| breakui-1 | 11, 11 | 1 (C2) | 0 | 9, 9 (Q5 long name under 35 chars) | PASS | $0.18 |
| breakui-2 | 10, 10 (D3 missed) | 1 (C2) | 0 | 9, 9 (Q3 no RTL text) | PASS | $0.19 |
| break-1 | 11, 11 | 1 (C2) | 0 | 10, 10 | PASS | $0.22 |
| break-2 | 10, 10 (D5 missed) | 1 (C2) | 0 | 10, 10 | PASS | $0.22 |

Judge 1's structured field for break-1 said TP 10 and its notes corrected it to
11 (D5 hit through a 150-character URL). Judge 1 gave break-1 Q 9 for "no
emoji"; the output contains an emoji-first name, so judge 2's 10 stands. No
other disagreement. No run declined; every run labelled its findings inferred.

Per arm: bare 10.5/11, breakui 10.5/11, break 10.5/11. A three-way tie. The
only separations are the dataset rubric (bare 10, breakui 9, break 10) and
plausibility (bare failed one run on `x`-repeated filler; both skill arms passed
both runs). Valid unkeyed extras were comparable (6 to 9 per run): the
`javascript:` and scheme-less `href`, duplicate team keys, "0 GB" storage,
page-only diacritic-blind search, the default link colour in dark mode, and the
header's missing `flex-wrap`.

Reading: headless, no-tools sonnet saturates this key regardless of skill. That
is a finding about the fixture's ceiling, not evidence that either skill adds
nothing. See the corrections section of `answer-key.md` for the C2 reclassification
(all six runs correctly reported a real defect) and the D10 visibility note.

## Re-running

```
OUT=/tmp/hv-emil-rerun/arms bash run-arms.sh   # needs the clone at $CAND and the settings file at $SETTINGS
python3 -I parse-results.py /tmp/hv-emil-rerun/arms
```

Override `CAND`, `INC`, `OUT`, `SETTINGS`, `MODEL` and `RUNS` in the environment.
The script refuses to start when a file an arm prompt is built from is
unreadable (a missing skill file would otherwise demote a treatment arm to a
bare arm) and when `OUT` already holds result files, since `parse-results.py`
scores every `*.json` it finds there; the default `OUT` is the original run's
directory, so a re-run on this host needs a fresh one.
Before reusing the key to rank skills, raise its difficulty: the next revision
needs defects that only a rendered layout shows, or interactions between two
rules, and a real C2 control.
