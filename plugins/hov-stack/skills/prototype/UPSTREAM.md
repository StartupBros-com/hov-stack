# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit de33dbed000212b54400a33767d1e4d03654db2a, MIT license),
cherry-picked 2026-08-05 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
The invocation flag is unchanged: upstream already sets disable-model-invocation: true.

Adopted for the quick-demo / presentation-site case. PICKER.md's standalone branch is
genuinely zero-install complete — verbatim markup, CSS, an explicit behaviour contract
and a full vanilla-JS reference wiring (click + keyboard handlers, ?v=N URL persistence
via history.replaceState, double-rAF gate so load does not animate, reduced-motion
handled, ARIA correct). It runs from file:// with no package.json.

That matches the operator's preference for self-contained HTML/CSS/JS tools
and static documentation, without adding a slide framework.

Scope it honestly: this builds "flip between 3 variants of ONE piece", not "scaffold a
demo site". Nothing in this harness covers the latter — see the note in CLAUDE.md.

Local change 2026-09-01 (harness-vet of jakubkrehel/skills): Phase 4 gained the
real-page hosting option (`?variant=<name>` on the real route when the piece already
has a home), ported from that repo's `variant` skill (commit
267330e1adfc66a718fb65fa6918c1f06d0a689e, MIT). `variant` itself was SKIPPED as a
near-duplicate of this skill; this one sentence was its only substantive difference.

Additional local changes in SKILL.md: the instant-switching sentence spells out the frequency/motion rule; completion now requires every interaction to respond and one concrete benefit and cost per variant.
