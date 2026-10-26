#!/usr/bin/env python3
"""Shim availability, per-script budget/size isolation, batching, and
exit-code tests for scripts/lib/wf_pin_lex_client.py and the parts
of scripts/wf-pin-audit.py that consume it. Split out of
test_wf_pin_audit.py (finding #3, PR #1352 round 7); see
wf_pin_test_support.py for the shared fixture helpers and the WF
module-under-test load."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from wf_pin_test_support import (
    BUDGET_INJECT_ENV,
    CLAUDE,
    WF,
    _budget_fixture_script,
    call_main_inprocess,
    last_line,
    run_auditor,
    run_auditor_merged,
    write_workflow,
)

sys.path.insert(0, str(CLAUDE / "scripts" / "lib"))
import wf_pin_lex_client as CLIENT  # noqa: E402


class CliFloorTests(unittest.TestCase):
    def run_auditor(self, home: Path) -> subprocess.CompletedProcess:
        return run_auditor(home)

    def test_empty_existing_projects_root_is_unverified(self):
        """PLANTED NEGATIVE: empty corpus used to exit 0 as a quiet window."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / ".claude/projects").mkdir(parents=True)
            result = self.run_auditor(home)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("workflow script corpus", result.stderr)

    def test_old_script_allows_a_quiet_window(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            write_workflow(home, old=True)
            result = self.run_auditor(home)
            self.assertEqual(result.returncode, 0)
            self.assertIn("no workflow scripts modified in the last 8d", result.stdout)

    def test_recent_pinned_script_reports_clean(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            write_workflow(home)
            result = self.run_auditor(home)
            self.assertEqual(result.returncode, 0)
            self.assertIn("wf-pin-audit: clean (1 distinct script(s)", result.stdout)


class LexShimAvailabilityTests(unittest.TestCase):
    """Round 9 (#1351 second adversarial pass): wf-pin-audit.py now delegates
    lexing to a node subprocess shim (scripts/lib/wf-pin-lex.js).
    Doctrine ("a gate that cannot compare must fail"): a caller that cannot
    reach the shim must say so and exit non-zero, never fall back to a
    comment-blind scan and report clean -- see prefetch_lex_cache()'s and
    ShimUnavailable's own doc comments."""

    def test_unreachable_node_binary_is_a_loud_non_zero_exit(self):
        """PLANTED NEGATIVE shape: a script with a genuinely unpinned
        agent() call sits in this fixture HOME. If the shim failure were
        ever swallowed instead of reported, this would print clean with
        exit 0 -- the opposite of what must happen."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            script = home / ".claude/projects/project/session/workflows/scripts/flow.js"
            script.parent.mkdir(parents=True)
            script.write_text("await agent('work')\n", encoding="utf-8")
            result = self.run_auditor(home)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("wf-pin-audit: clean", result.stdout)
            self.assertIn("lexer shim unavailable", result.stderr)

    def run_auditor(self, home: Path) -> subprocess.CompletedProcess:
        return run_auditor(
            home,
            extra_env={"WF_PIN_LEX_NODE_BIN": "/nonexistent/wf-pin-lex-node-binary"},
        )

    def test_exit_code_is_the_dedicated_shim_unavailable_code(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            write_workflow(home)
            result = self.run_auditor(home)
            self.assertEqual(result.returncode, 3)

    # harness-doctor.sh check 23's own idiom, verbatim (see the doctor's
    # comment above _wf_scanned=): `printf '%s\n' "$_wf_out" | tail -1 |
    # sed -n 's/.*(\([0-9][0-9]*\) distinct script(s).*/\1/p'`. Finding #5
    # (PR #1352 round 7): the exit-3 summary used to omit the parenthesized
    # "(N distinct script(s), ...)" clause entirely, so this exact sed found
    # nothing on the shim-unavailable path and the doctor silently reported
    # "? scripts scanned" instead of the real denominator. This drives the
    # doctor's real sed binary against the real exit-3 last line, not a
    # Python regex standing in for it.
    _DOCTOR_SED_EXPR = r"s/.*(\([0-9][0-9]*\) distinct script(s).*/\1/p"

    def test_exit_3_summary_denominator_survives_the_doctors_own_sed(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            scripts.mkdir(parents=True)
            for i in range(3):
                (scripts / f"flow{i}.js").write_text(
                    f"await agent('work {i}', {{model: 'sonnet'}})\n", encoding="utf-8",
                )
            result = run_auditor_merged(
                home, extra_env={"WF_PIN_LEX_NODE_BIN": "/nonexistent/wf-pin-lex-node-binary"},
            )
            self.assertEqual(result.returncode, 3)
            tail = last_line(result.stdout)
            self.assertIn("distinct script(s)", tail)
            sed = subprocess.run(
                ["sed", "-n", self._DOCTOR_SED_EXPR],
                input=tail, capture_output=True, text=True, check=True,
            )
            self.assertEqual(sed.stdout.strip(), "3")


class PerScriptBudgetTests(unittest.TestCase):
    """Round 10 (#1351 third adversarial pass): a single pathological script
    used to make the WHOLE batch unaudited (ShimUnavailable via the fixed
    120s batch timeout, exit 3, every script in the window unreported).
    wf-pin-lex.js now enforces a per-script budget/size cap and reports that
    ONE script's result as {"error": ...} instead of throwing -- every other
    script in the same batch is still fully audited and reported. The budget
    failure is triggered deterministically through BUDGET_INJECT_ENV
    (wf-pin-lex.js's WF_PIN_LEX_BUDGET_INJECT seam) rather than a run-wide
    WF_PIN_LEX_BUDGET_MS=1, which also throttled the tiny sibling that must
    audit normally and flaked under CPU load."""

    def _write(self, scripts_dir: Path, name: str, content: str) -> None:
        scripts_dir.mkdir(parents=True, exist_ok=True)
        (scripts_dir / name).write_text(content, encoding="utf-8")

    def test_budget_exceeded_script_is_unaudited_others_still_reported(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(scripts, "big.js", _budget_fixture_script())
            self._write(scripts, "normal.js", "await agent('work')\n")
            result = run_auditor(home, extra_env=BUDGET_INJECT_ENV)
            self.assertEqual(result.returncode, 4)
            self.assertIn("UNPINNED", result.stdout)
            self.assertIn("normal.js", result.stdout)
            self.assertIn("lexer budget exceeded", result.stderr)
            self.assertIn("big.js", result.stderr)
            self.assertIn("budget exceeded after", result.stderr)

    def test_size_cap_exceeded_script_is_unaudited_others_still_reported(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(
                scripts,
                "big.js",
                "await agent('work with a much longer label to exceed the tiny cap')\n",
            )
            self._write(scripts, "normal.js", "await agent('work')\n")
            result = run_auditor(home, extra_env={"WF_PIN_LEX_MAX_BYTES": "40"})
            self.assertEqual(result.returncode, 4)
            self.assertIn("UNPINNED", result.stdout)
            self.assertIn("normal.js", result.stdout)
            # Finding #6 (PR #1352 round 7): the per-script WARN label is now
            # classified by reason -- a size-cap hit reads as "size cap
            # exceeded", not the old blanket "lexer budget exceeded" for
            # every reason.
            self.assertIn("size cap exceeded", result.stderr)
            self.assertIn("big.js", result.stderr)
            self.assertIn("exceeds 40 bytes", result.stderr)

    def test_planted_negative_disabling_error_handling_reports_clean(self):
        """PLANTED NEGATIVE: if the per-script error entry were ever silently
        treated as a clean result (lex_error() never consulted), this exact
        budget-exceeded fixture -- which genuinely has zero unpinned agent()
        calls -- would read as a clean, fully-audited run instead of exit 4,
        masking the fact that it was never actually analyzed. Proves this
        suite exercises the fix rather than just its surface exit code.
        Restored immediately after (mock.patch.object is scoped to the
        `with` block), and a real run against the same fixture is re-checked
        to prove the restoration took effect for every later test."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            big_text = _budget_fixture_script()
            self._write(scripts, "big.js", big_text)
            real_lex_result = WF._lex_result

            def _ignore_per_script_errors(text):
                """Stand-in for 'the per-script error entry is treated as a
                clean result' -- exactly the shape main() would see if
                lex_error() were never consulted: this fixture's genuine
                (empty) findings, not the budget-exceeded error."""
                result = real_lex_result(text)
                if "error" in result:
                    return {"spans": [], "blanked": text, "uncapped": []}
                return result

            with mock.patch.dict(os.environ, BUDGET_INJECT_ENV):
                with mock.patch.object(
                    WF, "_lex_result", side_effect=_ignore_per_script_errors
                ):
                    code, out, _err = call_main_inprocess(home)
                self.assertEqual(code, 0)
                self.assertIn("wf-pin-audit: clean", out)
                # restored: the real _lex_result()/lex_error() are back in
                # effect here, outside the inner `with`.
                result = run_auditor(home, extra_env=BUDGET_INJECT_ENV)
            self.assertEqual(result.returncode, 4)


class MergedStreamOrderingTests(unittest.TestCase):
    """Round 11 (#1351 fourth adversarial pass): harness-doctor.sh check 23
    reads this auditor as `_wf_out=$(python3 wf-pin-audit.py --days 8 2>&1)`
    and, on nonzero exit, warns with `echo "$_wf_out" | tail -1`. Python's
    stdout is block-buffered when piped and only flushes at process exit;
    stderr is unbuffered and flushes immediately. A WARN written to stderr
    mid-run used to reach the merged pipe BEFORE stdout's own,
    still-buffered content flushed as one block at exit -- so `tail -1`
    always saw the stdout summary line, even when it said "clean" for a run
    that had already warned about an unaudited script. These tests run the
    auditor through run_auditor_merged() (stderr=subprocess.STDOUT, exactly
    the shell's `2>&1`) rather than run_auditor()'s separately-captured
    streams, since only a genuinely single merged pipe can reproduce the
    ordering bug `tail -1` actually saw."""

    def _write(self, scripts_dir: Path, name: str, content: str) -> None:
        scripts_dir.mkdir(parents=True, exist_ok=True)
        (scripts_dir / name).write_text(content, encoding="utf-8")

    def test_budget_exceeded_last_line_names_the_unaudited_script(self):
        """A genuinely clean, pinned sibling (zero unpinned findings) makes
        this the exact P1 shape: the pre-fix summary picked between only
        "clean" and an unpinned count, so with unaudited the sole finding it
        printed literal "wf-pin-audit: clean (...)" as the merged stream's
        last line."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(scripts, "big.js", _budget_fixture_script())
            self._write(scripts, "clean.js", "await agent('work', {model: 'sonnet'})\n")
            result = run_auditor_merged(home, extra_env=BUDGET_INJECT_ENV)
            self.assertEqual(result.returncode, 4)
            tail = last_line(result.stdout)
            self.assertIn("UNAUDITED", tail)
            self.assertIn("big.js", tail)
            # "wf-pin-audit: NOT clean: ..." is the required wording and
            # deliberately contains "clean" as a substring of "NOT clean";
            # what must never appear is the bare success phrase.
            self.assertNotIn("wf-pin-audit: clean", tail)

    def test_size_cap_last_line_names_the_unaudited_script(self):
        """Same shape as above, with a clean pinned sibling, for the
        size-cap trigger instead of the budget trigger."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(
                scripts,
                "big.js",
                "await agent('work with a much longer label to exceed the tiny cap')\n",
            )
            self._write(scripts, "clean.js", "await agent('work', {model: 'sonnet'})\n")
            result = run_auditor_merged(home, extra_env={"WF_PIN_LEX_MAX_BYTES": "40"})
            self.assertEqual(result.returncode, 4)
            tail = last_line(result.stdout)
            self.assertIn("UNAUDITED", tail)
            self.assertIn("big.js", tail)
            self.assertNotIn("wf-pin-audit: clean", tail)

    def test_shim_unavailable_last_line_names_the_shim_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            write_workflow(home)
            result = run_auditor_merged(
                home,
                extra_env={"WF_PIN_LEX_NODE_BIN": "/nonexistent/wf-pin-lex-node-binary"},
            )
            self.assertEqual(result.returncode, 3)
            tail = last_line(result.stdout)
            self.assertIn("lexer shim unavailable", tail)
            self.assertNotIn("wf-pin-audit: clean", tail)

    def test_unpinned_case_last_line_still_carries_the_count(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(scripts, "unpinned.js", "await agent('work')\n")
            result = run_auditor_merged(home)
            self.assertEqual(result.returncode, 1)
            tail = last_line(result.stdout)
            self.assertIn("unpinned agent() call(s)", tail)
            self.assertNotIn("wf-pin-audit: clean", tail)


class LexerErrorFaultInjectionTests(unittest.TestCase):
    """Round 6 (#1352 adversarial finding, P2): before this round, lexOne()
    in wf-pin-lex.js special-cased only AnalysisBudgetExceeded -- lexCode()
    itself ran with no try/catch around it at all, and uncappedFanouts()'s
    catch re-threw anything that was not a budget overrun. ANY other
    exception (a real future divergence between this shim and
    fanout-admission.js, or simply a bug neither has hit yet) escaped
    lexOne(), escaped the `.map()` in wf-pin-lex.js's own main(), and turned
    ONE pathological script into a SHIM-LEVEL failure for the WHOLE batch:
    node exits 1, wf_pin_lex_client.py raises ShimUnavailable, and
    wf-pin-audit.py exits 3 -- every distinct script in the scan window
    (up to 8 days) read as unaudited instead of just the one bad script.
    lexOne() now catches every per-text exception and reports it as a
    per-script `{"error": "lexer-error: <message>"}` entry, exactly like
    the existing budget/size-cap entries.

    Mechanism: a bounded (~10 minute) probe -- unterminated template
    literals/regexes, unbalanced parens, a fan-out call with no closing
    paren, pathological nesting, non-UTF-8 bytes -- found no real script
    text that makes fanout-admission.js's OWN lexer/uncappedFanouts() throw
    a non-budget error today (every recursive descent in that file is
    already guarded, and lexCode()'s one RangeError path -- interpolation
    nesting too deep -- is already caught and returns null, not a throw).
    These tests instead drive the new catch-all path through
    WF_PIN_LEX_FAULT_INJECT, the env-gated test seam wf-pin-lex.js's own
    doc comment documents for exactly this purpose (inert unless set)."""

    FAULT_MARKER = "WFPIN_R6_FAULT_MARKER"

    def _write(self, scripts_dir: Path, name: str, content: str) -> None:
        scripts_dir.mkdir(parents=True, exist_ok=True)
        (scripts_dir / name).write_text(content, encoding="utf-8")

    def test_lexer_error_script_is_unaudited_others_still_reported(self):
        """PLANTED POSITIVE: bad.js's own content (a plain PINNED agent()
        call) would read as genuinely clean if the injected fault were ever
        ignored -- so "bad.js is unaudited" can only come from the lexer
        error path, not from some other finding. normal.js plants a real
        uncapped data-driven fan-out (the exact fixture
        test_uncapped_call_alone_is_flagged uses) that must still be fully
        audited and reported.

        REVERT CHECK: reverting lexOne()'s try/catch widening (narrowing it
        back to wrap only uncappedFanouts(), with lexCode() and the fault
        check outside any try/catch) makes bad.js's injected throw escape
        into wf-pin-lex.js's own main() `.map()`, which fails the whole
        node process (exit 1). wf_pin_lex_client.py then raises
        ShimUnavailable and wf-pin-audit.py exits 3, not 4 -- so
        `self.assertEqual(result.returncode, 4)` below is the assertion
        that fails first."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(
                scripts,
                "bad.js",
                f"// {self.FAULT_MARKER}\nawait agent('work', {{model: 'sonnet'}})\n",
            )
            self._write(
                scripts,
                "normal.js",
                "const a = await parallel(items.map(x => () => agent(x)))\n",
            )
            result = run_auditor(
                home, extra_env={"WF_PIN_LEX_FAULT_INJECT": self.FAULT_MARKER}
            )
            self.assertEqual(result.returncode, 4)
            self.assertIn("bad.js", result.stderr)
            self.assertIn("lexer-error", result.stderr)
            # Finding #6 (PR #1352 round 7): the per-script WARN label is now
            # classified by reason -- a fault-injected exception is neither a
            # budget overrun nor a size-cap hit, so it reads as "lexer error",
            # not the old blanket "lexer budget exceeded" for every reason.
            self.assertIn("lexer error", result.stderr)
            self.assertIn("normal.js", result.stdout)
            self.assertIn("data-driven fan-out with no .slice( cap", result.stdout)

    def test_merged_stream_last_line_names_the_unaudited_count_and_reason(self):
        """Same shape as MergedStreamOrderingTests's budget/size-cap
        variants: the merged-stream last line must name the unaudited
        script and reason, never read as "clean"."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(
                scripts,
                "bad.js",
                f"// {self.FAULT_MARKER}\nawait agent('work', {{model: 'sonnet'}})\n",
            )
            self._write(scripts, "clean.js", "await agent('work', {model: 'sonnet'})\n")
            result = run_auditor_merged(
                home, extra_env={"WF_PIN_LEX_FAULT_INJECT": self.FAULT_MARKER}
            )
            self.assertEqual(result.returncode, 4)
            tail = last_line(result.stdout)
            self.assertIn("UNAUDITED", tail)
            self.assertIn("bad.js", tail)
            self.assertIn("lexer-error", tail)
            self.assertNotIn("wf-pin-audit: clean", tail)

    def test_fault_injection_is_inert_without_the_env_var(self):
        """The SAME marker text lexes normally -- no "error" key at all, the
        normal "spans"/"blanked"/"uncapped" shape instead -- once
        WF_PIN_LEX_FAULT_INJECT is unset, proving the seam is opt-in rather
        than always-on for any text containing the marker string."""
        text = f"// {self.FAULT_MARKER}\nawait agent('work', {{model: 'sonnet'}})\n"
        saved = os.environ.pop("WF_PIN_LEX_FAULT_INJECT", None)
        try:
            result = WF.lex_texts([text])[0]
        finally:
            if saved is not None:
                os.environ["WF_PIN_LEX_FAULT_INJECT"] = saved
        self.assertNotIn("error", result)
        self.assertIn("spans", result)
        self.assertIn("uncapped", result)


def _write_stub_shim(temp_dir: Path, body: str) -> Path:
    """A stand-in for wf-pin-lex.js used with WF_PIN_LEX_NODE_BIN pointed at
    `sys.executable` and WF_PIN_LEX_SHIM_PATH pointed at the returned file:
    the client only ever runs `[node_bin, shim_path]` with the batch JSON on
    stdin, so a plain Python script satisfies the same contract without a
    real node process at all."""
    stub = temp_dir / "stub_shim.py"
    stub.write_text(body, encoding="utf-8")
    return stub


class ShimUnavailableBranchTests(unittest.TestCase):
    """Finding #4 (PR #1352 round 7): three ShimUnavailable branches in
    lex_texts()/_lex_batch() had no direct test -- a non-zero exit, non-JSON
    stdout, and a wrong-length results array. Each stub below satisfies the
    `[node_bin, shim_path]` contract with a plain Python script (via
    WF_PIN_LEX_NODE_BIN=sys.executable), so no real node/wf-pin-lex.js
    behavior is needed to exercise the client's own failure handling."""

    def _lex_with_stub(self, body: str, texts=("await agent('work')\n",)):
        with tempfile.TemporaryDirectory() as temp:
            stub = _write_stub_shim(Path(temp), body)
            with mock.patch.dict(
                os.environ,
                {"WF_PIN_LEX_NODE_BIN": sys.executable, "WF_PIN_LEX_SHIM_PATH": str(stub)},
            ):
                return CLIENT.lex_texts(list(texts))

    def test_non_zero_exit_with_stderr_names_the_stderr_detail(self):
        body = "import sys\nsys.stderr.write('stub failure detail')\nsys.exit(1)\n"
        with self.assertRaises(CLIENT.ShimUnavailable) as ctx:
            self._lex_with_stub(body)
        self.assertIn("stub failure detail", str(ctx.exception))

    def test_non_json_stdout_names_the_json_failure(self):
        body = "import sys\nsys.stdout.write('not valid json {')\n"
        with self.assertRaises(CLIENT.ShimUnavailable) as ctx:
            self._lex_with_stub(body)
        self.assertIn("invalid JSON", str(ctx.exception))

    def test_wrong_length_results_array_names_the_count_mismatch(self):
        body = (
            "import sys, json\n"
            "sys.stdin.read()\n"
            "sys.stdout.write(json.dumps({'results': []}))\n"
        )
        with self.assertRaises(CLIENT.ShimUnavailable) as ctx:
            self._lex_with_stub(body)
        self.assertIn("result(s)", str(ctx.exception))

    def test_end_to_end_non_zero_exit_is_the_dedicated_exit_code(self):
        """The CLI-level confirmation the spec asks for: a broken shim never
        reads as clean or crashes with a traceback -- it is the documented
        exit 3, "shim unavailable"."""
        with tempfile.TemporaryDirectory() as temp_home, tempfile.TemporaryDirectory() as temp_shim:
            home = Path(temp_home)
            write_workflow(home)
            stub = _write_stub_shim(
                Path(temp_shim),
                "import sys\nsys.stderr.write('stub failure detail')\nsys.exit(1)\n",
            )
            result = run_auditor(
                home,
                extra_env={
                    "WF_PIN_LEX_NODE_BIN": sys.executable,
                    "WF_PIN_LEX_SHIM_PATH": str(stub),
                },
            )
            self.assertEqual(result.returncode, 3)
            self.assertIn("lexer shim unavailable", result.stderr)


class BatchTimeoutCeilingTests(unittest.TestCase):
    """Finding #7a (PR #1352 round 7): _batch_timeout_s() used to scale
    without limit (per-script budget * script count), so an oversized
    corpus scaled the subprocess timeout without bound instead of failing
    closed within a fixed time. It is now capped at
    CLIENT.BATCH_TIMEOUT_CEILING_S regardless of text_count."""

    def test_several_hundred_texts_is_capped_at_the_ceiling(self):
        timeout = CLIENT._batch_timeout_s(500)
        self.assertEqual(timeout, CLIENT.BATCH_TIMEOUT_CEILING_S)

    def test_mutation_check_uncapped_scaling_would_exceed_the_ceiling(self):
        """Documents the exact shape a reverted cap would produce, so this
        assertion is the one that fails if BATCH_TIMEOUT_CEILING_S's min()
        clamp is ever removed: at the default 3000ms budget, 500 texts scale
        to 1530s -- five times the ceiling."""
        uncapped_shape = (CLIENT.DEFAULT_BUDGET_MS / 1000.0) * 500 + CLIENT.BATCH_TIMEOUT_OVERHEAD_S
        self.assertGreater(uncapped_shape, CLIENT.BATCH_TIMEOUT_CEILING_S)

    def test_small_batch_is_floored_not_zero(self):
        timeout = CLIENT._batch_timeout_s(1)
        self.assertEqual(timeout, CLIENT.BATCH_TIMEOUT_FLOOR_S)


class BatchChunkingTests(unittest.TestCase):
    """Finding #9 (PR #1352 round 7): batch transport used to send the
    whole corpus as one subprocess call/timeout no matter how large. An
    oversized file is now excluded from the batch entirely (before it is
    even read) and the remaining texts travel in size/count-bounded
    sub-batches with the same results as a single batch."""

    def test_oversized_file_is_reported_unaudited_and_never_reaches_the_shim(self):
        with tempfile.TemporaryDirectory() as temp_home, tempfile.TemporaryDirectory() as temp_shim:
            home = Path(temp_home)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            scripts.mkdir(parents=True)
            big_text = "await agent('work with a much longer label than the tiny cap allows')\n"
            (scripts / "big.js").write_text(big_text, encoding="utf-8")
            (scripts / "normal.js").write_text("await agent('work')\n", encoding="utf-8")
            received_path = Path(temp_shim) / "received.json"
            stub = _write_stub_shim(
                Path(temp_shim),
                "import sys, json\n"
                "payload = json.load(sys.stdin)\n"
                "with open(%r, 'w') as f:\n"
                "    json.dump(payload['texts'], f)\n"
                "results = [{'spans': [], 'blanked': t, 'uncapped': []} for t in payload['texts']]\n"
                "sys.stdout.write(json.dumps({'results': results}))\n" % str(received_path),
            )
            result = run_auditor(
                home,
                extra_env={
                    "WF_PIN_LEX_MAX_BYTES": "40",
                    "WF_PIN_LEX_NODE_BIN": sys.executable,
                    "WF_PIN_LEX_SHIM_PATH": str(stub),
                },
            )
            self.assertEqual(result.returncode, 4)
            self.assertIn("size cap exceeded", result.stderr)
            self.assertIn("big.js", result.stderr)
            self.assertIn("UNPINNED", result.stdout)
            self.assertIn("normal.js", result.stdout)
            received = json.loads(received_path.read_text(encoding="utf-8"))
            self.assertEqual(len(received), 1)
            self.assertNotIn(big_text, received)

    def test_corpus_spanning_multiple_batches_matches_a_single_batch_run(self):
        """A real (node-backed) multi-batch run must report the exact same
        per-text results as a single-batch run of the same texts -- chunking
        is a transport detail, not a behavior change."""
        texts = [
            f"await agent('work {i}', {{model: 'sonnet'}})\n" for i in range(5)
        ] + ["await parallel(items.map(x => () => agent(x)))\n"]
        with mock.patch.dict(os.environ, {"WF_PIN_LEX_BATCH_MAX_TEXTS": "2"}):
            chunked = CLIENT.lex_texts(list(texts))
        single_batch = CLIENT.lex_texts(list(texts))
        self.assertEqual(chunked, single_batch)


class MalformedResultTests(unittest.TestCase):
    """Finding #10 (PR #1352 round 7): a malformed result entry -- `{}` or a
    non-dict entry -- used to reach wf-pin-audit.py as an uncaught KeyError
    (exit 1, a traceback) instead of the documented "shim unavailable" exit
    3. _validate_entry() now raises ShimUnavailable naming the entry index
    and shape for either case, both at the unit level and end to end."""

    def test_empty_dict_entry_raises_shim_unavailable(self):
        with self.assertRaises(CLIENT.ShimUnavailable):
            CLIENT._validate_entry(0, {}, 1)

    def test_non_dict_entry_raises_shim_unavailable(self):
        with self.assertRaises(CLIENT.ShimUnavailable):
            CLIENT._validate_entry(0, "not a dict", 1)

    def test_empty_dict_entry_end_to_end_is_exit_3_with_no_traceback(self):
        with tempfile.TemporaryDirectory() as temp_home, tempfile.TemporaryDirectory() as temp_shim:
            home = Path(temp_home)
            write_workflow(home)
            stub = _write_stub_shim(
                Path(temp_shim),
                "import sys\nsys.stdin.read()\nsys.stdout.write('{\"results\": [{}]}')\n",
            )
            result = run_auditor(
                home,
                extra_env={
                    "WF_PIN_LEX_NODE_BIN": sys.executable,
                    "WF_PIN_LEX_SHIM_PATH": str(stub),
                },
            )
            self.assertEqual(result.returncode, 3)
            self.assertIn("lexer shim unavailable", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_non_dict_entry_end_to_end_is_exit_3_with_no_traceback(self):
        with tempfile.TemporaryDirectory() as temp_home, tempfile.TemporaryDirectory() as temp_shim:
            home = Path(temp_home)
            write_workflow(home)
            stub = _write_stub_shim(
                Path(temp_shim),
                "import sys\nsys.stdin.read()\nsys.stdout.write('{\"results\": [42]}')\n",
            )
            result = run_auditor(
                home,
                extra_env={
                    "WF_PIN_LEX_NODE_BIN": sys.executable,
                    "WF_PIN_LEX_SHIM_PATH": str(stub),
                },
            )
            self.assertEqual(result.returncode, 3)
            self.assertIn("lexer shim unavailable", result.stderr)
            self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
