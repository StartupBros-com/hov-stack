#!/usr/bin/env python3

import contextlib
import datetime as dt
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

CLAUDE = Path(__file__).resolve().parents[1]
AUDITOR = CLAUDE / "scripts" / "memory-audit.py"
SYNC = CLAUDE / "sync.sh"

_spec = importlib.util.spec_from_file_location("memory_audit_module", AUDITOR)
MA = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(MA)


def note(name="note", note_type="project", extra="", body="Body.", nested=True):
    type_field = f"metadata:\n  type: {note_type}\n" if nested else f"type: {note_type}\n"
    return (
        "---\n"
        f"name: {name}\n"
        f"description: Fixture note describing {name} in detail\n"
        f"{type_field}"
        f"{extra}"
        "---\n"
        f"{body}\n"
    )


# memory-dream 0.4.0 writes this plain-text line (apply.py, assemble.py ARCHIVE_POINTER).
DREAM_POINTER = "- Older or resolved entries are archived in MEMORY-archive.md (not auto-loaded); grep it when a topic is missing here.\n"


class Fixture:
    def __init__(self, root: Path):
        self.live = root / "live"
        self.mirror = root / "mirror"
        self.live.mkdir()
        self.mirror.mkdir()

    def project(self, key="project", mirror=True):
        live = self.live / key / "memory"
        live.mkdir(parents=True)
        if mirror:
            mirrored = self.mirror / key
            mirrored.mkdir(parents=True)
        else:
            mirrored = self.mirror / key
        return live, mirrored


class BackupRepo:
    """A git checkout standing in for dotfiles: with no mirror named, the auditor
    reads memory from its PUSHED_MIRROR_REF (CLAUDE_MEMORY_BACKUP_REPO)."""

    def __init__(self, root: Path):
        self.path = root / "repo"
        self.git("init", "-q", str(self.path), at=False)

    def git(self, *args, at=True):
        prefix = ["git", "-C", str(self.path)] if at else ["git"]
        config = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        subprocess.run([*prefix, *config, *args], check=True, capture_output=True)

    def commit(self, project: str, files: dict[str, bytes], push: bool) -> None:
        """Commit `files` as memory/<project>/. Only push=True moves the ref,
        as backup-harness.sh's push does; a plain commit is a copy never pushed."""
        dest = self.path / "memory" / project
        shutil.rmtree(dest, ignore_errors=True)
        dest.mkdir(parents=True)
        for rel, data in files.items():
            (dest / rel).write_bytes(data)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "snapshot")
        if push:
            self.git("update-ref", MA.PUSHED_MIRROR_REF, "HEAD")

    def env(self):
        env = {key: value for key, value in os.environ.items() if key != "CLAUDE_MEMORY_MIRROR_ROOT"}
        env["CLAUDE_MEMORY_BACKUP_REPO"] = str(self.path)
        return env


def snapshot(live: Path) -> dict[str, bytes]:
    return {path.name: path.read_bytes() for path in live.iterdir() if path.is_file()}


class MemoryAuditTests(unittest.TestCase):
    def run_audit(self, fixture, *args):
        command = [
            "python3",
            str(AUDITOR),
            "--live-root",
            str(fixture.live),
            "--mirror-root",
            str(fixture.mirror),
            "--format",
            "json",
            *args,
        ]
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_clean_fixture_and_deterministic_json(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [Note](note.md)\n- [Legacy](legacy.md)\n")
            (live / "note.md").write_text(note())
            (live / "legacy.md").write_text(note("legacy", nested=False))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            first = self.run_audit(fixture)
            second = self.run_audit(fixture)
            self.assertEqual(first.returncode, 0)
            self.assertEqual(first.stdout, second.stdout)
            self.assertNotIn("timestamp", first.stdout)
            self.assertEqual(json.loads(first.stdout)["findings"], [])
            self.assertNotIn("refusing to report clean", first.stderr)

    def test_empty_existing_roots_refuse_to_report_clean(self):
        """PLANTED NEGATIVE: empty roots previously exited 0 with zero projects."""
        with tempfile.TemporaryDirectory() as temp:
            result = self.run_audit(Fixture(Path(temp)))
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("memory audit live projects", result.stderr)
            self.assertIn("examined 0 item(s), expected at least 1", result.stderr)

    def test_coverage_drift_orphans_indexes_and_escaped_links(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text(
                "- [Escaped](space\\(copy\\).md)\n"
                "- [Missing](gone.md)\n"
                "- [Outside](../outside.md)\n"
            )
            (live / "space(copy).md").write_text(note("escaped"))
            (live / "unindexed.md").write_text(note("unindexed"))
            (live / "attachment.txt").write_text("live attachment\n")
            (mirror / "MEMORY.md").write_text("old\n")
            (mirror / "orphan.md").write_text(note("orphan"))
            (mirror / "mirror-only.txt").write_text("mirror attachment\n")
            fixture.project("missing-mirror", mirror=False)[0].joinpath("MEMORY.md").write_text("")
            orphan_project = fixture.mirror / "mirror-only"
            orphan_project.mkdir()
            (orphan_project / "MEMORY.md").write_text("")

            result = self.run_audit(fixture)
            kinds = [item["kind"] for item in json.loads(result.stdout)["findings"]]
            self.assertEqual(result.returncode, 1)
            findings = json.loads(result.stdout)["findings"]
            self.assertIn(
                {"kind": "mirror_missing_file", "project": "project", "path": "attachment.txt"},
                findings,
            )
            self.assertIn(
                {"kind": "mirror_only_file", "project": "project", "path": "mirror-only.txt"},
                findings,
            )
            for expected in (
                "mirror_missing_project",
                "mirror_stale_file",
                "mirror_only_file",
                "mirror_only_project",
                "unindexed_markdown",
                "missing_index_target",
                "escaping_index_target",
            ):
                self.assertIn(expected, kinds)
            escaped = [item for item in json.loads(result.stdout)["findings"] if item.get("path") == "space(copy).md"]
            self.assertFalse(any(item["kind"] == "unindexed_markdown" for item in escaped))

    def test_frontmatter_duplicates_sensitive_redaction_and_stale_date(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("[A](a.md) [B](b.md) [Bad](bad.md) [Secret](api-key.md)\n")
            (live / "a.md").write_text(
                note("same", extra="status: 2025-01-01\n", body="Body date: 2025-01-01")
            )
            (live / "b.md").write_text(note("same", extra="  api_token: redacted-fixture-value\n"))
            (live / "bad.md").write_text("---\nname: bad\nmetadata:\n  type: wrong\n---\nbody\n")
            (live / "api-key.md").write_text(
                note("sensitive", body="api_key=highsignalsignaturevalue123456789")
            )
            result = self.run_audit(fixture, "--as-of", "2025-05-01", "--scan-content")
            payload = json.loads(result.stdout)
            kinds = [item["kind"] for item in payload["findings"]]
            self.assertIn("duplicate_frontmatter_name", kinds)
            self.assertIn("invalid_frontmatter", kinds)
            self.assertIn("sensitive_filename_indicator", kinds)
            self.assertIn("sensitive_frontmatter_indicator", kinds)
            self.assertIn("sensitive_content_indicator", kinds)
            self.assertIn("stale_date_review", kinds)
            self.assertEqual(payload["as_of"], "2025-05-01")
            self.assertNotIn("redacted-fixture-value", result.stdout)
            self.assertNotIn("highsignalsignaturevalue", result.stdout)
            sensitive_only = self.run_audit(fixture, "--sensitive-exit")
            self.assertEqual(sensitive_only.returncode, 1)

    def test_token_project_name_is_not_a_sensitive_filename(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[Token eater](project_token_eater.md)\n")
            (live / "project_token_eater.md").write_text(note("token-eater"))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())

            result = self.run_audit(fixture)
            self.assertEqual(result.returncode, 0)

    def test_whatsapp_store_databases_are_unconditionally_quarantined(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("")
            filenames = (
                "session.db",
                "session.db-journal",
                "session.db-mj123456789",
                "session.db-wal",
                "wacli.db",
                "wacli.db-journal",
                "wacli.db-mj42",
                "wacli.db-shm",
            )
            for filename in filenames:
                (live / filename).write_bytes(b"sqlite fixture")
            allowlist = Path(temp) / "allowlist.txt"
            allowlist.write_text("\n".join(f"project/{name}" for name in filenames))

            result = self.run_audit(
                fixture, "--filename-allowlist", str(allowlist), "--copy-gate"
            )
            gate = json.loads(result.stdout)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(gate["blocked"], [])
            self.assertEqual(
                gate["quarantine_paths"],
                [
                    "project/session.db",
                    "project/session.db-journal",
                    "project/session.db-mj123456789",
                    "project/session.db-wal",
                    "project/wacli.db",
                    "project/wacli.db-journal",
                    "project/wacli.db-mj42",
                    "project/wacli.db-shm",
                ],
            )

    def test_filename_allowlist_clears_the_name_but_not_the_body(self):
        """The allowlist records that a *name* is not evidence.

        A note about credential handling reads identically to a note containing
        one, so a reviewed path may opt out of the filename heuristic. Body and
        frontmatter scanning still apply, so the same path is still quarantined
        the moment it actually contains a secret.
        """
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[About](rotate-a-credential-safely.md)\n")
            note_path = live / "rotate-a-credential-safely.md"
            note_path.write_text(note("rotate", body="Rotate it, then prove the old one is dead."))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            allowlist = Path(temp) / "allowlist.txt"
            allowlist.write_text(
                "# reviewed\nproject/rotate-a-credential-safely.md\n\n# blank + comment ignored\n"
            )

            flagged = self.run_audit(fixture)
            self.assertIn(
                "sensitive_filename_indicator",
                [item["kind"] for item in json.loads(flagged.stdout)["findings"]],
            )

            allowed = self.run_audit(fixture, "--filename-allowlist", str(allowlist))
            payload = json.loads(allowed.stdout)
            kinds = [item["kind"] for item in payload["findings"]]
            self.assertNotIn("sensitive_filename_indicator", kinds)
            self.assertIn("filename_indicator_allowlisted", kinds)
            # Allowlisted is a record, not a defect: it must not make the audit fail.
            self.assertEqual(payload["summary"]["blocking_findings"], 0)
            self.assertEqual(allowed.returncode, 0)

            # Same allowlisted path, now with a real secret in the body.
            note_path.write_text(
                note("rotate", body="api_key=highsignalsignaturevalue123456789")
            )
            leaked = self.run_audit(
                fixture, "--filename-allowlist", str(allowlist), "--copy-gate"
            )
            gate = json.loads(leaked.stdout)
            self.assertEqual(leaked.returncode, 0)
            self.assertEqual(gate["blocked"], [])
            self.assertEqual(
                gate["quarantine_paths"], ["project/rotate-a-credential-safely.md"]
            )

    def test_filename_allowlist_is_read_from_the_overlay(self):
        """The tracked list ships no entries; a reviewed path lives in the overlay copy.

        HOV_STACK_OVERLAY names the overlay directory, else $XDG_CONFIG_HOME/hov-stack. An
        overlay without the file falls back to the tracked default, so the note is flagged
        again, and --filename-allowlist still wins over the overlay.
        """
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[About](rotate-a-credential-safely.md)\n")
            (live / "rotate-a-credential-safely.md").write_text(
                note("rotate", body="Rotate it, then prove the old one is dead.")
            )
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            entry = "# reviewed\nproject/rotate-a-credential-safely.md\n"
            overlay = Path(temp) / "overlay"
            overlay.mkdir()
            (overlay / "memory-filename-allowlist.txt").write_text(entry)
            xdg = Path(temp) / "xdg"
            (xdg / "hov-stack").mkdir(parents=True)
            (xdg / "hov-stack" / "memory-filename-allowlist.txt").write_text(entry)
            empty = Path(temp) / "empty-overlay"
            empty.mkdir()
            explicit = Path(temp) / "explicit.txt"
            explicit.write_text("# nothing reviewed\n")

            def kinds(overlay_dir, xdg_dir, *args):
                # The subprocess inherits os.environ; patch.dict restores it afterwards.
                with mock.patch.dict(os.environ):
                    os.environ.pop("HOV_STACK_OVERLAY", None)
                    os.environ.pop("XDG_CONFIG_HOME", None)
                    if overlay_dir is not None:
                        os.environ["HOV_STACK_OVERLAY"] = str(overlay_dir)
                    if xdg_dir is not None:
                        os.environ["XDG_CONFIG_HOME"] = str(xdg_dir)
                    result = self.run_audit(fixture, *args)
                kinds_found = [item["kind"] for item in json.loads(result.stdout)["findings"]]
                return result.returncode, kinds_found

            def assert_allowlisted(rc, found):
                # An allowlisted name is a record, not a defect: exit 0.
                self.assertEqual(rc, 0)
                self.assertIn("filename_indicator_allowlisted", found)
                self.assertNotIn("sensitive_filename_indicator", found)

            def assert_flagged(rc, found):
                # A flagged name is a blocking finding: exit 1.
                self.assertEqual(rc, 1)
                self.assertIn("sensitive_filename_indicator", found)
                self.assertNotIn("filename_indicator_allowlisted", found)

            assert_allowlisted(*kinds(overlay, None))
            assert_allowlisted(*kinds(None, xdg))
            # HOV_STACK_OVERLAY wins over XDG_CONFIG_HOME; an overlay without the file falls
            # back to the tracked default, which ships no entries, so the name is flagged.
            assert_flagged(*kinds(empty, xdg))
            # An explicit --filename-allowlist wins over an overlay copy.
            assert_flagged(*kinds(overlay, None, "--filename-allowlist", str(explicit)))

    def test_copy_gate_blocks_only_on_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            outside = Path(temp) / "outside.md"
            outside.write_text(note("outside"))
            (live / "MEMORY.md").write_text("[Out](outside.md)\n[Note](note.md)\n")
            (live / "note.md").write_text(note("note"))
            (live / "outside.md").symlink_to(outside)

            result = self.run_audit(fixture, "--copy-gate")
            gate = json.loads(result.stdout)
            self.assertEqual(result.returncode, 1)
            self.assertEqual([item["kind"] for item in gate["blocked"]], ["live_symlink"])
            self.assertEqual(gate["quarantine_paths"], [])

    def test_truncated_description_detection(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[T](truncated.md) [F](fine.md)\n")
            (live / "truncated.md").write_text(
                "---\nname: truncated\ndescription: shipped as PR\nmetadata:\n  type: project\n---\nBody.\n"
            )
            (live / "fine.md").write_text(
                '---\nname: fine\ndescription: "Shipped as PR #12 and merged."\nmetadata:\n  type: project\n---\nBody.\n'
            )
            for name, desc in (
                ("caps", "keeps payload-logging ON"),
                ("flag", "never use git add -A"),
                ("path", "transcripts live in temp/meeting-transcripts/"),
                # '#' cannot start a comment inside a closed quote pair, so these end
                # where their writer ended them (16 of 18 live flags on 2026-10-16).
                ("dquoted", '"Renovate opens the actual security PRs"'),
                ("squoted", "'follow-ups #1045 and #1046 deferred to issues'"),
                # An opening quote with no closing one is still a cut value.
                ("dopen", '"shipped as PR'),
            ):
                (live / f"{name}.md").write_text(
                    f"---\nname: {name}\ndescription: {desc}\nmetadata:\n  type: project\n---\nBody.\n"
                )
            index_lines = "".join(
                f"[{n}]({n}.md) " for n in ("truncated", "fine", "caps", "flag", "path", "dquoted", "squoted", "dopen")
            )
            (live / "MEMORY.md").write_text(index_lines + "\n")
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            self.assertIn(
                {"kind": "truncated_description", "project": "project", "path": "truncated.md"},
                findings,
            )
            flagged = {f["path"] for f in findings if f["kind"] == "truncated_description"}
            self.assertEqual(flagged, {"truncated.md", "dopen.md"})

    def test_sensitive_scan_covers_index_frontmatter_and_attachments(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text(
                "[N](note.md)\napi_key=indexleakhighsignalvalue1234567890\n"
            )
            (live / "note.md").write_text(note())
            (live / "attachment.txt").write_text("ghp_" + "a" * 20 + "\n")
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            flagged = {f["path"] for f in findings if f["kind"] == "sensitive_content_indicator"}
            self.assertIn("MEMORY.md", flagged)
            self.assertIn("attachment.txt", flagged)
            self.assertNotIn("indexleakhighsignalvalue", result.stdout)
            sensitive_exit = self.run_audit(fixture, "--sensitive-exit")
            self.assertEqual(sensitive_exit.returncode, 1)

    def test_yaml_literal_name_is_invalid(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("[N](nullname.md)\n")
            (live / "nullname.md").write_text(
                "---\nname: null\ndescription: false\nmetadata:\n  type: project\n---\nBody.\n"
            )
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            problems = [
                p for f in findings if f["kind"] == "invalid_frontmatter" for p in f["problems"]
            ]
            self.assertIn("name is a YAML literal, not a string", problems)
            self.assertIn("description is a YAML literal, not a string", problems)

    def test_wikilink_typo_detection(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("[A](project_alpha_note.md) [B](project_beta.md)\n")
            (live / "project_alpha_note.md").write_text(note("alpha"))
            (live / "project_beta.md").write_text(
                note("beta", body="See [[alpha-note]] and [[totally-unknown-forward-ref]].")
            )
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            typos = [f for f in findings if f["kind"] == "wikilink_typo"]
            self.assertEqual(len(typos), 1)
            self.assertEqual(typos[0]["link"], "alpha-note")
            self.assertEqual(typos[0]["resolves_to"], "project_alpha_note")

    def test_symlinked_memory_root_is_blocked(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            outside = Path(temp) / "outside"
            outside.mkdir()
            (outside / "MEMORY.md").write_text("")
            project_parent = fixture.live / "linked"
            project_parent.mkdir()
            (project_parent / "memory").symlink_to(outside)
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            self.assertIn(
                {"kind": "live_symlink", "project": "linked", "path": "memory"}, findings
            )
            sensitive_exit = self.run_audit(fixture, "--sensitive-exit")
            self.assertEqual(sensitive_exit.returncode, 1)

    def test_missing_memory_index_and_oversize_metrics(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project("missing", mirror=False)
            (live / "note.md").write_text(note())
            large, _ = fixture.project("large", mirror=False)
            (large / "MEMORY.md").write_text("one\ntwo\n")
            result = self.run_audit(fixture, "--max-index-lines", "1")
            kinds = [item["kind"] for item in json.loads(result.stdout)["findings"]]
            self.assertIn("missing_memory_index", kinds)
            self.assertIn("oversized_memory_index", kinds)

    def test_archive_tier_notes_are_indexed(self):
        """PLANTED NEGATIVE: a note listed only in an archive tier below MEMORY.md's load
        cut (rehook's memory-archive-index.md, memory-dream's MEMORY-archive.md) was
        reported as unindexed_markdown: 3,367 of the 3,726 live findings on 2026-10-15."""
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text(
                "- [Kept](kept.md)\n- [Archive tier](memory-archive-index.md) — 1 hooked pointer\n" + DREAM_POINTER
            )
            (live / "memory-archive-index.md").write_text(
                note("memory-archive-index", note_type="reference", body="- [Hooked](hooked.md) — archived")
            )
            (live / "MEMORY-archive.md").write_text("- [Demoted](demoted.md) — cold entry\n")
            for name in ("kept", "hooked", "demoted", "orphan"):
                (live / f"{name}.md").write_text(note(name))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            unindexed = [
                item["path"] for item in json.loads(result.stdout)["findings"]
                if item["kind"] == "unindexed_markdown"
            ]
            self.assertEqual(unindexed, ["orphan.md"])

    def test_copy_gate_reads_no_archive_tier(self):
        # The archive-tier exemption is advisory and the copy gate ignores
        # unindexed_markdown, so sync.sh's nightly --copy-gate run must not read a
        # tier: MEMORY-archive.md is otherwise read only inside the content scan's
        # unreadable_file guard, and one unreadable tier would end the push with
        # "auditor could not inspect live memory" (exit 2). Outside the gate an
        # unreadable tier only loses the exemption, as before tiers were read.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [Kept](kept.md)\n" + DREAM_POINTER)
            (live / "MEMORY-archive.md").write_text("- [Demoted](demoted.md) — cold entry\n")
            for name in ("kept", "demoted"):
                (live / f"{name}.md").write_text(note(name))
            argv = ["--live-root", str(fixture.live), "--mirror-root", str(fixture.mirror)]
            with mock.patch.object(MA, "archive_tier_targets", side_effect=AssertionError("tier read in copy-gate mode")):
                gated = MA.audit(MA.parser().parse_args([*argv, "--copy-gate"]))
            self.assertEqual(MA.copy_gate(gated)["blocked"], [])
            with mock.patch.object(MA, "archive_tier_targets", side_effect=PermissionError("unreadable tier")):
                advisory = MA.audit(MA.parser().parse_args(argv))
            unindexed = [item["path"] for item in advisory["findings"] if item["kind"] == "unindexed_markdown"]
            self.assertEqual(unindexed, ["demoted.md"])

    def test_unlinked_archive_tier_is_flagged_but_its_notes_are_not(self):
        # An archive tier MEMORY.md does not link is itself unindexed and says so;
        # the notes it lists stay exempt, as rehook reads its tier whole.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [Kept](kept.md)\n")
            (live / "memory-archive-index.md").write_text(
                note("memory-archive-index", note_type="reference", body="- [Hooked](hooked.md) — archived")
            )
            for name in ("kept", "hooked"):
                (live / f"{name}.md").write_text(note(name))
            result = self.run_audit(fixture)
            unindexed = [
                item["path"] for item in json.loads(result.stdout)["findings"]
                if item["kind"] == "unindexed_markdown"
            ]
            self.assertEqual(unindexed, ["memory-archive-index.md"])

    def test_unlinked_dream_archive_tier_is_flagged_and_its_plain_pointer_links_it(self):
        # memory-dream's MEMORY-archive.md was skipped by name, so once its notes were
        # exempted a MEMORY.md that never mentions it produced no finding at all
        # (acme-evals, 64 notes, 2026-10-16). Its pointer is plain text, not a link.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _mirror = fixture.project()
            (live / "MEMORY-archive.md").write_text("- [Demoted](demoted.md) — cold entry\n")
            for name in ("kept", "demoted"):
                (live / f"{name}.md").write_text(note(name))
            for index, expected in (
                ("- [Kept](kept.md)\n", ["MEMORY-archive.md"]),
                ("- [Kept](kept.md)\n" + DREAM_POINTER, []),
            ):
                with self.subTest(index=index):
                    (live / "MEMORY.md").write_text(index)
                    result = self.run_audit(fixture)
                    unindexed = [
                        item["path"] for item in json.loads(result.stdout)["findings"]
                        if item["kind"] == "unindexed_markdown"
                    ]
                    self.assertEqual(unindexed, expected)


class MemoryTriageTests(unittest.TestCase):
    def run_triage(self, fixture, *args):
        command = [
            "python3", str(AUDITOR), "triage",
            "--live-root", str(fixture.live),
            "--mirror-root", str(fixture.mirror),
            "--format", "json",
            *args,
        ]
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_stacked_supersession_and_oversized_flagged(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [S](stacked.md)\n- [L](lognote.md)\n")
            (live / "stacked.md").write_text(
                note("stacked", body="SUPERSEDED 2025-01: a.\nCORRECTED 2025-02: b.\nRESOLVED 2025-03: c.")
            )
            (live / "lognote.md").write_text(note("lognote", body="x" * 6500))
            result = self.run_triage(fixture)
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            flagged = {item["path"]: item for item in payload["flagged"]}
            self.assertIn("stacked.md", flagged)
            self.assertTrue(any(r.startswith("supersession:") for r in flagged["stacked.md"]["reasons"]))
            self.assertEqual(flagged["stacked.md"]["supersessions"], 3)
            self.assertIn("lognote.md", flagged)
            self.assertTrue(any(r.startswith("size:") for r in flagged["lognote.md"]["reasons"]))

    def test_retracted_status_line_is_a_supersession_marker(self):
        # Triage is the only supersession check since harness-doctor's section 16
        # was retired, and that section counted RETRACTED too.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [R](retracted.md)\n- [P](prose.md)\n")
            (live / "retracted.md").write_text(note("retracted", body="RETRACTED 2025-04: the claim below was wrong."))
            (live / "prose.md").write_text(note("prose", body="An earlier claim was retracted after review."))
            payload = json.loads(self.run_triage(fixture).stdout)
            flagged = {item["path"]: item for item in payload["flagged"]}
            self.assertIn("retracted.md", flagged)
            self.assertEqual(flagged["retracted.md"]["supersessions"], 1)
            self.assertNotIn("prose.md", flagged)

    def test_fresh_small_linked_note_not_flagged(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [A](alpha.md)\n- [B](beta.md)\n")
            (live / "alpha.md").write_text(note("alpha", body="Short durable fact."))
            (live / "beta.md").write_text(note("beta", body="See [[alpha]] for context."))
            result = self.run_triage(fixture)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["summary"]["flagged"], 0)
            self.assertEqual(payload["flagged"], [])
            self.assertNotIn("refusing to report clean", result.stderr)

    def test_empty_existing_live_root_refuses_to_report_clean(self):
        """PLANTED NEGATIVE: triage used to report 0 projects and flagged:0."""
        with tempfile.TemporaryDirectory() as temp:
            result = self.run_triage(Fixture(Path(temp)))
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("memory triage live projects", result.stderr)
            self.assertIn("examined 0 item(s), expected at least 1", result.stderr)

    def test_empty_and_single_note_projects_produce_no_flags(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            empty, _ = fixture.project("empty", mirror=False)
            (empty / "MEMORY.md").write_text("")
            single, _ = fixture.project("single", mirror=False)
            (single / "MEMORY.md").write_text("- [Only](only.md)\n")
            (single / "only.md").write_text(note("only", body="One small durable fact."))
            result = self.run_triage(fixture)
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["summary"]["flagged"], 0)

    def test_age_signal_uses_mtime_not_mirror(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [Old](old.md)\n")
            # Oversized so it flags structurally; the point of the test is that its
            # reported age comes from live mtime, never mirror git state.
            (live / "old.md").write_text(note("old", body="A" * 6500))
            # Mirror copy diverges (a mirror_stale_file condition), but triage age
            # must come from the live file's mtime regardless of any mirror state.
            (mirror / "old.md").write_text(note("old", body="Different stale mirror content."))
            old_ts = time.mktime(dt.date(2026, 1, 1).timetuple())
            os.utime(live / "old.md", (old_ts, old_ts))
            result = self.run_triage(fixture, "--now", "2026-07-17")
            payload = json.loads(result.stdout)
            flagged = {item["path"]: item for item in payload["flagged"]}
            self.assertIn("old.md", flagged)
            self.assertEqual(flagged["old.md"]["age_source"], "mtime")
            expected = (dt.date(2026, 7, 17) - dt.date(2026, 1, 1)).days
            self.assertEqual(flagged["old.md"]["age_days"], expected)
            self.assertTrue(any(r.startswith("age:") for r in flagged["old.md"]["reasons"]))

    def test_deterministic_output_and_single_flagged_line(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            for key in ("bravo", "alpha"):
                live, _ = fixture.project(key, mirror=False)
                (live / "MEMORY.md").write_text("- [Log](log.md)\n")
                (live / "log.md").write_text(note("log", body="y" * 6500))
            first = self.run_triage(fixture)
            second = self.run_triage(fixture)
            self.assertEqual(first.stdout, second.stdout)
            human = subprocess.run(
                ["python3", str(AUDITOR), "triage", "--live-root", str(fixture.live),
                 "--mirror-root", str(fixture.mirror)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(human.stdout.count("flagged:"), 1)
            self.assertTrue(human.stdout.rstrip().endswith("flagged:2"))
            # Human output is project-level only: no note filenames leak into it.
            self.assertNotIn("log.md", human.stdout)

    def test_json_envelope_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [L](log.md)\n")
            (live / "log.md").write_text(note("log", body="z" * 6500))
            payload = json.loads(self.run_triage(fixture).stdout)
            self.assertEqual(payload["schema_version"], 1)
            self.assertEqual(payload["command"], "triage")
            self.assertIn("roots", payload)
            for field in ("live_projects", "notes_scored", "flagged", "by_project"):
                self.assertIn(field, payload["summary"])
            record = payload["flagged"][0]
            for field in ("project", "path", "score", "reasons", "body_bytes", "age_days", "inbound_links", "supersessions"):
                self.assertIn(field, record)


class MemoryFixTests(unittest.TestCase):
    def run_fix(self, fixture, *args):
        command = [
            "python3", str(AUDITOR), "fix",
            "--live-root", str(fixture.live),
            "--mirror-root", str(fixture.mirror),
            "--format", "json",
            *args,
        ]
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def mirror_from_live(self, live, mirror):
        for path in live.iterdir():
            if path.is_file():
                shutil.copy2(path, mirror / path.name)

    def test_empty_existing_live_root_refuses_to_report_no_repairs(self):
        """PLANTED NEGATIVE: fix previously exited 0 with zero repairs."""
        with tempfile.TemporaryDirectory() as temp:
            result = self.run_fix(Fixture(Path(temp)))
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("memory fix live projects", result.stderr)
            self.assertIn("examined 0 item(s), expected at least 1", result.stderr)

    def test_single_candidate_rewrite_only(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [A](project_alpha_note.md)\n")
            (live / "project_alpha_note.md").write_text(note("alpha"))
            (live / "foo-bar.md").write_text(note("foobar-a"))
            (live / "foo_bar.md").write_text(note("foobar-b"))
            (live / "beta.md").write_text(
                note("beta", body="Links: [[alpha-note]], [[totally-unknown]], [[foo bar]].")
            )
            payload = json.loads(self.run_fix(fixture).stdout)
            rewrites = [r for r in payload["repairs"] if r["kind"] == "wikilink_rewrite"]
            self.assertEqual(len(rewrites), 1)
            self.assertEqual(rewrites[0]["link"], "alpha-note")
            self.assertEqual(rewrites[0]["resolves_to"], "project_alpha_note")

    def test_index_reconcile_append_drop_and_format_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            header = "# Memory index\n\nIntro prose line.\n\n"
            (live / "MEMORY.md").write_text(header + "- [Kept](kept.md)\n- [Gone](gone.md)\n")
            (live / "kept.md").write_text(note("kept"))
            (live / "fresh.md").write_text(
                '---\nname: fresh\ndescription: "Shipped as PR #99, tracked"\nmetadata:\n  type: project\n---\nBody.\n'
            )
            self.mirror_from_live(live, mirror)
            dry = json.loads(self.run_fix(fixture).stdout)
            reconcile = [r for r in dry["repairs"] if r["kind"] == "index_reconcile"]
            self.assertEqual(len(reconcile), 1)
            self.assertEqual(reconcile[0]["appended"], ["fresh.md"])
            self.assertEqual(reconcile[0]["dropped"], ["gone.md"])
            # Dry-run writes nothing.
            self.assertIn("- [Gone](gone.md)", (live / "MEMORY.md").read_text())
            # Apply and verify the reconciliation result.
            self.assertEqual(self.run_fix(fixture, "--apply").returncode, 0)
            text = (live / "MEMORY.md").read_text()
            self.assertTrue(text.startswith(header))  # header + prose preserved byte-for-byte
            self.assertIn("- [Kept](kept.md)", text)
            self.assertNotIn("gone.md", text)
            self.assertIn("(fresh.md)", text)
            self.assertIn("PR #99", text)  # '#' not truncated

    def test_dry_run_writes_nothing_and_preserves_bodies(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [A](project_alpha_note.md)\n")
            (live / "project_alpha_note.md").write_text(note("alpha"))
            beta_text = note("beta", body="See [[alpha-note]].")
            (live / "beta.md").write_text(beta_text)
            before = {p.name: p.read_bytes() for p in live.iterdir()}
            self.run_fix(fixture)
            after = {p.name: p.read_bytes() for p in live.iterdir()}
            self.assertEqual(before, after)

    def test_index_reconcile_keeps_mixed_dead_live_line(self):
        # A line naming both a gone and a surviving note is left intact, and the gone
        # target is NOT claimed as dropped (the record must never lie).
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            mixed = "- see [combo](gone.md) and [live](kept.md)\n"
            (live / "MEMORY.md").write_text(mixed + "- [Solo](solo-gone.md)\n")
            (live / "kept.md").write_text(note("kept"))
            self.mirror_from_live(live, mirror)
            payload = json.loads(self.run_fix(fixture).stdout)
            reconcile = [r for r in payload["repairs"] if r["kind"] == "index_reconcile"][0]
            # solo-gone.md is on an all-dead line -> droppable; gone.md is on a mixed
            # line -> not claimed.
            self.assertIn("solo-gone.md", reconcile["dropped"])
            self.assertNotIn("gone.md", reconcile["dropped"])
            self.assertEqual(self.run_fix(fixture, "--apply").returncode, 0)
            text = (live / "MEMORY.md").read_text()
            self.assertIn(mixed, text)  # mixed line preserved byte-for-byte
            self.assertNotIn("solo-gone.md", text)  # all-dead line removed

    def test_index_reconcile_leaves_the_archive_tiers_alone(self):
        """PLANTED NEGATIVE: fix planned to append every archive-tier note back into
        MEMORY.md (3,121 rehook-archived notes in the 2026-10-15 live dry run), undoing
        rehook's load-cap split, and to drop MEMORY.md's link to MEMORY-archive.md
        because that file is an index, not a note record."""
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            index = (
                "- [Kept](kept.md)\n"
                "- [Archive tier](memory-archive-index.md) — 1 hooked pointer\n"
                "- [Older entries](MEMORY-archive.md)\n"
            )
            (live / "MEMORY.md").write_text(index)
            (live / "memory-archive-index.md").write_text(
                note("memory-archive-index", note_type="reference", body="- [Hooked](hooked.md) — archived")
            )
            (live / "MEMORY-archive.md").write_text("- [Demoted](demoted.md) — cold entry\n")
            for name in ("kept", "hooked", "demoted", "orphan"):
                (live / f"{name}.md").write_text(note(name))
            self.mirror_from_live(live, mirror)
            payload = json.loads(self.run_fix(fixture).stdout)
            reconcile = [r for r in payload["repairs"] if r["kind"] == "index_reconcile"]
            self.assertEqual(len(reconcile), 1)
            self.assertEqual(reconcile[0]["appended"], ["orphan.md"])
            self.assertEqual(reconcile[0]["dropped"], [])
            self.assertEqual(self.run_fix(fixture, "--apply").returncode, 0)
            text = (live / "MEMORY.md").read_text()
            self.assertTrue(text.startswith(index))  # every existing line kept, archive links included
            self.assertIn("(orphan.md)", text)
            self.assertNotIn("(hooked.md)", text)
            self.assertNotIn("(demoted.md)", text)

    def test_index_reconcile_still_drops_a_link_to_a_missing_tier(self):
        # Only a tier file that exists keeps its MEMORY.md link; a link to a gone
        # MEMORY-archive.md is a dead line like any other.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [Kept](kept.md)\n- [Older entries](MEMORY-archive.md)\n")
            (live / "kept.md").write_text(note("kept"))
            self.mirror_from_live(live, mirror)
            payload = json.loads(self.run_fix(fixture).stdout)
            reconcile = [r for r in payload["repairs"] if r["kind"] == "index_reconcile"]
            self.assertEqual(len(reconcile), 1)
            self.assertEqual(reconcile[0]["appended"], [])
            self.assertEqual(reconcile[0]["dropped"], ["MEMORY-archive.md"])

    def test_index_reconcile_skips_a_project_whose_tier_is_unreadable(self):
        # Healing without the tier would append every note it lists back into
        # MEMORY.md, so an unreadable tier skips that project's reconcile instead
        # of ending the whole fix with a traceback.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [Kept](kept.md)\n")
            for name in ("kept", "orphan"):
                (live / f"{name}.md").write_text(note(name))
            records = MA.scan_project_notes(live)
            self.assertEqual(MA.compute_index_reconcile("project", live, records)["appended"], ["orphan.md"])
            with mock.patch.object(MA, "archive_tier_targets", side_effect=PermissionError("unreadable tier")):
                self.assertIsNone(MA.compute_index_reconcile("project", live, records))

    def test_apply_refuses_stale_mirror_and_preserves_mtime(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [A](project_alpha_note.md)\n- [B](beta.md)\n")
            (live / "project_alpha_note.md").write_text(note("alpha"))
            beta = live / "beta.md"
            beta.write_text(note("beta", body="See [[alpha-note]]."))
            self.mirror_from_live(live, mirror)
            # Diverge the mirror: the affected project is now stale.
            (mirror / "project_alpha_note.md").write_text(note("alpha", body="mirror drift"))
            refused = self.run_fix(fixture, "--apply")
            self.assertEqual(refused.returncode, 1)
            self.assertIn("mirror not fresh", refused.stderr)
            self.assertIn("[[alpha-note]]", beta.read_text())  # nothing written
            # Re-sync the mirror, then apply and confirm mtime is preserved.
            self.mirror_from_live(live, mirror)
            pre = beta.stat().st_mtime_ns
            time.sleep(0.02)
            self.assertEqual(self.run_fix(fixture, "--apply").returncode, 0)
            self.assertIn("[[project_alpha_note]]", beta.read_text())
            self.assertEqual(beta.stat().st_mtime_ns, pre)

    def test_apply_with_no_mirror_named_checks_the_pushed_backup_ref(self):
        """PLANTED NEGATIVE (#1918): with no --mirror-root, a matching copy committed
        but never pushed refuses; only the backup ref's tree lets the apply through."""
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [A](project_alpha_note.md)\n- [B](beta.md)\n")
            (live / "project_alpha_note.md").write_text(note("alpha"))
            beta = live / "beta.md"
            beta.write_text(note("beta", body="See [[alpha-note]]."))
            repo = BackupRepo(Path(temp))
            command = ["python3", str(AUDITOR), "fix", "--live-root", str(fixture.live), "--apply", "--format", "json"]
            stale = {**snapshot(live), "project_alpha_note.md": note("alpha", body="older").encode()}
            repo.commit("project", stale, push=True)
            repo.commit("project", snapshot(live), push=False)
            refused = subprocess.run(command, text=True, capture_output=True, check=False, env=repo.env())
            self.assertEqual(refused.returncode, 1)
            self.assertIn(
                "memory-fix: refusing to apply to project: mirror not fresh (mirror_stale_file); "
                "checked against refs/remotes/origin/backup/claude-memory",
                refused.stderr,
            )
            self.assertIn("[[alpha-note]]", beta.read_text())  # nothing written
            repo.git("update-ref", MA.PUSHED_MIRROR_REF, "HEAD")
            applied = subprocess.run(command, text=True, capture_output=True, check=False, env=repo.env())
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual(json.loads(applied.stdout)["roots"]["mirror"], MA.PUSHED_MIRROR_REF)
            self.assertIn("[[project_alpha_note]]", beta.read_text())


class MemorySyncTests(unittest.TestCase):
    def run_sync(self, home, mirror, mode):
        env = os.environ.copy()
        env.update({"HOME": str(home), "CLAUDE_MEMORY_MIRROR_ROOT": str(mirror)})
        return subprocess.run(
            ["bash", str(SYNC), mode], env=env, text=True, capture_output=True, check=False
        )

    def test_preview_then_push_is_non_destructive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            live = home / ".claude" / "projects" / "project" / "memory"
            mirror = root / "mirror"
            destination = mirror / "project"
            live.mkdir(parents=True)
            destination.mkdir(parents=True)
            (live / "MEMORY.md").write_text("[Live](live.md)\n")
            (live / "live.md").write_text(note("live"))
            (destination / "orphan.md").write_text(note("orphan"))

            preview = self.run_sync(home, mirror, "memory-preview")
            self.assertEqual(preview.returncode, 1)
            self.assertIn("COPY project/MEMORY.md", preview.stdout)
            self.assertIn("KEEP mirror-only project/orphan.md", preview.stdout)
            self.assertFalse((destination / "live.md").exists())

            pushed = self.run_sync(home, mirror, "memory-push")
            self.assertEqual(pushed.returncode, 0)
            self.assertTrue((destination / "live.md").exists())
            self.assertTrue((destination / "orphan.md").exists())
            # Once the copy is done, the only remaining finding is a path the
            # push deliberately preserved. There is no command in sync.sh that
            # can clear it, so it is reported but is not drift -- otherwise
            # `check` prints "DRIFT: memory differs" forever and stops meaning
            # anything (46 such paths on the box where this was found).
            checked = self.run_sync(home, mirror, "memory-check")
            self.assertEqual(checked.returncode, 0)
            self.assertIn("KEEP mirror-only project/orphan.md", checked.stdout)
            self.assertIn("memory in sync", checked.stdout)

    def test_vanished_live_store_is_drift_not_silence(self):
        """A whole live project gone is loss, not deletion hygiene.

        This is what keeps the KEEP-is-informational rule safe. The corpus floor
        counts mirrored files too, so a live root that disappeared still walks
        the mirror, still satisfies the floor, and -- if every mirror-only path
        were merely informational -- would report "memory in sync" while the
        real store was gone. The per-project LOST line is the tripwire, and it
        is silent whenever the live store exists.
        """
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            live = home / ".claude" / "projects" / "project" / "memory"
            mirror = root / "mirror"
            destination = mirror / "project"
            live.mkdir(parents=True)
            destination.mkdir(parents=True)
            (live / "MEMORY.md").write_text("[Live](live.md)\n")
            (live / "live.md").write_text(note("live"))
            self.assertEqual(self.run_sync(home, mirror, "memory-push").returncode, 0)

            # Baseline: mirrored and live agree, so the tripwire is silent.
            clean = self.run_sync(home, mirror, "memory-check")
            self.assertEqual(clean.returncode, 0)
            self.assertNotIn("LOST live store", clean.stdout)

            # Now the live store disappears the way an unmounted home or a
            # wiped ~/.claude would take it, leaving the mirror untouched.
            shutil.rmtree(live)
            lost = self.run_sync(home, mirror, "memory-check")
            self.assertEqual(lost.returncode, 1)
            self.assertIn("LOST live store project", lost.stdout)
            self.assertNotIn("memory in sync", lost.stdout)
            # Reported once for the project, not once per orphaned note.
            self.assertEqual(lost.stdout.count("LOST live store"), 1)

    def test_push_quarantines_sensitive_file_and_copies_the_rest(self):
        """One flagged note must not cost every other note its backup.

        The flagged bytes stay out of the mirror either way; refusing the whole
        push only added collateral. Six consecutive nightly backups were lost to
        that behaviour on filename false positives.
        """
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            live = home / ".claude" / "projects" / "project" / "memory"
            mirror = root / "mirror"
            live.mkdir(parents=True)
            mirror.mkdir()
            (live / "MEMORY.md").write_text("[Secret](secret.md)\n[Clean](clean.md)\n")
            (live / "secret.md").write_text(
                note("secret", body="api_key=highsignalsignaturevalue123456789")
            )
            (live / "clean.md").write_text(note("clean"))

            pushed = self.run_sync(home, mirror, "memory-push")
            self.assertEqual(pushed.returncode, 0)
            self.assertFalse((mirror / "project" / "secret.md").exists())
            self.assertTrue((mirror / "project" / "clean.md").exists())
            self.assertTrue((mirror / "project" / "MEMORY.md").exists())
            # The diagnostic names the path; the old refusal named nothing.
            self.assertIn("QUARANTINE", pushed.stderr)
            self.assertIn("project/secret.md", pushed.stderr)
            self.assertIn("quarantined path(s) NOT copied", pushed.stdout)

    def test_quarantine_exclusion_is_anchored_per_project(self):
        """A same-named note in another project keeps its backup."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            projects = home / ".claude" / "projects"
            flagged = projects / "flagged" / "memory"
            other = projects / "other" / "memory"
            mirror = root / "mirror"
            flagged.mkdir(parents=True)
            other.mkdir(parents=True)
            mirror.mkdir()
            for directory in (flagged, other):
                (directory / "MEMORY.md").write_text("[Note](note.md)\n")
            (flagged / "note.md").write_text(
                note("note", body="api_key=highsignalsignaturevalue123456789")
            )
            (other / "note.md").write_text(note("note"))

            pushed = self.run_sync(home, mirror, "memory-push")
            self.assertEqual(pushed.returncode, 0)
            self.assertFalse((mirror / "flagged" / "note.md").exists())
            self.assertTrue((mirror / "other" / "note.md").exists())

    def test_push_refuses_symlinked_memory_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            outside = root / "outside"
            outside.mkdir()
            (outside / "MEMORY.md").write_text("")
            parent = home / ".claude" / "projects" / "linked"
            parent.mkdir(parents=True)
            (parent / "memory").symlink_to(outside)
            mirror = root / "mirror"
            mirror.mkdir()

            pushed = self.run_sync(home, mirror, "memory-push")
            self.assertNotEqual(pushed.returncode, 0)
            self.assertFalse((mirror / "linked").exists())

    def test_push_refuses_live_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            live = home / ".claude" / "projects" / "project" / "memory"
            mirror = root / "mirror"
            outside = root / "outside.md"
            live.mkdir(parents=True)
            mirror.mkdir()
            outside.write_text(note("outside"))
            (live / "MEMORY.md").write_text("[Outside](outside.md)\n")
            (live / "outside.md").symlink_to(outside)

            preview = self.run_sync(home, mirror, "memory-preview")
            self.assertEqual(preview.returncode, 1)
            self.assertIn("BLOCK live symlink project/outside.md", preview.stdout)

            pushed = self.run_sync(home, mirror, "memory-push")
            self.assertEqual(pushed.returncode, 1)
            self.assertIn("live symlink in the memory store", pushed.stderr)
            # A symlink means the store is no longer a self-contained tree, so
            # this one stays a whole-push refusal rather than a quarantine.
            self.assertIn("BLOCK live_symlink project/outside.md", pushed.stderr)
            self.assertFalse((mirror / "project").exists())


class TriageDescriptionTests(unittest.TestCase):
    """Description-quality flags: recall is description-routed, so triage surfaces
    unroutable descriptions for a redescribe proposal."""

    run_triage = MemoryTriageTests.run_triage

    def test_short_and_duplicate_descriptions_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [A](a.md)\n- [B](b.md)\n- [C](c.md)\n- [D](d.md)\n")
            short = note("a").replace("description: Fixture note describing a in detail", "description: Vague words")
            (live / "a.md").write_text(short)
            dup = note("b").replace("describing b in detail", "covering the same exact topic")
            (live / "b.md").write_text(dup)
            dup2 = note("c").replace("describing c in detail", "covering the same exact topic")
            (live / "c.md").write_text(dup2)
            (live / "d.md").write_text(note("d", body="Fine and healthy."))
            result = self.run_triage(fixture)
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            flagged = {item["path"]: item["reasons"] for item in payload["flagged"]}
            self.assertIn("desc_short", flagged["a.md"])
            self.assertIn("desc_dup", flagged["b.md"])
            self.assertIn("desc_dup", flagged["c.md"])
            self.assertNotIn("d.md", flagged)

    def test_index_over_budget_warns(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "a.md").write_text(note("a"))
            # 150 effective lines >= 70% of the 200-line session load cap.
            (live / "MEMORY.md").write_text("- [A](a.md)\n" + "context line\n" * 149)
            result = self.run_triage(fixture)
            payload = json.loads(result.stdout)
            over = payload["summary"]["index_over_budget"]
            self.assertIn("project", over)
            self.assertEqual(over["project"]["lines"], 150)
            human = subprocess.run(
                ["python3", str(AUDITOR), "triage", "--live-root", str(fixture.live), "--mirror-root", str(fixture.mirror)],
                text=True, capture_output=True, check=False,
            )
            self.assertIn("WARN project: MEMORY.md at 150/200 lines", human.stdout)

    def test_index_within_budget_no_warning(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "a.md").write_text(note("a"))
            (live / "MEMORY.md").write_text("- [A](a.md)\n")
            payload = json.loads(self.run_triage(fixture).stdout)
            self.assertEqual(payload["summary"]["index_over_budget"], {})


class DecayTests(unittest.TestCase):
    """Confidence decay (0.5 half-life, 90d, 0.3 flag threshold) through the
    shared decay_effective() helper, exercised at BOTH call sites (audit() and
    triage_project()) so the extracted helper is proven to agree with itself."""

    run_audit = MemoryAuditTests.run_audit
    run_triage = MemoryTriageTests.run_triage

    def _decay_note(self, name, confidence, last_validated, note_type="project"):
        extra = f"  confidence: {confidence}\n  last_validated: {last_validated}\n"
        return note(name, note_type=note_type, extra=extra, body="Body has enough content to avoid other flags.")

    # -- audit() -----------------------------------------------------------

    def test_audit_flags_just_below_threshold(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            last_validated = (dt.date.today() - dt.timedelta(days=157)).isoformat()
            (live / "MEMORY.md").write_text("[N](decayed.md)\n")
            (live / "decayed.md").write_text(self._decay_note("decayed", 1.0, last_validated))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            decayed = [f for f in findings if f["kind"] == "decayed_confidence"]
            self.assertEqual(len(decayed), 1)
            self.assertEqual(decayed[0]["path"], "decayed.md")
            self.assertLess(decayed[0]["effective"], 0.3)

    def test_audit_does_not_flag_just_above_threshold(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            last_validated = (dt.date.today() - dt.timedelta(days=150)).isoformat()
            (live / "MEMORY.md").write_text("[N](fresh.md)\n")
            (live / "fresh.md").write_text(self._decay_note("fresh", 1.0, last_validated))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            self.assertFalse([f for f in findings if f["kind"] == "decayed_confidence"])

    def test_audit_unparseable_last_validated_flags_problem_not_decay(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[N](broken.md)\n")
            (live / "broken.md").write_text(self._decay_note("broken", 0.9, "not-a-date"))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            self.assertFalse([f for f in findings if f["kind"] == "decayed_confidence"])
            problems = [p for f in findings if f["kind"] == "invalid_frontmatter" for p in f["problems"]]
            self.assertIn("confidence/last_validated present but unparseable", problems)

    def test_audit_non_numeric_confidence_flags_problem_not_decay(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[N](broken.md)\n")
            (live / "broken.md").write_text(self._decay_note("broken", "high", "2026-01-01"))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            self.assertFalse([f for f in findings if f["kind"] == "decayed_confidence"])
            problems = [p for f in findings if f["kind"] == "invalid_frontmatter" for p in f["problems"]]
            self.assertIn("confidence/last_validated present but unparseable", problems)

    def test_audit_only_one_of_pair_present_no_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("[N](half.md)\n")
            (live / "half.md").write_text(note("half", extra="  confidence: 0.1\n"))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            result = self.run_audit(fixture)
            findings = json.loads(result.stdout)["findings"]
            self.assertFalse([f for f in findings if f["kind"] == "decayed_confidence"])
            problems = [p for f in findings if f["kind"] == "invalid_frontmatter" for p in f["problems"]]
            self.assertNotIn("confidence/last_validated present but unparseable", problems)

    # -- triage_project() ---------------------------------------------------

    def test_triage_flags_just_below_threshold(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [D](decayed.md)\n")
            (live / "decayed.md").write_text(self._decay_note("decayed", 1.0, "2026-01-01"))
            now = (dt.date(2026, 1, 1) + dt.timedelta(days=157)).isoformat()
            result = self.run_triage(fixture, "--now", now)
            payload = json.loads(result.stdout)
            flagged = {item["path"]: item["reasons"] for item in payload["flagged"]}
            self.assertIn("decayed.md", flagged)
            self.assertTrue(any(r.startswith("decayed_confidence") for r in flagged["decayed.md"]))

    def test_triage_does_not_flag_just_above_threshold(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [F](fresh.md)\n")
            (live / "fresh.md").write_text(self._decay_note("fresh", 1.0, "2026-01-01"))
            now = (dt.date(2026, 1, 1) + dt.timedelta(days=150)).isoformat()
            result = self.run_triage(fixture, "--now", now)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["summary"]["flagged"], 0)

    def test_triage_unparseable_last_validated_no_flag_no_crash(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [B](broken.md)\n")
            (live / "broken.md").write_text(self._decay_note("broken", 0.9, "not-a-date"))
            result = self.run_triage(fixture)
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["summary"]["flagged"], 0)

    def test_triage_non_numeric_confidence_no_flag_no_crash(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [B](broken.md)\n")
            (live / "broken.md").write_text(self._decay_note("broken", "high", "2026-01-01"))
            result = self.run_triage(fixture)
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["summary"]["flagged"], 0)

    def test_triage_only_one_of_pair_present_no_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project(mirror=False)
            (live / "MEMORY.md").write_text("- [H](half.md)\n")
            (live / "half.md").write_text(note("half", extra="  last_validated: 2020-01-01\n"))
            result = self.run_triage(fixture)
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["summary"]["flagged"], 0)


class AuditHelperTests(unittest.TestCase):
    """Pure-helper coverage for the v2 index and frontmatter machinery."""

    def test_effective_index_size_matches_load_accounting(self):
        text = "---\nname: idx\n---\n<!-- hidden\ncomment -->\nline one\nline two\n"
        lines, size = MA.effective_index_size(text)
        # Frontmatter and the HTML comment are stripped before counting (v2.1.211).
        self.assertEqual(lines, 3)  # blank line left by the stripped comment + two lines
        self.assertEqual(size, len("\nline one\nline two\n".encode()))

    def test_index_reconcile_append_restriction(self):
        # The dream pass appends only the notes it created; corpus-wide healing of
        # pre-existing unindexed notes is a separately gated step (fix mode).
        with tempfile.TemporaryDirectory() as temp:
            memory = Path(temp) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text("- [a](a.md)\n")
            for name in ("a", "b", "new"):
                (memory / f"{name}.md").write_text(note(name))
            records = MA.scan_project_notes(memory)
            restricted = MA.compute_index_reconcile("p", memory, records, restrict_appends_to={"new.md"})
            self.assertEqual(restricted["appended"], ["new.md"])  # b.md left for fix mode
            healing = MA.compute_index_reconcile("p", memory, records)
            self.assertEqual(healing["appended"], ["b.md", "new.md"])

    def test_description_similarity_content_words(self):
        self.assertGreaterEqual(
            MA.description_similarity(
                "reusable MLX serving gotchas from the champion trial",
                "reusable MLX serving lessons from the champion trial",
            ),
            0.6,
        )
        self.assertLess(
            MA.description_similarity(
                "reusable operational gotcha worth recalling",
                "durable sizing rule derived in the trial",
            ),
            0.3,
        )
        self.assertEqual(MA.description_similarity("", "anything"), 0.0)

    def test_loaded_index_text_truncates_like_the_session_loader(self):
        text = "---\nname: idx\n---\n<!-- hidden -->\n" + "line\n" * 250
        loaded = MA.loaded_index_text(text)
        # Frontmatter/comments stripped, then hard cut at 200 lines: entries past
        # the cap are invisible to a real session, so judges never see them.
        self.assertEqual(len(loaded.splitlines()), 200)
        big = "---\nname: idx\n---\n" + ("y" * 90 + "\n") * 400
        self.assertLessEqual(len(MA.loaded_index_text(big).encode()), MA.INDEX_LOAD_MAX_BYTES)

    def test_refresh_index_lines_only_sole_target_canonical_lines(self):
        index = "- [A](a.md): stale hook\n- mixed [A](a.md) and [B](b.md)\n- [B](b.md)\n"
        entry = {"a.md": {"old": ("A", "stale hook"), "new": ("A", "fresh hook"), "force": False}}
        refreshed = MA.refresh_index_lines(index, entry)
        self.assertIn("- [A](a.md): fresh hook\n", refreshed)
        self.assertIn("- mixed [A](a.md) and [B](b.md)\n", refreshed)  # mixed line untouched
        self.assertIn("- [B](b.md)\n", refreshed)  # unrefreshed line untouched

    def test_refresh_index_lines_preserves_hand_edited_lines(self):
        # A line that deviates from the canonical rendering of the note's pre-rewrite
        # frontmatter is hand-edited: never clobber it (KTD7)...
        index = "- [A](a.md): stale hook; NOTE also see runbook.md steps\n"
        entry = {"a.md": {"old": ("A", "stale hook"), "new": ("A", "fresh hook"), "force": False}}
        self.assertEqual(MA.refresh_index_lines(index, entry), index)
        # ...unless the action is redescribe, whose approved purpose is exactly to
        # replace the routing hook (and the index diff is in the preview).
        forced = {"a.md": {"old": ("A", "stale hook"), "new": ("A", "fresh hook"), "force": True}}
        self.assertEqual(MA.refresh_index_lines(index, forced), "- [A](a.md): fresh hook\n")

    def test_index_reconcile_strips_dead_fragment_from_packed_line(self):
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as temp:
            memory = Path(temp)
            (memory / "live.md").write_text("---\nname: live\ndescription: live note here\nmetadata:\n  type: project\n---\nBody.\n")
            (memory / "MEMORY.md").write_text(
                "# idx\n"
                "- Packed: [Live](live.md) still here; [Dead](dead.md) gone note; [Live2](live.md) again\n"
                "- [dead2](dead2.md): a whole-dead line\n"
            )
            records = {"live.md": {}}
            plan = MA.compute_index_reconcile("proj", memory, records, restrict_appends_to=set())
            self.assertEqual(plan["dropped"], ["dead2.md"])
            self.assertEqual(plan["fragment_dropped"], ["dead.md"])
            out = MA.render_index_reconcile((memory / "MEMORY.md").read_text(), memory, plan)
            self.assertIn("- Packed: [Live](live.md) still here; [Live2](live.md) again\n", out)
            self.assertNotIn("dead.md", out)
            self.assertNotIn("dead2.md", out)

    def test_strip_dead_index_fragments_conservative_on_mixed_fragment(self):
        # A single fragment carrying both a dead and a live link is left intact.
        line = "- Packed: [A](a.md) and [Dead](dead.md) together; [B](b.md) alone\n"
        out = MA.strip_dead_index_fragments(line, {"dead.md"})
        self.assertEqual(out, line)

    def test_preserve_metadata_extra_nested_inserts_and_replaces(self):
        donor = (
            "---\nname: a\ndescription: donor description with enough words\nmetadata:\n"
            "  node_type: memory\n  type: project\n  originSessionId: sess-a\n---\nBody.\n"
        )
        drafter = "---\nname: a\ndescription: merged description with enough words\nmetadata:\n  type: project\n---\nMerged.\n"
        merged = MA.preserve_metadata(drafter, donor, {"originSessionIds": "sess-a, sess-b"})
        self.assertIn("originSessionId: sess-a\n", merged)
        self.assertIn("  originSessionIds: sess-a, sess-b\n", merged)
        again = MA.preserve_metadata(merged, merged, {"originSessionIds": "sess-c"})
        self.assertIn("  originSessionIds: sess-c\n", again)
        self.assertNotIn("sess-a, sess-b", again)  # replaced, not duplicated

    def test_preserve_metadata_normalizes_flat_schema_donor(self):
        # A legacy flat-schema donor is normalized during consolidation: its
        # harness fields are lifted (values verbatim) into a nested metadata
        # block, so results follow the canonical shape and extra_nested fields
        # are no longer silently dropped.
        donor = "---\nname: a\ndescription: legacy flat schema donor note here\ntype: project\noriginSessionId: sess-a\n---\nBody.\n"
        drafter = "---\nname: a\ndescription: merged description with enough words\nmetadata:\n  type: reference\n---\nMerged.\n"
        merged = MA.preserve_metadata(drafter, donor, {"originSessionIds": "sess-a, sess-b"})
        # Assert through the parser, not substring presence: the block must sit
        # INSIDE the --- delimiters or the parser drops it (the original bug
        # appended it after the closing delimiter).
        meta, error, _body, _raw = MA.parse_frontmatter(merged)
        self.assertIsNone(error)
        nested = meta.get("metadata")
        self.assertIsInstance(nested, dict)
        self.assertEqual(nested.get("type"), "reference")  # drafter's type overlays lifted donor type
        self.assertEqual(nested.get("originSessionId"), "sess-a")  # lifted, value preserved
        self.assertEqual(nested.get("originSessionIds"), "sess-a, sess-b")  # extra_nested lands
        fm = merged.split("---")[1]
        self.assertNotRegex(fm, r"(?m)^type:")  # no top-level survivors
        self.assertNotRegex(fm, r"(?m)^originSessionId:")

    def test_preserve_metadata_flat_normalization_is_lift_only(self):
        # Lift-only: fields the donor lacks (node_type here) are never invented,
        # and unknown top-level fields stay top-level.
        donor = "---\nname: a\ndescription: legacy flat schema donor note here\ntype: project\ncustom_field: kept\n---\nBody.\n"
        drafter = "---\nname: a\ndescription: merged description with enough words\nmetadata:\n  type: project\n---\nMerged.\n"
        merged = MA.preserve_metadata(drafter, donor)
        meta, error, _body, _raw = MA.parse_frontmatter(merged)
        self.assertIsNone(error)
        self.assertEqual((meta.get("metadata") or {}).get("type"), "project")
        self.assertNotIn("node_type", merged)
        self.assertIn("custom_field: kept\n", merged)
        fm = merged.split("---")[1]
        self.assertNotRegex(fm, r"(?m)^type:")

    def test_origin_session_id_both_schemas(self):
        nested = "---\nname: a\ndescription: nested schema note with words\nmetadata:\n  originSessionId: sess-n\n  type: project\n---\nB.\n"
        flat = "---\nname: a\ndescription: flat schema note with words\ntype: project\noriginSessionId: sess-f\n---\nB.\n"
        self.assertEqual(MA.origin_session_id(nested), "sess-n")
        self.assertEqual(MA.origin_session_id(flat), "sess-f")
        self.assertIsNone(MA.origin_session_id("no frontmatter at all"))

    def test_redescribe_content_replaces_only_description(self):
        donor = "---\nname: a\ndescription: old stale hook\nmetadata:\n  type: project\n---\nBody stays.\n"
        rebuilt = MA.redescribe_content(donor, "shipped as PR #99 gate green")
        self.assertIsNotNone(rebuilt)
        self.assertIn('description: "shipped as PR #99 gate green"\n', rebuilt)  # quoted: contains '#'
        self.assertIn("Body stays.\n", rebuilt)
        self.assertEqual(
            rebuilt.replace('description: "shipped as PR #99 gate green"', "description: old stale hook"),
            donor,
        )

    def test_redescribe_content_neutralizes_newline_injection(self):
        # The redescribe description is the only drafter-controlled scalar that
        # reaches frontmatter raw from JSON; an embedded newline must never become
        # an injected frontmatter line.
        donor = "---\nname: a\ndescription: old\nmetadata:\n  type: project\n---\nBody.\n"
        rebuilt = MA.redescribe_content(donor, "innocent\ninjectedKey: attacker value")
        self.assertNotIn("\ninjectedKey", rebuilt)
        metadata, error, body, _raw = MA.parse_frontmatter(rebuilt)
        self.assertIsNone(error)
        self.assertEqual(body, "Body.")
        self.assertEqual(sorted(metadata.keys()), ["description", "metadata", "name"])
        self.assertIsNone(MA.redescribe_content(donor, " \n "))  # whitespace-only rejected

    def test_unbalanced_paren_description_flags_truncated(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, _ = fixture.project()
            content = note("a").replace(
                "description: Fixture note describing a in detail",
                "description: Fixed the gateway stamp (issue",
            )
            (live / "a.md").write_text(content)
            (live / "MEMORY.md").write_text("- [A](a.md)\n")
            result = subprocess.run(
                ["python3", str(AUDITOR), "--live-root", str(fixture.live), "--mirror-root", str(fixture.mirror), "--format", "json"],
                text=True, capture_output=True, check=False,
            )
            payload = json.loads(result.stdout)
            kinds = {finding["kind"] for finding in payload["findings"]}
            self.assertIn("truncated_description", kinds)


if __name__ == "__main__":
    unittest.main()


class TriageSuppressionTests(unittest.TestCase):
    def test_recently_applied_notes_suppressed(self):
        # A note an applied dream pass touched within the window is reported
        # under suppressed, not flagged (refire churn, pass-9 lesson).
        import json as json_mod
        import os as os_mod
        import subprocess
        import tempfile
        from pathlib import Path as P

        with tempfile.TemporaryDirectory() as temp:
            root = P(temp)
            memory = root / "live" / "proj" / "memory"
            memory.mkdir(parents=True)
            big_body = "RESOLVED\n" + ("x" * 7000)
            (memory / "big.md").write_text(
                "---\nname: big\ndescription: a large consolidated note fixture here\n"
                "metadata:\n  type: project\n---\n" + big_body
            )
            (memory / "MEMORY.md").write_text("# Index\n- [big](big.md) - fixture\n")
            pass_dir = root / "passes" / "20260101-000000"
            pass_dir.mkdir(parents=True)
            (pass_dir / "manifest.json").write_text(json_mod.dumps(
                {"proposals": [{"project": "proj", "results": [{"path": "big.md", "content": "x"}]}]}
            ))
            (pass_dir / "apply-manifest.json").write_text("{}")
            env = dict(os_mod.environ, MEMORY_DREAM_PASS_ROOT=str(root / "passes"))
            out = subprocess.run(
                ["python3", str(P(__file__).resolve().parent.parent / "scripts" / "memory-audit.py"),
                 "triage", "--format", "json", "--live-root", str(root / "live")],
                capture_output=True, text=True, env=env, check=False,
            )
            result = json_mod.loads(out.stdout)
            self.assertEqual(result["summary"]["flagged"], 0)
            self.assertEqual(result["summary"]["suppressed_recently_applied"], 1)
            self.assertEqual(result["suppressed"][0]["path"], "big.md")
            out2 = subprocess.run(
                ["python3", str(P(__file__).resolve().parent.parent / "scripts" / "memory-audit.py"),
                 "triage", "--format", "json", "--live-root", str(root / "live"),
                 "--suppress-applied-days", "0"],
                capture_output=True, text=True, env=env, check=False,
            )
            result2 = json_mod.loads(out2.stdout)
            self.assertEqual(result2["summary"]["flagged"], 1)


class RehookTests(unittest.TestCase):
    """memory-audit.py rehook (#1450): bare `[-](slug.md)` fragments become hooked
    lines rendered from frontmatter, every entry ranks user-first then newest-first,
    MEMORY.md is filled under the load budget and the rest moves, hooked, into the
    archive tier. Previously hooked lines keep their text byte-for-byte."""

    NOW = dt.date(2026, 9, 28)
    POINTER = "- [Archive tier](memory-archive-index.md) — older notes\n"

    def make_project(self, temp, index_text, notes, mirror=True):
        fixture = Fixture(Path(temp))
        live, mirror_dir = fixture.project(mirror=mirror)
        (live / "MEMORY.md").write_text(index_text)
        for rel, (note_type, modified) in notes.items():
            extra = f"  modified: {modified}\n" if modified else ""
            (live / rel).write_text(note(rel[:-3], note_type, extra=extra))
        return fixture, live, mirror_dir

    def plan(self, live, forced=False):
        return MA.compute_rehook("project", live, MA.scan_project_notes(live), self.NOW, forced=forced)

    def cli(self, fixture, command, *args):
        return subprocess.run(
            ["python3", str(AUDITOR), command, "--live-root", str(fixture.live), "--mirror-root", str(fixture.mirror), *args],
            text=True, capture_output=True, check=False,
        )

    @staticmethod
    def entry(rel):
        name = rel[:-3]
        return f"- [{name}]({rel}): Fixture note describing {name} in detail\n"

    def test_root_and_format_flags_before_the_subcommand_are_honoured(self):
        # Each subparser re-declared these flags with their defaults, which overwrote a
        # value given before the subcommand: `--live-root X rehook --apply` planned and
        # wrote against the real store. The env defaults here point nowhere, so the
        # pre-fix code refuses instead of reading the real store.
        with tempfile.TemporaryDirectory() as temp:
            fixture, _, _ = self.make_project(temp, "# idx\n", {"a.md": ("project", None)})
            env = {
                **os.environ,
                "CLAUDE_MEMORY_LIVE_ROOT": str(Path(temp) / "absent-live"),
                "CLAUDE_MEMORY_MIRROR_ROOT": str(Path(temp) / "absent-mirror"),
            }
            for command in ("triage", "fix", "rehook"):
                with self.subTest(command=command):
                    result = subprocess.run(
                        ["python3", str(AUDITOR), "--live-root", str(fixture.live), "--mirror-root", str(fixture.mirror), "--format", "json", command],
                        text=True, capture_output=True, check=False, env=env,
                    )
                    self.assertNotIn("not a directory", result.stderr)
                    payload = json.loads(result.stdout)
                    self.assertEqual(payload["roots"], {"live": str(fixture.live), "mirror": str(fixture.mirror)})

    def test_clip_description_cuts_on_a_word_boundary(self):
        text = "alpha beta gamma delta epsilon"
        self.assertEqual(MA.clip_description(text, 12), "alpha beta")  # mid-word cut backs up
        self.assertEqual(MA.clip_description(text, 10), "alpha beta")  # cut lands on a space
        self.assertEqual(MA.clip_description("alpha beta, gamma", 12), "alpha beta")  # no dangling comma
        self.assertEqual(MA.clip_description("short one", 50), "short one")
        self.assertEqual(MA.clip_description("a  b\n c", 50), "a b c")  # whitespace collapsed
        self.assertEqual(MA.clip_description("", 50), "")

    def test_parse_index_entries_expands_packed_lines_and_pins_hooked_text(self):
        index = (
            "# idx\n"
            + self.POINTER
            + "- [-](a.md);[-](b.md);[Hooked C](c.md) hand text; [-](a.md)\n"
            "- [D](d.md): canonical d\n"
            "- prose with [E](e.md) and [F](f.md) is not an entry\n"
            "- [again](memory-archive-index.md) second link\n"
        )
        parsed = MA.parse_index_entries(index)
        self.assertEqual(parsed["preamble"], ["# idx\n"])
        self.assertEqual(parsed["pointer"], ("Archive tier", self.POINTER))
        self.assertEqual(parsed["fragments"], ["a.md", "b.md"])  # the duplicate a.md collapses
        self.assertEqual(parsed["entries"]["c.md"], "- [Hooked C](c.md) hand text\n")
        self.assertEqual(parsed["entries"]["d.md"], "- [D](d.md): canonical d\n")
        self.assertEqual(parsed["unsplit"], ["- prose with [E](e.md) and [F](f.md) is not an entry\n"])
        self.assertEqual(
            parsed["other"],
            ["- prose with [E](e.md) and [F](f.md) is not an entry\n", "- [again](memory-archive-index.md) second link\n"],
        )

    def test_rehook_renders_fragments_and_ranks_user_first_then_newest(self):
        with tempfile.TemporaryDirectory() as temp:
            index = (
                "# idx\n"
                + self.POINTER
                + "- [-](a.md);[-](b.md);[Hooked C](c.md) hand text\n"
                "- [D](d.md) :: hand-edited, odd spacing   \n"
            )
            notes = {
                "a.md": ("feedback", "2026-09-01T00:00:00Z"),
                "b.md": ("project", "2026-09-10T00:00:00Z"),
                "c.md": ("project", None),  # no frontmatter stamp: file mtime ranks it
                "d.md": ("user", "2026-08-01T00:00:00Z"),  # oldest, yet user notes rank first
                "e.md": ("reference", "2026-09-05T00:00:00Z"),  # in neither index
            }
            notes["f.md"] = ("project", "garbage")  # malformed stamp: file mtime ranks it
            _fixture, live, _ = self.make_project(temp, index, notes)
            sep7 = time.mktime((2026, 9, 7, 0, 0, 0, 0, 0, -1))
            sep8 = time.mktime((2026, 9, 8, 0, 0, 0, 0, 0, -1))
            os.utime(live / "c.md", (sep7, sep7))  # must land between b (Sep 10) and e (Sep 5)
            os.utime(live / "f.md", (sep8, sep8))
            plan = self.plan(live)
            self.assertTrue(plan["changed"])
            self.assertEqual(plan["fragments"], ["a.md", "b.md"])
            self.assertEqual(plan["unindexed"], ["e.md", "f.md"])
            self.assertEqual(plan["kept"], ["d.md", "b.md", "f.md", "c.md", "e.md", "a.md"])
            self.assertEqual(plan["moved"], [])
            self.assertEqual(
                plan["main_text"],
                "# idx\n"
                + self.POINTER  # nothing moved, so the pointer is untouched
                + "- [D](d.md) :: hand-edited, odd spacing   \n"
                + self.entry("b.md")
                + self.entry("f.md")
                + "- [Hooked C](c.md) hand text\n"
                + self.entry("e.md")
                + self.entry("a.md"),
            )
            self.assertEqual(plan["archive_text"], "")
            self.assertEqual((plan["dangling"], plan["hookless"], plan["dead"], plan["unsplit"]), ([], [], [], 0))

    def test_rehook_leaves_a_hooked_index_under_budget_alone_unless_forced(self):
        with tempfile.TemporaryDirectory() as temp:
            index = "# idx\n- [A](a.md): hooked a\n"
            notes = {"a.md": ("project", "2026-09-01T00:00:00Z"), "b.md": ("project", "2026-09-02T00:00:00Z")}
            _fixture, live, _ = self.make_project(temp, index, notes)
            self.assertFalse(self.plan(live)["changed"])  # an unindexed note alone is fix's job
            forced = self.plan(live, forced=True)
            self.assertTrue(forced["changed"])
            # Every entry ranks, so the newer unindexed note lands above the older hooked one.
            self.assertEqual(forced["main_text"], "# idx\n" + self.entry("b.md") + "- [A](a.md): hooked a\n")

    def budget_fixture(self, temp, archive_text=None):
        index = "# idx\n- [-](a.md);[-](b.md);[-](c.md);[-](d.md)\n"
        notes = {
            "a.md": ("project", "2026-09-04T00:00:00Z"),
            "b.md": ("project", "2026-09-03T00:00:00Z"),
            "c.md": ("project", "2026-09-02T00:00:00Z"),
            "d.md": ("project", "2026-09-01T00:00:00Z"),
        }
        fixture, live, mirror = self.make_project(temp, index, notes)
        if archive_text is not None:
            (live / "memory-archive-index.md").write_text(archive_text)
        return fixture, live, mirror

    def test_rehook_cuts_at_the_byte_budget_and_moves_the_rest_hooked(self):
        saved = MA.REHOOK_MAIN_MAX_BYTES
        try:
            with tempfile.TemporaryDirectory() as temp:
                _fixture, live, _ = self.budget_fixture(temp)
                records = MA.scan_project_notes(live)
                pointer = MA.archive_pointer_line("Archive tier", records, {"c.md", "d.md"})
                two_kept = "# idx\n" + pointer + self.entry("a.md") + self.entry("b.md")
                MA.REHOOK_MAIN_MAX_BYTES = len(two_kept.encode("utf-8")) + 1  # two fit, a third does not
                plan = self.plan(live)
                self.assertEqual(plan["kept"], ["a.md", "b.md"])
                self.assertEqual(plan["moved"], ["c.md", "d.md"])  # rank order, newest first
                self.assertEqual(plan["main_text"], two_kept)
                self.assertIn("2 hooked pointers below this index's load cut (2 project, modified 2026-09-01 to 2026-09-02)", plan["pointer_line"])
                # The budget is strict: an index exactly at the byte budget does not fit.
                MA.REHOOK_MAIN_MAX_BYTES = len(two_kept.encode("utf-8"))
                self.assertEqual(self.plan(live)["kept"], ["a.md"])
                MA.REHOOK_MAIN_MAX_BYTES = len(two_kept.encode("utf-8")) + 1
                plan = self.plan(live)
                self.assertTrue(plan["archive_created"])
                self.assertTrue(plan["archive_text"].startswith("---\nname: memory-archive-index\n"))
                self.assertTrue(
                    plan["archive_text"].endswith(
                        "\n## Moved out on 2026-09-28 (rehook: ranked tier split under the load cap)\n"
                        + self.entry("c.md") + self.entry("d.md")
                    )
                )
                self.assertEqual(plan["summary"]["after"]["bytes"], len(two_kept.encode("utf-8")))
        finally:
            MA.REHOOK_MAIN_MAX_BYTES = saved

    def test_rehook_cuts_at_the_line_budget(self):
        saved = MA.REHOOK_MAIN_MAX_LINES
        try:
            with tempfile.TemporaryDirectory() as temp:
                _fixture, live, _ = self.budget_fixture(temp)
                MA.REHOOK_MAIN_MAX_LINES = 4  # heading + pointer + one entry = 3 lines fit; four do not
                plan = self.plan(live)
                self.assertEqual(plan["kept"], ["a.md"])
                self.assertEqual(plan["moved"], ["b.md", "c.md", "d.md"])
                self.assertEqual(plan["summary"]["after"]["lines"], 3)
        finally:
            MA.REHOOK_MAIN_MAX_LINES = saved

    def test_rehook_dedups_against_the_existing_archive_and_is_idempotent(self):
        saved = MA.REHOOK_MAIN_MAX_BYTES
        try:
            with tempfile.TemporaryDirectory() as temp:
                archive = (
                    "---\nname: memory-archive-index\ndescription: archive tier fixture\nmetadata:\n  type: reference\n---\n"
                    "# archive\n- [c](c.md): already here\n"
                )
                _fixture, live, _ = self.budget_fixture(temp, archive_text=archive)
                records = MA.scan_project_notes(live)
                pointer = MA.archive_pointer_line("Archive tier", records, {"c.md", "d.md"})
                two_kept = "# idx\n" + pointer + self.entry("a.md") + self.entry("b.md")
                MA.REHOOK_MAIN_MAX_BYTES = len(two_kept.encode("utf-8")) + 1
                plan = self.plan(live)
                self.assertEqual(plan["moved"], ["c.md", "d.md"])
                self.assertEqual(plan["archive_appended"], ["d.md"])
                self.assertEqual(plan["archive_deduped"], ["c.md"])
                self.assertFalse(plan["archive_created"])
                self.assertEqual(plan["archive_text"].count("(c.md)"), 1)
                self.assertEqual(
                    plan["archive_text"],
                    archive + "\n## Moved out on 2026-09-28 (rehook: ranked tier split under the load cap)\n" + self.entry("d.md"),
                )
                # The index had no pointer line: one is inserted after the heading.
                self.assertTrue(plan["main_text"].startswith("# idx\n- [Archive tier](memory-archive-index.md): 2 hooked pointers"))
                # Apply the plan by hand, then a second plan proposes nothing.
                (live / "MEMORY.md").write_text(plan["main_text"])
                (live / "memory-archive-index.md").write_text(plan["archive_text"])
                again = self.plan(live)
                self.assertFalse(again["changed"])
                self.assertEqual(again["summary"]["bare_fragments"], 0)
                self.assertEqual(again["summary"]["unindexed"], 0)
        finally:
            MA.REHOOK_MAIN_MAX_BYTES = saved

    def test_rehook_apply_is_mirror_gated_preserves_mtime_and_prints_zero_changes_after(self):
        with tempfile.TemporaryDirectory() as temp:
            index = "# idx\n- [-](a.md);[-](b.md)\n"
            notes = {"a.md": ("feedback", "2026-09-04T00:00:00Z"), "b.md": ("project", "2026-09-03T00:00:00Z")}
            fixture, live, mirror = self.make_project(temp, index, notes)
            old = time.mktime((2026, 8, 1, 0, 0, 0, 0, 0, -1))
            os.utime(live / "MEMORY.md", (old, old))
            # Stale mirror (empty): apply refuses and writes nothing.
            refused = self.cli(fixture, "rehook", "--apply", "--project=project", "--now", "2026-09-28")
            self.assertEqual(refused.returncode, 1)
            self.assertIn("refusing to apply to project: mirror not fresh", refused.stderr)
            self.assertEqual((live / "MEMORY.md").read_text(), index)
            # Fresh mirror: apply writes the hooked index and keeps its mtime.
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            applied = self.cli(fixture, "rehook", "--apply", "--project=project", "--now", "2026-09-28", "--format", "json")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            payload = json.loads(applied.stdout)
            self.assertTrue(payload["applied"])
            self.assertEqual(payload["summary"]["projects"]["project"]["bare_fragments"], 2)
            self.assertEqual((live / "MEMORY.md").read_text(), "# idx\n" + self.entry("a.md") + self.entry("b.md"))
            self.assertEqual(int((live / "MEMORY.md").stat().st_mtime), int(old))
            self.assertFalse((live / "memory-archive-index.md").exists())  # nothing moved, no tier created
            # A second preview on the applied index reports zero changes.
            again = self.cli(fixture, "rehook", "--project=project", "--now", "2026-09-28")
            self.assertEqual(again.returncode, 0)
            self.assertIn("0 of 1 live index(es) need work", again.stdout)
            self.assertTrue(again.stdout.rstrip().endswith("changes:0"))

    def test_rehook_apply_with_no_mirror_named_checks_the_pushed_backup_ref(self):
        """PLANTED NEGATIVE (#1918): with no --mirror-root, an absent ref, a ref whose
        MEMORY.md differs or lacks a note, and a matching copy committed but never
        pushed all refuse and leave live byte-identical; a matching ref applies."""
        with tempfile.TemporaryDirectory() as temp:
            index = "# idx\n- [-](a.md);[-](b.md)\n"
            notes = {"a.md": ("feedback", "2026-09-04T00:00:00Z"), "b.md": ("project", "2026-09-03T00:00:00Z")}
            fixture, live, _mirror = self.make_project(temp, index, notes, mirror=False)
            repo = BackupRepo(Path(temp))
            command = [
                "python3", str(AUDITOR), "rehook", "--live-root", str(fixture.live),
                "--apply", "--project=project", "--now", "2026-09-28", "--format", "json",
            ]
            before = snapshot(live)

            def refused_with(kinds):
                result = subprocess.run(command, text=True, capture_output=True, check=False, env=repo.env())
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(
                    f"memory-rehook: refusing to apply to project: mirror not fresh ({kinds}); "
                    "checked against refs/remotes/origin/backup/claude-memory",
                    result.stderr,
                )
                self.assertEqual(snapshot(live), before)

            refused_with("mirror_missing_project")  # the ref does not exist yet
            older = {"MEMORY.md": b"# idx\n", "a.md": before["a.md"]}
            repo.commit("project", older, push=True)
            refused_with("mirror_missing_file, mirror_stale_file")
            repo.commit("project", before, push=False)
            refused_with("mirror_missing_file, mirror_stale_file")  # same bytes, never pushed
            repo.git("update-ref", MA.PUSHED_MIRROR_REF, "HEAD")
            applied = subprocess.run(command, text=True, capture_output=True, check=False, env=repo.env())
            self.assertEqual(applied.returncode, 0, applied.stderr)
            payload = json.loads(applied.stdout)
            self.assertTrue(payload["applied"])
            self.assertEqual(payload["roots"]["mirror"], MA.PUSHED_MIRROR_REF)
            self.assertEqual((live / "MEMORY.md").read_text(), "# idx\n" + self.entry("a.md") + self.entry("b.md"))

    def test_parse_keeps_semicolon_hooks_comment_bullets_and_bare_junk_lines_verbatim(self):
        index = (
            "---\nname: idx\n---\n"
            "# idx\n"
            "<!--\n- [c](c.md): commented out\n-->\n"
            "- [X](x.md): foo; [see](y.md) bar\n"
            "- [-](a.md);[-](b.md)\n"
            "- [-](q.md);plain text [Y](y.md)\n"
        )
        parsed = MA.parse_index_entries(index)
        self.assertEqual(parsed["frontmatter"], "---\nname: idx\n---\n")
        self.assertEqual(parsed["preamble"], ["# idx\n", "<!--\n", "- [c](c.md): commented out\n", "-->\n"])
        # A hooked line whose hook carries `; [link]` is one entry, byte-identical.
        self.assertEqual(parsed["entries"], {"x.md": "- [X](x.md): foo; [see](y.md) bar\n"})
        self.assertEqual(parsed["fragments"], ["a.md", "b.md"])
        # A bare fragment with trailing junk is neither hooked nor split: kept verbatim, reported.
        self.assertEqual(parsed["unsplit"], ["- [-](q.md);plain text [Y](y.md)\n"])
        self.assertEqual(parsed["other"], ["- [-](q.md);plain text [Y](y.md)\n"])
        with tempfile.TemporaryDirectory() as temp:
            notes = {rel: ("project", f"2026-09-0{i + 1}T00:00:00Z") for i, rel in enumerate(("a.md", "b.md", "c.md", "q.md", "x.md", "y.md"))}
            _fixture, live, _ = self.make_project(temp, index, notes)
            plan = self.plan(live)
            self.assertEqual(plan["bare_remaining"], 1)  # q.md stays bare on its unsplit line
            self.assertEqual(plan["summary"]["bare_fragments"], 3)  # counted like triage does
            self.assertTrue(plan["main_text"].startswith("---\nname: idx\n---\n# idx\n<!--\n- [c](c.md): commented out\n-->\n"))
            self.assertNotIn("c.md", plan["kept"])  # a commented-out bullet is not an entry
            self.assertIn("- [X](x.md): foo; [see](y.md) bar\n", plan["main_text"])
            self.assertIn("- [-](q.md);plain text [Y](y.md)\n", plan["main_text"])

    def test_rehook_replaces_an_existing_pointer_in_place_with_the_union_count(self):
        saved = MA.REHOOK_MAIN_MAX_BYTES
        try:
            with tempfile.TemporaryDirectory() as temp:
                index = "# idx\n- [Custom](memory-archive-index.md): old hook\n- [-](a.md);[-](b.md);[-](c.md);[-](d.md)\n"
                archive = "---\nname: memory-archive-index\ndescription: archive tier fixture\nmetadata:\n  type: reference\n---\n# archive\n- [x](x.md): archived long ago\n"
                notes = {
                    "a.md": ("project", "2026-09-04T00:00:00Z"),
                    "b.md": ("project", "2026-09-03T00:00:00Z"),
                    "c.md": ("project", "2026-09-02T00:00:00Z"),
                    "d.md": ("project", "2026-09-01T00:00:00Z"),
                    "x.md": ("feedback", "2026-08-01T00:00:00Z"),
                }
                _fixture, live, _ = self.make_project(temp, index, notes)
                (live / "memory-archive-index.md").write_text(archive)
                records = MA.scan_project_notes(live)
                pointer = MA.archive_pointer_line("Custom", records, {"x.md", "c.md", "d.md"})
                two_kept = "# idx\n" + pointer + self.entry("a.md") + self.entry("b.md")
                MA.REHOOK_MAIN_MAX_BYTES = len(two_kept.encode("utf-8")) + 1
                plan = self.plan(live)
                self.assertEqual(plan["main_text"], two_kept)
                self.assertEqual(plan["main_text"].count("memory-archive-index.md"), 1)  # replaced, not duplicated
                self.assertTrue(plan["pointer_line"].startswith("- [Custom](memory-archive-index.md): 3 hooked pointers"))
                self.assertIn("(1 feedback, 2 project, modified 2026-08-01 to 2026-09-02)", plan["pointer_line"])
        finally:
            MA.REHOOK_MAIN_MAX_BYTES = saved

    def test_rehook_moves_hooked_lines_byte_identical_and_reports_dangling_and_dead(self):
        saved = MA.REHOOK_MAIN_MAX_LINES
        try:
            with tempfile.TemporaryDirectory() as temp:
                index = "# idx\n- [-](a.md);[-](b.md);[-](gone.md)\n- [Z](z.md) :: odd  \n- [Dead](nothere.md): dead\n"
                notes = {
                    "a.md": ("project", "2026-09-04T00:00:00Z"),
                    "b.md": ("project", "2026-09-03T00:00:00Z"),
                    "z.md": ("project", "2026-09-01T00:00:00Z"),
                }
                _fixture, live, _ = self.make_project(temp, index, notes)
                MA.REHOOK_MAIN_MAX_LINES = 5  # heading + pointer + two entries fit; a third entry does not
                plan = self.plan(live)
                self.assertEqual(plan["kept"], ["a.md", "b.md"])
                self.assertEqual(plan["moved"], ["z.md", "nothere.md"])  # a dead hooked line ranks last, never dropped
                self.assertEqual(plan["dangling"], ["gone.md"])  # a bare fragment to no note: reported, not rendered
                self.assertEqual(plan["dead"], ["nothere.md"])
                self.assertTrue(plan["archive_text"].endswith("- [Z](z.md) :: odd  \n- [Dead](nothere.md): dead\n"))
                self.assertIn("1 hooked pointer below", plan["pointer_line"])  # only notes that exist are counted
        finally:
            MA.REHOOK_MAIN_MAX_LINES = saved

    def test_rehook_skips_unsafe_files_and_keeps_crlf_hooked_lines(self):
        with tempfile.TemporaryDirectory() as temp:
            notes = {"a.md": ("project", "2026-09-03T00:00:00Z"), "b.md": ("project", "2026-09-02T00:00:00Z"), "c.md": ("project", "2026-09-01T00:00:00Z")}
            fixture, live, _ = self.make_project(temp, "- [-](a.md)\n", notes)
            # A symlinked archive tier is never treated as absent (it would be clobbered).
            (live / "real-archive.md").write_text(note("real-archive", "reference"))
            os.symlink("real-archive.md", live / "memory-archive-index.md")
            plan = self.plan(live)
            self.assertIn("symlink", plan["skipped"])
            self.assertFalse(plan["changed"])
            applied = self.cli(fixture, "rehook", "--apply", "--project=project", "--format", "json")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            payload = json.loads(applied.stdout)
            self.assertFalse(payload["applied"])
            self.assertIn("symlink", payload["summary"]["skipped"]["project"])
            self.assertEqual((live / "MEMORY.md").read_text(), "- [-](a.md)\n")
            os.unlink(live / "memory-archive-index.md")
            os.unlink(live / "real-archive.md")
            # Bytes that are not UTF-8 are left alone rather than rewritten as U+FFFD.
            (live / "MEMORY.md").write_bytes(b"- [-](a.md)\n- [L](c.md): caf\xe9\n")
            self.assertIn("not valid UTF-8", self.plan(live)["skipped"])
            # An unreadable index skips the project instead of aborting the run.
            if os.geteuid() != 0:
                (live / "MEMORY.md").write_text("- [-](a.md)\n")
                os.chmod(live / "MEMORY.md", 0)
                try:
                    self.assertTrue(self.plan(live)["skipped"].startswith("unreadable MEMORY.md"))
                finally:
                    os.chmod(live / "MEMORY.md", 0o644)
            # CRLF line endings survive on a hooked line; rendered lines use LF.
            (live / "MEMORY.md").write_bytes(b"- [-](a.md);[-](b.md)\r\n- [C](c.md): hooked\r\n")
            plan = self.plan(live)
            self.assertEqual(plan["main_text"], self.entry("a.md") + self.entry("b.md") + "- [C](c.md): hooked\r\n")

    def test_rehook_apply_with_a_move_writes_the_archive_hooks_its_fragments_and_needs_a_scope(self):
        with tempfile.TemporaryDirectory() as temp:
            count = 160  # more one-line entries than the 140-line budget holds
            rels = [f"n{i:03d}.md" for i in range(count)]
            notes = {rel: ("project", f"2026-09-{28 - i // 24:02d}T{23 - i % 24:02d}:00:00Z") for i, rel in enumerate(rels)}
            notes["old1.md"] = ("project", "2026-07-01T00:00:00Z")
            notes["old2.md"] = ("project", "2026-07-02T00:00:00Z")
            packed = "".join("- " + ";".join(f"[-]({rel})" for rel in rels[i:i + 10]) + "\n" for i in range(0, count, 10))
            fixture, live, mirror = self.make_project(temp, "# idx\n" + packed, notes)
            archive = (
                "---\nname: memory-archive-index\ndescription: archive tier fixture\nmetadata:\n  type: reference\n---\n"
                "# archive\n- [-](old1.md);[-](old2.md)\n"
            )
            (live / "memory-archive-index.md").write_text(archive)
            old = time.mktime((2026, 8, 1, 0, 0, 0, 0, 0, -1))
            os.utime(live / "memory-archive-index.md", (old, old))
            os.utime(live / "MEMORY.md", (old, old))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            # A write needs an explicit scope: every qualifying project would be rewritten.
            unscoped = self.cli(fixture, "rehook", "--apply", "--now", "2026-09-28")
            self.assertEqual(unscoped.returncode, 2)
            self.assertIn("--apply needs --project NAME or --all", unscoped.stderr)
            self.assertEqual((live / "MEMORY.md").read_text(), "# idx\n" + packed)
            applied = self.cli(fixture, "rehook", "--apply", "--all", "--now", "2026-09-28", "--format", "json")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            payload = json.loads(applied.stdout)
            self.assertTrue(payload["applied"])
            item = payload["summary"]["projects"]["project"]
            self.assertEqual((item["bare_fragments"], item["archive_bare_fragments"], item["archive_hooked"]), (count, 2, 2))
            main = (live / "MEMORY.md").read_text()
            lines, size = MA.effective_index_size(main)
            self.assertTrue(lines < MA.REHOOK_MAIN_MAX_LINES and size < MA.REHOOK_MAIN_MAX_BYTES)
            self.assertNotIn("[-](", main)
            self.assertEqual(item["kept"] + item["moved"], count)
            self.assertTrue(main.startswith("# idx\n- [Archive tier](memory-archive-index.md): " + str(item["moved"] + 2) + " hooked pointers"))
            archived = (live / "memory-archive-index.md").read_text()
            self.assertTrue(archived.startswith(archive.replace("- [-](old1.md);[-](old2.md)\n", self.entry("old1.md") + self.entry("old2.md"))))
            self.assertIn("\n## Moved out on 2026-09-28 (rehook: ranked tier split under the load cap)\n", archived)
            self.assertEqual(archived.count("[-]("), 0)
            self.assertEqual(sum(1 for rel in rels if f"({rel})" in archived), item["moved"])
            self.assertEqual(int((live / "memory-archive-index.md").stat().st_mtime), int(old))
            self.assertEqual(int((live / "MEMORY.md").stat().st_mtime), int(old))
            again = self.cli(fixture, "rehook", "--project=project", "--now", "2026-09-28")
            self.assertTrue(again.stdout.rstrip().endswith("changes:0"), again.stdout)

    def test_miner_droppings_never_count_as_missing_mirror_files(self):
        # sync.sh never mirrors the miner's runtime state; the auditor's copy of that
        # list must match sync.sh's, and neither the coverage audit nor the apply gate
        # may treat a dropping as a missing mirror file (#1450: with them counted,
        # `fix --apply` and `rehook --apply` could never pass on this project).
        sync_text = SYNC.read_text(encoding="utf-8")
        block = sync_text.split("MEMORY_MINER_DROPPINGS=(", 1)[1].split(")", 1)[0]
        self.assertEqual(tuple(re.findall(r"'([^']+)'", block)), MA.MINER_DROPPINGS)
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, mirror = fixture.project()
            (live / "MEMORY.md").write_text("- [-](a.md)\n")
            (live / "a.md").write_text(note("a"))
            for path in live.iterdir():
                (mirror / path.name).write_bytes(path.read_bytes())
            (live / ".mine-apply.lock").write_text("pid 1\n")
            (live / ".mined-sessions.json").write_text("{}\n")
            (live / ".MEMORY.md.pre-mine-20260901000000").write_text("- old\n")
            self.assertEqual(MA.mirror_freshness(fixture.live, fixture.mirror, ["project"]), {})
            audit = subprocess.run(
                ["python3", str(AUDITOR), "--live-root", str(fixture.live), "--mirror-root", str(fixture.mirror), "--format", "json"],
                text=True, capture_output=True, check=False,
            )
            kinds = {item["kind"] for item in json.loads(audit.stdout)["findings"]}
            self.assertNotIn("mirror_missing_file", kinds)
            applied = self.cli(fixture, "rehook", "--apply", "--project=project", "--now", "2026-09-28", "--format", "json")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertTrue(json.loads(applied.stdout)["applied"])
            # What the push quarantines (a sensitive filename that is not allowlisted, a
            # content signature, a sensitive frontmatter key) is never mirrored either.
            (live / "MEMORY.md").write_bytes((mirror / "MEMORY.md").read_bytes())  # back in sync
            (live / "credential-cache-notes.md").write_text(note("credential-cache-notes"))
            (live / "keyed.md").write_text(note("keyed", extra="  api_key: placeholder\n"))
            self.assertEqual(MA.mirror_freshness(fixture.live, fixture.mirror, ["project"], filename_allowlist=set()), {})
            self.assertEqual(
                MA.push_excluded_paths("project", live, set()) - {".mine-apply.lock", ".mined-sessions.json", ".MEMORY.md.pre-mine-20260901000000"},
                {"credential-cache-notes.md", "keyed.md"},
            )
            # Allowlisting the name makes the push copy it, so the gate demands it again.
            allowlisted = {"project/credential-cache-notes.md"}
            self.assertEqual(MA.mirror_freshness(fixture.live, fixture.mirror, ["project"], filename_allowlist=allowlisted), {"project": ["mirror_missing_file"]})
            # A genuinely unmirrored note still blocks the gate.
            (live / "b.md").write_text(note("b"))
            self.assertIn("mirror_missing_file", MA.mirror_freshness(fixture.live, fixture.mirror, ["project"], filename_allowlist=set())["project"])

    def test_triage_warns_on_bare_index_fragments(self):
        with tempfile.TemporaryDirectory() as temp:
            index = "- [A](a.md): hooked\n- [-](b.md);[-](c.md)\n"
            notes = {"a.md": ("project", None), "b.md": ("project", None), "c.md": ("project", None)}
            fixture, _live, _ = self.make_project(temp, index, notes, mirror=False)
            payload = json.loads(self.cli(fixture, "triage", "--format", "json").stdout)
            self.assertEqual(payload["summary"]["index_bare_fragments"], {"project": 2})
            human = self.cli(fixture, "triage")
            self.assertIn("WARN project: MEMORY.md carries 2 bare [-](slug) fragment(s) that cannot route recall", human.stdout)


class CitedEnforcerTests(unittest.TestCase):
    """cited_enforcer_missing (dotfiles#1687): a feedback note of the repo's own
    project that cites a script or repo path which does not exist in the repo."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.repo = root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "scripts" / "real-guard.sh").write_text("#!/bin/sh\n")
        (self.repo / "hooks" / "PreToolUse").mkdir(parents=True)
        (self.repo / "hooks" / "PreToolUse" / "git-guard.js").write_text("// hook\n")
        # The flat root has generic directory names; bin/ exists so a foreign bin/x.sh
        # has to be classified rather than dropped for its first segment.
        (self.repo / "bin").mkdir()
        # The memory mirror is not an enforcer index: a script that exists only
        # under memory must not rescue a citation.
        (self.repo / "memory" / "p").mkdir(parents=True)
        (self.repo / "memory" / "p" / "mirror-only.py").write_text("")
        self.fixture = Fixture(root)
        self.key = MA.project_key(self.repo)
        self.live, self.mirror = self.fixture.project(self.key)
        # Empty by default so the host's ~/SITES and ~/.claude/plugins never leak in.
        self.sites = root / "sites"
        self.sites.mkdir()
        self.plugins = root / "plugins"
        self.plugins.mkdir()

    def write(self, name, body, note_type="feedback", live=None, mirror=None, description=None):
        live = live or self.live
        mirror = mirror or self.mirror
        text = note(name, note_type=note_type, body=body)
        if description is not None:
            text = text.replace(f"description: Fixture note describing {name} in detail", f'description: "{description}"')
        (live / f"{name}.md").write_text(text)
        index = live / "MEMORY.md"
        existing = index.read_text() if index.exists() else ""
        index.write_text(existing + f"- [{name}]({name}.md)\n")
        for path in live.iterdir():
            (mirror / path.name).write_bytes(path.read_bytes())

    def audit(self, *args, sites=None, plugins=None, enforcer_repo=None):
        # Both root flags append, so a test that wants a different root names it
        # here instead of stacking a second flag on the default.
        command = [
            "python3",
            str(AUDITOR),
            "--live-root",
            str(self.fixture.live),
            "--mirror-root",
            str(self.fixture.mirror),
            "--format",
            "json",
            "--enforcer-repo",
            str(enforcer_repo or self.repo),
            "--repo-root",
            str(sites or self.sites),
            "--enforcer-extra-root",
            str(plugins or self.plugins),
            *args,
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        payload = json.loads(result.stdout)
        flagged = [item for item in payload["findings"] if item["kind"] == "cited_enforcer_missing"]
        return result, payload, flagged

    def test_project_key_matches_claude_code_encoding(self):
        self.assertEqual(MA.project_key(Path("/home/user/dotfiles")), "-home-user-dotfiles")
        # Observed on the author's host 2026-10-08: ~/SITES/coding_agent_session_search
        # was the live project -home-<user>-SITES-coding-agent-session-search, and no
        # live key contained an underscore. An under-encoded key matches no live project, which
        # drops a sibling repo from the derived repo names silently. Other
        # punctuation is not asserted: the only live keys keeping a `+` or `.` date
        # from April 2026 and hold no memory.
        self.assertEqual(
            MA.project_key(Path("/home/user/SITES/coding_agent_session_search")),
            "-home-user-SITES-coding-agent-session-search",
        )
        self.assertEqual(
            MA.project_key(Path("/home/user/dotfiles/.claude/worktrees/x")),
            "-home-user-dotfiles--claude-worktrees-x",
        )

    def test_missing_basename_citation_flags_without_blocking(self):
        self.write("n", "Project the return with `cr-compact.py`, then run `scripts/real-guard.sh:12-20`.")
        result, payload, flagged = self.audit()
        self.assertEqual(result.returncode, 0, "cited_enforcer_missing must not make the audit exit non-zero")
        self.assertEqual(flagged, [{"kind": "cited_enforcer_missing", "project": self.key, "path": "n.md", "token": "cr-compact.py"}])
        self.assertEqual(payload["summary"]["cited_enforcer_missing"], 1)
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_checked"], 1)
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["project"], self.key)
        self.assertEqual(payload["summary"]["blocking_findings"], 0)

    def test_existing_citations_do_not_flag(self):
        self.write(
            "n",
            "Exact `scripts/real-guard.sh:12-20`, basename `real-guard.sh`, moved hook "
            "`hooks/git-guard.js:517-537`, installed copy `~/.claude/scripts/real-guard.sh --flag`, "
            "pytest id `real-guard.sh::case`, directory `hooks/`, trailing `real-guard.sh:105-138,` "
            "and a plain word `jq` or `rg -F`. Runtime state `~/.claude/logs/run.py` and another repo's "
            "layout `ops/arc/bin/egress-smoke.py` (no ops/ here) is not a citation.",
        )
        _result, payload, flagged = self.audit()
        self.assertEqual(flagged, [])
        self.assertEqual(payload["summary"]["cited_enforcer_missing"], 0)
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_checked"], 1)
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_other_repo"], 0)

    def test_missing_claude_path_and_mirror_only_script_flag(self):
        self.write(
            "n",
            "See `scripts/gone.sh`, `hooks/PreToolUse/nope.js:3` and `~/.claude/scripts/gone-installed.sh`; "
            "`mirror-only.py` is not a repo script.",
        )
        _result, _payload, flagged = self.audit()
        self.assertEqual(
            sorted(item["token"] for item in flagged),
            ["hooks/PreToolUse/nope.js", "mirror-only.py", "scripts/gone.sh", "~/.claude/scripts/gone-installed.sh"],
        )

    def test_foreign_path_under_a_root_directory_name_flags_unless_its_sentence_names_the_repo(self):
        # Since the 2026-10 flatten the root holds generic directory names (bin,
        # scripts, lib), so another repository's `bin/x.sh` has the shape of a
        # citation of ours. It is reported, never blocking, unless the sentence names
        # the repository, which the other-repo skip honours.
        self.write(
            "n",
            "Deploy with `bin/deploy_fleet_health_http.sh` after the check.\n\n"
            "Shipped in acme-app#1621 as `bin/deploy_fleet_health_http.sh` over there.",
        )
        result, payload, flagged = self.audit()
        self.assertEqual(result.returncode, 0)
        self.assertEqual([item["token"] for item in flagged], ["bin/deploy_fleet_health_http.sh"])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_other_repo"], 1)
        self.assertEqual(payload["summary"]["blocking_findings"], 0)

    def test_legacy_nested_prefix_maps_to_the_root(self):
        # A note written under the pre-2026-10 layout cites `<old prefix><dir>/...`;
        # with no such directory in the repo the prefix maps to the root, so an
        # existing file passes and a missing one is reported under the token as
        # written. The prefix is split so the layout suite's scan ignores this file.
        legacy = "cl" "aude/"
        self.assertEqual(legacy, MA.ENFORCER_LEGACY_PREFIX)
        self.write(
            "n",
            f"Run `{legacy}scripts/real-guard.sh`, then `{legacy}scripts/gone.sh`; `{legacy}hooks/` holds the hooks.",
        )
        _result, _payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], [f"{legacy}scripts/gone.sh"])

    def test_installed_plugin_scripts_count_as_existing(self):
        (self.plugins / "cache" / "ce" / "scripts").mkdir(parents=True)
        (self.plugins / "cache" / "ce" / "scripts" / "run-log.py").write_text("")
        self.write("n", "The leaf ran `run-log.py summarize` and skipped `report.md`.")
        _result, _payload, flagged = self.audit()
        self.assertEqual(flagged, [])
        empty = self.plugins.parent / "no-plugins"
        empty.mkdir()
        _result, _payload, flagged = self.audit(plugins=empty)
        self.assertEqual([item["token"] for item in flagged], ["run-log.py"])

    def test_derived_repo_names_apply_next_to_issue_refs_and_in_descriptions(self):
        acme_app = self.sites / "acme-app"
        acme_app.mkdir()
        self.fixture.project(MA.project_key(acme_app))
        self.write(
            "n",
            "Shipped in acme-app #1621 (`check-migration-code-coupling.mjs`), guarding the ordering bug.\n\n"
            "acme-app's `coupling.mjs` guards the same ordering.",
        )
        self.write("about", "Run `gate.mjs` before merging.", description="Shipped in acme-app #12 as a required gate")
        _result, payload, flagged = self.audit()
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["repo_names"], ["acme-app"])
        self.assertEqual([item["token"] for item in flagged], ["coupling.mjs"], "a derived name skips only next to an issue ref")
        self.assertEqual(scope["notes_checked"], 1)
        self.assertEqual(scope["notes_other_repo"], 2)
        empty = self.sites.parent / "no-sites"
        empty.mkdir()
        _result, payload, flagged = self.audit(sites=empty)
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["repo_names"], [])
        self.assertEqual(
            sorted(item["token"] for item in flagged),
            ["check-migration-code-coupling.mjs", "coupling.mjs", "gate.mjs"],
        )

    def test_other_repo_paragraphs_are_skipped(self):
        body = (
            "Shipped in acme-app#1621 (`check-migration-code-coupling.mjs`), which guards the ordering bug.\n\n"
            "The gate lives at `~/SITES/acme-app/scripts/gate.mjs`; run `gate.mjs` before merging.\n\n"
            "Plugin copy: `~/.claude/plugins/cache/every/ce/3.30.4/scripts/run-log.py` is `run-log.py`.\n\n"
            "acme-other's `coupling.mjs` guards the same ordering."
        )
        self.write("n", body)
        _result, _payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["coupling.mjs"], "only the paragraph with no repo signal is checked")
        _result, _payload, flagged = self.audit("--other-repo", "acme-other")
        self.assertEqual(flagged, [])

    def test_sites_path_of_own_repo_keeps_citations_in_scope(self):
        # Path text may come from a different host than the audited checkout.
        # Parse both separator styles without consulting that host's filesystem.
        paths = (
            "~/SITES/repo", "/home/user/SITES/repo/", "/SITES/repo/scripts",
            r"C:\Users\user\SITES\repo", r"C:\SITES\repo\claude\scripts",
            "C:/SITES/repo", "~/SITES/REPO", "~/SITES/repo.",
        )
        for number, path in enumerate(paths):
            with self.subTest(path=path):
                self.write(f"own-{number}", f"In {path}, run `missing-{number}.sh` and `real-guard.sh`.")
        result, payload, flagged = self.audit()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(sorted(item["token"] for item in flagged), [f"missing-{n}.sh" for n in range(len(paths))])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["notes_checked"], len(paths))
        self.assertEqual(scope["notes_other_repo"], 0)

    def test_sites_path_compares_the_whole_other_repo_component(self):
        paths = (
            "~/SITES/acme-app", "/home/user/SITES/acme-app/scripts", r"C:\SITES\acme-app",
            "C:/SITES/acme-app/", "~/SITES/repo-tools", "~/SITES/repository",
            "~/SITES/repo_extra", "~/SITES/repo.extra", "~/SITES/repo+extra",
            "~/SITES/repo.git", "~/SITES/acme-app.",
        )
        for number, path in enumerate(paths):
            self.write(f"other-{number}", f"In {path}, run `missing-{number}.sh`.")
        _result, payload, flagged = self.audit()
        self.assertEqual(flagged, [])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["notes_checked"], len(paths))
        self.assertEqual(scope["notes_other_repo"], len(paths))

    def test_sites_path_needs_a_repo_component_and_directory_boundary(self):
        # A collection root or a similarly named directory identifies no other
        # repository. Punctuation and Markdown delimiters end the component.
        paths = ("~/SITES/", "~/WEBSITES/acme-app", "~/SITES-backup/acme-app", "(~/SITES/repo)", "`~/SITES/repo`")
        for number, path in enumerate(paths):
            self.write(f"boundary-{number}", f"In {path}, run `missing-{number}.sh`.")
        _result, payload, flagged = self.audit()
        self.assertEqual(sorted(item["token"] for item in flagged), [f"missing-{n}.sh" for n in range(len(paths))])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_other_repo"], 0)

    def test_sites_scope_preserves_sentence_and_list_boundaries(self):
        self.write(
            "n",
            "In ~/SITES/acme-app, e.g. run `foreign.sh`. In ~/SITES/repo, run `own.sh`.\n"
            "- In C:\\SITES\\acme-app run `foreign-list.sh`\n"
            "- In C:\\SITES\\repo run `own-list.sh`\n"
            "- In ~/SITES/repo and ~/SITES/acme-app run `mixed.sh`\n"
            "- In ~/SITES/repo use `~/.claude/plugins/cache/example/guard.py` and `plugin.sh`",
        )
        _result, payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["own-list.sh", "own.sh"])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_other_repo"], 1)

    def test_sites_paths_accept_requested_worktree_and_main_checkout_names(self):
        worktree = self.repo.parent / "review-worktree"
        worktree.mkdir()
        (self.repo / ".git" / "worktrees" / worktree.name).mkdir(parents=True)
        (worktree / ".git").write_text(f"gitdir: {self.repo}/.git/worktrees/{worktree.name}\n")
        self.write(
            "n",
            "In ~/SITES/repo run `main-missing.sh`. In ~/SITES/review-worktree run `worktree-missing.sh`. "
            "In ~/SITES/review-worktree-other run `foreign.sh`.",
        )
        _result, payload, flagged = self.audit(enforcer_repo=worktree)
        self.assertEqual([item["token"] for item in flagged], ["main-missing.sh", "worktree-missing.sh"])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["repo"], str(self.repo))
        self.assertEqual(scope["repo_requested"], str(worktree))
        self.assertEqual(scope["notes_checked"], 1)
        self.assertEqual(scope["notes_other_repo"], 1)

    def test_non_feedback_notes_and_placeholders_are_skipped(self):
        self.write("project-note", "Run `gone.py` here.", note_type="project")
        self.write(
            "n",
            "Shapes: `plugins/hov-stack/skills/<name>/`, `taint_*.py`, `${HOME}/x.sh`, `$SCRIPTS/y.sh`, "
            "`https://example.com/x.py`, `{hooks,scripts}`.",
        )
        _result, payload, flagged = self.audit()
        self.assertEqual(flagged, [])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_checked"], 1)

    def test_other_projects_are_not_checked(self):
        other_live, other_mirror = self.fixture.project("other-project")
        self.write("n", "Run `gone.py` here.", live=other_live, mirror=other_mirror)
        _result, payload, flagged = self.audit()
        self.assertEqual(flagged, [])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_checked"], 0)
        self.assertEqual(payload["summary"]["cited_enforcer_missing"], 0)

    def test_assignment_rhs_is_the_citation(self):
        self.write("n", "The unit's `ExecStopPost=gone-unit.sh` line and `Environment=X=real-guard.sh` both cite scripts.")
        _result, _payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["gone-unit.sh"])

    def test_human_render_lists_the_kind(self):
        self.write("n", "Run `cr-compact.py`.")
        command = [
            "python3", str(AUDITOR), "--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror),
            "--enforcer-repo", str(self.repo),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cited_enforcer_missing: 1", result.stdout)

    def test_linked_worktree_resolves_to_main_checkout(self):
        # Run from a linked worktree, the default enforcer repo is the worktree,
        # whose Claude Code project holds no feedback notes, so the check covered
        # 0 notes and reported nothing (seen live 2026-10-08 on the first human
        # run of this check). A linked worktree's .git is a pointer file into the
        # main checkout's .git/worktrees/<name>; that main checkout's project is
        # the one whose notes cite this repo's enforcers.
        self.write("n", "Run `gone.sh` first.")
        worktree = self.repo.parent / "worktree"
        worktree.mkdir()
        (self.repo / ".git" / "worktrees" / "worktree").mkdir(parents=True)
        (worktree / ".git").write_text(f"gitdir: {self.repo}/.git/worktrees/worktree\n")
        _, payload, flagged = self.audit("--enforcer-repo", str(worktree))
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["repo"], str(self.repo))
        self.assertEqual(scope["repo_requested"], str(worktree))
        self.assertEqual(scope["project"], self.key)
        self.assertEqual(scope["notes_checked"], 1)
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])

    def test_main_checkout_leaves_ordinary_checkouts_alone(self):
        plain = self.repo.parent / "plain"
        (plain / ".git").mkdir(parents=True)
        self.assertEqual(MA.main_checkout(plain), plain)
        self.assertEqual(MA.main_checkout(self.repo), self.repo)  # no .git at all
        odd = self.repo.parent / "odd"
        odd.mkdir()
        (odd / ".git").write_text("not a pointer\n")
        self.assertEqual(MA.main_checkout(odd), odd)
        elsewhere = self.repo.parent / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / ".git").write_text("gitdir: /srv/bare.git\n")
        self.assertEqual(MA.main_checkout(elsewhere), elsewhere)
        relative = self.repo.parent / "relative"
        relative.mkdir()
        (relative / ".git").write_text("gitdir: ../repo/.git/worktrees/relative\n")
        self.assertEqual(MA.main_checkout(relative), self.repo)

    def test_human_render_shows_coverage_scope(self):
        # The denominator is part of the result: a run that checked 0 notes must
        # not read like a clean store.
        self.write("n", "Run `cr-compact.py`.")
        command = [
            "python3", str(AUDITOR), "--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror),
            "--enforcer-repo", str(self.repo), "--repo-root", str(self.sites), "--enforcer-extra-root", str(self.plugins),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cited_enforcer_scope: 1 feedback note(s) checked, 0 skipped as other-repo", result.stdout)
        self.assertIn(f"project {self.key}", result.stdout)

    def unreadable_dir(self, name, parent=None):
        # Mode 000 is restored before the TemporaryDirectory cleanup registered in
        # setUp runs (cleanups run last-in first-out), so rmtree can remove it.
        path = (parent or self.repo.parent) / name
        path.mkdir(parents=True)
        os.chmod(path, 0)
        self.addCleanup(os.chmod, path, 0o700)
        if os.geteuid() == 0 or os.access(path, os.R_OK):
            self.skipTest("mode 000 does not make a directory unreadable here")
        return path

    def unsearchable_dir(self, path):
        # Mode r-- (0o444): the directory still lists, but nothing inside it can be
        # stat'ed. Restored before the TemporaryDirectory cleanup like unreadable_dir.
        os.chmod(path, 0o444)
        self.addCleanup(os.chmod, path, 0o700)
        if os.geteuid() == 0 or os.access(path, os.X_OK):
            self.skipTest("mode 444 does not make a directory unsearchable here")
        return path

    def test_copy_gate_skips_the_advisory_scan_even_with_unreadable_roots(self):
        # sync.sh's nightly push runs --copy-gate; its verdict is about confinement
        # and sensitive data only. At 43575a48 the sibling-repo discovery ran in
        # that mode too, and an unreadable optional root turned the push into
        # "auditor could not inspect live memory" (exit 2; #1699 comment 6070518687).
        self.write("n", "Run `gone.sh` first.")
        sealed = self.unreadable_dir("sealed-sites")
        command = [
            "python3", str(AUDITOR), "--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror),
            "--copy-gate", "--enforcer-repo", str(self.repo), "--repo-root", str(sealed), "--enforcer-extra-root", str(sealed),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unable to read audit roots", result.stderr)
        gate = json.loads(result.stdout)
        self.assertEqual(gate["blocked"], [])
        self.assertEqual(gate["quarantine_paths"], [])

    def test_unreadable_discovery_root_degrades_the_check_not_the_audit(self):
        # Outside the copy gate the check still runs, records what it could not
        # read, and keeps auditing: an unreadable ~/SITES is a degraded other-repo
        # guard, not a reason to exit 2 without a verdict.
        self.write("n", "Run `gone.sh` first.")
        sealed = self.unreadable_dir("sealed-sites")
        _result, payload, flagged = self.audit(sites=sealed)
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["repo_names"], [])
        self.assertEqual(len(scope["discovery_errors"]), 1, scope)
        self.assertIn(str(sealed), scope["discovery_errors"][0])
        command = [
            "python3", str(AUDITOR), "--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror),
            "--enforcer-repo", str(self.repo), "--repo-root", str(sealed), "--enforcer-extra-root", str(self.plugins),
        ]
        human = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("cited_enforcer_discovery_errors: 1", human.stdout)

    def test_own_repo_github_url_is_not_an_other_repo_signal(self):
        self.write(
            "n",
            f"Fixed in https://github.com/StartupBros-com/{self.repo.name}/pull/5 by `gone.sh`.\n\n"
            "Upstream fix: https://github.com/other-org/thing/pull/9 added `foreign.py`.",
        )
        _result, payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_other_repo"], 1)

    def test_directories_and_broken_symlinks_are_not_existing_scripts(self):
        (self.repo / "scripts" / "directory.py").mkdir()
        (self.repo / "scripts" / "broken.sh").symlink_to("missing-target.sh")
        (self.repo / "scripts" / "link.sh").symlink_to("real-guard.sh")
        self.write(
            "n",
            "A directory `scripts/directory.py` and a dangling link `scripts/broken.sh` or `broken.sh` "
            "are not scripts; `link.sh`, `scripts/` and `hooks` resolve.",
        )
        _result, _payload, flagged = self.audit()
        self.assertEqual(
            sorted(item["token"] for item in flagged),
            ["broken.sh", "scripts/broken.sh", "scripts/directory.py"],
        )

    def test_line_anchors_and_dot_slash_prefixes_are_normalised(self):
        self.write("n", "See `./scripts/real-guard.sh#L12-L20`, `real-guard.sh#L3` and `./gone.sh#L7`.")
        _result, _payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])

    def test_other_repo_signal_is_scoped_to_the_sentence(self):
        # dotfiles#1687: "tokens inside a sentence that names another repo" are
        # skipped. A later sentence or list item of the same paragraph is back in
        # scope, so an acme-app reference cannot hide this repo's missing script.
        self.write(
            "n",
            "Shipped in acme-app#1621 (`check-migration-code-coupling.mjs`). Locally, run `gone.sh` before pushing.\n\n"
            "The gate is acme-app#1700's, e.g. `coupling.mjs` there, i.e. not here.\n\n"
            "- acme-app#1621 fixed `coupling.mjs`\n- run `gone-too.sh` here",
        )
        _result, payload, flagged = self.audit()
        self.assertEqual(sorted(item["token"] for item in flagged), ["gone-too.sh", "gone.sh"])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["notes_other_repo"], 1)

    def doctor_line(self, summary):
        # harness-doctor.sh renders its memory-audit line with two inline Python
        # programs; run the real ones so the shell file cannot drift from the audit.
        text = (AUDITOR.parent / "harness-doctor.sh").read_text()
        programs = {}
        for name in ("_memory_summary", "_memory_actionable"):
            match = re.search(rf"{name}=\$\(python3 -c '(.*?)' <<<", text)
            self.assertIsNotNone(match, f"{name} snippet not found in harness-doctor.sh")
            programs[name] = match.group(1)
        payload = json.dumps({"summary": summary})
        line = subprocess.run(["python3", "-c", programs["_memory_summary"]], input=payload, text=True, capture_output=True, check=True)
        count = subprocess.run(["python3", "-c", programs["_memory_actionable"]], input=payload, text=True, capture_output=True, check=True)
        return line.stdout.strip(), int(count.stdout.strip())

    def gate_audit(self, *args):
        # The in-process copy-gate run: sync.sh passes only --copy-gate, so the
        # enforcer repo and both discovery roots are the production defaults.
        argv = ["--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror), "--copy-gate", *args]
        return MA.audit(MA.parser().parse_args(argv))

    def test_doctor_snippets_render_every_summary_shape(self):
        # Real auditor summaries, so a doctor program reading a field the auditor
        # stopped writing fails here instead of rendering a clean line (CE on
        # #1699: a missing enforcer repo rendered "0 actionable" at 28067804).
        prefix = "0 actionable, 0 stale-date review candidate(s)"
        self.write("n", "Run `gone.sh`, then `gone-too.sh`.")
        _result, live, _flagged = self.audit()
        self.assertEqual(self.doctor_line(live["summary"]), (f"{prefix}, 2 phantom enforcer citation(s)", 2))
        gone = self.repo.parent / "gone-repo"
        _result, missing, _flagged = self.audit(enforcer_repo=gone)
        self.assertEqual(self.doctor_line(missing["summary"]), (f"{prefix}, cited-enforcer repo unavailable ({gone})", 1))
        for path in self.live.iterdir():
            path.unlink()
            (self.mirror / path.name).unlink()
        self.write("p", "A project note cites `gone.sh` without being checked.", note_type="project")
        _result, zero, _flagged = self.audit()
        self.assertEqual(
            self.doctor_line(zero["summary"]),
            (f"{prefix}, cited-enforcer check covered 0 feedback notes (project {self.key})", 1),
        )
        skipped = self.gate_audit()["summary"]
        self.assertEqual(skipped["cited_enforcer_scope"], {"skipped": "copy-gate"})
        self.assertEqual(self.doctor_line(skipped), (prefix, 0))
        # An auditor older than the check writes no scope block at all.
        base = {"blocking_findings": 3, "review_candidates": 1}
        self.assertEqual(self.doctor_line(base), ("3 actionable, 1 stale-date review candidate(s)", 3))
        # Last, because unreadable_dir skips the test where mode 000 stays readable
        # (root): every shape above must have asserted before that can happen. The
        # live store now holds only the project note, so this is the two-warning line.
        sealed = self.unreadable_dir("sealed-sites")
        _result, degraded, _flagged = self.audit(sites=sealed)
        self.assertEqual(
            self.doctor_line(degraded["summary"]),
            (
                f"{prefix}, cited-enforcer check covered 0 feedback notes (project {self.key}), "
                "cited-enforcer discovery degraded (1 error(s))",
                2,
            ),
        )
        # The combined shape, phantom citations plus degraded discovery, with the
        # feedback note written back: the doctor's count adds both (CE on #1699
        # round 5: the move above had dropped this shape from the suite).
        self.write("n", "Run `gone.sh`, then `gone-too.sh`.")
        _result, combined, _flagged = self.audit(sites=sealed)
        self.assertEqual(
            self.doctor_line(combined["summary"]),
            (f"{prefix}, 2 phantom enforcer citation(s), cited-enforcer discovery degraded (1 error(s))", 3),
        )

    def test_missing_enforcer_repo_is_reported_not_clean(self):
        # A deleted checkout or a wrong --enforcer-repo checks 0 notes. That is a
        # named warning in the scope block and the human render, never a clean run.
        self.write("n", "Run `gone.sh`.")
        gone = self.repo.parent / "gone-repo"
        _result, payload, flagged = self.audit(enforcer_repo=gone)
        self.assertEqual(flagged, [])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertFalse(scope["repo_exists"])
        self.assertEqual(scope["notes_checked"], 0)
        # .get(): at the defect revision these keys do not exist yet, and the RED
        # primitive needs an assertion failure there, not a KeyError.
        self.assertEqual(scope.get("discovery_errors"), [])
        self.assertEqual(scope.get("warnings"), [f"cited-enforcer repo unavailable ({gone})"])
        command = [
            "python3", str(AUDITOR), "--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror),
            "--enforcer-repo", str(gone), "--repo-root", str(self.sites), "--enforcer-extra-root", str(self.plugins),
        ]
        human = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn(f"cited_enforcer_warnings: 1 (cited-enforcer repo unavailable ({gone}))", human.stdout)
        # The healthy run carries an empty list, so a consumer can always read it.
        _result, payload, _flagged = self.audit()
        self.assertEqual(payload["summary"]["cited_enforcer_scope"].get("warnings"), [])

    def test_inaccessible_root_parents_degrade_the_check_not_the_audit(self):
        # A root whose parent denies traversal cannot even be stat'ed: Path.is_dir()
        # raises PermissionError under 3.12 and returns False under 3.13. Either way
        # the probe failure must land in discovery_errors and the audit must finish.
        self.write("n", "Run `gone.sh`.")
        inner = self.unreadable_dir("sealed") / "inner"
        _result, payload, flagged = self.audit(sites=inner, plugins=inner)
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertTrue(scope["repo_exists"])
        self.assertEqual(scope["notes_checked"], 1)
        self.assertEqual(len(scope["discovery_errors"]), 2, scope)  # the repo-root probe and the extra-root probe
        self.assertTrue(all(str(inner) in error for error in scope["discovery_errors"]), scope)
        self.assertEqual(scope["warnings"], ["cited-enforcer discovery degraded (2 error(s))"])
        # The enforcer repo itself behind such a parent: its .git probe and its own
        # probe are both recorded, and the run is reported as repo-unavailable.
        _result, payload, flagged = self.audit(enforcer_repo=inner)
        self.assertEqual(flagged, [])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertFalse(scope["repo_exists"])
        self.assertEqual(len(scope["discovery_errors"]), 2, scope)
        self.assertTrue(all(str(inner) in error for error in scope["discovery_errors"]), scope)
        self.assertEqual(
            scope["warnings"],
            [f"cited-enforcer repo unavailable ({inner})", "cited-enforcer discovery degraded (2 error(s))"],
        )

    def test_unreadable_cited_path_is_unknown_not_phantom(self):
        # EACCES on a cited repo path is a probe failure, recorded and never a
        # phantom: the file may well be there.
        sealed = self.unreadable_dir("sealed", parent=self.repo)
        self.write("n", "Run `sealed/inner/guard.sh` and `gone.sh`.")
        _result, payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        scope = payload["summary"]["cited_enforcer_scope"]
        # Two distinct failures: the index walk could not list the sealed directory,
        # and the cited path behind it could not be stat'ed.
        self.assertEqual(
            sorted(error.split(": ")[0] for error in scope["discovery_errors"]),
            sorted([str(sealed), str(sealed / "inner" / "guard.sh")]),
            scope,
        )

    def test_file_valued_discovery_root_is_a_discovery_error(self):
        # An operator-supplied root that exists but is a regular file is a
        # misconfiguration, recorded so the run does not read as a complete
        # check. A root that is simply absent (no ~/SITES on a CI host) stays silent.
        self.write("n", "Run `gone.sh`.")
        flat = self.repo.parent / "flat-root"
        flat.write_text("")
        _result, payload, flagged = self.audit(sites=flat)
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        # .get(): the defect revision has no discovery_errors key; RED needs a
        # failed assertion there, not a KeyError.
        self.assertEqual(payload["summary"]["cited_enforcer_scope"].get("discovery_errors"), [f"{flat}: not a directory"])
        _result, payload, _flagged = self.audit(sites=self.repo.parent / "absent-root", plugins=self.repo.parent / "absent-plugins")
        self.assertEqual(payload["summary"]["cited_enforcer_scope"].get("discovery_errors"), [])

    def test_nul_in_a_cited_path_degrades_not_crashes(self):
        # Note bodies are agent-written text. Path.stat() raises ValueError, not
        # OSError, on an embedded NUL; at 28067804 that traceback ended the whole
        # audit with exit 1 and no report (CE on #1699, security P2).
        self.write("n", "Run `scripts/re\x00al.sh` then `gone.sh`.")
        _result, payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        self.assertEqual(payload["summary"]["cited_enforcer_scope"]["discovery_errors"], [])
        self.assertIsNone(MA.enforcer_token("scripts/re\x00al.sh"))
        errors = []
        self.assertEqual(MA.path_kind(self.repo / "re\x00al.sh", errors), "unknown")
        self.assertEqual(len(errors), 1, errors)

    def test_copy_gate_runs_no_enforcer_discovery(self):
        # Every probe the check owns raises if called: sync.sh's gate must never
        # reach any of them (at 43575a48 it ran the sibling-repo discovery and an
        # unreadable ~/SITES ended the nightly push with exit 2).
        self.write("n", "Run `gone.sh`.")
        probes = ("other_repo_names", "main_checkout", "enforcer_index", "path_kind", "usable_root")
        patched = []
        with contextlib.ExitStack() as stack:
            for name in probes:
                # The defect revision lacks some of these; RED must fail on the gate
                # running discovery, not on patching a name that is not there yet.
                if hasattr(MA, name):
                    stack.enter_context(mock.patch.object(MA, name, side_effect=AssertionError(f"{name} ran in copy-gate mode")))
                    patched.append(name)
            result = self.gate_audit()
        self.assertEqual(result["summary"]["cited_enforcer_scope"], {"skipped": "copy-gate"})
        self.assertEqual(MA.copy_gate(result)["blocked"], [])
        # Every probe the pin names must exist at head, or a renamed probe escapes it.
        self.assertEqual(patched, list(probes))

    def test_unsearchable_repo_root_records_each_child_it_cannot_probe(self):
        # A root that lists but cannot be searched (mode r--): iterdir() yields the
        # sibling checkouts and probing any of them fails. Path.is_dir() raised
        # PermissionError there under 3.12 (at 43575a48 that ended the audit with a
        # traceback; at 28067804 it was recorded against the root and the rest of
        # the root was abandoned) and returns False under 3.13, recording nothing.
        # Each child the auditor cannot probe is one recorded failure, on both, and
        # two children show the loop continues past the first failed probe.
        acme_app = self.sites / "acme-app"
        prbot = self.sites / "prbot"
        for child in (acme_app, prbot):
            child.mkdir()
            self.fixture.project(MA.project_key(child))
        self.unsearchable_dir(self.sites)
        self.write("n", "Run `gone.sh`.")
        command = [
            "python3", str(AUDITOR), "--live-root", str(self.fixture.live), "--mirror-root", str(self.fixture.mirror),
            "--format", "json", "--enforcer-repo", str(self.repo), "--repo-root", str(self.sites),
            "--enforcer-extra-root", str(self.plugins),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        # The audit must finish with a verdict: a probe failure is never a traceback.
        self.assertNotIn("Traceback", result.stderr, result.stderr)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual([item["token"] for item in payload["findings"] if item["kind"] == "cited_enforcer_missing"], ["gone.sh"])
        scope = payload["summary"]["cited_enforcer_scope"]
        self.assertEqual(scope["repo_names"], [])
        # .get(): the defect revision writes neither key; RED needs a failed assertion.
        # sorted(): iterdir() yields the children in filesystem order.
        self.assertEqual(
            sorted(scope.get("discovery_errors") or []),
            sorted(f"{child}: Permission denied" for child in (acme_app, prbot)),
        )
        self.assertEqual(scope.get("warnings"), ["cited-enforcer discovery degraded (2 error(s))"])

    def test_unstatable_indexed_file_is_recorded_and_stays_citable(self):
        # os.walk lists the entries of a directory that lists but cannot be searched
        # (mode r--) without a stat, and at 28067804 the regular-file filter dropped
        # each of them in silence: a real enforcer vanished from the basename index,
        # its citation became a phantom, and the scope block claimed a complete check.
        held = self.repo / "held"
        held.mkdir()
        (held / "held-guard.sh").write_text("#!/bin/sh\n")
        self.unsearchable_dir(held)
        self.write("n", "Run `held-guard.sh` and `gone.sh`.")
        _result, payload, flagged = self.audit()
        self.assertEqual([item["token"] for item in flagged], ["gone.sh"])
        scope = payload["summary"]["cited_enforcer_scope"]
        # .get(): the defect revision writes neither key; RED needs a failed assertion.
        self.assertEqual(scope.get("discovery_errors"), [f"{held / 'held-guard.sh'}: Permission denied"])
        self.assertEqual(scope.get("warnings"), ["cited-enforcer discovery degraded (1 error(s))"])

    def test_sync_memory_push_gate_survives_unreadable_default_roots(self):
        # The real consumer, production-shaped: sync.sh memory-push passes only
        # --copy-gate, so the discovery roots are ~/SITES and ~/.claude/plugins of
        # this HOME. An unreadable ~/SITES must not refuse the push.
        home = self.repo.parent / "home"
        live = home / ".claude" / "projects" / self.key / "memory"
        live.mkdir(parents=True)
        (live / "MEMORY.md").write_text("- [n](n.md)\n")
        (live / "n.md").write_text(note("n", note_type="feedback", body="Run `gone.sh`."))
        mirror = self.repo.parent / "sync-mirror"
        (mirror / self.key).mkdir(parents=True)
        self.unreadable_dir("SITES", parent=home)
        env = os.environ.copy()
        env.update({"HOME": str(home), "CLAUDE_MEMORY_MIRROR_ROOT": str(mirror)})
        pushed = subprocess.run(["bash", str(SYNC), "memory-push"], env=env, text=True, capture_output=True, check=False)
        self.assertEqual(pushed.returncode, 0, pushed.stderr)
        self.assertNotIn("could not inspect live memory", pushed.stderr)
        self.assertTrue((mirror / self.key / "n.md").exists(), pushed.stdout + pushed.stderr)

