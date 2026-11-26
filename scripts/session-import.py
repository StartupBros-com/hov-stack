#!/usr/bin/env python3
"""session-import.py: copy the transcripts cass's raw mirror holds into the session archive.

cass kept a byte copy of every transcript file it indexed (its "raw mirror").
For transcripts the agents have since deleted, that copy is the only one left,
and the session archive (session-archive.py), which started later, never saw
them. `mirror` reads the mirror's manifests and stores each transcript the
archive lacks, under the key the file would have had if a capture pass had
found it, so session-search.py indexes it like any other.

Rules the code keeps:

  * The archive's own code decides and writes. Each file goes through
    session-archive.py's `find_or_create` and `append`, under the archive's
    lock: a file the archive already holds (byte for byte, or as the start of a
    stored version) stores nothing, a file that continues a stored version
    appends to it, anything else starts a new version beside the others. No
    stored byte is changed or removed.
  * A mirror entry is stored whole or not at all. Its manifest must name the
    mirror format this was written for, every blob must exist at the size the
    manifest gives, and the blobs must add up to the recorded file size.
    Anything else is refused, counted and named on stderr.
  * No source path is recorded for an imported file, so a capture pass looks at
    nothing new. The file's original path is kept in the import's own ledger.
  * Captures go first. Reading the mirror and putting a chunked transcript
    together need no lock; the lock is held only while one file is compared
    and appended. A file is started only when the archive's next capture pass
    is further off than the file should take (its size at 16 MiB a second,
    plus 90 seconds); otherwise the import waits, lock released, until that
    pass has run. A file that takes longer than that estimate can still cost
    the archive one pass, which the pass after it makes up.
  * A file is stored only when the bytes it adds leave the disk at or above the
    free-space floor. When one does not fit, nothing more is stored and the
    run exits 1.
  * One import runs on a store at a time.

What a run does NOT prove: the mirror's blobs are trusted as cass wrote them
(they are named by a BLAKE3 hash this file cannot recompute with the standard
library); sizes are checked, hashes are not.

Which files: a manifest's original path is placed under a root the same way a
capture pass places a file (`--root AGENT=DIR[:DEPTH]`, as session-archive.py
takes it; default: its built-in roots). A path under no root, or a file a
capture pass would not follow, is counted and left in the mirror.

The ledger, `<store>/imports/cass-mirror.jsonl`, has one line per manifest
that was settled (stored, extended, new version, already held, empty): the
manifest's name, the outcome, the stream it landed in and the original path.
The next run skips those manifests, so a run cut short by a budget or a kill
is continued by running it again; `--recheck` compares them again. A manifest
that was refused or hit an error is not in the ledger and is tried again.
Before the first byte of a key the archive did not have is stored, a `begun`
line names that key, synced to disk: it is how a later run knows the key is
the import's own when a kill came between the store write and the row that
settles it.

Usage:
  session-import.py [--store DIR] [--root AGENT=DIR[:DEPTH]]... mirror [--mirror DIR]
                    [--plan] [--names FILE] [--new-keys-only] [--recheck] [--limit N]
                    [--max-seconds N] [--max-bytes N] [--min-free-bytes N]
                    [--capture-every N] [--scratch DIR] [--json]

  --plan           read manifests and metadata only and print what a run would do
  --names FILE     only the manifest file names listed in FILE, one per line
  --new-keys-only  only keys the archive did not have before the import; a key it
                   already had is left for a later run, which compares in full
  --capture-every  seconds between the archive's capture passes (0: never wait for one)
  --scratch        folder for the temporary copy of a transcript the mirror keeps in
                   chunks (default: the store's `imports` folder, on the store's disk)

Exit: 0 ok, also when a budget ended the run early · 1 an entry was refused, a
store error was counted, a named manifest is missing, a file did not fit above
the free-space floor, or another import is running · 2 usage · 3 zstd is missing.
"""
from __future__ import annotations

import argparse
import collections
import fcntl
import importlib.util
import json
import math
import os
import shutil
import sqlite3
import stat
import sys
import tempfile
import time
from collections.abc import Callable

HERE = os.path.dirname(os.path.abspath(__file__))
ARCHIVE_SCRIPT = os.path.join(HERE, "session-archive.py")
MANIFEST_KIND = "cass_raw_session_mirror_v1"
CHUNKED = "fixed_chunks_v1"
IMPORTS = "imports"
LEDGER = os.path.join(IMPORTS, "cass-mirror.jsonl")
SETTLED = ("stored", "extended", "new_version", "held", "empty")   # outcomes the ledger keeps
COPY = 1 << 20
DEFAULT_CAPTURE_EVERY = 600    # session-archive.timer fires every ten minutes
# The timer adds up to a minute of random delay, so two passes start between
# nine and eleven minutes apart. The import stops taking files SLOT_LEAD seconds
# before ten minutes are up and stops waiting SLOT_GRACE seconds after.
SLOT_LEAD = 90
SLOT_GRACE = 180
# What a file is assumed to manage under the lock when its run-up is sized: a
# full comparison with a stored version and one zstd pass, on a busy disk.
IMPORT_RATE = 16 << 20
BLOCKED = 5.0                  # a wait for the lock longer than this: something else was writing
RUN_LOCK = os.path.join(IMPORTS, "run.lock")
LEDGER_SYNC_EVERY = 50


class Refused(Exception):
    """A mirror entry that cannot be put together exactly as its manifest describes."""


class LowDisk(Exception):
    """The free-space floor was reached: the run stores nothing more."""


def log(message: str) -> None:
    print(f"session-import: {message}", file=sys.stderr)


def load_archive():
    """session-archive.py as a module: the store's layout and write rules live there."""
    name = "session_archive_for_import"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, ARCHIVE_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def default_mirror() -> str:
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "coding-agent-search", "raw-mirror", "v1")


# ---- the mirror ------------------------------------------------------------------

def whole_number(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def read_manifest(mirror: str, name: str) -> dict:
    """One manifest, or Refused when it is not a JSON object naming an original path."""
    try:
        with open(os.path.join(mirror, "manifests", name), "rb") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError, RecursionError) as error:
        raise Refused(f"manifest cannot be read: {type(error).__name__}: {str(error)[:200]}") from error
    if not isinstance(manifest, dict) or not isinstance(manifest.get("original_path"), str):
        raise Refused("manifest names no original path")
    if not encodable(manifest["original_path"]):
        raise Refused("the original path is not text a file name can hold")
    return manifest


def encodable(value: str) -> bool:
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def blob_refs(manifest: dict) -> list:
    """[(path below the mirror, size)] for the blobs that make up one captured file, in order."""
    if manifest.get("manifest_kind") != MANIFEST_KIND:
        raise Refused(f"manifest kind {manifest.get('manifest_kind')!r}")
    for field in ("compression", "encryption"):
        value = manifest.get(field)
        state = value.get("state") if isinstance(value, dict) else value
        if state not in (None, "none"):
            raise Refused(f"{field} state {state!r}")
    size = manifest.get("source_size_bytes")
    if not whole_number(size):
        raise Refused("no source size")
    storage = manifest.get("content_storage")
    if storage is None:
        entries = [manifest]
    elif isinstance(storage, dict) and storage.get("kind") == CHUNKED:
        entries = storage.get("chunks")
        if not isinstance(entries, list) or storage.get("content_size_bytes") != size:
            raise Refused("chunk list does not describe the recorded file size")
    else:
        raise Refused(f"storage kind {storage.get('kind') if isinstance(storage, dict) else storage!r}")
    refs = []
    for entry in entries:
        relative = entry.get("blob_relative_path") if isinstance(entry, dict) else None
        length = entry.get("blob_size_bytes") if isinstance(entry, dict) else None
        if not isinstance(relative, str) or not relative or not whole_number(length):
            raise Refused("a blob entry has no path or size")
        if "\0" in relative or not encodable(relative) or any(
                part in ("", ".", "..") for part in relative.split("/")):
            raise Refused("a blob path leaves the mirror")
        refs.append((relative, length))
    if sum(length for _, length in refs) != size:
        raise Refused("the blobs do not add up to the recorded file size")
    return refs


def check_blobs(mirror: int, refs: list) -> None:
    """Refused unless every blob is a regular file of the size its manifest gives. Reads no content."""
    for relative, length in refs:
        open_blob(mirror, relative, length).close()


def open_blob(mirror: int, relative: str, length: int):
    """One blob, opened below the mirror's folder (an open descriptor) with no symbolic link followed
    at any step: a link inside the mirror cannot make a file from elsewhere part of a transcript."""
    parts = relative.split("/")
    folder = os.dup(mirror)
    try:
        for part in parts[:-1]:
            below = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=folder)
            os.close(folder)
            folder = below
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=folder)
    except OSError as error:
        raise Refused(f"blob {relative}: {error.strerror or error}") from error
    finally:
        os.close(folder)
    fh = os.fdopen(fd, "rb")
    found = os.fstat(fd)
    if not stat.S_ISREG(found.st_mode) or found.st_size != length:
        fh.close()
        raise Refused(f"blob {relative} is not a file of the {length} bytes its manifest gives")
    return fh


def open_content(mirror: int, refs: list, scratch: str):
    """An open file holding exactly the captured bytes: the blob itself, or the chunks put together.

    The copy of a chunked transcript has no name: it goes when it is closed, or
    with the process.
    """
    if len(refs) == 1:
        return open_blob(mirror, *refs[0])
    os.makedirs(scratch, mode=0o700, exist_ok=True)
    out = tempfile.TemporaryFile(dir=scratch)
    try:
        for relative, length in refs:
            copied = 0
            with open_blob(mirror, relative, length) as blob:
                while True:
                    data = blob.read(COPY)
                    if not data:
                        break
                    out.write(data)
                    copied += len(data)
            if copied != length:
                raise Refused(f"blob {relative} gave {copied} of its {length} bytes")
        out.flush()
    except BaseException:
        out.close()
        raise
    return out


def list_manifests(mirror: str, names: set | None, problem: Callable[[str, str], None]) -> list:
    """[(original path, captured at, name)], a path's captures together and oldest first.

    That order lets a file cass captured more than once as it grew extend one
    stored version. Only these three fields are kept: the mirror's manifests
    are half a gigabyte, and each is read again when its turn comes.
    """
    with os.scandir(os.path.join(mirror, "manifests")) as entries:
        listed = sorted(entry.name for entry in entries if entry.name.endswith(".json"))
    found = []
    for name in listed:
        if names is not None and name not in names:
            continue
        try:
            manifest = read_manifest(mirror, name)
        except Refused as error:
            problem(name, str(error))
            continue
        captured = manifest.get("captured_at_ms")
        found.append((manifest["original_path"], captured if whole_number(captured) else 0, name))
    found.sort()
    return found


def free_bytes(folder: str) -> int:
    """Free bytes on the disk a folder is on, or will be on once it is made."""
    while not os.path.exists(folder):
        folder = os.path.dirname(folder)
    return shutil.disk_usage(folder).free


def identity(A, roots: list, path: str) -> tuple:
    """('ok', agent, key), or ('outside_roots' | 'not_followed', None, None), as a capture pass would place it."""
    if "\0" in path or not os.path.isabs(path) or os.path.normpath(path) != path:
        return "outside_roots", None, None
    placed = A.Archive.place(path, roots)
    if placed is None or len(placed[1]) <= placed[0].depth:
        return "outside_roots", None, None
    root, parts = placed
    if not A.followed(root.agent, parts):
        return "not_followed", None, None
    return "ok", root.agent, "/".join(parts[root.depth:])


# ---- the import -------------------------------------------------------------------

class Importer:
    def __init__(self, A, store: str, roots: list, mirror: str, scratch: str | None = None,
                 min_free: int = 0, max_bytes: int = 0, max_seconds: int = 0, capture_every: int = 0,
                 recheck: bool = False, new_keys_only: bool = False, limit: int = 0,
                 clock: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep,
                 free: Callable[[str], int] | None = None):
        self.A = A
        self.store = store
        self.roots = roots
        self.mirror = mirror
        self.mirror_fd = -1
        self.free = free or free_bytes
        self.blocked_after = BLOCKED
        self.scratch = scratch or os.path.join(store, IMPORTS)
        self.min_free = min_free
        self.max_bytes = max_bytes
        self.max_seconds = max_seconds
        self.capture_every = capture_every
        self.recheck = recheck
        self.new_keys_only = new_keys_only
        self.limit = limit
        self.clock = clock
        self.sleep = sleep
        self.n: collections.Counter = collections.Counter()
        self.slot: float | None = None          # when the next capture pass is due
        self.slot_from: tuple | None = None     # the pass record `slot` was worked out from
        self.ours: set = set()                     # (agent, key) of keys an import began
        self.archive = None
        self.ledger = None
        self.unsynced = 0

    # ---- ledger --------------------------------------------------------------

    def ledger_path(self) -> str:
        return os.path.join(self.store, LEDGER)

    def read_ledger(self) -> set:
        """Names of the manifests an earlier run settled; fills `ours`. A line a kill cut short is not a row."""
        names = set()
        try:
            with open(self.ledger_path(), "rb") as fh:
                for line in fh:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    if row.get("outcome") in ("begun", "stored"):
                        self.ours.add((row.get("agent"), row.get("key")))
                    if row.get("outcome") in SETTLED:
                        names.add(row.get("manifest"))
        except FileNotFoundError:
            pass
        return names

    def open_ledger(self) -> None:
        os.makedirs(os.path.dirname(self.ledger_path()), mode=0o700, exist_ok=True)
        fd = os.open(self.ledger_path(), os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        self.ledger = os.fdopen(fd, "r+b")
        # A line a kill cut short would join the next one written: end it first.
        size = os.fstat(fd).st_size
        if size and os.pread(fd, 1, size - 1) != b"\n":
            self.ledger.write(b"\n")
            self.ledger.flush()

    def note(self, row: dict) -> None:
        self.ledger.write((json.dumps(row, sort_keys=True) + "\n").encode())
        self.ledger.flush()
        self.unsynced += 1
        if self.unsynced >= LEDGER_SYNC_EVERY:
            self.sync_ledger()

    def sync_ledger(self) -> None:
        if self.ledger is not None and self.unsynced:
            os.fsync(self.ledger.fileno())
            self.unsynced = 0

    def begin(self, row: dict) -> None:
        """Record, durably, that the import is about to create this key. Comes before the first store write,
        so no kill can leave a key the import made looking like one the archive had."""
        self.ledger.write((json.dumps({"manifest": row["manifest"], "agent": row["agent"], "key": row["key"],
                                       "outcome": "begun"}, sort_keys=True) + "\n").encode())
        self.ledger.flush()
        os.fsync(self.ledger.fileno())
        self.unsynced = 0
        self.ours.add((row["agent"], row["key"]))

    # ---- giving way to capture -------------------------------------------------

    def last_pass(self) -> tuple | None:
        """(end, start) of the archive's last capture pass, in seconds, or None when there has been none."""
        row = self.archive.db.execute("SELECT v FROM meta WHERE k='last_pass'").fetchone()
        if row is None:
            return None
        try:
            record = json.loads(row[0])
            end, took = float(record["at"]), float(record.get("seconds") or 0)
        except (ValueError, KeyError, TypeError, OverflowError):
            return None
        if not (math.isfinite(end) and math.isfinite(took)) or took < 0:
            return None
        return end, end - took

    def timer_seen(self, last: tuple | None, now: float) -> bool:
        """Does the state show a capture timer at work? Not when there was never a pass, or none for two intervals."""
        return last is not None and now - last[0] <= 2 * self.capture_every + SLOT_GRACE

    @staticmethod
    def lead(size: int) -> float:
        """How long before a pass is due a file of this size is no longer started."""
        return SLOT_LEAD + size // IMPORT_RATE

    def due(self, size: int) -> bool:
        """Is a capture pass due within this file's run-up?"""
        if not self.capture_every:
            return False
        last, now = self.last_pass(), self.clock()
        if not self.timer_seen(last, now):
            return False
        slot = self.slot if last == self.slot_from else last[1] + self.capture_every
        return slot - self.lead(size) <= now <= slot + SLOT_GRACE

    def give_way(self, size: int = 0) -> None:
        """Wait, holding nothing, while a capture pass is due.

        A capture pass takes the archive's lock without waiting and gives up
        when it is held, so an import holding it at that moment would cost the
        archive a pass. The next pass is due `capture_every` seconds after the
        last one started. A file is not started inside its run-up to that
        moment (`lead`): the import waits until the state shows a newer pass,
        or SLOT_GRACE seconds have gone by with none, and then starts the file
        at once, which is the longest run-up there is. A store whose last pass
        is more than two intervals old has no timer running, and is not waited
        for.
        """
        if not self.capture_every:
            return
        waited = False
        while True:
            last = self.last_pass()
            now = self.clock()
            if not self.timer_seen(last, now):
                return
            if last != self.slot_from:
                self.slot_from, self.slot = last, last[1] + self.capture_every
                if waited:
                    return
            if now > self.slot + SLOT_GRACE:
                self.slot += self.capture_every * max(1, int((now - self.slot) // self.capture_every))
                if waited:
                    self.n["capture_waits_timed_out"] += 1
                    return
                continue
            if now < self.slot - self.lead(size):
                return
            if not waited:
                self.n["waited_for_capture"] += 1
                waited = True
            self.sleep(1)

    def take_lock(self, lock: int, size: int) -> None:
        """The archive's lock, taken when no capture pass is due within this file's run-up."""
        self.give_way(size)
        asked = time.monotonic()
        fcntl.flock(lock, fcntl.LOCK_EX)
        if time.monotonic() - asked > self.blocked_after and self.due(size):
            # Something else held the lock for a while and a pass has come close
            # in the meantime: step back for it, once.
            fcntl.flock(lock, fcntl.LOCK_UN)
            self.give_way(size)
            fcntl.flock(lock, fcntl.LOCK_EX)

    # ---- one manifest ----------------------------------------------------------

    def room(self, folder: str, more: int) -> bool:
        """Would `more` further bytes leave this folder's disk at or above the floor?"""
        return not self.min_free or self.free(folder) - more >= self.min_free

    def prepare(self, name: str) -> tuple:
        """What needs no lock: read and check one manifest, and open its bytes.

        Returns (ledger row or None, open content or None). No content means
        there is nothing to store: the row, when there is one, is settled as it
        stands, and without a row the manifest is left where it is.
        """
        manifest = read_manifest(self.mirror, name)
        path = manifest["original_path"]
        verdict, agent, key = identity(self.A, self.roots, path)
        if verdict != "ok":
            self.n[verdict] += 1
            return None, None
        refs = blob_refs(manifest)
        size = manifest["source_size_bytes"]
        row = {"manifest": name, "agent": agent, "key": key, "path": path, "bytes": size}
        if size == 0:
            self.n["empty"] += 1
            return dict(row, outcome="empty"), None
        if self.new_keys_only and (agent, key) not in self.ours and self.archive.listed(agent, key):
            self.n["key_in_archive_left_for_later"] += 1
            return None, None
        check_blobs(self.mirror_fd, refs)
        # The copy of a chunked transcript is the first thing written: it has to fit.
        # What goes to the store is checked under the lock, when its size is known.
        if len(refs) > 1 and not self.room(self.scratch, size):
            raise LowDisk()
        content = open_content(self.mirror_fd, refs, self.scratch)
        if os.fstat(content.fileno()).st_size != size:
            got = os.fstat(content.fileno()).st_size
            content.close()
            raise Refused(f"the mirror gave {got} of the {size} bytes recorded")
        return row, content

    def settle(self, row: dict, content) -> dict | None:
        """Under the lock: compare one file with what the archive holds and append what it lacks."""
        archive = self.archive
        agent, key, size = row["agent"], row["key"], row["bytes"]
        fd = content.fileno()
        snap = os.fstat(fd)
        new_key = not archive.listed(agent, key)
        if new_key:
            # Nothing of this key is held, so all of it is written: it has to fit
            # before the key is called the import's own.
            if not self.room(self.store, size):
                raise LowDisk()
            if (agent, key) not in self.ours:
                self.begin(row)
        elif self.new_keys_only and (agent, key) not in self.ours:
            # A capture pass stored this key while the import waited for the lock.
            self.n["key_in_archive_left_for_later"] += 1
            return None
        versions = archive.n["versions"]
        archive.db.execute("BEGIN")
        try:
            stream, window = archive.find_or_create(agent, key, fd, size)
            had = stream.content_bytes
            if size > had:
                # A frame is never larger than what it holds by more than a few bytes.
                if not self.room(self.store, size - had):
                    raise LowDisk()
                stream = archive.append(stream, fd, snap, window)
            archive.db.execute("COMMIT")
        except BaseException:
            # The state goes back to before this file. A frame that reached the
            # store file stays there, and the next look at this key adopts it.
            try:
                archive.db.execute("ROLLBACK")
            except sqlite3.Error:
                pass                 # SQLite had already ended the transaction; the first error is the one to report
            raise
        if new_key:
            outcome = "stored"
        elif archive.n["versions"] > versions:
            outcome = "new_version"
        else:
            outcome = "extended" if size > had else "held"
        self.n[outcome] += 1
        self.n["bytes_added"] += max(0, size - had)
        self.n["bytes_read"] += size
        return dict(row, outcome=outcome, version=stream.version)

    # ---- a run -----------------------------------------------------------------

    def refuse(self, name: str, reason: str) -> None:
        self.n["refused"] += 1
        log(f"refused {name}: {reason}")

    def listing(self, names: set | None) -> list:
        manifests = list_manifests(self.mirror, names, self.refuse)
        self.n["manifests"] = len(manifests)
        if names is not None:
            # A manifest refused while listing was found; it is counted there, not here.
            self.n["names_not_found"] = len(names) - len(manifests) - self.n["refused"]
            if self.n["names_not_found"]:
                log(f"{self.n['names_not_found']} named manifest(s) are not in the mirror")
        return manifests

    def run(self, names: set | None = None) -> dict:
        A = self.A
        started = time.monotonic()
        began = self.clock()
        os.makedirs(self.store, mode=0o700, exist_ok=True)
        os.makedirs(os.path.join(self.store, IMPORTS), mode=0o700, exist_ok=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
        running = os.open(os.path.join(self.store, RUN_LOCK), flags, 0o600)
        try:
            try:
                fcntl.flock(running, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.n["busy"] = 1
                log("another import is running on this store; nothing done")
                return self.summary(started)
            self.mirror_fd = os.open(self.mirror, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
            manifests = self.listing(names)
            done = self.read_ledger()
            if self.recheck:
                done = set()
            self.archive = A.Archive(self.store, self.roots)
            lock = os.open(os.path.join(self.store, "lock"), flags, 0o600)
            try:
                self.open_ledger()
                handled = 0
                for index, (_path, _captured, name) in enumerate(manifests):
                    if name in done:
                        self.n["settled_before"] += 1
                        continue
                    if ((self.limit and handled >= self.limit)
                            or (self.max_bytes and self.n["bytes_read"] >= self.max_bytes)
                            or (self.max_seconds and self.clock() - began >= self.max_seconds)):
                        self.n["deferred"] = sum(1 for item in manifests[index:] if item[2] not in done)
                        break
                    handled += 1
                    settled = None
                    try:
                        settled, content = self.prepare(name)
                        if content is not None:
                            row, settled = settled, None
                            with content:
                                self.take_lock(lock, row["bytes"])
                                try:
                                    settled = self.settle(row, content)
                                finally:
                                    fcntl.flock(lock, fcntl.LOCK_UN)
                    except Refused as error:
                        self.refuse(name, str(error))
                    except LowDisk:
                        self.n["low_disk"] = 1
                        self.n["deferred"] = sum(1 for item in manifests[index:] if item[2] not in done)
                        log(f"free space is below {self.min_free} bytes, or this file would take it there; "
                            f"{self.n['deferred']} manifest(s) are not imported")
                        break
                    except sqlite3.Error as error:
                        # The state file itself failed (a full disk, a lock that never cleared).
                        # The file after this one would meet the same, so the run ends here.
                        self.n["store_errors"] += 1
                        self.n["deferred"] = sum(1 for item in manifests[index + 1:] if item[2] not in done)
                        log(f"{name}: the archive's state file failed, the run ends: {error}")
                        break
                    except (A.StoreError, A.SourceError, A.Skipped, OSError) as error:
                        self.n["store_errors"] += 1
                        log(f"{name}: {error}")
                    if settled is not None:
                        self.note(dict(settled, at=int(self.clock())))
            finally:
                self.sync_ledger()
                if self.ledger is not None:
                    self.ledger.close()
                os.close(lock)
                self.n["store_errors"] += self.archive.n["store_errors"]
                self.archive.close()
        finally:
            if self.mirror_fd >= 0:
                os.close(self.mirror_fd)
                self.mirror_fd = -1
            os.close(running)
        return self.summary(started)

    def plan(self, names: set | None = None) -> dict:
        """What a run would do, from manifests, blob sizes and the archive's state. Writes nothing."""
        A = self.A
        started = time.monotonic()
        manifests = self.listing(names)
        done = self.read_ledger()
        if self.recheck:
            done = set()
        self.archive = A.Archive(self.store, self.roots, readonly=True)
        self.mirror_fd = os.open(self.mirror, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            for _path, _captured, name in manifests:
                if name in done:
                    self.n["settled_before"] += 1
                    continue
                try:
                    manifest = read_manifest(self.mirror, name)
                    verdict, agent, key = identity(A, self.roots, manifest["original_path"])
                    if verdict != "ok":
                        self.n[verdict] += 1
                        continue
                    check_blobs(self.mirror_fd, blob_refs(manifest))
                except Refused as error:
                    self.refuse(name, str(error))
                    continue
                label = "key_in_archive" if self.archive.listed(agent, key) else "key_new"
                self.n[label] += 1
                self.n[label + "_bytes"] += manifest["source_size_bytes"]
        finally:
            os.close(self.mirror_fd)
            self.mirror_fd = -1
            self.archive.close()
        return self.summary(started)

    def summary(self, started: float) -> dict:
        names = ("manifests", "names_not_found", "settled_before", "stored", "extended", "new_version", "held",
                 "empty", "outside_roots", "not_followed", "key_in_archive_left_for_later", "refused",
                 "store_errors", "low_disk", "busy", "deferred", "bytes_read", "bytes_added", "waited_for_capture",
                 "capture_waits_timed_out", "key_new", "key_new_bytes", "key_in_archive", "key_in_archive_bytes")
        report = {name: self.n[name] for name in names if self.n[name] or name in ("manifests", "refused")}
        report["seconds"] = round(time.monotonic() - started, 2)
        return report


def build_parser(A) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="session-import.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--store", default=None, help="archive folder (default: session-archive.py's own)")
    parser.add_argument("--root", action="append", metavar="AGENT=DIR[:DEPTH]",
                        help="place original paths under this folder instead of the built-in roots (repeatable)")
    sub = parser.add_subparsers(dest="command", required=True)
    mirror = sub.add_parser("mirror", help="import what cass's raw mirror holds and the archive lacks")
    mirror.add_argument("--mirror", default=None, help="the mirror's folder, the one holding `manifests` "
                        "(default: ${XDG_DATA_HOME:-~/.local/share}/coding-agent-search/raw-mirror/v1)")
    mirror.add_argument("--plan", action="store_true", help="print what a run would do and write nothing")
    mirror.add_argument("--names", default=None, metavar="FILE",
                        help="only the manifest file names listed in FILE, one per line")
    mirror.add_argument("--new-keys-only", action="store_true",
                        help="only keys the archive did not have before the import")
    mirror.add_argument("--recheck", action="store_true", help="compare manifests an earlier run settled again")
    mirror.add_argument("--limit", type=int, default=0, help="stop after this many manifests (0: no limit)")
    mirror.add_argument("--max-seconds", type=int, default=0, help="take no new manifest after this long (0: no limit)")
    mirror.add_argument("--max-bytes", type=int, default=0,
                        help="take no new manifest once this many mirror bytes were read (0: no limit)")
    mirror.add_argument("--min-free-bytes", type=int,
                        default=int(os.environ.get("SESSION_ARCHIVE_MIN_FREE_BYTES") or A.DEFAULT_MIN_FREE),
                        help="store nothing more, and exit 1, once the disk has less free space than this "
                        "(0 turns the floor off)")
    mirror.add_argument("--capture-every", type=int, default=DEFAULT_CAPTURE_EVERY,
                        help="seconds between the archive's capture passes; the import waits while one is due "
                        "(0: never wait)")
    mirror.add_argument("--scratch", default=None,
                        help="folder for the temporary copy of a transcript kept in chunks "
                        "(default: the store's imports folder)")
    mirror.add_argument("--json", action="store_true")
    return parser


def main(argv: list | None = None) -> int:
    A = load_archive()
    args = build_parser(A).parse_args(argv)
    if A.ZSTD is None:
        log("zstd is not on PATH; install it (apt install zstd, brew install zstd)")
        return 3
    os.umask(0o077)            # transcripts hold secrets; the archive is private to its owner
    store = args.store or A.default_store()
    mirror = os.path.abspath(os.path.expanduser(args.mirror or default_mirror()))
    if not os.path.isdir(os.path.join(mirror, "manifests")):
        log(f"no manifests folder under {mirror}")
        return 2
    names = None
    if args.names:
        try:
            with open(args.names, encoding="utf-8") as fh:
                names = {line.strip() for line in fh if line.strip()}
        except OSError as error:
            log(f"cannot read {args.names}: {error.strerror or error}")
            return 2
    importer = Importer(A, store, A.parse_roots(args.root), mirror, scratch=args.scratch,
                        min_free=args.min_free_bytes, max_bytes=args.max_bytes, max_seconds=args.max_seconds,
                        capture_every=args.capture_every, recheck=args.recheck,
                        new_keys_only=args.new_keys_only, limit=args.limit)
    try:
        report = importer.plan(names) if args.plan else importer.run(names)
    except A.StoreError as error:
        log(str(error))
        return 1
    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        print("session-import: " + " ".join(f"{name}={value}" for name, value in report.items()))
    failed = ("refused", "store_errors", "low_disk", "names_not_found", "busy")
    return 1 if any(report.get(name) for name in failed) else 0


if __name__ == "__main__":
    sys.exit(main())
