# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/interface-review/`
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

- L11: severity/cap/verdict now point at the folded-in section instead of `better-interface`
- L45: whole-repository audits route to /ux-audit or /design-rails
- L79: cap/verdict applied inline
- §7: hand-off to `better-interface` replaced by direct routing to the installed invoke-only domain skills
- Before-you-finish row: defer target updated
- L154: severity/cap source updated
- appended `## Severity, cap and verdict`: upstream better-interface ranking, fix-order, consolidation, cap and verdict rules, with heading numbers and the internal cap cross-reference removed; added provenance and change-review applicability notes
- scope-resolution L27: citation rule no longer attributed to `better-interface`
- scope-resolution L45: `gh pr status` mechanism corrected (verified live: `currentBranch` is not a --json field)
- scope-resolution L49: repository audit routes to /ux-audit or /design-rails
- scope-resolution L72: pathspec mechanism corrected (verified live in a scratch repo, git 2.43; upstream issue #21 item 4)
