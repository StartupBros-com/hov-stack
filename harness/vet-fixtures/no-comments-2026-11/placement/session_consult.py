#!/usr/bin/env python3
"""session_consult.py <claude-projects-dir> [--days N] [--sample N] - how often does a code-editing session
look at a record of "why" before its first edit? Prints counts only, unless --sample is given.
session_consult.py --self-test checks the classifier on the command shapes listed at the end of this file.

Unit: one top-level Claude Code session transcript modified in the last N days (default 30) that made at
least one Edit, Write or NotebookEdit to a file outside the agent's own config, job and temp directories.
"Before first edit" compares record timestamps. Each count is given twice: for the session's own commands,
and with the commands of its subagents (files under <session-id>/subagents/) added.

Classes, per session, each "at least one such command":
  git_any      any git log, git show or git blame
  git_body     a git log or git show that prints commit message bodies: no --oneline, and either no
               --format/--pretty or one that carries %b or %B or names medium, full, fuller, email or raw.
               `git show <rev>:<path>` prints a file, not a message, and does not count.
  git_titles   a git log or git show that prints subject lines or less
  pr_text      gh pr view or gh issue view that prints the body or the comments
  cass         a session-index search, view or pack (a --help call does not count)
  docs_named   a tool input that names docs/solutions, docs/decisions or docs/adr (mostly listings and
               searches)
  docs_read    a Read of a file under one of those folders, or a cat, head, tail, sed, less or bat of one

A Bash call is split into its simple commands (at ; && || | and newlines outside quotes) and each one is
classified, so a second git command on the same line counts. A subagent's edit does not end the "before
first edit" window; only the session's own edit does.

A hit is a command that looked, not proof that the reason was found. --sample N prints up to N matched
commands per class for a read by eye; that output can name private paths, so it is not for committing.
"""
import argparse
import collections
import glob
import json
import os
import re
import time

ap = argparse.ArgumentParser()
ap.add_argument("root", nargs="?")
ap.add_argument("--days", type=int, default=30)
ap.add_argument("--sample", type=int, default=0)
ap.add_argument("--self-test", action="store_true")
opt = ap.parse_args()
if not opt.self_test and not opt.root:
    ap.error("a projects directory or --self-test is required")

SKIP_EDIT = ("/.claude/projects/", "/.claude/jobs/", "/tmp/", "/memory/", "/.claude/deliverables/")
# Where a command can start: the head of a simple command (after shell keywords, env assignments and a few
# wrappers) or the head of a command substitution. "git log" inside an echo label or a commit message is not one.
# Every prefix token ends in required whitespace, so the pattern cannot backtrack inside a token.
HEAD = (r"(?:^\s*(?:(?:[A-Za-z_]\w*=\S*|timeout\s+\S+|xargs(?:\s+-\S+)*|if|elif|while|until|do|then|else|time|command)\s+"
        r"|[!{(]\s*)*|\$\(\s*|`\s*)")
GIT = re.compile(HEAD + r"git\b(?:\s+-C\s+\S+|\s+--no-pager|\s+-c\s+\S+)*\s+(log|show|blame)\b([^\n]*)")
CUT = re.compile(r"\s(?:&&|\|\||;|\|)\s")
FMT = re.compile(r"--(?:format|pretty)(?:=|\s+)(?:'([^']*)'|\"([^\"]*)\"|(\S*))")
REVPATH = re.compile(r"\s[\"']?(?!-)[^\s:'\"=]+:[^\s:]+")
GH = re.compile(HEAD + r"gh\s+(?:pr|issue)\s+view\b([^\n]*)")
CASS = re.compile(HEAD + r"cass(?:-vec|-rerank-local)?\s+(?:search|view|pack)\b([^\n]{0,150})")
DOCS = ("docs/solutions", "docs/decisions", "docs/adr", "docs/ADR")
DOCFILE = re.compile(r"docs/(?:solutions|decisions|adr|ADR)/\S*\.md")
SHOWS = re.compile(r"\b(?:cat|head|tail|sed|less|bat)\b[^|;&\n]*docs/(?:solutions|decisions|adr|ADR)/\S*\.md")
CLASSES = ("git_any", "git_body", "git_titles", "pr_text", "cass", "docs_named", "docs_read")
WHY = ("git_body", "pr_text", "cass", "docs_read")


def simple_commands(cmd):
    """Split a shell command at ; && || | and newlines that sit outside quotes."""
    parts, buf, quote, i = [], [], None, 0
    while i < len(cmd):
        ch = cmd[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch == "\\" and i + 1 < len(cmd):
            buf.append(cmd[i:i + 2])
            i += 1
        elif ch in ";|\n" or cmd.startswith("&&", i):
            parts.append("".join(buf))
            buf = []
            if cmd.startswith(("&&", "||"), i):
                i += 1
        else:
            buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return [part for part in parts if part.strip()]


def classify(name, inp):
    """Return [(class, matched text)] for one tool call."""
    out = []
    if name == "Bash":
        whole = str(inp.get("command") or "")
        if any(word in whole for word in ("git", "gh ", "cass", "docs/")):
            for cmd in simple_commands(whole):
                if any(word in cmd for word in ("git", "gh ", "cass", "docs/")):
                    out.extend(classify_command(cmd))
    blob = json.dumps(inp)
    if any(d in blob for d in DOCS):
        out.append(("docs_named", f"{name}: {blob[:160]}"))
    if name == "Read" and DOCFILE.search(str(inp.get("file_path") or "")):
        out.append(("docs_read", f"Read: {inp.get('file_path')}"))
    return out


def classify_command(cmd):
    """Return [(class, matched text)] for one simple shell command."""
    out = []
    for m in GIT.finditer(cmd):
        sub, rest = m.group(1), CUT.split(m.group(2), maxsplit=1)[0]
        text = f"git {sub}{rest}"
        out.append(("git_any", text))
        if sub == "blame":
            continue
        fmt = FMT.search(rest)
        spec = next((g for g in fmt.groups() if g is not None), "") if fmt else None
        if sub == "show" and REVPATH.search(FMT.sub("", rest)):
            continue
        if "--oneline" in rest:
            out.append(("git_titles", text))
        elif spec is None or "%b" in spec or "%B" in spec or spec in ("medium", "full", "fuller", "email", "raw"):
            out.append(("git_body", text))
        else:
            out.append(("git_titles", text))
    for m in GH.finditer(cmd):
        rest = CUT.split(m.group(1), maxsplit=1)[0]
        fields = re.search(r"--json(?:=|\s+)(\S+)", rest)
        if fields is None or re.search(r"\b(body|comments|reviews)\b", fields.group(1)) or "--comments" in rest:
            out.append(("pr_text", f"gh view{rest}"))
    for m in CASS.finditer(cmd):
        if "--help" not in m.group(1):
            out.append(("cass", "cass" + m.group(0).split("cass", 1)[1]))
    if SHOWS.search(cmd):
        out.append(("docs_read", SHOWS.search(cmd).group(0)))
    return out


def tool_calls(path, sidechain):
    """Yield (timestamp, tool name, input) for each tool call in one transcript."""
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant" or bool(rec.get("isSidechain")) != sidechain:
                continue
            for block in (rec.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    yield str(rec.get("timestamp") or ""), block.get("name"), block.get("input") or {}


SHAPES = [
    ("git log --oneline -5 && git show --stat HEAD", {"git_any", "git_titles", "git_body"}),
    ("git show --stat abc; git log --oneline -3", {"git_any", "git_titles", "git_body"}),
    ("git log --format='%h | %s' -3", {"git_any", "git_titles"}),
    ("git log --format='%h %s%n%b' -- a.json", {"git_any", "git_body"}),
    ("git show main:docs/a.md", {"git_any"}),
    ('git show "origin/main:$f"', {"git_any"}),
    ("git log --oneline -1; gh pr view 12 --json body --jq .body", {"git_any", "git_titles", "pr_text"}),
    ("cd x && git -C y log -3", {"git_any", "git_body"}),
    ("git log --name-only --format= -3", {"git_any", "git_titles"}),
    ('echo hi | cass search "foo bar" --limit 3', {"cass"}),
    ("echo '--- git log NVDA ---'; git log --oneline -3 -- NVDA", {"git_any", "git_titles"}),
    ('echo "git log since 10-25 touching stock path"', set()),
    ('git commit -m "use git show to read it"', set()),
    ('for c in $(git log --format=%h -5); do git show "$c"; done', {"git_any", "git_titles", "git_body"}),
    ('echo "$(git log -1 --format=%B)"', {"git_any", "git_body"}),
    ("GIT_PAGER=cat git log -3", {"git_any", "git_body"}),
    ("if git show --stat HEAD > /dev/null; then echo y; fi", {"git_any", "git_body"}),
    ("timeout 60 cass search 'x y' --limit 8 --robot", {"cass"}),
    ("CASS_AUTO_REFRESH=0 timeout 120 cass search foo", {"cass"}),
    ("URL=https://x.test/?" + "&".join(f"k{i}=v{i}" for i in range(60)) + " curl -s x", set()),
    ("command -v cass && cass --help", set()),
    ('papercut add -m "gh pr view picks the wrong remote"', set()),
    ("gh issue view 12 --json title,state", set()),
    ("gh pr view 12 --comments", {"pr_text"}),
    ("sed -n 1,60p docs/decisions/010-policy.md", {"docs_named", "docs_read"}),
    ("ls docs/solutions", {"docs_named"}),
]
if opt.self_test:
    wrong = 0
    for shape, want in SHAPES:
        got = {cls for cls, _ in classify("Bash", {"command": shape})}
        wrong += got != want
        print("ok " if got == want else "BAD", shape, "->", sorted(got))
    print(f"{len(SHAPES) - wrong} of {len(SHAPES)} shapes classified as expected")
    raise SystemExit(1 if wrong else 0)

now = time.time()
files = sorted(p for p in glob.glob(os.path.join(opt.root, "*", "*.jsonl"))
               if now - os.path.getmtime(p) < opt.days * 86400)
tot = collections.Counter()
samples = collections.defaultdict(list)
for path in files:
    first_edit = None
    seen, before = collections.Counter(), collections.Counter()
    for ts, name, inp in tool_calls(path, sidechain=False):
        if name in ("Edit", "Write", "NotebookEdit"):
            target = str(inp.get("file_path") or inp.get("notebook_path") or "")
            if first_edit is None and target and not any(s in target for s in SKIP_EDIT):
                first_edit = ts
            continue
        for cls, text in classify(name, inp):
            seen[cls] += 1
            if first_edit is None:
                if not before[cls]:
                    samples[cls].append(text)
                before[cls] += 1
    if first_edit is None:
        tot["sessions with no code edit"] += 1
        continue
    tot["code-editing sessions"] += 1
    with_sub = collections.Counter(before)
    sub_dir = os.path.join(path[: -len(".jsonl")], "subagents")
    sub_files = glob.glob(os.path.join(sub_dir, "**", "*.jsonl"), recursive=True)
    tot["code-editing sessions with at least one subagent transcript"] += bool(sub_files)
    for sub in sub_files:
        for ts, name, inp in tool_calls(sub, sidechain=True):
            if ts and ts < first_edit:
                for cls, _ in classify(name, inp):
                    with_sub[cls] += 1
    for label, got in (("own commands", before), ("with subagents", with_sub)):
        for cls in CLASSES:
            tot[f"before first edit, {label}: {cls}"] += bool(got[cls])
        tot[f"before first edit, {label}: git_titles and no git_body"] += bool(got["git_titles"] and not got["git_body"])
        tot[f"before first edit, {label}: git_body or pr_text"] += bool(got["git_body"] or got["pr_text"])
        tot[f"before first edit, {label}: git_body or pr_text or cass or docs_read"] += bool(any(got[c] for c in WHY))
    for cls in CLASSES:
        tot[f"any time, own commands: {cls}"] += bool(seen[cls])
print(f"transcripts scanned (top-level, modified in the last {opt.days} days): {len(files)}")
for key in sorted(tot):
    print(f"  {key}: {tot[key]}")
if opt.sample:
    for cls in CLASSES[1:]:
        got = samples[cls]
        step = max(1, len(got) // opt.sample)
        print(f"== sample, {cls} (first pre-edit hit of every {step}th session with one; {len(got)} sessions)")
        for text in got[::step][: opt.sample]:
            print("   ", re.sub(r"/home/\w+", "~", text)[:190])
