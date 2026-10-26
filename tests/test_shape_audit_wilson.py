#!/usr/bin/env python3
"""Pin the shared shape-audit Wilson interval to the pre-collapse contract.

Goldens are repr() of robust_cost.wilson before the five copies were deleted.
repr, not ==, because a boundary clamp is int 0 / int 100, and 0 == 0.0.
"""

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHAPE_AUDIT = ROOT / "scripts" / "shape-audit"
WILSON_PY = SHAPE_AUDIT / "wilson.py"
SCRIPTS = (
    "check_step",
    "model_confound",
    "robust_cost",
    "shape_audit",
    "validate_eval",
)

# Captured 2026-10-07 from the inlined function, before extract.
GOLDENS = {
    (0, 0): "(0.0, 0.0, 0.0)",
    (0, 10): "(0.0, 0, 27.75401687666166)",
    (10, 10): "(100.0, 72.24598312333835, 100)",
    (1, 2): "(50.0, 9.452865480086615, 90.54713451991339)",
    (3, 16855): "(0.017798872738059923, 0.006053293846884189, 0.05232319626735949)",
    (16, 2622): "(0.6102212051868803, 0.37596319036759823, 0.9889934772394653)",
    (1, 2, 2.576): "(50.0, 6.170635002311381, 93.82936499768861)",
}


def load_wilson():
    import importlib.util

    spec = importlib.util.spec_from_file_location("shape_audit_wilson_under_test", WILSON_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.wilson


class WilsonContract(unittest.TestCase):
    def test_repr_goldens(self):
        wilson = load_wilson()
        for args, expected in GOLDENS.items():
            self.assertEqual(repr(wilson(*args)), expected, args)

    def test_scripts_bind_the_shared_function(self):
        probe = (
            "import {name}\n"
            "import wilson\n"
            "assert {name}.wilson is wilson.wilson, {name}.wilson\n"
            "assert repr({name}.wilson(0, 10)) == '(0.0, 0, 27.75401687666166)'\n"
            "assert repr({name}.wilson(10, 10)) == '(100.0, 72.24598312333835, 100)'\n"
        )
        for name in SCRIPTS:
            proc = subprocess.run(
                [sys.executable, "-c", probe.format(name=name)],
                cwd=SHAPE_AUDIT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                proc.returncode,
                0,
                f"{name}: stdout={proc.stdout!r} stderr={proc.stderr!r}",
            )


if __name__ == "__main__":
    unittest.main()
