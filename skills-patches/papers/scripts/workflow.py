#!/usr/bin/env python3
"""Full pipeline workflow for preprint research.

Orchestrates: search (standard or creative) -> optional download + extraction
-> optional ambiguity audit -> synthesis -> citations -> return comprehensive
result dict.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

# Resolve paper_search_lib regardless of cwd.
_LIB_DIR = str(Path(__file__).resolve().parent / "paper_search_lib")
if _LIB_DIR not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from paper_search_lib.core import (
    CacheStore,
    HttpClient,
    PaperSearchError,
    PaperRecord,
    default_cache_dir,
    dedupe_records,
    parse_date,
    suggested_filename,
)
from paper_search_lib.bundle import download_paper_bundle
from paper_search_lib.providers import SearchArgs, build_provider_registry
from paper_search_lib.extract import extract_input
from paper_search_lib.citation import format_bibtex

# Import sibling modules.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from analysis import perform_ambiguity_audit
from synthesis import creative_search_with_warnings, synthesize_papers


def _warning_payload(stage: str, exc: Exception, **details: object) -> dict[str, object]:
    payload = {
        "stage": stage,
        "message": str(exc),
        "details": details,
    }
    if isinstance(exc, PaperSearchError):
        payload["error"] = exc.to_dict()
    # Provider details can retain exceptions, such as urllib's URLError.reason.
    return json.loads(json.dumps(payload, default=str))


def _search_standard(
    query: str,
    sources: list[str],
    max_results: int,
    days: int,
    http: HttpClient,
) -> tuple[list[dict], list[dict[str, object]]]:
    """Standard search using paper_search_lib providers."""
    providers = build_provider_registry(http)
    search_args = SearchArgs(
        query=query,
        author=None,
        categories=[],
        limit=max_results,
        sort="relevance",
        days=days,
    )
    all_records: list[PaperRecord] = []
    warnings: list[dict[str, object]] = []
    for source_name in sources:
        provider = providers.get(source_name)
        if provider is None:
            warnings.append(
                {
                    "stage": "search",
                    "message": f"unsupported source skipped: {source_name}",
                    "details": {"source": source_name},
                }
            )
            continue
        try:
            records = provider.search(search_args)
            all_records.extend(records)
        except Exception as exc:
            warnings.append(_warning_payload("search", exc, source=source_name))

    deduped = dedupe_records(all_records)
    deduped.sort(
        key=lambda r: (
            r.relevance_score,
            parse_date(r.published_date) or parse_date("1970-01-01"),
        ),
        reverse=True,
    )
    return [r.to_dict() for r in deduped[:max_results]], warnings


def _download_and_extract(
    papers: list[dict],
    http: HttpClient,
    output_dir: str | None = None,
    max_papers: int | None = None,
    persist_downloads: bool = False,
) -> tuple[list[str], dict[str, dict], list[dict[str, object]]]:
    """Download and/or extract papers.

    Returns (download_paths, extractions) where extractions maps
    source_id -> section dict.
    """
    work_path = None
    if persist_downloads:
        work_path = Path(output_dir) if output_dir is not None else Path(tempfile.mkdtemp(prefix="papers-workflow-"))
        work_path.mkdir(parents=True, exist_ok=True)
    providers = build_provider_registry(http)

    download_paths: list[str] = []
    extractions: dict[str, dict] = {}
    warnings: list[dict[str, object]] = []

    selected_papers = papers if max_papers is None else papers[:max_papers]
    for paper in selected_papers:
        pdf_url = paper.get("pdf_url")
        text_url = paper.get("text_url")
        source_id = paper.get("source_id", "unknown")
        source_name = paper.get("source")

        url = text_url or pdf_url
        if not url:
            warnings.append(
                {
                    "stage": "extract",
                    "message": "paper has no extractable URL",
                    "details": {"source_id": source_id, "source": source_name},
                }
            )
            continue

        bundle = None
        if persist_downloads and source_name and source_id and source_name in providers and work_path is not None:
            try:
                record = providers[source_name].lookup(str(source_id))
                bundle = download_paper_bundle(
                    http,
                    record=record,
                    output_dir=work_path,
                )
                download_paths.append(str(bundle["bundle_dir"]))
            except Exception as exc:
                warnings.append(
                    _warning_payload(
                        "download",
                        exc,
                        source=source_name,
                        source_id=source_id,
                    )
                )
                bundle = None

        try:
            extracted = extract_input(http, input_path=None, url=url)
            sections = dict(extracted.sections or {})
            sections["full_text"] = extracted.text

            if persist_downloads and work_path is not None:
                if bundle:
                    text_path = Path(str(bundle["paper_dir"])) / f"{str(source_id).replace('/', '_')}.txt"
                else:
                    filename = str(source_id).replace("/", "_") + ".txt"
                    text_path = work_path / filename
                text_path.write_text(extracted.text, encoding="utf-8")
                download_paths.append(str(text_path))

                if pdf_url and not text_url and not bundle:
                    try:
                        response = http.read(pdf_url, source="download")
                        pdf_name = suggested_filename(response.final_url or pdf_url, response.content_type)
                        pdf_path = work_path / pdf_name
                        pdf_path.write_bytes(response.body)
                        download_paths.append(str(pdf_path))
                    except Exception as exc:
                        warnings.append(
                            _warning_payload(
                                "download",
                                exc,
                                source=source_name,
                                source_id=source_id,
                                url=pdf_url,
                            )
                        )

            extractions[source_id] = sections

        except Exception as exc:
            warnings.append(
                _warning_payload(
                    "extract",
                    exc,
                    source=source_name,
                    source_id=source_id,
                    url=url,
                )
            )
            continue

    return download_paths, extractions, warnings


def full_preprint_workflow(
    query: str,
    max_results: int = 10,
    sources: list[str] | None = None,
    days: int = 60,
    download: bool = False,
    deep_analyze: bool = False,
    creative_mode: bool = False,
    output_dir: str | None = None,
) -> dict:
    """Run the full preprint research workflow.

    Args:
        query: Search query.
        max_results: Maximum number of results.
        sources: List of source names (arxiv, biorxiv, medrxiv).
        days: Date window in days.
        download: Whether to download and extract PDFs.
        deep_analyze: Whether to run ambiguity audit.
        creative_mode: Whether to use creative query expansion.
        output_dir: Directory for downloaded files (temp dir if None).

    Returns:
        Comprehensive result dict with papers, downloads, extractions,
        audits, synthesis, and citations.
    """
    sources = sources or ["arxiv", "biorxiv", "medrxiv"]
    cache = CacheStore(default_cache_dir())
    http = HttpClient(cache)
    warnings: list[dict[str, object]] = []

    # Step 1: Search.
    if creative_mode:
        papers, search_warnings = creative_search_with_warnings(
            query,
            max_results=max_results,
            sources=sources,
            days=days,
        )
        warnings.extend(search_warnings)
    else:
        papers, search_warnings = _search_standard(query, sources, max_results, days, http)
        warnings.extend(search_warnings)

    if not papers:
        result = {
            "query": query,
            "mode": "creative" if creative_mode else "standard",
            "papers": [],
            "note": "No results found. Try broadening the query or increasing the date window.",
        }
        if warnings:
            result["warnings"] = warnings
        return result

    # Step 2: Optional download + extraction.
    download_paths: list[str] | None = None
    extractions: dict[str, dict] | None = None
    if download or deep_analyze:
        download_paths_raw, extractions, extraction_warnings = _download_and_extract(
            papers,
            http,
            output_dir=output_dir,
            max_papers=max_results,
            persist_downloads=download,
        )
        warnings.extend(extraction_warnings)
        if download:
            download_paths = download_paths_raw

    # Step 3: Optional ambiguity audit.
    audits: list[dict] | None = None
    if deep_analyze and extractions is not None:
        audits = []
        for paper in papers[:max_results]:
            source_id = paper.get("source_id", "")
            sections = extractions.get(source_id, {})
            if sections:
                audit = perform_ambiguity_audit(paper, sections)
                audits.append(audit)

    # Step 4: Synthesis.
    synthesis = synthesize_papers(papers)

    # Step 5: Citations (BibTeX).
    citations_bibtex: list[str] = []
    # Reconstruct PaperRecord objects for citation generation.
    providers = build_provider_registry(http)
    for paper in papers[:max_results]:
        source = paper.get("source")
        source_id = paper.get("source_id")
        if source and source_id:
            try:
                provider = providers.get(source)
                if provider is None:
                    raise PaperSearchError(
                        f"unsupported source: {source}",
                        code="unsupported_source",
                    )
                record = provider.lookup(source_id)
                citations_bibtex.append(format_bibtex(record))
            except Exception as exc:
                warnings.append(
                    _warning_payload(
                        "citation",
                        exc,
                        source=source,
                        source_id=source_id,
                    )
                )
                # Fallback: generate simple citation from dict.
                authors = paper.get("authors", ["Unknown"])
                title = paper.get("title", "Untitled")
                year = (paper.get("published_date") or "n.d.")[:4]
                key = authors[0].split()[-1].lower() if authors else "unknown"
                citations_bibtex.append(
                    f"@article{{{key}{year},\n  title = {{{title}}},\n"
                    f"  author = {{{' and '.join(authors)}}},\n"
                    f"  year = {{{year}}},\n  note = {{{source} preprint}}\n}}"
                )

    result = {
        "query": query,
        "mode": "creative" if creative_mode else "standard",
        "papers": papers,
        "downloads": download_paths,
        "extractions": extractions,
        "audits": audits,
        "synthesis": synthesis,
        "citations_bibtex": citations_bibtex,
        "total_found": len(papers),
        "note": "All results are preprints (not peer-reviewed).",
    }
    if warnings:
        result["warnings"] = warnings
    return result

def main() -> int:
    parser = argparse.ArgumentParser(description="Full preprint research workflow.")
    parser.add_argument("query", help="Search query")
    parser.add_argument("--sources", default="arxiv,biorxiv,medrxiv")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--days", type=int, default=60)
    parser.add_argument("--download", action="store_true", help="Download PDFs for top results")
    parser.add_argument("--deep-analyze", action="store_true", help="Run ambiguity audit")
    parser.add_argument("--creative", action="store_true", help="Use creative query expansion")
    parser.add_argument("--output-dir", help="Directory for downloaded files")
    parser.add_argument("--output", help="Write workflow result to this JSON file")
    args = parser.parse_args()

    sources = [s.strip() for s in args.sources.split(",") if s.strip()]
    try:
        result = full_preprint_workflow(
            query=args.query,
            max_results=args.limit,
            sources=sources,
            days=args.days,
            download=args.download,
            deep_analyze=args.deep_analyze,
            creative_mode=args.creative,
            output_dir=args.output_dir,
        )
    except PaperSearchError as exc:
        print(json.dumps(exc.to_dict(), indent=2), file=sys.stderr)
        return 1
    except Exception as exc:
        print(
            json.dumps(
                {
                    "error_code": "unexpected_error",
                    "message": str(exc),
                    "retryable": False,
                    "source": "workflow",
                    "http_status": None,
                    "details": {"query": args.query},
                },
                indent=2,
            ),
            file=sys.stderr,
        )
        return 1

    output = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        Path(args.output).write_text(output + "\n", encoding="utf-8")
        print(f"Results written to {args.output}")
    else:
        print(output)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
