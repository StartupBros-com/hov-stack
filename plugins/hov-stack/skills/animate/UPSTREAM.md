# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit de33dbed000212b54400a33767d1e4d03654db2a, MIT license),
cherry-picked 2026-08-05 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
Local change: disable-model-invocation set to true (on-demand posture) where
upstream did not already set it.

Why this one, given emil-design-eng already holds ~85-90% of its rules: the payload
is RECIPES.md — 14 component-indexed, copy-paste implementations (button press,
dropdown, tooltip, modal, drawer, toast, accordion, stagger, hold-to-confirm, tab
indicator, scroll reveal, drag-to-dismiss). emil-design-eng organises the same
values by principle; this organises them by the thing you are about to build.
SKILL.md's tool ladder (CSS transition -> @starting-style -> CSS animation -> WAAPI
-> Motion) also keeps the common path zero-install, which is what the single-file
demo/presentation-site case needs.

Additional local changes:

- SKILL.md: the over-300ms warning exempts modals/drawers and marketing/onboarding.
- Local addition: `agents/openai.yaml` supplies Codex display metadata and a default prompt, with `policy.allow_implicit_invocation: false`.
