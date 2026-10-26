#!/usr/bin/env python3
"""Black-box test for compaction-profile.py floor composition: a synthetic transcript with two assistant requests and
one automatic compaction boundary, run with CLAUDE_PROJECTS_ROOT pointing at a temp dir (not ~/.claude)."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

PROFILE = pathlib.Path(__file__).resolve().parent.parent / 'scripts' / 'compaction-profile.py'
SUMMARY_HEAD = 'This session is being continued from a previous conversation that ran out of context. '


def request(mid, ctx):
    u = {'input_tokens': ctx, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0, 'output_tokens': 10}
    return {'type': 'assistant', 'uuid': mid, 'message': {'id': mid, 'usage': u, 'content': [{'type': 'text', 'text': 'x'}]}}


def boundary(trigger='auto'):
    md = json.dumps({'trigger': trigger, 'preTokens': 265000, 'postTokens': 40000})
    return {'type': 'system', 'subtype': 'compact_boundary', 'content': 'Conversation compacted', 'compactMetadata': md}


def summary(chars):
    return {'type': 'user', 'isCompactSummary': True,
            'message': {'role': 'user', 'content': SUMMARY_HEAD + 'x' * (chars - len(SUMMARY_HEAD))}}


class FloorComposition(unittest.TestCase):
    def run_profile(self, records, *args, plant=None):
        with tempfile.TemporaryDirectory() as d:
            proj = pathlib.Path(d) / 'projects' / '-tmp-fixture'
            proj.mkdir(parents=True)
            (proj / 's.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in records), encoding='utf-8')
            if plant: plant(pathlib.Path(d))  # files under the temporary HOME (skills, plugin cache)
            env = {**os.environ, 'HOME': d, 'CLAUDE_PROJECTS_ROOT': str(pathlib.Path(d) / 'projects')}
            r = subprocess.run([sys.executable, '-I', str(PROFILE), '14', '1', *args], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_floor_parts_add_up(self):
        out = self.run_profile([request('a', 50_000), boundary(), summary(4_000), request('b', 60_000)])
        self.assertIn('automatic boundaries (compactMetadata.trigger=auto) in long sessions: n=1', out, out)
        self.assertIn('prefix (session first request, measured): median=50,000 p90=50,000', out, out)
        self.assertIn('summary (chars/4, ESTIMATE): median=1,000 p90=1,000', out, out)
        self.assertIn('tail (floor - prefix - summary, derived): median=9,000 p90=9,000', out, out)
        self.assertIn('floor (first request after boundary, measured): median=60,000 p90=60,000', out, out)
        self.assertIn('steered/unsteered: not measurable from existing transcripts', out, out)

    def test_missing_summary_is_na_not_a_crash(self):
        """Planted negative: a boundary with no summary message reports n/a."""
        out = self.run_profile([request('a', 50_000), boundary(), request('b', 60_000)])
        self.assertIn('summary: n/a', out, out)
        self.assertIn('tail: n/a', out, out)
        self.assertIn('floor (first request after boundary, measured): median=60,000', out, out)

    def test_manual_boundary_is_not_automatic(self):
        out = self.run_profile([request('a', 50_000), boundary('manual'), summary(4_000), request('b', 60_000)])
        self.assertIn('in long sessions: n=0', out, out)

    def test_skill_listing_counts_one_plugin_version_and_block_scalar_descriptions(self):
        """One cached version per plugin (the manifest's, else the newest) and the full folded description.
        Planted negative: a second cached version of the same plugin must not add a third skill dir."""
        def skill(home, rel, desc):
            p = home / rel / 'SKILL.md'
            p.parent.mkdir(parents=True)
            p.write_text(f'---\nname: {p.parent.name}\n{desc}---\n# body\n', encoding='utf-8')
        def plant(home):
            skill(home, '.claude/skills/folded', 'description: >\n  line one\n  line two\n')  # 17 chars joined
            skill(home, '.claude/plugins/cache/mk/plug/1.0.0/skills/s', 'description: plugin skill\n')  # 12 chars
            skill(home, '.claude/plugins/cache/mk/plug/2.0.0/skills/s', 'description: plugin skill newer\n')
            manifest = {'version': 2, 'plugins': {'plug@mk': {'installPath': str(home / '.claude/plugins/cache/mk/plug/1.0.0'), 'version': '1.0.0'}}}
            (home / '.claude/plugins/installed_plugins.json').write_text(json.dumps(manifest), encoding='utf-8')
        out = self.run_profile([request('a', 50_000)], plant=plant)
        # (17 + 12) // 4 + 10 * 2 skill dirs
        self.assertIn('skill listing: 27 tokens (estimate: 2 skill dirs', out, out)

    def test_skill_listing_falls_back_to_the_newest_cached_version(self):
        """No manifest: the newest version dir by mtime stands in for the installed one."""
        def plant(home):
            for ver, desc in (('1.0.0', 'old skill'), ('2.0.0', 'new skill!!')):
                p = home / f'.claude/plugins/cache/mk/plug/{ver}/skills/s/SKILL.md'
                p.parent.mkdir(parents=True)
                p.write_text(f'---\nname: s\ndescription: {desc}\n---\n', encoding='utf-8')
            os.utime(home / '.claude/plugins/cache/mk/plug/1.0.0', (1_700_000_000, 1_700_000_000))
            os.utime(home / '.claude/plugins/cache/mk/plug/2.0.0', (1_800_000_000, 1_800_000_000))
        out = self.run_profile([request('a', 50_000)], plant=plant)
        # 11 chars // 4 + 10 * 1 skill dir
        self.assertIn('skill listing: 12 tokens (estimate: 1 skill dirs', out, out)

    def test_help_prints_docstring(self):
        r = subprocess.run([sys.executable, str(PROFILE), '--help'], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Usage: compaction-profile.py', r.stdout)


if __name__ == '__main__':
    unittest.main()
