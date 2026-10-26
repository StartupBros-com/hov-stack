# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/better-ui/`
(commit 267330e1adfc66a718fb65fa6918c1f06d0a689e, 2026-08-29, MIT), cherry-picked 2026-09-01 per the
harness-vet evaluation (memory note jakubkrehel-skills-vet-2026-09). Deliberately
NOT auto-tracked: upstream is a single-author repo (100 commits in 7 weeks, no
tags) whose own version-bump rule is violated in 12 of its last 30 commits, so a
version number is not a freshness signal. Re-pull manually and re-diff on purpose.

Upstream ships this skill as MODEL-INVOKED (no disable-model-invocation; auto-fires on matching prompts). Local posture:
`disable-model-invocation: true` in SKILL.md and
`policy.allow_implicit_invocation: false` in agents/openai.yaml (the Codex half
of the same switch) — invoke by name, zero always-on cost.

Local changes beyond the invocation switch are listed below; each is a deliberate
correction or a reconciliation with skills already installed on this harness.

- appended `## Reconciling with the rest of this harness` (0.96 vs installed 0.97; motion overlap; concentric-radius overlap)
- performance.md Tailwind note: v4-only mapping now says so; v3 maps to `transform` alone (compiled both; upstream issue #21 item 5)
- SKILL.md L69: Tailwind version caveat
- animations.md static-prop recipe: `not-disabled:` is v4-only, v3 silently emits nothing (compiled both); v3 equivalent named
- reconciliation §1: named the 0.97 source
