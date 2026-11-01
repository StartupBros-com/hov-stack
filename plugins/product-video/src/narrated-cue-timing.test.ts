import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  alignCuesToAnchors,
  collectCueAnchors,
  cueLeadInMs,
  measureCueLag,
} from './narrated-cue-timing';

const events = [
  { channel: 'route' as const, seq: 0, tMs: 884, routeId: 'dashboard' },
  { channel: 'route' as const, seq: 1, tMs: 12_739, routeId: 'profiles' },
  { channel: 'route' as const, seq: 2, tMs: 20_449, routeId: 'members' },
  { channel: 'route' as const, seq: 3, tMs: 20_600, routeId: 'members' },
  { channel: 'route' as const, seq: 4, tMs: 29_142, routeId: 'dashboard' },
];

test('anchors collapse repeat route events from one navigation', () => {
  const anchors = collectCueAnchors(events);
  assert.deepEqual(
    anchors.map((a) => a.tMs),
    [884, 12_739, 20_449, 29_142],
  );
});

test('cues snap onto the screen change they describe', () => {
  const anchors = collectCueAnchors(events);
  // The lags actually measured on the shipped tour.
  const authored = [
    { startMs: 1_300, endMs: 8_300 },
    { startMs: 13_400, endMs: 19_800 },
    { startMs: 21_400, endMs: 28_300 },
    { startMs: 30_000, endMs: 33_200 },
  ];
  const before = measureCueLag(authored, anchors);
  assert.deepEqual(before, [416, 661, 951, 858]);

  const aligned = alignCuesToAnchors(authored, anchors, 33_308);
  const after = measureCueLag(aligned, anchors);
  for (const lag of after) {
    assert.equal(lag, cueLeadInMs);
  }
  // Durations survive the move.
  aligned.forEach((cue, index) => {
    assert.equal(
      cue.endMs - cue.startMs,
      authored[index]!.endMs - authored[index]!.startMs,
    );
  });
});

test('cues never overlap or run past the timeline', () => {
  const anchors = collectCueAnchors(events);
  const aligned = alignCuesToAnchors(
    [
      { startMs: 1_000, endMs: 12_000 },
      { startMs: 12_500, endMs: 21_000 },
    ],
    anchors,
    22_000,
  );
  assert.ok(aligned[1]!.startMs >= aligned[0]!.endMs, 'cues overlap');
  for (const cue of aligned) {
    assert.ok(cue.endMs <= 22_000, 'cue runs past the timeline');
  }
});

test('a cue with no plausible anchor keeps its authored start', () => {
  const aligned = alignCuesToAnchors(
    [{ startMs: 60_000, endMs: 62_000 }],
    collectCueAnchors(events),
    70_000,
  );
  assert.equal(aligned[0]!.startMs, 60_000);
});
