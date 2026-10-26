#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
FACEOFF = CLAUDE / "scripts" / "memory-faceoff.py"

_spec = importlib.util.spec_from_file_location("memory_audit", CLAUDE / "scripts" / "memory-audit.py")
AUDIT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(AUDIT)

SNIPPET_A = "the recall gate always verifies snippets before scoring anything"
SNIPPET_B = "a second and entirely distinct fact used only for scoring math"


def candidate(question="What does the gate verify before scoring?", snippet=SNIPPET_A,
              repo="testrepo", source_path=""):
    return {
        "question": question,
        "answer_snippet": snippet,
        "repo": repo,
        "source_path": source_path,
    }


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.store = root / "store"
        self.store.mkdir()
        self.env = {**os.environ, "FACEOFF_STORES": json.dumps({"testrepo": str(self.store)})}

    def run(self, *args):
        return subprocess.run(
            ["python3", str(FACEOFF), *args],
            text=True, capture_output=True, check=False, env=self.env,
        )

    def source(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def freeze(self, cands, out_name="suite.json"):
        cpath = self.root / "candidates.json"
        cpath.write_text(json.dumps({"candidates": cands}))
        out = self.root / out_name
        result = self.run("freeze", "--candidates", str(cpath), "--out", str(out), "--min-per-repo", "0")
        payload = json.loads(out.read_text())
        return result, payload

    def routing_inputs(self, questions, out_name="routing-inputs.json"):
        suite_path = self.root / "suite.json"
        suite_path.write_text(json.dumps({"schema_version": 1, "questions": questions}))
        out = self.root / out_name
        result = self.run("routing-inputs", "--suite", str(suite_path), "--out", str(out))
        payload = json.loads(out.read_text()) if out.exists() else None
        return result, payload


class StoreConfigurationTests(unittest.TestCase):
    def test_missing_empty_and_invalid_stores_fail_with_shape(self):
        for value in (None, "", "{}", "[]", "broken", '{"acme-app": ""}'):
            with self.subTest(value=value):
                env = dict(os.environ)
                env.pop("FACEOFF_STORES", None)
                if value is not None:
                    env["FACEOFF_STORES"] = value
                result = subprocess.run(
                    ["python3", str(FACEOFF), "--help"],
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("FACEOFF_STORES", result.stderr)
                self.assertIn("JSON object of name -> memory dir", result.stderr)


class FreezeTests(unittest.TestCase):
    def test_unknown_repo_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            src = fixture.source("s1.txt", f"Session text. {SNIPPET_A} More text.")
            result, payload = fixture.freeze([candidate(repo="ghost-repo", source_path=str(src))])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 0)
            self.assertIn("unknown repo", payload["rejected"][0]["reason"])

    def test_snippet_length_bounds_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            src = fixture.source("s1.txt", "Session text with a short bit and a very long bit padded out here.")
            result, payload = fixture.freeze([
                candidate(snippet="too short", source_path=str(src)),
                candidate(question="Is the padded snippet too long for the gate to accept here?",
                          snippet="x" * 400, source_path=str(src)),
            ])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 0)
            reasons = [r["reason"] for r in payload["rejected"]]
            self.assertTrue(all("snippet length" in r for r in reasons))

    def test_malformed_question_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            src = fixture.source("s1.txt", f"Session text. {SNIPPET_A} More text.")
            result, payload = fixture.freeze([
                candidate(question="too short?", source_path=str(src)),
                candidate(question="This question is long enough but has no mark", source_path=str(src)),
            ])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 0)
            reasons = [r["reason"] for r in payload["rejected"]]
            self.assertTrue(all(r == "malformed question" for r in reasons))

    def test_fabricated_snippet_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            src = fixture.source("s1.txt", "Session text that never mentions the fabricated fact at all.")
            result, payload = fixture.freeze([candidate(source_path=str(src))])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 0)
            self.assertIn("fabricated", payload["rejected"][0]["reason"])

    def test_source_unreadable_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            missing = Path(temp) / "does-not-exist.txt"
            result, payload = fixture.freeze([candidate(source_path=str(missing))])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 0)
            self.assertIn("source unreadable", payload["rejected"][0]["reason"])

    def test_duplicate_snippet_rejected_after_first_kept(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            src = fixture.source("s1.txt", f"Session text. {SNIPPET_A} More text.")
            result, payload = fixture.freeze([
                candidate(source_path=str(src)),
                candidate(question="Does it verify snippets before scoring, again?",
                          snippet=SNIPPET_A.upper(), source_path=str(src)),
            ])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 1)
            self.assertEqual(payload["rejected"][0]["reason"], "duplicate snippet")

    def test_valid_candidates_kept_with_sequential_ids(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            src = fixture.source("s1.txt", f"Session text. {SNIPPET_A} {SNIPPET_B} More text.")
            result, payload = fixture.freeze([
                candidate(source_path=str(src)),
                candidate(question="What is the second distinct fact used for?", snippet=SNIPPET_B, source_path=str(src)),
            ])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["questions"]), 2)
            self.assertEqual([q["id"] for q in payload["questions"]], ["q001", "q002"])
            self.assertEqual(payload["per_repo"], {"testrepo": 2})


class RoutingInputsTests(unittest.TestCase):
    """P2 pro-gate-145 #5: the routing judge must see only the same load-capped
    index surface a real Claude Code session actually loads, not the raw file —
    otherwise entries that are routing-invisible in production can still win in
    the benchmark."""

    def test_index_truncated_to_loaded_surface(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            # Well past both the 200-line and 25600-byte load caps.
            lines = [f"- [note-{i}](note-{i}.md) — filler routing line number {i}\n" for i in range(400)]
            lines.insert(0, "MARKER-EARLY-VISIBLE\n")
            lines.append("MARKER-LATE-INVISIBLE\n")
            (fixture.store / "MEMORY.md").write_text("".join(lines))
            result, payload = fixture.routing_inputs(
                [{"id": "q001", "question": "does routing see the tail?", "repo": "testrepo"}]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            index = payload["tasks"][0]["index"]
            self.assertIn("MARKER-EARLY-VISIBLE", index)
            self.assertNotIn("MARKER-LATE-INVISIBLE", index)
            self.assertLessEqual(len(index.splitlines()), AUDIT.INDEX_LOAD_MAX_LINES)
            self.assertLessEqual(len(index.encode("utf-8")), AUDIT.INDEX_LOAD_MAX_BYTES)

    def test_under_cap_index_passed_through_unchanged_besides_frontmatter_strip(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "MEMORY.md").write_text(
                "- [note-1](note-1.md) — a single short routing line\n"
            )
            result, payload = fixture.routing_inputs(
                [{"id": "q001", "question": "x", "repo": "testrepo"}]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("note-1.md", payload["tasks"][0]["index"])


class ScoreTests(unittest.TestCase):
    def _score(self, fixture, suite, cm, routing, semantic=None, out_name="report.json"):
        suite_path = fixture.root / "suite.json"
        suite_path.write_text(json.dumps(suite))
        cm_path = fixture.root / "cm.json"
        cm_path.write_text(json.dumps(cm))
        routing_path = fixture.root / "routing.json"
        routing_path.write_text(json.dumps(routing))
        out = fixture.root / out_name
        args = ["score", "--suite", str(suite_path), "--cm", str(cm_path),
                "--routing", str(routing_path), "--out", str(out)]
        if semantic is not None:
            semantic_path = fixture.root / "semantic.json"
            semantic_path.write_text(json.dumps(semantic))
            args += ["--semantic", str(semantic_path)]
        result = fixture.run(*args)
        payload = json.loads(out.read_text()) if out.exists() else None
        return result, payload

    def test_strict_containment_and_median_chars(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "a.md").write_text(f"Note body. {SNIPPET_A} trailing prose.\n")
            (fixture.store / "c.md").write_text(
                f"Longer note body with lots of padding around it. {SNIPPET_A} and even more trailing prose here.\n"
            )
            suite = {
                "questions": [
                    {"id": "q001", "repo": "testrepo", "answer_snippet": SNIPPET_A},
                    {"id": "q002", "repo": "testrepo", "answer_snippet": SNIPPET_A},
                    {"id": "q003", "repo": "testrepo", "answer_snippet": SNIPPET_A},
                ]
            }
            routing = {"q001": ["a.md"], "q002": ["missing.md"], "q003": ["c.md"]}
            cm = {
                "q001": {"text": "unrelated cm text without the phrase", "chars": 37},
                "q002": {"text": SNIPPET_A, "chars": len(SNIPPET_A)},
                "q003": {"text": "also unrelated", "chars": 15},
            }
            result, report = self._score(fixture, suite, cm, routing)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(report["current"]["strict_pct"], round(100 * 2 / 3, 1))
            self.assertEqual(report["cm"]["strict_pct"], round(100 * 1 / 3, 1))
            a_len = len((fixture.store / "a.md").read_text())
            c_len = len((fixture.store / "c.md").read_text())
            expected_median = sorted([a_len, 0, c_len])[3 // 2]
            self.assertEqual(report["current"]["median_chars"], expected_median)

    def test_semantic_pct_nan_when_no_semantic_file(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "a.md").write_text(f"Note body. {SNIPPET_A}\n")
            suite = {"questions": [{"id": "q001", "repo": "testrepo", "answer_snippet": SNIPPET_A}]}
            routing = {"q001": ["a.md"]}
            cm = {"q001": {"text": "", "chars": 0}}
            result, report = self._score(fixture, suite, cm, routing, semantic=None)
            self.assertEqual(result.returncode, 0)
            self.assertTrue(report["current"]["semantic_pct"] != report["current"]["semantic_pct"])  # nan
            self.assertTrue(report["cm"]["semantic_pct"] != report["cm"]["semantic_pct"])  # nan

    def test_semantic_pct_computed_when_semantic_file_present(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "a.md").write_text(f"Note body. {SNIPPET_A}\n")
            suite = {
                "questions": [
                    {"id": "q001", "repo": "testrepo", "answer_snippet": SNIPPET_A},
                    {"id": "q002", "repo": "testrepo", "answer_snippet": SNIPPET_A},
                ]
            }
            routing = {"q001": ["a.md"], "q002": ["a.md"]}
            cm = {"q001": {"text": "", "chars": 0}, "q002": {"text": "", "chars": 0}}
            semantic = {"q001": {"current": True, "cm": False}, "q002": {"current": False, "cm": False}}
            result, report = self._score(fixture, suite, cm, routing, semantic=semantic)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(report["current"]["semantic_pct"], 50.0)
            self.assertEqual(report["cm"]["semantic_pct"], 0.0)


if __name__ == "__main__":
    unittest.main()
