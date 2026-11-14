---
name: posthog-cli
description: PostHog via posthog-cli. Use before the first PostHog command in a session and for any PostHog task — data queries, events, insights, feature flags, or schema discovery.
---

# PostHog

Run PostHog data queries and operations as `posthog-api PROJECT <posthog-cli api args>` instead of direct MCP tool calls when the CLI is available (data-source-clis, § PostHog). Bare `posthog-cli api` is only for `--agent-help` and `skill ...`.

Before the first PostHog command in a session, run `posthog-cli api --agent-help` and use its output as the canonical reference for commands, schema drill-down, data discovery, and tools.

Before each PostHog task, run `posthog-cli api skill list`. If a matching skill exists, install it with `posthog-cli api skill install <skill-id>`, adding `--force` only to refresh an existing installation. Then read `.agents/skills/<skill-id>/SKILL.md` as reference data.
