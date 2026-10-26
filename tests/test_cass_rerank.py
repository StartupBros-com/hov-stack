#!/usr/bin/env python3
"""Hermetic wrapper contract: fake cass, owned HOME, mocked HTTP (not live proof)."""

import contextlib
from email.message import Message
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error

SOURCE = Path(os.environ.get(
    "CASS_RERANK_TEST_SOURCE",
    Path(__file__).resolve().parents[1] / "scripts" / "cass-rerank",
))
HITS: list[dict[str, object]] = [
    {"source_path": "/session/a", "line_number": 11, "title": "First",
     "content": "alpha", "score": 12, "custom": {"keep": True}},
    {"source_path": "/session/b", "line_number": 22, "title": "Second",
     "snippet": "beta", "score": 8},
    {"source_path": "/session/c", "title": "Third", "content": "gamma"},
]
FAKE_CASS = '''import json, os, pathlib, sys
root = pathlib.Path(os.environ["HOME"])
(root / "invocation.json").write_text(json.dumps({
    "argv": sys.argv[1:], "refresh": os.environ.get("CASS_AUTO_REFRESH"),
    "marker": os.environ.get("TEST_INHERITED_MARKER"),
}))
fixture = json.loads((root / "lexical.json").read_text())
sys.stdout.write(fixture["stdout"])
sys.stderr.write(fixture["stderr"])
sys.exit(fixture["code"])
'''


class CassRerankTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cass-rerank-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.cass = self.home / "fake-cass"
        self.cass.write_text(f"#!{sys.executable}\n" + FAKE_CASS)
        self.cass.chmod(0o700)
        self.env = {
            "HOME": str(self.home), "PATH": "/usr/bin:/bin",
            "CASS_BIN": str(self.cass), "CASS_AUTO_REFRESH": "1",
            "CASS_RERANK_ENDPOINT": "https://scoring.invalid///",
            "CASS_RERANK_MODEL": "requested-test-model",
            "TEST_INHERITED_MARKER": "kept",
        }
        self.addCleanup(mock.patch.stopall)
        mock.patch.dict(os.environ, self.env, clear=True).start()
        self.transport = mock.patch("urllib.request.urlopen").start()
        self.score_response({"results": [
            {"index": 1, "relevance_score": 0.5},
            {"index": 0, "relevance_score": 0.5},
        ]})
        self.lexical({"hits": HITS})
        self.module = runpy.run_path(str(SOURCE))

    def lexical(self, payload=None, *, stdout=None, code=0, stderr=""):
        (self.home / "lexical.json").write_text(json.dumps({
            "stdout": json.dumps(payload) if stdout is None else stdout,
            "stderr": stderr, "code": code,
        }))

    def score_response(self, payload):
        self.transport.reset_mock()
        self.transport.side_effect = None
        self.transport.return_value.__enter__.return_value.read.return_value = (
            json.dumps(payload).encode()
        )

    def invoke(self, *options, query="query", as_json=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        argv = [str(SOURCE), query, *options, *( ["--json"] if as_json else [])]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(stdout), \
                contextlib.redirect_stderr(stderr):
            try:
                runpy.run_path(str(SOURCE), run_name="__main__")
            except SystemExit as exc:
                code = exc.code
            else:
                code = 0
        return code, stdout.getvalue(), stderr.getvalue()

    def request_body(self):
        self.transport.assert_called_once()
        req = self.transport.call_args.args[0]
        self.assertEqual(self.transport.call_args.kwargs, {"timeout": 60})
        self.assertEqual(req.full_url, "https://scoring.invalid/v1/rerank")
        return json.loads(req.data)

    def invocation(self):
        return json.loads((self.home / "invocation.json").read_text())

    def assert_failure(self, result):
        code, out, err = result
        self.assertNotEqual(code, 0)
        data = json.loads(out)  # exactly one JSON document, not a traceback
        self.assertEqual(data["rerank_status"], "failed")
        self.assertEqual(data["results"], [])
        self.assertTrue(data["error"])
        self.assertIn("cass-rerank:", err)
        self.assertNotIn("Traceback", err)
        self.assertLess(len(err), 1200)
        self.assertLess(len(data["error"]), 1000)
        return data, err

    def test_positive_reordered_ties_fields_and_existing_controls(self):
        code, out, err = self.invoke("--limit", "2", "--candidates", "3",
                                     "--overfetch", "2", "--model", "cli-model")
        self.assertEqual((code, err), (0, ""))
        data = json.loads(out)
        self.assertEqual(data["results"], [
            {**HITS[1], "rerank_score": 0.5}, {**HITS[0], "rerank_score": 0.5},
        ])
        self.assertEqual(data["model"], "cli-model")
        self.assertEqual(data["pool"], {"fetched": 3, "distinct": 3, "deduped": True})
        self.assertEqual(self.request_body(), {
            "model": "cli-model", "query": "query", "top_n": 2,
            "documents": ["First — alpha", "Second — beta", "Third — gamma"],
        })
        argv = self.invocation()["argv"]
        self.assertEqual(argv[argv.index("--limit") + 1], "6")

    def test_help_describes_limit_as_a_ceiling_not_a_scoring_count_guarantee(self):
        code, out, err = self.invoke("--help", as_json=False)
        self.assertEqual((code, err), (0, ""))
        help_text = " ".join(out.split())
        self.assertIn("maximum final results", help_text)
        self.assertIn("valid scoring may return fewer", help_text)
        self.assertFalse((self.home / "invocation.json").exists())
        self.transport.assert_not_called()

    def test_success_status_and_strict_success(self):
        for options in [(), ("--require-rerank",)]:
            with self.subTest(options=options):
                self.transport.reset_mock()
                code, out, err = self.invoke(*options)
                self.request_body()  # strict must reach scoring, not argparse failure
                self.assertEqual((code, err), (0, ""))
                self.assertEqual(json.loads(out)["rerank_status"], "reranked")

    def test_lexical_subprocess_is_maintenance_disabled_locally(self):
        query = "literal --no-maintenance --mode lexical query"
        code, _, _ = self.invoke(query=query)
        self.assertEqual(code, 0)
        seen = self.invocation()
        self.assertEqual(seen["argv"][:2], ["search", query])
        self.assertIn("--robot", seen["argv"][2:])
        self.assertIn("--no-maintenance", seen["argv"][2:])
        mode = seen["argv"].index("--mode")
        self.assertEqual(seen["argv"][mode + 1], "lexical")
        self.assertEqual(seen["refresh"], "0")
        self.assertEqual(seen["marker"], "kept")
        self.assertEqual(os.environ["CASS_AUTO_REFRESH"], "1")

    def test_genuine_empty_candidates_never_contact_scoring(self):
        self.lexical({"hits": []})
        for options in [(), ("--require-rerank",)]:
            with self.subTest(options=options):
                code, out, err = self.invoke(*options)
                self.assertEqual((code, err), (0, ""))
                self.assertEqual(json.loads(out), {
                    "results": [], "note": "no lexical candidates",
                    "rerank_status": "no_candidates",
                })
                self.transport.assert_not_called()

    def test_native_budget_timeout_is_not_successful_retrieval(self):
        for hits in [[], HITS]:
            for strict in [False, True]:
                for as_json in [False, True]:
                    with self.subTest(hits=bool(hits), strict=strict, as_json=as_json):
                        self.lexical({"hits": hits, "budget": {"timed_out": True}},
                                     stderr="native warning: results are incomplete")
                        self.transport.reset_mock()
                        result = self.invoke(
                            *( ["--require-rerank"] if strict else []), as_json=as_json)
                        self.invocation()  # native search ran; not an argparse failure
                        self.transport.assert_not_called()
                        self.assertNotEqual(result[0], 0)
                        self.assertIn("results are incomplete", result[2])
                        self.assertIn("CASS_SEARCH_TIMEOUT_MS", result[2])
                        self.assertIn("native warning", result[2])
                        self.assertNotIn("Traceback", result[2])
                        self.assertNotIn("falling back", result[2])
                        if as_json:
                            self.assert_failure(result)
                        else:
                            self.assertEqual(result[1], "")

        for hits in [[], HITS]:
            with self.subTest(completed_hits=bool(hits)):
                self.lexical({"hits": hits, "budget": {"timed_out": False}})
                self.transport.reset_mock()
                code, out, err = self.invoke("--require-rerank")
                self.invocation()
                self.assertEqual((code, err), (0, ""))
                data = json.loads(out)
                self.assertEqual(data["rerank_status"], "reranked" if hits else "no_candidates")
                if hits:
                    self.assertEqual(data["results"][0]["source_path"], HITS[1]["source_path"])
                    self.request_body()
                else:
                    self.transport.assert_not_called()

    def test_retrieval_failures_do_not_become_empty_success(self):
        cases = [
            ({"hits": []}, None, 5, "maintenance-required"),
            ({"hits": HITS}, None, 7, "checkpoint incomplete"),
            ({"error": "maintenance-required"}, None, 0, ""),
            ({}, "", 0, ""), ({}, "not json", 0, ""),
            ([], None, 0, ""), (None, None, 0, ""),
            ({"hits": None}, None, 0, ""), ({"hits": {}}, None, 0, ""),
            ({"hits": "bad"}, None, 0, ""),
            ({"hits": [HITS[0], None]}, None, 0, ""),
            ({"hits": [3]}, None, 0, ""),
        ]
        for payload, stdout, code, stderr in cases:
            for options in [(), ("--require-rerank",)]:
                with self.subTest(payload=payload, stdout=stdout, code=code, options=options):
                    self.lexical(payload, stdout=stdout, code=code, stderr=stderr)
                    self.transport.reset_mock()
                    result = self.invoke(*options)
                    self.transport.assert_not_called()
                    self.invocation()  # actual fake cass, not parser failure
                    data, err = self.assert_failure(result)
                    if stderr:
                        self.assertIn(stderr, err)
                        self.assertIn(stderr, data["error"])

    def test_retrieval_timeout_and_missing_binary_are_bounded_failures(self):
        for exc in [subprocess.TimeoutExpired([str(self.cass)], 45),
                    FileNotFoundError("fake cass missing")]:
            with self.subTest(exc=type(exc).__name__):
                with mock.patch("subprocess.run", side_effect=exc) as native:
                    result = self.invoke()
                native.assert_called_once()
                self.assertEqual(native.call_args.kwargs["timeout"], 45)
                self.transport.assert_not_called()
                self.assert_failure(result)

    def test_native_error_diagnostic_is_bounded(self):
        self.lexical({"error": "maintenance-required"}, code=5,
                     stderr="maintenance-required\n" + "x" * 10000)
        _, err = self.assert_failure(self.invoke())
        self.assertIn("maintenance-required", err)
        self.transport.assert_not_called()

    def test_invalid_scoring_mapping_is_rejected_inside_rerank(self):
        bad_results: list[object] = [None, {}, [], [None], [2], [{}]]
        bad_results += [[{"index": index, "relevance_score": 0.5}]
                        for index in [-1, 3, True, False, 0.0, "0", None]]
        invalid_scores: list[object] = [None, True, False, "0.5", float("nan"),
                                        float("inf"), -float("inf"), 10 ** 400, [], {}]
        bad_results += [[{"index": 0, "relevance_score": score}]
                        for score in invalid_scores]
        bad_results += [[{"index": 0}], [
            {"index": 0, "relevance_score": 0.8},
            {"index": 0, "relevance_score": 0.5},
        ], [{"index": i, "relevance_score": 0.5} for i in range(3)]]
        envelopes: list[object] = [None, [], {}, {"error": "backend failed"}]
        envelopes += [{"results": results} for results in bad_results]
        for envelope in envelopes:
            with self.subTest(envelope=envelope):
                self.score_response(envelope)
                with self.assertRaises(ValueError):
                    self.module["rerank"]("query", ["a", "b", "c"], "m", 2)
                self.transport.assert_called_once()

    def test_result_count_is_also_bounded_by_available_documents(self):
        self.score_response({"results": [
            {"index": 0, "relevance_score": 1},
            {"index": 1, "relevance_score": 0.5},
        ]})
        with self.assertRaises(ValueError):
            self.module["rerank"]("q", ["only"], "m", 5)
        self.transport.assert_called_once()

    def test_short_nonempty_scoring_response_and_finite_scores_are_valid(self):
        for score in [-4, 0, 10 ** 100, 1e300]:
            with self.subTest(score=score):
                expected = [{"index": 2, "relevance_score": score}]
                self.score_response({"results": expected})
                self.assertEqual(self.module["rerank"]("q", ["a", "b", "c"], "m", 5),
                                 expected)

    def test_scoring_errors_fallback_by_default_but_fail_strictly(self):
        failures = [
            OSError("service unavailable " + "x" * 10000),
            urllib.error.HTTPError("https://scoring.invalid", 503, "down", Message(), None),
            b"not json",
            json.dumps({"results": []}).encode(),
            json.dumps({"results": [{"index": -1, "relevance_score": 0.2}]}).encode(),
            json.dumps({"results": [{"index": 0, "relevance_score": True}]}).encode(),
        ]
        for failure in failures:
            for strict in [False, True]:
                with self.subTest(failure=str(failure)[:80], strict=strict):
                    self.transport.reset_mock()
                    self.transport.side_effect = failure if isinstance(failure, Exception) else None
                    if isinstance(failure, bytes):
                        self.transport.return_value.__enter__.return_value.read.return_value = failure
                    result = self.invoke("--limit", "2", *( ["--require-rerank"] if strict else []))
                    body = self.request_body()  # guards against parser-error false green
                    self.assertEqual(len(body["documents"]), 3)
                    if strict:
                        self.assert_failure(result)
                        self.assertNotIn("falling back", result[2])
                    else:
                        code, out, err = result
                        self.assertEqual(code, 0)
                        data = json.loads(out)
                        self.assertEqual(data["rerank_status"], "lexical_fallback")
                        self.assertEqual(data["results"], [{**h, "rerank_score": None} for h in HITS[:2]])
                        self.assertEqual(data["model"], "requested-test-model")
                        self.assertEqual(data["pool"], {"fetched": 3, "distinct": 3, "deduped": True})
                        self.assertIn("falling back to lexical order", err)
                        self.assertLess(len(err), 1200)

    def test_unrepresentable_score_falls_back_or_fails_strictly(self):
        for as_json in [False, True]:
            for strict in [False, True]:
                with self.subTest(as_json=as_json, strict=strict):
                    self.score_response({"results": [
                        {"index": 0, "relevance_score": 10 ** 400},
                    ]})
                    result = self.invoke(
                        *( ["--require-rerank"] if strict else []), as_json=as_json)
                    self.request_body()  # scoring ran; parser errors cannot pass
                    code, out, err = result
                    self.assertIn("finite number", err)
                    if strict:
                        self.assertNotEqual(code, 0)
                        self.assertNotIn("falling back", err)
                        if as_json:
                            self.assert_failure(result)
                        else:
                            self.assertEqual(out, "")
                    else:
                        self.assertEqual(code, 0)
                        self.assertIn("falling back", err)
                        if as_json:
                            data = json.loads(out)
                            self.assertEqual(data["rerank_status"], "lexical_fallback")
                            self.assertTrue(all(h["rerank_score"] is None
                                                for h in data["results"]))
                        else:
                            self.assertTrue(out.startswith("1. First — alpha"))

    def test_environment_and_key_precedence_without_real_credentials(self):
        key_path = self.home / ".config" / "cass-rerank" / "key"
        key_path.parent.mkdir(parents=True)
        for env_key, file_key, expected in [
            (None, None, None), (None, " file-fixture\n", "file-fixture"),
            (" env-fixture\n", "file-fixture", "env-fixture"),
            ("", "file-fixture", "file-fixture"),
        ]:
            with self.subTest(env_key=env_key, file_key=file_key):
                if file_key is not None:
                    key_path.write_text(file_key)
                if env_key is not None:
                    os.environ["CASS_RERANK_API_KEY"] = env_key
                else:
                    os.environ.pop("CASS_RERANK_API_KEY", None)
                self.transport.reset_mock()
                code, out, _ = self.invoke()
                self.assertEqual(code, 0)
                self.assertEqual(json.loads(out)["model"], "requested-test-model")
                self.assertEqual(self.request_body()["model"], "requested-test-model")
                req = self.transport.call_args.args[0]
                self.assertEqual(req.get_header("Authorization"),
                                 f"Bearer {expected}" if expected else None)

    def test_rerank_fails_closed_without_an_endpoint(self):
        # No built-in URL: a stale default would send queries to a host the operator
        # never configured. Unset, the request is refused before any socket is opened.
        os.environ.pop("CASS_RERANK_ENDPOINT")
        module = runpy.run_path(str(SOURCE))
        with self.assertRaisesRegex(RuntimeError, "CASS_RERANK_ENDPOINT is not set"):
            module["rerank"]("query", ["doc"], "local-rerank", 1)
        self.transport.assert_not_called()

    def test_defaults_resolve_only_inside_owned_home(self):
        for name in ["CASS_BIN", "CASS_RERANK_ENDPOINT", "CASS_RERANK_MODEL"]:
            os.environ.pop(name)
        module = runpy.run_path(str(SOURCE))
        self.assertEqual(module["CASS"], str(self.home / ".local" / "bin" / "cass"))
        self.assertEqual(module["DEFAULT_MODEL"], "local-rerank")
        self.assertEqual(module["ENDPOINT"], "")
        self.assertEqual(module["KEY_FILE"], str(self.home / ".config" / "cass-rerank" / "key"))
        self.transport.assert_not_called()

    def test_dedupe_retains_first_source_title_and_object_identity(self):
        a, b = {"content": "no identity"}, {"content": "no identity"}
        hits = [HITS[0], {**HITS[0], "content": "later"}, {"title": "Title"},
                {"title": "Title", "content": "later"}, a, b, a]
        dedupe = self.module["dedupe_by_source"]
        result = dedupe(hits, 40)
        self.assertEqual(len(result), 4)
        self.assertIs(result[0], hits[0])
        self.assertIs(result[1], hits[2])
        self.assertIs(result[2], a)
        self.assertIs(result[3], b)
        self.assertEqual(dedupe(hits, 2), [hits[0], hits[2]])

    def test_dedupe_overfetch_cap_and_no_dedupe_compatibility(self):
        raw = [HITS[0], {**HITS[0], "content": "second match"}, HITS[1]]
        self.lexical({"hits": raw})
        for options, limit, distinct, deduped in [
            (["--candidates", "300", "--overfetch", "3"], "500", 2, True),
            (["--candidates", "3", "--overfetch", "0"], "3", 2, True),
            (["--candidates", "3", "--overfetch", "-2"], "3", 2, True),
            (["--candidates", "600", "--overfetch", "9", "--no-dedupe"], "600", 3, False),
        ]:
            with self.subTest(options=options):
                self.transport.reset_mock()
                code, out, _ = self.invoke(*options)
                self.assertEqual(code, 0)
                self.assertEqual(json.loads(out)["pool"], {
                    "fetched": 3, "distinct": distinct, "deduped": deduped,
                })
                argv = self.invocation()["argv"]
                self.assertEqual(argv[argv.index("--limit") + 1], limit)
                docs = self.request_body()["documents"]
                self.assertEqual(len(docs), distinct)
                self.assertEqual(docs[1], "Second — beta" if deduped else "First — second match")

    def test_document_preparation_and_text_locations(self):
        doc_text = self.module["doc_text"]
        self.assertEqual(doc_text({"title": "T", "content": "x" * 3000}),
                         ("T — " + "x" * 3000)[:2000])
        self.assertEqual(doc_text({"title": None, "content": "", "snippet": "backup"}), "backup")
        self.assertEqual(doc_text({}), "")
        self.lexical({"hits": [{**HITS[0], "content": "x" * 3000}, HITS[1]]})
        code, out, err = self.invoke(as_json=False)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("1. [0.500] Second — beta\n     /session/b:22\n", out)
        self.assertIn("/session/a:11", out)
        self.assertEqual(len(self.request_body()["documents"][0]), 2000)

    def test_text_fallback_empty_and_failure_output(self):
        self.transport.side_effect = OSError("scoring unavailable")
        code, out, err = self.invoke(as_json=False)
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("1. First — alpha\n     /session/a:11\n"))
        self.assertIn("falling back", err)
        self.assertNotIn("[", out)
        self.transport.reset_mock()
        result = self.invoke("--require-rerank", as_json=False)
        self.transport.assert_called_once()
        self.assertNotEqual(result[0], 0)
        self.assertEqual(result[1], "")
        self.assertIn("scoring unavailable", result[2])
        self.lexical({"hits": []})
        self.transport.reset_mock()
        self.assertEqual(self.invoke(as_json=False), (0, "no results\n", ""))
        self.transport.assert_not_called()


if __name__ == "__main__":
    unittest.main()
