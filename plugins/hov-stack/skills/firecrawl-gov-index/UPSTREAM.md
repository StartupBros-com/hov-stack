# Upstream provenance

Adapted port. No upstream skill directory exists for the Government Index;
adapted from https://github.com/firecrawl/cli `skills/firecrawl/SKILL.md` and
`skills/firecrawl-search/SKILL.md` (their Government Index sections) at commit
a9a46fe23af001d726a05d8448d25a7188b42fdc (repository head on 2026-10-28; those
files last changed in d32f009caa0dce25e2dc6d6634ed73ad457010ce), ISC license,
plus https://docs.firecrawl.dev/features/gov and
https://docs.firecrawl.dev/api-reference/endpoint/gov-search, landed
2026-10-28 for dotfiles #2070.

Deliberately NOT installed via `npx firecrawl-cli setup` or `npx skills add`,
for the same reasons as `firecrawl-research-index/UPSTREAM.md`: third-party
installer fan-out into every agent tree and default-on telemetry.

Local changes:

- Every command retargeted to the `firecrawl-cli gov` wrapper verb (API-direct,
  free, keyless; the vendor `firecrawl gov` needs 1.26.x and hosts run 1.19.26).
- Filters named per the wrapper's flag spelling (`--court-type`, `--cites`,
  `--domain`, `--jurisdiction`, `--court`), with the court-type enum listed.
- Added the envelope location (`data.data.web[]`), the 24,576-character body
  bound and `--full`, and the exit-code behaviour for bad filters.
- Added a question-shape approach list and a verification section (issuer,
  jurisdiction, effective status, version; read the source before citing).
- Added two-way routing to web search and `fetch`; upstream's `scrape` becomes
  `firecrawl-cli fetch`.
