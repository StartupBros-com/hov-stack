# Upstream provenance

Body upstream: https://github.com/StartupBros-com/skill-tuner
`skills/skill-tuner/SKILL.md`, pinned at commit 297efb49ffa893967952cd989f321219cbb06a28
(repo head, 2026-09-20; the body itself last changed in 99e85a7, "plugin-eval-ingest
(#54)", MIT). This directory is the harness's personal edition of that doctrine, not a
stale copy: shared rule body below the locally adapted introduction, own frontmatter (`name: writing-for-agents`; the pruned
description is kept on purpose, so no routing change), plus SKILL-MECHANICS.md for
frontmatter mechanics and FALSIFIERS.md as the evidence ledger, and it is the copy
deployed to Codex via `codex-skills.txt`. The plugin skill `skill-tuner:skill-tuner`
fires on the same trigger; that overlap is deliberate (skillOverrides cannot demote
plugin skills, and this copy is the one Codex sees).

Re-pull by hand: diff `skills/skill-tuner/SKILL.md` at the new head against SKILL.md
here, port body changes below the intro, keep the frontmatter, the intro paragraph and
the SKILL-MECHANICS pointer as they are, then move the pin above.

Re-pinned 2026-09-22: ported the 2026-09-20 `neutral_ids` caveat on the routing-parity
rule, the only body change since doctrine v3 (2e8b117). Before this the pin still named
the original mattpocock snapshot, so vendored-drift-check reported MOVED against a
repository this body no longer tracks.

Kept MODEL-INVOKED on purpose (no disable-model-invocation): the trigger
(creating/editing skills, AGENTS.md, CLAUDE.md) fires ~1.5x/day in this repo's
recent history, and 15 of the 32 locally authored skills were already model-invoked
when this was written.

Known tension, left unpatched: skill-creator (first-party plugin) advises
"pushy" synonym-stacked descriptions; this skill advises one-trigger-per-branch
pruned descriptions. They fight over the same artifact (the always-loaded
description line). This harness sides with pruning (2026-07 demotion audit) —
now with a measured receipt: a 37% description cut routed 30/30 vs the
originals' 28/30 (skill-tuner routing-parity, 2026-08-06); the 2026-09-20 caveat
in the body records the neutral-id re-run that refused a later prune.

## History

Origin (2026-08-06): frozen snapshot of https://github.com/mattpocock/skills
`skills/productivity/writing-for-agents/` at 8b36d4fb2635b3c21998dcd8144439c9e5ba7302
(2026-08-05, MIT), cherry-picked per the writing-for-agents evaluation
(6-agent adversarial pass; see memory note ste100-and-wait-what-evaluation-2026-08
and its successor). Deliberately not auto-tracked: upstream was a ~7-week-old,
still-mutating theory (renamed from writing-great-skills 2026-07-23). This fork
REPLACED the stale skills.sh install of the pre-rename `writing-great-skills`
(removed from ~/.agents/skills + .skill-lock.json at deploy time). SKILL-MECHANICS.md
still derives from that snapshot.

Local change on the snapshot: one sentence appended to the no-op bullet in Pruning,
making the no-op test time-relative (model-default drift; grounded in the 2026-08-05
binary-dump finding that Claude Code's default tone rules got vaguer over
versions — a pruned no-op can silently become load-bearing again).

SWAPPED 2026-08-08 (R13 follow-through): the body became skill-tuner doctrine
v3, the first version to out-find the mattpocock text on its own gate — 42 vs
29 confirmed defects on 15 shared documents, 95% CI [+0.03, +1.70]
(https://github.com/StartupBros-com/skill-tuner/blob/main/reports/swapgate6-summary.md).
The incumbent it replaced (the 8b36d4f snapshot plus the time-relative amendment)
is preserved in git history and remains the banked gate baseline. Frontmatter
kept unchanged — no routing change. FALSIFIERS.md added alongside (evidence ledger).
SKILL-MECHANICS.md retained for frontmatter mechanics; the v3 body's
model-invoked/user-invoked bullet supersedes its invocation-choice section.

Local differences from the current pin:

- SKILL.md: renamed the skill and rewrote its description and introduction; added the SKILL-MECHANICS.md pointer and shortened the tune-loop pointer, dropping its non-slash-client explanation.
- FALSIFIERS.md: added a candidate workflow-summary falsifier; changed report references to external links, removed the rejected quantitative claim, supporting-but-not-graduating citations and Evidence index, and condensed the gate history, omitting the v3.1, replication and cross-family audit details.
- Local addition: LICENSE-mattpocock-skills carries the MIT license for the retained SKILL-MECHANICS.md material.
- Local addition: agents/openai.yaml supplies Codex display metadata.
- Not vendored: upstream scripts/ command-line runners and helpers, plus their scripts/tests/ suite and fixture data.
