# correct vet fixture (2026-10-07)

Behavioural fixture behind `docs/vets/2026-10-07-correct-retro-family-harness-vet.md`.

## What it is

`ledgerline/` is a synthetic Python 3 (stdlib only) invoicing service whose point is its
**git history**: 24 commits, three authors (a human reviewer who fixes, two agent identities
that introduce), fixed dates 2026-08-03..2026-09-29, review-style fix messages ("third time
this month the lists drifted"). The directory here is the working tree at HEAD
(`cdeb5d2c`) without `.git`; `build-fixture.sh` regenerates the whole history with fixed
author and committer dates, so the SHAs in `shas.txt` and `answer-key.md` reproduce
byte-for-byte.

Planted:

- **three repeated classes**: C1 a status list hand-synced across three modules (introduced
  3x, hand-fixed 3x); C2 money passed through float (2x/2x); C3 importing `storage._db` past
  the `repo` boundary (2x/2x);
- **one one-off decoy**: D1 pagination off-by-one, introduced and fixed once;
- **one already-enforced control**: E1 "no `print()` in src/", a `scripts/check.py` lint wired
  into `make check` and CI, never recurred;
- **one judgement-call control**: J1 test naming, a rule with no history.

`AGENTS.md` at HEAD states an unenforced prose rule for each of C1, C2, C3. `make check`
passes at HEAD.

The answer key is `answer-key.md`; the re-plant procedure is `replant.md`. Both stay with the
grader, never with an arm.

## Why it is shaped this way

The task cannot be done from the tree at HEAD. Every class is already fixed there; the only
evidence that it *repeats* is in `git log`, so an arm that does not mine history cannot find
the classes. The controls make a false accusation cost something: classing D1 as a repeat,
re-implementing E1, or inventing a lint for J1 each count as a false class. The highest-level
fix for each class is stated in the key (single source of truth; a Money type or money module;
an unimportable `_db`) so the grader records the level actually landed, not the level
described in prose.

## Arms

`setup-arms.sh` builds three arms x three trials that differ **only** in what the per-arm
`CLAUDE_CONFIG_DIR` holds and a leading slash token:

| arm | loads | prompt |
|---|---|---|
| a1 bare | nothing | task body |
| a2 `/correct` | `config/skills/correct/SKILL.md` (candidate, verbatim) | `/correct` + blank line + task body |
| a3 house doctrine | `config/CLAUDE.md` with two global-rules lines (full scope; root causes) | task body |

The task body is identical (`arms/a1-prompt.txt`, `arms/a2-prompt.txt`; a3's config is
`arms/a3-CLAUDE.md`). `run_arm.sh` is the retro fixture's runner with one change,
`--max-turns 35 -> 60`, because this task commits code rather than only writing a report.
The committed `run_arm.sh` already carries 60, so the `sed` in `setup-arms.sh` is a no-op
against it; it is kept because the recorded run applied it to the retro runner's copy.

Isolation is the fresh per-arm config dir, which removes the operator's skills, plugins,
settings and auto-memory (all live under `CLAUDE_CONFIG_DIR`). The
`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` switch was not used because a3's treatment is itself a
`config/CLAUDE.md`. No `CLAUDE.md` exists in any ancestor directory of the arm paths
(checked after the run, not probed during it).

`run-all.sh` runs the nine arms three at a time; `collect.py` gathers exit code, turns, cost,
commits made and whether each arm's transcript contains the skill phrase ("highest level that
works") or the house phrase ("one guard in the shared function"). `relabel.sh` copies each
arm's final tree and report to `r01..r09` in `shuf` order, writes `key/mapping.tsv`, and
runs the blinding scans: identity strings in reports, eval vocabulary in prompts and paths,
and a counts-only report-content scan (below).

## Grading

Two independent graders scored `r01..r09` blind against the key (`graders/judge-one.json`,
`graders/judge-two.json`, grader two's notes in `graders/judge-two-notes.md`). Each re-ran
`make check` at every head and then re-planted five past mistakes from `replant.md` on a copy
of each tree (`graders/judge-one-tools/plant.py` is grader one's planter). The mapping was
unsealed only after both JSON files were written.

### Blinding

Labels, paths, prompts and identity strings were clean: `/correct`, `CLAUDE.md`, `skill` and
`pstack` occur in no report, the eval vocabulary occurs in no prompt or path, and the mapping
was withheld. Report **content** was not clean for the `/correct` arm, and cannot be: the
skill tells the agent to write a rule-to-enforcer table and to justify the "highest level"
fix, the arm did, and the report says so. Over `tools/scan-words.txt`, r02 has two matching
lines ("the highest level"; "a table pairing each rule with what enforces it"), r05 one (the
same table sentence) and r09 two (the table sentence, plus the substring `score` inside
`underscore`); the other six have none. A grader who knew the candidate's vocabulary could
place those three. The feature that leaks is the measured delta itself (rule table is a
scored column), so it is disclosed here and in the note rather than scrubbed; both graders'
notes record "Rule table" as an axis they scored. `relabel.sh` prints these counts per
report and never fails on them.

## Files

- `stage.sh`: copies `tools/`, `run_arm.sh` and the a2 SKILL copy into the scratch root and
  creates `key/`, `out/`, `cand/`. Run first.
- `build-fixture.sh`, `tools/` (`rep.py`, `fill.py`, `scan.sh`, `scan-words.txt`): rebuild the
  fixture; `scan.sh` is the blinding word scan over fixture content, paths and commit
  messages (exit 0 only on a complete, clean scan).
- `answer-key.md`, `replant.md`, `shas.txt`: sealed key, re-plant procedure, commit SHAs.
- `setup-arms.sh`, `run_arm.sh`, `run-all.sh`, `collect.py`, `relabel.sh`: arms.
- `arm-outputs/r01..r09.md`: each arm's final report; `mapping.tsv`; `runner-validity.json`
  (`runs` is the list from `collect.py`; `mapping_path`, `runner_change`, `blinding_scan`
  and `validity_notes` are manual observations of the recorded run); `timing.json` (per-arm `duration_ms`, `duration_api_ms`, `num_turns`,
  `total_cost_usd`, copied by script from each arm's `result.json`; the note's "wall s" column
  is `duration_ms / 1000` rounded).
- `graders/`: both graders' scores (`judge-one.json`, `judge-two.json`), grader two's notes,
  and `judge-one-tools/`, a frozen copy of what grader one ran from `$R/judge-one/`:
  `plant.py` (the re-planter), `runall.sh` (all nine runs), `rerun.sh` (a partial re-run of
  `runall.sh` for r02, r05 and r09 after a planter fix), `info.sh` (per-run commit summary).
  Grader two's planter was not captured, so its re-plant is not re-runnable from here.
- `evidence/`: the other workflow agents' structured outputs (five readers, three sweep
  readers, the cluster judge, three enforcer verifiers, five claim verifiers) behind sections
  2.2-2.4 of the note.
- `ledgerline/`: the fixture working tree at HEAD.

### Scratch root and committed copies

All paths inside the recorded-run scripts are the scratch root `R=/tmp/hv-correct-2026-10-07`
(`ROOT` in `build-fixture.sh`); change them to reproduce elsewhere. `stage.sh` and
`tools/scan.sh` also read `R`, `FX` and `W` from the environment.

| under `R` | committed here |
|---|---|
| `fixture/` (built, with `.git`) | `ledgerline/` (tree only) |
| `key/shas.txt` | `shas.txt` |
| `key/mapping.tsv` | `arm-outputs/mapping.tsv` |
| `tools/`, `run_arm.sh`, `cand/correct-SKILL.md` | `tools/`, `run_arm.sh`, `arms/a2-correct-SKILL.md` (staged by `stage.sh`) |
| `arms/<arm>/{prompt.txt,config/,repo/,result.json,stderr.txt,tools.txt,report.md}` | `arms/a*-prompt.txt`, `arms/a3-CLAUDE.md`; `result.json` fields in `arm-outputs/timing.json` |
| `runs/rNN/{repo/,report.md}` | `arm-outputs/rNN.md` |
| `out/collect.json` | the `runs` list in `arm-outputs/runner-validity.json`; its other fields are manual |
| `out/timing.json` (new reruns) | `arm-outputs/timing.json` is the recorded run, not overwritten by reproduction |
| `judge-one/` | `graders/judge-one-tools/` |

### Retention

Consumers: a reader re-checking a number or citation in the note, and a re-vet fired by one
of the note's section 6 triggers (it reuses the fixture, key and runner). Delete this
directory when a later vet of the same family supersedes the note, or when every section 6
trigger has been retired. Nothing outside this directory reads it: no harness test, hook
or runtime script imports it. `test_reproduction.py` checks only this fixture tooling.

## Licence and provenance of the candidate copy

`arms/a2-correct-SKILL.md` is a verbatim copy of cursor/plugins
`pstack/skills/correct/SKILL.md` at commit `9511e60321f7` (PR #494, 2026-10-03), MIT, (c) 2026
Lauren Tan; licence text in `arms/LICENSE-pstack`. Kept so the a2 arm is reproducible. It is
**not installed** anywhere in this harness and is not loaded by any session.

## Reproduce

0. `bash stage.sh` (creates `$R/{key,out,cand,tools}` and stages the tooling).
1. `bash build-fixture.sh` (refuses if `$R/fixture` exists; writes `key/shas.txt`; diff it
   against `shas.txt` here).
2. `bash tools/scan.sh` (prints `PASS` and exits 0; a hit or tool error exits 1, a missing
   fixture 2).
3. `bash setup-arms.sh`, then `bash run-all.sh`, then `python3 -I collect.py` (writes
   `out/collect.json`).
4. `bash relabel.sh` (writes `runs/r*/` and `key/mapping.tsv`); hand `runs/r*/` and
   `answer-key.md` + `replant.md` to graders who have not seen `key/mapping.tsv`.
   It refuses an existing `runs/` before touching the mapping, including after a partial
   attempt. Use a fresh scratch root for a rerun; do not reshuffle a previously graded set.
5. `python3 -I gen-timing.py --root /tmp/hv-correct-2026-10-07` (reads the new
   `key/mapping.tsv` and arm results; writes `out/timing.json`). Keep rerun evidence separate
   from `arm-outputs/`: those committed files describe the recorded run, not the rerun.

Tooling checks without model calls: `python3 -I test_reproduction.py`. These use synthetic
input to check failure paths, not as evidence of arm behavior. To re-check the recorded timing
rows, pass `--mapping arm-outputs/mapping.tsv` and a fresh `--output` path to `gen-timing.py`
while the recorded arm results still exist in the scratch root.

Steps 0-2 were smoke-tested after the review fixes under a fresh root with `ROOT`
redirected: 24 SHAs identical to `shas.txt`, tree identical to `ledgerline/`, scan `PASS`;
the scan exits 2 on a missing fixture and 1 on a planted hit.

## Changes after the recorded run

The recorded run used the scripts as committed at `f65cce03`. Review of PR #1684 found that
the committed layout could not reproduce without hand staging and that two scripts could pass
vacuously. Changes since, none of which alters what an arm sees:

- `stage.sh`: new. The run was staged by hand.
- `tools/scan.sh`: requires `$FX/.git` and the word list, treats a grep error as failure,
  prints `PASS`/`FAIL` and exits with it. The recorded version echoed grep's status and
  exited with `wc`'s, so a missing fixture "passed".
- `relabel.sh`: added the counts-only report-content scan. A later fix rejects empty or
  missing word lists and treats grep errors as failures across every scan. Hits remain
  observations, not failures. It now refuses an existing `runs/` before truncating the
  mapping, preventing retries from nesting new repositories under old labelled trees.
  This changes no recorded arm output.
- `collect.py`: creates `out/` before writing.
- `arm-outputs/timing.json`: new, generated by a session scratch script from the recorded
  `result.json` files. `gen-timing.py` now commits its extraction logic with configurable
  paths and mapping validation. Re-execution against the recorded sources matched every
  `runs` row; the original snapshot and its provenance string are unchanged.
- `test_reproduction.py`: new, fixture-local checks for timing extraction and scan failures.
- `evidence/*.json`: the operator's home prefix replaced with `~` in 12 strings across 8
  files (hygiene; every file re-parsed as JSON afterwards).
- `run-all.sh`: unchanged. A reviewer asked for a hard-fail on a failed arm; `run-all.sh`
  prints each arm's rc and `collect.py` records the error and exit code, so a failure is
  visible, and all nine recorded arms exited 0.
- `run_arm.sh`: exits nonzero when the invocation produced no usable result (`claude` exited
  nonzero, `result.json` is not a non-error envelope, or `result` is empty; dotfiles#1690).
  The `EXIT_CODE=` line in `stderr.txt` and `tools.txt` are written as before, so the rc
  `run-all.sh` prints is now the invocation's rather than the tool-log pass's. The recorded
  run predates this; its nine `EXIT_CODE=0` lines are unaffected.
