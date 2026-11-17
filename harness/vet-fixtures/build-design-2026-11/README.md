# build-design-2026-11: behavioral fixture for the build-design vet

Pre-registration for the behavioral test of `build-design` (vet 2 of 9 in hov-stack#683). Everything
down to "Reproduce" was written and committed before the scored runs. The results, and anything
added after the runs, go in the eval note, `docs/vets/2026-11-17-build-design-harness-vet.md`.

## What is under test

- **Candidate:** `skills/build-design` from `jakubkrehel/skills` at
  `6c2120103600407a1a9986afd834e73144ef8998` (MIT): build UI from a Figma file or a design image,
  mapped onto the project's existing tokens and components, then compare and report.
- **Incumbent:** the hov-stack pack as members install it (`plugins/hov-stack` at this branch's base,
  0.3.5, skills only: no hooks, no MCP). It already carries nine of the candidate's siblings from
  the same upstream (better-accessibility, better-colors, better-layout, better-typography, better-ui,
  better-writing, break, explain-interface, interface-review), which the candidate defers its domain
  rules to. So the question is the pack against the pack plus build-design, with bare as the floor.
- **Contender:** `design-to-code-fidelity` from `guillem-cotcha/design-to-code-skills` at
  `5548960f32791982a0d353903dc050c4a9368c30` (MIT): a stack-agnostic method skill (ask before
  building, read the design first, verify after each change; manual mode for screenshots).
- **Not in the arms** (the eval note carries their rows): Figma's own `figma-design-to-code` and
  `skobak/pix` need a Figma MCP, which this vet does not connect; `hxx2001/screenshot_to_code` runs
  Python scripts, a preview server and a browser capture, which no arm here has, and targets a new
  standalone page rather than an existing tokened project. That is "not evaluated under this
  fixture", not a rejection.

## Scope of the verdict

Image-to-code in an existing React + Tailwind v4 project with a reset token scale. **Not
evaluated:**

- the Figma path (no Figma MCP is connected, by rule: enabling one is a security-posture change for
  the operator);
- the candidate's visual comparison step (no arm can render; see "Isolation");
- the benefit of asking first. The second turn tells an arm that asked to go ahead with nothing more,
  so a question's payoff (a user who does have the Figma file or exact values) is never measured.
  Asking is scored only as a cost (t3) and through the final build and reply.

All three are re-vet triggers.

## Arms

| Arm | Loads | Prompt |
|---|---|---|
| bare | nothing | the task |
| pack | hov-stack plugin via `--plugin-dir` | the task |
| pack+build-design | the same plugin copy plus `skills/build-design` | `/hov-stack:build-design <task>` |
| pack+design-to-code-fidelity | the same plugin copy plus `skills/design-to-code-fidelity` | `/hov-stack:design-to-code-fidelity <task>` |

The skill arms are invoked explicitly, as a member would when they want the skill; whether the model
reaches for it unasked is the separate invocation probe below.

## Tasks (prompts in `make_runs.py`; key in `answer-key.md`)

- **t1** Team members card into the settings page (one card; off-scale gap, off-palette badge, no
  Badge, exact-token low-contrast email, a drawn pending row, out-of-scope bait).
- **t2** a Figma link with no Figma tool (the right answer builds nothing and asks).
- **t3** Delete workspace card (the clean control: every value maps; asking is a cost).
- **t4** a whole billing page into a new `src/pages/Billing.tsx` (missing Progress, Toggle and Badge,
  off-palette pills, off-scale bar and toggle, a red text button no variant expresses). Added after
  the pilot, before calibration.

A second turn, identical for every arm, is sent only when turn 1 left the working copy unchanged on a
build task: "I don't have anything beyond the image right now. Go ahead and build it with what the
project already has." Items score the final state and the final reply.

## Isolation (`run_arm.sh`)

`env -u` empties the environment except PATH and the model-route variables (by name); HOME, TMPDIR,
the XDG pair and `CLAUDE_CONFIG_DIR` sit inside the run dir. `--tools` and `--allowedTools` are both
`Read,Glob,Grep,Write,Edit,Skill,TodoWrite`: no shell, so no arm can install, start a dev server or
open a browser, and every arm has the same (zero) means of looking at its build. Model: sonnet, one
`claude -p` per turn, `--max-turns 60 --max-budget-usd 4`. Run dirs are built from `seed/` only, under
a neutral `/tmp` root; the key and the design sources never enter them. A run whose `tools.txt`
lists a path outside its run dir is void and re-run under a new number. The runner logs, per run,
the slash commands sent, any that did not resolve, every skill the Skill tool loaded, and any
permission refusal; those logs are diffed across arms before scoring.

## Pilot and calibration (not scored)

- **Pilot** (one t1 run per arm, skills as user skills, no pack): no shell calls, no permission
  refusals, both slash commands resolved, nothing outside the run dirs. All three built t1
  on-system with full component reuse, so t1's outcome items sat at ceiling; both skill arms stopped
  to ask first. That is why t4 was added and why the pack became the incumbent arm.
- **Calibration** (15 runs: bare x3 on t1-t4, one t4 run per pack arm; the pilot's second-turn
  wording):
  - Outcome items: bare passed every one in every run. It built t1, t3 and t4 on turn 1, and on t2
    built nothing and asked for the frame (3 of 3). On t1 it darkened the email to `gray-500` every
    time and said so (D5 via J5, 3 of 3). The pack and pack+build-design runs passed every outcome
    item on t4. pack+design-to-code-fidelity asked first, then drew the toggle with arbitrary pixel
    values (D1 fail).
  - Report items: R1 and R4 at ceiling for bare. **R2 at floor for bare (0 of 6) and the pack
    (0 of 1)**, passed by both skill runs. R3 8 of 9 for bare. The build-design run **failed what
    became R5**: its element table reads "Page padding, section gap | about 32px | `p-8`, `gap-8` |
    Matches", and the design's gap is 24px.
  - Judges: two Sonnet judges, reading the packets in opposite orders, agreed on every grade. One
    returned a null for an item not listed for its run; the tally refused, as designed, and the null
    was removed.
  - Routing: the pack arm's billing run loaded no skill at all. Its transcript's skill listing
    names 28 skills, 15 of them the pack's, and none a design skill: 33 of the pack's 47 skills
    are slash-only (`disable-model-invocation: true`), every design sibling of the candidate among
    them. On a plain "build this design" ask the pack offers the model nothing to reach for, so the
    pack arm is what a member gets today without typing a slash command. The candidate is
    model-invocable upstream, so the invocation probe below still measures something.
  - Logging control (one pack run, plain prompt naming the model-invocable `writing-for-agents`):
    `skills=hov-stack:writing-for-agents`, no refusals, status ok, and the `c1` scoring path ran.
    An empty `skills=` therefore means no skill was loaded, not a blind log.

### What calibration settles

Bare, and the pack in its one run, sit at ceiling on every outcome item. The candidate cannot beat
the pack by the adoption margin there unless the pack fails, so **ADOPT is out of reach on this
fixture** and the outcome comparison is a **harm test**: does adding the candidate break the build
the pack already makes? The ADOPT rule stays as written below; it is stated as unreachable here,
not loosened to fit.

The only items with room to move are R2 (values called estimates), a little of R3, and R5 in the
harm direction. A gain there supports at most **EXTRACT**: port the reporting lines that produced it
into the pack, not the skill.

### Changed after calibration, before any scored run

1. The second turn lost "and tell me anything you had to approximate". Only arms that ask first
   receive a second turn, so that wording handed them the report items and never reached an arm
   that builds on turn 1.
2. **R5** (no false match on a planted value) was added after reading the one build-design run that
   failed it. It is an item derived from one candidate reply, so it is disclosed here, and it runs in
   every arm.
3. The tally drops cells per item and task (not pooled across tasks), refuses to run on a missing,
   split or unknown grade, and applies the concentration and regression rules below
   (`selftest_tally.py`, planted checks).
4. The scorer reports whole arbitrary-value classes (`translate-x-[16px]`, not `x-[16px]`). The
   pass or fail is unchanged; `selftest_score.py` still passes.
5. The synthetic addresses moved from `acme.dev`, a registrable domain the repo's public-safety
   scan rejects, to the reserved `acme.example`, in the seed, the design sources and the re-rendered
   PNGs. Layout, colours and sizes are unchanged; no gate string is an address.
6. Run status, voids and gating, after an independent review of the first pre-registration
   (commit 7c8c618, pushed before any scored run): the runner classifies every turn (below), the
   scorer lists every run dir including crashed ones, the tally refuses unless each arm has exactly
   four counted runs per task, report items fail when the build gate fails, and the packet writer
   skips void and probe runs.

## Pre-registered

**Runs.** 4 arms x 4 tasks x 4 runs = 64, order shuffled with seed 20261117, into a fresh root. Bare
runs again at n=4 rather than reusing calibration. Pilot and calibration runs are not scored.

**Items** (`answer-key.md`). Outcome items, scored by `score_runs.py` (validated by
`selftest_score.py` on planted pass and fail builds): G_built (gate), D1 on-system values (compiled
against Tailwind 4.1.11), D2 design system untouched, D3 no unrelated edits, D4 component reuse, D5
email colour as drawn or named (t1; the naming half by the judges, J5), O2 no build from a guess
(t2). Gated items fail when the gate fails. Report items, graded by two judges per run on blinded
packets (`packets.py`, `judge-brief.md`): R1 gap reported, R2 values called estimates, R3 no
unverified whole-build match claim, R4 asks for the frame, R5 no false match on a planted value.
On t1, t3 and t4 the report items are gated too: a run that built nothing cannot pass R3 or R5 by
saying nothing. Each judge writes its JSON verbatim, quotes included; a split is settled by hand
with the quote in `adjudicated.json`, and the tally refuses to run while any grade is missing,
split or unknown. Skill names are redacted from packets; each skill's report layout is still
recognisable, so the judges are blind to labels, not to style.

**Void and re-run.** The runner classifies each turn from its result envelope. `ok`, and
`arm-stop` (the arm hit its own `--max-turns 60` or `--max-budget-usd 4`), are counted runs, scored
on their final state. `harness-fail` (no valid envelope, a runtime or API error, an empty result), a
run with no status file, and a run that touched a path outside its dir are void: listed, never
scored, and re-run under a new number until each arm has exactly four counted runs per task.

**Drop rule.** A cell (one item on one task) that every arm passed in every run, or failed in every
run, is dropped from the comparison and listed.

**Regression.** A cell where an arm fails at least two more of its four runs than the pack does. One
run is the noise floor at n=4.

**ADOPT** (all of):

1. pack+build-design beats the pack by at least max(3, ceil(20% of the pack's retained outcome
   item-runs)) outcome passes;
2. that gain is spread over three or more cells (a margin in one or two cells reads as EXTRACT, not
   ADOPT);
3. no outcome regression against the pack;
4. it does not trail pack+design-to-code-fidelity on outcome passes;
5. every countermetric holds.

**EXTRACT** (when ADOPT is not met; all of):

1. pack+build-design beats the pack on report items, net of its report losses, by at least
   max(3, ceil(20% of the pack's retained report item-runs)) passes;
2. no outcome regression against the pack.

The port is the candidate's lines tied to the gaining cells, written into an existing pack skill. It
lands only after its own live run on this fixture (pack plus port against the pack, four runs each
of t1 and t4) shows the same cells gaining, no outcome regression, and none of the candidate's
report regressions repeated. If the contender clears the same EXTRACT margin with no outcome
regression, it is named as an EXTRACT source too; if it clears ADOPT rule 1 and the candidate does
not, it is named for its own fit vet. Nothing is adopted from the contender on this run.

**Otherwise SKIP**, with "Do-not-retry unless" triggers, including the three "not evaluated" paths.

**Countermetrics** (pack+build-design against the pack; part of ADOPT, reported for EXTRACT), with
derivation:

- t3 asked-and-stopped: at most one run more than the pack. On a design where everything maps,
  stopping to ask is a pure cost; one run of slack is the noise floor at n=4.
- Median added lines per task (t1, t3, t4): at most 1.5x the pack's. A diff much wider than the
  pack's on the same design is scope the user did not ask for; 1.5x leaves room for report comments
  and data arrays, which varied by about a third between arms in calibration (101 to 154 lines on
  t4).
- Median cost per run: at most 2x the pack's. Calibration turns cost $0.05 to $0.18; one extra
  clarifying turn roughly doubles a run, so 2x is "at most one extra turn". Four runs per cell cannot
  resolve smaller ratios, so cost is reported and fails the rule only beyond 2x.

Also reported, never counted: normalized gain ((arm - bare) / (1 - bare)) per kind, the per-run
spread, turns, every judge split, and each arm's skill-load log.

**Invocation probe** (exploratory, outside both rules): pack+build-design with plain prompts, four
runs of t4 (it should reach for the skill) and four of an unrelated control, "Fix the typo in the
Notifications card title." (it should not), seed 20261118. Logged: whether the Skill tool loaded
build-design. The scored pack runs' skill-load logs answer the same question for the pack.

## Reproduce

```bash
# scratch: Tailwind 4.1.11 for the scorer's compile check (pnpm add exits non-zero on ignored
# build scripts; check that node_modules/@tailwindcss/cli exists instead of the exit code)
mkdir -p /tmp/tw && cd /tmp/tw && echo '{"private":true}' > package.json
pnpm add tailwindcss@4.1.11 @tailwindcss/cli@4.1.11
cd -   # back to this directory
python3 -I selftest_score.py --tailwind /tmp/tw --scratch "$(mktemp -d)"
python3 -I selftest_tally.py --scratch "$(mktemp -d)"
# skills at their pins
git clone https://github.com/jakubkrehel/skills /tmp/cand && git -C /tmp/cand checkout 6c2120103600407a1a9986afd834e73144ef8998
git clone https://github.com/guillem-cotcha/design-to-code-skills /tmp/cont && git -C /tmp/cont checkout 5548960f32791982a0d353903dc050c4a9368c30
python3 -I make_runs.py --out /tmp/acme-work/runs --key /tmp/acme-key.json --reps 4 \
  --src pack=../../../plugins/hov-stack --src build-design=/tmp/cand/skills/build-design \
  --src design-to-code-fidelity=/tmp/cont/design-to-code-fidelity
ls /tmp/acme-work/runs | xargs -P 4 -I{} bash run_arm.sh /tmp/acme-work/runs/{}
python3 -I score_runs.py /tmp/acme-work/runs --tailwind /tmp/tw --out /tmp/acme-work/scores.json
python3 -I packets.py /tmp/acme-work/runs /tmp/acme-work/packets --scores /tmp/acme-work/scores.json \
  --key /tmp/acme-key.json
# two judges grade the packets with judge-brief.md into /tmp/acme-work/grades/judge-{a,b}.json
python3 -I score_runs.py /tmp/acme-work/runs --tailwind /tmp/tw --key /tmp/acme-key.json \
  --grades /tmp/acme-work/grades --tally /tmp/acme-work/tally.md
```

`render_designs.sh` regenerates the PNGs from `designs/*.html` (headless Chrome with its own profile
and XDG pair).
