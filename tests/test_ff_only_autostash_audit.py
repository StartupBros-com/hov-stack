#!/usr/bin/env python3
"""Contract for ff-only-autostash-audit.py (dotfiles#481).

Planted negatives: every finding case names a command shape that
stashes-and-pops under git/config.shared (measured 2026-09-03, git 2.43.0): a
bare pull or merge --ff-only, the config spelling `pull.ff=only`, and the
subtle one -- `-c merge.autostash=false` on a *pull*, which the issue itself
suggested and which does nothing on git 2.36+ under pull.rebase=true. The
inward vet's two evasions are pinned too: a --no-autostash in a trailing
comment, or on a guarded sibling command chained on the same line, must not
vouch for a bare command. Controls: the shapes the repo's fixed sites use
stay clean. The last test scans the live repo and pins zero findings, so a
new unguarded call site fails at PR time rather than on the next Monday
doctor run.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
AUDITOR = REPO / "scripts" / "ff-only-autostash-audit.py"

_spec = importlib.util.spec_from_file_location("ff_only_autostash_audit", AUDITOR)
FF = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(FF)


def finding(command: str) -> str | None:
    return FF.judge(command)[1]


class JudgeTests(unittest.TestCase):
    # -- controls: the shapes the fixed sites use --------------------------------
    def test_merge_with_config_off_is_clean(self):
        self.assertIsNone(finding(
            'git -C "$repo" -c merge.autostash=false merge --ff-only "origin/$default" --quiet'
        ))

    def test_merge_with_no_autostash_is_clean(self):
        self.assertIsNone(finding(
            '"$GIT_BIN" -C "$target" merge --ff-only --no-autostash "$upstream"'
        ))

    def test_pull_with_no_autostash_is_clean(self):
        self.assertIsNone(finding(
            'run_with_timeout 300 git -C "$repo_dir" pull --no-autostash --ff-only origin "$b"'
        ))

    def test_pull_with_both_config_keys_off_is_clean(self):
        self.assertIsNone(finding(
            "git -c merge.autostash=false -c rebase.autostash=false pull --ff-only"
        ))

    def test_config_key_case_is_insensitive(self):
        self.assertIsNone(finding("git -c merge.autoStash=false merge --ff-only origin/main"))

    def test_no_autostash_is_not_mistaken_for_autostash_on(self):
        self.assertIsNone(finding("git merge --ff-only --no-autostash origin/main"))

    # -- planted negatives ---------------------------------------------------------
    def test_bare_pull_is_flagged(self):
        self.assertIn("add --no-autostash", finding('git -C "$d" pull --ff-only'))

    def test_bare_merge_is_flagged(self):
        self.assertIn("-c merge.autostash=false", finding("git merge --ff-only origin/main"))

    def test_pull_with_only_merge_key_is_flagged_with_the_pull_rebase_reason(self):
        """The issue's own suggested fix: a no-op for pull under pull.rebase=true."""
        why = finding("git -c merge.autostash=false pull --ff-only origin main")
        self.assertIsNotNone(why)
        self.assertIn("pull.rebase=true", why)
        self.assertIn("--no-autostash", why)

    def test_pull_with_only_rebase_key_is_flagged(self):
        why = finding("git -c rebase.autostash=false pull --ff-only")
        self.assertIsNotNone(why)
        self.assertIn("pull.rebase unset", why)

    def test_explicit_autostash_on_is_flagged(self):
        self.assertIn("opts INTO autostash", finding("git merge --ff-only --autostash origin/main"))

    def test_unknown_verb_is_flagged_and_names_the_variable_case(self):
        why = finding('git "${args[@]}" --ff-only')
        self.assertIn("without pull or merge in the same command", why)
        self.assertIn("flag held in a variable", why)

    def test_merge_base_is_not_the_merge_verb(self):
        # Contrived on one line, but the verb regex must not read "merge-base" as
        # "merge" and then let a merge.autostash key vouch for it.
        self.assertEqual(FF.judge("git merge-base --ff-only x")[0], "unknown")

    def test_verb_is_found_after_a_config_key_that_names_it(self):
        self.assertEqual(FF.judge("git -c merge.autostash=false pull --ff-only")[0], "pull")


class CommandSplitTests(unittest.TestCase):
    def test_operators_split_and_trailing_comment_is_dropped(self):
        self.assertEqual(
            [s.strip() for s in FF.commands("a; b && c || d | e & f # g; h")],
            ["a", "b", "c", "d", "e", "f"],
        )

    def test_quoted_operators_and_hash_are_kept(self):
        self.assertEqual(
            FF.commands('echo "a; b # c" \'d && e\' x#y'),
            ['echo "a; b # c" \'d && e\' x#y'],
        )

    def test_escaped_operator_is_kept(self):
        self.assertEqual(FF.commands("a \\; b"), ["a \\; b"])

    def test_leading_hash_is_a_comment(self):
        self.assertEqual(FF.commands("# git pull --ff-only"), [])


class TextTests(unittest.TestCase):
    def test_comment_lines_are_skipped(self):
        self.assertEqual(FF.audit_text("# git pull --ff-only would not have helped\n"), (0, []))

    def test_trailing_comment_cannot_vouch_for_a_bare_pull(self):
        """Inward-vet evasion: --no-autostash in the comment, not the command."""
        text = "git pull --ff-only origin main  # deliberately not --no-autostash here\n"
        sites, findings = FF.audit_text(text)
        self.assertEqual(sites, 1)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("add --no-autostash", findings[0][1])

    def test_chained_commands_are_judged_separately(self):
        """Inward-vet evasion: a guarded sibling on the same line must not vouch."""
        text = (
            'git -C "$a" merge --ff-only --no-autostash origin/main; '
            'git -C "$b" pull --ff-only origin main\n'
        )
        sites, findings = FF.audit_text(text)
        self.assertEqual(sites, 2)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("pull --ff-only leaves autostash", findings[0][1])

    def test_and_or_chain_isolates_the_bare_merge(self):
        text = "git fetch origin && git merge --ff-only origin/main || echo failed\n"
        sites, findings = FF.audit_text(text)
        self.assertEqual((sites, len(findings)), (1, 1))

    def test_hash_inside_quotes_does_not_strip_the_guard(self):
        text = 'git merge "#" --ff-only --no-autostash origin/main\n'
        self.assertEqual(FF.audit_text(text), (1, []))

    def test_config_spelling_of_ff_only_is_a_site(self):
        sites, findings = FF.audit_text("git -c pull.ff=only pull origin main\n")
        self.assertEqual(sites, 1)
        self.assertIn("add --no-autostash", findings[0][1])

    def test_variable_held_flag_is_reported_at_the_assignment(self):
        sites, findings = FF.audit_text("opts=--ff-only\ngit pull $opts origin main\n")
        self.assertEqual(sites, 1)
        self.assertEqual(findings[0][0], 1)
        self.assertIn("flag held in a variable", findings[0][1])

    def test_continuation_lines_are_joined(self):
        text = 'git -C "$d" \\\n  pull --ff-only \\\n  --no-autostash origin main\n'
        self.assertEqual(FF.audit_text(text), (1, []))

    def test_finding_reports_the_first_physical_line(self):
        text = 'echo start\ngit -C "$d" \\\n  pull --ff-only origin main\n'
        sites, findings = FF.audit_text(text)
        self.assertEqual(sites, 1)
        self.assertEqual(findings[0][0], 2)

    def test_lines_without_a_site_are_not_counted(self):
        self.assertEqual(FF.audit_text("git pull --rebase\ngit merge origin/main\n")[0], 0)

    def test_shell_detection_by_shebang_and_suffix(self):
        root = Path(tempfile.mkdtemp(prefix="ff-only-audit-shebang."))
        self.addCleanup(lambda: shutil.rmtree(root, ignore_errors=True))
        cases = {
            "a.sh": ("echo\n", True),
            "bin/tool": ("#!/usr/bin/env bash\n", True),
            "bin/posix": ("#!/bin/sh -e\n", True),
            "bin/py": ("#!/usr/bin/env python3\n", False),
            "bin/fish": ("#!/usr/bin/fish\n", False),
            "notes.md": ("# git pull --ff-only\n", False),
        }
        for rel, (body, expected) in cases.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
            self.assertEqual(FF.is_shell_source(path), expected, rel)

    def test_test_paths_are_exempt(self):
        self.assertTrue(FF.is_test_path("tests/x.test.sh"))
        self.assertTrue(FF.is_test_path("tests/helper.sh"))
        self.assertTrue(FF.is_test_path("tools/y.test.sh"))
        self.assertFalse(FF.is_test_path("scripts/update-mcp-servers.sh"))
        self.assertFalse(FF.is_test_path("harnesses/pi/agent/bin/pi-local"))


class CorpusTests(unittest.TestCase):
    def _repo(self, files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp(prefix="ff-only-audit."))
        self.addCleanup(lambda: shutil.rmtree(root, ignore_errors=True))
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for rel, body in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        return root

    def test_untracked_and_non_shell_and_test_files_are_ignored(self):
        root = self._repo({
            "bin/updater": "#!/usr/bin/env bash\ngit pull --ff-only\n",
            "tests/x.test.sh": "git pull --ff-only\n",
            "tools/y.test.sh": "git pull --ff-only\n",
            "notes.md": "run git pull --ff-only\n",
            "plain.txt": "git pull --ff-only\n",
        })
        (root / "untracked.sh").write_text("git pull --ff-only\n", encoding="utf-8")
        code, lines = FF.run(root, 1)
        self.assertEqual(code, 1, lines)
        warns = [line for line in lines if line.startswith("WARN ")]
        self.assertEqual(len(warns), 1, lines)
        self.assertTrue(warns[0].startswith("WARN bin/updater:2: "), warns[0])
        self.assertIn("1 finding(s) across 1 --ff-only call site(s) in 1 shell file(s)", lines[-1])

    def test_clean_corpus_exits_zero(self):
        root = self._repo({"a.sh": "git merge --ff-only --no-autostash origin/main\n"})
        code, lines = FF.run(root, 1)
        self.assertEqual(code, 0, lines)
        self.assertIn("0 finding(s) across 1 --ff-only call site(s)", lines[-1])

    def test_empty_corpus_refuses_to_report_clean(self):
        root = self._repo({"a.sh": "echo nothing to see\n"})
        code, lines = FF.run(root, 1)
        self.assertEqual(code, 2, lines)
        self.assertIn("refusing to report clean", lines[-1])

    def test_floor_zero_allows_an_empty_corpus(self):
        root = self._repo({"a.sh": "echo nothing\n"})
        self.assertEqual(FF.run(root, 0)[0], 0)

    def test_non_checkout_exits_two(self):
        root = Path(tempfile.mkdtemp(prefix="ff-only-audit-nogit."))
        self.addCleanup(lambda: shutil.rmtree(root, ignore_errors=True))
        code, lines = FF.run(root, 1)
        self.assertEqual(code, 2, lines)
        self.assertIn("not a git checkout", lines[-1])

    def test_cli_exit_status_and_warn_lines(self):
        root = self._repo({"up.sh": "git pull --ff-only\n"})
        proc = subprocess.run(
            [sys.executable, str(AUDITOR), "--root", str(root)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("WARN up.sh:1: pull --ff-only leaves autostash", proc.stdout)

    def test_crash_exits_two_with_a_warn_line_not_one(self):
        """Python's unhandled-exception exit is 1, which reads as 'findings'."""
        out = io.StringIO()
        with mock.patch.object(FF, "run", side_effect=RuntimeError("boom")):
            with contextlib.redirect_stdout(out):
                code = FF.main(["--root", "/nonexistent"])
        self.assertEqual(code, 2)
        self.assertIn("WARN ff-only-autostash-audit: crashed", out.getvalue())
        self.assertIn("refusing to report clean", out.getvalue())


class LiveRepoTest(unittest.TestCase):
    def test_this_repo_has_no_unguarded_ff_only_site(self):
        """The standing sweep from #481: fails the PR that adds one back."""
        code, lines = FF.run(REPO, 1)
        self.assertEqual(code, 0, "\n".join(lines))


if __name__ == "__main__":
    unittest.main()
