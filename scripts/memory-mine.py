#!/usr/bin/env python3
"""Directed-capture tier for Claude Code auto-memory: mine session logs into
draft memory notes, validate deterministically, apply to a store.

Closes the write-path gap measured by memory-faceoff.py (2026-07-31: 16/31
session-derived facts had no covering note; directed extraction lifted cm from
3.2% to 45.2% on the same suite — this points the proven mechanism at the
stock store instead).

Same trust architecture as the dream pass: extraction subagents are pure text
transformations (session text in, JSON out) and never write; THIS script is the
only writer, and it re-validates everything first. Notes carry decay fields
(confidence / maturity / last_validated) so staleness is measurable later.

Commands:
  inventory --project-dir D --days N --out F [selection flags]
  staleness [--days N] [--json]
  validate  --candidates F --store D --out F [--manifest F]
  apply     --accepted F --store D [--manifest F] [--receipt F]
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


def load_sibling(filename: str, module_name: str) -> Any:
    path = Path(__file__).resolve().parent / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


AUDIT = load_sibling("memory-audit.py", "memory_audit")

MATURITIES = {"candidate", "established", "proven"}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")
BODY_MIN, BODY_MAX = 80, 8000
DESC_MIN, DESC_MAX = 20, 200
DISPOSITIONS = frozenset({"notes", "no-durable-knowledge"})
REASON_CODES = frozenset(
    {
        "bad_slug",
        "name_collision",
        "bad_type",
        "description_length",
        "body_length",
        "confidence_out_of_range",
        "frontmatter_newline",
        "source_session_not_string",
        "source_session_control_characters",
        "source_session_whitespace",
        "source_session_extension",
        "unknown_source_session",
        "credential_looking_content",
        "near_duplicate",
    }
)
BENIGN_REJECTION_CODES = frozenset({"near_duplicate"})

MANIFEST_KEYS = frozenset({"schema_version", "store", "sessions"})
MANIFEST_SESSION_KEYS = frozenset(
    {"source_session", "source_path", "sha256", "size", "mtime"}
)
MANIFEST_CANDIDATE_KEYS = frozenset({"schema_version", "sessions"})
MANIFEST_CANDIDATE_SESSION_KEYS = frozenset(
    {"source_session", "disposition", "reason", "notes"}
)
MANIFEST_ACCEPTED_KEYS = frozenset(
    {"schema_version", "store", "processed_sessions", "accepted", "rejected"}
)
PROCESSED_SESSION_KEYS = frozenset({"source_session", "disposition"})
MANIFEST_REJECTION_KEYS = frozenset({"name", "source_session", "reason_code", "reason"})


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    obj: dict[str, Any] = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"duplicate JSON key {key!r}")
        obj[key] = value
    return obj


def read_json(path: Path, label: str, *, strict: bool = False) -> Any:
    """Read JSON with concise failures; strict mode also rejects duplicate keys."""
    try:
        text = path.read_text()
        if strict:
            return json.loads(text, object_pairs_hook=_unique_json_object)
        return json.loads(text)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        die(f"{label} is not valid JSON: {error}")


def require_exact_keys(
    value: dict[str, Any], expected: frozenset[str], label: str
) -> None:
    actual = set(value)
    if actual == expected:
        return
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    details = []
    if missing:
        details.append(f"missing {missing}")
    if extra:
        details.append(f"extra {extra}")
    die(f"{label} has invalid fields ({'; '.join(details)})")


def _is_plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _session_basename(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        die(f"{label} must be a non-empty string")
    if re.search(r"[\x00-\x20\x7f]", value):
        die(f"{label} must not contain whitespace or control characters")
    if "/" in value or "\\" in value or Path(value).name != value:
        die(f"{label} must be a basename")
    if not value.endswith(".jsonl"):
        die(f"{label} must end in .jsonl")
    return value


def _sha256_fd(fd: int) -> str:
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while chunk := os.read(fd, 1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path, store: Path) -> dict[str, Any]:
    """Load and authenticate a frozen source batch before validate/apply."""
    data = read_json(path, "manifest", strict=True)
    if not isinstance(data, dict):
        die("manifest must be a JSON object")
    require_exact_keys(data, MANIFEST_KEYS, "manifest")
    if not _is_plain_int(data["schema_version"]) or data["schema_version"] != 1:
        die("manifest schema_version must be integer 1")
    if not isinstance(data["store"], str) or not data["store"]:
        die("manifest store must be a non-empty string")

    resolved_store = store.expanduser().resolve()
    if Path(data["store"]).expanduser().resolve() != resolved_store:
        die("manifest store does not resolve to --store")
    if not isinstance(data["sessions"], list):
        die("manifest sessions must be a list")

    sessions: dict[str, dict[str, Any]] = {}
    for position, session in enumerate(data["sessions"]):
        label = f"manifest sessions[{position}]"
        if not isinstance(session, dict):
            die(f"{label} must be an object")
        require_exact_keys(session, MANIFEST_SESSION_KEYS, label)
        source_session = _session_basename(
            session["source_session"], f"{label}.source_session"
        )
        if source_session in sessions:
            die(f"manifest has duplicate source_session {source_session!r}")
        source_path_raw = session["source_path"]
        if not isinstance(source_path_raw, str) or not source_path_raw:
            die(f"{label}.source_path must be a non-empty string")
        source_path = Path(source_path_raw).expanduser()
        if not source_path.is_absolute():
            die(f"{label}.source_path must be absolute")
        if source_path.name != source_session:
            die(f"{label}.source_path basename does not match source_session")
        expected_sha = session["sha256"]
        if not isinstance(expected_sha, str) or not re.fullmatch(
            r"[0-9a-f]{64}", expected_sha
        ):
            die(f"{label}.sha256 must be 64 lowercase hexadecimal characters")
        if not _is_plain_int(session["size"]) or session["size"] < 0:
            die(f"{label}.size must be a non-negative integer")
        if not _is_plain_int(session["mtime"]) or session["mtime"] < 0:
            die(f"{label}.mtime must be a non-negative integer")

        try:
            source_fd = os.open(
                source_path,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                before = os.fstat(source_fd)
                if not stat.S_ISREG(before.st_mode):
                    die(
                        f"{label}.source_path must be an existing regular "
                        "non-symlink file"
                    )
                actual_sha = _sha256_fd(source_fd)
                after = os.fstat(source_fd)
            finally:
                os.close(source_fd)
        except OSError as error:
            die(f"cannot authenticate {label}.source_path: {error}")
        identity_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        )
        identity_after = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        )
        if identity_before != identity_after:
            die(f"{label}.source_path changed while being authenticated")
        if session["size"] != after.st_size:
            die(f"{label}.size does not match source_path")
        if session["mtime"] != int(after.st_mtime):
            die(f"{label}.mtime does not match source_path")
        if expected_sha != actual_sha:
            die(f"{label}.sha256 does not match source_path")
        sessions[source_session] = {
            **session,
            "source_path": source_path_raw,
        }

    return {
        "schema_version": 1,
        "store": str(resolved_store),
        "sessions": sessions,
    }


def atomic_private_json(path: Path, payload: Any, *, indent: int = 2) -> None:
    """Atomically replace a JSON file with a private, fsync'd sibling temp."""
    fd = -1
    tmp_path: Path | None = None
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
        tmp_path = Path(tmp_name)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            fd = -1
            json.dump(payload, output, indent=indent)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(tmp_path, path)
        tmp_path = None
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_path is not None:
            with contextlib.suppress(OSError):
                tmp_path.unlink()


@contextlib.contextmanager
def store_lock(store: Path):
    """Per-store lock guarding concurrent `apply` runs: an advisory fcntl.flock
    held on an open fd for the ENTIRE apply, non-blocking acquire.

    The prior design (create a lockfile with O_EXCL, unlink-and-retry once it
    looked "stale") had an ABA race: two processes could both observe the same
    old lock as stale, one unlinks it and creates its replacement, and the
    other — already past its own staleness check — unlinks THAT replacement
    and creates its own, so both proceed to mutate the index/ledger
    concurrently. flock has no such window: it is scoped to the open fd, not
    the path, so a second process can never unlink its way past a live
    holder's lock. It is also released automatically by the kernel if the
    holding process dies, so a leftover lock file from a crashed apply never
    needs manual staleness/reclamation logic at all — only a still-running
    holder blocks."""
    lock_path = store / ".mine-apply.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            try:
                holder = os.read(fd, 4096).decode("utf-8", errors="replace").strip()
            except OSError:
                holder = ""
            print(
                f"ERROR: another `apply` is already running for {store} "
                f"(held by: {holder or 'unknown'})",
                file=sys.stderr,
            )
            sys.exit(2)
        os.ftruncate(fd, 0)
        os.write(fd, f"pid={os.getpid()} at={time.time()}\n".encode("utf-8"))
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


def mined_state(store: Path) -> set[str]:
    """Session paths already captured into this store: the .mined-sessions.json
    ledger plus every note's mined_from filename (survives ledger loss)."""
    done: set[str] = set()
    ledger = store / ".mined-sessions.json"
    if ledger.exists():
        try:
            done.update(json.loads(ledger.read_text()))
        except json.JSONDecodeError:
            pass
    for p in store.glob("*.md"):
        m = re.search(
            r"^\s+mined_from:\s*(\S+\.jsonl)\s*$",
            p.read_text(errors="replace")[:2000],
            re.M,
        )
        if m:
            done.add(m.group(1))
    return done


def candidate_session_files(
    project_dir: Path, cutoff: float, min_bytes: int
) -> list[Path]:
    """Claude Code session jsonl files for a project: the canonical project dir
    PLUS sibling `<slug>--claude-worktrees-*` dirs (one per active git worktree),
    fresh and large enough to matter.

    Single shared discovery routine for cmd_inventory (candidate list) and
    cmd_staleness (freshness gate) — staleness used to scan only the canonical
    dir, so a project whose recent activity lived entirely in worktrees was
    reported fresh forever and the scheduled miner never ran for it."""
    roots = [project_dir]
    roots += sorted(project_dir.parent.glob(project_dir.name + "--claude-worktrees-*"))
    found: list[Path] = []
    for root in roots:
        for p in root.glob("*.jsonl"):
            st = p.stat()
            if st.st_mtime >= cutoff and st.st_size > min_bytes:
                found.append(p)
    return found


def known_session_files(store: Path) -> set[str]:
    """Basenames of real session files this store's project could legitimately
    be mined from: the store's project dir (store.parent) plus sibling
    `<slug>--claude-worktrees-*` dirs, via candidate_session_files() — the same
    discovery routine cmd_inventory and cmd_staleness use.

    No freshness/size gate (cutoff=0, min_bytes=-1): inventory's --days and
    --min-bytes only decide what gets OFFERED for mining on a given pass, not
    what a drafter-supplied source_session may legitimately name. Validation
    must recognize every real session file for this project, not just the
    ones that happened to be fresh/large enough to appear in one inventory
    run — otherwise a legitimate but older session would fail authentication."""
    return {
        p.name for p in candidate_session_files(store.parent, cutoff=0, min_bytes=-1)
    }


def cmd_inventory(args: argparse.Namespace) -> None:
    """Candidate sessions for a project: claude_code jsonl files (incl. worktree
    project dirs) plus, with --workspace, cross-agent sessions via cass."""
    now = time.time()
    cutoff = now - args.days * 86400
    settled_seconds = getattr(args, "settled_seconds", 0)
    settled_before = now - settled_seconds
    max_bytes = getattr(args, "max_bytes", None)
    seen: dict[str, dict] = {}
    for p in candidate_session_files(Path(args.project_dir), cutoff, args.min_bytes):
        st = p.stat()
        if settled_seconds and st.st_mtime > settled_before:
            continue
        if max_bytes is not None and st.st_size > max_bytes:
            continue
        seen[str(p)] = {
            "path": str(p),
            "mtime": int(st.st_mtime),
            "bytes": st.st_size,
            "agent": "claude_code",
        }
    if args.workspace:
        import subprocess

        try:
            r = subprocess.run(
                [
                    "cass",
                    "search",
                    "",
                    "--workspace",
                    args.workspace,
                    "--robot-format",
                    "sessions",
                    "--limit",
                    "200",
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line or line in seen:
                    continue
                p = Path(line)
                if p.exists():
                    st = p.stat()
                    if (
                        st.st_mtime >= cutoff
                        and st.st_size > args.min_bytes
                        and (max_bytes is None or st.st_size <= max_bytes)
                        and (not settled_seconds or st.st_mtime <= settled_before)
                    ):
                        seen[line] = {
                            "path": line,
                            "mtime": int(st.st_mtime),
                            "bytes": st.st_size,
                            "agent": "cass",
                        }
        except Exception as e:  # cass optional: inventory degrades, never fails
            print(f"WARN: cass sweep skipped: {e}", file=sys.stderr)
    exclude = mined_state(Path(args.store)) if args.store else set()
    out = [
        v
        for v in seen.values()
        if v["path"] not in exclude and Path(v["path"]).name not in exclude
    ]
    if getattr(args, "oldest_first", False):
        out.sort(key=lambda v: (v["mtime"], v["path"]))
    else:
        out.sort(key=lambda v: (-v["mtime"], v["path"]))
    eligible_count = len(out)
    limit = getattr(args, "limit", None)
    if limit is not None:
        out = out[:limit]
    Path(args.out).write_text(json.dumps({"sessions": out}, indent=2))
    print(
        f"{len(out)} candidate sessions ({len(seen) - eligible_count} already mined, "
        f"{sum(1 for v in out if v['agent'] != 'claude_code')} cross-agent)"
    )


def cmd_staleness(args: argparse.Namespace) -> None:
    """For harness-weekly: which live stores have unmined recent sessions?
    Exit 0 always; text mode preserves the scheduler-facing legacy format."""
    projects_root = Path.home() / ".claude/projects"
    cutoff = time.time() - args.days * 86400
    stale = []
    for store in sorted(projects_root.glob("*/memory")):
        proj_dir = store.parent
        if (
            proj_dir.name.endswith("-worktrees")
            or "--claude-worktrees-" in proj_dir.name
        ):
            continue
        # Same discovery routine cmd_inventory uses (canonical dir + sibling
        # worktree dirs), applying the CANONICAL store's mined ledger: a project
        # whose recent activity lives entirely in worktree sessions must still
        # be flagged, not silently reported fresh forever.
        done = mined_state(store)
        fresh = [
            p
            for p in candidate_session_files(proj_dir, cutoff, args.min_bytes)
            if str(p) not in done and p.name not in done
        ]
        if len(fresh) >= args.threshold:
            stale.append((proj_dir.name, len(fresh)))
    if getattr(args, "json", False):
        print(
            json.dumps(
                {
                    "stale": [
                        {"project": project, "unmined_sessions": count}
                        for project, count in stale
                    ]
                },
                indent=2,
            )
        )
    elif stale:
        for project, count in stale:
            print(f"STALE: {project} {count} unmined sessions (last {args.days}d)")
    else:
        print("capture fresh: no store has unmined recent sessions")


def validate_record(
    c: dict[str, Any],
    existing_names: set[str],
    seen_names: set[str],
    existing_desc_tokens: list[set[str]],
    known_sessions: set[str],
) -> tuple[dict[str, Any] | None, str | None]:
    """Deterministic accept/reject gate for one candidate record: (record, None)
    on accept, (None, reason) on reject.

    Shared by cmd_validate (first pass over drafter output) AND cmd_apply
    (re-run at the write boundary): validation and application are separate
    commands, and an --accepted file can be stale, hand-edited, or replayed
    against a store that has moved on since it was produced. apply is the only
    writer and must not trust the upstream validate pass alone (P1: an
    unvalidated record's name previously reached the filesystem unchecked).

    known_sessions (from known_session_files(store)) authenticates
    source_session: it is drafter/model-produced and otherwise untrusted, so
    without this check a prompt-steered candidate could claim ANY known
    session's filename (not just the one it was actually given). Once written,
    that filename enters the mined ledger and retires the real session from
    future inventory without its knowledge ever being captured."""
    name = str(c.get("name", "")).strip()
    desc = str(c.get("description", "")).strip()
    body = str(c.get("body", "")).strip()
    typ = str(c.get("type", "")).strip()
    conf = c.get("confidence")
    source_session_raw = c.get("source_session", "")
    reason = None
    if not SLUG_RE.match(name):
        reason = f"bad slug {name!r}"
    elif name in existing_names or name in seen_names:
        reason = f"name collision {name!r}"
    elif typ not in AUDIT.ALLOWED_TYPES:
        reason = f"bad type {typ!r}"
    elif not (DESC_MIN <= len(desc) <= DESC_MAX):
        reason = f"description length {len(desc)}"
    elif not (BODY_MIN <= len(body) <= BODY_MAX):
        reason = f"body length {len(body)}"
    elif not isinstance(conf, (int, float)) or not (0.0 < float(conf) <= 1.0):
        reason = "confidence not in (0,1]"
    elif "\n" in desc or "\n" in name or "\n" in typ:
        # Frontmatter-bound fields: an embedded newline could break out of the
        # YAML block (e.g. inject a bogus `---` + fake keys) once written by
        # cmd_apply. Reject at the gate rather than relying solely on the
        # whitespace-flattening done at write time (defense in depth).
        reason = "embedded newline in frontmatter field"
    elif not isinstance(source_session_raw, str):
        reason = "source_session not a string"
    elif source_session_raw and re.search(r"[\x00-\x1f\x7f]", source_session_raw):
        # mined_from is written verbatim into the note's YAML frontmatter. A
        # drafter-supplied source_session containing a newline (or other
        # control character) could otherwise close the frontmatter block early
        # and inject unscanned attacker content (e.g. "s.jsonl\n---\nname:
        # evil\n---\n..."), bypassing the deterministic body/credential gates
        # entirely. Path(...).name does NOT strip embedded newlines from a
        # component with no "/" in it, so this must be rejected outright here
        # rather than "sanitized" by the .name flattening applied below.
        reason = "source_session contains control characters"
    elif source_session_raw and re.search(r"\s", source_session_raw):
        # A drafter-echoed session path must be byte-identical to a real
        # inventory entry. Accepting internal whitespace and silently
        # collapsing it at write time (mirroring the whitespace-flattening
        # applied to name/type/description) would let accepted.json's
        # source_session and the note's on-disk mined_from diverge — and
        # retry recovery's identity check (_own_mined_from == expected)
        # compares that exact value. Reject outright instead of
        # "sanitizing": no accept-then-collapse.
        reason = "source_session contains whitespace"
    elif source_session_raw and not source_session_raw.endswith(".jsonl"):
        reason = "source_session must be a *.jsonl filename"
    elif source_session_raw and Path(source_session_raw).name not in known_sessions:
        reason = "unknown source_session"
    elif re.search(
        r"(api[_-]?key|secret|token|password)\s*[:=]\s*\S{8,}", body, re.I
    ) or any(pattern.search(body) for pattern in AUDIT.CONTENT_SIGNATURES):
        reason = "credential-looking content"
    else:
        # Containment ratio (inter / |desc tokens|), not AUDIT.description_similarity's
        # Jaccard (inter / union): a short new description that's fully covered by an
        # existing longer index line should still be flagged as near-duplicate, which
        # Jaccard would dilute. Deliberate divergence, not an oversight.
        dtok = AUDIT.content_tokens(desc)
        for etok in existing_desc_tokens:
            inter = len(dtok & etok)
            if dtok and etok and inter / max(len(dtok), 1) > 0.75:
                reason = "near-duplicate of existing index line"
                break
    if reason:
        return None, reason
    # Flatten to a bare filename: control characters/newlines were already
    # rejected above, but a directory component (e.g. "../../x.jsonl") is not
    # a frontmatter-injection risk, just noise — Path(...).name normalizes it
    # to the basename the same way the write boundary and retry-recovery
    # comparison already treat source_session.
    safe_source_session = Path(source_session_raw).name if source_session_raw else ""
    return {
        "name": name,
        "description": desc,
        "type": typ,
        "body": body,
        "confidence": round(float(conf), 2),
        "source_session": safe_source_session,
    }, None


def validation_reason_code(reason: str) -> str:
    """Map every human-readable validation failure onto a closed stable code."""
    if reason.startswith("bad slug "):
        return "bad_slug"
    if reason.startswith("name collision "):
        return "name_collision"
    if reason.startswith("bad type "):
        return "bad_type"
    if reason.startswith("description length "):
        return "description_length"
    if reason.startswith("body length "):
        return "body_length"
    exact = {
        "confidence not in (0,1]": "confidence_out_of_range",
        "embedded newline in frontmatter field": "frontmatter_newline",
        "source_session not a string": "source_session_not_string",
        "source_session contains control characters": "source_session_control_characters",
        "source_session contains whitespace": "source_session_whitespace",
        "source_session must be a *.jsonl filename": "source_session_extension",
        "unknown source_session": "unknown_source_session",
        "credential-looking content": "credential_looking_content",
        "near-duplicate of existing index line": "near_duplicate",
    }
    code = exact.get(reason)
    if code is None or code not in REASON_CODES:
        raise AssertionError(f"unclassified validation reason: {reason}")
    return code


def _require_exact_session_set(
    actual: set[str], expected: set[str], label: str
) -> None:
    if actual == expected:
        return
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    details = []
    if missing:
        details.append(f"missing {missing}")
    if extra:
        details.append(f"extraneous {extra}")
    die(f"{label} does not match manifest ({'; '.join(details)})")


def manifest_candidates(
    data: Any, manifest: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """Validate the drafter's exact session envelope and flatten its notes."""
    if not isinstance(data, dict):
        die("manifest-mode candidates must be an object")
    require_exact_keys(data, MANIFEST_CANDIDATE_KEYS, "candidates")
    if not _is_plain_int(data["schema_version"]) or data["schema_version"] != 1:
        die("candidates schema_version must be integer 1")
    if not isinstance(data["sessions"], list):
        die("candidates sessions must be a list")

    expected = set(manifest["sessions"])
    actual: set[str] = set()
    notes: list[dict[str, Any]] = []
    processed: list[dict[str, str]] = []
    for position, session in enumerate(data["sessions"]):
        label = f"candidates sessions[{position}]"
        if not isinstance(session, dict):
            die(f"{label} must be an object")
        require_exact_keys(session, MANIFEST_CANDIDATE_SESSION_KEYS, label)
        source_session = _session_basename(
            session["source_session"], f"{label}.source_session"
        )
        if source_session in actual:
            die(f"candidates has duplicate source_session {source_session!r}")
        actual.add(source_session)
        disposition = session["disposition"]
        if not isinstance(disposition, str) or disposition not in DISPOSITIONS:
            die(f"{label}.disposition must be one of {sorted(DISPOSITIONS)}")
        reason = session["reason"]
        if not isinstance(reason, str) or not reason.strip():
            die(f"{label}.reason must be a non-empty string")
        session_notes = session["notes"]
        if not isinstance(session_notes, list):
            die(f"{label}.notes must be a list")
        if disposition == "notes" and not (1 <= len(session_notes) <= 6):
            die(f"{label} with notes disposition must contain 1-6 notes")
        if disposition == "no-durable-knowledge" and session_notes:
            die(f"{label} with no-durable-knowledge disposition must contain no notes")
        for note_position, note in enumerate(session_notes):
            note_label = f"{label}.notes[{note_position}]"
            if not isinstance(note, dict):
                die(f"{note_label} must be an object")
            if note.get("source_session") != source_session:
                die(f"{note_label}.source_session must exactly match its session")
            notes.append(note)
        processed.append({"source_session": source_session, "disposition": disposition})
    _require_exact_session_set(actual, expected, "candidate session set")
    return notes, processed


def cmd_validate(args: argparse.Namespace) -> None:
    store = Path(args.store)
    manifest_path = getattr(args, "manifest", "")
    manifest = load_manifest(Path(manifest_path), store) if manifest_path else None
    candidate_data = read_json(
        Path(args.candidates), "candidates", strict=manifest is not None
    )
    processed_sessions: list[dict[str, str]] = []
    if manifest is not None:
        cands, processed_sessions = manifest_candidates(candidate_data, manifest)
        known_sessions = set(manifest["sessions"])
    else:
        if isinstance(candidate_data, dict) and "sessions" in candidate_data:
            die("session-envelope candidates require --manifest")
        cands = candidate_data
        if isinstance(cands, dict):
            cands = cands.get("notes", [])
        known_sessions = known_session_files(store)
    if not isinstance(cands, list):
        die("candidates notes must be a list")

    existing_names = {p.stem for p in store.glob("*.md")} | {"MEMORY"}
    index_text = (
        (store / "MEMORY.md").read_text(errors="replace")
        if (store / "MEMORY.md").exists()
        else ""
    )
    existing_desc_tokens = [
        AUDIT.content_tokens(line)
        for line in index_text.splitlines()
        if line.strip().startswith(("-", "*"))
    ]

    accepted, rejected = [], []
    seen_names: set[str] = set()
    for c in cands:
        if not isinstance(c, dict):
            die("each candidate note must be an object")
        record, reason = validate_record(
            c, existing_names, seen_names, existing_desc_tokens, known_sessions
        )
        if reason:
            rejection = {
                "name": str(c.get("name", "")).strip() or "?",
                "reason_code": validation_reason_code(reason),
                "reason": reason,
            }
            if manifest is not None:
                rejection["source_session"] = c["source_session"]
            rejected.append(rejection)
        else:
            assert record is not None
            seen_names.add(record["name"])
            accepted.append(record)
    output: dict[str, Any] = {"accepted": accepted, "rejected": rejected}
    if manifest is not None:
        output = {
            "schema_version": 1,
            "store": manifest["store"],
            "processed_sessions": processed_sessions,
            **output,
        }
    Path(args.out).write_text(json.dumps(output, indent=2))
    print(f"accepted {len(accepted)}, rejected {len(rejected)}")
    for r in rejected:
        print(f"  reject {r['name']}: {r['reason']}")


def _own_mined_from(fp: Path) -> str:
    """The mined_from filename recorded in an existing note's frontmatter, or ""
    if absent/unparseable. Used to tell a genuine RETRY of this exact record's
    own prior partial write (body written, index/ledger step never completed)
    apart from an unrelated pre-existing note that happens to collide on slug —
    only the former is safe to recover into the index without rewriting the
    body. Parsed via AUDIT.parse_frontmatter (the same nested-metadata-aware
    parser the rest of the harness reads mined_from through) rather than a
    line-oriented \\S+ regex, so a value is read back exactly as written, with
    no independent (and possibly divergent) notion of what counts as the field."""
    metadata, error, _body, _raw = AUDIT.parse_frontmatter(
        fp.read_text(errors="replace")
    )
    if error or not isinstance(metadata, dict):
        return ""
    nested = metadata.get("metadata")
    value = nested.get("mined_from") if isinstance(nested, dict) else None
    return value if isinstance(value, str) else ""


def manifest_accepted_input(
    data: Any, manifest: dict[str, Any], store: Path
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, str]]]:
    """Authenticate validate's store-bound output before apply mutates anything."""
    if not isinstance(data, dict):
        die("manifest-mode accepted input must be an object")
    require_exact_keys(data, MANIFEST_ACCEPTED_KEYS, "accepted input")
    if not _is_plain_int(data["schema_version"]) or data["schema_version"] != 1:
        die("accepted input schema_version must be integer 1")
    if not isinstance(data["store"], str) or not data["store"]:
        die("accepted input store must be a non-empty string")
    if Path(data["store"]).expanduser().resolve() != store.expanduser().resolve():
        die("accepted input belongs to a different store")

    processed = data["processed_sessions"]
    if not isinstance(processed, list):
        die("accepted input processed_sessions must be a list")
    dispositions: dict[str, str] = {}
    normalized_processed: list[dict[str, str]] = []
    for position, item in enumerate(processed):
        label = f"accepted input processed_sessions[{position}]"
        if not isinstance(item, dict):
            die(f"{label} must be an object")
        require_exact_keys(item, PROCESSED_SESSION_KEYS, label)
        source_session = _session_basename(
            item["source_session"], f"{label}.source_session"
        )
        if source_session in dispositions:
            die(f"accepted input has duplicate processed session {source_session!r}")
        disposition = item["disposition"]
        if not isinstance(disposition, str) or disposition not in DISPOSITIONS:
            die(f"{label}.disposition must be one of {sorted(DISPOSITIONS)}")
        dispositions[source_session] = disposition
        normalized_processed.append(
            {"source_session": source_session, "disposition": disposition}
        )
    _require_exact_session_set(
        set(dispositions), set(manifest["sessions"]), "processed session set"
    )

    notes = data["accepted"]
    rejected = data["rejected"]
    if not isinstance(notes, list):
        die("accepted input accepted must be a list")
    if not isinstance(rejected, list):
        die("accepted input rejected must be a list")
    record_counts = {source_session: 0 for source_session in dispositions}
    for position, note in enumerate(notes):
        label = f"accepted input accepted[{position}]"
        if not isinstance(note, dict):
            die(f"{label} must be an object")
        source_session = _session_basename(
            note.get("source_session"), f"{label}.source_session"
        )
        if source_session not in dispositions:
            die(f"{label}.source_session is extraneous to processed_sessions")
        if dispositions[source_session] != "notes":
            die(f"{label} cannot belong to a no-durable-knowledge session")
        record_counts[source_session] += 1
    for position, rejection in enumerate(rejected):
        label = f"accepted input rejected[{position}]"
        if not isinstance(rejection, dict):
            die(f"{label} must be an object")
        require_exact_keys(rejection, MANIFEST_REJECTION_KEYS, label)
        source_session = _session_basename(
            rejection["source_session"], f"{label}.source_session"
        )
        if source_session not in dispositions:
            die(f"{label}.source_session is extraneous to processed_sessions")
        if dispositions[source_session] != "notes":
            die(f"{label} cannot belong to a no-durable-knowledge session")
        if (
            not isinstance(rejection["reason_code"], str)
            or rejection["reason_code"] not in REASON_CODES
        ):
            die(f"{label}.reason_code is not a closed validation reason code")
        if not isinstance(rejection["name"], str) or not isinstance(
            rejection["reason"], str
        ):
            die(f"{label} name and reason must be strings")
        record_counts[source_session] += 1
    for source_session, disposition in dispositions.items():
        if disposition == "notes" and record_counts[source_session] == 0:
            die(f"notes session {source_session!r} has no accepted or rejected notes")
        if disposition == "no-durable-knowledge" and record_counts[source_session] != 0:
            die(f"no-durable-knowledge session {source_session!r} has note records")
    return notes, rejected, normalized_processed


def cmd_apply(args: argparse.Namespace) -> None:
    store = Path(args.store)
    manifest_path = getattr(args, "manifest", "")
    manifest = load_manifest(Path(manifest_path), store) if manifest_path else None
    data = read_json(Path(args.accepted), "accepted input", strict=manifest is not None)
    rejected: list[dict[str, Any]] = []
    processed_sessions: list[dict[str, str]] = []
    if manifest is not None:
        notes, rejected, processed_sessions = manifest_accepted_input(
            data, manifest, store
        )
    else:
        if isinstance(data, dict) and (
            "processed_sessions" in data or "store" in data or "schema_version" in data
        ):
            die("manifest-bound accepted input requires --manifest")
        notes = data.get("accepted", data) if isinstance(data, dict) else data
        if not isinstance(notes, list):
            die("accepted input must be a list or contain an accepted list")

    receipt_arg = getattr(args, "receipt", "")
    receipt = Path(receipt_arg) if receipt_arg else None
    if receipt is not None:
        if not receipt.parent.is_dir():
            die("receipt parent directory does not exist")
        if receipt.exists() and receipt.is_dir():
            die("receipt path is a directory")
        resolved_receipt = receipt.expanduser().resolve()
        resolved_store = store.expanduser().resolve()
        protected_store_paths = {
            resolved_store,
            (store / "MEMORY.md").resolve(),
            (store / ".mined-sessions.json").resolve(),
            (store / ".mine-apply.lock").resolve(),
        }
        protected_store_paths.update(path.resolve() for path in store.glob("*.md"))
        protected_store_paths.update(
            path.resolve() for path in store.glob(".MEMORY.md.pre-mine-*")
        )
        for note in notes:
            raw_name = " ".join(str(note.get("name", "")).split())
            destination = (
                AUDIT.confined_path(store, f"{raw_name}.md") if raw_name else None
            )
            if destination is not None:
                protected_store_paths.add(destination.resolve())
        if resolved_receipt in protected_store_paths:
            die("receipt must not replace a memory store artifact")
        protected_inputs = {Path(args.accepted).expanduser().resolve()}
        if manifest_path:
            protected_inputs.add(Path(manifest_path).expanduser().resolve())
        if manifest is not None:
            protected_inputs.update(
                Path(item["source_path"]).expanduser().resolve()
                for item in manifest["sessions"].values()
            )
        if resolved_receipt in protected_inputs:
            die("receipt must not replace an apply input or source session")

    # Manifest and accepted-output identity checks above are deliberately
    # complete before mkdir, lock-file creation, backup, staging, or ledgering.
    store.mkdir(parents=True, exist_ok=True)
    date = getattr(args, "date", "") or time.strftime("%Y-%m-%d")
    index = store / "MEMORY.md"

    with store_lock(store):
        index_text = index.read_text(errors="replace") if index.exists() else ""
        indexed_targets, _escaping = AUDIT.index_targets(index_text)

        existing_names = {p.stem for p in store.glob("*.md")} | {"MEMORY"}
        existing_desc_tokens = [
            AUDIT.content_tokens(line)
            for line in index_text.splitlines()
            if line.strip().startswith(("-", "*"))
        ]
        known_sessions = (
            set(manifest["sessions"])
            if manifest is not None
            else known_session_files(store)
        )

        dispositions = {
            item["source_session"]: item["disposition"] for item in processed_sessions
        }
        upstream_failed_sessions = {
            item["source_session"]
            for item in rejected
            if item["reason_code"] not in BENIGN_REJECTION_CODES
        }
        failed_sessions = set(upstream_failed_sessions)
        failed_note_positions: set[int] = set()
        note_positions_by_session: dict[str, set[int]] = {}
        if manifest is not None:
            for position, note in enumerate(notes):
                note_positions_by_session.setdefault(note["source_session"], set()).add(
                    position
                )

        # Classification pass: for every record, decide whether it's a brand-new
        # note to write, a RETRY recovery (body already on disk from a crashed
        # prior apply, index line still missing), or a genuine reject/skip. No
        # filesystem mutation happens in this pass.
        seen_names: set[str] = set()
        to_write: list[dict[str, Any]] = []
        to_recover: list[dict[str, Any]] = []
        already_applied: list[dict[str, Any]] = []
        for position, n in enumerate(notes):
            source_session = n.get("source_session", "")
            if manifest is not None and source_session in failed_sessions:
                failed_note_positions.add(position)
                print(f"skip (session has rejected note): {source_session}")
                continue
            raw_name = " ".join(str(n.get("name", "")).split())
            # Re-run the FULL validation gate (P1: apply must not trust the
            # --accepted file alone) AND independently confine the destination
            # beneath the store, resolving symlinks: two checks so a bug in
            # either alone cannot reopen the path-escape.
            dest = AUDIT.confined_path(store, f"{raw_name}.md") if raw_name else None
            if dest is None:
                print(f"skip (invalid path): {raw_name or '?'}")
                failed_note_positions.add(position)
                if manifest is not None:
                    failed_sessions.add(source_session)
                continue
            if dest.is_symlink():
                print(f"skip (symlink, refusing to follow): {dest.name}")
                failed_note_positions.add(position)
                if manifest is not None:
                    failed_sessions.add(source_session)
                continue
            if dest.exists():
                if not dest.is_file():
                    print(f"skip (not a regular file): {dest.name}")
                    failed_note_positions.add(position)
                    if manifest is not None:
                        failed_sessions.add(source_session)
                    continue
                expected = (
                    Path(source_session).name
                    if isinstance(source_session, str) and source_session
                    else ""
                )
                if expected and _own_mined_from(dest) == expected:
                    # Retry: this exact record's body already landed; only the
                    # index line (and, transitively, the ledger) is missing.
                    if dest.name in indexed_targets:
                        if manifest is not None:
                            already_applied.append(
                                {
                                    "name": raw_name,
                                    "source_session": source_session,
                                    "_input_position": position,
                                }
                            )
                        continue  # already fully applied in a prior run: nothing to do
                    _fm_name, desc = AUDIT.frontmatter_entry(
                        dest.read_text(errors="replace"), dest.name
                    )
                    seen_names.add(raw_name)
                    to_recover.append(
                        {
                            "name": raw_name,
                            "description": desc,
                            "source_session": source_session,
                            "_input_position": position,
                        }
                    )
                else:
                    # Unrelated pre-existing note colliding on slug: never overwritten.
                    print(f"skip (exists): {dest.name}")
                    failed_note_positions.add(position)
                    if manifest is not None:
                        failed_sessions.add(source_session)
                continue
            record, reason = validate_record(
                n, existing_names, seen_names, existing_desc_tokens, known_sessions
            )
            if reason:
                print(f"skip (invalid): {raw_name or '?'}: {reason}")
                failed_note_positions.add(position)
                if manifest is not None:
                    failed_sessions.add(source_session)
                continue
            assert record is not None
            seen_names.add(record["name"])
            to_write.append({**record, "_dest": dest, "_input_position": position})

        if manifest is not None:
            for source_session in failed_sessions:
                failed_note_positions.update(
                    note_positions_by_session.get(source_session, set())
                )
            to_write = [
                rec for rec in to_write if rec["source_session"] not in failed_sessions
            ]
            to_recover = [
                rec
                for rec in to_recover
                if rec["source_session"] not in failed_sessions
            ]
            already_applied = [
                rec
                for rec in already_applied
                if rec["source_session"] not in failed_sessions
            ]

        if index.exists():
            backup = store / f".MEMORY.md.pre-mine-{time.strftime('%Y%m%d%H%M%S')}"
            backup.write_text(index_text)

        # Phase 1: stage EVERY new note's body in a tmp file first, alongside its
        # final name in the store (so the commit in phase 1b below is a same-
        # filesystem rename/link, not a cross-device copy). A tmp file's name
        # never matches the store's "*.md" glob, so mined_state() and every
        # other reader treat it as invisible until phase 1b commits it. Only
        # once EVERY body in this batch is confirmed staged does any of them
        # become visible under its final name — closes the gap where a kill or
        # I/O failure after one final-path write, but before the rest of the
        # batch or the index/ledger step, let inventory treat the whole source
        # session as mined and silently suppress its still-missing siblings.
        # On any staging failure, every tmp file written so far is unlinked and
        # the whole apply aborts before anything becomes visible.
        staged: list[dict[str, Any]] = []
        for rec in to_write:
            fp = rec["_dest"]
            # Flatten whitespace (incl. embedded newlines) on every frontmatter-bound
            # field right before writing, mirroring memory-audit.py's
            # redescribe_content(): validate-time gates are a first line of defense,
            # but the write boundary itself must not trust upstream checks alone.
            name = " ".join(str(rec["name"]).split())
            typ = " ".join(str(rec["type"]).split())
            desc = " ".join(str(rec["description"]).split()).replace('"', "'")
            # No further normalization here (unlike name/type/desc above):
            # validate_record already rejected any whitespace and authenticated
            # this value against the real session inventory, so rewriting it
            # again would risk producing a value that no longer matches what
            # was actually validated. Write the exact validated value.
            mined_from = rec.get("source_session", "")
            body_text = (
                "---\n"
                f"name: {name}\n"
                f'description: "{desc}"\n'
                "metadata:\n"
                f"  type: {typ}\n"
                f"  confidence: {rec['confidence']}\n"
                "  maturity: candidate\n"
                f"  last_validated: {date}\n"
                f"  mined_from: {mined_from}\n"
                "---\n\n"
                f"{rec['body']}\n"
            )
            tmp = fp.with_name(f"{fp.name}.tmp-{os.getpid()}")
            try:
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(body_text)
            except OSError as error:
                print(
                    f"ERROR: staging {fp.name} failed ({error}); aborting batch, "
                    "nothing written",
                    file=sys.stderr,
                )
                for prior in staged:
                    with contextlib.suppress(OSError):
                        prior["_tmp"].unlink()
                with contextlib.suppress(OSError):
                    tmp.unlink()
                sys.exit(1)
            staged.append({**rec, "name": name, "description": desc, "_tmp": tmp})

        # Phase 1b: every body in the batch staged successfully — commit each
        # into its final name. A hard link, not os.rename (which silently
        # overwrites an existing destination), keeps "refuse pre-existing
        # finals" atomic: it fails with FileExistsError instead of clobbering
        # anything a TOCTOU race placed at dest since the classification pass,
        # while the visible commit itself is still a single atomic op.
        written_records: list[dict[str, Any]] = []
        raced_sessions: set[str] = set()
        for commit_position, rec in enumerate(staged):
            fp = rec["_dest"]
            tmp = rec.pop("_tmp")
            try:
                os.link(tmp, fp)
            except FileExistsError:
                print(f"skip (race, now exists): {fp.name}")
                failed_note_positions.add(rec["_input_position"])
                if manifest is not None:
                    raced_sessions.add(rec["source_session"])
                continue
            except OSError as error:
                cleanup_errors = []
                for prior in written_records:
                    try:
                        prior["_dest"].unlink()
                    except OSError as cleanup_error:
                        cleanup_errors.append(str(cleanup_error))
                for remaining in staged[commit_position + 1 :]:
                    try:
                        remaining["_tmp"].unlink()
                    except OSError as cleanup_error:
                        cleanup_errors.append(str(cleanup_error))
                print(
                    f"ERROR: committing {fp.name} failed ({error}); aborting "
                    "batch, nothing written",
                    file=sys.stderr,
                )
                if cleanup_errors:
                    print(
                        "ERROR: commit rollback was incomplete: "
                        + "; ".join(cleanup_errors),
                        file=sys.stderr,
                    )
                sys.exit(1)
            finally:
                with contextlib.suppress(OSError):
                    tmp.unlink()
            written_records.append(rec)

        if manifest is not None and raced_sessions:
            failed_sessions.update(raced_sessions)
            for source_session in raced_sessions:
                failed_note_positions.update(
                    note_positions_by_session.get(source_session, set())
                )
            kept_written = []
            for rec in written_records:
                if rec["source_session"] in raced_sessions:
                    with contextlib.suppress(OSError):
                        rec["_dest"].unlink()
                else:
                    kept_written.append(rec)
            written_records = kept_written
            to_recover = [
                rec for rec in to_recover if rec["source_session"] not in raced_sessions
            ]
            already_applied = [
                rec
                for rec in already_applied
                if rec["source_session"] not in raced_sessions
            ]

        # Phase 2: index lines for everything written OR recovered this run —
        # never interleaved with body writes, so a crash mid-loop cannot leave a
        # body written with no corresponding index line queued.
        lines = []
        for rec in written_records:
            title = rec["name"].replace("-", " ").capitalize()
            lines.append(f"- [{title}]({rec['name']}.md) — {rec['description']}")
        for rec in to_recover:
            title = rec["name"].replace("-", " ").capitalize()
            lines.append(f"- [{title}]({rec['name']}.md) — {rec['description']}")
        if lines:
            with index.open("a") as f:
                f.write("\n" + "\n".join(lines) + "\n")

        # Phase 3: ledger, last. Legacy mode retains its exact written/recovered
        # semantics. Manifest mode additionally records successful no-note
        # dispositions and requires every note for a source to be durable.
        ledger = store / ".mined-sessions.json"
        done = mined_state(store)
        if manifest is not None:
            completed_positions = {
                rec["_input_position"]
                for rec in (*written_records, *to_recover, *already_applied)
            }
            ledgered_sessions = {
                source_session
                for source_session, disposition in dispositions.items()
                if source_session not in failed_sessions
                and (
                    disposition == "no-durable-knowledge"
                    or note_positions_by_session.get(source_session, set())
                    <= completed_positions
                )
            }
            # Ledger history is monotonic: this attempt may add newly proven
            # successes, but a later failed replay must not erase an earlier
            # successful capture claim.
            done.update(ledgered_sessions)
        else:
            ledgered_sessions = {
                rec["source_session"]
                for rec in (*written_records, *to_recover)
                if rec.get("source_session")
            }
            done.update(ledgered_sessions)
        done.discard("")
        atomic_private_json(ledger, sorted(done), indent=1)

        if receipt is not None:
            atomic_private_json(
                receipt,
                {
                    "processed": (
                        len(processed_sessions) if manifest is not None else len(notes)
                    ),
                    "accepted": len(notes) - len(failed_note_positions),
                    "rejected": len(rejected) + len(failed_note_positions),
                    "written": len(written_records),
                    "recovered": len(to_recover),
                    "indexed": len(lines),
                    "ledgered": len(ledgered_sessions),
                },
            )
        print(
            f"wrote {len(written_records)} notes + {len(lines)} index lines "
            f"({len(to_recover)} recovered from a prior partial apply) to {store}"
        )


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("inventory")
    i.add_argument("--project-dir", required=True)
    i.add_argument("--days", type=int, default=14)
    i.add_argument("--min-bytes", type=int, default=20000)
    i.add_argument("--max-bytes", type=positive_int)
    i.add_argument("--out", required=True)
    i.add_argument("--workspace", default="")
    i.add_argument("--store", default="")
    i.add_argument("--limit", type=positive_int)
    i.add_argument("--settled-seconds", type=nonnegative_int, default=0)
    i.add_argument("--oldest-first", action="store_true")
    s2 = sub.add_parser("staleness")
    s2.add_argument("--days", type=int, default=14)
    s2.add_argument("--min-bytes", type=int, default=20000)
    s2.add_argument("--threshold", type=int, default=3)
    s2.add_argument("--json", action="store_true")
    v = sub.add_parser("validate")
    v.add_argument("--candidates", required=True)
    v.add_argument("--store", required=True)
    v.add_argument("--out", required=True)
    v.add_argument("--manifest", default="")
    a = sub.add_parser("apply")
    a.add_argument("--accepted", required=True)
    a.add_argument("--store", required=True)
    a.add_argument("--date", default="")
    a.add_argument("--manifest", default="")
    a.add_argument("--receipt", default="")
    args = ap.parse_args()
    {
        "inventory": cmd_inventory,
        "validate": cmd_validate,
        "apply": cmd_apply,
        "staleness": cmd_staleness,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
