#!/usr/bin/env python3
"""ff-only-autostash-audit.py: every scripted fast-forward-only site switches autostash off.

Ceremony Test (harness/evidence-regime.md §1):
  consumer     harness-doctor.sh check 30 (Monday harness-weekly), and
               tests/test_ff_only_autostash_audit.py, whose live-repo
               case runs this against the checkout on every PR.
  gate         a finding turns the doctor red and fails the python suite; a
               corpus it cannot inventory exits 2 and is reported as "did NOT
               run", never as clean.
  defect       OBSERVED, twice: lib/repo-update.sh passed its own planted
               negative for the wrong reason until #383 (the merge autostashed
               and succeeded, so the refusal branch was never reached); and
               update-mcp-servers.sh shipped a bare `pull --ff-only` in #730
               on 2026-08-30, three days after #481 named the trap. Of the
               four sites #481 swept, three were safe by accident.
  delete-when  git/config.shared stops setting merge.autoStash and
               rebase.autoStash -- a bare --ff-only then refuses on its own.

THE TRAP
--------
git/config.shared sets merge.autoStash, rebase.autoStash and pull.rebase to
true for every checkout on the box. Under that config a `git merge --ff-only`
or `git pull --ff-only` whose contract is "refuse when a local edit overlaps
the incoming diff" does not refuse: it stashes, fast-forwards and pops -- and
when the pop conflicts the command STILL EXITS 0, leaving UU entries and
conflict markers in the tree and the stash undropped (#210 documented the
shape). Automation that gates on $? logs that as success.

THE RULE (static, per command -- no control-flow inference, because a
dirtiness guard three lines up is invisible to the next editor who moves the
line):

    git merge ... --ff-only   carries --no-autostash  OR  -c merge.autostash=false
    git pull  ... --ff-only   carries --no-autostash  OR  BOTH
                              -c merge.autostash=false -c rebase.autostash=false

Why pull is stricter: since git 2.36, `git pull` copies rebase.autoStash into
its own autostash setting whenever pull.rebase is on, then passes an explicit
--autostash to the merge it runs for --ff-only, so `-c merge.autostash=false`
alone never reaches that merge (measured on 2.43.0: exit 0, UU, stash left;
on 2.34.1 the -c form still worked, which is why #481 could suggest it). With
pull.rebase unset the merge honors merge.autoStash instead, so
`-c rebase.autostash=false` alone is the no-op. Only --no-autostash covers
every config and git version a checkout may run under.

WHAT IS SCANNED
---------------
git-tracked shell sources (*.sh, or a #! line naming sh/bash/zsh/dash) minus
test suites (any tests/ directory, *.test.sh), whose stubs legitimately spell
these commands. Comment lines are skipped, an unquoted trailing `# ...` is
stripped, backslash continuations are joined, and each logical line is split
on unquoted `;`, `&&`, `||`, `|`, so a guarded command cannot vouch for a
bare one beside it and a comment cannot vouch for the command it annotates.
A site is any command containing `--ff-only` or the config spelling
`pull.ff=only` / `merge.ff=only`.

KNOWN GAPS, by design: a non-shell caller that shells out (`subprocess.run(
["bash", "-lc", "git pull --ff-only"])`) is outside the corpus -- none exists
in this repo (rg -F -- '--ff-only' finds only shell sources and tests), and
widening to .py/.js would put this docstring in scope. A flag held in a
variable (`opts=--ff-only; git pull $opts`) is reported at the assignment as
an unauditable site rather than silently passed. An echo'd string containing
the literal flag is judged like a command: the audit reads text, and the fix
for that false positive is to spell the sentence without the flag.

Usage: ff-only-autostash-audit.py [--root DIR] [--floor N]
Exit: 0 clean, 1 findings, 2 corpus unavailable, below the site floor, or
crashed (harness-doctor friendly). One "WARN <path>:<line>: <why>" per
finding, then a one-line tally.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from floor_assert import FloorNotMet, require_floor  # noqa: E402

LABEL = "ff-only-autostash-audit"
NO_AUTOSTASH = "--no-autostash"
SITE_RE = re.compile(
    r"--ff-only(?![\w-])|\b(?:pull|merge)\.ff=only(?![\w-])", re.IGNORECASE
)
# The subcommand as a standalone word. `merge.autostash=false` also contains
# "merge" and `merge-base` is not a merge, so a word followed by "." or "-" is
# not the verb.
VERB_RE = re.compile(r"\b(pull|merge)\b(?![.\w-])")
AUTOSTASH_ON_RE = re.compile(r"(?<![\w-])--autostash(?![\w-])")
MERGE_OFF_RE = re.compile(r"\bmerge\.autostash=false\b", re.IGNORECASE)
REBASE_OFF_RE = re.compile(r"\brebase\.autostash=false\b", re.IGNORECASE)
SHEBANG_SHELL_RE = re.compile(r"^#!.*\b(?:ba|da|z)?sh\b")

POP_CONFLICT = (
    "a conflicted autostash pop exits 0 with UU entries and the stash left behind"
)


def is_shell_source(path: Path) -> bool:
    if path.suffix == ".sh":
        return True
    try:
        with path.open("rb") as fh:
            first = fh.readline(200)
    except OSError:
        return False
    return bool(SHEBANG_SHELL_RE.match(first.decode("utf-8", "replace")))


def is_test_path(rel: str) -> bool:
    parts = rel.split("/")
    return "tests" in parts[:-1] or parts[-1].endswith(".test.sh")


def logical_lines(text: str):
    """Yield (first_physical_lineno, joined_line), folding backslash continuations."""
    buf: list[str] = []
    start = 0
    for idx, raw in enumerate(text.splitlines(), start=1):
        if not buf:
            start = idx
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            buf.append(stripped[:-1])
            continue
        buf.append(raw)
        yield start, " ".join(buf)
        buf = []
    if buf:
        yield start, " ".join(buf)


def commands(line: str) -> list[str]:
    """Split a logical line into its commands.

    Drops an unquoted trailing `# comment` and splits on unquoted `;`, `&&`,
    `||`, `|` and `&`, tracking single/double quotes and backslash escapes.
    Subshells and braces are not tracked: a segment only has to isolate one
    git invocation's own flags from its neighbours' and from prose.
    """
    out: list[str] = []
    buf: list[str] = []
    quote: str | None = None
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if quote:
            buf.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                buf.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            buf.append(ch)
            buf.append(line[i + 1])
            i += 2
            continue
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        if ch in ";|&":
            out.append("".join(buf))
            buf = []
            if i + 1 < n and line[i + 1] == ch:
                i += 1
            i += 1
            continue
        buf.append(ch)
        i += 1
    out.append("".join(buf))
    return [seg for seg in out if seg.strip()]


def judge(command: str) -> tuple[str, str | None]:
    """Classify one command that contains a fast-forward-only site. Returns (verb, finding)."""
    match = VERB_RE.search(command)
    verb = match.group(1) if match else "unknown"
    if AUTOSTASH_ON_RE.search(command):
        return verb, (
            f"{verb} --ff-only opts INTO autostash: {POP_CONFLICT}; drop --autostash, "
            "or gate on `git status --porcelain` and never on $?"
        )
    if NO_AUTOSTASH in command:
        return verb, None
    merge_off = bool(MERGE_OFF_RE.search(command))
    rebase_off = bool(REBASE_OFF_RE.search(command))
    if verb == "merge":
        if merge_off:
            return verb, None
        return verb, (
            "merge --ff-only leaves autostash to global config (merge.autoStash=true: "
            f"{POP_CONFLICT}); add --no-autostash or -c merge.autostash=false"
        )
    if verb == "pull":
        if merge_off and rebase_off:
            return verb, None
        if merge_off:
            return verb, (
                "pull --ff-only with only -c merge.autostash=false: under pull.rebase=true "
                "git pull passes an explicit --autostash to its merge, so this knob never "
                "reaches it (git 2.36+, measured 2.43.0); use --no-autostash"
            )
        if rebase_off:
            return verb, (
                "pull --ff-only with only -c rebase.autostash=false: with pull.rebase unset "
                "the merge honors merge.autoStash=true instead; use --no-autostash"
            )
        return verb, (
            "pull --ff-only leaves autostash to global config (pull.rebase + "
            f"rebase.autoStash: {POP_CONFLICT}); add --no-autostash"
        )
    return verb, (
        "--ff-only without pull or merge in the same command (a flag held in a "
        "variable, an echo'd string, or a subcommand on another line); put the "
        "subcommand and the flag in one command so its autostash rule can be "
        "checked, or spell the sentence without the flag"
    )


def audit_text(text: str) -> tuple[int, list[tuple[int, str]]]:
    """Return (site_count, [(lineno, finding), ...]) for one file's text."""
    sites = 0
    findings: list[tuple[int, str]] = []
    for lineno, line in logical_lines(text):
        if line.lstrip().startswith("#") or not SITE_RE.search(line):
            continue
        for command in commands(line):
            if not SITE_RE.search(command):
                continue
            sites += 1
            _verb, finding = judge(command)
            if finding:
                findings.append((lineno, finding))
    return sites, findings


def tracked_files(root: Path) -> list[str] | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [p for p in out.decode("utf-8", "replace").split("\0") if p]


def run(root: Path, floor: int) -> tuple[int, list[str]]:
    """Audit one checkout. Returns (exit_code, output_lines)."""
    files = tracked_files(root)
    if files is None:
        return 2, [
            f"WARN {LABEL}: {root} is not a git checkout (git ls-files failed) — "
            "refusing to report clean"
        ]
    lines: list[str] = []
    shell_files = 0
    sites = 0
    findings = 0
    for rel in sorted(files):
        if is_test_path(rel):
            continue
        path = root / rel
        if not path.is_file() or not is_shell_source(path):
            continue
        shell_files += 1
        try:
            text = path.read_bytes().decode("utf-8", "replace")
        except OSError:
            continue
        file_sites, file_findings = audit_text(text)
        sites += file_sites
        for lineno, why in file_findings:
            findings += 1
            lines.append(f"WARN {rel}:{lineno}: {why}")
    try:
        require_floor(sites, floor, LABEL)
    except FloorNotMet as exc:
        lines.append(f"{exc} ({shell_files} shell file(s) scanned under {root})")
        return 2, lines
    lines.append(
        f"{LABEL}: {findings} finding(s) across {sites} --ff-only call site(s) "
        f"in {shell_files} shell file(s) under {root}"
    )
    return (1 if findings else 0), lines


def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root", type=Path, default=default_root,
        help="checkout to scan (default: the repo this script lives in)",
    )
    parser.add_argument(
        "--floor", type=int, default=1,
        help="minimum --ff-only call sites before a clean verdict counts (default 1)",
    )
    args = parser.parse_args(argv)
    try:
        code, lines = run(args.root.resolve(), args.floor)
    except Exception as exc:  # noqa: BLE001 — a crash is not a verdict either way
        # Python's own unhandled-exception exit is 1, which a caller reading
        # exit codes would take for "findings" while no finding line exists.
        print(
            f"WARN {LABEL}: crashed before reaching a verdict "
            f"({type(exc).__name__}: {exc}) — refusing to report clean"
        )
        return 2
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
