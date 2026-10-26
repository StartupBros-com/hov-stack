"""Tests for papercut-vendor.py, the transform that builds the packaged copy.

Both traps pinned below shipped in a first draft of that script and were caught
by running it, not by reading it. They are the reason the vendor verifies its
own output rather than trusting its rules.
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
from unittest.mock import patch
import posixpath
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"
_spec = importlib.util.spec_from_file_location(
    "papercut_vendor", SCRIPTS / "papercut-vendor.py")
VENDOR = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(VENDOR)

# A relative require -- './x' or '../x' -- is the only form the vendored tree
# has to resolve entirely on its own after flattening; a bare `require('fs')`
# or `require('./lib/hook-flags')` package-relative-to-node_modules form is
# out of scope here.
REQUIRE_RE = re.compile(r"require\((['\"])(\.\.?/[^'\"]+)\1\)")

# Mirrors ~/SITES/papercut/scripts/check_no_private_refs.py's DOCTRINE_RE.
# Duplicated rather than imported: that file lives in the skeleton repo, not
# this one, and a vendor run only reaches it against a real skeleton checkout
# that this test suite cannot assume exists. KTD2 and AE5 shipped in
# papercut-log.js's shape-rewrite comment (added by #1266, unrelated to this
# file's own DOCTRINE additions) with nothing here to catch it before a real
# vendor run hit that downstream gate.
DOCTRINE_CODE_RE = re.compile(r"\b(?:R1?[0-9]|KTD[0-9]+|AE[0-9]+)\b")


class TestVendorRules(unittest.TestCase):
    def test_no_replacement_contains_its_own_pattern(self):
        """runner-guard -> a-runner-guard left the pattern intact.

        The guard re-detected it and the vendor failed, which is the correct
        outcome but a rule that cannot clean should never have been written.
        """
        for old, new in VENDOR.LITERALS:
            self.assertNotIn(old, new,
                             f"rule {old!r} -> {new!r} re-introduces its own pattern")

    def test_every_literal_anchor_still_matches_a_vendored_source(self):
        """A LITERALS `old` no source contains is a silent no-op.

        substitute() never raises, so editing a private passage without
        moving its anchor ships the private text unchanged, and the
        private-reference guard only notices when that text carries a
        path. Runs in the harness python suite; retires with the vendor.
        """
        sources = {rel: (REPO_ROOT / rel).read_text(encoding="utf-8")
                   for rel in VENDOR.VENDORED}
        for old, _new in VENDOR.LITERALS:
            self.assertTrue(any(old in text for text in sources.values()),
                            f"no vendored source contains anchor {old[:60]!r}")

    def test_every_config_default_anchor_still_matches_a_vendored_source(self):
        """Same silent no-op as above, for the line-anchored config overrides."""
        sources = {rel: (REPO_ROOT / rel).read_text(encoding="utf-8")
                   for rel in VENDOR.VENDORED}
        for old, _new in VENDOR.CONFIG_DEFAULTS:
            pattern = re.compile(r"(?m)^" + re.escape(old))
            self.assertTrue(any(pattern.search(text) for text in sources.values()),
                            f"no vendored source contains config anchor {old[:60]!r}")

    def test_doctrine_replacements_do_not_reintroduce_a_code(self):
        for code, name in VENDOR.DOCTRINE.items():
            self.assertNotIn(code, name, f"doctrine {code} -> {name!r} keeps the code")


class TestPrivateTokens(unittest.TestCase):
    def test_planted_list_precedes_fixed_table_and_preserves_boundaries(self):
        # The variable carries the list itself, as it does for the scan.
        names = "# private fixture\n\nacme-secret\nacme-team/app.v2\ndispatcher-helper\n"
        with patch.dict(os.environ, {"HOV_STACK_PRIVATE_TOKENS": names}):
            self.assertEqual(
                VENDOR.transform(
                    "acme-secret acme-team/app.v2 acme-team/appXv2 my_acme-secret_id dispatcher-helper"
                ),
                "example-project example-project acme-team/appXv2 my_acme-secret_id example-project",
            )

    def test_a_path_in_the_variable_is_not_read_as_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "names"
            source.write_text("acme-secret\n")
            with patch.dict(os.environ, {"HOV_STACK_PRIVATE_TOKENS": str(source)}):
                self.assertEqual(VENDOR.private_tokens(), [str(source)])
                self.assertEqual(VENDOR.transform("acme-secret"), "acme-secret")

    def test_names_match_in_any_case_and_the_longest_name_wins(self):
        # "acme" first would leave "example-project-Secret" behind.
        with patch.dict(os.environ, {"HOV_STACK_PRIVATE_TOKENS": "acme\nacme-secret\nACME\n"}):
            self.assertEqual(VENDOR.private_tokens(), ["acme-secret", "ACME", "acme"])
            self.assertEqual(
                VENDOR.transform("ACME-Secret acme Acme acme-team/APP.v2"),
                "example-project example-project example-project example-project-team/APP.v2",
            )
        with patch.dict(os.environ, {"HOV_STACK_PRIVATE_TOKENS": "acme-team/app.v2\n"}):
            self.assertEqual(VENDOR.transform("ACME-TEAM/APP.V2"), "example-project")

    def test_overlay_list_and_missing_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(
                os.environ, {"HOV_STACK_PRIVATE_TOKENS": "", "HOV_STACK_OVERLAY": tmp}
            ):
                self.assertEqual(VENDOR.transform("acme-secret"), "acme-secret")
                (Path(tmp) / "private-tokens").write_text("acme-secret\n")
                self.assertEqual(VENDOR.transform("acme-secret"), "example-project")

    def test_overlay_resolution_matches_setup(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            xdg = Path(tmp) / "xdg"
            for root in (home / ".config", xdg):
                overlay = root / "hov-stack"
                overlay.mkdir(parents=True)
                (overlay / "private-tokens").write_text("acme-secret\n")
            for configured_xdg in (str(xdg), "relative"):
                with (
                    self.subTest(xdg=configured_xdg),
                    patch.dict(
                        os.environ,
                        {
                            "HOME": str(home),
                            "XDG_CONFIG_HOME": configured_xdg,
                            "HOV_STACK_OVERLAY": "",
                            "HOV_STACK_PRIVATE_TOKENS": "",
                        },
                    ),
                ):
                    self.assertEqual(VENDOR.transform("acme-secret"), "example-project")
            # A relative overlay is ignored even where it resolves to a list: run from
            # a directory holding relative/private-tokens, or ignoring it proves nothing.
            cwd = Path(tmp) / "cwd"
            (cwd / "relative").mkdir(parents=True)
            (cwd / "relative" / "private-tokens").write_text("acme-secret\n")
            before = os.getcwd()
            os.chdir(cwd)
            try:
                with patch.dict(
                    os.environ,
                    {
                        "HOME": str(home),
                        "XDG_CONFIG_HOME": str(xdg),
                        "HOV_STACK_OVERLAY": "relative",
                        "HOV_STACK_PRIVATE_TOKENS": "",
                    },
                ):
                    self.assertEqual(VENDOR.transform("acme-secret"), "acme-secret")
            finally:
                os.chdir(before)

    def test_a_missing_list_is_named_on_the_write_path_only(self):
        # harness-weekly reads any stderr from --verify-delivered as a warning,
        # so the verify paths stay silent about it.
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOV_STACK_PRIVATE_TOKENS": "", "HOV_STACK_OVERLAY": str(Path(tmp) / "none")}
            with patch.dict(os.environ, env), patch.object(VENDOR, "SKELETON", Path(tmp)):
                for argv, named in ((["vendor", "--check"], True),
                                    (["vendor", "--verify-fresh"], False)):
                    err, out = io.StringIO(), io.StringIO()
                    with (self.subTest(argv=argv), patch.object(sys, "argv", argv),
                          contextlib.redirect_stderr(err), contextlib.redirect_stdout(out)):
                        VENDOR.main()
                        self.assertEqual("private-token list missing" in err.getvalue(), named,
                                         err.getvalue())


class TestSubstitutionSafety(unittest.TestCase):
    def test_a_bare_word_never_fires_inside_an_identifier(self):
        """The trap that produced invalid Python.

        `dispatcher` -> `an autonomous queue` rewrote
        test_no_dispatcher_configured_says_nothing into
        `def test_no_an autonomous queue_configured...`, a file that still
        passed the private-reference guard and no longer parsed.
        """
        src = "    def test_no_dispatcher_configured(self):\n"
        self.assertEqual(VENDOR.substitute(src, "dispatcher", "a queue"), src)

    def test_a_standalone_word_is_still_replaced(self):
        """Planted negative: word boundaries must not make the rule inert."""
        self.assertEqual(
            VENDOR.substitute("the dispatcher tags it", "dispatcher", "a queue"),
            "the a queue tags it")

    def test_placeholder_home_paths_pass_through_unchanged(self):
        """The tree spells homes as $HOME/ or the /home/user placeholder.

        No table row touches either form, in the path or the slug encoding:
        a rule that did would rewrite a test's input and leave its expected
        value alone -- output that is clean, valid, and wrong.
        """
        line = 'assert slug("/home/user/x") == "-home-user-x"\n'
        self.assertEqual(VENDOR.transform(line), line)

    def test_a_path_rule_applies_without_word_boundaries(self):
        """A leading \\b cannot match before "/", so paths stay plain."""
        self.assertEqual(
            VENDOR.substitute("/home/someone/x", "/home/someone", "/home/user"),
            "/home/user/x")


class TestTransformMeaning(unittest.TestCase):
    def test_a_doctrine_code_is_named_not_deleted(self):
        out = VENDOR.transform("fails closed per KTD6.\n")
        self.assertNotIn("KTD6", out)
        self.assertIn("open-work cap", out,
                      "a code must become the invariant it names, not vanish")

    def test_another_plans_code_is_not_named_by_this_plans_meaning(self):
        """DOCTRINE is keyed by bare code, and codes repeat across plans.

        papercut-log.js cites the shape-rewrite plan's KTD2/KTD6/KTD7; that
        plan's KTD6 is the receipt-in-the-script rule, not papercut's
        open-work cap, so the bare-code rule would ship a wrong meaning.
        """
        out = VENDOR.transform(
            "// shape-rewrite (KTD2/KTD6/KTD7): the PreToolUse hook writes the rewritten\n")
        self.assertNotIn("KTD", out)
        self.assertNotIn("open-work cap", out)
        self.assertIn("receipt", out)

    def test_evidence_survives_and_only_the_address_goes(self):
        """The rule the whole transform exists to honour.

        A comment asserting something with no visible grounds is worse than
        either the private citation or silence, so the measurement stays and
        only the unresolvable reference is translated.
        """
        out = VENDOR.transform(
            "# Measured 2026-08-29: 4,899 of 4,917 records were synthesized,\n"
            "# fixed by PR #530.\n")
        self.assertIn("4,899 of 4,917", out)
        self.assertIn("2026-08-29", out)
        self.assertNotIn("#530", out)

    def test_packaged_config_defaults_are_neutral(self):
        """Stage 1's payoff: the packaged copy differs by defaults, not by fork.

        The label is blank in both copies since 2026-10-18; the override now
        swaps the private comment above it, which names the retired dispatcher
        and a pull request the plugin's reader cannot open.
        """
        private = next(old for old, _new in VENDOR.CONFIG_DEFAULTS
                       if old.endswith('DISPATCH_READY_LABEL = ""'))
        self.assertIn("dotfiles#1873", private)
        out = VENDOR.transform(private + "\n")
        self.assertIn('DISPATCH_READY_LABEL = ""', out)
        self.assertIn("Empty means no", out)
        self.assertNotIn("dotfiles#1873", out)
        self.assertNotIn("Blank since", out)

        # Same constant, not at offset 0. The two cases are separate because an
        # anchor spelled as a literal "\n" prefix passes the one above only when
        # something precedes it, and silently stops neutralizing a file that
        # opens with the constant.
        out = VENDOR.transform("import os\n" + private + "\n")
        self.assertIn('DISPATCH_READY_LABEL = ""', out)
        self.assertNotIn("dotfiles#1873", out)

    def test_a_config_default_is_rewritten_only_as_a_definition(self):
        """A CONFIG_DEFAULT names a module-level constant, not any occurrence.

        Unanchored, the rewrite also fired inside a test's
        `PC.DISPATCH_READY_LABEL = "loop-ok"`, splicing the replacement's
        comment block into the middle of an expression and emitting a file that
        would not parse. The address still gets translated; the DEFINITION
        rewrite must not.
        """
        out = VENDOR.transform('        PC.DISPATCH_READY_LABEL = "loop-ok"\n')
        self.assertEqual(out.count("\n"), 1, f"replacement spliced extra lines: {out!r}")
        self.assertIn("PC.DISPATCH_READY_LABEL = ", out)
        self.assertNotIn("Empty means no", out)
        self.assertNotIn("loop-ok", out)


class TestVendoredRequiresResolve(unittest.TestCase):
    """hook-output.js shipped in hooks/lib/ with three callers vendored
    (papercut-log.js, structured-output-unwrap.js, read-ceiling-chunk.js) but
    was itself absent from VENDORED. The package flattens every hooks/*.js
    source into a single hooks/ directory, so nothing in `node --check` or
    py_compile ever notices: each file still parses on its own: the missing
    file only breaks a real `require()` at runtime. This walks every relative
    require() in a vendored .js source and resolves it, against REPO_ROOT (this
    checkout, not VENDOR.SOURCE, which PAPERCUT_VENDOR_SOURCE can point at
    another checkout), through the same VENDORED keys the
    vendor itself reads from, so a caller of an unvendored module is caught
    here instead of shipping a package that MODULE_NOT_FOUNDs the first time
    that path runs.
    """

    def test_every_relative_require_in_a_vendored_js_source_is_itself_vendored(self):
        js_sources = {src for src in VENDOR.VENDORED if src.endswith(".js")}
        missing = []
        for src_rel in sorted(js_sources):
            text = (REPO_ROOT / src_rel).read_text(encoding="utf-8")
            src_dir = posixpath.dirname(src_rel)
            for _, rel_import in REQUIRE_RE.findall(text):
                resolved = posixpath.normpath(posixpath.join(src_dir, rel_import))
                if not resolved.endswith(".js"):
                    resolved += ".js"
                if resolved not in js_sources:
                    missing.append(
                        f"{src_rel}: require({rel_import!r}) resolves to {resolved}, "
                        "which is not a key in VENDORED"
                    )
        self.assertEqual(
            missing,
            [],
            "a vendored .js file requires a source that itself is not vendored -- the "
            "packaged copy would MODULE_NOT_FOUND at runtime:\n" + "\n".join(missing),
        )


class TestDoctrineCodesResolve(unittest.TestCase):
    """DOCTRINE only translates a code it has an entry for; anything else
    ships as a literal citation and fails the skeleton's own
    check_no_private_refs.py the first time a real vendor run reaches that
    gate -- which is exactly what happened to KTD2 and AE5 in
    papercut-log.js's shape-rewrite signature comment (added by #1266, long
    before this file's own DOCTRINE additions, so not caused by them) with no
    test catching it beforehand. This resolves every doctrine-shaped code in
    a vendored source against VENDOR.DOCTRINE the same way
    TestVendoredRequiresResolve resolves require() targets. It resolves the
    text DOCTRINE actually receives (after the EXACT overrides): a code an
    EXACT rule names first, such as another plan's KTD6, never reaches the
    bare-code map and must not be forced into it.
    """

    def test_every_doctrine_code_in_a_vendored_source_has_a_doctrine_entry(self):
        sources = {src for src in VENDOR.VENDORED
                   if src.endswith((".js", ".py", ".md"))}
        missing = []
        for src_rel in sorted(sources):
            text = VENDOR.apply_overrides(
                (REPO_ROOT / src_rel).read_text(encoding="utf-8"))
            for code in sorted(set(DOCTRINE_CODE_RE.findall(text))):
                if code not in VENDOR.DOCTRINE:
                    missing.append(f"{src_rel}: cites {code}, which is not a key in DOCTRINE")
        self.assertEqual(
            missing,
            [],
            "a vendored source cites a doctrine code with no DOCTRINE entry -- it ships "
            "as a literal and fails check_no_private_refs.py the first time a real "
            "vendor run reaches that gate:\n" + "\n".join(missing),
        )


if __name__ == "__main__":
    unittest.main()
