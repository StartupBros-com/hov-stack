import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isCommandAvailable } from './command-availability';

test('command availability accepts success and bounds stalled probes', () => {
  assert.equal(isCommandAvailable(process.execPath, ['--version']), true);
  assert.equal(
    isCommandAvailable(
      process.execPath,
      ['-e', 'setTimeout(() => undefined, 1_000)'],
      20,
    ),
    false,
  );
  assert.equal(
    isCommandAvailable('missing-narrated-prerequisite-command', ['--version']),
    false,
  );
});
