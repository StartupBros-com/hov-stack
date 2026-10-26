---
title: "Neutralise the skill name when a routing test is meant to guard the description"
date: "2026-09-20"
category: best-practices
module: skill-routing-evals
problem_type: best_practice
component: testing_framework
severity: medium
resolution_type: test_fix
applies_when:
  - "A routing eval (a `tool_used: Skill` case in `claude plugin eval`, or skill-tuner's routing-parity battery) is used to decide whether a description edit or prune is safe to land"
  - "The skill's name or id already says what the test prompts are about (deploy-helper, skill-tuner, memory-dream), and the listing or the plugin shows that name beside the description"
  - "A parity verdict on a pruned description is about to be cited as evidence that the description still routes"
symptoms:
  - "A skill whose description was replaced with `Internal notes.` still fires 3 of 3 runs on a natural-phrasing prompt that never names it"
  - "The same broken description fires 0 of 3 once the skill's name is changed to a neutral token, and the original description fires 3 of 3 under that neutral name"
  - "A routing-parity battery reports parity for a heavy prune and the reader cannot tell whether the description or the visible id carried the answer"
tags: [skill-routing, plugin-eval, routing-parity, skill-description, name-masking, eval-design]
related_components:
  - skill-tuner-routing-parity
  - claude-plugin-eval
---

# Neutralise the skill name when a routing test is meant to guard the description

## Context

The plugin-eval vet on 2026-09-20 planted a defect to see whether a routing suite could catch it: skill-tuner's description was replaced with `Internal notes.` and the suite's routing case ("help me rewrite my deploy-helper SKILL.md description", which never names the skill) was run three times per cell with the plugin loaded. The destroyed description still fired 3 of 3. Renaming the skill to `zz-notes` with the same destroyed description gave 0 of 3; restoring the original description under the neutral name gave 3 of 3. The name alone was carrying the route. skill-tuner's own routing-parity battery had the same blind spot by construction, because its listing line is `- {id}: {description}`, so every parity verdict it had ever produced for a description prune was potentially name-carried.

## Guidance

When the thing under test is the description, take the name out of the measurement:

- In `claude plugin eval`, run the routing case on a copy of the plugin whose skill `name` is a neutral token (the vet used `zz-notes`), or write prompts that avoid the name's vocabulary entirely, and keep an unrelated-request control case with `min: 0, max: 0, arm: both` so a skill that fires on everything is caught too. A `tool_used: Skill` grader is a with-arm-only indicator: it reports whether the skill fired, not whether the description caused it.
- In skill-tuner's routing-parity battery, set `neutral_ids: true` in the config (shipped in v0.9.0). Every skill id becomes `skill-<n>` in the listing, the expected answers and the scoring; the alias map is recorded in the run's manifest so a human can read the receipt. The contract is blinding, not anonymity: the router never sees a real id, while the persisted report keeps the real case ids on purpose.
- When citing a parity result for a description prune, say whether the id was visible. A result measured with the id showing supports the weaker claim "name plus description routes", not "description routes".

## Why This Matters

A routing test is a gate on landing description edits; the whole point of pruning synonym-stacked descriptions is to cut always-loaded context without losing recall. If the name carries the route, the gate passes any prune, including one that deletes the description outright, and the recall loss the gate exists to catch is invisible until a skill with a less descriptive name is pruned the same way. The measured effect was total on this plugin (3 of 3 to 0 of 3 on the name alone), which is why the harness's doctrine now carries the caveat in place rather than as a footnote.

## When to Apply

- Before landing any description prune whose evidence is a routing battery or a plugin-eval routing case.
- When writing a plugin's own eval suite (the evals directory `claude plugin eval` reads): name the neutral-copy or name-free-prompt choice in the case file so the next author does not reintroduce the leak.
- Not needed when the test is meant to guard the whole trigger surface, name included; then the visible id is the point, and the report should say so.

## Examples

Measured on skill-tuner with Claude Code 2.1.278, three runs per cell, with-arm only:

| skill name | description | fired |
|---|---|---|
| skill-tuner | original | 3/3 |
| skill-tuner | `Internal notes.` | 3/3 |
| zz-notes | `Internal notes.` | 0/3 |
| zz-notes | original | 3/3 |

Re-running skill-tuner's receipts battery with `neutral_ids: true` gave original 26/26, pruned 23/26, verdict refuse, with the same failing skill as the id-visible run (24/26 vs 23/26): hiding the ids neither rescued the prune nor hurt the originals. The earlier 30/30 figure in the doctrine came from a different battery that predates the option and is cited with that caveat. Full evidence: `docs/vets/2026-09-20-claude-plugin-eval-harness-vet.md`.

## Related

- `docs/vets/2026-09-20-claude-plugin-eval-harness-vet.md` (the planted-defect runs and their cost)
- skill-tuner's `routing_parity.py` (the `neutral_ids` aliasing block, tested since v0.9.1) and its README's routing caveat
- Memory: `skill-name-masks-description-in-routing-tests` (auto memory [claude])
