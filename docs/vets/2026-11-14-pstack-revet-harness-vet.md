# Harness vet: pstack re-vet, subtract-before-you-add, the laziness protocol and `/poteto-mode`

**Date:** 2026-11-14
**Ask (operator):** "https://x.com/inoino65536/status/2118906585821163741
https://x.com/cu30rry_/status/2119379401842516265 we need to essentially /harness-vet or
/rent-check this and cherry-pick the magic into our harness/stack"
**Tracking:** issue #595, branch `pstack-revet-2026-11`.
**Prior vet:** `docs/vets/2026-09-18-pstack-harness-vet.md` (pin `1f84288b`); its row
dispositions live on dotfiles#1202.

---

## Headline

- **The two `CLAUDE.md` lines distilled from the posts' pstack leaves are not adopted.**
  This vet's predeclared rule: a line earns its place only if it beats the incumbent on a
  primary metric in at least 2 of 3 runs of a task without worsening any countermetric. The
  lines miss it for three reasons, in order:
  1. **Cost failed.** Read literally, a9 cost more per run than the incumbent in four of
     five cells in batches 1 to 3 (2.3). A fourth batch, with its warm-cache pass condition
     written before launch, also failed: one of its five cells held a cold-cache run and is
     invalid under that condition (2.5).
  2. **The rule is per line, and only the pair cleared the primaries.** Line 2 alone (arm
     `a8-premise`) never beat the incumbent. Line 1 alone ran only in a longer form
     (`a7-smallest`, with a clause later cut) and beat the incumbent in one cell. a9's own
     line 1 never ran alone (2.2).
  3. **Its interactions are untested.** The fixture never tested how the lines interact
     with the live `CLAUDE.md` or with Claude Code's built-in "Only validate at system
     boundaries" sentence. The arms carried a five-bullet excerpt (4.2).
- **What the pair did on this fixture.** Across the four cells not at ceiling, the two-line
  text (arm `a9-trimmed`) reached the best outcome in 9 of 12 runs in batches 1 to 3. The
  incumbent reached it in 1 of 12, or 6 of 9 against 1 of 9 if Opus t3's root-fix-plus-dedupe
  counts as a tie. Batch 4 repeated those totals, but Sonnet t3 fell to 1 of 3. The sample is
  three runs per cell on one fixture with author-built traps, run under `claude -p` only.
- **The exact text stays documented as the operator's override option** (4.2), with the
  deciding run an override would need first: multi-site and boundary-guard tasks under the
  full live `CLAUDE.md`, with the pass condition written before launch. It is on a
  needs-human issue because `CLAUDE.md` is the live `~/.claude/CLAUDE.md` and a permission
  surface only the operator changes.
- **The posts' "magic" is two pstack principle leaves reached through `/poteto-mode`.** As
  delivered, a Cursor-first plugin behind a 21.7 KB router, it stays SKIP. The
  plugin-with-router route, as run, cost 1.6 to 2.3 times the incumbent per Sonnet run
  (medians $0.079 to $0.092 against $0.035 to $0.050). That is in line with the thread's
  "good but costly as hell" reply. Its two warm-cache runs still cost 1.42 and 1.57 times
  the incumbent, so most of the difference is a larger prompt, not a cold cache (2.4).
- **Landed by this PR:** three upstream sentences in the vendored
  `create-verification-skill` (cursor/plugins `c49b37a`), path-scoped re-pins of both vendored
  verification skills, the fixture under `harness/vet-fixtures/pstack-2026-11/`, and this note.
- **The rest of the 83-commit delta:** SKIP, REJECT or parked; table in section 3.

---

## 1. Identity, targets and run choices

**Source.** cursor/plugins `pstack/` at `3dbd22ff12742fb28c9700b9760baa29ed41dc13`
(2026-11-13, pstack 0.15.36), MIT, upstream copyright holder Lauren Tan (licence unchanged
since `1f84288b`). Delta since the prior vet's pin `1f84288b2c047b6d39952da23f51cf486f3b2f7a`
(2026-09-18, pstack 0.15.2): 83 commits touching `pstack/`, 529 files changed, +22,330 / -4,456
lines, 47 to 58 skills. New skills: benchmark-checklist, correct, create-formal-verification-skill,
in-your-own-words, ketchup, ketchup-video, maintain-formal-verification-skill, poteto-help,
principle-explain-the-number, sharpen, statechart. None removed.

**Focus components (named by the posts).**

- `principle-subtract-before-you-add` and `principle-laziness-protocol`: last upstream change
  `08bd59b37834550f5e8fa0bb5e8852204a7534cf` (2026-10-11, #571, "cut unneeded sections from
  seven skills"): -8 lines in laziness, 5 lines changed in subtract. Both are
  `disable-model-invocation: true` leaves reached through the router.
- `poteto-mode`: last upstream change `c742dd61706fbacc1b95f1a20b7b988cf096ce6c` (2026-10-27,
  #1043); `SKILL.md` is 21,670 bytes.

**The posts.** @inoino65536 (2026-11-07, Japanese) lists principles from O'Reilly's
*Becoming a Better Programmer* (minimal code, KISS, delete dead code, understand the user's
real need, avoid over-implementing, clear done criteria) and says most of them are "packed
into pstack" (大体はpstackに詰め込まれてる). @cu30rry_ (2026-11-08) credits
`principle-subtract-before-you-add`, `principle-laziness-protocol` and `/poteto-mode`. A reply
by @MiguelsonAnten1 calls pstack "good but costly as hell".

**Targets.** H, this harness: the always-loaded doctrine (repo-root `CLAUDE.md`, served as
`~/.claude/CLAUDE.md`) and the vendored verification skills. P, the product repos agents work
in under `~/SITES/`; the fixture is shaped like one of them.

**Concrete task.** An agent asked for a small change in a working repo makes the smallest
correct change at the root, adds no surface nobody asked for, and says so when the code
refutes the request's premise.

**Landing depth.** The PR carries the note, the fixture and the verification-skill re-pin.
The `CLAUDE.md` lines are not adopted; they are documented as an override option on a
needs-human issue, since the file is a permission surface. Nothing was installed or enabled.
pstack is installed nowhere on this host (checked: no plugin entry, no skill copy).

**Run choices.** Ultracode on. Delta triage ran as one Workflow of 16 agents (8 readers over
clusters measure / formal / statechart / words / ketchup / router / thinking / rest, then 8
refute-by-default verifiers, one per reader), 562,863 subagent tokens. Behavioural arms ran
`claude -p` on Claude Code 2.1.325 under an isolated `CLAUDE_CONFIG_DIR` with every
environment variable unset except the model route's, blinded run ids, a mechanical grader
that never reads the arm map. Four batches; spend in section 6.

### 1.1 Discovery record

The discovery agent searched with the candidate's name withheld from lane 1; the word
"pstack" appears once in its queries (P2 q5, a lookup after lane 1 closed).

| Lane | Sources and queries | Searched |
|---|---|---|
| 1, alternatives | `gh search repos "karpathy guidelines CLAUDE.md"` (empty); `gh search code "Surgical Changes" "Simplicity First" "Think Before Coding"`; `gh search repos "anti-overengineering claude code skill minimal diff"` (empty); `gh search code "smallest change that meets the request" filename:AGENTS.md`; `gh search repos "minimal diff coding agent skill"` (empty); `gh search repos "surgical changes AGENTS.md overengineering"` (empty); `gh search code "nothing speculative" filename:CLAUDE.md`; `gh search code "unrequested" "YAGNI" filename:SKILL.md`; exa `claude code skill SKILL.md YAGNI stop over-engineering minimal change reviewer` | yes |
| 2, first-party | exa: Codex AGENTS.md guide; Cursor rules docs; the Claude Code system prompt line; Anthropic prompting best practices. `gh search code` in openai/codex (three queries, one empty). firecrawl fetches: the Claude prompting best-practices page, the Sonnet 5.5 prompting page, cursor.com/docs/rules | yes |
| 3, experience | exa: four queries on measured effects of minimal-diff rule files (AGENTS.md / CLAUDE.md evals, Karpathy benchmarks, scope-creep comparisons) | yes |

| Pass | Seed | Admitted |
|---|---|---|
| P1 | "ladder / moyu / minimalist" (lane 1 hit) | Ponytail, Honey, check-premises |
| P2 | "Ponytail" | JetBrains eval, Ponytail's benchmark repo |
| P3 | "JetBrains / SkillsBench" | DocSpring, makaneko |
| P4 | "check-premises / PREMISE FALSE" | nothing new |

**Stop that fired:** the pass ceiling of 4 (P4 was the first empty pass, so the
two-empty-passes stop never fired).

**Not searched:** code.claude.com/docs/en/memory (cited by loopnotes, not fetched);
developers.openai.com/codex/guides/agents-md; anthropics/claude-code's Opus 4.5 migration
`prompt-snippets.md` (`gh api` 404); cass (no local-session evidence requested); arXiv
2602.11988, 2601.20404, 2607.27250, unlearn.dev and the independent Ponytail benchmark repos
(result lists only); makaneko full text (paywalled; the visible part was read).

**Outside evals found (none measures this whole job; all small).** Loopnotes (Karpathy
CLAUDE.md, 60 runs, Sonnet 5.5): mostly changed what the model said, not its code; the author
later dropped "Think Before Coding". Lawrentz: lines added 15 to 8 to 6 on one retry task,
"a shape, not a law". AWS "Guardrails Beat Guidance" (arXiv 2604.11088v2, Opus 4.6,
SWE-bench Verified): only negative constraints helped individually, -20pp when "do not
refactor unrelated code" was removed (McNemar p=0.016, does not survive correction).
Ponytail's own benchmark (`01cbf815`): -53% lines, author's numbers. JetBrains (80 paired
tasks): -15% code (p=0.088), -10.3% cost (p=0.004), no quality difference detected.
DocSpring (4 tasks x 2): a blind judge preferred their AGENTS.md alone over adding Ponytail
(6.8 vs 5.9) because Ponytail sessions missed sibling code paths. Honey: author claims.
Makaneko (paywalled, partly read): a distilled rule a quarter of Ponytail's length gave
-43.9% lines at equal or better scores. Vuncloud: uncontrolled pilot, weakest.

---

## 2. Measured, not inferred

### 2.1 Fixture and arms

`harness/vet-fixtures/pstack-2026-11/` (README there). A synthetic Python invoice package,
`invoicer` 1.4, one commit, visible tests green. Three tasks, each a short operator-style
request:

- **t1**, add `summary_to_csv(invoices)`. Traps: a compat alias `summarise`, a public
  `format_summary_v1`, an unreferenced private helper `_legacy_format_row`, a plugin module
  that looks unused. Measures false deletions and unrequested public surface.
- **t2**, "some invoice amounts come out a cent low." The cause is `round()` (banker's
  rounding) in `money.to_cents`; `totals.py` only calls it. Best outcome: the fix lives in
  `money.py` only.
- **t3**, "add deduplication to `send_reminders` (a set of invoice ids already sent is
  fine)." The cause is `send_reminders` iterating `due_invoices + overdue_invoices`, so every
  overdue invoice is in both lists. Classes:
  - **A**: root fix, no dedupe, cause named. **A-**: the same, with the cause not named.
  - **B**: stopped with the cause and evidence. Never occurred. Such a run fails the hidden
    check and would print as E.
  - **C**: root fix plus the dedupe.
  - **D**: dedupe only.
  - **E**: a hidden check failed.

  Class A is this vet's definition of the best outcome. It departs from the literal request:
  the operator asked for a dedupe and said a set was fine.

Hidden checks per task (graded in a temporary copy) catch broken fixes: t2 checks half-up on
lines, credits and tax; t3 checks one reminder per invoice, a second day's run still
reminding, and the overdue listing unchanged.

| Arm | Always-loaded text | Bytes |
|---|---|---|
| `a1-bare` | none | 0 |
| `a2-pstack` | pstack @ `3dbd22ff` as `--plugin-dir`, prompt prefixed `/pstack:poteto-mode` | plugin |
| `a3-incumbent` | `# Global Rules` plus the first five bullets of the live `CLAUDE.md` | 694 |
| `a4-port` | a3 plus two lines: the smallest-change line with a trailing delete/flag clause, and the premise line | 1,091 |
| `a5-ponytail` | Ponytail `.agents/rules/ponytail.md` @ `2a1fe842` alone (contender) | 2,623 |
| `a6-karpathy` | multica-ai/andrej-karpathy-skills `CLAUDE.md` @ `2c606141` alone (contender) | 2,357 |
| `a7-smallest` | a3 plus the smallest-change line only (with the trailing clause) | 989 |
| `a8-premise` | a3 plus the premise line only | 796 |
| `a9-trimmed` | a3 plus the two lines with the trailing clause cut | 941 |

Every arm also carries the Claude Code 2.1.325 built-in prompt. That prompt is the baseline
every arm sits on; no arm adds it. Its "Doing tasks" section already says:

- "Don't add features, refactor, or introduce abstractions beyond what the task requires. A
  bug fix doesn't need surrounding cleanup; a one-shot operation doesn't need a helper."
- "Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust
  internal code and framework guarantees. Only validate at system boundaries (user input,
  external APIs)."

Predeclared (batches 1 to 3): 3 runs per arm per task; primaries as above; countermetrics
hidden pass, false deletions, cost per run, turns; decision rule "a port line earns its place
only if it beats a3 on a primary metric in at least 2 of 3 runs of a task without worsening
any countermetric"; a task is uninformative when bare hits the best outcome 3 of 3. No noise
band was declared.

### 2.2 Batches 1 to 3: primary metrics (99 runs, all exit 0, all hidden checks pass)

Batch 1: a1 to a6 on Sonnet, t1 to t3 (54 runs). Batch 2: a7, a8 on Sonnet t2, t3; a1, a3, a4
on Opus t2, t3 (30). Batch 3: a9 on Sonnet t1 to t3 and Opus t2, t3 (15). Model ids reported
per run: `claude-sonnet-5-5` and `claude-opus-5-5`.

**t1 is at ceiling:** every arm, bare included, kept the compat alias, `format_summary_v1`
and the plugin module, removed nothing, and added no public name besides the requested one
(0 false deletions, 0 of 3 unrequested public names in every arm). `_legacy_format_row`, the
one deletion the trailing clause invites, was removed in 0 runs of any arm.

Best outcome per informative cell (t2: fix only in `money.py`; t3: class A):

| Arm | Sonnet t2 | Opus t2 | Sonnet t3 | Opus t3 | Total |
|---|---|---|---|---|---|
| a1-bare | 0/3 (3/3 added a public name) | 0/3 | D D D | C C D | 0/12 |
| a3-incumbent | 0/3 (1/3 added a public name) | 1/3 | D D D | C C C | 1/12 |
| **a9-trimmed** | **2/3** | **2/3** | **A D A** | **A A A** | **9/12** |
| a4-port | 2/3 | 3/3 | A A A | A A A | 11/12 |
| a7-smallest | 0/3 | not run | A A D | not run | 2/6 |
| a8-premise | 0/3 | not run | D C D | not run | 0/6 |
| a2-pstack | 1/3 (2/3 added a public name) | not run | A A A | not run | 4/6 |
| a5-ponytail | 0/3 | not run | C C C | not run | 0/6 |
| a6-karpathy | 1/3 (1/3 added a public name) | not run | D D D | not run | 1/6 |

Read against the decision rule:

- **The reading of "beats" used here:** the arm reaches the best outcome in at least 2 of 3
  runs, and in more runs than a3. Runs are not paired by rep. A stricter reading fails Opus
  t2, where a9 scored 2 against a3's 1. Two such readings: a margin of at least 2 runs, or
  runs paired by rep (a9 right in reps 1 and 3, a3 in rep 3 only). The verdict in section 3
  does not depend on which reading is taken.
- **In batches 1 to 3, under that reading, the pair (a9) beats a3 in all four cells.**
  Diffs stay small: t2 +2 to +10 lines, t3 +1/-1 in five of six runs. In batch 4, Sonnet t3
  fell to 1 of 3 (2.5), so across batches 3 and 4 that cell is 3 of 6.
- **The rule is per line, and no line met it alone:**
  - Line 2 alone (a8) never beat a3: Sonnet t2 0/3, Sonnet t3 D C D.
  - Line 1 alone ran only as a7, which still carried the trailing clause later cut (2.6).
    It beat a3 in one cell (Sonnet t3: A A D against D D D) and tied at 0/3 on Sonnet t2.
  - Neither line ran alone on Opus. a9's line 1, without the clause, never ran alone.

  Only the pair cleared the primaries. On t2, a7 and a8 each scored 0/3 and the pair (a4,
  a9) scored 2/3. That is either an interaction or noise at n=3; this fixture cannot tell
  which.
- **The t3 primary rewards line 1's behavior, not line 2's.** Class A is the smallest
  correct change at the root (line 1). As worded, line 2 leads to flagging the premise and
  then building what was asked. Run `3e5bc7ce` did exactly that and scored class D.
- **Bare (a1) is not a usable comparison for a9.** a1 reached 0 of 12 and was cheaper than
  a3 in four of five cells (2.3). It ran in batches 1 and 2, a9 in batch 3, so the two never
  ran side by side.
- **The incumbent's own "Diagnose root causes … one guard in the shared function beats one
  per call site" line did not produce the root fix on Sonnet t3** (D D D, the same as bare).
- **a9 is two best outcomes short of a4.** The two misses: Sonnet t3 run `3e5bc7ce` (flagged
  the premise, then built the requested dedupe anyway: class D) and Opus t2 run `b5e4a2f3`
  (also edited `totals.py`). At n=3 that difference is not separable from noise, and it is
  not explained by the cut clause's own target behavior, which fired in 0 runs of any arm.
- **Opus t3 is contestable.** The incumbent's C (root fix plus the set the operator said was
  "fine") honors the literal request and is correct; a9's A is the smaller correct change.
  If C is scored equal to A, the Opus t3 cell is a tie and a9's margin rests on the other
  three cells (6 of 9 against 1 of 9).
- **The `/poteto-mode` arm (a2)** reached 4 of 6 on Sonnet at 1.6 to 2.3 times the
  incumbent's median cost per run (t1 $0.079 vs $0.050, t2 $0.092 vs $0.048, t3 $0.081 vs
  $0.035). Most of that is a larger prompt, not a cold cache (2.4).
- **Contenders as substitutes:** Ponytail fixed t3 at the root but also built the dedupe
  (C C C) and never fixed t2 in `money.py` only; Karpathy matched bare on t3 (D D D).

### 2.3 Countermetrics, read literally

Hidden pass: 3/3 in every cell, every arm. False deletions: 0 everywhere (t1 at ceiling).
Turns: a9's median is at most a3's plus 2 in every cell (Opus t2: 6 vs 4).

Cost per run: the median `total_cost_usd` in dollars, and each ratio to a3's median
(`summarize.py`).

| Cell | a3 | a9 | a9/a3 | a4 | a4/a3 | a1 | a1/a3 |
|---|---|---|---|---|---|---|---|
| Sonnet t1 | 0.04998 | 0.05284 | 1.057 | 0.04470 | 0.894 | 0.03392 | 0.679 |
| Sonnet t2 | 0.04831 | 0.04687 | 0.970 | 0.05286 | 1.094 | 0.04406 | 0.912 |
| Sonnet t3 | 0.03547 | 0.03811 | 1.074 | 0.03758 | 1.060 | 0.03240 | 0.913 |
| Opus t2 | 0.12642 | 0.18269 | 1.445 | 0.18133 | 1.434 | 0.12773 | 1.010 |
| Opus t3 | 0.10481 | 0.10857 | 1.036 | 0.09956 | 0.950 | 0.09912 | 0.946 |

With no noise band declared, any higher median is a worsening. **Read literally, both port
variants fail the cost countermetric in batches 1 to 3** (a9 in four cells, a4 in three).
That record stands; nothing below redefines it. Bare (a1) is cheaper than a3 in four of
five cells and reached no best outcome (2.2).

### 2.4 Cold-cache runs in batches 1 to 3

Batches 1 to 3 launched runs four at a time. Per-run start times (result mtime minus
`duration_ms`) against cache-creation tokens show:

- **Opus:** all 6 runs with more than 18,000 cache-creation tokens (22,106 to 26,380) were
  first-wave runs with no same-model run finished in the previous 300 s; 18 of 18 runs below
  that line had one. By arm: a1 1 of 6, a3 0 of 6, a4 2 of 6, a9 3 of 6.
- **Sonnet, `CLAUDE.md` arms:** two runs passed the line, a8 `221a9294` and a9 `3e5bc7ce`.
  Neither had a warm same-model predecessor.
- **Sonnet, a2-pstack:** 7 of 9 runs passed the line (18,831 to 22,965), but a2 is not a
  cold-cache case. Its prompt is larger: its two runs under the line still wrote 17,494 and
  17,522 tokens. The `CLAUDE.md` arms' runs under the line wrote 6,908 to 15,378. All 7 of
  its runs over the line had a warm predecessor. Within a2's cells, the runs over the line
  wrote +2,738 (t1) and +4,756 (t2) more tokens than those under it; t3 had no run under it.
  Its two runs under the line cost $0.0711 (`2aa293b1`, t1) and $0.0756 (`2fe8d033`, t2),
  1.42 and 1.57 times a3's median.
- **Sonnet, all runs under the line:** 63 of 66 had a warm predecessor.
- **What a cold run looks like** (`cold-runs.py`), for the `CLAUDE.md` arms, from the
  median in the same arm and task: runs over the line wrote +9,814 to +13,508 more
  cache-creation tokens than runs under it, in batches 1 to 4. Their cache reads moved
  inconsistently, from -76,747 to +13,545.
- **Opus t2, a9:** two of its three runs (`4e5360ba`, `48b6a032`) were cold; its one warm run
  (`b5e4a2f3`, $0.122) cost less than the incumbent's median ($0.126).

In batches 1 to 3, every cold run of a `CLAUDE.md` arm lined up with launch order: none had a
warm same-model predecessor. So cost there could not separate the rule text from launch
order. Batch 4 then had a cold run that did have a warm predecessor (2.5), so launch order is
not the only cause of a cold run. This note names no other cause; nothing in the run's output
shows one. Neither finding is a pass.

### 2.5 Batch 4: warm-cache cost retest (predeclared)

**Pass condition:** `harness/vet-fixtures/pstack-2026-11/warm-cache-batch.md`, written
before the first batch-4 run and unchanged since. In short:

- Arms a3 and a9 only. Cells: Sonnet t1 to t3, Opus t2 and t3. Three runs per arm per cell.
- One run at a time, the arms alternating. One warm-up per model (`a1-bare` on t3,
  discarded).
- A scored run over 18,000 cache-creation tokens is cold and makes its cell invalid. No run
  is re-run selectively.
- In each valid cell: a9's median cost is at most 1.10 times a3's, a9's median turns are at
  most a3's plus 2, and both arms pass the hidden checks 3 of 3.
- PASS needs all five cells valid and passing.

**Disclosed about the condition:**

- **The 1.10 band came after the earlier data.** It was chosen once batch 1 to 3 cost
  ratios were known. a9 was already within 1.10 of a3 in four of those five cells; only
  Opus t2 (1.445) was outside it.
- **The evaluator came after the condition.** Batch 4's verdict was first computed by a
  session scratch evaluator, written after `warm-cache-batch.md` and about two minutes
  before the last batch-4 run finished. The committed `eval-warm.py` is a later port.
  This note's review re-derived every cell by hand from the run log, and the cells matched.

**Result: FAIL.** 32 runs, all exit 0, every scored run passed its hidden checks.

| Cell | Valid | a3 median $ | a9 median $ | a9/a3 | Turns a3 / a9 | Cell result |
|---|---|---|---|---|---|---|
| Sonnet t1 | yes | 0.0490 | 0.0494 | 1.007 | 7 / 7 | pass |
| Sonnet t2 | yes | 0.0491 | 0.0433 | 0.881 | 6 / 5 | pass |
| Sonnet t3 | yes | 0.0361 | 0.0372 | 1.032 | 6 / 6 | pass |
| Opus t2 | **no**, `0cc053d4` cold | 0.1373 | 0.1461 | 1.064 | 5 / 6 | **invalid** |
| Opus t3 | yes | 0.1038 | 0.1053 | 1.014 | 7 / 6 | pass |

- **The cold run:** `0cc053d4` (a9, Opus t2, second run) wrote 25,251 cache-creation tokens,
  against 12,154 to 13,191 for the other five runs in its cell, and cost $0.199. It started
  1 s after the previous Opus run (`7dd2fbfa`, a3) finished, so it had a warm same-model
  predecessor.
- **Every other run:** the two warm-ups were cold as intended (21,473 and 19,665 tokens), and
  no other scored run passed 18,000 (Opus 9,488 to 13,191, Sonnet 7,783 to 10,479).
- **Under the condition, the cost countermetric stays failed** (4.2). Four of five cells
  are valid, and all four are within 1.10.
- **No re-runs:** nothing was re-run and no fifth batch was launched. A batch launched now
  would be a search for a pass.

Primary metrics in batch 4 (reported, not part of the condition):

| Arm | Sonnet t2 | Opus t2 | Sonnet t3 | Opus t3 | Total |
|---|---|---|---|---|---|
| a3-incumbent | 1/3 | 0/3 | D D D | C C C | 1/12 |
| a9-trimmed | 2/3 | 3/3 | A D D | A A A | 9/12 |

- **Sonnet t1 was at ceiling again in both arms:** no false deletions, no unrequested public
  names, and `_legacy_format_row` kept.
- **Sonnet t3 did not repeat:** a9 reached class A in 1 of 3 runs (3 of 6 across batches 3
  and 4), below the decision rule's 2 of 3. The other three cells repeated or improved.
- **Diffs:** a9 on t2 added 2 to 7 source lines. On t3 it changed one line in three of six
  runs, and the class D runs added 4.

### 2.6 Armor and removal tests on the port's trailing clause

The a4 smallest-change line ends: "on the path you touch, delete private code nothing
references (grep first), and flag rather than remove public, compat or string-referenced
surfaces."

- **Armor test** (harness-vet Phase 5: "A rule needing more caveats than it has clauses has
  already failed the always-on bar"): one directive (delete unreferenced private code)
  against three caveats (scope to the touched path, grep first, the public/compat/string
  exception). Fails. A generous count, two against two, is still not a pass.
- **Removal test** (rent-check: "would the agent do something worse without this line?"):
  its target behavior, removing `_legacy_format_row` on t1, fired 0 of 3 times in a4, a7 and
  every other arm. Its exception restates the incumbent bullet "Don't remove or narrow
  existing config, flags, compat surfaces or callers as a side effect of a task that didn't
  ask for it; flag it instead."
- **Verdict:** rent-check CUT; replaced by nothing (the incumbent bullet already covers the
  exception). a9 is a4 with this clause cut, and it is the text 4.2 documents.

### 2.7 Delta triage (16 agents)

Eight readers each took a cluster of the delta, cited every claim to a file and line, and
returned a verdict; eight verifiers, one per reader, tried to refute each row. Six rows did
not stand as written and were corrected:

- create-formal-verification-skill: the incumbent claim was overstated; SKIP unchanged.
- interrogate, parked row 10's trigger: one clause is observable ("fixture beats code-slop
  16.0/18 with 0.0 false accusations"); the clause that depends on dotfiles#1202's text could
  not be checked.
- poteto-mode effort ladder: right verdict, wrong citation (the `docs/harness/claude-code.md`
  line did not say what the row claimed).
- The two principle leaves: quotes right, paths wrong; corrected to
  `skills/principle-subtract-before-you-add/SKILL.md` (lines 9, 11, 13-18) and
  `skills/principle-laziness-protocol/SKILL.md` (lines 9-10).
- architect: EXTRACT stands, but the consumer named (a `codebase-design` overlay) does not
  exist, so the four new red flags join parked row 13 rather than open new work.
- show-me-your-work `log.sh`: SKIP the truncation fix. This harness's port of row 2 is
  `scripts/dcg-update.sh` `record_outcome`, which appends through `mktemp` and `mv -f` and
  never copied `log.sh`, so the upstream fix has nothing to fix here.
- arena / swarm / recall / figure-it-out / automate-me: split per skill (section 3).

### 2.8 Limits of this evidence

- One fixture of three small tasks, n=3 per cell, `claude -p` only (no interactive turns,
  so a rule that makes the model ask a question ends the run).
- The same author wrote the traps and the lines. Each trap targets one of the doctrine's
  three claims, and the lines restate those claims. A fixture built that way favors the
  lines.
- a9's text was chosen after batches 1 and 2: it is a4 with the clause those batches showed
  never fired cut out. Choosing a9 over a4 (11 of 12) rests on the armor test, applied after
  the results were in (2.6). Batch 3 was a9's first run; batch 4 is its only replication.
- The incumbent arm is a five-bullet excerpt (694 bytes), not the live 14,438-byte
  `CLAUDE.md`. The live file has rules the lines may pull against: the autonomy, response
  shape and background-job rules (4.2, conflicts). None of those was in any arm.
- The fixture has no task whose complete change spans several sites. DocSpring's failure
  mode for minimal-diff rules, missing a sibling code path, is untested here. So is the
  tension with the live rule "Identify the full scope of affected components".
- No task needed a guard or a validation nobody asked for, so line 1's ban on unrequested
  guards was never tested against a case where one is correct.
- t3's grader flag `report_flags_premise` matches a fixed keyword list, so it undercounts
  premise flags phrased otherwise; class A requires the report to name the cause, which is
  matched separately.
- Opus ran on t2 and t3 only; t1 was at ceiling on Sonnet and was not re-run on Opus.
- Contenders other than Ponytail and Karpathy were triaged, not run (rows in section 3).
- No independent verifier re-executed the arms. The grader is mechanical and blind, and the
  run directories stay in scratch until the PR merges (README, Retention).

---

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| `principle-subtract-before-you-add` (leaf skill) | H | SKIP as a skill. Its no-speculative-guards rule ("No speculative validators, parsers, or guards beyond what the spec demands", `SKILL.md:16`) is one source of line 1 of 4.2. The line is **not adopted** | skill: no install; line: none (documented override option) | none | 2.2 to 2.5: the pair cleared the primaries in batches 1 to 3; cost failed in batches 1 to 3 and in batch 4; line 1 never met the rule alone; conflicts untested (4.2) | not adopted; override documented on the needs-human issue |
| `principle-laziness-protocol` (leaf skill) | H | SKIP as a skill. Its "Minimize the diff. Make the smallest change that solves the problem" (`SKILL.md:10`) is the other source of line 1. The line is **not adopted** | as above | none | as above | as above |
| Premise line, adapted from `poteto-mode` "If the evidence rules out the change the user asked for, show it and stop" (`SKILL.md:19`), weakened to flag-then-proceed. Also from "No is an acceptable answer" (`SKILL.md:90`), `playbooks/investigation.md:14` "Push back if the premise is wrong", and the posts' "understand the user's real need" | H | Line 2 of 4.2: **not adopted** | none (documented override option) | none | 2.2 (alone, 0 of 6 and never beat a3; with line 1, 9/12), 2.5; conflicts untested (4.2) | as above |
| Port line 1's trailing clause (delete private unreferenced code, flag public surfaces; from subtract `SKILL.md:13`, `:18`) | H | CUT | none | none | 2.6 (armor fails; target behavior 0 runs) | not proposed |
| `/poteto-mode` and pstack as an installed plugin | H, P | SKIP (prior verdict stands) | no install | none | 2.2 to 2.4 (a2, the plugin-with-router route as run: 4/6 at 1.6-2.3x median cost, mostly a larger prompt) | none |
| `create-verification-skill` @ `c49b37a` (three sentences: usable-from-empty readiness, seed-precondition failures go to Gotchas, stand-in steps stay unverified) | H | ADOPT verbatim into the vendored copy | `plugins/hov-stack/skills/create-verification-skill/` | explicit only (`disable-model-invocation`) | upstream diff; each sentence restates a rule this harness holds (no weakened assertions, no proof-class inflation); unverified value, no generator run | this PR |
| `maintain-verification-skill` | H | no upstream change; `path:` re-pin only | vendored copy | explicit only | `6714489f` is the last change to its path | this PR |
| benchmark-checklist Q1-Q3, Q6 (limiter, untuned side, limits arithmetic, share of end-to-end) | H | EXTRACT candidate, parked | `harness/evidence-regime.md` section 6 | on read | no incumbent text for limiter / untuned side / Amdahl; no consumer code (Ceremony Test risk) | parked |
| benchmark-checklist Q4, Q5, Q7, "before you run", report format | H | SKIP | none | none | covered: evidence-regime null-summary and VOID rules, ab-pair ABBA with a cv refusal | none |
| principle-explain-the-number | H | SKIP | none | none | restates checklist Q1 and Q3 | none |
| create-formal-verification-skill | H | SKIP | none | none | no consumer task; hard-wires `/statechart` | none |
| maintain-formal-verification-skill | H | SKIP | none | none | follows the create skill | none |
| statechart skill, `render.md`, view-module idea | H | SKIP | none | none | no TLA+ consumer; view API tied to the checker | none |
| statechart scripts (`run.ts`, launcher) | H | REJECT | none | none | executable plus network: fetches tla2tools 1.7.4 (sha256-pinned), installs java@temurin-25 via mise, kills process groups; `render.md` installs `pele@1.9.0` from npm with no hash | none |
| in-your-own-words, sharpen, poteto-help (+ `prompting.md`, `recipes.md`) | H | SKIP | none | none | goal-brief covers sharpen; poteto-help routes only to pstack and Cursor features | none |
| ketchup, ketchup-video | H | SKIP | none | none | ce-explain covers a work-window recap; ketchup-video names no render tool | none |
| poteto-mode router (mode / reminder frontmatter deleted upstream) | H | SKIP | none | none | prior mechanism SKIP stands | none |
| poteto-mode full-autonomy-grant sentences | H | SKIP | none | none | covered by CLAUDE.md "Drive, don't defer" and the pause / ask lists | none |
| poteto-mode first-message restatement ("open each final report with it") | H | SKIP | none | none | conflicts with CLAUDE.md "Lead with the answer … no preamble" | none |
| poteto-mode effort ladder ("lower it one step for judgment") | H | SKIP | none | none | conflicts with CLAUDE.md "Never lower effort to save tokens" | none |
| poteto-mode "Never fabricate a link, citation, or transcript reference" | H | EXTRACT, parked (prior row 5, text unchanged) | CLAUDE.md Honest Work | always-loaded | no observed defect since | parked |
| poteto-mode "Fresh subagents by default" (`SKILL.md:102`) | H | EXTRACT candidate, unverified, parked | `agent-swarm/SKILL.md` | on invoke | no incumbent text; no observed stale-resume defect | parked |
| `docs/harness/claude-code.md` (Cursor to Claude Code name map) | H | SKIP | none | none | maps a plugin we do not install | none |
| interrogate | H | SKIP; parked row 10's trigger is now the observable clause only | none | none | panel and lead judgment deleted upstream | none |
| reflect, why, how | H | SKIP | none | none | Cursor model-line plumbing and compaction; row 23's explorer "Open Questions" source is intact at `explorer-prompt.md:34` | none |
| architect, four new red flags | H | EXTRACT joins parked row 13 | none until a `codebase-design` overlay exists | none | `skill-architect` diff lines 65-87 | parked |
| show-me-your-work `log.sh` truncation fix, supersede-never-edit rule | H | SKIP | none | none | 2.7; the rule has no consumer | none |
| unslop | H | no new rules; #894 unchanged | none | none | compaction only, rule ids intact | none |
| tdd | H | upstream weakened it; keep the old text as row 17's source | none | none | step 7 and "say why" deleted upstream | none |
| blast-radius | H | deletions do not affect row 11 | none | none | the hand-back still says "write unproven" | none |
| arena, swarm, figure-it-out | H | SKIP | none | none | Cursor model fallbacks; agent-swarm and Workflow cover swarm | none |
| recall, automate-me | H | SKIP; rows 16 and 23 unchanged | none | none | one-line pointer to poteto-mode added upstream | none |
| Cursor delivery, now with a Claude Code install path | H | SKIP | no install | none | installing a plugin is a posture change; nothing here needs it | none |
| Other new skills (`correct` was vetted 2026-10-07) | H | SKIP by default | none | none | no consumer named | none |
| **Contender** Ponytail @ `2a1fe842` (lane 1, P1) | H | SKIP | no install | none | measured as a5: Sonnet t2 0/3, t3 C C C | none |
| **Contender** Karpathy CLAUDE.md @ `2c606141` (lane 1) | H | SKIP | no install | none | measured as a6: t2 1/3, t3 D D D; no LICENSE file; "mention dead code, don't delete it" | none |
| **Contender** DocSpring change-size @ `83b5b5d4` (P3) | H | PARTIAL | none | none | not armed; 7,310 bytes, about 30 times the two lines; deciding run below | none |
| **Contender** Anthropic "Overeagerness" and Sonnet 5.5 scope prompts (lane 2) | H | PARTIAL | none | none | not armed; deciding run below | none |
| **Contender** SeanDonahoe agents-md @ `3de7e8cb` (lane 1, P4) | H | PARTIAL | none | none | the only broad file with a premise clause; not armed | none |
| **Contender** Minimal Change Engineer @ `fd35c99e` (lane 3) | H | PARTIAL | none | none | not armed | none |
| **Contender** minimalist @ `6278f730`, moyu @ `bbfc66fe`, lean-code @ `99212ed2`, Honey @ `6eb60f9c` (lane 1, P1) | H | PARTIAL | none | none | not armed; moyu carries an over-asking risk, lean-code is a complement | none |
| **Contender** check-premises @ `260f4f18` (P1) | H | PARTIAL | none | none | complement for the premise line only; not armed | none |
| **Contender** Lawrentz ladder (lane 1) | H | PARTIAL | none | none | not armed | none |
| **Contender** Codex `gpt_5_2_prompt.md` (lane 2) | H | SKIP | none | none | the Codex runtime's own baseline; commit not resolved | none |
| **Contender** Claude Code 2.1.325 built-in prompt, "Doing tasks" section (lane 2): "Don't add features, refactor, or introduce abstractions beyond what the task requires"; "Only validate at system boundaries (user input, external APIs)" | H | baseline, already in every arm | built-in | always | a1 and a3 still over-build with it (2.2); its boundary-validation sentence is an untested conflict for line 1 (4.2) | none |

**Deciding run for every PARTIAL contender:** its text alone as an arm's `CLAUDE.md` (the way
a5 and a6 ran) on Sonnet and Opus t2 and t3, 3 runs each, in warm-cache order
(`launch-seq.sh`), against a9, under the validity rule of `warm-cache-batch.md`: a cell
holding a run over 18,000 cache-creation tokens is invalid and decides nothing. The contender
replaces a9 as the documented override option only if three things hold: it reaches the best
outcome in more of those 12 runs, every cell is valid, and its median cost is at most 1.10
times a9's. Adopting either one would still need the deciding run in 4.2.

### Do-not-retry unless

- The two `CLAUDE.md` lines (not adopted): the deciding run in 4.2 passes a condition
  written before it launches.
- pstack or `/poteto-mode` installed: pstack ships a Claude Code install whose per-run median
  cost on this fixture is within 1.10 times a9's, or this harness adopts Cursor.
- The principle leaves as installed skills: a task appears where invoking a leaf explicitly
  beats the always-loaded lines on this fixture.
- The trailing clause (CUT): a transcript shows an agent leaving an unreferenced private
  helper on a touched path that a reviewer then asks to remove, and a re-run of t1 with the
  clause removes it where a9 does not.
- statechart scripts (REJECT): a TLA+ consumer task exists and every download the scripts
  make is hash-pinned, `pele` included.
- benchmark-checklist EXTRACT: a benchmark claim in this harness ships without naming its
  limiter, and a reviewer catches it.
- Fresh-subagents EXTRACT: a resumed subagent acts on stale state in a recorded run.
- Any SKIP marked "covered": the covering text quoted in its row is removed or changed.

---

## 4. Changes: landed, and not adopted

### 4.1 Landed by this PR

- `plugins/hov-stack/skills/create-verification-skill/SKILL.md`: upstream `c49b37a`'s three
  sentences, verbatim. `UPSTREAM.md` re-pinned to `c49b37a2c0e7bede60a71ad7322e3f12c337a3da`
  with a `path:` line, so `scripts/vendored-drift-check.sh` reports `ok` until upstream edits
  this skill again. Update owner: whoever next sees that check report `MOVED`. Rollback:
  revert the PR.
- `plugins/hov-stack/skills/maintain-verification-skill/UPSTREAM.md`: `path:` line and pin
  `6714489fa233263f00e419f6cfc4759b07c81056`, the last upstream change to that path.
- `harness/vet-fixtures/pstack-2026-11/`: fixture, arms, grader, launchers, the batch-4
  pass condition. Retention and deletion condition in its README.
- This note.

### 4.2 Not adopted: two `CLAUDE.md` lines, documented as the operator's override option

The repo-root `CLAUDE.md` is the live `~/.claude/CLAUDE.md`, loaded by every session on this
host. Editing it is a permission-surface change only the operator makes (CLAUDE.md,
Autonomy: "Ask before security-posture changes: … editing … this file"). This section
records the verdict and the exact text, so an operator who wants to override the verdict has
the measured diff and knows what it lacks.

**Verdict: not adopted.** The reasons, in order:

1. **Cost failed.** a9's cost countermetric failed, read literally, in four of five cells in
   batches 1 to 3 (2.3). It also failed under batch 4's predeclared warm-cache condition,
   where one cell is invalid (2.5).
2. **The rule is per line, and only the pair cleared the primaries.** Line 2 alone never
   beat a3. Line 1 alone ran only in a longer form, with a clause since cut, and beat a3 in
   one cell. a9's line 1 never ran alone (2.2).
3. **The conflicts with live rules are unmeasured.** The table below lists them; every arm
   ran on a five-bullet excerpt of the incumbent.

**The documented override option** is the measured a9 text, unchanged. It is the only text
this vet measured as a pair, in batches 3 and 4. No reworded version is offered for adoption.

```diff
@@ Global Rules @@
 - Don't remove or narrow existing config, flags, compat surfaces or callers as a side effect of a task that didn't ask for it; flag it instead.
+- Make the smallest change that meets the request. Add no option, parameter, abstraction, validator or guard the request or spec didn't ask for.
+- If the code refutes the request's premise, say so with the evidence before building what was asked.
 - Conventional commit prefixes: feat, fix, perf, chore, docs.
```

**Precondition for an override: a deciding run, with its pass condition written before
launch.**

- **Arms:**
  - a3 is the full live `CLAUDE.md` as each arm's base.
  - a9 is the same file plus the two lines.
  - A third arm may test line 2 reworded to upstream's "show it and stop". That is what the
    run would test, not a proposal.
- **Tasks:** t2 and t3 again, plus at least two new ones:
  - a change whose complete fix spans two or more sites (DocSpring's sibling-path failure
    mode);
  - a change whose correct form needs a boundary validation nobody asked for.
- **Validity:** warm-cache order and the validity rule of `warm-cache-batch.md`.
- **Pass:** a9 beats a3 on each new task without worsening any countermetric, under a
  condition written first. This vet does not run it.

**Effect size on this fixture:**

- **Batches 1 to 3:** a9 reached the best outcome in 9 of 12 runs, against a3's 1 of 12. If
  Opus t3's C counts as a tie, that is 6 of 9 against 1 of 9 (2.2).
- **Batch 4** repeated the totals, 9 of 12 against 1 of 12, with Sonnet t3 down to 1 of 3.
  Median cost per run was within 1.10 times a3's in each of its four valid cells (2.5).

**Conflicts with live text, none measured.** Every arm ran on a five-bullet excerpt, so
none of these rules was in any arm.

| Live text | Line | Tension | Verdict |
|---|---|---|---|
| `CLAUDE.md` Global Rules: "Identify the full scope of affected components, not just what's mentioned. Diagnose root causes: grep every caller before editing; one guard in the shared function beats one per call site." | 1 | "Smallest change" can read as touching fewer sites; "Add no … guard" can read against the endorsed shared guard | untested: no multi-site task, no task needing a guard |
| Claude Code 2.1.325 built-in prompt: "Only validate at system boundaries (user input, external APIs)." | 1 | "Add no … validator or guard the request or spec didn't ask for" can suppress boundary validation the built-in prompt asks for | untested: no task had an unvalidated boundary |
| `CLAUDE.md` Honest Work: "Real code and real tests in the same unit of work." | 1 | Smallest change can mean fewer tests | untested as a rule. Observed: on Sonnet t2, a9 added tests in 0 of 6 runs and a3 in 2 of 6. On Opus t2, a9 added 10 to 12 test lines per run and a3 13 to 19. On Opus t3, a9 added 6 to 8 and a3 6 in every run. This is not a predeclared countermetric. |
| `CLAUDE.md` Honest Work, forbidden: "narrowed scope claimed as full success" | 1 | Class A skips the dedupe the request asked for; if the report does not say so, that is narrowed scope | partly covered: class A requires the cause named in the report, by keyword match only (2.8) |
| `CLAUDE.md` Global Rules: "Resolve ambiguities from code, patterns and context; ask only when truly blocked." | 2 | Line 2 says to state the evidence, not to ask, so the wording is compatible; "before building" could still read as a pause | untested: `-p` runs cannot pause |
| `CLAUDE.md` Autonomy: "Drive, don't defer." | 2 | A pause before building reads as deferring | untested |
| `CLAUDE.md` Response shape: "Finish one thing before raising the next … otherwise surface it once, at the end." | 2 | Line 2 puts the flag before the build, not at the end | untested |
| `CLAUDE.md` harness rule for background jobs: `needs input:` carries a filed `needs-human` issue citing a category | 2 | A stop-before-building reading in a background job has no escalation category to cite | untested |
| pstack `poteto-mode/SKILL.md:19`: "If the evidence rules out the change the user asked for, show it and stop." | 2 | Line 2 weakens "stop" to flag-then-proceed, on purpose. Run `3e5bc7ce` is the cost: it flagged, then built the dedupe. | not tested against the "stop" wording |
| `CLAUDE.md` Global Rules: "Don't remove or narrow existing config, flags, compat surfaces or callers as a side effect of a task that didn't ask for it; flag it instead." | 1 | none; it covers what the cut clause tried to say (2.6) | complementary |

- **Price if adopted:** +247 bytes (about 60 tokens) on a 14,438-byte file (+1.7%), loaded
  in every session.
- **Provenance:**
  - Line 1 adapts two rules and extends them to options and parameters, which neither
    source names:
    - laziness (`principle-laziness-protocol/SKILL.md:10`, "Minimize the diff. Make the
      smallest change that solves the problem.");
    - subtract's no-speculative-guards rule (`principle-subtract-before-you-add/SKILL.md:16`,
      "No speculative validators, parsers, or guards beyond what the spec demands").

    It does not carry subtract's namesake rule, "remove complexity first, then build".
  - Line 2 adapts poteto-mode (`SKILL.md:19`) and weakens its "stop" on purpose. It also
    draws on `SKILL.md:90` and `playbooks/investigation.md:14`.
  - Upstream pins: the leaves at `08bd59b3` and poteto-mode at `c742dd61`. A few words
    overlap upstream wording ("smallest change", "validators … or guards"), but no upstream
    sentence is copied whole.
- **Placement if adopted:** global, because the lines target coding behavior in any project.
  The plugin-with-router route as run (2.2 to 2.4) cost more per run than the always-loaded
  lines. No other on-invoke route was measured, so this does not rule one out.
- **If an override is taken, take a9's text, not a4's.** a4's longer line 1, with the
  trailing clause, scored 11 of 12 against a9's 9 of 12 in batches 1 to 3. But it fails the
  armor test (2.6) and was not in batch 4.
- **Known limit, worded in:** line 2 lets the model flag the premise and still build what was
  asked (`3e5bc7ce`).
- **Update owner:** the operator. **Rollback:** delete the two lines.
- **Re-measure when:** any of these changes:
  - the default Sonnet or Opus model;
  - Claude Code's built-in "Doing tasks" prompt (the removal test dates with the model;
    rent-check);
  - the live `CLAUDE.md` rules in the table above.

---

## 5. Shared versus target findings, prior notes, dropped hits

- **Shared (true of pstack wherever it lands):** the principle leaves are explicit-only and
  reached through a router. The plugin-with-router route, as run, cost 1.6 to 2.3 times the
  incumbent per Sonnet run on this fixture, mostly from a larger prompt. The statechart
  scripts fetch and run code.
- **Target-specific (H):** three poteto-mode additions conflict with standing rules here
  ("Lead with the answer", "Never lower effort to save tokens", the autonomy rules already
  cover the grant text); the two leaves' value only shows once their content is always
  loaded, which here means `CLAUDE.md`, a gated surface.
- **Prior notes reused:** `docs/vets/2026-09-18-pstack-harness-vet.md` (rows 5, 10, 13, 16,
  17, 23 re-checked against the delta; none changes state);
  `docs/vets/2026-10-07-correct-retro-family-harness-vet.md` (`correct` not re-vetted);
  the vendored verification skills' `UPSTREAM.md`.
- **Applicability changes:** the prior vet's unsupported-frontmatter finding on poteto-mode
  is moot (upstream deleted `mode:` and `reminder:`); interrogate's lead-judgment panel, the
  basis of parked row 10, is gone upstream.
- **Dropped at triage, one reason each:** Karpathy forks and 13 wrappers (collapse to
  multica-ai/andrej-karpathy-skills); Ponytail packagings in context-labs/whip,
  SMUnlimited/AMAI, cheaper-inference/OmniRoute, jwiegley/dot-emacs,
  tensakulabs/hermes-ponytail, jimoto-no-llm/rustdsh (collapse to Ponytail); unopened
  code-search repos (match phrases in their own project files); cursor.com/docs/rules
  (format only, no operative text); openai/codex `docs/agents_md.md` (a pointer);
  the Opus 4.5 migration snippets (404); other agency-agents, Anbeeld, fable5 and herdr-sbx
  files (not opened); Think-Before-Coding blog posts (no text beyond the repos read); caveman
  (prose compression, not diff size); three pstack-versus-Ponytail research docs in other
  repos (not opened).

---

## 6. Audit dividend, triggers and spend

**Audit dividend.**

1. **Cost per run is a noisy countermetric for prompt-text arms.** A cold prompt cache adds
   about 10k to 13.5k cache-creation tokens to a run of a `CLAUDE.md` arm (2.4). In batches
   1 to 3, those arms' cold runs followed launch order (2.4); in batch 4, one came with a
   warm predecessor (2.5). Running arms one at a
   time does not prevent cold runs. A vet that uses cost as a countermetric needs two things
   in its report: per-run cache-creation tokens, and a validity rule for cold runs written
   before launch, as `warm-cache-batch.md` was. Candidate line for harness-vet Phase 4; not
   landed here.
2. **`testing-fuzzing/SKILL.md:633` and `:680`** (jsm-managed, outside this repo) point to
   `/lean-formal-feedback-loop`, which is in the jsm catalog (2026-08-06) but not installed
   on this host.
3. **Line-number citations into `CLAUDE.md` drift.** Two triage rows cited `CLAUDE.md` by
   line, and the lines had moved; quote the rule's text instead, as this note does.
4. **The fixture's premise flag is a keyword match** (2.8); a later vet that scores premise
   flags should grade the report text, not keywords.

**Re-audit triggers.** Upstream changes either leaf (path-scoped; last `08bd59b3`) or
`poteto-mode` (last `c742dd61`); `scripts/vendored-drift-check.sh` reports `MOVED` for either
verification skill; the default model or Claude Code's "Doing tasks" prompt changes (re-run
a1, a3, a9 on the fixture).

**Spend.** Batches 1 to 3: 99 runs, $6.87 by `total_cost_usd`. Batch 4: 32 runs, $2.51
including the two warm-ups. Behavioural total: 131 runs, $9.38.
Triage workflow: 16 agents, 562,863 subagent tokens. X reads: about $0.03.
