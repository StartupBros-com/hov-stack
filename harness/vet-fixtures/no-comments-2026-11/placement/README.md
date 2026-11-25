# Placement test (2026-11-24)

The experiment behind section 7 of `docs/vets/2026-11-24-no-comments-harness-vet.md`. It asks
one question: when a later agent changes code that carries a design decision, does it keep the
decision, and does that depend on where the decision is written down?

`prereg.md` holds the arms, tasks, measures and decision rules. It was written before the first
run; `results/launch.stamp` carries its hash and the launch time.

## What it is

Seven copies ("arms") of the parent fixture's clean `tally` repo. The code is the same in every
arm. Only the place where the 14 decisions are recorded differs:

| Arm | Where the 14 decisions are recorded |
|---|---|
| `comment` | a comment at the code |
| `none` | nowhere |
| `tests` | `tests/test_decisions.py`: a test per decision, the reason in its docstring |
| `doc` | `docs/decisions/*.md`, one pointer line in the README |
| `claudemd` | the repo's `CLAUDE.md` |
| `history` | commit message bodies only |
| `stale` | as `comment`, but three comments are false about the code |

Seven tasks (`tasks.json`): three trap tasks whose obvious implementation breaks a decision the
shipped tests do not catch, two conflict tasks that ask for a decision to be reversed, two
controls. Each arm is a fresh git repository, so no arm can read another arm's record.

177 runs: 135 on `claude-sonnet-5-5` (3 per arm per task; `stale` runs the trap tasks only) and
42 on `claude-opus-5-5` (trap tasks, 2 per arm). Total cost $12.51. Every run used the parent
fixture's `run_arm.sh`: bare Claude Code, empty environment, no user `CLAUDE.md`, no plugins.

## Files

- `build_arms.py`: builds the seven arm bases from the clean variant.
- `test_decisions.py`: the `tests` arm's record.
- `verify_bases.sh`: builds the bases and checks them (same code in every arm, `make check`
  green, every probe passing, no decision text outside the arm's own record).
- `probes.py`: the hidden checks. They stay outside the run root.
- `probe_validity.py`: shows, before any run, that a naive change for each trap task delivers
  the request, keeps `make check` green and fails the hidden check, and a careful change passes.
- `make_runs.py`: creates blinded run dirs and the arm map.
- `grade.py`, `report.py`: grade every run and print the tables.
- `judge_prep.py`, `judge_join.py`: blind packets for the conflict-task judges, and the join of
  their verdicts. The judges were two workflow agents that saw only the request and the final
  message.
- `record_upkeep.py`: post hoc, not in `prereg.md`. Whether the record was updated when the
  change altered a decision.
- `session_consult.py`: counts, in the Claude Code transcripts on a host, how many code-editing
  sessions looked at commit titles, commit message bodies, pull-request or issue text, the
  session index or a decisions doc before their first edit. Each count is given for the
  session's own commands and with its subagents' commands added. It prints counts only,
  unless `--sample` is given.

## Running it

```bash
F=harness/vet-fixtures/no-comments-2026-11
bash $F/build-base.sh /tmp/<base-root>
python3 $F/tools/reference_variants.py /tmp/<base-root>/base /tmp/<variants>
bash $F/placement/verify_bases.sh /tmp/<arms> /tmp/<variants>/ideal
ALL=comment,none,tests,doc,claudemd,history
python3 $F/placement/make_runs.py /tmp/<arms> /tmp/<mapdir>/map.tsv sonnet 3 $F/placement/tasks.json $ALL,stale fileorder,always,addrule /tmp/<runs>
python3 $F/placement/make_runs.py /tmp/<arms> /tmp/<mapdir>/map.tsv sonnet 3 $F/placement/tasks.json $ALL pending,negative,version,cats /tmp/<runs>
python3 $F/placement/make_runs.py /tmp/<arms> /tmp/<mapdir>/map.tsv opus 2 $F/placement/tasks.json $ALL,stale fileorder,always,addrule /tmp/<runs>
bash $F/launch.sh /tmp/<runs> 7
python3 $F/placement/grade.py /tmp/<runs> /tmp/<mapdir>/map.tsv /tmp/<graded>.json /tmp/<arms>
python3 $F/placement/report.py /tmp/<graded>.json [/tmp/<judged>.json]
```

Keep the map in a directory of its own, outside the run root, so a run cannot see which arm it
is. The grader marks a run `left_repo` when a tool input names that directory or the arms
directory. No run did.

Re-run on 2026-11-24 from this folder: `verify_bases.sh` rebuilt and passed all seven bases,
and `grade.py` regraded the 177 runs with no field different from the grades behind
`results/`.

## Results

- `results/map.tsv`: run id, arm, task, repetition, model.
- `results/runs.tsv`: one row per run: delivered, `make check`, decision kept, each probe,
  cost, turns, what the agent asked for and what it was shown, and the two judges' verdicts on
  the conflict tasks.
- `results/tables.txt`: `report.py` output, per model.
- `results/judged.json`: the judges' verdicts with the phrase each one quoted.
- `results/record-upkeep.txt`: `record_upkeep.py` output. The eight rows it lists for a read
  by eye were read: each is a rewritten sentence that is true of the new code, or a line about
  a different decision.
- `results/session-consult.txt`: `session_consult.py` output on the operator's workstation. A
  sample of each class's matches was read by eye before the counts were used (section 7.3 of
  the note).
- `results/launch.stamp`: launch time and the hashes of `prereg.md` (as `PREREG.md`),
  `tasks.json` and `probes.py` at launch.

Known over-count in `runs.tsv`: `asked_history` is true for any `git log`, `git show` or
`git blame`. The two runs it marks (`25aa560a`, a Sonnet `history` run, and `5928d301`, an Opus
`tests` run) ran `git log --oneline`, which prints titles only. `shown_history`, which looks for decision text
in a tool result, is false for every run. No `history`-arm run read a commit body.

The run dirs (transcripts, diffs) were kept in scratch and are not committed. The real-comment
audit that section 7 also reports sampled the operator's private repos; only its counts are
public, in the note.

## Limits

- The fixture, its 14 decisions, the probes and the task intents have one author, who also ran
  the test. This shows how the mechanism behaves on a 300-line Python repo. It does not measure
  any real repo.
- Three trap tasks. `fileorder` turned out weak: the function that needs sorted rows is called
  only from the test suite, so dropping the sort is arguably correct.
- The conflict tasks ran on Sonnet only, 6 runs per arm.
- A partial table (43 of 177 runs) was printed while the grader was being tested. The rules
  were frozen before launch and nothing was changed after that look.
