import assert from 'node:assert/strict';
import { test } from 'node:test';

import fixture from '../fixtures/narrated-browser-tour.json';
import { assertCaptureSourceDuration } from './narrated-duration';
import { assertNarrationMatchesWindow } from './narrated-media';
import { parseNarratedResolvedManifest } from './narrated-resolved-contracts';
import { assertNarratedDurationMatches } from './narrated-verification';

const baseManifest = parseNarratedResolvedManifest(fixture);

for (const [fps, toleranceMs] of [
  [12, 167],
  [15, 134],
  [19.99, 101],
  [20, 100],
  [24, 100],
  [29.97, 100],
  [30, 100],
  [60, 100],
]) {
  test(`capture and render keep distinct inclusive boundaries at ${fps}fps`, () => {
    const declaredDurationMs = 6_000;
    const capture = (delta: number) =>
      assertCaptureSourceDuration({
        declaredDurationMs,
        fps: fps!,
        observedDurationMs: declaredDurationMs + delta,
      });
    assert.doesNotThrow(() => capture(-toleranceMs!));
    assert.throws(() => capture(-toleranceMs! - 1), {
      message: 'Capture source is shorter than its declared timeline',
    });
    assert.doesNotThrow(() => capture(1_000));
    assert.throws(() => capture(1_001), {
      message: 'Capture source tail padding exceeds its bounded tolerance',
    });

    const manifest = {
      ...baseManifest,
      project: { ...baseManifest.project, fps: fps! },
    };
    for (const sign of [-1, 1]) {
      assert.doesNotThrow(() =>
        assertNarratedDurationMatches(
          manifest.durationMs + sign * toleranceMs!,
          manifest,
        ),
      );
      assert.throws(
        () =>
          assertNarratedDurationMatches(
            manifest.durationMs + sign * (toleranceMs! + 1),
            manifest,
          ),
        {
          message: `Narrated duration drift exceeds ${toleranceMs}ms; refusing to hide source/render mismatch`,
        },
      );
      assert.doesNotThrow(() =>
        assertNarrationMatchesWindow(
          { durationMs: declaredDurationMs + sign * toleranceMs! },
          { startMs: 0, endMs: declaredDurationMs },
          toleranceMs!,
        ),
      );
      assert.throws(
        () =>
          assertNarrationMatchesWindow(
            { durationMs: declaredDurationMs + sign * (toleranceMs! + 1) },
            { startMs: 0, endMs: declaredDurationMs },
            toleranceMs!,
          ),
        /Narration duration drift/,
      );
    }
  });
}

test('existing number-taking APIs preserve nonfinite and signed-zero behavior', () => {
  for (const fps of [0, -0, -1, Infinity, -Infinity, NaN]) {
    const toleranceMs = Math.max(100, Math.ceil(2_000 / fps));
    for (const delta of [-10_000, -101, -100, 100, 101, 1_000, 1_001]) {
      const capture = () =>
        assertCaptureSourceDuration({
          declaredDurationMs: 6_000,
          fps,
          observedDurationMs: 6_000 + delta,
        });
      if (delta < -toleranceMs || delta > 1_000) {
        assert.throws(capture);
      } else {
        assert.doesNotThrow(capture);
      }
      const render = () =>
        assertNarratedDurationMatches(6_000 + delta, {
          ...baseManifest,
          durationMs: 6_000,
          project: { ...baseManifest.project, fps },
        });
      if (Math.abs(delta) > toleranceMs) {
        assert.throws(render);
      } else {
        assert.doesNotThrow(render);
      }
    }
  }
});
