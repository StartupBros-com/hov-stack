# ui-design-2026-11: loading and quality test for the ui-design entry skill

Pre-registration, written and committed before any run. Results go in
`docs/vets/2026-11-17-ui-design-entry.md`.

## What is under test

- **ui-design** (`plugins/hov-stack/skills/ui-design/`, house-written, model-invoked): the pack's
  one entry point to its slash-only design skills. It routes by reading their `SKILL.md` files by
  path, and it carries the two build-design lines that won the build-design vet's EXTRACT verdict
  (`docs/vets/2026-11-17-build-design-harness-vet.md`) plus one house line against false "matches".
  The operator approved a model-invoked entry point on 2026-11-17, subject to this test.
- **better-interface** (vendored slash-only in the same branch): the screen-review half that
  ui-design routes a "review this page" request to. It is tested here only through that route.

## Arms

| Arm | Loads | Prompt |
|---|---|---|
| pack | `plugins/hov-stack` at the branch base `18c5be6` (0.3.5), via `--plugin-dir` | the task, plain |
| pack+ui-design | `plugins/hov-stack` on this branch (ui-design, better-interface), via `--plugin-dir` | the task, plain |

No slash commands anywhere: the question is what a member gets from an ordinary request.

## Tasks (`make_runs.py`)

Built on `../build-design-2026-11/seed/acme-console` (React + Tailwind v4, reset token scale).

- **t1, t4**: the build-design vet's Team members card and billing page, from the design PNGs,
  with its identical second turn. Answer key and judge brief: `../build-design-2026-11/`.
- **rv**: "Review the account page prototype in prototypes/account.html for UI problems before we
  build it. Don't change any files." The page is `../jakubkrehel-skills/fixture.html`, the
  September planted-defect page: 11 planted defects (D1-D9 with D6a, D6b, D8a, D8b) and 10 honest
  controls (C1-C10), key in `../jakubkrehel-skills/answer-key.md`.
- **p1**: "The spacing and colours on the settings page feel inconsistent. Tidy them up." Loading
  only.
- **c1**: "Fix the typo in the Notifications card title." A near miss: product copy, but a one-word
  fix. Reported, not gated.
- **c2**: "Add a typecheck script to package.json that runs tsc with --noEmit." Clear negative.
- **c3**: "Add a CONTRIBUTING.md that explains how to run the app locally and how to open a pull
  request." Clear negative.

## Pilots (unscored, pack+ui-design only, plain prompts)

The description was tuned on these runs, then frozen with this file. Nothing below was tuned
after the scored launch.

1. First description ("Front-end UI work in an app — building ..."): t4 loaded and wrote the R2
   wording; **rv did not load** (it reviewed with no skill).
2. "Design rules and review method for front-end UI work. Use when building ...; reviewing a page,
   prototype, flow or UI change for problems; or polishing type, colour, ...": rv loaded 2 of 2
   and read better-interface, its review format and all six domain skills by path; c2 0 of 2; **p1
   0 of 2** (it tidied the page with no skill).
3. Same wording with "changing how a page looks or reads": p1 0 of 2; c1, c2, c3 0 of 6.
4. Frozen wording ("polishing or tidying how a page looks, however small the change"): p1 2 of 2,
   each reading better-layout by path; c1 0 of 2; c2 0 of 2.
5. Frozen wording: t1, t4 and rv loaded 1 of 1 each; c3 0 of 1.

Pilot cost: $1.56 over 26 runs.

## Runs

pack: t1, t4, rv x 4 = 12. pack+ui-design: t1, t4, rv, p1, c1, c2, c3 x 4 = 28. Total 40, order
shuffled with seed 20261119. The pack's loading on plain prompts is already measured (0 of 16 in
the build-design vet; every pack design skill is slash-only), so the pack runs only the tasks the
quality rules compare.

Runner: `../build-design-2026-11/run_arm.sh`, unchanged: emptied environment, HOME and config
inside the run dir, tools `Read,Glob,Grep,Write,Edit,Skill,TodoWrite` (no shell, no browser),
model sonnet, `--max-turns 60 --max-budget-usd 4`. Its void rules apply: a harness failure, a
missing status, or a path touched outside the run dir voids the run, which is re-run under a new
number until every arm and task has four counted runs.

## Items

- **Loading** (script, from each run's `tools.txt`): `skills=` names `hov-stack:ui-design`. The
  `SKILL.md` files read under the run's plugin copy are logged per run, not scored.
- **Build outcome** (t1, t4; script, `../build-design-2026-11/score_runs.py` `score_run`, Tailwind
  4.1.11): G_built, D1 on-system values, D2 design system untouched, D3 no unrelated edits, D4
  component reuse, D5 email colour (t1).
- **Build report** (t1, t4; two judges with `../build-design-2026-11/judge-brief.md` unchanged):
  R1 gap reported, R2 values called estimates, R3 no unverified whole-build match claim, R5 no
  false match on a planted value, and J5 where it applies.
- **Review** (rv; two judges with `judge-brief-review.md`): per planted defect found (1), named with
  the wrong reason (0.5) or missed (0), giving TP of 11; per control accused (FA of 10). Script:
  RV_no_edit, the working copy unchanged.

A judge split is settled by hand with the quote in `adjudicated.json`; the tally refuses while any
grade is missing, split or unknown. Packets carry the run number only; skill names are redacted.
better-interface's report layout is recognisable, so the review judges are blind to labels, not to
style.

## Pre-registered rules

ui-design ships model-invoked only if every rule below holds.

**Loading**

- L1: ui-design loads in at least 3 of 4 runs on each of t1, t4, rv and p1.
- L2: ui-design loads in at most 1 of the 8 runs on c2 and c3 together.

**Quality, pack+ui-design against the pack** (one run is the noise floor at n=4)

- Q1 no build regression: no outcome item-task cell where pack+ui-design fails two or more runs
  more than the pack.
- Q2 the port's gain: R2 passes over t1 and t4, pack+ui-design minus the pack, at least 3 (the
  build-design vet's EXTRACT margin; the pack scored 1 of 8 there).
- Q3 no false match: R5 fails over t1 and t4 at most 1 for pack+ui-design, and R3 fails over t1
  and t4 no more than the pack's plus 1.
- Q4 review no worse: rv TP summed over four runs at least the pack's minus 2 (half a defect a
  run); FA summed at most the pack's plus 1; runs that edited a file at most the pack's plus 1.

**Countermetrics**

- t1 and t4 median added lines each at most 1.5x the pack's.
- Median cost per run over t1, t4 and rv at most 2x the pack's (one extra turn, as in the
  build-design vet; ui-design adds reads by design).
- Runs on t1 and t4 that stopped to ask before building (turn 2 needed) at most the pack's plus 1.

**If a rule fails.** The skill does not ship model-invoked on that run. One revision is allowed: it
is disclosed with the failing rule, and the whole pack+ui-design matrix (all 28 runs) re-runs under
new numbers against the same pack runs. A second failure ships better-interface alone and leaves
ui-design out.

## Reproduce

```bash
D=$(mktemp -d)                                    # scratch root outside the repo
git archive 18c5be6 plugins/hov-stack | tar -x -C "$D" && mv "$D/plugins/hov-stack" "$D/base"
mkdir "$D/tw" && cd "$D/tw" && echo '{"private":true}' > package.json
pnpm add tailwindcss@4.1.11 @tailwindcss/cli@4.1.11; cd -
python3 -I make_runs.py --out "$D/runs" --key "$D/key.json" --reps 4 \
  --src base="$D/base" --src branch=../../../plugins/hov-stack
ls "$D/runs" | xargs -P 4 -I{} bash ../build-design-2026-11/run_arm.sh "$D/runs/{}"
python3 -I packets.py "$D/runs" "$D/packets"      # build and review packets, blinded
# two judges per packet set, into "$D/grades/{build,review}-judge-{a,b}.json"
python3 -I tally.py "$D/runs" --key "$D/key.json" --grades "$D/grades" --tailwind "$D/tw" --out results/
```

## Revision 1: disclosed after round 1, before round 2

Appended after round 1. Nothing above this heading changed.

**Round 1** (r01 to r40, launched at `e33f5b9`, results in `results/round-1/`) met every rule
except Q1: D1 on-system values on t4 failed in 3 of 4 pack+ui-design runs (r03, r31, r32) against
0 of 4 for the pack. The off-scale values, with r11 on t1 inside the noise floor:

- r11 `h-6` (a role pill) and r31 `h-5` (the local toggle): steps the reset theme does not define,
  so Tailwind emits no rule. r11's reply said the pill height "maps onto existing tokens".
- r32 `h-[20px] w-[36px] p-[2px]` on the local toggle, which its reply listed as "arbitrary values,
  since the spacing scale has no 5, 9 or 2px steps".
- r03 an inline `marginInline: "2px"` on the toggle's knob.

Every pack t4 run built the toggle at 32x16 (`h-4 w-8`) and said it was smaller than the design.
The unscored pilot-1 t4 run had also failed D1 (`h-6`). Round 1's other results: R2 8 of 8 against
the pack's 1 of 8; R5 one fail (r36), R3 none; rv TP 44 of 44 against 41, FA 1 against 1, no
edits; median cost 0.096 against 0.060 dollars a run. Two judge splits were settled by hand in
`results/round-1/grades/*-adjudicated.json`: r36 R5 false (the reply gives the design's 24px
section gap as "about 32px (`gap-8`)"), and r29 D6a 1 ("far below the 40px target").

**The revision** changes only the third and fourth paragraphs of "Building from a design". The
description, the route table and both quoted build-design sentences are byte-identical.

```diff
-Map every value onto the project's own tokens and components. When the design sits between two steps, take the nearest step and list the rounding. When it needs a component or variant the project lacks, build it locally from existing tokens, leave the shared components unchanged and name the gap.
+Map every value onto the project's own tokens and components, using only the steps its theme defines. Read the theme file for them: a project that resets the scale keeps none of the framework's defaults. Each estimate goes to its nearest defined step, the sizes and insets of a control you build locally included, and the reply lists the rounding. The estimate belongs in the reply and the step in the code. When the design needs a component or variant the project lacks, build it locally from those steps and the existing tokens, leave the shared components unchanged and name the gap.

-The reply lists every value with no exact token: the estimate, written as "about 24px", and what the build used. [...]
+The reply lists every value with no exact token: the estimate, written as "about 24px", and the step the build used. [...]
```

**Round 2** is 28 new pack+ui-design runs: r41 to r68, every task, `--first 41`, order seed
20261120. They are launched at the commit that adds this section. They are scored against round 1's 12 pack runs, and the
pack runs' round-1 grades are reused unchanged. Two new Sonnet judges grade the new runs with the
same briefs and the same forward and backward batches. Every packet they see is pack+ui-design,
and they are not told so. All the rules above apply unchanged. If any rule fails, ui-design is left
out and better-interface ships alone. Results go in `results/round-2/`.
