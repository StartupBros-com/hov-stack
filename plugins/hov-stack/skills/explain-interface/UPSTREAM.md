# Upstream provenance

Frozen snapshot of https://github.com/jakubkrehel/skills `skills/explain-interface/`
(commit 267330e1adfc66a718fb65fa6918c1f06d0a689e, 2026-08-29, MIT), cherry-picked 2026-09-01 per the
harness-vet evaluation (memory note jakubkrehel-skills-vet-2026-09). Deliberately
NOT auto-tracked: upstream is a single-author repo (100 commits in 7 weeks, no
tags) whose own version-bump rule is violated in 12 of its last 30 commits, so a
version number is not a freshness signal. Re-pull manually and re-diff on purpose.

Upstream ships this skill as user-invoked (disable-model-invocation: true) upstream too. Local posture:
`disable-model-invocation: true` in SKILL.md and
`policy.allow_implicit_invocation: false` in agents/openai.yaml (the Codex half
of the same switch) — invoke by name, zero always-on cost.

Local changes beyond the invocation switch are listed below; each is a deliberate
correction or a reconciliation with skills already installed on this harness.

- L11: sibling references rewritten to installed skills
- L37-43: the upstream MCP-server install command (chrome-devtools via `npx ...@latest`) removed; browser branch routed through wsl-cdp (eval/screenshot, mcp-add for traces)
- find-the-effect L5: wsl-cdp eval named first
- read-the-system L5: wsl-cdp eval named first
- no-browser L8: `--max-filesize 5000000` added
- no-browser: note on the size cap and on not spoofing a user agent
