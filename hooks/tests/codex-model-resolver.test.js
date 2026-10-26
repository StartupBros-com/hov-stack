'use strict';
/**
 * lib/codex-model-resolver: the pure selection and rewrite logic behind
 * codex-quota-guard's rewrite-instead-of-deny and the codex-pick CLI (issue 991).
 * Fixtures under fixtures/codex/ are field-faithful copies of the live
 * catalog and usage payloads probed 2026-09-04; the planted catalog puts an
 * unknown slug on top so name-keyed logic fails loudly.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
require('./lib/harness'); // sandbox HOME for this process
const R = require('../lib/codex-model-resolver');

const FIX = path.join(__dirname, 'fixtures', 'codex');
const load = (name) => JSON.parse(fs.readFileSync(path.join(FIX, name), 'utf8'));
const catalog = load('catalog.json').models;
const planted = load('catalog-planted.json').models;
const sparkOpen = load('usage-exhausted-spark-open.json');
const allOut = load('usage-exhausted-all.json');
const healthy = load('usage-healthy.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

const SPARK = 'gpt-5.3-codex-spark';
const SOL = 'gpt-5.6-sol';
const LUNA = 'gpt-5.6-luna';

/** Catalog variant: Spark stops at `high`, for the effort-clamp fixture. */
function sparkCappedAtHigh() {
  const c = clone(catalog);
  const spark = c.find((m) => m.slug === SPARK);
  spark.supported_reasoning_levels = [{ effort: 'low' }, { effort: 'medium' }, { effort: 'high' }];
  return c;
}

const ACTIVE = { name: 'active', authPath: '/nonexistent/active/auth.json', execPrefix: null };
const profile = (name) => ({ name, authPath: `/nonexistent/${name}/auth.json`, execPrefix: ['caam', 'exec', 'codex', name, '--no-lock', '--'] });

function deps(overrides = {}) {
  const calls = { catalog: 0, usage: [] };
  return {
    calls,
    listAccounts: () => [ACTIVE],
    readAuth: () => ({ token: 'fixture-token', account: 'fixture-account' }),
    loadCatalog: async () => { calls.catalog += 1; return { models: catalog, fetchedAt: '2026-09-04T23:00:00.000Z', source: 'fixture' }; },
    fetchUsage: async (auth) => { calls.usage.push(auth); return { ...R.evaluateUsage(sparkOpen), usage: sparkOpen }; },
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// usage semantics
// ---------------------------------------------------------------------------

test('rate-limit state is explicit-only: ok / blocked / uncertain', () => {
  assert.strictEqual(R.rateLimitState({ allowed: true, limit_reached: false }), 'ok');
  assert.strictEqual(R.rateLimitState({ allowed: false }), 'blocked');
  assert.strictEqual(R.rateLimitState({ limit_reached: true }), 'blocked');
  assert.strictEqual(R.rateLimitState({ primary_window: { used_percent: 100 } }), 'uncertain');
  assert.strictEqual(R.rateLimitState(null), 'uncertain');
  assert.strictEqual(R.rateLimitState([]), 'uncertain');
});

test('evaluateUsage keeps the pre-issue-991 verdict shape exactly', () => {
  assert.deepStrictEqual(R.evaluateUsage(healthy), { ok: true, blocked: false });
  assert.deepStrictEqual(R.evaluateUsage(sparkOpen), { ok: true, blocked: true });
  assert.deepStrictEqual(R.evaluateUsage({ rate_limit: { primary_window: { used_percent: 100 } } }), { ok: false, blocked: false });
  assert.deepStrictEqual(R.evaluateUsage({}), { ok: false, blocked: false });
  assert.deepStrictEqual(R.evaluateUsage(null), { ok: false, blocked: false });
});

test('a separately metered model reads its own meter; everything else reads the account meter', () => {
  const spark = catalog.find((m) => m.slug === SPARK);
  const luna = catalog.find((m) => m.slug === LUNA);
  assert.deepStrictEqual(R.availability(spark, sparkOpen), { separate: true, state: 'ok' });
  assert.deepStrictEqual(R.availability(luna, sparkOpen), { separate: false, state: 'blocked' });
  assert.deepStrictEqual(R.availability(spark, allOut), { separate: true, state: 'blocked' });
  assert.deepStrictEqual(R.availability(luna, healthy), { separate: false, state: 'ok' });
  assert.deepStrictEqual(R.availability(luna, null), { separate: false, state: 'uncertain' });
});

test('banked resets come from rate_limit_reset_credits.available_count only', () => {
  assert.strictEqual(R.bankedResets(sparkOpen), 1);
  assert.strictEqual(R.bankedResets(allOut), 0);
  assert.strictEqual(R.bankedResets({}), 0);
  assert.strictEqual(R.bankedResets({ rate_limit_reset_credits: { available_count: 'two' } }), 0);
});

// ---------------------------------------------------------------------------
// catalog semantics
// ---------------------------------------------------------------------------

test('candidates: hidden entries dropped, deprecations followed, sorted by priority', () => {
  const slugs = R.candidates(catalog, healthy).map((m) => m.slug);
  assert.deepStrictEqual(slugs, [SOL, 'gpt-5.6-terra', LUNA, 'gpt-daybreak-blue-latest', 'gpt-5.5', SPARK]);
  assert.ok(!slugs.includes('gpt-reserve'), 'visibility:hide is never a candidate even at priority 3');
  assert.ok(!slugs.includes('gpt-5.4-mini'), 'a deprecated entry is replaced by its upgrade target');
});

test('candidates on an exhausted account are exactly the separately metered open models', () => {
  assert.deepStrictEqual(R.candidates(catalog, sparkOpen).map((m) => m.slug), [SPARK]);
  assert.deepStrictEqual(R.candidates(catalog, allOut), []);
});

test('PLANTED NEGATIVE: an unknown top slug wins over a known slug that upgrades to it', () => {
  const slugs = R.candidates(planted, healthy).map((m) => m.slug);
  assert.strictEqual(slugs[0], 'gpt-zz-9-newname');
  assert.ok(!slugs.includes('gpt-hidden-top'), 'priority 1 but hidden: not a candidate');
  assert.ok(!slugs.includes(LUNA), 'the known slug collapses into its upgrade target');

  // Exhausted main window, both listed models separately metered and open:
  // the fallback must still be the unknown slug, never the familiar one.
  const usage = clone(allOut);
  usage.additional_rate_limits = [
    { limit_name: 'GPT-ZZ-9', rate_limit: { allowed: true, limit_reached: false } },
    { limit_name: 'GPT-5.6-Luna', rate_limit: { allowed: true, limit_reached: false } },
  ];
  const sel = R.selectModel({ catalog: planted, usage, requestedModel: null, requestedEffort: 'xhigh' });
  assert.strictEqual(sel.model, 'gpt-zz-9-newname');
  assert.strictEqual(sel.modelChanged, true);
  assert.strictEqual(sel.effort, 'high', 'xhigh clamped to the unknown model\'s ceiling');
  assert.strictEqual(sel.effortChanged, true);
});

test('a deprecated model that is itself still open stays when explicitly requested', () => {
  const usage = clone(allOut);
  usage.additional_rate_limits = [
    { limit_name: 'GPT-ZZ-9', rate_limit: { allowed: true, limit_reached: false } },
    { limit_name: 'GPT-5.6-Luna', rate_limit: { allowed: true, limit_reached: false } },
  ];
  const sel = R.selectModel({ catalog: planted, usage, requestedModel: LUNA, requestedEffort: null });
  assert.strictEqual(sel.reason, 'requested-available');
  assert.strictEqual(sel.model, LUNA);
  assert.strictEqual(sel.modelChanged, false);
});

// ---------------------------------------------------------------------------
// effort
// ---------------------------------------------------------------------------

test('clampEffort walks down to the nearest supported level', () => {
  assert.strictEqual(R.clampEffort('xhigh', ['low', 'medium', 'high']), 'high');
  assert.strictEqual(R.clampEffort('ultra', ['low', 'medium', 'high', 'xhigh', 'max']), 'max');
  assert.strictEqual(R.clampEffort('high', ['low', 'medium', 'high', 'xhigh']), 'high');
  assert.strictEqual(R.clampEffort('medium', ['high', 'xhigh']), 'high', 'everything supported is above: lowest supported');
  assert.strictEqual(R.clampEffort('bogus', ['low', 'high']), null, 'unknown level names clamp to nothing');
  assert.strictEqual(R.clampEffort(null, ['low']), null);
  assert.strictEqual(R.clampEffort('high', []), null);
});

test('pickEffort: catalog default when nothing requested, request kept when supported, clamped otherwise', () => {
  const spark = catalog.find((m) => m.slug === SPARK);
  assert.deepStrictEqual(R.pickEffort(null, spark), { effort: 'high', changed: false, source: 'catalog-default' });
  assert.deepStrictEqual(R.pickEffort('xhigh', spark), { effort: 'xhigh', changed: false, source: 'requested' });
  const capped = sparkCappedAtHigh().find((m) => m.slug === SPARK);
  assert.deepStrictEqual(R.pickEffort('xhigh', capped), { effort: 'high', changed: true, source: 'clamped' });
  assert.deepStrictEqual(R.pickEffort('xhigh', { slug: 'x' }), { effort: 'xhigh', changed: false, source: 'requested' }, 'no level list: keep the request');
});

// ---------------------------------------------------------------------------
// selection
// ---------------------------------------------------------------------------

test('selectModel: exhausted main window falls back to the open separately metered model', () => {
  const sel = R.selectModel({ catalog, usage: sparkOpen, requestedModel: null, requestedEffort: null });
  assert.deepStrictEqual(sel, { model: SPARK, priority: 26, modelChanged: true, effort: 'high', effortChanged: false, effortSource: 'catalog-default', reason: 'fallback' });
  const fromLuna = R.selectModel({ catalog, usage: sparkOpen, requestedModel: LUNA, requestedEffort: 'xhigh' });
  assert.strictEqual(fromLuna.model, SPARK);
  assert.strictEqual(fromLuna.effort, 'xhigh', 'Spark supports xhigh: the request survives the model change');
  assert.strictEqual(fromLuna.effortChanged, false);
});

test('selectModel: the requested model on an open meter is kept', () => {
  const sel = R.selectModel({ catalog, usage: sparkOpen, requestedModel: SPARK, requestedEffort: 'xhigh' });
  assert.strictEqual(sel.reason, 'requested-available');
  assert.strictEqual(sel.modelChanged, false);
  assert.strictEqual(sel.effortChanged, false);
});

test('selectModel: effort clamps when the fallback model stops lower than the request', () => {
  const sel = R.selectModel({ catalog: sparkCappedAtHigh(), usage: sparkOpen, requestedModel: LUNA, requestedEffort: 'xhigh' });
  assert.strictEqual(sel.model, SPARK);
  assert.strictEqual(sel.effort, 'high');
  assert.strictEqual(sel.effortChanged, true);
});

test('selectModel: a kept model still clamps an effort it cannot serve (review finding)', () => {
  const sel = R.selectModel({ catalog, usage: sparkOpen, requestedModel: SPARK, requestedEffort: 'ultra' });
  assert.strictEqual(sel.reason, 'requested-available');
  assert.strictEqual(sel.modelChanged, false);
  assert.strictEqual(sel.effort, 'xhigh', 'Spark stops at xhigh');
  assert.strictEqual(sel.effortChanged, true);
});

test('resolve: a kept model with an unservable effort is rewritten for the effort only', async () => {
  const r = await R.resolve({ command: `codex exec -m ${SPARK} -c model_reasoning_effort=ultra p`, usage: sparkOpen, env: {}, deps: deps() });
  assert.strictEqual(r.reason, 'requested-available');
  assert.strictEqual(r.changed, true);
  assert.strictEqual(r.rewrite, `codex exec -m ${SPARK} -c model_reasoning_effort=xhigh p`);
});

test('a bare `--` ends option parsing: a -m after it is prompt text, never a flag (review finding)', () => {
  const p = R.parseCommand("codex exec -- explain the -m flag in this script");
  assert.strictEqual(p.requestedModel, null);
  assert.strictEqual(
    R.rewriteCommand('codex exec -- explain the -m flag in this script', { model: SPARK }),
    `codex exec -m ${SPARK} -- explain the -m flag in this script`,
  );
  assert.strictEqual(
    R.rewriteCommand('codex exec -m gpt-5.6-luna -- explain the --model flag', { model: SPARK }),
    `codex exec -m ${SPARK} -- explain the --model flag`,
  );
  assert.deepStrictEqual(R.rewriteArgv(['codex', 'exec', '--', 'explain', '-m', 'flag'], { model: SPARK }),
    ['codex', 'exec', '-m', SPARK, '--', 'explain', '-m', 'flag']);
});

test('selectModel: everything out returns null', () => {
  assert.strictEqual(R.selectModel({ catalog, usage: allOut, requestedModel: null, requestedEffort: null }), null);
  assert.strictEqual(R.selectModel({ catalog, usage: allOut, requestedModel: SPARK, requestedEffort: null }), null);
});

test('selectModel: healthy account with no request decides nothing; an unknown requested slug is left alone', () => {
  assert.strictEqual(R.selectModel({ catalog, usage: healthy, requestedModel: null, requestedEffort: 'high' }).reason, 'healthy');
  const unknown = R.selectModel({ catalog, usage: healthy, requestedModel: 'gpt-not-in-catalog', requestedEffort: null });
  assert.strictEqual(unknown.reason, 'requested-unknown');
  assert.strictEqual(unknown.modelChanged, false);
});

test('selectModel: healthy account but the requested separately metered model is out → best main-meter model', () => {
  const usage = clone(healthy);
  usage.additional_rate_limits[0].rate_limit = { allowed: false, limit_reached: true };
  const sel = R.selectModel({ catalog, usage, requestedModel: SPARK, requestedEffort: 'xhigh' });
  assert.strictEqual(sel.model, SOL);
  assert.strictEqual(sel.modelChanged, true);
  assert.strictEqual(sel.effort, 'xhigh');
});

test('apiCandidate: best listed supported_in_api model; Spark (not API-capable) is never it', () => {
  const only = clone(catalog).filter((m) => m.slug === SPARK || m.slug === 'gpt-reserve');
  assert.strictEqual(R.apiCandidate(only, null, null), null);
  const sel = R.apiCandidate(catalog, null, 'xhigh');
  assert.strictEqual(sel.model, SOL);
  assert.strictEqual(sel.reason, 'api-key');
  assert.strictEqual(R.apiCandidate(catalog, LUNA, null).model, LUNA, 'a requested API-capable model is kept');
});

// ---------------------------------------------------------------------------
// command parsing
// ---------------------------------------------------------------------------

test('parseCommand finds direct invocations and reads every model/effort flag spelling', () => {
  const cases = [
    ["codex exec --profile auto 'Reply OK'", null, null],
    ["cd /x && codex exec -m gpt-5.6-luna -c 'model_reasoning_effort=\"xhigh\"' 'p'", LUNA, 'xhigh'],
    ['codex exec --model=gpt-5.5 p', 'gpt-5.5', null],
    ['codex exec -c model="gpt-5.5" p', 'gpt-5.5', null],
    ['codex exec --config=model_reasoning_effort=high p', null, 'high'],
    ['codex exec --config "model_reasoning_effort=\\"medium\\"" p', null, 'medium'],
    ['/home/user/.local/bin/codex e -m gpt-5.6-terra p', 'gpt-5.6-terra', null],
    ['timeout 600 codex review --base main -m gpt-5.6-sol', SOL, null],
    ['env -u OPENAI_API_KEY codex exec -s read-only "p"', null, null],
    ["bash -c \"codex exec -m gpt-5.6-luna 'p'\"", LUNA, null],
    ["bash -lc 'codex exec -c model_reasoning_effort=xhigh \"p\"'", null, 'xhigh'],
  ];
  for (const [cmd, model, effort] of cases) {
    const p = R.parseCommand(cmd);
    assert.ok(p, cmd);
    assert.strictEqual(p.requestedModel, model, cmd);
    assert.strictEqual(p.requestedEffort, effort, cmd);
  }
});

test('parseCommand ignores quoted mentions, recovery commands, and wrappers it cannot see into', () => {
  for (const cmd of [
    'echo "codex exec --profile auto"',
    "grep -R 'codex exec' scripts/",
    'codex login',
    'caam activate codex work',
    'node /plugin/scripts/codex-companion.mjs review',
    'caam exec codex work -- exec p',
    'codex mcp-server',
    "codex exec 'unterminated",
  ]) {
    assert.strictEqual(R.parseCommand(cmd), null, cmd);
  }
});

test('parseCommand marks expansions in model/effort flags as opaque', () => {
  const p = R.parseCommand('codex exec -m "$MODEL" p');
  assert.strictEqual(p.opaque, true);
  assert.strictEqual(p.requestedModel, null);
  const q = R.parseCommand('codex exec -m $(pick) p');
  assert.strictEqual(q.opaque, true);
});

test('heredoc bodies are prompt text, not invocations', () => {
  const cmd = "codex exec - <<'EOF'\ncodex exec -m gpt-5.6-luna 'inner'\nEOF\necho done";
  const p = R.parseCommand(cmd);
  assert.strictEqual(p.invocations.length, 1);
  assert.strictEqual(p.requestedModel, null, 'the -m inside the heredoc is never read');
  const out = R.rewriteCommand(cmd, { model: SPARK });
  assert.strictEqual(out, `codex exec -m ${SPARK} - <<'EOF'\ncodex exec -m gpt-5.6-luna 'inner'\nEOF\necho done`);
});

// ---------------------------------------------------------------------------
// command rewriting
// ---------------------------------------------------------------------------

test('rewriteCommand inserts -m after the subcommand when the request had no model', () => {
  assert.strictEqual(
    R.rewriteCommand("codex exec --profile auto 'Reply OK'", { model: SPARK }),
    `codex exec -m ${SPARK} --profile auto 'Reply OK'`,
  );
  assert.strictEqual(
    R.rewriteCommand('cd /w && codex exec - < brief.md', { model: SPARK, effort: 'high' }),
    `cd /w && codex exec -m ${SPARK} -c model_reasoning_effort=high - < brief.md`,
  );
});

test('rewriteCommand replaces every model and effort spelling in place', () => {
  const cases = [
    ["codex exec -m gpt-5.6-luna -c 'model_reasoning_effort=\"xhigh\"' 'p'", { model: SPARK, effort: 'high' }, `codex exec -m ${SPARK} -c model_reasoning_effort=high 'p'`],
    ['codex exec --model=gpt-5.6-luna p', { model: SPARK }, `codex exec --model=${SPARK} p`],
    ['codex exec --model=gpt-5.6-luna p', { model: SPARK, effort: 'high' }, `codex exec -c model_reasoning_effort=high --model=${SPARK} p`],
    ['codex exec -c model="gpt-5.6-luna" p', { model: SPARK }, `codex exec -c model=${SPARK} p`],
    ['codex exec --config=model_reasoning_effort=xhigh p', { model: SPARK, effort: 'high' }, `codex exec -m ${SPARK} --config=model_reasoning_effort=high p`],
    ['codex exec --model gpt-5.6-luna --config model_reasoning_effort="xhigh" p', { model: SPARK, effort: 'high' }, `codex exec --model ${SPARK} --config model_reasoning_effort=high p`],
  ];
  for (const [cmd, plan, want] of cases) {
    assert.strictEqual(R.rewriteCommand(cmd, plan), want, cmd);
  }
});

test('rewriteCommand leaves effort alone when the plan does not change it', () => {
  assert.strictEqual(
    R.rewriteCommand("codex exec -m gpt-5.6-luna -c 'model_reasoning_effort=\"xhigh\"' p", { model: SPARK }),
    `codex exec -m ${SPARK} -c 'model_reasoning_effort="xhigh"' p`,
  );
});

test('rewriteCommand rewrites inside a bash -c wrapper and re-quotes losslessly', () => {
  assert.strictEqual(
    R.rewriteCommand("bash -c \"codex exec -m gpt-5.6-luna 'p'\"", { model: SPARK }),
    `bash -c "codex exec -m ${SPARK} 'p'"`,
  );
  assert.strictEqual(
    R.rewriteCommand("bash -lc 'codex exec \"say hi\"'", { model: SPARK }),
    `bash -lc 'codex exec -m ${SPARK} "say hi"'`,
  );
  assert.strictEqual(
    R.rewriteCommand("bash -c \"codex exec \\\"quoted\\\" p\"", { model: SPARK }),
    `bash -c "codex exec -m ${SPARK} \\"quoted\\" p"`,
  );
});

test('rewriteCommand refuses shapes it cannot rewrite safely', () => {
  for (const cmd of [
    'codex exec -m "$MODEL" p',
    'bash -c "codex exec $ARGS"',
    "bash -c 'codex exec -m gpt-5.6-luna it'\"'\"'s'",
    'node /plugin/scripts/codex-companion.mjs review',
    'echo "codex exec"',
  ]) {
    assert.strictEqual(R.rewriteCommand(cmd, { model: SPARK }), null, cmd);
  }
  assert.strictEqual(R.rewriteCommand('codex exec p', { model: 'bad slug; rm -rf' }), null, 'unsafe slug never reaches the shell');
  assert.strictEqual(R.rewriteCommand('codex exec p', { model: SPARK, effort: 'x y' }), null);
});

test('rewriteCommand applies the account prefix and extra config', () => {
  assert.strictEqual(
    R.rewriteCommand("codex exec 'p'", { model: SOL, execPrefix: ['caam', 'exec', 'codex', 'work', '--no-lock', '--'] }),
    `caam exec codex work --no-lock -- exec -m ${SOL} 'p'`,
  );
  assert.strictEqual(
    R.rewriteCommand('codex exec p', { model: SOL, extraConfig: [R.API_AUTH_CONFIG] }),
    `codex exec -m ${SOL} -c preferred_auth_method=apikey p`,
  );
  assert.strictEqual(
    R.rewriteCommand('codex exec -c preferred_auth_method=chatgpt p', { model: SOL, extraConfig: [R.API_AUTH_CONFIG] }),
    `codex exec -m ${SOL} -c preferred_auth_method=apikey p`,
  );
});

test('rewriteCommand handles several invocations in one command', () => {
  assert.strictEqual(
    R.rewriteCommand('codex exec a; codex exec -m gpt-5.6-luna b && echo ok', { model: SPARK }),
    `codex exec -m ${SPARK} a; codex exec -m ${SPARK} b && echo ok`,
  );
});

test('argv twin mirrors the string rewriter', () => {
  assert.deepStrictEqual(R.rewriteArgv(['codex', 'exec', '-m', LUNA, '-c', 'model_reasoning_effort="xhigh"', 'p'], { model: SPARK, effort: 'high' }),
    ['codex', 'exec', '-m', SPARK, '-c', 'model_reasoning_effort=high', 'p']);
  assert.deepStrictEqual(R.rewriteArgv(['codex', 'exec', 'p'], { model: SPARK, effort: 'high', execPrefix: ['caam', 'exec', 'codex', 'w', '--no-lock', '--'] }),
    ['caam', 'exec', 'codex', 'w', '--no-lock', '--', 'exec', '-m', SPARK, '-c', 'model_reasoning_effort=high', 'p']);
  assert.strictEqual(R.rewriteArgv(['node', 'x.mjs'], { model: SPARK }), null);
  assert.deepStrictEqual(R.parseArgv(['codex', 'exec', '--model=gpt-5.5', 'p']).requestedModel, 'gpt-5.5');
});

// ---------------------------------------------------------------------------
// resolve(): the rungs
// ---------------------------------------------------------------------------

test('resolve: exhausted account with Spark open rewrites to Spark on the active account', async () => {
  const d = deps();
  const r = await R.resolve({ command: "codex exec --profile auto 'Reply OK'", usage: sparkOpen, env: {}, deps: d });
  assert.strictEqual(r.reason, 'fallback');
  assert.strictEqual(r.account, 'active');
  assert.strictEqual(r.model, SPARK);
  assert.strictEqual(r.effort, 'high');
  assert.strictEqual(r.priority, 26);
  assert.strictEqual(r.changed, true);
  assert.strictEqual(r.banked_resets, 1);
  assert.strictEqual(r.catalog_fetched_at, '2026-09-04T23:00:00.000Z');
  assert.strictEqual(r.rewrite, `codex exec -m ${SPARK} --profile auto 'Reply OK'`);
  assert.deepStrictEqual(d.calls.usage, [], 'the caller supplied usage; nothing refetched');
});

test('resolve: healthy account fetches no catalog and changes nothing', async () => {
  const d = deps();
  const r = await R.resolve({ command: "codex exec 'Reply OK'", usage: healthy, env: {}, deps: d });
  assert.strictEqual(r.reason, 'healthy');
  assert.strictEqual(r.changed, false);
  assert.strictEqual(r.rewrite, null);
  assert.strictEqual(d.calls.catalog, 0);
});

test('resolve: everything out, no other account, no key → exhausted; banked reset named only when one exists', async () => {
  const none = await R.resolve({ command: 'codex exec p', usage: allOut, env: {}, deps: deps() });
  assert.strictEqual(none.reason, 'exhausted');
  assert.strictEqual(none.changed, false);
  assert.strictEqual(none.banked_resets, 0);
  assert.ok(!none.note.includes('banked reset'), none.note);

  const banked = clone(allOut);
  banked.rate_limit_reset_credits.available_count = 1;
  const one = await R.resolve({ command: 'codex exec p', usage: banked, env: {}, deps: deps() });
  assert.strictEqual(one.reason, 'exhausted');
  assert.strictEqual(one.banked_resets, 1);
  assert.ok(one.note.includes(R.BANKED_RESET_HINT), one.note);
});

test('resolve: a requested model on an open meter is reported available and left unchanged', async () => {
  const r = await R.resolve({ command: `codex exec -m ${SPARK} p`, usage: sparkOpen, env: {}, deps: deps() });
  assert.strictEqual(r.reason, 'requested-available');
  assert.strictEqual(r.changed, false);
  assert.strictEqual(r.rewrite, null);
});

test('resolve: another caam profile verified open takes the run, with the requested model kept when it can be', async () => {
  const usageFor = { active: allOut, work: healthy };
  const d = deps({
    listAccounts: () => [ACTIVE, profile('work')],
    readAuth: (p) => ({ token: p, account: 'x' }),
    fetchUsage: async (auth) => {
      const name = auth.token.includes('/work/') ? 'work' : 'active';
      d.calls.usage.push(name);
      return { ...R.evaluateUsage(usageFor[name]), usage: usageFor[name] };
    },
  });
  const r = await R.resolve({ command: "codex exec -m gpt-5.6-luna 'p'", usage: allOut, env: {}, deps: d });
  assert.strictEqual(r.reason, 'account-fallback');
  assert.strictEqual(r.account, 'work');
  assert.strictEqual(r.model, LUNA);
  assert.strictEqual(r.changed, true);
  assert.strictEqual(r.rewrite, `caam exec codex work --no-lock -- exec -m ${LUNA} 'p'`);
  assert.deepStrictEqual(d.calls.usage, ['work']);

  const noModel = await R.resolve({ command: "codex exec 'p'", usage: allOut, env: {}, deps: d });
  assert.strictEqual(noModel.model, SOL, 'no -m: the other account\'s best model is pinned explicitly');
  assert.strictEqual(noModel.rewrite, `caam exec codex work --no-lock -- exec -m ${SOL} 'p'`);
});

test('resolve: a profile whose usage is uncertain or exhausted is never a rung (issue 993 planted negative)', async () => {
  const d = deps({
    listAccounts: () => [ACTIVE, profile('stale'), profile('spent')],
    readAuth: (p) => (p.includes('/stale/') ? null : { token: p, account: 'x' }),
    fetchUsage: async () => ({ ok: true, blocked: true, usage: allOut }),
  });
  const r = await R.resolve({ command: 'codex exec p', usage: allOut, env: {}, deps: d });
  assert.strictEqual(r.reason, 'exhausted');
  assert.deepStrictEqual(r.accounts_skipped, ['stale: no usable auth', 'spent: exhausted']);

  const uncertain = deps({
    listAccounts: () => [ACTIVE, profile('flaky')],
    fetchUsage: async () => ({ ok: false, blocked: false, usage: null }),
  });
  const u = await R.resolve({ command: 'codex exec p', usage: allOut, env: {}, deps: uncertain });
  assert.strictEqual(u.reason, 'exhausted');
  assert.deepStrictEqual(u.accounts_skipped, ['flaky: usage uncertain']);
});

test('resolve: the hook budget caps fallback accounts and says so (no silent cap)', async () => {
  const d = deps({
    listAccounts: () => [ACTIVE, profile('a'), profile('b'), profile('c')],
    fetchUsage: async (auth) => { d.calls.usage.push(auth.token); return { ok: true, blocked: true, usage: allOut }; },
  });
  const r = await R.resolve({ command: 'codex exec p', usage: allOut, env: {}, deps: d });
  assert.strictEqual(d.calls.usage.length, R.MAX_FALLBACK_ACCOUNTS);
  assert.ok(r.accounts_skipped.some((s) => s.startsWith('c: past the')), JSON.stringify(r.accounts_skipped));
});

test('resolve: an ambient API key alone never selects the API rung (no API spend without opt-in)', async () => {
  const keyOnly = await R.resolve({ command: 'codex exec p', usage: allOut, env: { OPENAI_API_KEY: 'sk-test' }, deps: deps() });
  assert.strictEqual(keyOnly.reason, 'exhausted');
  assert.strictEqual(keyOnly.rewrite, null);
  const flagOnly = await R.resolve({ command: 'codex exec p', usage: allOut, env: { CODEX_PICK_API_LANE: '1' }, deps: deps() });
  assert.strictEqual(flagOnly.reason, 'exhausted', 'the flag without a key resolves nothing');
  assert.strictEqual(R.apiLaneEnabled({ OPENAI_API_KEY: 'sk-test', CODEX_PICK_API_LANE: 'yes' }), false, 'only the literal 1 opts in');
  assert.strictEqual(R.apiLaneEnabled({ OPENAI_API_KEY: 'sk-test', CODEX_PICK_API_LANE: '1' }), true);
});

test('resolve: with the explicit opt-in, the API key is the last rung and pins the auth method', async () => {
  const withKey = await R.resolve({ command: "codex exec -c 'model_reasoning_effort=\"ultra\"' p", usage: allOut, env: { OPENAI_API_KEY: 'sk-test', CODEX_PICK_API_LANE: '1' }, deps: deps() });
  assert.strictEqual(withKey.reason, 'api-key');
  assert.strictEqual(withKey.account, 'api-key');
  assert.strictEqual(withKey.model, SOL);
  assert.strictEqual(withKey.effort, 'ultra', 'sol supports ultra');
  assert.strictEqual(withKey.rewrite, `codex exec -m ${SOL} -c preferred_auth_method=apikey -c 'model_reasoning_effort="ultra"' p`);
  assert.ok(!JSON.stringify(withKey).includes('sk-test'), 'the key never enters the receipt');

  const blank = await R.resolve({ command: 'codex exec p', usage: allOut, env: { OPENAI_API_KEY: '  ', CODEX_PICK_API_LANE: '1' }, deps: deps() });
  assert.strictEqual(blank.reason, 'exhausted');
});

test('resolve: no catalog on an exhausted account means no rewrite (fail open for the caller to decide)', async () => {
  const r = await R.resolve({ command: 'codex exec p', usage: sparkOpen, env: {}, deps: deps({ loadCatalog: async () => null }) });
  assert.strictEqual(r.reason, 'no-catalog');
  assert.strictEqual(r.changed, false);
});

test('resolve: uncertainty on the active account is reported, never acted on', async () => {
  const noAuth = await R.resolve({ command: 'codex exec p', env: {}, deps: deps({ readAuth: () => null }) });
  assert.strictEqual(noAuth.reason, 'uncertain');
  const flaky = await R.resolve({ command: 'codex exec p', env: {}, deps: deps({ fetchUsage: async () => ({ ok: false, blocked: false, usage: null }) }) });
  assert.strictEqual(flaky.reason, 'uncertain');
  assert.strictEqual(flaky.changed, false);
});

test('resolve: a fallback exists but the command shape is unrewritable → reported, not rewritten', async () => {
  const r = await R.resolve({ command: 'node /plugin/scripts/codex-companion.mjs review', usage: sparkOpen, env: {}, deps: deps() });
  assert.strictEqual(r.changed, false);
  assert.strictEqual(r.rewrite, null);
  assert.ok(r.note.includes('cannot be rewritten safely'), r.note);
  assert.ok(r.note.includes(SPARK), r.note);
});

test('resolve: argv path returns a rewritten argv and the same receipt fields', async () => {
  const r = await R.resolve({ argv: ['codex', 'exec', '-c', 'model_reasoning_effort="xhigh"', 'p'], usage: sparkOpen, env: {}, deps: deps({ loadCatalog: async () => ({ models: sparkCappedAtHigh(), fetchedAt: 'x', source: 'fixture' }) }) });
  assert.strictEqual(r.model, SPARK);
  assert.strictEqual(r.effort, 'high');
  assert.deepStrictEqual(r.argv, ['codex', 'exec', '-m', SPARK, '-c', 'model_reasoning_effort=high', 'p']);
  assert.strictEqual(r.rewrite, `codex exec -m ${SPARK} -c model_reasoning_effort=high p`);
});

// ---------------------------------------------------------------------------
// catalog cache + account discovery (filesystem, sandboxed HOME)
// ---------------------------------------------------------------------------

test('catalog cache is reused only while fresh, and Codex\'s file is never written', async () => {
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'codex-cat-'));
  try {
    const cachePath = path.join(dir, 'models_cache.json');
    const fetchedAt = '2026-09-04T08:52:18.707198406Z';
    fs.writeFileSync(cachePath, JSON.stringify({ fetched_at: fetchedAt, client_version: '0.147.0', models: catalog }));
    const before = fs.statSync(cachePath).mtimeMs;
    const fresh = await R.loadCatalog({ auth: null, nowMs: Date.parse(fetchedAt) + 60_000, deps: { catalogCachePath: cachePath } });
    assert.strictEqual(fresh.source, 'cache');
    assert.strictEqual(fresh.models.length, catalog.length);

    let fetched = 0;
    const live = await R.loadCatalog({
      auth: { token: 't', account: 'a' },
      nowMs: Date.parse(fetchedAt) + R.CATALOG_CACHE_MAX_AGE_MS + 1,
      deps: { catalogCachePath: cachePath, clientVersion: '0.147.0', httpGetJson: async (url) => { fetched += 1; assert.ok(url.includes('client_version=0.147.0')); return { ok: true, status: 200, json: { models: planted } }; } },
    });
    assert.strictEqual(live.source, 'live');
    assert.strictEqual(fetched, 1);
    assert.strictEqual(live.models[0].slug, 'gpt-zz-9-newname');

    const stale = await R.loadCatalog({
      auth: { token: 't', account: 'a' },
      nowMs: Date.parse(fetchedAt) + R.CATALOG_CACHE_MAX_AGE_MS + 1,
      deps: { catalogCachePath: cachePath, clientVersion: '0.147.0', httpGetJson: async () => ({ ok: false }) },
    });
    assert.strictEqual(stale.source, 'stale-cache', 'a stale cache beats no catalog');
    assert.strictEqual(fs.statSync(cachePath).mtimeMs, before, 'never written');
    assert.strictEqual(await R.loadCatalog({ auth: null, nowMs: 0, deps: { catalogCachePath: path.join(dir, 'missing.json') } }), null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('listAccounts: active first, then caam ISOLATED profiles with an auth.json; vault backups are not accounts', () => {
  const home = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'codex-acct-'));
  try {
    const env = { HOME: home, XDG_DATA_HOME: path.join(home, '.local', 'share') };
    const profiles = path.join(home, '.local', 'share', 'caam', 'profiles', 'codex');
    fs.mkdirSync(path.join(profiles, 'work', 'codex_home'), { recursive: true });
    fs.writeFileSync(path.join(profiles, 'work', 'codex_home', 'auth.json'), '{}');
    fs.mkdirSync(path.join(profiles, 'unlogged', 'codex_home'), { recursive: true });
    fs.mkdirSync(path.join(home, '.local', 'share', 'caam', 'vault', 'codex', 'backup'), { recursive: true });
    fs.writeFileSync(path.join(home, '.local', 'share', 'caam', 'vault', 'codex', 'backup', 'auth.json'), '{}');
    const accounts = R.listAccounts(env);
    assert.deepStrictEqual(accounts.map((a) => a.name), ['active', 'work']);
    assert.deepStrictEqual(accounts[1].execPrefix, ['caam', 'exec', 'codex', 'work', '--no-lock', '--']);
    assert.strictEqual(accounts[0].execPrefix, null);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('readAuth: token required, account id optional, garbage is null', () => {
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'codex-auth-'));
  try {
    const p = path.join(dir, 'auth.json');
    fs.writeFileSync(p, JSON.stringify({ tokens: { access_token: 'tok', account_id: 'acc' } }));
    assert.deepStrictEqual(R.readAuth(p), { token: 'tok', account: 'acc' });
    fs.writeFileSync(p, JSON.stringify({ tokens: { access_token: 'tok', chatgpt_account_id: 'c' } }));
    assert.deepStrictEqual(R.readAuth(p), { token: 'tok', account: 'c' });
    fs.writeFileSync(p, JSON.stringify({ tokens: {} }));
    assert.strictEqual(R.readAuth(p), null);
    fs.writeFileSync(p, 'nope');
    assert.strictEqual(R.readAuth(p), null);
    assert.strictEqual(R.readAuth(path.join(dir, 'missing.json')), null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
