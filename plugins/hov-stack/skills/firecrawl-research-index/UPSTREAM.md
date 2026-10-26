# Upstream provenance

Adapted port of https://github.com/firecrawl/skills
`skills/firecrawl-research-index/SKILL.md` (commit
16e5c07daff9a27f6cb6323de8ea8ad0ff3a3f8d, ISC license), landed 2026-08-21 by
the harness-vet run on https://docs.firecrawl.dev/features/research.

Deliberately NOT installed via the docs-recommended `npx skills add`: that is
vercel-labs/skills (a third-party CLI, not Firecrawl's), which by default
symlink-fans-out into every detected agent ecosystem on the machine and ships
default-on telemetry — the same blast-radius class as the 2026-07 firecrawl
installer incident (1,612 symlinks across 52 agent trees). Re-pull manually if
wanted.

Local changes (forced by a two-skeptic inward review; both landed on TRIM):

- Cut roughly 40% of upstream text that duplicated the live MCP tool schemas
  and the firecrawl MCP server instruction blurb: the corpus enumeration,
  per-tool re-narration, and 3 of upstream's 4 restatements of the
  `categories: ["research"]`-is-a-different-feature disambiguation.
- FIXED an upstream CLI flag bug: upstream documents `--k <n>` as the
  result-count flag; the real flag is `--limit`, and `--k` silently binds to
  `-k/--api-key`, clobbering auth with the numeral and yielding a misleading
  401 (verified against firecrawl CLI v1.19.26 `--help` plus live calls).
- Added a `related_papers` caution: the response `poolSize` echoes the
  requested `k` (it is not a graph-richness signal), and one live `citers`
  test returned off-topic results — thin neighborhoods happen.
- Added explicit two-way routing against the local `papers` skill (papers =
  download/extract/paper+code bundles, arXiv-only citation graph; this skill =
  PubMed/published literature, cross-source citation graph).
- Trimmed the ~150-word upstream frontmatter description to listing-budget
  size; consolidated upstream's six restatements of the include-the-family
  principle into one; removed the sentence containing the "sturctural" typo.

Kept: the query-shape → tool-strategy table and the verify-to-exclude
principle — upstream's genuinely novel content, absent from every schema and
blurb the harness already carries.

- SKILL.md: MCP calls replaced by vendor CLI subcommands through `firecrawl-cli raw --json -- research ... --json`; added keyless-tier 401 guidance, routed web search/fetch through `firecrawl-cli`, and added the general web-retrieval routing pointer.
