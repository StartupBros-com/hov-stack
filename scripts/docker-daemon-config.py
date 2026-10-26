#!/usr/bin/env python3
"""Adopt and reconcile the one Docker daemon key owned by dotfiles.

The helper never starts, stops, reloads, or restarts Docker. It validates a
candidate with ``dockerd --validate`` and publishes only the owned ``init`` key.
First publication is available only through the explicit ``adopt`` command;
routine ``check`` and ``reconcile`` calls report an unadopted policy as pending.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

DEFAULT_TARGET = Path("/etc/docker/daemon.json")
DEFAULT_STATE = Path("/var/lib/dotfiles/docker-init-adoption.json")
DEFAULT_BACKUP = Path("/var/lib/dotfiles/docker-init-adoption.original")
DEFAULT_LOCK = Path("/etc/docker/.daemon.json.dotfiles.lock")
DEFAULT_PATCH = Path(__file__).resolve().parents[1] / "config/system/docker-daemon.patch.json"
STATE_VERSION = 1
PRIVILEGE_EXIT = 4
CRASH_EXIT = 86
VALIDATION_TIMEOUT_SECONDS = 30.0


def validation_timeout_seconds(value: str) -> float:
    """Parse --validation-timeout. The default stays the module constant."""
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("validation timeout must be a number") from exc
    # nan fails both comparisons; inf is not < inf.
    if not 0 < parsed < float("inf"):
        raise argparse.ArgumentTypeError("validation timeout must be a positive finite number")
    return parsed


class PolicyError(RuntimeError):
    """A fail-closed policy or filesystem validation error."""

    def __init__(self, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code


class DuplicateKeyError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json_bytes(raw: bytes, path: Path) -> dict[str, Any]:
    try:
        value = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, DuplicateKeyError) as exc:
        raise PolicyError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PolicyError(f"JSON root must be an object: {path}")
    return value


def load_json_object(path: Path, *, allow_missing: bool = False) -> tuple[dict[str, Any], bytes | None]:
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        if allow_missing:
            return {}, None
        raise PolicyError(f"required JSON file is missing: {path}") from None
    except PermissionError as exc:
        raise PolicyError(f"privilege is required to read {path}: {exc}", PRIVILEGE_EXIT) from exc
    except OSError as exc:
        raise PolicyError(f"cannot read {path}: {exc}") from exc
    return load_json_bytes(raw, path), raw


def validate_regular_file(path: Path, label: str, *, allow_missing: bool = False) -> os.stat_result | None:
    try:
        result = os.lstat(path)
    except FileNotFoundError:
        if allow_missing:
            return None
        raise PolicyError(f"{label} is missing: {path}") from None
    except PermissionError as exc:
        raise PolicyError(f"privilege is required to inspect {label} {path}: {exc}", PRIVILEGE_EXIT) from exc
    except OSError as exc:
        raise PolicyError(f"cannot inspect {label} {path}: {exc}") from exc
    if stat.S_ISLNK(result.st_mode) or not stat.S_ISREG(result.st_mode):
        raise PolicyError(f"{label} must be a regular non-symlink file: {path}")
    return result


def validate_patch(path: Path) -> tuple[dict[str, Any], str]:
    validate_regular_file(path, "policy patch")
    patch, _ = load_json_object(path)
    if set(patch) != {"init"} or patch.get("init") is not True:
        raise PolicyError(f"policy patch must contain only boolean init=true: {path}")
    return patch, sha256(render_config(patch))


def _path_is_within(path: Path, root: Path) -> bool:
    if ".." in path.parts:
        return False
    try:
        path.resolve(strict=False).relative_to(root.resolve(strict=True))
    except (FileNotFoundError, OSError, ValueError):
        return False
    return True


def validate_test_boundary(args: argparse.Namespace) -> None:
    if args.test_root is None:
        return
    root = args.test_root.absolute()
    try:
        root_stat = os.lstat(root)
    except OSError as exc:
        raise PolicyError(f"test root is unavailable: {root}: {exc}") from exc
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise PolicyError(f"test root must be a real directory: {root}")
    if root_stat.st_uid != os.geteuid() or root_stat.st_mode & 0o077:
        raise PolicyError(f"test root must be owned by this uid with mode 0700: {root}")
    for path in (args.target, args.state, args.backup, args.lock, args.dockerd):
        if not _path_is_within(path, root):
            raise PolicyError(f"test override escapes asserted root {root}: {path}")


def validate_path_chain(path: Path, *, boundary: Path | None, create_parent: bool = False) -> None:
    absolute = path.absolute()
    start = boundary.absolute() if boundary is not None else Path(absolute.anchor)
    if boundary is not None and not _path_is_within(absolute, start):
        raise PolicyError(f"path escapes validation boundary {start}: {absolute}")
    current = start
    parts = absolute.relative_to(start).parts[:-1]
    for part in parts:
        current /= part
        try:
            current_stat = os.lstat(current)
        except FileNotFoundError:
            if not create_parent:
                break
            try:
                os.mkdir(current, 0o700)
                current_stat = os.lstat(current)
            except OSError as exc:
                raise PolicyError(f"cannot create trusted parent {current}: {exc}") from exc
        except PermissionError as exc:
            raise PolicyError(
                f"privilege is required to inspect parent {current}: {exc}",
                PRIVILEGE_EXIT,
            ) from exc
        except OSError as exc:
            raise PolicyError(f"cannot inspect parent {current}: {exc}") from exc
        if stat.S_ISLNK(current_stat.st_mode) or not stat.S_ISDIR(current_stat.st_mode):
            raise PolicyError(f"symlink or non-directory parent refused: {current}")
        expected_uid = os.geteuid() if boundary is not None else 0
        if current_stat.st_uid != expected_uid or current_stat.st_mode & 0o022:
            raise PolicyError(f"untrusted writable or foreign-owned parent refused: {current}")


def target_snapshot(path: Path) -> tuple[dict[str, Any], bytes | None]:
    path_stat = validate_regular_file(path, "Docker daemon target", allow_missing=True)
    if path_stat is None:
        return {"exists": False}, None
    descriptor: int | None = None
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
        descriptor = os.open(path, flags)
        opened_stat = os.fstat(descriptor)
        if not stat.S_ISREG(opened_stat.st_mode):
            raise PolicyError(f"Docker daemon target must be a regular non-symlink file: {path}")
        if (opened_stat.st_dev, opened_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino):
            raise PolicyError(f"Docker daemon target changed while it was being inspected: {path}")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = None
            raw = handle.read()
            final_stat = os.fstat(handle.fileno())
    except PermissionError as exc:
        raise PolicyError(
            f"privilege is required to read Docker daemon target {path}: {exc}",
            PRIVILEGE_EXIT,
        ) from exc
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise PolicyError(f"Docker daemon target must be a regular non-symlink file: {path}") from exc
        raise PolicyError(f"cannot read Docker daemon target {path}: {exc}") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)

    opened_identity = (
        opened_stat.st_dev,
        opened_stat.st_ino,
        opened_stat.st_mode,
        opened_stat.st_uid,
        opened_stat.st_gid,
        opened_stat.st_size,
        opened_stat.st_mtime_ns,
    )
    final_identity = (
        final_stat.st_dev,
        final_stat.st_ino,
        final_stat.st_mode,
        final_stat.st_uid,
        final_stat.st_gid,
        final_stat.st_size,
        final_stat.st_mtime_ns,
    )
    if opened_identity != final_identity or len(raw) != final_stat.st_size:
        raise PolicyError(f"Docker daemon target changed while it was being read: {path}")
    return (
        {
            "exists": True,
            "device": final_stat.st_dev,
            "inode": final_stat.st_ino,
            "uid": final_stat.st_uid,
            "gid": final_stat.st_gid,
            "mode": stat.S_IMODE(final_stat.st_mode),
            "size": final_stat.st_size,
            "mtime_ns": final_stat.st_mtime_ns,
            "content_sha256": sha256(raw),
        },
        raw,
    )


def snapshots_match(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return left == right


def render_config(config: dict[str, Any]) -> bytes:
    return (json.dumps(config, indent=2, sort_keys=True) + "\n").encode("utf-8")


def parse_target(path: Path, snapshot: dict[str, Any], raw: bytes | None) -> dict[str, Any]:
    if not snapshot["exists"]:
        return {}
    assert raw is not None
    config = load_json_bytes(raw, path)
    if "init" in config and not isinstance(config["init"], bool):
        raise PolicyError("existing Docker init value must be boolean")
    return config


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def validate_candidate_file(candidate_path: Path, dockerd: Path) -> None:
    validate_regular_file(dockerd, "dockerd validator")
    if not os.access(dockerd, os.X_OK):
        raise PolicyError(f"dockerd validator is not executable: {dockerd}")
    try:
        result = subprocess.run(
            [str(dockerd), "--validate", "--config-file", str(candidate_path)],
            text=True,
            capture_output=True,
            check=False,
            timeout=VALIDATION_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise PolicyError(
            f"Docker configuration validation timed out after {VALIDATION_TIMEOUT_SECONDS:g} seconds"
        ) from exc
    except OSError as exc:
        raise PolicyError(f"Docker configuration validation could not run: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise PolicyError(f"Docker configuration validation failed: {detail}")


def remove_temporary(path: Path | None) -> None:
    if path is None:
        return
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass


def validate_candidate_bytes(candidate: bytes, dockerd: Path, scratch_root: Path | None) -> None:
    directory = scratch_root if scratch_root is not None else Path("/tmp")
    candidate_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix="docker-daemon-candidate-", suffix=".json", dir=directory, delete=False
        ) as handle:
            candidate_path = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            handle.write(candidate)
            handle.flush()
            os.fsync(handle.fileno())
        validate_candidate_file(candidate_path, dockerd)
    except OSError as exc:
        raise PolicyError(f"cannot stage Docker configuration validation: {exc}") from exc
    finally:
        remove_temporary(candidate_path)


def require_mutation_authority(args: argparse.Namespace) -> None:
    if args.test_root is None and os.geteuid() != 0:
        raise PolicyError("root privilege is required for Docker policy mutation", PRIVILEGE_EXIT)


def atomic_write(
    path: Path,
    value: bytes,
    *,
    mode: int,
    uid: int,
    gid: int,
    boundary: Path | None,
    expected: dict[str, Any] | None = None,
) -> dict[str, Any]:
    validate_path_chain(path, boundary=boundary, create_parent=True)
    parent = path.parent
    temp_path: Path | None = None
    try:
        descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.tmp.", dir=parent)
        temp_path = Path(temp_name)
        with os.fdopen(descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            if os.geteuid() == 0:
                os.fchown(handle.fileno(), uid, gid)
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        if expected is not None:
            actual, _ = target_snapshot(path)
            if not snapshots_match(actual, expected):
                raise PolicyError(f"external change detected before publishing {path}; live bytes left untouched")
        os.replace(temp_path, path)
        temp_path = None
        fsync_directory(parent)
        published, _ = target_snapshot(path)
        return published
    except OSError as exc:
        raise PolicyError(f"atomic publication failed for {path}: {exc}") from exc
    finally:
        remove_temporary(temp_path)


def write_state(
    args: argparse.Namespace,
    record: dict[str, Any],
    *,
    expected: dict[str, Any],
) -> dict[str, Any]:
    boundary = args.test_root.absolute() if args.test_root is not None else None
    return atomic_write(
        args.state,
        render_config(record),
        mode=0o600,
        uid=0 if boundary is None else os.geteuid(),
        gid=0 if boundary is None else os.getegid(),
        boundary=boundary,
        expected=expected,
    )


def validate_digest(value: Any, label: str, *, allow_none: bool = False) -> None:
    if allow_none and value is None:
        return
    if not isinstance(value, str) or len(value) != 64:
        raise PolicyError(f"Docker adoption state has an invalid {label}")
    try:
        int(value, 16)
    except ValueError as exc:
        raise PolicyError(f"Docker adoption state has an invalid {label}") from exc


def validate_snapshot_record(value: Any, label: str) -> None:
    if not isinstance(value, dict) or type(value.get("exists")) is not bool:
        raise PolicyError(f"Docker adoption state has an invalid {label} snapshot")
    if not value["exists"]:
        if set(value) != {"exists"}:
            raise PolicyError(f"Docker adoption state has an invalid absent {label} snapshot")
        return
    required = {
        "exists",
        "device",
        "inode",
        "uid",
        "gid",
        "mode",
        "size",
        "mtime_ns",
        "content_sha256",
    }
    if not required.issubset(value):
        raise PolicyError(f"Docker adoption state has an incomplete {label} snapshot")
    for field in ("device", "inode", "uid", "gid", "mode", "size", "mtime_ns"):
        field_value = value[field]
        if type(field_value) is not int or field_value < 0:
            raise PolicyError(f"Docker adoption state has an invalid {label} {field}")
    if value["mode"] > 0o7777:
        raise PolicyError(f"Docker adoption state has an invalid {label} mode")
    validate_digest(value["content_sha256"], f"{label} content digest")


def validate_state_record(args: argparse.Namespace, state: dict[str, Any]) -> None:
    required = {
        "version",
        "phase",
        "target",
        "original_file_existed",
        "prior_init_present",
        "managed_init_value",
        "policy_sha256",
        "original_target",
        "desired_content_sha256",
        "expected_target",
        "backup",
    }
    if not required.issubset(state):
        raise PolicyError(f"Docker adoption state is incomplete: {args.state}")
    if type(state["version"]) is not int or state["version"] != STATE_VERSION:
        raise PolicyError(f"Docker adoption state does not match this helper: {args.state}")
    expected_target_path = str(args.target.absolute())
    if not isinstance(state["target"], str) or state["target"] != expected_target_path:
        raise PolicyError(f"Docker adoption state does not match this target: {args.state}")
    phase = state["phase"]
    if not isinstance(phase, str) or phase not in {"prepared", "adopted", "rollback_prepared", "rolled_back"}:
        raise PolicyError(f"Docker adoption state has unknown phase: {phase!r}")
    if state["managed_init_value"] is not True:
        raise PolicyError("Docker adoption state has an invalid managed init value")
    if type(state["original_file_existed"]) is not bool or type(state["prior_init_present"]) is not bool:
        raise PolicyError("Docker adoption state has invalid baseline markers")
    if state["prior_init_present"] and type(state.get("prior_init_value")) is not bool:
        raise PolicyError("Docker adoption state has an invalid prior init value")
    validate_digest(state["policy_sha256"], "policy digest")
    validate_digest(state["desired_content_sha256"], "desired content digest")
    validate_snapshot_record(state["original_target"], "original target")
    validate_snapshot_record(state["expected_target"], "expected target")
    if state["original_target"]["exists"] is not state["original_file_existed"]:
        raise PolicyError("Docker adoption state has inconsistent original-file markers")
    expected_backup = str(args.backup.absolute()) if state["original_file_existed"] else None
    if state["backup"] != expected_backup:
        raise PolicyError("Docker adoption state has an invalid recovery backup path")
    if state["phase"] == "rollback_prepared":
        if "rollback_content_sha256" not in state or "rollback_remove_target" not in state:
            raise PolicyError("Docker adoption state has incomplete rollback preparation")
    if "rollback_remove_target" in state:
        if type(state["rollback_remove_target"]) is not bool:
            raise PolicyError("Docker adoption state has an invalid rollback removal marker")
        validate_digest(
            state.get("rollback_content_sha256"),
            "rollback content digest",
            allow_none=state["rollback_remove_target"],
        )


def load_state(args: argparse.Namespace) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.state, boundary=boundary, create_parent=False)
    state_snapshot, state_raw = target_snapshot(args.state)
    if not state_snapshot["exists"]:
        return None, state_snapshot
    expected_uid = os.geteuid() if boundary is not None else 0
    if state_snapshot["uid"] != expected_uid or state_snapshot["mode"] & 0o077:
        raise PolicyError("Docker adoption state is not a private owned file")
    assert state_raw is not None
    state = load_json_bytes(state_raw, args.state)
    validate_state_record(args, state)
    return state, state_snapshot


def open_transaction_lock(args: argparse.Namespace) -> int:
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.lock, boundary=boundary, create_parent=False)
    try:
        descriptor = os.open(args.lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        lock_stat = os.fstat(descriptor)
        expected_uid = os.geteuid() if boundary is not None else 0
        if (
            not stat.S_ISREG(lock_stat.st_mode)
            or lock_stat.st_nlink != 1
            or lock_stat.st_uid != expected_uid
            or stat.S_IMODE(lock_stat.st_mode) & 0o077
        ):
            raise PolicyError(f"transaction lock is not a private owned regular file: {args.lock}")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor
    except OSError as exc:
        raise PolicyError(f"cannot acquire Docker policy lock {args.lock}: {exc}") from exc


def preserve_baseline(args: argparse.Namespace, original: dict[str, Any], raw: bytes | None) -> None:
    validate_regular_file(args.backup, "Docker adoption backup", allow_missing=True)
    if args.backup.exists():
        raise PolicyError(f"recovery backup exists without adoption state; refusing to overwrite it: {args.backup}")
    if not original["exists"]:
        return
    assert raw is not None
    boundary = args.test_root.absolute() if args.test_root is not None else None
    atomic_write(
        args.backup,
        raw,
        mode=0o600,
        uid=0 if boundary is None else os.geteuid(),
        gid=0 if boundary is None else os.getegid(),
        boundary=boundary,
        expected={"exists": False},
    )


def validate_recovery_backup(args: argparse.Namespace, state: dict[str, Any]) -> None:
    if not state["original_file_existed"]:
        return
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.backup, boundary=boundary, create_parent=False)
    backup, _ = target_snapshot(args.backup)
    if not backup["exists"]:
        raise PolicyError("prepared adoption recovery backup is missing")
    expected_uid = os.geteuid() if boundary is not None else 0
    if backup["uid"] != expected_uid or backup["mode"] & 0o077:
        raise PolicyError("prepared adoption recovery backup is not a private owned file")
    if backup["content_sha256"] != state["original_target"]["content_sha256"]:
        raise PolicyError("prepared adoption recovery backup does not match the original target")


def crash_if(args: argparse.Namespace, point: str) -> None:
    if args.inject_crash == point:
        os._exit(CRASH_EXIT)


def publish_candidate(
    args: argparse.Namespace,
    candidate: bytes,
    expected_target: dict[str, Any],
) -> dict[str, Any]:
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.target, boundary=boundary, create_parent=False)
    parent = args.target.parent
    mode = expected_target.get("mode", 0o644)
    uid = expected_target.get("uid", 0 if boundary is None else os.geteuid())
    gid = expected_target.get("gid", 0 if boundary is None else os.getegid())
    stage_path: Path | None = None
    try:
        descriptor, stage_name = tempfile.mkstemp(prefix=".daemon.json.dotfiles-stage.", dir=parent)
        stage_path = Path(stage_name)
        with os.fdopen(descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            if os.geteuid() == 0:
                os.fchown(handle.fileno(), uid, gid)
            handle.write(candidate)
            handle.flush()
            os.fsync(handle.fileno())
        validate_candidate_file(stage_path, args.dockerd)
        crash_if(args, "before-target-publication")
        actual_target, _ = target_snapshot(args.target)
        if not snapshots_match(actual_target, expected_target):
            raise PolicyError("external Docker daemon config change detected before publication; live bytes left untouched")
        os.replace(stage_path, args.target)
        stage_path = None
        fsync_directory(parent)
        crash_if(args, "after-target-publication")
        return target_snapshot(args.target)[0]
    except OSError as exc:
        raise PolicyError(f"Docker daemon config publication failed: {exc}") from exc
    finally:
        remove_temporary(stage_path)


def inspect_candidate(args: argparse.Namespace) -> tuple[dict[str, Any], str, dict[str, Any], bytes]:
    patch, policy_digest = validate_patch(args.patch)
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.target, boundary=boundary)
    target, raw = target_snapshot(args.target)
    config = parse_target(args.target, target, raw)
    candidate = dict(config)
    candidate.update(patch)
    candidate_bytes = render_config(candidate)
    return patch, policy_digest, config, candidate_bytes


def mark_adopted(
    args: argparse.Namespace,
    state: dict[str, Any],
    state_snapshot: dict[str, Any],
    target: dict[str, Any],
) -> int:
    crash_if(args, "before-adopted-state")
    adopted = dict(state)
    adopted["phase"] = "adopted"
    adopted["expected_target"] = target
    write_state(args, adopted, expected=state_snapshot)
    print("docker-init: adopted; desired config present; runtime not verified")
    return 0


def resolve_prepared(
    args: argparse.Namespace,
    state: dict[str, Any],
    state_snapshot: dict[str, Any],
    policy_digest: str,
    *,
    allow_publication: bool = False,
) -> int:
    if state["policy_sha256"] != policy_digest:
        raise PolicyError("prepared adoption policy differs from the current reviewed patch")
    validate_recovery_backup(args, state)
    target, raw = target_snapshot(args.target)
    config = parse_target(args.target, target, raw)
    if snapshots_match(target, state["expected_target"]):
        if not allow_publication:
            raise PolicyError("prepared config is not published; explicit adoption recovery requires an approved maintenance window")
        candidate = dict(config)
        candidate["init"] = True
        candidate_bytes = render_config(candidate)
        if sha256(candidate_bytes) != state["desired_content_sha256"]:
            raise PolicyError("prepared adoption candidate no longer matches its recovery record")
        published = publish_candidate(args, candidate_bytes, target)
        state_snapshot = target_snapshot(args.state)[0]
        return mark_adopted(args, state, state_snapshot, published)
    if target.get("content_sha256") == state["desired_content_sha256"] and config.get("init") is True:
        validate_candidate_bytes(raw or b"", args.dockerd, args.test_root)
        return mark_adopted(args, state, state_snapshot, target)
    raise PolicyError("prepared adoption target mismatch requires investigation; original recovery baseline retained")


def adopt(args: argparse.Namespace) -> int:
    require_mutation_authority(args)
    patch, policy_digest, _, _ = inspect_candidate(args)
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.state, boundary=boundary, create_parent=True)
    validate_path_chain(args.backup, boundary=boundary, create_parent=True)
    lock_descriptor = open_transaction_lock(args)
    try:
        state, state_snapshot = load_state(args)
        if state is not None:
            if state["phase"] == "prepared":
                return resolve_prepared(args, state, state_snapshot, policy_digest, allow_publication=True)
            if state["phase"] == "adopted":
                return reconcile(args)
            raise PolicyError("Docker init adoption was rolled back; explicit recovery-state retirement is required before re-adoption")

        target, raw = target_snapshot(args.target)
        config = parse_target(args.target, target, raw)
        if config.get("init") is False and not args.allow_existing_false:
            raise PolicyError("existing explicit init=false is an ownership conflict; re-run explicit adoption with --allow-existing-false only when approval covers it")
        candidate = dict(config)
        candidate.update(patch)
        candidate_bytes = render_config(candidate)
        validate_candidate_bytes(candidate_bytes, args.dockerd, boundary)
        preserve_baseline(args, target, raw)
        record: dict[str, Any] = {
            "version": STATE_VERSION,
            "phase": "prepared",
            "target": str(args.target.absolute()),
            "original_file_existed": target["exists"],
            "prior_init_present": "init" in config,
            "managed_init_value": True,
            "policy_sha256": policy_digest,
            "original_target": target,
            "desired_content_sha256": sha256(candidate_bytes),
            "expected_target": target,
            "backup": str(args.backup.absolute()) if target["exists"] else None,
        }
        if "init" in config:
            record["prior_init_value"] = config["init"]
        write_state(args, record, expected=state_snapshot)
        prepared_snapshot = target_snapshot(args.state)[0]
        published = publish_candidate(args, candidate_bytes, target)
        return mark_adopted(args, record, prepared_snapshot, published)
    finally:
        os.close(lock_descriptor)


def inspect_or_reconcile(args: argparse.Namespace, *, mutate: bool) -> int:
    _, policy_digest, config, candidate = inspect_candidate(args)
    validate_candidate_bytes(candidate, args.dockerd, args.test_root)
    state, state_snapshot = load_state(args)
    if state is None:
        if config.get("init") is True:
            print("docker-init: desired config present; pending adoption; runtime not verified")
        else:
            print("docker-init: pending adoption; candidate valid; runtime not verified")
        return 0
    if state["phase"] == "rolled_back":
        print("docker-init: pending adoption after rollback; runtime not verified")
        return 0
    if state["phase"] == "rollback_prepared":
        raise PolicyError("rollback transaction is prepared and requires explicit rollback recovery")
    if state["phase"] == "prepared":
        if not mutate:
            raise PolicyError("adoption transaction is prepared and requires reconcile recovery")
        require_mutation_authority(args)
        lock_descriptor = open_transaction_lock(args)
        try:
            current_state, current_snapshot = load_state(args)
            assert current_state is not None
            return resolve_prepared(args, current_state, current_snapshot, policy_digest)
        finally:
            os.close(lock_descriptor)
    if state["policy_sha256"] != policy_digest:
        raise PolicyError("adopted Docker init policy differs from the current reviewed patch")
    if config.get("init") is not state["managed_init_value"]:
        raise PolicyError("owned Docker init value changed independently; refusing to overwrite it")
    print("docker-init: desired config present; adopted; runtime not verified")
    return 0


def reconcile(args: argparse.Namespace) -> int:
    return inspect_or_reconcile(args, mutate=True)


def check(args: argparse.Namespace) -> int:
    return inspect_or_reconcile(args, mutate=False)


def rollback_candidate(state: dict[str, Any], config: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    result = dict(config)
    if state["prior_init_present"]:
        result["init"] = state["prior_init_value"]
    else:
        result.pop("init", None)
    remove_target = not state["original_file_existed"] and not result
    return result, remove_target


def finalize_rollback(
    args: argparse.Namespace,
    state: dict[str, Any],
    state_snapshot: dict[str, Any],
    target: dict[str, Any],
) -> int:
    rolled_back = dict(state)
    rolled_back["phase"] = "rolled_back"
    rolled_back["expected_target"] = target
    write_state(args, rolled_back, expected=state_snapshot)
    print("docker-init: rolled back owned init key; adoption disabled; runtime not verified")
    return 0


def rollback(args: argparse.Namespace) -> int:
    require_mutation_authority(args)
    _, policy_digest, _, _ = inspect_candidate(args)
    boundary = args.test_root.absolute() if args.test_root is not None else None
    validate_path_chain(args.state, boundary=boundary, create_parent=False)
    lock_descriptor = open_transaction_lock(args)
    try:
        state, state_snapshot = load_state(args)
        if state is None:
            raise PolicyError("Docker init policy has not been adopted")
        if state["phase"] == "rolled_back":
            print("docker-init: already rolled back; adoption disabled; runtime not verified")
            return 0
        if state["phase"] == "prepared":
            raise PolicyError("adoption is still prepared; run reconcile before rollback")
        if state["policy_sha256"] != policy_digest:
            raise PolicyError("adopted Docker init policy differs from the current reviewed patch")

        target, raw = target_snapshot(args.target)
        config = parse_target(args.target, target, raw)
        rollback_config, remove_target = rollback_candidate(state, config)
        rollback_bytes = b"" if remove_target else render_config(rollback_config)
        rollback_digest = None if remove_target else sha256(rollback_bytes)

        if state["phase"] == "rollback_prepared":
            if target.get("content_sha256") == state.get("rollback_content_sha256"):
                return finalize_rollback(args, state, state_snapshot, target)
            if state.get("rollback_remove_target") and not target["exists"]:
                return finalize_rollback(args, state, state_snapshot, target)
            if config.get("init") is not state["managed_init_value"]:
                raise PolicyError("rollback target mismatch requires investigation; recovery baseline retained")
        elif config.get("init") is not state["managed_init_value"]:
            raise PolicyError("owned Docker init value changed independently; refusing rollback")

        prepared = dict(state)
        prepared["phase"] = "rollback_prepared"
        prepared["expected_target"] = target
        prepared["rollback_content_sha256"] = rollback_digest
        prepared["rollback_remove_target"] = remove_target
        write_state(args, prepared, expected=state_snapshot)
        prepared_snapshot = target_snapshot(args.state)[0]

        if remove_target:
            actual, _ = target_snapshot(args.target)
            if not snapshots_match(actual, target):
                raise PolicyError("external Docker daemon config change detected before rollback; live bytes left untouched")
            try:
                args.target.unlink()
                fsync_directory(args.target.parent)
            except OSError as exc:
                raise PolicyError(f"Docker daemon config rollback failed: {exc}") from exc
            published = {"exists": False}
        else:
            validate_candidate_bytes(rollback_bytes, args.dockerd, boundary)
            published = publish_candidate(args, rollback_bytes, target)
        return finalize_rollback(args, prepared, prepared_snapshot, published)
    finally:
        os.close(lock_descriptor)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "reconcile", "adopt", "rollback"))
    parser.add_argument("--profile", default="unknown")
    parser.add_argument("--patch", type=Path, default=DEFAULT_PATCH)
    parser.add_argument("--target", type=Path, default=DEFAULT_TARGET)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--backup", type=Path, default=DEFAULT_BACKUP)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--dockerd", type=Path, default=Path("/usr/bin/dockerd"))
    parser.add_argument("--test-root", type=Path)
    parser.add_argument("--allow-existing-false", action="store_true")
    parser.add_argument(
        "--inject-crash",
        choices=("before-target-publication", "after-target-publication", "before-adopted-state"),
    )
    parser.add_argument(
        "--validation-timeout",
        type=validation_timeout_seconds,
        default=None,
        help="override the 30s dockerd --validate deadline; only valid with --test-root",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    global VALIDATION_TIMEOUT_SECONDS
    args = build_parser().parse_args(argv)
    # Absent flag leaves the module constant alone, including an in-process
    # test that patches it before calling main().
    if args.validation_timeout is not None:
        if args.test_root is None:
            print(
                "docker-init: ERROR: validation timeout override requires --test-root",
                file=sys.stderr,
            )
            return 2
        VALIDATION_TIMEOUT_SECONDS = args.validation_timeout
    try:
        validate_test_boundary(args)
        if args.profile != "workstation":
            if args.command in {"adopt", "rollback"}:
                raise PolicyError("Docker init policy is restricted to the declared workstation profile", 2)
            return 0
        if args.command == "check":
            return check(args)
        if args.command == "reconcile":
            return reconcile(args)
        if args.command == "adopt":
            return adopt(args)
        return rollback(args)
    except PolicyError as exc:
        print(f"docker-init: ERROR: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
