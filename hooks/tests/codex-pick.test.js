'use strict';
/**
 * bin/codex-pick: the resolver as a CLI for paths that never pass
 * through the PreToolUse guard (issue 991). Black-box: spawn the real bin against
 * the same fixtures the guard suite uses and require the same receipt.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnNode } = require('./lib/harness');
const R = require('../lib/codex-model-resolver');

const BIN = path.resolve(__dirname, '..', '..', 'bin', 'codex-pick');
const FIX = path.join(__dirname, 'fixtures', 'codex');
const fixture = (name) => path.join(FIX, name);
const load = (name) => JSON.parse(fs.readFileSync(fixture(name), 'utf8'));
const SPARK = 'gpt-5.3-codex-spark';

const fixtureEnv = (usage, catalog = 'catalog.json') => ({
  CODEX_PICK_USAGE_FIXTURE: fixture(usage),
  CODEX_PICK_CATALOG_FIXTURE: fixture(catalog),
  CODEX_PICK_ACCOUNTS: 'none',
});

async function pick(argv, env) {
  const res = await spawnNode(BIN, { argv, env });
  return { ...res, json: res.stdout.trim() ? JSON.parse(res.stdout) : null };
}

/** The guard's view of the same fixture, through the shared resolver. */
async function guardReceipt(command, usageName, catalogName = 'catalog.json') {
  const usage = load(usageName);
  const models = load(catalogName).models;
  return R.resolve({
    command,
    usage,
    env: {},
    deps: {
      listAccounts: () => [{ name: 'active', authPath: '/nonexistent', execPrefix: null }],
      readAuth: () => ({ token: 't', account: 'a' }),
      loadCatalog: async () => ({ models, fetchedAt: 'fixture', source: 'fixture' }),
    },
  });
}

const compare = (r) => ({ account: r.account, model: r.model, effort: r.effort, priority: r.priority, reason: r.reason, changed: r.changed, banked_resets: r.banked_resets });

test('--version and --help resolve nothing and exit 0', async () => {
  const v = await spawnNode(BIN, { argv: ['--version'] });
  assert.strictEqual(v.code, 0);
  assert.match(v.stdout, /^codex-pick \d+\.\d+\.\d+\n$/);
  const h = await spawnNode(BIN, { argv: ['--help'] });
  assert.strictEqual(h.code, 0);
  assert.match(h.stdout, /^usage: codex-pick/);
  const bad = await spawnNode(BIN, { argv: ['--bogus'] });
  assert.strictEqual(bad.code, 2);
});

test('--json on the Spark-open fixture yields the guard\'s receipt', async () => {
  const cmd = ['codex', 'exec', '--profile', 'auto', 'Reply OK'];
  const cli = await pick(['--json', '--', ...cmd], fixtureEnv('usage-exhausted-spark-open.json'));
  assert.strictEqual(cli.code, 0, cli.stderr);
  const guard = await guardReceipt("codex exec --profile auto 'Reply OK'", 'usage-exhausted-spark-open.json');
  assert.deepStrictEqual(compare(cli.json), compare(guard));
  assert.strictEqual(cli.json.model, SPARK);
  assert.deepStrictEqual(cli.json.argv, ['codex', 'exec', '-m', SPARK, '--profile', 'auto', 'Reply OK']);
  assert.strictEqual(cli.json.rewrite, guard.rewrite);
});

test('--json on the everything-out fixture matches the guard: exhausted, no banked reset', async () => {
  const cli = await pick(['--json', '--', 'codex', 'exec', 'p'], fixtureEnv('usage-exhausted-all.json'));
  const guard = await guardReceipt('codex exec p', 'usage-exhausted-all.json');
  assert.deepStrictEqual(compare(cli.json), compare(guard));
  assert.strictEqual(cli.json.reason, 'exhausted');
});

test('--json on a healthy account: no rewrite, no catalog needed', async () => {
  const cli = await pick(['--json'], { CODEX_PICK_USAGE_FIXTURE: fixture('usage-healthy.json'), CODEX_PICK_ACCOUNTS: 'none' });
  assert.strictEqual(cli.code, 0, cli.stderr);
  assert.strictEqual(cli.json.reason, 'healthy');
  assert.strictEqual(cli.json.changed, false);
});

test('--json keeps a requested model whose meter is open, and clamps effort on a fallback', async () => {
  const kept = await pick(['--json', '--', 'codex', 'exec', '-m', SPARK, 'p'], fixtureEnv('usage-exhausted-spark-open.json'));
  assert.strictEqual(kept.json.reason, 'requested-available');
  assert.strictEqual(kept.json.changed, false);

  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'codex-pick-cat-'));
  try {
    const capped = load('catalog.json');
    capped.models.find((m) => m.slug === SPARK).supported_reasoning_levels = [{ effort: 'low' }, { effort: 'medium' }, { effort: 'high' }];
    const cappedPath = path.join(dir, 'capped.json');
    fs.writeFileSync(cappedPath, JSON.stringify(capped));
    const cli = await pick(['--json', '--', 'codex', 'exec', '-c', 'model_reasoning_effort="xhigh"', 'p'], {
      CODEX_PICK_USAGE_FIXTURE: fixture('usage-exhausted-spark-open.json'),
      CODEX_PICK_CATALOG_FIXTURE: cappedPath,
      CODEX_PICK_ACCOUNTS: 'none',
    });
    assert.strictEqual(cli.json.effort, 'high');
    assert.deepStrictEqual(cli.json.argv, ['codex', 'exec', '-m', SPARK, '-c', 'model_reasoning_effort=high', 'p']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('PLANTED NEGATIVE through the CLI: the unknown top slug is chosen', async () => {
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'codex-pick-planted-'));
  try {
    const usage = load('usage-exhausted-all.json');
    usage.additional_rate_limits = [
      { limit_name: 'GPT-ZZ-9', rate_limit: { allowed: true, limit_reached: false } },
      { limit_name: 'GPT-5.6-Luna', rate_limit: { allowed: true, limit_reached: false } },
    ];
    const usagePath = path.join(dir, 'usage.json');
    fs.writeFileSync(usagePath, JSON.stringify(usage));
    const cli = await pick(['--json', '--', 'codex', 'exec', 'p'], {
      CODEX_PICK_USAGE_FIXTURE: usagePath,
      CODEX_PICK_CATALOG_FIXTURE: fixture('catalog-planted.json'),
      CODEX_PICK_ACCOUNTS: 'none',
    });
    assert.strictEqual(cli.json.model, 'gpt-zz-9-newname');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('--exec runs the rewritten argv and propagates the child exit code; exhausted exits 3 without running', async () => {
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'codex-pick-exec-'));
  try {
    // A fake `codex` on PATH that records its argv and exits 7.
    const fake = path.join(dir, 'codex');
    const log = path.join(dir, 'argv.log');
    fs.writeFileSync(fake, `#!/bin/sh\nprintf '%s\\n' "$@" > '${log}'\nexit 7\n`);
    fs.chmodSync(fake, 0o755);
    const env = { ...fixtureEnv('usage-exhausted-spark-open.json'), PATH: `${dir}:${process.env.PATH}` };
    const ran = await spawnNode(BIN, { argv: ['--exec', '--', 'codex', 'exec', 'Reply OK'], env });
    assert.strictEqual(ran.code, 7, ran.stderr);
    assert.deepStrictEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['exec', '-m', SPARK, 'Reply OK']);
    assert.match(ran.stderr, /rewrote to gpt-5\.3-codex-spark/);

    fs.rmSync(log, { force: true });
    const out = await spawnNode(BIN, { argv: ['--exec', '--', 'codex', 'exec', 'p'], env: { ...env, CODEX_PICK_USAGE_FIXTURE: fixture('usage-exhausted-all.json') } });
    assert.strictEqual(out.code, 3);
    assert.strictEqual(fs.existsSync(log), false, 'nothing ran');
    assert.match(out.stderr, /exhausted/);

    const healthy = await spawnNode(BIN, { argv: ['--exec', '--', 'codex', 'exec', 'p'], env: { ...env, CODEX_PICK_USAGE_FIXTURE: fixture('usage-healthy.json') } });
    assert.strictEqual(healthy.code, 7);
    assert.deepStrictEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['exec', 'p'], 'healthy: unchanged argv');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the command after -- must be a direct codex invocation', async () => {
  const res = await spawnNode(BIN, { argv: ['--json', '--', 'node', 'companion.mjs'], env: fixtureEnv('usage-healthy.json') });
  assert.strictEqual(res.code, 2);
  const noCmd = await spawnNode(BIN, { argv: ['--exec'], env: fixtureEnv('usage-healthy.json') });
  assert.strictEqual(noCmd.code, 2);
});
