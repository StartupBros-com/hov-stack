'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { runHook, decisionOf, assertQuietPassThrough } = require('./lib/harness');

const HOOK = 'PreToolUse/settings-guard.js';

const edit = (file_path, tool_name = 'Edit') => ({ tool_name, tool_input: { file_path } });
const bash = (command) => ({ tool_name: 'Bash', tool_input: { command } });

test('ask-gates Edit/Write/MultiEdit on permission-surface files', async () => {
  for (const tool of ['Edit', 'Write', 'MultiEdit']) {
    for (const name of ['settings.json', 'settings.local.json', 'managed-settings.json']) {
      const res = await runHook(HOOK, edit(`/home/user/.claude/${name}`, tool));
      assert.strictEqual(decisionOf(res), 'ask', `${tool} ${name}`);
    }
  }
});

test('does NOT gate Bash (full Bash autonomy is a standing decision)', async () => {
  for (const command of [
    "jq '.env.X=1' ~/.claude/settings.json > /tmp/out.json",
    'sed -i s/foo/bar/ /home/user/.claude/settings.json',
    'cat ~/.claude/settings.json',
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

test('allows editor writes to unrelated files', async () => {
  for (const payload of [edit('/repo/src/config.json'), edit('/repo/app/theme.json')]) {
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('passes malformed and unsupported tool input through', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
  const payload = { tool_name: 'Read', tool_input: { file_path: '/home/user/.claude/settings.json' } };
  assertQuietPassThrough(await runHook(HOOK, payload));
});
