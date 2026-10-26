# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit de33dbed000212b54400a33767d1e4d03654db2a, MIT license),
cherry-picked 2026-08-05 per the harness-addition evaluation. Deliberately NOT
auto-tracked: upstream churns opinions fast; re-pull manually if wanted.
Upstream already sets disable-model-invocation: true. Local changes: the frontmatter
description drops upstream's closing sentence, "Default to flagging; approval is
earned." (the same phrase opens agents/openai.yaml's default_prompt), and
agents/openai.yaml is local: the Codex half of the invocation switch.

One of the three DETECTORS in this batch, and the one that closes a standing hole
rather than a one-off task. ce-code-review's reviewer roster (correctness, testing,
maintainability, agent-native, security, performance, api-contract, data-migration,
reliability, adversarial, previous-comments, julik-frontend-races, swift-ios) contains
NO motion or design-feel lens. The closest, julik-frontend-races-reviewer, is about
async UI race conditions, not whether motion feels right.

STANDARDS.md duplicates emil-design-eng's rule catalogue almost verbatim; that is fine
and expected — both are invoke-only, so they never load together. The net-new content
is the review PROCEDURE: ten non-negotiable standards, the escalation trigger list, the
nine-step remedial preference hierarchy (delete > reduce > fix easing > fix origin >
interruptibility > GPU > asymmetric timing > polish > a11y), and an explicit
Block/Approve gate. Off the default merge path since 2026-10-17: CLAUDE.md's
Merge-and-end rule runs no review tier except the gated /pro-gate, so this skill
runs only when the operator names it.
