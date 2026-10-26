'use strict';
/**
 * Codex best-available-model resolver (dotfiles issue 991).
 *
 * Two live sources, no model names in code:
 *
 *   catalog  GET chatgpt.com/backend-api/codex/models?client_version=<v>
 *            "best" = lowest `priority` among entries with `visibility: "list"`,
 *            following `upgrade.model` deprecation pointers when the
 *            replacement is itself available. Codex caches the same payload at
 *            $CODEX_HOME/models_cache.json (`fetched_at`, `client_version`,
 *            `models`); a cache younger than CATALOG_CACHE_MAX_AGE_MS is reused
 *            and the file is never written by us.
 *   usage    GET chatgpt.com/backend-api/wham/usage (the quota guard's endpoint)
 *            "available" = the account-level `rate_limit` for every model EXCEPT
 *            separately metered ones, which appear in `additional_rate_limits[]`
 *            keyed by `limit_name == catalog display_name` with their own
 *            `rate_limit`. `rate_limit_reset_credits.available_count` counts
 *            banked resets the operator can spend at chatgpt.com/codex/settings/usage.
 *
 * Rungs, in order: requested model if it is available on the active account;
 * else the best available model on the active account (a separately metered
 * one when the main window is out); else the best model on another caam
 * isolated profile, verified per command through its own usage endpoint (never
 * `caam activate`, which swaps auth machine-wide); else — ONLY when the
 * operator has opted in with CODEX_PICK_API_LANE=1 and a key is present — the
 * best `supported_in_api` model over the API; else "exhausted", naming the
 * banked reset when one exists. The API rung is off by default: the standing
 * posture is OAuth subscription limits, never API spend (issue 993).
 *
 * Uncertainty on the ACTIVE account (no auth, timeout, unfamiliar payload, no
 * catalog) resolves to `reason: "uncertain"` with no rewrite — the caller keeps
 * failing open exactly as before. Uncertainty on a FALLBACK account just skips
 * that account: we only rewrite toward a rung we could prove.
 *
 * Effort is the request's effort clamped to the chosen model's
 * `supported_reasoning_levels` (the fixture in issue 991: xhigh on a model that stops
 * at high becomes high); when nothing was requested the catalog
 * `default_reasoning_level` is reported and Codex is left to apply it.
 *
 * Consumed by PreToolUse/codex-quota-guard.js (rewrite instead of deny) and by
 * bin/codex-pick (scripts, cron, the Codex host). Both produce the same
 * receipt for the same inputs; that parity is a test.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const { execFileSync } = require('child_process');

const USAGE_ENDPOINTS = [
  'https://chatgpt.com/backend-api/wham/usage',
  'https://chatgpt.com/api/codex/usage',
];
const CATALOG_ENDPOINT = 'https://chatgpt.com/backend-api/codex/models';
const REQUEST_TIMEOUT_MS = 2500;
const CATALOG_CACHE_MAX_AGE_MS = 6 * 60 * 60 * 1000;
// A PreToolUse hook has a 10 s budget (settings.json registers this guard with
// timeout 10). Usage + catalog can take 5 s; two more accounts at 2.5 s each is
// the most that still fits. Anything past the cap is reported, never hidden.
const MAX_FALLBACK_ACCOUNTS = 2;
// Effort names are a Codex config vocabulary, not model names. The catalog lists
// each model's supported levels but not their order, so this is the ordering
// used to clamp a request DOWN to the nearest level a model supports.
const EFFORT_ORDER = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
// Codex config key/value that makes a run bill an API key while ChatGPT auth is
// also present (the inverse of the `preferred_auth_method = "chatgpt"` pin the
// delegation doc records). A config enum, not a model name.
const API_AUTH_CONFIG = ['preferred_auth_method', 'apikey'];
const CODEX_SUBCOMMANDS = new Set(['exec', 'e', 'review']);
const SAFE_VALUE = /^[A-Za-z0-9._:-]+$/;
const BANKED_RESET_HINT = 'a banked reset is available at chatgpt.com/codex/settings/usage';
// better-ccflare's Codex OAuth pool (dotfiles issue 1002). A Codex-shaped
// request through ccflare must name a route PROFILE id, never a physical model
// (raw gpt-* ids are refused, better-ccflare issue 324). Pool profiles follow
// our own naming convention, `codex-pool-<tier>`, where <tier> is the last
// hyphenated token of the physical model's catalog slug (gpt-6-astra -> astra),
// so the best pool is found by ranking tiers against the LIVE catalog, not by
// a name in this file. The Codex config key/value that selects the provider is
// a config enum, not a model name.
const CCFLARE_POOL_PROFILE_PREFIX = 'claude-bccf-route-codex-pool-';
const CCFLARE_PROVIDER_CONFIG = ['model_provider', 'better_ccflare'];

// ---------------------------------------------------------------------------
// Paths and auth
// ---------------------------------------------------------------------------

function codexHome(env = process.env) {
  if (env.CODEX_HOME && String(env.CODEX_HOME).trim()) return String(env.CODEX_HOME);
  return path.join(os.homedir(), '.codex');
}

function activeAuthPath(env = process.env) {
  return path.join(codexHome(env), 'auth.json');
}

function catalogCachePath(env = process.env) {
  return path.join(codexHome(env), 'models_cache.json');
}

function caamProfilesDir(env = process.env) {
  const data = env.XDG_DATA_HOME && String(env.XDG_DATA_HOME).trim()
    ? String(env.XDG_DATA_HOME)
    : path.join(os.homedir(), '.local', 'share');
  return path.join(data, 'caam', 'profiles', 'codex');
}

/** Read a Codex auth.json; null when there is no usable access token. */
function readAuth(authPath) {
  try {
    const auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
    const tokens = auth && auth.tokens;
    const token = (tokens && tokens.access_token) || '';
    const account = (tokens && (tokens.account_id || tokens.chatgpt_account_id)) || '';
    if (!token) return null;
    return { token, account };
  } catch {
    return null;
  }
}

/**
 * Accounts in preference order. The active $CODEX_HOME auth comes first; then
 * every caam ISOLATED profile (`caam profile add codex <name>` + `caam login`),
 * which lives at <data>/caam/profiles/codex/<name>/codex_home/auth.json and is
 * the only caam shape `caam exec` can run. Vault backups (`caam backup`) are
 * not listed: they feed `caam activate`, a machine-wide swap this resolver
 * never performs.
 */
function listAccounts(env = process.env) {
  const accounts = [{ name: 'active', authPath: activeAuthPath(env), execPrefix: null }];
  const dir = caamProfilesDir(env);
  let names = [];
  try {
    names = fs.readdirSync(dir).filter((n) => !n.startsWith('.')).sort();
  } catch {
    return accounts;
  }
  for (const name of names) {
    const authPath = path.join(dir, name, 'codex_home', 'auth.json');
    if (!fs.existsSync(authPath)) continue;
    accounts.push({
      name,
      authPath,
      execPrefix: ['caam', 'exec', 'codex', name, '--no-lock', '--'],
    });
  }
  return accounts;
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function httpGetJson(endpoint, auth, timeoutMs = REQUEST_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let url;
    try { url = new URL(endpoint); } catch { return resolve({ ok: false }); }
    const headers = {
      Authorization: `Bearer ${auth.token}`,
      Accept: 'application/json',
      'User-Agent': 'codex-cli',
    };
    if (auth.account) headers['chatgpt-account-id'] = auth.account;
    const req = https.request({
      hostname: url.hostname,
      path: `${url.pathname}${url.search}`,
      method: 'GET',
      headers,
      timeout: timeoutMs,
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => {
        if (body.length < 1048576) body += chunk;
      });
      res.on('end', () => {
        const status = res.statusCode || 0;
        if (status !== 200) return resolve({ ok: true, status, json: null });
        try { resolve({ ok: true, status, json: JSON.parse(body) }); } catch { resolve({ ok: true, status, json: null }); }
      });
    });
    req.on('error', () => resolve({ ok: false }));
    req.on('timeout', () => {
      req.destroy();
      resolve({ ok: false });
    });
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

/** Explicit-state read of one rate_limit object: ok | blocked | uncertain. */
function rateLimitState(rateLimit) {
  if (!rateLimit || typeof rateLimit !== 'object' || Array.isArray(rateLimit)) return 'uncertain';
  const hasAllowed = typeof rateLimit.allowed === 'boolean';
  const hasReached = typeof rateLimit.limit_reached === 'boolean';
  if (!hasAllowed && !hasReached) return 'uncertain';
  if (rateLimit.allowed === false || rateLimit.limit_reached === true) return 'blocked';
  return 'ok';
}

/**
 * The quota guard's original verdict, unchanged: deny only on explicit state,
 * every unfamiliar shape fails open.
 */
function evaluateUsage(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, blocked: false };
  const state = rateLimitState(body.rate_limit);
  if (state === 'uncertain') return { ok: false, blocked: false };
  return { ok: true, blocked: state === 'blocked' };
}

function bankedResets(usage) {
  const credits = usage && usage.rate_limit_reset_credits;
  const n = credits && credits.available_count;
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** Fetch usage for one auth; { ok, blocked, usage } with usage null on uncertainty. */
async function fetchUsage(auth, deps = {}) {
  if (!auth) return { ok: false, blocked: false, usage: null };
  const get = deps.httpGetJson || httpGetJson;
  let response = await get(USAGE_ENDPOINTS[0], auth);
  if (response.ok && response.status === 404) response = await get(USAGE_ENDPOINTS[1], auth);
  if (!response.ok || response.status !== 200 || !response.json) return { ok: false, blocked: false, usage: null };
  const verdict = evaluateUsage(response.json);
  return { ...verdict, usage: verdict.ok ? response.json : null };
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

function readCatalogCache(cachePath, nowMs) {
  try {
    const cache = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
    if (!cache || !Array.isArray(cache.models)) return null;
    const fetchedAt = typeof cache.fetched_at === 'string' ? Date.parse(cache.fetched_at) : NaN;
    const fresh = Number.isFinite(fetchedAt) && nowMs - fetchedAt >= 0 && nowMs - fetchedAt < CATALOG_CACHE_MAX_AGE_MS;
    return {
      models: cache.models,
      fetchedAt: Number.isFinite(fetchedAt) ? new Date(fetchedAt).toISOString() : null,
      clientVersion: typeof cache.client_version === 'string' ? cache.client_version : null,
      fresh,
    };
  } catch {
    return null;
  }
}

function codexClientVersion(hint) {
  if (hint) return hint;
  try {
    const out = execFileSync('codex', ['--version'], { encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'] });
    const m = /(\d+\.\d+\.\d+)/.exec(out);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

/**
 * The catalog: a fresh Codex cache when there is one, else a live fetch with
 * the active auth. Returns { models, fetchedAt, source } or null. Never writes
 * Codex's cache file.
 */
async function loadCatalog({ auth, env = process.env, nowMs = Date.now(), deps = {} } = {}) {
  const cachePath = deps.catalogCachePath || catalogCachePath(env);
  const cache = readCatalogCache(cachePath, nowMs);
  if (cache && cache.fresh) return { models: cache.models, fetchedAt: cache.fetchedAt, source: 'cache' };
  if (auth) {
    const get = deps.httpGetJson || httpGetJson;
    const version = codexClientVersion(deps.clientVersion || (cache && cache.clientVersion));
    const url = version ? `${CATALOG_ENDPOINT}?client_version=${encodeURIComponent(version)}` : CATALOG_ENDPOINT;
    const response = await get(url, auth);
    const models = response.ok && response.status === 200 && response.json && Array.isArray(response.json.models)
      ? response.json.models
      : null;
    if (models) return { models, fetchedAt: new Date(nowMs).toISOString(), source: 'live' };
  }
  // A stale cache beats no catalog: names rot within hours, but a stale pick is
  // still verified against live usage before anything is rewritten.
  if (cache) return { models: cache.models, fetchedAt: cache.fetchedAt, source: 'stale-cache' };
  return null;
}

// ---------------------------------------------------------------------------
// Selection (pure)
// ---------------------------------------------------------------------------

const priorityOf = (m) => (Number.isFinite(m && m.priority) ? m.priority : Number.POSITIVE_INFINITY);
const isListed = (m) => m && typeof m.slug === 'string' && m.slug && m.visibility === 'list';

function supportedEfforts(model) {
  const levels = model && Array.isArray(model.supported_reasoning_levels) ? model.supported_reasoning_levels : [];
  return levels.map((l) => (l && typeof l === 'object' ? l.effort : l)).filter((e) => typeof e === 'string' && e);
}

/** Which meter governs a model, and its explicit state. */
function availability(model, usage) {
  if (!usage || typeof usage !== 'object') return { separate: false, state: 'uncertain' };
  const extras = Array.isArray(usage.additional_rate_limits) ? usage.additional_rate_limits : [];
  const own = extras.find((a) => a && typeof a === 'object' && a.limit_name && a.limit_name === model.display_name);
  if (own) return { separate: true, state: rateLimitState(own.rate_limit) };
  return { separate: false, state: rateLimitState(usage.rate_limit) };
}

/** Listed models whose governing meter is explicitly open, catalog order. */
function availableListed(catalog, usage) {
  return (Array.isArray(catalog) ? catalog : []).filter((m) => isListed(m) && availability(m, usage).state === 'ok');
}

/**
 * Listed, available models sorted best-first, with deprecations followed when
 * the replacement is itself available. Pure: (catalog, usage) -> models.
 */
function candidates(catalog, usage) {
  const listed = (Array.isArray(catalog) ? catalog : []).filter(isListed);
  const bySlug = new Map(listed.map((m) => [m.slug, m]));
  const available = (m) => availability(m, usage).state === 'ok';
  const out = new Map();
  for (const m of listed) {
    if (!available(m)) continue;
    let pick = m;
    const target = m.upgrade && typeof m.upgrade === 'object' && typeof m.upgrade.model === 'string'
      ? bySlug.get(m.upgrade.model)
      : null;
    if (target && available(target)) pick = target;
    if (!out.has(pick.slug)) out.set(pick.slug, pick);
  }
  return [...out.values()].sort((a, b) => priorityOf(a) - priorityOf(b));
}

/** Clamp a requested effort down to the nearest level a model supports; null when nothing fits. */
function clampEffort(requested, levels) {
  if (!requested || !levels.length) return null;
  if (levels.includes(requested)) return requested;
  const wanted = EFFORT_ORDER.indexOf(requested);
  if (wanted < 0) return null;
  let best = null;
  let bestRank = -1;
  for (const level of levels) {
    const rank = EFFORT_ORDER.indexOf(level);
    if (rank < 0 || rank > wanted) continue;
    if (rank > bestRank) { best = level; bestRank = rank; }
  }
  if (best) return best;
  // Everything the model supports is above the request: take its lowest.
  return levels
    .filter((l) => EFFORT_ORDER.indexOf(l) >= 0)
    .sort((a, b) => EFFORT_ORDER.indexOf(a) - EFFORT_ORDER.indexOf(b))[0] || levels[0];
}

function pickEffort(requestedEffort, model) {
  const levels = supportedEfforts(model);
  const fallback = typeof model.default_reasoning_level === 'string' ? model.default_reasoning_level : null;
  if (!requestedEffort) return { effort: fallback, changed: false, source: 'catalog-default' };
  if (!levels.length || levels.includes(requestedEffort)) return { effort: requestedEffort, changed: false, source: 'requested' };
  const clamped = clampEffort(requestedEffort, levels) || fallback;
  return { effort: clamped, changed: clamped !== requestedEffort, source: 'clamped' };
}

/**
 * One account's pick. Returns null when nothing on this account is available.
 *   { model, priority, modelChanged, effort, effortChanged, effortSource, reason }
 */
function selectModel({ catalog, usage, requestedModel, requestedEffort }) {
  const cands = candidates(catalog, usage);
  const mainState = rateLimitState(usage && usage.rate_limit);
  if (requestedModel) {
    // A requested model that is itself available stays, deprecation pointer or
    // not: "already carries -m for a still-available model" is untouched.
    const kept = availableListed(catalog, usage).find((c) => c.slug === requestedModel);
    if (kept) {
      // The model stays; its effort may still need clamping (ultra on a model
      // that stops at xhigh), and that clamp is a rewrite in its own right.
      const effort = pickEffort(requestedEffort, kept);
      return {
        model: kept.slug,
        priority: priorityOf(kept),
        modelChanged: false,
        effort: effort.effort,
        effortChanged: effort.changed,
        effortSource: effort.source,
        reason: 'requested-available',
      };
    }
    const known = (Array.isArray(catalog) ? catalog : []).find((m) => m && m.slug === requestedModel);
    // An unknown slug on a healthy main window: we cannot say which meter it
    // draws on, so leave the request alone rather than second-guess it.
    if (!known && mainState === 'ok') {
      return { model: requestedModel, priority: null, modelChanged: false, effort: requestedEffort || null, effortChanged: false, effortSource: 'requested', reason: 'requested-unknown' };
    }
  } else if (mainState === 'ok') {
    // No -m and the main window is open: Codex's default model draws on it.
    return { model: null, priority: null, modelChanged: false, effort: requestedEffort || null, effortChanged: false, effortSource: 'requested', reason: 'healthy' };
  }
  const top = cands[0];
  if (!top) return null;
  const effort = pickEffort(requestedEffort, top);
  return {
    model: top.slug,
    priority: priorityOf(top),
    modelChanged: true,
    effort: effort.effort,
    effortChanged: effort.changed,
    effortSource: effort.source,
    reason: 'fallback',
  };
}

/** Best API-capable listed model, independent of any subscription meter. */
function apiCandidate(catalog, requestedModel, requestedEffort) {
  const listed = (Array.isArray(catalog) ? catalog : []).filter((m) => isListed(m) && m.supported_in_api === true);
  if (!listed.length) return null;
  const kept = requestedModel ? listed.find((m) => m.slug === requestedModel) : null;
  const pick = kept || listed.sort((a, b) => priorityOf(a) - priorityOf(b))[0];
  const effort = pickEffort(requestedEffort, pick);
  return {
    model: pick.slug,
    priority: priorityOf(pick),
    modelChanged: !kept,
    effort: effort.effort,
    effortChanged: effort.changed,
    effortSource: effort.source,
    reason: 'api-key',
  };
}

// ---------------------------------------------------------------------------
// Command parsing and rewriting
// ---------------------------------------------------------------------------

const isSpace = (c) => c === ' ' || c === '\t';
const isBreak = (c) => c === '\n' || c === ';' || c === '|' || c === '&' || c === '(' || c === ')';

/**
 * Top-level shell scan with source offsets. Tokens are { text, raw, start, end,
 * sep, opaque }: `text` is the exact source slice, `raw` the shell-unquoted
 * value, `opaque` marks words carrying `$…` or backtick expansions whose runtime
 * value we cannot know. Returns null on an unterminated quote.
 */
function scanShell(src) {
  const tokens = [];
  const n = src.length;
  let i = 0;
  // Pending heredoc delimiters (`<<EOF`, `<<-EOF`, `<<'EOF'`): their bodies are
  // prompt text, not commands, so each body becomes ONE opaque token and is
  // never scanned for an invocation.
  const heredocs = [];
  while (i < n) {
    const c = src[i];
    if (isSpace(c)) { i += 1; continue; }
    if (isBreak(c)) {
      let j = i + 1;
      if ((c === '|' || c === '&') && src[j] === c) j += 1;
      tokens.push({ text: src.slice(i, j), raw: src.slice(i, j), start: i, end: j, sep: true, opaque: false });
      i = j;
      if (c === '\n' && heredocs.length) {
        const bodyStart = i;
        while (heredocs.length) {
          const delimiter = heredocs.shift();
          for (;;) {
            if (i >= n) break;
            let lineEnd = src.indexOf('\n', i);
            if (lineEnd < 0) lineEnd = n;
            const line = src.slice(i, lineEnd);
            i = lineEnd < n ? lineEnd + 1 : n;
            if (line.replace(/^\t+/, '') === delimiter) break;
          }
        }
        tokens.push({ text: src.slice(bodyStart, i), raw: src.slice(bodyStart, i), start: bodyStart, end: i, sep: false, opaque: true, heredoc: true });
        if (i > bodyStart) tokens.push({ text: '', raw: '\n', start: i, end: i, sep: true, opaque: false });
      }
      continue;
    }
    const start = i;
    let raw = '';
    let quote = null;
    let opaque = false;
    while (i < n) {
      const ch = src[i];
      if (quote === "'") {
        if (ch === "'") quote = null; else raw += ch;
        i += 1;
        continue;
      }
      if (quote === '"') {
        if (ch === '"') { quote = null; i += 1; continue; }
        if (ch === '\\' && i + 1 < n && '"$`\\\n'.includes(src[i + 1])) {
          if (src[i + 1] !== '\n') raw += src[i + 1];
          i += 2;
          continue;
        }
        if (ch === '$' || ch === '`') opaque = true;
        raw += ch;
        i += 1;
        continue;
      }
      if (ch === "'" || ch === '"') { quote = ch; i += 1; continue; }
      if (ch === '\\' && i + 1 < n) {
        if (src[i + 1] !== '\n') raw += src[i + 1];
        i += 2;
        continue;
      }
      if (ch === '$' && src[i + 1] === '(') {
        // $( … ) — consume to the matching paren so the inner parens never read as separators.
        opaque = true;
        let depth = 0;
        while (i < n) {
          if (src[i] === '(') depth += 1;
          else if (src[i] === ')') { depth -= 1; if (depth === 0) { raw += src[i]; i += 1; break; } }
          raw += src[i];
          i += 1;
        }
        continue;
      }
      if (ch === '`') {
        opaque = true;
        raw += ch;
        i += 1;
        while (i < n && src[i] !== '`') { raw += src[i]; i += 1; }
        if (i < n) { raw += src[i]; i += 1; }
        continue;
      }
      if (isSpace(ch) || isBreak(ch)) break;
      if (ch === '$') opaque = true;
      raw += ch;
      i += 1;
    }
    if (quote) return null;
    if (raw.startsWith('<<')) heredocs.push(raw.replace(/^<<-?/, ''));
    tokens.push({ text: src.slice(start, i), raw, start, end: i, sep: false, opaque });
  }
  return tokens;
}

const baseName = (raw) => raw.slice(raw.lastIndexOf('/') + 1);

/** Strip one layer of TOML string quotes from a `-c key=value` value. */
function tomlString(value) {
  const v = String(value);
  if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"))) {
    return v.slice(1, -1);
  }
  return v;
}

/**
 * Walk one segment's tokens from the subcommand onward, collecting the model
 * and effort flags. Each hit records which token carries the VALUE and how it
 * should be re-rendered. Stops at the next separator.
 */
function readFlags(tokens, from) {
  const flags = { model: [], effort: [], authMethod: [], provider: [], end: tokens.length, requestedModel: null, requestedEffort: null, requestedProvider: null, opaque: false };
  for (let k = from; k < tokens.length; k += 1) {
    const t = tokens[k];
    if (t.sep) { flags.end = k; break; }
    const raw = t.raw;
    // Codex (clap) accepts options anywhere before a bare `--`; after it every
    // word is the prompt, so a `-m` there is prose and must not be touched.
    if (raw === '--') {
      for (let j = k + 1; j < tokens.length && !tokens[j].sep; j += 1) k = j;
      continue;
    }
    const next = tokens[k + 1] && !tokens[k + 1].sep ? tokens[k + 1] : null;
    if ((raw === '-m' || raw === '--model') && next) {
      flags.model.push({ token: next, render: (slug) => slug });
      if (next.opaque) flags.opaque = true; else if (flags.requestedModel === null) flags.requestedModel = next.raw;
      k += 1;
      continue;
    }
    if (raw.startsWith('--model=')) {
      flags.model.push({ token: t, render: (slug) => `--model=${slug}` });
      if (t.opaque) flags.opaque = true; else if (flags.requestedModel === null) flags.requestedModel = raw.slice('--model='.length);
      continue;
    }
    let config = null;
    let configToken = null;
    let configRender = null;
    if ((raw === '-c' || raw === '--config') && next) {
      config = next.raw;
      configToken = next;
      configRender = (kv) => kv;
      k += 1;
    } else if (raw.startsWith('--config=')) {
      config = raw.slice('--config='.length);
      configToken = t;
      configRender = (kv) => `--config=${kv}`;
    }
    if (config !== null) {
      const eq = config.indexOf('=');
      const key = eq >= 0 ? config.slice(0, eq).trim() : config.trim();
      const value = eq >= 0 ? tomlString(config.slice(eq + 1).trim()) : '';
      const opaque = configToken.opaque;
      if (key === 'model') {
        flags.model.push({ token: configToken, render: (slug) => configRender(`model=${slug}`) });
        if (opaque) flags.opaque = true; else if (flags.requestedModel === null) flags.requestedModel = value;
      } else if (key === 'model_reasoning_effort') {
        flags.effort.push({ token: configToken, render: (level) => configRender(`model_reasoning_effort=${level}`) });
        if (opaque) flags.opaque = true; else if (flags.requestedEffort === null) flags.requestedEffort = value;
      } else if (key === API_AUTH_CONFIG[0]) {
        flags.authMethod.push({ token: configToken, render: (v) => configRender(`${API_AUTH_CONFIG[0]}=${v}`) });
      } else if (key === CCFLARE_PROVIDER_CONFIG[0]) {
        flags.provider.push({ token: configToken, render: (v) => configRender(`${CCFLARE_PROVIDER_CONFIG[0]}=${v}`) });
        if (!opaque && flags.requestedProvider === null) flags.requestedProvider = value;
      }
    }
  }
  return flags;
}

/**
 * Find every direct `codex <exec|e|review>` invocation at the top level of a
 * command string. Returns { invocations, requestedModel, requestedEffort,
 * opaque } or null when the string has no direct invocation. A wrapped
 * `bash -c "codex exec …"` is found one level down and reported as such.
 */
function parseCommand(command) {
  const tokens = scanShell(String(command || ''));
  if (!tokens) return null;
  const invocations = [];
  let requestedModel = null;
  let requestedEffort = null;
  let opaque = false;
  for (let k = 0; k + 1 < tokens.length; k += 1) {
    const t = tokens[k];
    const sub = tokens[k + 1];
    if (t.sep || sub.sep) continue;
    if (baseName(t.raw) === 'codex' && !t.opaque && CODEX_SUBCOMMANDS.has(sub.raw)) {
      const flags = readFlags(tokens, k + 2);
      invocations.push({ kind: 'direct', codexToken: t, subToken: sub, flags });
      if (requestedModel === null) requestedModel = flags.requestedModel;
      if (requestedEffort === null) requestedEffort = flags.requestedEffort;
      opaque = opaque || flags.opaque;
      k = flags.end - 1;
      continue;
    }
    if (['bash', 'sh', 'zsh'].includes(baseName(t.raw)) && !t.opaque) {
      // bash [opts] -c '<payload>' (also -lc, -ec: a short cluster ending in c)
      // — the payload token must be ONE quoted span.
      const isDashC = (raw) => /^-[a-zA-Z]*c$/.test(raw);
      let j = k + 1;
      while (j < tokens.length && !tokens[j].sep && !isDashC(tokens[j].raw)) j += 1;
      const payload = tokens[j + 1];
      if (j < tokens.length && isDashC(tokens[j].raw) && payload && !payload.sep) {
        const quote = singleQuotedSpan(payload.text);
        const inner = parseCommand(payload.raw);
        if (inner && inner.invocations.length) {
          invocations.push({ kind: 'wrapped', payloadToken: payload, quote, inner });
          if (requestedModel === null) requestedModel = inner.requestedModel;
          if (requestedEffort === null) requestedEffort = inner.requestedEffort;
          opaque = opaque || inner.opaque || payload.opaque;
          k = j + 1;
          continue;
        }
      }
    }
  }
  if (!invocations.length) return null;
  return { invocations, requestedModel, requestedEffort, opaque };
}

/** 'x' or "x" as exactly one quoted span → the quote char; else null. */
function singleQuotedSpan(text) {
  if (text.length < 2) return null;
  const q = text[0];
  if ((q !== "'" && q !== '"') || text[text.length - 1] !== q) return null;
  for (let i = 1; i < text.length - 1; i += 1) {
    if (q === '"' && text[i] === '\\') { i += 1; continue; }
    if (text[i] === q) return null;
  }
  return q;
}

const SHELL_SAFE_WORD = /^[A-Za-z0-9._:=/,+@%-]+$/;
function shellWord(value) {
  return SHELL_SAFE_WORD.test(value) ? value : `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

/**
 * Apply a plan { model, effort, execPrefix, extraConfig } to one command
 * string. Returns the rewritten string, or null when the shape cannot be
 * rewritten safely (no direct invocation, an expansion in a flag we would have
 * to replace, or a wrapper payload we could not re-quote losslessly).
 */
function rewriteCommand(command, plan) {
  const parsed = parseCommand(command);
  if (!parsed) return null;
  if (plan.model && !SAFE_VALUE.test(plan.model)) return null;
  if (plan.effort && !SAFE_VALUE.test(plan.effort)) return null;
  const edits = [];
  for (const inv of parsed.invocations) {
    if (inv.kind === 'wrapped') {
      if (inv.payloadToken.opaque) return null;
      const innerRewritten = rewriteCommand(inv.payloadToken.raw, plan);
      if (innerRewritten === null) return null;
      const requoted = requote(innerRewritten, inv.quote);
      if (requoted === null) return null;
      edits.push({ start: inv.payloadToken.start, end: inv.payloadToken.end, text: requoted });
      continue;
    }
    const { flags, codexToken, subToken } = inv;
    const inserts = [];
    if (plan.model) {
      if (flags.model.length) {
        for (const f of flags.model) {
          if (f.token.opaque) return null;
          edits.push({ start: f.token.start, end: f.token.end, text: f.render(plan.model) });
        }
      } else {
        inserts.push(`-m ${plan.model}`);
      }
    }
    if (plan.effort) {
      if (flags.effort.length) {
        for (const f of flags.effort) {
          if (f.token.opaque) return null;
          edits.push({ start: f.token.start, end: f.token.end, text: f.render(plan.effort) });
        }
      } else {
        inserts.push(`-c model_reasoning_effort=${plan.effort}`);
      }
    }
    for (const [key, value] of plan.extraConfig || []) {
      const existing = key === API_AUTH_CONFIG[0] ? flags.authMethod : key === CCFLARE_PROVIDER_CONFIG[0] ? flags.provider : [];
      if (existing.length) {
        for (const f of existing) {
          if (f.token.opaque) return null;
          edits.push({ start: f.token.start, end: f.token.end, text: f.render(value) });
        }
      } else {
        inserts.push(`-c ${key}=${value}`);
      }
    }
    if (inserts.length) edits.push({ start: subToken.end, end: subToken.end, text: ` ${inserts.join(' ')}` });
    if (plan.execPrefix && plan.execPrefix.length) {
      edits.push({ start: codexToken.start, end: codexToken.end, text: plan.execPrefix.map(shellWord).join(' ') });
    }
  }
  edits.sort((a, b) => b.start - a.start || b.end - a.end);
  let out = String(command);
  for (const e of edits) out = out.slice(0, e.start) + e.text + out.slice(e.end);
  return out;
}

function requote(inner, quote) {
  if (quote === "'") return inner.includes("'") ? null : `'${inner}'`;
  if (quote === '"') return `"${inner.replace(/(["\\$`])/g, '\\$1')}"`;
  return null;
}

/** argv twin of parseCommand/rewriteCommand for codex-pick --exec. */
function parseArgv(argv) {
  const tokens = argv.map((a, i) => ({ text: a, raw: a, start: i, end: i + 1, sep: false, opaque: false }));
  for (let k = 0; k + 1 < tokens.length; k += 1) {
    if (baseName(tokens[k].raw) === 'codex' && CODEX_SUBCOMMANDS.has(tokens[k + 1].raw)) {
      const flags = readFlags(tokens, k + 2);
      return { codexIndex: k, subIndex: k + 1, flags, requestedModel: flags.requestedModel, requestedEffort: flags.requestedEffort, opaque: false };
    }
  }
  return null;
}

function rewriteArgv(argv, plan) {
  const parsed = parseArgv(argv);
  if (!parsed) return null;
  const out = argv.slice();
  const { flags, codexIndex, subIndex } = parsed;
  const edits = [];
  const inserts = [];
  if (plan.model) {
    if (flags.model.length) for (const f of flags.model) edits.push({ index: f.token.start, text: f.render(plan.model) });
    else inserts.push('-m', plan.model);
  }
  if (plan.effort) {
    if (flags.effort.length) for (const f of flags.effort) edits.push({ index: f.token.start, text: f.render(plan.effort) });
    else inserts.push('-c', `model_reasoning_effort=${plan.effort}`);
  }
  for (const [key, value] of plan.extraConfig || []) {
    const existing = key === API_AUTH_CONFIG[0] ? flags.authMethod : key === CCFLARE_PROVIDER_CONFIG[0] ? flags.provider : [];
    if (existing.length) for (const f of existing) edits.push({ index: f.token.start, text: f.render(value) });
    else inserts.push('-c', `${key}=${value}`);
  }
  for (const e of edits) out[e.index] = e.text;
  out.splice(subIndex + 1, 0, ...inserts);
  if (plan.execPrefix && plan.execPrefix.length) out.splice(codexIndex, 1, ...plan.execPrefix);
  return out;
}

// ---------------------------------------------------------------------------
// Resolve
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// better-ccflare's Codex OAuth pool
// ---------------------------------------------------------------------------

/** Claude Code's live settings: where ccflare is and the host key it wants. */
function ccflareConfig(env = process.env) {
  try {
    const home = env.CLAUDE_HOME && String(env.CLAUDE_HOME).trim() ? String(env.CLAUDE_HOME) : path.join(os.homedir(), '.claude');
    const settings = JSON.parse(fs.readFileSync(path.join(home, 'settings.json'), 'utf8'));
    const vars = (settings && settings.env) || {};
    const base = typeof vars.ANTHROPIC_BASE_URL === 'string' ? vars.ANTHROPIC_BASE_URL.replace(/\/+$/, '') : '';
    const header = typeof vars.ANTHROPIC_CUSTOM_HEADERS === 'string' ? vars.ANTHROPIC_CUSTOM_HEADERS : '';
    const colon = header.indexOf(':');
    if (!base || colon < 1) return null;
    return { base, headerName: header.slice(0, colon).trim(), headerValue: header.slice(colon + 1).trim() };
  } catch {
    return null;
  }
}

/** GET a JSON document from ccflare (http or https), never throwing. */
function ccflareGet(cfg, route, timeoutMs = REQUEST_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let url;
    try { url = new URL(cfg.base + route); } catch { return resolve({ ok: false }); }
    const client = url.protocol === 'http:' ? require('http') : https;
    const req = client.request({
      hostname: url.hostname,
      port: url.port || undefined,
      path: `${url.pathname}${url.search}`,
      method: 'GET',
      headers: { Accept: 'application/json', [cfg.headerName]: cfg.headerValue },
      timeout: timeoutMs,
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => { if (body.length < 1048576) body += chunk; });
      res.on('end', () => {
        const status = res.statusCode || 0;
        if (status !== 200) return resolve({ ok: true, status, json: null });
        try { resolve({ ok: true, status, json: JSON.parse(body) }); } catch { resolve({ ok: true, status, json: null }); }
      });
    });
    req.on('error', () => resolve({ ok: false }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false }); });
    req.end();
  });
}

const tierOf = (slug) => String(slug || '').slice(String(slug || '').lastIndexOf('-') + 1);
const ccflareAccountOpen = (a) => a && a.provider === 'codex' && !a.paused && !a.requiresReauth
  && /^(ok|allowed)/i.test(String(a.rateLimitStatus || ''));

/**
 * The best Codex pool profile ccflare exposes, ranked by the LIVE catalog, and
 * the pool's per-account status. Pure over the two documents; pass fetched
 * `models` (GET /v1/models) and `accounts` (GET /api/accounts).
 */
function rankCcflarePools(models, accounts, catalog) {
  const listed = (Array.isArray(catalog) ? catalog : []).filter(isListed);
  const ids = (Array.isArray(models) ? models : []).map((m) => (m && typeof m.id === 'string' ? m.id : '')).filter(Boolean);
  const pools = [];
  for (const id of ids) {
    const bare = id.replace(/\[[^\]]*\]$/, '');
    if (!bare.startsWith(CCFLARE_POOL_PROFILE_PREFIX)) continue;
    const tier = bare.slice(CCFLARE_POOL_PROFILE_PREFIX.length);
    const entry = listed.find((m) => tierOf(m.slug) === tier || m.slug === tier);
    if (!entry) continue;
    pools.push({ profile: bare, tier, model: entry.slug, priority: priorityOf(entry), entry });
  }
  pools.sort((a, b) => a.priority - b.priority);
  const codexAccounts = (Array.isArray(accounts) ? accounts : []).filter((a) => a && a.provider === 'codex')
    .map((a) => ({ name: a.name, status: a.rateLimitStatus || (a.paused ? 'paused' : 'unknown'), open: ccflareAccountOpen(a) }));
  return { pools, accounts: codexAccounts, open: codexAccounts.filter((a) => a.open).map((a) => a.name) };
}

/** Discover the pool live; null when ccflare is not configured or not answering. */
async function ccflarePool({ env = process.env, catalog, deps = {} } = {}) {
  const cfg = (deps.ccflareConfig || ccflareConfig)(env);
  if (!cfg) return null;
  const get = deps.ccflareGet || ccflareGet;
  const [models, accounts] = await Promise.all([get(cfg, '/v1/models'), get(cfg, '/api/accounts')]);
  if (!models.ok || !models.json || !accounts.ok || !accounts.json) return null;
  const modelRows = Array.isArray(models.json.data) ? models.json.data : [];
  const accountRows = Array.isArray(accounts.json) ? accounts.json : accounts.json.accounts || accounts.json.data || [];
  return rankCcflarePools(modelRows, accountRows, catalog);
}

/** Top-level `model_provider = "..."` in Codex's config, else null. */
function configModelProvider(env = process.env) {
  try {
    const text = fs.readFileSync(path.join(codexHome(env), 'config.toml'), 'utf8');
    const top = text.split(/\r?\n/).findIndex((line) => /^\s*\[/.test(line));
    const head = top < 0 ? text : text.split(/\r?\n/).slice(0, top).join('\n');
    const m = /^\s*model_provider\s*=\s*"([^"]*)"/m.exec(head);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

/**
 * True when the command (or Codex's config) sends the run to a custom
 * model_provider such as ccflare: the local account's window is then not the
 * account that will serve it, so the quota guard has nothing to judge.
 */
function usesCustomProvider(command, env = process.env, deps = {}) {
  const parsed = parseCommand(command);
  if (parsed) {
    for (const inv of parsed.invocations) {
      const flags = inv.kind === 'wrapped' ? null : inv.flags;
      if (flags && flags.provider.length) return true;
      if (inv.kind === 'wrapped' && inv.inner.invocations.some((i) => i.flags && i.flags.provider.length)) return true;
    }
  }
  return !!(deps.configModelProvider || configModelProvider)(env);
}

/** The API-key rung runs only when explicitly opted in AND a key is present. */
function apiLaneEnabled(env = process.env) {
  return String(env.CODEX_PICK_API_LANE || '').trim() === '1'
    && !!(env.OPENAI_API_KEY && String(env.OPENAI_API_KEY).trim());
}

function planFor(sel, account, extraConfig) {
  return {
    model: sel.modelChanged || (account && account.execPrefix) || extraConfig ? sel.model : null,
    effort: sel.effortChanged ? sel.effort : null,
    execPrefix: account ? account.execPrefix : null,
    extraConfig: extraConfig || null,
  };
}

/**
 * Resolve the best available run for a Codex command.
 *
 * @param {object} o
 * @param {string} [o.command]   shell command string (guard path)
 * @param {string[]} [o.argv]    argv (codex-pick path); one of command/argv
 * @param {object} [o.usage]     the ACTIVE account's usage body, if the caller
 *                               already fetched it (the guard did)
 * @param {object} [o.env]       environment (OPENAI_API_KEY, CODEX_HOME, …)
 * @param {object} [o.deps]      injection: listAccounts, readAuth, fetchUsage,
 *                               loadCatalog, nowMs
 * @returns receipt { account, model, effort, priority, reason, changed,
 *   catalog_fetched_at, banked_resets, rewrite, argv, note, accounts_skipped }
 */
async function resolve(o = {}) {
  const env = o.env || process.env;
  const deps = o.deps || {};
  const nowMs = deps.nowMs || Date.now();
  const parsed = o.argv ? parseArgv(o.argv) : parseCommand(o.command || '');
  const requestedModel = parsed ? parsed.requestedModel : null;
  const requestedEffort = parsed ? parsed.requestedEffort : null;
  const accounts = (deps.listAccounts || listAccounts)(env);
  const active = accounts[0];
  const auth = (deps.readAuth || readAuth)(active.authPath);
  const receipt = {
    account: null,
    model: null,
    effort: null,
    priority: null,
    reason: 'uncertain',
    changed: false,
    requested_model: requestedModel,
    requested_effort: requestedEffort,
    catalog_fetched_at: null,
    banked_resets: 0,
    rewrite: null,
    argv: null,
    note: '',
    accounts_skipped: [],
  };

  // Active account: usage (already fetched by the guard, or fetch now).
  let usage = o.usage || null;
  if (!usage) {
    if (!auth) { receipt.note = 'no usable Codex auth for the active account'; return receipt; }
    const u = await (deps.fetchUsage || fetchUsage)(auth, deps);
    if (!u.ok) { receipt.note = 'usage endpoint uncertain for the active account'; return receipt; }
    usage = u.usage;
  }
  receipt.banked_resets = bankedResets(usage);
  const mainState = rateLimitState(usage.rate_limit);

  // Healthy main window and no requested model: nothing to decide, no catalog.
  if (mainState === 'ok' && !requestedModel) {
    receipt.account = active.name;
    receipt.reason = 'healthy';
    receipt.effort = requestedEffort;
    receipt.note = 'active account window open; command runs unchanged';
    return receipt;
  }

  const catalog = await (deps.loadCatalog || loadCatalog)({ auth, env, nowMs, deps });
  if (!catalog) {
    receipt.reason = mainState === 'ok' ? 'requested-unknown' : 'no-catalog';
    receipt.account = active.name;
    receipt.model = requestedModel;
    receipt.effort = requestedEffort;
    receipt.note = 'no model catalog (no fresh cache and the live fetch failed); nothing rewritten';
    return receipt;
  }
  receipt.catalog_fetched_at = catalog.fetchedAt;

  const finish = (sel, account, extraConfig) => {
    receipt.account = account ? account.name : 'api-key';
    receipt.model = sel.model;
    receipt.effort = sel.effort;
    receipt.priority = sel.priority;
    receipt.reason = sel.reason;
    const accountChanged = !!(account && account.execPrefix);
    receipt.changed = sel.modelChanged || sel.effortChanged || accountChanged || !!extraConfig;
    if (receipt.changed) {
      const plan = planFor(sel, account, extraConfig);
      if (o.argv) {
        receipt.argv = rewriteArgv(o.argv, plan);
        receipt.rewrite = receipt.argv ? receipt.argv.map(shellWord).join(' ') : null;
      } else {
        receipt.rewrite = rewriteCommand(o.command || '', plan);
      }
      if (receipt.rewrite === null) {
        receipt.note = `${sel.model} is available (${sel.reason}) but this command shape cannot be rewritten safely; run it directly as \`codex exec … -m ${sel.model}\``;
        receipt.changed = false;
        return receipt;
      }
    }
    receipt.note = receipt.changed
      ? `rewrote to ${sel.model}${sel.effortChanged ? ` at effort ${sel.effort}` : ''} on ${receipt.account} (${sel.reason})`
      : `${sel.model || 'requested model'} is available on ${receipt.account}; command runs unchanged`;
    return receipt;
  };

  // Rung 1: the active account. An unchanged model is final (requested-available,
  // healthy, requested-unknown); a fallback pick competes with the ccflare pool.
  const activeSel = selectModel({ catalog: catalog.models, usage, requestedModel, requestedEffort });
  if (activeSel && !activeSel.modelChanged) return finish(activeSel, active, null);

  // Rung 1b: better-ccflare's Codex OAuth pool — every ChatGPT Pro account
  // ccflare owns, rotated and failed closed by ccflare. Used when the pool has
  // an open account and its best physical model outranks what the active
  // account can still offer (a separately metered model). ccflare unreachable
  // or unconfigured just skips the rung.
  let pool = null;
  try { pool = await (deps.ccflarePool || ccflarePool)({ env, catalog: catalog.models, deps }); } catch { pool = null; }
  receipt.ccflare_pool = pool ? { open: pool.open, accounts: pool.accounts, pools: pool.pools.map((p) => ({ profile: p.profile, model: p.model, priority: p.priority })) } : null;
  if (pool && pool.pools.length && pool.open.length) {
    const best = pool.pools[0];
    if (!activeSel || best.priority < activeSel.priority) {
      const effort = pickEffort(requestedEffort, best.entry);
      const sel = { model: best.profile, priority: best.priority, modelChanged: true, effort: effort.effort, effortChanged: effort.changed, effortSource: effort.source, reason: 'ccflare-pool' };
      const out = finish(sel, { name: `ccflare:${best.profile}`, execPrefix: null }, [CCFLARE_PROVIDER_CONFIG]);
      out.model = best.model;
      out.profile = best.profile;
      if (out.changed) out.note = `rewrote to ccflare pool ${best.profile} (${best.model}${sel.effortChanged ? ` at effort ${sel.effort}` : ''}), open accounts: ${pool.open.join(', ')}`;
      return out;
    }
  }
  if (activeSel) return finish(activeSel, active, null);

  // Rung 2: other caam isolated profiles, each verified through its own usage.
  const others = accounts.slice(1);
  const tried = others.slice(0, MAX_FALLBACK_ACCOUNTS);
  receipt.accounts_skipped = others.slice(MAX_FALLBACK_ACCOUNTS).map((a) => `${a.name}: past the ${MAX_FALLBACK_ACCOUNTS}-account hook budget`);
  for (const account of tried) {
    const otherAuth = (deps.readAuth || readAuth)(account.authPath);
    if (!otherAuth) { receipt.accounts_skipped.push(`${account.name}: no usable auth`); continue; }
    const u = await (deps.fetchUsage || fetchUsage)(otherAuth, deps);
    if (!u.ok) { receipt.accounts_skipped.push(`${account.name}: usage uncertain`); continue; }
    const sel = selectModel({ catalog: catalog.models, usage: u.usage, requestedModel, requestedEffort });
    if (!sel) { receipt.accounts_skipped.push(`${account.name}: exhausted`); continue; }
    if (sel.reason === 'healthy') {
      // No -m on the request: pin the best model explicitly so the receipt
      // and the command agree on what the other account will run.
      const top = candidates(catalog.models, u.usage)[0];
      if (!top) { receipt.accounts_skipped.push(`${account.name}: exhausted`); continue; }
      const effort = pickEffort(requestedEffort, top);
      return finish({ model: top.slug, priority: priorityOf(top), modelChanged: true, effort: effort.effort, effortChanged: effort.changed, effortSource: effort.source, reason: 'account-fallback' }, account, null);
    }
    return finish({ ...sel, reason: 'account-fallback' }, account, null);
  }

  // Rung 3: pay-per-token on the best API model. OPT-IN ONLY: the operator's
  // standing posture (2026-09-05, issue 993) is OAuth subscription limits and
  // no API spend, and an OPENAI_API_KEY is ambient in Claude Code's environment
  // on this box, so the key's presence alone must never select this rung.
  if (apiLaneEnabled(env)) {
    const sel = apiCandidate(catalog.models, requestedModel, requestedEffort);
    if (sel) return finish(sel, null, [API_AUTH_CONFIG]);
  }

  // Exhausted everywhere we could prove.
  receipt.account = active.name;
  receipt.reason = 'exhausted';
  receipt.model = requestedModel;
  receipt.effort = requestedEffort;
  receipt.note = receipt.banked_resets > 0
    ? `no available model on any verified account and no API key; ${BANKED_RESET_HINT}`
    : 'no available model on any verified account and no API key';
  return receipt;
}

module.exports = {
  // constants
  USAGE_ENDPOINTS,
  CATALOG_ENDPOINT,
  REQUEST_TIMEOUT_MS,
  CATALOG_CACHE_MAX_AGE_MS,
  MAX_FALLBACK_ACCOUNTS,
  EFFORT_ORDER,
  API_AUTH_CONFIG,
  BANKED_RESET_HINT,
  // paths + auth
  codexHome,
  activeAuthPath,
  catalogCachePath,
  caamProfilesDir,
  readAuth,
  listAccounts,
  // network
  httpGetJson,
  fetchUsage,
  loadCatalog,
  readCatalogCache,
  // pure
  rateLimitState,
  evaluateUsage,
  bankedResets,
  isListed,
  availability,
  availableListed,
  candidates,
  clampEffort,
  pickEffort,
  selectModel,
  apiCandidate,
  apiLaneEnabled,
  // ccflare pool
  CCFLARE_POOL_PROFILE_PREFIX,
  CCFLARE_PROVIDER_CONFIG,
  ccflareConfig,
  ccflareGet,
  rankCcflarePools,
  ccflarePool,
  configModelProvider,
  usesCustomProvider,
  // command
  scanShell,
  parseCommand,
  rewriteCommand,
  parseArgv,
  rewriteArgv,
  shellWord,
  // entry
  resolve,
};
