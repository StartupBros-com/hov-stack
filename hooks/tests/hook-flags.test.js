'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const hf = require('../lib/hook-flags');

// Save/restore env around each case so tests don't leak into one another.
function withEnv(vars, fn) {
  const saved = {};
  for (const k of Object.keys(vars)) {
    saved[k] = process.env[k];
    if (vars[k] === undefined) delete process.env[k];
    else process.env[k] = vars[k];
  }
  try {
    return fn();
  } finally {
    for (const k of Object.keys(saved)) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

test('enabled when the current profile is in the allowed list', () => {
  withEnv({ HOOK_PROFILE: 'standard', HOOK_DISABLED: undefined }, () => {
    assert.strictEqual(hf.isHookEnabled('x', { profiles: 'standard,strict' }), true);
  });
});

test('disabled when the current profile is not allowed', () => {
  withEnv({ HOOK_PROFILE: 'standard', HOOK_DISABLED: undefined }, () => {
    assert.strictEqual(hf.isHookEnabled('x', { profiles: 'strict' }), false);
  });
});

test('HOOK_DISABLED overrides an allowing profile', () => {
  withEnv({ HOOK_PROFILE: 'standard', HOOK_DISABLED: 'x,y' }, () => {
    assert.strictEqual(hf.isHookEnabled('x', { profiles: 'standard' }), false);
  });
});

test('empty hookId is always enabled', () => {
  assert.strictEqual(hf.isHookEnabled('', { profiles: 'strict' }), true);
});

test('an invalid HOOK_PROFILE falls back to standard', () => {
  withEnv({ HOOK_PROFILE: 'bogus' }, () => {
    assert.strictEqual(hf.getHookProfile(), 'standard');
  });
});

test('parseProfiles falls back when given nothing valid', () => {
  assert.deepStrictEqual(hf.parseProfiles(undefined), ['standard', 'strict']);
  assert.deepStrictEqual(hf.parseProfiles('nonsense'), ['standard', 'strict']);
  assert.deepStrictEqual(hf.parseProfiles('strict'), ['strict']);
});
