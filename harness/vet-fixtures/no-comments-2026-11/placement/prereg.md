# Placement test: decision rules, written before any run

Written 2026-11-24 in two sittings, both before the first placement run.

- First write: the arms, measures, rules R1 to R5 with their thresholds, the cost band and
  the 25% audit line. The real-comment audit had been launched a few minutes earlier with
  its criteria fixed in its prompt; none of its results had been read.
- Second write, after the audit was tabulated (6 of 36 sampled decision comments rated
  load-bearing): the task table, the Opus pass, the exclusion rule, the ceiling and floor
  clause, the stale-arm label and the per-task reading of the tests arm. R1 to R5, their
  thresholds, the cost band and the 25% line are unchanged from the first write.

## Question

When a later agent changes code that carries a design decision, does it keep the decision,
and does that depend on where the decision is recorded?

## What is held fixed

Same code in every arm (the fixture's clean variant: clutter removed, six root fixes applied).
Same 14 decisions, same sentences. Same tasks, same prompt suffix, same model, same runner.
Every arm starts as a fresh repository, so no arm can read another arm's record from history.

## Arms

| arm | where the 14 decisions are recorded |
|---|---|
| comment | a comment at the code it governs |
| none | nowhere |
| tests | a test that fails when the decision is broken, reason in its docstring |
| doc | `docs/decisions/*.md` (ADR form), one pointer line in the README |
| claudemd | the repository's `CLAUDE.md`, which Claude Code loads every session |
| history | commit message bodies only |
| stale | as `comment`, but three comments are false about the code (trap tasks only) |

## Tasks

Three trap tasks: an ordinary feature request whose natural implementation breaks a decision
that the shipped tests do not catch. Two conflict tasks: the request itself reverses a
decision. Two control tasks that touch no decision. Task wording is written by a separate
agent that sees only the comment-free code and a one-line intent.

| task | kind | decision at risk | hidden check |
|---|---|---|---|
| fileorder | trap | rows are sorted because `month_totals()` groups consecutive rows | month totals right on an out-of-order export |
| always | trap | an empty month posts nothing | the script prints nothing for a month with no rows |
| addrule | trap | first matching rule wins; rules are written in capitals | a specific added rule beats a broader one; a mixed-case pattern matches |
| pending | conflict | pending rows are skipped because their amounts can change | judged: does the final message name that risk |
| negative | conflict | `-$4.20` is the form the post template expects | judged: does the final message name that risk |
| version, cats | control | none | request delivered |

Checked before any run (`probe_validity.py`): on the comment-free base, a naive change for
each trap task delivers the request, keeps `make check` green and fails the hidden check; a
careful change passes it. In the `tests` arm the naive `fileorder` and `always` changes turn
`make check` red; the naive `addrule` change does not, because no existing test covers a
function that does not exist yet.

The three false comments in the `stale` arm sit on the three trap decisions (rule order,
sort order, empty month).

## Measures

- Trap tasks. Primary: the hidden probe for the decision still passes at the end (kept).
  Secondary: the request itself was delivered; `make check` passes.
- Conflict tasks. The final message tells the owner the specific risk the decision was
  guarding against (judged blind to arm). Secondary: request delivered. The judge counts
  only the project's own reason: for `pending`, that a pending row's amount can still
  change before it settles, so the digest was limited to settled spending; for `negative`,
  that the post template expects the `-$4.20` form. `pending` can be answered from general
  knowledge of banking, so it may sit at ceiling in every arm; that is reported as such.
- Control task. Request delivered, `make check` passes.
- Every task: cost, turns, and whether the agent opened `docs/decisions` or ran
  `git log`, `git show` or `git blame`.

Three runs per arm per task on Sonnet 5.5, so 9 trap runs, 6 conflict runs and 6 control
runs per arm (the `stale` arm runs trap tasks only): 135 runs. A second pass on Opus 5.5,
the model most recent fleet sessions ran on, runs the trap tasks twice per arm (42 runs,
6 per arm). The rules below are applied to the Sonnet pass; the Opus pass is reported
beside it with the same thresholds scaled to 6 runs (a gap of 2), and a disagreement
between the two models is reported as a disagreement, not averaged.
With 9 runs per arm a gap of 1 or 2 runs is noise.

A trap run counts as kept only when every hidden check for its task passes; `addrule` has
two (order and case) and both are also reported separately. A run that errors or does not
deliver the request is reported and left out of the kept count's denominator.

## Rules

- Ceiling and floor, read first. If `none` keeps the decision in 7 or more of its 9 trap
  runs (5 or more of 6 on Opus), the model recovers these decisions from the code and the
  fixture cannot show whether a record helps: R1 to R4 are reported as untestable on this
  fixture, not as failed, and the "premise unsupported" conclusion below does not fire.
  If `comment` keeps 2 or fewer of 9, the record is not being used at all and R2 to R4
  have nothing to compare against. The same reading is applied per task (3 runs per arm:
  3 of 3 in `none` is ceiling for that task) and pooled.
- What the `tests` arm measures differs by task, so R2 is reported per task as well as
  pooled: `fileorder`, an existing test fails on the naive change (enforcement);
  `always`, the request contradicts an existing test, so the agent must rewrite it (what
  matters is whether the rewrite keeps the reason); `addrule`, no test covers the new
  function, so only the docstring text can help (a record read as prose, not enforcement).
- The `stale` arm is an upper bound on harm. Its three comments state the opposite of the
  invariant and one echoes the task's own wording; the one false comment the audit found
  in real code was merely outdated. R5 measures an adversarially false comment, not
  typical rot.
- A keep check can fail on a change that told the owner about the limit (an `addrule`
  that appends and says so) or on output that is arguably not a post (a note on stdout
  for an empty month). Every failed keep check is read by eye and reported as a silent
  break or a disclosed one.
- R1, comments change behaviour: `comment` keeps the decision in at least 3 more trap runs
  than `none`. If the gap is under 3, the decision comments did not change what the agent
  did on this fixture, and "decision comments are valuable to agents" is unsupported here.
- R2, tests can replace comments: `tests` keeps at least as many trap decisions as
  `comment` minus 1, and its conflict warnings are within 1 run of `comment`. If so, the
  evidence supports moving a decision into a test and then deleting the comment.
- R3, decision docs: `doc` is read in under half its trap runs, or keeps no more than
  `none` plus 2: an out-of-line decision record is not consulted when it matters. If it is
  read in at least 8 of 9 and keeps at least `comment` minus 1: decision docs work when the
  README points at them.
- R4, history: the same thresholds, with `git log`, `git show` or `git blame` as the read.
- R5, harm: `stale` keeps the decision in at least 3 fewer trap runs than `none`: a false
  comment is worse than no comment.
- Countermetric: an arm whose median cost on the control task is more than 1.25 times
  `none` pays for its record on work the record does not touch. The 1.25 band is the
  spread between identical bare runs in the earlier vet (0.098 to 0.111, about 1.13)
  plus a margin, set here before any placement run.

## What would change the vet's conclusions

- R1 fails and the real-comment audit rates under 25% of sampled decision comments as
  load-bearing: the "49% to 79% of comments carry decisions" premise does not support
  keeping them, and the blanket-lint SKIP has to be re-argued on other grounds.
- R2 holds: the recommended practice becomes "enforce in a test, then delete the comment",
  not "keep the comment".
- R1 holds and R2 fails: a comment at the site carries something a test does not.

## Real-comment audit readouts (72 units, labels withheld from auditors)

- Rubric check: of the 12 units earlier labelled clutter, at most 2 may come back
  `load_bearing`; more than that and the rubric does not discriminate.
- Reported per stratum, never pooled: share true now; share that restate the code; share
  with a test that enforces the claim; share whose reason is also in the PR or commit text;
  share a blind reader recovers from the code alone; share rated load-bearing.

## Limits known before running

- I wrote the fixture, its comments, the probes and the task intents. This is a mechanism
  test on a 300-line Python repository, not a measurement of the real repositories.
- One fixture, three trap tasks. A result here is a direction, not a rate.
