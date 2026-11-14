# pstack re-vet fixture (2026-11-14)

Behavioural fixture behind `docs/vets/2026-11-14-pstack-revet-harness-vet.md`.

## What it is

`repo/` is `invoicer` 1.4, a synthetic Python 3 (stdlib only) invoicing package with
visible tests that pass. `build-base.sh` turns it into a one-commit git repo with a fixed
author and date, so every run starts from the same commit. Its customers ("Acme, Inc.",
"Globex", "Initech", "Umbrella") are invented.

Three short operator-style requests (`tasks/t1.txt` to `t3.txt`), each with a planted trap:

- **t1**, add `summary_to_csv`. The module also holds a compat alias, a public
  `format_summary_v1`, an unreferenced private `_legacy_format_row` and a plugin module
  that looks unused. Scores false deletions and unrequested public names.
- **t2**, "amounts come out a cent low." The cause is `round()` (banker's rounding) in
  `money.to_cents`; `totals.py` only calls it. The best outcome is a fix in `money.py`
  only.
- **t3**, "add deduplication to `send_reminders`." The cause is that `send_reminders`
  iterates `due_invoices + overdue_invoices`, and every overdue invoice is also due. The best
  outcome is the root fix, with no dedupe, and the cause named in the report.

`grader/hidden_t1.py` to `hidden_t3.py` are the hidden checks. Each run is graded in a
temporary copy, so a broken fix fails there even when the visible tests pass.

## Why it is shaped this way

The doctrine under test makes three claims: smallest change, nothing unrequested, and say
so when the request's premise is wrong. Each task gives an agent one way to break one of
them:

- t1 tempts it to clean up code nobody asked about.
- t2 tempts it to patch where the symptom shows instead of where the cause is.
- t3 asks for a dedupe that would hide the cause.

All three tasks are small enough that a run costs cents, so arms can be repeated.

## Arms

`make-runs.sh` builds blinded run dirs (`runs/<random id>/`) that differ only in what the
per-run `CLAUDE_CONFIG_DIR` holds, an optional slash-command prefix, an optional
`--plugin-dir` and the model alias. The arm map is written to a file outside the run root.

| Arm | Definition | Source |
|---|---|---|
| `a1-bare` | `arms/a1-bare/` (empty) | none |
| `a2-pstack` | `plugin.txt` (a `--plugin-dir`), `prefix.txt` (`/pstack:poteto-mode`) | a clone of cursor/plugins at `3dbd22ff`, at the scratch path `plugin.txt` names; not committed |
| `a3-incumbent` | `arms/a3-incumbent/CLAUDE.md` | `# Global Rules` plus lines 3 to 7 (the first five bullets) of the live `CLAUDE.md` on 2026-11-14 |
| `a4-port` | `arms/a4-port/CLAUDE.md` | a3 plus two lines distilled from the pstack leaves and poteto-mode |
| `a5-ponytail` | kept outside the repo | DietrichGebert/ponytail `.agents/rules/ponytail.md` at `2a1fe842` |
| `a6-karpathy` | kept outside the repo | multica-ai/andrej-karpathy-skills `CLAUDE.md` at `2c606141` |
| `a7-smallest` | `arms/a7-smallest/CLAUDE.md` | a3 plus a4's first line |
| `a8-premise` | `arms/a8-premise/CLAUDE.md` | a3 plus a4's second line |
| `a9-trimmed` | `arms/a9-trimmed/CLAUDE.md` | a4 with line 1's trailing delete/flag clause cut; the text the note documents as an override option |

`a5` and `a6` were contender texts used whole as the arm's `CLAUDE.md`. Neither file is
committed. The Karpathy repo has no licence file. Ponytail is not committed either,
because a pin is enough to rebuild it. To rebuild them, fetch each file at its pin into
`<dir>/a5-ponytail/CLAUDE.md` and `<dir>/a6-karpathy/CLAUDE.md` and pass those directories
to `make-runs.sh` as the arm (it accepts a path).

`run_arm.sh` runs one arm with `claude -p` under an emptied environment. Only `PATH` and the
model-route variables pass, by name. `HOME`, `TMPDIR`, the XDG dirs and `CLAUDE_CONFIG_DIR`
point inside the run dir, so no operator skill, plugin, hook, setting or memory loads.
Managed settings apply equally to every arm. Each run is capped at `--max-budget-usd 4`.

## Grading and blinding

`grade.py <root> <out.json>` reads only `runs/<id>/task.txt`, never the arm map. It
grades each run in a temporary copy and records:

- hidden and visible test results;
- the source diff and AST changes (public names added or removed, signatures changed);
- the task-specific fields (`t1_*`, `t2_*`, `t3_*`);
- the final report text and the patch.

Everything it scores is mechanical. The report keyword flags (`t3_report_names_cause`,
`t3_report_flags_premise`) match fixed keyword lists. They undercount differently worded
reports, and the note reads them as such.

`summarize.py` turns a grade file and a run log into the note's primary tables. Per task and
arm it prints hidden passes, unrequested public names, the task's primary metric, source
diff sizes, test lines added per run, and median cost and turns. It ends with each arm's
median cost over `a3-incumbent`'s median on the same model and task, from unrounded
medians. Its t3 classes:

| Class | Meaning |
|---|---|
| A | root fix, no dedupe, cause named |
| A- | root fix, no dedupe, cause not named |
| B | stopped with the cause and evidence and changed no source. `summarize.py` has no code for it: such a run leaves the duplicate reminder in place, fails `hidden_t3.py`'s `test_one_reminder_per_due_invoice` and prints as E. No run in any batch changed zero source lines. |
| B? | hidden checks pass, but neither a root fix nor a dedupe was detected. Never occurred. |
| C | root fix plus a dedupe |
| D | dedupe only |
| E | a hidden check failed |

## The four batches

| Batch | Arms | Launch | Runs |
|---|---|---|---|
| 1 | a1 (calibration launch, 3 at a time), then a2 to a6 (4 at a time); Sonnet t1 to t3 | `launch.sh` | 54 |
| 2 | a7, a8 on Sonnet t2, t3; a1, a3, a4 on Opus t2, t3 | `launch.sh`, 4 at a time | 30 |
| 3 | a9 on Sonnet t1 to t3 and Opus t2, t3 | `launch.sh`, 4 at a time | 15 |
| 4 | a3, a9 plus one bare warm-up per model; Sonnet t1 to t3, Opus t2, t3 | `batch4.sh`: `order-warm.py`, then `launch-seq.sh`, one at a time | 32 |

Batch 4's pass condition is `warm-cache-batch.md`. It was written before the batch launched
and has not changed since. `eval-warm.py` applies it. `cold-runs.py` lists the runs that
wrote more than 18,000 cache-creation tokens, and whether a run on the same model had
finished in the 300 s before each one started. For each arm and task holding such a run, it
prints the median cache creation and cache reads of its runs over the threshold minus those
under it (section 2.4 of the note).

## Files

- `repo/`, `build-base.sh`: the fixture and its one-commit build.
- `tasks/`, `arms/`, `grader/`: requests, arm definitions, hidden checks.
- `make-runs.sh`, `run_arm.sh`, `launch.sh` (parallel), `launch-seq.sh` (one at a time),
  `batch4.sh`, `order-warm.py`: create and run arms.
- `grade.py`, `runlog.py` (with `runs.py`), `summarize.py`, `eval-warm.py`,
  `cold-runs.py`: score and summarize.
- `warm-cache-batch.md`: batch 4's predeclared pass condition.
- `results/`: the recorded run, written once and never overwritten by a reproduction.
  - `grade-b1-3.json`, `grade-b4.json`: `grade.py` output, including each run's report,
    patch and hidden-check results.
  - `runs-b1-3.tsv`, `runs-b4.tsv`: `runlog.py` output. The id-to-arm map plus model, start
    and end times, cost, turns and token counts.
  - `order-b4.txt`: batch 4's launch order.

### Scratch roots and committed copies

| Recorded scratch path | Committed here |
|---|---|
| `/tmp/inv-r2` (batches 1 to 3), `/tmp/inv-r4` (batch 4): `base/`, `runs/<id>/{prompt.txt,config/,repo/,result.json,stderr.txt,...}` | `results/grade-*.json`, `results/runs-*.tsv` |
| `/tmp/pstackvet-r2/map.tsv`, `map4.tsv` | columns 1 to 4 of `results/runs-*.tsv` |
| `/tmp/pstackvet-r2/order4.txt` | `results/order-b4.txt` |
| `/tmp/pstackvet-r2/plugin/pstack` (a2's `--plugin-dir`) | not committed; a cursor/plugins clone at `3dbd22ff` |
| `/tmp/pstackvet-r2/arms-ext/a5-ponytail`, `a6-karpathy` | not committed; rebuilt from the pins above |

### Retention

**Consumers:**

- A reader re-checking a number or a run id in the note.
- A re-vet fired by one of the note's re-audit triggers. It reuses the fixture, the arms
  and the grader.
- The deciding run named for each PARTIAL contender row. It runs a contender through
  `make-runs.sh` and `launch-seq.sh` against `a9-trimmed`.
- The deciding run the note requires before anyone overrides its verdict on the two
  `CLAUDE.md` lines. It reuses `run_arm.sh`, `launch-seq.sh` and `grade.py` with new tasks.

**Delete this directory** when a later vet of the same doctrine supersedes the note, or when
every trigger and PARTIAL row in it has been retired.

**Nothing outside this directory reads it:** no harness test, hook or runtime script.

## Licence and provenance

`repo/`, `tasks/`, `grader/` and the scripts were written for this vet. The a3 text is this
repo's own `CLAUDE.md`. The a4, a7, a8 and a9 lines are distilled from pstack
`principle-subtract-before-you-add` and `principle-laziness-protocol` at `08bd59b3`, and
from `poteto-mode` at `c742dd61` (cursor/plugins, MIT, (c) Lauren Tan). No upstream sentence is
copied whole. No contender text is committed.

## Reproduce

Steps 1, 2 and 4 make real model calls on whatever model route the environment holds. The
recorded batches cost $6.87 (batches 1 to 3) and $2.51 (batch 4).

1. **Batches 1 to 3:**
   1. `bash build-base.sh <root>`.
   2. Once per arm and model: `[MODEL=opus] bash make-runs.sh <root> <map.tsv> <arm> 3 <tasks...>`.
   3. `bash launch.sh <root> 4`.
2. **Score:**
   1. `python3 grade.py <root> <grade.json>`.
   2. `python3 -I runlog.py <root> <map.tsv> > <runs.tsv>`.
   3. `python3 -I summarize.py <grade.json> <runs.tsv>`.
3. **Re-check the recorded numbers without model calls:**
   - `python3 -I summarize.py results/grade-b1-3.json results/runs-b1-3.tsv`
   - `python3 -I cold-runs.py results/runs-b1-3.tsv`
   - `python3 -I cold-runs.py results/runs-b4.tsv`
   - `python3 -I eval-warm.py results/runs-b4.tsv results/grade-b4.json`
   - `python3 -I summarize.py results/grade-b4.json results/runs-b4.tsv a1-bare`
4. **Batch 4:** `bash batch4.sh <fresh root> <map.tsv outside it>`. It ends by printing the
   pass condition's verdict.

Every step-3 command was run against the committed `results/` before commit. Each printed the
numbers in the note: the section 2.2 and 2.3 tables, the section 2.4 cold-run counts and
per-cell deltas, the section 2.5 cells, the test-line counts in section 4.2, and
`OVERALL: FAIL`.

## Changes after the recorded run

Batches 1 to 3 and batch 4 ran with this fixture's `build-base.sh`, `make-runs.sh`,
`run_arm.sh`, `launch.sh`, `launch-seq.sh` and `grade.py` as committed here. Each batch was
started by a session scratch script that called them with absolute paths.

These were written after batch 4 from session scratch scripts with the same logic, so the
analysis can be re-run from the committed files:

- `batch4.sh`, written from the scratch launcher.
- `order-warm.py`. Its output is identical to the recorded `results/order-b4.txt`.
- `eval-warm.py`, which reads the run log rather than each run's `result.json`. Batch 4's
  verdict was first computed by a scratch evaluator. It was written after
  `warm-cache-batch.md` and about two minutes before the last batch-4 run finished.
- `cold-runs.py`, `summarize.py`, `runlog.py` and `runs.py`.

None of them changes what an arm saw.
