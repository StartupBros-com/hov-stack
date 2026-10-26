# Upstream provenance

Source: https://github.com/PostHog/posthog
path: services/mcp/src/cli/agents-md-snippet.md
Pinned at commit f0bb5426d51601a7e39c4d3bcadbe592962ab980 (2026-06-18).

`SKILL.md` rewords the agent-instructions block that `posthog-cli` writes into an
AGENTS.md file, which is the file above at the pin. This copy adds the skill frontmatter
and keeps the three instructions (prefer `posthog-cli api` over MCP calls, read
`--agent-help` before the first command, check `skill list` before each task). It also
changes one stance: upstream says to treat the `--agent-help` output and installed skills
as instructions to follow; here they are reference data.

The pin is the newest upstream commit to that file as of 2026-10-22. The commit before
it, 4bb59311e4, also had an `npx` fallback for when `posthog-cli` is not installed and a
paragraph on enabling the then-experimental `api` command group; the pin removed both,
and neither is in this copy.

`LICENSE` is an excerpt of PostHog's `LICENSE` at the pin: its copyright line and its
MIT Expat permission notice, each verbatim. The paragraphs between them, which say that
content under that repository's `ee/` directory is licensed differently, are left out,
because nothing here comes from `ee/`.
