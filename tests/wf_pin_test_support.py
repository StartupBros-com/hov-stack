"""Shared fixtures/helpers for the wf-pin-audit test suite.

Finding #3 (PR #1352 round 7): test_wf_pin_audit.py grew to 1,137 lines
across 19 test classes. It is now split by subject into
test_wf_pin_audit.py (fan-out scope, schema/comment lexing regressions,
pin detection), test_wf_pin_lex_client.py (shim availability, per-script
budget/size isolation, batching, exit codes), and
test_wf_pin_audit_schema.py (schema-breadth counting). This module is the
ONE place the shared `WF` module-under-test load and the fixture helpers
below live, so none of the three test files duplicates them.
"""

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import time
from pathlib import Path
from unittest import mock

CLAUDE = Path(__file__).resolve().parents[1]
AUDITOR = CLAUDE / "scripts" / "wf-pin-audit.py"

_spec = importlib.util.spec_from_file_location("wf_pin_audit_module", AUDITOR)
WF = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(WF)


def lines_of(source: str) -> list[int]:
    """1-indexed line numbers of the uncapped fan-outs in source."""
    stripped = WF.blank_strings(source)
    return [source.count("\n", 0, start) + 1 for start, _ in WF.uncapped_fanouts(stripped)]


def write_workflow(home: Path, *, old: bool = False) -> None:
    script = home / ".claude/projects/project/session/workflows/scripts/flow.js"
    script.parent.mkdir(parents=True)
    script.write_text("await agent('work', {model: 'sonnet'})\n", encoding="utf-8")
    if old:
        stamp = time.time() - 30 * 86400
        os.utime(script, (stamp, stamp))


def run_auditor(
    home: Path, agents_dir: Path = None, extra_env: dict | None = None
) -> subprocess.CompletedProcess:
    """Run the CLI against a fixture HOME.

    Defaults --agents-dir to a sibling directory that need not exist: every
    pre-existing CLI test here scans a throwaway fixture HOME, not the live
    repo's agents/*.md, unless a test opts into a real agents dir.
    extra_env layers on top of (and can override) the inherited environment
    -- used by the shim-availability tests below to point
    WF_PIN_LEX_NODE_BIN at a nonexistent binary without touching PATH.
    """
    if agents_dir is None:
        agents_dir = home / "agents-fixture"
    return subprocess.run(
        [sys.executable, str(AUDITOR), "--days", "8", "--agents-dir", str(agents_dir)],
        capture_output=True, text=True,
        env={**os.environ, "HOME": str(home), **(extra_env or {})}, check=False,
    )


def run_auditor_merged(
    home: Path, agents_dir: Path = None, extra_env: dict | None = None
) -> subprocess.CompletedProcess:
    """Run the CLI exactly through harness-doctor.sh check 23's own idiom:
    `python3 wf-pin-audit.py --days 8 2>&1`, stdout and stderr merged into
    ONE pipe (stderr=subprocess.STDOUT), not captured separately the way
    run_auditor() does. Ordering bugs between stdout's block buffering and
    stderr's unbuffered writes (round 11, #1351 fourth adversarial pass) are
    invisible to run_auditor()'s separate capture -- both streams reach the
    test process's memory in real time either way -- so only a genuinely
    merged single pipe reproduces what `tail -1` actually sees."""
    if agents_dir is None:
        agents_dir = home / "agents-fixture"
    return subprocess.run(
        [sys.executable, str(AUDITOR), "--days", "8", "--agents-dir", str(agents_dir)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        env={**os.environ, "HOME": str(home), **(extra_env or {})}, check=False,
    )


def last_line(text: str) -> str:
    """The last line of merged output, matching the shell's `tail -1`: a
    trailing newline contributes no extra empty line, but a genuinely blank
    final line (there is none on any path here) would still be returned
    as-is rather than skipped."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines[-1] if lines else ""


# The budget fixture's first line carries this marker; BUDGET_INJECT_ENV points
# wf-pin-lex.js's WF_PIN_LEX_BUDGET_INJECT test seam at it, so exactly that one
# script starts over budget (through the real AnalysisBudgetExceeded path)
# while every sibling in the same run keeps the real per-script budget. A
# run-wide WF_PIN_LEX_BUDGET_MS=1 used to do this job and flaked under CPU
# load: the tiny sibling that must audit normally exceeded 1ms too.
BUDGET_FIXTURE_MARKER = "wf-pin-lex budget fixture"
BUDGET_INJECT_ENV = {"WF_PIN_LEX_BUDGET_INJECT": BUDGET_FIXTURE_MARKER}


def _budget_fixture_script(declarations: int = 50000) -> str:
    """A synthetic script, marked on its first line with BUDGET_FIXTURE_MARKER,
    with tens of thousands of plain declarations and NO agent() calls at all
    -- a realistic slow shape (uncappedFanouts() runs
    findAllDeclarationPositions() unconditionally) that genuinely contains
    zero unpinned agent() calls, which the planted-negative test depends on:
    a script that would read as CLEAN, not merely quiet, if its per-script
    error were ever silently treated as a normal result. Its budget failure
    is triggered deterministically by BUDGET_INJECT_ENV, not by timing."""
    lines = [f"// {BUDGET_FIXTURE_MARKER}"]
    lines.extend(f"const helper_{i} = 0" for i in range(declarations))
    return "\n".join(lines) + "\n"


def call_main_inprocess(home: Path, agents_dir: Path = None) -> tuple[int, str, str]:
    """Invoke WF.main() in THIS test process rather than via run_auditor()'s
    subprocess, so a test can monkeypatch a WF module function (e.g.
    lex_error()) for the duration of one run -- a subprocess runs a fresh
    interpreter and could never see a patch made here. Path.home() and
    sys.argv are patched to point at the fixture HOME the same way
    run_auditor()'s subprocess env does."""
    if agents_dir is None:
        agents_dir = home / "agents-fixture"
    argv = ["wf-pin-audit.py", "--days", "8", "--agents-dir", str(agents_dir)]
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(sys, "argv", argv), mock.patch(
        "pathlib.Path.home", return_value=home
    ), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = WF.main()
    return code, out.getvalue(), err.getvalue()


def _req(n: int) -> str:
    """A required: array literal with n single-quoted entries."""
    return "[" + ", ".join("'f%d'" % i for i in range(n)) + "]"


def schema_lines(source: str) -> list[tuple[int, int, int]]:
    """(1-indexed line, required-count, limit) per over-demanding schema."""
    return [
        (source.count("\n", 0, off) + 1, count, limit)
        for off, count, limit in WF.overdemanding_schemas(source)
    ]
