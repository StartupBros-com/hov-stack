#!/usr/bin/env python3

import argparse
import builtins
import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

CLAUDE = Path(__file__).resolve().parents[1]
MINE = CLAUDE / "scripts" / "memory-mine.py"
DRAFTER = CLAUDE / "agents" / "memory-mine-drafter.md"
SKILL = CLAUDE / "skills-stack" / "memory-mine" / "SKILL.md"

_spec = importlib.util.spec_from_file_location("memory_mine", MINE)
MM = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(MM)

GOOD_DESC = "A fixture description long enough to pass the length gate cleanly"
GOOD_BODY = (
    "Fixture body content sufficient to clear the minimum body length gate. " * 2
)


def candidate(
    name="new-note",
    description=GOOD_DESC,
    body=GOOD_BODY,
    note_type="project",
    confidence=0.8,
    source_session="",
):
    return {
        "name": name,
        "description": description,
        "body": body,
        "type": note_type,
        "confidence": confidence,
        "source_session": source_session,
    }


def manifest_session(path: Path):
    file_stat = path.stat()
    return {
        "source_session": path.name,
        "source_path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": file_stat.st_size,
        "mtime": int(file_stat.st_mtime),
    }


def session_result(
    source_session, disposition="notes", notes=None, reason="Processed safely."
):
    return {
        "source_session": source_session,
        "disposition": disposition,
        "reason": reason,
        "notes": notes or [],
    }


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.store = root / "store"
        self.store.mkdir()

    def add_session(self, filename: str, size: int = 100) -> Path:
        """Create a real session .jsonl file in the store's project dir
        (store.parent == self.root), so a candidate's source_session naming
        it passes known_session_files() authentication."""
        path = self.root / filename
        path.write_text("x" * size)
        return path

    def run(self, *args):
        return subprocess.run(
            ["python3", str(MINE), *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def validate(self, cands, out_name="validated.json"):
        cpath = self.root / "candidates.json"
        cpath.write_text(json.dumps({"notes": cands}))
        out = self.root / out_name
        result = self.run(
            "validate",
            "--candidates",
            str(cpath),
            "--store",
            str(self.store),
            "--out",
            str(out),
        )
        payload = json.loads(out.read_text())
        return result, payload

    def make_manifest(self, sessions, store=None, name="manifest.json"):
        payload = {
            "schema_version": 1,
            "store": str((store or self.store).resolve()),
            "sessions": [manifest_session(session) for session in sessions],
        }
        path = self.root / name
        path.write_text(json.dumps(payload))
        return path, payload

    def validate_manifest(self, payload, manifest, out_name="validated-manifest.json"):
        candidates = self.root / f"candidates-{out_name}"
        candidates.write_text(json.dumps(payload))
        out = self.root / out_name
        result = self.run(
            "validate",
            "--candidates",
            str(candidates),
            "--store",
            str(self.store),
            "--manifest",
            str(manifest),
            "--out",
            str(out),
        )
        output = json.loads(out.read_text()) if out.exists() else None
        return result, output

    def apply(self, accepted, date=None):
        apath = self.root / "accepted.json"
        apath.write_text(json.dumps({"accepted": accepted}))
        args = ["apply", "--accepted", str(apath), "--store", str(self.store)]
        if date:
            args += ["--date", date]
        return self.run(*args)

    def apply_payload(
        self, payload, manifest=None, receipt=None, name="accepted-manifest.json"
    ):
        accepted = self.root / name
        accepted.write_text(json.dumps(payload))
        args = ["apply", "--accepted", str(accepted), "--store", str(self.store)]
        if manifest:
            args += ["--manifest", str(manifest)]
        if receipt:
            args += ["--receipt", str(receipt)]
        return self.run(*args)


class DrafterArtifactTests(unittest.TestCase):
    def test_agent_frontmatter_is_read_only_and_sonnet(self):
        text = DRAFTER.read_text()
        frontmatter = text.split("---", 2)[1]
        self.assertIn("name: memory-mine-drafter", frontmatter)
        self.assertIn("tools: Read, Grep", frontmatter)
        self.assertIn("model: sonnet", frontmatter)
        for forbidden in ("Bash", "Write", "Edit", "Agent", "Task", "Glob"):
            self.assertNotIn(forbidden, frontmatter)

    def test_agent_contract_pins_exact_batch_and_closed_dispositions(self):
        text = DRAFTER.read_text()
        self.assertIn("exactly the two frozen", text)
        self.assertIn("Echo each supplied session basename exactly once", text)
        self.assertIn("no-durable-knowledge", text)
        self.assertIn("At most six notes", text)
        self.assertIn("at most six tool calls total", text)
        self.assertIn("at most two narrow Greps", text)
        self.assertIn('"schema_version": 1', text)
        self.assertIn('"source_session"', text)

    def test_manual_skill_delegates_once_without_dynamic_orchestration(self):
        text = SKILL.read_text()
        frontmatter = text.split("---", 2)[1]
        self.assertIn("allowed-tools: Bash, Read", frontmatter)
        self.assertNotIn("Task", frontmatter)
        self.assertIn("memory-mine-controller.py", text)
        self.assertIn("--project=<slug>", text)
        self.assertIn("workspace:/absolute/path", text)
        self.assertNotIn("claude -p", text)
        self.assertNotIn("subagent_type", text)
        self.assertNotIn("memory-dream-drafter", text)


class InventorySelectionTests(unittest.TestCase):
    def _inventory(self, fixture, *extra):
        out = fixture.root / "inventory.json"
        result = fixture.run(
            "inventory",
            "--project-dir",
            str(fixture.root),
            "--days",
            "3650",
            "--min-bytes",
            "0",
            "--out",
            str(out),
            *extra,
        )
        payload = json.loads(out.read_text())
        return result, payload["sessions"]

    def test_limit_keeps_newest_candidates_after_mined_filter(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            now = time.time()
            sessions = [
                fixture.add_session(f"session-{index}.jsonl") for index in range(4)
            ]
            for index, session in enumerate(sessions):
                os.utime(session, (now - index * 100, now - index * 100))
            (fixture.store / ".mined-sessions.json").write_text(
                json.dumps([sessions[0].name])
            )

            result, inventory = self._inventory(
                fixture, "--store", str(fixture.store), "--limit", "2"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [Path(item["path"]).name for item in inventory],
                ["session-1.jsonl", "session-2.jsonl"],
            )
            self.assertIn("2 candidate sessions (1 already mined", result.stdout)

    def test_oldest_first_orders_before_applying_limit(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            now = time.time()
            sessions = [
                fixture.add_session(f"ordered-{index}.jsonl") for index in range(4)
            ]
            for index, session in enumerate(sessions):
                os.utime(session, (now - index * 100, now - index * 100))

            result, inventory = self._inventory(
                fixture, "--oldest-first", "--limit", "2"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [Path(item["path"]).name for item in inventory],
                ["ordered-3.jsonl", "ordered-2.jsonl"],
            )

    def test_max_bytes_excludes_oversized_session_before_limit(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            now = time.time()
            oversized = fixture.add_session("oversized.jsonl", size=500)
            first = fixture.add_session("first.jsonl", size=200)
            second = fixture.add_session("second.jsonl", size=200)
            for index, session in enumerate((oversized, first, second)):
                os.utime(session, (now - 300 + index, now - 300 + index))

            result, inventory = self._inventory(
                fixture,
                "--oldest-first",
                "--limit",
                "2",
                "--max-bytes",
                "300",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [Path(item["path"]).name for item in inventory],
                [first.name, second.name],
            )

    def test_settled_seconds_excludes_currently_active_session(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            now = time.time()
            settled = fixture.add_session("settled.jsonl")
            active = fixture.add_session("active.jsonl")
            os.utime(settled, (now - 120, now - 120))
            os.utime(active, (now, now))

            result, inventory = self._inventory(fixture, "--settled-seconds", "60")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [Path(item["path"]).name for item in inventory],
                ["settled.jsonl"],
            )


class ValidateGateTests(unittest.TestCase):
    def test_rejection_reason_codes_are_closed_and_keep_reason_text(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "collision-note.md").write_text("existing")
            (fixture.store / "MEMORY.md").write_text(
                "- [Old](old.md) — quantum flux capacitor requires biweekly calibration checks always\n"
            )
            candidates = [
                candidate(name="Not A Slug!"),
                candidate(name="collision-note"),
                candidate(name="bad-type-note", note_type="invalid"),
                candidate(name="short-description", description="short"),
                candidate(name="short-body", body="short"),
                candidate(name="bad-confidence", confidence=0),
                candidate(
                    name="frontmatter-newline",
                    description="A valid-length description\nwith an injected line",
                ),
                candidate(name="source-not-string", source_session=123),
                candidate(name="source-control", source_session="bad\x00session.jsonl"),
                candidate(name="source-whitespace", source_session="bad session.jsonl"),
                candidate(name="source-extension", source_session="session.txt"),
                candidate(name="source-unknown", source_session="missing.jsonl"),
                candidate(
                    name="credential-content",
                    body=(
                        "Long enough body with token=abcdefghijklmnopqrstuvwxyz0123456789 "
                        "and additional safe padding for the body gate."
                    ),
                ),
                candidate(
                    name="near-duplicate-note",
                    description="quantum flux capacitor requires biweekly calibration checks",
                ),
            ]
            result, payload = fixture.validate(candidates)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(payload["rejected"]), len(MM.REASON_CODES))
            by_name = {item["name"]: item for item in payload["rejected"]}
            self.assertEqual(
                {item["reason_code"] for item in payload["rejected"]},
                MM.REASON_CODES,
            )
            self.assertEqual(by_name["Not A Slug!"]["reason_code"], "bad_slug")
            self.assertTrue(all(item["reason"] for item in payload["rejected"]))

    def test_bad_slug_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate([candidate(name="Not A Slug!")])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("bad slug", payload["rejected"][0]["reason"])

    def test_name_collision_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "taken-name.md").write_text(
                "---\nname: taken-name\n---\nBody.\n"
            )
            result, payload = fixture.validate([candidate(name="taken-name")])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("name collision", payload["rejected"][0]["reason"])

    def test_bad_type_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate([candidate(note_type="not-a-real-type")])
            self.assertEqual(result.returncode, 0)
            self.assertIn("bad type", payload["rejected"][0]["reason"])

    def test_description_length_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate(
                [
                    candidate(name="too-short-desc", description="short"),
                    candidate(name="too-long-desc", description="x" * 500),
                ]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            reasons = [r["reason"] for r in payload["rejected"]]
            self.assertTrue(all("description length" in r for r in reasons))

    def test_body_length_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate(
                [
                    candidate(name="too-short-body", body="short body"),
                    candidate(name="too-long-body", body="x" * 9000),
                ]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            reasons = [r["reason"] for r in payload["rejected"]]
            self.assertTrue(all("body length" in r for r in reasons))

    def test_confidence_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate(
                [
                    candidate(name="zero-conf", confidence=0.0),
                    candidate(name="over-conf", confidence=1.5),
                    candidate(name="nonnumeric-conf", confidence="high"),
                ]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            reasons = [r["reason"] for r in payload["rejected"]]
            self.assertTrue(all("confidence" in r for r in reasons))

    def test_credential_rejected_via_shared_audit_signatures(self):
        # This body trips AUDIT.CONTENT_SIGNATURES' github-token pattern but NOT
        # memory-mine's own inline api_key/secret/token/password regex, proving
        # the shared-signature reuse is actually wired in, not just cosmetic.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            leaky_body = (
                "Filler prose around the leaked value here so the body clears "
                "the minimum length gate. ghp_1234567890ABCDEFGHIJ leaked by accident."
            )
            result, payload = fixture.validate(
                [candidate(name="leaky-note", body=leaky_body)]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("credential", payload["rejected"][0]["reason"])

    def test_near_duplicate_of_existing_index_line_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "MEMORY.md").write_text(
                "- [old](old.md) — the quantum flux capacitor requires biweekly calibration checks always\n"
            )
            dup_desc = "the quantum flux capacitor requires biweekly calibration checks"
            result, payload = fixture.validate(
                [candidate(name="dup-note", description=dup_desc)]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("near-duplicate", payload["rejected"][0]["reason"])

    def test_embedded_newline_in_description_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            injected = "Looks fine on the surface\n---\nname: evil\n---\nmore text padding here"
            result, payload = fixture.validate(
                [candidate(name="newline-note", description=injected)]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("embedded newline", payload["rejected"][0]["reason"])

    def test_valid_candidate_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate([candidate(name="valid-fixture-note")])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 1)
            self.assertEqual(payload["accepted"][0]["name"], "valid-fixture-note")

    def test_source_session_with_embedded_newline_rejected(self):
        # P1: a source_session containing "\n---\n..." could close the note's
        # YAML frontmatter early and inject unscanned content once written by
        # cmd_apply. Path(...).name does not strip newlines, so this must be
        # caught here, not silently "sanitized".
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            injected = "s.jsonl\n---\nname: evil\n---\nmore text padding here"
            result, payload = fixture.validate(
                [candidate(name="ss-newline", source_session=injected)]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("source_session", payload["rejected"][0]["reason"])
            self.assertIn("control charact", payload["rejected"][0]["reason"])

    def test_source_session_with_control_character_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            injected = "s\x00ession.jsonl"
            result, payload = fixture.validate(
                [candidate(name="ss-control", source_session=injected)]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("source_session", payload["rejected"][0]["reason"])

    def test_source_session_wrong_extension_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate(
                [candidate(name="ss-ext", source_session="session.txt")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("source_session", payload["rejected"][0]["reason"])
            self.assertIn(".jsonl", payload["rejected"][0]["reason"])

    def test_source_session_non_string_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate(
                [candidate(name="ss-nonstring", source_session=12345)]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("source_session", payload["rejected"][0]["reason"])

    def test_source_session_directory_component_flattened_not_rejected(self):
        # A directory component is not a frontmatter-injection risk (no control
        # characters/newlines), just noise: flatten to the basename rather than
        # reject outright for the path shape alone. The flattened basename must
        # still name a real session ("evil-session.jsonl" here) to pass
        # authentication.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            fixture.add_session("evil-session.jsonl")
            result, payload = fixture.validate(
                [
                    candidate(
                        name="ss-traversal",
                        source_session="../../etc/evil-session.jsonl",
                    )
                ]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 1)
            self.assertEqual(
                payload["accepted"][0]["source_session"], "evil-session.jsonl"
            )

    def test_source_session_unknown_rejected(self):
        # P1: source_session is drafter/model-produced and otherwise untrusted.
        # A candidate naming a *.jsonl file that is not a real session for this
        # project (no backing file exists in the store's project dir or any
        # sibling worktree dir) must be rejected, not silently written and
        # ledgered — otherwise a prompt-steered drafter could claim ANY known
        # session's filename and retire it from future inventory unmined.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result, payload = fixture.validate(
                [candidate(name="ss-unknown", source_session="phantom-session.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("source_session", payload["rejected"][0]["reason"])
            self.assertIn("unknown", payload["rejected"][0]["reason"])

    def test_source_session_known_sibling_worktree_session_accepted(self):
        # Authentication must recognize sessions living in a sibling
        # `<slug>--claude-worktrees-*` dir too, per candidate_session_files(),
        # not just the canonical project dir — mirroring the worktree-aware
        # discovery inventory/staleness already use.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            worktree_dir = fixture.root.parent / (
                fixture.root.name + "--claude-worktrees-abc123"
            )
            worktree_dir.mkdir()
            (worktree_dir / "wt-session.jsonl").write_text("x" * 50)
            result, payload = fixture.validate(
                [candidate(name="ss-worktree", source_session="wt-session.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 1)
            self.assertEqual(
                payload["accepted"][0]["source_session"], "wt-session.jsonl"
            )

    def test_source_session_with_internal_whitespace_rejected(self):
        # P2: internal whitespace must be rejected outright, not silently
        # collapsed at write time — accept-then-collapse let accepted.json's
        # source_session diverge from the note's on-disk mined_from, breaking
        # retry recovery's exact-identity comparison.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            fixture.add_session("my weird session.jsonl")
            result, payload = fixture.validate(
                [
                    candidate(
                        name="ss-whitespace", source_session="my weird session.jsonl"
                    )
                ]
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(payload["accepted"]), 0)
            self.assertIn("source_session", payload["rejected"][0]["reason"])
            self.assertIn("whitespace", payload["rejected"][0]["reason"])


class ManifestValidationTests(unittest.TestCase):
    def _payload(self, *sessions):
        return {"schema_version": 1, "sessions": list(sessions)}

    def test_manifest_store_must_resolve_to_requested_store(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("store-bound.jsonl")
            manifest, payload = fixture.make_manifest([session])
            candidates = self._payload(
                session_result(
                    session.name,
                    notes=[
                        candidate(name="store-bound-note", source_session=session.name)
                    ],
                )
            )

            payload["store"] = str(fixture.root / "different-store")
            manifest.write_text(json.dumps(payload))
            result, output = fixture.validate_manifest(candidates, manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(output)
            self.assertIn("does not resolve to --store", result.stderr)

            payload["store"] = str(fixture.store / ".." / fixture.store.name)
            manifest.write_text(json.dumps(payload))
            result, output = fixture.validate_manifest(
                candidates, manifest, out_name="resolved-store.json"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(output["accepted"]), 1)

    def test_manifest_digest_size_and_mtime_are_authenticated(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("authenticated.jsonl")
            candidates = self._payload(
                session_result(
                    session.name,
                    notes=[
                        candidate(
                            name="authenticated-note", source_session=session.name
                        )
                    ],
                )
            )
            mutations = {
                "digest": ("sha256", "0" * 64, "sha256 does not match"),
                "size": ("size", session.stat().st_size + 1, "size does not match"),
                "mtime": (
                    "mtime",
                    int(session.stat().st_mtime) + 1,
                    "mtime does not match",
                ),
            }
            for name, (field, value, message) in mutations.items():
                with self.subTest(field=field):
                    manifest, payload = fixture.make_manifest(
                        [session], name=f"manifest-{name}.json"
                    )
                    payload["sessions"][0][field] = value
                    manifest.write_text(json.dumps(payload))
                    result, output = fixture.validate_manifest(
                        candidates, manifest, out_name=f"out-{name}.json"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(output)
                    self.assertIn(message, result.stderr)

    def test_manifest_source_path_must_match_the_session_basename(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("right-name.jsonl")
            other = fixture.add_session("wrong-name.jsonl")
            manifest, payload = fixture.make_manifest([session])
            payload["sessions"][0]["source_path"] = str(other)
            manifest.write_text(json.dumps(payload))
            candidates = self._payload(
                session_result(
                    session.name,
                    notes=[candidate(name="path-note", source_session=session.name)],
                )
            )

            result, output = fixture.validate_manifest(candidates, manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(output)
            self.assertIn("basename does not match", result.stderr)

    def test_manifest_source_path_must_be_absolute_regular_and_non_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("source-shape.jsonl")
            directory_parent = fixture.root / "directory-source"
            directory_parent.mkdir()
            directory_source = directory_parent / session.name
            directory_source.mkdir()
            symlink_parent = fixture.root / "symlink-source"
            symlink_parent.mkdir()
            symlink_source = symlink_parent / session.name
            symlink_source.symlink_to(session)
            cases = {
                "relative": session.name,
                "missing": str(fixture.root / "missing" / session.name),
                "directory": str(directory_source),
                "symlink": str(symlink_source),
            }
            candidates = self._payload(
                session_result(
                    session.name,
                    notes=[
                        candidate(name="source-shape-note", source_session=session.name)
                    ],
                )
            )
            for name, source_path in cases.items():
                with self.subTest(name=name):
                    manifest, payload = fixture.make_manifest(
                        [session], name=f"source-shape-{name}.json"
                    )
                    payload["sessions"][0]["source_path"] = source_path
                    manifest.write_text(json.dumps(payload))
                    result, output = fixture.validate_manifest(
                        candidates,
                        manifest,
                        out_name=f"source-shape-out-{name}.json",
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(output)

    def test_manifest_schema_and_session_basenames_are_strict(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("strict.jsonl")
            candidates = self._payload(
                session_result(
                    session.name,
                    notes=[candidate(name="strict-note", source_session=session.name)],
                )
            )
            manifest, valid = fixture.make_manifest([session])
            missing_version = {
                key: value for key, value in valid.items() if key != "schema_version"
            }
            missing_session_sha = {
                **valid,
                "sessions": [
                    {
                        key: value
                        for key, value in valid["sessions"][0].items()
                        if key != "sha256"
                    }
                ],
            }
            invalid_payloads = {
                "bool-version": {**valid, "schema_version": True},
                "string-version": {**valid, "schema_version": "1"},
                "unsupported-version": {**valid, "schema_version": 2},
                "missing-version": missing_version,
                "extra-field": {**valid, "unexpected": "field"},
                "missing-session-field": missing_session_sha,
                "extra-session-field": {
                    **valid,
                    "sessions": [{**valid["sessions"][0], "unexpected": "field"}],
                },
                "wrong-size-type": {
                    **valid,
                    "sessions": [{**valid["sessions"][0], "size": "100"}],
                },
                "duplicate-session": {
                    **valid,
                    "sessions": [valid["sessions"][0], valid["sessions"][0]],
                },
                "qualified-session": {
                    **valid,
                    "sessions": [
                        {
                            **valid["sessions"][0],
                            "source_session": f"nested/{session.name}",
                        }
                    ],
                },
            }
            for name, invalid in invalid_payloads.items():
                with self.subTest(name=name):
                    path = fixture.root / f"strict-{name}.json"
                    path.write_text(json.dumps(invalid))
                    result, output = fixture.validate_manifest(
                        candidates, path, out_name=f"strict-out-{name}.json"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(output)

            duplicate_key_path = fixture.root / "strict-duplicate-key.json"
            duplicate_key_path.write_text(
                json.dumps(valid).replace(
                    '"schema_version": 1',
                    '"schema_version": 1, "schema_version": 1',
                    1,
                )
            )
            result, output = fixture.validate_manifest(
                candidates,
                duplicate_key_path,
                out_name="strict-out-duplicate-key.json",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(output)
            self.assertIn("duplicate JSON key", result.stderr)

    def test_candidate_session_set_must_exactly_match_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            first = fixture.add_session("first.jsonl")
            second = fixture.add_session("second.jsonl")
            manifest, _payload = fixture.make_manifest([first])
            valid = session_result(
                first.name,
                notes=[candidate(name="first-note", source_session=first.name)],
            )
            cases = {
                "missing": self._payload(),
                "extraneous": self._payload(
                    valid,
                    session_result(
                        second.name,
                        notes=[
                            candidate(name="second-note", source_session=second.name)
                        ],
                    ),
                ),
                "duplicate": self._payload(valid, valid),
            }
            for name, payload in cases.items():
                with self.subTest(name=name):
                    result, output = fixture.validate_manifest(
                        payload, manifest, out_name=f"session-set-{name}.json"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(output)

    def test_valid_note_and_no_durable_dispositions_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            with_note = fixture.add_session("with-note.jsonl")
            without_note = fixture.add_session("without-note.jsonl")
            manifest, _payload = fixture.make_manifest([with_note, without_note])
            candidates = self._payload(
                session_result(
                    without_note.name,
                    disposition="no-durable-knowledge",
                    reason="Nothing durable remained after review.",
                ),
                session_result(
                    with_note.name,
                    notes=[
                        candidate(name="durable-note", source_session=with_note.name)
                    ],
                ),
            )

            result, output = fixture.validate_manifest(candidates, manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output["schema_version"], 1)
            self.assertEqual(output["store"], str(fixture.store.resolve()))
            self.assertEqual(
                output["processed_sessions"],
                [
                    {
                        "source_session": without_note.name,
                        "disposition": "no-durable-knowledge",
                    },
                    {"source_session": with_note.name, "disposition": "notes"},
                ],
            )
            self.assertEqual(len(output["accepted"]), 1)
            self.assertEqual(output["rejected"], [])

    def test_disposition_and_nested_note_identity_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("disposition.jsonl")
            # This is a real, otherwise known project session, but deliberately
            # absent from the frozen manifest batch below.
            fixture.add_session("other.jsonl")
            manifest, _payload = fixture.make_manifest([session])
            cases = {
                "unknown": session_result(session.name, disposition="skip"),
                "empty-notes": session_result(session.name),
                "notes-on-no-durable": session_result(
                    session.name,
                    disposition="no-durable-knowledge",
                    notes=[
                        candidate(name="forbidden-note", source_session=session.name)
                    ],
                ),
                "wrong-nested-source": session_result(
                    session.name,
                    notes=[
                        candidate(name="wrong-source", source_session="other.jsonl")
                    ],
                ),
            }
            for name, session_payload in cases.items():
                with self.subTest(name=name):
                    result, output = fixture.validate_manifest(
                        self._payload(session_payload),
                        manifest,
                        out_name=f"disposition-{name}.json",
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(output)


class ApplyTests(unittest.TestCase):
    def test_note_written_with_decay_frontmatter_and_index_appended(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            fixture.add_session("s1.jsonl")
            accepted = [
                candidate(name="fresh-note", confidence=0.72, source_session="s1.jsonl")
            ]
            result = fixture.apply(accepted, date="2026-01-15")
            self.assertEqual(result.returncode, 0)
            note_text = (fixture.store / "fresh-note.md").read_text()
            self.assertIn("confidence: 0.72", note_text)
            self.assertIn("maturity: candidate", note_text)
            self.assertIn("last_validated: 2026-01-15", note_text)
            self.assertIn("mined_from: s1.jsonl", note_text)
            index_text = (fixture.store / "MEMORY.md").read_text()
            self.assertIn("fresh-note.md", index_text)

    def test_ledger_updated_only_for_sessions_actually_written(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            # Pre-existing note collides by name, so its candidate will be skipped
            # before source_session is ever authenticated — no backing file needed
            # for session-skip.jsonl.
            (fixture.store / "existing-note.md").write_text(
                "---\nname: existing-note\n---\nAlready here.\n"
            )
            fixture.add_session("session-write.jsonl")
            accepted = [
                candidate(name="existing-note", source_session="session-skip.jsonl"),
                candidate(name="brand-new-note", source_session="session-write.jsonl"),
            ]
            result = fixture.apply(accepted)
            self.assertEqual(result.returncode, 0)
            ledger = json.loads((fixture.store / ".mined-sessions.json").read_text())
            self.assertIn("session-write.jsonl", ledger)
            self.assertNotIn("session-skip.jsonl", ledger)

    def test_skip_if_exists_does_not_write_or_duplicate_index_line(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "dup.md").write_text(
                "---\nname: dup\n---\nOriginal body untouched.\n"
            )
            result = fixture.apply([candidate(name="dup", source_session="s2.jsonl")])
            self.assertEqual(result.returncode, 0)
            self.assertIn("skip (exists)", result.stdout)
            self.assertEqual(
                (fixture.store / "dup.md").read_text(),
                "---\nname: dup\n---\nOriginal body untouched.\n",
            )

    def test_backup_created_when_index_preexists(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / "MEMORY.md").write_text(
                "- [old](old.md) — pre-existing line\n"
            )
            result = fixture.apply([candidate(name="another-note")])
            self.assertEqual(result.returncode, 0)
            backups = list(fixture.store.glob(".MEMORY.md.pre-mine-*"))
            self.assertEqual(len(backups), 1)
            self.assertIn("pre-existing line", backups[0].read_text())

    def test_mined_from_whitespace_rejected_not_flattened(self):
        # P2 fix: a source_session with internal whitespace is rejected at the
        # validate_record gate apply re-runs (no accept-then-collapse), so the
        # note is skipped rather than written with a flattened mined_from that
        # would no longer match what a caller's accepted.json actually said.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            fixture.add_session("my   weird   session.jsonl")
            accepted = [
                candidate(name="ws-note", source_session="my   weird   session.jsonl")
            ]
            result = fixture.apply(accepted, date="2026-01-15")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("skip (invalid)", result.stdout)
            self.assertIn("whitespace", result.stdout)
            self.assertFalse((fixture.store / "ws-note.md").exists())


class ManifestApplyTests(unittest.TestCase):
    def _validate(self, fixture, manifest, sessions, out_name="apply-validated.json"):
        result, output = fixture.validate_manifest(
            {"schema_version": 1, "sessions": sessions},
            manifest,
            out_name=out_name,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    def test_no_durable_session_is_ledgered_without_writing_a_note(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            noted = fixture.add_session("noted.jsonl")
            no_note = fixture.add_session("no-note.jsonl")
            manifest, _payload = fixture.make_manifest([noted, no_note])
            accepted = self._validate(
                fixture,
                manifest,
                [
                    session_result(
                        noted.name,
                        notes=[
                            candidate(name="manifest-note", source_session=noted.name)
                        ],
                    ),
                    session_result(
                        no_note.name,
                        disposition="no-durable-knowledge",
                        reason="No durable knowledge in this source.",
                    ),
                ],
            )

            result = fixture.apply_payload(accepted, manifest=manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((fixture.store / "manifest-note.md").exists())
            self.assertEqual(
                json.loads((fixture.store / ".mined-sessions.json").read_text()),
                sorted([noted.name, no_note.name]),
            )

    def test_near_duplicate_is_ledgered_as_successfully_reviewed(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            covered = fixture.add_session("covered.jsonl")
            no_note = fixture.add_session("covered-no-note.jsonl")
            (fixture.store / "MEMORY.md").write_text(
                f"- [existing](existing.md) — {GOOD_DESC}\n"
            )
            manifest, _payload = fixture.make_manifest([covered, no_note])
            accepted = self._validate(
                fixture,
                manifest,
                [
                    session_result(
                        covered.name,
                        notes=[
                            candidate(
                                name="already-covered",
                                description=GOOD_DESC,
                                source_session=covered.name,
                            )
                        ],
                    ),
                    session_result(
                        no_note.name,
                        disposition="no-durable-knowledge",
                        reason="Nothing durable was found.",
                    ),
                ],
            )
            self.assertEqual(accepted["accepted"], [])
            self.assertEqual(accepted["rejected"][0]["reason_code"], "near_duplicate")

            receipt = fixture.root / "covered-receipt.json"
            result = fixture.apply_payload(accepted, manifest=manifest, receipt=receipt)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads((fixture.store / ".mined-sessions.json").read_text()),
                sorted([covered.name, no_note.name]),
            )
            self.assertEqual(json.loads(receipt.read_text())["ledgered"], 2)

    def test_invalid_sibling_note_suppresses_entire_manifest_session(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            partial = fixture.add_session("partial.jsonl")
            no_note = fixture.add_session("clean-no-note.jsonl")
            manifest, _payload = fixture.make_manifest([partial, no_note])
            accepted = self._validate(
                fixture,
                manifest,
                [
                    session_result(
                        partial.name,
                        notes=[
                            candidate(
                                name="would-be-valid", source_session=partial.name
                            ),
                            candidate(
                                name="invalid-sibling",
                                body="too short",
                                source_session=partial.name,
                            ),
                        ],
                    ),
                    session_result(
                        no_note.name,
                        disposition="no-durable-knowledge",
                        reason="Nothing durable was found.",
                    ),
                ],
            )
            self.assertEqual(len(accepted["accepted"]), 1)
            self.assertEqual(len(accepted["rejected"]), 1)

            receipt = fixture.root / "invalid-sibling-receipt.json"
            result = fixture.apply_payload(accepted, manifest=manifest, receipt=receipt)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((fixture.store / "would-be-valid.md").exists())
            ledger = json.loads((fixture.store / ".mined-sessions.json").read_text())
            self.assertNotIn(partial.name, ledger)
            self.assertIn(no_note.name, ledger)
            self.assertEqual(
                json.loads(receipt.read_text()),
                {
                    "processed": 2,
                    "accepted": 0,
                    "rejected": 2,
                    "written": 0,
                    "recovered": 0,
                    "indexed": 0,
                    "ledgered": 1,
                },
            )

    def test_apply_boundary_invalid_note_prevents_manifest_session_ledger(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("tampered.jsonl")
            manifest, _payload = fixture.make_manifest([session])
            accepted = self._validate(
                fixture,
                manifest,
                [
                    session_result(
                        session.name,
                        notes=[
                            candidate(
                                name="tampered-first", source_session=session.name
                            ),
                            candidate(
                                name="tampered-second", source_session=session.name
                            ),
                        ],
                    )
                ],
            )
            accepted["accepted"][1]["body"] = "invalid after validate"

            result = fixture.apply_payload(accepted, manifest=manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((fixture.store / "tampered-first.md").exists())
            self.assertFalse((fixture.store / "tampered-second.md").exists())
            self.assertNotIn(
                session.name,
                json.loads((fixture.store / ".mined-sessions.json").read_text()),
            )

    def test_processed_identity_failures_happen_before_any_store_mutation(self):
        mutations = {
            "missing": lambda output: output.update(processed_sessions=[]),
            "duplicate": lambda output: output["processed_sessions"].append(
                dict(output["processed_sessions"][0])
            ),
            "extraneous-processed": lambda output: output["processed_sessions"].append(
                {
                    "source_session": "other.jsonl",
                    "disposition": "no-durable-knowledge",
                }
            ),
            "malformed-processed": lambda output: output["processed_sessions"][
                0
            ].update(source_session="../identity.jsonl"),
            "invalid-disposition": lambda output: output["processed_sessions"][
                0
            ].update(disposition="skip"),
            "extraneous-note": lambda output: output["accepted"][0].update(
                source_session="other.jsonl"
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                session = fixture.add_session("identity.jsonl")
                manifest, _payload = fixture.make_manifest([session])
                accepted = self._validate(
                    fixture,
                    manifest,
                    [
                        session_result(
                            session.name,
                            notes=[
                                candidate(
                                    name="identity-note", source_session=session.name
                                )
                            ],
                        )
                    ],
                    out_name=f"identity-{name}.json",
                )
                mutate(accepted)
                index = fixture.store / "MEMORY.md"
                ledger = fixture.store / ".mined-sessions.json"
                index.write_text("sentinel index\n")
                ledger.write_text(json.dumps(["sentinel.jsonl"]))
                receipt = fixture.root / "should-not-exist.json"

                result = fixture.apply_payload(
                    accepted,
                    manifest=manifest,
                    receipt=receipt,
                    name=f"invalid-accepted-{name}.json",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(index.read_text(), "sentinel index\n")
                self.assertEqual(json.loads(ledger.read_text()), ["sentinel.jsonl"])
                self.assertFalse((fixture.store / ".mine-apply.lock").exists())
                self.assertEqual(list(fixture.store.glob(".MEMORY.md.pre-mine-*")), [])
                self.assertFalse((fixture.store / "identity-note.md").exists())
                self.assertFalse(receipt.exists())

    def test_validated_output_cannot_be_replayed_into_another_store(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first_root = root / "first"
            second_root = root / "second"
            first_root.mkdir()
            second_root.mkdir()
            first = Fixture(first_root)
            second = Fixture(second_root)
            first_session = first.add_session("same-session.jsonl")
            second_session = second.add_session("same-session.jsonl")
            first_manifest, _payload = first.make_manifest([first_session])
            second_manifest, _payload = second.make_manifest([second_session])
            accepted = self._validate(
                first,
                first_manifest,
                [
                    session_result(
                        first_session.name,
                        notes=[
                            candidate(
                                name="cross-store-note",
                                source_session=first_session.name,
                            )
                        ],
                    )
                ],
            )

            result = second.apply_payload(accepted, manifest=second_manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different store", result.stderr)
            self.assertFalse((second.store / ".mine-apply.lock").exists())
            self.assertFalse((second.store / "cross-store-note.md").exists())
            self.assertFalse((second.store / ".mined-sessions.json").exists())

    def test_apply_rechecks_manifest_digest_before_mutation(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("changes-after-validate.jsonl")
            manifest, _payload = fixture.make_manifest([session])
            accepted = self._validate(
                fixture,
                manifest,
                [
                    session_result(
                        session.name,
                        notes=[
                            candidate(name="frozen-note", source_session=session.name)
                        ],
                    )
                ],
            )
            session.write_text("changed after validation")

            result = fixture.apply_payload(accepted, manifest=manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((fixture.store / ".mine-apply.lock").exists())
            self.assertFalse((fixture.store / "frozen-note.md").exists())
            self.assertFalse((fixture.store / ".mined-sessions.json").exists())

    def test_failed_replay_does_not_erase_prior_ledger_success(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("prior-success.jsonl")
            manifest, _payload = fixture.make_manifest([session])
            accepted = self._validate(
                fixture,
                manifest,
                [
                    session_result(
                        session.name,
                        notes=[
                            candidate(
                                name="later-invalid-note",
                                body="too short",
                                source_session=session.name,
                            )
                        ],
                    )
                ],
            )
            self.assertEqual(accepted["accepted"], [])
            (fixture.store / ".mined-sessions.json").write_text(
                json.dumps([session.name])
            )

            result = fixture.apply_payload(accepted, manifest=manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads((fixture.store / ".mined-sessions.json").read_text()),
                [session.name],
            )

    def test_receipt_cannot_alias_any_memory_store_artifact(self):
        for receipt_name in (".mined-sessions.json", "receipt-note.md"):
            with (
                self.subTest(receipt_name=receipt_name),
                tempfile.TemporaryDirectory() as temp,
            ):
                fixture = Fixture(Path(temp))
                session = fixture.add_session("receipt-alias.jsonl")
                manifest, _payload = fixture.make_manifest([session])
                accepted = self._validate(
                    fixture,
                    manifest,
                    [
                        session_result(
                            session.name,
                            notes=[
                                candidate(
                                    name="receipt-note", source_session=session.name
                                )
                            ],
                        )
                    ],
                    out_name=f"receipt-alias-{receipt_name.replace('.', '-')}.json",
                )

                result = fixture.apply_payload(
                    accepted,
                    manifest=manifest,
                    receipt=fixture.store / receipt_name,
                    name=f"accepted-alias-{receipt_name.replace('.', '-')}.json",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must not replace a memory store artifact", result.stderr)
                self.assertFalse((fixture.store / ".mine-apply.lock").exists())
                self.assertFalse((fixture.store / "receipt-note.md").exists())
                self.assertFalse((fixture.store / ".mined-sessions.json").exists())

    def test_legacy_list_and_object_inputs_remain_compatible_without_manifest(self):
        for shape in ("list", "object"):
            with self.subTest(shape=shape), tempfile.TemporaryDirectory() as temp:
                fixture = Fixture(Path(temp))
                session = fixture.add_session(f"legacy-{shape}.jsonl")
                note = candidate(
                    name=f"legacy-{shape}-note", source_session=session.name
                )
                payload = [note] if shape == "list" else {"accepted": [note]}
                receipt = fixture.root / f"legacy-{shape}-receipt.json"
                result = fixture.apply_payload(payload, receipt=receipt)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((fixture.store / f"legacy-{shape}-note.md").exists())
                self.assertIn(
                    session.name,
                    json.loads((fixture.store / ".mined-sessions.json").read_text()),
                )
                self.assertEqual(
                    json.loads(receipt.read_text()),
                    {
                        "processed": 1,
                        "accepted": 1,
                        "rejected": 0,
                        "written": 1,
                        "recovered": 0,
                        "indexed": 1,
                        "ledgered": 1,
                    },
                )


class AtomicStateAndReceiptTests(unittest.TestCase):
    def test_ledger_replacement_is_private_atomic_and_preserves_prior_entries(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            session = fixture.add_session("atomic-ledger.jsonl")
            ledger = fixture.store / ".mined-sessions.json"
            ledger.write_text(json.dumps(["prior.jsonl"]))
            ledger.chmod(0o644)

            result = fixture.apply(
                [candidate(name="atomic-ledger-note", source_session=session.name)]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(ledger.read_text()),
                sorted(["prior.jsonl", session.name]),
            )
            self.assertEqual(stat.S_IMODE(ledger.stat().st_mode), 0o600)
            self.assertEqual(
                list(fixture.store.glob("..mined-sessions.json.tmp-*")), []
            )

    def test_manifest_receipt_is_private_atomic_count_only_json(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            fresh = fixture.add_session("receipt-fresh.jsonl")
            recovered = fixture.add_session("receipt-recovered.jsonl")
            no_note = fixture.add_session("receipt-no-note.jsonl")
            manifest, _payload = fixture.make_manifest([fresh, recovered, no_note])
            candidates = {
                "schema_version": 1,
                "sessions": [
                    session_result(
                        fresh.name,
                        notes=[
                            candidate(
                                name="receipt-fresh-note", source_session=fresh.name
                            )
                        ],
                    ),
                    session_result(
                        recovered.name,
                        notes=[
                            candidate(
                                name="receipt-recovered-note",
                                source_session=recovered.name,
                            )
                        ],
                    ),
                    session_result(
                        no_note.name,
                        disposition="no-durable-knowledge",
                        reason="No durable knowledge was present.",
                    ),
                ],
            }
            result, accepted = fixture.validate_manifest(candidates, manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            (fixture.store / "receipt-recovered-note.md").write_text(
                "---\n"
                "name: receipt-recovered-note\n"
                'description: "A recovered note missing only its index entry"\n'
                "metadata:\n"
                "  type: project\n"
                "  confidence: 0.8\n"
                "  maturity: candidate\n"
                "  last_validated: 2026-01-01\n"
                f"  mined_from: {recovered.name}\n"
                "---\n\n"
                "Existing durable body remains untouched.\n"
            )
            receipt = fixture.root / "apply-receipt.json"
            receipt.write_text("permissive old receipt")
            receipt.chmod(0o644)

            result = fixture.apply_payload(accepted, manifest=manifest, receipt=receipt)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(receipt.read_text()),
                {
                    "processed": 3,
                    "accepted": 2,
                    "rejected": 0,
                    "written": 1,
                    "recovered": 1,
                    "indexed": 2,
                    "ledgered": 3,
                },
            )
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
            self.assertEqual(
                stat.S_IMODE((fixture.store / ".mined-sessions.json").stat().st_mode),
                0o600,
            )
            receipt_text = receipt.read_text()
            self.assertNotIn(GOOD_BODY, receipt_text)
            self.assertNotIn("receipt-fresh-note", receipt_text)
            self.assertNotIn(fresh.name, receipt_text)
            self.assertEqual(list(fixture.root.glob(".apply-receipt.json.tmp-*")), [])

    def test_atomic_receipt_replace_failure_preserves_previous_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            receipt = Path(temp) / "receipt.json"
            receipt.write_text("original receipt bytes")
            real_replace = os.replace

            def fail_receipt_replace(source, destination):
                if Path(destination) == receipt:
                    raise OSError("simulated receipt replace failure")
                return real_replace(source, destination)

            with mock.patch.object(MM.os, "replace", side_effect=fail_receipt_replace):
                with self.assertRaisesRegex(
                    OSError, "simulated receipt replace failure"
                ):
                    MM.atomic_private_json(receipt, {"processed": 1})

            self.assertEqual(receipt.read_text(), "original receipt bytes")
            self.assertEqual(list(receipt.parent.glob(".receipt.json.tmp-*")), [])

    def test_atomic_ledger_replace_failure_preserves_previous_ledger(self):
        with tempfile.TemporaryDirectory() as temp:
            ledger = Path(temp) / ".mined-sessions.json"
            original = json.dumps(["prior.jsonl"])
            ledger.write_text(original)
            real_replace = os.replace

            def fail_ledger_replace(source, destination):
                if Path(destination) == ledger:
                    raise OSError("simulated ledger replace failure")
                return real_replace(source, destination)

            with mock.patch.object(MM.os, "replace", side_effect=fail_ledger_replace):
                with self.assertRaisesRegex(
                    OSError, "simulated ledger replace failure"
                ):
                    MM.atomic_private_json(ledger, ["new.jsonl"])

            self.assertEqual(ledger.read_text(), original)
            self.assertEqual(
                list(ledger.parent.glob("..mined-sessions.json.tmp-*")), []
            )


class StalenessWorktreeSweepTests(unittest.TestCase):
    """P1 #4: staleness must flag a project whose recent activity lives entirely
    in sibling worktree session dirs, not just the canonical project dir."""

    def test_worktree_only_activity_flagged_stale(self):
        with tempfile.TemporaryDirectory() as temp:
            fake_home = Path(temp) / "home"
            projects = fake_home / ".claude" / "projects"
            canonical = projects / "-SITES-myrepo"
            (canonical / "memory").mkdir(parents=True)
            worktree_dir = projects / "-SITES-myrepo--claude-worktrees-abc123"
            worktree_dir.mkdir(parents=True)
            # A large-enough, fresh session file that lives ONLY in the worktree
            # sibling dir — never in the canonical project dir.
            (worktree_dir / "session-1.jsonl").write_text("x" * 30000)
            env = {**os.environ, "HOME": str(fake_home)}
            result = subprocess.run(
                [
                    "python3",
                    str(MINE),
                    "staleness",
                    "--days",
                    "3650",
                    "--min-bytes",
                    "10",
                    "--threshold",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.strip(),
                "STALE: -SITES-myrepo 1 unmined sessions (last 3650d)",
            )

    def test_worktree_activity_already_mined_not_flagged(self):
        with tempfile.TemporaryDirectory() as temp:
            fake_home = Path(temp) / "home"
            projects = fake_home / ".claude" / "projects"
            canonical = projects / "-SITES-myrepo"
            memory = canonical / "memory"
            memory.mkdir(parents=True)
            worktree_dir = projects / "-SITES-myrepo--claude-worktrees-abc123"
            worktree_dir.mkdir(parents=True)
            session = worktree_dir / "session-1.jsonl"
            session.write_text("x" * 30000)
            (memory / ".mined-sessions.json").write_text(json.dumps([str(session)]))
            env = {**os.environ, "HOME": str(fake_home)}
            result = subprocess.run(
                [
                    "python3",
                    str(MINE),
                    "staleness",
                    "--days",
                    "3650",
                    "--min-bytes",
                    "10",
                    "--threshold",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.strip(),
                "capture fresh: no store has unmined recent sessions",
            )


class StalenessJsonTests(unittest.TestCase):
    def test_json_mode_reports_stale_projects_without_text_prose(self):
        with tempfile.TemporaryDirectory() as temp:
            fake_home = Path(temp) / "home"
            project = fake_home / ".claude" / "projects" / "-SITES-json-project"
            (project / "memory").mkdir(parents=True)
            (project / "fresh-session.jsonl").write_text("x" * 100)
            env = {**os.environ, "HOME": str(fake_home)}
            result = subprocess.run(
                [
                    "python3",
                    str(MINE),
                    "staleness",
                    "--days",
                    "3650",
                    "--min-bytes",
                    "10",
                    "--threshold",
                    "1",
                    "--json",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("STALE:", result.stdout)
            self.assertNotIn("capture fresh", result.stdout)
            self.assertEqual(
                json.loads(result.stdout),
                {
                    "stale": [
                        {
                            "project": "-SITES-json-project",
                            "unmined_sessions": 1,
                        }
                    ]
                },
            )

    def test_json_mode_empty_result_is_still_one_parseable_document(self):
        with tempfile.TemporaryDirectory() as temp:
            fake_home = Path(temp) / "home"
            (fake_home / ".claude" / "projects").mkdir(parents=True)
            env = {**os.environ, "HOME": str(fake_home)}
            result = subprocess.run(
                ["python3", str(MINE), "staleness", "--json"],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"stale": []})


class PathEscapeTests(unittest.TestCase):
    """P1 #1: apply must not trust an --accepted file's name field. These bypass
    `validate` entirely (as a tampered/stale/hand-edited accepted.json would) to
    exercise apply's own confinement gate directly."""

    def test_traversal_name_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            result = fixture.apply(
                [candidate(name="../../evil-note", source_session="s.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertFalse((fixture.root / "evil-note.md").exists())
            self.assertFalse((fixture.root.parent / "evil-note.md").exists())
            self.assertEqual(list(fixture.store.glob("*.md")), [])
            ledger_path = fixture.store / ".mined-sessions.json"
            if ledger_path.exists():
                self.assertNotIn("s.jsonl", json.loads(ledger_path.read_text()))

    def test_absolute_path_name_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            evil_target = Path(temp) / "outside-note.md"
            result = fixture.apply(
                [candidate(name=str(evil_target)[:-3], source_session="s.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertFalse(evil_target.exists())

    def test_symlink_escaping_store_refused(self):
        # confined_path resolves symlinks and rejects any destination whose
        # resolved path escapes the store, before apply's own symlink check
        # ever runs.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            outside_target = Path(temp) / "outside.md"
            outside_target.write_text("PRE-EXISTING OUTSIDE CONTENT\n")
            (fixture.store / "escape-note.md").symlink_to(outside_target)
            result = fixture.apply(
                [candidate(name="escape-note", source_session="s.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("skip (invalid path)", result.stdout)
            # The symlink's target must be untouched, and apply must not have
            # followed it to fabricate an index entry or ledger record.
            self.assertEqual(
                outside_target.read_text(), "PRE-EXISTING OUTSIDE CONTENT\n"
            )
            index_path = fixture.store / "MEMORY.md"
            if index_path.exists():
                self.assertNotIn("escape-note.md", index_path.read_text())
            ledger_path = fixture.store / ".mined-sessions.json"
            if ledger_path.exists():
                self.assertNotIn("s.jsonl", json.loads(ledger_path.read_text()))

    def test_in_store_symlink_not_followed(self):
        # A symlink whose resolved target stays inside the store passes
        # confined_path's escape check; apply's own is_symlink() guard must
        # still refuse to write through it rather than clobber the target.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            real_target = fixture.store / "real-note.md"
            real_target.write_text("PRE-EXISTING REAL CONTENT\n")
            (fixture.store / "link-note.md").symlink_to(real_target)
            result = fixture.apply(
                [candidate(name="link-note", source_session="s.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("skip (symlink, refusing to follow)", result.stdout)
            self.assertEqual(real_target.read_text(), "PRE-EXISTING REAL CONTENT\n")


class RetryRecoveryTests(unittest.TestCase):
    """P1 #2: a crashed apply that wrote a note body but never reached the index
    or ledger step must self-heal on retry (same --accepted file, run again),
    not desync forever."""

    def _orphan(
        self,
        fixture,
        name="orphan-note",
        mined_from="session-retry.jsonl",
        body="Original body untouched by retry.\n",
    ):
        (fixture.store / f"{name}.md").write_text(
            "---\n"
            f"name: {name}\n"
            'description: "an orphaned note missing only its index line"\n'
            "metadata:\n  type: project\n  confidence: 0.8\n  maturity: candidate\n"
            "  last_validated: 2026-01-01\n"
            f"  mined_from: {mined_from}\n"
            "---\n\n"
            f"{body}"
        )

    def test_retry_backfills_missing_index_line_without_rewriting_body(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            self._orphan(fixture)
            original_body = (fixture.store / "orphan-note.md").read_text()
            result = fixture.apply(
                [candidate(name="orphan-note", source_session="session-retry.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("1 recovered", result.stdout)
            # Body byte-identical: recovery must never rewrite an existing note.
            self.assertEqual(
                (fixture.store / "orphan-note.md").read_text(), original_body
            )
            index_text = (fixture.store / "MEMORY.md").read_text()
            self.assertIn("orphan-note.md", index_text)
            ledger = json.loads((fixture.store / ".mined-sessions.json").read_text())
            self.assertIn("session-retry.jsonl", ledger)

    def test_retry_is_noop_once_already_indexed(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            self._orphan(fixture)
            (fixture.store / "MEMORY.md").write_text(
                "- [Orphan note](orphan-note.md) — already indexed\n"
            )
            result = fixture.apply(
                [candidate(name="orphan-note", source_session="session-retry.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            index_text = (fixture.store / "MEMORY.md").read_text()
            self.assertEqual(index_text.count("orphan-note.md"), 1)  # no duplicate line

    def test_retry_recognizes_quoted_mined_from_via_frontmatter_parser(self):
        # cmd_apply now reads an existing note's mined_from through
        # AUDIT.parse_frontmatter instead of a line-oriented \S+ regex. The
        # old regex would capture a quoted value's quotes verbatim (\S+ does
        # not treat '"' as a boundary), so "session-retry.jsonl" would never
        # equal the candidate's bare source_session and retry recovery would
        # wrongly treat this as a foreign collision. The structured parser
        # strips matching quotes (same scalar() used everywhere else
        # frontmatter is read), so recovery still re-indexes.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            self._orphan(fixture, mined_from='"session-retry.jsonl"')
            original_body = (fixture.store / "orphan-note.md").read_text()
            result = fixture.apply(
                [candidate(name="orphan-note", source_session="session-retry.jsonl")]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 recovered", result.stdout)
            self.assertEqual(
                (fixture.store / "orphan-note.md").read_text(), original_body
            )
            index_text = (fixture.store / "MEMORY.md").read_text()
            self.assertIn("orphan-note.md", index_text)
            ledger = json.loads((fixture.store / ".mined-sessions.json").read_text())
            self.assertIn("session-retry.jsonl", ledger)

    def test_foreign_collision_not_treated_as_retry(self):
        # An existing note with the same slug but a DIFFERENT (or absent)
        # mined_from must never be "recovered" — that would silently attach an
        # unrelated session to it in the ledger.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            self._orphan(fixture, mined_from="some-other-session.jsonl")
            result = fixture.apply(
                [candidate(name="orphan-note", source_session="session-retry.jsonl")]
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("skip (exists)", result.stdout)
            index_path = fixture.store / "MEMORY.md"
            self.assertFalse(index_path.exists())
            ledger_path = fixture.store / ".mined-sessions.json"
            if ledger_path.exists():
                self.assertNotIn(
                    "session-retry.jsonl", json.loads(ledger_path.read_text())
                )


class LockTests(unittest.TestCase):
    """apply's lock is now a real advisory fcntl.flock held on an open fd for
    the whole apply (P1: the prior create/unlink-if-stale scheme had an ABA
    race — two processes could each observe the same old lock as stale, and
    the second could unlink the FIRST's freshly created replacement lock and
    then acquire the path itself, letting both mutate the index/ledger
    concurrently). flock has no such window and is released by the kernel the
    instant its holder exits or dies, so staleness/age is no longer a concept
    at all — only a still-running holder blocks."""

    def _hold_lock(
        self, lock_path: Path, hold_seconds: float = 5.0
    ) -> subprocess.Popen:
        """Spawn a subprocess that flocks `lock_path` exclusively, writes
        holder info, and blocks for `hold_seconds` — confirming acquisition
        via a stdout line before returning, so the caller can be certain the
        lock is genuinely held (not racing to find out) before testing
        against it."""
        script = (
            "import fcntl, os, sys, time\n"
            "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)\n"
            "fcntl.flock(fd, fcntl.LOCK_EX)\n"
            "os.write(fd, f'pid={os.getpid()} at={time.time()}\\n'.encode())\n"
            "os.fsync(fd)\n"
            "print('LOCKED', flush=True)\n"
            "time.sleep(float(sys.argv[2]))\n"
        )
        proc = subprocess.Popen(
            ["python3", "-c", script, str(lock_path), str(hold_seconds)],
            stdout=subprocess.PIPE,
            text=True,
        )
        line = proc.stdout.readline()
        self.assertEqual(
            line.strip(), "LOCKED", "holder subprocess failed to acquire the flock"
        )
        return proc

    def test_concurrent_apply_blocked_by_held_flock(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            lock_path = fixture.store / ".mine-apply.lock"
            holder = self._hold_lock(lock_path)
            try:
                result = fixture.apply([candidate(name="blocked-note")])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("another `apply`", result.stderr)
                self.assertIn("held by", result.stderr)
                self.assertFalse((fixture.store / "blocked-note.md").exists())
            finally:
                holder.terminate()
                holder.wait(timeout=5)
                holder.stdout.close()

    def test_lock_released_as_soon_as_holder_exits(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            lock_path = fixture.store / ".mine-apply.lock"
            holder = self._hold_lock(lock_path, hold_seconds=0.5)
            holder.wait(timeout=5)
            holder.stdout.close()
            result = fixture.apply([candidate(name="unblocked-note")])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((fixture.store / "unblocked-note.md").exists())

    def test_leftover_lock_file_from_crashed_process_does_not_block(self):
        # A lock FILE surviving a crashed apply (its flock died with the
        # process automatically) must never need manual staleness/age logic to
        # reclaim — only a still-live holder blocks, never a leftover file.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            (fixture.store / ".mine-apply.lock").write_text("pid=999999 at=1.0\n")
            result = fixture.apply([candidate(name="reclaimed-note")])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((fixture.store / "reclaimed-note.md").exists())


class StagedWriteAtomicityTests(unittest.TestCase):
    """P1 (2026-08 hardening): a batch's note bodies must become visible under
    their final .md names all-or-nothing. Before, cmd_apply wrote each body
    straight to its final name in a loop; a kill or I/O failure partway left
    some final notes visible (and thus 'mined' per mined_state's frontmatter
    scan) while their batch-mates and the index/ledger step never ran. Now
    every body is staged to a `<name>.md.tmp-<pid>` sibling first; only once
    ALL bodies in the batch are confirmed staged does phase 1b commit them.
    These drive cmd_apply in-process (not via subprocess) so builtins.open can
    be made to fail for one specific candidate mid-batch."""

    def test_staging_failure_aborts_batch_leaving_no_visible_notes_or_tmp_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            store = root / "store"
            store.mkdir()
            (root / "s1.jsonl").write_text("x" * 100)
            (root / "s2.jsonl").write_text("x" * 100)
            accepted = [
                candidate(name="good-note", source_session="s1.jsonl"),
                candidate(name="fails-to-stage", source_session="s2.jsonl"),
            ]
            accepted_path = root / "accepted.json"
            accepted_path.write_text(json.dumps({"accepted": accepted}))
            args = argparse.Namespace(
                accepted=str(accepted_path), store=str(store), date="2026-01-15"
            )

            real_open = builtins.open

            def flaky_open(path, mode="r", *a, **kw):
                if "w" in mode and "fails-to-stage" in str(path):
                    raise OSError("simulated staging failure")
                return real_open(path, mode, *a, **kw)

            with mock.patch("builtins.open", side_effect=flaky_open):
                with self.assertRaises(SystemExit) as ctx:
                    MM.cmd_apply(args)
            self.assertEqual(ctx.exception.code, 1)

            # Neither note's final name became visible...
            self.assertEqual(list(store.glob("*.md")), [])
            # ...and good-note's tmp file, staged successfully before
            # fails-to-stage's failure, was unlinked during the abort rather
            # than left behind.
            self.assertEqual(list(store.glob("*.tmp-*")), [])
            # No index or ledger write happened either: the batch is entirely
            # invisible, not partially committed.
            self.assertFalse((store / "MEMORY.md").exists())
            self.assertFalse((store / ".mined-sessions.json").exists())

    def test_successful_batch_leaves_no_tmp_files_behind(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            store = root / "store"
            store.mkdir()
            (root / "s1.jsonl").write_text("x" * 100)
            (root / "s2.jsonl").write_text("x" * 100)
            accepted = [
                candidate(name="note-a", source_session="s1.jsonl"),
                candidate(name="note-b", source_session="s2.jsonl"),
            ]
            accepted_path = root / "accepted.json"
            accepted_path.write_text(json.dumps({"accepted": accepted}))
            args = argparse.Namespace(
                accepted=str(accepted_path), store=str(store), date="2026-01-15"
            )
            MM.cmd_apply(args)
            self.assertEqual(list(store.glob("*.tmp-*")), [])
            self.assertEqual(
                {p.name for p in store.glob("*.md") if p.name != "MEMORY.md"},
                {"note-a.md", "note-b.md"},
            )

    def test_commit_io_failure_rolls_back_linked_finals_and_remaining_temps(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            store = root / "store"
            store.mkdir()
            accepted = []
            for index in range(3):
                source = root / f"commit-{index}.jsonl"
                source.write_text("x" * 100)
                accepted.append(
                    candidate(name=f"commit-note-{index}", source_session=source.name)
                )
            accepted_path = root / "accepted.json"
            accepted_path.write_text(json.dumps({"accepted": accepted}))
            args = argparse.Namespace(
                accepted=str(accepted_path), store=str(store), date="2026-01-15"
            )
            real_link = os.link
            calls = 0

            def fail_second_link(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("simulated commit I/O failure")
                return real_link(source, destination)

            with mock.patch.object(MM.os, "link", side_effect=fail_second_link):
                with self.assertRaises(SystemExit) as ctx:
                    MM.cmd_apply(args)
            self.assertEqual(ctx.exception.code, 1)
            self.assertEqual(list(store.glob("*.md")), [])
            self.assertEqual(list(store.glob("*.tmp-*")), [])
            self.assertFalse((store / "MEMORY.md").exists())
            self.assertFalse((store / ".mined-sessions.json").exists())


if __name__ == "__main__":
    unittest.main()
