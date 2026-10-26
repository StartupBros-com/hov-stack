#!/usr/bin/env node
'use strict';
/**
 * cross-model-catalog-check — standalone auditor behind harness-doctor's
 * check 33 (#1355 / #1356 round 3).
 *
 * Extracted from harness-doctor.sh's inline bash block: the review found
 * that block re-deriving policy (catalog freshness, model selectability,
 * plugin-version resolution) the harness already owns in one place
 * (hooks/lib/codex-model-resolver.js). This script owns that
 * comparison; the doctor becomes a thin `timeout` + `jq` consumer of its
 * JSON (same shape as memory-audit.py / skills-beads-sweep-check.py /
 * wf-pin-audit.py --json elsewhere in this doctor).
 *
 * Contract: always prints exactly one JSON object to stdout and exits 0 —
 * findings are data, not an exit code; the doctor turns findings into WARNs.
 * A CLI usage error (bad flag, unparseable --now) exits 2 with a message on
 * stderr, before any JSON is printed. Every discovered repo lands in exactly
 * one of repos.checked / skipped_other_peer / skipped_no_plugin / unreadable,
 * and those four always sum to repos.discovered (the doctor checks the sum).
 *
 * "One resolver, two entry points"
 * (docs/solutions/best-practices/pick-the-best-available-model-from-live-
 * catalog-and-per-meter-usage.md): the served/selectable model set and its
 * ranking come from hooks/lib/codex-model-resolver.js's exported
 * readCatalogCache/availableListed/candidates/isListed — never re-derived
 * here. "Selectable" means an explicit pin the ChatGPT-login (OAuth) lane
 * can keep: availableListed(), including models with upgrade pointers.
 * Recommended replacements use candidates(): ranked, deprecations followed. The
 * resolver's supported_in_api filter belongs only to its opt-in API-key lane
 * (apiCandidate, CODEX_PICK_API_LANE=1) and is deliberately not applied here.
 */

const fs = require('node:fs');
const path = require('node:path');

const resolver = require(path.join(path.dirname(fs.realpathSync(__filename)), '..', 'hooks', 'lib', 'codex-model-resolver.js'));

const DAY_MS = 24 * 60 * 60 * 1000;
const STALE_DAYS = 30;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const FLAGS = {
  '--home': 'home',
  '--sites-root': 'sitesRoot',
  '--dotfiles-repo': 'dotfilesRepo',
  '--catalog': 'catalog',
  '--registry': 'registry',
  '--now': 'now',
};

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const key = FLAGS[arg];
    if (!key) {
      throw new Error(`unrecognized flag: ${arg}`);
    }
    const val = argv[i + 1];
    if (val === undefined) {
      throw new Error(`${arg} requires a value`);
    }
    out[key] = val;
    i += 1;
  }
  return out;
}

function resolveOptions(argv, env) {
  const opts = parseArgs(argv);
  const home = opts.home || env.HOME || require('node:os').homedir();
  let now = Date.now();
  if (opts.now !== undefined) {
    // An unparseable --now would be NaN, and every staleness comparison
    // against NaN is false: the catalog would read fresh forever.
    now = Date.parse(opts.now);
    if (!Number.isFinite(now)) throw new Error(`--now is not a parseable timestamp: ${opts.now}`);
  }
  return {
    home,
    sitesRoot: opts.sitesRoot || path.join(home, 'SITES'),
    dotfilesRepo: opts.dotfilesRepo || env.DOTFILES_REPO || path.join(home, 'dotfiles'),
    catalogPath: opts.catalog || path.join(home, '.codex', 'models_cache.json'),
    registryPath: opts.registry || path.join(home, '.claude', 'plugins', 'installed_plugins.json'),
    now,
  };
}

// ---------------------------------------------------------------------------
// Filesystem helpers — every read is wrapped so "absent" and "present but
// unreadable" are distinguished (finding #1/#2): a bare fs.existsSync/readFileSync
// pair conflates EACCES/EISDIR with ENOENT, which is exactly the bug.
// ---------------------------------------------------------------------------

// Only ENOENT and ENOTDIR prove a path absent. Any other stat error (EACCES
// from a parent directory without search permission, ELOOP, EIO) means the
// path may well exist and could not be inspected. Round 4: a catch-all here
// folded an unsearchable .compound-engineering/ into "no config files", so
// the repo silently resolved to the plugin default and counted as checked.
const ABSENT_CODES = new Set(['ENOENT', 'ENOTDIR']);

/** { st, absent, error }: st is the Stats on success; absent is true only on
 * ENOENT/ENOTDIR; any other failure leaves st null with its error code. */
function statState(p) {
  try {
    return { st: fs.statSync(p), absent: false, error: null };
  } catch (e) {
    if (ABSENT_CODES.has(e.code)) return { st: null, absent: true, error: null };
    return { st: null, absent: false, error: e.code || e.message };
  }
}

function realpathSafe(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
}

/** { exists, readable, raw, error } for a plain file. `exists` means "not
 * proven absent": a stat failure other than ENOENT/ENOTDIR reports
 * exists: true, readable: false, with that failure's code. */
function readFileState(p) {
  const s = statState(p);
  if (s.absent) return { exists: false, readable: false, raw: '', error: null };
  if (!s.st) return { exists: true, readable: false, raw: '', error: s.error };
  try {
    const raw = fs.readFileSync(p, 'utf8');
    return { exists: true, readable: true, raw, error: null };
  } catch (e) {
    return { exists: true, readable: false, raw: '', error: e.code || e.message };
  }
}

/** Directory listing, distinguishing "does not exist" from "unreadable"
 * (same "not proven absent" meaning of `exists` as readFileState). */
function readDirState(p) {
  const s = statState(p);
  if (s.absent) return { exists: false, readable: false, names: [], error: null };
  if (!s.st) return { exists: true, readable: false, names: [], error: s.error };
  try {
    const names = fs.readdirSync(p);
    return { exists: true, readable: true, names, error: null };
  } catch (e) {
    return { exists: true, readable: false, names: [], error: e.code || e.message };
  }
}

// ---------------------------------------------------------------------------
// CE config yaml reader — flat `key: value` scalars only (see
// skills/ce-setup/references/config-template.yaml), same contract as the
// bash `_cm_key` awk it replaces: first active (non-comment, non-empty)
// value for the key, quotes stripped.
// ---------------------------------------------------------------------------

function ceKey(raw, key) {
  const re = new RegExp(`^[ \\t]*${key}[ \\t]*:[ \\t]*(.*)$`);
  for (const line of raw.split('\n')) {
    if (/^[ \t]*#/.test(line)) continue;
    const m = re.exec(line);
    if (!m) continue;
    let v = m[1].replace(/[ \t]*#.*$/, '').trim();
    v = v.replace(/^["']|["']$/g, '');
    if (v.length > 0) return v;
  }
  return '';
}

// ---------------------------------------------------------------------------
// Catalog classification (finding #6, demoted "staleness" + "empty vs
// missing" items)
// ---------------------------------------------------------------------------

function classifyCatalog(catalogPath, nowMs) {
  const findings = [];
  const unreadable = (detail) => {
    findings.push({ code: 'catalog-unreadable', repo: null, message: `codex model catalog unreadable: ${catalogPath} (${detail}) — run \`codex\` once to refresh it` });
    return { state: 'unreadable', ageDays: null, served: [], selectable: [], modelsBySlug: new Map(), findings };
  };
  const s = statState(catalogPath);
  if (s.absent) {
    findings.push({ code: 'catalog-missing', repo: null, message: `codex model catalog missing: ${catalogPath} — run \`codex\` once to refresh it` });
    return { state: 'missing', ageDays: null, served: [], selectable: [], modelsBySlug: new Map(), findings };
  }
  if (!s.st) return unreadable(s.error);
  let raw;
  try {
    raw = fs.readFileSync(catalogPath, 'utf8');
  } catch (e) {
    return unreadable(e.code || e.message);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return unreadable('malformed JSON');
  }
  if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.models) || parsed.models.length === 0) {
    findings.push({ code: 'catalog-empty', repo: null, message: `codex model catalog is empty: ${catalogPath} — run \`codex\` once to refresh it` });
    return { state: 'empty', ageDays: null, served: [], selectable: [], modelsBySlug: new Map(), findings };
  }

  // readCatalogCache re-reads the same file, so it returns null only when that
  // second read or parse fails — which the checks above just ruled out unless
  // the file changed in between. Fall back to the payload parsed here rather
  // than turning that race into a spurious "no fetched_at".
  const cache = resolver.readCatalogCache(catalogPath, nowMs);
  const models = cache ? cache.models : parsed.models;
  const fetchedAtRaw = cache ? cache.fetchedAt : (typeof parsed.fetched_at === 'string' ? parsed.fetched_at : null);
  const modelsBySlug = new Map(models.filter((m) => m && typeof m.slug === 'string').map((m) => [m.slug, m]));
  const served = [...modelsBySlug.keys()];

  // Match selectModel's explicit-pin policy: available listed models stay,
  // upgrade pointer or not. Only recommendations follow upgrades and rank.
  // Synthetic always-open usage neutralizes account quota for both helpers:
  // no per-model additional_rate_limits entry matches, so every listed
  // model uses the open main meter. This audits catalog policy, not quota.
  const SYNTHETIC_USAGE = { rate_limit: { allowed: true } };
  const ranked = resolver.candidates(models, SYNTHETIC_USAGE);
  const selectable = resolver.availableListed(models, SYNTHETIC_USAGE).map((m) => m.slug);

  let ageDays = null;
  let state = 'ok';
  const fetchedAtMs = fetchedAtRaw ? Date.parse(fetchedAtRaw) : NaN;
  if (!Number.isFinite(fetchedAtMs)) {
    state = 'no-fetched-at';
    const mtimeIso = s.st.mtime.toISOString();
    findings.push({
      code: 'catalog-no-fetched-at',
      repo: null,
      message: `codex model catalog has no parseable fetched_at (${catalogPath}); mtime ${mtimeIso} is a hint only — run \`codex\` once to refresh it`,
    });
  } else if (nowMs - fetchedAtMs < 0) {
    // Mirrors readCatalogCache's own freshness guard (`nowMs - fetchedAt >= 0`):
    // a fetched_at in the future is clock skew or a corrupted cache, never a
    // fresh catalog, and a negative age must not reach the clean line.
    state = 'future';
    findings.push({
      code: 'catalog-future-fetched-at',
      repo: null,
      message: `codex model catalog fetched_at ${new Date(fetchedAtMs).toISOString()} is in the future (${catalogPath}) — clock skew or a corrupted cache; run \`codex\` once to refresh it`,
    });
  } else {
    ageDays = Math.floor((nowMs - fetchedAtMs) / DAY_MS);
    if (ageDays >= STALE_DAYS) {
      state = 'stale';
      findings.push({ code: 'catalog-stale', repo: null, message: `codex model catalog is ${ageDays} days old (${catalogPath}) — run \`codex\` once to refresh it` });
    }
  }

  return { state, ageDays, served, selectable, selectableRanked: ranked, modelsBySlug, findings };
}

/** Why a slug cannot be kept as an explicit pin; null when selectable.
 * With the auditor's always-open usage, every listed model is available,
 * including deprecated models. Upgrade forwarding is recommendation-only. */
function reasonNotSelectable(slug, catalog) {
  const m = catalog.modelsBySlug.get(slug);
  if (!m) return 'not in the catalog payload';
  if (!resolver.isListed(m)) return 'hidden';
  return null;
}

// ---------------------------------------------------------------------------
// Plugin registry + per-installPath script (finding #4)
// ---------------------------------------------------------------------------

function loadRegistry(registryPath) {
  const file = readFileState(registryPath);
  if (!file.exists) return { ok: false, reason: 'missing' };
  if (!file.readable) return { ok: false, reason: 'unreadable' };
  let parsed;
  try {
    parsed = JSON.parse(file.raw);
  } catch {
    return { ok: false, reason: 'unreadable' };
  }
  const entries = parsed && parsed.plugins && Array.isArray(parsed.plugins['compound-engineering@every-marketplace'])
    ? parsed.plugins['compound-engineering@every-marketplace']
    : [];
  return { ok: true, entries };
}

// Matches the M_CODEX="..." (and M_CLAUDE=/M_GROK=/M_COMPOSER=) mapping lines
// themselves, never a hardcoded id — the whole point of this check is to
// notice when one of those lines changes.
const PEER_LINE = /^M_([A-Z0-9_]+)="([^"]*)"/gm;

// Peer targets that have no M_<PEER>= line: the plugin's route_model()
// prints 'auto' for cursor and opencode instead of reading a constant
// (cross-model-adversarial-review.sh, 3.28.2), and
// references/cross-model-review.md lists the six targets as codex, claude,
// grok, cursor, composer, opencode.
const NO_MODEL_TARGETS = ['cursor', 'opencode'];

function loadPluginScript(installPath, cache) {
  if (cache.has(installPath)) return cache.get(installPath);
  const scriptPath = path.join(installPath, 'skills', 'ce-code-review', 'scripts', 'cross-model-adversarial-review.sh');
  const file = readFileState(scriptPath);
  let result;
  if (!file.readable) {
    result = { ok: false, reason: 'unreadable', error: file.exists ? file.error : 'ENOENT', scriptPath, peers: new Map(), targets: new Set() };
  } else {
    const peers = new Map();
    let m;
    PEER_LINE.lastIndex = 0;
    while ((m = PEER_LINE.exec(file.raw))) {
      peers.set(m[1].toLowerCase(), m[2]);
    }
    // A target is the first segment of an M_ key: M_GROK_CURSOR is grok's
    // cursor route, not a target of its own.
    const targets = new Set([...peers.keys()].map((k) => k.split('_')[0]).concat(NO_MODEL_TARGETS));
    const ok = peers.has('codex');
    result = { ok, reason: ok ? null : 'no-codex-line', error: null, scriptPath, peers, targets };
  }
  cache.set(installPath, result);
  return result;
}

/** One-line description of why a plugin script cannot supply its codex
 * default or validate peer names. */
function scriptProblem(script) {
  if (script.reason === 'no-codex-line') return `plugin script has no M_CODEX= line (${script.scriptPath})`;
  return `could not read the plugin script (${script.scriptPath}: ${script.error})`;
}

/** The applicable compound-engineering entry for a repo at real path P:
 * matching `local`, then matching `project`, then `user`, else none.
 * Both repo-scoped entries require exact real projectPath equality with P;
 * the chosen script supplies both the model default and peer validation. */
function resolveApplicablePlugin(repoRealPath, ctx) {
  const reg = ctx.registry;
  if (!reg.ok) return { ok: false, reason: reg.reason };
  const matchingScope = (scope) => reg.entries.find((e) => e && e.scope === scope && e.projectPath && realpathSafe(e.projectPath) === repoRealPath);
  const entry = matchingScope('local') || matchingScope('project') || reg.entries.find((e) => e && e.scope === 'user');
  if (!entry || !entry.installPath) return { ok: false, reason: 'no-entry' };
  const script = loadPluginScript(entry.installPath, ctx.scriptCache);
  return { ok: true, entry, script };
}

/** The missing/unreadable-registry finding, once per run. */
function warnRegistryOnce(ctx, findings, reason) {
  if (ctx.registryWarned.has(true)) return;
  ctx.registryWarned.add(true);
  findings.push({
    code: 'registry-unreadable',
    repo: null,
    message: `plugin registry ${reason}: ${ctx.registryPath} — cross_model_peer values cannot be validated and repos without their own cross_model_model pin cannot be checked; repair the registry or pin cross_model_model per repo`,
  });
}

// ---------------------------------------------------------------------------
// Peer resolution (finding #3): mirrors the plugin's own layering, CE's
// "ordinary-key rule" (~/.claude/plugins/cache/every-marketplace/
// compound-engineering/3.28.2/skills/ce-code-review/references/
// cross-model-review.md): the first active SUPPORTED target wins; an invalid
// value continues to the next layer, then to the skill default, codex.
//
// "Supported" is checked against the applicable plugin script's targets
// (loadPluginScript). When no applicable script can be read — no registry
// entry applies to the repo, the script is unreadable, or it has no M_CODEX=
// line — a non-codex value cannot be validated: it is taken at face value as
// an other-peer skip, with a peer-unverified finding so the skip is never
// silent. When the registry itself is missing or unreadable, the one
// registry finding says so instead.
// ---------------------------------------------------------------------------

/** Why a repo has no applicable plugin entry, for finding text. */
function noEntryProblem(ctx) {
  return `no compound-engineering entry in the plugin registry (${ctx.registryPath}) applies to this repo`;
}

function resolvePeer(repoPath, repoRealPath, layers, ctx) {
  const findings = [];
  const name = path.basename(repoPath);
  const plugin = resolveApplicablePlugin(repoRealPath, ctx);
  const canValidate = plugin.ok && plugin.script.ok;
  let resolved = null;
  for (const layer of layers) {
    const v = (layer.value || '').trim();
    if (!v) continue;
    if (v === 'codex') {
      resolved = 'codex';
      break;
    }
    if (canValidate) {
      if (plugin.script.targets.has(v)) {
        resolved = v;
        break;
      }
      findings.push({
        code: 'peer-invalid',
        repo: repoPath,
        message: `${name}: ${layer.label} sets cross_model_peer '${v}', which the installed compound-engineering plugin (${plugin.script.scriptPath}) does not recognize — resolution continues to the next layer`,
      });
      continue;
    }
    resolved = v;
    if (plugin.ok || plugin.reason === 'no-entry') {
      const why = plugin.ok ? scriptProblem(plugin.script) : noEntryProblem(ctx);
      findings.push({
        code: 'peer-unverified',
        repo: repoPath,
        message: `${name}: ${layer.label} sets cross_model_peer '${v}', which could not be validated: ${why} — skipped as an other-peer repo`,
      });
    } else {
      warnRegistryOnce(ctx, findings, plugin.reason);
    }
    break;
  }
  if (resolved === null) resolved = 'codex';
  return { resolved, findings, plugin };
}

module.exports = { parseArgs, resolveOptions, statState, ceKey, classifyCatalog, reasonNotSelectable, loadRegistry, loadPluginScript, resolveApplicablePlugin, resolvePeer, readFileState, readDirState, audit, main };

// ---------------------------------------------------------------------------
// Per-repo audit. Returns exactly one bucket: checked, skipped_other_peer,
// skipped_no_plugin, or unreadable.
// ---------------------------------------------------------------------------

function auditRepo(repoPath, isDotfiles, ctx) {
  const findings = [];
  const name = path.basename(repoPath);
  // Discovery inspects SITES directories, but always includes the required
  // dotfiles path. Prove that path is a readable directory before treating
  // absent config files as permission to use the plugin default.
  if (isDotfiles) {
    const dir = readDirState(repoPath);
    if (!dir.readable) {
      const problem = !dir.exists ? 'required dotfiles directory is missing'
        : dir.error === 'ENOTDIR' ? 'required dotfiles path is not a directory'
          : `required dotfiles directory could not be read (${dir.error})`;
      findings.push({ code: 'repo-unreadable', repo: repoPath, message: `${name}: ${problem}: ${repoPath}` });
      return { bucket: 'unreadable', findings, dotfilesSource: 'dotfiles path unreadable' };
    }
  }
  const repoRealPath = realpathSafe(repoPath);
  const localFile = readFileState(path.join(repoPath, '.compound-engineering', 'config.local.yaml'));
  const mainFile = readFileState(path.join(repoPath, '.compound-engineering', 'config.yaml'));
  let configUnreadable = false;
  for (const [label, file] of [['config.local.yaml', localFile], ['config.yaml', mainFile]]) {
    if (file.exists && !file.readable) {
      configUnreadable = true;
      findings.push({ code: 'config-unreadable', repo: repoPath, message: `${name}: ${label} could not be read (${file.error})` });
    }
  }
  // Either layer unreadable leaves the effective peer and model unknowable
  // (an unreadable config.local.yaml may shadow everything below it), so the
  // repo is never compared on a partial read.
  if (configUnreadable) return { bucket: 'unreadable', findings, dotfilesSource: 'config unreadable' };

  const peerResult = resolvePeer(repoPath, repoRealPath, [
    { label: 'config.local.yaml', value: ceKey(localFile.raw, 'cross_model_peer') },
    { label: 'config.yaml', value: ceKey(mainFile.raw, 'cross_model_peer') },
  ], ctx);
  findings.push(...peerResult.findings);
  if (peerResult.resolved !== 'codex') {
    return { bucket: 'skipped_other_peer', findings, dotfilesSource: 'other-peer, skipped' };
  }

  const modelLocal = ceKey(localFile.raw, 'cross_model_model');
  const modelMain = ceKey(mainFile.raw, 'cross_model_model');
  if (modelLocal && modelMain && modelLocal !== modelMain) {
    findings.push({ code: 'local-shadows-main', repo: repoPath, message: `${name}: config.local.yaml shadows cross_model_model ('${modelLocal}') over config.yaml's '${modelMain}'` });
  }

  let effective;
  let source;
  if (modelLocal) {
    effective = modelLocal;
    source = 'config.local.yaml';
  } else if (modelMain) {
    effective = modelMain;
    source = 'config.yaml';
  } else {
    const plugin = peerResult.plugin;
    if (!plugin.ok) {
      if (plugin.reason === 'unreadable') {
        warnRegistryOnce(ctx, findings, plugin.reason);
        return { bucket: 'unreadable', findings, dotfilesSource: 'registry unreadable' };
      }
      if (plugin.reason === 'missing') {
        warnRegistryOnce(ctx, findings, plugin.reason);
      } else {
        // A readable registry with no applicable entry leaves this repo's
        // default unknown; as a silent skip, another repo's check could still
        // print the clean line (confirmed by the round-3 review's validator).
        findings.push({ code: 'plugin-no-entry', repo: repoPath, message: `${name}: ${noEntryProblem(ctx)}, so the plugin's codex default cannot be resolved — pin cross_model_model or install the plugin for this repo` });
      }
      return { bucket: 'skipped_no_plugin', findings, dotfilesSource: 'no plugin' };
    }
    if (!plugin.script.ok) {
      // Per repo, never deduped: every repo that needs this default is one
      // the check could not compare, and the doctor names each of them.
      findings.push({ code: 'plugin-default-unreadable', repo: repoPath, message: `${name}: the plugin's codex default is unknown — ${scriptProblem(plugin.script)}` });
      return { bucket: 'unreadable', findings, dotfilesSource: 'plugin default unknown' };
    }
    effective = plugin.script.peers.get('codex');
    source = `plugin-default ${plugin.entry.version}`;
  }

  if (ctx.catalog.state !== 'missing' && ctx.catalog.state !== 'unreadable' && ctx.catalog.state !== 'empty') {
    if (!ctx.catalog.served.includes(effective)) {
      const best = ctx.catalog.selectableRanked && ctx.catalog.selectableRanked[0];
      findings.push({
        code: 'model-unserved',
        repo: repoPath,
        message: `${name}: cross_model_model '${effective}' (${source}) is not in the served codex catalog — best selectable: ${best ? best.slug : 'none'}, ${ctx.catalog.selectable.length} selectable slug(s)`,
      });
    } else if (!ctx.catalog.selectable.includes(effective)) {
      const reason = reasonNotSelectable(effective, ctx.catalog);
      findings.push({
        code: 'model-not-selectable',
        repo: repoPath,
        message: `${name}: cross_model_model '${effective}' (${source}) is served but not selectable — ${reason}`,
      });
    }
  }

  return { bucket: 'checked', findings, effective, source };
}

// ---------------------------------------------------------------------------
// Repo discovery (finding #2). Returns the repos to audit plus the count of
// SITES entries that could not be inspected (each already named by a
// finding), so audit() can count them in repos.unreadable.
// ---------------------------------------------------------------------------

function discoverRepos(ctx, findings) {
  const repos = [{ path: ctx.dotfilesRepo, isDotfiles: true }];
  let unreadable = 0;
  const unenterable = (name, repoPath, what, error) => {
    unreadable += 1;
    findings.push({ code: 'repo-unreadable', repo: repoPath, message: `${name}: ${what} (${error})` });
  };
  const dir = readDirState(ctx.sitesRoot);
  // No SITES root at all is not an error: many hosts have none.
  if (!dir.exists) return { repos, unreadable };
  if (!dir.readable) {
    findings.push({ code: 'sites-unreadable', repo: null, message: `SITES root exists but could not be listed: ${ctx.sitesRoot} (${dir.error})` });
    return { repos, unreadable };
  }
  const dotfilesReal = realpathSafe(ctx.dotfilesRepo);
  for (const name of [...dir.names].sort()) {
    const repoPath = path.join(ctx.sitesRoot, name);
    const s = statState(repoPath);
    if (s.absent) continue; // e.g. a dangling symlink
    if (!s.st) {
      unenterable(name, repoPath, 'repo directory could not be inspected', s.error);
      continue;
    }
    if (!s.st.isDirectory()) continue;
    // The dotfiles checkout is always audited once, as the dotfiles repo; a
    // SITES entry resolving to the same directory must not count it twice.
    if (realpathSafe(repoPath) === dotfilesReal) continue;
    // Confirm the repo directory itself is enterable (readdir succeeds)
    // BEFORE looking inside it for .compound-engineering, so "cannot be
    // entered" is never folded into "no .compound-engineering here" — the
    // absent-vs-unreadable conflation findings #1/#2 exist to catch, one
    // level down.
    const entered = readDirState(repoPath);
    if (!entered.readable) {
      unenterable(name, repoPath, 'repo directory exists but could not be entered', entered.error);
      continue;
    }
    const ce = statState(path.join(repoPath, '.compound-engineering'));
    if (ce.absent) continue;
    if (!ce.st) {
      unenterable(name, repoPath, '.compound-engineering could not be inspected', ce.error);
      continue;
    }
    if (!ce.st.isDirectory()) continue;
    repos.push({ path: repoPath, isDotfiles: false });
  }
  return { repos, unreadable };
}

// ---------------------------------------------------------------------------
// Top-level audit
// ---------------------------------------------------------------------------

function audit(opts) {
  const findings = [];
  const catalog = classifyCatalog(opts.catalogPath, opts.now);
  findings.push(...catalog.findings);

  const ctx = {
    catalog,
    registry: loadRegistry(opts.registryPath),
    registryPath: opts.registryPath,
    scriptCache: new Map(),
    registryWarned: new Set(),
  };

  const discovery = discoverRepos(opts, findings);
  const counts = { checked: 0, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: discovery.unreadable };
  let dotfilesModel = null;
  let dotfilesSource = '';

  for (const repo of discovery.repos) {
    const res = auditRepo(repo.path, repo.isDotfiles, ctx);
    if (!Object.prototype.hasOwnProperty.call(counts, res.bucket)) {
      throw new Error(`auditRepo returned an unknown bucket '${res.bucket}' for ${repo.path}`);
    }
    findings.push(...res.findings);
    counts[res.bucket] += 1;
    if (repo.isDotfiles) {
      if (res.bucket === 'checked') {
        dotfilesModel = res.effective;
        dotfilesSource = res.source;
      } else {
        dotfilesSource = res.dotfilesSource;
      }
    }
  }

  // No floor finding here: harness-doctor.sh keeps its own
  // `floor "$_cm_checked" 1 "cross-model codex repos"` call (the demoted
  // "zero repos" item asks for this explicitly) so repos.checked alone is
  // the floor's input and this auditor does not duplicate that WARN.

  return {
    findings,
    repos: { ...counts, discovered: discovery.repos.length + discovery.unreadable },
    catalog: { path: opts.catalogPath, state: catalog.state, age_days: catalog.ageDays, served: catalog.served, selectable: catalog.selectable },
    dotfiles: { model: dotfilesModel, source: dotfilesSource },
  };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function main(argv, env) {
  let opts;
  try {
    opts = resolveOptions(argv, env);
  } catch (e) {
    process.stderr.write(`cross-model-catalog-check: ${e.message}\n`);
    process.exitCode = 2;
    return;
  }
  const result = audit(opts);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = 0;
}

if (require.main === module) {
  main(process.argv.slice(2), process.env);
}
