# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/better-colors/`
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

- token-naming.md L95: emitted utility corrected to `text-text-secondary` (compiled v4.3.3: `text-secondary` generates no rule; upstream issue #21 item 1)
- color-usage.md L118: "15 points of perceived lightness" heuristic removed; it conflated OKLCH L with APCA Lc (sweep with apca-w3 0.1.9: ΔLc 14-23 for ΔL 15)
- contrast.md L34: 18.5px kept (it is W3C's own wording) with the exact 18.667px and the boundary caveat added
- color-formats.md modern-CSS list: `contrast-color()` added (MDN: Baseline newly available April 2026)
- contrast.md L9-22 APCA table: body Lc75/90, non-body min Lc60, large (≥36px) min Lc45 confirmed against readtech.org ARC Bronze; the remaining rows (non-body preferred Lc75, large preferred Lc60, UI Lc30, placeholder Lc30, discernibility Lc15) were matched by a reader against apca-w3's APCA_in_a_Nutshell.md but not independently reproduced by the verifier — treat as unverified against a primary source
