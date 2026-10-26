#!/usr/bin/env python3
"""Hermetic synthetic compressed rollouts; optional pinned real-reader parity."""

import errno
import fcntl
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "bin/codex-zst-bridge"
STAMP = "2026-09-28T00:30:00.000Z"
BODY = "PRIVATE MESSAGE TOOL INSTRUCTION BODY"


def fixture(tokens=100):
    return [
        {
            "type": "session_meta",
            "timestamp": STAMP,
            "payload": {
                "id": "11111111-1111-4111-8111-111111111111",
                "timestamp": STAMP,
                "cwd": "/synthetic",
                "originator": "codex_cli_rs",
                "cli_version": "0.100.0",
                "source": "cli",
                "model_provider": "openai",
                "instructions": BODY,
            },
        },
        {
            "type": "turn_context",
            "timestamp": STAMP,
            "payload": {
                "turn_id": "turn",
                "model": "gpt-5",
                "cwd": "/synthetic",
                "timestamp": STAMP,
                "instructions": BODY,
            },
        },
        {"type": "response_item", "payload": {"type": "message", "content": BODY}},
        {"type": "event_msg", "payload": {"type": "agent_message", "message": BODY}},
        {
            "type": "event_msg",
            "timestamp": STAMP,
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 20,
                        "output_tokens": 30,
                        "reasoning_output_tokens": 10,
                        "total_tokens": tokens + 30,
                    },
                    "last_token_usage": {
                        "input_tokens": tokens,
                        "cached_input_tokens": 20,
                        "output_tokens": 30,
                        "reasoning_output_tokens": 10,
                        "total_tokens": tokens + 30,
                    },
                    "model_context_window": 200000,
                },
                "rate_limits": None,
            },
        },
    ]


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("zstd"):
            raise RuntimeError("zstd is required: compressed fixture tests must run")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="codex-zst-test-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.source = self.home / "source"
        self.state = self.home / "state"
        self.out = self.state / "codex"
        self.env = {
            "HOME": str(self.home),
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "TZ": "UTC",
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "HTTP_PROXY": "http://127.0.0.1:9",
            "HTTPS_PROXY": "http://127.0.0.1:9",
            "ALL_PROXY": "http://127.0.0.1:9",
            "NO_PROXY": "",
        }

    def compressed(
        self,
        rows=None,
        home=None,
        rel="sessions/2026/rollout-fixture.jsonl.zst",
        bad=False,
    ):
        path = (home or self.source) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        data = "".join(
            json.dumps(row, separators=(",", ":")) + "\n" for row in (rows or fixture())
        )
        if bad:
            data += "{broken json\n"
        result = subprocess.run(
            ["zstd", "-q", "-c"], input=data.encode(), capture_output=True, check=True
        )
        path.write_bytes(result.stdout)
        return path

    def run_bridge(self, *homes, success=True):
        args = [sys.executable, str(SCRIPT), "--state-dir", str(self.state)]
        for home in homes or (self.source,):
            args += ["--codex-home", str(home)]
        result = subprocess.run(
            args, env=self.env, capture_output=True, text=True, timeout=20
        )
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        self.last_stderr = result.stderr
        return json.loads(result.stdout) if success else result

    def test_projection_only_metadata_and_bad_lines(self):
        source = self.compressed(bad=True)
        before = source.read_bytes()
        stats = self.run_bridge()
        files = list(self.out.rglob("*.jsonl"))
        self.assertEqual(len(files), 1)
        text = files[0].read_text()
        rows = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(
            [row["type"] for row in rows], ["session_meta", "turn_context", "event_msg"]
        )
        self.assertEqual(
            set(rows[0]["payload"]), set(fixture()[0]["payload"]) - {"instructions"}
        )
        self.assertEqual(
            set(rows[1]["payload"]), {"turn_id", "model", "cwd", "timestamp"}
        )
        self.assertEqual(rows[2], fixture()[-1])
        self.assertNotIn(BODY, text)
        self.assertEqual(stats["badLines"], 1)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(files[0].stat().st_mtime_ns, source.stat().st_mtime_ns)
        self.assertEqual(
            files[0].stat().st_ino,
            next((self.state / "objects").glob("*.jsonl")).stat().st_ino,
        )

    def test_plain_twin_in_either_leaf_is_skipped(self):
        self.compressed()
        twin = self.source / "archived_sessions/rollout-fixture.jsonl"
        twin.parent.mkdir(parents=True)
        twin.write_text("native")
        stats = self.run_bridge()
        self.assertEqual(stats["twinSkipped"], 1)
        self.assertEqual(list(self.out.rglob("*.jsonl")), [])

    def test_merges_homes_and_preserves_both_leaf_relative_paths(self):
        self.compressed()
        other = self.home / "other"
        self.compressed(
            fixture(200), home=other, rel="archived_sessions/rollout-archive.jsonl.zst"
        )
        stats = self.run_bridge(self.source, other)
        self.assertEqual((stats["sources"], stats["projected"]), (2, 2))
        self.assertEqual(
            {p.relative_to(self.out).as_posix() for p in self.out.rglob("*.jsonl")},
            {
                "sessions/2026/rollout-fixture.jsonl",
                "archived_sessions/rollout-archive.jsonl",
            },
        )

    def test_incremental_reuse_never_invokes_zstd(self):
        self.compressed()
        first = self.run_bridge()
        shim = self.home / "shim"
        shim.mkdir()
        command = shim / "zstd"
        command.write_text('#!/bin/sh\necho invoked >> "$HOME/zstd-invoked"\nexit 97\n')
        command.chmod(0o755)
        self.env["PATH"] = str(shim) + ":" + self.env["PATH"]
        second = self.run_bridge()
        self.assertEqual(second["generation"], first["generation"])
        self.assertEqual((second["reused"], second["projected"]), (1, 0))
        self.assertFalse((self.home / "zstd-invoked").exists())

    def test_unchanged_projection_refreshes_source_mtime_without_new_generation(self):
        source = self.compressed()
        first = self.run_bridge()["generation"]
        rows = fixture()
        rows[2]["payload"]["content"] = BODY + " changed"
        self.compressed(rows)
        stamp = source.stat().st_mtime_ns + 1_000_000_000
        os.utime(source, ns=(stamp, stamp))
        second = self.run_bridge()
        self.assertEqual(second["generation"], first)
        self.assertEqual(second["projected"], 1)
        self.assertEqual(
            next((self.state / "objects").glob("*.jsonl")).stat().st_mtime_ns, stamp
        )

    def test_rotation_keeps_previous_and_prunes_old_objects(self):
        ids = []
        for tokens in (100, 200, 300):
            self.compressed(fixture(tokens))
            ids.append(self.run_bridge()["generation"])
        self.assertEqual(len(set(ids)), 3)
        self.assertEqual(
            {p.name for p in (self.state / "generations").iterdir()}, set(ids[-2:])
        )
        self.assertEqual(len(list((self.state / "objects").glob("*.jsonl"))), 2)
        self.assertEqual(self.run_bridge()["generation"], ids[-1])
        # Repeated runs must retain the immediately previous distinct generation.
        self.assertTrue((self.state / "generations" / ids[-2]).exists())

    def test_pruning_waits_for_active_readers(self):
        self.compressed(fixture(100))
        ids = [self.run_bridge()["generation"]]
        pinned = self.state / "generations" / ids[0]
        expected = next(pinned.rglob("*.jsonl")).read_text()
        # A reader pinned to A while exports publish B and C keeps A intact.
        with open(self.state / ".readers.lock") as reader:
            fcntl.flock(reader, fcntl.LOCK_SH)
            for tokens in (200, 300):
                self.compressed(fixture(tokens))
                ids.append(self.run_bridge()["generation"])
                self.assertIn("deferred while a reader is active", self.last_stderr)
            self.assertEqual(len(set(ids)), 3)
            self.assertEqual(self.out.resolve().name, ids[-1])
            self.assertEqual(next(pinned.rglob("*.jsonl")).read_text(), expected)
        self.assertEqual(self.run_bridge()["generation"], ids[-1])
        self.assertNotIn("deferred", self.last_stderr)
        self.assertEqual(
            {p.name for p in (self.state / "generations").iterdir()}, set(ids[-2:])
        )
        self.assertEqual(len(list((self.state / "objects").glob("*.jsonl"))), 2)

    def test_malformed_lines_name_the_rollout_on_every_export(self):
        self.compressed(bad=True)
        message = "skipped 1 malformed line(s) in sessions/2026/rollout-fixture.jsonl"
        self.assertEqual(self.run_bridge()["badLines"], 1)
        self.assertIn(message, self.last_stderr)
        stats = self.run_bridge()
        self.assertEqual((stats["reused"], stats["badLines"]), (1, 1))
        self.assertIn(message, self.last_stderr)
        self.compressed()
        self.assertEqual(self.run_bridge()["badLines"], 0)
        self.assertNotIn("malformed", self.last_stderr)

    def load_bridge(self):
        loader = importlib.machinery.SourceFileLoader("zst_bridge_test", str(SCRIPT))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module

    def test_failed_atomic_swap_preserves_current_and_its_predecessor(self):
        ids = []
        for tokens in (100, 200):
            self.compressed(fixture(tokens))
            ids.append(self.run_bridge()["generation"])
        self.compressed(fixture(300))
        bridge = self.load_bridge()
        replace = bridge.os.replace

        def fail_swap(source, destination):
            if Path(destination) == self.out:
                raise OSError(errno.EIO, "synthetic publication failure")
            return replace(source, destination)

        with patch.object(bridge.os, "replace", side_effect=fail_swap):
            with self.assertRaises(OSError):
                bridge.export([self.source], self.state)
        self.assertEqual(self.out.resolve().name, ids[-1])
        self.compressed(fixture(200))
        self.assertEqual(self.run_bridge()["generation"], ids[-1])
        self.assertEqual(
            {p.name for p in (self.state / "generations").iterdir()}, set(ids)
        )

    def test_hardlink_fallback_only_for_exdev_and_eperm(self):
        self.compressed()
        bridge = self.load_bridge()
        for error in (errno.EXDEV, errno.EPERM):
            state = self.home / str(error)
            with patch.object(
                bridge.os, "link", side_effect=OSError(error, "synthetic")
            ):
                bridge.export([self.source], state)
            output = next((state / "codex").rglob("*.jsonl"))
            obj = next((state / "objects").glob("*.jsonl"))
            self.assertEqual(output.read_bytes(), obj.read_bytes())
            self.assertNotEqual(output.stat().st_ino, obj.stat().st_ino)
        first = self.run_bridge()["generation"]
        self.compressed(fixture(200))
        with patch.object(
            bridge.os, "link", side_effect=OSError(errno.EIO, "synthetic")
        ):
            with self.assertRaises(OSError):
                bridge.export([self.source], self.state)
        self.assertEqual(self.out.resolve().name, first)

    def test_symlinked_owned_child_paths_refused(self):
        self.compressed()
        for name in (
            "generations",
            "objects",
            ".export.lock",
            "index.json",
            "previous.json",
        ):
            with self.subTest(name=name):
                self.state.mkdir(exist_ok=True)
                outside = self.home / ("outside-" + name)
                outside.mkdir()
                path = self.state / name
                path.symlink_to(outside, target_is_directory=True)
                self.run_bridge(success=False)
                self.assertEqual(list(outside.iterdir()), [])
                path.unlink()

    def test_old_corruption_preserves_previous_and_fresh_corruption_is_in_flight(self):
        source = self.compressed()
        first = self.run_bridge()
        source.write_bytes(b"corrupt " + BODY.encode())
        old = time.time() - 901
        os.utime(source, (old, old))
        result = self.run_bridge(success=False)
        self.assertIn("previous export preserved", result.stderr)
        self.assertNotIn(BODY, result.stderr)
        self.assertEqual(self.out.resolve().name, first["generation"])
        os.utime(source, None)
        fresh = self.run_bridge()
        self.assertEqual(fresh["inFlightSkipped"], 1)
        self.assertEqual(list(self.out.rglob("*.jsonl")), [])

    def test_symlinked_state_refused(self):
        actual = self.home / "actual"
        actual.mkdir()
        self.state.symlink_to(actual, target_is_directory=True)
        self.compressed()
        self.run_bridge(success=False)
        self.assertEqual(list(actual.iterdir()), [])

    def test_cross_home_collision_preserves_previous(self):
        self.compressed()
        previous = self.run_bridge()["generation"]
        other = self.home / "other"
        self.compressed(fixture(200), home=other)
        result = self.run_bridge(self.source, other, success=False)
        self.assertIn("conflicting cross-home", result.stderr)
        self.assertEqual(self.out.resolve().name, previous)
        self.compressed(home=other)
        self.run_bridge(self.source, other)
        self.assertEqual(len(list(self.out.rglob("*.jsonl"))), 1)

    def test_no_sources_and_disappearing_sources(self):
        self.assertIsNone(self.run_bridge()["generation"])
        self.assertFalse(self.out.exists())
        source = self.compressed()
        self.run_bridge()
        source.unlink()
        self.assertIsNotNone(self.run_bridge()["generation"])
        self.assertEqual(list(self.out.rglob("*.jsonl")), [])

    def test_missing_zstd_fails_with_sources_even_if_cached(self):
        self.compressed()
        first = self.run_bridge()["generation"]
        self.env["PATH"] = str(self.home / "no-commands")
        self.run_bridge(success=False)
        self.assertEqual(self.out.resolve().name, first)

    @unittest.skipUnless(
        os.environ.get("CODEX_ZST_CCUSAGE_BIN"),
        "SKIP real-reader parity: set CODEX_ZST_CCUSAGE_BIN",
    )
    def test_real_reader_parity(self):
        binary = os.environ["CODEX_ZST_CCUSAGE_BIN"]
        version = subprocess.run(
            [binary, "--version"],
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(version.stdout.strip().removeprefix("ccusage "), "20.0.19")
        source = self.compressed()
        self.run_bridge()
        plain = self.home / "decompressed/sessions/2026/rollout-fixture.jsonl"
        plain.parent.mkdir(parents=True)
        data = subprocess.run(
            ["zstd", "-q", "-dc", "--", str(source)], capture_output=True, check=True
        )
        plain.write_bytes(data.stdout)
        totals = []
        for root in (self.out.resolve(), self.home / "decompressed"):
            result = subprocess.run(
                [binary, "codex", "daily", "--json", "--offline", "--no-cost"],
                env=self.env | {"CODEX_HOME": str(root)},
                capture_output=True,
                text=True,
                timeout=45,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            totals.append(json.loads(result.stdout)["totals"])
        self.assertEqual(totals[0], totals[1])
        self.assertEqual(totals[0]["totalTokens"], 130)
        print(
            "PASS real-reader parity: ccusage 20.0.19 projection == fully decompressed fixture (130 tokens)"
        )


if __name__ == "__main__":
    if not os.environ.get("CODEX_ZST_CCUSAGE_BIN"):
        print("SKIP real-reader parity: CODEX_ZST_CCUSAGE_BIN is unset", flush=True)
    unittest.main()
