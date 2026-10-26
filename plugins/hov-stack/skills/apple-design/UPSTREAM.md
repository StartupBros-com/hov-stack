# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit de33dbed000212b54400a33767d1e4d03654db2a, MIT license),
cherry-picked 2026-08-05 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
Local change: disable-model-invocation set to true (on-demand posture) where
upstream did not already set it.

Second local change: a "Reconciling with the rest of this harness" section appended,
because two conflicts were found during evaluation and an unarbitrated third opinion
is worse than no skill:

  1. kill-ai-slop lists glassmorphism, oversized shadows and heavy blur as slop tells
     to REMOVE; this skill's Materials & Depth section teaches translucency as a
     hierarchy tool. Both are right in their own scope. The appended section states
     the arbitration rule rather than leaving the model to guess.
  2. emil-design-eng prefers CSS transitions over keyframes for interruptible UI;
     this skill says avoid CSS transitions entirely for gesture-driven motion. These
     reconcile as a hierarchy (springs > transitions > keyframes) scoped by whether a
     pointer is dragging. Recorded explicitly.

This is the only skill of the six carrying genuinely new domain content rather than a
re-framing of emil-design-eng: Apple's real momentum-projection function, the
rubber-band resistance formula, velocity-handoff normalisation, the per-interaction
damping/response table, plus Materials & Depth and Typography — two dimensions with
zero coverage anywhere else in the harness.

Additional local changes:

- SKILL.md: removed "restraint" from the description, reworded the input-responsiveness and translucent-layer rules, and split the spring table into momentum-driven rotation/sheets and non-momentum sheets (`1.0` damping).
- Local addition: `agents/openai.yaml` supplies Codex display metadata and a default prompt, with `policy.allow_implicit_invocation: false`.
