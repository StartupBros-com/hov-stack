import json
from pathlib import Path
import unittest
from cli import build_command


class CommandTests(unittest.TestCase):
    def test_space_is_one_argument(self):
        self.assertEqual(build_command('team alpha'), ['tool', 'inspect', '--project', 'team alpha'])

    def test_literal_shell_text_is_data(self):
        self.assertEqual(build_command('demo; print secret'), ['tool', 'inspect', '--project', 'demo; print secret'])

    def test_plain_project(self):
        self.assertEqual(build_command('demo'), ['tool', 'inspect', '--project', 'demo'])

    def test_consecutive_spaces_are_verbatim(self):
        self.assertEqual(build_command('team  alpha'), ['tool', 'inspect', '--project', 'team  alpha'])

    def test_leading_spaces_are_verbatim(self):
        self.assertEqual(build_command('  alpha'), ['tool', 'inspect', '--project', '  alpha'])

    def test_trailing_spaces_are_verbatim(self):
        self.assertEqual(build_command('alpha  '), ['tool', 'inspect', '--project', 'alpha  '])

    def test_tabs_are_verbatim(self):
        self.assertEqual(build_command('\tteam\talpha\t'), ['tool', 'inspect', '--project', '\tteam\talpha\t'])

    def test_newlines_are_verbatim(self):
        self.assertEqual(build_command('\nteam\nalpha\n'), ['tool', 'inspect', '--project', '\nteam\nalpha\n'])

    def test_empty_string_is_an_argument(self):
        self.assertEqual(build_command(''), ['tool', 'inspect', '--project', ''])

    def test_observed_invocation_replays(self):
        records = json.loads(Path(__file__).with_name('source-events.json').read_text())
        observed = records['synthetic-split-001']
        self.assertEqual(build_command(observed['input']['project']), observed['expected_argv'])


if __name__ == '__main__':
    unittest.main()
