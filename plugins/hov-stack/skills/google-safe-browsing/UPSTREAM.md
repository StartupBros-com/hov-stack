# Upstream provenance

Frozen snapshot of https://github.com/davidondrej/skills (commit
081d4d52cddb1f24e9358add21d47a45d82dd3fd, 2026-08-09, MIT license), skill
`skills/ops-and-setup/google-safe-browsing/SKILL.md`, adapted 2026-08-10.
Deliberately NOT auto-tracked: re-pull manually if wanted.

Local changes: replaced the generic "verify in / request review via Search
Console" steps with our `gsc` CLI (see CLAUDE.md "Data-source access:
prefer a CLI over an MCP server") and named the two domains our service
account already covers (startupbros.com, prbot.ai) so a flag on either skips
verification entirely. No frontmatter change from upstream — kept
model-invocable: the trigger is a browser interstitial or a domain-buying
moment the human hits without knowing a skill exists for it, same shape as
cass-rerank-local/ssh-local (narrow, tight-description, always-on), not the
big fan-out workflows this repo demotes to /-invocable. This operator runs
multiple public sites (prbot.ai, startupbros.com) and the harness had zero
prior coverage of this risk category when adopted (verified via grep
2026-08-10).

Additional local changes in SKILL.md: added an attribution comment, documented manual UI steps for new-property verification and Security Issues/review requests, and named the CLI scope limits.
