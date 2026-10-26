'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { runHook } = require('./lib/harness');

const HOOK = 'PreCompact/compact-preserve.js';

// The whole contract: exit 0 always (exit 2 would BLOCK compaction — for a
// reactive compact that fails the user's request outright), and stdout is
// either empty or the preserve-list.
function assertEmits(res) {
  assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
  assert.match(res.stdout, /Preserve these in the summary/);
  assert.match(res.stdout, /verification ledger/i);
}

function assertSilent(res) {
  assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
  assert.strictEqual(res.stdout, '', 'expected no output');
}

test('auto trigger: emits preserve-list', async () => {
  assertEmits(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'auto',
      custom_instructions: '',
    })
  );
});

test('manual trigger with user instructions: silent (user focus wins)', async () => {
  assertSilent(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'manual',
      custom_instructions: 'focus on the auth bug fix',
    })
  );
});

test('manual trigger with empty instructions: emits preserve-list', async () => {
  assertEmits(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'manual',
      custom_instructions: '',
    })
  );
});

test('manual trigger with null instructions (schema allows null): emits', async () => {
  assertEmits(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'manual',
      custom_instructions: null,
    })
  );
});

test('whitespace-only manual instructions count as empty: emits', async () => {
  assertEmits(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'manual',
      custom_instructions: '   \n ',
    })
  );
});

test('malformed stdin: still exits 0 and emits (never blocks, never errors)', async () => {
  assertEmits(await runHook(HOOK, 'this is not json {'));
});

test('empty stdin: still exits 0 and emits', async () => {
  assertEmits(await runHook(HOOK, ''));
});

test('never exits 2 under any input shape', async () => {
  const shapes = [
    { hook_event_name: 'PreCompact' },
    { trigger: 42, custom_instructions: { nested: true } },
    '[]',
    'null',
  ];
  for (const s of shapes) {
    const res = await runHook(HOOK, s);
    assert.strictEqual(res.code, 0, `input ${JSON.stringify(s)} exited ${res.code}`);
  }
});
