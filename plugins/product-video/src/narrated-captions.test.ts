import assert from 'node:assert/strict';
import { test } from 'node:test';

import { narratedCaptionOverflowStyle } from './narrated-captions';

test('narrated captions contain long unbroken tokens inside the frame', () => {
  assert.deepEqual(narratedCaptionOverflowStyle, {
    maxHeight: 150,
    overflow: 'hidden',
    overflowWrap: 'anywhere',
    wordBreak: 'break-word',
  });
});
