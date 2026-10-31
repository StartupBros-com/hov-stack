#!/usr/bin/env python3
"""Fixture tests for the rent-check fact engine.

Every check is asserted in BOTH directions: it fires on a known-bad fixture
and stays quiet on a known-good one. A gate that only ever passes measures
nothing -- the skill says so about other people's CI, and it applies here.

Run: python3 rent-check.test.py
"""

from __future__ import annotations

import io
import json
import contextlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import importlib.util

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rent_check", HERE / "rent-check.py")
assert spec and spec.loader
rc = importlib.util.module_from_spec(spec)
# Register before exec: @dataclass resolves annotations via
# sys.modules[cls.__module__], which is absent for an unregistered module.
sys.modules["rent_check"] = rc
spec.loader.exec_module(rc)


def run(argv: list[str]) -> tuple[int, dict]:
    """Invoke a subcommand, capture stdout, parse the JSON payload."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = rc.main(argv + ["--json"])
    out = buf.getvalue().strip()
    return code, (json.loads(out) if out.startswith("{") else {})


class TempTree(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, rel: str, text: str) -> Path:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p


class TestInventory(TempTree):
    def test_finds_files_at_any_depth(self) -> None:
        self.write("AGENTS.md", "# root\n")
        self.write("a/b/c/d/e/f/AGENTS.md", "# deep\n")
        code, out = run(["inventory", str(self.root)])
        self.assertEqual(code, 0)
        self.assertEqual(out["file_count"], 2, "a depth cap would silently miss the deep file")

    def test_prunes_by_name_not_depth(self) -> None:
        self.write("AGENTS.md", "# root\n")
        self.write("node_modules/pkg/AGENTS.md", "# vendored\n")
        _, out = run(["inventory", str(self.root)])
        self.assertEqual(out["file_count"], 1)

    def test_root_is_always_loaded_subdir_is_on_read(self) -> None:
        self.write("AGENTS.md", "# root\n")
        self.write("sub/AGENTS.md", "# sub\n")
        _, out = run(["inventory", str(self.root)])
        classes = {Path(f["path"]).parent.name: f["load_class"] for f in out["files"]}
        self.assertEqual(classes[self.root.name], "always-loaded")
        self.assertEqual(classes["sub"], "on-read")

    def test_calibrated_estimate_exceeds_floor(self) -> None:
        self.write("AGENTS.md", "word " * 500)
        _, out = run(["inventory", str(self.root)])
        f = out["files"][0]
        self.assertGreater(f["est_tokens_calibrated"], f["est_tokens_floor"],
                           "chars/4 is a floor; the calibrated figure must exceed it")


class TestVcsVisibility(TempTree):
    """A context file nobody can see still steers every local agent.

    Asserted in both directions: the field must distinguish tracked from
    untracked, and must degrade to an explicit "unavailable" outside git
    rather than silently claiming either.
    """

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.root), *args],
                       check=True, capture_output=True)

    def init_repo(self) -> None:
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")

    def test_untracked_context_file_is_named(self) -> None:
        self.init_repo()
        self.write("AGENTS.md", "# untracked\n")
        _, out = run(["inventory", str(self.root)])
        rec = out["files"][0]
        self.assertEqual(rec["vcs"]["state"], "untracked")
        self.assertIn("git clean", rec["vcs"]["detail"])
        self.assertEqual(len(out["untracked_context_files"]), 1)

    def test_tracked_context_file_is_clean(self) -> None:
        self.init_repo()
        self.write("AGENTS.md", "# tracked\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "add")
        _, out = run(["inventory", str(self.root)])
        self.assertEqual(out["files"][0]["vcs"]["state"], "tracked")
        self.assertEqual(out["untracked_context_files"], [])

    def test_gitignored_untracked_file_is_distinguished(self) -> None:
        # The better-ccflare shape: ignored AND untracked, so it loads locally
        # and freezes while its tracked twin keeps moving.
        self.init_repo()
        self.write(".gitignore", "AGENTS.md\n")
        self.write("AGENTS.md", "# local-only\n")
        _, out = run(["inventory", str(self.root)])
        rec = next(f for f in out["files"] if f["path"].endswith("AGENTS.md"))
        self.assertEqual(rec["vcs"]["state"], "untracked-ignored")
        self.assertIn("invisible", rec["vcs"]["detail"])

    def test_force_added_tracked_ignored_is_named(self) -> None:
        self.init_repo()
        self.write(".gitignore", "CLAUDE.md\n")
        self.write("CLAUDE.md", "# force-added\n")
        self.git("add", "-f", "CLAUDE.md")
        self.git("commit", "-qm", "force add")
        _, out = run(["inventory", str(self.root)])
        rec = next(f for f in out["files"] if f["path"].endswith("CLAUDE.md"))
        self.assertEqual(rec["vcs"]["state"], "tracked-ignored")
        self.assertEqual(out["untracked_context_files"], [])

    def test_outside_git_degrades_explicitly(self) -> None:
        self.write("AGENTS.md", "# no repo\n")
        _, out = run(["inventory", str(self.root)])
        self.assertEqual(out["files"][0]["vcs"]["state"], "unavailable")
        self.assertTrue(out["files"][0]["vcs"]["detail"],
                        "degradation must name its reason, never skip silently")


class TestCheckoutFreshness(TempTree):
    """A stale checkout answers a different question than the one asked.

    Both directions: `stale` must appear with the distance when the checkout
    is behind, `current` when it is level, and every unjudgeable case must
    name itself rather than defaulting to either.
    """

    def git(self, *args: str, cwd: Path | None = None) -> None:
        subprocess.run(["git", "-C", str(cwd or self.root), *args],
                       check=True, capture_output=True)

    def make_clone_behind(self, n: int) -> Path:
        """An origin with n commits the clone has not pulled."""
        origin = self.root / "origin"
        origin.mkdir()
        self.git("init", "-q", "--bare", cwd=origin) if False else None
        subprocess.run(["git", "init", "-q", str(origin)], check=True, capture_output=True)
        self.git("config", "user.email", "t@example.com", cwd=origin)
        self.git("config", "user.name", "t", cwd=origin)
        (origin / "AGENTS.md").write_text("# v1\n", encoding="utf-8")
        self.git("add", "AGENTS.md", cwd=origin)
        self.git("commit", "-qm", "v1", cwd=origin)

        clone = self.root / "clone"
        subprocess.run(["git", "clone", "-q", str(origin), str(clone)],
                       check=True, capture_output=True)

        for i in range(n):
            (origin / "AGENTS.md").write_text(f"# v{i + 2}\n", encoding="utf-8")
            self.git("add", "AGENTS.md", cwd=origin)
            self.git("commit", "-qm", f"v{i + 2}", cwd=origin)
        # Fetch so the ref exists locally; deliberately do NOT merge.
        self.git("fetch", "-q", "origin", cwd=clone)
        return clone

    def test_behind_upstream_is_named_with_distance(self) -> None:
        clone = self.make_clone_behind(3)
        _, out = run(["inventory", str(clone)])
        c = out["checkout"]
        self.assertEqual(c["state"], "stale")
        self.assertEqual(c["behind"], 3)
        self.assertIn("past state", c["detail"])

    def test_strict_fails_on_stale_checkout(self) -> None:
        clone = self.make_clone_behind(1)
        code, _ = run(["inventory", str(clone), "--strict"])
        self.assertEqual(code, 1, "--strict must refuse to bless a stale audit")

    def test_level_with_upstream_is_current(self) -> None:
        clone = self.make_clone_behind(0)
        _, out = run(["inventory", str(clone)])
        self.assertEqual(out["checkout"]["state"], "current")
        self.assertEqual(out["checkout"]["behind"], 0)

    def test_strict_passes_when_current(self) -> None:
        clone = self.make_clone_behind(0)
        code, _ = run(["inventory", str(clone), "--strict"])
        self.assertEqual(code, 0, "a current checkout must not fail --strict")

    def test_no_upstream_is_its_own_state(self) -> None:
        # Legitimate (detached HEAD, local-only branch) but unjudgeable.
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, capture_output=True)
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.write("AGENTS.md", "# local only\n")
        self.git("add", "AGENTS.md")
        self.git("commit", "-qm", "only")
        _, out = run(["inventory", str(self.root)])
        self.assertEqual(out["checkout"]["state"], "no-upstream")
        self.assertTrue(out["checkout"]["detail"])

    def test_outside_git_degrades_explicitly(self) -> None:
        self.write("AGENTS.md", "# no repo\n")
        _, out = run(["inventory", str(self.root)])
        self.assertEqual(out["checkout"]["state"], "unavailable")
        self.assertIn("not a git repository", out["checkout"]["detail"])


class TestClaims(TempTree):
    """Enforcement-shaped assertions must all reach the worklist.

    Both directions: it catches the shapes that actually shipped as defects,
    and it does not drown the list in prose that claims nothing.
    """

    def test_catches_the_real_defects_that_shipped(self) -> None:
        # Verbatim shapes from three separate repos, each a confirmed defect.
        self.write("AGENTS.md", "\n".join([
            "`CLAUDE_CLI_VERSION` is auto-updated by pre-push hook.",
            "CI integration: a GitHub Actions job runs `resend:webhooks:audit` on PRs.",
            "Drift between declared and live state fails the check.",
        ]))
        code, out = run(["claims", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0, "worklist subcommands exit 0 without --strict")
        kinds = {c["kind"] for c in out["candidates"]}
        self.assertIn("git-hook", kinds)
        self.assertIn("ci-job", kinds)
        self.assertIn("blocking-claim", kinds)
        self.assertGreaterEqual(out["candidate_count"], 3)

    def test_strict_exits_nonzero(self) -> None:
        self.write("AGENTS.md", "This is enforced by a pre-commit hook.\n")
        code, _ = run(["claims", str(self.root / "AGENTS.md"), "--strict"])
        self.assertEqual(code, 1)

    def test_quiet_on_prose_that_claims_no_enforcement(self) -> None:
        self.write("AGENTS.md", "\n".join([
            "# Project",
            "Run `pnpm test` before opening a PR.",
            "Prefer TypeScript. Keep functions small.",
            "The database lives at ~/.config/app/app.db",
        ]))
        _, out = run(["claims", str(self.root / "AGENTS.md")])
        self.assertEqual(out["candidate_count"], 0,
                         "a request to run something is not a claim that CI enforces it")

    def test_ignores_fenced_code_blocks(self) -> None:
        # The command itself is not an assertion about the repo.
        self.write("AGENTS.md", "\n".join([
            "```bash",
            "# CI runs this and fails the build",
            "pnpm lint",
            "```",
        ]))
        _, out = run(["claims", str(self.root / "AGENTS.md")])
        self.assertEqual(out["candidate_count"], 0)

    def test_one_candidate_per_kind_per_line(self) -> None:
        self.write("AGENTS.md", "CI runs the linter and CI checks the build.\n")
        _, out = run(["claims", str(self.root / "AGENTS.md")])
        self.assertEqual(out["candidate_count"], 1,
                         "one line should not flood the worklist with duplicates")

    def test_emits_worklist_framing_not_verdicts(self) -> None:
        self.write("AGENTS.md", "Enforced by a pre-push hook.\n")
        _, out = run(["claims", str(self.root / "AGENTS.md")])
        self.assertIn("WORKLIST", out["note"])
        self.assertIn("not defects", out["note"],
                      "a verified-real claim must not read as something to cut")


class TestRefs(TempTree):
    def test_dead_reference_is_flagged(self) -> None:
        self.write("AGENTS.md", "See `docs/nope.md` for details.\n")
        code, out = run(["refs", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 1)
        self.assertEqual(out["dead_count"], 1)
        self.assertEqual(out["dead"][0]["line"], 1)

    def test_live_reference_is_clean(self) -> None:
        self.write("docs/real.md", "x\n")
        self.write("AGENTS.md", "See `docs/real.md` for details.\n")
        code, out = run(["refs", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0)
        self.assertEqual(out["dead_count"], 0)

    def test_globs_are_not_treated_as_literal_paths(self) -> None:
        self.write("AGENTS.md", "Config at `packages/*/AGENTS.md` everywhere.\n")
        code, _ = run(["refs", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0, "a glob is not a dead reference")

    def test_command_lines_are_not_treated_as_paths(self) -> None:
        self.write("AGENTS.md", "Run `pnpm run build` first.\n")
        code, out = run(["refs", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0)
        self.assertEqual(out["refs_checked"], 0)


class TestEmphasis(TempTree):
    def test_counts_density_per_1k_words(self) -> None:
        self.write("AGENTS.md", ("filler " * 990) + ("NEVER " * 10))
        _, out = run(["emphasis", str(self.root / "AGENTS.md")])
        self.assertEqual(out["emphasis_tokens"], 10)
        self.assertAlmostEqual(out["per_1k_words"], 10.0, places=1)

    def test_quiet_file_reports_zero(self) -> None:
        self.write("AGENTS.md", "calm prose with no shouting\n")
        _, out = run(["emphasis", str(self.root / "AGENTS.md")])
        self.assertEqual(out["emphasis_tokens"], 0)


class TestExpiring(TempTree):
    def test_catches_the_claims_that_actually_rotted(self) -> None:
        # Verbatim shapes from the real incident this check exists for.
        self.write("AGENTS.md", "\n".join([
            "- `/pro-gate` (terminal GPT-5.5 Pro gate, ~10-30 min).",
            "- Service account holds `siteFullUser` on two properties.",
            "- Requires Claude Code v2.1.206 or later.",
            "- Budget $3 per run.",
        ]))
        code, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0, "worklists do not fail the build without --strict")
        kinds = {c["kind"] for c in out["candidates"]}
        for expected in ("model-name", "duration-range", "permission-level", "version", "price"):
            self.assertIn(expected, kinds, f"missed the {expected} shape")

    def test_strict_mode_fails_when_candidates_exist(self) -> None:
        self.write("AGENTS.md", "Uses GPT-5.5 Pro.\n")
        code, _ = run(["expiring", str(self.root / "AGENTS.md"), "--strict"])
        self.assertEqual(code, 1)

    def test_ordinary_prose_produces_no_candidates(self) -> None:
        self.write("AGENTS.md", "Prefer server components. Avoid useEffect.\n")
        code, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0)
        self.assertEqual(out["candidate_count"], 0, "false positives make the worklist unusable")


class TestDelta(TempTree):
    def test_growth_is_reported_and_can_fail(self) -> None:
        orig = self.write("orig.md", "short\n")
        draft = self.write("draft.md", "much longer replacement text\n")
        code, out = run(["delta", str(orig), str(draft)])
        self.assertEqual(code, 0)
        self.assertTrue(out["grew"])
        self.assertGreater(out["delta_bytes"], 0)
        code, _ = run(["delta", str(orig), str(draft), "--strict"])
        self.assertEqual(code, 1, "--strict is what makes the byte gate a gate")

    def test_shrinking_correction_passes_strict(self) -> None:
        orig = self.write("orig.md", "a very long original line of prose\n")
        draft = self.write("draft.md", "short\n")
        code, out = run(["delta", str(orig), str(draft), "--strict"])
        self.assertEqual(code, 0)
        self.assertFalse(out["grew"])


class TestMemoryCeiling(TempTree):
    def test_over_bytes_but_under_lines_is_still_truncated(self) -> None:
        # The case that bit for real: few lines, way over 25KB.
        self.write("MEMORY.md", ("x" * 3000 + "\n") * 10)
        code, out = run(["memory", str(self.root / "MEMORY.md")])
        self.assertEqual(code, 1)
        self.assertTrue(out["over_bytes"])
        self.assertFalse(out["over_lines"], "line count alone would have passed this file")

    def test_over_lines_but_small_is_truncated(self) -> None:
        self.write("MEMORY.md", "y\n" * 250)
        code, out = run(["memory", str(self.root / "MEMORY.md")])
        self.assertEqual(code, 1)
        self.assertTrue(out["over_lines"])
        self.assertFalse(out["over_bytes"])

    def test_within_both_limits_is_clean(self) -> None:
        self.write("MEMORY.md", "z\n" * 50)
        code, out = run(["memory", str(self.root / "MEMORY.md")])
        self.assertEqual(code, 0)
        self.assertFalse(out["truncated"])


class TestLedger(TempTree):
    def test_write_then_resolve_detects_a_later_edit(self) -> None:
        self.write("AGENTS.md", "original\n")
        led = self.root / "ledger.jsonl"
        code = rc.main(["ledger-write", str(self.root), "--run", "2026-08-11", "--out", str(led)])
        self.assertEqual(code, 0)
        self.assertTrue(led.is_file())

        self.write("AGENTS.md", "edited after the run\n")
        code, out = run(["ledger-resolve", str(led)])
        self.assertEqual(code, 0)
        entry = out["entries"][0]
        self.assertTrue(entry["changed_since_run"],
                        "an applied verdict must be visible as a fingerprint change")

    def test_unchanged_file_reports_no_change(self) -> None:
        self.write("AGENTS.md", "stable\n")
        led = self.root / "ledger.jsonl"
        rc.main(["ledger-write", str(self.root), "--run", "2026-08-11", "--out", str(led)])
        _, out = run(["ledger-resolve", str(led)])
        self.assertFalse(out["entries"][0]["changed_since_run"])

    def test_legacy_prose_ledger_degrades_explicitly(self) -> None:
        led = self.root / "ledger.md"
        led.write_text("/path/AGENTS.md | 5553B, 148L | 5 verdicts\n", encoding="utf-8")
        code, out = run(["ledger-resolve", str(led)])
        self.assertEqual(code, 0)
        self.assertIn("unparseable", out["entries"][0]["status"],
                      "a legacy ledger must degrade loudly, never silently")

    def test_fingerprint_prefers_git_blob_sha(self) -> None:
        p = self.write("AGENTS.md", "content\n")
        fp = rc.fingerprint(p)
        self.assertIn(fp.kind, ("git-blob", "size-mtime"))
        if fp.kind == "git-blob":
            self.assertEqual(len(fp.value), 40, "a blob SHA is 40 hex chars")

    def test_missing_file_is_reported_not_crashed(self) -> None:
        self.write("AGENTS.md", "temporary\n")
        led = self.root / "ledger.jsonl"
        rc.main(["ledger-write", str(self.root), "--run", "2026-08-11", "--out", str(led)])
        (self.root / "AGENTS.md").unlink()
        code, out = run(["ledger-resolve", str(led)])
        self.assertEqual(code, 0)
        self.assertEqual(out["entries"][0]["status"], "file-gone")


class TestInwardVetRegressions(TempTree):
    """One test per defect the inward vet found. Each failed before its fix."""

    def test_memory_counts_a_file_with_no_trailing_newline(self) -> None:
        # 201 real lines, 200 newline chars. count("\n") reported clean at
        # exactly the ceiling the check exists to enforce.
        self.write("MEMORY.md", "\n".join(f"line {i}" for i in range(1, 202)))
        code, out = run(["memory", str(self.root / "MEMORY.md")])
        self.assertEqual(out["lines"], 201)
        self.assertTrue(out["over_lines"])
        self.assertEqual(code, 1)

    def test_memory_limit_does_not_apply_to_claude_md(self) -> None:
        # Docs: the limit applies to MEMORY.md only; CLAUDE.md loads in full
        # regardless of length. Reporting it truncated invents a defect.
        self.write("CLAUDE.md", ("x" * 3000 + "\n") * 12)
        code, out = run(["memory", str(self.root / "CLAUDE.md")])
        self.assertFalse(out["limit_applies"])
        self.assertFalse(out["truncated"])
        self.assertEqual(code, 0)

    def test_force_applies_limits_to_a_renamed_index(self) -> None:
        self.write("index.md", "y\n" * 250)
        code, out = run(["memory", str(self.root / "index.md"), "--force"])
        self.assertTrue(out["limit_applies"])
        self.assertTrue(out["over_lines"])
        self.assertEqual(code, 1)

    def test_path_with_spaces_is_not_a_blind_spot(self) -> None:
        self.write("AGENTS.md", "See `docs/my notes.md` for details.\n")
        code, out = run(["refs", str(self.root / "AGENTS.md")])
        self.assertEqual(out["refs_checked"], 1, "spaced paths were invisible in both directions")
        self.assertEqual(code, 1)

    def test_url_in_backticks_is_not_a_path(self) -> None:
        self.write("AGENTS.md", "Fetch `https://cdn.example.com/lib/2.3.4/foo.js` at boot.\n")
        code, out = run(["refs", str(self.root / "AGENTS.md")])
        self.assertEqual(out["refs_checked"], 0)
        self.assertEqual(code, 0)

    def test_symlinked_directory_is_traversed_not_skipped(self) -> None:
        self.write("AGENTS.md", "root\n")
        outside = self.root.parent / f"{self.root.name}-target"
        (outside).mkdir(exist_ok=True)
        (outside / "AGENTS.md").write_text("linked\n", encoding="utf-8")
        try:
            (self.root / "linked").symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("symlinks unavailable on this platform")
        try:
            _, out = run(["inventory", str(self.root)])
            self.assertEqual(out["file_count"], 2, "a silently skipped subtree is the forbidden failure")
        finally:
            for p in outside.iterdir():
                p.unlink()
            outside.rmdir()

    def test_symlink_cycle_terminates(self) -> None:
        self.write("AGENTS.md", "root\n")
        try:
            (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        except OSError:
            self.skipTest("symlinks unavailable on this platform")
        code, out = run(["inventory", str(self.root)])
        self.assertEqual(code, 0, "following links must not hang on a cycle")
        self.assertGreaterEqual(out["file_count"], 1)

    def test_two_part_v_prefixed_version_is_caught(self) -> None:
        self.write("AGENTS.md", "Requires v1.2 of the CLI.\n")
        _, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertIn("version", {c["kind"] for c in out["candidates"]})

    def test_bare_two_part_number_stays_quiet(self) -> None:
        self.write("AGENTS.md", "See step 3.2 of the runbook.\n")
        _, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertEqual(out["candidate_count"], 0, "bare 2-part numbers are noise, not versions")

    def test_dates_are_an_expiring_shape(self) -> None:
        self.write("AGENTS.md", "As of 2026-08-11 the feature is in beta.\n")
        _, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertIn("date", {c["kind"] for c in out["candidates"]})

    def test_openai_o_series_is_caught(self) -> None:
        self.write("AGENTS.md", "Model in use: o3.\n")
        _, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertIn("model-name", {c["kind"] for c in out["candidates"]})

    def test_capital_o2_is_not_a_model(self) -> None:
        self.write("AGENTS.md", "Blood O2 saturation and grade O3 steel.\n")
        _, out = run(["expiring", str(self.root / "AGENTS.md")])
        self.assertEqual(out["candidate_count"], 0, "the o-series pattern must stay case-sensitive")

    def test_inventory_names_unscanned_ancestor_files(self) -> None:
        self.write("parentmarker/AGENTS.md", "ancestor\n")
        self.write("parentmarker/child/AGENTS.md", "child\n")
        _, out = run(["inventory", str(self.root / "parentmarker" / "child")])
        self.assertTrue(
            any("parentmarker/AGENTS.md" in p for p in out["ancestor_files_not_scanned"]),
            "ancestor files load at launch too; the gap must be named, not hidden",
        )


class TestProGateRegressions(TempTree):
    """One test per still-live pro-gate finding. Each failed before its fix."""

    def test_own_draft_output_is_not_rediscovered(self) -> None:
        # Phase 5 writes drafts under <root>/.rent-check/<date>/ mirroring
        # audited paths. Without pruning, the next run audits its own drafts.
        self.write("AGENTS.md", "real\n")
        self.write(".rent-check/2026-08-11/AGENTS.md", "a draft, not a context file\n")
        _, out = run(["inventory", str(self.root)])
        self.assertEqual(out["file_count"], 1, "the engine must not audit its own output")

    def test_inventory_accepts_a_single_file(self) -> None:
        # The skill's argument-hint is [context-file-path | repo-root].
        self.write("AGENTS.md", "target\n")
        self.write("SIBLING-CLAUDE.md", "should not appear\n")
        self.write("CLAUDE.md", "sibling that would widen the scope\n")
        code, out = run(["inventory", str(self.root / "AGENTS.md")])
        self.assertEqual(code, 0)
        self.assertEqual(out["file_count"], 1, "a file target must not widen to its siblings")
        self.assertTrue(out["files"][0]["path"].endswith("AGENTS.md"))

    def test_inventory_line_count_handles_missing_trailing_newline(self) -> None:
        self.write("AGENTS.md", "one\ntwo\nthree")  # 3 lines, 2 newlines
        _, out = run(["inventory", str(self.root / "AGENTS.md")])
        self.assertEqual(out["files"][0]["lines"], 3)

    def test_bloated_fix_cannot_hide_behind_a_cut(self) -> None:
        # The exact gaming the aggregate allowed: one FIX grows, an unrelated
        # CUT shrinks more, whole-file delta is negative, --strict passed.
        orig = self.write("orig.md", "x" * 400)
        draft = self.write("draft.md", "x" * 200)
        manifest = self.root / "hunks.json"
        manifest.write_text(json.dumps([
            {"id": "1", "type": "FIX", "original": "short", "replacement": "a much longer replacement"},
            {"id": "2", "type": "CUT", "original": "x" * 300, "replacement": ""},
        ]), encoding="utf-8")
        code, out = run(["delta", str(orig), str(draft), "--hunks", str(manifest), "--strict"])
        self.assertLess(out["delta_bytes"], 0, "file shrank overall")
        self.assertEqual(out["hunks_that_grew"], ["1"])
        self.assertEqual(code, 1, "a growing FIX must fail even when the file shrank")

    def test_all_shrinking_hunks_pass_strict(self) -> None:
        orig = self.write("orig.md", "x" * 400)
        draft = self.write("draft.md", "x" * 200)
        manifest = self.root / "hunks.json"
        manifest.write_text(json.dumps([
            {"id": "1", "type": "FIX", "original": "a long wrong sentence", "replacement": "short"},
        ]), encoding="utf-8")
        code, out = run(["delta", str(orig), str(draft), "--hunks", str(manifest), "--strict"])
        self.assertEqual(out["hunks_that_grew"], [])
        self.assertEqual(code, 0)

    def test_ledger_carries_verdicts_and_resolves_them(self) -> None:
        self.write("AGENTS.md", "keep this line\nand cut THIS PHRASE from here\n")
        manifest = self.root / "verdicts.json"
        manifest.write_text(json.dumps({
            str(self.root / "AGENTS.md"): [
                {"id": "1", "type": "CUT", "quote": "THIS PHRASE"},
                {"id": "2", "type": "KEEP", "quote": "keep this line"},
            ]
        }), encoding="utf-8")
        led = self.root / "ledger.jsonl"
        code, out = run(["ledger-write", str(self.root), "--run", "2026-08-11",
                         "--out", str(led), "--verdicts", str(manifest)])
        self.assertEqual(code, 0)
        self.assertEqual(out["verdicts_attached"], 2, "an empty verdicts list defeats the whole loop")

        # Operator applies the CUT.
        self.write("AGENTS.md", "keep this line\nand cut  from here\n")
        _, res = run(["ledger-resolve", str(led)])
        verdicts = {v["id"]: v for v in res["entries"][0]["verdicts"]}
        self.assertFalse(verdicts["1"]["quote_present_now"], "the CUT landed")
        self.assertTrue(verdicts["2"]["quote_present_now"], "the KEEP was left alone")

    def test_ledger_write_honours_json_flag(self) -> None:
        self.write("AGENTS.md", "x\n")
        led = self.root / "ledger.jsonl"
        r = subprocess.run(
            ["python3", str(HERE / "rent-check.py"), "ledger-write", str(self.root),
             "--run", "2026-08-11", "--out", str(led), "--json"],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(r.returncode, 0)
        parsed = json.loads(r.stdout)  # raises if it printed plain text
        self.assertEqual(parsed["entries_written"], 1)


class TestCli(unittest.TestCase):
    def test_runs_as_a_subprocess(self) -> None:
        """The agent shells out to this; importability is not enough."""
        r = subprocess.run(
            ["python3", str(HERE / "rent-check.py"), "--help"],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(r.returncode, 0)
        self.assertIn("inventory", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
