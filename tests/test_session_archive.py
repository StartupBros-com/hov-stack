#!/usr/bin/env python3
"""Tests for session-archive.py.

The failure that matters for an archive is a byte that was in a transcript and
is not in the store, or a stored version that no transcript ever held. Every
test here runs the real zstd binary against real files; nothing about the store
is mocked. Stored bytes are read back with a plain `zstd -dc`, not with the
tool's own reader.
"""

import fcntl
import importlib.util
import json
import os
import random
import re
import shutil
import stat
import subprocess
import sys
import tempfile
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

        def slow_walk(root):
            now["t"] += 1000                                    # far past the budget
            yield from real_walk(root)

        with mock.patch.object(A.time, "monotonic", tick), mock.patch.object(A, "walk", slow_walk):
            summary = self.run_pass(max_seconds=25)
        self.assertEqual((summary["appended"], summary["deferred"]), (2, 1))


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

    def run_seed(self, seed):
        rng = random.Random(seed)
        observed, must_keep = {}, set()
        saved_state = None
        for step in range(45):
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
            crashed = rng.random() < 0.2
            if crashed:
                countdown = [rng.randrange(1, 4)]

                def hook():
                    countdown[0] -= 1
                    if countdown[0] == 0:
                        raise Crash()
                archive.after_store_write = hook
            try:
                summary = archive.capture()
                self.assertEqual(summary["store_errors"] + summary["source_errors"], 0, label)
                crashed = False
            except Crash:
                pass
            finally:
                archive.close()
            self.check_versions(observed, label)
            if crashed:
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

    def test_random_operations(self):
        for seed in (1, 2, 3, 4, 5, 6):
            with self.subTest(seed=seed):
                shutil.rmtree(self.store, ignore_errors=True)
                for root in (self.claude, self.codex):
                    shutil.rmtree(root)
                    os.makedirs(root)
                self.run_seed(seed)


class CommandLineTests(Case):
    def cli(self, *args, env=None, check=True):
        command = [sys.executable, str(SCRIPT), "--store", self.store,
                   "--root", "claude=%s:1" % self.claude, "--root", "codex=%s" % self.codex, *args]
        if env is None:
            # A CI runner can have less free disk than the shipped 10 GiB floor.
            env = dict(os.environ, SESSION_ARCHIVE_MIN_FREE_BYTES="0")
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


if __name__ == "__main__":
    unittest.main()
