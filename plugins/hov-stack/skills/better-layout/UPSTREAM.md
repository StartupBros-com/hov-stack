# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/better-layout/`
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

- spacing-and-adaptivity.md L77: peeking-scroller flex-basis fixed — upstream `calc(100% - 48px - 24px)` double-subtracted the padding and produced an 84px peek against its own 16-32px target (MDN flex-basis: percentages resolve against the container's inner main size; upstream issue #21 item 3)
- spacing-and-adaptivity.md L117: `viewport-fit=cover` prerequisite for `env(safe-area-inset-*)` and the `100dvh`/`100svh` over `100vh` rule, ported from emilkowalski/skills `skills/mobile-native/SKILL.md` L88-L98 and L169-L187 at e8a175de22ae1e49370fc144c1f3bb9aeedf988d (harness-vet 2026-10-07, docs/vets/2026-10-07-emilkowalski-skills-harness-vet.md; WebKit "Designing Websites for iPhone X" and web.dev "The large, small, and dynamic viewport units" confirm the behaviour). Value unverified on a live task; the deciding measurement is a mobile layout task on the members app where the pane or inset defect goes unfound without these lines.
