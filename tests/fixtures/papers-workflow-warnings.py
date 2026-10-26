"""Hermetic dependencies and behavioral tests for the real workflow overlay."""

import contextlib
import importlib
import io
import json
from pathlib import Path
import socket
import subprocess
import sys
import unittest
from unittest.mock import patch


SCRIPTS = Path(sys.argv.pop(1)).resolve()
LIBRARY = SCRIPTS / "paper_search_lib"
LIBRARY.mkdir()
(LIBRARY / "__init__.py").write_text("", encoding="utf-8")

# Only external dependencies are controlled. Search, extraction orchestration,
# warning construction, fallback citation, and main() all run from the overlay.
(SCRIPTS / "controlled.py").write_text(
    """
from datetime import date
from pathlib import Path
from types import SimpleNamespace

STATE = {}
CALLS = []
PAPER = {
    "source": "arxiv", "source_id": "p1", "title": "Example preprint",
    "authors": ["Ada Lovelace"], "published_date": "2026-04-01",
    "text_url": "https://example.invalid/p1.txt",
    "pdf_url": "https://example.invalid/p1.pdf", "relevance_score": 1.0,
}

class PaperSearchError(RuntimeError):
    def __init__(self, message, *, code, details=None):
        super().__init__(message)
        self.code = code
        self.details = details or {}

    def to_dict(self):
        return {"error_code": self.code, "message": str(self),
                "retryable": False, "source": None, "http_status": None,
                "details": self.details}

class PaperRecord:
    def __init__(self, payload):
        self.payload = dict(payload)
        self.relevance_score = payload["relevance_score"]
        self.published_date = payload["published_date"]

    def to_dict(self):
        return dict(self.payload)

class CacheStore:
    def __init__(self, path):
        assert path == Path.home() / "cache"

class HttpClient:
    def __init__(self, cache):
        pass

    def read(self, url, **kwargs):
        CALLS.append(("read", url, kwargs))
        raise STATE.get("read_error", AssertionError("unexpected HTTP read"))

def default_cache_dir():
    return Path.home() / "cache"

def dedupe_records(records):
    return list({r.payload["source_id"]: r for r in records}.values())

def parse_date(value):
    return date.fromisoformat(value)

def suggested_filename(*args):
    return "paper.pdf"

class SearchArgs(SimpleNamespace):
    pass

class Provider:
    def __init__(self, source):
        self.source = source

    def search(self, args):
        CALLS.append(("search", self.source, vars(args)))
        error = STATE.get("search_errors", {}).get(self.source)
        if error:
            raise error
        return [PaperRecord(p) for p in STATE.get("papers", [PAPER])
                if p["source"] == self.source]

    def lookup(self, source_id):
        CALLS.append(("lookup", self.source, source_id))
        error = STATE.get("lookup_error")
        if error:
            raise error
        return PaperRecord(PAPER)

def build_provider_registry(http):
    return {source: Provider(source) for source in ("arxiv", "biorxiv", "medrxiv")}

def download_paper_bundle(http, *, record, output_dir):
    CALLS.append(("bundle", str(output_dir)))
    error = STATE.get("bundle_error")
    if error:
        raise error
    raise AssertionError("unexpected bundle download")

def extract_input(http, *, input_path, url):
    CALLS.append(("extract", input_path, url))
    error = STATE.get("extract_error")
    if error:
        raise error
    return SimpleNamespace(sections={"methods": "Controlled methods"},
                           text="Controlled full text")

def format_bibtex(record):
    CALLS.append(("citation", record.payload["source_id"]))
    error = STATE.get("citation_error")
    if error:
        raise error
    return "@article{controlled, title={Example preprint}}"

def perform_ambiguity_audit(paper, sections):
    CALLS.append(("audit", paper["source_id"], sections))
    return {"source_id": paper["source_id"], "flags": []}

def creative_search_with_warnings(query, **kwargs):
    CALLS.append(("creative", query, kwargs))
    return STATE.get("papers", [dict(PAPER)]), STATE.get("creative_warnings", [])

def synthesize_papers(papers):
    CALLS.append(("synthesis", len(papers)))
    return "Controlled synthesis"
""",
    encoding="utf-8",
)

for module, exports in {
    "core": "CacheStore, HttpClient, PaperSearchError, PaperRecord, default_cache_dir, dedupe_records, parse_date, suggested_filename",
    "bundle": "download_paper_bundle",
    "providers": "SearchArgs, build_provider_registry",
    "extract": "extract_input",
    "citation": "format_bibtex",
}.items():
    (LIBRARY / f"{module}.py").write_text(
        f"from controlled import {exports}\n", encoding="utf-8"
    )
for module, exports in {
    "analysis": "perform_ambiguity_audit",
    "synthesis": "creative_search_with_warnings, synthesize_papers",
}.items():
    (SCRIPTS / f"{module}.py").write_text(
        f"from controlled import {exports}\n", encoding="utf-8"
    )

sys.path.insert(0, str(SCRIPTS))
dependencies = importlib.import_module("controlled")
workflow = importlib.import_module("workflow")
assert Path(workflow.__file__).resolve() == SCRIPTS / "workflow.py"


class WorkflowWarningsTests(unittest.TestCase):
    def setUp(self):
        dependencies.STATE.clear()
        dependencies.CALLS.clear()
        self.network_guard = patch.object(
            socket, "socket", side_effect=AssertionError("network is forbidden")
        )
        self.network_guard.start()
        self.addCleanup(self.network_guard.stop)

    def run_workflow(self, **kwargs):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = workflow.full_preprint_workflow("test query", **kwargs)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(json.loads(json.dumps(result)), result)
        return result

    def test_standard_search_warning_retention(self):
        dependencies.STATE["search_errors"] = {"biorxiv": RuntimeError("source down")}
        result = self.run_workflow(sources=["arxiv", "biorxiv", "unsupported"])
        self.assertEqual(result["total_found"], 1)
        self.assertEqual(
            result.get("warnings"),
            [
                {
                    "stage": "search",
                    "message": "source down",
                    "details": {"source": "biorxiv"},
                },
                {
                    "stage": "search",
                    "message": "unsupported source skipped: unsupported",
                    "details": {"source": "unsupported"},
                },
            ],
        )
        self.assertEqual(result["mode"], "standard")

    def test_creative_search_warning_retention(self):
        expected = [
            {
                "stage": "search",
                "message": "query expansion failed",
                "details": {"query": "expanded"},
            },
            {
                "stage": "search",
                "message": "partial source",
                "details": {"source": "medrxiv"},
            },
        ]
        dependencies.STATE["creative_warnings"] = expected
        result = self.run_workflow(
            creative_mode=True, sources=["arxiv"], days=7, max_results=2
        )
        self.assertEqual(result.get("warnings"), expected)
        self.assertEqual(result["mode"], "creative")
        self.assertEqual(result["total_found"], 1)
        self.assertEqual(
            dependencies.CALLS[0],
            (
                "creative",
                "test query",
                {"max_results": 2, "sources": ["arxiv"], "days": 7},
            ),
        )

    def test_warning_order_and_structured_error_details(self):
        dependencies.STATE.update(
            search_errors={"biorxiv": RuntimeError("search failed")},
            lookup_error=dependencies.PaperSearchError(
                "lookup failed", code="lookup_failed"
            ),
            extract_error=RuntimeError("extract failed"),
        )
        result = self.run_workflow(download=True, output_dir=str(SCRIPTS / "ordered"))
        warnings = result.get("warnings", [])
        self.assertEqual(
            [w["stage"] for w in warnings],
            ["search", "download", "extract", "citation"],
        )
        self.assertEqual(
            [w["message"] for w in warnings],
            ["search failed", "lookup failed", "extract failed", "lookup failed"],
        )
        self.assertEqual(warnings[0]["details"], {"source": "biorxiv"})
        for index in (1, 3):
            self.assertEqual(
                warnings[index]["details"], {"source": "arxiv", "source_id": "p1"}
            )
            self.assertEqual(
                warnings[index]["error"],
                {
                    "error_code": "lookup_failed",
                    "message": "lookup failed",
                    "retryable": False,
                    "source": None,
                    "http_status": None,
                    "details": {},
                },
            )
        self.assertEqual(
            warnings[2]["details"],
            {
                "source": "arxiv",
                "source_id": "p1",
                "url": "https://example.invalid/p1.txt",
            },
        )
        self.assertNotIn("error", warnings[2])
        self.assertEqual(result["downloads"], [])
        self.assertEqual(result["extractions"], {})
        self.assertEqual(result["synthesis"], "Controlled synthesis")

    def test_download_failures_preserve_extracted_text(self):
        dependencies.STATE.update(
            papers=[dict(dependencies.PAPER, text_url=None)],
            bundle_error=RuntimeError("bundle failed"),
            read_error=RuntimeError("pdf failed"),
        )
        output_dir = SCRIPTS / "downloads"
        result = self.run_workflow(download=True, output_dir=str(output_dir))
        self.assertEqual(
            result.get("warnings"),
            [
                {
                    "stage": "download",
                    "message": "bundle failed",
                    "details": {"source": "arxiv", "source_id": "p1"},
                },
                {
                    "stage": "download",
                    "message": "pdf failed",
                    "details": {
                        "source": "arxiv",
                        "source_id": "p1",
                        "url": "https://example.invalid/p1.pdf",
                    },
                },
            ],
        )
        self.assertEqual(result["downloads"], [str(output_dir / "p1.txt")])
        self.assertEqual((output_dir / "p1.txt").read_text(), "Controlled full text")
        self.assertEqual(
            result["extractions"]["p1"]["full_text"], "Controlled full text"
        )

    def test_missing_extractable_url_retains_warning(self):
        dependencies.STATE["papers"] = [
            dict(dependencies.PAPER, text_url=None, pdf_url=None)
        ]
        result = self.run_workflow(deep_analyze=True)
        self.assertEqual(
            result.get("warnings"),
            [
                {
                    "stage": "extract",
                    "message": "paper has no extractable URL",
                    "details": {"source_id": "p1", "source": "arxiv"},
                }
            ],
        )
        self.assertEqual(result["extractions"], {})
        self.assertEqual(result["audits"], [])

    def test_citation_failure_retains_warning_and_fallback_bibtex(self):
        dependencies.STATE["citation_error"] = RuntimeError("citation formatter failed")
        result = self.run_workflow()
        self.assertEqual(
            result.get("warnings"),
            [
                {
                    "stage": "citation",
                    "message": "citation formatter failed",
                    "details": {"source": "arxiv", "source_id": "p1"},
                }
            ],
        )
        self.assertEqual(
            result["citations_bibtex"],
            [
                "@article{lovelace2026,\n  title = {Example preprint},\n  author = {Ada Lovelace},\n  year = {2026},\n  note = {arxiv preprint}\n}"
            ],
        )

    def test_clean_success_without_warnings(self):
        result = self.run_workflow()
        self.assertEqual(
            result,
            {
                "query": "test query",
                "mode": "standard",
                "papers": [dependencies.PAPER],
                "downloads": None,
                "extractions": None,
                "audits": None,
                "synthesis": "Controlled synthesis",
                "citations_bibtex": ["@article{controlled, title={Example preprint}}"],
                "total_found": 1,
                "note": "All results are preprints (not peer-reviewed).",
            },
        )

    def test_empty_results_preserve_early_return(self):
        dependencies.STATE["papers"] = []
        for creative in (False, True):
            with self.subTest(creative=creative):
                result = self.run_workflow(
                    creative_mode=creative, download=True, deep_analyze=True
                )
                self.assertEqual(
                    result,
                    {
                        "query": "test query",
                        "mode": "creative" if creative else "standard",
                        "papers": [],
                        "note": "No results found. Try broadening the query or increasing the date window.",
                    },
                )
        self.assertFalse(
            any(
                call[0] in {"extract", "bundle", "synthesis", "lookup", "audit"}
                for call in dependencies.CALLS
            )
        )

    def test_empty_results_retain_search_warnings(self):
        dependencies.STATE.update(
            papers=[], search_errors={"arxiv": RuntimeError("empty source failed")}
        )
        result = self.run_workflow(sources=["arxiv"])
        self.assertEqual(result["papers"], [])
        self.assertEqual(
            result.get("warnings"),
            [
                {
                    "stage": "search",
                    "message": "empty source failed",
                    "details": {"source": "arxiv"},
                }
            ],
        )
        self.assertNotIn("citations_bibtex", result)

    def test_deep_analysis_without_download(self):
        unused_output = SCRIPTS / "must-not-create"
        result = self.run_workflow(
            deep_analyze=True, download=False, output_dir=str(unused_output)
        )
        self.assertIsNone(result["downloads"])
        self.assertEqual(
            result["extractions"],
            {
                "p1": {
                    "methods": "Controlled methods",
                    "full_text": "Controlled full text",
                }
            },
        )
        self.assertEqual(result["audits"], [{"source_id": "p1", "flags": []}])
        self.assertIn(("audit", "p1", result["extractions"]["p1"]), dependencies.CALLS)
        self.assertFalse(
            any(call[0] in {"bundle", "read"} for call in dependencies.CALLS)
        )
        self.assertFalse(unused_output.exists())
        self.assertNotIn("warnings", result)

    def test_dns_error_details_survive_json_output(self):
        # HttpClient puts URLError.reason in details; DNS failures carry a
        # real socket.gaierror, not a JSON-native string.
        reason = socket.gaierror(-2, "Name or service not known")
        for empty in (False, True):
            with self.subTest(empty=empty):
                dependencies.STATE.update(
                    papers=[] if empty else [dependencies.PAPER],
                    search_errors={
                        "biorxiv": dependencies.PaperSearchError(
                            "network failed",
                            code="network_error",
                            details={"reason": reason, "attempts": 3},
                        )
                    },
                )
                stdout = io.StringIO()
                with patch.object(sys, "argv", ["workflow.py", "test query"]):
                    with contextlib.redirect_stdout(stdout):
                        code = workflow.main()
                self.assertEqual(code, 0)
                result = json.loads(stdout.getvalue())
                self.assertEqual(len(result["papers"]), 0 if empty else 1)
                warning = result["warnings"][0]
                self.assertEqual(warning["error"]["error_code"], "network_error")
                self.assertEqual(
                    warning["error"]["details"],
                    {
                        "reason": str(reason),
                        "attempts": 3,
                    },
                )

    def test_nested_exception_details_keep_other_warning_fields(self):
        reason = TimeoutError("upstream timeout")
        dependencies.STATE["lookup_error"] = dependencies.PaperSearchError(
            "lookup failed",
            code="network_error",
            details={"causes": [{"reason": reason, "retryable": True}], "status": None},
        )
        result = self.run_workflow()
        encoded = json.loads(json.dumps(result))
        self.assertEqual(encoded["total_found"], 1)
        warning = encoded["warnings"][0]
        self.assertEqual(warning["stage"], "citation")
        self.assertEqual(warning["details"], {"source": "arxiv", "source_id": "p1"})
        self.assertEqual(
            warning["error"]["details"],
            {
                "causes": [{"reason": "upstream timeout", "retryable": True}],
                "status": None,
            },
        )
        self.assertTrue(encoded["citations_bibtex"])

    def test_main_emits_json_with_warnings(self):
        dependencies.STATE["search_errors"] = {
            "biorxiv": RuntimeError("stdout warning")
        }
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", ["workflow.py", "test query"]):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = workflow.main()
        self.assertEqual(code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertTrue(stdout.getvalue().endswith("\n"))
        result = json.loads(stdout.getvalue())
        self.assertEqual(result["total_found"], 1)
        self.assertEqual(
            result.get("warnings"),
            [
                {
                    "stage": "search",
                    "message": "stdout warning",
                    "details": {"source": "biorxiv"},
                }
            ],
        )

    def test_standalone_json_and_output_file_contract(self):
        command = [
            sys.executable,
            "-B",
            "-E",
            "-S",
            str(SCRIPTS / "workflow.py"),
            "CLI query",
        ]
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        expected = json.loads(completed.stdout)
        self.assertEqual(expected["query"], "CLI query")
        self.assertNotIn("warnings", expected)
        destination = SCRIPTS / "result.json"
        completed = subprocess.run(
            command + ["--output", str(destination)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(completed.stdout, f"Results written to {destination}\n")
        self.assertEqual(json.loads(destination.read_text()), expected)
        self.assertTrue(destination.read_text().endswith("\n"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
