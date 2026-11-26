#!/usr/bin/env python3
"""Tests for session-search.py and session-index-backend.py.

The failures that matter for an index over an append-only store are a transcript
line that is in the store and not in the index, a line that is in the index
twice, and a hit that points at the wrong line. Every test here captures real
files into a real store with session-archive.py and the real zstd binary.

Two backends are used. Cursor, recovery and overlap tests run against a ledger:
a stand-in that keeps every doc it was given, refuses a doc id it already
holds, and records each call. It is stricter than a search engine, which would
hide a doc indexed twice behind one hit. Search, show and the backend's own
contract run against the shipped session-index-backend.py.

The ledger has no `check` command (it exits 1, as any backend without one
does) until a test drops an `old-format` file into its folder; then `check`
exits 4, the way the shipped backend answers for an index in another format.
"""

import contextlib
import fcntl
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "session-search.py"
BACKEND = REPO / "scripts" / "session-index-backend.py"

_spec = importlib.util.spec_from_file_location("session_search_module", SCRIPT)
S = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = S
_spec.loader.exec_module(S)
A = S.load_archive()

U1 = "11111111-1111-4111-8111-111111111111"
U2 = "22222222-2222-4222-8222-222222222222"
U3 = "33333333-3333-4333-8333-333333333333"
U4 = "44444444-4444-4444-8444-444444444444"


def claude_file(key, version=1):
    """A Claude Code stream's name in the index, as the driver writes it."""
    return S.file_name("claude", key, version)

LEDGER = r'''
import json, os, sys

def path(d):
    return os.path.join(d, "ledger.jsonl")

def load(d):
    docs = {}
    if os.path.exists(path(d)):
        with open(path(d), encoding="utf-8") as fh:
            for line in fh:
                doc = json.loads(line)
                docs[doc["id"]] = doc
    return docs

def save(d, docs):
    with open(path(d), "w", encoding="utf-8") as fh:
        for doc in docs.values():
            fh.write(json.dumps(doc) + "\n")

def note(d, what):
    with open(os.path.join(os.path.dirname(d), "calls.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(what) + "\n")

cmd = sys.argv[1]
if cmd in ("build", "update"):
    src, d = sys.argv[2], sys.argv[3]
    if cmd == "build" and os.listdir(d):
        sys.exit("build into a folder that is not empty")
    if cmd == "update" and not os.path.exists(path(d)):
        sys.exit("update with no index")
    docs = load(d)
    with open(src, encoding="utf-8") as fh:
        new = [json.loads(line) for line in fh]
    flag = os.path.join(os.path.dirname(d), "fail-next")
    failing = os.path.exists(flag)
    if failing:
        os.unlink(flag)
        new = new[:max(1, len(new) // 2)]
    for doc in new:
        if doc["id"] in docs:
            sys.exit("doc %s is already in the index" % doc["id"])
        docs[doc["id"]] = doc
    save(d, docs)
    if failing:
        sys.exit("told to fail after writing half of the batch")
    note(d, [cmd, len(new)])
elif cmd == "remove":
    d, files = sys.argv[2], sys.argv[3]
    with open(files, encoding="utf-8") as fh:
        names = set(line.rstrip("\n") for line in fh)
    docs = load(d)
    kept = dict((k, v) for k, v in docs.items() if v["file"] not in names)
    save(d, kept)
    note(d, ["remove", len(docs) - len(kept)])
elif cmd == "query":
    d, limit, words = sys.argv[2], int(sys.argv[3]), sys.argv[4].lower().split()
    seen = set()
    for doc in load(d).values():
        if all(w in doc["text"].lower() for w in words) and doc["session"] not in seen:
            seen.add(doc["session"])
            print(json.dumps({"session": doc["session"], "id": doc["id"], "preview": doc["text"][:200]}))
            if len(seen) >= limit:
                break
elif cmd == "check" and os.path.exists(os.path.join(sys.argv[2], "old-format")):
    sys.exit(4)
else:
    sys.exit("unknown command")
'''


def setUpModule():
    # A missing compressor must fail this suite, never skip it: the store cannot be read without zstd.
    if A.ZSTD is None:
        raise RuntimeError("zstd is not installed; session-search cannot be tested or run without it")


class Crash(BaseException):
    """Stands in for a kill: nothing in the tool catches it."""


def say(text, who="user", ts="2026-11-20T10:00:00.000Z", cwd="/work/alpha"):
    """One Claude Code transcript line holding one message."""
    record = {"type": who, "timestamp": ts, "cwd": cwd, "message": {"role": who, "content": text}}
    return json.dumps(record).encode() + b"\n"


def lines(prefix, count, **kwargs):
    return b"".join(say("%s-%d" % (prefix, n), **kwargs) for n in range(count))


def simple_docs(file, data):
    """{doc id: text} for a transcript of say() lines, from the source bytes alone."""
    out = {}
    for number, line in enumerate(data.split(b"\n")[:-1], 1):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get("type") in ("user", "assistant"):
            content = record.get("message", {}).get("content")
            if isinstance(content, str) and content.strip():
                out["%s:%d:0" % (file, number)] = content
    return out


class Case(unittest.TestCase):
    backend = None            # the ledger, unless a test class says otherwise

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="session-search-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.sources = {}
        for agent in ("claude", "codex", "pi", "factory"):
            self.sources[agent] = os.path.join(self.tmp, agent)
            os.makedirs(self.sources[agent])
        self.roots = [A.Root("claude", self.sources["claude"], 1), A.Root("codex", self.sources["codex"], 0),
                      A.Root("pi", self.sources["pi"], 1), A.Root("factory", self.sources["factory"], 1)]
        self.store = os.path.join(self.tmp, "store")
        self.index_dir = os.path.join(self.tmp, "index")
        self.clock = 1_700_000_000_000_000_000
        if self.backend is None:
            self.backend = os.path.join(self.tmp, "ledger.py")
            Path(self.backend).write_text(LEDGER, encoding="utf-8")

    # ---- sources and the store -------------------------------------------------

    def put(self, rel, data, agent="claude", mode="wb"):
        path = os.path.join(self.sources[agent], rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as fh:
            fh.write(data)
        self.clock += 1_000_000_000
        os.utime(path, ns=(self.clock, self.clock))
        return path

    def add(self, rel, data, agent="claude"):
        return self.put(rel, data, agent, "ab")

    def capture(self):
        archive = A.Archive(self.store, self.roots)
        try:
            summary = archive.capture()
        finally:
            archive.close()
        self.assertEqual(summary["store_errors"] + summary["source_errors"], 0, summary)
        return summary

    def store_path(self, agent, key, version=1):
        return os.path.join(self.store, "data", agent, key[:2], key + (".zst" if version == 1 else ".v%d.zst" % version))

    def store_row(self, agent, key, version=1):
        con = sqlite3.connect(os.path.join(self.store, "state.sqlite3"))
        try:
            return con.execute("SELECT store_bytes, content_bytes FROM streams WHERE agent=? AND key=? AND version=?",
                               (agent, key, version)).fetchone()
        finally:
            con.close()

    # ---- the index -------------------------------------------------------------

    def run_index(self, seams=None, **kwargs):
        index = S.Index(self.index_dir, self.backend)
        indexer = S.Indexer(A, self.store, index, **kwargs)
        for name, hook in (seams or {}).items():
            setattr(indexer, name, hook)
        try:
            return indexer.run()
        finally:
            indexer.close()
            index.close()

    def ledger(self):
        """{doc id: text} of everything the ledger backend holds."""
        path = os.path.join(self.index_dir, "backend", "ledger.jsonl")
        if not os.path.exists(path):
            return {}
        with open(path, encoding="utf-8") as fh:
            return {doc["id"]: doc["text"] for doc in map(json.loads, fh)}

    def calls(self):
        path = os.path.join(self.index_dir, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            return [tuple(json.loads(line)) for line in fh]

    def cursor(self, file):
        con = sqlite3.connect(os.path.join(self.index_dir, "driver.sqlite3"))
        try:
            return con.execute("SELECT store_off, content_off, lines, docs, carry FROM streams WHERE file=?",
                               (file,)).fetchone()
        finally:
            con.close()

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = S.main(["--store", self.store, "--index", self.index_dir, "--backend", self.backend, *args])
        return code, out.getvalue(), err.getvalue()


# ---- records to docs -------------------------------------------------------------

class DocTests(unittest.TestCase):
    def test_claude_blocks_become_docs_in_block_order(self):
        record = {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "weighing it"},
            {"type": "text", "text": "the answer"},
            {"type": "text", "text": "   "},
            {"type": "tool_use", "name": "Bash", "input": {"command": "ls -la"}},
            {"type": "server_tool_use", "name": "web_search", "input": {"query": "zstd frames"}},
            {"type": "image", "source": {"data": "AAAA"}},
        ]}}
        self.assertEqual(list(S.claude_docs(record)), [
            ("assistant", "thinking", "weighing it"),
            ("assistant", "assistant_text", "the answer"),
            ("assistant", "tool_input", 'Bash {"command": "ls -la"}'),
            ("assistant", "tool_input", 'web_search {"query": "zstd frames"}'),
        ])

    def test_claude_tool_results_and_plain_strings(self):
        record = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "plain output"},
            {"type": "tool_result", "tool_use_id": "t2", "content": [
                {"type": "text", "text": "first part"}, {"type": "image", "source": {}},
                {"type": "text", "text": "second part"}]},
            {"type": "advisor_tool_result", "content": {"type": "text", "text": "advice"}},
            {"type": "mcp_tool_result", "content": [{"stdout": "from a tool"}]},
        ]}}
        self.assertEqual(list(S.claude_docs(record)), [
            ("user", "tool_output", "plain output"),
            ("user", "tool_output", "first part\nsecond part"),
            ("user", "tool_output", "advice"),
            ("user", "tool_output", "from a tool"),
        ])
        self.assertEqual(list(S.claude_docs({"type": "user", "message": {"role": "user", "content": "a question"}})),
                         [("user", "user_prompt", "a question")])
        self.assertEqual(list(S.claude_docs({"type": "assistant", "message": {"content": "an answer"}})),
                         [("assistant", "assistant_text", "an answer")])

    def test_claude_records_that_are_not_messages_yield_nothing(self):
        for record in ({"type": "summary", "summary": "text"}, {"type": "user"}, {"type": "user", "message": "x"},
                       {"type": "system", "message": {"content": "x"}}, {"type": "user", "message": {"content": 7}},
                       {"type": "file-history-snapshot", "snapshot": {}}):
            self.assertEqual(list(S.claude_docs(record)), [], record)

    def test_codex_response_items(self):
        def item(payload):
            return {"type": "response_item", "timestamp": "2026-11-20T10:00:00.000Z", "payload": payload}
        cases = [
            ({"type": "message", "role": "user", "content": [{"type": "input_text", "text": "do the thing"}]},
             [("user", "user_prompt", "do the thing")]),
            ({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "done"},
                                                                  {"type": "input_image", "image_url": "x"}]},
             [("assistant", "assistant_text", "done")]),
            ({"type": "reasoning", "summary": [{"type": "summary_text", "text": "thinking it over"}]},
             [("assistant", "thinking", "thinking it over")]),
            ({"type": "function_call", "name": "shell", "arguments": '{"command": ["ls"]}'},
             [("assistant", "tool_input", 'shell {"command": ["ls"]}')]),
            ({"type": "custom_tool_call", "name": "apply_patch", "input": "*** Begin Patch"},
             [("assistant", "tool_input", "apply_patch *** Begin Patch")]),
            ({"type": "local_shell_call", "action": {"command": ["pwd"]}},
             [("assistant", "tool_input", 'local_shell_call {"command": ["pwd"]}')]),
            ({"type": "function_call_output", "output": "exit 0"}, [("tool", "tool_output", "exit 0")]),
            ({"type": "custom_tool_call_output", "output": {"output": "patched", "metadata": {}}},
             [("tool", "tool_output", "patched")]),
            ({"type": "reasoning", "summary": []}, []),
            ({"type": "ghost_snapshot"}, []),
        ]
        for payload, want in cases:
            self.assertEqual(list(S.codex_docs(item(payload))), want, payload)
        self.assertEqual(list(S.codex_docs({"type": "event_msg", "payload": {"type": "message", "content": "x"}})), [])
        self.assertEqual(list(S.codex_docs({"type": "response_item", "payload": "x"})), [])

    def test_pi_messages(self):
        # Shapes read from ~/.pi/agent/sessions on 2026-11-25; no frozen corpus covers this agent.
        user = {"type": "message", "id": "a", "parentId": None, "timestamp": "2026-11-20T09:00:01.000Z",
                "message": {"role": "user", "content": [{"type": "text", "text": "pi user asks"}], "timestamp": 1}}
        assistant = {"type": "message", "id": "b", "parentId": "a", "timestamp": "2026-11-20T09:00:02.000Z",
                     "message": {"role": "assistant", "content": [
                         {"type": "thinking", "thinking": "pi ponders", "thinkingSignature": "sig"},
                         {"type": "toolCall", "id": "c1", "name": "bash", "arguments": {"command": "ls"}},
                         {"type": "text", "text": "pi answers", "textSignature": "sig"}]}}
        result = {"type": "message", "id": "c", "parentId": "b", "timestamp": "2026-11-20T09:00:03.000Z",
                  "message": {"role": "toolResult", "content": [
                      {"type": "text", "text": "tool says"}, {"type": "image", "data": "AAAA", "mimeType": "image/png"}]}}
        self.assertEqual(list(S.pi_docs(user)), [("user", "user_prompt", "pi user asks")])
        self.assertEqual(list(S.pi_docs(assistant)), [
            ("assistant", "thinking", "pi ponders"),
            ("assistant", "tool_input", 'bash {"command": "ls"}'),
            ("assistant", "assistant_text", "pi answers")])
        self.assertEqual(list(S.pi_docs(result)), [("tool", "tool_output", "tool says")])
        for record in ({"type": "session", "cwd": "/w", "id": "s", "version": 3},
                       {"type": "model_change", "modelId": "m"}, {"type": "thinking_level_change"},
                       {"type": "compaction", "summary": "a summary"},
                       {"type": "message", "message": {"role": "bashExecution", "content": "x"}}):
            self.assertEqual(list(S.pi_docs(record)), [], record)

    def test_factory_messages(self):
        # Shapes read from ~/.factory/sessions on 2026-11-25; no frozen corpus covers this agent.
        user = {"type": "message", "id": "m1", "parentId": None, "seq": 1, "timestamp": "2026-11-21T08:00:00.000Z",
                "message": {"role": "user", "content": [{"type": "text", "text": "factory user asks"}]}}
        assistant = {"type": "message", "id": "m2", "parentId": "m1", "seq": 2,
                     "message": {"role": "assistant", "content": [
                         {"type": "thinking", "thinking": "factory ponders", "signature": "s"},
                         {"type": "tool_use", "id": "t1", "name": "Execute", "input": {"command": "echo hi"}},
                         {"type": "text", "text": "factory answers"}]}}
        results = {"type": "message", "id": "m3", "parentId": "m2", "seq": 3,
                   "message": {"role": "user", "content": [
                       {"type": "tool_result", "tool_use_id": "t1", "content": "result one"},
                       {"type": "tool_result", "tool_use_id": "t2", "content": [{"type": "text", "text": "result two"}]}]}}
        self.assertEqual(list(S.factory_docs(user)), [("user", "user_prompt", "factory user asks")])
        self.assertEqual(list(S.factory_docs(assistant)), [
            ("assistant", "thinking", "factory ponders"),
            ("assistant", "tool_input", 'Execute {"command": "echo hi"}'),
            ("assistant", "assistant_text", "factory answers")])
        self.assertEqual(list(S.factory_docs(results)), [
            ("user", "tool_output", "result one"), ("user", "tool_output", "result two")])
        for record in ({"type": "session_start", "cwd": "/w", "title": "t"}, {"type": "todo_state", "todos": "x"},
                       {"type": "compaction_state", "summaryText": "a summary"}, {"type": "agent_turn_outcome"},
                       {"type": "message", "message": {"role": "system", "content": "x"}}):
            self.assertEqual(list(S.factory_docs(record)), [], record)

    def test_flat_text(self):
        self.assertEqual(S.flat_text(None), "")
        self.assertEqual(S.flat_text(12), "12")
        self.assertEqual(S.flat_text(["a", "", {"type": "text", "text": "b"}, {"type": "image"}]), "a\nb")
        self.assertEqual(S.flat_text({"content": [{"output": "deep"}]}), "deep")
        self.assertEqual(S.flat_text({"unknown": "shape"}), '{"unknown": "shape"}')
        nested = "x"
        for _ in range(9):
            nested = [nested]
        self.assertEqual(S.flat_text(nested), "")

    def test_which_streams_are_indexed_and_what_session_they_belong_to(self):
        self.assertTrue(S.indexed("claude", U1 + ".jsonl"))
        self.assertTrue(S.indexed("claude", U1 + "/subagents/agent-a1.jsonl"))
        self.assertTrue(S.indexed("pi", "ab12/run-0/session.jsonl"))
        self.assertFalse(S.indexed("claude", U1 + "/subagents/agent-a1.meta.json"))
        self.assertFalse(S.indexed("claude", U1 + "/tool-results/toolu_1.txt"))
        self.assertFalse(S.indexed("claude", U1 + "/workflows/wf_1/journal.jsonl"))
        self.assertFalse(S.indexed("claude", U1 + "/workflows/wf_1.json"))
        self.assertTrue(S.indexed("pi-runtime", "runs/2026-03-29T10-00-00_" + U4 + ".jsonl"))
        self.assertFalse(S.indexed("pi-runtime", "runs/state.json"))
        self.assertFalse(S.indexed("elsewhere", "x.jsonl"))
        self.assertFalse(S.indexed("elsewhere-pi", "x.jsonl"))
        self.assertEqual(S.session_of("pi-runtime", "runs/topic/2026-03-29T10-00-00_" + U4 + ".jsonl"), U4)
        self.assertEqual(S.session_of("codex-old", "2026/01/02/rollout-2026-01-02T10-00-00-" + U2 + ".jsonl"), U2)
        self.assertEqual(S.session_of("claude", U1 + ".jsonl"), U1)
        self.assertEqual(S.session_of("claude", U1 + "/subagents/agent-a1.jsonl"), U1)
        self.assertEqual(S.session_of("codex", "2026/11/20/rollout-2026-11-20T10-00-00-" + U2 + ".jsonl"), U2)
        self.assertEqual(S.session_of("factory", U3 + ".jsonl"), U3)
        self.assertEqual(S.session_of("pi", "2026-11-20T10-00-00_" + U4 + "/ab12/run-0/session.jsonl"), U4)
        self.assertEqual(S.session_of("pi", "ab12/run-0/session.jsonl"), "ab12")
        self.assertEqual(S.session_of("claude", "notes.jsonl"), "notes")
        self.assertEqual(S.file_name("codex", "k.jsonl", 1), "codex/k.jsonl")
        self.assertEqual(S.file_name("codex", "k.jsonl", 3), "codex/k.jsonl@v3")

    def test_timestamps(self):
        self.assertEqual(S.parse_ts("1970-01-02T00:00:00.000Z"), 86400)
        self.assertEqual(S.parse_ts("2026-11-20T10:00:00Z"), S.parse_ts("2026-11-20T10:00:00.123+00:00"))
        for bad in (None, 1700000000, "", "yesterday", "2026-13-40T99:00:00"):
            self.assertEqual(S.parse_ts(bad), 0, bad)


# ---- reading the store from an offset ----------------------------------------------

class OffsetTests(Case):
    def test_decoding_from_a_committed_offset_equals_the_archives_own_read(self):
        key = U1 + ".jsonl"
        parts = [lines("first", 400), lines("second", 30), lines("third", 900), b'{"unfinished'
                 ]
        marks = [(0, 0)]
        for part in parts:
            self.add("proj/" + key, part)
            self.capture()
            marks.append(self.store_row("claude", key))
        whole = b"".join(parts)
        reader = A.Archive(self.store, [], readonly=True)
        try:
            stream = reader.listed("claude", key)[0][1]
            self.assertEqual(b"".join(reader.read(stream)), whole)
        finally:
            reader.close()
        path = self.store_path("claude", key)
        end = marks[-1][0]
        self.assertEqual(len(set(marks)), len(marks), "each capture pass must have added a frame")
        for store_off, content_off in marks:
            got = b"".join(S.decode_from(A, path, store_off, end))
            self.assertEqual(got, whole[content_off:], "from store byte %d" % store_off)
        for (store_off, content_off), (store_end, content_end) in zip(marks, marks[1:]):
            got = b"".join(S.decode_from(A, path, store_off, store_end))
            self.assertEqual(got, whole[content_off:content_end])

    def test_an_offset_that_is_not_a_frame_start_is_an_error_not_short_data(self):
        key = U1 + ".jsonl"
        self.put("proj/" + key, lines("only", 300))
        self.capture()
        path = self.store_path("claude", key)
        end = self.store_row("claude", key)[0]
        with self.assertRaises(A.StoreError):
            b"".join(S.decode_from(A, path, 7, end))
        with self.assertRaises(A.StoreError):
            b"".join(S.decode_from(A, path, 0, end - 5))
        with self.assertRaises(A.StoreError):
            b"".join(S.decode_from(A, path + ".gone", 0, end))
        self.assertEqual(b"".join(S.decode_from(A, path, end, end)), b"")


# ---- cursors, against the ledger -----------------------------------------------------

class RunTests(Case):
    def test_first_run_indexes_every_whole_line_once_with_its_line_number(self):
        key = U1 + ".jsonl"
        data = (say("alpha one") + b'{"type":"api-request","body":"alpha hidden"}\n' + b"not json\n" + b"\n"
                + say("alpha two", "assistant") + b'[1, 2]\n' + say("   ") + say("alpha three"))
        self.put("proj/" + key, data)
        sub = self.put("proj/" + U1 + "/subagents/agent-x.jsonl", lines("sub", 3))
        rollout = "2026/11/20/rollout-2026-11-20T10-00-00-" + U2 + ".jsonl"
        codex = json.dumps({"type": "response_item", "timestamp": "2026-11-20T10:00:00.000Z",
                            "payload": {"type": "message", "role": "user", "content": "codex asks"}}).encode() + b"\n"
        self.put(rollout, codex, "codex")
        self.capture()
        summary = self.run_index()
        file = claude_file(key)
        self.assertEqual(self.ledger(), {
            file + ":1:0": "alpha one", file + ":5:0": "alpha two", file + ":8:0": "alpha three",
            **simple_docs(claude_file(U1 + "/subagents/agent-x.jsonl"), Path(sub).read_bytes()),
            "codex/" + rollout + ":1:0": "codex asks"})
        self.assertEqual((summary["indexed"], summary["new"], summary["docs"], summary["bad_lines"]), (3, 3, 7, 1))
        self.assertEqual(self.calls(), [("build", 7)])
        self.assertEqual(self.cursor(file)[2:], (8, 3, b""))
        again = self.run_index()
        self.assertEqual((again["waiting"], again["indexed"], again["backend_calls"]), (0, 0, 0))
        self.assertEqual(self.calls(), [("build", 7)])

    def test_docs_carry_session_agent_role_kind_and_time(self):
        key = U1 + "/subagents/agent-x.jsonl"
        self.put("proj/" + key, say("with fields", "assistant", ts="2026-03-04T05:06:07.000Z"))
        self.capture()
        self.run_index()
        with open(os.path.join(self.index_dir, "backend", "ledger.jsonl"), encoding="utf-8") as fh:
            docs = [json.loads(line) for line in fh]
        self.assertEqual(docs, [{"id": claude_file(key) + ":1:0", "session": U1, "file": claude_file(key),
                                 "agent": "claude", "role": "assistant", "kind": "assistant_text",
                                 "ts": S.parse_ts("2026-03-04T05:06:07"), "text": "with fields"}])

    def test_growth_is_decoded_from_the_cursor_and_only_new_docs_reach_the_backend(self):
        key = U1 + ".jsonl"
        first, more = lines("first", 200), lines("more", 40)
        self.put("proj/" + key, first)
        self.capture()
        self.run_index()
        self.add("proj/" + key, more)
        self.capture()
        summary = self.run_index()
        self.assertEqual(summary["bytes_decoded"], len(more))
        self.assertEqual((summary["grown"], summary["new"], summary["restarted"], summary["docs"]), (1, 0, 0, 40))
        self.assertEqual(self.calls(), [("build", 200), ("update", 40)])
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), first + more))
        self.assertEqual(self.cursor(claude_file(key))[:4], (*self.store_row("claude", key), 240, 240))

    def test_an_unfinished_last_line_waits_for_its_newline_across_runs(self):
        key = U1 + ".jsonl"
        whole = say("the quick brown fox") + say("jumps over the lazy dog") + say("and rests")
        cuts = [len(say("the quick brown fox")) + 20, len(whole) - 30, len(whole) - 1, len(whole)]
        seen, start = [], 0
        for cut in cuts:
            self.add("proj/" + key, whole[start:cut])
            start = cut
            self.capture()
            self.run_index()
            seen.append(sorted(self.ledger().values()))
        self.assertEqual(seen, [["the quick brown fox"], ["jumps over the lazy dog", "the quick brown fox"],
                                ["jumps over the lazy dog", "the quick brown fox"],
                                ["and rests", "jumps over the lazy dog", "the quick brown fox"]])
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), whole))
        self.assertEqual(self.cursor(claude_file(key))[2:], (3, 3, b""))

    def test_a_line_longer_than_a_decode_chunk_is_one_doc(self):
        key = U1 + ".jsonl"
        big = "x" * (2 * A.CHUNK + 4321)
        data = say("before") + say(big) + say("after")
        self.put("proj/" + key, data)
        self.capture()
        self.run_index()
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), data))
        self.assertEqual(len(self.ledger()[claude_file(key) + ":2:0"]), len(big))

    def test_only_a_newline_ends_a_line(self):
        # str.splitlines would also cut at these; the line numbers must be the transcript's.
        key = U1 + ".jsonl"
        odd = "left middle\u0085right end"
        record = {"type": "user", "message": {"role": "user", "content": odd}}
        data = json.dumps(record, ensure_ascii=False).encode() + b"\n" + say("next")
        self.put("proj/" + key, data)
        self.capture()
        self.run_index()
        self.assertEqual(self.ledger(), {claude_file(key) + ":1:0": odd, claude_file(key) + ":2:0": "next"})

    def test_files_that_are_not_transcripts_are_not_indexed(self):
        self.put("proj/" + U1 + ".jsonl", say("a transcript"))
        self.put("proj/" + U1 + "/workflows/wf_1/journal.jsonl", say("journal text"))
        self.put("proj/" + U1 + "/tool-results/toolu_1.txt", b"tool result text\n")
        self.put("proj/" + U1 + "/subagents/agent-x.meta.json", b'{"agentType": "x"}\n')
        self.assertEqual(self.capture()["appended"], 4)
        summary = self.run_index()
        self.assertEqual(sorted(self.ledger().values()), ["a transcript"])
        self.assertEqual((summary["streams"], summary["indexed"]), (1, 1))

    def test_a_rewritten_transcript_is_indexed_as_its_own_version(self):
        key = U1 + ".jsonl"
        old = lines("old", 50)
        self.put("proj/" + key, old)
        self.capture()
        self.run_index()
        new = lines("new", 50)
        self.assertEqual(len(new), len(old))
        self.put("proj/" + key, new, mode="r+b")
        self.capture()
        self.assertIsNotNone(self.store_row("claude", key, 2), "the archive must have kept the rewrite as version 2")
        summary = self.run_index()
        self.assertEqual((summary["new"], summary["restarted"]), (1, 0))
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(key), old), **simple_docs(claude_file(key, 2), new)})

    def test_a_store_file_the_archive_stored_again_is_indexed_again_from_zero(self):
        key = U1 + ".jsonl"
        other = U2 + ".jsonl"
        first, more = lines("first", 300), lines("more", 20)
        self.put("proj/" + key, first)
        self.put("proj/" + other, lines("other", 10))
        self.capture()
        self.run_index()
        self.add("proj/" + key, more)
        self.capture()
        self.run_index()
        before = self.cursor(claude_file(key))
        os.unlink(self.store_path("claude", key))
        archive = A.Archive(self.store, self.roots)
        try:
            archive.capture()                      # reports the lost file and stores the transcript again
        finally:
            archive.close()
        after = self.store_row("claude", key)
        self.assertEqual(after[1], len(first + more))
        self.assertNotEqual(after[0], before[0], "one frame must differ in size from the two it replaces")
        summary = self.run_index()
        self.assertEqual((summary["restarted"], summary["removed"], summary["grown"], summary["new"]), (1, 1, 0, 0))
        self.assertEqual(self.calls()[-2:], [("remove", 320), ("update", 320)])
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(key), first + more),
                                         **simple_docs(claude_file(other), lines("other", 10))})

    def test_a_store_file_rewritten_under_the_cursor_is_caught_by_the_guard(self):
        # The archive's cursor is past the index's, so only the bytes before the index's cursor tell.
        key = U1 + ".jsonl"
        first, more, later = lines("first", 300), lines("more", 20), lines("later", 2000)
        self.put("proj/" + key, first)
        self.capture()
        self.add("proj/" + key, more)
        self.capture()
        self.run_index()
        before = self.cursor(claude_file(key))
        os.unlink(self.store_path("claude", key))
        archive = A.Archive(self.store, self.roots)
        try:
            archive.capture()
        finally:
            archive.close()
        self.add("proj/" + key, later)
        self.capture()
        after = self.store_row("claude", key)
        self.assertGreater(after[0], before[0], "this case needs the new store file to be longer than the old cursor")
        self.assertGreater(after[1], before[1])
        summary = self.run_index()
        self.assertEqual((summary["restarted"], summary["removed"]), (1, 1))
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), first + more + later))

    def test_a_kill_after_the_backend_call_never_leaves_a_doc_twice(self):
        key, other = U1 + ".jsonl", U2 + ".jsonl"
        first, more = lines("first", 60), lines("more", 15)
        self.put("proj/" + key, first)
        self.put("proj/" + other, lines("other", 5))
        self.capture()
        self.run_index()
        self.add("proj/" + key, more)
        self.put("proj/" + U3 + ".jsonl", lines("third", 7))
        self.capture()

        def kill():
            raise Crash()
        with self.assertRaises(Crash):
            self.run_index(seams={"after_backend": kill})
        self.assertTrue(os.path.exists(os.path.join(self.index_dir, "pending.json")))
        self.assertEqual(len(self.ledger()), 60 + 5 + 15 + 7, "the killed run's docs are in the backend")
        self.assertEqual(self.cursor(claude_file(key))[3], 60, "and its cursors are not committed")
        summary = self.run_index()
        self.assertEqual(summary["recovered"], 2)
        self.assertFalse(os.path.exists(os.path.join(self.index_dir, "pending.json")))
        want = {**simple_docs(claude_file(key), first + more), **simple_docs(claude_file(other), lines("other", 5)),
                **simple_docs(claude_file(U3 + ".jsonl"), lines("third", 7))}
        self.assertEqual(self.ledger(), want)
        self.assertEqual(self.calls()[-2:], [("remove", 60 + 15 + 7), ("update", 60 + 15 + 7)])
        self.assertEqual(self.run_index()["waiting"], 0)

    def test_a_kill_during_the_call_that_created_the_index_starts_it_over(self):
        key = U1 + ".jsonl"
        data = lines("first", 40)
        self.put("proj/" + key, data)
        self.capture()

        def kill():
            raise Crash()
        with self.assertRaises(Crash):
            self.run_index(seams={"after_backend": kill})
        with open(os.path.join(self.index_dir, "pending.json"), encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), {"files": [claude_file(key)], "created": True})
        # What a kill mid-build can leave: a file the backend cannot open.
        Path(self.index_dir, "backend", "ledger.jsonl").write_bytes(b"\x00 not an index")
        summary = self.run_index()
        self.assertEqual((summary["recovered"], summary["new"]), (1, 1))
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), data))
        self.assertEqual(self.calls(), [("build", 40), ("build", 40)])

    def test_a_backend_that_fails_half_way_is_undone_by_the_next_run(self):
        key = U1 + ".jsonl"
        first, more = lines("first", 30), lines("more", 30)
        self.put("proj/" + key, first)
        self.capture()
        self.assertEqual(self.cli("index")[0], 0)
        self.add("proj/" + key, more)
        self.capture()
        Path(self.index_dir, "fail-next").write_text("")
        code, _out, err = self.cli("index")
        self.assertEqual(code, 1)
        self.assertIn("backend update exited 1", err)
        self.assertEqual(len(self.ledger()), 45, "half of the failed batch is in the backend")
        code, out, _err = self.cli("index", "--json")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["recovered"], 1)
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), first + more))

    def test_an_index_the_backend_no_longer_reads_is_emptied_and_built_again(self):
        key, other = U1 + ".jsonl", U2 + ".jsonl"
        first, second = lines("first", 30), lines("second", 8)
        self.put("proj/" + key, first)
        self.put("proj/" + other, second)
        self.capture()
        self.assertEqual(self.run_index()["rebuilt"], 0)
        Path(self.index_dir, "backend", "old-format").write_text("")
        summary = self.run_index()
        self.assertEqual((summary["rebuilt"], summary["new"], summary["docs"]), (1, 2, 38))
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(key), first),
                                         **simple_docs(claude_file(other), second)})
        # The ledger refuses a build into a folder that is not empty and a doc id it already holds.
        self.assertEqual(self.calls(), [("build", 38), ("build", 38)])
        again = self.run_index()
        self.assertEqual((again["rebuilt"], again["waiting"]), (0, 0))

    def test_a_kill_before_a_stale_index_is_emptied_leaves_it_stale_for_the_next_run(self):
        key = U1 + ".jsonl"
        data = lines("first", 25)
        self.put("proj/" + key, data)
        self.capture()
        self.run_index()
        Path(self.index_dir, "backend", "old-format").write_text("")
        with mock.patch.object(S.Index, "reset_backend", side_effect=Crash()), self.assertRaises(Crash):
            self.run_index()
        self.assertIsNone(self.cursor(claude_file(key)), "the cursors go before the folder")
        self.assertEqual(len(self.ledger()), 25, "and the old index is still there")
        summary = self.run_index()
        self.assertEqual((summary["rebuilt"], summary["new"]), (1, 1))
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), data))

    def test_a_kill_right_after_a_stale_index_is_emptied_never_leaves_cursors_over_nothing(self):
        key = U1 + ".jsonl"
        data = lines("first", 25)
        self.put("proj/" + key, data)
        self.capture()
        self.run_index()
        Path(self.index_dir, "backend", "old-format").write_text("")
        emptied = S.Index.reset_backend

        def emptied_then_killed(index):
            emptied(index)
            raise Crash()
        with mock.patch.object(S.Index, "reset_backend", emptied_then_killed), self.assertRaises(Crash):
            self.run_index()
        self.assertEqual(self.ledger(), {})
        summary = self.run_index()
        self.assertEqual((summary["new"], summary["docs"]), (1, 25))
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), data))

    def test_a_half_applied_batch_on_a_stale_index_goes_with_it(self):
        key = U1 + ".jsonl"
        first, more = lines("first", 20), lines("more", 6)
        self.put("proj/" + key, first)
        self.capture()
        self.run_index()
        self.add("proj/" + key, more)
        self.capture()

        def kill():
            raise Crash()
        with self.assertRaises(Crash):
            self.run_index(seams={"after_backend": kill})
        self.assertTrue(os.path.exists(os.path.join(self.index_dir, "pending.json")))
        Path(self.index_dir, "backend", "old-format").write_text("")
        summary = self.run_index()
        self.assertEqual((summary["rebuilt"], summary["recovered"], summary["new"]), (1, 0, 1))
        self.assertFalse(os.path.exists(os.path.join(self.index_dir, "pending.json")))
        self.assertEqual(self.ledger(), simple_docs(claude_file(key), first + more))

    def test_a_backend_with_no_check_command_is_never_taken_for_stale(self):
        key = U1 + ".jsonl"
        self.put("proj/" + key, lines("first", 5))
        self.capture()
        self.run_index()
        folder = os.path.join(self.index_dir, "backend")
        asked = subprocess.run([sys.executable, "-I", self.backend, "check", folder], stderr=subprocess.PIPE,
                               check=False)
        self.assertEqual((asked.returncode, asked.stderr.decode().strip()), (1, "unknown command"))
        self.add("proj/" + key, lines("more", 3))
        self.capture()
        summary = self.run_index()
        self.assertEqual((summary["rebuilt"], summary["grown"]), (0, 1))
        self.assertEqual(self.calls(), [("build", 5), ("update", 3)])

    def test_a_stream_that_does_not_decode_is_left_and_the_rest_is_indexed(self):
        bad, good = U1 + ".jsonl", U2 + ".jsonl"
        first, more = lines("first", 50), lines("more", 50)
        self.put("proj/" + bad, first)
        self.put("proj/" + good, lines("good", 5))
        self.capture()
        self.run_index()
        before = self.cursor(claude_file(bad))
        self.add("proj/" + bad, more)
        self.add("proj/" + good, lines("good-more", 5))
        self.capture()
        path = self.store_path("claude", bad)
        size = os.path.getsize(path)
        with open(path, "r+b") as fh:
            fh.seek(before[0] + 6)
            fh.write(b"\xff" * (size - before[0] - 6))
        summary = self.run_index()
        self.assertEqual((summary["store_errors"], summary["indexed"], summary["grown"]), (1, 1, 1))
        self.assertEqual(self.cursor(claude_file(bad)), before)
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(bad), first),
                                         **simple_docs(claude_file(good), lines("good", 5) + lines("good-more", 5))})
        self.assertEqual(self.cli("index")[0], 1, "a stream that cannot be read must fail the run")
        os.unlink(path)
        archive = A.Archive(self.store, self.roots)
        try:
            archive.capture()
        finally:
            archive.close()
        code, out, _err = self.cli("index", "--json")
        self.assertEqual((code, json.loads(out)["store_errors"]), (0, 0))
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(bad), first + more),
                                         **simple_docs(claude_file(good), lines("good", 5) + lines("good-more", 5))})

    def test_a_capture_pass_during_a_run_is_picked_up_by_the_next_run(self):
        key = U1 + ".jsonl"
        first, during, later = lines("first", 80), lines("during", 20), lines("later", 10)
        others = {}
        for uuid in (U2, U3):
            self.put("proj/%s.jsonl" % uuid, lines(uuid[:4], 3))
            others.update(simple_docs(claude_file(uuid + ".jsonl"), lines(uuid[:4], 3)))
        self.capture()
        self.put("proj/" + key, first)         # captured last, so the run (newest first) decodes it first
        self.capture()
        state = os.path.join(self.store, "state.sqlite3")
        checked = []

        def capture_now():
            if checked:
                return
            self.add("proj/" + key, during)
            self.capture()
            # The run must hold no read on the archive's state while it decodes: a read left open
            # keeps the capture pass from ever emptying its write-ahead log. The control shows
            # this probe does see a held read.
            con = sqlite3.connect(state)
            try:
                checked.append(con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0])
                held = sqlite3.connect(state)
                reading = held.execute("SELECT id FROM streams")
                reading.fetchone()                 # two rows are still to come, so this read stays open
                con.execute("UPDATE streams SET version=version")
                con.commit()
                checked.append(con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0])
                reading.close()
                held.close()
            finally:
                con.close()
        summary = self.run_index(seams={"before_decode": capture_now})
        self.assertEqual(checked, [0, 1], "first: the run blocks no checkpoint; second: a held read does")
        self.assertEqual((summary["docs"], summary["left_for_next_run"]), (86, 0))
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(key), first), **others})
        self.add("proj/" + key, later)
        self.capture()
        summary = self.run_index()
        self.assertEqual((summary["grown"], summary["docs"]), (1, 30))
        self.assertEqual(self.ledger(), {**simple_docs(claude_file(key), first + during + later), **others})

    def test_a_stream_the_archive_cut_back_during_a_run_is_left_for_the_next_run(self):
        key = U1 + ".jsonl"
        data = lines("first", 500)
        self.put("proj/" + key, data)
        self.capture()
        state = os.path.join(self.store, "state.sqlite3")

        def cut_back():
            con = sqlite3.connect(state)
            con.execute("UPDATE streams SET store_bytes=0, content_bytes=0 WHERE key=?", (key,))
            con.commit()
            con.close()
        summary = self.run_index(seams={"after_decode": cut_back})
        self.assertEqual((summary["left_for_next_run"], summary["indexed"], summary["docs"]), (1, 0, 0))
        self.assertEqual(self.ledger(), {})
        self.assertIsNone(self.cursor(claude_file(key)))

    def test_a_run_stops_taking_streams_at_its_byte_budget_and_the_next_runs_finish(self):
        want = {}
        for number, uuid in enumerate((U1, U2, U3)):
            data = lines("s%d" % number, 20)
            self.put("proj/%s.jsonl" % uuid, data)
            want.update(simple_docs(claude_file(uuid + ".jsonl"), data))
        self.capture()
        seen = []
        for _ in range(4):
            summary = self.run_index(max_bytes=1)
            seen.append((summary["waiting"], summary["indexed"], summary["deferred"]))
        self.assertEqual(seen, [(3, 1, 2), (2, 1, 1), (1, 1, 0), (0, 0, 0)])
        self.assertEqual(self.ledger(), want)
        self.assertEqual(self.calls(), [("build", 20), ("update", 20), ("update", 20)])

    def test_a_run_short_of_budget_takes_the_newest_capture_first(self):
        # A first build or a rebuild takes hours; the stream row created last goes first.
        for number, uuid in enumerate((U1, U2, U3)):
            self.put("proj/%s.jsonl" % uuid, lines("s%d" % number, 20))
            self.capture()
        summary = self.run_index(max_bytes=1)
        self.assertEqual((summary["indexed"], summary["deferred"]), (1, 2))
        self.assertIsNotNone(self.cursor(claude_file(U3 + ".jsonl")))
        self.assertIsNone(self.cursor(claude_file(U1 + ".jsonl")))
        self.assertIsNone(self.cursor(claude_file(U2 + ".jsonl")))

    def test_a_small_batch_size_means_several_backend_calls_and_the_same_index(self):
        want = {}
        for number, uuid in enumerate((U1, U2, U3, U4)):
            data = lines("s%d" % number, 25)
            self.put("proj/%s.jsonl" % uuid, data)
            want.update(simple_docs(claude_file(uuid + ".jsonl"), data))
        self.capture()
        summary = self.run_index(batch_bytes=1)
        self.assertEqual(summary["backend_calls"], 4)
        self.assertEqual(self.calls(), [("build", 25)] + [("update", 25)] * 3)
        self.assertEqual(self.ledger(), want)

    def test_below_the_free_space_floor_nothing_is_indexed_and_the_run_fails(self):
        self.put("proj/" + U1 + ".jsonl", lines("first", 5))
        self.capture()
        summary = self.run_index(min_free=1 << 62)
        self.assertEqual((summary["low_disk"], summary["indexed"], summary["deferred"]), (1, 0, 1))
        self.assertEqual(self.cli("index", "--min-free-bytes", str(1 << 62))[0], 1)
        self.assertEqual(self.ledger(), {})

    def test_a_second_run_at_the_same_time_does_nothing(self):
        self.put("proj/" + U1 + ".jsonl", lines("first", 5))
        self.capture()
        os.makedirs(self.index_dir)
        held = os.open(os.path.join(self.index_dir, "lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(held, fcntl.LOCK_EX)
            code, _out, err = self.cli("index")
        finally:
            os.close(held)
        self.assertEqual(code, 0)
        self.assertIn("another index run holds the lock", err)
        self.assertEqual(self.ledger(), {})

    def test_without_zstd_the_tool_says_so(self):
        with mock.patch.object(A, "ZSTD", None):
            code, _out, err = self.cli("index")
        self.assertEqual(code, 3)
        self.assertIn("zstd is not on PATH", err)


# ---- the shipped backend ---------------------------------------------------------------

def engine():
    """The shipped backend as a module, for the tests that reach inside it."""
    spec = importlib.util.spec_from_file_location("session_index_backend_under_test", BACKEND)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ask(module, index, limit, query):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        module.query(index, limit, query)
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def backend(*args):
    done = subprocess.run([sys.executable, "-I", str(BACKEND), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return done.returncode, [json.loads(line) for line in done.stdout.decode().splitlines() if line.strip()], \
        done.stderr.decode()


def as_format_1(folder):
    """Rewrite a manifest the way the format 1 engine wrote it: no format number, the list under "segs"."""
    path = Path(folder, "manifest.json")
    manifest = json.loads(path.read_text())
    del manifest["fmt"]
    manifest["segs"] = manifest.pop("segments")
    path.write_text(json.dumps(manifest))


class BackendTests(unittest.TestCase):
    """The five commands the driver relies on, on the backend file that ships."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="session-index-backend-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.index = os.path.join(self.tmp, "index")
        os.makedirs(self.index)

    def docs(self, name, rows):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            for file, session, line, text in rows:
                fh.write(json.dumps({"id": "%s:%d:0" % (file, line), "session": session, "file": file,
                                     "agent": "claude", "role": "user", "kind": "user_prompt", "ts": 0,
                                     "text": text}) + "\n")
        return path

    def names(self, *files):
        path = os.path.join(self.tmp, "files.txt")
        Path(path).write_text("".join(name + "\n" for name in files), encoding="utf-8")
        return path

    def test_build_query_remove_update(self):
        base = self.docs("base.jsonl", [
            ("codex/a.jsonl", "sess-a", 1, "the heron waits by the weir"),
            ("codex/a.jsonl", "sess-a", 2, "a kingfisher dives"),
            ("codex/b.jsonl", "sess-b", 1, "the heron flies at dusk"),
            ("codex/c.jsonl@v2", "sess-c", 4, "an otter and a kingfisher"),
        ])
        self.assertEqual(backend("build", base, self.index)[0], 0)
        code, hits, err = backend("query", self.index, "10", "kingfisher")
        self.assertEqual(code, 0, err)
        self.assertEqual({(hit["session"], hit["id"]) for hit in hits},
                         {("sess-a", "codex/a.jsonl:2:0"), ("sess-c", "codex/c.jsonl@v2:4:0")})
        self.assertTrue(all("kingfisher" in hit["preview"] for hit in hits))
        self.assertEqual(len(backend("query", self.index, "1", "heron")[1]), 1)
        self.assertEqual(backend("query", self.index, "10", "heron weir")[1][0]["id"], "codex/a.jsonl:1:0")
        self.assertEqual(backend("query", self.index, "10", "wolverine")[1], [])
        self.assertEqual(backend("query", self.index, "10", "...")[0], 0)

        self.assertEqual(backend("remove", self.index, self.names("codex/a.jsonl"))[0], 0)
        self.assertEqual([hit["session"] for hit in backend("query", self.index, "10", "kingfisher")[1]], ["sess-c"])
        self.assertEqual([hit["session"] for hit in backend("query", self.index, "10", "heron")[1]], ["sess-b"])

        more = self.docs("more.jsonl", [
            ("codex/a.jsonl", "sess-a", 1, "the heron waits by the weir"),
            ("codex/a.jsonl", "sess-a", 2, "a kingfisher dives"),
            ("codex/a.jsonl", "sess-a", 3, "a late wagtail"),
            ("codex/d.jsonl", "sess-d", 1, "wagtail on the wall"),
        ])
        self.assertEqual(backend("update", more, self.index)[0], 0)
        self.assertEqual({hit["id"] for hit in backend("query", self.index, "10", "wagtail")[1]},
                         {"codex/a.jsonl:3:0", "codex/d.jsonl:1:0"})
        self.assertEqual({hit["session"] for hit in backend("query", self.index, "10", "heron")[1]}, {"sess-a", "sess-b"})

        twice = self.names("codex/a.jsonl", "codex/never-indexed.jsonl")
        self.assertEqual(backend("remove", self.index, twice)[0], 0)
        self.assertEqual(backend("remove", self.index, twice)[0], 0)
        self.assertEqual([hit["id"] for hit in backend("query", self.index, "10", "wagtail")[1]], ["codex/d.jsonl:1:0"])
        self.assertEqual([hit["session"] for hit in backend("query", self.index, "10", "kingfisher")[1]], ["sess-c"])

    def test_an_index_in_another_format_stops_every_command_before_it_writes(self):
        base = self.docs("base.jsonl", [("codex/a.jsonl", "sess-a", 1, "the heron waits")])
        self.assertEqual(backend("check", self.index)[0], 0, "an empty folder is not an old index")
        self.assertEqual(backend("build", base, self.index)[0], 0)
        self.assertEqual(backend("check", self.index)[0], 0)
        manifest = Path(self.index, "manifest.json")
        current = manifest.read_text()
        # The format 1 engine has no format check and reads "segs": without that key it stops on a
        # format 2 folder, where it would otherwise add a format 1 segment.
        self.assertNotIn("segs", json.loads(current))
        newer = dict(json.loads(current), fmt=json.loads(current)["fmt"] + 1)
        for label, rewrite in (("format 1", lambda: as_format_1(self.index)),
                               ("a later format", lambda: manifest.write_text(json.dumps(newer)))):
            manifest.write_text(current)
            rewrite()
            before = {name: Path(self.index, name).read_bytes() for name in os.listdir(self.index)}
            for args in (("check", self.index), ("query", self.index, "5", "heron"), ("update", base, self.index),
                         ("build", base, self.index), ("remove", self.index, self.names("codex/a.jsonl"))):
                code, _hits, err = backend(*args)
                self.assertEqual(code, 4, (label, args[0], err))
                self.assertIn("built again", err)
            after = {name: Path(self.index, name).read_bytes() for name in os.listdir(self.index)}
            self.assertEqual(after, before, label)

    def test_one_session_is_printed_once_and_the_best_doc_names_it(self):
        rows = [("codex/a.jsonl", "sess-a", n, "filler line number %d about nothing" % n) for n in range(1, 30)]
        rows.append(("codex/a.jsonl", "sess-a", 30, "quetzal quetzal quetzal"))
        rows.append(("codex/a.jsonl", "sess-a", 31, "one quetzal among many other words in a long line of text"))
        rows.append(("codex/b.jsonl", "sess-b", 1, "a quetzal was mentioned once here in passing, no more than that"))
        self.assertEqual(backend("build", self.docs("base.jsonl", rows), self.index)[0], 0)
        hits = backend("query", self.index, "10", "quetzal")[1]
        self.assertEqual([hit["session"] for hit in hits], ["sess-a", "sess-b"])
        self.assertEqual(hits[0]["id"], "codex/a.jsonl:30:0")


    def test_a_session_with_many_matches_does_not_hide_the_other_sessions(self):
        rows = [("codex/a.jsonl", "sess-a", n, "ibis ibis") for n in range(1, 901)]
        for n in range(12):
            rows.append(("codex/o%d.jsonl" % n, "sess-o%d" % n, 1,
                         "a long line of ordinary words in which an ibis is named once, near the middle, and then "
                         "the line goes on for a good while about reeds, mud, weather and the state of the path"))
        self.assertEqual(backend("build", self.docs("base.jsonl", rows), self.index)[0], 0)
        hits = backend("query", self.index, "20", "ibis")[1]
        self.assertEqual(hits[0]["session"], "sess-a")
        self.assertEqual(sorted(hit["session"] for hit in hits), sorted(["sess-a"] + ["sess-o%d" % n for n in range(12)]))
        self.assertEqual(len(backend("query", self.index, "5", "ibis")[1]), 5)


    def test_many_small_updates_keep_every_doc_in_a_bounded_number_of_files(self):
        alive = set()
        for n in range(60):
            rows = [("codex/f%d.jsonl" % n, "sess-%d" % n, 1, "the dunlin feeds, entry %d" % n),
                    ("codex/f%d.jsonl" % n, "sess-%d" % n, 2, "word%d alone" % n)]
            self.assertEqual(backend("update" if n else "build", self.docs("part.jsonl", rows), self.index)[0], 0)
            alive.add("sess-%d" % n)
            if n in (20, 41):
                self.assertEqual(backend("remove", self.index, self.names("codex/f%d.jsonl" % (n - 13)))[0], 0)
                alive.discard("sess-%d" % (n - 13))
            if n == 50:
                self.assertEqual(backend("update", self.docs("again.jsonl", [
                    ("codex/f7.jsonl", "sess-7", 9, "the dunlin feeds again")]), self.index)[0], 0)
                alive.add("sess-7")
        hits = backend("query", self.index, "200", "dunlin")[1]
        self.assertEqual(sorted(hit["session"] for hit in hits), sorted(alive))
        self.assertEqual({hit["session"]: hit["id"] for hit in hits}["sess-7"], "codex/f7.jsonl:9:0")
        self.assertEqual([hit["id"] for hit in backend("query", self.index, "5", "word33")[1]], ["codex/f33.jsonl:2:0"])
        self.assertEqual(backend("query", self.index, "5", "word28")[1], [])
        self.assertLessEqual(len(os.listdir(self.index)), 24)

    def test_two_words_with_one_hash_share_a_list_and_merges_still_work(self):
        module = engine()
        real = module.h48
        module.h48 = lambda term: real(term[:2])      # heron and hedge now collide, in every batch
        for n in range(40):
            rows = [("codex/a%d.jsonl" % n, "sess-a%d" % n, 1, "a heron"),
                    ("codex/b%d.jsonl" % n, "sess-b%d" % n, 1, "a hedge"),
                    ("codex/c%d.jsonl" % n, "sess-c%d" % n, 1, "heron by the hedge"),
                    ("codex/d%d.jsonl" % n, "sess-d%d" % n, 1, "an otter")]
            module.ingest(self.docs("part.jsonl", rows), self.index)
        self.assertLessEqual(len(os.listdir(self.index)), 24)
        found = {hit["session"] for hit in ask(module, self.index, 500, "heron")}
        self.assertTrue({"sess-a%d" % n for n in range(40)} | {"sess-c%d" % n for n in range(40)} <= found)
        self.assertFalse({"sess-d%d" % n for n in range(40)} & found)
        self.assertEqual(len(ask(module, self.index, 500, "otter")), 40)

    def test_a_search_that_races_a_merge_reads_the_manifest_again(self):
        module = engine()
        module.ingest(self.docs("base.jsonl", [("codex/a.jsonl", "sess-a", 1, "the heron waits")]), self.index)
        real = module.read_manifest
        stale = real(self.index)
        stale["segs"][0] = dict(stale["segs"][0], name="seg-99999.bin")     # a file a merge already deleted
        answers = [stale]
        module.read_manifest = lambda folder: answers.pop() if answers else real(folder)
        self.assertEqual([hit["session"] for hit in ask(module, self.index, 5, "heron")], ["sess-a"])
        module.read_manifest = lambda folder: dict(stale)
        with self.assertRaises(FileNotFoundError):
            ask(module, self.index, 5, "heron")

    def test_leftovers_of_a_killed_update_are_cleared_by_the_next_one(self):
        self.assertEqual(backend("build", self.docs("base.jsonl", [
            ("codex/a.jsonl", "sess-a", 1, "the heron waits")]), self.index)[0], 0)
        for name in ("seg-00007.bin", "seg-00008.bin.tmp", "recs.tmp"):
            Path(self.index, name).write_bytes(b"half written")
        self.assertEqual([hit["session"] for hit in backend("query", self.index, "5", "heron")[1]], ["sess-a"])
        self.assertEqual(backend("update", self.docs("more.jsonl", [
            ("codex/b.jsonl", "sess-b", 1, "a second heron")]), self.index)[0], 0)
        self.assertEqual({hit["session"] for hit in backend("query", self.index, "5", "heron")[1]}, {"sess-a", "sess-b"})
        self.assertFalse({"seg-00007.bin", "seg-00008.bin.tmp", "recs.tmp"} & set(os.listdir(self.index)))


# ---- search, show and status, end to end on the shipped backend ---------------------------

class SearchTests(Case):
    backend = str(BACKEND)

    def fill(self):
        now = time.time()
        recent = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 2 * 86400))
        self.put("proj-a/" + U1 + ".jsonl",
                 say("how do we rotate the heron signing key", ts="2026-01-10T08:00:00.000Z", cwd="/work/alpha")
                 + say("rotate it with the vault helper, then restart", "assistant", ts="2026-01-10T08:00:05.000Z",
                       cwd="/work/alpha")
                 + say("unrelated closing remark", ts="2026-01-10T08:01:00.000Z", cwd="/work/alpha"))
        self.put("proj-b/" + U2 + ".jsonl",
                 say("the heron deploy failed on the bravo host", ts=recent, cwd="/work/bravo"))
        rollout = "2026/06/10/rollout-2026-06-10T09-00-00-" + U3 + ".jsonl"
        codex = [{"type": "session_meta", "timestamp": "2026-06-10T09:00:00.000Z", "payload": {"cwd": "/work/charlie"}},
                 {"type": "response_item", "timestamp": "2026-06-10T09:00:01.000Z",
                  "payload": {"type": "message", "role": "user", "content": "codex looks at the heron parser"}}]
        self.put(rollout, b"".join(json.dumps(r).encode() + b"\n" for r in codex), "codex")
        pi = [{"type": "session", "version": 3, "id": "p", "timestamp": "2026-06-11T09:00:00.000Z", "cwd": "/work/delta"},
              {"type": "message", "id": "a", "parentId": None, "timestamp": "2026-06-11T09:00:01.000Z",
               "message": {"role": "user", "content": [{"type": "text", "text": "pi asks about the heron cache"}]}}]
        self.put("enc-cwd/ab12cd/run-0/session.jsonl", b"".join(json.dumps(r).encode() + b"\n" for r in pi), "pi")
        factory = [{"type": "session_start", "id": U4, "title": "t", "cwd": "/work/echo"},
                   {"type": "message", "id": "m1", "parentId": None, "seq": 1, "timestamp": "2026-06-12T09:00:00.000Z",
                    "message": {"role": "assistant", "content": [
                        {"type": "tool_use", "id": "t1", "name": "Execute", "input": {"command": "heron --check"}}]}}]
        self.put("enc-cwd/" + U4 + ".jsonl", b"".join(json.dumps(r).encode() + b"\n" for r in factory), "factory")
        self.capture()
        code, out, err = self.cli("index", "--json")
        self.assertEqual(code, 0, err)
        return json.loads(out), rollout

    def find(self, *args):
        code, out, err = self.cli("search", "--json", *args)
        self.assertEqual(code, 0, err)
        return json.loads(out)["hits"]

    def test_a_search_names_the_session_the_stream_and_the_line(self):
        summary, rollout = self.fill()
        self.assertEqual((summary["indexed"], summary["docs"], summary["store_errors"]), (5, 7, 0))
        hits = self.find("heron")
        self.assertEqual({hit["session"] for hit in hits}, {U1, U2, U3, "ab12cd", U4})
        by_session = {hit["session"]: hit for hit in hits}
        self.assertEqual(by_session[U1], {
            "session": U1, "agent": "claude", "workspace": "/work/alpha", "ref": claude_file(U1 + ".jsonl") + ":1",
            "stream": U1 + ".jsonl", "version": 1, "line": 1, "block": 0,
            "last_active": "2026-01-10T08:01:00Z", "preview": "how do we rotate the heron signing key"})
        self.assertEqual((by_session[U3]["agent"], by_session[U3]["workspace"], by_session[U3]["ref"]),
                         ("codex", "/work/charlie", "codex/%s:2" % rollout))
        self.assertEqual((by_session["ab12cd"]["agent"], by_session["ab12cd"]["workspace"]), ("pi", "/work/delta"))
        self.assertEqual((by_session[U4]["agent"], by_session[U4]["workspace"], by_session[U4]["line"]),
                         ("factory", "/work/echo", 2))
        self.assertEqual([hit["session"] for hit in self.find("vault helper")], [U1])
        self.assertEqual(self.find("heron", "--limit", "2").__len__(), 2)
        self.assertEqual(self.find("nosuchwordanywhere"), [])
        code, out, _err = self.cli("search", "heron", "--limit", "1")
        self.assertEqual(code, 0)
        self.assertIn("heron", out)
        self.assertEqual(self.cli("search", "nosuchwordanywhere")[1].strip(), "no match")

    def test_filters(self):
        self.fill()
        self.assertEqual({hit["session"] for hit in self.find("heron", "--agent", "codex")}, {U3})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--agent", "pi")}, {"ab12cd"})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--workspace", "/work/bravo")}, {U2})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--workspace", "work")},
                         {U1, U2, U3, "ab12cd", U4})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--days", "7")}, {U2})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--until", "2026-02-01")}, {U1})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--since", "2026-06-11", "--until", "2026-06-12")},
                         {"ab12cd", U4})
        self.assertEqual({hit["session"] for hit in self.find("heron", "--since", "2026-06-10", "--until", "2026-06-10")},
                         {U3})
        with self.assertRaises(SystemExit):
            self.cli("search", "heron", "--since", "last tuesday")

    def test_show_prints_the_transcript_around_a_hit(self):
        self.fill()
        ref = [hit for hit in self.find("vault helper") if hit["session"] == U1][0]["ref"]
        code, out, err = self.cli("show", ref, "--context", "1")
        self.assertEqual(code, 0, err)
        blocks = [line for line in out.splitlines() if line[:2] in ("> ", "  ") and ":0 " in line]
        self.assertEqual([line[:5] for line in blocks], ["  1:0", "> 2:0", "  3:0"])
        self.assertIn("rotate it with the vault helper, then restart", out)
        self.assertIn("how do we rotate the heron signing key", out)
        code, out, _err = self.cli("show", ref, "--context", "0", "--max-chars", "9")
        self.assertEqual(out.splitlines()[1], "rotate it [...]")
        self.assertNotIn("heron", out)
        self.assertEqual(self.cli("show", claude_file(U3 + ".jsonl") + ":1")[0], 1)
        with self.assertRaises(SystemExit):
            self.cli("show", "not-a-ref")

    def test_show_reads_the_version_a_hit_names(self):
        key = U1 + ".jsonl"
        old = say("the osprey plan, first draft")
        new = say("the marten plan, later draft")
        self.assertEqual(len(old), len(new))
        self.put("proj/" + key, old)
        self.capture()
        self.assertEqual(self.cli("index")[0], 0)
        self.put("proj/" + key, new, mode="r+b")
        self.capture()
        self.assertEqual(self.cli("index")[0], 0)
        hit = self.find("marten")[0]
        self.assertEqual((hit["ref"], hit["version"]), (claude_file(key, 2) + ":1", 2))
        self.assertIn("the marten plan", self.cli("show", hit["ref"])[1])
        self.assertIn("the osprey plan", self.cli("show", self.find("osprey")[0]["ref"])[1])

    def test_a_stream_stored_again_is_searchable_once_after_the_reindex(self):
        key = U1 + ".jsonl"
        first, more = lines("gannet", 200), say("the petrel line")
        self.put("proj/" + key, first)
        self.capture()
        self.assertEqual(self.cli("index")[0], 0)
        self.add("proj/" + key, more)
        self.capture()
        self.assertEqual(self.cli("index")[0], 0)
        os.unlink(self.store_path("claude", key))
        archive = A.Archive(self.store, self.roots)
        try:
            archive.capture()
        finally:
            archive.close()
        code, out, err = self.cli("index", "--json")
        self.assertEqual((code, json.loads(out)["restarted"]), (0, 1), err)
        self.assertEqual([hit["ref"] for hit in self.find("petrel")], [claude_file(key) + ":201"])
        con = sqlite3.connect(os.path.join(self.index_dir, "driver.sqlite3"))
        try:
            self.assertEqual(con.execute("SELECT docs FROM streams").fetchall(), [(201,)])
        finally:
            con.close()

    def test_a_root_followed_by_hand_is_read_as_its_agents_transcripts(self):
        folder = os.path.join(self.tmp, "pi-runtime")
        os.makedirs(os.path.join(folder, "runs", "topic"))
        self.sources["pi-runtime"] = folder
        self.roots.append(A.Root("pi-runtime", folder, 0))
        key = "runs/topic/2026-03-29T10-00-00_" + U4 + ".jsonl"
        records = [{"type": "session", "version": 3, "id": "p", "timestamp": "2026-03-29T10:00:00.000Z", "cwd": "/work/fox"},
                   {"type": "message", "id": "a", "parentId": None, "timestamp": "2026-03-29T10:00:01.000Z",
                    "message": {"role": "toolResult", "content": [{"type": "text", "text": "the bittern report"}]}}]
        self.put(key, b"".join(json.dumps(r).encode() + b"\n" for r in records), "pi-runtime")
        plain = {"type": "message", "id": "b", "parentId": None, "timestamp": "2026-06-11T09:00:01.000Z",
                 "message": {"role": "user", "content": [{"type": "text", "text": "an ordinary pi line about a bittern"}]}}
        self.put("enc-cwd/ab12cd/run-0/session.jsonl", json.dumps(plain).encode() + b"\n", "pi")
        self.capture()
        self.assertEqual(self.cli("index")[0], 0)
        hits = {hit["session"]: hit for hit in self.find("bittern", "--agent", "pi")}
        self.assertEqual(set(hits), {U4, "ab12cd"})
        self.assertEqual((hits[U4]["agent"], hits[U4]["ref"], hits[U4]["workspace"]),
                         ("pi-runtime", "pi-runtime/%s:2" % key, "/work/fox"))
        self.assertEqual(self.find("bittern", "--agent", "claude"), [])
        self.assertIn("the bittern report", self.cli("show", hits[U4]["ref"])[1])

    def test_an_older_format_is_named_by_search_and_status_and_built_again_by_the_next_index_run(self):
        self.fill()
        self.assertFalse(json.loads(self.cli("status", "--json")[1])["index_needs_rebuild"])
        as_format_1(os.path.join(self.index_dir, "backend"))
        code, out, err = self.cli("search", "heron")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("`session-search.py index` builds it again", err)
        self.assertTrue(json.loads(self.cli("status", "--json")[1])["index_needs_rebuild"])
        code, out, err = self.cli("index", "--json")
        self.assertEqual(code, 0, err)
        summary = json.loads(out)
        self.assertEqual((summary["rebuilt"], summary["indexed"], summary["docs"]), (1, 5, 7))
        self.assertEqual({hit["session"] for hit in self.find("heron")}, {U1, U2, U3, "ab12cd", U4})
        self.assertEqual([hit["session"] for hit in self.find("vault helper")], [U1])
        self.assertFalse(json.loads(self.cli("status", "--json")[1])["index_needs_rebuild"])
        again = json.loads(self.cli("index", "--json")[1])
        self.assertEqual((again["rebuilt"], again["waiting"]), (0, 0))

    def test_status_counts_what_is_indexed_and_what_waits(self):
        self.assertEqual(self.cli("status")[0], 1, "no index yet")
        self.assertEqual(self.cli("search", "heron")[0], 1)
        self.fill()
        code, out, _err = self.cli("status", "--json")
        report = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual((report["streams_indexed"], report["docs"], report["transcripts_in_archive"],
                          report["streams_waiting"], report["content_bytes_waiting"], report["half_applied_batch"]),
                         (5, 7, 5, 0, 0, False))
        self.assertEqual(report["last_run"]["indexed"], 5)
        self.assertGreater(report["index_bytes_on_disk"], 0)
        grown = say("a later line with no newline yet")[:-1]
        self.add("proj-a/" + U1 + ".jsonl", grown)
        self.put("proj-a/" + U2 + "-new.jsonl", lines("new", 3))
        self.capture()
        report = json.loads(self.cli("status", "--json")[1])
        self.assertEqual((report["streams_waiting"], report["content_bytes_waiting"]),
                         (2, len(grown) + len(lines("new", 3))))
        self.assertEqual(self.cli("index")[0], 0)
        report = json.loads(self.cli("status", "--json")[1])
        self.assertEqual((report["streams_waiting"], report["streams_ending_in_an_unfinished_line"]), (0, 1))
        self.assertIn("streams_indexed: 6", self.cli("status")[1])


if __name__ == "__main__":
    unittest.main()
