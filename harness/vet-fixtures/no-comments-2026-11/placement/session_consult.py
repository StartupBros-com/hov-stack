#!/usr/bin/env python3
"""session_consult.py <claude-projects-dir> [days] - how often does a code-editing session look at a record of
"why" before its first edit? Prints counts only, never transcript content.

Unit: one top-level Claude Code session transcript (subagent files are skipped) modified in the last <days>
days (default 30) that made at least one Edit, Write or NotebookEdit to a file outside the agent's own config,
job and temp directories. A hit is a command that looked, not proof that the reason was found.
"""
import collections
import glob
import json
import os
import re
import sys
import time

root = sys.argv[1]
days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
now = time.time()
files = [p for p in glob.glob(os.path.join(root, "*", "*.jsonl")) if now - os.path.getmtime(p) < days * 86400]
SKIP_EDIT = ("/.claude/projects/", "/.claude/jobs/", "/tmp/", "/memory/", "/.claude/deliverables/")
BODY = re.compile(r"git (show|blame)\b|git log\b[^|;&\n]*( -p\b| -S| -G| -L|--follow|%[bB]|--format=(full|medium|fuller)| -- )")
ANYLOG = re.compile(r"git (log|show|blame)\b")
CASS = re.compile(r"(^|[\s;&|(])cass(-vec|-rerank-local)?\s")
DOCS = ("docs/solutions", "docs/decisions", "docs/adr", "docs/ADR")
tot = collections.Counter()
for path in files:
    first_edit = edited = False
    seen, before = collections.Counter(), collections.Counter()
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant" or rec.get("isSidechain"):
                continue
            for block in (rec.get("message") or {}).get("content") or []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                name, inp = block.get("name"), block.get("input") or {}
                if name in ("Edit", "Write", "NotebookEdit"):
                    target = str(inp.get("file_path") or inp.get("notebook_path") or "")
                    if target and not any(s in target for s in SKIP_EDIT):
                        edited = first_edit = True
                    continue
                hits = set()
                blob = json.dumps(inp)
                if name == "Bash":
                    cmd = str(inp.get("command") or "")
                    if ANYLOG.search(cmd):
                        hits.add("git_any")
                    if BODY.search(cmd):
                        hits.add("git_body")
                    if CASS.search(cmd):
                        hits.add("cass")
                if name == "Skill" and "cass" in blob:
                    hits.add("cass")
                if any(d in blob for d in DOCS):
                    hits.add("docs")
                for h in hits:
                    seen[h] += 1
                    if not first_edit:
                        before[h] += 1
    if not edited:
        tot["sessions with no code edit"] += 1
        continue
    tot["code-editing sessions"] += 1
    for h in ("git_any", "git_body", "cass", "docs"):
        tot[f"before first edit: {h}"] += bool(before[h])
        tot[f"any time: {h}"] += bool(seen[h])
    tot["before first edit: git_body or cass or docs"] += bool(before["git_body"] or before["cass"] or before["docs"])
    tot["any time: git_body or cass or docs"] += bool(seen["git_body"] or seen["cass"] or seen["docs"])
print(f"transcripts scanned (top-level, modified in the last {days} days): {len(files)}")
for key in sorted(tot):
    print(f"  {key}: {tot[key]}")
