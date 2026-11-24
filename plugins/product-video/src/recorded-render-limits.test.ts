import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  RECORDED_DEFAULT_MAX_CONCURRENCY,
  RECORDED_FRAME_CACHE_BYTES,
  resolveRecordedRenderLimits,
} from './recorded-render-limits';

test('the default concurrency is half the cores, capped for many-core machines', () => {
  assert.equal(
    resolveRecordedRenderLimits(undefined, 28).concurrency,
    RECORDED_DEFAULT_MAX_CONCURRENCY,
  );
  assert.equal(resolveRecordedRenderLimits(undefined, 6).concurrency, 3);
  assert.equal(resolveRecordedRenderLimits(undefined, 1).concurrency, 1);
});

test('an explicit concurrency is used as given', () => {
  assert.equal(resolveRecordedRenderLimits('2', 28).concurrency, 2);
  assert.equal(resolveRecordedRenderLimits('12', 28).concurrency, 12);
});

test('a concurrency that is not a whole number of at least 1 is refused', () => {
  for (const flag of ['0', '-1', '1.5', 'four', '', '50%']) {
    assert.throws(
      () => resolveRecordedRenderLimits(flag, 28),
      /--concurrency must be a whole number/,
    );
  }
});

test('a concurrency above the core count is refused', () => {
  assert.throws(
    () => resolveRecordedRenderLimits('29', 28),
    /exceeds this machine's 28 cores/,
  );
});

test('the frame cache is bounded instead of sized from free memory', () => {
  assert.equal(
    resolveRecordedRenderLimits(undefined, 28).offthreadVideoCacheSizeInBytes,
    RECORDED_FRAME_CACHE_BYTES,
  );
});
