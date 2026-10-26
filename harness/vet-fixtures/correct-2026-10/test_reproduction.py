"""Offline synthetic checks of reproduction tools, not evidence of model behavior.

Run: python3 -I test_reproduction.py
FIXTURE_SOURCE may name an earlier copy of the tooling for red/green checks.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(os.environ.get('FIXTURE_SOURCE', Path(__file__).resolve().parent))
ARMS = [f'a{a}-{trial}' for a in range(1, 4) for trial in range(1, 4)]


class ReproductionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='correct-repro-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'key').mkdir()
        (self.root / 'tools').mkdir()
        self.words = self.root / 'tools/scan-words.txt'
        self.words.write_text('highest level\nrule table\n')
        self.mapping = self.root / 'key/mapping.tsv'
        self.mapping.write_text(''.join(f'r{i:02d}\t{arm}\n' for i, arm in enumerate(ARMS, 1)))
        for i, arm in enumerate(ARMS, 1):
            directory = self.root / 'arms' / arm
            (directory / 'repo').mkdir(parents=True)
            (directory / 'repo/app.txt').write_text('fixture\n')
            (directory / 'report.md').write_text('ordinary report\n')
            (directory / 'prompt.txt').write_text('maintain this service\n')
            data = dict(duration_ms=i * 1000, duration_api_ms=i * 900,
                        num_turns=i, total_cost_usd=i / 100)
            (directory / 'result.json').write_text(json.dumps(data))
        # Original recorded-run scripts hard-code their root. Only relocate that
        # literal, exactly as the README instructs; exercise the rest unmodified.
        script = (SOURCE / 'relabel.sh').read_text()
        self.assertEqual(script.count('R=/tmp/hv-correct-2026-10-07\n'), 1)
        self.relabel = self.root / 'relabel.sh'
        self.relabel.write_text(script.replace('R=/tmp/hv-correct-2026-10-07\n',
                                               f'R={self.root}\n'))

    def run_relabel(self, env=None):
        return subprocess.run(['bash', str(self.relabel)], text=True,
                              capture_output=True, env=env)

    def run_timing(self):
        return subprocess.run(['python3', '-I', str(SOURCE / 'gen-timing.py'),
                               '--root', str(self.root)], text=True, capture_output=True)

    def test_relabel_zero_hits(self):
        result = self.run_relabel()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.count('scan_words=0 skill_terms=0'), 9)

    def test_relabel_reports_hits_without_failing(self):
        (self.root / 'arms/a2-1/report.md').write_text('highest level\nrule table\n')
        result = self.run_relabel()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.count('scan_words=2 skill_terms=0'), 1)

    def test_relabel_rerun_preserves_existing_output(self):
        for arm in ARMS:
            (self.root / 'arms' / arm / 'repo/app.txt').write_text(arm)
        first = self.run_relabel()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        before = {str(p.relative_to(self.root)): p.read_bytes()
                  for p in (self.root / 'runs').rglob('*') if p.is_file()}
        mapping = self.mapping.read_bytes()
        second = self.run_relabel()
        self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self.mapping.read_bytes(), mapping)
        after = {str(p.relative_to(self.root)): p.read_bytes()
                 for p in (self.root / 'runs').rglob('*') if p.is_file()}
        self.assertEqual(after, before)

    def test_relabel_partial_output_preserves_mapping(self):
        # A failed previous attempt may leave only a partial tree. Never
        # silently attach newly shuffled labels to any of that old output.
        (self.root / 'runs/r01/repo').mkdir(parents=True)
        marker = self.root / 'runs/r01/repo/app.txt'
        marker.write_text('previous incomplete attempt')
        mapping = self.mapping.read_bytes()
        result = self.run_relabel()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mapping.read_bytes(), mapping)
        self.assertEqual(marker.read_text(), 'previous incomplete attempt')
        self.assertFalse((self.root / 'runs/r01/repo/repo').exists())

    def test_relabel_missing_word_list_fails(self):
        self.words.unlink()
        result = self.run_relabel()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_relabel_empty_word_list_fails(self):
        self.words.write_text('')
        result = self.run_relabel()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_relabel_missing_report_fails(self):
        (self.root / 'arms/a2-1/report.md').unlink()
        result = self.run_relabel()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_relabel_grep_error_fails(self):
        # Controlled tool failure, not a real grep result. Proves status 2 is
        # not treated as a successful zero-match scan, even with readable files.
        bindir = self.root / 'bin'
        bindir.mkdir()
        stub = bindir / 'grep'
        stub.write_text('#!/bin/sh\necho simulated-grep-error >&2\nexit 2\n')
        stub.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'])
        result = self.run_relabel(env)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('simulated-grep-error', result.stderr)

    def test_timing_copies_all_rows(self):
        result = self.run_timing()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.root / 'out/timing.json').read_text())
        self.assertEqual(len(data['runs']), 9)
        for i, row in enumerate(data['runs'], 1):
            self.assertEqual(row, dict(arm=ARMS[i - 1], blind_label=f'r{i:02d}',
                                      duration_ms=i * 1000, duration_api_ms=i * 900,
                                      num_turns=i, total_cost_usd=i / 100))

    def test_timing_missing_mapping_fails(self):
        self.mapping.unlink()
        result = self.run_timing()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'out/timing.json').exists())

    def test_timing_duplicate_label_fails(self):
        self.mapping.write_text(self.mapping.read_text().replace('r02', 'r01'))
        result = self.run_timing()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'out/timing.json').exists())

    def test_timing_missing_result_preserves_previous_output(self):
        (self.root / 'out').mkdir()
        output = self.root / 'out/timing.json'
        output.write_text('previous data\n')
        (self.root / 'arms/a3-3/result.json').unlink()
        result = self.run_timing()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), 'previous data\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
