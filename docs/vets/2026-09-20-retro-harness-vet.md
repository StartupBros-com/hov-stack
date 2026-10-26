# Harness vet: `mattpocock/skills` → `skills/in-progress/retro`

**Date:** 2026-09-20
**Candidate:** https://github.com/mattpocock/skills/blob/main/skills/in-progress/retro/SKILL.md
@ `c55ee46073ed923f86ce59a5eb3b6d895095d1b7` (2026-09-18), MIT.
Component = `skills/in-progress/retro/` — `SKILL.md` (4,369 B) + `agents/openai.yaml`.
**Self-description:** "Conduct a retrospective on a coding session."
**Upstream's own label:** `skills/in-progress/README.md` — *"STUB: design notes only,
not functional yet. User-invoked."* The bucket is excluded from the plugin and the
top-level README, gets no docs page, and "can change or disappear without warning."
**Target vetted:** one — global harness scope (`~/.claude` + `~/.codex`).
**Landing depth:** report-only. Nothing was installed; no skill was added, removed or
re-pinned; `~/.agents/.skill-lock.json` is untouched.
**Run choices:** target inferred from `/harness-vet` with no target named. Single
component, so no triage stage. Concrete task fixed as: *after a coding session, propose
improvements to the agent's environment (steering files, standards, automated checks,
tooling, information access)*.

---

## 1. Headline

**SKIP the skill at global scope. REJECT the documented install command. EXTRACT nothing
now; one wording gap filed as an issue.**

retro is safe, cheap and well-formed — and on a nine-defect fixture it showed **no measured
advantage over the bare model** (7.00 vs 6.67 of 8, n=3/arm) and **lost to the incumbent
`rent-check`** (7.33, with 16 extra real findings against retro's 3). Three of its seven
categories are already covered by rent-check, which does them better; the four it uniquely
claims were exercised by the fixture and the bare model handled them unaided.

The vet's most useful output is not the verdict. It is the **audit dividend**: `rent-check`,
an installed harness skill, wrote to the target repo in **3 of 3** runs, against its own
`SKILL.md:350` rule "Report first, edit never."

---

## 2. Measured, not inferred

Runtime: Claude Code 2.1.278, WSL2, session model Opus 5. All arm runs used `--model sonnet`,
`--max-turns 35`, each under its own `CLAUDE_CONFIG_DIR` so no arm inherited the operator's
live skills, plugins or settings. Fixture, answer key, runner and all nine graded outputs:
`harness/vet-fixtures/retro-2026-09/`.

### Behavioral comparison (3 arms x 3 trials, $4.53 total)

Fixture `orderflow`: a synthetic TypeScript service with nine planted environment defects
and three controls, plus a session transcript that trips most of them. Three defects sit
**outside** retro's own seven-category taxonomy, so the fixture does not merely test whether
the candidate can recite itself. Arms differ only by a leading slash token.

| arm | defects found (of 8) | valid traps tripped | extra real findings | mean cost | repo modified |
|---|---|---|---|---|---|
| bare control | 7, 7, 6 → **6.67** | 0 | 7 | $0.34 | 0 / 3 |
| **retro** | 7, 7, 7 → **7.00** | 0 | 3 | **$0.29** | **0 / 3** |
| rent-check (incumbent) | 8, 7, 7 → **7.33** | 0 | 16 | $0.87 | **3 / 3** |

Scored blind by two independent graders against a sealed key, outputs relabelled `r01..r09`
in shuffled order with the mapping withheld. **The two graders agreed on every per-report
defect count.** They differed only on extra-finding tallies (7/3/16 vs 5/2/14) — same
ordering, same magnitude.

Validity checks, run before scoring:

- retro's doctrine reached its arm's context (its "Tool economy" category string appears in
  the a2 transcript and is absent from bare), and its arm executed step 1 by invoking
  `writing-for-agents` through the Skill tool. The slash actually fired.
- `writing-for-agents` was placed in **all three** arms' config dirs, because retro step 1
  calls it. The bare arm made zero Skill calls, so shared availability produced no
  differential access.
- Per-arm tool logs: retro 3/3/6 Bash calls, bare 7/4/9, rent-check 23/11/19.

### What separates the arms

Not defect detection — at n=3 those spreads are parity. Three real differences:

1. **Thoroughness comes from running, not reading.** rent-check found 16 real problems the
   key never planted: no `tsconfig.json`, zero spec files, `@eslint/js` absent so `pnpm lint`
   crashes outright, `gen-types.ts` a non-functional stub. It ran the gates. retro's text
   tells the agent to *read* the repo's check scripts and CI workflow; its arms ran the
   fewest commands of any arm and found the fewest extras.
2. **retro names a category it does not operationalize.** It declares a **"No-ops"**
   category; its arms mentioned the two planted no-op lines **0 times in 3**. The only run
   of nine that surfaced them was a rent-check run applying its five-filter screen and then
   explicitly declining to act on them. At 1 of 3 that is a weak contrast, but 0 of 3
   against a category the skill itself names is the substantive point.
3. **Counter-finding discipline.** Only rent-check runs (2 of 3) explicitly defended
   something as correct and worth keeping. No retro or bare run did.

### Delivery, verified from source

The upstream-documented install command **does not work**. The README says
`npx skills@latest add mattpocock/skills --skill=<name>`. In `vercel-labs/skills@1.7.0`
(`7407f38`), `parseAddOptions()` matches `--skill` by exact string equality with no
`=`-splitting, and the positional fallback rejects any token starting with `-`. So
`--skill=retro` is silently dropped, `options.skill` stays undefined, and the command falls
into the no-skill-specified branch — which, per this harness's 2026-08 finding, goes
non-interactive inside an agent session and installs **everything**, project-scoped to cwd.
Only `-s retro` (space-separated) works. Confirmed from source; no install was run.

The CLI's discovery walk ignores the plugin manifest entirely, so the `in-progress`
exclusion (a literal 24-path allow-list in `.claude-plugin/plugin.json` with zero
`in-progress` entries) offers **no protection** against installing retro.

### Supply chain and cost

- No `postinstall`/`preinstall`/`prepare` anywhere in the repo. The skills CLI only clones
  and copies; it never executes code from the cloned repo (`install.ts`, `installer.ts` and
  `download-source.ts` contain no `exec`/`spawn`/`npm install`).
- `scripts/link-skills.sh` writes symlinks outside the repo but is manual, maintainer-only,
  and self-labelled "not a supported installer."
- All four retro commits are prose-only. No executable code, schema or state has ever
  shipped in this component.
- **Context cost ~0.** `disable-model-invocation: true` maps exactly onto absence from the
  always-loaded skill list on this box (verified against rent-check, measure, harness-vet,
  memory-mine and design-drift, versus papercut, tdd and wizard). retro already ships that
  flag and a correct `agents/openai.yaml` Codex gate, so adoption would need no
  `skillOverrides` entry (79 today) and no settings-guard ask.
- Sole hard dependency is `writing-for-agents`, which resolves here (`~/.claude/skills/` and
  `~/.codex/skills/`, vendored, pinned at `8b36d4f` with the body swapped to skill-tuner
  doctrine v3 on 2026-08-08).

### Corrections to my own digest

- **"Single author" is wrong.** retro's most recent commit (`0243b6e`, 2026-09-15) is
  authored by `Claude Sonnet 5 <noreply@anthropic.com>` via PR #1083; a superseded draft
  (PR #889, closed unmerged) came from `Remote Box Agent`. Governance remains single-human —
  mattpocock authored or merged every retro change.
- **"Not functional yet" is refuted by upstream's own tracker.** Issue #1010 records a real
  session running `/retro` over its own session JSONL and producing findings. The author
  removed the STUB text from the skill's frontmatter in commit 2 and moved it to the bucket
  README, where it went stale.
- `agent-native-audit` is **not** an incumbent here — it audits a *product's* agent-facing
  architecture, not the authoring harness. `denial-triage` is a slash command
  (`commands/`) and `harness-audit-2026-07` is a Workflow script; neither is a skill
  and neither performs retro's sweep.

### Limits of this evidence

Recorded because they bound what the numbers support. **Three flaws in my own fixture:**

- **D7 was mis-planted** and is excluded from all scores. It assumed a bloated `CLAUDE.md`;
  the file is 36 lines, inside every size threshold. All nine reports declined to raise it,
  and they were right. Scores are therefore out of 8, not 9.
- **T2 is weaker than designed.** The fixture's CI exists but cannot pass (no
  `tsconfig.json`, no spec files, `@eslint/js` missing). Arms that ran the gates found real
  breakage the key never planted — a true finding, not a tripped trap.
- **T3 was invalid.** The key asserted `docs/architecture/request-flow.md` "matches the
  code"; it does not — it describes a `src/core/handlers/` directory that was never created.
  A retro arm correctly flagged this and one grader scored it as a false finding. **Voided**,
  and the arm credited. No arm tripped a valid trap.
- One fixture, sonnet, n=3. Enough to refute a large claimed effect, not to resolve a small
  one.
- **The fixture approximates retro's real home.** retro is built to mine *session logs on
  this machine*; the fixture handed every arm a pre-digested markdown transcript. That
  removes the step where retro's guidance might matter most. This is the single biggest
  reason the SKIP below is scoped rather than absolute.

---

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| `retro` (skill content) | global harness | **SKIP** | no installation | n/a | CONFIRMED (n=3/arm, 2 blind graders) | not installed |
| skills-CLI install path as documented | global harness | **REJECT** | no installation | n/a | CONFIRMED (source-traced, `vercel-labs/skills@1.7.0`) | not installed |
| "no guardrail at all is a finding" clause | `rent-check` RUBRIC E4 | **EXTRACT — deferred** | `skills-local/rent-check/RUBRIC.md` | n/a | PARTIAL (marginal value unproven) | filed as #1245, not landed |

**Rollup for global harness scope: 0 ADOPT / 0 ADAPT / 0 EXTRACT landed / 1 SKIP /
1 REJECT, plus 1 deferred extraction.**

### Why SKIP rather than ADOPT

Category-by-category coverage, each claim requiring both a named mechanism and its control
surface, with a default of REFUTED:

| retro category | verdict | covering mechanism |
|---|---|---|
| Coding standards (mechanical vs judgement) | **CONFIRMED covered** | `rent-check` Doctrine #2 + RUBRIC E1, via `/rent-check` |
| Global AGENTS.md / CLAUDE.md | **CONFIRMED covered** (multiply) | `rent-check` L1/L3, harness-doctor check 5, `claude-setup-auditor`, built-in `/doctor` |
| No-ops | **CONFIRMED covered** | `rent-check` RUBRIC Q1 five-filter + Q2 removal test |
| Navigation | not covered | nothing audits hidden file-to-file dependencies |
| Automated checks | partial | `rent-check` E4, but scoped to scripts *referenced by a rule* |
| Tool economy | not covered | only `PreToolUse/read-ceiling-chunk.js`, one narrow slice |
| Information access | not covered | the data-source CLIs are supply already granted, not gap detection |

Four uncovered categories would normally argue for adoption. They do not here, because the
fixture exercised three of them directly — the generated-file dependency (navigation), the
mandatory 419-line status dump (tool economy), and the silenced dev server (information
access) — and **every arm including bare found all three**. An uncovered category is not a
demonstrated need when the bare model already handles it.

### Why REJECT the documented delivery

Not a judgement about retro's content. The published command degrades to
install-everything inside an agent session. Should retro ever be installed, the only correct
form is:

```
npx skills@latest add mattpocock/skills -g -s retro -a claude-code codex -y
```

### Do-not-retry unless

- retro graduates out of `skills/in-progress/` into a stable bucket **and** gains an
  executable procedure (a script, a schema, or step-level structure) rather than another
  prose expansion — all four commits to date are prose-only; **or**
- a fixture that gives arms **raw session JSONL** rather than a pre-digested transcript
  shows retro beating both bare and `rent-check`. This is the recorded gap in the present
  evidence; **or**
- this harness acquires a session-end trigger and needs a body of doctrine to hang on it,
  where `rent-check`'s context-file scope is demonstrably too narrow; **or**
- `rent-check` becomes unavailable or is narrowed out of categories 3, 4 and 6.

Bare time, upstream popularity, or a further prose commit do not reopen this.

---

## 4. Audit dividend

**1. `rent-check` violates its own write boundary — 3 of 3 runs.** Its `SKILL.md:350` says
"Report first, edit never — all changes ship as drafts and diffs; the operator applies
them," and `SKILL.md:9` says verdicts are "never auto-applied." In the three control-arm
runs it:

- ran `pnpm install` and **accidentally `git init`'d the target repo**, then asked the
  operator to run `rm -rf repo/.git` by hand because its own cleanup was guard-blocked (r06);
- ran a real `pnpm install` and **edited `package.json`** — "Fixed as part of finding #6's
  diff (added `@eslint/js` to devDependencies)" (r02);
- modified the repo and reported "Repo restored to original state" (r05).

Two of the three disclosed the side effects honestly, which is to rent-check's credit. The
boundary is still crossed every run, and a skill that hands the operator an `rm -rf` to run
inverts this harness's agent-native convention. Filed as **#1244**, with the tension noted
there: running the gates is exactly *why* rent-check found 16 real problems the read-only
arms missed, so the repair should relocate the writes, not forbid them.

**2. Confirmed gap: nothing on this harness triggers at session end.** No `SessionEnd` hook
is wired at all; the only `Stop` hook is `verify-on-stop.js`, a pass/fail verification gate
that proposes nothing. `harness-weekly.timer` is calendar-driven, not session-driven. Worth
recording — but note that adopting retro would **not** close it, because retro is a manually
invoked prompt skill, not a trigger.

**3. Dogfood probe on retro's own sharpest rule — clean null.** retro's 2026-09-15 clause
says a check that exists but sits unwired is itself the finding. Against this repo's CI: 34
suites are not named individually, but `dcg/tests/*.sh` is globbed
(`harness-tests.yml:759`) and `tests/test_*.py` is covered by `unittest discover`
under `working-directory: claude` (:1657). The two genuine remainders both carry headers
documenting deliberate exclusion. The workflow already states the rule verbatim: *"A suite
on disk is not a suite in CI."* No finding — this harness is ahead of the candidate here.

---

## 5. Prior notes and reuse

Reused from `mattpocock-skills-evaluation-2026-08` (2026-08-06, 12-agent pass): the plugin
route was rejected there and nothing in this vet reopens it; skills.sh remains the install
path; the `-s`/`-a` space-separated and install-everything-in-an-agent-session traps are
reconfirmed here from CLI source. That vet's **fit** conclusion does not apply to retro,
which was created 2026-08-24, eighteen days after it.

Also reused: `codex-openai-yaml-invocation-gate` (Codex honours
`policy.allow_implicit_invocation`; retro ships it correctly) and
`writing-for-agents-adoption-2026-08` (the vendored dependency and its pin).

Searched: `~/.claude/projects/-home-user-hov-stack/memory/`, `docs/vets/`,
`harness/`. No prior note on `retro` specifically exists; this is the first.

---

## 6. Re-audit triggers

Re-read this note if the `skills` CLI changes its argument parser — the `--skill=` finding is
version-pinned to `vercel-labs/skills@1.7.0` / `7407f38` — or if `rent-check`'s scope changes
such that categories 3, 4 and 6 are no longer covered.
