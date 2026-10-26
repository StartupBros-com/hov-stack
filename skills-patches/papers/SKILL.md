---
name: papers
description: Search preprints from arXiv, bioRxiv, and medRxiv without API keys. Supports search, lookup, extraction, citations, enrichment, and paper downloads that bundle PDFs plus linked GitHub code.
compatibility: Optimized for Claude Code. Install in project .claude/skills/ or personal
  ~/.claude/skills/. Pure local Python with no servers, no MCP, and no API keys.
allowed-tools: Read Write Edit Grep Glob Bash Python
metadata:
  short-description: Download preprints as paper/code bundles with auto-cloned GitHub repos
license: MIT
distribution: public
---

# Papers

## Purpose

Search, retrieve, download, extract, analyze, and synthesize preprint papers
from arXiv, bioRxiv, and medRxiv using pure local Python with no API keys.
Prefer bundled scripts over ad hoc scraping: they return stable JSON,
deduplicate cross-source results, and handle source-specific URL quirks.

## Workflow

1. Run `search` first unless the user already has an arXiv ID or DOI.
2. Read the JSON results and choose the highest-signal papers. Keep
   `source`, `source_id`, `pdf_url`, and `text_url`.
3. Read `retrieval_capabilities` before fetching. Use `blocked_reason` and
   `section_extraction_quality` instead of assuming every URL works.
4. Prefer `text_url` over `pdf_url` when it exists. XML extraction is cleaner.
5. Use `download` only when a local copy is needed in the workspace.
   Paper-aware downloads may also clone a linked public code repository into
   the bundle's `code/` directory when one is detected. Before running
   `download` on a record with a `repo_url`, tell the user that code will be
   cloned from the public host and confirm they want the code copy. Treat cloned
   code as untrusted source material: read it, do not execute it unless the user
   separately asks for that and the repo has been reviewed.
6. Use `extract` to produce full text or specific sections for review.
7. Use `analyze` to run an ambiguity audit on methodological gaps.
8. Use `synthesize` for creative multi-query search and literature synthesis.
9. Use `workflow` for the full search-to-synthesis pipeline in one call.
10. Explicitly note that preprints are not peer reviewed.

## Script Reference

### Core CLI (`paper_search.py`)

- `search` — Multi-source topic search. arXiv supports direct queries;
  bioRxiv/medRxiv search recent windows and rank locally.
- `lookup` — Resolve a known arXiv ID or DOI with Crossref fallback.
- `download` — Fetch any `pdf_url` or `text_url` to a task-local directory.
  When downloading by paper identifier or saved record, it creates a paper bundle
  directory with `paper/` and `code/` subdirectories, stores the paper asset in
  `paper/`, and clones the detected repository into `code/` when a GitHub-style
  repo URL is available. Confirm before cloning and never execute cloned code by
  default.
- `extract` — Extract full text or named sections from XML, TXT, or PDF.
  Section extraction is strongest on JATS XML, medium on plain text,
  best-effort on PDF.
- `analyze` — Run the ambiguity audit against either a raw sections map or an
  `extract --json` payload plus paper metadata.
- `synthesize` — Search and synthesize preprint literature. Use `--creative`
  when you want query expansion instead of standard search.
- `workflow` — Full pipeline: search → optional download → extract → optional
  audit → synthesis → citations. `--deep-analyze` works even without
  `--download`.
- `cite` — Generate BibTeX, APA, or RIS citations from a record or identifier.
- `enrich-related` — Fetch similar arXiv papers plus citation-graph links.
- `extract-tikz` — Extract TikZ figures from arXiv source archives.
- `doctor` — Check curl, pdftotext, cache writability, and provider reachability.

### Standalone Utilities

- `analysis.py`, `synthesis.py`, and `workflow.py` remain available as direct
  scripts, but `paper_search.py` is the authoritative CLI surface.

## Command Rules

- `search`: Use for topic, author, and category discovery. Add `--days` for
  tighter windows on broad biomedical queries. Use `--sort date` for recency.
- `lookup`: Use when the user has an arXiv ID or DOI. Falls back to Crossref.
- `download`: Keep downloads in a task-local directory, not the repo root.
  Prefer `download --source ... --id ...` or `download --record ...` for
  paper-aware bundles; use `download --url ...` only for raw asset fetches.
  If the selected record has `repo_url`, the paper-aware bundle may run
  `git clone --depth 1` for that public repo. Ask before the clone and use
  `--repo-discovery off` during lookup/search when the user wants paper-only
  retrieval.
- `extract`: Use `--write` for long output. Use `--sections` for named sections.
  Use `--json` for structured inline results.
- `analyze`: Pass extracted sections JSON or `extract --json` output plus paper
  metadata. Returns flags
  with citation anchors (section + paragraph index).
- `synthesize`: Pass a query for standard or creative search, or pass paper
  records for literature synthesis. Groups papers by theme.
- `workflow`: Pass `--creative` for query expansion, `--download` for PDFs,
  `--deep-analyze` for ambiguity audit, and `--output-dir` if you want
  downloaded assets persisted. Combines all steps.

## Output Contract

Every search result includes `retrieval_capabilities` with
`can_fetch_pdf`, `can_fetch_text`, `text_format`,
`section_extraction_quality`, and `blocked_reason`.

Errors emit JSON on stderr with `error_code`, `message`, `retryable`,
`source`, `http_status`, and `details`.

Audit flags include `category`, `status`, `anchor`, and `description`.
Workflow results may include `warnings` for degraded-but-nonfatal provider,
download, extraction, or citation paths.

## Source-Specific Guidance

- arXiv is strongest for CS, ML, math, physics, quantitative work.
- bioRxiv and medRxiv are strongest for life sciences and medicine.
- When a query spans ML plus biology/medicine, search all three.
- For broad biomedical queries, reduce `--days` before increasing `--limit`.
- medRxiv content downloads may return 403 in some environments.
- arXiv enforces polite access; the script backs off automatically.
- `enrich-related` (similar papers + citation-graph links) is arXiv-only: the seed must be an arXiv ID, so bioRxiv/medRxiv records cannot be enriched — for cross-source citation expansion use the `firecrawl-research-index` skill.

## Guardrails

- Never claim a preprint is peer-reviewed.
- Respect arXiv 3-second polite delay (enforced in paper_search_lib).
- Do not create files inside the skill directory; use task-local paths.
- Ask for clarification when the topic is missing or ambiguous.
- When a source is unavailable, degrade gracefully and report what succeeded.

## Adapter Notes

- Prefer bundled scripts over ad hoc shell commands for search, download, and extraction.
- Keep the authored source of truth in split project files, not in generated adapter bundles.
- All results are preprints. Never claim peer-review status.
