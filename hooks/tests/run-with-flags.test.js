'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { runViaFlags, assertQuietPassThrough } = require('./lib/harness');

const PAYLOAD = '{"hello":"world"}';

test('awaits an async run() and writes its resolved output [regression: un-awaited async hook]', async () => {
  const res = await runViaFlags('test:async', 'tests/fixtures/async-echo.hook.js', 'standard', PAYLOAD);
  assert.strictEqual(res.code, 0);
  assert.strictEqual(res.stdout, 'ASYNC:' + PAYLOAD, 'async run() output must be awaited, not a stringified Promise');
});

test('runs a sync run() and writes its output', async () => {
  const res = await runViaFlags('test:sync', 'tests/fixtures/sync-echo.hook.js', 'standard', PAYLOAD);
  assert.strictEqual(res.code, 0);
  assert.strictEqual(res.stdout, 'SYNC:' + PAYLOAD);
});

test('a throwing run() is caught → input passes through, error on stderr', async () => {
  const res = await runViaFlags('test:throws', 'tests/fixtures/throws.hook.js', 'standard', PAYLOAD);
  assertQuietPassThrough(res);
  assert.match(res.stderr, /run\(\) error/);
});

test('disabled by profile mismatch → pass-through, hook not run', async () => {
  // HOOK_PROFILE is forced to 'standard'; allowing only 'strict' disables it.
  const res = await runViaFlags('test:sync', 'tests/fixtures/sync-echo.hook.js', 'strict', PAYLOAD);
  assertQuietPassThrough(res);
});

test('disabled by HOOK_DISABLED → pass-through', async () => {
  const res = await runViaFlags('test:sync', 'tests/fixtures/sync-echo.hook.js', 'standard', PAYLOAD, {
    env: { HOOK_DISABLED: 'test:sync' },
  });
  assertQuietPassThrough(res);
});

test('missing script → pass-through, exit 0, stderr notes it', async () => {
  const res = await runViaFlags('test:missing', 'tests/fixtures/does-not-exist.js', 'standard', PAYLOAD);
  assertQuietPassThrough(res);
  assert.match(res.stderr, /Script not found/);
});

test('path traversal outside the hooks root → rejected, pass-through', async () => {
  const res = await runViaFlags('test:traversal', '../../../../etc/passwd', 'standard', PAYLOAD);
  assertQuietPassThrough(res);
  assert.match(res.stderr, /traversal/i);
});

test('no hookId/script args → pass-through unchanged', async () => {
  const res = await runViaFlags('', '', '', PAYLOAD);
  assertQuietPassThrough(res);
});
