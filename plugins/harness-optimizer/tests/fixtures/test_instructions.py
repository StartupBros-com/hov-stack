"""Structural baseline identity alarm, NOT a behavioral or semantic oracle.

Changed wording needs the opt-in held-out model consumer in run_behavioral.py.
This check neither accepts equivalent rewrites nor claims they behave worse.
"""
from pathlib import Path
import unittest

BASELINE = ('Check the literal project argument before executing a command.\n'
            'Retain literal spaces and shell-like text as data.\n')


class InstructionStructureTests(unittest.TestCase):
    def test_instruction_baseline_identity(self):
        self.assertEqual(Path(__file__).with_name('instructions.md').read_text(), BASELINE,
                         'wording changed; instruction behavior requires held-out model evaluation')


if __name__ == '__main__':
    unittest.main()
