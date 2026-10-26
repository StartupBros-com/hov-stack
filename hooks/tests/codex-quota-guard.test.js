'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { decisionOf, assertPreToolUseDeny, assertPassThrough, assertQuietPassThrough, runHook } = require('./lib/harness');
const { run, evaluateUsage } = require('../PreToolUse/codex-quota-guard');
const resolver = require('../lib/codex-model-resolver');

const payload = (command) => ({
  session_id: 'quota-guard-test',
  cwd: '/tmp/project',
  tool_name: 'Bash',
  tool_input: { command },
});

async function withCheck(command, result, calls = { count: 0 }) {
  const input = payload(command);
  const raw = JSON.stringify(input);
  const out = await run(raw, {
    checkQuota: async () => {
      calls.count += 1;
      return result;
    },
  });
  return {
    input,
    raw,
    out,
    res: { code: 0, stdout: out, stderr: '' },
    calls,
  };
}

test('non-codex commands bypass the quota query', async () => {
  const result = await withCheck('ls -la', { ok: true, blocked: true });
  assert.strictEqual(result.calls.count, 0);
  assertPassThrough(result.res, result.input);
});

test('recovery and quoted diagnostic commands bypass the quota query', async () => {
  for (const command of [
    'codex login',
    'caam activate codex work',
    'echo "codex exec --profile auto"',
    'grep -R "codex exec" scripts/',
  ]) {
    const result = await withCheck(command, { ok: true, blocked: true });
    assert.strictEqual(result.calls.count, 0, command);
    assertPassThrough(result.res, result.input);
  }
});

test('shell-wrapped and plugin Codex invocations still query quota', async () => {
  for (const command of [
    'bash -c "codex exec --profile auto ship"',
    'node "/plugin/scripts/codex-companion.mjs" review',
    'node /plugin/scripts/app-server-broker.mjs serve',
  ]) {
    const result = await withCheck(command, { ok: true, blocked: false });
    assert.strictEqual(result.calls.count, 1, command);
    assertPassThrough(result.res, result.input);
  }
});

test('weekly 100% with allowed=true remains available (incident regression)', async () => {
  const usage = evaluateUsage({
    rate_limit: {
      allowed: true,
      limit_reached: false,
      primary_window: {
        used_percent: 100,
        limit_window_seconds: 604800,
        reset_at: 1788272156,
      },
      secondary_window: null,
    },
  });
  assert.deepStrictEqual(usage, { ok: true, blocked: false });

  const result = await withCheck('codex exec "ship it"', usage);
  assert.strictEqual(result.calls.count, 1);
  assertPassThrough(result.res, result.input);
});

test('explicit allowed=false denies a codex spend', async () => {
  const result = await withCheck('codex exec "ship it"', {
    ok: true,
    blocked: true,
  });
  assert.strictEqual(decisionOf(result.res), 'block');
  assertPreToolUseDeny(result.res);
});

test('explicit limit_reached=true denies a codex spend', async () => {
  assert.deepStrictEqual(
    evaluateUsage({ rate_limit: { allowed: true, limit_reached: true } }),
    { ok: true, blocked: true },
  );
});

test('percentage-only and unfamiliar schemas fail open', async () => {
  for (const body of [
    { rate_limit: { primary_window: { used_percent: 100 } } },
    { rate_limit: null },
    {},
    null,
  ]) {
    assert.deepStrictEqual(evaluateUsage(body), { ok: false, blocked: false });
  }
});

test('auth/network/schema uncertainty fails open', async () => {
  const result = await withCheck('codex review --base main', {
    ok: false,
    blocked: false,
  });
  assert.strictEqual(result.calls.count, 1);
  assertPassThrough(result.res, result.input);
});

test('malformed hook input passes through', async () => {
  assert.strictEqual(await run('not-json{{{'), 'not-json{{{');
});

// ---------------------------------------------------------------------------
// dotfiles issue 991: rewrite instead of deny. Fixtures are field-faithful copies of
// the live usage/catalog payloads probed 2026-09-04.
// ---------------------------------------------------------------------------

const FIX = path.join(__dirname, 'fixtures', 'codex');
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(FIX, name), 'utf8'));
const CATALOG = fixture('catalog.json').models;
const SPARK_OPEN = fixture('usage-exhausted-spark-open.json');
const ALL_OUT = fixture('usage-exhausted-all.json');
const HEALTHY = fixture('usage-healthy.json');
const SPARK = 'gpt-5.3-codex-spark';

async function withUsage(command, usage, { catalog = CATALOG, env = {}, toolInput = {} } = {}) {
  const input = { ...payload(command), tool_input: { command, ...toolInput } };
  const raw = JSON.stringify(input);
  const calls = { quota: 0, catalog: 0 };
  const out = await run(raw, {
    checkQuota: async () => { calls.quota += 1; return { ...resolver.evaluateUsage(usage), usage }; },
    env,
    resolverDeps: {
      listAccounts: () => [{ name: 'active', authPath: '/nonexistent', execPrefix: null }],
      readAuth: () => ({ token: 't', account: 'a' }),
      loadCatalog: async () => { calls.catalog += 1; return { models: catalog, fetchedAt: '2026-09-04T23:00:00.000Z', source: 'fixture' }; },
    },
  });
  return { input, raw, out, res: { code: 0, stdout: out, stderr: '' }, calls };
}

test('issue 991 AC1: account limit_reached, Spark open → updatedInput carries -m and the reason names the rewrite', async () => {
  const r = await withUsage("codex exec --profile auto 'Reply OK'", SPARK_OPEN);
  const out = JSON.parse(r.out);
  assert.strictEqual(decisionOf(r.res), null, 'no deny, no allow: the rewritten input flows through normal evaluation');
  assert.strictEqual(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, `codex exec -m ${SPARK} --profile auto 'Reply OK'`);
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /rewritten to run on the best model/);
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /"model":"gpt-5\.3-codex-spark"/);
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /"reason":"fallback"/);
  assert.strictEqual('permissionDecision' in out.hookSpecificOutput, false);
  assert.strictEqual('additionalContext' in out.hookSpecificOutput, false);
  assert.strictEqual(r.calls.catalog, 1);
});

test('issue 991: updatedInput replaces tool_input wholesale, so the other fields survive', async () => {
  const r = await withUsage('codex exec p', SPARK_OPEN, { toolInput: { description: 'Ask Codex', timeout: 600000 } });
  const out = JSON.parse(r.out);
  assert.deepStrictEqual(out.hookSpecificOutput.updatedInput, {
    command: `codex exec -m ${SPARK} p`,
    description: 'Ask Codex',
    timeout: 600000,
  });
});

test('issue 991 AC2: Spark out too, no API key → deny; banked-reset line iff available_count > 0', async () => {
  const none = await withUsage('codex exec p', ALL_OUT);
  assert.strictEqual(decisionOf(none.res), 'block');
  assertPreToolUseDeny(none.res);
  const noneReason = JSON.parse(none.out).hookSpecificOutput.permissionDecisionReason;
  assert.ok(!noneReason.includes('banked reset'), noneReason);
  assert.match(noneReason, /"reason":"exhausted"/);

  const banked = JSON.parse(JSON.stringify(ALL_OUT));
  banked.rate_limit_reset_credits.available_count = 1;
  const one = await withUsage('codex exec p', banked);
  assert.strictEqual(decisionOf(one.res), 'block');
  assert.match(JSON.parse(one.out).hookSpecificOutput.permissionDecisionReason, /banked reset is available at chatgpt\.com\/codex\/settings\/usage/);
});

test('issue 991 AC3: healthy account → output byte-identical to today\'s, and no catalog fetch', async () => {
  const r = await withUsage("codex exec 'Reply OK'", HEALTHY);
  assert.strictEqual(r.out, r.raw);
  assertPassThrough(r.res, r.input);
  assert.strictEqual(r.calls.quota, 1);
  assert.strictEqual(r.calls.catalog, 0);
});

test('issue 991 AC4: a command already carrying -m for a still-open model is untouched', async () => {
  const r = await withUsage(`codex exec -m ${SPARK} -c model_reasoning_effort=high p`, SPARK_OPEN);
  assert.strictEqual(r.out, r.raw);
  assertPassThrough(r.res, r.input);
});

test('issue 991 AC5: requested xhigh on a fallback that stops at high → rewritten to high', async () => {
  const capped = JSON.parse(JSON.stringify(CATALOG));
  capped.find((m) => m.slug === SPARK).supported_reasoning_levels = [{ effort: 'low' }, { effort: 'medium' }, { effort: 'high' }];
  const r = await withUsage("codex exec -m gpt-5.6-luna -c 'model_reasoning_effort=\"xhigh\"' p", SPARK_OPEN, { catalog: capped });
  const out = JSON.parse(r.out);
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, `codex exec -m ${SPARK} -c model_reasoning_effort=high p`);
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /"effort":"high"/);
});

test('issue 991: a wrapper the guard cannot rewrite still denies, and the denial names the open lane', async () => {
  const r = await withUsage('node /plugin/scripts/codex-companion.mjs review', SPARK_OPEN);
  assert.strictEqual(decisionOf(r.res), 'block');
  const reason = JSON.parse(r.out).hookSpecificOutput.permissionDecisionReason;
  assert.match(reason, /cannot be rewritten safely/);
  assert.match(reason, /codex exec … -m gpt-5\.3-codex-spark/);
});

test('issue 991: bash -c wrapped invocation is rewritten inside the payload', async () => {
  const r = await withUsage("bash -c \"codex exec -m gpt-5.6-luna 'p'\"", SPARK_OPEN);
  const out = JSON.parse(r.out);
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, `bash -c "codex exec -m ${SPARK} 'p'"`);
});

test('issue 991: API key in the environment is the last rung and is never echoed', async () => {
  const r = await withUsage('codex exec p', ALL_OUT, { env: { OPENAI_API_KEY: 'sk-secret', CODEX_PICK_API_LANE: '1' } });
  const out = JSON.parse(r.out);
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, 'codex exec -m gpt-5.6-sol -c preferred_auth_method=apikey p');
  assert.ok(!r.out.includes('sk-secret'));
});

test('issue 993: an ambient API key without the opt-in flag still denies (no API spend by default)', async () => {
  const r = await withUsage('codex exec p', ALL_OUT, { env: { OPENAI_API_KEY: 'sk-secret' } });
  assert.strictEqual(decisionOf(r.res), 'block');
  const reason = JSON.parse(r.out).hookSpecificOutput.permissionDecisionReason;
  assert.match(reason, /"reason":"exhausted"/);
  assert.ok(!reason.includes('apikey'), reason);
  assert.ok(!r.out.includes('sk-secret'));
});

test('issue 991: a blocked verdict without a usage body denies exactly as before (resolver never guesses)', async () => {
  const result = await withCheck('codex exec p', { ok: true, blocked: true });
  assert.strictEqual(decisionOf(result.res), 'block');
  const reason = JSON.parse(result.out).hookSpecificOutput.permissionDecisionReason;
  assert.ok(reason.startsWith('Codex quota is explicitly unavailable'), reason);
  assert.ok(!reason.includes('Receipt'), 'no receipt without a usage body');
});

test('issue 991: a resolver failure inside the exhausted path falls back to the plain denial', async () => {
  const input = payload('codex exec p');
  const out = await run(JSON.stringify(input), {
    checkQuota: async () => ({ ok: true, blocked: true, usage: SPARK_OPEN }),
    env: {},
    resolverDeps: { listAccounts: () => { throw new Error('boom'); } },
  });
  assert.strictEqual(decisionOf({ stdout: out }), 'block');
});

test('issue 991: the spawned hook with no readable auth fails open (black-box passthrough)', async () => {
  const input = payload('codex exec p');
  const res = await runHook('PreToolUse/codex-quota-guard.js', input, { env: { CODEX_HOME: '/nonexistent/codex-home' } });
  assert.strictEqual(res.code, 0);
  assertQuietPassThrough(res);
});
