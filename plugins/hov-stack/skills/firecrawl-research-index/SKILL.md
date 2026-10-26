---
name: firecrawl-research-index
description: Find papers on a topic, follow citations, and verify what a paper actually reports across PubMed, bioRxiv, medRxiv, and arXiv via Firecrawl's hosted paper index. Use for literature-finding and paper-retrieval tasks, including clinical, biomedical, and life-science questions. For downloading PDFs, extracting sections, or paper+code bundles, use the `papers` skill instead.
---

# Firecrawl Research Index

Find the research papers that answer a query. The corpus's largest share is
biomedical and life-science literature (PubMed journal articles plus bioRxiv
and medRxiv preprints); arXiv covers CS, physics, and math. Coverage outside
those sources is thinner — a paper that exists only behind a publisher paywall
or in a niche venue may not be indexed; general web search is the fallback.

## Tools

Every tool is a vendor CLI subcommand (`firecrawl research ...`); call it as
`firecrawl-cli raw --json -- research <subcommand> ... --json` so the harness
budget and envelope apply (the Firecrawl MCP is retired). The vendor CLI works
without an API key — use it from subagents, cron, and scripts — but the keyless
tier can intermittently return 401 under load; set a key for reliability. The
CLI result-count flag is `--limit`, never `--k`: `--k` silently binds to
`-k/--api-key`, clobbering auth with your numeral and producing a misleading
401.

- `firecrawl research search-papers <query> --limit <n>` —
  semantic search over abstracts; the first move for almost any query.
- `firecrawl research related-papers <ids...> --intent <intent> --mode <similar|citers|references> --limit <n>` —
  semantic + structural expansion, ranked to your intent; reaches papers
  semantic search cannot. Caution: the response's `poolSize` merely echoes the
  `k` you asked for — it is not a graph-richness signal. Sanity-check returned
  titles against the seed's topic; when hits look unrelated the seed's
  neighborhood is thin, so stop re-seeding rather than burning calls.
- `firecrawl research inspect-paper <id>` —
  canonical metadata for one paper. Does not read the body.
- `firecrawl research read-paper <id> --question <q>` —
  in-body passages answering one specific question. Use it to settle a
  specific doubt (method actually used, score actually reported,
  affiliation), not on everything.

Ids work in `arxiv:`, `pmid:`, `pmcid:`, and `doi:` forms interchangeably.

Not this index: `firecrawl-cli search "<q>" --categories research --json` is a
website filter on ordinary web search. Its results are pages (each research-site
hit carries `category: "research"`; plain web results carry no `category`
field — key on that when merging). For paper-finding, use the tools above.

## Match the approach to the query

- **Single named paper** ("the Qwen3 report") → one `search_papers`, done.
  The only case that truly wants exactly one paper.
- **Paper by description / method** ("the paper that introduced X") → find the
  best match, then assume there's a family: expand with `related_papers` and
  keep the close neighbors rather than narrowing to the single literal match.
- **Enumeration / method-family** ("papers that do X", "alternatives to
  Adam") → the answer is a set: expand several strong anchors with
  `mode=similar`, re-seed from new strong hits. One search is never enough.
- **Exhibiting** ("papers that *use* property P") → their abstracts may not
  say so. Go from P's defining paper outward via `citers`/`references`, then
  `read_paper` to confirm a candidate actually uses P.
- **Superlative / leaderboard** ("best on benchmark X") → the ranking lives on
  the web, not in any abstract: find the leaderboard with `firecrawl-cli search` /
  `firecrawl-cli fetch`, read off the top entries, then `search_papers` each.
- **Org / author filtered** → topical match isn't enough; verify affiliation
  or authorship (metadata or `read_paper`) before keeping a paper.
- **Compare-against** ("what does paper X benchmark against") → the answer is
  inside X: `read_paper(X, ...)` or `related_papers([X], mode="references")`.

## Principles

- **When in doubt, include.** For topic / method / comparison questions,
  return the relevant family, most relevant first, not just the single best
  hit — stopping at one good result is the most common way to leave the
  reader with half an answer. Only drop the clearly off-topic.
- **Verify to exclude, not to gatekeep.** Use `read_paper` to rule a paper
  *out* when a hard constraint clearly fails; when a paper is plausibly
  relevant, keep it rather than demanding proof.

## Routing vs the `papers` skill

- **`papers`**: downloading PDFs, extracting sections, paper+code bundles,
  fully local/keyless preprint work. Its citation-graph enrichment is
  arXiv-only.
- **This skill**: published/PubMed literature, question-directed in-body
  reads, and citation-graph expansion across all four sources.
- **Neither** (web pages, code and issue search, plain discovery): the
  cross-provider table in `harness/cc-mcp-architecture.md` → "Web
  retrieval routing".
