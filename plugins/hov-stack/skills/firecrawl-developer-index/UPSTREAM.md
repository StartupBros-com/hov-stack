# Upstream provenance

Adapted port of https://github.com/firecrawl/cli
`skills/firecrawl-developer-index/SKILL.md` at commit
a9a46fe23af001d726a05d8448d25a7188b42fdc (repository head on 2026-10-28; the
skill last changed in 84c82119a186bc50a27457f81e1d672ec8f28eaf), ISC license,
landed 2026-10-28 for dotfiles #2070.

Local changes:

- Cut the HTTP/MCP/vendor-CLI tool triplets to the single `firecrawl-cli
  developer` wrapper verb. The vendor CLI command lacks the filters; the
  wrapper exposes `--types`, `--repos`, `--sources`, `--passages`, the
  repository attributes, and `--skills-only`.
- Added keyed versus keyless cost semantics (2 credits per 10 results keyed;
  keyless has no account-floor check).
- Dropped the `firecrawl-build-search` see-also, the `references/` handoff to
  the official-documentation workflow, and the web-search tool bullets.
- Added a routing section (Context7, research index, GitHub-history fallback,
  open web) and the envelope location (`data.results[]`).
- Trimmed roughly 30% of upstream text, mostly tool re-narration.
