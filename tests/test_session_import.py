#!/usr/bin/env python3
"""Tests for session-import.py.

The failures that matter for an import into an append-only archive are a stored
byte the mirror never held, a transcript filed under a key a capture pass would
not have given it, and a stored version changed or lost on the way. Every test
here builds a mirror on disk in cass's manifest format, imports it into a real
store with the real zstd binary, and reads the store back with a plain
`zstd -dc`, not with either tool's own reader. Where an import has to live with
capture passes, the real session-archive.py makes them.
"""

import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "session-import.py"
SEARCH = REPO / "scripts" / "session-search.py"
BACKEND = REPO / "scripts" / "session-index-backend.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


I = load("session_import_module", SCRIPT)
A = I.load_archive()
S = load("session_search_for_import_tests", SEARCH)

ZSTD = shutil.which("zstd")
U1 = "11111111-1111-4111-8111-111111111111"
U2 = "22222222-2222-4222-8222-222222222222"


def setUpModule():
    # A missing compressor must fail this suite, never skip it.
    if ZSTD is None:
        raise RuntimeError("zstd is not installed; session-import cannot be tested or run without it")


class Crash(BaseException):
    """Stands in for a kill: nothing in the tool catches it."""


def text(seed, size):
    """`size` bytes of line-shaped pseudo-random text."""
    rng = random.Random(seed)
    out, total = [], 0
    while total < size:
        line = ('{"n":%d,"v":"%032x"}\n' % (rng.randrange(10 ** 9), rng.getrandbits(128))).encode()
        out.append(line)
        total += len(line)
    return b"".join(out)[:size]


def said(words, ts="2026-01-10T08:00:00.000Z"):
    """One Claude Code transcript line with a user message."""
    record = {"type": "user", "timestamp": ts, "cwd": "/work/alpha", "sessionId": U1,
              "message": {"role": "user", "content": words}}
    return json.dumps(record).encode() + b"\n"


def zstd_decode(path):
    return subprocess.run([ZSTD, "-dc", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


class Mirror:
    """A raw mirror on disk, laid out as cass writes one."""

    def __init__(self, root):
        self.root = root
        self.count = 0
        os.makedirs(os.path.join(root, "manifests"))
        os.makedirs(os.path.join(root, "blobs", "blake3"))

    def blob(self, data):
        # cass names a blob by its BLAKE3 hash; any content hash keeps the layout.
        digest = hashlib.sha256(data).hexdigest()
        relative = "blobs/blake3/%s/%s" % (digest[:2], digest)
        path = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return {"blob_relative_path": relative, "blob_blake3": digest, "blob_size_bytes": len(data)}

    def add(self, original, data, chunk=0, captured=None, **changes):
        """Write the blobs and the manifest of one captured file; returns the manifest's file name."""
        self.count += 1
        manifest = {"manifest_kind": "cass_raw_session_mirror_v1", "provider": "claude_code",
                    "original_path": original, "captured_at_ms": captured or 1_700_000_000_000 + self.count,
                    "source_size_bytes": len(data), "source_mtime_ms": 1_700_000_000_000,
                    "compression": {"state": "none"}, "encryption": {"state": "none"}, "db_links": []}
        if chunk:
            pieces = [data[start:start + chunk] for start in range(0, len(data), chunk)]
            manifest["content_storage"] = {"kind": "fixed_chunks_v1", "content_size_bytes": len(data),
                                           "chunk_size_bytes": chunk, "chunks": [self.blob(piece) for piece in pieces]}
            manifest.update(blob_relative_path="blobs/blake3/00/unused", blob_blake3="0", blob_size_bytes=0)
        else:
            manifest.update(self.blob(data))
        manifest.update(changes)
        name = "doctor-raw-mirror-manifest-id-v1-%04d.json" % self.count
        self.write(name, manifest)
        return name

    def write(self, name, manifest):
        with open(os.path.join(self.root, "manifests", name), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh)

    def read(self, name):
        with open(os.path.join(self.root, "manifests", name), encoding="utf-8") as fh:
            return json.load(fh)

    def path(self, relative):
        return os.path.join(self.root, relative)


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="session-import-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.claude = os.path.join(self.tmp, "home", ".claude", "projects")
        self.codex = os.path.join(self.tmp, "home", ".codex", "sessions")
        os.makedirs(self.claude)
        os.makedirs(self.codex)
        self.roots = [A.Root("claude", self.claude, 1), A.Root("codex", self.codex, 0)]
        self.store = os.path.join(self.tmp, "store")
        self.mirror = Mirror(os.path.join(self.tmp, "mirror"))
        self.clock = 1_700_000_000_000_000_000

    # ---- sources and passes ----------------------------------------------------

    def source(self, rel):
        """Where a transcript with this path below the Claude root lived."""
        return os.path.join(self.claude, rel)

    def put(self, rel, data):
        path = self.source(rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        self.clock += 1_000_000_000
        os.utime(path, ns=(self.clock, self.clock))
        return path

    def capture(self, roots=None):
        archive = A.Archive(self.store, roots or self.roots)
        try:
            summary = archive.capture()
        finally:
            archive.close()
        self.assertEqual(summary["store_errors"] + summary["source_errors"], 0, summary)
        return summary

    def importer(self, **options):
        return I.Importer(A, self.store, options.pop("roots", self.roots), self.mirror.root, **options)

    def run_import(self, names=None, **options):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            report = self.importer(**options).run(names)
        self.stderr = err.getvalue()
        return report

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        roots = ["--root", "claude=%s:1" % self.claude, "--root", "codex=%s:0" % self.codex]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = I.main(["--store", self.store, *roots, "mirror", "--mirror", self.mirror.root,
                           "--capture-every", "0", "--min-free-bytes", "0", *args])
        return code, out.getvalue(), err.getvalue()

    # ---- the store, read without the tools ---------------------------------------

    def store_path(self, key, version=1, agent="claude"):
        return os.path.join(self.store, "data", agent, key[:2], key + (".zst" if version == 1 else ".v%d.zst" % version))

    def stored(self, key, version=1, agent="claude"):
        return zstd_decode(self.store_path(key, version, agent))

    def rows(self, table="streams"):
        con = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        try:
            order = "id" if table == "streams" else "path"
            return con.execute("SELECT * FROM %s ORDER BY %s" % (table, order)).fetchall()
        finally:
            con.close()

    def store_files(self):
        """{path below the store's data folder: bytes} of every store file."""
        found = {}
        base = os.path.join(self.store, "data")
        for folder, _dirs, files in os.walk(base):
            for name in files:
                path = os.path.join(folder, name)
                with open(path, "rb") as fh:
                    found[os.path.relpath(path, base)] = fh.read()
        return found

    def ledger(self, outcome=None):
        """The ledger's rows for settled manifests, or the rows with one outcome (`begun` among them)."""
        path = os.path.join(self.store, "imports", "cass-mirror.jsonl")
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
        return [row for row in rows if (row["outcome"] == outcome if outcome else row["outcome"] != "begun")]

    def with_archive(self, change):
        """Run one import whose Archive object `change` has been applied to."""
        original = A.Archive

        def changed(*args, **kwargs):
            archive = original(*args, **kwargs)
            change(archive)
            return archive
        changed.place = original.place
        A.Archive = changed
        self.addCleanup(setattr, A, "Archive", original)
        return original


# ---- bytes -----------------------------------------------------------------------

class StoreTests(Case):
    def test_a_whole_blob_is_stored_byte_for_byte_under_the_key_capture_would_give_it(self):
        data = text(1, 50_000)
        name = self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), data)
        report = self.run_import()
        self.assertEqual((report["manifests"], report["stored"], report["refused"]), (1, 1, 0))
        self.assertEqual(self.stored(U1 + ".jsonl"), data)
        self.assertEqual([row[1:5] for row in self.rows()], [("claude", U1 + ".jsonl", 1, len(data))])
        self.assertEqual(self.rows("sources"), [])
        row, = self.ledger()
        self.assertEqual({k: row[k] for k in ("manifest", "outcome", "agent", "key", "version", "bytes", "path")},
                         {"manifest": name, "outcome": "stored", "agent": "claude", "key": U1 + ".jsonl",
                          "version": 1, "bytes": len(data), "path": self.source("proj-a/" + U1 + ".jsonl")})

    def test_a_chunked_transcript_is_put_together_in_order_and_no_copy_is_left(self):
        data = text(2, 300_000)
        self.mirror.add(self.source("proj-a/" + U1 + "/subagents/agent-a1.jsonl"), data, chunk=65_536)
        report = self.run_import()
        self.assertEqual(report["stored"], 1)
        self.assertEqual(self.stored(U1 + "/subagents/agent-a1.jsonl"), data)
        begun, = self.ledger("begun")
        self.assertEqual((begun["agent"], begun["key"]), ("claude", U1 + "/subagents/agent-a1.jsonl"))

    def test_captures_of_a_growing_file_become_one_version(self):
        data = text(3, 90_000)
        path = self.source("proj-a/" + U1 + ".jsonl")
        # Written newest first, so only the capture times put them in order.
        self.mirror.add(path, data, captured=3000)
        self.mirror.add(path, data[:30_000], captured=1000)
        self.mirror.add(path, data[:60_000], chunk=16_384, captured=2000)
        report = self.run_import()
        self.assertEqual((report["stored"], report["extended"], report.get("new_version", 0)), (1, 2, 0))
        self.assertEqual(self.stored(U1 + ".jsonl"), data)
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual([row["outcome"] for row in self.ledger()], ["stored", "extended", "extended"])

    def test_a_rewritten_file_becomes_a_version_beside_the_first(self):
        path = self.source("proj-a/" + U1 + ".jsonl")
        first, second = text(4, 20_000), text(5, 20_000)
        self.mirror.add(path, first, captured=1000)
        self.mirror.add(path, second, captured=2000)
        report = self.run_import()
        self.assertEqual((report["stored"], report["new_version"]), (1, 1))
        self.assertEqual(self.stored(U1 + ".jsonl"), first)
        self.assertEqual(self.stored(U1 + ".jsonl", 2), second)

    def test_an_empty_file_is_settled_and_stores_nothing(self):
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), b"")
        report = self.run_import()
        self.assertEqual(report["empty"], 1)
        self.assertEqual(self.store_files(), {})
        self.assertEqual(self.rows(), [])
        self.assertEqual([row["outcome"] for row in self.ledger()], ["empty"])

    def test_other_agents_and_followed_files_that_are_not_transcripts(self):
        rollout = "2026/06/10/rollout-2026-06-10T09-00-00-" + U2 + ".jsonl"
        meta, result = text(6, 900), text(7, 4_000)
        self.mirror.add(os.path.join(self.codex, rollout), text(8, 9_000))
        self.mirror.add(self.source("proj-a/" + U1 + "/subagents/agent-a1.meta.json"), meta)
        self.mirror.add(self.source("proj-a/" + U1 + "/tool-results/toolu_01.txt"), result)
        report = self.run_import()
        self.assertEqual(report["stored"], 3)
        self.assertEqual(self.stored(rollout, agent="codex"), text(8, 9_000))
        self.assertEqual(self.stored(U1 + "/subagents/agent-a1.meta.json"), meta)
        self.assertEqual(self.stored(U1 + "/tool-results/toolu_01.txt"), result)


# ---- what the archive already holds ----------------------------------------------

class HeldTests(Case):
    def test_a_file_the_archive_holds_stores_nothing_and_changes_nothing(self):
        data = text(10, 40_000)
        path = self.put("proj-a/" + U1 + ".jsonl", data)
        self.capture()
        files, rows, sources = self.store_files(), self.rows(), self.rows("sources")
        self.mirror.add(path, data)
        self.mirror.add(path, data[:15_000])          # an earlier, shorter capture of the same file
        report = self.run_import()
        self.assertEqual((report["held"], report["bytes_added"] if "bytes_added" in report else 0), (2, 0))
        self.assertEqual((self.store_files(), self.rows(), self.rows("sources")), (files, rows, sources))

    def test_a_capture_longer_than_the_stored_file_extends_it_and_capture_then_agrees(self):
        data = text(11, 80_000)
        path = self.put("proj-a/" + U1 + ".jsonl", data[:30_000])
        self.capture()
        before = self.store_files()[os.path.relpath(self.store_path(U1 + ".jsonl"), os.path.join(self.store, "data"))]
        self.mirror.add(path, data)
        report = self.run_import()
        self.assertEqual((report["extended"], report["bytes_added"]), (1, 50_000))
        self.assertEqual(self.stored(U1 + ".jsonl"), data)
        with open(self.store_path(U1 + ".jsonl"), "rb") as fh:
            self.assertEqual(fh.read(len(before)), before)      # the frames already there are untouched
        # The live file is still the shorter one. A pass that looks at it again
        # finds every byte stored and starts no version.
        self.put("proj-a/" + U1 + ".jsonl", data[:30_000])
        summary = self.capture()
        self.assertEqual((summary["covered"], summary["versions"], summary["appended"]), (1, 0, 0))
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)

    def test_a_different_file_under_a_held_key_is_a_new_version_and_the_first_is_untouched(self):
        live = text(12, 25_000)
        path = self.put("proj-a/" + U1 + ".jsonl", live)
        self.capture()
        first = self.store_files()
        old = text(13, 18_000)
        self.mirror.add(path, old)
        report = self.run_import()
        self.assertEqual(report["new_version"], 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), live)
        self.assertEqual(self.stored(U1 + ".jsonl", 2), old)
        for name, data in first.items():
            self.assertEqual(self.store_files()[name], data)
        # The live file still belongs to version 1: verify compares it there.
        archive = A.Archive(self.store, self.roots, readonly=True)
        try:
            self.assertEqual(archive.verify([], 1 << 30)["same"], 1)
        finally:
            archive.close()

    def test_a_staged_copy_under_a_second_root_of_the_same_agent_lands_in_the_sessions_own_stream(self):
        data = text(14, 30_000)
        self.put("proj-a/" + U1 + ".jsonl", data[:20_000])
        self.capture()
        staged = os.path.join(self.tmp, "recovery", "stage", ".claude", "projects")
        roots = self.roots + [A.Root("claude", staged, 1)]
        self.mirror.add(os.path.join(staged, "proj-renamed", U1 + ".jsonl"), data)
        report = self.run_import(roots=roots)
        self.assertEqual(report["extended"], 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)
        self.assertEqual(len(self.rows()), 1)


# ---- living with capture passes ---------------------------------------------------

class CaptureTests(Case):
    def test_capture_and_verify_leave_imported_streams_exactly_as_they_were(self):
        gone, live = text(20, 35_000), text(21, 22_000)
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), gone)
        self.mirror.add(self.source("proj-a/" + U1 + "/subagents/agent-a1.jsonl"), gone[:9_000], chunk=4_096)
        self.run_import()
        files = self.store_files()
        rows = self.rows()
        self.put("proj-b/" + U2 + ".jsonl", live)
        summary = self.capture()
        self.assertEqual(summary["streams"], 1)
        archive = A.Archive(self.store, self.roots, readonly=True)
        try:
            report = archive.verify([], 1 << 30)
        finally:
            archive.close()
        self.assertEqual((report["same"], report["different"]), (1, 0))
        after = self.store_files()
        for name, data in files.items():
            self.assertEqual(after[name], data, name)
        self.assertEqual(self.rows()[:len(rows)], rows)
        self.assertEqual(len(self.rows()), len(rows) + 1)

    def test_a_file_that_is_live_after_all_continues_its_imported_stream(self):
        data = text(22, 70_000)
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), data[:40_000])
        self.run_import()
        for size, counter in ((70_000, "proved"), (40_000, "covered"), (25_000, "covered")):
            with self.subTest(size=size):
                self.put("proj-a/" + U1 + ".jsonl", data[:size])
                summary = self.capture()
                self.assertEqual((summary[counter], summary["versions"], summary["streams"]), (1, 0, 0), summary)
                self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)

    def test_the_key_is_the_one_a_capture_pass_binds_the_same_path_to(self):
        rels = ["proj-a/" + U1 + ".jsonl", "proj-a/" + U1 + "/subagents/agent-a1.jsonl",
                "proj-a/" + U1 + "/subagents/agent-a1.meta.json", "proj-a/" + U1 + "/tool-results/toolu_01.txt",
                "proj-b/" + U2 + "/subagents/workflows/wf_1/journal.jsonl"]
        paths = [self.put(rel, text(30 + n, 2_000)) for n, rel in enumerate(rels)]
        rollout = os.path.join(self.codex, "2026/06/10/rollout-x.jsonl")
        os.makedirs(os.path.dirname(rollout))
        with open(rollout, "wb") as fh:
            fh.write(text(40, 2_000))
        self.capture()
        archive = A.Archive(self.store, self.roots, readonly=True)
        try:
            for path in paths + [rollout]:
                stream, _size = archive.bound(path)
                self.assertEqual(I.identity(A, self.roots, path), ("ok", stream.agent, stream.key), path)
        finally:
            archive.close()

    def test_the_lock_is_waited_for_and_nothing_is_written_until_it_is_free(self):
        data = text(23, 12_000)
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), data)
        os.makedirs(self.store)
        held = os.open(os.path.join(self.store, "lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, held)
        fcntl.flock(held, fcntl.LOCK_EX)
        done = {}
        worker = threading.Thread(target=lambda: done.update(report=self.importer().run()))
        worker.start()
        worker.join(0.5)
        self.assertTrue(worker.is_alive())
        self.assertEqual(self.store_files(), {})
        fcntl.flock(held, fcntl.LOCK_UN)
        worker.join(30)
        self.assertFalse(worker.is_alive())
        self.assertEqual(done["report"]["stored"], 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)

    def test_a_kill_between_the_store_write_and_the_state_commit_leaves_the_bytes_once(self):
        data = text(24, 60_000)
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), data[:20_000], captured=1000)
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), data, captured=2000)
        self.run_import(limit=1)

        def hook():
            raise Crash()
        importer = self.importer()
        original = A.Archive

        def crashing(*args, **kwargs):
            archive = original(*args, **kwargs)
            archive.after_store_write = hook
            return archive
        A.Archive, restore = crashing, original
        A.Archive.place = original.place
        try:
            with self.assertRaises(Crash), contextlib.redirect_stderr(io.StringIO()):
                importer.run()
        finally:
            A.Archive = restore
        # The frame reached the store file and the state never heard of it.
        self.assertEqual(self.rows()[0][4], 20_000)
        self.assertEqual(len(self.ledger()), 1)
        report = self.run_import()
        self.assertEqual(report["store_errors"] if "store_errors" in report else 0, 0)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)
        self.assertEqual(self.rows()[0][4], len(data))
        self.assertEqual(len(self.ledger()), 2)

    def test_new_keys_only_leaves_a_key_a_capture_pass_stored_while_the_import_waited_for_the_lock(self):
        data = text(25, 30_000)
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), data)
        importer = self.importer(new_keys_only=True)
        take = importer.take_lock

        def a_pass_runs_first(lock, size):
            self.put("proj-a/" + U1 + ".jsonl", data[:10_000])
            self.capture()
            take(lock, size)
        importer.take_lock = a_pass_runs_first
        with contextlib.redirect_stderr(io.StringIO()):
            report = importer.run()
        self.assertEqual((report["key_in_archive_left_for_later"], report.get("stored", 0), report.get("extended", 0)),
                         (1, 0, 0))
        self.assertEqual(self.stored(U1 + ".jsonl"), data[:10_000])
        self.assertEqual((self.ledger(), self.ledger("begun")), ([], []))


# ---- kills and failures part way ----------------------------------------------------

class KillTests(Case):
    """Under --new-keys-only a key the import began must stay the import's own, whatever stopped it."""

    def setUp(self):
        super().setUp()
        self.grown = text(26, 45_000)
        self.path = self.source("proj-b/" + U2 + ".jsonl")
        self.mirror.add(self.path, self.grown[:15_000], captured=1000)
        self.mirror.add(self.path, self.grown, captured=2000)

    def finish(self):
        report = self.run_import(new_keys_only=True)
        self.assertEqual((report.get("key_in_archive_left_for_later", 0), report.get("store_errors", 0)), (0, 0))
        self.assertEqual(self.stored(U2 + ".jsonl"), self.grown)
        self.assertEqual([row[1:5] for row in self.rows()], [("claude", U2 + ".jsonl", 1, len(self.grown))])
        self.assertEqual([row["outcome"] for row in self.ledger()][-1], "extended")
        return report

    def test_a_kill_after_the_state_commit_and_before_the_ledger_row(self):
        importer = self.importer(new_keys_only=True)

        def killed(row):
            raise Crash()
        importer.note = killed
        with self.assertRaises(Crash), contextlib.redirect_stderr(io.StringIO()):
            importer.run()
        self.assertEqual(self.stored(U2 + ".jsonl"), self.grown[:15_000])
        self.assertEqual((self.ledger(), len(self.ledger("begun"))), ([], 1))
        self.finish()

    def test_a_kill_after_the_first_frame_of_a_new_key_and_before_the_state_commit(self):
        def kill(archive):
            def hook():
                raise Crash()
            archive.after_store_write = hook
        original = self.with_archive(kill)
        with self.assertRaises(Crash), contextlib.redirect_stderr(io.StringIO()):
            self.importer(new_keys_only=True).run()
        A.Archive = original
        self.assertEqual(self.rows(), [])                       # the frame is in the store file, the state has no row
        self.assertEqual(self.stored(U2 + ".jsonl"), self.grown[:15_000])
        self.assertEqual((self.ledger(), len(self.ledger("begun"))), ([], 1))
        self.finish()

    def test_a_state_file_error_ends_the_run_and_the_first_error_is_the_one_reported(self):
        def fail(archive):
            def full(*args):
                archive.db.execute("ROLLBACK")          # as SQLite does by itself on some errors
                raise sqlite3.OperationalError("database or disk is full")
            archive.find_or_create = full
        original = self.with_archive(fail)
        report = self.run_import(new_keys_only=True)
        A.Archive = original
        self.assertEqual((report["store_errors"], report["deferred"], report.get("stored", 0)), (1, 1, 0))
        self.assertIn("database or disk is full", self.stderr)
        self.assertEqual((self.store_files(), self.ledger()), ({}, []))
        self.finish()

    def test_an_append_that_failed_leaves_an_empty_version_that_does_not_take_older_bytes(self):
        first, rewritten = text(28, 20_000), text(29, 20_000)
        path = self.source("proj-a/" + U1 + ".jsonl")
        self.mirror.add(path, first, captured=1000)
        self.assertEqual(self.run_import(limit=1)["stored"], 1)
        self.mirror.add(path, rewritten, captured=2000)
        broken = os.path.join(self.tmp, "zstd-that-cannot-compress")
        with open(broken, "w", encoding="utf-8") as fh:
            fh.write('#!/bin/sh\ncase "$1" in -d*) exec "%s" "$@";; esac\nexit 1\n' % ZSTD)
        os.chmod(broken, 0o755)
        A.ZSTD = broken
        self.addCleanup(setattr, A, "ZSTD", ZSTD)
        report = self.run_import(limit=1)
        A.ZSTD = ZSTD
        self.assertEqual(report["store_errors"], 1)
        self.assertEqual(os.path.getsize(self.store_path(U1 + ".jsonl", 2)), 0)
        self.run_import(recheck=True)
        self.assertEqual(self.stored(U1 + ".jsonl"), first)
        self.assertEqual(self.stored(U1 + ".jsonl", 2), rewritten)
        self.assertFalse(os.path.exists(self.store_path(U1 + ".jsonl", 3)))


# ---- refusals ---------------------------------------------------------------------

class RefusalTests(Case):
    def refused(self, name=None, count=1):
        code, out, err = self.cli("--json")
        report = json.loads(out)
        self.assertEqual((code, report["refused"]), (1, count), err)
        self.assertEqual(self.store_files(), {})
        self.assertEqual(self.ledger(), [])
        self.assertFalse(os.path.exists(os.path.join(self.store, "state.sqlite3")) and self.rows())
        if name:
            self.assertIn(name, err)
        return err

    def test_a_missing_blob(self):
        name = self.mirror.add(self.source("p/" + U1 + ".jsonl"), text(50, 5_000))
        os.unlink(self.mirror.path(self.mirror.read(name)["blob_relative_path"]))
        self.refused(name)

    def test_a_blob_of_another_size(self):
        name = self.mirror.add(self.source("p/" + U1 + ".jsonl"), text(51, 5_000))
        with open(self.mirror.path(self.mirror.read(name)["blob_relative_path"]), "ab") as fh:
            fh.write(b"x")
        self.refused(name)

    def test_a_missing_chunk_is_found_before_anything_is_copied(self):
        name = self.mirror.add(self.source("p/" + U1 + ".jsonl"), text(52, 50_000), chunk=8_192)
        chunks = self.mirror.read(name)["content_storage"]["chunks"]
        os.unlink(self.mirror.path(chunks[-1]["blob_relative_path"]))
        scratch = os.path.join(self.tmp, "scratch")
        code, _out, err = self.cli("--scratch", scratch)
        self.assertEqual(code, 1)
        self.assertIn(name, err)
        self.assertFalse(os.path.exists(scratch))
        self.assertEqual(self.store_files(), {})

    def test_chunks_that_do_not_add_up_to_the_recorded_size(self):
        name = self.mirror.add(self.source("p/" + U1 + ".jsonl"), text(53, 50_000), chunk=8_192)
        manifest = self.mirror.read(name)
        manifest["content_storage"]["chunks"].pop()
        self.mirror.write(name, manifest)
        scratch = os.path.join(self.tmp, "scratch")
        code, _out, err = self.cli("--scratch", scratch)
        self.assertEqual(code, 1)
        self.assertIn("do not add up", err)
        self.assertFalse(os.path.exists(scratch))       # refused from the manifest alone: no chunk was copied
        self.refused(name)

    def test_a_recorded_size_the_blob_does_not_have(self):
        name = self.mirror.add(self.source("p/" + U1 + ".jsonl"), text(54, 5_000), source_size_bytes=5_001)
        self.refused(name)

    def test_formats_this_was_not_written_for(self):
        changes = [{"manifest_kind": "cass_raw_session_mirror_v2"}, {"compression": {"state": "zstd"}},
                   {"encryption": {"state": "age"}}, {"content_storage": {"kind": "content_defined_v1", "chunks": []}}]
        for n, change in enumerate(changes):
            self.mirror.add(self.source("p/%d/%s.jsonl" % (n, U1)), text(55 + n, 3_000), **change)
        err = self.refused(count=len(changes))
        for word in ("manifest kind", "compression state", "encryption state", "storage kind"):
            self.assertIn(word, err)

    def test_a_blob_path_that_leaves_the_mirror_or_is_a_link(self):
        secret = os.path.join(self.tmp, "secret")
        with open(secret, "wb") as fh:
            fh.write(b"k" * 100)
        self.mirror.add(self.source("p/1/" + U1 + ".jsonl"), b"k" * 100, blob_relative_path="../secret")
        self.mirror.add(self.source("p/2/" + U1 + ".jsonl"), b"k" * 100, blob_relative_path=secret)
        os.symlink(secret, self.mirror.path("blobs/link"))
        self.mirror.add(self.source("p/3/" + U1 + ".jsonl"), b"k" * 100, blob_relative_path="blobs/link")
        # A path cass would not write is refused even where it leads to the blob.
        for n, (old, new) in enumerate((("blobs/", "/blobs/"), ("blobs/", "./blobs/"), ("blobs/", "blobs/./"),
                                        ("blobs/", "blobs//"))):
            name = self.mirror.add(self.source("p/%d/%s.jsonl" % (4 + n, U1)), b"k" * 100)
            manifest = self.mirror.read(name)
            manifest["blob_relative_path"] = manifest["blob_relative_path"].replace(old, new)
            self.mirror.write(name, manifest)
        self.refused(count=7)

    def test_a_folder_in_a_blob_path_that_is_a_link(self):
        away = os.path.join(self.tmp, "away")
        os.makedirs(away)
        with open(os.path.join(away, "x"), "wb") as fh:
            fh.write(b"k" * 100)
        os.symlink(away, self.mirror.path("blobs/out"))
        self.mirror.add(self.source("p/1/" + U1 + ".jsonl"), b"k" * 100, blob_relative_path="blobs/out/x")
        # A link that stays inside the mirror is refused all the same: cass writes none.
        name = self.mirror.add(self.source("p/2/" + U1 + ".jsonl"), b"k" * 100)
        os.symlink(self.mirror.path("blobs/blake3"), self.mirror.path("blobs/alias"))
        manifest = self.mirror.read(name)
        manifest["blob_relative_path"] = manifest["blob_relative_path"].replace("blobs/blake3", "blobs/alias")
        self.mirror.write(name, manifest)
        self.refused(count=2)

    def test_a_chunk_of_another_size_is_found_before_anything_is_copied(self):
        name = self.mirror.add(self.source("p/" + U1 + ".jsonl"), text(56, 50_000), chunk=8_192)
        chunks = self.mirror.read(name)["content_storage"]["chunks"]
        with open(self.mirror.path(chunks[2]["blob_relative_path"]), "ab") as fh:
            fh.write(b"x")
        scratch = os.path.join(self.tmp, "scratch")
        code, _out, err = self.cli("--scratch", scratch)
        self.assertEqual(code, 1)
        self.assertIn(name, err)
        self.assertFalse(os.path.exists(scratch))
        self.assertEqual(self.store_files(), {})

    def test_a_manifest_no_reader_can_take_is_refused_and_the_ones_after_it_are_imported(self):
        with open(os.path.join(self.mirror.root, "manifests", "doctor-raw-mirror-manifest-id-v1-0000-deep.json"), "w") as fh:
            fh.write("[" * 100_000)
        self.mirror.add(self.source("proj-a/\udcff/" + U1 + ".jsonl"), text(57, 3_000))
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), text(58, 3_000),
                        captured_at_ms="yesterday")                       # sorted as never dated, not a crash
        good = text(59, 3_000)
        self.mirror.add(self.source("proj-z/" + U2 + ".jsonl"), good)
        code, out, err = self.cli("--json")
        report = json.loads(out)
        self.assertEqual((code, report["refused"], report["stored"]), (1, 2, 2), err)
        self.assertEqual(self.stored(U2 + ".jsonl"), good)

    def test_a_manifest_that_is_not_json_or_names_no_path(self):
        with open(os.path.join(self.mirror.root, "manifests", "doctor-raw-mirror-manifest-id-v1-cut.json"), "w") as fh:
            fh.write('{"manifest_kind": "cass_raw_session_mirror_v1", "original_p')
        self.mirror.write("doctor-raw-mirror-manifest-id-v1-list.json", [1, 2])
        self.refused(count=2)

    def test_a_refused_entry_does_not_stop_the_ones_after_it_and_is_tried_again(self):
        bad = self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), text(60, 5_000))
        good = text(61, 5_000)
        self.mirror.add(self.source("proj-b/" + U2 + ".jsonl"), good)
        blob = self.mirror.path(self.mirror.read(bad)["blob_relative_path"])
        os.rename(blob, blob + ".away")
        code, out, _err = self.cli("--json")
        self.assertEqual((code, json.loads(out)["refused"], json.loads(out)["stored"]), (1, 1, 1))
        self.assertEqual(self.stored(U2 + ".jsonl"), good)
        os.rename(blob + ".away", blob)
        code, out, _err = self.cli("--json")
        report = json.loads(out)
        self.assertEqual((code, report["refused"], report["stored"], report["settled_before"]), (0, 0, 1, 1))
        self.assertEqual(self.stored(U1 + ".jsonl"), text(60, 5_000))


class StoreErrorTests(Case):
    def test_a_store_that_cannot_be_written_is_an_error_and_leaves_no_row_and_no_ledger_line(self):
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), text(65, 5_000))
        good = text(66, 5_000)
        rollout = "2026/06/10/rollout-x.jsonl"
        self.mirror.add(os.path.join(self.codex, rollout), good)
        os.makedirs(os.path.join(self.store, "data"))
        with open(os.path.join(self.store, "data", "claude"), "w") as fh:     # a file where a folder must go
            fh.write("in the way")
        code, out, err = self.cli("--json")
        report = json.loads(out)
        self.assertEqual((code, report["store_errors"], report["stored"], report["refused"]), (1, 1, 1, 0), err)
        self.assertEqual([row[1:3] for row in self.rows()], [("codex", rollout)])
        self.assertEqual([row["agent"] for row in self.ledger()], ["codex"])
        self.assertEqual(self.stored(rollout, agent="codex"), good)
        os.unlink(os.path.join(self.store, "data", "claude"))
        code, out, _err = self.cli("--json")
        self.assertEqual((code, json.loads(out)["stored"]), (0, 1))
        self.assertEqual(self.stored(U1 + ".jsonl"), text(65, 5_000))


class PlacementTests(Case):
    def test_paths_outside_the_roots_and_files_capture_does_not_follow_stay_in_the_mirror(self):
        outside = [os.path.join(self.tmp, "home", ".grok", "auth.json"),
                   os.path.join(self.tmp, "home", ".grok", "sessions", "s", "chat.jsonl"),
                   os.path.join(self.claude, "..", "projects", "p", U1 + ".jsonl"),
                   "relative/" + U1 + ".jsonl",
                   os.path.join(self.claude, "loose.jsonl")]           # no project folder above it: no key
        unfollowed = [self.source("p/" + U1 + "/notes.json"), self.source("p/settings.local.json"),
                      os.path.join(self.codex, "2026/06/10/auth.json")]
        for n, path in enumerate(outside + unfollowed):
            self.mirror.add(path, text(70 + n, 1_000))
        code, out, err = self.cli("--json")
        report = json.loads(out)
        self.assertEqual((code, report["outside_roots"], report["not_followed"]), (0, len(outside), len(unfollowed)), err)
        self.assertEqual(self.store_files(), {})
        self.assertEqual(self.ledger(), [])

    def test_a_plan_counts_what_a_run_would_do_and_writes_nothing(self):
        held = text(80, 10_000)
        path = self.put("proj-a/" + U1 + ".jsonl", held)
        self.capture()
        self.mirror.add(path, held)
        self.mirror.add(self.source("proj-b/" + U2 + ".jsonl"), text(81, 7_000))
        self.mirror.add(os.path.join(self.tmp, "elsewhere", "x.jsonl"), text(82, 100))
        missing = self.mirror.add(self.source("proj-c/" + U2 + ".jsonl"), text(83, 100))
        os.unlink(self.mirror.path(self.mirror.read(missing)["blob_relative_path"]))
        before = (self.store_files(), self.rows(), sorted(os.listdir(self.store)))
        code, out, _err = self.cli("--plan", "--json")
        report = json.loads(out)
        self.assertEqual(code, 1)
        self.assertEqual({k: report.get(k) for k in ("key_new", "key_new_bytes", "key_in_archive", "key_in_archive_bytes",
                                                     "outside_roots", "refused")},
                         {"key_new": 1, "key_new_bytes": 7_000, "key_in_archive": 1, "key_in_archive_bytes": 10_000,
                          "outside_roots": 1, "refused": 1})
        self.assertEqual((self.store_files(), self.rows(), sorted(os.listdir(self.store))), before)

    def test_a_plan_of_a_store_that_does_not_exist_creates_nothing(self):
        self.mirror.add(self.source("proj-b/" + U2 + ".jsonl"), text(84, 7_000))
        code, out, _err = self.cli("--plan", "--json")
        self.assertEqual((code, json.loads(out)["key_new"]), (0, 1))
        self.assertFalse(os.path.exists(self.store))


# ---- runs that stop and start -------------------------------------------------------

class RunTests(Case):
    def fill(self, count=4):
        self.data = [text(90 + n, 6_000 + n) for n in range(count)]
        self.keys = ["%04d%s.jsonl" % (n, U1[4:]) for n in range(count)]
        return [self.mirror.add(self.source("p/" + key), data) for key, data in zip(self.keys, self.data)]

    def test_a_second_run_settles_nothing_again_and_recheck_compares_again(self):
        self.fill()
        self.assertEqual(self.run_import()["stored"], 4)
        files, rows = self.store_files(), self.rows()
        report = self.run_import()
        self.assertEqual((report["settled_before"], report.get("held", 0), report.get("stored", 0)), (4, 0, 0))
        report = self.run_import(recheck=True)
        self.assertEqual((report.get("settled_before", 0), report["held"]), (0, 4))
        self.assertEqual((self.store_files(), self.rows()), (files, rows))

    def test_budgets_end_a_run_between_files_and_the_next_run_goes_on(self):
        self.fill()
        code, out, _err = self.cli("--json", "--limit", "1")
        self.assertEqual((code, json.loads(out)["stored"], json.loads(out)["deferred"]), (0, 1, 3))
        code, out, _err = self.cli("--json", "--max-bytes", "1")
        self.assertEqual((json.loads(out)["stored"], json.loads(out)["deferred"]), (1, 2))
        code, out, _err = self.cli("--json")
        self.assertEqual((code, json.loads(out)["stored"], json.loads(out)["settled_before"]), (0, 2, 2))
        for key, data in zip(self.keys, self.data):
            self.assertEqual(self.stored(key), data)

    def test_a_ledger_line_cut_by_a_kill_is_not_a_row_and_does_not_swallow_the_next(self):
        names = self.fill(2)
        self.run_import()
        path = os.path.join(self.store, "imports", "cass-mirror.jsonl")
        with open(path, "rb") as fh:
            lines = fh.read().splitlines(keepends=True)
        self.assertEqual(len(lines), 4)                 # begun and stored, for each of two keys
        with open(path, "wb") as fh:
            fh.write(b"".join(lines[:3]) + lines[3][:25])
        report = self.run_import()
        self.assertEqual((report["settled_before"], report["held"]), (1, 1))
        rows = []
        with open(path, "rb") as fh:
            for line in fh:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
        self.assertEqual([(row["manifest"], row["outcome"]) for row in rows if row["outcome"] != "begun"],
                         [(names[0], "stored"), (names[1], "held")])
        self.assertEqual(self.run_import()["settled_before"], 2)

    def test_a_last_ledger_line_that_is_whole_but_for_its_newline_is_a_row(self):
        self.fill(2)
        self.run_import()
        path = os.path.join(self.store, "imports", "cass-mirror.jsonl")
        with open(path, "rb+") as fh:
            fh.truncate(os.path.getsize(path) - 1)
        report = self.run_import()
        self.assertEqual((report["settled_before"], report.get("held", 0)), (2, 0))

    def test_the_time_budget_ends_a_run_between_files(self):
        self.fill()
        now = [1_800_000_000.0]

        def clock():
            now[0] += 10              # every look at the clock is ten seconds later
            return now[0]
        report = self.run_import(max_seconds=45, clock=clock)
        self.assertEqual(report["stored"] + report["deferred"], 4)
        self.assertGreater(report["deferred"], 0)
        self.assertGreater(report["stored"], 0)
        self.assertEqual(self.run_import()["stored"], report["deferred"])

    def test_a_second_import_on_the_same_store_does_nothing(self):
        self.fill(1)
        os.makedirs(os.path.join(self.store, "imports"))
        held = os.open(os.path.join(self.store, "imports", "run.lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, held)
        fcntl.flock(held, fcntl.LOCK_EX)
        code, out, err = self.cli("--json")
        self.assertEqual((code, json.loads(out).get("busy")), (1, 1))
        self.assertIn("another import is running", err)
        self.assertEqual(self.store_files(), {})

    def test_new_keys_only_leaves_a_key_the_archive_had_and_takes_every_capture_of_one_it_did_not(self):
        held = text(100, 30_000)
        path = self.put("proj-a/" + U1 + ".jsonl", held[:10_000])
        self.capture()
        self.mirror.add(path, held)
        grown = text(101, 45_000)
        new = self.source("proj-b/" + U2 + ".jsonl")
        self.mirror.add(new, grown[:15_000], captured=1000)
        self.mirror.add(new, grown[:30_000], captured=2000)
        self.mirror.add(new, grown, captured=3000)
        # The first run is cut after one file: the key it made is still the import's own in the next.
        report = self.run_import(new_keys_only=True, limit=2)
        self.assertEqual((report["key_in_archive_left_for_later"], report["stored"]), (1, 1))
        report = self.run_import(new_keys_only=True)
        self.assertEqual((report["key_in_archive_left_for_later"], report["extended"]), (1, 2))
        self.assertEqual(self.stored(U2 + ".jsonl"), grown)
        self.assertEqual(self.stored(U1 + ".jsonl"), held[:10_000])
        report = self.run_import()
        self.assertEqual(report["extended"], 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), held)

    def test_a_named_manifest_that_is_not_in_the_mirror_fails_the_run(self):
        names = self.fill(2)
        listing = os.path.join(self.tmp, "names.txt")
        with open(listing, "w", encoding="utf-8") as fh:
            fh.write(names[1] + "\n\ndoctor-raw-mirror-manifest-id-v1-absent.json\n")
        code, out, err = self.cli("--json", "--names", listing)
        report = json.loads(out)
        self.assertEqual((code, report["manifests"], report["stored"], report["names_not_found"]), (1, 1, 1, 1), err)
        self.assertEqual(sorted(self.store_files()), [os.path.join("claude", self.keys[1][:2], self.keys[1] + ".zst")])
        self.assertEqual(self.cli("--names", os.path.join(self.tmp, "no-such-file"))[0], 2)

    def test_below_the_free_space_floor_nothing_is_stored_and_the_run_says_so(self):
        self.fill(3)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = I.main(["--store", self.store, "--root", "claude=%s:1" % self.claude, "mirror", "--mirror",
                           self.mirror.root, "--capture-every", "0", "--json", "--min-free-bytes", str(1 << 60)])
        report = json.loads(out.getvalue())
        self.assertEqual((code, report["low_disk"], report["deferred"], report.get("stored", 0)), (1, 1, 3, 0))
        self.assertIn("free space is below", err.getvalue())
        self.assertEqual(self.store_files(), {})
        self.assertEqual(self.ledger(), [])

    FLOOR = 1 << 30

    def test_a_file_that_would_take_the_disk_under_the_floor_ends_the_run_before_it_is_written(self):
        self.fill(3)
        size = len(self.data[1])
        # Room for the first file and its like; once one is stored, one byte too little for the next.
        report = self.run_import(min_free=self.FLOOR, free=lambda folder: self.FLOOR + size - bool(self.store_files()))
        self.assertEqual((report["stored"], report["low_disk"], report["deferred"]), (1, 1, 2))
        self.assertIn("free space is below", self.stderr)
        self.assertEqual(sorted(self.store_files()), [os.path.join("claude", self.keys[0][:2], self.keys[0] + ".zst")])
        self.assertEqual(([row["key"] for row in self.ledger()], [row["key"] for row in self.ledger("begun")]),
                         ([self.keys[0]], [self.keys[0]]))            # the key that did not fit was never begun
        self.assertEqual(self.run_import()["stored"], 2)

    def test_the_copy_of_a_chunked_transcript_has_to_fit_before_a_chunk_is_read(self):
        data = text(95, 40_000)
        self.mirror.add(self.source("p/" + U1 + ".jsonl"), data, chunk=8_192)
        scratch = os.path.join(self.tmp, "scratch")
        tight = {self.store: self.FLOOR + len(data) * 2, scratch: self.FLOOR + len(data) - 1}
        report = self.run_import(min_free=self.FLOOR, scratch=scratch, free=tight.__getitem__)
        self.assertEqual((report["low_disk"], report.get("stored", 0)), (1, 0))
        self.assertFalse(os.path.exists(scratch))
        self.assertEqual((self.store_files(), self.ledger("begun")), ({}, []))
        tight[scratch] += 1
        self.assertEqual(self.run_import(min_free=self.FLOOR, scratch=scratch, free=tight.__getitem__)["stored"], 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)

    def test_under_the_floor_a_file_the_archive_already_holds_is_still_settled(self):
        self.fill(2)
        self.assertEqual(self.run_import(limit=1)["stored"], 1)
        report = self.run_import(recheck=True, min_free=self.FLOOR, free=lambda folder: self.FLOOR - 1)
        self.assertEqual((report["held"], report["low_disk"], report["deferred"]), (1, 1, 1))

    def test_a_new_store_is_made_for_its_owner_alone(self):
        self.fill(1)
        before = os.umask(0o022)
        self.addCleanup(os.umask, before)
        self.run_import()
        for folder in (self.store, os.path.join(self.store, "imports")):
            self.assertEqual(os.stat(folder).st_mode & 0o777, 0o700, folder)

    def test_growth_that_would_take_the_disk_under_the_floor_is_not_appended(self):
        data = text(96, 30_000)
        path = self.source("p/" + U1 + ".jsonl")
        self.mirror.add(path, data[:10_000], captured=1000)
        self.mirror.add(path, data, captured=2000)
        self.assertEqual(self.run_import(limit=1)["stored"], 1)
        files, rows = self.store_files(), self.rows()
        report = self.run_import(min_free=self.FLOOR, free=lambda folder: self.FLOOR + 20_000 - 1)
        self.assertEqual((report["low_disk"], report.get("extended", 0)), (1, 0))
        self.assertEqual((self.store_files(), self.rows()), (files, rows))
        report = self.run_import(min_free=self.FLOOR, free=lambda folder: self.FLOOR + 20_000)
        self.assertEqual(report["extended"], 1)
        self.assertEqual(self.stored(U1 + ".jsonl"), data)

    def test_a_mirror_without_manifests_is_a_usage_error(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = I.main(["--store", self.store, "mirror", "--mirror", os.path.join(self.tmp, "nowhere")])
        self.assertEqual(code, 2)
        self.assertFalse(os.path.exists(self.store))


# ---- giving way to the capture timer -----------------------------------------------

class GiveWayTests(Case):
    def setUp(self):
        super().setUp()
        self.now = 1_800_000_000.0
        self.sleeps = 0
        self.on_sleep = lambda: None
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), text(110, 5_000))

    def tick(self, seconds):
        self.sleeps += 1
        self.now += seconds
        self.on_sleep()

    def passed(self, started, seconds=4):
        """Record a capture pass in the store's state, as capture() does."""
        os.makedirs(self.store, exist_ok=True)
        archive = A.Archive(self.store, self.roots)
        try:
            archive.db.execute("INSERT OR REPLACE INTO meta(k, v) VALUES ('last_pass', ?)",
                               (json.dumps({"at": int(started + seconds), "seconds": seconds}),))
        finally:
            archive.close()

    def go(self, capture_every=600):
        report = self.run_import(capture_every=capture_every, clock=lambda: self.now, sleep=self.tick)
        self.assertEqual(report["stored"], 1)
        return report

    def test_a_store_that_never_had_a_pass_is_not_waited_for(self):
        self.go()
        self.assertEqual(self.sleeps, 0)

    def test_between_passes_the_import_does_not_wait(self):
        self.passed(self.now - 300)
        report = self.go()
        self.assertEqual((self.sleeps, report.get("waited_for_capture", 0)), (0, 0))

    def test_when_a_pass_is_due_the_import_waits_with_the_lock_free_until_it_has_run(self):
        self.passed(self.now - 520)             # the next is due in 80 s: inside the lead
        free = []

        def capture_arrives():
            probe = os.open(os.path.join(self.store, "lock"), os.O_WRONLY | os.O_CREAT, 0o600)
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)      # raises when the import holds it
                free.append(True)
            finally:
                os.close(probe)
            if self.sleeps == 100:
                self.passed(self.now - 3)
        self.on_sleep = capture_arrives
        report = self.go()
        self.assertEqual((self.sleeps, report["waited_for_capture"], report.get("capture_waits_timed_out", 0)),
                         (100, 1, 0))
        self.assertEqual(len(free), 100)
        self.assertEqual(self.rows("sources"), [])

    def test_a_pass_that_never_comes_is_waited_for_only_so_long(self):
        self.passed(self.now - 590)
        report = self.go()
        self.assertEqual(self.sleeps, 10 + I.SLOT_GRACE + 1)
        self.assertEqual((report["waited_for_capture"], report["capture_waits_timed_out"]), (1, 1))

    def test_a_store_whose_timer_is_off_is_not_waited_for(self):
        self.passed(self.now - 3 * 86400)
        self.go()
        self.assertEqual(self.sleeps, 0)

    def test_zero_turns_the_waiting_off(self):
        self.passed(self.now - 599)
        self.go(capture_every=0)
        self.assertEqual(self.sleeps, 0)

    def pass_at_sleep(self, count):
        def arrives():
            if self.sleeps == count:
                self.passed(self.now - 3)
        self.on_sleep = arrives

    def test_every_file_gives_way_not_only_the_first(self):
        self.mirror.add(self.source("proj-b/" + U2 + ".jsonl"), text(111, 5_000))
        self.passed(self.now - 300)
        self.pass_at_sleep(40)
        # Once the first file is stored the clock stands 230 s on: the next pass is 70 s off.
        report = self.run_import(capture_every=600, sleep=self.tick,
                                 clock=lambda: self.now + (230 if self.store_files() else 0))
        self.assertEqual((report["stored"], report["waited_for_capture"], self.sleeps), (2, 1, 40))

    def test_a_larger_file_stops_being_started_sooner(self):
        self.assertEqual((I.Importer.lead(0), I.Importer.lead(160 << 20)), (I.SLOT_LEAD, I.SLOT_LEAD + 10))
        self.addCleanup(setattr, I, "IMPORT_RATE", I.IMPORT_RATE)
        I.IMPORT_RATE = 100                     # the 5,000 byte file now counts for 50 s under the lock
        self.passed(self.now - 470)             # the next pass is 130 s off: outside 90 s, inside 140 s
        self.pass_at_sleep(60)
        report = self.go()
        self.assertEqual((report["waited_for_capture"], self.sleeps), (1, 60))

    def test_a_file_too_large_to_fit_between_two_passes_starts_right_after_one(self):
        self.addCleanup(setattr, I, "IMPORT_RATE", I.IMPORT_RATE)
        I.IMPORT_RATE = 1                       # 5,000 s under the lock: no gap between passes is long enough
        self.passed(self.now - 300)
        self.pass_at_sleep(50)
        report = self.go()
        self.assertEqual((self.sleeps, report["waited_for_capture"], report.get("capture_waits_timed_out", 0)),
                         (50, 1, 0))

    def test_a_pass_record_that_is_not_a_time_counts_as_no_pass(self):
        for value in ('{"at": NaN}', '{"at": 1e999, "seconds": 4}', '{"at": %s}' % ("9" * 400),
                      '{"at": 1800000000, "seconds": -1e999}', '{"at": "soon"}', "[]"):
            self.passed(self.now - 599)
            con = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
            con.execute("UPDATE meta SET v = ? WHERE k = 'last_pass'", (value,))
            con.commit()
            con.close()
            importer = self.importer(capture_every=600, clock=lambda: self.now, sleep=self.tick)
            importer.archive = A.Archive(self.store, self.roots, readonly=True)
            self.addCleanup(importer.archive.close)
            self.assertIsNone(importer.last_pass(), value)
            importer.give_way()
            self.assertEqual(self.sleeps, 0, value)

    def test_a_pass_that_came_due_while_the_lock_was_held_elsewhere_is_given_way_to(self):
        self.passed(self.now - 300)
        held = os.open(os.path.join(self.store, "lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, held)
        fcntl.flock(held, fcntl.LOCK_EX)
        importer = self.importer(capture_every=600, clock=lambda: self.now, sleep=self.tick)
        importer.blocked_after = 0.2
        done = {}

        def work():
            with contextlib.redirect_stderr(io.StringIO()):
                done.update(report=importer.run())
        worker = threading.Thread(target=work)
        worker.start()
        worker.join(0.6)
        self.assertTrue(worker.is_alive())
        self.assertEqual(self.sleeps, 0)        # not due when it asked for the lock
        self.now += 230                         # the lock holder took its time: the pass is now 70 s off
        self.pass_at_sleep(30)
        fcntl.flock(held, fcntl.LOCK_UN)
        worker.join(30)
        self.assertFalse(worker.is_alive())
        self.assertEqual((done["report"]["stored"], done["report"]["waited_for_capture"], self.sleeps), (1, 1, 30))


# ---- search ---------------------------------------------------------------------------

class SearchTests(Case):
    def test_an_imported_transcript_is_found_by_a_search_of_the_archive(self):
        gone = said("where did the quillfeather migration notes go") + said("they are in the ops folder")
        self.mirror.add(self.source("proj-a/" + U1 + ".jsonl"), gone, chunk=64)
        self.mirror.add(self.source("proj-a/" + U1 + "/subagents/agent-a1.meta.json"), b'{"agentType":"x"}')
        self.assertEqual(self.run_import()["stored"], 2)
        index = os.path.join(self.tmp, "index")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = S.main(["--store", self.store, "--index", index, "--backend", str(BACKEND), "index", "--json"])
        self.assertEqual(code, 0, err.getvalue())
        self.assertEqual((json.loads(out.getvalue())["indexed"], json.loads(out.getvalue())["docs"]), (1, 2))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = S.main(["--store", self.store, "--index", index, "--backend", str(BACKEND),
                           "search", "--json", "quillfeather"])
        self.assertEqual(code, 0, err.getvalue())
        hit, = json.loads(out.getvalue())["hits"]
        self.assertEqual((hit["session"], hit["agent"], hit["stream"], hit["line"], hit["workspace"]),
                         (U1, "claude", U1 + ".jsonl", 1, "/work/alpha"))


if __name__ == "__main__":
    unittest.main()
