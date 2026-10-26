# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/break/`
(commit 267330e1adfc66a718fb65fa6918c1f06d0a689e, 2026-08-29, MIT), cherry-picked 2026-09-01 per the
harness-vet evaluation (memory note jakubkrehel-skills-vet-2026-09). Deliberately
NOT auto-tracked: upstream is a single-author repo (100 commits in 7 weeks, no
tags) whose own version-bump rule is violated in 12 of its last 30 commits, so a
version number is not a freshness signal. Re-pull manually and re-diff on purpose.

Upstream ships this skill as user-invoked (disable-model-invocation: true) upstream too. Local posture:
`disable-model-invocation: true` in SKILL.md and
`policy.allow_implicit_invocation: false` in agents/openai.yaml (the Codex half
of the same switch) — invoke by name, zero always-on cost.

Local changes beyond the invocation switch are listed below; each is a deliberate
correction or a reconciliation with skills already installed on this harness.

- L11: sibling references rewritten to installed skills
- L13: `variant` reference removed
- scenarios.md L60-L87: two axes added, Time and Images and media, ported (paraphrased, not pasted) from emilkowalski/skills `skills/break-ui/CATALOG.md` L88-L111 at e8a175de22ae1e49370fc144c1f3bb9aeedf988d (harness-vet 2026-10-07, docs/vets/2026-10-07-emilkowalski-skills-harness-vet.md). Value unverified: on that vet's fixture the bare arm found the time and media defects in both runs without these axes, so the only measurement run shows no detection gain; the deciding measurement is a fixture where a time or media defect goes unfound without them.
