# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/better-interface/`
(commit 267330e1adfc66a718fb65fa6918c1f06d0a689e, 2026-08-29, MIT), the same pin as the
six `better-*` domain skills it reads, vendored 2026-11-17 (hov-stack#683). Deliberately NOT
auto-tracked: re-pull manually and re-diff on purpose, together with the domain skills.

Upstream `SKILL.md` at the pin: sha256
`57412a685bd1a654f81def820099481b7df6ddf8f4bc06989a1b875b1d01c036`. `review-format.md` is
byte-identical to the pin (sha256 `99bf274b4a382d89fc281482c688127d1d82e3a5a5c84d2662ebfc9946dc8108`).
`LICENSE` is the upstream repo's.

**Why the September vet skipped it and why it is here now.** The 2026-09-01 vet skipped this
orchestrator for two reasons: upstream ships it model-invoked, so it would have out-routed the
review skills then installed on "review this UI", and its routing said "load" the domain skills,
which cannot be loaded here because they are invoke-only. Its severity ladder, triggers, fix
ladder, cap and verdict were folded into `interface-review` instead. That left the pack with
change review only: `interface-review` sent a whole-screen review to `/ux-audit`, which the pack
does not ship. This copy fills that gap with both September reasons fixed: it is invoke-only, and
it reads the domain skills by path the way `interface-review` already does.

**Why the September pin and not upstream head.** At `6c21201` (2026-11-16) every `better-*` skill
had been reworded upstream, and the pack's domain skills are frozen at `267330e` with local
corrections. The orchestrator is kept at the pin its domain skills come from. Head still says
"load every owning skill", so its routing would fail here the same way.

Local posture: `disable-model-invocation: true` in `SKILL.md` and
`policy.allow_implicit_invocation: false` in `agents/openai.yaml` (the Codex half of the same
switch; upstream's file carries only the `interface` block). Members run it as
`/hov-stack:better-interface`. The model reaches it only through `ui-design`, which reads this
file by path when a user asks for a review of a screen, flow or page.

Local changes beyond the invocation switch:

- §1 cap: "at most 15 findings" now exempts the escalation triggers, as in `interface-review`.
  As written, the cap and "never why a blocker went unreported" disagreed once more than 15
  triggers fired.
- §2: the hand-off names the slash command members type, `/hov-stack:interface-review`.
- §4: "Load and apply every available owner" now reads the domain skills by path
  (`../<name>/SKILL.md`) and the reference files each points to, because on this harness they are
  invoke-only and the Skill tool cannot load them. "loaded here" became "read here".
- §6: the trigger paragraph takes `interface-review`'s wording for the same cap fix.
