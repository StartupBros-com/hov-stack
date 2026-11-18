# Vet: the `ui-design` entry skill and `better-interface`

**Date:** 2026-11-17
**Ask (operator):** a pack skill as "an entry point for users to utilize all our design skills
instead of having to remember to use them", and "if we have all the other /better-* skills why
do we not have the interface one too?". Answered with a recommendation, then "go".
**Tracking:** hov-stack#683, branch `worktree-design-entry`.
**Fixture:** `harness/vet-fixtures/ui-design-2026-11/`. Its README is the pre-registration,
committed and pushed before any scored run (`f35fc24`, script fix `e33f5b9`). Its appended
section discloses the one revision, pushed before round 2 (`a5f3a1e`).

## Headline

- **Verdict: ships, model-invoked, after one disclosed revision.** Round 2 met every
  pre-registered rule. Round 1 failed one rule (Q1, a build regression on t4), which the revision
  fixed.
- **Reach.** With plain requests and no slash command, ui-design loaded in 15 of 16 UI runs
  (build t1 3/4, build t4 4/4, review 4/4, polish 4/4). It loaded in 0 of 8 non-UI runs, and 0 of
  4 on a one-word typo fix. Before this, every pack design skill was slash-only, and plain
  requests loaded none (0 of 16 in the build-design vet).
- **Gain on builds from an image.** Replies called the values read off the image estimates, or
  stated the assumed scale, in 8 of 8 runs against the pack's 1 of 8. This is the port the
  build-design vet's EXTRACT named. No false "matches" claim on a planted value in round 2.
- **Reviews.** "Review this page" reached better-interface through ui-design every time. Each
  review read better-interface, its report format and all six domain skills by path. It found a
  mean 10.9 of 11 planted defects against the pack's 10.25, with the same false accusations (1
  of 40 each) and no edits.
- **Cost.** Median $0.101 against $0.060 a run over builds and reviews. Reviews alone cost 3.8x
  ($0.182 against $0.048), because they read seven skill files.

## 1. What was tested

- **ui-design** (house-written, model-invoked): routes UI work to the pack's slash-only design
  skills by reading their `SKILL.md` files by path, the way `interface-review` §7 already does. It
  carries build-design's two estimate sentences plus a house sentence against false "matches".
  The model-invoked posture is the operator-approved exception (2026-11-17) to the pack's
  invoke-only route for vendored skills.
- **better-interface** (jakubkrehel/skills at `267330e`, slash-only, vendored): the
  whole-screen review that coordinates the six `better-*` domain skills. It was skipped in
  September because upstream it is model-invoked and "loads" domain skills that are slash-only
  here. Both reasons are fixed: it is slash-only, and it reads the domain skills by path.
- **interface-review** pointed whole-repository reviews at `/ux-audit`, which the pack does not
  ship. It now points at `/hov-stack:better-interface`.

Arms: `pack` (0.3.5 at `18c5be6`) and `pack+ui-design` (this branch), each loaded with
`--plugin-dir`, plain prompts, Sonnet, the build-design fixture's isolated runner (no shell, no
browser). Tasks:
- t1 and t4: the build-design vet's two builds from a design image;
- rv: the September planted-defect page as a prototype to review, with no edits;
- p1: "tidy the spacing and colours";
- c1: a typo fix;
- c2 and c3: two non-UI tasks.

Two blinded Sonnet judges graded every build and review reply.

## 2. Pilots

The description was tuned on 26 unscored pilot runs ($1.56), then frozen with the
pre-registration. The README lists every wording.
- **First description:** the review request did not load the skill.
- **Second:** reviews loaded, but the "tidy" request did not.
- **Frozen wording** names "polishing or tidying how a page looks, however small the change". With
  it, every UI pilot loaded and no negative did.

## 3. Round 1, the failed rule, and the revision

Round 1 (r01 to r40, $2.77) met every rule except Q1. The "values on the design system" item
(D1) on t4 failed in 3 of 4 ui-design runs against 0 of 4 for the pack:
- r31 used `h-5`, a step the project's reset theme does not define (r11 did the same with `h-6`
  on t1, where one fail sits inside the noise floor);
- r32 sized the local toggle with `h-[20px] w-[36px] p-[2px]` and listed them as "arbitrary values";
- r03 used an inline `marginInline: 2px`.

Every pack run built the toggle at 32x16 (`h-4 w-8`) and said it was smaller than the design.
The estimate lines made the model want to reproduce the measured value, and that beat the
project's own AGENTS.md note that the scales are reset.

The one revision, allowed by the pre-registration, changed only the mapping paragraph of
"Building from a design":
- use only the steps the theme defines;
- read the theme file for them;
- a local control's sizes and insets go to the nearest defined step;
- "the estimate belongs in the reply and the step in the code".

The description, the route table and the quoted build-design sentences stayed byte-identical.
The exact diff is in the fixture README.

Round 1's other numbers already passed:
- estimates 8 of 8 against 1 of 8;
- review 44 of 44 against 41;
- false accusations 1 against 1.

## 4. Round 2

28 new ui-design runs (r41 to r68, $2.06), scored against round 1's 12 pack runs and their
grades. Full table in `harness/vet-fixtures/ui-design-2026-11/results/round-2/tally.md`.

| rule | measured | result |
|---|---|---|
| L1 loads on t1, t4, rv, p1 (at least 3 of 4 each) | 3/4, 4/4, 4/4, 4/4 | met |
| L2 quiet on c2 and c3 (at most 1 of 8) | 0 of 8; c1 0 of 4 | met |
| Q1 no build regression (no cell 2+ fails worse) | worst cell D1 t4, 3/4 against 4/4 | met |
| Q2 estimates gain at least 3 | 8 against 1 of 8 (+7) | met |
| Q3 no false match | R5 0 fails; R3 0 against 0 | met |
| Q4 review no worse | TP 43.5 against 41 of 44; FA 1 against 1 of 40; no edits | met |
| Countermetrics: lines, cost (2x), stopped to ask | 41 vs 38 and 148 vs 126 lines; $0.101 vs $0.060; 0 vs 0 | met |

The judges agreed on every round-2 item. Round 1 had two splits, settled by hand with quotes:
- r36 R5: false, counted against ui-design;
- r29 D6a: full credit.

Agreement between two Sonnet judges is not independent evidence. So I re-read the deciding
cells from the replies themselves:
- Seven of the eight ui-design build replies state an assumed scale and call every size an
  estimate.
- The eighth, r60, is the one t1 run where the skill did not load. It passed R2 only on "about
  `gray-300`". Without it the gain is still +6.

## 5. Known limits

- **One D1 failure remains.** r62 sized the local toggle `h-6 w-10`, the same mechanism as round
  1, now 1 of 4 against 3 of 4.
- **Small samples.** n = 4 per cell, one model (Sonnet), one seed project, one review page. The
  build tasks are the build-design vet's own, so the estimate result is measured on the case it
  was designed for.
- **Partial blinding.** better-interface's report layout is recognisable to a judge. Round 2's new
  judges saw only ui-design packets, without being told.
- **Not measured:** a real Figma link, other frameworks, Codex (ui-design ships with no Codex
  manifest), and whether Anthropic's `frontend-design` skill competes when both are installed.
  The collision check found no overlap in descriptions.
- **Always-loaded cost.** The description costs context on every turn of every member session:
  56 words.
- **Checked after ship (2026-11-17).** The copy a member gets loads on the fixture's prompts.
  - Installed from the `hov` marketplace into a clean home directory, hov-stack 0.3.6 lists
    `hov-stack:ui-design`, and all 13 route targets resolve.
  - The fixture's own p1 and rv prompts loaded ui-design 3 of 3 each, on CLI 2.1.326 (the
    fixture's) and on 2.1.327, which came out after the fixture ran and adds a built-in `design`
    skill. c2 loaded it 0 of 2 on 2.1.327.
  - The rv runs read all eight sibling files by path from the installed copy.
  - On 2.1.327, two of the three p1 runs loaded ui-design but read no sibling file, where every
    2.1.326 p1 run read two. Whether that changes the polish is not measured.
- **A plain review ask can miss.** "Review this pricing page (index.html) for problems before we
  ship it", in a repo holding only that page, loaded ui-design in 0 of 4 runs, though the
  description names "reviewing a page … for problems". It has not been tried in a real frontend
  project, where the repo itself may change the routing.

## 6. Re-audit triggers

- Any edit to ui-design's description or "Building from a design" section. Both were measured;
  re-run this fixture before landing either.
- A new pack design skill: add a route-table row, and re-run L1/L2 if the description changes.
- A Claude Code release that adds or changes a built-in design skill (2.1.327 added `design`):
  re-run L1/L2, and check that a run which loads ui-design still reads the sibling its row names.
- An upstream jakubkrehel/skills re-pin of the `better-*` skills: better-interface must move with
  its domain skills.
