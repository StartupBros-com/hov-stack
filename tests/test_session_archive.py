#!/usr/bin/env python3
"""Tests for session-archive.py.

The failure that matters for an archive is a byte that was in a transcript and
is not in the store, or a stored version that no transcript ever held. Every
test here runs the real zstd binary against real files; nothing about the store
is mocked. Stored bytes are read back with a plain `zstd -dc`, not with the
tool's own reader.
"""

import contextlib
import errno
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import random
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "session-archive.py"

_spec = importlib.util.spec_from_file_location("session_archive_module", SCRIPT)
A = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = A
_spec.loader.exec_module(A)

ZSTD = shutil.which("zstd")


def setUpModule():
    # A missing compressor must fail this suite, never skip it: the tool cannot
    # save one byte without zstd.
    if ZSTD is None:
        raise RuntimeError("zstd is not installed; session-archive cannot be tested or run without it")


class Crash(BaseException):
    """Stands in for a kill: nothing in the tool catches it."""


def text(seed, size):
    """`size` bytes of line-shaped pseudo-random text."""
    rng = random.Random(seed)
    out = []
    total = 0
    while total < size:
        line = ('{"n":%d,"v":"%032x"}\n' % (rng.randrange(10 ** 9), rng.getrandbits(128))).encode()
        out.append(line)
        total += len(line)
    return b"".join(out)[:size]


def noise(seed, size):
    return random.Random(seed).randbytes(size)


def zstd_decode(path):
    return subprocess.run([ZSTD, "-dc", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def zstd_frame(data, *flags):
    return subprocess.run([ZSTD, "-q", "-c", *flags], input=data, stdout=subprocess.PIPE, check=True).stdout


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="session-archive-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.claude = os.path.join(self.tmp, "claude-projects")
        self.codex = os.path.join(self.tmp, "codex-sessions")
        self.store = os.path.join(self.tmp, "store")
        os.makedirs(self.claude)
        os.makedirs(self.codex)
        self.roots = [A.Root("claude", self.claude, 1), A.Root("codex", self.codex, 0)]
        self.clock = 1_700_000_000_000_000_000

    # ---- sources -------------------------------------------------------------

    def stamp(self, path):
        """Give the file a new, strictly later mtime: two writes inside one clock tick must still differ."""
        self.clock += 1_000_000_000
        os.utime(path, ns=(self.clock, self.clock))

    def put(self, rel, data, root=None, mode="wb"):
        path = os.path.join(root or self.claude, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as fh:
            fh.write(data)
        self.stamp(path)
        return path

    def add(self, rel, data, root=None):
        return self.put(rel, data, root, "ab")

    def edit(self, rel, data, root=None):
        """Overwrite bytes in place from offset 0, keeping the inode and the length beyond `data`."""
        return self.put(rel, data, root, "r+b")

    # ---- store ---------------------------------------------------------------

    def archive(self, **kwargs):
        return A.Archive(self.store, self.roots, **kwargs)

    def run_pass(self, **kwargs):
        archive = self.archive(**kwargs)
        try:
            return archive.capture()
        finally:
            archive.close()

    def store_path(self, agent, key, version=1):
        suffix = ".zst" if version == 1 else ".v%d.zst" % version
        return os.path.join(self.store, "data", agent, key[:2], key + suffix)

    def stored(self, agent, key, version=1):
        return zstd_decode(self.store_path(agent, key, version))

    def store_files(self):
        """Every file under the store's data folder, with its bytes."""
        found = {}
        for directory, _, names in os.walk(os.path.join(self.store, "data")):
            for name in names:
                path = os.path.join(directory, name)
                found[os.path.relpath(path, self.store)] = Path(path).read_bytes()
        return found

    def versions_on_disk(self, agent, key):
        """Decoded content of every version of a key, found by file name alone."""
        out = {}
        version = 1
        while os.path.exists(self.store_path(agent, key, version)):
            if os.path.getsize(self.store_path(agent, key, version)):
                out[version] = self.stored(agent, key, version)
            version += 1
        return out

    def drop_state(self):
        for name in os.listdir(self.store):
            if name.startswith("state.sqlite3"):
                os.unlink(os.path.join(self.store, name))


class CaptureTests(Case):
    def test_first_pass_stores_every_followed_file_exactly(self):
        main = self.put("proj-a/s1.jsonl", text(1, 9000))
        sub = self.put("proj-a/s1/subagents/agent-x.jsonl", text(2, 300))
        rollout = self.put("2026/11/24/rollout-1.jsonl", text(3, 5000), root=self.codex)
        summary = self.run_pass()
        self.assertEqual(summary["appended"], 3)
        self.assertEqual(summary["store_errors"] + summary["source_errors"], 0)
        self.assertEqual(self.stored("claude", "s1.jsonl"), Path(main).read_bytes())
        self.assertEqual(self.stored("claude", "s1/subagents/agent-x.jsonl"), Path(sub).read_bytes())
        self.assertEqual(self.stored("codex", "2026/11/24/rollout-1.jsonl"), Path(rollout).read_bytes())

    def test_growth_is_appended_and_only_the_new_bytes_are_read(self):
        first, more = text(1, 9000), text(2, 2500)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        frame_one = Path(self.store_path("claude", "s1.jsonl")).read_bytes()
        self.add("proj-a/s1.jsonl", more)
        summary = self.run_pass()
        self.assertEqual(summary["bytes_read"], len(more))
        self.assertEqual(summary["appended"], 1)
        self.assertEqual(self.stored("claude", "s1.jsonl"), first + more)
        # The first frame is still there, byte for byte: growth never rewrites the store.
        self.assertTrue(Path(self.store_path("claude", "s1.jsonl")).read_bytes().startswith(frame_one))

    def test_unchanged_tree_opens_no_file(self):
        self.put("proj-a/s1.jsonl", text(1, 9000))
        self.put("proj-a/s1/tool-results/out.txt", text(2, 700))
        self.run_pass()
        before = self.store_files()
        archive = self.archive()
        self.addCleanup(archive.close)
        with mock.patch.object(A.os, "open", side_effect=AssertionError("a second pass opened a file")):
            summary = archive.capture()
        self.assertEqual((summary["scanned"], summary["changed"], summary["bytes_read"]), (2, 0, 0))
        self.assertEqual(self.store_files(), before)

    def test_a_version_that_holds_nothing_is_tried_after_the_ones_that_hold_bytes(self):
        data = text(7, 9000)
        self.put("proj-a/s1.jsonl", data)
        self.run_pass()
        empty = self.store_path("claude", "s1.jsonl", 2)
        Path(empty).write_bytes(b"")            # what a first append that failed leaves behind
        self.put("proj-b/s1.jsonl", data)       # the same transcript, met under another path
        summary = self.run_pass()
        self.assertEqual(summary["store_errors"] + summary["source_errors"], 0)
        self.assertEqual(os.path.getsize(empty), 0)
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: data})

    def test_rewritten_transcript_becomes_a_new_version_and_the_old_one_is_untouched(self):
        old, new = text(1, 9000), text(2, 12000)
        self.put("proj-a/s1.jsonl", old)
        self.run_pass()
        v1_bytes = Path(self.store_path("claude", "s1.jsonl")).read_bytes()
        self.put("proj-a/s1.jsonl", new)
        summary = self.run_pass()
        self.assertEqual(summary["versions"], 1)
        self.assertEqual(Path(self.store_path("claude", "s1.jsonl")).read_bytes(), v1_bytes)
        self.assertEqual(self.stored("claude", "s1.jsonl"), old)
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), new)

    def test_same_size_edit_that_keeps_the_last_4k_is_caught_for_a_state_file(self):
        old = text(1, 9000)
        new = b"X" + old[1:]
        self.assertEqual(old[-A.TAIL:], new[-A.TAIL:])
        key = "s1/workflows/wf_1.json"
        self.put("proj-a/" + key, old)
        self.run_pass()
        self.edit("proj-a/" + key, b"X")
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", key), {1: old, 2: new})

    def test_state_file_that_grew_with_an_edited_start_is_a_new_version(self):
        old = text(1, 9000)
        new = b"X" + old[1:] + text(2, 500)
        key = "s1/workflows/wf_1.json"
        self.put("proj-a/" + key, old)
        self.run_pass()
        self.put("proj-a/" + key, new)
        self.run_pass()
        # Only a .jsonl is append-only by format; anything else gets the full comparison.
        self.assertEqual(self.versions_on_disk("claude", key), {1: old, 2: new})

    def test_same_size_edit_of_a_transcript_is_caught(self):
        old = text(1, 9000)
        new = b"X" + old[1:]
        self.put("proj-a/s1.jsonl", old)
        self.run_pass()
        self.edit("proj-a/s1.jsonl", b"X")
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: old, 2: new})

    def test_truncation_stores_nothing_new_and_a_different_regrowth_is_a_new_version(self):
        old = text(1, 9000)
        self.put("proj-a/s1.jsonl", old)
        self.run_pass()
        before = self.store_files()
        path = self.put("proj-a/s1.jsonl", old[:4000])
        summary = self.run_pass()
        self.assertEqual((summary["covered"], summary["appended"], summary["versions"]), (1, 0, 0))
        self.assertEqual(self.store_files(), before)
        archive = self.archive()
        self.addCleanup(archive.close)
        stream, size = archive.bound(path)
        self.assertEqual(b"".join(archive.read(stream, size)), old[:4000])
        regrown = old[:4000] + text(2, 7000)
        self.put("proj-a/s1.jsonl", regrown)
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: old, 2: regrown})

    def test_deleting_sources_never_changes_the_store(self):
        self.put("proj-a/s1.jsonl", text(1, 9000))
        self.put("proj-a/s1/subagents/agent-x.jsonl", text(2, 300))
        self.run_pass()
        before = self.store_files()
        shutil.rmtree(os.path.join(self.claude, "proj-a"))
        summary = self.run_pass()
        self.assertEqual((summary["scanned"], summary["store_errors"]), (0, 0))
        self.assertEqual(self.store_files(), before)

    def test_empty_file_is_bound_without_a_store_file_and_captured_once_it_has_bytes(self):
        self.put("proj-a/s1.jsonl", b"")
        summary = self.run_pass()
        self.assertEqual((summary["appended"], summary["store_errors"]), (0, 0))
        self.assertEqual(self.store_files(), {})
        self.add("proj-a/s1.jsonl", text(1, 500))
        self.run_pass()
        self.assertEqual(self.stored("claude", "s1.jsonl"), text(1, 500))


class FollowedFilesTests(Case):
    def test_which_files_are_followed_and_how_they_are_keyed(self):
        for rel in ("proj-a/s1.jsonl", "proj-a/s1/subagents/agent-x.jsonl",
                    "proj-a/s1/subagents/agent-x.meta.json",
                    "proj-a/s1/subagents/workflows/wf_9/agent-y.jsonl",
                    "proj-a/s1/subagents/workflows/wf_9/journal.jsonl",
                    "proj-a/s1/workflows/wf_1.json", "proj-a/s1/tool-results/out.txt",
                    "proj-a/s1/tool-results/page.pdf",
                    # not part of a session's record:
                    "proj-a/cache/s1.json", "proj-a/memory/note.md", "proj-a/s1.jsonl.bak.1",
                    "proj-a/session-s1.html", "proj-a/s1/workflows/wf_1.txt"):
            self.put(rel, b"x")
        self.put("stray.jsonl", b"x")                       # above the project folders
        os.symlink(os.path.join(self.claude, "proj-a/s1.jsonl"), os.path.join(self.claude, "proj-a/link.jsonl"))
        os.symlink(os.path.join(self.claude, "proj-a"), os.path.join(self.claude, "proj-link"))
        self.put("2026/11/24/rollout-1.jsonl", b"x", root=self.codex)
        self.put("2026/11/24/notes.json", b"x", root=self.codex)
        keys = sorted((root.agent, key) for root in self.roots for key, _, _ in A.walk(root))
        self.assertEqual(keys, [
            ("claude", "s1.jsonl"),
            ("claude", "s1/subagents/agent-x.jsonl"),
            ("claude", "s1/subagents/agent-x.meta.json"),
            ("claude", "s1/subagents/workflows/wf_9/agent-y.jsonl"),
            ("claude", "s1/subagents/workflows/wf_9/journal.jsonl"),
            ("claude", "s1/tool-results/out.txt"),
            ("claude", "s1/tool-results/page.pdf"),
            ("claude", "s1/workflows/wf_1.json"),
            ("codex", "2026/11/24/rollout-1.jsonl"),
        ])


class SecondFolderTests(Case):
    """One session's file under more than one project folder (a worktree move, a resume elsewhere)."""

    def test_longer_copy_in_another_folder_extends_the_one_stream(self):
        first, more = text(1, 9000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.put("proj-b/s1.jsonl", first + more)
        summary = self.run_pass()
        self.assertEqual((summary["proved"], summary["versions"], summary["bytes_read"]), (1, 0, len(more)))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})

    def test_copy_that_differs_before_a_matching_tail_is_stored_again(self):
        head, tail = text(1, 3000), text(9, A.TAIL + 500)
        one, two = head + text(2, 2000) + tail, head + text(3, 2000) + tail
        self.assertEqual((len(one), one[-A.TAIL:]), (len(two), two[-A.TAIL:]))
        self.put("proj-a/s1.jsonl", one)
        self.put("proj-b/s1.jsonl", two)
        summary = self.run_pass()
        self.assertEqual(summary["versions"], 1)
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: one, 2: two})

    def test_shorter_copy_of_a_stored_file_adds_nothing(self):
        whole = text(1, 9000)
        self.put("proj-a/s1.jsonl", whole)
        self.run_pass()
        before = self.store_files()
        self.put("proj-b/s1.jsonl", whole[:5000])
        summary = self.run_pass()
        self.assertEqual((summary["covered"], summary["appended"], summary["versions"]), (1, 0, 0))
        self.assertEqual(self.store_files(), before)

    def test_path_whose_stream_another_folder_moved_gets_a_full_comparison(self):
        base, grown = text(1, 5000), text(2, 6000)
        self.put("proj-a/s1.jsonl", base)
        self.put("proj-b/s1.jsonl", base)
        self.run_pass()
        self.add("proj-b/s1.jsonl", grown)
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: base + grown})
        # proj-a now grows differently, but its bytes just before the stream's
        # cursor equal the stream's: a tail check alone would append to it.
        other = b"Y" + grown[1:]
        self.assertEqual((base + other)[-A.TAIL:], (base + grown)[-A.TAIL:])
        diverged = base + other + text(3, 100)
        self.put("proj-a/s1.jsonl", diverged)
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: base + grown, 2: diverged})


class MovedFolderTests(Case):
    """A session's folder renamed to another project folder: same files, same inodes, new paths."""

    def no_full_comparison(self):
        return mock.patch.object(A.Archive, "same_bytes", side_effect=AssertionError("full comparison"))

    def move(self, old="proj-a", new="proj-b"):
        os.rename(os.path.join(self.claude, old), os.path.join(self.claude, new))

    def state_rows(self):
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        try:
            return db.execute("SELECT path, stream, size, ino, dev FROM sources ORDER BY path").fetchall()
        finally:
            db.close()

    def strip_device_column(self):
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"), isolation_level=None)
        try:
            db.execute("DROP INDEX IF EXISTS sources_ino")
            db.execute("DROP INDEX IF EXISTS sources_stream")
            db.execute("ALTER TABLE sources DROP COLUMN dev")
        finally:
            db.close()

    def schema(self):
        db = sqlite3.connect("file:%s?mode=ro" % os.path.join(self.store, "state.sqlite3"), uri=True)
        try:
            return db.execute("SELECT type, name, sql FROM sqlite_master ORDER BY name").fetchall()
        finally:
            db.close()

    def test_moved_growing_jsonl_is_continued_without_a_full_comparison(self):
        first, more = text(1, 20_000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.move()
        self.add("proj-b/s1.jsonl", more)
        with self.no_full_comparison():
            summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"], summary["versions"], summary["bytes_read"]),
                         (1, 0, 0, len(more)))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})
        self.assertEqual(self.stored("claude", "s1.jsonl"), Path(self.claude, "proj-b/s1.jsonl").read_bytes())

    def test_moved_unchanged_files_of_every_kind_are_adopted_without_reading_them(self):
        files = {"s1.jsonl": text(1, 9000), "s1/tool-results/out.txt": text(2, 700),
                 "s1/workflows/w.json": text(3, 500)}
        for rel, data in files.items():
            self.put("proj-a/" + rel, data)
        self.run_pass()
        before = self.store_files()
        self.move()
        with self.no_full_comparison():
            summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"], summary["appended"], summary["bytes_read"]),
                         (3, 0, 0, 0))
        self.assertEqual(self.store_files(), before)
        self.assertEqual(sorted(row[0] for row in self.state_rows() if "proj-b" in row[0]),
                         sorted(os.path.join(self.claude, "proj-b", rel) for rel in files))

    def test_grown_file_that_is_not_jsonl_is_compared_in_full(self):
        first, more = text(1, 9000), text(2, 900)
        self.put("proj-a/s1/workflows/w.json", first)
        self.run_pass()
        self.move()
        self.add("proj-b/s1/workflows/w.json", more)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1/workflows/w.json"), {1: first + more})

    def test_path_with_a_live_hard_link_is_compared_in_full(self):
        first = text(1, 9000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        os.makedirs(os.path.join(self.claude, "proj-b"))
        os.link(os.path.join(self.claude, "proj-a/s1.jsonl"), os.path.join(self.claude, "proj-b/s1.jsonl"))
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))

    def test_another_live_holder_of_the_stream_forces_a_full_comparison(self):
        first = text(1, 9000)
        self.put("proj-a/s1.jsonl", first)
        self.put("proj-b/s1.jsonl", first)
        self.run_pass()
        self.move("proj-b", "proj-c")
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first})

    def forge_reuse(self, rel, path):
        """What an inode reused after a delete looks like: the dead row's identity, now held by `path`."""
        st = os.stat(path)
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        try:
            db.execute("UPDATE sources SET ino=?, dev=? WHERE path=?",
                       (st.st_ino, st.st_dev, os.path.join(self.claude, rel)))
            db.commit()
        finally:
            db.close()

    def test_inode_reused_by_a_different_file_is_not_adopted(self):
        first = text(1, 9000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        name = os.path.relpath(self.store_path("claude", "s1.jsonl"), self.store)
        stored = self.store_files()[name]
        os.unlink(os.path.join(self.claude, "proj-a/s1.jsonl"))
        other = text(7, 9500)
        path = self.put("proj-b/s1.jsonl", other)
        self.forge_reuse("proj-a/s1.jsonl", path)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["versions"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first, 2: other})
        self.assertEqual(self.store_files()[name], stored)

    def test_inode_reused_by_a_different_file_of_the_same_size_and_mtime_is_not_adopted(self):
        first = text(1, 9000)
        old = self.put("proj-a/s1.jsonl", first)
        mtime = os.stat(old).st_mtime_ns
        self.run_pass()
        os.unlink(old)
        other = text(7, 9000)
        path = self.put("proj-b/s1.jsonl", other)
        os.utime(path, ns=(mtime, mtime))
        self.forge_reuse("proj-a/s1.jsonl", path)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["versions"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first, 2: other})

    def test_row_from_another_device_is_not_adopted(self):
        self.put("proj-a/s1.jsonl", text(1, 9000))
        self.run_pass()
        self.move()
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        db.execute("UPDATE sources SET dev=dev+1")
        db.commit()
        db.close()
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))

    def test_moved_then_rewritten_file_is_compared_in_full(self):
        first, rewritten = text(1, 9000), text(5, 9500)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.move()
        self.put("proj-b/s1.jsonl", rewritten)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["versions"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first, 2: rewritten})

    def test_file_moved_under_another_name_is_not_added_to_the_old_name_stream(self):
        first = text(1, 9000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        os.makedirs(os.path.join(self.claude, "proj-b"))
        os.rename(os.path.join(self.claude, "proj-a/s1.jsonl"), os.path.join(self.claude, "proj-b/s2.jsonl"))
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["streams"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s2.jsonl"), {1: first})

    def back_and_forth(self):
        """A file stored under proj-a, moved to proj-b and grown there; the folder is then moved back to proj-a."""
        first, more = text(1, 20_000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.move("proj-a", "proj-b")
        self.add("proj-b/s1.jsonl", more)
        self.assertEqual(self.run_pass()["moved"], 1)
        self.move("proj-b", "proj-a")
        return first + more

    def test_session_that_returns_to_a_folder_it_used_before_is_continued_without_a_full_comparison(self):
        before, more = self.back_and_forth(), text(3, 2500)
        self.add("proj-a/s1.jsonl", more)
        with self.no_full_comparison():
            summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"], summary["bytes_read"]), (1, 0, len(more)))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: before + more})

    def test_session_that_returns_unchanged_is_adopted_without_reading_it(self):
        before = self.back_and_forth()
        with self.no_full_comparison():
            summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"], summary["appended"]), (1, 0, 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: before})

    def test_session_that_returns_rewritten_is_compared_in_full(self):
        before = self.back_and_forth()
        rewritten = text(8, len(before) + 500)
        self.put("proj-a/s1.jsonl", rewritten)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["versions"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: before, 2: rewritten})

    def test_session_that_returns_touched_is_compared_in_full(self):
        self.back_and_forth()
        self.stamp(os.path.join(self.claude, "proj-a/s1.jsonl"))
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))

    def test_file_rewritten_in_place_at_a_known_path_is_compared_in_full(self):
        first, rewritten = text(1, 9000), text(5, 9500)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.put("proj-a/s1.jsonl", rewritten)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["versions"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first, 2: rewritten})

    def test_stale_record_of_the_inode_does_not_outrank_a_newer_one(self):
        first = text(1, 9096)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.move()
        self.assertEqual(self.run_pass()["moved"], 1)
        path = os.path.join(self.claude, "proj-b/s1.jsonl")
        os.truncate(path, 1000)
        self.stamp(path)
        self.assertEqual(self.run_pass()["covered"], 1)
        # Regrown over the old length with a changed middle and the same 4 KiB before the old cursor.
        regrown = first[:1000] + b"Z" * 4000 + first[5000:] + text(9, 1000)
        self.assertEqual(regrown[len(first) - A.TAIL:len(first)], first[-A.TAIL:])
        self.put("proj-b/s1.jsonl", regrown)
        summary = self.run_pass()
        self.assertEqual(summary["moved"], 0)
        self.assertIn(regrown, self.versions_on_disk("claude", "s1.jsonl").values())
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl")[1], first)

    def test_moved_file_touched_without_growing_is_compared_in_full(self):
        self.put("proj-a/s1.jsonl", text(1, 9000))
        self.run_pass()
        self.move()
        self.stamp(os.path.join(self.claude, "proj-b/s1.jsonl"))
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))

    def test_moved_file_cut_short_is_compared_in_full(self):
        first = text(1, 9000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.move()
        self.put("proj-b/s1.jsonl", first[:5000])
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["covered"]), (0, 1))

    def test_stream_another_path_advanced_is_compared_in_full(self):
        base, more = text(1, 9000), text(2, 6000)
        self.put("proj-a/s1.jsonl", base)
        self.run_pass()
        self.put("proj-b/s1.jsonl", base + more)       # another file, another inode, carries the stream on
        self.run_pass()
        os.unlink(os.path.join(self.claude, "proj-b/s1.jsonl"))
        self.move("proj-a", "proj-c")
        # proj-c now grows differently, but the 4 KiB before the stream's cursor still match it.
        other = b"Y" + more[1:] + text(3, 100)
        self.assertEqual((base + other)[len(base + more) - A.TAIL:len(base + more)], (base + more)[-A.TAIL:])
        self.add("proj-c/s1.jsonl", other)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["versions"]), (0, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: base + more, 2: base + other})

    def test_stream_cut_this_pass_is_not_adopted(self):
        self.put("proj-a/s1.jsonl", text(1, 9000))
        self.run_pass()
        self.move()
        archive = self.archive()
        self.addCleanup(archive.close)
        path = os.path.join(self.claude, "proj-b/s1.jsonl")
        fd = os.open(path, os.O_RDONLY)
        self.addCleanup(os.close, fd)
        archive.cut.add(1)
        self.assertIsNone(archive.moved("claude", "s1.jsonl", path, fd, os.fstat(fd)))
        archive.cut.clear()
        self.assertIsNotNone(archive.moved("claude", "s1.jsonl", path, fd, os.fstat(fd)))

    def test_kill_between_the_append_and_the_row_write_duplicates_nothing(self):
        first, more = text(1, 20_000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.move()
        self.add("proj-b/s1.jsonl", more)

        def hook():
            raise Crash()
        archive = self.archive()
        archive.after_store_write = hook
        try:
            with self.assertRaises(Crash):
                archive.capture()
        finally:
            archive.close()
        # The frame is durable but the cursor and the row were not saved: the store is
        # ahead of the old path's row, so the new path is proved in full, not adopted.
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"], summary["appended"]), (0, 1, 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})
        self.assertEqual(self.run_pass()["appended"], 0)
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})

    def test_state_file_from_before_the_device_column_migrates(self):
        first, more, last = text(1, 20_000), text(2, 3000), text(3, 2000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.strip_device_column()
        self.move()
        self.add("proj-b/s1.jsonl", more)
        summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (0, 1))     # a row without a device never qualifies
        self.assertTrue(all(row[4] is not None for row in self.state_rows() if "proj-b" in row[0]))
        self.move("proj-b", "proj-c")
        self.add("proj-c/s1.jsonl", last)
        with self.no_full_comparison():
            summary = self.run_pass()
        self.assertEqual((summary["moved"], summary["proved"]), (1, 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more + last})

    def test_capture_that_finds_the_lock_taken_leaves_an_old_state_file_as_it_was(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.run_pass()
        self.strip_device_column()
        before = self.schema()
        self.assertNotIn("dev", repr(before))
        holder = os.open(os.path.join(self.store, "lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, holder)
        fcntl.flock(holder, fcntl.LOCK_EX)
        env = dict(os.environ, SESSION_ARCHIVE_MIN_FREE_BYTES="0")
        command = [sys.executable, str(SCRIPT), "--store", self.store, "--root", "claude=%s:1" % self.claude,
                   "capture"]
        done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        self.assertIn("another capture holds the lock", done.stderr.decode())
        self.assertEqual(self.schema(), before)
        fcntl.flock(holder, fcntl.LOCK_UN)
        self.assertEqual(subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env).returncode, 0)
        self.assertIn("sources_stream", repr(self.schema()))

    def test_status_reads_a_state_file_without_the_device_column(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.run_pass()
        self.strip_device_column()
        archive = A.Archive(self.store, self.roots, readonly=True)
        try:
            self.assertEqual(archive.status()["sources"], 1)
        finally:
            archive.close()


class RecoveryTests(Case):
    def crash_after(self, count):
        calls = {"n": 0}

        def hook():
            calls["n"] += 1
            if calls["n"] == count:
                raise Crash()
        archive = self.archive()
        archive.after_store_write = hook
        try:
            with self.assertRaises(Crash):
                archive.capture()
        finally:
            archive.close()

    def test_store_file_and_its_folder_are_synced_before_the_cursor_is_saved(self):
        # The one ordering the store's recovery rests on: a cursor never points
        # past bytes that a power cut could still lose.
        self.put("proj-a/s1.jsonl", text(1, 3000))
        path = os.path.realpath(self.store_path("claude", "s1.jsonl"))
        archive = self.archive()
        self.addCleanup(archive.close)
        events = []
        real_fsync, real_save = os.fsync, archive.save

        def fsync(fd):
            events.append(("sync", os.path.realpath("/proc/self/fd/%d" % fd)))
            return real_fsync(fd)

        def save(stream, content_bytes, *rest, **more):
            if content_bytes:
                events.append(("cursor", os.path.realpath(archive.stream_path(stream))))
            return real_save(stream, content_bytes, *rest, **more)

        archive.save = save
        with mock.patch.object(A.os, "fsync", fsync):
            archive.capture()
        cursor = events.index(("cursor", path))
        self.assertLess(events.index(("sync", path)), cursor)
        self.assertLess(events.index(("sync", os.path.dirname(path))), cursor)

    def test_kill_between_the_store_write_and_the_cursor_commit_duplicates_nothing(self):
        grown_old, grown_new, fresh = text(1, 9000), text(2, 4000), text(3, 7000)
        self.put("proj-a/s1.jsonl", grown_old)
        self.run_pass()
        self.add("proj-a/s1.jsonl", grown_new)
        self.put("proj-a/s2.jsonl", fresh)
        self.crash_after(2)                 # both frames are on disk, neither cursor is saved
        after_crash = self.store_files()
        self.assertEqual(self.stored("claude", "s1.jsonl"), grown_old + grown_new)
        self.assertEqual(self.stored("claude", "s2.jsonl"), fresh)
        summary = self.run_pass()
        self.assertEqual((summary["appended"], summary["bytes_stored"], summary["versions"]), (0, 0, 0))
        self.assertEqual(self.store_files(), after_crash)
        self.add("proj-a/s2.jsonl", b'{"later":1}\n')
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s2.jsonl"), {1: fresh + b'{"later":1}\n'})

    def test_lost_state_file_is_rebuilt_from_the_store_without_writing_a_byte(self):
        whole = text(1, 9000)
        self.put("proj-a/s1.jsonl", whole[:5000])       # a shorter copy, older
        self.put("proj-b/s1.jsonl", whole)
        self.put("proj-a/s1/workflows/wf_1.json", text(2, 800))
        self.run_pass()
        self.put("proj-a/s1/workflows/wf_1.json", text(3, 900))
        self.run_pass()
        before = self.store_files()
        self.drop_state()
        summary = self.run_pass()
        self.assertEqual((summary["appended"], summary["bytes_stored"], summary["versions"],
                          summary["store_errors"]), (0, 0, 0, 0))
        self.assertEqual(self.store_files(), before)
        archive = self.archive()
        self.addCleanup(archive.close)
        self.assertEqual(archive.status()["sources"], 3)
        self.assertEqual(archive.verify([], 1 << 30)["different"], 0)

    def test_restored_older_state_file_cannot_shorten_or_duplicate_the_archive(self):
        first, more = text(1, 9000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        saved = os.path.join(self.tmp, "state.old")
        shutil.copy(os.path.join(self.store, "state.sqlite3"), saved)
        self.add("proj-a/s1.jsonl", more)
        self.put("proj-a/s2.jsonl", text(3, 600))
        self.run_pass()
        before = self.store_files()
        self.drop_state()
        shutil.copy(saved, os.path.join(self.store, "state.sqlite3"))
        summary = self.run_pass()
        self.assertEqual((summary["appended"], summary["bytes_stored"]), (0, 0))
        self.assertEqual(self.store_files(), before)
        self.add("proj-a/s1.jsonl", b'{"later":1}\n')
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more + b'{"later":1}\n'})

    def test_partial_trailing_frame_is_moved_aside_and_the_stream_goes_on(self):
        first, more = text(1, 9000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        whole_frames = Path(path).read_bytes()
        partial = zstd_frame(noise(5, 300_000))[:150_000]      # what a kill mid-append leaves
        with open(path, "ab") as fh:
            fh.write(partial)
        self.add("proj-a/s1.jsonl", more)
        summary = self.run_pass()
        self.assertEqual((summary["partial_frames_set_aside"], summary["store_errors"]), (1, 0))
        self.assertEqual(Path(path + ".partial").read_bytes(), partial)
        self.assertTrue(Path(path).read_bytes().startswith(whole_frames))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})

    def test_store_file_that_does_not_decode_is_never_cut(self):
        first, more = text(1, 9000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        bad = bytearray(zstd_frame(noise(5, 50_000)))           # a whole frame whose checksum fails
        bad[len(bad) // 2] ^= 0xFF
        with open(path, "ab") as fh:
            fh.write(bytes(bad))
        damaged = Path(path).read_bytes()
        self.assertEqual(A.frame_scan(path, len(damaged)), len(damaged))
        self.add("proj-a/s1.jsonl", more)
        summary = self.run_pass()
        self.assertEqual((summary["store_errors"], summary["versions"]), (1, 1))
        self.assertEqual(Path(path).read_bytes(), damaged)
        self.assertFalse(os.path.exists(path + ".partial"))
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), first + more)
        self.add("proj-a/s1.jsonl", b'{"later":1}\n')
        summary = self.run_pass()               # the damage is reported once, not on every pass
        self.assertEqual(summary["store_errors"], 0)
        self.assertEqual(Path(path).read_bytes(), damaged)
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), first + more + b'{"later":1}\n')

    def test_damaged_frame_followed_by_a_partial_one_is_left_whole(self):
        first, more = text(1, 9000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        frame = bytearray(Path(path).read_bytes())
        frame[len(frame) // 2] ^= 0xFF                          # the committed frame no longer decodes
        damaged = bytes(frame) + zstd_frame(noise(5, 300_000))[:150_000]
        Path(path).write_bytes(damaged)
        self.assertEqual(A.frame_scan(path, len(damaged)), len(frame))
        self.add("proj-a/s1.jsonl", more)
        summary = self.run_pass()
        # Cutting the partial frame off would leave a file that still does not
        # decode, with a cursor that says it does. Nothing is moved or cut.
        self.assertEqual((summary["store_errors"], summary["versions"], summary["partial_frames_set_aside"]),
                         (1, 1, 0))
        self.assertEqual(Path(path).read_bytes(), damaged)
        self.assertFalse(os.path.exists(path + ".partial"))
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), first + more)

    def test_every_source_recorded_against_a_file_found_damaged_is_stored_again(self):
        whole = text(1, 9000)
        self.put("proj-a/s1.jsonl", whole[:5000])
        self.put("proj-b/s1.jsonl", whole)
        covered = self.put("proj-c/s1.jsonl", whole[:7000])
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        with open(path, "r+b") as fh:                           # same size, no longer zstd
            fh.write(b"\0\0\0\0")
        damaged = Path(path).read_bytes()
        self.add("proj-a/s1.jsonl", whole[5000:6000])           # needs a full comparison, which finds the damage
        summary = self.run_pass()
        self.assertEqual((summary["changed"], summary["store_errors"], summary["versions"]), (1, 1, 1))
        # proj-b and proj-c did not change, but the file their bytes were in is
        # now known not to decode: the next pass stores them in the new version.
        summary = self.run_pass()
        self.assertEqual((summary["changed"], summary["store_errors"], summary["covered"]), (2, 0, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), whole)
        self.assertEqual(Path(path).read_bytes(), damaged)
        archive = self.archive()
        self.addCleanup(archive.close)
        stream, size = archive.bound(covered)
        self.assertEqual((stream.version, stream.broken, size), (2, 0, 7000))
        self.assertEqual(self.run_pass()["changed"], 0)

    def test_deleted_store_file_is_stored_again_though_no_source_changed(self):
        whole = text(1, 9000)
        self.put("proj-a/s1.jsonl", whole[:5000])
        self.put("proj-b/s1.jsonl", whole)
        self.put("proj-a/s2.jsonl", text(2, 700))
        self.run_pass()
        os.unlink(self.store_path("claude", "s1.jsonl"))
        summary = self.run_pass()                   # nothing under the roots was touched
        self.assertEqual((summary["store_errors"], summary["changed"]), (1, 2))     # said out loud, once
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: whole})
        summary = self.run_pass()
        self.assertEqual((summary["store_errors"], summary["changed"]), (0, 0))
        archive = self.archive()
        self.addCleanup(archive.close)
        self.assertEqual(archive.verify([], 1 << 30)["same"], 3)

    def test_store_file_cut_back_to_an_earlier_frame_is_reported_and_completed(self):
        first, more = text(1, 9000), text(2, 3000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        one_frame = os.path.getsize(path)
        self.add("proj-a/s1.jsonl", more)
        self.run_pass()
        os.truncate(path, one_frame)                # an older copy of the store file came back
        summary = self.run_pass()
        self.assertEqual((summary["store_errors"], summary["bytes_read"]), (1, len(more)))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})
        self.assertEqual(self.run_pass()["changed"], 0)

    def test_source_bound_to_a_damaged_store_file_is_stored_again_elsewhere(self):
        whole, more = text(1, 9000), text(2, 3000)
        grown = self.put("proj-a/s1.jsonl", whole)
        short = self.put("proj-b/s1.jsonl", whole[:5000])
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        bad = bytearray(zstd_frame(noise(5, 50_000)))
        bad[len(bad) // 2] ^= 0xFF
        with open(path, "ab") as fh:
            fh.write(bytes(bad))
        damaged = Path(path).read_bytes()
        self.add("proj-a/s1.jsonl", more)
        older = os.stat(short).st_mtime_ns - 1          # the grown file goes first, the short copy waits
        os.utime(grown, ns=(older, older))
        summary = self.run_pass(max_bytes=1)
        self.assertEqual((summary["store_errors"], summary["versions"], summary["deferred"]), (1, 1, 1))
        # The short copy did not change and is still recorded against the damaged
        # file. The next pass moves it to a version that decodes.
        summary = self.run_pass()
        self.assertEqual((summary["changed"], summary["covered"], summary["store_errors"]), (1, 1, 0))
        archive = self.archive()
        self.addCleanup(archive.close)
        stream, size = archive.bound(short)
        self.assertEqual((stream.version, stream.broken, size), (2, 0, 5000))
        self.assertEqual(b"".join(archive.read(stream, size)), whole[:5000])
        self.assertEqual(Path(path).read_bytes(), damaged)
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), whole + more)
        self.assertEqual(self.run_pass()["changed"], 0)

    def all_the_same(self, count):
        archive = self.archive()
        try:
            report = archive.verify([], 1 << 30)
        finally:
            archive.close()
        self.assertEqual((report["same"], report["different"]), (count, 0))

    def test_deleted_store_file_half_restored_by_a_cut_pass_is_finished_by_the_next(self):
        whole = text(1, 9000)
        self.put("proj-a/s1.jsonl", whole[:5000])       # the shorter copy is older, so it is taken first
        self.put("proj-b/s1.jsonl", whole)
        self.run_pass()
        os.unlink(self.store_path("claude", "s1.jsonl"))
        summary = self.run_pass(max_bytes=1)            # the budget ends the pass after one file
        self.assertEqual((summary["appended"], summary["deferred"]), (1, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl"), whole[:5000])
        # Nothing under the roots changed and the store file is as the last pass
        # left it, yet 4,000 bytes of the longer copy are still missing.
        summary = self.run_pass()
        self.assertEqual((summary["changed"], summary["store_errors"]), (1, 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: whole})
        self.all_the_same(2)
        self.assertEqual(self.run_pass()["changed"], 0)

    def test_source_whose_emptied_stream_another_file_took_over_is_stored_again(self):
        mine, other = text(1, 5000), text(2, 7000)
        path = self.put("proj-a/s1.jsonl", mine)
        self.run_pass()
        os.unlink(self.store_path("claude", "s1.jsonl"))
        # A file of the same name and other content turns up in another folder,
        # older than the stored one, so a cut pass takes it first and puts it in
        # the emptied store file. It is at least as long as the stored one was.
        newcomer = self.put("proj-b/s1.jsonl", other)
        older = os.stat(path).st_mtime_ns - 1
        os.utime(newcomer, ns=(older, older))
        summary = self.run_pass(max_bytes=1)
        self.assertEqual((summary["appended"], summary["deferred"]), (1, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl"), other)
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: other, 2: mine})
        archive = self.archive()
        self.addCleanup(archive.close)
        stream, size = archive.bound(path)
        self.assertEqual((stream.version, size), (2, 5000))
        self.assertEqual(b"".join(archive.read(stream, size)), mine)
        self.all_the_same(2)

    def test_binding_longer_than_its_stream_is_never_taken_as_stored(self):
        # The state is a cache and can come back inconsistent: here an older copy
        # of the store file and of its cursor, beside a newer record of the source.
        # A source recorded as 9,000 bytes against a stream that holds 5,000 is
        # not stored, whatever the file sizes say.
        first, more = text(1, 5000), text(2, 4000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        path = self.store_path("claude", "s1.jsonl")
        one_frame = os.path.getsize(path)
        self.add("proj-a/s1.jsonl", more)
        self.run_pass()
        os.truncate(path, one_frame)
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        try:
            db.execute("UPDATE streams SET content_bytes=?, store_bytes=?, tail=?",
                       (len(first), one_frame, A.tail_hash(first)))
            db.commit()
        finally:
            db.close()
        summary = self.run_pass()
        self.assertEqual((summary["changed"], summary["bytes_read"], summary["store_errors"]), (1, len(more), 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})
        self.assertEqual(self.run_pass()["changed"], 0)

    def test_growth_is_not_added_to_another_files_bytes_in_a_stream_that_was_emptied(self):
        # The quick check looks only at the 4 KiB before the cursor. Here the
        # store file was lost, and a file of the same name refills it in the same
        # pass to the very length the grown file was stored at, ending in the same
        # 4 KiB. The growth must not land on the other file's bytes.
        ending = text(9, A.TAIL)
        mine, other, more = text(1, 6000) + ending, text(2, 6000) + ending, text(3, 2500)
        path = self.put("proj-a/s1.jsonl", mine)
        self.run_pass()
        os.unlink(self.store_path("claude", "s1.jsonl"))
        self.add("proj-a/s1.jsonl", more)
        newcomer = self.put("proj-b/s1.jsonl", other)
        older = os.stat(path).st_mtime_ns - 1           # the newcomer is taken first
        os.utime(newcomer, ns=(older, older))
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: other, 2: mine + more})
        self.all_the_same(2)


class FailureTests(Case):
    def fake_zstd(self, body):
        path = os.path.join(self.tmp, "fake-zstd")
        with open(path, "w") as fh:
            fh.write('#!/bin/sh\ncase " $* " in *" -dcq "*) exec "%s" -dcq ;; esac\n%s\n' % (ZSTD, body))
        os.chmod(path, 0o755)
        return path

    def check_failed_compressor(self, body):
        first = text(1, 9000)
        self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        before = self.store_files()
        self.add("proj-a/s1.jsonl", text(2, 3000))
        self.put("proj-a/s2.jsonl", text(3, 700))
        with mock.patch.object(A, "ZSTD", self.fake_zstd(body)):
            summary = self.run_pass()
        # Both files were tried: one failure does not end the pass.
        self.assertEqual((summary["store_errors"], summary["appended"], summary["bytes_stored"]), (2, 0, 0))
        after = {name: data for name, data in self.store_files().items() if data}
        self.assertEqual(after, before)                     # what the failed attempts wrote was taken back
        archive = self.archive()
        try:
            self.assertEqual(archive.status()["content_bytes"], len(first))     # no cursor moved
        finally:
            archive.close()
        summary = self.run_pass()
        self.assertEqual((summary["store_errors"], summary["appended"]), (0, 2))
        self.assertEqual(self.stored("claude", "s1.jsonl"), first + text(2, 3000))
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(3, 700))

    def test_compressor_that_fails_after_writing_leaves_cursors_and_store_as_they_were(self):
        self.check_failed_compressor("printf 'half a frame'; cat >/dev/null; exit 1")

    def test_compressor_that_dies_without_reading_leaves_cursors_and_store_as_they_were(self):
        self.check_failed_compressor("exit 70")

    def test_unreadable_source_is_counted_and_the_rest_of_the_pass_runs(self):
        blocked = self.put("proj-a/s1.jsonl", text(1, 900))
        self.put("proj-a/s2.jsonl", text(2, 900))
        real_open = os.open

        def guarded(path, flags, *rest, **kwargs):
            if path == blocked:
                raise PermissionError(13, "Permission denied", path)
            return real_open(path, flags, *rest, **kwargs)
        with mock.patch.object(A.os, "open", guarded):
            summary = self.run_pass()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 1))
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 900))
        summary = self.run_pass()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl"), text(1, 900))

    def test_failed_repair_of_a_deleted_store_file_is_tried_again(self):
        content = text(1, 9000)
        self.put("proj-a/s1.jsonl", content)
        self.run_pass()
        os.unlink(self.store_path("claude", "s1.jsonl"))
        with mock.patch.object(A, "ZSTD", self.fake_zstd("exit 70")):
            summary = self.run_pass()
        self.assertEqual((summary["appended"], summary["store_errors"]), (0, 2))    # the loss, and the failed repair
        summary = self.run_pass()                       # nothing under the roots changed
        self.assertEqual((summary["changed"], summary["appended"], summary["store_errors"]), (1, 1, 0))
        self.assertEqual(self.stored("claude", "s1.jsonl"), content)

    def pass_with_scandir(self, scandir):
        """One pass with os.scandir replaced; returns (summary, what the pass wrote to stderr)."""
        said = io.StringIO()
        with mock.patch.object(A.os, "scandir", scandir), contextlib.redirect_stderr(said):
            summary = self.run_pass()
        return summary, said.getvalue()

    def test_folder_that_cannot_be_listed_is_counted_and_the_rest_of_the_pass_runs(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.put("proj-b/s2.jsonl", text(2, 900))
        blocked = os.path.join(self.claude, "proj-a")
        real_scandir = os.scandir

        def scandir(path):
            if path == blocked:
                raise OSError(errno.EIO, "Input/output error", path)
            return real_scandir(path)
        summary, said = self.pass_with_scandir(scandir)
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 1))
        self.assertIn(blocked, said)
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 900))
        summary = self.run_pass()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl"), text(1, 900))

    def test_file_whose_metadata_cannot_be_read_is_counted_and_the_rest_of_the_pass_runs(self):
        blocked = self.put("proj-a/s1.jsonl", text(1, 900))
        self.put("proj-a/s2.jsonl", text(2, 900))
        real_scandir = os.scandir

        class Entry:
            def __init__(self, entry):
                self.entry, self.name, self.path = entry, entry.name, entry.path

            def is_dir(self, **how):
                return self.entry.is_dir(**how)

            def is_file(self, **how):
                return self.entry.is_file(**how)

            def stat(self, **how):
                if self.path == blocked:
                    raise OSError(errno.EIO, "Input/output error", self.path)
                return self.entry.stat(**how)

        class Listing:
            def __init__(self, path):
                self.real = real_scandir(path)

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                self.real.close()

            def __iter__(self):
                return self

            def __next__(self):
                return Entry(next(self.real))
        summary, said = self.pass_with_scandir(Listing)
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 1))
        self.assertIn(blocked, said)
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 900))

    def test_folder_that_went_away_and_a_root_that_is_not_there_are_not_errors(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.put("proj-b/s2.jsonl", text(2, 900))
        self.roots.append(A.Root("pi", os.path.join(self.tmp, "never-made"), 1))
        gone = os.path.join(self.claude, "proj-a")
        real_scandir = os.scandir

        def scandir(path):
            if path == gone:                            # removed between its listing and its own read
                raise FileNotFoundError(errno.ENOENT, "No such file or directory", path)
            return real_scandir(path)
        summary, said = self.pass_with_scandir(scandir)
        self.assertEqual((summary["source_errors"], summary["appended"], said), (0, 1, ""))

    def read_hook(self, path, action):
        """Run `action` once, just before the tool reads the file's second megabyte."""
        real_pread = os.pread
        fired = []

        def pread(fd, count, offset):
            if not fired and offset >= A.CHUNK and os.path.samestat(os.fstat(fd), os.stat(path)):
                fired.append(1)
                action()
            return real_pread(fd, count, offset)
        return mock.patch.object(A.os, "pread", pread)

    def test_source_rewritten_while_it_is_read_is_not_stored_as_a_mix(self):
        old, new = text(1, A.CHUNK * 3 // 2), text(2, A.CHUNK * 3 // 2)
        path = self.put("proj-a/s1.jsonl", old)
        with self.read_hook(path, lambda: self.edit("proj-a/s1.jsonl", new)):
            summary = self.run_pass()
        self.assertEqual((summary["skipped"], summary["appended"], summary["bytes_stored"]), (1, 0, 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {})
        self.run_pass()
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: new})

    def test_source_appended_while_it_is_read_is_stored_as_read(self):
        old, more = text(1, A.CHUNK * 3 // 2), text(2, 5000)
        path = self.put("proj-a/s1.jsonl", old)
        with self.read_hook(path, lambda: self.add("proj-a/s1.jsonl", more)):
            summary = self.run_pass()
        self.assertEqual((summary["skipped"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl"), old)
        self.run_pass()
        self.assertEqual(self.stored("claude", "s1.jsonl"), old + more)

    def test_byte_budget_takes_the_oldest_files_first_and_defers_the_rest(self):
        self.put("proj-a/new.jsonl", text(3, 1000))
        self.put("proj-a/old.jsonl", text(1, 1000))
        self.put("proj-a/mid.jsonl", text(2, 1000))
        for age, name in enumerate(("old", "mid", "new")):
            os.utime(os.path.join(self.claude, "proj-a", name + ".jsonl"), ns=(10 ** 18 + age, 10 ** 18 + age))
        summary = self.run_pass(max_bytes=1500)
        self.assertEqual((summary["appended"], summary["deferred"]), (2, 1))
        self.assertEqual(self.stored("claude", "old.jsonl"), text(1, 1000))
        self.assertEqual(self.stored("claude", "mid.jsonl"), text(2, 1000))
        self.assertEqual(self.versions_on_disk("claude", "new.jsonl"), {})
        summary = self.run_pass(max_bytes=1500)
        self.assertEqual((summary["appended"], summary["deferred"]), (1, 0))
        self.assertEqual(self.stored("claude", "new.jsonl"), text(3, 1000))


class TimeBudgetTests(Case):
    def test_pass_takes_no_new_file_once_its_time_is_spent(self):
        for index, name in enumerate(("old", "mid", "new")):
            path = self.put("proj-a/%s.jsonl" % name, text(index, 800))
            os.utime(path, ns=(10 ** 18 + index, 10 ** 18 + index))
        ticks = iter(range(0, 10_000, 10))                      # every look at the clock is 10 s later
        with mock.patch.object(A.time, "monotonic", lambda: next(ticks)):
            summary = self.run_pass(max_seconds=25)
        self.assertEqual((summary["appended"], summary["deferred"], summary["store_errors"]), (2, 1, 0))
        self.assertEqual(self.stored("claude", "old.jsonl"), text(0, 800))
        self.assertEqual(self.versions_on_disk("claude", "new.jsonl"), {})
        summary = self.run_pass()                               # no limit: the rest is taken
        self.assertEqual((summary["appended"], summary["deferred"]), (1, 0))

    def test_walk_that_outlasts_the_budget_does_not_leave_the_pass_storing_nothing(self):
        # Seen on real data: the walk took 20 s against a 1 s budget, and the
        # pass stored nothing, left 68,927 files waiting and exited 0.
        for index, name in enumerate(("old", "mid", "new")):
            path = self.put("proj-a/%s.jsonl" % name, text(index, 800))
            os.utime(path, ns=(10 ** 18 + index, 10 ** 18 + index))
        now = {"t": 0}
        real_walk = A.walk

        def tick():
            now["t"] += 10
            return now["t"]

        def slow_walk(root, *rest):
            now["t"] += 1000                                    # far past the budget
            yield from real_walk(root, *rest)

        with mock.patch.object(A.time, "monotonic", tick), mock.patch.object(A, "walk", slow_walk):
            summary = self.run_pass(max_seconds=25)
        self.assertEqual((summary["appended"], summary["deferred"]), (2, 1))


class Listing:
    """What os.scandir returns, from a list of entries; `broken` fails the listing before its first entry."""

    def __init__(self, items, broken=False):
        self.items = iter(items)
        self.broken = broken

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def __iter__(self):
        return self

    def __next__(self):
        if self.broken:
            raise OSError(errno.EIO, "Input/output error")
        return next(self.items)


class Entry:
    """An os.DirEntry whose stat() fails with EIO when `blocked`."""

    def __init__(self, entry, blocked):
        self.entry, self.blocked = entry, blocked
        self.path, self.name = entry.path, entry.name

    def is_dir(self, **how):
        return self.entry.is_dir(**how)

    def is_file(self, **how):
        return self.entry.is_file(**how)

    def inode(self):
        return self.entry.inode()

    def stat(self, **how):
        if self.blocked:
            raise OSError(errno.EIO, "Input/output error", self.path)
        return self.entry.stat(**how)


class LightPassTests(Case):
    """Light passes find what changed by looking at little; full passes stay the net under them.

    Files dated `old` are cold: a light pass reaches them only through a folder
    whose mtime moved, or through the pending list. `age()` dates every folder
    `old` too, so a folder counts as changed only when something happens in it
    after the pass that listed it.
    """

    def setUp(self):
        super().setUp()
        self.clock = time.time_ns() - 3600 * 10 ** 9        # put() and add() write files dated an hour ago
        self.old = time.time_ns() - 5 * 24 * 3600 * 10 ** 9

    def cold(self, rel, data, root=None):
        path = self.put(rel, data, root)
        os.utime(path, ns=(self.old, self.old))
        return path

    def age(self):
        for top in (self.claude, self.codex):
            for directory, _, _ in os.walk(top):
                os.utime(directory, ns=(self.old, self.old))

    def run_light(self, **kwargs):
        archive = self.archive(**kwargs)
        try:
            return archive.capture(False)
        finally:
            archive.close()

    def run_full(self, **kwargs):
        archive = self.archive(**kwargs)
        try:
            return archive.capture(True)
        finally:
            archive.close()

    def pending(self):
        archive = self.archive()
        try:
            return archive.status()["pending"]
        finally:
            archive.close()

    def state(self, sql, *args):
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"), isolation_level=None)
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()

    def test_growth_of_a_recent_session_is_stored_without_listing_a_folder(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.cold("proj-b/s2.jsonl", text(2, 900))
        self.age()
        self.assertEqual(self.run_full()["full_walks"], 2)
        self.add("proj-a/s1.jsonl", text(3, 400))
        summary = self.run_light()
        self.assertEqual((summary["full_walks"], summary["appended"], summary["folders_read"]), (0, 1, 0))
        self.assertEqual(self.stored("claude", "s1.jsonl"), text(1, 900) + text(3, 400))
        summary = self.run_light()
        self.assertEqual((summary["changed"], summary["appended"], summary["folders_read"]), (0, 0, 0))

    def test_new_session_in_a_cold_project_folder(self):
        self.cold("proj-b/s2.jsonl", text(2, 900))
        self.age()
        self.run_full()
        self.cold("proj-b/s9.jsonl", text(9, 700))          # copied in with its old date kept
        summary = self.run_light()
        self.assertEqual((summary["appended"], summary["folders_read"]), (1, 1))
        self.assertEqual(self.stored("claude", "s9.jsonl"), text(9, 700))

    def test_new_project_folder(self):
        self.cold("proj-b/s2.jsonl", text(2, 900))
        self.age()
        self.run_full()
        self.cold("proj-new/s5.jsonl", text(5, 700))
        self.cold("proj-new/s5/subagents/agent-q.jsonl", text(6, 300))
        summary = self.run_light()
        self.assertEqual(summary["appended"], 2)
        self.assertEqual(self.stored("claude", "s5.jsonl"), text(5, 700))
        self.assertEqual(self.stored("claude", "s5/subagents/agent-q.jsonl"), text(6, 300))

    def test_new_subagent_file_in_a_recent_sessions_folder(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.cold("proj-a/s1/subagents/agent-a.jsonl", text(2, 300))
        self.age()
        self.run_full()
        self.cold("proj-a/s1/subagents/agent-b.jsonl", text(3, 300))
        summary = self.run_light()
        self.assertEqual(summary["appended"], 1)
        self.assertEqual(self.stored("claude", "s1/subagents/agent-b.jsonl"), text(3, 300))

    def test_new_month_folder_under_a_dated_root(self):
        self.put("2026/11/24/rollout-1.jsonl", text(1, 900), root=self.codex)
        self.age()
        self.run_full()
        self.cold("2026/12/01/rollout-2.jsonl", text(2, 500), root=self.codex)
        summary = self.run_light()
        self.assertEqual(summary["appended"], 1)
        self.assertEqual(self.stored("codex", "2026/12/01/rollout-2.jsonl"), text(2, 500))

    def test_file_replaced_under_its_name_is_stored(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        swap = os.path.join(self.tmp, "swap")
        Path(swap).write_bytes(text(7, 600))
        os.utime(swap, ns=(self.old, self.old))
        os.replace(swap, os.path.join(self.claude, "proj-a/s1.jsonl"))
        summary = self.run_light()
        self.assertEqual((summary["appended"], summary["versions"]), (1, 1))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: text(1, 900), 2: text(7, 600)})

    def test_folder_that_changed_just_before_its_listing_is_listed_again(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        folder = os.path.join(self.claude, "proj-a")
        listed = time.time_ns() - 60 * 10 ** 9
        os.utime(folder, ns=(listed, listed))
        # The full pass lists the folder one second after it changed: inside the racy window.
        with mock.patch.object(A.time, "time_ns", lambda: listed + 10 ** 9):
            self.run_full()
        self.assertEqual(self.state("SELECT mtime_ns FROM folders WHERE path=?", folder), [(0,)])
        # A file added within the same timestamp tick leaves the folder's mtime where it was.
        self.cold("proj-a/s2.jsonl", text(2, 500))
        os.utime(folder, ns=(listed, listed))
        summary = self.run_light()
        self.assertEqual(summary["appended"], 1)
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 500))

    def test_files_a_budget_cut_left_are_stored_by_the_next_light_pass(self):
        for index, name in enumerate(("a", "b", "c")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        summary = self.run_full(max_bytes=1)
        self.assertEqual((summary["appended"], summary["deferred"]), (1, 2))
        self.assertEqual(self.pending(), 2)
        summary = self.run_light()
        self.assertEqual((summary["appended"], summary["folders_read"]), (2, 0))
        self.assertEqual(self.pending(), 0)
        self.assertEqual(self.stored("claude", "c.jsonl"), text(2, 800))
        self.assertEqual(self.run_light()["changed"], 0)

    def test_waiting_file_that_cannot_be_read_stays_waiting(self):
        for index, name in enumerate(("a", "b")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        self.run_full(max_bytes=1)
        blocked = os.path.join(self.claude, "proj-a/b.jsonl")
        real_stat = os.stat

        def guarded(path, *rest, **how):
            if path == blocked:
                raise PermissionError(errno.EACCES, "Permission denied", path)
            return real_stat(path, *rest, **how)
        said = io.StringIO()
        with mock.patch.object(A.os, "stat", guarded), contextlib.redirect_stderr(said):
            summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        self.assertIn(blocked, said.getvalue())
        self.assertEqual(self.pending(), 1)
        summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "b.jsonl"), text(1, 800))

    def test_waiting_file_that_is_gone_stops_waiting(self):
        for index, name in enumerate(("a", "b")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        self.run_full(max_bytes=1)
        os.unlink(os.path.join(self.claude, "proj-a/b.jsonl"))
        summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 0))
        self.assertEqual(self.pending(), 0)

    def test_waiting_file_found_stored_stops_waiting(self):
        # The state is a cache and can come back inconsistent: here it lists as
        # waiting a file it also records as stored, unchanged since.
        path = self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        self.state("INSERT INTO pending(path) VALUES (?)", path)
        summary = self.run_light()
        self.assertEqual((summary["changed"], summary["source_errors"]), (0, 0))
        self.assertEqual(self.pending(), 0)

    def test_folder_that_cannot_be_listed_in_a_light_pass_is_counted(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        self.cold("proj-a/s2.jsonl", text(2, 500))
        blocked = os.path.join(self.claude, "proj-a")
        real_scandir = os.scandir

        def scandir(path):
            if path == blocked:
                raise OSError(errno.EIO, "Input/output error", path)
            return real_scandir(path)
        said = io.StringIO()
        with mock.patch.object(A.os, "scandir", scandir), contextlib.redirect_stderr(said):
            summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        self.assertIn(blocked, said.getvalue())
        summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))

    def test_file_gone_before_its_turn_stops_waiting(self):
        for index, name in enumerate(("a", "b", "c")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        self.run_full(max_bytes=1)
        archive = self.archive()
        archive.after_store_write = lambda: os.path.exists(gone) and os.unlink(gone)
        gone = os.path.join(self.claude, "proj-a/c.jsonl")
        try:
            summary = archive.capture(False)
        finally:
            archive.close()
        self.assertEqual((summary["appended"], summary["skipped"]), (1, 1))
        self.assertEqual(self.pending(), 0)

    def test_root_made_after_the_full_pass(self):
        shutil.rmtree(self.codex)
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        self.cold("2026/11/25/rollout-1.jsonl", text(2, 500), root=self.codex)
        summary = self.run_light()
        self.assertEqual(summary["appended"], 1)
        self.assertEqual(self.stored("codex", "2026/11/25/rollout-1.jsonl"), text(2, 500))

    def test_source_recorded_longer_than_its_stream_is_stored_by_a_light_pass(self):
        # As test_binding_longer_than_its_stream_is_never_taken_as_stored, on a light pass.
        first, more = text(1, 5000), text(2, 4000)
        self.put("proj-a/s1.jsonl", first)
        self.run_full()
        path = self.store_path("claude", "s1.jsonl")
        one_frame = os.path.getsize(path)
        self.add("proj-a/s1.jsonl", more)
        self.run_light()
        os.truncate(path, one_frame)
        self.state("UPDATE streams SET content_bytes=?, store_bytes=?, tail=?",
                   len(first), one_frame, A.tail_hash(first))
        summary = self.run_light()
        self.assertEqual((summary["changed"], summary["bytes_read"], summary["store_errors"]), (1, len(more), 0))
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: first + more})

    def test_unchanged_source_of_a_broken_stream_is_stored_again_by_a_light_pass(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.run_full()
        self.state("UPDATE streams SET broken=1")
        summary = self.run_light()
        self.assertEqual((summary["changed"], summary["versions"], summary["appended"]), (1, 1, 1))
        self.assertEqual(self.stored("claude", "s1.jsonl", 2), text(1, 900))
        self.assertEqual(self.run_light()["changed"], 0)

    def listing_that_gains(self, folder, rel, data, mtime):
        """os.scandir that, the first time it lists `folder`, adds a cold file there after reading the entries.

        The folder's new mtime is set outside the racy window, so only the order
        of the mtime read and the listing decides whether the file is found.
        """
        real = os.scandir
        armed = [True]

        def scandir(path):
            if path != folder or not armed[0]:
                return real(path)
            armed[0] = False
            with real(path) as entries:
                items = list(entries)
            self.cold(rel, data)
            os.utime(folder, ns=(mtime, mtime))
            return Listing(items)
        return mock.patch.object(A.os, "scandir", scandir)

    @staticmethod
    def listing_of(folder, blocked=None, broken=False):
        """os.scandir that lists `folder` with `blocked`'s metadata unreadable, or fails it (`broken`)."""
        real = os.scandir

        def scandir(path):
            if path != folder:
                return real(path)
            with real(path) as entries:
                items = [Entry(entry, entry.path == blocked) for entry in entries]
            return Listing(items, broken)
        return mock.patch.object(A.os, "scandir", scandir)

    def test_folder_replaced_by_a_symlink_is_not_followed(self):
        # A full pass does not go through a symlink below a root, and neither may
        # a light pass: not to a recent source's folder, nor to a folder it listed.
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.cold("proj-b/s2.jsonl", text(2, 900))
        self.put("proj-c/s3.jsonl", text(5, 900))
        self.put("proj-c/s3/subagents/agent-a.jsonl", text(6, 300))
        self.age()
        self.run_full()
        # A project folder, and a session's folder one level further down.
        for name, files in (("proj-a", {"s1.jsonl": text(1, 900) + text(3, 400)}),
                            ("proj-b", {"private.jsonl": text(4, 500)}),
                            ("proj-c/s3", {"subagents/agent-a.jsonl": text(6, 300) + text(7, 200),
                                           "subagents/agent-z.jsonl": text(8, 200)})):
            outside = os.path.join(self.tmp, "outside-" + name.replace("/", "-"))
            for file, data in files.items():
                os.makedirs(os.path.dirname(os.path.join(outside, file)), exist_ok=True)
                Path(outside, file).write_bytes(data)
            shutil.rmtree(os.path.join(self.claude, name))
            os.symlink(outside, os.path.join(self.claude, name))
        summary = self.run_light()
        self.assertEqual((summary["changed"], summary["appended"], summary["source_errors"]), (0, 0, 0))
        self.assertEqual(self.run_full()["changed"], 0)
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {1: text(1, 900)})
        self.assertEqual(self.versions_on_disk("claude", "private.jsonl"), {})
        self.assertEqual(self.versions_on_disk("claude", "s3/subagents/agent-a.jsonl"), {1: text(6, 300)})
        self.assertEqual(self.versions_on_disk("claude", "s3/subagents/agent-z.jsonl"), {})

    def test_waiting_file_a_full_pass_could_not_read_keeps_waiting(self):
        for index, name in enumerate(("a", "b")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        self.run_full(max_bytes=1)
        self.assertEqual(self.pending(), 1)
        folder = os.path.join(self.claude, "proj-a")
        with self.listing_of(folder, blocked=os.path.join(folder, "b.jsonl")), \
                contextlib.redirect_stderr(io.StringIO()):
            summary = self.run_full()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        self.assertEqual(self.pending(), 1)
        summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "b.jsonl"), text(1, 800))
        self.assertEqual(self.pending(), 0)

    def test_folder_a_full_pass_could_not_list_is_listed_again(self):
        for index, name in enumerate(("a", "b")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        self.run_full(max_bytes=1)                  # a is stored, b waits
        self.cold("proj-a/c.jsonl", text(2, 800))
        self.age()
        folder = os.path.join(self.claude, "proj-a")
        with self.listing_of(folder, broken=True), contextlib.redirect_stderr(io.StringIO()):
            summary = self.run_full()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        self.assertEqual(self.pending(), 1)         # b, below the folder the walk could not list
        self.assertEqual(self.state("SELECT mtime_ns FROM folders WHERE path=?", folder), [(0,)])
        summary = self.run_light()
        self.assertEqual((summary["appended"], summary["folders_read"], summary["source_errors"]), (2, 1, 0))
        self.assertEqual(self.stored("claude", "c.jsonl"), text(2, 800))
        self.assertEqual(self.pending(), 0)

    def test_waiting_file_that_is_gone_stops_waiting_on_a_full_pass(self):
        for index, name in enumerate(("a", "b")):
            path = self.cold(f"proj-a/{name}.jsonl", text(index, 800))
            os.utime(path, ns=(self.old + index, self.old + index))
        self.age()
        self.run_full(max_bytes=1)
        os.unlink(os.path.join(self.claude, "proj-a/b.jsonl"))
        self.assertEqual(self.run_full()["source_errors"], 0)
        self.assertEqual(self.pending(), 0)

    def test_folder_a_full_pass_could_not_open_is_listed_again(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        self.cold("proj-a/s2.jsonl", text(2, 500))
        self.age()
        folder = os.path.join(self.claude, "proj-a")
        real_scandir = os.scandir

        def scandir(path):
            if path == folder:
                raise OSError(errno.EIO, "Input/output error", path)
            return real_scandir(path)
        with mock.patch.object(A.os, "scandir", scandir), contextlib.redirect_stderr(io.StringIO()):
            summary = self.run_full()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        self.assertEqual(self.state("SELECT mtime_ns FROM folders WHERE path=?", folder), [(0,)])
        summary = self.run_light()
        self.assertEqual((summary["appended"], summary["source_errors"]), (1, 0))
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 500))

    def test_folder_a_light_pass_could_not_list_whole_is_listed_again(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        self.cold("proj-a/s2.jsonl", text(2, 500))
        folder = os.path.join(self.claude, "proj-a")
        os.utime(folder, ns=(self.old + 10 ** 9, self.old + 10 ** 9))
        with self.listing_of(folder, broken=True), contextlib.redirect_stderr(io.StringIO()):
            summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 500))

    def test_file_a_light_pass_could_not_read_is_looked_at_again(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        self.cold("proj-a/s2.jsonl", text(2, 500))
        folder = os.path.join(self.claude, "proj-a")
        os.utime(folder, ns=(self.old + 10 ** 9, self.old + 10 ** 9))
        with self.listing_of(folder, blocked=os.path.join(folder, "s2.jsonl")), \
                contextlib.redirect_stderr(io.StringIO()):
            summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (1, 0))
        summary = self.run_light()
        self.assertEqual((summary["source_errors"], summary["appended"]), (0, 1))
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 500))

    def test_file_added_while_a_full_pass_lists_its_folder(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        folder = os.path.join(self.claude, "proj-a")
        with self.listing_that_gains(folder, "proj-a/s2.jsonl", text(2, 500), self.old + 10 ** 9):
            self.assertEqual(self.run_full()["appended"], 1)
        summary = self.run_light()
        self.assertEqual((summary["appended"], summary["folders_read"]), (1, 1))
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 500))

    def test_file_added_while_a_light_pass_lists_its_folder(self):
        self.cold("proj-a/s1.jsonl", text(1, 900))
        self.age()
        self.run_full()
        folder = os.path.join(self.claude, "proj-a")
        self.cold("proj-a/s2.jsonl", text(2, 500))
        os.utime(folder, ns=(self.old + 10 ** 9, self.old + 10 ** 9))
        with self.listing_that_gains(folder, "proj-a/s3.jsonl", text(3, 500), self.old + 2 * 10 ** 9):
            self.assertEqual(self.run_light()["appended"], 1)
        self.assertEqual(self.run_light()["appended"], 1)
        self.assertEqual(self.stored("claude", "s3.jsonl"), text(3, 500))

    def test_folder_removed_and_made_again_after_a_full_pass(self):
        self.cold("proj-a/s1/subagents/agent-a.jsonl", text(1, 300))
        self.age()
        self.run_full()
        shutil.rmtree(os.path.join(self.claude, "proj-a/s1"))
        self.age()
        self.run_full()
        self.cold("proj-a/s1/subagents/agent-b.jsonl", text(2, 300))
        self.assertEqual(self.run_light()["appended"], 1)
        self.assertEqual(self.stored("claude", "s1/subagents/agent-b.jsonl"), text(2, 300))

    def test_what_a_light_pass_leaves_to_the_full_pass(self):
        self.cold("proj-b/s2.jsonl", text(2, 900))
        self.cold("proj-b/s2/tool-results/a.txt", text(3, 300))
        self.age()
        self.run_full()
        self.add("proj-b/s2.jsonl", text(4, 200))           # an old session resumed: it grows in place
        self.cold("proj-b/s2/tool-results/b.txt", text(5, 300))     # a new file in a cold folder
        self.assertEqual(self.run_light()["changed"], 0)
        summary = self.run_full()
        self.assertEqual(summary["appended"], 2)
        self.assertEqual(self.stored("claude", "s2.jsonl"), text(2, 900) + text(4, 200))
        self.assertEqual(self.stored("claude", "s2/tool-results/b.txt"), text(5, 300))

    def test_light_plan_is_a_subset_of_the_full_plan(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.cold("proj-a/s1/subagents/agent-a.jsonl", text(2, 300))
        self.cold("proj-b/s2.jsonl", text(3, 900))
        self.cold("proj-b/s2/tool-results/a.txt", text(4, 300))
        self.put("2026/11/24/rollout-1.jsonl", text(5, 900), root=self.codex)
        self.age()
        self.run_full()
        self.add("proj-a/s1.jsonl", text(6, 100))
        self.cold("proj-a/s1/subagents/agent-b.jsonl", text(7, 300))
        self.cold("proj-b/s8.jsonl", text(8, 300))
        self.cold("proj-c/s9.jsonl", text(9, 300))
        self.cold("2026/12/01/rollout-2.jsonl", text(10, 300), root=self.codex)
        grown = self.add("proj-b/s2.jsonl", text(11, 100))
        deep = self.cold("proj-b/s2/tool-results/b.txt", text(12, 300))
        archive = self.archive()
        try:
            light, full = set(archive.plan(False)[0]), set(archive.plan(True)[0])
        finally:
            archive.close()
        self.assertLessEqual(light, full)
        self.assertEqual(full - light, {grown, deep})
        self.assertEqual(len(light), 5)

    def test_full_pass_comes_once_the_last_one_is_full_every_old(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        every = A.DEFAULT_FULL_EVERY
        self.assertEqual(self.run_pass(full_every=every)["full_walks"], 2)      # no full pass yet
        self.assertEqual(self.run_pass(full_every=every)["full_walks"], 0)
        now = time.time_ns()
        for ago, walks in ((every - 30, 0), (every + 1, 2), (-600, 2)):        # -600: the clock moved back
            self.state("UPDATE meta SET v=? WHERE k LIKE 'full_walk%'", str(now - ago * 10 ** 9))
            self.assertEqual(self.run_pass(full_every=every)["full_walks"], walks, ago)

    def test_full_every_is_under_an_hour(self):
        # The timer this replaced fired hourly with up to two minutes of jitter;
        # on that timer every pass must stay full.
        self.assertLessEqual(A.DEFAULT_FULL_EVERY, 3600 - 300)


class FreeSpaceFloorTests(Case):
    def test_below_the_floor_nothing_is_stored_and_the_pass_says_so(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.run_pass()
        before = self.store_files()
        self.add("proj-a/s1.jsonl", text(2, 300))
        self.put("proj-a/s2.jsonl", text(3, 500))
        summary = self.run_pass(min_free=1 << 62)       # more than any disk has free
        self.assertEqual((summary["low_disk"], summary["deferred"], summary["appended"]), (1, 2, 0))
        self.assertEqual(self.store_files(), before)
        summary = self.run_pass(min_free=1)
        self.assertEqual((summary["low_disk"], summary["appended"]), (0, 2))
        self.assertEqual(self.stored("claude", "s1.jsonl"), text(1, 900) + text(2, 300))

    def test_floor_is_quiet_when_there_is_nothing_to_store(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.run_pass()
        summary = self.run_pass(min_free=1 << 62)
        self.assertEqual((summary["low_disk"], summary["deferred"], summary["changed"]), (0, 0, 0))


class FrameScanTests(Case):
    def test_last_whole_frame_is_found_at_every_cut_point(self):
        path = os.path.join(self.tmp, "frames.zst")
        plain = os.path.join(self.tmp, "plain")
        Path(plain).write_bytes(text(4, 200))
        frames = [
            zstd_frame(text(1, 300)),                       # from a pipe: no content size in the header
            zstd_frame(text(5, 300), "--no-check"),         # no checksum: the last block ends the frame
            zstd_frame(noise(2, 400), "--long=27"),         # raw blocks, a window descriptor
            subprocess.run([ZSTD, "-q", "-c", plain], stdout=subprocess.PIPE, check=True).stdout,  # sized
            zstd_frame(b"a" * 5000),                        # a run-length block
            zstd_frame(noise(3, 140_000)),                  # more than one block
        ]
        Path(path).write_bytes(b"".join(frames))
        ends = []
        for frame in frames:
            ends.append((ends[-1] if ends else 0) + len(frame))
        total = ends[-1]
        cuts = set(range(0, ends[4] + 40)) | {end + delta for end in ends for delta in (-2, -1, 0, 1, 2, 6)}
        for cut in sorted(cut for cut in cuts if 0 <= cut <= total):
            expected = max([end for end in ends if end <= cut], default=0)
            self.assertEqual(A.frame_scan(path, cut), expected, "cut at %d" % cut)

    def test_bytes_that_are_not_a_frame_are_never_called_whole(self):
        path = os.path.join(self.tmp, "junk")
        Path(path).write_bytes(noise(1, 500))
        self.assertEqual(A.frame_scan(path, 500), 0)


class RandomOperationsTest(Case):
    """Seeded random edits, copies, moves, crashes and state loss.

    Two properties, checked from the store's files alone:
      * every stored version is exactly a source state some pass saw (no mixes,
        no duplicated or missing bytes);
      * every state a completed pass saw is still the start of a stored version.
    And after each completed pass, the stream recorded for a live source starts
    with that source's bytes.
    """

    KEYS = ("s1.jsonl", "s2.jsonl", "s1/subagents/agent-x.jsonl", "s1/workflows/wf_1.json",
            "s1/tool-results/out.txt")
    FOLDERS = ("proj-a", "proj-b")

    def live(self):
        found = {}
        for folder in self.FOLDERS:
            for key in self.KEYS:
                path = os.path.join(self.claude, folder, key)
                if os.path.exists(path):
                    found[path] = (("claude", key), Path(path).read_bytes())
        path = os.path.join(self.codex, "2026/11/24/rollout-1.jsonl")
        if os.path.exists(path):
            found[path] = (("codex", "2026/11/24/rollout-1.jsonl"), Path(path).read_bytes())
        return found

    def mutate(self, rng, seed):
        folder, key = rng.choice(self.FOLDERS), rng.choice(self.KEYS)
        if rng.random() < 0.15:
            rel, root = "2026/11/24/rollout-1.jsonl", self.codex
        else:
            rel, root = folder + "/" + key, self.claude
        path = os.path.join(root, rel)
        other = os.path.join(self.claude, rng.choice(self.FOLDERS), key)
        size = rng.choice((1, 60, 900, A.TAIL - 1, A.TAIL + 1, 3 * A.TAIL))
        fresh = text(seed, size)
        exists = os.path.exists(path)
        op = rng.choice(("write", "append", "append", "append", "truncate", "copy", "move", "delete", "touch"))
        if not exists or op == "write":
            self.put(rel, fresh, root)
        elif op == "append":
            self.add(rel, fresh, root)
        elif op == "truncate":
            self.put(rel, Path(path).read_bytes()[:rng.randrange(0, os.path.getsize(path) + 1)], root)
        elif op == "copy" and root == self.claude and other != path:
            os.makedirs(os.path.dirname(other), exist_ok=True)
            shutil.copyfile(path, other)
            self.stamp(other)
        elif op == "move" and root == self.claude and other != path:
            os.makedirs(os.path.dirname(other), exist_ok=True)
            os.replace(path, other)
            self.stamp(other)
        elif op == "delete":
            os.unlink(path)
        else:
            self.stamp(path)

    def check_versions(self, observed, label):
        for directory, _, names in os.walk(os.path.join(self.store, "data")):
            for name in names:
                self.assertRegex(name, r"\.zst$", label)
                path = os.path.join(directory, name)
                if not os.path.getsize(path):
                    continue
                agent, _, key = os.path.relpath(path, os.path.join(self.store, "data")).split(os.sep, 2)
                key = re.sub(r"(\.v\d+)?\.zst$", "", key.replace(os.sep, "/"))
                self.assertIn(zstd_decode(path), observed.get((agent, key), set()),
                              "%s: %s holds bytes no pass ever saw as one file" % (label, path))

    def run_seed(self, seed, light=False):
        """With `light`, each pass is light or full at random and the run ends with a full pass.

        A light pass may leave a change to the next full pass (the module
        docstring says which), so the check that every live source is stored runs
        after full passes only. That no stored version is a state no pass saw is
        checked after every pass, light or full.
        """
        rng = random.Random(seed)
        observed, must_keep = {}, set()
        saved_state = None
        for step in range(46 if light else 45):
            last = light and step == 45
            label = "seed %d step %d" % (seed, step)
            for index in range(rng.randrange(1, 4)):
                self.mutate(rng, seed * 100_000 + step * 10 + index)
            roll = rng.random()
            state_file = os.path.join(self.store, "state.sqlite3")
            if roll < 0.08 and os.path.exists(state_file):
                self.drop_state()
            elif roll < 0.16 and saved_state is not None:
                self.drop_state()
                shutil.copy(saved_state, state_file)
            elif roll < 0.30 and os.path.exists(state_file):
                saved_state = os.path.join(self.tmp, "state.saved")
                shutil.copy(state_file, saved_state)
            live = self.live()
            for identity, content in live.values():
                observed.setdefault(identity, set()).add(content)
            archive = self.archive()
            full = True
            if light:
                full = last or rng.random() < 0.35
            crashed = not last and rng.random() < 0.2
            if crashed:
                countdown = [rng.randrange(1, 4)]

                def hook():
                    countdown[0] -= 1
                    if countdown[0] == 0:
                        raise Crash()
                archive.after_store_write = hook
            try:
                summary = archive.capture(full if light else None)
                self.assertEqual(summary["store_errors"] + summary["source_errors"], 0, label)
                crashed = False
            except Crash:
                pass
            finally:
                archive.close()
            self.check_versions(observed, label)
            if crashed or not full:
                continue
            archive = self.archive()
            try:
                for path, (identity, content) in live.items():
                    found = archive.bound(path)
                    self.assertIsNotNone(found, "%s: %s has no stream" % (label, path))
                    stream, size = found
                    self.assertEqual((stream.agent, stream.key, size), identity + (len(content),), label)
                    if content:
                        whole = zstd_decode(archive.stream_path(stream))
                        self.assertEqual(whole[:size], content, "%s: %s" % (label, path))
                    must_keep.add((identity, content))
            finally:
                archive.close()
        for (agent, key), content in must_keep:
            if content:
                kept = self.versions_on_disk(agent, key).values()
                self.assertTrue(any(version.startswith(content) for version in kept),
                                "seed %d: a %d-byte state of %s/%s is in no stored version"
                                % (seed, len(content), agent, key))

    def fresh(self):
        shutil.rmtree(self.store, ignore_errors=True)
        for root in (self.claude, self.codex):
            shutil.rmtree(root)
            os.makedirs(root)

    def test_random_operations(self):
        for seed in (1, 2, 3, 4, 5, 6):
            with self.subTest(seed=seed):
                self.fresh()
                self.run_seed(seed)

    def test_random_operations_with_light_passes_between_full_ones(self):
        for seed in (11, 12, 13, 14, 15, 16):
            with self.subTest(seed=seed):
                self.fresh()
                # Odd seeds write files dated an hour ago, which light passes
                # follow as recent sources; even seeds keep the 2023 dates, which
                # light passes reach only through the folders and the pending list.
                if seed % 2:
                    self.clock = time.time_ns() - 3600 * 10 ** 9
                self.run_seed(seed, light=True)


class CommandLineTests(Case):
    def cli(self, *args, env=None, check=True):
        command = [sys.executable, str(SCRIPT), "--store", self.store,
                   "--root", "claude=%s:1" % self.claude, "--root", "codex=%s" % self.codex, *args]
        if env is None:
            # A CI runner can have less free disk than the shipped 10 GiB floor.
            # These files carry 2023 timestamps, which a light pass rightly
            # leaves to the full one, so every pass here is full; LightPassTests
            # drive the command line's light passes themselves.
            env = dict(os.environ, SESSION_ARCHIVE_MIN_FREE_BYTES="0", SESSION_ARCHIVE_FULL_EVERY="0")
        done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if check:
            self.assertEqual(done.returncode, 0, done.stderr.decode())
        return done

    def test_capture_status_where_cat_and_verify(self):
        content = text(1, 9000)
        path = self.put("proj-a/s1.jsonl", content)
        self.put("2026/11/24/rollout-1.jsonl", text(2, 400), root=self.codex)
        summary = json.loads(self.cli("capture", "--json").stdout)
        self.assertEqual((summary["appended"], summary["bytes_read"]), (2, 9400))
        line = self.cli("capture").stdout.decode()
        self.assertRegex(line, r"^session-archive: scanned=2 changed=0 appended=0 ")
        status = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual((status["streams"], status["sources"], status["content_bytes"]), (2, 2, 9400))
        self.assertEqual(status["last_pass"]["changed"], 0)
        self.assertEqual(self.cli("cat", path).stdout, content)
        where = self.cli("where", path).stdout.decode()
        self.assertIn("* v1 9000 bytes " + self.store_path("claude", "s1.jsonl"), where)
        report = json.loads(self.cli("verify").stdout)
        self.assertEqual((report["same"], report["different"], report["bytes"]), (2, 0, 9400))

    def test_capture_leaves_when_another_capture_holds_the_lock(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        os.makedirs(self.store)
        holder = os.open(os.path.join(self.store, "lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, holder)
        fcntl.flock(holder, fcntl.LOCK_EX)
        done = self.cli("capture", "--json")
        self.assertIn("another capture holds the lock", done.stderr.decode())
        self.assertEqual((done.stdout, self.store_files()), (b"", {}))
        fcntl.flock(holder, fcntl.LOCK_UN)
        self.assertEqual(json.loads(self.cli("capture", "--json").stdout)["appended"], 1)

    def test_verify_reports_a_store_that_differs_from_its_source(self):
        path = self.put("proj-a/s1.jsonl", text(1, 9000))
        self.cli("capture")
        store_file = self.store_path("claude", "s1.jsonl")
        Path(store_file).write_bytes(zstd_frame(text(7, 9000)))
        done = self.cli("verify", check=False)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(json.loads(done.stdout)["differences"], [path])

    def test_archive_is_private_to_its_owner(self):
        self.put("proj-a/s1/subagents/agent-x.jsonl", text(1, 900))
        self.addCleanup(os.umask, os.umask(0o022))     # the tool must not rely on the caller's umask
        self.cli("capture")
        for directory, _, names in os.walk(self.store):
            self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o700, directory)
            for name in names:
                path = os.path.join(directory, name)
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode) & 0o077, 0, path)

    def test_second_capture_leaves_when_one_is_running(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        os.makedirs(self.store)
        with open(os.path.join(self.store, "lock"), "w") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            done = self.cli("capture")
        self.assertIn("another capture holds the lock", done.stderr.decode())
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {})

    def test_low_disk_is_exit_1_with_the_reason(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        done = self.cli("capture", "--min-free-bytes", str(1 << 62), check=False)
        self.assertEqual(done.returncode, 1)
        self.assertIn("free space on the store's disk is below", done.stderr.decode())
        self.assertEqual(self.versions_on_disk("claude", "s1.jsonl"), {})
        self.cli("capture")
        self.assertEqual(self.stored("claude", "s1.jsonl"), text(1, 900))

    def test_capture_is_light_between_full_passes_and_full_on_request(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        env = dict(os.environ, SESSION_ARCHIVE_MIN_FREE_BYTES="0")
        env.pop("SESSION_ARCHIVE_FULL_EVERY", None)

        def walks(*args):
            return json.loads(self.cli("capture", "--json", *args, env=env).stdout)["full_walks"]
        self.assertEqual([walks(), walks(), walks("--full"), walks("--full-every", "0"), walks()], [2, 0, 2, 2, 0])

    def test_status_reads_a_state_file_written_before_light_passes(self):
        os.makedirs(self.store)
        state = os.path.join(self.store, "state.sqlite3")
        db = sqlite3.connect(state, isolation_level=None)
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript("""
            CREATE TABLE streams(
              id INTEGER PRIMARY KEY, agent TEXT NOT NULL, key TEXT NOT NULL, version INTEGER NOT NULL,
              content_bytes INTEGER NOT NULL, store_bytes INTEGER NOT NULL, tail BLOB NOT NULL,
              broken INTEGER NOT NULL DEFAULT 0, UNIQUE(agent, key, version));
            CREATE TABLE sources(
              path TEXT PRIMARY KEY, stream INTEGER NOT NULL, size INTEGER NOT NULL,
              mtime_ns INTEGER NOT NULL, ino INTEGER NOT NULL, seen_ns INTEGER NOT NULL);
            CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
        """)
        db.close()

        def tables():
            check = sqlite3.connect(f"file:{state}?mode=ro", uri=True)
            try:
                return sorted(row[0] for row in check.execute("SELECT name FROM sqlite_master WHERE type='table'"))
            finally:
                check.close()
        status = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual((status["streams"], status["pending"]), (0, 0))
        self.assertEqual(tables(), ["meta", "sources", "streams"])
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.assertEqual(json.loads(self.cli("capture", "--json").stdout)["appended"], 1)
        self.assertEqual(tables(), ["folders", "meta", "pending", "sources", "streams"])
        self.assertEqual(json.loads(self.cli("status", "--json").stdout)["pending"], 0)

    def test_root_option_takes_a_home_relative_folder_and_a_depth(self):
        home = os.path.expanduser("~")
        self.assertEqual(A.parse_roots(["extra=~/some/where:2", "flat=/srv/logs"]),
                         [A.Root("extra", os.path.join(home, "some/where"), 2), A.Root("flat", "/srv/logs", 0)])
        self.assertEqual([(root.agent, os.path.relpath(root.path, home), root.depth) for root in A.parse_roots(None)],
                         [("claude", ".claude/projects", 1), ("codex", ".codex/sessions", 0),
                          ("pi", ".pi/agent/sessions", 1), ("factory", ".factory/sessions", 1)])

    def test_missing_zstd_is_exit_3_with_the_reason(self):
        empty = os.path.join(self.tmp, "no-tools")
        os.makedirs(empty)
        done = self.cli("capture", env={"PATH": empty, "HOME": self.tmp}, check=False)
        self.assertEqual(done.returncode, 3)
        self.assertIn("zstd is not on PATH", done.stderr.decode())

    def test_errors_make_the_exit_code_1(self):
        self.put("proj-a/s1.jsonl", text(1, 900))
        self.cli("capture")
        bad = bytearray(zstd_frame(noise(5, 50_000)))
        bad[len(bad) // 2] ^= 0xFF
        with open(self.store_path("claude", "s1.jsonl"), "ab") as fh:
            fh.write(bytes(bad))
        self.add("proj-a/s1.jsonl", text(2, 100))
        done = self.cli("capture", check=False)
        self.assertEqual(done.returncode, 1)
        self.assertIn("store file does not decode", done.stderr.decode())

    # ---- status, verify, where and cat only read -------------------------------

    def fingerprint(self):
        """Every store file and every state row, as digests: a failed comparison must not print megabytes."""
        files = sorted((name, len(data), hashlib.sha256(data).hexdigest())
                       for name, data in self.store_files().items())
        db = sqlite3.connect("file:%s?mode=ro" % os.path.join(self.store, "state.sqlite3"), uri=True)
        try:
            rows = repr((db.execute("SELECT * FROM streams ORDER BY id").fetchall(),
                         db.execute("SELECT * FROM sources ORDER BY path").fetchall()))
        finally:
            db.close()
        return files, hashlib.sha256(rows.encode()).hexdigest()

    def test_read_commands_change_neither_the_store_nor_the_state(self):
        first, more = text(1, 9000), text(2, 3000)
        path = self.put("proj-a/s1.jsonl", first)
        self.cli("capture")
        self.add("proj-a/s1.jsonl", more)
        self.cli("capture")
        store_file = self.store_path("claude", "s1.jsonl")
        # What a capture that is writing this very moment, or one that was killed,
        # leaves after the last frame the state knows: part of a frame.
        with open(store_file, "ab") as fh:
            fh.write(zstd_frame(noise(5, 300_000))[:150_000])
        # And a version file the state has no row for.
        stray = self.store_path("claude", "s1.jsonl", 2)
        Path(stray).write_bytes(zstd_frame(text(7, 500)))
        before = self.fingerprint()
        self.cli("status")
        self.assertEqual(json.loads(self.cli("verify").stdout)["same"], 1)
        where = self.cli("where", path).stdout.decode()
        self.assertTrue(self.cli("cat", path).stdout == first + more)
        self.assertTrue(self.cli("cat", "--version", "1", path).stdout == first + more)
        self.assertTrue(self.cli("cat", "--version", "2", path).stdout == text(7, 500))
        self.assertEqual(self.fingerprint(), before)
        self.assertFalse(os.path.exists(store_file + ".partial"))
        self.assertIn("* v1 12000 bytes " + store_file, where)
        self.assertRegex(where, r"(?m)^  v2 not in the state yet %s$" % re.escape(stray))

    def test_read_commands_run_beside_a_capture_that_is_writing(self):
        first, more = text(1, 9000), text(2, 3000)
        path = self.put("proj-a/s1.jsonl", first)
        self.run_pass()
        self.add("proj-a/s1.jsonl", more)
        store_file = self.store_path("claude", "s1.jsonl")
        seen = {}

        def beside():
            # The new frame is on disk, its cursor is not saved, and the pass's
            # transaction is open. Readers see the last committed state.
            during = Path(store_file).read_bytes()
            seen["where"] = self.cli("where", path).stdout.decode()
            seen["cat"] = self.cli("cat", path).stdout
            seen["version"] = self.cli("cat", "--version", "1", path).stdout
            seen["status"] = json.loads(self.cli("status", "--json").stdout)["content_bytes"]
            seen["verify"] = json.loads(self.cli("verify").stdout)["changed_since_capture"]
            seen["untouched"] = Path(store_file).read_bytes() == during
        archive = self.archive()
        archive.after_store_write = beside
        try:
            summary = archive.capture()
        finally:
            archive.close()
        self.assertEqual((seen["cat"], seen["version"], seen["status"], seen["verify"], seen["untouched"]),
                         (first, first, 9000, 1, True))
        self.assertIn("* v1 9000 bytes " + store_file, seen["where"])
        self.assertEqual((summary["appended"], summary["store_errors"]), (1, 0))
        self.assertEqual(self.stored("claude", "s1.jsonl"), first + more)
        self.assertEqual(self.cli("cat", path).stdout, first + more)

    def test_read_commands_create_nothing_where_no_archive_exists(self):
        path = self.put("proj-a/s1.jsonl", text(1, 900))
        status = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual((status["streams"], status["sources"], status["last_pass"]), (0, 0, None))
        self.assertEqual(json.loads(self.cli("verify").stdout)["same"], 0)
        for command in ("where", "cat"):
            done = self.cli(command, path, check=False)
            self.assertEqual(done.returncode, 1, command)
            self.assertIn("no stored stream", done.stderr.decode())
        self.assertFalse(os.path.exists(self.store))

    def test_cat_fails_when_the_store_holds_less_than_was_recorded(self):
        first, more = text(1, 9000), text(2, 17000)
        path = self.put("proj-a/s1.jsonl", first)
        self.cli("capture")
        store_file = self.store_path("claude", "s1.jsonl")
        one_frame = os.path.getsize(store_file)
        self.add("proj-a/s1.jsonl", more)
        self.cli("capture")
        os.unlink(path)                                 # the transcript is gone: the store is the only copy
        os.truncate(store_file, one_frame)
        for args in (("cat", path), ("cat", "--version", "1", path)):
            done = self.cli(*args, check=False)
            self.assertEqual(done.returncode, 1, args)
            self.assertIn("holds 9000 of the 26000 bytes recorded", done.stderr.decode())


class DeviceFillTests(Case):
    """Records written before the device column was kept get their device from a pass that finds the file as recorded."""

    move = MovedFolderTests.move
    state_rows = MovedFolderTests.state_rows
    strip_device_column = MovedFolderTests.strip_device_column
    no_full_comparison = MovedFolderTests.no_full_comparison
    run_light = LightPassTests.run_light
    run_full = LightPassTests.run_full

    def setUp(self):
        super().setUp()
        self.clock = time.time_ns() - 3600 * 10 ** 9        # files dated an hour ago: recent for a quick pass

    FILES = (("proj-a/s1.jsonl", 40_000), ("proj-a/s2.jsonl", 30_000), ("proj-a/s1/tool-results/out.txt", 20_000))

    def populate(self):
        for number, (rel, size) in enumerate(self.FILES):
            self.put(rel, text(number, size))

    def query(self, sql, args=()):
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()

    def write(self, sql, args=()):
        db = sqlite3.connect(os.path.join(self.store, "state.sqlite3"), isolation_level=None)
        try:
            db.execute(sql, args)
        finally:
            db.close()

    def records(self):
        return self.query("SELECT path, size, mtime_ns, ino, seen_ns, dev FROM sources ORDER BY path")

    def pre_migration_state(self):
        """What a pass before the device column left: the records exist and their device is NULL."""
        self.run_pass()
        self.write("UPDATE sources SET dev=NULL")
        self.assertTrue(all(row[5] is None for row in self.records()))

    def full_pass(self):
        """A full pass; `self.compared` is the source bytes it compared against the store (not in bytes_read)."""
        archive = self.archive()
        try:
            summary = archive.capture()
            self.compared = archive.spent - summary["bytes_read"]
            return summary
        finally:
            archive.close()

    def scenario(self, run):
        """Pre-migration records, one pass of `run`, a folder rename, one more pass: (fill pass, rename pass)."""
        self.populate()
        self.pre_migration_state()
        before = self.records()
        filled = run()
        after = self.records()
        self.assertEqual([row[:5] for row in before], [row[:5] for row in after])     # seen_ns and the rest are as they were
        self.move()
        return filled, run()

    def test_full_pass_fills_the_device_and_the_renamed_folder_is_not_compared(self):
        filled, renamed = self.scenario(self.full_pass)
        self.assertEqual(filled["device_filled"], 3)
        self.assertEqual({row[5] for row in self.records()}, {os.stat(self.claude).st_dev})
        self.assertEqual((renamed["moved"], renamed["proved"], renamed["device_filled"]), (3, 0, 0))
        self.assertEqual((renamed["bytes_read"], self.compared), (0, 0))

    def test_without_the_fill_the_renamed_folder_is_compared_in_full(self):
        with mock.patch.object(A.Archive, "fill"):
            filled, renamed = self.scenario(self.full_pass)
        self.assertEqual((filled["device_filled"], renamed["moved"], renamed["proved"]), (0, 0, 3))
        self.assertEqual(self.compared, sum(size for _, size in self.FILES))

    def test_quick_pass_fills_recent_records(self):
        self.populate()
        self.run_full()
        self.write("UPDATE sources SET dev=NULL")
        before = self.records()
        filled = self.run_light()
        self.assertEqual(filled["full_walks"], 0)
        self.assertEqual(filled["device_filled"], 3)
        self.assertEqual([row[:5] for row in before], [row[:5] for row in self.records()])
        self.assertTrue(all(row[5] is not None for row in self.records()))
        self.move()
        with self.no_full_comparison():
            renamed = self.run_light()
        self.assertEqual((renamed["full_walks"], renamed["moved"], renamed["proved"]), (0, 3, 0))
        self.assertEqual(renamed["bytes_read"], 0)

    def test_quick_pass_leaves_a_record_older_than_the_recent_window_alone(self):
        path = self.put("proj-a/s1.jsonl", text(1, 5000))
        old = time.time_ns() - 5 * 24 * 3600 * 10 ** 9
        os.utime(path, ns=(old, old))
        self.run_full()
        self.write("UPDATE sources SET dev=NULL")
        self.assertEqual(self.run_light()["device_filled"], 0)
        self.assertEqual(self.run_full()["device_filled"], 1)

    def test_a_file_that_changed_gets_no_fill(self):
        self.populate()
        self.pre_migration_state()
        grown = os.path.join(self.claude, "proj-a/s1.jsonl")
        self.add("proj-a/s1.jsonl", text(9, 100))
        touched = os.path.join(self.claude, "proj-a/s2.jsonl")
        self.stamp(touched)
        replaced = os.path.join(self.claude, "proj-a/s1/tool-results/out.txt")
        mtime = os.stat(replaced).st_mtime_ns
        os.rename(replaced, replaced + ".old")
        with open(replaced, "wb") as fh:
            fh.write(Path(replaced + ".old").read_bytes())             # same size, same mtime, other inode
        os.utime(replaced, ns=(mtime, mtime))
        os.unlink(replaced + ".old")
        for full in (True, False):
            archive = self.archive()
            try:
                archive.plan(full)
                self.assertEqual([fill[1] for fill in archive.fills if fill[1] in (grown, touched, replaced)], [])
            finally:
                archive.close()

    def test_a_path_that_is_gone_gets_no_fill(self):
        self.populate()
        self.pre_migration_state()
        gone = os.path.join(self.claude, "proj-a/s2.jsonl")
        os.unlink(gone)
        archive = self.archive()
        try:
            archive.plan(True)
            self.assertEqual(len(archive.fills), 2)
            self.assertNotIn(gone, [fill[1] for fill in archive.fills])
        finally:
            archive.close()
        self.assertEqual(self.run_pass()["device_filled"], 2)
        self.assertEqual([row[5] is None for row in self.records() if row[0] == gone], [True])

    def test_a_record_changed_between_the_plan_and_the_write_is_not_filled(self):
        self.populate()
        self.pre_migration_state()
        real = A.Archive.plan
        changed = {os.path.join(self.claude, "proj-a/s1.jsonl"): "size=size+1",
                   os.path.join(self.claude, "proj-a/s2.jsonl"): "mtime_ns=mtime_ns+1",
                   os.path.join(self.claude, "proj-a/s1/tool-results/out.txt"): "ino=ino+1"}

        def plan_then_change(archive, *args):
            result = real(archive, *args)
            self.assertEqual(len(archive.fills), 3)
            for path, change in changed.items():
                archive.db.execute("UPDATE sources SET " + change + " WHERE path=?", (path,))
            return result
        with mock.patch.object(A.Archive, "plan", plan_then_change):
            summary = self.run_pass()
        self.assertEqual(summary["device_filled"], 0)
        self.assertTrue(all(row[5] is None for row in self.records()))

    def test_a_fill_does_not_change_which_record_is_the_newest_of_an_inode(self):
        first = self.put("proj-a/s1.jsonl", text(1, 9000))
        second = os.path.join(self.claude, "proj-b", "s1.jsonl")
        os.makedirs(os.path.dirname(second))
        os.link(first, second)
        self.run_pass()
        # Two records of one inode: the one for `second` is the newer.
        self.write("UPDATE sources SET dev=NULL, seen_ns=CASE WHEN path=? THEN 100 ELSE 200 END", (first,))
        newest = "SELECT path FROM sources WHERE ino=? ORDER BY seen_ns DESC LIMIT 1"
        ino = os.stat(first).st_ino
        before = (self.records(), self.query(newest, (ino,)))
        summary = self.run_pass()
        self.assertEqual(summary["device_filled"], 2)
        after = (self.records(), self.query(newest, (ino,)))
        self.assertEqual(before[1], after[1])
        self.assertEqual(before[1], [(second,)])
        self.assertEqual([row[:5] for row in before[0]], [row[:5] for row in after[0]])

    def test_a_stored_device_that_differs_is_refreshed_and_the_shortcut_follows(self):
        self.populate()
        self.run_pass()
        device = os.stat(self.claude).st_dev
        self.write("UPDATE sources SET dev=?", (device + 7,))
        before = self.records()
        filled = self.run_pass()
        self.assertEqual(filled["device_filled"], 3)
        self.assertEqual({row[5] for row in self.records()}, {device})
        self.assertEqual([row[:5] for row in before], [row[:5] for row in self.records()])
        self.assertEqual(self.run_pass()["device_filled"], 0)          # a matching device is not written again
        self.move()
        with self.no_full_comparison():
            self.assertEqual(self.run_pass()["moved"], 3)

    def test_plan_still_writes_nothing_on_a_read_only_state(self):
        self.populate()
        self.pre_migration_state()
        state = os.path.join(self.store, "state.sqlite3")
        before, rows = Path(state).read_bytes(), self.records()
        archive = A.Archive(self.store, self.roots, readonly=True)
        try:
            for full in (True, False):
                work, _, _, _ = archive.plan(full)
                self.assertEqual(work, {})
                self.assertEqual(len(archive.fills), 3)
        finally:
            archive.close()
        self.assertEqual((Path(state).read_bytes(), self.records()), (before, rows))

    def test_plan_on_a_read_only_state_without_the_device_column_collects_nothing(self):
        self.populate()
        self.run_pass()
        self.strip_device_column()
        archive = A.Archive(self.store, self.roots, readonly=True)
        try:
            archive.plan(True)
            archive.plan(False)
            self.assertEqual(archive.fills, [])
        finally:
            archive.close()

    def test_the_fill_is_written_inside_the_pass_transaction(self):
        self.populate()
        self.pre_migration_state()
        statements = []
        archive = self.archive()
        archive.db.set_trace_callback(statements.append)
        try:
            summary = archive.capture()
        finally:
            archive.close()
        self.assertEqual(summary["device_filled"], 3)
        depth, inside = 0, []
        for sql in statements:
            word = sql.split(None, 1)[0].upper() if sql.strip() else ""
            if word == "BEGIN":
                depth += 1
            elif word in ("COMMIT", "END"):
                depth -= 1
            elif sql.startswith("UPDATE sources SET dev"):
                inside.append(depth)
        self.assertEqual(inside, [1, 1, 1])

    def test_the_pass_summary_carries_the_counter(self):
        self.populate()
        self.run_pass()
        self.assertEqual(self.run_pass()["device_filled"], 0)
        self.assertIn("device_filled", A.COUNTERS)
        reader = A.Archive(self.store, [], readonly=True)
        try:
            self.assertEqual(reader.status()["last_pass"]["device_filled"], 0)
        finally:
            reader.close()


if __name__ == "__main__":
    unittest.main()
