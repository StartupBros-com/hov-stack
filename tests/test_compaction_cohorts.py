#!/usr/bin/env python3
"""Synthetic JSONL proofs for event-time cohorts; no live transcript content."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROFILE = Path(__file__).resolve().parent.parent / 'scripts' / 'compaction-profile.py'


def request(mid, when, ctx=310000, **extra):
    return {'type': 'assistant', 'uuid': mid, 'timestamp': when,
            'requestedModel': 'claude-opus-5-5', 'entrypoint': 'cli', 'sessionKind': 'bg',
            'message': {'id': mid, 'model': 'served-other', 'usage': {
                'input_tokens': ctx, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}}, **extra}


def boundary(when, trigger='auto', **extra):
    return {'type': 'system', 'subtype': 'compact_boundary', 'uuid': 'boundary', 'timestamp': when,
            'compactMetadata': {'trigger': trigger, 'preTokens': 320000, 'postTokens': 40000}, **extra}


class EventCohorts(unittest.TestCase):
    def run_profile(self, files, *args):
        with tempfile.TemporaryDirectory() as d:
            for name, records in files.items():
                p = Path(d) / 'projects' / name
                p.parent.mkdir(parents=True, exist_ok=True)
                if records is None:
                    p.symlink_to(p.parent / 'missing-target')
                    continue
                p.write_text(''.join(json.dumps(r) + '\n' for r in records))
                os.utime(p, (1, 1))  # Old mtime must not exclude recent events.
            # Never expose a real credential store to a synthetic fixture.
            (Path(d) / '.claude.json').mkdir()
            result = subprocess.run([sys.executable, '-I', str(PROFILE), '--since', '2026-10-05T00:00:00Z',
                                     '--until', '2026-10-11T00:00:00Z', '--split-at', '2026-10-10T00:00:00Z', *args],
                                    env={**os.environ, 'HOME': d, 'CLAUDE_PROJECTS_ROOT': str(Path(d) / 'projects')},
                                    text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_event_time_dedup_threshold_and_adjacent_request(self):
        a = request('a', '2026-10-09T23:59:00Z')
        out = self.run_profile({'p/s.jsonl': [request('old', '2026-10-04T12:00:00Z', 900000), a, a,
                                             boundary('2026-10-10T00:00:00Z'),
                                             request('b', '2026-10-10T00:01:00Z', 85000)]})
        before, after = out['cohorts']
        self.assertEqual(before['all']['requests'], 1)
        self.assertEqual(before['all']['sessions_reaching_300k'], 1)
        self.assertEqual(before['all']['requests_above_800k'], 0)
        self.assertEqual(after['all']['automatic_boundaries'], 1)
        self.assertEqual(after['all']['sessions_reaching_300k'], 1)  # native preTokens counts
        self.assertEqual(after['all']['automatic_pre_tokens_median'], 320000)
        self.assertEqual(after['all']['automatic_next_context_median'], 85000)
        self.assertEqual(after['groups'][0]['requested_models'], ['claude-opus-5-5'])
        self.assertEqual(after['groups'][0]['response_models'], ['served-other'])

    def test_short_subagent_and_typed_command_not_quoted_mentions(self):
        user = {'type': 'user', 'timestamp': '2026-10-06T01:00:00Z', 'uuid': 'u',
                'message': {'content': '<command-name>/compact</command-name>\n<command-message>compact</command-message>'}}
        quoted = {**user, 'uuid': 'q', 'message': {'content': 'Someone mentioned /compact and <command-name>/compact</command-name>'}}
        out = self.run_profile({'p/s/subagents/agent-x.jsonl': [request('a', '2026-10-06T00:00:00Z'), user, user, quoted,
                                      boundary('2026-10-06T01:01:00Z', 'manual'),
                                      request('b', '2026-10-07T00:00:00Z', 900000, interruptedMessageId='cut') ]})
        row = out['cohorts'][0]['all']
        self.assertEqual(row['sessions'], 1)
        self.assertEqual(row['active_session_days_utc'], 2)
        self.assertEqual(row['typed_compact'], 1)
        self.assertEqual(row['typed_compact_per_session_day'], .5)
        self.assertEqual(row['automatic_boundaries'], 0)
        self.assertIsNone(row['automatic_pre_tokens_median'])
        self.assertEqual(row['interrupted_messages'], 1)
        self.assertEqual(out['cohorts'][0]['groups'][0]['kind'], 'subagent')

    def test_missing_identity_is_not_inferred_from_response(self):
        a = request('a', '2026-10-06T00:00:00Z')
        del a['requestedModel']
        out = self.run_profile({'p/s.jsonl': [a, boundary('2026-10-06T00:01:00Z')]})
        group = out['cohorts'][0]['groups'][0]
        self.assertEqual(group['model_class'], 'unknown')
        self.assertEqual(group['automatic_without_next_request'], 1)
        self.assertIsNone(out['cohorts'][1]['all']['typed_compact_per_session_day'])

    def test_relocated_records_are_deduplicated_across_files(self):
        records = [request('a', '2026-10-06T00:00:00Z', sessionId='same'),
                   boundary('2026-10-06T00:01:00Z', sessionId='same'),
                   request('b', '2026-10-06T00:02:00Z', 60000, sessionId='same')]
        out = self.run_profile({'p/s.jsonl': records, 'q/s.jsonl': records})
        row = out['cohorts'][0]['all']
        self.assertEqual(row['requests'], 2)
        self.assertEqual(row['automatic_boundaries'], 1)
        self.assertEqual(row['automatic_next_context_median'], 60000)
        self.assertEqual(out['quality']['duplicate_activity_records'], 3)
        self.assertIsNone(row['compaction_caused_interruptions'])
        self.assertIsNone(row['loop_fence_stops'])
        self.assertIsNone(row['loop_handoff_rotations'])

    def test_partial_relocation_preserves_adjacency_and_identity(self):
        a = request('a', '2026-10-06T00:00:00Z', sessionId='same')
        first = boundary('2026-10-06T00:01:00Z', uuid='first', sessionId='same')
        second = boundary('2026-10-06T00:02:00Z', uuid='second', sessionId='same')
        b = request('b', '2026-10-06T00:03:00Z', 60000, sessionId='same')
        out = self.run_profile({'p/s.jsonl': [a, first], 'q/s.jsonl': [a, first, b]})
        self.assertEqual(out['cohorts'][0]['all']['automatic_next_context_median'], 60000)
        self.assertEqual(out['cohorts'][0]['all']['automatic_without_next_request'], 0)
        # A newly appended boundary must inherit A even when A was deduplicated.
        out = self.run_profile({'p/s.jsonl': [a, first], 'q/s.jsonl': [a, first, second, b]})
        groups = out['cohorts'][0]['groups']
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['model_class'], 'named')
        self.assertEqual(groups[0]['automatic_boundaries'], 2)
        self.assertEqual(groups[0]['automatic_without_next_request'], 1)
        self.assertEqual(groups[0]['automatic_next_context_median'], 60000)

    def test_chronology_not_file_or_record_order_determines_adjacency(self):
        a = request('a', '2026-10-06T00:00:00Z', sessionId='same')
        mark = boundary('2026-10-06T00:01:00Z', sessionId='same')
        b = request('b', '2026-10-06T00:02:00Z', 60000, sessionId='same')
        ordered = self.run_profile({'p/s.jsonl': [a, mark, b]})
        reversed_files = self.run_profile({'p/s.jsonl': [b, mark], 'q/s.jsonl': [a]})
        self.assertEqual(ordered['cohorts'], reversed_files['cohorts'])

    def test_duplicate_timestamps_use_earliest_observation_not_file_order(self):
        early = request('a', '2026-10-09T23:59:00Z', sessionId='same')
        late = {**early, 'timestamp': '2026-10-10T00:01:00Z'}
        first = self.run_profile({'p/s.jsonl': [early], 'q/s.jsonl': [late]})
        reversed_files = self.run_profile({'p/s.jsonl': [late], 'q/s.jsonl': [early]})
        self.assertEqual(first['cohorts'], reversed_files['cohorts'])
        self.assertEqual([r['all']['requests'] for r in first['cohorts']], [1, 0])

    def test_interruption_without_usage_survives_request_dedup(self):
        for usage in (None, {}):
            with self.subTest(usage=usage):
                cut = request('a', '2026-10-06T00:01:00Z', sessionId='same', interruptedMessageId='cut')
                cut['message']['usage'] = usage
                alone = self.run_profile({'p/s.jsonl': [cut]})['cohorts'][0]['all']
                self.assertEqual(alone['interrupted_messages'], 1)
                self.assertEqual(alone['sessions'], 1)
                self.assertEqual(alone['active_session_days_utc'], 1)
                self.assertEqual(alone['requests'], 0)
                positive = request('a', '2026-10-06T00:00:00Z', sessionId='same')
                first = self.run_profile({'p/s.jsonl': [positive], 'q/s.jsonl': [cut, cut]})
                reversed_files = self.run_profile({'p/s.jsonl': [cut, cut], 'q/s.jsonl': [positive]})
                self.assertEqual(first['cohorts'], reversed_files['cohorts'])
                self.assertEqual(first['cohorts'][0]['all']['interrupted_messages'], 1)
                self.assertEqual(first['cohorts'][0]['all']['requests'], 1)

    def test_second_boundary_censors_first_and_until_censors_next_request(self):
        out = self.run_profile({'p/s.jsonl': [
            request('a', '2026-10-06T00:00:00Z'),
            boundary('2026-10-06T00:01:00Z', uuid='first'),
            boundary('2026-10-06T00:02:00Z', uuid='second'),
            request('b', '2026-10-06T00:03:00Z', 60000),
            boundary('2026-10-10T23:59:00Z', uuid='third'),
            request('c', '2026-10-11T00:00:00Z', 90000)]})
        before, after = out['cohorts']
        self.assertEqual(before['all']['automatic_boundaries'], 2)
        self.assertEqual(before['all']['automatic_without_next_request'], 1)
        self.assertEqual(before['all']['automatic_next_context_median'], 60000)
        self.assertEqual(after['all']['automatic_without_next_request'], 1)
        self.assertIsNone(after['all']['automatic_next_context_median'])

    def test_unreadable_error_counts_and_below_window_strata(self):
        out = self.run_profile({'p/missing.jsonl': None,
                               'p/s.jsonl': [request('a', '2026-10-06T00:00:00Z', 270000),
                                             boundary('2026-10-06T00:01:00Z', compactMetadata={
                                                 'trigger': 'auto', 'preTokens': 270000})],
                               'p/s/subagents/agent-x.jsonl': [request('b', '2026-10-06T00:00:00Z', 40000)]})
        self.assertEqual(out['quality']['unreadable_files'], 1)
        self.assertEqual(out['quality']['read_errors'], [{'kind': 'FileNotFoundError', 'errno': 2, 'files': 1}])
        cohort = out['cohorts'][0]
        self.assertEqual(cohort['main']['automatic_pre_tokens_below_300k'], 1)
        self.assertIsNone(cohort['main']['automatic_per_eligible_session'])
        self.assertEqual(cohort['main']['requests'], 1)
        self.assertEqual(cohort['subagents']['requests'], 1)
        self.assertEqual(cohort['subagents']['automatic_boundaries'], 0)

    def test_iteration_context_and_end_exclusive(self):
        a = request('a', '2026-10-06T00:00:00Z', 900000)
        a['message']['usage']['iterations'] = [{'type': 'message', 'input_tokens': 50000,
                                               'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}]
        out = self.run_profile({'p/s.jsonl': [a, request('b', '2026-10-11T00:00:00Z', 900000)]})
        self.assertEqual(out['cohorts'][0]['all']['sessions_reaching_300k'], 0)
        self.assertEqual(out['cohorts'][1]['all']['requests'], 0)


if __name__ == '__main__':
    unittest.main()
