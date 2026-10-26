#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

CLAUDE = Path(__file__).resolve().parents[1]
CONTROLLER = CLAUDE / "scripts" / "memory-mine-controller.py"
WRITER = CLAUDE / "scripts" / "memory-mine.py"

_spec = importlib.util.spec_from_file_location("memory_mine_controller", CONTROLLER)
MMC = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(MMC)

NOTE_SENTINEL = "PRIVATE-NOTE-BODY-SENTINEL-24"


class ControllerFixture:
    def __init__(self, root: Path):
        self.root = root
        self.home = root / "home"
        self.projects = self.home / ".claude" / "projects"
        self.projects.mkdir(parents=True)
        self.state = root / "state"
        self.control = root / "fake-claude-control.json"
        self.calls = root / "fake-claude-calls.jsonl"
        self.fake_claude = root / "fake-claude.py"
        self.bin = root / "bin"
        self.bin.mkdir()
        self.cass_sessions = root / "cass-sessions.txt"
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self._write_fake_claude()
        self._write_fake_cass()
        self.set_behaviors("success")

    def _write_fake_claude(self) -> None:
        script = f"""\
            #!{sys.executable}
            import json
            import os
            import signal
            import sys
            import time
            from pathlib import Path

            CONTROL = Path({str(self.control)!r})
            CALLS = Path({str(self.calls)!r})
            control = json.loads(CONTROL.read_text())
            existing = CALLS.read_text().splitlines() if CALLS.exists() else []
            index = len(existing)
            behaviors = control.get("behaviors", ["success"])
            behavior = behaviors[min(index, len(behaviors) - 1)]
            prompt = sys.stdin.read()
            argv = sys.argv[1:]
            captured_env = {{
                key: os.environ[key]
                for key in ("ANTHROPIC_BASE_URL", "PATH", "HOME", "SECRET_SENTINEL")
                if key in os.environ
            }}
            with CALLS.open("a") as output:
                output.write(json.dumps({{"argv": argv, "prompt": prompt, "env": captured_env}}) + "\\n")

            if behavior == "timeout":
                time.sleep(5)
            if behavior in {"crash_parent", "crash_parent_live"}:
                os.kill(os.getppid(), signal.SIGKILL)
                time.sleep(5 if behavior == "crash_parent_live" else 0.1)
                raise SystemExit(0)
            if behavior == "malformed_outer":
                print("{{not-json")
                raise SystemExit(0)
            if behavior == "empty_outer":
                raise SystemExit(0)

            manifest = json.loads((Path.cwd() / "manifest.json").read_text())
            session_names = [item["source_session"] for item in manifest["sessions"]]
            body = control.get("note_body")
            sessions = []
            for position, source_session in enumerate(session_names):
                if body and position == 0:
                    sessions.append({{
                        "source_session": source_session,
                        "disposition": "notes",
                        "reason": "A durable controller fact was found.",
                        "notes": [{{
                            "name": "controller-private-fixture",
                            "description": "A private durable controller fixture used for integration verification",
                            "type": "project",
                            "body": body + " " + ("Durable private context. " * 5) + "\\n\\n**Why:** It proves cleanup.\\n\\n**How to apply:** Keep receipts body-free.",
                            "confidence": 0.9,
                            "source_session": source_session,
                        }}],
                    }})
                else:
                    sessions.append({{
                        "source_session": source_session,
                        "disposition": "no-durable-knowledge",
                        "reason": "No durable knowledge remained after review.",
                        "notes": [],
                    }})

            if behavior == "missing_session":
                sessions = sessions[:-1]
            elif behavior == "extra_session":
                sessions.append({{
                    "source_session": "extraneous.jsonl",
                    "disposition": "no-durable-knowledge",
                    "reason": "Extraneous fixture.",
                    "notes": [],
                }})
            elif behavior == "duplicate_session":
                sessions[1]["source_session"] = sessions[0]["source_session"]
            elif behavior == "wrong_session_set":
                sessions[1]["source_session"] = "wrong-session.jsonl"
            elif behavior == "whitespace_session":
                sessions[1]["source_session"] = " second-session.jsonl "
            elif behavior == "reversed_sessions":
                sessions.reverse()
            elif behavior == "blank_reason":
                sessions[0]["reason"] = "   "
            elif behavior == "unhashable_disposition":
                sessions[0]["disposition"] = []
            elif behavior == "nested_source_mismatch":
                sessions[0]["notes"][0]["source_session"] = session_names[1]
            elif behavior == "unhashable_note_type":
                sessions[0]["notes"][0]["type"] = {{}}

            candidate = {{"schema_version": 1, "sessions": sessions}}
            session_id = argv[argv.index("--session-id") + 1]
            model_usage = {{"claude-sonnet-5": {{"inputTokens": 20, "outputTokens": 10}}}}
            terminal = "completed"
            turns = 2
            denials = []
            if behavior == "reported_turn_boundary":
                turns = 13
            elif behavior == "reported_turn_overflow":
                turns = 14
            elif behavior == "nonterminal_boundary":
                turns = 13
                terminal = "max_turns"
            elif behavior == "wrong_session":
                session_id = "00000000-0000-4000-8000-000000000000"
            elif behavior == "wrong_model":
                model_usage = {{"claude-opus-5": {{"inputTokens": 20, "outputTokens": 10}}}}
            elif behavior == "multi_model":
                model_usage["claude-opus-5"] = {{"inputTokens": 1, "outputTokens": 1}}
            elif behavior == "permission_denial":
                denials = [{{"tool": "Read"}}]
            elif behavior == "nonterminal":
                terminal = "max_turns"

            envelope = {{
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "session_id": session_id,
                "result": json.dumps(candidate),
                "structured_output": candidate,
                "stop_reason": "end_turn",
                "terminal_reason": terminal,
                "total_cost_usd": 0.01,
                "num_turns": turns,
                "duration_ms": 120,
                "duration_api_ms": 100,
                "permission_denials": denials,
                "modelUsage": model_usage,
                "usage": {{"input_tokens": 20, "output_tokens": 10}},
            }}
            if behavior == "result_only":
                envelope.pop("structured_output")
            elif behavior == "malformed_result":
                envelope.pop("structured_output")
                envelope["result"] = "{{bad-json"
            elif behavior == "malformed_structured":
                envelope["structured_output"] = "not-an-object"
            print(json.dumps(envelope))
        """
        self.fake_claude.write_text(textwrap.dedent(script))
        self.fake_claude.chmod(0o755)

    def _write_fake_cass(self) -> None:
        script = self.bin / "cass"
        script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            '[ "${1:-}" = search ]\n'
            f"cat {str(self.cass_sessions)!r}\n"
        )
        script.chmod(0o755)

    def set_behaviors(self, *behaviors: str, note_body: str | None = None) -> None:
        payload: dict[str, object] = {"behaviors": list(behaviors)}
        if note_body is not None:
            payload["note_body"] = note_body
        self.control.write_text(json.dumps(payload))

    def add_project(self, slug: str, session_count: int = 2) -> tuple[Path, Path]:
        project = self.projects / slug
        store = project / "memory"
        store.mkdir(parents=True)
        for index in range(session_count):
            self.add_session(slug, f"{slug}-session-{index}.jsonl")
        return project, store

    def add_session(self, slug: str, name: str, *, age_seconds: int = 7200) -> Path:
        project = self.projects / slug
        project.mkdir(parents=True, exist_ok=True)
        path = project / name
        path.write_text((json.dumps({"fixture": name}) + "\n") * 900)
        when = time.time() - age_seconds
        os.utime(path, (when, when))
        return path

    def add_sparse_session(
        self, slug: str, name: str, size: int, *, age_seconds: int = 7200
    ) -> Path:
        project = self.projects / slug
        project.mkdir(parents=True, exist_ok=True)
        path = project / name
        with path.open("wb") as stream:
            stream.truncate(size)
        when = time.time() - age_seconds
        os.utime(path, (when, when))
        return path

    def add_cass_session(self, name: str, *, age_seconds: int = 10800) -> Path:
        path = self.root / name
        path.write_text((json.dumps({"fixture": name}) + "\n") * 900)
        when = time.time() - age_seconds
        os.utime(path, (when, when))
        existing = self.cass_sessions.read_text() if self.cass_sessions.exists() else ""
        self.cass_sessions.write_text(existing + str(path) + "\n")
        return path

    def environment(
        self, *, writer: Path | None = None, timeout: str = "2"
    ) -> dict[str, str]:
        return {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ.get('PATH', '')}",
            "HOME": str(self.home),
            "MEMORY_MINE_STATE_ROOT": str(self.state),
            "MEMORY_MINE_PROJECTS_ROOT": str(self.projects),
            "MEMORY_MINE_SCRIPT": str(writer or WRITER),
            "CLAUDE_BIN": str(self.fake_claude),
            "MEMORY_MINE_PROXY_URL": "http://localhost:8788",
            "MEMORY_MINE_CHILD_TIMEOUT": timeout,
            "MEMORY_MINE_NOW": self.now.isoformat(),
            "SECRET_SENTINEL": "must-not-reach-child",
        }

    def run(
        self,
        *args: str,
        writer: Path | None = None,
        timeout: str = "2",
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CONTROLLER), *args],
            text=True,
            capture_output=True,
            check=False,
            env=self.environment(writer=writer, timeout=timeout),
            timeout=15,
        )

    def call_log(self) -> list[dict[str, object]]:
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def run_dirs(self) -> list[Path]:
        runs = self.state / "runs"
        return (
            sorted(path for path in runs.iterdir() if path.is_dir())
            if runs.exists()
            else []
        )

    def final_receipts(self) -> list[dict[str, object]]:
        return [
            json.loads((run / "final-receipt.json").read_text())
            for run in self.run_dirs()
            if (run / "final-receipt.json").exists()
        ]

    def writer_wrapper(
        self, fail_subcommand: str, *, after_delegate: bool = False
    ) -> Path:
        wrapper = self.root / f"writer-fail-{fail_subcommand}.py"
        marker = self.root / f"writer-fail-{fail_subcommand}.marker"
        script = f"""\
            #!{sys.executable}
            import os
            import subprocess
            import sys
            from pathlib import Path

            REAL = Path({str(WRITER)!r})
            MARKER = Path({str(marker)!r})
            subcommand = sys.argv[1] if len(sys.argv) > 1 else ""
            if subcommand == {fail_subcommand!r} and not MARKER.exists():
                MARKER.write_text("failed once")
                if {after_delegate!r}:
                    completed = subprocess.run([sys.executable, str(REAL), *sys.argv[1:]], check=False)
                    if "--receipt" in sys.argv:
                        Path(sys.argv[sys.argv.index("--receipt") + 1]).unlink(missing_ok=True)
                    raise SystemExit(41 if completed.returncode == 0 else completed.returncode)
                raise SystemExit(41)
            os.execv(sys.executable, [sys.executable, str(REAL), *sys.argv[1:]])
        """
        wrapper.write_text(textwrap.dedent(script))
        wrapper.chmod(0o755)
        return wrapper


class DrafterSchemaTests(unittest.TestCase):
    def test_drafter_system_prompt_strips_frontmatter_and_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact = root / "drafter.md"
            artifact.write_text("---\nname: test\ntools: Read\n---\n\nBounded body.\n")

            self.assertEqual(MMC.load_drafter_system_prompt(artifact), "Bounded body.")

            linked = root / "linked.md"
            linked.symlink_to(artifact)
            with self.assertRaises(MMC.StateValidationError):
                MMC.load_drafter_system_prompt(linked)

            fifo = root / "fifo.md"
            os.mkfifo(fifo)
            started = time.monotonic()
            with self.assertRaises(MMC.StateValidationError):
                MMC.load_drafter_system_prompt(fifo)
            self.assertLess(time.monotonic() - started, 1)

            malformed = root / "malformed.md"
            malformed.write_text("---\nname: test\nBounded body.\n")
            with self.assertRaises(MMC.StateValidationError):
                MMC.load_drafter_system_prompt(malformed)

    def test_invalid_drafter_artifact_refuses_config_before_state_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            missing = fixture.root / "missing-drafter.md"
            with mock.patch.object(MMC, "DRAFTER_AGENT", missing):
                with self.assertRaises(MMC.StateValidationError):
                    MMC.Config(fixture.environment())
            self.assertFalse(fixture.state.exists())
            self.assertEqual(fixture.call_log(), [])

    def test_schema_is_cross_draft_and_binds_exact_session_set(self):
        expected = ["first-session.jsonl", "second-session.jsonl"]
        schema = MMC.drafter_schema(expected)
        self.assertNotIn("$schema", schema)
        self.assertEqual(schema["type"], "object")
        self.assertFalse(schema["additionalProperties"])
        sessions_schema = schema["properties"]["sessions"]
        self.assertIsInstance(sessions_schema["items"], dict)
        self.assertNotIn("additionalItems", sessions_schema)
        self.assertNotIn("prefixItems", sessions_schema)
        session_schema = sessions_schema["items"]
        self.assertIn("allOf", session_schema)
        self.assertEqual(
            session_schema["properties"]["source_session"]["enum"], expected
        )
        self.assertEqual(
            session_schema["properties"]["notes"]["items"]["properties"][
                "source_session"
            ]["enum"],
            expected,
        )
        self.assertEqual(session_schema["properties"]["reason"]["pattern"], r"\S")
        self.assertEqual(
            [
                clause["contains"]["properties"]["source_session"]["const"]
                for clause in sessions_schema["allOf"]
            ],
            expected,
        )
        bindings = session_schema["allOf"][1:]
        self.assertEqual(
            [
                (
                    clause["if"]["properties"]["source_session"]["const"],
                    clause["then"]["properties"]["notes"]["items"]["properties"][
                        "source_session"
                    ]["const"],
                )
                for clause in bindings
            ],
            [(name, name) for name in expected],
        )
        json.dumps(schema)

    def test_candidate_normalizes_reversed_sessions_before_persistence(self):
        expected = ["first-session.jsonl", "second-session.jsonl"]
        candidate = {
            "schema_version": 1,
            "sessions": [
                {
                    "source_session": "second-session.jsonl",
                    "disposition": "no-durable-knowledge",
                    "reason": "No durable second-session knowledge.",
                    "notes": [],
                },
                {
                    "source_session": "first-session.jsonl",
                    "disposition": "no-durable-knowledge",
                    "reason": "No durable first-session knowledge.",
                    "notes": [],
                },
            ],
        }

        normalized = MMC.validate_candidate(candidate, expected)

        self.assertEqual(
            [item["source_session"] for item in normalized["sessions"]], expected
        )
        self.assertEqual(
            [item["source_session"] for item in candidate["sessions"]],
            list(reversed(expected)),
        )


class ControllerIntegrationTests(unittest.TestCase):
    def test_one_invocation_exact_two_explicit_scope_and_success_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            _project, store = fixture.add_project("alpha", 2)
            _other_project, other_store = fixture.add_project("beta", 4)
            fixture.set_behaviors("success", note_body=NOTE_SENTINEL)

            result = fixture.run("--project", "alpha")

            self.assertEqual(result.returncode, 0, result.stderr)
            calls = fixture.call_log()
            self.assertEqual(len(calls), 1)
            argv = calls[0]["argv"]
            prompt = calls[0]["prompt"]
            self.assertEqual(argv[0], "-p")
            expected_pairs = {
                "--model": "sonnet",
                "--max-turns": "12",
                "--max-budget-usd": "2.00",
                "--output-format": "json",
                "--permission-mode": "dontAsk",
                "--allowedTools": "Read,Grep",
                "--tools": "Read,Grep",
                "--disallowedTools": "Bash,Write,Edit,Agent,Task,Glob",
            }
            for flag, expected in expected_pairs.items():
                self.assertEqual(argv[argv.index(flag) + 1], expected)
            for flag in (
                "--append-system-prompt",
                "--json-schema",
                "--no-session-persistence",
                "--session-id",
            ):
                self.assertIn(flag, argv)
            self.assertNotIn("--agent", argv)
            system_prompt = argv[argv.index("--append-system-prompt") + 1]
            self.assertIn("Use at most six tool calls total", system_prompt)
            self.assertIn("no-durable-knowledge", system_prompt)
            self.assertNotIn("name: memory-mine-drafter", system_prompt)
            schema = json.loads(argv[argv.index("--json-schema") + 1])
            expected_sessions = ["alpha-session-0.jsonl", "alpha-session-1.jsonl"]
            sessions_schema = schema["properties"]["sessions"]
            self.assertIsInstance(sessions_schema["items"], dict)
            self.assertEqual(
                sessions_schema["items"]["properties"]["source_session"]["enum"],
                expected_sessions,
            )
            self.assertEqual(len(sessions_schema["allOf"]), 2)
            self.assertNotIn("/memory-mine", " ".join(argv))
            self.assertNotIn("/memory-mine", prompt)
            self.assertIn("alpha-session-0.jsonl", prompt)
            self.assertIn("alpha-session-1.jsonl", prompt)
            self.assertNotIn("beta-session", prompt)
            self.assertIn("at most six tool calls total", prompt)
            self.assertIn("no-durable-knowledge", prompt)
            self.assertNotIn("SECRET_SENTINEL", calls[0]["env"])
            self.assertEqual(
                calls[0]["env"]["ANTHROPIC_BASE_URL"], "http://localhost:8788"
            )

            self.assertEqual(
                json.loads((store / ".mined-sessions.json").read_text()),
                ["alpha-session-0.jsonl", "alpha-session-1.jsonl"],
            )
            self.assertFalse((other_store / ".mined-sessions.json").exists())
            run = fixture.run_dirs()[0]
            manifest = json.loads((run / "manifest.json").read_text())
            self.assertEqual(len(manifest["sessions"]), 2)
            self.assertEqual(manifest["store"], str(store.resolve()))
            for body_path in (
                run / "inputs",
                run / "claude-result.json",
                run / "candidate.json",
                run / "validated.json",
            ):
                self.assertFalse(body_path.exists(), body_path)
            for retained in (
                "manifest.json",
                "launch.json",
                "apply-receipt.json",
                "final-receipt.json",
            ):
                path = run / retained
                self.assertTrue(path.is_file(), path)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertNotIn(NOTE_SENTINEL, path.read_text())
            final = json.loads((run / "final-receipt.json").read_text())
            self.assertEqual(final["status"], "complete")
            self.assertIsNone(final["failure"])
            self.assertEqual(set(final), MMC.FINAL_KEYS)
            self.assertEqual(final["processed"], 2)
            self.assertEqual(final["ledgered"], 2)
            self.assertNotIn(NOTE_SENTINEL, result.stdout)
            self.assertNotIn(NOTE_SENTINEL, result.stderr)
            for retained in run.iterdir():
                if retained.is_file():
                    self.assertNotIn(NOTE_SENTINEL, retained.read_text())

    def test_completed_terminal_turn_persists_and_resumes_without_redraft(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.set_behaviors("reported_turn_boundary")
            writer = fixture.writer_wrapper("validate")

            first = fixture.run("--project", "alpha", writer=writer)
            run = fixture.run_dirs()[0]
            drafted = json.loads((run / "drafted.json").read_text())
            second = fixture.run("--project", "alpha")
            third = fixture.run("--project", "alpha")

            self.assertNotEqual(first.returncode, 0)
            self.assertEqual(drafted["turns"], MMC.MAX_REPORTED_TURNS)
            self.assertEqual(len(fixture.call_log()), 1)
            argv = fixture.call_log()[0]["argv"]
            self.assertEqual(argv[argv.index("--max-turns") + 1], str(MMC.MAX_TURNS))
            self.assertEqual(second.returncode, 0, second.stderr)
            final = fixture.final_receipts()[0]
            self.assertEqual(final["status"], "complete")
            self.assertEqual(final["turns"], MMC.MAX_REPORTED_TURNS)
            self.assertEqual(third.returncode, 0, third.stderr)
            self.assertIn("no-work", third.stdout)
            self.assertEqual(len(fixture.call_log()), 1)

    def test_reported_turn_overflow_fails_without_ledgering(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            _project, store = fixture.add_project("alpha", 2)
            fixture.set_behaviors("reported_turn_overflow")

            result = fixture.run("--project", "alpha")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("child_output_invalid", result.stderr)
            final = fixture.final_receipts()[0]
            self.assertEqual(final["status"], "failed")
            self.assertEqual(final["turns"], MMC.MAX_REPORTED_TURNS + 1)
            self.assertFalse((store / ".mined-sessions.json").exists())

    def test_nonterminal_boundary_turn_still_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.set_behaviors("nonterminal_boundary")

            result = fixture.run("--project", "alpha")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("child_nonterminal", result.stderr)
            final = fixture.final_receipts()[0]
            self.assertEqual(final["status"], "failed")
            self.assertEqual(final["turns"], MMC.MAX_REPORTED_TURNS)

    def test_scheduled_selection_is_fair_by_attempt_count_staleness_and_slug(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.add_project("beta", 4)
            fixture.add_project("gamma", 4)

            for _ in range(3):
                result = fixture.run("--scheduled")
                self.assertEqual(result.returncode, 0, result.stderr)

            selected = []
            for call in fixture.call_log():
                prompt = call["prompt"]
                selected.append(
                    next(
                        slug
                        for slug in ("alpha", "beta", "gamma")
                        if f"{slug}-session-" in prompt
                    )
                )
            self.assertEqual(selected, ["beta", "gamma", "alpha"])
            self.assertEqual(len(fixture.call_log()), 3)

    def test_scheduled_selection_skips_non_project_root_files(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            (fixture.projects / ".sweep_count.jq").write_text("scratch")
            fixture.add_project("alpha", 2)

            result = fixture.run("--scheduled")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(fixture.call_log()), 1)
            self.assertIn("alpha-session-", fixture.call_log()[0]["prompt"])

    def test_frozen_session_may_exceed_json_state_limit(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 0)
            large = fixture.add_sparse_session(
                "alpha", "large.jsonl", MMC.MAX_STATE_BYTES + 1024
            )
            small = fixture.add_session("alpha", "small.jsonl")

            result = fixture.run("--project", "alpha")

            self.assertEqual(result.returncode, 0, result.stderr)
            prompt = fixture.call_log()[0]["prompt"]
            self.assertIn(large.name, prompt)
            self.assertIn(small.name, prompt)
            self.assertEqual(fixture.final_receipts()[0]["ledgered"], 2)

    def test_scheduled_selection_skips_oversized_session(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 0)
            oversized = fixture.add_sparse_session(
                "alpha",
                "oversized.jsonl",
                MMC.MAX_SESSION_BYTES + 1,
                age_seconds=10800,
            )
            first = fixture.add_session("alpha", "first.jsonl", age_seconds=9000)
            second = fixture.add_session("alpha", "second.jsonl", age_seconds=8000)

            result = fixture.run("--scheduled")

            self.assertEqual(result.returncode, 0, result.stderr)
            prompt = fixture.call_log()[0]["prompt"]
            self.assertNotIn(oversized.name, prompt)
            self.assertIn(first.name, prompt)
            self.assertIn(second.name, prompt)

    def test_scheduled_selection_skips_unsettled_high_count_store(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("active", 0)
            for index in range(5):
                fixture.add_session(
                    "active", f"active-session-{index}.jsonl", age_seconds=0
                )
            fixture.add_project("settled", 2)

            result = fixture.run("--scheduled")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(fixture.call_log()), 1)
            prompt = fixture.call_log()[0]["prompt"]
            self.assertIn("settled-session-", prompt)
            self.assertNotIn("active-session-", prompt)

    def test_settled_filter_returns_no_work_without_claude(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 1)
            fixture.add_session("alpha", "alpha-active.jsonl", age_seconds=0)

            result = fixture.run("--project", "alpha")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("no-work", result.stdout)
            self.assertEqual(fixture.call_log(), [])
            self.assertEqual(fixture.run_dirs(), [])

    def test_explicit_slug_may_begin_with_a_hyphen(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("-home-user-SITES-alpha", 2)

            result = fixture.run("--project", "-home-user-SITES-alpha")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(fixture.call_log()), 1)
            self.assertEqual(
                fixture.final_receipts()[0]["project"], "-home-user-SITES-alpha"
            )

    def test_explicit_workspace_adds_cass_sessions_only_in_manual_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            workspace = fixture.root / "workspace"
            workspace.mkdir()
            first = fixture.add_cass_session("cass-session-a.jsonl")
            second = fixture.add_cass_session("cass-session-b.jsonl")

            result = fixture.run("--project", "alpha", "--workspace", str(workspace))

            self.assertEqual(result.returncode, 0, result.stderr)
            prompt = fixture.call_log()[0]["prompt"]
            self.assertIn(first.name, prompt)
            self.assertIn(second.name, prompt)
            self.assertNotIn("alpha-session", prompt)

            other = ControllerFixture(Path(temp) / "scheduled")
            other.add_project("alpha", 2)
            scheduled_workspace = other.root / "workspace"
            scheduled_workspace.mkdir()
            refused = other.run("--scheduled", "--workspace", str(scheduled_workspace))
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("invalid_workspace", refused.stderr)
            self.assertEqual(other.call_log(), [])

    def test_fourth_iso_week_attempt_does_not_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 8)

            for _ in range(3):
                result = fixture.run("--project", "alpha")
                self.assertEqual(result.returncode, 0, result.stderr)
            fourth = fixture.run("--project", "alpha")

            self.assertEqual(fourth.returncode, 0, fourth.stderr)
            self.assertIn("budget-exhausted", fourth.stdout)
            self.assertEqual(len(fixture.call_log()), 3)
            launches = list((fixture.state / "runs").glob("*/launch.json"))
            self.assertEqual(len(launches), 3)

    def test_selected_run_cannot_bypass_exhausted_weekly_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            project, store = fixture.add_project(
                "alpha", (MMC.MAX_WEEKLY_LAUNCHES + 1) * MMC.BATCH_SIZE
            )
            for _ in range(MMC.MAX_WEEKLY_LAUNCHES):
                result = fixture.run("--project", "alpha")
                self.assertEqual(result.returncode, 0, result.stderr)

            config = MMC.Config(fixture.environment())
            inventory = MMC.inventory_sessions(config, fixture.state, project, store)
            self.assertIsNotNone(inventory)
            run = MMC.create_selected_run(
                config,
                fixture.state / "runs",
                "alpha",
                store,
                MMC.BATCH_SIZE,
                inventory,
            )
            self.assertFalse((run.run_dir / "launch.json").exists())

            blocked = fixture.run("--project", "alpha")

            self.assertEqual(blocked.returncode, 0, blocked.stderr)
            status = json.loads(blocked.stdout)
            self.assertEqual(status["status"], "budget-exhausted")
            self.assertEqual(status["launched_attempts"], MMC.MAX_WEEKLY_LAUNCHES)
            self.assertFalse((run.run_dir / "launch.json").exists())
            self.assertEqual(len(fixture.call_log()), MMC.MAX_WEEKLY_LAUNCHES)

    def test_orphaned_launch_is_interrupted_without_relaunch_and_debits_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.set_behaviors("crash_parent", "success")

            crashed = fixture.run("--project", "alpha")
            self.assertEqual(crashed.returncode, -signal.SIGKILL)
            run = fixture.run_dirs()[0]
            self.assertTrue((run / "launch.json").exists())
            self.assertFalse((run / "claude-result.json").exists())
            child = json.loads((run / "child.json").read_text())
            deadline = time.monotonic() + 2
            while (
                MMC.default_process_probe(child["pid"]).alive
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)

            reconciled = fixture.run("--project", "alpha")

            self.assertNotEqual(reconciled.returncode, 0)
            self.assertEqual(len(fixture.call_log()), 1)
            final = json.loads((run / "final-receipt.json").read_text())
            self.assertEqual(final["status"], "interrupted")
            self.assertEqual(final["failure"], "interrupted_launch")
            self.assertFalse(
                (
                    fixture.projects / "alpha" / "memory" / ".mined-sessions.json"
                ).exists()
            )
            week_id = fixture.now.isocalendar()
            expected_week = f"{week_id.year}-W{week_id.week:02d}"
            self.assertEqual(
                MMC.count_weekly_launches(fixture.state / "runs", expected_week), 1
            )

            fixture.set_behaviors("success")
            second_attempt = fixture.run("--project", "alpha")
            self.assertEqual(second_attempt.returncode, 0, second_attempt.stderr)
            fixture.add_session("alpha", "alpha-session-2.jsonl")
            fixture.add_session("alpha", "alpha-session-3.jsonl")
            third_attempt = fixture.run("--project", "alpha")
            self.assertEqual(third_attempt.returncode, 0, third_attempt.stderr)
            fixture.add_session("alpha", "alpha-session-4.jsonl")
            fixture.add_session("alpha", "alpha-session-5.jsonl")

            budgeted = fixture.run("--project", "alpha")

            self.assertEqual(budgeted.returncode, 0, budgeted.stderr)
            self.assertIn("budget-exhausted", budgeted.stdout)
            self.assertEqual(len(fixture.call_log()), 3)

    def test_live_orphan_child_is_fenced_before_interruption(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.set_behaviors("crash_parent_live")

            crashed = fixture.run("--project", "alpha")
            self.assertEqual(crashed.returncode, -signal.SIGKILL)
            run = fixture.run_dirs()[0]
            child = json.loads((run / "child.json").read_text())

            fenced = fixture.run("--project", "alpha")
            self.assertNotEqual(fenced.returncode, 0)
            self.assertIn("child_still_running", fenced.stderr)
            self.assertFalse((run / "final-receipt.json").exists())
            self.assertEqual(len(fixture.call_log()), 1)

            try:
                os.killpg(child["pid"], signal.SIGKILL)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 2
            while (
                MMC.default_process_probe(child["pid"]).alive
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)

            reconciled = fixture.run("--project", "alpha")
            self.assertNotEqual(reconciled.returncode, 0)
            final = json.loads((run / "final-receipt.json").read_text())
            self.assertEqual(final["status"], "interrupted")
            self.assertEqual(final["failure"], "interrupted_launch")
            self.assertEqual(len(fixture.call_log()), 1)

    def test_outer_and_candidate_failures_are_closed(self):
        cases = {
            "malformed_outer": ("child_output_invalid", None),
            "empty_outer": ("child_output_invalid", None),
            "malformed_result": (
                "candidate_invalid",
                "structured_output_missing",
            ),
            "malformed_structured": (
                "candidate_invalid",
                "structured_output_not_object",
            ),
            "missing_session": ("candidate_invalid", "session_count"),
            "extra_session": ("candidate_invalid", "session_count"),
            "duplicate_session": (
                "candidate_invalid",
                "duplicate_session_source",
            ),
            "wrong_session_set": ("candidate_invalid", "session_set"),
            "whitespace_session": ("candidate_invalid", "session_source"),
            "blank_reason": ("candidate_invalid", "reason"),
            "unhashable_disposition": ("candidate_invalid", "disposition"),
            "nested_source_mismatch": (
                "candidate_invalid",
                "note_source_mismatch",
            ),
            "unhashable_note_type": ("candidate_invalid", "note_type"),
            "wrong_model": ("child_model_mismatch", None),
            "multi_model": ("child_model_mismatch", None),
            "wrong_session": ("child_session_mismatch", None),
            "permission_denial": ("child_permission_denied", None),
            "nonterminal": ("child_nonterminal", None),
        }
        note_behaviors = {"nested_source_mismatch", "unhashable_note_type"}
        for behavior, (failure, failure_detail) in cases.items():
            with self.subTest(behavior=behavior), tempfile.TemporaryDirectory() as temp:
                fixture = ControllerFixture(Path(temp))
                fixture.add_project("alpha", 2)
                fixture.set_behaviors(
                    behavior,
                    note_body=NOTE_SENTINEL if behavior in note_behaviors else None,
                )

                result = fixture.run("--project", "alpha")

                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(fixture.call_log()), 1)
                final = fixture.final_receipts()[0]
                self.assertEqual(final["status"], "failed")
                self.assertEqual(final["failure"], failure)
                self.assertEqual(set(final), MMC.FINAL_KEYS)
                expected_label = (
                    failure if failure_detail is None else f"{failure}:{failure_detail}"
                )
                self.assertIn(expected_label, result.stderr)
                self.assertNotIn(NOTE_SENTINEL, result.stderr)
                self.assertNotIn(NOTE_SENTINEL, json.dumps(final))
                if behavior == "wrong_model":
                    self.assertEqual(final["model"], "claude-opus-5")
                    self.assertEqual(final["turns"], 2)
                elif behavior not in {"malformed_outer", "empty_outer"}:
                    self.assertEqual(final["child_duration_ms"], 120)
                self.assertFalse(
                    (
                        fixture.projects / "alpha" / "memory" / ".mined-sessions.json"
                    ).exists()
                )
                run = fixture.run_dirs()[0]
                for body_path in (
                    run / "inputs",
                    run / "claude-result.json",
                    run / "candidate.json",
                    run / "validated.json",
                ):
                    self.assertFalse(body_path.exists(), body_path)

    def test_reversed_sessions_are_normalized_to_manifest_order(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            _project, store = fixture.add_project("alpha", 2)
            fixture.set_behaviors("reversed_sessions")

            result = fixture.run("--project", "alpha")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(fixture.final_receipts()[0]["status"], "complete")
            self.assertEqual(
                json.loads((store / ".mined-sessions.json").read_text()),
                ["alpha-session-0.jsonl", "alpha-session-1.jsonl"],
            )

    def test_result_only_json_cannot_bypass_requested_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.set_behaviors("result_only", note_body=NOTE_SENTINEL)

            result = fixture.run("--project", "alpha")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("candidate_invalid:structured_output_missing", result.stderr)
            self.assertNotIn(NOTE_SENTINEL, result.stderr)
            final = fixture.final_receipts()[0]
            self.assertEqual(final["status"], "failed")
            self.assertEqual(final["failure"], "candidate_invalid")
            self.assertNotIn(NOTE_SENTINEL, json.dumps(final))
            self.assertFalse(
                (
                    fixture.projects / "alpha" / "memory" / ".mined-sessions.json"
                ).exists()
            )
            run = fixture.run_dirs()[0]
            for body_path in (
                run / "inputs",
                run / "claude-result.json",
                run / "candidate.json",
                run / "validated.json",
            ):
                self.assertFalse(body_path.exists(), body_path)

    def test_timeout_fails_closed_and_kills_the_child_group(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.set_behaviors("timeout")
            started = time.monotonic()

            result = fixture.run("--project", "alpha", timeout="0.1")

            self.assertLess(time.monotonic() - started, 3)
            self.assertNotEqual(result.returncode, 0)
            final = fixture.final_receipts()[0]
            self.assertEqual(final["status"], "failed")
            self.assertEqual(final["failure"], "child_timeout")
            self.assertGreater(final["child_elapsed_ms"], 0)
            self.assertFalse(
                (
                    fixture.projects / "alpha" / "memory" / ".mined-sessions.json"
                ).exists()
            )

    def test_validate_failure_resumes_from_draft_without_another_claude_call(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            writer = fixture.writer_wrapper("validate")

            first = fixture.run("--project", "alpha", writer=writer)
            run = fixture.run_dirs()[0]
            self.assertNotEqual(first.returncode, 0)
            self.assertTrue((run / "drafted.json").exists())
            self.assertFalse((run / "validated-stage.json").exists())
            self.assertFalse((run / "final-receipt.json").exists())

            second = fixture.run("--project", "alpha", writer=writer)

            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(len(fixture.call_log()), 1)
            self.assertEqual(fixture.final_receipts()[0]["status"], "complete")

    def test_uncertain_apply_is_replayed_idempotently_without_redrafting(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            _project, store = fixture.add_project("alpha", 2)
            fixture.set_behaviors("success", note_body=NOTE_SENTINEL)
            writer = fixture.writer_wrapper("apply", after_delegate=True)

            first = fixture.run("--project", "alpha", writer=writer)
            run = fixture.run_dirs()[0]
            self.assertNotEqual(first.returncode, 0)
            self.assertTrue((run / "validated-stage.json").exists())
            self.assertFalse((run / "applied.json").exists())
            self.assertEqual(
                len(json.loads((store / ".mined-sessions.json").read_text())), 2
            )

            second = fixture.run("--project", "alpha", writer=writer)

            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(len(fixture.call_log()), 1)
            receipt = json.loads((run / "apply-receipt.json").read_text())
            self.assertEqual(receipt["processed"], 2)
            self.assertEqual(receipt["ledgered"], 2)
            self.assertEqual(
                len(json.loads((store / ".mined-sessions.json").read_text())), 2
            )
            self.assertTrue((store / "controller-private-fixture.md").is_file())
            index = (store / "MEMORY.md").read_text()
            self.assertEqual(index.count("controller-private-fixture.md"), 1)

    def test_inventory_writer_failure_never_launches(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            writer = fixture.writer_wrapper("inventory")

            result = fixture.run("--project", "alpha", writer=writer)

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(fixture.call_log(), [])
            self.assertEqual(fixture.run_dirs(), [])


class StateSecurityTests(unittest.TestCase):
    def test_wrong_mode_symlink_and_corrupt_state_are_refused_without_rewrite(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            fixture.state.mkdir(mode=0o755)
            fixture.state.chmod(0o755)
            before = fixture.state.stat().st_mode

            wrong_mode = fixture.run("--project", "alpha")

            self.assertNotEqual(wrong_mode.returncode, 0)
            self.assertEqual(fixture.state.stat().st_mode, before)
            self.assertEqual(fixture.call_log(), [])

        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            target = fixture.root / "state-target"
            target.mkdir(mode=0o700)
            fixture.state.symlink_to(target, target_is_directory=True)

            symlinked = fixture.run("--project", "alpha")

            self.assertNotEqual(symlinked.returncode, 0)
            self.assertEqual(list(target.iterdir()), [])
            self.assertTrue(fixture.state.is_symlink())

        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            target = fixture.root / "state-parent-target"
            target.mkdir(mode=0o700)
            linked_parent = fixture.root / "state-parent-link"
            linked_parent.symlink_to(target, target_is_directory=True)
            fixture.state = linked_parent / "nested-state"

            traversed = fixture.run("--project", "alpha")

            self.assertNotEqual(traversed.returncode, 0)
            self.assertEqual(list(target.iterdir()), [])
            self.assertFalse(fixture.state.exists())

        with tempfile.TemporaryDirectory() as temp:
            fixture = ControllerFixture(Path(temp))
            fixture.add_project("alpha", 2)
            runs = fixture.state / "runs"
            run = runs / "corrupt-run"
            run.mkdir(parents=True, mode=0o700)
            fixture.state.chmod(0o700)
            runs.chmod(0o700)
            corrupt = run / "final-receipt.json"
            corrupt.write_bytes(b"{definitely-not-json")
            corrupt.chmod(0o600)
            before = corrupt.read_bytes()

            corrupted = fixture.run("--project", "alpha")

            self.assertNotEqual(corrupted.returncode, 0)
            self.assertEqual(corrupt.read_bytes(), before)
            self.assertEqual(fixture.call_log(), [])

    def test_wrong_owner_check_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private"
            path.mkdir(mode=0o700)
            with mock.patch.object(MMC.os, "geteuid", return_value=os.geteuid() + 1):
                with self.assertRaises(MMC.StateSecurityError):
                    MMC.assert_private_directory(path, "test directory")


if __name__ == "__main__":
    unittest.main()
