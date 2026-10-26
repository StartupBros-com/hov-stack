# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit f6f79ca1d8e9e2d82c8b90d7481b70ca66f4adfb, MIT license),
cherry-picked 2026-07-22 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
Local change: disable-model-invocation set to true (on-demand posture) where
upstream did not already set it.

Local changes beyond the invocation switch:

- SKILL.md L9-L15: upstream "Initial Response" block removed (the "respond only with: I'm ready to help you build interfaces that feel right, my knowledge comes from Emil Kowalski's …" gag plus the animations.dev course link). Vendored unstripped in round 1 and live until 2026-10-07. The suppression was live-confirmed that day on break-ui's copy of the same block shape at e8a175de22ae1e49370fc144c1f3bb9aeedf988d, not on this file: a bare `/break-ui` invocation in a scratch config returned only the branded line and nothing else. harness-vet 2026-10-07, docs/vets/2026-10-07-emilkowalski-skills-harness-vet.md.

- SKILL.md: the description adds invocation and paired-skill guidance; the duration rule allows modals/drawers up to 500ms; the ease-in and popover-origin fixes in the anti-pattern table now point to the body sections.
- Local addition: `agents/openai.yaml` supplies Codex display metadata and a default prompt, with `policy.allow_implicit_invocation: false`.
