'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
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

// The idle-compact mod's compaction has the same shape as `/compact <focus>`:
// trigger "manual" with custom text. Build that text from the vendored source,
// so a re-vendor that rewords the instructions fails here.
function idleCompactInstructions() {
  const source = fs.readFileSync(
    path.join(__dirname, '..', '..', 'mods', 'idle-compact', 'hooks', 'register.ts'),
    'utf8'
  );
  const at = source.indexOf('const instructions = (at: string, idleMin: number) =>');
  assert.notStrictEqual(at, -1, 'register.ts no longer defines instructions(at, idleMin)');
  const end = source.indexOf('\n\n', at);
  const pieces = [];
  // The body is one template literal followed by plain string literals.
  for (const m of source.slice(at, end).matchAll(/`([^`]*)`|'([^']*)'/g)) {
    pieces.push(m[1] !== undefined ? m[1] : m[2]);
  }
  assert.ok(pieces.length >= 2, `expected the instruction literals, found ${pieces.length}`);
  const text = pieces.join('').replace('${at}', '17:36').replace('${idleMin}', '50');
  assert.doesNotMatch(text, /\$\{/, 'an unfilled placeholder is left in the instructions');
  return text;
}

test('idle-compact mod instructions (manual, custom text): emits preserve-list', async () => {
  const instructions = idleCompactInstructions();
  // What the mod sends, as its own source builds it.
  assert.match(instructions, /^This compaction ran automatically at 17:36, after 50 minutes idle/);
  assertEmits(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'manual',
      custom_instructions: instructions,
    })
  );
});

test('a user focus that only mentions an automatic compaction: still silent', async () => {
  assertSilent(
    await runHook(HOOK, {
      hook_event_name: 'PreCompact',
      trigger: 'manual',
      custom_instructions: 'keep the part where this compaction ran automatically at night',
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
