#!/usr/bin/env python3
"""session-search.py: full-text search over the session archive.

  index    read what each archived transcript gained since the last run, cut it
           into one doc per message block, and hand the docs to the index backend
  search   one query, one process: the best sessions, each with the transcript
           line that matched
  show     print the transcript around a hit
  status   what is indexed, what is waiting, the last run

The archive (session-archive.py) is the only source. Nothing here reads an
agent's own transcript folders, so a session stays searchable after the agent
deletes it, and the index can be thrown away and rebuilt from the archive.

What gets indexed: every `.jsonl` stream of Claude Code, Codex, pi and factory
except `journal.jsonl`. Tool-result files, `*.meta.json` and workflow state are
archived but not indexed. Each version of a rewritten file is its own stream.
A root the archive follows by hand under a label like `pi-runtime` is read as
that agent's (`--agent pi` finds it).
A doc is one text, thinking, tool-call or tool-result block; its id is
`<agent>/<key>:<line>:<block>`, where line is the 1-based line of the
transcript. Only whole lines are indexed: a last line with no newline yet waits
for the run after its newline arrives.

How a run stays cheap. A stream's store file only grows by whole zstd frames,
one per capture pass, so the cursor kept for a stream is the store offset its
last run ended at, the content offset that goes with it, and the bytes of the
unfinished last line. The next run decodes from that offset, never from zero.
A hash of the 64 store bytes before the offset travels with the cursor: when
it no longer matches, or the archive's own cursor is behind this one (the
archive repaired the file), the stream's docs are removed and it is indexed
again from its first byte.

How a run survives a kill. The files a batch touches are written to
`pending.json` before the backend is called and cleared after the cursors are
committed. A run that finds the list removes those files from the index and
indexes them again, so a doc is never in the index twice; when the killed call
was the one that created the index, the backend's folder is emptied instead,
since everything in it came from that call. The backend's files are fsynced
before the cursors are committed. A stream that cannot be decoded, or that the
archive changed while it was being read, is left as it was for the next run.

The backend is a separate file (session-index-backend.py) with four commands:
`build <docs.jsonl> <dir>`, `update <docs.jsonl> <dir>`, `remove <dir>
<files.txt>` and `query <dir> <limit> <query>`. It is the index campaign's
docseg-bm25 engine (issue 885), scored in the form that ships; its own header
describes the file layout and its limits.

Index: $SESSION_SEARCH_DIR, else ${XDG_DATA_HOME:-~/.local/share}/session-search.
Store: --store, else session-archive.py's own default.
Environment: SESSION_SEARCH_MAX_SECONDS, SESSION_SEARCH_MAX_BYTES,
SESSION_SEARCH_BATCH_BYTES, SESSION_SEARCH_MIN_FREE_BYTES, SESSION_SEARCH_BACKEND.
Exit: 0 ok, also when another index run holds the lock · 1 a stream could not
be read, the backend failed, the disk is below the free-space floor with
streams waiting, or there is no index to search · 2 usage · 3 zstd is missing.
"""
from __future__ import annotations

import argparse
import calendar
import collections
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass
from typing import Callable, Iterator, Optional

HERE = os.path.dirname(os.path.realpath(__file__))
ARCHIVE_SCRIPT = os.path.join(HERE, "session-archive.py")
BACKEND_SCRIPT = os.path.join(HERE, "session-index-backend.py")

GUARD = 64                      # store bytes before a cursor whose hash is kept with it
DEFAULT_MAX_SECONDS = 15 * 60   # a run takes no new stream after this long
DEFAULT_MAX_BYTES = 8 << 30     # decoded bytes per run before the rest waits
DEFAULT_BATCH_BYTES = 256 << 20  # doc text handed to the backend in one call (a stream is never split)
DEFAULT_MIN_FREE = 10 << 30     # free bytes on the index's disk below which a run indexes nothing more
OVERFETCH = 10                  # sessions asked of the backend per session wanted, when a filter is set

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

SCHEMA = """
CREATE TABLE IF NOT EXISTS streams(
  file TEXT PRIMARY KEY, agent TEXT NOT NULL, key TEXT NOT NULL, version INTEGER NOT NULL,
  session TEXT NOT NULL, cwd TEXT,
  store_off INTEGER NOT NULL, content_off INTEGER NOT NULL, guard BLOB NOT NULL, carry BLOB NOT NULL,
  lines INTEGER NOT NULL, first_ts INTEGER NOT NULL, last_ts INTEGER NOT NULL, docs INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
"""

COUNTERS = ("streams", "waiting", "indexed", "new", "grown", "restarted", "docs", "bad_lines", "removed",
            "recovered", "deferred", "left_for_next_run", "store_errors", "low_disk", "bytes_decoded",
            "text_bytes", "backend_calls")


class BackendError(Exception):
    """The index backend exited non-zero; the run stops and the next one recovers."""


def log(message: str) -> None:
    print(f"session-search: {message}", file=sys.stderr)


def load_archive():
    """session-archive.py as a module: the store's layout and read rules live there."""
    name = "session_archive_for_search"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, ARCHIVE_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# ---- transcript records to docs -----------------------------------------------
#
# claude_docs, codex_docs, flat_text and parse_ts follow the corpus builder the
# index campaign froze (same kinds, same block order, same line numbers), so a
# doc here is the doc the scorer measured. pi and factory have no such oracle;
# their fixtures in the tests come from the record shapes on this host.

def flat_text(value, depth: int = 0) -> str:
    """A tool result or other content value as text."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if depth > 6:
        return ""
    if isinstance(value, list):
        return "\n".join(text for text in (flat_text(item, depth + 1) for item in value) if text)
    if isinstance(value, dict):
        if value.get("type") == "text" and isinstance(value.get("text"), str):
            return value["text"]
        if value.get("type") in ("image", "input_image"):
            return ""
        for name in ("text", "content", "output", "stdout"):
            if name in value:
                return flat_text(value[name], depth + 1)
        return json.dumps(value, ensure_ascii=False)
    return ""


def message_blocks(who: str, role: str, content) -> Iterator[tuple]:
    """(role, kind, text) for an Anthropic-style message: a string, or a list of typed blocks."""
    spoken = "user_prompt" if who == "user" else "assistant_text"
    if isinstance(content, str):
        if content.strip():
            yield role, spoken, content
        return
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict):
            continue
        kind_of = block.get("type")
        if kind_of == "text":
            text, kind = block.get("text") or "", spoken
        elif kind_of == "thinking":
            text, kind = block.get("thinking") or "", "thinking"
        elif kind_of in ("tool_use", "server_tool_use"):
            text = (block.get("name") or "") + " " + json.dumps(block.get("input"), ensure_ascii=False)
            kind = "tool_input"
        elif kind_of in ("tool_result", "advisor_tool_result") or (kind_of or "").endswith("_tool_result"):
            text, kind = flat_text(block.get("content")), "tool_output"
        else:
            continue
        if text and text.strip():
            yield role, kind, text


def claude_docs(record: dict) -> Iterator[tuple]:
    who = record.get("type")
    if who not in ("user", "assistant"):
        return
    message = record.get("message")
    if isinstance(message, dict):
        yield from message_blocks(who, message.get("role") or who, message.get("content"))


def factory_docs(record: dict) -> Iterator[tuple]:
    if record.get("type") != "message":
        return
    message = record.get("message")
    if isinstance(message, dict) and message.get("role") in ("user", "assistant"):
        yield from message_blocks(message["role"], message["role"], message.get("content"))


def codex_docs(record: dict) -> Iterator[tuple]:
    if record.get("type") != "response_item":
        return
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return
    kind_of = payload.get("type")
    if kind_of == "message":
        role = payload.get("role") or "assistant"
        text = flat_text(payload.get("content"))
        kind = "user_prompt" if role == "user" else "assistant_text"
    elif kind_of == "reasoning":
        role, kind = "assistant", "thinking"
        text = flat_text(payload.get("summary"))
    elif kind_of in ("function_call", "custom_tool_call", "local_shell_call"):
        role, kind = "assistant", "tool_input"
        text = (payload.get("name") or kind_of) + " " + flat_text(
            payload.get("arguments") or payload.get("input") or payload.get("action"))
    elif kind_of in ("function_call_output", "custom_tool_call_output"):
        role, kind = "tool", "tool_output"
        text = flat_text(payload.get("output"))
    else:
        return
    if text and text.strip():
        yield role, kind, text


def pi_docs(record: dict) -> Iterator[tuple]:
    if record.get("type") != "message":
        return
    message = record.get("message")
    if not isinstance(message, dict):
        return
    role, content = message.get("role"), message.get("content")
    if role == "toolResult":
        text = flat_text(content)
        if text.strip():
            yield "tool", "tool_output", text
        return
    if role not in ("user", "assistant"):
        return
    spoken = "user_prompt" if role == "user" else "assistant_text"
    if isinstance(content, str):
        if content.strip():
            yield role, spoken, content
        return
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict):
            continue
        kind_of = block.get("type")
        if kind_of == "text":
            text, kind = block.get("text") or "", spoken
        elif kind_of == "thinking":
            text, kind = block.get("thinking") or "", "thinking"
        elif kind_of == "toolCall":
            text = (block.get("name") or "") + " " + json.dumps(block.get("arguments"), ensure_ascii=False)
            kind = "tool_input"
        else:
            continue
        if text and text.strip():
            yield role, kind, text


PARSERS = {"claude": claude_docs, "codex": codex_docs, "pi": pi_docs, "factory": factory_docs}


def base_agent(agent: str) -> str:
    """The agent whose transcripts an archive label holds. A root followed by hand is labelled
    `<agent>-<what>` (`session-archive.py --root pi-runtime=DIR`), and its files are that agent's."""
    return agent if agent in PARSERS else agent.split("-", 1)[0]


def parse_ts(value) -> int:
    if not isinstance(value, str) or len(value) < 19:
        return 0
    try:
        return calendar.timegm(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return 0


def indexed(agent: str, key: str) -> bool:
    """Is this stream a transcript the index reads?"""
    return base_agent(agent) in PARSERS and key.endswith(".jsonl") and key.rsplit("/", 1)[-1] != "journal.jsonl"


def session_of(agent: str, key: str) -> str:
    """The session a stream belongs to: a main transcript and its subagent files share one."""
    parts = key.split("/")
    first = parts[-1] if base_agent(agent) == "codex" else parts[0]
    found = UUID_RE.search(first) or UUID_RE.search(key)
    if found:
        return found.group(0)
    return first[:-len(".jsonl")] if first.endswith(".jsonl") else first


def file_name(agent: str, key: str, version: int) -> str:
    """The name the index knows a stream by."""
    return f"{agent}/{key}" + ("" if version == 1 else f"@v{version}")


def workdir_of(record: dict) -> Optional[str]:
    for holder in (record, record.get("payload")):
        if isinstance(holder, dict) and isinstance(holder.get("cwd"), str) and holder["cwd"]:
            return holder["cwd"]
    return None


# ---- the store, from an offset ------------------------------------------------

def decode_from(archive, path: str, start: int, end: int) -> Iterator[bytes]:
    """Yield the content held in store bytes [start, end) of a store file.

    `start` must be where a zstd frame begins. Raises the archive's StoreError
    when zstd rejects the bytes. session-archive.py's own reader starts at
    byte 0; the tests hold this one to it.
    """
    if end <= start:
        return
    try:
        fh = open(path, "rb")
    except OSError as error:
        raise archive.StoreError(f"cannot open {path}: {error}") from error
    try:
        fh.seek(start)
        proc = subprocess.Popen([archive.ZSTD, "-dcq"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
    except OSError as error:
        fh.close()
        raise archive.StoreError(f"cannot start zstd for {path}: {error}") from error

    def feed() -> None:
        left = end - start
        try:
            while left > 0:
                data = fh.read(min(archive.CHUNK, left))
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
    finished = False
    try:
        while True:
            chunk = proc.stdout.read(archive.CHUNK)
            if not chunk:
                break
            yield chunk
        finished = True
    finally:
        proc.stdout.close()
        if not finished:
            proc.kill()
        feeder.join()
        detail = proc.stderr.read().decode("utf-8", "replace").strip()
        proc.stderr.close()
        code = proc.wait()
        fh.close()
    if code != 0:
        raise archive.StoreError(f"zstd cannot decode {path} from byte {start}: {detail or 'exit %d' % code}")


def guard_of(path: str, offset: int) -> bytes:
    """A hash of the store bytes just before `offset`: it changes when the file was rewritten under a cursor."""
    with open(path, "rb") as fh:
        fh.seek(max(0, offset - GUARD))
        data = fh.read(min(GUARD, offset))
    return hashlib.blake2b(data, digest_size=16).digest()


# ---- index state --------------------------------------------------------------

@dataclass
class Cursor:
    file: str
    agent: str
    key: str
    version: int
    session: str
    cwd: Optional[str]
    store_off: int
    content_off: int
    guard: bytes
    carry: bytes
    lines: int
    first_ts: int
    last_ts: int
    docs: int


def default_index() -> str:
    explicit = os.environ.get("SESSION_SEARCH_DIR")
    if explicit:
        return explicit
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "session-search")


def write_durably(path: str, data: bytes) -> None:
    partial = path + ".partial"
    with open(partial, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(partial, path)
    fd = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Index:
    """The index folder: this tool's cursors (`driver.sqlite3`) and the backend's files (`backend/`)."""

    _COLUMNS = ("file, agent, key, version, session, cwd, store_off, content_off, guard, carry, lines,"
                " first_ts, last_ts, docs")

    def __init__(self, folder: str, backend: str, readonly: bool = False):
        self.folder = folder
        self.backend_dir = os.path.join(folder, "backend")
        self.backend_path = backend
        self.pending_path = os.path.join(folder, "pending.json")
        self.batch_path = os.path.join(folder, "batch.jsonl")
        self.remove_path = os.path.join(folder, "remove.txt")
        state = os.path.join(folder, "driver.sqlite3")
        if readonly:
            if not os.path.exists(state):
                raise FileNotFoundError(state)
            self.db = sqlite3.connect("file:" + urllib.parse.quote(os.path.abspath(state)) + "?mode=ro",
                                      uri=True, isolation_level=None)
            return
        os.makedirs(self.backend_dir, mode=0o700, exist_ok=True)
        self.db = sqlite3.connect(state, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    def cursor(self, file: str) -> Optional[Cursor]:
        row = self.db.execute(f"SELECT {self._COLUMNS} FROM streams WHERE file=?", (file,)).fetchone()
        return Cursor(*row) if row else None

    def offsets(self) -> dict:
        return {row[0]: (row[1], row[2]) for row in self.db.execute(
            "SELECT file, store_off, content_off FROM streams")}

    def backend_empty(self) -> bool:
        return not os.listdir(self.backend_dir)

    def run_backend(self, *args: str) -> str:
        done = subprocess.run([sys.executable, "-I", self.backend_path, *args], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        if done.returncode != 0:
            detail = done.stderr.decode("utf-8", "replace").strip()[-400:]
            raise BackendError(f"backend {args[0]} exited {done.returncode}: {detail}")
        return done.stdout.decode("utf-8", "replace")

    def remove_files(self, files: list) -> None:
        if not files or self.backend_empty():
            return
        with open(self.remove_path, "w", encoding="utf-8") as fh:
            fh.write("".join(name + "\n" for name in files))
        self.run_backend("remove", self.backend_dir, self.remove_path)
        os.unlink(self.remove_path)

    def reset_backend(self) -> None:
        shutil.rmtree(self.backend_dir)
        os.makedirs(self.backend_dir, mode=0o700)

    def sync_backend(self) -> None:
        """fsync what the backend wrote: its own commit may not wait for the disk, and the cursors are about to."""
        for folder, _dirs, names in os.walk(self.backend_dir):
            for name in names + ["."]:
                try:
                    fd = os.open(os.path.join(folder, name), os.O_RDONLY)
                except OSError:
                    continue            # a journal the backend already deleted
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)


class Indexer:
    def __init__(self, archive, store: str, index: Index, max_seconds: int = DEFAULT_MAX_SECONDS,
                 max_bytes: int = DEFAULT_MAX_BYTES, batch_bytes: int = DEFAULT_BATCH_BYTES,
                 min_free: int = 0):
        self.A = archive
        self.store = archive.Archive(store, [], readonly=True)
        self.index = index
        self.max_seconds = max_seconds      # 0: no limit
        self.max_bytes = max_bytes          # 0: no limit
        self.batch_bytes = batch_bytes
        self.min_free = min_free            # 0: no floor
        self.n: collections.Counter = collections.Counter()
        self.batch = None
        self.batch_text = 0
        self.ready: list = []               # cursors whose docs are in the open batch
        self.removals: list = []            # files to take out of the index before the batch goes in
        # Test seams: a capture pass or a kill can land at each of these points.
        self.before_decode: Callable[[], None] = lambda: None
        self.after_decode: Callable[[], None] = lambda: None
        self.after_backend: Callable[[], None] = lambda: None

    def close(self) -> None:
        if self.batch is not None:
            self.batch.close()
        self.store.close()

    # ---- the archive's rows ------------------------------------------------------

    def archive_rows(self) -> list:
        """Every stream's row, fetched whole: a read held open would stop the capture pass's checkpoints.
        The row created last comes first. A run is cut short by its budget, and a first build or a
        rebuild takes hours; this way the transcripts that appeared since the first capture, the
        ones searched most, are searchable first. For the history that first capture copied, the
        order is the reverse of its walk, not of the sessions' age."""
        return self.store.db.execute(
            "SELECT id, agent, key, version, content_bytes, store_bytes, broken FROM streams ORDER BY id DESC"
        ).fetchall()

    def archive_row(self, stream_id: int) -> Optional[tuple]:
        rows = self.store.db.execute(
            "SELECT id, agent, key, version, content_bytes, store_bytes, broken FROM streams WHERE id=?",
            (stream_id,)).fetchall()
        return rows[0] if rows else None

    # ---- recovery ----------------------------------------------------------------

    def recover(self) -> None:
        """Undo a batch a killed run left half applied: its files leave the index and are indexed again."""
        if not os.path.exists(self.index.pending_path):
            return
        with open(self.index.pending_path, encoding="utf-8") as fh:
            pending = json.load(fh)
        files = pending["files"]
        if pending.get("created"):
            # The killed call was the one that made the index, so all it holds came from that
            # call, and a half-written index may not open at all: empty the folder.
            self.index.reset_backend()
        else:
            self.index.remove_files(files)
        self.index.db.execute("BEGIN IMMEDIATE")
        self.index.db.executemany("DELETE FROM streams WHERE file=?", [(name,) for name in files])
        self.index.db.execute("COMMIT")
        os.unlink(self.index.pending_path)
        self.n["recovered"] = len(files)
        log(f"a killed run left {len(files)} stream(s) half indexed; they are indexed again")

    # ---- one stream ----------------------------------------------------------------

    def low_disk(self) -> bool:
        return bool(self.min_free) and shutil.disk_usage(self.index.folder).free < self.min_free

    def discard(self, mark: tuple, reason: str, path: str) -> None:
        position, text, docs, bad = mark
        self.batch.seek(position)
        self.batch.truncate()
        self.batch_text = text
        self.n["docs"] = docs
        self.n["bad_lines"] = bad
        log(f"{path}: {reason}; left for the next run")

    def one_stream(self, stream_id: int) -> None:
        row = self.archive_row(stream_id)
        if row is None or row[6]:
            return
        _id, agent, key, version, content_end, store_end, _broken = row
        file = file_name(agent, key, version)
        path = self.store.path_for(agent, key, version)
        cursor = self.index.cursor(file)
        restart = False
        if cursor is not None:
            if store_end == cursor.store_off and content_end == cursor.content_off:
                return
            try:
                moved = (store_end <= cursor.store_off or content_end < cursor.content_off
                         or guard_of(path, cursor.store_off) != cursor.guard)
            except OSError as error:
                self.n["store_errors"] += 1
                log(f"cannot read {path}: {error}")
                return
            if moved:
                restart = True
        existed = cursor is not None
        if cursor is None or restart:
            cursor = Cursor(file, agent, key, version, session_of(agent, key), None, 0, 0, b"", b"", 0, 0, 0, 0)
        if self.batch is None:
            self.batch = open(self.index.batch_path, "wb")
        mark = (self.batch.tell(), self.batch_text, self.n["docs"], self.n["bad_lines"])
        parts = [cursor.carry] if cursor.carry else []
        decoded = 0
        self.before_decode()
        try:
            for chunk in decode_from(self.A, path, cursor.store_off, store_end):
                decoded += len(chunk)
                cut = chunk.rfind(b"\n")
                if cut < 0:
                    parts.append(chunk)
                    continue
                whole = b"".join(parts) + chunk[:cut]
                parts = [chunk[cut + 1:]] if cut + 1 < len(chunk) else []
                for line in whole.split(b"\n"):
                    cursor.lines += 1
                    self.one_line(cursor, line)
        except self.A.StoreError as error:
            self.n["store_errors"] += 1
            self.discard(mark, str(error), path)
            return
        self.n["bytes_decoded"] += decoded
        if decoded != content_end - cursor.content_off:
            self.n["store_errors"] += 1
            self.discard(mark, f"decoded {decoded} bytes where the archive records "
                         f"{content_end - cursor.content_off}", path)
            return
        self.after_decode()
        now = self.archive_row(stream_id)
        if now is None or now[5] < store_end or now[4] < content_end:
            self.n["left_for_next_run"] += 1
            self.discard(mark, "the archive changed this stream while it was read", path)
            return
        try:
            cursor.guard = guard_of(path, store_end)
        except OSError as error:
            self.n["store_errors"] += 1
            self.discard(mark, f"cannot read it: {error}", path)
            return
        cursor.store_off, cursor.content_off, cursor.carry = store_end, content_end, b"".join(parts)
        if restart:
            self.removals.append(file)
            self.n["restarted"] += 1
        else:
            self.n["grown" if existed else "new"] += 1
        self.ready.append(cursor)
        self.n["indexed"] += 1

    def one_line(self, cursor: Cursor, line: bytes) -> None:
        if base_agent(cursor.agent) == "claude" and line.startswith(b'{"type":"api-request'):
            return
        if not line.strip():
            return
        try:
            record = json.loads(line)
        except ValueError:
            self.n["bad_lines"] += 1
            return
        if not isinstance(record, dict):
            return
        ts = parse_ts(record.get("timestamp")) or cursor.last_ts
        cursor.last_ts = ts or cursor.last_ts
        if ts and not cursor.first_ts:
            cursor.first_ts = ts
        if cursor.cwd is None:
            cursor.cwd = workdir_of(record)
        for block, (role, kind, text) in enumerate(PARSERS[base_agent(cursor.agent)](record)):
            doc = {"id": "%s:%d:%d" % (cursor.file, cursor.lines, block), "session": cursor.session,
                   "file": cursor.file, "agent": cursor.agent, "role": role, "kind": kind, "ts": ts, "text": text}
            self.batch.write(json.dumps(doc, ensure_ascii=False).encode("utf-8", "replace") + b"\n")
            self.batch_text += len(text)
            cursor.docs += 1
            self.n["docs"] += 1

    # ---- a batch -------------------------------------------------------------------

    def flush(self) -> None:
        """Hand the open batch to the backend, then commit the cursors of the streams in it."""
        if not self.ready and not self.removals:
            return
        files = sorted(set(self.removals) | {cursor.file for cursor in self.ready})
        if self.batch is not None:
            self.batch.flush()
        docs = self.batch is not None and self.batch.tell() > 0
        created = docs and self.index.backend_empty()
        write_durably(self.index.pending_path, json.dumps({"files": files, "created": created}).encode())
        self.index.remove_files(self.removals)
        self.n["removed"] += len(self.removals)
        if docs:
            self.index.run_backend("build" if created else "update", self.index.batch_path,
                                   self.index.backend_dir)
            self.n["backend_calls"] += 1
        self.index.sync_backend()
        self.after_backend()
        db = self.index.db
        db.execute("BEGIN IMMEDIATE")
        db.executemany("DELETE FROM streams WHERE file=?", [(name,) for name in self.removals])
        db.executemany(
            f"INSERT OR REPLACE INTO streams({Index._COLUMNS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [(c.file, c.agent, c.key, c.version, c.session, c.cwd, c.store_off, c.content_off, c.guard, c.carry,
              c.lines, c.first_ts, c.last_ts, c.docs) for c in self.ready])
        db.execute("COMMIT")
        os.unlink(self.index.pending_path)
        if self.batch is not None:
            self.batch.seek(0)
            self.batch.truncate()
        self.n["text_bytes"] += self.batch_text
        self.batch_text = 0
        self.ready, self.removals = [], []

    # ---- a run ---------------------------------------------------------------------

    def run(self) -> dict:
        started = time.monotonic()
        self.recover()
        known = self.index.offsets()
        todo = []
        for stream_id, agent, key, version, content_bytes, store_bytes, broken in self.archive_rows():
            if not indexed(agent, key):
                continue
            self.n["streams"] += 1
            if broken:
                continue
            seen = known.get(file_name(agent, key, version))
            if seen is None and content_bytes == 0:
                continue
            if seen != (store_bytes, content_bytes):
                todo.append(stream_id)
        self.n["waiting"] = len(todo)
        for position, stream_id in enumerate(todo):
            over_time = self.max_seconds and time.monotonic() - started >= self.max_seconds
            over_bytes = self.max_bytes and self.n["bytes_decoded"] >= self.max_bytes
            if over_time or over_bytes or self.low_disk():
                self.n["deferred"] = len(todo) - position
                self.n["low_disk"] = int(self.low_disk())
                break
            self.one_stream(stream_id)
            if self.batch_text >= self.batch_bytes:
                self.flush()
        self.flush()
        summary = {name: self.n[name] for name in COUNTERS}
        summary["seconds"] = round(time.monotonic() - started, 2)
        summary["at"] = int(time.time())
        self.index.db.execute("INSERT OR REPLACE INTO meta(k, v) VALUES ('last_run', ?)", (json.dumps(summary),))
        return summary


# ---- search, show, status -------------------------------------------------------

def when(value: str) -> int:
    """YYYY-MM-DD or an ISO time, as epoch seconds (UTC)."""
    text = value if "T" in value else value + "T00:00:00"
    stamp = parse_ts(text)
    if not stamp:
        raise SystemExit(f"session-search: cannot read {value!r} as a date (want YYYY-MM-DD)")
    return stamp


def iso(stamp: int) -> Optional[str]:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp)) if stamp else None


def search(index: Index, args) -> int:
    since = when(args.since) if args.since else (int(time.time()) - args.days * 86400 if args.days else 0)
    until = when(args.until) + 86399 if args.until else 0
    filtered = bool(args.agent or args.workspace or since or until)
    ask = args.limit * OVERFETCH if filtered else args.limit
    hits = []
    for line in index.run_backend("query", index.backend_dir, str(ask), args.query).splitlines():
        if not line.strip():
            continue
        found = json.loads(line)
        file, line_no, block = found["id"].rsplit(":", 2)
        cursor = index.cursor(file)
        if cursor is None:
            continue
        if args.agent and base_agent(cursor.agent) != args.agent:
            continue
        if args.workspace and args.workspace not in (cursor.cwd or ""):
            continue
        if since and cursor.last_ts and cursor.last_ts < since:
            continue
        if until and cursor.first_ts and cursor.first_ts > until:
            continue
        hits.append({"session": found["session"], "agent": cursor.agent, "workspace": cursor.cwd,
                     "ref": f"{file}:{line_no}", "stream": cursor.key, "version": cursor.version,
                     "line": int(line_no), "block": int(block), "last_active": iso(cursor.last_ts),
                     "preview": found.get("preview", "")})
        if len(hits) >= args.limit:
            break
    if args.json:
        print(json.dumps({"query": args.query, "count": len(hits), "hits": hits}))
        return 0
    if not hits:
        print("no match")
    for number, hit in enumerate(hits, 1):
        print(f"{number}. {hit['agent']} {hit['session']}  {hit['last_active'] or '-'}  {hit['workspace'] or '-'}")
        print(f"   {hit['ref']}")
        print("   " + " ".join(hit["preview"].split())[:200])
    return 0


def show(archive, store: str, args) -> int:
    file, _, line_text = args.ref.rpartition(":")
    if not file or not line_text.isdigit():
        raise SystemExit("session-search: show wants a hit's ref, <agent>/<key>:<line>")
    target = int(line_text)
    agent, _, rest = file.partition("/")
    key, version = rest, 1
    found = re.search(r"@v(\d+)$", rest)
    if found:
        key, version = rest[:found.start()], int(found.group(1))
    if base_agent(agent) not in PARSERS:
        raise SystemExit(f"session-search: no transcript reader for {agent!r}")
    reader = archive.Archive(store, [], readonly=True)
    try:
        stream = next((item for number, item, _path in reader.listed(agent, key) if number == version), None)
        if stream is None or stream.broken:
            log(f"the archive holds no {file}")
            return 1
        low, high = max(1, target - args.context), target + args.context
        number, last_ts, carry = 0, 0, b""
        for chunk in reader.read(stream):
            lines = (carry + chunk).split(b"\n")
            carry = lines.pop()
            for line in lines:
                number += 1
                if number > high:
                    return 0
                if base_agent(agent) == "claude" and line.startswith(b'{"type":"api-request'):
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(record, dict):
                    continue
                last_ts = parse_ts(record.get("timestamp")) or last_ts
                if number < low:
                    continue
                for block, (role, kind, text) in enumerate(PARSERS[base_agent(agent)](record)):
                    mark = ">" if number == target else " "
                    print(f"{mark} {number}:{block} {kind} {role} {iso(last_ts) or '-'}")
                    print(text if len(text) <= args.max_chars else text[:args.max_chars] + " [...]")
                    print()
    finally:
        reader.close()
    return 0


def status(archive, store: str, index: Index) -> dict:
    reader = archive.Archive(store, [], readonly=True)
    try:
        rows = reader.db.execute("SELECT agent, key, version, content_bytes, broken FROM streams").fetchall()
    finally:
        reader.close()
    known = {row[0]: row[1] for row in index.db.execute("SELECT file, content_off FROM streams")}
    waiting = behind = eligible = 0
    for agent, key, version, content_bytes, broken in rows:
        if not indexed(agent, key) or broken or not content_bytes:
            continue
        eligible += 1
        done = known.get(file_name(agent, key, version), 0)
        if done != content_bytes:
            waiting += 1
            behind += max(0, content_bytes - done)
    streams, docs, content, unfinished = index.db.execute(
        "SELECT COUNT(*), COALESCE(SUM(docs), 0), COALESCE(SUM(content_off), 0),"
        " COALESCE(SUM(length(carry) > 0), 0) FROM streams").fetchone()
    last = index.db.execute("SELECT v FROM meta WHERE k='last_run'").fetchone()
    size = 0
    for folder, _dirs, names in os.walk(index.folder):
        for name in names:
            try:
                size += os.lstat(os.path.join(folder, name)).st_size
            except OSError:
                pass
    return {"index": index.folder, "store": store, "streams_indexed": streams, "docs": docs,
            "content_bytes_indexed": content, "transcripts_in_archive": eligible, "streams_waiting": waiting,
            "content_bytes_waiting": behind, "streams_ending_in_an_unfinished_line": unfinished,
            "index_bytes_on_disk": size,
            "half_applied_batch": os.path.exists(index.pending_path),
            "last_run": json.loads(last[0]) if last else None}


# ---- command line ---------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="session-search.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--store", default=None, help="archive folder (default: session-archive.py's own)")
    parser.add_argument("--index", default=None, help="index folder (default: $SESSION_SEARCH_DIR, else "
                        "${XDG_DATA_HOME:-~/.local/share}/session-search)")
    parser.add_argument("--backend", default=None, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    index = sub.add_parser("index", help="one run: index what the archive gained")
    index.add_argument("--max-seconds", type=int,
                       default=int(os.environ.get("SESSION_SEARCH_MAX_SECONDS") or DEFAULT_MAX_SECONDS),
                       help="take no new stream after this long (0: no limit)")
    index.add_argument("--max-bytes", type=int,
                       default=int(os.environ.get("SESSION_SEARCH_MAX_BYTES") or DEFAULT_MAX_BYTES),
                       help="take no new stream after decoding this much (0: no limit)")
    index.add_argument("--batch-bytes", type=int,
                       default=int(os.environ.get("SESSION_SEARCH_BATCH_BYTES") or DEFAULT_BATCH_BYTES),
                       help="doc text handed to the backend in one call")
    index.add_argument("--min-free-bytes", type=int,
                       default=int(os.environ.get("SESSION_SEARCH_MIN_FREE_BYTES") or DEFAULT_MIN_FREE),
                       help="index nothing more, and exit 1, once the index's disk has less free space "
                       "than this (0 turns the floor off)")
    index.add_argument("--json", action="store_true")
    find = sub.add_parser("search", help="the best-matching sessions for a query")
    find.add_argument("query")
    find.add_argument("--limit", type=int, default=10)
    find.add_argument("--json", action="store_true")
    find.add_argument("--agent", choices=sorted(PARSERS))
    find.add_argument("--workspace", help="only sessions whose working directory contains this text")
    find.add_argument("--days", type=int, help="only sessions active in the last N days")
    find.add_argument("--since", help="only sessions active on or after this date (YYYY-MM-DD, UTC)")
    find.add_argument("--until", help="only sessions that began on or before this date (YYYY-MM-DD, UTC)")
    view = sub.add_parser("show", help="print the transcript around a hit")
    view.add_argument("ref", help="a hit's ref: <agent>/<key>:<line>")
    view.add_argument("--context", type=int, default=2, help="transcript lines before and after")
    view.add_argument("--max-chars", type=int, default=4000, help="characters printed per block")
    report = sub.add_parser("status", help="what is indexed, what is waiting, the last run")
    report.add_argument("--json", action="store_true")
    return parser


def main(argv: Optional[list] = None) -> int:
    args = build_parser().parse_args(argv)
    archive = load_archive()
    if archive.ZSTD is None:
        log("zstd is not on PATH; install it (apt install zstd, brew install zstd)")
        return 3
    os.umask(0o077)            # the index holds transcript text; it is private to its owner
    store = args.store or archive.default_store()
    folder = args.index or default_index()
    backend = args.backend or os.environ.get("SESSION_SEARCH_BACKEND") or BACKEND_SCRIPT
    if args.command == "show":
        return show(archive, store, args)
    if args.command != "index":
        try:
            index = Index(folder, backend, readonly=True)
        except FileNotFoundError:
            log(f"no index at {folder}; run `session-search.py index` first")
            return 1
        try:
            if args.command == "search":
                return search(index, args)
            report = status(archive, store, index)
            if args.json:
                print(json.dumps(report, sort_keys=True))
            else:
                for name, value in report.items():
                    print(f"{name}: {value}")
            return 0
        except BackendError as error:
            log(str(error))
            return 1
        finally:
            index.close()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    lock = os.open(os.path.join(folder, "lock"), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("another index run holds the lock; nothing to do")
            return 0
        index = Index(folder, backend)
        indexer = Indexer(archive, store, index, args.max_seconds, args.max_bytes, args.batch_bytes,
                          args.min_free_bytes)
        try:
            summary = indexer.run()
        except BackendError as error:
            log(f"{error}; the next run takes the half-applied batch out and indexes it again")
            return 1
        finally:
            indexer.close()
            index.close()
    finally:
        os.close(lock)
    if args.json:
        print(json.dumps(summary, sort_keys=True))
    else:
        print("session-search: " + " ".join(f"{name}={value}" for name, value in summary.items()))
    return 1 if summary["store_errors"] or summary["low_disk"] else 0


if __name__ == "__main__":
    sys.exit(main())
