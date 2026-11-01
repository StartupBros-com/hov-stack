import assert from 'node:assert/strict';
import { test } from 'node:test';

import { getNarratedDurationToleranceMs } from './narrated-duration';

test('duration tolerance preserves rounding, the floor and all numeric edge cases', () => {
  for (const fps of [
    -Infinity,
    -60,
    -1,
    -0,
    0,
    Number.MIN_VALUE,
    0.5,
    12,
    15,
    19.99,
    20,
    23.976,
    24,
    29.97,
    30,
    60,
    Number.MAX_VALUE,
    Infinity,
    NaN,
  ]) {
    assert.equal(
      getNarratedDurationToleranceMs(fps),
      Math.max(100, Math.ceil(2_000 / fps)),
    );
  }
});
