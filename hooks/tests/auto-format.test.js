'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runHook, assertQuietPassThrough } = require('./lib/harness');

const HOOK = 'PostToolUse/auto-format.js';

test('passes non-JS/TS files through untouched', async () => {
  const payload = { tool_input: { file_path: '/tmp/readme.md' } };
  assertQuietPassThrough(await runHook(HOOK, payload));
});

test('passes malformed JSON through without throwing', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
});

test('JS file in a project with no formatter config → pass-through (no formatter invoked)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'af-'));
  try {
    // package.json makes this the project root; no biome/prettier config → detectFormatter null.
    fs.writeFileSync(path.join(dir, 'package.json'), '{}');
    const file = path.join(dir, 'x.ts');
    fs.writeFileSync(file, 'const a=1');
    const payload = { tool_input: { file_path: file } };
    assertQuietPassThrough(await runHook(HOOK, payload));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
