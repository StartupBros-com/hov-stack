import assert from 'node:assert/strict';
import { test } from 'node:test';

import { assertCaptureSourceDuration } from './narrated-duration';

test('capture duration accepts bounded WebM tail padding but not missing frames', () => {
  assert.doesNotThrow(() =>
    assertCaptureSourceDuration({
      declaredDurationMs: 26_742,
      fps: 30,
      observedDurationMs: 27_400,
    }),
  );
  assert.throws(
    () =>
      assertCaptureSourceDuration({
        declaredDurationMs: 26_742,
        fps: 30,
        observedDurationMs: 26_500,
      }),
    /shorter/i,
  );
  assert.throws(
    () =>
      assertCaptureSourceDuration({
        declaredDurationMs: 26_742,
        fps: 30,
        observedDurationMs: 27_743,
      }),
    /tail padding/i,
  );
});
