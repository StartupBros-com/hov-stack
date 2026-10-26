# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/better-accessibility/`
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

- forms.md L22: the placeholder example's email address is an `example.com` address here, so this repository's public-safety scan passes
- motion-and-zoom.md L64: WCAG 1.4.10 exception list corrected to the spec's own examples; "code blocks" removed (not a W3C exception)
- motion-and-zoom.md L39: rationale for 0.01ms made precise (0s transitions fire nothing; 0s animations do per current spec; none never does)
- hit-areas.md L91-L93: `touch-action: pan-x`/`pan-y` semantics, the `transparent` tap-highlight value with its `:active` pairing, and root `overscroll-behavior: none` against Android pull-to-refresh, ported from emilkowalski/skills `skills/mobile-native/SKILL.md` L78-L84, L146-L165 and L205-L221 at e8a175de22ae1e49370fc144c1f3bb9aeedf988d (harness-vet 2026-10-07, docs/vets/2026-10-07-emilkowalski-skills-harness-vet.md; MDN touch-action, -webkit-tap-highlight-color and overscroll-behavior confirm the stated halves; the iOS root-bounce half is unverified and the text says so). Value unverified on a live task; the deciding measurement is a mobile task on the members app where one of these goes unfound without the lines.
