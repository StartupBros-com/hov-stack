# retro vet fixture (2026-09-20)

Behavioral fixture behind `docs/vets/2026-09-20-retro-harness-vet.md`.

## What it is

`orderflow/` is a synthetic TypeScript service carrying **nine planted
environment defects** and **three honest controls**, plus `session-log.md`, a
transcript of a coding session that trips most of them. The task given to every
arm is identical: read the transcript and the repo's steering files, then say
what to change so the next session goes better.

The answer key is `answer-key.md`. It stays with the grader, never with an arm.

## Why it is shaped this way

Three of the nine defects sit **outside** the candidate skill's own seven-category
taxonomy (D8 actively-wrong instruction, D9 cross-file contradiction, and the
generated-file dependency framed as data loss rather than as "navigation"). A
fixture built only from a candidate's own category list measures whether the
candidate can recite itself, not whether it helps.

The three controls exist because a false accusation has to cost something:

- **T1** a genuine judgement call that must NOT be handed to a linter,
- **T2** a working CI job, so "this repo has no guardrails" is a wrong answer,
- **T3** an accurate, load-bearing navigation pointer that must not be cut.

## Arms

`setup-arms.sh` builds three arms that differ **only** in a leading slash token:

| arm | loads |
|---|---|
| a1 | nothing (bare control) |
| a2 | the candidate, `retro` |
| a3 | the incumbent, `rent-check` |

`writing-for-agents` is placed in **all three** config dirs, because `retro`
step 1 calls it. Giving it only to the candidate's arm would be differential
access, which is a confound, not a result.

Each arm runs under its own `CLAUDE_CONFIG_DIR` via `run_arm.sh` (copied from
`experiments/seo-arm-fixture-2026-09-05/`), so no arm inherits the
operator's live skills, plugins or settings. `run_arm.sh` also writes a
`tools.txt` per arm; read it before comparing anything, because a tool one arm
reached and its siblings did not is the confound. Its exit status is the
invocation's (dotfiles#1690): 0 only when `claude` exited 0 and `result.json`
is a non-error envelope with a non-empty result; it says nothing about the
result's quality.

## Blinding

Arm directories are `a1`/`a2`/`a3` and outputs are relabelled `r01..r09` in
shuffled order before grading. No harness-authored path, label or prompt line
contains `eval`, `judge`, `rubric`, `score`, `compare`, `benchmark`, `candidate`
or `arena`. The skills under test keep their own names and wording — redacting
those would measure a hobbled skill.

`arm-outputs/` holds the nine graded reports; `arm-outputs/mapping.tsv` is the
label-to-arm key, withheld from graders.

## Re-running

```
bash build-fixture.sh     # writes /tmp/hv-retro-<date>/fixture
bash setup-arms.sh        # builds the three arms
bash run_arm.sh <arm-dir> # one arm
```

## Known limits of this fixture

Recorded because they bound what the numbers can support:

- **D7 was mis-planted.** It assumed a bloated `CLAUDE.md`, but the file is 36
  lines — inside every size threshold. An arm that declined to raise it was
  right, so D7 cannot be scored as a miss.
- **T2 is weaker than intended.** The fixture's CI *exists* but cannot pass
  (no `tsconfig.json`, no spec files, `@eslint/js` absent). Arms that ran the
  gates found real breakage the key never planted. That is a true finding, not
  a tripped trap, but it means T2 no longer cleanly separates arms.
- n=3 per arm, one fixture, sonnet. Enough to refute a large claimed effect,
  not enough to resolve a small one.
