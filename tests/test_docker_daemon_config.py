#!/usr/bin/env python3
"""Hermetic contract tests for Docker daemon init policy adoption."""

from __future__ import annotations

import fcntl
import hashlib
import io
import json
import os
import runpy
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import cast
from unittest.mock import patch as mock_patch

CLAUDE_ROOT = Path(__file__).resolve().parents[1]
HELPER = CLAUDE_ROOT / "scripts" / "docker-daemon-config.py"
# The local run at 07a5c4ce joined the first adopter for 5s. The child was
# still inside dockerd --validate, and executor shutdown then waited out the
# helper's 30s kill (suite 39.3s vs 7.3s idle). Join for longer than that
# stall, and give the helper the same deadline so it does not kill the gate.
SIBLING_ADOPTER_JOIN_SECONDS = 120.0


class DockerDaemonConfigCliTests(unittest.TestCase):
    @staticmethod
    def sha256(value: bytes) -> str:
        return hashlib.sha256(value).hexdigest()

    def setUp(self) -> None:
        # The helper refuses group- or world-writable parents, so the fixture
        # tree must not inherit the caller's umask (0002 is common under WSL).
        # Registered before any allocation so a failed setUp still restores it.
        previous_umask = os.umask(0o022)
        self.addCleanup(os.umask, previous_umask)
        self.tempdir = tempfile.TemporaryDirectory(prefix="docker-daemon-config-")
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.target = self.root / "etc" / "docker" / "daemon.json"
        self.state = self.root / "var" / "lib" / "dotfiles" / "docker-init-adoption.json"
        self.backup = self.root / "var" / "lib" / "dotfiles" / "docker-init-adoption.original"
        self.lock = self.root / "etc" / "docker" / ".daemon.json.dotfiles.lock"
        self.patch = self.root / "repo" / "docker-daemon.patch.json"
        self.dockerd = self.root / "bin" / "dockerd"
        self.validation_log = self.root / "dockerd-validation.log"
        self.validated_config = self.root / "validated-daemon.json"
        self.target.parent.mkdir(parents=True)
        self.patch.parent.mkdir(parents=True)
        self.dockerd.parent.mkdir(parents=True)
        self.patch.write_text('{"init": true}\n', encoding="utf-8")
        self.dockerd.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "[ \"$1\" = --validate ]\n"
            "[ \"$2\" = --config-file ]\n"
            "printf '%s\\n' \"$*\" >>\"$DOCKER_VALIDATE_LOG\"\n"
            "cp \"$3\" \"$DOCKER_VALIDATED_CONFIG\"\n"
            "validation_count=$(wc -l <\"$DOCKER_VALIDATE_LOG\")\n"
            "if [ -n \"${DOCKER_CHMOD_PARENT_ON_VALIDATE:-}\" ] && "
            "[ \"$validation_count\" -eq \"$DOCKER_CHMOD_PARENT_ON_VALIDATE\" ]; then\n"
            "  chmod 500 \"$DOCKER_TARGET_PARENT\"\n"
            "fi\n"
            "if [ -n \"${DOCKER_VALIDATE_READY:-}\" ]; then\n"
            "  : >\"$DOCKER_VALIDATE_READY\"\n"
            "  while [ ! -e \"$DOCKER_VALIDATE_RELEASE\" ]; do sleep 0.01; done\n"
            "fi\n"
            "if [ -n \"${DOCKER_VALIDATE_HOLD_SECONDS:-}\" ]; then\n"
            "  sleep \"$DOCKER_VALIDATE_HOLD_SECONDS\"\n"
            "fi\n"
            "if [ -n \"${DOCKER_VALIDATE_SLEEP_ONCE:-}\" ] && "
            "[ ! -e \"$DOCKER_VALIDATE_SLEEP_ONCE\" ]; then\n"
            "  : >\"$DOCKER_VALIDATE_SLEEP_ONCE\"\n"
            "  exec sleep \"${DOCKER_VALIDATE_SLEEP_SECONDS:-1}\"\n"
            "fi\n"
            "if [ -n \"${DOCKER_MUTATE_TARGET:-}\" ]; then\n"
            "  printf '%s\\n' '{\"external-writer\":true}' >\"$DOCKER_MUTATE_TARGET\"\n"
            "fi\n"
            "exit \"${DOCKER_VALIDATE_EXIT:-0}\"\n",
            encoding="utf-8",
        )
        self.dockerd.chmod(0o755)

    def run_helper(
        self,
        command: str,
        *extra: str,
        profile: str = "workstation",
        env: dict[str, str] | None = None,
        include_test_root: bool = True,
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command_env = os.environ.copy()
        command_env.update(
            {
                "DOCKER_VALIDATE_LOG": str(self.validation_log),
                "DOCKER_VALIDATED_CONFIG": str(self.validated_config),
            }
        )
        if env:
            command_env.update(env)
        argv = [
            sys.executable,
            str(HELPER),
            command,
            "--profile",
            profile,
            "--patch",
            str(self.patch),
            "--target",
            str(self.target),
            "--state",
            str(self.state),
            "--backup",
            str(self.backup),
            "--lock",
            str(self.lock),
            "--dockerd",
            str(self.dockerd),
        ]
        if include_test_root:
            argv.extend(("--test-root", str(self.root)))
        argv.extend(extra)
        return subprocess.run(
            argv,
            text=True,
            capture_output=True,
            env=command_env,
            check=False,
            timeout=timeout,
        )

    def test_routine_reconcile_validates_but_does_not_first_publish(self) -> None:
        original = b'{\n  "log-driver": "local",\n  "unknown-option": {"keep": true}\n}\n'
        self.target.write_bytes(original)

        result = self.run_helper("reconcile")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pending adoption", result.stdout)
        self.assertIn("runtime not verified", result.stdout)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.validation_log.read_text(encoding="utf-8").count("--validate"), 1)
        candidate = json.loads(self.validated_config.read_text(encoding="utf-8"))
        self.assertTrue(candidate["init"])
        self.assertEqual(candidate["unknown-option"], {"keep": True})

    def test_explicit_adoption_preserves_unknown_settings_metadata_and_baseline(self) -> None:
        original = (
            b'{"log-driver":"local","log-opts":{"max-size":"10m"},'
            b'"default-address-pools":[{"base":"172.80.0.0/16","size":24}],'
            b'"default-ulimits":{"nofile":{"Name":"nofile","Hard":64000,"Soft":64000}},'
            b'"future-option":{"keep":true}}\n'
        )
        self.target.write_bytes(original)
        self.target.chmod(0o640)
        original_stat = self.target.stat()

        adopted = self.run_helper("adopt")

        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        self.assertIn("adopted", adopted.stdout)
        self.assertIn("runtime not verified", adopted.stdout)
        live = json.loads(self.target.read_text(encoding="utf-8"))
        self.assertIs(live["init"], True)
        self.assertEqual(live["log-opts"], {"max-size": "10m"})
        self.assertEqual(live["default-address-pools"], [{"base": "172.80.0.0/16", "size": 24}])
        self.assertEqual(live["default-ulimits"]["nofile"]["Hard"], 64000)
        self.assertEqual(live["future-option"], {"keep": True})
        adopted_stat = self.target.stat()
        self.assertEqual(stat.S_IMODE(adopted_stat.st_mode), 0o640)
        self.assertEqual((adopted_stat.st_uid, adopted_stat.st_gid), (original_stat.st_uid, original_stat.st_gid))
        self.assertEqual(self.backup.read_bytes(), original)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(state["phase"], "adopted")
        self.assertTrue(state["original_file_existed"])
        self.assertFalse(state["prior_init_present"])
        self.assertEqual(state["managed_init_value"], True)
        self.assertEqual(state["expected_target"]["content_sha256"], self.sha256(self.target.read_bytes()))
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o600)

        target_after_adopt = self.target.read_bytes()
        state_after_adopt = self.state.read_bytes()
        backup_after_adopt = self.backup.read_bytes()
        reconciled = self.run_helper("reconcile")
        self.assertEqual(reconciled.returncode, 0, reconciled.stderr)
        self.assertIn("desired config present", reconciled.stdout)
        self.assertEqual(self.target.read_bytes(), target_after_adopt)
        self.assertEqual(self.state.read_bytes(), state_after_adopt)
        self.assertEqual(self.backup.read_bytes(), backup_after_adopt)

    def test_explicit_false_requires_scoped_adoption_approval(self) -> None:
        original = b'{"init":false,"unknown-option":"preserve"}\n'
        self.target.write_bytes(original)

        refused = self.run_helper("adopt")

        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("ownership conflict", refused.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

        approved = self.run_helper("adopt", "--allow-existing-false")

        self.assertEqual(approved.returncode, 0, approved.stderr)
        self.assertEqual(json.loads(self.target.read_text(encoding="utf-8")), {"init": True, "unknown-option": "preserve"})
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertTrue(state["prior_init_present"])
        self.assertIs(state["prior_init_value"], False)
        self.assertEqual(self.backup.read_bytes(), original)

    def test_rollback_restores_approved_prior_false_and_preserves_later_unowned_keys(self) -> None:
        original = b'{"init":false,"unknown-option":"baseline"}\n'
        self.target.write_bytes(original)
        adopted = self.run_helper("adopt", "--allow-existing-false")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)

        live = json.loads(self.target.read_text(encoding="utf-8"))
        live["added-after-adoption"] = {"preserve": True}
        self.target.write_text(json.dumps(live) + "\n", encoding="utf-8")

        rolled_back = self.run_helper("rollback")

        self.assertEqual(rolled_back.returncode, 0, rolled_back.stderr)
        self.assertEqual(
            json.loads(self.target.read_text(encoding="utf-8")),
            {
                "init": False,
                "unknown-option": "baseline",
                "added-after-adoption": {"preserve": True},
            },
        )
        self.assertEqual(self.backup.read_bytes(), original)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rolled_back")

    def test_invalid_json_shapes_and_patch_scope_leave_target_untouched(self) -> None:
        cases = (
            ("malformed", b'{"log-driver":', b'{"init":true}\n', "invalid JSON in"),
            (
                "duplicate-key",
                b'{"log-driver":"local","log-driver":"json-file"}\n',
                b'{"init":true}\n',
                "duplicate JSON key 'log-driver'",
            ),
            ("non-object", b'["log-driver"]\n', b'{"init":true}\n', "JSON root must be an object"),
            (
                "invalid-init-type",
                b'{"init":"true","future-option":1}\n',
                b'{"init":true}\n',
                "existing Docker init value must be boolean",
            ),
            (
                "unsupported-policy-key",
                b'{"future-option":1}\n',
                b'{"init":true,"live-restore":true}\n',
                "policy patch must contain only boolean init=true",
            ),
        )
        for name, original, patch, diagnostic in cases:
            with self.subTest(name=name):
                self.target.write_bytes(original)
                self.patch.write_bytes(patch)

                result = self.run_helper("adopt")

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR", result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(self.target.read_bytes(), original)
                self.assertFalse(self.state.exists())
                self.assertFalse(self.backup.exists())

    def test_symlink_target_and_parent_are_rejected_without_touching_victims(self) -> None:
        victim = self.root / "target-victim.json"
        victim.write_bytes(b'{"victim":true}\n')
        self.target.symlink_to(victim)

        target_result = self.run_helper("adopt")

        self.assertNotEqual(target_result.returncode, 0)
        self.assertIn("symlink", target_result.stderr)
        self.assertEqual(victim.read_bytes(), b'{"victim":true}\n')
        self.assertFalse(self.state.exists())
        self.target.unlink()

        self.target.parent.rmdir()
        real_parent = self.root / "real-docker-parent"
        real_parent.mkdir()
        parent_victim = real_parent / "daemon.json"
        parent_victim.write_bytes(b'{"parent-victim":true}\n')
        self.target.parent.symlink_to(real_parent, target_is_directory=True)

        parent_result = self.run_helper("adopt")

        self.assertNotEqual(parent_result.returncode, 0)
        self.assertIn("symlink or non-directory parent refused", parent_result.stderr)
        self.assertEqual(parent_victim.read_bytes(), b'{"parent-victim":true}\n')
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

    def test_symlinked_state_backup_and_lock_paths_are_rejected_without_touching_victims(self) -> None:
        original = b'{"log-driver":"local","future-option":"baseline"}\n'
        for label, path, diagnostic in (
            ("state", self.state, f"must be a regular non-symlink file: {self.state}"),
            ("backup", self.backup, f"must be a regular non-symlink file: {self.backup}"),
            ("lock", self.lock, f"cannot acquire Docker policy lock {self.lock}"),
        ):
            with self.subTest(path=label):
                for artifact in (self.target, self.state, self.backup, self.lock):
                    artifact.unlink(missing_ok=True)
                self.target.write_bytes(original)
                path.parent.mkdir(parents=True, exist_ok=True)
                victim = self.root / f"{label}-victim"
                victim.write_bytes(b"victim-bytes\n")
                path.symlink_to(victim)

                result = self.run_helper("adopt")

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR", result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(self.target.read_bytes(), original)
                self.assertEqual(victim.read_bytes(), b"victim-bytes\n")

    def test_reconcile_rejects_a_symlinked_state_parent_without_touching_victim(self) -> None:
        original = b'{"log-driver":"local","future-option":true}\n'
        self.target.write_bytes(original)
        victim_parent = self.root / "state-parent-victim"
        victim_parent.mkdir()
        (self.root / "var" / "lib").mkdir(parents=True)
        self.state.parent.symlink_to(victim_parent, target_is_directory=True)

        result = self.run_helper("reconcile")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink or non-directory parent refused", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(list(victim_parent.iterdir()), [])
        self.assertFalse(self.backup.exists())

    def test_group_or_world_writable_ancestor_is_refused_without_artifacts(self) -> None:
        original = b'{"log-driver":"local","future-option":true}\n'
        self.target.write_bytes(original)
        ancestor = self.root / "etc"
        original_mode = stat.S_IMODE(ancestor.stat().st_mode)
        for mode in (0o775, 0o757):
            with self.subTest(mode=oct(mode)):
                ancestor.chmod(mode)
                try:
                    result = self.run_helper("adopt")
                finally:
                    ancestor.chmod(original_mode)

                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(
                    result.stderr,
                    f"docker-init: ERROR: untrusted writable or foreign-owned parent refused: {ancestor}\n",
                )
                self.assertEqual(self.target.read_bytes(), original)
                for artifact in (self.state, self.backup, self.lock, self.validation_log, self.validated_config):
                    self.assertFalse(artifact.exists(), artifact)

    def test_validator_failure_leaves_live_bytes_and_recovery_paths_absent(self) -> None:
        original = b'{"log-driver":"local","future-option":true}\n'
        self.target.write_bytes(original)

        result = self.run_helper("adopt", env={"DOCKER_VALIDATE_EXIT": "42"})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("validation failed", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

    def test_validator_timeout_releases_lock_without_publishing_config(self) -> None:
        original = b'{"log-driver":"local","future-option":true}\n'
        self.target.write_bytes(original)
        sleep_once = self.root / "validator-sleep-once"
        helper_globals = runpy.run_path(str(HELPER))
        helper_main_object = helper_globals["main"]
        helper_main_object.__globals__["VALIDATION_TIMEOUT_SECONDS"] = 0.05
        helper_main = cast(Callable[[list[str] | None], int], helper_main_object)
        real_validate_candidate_file = helper_main_object.__globals__[
            "validate_candidate_file"
        ]

        def validate_with_lock_probe(candidate_path: Path, dockerd: Path) -> None:
            with self.lock.open("rb") as probe, self.assertRaises(BlockingIOError):
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            real_validate_candidate_file(candidate_path, dockerd)

        helper_main_object.__globals__["validate_candidate_file"] = (
            validate_with_lock_probe
        )
        helper_argv = [
            "adopt",
            "--profile",
            "workstation",
            "--patch",
            str(self.patch),
            "--target",
            str(self.target),
            "--state",
            str(self.state),
            "--backup",
            str(self.backup),
            "--lock",
            str(self.lock),
            "--dockerd",
            str(self.dockerd),
            "--test-root",
            str(self.root),
        ]
        validator_env = {
            "DOCKER_VALIDATE_LOG": str(self.validation_log),
            "DOCKER_VALIDATED_CONFIG": str(self.validated_config),
            "DOCKER_VALIDATE_SLEEP_ONCE": str(sleep_once),
            "DOCKER_VALIDATE_SLEEP_SECONDS": "0.25",
        }
        stdout = io.StringIO()
        stderr = io.StringIO()

        with (
            mock_patch.dict(os.environ, validator_env),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            result_code = helper_main(helper_argv)

        with self.lock.open("rb") as probe:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

        self.assertEqual(result_code, 1)
        self.assertIn("validation timed out after 0.05 seconds", stderr.getvalue())
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())
        self.assertEqual(list(self.root.glob("docker-daemon-candidate-*.json")), [])

        refused = b'{"init":false,"future-option":true}\n'
        self.target.write_bytes(refused)
        subsequent = self.run_helper("adopt", timeout=1.0)

        self.assertEqual(subsequent.returncode, 1, subsequent.stderr)
        self.assertIn("ownership conflict", subsequent.stderr)
        self.assertEqual(self.target.read_bytes(), refused)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root runner to prove backup write refusal")
    def test_backup_publication_failure_leaves_target_and_recovery_paths_untouched(self) -> None:
        original = b'{"log-driver":"local","future-option":"baseline"}\n'
        self.target.write_bytes(original)
        self.state.parent.mkdir(parents=True)
        self.state.parent.chmod(0o500)
        try:
            result = self.run_helper("adopt")
        finally:
            self.state.parent.chmod(0o700)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("atomic publication failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root runner to prove target staging refusal")
    def test_target_staging_failure_retains_durable_prepared_state_and_baseline(self) -> None:
        original = b'{"log-driver":"local","future-option":"baseline"}\n'
        self.target.write_bytes(original)
        try:
            result = self.run_helper(
                "adopt",
                env={
                    "DOCKER_CHMOD_PARENT_ON_VALIDATE": "1",
                    "DOCKER_TARGET_PARENT": str(self.target.parent),
                },
            )
        finally:
            self.target.parent.chmod(0o700)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config publication failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(self.backup.read_bytes(), original)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(state["phase"], "prepared")
        self.assertEqual(state["original_target"]["content_sha256"], self.sha256(original))
        self.assertEqual(list(self.target.parent.glob(".daemon.json.dotfiles-stage.*")), [])

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root runner to prove target replacement refusal")
    def test_target_replacement_failure_retains_durable_prepared_state_and_baseline(self) -> None:
        original = b'{"log-driver":"local","future-option":"baseline"}\n'
        self.target.write_bytes(original)
        try:
            result = self.run_helper(
                "adopt",
                env={
                    "DOCKER_CHMOD_PARENT_ON_VALIDATE": "2",
                    "DOCKER_TARGET_PARENT": str(self.target.parent),
                },
            )
        finally:
            self.target.parent.chmod(0o700)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config publication failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(self.backup.read_bytes(), original)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(state["phase"], "prepared")
        self.assertEqual(state["original_target"]["content_sha256"], self.sha256(original))

    def test_non_private_adoption_state_is_refused_without_touching_target(self) -> None:
        original = b'{"future-option":"baseline"}\n'
        self.target.write_bytes(original)
        adopted = self.run_helper("adopt")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        target_after_adopt = self.target.read_bytes()
        state_after_adopt = self.state.read_bytes()
        self.state.chmod(0o666)

        result = self.run_helper("check")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private owned", result.stderr)
        self.assertEqual(self.target.read_bytes(), target_after_adopt)
        self.assertEqual(self.state.read_bytes(), state_after_adopt)

    def test_malformed_nested_adoption_state_fails_closed_without_traceback(self) -> None:
        self.target.write_bytes(b'{"future-option":"baseline"}\n')
        adopted = self.run_helper("adopt")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        state["original_target"] = "not-a-snapshot"
        self.state.write_text(json.dumps(state) + "\n", encoding="utf-8")

        result = self.run_helper("check")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIs(json.loads(self.target.read_text(encoding="utf-8"))["init"], True)

    def test_interrupted_prepared_transactions_recover_without_replacing_baseline(self) -> None:
        original = b'{"log-driver":"local","future-option":{"preserve":true}}\n'
        for crash_point in (
            "before-target-publication",
            "after-target-publication",
            "before-adopted-state",
        ):
            with self.subTest(crash_point=crash_point):
                for path in (self.target, self.state, self.backup, self.lock, self.validation_log, self.validated_config):
                    path.unlink(missing_ok=True)
                self.target.write_bytes(original)

                interrupted = self.run_helper("adopt", "--inject-crash", crash_point)

                self.assertEqual(interrupted.returncode, 86, interrupted.stderr)
                self.assertEqual(self.backup.read_bytes(), original)
                prepared = json.loads(self.state.read_text(encoding="utf-8"))
                self.assertEqual(prepared["phase"], "prepared")
                self.assertEqual(prepared["original_target"]["content_sha256"], self.sha256(original))

                recovered = self.run_helper("reconcile")
                if crash_point == "before-target-publication":
                    self.assertNotEqual(recovered.returncode, 0)
                    self.assertIn("explicit adoption", recovered.stderr)
                    self.assertEqual(self.target.read_bytes(), original)
                    self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "prepared")
                    recovered = self.run_helper("adopt")

                self.assertEqual(recovered.returncode, 0, recovered.stderr)
                self.assertIn("adopted", recovered.stdout)
                self.assertEqual(self.backup.read_bytes(), original)
                self.assertIs(json.loads(self.target.read_text(encoding="utf-8"))["init"], True)
                self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "adopted")

    def test_prepared_recovery_refuses_a_changed_original_backup(self) -> None:
        original = b'{"log-driver":"local","baseline":true}\n'
        self.target.write_bytes(original)
        interrupted = self.run_helper("adopt", "--inject-crash", "before-target-publication")
        self.assertEqual(interrupted.returncode, 86, interrupted.stderr)
        prepared_before = self.state.read_bytes()
        self.backup.write_bytes(b'{"tampered":true}\n')

        result = self.run_helper("reconcile")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backup", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(self.state.read_bytes(), prepared_before)
        self.assertEqual(self.backup.read_bytes(), b'{"tampered":true}\n')

    def test_external_change_before_publication_is_refused_and_baseline_is_retained(self) -> None:
        original = b'{"log-driver":"local","baseline":true}\n'
        external = b'{"external-writer":true}\n'
        self.target.write_bytes(original)

        result = self.run_helper("adopt", env={"DOCKER_MUTATE_TARGET": str(self.target)})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("external Docker daemon config change", result.stderr)
        self.assertEqual(self.target.read_bytes(), external)
        self.assertEqual(self.backup.read_bytes(), original)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(state["phase"], "prepared")
        self.assertEqual(state["original_target"]["content_sha256"], self.sha256(original))

        reentry = self.run_helper("reconcile")
        self.assertNotEqual(reentry.returncode, 0)
        self.assertIn("requires investigation", reentry.stderr)
        self.assertEqual(self.target.read_bytes(), external)
        self.assertEqual(self.backup.read_bytes(), original)

    def test_rollback_restores_only_owned_key_and_disables_routine_reapplication(self) -> None:
        original = b'{"log-driver":"local","baseline":true}\n'
        self.target.write_bytes(original)
        adopted = self.run_helper("adopt")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)

        live = json.loads(self.target.read_text(encoding="utf-8"))
        live["added-after-adoption"] = {"preserve": True}
        self.target.write_text(json.dumps(live) + "\n", encoding="utf-8")

        rolled_back = self.run_helper("rollback")

        self.assertEqual(rolled_back.returncode, 0, rolled_back.stderr)
        self.assertIn("adoption disabled", rolled_back.stdout)
        self.assertEqual(
            json.loads(self.target.read_text(encoding="utf-8")),
            {"log-driver": "local", "baseline": True, "added-after-adoption": {"preserve": True}},
        )
        self.assertEqual(self.backup.read_bytes(), original)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rolled_back")

        target_after_rollback = self.target.read_bytes()
        reconciled = self.run_helper("reconcile")
        self.assertEqual(reconciled.returncode, 0, reconciled.stderr)
        self.assertIn("pending adoption after rollback", reconciled.stdout)
        self.assertEqual(self.target.read_bytes(), target_after_rollback)

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root runner to inject rollback staging refusal")
    def test_rollback_prepared_state_recovers_after_publication_failure(self) -> None:
        original = b'{"log-driver":"local","baseline":true}\n'
        self.target.write_bytes(original)
        adopted = self.run_helper("adopt")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        try:
            interrupted = self.run_helper(
                "rollback",
                env={
                    "DOCKER_CHMOD_PARENT_ON_VALIDATE": "3",
                    "DOCKER_TARGET_PARENT": str(self.target.parent),
                },
            )
        finally:
            self.target.parent.chmod(0o700)

        self.assertNotEqual(interrupted.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rollback_prepared")
        self.assertIs(json.loads(self.target.read_text(encoding="utf-8"))["init"], True)

        routine = self.run_helper("reconcile")
        self.assertNotEqual(routine.returncode, 0)
        self.assertIn("explicit rollback", routine.stderr)
        self.assertIs(json.loads(self.target.read_text(encoding="utf-8"))["init"], True)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rollback_prepared")

        recovered = self.run_helper("rollback")

        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(json.loads(self.target.read_text(encoding="utf-8")), {"log-driver": "local", "baseline": True})
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rolled_back")
        self.assertEqual(self.backup.read_bytes(), original)

    def test_rollback_finalizes_when_prepared_target_was_already_published(self) -> None:
        original = b'{"log-driver":"local","baseline":true}\n'
        self.target.write_bytes(original)
        adopted = self.run_helper("adopt")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        live = json.loads(self.target.read_text(encoding="utf-8"))
        live.pop("init")
        rollback_bytes = (json.dumps(live, indent=2, sort_keys=True) + "\n").encode("utf-8")
        state = json.loads(self.state.read_text(encoding="utf-8"))
        state["phase"] = "rollback_prepared"
        state["rollback_content_sha256"] = self.sha256(rollback_bytes)
        state["rollback_remove_target"] = False
        self.state.write_text(json.dumps(state) + "\n", encoding="utf-8")
        self.state.chmod(0o600)
        self.target.write_bytes(rollback_bytes)

        recovered = self.run_helper("rollback")

        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(self.target.read_bytes(), rollback_bytes)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rolled_back")
        self.assertEqual(self.backup.read_bytes(), original)

    def test_rollback_refuses_an_independently_changed_owned_value(self) -> None:
        original = b'{"future-option":"baseline"}\n'
        self.target.write_bytes(original)
        adopted = self.run_helper("adopt")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)

        independently_changed = b'{"init":false,"future-option":"changed-elsewhere"}\n'
        self.target.write_bytes(independently_changed)
        state_before = self.state.read_bytes()

        result = self.run_helper("rollback")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed independently", result.stderr)
        self.assertEqual(self.target.read_bytes(), independently_changed)
        self.assertEqual(self.state.read_bytes(), state_before)
        self.assertEqual(self.backup.read_bytes(), original)

    def test_missing_target_adoption_and_rollback_preserve_original_absence(self) -> None:
        pending = self.run_helper("reconcile")
        self.assertEqual(pending.returncode, 0, pending.stderr)
        self.assertIn("pending adoption", pending.stdout)
        self.assertFalse(self.target.exists())

        adopted = self.run_helper("adopt")

        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        self.assertEqual(json.loads(self.target.read_text(encoding="utf-8")), {"init": True})
        self.assertFalse(self.backup.exists())
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertFalse(state["original_file_existed"])
        self.assertFalse(state["prior_init_present"])

        rolled_back = self.run_helper("rollback")
        self.assertEqual(rolled_back.returncode, 0, rolled_back.stderr)
        self.assertFalse(self.target.exists())
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "rolled_back")

    def test_desired_unadopted_and_non_workstation_paths_do_not_publish(self) -> None:
        desired = b'{"init":true,"unowned":"keep"}\n'
        self.target.write_bytes(desired)

        workstation = self.run_helper("check")
        self.assertEqual(workstation.returncode, 0, workstation.stderr)
        self.assertIn("desired config present", workstation.stdout)
        self.assertIn("pending adoption", workstation.stdout)
        self.assertIn("runtime not verified", workstation.stdout)
        self.assertEqual(self.target.read_bytes(), desired)
        self.assertFalse(self.state.exists())

        self.validation_log.unlink(missing_ok=True)
        satellite = self.run_helper("reconcile", profile="satellite")
        self.assertEqual(satellite.returncode, 0, satellite.stderr)
        self.assertEqual(satellite.stdout, "")
        self.assertFalse(self.validation_log.exists())
        self.assertEqual(self.target.read_bytes(), desired)

        undeclared_adopt = self.run_helper("adopt", profile="unknown")
        self.assertNotEqual(undeclared_adopt.returncode, 0)
        self.assertIn("restricted", undeclared_adopt.stderr)
        self.assertEqual(self.target.read_bytes(), desired)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root runner to prove privilege refusal")
    def test_production_mutation_without_root_privilege_is_refused(self) -> None:
        original = b'{"future-option":"unchanged"}\n'
        self.target.write_bytes(original)

        result = self.run_helper("adopt", include_test_root=False)

        self.assertEqual(result.returncode, 4)
        self.assertIn("root privilege is required", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

    def test_cooperating_adopters_are_serialized_by_the_sibling_lock(self) -> None:
        original = b'{"log-driver":"local","baseline":"one"}\n'
        self.target.write_bytes(original)
        ready = self.root / "validator-ready"
        release = self.root / "validator-release"
        first_env = {
            "DOCKER_VALIDATE_READY": str(ready),
            "DOCKER_VALIDATE_RELEASE": str(release),
        }

        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(
                self.run_helper,
                "adopt",
                "--validation-timeout",
                str(SIBLING_ADOPTER_JOIN_SECONDS),
                env=first_env,
            )
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not ready.exists():
                release.touch()
            self.assertTrue(ready.exists(), "first adopter did not reach validator gate")

            second = executor.submit(
                self.run_helper,
                "adopt",
                "--validation-timeout",
                str(SIBLING_ADOPTER_JOIN_SECONDS),
            )
            try:
                time.sleep(0.1)
                self.assertFalse(second.done(), "second adopter bypassed the transaction lock")
            finally:
                release.touch()
            first_result = first.result(timeout=SIBLING_ADOPTER_JOIN_SECONDS)
            second_result = second.result(timeout=SIBLING_ADOPTER_JOIN_SECONDS)

        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        self.assertEqual(second_result.returncode, 0, second_result.stderr)
        self.assertEqual(self.backup.read_bytes(), original)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "adopted")
        self.assertIs(json.loads(self.target.read_text(encoding="utf-8"))["init"], True)

    def test_ci_local_docker_daemon_config_sibling_lock_survives_descheduled_validator(self) -> None:
        """Pin ci:local:test_docker_daemon_config.py at 07a5c4ce.

        The local suite run joined the first adopter with future.result(timeout=5)
        after opening the validator gate. Under that run the child had not
        exited, so the join raised TimeoutError and executor shutdown then
        waited out the helper's 30s validator kill (suite 39.3s vs 7.3s idle).
        A hold longer than that 5s join must still publish once, with the
        second adopter kept behind the lock.
        """
        original = b'{"log-driver":"local","baseline":"held"}\n'
        self.target.write_bytes(original)
        ready = self.root / "validator-ready"
        release = self.root / "validator-release"
        held = {
            "DOCKER_VALIDATE_READY": str(ready),
            "DOCKER_VALIDATE_RELEASE": str(release),
            "DOCKER_VALIDATE_HOLD_SECONDS": "6",
        }

        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(
                self.run_helper,
                "adopt",
                "--validation-timeout",
                str(SIBLING_ADOPTER_JOIN_SECONDS),
                env=held,
            )
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not ready.exists():
                release.touch()
            self.assertTrue(ready.exists(), "first adopter did not reach validator gate")

            second = executor.submit(
                self.run_helper,
                "adopt",
                "--validation-timeout",
                str(SIBLING_ADOPTER_JOIN_SECONDS),
            )
            try:
                time.sleep(0.1)
                self.assertFalse(second.done(), "second adopter bypassed the transaction lock")
            finally:
                release.touch()
            first_result = first.result(timeout=SIBLING_ADOPTER_JOIN_SECONDS)
            second_result = second.result(timeout=SIBLING_ADOPTER_JOIN_SECONDS)

        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        self.assertEqual(second_result.returncode, 0, second_result.stderr)
        self.assertEqual(self.backup.read_bytes(), original)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["phase"], "adopted")
        self.assertIs(json.loads(self.target.read_text(encoding="utf-8"))["init"], True)

    def test_ci_local_docker_daemon_config_validation_timeout_flag_bounds_gated_validator(self) -> None:
        """Pin the 30s kill behind ci:local:test_docker_daemon_config.py at 07a5c4ce.

        The suite's extra ~32s matched VALIDATION_TIMEOUT_SECONDS. The
        sibling-lock join raises that deadline with --validation-timeout;
        the short side of the same flag must still fail closed, and must
        not be available outside --test-root.
        """
        original = b'{"log-driver":"local"}\n'
        self.target.write_bytes(original)
        result = self.run_helper(
            "adopt",
            "--validation-timeout",
            "0.05",
            env={
                "DOCKER_VALIDATE_SLEEP_ONCE": str(self.root / "validator-sleep-once"),
                "DOCKER_VALIDATE_SLEEP_SECONDS": "1",
            },
            timeout=5,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("validation timed out after 0.05 seconds", result.stderr)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.backup.exists())

        refused = self.run_helper(
            "adopt",
            "--validation-timeout",
            "120",
            include_test_root=False,
            timeout=5,
        )
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("requires --test-root", refused.stderr)

    def test_lexical_parent_traversal_cannot_escape_the_asserted_test_root(self) -> None:
        original = b'{"inside":"unchanged"}\n'
        self.target.write_bytes(original)
        with tempfile.TemporaryDirectory(prefix="docker-daemon-sibling-", dir=self.root.parent) as sibling_dir:
            sibling = Path(sibling_dir) / "daemon.json"
            sibling.write_bytes(b'{"outside":"victim"}\n')
            traversing = self.root / ".." / Path(sibling_dir).name / "daemon.json"

            result = self.run_helper("adopt", "--target", str(traversing))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes asserted root", result.stderr)
            self.assertEqual(sibling.read_bytes(), b'{"outside":"victim"}\n')
            self.assertEqual(self.target.read_bytes(), original)
            self.assertFalse(self.state.exists())

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root runner to prove unreadable-state classification")
    def test_permission_denied_state_read_uses_the_privilege_retry_exit(self) -> None:
        self.target.write_bytes(b'{"init":true}\n')
        self.state.parent.mkdir(parents=True)
        self.state.write_text("{}\n", encoding="utf-8")
        self.state.chmod(0)
        try:
            result = self.run_helper("reconcile")
        finally:
            self.state.chmod(0o600)

        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("privilege is required to read", result.stderr)
        self.assertEqual(self.target.read_bytes(), b'{"init":true}\n')
        self.assertFalse(self.backup.exists())


class FixtureUmaskIsolationTests(unittest.TestCase):
    """os.umask is process-global, so a leaked fixture pin would reach every module in discovery."""

    def test_fixture_restores_caller_umask_after_normal_and_failed_setup(self) -> None:
        # Runs in a child interpreter under the 0002 umask that exposed the
        # fixture's host dependence, so a broken restore cannot leak here.
        probe = (
            "import importlib.util, json, os, sys, unittest\n"
            "from unittest.mock import patch\n"
            "def current_umask():\n"
            "    value = os.umask(0)\n"
            "    os.umask(value)\n"
            "    return value\n"
            "os.umask(0o002)\n"
            "spec = importlib.util.spec_from_file_location('docker_daemon_config_umask_probe', sys.argv[1])\n"
            "module = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(module)\n"
            "def run(name):\n"
            "    result = unittest.TestResult()\n"
            "    module.DockerDaemonConfigCliTests(name).run(result)\n"
            "    return result\n"
            "normal = run('test_routine_reconcile_validates_but_does_not_first_publish')\n"
            "after_normal = current_umask()\n"
            "with patch('tempfile.TemporaryDirectory', side_effect=OSError('injected setUp failure')):\n"
            "    failed = run('test_routine_reconcile_validates_but_does_not_first_publish')\n"
            "after_failed = current_umask()\n"
            "print(json.dumps({\n"
            "    'normal_ok': normal.wasSuccessful(),\n"
            "    'normal_problems': [text for _, text in normal.failures + normal.errors],\n"
            "    'after_normal': after_normal,\n"
            "    'failed_errors': [text for _, text in failed.errors],\n"
            "    'failed_failures': len(failed.failures),\n"
            "    'after_failed': after_failed,\n"
            "}))\n"
        )

        completed = subprocess.run(
            [sys.executable, "-c", probe, str(Path(__file__).resolve())],
            text=True,
            capture_output=True,
            check=False,
            timeout=60,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(completed.stdout)
        self.assertTrue(report["normal_ok"], report["normal_problems"])
        self.assertEqual(report["after_normal"], 0o002)
        self.assertEqual(len(report["failed_errors"]), 1, report["failed_errors"])
        self.assertIn("injected setUp failure", report["failed_errors"][0])
        self.assertEqual(report["failed_failures"], 0)
        self.assertEqual(report["after_failed"], 0o002)


if __name__ == "__main__":
    unittest.main()
