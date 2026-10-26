#!/usr/bin/env python3
"""Black-box tests for compaction-profile.py (issue #1313). The other miner, transcript-mine.py, was
retired in dotfiles#1429 with no runtime caller, and its cases went with it.

Claude Code writes one JSONL record per assistant content block; every record of one API request repeats
message.id, and output_tokens grows from the first record to the last. The miner must count one request
per message id. Runs the script against a temporary HOME holding one fixture session."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent / 'scripts'
PROFILE = SCRIPTS / 'compaction-profile.py'


def usage(ci, out, cc=0):
    return {'input_tokens': ci - cc, 'cache_creation_input_tokens': cc, 'cache_read_input_tokens': 0,
            'output_tokens': out, 'output_tokens_details': {'thinking_tokens': out // 2}}


def record(mid, block, u, effort='low'):
    return {'type': 'assistant', 'uuid': f'{mid}-{block["type"]}', 'effort': effort,
            'message': {'id': mid, 'model': 'claude-sonnet-5', 'usage': u, 'content': [block]}}


def fixture_session():
    """Two requests. Request A spans three records (thinking, text, tool_use) with the same id; output grows
    314 -> 900 -> 1200. Request B is one record. A naive counter reports 4 requests and 4x the context."""
    a = [record('msg_A', {'type': 'thinking', 'thinking': '...'}, usage(50_000, 314)),
         record('msg_A', {'type': 'text', 'text': 'hi'}, usage(50_000, 900)),
         record('msg_A', {'type': 'tool_use', 'name': 'Read', 'input': {'file_path': '/x'}}, usage(50_000, 1200))]
    b = [record('msg_B', {'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'ls'}}, usage(60_000, 400, cc=25_000))]
    human = {'type': 'user', 'message': {'role': 'user', 'content': 'go'}}
    return [human] + a + b


def advisor_session():
    """One request from the response that hard-stopped #1540's fixer (#1544): its top-level usage sums its two
    main-model `message` iterations to 398,630 (the `advisor_message` iteration is not in it); the last message
    iteration, the real context, is 2 + 2,128 + 198,234 = 200,364."""
    u = {'input_tokens': 34, 'cache_creation_input_tokens': 2630, 'cache_read_input_tokens': 395966, 'output_tokens': 50,
         'iterations': [
             {'type': 'message', 'input_tokens': 32, 'cache_creation_input_tokens': 502, 'cache_read_input_tokens': 197732},
             {'type': 'advisor_message', 'input_tokens': 199528, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0},
             {'type': 'message', 'input_tokens': 2, 'cache_creation_input_tokens': 2128, 'cache_read_input_tokens': 198234}]}
    human = {'type': 'user', 'message': {'role': 'user', 'content': 'go'}}
    return [human, record('msg_ADV', {'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'ls'}}, u)]


class FixtureHome(unittest.TestCase):
    """Runs a miner against a temporary HOME holding one session built from self.session()."""
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        proj = pathlib.Path(self.home.name) / '.claude' / 'projects' / '-tmp-fixture'
        proj.mkdir(parents=True)
        with open(proj / 'sess-1.jsonl', 'w', encoding='utf-8') as fh:
            for r in self.session():
                fh.write(json.dumps(r) + '\n')
        self.env = {**os.environ, 'HOME': self.home.name}

    def tearDown(self):
        self.home.cleanup()

    def run_script(self, script, *args):
        r = subprocess.run([sys.executable, str(script), *args], env=self.env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout


class MinersDedupeByMessageId(FixtureHome):
    session = staticmethod(fixture_session)

    def test_compaction_profile_counts_requests_once(self):
        out = self.run_script(PROFILE, '14', '1')
        self.assertIn('long sessions (>=1 req): 1, requests: 2', out, out)  # not 4

    def test_naive_count_would_be_four(self):
        """Planted negative: the fixture really does hold four assistant records."""
        n = sum(1 for r in fixture_session() if r['type'] == 'assistant')
        self.assertEqual(n, 4)


class ProfileCountsLastMessageIteration(FixtureHome):
    session = staticmethod(advisor_session)

    def test_advisor_request_lands_in_its_real_context_band(self):
        out = self.run_script(PROFILE, '14', '1')
        self.assertIn('200k-300k=100.0%', out, out)
        self.assertNotIn('300k-400k', out, out)

    def test_top_level_sum_would_land_a_band_higher(self):
        """Planted negative: the fixture's summed top-level usage really is in the 300k band."""
        u = advisor_session()[1]['message']['usage']
        top = u['input_tokens'] + u['cache_creation_input_tokens'] + u['cache_read_input_tokens']
        self.assertEqual((top, top // 100_000), (398_630, 3))


def malformed_iterations_session():
    """Two requests whose top level reads 350,002 (#1550 review): one with a partial message iteration that alone would
    read 2, one whose iterations value is not a list. Both must count at the top level, and neither may crash."""
    top = {'input_tokens': 2, 'cache_creation_input_tokens': 100_000, 'cache_read_input_tokens': 250_000, 'output_tokens': 9}
    human = {'type': 'user', 'message': {'role': 'user', 'content': 'go'}}
    block = {'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'ls'}}
    return [human,
            record('msg_PARTIAL', block, {**top, 'iterations': [{'type': 'message', 'input_tokens': 2}]}),
            record('msg_NOTLIST', block, {**top, 'iterations': True})]


class ProfileKeepsTopLevelForIncompleteIterations(FixtureHome):
    session = staticmethod(malformed_iterations_session)

    def test_incomplete_iterations_count_at_the_top_level(self):
        out = self.run_script(PROFILE, '14', '1')
        self.assertIn('requests: 2', out, out)
        self.assertIn('300k-400k=100.0%', out, out)


if __name__ == '__main__':
    unittest.main()
