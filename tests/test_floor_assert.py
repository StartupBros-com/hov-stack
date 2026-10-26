#!/usr/bin/env python3
"""Unit contract for the import-only Python floor helper."""

import importlib
import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "scripts" / "lib"
sys.path.insert(0, str(LIB))


class FloorAssertTests(unittest.TestCase):
    def test_import_has_no_cli_side_effects(self):
        sys.modules.pop("floor_assert", None)
        stdout = io.StringIO()
        stderr = io.StringIO()

        with redirect_stdout(stdout), redirect_stderr(stderr):
            module = importlib.import_module("floor_assert")

        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")
        self.assertFalse(hasattr(module, "main"))

    def test_above_floor_and_boundary_pass(self):
        from floor_assert import require_floor

        self.assertTrue(require_floor(5, 3, "unit corpus"))
        self.assertTrue(require_floor(3, 3, "unit corpus"))

    def test_below_floor_raises_typed_exception_with_shell_semantics(self):
        from floor_assert import FloorNotMet, require_floor

        with self.assertRaises(FloorNotMet) as raised:
            require_floor(0, 1, "unit corpus")

        self.assertEqual(
            str(raised.exception),
            "WARN unit corpus: examined 0 item(s), expected at least 1 — "
            "refusing to report clean",
        )


if __name__ == "__main__":
    unittest.main()
