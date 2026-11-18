---
title: "A vetted extract needs its own scored run, because honest wording can push estimates into the code"
date: 2026-11-17
category: best-practices
module: harness-vet-extract-ports
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A harness-vet EXTRACT verdict names sentences to port from a candidate skill into a pack skill"
  - "The ported wording asks the model to report a measurement, an estimate or its own uncertainty"
  - "The live run planned for a port scores only the behaviour the port was chosen for"
  - "A skill tells the model to build from a design image, where every value it reads is an estimate"
related_components:
  - "harness-vet"
  - "hov-stack ui-design skill"
  - "vet fixtures"
tags:
  - harness-vet
  - extract-port
  - skill-wording
  - outcome-regression
  - vet-fixture
  - design-tokens
  - estimates
---

# A vetted extract needs its own scored run, because honest wording can push estimates into the code

## Context

The harness-vet of Jakub Krehel's `build-design` skill (PR #710) returned EXTRACT
(`docs/vets/2026-11-17-build-design-harness-vet.md:22`). The pattern worth keeping was two sentences
that make an agent call the sizes it reads off a design image estimates. The pack had no
model-invoked design skill to carry them, so they went into a new one, `ui-design` (PR #730), where
they still read: "Sizes are ratios to the capture, so state the
scale you assumed and treat every measurement as an estimate"
(`plugins/hov-stack/skills/ui-design/SKILL.md:50`).

The working belief was that the EXTRACT *was* those two sentences. The vet had credited them with
build-design's whole gain, and the port's own target improved as expected. In round 1 of the pre-registered fixture
(`harness/vet-fixtures/ui-design-2026-11/`), builds called their values estimates 8 of 8 times
against 1 of 8 without the skill.

A different scored item regressed. On the billing-page task (t4), 3 of 4 ui-design builds put values
on the page that the project's theme does not define. Without the skill that happened 0 of 4 times
(`harness/vet-fixtures/ui-design-2026-11/results/round-1/tally.md:14`, rule Q1 "not met" at `:32`).
- r31 used `h-5` on a locally built toggle, a step the reset theme lacks, so Tailwind emits no
  rule for it. r11 did the same with `h-6` on t1, where one fail sits inside the noise floor.
- r32 wrote `h-[20px] w-[36px] p-[2px]` and called them "arbitrary values".
- r03 used an inline `marginInline: "2px"`.

Every t4 run without the skill built the toggle on the scale at 32x16 and said it was smaller than
the design (`harness/vet-fixtures/ui-design-2026-11/README.md:154`). build-design run whole had
slipped on that toggle in 1 of 4 scored runs of its own vet, a separate run of the same t4 task
(`docs/vets/2026-11-17-build-design-harness-vet.md:36-38`). Round 1's ui-design wording slipped in
3 of 4. That wording held the two sentences, the old mapping paragraph, a house sentence against
claiming the build "matches" and the route table, so no run isolated the two sentences. The vet note's reading is that
the estimate lines made the model want to reproduce the measured value, and that this beat the
project's own AGENTS.md note that the scales are reset (`docs/vets/2026-11-17-ui-design-entry.md:65-76`).

## Guidance

**Score every outcome cell the port could disturb, not only the behaviour it was chosen for.**
`plugins/harness-vet/skills/harness-vet/VERDICTS.md:21-24` already asks for a live-task result
before a behaviour-shaping port lands, or an explicit unverified-value marker in its place. Make that run an arm comparison against the target without
the port, with a pre-registered no-regression rule over the cells the target already passes. This
fixture's rule was "no outcome item-task cell where pack+ui-design fails two or more runs more
than the pack" (`harness/vet-fixtures/ui-design-2026-11/README.md:104-105`). The adversarial
wording review at `plugins/harness-vet/skills/harness-vet/SKILL.md:511-519` judges fidelity and utility of
the text, and this side effect showed only in the built output.

**Port a reporting rule together with where the reported value goes.** Asking for honest numbers
without saying where they go invites the model to carry them into the artifact. The fix that met
every rule in round 2 was one disclosed revision of the mapping paragraph
(`plugins/hov-stack/skills/ui-design/SKILL.md:54`), plus one word in the paragraph after it. It says:
- read the theme file;
- use only the steps it defines, the sizes and insets of a locally built control included;
- "The estimate belongs in the reply and the step in the code."

Its exact diff is at `harness/vet-fixtures/ui-design-2026-11/README.md:161-170`.

## Why This Matters

The regression showed only in the outcome score:
- the vet measured build-design whole, not the two sentences without the rest of it;
- a wording review judges the text, not what the model builds from it;
- the port's own target metric improved.

Shipping round 1's wording would have given members builds that look honest in the reply while
writing sizes into the code that the project's theme cannot render. That is the reverse of what
build-design's sentences were for.

After the revision, round 2 met every rule. On t4, 3 of 4 ui-design builds stayed on the theme
against 4 of 4 for the pack, inside the rule. Estimates held at 8 of 8 against 1 of 8
(`harness/vet-fixtures/ui-design-2026-11/results/round-2/tally.md:14`, `:32`, `:33`). One failure of the same kind remains: r62 sized the toggle `h-6 w-10`
(`docs/vets/2026-11-17-ui-design-entry.md:121-122`). The rule narrows the behaviour; it does not
remove it.

## When to Apply

- Porting an EXTRACT from any vetted skill, especially the remaining design skills queued in #683.
- Writing or editing a rule that asks the model to report a measurement, an estimate, a
  confidence level or a gap. Say in the same rule where the reported value lives and what goes in
  the artifact instead.
- Editing ui-design's "Building from a design" section. Removing or loosening the mapping paragraph
  re-opens the round-1 failure, which round 1's wording produced.

## Examples

Round 1's mapping paragraph, which regressed t4 when paired with the estimate sentences, opened:

> Map every value onto the project's own tokens and components. When the design sits between two
> steps, take the nearest step and list the rounding. […]

Round 2's, which met every rule, opens:

> Map every value onto the project's own tokens and components, using only the steps its theme
> defines. Read the theme file for them: a project that resets the scale keeps none of the
> framework's defaults. Each estimate goes to its nearest defined step, the sizes and insets of a
> control you build locally included, and the reply lists the rounding. The estimate belongs in the
> reply and the step in the code. […]

## Related

- `docs/solutions/best-practices/a-stub-proves-wiring-only-a-live-run-proves-a-cooperative-contract.md`:
  the same shape in another area, where a proxy check passed and only the real run showed the defect.
- `docs/solutions/best-practices/agent-bakeoff-eval-discrimination-failure.md`: why the arm without
  the port has to be scored on the same outcomes for the comparison to discriminate.
- `docs/vets/2026-11-17-ui-design-entry.md` and `docs/vets/2026-11-17-build-design-harness-vet.md`:
  the two vet notes.
- #683: the design-skill vet queue this applies to next.
