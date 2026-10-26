'use strict';
/**
 * The ccflare Codex-pool rung (dotfiles issue 1002): when the local account is
 * out, rewrite to better-ccflare's best Codex pool profile instead of a lesser
 * model, discovered live and ranked against the catalog by tier suffix.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runHook, spawnNode, decisionOf, assertQuietPassThrough } = require('./lib/harness');
const R = require('../lib/codex-model-resolver');
const { run } = require('../PreToolUse/codex-quota-guard');

const FIX = path.join(__dirname, 'fixtures', 'codex');
const load = (name) => JSON.parse(fs.readFileSync(path.join(FIX, name), 'utf8'));
const catalog = load('catalog.json').models;
const sparkOpen = load('usage-exhausted-spark-open.json');
const allOut = load('usage-exhausted-all.json');
const healthy = load('usage-healthy.json');
const cc = load('ccflare.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

// The fixture catalog predates Astra; add it so ranking has a real top tier.
const catalogWithAstra = [
  { slug: 'gpt-6-astra', display_name: 'GPT-6-Astra', priority: 1, visibility: 'list', upgrade: null, default_reasoning_level: 'medium', supported_in_api: true,
    supported_reasoning_levels: [{ effort: 'low' }, { effort: 'medium' }, { effort: 'high' }, { effort: 'xhigh' }, { effort: 'max' }, { effort: 'ultra' }] },
  ...catalog,
];
const ASTRA_POOL = 'claude-bccf-route-codex-pool-astra';
const SOL_POOL = 'claude-bccf-route-codex-pool-sol';
const SPARK = 'gpt-5.3-codex-spark';

const ACTIVE = { name: 'active', authPath: '/nonexistent/auth.json', execPrefix: null };
function deps(over = {}) {
  return {
    listAccounts: () => [ACTIVE],
    readAuth: () => ({ token: 't', account: 'a' }),
    loadCatalog: async () => ({ models: catalogWithAstra, fetchedAt: 'fixture', source: 'fixture' }),
    ccflarePool: async ({ catalog: c }) => R.rankCcflarePools(cc.models.data, cc.accounts, c),
    configModelProvider: () => null,
    ...over,
  };
}

test('rankCcflarePools: pools ranked by live catalog priority via the tier suffix; unknown tiers dropped; only codex accounts count', () => {
  const r = R.rankCcflarePools(cc.models.data, cc.accounts, catalogWithAstra);
  assert.deepStrictEqual(r.pools.map((p) => [p.profile, p.model, p.priority]), [
    [ASTRA_POOL, 'gpt-6-astra', 1],
    [SOL_POOL, 'gpt-5.6-sol', 6],
  ]);
  assert.deepStrictEqual(r.accounts.map((a) => [a.name, a.open]), [['acct-b', true], ['acct-d', false], ['acct-e', false]]);
  assert.deepStrictEqual(r.open, ['acct-b']);
  const noAstra = R.rankCcflarePools(cc.models.data, cc.accounts, catalog);
  assert.deepStrictEqual(noAstra.pools.map((p) => p.profile), [SOL_POOL], 'a pool whose tier the catalog no longer lists is not a candidate');
  assert.deepStrictEqual(R.rankCcflarePools([], [], catalogWithAstra), { pools: [], accounts: [], open: [] });
});

test('ccflareConfig reads Claude Code\'s live settings and never invents a key', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ccflare-cfg-'));
  try {
    assert.strictEqual(R.ccflareConfig({ CLAUDE_HOME: home }), null);
    fs.writeFileSync(path.join(home, 'settings.json'), JSON.stringify({ env: { ANTHROPIC_BASE_URL: 'http://127.0.0.1:8788/', ANTHROPIC_CUSTOM_HEADERS: 'x-api-key: btr-test' } }));
    assert.deepStrictEqual(R.ccflareConfig({ CLAUDE_HOME: home }), { base: 'http://127.0.0.1:8788', headerName: 'x-api-key', headerValue: 'btr-test' });
    fs.writeFileSync(path.join(home, 'settings.json'), JSON.stringify({ env: { ANTHROPIC_BASE_URL: 'http://127.0.0.1:8788' } }));
    assert.strictEqual(R.ccflareConfig({ CLAUDE_HOME: home }), null, 'no header, no config');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('ccflarePool skips cleanly when unconfigured or unreachable', async () => {
  assert.strictEqual(await R.ccflarePool({ env: {}, catalog: catalogWithAstra, deps: { ccflareConfig: () => null } }), null);
  const cfg = { base: 'http://127.0.0.1:1', headerName: 'x', headerValue: 'y' };
  assert.strictEqual(await R.ccflarePool({ env: {}, catalog: catalogWithAstra, deps: { ccflareConfig: () => cfg, ccflareGet: async () => ({ ok: false }) } }), null);
  const pool = await R.ccflarePool({ env: {}, catalog: catalogWithAstra, deps: { ccflareConfig: () => cfg, ccflareGet: async (_c, route) => ({ ok: true, status: 200, json: route === '/v1/models' ? cc.models : cc.accounts }) } });
  assert.strictEqual(pool.pools[0].profile, ASTRA_POOL);
});

test('resolve: exhausted account + open ccflare pool → rewrite to the Astra pool with the provider config, ahead of Spark', async () => {
  const r = await R.resolve({ command: "codex exec -m gpt-5.6-luna 'p'", usage: sparkOpen, env: {}, deps: deps() });
  assert.strictEqual(r.reason, 'ccflare-pool');
  assert.strictEqual(r.account, `ccflare:${ASTRA_POOL}`);
  assert.strictEqual(r.model, 'gpt-6-astra');
  assert.strictEqual(r.profile, ASTRA_POOL);
  assert.strictEqual(r.priority, 1);
  assert.strictEqual(r.changed, true);
  // The existing -m is replaced in place; only the provider flag is inserted, right after the subcommand.
  assert.strictEqual(r.rewrite, `codex exec -c model_provider=better_ccflare -m ${ASTRA_POOL} 'p'`);
  assert.deepStrictEqual(r.ccflare_pool.open, ['acct-b']);
  assert.ok(!JSON.stringify(r).includes('btr-'), 'no key material in the receipt');
});

test('resolve: the pool is taken even when nothing is open on the active account', async () => {
  const r = await R.resolve({ command: 'codex exec p', usage: allOut, env: {}, deps: deps() });
  assert.strictEqual(r.reason, 'ccflare-pool');
  assert.strictEqual(r.rewrite, `codex exec -m ${ASTRA_POOL} -c model_provider=better_ccflare p`);
});

test('resolve: effort is clamped to the pool model and an existing provider flag is replaced', async () => {
  const noUltra = clone(catalogWithAstra);
  noUltra[0].supported_reasoning_levels = [{ effort: 'low' }, { effort: 'medium' }, { effort: 'high' }, { effort: 'xhigh' }];
  const r = await R.resolve({
    command: 'codex exec -c model_provider=openai -c model_reasoning_effort=ultra p',
    usage: allOut, env: {},
    deps: deps({ loadCatalog: async () => ({ models: noUltra, fetchedAt: 'x', source: 'fixture' }) }),
  });
  assert.strictEqual(r.effort, 'xhigh');
  assert.strictEqual(r.rewrite, `codex exec -m ${ASTRA_POOL} -c model_provider=better_ccflare -c model_reasoning_effort=xhigh p`);
});

test('resolve: pool closed (no open codex account) → Spark on the active account; pool absent → Spark too', async () => {
  const closed = clone(cc);
  closed.accounts.forEach((a) => { if (a.provider === 'codex') a.rateLimitStatus = 'usage_exhausted (10m)'; });
  const r = await R.resolve({ command: 'codex exec p', usage: sparkOpen, env: {}, deps: deps({ ccflarePool: async ({ catalog: c }) => R.rankCcflarePools(closed.models.data, closed.accounts, c) }) });
  assert.strictEqual(r.reason, 'fallback');
  assert.strictEqual(r.model, SPARK);
  assert.deepStrictEqual(r.ccflare_pool.open, []);
  const none = await R.resolve({ command: 'codex exec p', usage: sparkOpen, env: {}, deps: deps({ ccflarePool: async () => null }) });
  assert.strictEqual(none.model, SPARK);
  assert.strictEqual(none.ccflare_pool, null);
  const throwing = await R.resolve({ command: 'codex exec p', usage: sparkOpen, env: {}, deps: deps({ ccflarePool: async () => { throw new Error('boom'); } }) });
  assert.strictEqual(throwing.model, SPARK, 'a broken pool lookup never blocks the other rungs');
});

test('resolve: the pool never outranks a requested model that is itself open, nor a healthy account', async () => {
  const kept = await R.resolve({ command: `codex exec -m ${SPARK} p`, usage: sparkOpen, env: {}, deps: deps() });
  assert.strictEqual(kept.reason, 'requested-available');
  assert.strictEqual(kept.changed, false);
  const ok = await R.resolve({ command: 'codex exec p', usage: healthy, env: {}, deps: deps() });
  assert.strictEqual(ok.reason, 'healthy');
});

test('resolve: pool closed and everything else out → exhausted, with the pool state in the receipt', async () => {
  const closed = clone(cc);
  closed.accounts.forEach((a) => { if (a.provider === 'codex') a.paused = true; });
  const r = await R.resolve({ command: 'codex exec p', usage: allOut, env: {}, deps: deps({ ccflarePool: async ({ catalog: c }) => R.rankCcflarePools(closed.models.data, closed.accounts, c) }) });
  assert.strictEqual(r.reason, 'exhausted');
  assert.deepStrictEqual(r.ccflare_pool.open, []);
});

test('argv path produces the same pool rewrite', async () => {
  const r = await R.resolve({ argv: ['codex', 'exec', '-m', 'gpt-5.6-luna', 'p'], usage: allOut, env: {}, deps: deps() });
  assert.deepStrictEqual(r.argv, ['codex', 'exec', '-c', 'model_provider=better_ccflare', '-m', ASTRA_POOL, 'p']);
});

test('usesCustomProvider: per-call flag, wrapped flag, or a top-level config key; never a provider table alone', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-cfg-'));
  try {
    const env = { CODEX_HOME: home };
    assert.strictEqual(R.usesCustomProvider('codex exec -c model_provider=better_ccflare p', env), true);
    assert.strictEqual(R.usesCustomProvider('bash -c "codex exec -c model_provider=better_ccflare p"', env), true);
    assert.strictEqual(R.usesCustomProvider('codex exec p', env), false, 'no config file: not custom');
    fs.writeFileSync(path.join(home, 'config.toml'), 'model = "gpt-6-astra"\n[model_providers.better_ccflare]\nbase_url = "http://127.0.0.1:8788/v1"\n');
    assert.strictEqual(R.configModelProvider(env), null, 'a provider TABLE is not a selection');
    assert.strictEqual(R.usesCustomProvider('codex exec p', env), false);
    fs.writeFileSync(path.join(home, 'config.toml'), 'model_provider = "better_ccflare"\nmodel = "x"\n[projects."/x"]\ntrust_level = "trusted"\n');
    assert.strictEqual(R.configModelProvider(env), 'better_ccflare');
    assert.strictEqual(R.usesCustomProvider('codex exec p', env), true);
    fs.writeFileSync(path.join(home, 'config.toml'), '[projects."/x"]\nmodel_provider = "better_ccflare"\n');
    assert.strictEqual(R.configModelProvider(env), null, 'a key inside a table is not top-level');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// the guard
// ---------------------------------------------------------------------------

const payload = (command) => ({ session_id: 'ccflare-pool-test', cwd: '/tmp/project', tool_name: 'Bash', tool_input: { command } });

test('guard: a run already sent to a custom provider passes through without a quota query', async () => {
  const input = payload('codex exec -c model_provider=better_ccflare -m claude-bccf-route-codex-pool-astra p');
  let quotaCalls = 0;
  const out = await run(JSON.stringify(input), { checkQuota: async () => { quotaCalls += 1; return { ok: true, blocked: true, usage: allOut }; }, env: {}, resolverDeps: { configModelProvider: () => null } });
  assert.strictEqual(out, JSON.stringify(input));
  assert.strictEqual(quotaCalls, 0);
  const byConfig = await run(JSON.stringify(payload('codex exec p')), { checkQuota: async () => { quotaCalls += 1; return { ok: true, blocked: true, usage: allOut }; }, env: {}, resolverDeps: { configModelProvider: () => 'better_ccflare' } });
  assert.strictEqual(JSON.parse(byConfig).tool_input.command, 'codex exec p');
  assert.strictEqual(quotaCalls, 0);
});

test('guard: exhaustion with an open ccflare pool → updatedInput names the pool profile and the provider', async () => {
  const input = payload("codex exec --profile auto 'Reply OK'");
  const out = await run(JSON.stringify(input), {
    checkQuota: async () => ({ ok: true, blocked: true, usage: sparkOpen }),
    env: {},
    resolverDeps: deps(),
  });
  const parsed = JSON.parse(out);
  assert.strictEqual(decisionOf({ stdout: out }), null);
  assert.strictEqual(parsed.hookSpecificOutput.updatedInput.command, `codex exec -m ${ASTRA_POOL} -c model_provider=better_ccflare --profile auto 'Reply OK'`);
  assert.match(parsed.hookSpecificOutput.permissionDecisionReason, /ccflare pool/);
  assert.match(parsed.hookSpecificOutput.permissionDecisionReason, /"model":"gpt-6-astra"/);
});

test('guard: pool closed → Spark rewrite as before; pool closed and Spark out → deny naming the pool state', async () => {
  const closed = clone(cc);
  closed.accounts.forEach((a) => { if (a.provider === 'codex') a.rateLimitStatus = 'usage_exhausted (1m)'; });
  const pool = async ({ catalog: c }) => R.rankCcflarePools(closed.models.data, closed.accounts, c);
  const spark = await run(JSON.stringify(payload('codex exec p')), { checkQuota: async () => ({ ok: true, blocked: true, usage: sparkOpen }), env: {}, resolverDeps: deps({ ccflarePool: pool }) });
  assert.strictEqual(JSON.parse(spark).hookSpecificOutput.updatedInput.command, `codex exec -m ${SPARK} p`);
  const deny = await run(JSON.stringify(payload('codex exec p')), { checkQuota: async () => ({ ok: true, blocked: true, usage: allOut }), env: {}, resolverDeps: deps({ ccflarePool: pool }) });
  assert.strictEqual(decisionOf({ stdout: deny }), 'block');
});

test('guard (spawned): no ccflare settings under the sandbox home → the rung is silently absent', async () => {
  const input = payload('codex exec p');
  const res = await runHook('PreToolUse/codex-quota-guard.js', input, { env: { CODEX_HOME: '/nonexistent/codex-home' } });
  assert.strictEqual(res.code, 0);
  assertQuietPassThrough(res);
});

// ---------------------------------------------------------------------------
// codex-pick parity
// ---------------------------------------------------------------------------

test('codex-pick --json with the ccflare fixture yields the same pool receipt as the guard', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-pick-cc-'));
  try {
    const catalogPath = path.join(dir, 'catalog.json');
    fs.writeFileSync(catalogPath, JSON.stringify({ models: catalogWithAstra }));
    const res = await spawnNode(path.resolve(__dirname, '..', '..', 'bin', 'codex-pick'), {
      argv: ['--json', '--', 'codex', 'exec', '-m', 'gpt-5.6-luna', 'p'],
      env: {
        CODEX_PICK_USAGE_FIXTURE: path.join(FIX, 'usage-exhausted-spark-open.json'),
        CODEX_PICK_CATALOG_FIXTURE: catalogPath,
        CODEX_PICK_CCFLARE_FIXTURE: path.join(FIX, 'ccflare.json'),
        CODEX_PICK_ACCOUNTS: 'none',
      },
    });
    assert.strictEqual(res.code, 0, res.stderr);
    const cli = JSON.parse(res.stdout);
    const guard = await R.resolve({ command: 'codex exec -m gpt-5.6-luna p', usage: sparkOpen, env: {}, deps: deps() });
    for (const k of ['account', 'model', 'profile', 'priority', 'reason', 'changed']) assert.strictEqual(cli[k], guard[k], k);
    assert.deepStrictEqual(cli.argv, ['codex', 'exec', '-c', 'model_provider=better_ccflare', '-m', ASTRA_POOL, 'p']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
