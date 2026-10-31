import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  assertNarrationMatchesWindow,
  canonicalizeSrtCues,
  parseStrictSrt,
} from './narrated-media';

test('strict SRT parsing produces ordered plain-text canonical cues', () => {
  const cues = parseStrictSrt(`1
00:00:00,500 --> 00:00:01,500
Open reports.

2
00:00:02,000 --> 00:00:03,000
Review progress.`);
  assert.deepEqual(canonicalizeSrtCues(cues, { endMs: 4_000, startMs: 0 }), [
    { id: 'cue-1', startMs: 500, endMs: 1_500, text: 'Open reports.' },
    { id: 'cue-2', startMs: 2_000, endMs: 3_000, text: 'Review progress.' },
  ]);
});

test('strict SRT rejects markup, overlap, malformed times, and window overflow', () => {
  assert.throws(
    () =>
      parseStrictSrt(`1
00:00:00,000 --> 00:00:01,000
<i>Not plain text</i>`),
    /plain text/i,
  );
  assert.throws(
    () =>
      parseStrictSrt(`1
00:00:00.000 --> 00:00:01,000
Bad timestamp`),
    /timing/i,
  );
  const overlapping = parseStrictSrt(`1
00:00:00,000 --> 00:00:01,500
First

2
00:00:01,000 --> 00:00:02,000
Second`);
  assert.throws(
    () => canonicalizeSrtCues(overlapping, { endMs: 3_000, startMs: 0 }),
    /overlap/i,
  );
  const overflowing = parseStrictSrt(`1
00:00:02,900 --> 00:00:03,500
Too late`);
  assert.throws(
    () => canonicalizeSrtCues(overflowing, { endMs: 3_000, startMs: 0 }),
    /window/i,
  );
});

test('narration duration drift is rejected rather than silently padded or clipped', () => {
  assert.doesNotThrow(() =>
    assertNarrationMatchesWindow(
      { durationMs: 6_030 },
      { endMs: 6_000, startMs: 0 },
      100,
    ),
  );
  assert.throws(
    () =>
      assertNarrationMatchesWindow(
        { durationMs: 6_500 },
        { endMs: 6_000, startMs: 0 },
        100,
      ),
    /drift/i,
  );
});
