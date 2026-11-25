#!/usr/bin/env python3
"""session-archive: an append-only, compressed copy of agent session transcripts.

Agent transcripts are the only full record of what an agent did, and the agents
delete their own (Claude Code after 30 days by default). Each `capture` pass
walks the transcript roots by metadata only, reads just the bytes a file has
gained since the last pass, and appends them as one zstd frame to that file's
store file. A store file is a plain sequence of zstd frames, so
`zstd -dc FILE` prints the transcript.

Rules the code keeps:

  * Bytes are only added. A source is saved once some stored version starts
    with all of its bytes. A source that was rewritten starts a new version
    beside the old one. Deleting a source changes nothing here, and no command
    in this file removes a store file or any byte zstd can decode.
  * The store outranks the state. state.sqlite3 only caches cursors. When it
    disagrees with a store file, the store file is decoded and the cursor is
    moved to match it. A trailing partial frame (an append cut short by a kill)
    is moved to `<store file>.partial`, never dropped.
  * The quick check (the last 4 KiB before the cursor) is trusted only for a
    `.jsonl` file that grew, on the same inode, when no other path has moved
    its stream. Every other case compares the whole stored prefix with the
    source: another project folder holding the same file, a rewritten or
    touched file, a state file that was lost or restored.
  * The cursor moves only after the appended frame is fsynced. A compressor
    failure, a full disk or an unreadable source leaves that file's cursor
    where it was and the pass goes on.

  * Each pass also checks that every live source's store file still has the
    size the state recorded. A store file that was deleted, cut or damaged is
    reported once, and its sources are stored again while they still exist.
  * Below the free-space floor a pass stores nothing more and exits 1, so the
    archive is never what fills the disk and a stalled archive is not silent.

What a pass does NOT prove: an edit inside a growing `.jsonl` that keeps the
4 KiB before the cursor is not seen, and neither is a store file changed
without changing its size. `verify` compares whole files on demand.

Usage:
  session-archive.py capture [--max-bytes N] [--max-seconds N] [--min-free-bytes N] [--json]
  session-archive.py status [--json]
  session-archive.py verify [--max-bytes N] [PATH ...]
  session-archive.py where PATH
  session-archive.py cat PATH [--version N]

Common options: --store DIR, --root AGENT=DIR[:DEPTH] (repeatable; replaces
the built-in roots; DEPTH is the number of leading folders left out of a
file's key, 1 for a per-project folder).

Store: $SESSION_ARCHIVE_DIR, else ${XDG_DATA_HOME:-~/.local/share}/session-archive.
Environment: SESSION_ARCHIVE_MAX_BYTES, SESSION_ARCHIVE_MAX_SECONDS,
SESSION_ARCHIVE_MIN_FREE_BYTES.
Exit: 0 ok, also when another capture holds the lock · 1 a store or source
error was counted, the disk is below the free-space floor with files still to
store, or verify found a difference · 2 usage · 3 zstd is missing.
"""
from __future__ import annotations

import argparse
import collections
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, replace
from typing import Callable, Iterator, Optional

TAIL = 4096                    # bytes before the cursor that a growing source must still match
CHUNK = 1 << 20
LONG_MIN = 8 << 20             # appends this large get zstd's long-distance window
COMMIT_EVERY = 100             # files per state commit; the store is fsynced per file
DEFAULT_MAX_BYTES = 8 << 30    # bytes read or decoded per pass before the rest waits for the next one
DEFAULT_MAX_SECONDS = 15 * 60  # a pass takes no new file after storing this long (the unit's timeout is 45 min)
DEFAULT_MIN_FREE = 10 << 30    # free bytes on the store's disk below which a pass stores nothing more
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
ZSTD = shutil.which("zstd")

# agent, folder below $HOME, leading folders left out of the key. Claude Code,
# pi and factory keep one folder per working directory, and a session's files
# move between those folders, so the folder is not part of a file's identity.
DEFAULT_ROOTS = (
    ("claude", ".claude/projects", 1),
    ("codex", ".codex/sessions", 0),
    ("pi", ".pi/agent/sessions", 1),
    ("factory", ".factory/sessions", 1),
)

COUNTERS = ("scanned", "changed", "appended", "streams", "versions", "proved", "covered", "adopted",
            "reconciled", "partial_frames_set_aside", "deferred", "skipped", "source_errors",
            "store_errors", "low_disk", "bytes_read", "bytes_stored")


class StoreError(Exception):
    """The archive could not be written or read; the pass counts it and exits 1."""


class SourceError(Exception):
    """A transcript could not be read; the pass counts it and exits 1."""


class Skipped(Exception):
    """A transcript disappeared or changed while it was read; the next pass takes it."""


@dataclass(frozen=True)
class Root:
    agent: str
    path: str
    depth: int


@dataclass(frozen=True)
class Stream:
    id: int
    agent: str
    key: str
    version: int
    content_bytes: int
    store_bytes: int
    tail: bytes
    broken: int


def log(message: str) -> None:
    print(f"session-archive: {message}", file=sys.stderr)


def tail_hash(data: bytes) -> bytes:
    return hashlib.blake2b(data[-TAIL:], digest_size=16).digest()


def followed(agent: str, parts: tuple) -> bool:
    """Is this file part of a session's record? `parts` is its path below the root."""
    name = parts[-1]
    if name.endswith(".jsonl"):
        return True
    if agent != "claude":
        return False
    if name.endswith(".meta.json"):
        return True
    parent = parts[-2] if len(parts) > 1 else ""
    # workflows/*.json is a workflow's state. tool-results/ holds output too
    # large for the transcript, which keeps only a preview and the file's path.
    return parent == "tool-results" or (parent == "workflows" and name.endswith(".json"))


def walk(root: Root) -> Iterator[tuple]:
    """Yield (key, path, stat) for each followed regular file. Metadata only; symlinks are not followed."""
    stack = [(root.path, ())]
    while stack:
        directory, parts = stack.pop()
        try:
            entries = os.scandir(directory)
        except OSError:
            continue
        with entries:
            for entry in entries:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        stack.append((entry.path, parts + (entry.name,)))
                    elif entry.is_file(follow_symlinks=False):
                        rel = parts + (entry.name,)
                        if len(rel) > root.depth and followed(root.agent, rel):
                            yield "/".join(rel[root.depth:]), entry.path, entry.stat(follow_symlinks=False)
                except OSError:
                    continue


def frame_scan(path: str, size: int) -> int:
    """Offset where the last structurally complete zstd frame ends (RFC 8878).

    Only used to find where a trailing partial frame starts; zstd itself decides
    whether the bytes before it are sound (see Archive.reconcile).
    """
    good = 0
    with open(path, "rb") as fh:
        while good + 5 <= size:
            fh.seek(good)
            head = fh.read(5)
            if len(head) < 5 or head[:4] != ZSTD_MAGIC:
                break
            descriptor = head[4]
            single = (descriptor >> 5) & 1
            pos = good + 5 + (0 if single else 1) + (0, 1, 2, 4)[descriptor & 3] + (
                (1 if single else 0), 2, 4, 8)[descriptor >> 6]
            complete = False
            while pos + 3 <= size:
                fh.seek(pos)
                block = int.from_bytes(fh.read(3), "little")
                kind = (block >> 1) & 3
                if kind == 3:
                    break
                pos += 3 + (1 if kind == 1 else block >> 3)
                if block & 1:
                    complete = True
                    break
            if not complete:
                break
            if (descriptor >> 2) & 1:
                pos += 4
            if pos > size:
                break
            good = pos
    return good


def decode(path: str, upto: Optional[int] = None) -> Iterator[bytes]:
    """Yield the decoded content of a store file (of its first `upto` bytes when given).

    Raises StoreError when zstd rejects the input.
    """
    try:
        fh = open(path, "rb")
    except OSError as error:
        raise StoreError(f"cannot open {path}: {error}") from error
    feeder = None
    try:
        if upto is None:
            proc = subprocess.Popen([ZSTD, "-dcq"], stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        else:
            proc = subprocess.Popen([ZSTD, "-dcq"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)

            def feed() -> None:
                left = upto
                try:
                    while left > 0:
                        data = fh.read(min(CHUNK, left))
                        if not data:
                            break
                        proc.stdin.write(data)
                        left -= len(data)
                except (OSError, ValueError):
                    pass
                finally:
                    try:
                        proc.stdin.close()
                    except OSError:
                        pass

            feeder = threading.Thread(target=feed, daemon=True)
            feeder.start()
    except OSError as error:
        fh.close()
        raise StoreError(f"cannot start zstd for {path}: {error}") from error
    finished = False
    try:
        while True:
            chunk = proc.stdout.read(CHUNK)
            if not chunk:
                break
            yield chunk
        finished = True
    finally:
        proc.stdout.close()
        if not finished:
            proc.kill()
        if feeder is not None:
            feeder.join()
        detail = proc.stderr.read().decode("utf-8", "replace").strip()
        proc.stderr.close()
        code = proc.wait()
        fh.close()
    if code != 0:
        raise StoreError(f"zstd cannot decode {path}: {detail or 'exit %d' % code}")


def measure(path: str, upto: Optional[int] = None) -> tuple:
    """(decoded length, tail hash) of a store file."""
    length = 0
    tail = b""
    for chunk in decode(path, upto):
        length += len(chunk)
        tail = (tail + chunk)[-TAIL:]
    return length, tail_hash(tail)


def fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def range_hash(fd: int, start: int, end: int) -> Optional[bytes]:
    """Hash of the source bytes [start, end), or None when they cannot all be read."""
    hasher = hashlib.blake2b(digest_size=16)
    offset = start
    while offset < end:
        try:
            chunk = os.pread(fd, min(CHUNK, end - offset), offset)
        except OSError:
            return None
        if not chunk:
            return None
        hasher.update(chunk)
        offset += len(chunk)
    return hasher.digest()


class Archive:
    def __init__(self, store: str, roots: list, max_bytes: int = DEFAULT_MAX_BYTES, min_free: int = 0,
                 max_seconds: int = 0):
        self.store = store
        self.data = os.path.join(store, "data")
        self.roots = roots
        self.max_bytes = max_bytes
        self.min_free = min_free          # 0: no floor
        self.max_seconds = max_seconds    # 0: no limit
        self.spent = 0
        self.n: collections.Counter = collections.Counter()
        # Test seam: runs after a frame is durable and before its cursor is saved.
        self.after_store_write: Callable[[], None] = lambda: None
        os.makedirs(self.data, mode=0o700, exist_ok=True)
        self.db = sqlite3.connect(os.path.join(store, "state.sqlite3"), isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS streams(
              id INTEGER PRIMARY KEY, agent TEXT NOT NULL, key TEXT NOT NULL, version INTEGER NOT NULL,
              content_bytes INTEGER NOT NULL, store_bytes INTEGER NOT NULL, tail BLOB NOT NULL,
              broken INTEGER NOT NULL DEFAULT 0, UNIQUE(agent, key, version));
            CREATE TABLE IF NOT EXISTS sources(
              path TEXT PRIMARY KEY, stream INTEGER NOT NULL, size INTEGER NOT NULL,
              mtime_ns INTEGER NOT NULL, ino INTEGER NOT NULL, seen_ns INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
            """)

    def close(self) -> None:
        self.db.close()

    # ---- state ---------------------------------------------------------------

    def path_for(self, agent: str, key: str, version: int) -> str:
        suffix = ".zst" if version == 1 else f".v{version}.zst"
        return os.path.join(self.data, agent, key[:2], key + suffix)

    def stream_path(self, stream: Stream) -> str:
        return self.path_for(stream.agent, stream.key, stream.version)

    _COLUMNS = "id, agent, key, version, content_bytes, store_bytes, tail, broken"

    def stream_by_id(self, stream_id: int) -> Optional[Stream]:
        row = self.db.execute(f"SELECT {self._COLUMNS} FROM streams WHERE id=?", (stream_id,)).fetchone()
        return Stream(*row) if row else None

    def save(self, stream: Stream, content_bytes: int, store_bytes: int, tail: bytes, broken: int = 0) -> Stream:
        self.db.execute("UPDATE streams SET content_bytes=?, store_bytes=?, tail=?, broken=? WHERE id=?",
                        (content_bytes, store_bytes, tail, broken, stream.id))
        return replace(stream, content_bytes=content_bytes, store_bytes=store_bytes, tail=tail, broken=broken)

    def mark_broken(self, stream: Stream) -> Stream:
        self.n["store_errors"] += 1
        log("store file does not decode and is left untouched; new bytes go to a new version: "
            + self.stream_path(stream))
        return self.save(stream, stream.content_bytes, stream.store_bytes, stream.tail, broken=1)

    def new_stream(self, agent: str, key: str, version: int) -> Stream:
        empty = tail_hash(b"")
        cursor = self.db.execute(
            "INSERT INTO streams(agent, key, version, content_bytes, store_bytes, tail) VALUES (?,?,?,0,0,?)",
            (agent, key, version, empty))
        return Stream(cursor.lastrowid, agent, key, version, 0, 0, empty, 0)

    def versions(self, agent: str, key: str) -> list:
        """Every version of a key, reconciled with the store, including store files the state has no row for."""
        rows = [Stream(*row) for row in self.db.execute(
            f"SELECT {self._COLUMNS} FROM streams WHERE agent=? AND key=?", (agent, key))]
        have = {stream.version for stream in rows}
        top = max(have, default=0)
        version = 1
        while version <= top or os.path.exists(self.path_for(agent, key, version)):
            if version not in have and os.path.exists(self.path_for(agent, key, version)):
                rows.append(self.new_stream(agent, key, version))
                self.n["adopted"] += 1
            version += 1
        return [self.reconcile(stream) for stream in rows]

    def reconcile(self, stream: Stream) -> Stream:
        """Make the cursor agree with the store file. The store file wins."""
        if stream.broken:
            return stream
        path = self.stream_path(stream)
        try:
            actual = os.stat(path).st_size
        except FileNotFoundError:
            actual = 0
        if actual == stream.store_bytes:
            return stream
        self.n["reconciled"] += 1
        if actual < stream.store_bytes:
            # Nothing here shortens a store file below what the state recorded,
            # so this one was deleted, cut or replaced from outside. It is said
            # once; a source that still exists is stored again from where the
            # file now ends.
            self.n["store_errors"] += 1
            log(f"store file is shorter than the state recorded ({actual} < {stream.store_bytes} bytes), "
                f"its cursor moves back: {path}")
        if actual == 0:
            return self.save(stream, 0, 0, tail_hash(b""))
        try:
            length, tail = measure(path)
            self.spent += length
            return self.save(stream, length, actual, tail)
        except StoreError:
            pass
        # zstd rejects the file as a whole. When everything before a trailing
        # partial frame decodes, that frame is what an interrupted append left:
        # it is moved to a side file and the store file ends at the last whole
        # frame. Anything else is left exactly as it is.
        good = frame_scan(path, actual)
        if 0 < good < actual:
            try:
                length, tail = measure(path, good)
            except StoreError:
                return self.mark_broken(stream)
            self.set_aside(path, good)
            self.n["partial_frames_set_aside"] += 1
            self.spent += length
            log(f"moved a partial trailing frame ({actual - good} bytes) to {path}.partial")
            return self.save(stream, length, good, tail)
        return self.mark_broken(stream)

    @staticmethod
    def set_aside(path: str, good: int) -> None:
        """Move the bytes after offset `good` to `<path>.partial`, durably, before the store file is cut."""
        try:
            side = os.open(path + ".partial", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC, 0o600)
            with os.fdopen(side, "ab") as out, open(path, "r+b") as fh:
                fh.seek(good)
                shutil.copyfileobj(fh, out, CHUNK)
                out.flush()
                os.fsync(out.fileno())
                fh.truncate(good)
                os.fsync(fh.fileno())
        except OSError as error:
            raise StoreError(f"cannot set aside the partial frame of {path}: {error}") from error

    # ---- capture -------------------------------------------------------------

    def continues(self, fd: int, size: int, stream: Stream) -> Optional[bytes]:
        """The source bytes just before the stream's cursor when they match it, else None."""
        if stream.broken or size < stream.content_bytes:
            return None
        span = min(TAIL, stream.content_bytes)
        window = os.pread(fd, span, stream.content_bytes - span) if span else b""
        return window if tail_hash(window) == stream.tail else None

    def same_bytes(self, fd: int, stream: Stream, length: int) -> bool:
        """Full comparison: are the first `length` stored bytes the first `length` source bytes?"""
        if length == 0:
            return True
        offset = 0
        for chunk in decode(self.stream_path(stream)):
            chunk = chunk[:length - offset]
            if os.pread(fd, len(chunk), offset) != chunk:
                self.spent += offset
                return False
            offset += len(chunk)
            if offset >= length:
                break
        self.spent += offset
        return offset == length

    def find_or_create(self, agent: str, key: str, fd: int, size: int) -> tuple:
        """The version this source belongs to, proven by a full comparison, or a new one."""
        versions = self.versions(agent, key)
        for candidate in sorted(versions, key=lambda item: -item.version):
            if candidate.broken:
                continue
            try:
                if size >= candidate.content_bytes:
                    window = self.continues(fd, size, candidate)
                    if window is not None and self.same_bytes(fd, candidate, candidate.content_bytes):
                        self.n["proved"] += 1 if candidate.content_bytes else 0
                        return candidate, window
                elif self.same_bytes(fd, candidate, size):
                    self.n["covered"] += 1       # every byte of this source is already stored
                    return candidate, b""
            except StoreError:
                self.mark_broken(candidate)
        version = max((item.version for item in versions), default=0) + 1
        self.n["versions" if version > 1 else "streams"] += 1
        return self.new_stream(agent, key, version), b""

    def append(self, stream: Stream, fd: int, snap: os.stat_result, window: bytes) -> Stream:
        """Compress source bytes [cursor, snap.st_size) onto the stream's store file as one frame."""
        path = self.stream_path(stream)
        start, end = stream.content_bytes, snap.st_size
        command = [ZSTD, "-q", "-c", "-3", "-T1"] + (["--long=27"] if end - start >= LONG_MIN else [])
        try:
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
            created = not os.path.exists(path)
            out_fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC, 0o600)
        except OSError as error:
            raise StoreError(f"cannot open {path}: {error}") from error
        with os.fdopen(out_fd, "ab") as out:
            before = os.fstat(out.fileno()).st_size
            if before != stream.store_bytes:
                raise StoreError(f"store file changed during the pass: {path}")
            try:
                proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=out, stderr=subprocess.PIPE)
            except OSError as error:
                raise StoreError(f"cannot start zstd: {error}") from error
            failure: Optional[Exception] = None
            hasher = hashlib.blake2b(digest_size=16)
            tail = window
            offset = start
            try:
                while offset < end and failure is None:
                    try:
                        chunk = os.pread(fd, min(CHUNK, end - offset), offset)
                    except OSError as error:
                        failure = SourceError(f"read failed: {error}")
                        break
                    if not chunk:
                        failure = Skipped("the source shrank while it was read")
                        break
                    proc.stdin.write(chunk)
                    hasher.update(chunk)
                    tail = (tail + chunk)[-TAIL:]
                    offset += len(chunk)
            except OSError:
                pass                     # zstd went away; its exit code and stderr say why
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass
            detail = proc.stderr.read().decode("utf-8", "replace").strip()
            proc.stderr.close()
            code = proc.wait()
            if failure is None and (code != 0 or offset < end):
                failure = StoreError(f"zstd failed writing {path}: {detail or 'exit %d' % code}")
            if failure is None:
                # The source may have been written while it was read. An append is
                # fine; a rewrite is not, and both move the mtime. Accept only when
                # the bytes that were read, and the bytes before them, are still there.
                now = os.fstat(fd)
                if (now.st_size, now.st_mtime_ns) != (snap.st_size, snap.st_mtime_ns):
                    span = len(window)
                    try:
                        still = now.st_size >= end and range_hash(fd, start, end) == hasher.digest() and (
                            tail_hash(os.pread(fd, span, start - span) if span else b"") == stream.tail)
                    except OSError:
                        still = False
                    if not still:
                        failure = Skipped("the source was rewritten while it was read")
            if failure is None:
                try:
                    out.flush()
                    os.fsync(out.fileno())
                except OSError as error:
                    failure = StoreError(f"cannot sync {path}: {error}")
            if failure is not None:
                # Take back only what this attempt wrote. Nothing committed is touched.
                try:
                    os.ftruncate(out.fileno(), before)
                except OSError:
                    pass
                raise failure
            after = os.fstat(out.fileno()).st_size
        if created:
            try:
                fsync_dir(os.path.dirname(path))
            except OSError as error:
                raise StoreError(f"cannot sync the folder of {path}: {error}") from error
        self.after_store_write()
        self.spent += end - start
        self.n["bytes_read"] += end - start
        self.n["bytes_stored"] += after - before
        self.n["appended"] += 1
        return self.save(stream, end, after, tail_hash(tail))

    def capture_one(self, agent: str, key: str, path: str, seen: Optional[tuple]) -> None:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        except FileNotFoundError as error:
            raise Skipped("the source is gone") from error
        except OSError as error:
            raise SourceError(f"cannot open: {error}") from error
        try:
            snap = os.fstat(fd)
            if not stat.S_ISREG(snap.st_mode):
                return
            stream = self.stream_by_id(seen[0]) if seen else None
            window = None
            if stream is not None:
                stream = self.reconcile(stream)
                # The quick check is enough only for an append-only file that grew in
                # place while no other path moved its stream. `seen` is
                # (stream, size, mtime_ns, ino) from this path's last pass.
                if (key.endswith(".jsonl") and snap.st_size > stream.content_bytes
                        and stream.content_bytes == seen[1] and snap.st_ino == seen[3]):
                    window = self.continues(fd, snap.st_size, stream)
            if window is None:
                stream, window = self.find_or_create(agent, key, fd, snap.st_size)
            if snap.st_size > stream.content_bytes:
                stream = self.append(stream, fd, snap, window)
            self.db.execute(
                "INSERT OR REPLACE INTO sources(path, stream, size, mtime_ns, ino, seen_ns) VALUES (?,?,?,?,?,?)",
                (path, stream.id, snap.st_size, snap.st_mtime_ns, snap.st_ino, time.time_ns()))
        finally:
            os.close(fd)

    def store_agrees(self, stream_id: int, streams: dict, checked: dict) -> bool:
        """Does this stream's store file still have the size the state recorded? One stat per stream."""
        if stream_id not in checked:
            row = streams.get(stream_id)
            agrees = False
            if row is not None and not row[4]:
                try:
                    actual = os.stat(self.path_for(row[0], row[1], row[2])).st_size
                except OSError:
                    actual = 0
                agrees = actual == row[3]
            checked[stream_id] = agrees
        return checked[stream_id]

    def low_disk(self) -> bool:
        return bool(self.min_free) and shutil.disk_usage(self.store).free < self.min_free

    def capture(self) -> dict:
        started = time.time()
        known = {row[0]: row[1:] for row in self.db.execute(
            "SELECT path, stream, size, mtime_ns, ino FROM sources")}
        streams = {row[0]: row[1:] for row in self.db.execute(
            "SELECT id, agent, key, version, store_bytes, broken FROM streams")}
        checked: dict = {}
        work = []
        for root in self.roots:
            for key, path, st in walk(root):
                self.n["scanned"] += 1
                seen = known.get(path)
                # A file is left alone when it is as the last pass saw it AND its
                # store file is as the last pass left it. A store file that is
                # gone, cut, damaged or marked broken sends its sources back
                # through capture_one, which stores them again.
                if (seen and seen[1:] == (st.st_size, st.st_mtime_ns, st.st_ino)
                        and self.store_agrees(seen[0], streams, checked)):
                    continue
                work.append((st.st_mtime_ns, path, root.agent, key))
        work.sort()          # oldest first: the files nearest deletion are saved first
        self.n["changed"] = len(work)
        self.db.execute("BEGIN")
        uncommitted = 0
        # The time budget starts here, after the walk. Counted from the start of
        # the pass, a walk that outlasts the budget (a cold directory cache on a
        # busy disk) would store nothing and exit 0, pass after pass. The walk
        # is bounded by the unit's own timeout instead, which pages.
        clock = time.monotonic()
        for index, (_, path, agent, key) in enumerate(work):
            # Both budgets end the pass between files; what is left waits for the
            # next pass.
            if self.spent >= self.max_bytes or (
                    self.max_seconds and time.monotonic() - clock >= self.max_seconds):
                self.n["deferred"] = len(work) - index
                break
            if self.low_disk():
                self.n["low_disk"] = 1
                self.n["deferred"] = len(work) - index
                log(f"free space on the store's disk is below {self.min_free} bytes; "
                    f"{len(work) - index} file(s) are not stored this pass")
                break
            try:
                self.capture_one(agent, key, path, known.get(path))
            except Skipped:
                self.n["skipped"] += 1
            except SourceError as error:
                self.n["source_errors"] += 1
                log(f"{path}: {error}")
            except StoreError as error:
                self.n["store_errors"] += 1
                log(str(error))
            uncommitted += 1
            if uncommitted >= COMMIT_EVERY:
                self.db.execute("COMMIT")
                self.db.execute("BEGIN")
                uncommitted = 0
        summary = {name: self.n[name] for name in COUNTERS}
        summary["seconds"] = round(time.time() - started, 2)
        summary["at"] = int(time.time())
        self.db.execute("INSERT OR REPLACE INTO meta(k, v) VALUES ('last_pass', ?)", (json.dumps(summary),))
        self.db.execute("COMMIT")
        return summary

    # ---- read side -----------------------------------------------------------

    def status(self) -> dict:
        streams, content, stored, broken = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(content_bytes), 0), COALESCE(SUM(store_bytes), 0), "
            "COALESCE(SUM(broken), 0) FROM streams").fetchone()
        sources = self.db.execute("SELECT COUNT(*) FROM sources").fetchone()[0]
        last = self.db.execute("SELECT v FROM meta WHERE k='last_pass'").fetchone()
        return {"store": self.store, "streams": streams, "sources": sources, "content_bytes": content,
                "store_bytes": stored, "broken_streams": broken,
                "ratio": round(content / stored, 2) if stored else None,
                "last_pass": json.loads(last[0]) if last else None}

    def bound(self, path: str) -> Optional[tuple]:
        """(stream, size) recorded for a source path: its bytes are the first `size` bytes of the stream."""
        row = self.db.execute("SELECT stream, size FROM sources WHERE path=?", (path,)).fetchone()
        if not row:
            return None
        stream = self.stream_by_id(row[0])
        return (stream, row[1]) if stream else None

    def read(self, stream: Stream, length: Optional[int] = None) -> Iterator[bytes]:
        """The stream's content, or its first `length` bytes."""
        left = stream.content_bytes if length is None else min(length, stream.content_bytes)
        if left <= 0:
            return
        for chunk in decode(self.stream_path(stream)):
            chunk = chunk[:left]
            yield chunk
            left -= len(chunk)
            if left <= 0:
                break

    def verify(self, paths: list, max_bytes: int) -> dict:
        """Compare stored content with the live source, byte for byte, newest captures first."""
        result: collections.Counter = collections.Counter()
        differences = []
        wanted = set(paths)
        rows = self.db.execute(
            "SELECT path, stream, size, mtime_ns, ino FROM sources ORDER BY seen_ns DESC").fetchall()
        for path, stream_id, size, mtime_ns, ino in rows:
            if wanted and path not in wanted:
                continue
            if result["bytes"] >= max_bytes:
                result["not_reached"] += 1
                continue
            stream = self.stream_by_id(stream_id)
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            except OSError:
                result["source_gone"] += 1
                continue
            try:
                now = os.fstat(fd)
                if (now.st_size, now.st_mtime_ns, now.st_ino) != (size, mtime_ns, ino):
                    result["changed_since_capture"] += 1
                    continue
                offset = 0
                same = stream is not None
                try:
                    for chunk in self.read(stream, size) if same else ():
                        if os.pread(fd, len(chunk), offset) != chunk:
                            same = False
                            break
                        offset += len(chunk)
                except StoreError as error:
                    same = False
                    log(str(error))
                same = same and offset == size
                result["bytes"] += offset
                result["same" if same else "different"] += 1
                if not same:
                    differences.append(path)
            finally:
                os.close(fd)
        report = {name: result[name] for name in (
            "same", "different", "changed_since_capture", "source_gone", "not_reached", "bytes")}
        report["differences"] = differences
        return report


def default_store() -> str:
    explicit = os.environ.get("SESSION_ARCHIVE_DIR")
    if explicit:
        return explicit
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "session-archive")


def parse_roots(values: Optional[list]) -> list:
    if not values:
        home = os.path.expanduser("~")
        return [Root(agent, os.path.join(home, rel), depth) for agent, rel, depth in DEFAULT_ROOTS]
    roots = []
    for value in values:
        agent, _, rest = value.partition("=")
        path, depth = rest, "0"
        if ":" in rest and rest.rsplit(":", 1)[-1].isdigit():
            path, depth = rest.rsplit(":", 1)
        if not agent or not path or "/" in agent:
            raise SystemExit(f"session-archive: --root wants AGENT=DIR[:DEPTH], got {value!r}")
        roots.append(Root(agent, os.path.abspath(os.path.expanduser(path)), int(depth)))
    return roots


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="session-archive.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--store", default=None, help="archive folder (default: $SESSION_ARCHIVE_DIR, "
                        "else ${XDG_DATA_HOME:-~/.local/share}/session-archive)")
    parser.add_argument("--root", action="append", metavar="AGENT=DIR[:DEPTH]",
                        help="follow this folder instead of the built-in roots (repeatable)")
    sub = parser.add_subparsers(dest="command", required=True)
    capture = sub.add_parser("capture", help="one pass: save what every followed file has gained")
    capture.add_argument("--max-bytes", type=int,
                         default=int(os.environ.get("SESSION_ARCHIVE_MAX_BYTES") or DEFAULT_MAX_BYTES),
                         help="stop taking new files once this many bytes were read or decoded")
    capture.add_argument("--max-seconds", type=int,
                         default=int(os.environ.get("SESSION_ARCHIVE_MAX_SECONDS") or DEFAULT_MAX_SECONDS),
                         help="stop taking new files once the pass has been storing this long, "
                         "not counting the walk before it (0: no limit)")
    capture.add_argument("--min-free-bytes", type=int,
                         default=int(os.environ.get("SESSION_ARCHIVE_MIN_FREE_BYTES") or DEFAULT_MIN_FREE),
                         help="store nothing more, and exit 1, once the store's disk has less free space "
                         "than this (0 turns the floor off)")
    capture.add_argument("--json", action="store_true")
    status = sub.add_parser("status", help="counts and the last pass, from the state file")
    status.add_argument("--json", action="store_true")
    verify = sub.add_parser("verify", help="compare stored bytes with live sources, newest captures first")
    verify.add_argument("--max-bytes", type=int, default=2 << 30)
    verify.add_argument("paths", nargs="*")
    where = sub.add_parser("where", help="print the store file(s) for a source path")
    where.add_argument("path")
    cat = sub.add_parser("cat", help="print the stored bytes for a source path")
    cat.add_argument("path")
    cat.add_argument("--version", type=int, default=None, help="print this whole version instead")
    return parser


def main(argv: Optional[list] = None) -> int:
    args = build_parser().parse_args(argv)
    if ZSTD is None:
        log("zstd is not on PATH; install it (apt install zstd, brew install zstd)")
        return 3
    os.umask(0o077)            # transcripts hold secrets; the archive is private to its owner
    store = args.store or default_store()
    os.makedirs(store, mode=0o700, exist_ok=True)
    archive = Archive(store, parse_roots(args.root), getattr(args, "max_bytes", DEFAULT_MAX_BYTES),
                      getattr(args, "min_free_bytes", 0), getattr(args, "max_seconds", 0))
    try:
        if args.command == "capture":
            lock = os.open(os.path.join(store, "lock"),
                           os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                log("another capture holds the lock; nothing to do")
                return 0
            summary = archive.capture()
            if args.json:
                print(json.dumps(summary, sort_keys=True))
            else:
                print("session-archive: " + " ".join(f"{name}={value}" for name, value in summary.items()))
            return 1 if summary["store_errors"] or summary["source_errors"] or summary["low_disk"] else 0
        if args.command == "status":
            report = archive.status()
            if args.json:
                print(json.dumps(report, sort_keys=True))
            else:
                for name, value in report.items():
                    print(f"{name}: {value}")
            return 0
        if args.command == "verify":
            report = archive.verify([os.path.abspath(path) for path in args.paths], args.max_bytes)
            print(json.dumps(report, sort_keys=True))
            return 1 if report["different"] else 0
        found = archive.bound(os.path.abspath(args.path))
        if found is None:
            log(f"no stored stream for {args.path}")
            return 1
        stream, size = found
        if args.command == "where":
            for item in sorted(archive.versions(stream.agent, stream.key), key=lambda one: one.version):
                mark = "*" if item.id == stream.id else " "
                print(f"{mark} v{item.version} {item.content_bytes} bytes {archive.stream_path(item)}")
            return 0
        length: Optional[int] = size
        if args.version is not None:
            match = [item for item in archive.versions(stream.agent, stream.key) if item.version == args.version]
            if not match:
                log(f"no version {args.version} for {args.path}")
                return 1
            stream, length = match[0], None
        for chunk in archive.read(stream, length):
            sys.stdout.buffer.write(chunk)
        return 0
    except StoreError as error:
        log(str(error))
        return 1
    finally:
        archive.close()


if __name__ == "__main__":
    sys.exit(main())
