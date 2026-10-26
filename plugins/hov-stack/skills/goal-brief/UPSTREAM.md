# Upstream provenance

Template adapted from https://github.com/davidondrej/skills (commit
081d4d52cddb1f24e9358add21d47a45d82dd3fd, 2026-08-09, MIT license), skill
`skills/agent-orchestration/goal-loop/SKILL.md`, adapted 2026-08-10.

ONLY the goal-contract template, writing rules (anti-reward-hacking,
anti-scope-creep, 4000-char limit, literal paths), and the two worked
examples were taken. Every product/feature claim in the source about
`/goal` — lifecycle states (pursuing/paused/unmet/budget-limited),
`/goal pause`/`resume` subcommands, server-side persistence, subscription-auth
requirement, TUI-only, `create_goal` tool, "Ralph loop" branding — was
verified FABRICATED against code.claude.com/docs/en/goal.md (2026-08-10,
Claude Code 2.1.224) and discarded. The real `/goal` is a session-scoped
prompt-based Stop hook with states active/achieved/cleared.

Local changes beyond the cut: restored the source's mandatory **Document:**
contract field, grounded the Before-drafting steps in real-file checks, and
added the memory-note cross-reference.

Additional local changes in SKILL.md: renamed `goal-loop` to `goal-brief`, replaced the description with contract-drafting scope, added `disable-model-invocation: true`, an `argument-hint`, and `allowed-tools: Read, Grep, Bash`; added attribution and contract-only output instructions, removed the remaining operational/meta-prompting advice, and revised both examples with documentation and anti-scope-creep/anti-reward-hacking clauses and ASCII comparisons.
