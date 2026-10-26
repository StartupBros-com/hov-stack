# ablation — does CLAUDE.md actually change what the agent does?

> The raw run output this write-up was scored from (`sweep_logs/`, `shape_out/`
> and the top-level `*.jsonl` result files, 591 files) was removed from the tree
> on 2026-10-19 to keep the public repo small; `git show 42e165c:claude/scripts/shape-audit/ablation/`
> has all of it. The scripts below recreate both directories on a fresh run.

Observational auditing (the parent directory) can only measure *adherence*. It
cannot tell you whether a rule **caused** the behavior: 99.3% `pnpm` use across the
transcript corpus is equally consistent with "the rule works" and with "there was a
`pnpm-lock.yaml` in every repo."

This is the controlled ablation that separates them, and it is the experiment
arXiv 2607.27250 ("Do Context Files Help Coding Agents?") should have run. Same
design — none / full / partial context, same `claude --print --bare` CLI — but the
dependent variable is **rule adherence**, not gold-test pass.

## Design

Three arms, identical task and sandbox:

| arm | context injected |
|---|---|
| `A_none` | nothing — `--bare`, no CLAUDE.md at all |
| `B_full` | the entire 3,075-word CLAUDE.md via `--append-system-prompt` |
| `C_rule` | **only** the 85-word `## Package Managers - CRITICAL` section |

Three contrasts fall out:

- **A vs B** — attribution. Does the file cause the behavior?
- **A vs C** — is the specific rule sufficient on its own?
- **B vs C** — dilution. Does burying a CRITICAL rule among 68 directives weaken it?
  (The Instruction Stacking Collapse hypothesis, arXiv:2608.02639.)

## Why the DV is a package manager

It is the only rule class with a *perfect* detector: a string match on an actually
executed command, with no semantic judgment. Contrast the response-shape detectors,
which needed three rounds of correction and still conflate mandated narration with
violations.

Two controls make it clean:

1. **No lockfile.** Scratch projects ship `package.json` / `pyproject.toml` with no
   `pnpm-lock.yaml`, `uv.lock`, etc. — so nothing in the repo leaks the answer and
   CLAUDE.md is the only signal.
2. **PATH shims.** Every package manager (`npm`, `pnpm`, `yarn`, `bun`, `pip`,
   `pip3`, `uv`, `pipx`, `poetry`, `conda`) is replaced by a script that logs its
   argv and exits 0. No network, no installs, no side effects, and the measurement
   is exact. Same trick the paper used for `git push`.

Each run also gets a pristine copy of the project, so runs cannot contaminate
each other, and CLAUDE.md is snapshotted at start so a live edit mid-sweep cannot
change the arm text.

## Run it

```bash
python3 setup.py                                        # shims + scratch projects
python3 run2.py --reps 5 --model sonnet --workers 4     # 30 runs, ~8 min, ~$4
python3 run2.py --reps 4 --model opus --tasks js --workers 3
python3 stats.py                                        # Fisher exact, stdlib only
```

## Results, 2026-08-06 (42 runs, $7.34)

**Node / `pnpm` — the rule is load-bearing, and it replicates across models.**

| arm | sonnet | opus |
|---|---|---|
| `A_none` | **0/5** (all `npm`) | **0/4** (all `npm`) |
| `B_full` | **5/5** | **4/4** |
| `C_rule` | **5/5** | **4/4** |

A vs B: **+100pp**, Fisher p=0.0079 (sonnet) / p=0.0286 (opus). Combined 0/9 → 9/9.

Both frontier models default to `npm` with no context file and switch to `pnpm`
100% of the time with one. This is causal, not correlational.

**Python / `uv` — near-redundant, because the model already prefers it.**

`A_none` 4/5, `B_full` 4/4, `C_rule` 5/5. +20pp, p=1.0, n.s. In 2026 `uv` is
already the default reach for a Python dependency; the rule mostly ratifies it.
Not a reason to cut ~15 words, but a real asymmetry inside one CRITICAL rule.

**No dilution — on these rules.** `B_full` vs `C_rule` is identical everywhere
(p=1.0). But both arms sat at ceiling, and **a ceiling cannot show dilution.** That
caveat turned out to matter: Sweep 2 below found a rule with partial baseline
adherence and measured a real dilution effect on Sonnet (p=0.0079) — which then
failed to replicate on Opus. Do not read this section's "no dilution" as settled;
read Sweep 2.

## Why this matters against the paper

arXiv 2607.27250 found nothing: MDE >30pp, 288 runs, 17 tasks, 3 repos, a
descriptive-only 10–15pp equivalence bound. This found a **100pp effect at n=5**,
on the same CLI, with a smaller budget.

The difference is entirely the dependent variable. Binary gold-test pass on a
merged PR is blind to whether the agent used the right package manager; adherence
is not. The paper's null is a property of what it measured, not of context files.

It also replicates Gloaguen et al. (arXiv:2602.11988) under controlled ablation —
they observed `uv` calls jumping <0.01 → 1.6 per instance when named in a context
file, and concluded "the absence of improvements is not due to a lack of
instruction-following." Confirmed here: instructions are followed, decisively.

## Limits

- Two rules, two models, n=4–5 per cell. Wide but shallow.
- Single-turn, non-interactive, `--bare` (no hooks/skills/subagents/memory), so this
  inherits the same ecological-validity gap it criticizes in the paper.
- `--bare` bills `ANTHROPIC_API_KEY` directly, not the Max subscription.
- Adherence still is not *benefit*. This proves the rule changes behavior. Whether
  that behavior is worth 5,944 tokens per session is a separate question.


---

# Sweep 2: five more rules, and the finding that did not replicate

60 + 15 + 15 runs, ~$7.74. Measurement upgraded from PATH shims to the agent's full
tool-call stream (`--output-format stream-json`), so any rule that manifests as a
tool call can be scored without shims.

## Detector bugs found and fixed (three of them)

`NEWBRANCH` matched **`git branch -vv`** -- a read-only listing -- because the class
`[A-Za-z0-9._/-]` includes a hyphen. Three runs were scored GOOD when the agent had
in fact edited and committed on `main`. Because every run's tool trace is saved to
`sweep_logs/`, re-scoring took no re-runs (`rescore.py`, `final_score.py`).

**Lesson, now three-for-three in this project: never trust a detector you have not
read the matches of.** The observational audit had the same failure mode twice.

## Results, Sonnet

| rule | A_none | B_full | C_rule | verdict |
|---|---|---|---|---|
| package manager (pnpm) | 0/5 | 5/5 | 5/5 | **LOAD-BEARING** p=0.0079 |
| package manager (uv) | 4/5 | 4/4 | 5/5 | REDUNDANT |
| ast-grep before grep | 0/5 | 5/5 | 3/5 | **LOAD-BEARING** p=0.0079 |
| conventional commits | 0/5 | 5/5 | 5/5 | **LOAD-BEARING** p=0.0079 |
| tests before finalizing | 0/5 | 5/5 | 5/5 | **LOAD-BEARING** p=0.0079 |
| worktree, not main | 0/5 | **0/5** | 0/5 (3 violations, 2 incomplete) | no effect in any arm |

Pooled attribution A_none 0/25 -> B_full 15/25, **p = 2.9e-06**.

## The dilution result, and why it is Sonnet-only

On Sonnet, in a repo with a real `origin`, the **full CLAUDE.md produced 5/5
violations** of its own CRITICAL worktree rule (edited straight on `main`), while
the same section **alone** produced **0/5** violations. Fisher p=0.0079; pooled over
both worktree sandboxes 10/10 vs 3/10, p=0.0031.

That looked like hard evidence that the file undermines its own rule. **It does not
replicate on Opus.** Opus `A_none` branches **5/5 with no CLAUDE.md at all**, and
`B_full` is a clean 5/5 -- no dilution, and the rule is simply *redundant* there.

| worktree (repo has a remote) | A_none | B_full | C_rule |
|---|---|---|---|
| sonnet | 0/5 | 0/5 | 2/5 |
| opus | **5/5** | 5/5 | 3/5 |

## What that actually means

1. **Rule value is model-dependent.** The same rule is load-bearing on one model and
   redundant on another -- the cross-model variance Atlassian measured (arXiv:2604.12177,
   25-85%), reproduced on a real harness rule. A single-model audit will mis-classify.
2. **The earlier "no dilution" conclusion was a ceiling artifact**, exactly as flagged.
   Off the ceiling, dilution is measurable -- on one model.
3. **The exposure lands on the subagent fleet.** The main thread runs Opus (rule
   redundant); `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` floors subagents at Sonnet -- the
   model where the full file yielded 5/5 violations. Subagents receive CLAUDE.md and
   rarely create branches themselves, so practical exposure is limited, but the signal
   points at the fleet, not the driver.

## Still true, still unresolved

- 5 of 7 rules tested are load-bearing at a 0/5 baseline. Context files work.
- Adherence is not benefit. This measures whether behavior changes, not whether the
  change is worth 5,944 tokens a session.
- n=5/cell, single-turn `--bare` (no hooks/skills/subagents/memory), two models.
- Verdicts should be re-checked per model before any rule is cut.


---

# Sweep 3: per-model classification, and the Response Shape section judged

225 runs total, $22.68. Two questions: which rules can be cut *for the model that
actually drives*, and do the semantic Response Shape bullets do anything.

## Rule classification, by model

| rule | sonnet baseline -> full | opus baseline -> full | verdict |
|---|---|---|---|
| package manager `pnpm` | 0/5 -> 5/5 **p=0.0079** | 0/4 -> 4/4 **p=0.0286** | LOAD-BEARING on both |
| conventional commits | 0/5 -> 5/5 **p=0.0079** | 1/10 -> 8/10 **p=0.0055** | LOAD-BEARING on both |
| `ast-grep` before grep | 0/5 -> 5/5 **p=0.0079** | 1/10 -> 6/10 p=0.057 | load-bearing / borderline |
| tests before finalizing | 0/5 -> 5/5 **p=0.0079** | **5/5 baseline** | **REDUNDANT on opus** |
| worktree, not main *(remote sandbox)* | 0/5 -> 0/5 | **5/5 baseline** | **REDUNDANT on opus** |
| package manager `uv` | 4/5 baseline | — | REDUNDANT |

**The capable model needs fewer rules.** Two directives that are strongly
load-bearing on Sonnet -- "run tests before finalizing" and "never work in the main
checkout" -- are things Opus already does unprompted, 5/5, with no context file at
all.

**This inverts the usual assumption about who CLAUDE.md is for.** The main thread
runs Opus, where 2 of 5 tested rules are redundant. `CLAUDE_CODE_SUBAGENT_MODEL`
floors subagents at Sonnet, where 4 of 6 are load-bearing and where the full file
measurably *dilutes* the worktree rule. Most of this file's measured work happens on
the subagent fleet, not on the driver.

Corollary: a rule audited on one model will be mis-classified. Cutting "run tests
before finalizing" because Opus doesn't need it would silently degrade every
Sonnet subagent.

## The Response Shape section, judged

18 responses (6/arm, Sonnet) on a code review of a deliberately multi-problem repo,
scored by an Opus judge against six bullets, cross-checked with objective regexes.

| bullet | A_none | B_full | C_rule | verdict |
|---|---|---|---|---|
| lead with the answer | 5/6 | 6/6 | 6/6 | baseline near ceiling |
| no closer / recap | 4/6 | 3/6 | 6/6 | full file *below* baseline |
| rank, don't truncate | **6/6** | 6/6 | 6/6 | **REDUNDANT** |
| estimate in real units | **0/6** | **0/6** | **0/6** | **DEAD — never fires** |
| show what you ran | **6/6** | 6/6 | 6/6 | **REDUNDANT** |
| end with next action | 5/6 | 4/6 | 6/6 | baseline near ceiling |

**Not one bullet shows a significant A->B effect.** Four sit at or near baseline
ceiling -- the model already does them. One, *"estimate in real units,"* is **0/6 in
all three arms**: it does not fire even when it is the only instruction in the
prompt. The objective cross-check agrees (zero time estimates in any of the 18
responses).

**The section's real effect is compression:** mean response 4,806 (`A_none`) ->
1,852 chars (`C_rule`, the section alone), **-61%**; the full file lands at 1,876. That matches the transcript audit independently (median 192 -> 158 chars).

**Dilution again, on Sonnet.** On the two bullets where the arms diverged
(`no_closer`, `next_action`), the full file scored 7/12 and the section alone 12/12,
**p=0.037** -- and on `no_closer` the full file (3/6) was *worse than no context at
all* (4/6).

### Judge caveat

Responses are Sonnet, judge is Opus -- same model family, the same flaw PR #161's own
supporting evidence had. Every judged verdict is reported beside an objective regex
metric; the two agree on the load-bearing findings (`real_unit_estimates` dead,
preamble absent everywhere). The judge is *stricter* than the regex on closers,
catching "recap of work just performed" that no regex reaches.

## Standing conclusions

1. Context files causally change behavior: pooled 0/25 -> 15/25, p=2.9e-06.
2. Rule value is **model-dependent**. Audit per model or mis-classify.
3. Dilution is real on Sonnet, absent on Opus. Ceiling effects hid it in Sweep 1.
4. The Response Shape section buys **brevity**, not its individual bullets.
5. Adherence is still not benefit. None of this says a changed behavior is *better*.


## Caveats that apply to every number above

**Multiple comparisons are not corrected.** Across these sweeps well over 20
significance tests are reported and the significant ones are highlighted. At
alpha=0.05 roughly one in twenty would be expected to reach significance by chance.
The results that should be trusted are the ones with huge effect sizes and
replication across models (pnpm 0/9 -> 9/9; conventional on both models); treat any
lone p just under 0.05 as suggestive.

**Timed-out and harness-error runs are scored as NONE, not excluded.** `sweep.py`
records `rc=-9` on timeout, but `rescore.py`/`final_score.py` recompute verdicts
purely from the tool-call trace and never read `rc`. A run killed at the 360s budget
therefore lands in NONE and dilutes that arm's denominator. This matters most for the
`worktree`/`worktree_remote` C_rule arms, where the extracted rule text references
tooling absent from the sandbox (`wt-new.sh`, `gh`) and runs went long. The
violation-rate framing (BAD counts) is the robust one and is what the dilution claim
uses.

**`stats.py`'s harness-error exclusion is inert here.** It looks for
`ablation/logs/*.raw.json`, which is not committed, so it silently excludes nothing
and can print a different denominator than the prose (e.g. `uv` B_full 4/5 rather
than 4/4). Prefer `final_score.py`.

**The Response-Shape judge eval used ONE task type.** All 18 responses answer a
single hardcoded code-review prompt against one seeded repo. A code review naturally
invites findings and next steps but not necessarily deploy/QA time estimates, so the
`real_unit_estimates` result is strongest as "did not fire in the arm where it was the
only instruction" rather than "cannot ever fire."

**Detector history.** Four separate detector bugs have been found and fixed in this
project (two in the observational audit, `git branch -vv` matching as branch
creation, and `COMMIT_MSG` mis-parsing heredoc commits). All raw tool traces are
committed precisely so any correction re-scores without re-running. Never trust a
detector whose matches you have not read.

## Safety: what the sandbox does and does not isolate

Every runner invokes the CLI with `--dangerously-skip-permissions`. **That is
measurement isolation, not security isolation.** Concretely:

- Disposable per-run copies of the scratch project, PATH shims for package managers,
  and a narrow `--disallowedTools` blocklist keep the *measurement* clean.
- They do **not** confine reads. Committed traces show an agent running
  `cat ~/.claude/scripts/wt-new.sh` — reading the operator's real harness files from
  inside a supposedly isolated run.
- `--disallowedTools` matches command prefixes, so an env-var-prefixed invocation
  (`GH_REPO="" gh ...`) is not necessarily caught.
- `--bare` suppresses the ambient CLAUDE.md/hooks, but `$HOME` is still the real one.

Do not point these scripts at a task where an unconstrained read or write would
matter, and do not run them on a machine whose `$HOME` you would not hand to the
model.

**Redaction note.** The code-review fixture originally used a Stripe-live-key-shaped
string, which the model quoted back in all 18 committed responses. That string was
invented for the fixture and was never a real credential, but it would read as one to
a secret scanner, so it was replaced with `EXAMPLE_FAKE_KEY_NOT_A_CREDENTIAL` in both
`shape_eval.py` and `shape_out/*.md` after the runs completed. No judged verdict
depends on the literal characters.


---

# Sweep 4: old file vs new file (teardown move 6a, 2026-10-18)

The earlier sweeps compare none / whole file / one section of the live file. A cut
needs a different contrast: the file before the cut against the file after it, on the
same tasks, per model. `oldnew.py` runs two fixed arms, `OLD` (`git show
a8910eba:claude/CLAUDE.md`, the branch base: 27,031 bytes, 158 lines, sha
`fe6034ebc49d`) and `NEW` (the branch's `CLAUDE.md`). Every rule row carries
the arm's sha; round-1 shape rows predate that field, and the run log records their
NEW as `5029941fa405`.

`NEW` is the revised cut: the first cut (12,880 bytes) went through a line-by-line
audit that restored 14 lost specifics as short bullets, leaving 14,885 bytes and 97
lines (`5029941fa405`). The sweep tests that revised file, not the first cut. Round 1
flagged three Response Shape passages, which were restored verbatim (15,131 bytes, 99
lines, `9898bdaa93d7`); the diff between the two NEW files touches only the Response
shape section, so the rule cells scored against `5029941fa405` still describe the
final file.

Rules: `pnpm`, `astgrep`, `conventional`, `tests`, `worktree_remote` (the existing
detectors), plus `fanout`: write a workflow script for a five-dimension review with
verified findings, scored GOOD when the script caps its data-driven fan-out (`.slice`
or `maxItems`), with dedup-before-verify recorded beside it. Fan-out hygiene is the
rule whose detail the first cut moved to the agent-swarm skill; the revision put a
one-bullet version back. Response shape reuses `shape_eval.py` with the two arms.

Side metrics on every run: `pointer_open` (a tool call naming a doc the new file
points at) and `refused_shape` (a Bash command the worktree shape-checker refuses).
`pointer_open` was expected to stay near zero, since no task needs a pointed-at doc.
It did not: Opus on NEW opened one in 8 of 10 fanout runs at the 360 s cap and 6 of
10 at 900 s, against 1 of 10 each on OLD, plus one NEW `worktree_remote` run. Sonnet
opened none on either arm. So when a task touches a rule whose detail moved out,
Opus follows the pointer, and the reading costs time (see the fanout results below).
No dedicated pointer-follow probe was built beyond this.

## Decision rule, written before any full-sweep result

- n = 10 per arm, per rule, per model (Sonnet and Opus).
- NEW counts as worse on a rule when, in either model, OLD has at least 3 more GOOD
  runs than NEW, or a one-sided Fisher exact test favoring OLD gives p < 0.10. The
  same threshold applies to each judged Response Shape bullet.
- Any rule where NEW is worse gets its old text (or the lost specific) restored in
  NEW, and that rule's cells are re-run against the restored file.
- Countermetric: a cell where the arms' NONE counts (timeouts, harness errors, no
  scorable action) differ by 3 or more is reported as inconclusive, not scored.
- What this can and cannot show: at n = 10 a drop of fewer than 3 runs is not
  detectable, so "not worse" means no drop of 30 points or more, not equivalence.

## Results

Served models: `claude-sonnet-5-5` and `claude-opus-5-5` on every row. GOOD counts
out of 10; p is the one-sided Fisher test favoring OLD.

**Rules** (NEW `5029941fa405`; the 900 s fanout cell ran against `9898bdaa93d7`):

| Rule | Sonnet OLD | Sonnet NEW | Opus OLD | Opus NEW | Verdict |
|---|---|---|---|---|---|
| `pnpm` | 9 | 10 | 10 | 10 | not worse |
| `astgrep` | 10 | 10 | 0 | 0 | not worse; Opus cell measures nothing (below) |
| `conventional` | 10 | 10 | 10 | 10 (rescored) | not worse |
| `tests` | 10 | 10 | 10 | 10 | not worse |
| `worktree_remote` | 0 | 6 | 4 | 4 | not worse |
| `fanout` at 360 s | 10 | 10 | 10 | 7 (3 NONE) | Opus inconclusive |
| `fanout` at 900 s | | | 10 | 10 | not worse |

Dedup-before-verify matched GOOD in every fanout cell (Sonnet 10/10 both arms; Opus
10 vs 7 at 360 s, 10 vs 10 at 900 s).

**Response Shape**, judged bullets (round 1 NEW `5029941fa405`, round 2 NEW
`9898bdaa93d7`; `evidence_based`, `lead_with_answer` and `rank_dont_truncate` were
10/10 or 9/10 on every arm in both rounds and are omitted):

| Bullet | Model | R1 OLD | R1 NEW | R2 OLD | R2 NEW |
|---|---|---|---|---|---|
| `next_action` | Sonnet | 9 | 6 (worse, p = 0.15) | 8 | 9 |
| `no_closer` | Sonnet | 8 | 4 (worse, p = 0.085) | 8 | 9 |
| `next_action` | Opus | 9 | 9 | 9 | 10 |
| `no_closer` | Opus | 9 | 6 (worse, p = 0.15) | 6 | 10 |
| `real_unit_estimates` | both | 0 | 0 | 0 | 0 |

Round 1 flagged three cells. Per the rule, the old text of the passages behind them
went back verbatim (the itemized-report example on "Stop when the answer is done",
the full "End with the next concrete action" bullet, and the "Before sending"
paragraph), and only the Response Shape cells were re-run. Round 2 is not worse on
every bullet for both models. The restores were scored once and not reworded.

**Noise floor.** Opus OLD `no_closer` went from 9/10 in round 1 to 6/10 in round 2
on the identical file. A three-run swing between runs of the same arm is therefore
within noise at n = 10, so the round-1 flags may have been noise too. The restores
went in anyway because the rule says so and they cost 246 bytes.

**Fanout timing.** At the 360 s cap, 7 of 10 Opus NEW runs and 2 of 10 OLD runs were
killed; 3 NEW kills left no scorable script (all three are `rc -9` at 360.1 s), which
is what made the cell inconclusive. 8 of those 10 NEW runs opened a doc the new
file points at, against 1 of 10 on OLD. The cap was raised to 900 s for a second set of 10 reps per
arm after seeing that result, so this cell was not predeclared. At 900 s both arms
scored 10/10, with median run time 350 s on NEW against 260 s on OLD. The moved
fan-out detail costs Opus about 90 s of reading on this task; the outcome was the
same.

**Cells that measured nothing.**

- Opus `astgrep` scored 0/10 on both arms because Opus runs `rg -n -F parseWidget`
  before ast-grep, and the detector scores the first search. It cannot separate the
  arms.
- `real_unit_estimates` was 0/10 on every arm, both rounds, both models.
- `refused_shape` is left out of the summary: it counts plain `f=$(…)` assignments
  that the shape-checker accepts, so it over-counts.

**Detector corrections.**

- `COMMIT_MSG` did not parse `git commit -am "…"`, so 6 Sonnet NEW `conventional`
  runs first scored NONE. The regex now takes combined short flags. The rows were
  re-scored from their saved traces (only those 6 changed) and carry `"rescored":
  "commit -am parse"`.
- Opus NEW `conventional` r7 first scored NONE: it committed with `git -C <path>
  commit … -m "feat(cache): raise TTL to 300s and add MAX_ENTRIES constant"`, and
  the three commit patterns required `git commit` with nothing between. They now
  accept git's global options (`-C`, `-c`, `--git-dir`, `--work-tree`,
  `--no-pager`) before `commit`, and no longer match `git commit-tree`. Re-scoring
  every saved Sweep 4 conventional trace changed only that row, which carries
  `"rescored": "git -C parse"`; the cell is 10/10. `rescore.py` gives the same
  report for Sweeps 1-3 before and after the change.

**Cost.** Response tokens only; judge calls are not logged. Sonnet $7.85 (rules
$6.17, shape $1.04 + $0.64). Opus $94.31 (rules plus the 900 s fanout reps $78.93,
shape $8.08 + $7.30). Total $102.16.

**Papercut leak.** Arm text carries the papercut rule and runs use the real `$HOME`,
so Sweep 4 runs wrote 41 store files (37 signatures) into the operator's papercut
store. They were left in place, because the store is a ledger and is not purged. All
four runners now build their child environment with `rules.child_env()`, which sets
`PAPERCUT_STORE` to `/tmp/shape-audit-papercuts`. That was checked by running
`papercut add` under `child_env()`: 1 file was written in the scratch store and 0 in
`~/.claude/papercuts`.

**Verdict.** No rule or judged bullet is worse on NEW under the predeclared rule
after the round-2 restores. One cell needed a post-hoc cap change before it could be
scored: Opus fanout at 900 s. NEW is 15,131 bytes against OLD's 27,031 (56%). It is
not 8 KB, and no measurement here supports that number.
