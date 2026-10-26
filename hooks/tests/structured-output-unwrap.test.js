'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'PreToolUse/structured-output-unwrap.js';
const MISMATCH = "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'";

function transcriptWith(dir, lines, name = 'session.jsonl') {
  const p = path.join(dir, name);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, lines.map((l) => JSON.stringify(l)).join('\n') + '\n');
  return p;
}
const use = (id, input) => ({
  type: 'assistant',
  message: { role: 'assistant', content: [{ type: 'tool_use', id, name: 'StructuredOutput', input }] },
});
const result = (id, text) => ({
  type: 'user',
  message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text }] },
});
const WRAPPED = { input: { refuted: false, reasoning: 'holds' } };
const payload = (over) => ({
  hook_event_name: 'PreToolUse',
  tool_name: 'StructuredOutput',
  tool_input: { input: { refuted: false, reasoning: 'holds, retried' } },
  session_id: 's',
  cwd: '/tmp',
  ...over,
});

test('the retry of a wrapped attempt that failed on its inner keys is unwrapped', async () => {
  const dir = mkTmp('so-unwrap-');
  try {
    const t = transcriptWith(dir, [use('t1', WRAPPED), result('t1', MISMATCH)]);
    const res = await runHook(HOOK, payload({ transcript_path: t }));
    const out = JSON.parse(res.stdout);
    assert.strictEqual(out.hookSpecificOutput.hookEventName, 'PreToolUse');
    assert.deepStrictEqual(out.hookSpecificOutput.updatedInput, { refuted: false, reasoning: 'holds, retried' });
    assert.match(out.hookSpecificOutput.permissionDecisionReason, /unwrapped/);
    assert.strictEqual('additionalContext' in out.hookSpecificOutput, false,
      'additionalContext is not a PreToolUse field; an unknown field can void the rewrite');
    assert.strictEqual('permissionDecision' in out.hookSpecificOutput, false,
      'no auto-approve: the modified input flows through normal permission evaluation');
  } finally { rmTmp(dir); }
});

test('a wrapped call with NO prior attempt passes through untouched', async () => {
  // A schema whose only top-level property is `input` looks exactly like this
  // on its first call; without a demonstrated failure the hook must not guess.
  const dir = mkTmp('so-unwrap-');
  try {
    const t = transcriptWith(dir, [{ type: 'user', message: { role: 'user', content: 'hello' } }]);
    const p = payload({ transcript_path: t });
    assertQuietPassThrough(await runHook(HOOK, p));
  } finally { rmTmp(dir); }
});

test('an unrelated schema\'s mismatch whose attempt was NOT this wrapped shape never seeds a rewrite', async () => {
  // Vet PoC (2026-09-02): the previous attempt was a different schema that
  // happened to fail on the same key names. The current call may be a
  // legitimate lone-`input` schema; leave it alone.
  const dir = mkTmp('so-unwrap-');
  try {
    const t = transcriptWith(dir, [use('t1', { verdict: 'x' }), result('t1', MISMATCH)]);
    const p = payload({ transcript_path: t });
    assertQuietPassThrough(await runHook(HOOK, p));
  } finally { rmTmp(dir); }
});

test('a successful attempt after an older mismatch means the current call is not a retry', async () => {
  const dir = mkTmp('so-unwrap-');
  try {
    const t = transcriptWith(dir, [
      use('t1', WRAPPED), result('t1', MISMATCH),
      use('t2', WRAPPED), result('t2', 'Structured output recorded.'),
    ]);
    const p = payload({ transcript_path: t });
    assertQuietPassThrough(await runHook(HOOK, p));
  } finally { rmTmp(dir); }
});

test('a prior wrapped attempt with DIFFERENT inner keys, or missing keys outside the wrapper, passes through', async () => {
  const dir = mkTmp('so-unwrap-');
  try {
    const t1 = transcriptWith(dir, [use('t1', { input: { refuted: false } }), result('t1', MISMATCH)], 'a.jsonl');
    const p1 = payload({ transcript_path: t1 });
    assertQuietPassThrough(await runHook(HOOK, p1));
    const t2 = transcriptWith(dir, [use('t1', WRAPPED),
      result('t1', "Output does not match required schema: root: must have required property 'findings'")], 'b.jsonl');
    const p2 = payload({ transcript_path: t2 });
    assertQuietPassThrough(await runHook(HOOK, p2));
  } finally { rmTmp(dir); }
});

test('a JSON-encoded string under input, and the {name, input} envelope, are wrappers too', async () => {
  // Measured 2026-09-02: a fleet of 14 agents each sent {input: "<JSON of the object>"} once.
  const dir = mkTmp('so-unwrap-');
  try {
    const asString = { input: JSON.stringify({ refuted: false, reasoning: 'holds' }) };
    const t1 = transcriptWith(dir, [use('t1', asString), result('t1', MISMATCH)], 'a.jsonl');
    const r1 = await runHook(HOOK, payload({ transcript_path: t1,
      tool_input: { input: JSON.stringify({ refuted: false, reasoning: 'holds, retried' }) } }));
    assert.deepStrictEqual(JSON.parse(r1.stdout).hookSpecificOutput.updatedInput,
      { refuted: false, reasoning: 'holds, retried' });

    const envelope = { name: 'StructuredOutput', input: { refuted: false, reasoning: 'holds' } };
    const t2 = transcriptWith(dir, [use('t1', envelope), result('t1', MISMATCH)], 'b.jsonl');
    const r2 = await runHook(HOOK, payload({ transcript_path: t2,
      tool_input: { name: 'StructuredOutput', input: { refuted: false, reasoning: 'holds, retried' } } }));
    assert.deepStrictEqual(JSON.parse(r2.stdout).hookSpecificOutput.updatedInput,
      { refuted: false, reasoning: 'holds, retried' });

    // Prose under input is not a wrapper: nothing to unwrap, pass through.
    const prose = { input: 'the claim holds because two is even' };
    const t3 = transcriptWith(dir, [use('t1', prose), result('t1', MISMATCH)], 'c.jsonl');
    const p3 = payload({ transcript_path: t3, tool_input: prose });
    assertQuietPassThrough(await runHook(HOOK, p3));
  } finally { rmTmp(dir); }
});

test('a missing or malformed transcript fails open', async () => {
  const dir = mkTmp('so-unwrap-');
  try {
    const p1 = payload({ transcript_path: path.join(dir, 'nope.jsonl') });
    assertQuietPassThrough(await runHook(HOOK, p1));
    const bad = path.join(dir, 'bad.jsonl');
    fs.writeFileSync(bad, '{not json StructuredOutput tool_result does not match required schema\n');
    const p2 = payload({ transcript_path: bad });
    assertQuietPassThrough(await runHook(HOOK, p2));
  } finally { rmTmp(dir); }
});

test('other tools and other shapes are never touched', async () => {
  const dir = mkTmp('so-unwrap-');
  try {
    const t = transcriptWith(dir, [use('t1', WRAPPED), result('t1', MISMATCH)]);
    const bash = payload({ transcript_path: t, tool_name: 'Bash', tool_input: { command: 'ls' } });
    assertQuietPassThrough(await runHook(HOOK, bash));
    const twoKeys = payload({ transcript_path: t, tool_input: { input: { refuted: true }, extra: 1 } });
    assertQuietPassThrough(await runHook(HOOK, twoKeys));
    const stringInner = payload({ transcript_path: t, tool_input: { input: 'prose' } });
    assertQuietPassThrough(await runHook(HOOK, stringInner));
  } finally { rmTmp(dir); }
});

test('inside a subagent, the agent-<id> transcript under the session\'s subagents tree is consulted', async () => {
  const dir = mkTmp('so-unwrap-');
  try {
    const session = transcriptWith(dir, [{ type: 'user', message: { role: 'user', content: 'parent has no attempt' } }]);
    transcriptWith(dir, [use('t1', WRAPPED), result('t1', MISMATCH)],
      path.join('session', 'subagents', 'workflows', 'wf_x', 'agent-abc.jsonl'));
    const res = await runHook(HOOK, payload({ transcript_path: session, agent_id: 'abc' }));
    const out = JSON.parse(res.stdout);
    assert.deepStrictEqual(out.hookSpecificOutput.updatedInput, { refuted: false, reasoning: 'holds, retried' });
  } finally { rmTmp(dir); }
});
