#!/usr/bin/env python3
"""Behavior-preservation tests for config override coercion."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from memory_dream import config


class ConfigOverrideTests(unittest.TestCase):
    def test_environment_scalar_override_keeps_default_type(self):
        with (
            mock.patch.object(config, "_OVERRIDABLE", {"TRIAGE_BODY_BYTES"}),
            mock.patch.object(config, "TRIAGE_BODY_BYTES", 6000),
            mock.patch.dict(
                os.environ, {"MEMORY_DREAM_TRIAGE_BODY_BYTES": "1234"}, clear=False
            ),
        ):
            config._apply_env_overrides()
            self.assertEqual(config.TRIAGE_BODY_BYTES, 1234)
            self.assertIs(type(config.TRIAGE_BODY_BYTES), int)

    def test_environment_list_override_remains_json_decoded(self):
        with (
            mock.patch.object(config, "_OVERRIDABLE", {"SENSITIVE_PATTERNS_EXTRA"}),
            mock.patch.object(config, "SENSITIVE_PATTERNS_EXTRA", []),
            mock.patch.dict(
                os.environ,
                {"MEMORY_DREAM_SENSITIVE_PATTERNS_EXTRA": '["secret", "token"]'},
                clear=False,
            ),
        ):
            config._apply_env_overrides()
            self.assertEqual(config.SENSITIVE_PATTERNS_EXTRA, ["secret", "token"])

    def test_file_list_override_remains_a_copy_of_decoded_value(self):
        supplied = ["secret", "token"]
        with (
            mock.patch.object(config, "_FILE_CONFIG_LOADED", False),
            mock.patch.object(config, "_OVERRIDABLE", {"SENSITIVE_PATTERNS_EXTRA"}),
            mock.patch.object(config, "SENSITIVE_PATTERNS_EXTRA", []),
            mock.patch.object(
                config,
                "_file_config",
                return_value={"sensitive_patterns_extra": supplied},
            ),
            mock.patch.object(config, "_apply_env_overrides"),
        ):
            config.load_file_config()
            self.assertEqual(config.SENSITIVE_PATTERNS_EXTRA, supplied)
            self.assertIsNot(config.SENSITIVE_PATTERNS_EXTRA, supplied)

    def test_invalid_environment_override_keeps_source_specific_diagnostic(self):
        with (
            mock.patch.object(config, "_OVERRIDABLE", {"TRIAGE_BODY_BYTES"}),
            mock.patch.object(config, "TRIAGE_BODY_BYTES", 6000),
            mock.patch.dict(
                os.environ,
                {"MEMORY_DREAM_TRIAGE_BODY_BYTES": "not-an-int"},
                clear=False,
            ),
        ):
            with self.assertRaisesRegex(
                SystemExit,
                r"^env var MEMORY_DREAM_TRIAGE_BODY_BYTES: expected int:",
            ):
                config._apply_env_overrides()

    def test_invalid_file_override_keeps_source_specific_diagnostic(self):
        with (
            mock.patch.object(config, "_FILE_CONFIG_LOADED", False),
            mock.patch.object(config, "_OVERRIDABLE", {"TRIAGE_BODY_BYTES"}),
            mock.patch.object(config, "TRIAGE_BODY_BYTES", 6000),
            mock.patch.object(
                config, "_file_config", return_value={"triage_body_bytes": "not-an-int"}
            ),
            mock.patch.object(config, "_apply_env_overrides"),
        ):
            with self.assertRaisesRegex(
                SystemExit, r"^config key triage_body_bytes: expected int:"
            ):
                config.load_file_config()


class PreviewOpenerConfigTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.config_path = Path(temporary.name) / "memory-dream.json"
        patches = (
            mock.patch.dict(
                os.environ, {"CLAUDE_CONFIG_DIR": temporary.name}, clear=True
            ),
            mock.patch.object(config, "_FILE_CONFIG_LOADED", False),
            mock.patch.object(config, "_OVERRIDABLE", set()),
            mock.patch.object(config, "PREVIEW_OPENER", None),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write_config(self, data):
        self.config_path.write_text(json.dumps(data), encoding="utf-8")

    def test_defaults_to_none_without_configuration(self):
        config.load_file_config()
        self.assertIsNone(config.PREVIEW_OPENER)

    def test_file_config_recognizes_preview_opener(self):
        self.write_config(
            {"preview_opener": 'browser-wrapper --profile "review profile"'}
        )
        config.load_file_config()
        self.assertEqual(
            config.PREVIEW_OPENER, 'browser-wrapper --profile "review profile"'
        )

    def test_environment_overrides_file_opener(self):
        self.write_config({"preview_opener": "file-opener"})
        os.environ["MEMORY_DREAM_PREVIEW_OPENER"] = "env-opener --wait"
        config.load_file_config()
        self.assertEqual(config.PREVIEW_OPENER, "env-opener --wait")

    def test_environment_opener_needs_no_file(self):
        os.environ["MEMORY_DREAM_PREVIEW_OPENER"] = "env-opener"
        config.load_file_config()
        self.assertEqual(config.PREVIEW_OPENER, "env-opener")

    def test_null_file_opener_keeps_builtin_default(self):
        self.write_config({"preview_opener": None})
        config.load_file_config()
        self.assertIsNone(config.PREVIEW_OPENER)

    def test_non_string_opener_is_rejected(self):
        self.write_config({"preview_opener": ["browser-wrapper"]})
        with self.assertRaisesRegex(
            SystemExit, "config key preview_opener: expected str or null"
        ):
            config.load_file_config()

    def test_unknown_key_diagnostic_lists_preview_opener(self):
        self.write_config({"preview_opner": "browser-wrapper"})
        with self.assertRaises(SystemExit) as raised:
            config.load_file_config()
        message = str(raised.exception)
        self.assertIn("unknown config key(s)", message)
        self.assertIn("preview_opner", message)
        self.assertIn("valid: mirror_root, mirror_push_hint, preview_opener", message)


class ScratchDirTests(unittest.TestCase):
    """The scratch folder holds note bodies, so it must be owner-only."""

    def setUp(self):
        self._root = tempfile.TemporaryDirectory()
        self.root = Path(self._root.name)
        env = mock.patch.dict(os.environ, {}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("MEMORY_DREAM_SCRATCH", None)
        os.environ.pop("CLAUDE_JOB_DIR", None)
        # gettempdir() caches, so point tempfile itself at the throwaway root.
        temp_root = mock.patch.object(tempfile, "tempdir", str(self.root))
        temp_root.start()
        self.addCleanup(temp_root.stop)
        if hasattr(config, "_scratch_fallback"):
            fallback = mock.patch.object(config, "_scratch_fallback", None)
            fallback.start()
            self.addCleanup(fallback.stop)
        self.addCleanup(self._root.cleanup)

    def _mode(self, path: Path) -> int:
        return path.stat().st_mode & 0o777

    def test_fallback_is_a_fresh_unpredictable_folder(self):
        scratch = config.scratch_dir()
        self.assertTrue(scratch.is_dir())
        self.assertEqual(scratch.parent, self.root)
        self.assertTrue(scratch.name.startswith("memory-dream-"))
        self.assertNotEqual(scratch.name, f"memory-dream-{os.getpid()}")

    @unittest.skipUnless(os.name == "posix", "POSIX modes")
    def test_fallback_is_owner_only(self):
        self.assertEqual(self._mode(config.scratch_dir()), 0o700)

    def test_fallback_never_reuses_a_precreated_pid_folder(self):
        planted = self.root / f"memory-dream-{os.getpid()}"
        planted.mkdir()
        (planted / "planted.txt").write_text("someone else's", encoding="utf-8")
        scratch = config.scratch_dir()
        self.assertNotEqual(scratch, planted)
        self.assertEqual(list(scratch.iterdir()), [])

    def test_fallback_is_stable_within_one_process(self):
        self.assertEqual(config.scratch_dir(), config.scratch_dir())

    @unittest.skipUnless(os.name == "posix", "POSIX modes")
    def test_env_scratch_is_honored_and_tightened_when_owned(self):
        chosen = self.root / "chosen"
        chosen.mkdir()
        os.chmod(chosen, 0o755)
        os.environ["MEMORY_DREAM_SCRATCH"] = str(chosen)
        self.assertEqual(config.scratch_dir(), chosen)
        self.assertEqual(self._mode(chosen), 0o700)

    @unittest.skipUnless(os.name == "posix", "POSIX modes")
    def test_job_dir_scratch_is_honored_and_tightened(self):
        job_tmp = self.root / "job" / "tmp"
        job_tmp.mkdir(parents=True)
        os.chmod(job_tmp, 0o755)
        os.environ["CLAUDE_JOB_DIR"] = str(self.root / "job")
        self.assertEqual(config.scratch_dir(), job_tmp)
        self.assertEqual(self._mode(job_tmp), 0o700)

    @unittest.skipUnless(os.name == "posix", "POSIX modes")
    def test_env_scratch_owned_by_someone_else_is_left_alone(self):
        shared = self.root / "shared"
        shared.mkdir()
        os.chmod(shared, 0o755)
        os.environ["MEMORY_DREAM_SCRATCH"] = str(shared)
        with mock.patch.object(os, "geteuid", return_value=os.geteuid() + 1):
            self.assertEqual(config.scratch_dir(), shared)
        self.assertEqual(self._mode(shared), 0o755)


if __name__ == "__main__":
    unittest.main()
