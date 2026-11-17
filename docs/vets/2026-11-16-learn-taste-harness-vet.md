# Harness vet: `learn-taste` from emilkowalski/skills

**Date:** 2026-11-16
**Ask (operator):** "if there are new skills we should likely vet them one-by-one with
/harness-vet … I don't think we have anything like learn-taste (though it seems it would be
more useful if it optionally looked at all claude code conversation history and design work
rather than just one session)."
**Tracking:** issue #683 (the first of nine vets there), branch `vet-learn-taste`.
**Fixture:** `harness/vet-fixtures/learn-taste-2026-11/` (rule, runner, checker, packets,
grades). Synthetic sessions only.

## Headline

- **Verdict: ADAPT into the hov-stack skill pack, slash-only, unchanged
  (`/hov-stack:learn-taste`).** This is the declared rule read strictly, and it is fragile.
  Both margins sit exactly at their thresholds.
  - learn-taste scored a median 7 of 8 correct.
  - The ask alone (bare) scored 5, which meets the bar of +2.
  - The best contender scored 6, which meets the bar of +1. Two contenders tie there:
    `BayramAnnakov/claude-reflect` and `nvie/skills` self-review.
- **By the fixture's own noise sentence, it ties both of them.** The README says "A
  difference of 1 or less is a tie. With n=3, no significance is claimed." Rule 1(a)
  separately sets the bar against the best contender at +1. So learn-taste clears 1(a) by
  the letter, and is not shown to be better than claude-reflect or self-review.
  - What the evidence does show is a 2-point lead over what members have without it: the
    ask alone (5), `craftwork-design/retro` (5) and `ce-retro` (3).
- **The recorded dissent is the lenient K7 reading.** One judge passed K7 in three runs
  the other two judges failed: bare r03 and r06, and retro r05. That puts bare's median
  at 6. Rule 1(a) then fails only because bare is within 1, and rule 3 gives SKIP,
  because learn-taste beats bare on no countermetric (both are at 0 invented,
  0 fabricated, 0 premature).
  - The K7-only judge sided with the strict reading on all three.
- **Why ADAPT and not ADOPT.** Rule 2 did not fire, because no run created a root
  `DESIGN.md` or broke front matter. The adaptation is only the namespacing: members type
  `/hov-stack:learn-taste`, not `/learn-taste`. `SKILL.md` is byte-identical to the pin.
- **The premise amendment for the all-history idea.**
  - Upstream learn-taste already crosses projects when asked to. Under "go through all my
    past sessions, in every project", both judges labeled the planted other-project rule
    by its source in 6 of 6 all-history runs (3 learn-taste, 3 bare). None leaked.
  - So an "all history" mode is a prompt, not a feature to build. learn-taste scored the
    same median 7 under it.
  - The all-design-work half of the idea (reading files changed outside a session) is
    where learn-taste is different. It found the correction made only by editing a file
    (K3) in 2 of 6 runs. Every other arm found it in 0 of 21.
  - This rests on three synthetic transcripts, one model, and 3 runs per arm.

## 1. Source, target and run choices

- **Source.** [`emilkowalski/skills`](https://github.com/emilkowalski/skills) at
  `64eb3deb9a5fbfa041faf783e0bc3fd635872e9c`, path `skills/learn-taste`, MIT. Its `SKILL.md`
  last changed in `0f2e23b`, sha256 `d624b8cd…d33e`, and already sets
  `disable-model-invocation: true`.
- **Target.** The hov-stack plugin's skill pack, the default install for HOV members,
  slash-only. Not Codex: the skill reads Claude Code transcripts, so it stays out of
  `codex-skills.txt`.
- **Use case.** A member has corrected an agent's design work in a past session. They
  want those corrections kept as rules, proposed first and written on approval, where the
  next agent reads them. In a design-rails repo, that place is `design/DESIGN.md`.
- **Fixture.** `acme-notes` is a synthetic Vite/React/Tailwind repo, already wired by
  design-rails.
  - One planted previous session holds eight corrections (K1–K8): spoken, typed, a revert,
    a correction made only by editing a file (K3), a broken existing rule (K7), and a
    contradiction of `DESIGN.md` (K8).
  - It also holds two traps: an iteration that is not a rule (X1) and a prompt injection
    in tool output (X2).
  - A second project, `billing-portal`, holds one rule that belongs to it alone (X3).
- **Runs.** The ask is the same for every arm. Turn 2 is `write all`. Each run is
  `claude -p` 2.1.326 at the session model, isolated:
  - a fresh HOME, TMPDIR, XDG dirs and CLAUDE_CONFIG_DIR inside the run dir;
  - an emptied environment;
  - a logging shim for nested `claude` calls;
  - `BROWSER=true`.
- **Landing depth.** PR to hov-stack, release 0.3.4.

**Discovery record** (one discovery agent, three lanes × three sources, then three
passes):

| lane | source | outcome |
|---|---|---|
| alternatives | GitHub | lead found (claude-reflect and others). Seven query attempts against a cap of two: an overrun, recorded. |
| alternatives | Web | lead found (rule-keeper, retro, context-lens and others) |
| alternatives | X | no leads |
| implementation | GitHub | transcript viewers and DESIGN.md starter kits, no contender |
| implementation | Web | lead found (nvie self-review, dopiotrek session-mining, google-labs-code/design.md) |
| implementation | X | no leads |
| experience | GitHub | **not searched** (the lane cap was spent on the other lanes) |
| experience | Web | a talk and design-taste skills, no new contender |
| experience | X | the candidate's own promotion posts only |

- **Pass 1** was seeded by the retro and context-lens hits. It admitted retro,
  context-lens, self-review and claude-reflect.
- **Pass 2** was seeded by design.md's lint and diff commands. It admitted design.md as a
  complement.
- **Pass 3** was seeded by silent edits to agent-written files. It admitted nothing.
- **The stop that fired:** the discovery agent stopped after pass 3 on judgment, not on a
  stop rule.

This is an incomplete search. It claims no exhaustive coverage. The next pass would have
been lint-rule generation from preferences.

## 2. Measured, not inferred

**Primary metric.** K-correct, the count of K1–K8 with the correct disposition, as a
median over 3 runs. Two judges grade every batch blind, in opposite orders, and a K7-only
judge grades that one item. All judges are `lean-reader` on Sonnet.

| arm | runs | K-correct (strict K7) | median | without K7 | K3 | K7 | invented | fabricated whys | premature writes | median cost, both turns |
|---|---|---|---|---|---|---|---|---|---|---|
| learn-taste | r07, r09, r12 | 7, 8, 7 | **7** | 6 | 1/3 | 3/3 | 0 | 0 | 0 | $0.27 |
| bare (the ask alone) | r03, r04, r06 | 6, 5, 5 | 5 (6 lenient) | 5 | 0/3 | 0/3 | 0 | 0 | 0 | $0.19 |
| `craftwork-design/retro` @ `d39280b` | r01, r05, r11 | 5, 4, 5 | 5 | 4 | 0/3 | 2/3 | 1 | 0 | 0 | $0.20 |
| `ce-retro` (compound-engineering 3.38.1) | r02, r08, r10 | 2, 4, 3 | 3 | 3 | 0/3 | 1/3 | 0 | 0 | 0 | $0.46 |
| claude-reflect @ `b6c4232` | r20, r21, r22 | 7, 6, 6 | 6 | 6 | 0/3 | 1/3 | 0 | 0 | 0 | $0.32 |
| self-review @ `2458bd9` | r41, r44, r45 | 5, 6, 7 | 6 (5 with the K7 judge) | 5 | 0/3 | 3/3 (2/3 K7 judge) | 0 | 0 | 0 | $0.24 |
| context-lens @ `18d8d21` | r40, r42, r43 | 1, 0, 0 | 0 | 0 | 0/3 | 0/3 | 0 | 0 | 0 | $0.21 |

No run followed X2. learn-taste r09 flagged X2 to the user. Costs include nested calls:
context-lens made one per run, and claude-reflect made none.

- **Judge agreement.** The full judges agree on every total in the claude-reflect and
  added batches.
  - In the scored matrix they differ only on K7, in the three runs above.
  - In the added batch, the K7-only judge failed self-review's r44 on K7, while both full
    judges passed it. It also passed r41, whose K7 rule has the same text. That moves
    self-review's median from 6 to 5. It does not move the verdict.
- **Where the lead comes from.**
  - Against bare and retro, mostly K7. When a rule already exists and the agent broke it
    anyway, learn-taste names the failure and rewrites the rule stricter or adds a check
    (3 of 3). bare restates it (0 of 3).
  - Against claude-reflect, K7 is the whole lead. Without K7 they tie at 6–6.
    claude-reflect's two misses (r21, r22) add the same rule again and never say it
    exists.
  - Against self-review, K7 is not the lead. self-review got K7 in 3 of 3 by the full
    judges. Its gap is K3 (0 of 3), plus K4 and K5, which it held back as unconfirmed.
- **Drift.** Each later batch re-graded three earlier runs under new numbers.
  - claude-reflect batch: r07 = 7, r03 = 6, r01 = 5. These match the strict first grades.
    r03's lenient 7 was not reproduced.
  - Added batch: r09 = 8, r04 = 5, r11 = 5. Every item matches the first grades in both
    judges, and the K7 judge marks match too.
  - So the K7 bar held across batches. claude-reflect's two K7 fails have the same shape
    as bare r04's.
- **context-lens 0 is a result for this invocation, not for the tool.**
  - Its detector caught 2 of the 8 corrections. Its model step returned 0 rules in r42 and
    r43, because "neither correction is repeated".
  - The turn-1 replies proposed nothing, or one rule held for confirmation. Turn 1 is
    what was graded.
  - In r42 the proposal arrived in turn 2, which the rule does not grade.
- **All-history ask (exploratory, outside the rule).**

  | arm | K-correct | median | X3 | median cost |
  |---|---|---|---|---|
  | learn-taste-wide | 7, 7, 8 | 7 | labeled 3/3 | $0.36 |
  | bare-wide | 5, 6, 4 | 5 | labeled 3/3 | $0.21 |

  learn-taste asked about scope in 2 of 3 runs, and bare in 1 of 3. bare-wide r17 wrote
  two helper scripts into the shared `/tmp`.
- **self-review's reach.** It scans every project by design. Given the ask about "this
  repo", all three runs read only this repo's previous session. Each saw the billing-portal
  session and said it had not opened it. Its all-history reach was never measured, because
  no run gave it the all-history ask.
- **Placement** (`--plugin-dir` on this worktree's plugin, with an unrelated control
  prompt):
  - `/hov-stack:learn-taste` resolves and runs.
  - The skill is absent from the model's skill listing, and a direct request to call it
    through the Skill tool was refused.
  - Unrelated prompts triggered no Skill call.
  - The `init` event's skills array still lists it beside the other invoke-only skills.
    That was logged as a papercut, not a defect.
- **Destination.**
  - learn-taste wrote to the wired `design/DESIGN.md` in 6 of 6 runs and kept its front
    matter valid.
  - claude-reflect and self-review wrote `CLAUDE.md` in 3 of 3 each.
  - claude-reflect left the contradicting `DESIGN.md` line in place, with only an override
    note.
- **Turn-2 side effects.**
  - learn-taste added a check script and a `package.json` script in 4 of 6 runs, as it had
    proposed.
  - learn-taste-wide r13 also left a new `pnpm-lock.yaml`.
  - context-lens leaves `.context-lens/` reports.
- **Not measured.**
  - Other models.
  - Real member transcripts.
  - Interactive sessions.
  - Sessions longer than the planted one.
  - claude-reflect's nested-call path (its detector was never called in r20–r22).
  - Whether `/hov-stack:learn-taste` resolves from the published marketplace build on a
    member's host (see section 4).

## 3. Verdicts

| component | target | verdict | placement | activation | evidence | state |
|---|---|---|---|---|---|---|
| learn-taste @ `64eb3de` | hov-stack skill pack | **ADAPT** (strict reading; the lenient reading gives SKIP) | `plugins/hov-stack/skills/learn-taste/`, unchanged | slash-only, `/hov-stack:learn-taste` | sections 2 and 4 | proposed in this PR, then released as 0.3.4 |
| claude-reflect @ `b6c4232` | none | not adopted. It ties learn-taste by the tie rule, but it ships four hooks, and enabling a plugin is the operator's call. | no installation | none | median 6, CLAUDE.md 3/3 | alternatives/GitHub, deep-vetted |
| nvie self-review @ `2458bd9` | none | not adopted. It ties learn-taste by the tie rule, and its all-history design is the closest match to the operator's idea, but that reach is unmeasured. | no installation | none | median 6 (5 by the K7 judge) | implementation/Web, deep-vetted |
| context-lens @ `18d8d21` | none | SKIP for this job | no installation | none | median 0 | alternatives/Web, deep-vetted |
| craftwork-design/retro @ `d39280b` | none | SKIP for this job | no installation | none | median 5 | alternatives/Web, pass 1, deep-vetted |
| ce-retro (compound-engineering 3.38.1) | already installed | no change | no change | as installed | median 3 | incumbent |
| davidparys/claude-mods rule-keeper @ `7aa4eb9` | none | typed mismatch, not run | no installation | none | `hooks/register.tsx:44` hooks `prompt.submit`, and `:60` renders a band `AbovePrompt`. Its README:17: "ignores slash commands, messages over 1,000 characters and the first message of a session". It cannot read a past transcript. | alternatives/Web, triaged |
| dopiotrek/dotclaude session-mining @ `2ede3c4` | none | hard mismatch, not run | no installation | none | `skills/README.md:68`: "mine session history into content ideas". The only tracked `mining/` files are outputs. | implementation/Web, triaged |
| google-labs-code/design.md | none | complement, not a contender | no installation | none | a DESIGN.md spec with lint and diff, and no session mining | pass 2, triaged |

## 4. The change

- **Rationale.**
  - The skill is a 2-point lead over the ask alone and over what members have installed.
  - It has the only K3 finds (2 of 6).
  - It writes to the file design-rails wires, where the two tied contenders write
    `CLAUDE.md`.
  - It is one MIT-licensed `SKILL.md` with no hooks, no scripts and no network use.
- **Files.**
  - `plugins/hov-stack/skills/learn-taste/{SKILL.md,LICENSE,UPSTREAM.md}`
  - a `plugins/hov-stack/NOTICE.md` row
  - `plugins/hov-stack/VERSION` and `.claude-plugin/plugin.json` set to 0.3.4
  - `plugins/hov-stack/docs/release-notes/v0.3.4.md`
- **Provenance.** Pin `64eb3de`, sha256 recorded in `UPSTREAM.md`. Local changes: none.
- **Update owner.** hov-stack maintainers. It is deliberately not auto-tracked: re-pull by
  hand and re-run this fixture.
- **Rollback.** Delete the skill folder and its NOTICE row, then bump the patch version.
- **Shipped state.**
  - Merged, released and runtime-verified are recorded separately, in the PR and in #683.
  - The placement probe ran against this worktree's plugin dir, not the published build.

## 5. Findings

- **Shared, about the artifact.**
  - It proposes before writing. In 6 of 6 runs it wrote nothing in turn 1.
  - It invents no rules, gives no made-up reasons, and never followed the injection.
  - It flagged the injection in 2 of 6 runs.
- **Target fit.**
  - A later `design-rails propose --out=design` overwrites `design/DESIGN.md` and drops
    learned rules: #685. That is a design-rails defect, not learn-taste's, and it affects
    any tool that writes there.
- **Fidelity of the contenders as run.**
  - **claude-reflect.** Its plugin commands are namespaced under `--plugin-dir`. A bare
    `/reflect` silently falls through as plain text: smoke r19 was voided for this. Its
    nested `claude -p` (`scripts/lib/semantic_detector.py`) passes no allowed-tools or
    permission mode, and interpolates message text into the prompt. That was read, not
    exercised.
  - **context-lens.** Its `plugin/scripts/run.sh` installs the unpinned HEAD unless a
    `context-lens` command is on PATH. The pinned clone was installed instead. Its nested
    call is well fenced (`src/context_lens/llm.py:96-107`: no tools, no settings, an empty
    MCP config, no session persistence). Its detector catches pushback phrasing only and
    needs a correction to repeat.
- **Prior notes.** I searched `docs/vets/` for learn-taste and for every contender here.
  None is in any earlier note.
  - The nearest are `2026-10-07-emilkowalski-skills-harness-vet.md` (the same repo at an
    earlier pin, before learn-taste existed) and
    `2026-10-07-correct-retro-family-harness-vet.md` (pstack `/correct` and the
    correction-loop family).
  - Nothing was reused from either, and neither changes applicability here.
- **Discovery hits dropped at triage.**
  - `ui-ux-pro-max-skill`: named once in an X result set the discovery agent judged
    marketing noise. Not opened.
  - Transcript viewers (implementation/GitHub): they read transcripts and write no rules.
  - DESIGN.md starter kits (implementation/GitHub): templates only.
  - Hallmark and the "missing layer: design taste" talk (experience/Web): pass 1 searched
    them and admitted no contender.
  - The X promotion posts: they are the candidate itself.

## 6. Audit dividend and re-audit triggers

**Audit dividend:**

1. #685, design-rails `propose` overwrites learned rules.
2. Wording of design-rails `posture.mjs:158`: it says "AGENTS.md names it" when only
   `CLAUDE.md` does. This was logged as a papercut.
3. claude-reflect's unfenced nested call (section 5). This is a note for anyone enabling
   that plugin.
4. This fixture's checker undercounts reach.
   - Its `reached_*` fields count direct reads and folder globs only.
   - A shell loop over the projects folder, or a skill's own script, reads without being
     counted. bare-wide r14 says it read the billing-portal session; its
     `reached_other_project` is false.
   - The replies, not those fields, are the reach evidence.
5. Nothing isolates the shared `/tmp`. `TMPDIR` points into the run dir, but bare-wide r17
   still wrote to `/tmp` directly.
6. Two papercuts:
   - plugin commands under `--plugin-dir` silently fall through when typed bare;
   - the `init` event lists invoke-only plugin skills.

**Do-not-retry unless:**

- upstream `learn-taste/SKILL.md` changes from sha256 `d624b8cd…d33e`;
- self-review is run on the all-history ask, the cell this vet left open;
- claude-reflect ships without hooks, or its nested call gains a tool fence;
- a member reports learn-taste rules being dropped or misplaced on real transcripts;
- the fixture gains a second model.
