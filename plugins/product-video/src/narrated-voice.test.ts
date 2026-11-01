import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  assertCueAudioFits,
  assertNarrationFitsTimeline,
  buildNarrationMixArgs,
  narrationSampleRate,
  planNarrationCues,
} from './narrated-voice';

const srt = [
  '1',
  '00:00:01,000 --> 00:00:04,000',
  'Open the workspace.',
  '',
  '2',
  '00:00:05,000 --> 00:00:08,000',
  'Review the results.',
  '',
].join('\n');

test('narration cues come from the same SRT parser prepare uses', () => {
  const cues = planNarrationCues(srt);
  assert.equal(cues.length, 2);
  assert.deepEqual(
    cues.map((cue) => [cue.startMs, cue.endMs]),
    [
      [1_000, 4_000],
      [5_000, 8_000],
    ],
  );
  assert.throws(() => planNarrationCues(''), /empty/i);
});

test('narration must fit inside the capture timeline', () => {
  const cues = planNarrationCues(srt);
  assert.doesNotThrow(() => assertNarrationFitsTimeline(cues, 8_000));
  assert.throws(
    () => assertNarrationFitsTimeline(cues, 7_000),
    /outside the 7000ms timeline/,
  );
});

test('a cue whose speech overruns its window fails closed', () => {
  const [cue] = planNarrationCues(srt);
  assert.ok(cue);
  // 3000ms window, 400ms default tolerance.
  assert.doesNotThrow(() => assertCueAudioFits(cue, 3_200));
  assert.throws(() => assertCueAudioFits(cue, 4_365), /runs 4365ms/);
});

test('each cue is delayed to its own start so the voice cannot drift', () => {
  const cues = planNarrationCues(srt);
  const args = buildNarrationMixArgs({
    cues,
    durationMs: 8_000,
    segmentPaths: ['/tmp/a.wav', '/tmp/b.wav'],
    outputPath: '/tmp/out.wav',
  });
  const filter = args[args.indexOf('-filter_complex') + 1];
  assert.ok(filter);
  assert.match(filter, /\[1:a\]adelay=1000\|1000/);
  assert.match(filter, /\[2:a\]adelay=5000\|5000/);
  assert.match(filter, /amix=inputs=3:normalize=0:duration=first/);
  assert.ok(args.includes(String(narrationSampleRate)));
  assert.ok(args.includes('pcm_s16le'));

  assert.throws(
    () =>
      buildNarrationMixArgs({
        cues,
        durationMs: 8_000,
        segmentPaths: ['/tmp/a.wav'],
        outputPath: '/tmp/out.wav',
      }),
    /exactly one rendered segment/,
  );
});
