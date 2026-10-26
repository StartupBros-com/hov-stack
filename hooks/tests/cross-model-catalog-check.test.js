'use strict';
/**
 * cross-model-catalog-check: the standalone auditor behind harness-doctor's
 * check 33 (#1355 / #1356). Exercised in-process (pure functions, explicit
 * options — no env/HOME sandboxing needed beyond mkdtemp fixture dirs) the
 * same way codex-model-resolver.test.js covers its pure lib; the bash-level
 * fixtures cover the doctor's consumption of this script's JSON (WARN
 * wiring, floor accounting, the typed contract). This file pins the JSON
 * contract and the branches harness-doctor.sh cannot reach on its own
 * (schema shape, staleness and future boundaries, exclusive repo buckets
 * that always sum to repos.discovered, CE's peer-resolution rule).
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const C = require('../../scripts/cross-model-catalog-check.js');
const resolver = require('../lib/codex-model-resolver.js');

const SCRIPT_PATH = path.join(__dirname, '..', '..', 'scripts', 'cross-model-catalog-check.js');
const DAY_MS = 24 * 60 * 60 * 1000;
const NOW = Date.parse('2026-09-23T12:00:00.000Z');
const IS_ROOT = typeof process.getuid === 'function' && process.getuid() === 0;
const ROOT_SKIP = 'root bypasses file permission bits — no safe substitute exists for this case';

function mktemp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function isoDaysAgo(days, fromMs) {
  return new Date(fromMs - days * DAY_MS).toISOString();
}

// gpt-not-api is listed with supported_in_api: false. It stays selectable:
// that flag gates only the resolver's opt-in API-key lane (apiCandidate),
// never candidates()/selectModel, the OAuth lane the cross-model peer uses.
const CATALOG_MODELS = [
  { slug: 'gpt-6-astra', visibility: 'list', supported_in_api: true, priority: 1 },
  { slug: 'gpt-5.6-luna', visibility: 'list', supported_in_api: true, priority: 2 },
  { slug: 'gpt-hidden', visibility: 'hidden', supported_in_api: true, priority: 3 },
  { slug: 'gpt-not-api', visibility: 'list', supported_in_api: false, priority: 4 },
  { slug: 'gpt-old', visibility: 'list', supported_in_api: true, priority: 5, upgrade: { model: 'gpt-6-astra' } },
];

function writeCatalog(p, models, fetchedAt) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const body = { models };
  if (fetchedAt !== undefined) body.fetched_at = fetchedAt;
  fs.writeFileSync(p, JSON.stringify(body));
}

function writePluginScript(installPath, body) {
  const scriptPath = path.join(installPath, 'skills', 'ce-code-review', 'scripts', 'cross-model-adversarial-review.sh');
  fs.mkdirSync(path.dirname(scriptPath), { recursive: true });
  fs.writeFileSync(scriptPath, body);
  return scriptPath;
}

function writeRegistry(registryPath, entries) {
  fs.mkdirSync(path.dirname(registryPath), { recursive: true });
  fs.writeFileSync(registryPath, JSON.stringify({ plugins: { 'compound-engineering@every-marketplace': entries } }));
}

function ctxFor(registryPath) {
  return { registry: C.loadRegistry(registryPath), registryPath, scriptCache: new Map(), registryWarned: new Set() };
}

function writeConfig(repo, file, body) {
  fs.mkdirSync(path.join(repo, '.compound-engineering'), { recursive: true });
  fs.writeFileSync(path.join(repo, '.compound-engineering', file), body);
}

/** The exclusive-bucket invariant the doctor's jq contract also enforces. */
function assertCountsReconcile(result) {
  const r = result.repos;
  assert.strictEqual(r.checked + r.skipped_other_peer + r.skipped_no_plugin + r.unreadable, r.discovered, `buckets must sum to discovered: ${JSON.stringify(r)}`);
}

// ---------------------------------------------------------------------------
// parseArgs / resolveOptions
// ---------------------------------------------------------------------------

test('parseArgs: unknown flag and missing value both throw; known flags map through', () => {
  assert.throws(() => C.parseArgs(['--bogus']), /unrecognized flag: --bogus/);
  assert.throws(() => C.parseArgs(['--home']), /--home requires a value/);
  assert.deepStrictEqual(C.parseArgs(['--home', '/h', '--now', '2026-01-01T00:00:00Z']), { home: '/h', now: '2026-01-01T00:00:00Z' });
});

test('resolveOptions: derives every path from home unless a flag overrides it', () => {
  const opts = C.resolveOptions([], { HOME: '/h' });
  assert.strictEqual(opts.home, '/h');
  assert.strictEqual(opts.sitesRoot, path.join('/h', 'SITES'));
  assert.strictEqual(opts.dotfilesRepo, path.join('/h', 'dotfiles'));
  assert.strictEqual(opts.catalogPath, path.join('/h', '.codex', 'models_cache.json'));
  assert.strictEqual(opts.registryPath, path.join('/h', '.claude', 'plugins', 'installed_plugins.json'));
  assert.ok(Number.isFinite(opts.now) && opts.now <= Date.now());

  const overridden = C.resolveOptions(
    ['--home', '/h', '--sites-root', '/s', '--dotfiles-repo', '/d', '--catalog', '/c', '--registry', '/r', '--now', '2026-01-01T00:00:00.000Z'],
    { HOME: '/ignored' },
  );
  assert.strictEqual(overridden.sitesRoot, '/s');
  assert.strictEqual(overridden.dotfilesRepo, '/d');
  assert.strictEqual(overridden.catalogPath, '/c');
  assert.strictEqual(overridden.registryPath, '/r');
  assert.strictEqual(overridden.now, Date.parse('2026-01-01T00:00:00.000Z'));

  // env.DOTFILES_REPO wins over the home-derived default when no --dotfiles-repo flag is given.
  assert.strictEqual(C.resolveOptions([], { HOME: '/h', DOTFILES_REPO: '/env-dotfiles' }).dotfilesRepo, '/env-dotfiles');
});

test('resolveOptions: an unparseable --now is a usage error, never a NaN clock that reads every catalog as fresh', () => {
  assert.throws(() => C.resolveOptions(['--now', 'not-a-date'], { HOME: '/h' }), /--now is not a parseable timestamp: not-a-date/);
});

// ---------------------------------------------------------------------------
// ceKey — flat `key: value` scalar reader
// ---------------------------------------------------------------------------

test('ceKey: first active value wins, quotes are stripped, comments and comment-only lines are ignored', () => {
  const raw = [
    '# cross_model_peer: commented-out',
    'cross_model_peer: codex # trailing comment',
    'cross_model_peer: second-value-never-wins',
    'cross_model_model: "gpt-6-astra"',
  ].join('\n');
  assert.strictEqual(C.ceKey(raw, 'cross_model_peer'), 'codex');
  assert.strictEqual(C.ceKey(raw, 'cross_model_model'), 'gpt-6-astra');
  assert.strictEqual(C.ceKey(raw, 'missing_key'), '');
  assert.strictEqual(C.ceKey('cross_model_peer:   \n', 'cross_model_peer'), '', 'a blank value does not count as active — falls through');
});

// ---------------------------------------------------------------------------
// classifyCatalog — missing / unreadable / empty / stale / future / selectable
// ---------------------------------------------------------------------------

test('classifyCatalog: missing file', () => {
  const dir = mktemp('cm-cat-missing-');
  try {
    const r = C.classifyCatalog(path.join(dir, 'nope.json'), NOW);
    assert.strictEqual(r.state, 'missing');
    assert.strictEqual(r.findings.length, 1);
    assert.strictEqual(r.findings[0].code, 'catalog-missing');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: malformed JSON is unreadable, not missing', () => {
  const dir = mktemp('cm-cat-malformed-');
  try {
    const p = path.join(dir, 'models_cache.json');
    fs.writeFileSync(p, '{not valid json');
    const r = C.classifyCatalog(p, NOW);
    assert.strictEqual(r.state, 'unreadable');
    assert.strictEqual(r.findings[0].code, 'catalog-unreadable');
    assert.match(r.findings[0].message, /malformed JSON/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: a catalog under a directory without search permission is unreadable, not missing', (t) => {
  if (IS_ROOT) {
    t.skip(ROOT_SKIP);
    return;
  }
  const dir = mktemp('cm-cat-eacces-');
  const locked = path.join(dir, 'codex');
  try {
    writeCatalog(path.join(locked, 'models_cache.json'), CATALOG_MODELS, isoDaysAgo(0, NOW));
    fs.chmodSync(locked, 0o000);
    const r = C.classifyCatalog(path.join(locked, 'models_cache.json'), NOW);
    assert.strictEqual(r.state, 'unreadable');
    assert.match(r.findings[0].message, /\(EACCES\)/);
  } finally {
    fs.chmodSync(locked, 0o755);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: empty models array is distinguished from missing/unreadable', () => {
  const dir = mktemp('cm-cat-empty-');
  try {
    const p = path.join(dir, 'models_cache.json');
    writeCatalog(p, [], isoDaysAgo(0, NOW));
    const r = C.classifyCatalog(p, NOW);
    assert.strictEqual(r.state, 'empty');
    assert.strictEqual(r.findings[0].code, 'catalog-empty');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: no parseable fetched_at falls back to an mtime hint, never a fabricated age', () => {
  const dir = mktemp('cm-cat-nofetch-');
  try {
    const p = path.join(dir, 'models_cache.json');
    writeCatalog(p, CATALOG_MODELS); // no fetched_at key at all
    const r = C.classifyCatalog(p, NOW);
    assert.strictEqual(r.state, 'no-fetched-at');
    assert.strictEqual(r.ageDays, null);
    assert.strictEqual(r.findings[0].code, 'catalog-no-fetched-at');
    assert.match(r.findings[0].message, /mtime .* is a hint only/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: staleness boundary is >= 30 days, not > 30 — 29 is ok, 30 is stale', () => {
  const dir = mktemp('cm-cat-stale-');
  try {
    const fresh = path.join(dir, 'fresh.json');
    writeCatalog(fresh, CATALOG_MODELS, isoDaysAgo(29, NOW));
    const rFresh = C.classifyCatalog(fresh, NOW);
    assert.strictEqual(rFresh.state, 'ok', 'day 29 must not be flagged stale');
    assert.strictEqual(rFresh.ageDays, 29);
    assert.strictEqual(rFresh.findings.length, 0);

    const stale = path.join(dir, 'stale.json');
    writeCatalog(stale, CATALOG_MODELS, isoDaysAgo(30, NOW));
    const rStale = C.classifyCatalog(stale, NOW);
    assert.strictEqual(rStale.state, 'stale', 'day 30 must be flagged stale');
    assert.strictEqual(rStale.ageDays, 30);
    assert.strictEqual(rStale.findings[0].code, 'catalog-stale');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: a fetched_at in the future is its own state with no age, mirroring the resolver\'s freshness guard; exactly now is ok', () => {
  const dir = mktemp('cm-cat-future-');
  try {
    const future = path.join(dir, 'future.json');
    writeCatalog(future, CATALOG_MODELS, new Date(NOW + DAY_MS).toISOString());
    const r = C.classifyCatalog(future, NOW);
    assert.strictEqual(r.state, 'future');
    assert.strictEqual(r.ageDays, null, 'a negative age must never be reported');
    assert.strictEqual(r.findings.length, 1);
    assert.strictEqual(r.findings[0].code, 'catalog-future-fetched-at');
    assert.match(r.findings[0].message, /is in the future/);
    // The resolver itself refuses to call such a cache fresh.
    assert.strictEqual(resolver.readCatalogCache(future, NOW).fresh, false);

    const now = path.join(dir, 'now.json');
    writeCatalog(now, CATALOG_MODELS, new Date(NOW).toISOString());
    const rNow = C.classifyCatalog(now, NOW);
    assert.strictEqual(rNow.state, 'ok');
    assert.strictEqual(rNow.ageDays, 0);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: when readCatalogCache\'s own re-read returns null (the file changed between reads), fetched_at comes from the payload parsed here', () => {
  const dir = mktemp('cm-cat-reread-');
  const original = resolver.readCatalogCache;
  let calls = 0;
  try {
    const p = path.join(dir, 'models_cache.json');
    writeCatalog(p, CATALOG_MODELS, isoDaysAgo(3, NOW));
    resolver.readCatalogCache = () => {
      calls += 1;
      return null;
    };
    const r = C.classifyCatalog(p, NOW);
    assert.strictEqual(calls, 1, 'the auditor calls the shared resolver function (not a private copy)');
    assert.strictEqual(r.state, 'ok');
    assert.strictEqual(r.ageDays, 3);
    assert.deepStrictEqual(r.selectable, ['gpt-6-astra', 'gpt-5.6-luna', 'gpt-not-api', 'gpt-old']);
  } finally {
    resolver.readCatalogCache = original;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('classifyCatalog: explicit pins use availableListed; recommendations stay ranked and upgrade-deduplicated', () => {
  const dir = mktemp('cm-cat-select-');
  try {
    const p = path.join(dir, 'models_cache.json');
    writeCatalog(p, CATALOG_MODELS, isoDaysAgo(0, NOW));
    const r = C.classifyCatalog(p, NOW);
    assert.deepStrictEqual([...r.served].sort(), CATALOG_MODELS.map((m) => m.slug).sort());
    // Explicit gpt-old pins stay selectable despite their upgrade pointer.
    // gpt-hidden stays excluded; supported_in_api:false stays selectable.
    assert.deepStrictEqual(r.selectable, ['gpt-6-astra', 'gpt-5.6-luna', 'gpt-not-api', 'gpt-old']);
    assert.deepStrictEqual(r.selectable, resolver.availableListed(CATALOG_MODELS, { rate_limit: { allowed: true } }).map((m) => m.slug));
    assert.deepStrictEqual(r.selectableRanked.map((m) => m.slug), ['gpt-6-astra', 'gpt-5.6-luna', 'gpt-not-api']);

    // Catalog order and the old model's higher priority must not make it a
    // fallback recommendation: only the explicit-pin membership keeps it.
    const shuffled = [...CATALOG_MODELS].reverse().map((m) => m.slug === 'gpt-old' ? { ...m, priority: 0 } : m);
    writeCatalog(p, shuffled, isoDaysAgo(0, NOW));
    const reordered = C.classifyCatalog(p, NOW);
    assert.ok(reordered.selectable.includes('gpt-old'));
    assert.deepStrictEqual(reordered.selectableRanked.map((m) => m.slug), ['gpt-6-astra', 'gpt-5.6-luna', 'gpt-not-api']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// reasonNotSelectable
// ---------------------------------------------------------------------------

test('reasonNotSelectable: not-in-catalog, hidden (the resolver\'s own isListed), no reason for selectable pins', () => {
  const dir = mktemp('cm-reason-');
  try {
    const p = path.join(dir, 'models_cache.json');
    writeCatalog(p, CATALOG_MODELS, isoDaysAgo(0, NOW));
    const catalog = C.classifyCatalog(p, NOW);
    assert.strictEqual(C.reasonNotSelectable('ghost-model', catalog), 'not in the catalog payload');
    assert.strictEqual(C.reasonNotSelectable('gpt-hidden', catalog), 'hidden');
    assert.strictEqual(resolver.isListed(catalog.modelsBySlug.get('gpt-hidden')), false);
    assert.strictEqual(C.reasonNotSelectable('gpt-old', catalog), null);
    assert.strictEqual(C.reasonNotSelectable('gpt-not-api', catalog), null);
    assert.strictEqual(C.reasonNotSelectable('gpt-6-astra', catalog), null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// loadRegistry — missing vs malformed vs valid, and caching in loadPluginScript
// ---------------------------------------------------------------------------

test('loadRegistry: missing file, malformed JSON, and a valid registry are all distinguished', () => {
  const dir = mktemp('cm-registry-');
  try {
    assert.deepStrictEqual(C.loadRegistry(path.join(dir, 'nope.json')), { ok: false, reason: 'missing' });

    const malformed = path.join(dir, 'malformed.json');
    fs.writeFileSync(malformed, '{not valid json');
    assert.deepStrictEqual(C.loadRegistry(malformed), { ok: false, reason: 'unreadable' });

    const valid = path.join(dir, 'valid.json');
    const entries = [{ scope: 'user', version: '3.28.2', installPath: '/plugins/ce' }];
    fs.writeFileSync(valid, JSON.stringify({ plugins: { 'compound-engineering@every-marketplace': entries } }));
    assert.deepStrictEqual(C.loadRegistry(valid), { ok: true, entries });

    // Valid JSON, but the expected key path is absent/mis-shaped: ok:true, empty entries — not a parse failure.
    const noKey = path.join(dir, 'no-key.json');
    fs.writeFileSync(noKey, JSON.stringify({ plugins: {} }));
    assert.deepStrictEqual(C.loadRegistry(noKey), { ok: true, entries: [] });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadRegistry: a registry under a directory without search permission is unreadable, not missing', (t) => {
  if (IS_ROOT) {
    t.skip(ROOT_SKIP);
    return;
  }
  const dir = mktemp('cm-registry-eacces-');
  const locked = path.join(dir, 'plugins');
  try {
    writeRegistry(path.join(locked, 'installed_plugins.json'), []);
    fs.chmodSync(locked, 0o000);
    assert.deepStrictEqual(C.loadRegistry(path.join(locked, 'installed_plugins.json')), { ok: false, reason: 'unreadable' });
  } finally {
    fs.chmodSync(locked, 0o755);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadPluginScript: reads M_<PEER>= lines into peers and targets, caches by installPath, and names why a script cannot serve', () => {
  const dir = mktemp('cm-plugin-script-');
  try {
    const installPath = path.join(dir, 'plugin');
    const scriptPath = writePluginScript(installPath, '#!/usr/bin/env bash\nM_CODEX="gpt-6-astra"\nM_CLAUDE="opus"\nM_GROK_CURSOR="grok-x"\n');

    const cache = new Map();
    const first = C.loadPluginScript(installPath, cache);
    assert.strictEqual(first.ok, true);
    assert.strictEqual(first.reason, null);
    assert.strictEqual(first.peers.get('codex'), 'gpt-6-astra');
    assert.strictEqual(first.peers.get('claude'), 'opus');
    // M_GROK_CURSOR is grok's cursor route, so it contributes the target
    // 'grok', never 'grok_cursor'; cursor and opencode have no M_ line.
    assert.deepStrictEqual([...first.targets].sort(), ['claude', 'codex', 'cursor', 'grok', 'opencode']);

    fs.writeFileSync(scriptPath, '#!/usr/bin/env bash\n# no default line here\n');
    const second = C.loadPluginScript(installPath, cache);
    assert.strictEqual(second, first, 'same installPath returns the cached object, not a fresh read');

    const noCodex = C.loadPluginScript(installPath, new Map());
    assert.strictEqual(noCodex.ok, false);
    assert.strictEqual(noCodex.reason, 'no-codex-line');

    const missing = C.loadPluginScript(path.join(dir, 'missing-plugin'), new Map());
    assert.strictEqual(missing.ok, false);
    assert.strictEqual(missing.reason, 'unreadable');
    assert.strictEqual(missing.error, 'ENOENT');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// resolveApplicablePlugin — local > project > user, by exact realpath
// ---------------------------------------------------------------------------

test('resolveApplicablePlugin: a project-scoped entry matching the repo realpath beats the user-scoped default', () => {
  const dir = mktemp('cm-resolve-plugin-');
  try {
    const repo = path.join(dir, 'repo');
    fs.mkdirSync(repo, { recursive: true });
    const userInstall = path.join(dir, 'user-plugin');
    const projectInstall = path.join(dir, 'project-plugin');
    const alias = path.join(dir, 'repo-alias');
    fs.symlinkSync(repo, alias);
    writePluginScript(userInstall, 'M_CODEX="user-model"\n');
    writePluginScript(projectInstall, 'M_CODEX="project-model"\n');
    const registryPath = path.join(dir, 'installed_plugins.json');
    writeRegistry(registryPath, [
      { scope: 'user', version: '1.0.0', installPath: userInstall },
      { scope: 'project', version: '1.0.0', installPath: projectInstall, projectPath: alias },
    ]);

    const ctx = ctxFor(registryPath);
    const resolved = C.resolveApplicablePlugin(fs.realpathSync(repo), ctx);
    assert.strictEqual(resolved.ok, true);
    assert.strictEqual(resolved.entry.installPath, projectInstall);
    assert.strictEqual(resolved.script.peers.get('codex'), 'project-model');

    // A different repo (no project entry matches) falls back to the user entry.
    const otherRepo = path.join(dir, 'other-repo');
    fs.mkdirSync(otherRepo, { recursive: true });
    const fallback = C.resolveApplicablePlugin(fs.realpathSync(otherRepo), ctx);
    assert.strictEqual(fallback.entry.installPath, userInstall);

    // A registry with no applicable entry at all.
    const emptyRegistryPath = path.join(dir, 'empty-registry.json');
    writeRegistry(emptyRegistryPath, []);
    assert.deepStrictEqual(C.resolveApplicablePlugin(fs.realpathSync(repo), ctxFor(emptyRegistryPath)), { ok: false, reason: 'no-entry' });

    // A missing registry propagates its own reason unchanged.
    assert.deepStrictEqual(C.resolveApplicablePlugin(fs.realpathSync(repo), ctxFor(path.join(dir, 'nope.json'))), { ok: false, reason: 'missing' });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('resolveApplicablePlugin: matching local wins over project and user; another repo or child does not match', () => {
  const { opts } = buildHomeWithPlugin('M_CODEX="gpt-6-astra"\n');
  try {
    const repo = path.join(opts.sitesRoot, 'repo-a');
    const other = path.join(opts.sitesRoot, 'repo-b');
    const alias = path.join(opts.home, 'repo-alias');
    fs.symlinkSync(repo, alias);
    const localInstall = path.join(opts.home, 'local-plugin');
    const projectInstall = path.join(opts.home, 'project-plugin');
    writePluginScript(localInstall, 'M_CODEX="gpt-local-unserved"\n');
    writePluginScript(projectInstall, 'M_CODEX="gpt-5.6-luna"\n');
    const user = C.loadRegistry(opts.registryPath).entries[0];
    const project = { scope: 'project', version: '2.0.0', installPath: projectInstall, projectPath: alias };
    const local = { scope: 'local', version: '3.0.0', installPath: localInstall, projectPath: alias };
    const foreignLocal = { ...local, projectPath: path.join(opts.home, 'elsewhere'), installPath: '/must-not-read' };
    // Deliberately out of precedence order, with a nonmatching local first.
    writeRegistry(opts.registryPath, [foreignLocal, user, project, local]);
    const ctx = ctxFor(opts.registryPath);
    const resolved = C.resolveApplicablePlugin(fs.realpathSync(repo), ctx);
    assert.strictEqual(resolved.entry.scope, 'local');
    assert.strictEqual(resolved.script.peers.get('codex'), 'gpt-local-unserved');
    assert.strictEqual(C.resolveApplicablePlugin(fs.realpathSync(other), ctx).entry.scope, 'user');
    const child = path.join(repo, 'child');
    fs.mkdirSync(child);
    assert.strictEqual(C.resolveApplicablePlugin(fs.realpathSync(child), ctx).entry.scope, 'user', 'repo scope is exact, not a path prefix');

    writeRegistry(opts.registryPath, [foreignLocal, user, project]);
    assert.strictEqual(C.resolveApplicablePlugin(fs.realpathSync(repo), ctxFor(opts.registryPath)).entry.scope, 'project');
    writeRegistry(opts.registryPath, [local]);
    assert.strictEqual(C.resolveApplicablePlugin(fs.realpathSync(repo), ctxFor(opts.registryPath)).entry.scope, 'local', 'local-only installs are applicable');
    assert.deepStrictEqual(C.resolveApplicablePlugin(fs.realpathSync(other), ctxFor(opts.registryPath)), { ok: false, reason: 'no-entry' });
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// resolvePeer — CE's ordinary-key rule (finding #3, round 4)
// ---------------------------------------------------------------------------

/** A repo plus a user-scoped registry entry whose script has the given body. */
function peerFixture(prefix, scriptBody) {
  const dir = mktemp(prefix);
  const repo = path.join(dir, 'repo');
  fs.mkdirSync(repo, { recursive: true });
  const installPath = path.join(dir, 'plugin');
  const scriptPath = scriptBody === null ? null : writePluginScript(installPath, scriptBody);
  const registryPath = path.join(dir, 'installed_plugins.json');
  writeRegistry(registryPath, [{ scope: 'user', version: '1.0.0', installPath }]);
  return { dir, repo, real: fs.realpathSync(repo), scriptPath, ctx: ctxFor(registryPath) };
}

test('resolvePeer: explicit codex short-circuits, no plugin lookup needed', () => {
  const ctx = { registry: { ok: false, reason: 'missing' }, registryPath: '/nope', scriptCache: new Map(), registryWarned: new Set() };
  const r = C.resolvePeer('/repo', '/repo', [{ label: 'config.yaml', value: 'codex' }], ctx);
  assert.strictEqual(r.resolved, 'codex');
  assert.strictEqual(r.findings.length, 0);
});

test('resolvePeer: no peer set anywhere defaults to codex (fail-open on absence, not a finding)', () => {
  const ctx = { registry: { ok: false, reason: 'missing' }, registryPath: '/nope', scriptCache: new Map(), registryWarned: new Set() };
  const r = C.resolvePeer('/repo', '/repo', [{ label: 'config.local.yaml', value: '' }, { label: 'config.yaml', value: '' }], ctx);
  assert.strictEqual(r.resolved, 'codex');
  assert.strictEqual(r.findings.length, 0);
});

test('resolvePeer: an invalid peer is flagged and resolution continues — to the next layer, then to the codex default', () => {
  const f = peerFixture('cm-peer-invalid-', 'M_CODEX="gpt-6-astra"\n');
  try {
    const r = C.resolvePeer(f.repo, f.real, [
      { label: 'config.local.yaml', value: 'not-a-real-peer' },
      { label: 'config.yaml', value: 'codex' },
    ], f.ctx);
    assert.strictEqual(r.resolved, 'codex');
    assert.strictEqual(r.findings.length, 1);
    assert.strictEqual(r.findings[0].code, 'peer-invalid');
    assert.match(r.findings[0].message, /config\.local\.yaml sets cross_model_peer 'not-a-real-peer'/);

    // Invalid on every layer: each layer is named, then the skill default applies.
    const bothInvalid = C.resolvePeer(f.repo, f.real, [
      { label: 'config.local.yaml', value: 'not-a-real-peer' },
      { label: 'config.yaml', value: 'also-not-real' },
    ], f.ctx);
    assert.strictEqual(bothInvalid.resolved, 'codex');
    assert.strictEqual(bothInvalid.findings.length, 2);

    // Invalid upper layer, lower layer unset: the same default, not a stall.
    const invalidThenUnset = C.resolvePeer(f.repo, f.real, [
      { label: 'config.local.yaml', value: 'not-a-real-peer' },
      { label: 'config.yaml', value: '' },
    ], f.ctx);
    assert.strictEqual(invalidThenUnset.resolved, 'codex');
    assert.strictEqual(invalidThenUnset.findings.length, 1);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('resolvePeer: cursor and opencode (no M_ line) and grok (only an M_GROK_CURSOR line) are valid targets, not peer-invalid', () => {
  const f = peerFixture('cm-peer-targets-', 'M_CODEX="gpt-6-astra"\nM_GROK_CURSOR="grok-x"\n');
  try {
    for (const target of ['cursor', 'opencode', 'grok']) {
      const r = C.resolvePeer(f.repo, f.real, [{ label: 'config.yaml', value: target }], f.ctx);
      assert.strictEqual(r.resolved, target);
      assert.strictEqual(r.findings.length, 0, `${target} must not be flagged`);
    }
    const bogus = C.resolvePeer(f.repo, f.real, [{ label: 'config.yaml', value: 'grok_cursor' }], f.ctx);
    assert.strictEqual(bogus.resolved, 'codex', 'a route constant is not a target');
    assert.strictEqual(bogus.findings[0].code, 'peer-invalid');
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('resolvePeer: when no registry entry applies to the repo, a non-codex value is skipped as other-peer but named as unverified', () => {
  const dir = mktemp('cm-peer-noentry-');
  try {
    const repo = path.join(dir, 'repo');
    fs.mkdirSync(repo, { recursive: true });
    const registryPath = path.join(dir, 'installed_plugins.json');
    writeRegistry(registryPath, []);
    const r = C.resolvePeer(repo, fs.realpathSync(repo), [{ label: 'config.yaml', value: 'some-unverifiable-peer' }], ctxFor(registryPath));
    assert.strictEqual(r.resolved, 'some-unverifiable-peer');
    assert.strictEqual(r.findings.length, 1);
    assert.strictEqual(r.findings[0].code, 'peer-unverified');
    assert.match(r.findings[0].message, /which could not be validated: no compound-engineering entry in the plugin registry \(.*installed_plugins\.json\) applies to this repo — skipped as an other-peer repo/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('audit(): an unpinned codex repo with no applicable registry entry is named, never a silent no-plugin skip that lets the run read clean', () => {
  const opts = buildHome();
  try {
    // Only a project-scoped entry for some other project: no user-scope
    // fallback, so neither SITES repo has an applicable entry.
    writeRegistry(opts.registryPath, [{ scope: 'project', version: '1.0.0', installPath: path.join(opts.home, 'plugin'), projectPath: path.join(opts.home, 'elsewhere') }]);
    const result = C.audit(opts);
    const noEntry = result.findings.filter((f) => f.code === 'plugin-no-entry');
    assert.deepStrictEqual(noEntry.map((f) => path.basename(f.repo)).sort(), ['repo-a', 'repo-b']);
    assert.match(noEntry[0].message, /^repo-a: no compound-engineering entry in the plugin registry \(.*\) applies to this repo, so the plugin's codex default cannot be resolved — pin cross_model_model or install the plugin for this repo$/);
    assert.strictEqual(result.repos.skipped_no_plugin, 2);
    assert.strictEqual(result.repos.checked, 1, 'dotfiles has its own pin and needs no plugin entry');
    assert.strictEqual(result.findings.some((f) => f.code === 'registry-unreadable'), false, 'the registry itself is fine');
    assertCountsReconcile(result);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('resolvePeer: an applicable plugin whose script is unreadable or has no M_CODEX= line still skips the repo, but never silently', () => {
  const unreadable = peerFixture('cm-peer-script-missing-', null);
  const noCodex = peerFixture('cm-peer-script-nocodex-', '# no mapping lines\n');
  try {
    const r1 = C.resolvePeer(unreadable.repo, unreadable.real, [{ label: 'config.yaml', value: 'grok' }], unreadable.ctx);
    assert.strictEqual(r1.resolved, 'grok');
    assert.strictEqual(r1.findings.length, 1);
    assert.strictEqual(r1.findings[0].code, 'peer-unverified');
    assert.match(r1.findings[0].message, /cross_model_peer 'grok', which could not be validated: could not read the plugin script \(.*: ENOENT\) — skipped as an other-peer repo/);

    const r2 = C.resolvePeer(noCodex.repo, noCodex.real, [{ label: 'config.yaml', value: 'grok' }], noCodex.ctx);
    assert.strictEqual(r2.findings[0].code, 'peer-unverified');
    assert.match(r2.findings[0].message, /plugin script has no M_CODEX= line/);
  } finally {
    fs.rmSync(unreadable.dir, { recursive: true, force: true });
    fs.rmSync(noCodex.dir, { recursive: true, force: true });
  }
});

test('resolvePeer: a missing registry cannot validate a non-codex value; the registry finding fires once per run', () => {
  const ctx = { registry: { ok: false, reason: 'missing' }, registryPath: '/nope/installed_plugins.json', scriptCache: new Map(), registryWarned: new Set() };
  const first = C.resolvePeer('/a', '/a', [{ label: 'config.yaml', value: 'grok' }], ctx);
  const second = C.resolvePeer('/b', '/b', [{ label: 'config.yaml', value: 'claude' }], ctx);
  assert.strictEqual(first.resolved, 'grok');
  assert.strictEqual(second.resolved, 'claude');
  assert.strictEqual(first.findings.length, 1);
  assert.strictEqual(first.findings[0].code, 'registry-unreadable');
  assert.match(first.findings[0].message, /plugin registry missing: \/nope\/installed_plugins\.json — cross_model_peer values cannot be validated/);
  assert.strictEqual(second.findings.length, 0, 'deduped across repos');
});

// ---------------------------------------------------------------------------
// statState / readFileState / readDirState — absent vs unreadable, never conflated
// ---------------------------------------------------------------------------

test('readFileState: missing is not unreadable; a directory in a file\'s place is unreadable, not missing', () => {
  const dir = mktemp('cm-readfile-');
  try {
    const missing = C.readFileState(path.join(dir, 'nope.txt'));
    assert.deepStrictEqual(missing, { exists: false, readable: false, raw: '', error: null });

    const p = path.join(dir, 'file.txt');
    fs.writeFileSync(p, 'hello');
    const ok = C.readFileState(p);
    assert.deepStrictEqual(ok, { exists: true, readable: true, raw: 'hello', error: null });

    const dirAsFile = path.join(dir, 'a-directory');
    fs.mkdirSync(dirAsFile);
    const bad = C.readFileState(dirAsFile);
    assert.strictEqual(bad.exists, true);
    assert.strictEqual(bad.readable, false);
    assert.strictEqual(bad.error, 'EISDIR');

    // A path under a regular file (ENOTDIR) is absent: nothing can exist there.
    assert.deepStrictEqual(C.readFileState(path.join(p, 'child')), { exists: false, readable: false, raw: '', error: null });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('readDirState: missing is not unreadable; a plain file in a directory\'s place is unreadable, not missing', () => {
  const dir = mktemp('cm-readdir-');
  try {
    const missing = C.readDirState(path.join(dir, 'nope'));
    assert.deepStrictEqual(missing, { exists: false, readable: false, names: [], error: null });

    const sub = path.join(dir, 'sub');
    fs.mkdirSync(sub);
    fs.writeFileSync(path.join(sub, 'a'), '');
    const ok = C.readDirState(sub);
    assert.strictEqual(ok.exists, true);
    assert.strictEqual(ok.readable, true);
    assert.deepStrictEqual(ok.names, ['a']);

    const fileAsDir = path.join(dir, 'a-file');
    fs.writeFileSync(fileAsDir, 'x');
    const bad = C.readDirState(fileAsDir);
    assert.strictEqual(bad.exists, true);
    assert.strictEqual(bad.readable, false);
    assert.strictEqual(bad.error, 'ENOTDIR');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('readFileState / readDirState / statState: chmod 000 is EACCES-unreadable, on the path itself and on its parent — skipped as root', (t) => {
  if (IS_ROOT) {
    t.skip(ROOT_SKIP);
    return;
  }
  const dir = mktemp('cm-chmod-');
  const lockedDir = path.join(dir, 'locked-dir');
  try {
    const p = path.join(dir, 'locked.txt');
    fs.writeFileSync(p, 'secret');
    fs.chmodSync(p, 0o000);
    const fileState = C.readFileState(p);
    assert.strictEqual(fileState.exists, true);
    assert.strictEqual(fileState.readable, false);
    assert.strictEqual(fileState.error, 'EACCES');

    fs.mkdirSync(lockedDir);
    fs.writeFileSync(path.join(lockedDir, 'inside'), '');
    fs.chmodSync(lockedDir, 0o000);
    const dirState = C.readDirState(lockedDir);
    assert.strictEqual(dirState.exists, true);
    assert.strictEqual(dirState.readable, false);
    assert.strictEqual(dirState.error, 'EACCES');

    // The round-4 case: the parent denies search permission, so the child's
    // stat fails EACCES. That is "cannot tell", never "absent".
    assert.deepStrictEqual(C.statState(path.join(lockedDir, 'inside')), { st: null, absent: false, error: 'EACCES' });
    assert.deepStrictEqual(C.readFileState(path.join(lockedDir, 'inside')), { exists: true, readable: false, raw: '', error: 'EACCES' });
    assert.strictEqual(C.readDirState(path.join(lockedDir, 'nested')).error, 'EACCES');
  } finally {
    fs.chmodSync(lockedDir, 0o755); // restore so rmSync can clean up
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// audit() — end-to-end wiring: discovery, exclusive buckets, dedup
// ---------------------------------------------------------------------------

function buildHome() {
  const home = mktemp('cm-audit-home-');
  const dotfiles = path.join(home, 'dotfiles');
  writeConfig(dotfiles, 'config.yaml', 'cross_model_peer: codex\ncross_model_model: gpt-6-astra\n');

  const sitesRoot = path.join(home, 'SITES');
  // Two repos with a .compound-engineering dir but no own pin -> fall through
  // to the (missing) registry; a third has no .compound-engineering at all
  // and must not be discovered.
  fs.mkdirSync(path.join(sitesRoot, 'repo-a', '.compound-engineering'), { recursive: true });
  fs.mkdirSync(path.join(sitesRoot, 'repo-b', '.compound-engineering'), { recursive: true });
  fs.mkdirSync(path.join(sitesRoot, 'repo-c-not-ce'), { recursive: true });

  const catalogPath = path.join(home, '.codex', 'models_cache.json');
  writeCatalog(catalogPath, CATALOG_MODELS, isoDaysAgo(0, NOW));

  return {
    home, dotfilesRepo: dotfiles, sitesRoot, catalogPath,
    registryPath: path.join(home, '.claude', 'plugins', 'installed_plugins.json'), // not created: registry-missing
    now: NOW,
  };
}

/** buildHome plus a user-scoped registry entry whose script has the given body. */
function buildHomeWithPlugin(scriptBody) {
  const opts = buildHome();
  const installPath = path.join(opts.home, '.claude', 'plugins', 'cache', 'ce', '1.0.0');
  const scriptPath = scriptBody === null ? path.join(installPath, 'skills', 'ce-code-review', 'scripts', 'cross-model-adversarial-review.sh') : writePluginScript(installPath, scriptBody);
  writeRegistry(opts.registryPath, [{ scope: 'user', version: '1.0.0', installPath }]);
  return { opts, scriptPath };
}

test('audit(): schema shape is pinned — every top-level and nested key, nothing extra', () => {
  const opts = buildHome();
  try {
    const result = C.audit(opts);
    assert.deepStrictEqual(Object.keys(result).sort(), ['catalog', 'dotfiles', 'findings', 'repos'].sort());
    assert.deepStrictEqual(Object.keys(result.repos).sort(), ['checked', 'discovered', 'skipped_no_plugin', 'skipped_other_peer', 'unreadable'].sort());
    assert.deepStrictEqual(Object.keys(result.catalog).sort(), ['age_days', 'path', 'selectable', 'served', 'state'].sort());
    assert.deepStrictEqual(Object.keys(result.dotfiles).sort(), ['model', 'source'].sort());
    assert.ok(Array.isArray(result.findings));
    assertCountsReconcile(result);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

for (const kind of ['missing', 'regular-file', 'unreadable', 'unsearchable-parent']) {
  test(`audit(): required dotfiles path ${kind} is unreadable, never a checked plugin-default repo`, (t) => {
    const permissionCase = kind === 'unreadable' || kind === 'unsearchable-parent';
    if (permissionCase && IS_ROOT) {
      t.skip(ROOT_SKIP);
      return;
    }
    const { opts } = buildHomeWithPlugin('M_CODEX="gpt-6-astra"\n');
    let locked;
    try {
      opts.dotfilesRepo = path.join(opts.home, 'required-dotfiles');
      opts.sitesRoot = path.join(opts.home, 'no-sites');
      if (kind === 'regular-file') fs.writeFileSync(opts.dotfilesRepo, 'not a directory\n');
      if (kind === 'unreadable') {
        fs.mkdirSync(opts.dotfilesRepo);
        locked = opts.dotfilesRepo;
        fs.chmodSync(locked, 0o000);
      }
      if (kind === 'unsearchable-parent') {
        locked = path.join(opts.home, 'locked-parent');
        opts.dotfilesRepo = path.join(locked, 'required-dotfiles');
        fs.mkdirSync(opts.dotfilesRepo, { recursive: true });
        fs.chmodSync(locked, 0o000);
      }
      const result = C.audit(opts);
      assert.deepStrictEqual(result.repos, { checked: 0, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: 1, discovered: 1 });
      assertCountsReconcile(result);
      assert.deepStrictEqual(result.dotfiles, { model: null, source: 'dotfiles path unreadable' });
      assert.strictEqual(result.findings.length, 1);
      assert.strictEqual(result.findings[0].code, 'repo-unreadable');
      assert.strictEqual(result.findings[0].repo, opts.dotfilesRepo);
      assert.ok(result.findings[0].message.includes(opts.dotfilesRepo), 'name the actual required path');
      assert.match(result.findings[0].message, kind === 'missing' ? /required dotfiles directory is missing/ : kind === 'regular-file' ? /required dotfiles path is not a directory/ : /required dotfiles directory could not be read \(EACCES\)/);
    } finally {
      if (locked) fs.chmodSync(locked, 0o755);
      fs.rmSync(opts.home, { recursive: true, force: true });
    }
  });
}

test('audit(): a readable dotfiles directory without config still uses its served plugin default', () => {
  const { opts } = buildHomeWithPlugin('M_CODEX="gpt-5.6-luna"\n');
  try {
    opts.dotfilesRepo = path.join(opts.home, 'required-dotfiles');
    opts.sitesRoot = path.join(opts.home, 'no-sites');
    fs.mkdirSync(opts.dotfilesRepo);
    const result = C.audit(opts);
    assert.deepStrictEqual(result.findings, []);
    assert.deepStrictEqual(result.dotfiles, { model: 'gpt-5.6-luna', source: 'plugin-default 1.0.0' });
    assert.deepStrictEqual(result.repos, { checked: 1, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: 0, discovered: 1 });
    assertCountsReconcile(result);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): dotfiles resolves via its own config.yaml pin; both plugin-less SITES repos are skipped_no_plugin; the missing-registry finding fires once, not per repo', () => {
  const opts = buildHome();
  try {
    const result = C.audit(opts);
    assert.strictEqual(result.repos.checked, 1, 'dotfiles only');
    assert.strictEqual(result.repos.skipped_no_plugin, 2, 'repo-a and repo-b');
    assert.strictEqual(result.repos.skipped_other_peer, 0);
    assert.strictEqual(result.repos.unreadable, 0);
    assert.strictEqual(result.repos.discovered, 3, 'repo-c-not-ce has no .compound-engineering and is not discovered');
    assertCountsReconcile(result);
    assert.strictEqual(result.dotfiles.model, 'gpt-6-astra');
    assert.strictEqual(result.dotfiles.source, 'config.yaml');
    assert.strictEqual(result.catalog.state, 'ok');

    const registryFindings = result.findings.filter((f) => f.code === 'registry-unreadable');
    assert.strictEqual(registryFindings.length, 1, 'ctx.registryWarned dedups the shared missing-registry warning across repos');
    assert.match(registryFindings[0].message, /plugin registry missing:/);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): an unserved or hidden effective model is flagged; a supported_in_api:false model is not (planted negative)', () => {
  const opts = buildHome();
  const cfg = path.join(opts.dotfilesRepo, '.compound-engineering', 'config.yaml');
  try {
    fs.writeFileSync(cfg, 'cross_model_peer: codex\ncross_model_model: totally-unknown-slug\n');
    const unserved = C.audit(opts);
    assert.strictEqual(unserved.findings.some((f) => f.code === 'model-unserved'), true);
    assertCountsReconcile(unserved);

    fs.writeFileSync(cfg, 'cross_model_peer: codex\ncross_model_model: gpt-hidden\n');
    const hidden = C.audit(opts);
    const finding = hidden.findings.find((f) => f.code === 'model-not-selectable');
    assert.ok(finding);
    assert.match(finding.message, /is served but not selectable — hidden/);

    fs.writeFileSync(cfg, 'cross_model_peer: codex\ncross_model_model: gpt-not-api\n');
    const oauthSelectable = C.audit(opts);
    assert.strictEqual(oauthSelectable.findings.some((f) => f.repo === opts.dotfilesRepo), false, 'the OAuth lane can select it, so nothing is wrong');
    assert.strictEqual(oauthSelectable.dotfiles.model, 'gpt-not-api');
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): an explicit deprecated pin kept by selectModel is accepted, while fallback recommendations still follow upgrades', () => {
  const { opts } = buildHomeWithPlugin('M_CODEX="gpt-6-astra"\n');
  try {
    const models = [...CATALOG_MODELS].reverse().map((m) => m.slug === 'gpt-old' ? { ...m, priority: 0 } : m);
    writeCatalog(opts.catalogPath, models, isoDaysAgo(0, NOW));
    const picked = resolver.selectModel({ catalog: models, usage: { rate_limit: { allowed: true } }, requestedModel: 'gpt-old' });
    assert.strictEqual(picked.model, 'gpt-old');
    assert.strictEqual(picked.modelChanged, false);
    assert.strictEqual(picked.reason, 'requested-available');
    writeConfig(opts.dotfilesRepo, 'config.yaml', 'cross_model_peer: codex\ncross_model_model: gpt-old\n');
    const accepted = C.audit(opts);
    assert.deepStrictEqual(accepted.findings, []);
    assert.strictEqual(accepted.dotfiles.model, 'gpt-old');
    assert.strictEqual(accepted.repos.checked, 3);
    assertCountsReconcile(accepted);

    writeConfig(opts.dotfilesRepo, 'config.yaml', 'cross_model_peer: codex\ncross_model_model: gpt-unserved\n');
    const rejected = C.audit(opts);
    assert.strictEqual(rejected.findings.length, 1);
    assert.strictEqual(rejected.findings[0].code, 'model-unserved');
    assert.match(rejected.findings[0].message, /best selectable: gpt-6-astra, 4 selectable slug\(s\)/);
    assertCountsReconcile(rejected);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

// Both defaults and peer-target validation must use the same local install.
for (const peer of ['codex', 'claude']) {
  test(`audit(): local scope controls ${peer === 'codex' ? 'the model default' : 'peer-target validation'}, not served project/user installs`, () => {
    const { opts } = buildHomeWithPlugin('M_CODEX="gpt-6-astra"\nM_CLAUDE="opus"\n');
    try {
      const repo = path.join(opts.sitesRoot, 'repo-a');
      const alias = path.join(opts.home, 'repo-alias');
      fs.symlinkSync(repo, alias);
      const localInstall = path.join(opts.home, 'local-plugin');
      const projectInstall = path.join(opts.home, 'project-plugin');
      const localScript = writePluginScript(localInstall, 'M_CODEX="gpt-local-unserved"\n');
      writePluginScript(projectInstall, 'M_CODEX="gpt-5.6-luna"\nM_CLAUDE="opus"\n');
      const user = C.loadRegistry(opts.registryPath).entries[0];
      writeRegistry(opts.registryPath, [user,
        { scope: 'project', version: '2.0.0', installPath: projectInstall, projectPath: alias },
        { scope: 'local', version: '3.0.0', installPath: localInstall, projectPath: alias },
      ]);
      writeConfig(repo, 'config.yaml', `cross_model_peer: ${peer}\n`);
      const result = C.audit(opts);
      assert.deepStrictEqual(result.findings.map((f) => f.code), peer === 'codex' ? ['model-unserved'] : ['peer-invalid', 'model-unserved']);
      assert.ok(result.findings.every((f) => f.repo === repo), 'nonmatching local/project entries must not affect repo-b or dotfiles');
      assert.match(result.findings.at(-1).message, /'gpt-local-unserved' \(plugin-default 3\.0\.0\) is not in the served codex catalog/);
      if (peer === 'claude') assert.ok(result.findings[0].message.includes(localScript));
      assert.deepStrictEqual(result.repos, { checked: 3, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: 0, discovered: 3 });
      assertCountsReconcile(result);
    } finally {
      fs.rmSync(opts.home, { recursive: true, force: true });
    }
  });
}

test('audit(): an unknown plugin default is one finding PER REPO, each repo counted unreadable — no-M_CODEX-line and unreadable-script worded apart', () => {
  const noLine = buildHomeWithPlugin('# no mapping lines here\n');
  const noScript = buildHomeWithPlugin(null);
  try {
    const result = C.audit(noLine.opts);
    const defaults = result.findings.filter((f) => f.code === 'plugin-default-unreadable');
    assert.deepStrictEqual(defaults.map((f) => path.basename(f.repo)).sort(), ['repo-a', 'repo-b']);
    for (const f of defaults) {
      assert.match(f.message, new RegExp(`^${path.basename(f.repo)}: the plugin's codex default is unknown — plugin script has no M_CODEX= line \\(${noLine.scriptPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\)$`));
    }
    assert.strictEqual(result.repos.unreadable, 2);
    assert.strictEqual(result.repos.checked, 1, 'dotfiles has its own pin');
    assertCountsReconcile(result);

    const missing = C.audit(noScript.opts);
    const missingDefaults = missing.findings.filter((f) => f.code === 'plugin-default-unreadable');
    assert.strictEqual(missingDefaults.length, 2);
    assert.match(missingDefaults[0].message, /the plugin's codex default is unknown — could not read the plugin script \(.*: ENOENT\)/);
    assertCountsReconcile(missing);
  } finally {
    fs.rmSync(noLine.opts.home, { recursive: true, force: true });
    fs.rmSync(noScript.opts.home, { recursive: true, force: true });
  }
});

test('audit(): a repo whose cross_model_peer is invalid on every layer is still checked against the codex default, never dropped from the counts', () => {
  const { opts } = buildHomeWithPlugin('M_CODEX="gpt-5.6-luna"\n');
  try {
    writeConfig(path.join(opts.sitesRoot, 'repo-a'), 'config.local.yaml', 'cross_model_peer: bogus-1\n');
    writeConfig(path.join(opts.sitesRoot, 'repo-a'), 'config.yaml', 'cross_model_peer: bogus-2\n');
    const result = C.audit(opts);
    assert.strictEqual(result.findings.filter((f) => f.code === 'peer-invalid').length, 2);
    assert.strictEqual(result.repos.checked, 3, 'dotfiles, repo-a (plugin default gpt-5.6-luna), repo-b');
    assertCountsReconcile(result);
    assert.strictEqual(result.findings.some((f) => f.code === 'model-unserved'), false, 'the plugin default is served');
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): a cursor peer is an other-peer skip, not peer-invalid, even though the script has no M_CURSOR line', () => {
  const { opts } = buildHomeWithPlugin('M_CODEX="gpt-5.6-luna"\n');
  try {
    writeConfig(path.join(opts.sitesRoot, 'repo-a'), 'config.yaml', 'cross_model_peer: cursor\ncross_model_model: would-fail-if-compared\n');
    const result = C.audit(opts);
    assert.strictEqual(result.repos.skipped_other_peer, 1);
    assert.strictEqual(result.findings.length, 0, JSON.stringify(result.findings));
    assertCountsReconcile(result);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): a malformed registry leaves an unpinned repo unreadable, not skipped as plugin-less', () => {
  const opts = buildHome();
  try {
    fs.mkdirSync(path.dirname(opts.registryPath), { recursive: true });
    fs.writeFileSync(opts.registryPath, '{not valid json');
    const result = C.audit(opts);
    assert.strictEqual(result.repos.unreadable, 2, 'repo-a and repo-b cannot resolve a plugin default');
    assert.strictEqual(result.repos.skipped_no_plugin, 0);
    assert.strictEqual(result.findings.filter((f) => f.code === 'registry-unreadable').length, 1);
    assert.match(result.findings.find((f) => f.code === 'registry-unreadable').message, /^plugin registry unreadable:/);
    assertCountsReconcile(result);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): equal config.local.yaml and config.yaml pins are not a shadow; differing ones are', () => {
  const opts = buildHome();
  try {
    writeConfig(opts.dotfilesRepo, 'config.local.yaml', 'cross_model_model: gpt-6-astra\n');
    const same = C.audit(opts);
    assert.strictEqual(same.findings.some((f) => f.code === 'local-shadows-main'), false);
    assert.strictEqual(same.dotfiles.source, 'config.local.yaml');

    writeConfig(opts.dotfilesRepo, 'config.local.yaml', 'cross_model_model: gpt-5.6-luna\n');
    const differ = C.audit(opts);
    assert.strictEqual(differ.findings.filter((f) => f.code === 'local-shadows-main').length, 1);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): the dotfiles checkout reachable under SITES is audited once, as dotfiles', () => {
  const opts = buildHome();
  try {
    fs.symlinkSync(opts.dotfilesRepo, path.join(opts.sitesRoot, 'dotfiles-link'));
    const result = C.audit(opts);
    assert.strictEqual(result.repos.discovered, 3);
    assert.strictEqual(result.repos.checked, 1);
    assertCountsReconcile(result);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): an unsearchable .compound-engineering/ is unreadable — never "no config", never the plugin default — skipped as root', (t) => {
  if (IS_ROOT) {
    t.skip(ROOT_SKIP);
    return;
  }
  const { opts } = buildHomeWithPlugin('M_CODEX="gpt-5.6-luna"\n');
  const ceDir = path.join(opts.sitesRoot, 'repo-a', '.compound-engineering');
  try {
    writeConfig(path.join(opts.sitesRoot, 'repo-a'), 'config.yaml', 'cross_model_peer: codex\ncross_model_model: gpt-9-vega\n');
    fs.chmodSync(ceDir, 0o000);
    const result = C.audit(opts);
    const unreadable = result.findings.filter((f) => f.code === 'config-unreadable');
    assert.deepStrictEqual(unreadable.map((f) => f.message), [
      'repo-a: config.local.yaml could not be read (EACCES)',
      'repo-a: config.yaml could not be read (EACCES)',
    ]);
    assert.strictEqual(result.repos.unreadable, 1);
    assert.strictEqual(result.repos.checked, 2, 'dotfiles and repo-b only');
    assert.strictEqual(result.findings.some((f) => f.code === 'model-unserved'), false, 'no comparison on a partial read');
    assertCountsReconcile(result);
  } finally {
    fs.chmodSync(ceDir, 0o755);
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

test('audit(): a SITES repo that cannot be entered is named and counted unreadable — skipped as root', (t) => {
  if (IS_ROOT) {
    t.skip(ROOT_SKIP);
    return;
  }
  const opts = buildHome();
  const locked = path.join(opts.sitesRoot, 'repo-a');
  try {
    fs.chmodSync(locked, 0o000);
    const result = C.audit(opts);
    assert.ok(result.findings.some((f) => f.code === 'repo-unreadable' && f.message === 'repo-a: repo directory exists but could not be entered (EACCES)'));
    assert.strictEqual(result.repos.unreadable, 1);
    assert.strictEqual(result.repos.discovered, 3);
    assertCountsReconcile(result);
  } finally {
    fs.chmodSync(locked, 0o755);
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// main() — CLI contract: JSON always on stdout, exit 0; a usage error exits
// 2 on stderr before any JSON is printed.
// ---------------------------------------------------------------------------

test('main(): a bad flag exits 2 with a stderr message and prints no JSON', () => {
  const proc = spawnSync(process.execPath, [SCRIPT_PATH, '--bogus', 'x'], { encoding: 'utf8', timeout: 5000 });
  assert.strictEqual(proc.status, 2);
  assert.match(proc.stderr, /unrecognized flag: --bogus/);
  assert.strictEqual(proc.stdout, '');
});

test('main(): a flag missing its value exits 2 with a stderr message', () => {
  const proc = spawnSync(process.execPath, [SCRIPT_PATH, '--home'], { encoding: 'utf8', timeout: 5000 });
  assert.strictEqual(proc.status, 2);
  assert.match(proc.stderr, /--home requires a value/);
});

test('main(): an unparseable --now exits 2 with a stderr message and prints no JSON', () => {
  const proc = spawnSync(process.execPath, [SCRIPT_PATH, '--now', 'yesterday-ish'], { encoding: 'utf8', timeout: 5000 });
  assert.strictEqual(proc.status, 2);
  assert.match(proc.stderr, /--now is not a parseable timestamp: yesterday-ish/);
  assert.strictEqual(proc.stdout, '');
});

test('main(): a successful run prints exactly one JSON object to stdout and exits 0', () => {
  const opts = buildHome();
  try {
    const proc = spawnSync(process.execPath, [
      SCRIPT_PATH,
      '--home', opts.home,
      '--sites-root', opts.sitesRoot,
      '--dotfiles-repo', opts.dotfilesRepo,
      '--catalog', opts.catalogPath,
      '--registry', opts.registryPath,
      '--now', new Date(opts.now).toISOString(),
    ], { encoding: 'utf8', timeout: 5000 });
    assert.strictEqual(proc.status, 0);
    const lines = proc.stdout.split('\n').filter(Boolean);
    assert.strictEqual(lines.length, 1);
    const parsed = JSON.parse(lines[0]);
    assert.strictEqual(parsed.dotfiles.model, 'gpt-6-astra');
    assert.strictEqual(parsed.repos.checked, 1);
    assertCountsReconcile(parsed);
  } finally {
    fs.rmSync(opts.home, { recursive: true, force: true });
  }
});
