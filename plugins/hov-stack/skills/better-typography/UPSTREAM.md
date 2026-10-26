# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/better-typography/`
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

- spacing-and-sizing L121: stale `text-box` support claim corrected (Firefox 154 shipped it; MDN marks it Baseline 2026)
- SKILL.md L99: "color is the only part … that animates" corrected; thickness and offset are animatable by spec, support caveat kept
- SKILL.md L69, wrapping-and-punctuation.md L22, css-cheat-sheet.md L45: `overflow-wrap: anywhere` added beside `break-word` for flex and grid children that must shrink. Reconciles a value divergence surfaced by the harness-vet of emilkowalski/skills `skills/break-ui/SKILL.md` L99 and L104 at e8a175de22ae1e49370fc144c1f3bb9aeedf988d (2026-10-07, docs/vets/2026-10-07-emilkowalski-skills-harness-vet.md). MDN overflow-wrap: `anywhere` soft-wrap opportunities "are considered when calculating min-content intrinsic sizes", `break-word`'s "are NOT". Tailwind class `wrap-anywhere` per tailwindcss.com/docs/overflow-wrap. Additive: `break-word` stays the default advice. Value unverified on a live task: the vet fixture measured source-level defect detection, not an implementation that applied this rule; the deciding measurement is a flex or grid layout task where a shrinking child still overflows under `break-word` and the `anywhere` fix goes unproposed without this line.
