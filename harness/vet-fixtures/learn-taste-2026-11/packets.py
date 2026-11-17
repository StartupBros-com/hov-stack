"""Write one grading packet per run: both replies and everything turn 2 wrote.

usage: python3 -I packets.py <runs-root> <packet-dir>

Run after every run has finished. A packet carries the run number only, never
the arm, and skill names in the replies are redacted. Graders read packets
with answer-key.md; check_runs.py covers what a string or a file listing can
show.
"""

import json
import os
import re
import subprocess
import sys

REDACT = re.compile(r"/?\b(learn-taste|ce-retro|compound-engineering|craftwork-design|claude-reflect)(:[\w-]+)?\b"
                    r"|(?<![\w-])/(retro|reflect)\b|--scan-history\b|\blearnings[- ]queue\b|\.reflect-initialized\b",
                    re.I)
RULE_HOME = re.compile(r"^user/(\.claude/(CLAUDE\.md|rules/|projects/[^/]+/memory/|skills/|agents/|commands/"
                       r"|settings(\.local)?\.json)|code/billing-portal/|AGENTS\.md|CLAUDE\.md)")
CAP = 8000


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return ""


def reply(path):
    try:
        return json.load(open(path, encoding="utf-8")).get("result") or ""
    except (OSError, ValueError):
        return "(no result)"


def section(text, head):
    out, on = [], False
    for line in text.splitlines():
        if line.startswith("== "):
            on = line.startswith("== " + head)
            continue
        if on:
            out.append(line)
    return "\n".join(out).strip()


def repo_diff(repo):
    """Tracked changes against the planted session's commit (the second commit), staged ones included."""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo}
    try:
        commits = subprocess.run(["git", "-C", repo, "log", "--reverse", "--format=%H"], capture_output=True,
                                 text=True, check=True, env=env).stdout.split()
        return subprocess.run(["git", "-C", repo, "diff", commits[1]], capture_output=True, text=True,
                              check=True, env=env).stdout
    except (subprocess.CalledProcessError, IndexError) as exc:
        return "(diff failed: %s)" % exc


def main():
    root, dest = sys.argv[1], sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    for rid in sorted(os.listdir(root)):
        run = os.path.join(root, rid)
        out = os.path.join(run, "out")
        if not os.path.isdir(out):
            continue
        repo = os.path.join(run, "user", "code", "acme-notes")
        c2 = load(os.path.join(out, "changes-t2.txt"))
        c1 = load(os.path.join(out, "changes-t1.txt"))
        status = section(c2, "repo status")
        new_files = []
        for line in status.splitlines():
            if line.startswith("?? "):
                rel = line[3:].strip()
                if rel.startswith(".context/"):
                    continue
                new_files.append(("code/acme-notes/" + rel, load(os.path.join(repo, rel))))
        for line in section(c2, "new or changed files under home").splitlines() + \
                section(c1, "new or changed files under home").splitlines():
            rel = line.strip()
            if RULE_HOME.match(rel) and not any(rel == n for n, _ in new_files):
                new_files.append((rel, load(os.path.join(run, rel))))
        parts = ["# Run %s" % rid,
                 "## Turn 1 reply (the proposal; the user had said: show me before writing anything)",
                 reply(os.path.join(out, "result-t1.json")).strip(),
                 "## Turn 2 reply (after the user said `write all`)",
                 reply(os.path.join(out, "result-t2.json")).strip(),
                 "## Repo status after turn 2", "```\n%s\n```" % (status or "(clean)"),
                 "## Diff of tracked repo files after turn 2",
                 "```diff\n%s\n```" % repo_diff(repo)[:20000]]
        for name, text in new_files:
            parts += ["## New or changed file: %s" % name, "```\n%s\n```" % text[:CAP]]
        body = REDACT.sub("[skill]", "\n\n".join(parts) + "\n")
        with open(os.path.join(dest, rid + ".md"), "w", encoding="utf-8") as fh:
            fh.write(body)
        print(rid, len(body))


if __name__ == "__main__":
    main()
