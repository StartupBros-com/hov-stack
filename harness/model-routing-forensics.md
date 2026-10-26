# Model-routing forensics (probe history)

Demoted from `~/.claude/CLAUDE.md` → Model Routing by the 2026-08-11 rent-check
(directives stayed in CLAUDE.md; this file holds the provenance — read it when a
pin behaves unexpectedly or before changing `CLAUDE_CODE_SUBAGENT_MODEL`).

Standing rule, cut to one clause in CLAUDE.md on 2026-10-18:
`CLAUDE_CODE_SUBAGENT_MODEL=sonnet` is a floor, not proof of the served model.
Read the statusline's `via` model or other runtime provenance before saying which
model ran. Workflow stage tiers moved to `plugins/hov-stack/skills/agent-swarm/SKILL.md`
→ "Cost routing" the same day.

- **2026-07-10** — `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` set in settings.json env.
  Same-day test: Task-tool `Agent` pins DO win over the env floor.
- **2026-07-23 probe** — unpinned Workflow `agent()` calls land on Sonnet too,
  so explicit `model:` pins are tier control and intent documentation, not the
  only leak guard.
- **2026-07-23 ccflare forensics** — the haiku-pin-ran-sonnet effect is
  CLIENT-side: Claude Code resolves Workflow `agent()` pins against
  `CLAUDE_CODE_SUBAGENT_MODEL` before any request is built (a haiku pin was not
  honored). ccflare performs no model rewriting on anthropic-native accounts —
  its modelMappings exist only on non-Anthropic accounts (codex/grok/<mac-host>).
- Standing consequence: when the tier matters, check the run's *reported* model;
  never assume one from config or prose.
