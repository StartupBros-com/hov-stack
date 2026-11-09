#!/usr/bin/env python3
"""cass-vec must read the cass archive without touching its -wal/-shm.

On 2026-09-29 one stock SQLite read-only open of cass's agent_search.db rewrote
the -shm that cass (fsqlite 0.4.4) had written, and every cass read-only open
then failed ("strict readonly open failed") until a stock
wal_checkpoint(TRUNCATE). cass-vec's `status` and `build` open that same DB, so
its open must leave both sidecars byte-identical and create neither.

That open (immutable=1) takes no locks, so a read overlapping a cass checkpoint
sees a torn file and can return counts no commit ever had. The fingerprint must
then be unknown (None), never a number.

Hermetic: a throwaway WAL-mode DB in a temp dir. numpy is stubbed only so the
script imports on a runner without it; `_corpus_fingerprint` never uses numpy.
"""

from __future__ import annotations

import array
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

CASS_VEC = Path(__file__).resolve().parents[1] / "scripts" / "cass-vec"


def _load_cass_vec(test: unittest.TestCase):
    # Undo both sys.modules entries after the test: CI also runs this file inside
    # a shared `unittest discover` process, where a leftover numpy stub would
    # shadow a later ImportError.
    try:
        import numpy  # noqa: F401
    except ImportError:
        sys.modules["numpy"] = types.ModuleType("numpy")
        test.addCleanup(sys.modules.pop, "numpy", None)
    loader = importlib.machinery.SourceFileLoader("cass_vec", str(CASS_VEC))
    spec = importlib.util.spec_from_loader("cass_vec", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["cass_vec"] = (
        module  # @dataclass resolves its module through sys.modules
    )
    test.addCleanup(sys.modules.pop, "cass_vec", None)
    loader.exec_module(module)
    return module


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _make_archive(root: Path) -> Path:
    """A WAL-mode DB whose -wal is empty and whose -shm this SQLite did not write.

    A zero-filled -shm stands in for cass's fsqlite one: a stock reader does not
    recognise either, so it rebuilds it. That rebuild is the damage.
    """
    # A space and a '#' pin the URI quoting: `file:{path}?...` cuts the path at '#'.
    root = root / "cass data #1"
    root.mkdir()
    db = root / "agent_search.db"
    conn = sqlite3.connect(db)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE conversations(id INTEGER PRIMARY KEY)")
    conn.execute("CREATE TABLE messages(id INTEGER PRIMARY KEY)")
    conn.executemany("INSERT INTO conversations VALUES (?)", [(i,) for i in range(5)])
    conn.executemany("INSERT INTO messages VALUES (?)", [(i,) for i in range(9)])
    conn.commit()
    conn.close()  # last connection: checkpoints and removes -wal/-shm
    (root / "agent_search.db-wal").write_bytes(b"")
    (root / "agent_search.db-shm").write_bytes(bytes(65536))
    return db


class CorpusFingerprintReadOnlyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.cass_vec = _load_cass_vec(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)  # registered first, so it runs last
        self.root = Path(self._tmp.name)

    def _hold_wal_frames(self, db: Path) -> None:
        """Commit rows cass-style: into the WAL, left there by an open writer."""
        writer = sqlite3.connect(db)
        self.addCleanup(writer.close)
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.executemany(
            "INSERT INTO conversations VALUES (?)", [(i,) for i in range(5, 8)]
        )
        writer.commit()
        wal = db.with_name("agent_search.db-wal")
        self.assertGreater(wal.stat().st_size, 32, "the WAL holds no frames")

    def _checkpoint_during_read(self, db: Path):
        """Move the DB's mtime right after the open, as a checkpoint's page writes do."""
        real_connect = sqlite3.connect

        def connect_then_checkpoint(*args, **kwargs):
            conn = real_connect(*args, **kwargs)
            st = db.stat()
            os.utime(db, ns=(st.st_atime_ns, st.st_mtime_ns + 1))
            return conn

        return mock.patch.object(sqlite3, "connect", connect_then_checkpoint)

    def _status(self, state: Path, db: Path) -> dict:
        out = io.StringIO()
        args = types.SimpleNamespace(state=str(state), corpus=str(db))
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.cass_vec.cmd_status(args), 0)
        return json.loads(out.getvalue())

    def test_precondition_a_plain_readonly_open_rewrites_the_shm(self) -> None:
        # Without this, the next test could pass on a fixture no reader disturbs.
        db = _make_archive(self.root)
        shm = db.with_name("agent_search.db-shm")
        before = _sha(shm)
        conn = sqlite3.connect(f"file:{db}?mode=ro".replace("#", "%23"), uri=True)
        conn.execute("SELECT COUNT(*) FROM conversations").fetchone()
        conn.close()
        self.assertNotEqual(_sha(shm), before, "fixture cannot detect a -shm rewrite")

    def test_fingerprint_leaves_wal_and_shm_untouched(self) -> None:
        db = _make_archive(self.root)
        shm, wal = (
            db.with_name("agent_search.db-shm"),
            db.with_name("agent_search.db-wal"),
        )
        before = (_sha(shm), shm.stat().st_size, _sha(wal), wal.stat().st_size)
        self.assertEqual(self.cass_vec._corpus_fingerprint(db), "conv:5:msg:9")
        after = (_sha(shm), shm.stat().st_size, _sha(wal), wal.stat().st_size)
        self.assertEqual(after, before, "cass-vec rewrote cass's -wal/-shm")

    def test_fingerprint_creates_no_sidecars(self) -> None:
        db = _make_archive(self.root)
        db.with_name("agent_search.db-shm").unlink()
        db.with_name("agent_search.db-wal").unlink()
        self.assertEqual(self.cass_vec._corpus_fingerprint(db), "conv:5:msg:9")
        self.assertEqual(
            sorted(p.name for p in db.parent.iterdir()), ["agent_search.db"]
        )

    def test_fingerprint_accepts_a_relative_path(self) -> None:
        # `--corpus` is free-form; Path.as_uri() refuses a relative path.
        db = _make_archive(self.root)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(db.parent)
        self.assertEqual(
            self.cass_vec._corpus_fingerprint(Path(db.name)), "conv:5:msg:9"
        )

    def test_fingerprint_is_unknown_while_the_wal_holds_frames(self) -> None:
        # The main file alone is not the corpus then (and mid-checkpoint it is torn).
        db = _make_archive(self.root)
        self._hold_wal_frames(db)
        shm, wal = (
            db.with_name("agent_search.db-shm"),
            db.with_name("agent_search.db-wal"),
        )
        before = (_sha(shm), _sha(wal))
        self.assertIsNone(self.cass_vec._corpus_fingerprint(db))
        self.assertEqual((_sha(shm), _sha(wal)), before)

    def test_fingerprint_is_unknown_when_the_file_changes_during_the_read(
        self,
    ) -> None:
        db = _make_archive(self.root)
        with self._checkpoint_during_read(db):
            self.assertIsNone(self.cass_vec._corpus_fingerprint(db))

    def test_a_read_error_on_an_unchanged_file_is_raised(self) -> None:
        db = self.root / "agent_search.db"
        db.write_bytes(b"not a database " * 100)
        with self.assertRaises(sqlite3.DatabaseError):
            self.cass_vec._corpus_fingerprint(db)

    def test_a_read_error_while_the_file_changes_is_unknown(self) -> None:
        db = self.root / "agent_search.db"
        db.write_bytes(b"not a database " * 100)
        with self._checkpoint_during_read(db):
            self.assertIsNone(self.cass_vec._corpus_fingerprint(db))

    def test_status_reports_staleness_unknown_while_cass_writes(self) -> None:
        db = _make_archive(self.root)
        state = self.root / "state"
        state.mkdir()
        (state / self.cass_vec.VECTORS).write_bytes(b"")
        index = (
            types.SimpleNamespace(shape=(1, 2)),
            [],
            {"model": "m", "corpus_fingerprint": "conv:5:msg:9"},
        )
        with mock.patch.object(self.cass_vec, "_read_index", return_value=index):
            quiet = self._status(state, db)
            self._hold_wal_frames(db)
            busy = self._status(state, db)
        self.assertEqual(
            (quiet["corpus_fingerprint_now"], quiet["corpus_stale"]),
            ("conv:5:msg:9", False),
        )
        self.assertEqual(
            (busy["corpus_fingerprint_now"], busy["corpus_stale"]), (None, None)
        )


class _Matrix:
    """The slice of an ndarray the build loop uses: shape and tofile."""

    def __init__(self, rows) -> None:
        self.rows = [list(row) for row in rows]
        self.shape = (len(self.rows), len(self.rows[0]))

    def tofile(self, handle) -> None:
        array.array("f", [x for row in self.rows for x in row]).tofile(handle)


class BuildManifestFingerprintTests(unittest.TestCase):
    """The manifest's fingerprint must name the corpus the build loaded.

    A full build embeds for hours (2026-11-06/07: 15 h 59 min for 73,899 docs)
    while the nightly cass index keeps committing. A fingerprint taken when the
    manifest is written names a corpus the build never loaded, so `status`
    reports corpus_stale false and the conversations committed mid-build are
    never embedded.
    """

    def setUp(self) -> None:
        self.cass_vec = _load_cass_vec(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def test_manifest_fingerprint_is_the_corpus_at_load(self) -> None:
        db = _make_archive(self.root)
        state = self.root / "state"
        exporter = self.root / "cass_sessions_export.py"
        exporter.write_text("# stand-in exporter\n")
        rows = [
            self.cass_vec.Row(
                doc_id=f"doc-{i}",
                conversation_id=str(i),
                title="t",
                workspace_path="/w",
                source_path="/s",
                text="x",
            )
            for i in range(2)
        ]

        def embed_while_cass_commits(texts, **_kwargs):
            # The nightly index commits new conversations during the embed.
            # Closing the last connection checkpoints, so the WAL is empty again
            # and the end-of-build fingerprint is a known, different count.
            conn = sqlite3.connect(db)
            conn.executemany(
                "INSERT INTO conversations VALUES (?)", [(i,) for i in range(5, 8)]
            )
            conn.commit()
            conn.close()
            return [[1.0, 0.0] for _ in texts]

        args = types.SimpleNamespace(
            state=str(state),
            corpus=str(db),
            workspace_prefix=["/"],
            limit=None,
            rebuild=False,
            batch=16,
            endpoint="http://embedder.invalid/v1/embeddings",
            model="m",
        )
        fake_np = types.SimpleNamespace(
            float32="float32", asarray=lambda vectors, dtype=None: _Matrix(vectors)
        )
        with (
            mock.patch.object(self.cass_vec, "_load_docs", return_value=rows),
            mock.patch.object(
                self.cass_vec, "_embed", side_effect=embed_while_cass_commits
            ),
            mock.patch.object(
                self.cass_vec, "_normalize", side_effect=lambda matrix: matrix
            ),
            mock.patch.object(self.cass_vec, "np", fake_np),
            mock.patch.object(self.cass_vec, "EXPORTER", exporter),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(self.cass_vec.cmd_build(args), 0)

        manifest = json.loads((state / self.cass_vec.MANIFEST).read_text())
        now = self.cass_vec._corpus_fingerprint(db)
        self.assertEqual(now, "conv:8:msg:9", "fixture: cass committed nothing")
        self.assertEqual(manifest["count"], 2)
        self.assertEqual(
            manifest["corpus_fingerprint"],
            "conv:5:msg:9",
            "the manifest names the corpus at build end, not the one it loaded",
        )


if __name__ == "__main__":
    unittest.main()
