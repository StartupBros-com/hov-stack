#!/usr/bin/env node
// settings-seed.js: build a settings.json seed from the tracked settings.json.
//
// Allow-list, not strip-list. A top-level key or env var not named here is dropped and
// reported, so a key bound to my machine can never leak into someone else's config by
// being new. The tracked file is a template: every home path is spelled with a literal
// `$HOME/` (`$HOME/.claude/...`, `$HOME/.local/bin/dcg`). Hook commands and the status
// line run through a shell, which expands it; env values and permission rules are read
// literally, so the seed renders every occurrence to the caller's config dir and HOME.
// The dcg hook is kept only when dcg is installed, and anything still carrying an
// unrendered `$HOME/` afterwards is dropped and reported rather than written.
//
// The private overlay (restructure plan U16) is the caller's own settings for this machine,
// <overlay>/settings.json. It is merged after the allow-list, so every key it names gets
// past it, and before the dcg rule and the rewrite, so its hooks and `$HOME/` paths are
// treated like the template's: a hook needing dcg is dropped when dcg is not installed. It
// merges the way Claude Code merges its own settings levels: objects by key, the overlay's
// value winning for anything else, and lists combined without repeats, so an overlay that
// adds a hook or a permission rule keeps the template's. An entry spelled with `$HOME/` and
// the same entry spelled with the rendered path count as one. A null removes the key it
// names, at any depth; a null in a list is a value. A value of another kind than the
// template's (a string where it has an object, an object where it has a list) is refused,
// and no seed is written.
//
// usage: node lib/settings-seed.js <src> <dst> <config-dir> <home> [<dcg-path> [<overlay>]]
// An empty <dcg-path> means dcg is not installed; an empty <overlay> means there is none.
'use strict';
const fs = require('node:fs');

const [src, dst, cfg, home, dcgPath, overlayPath] = process.argv.slice(2);
if (!src || !dst || !cfg || !home) {
  console.error('usage: settings-seed.js <src> <dst> <config-dir> <home> [dcg-path [overlay]]');
  process.exit(2);
}

const MY_HOME = '$HOME';            // the template's home token; only its `$HOME/` form is a path
const MY_CFG = '$HOME/.claude';
const MY_DCG = '$HOME/.local/bin/dcg';

const KEEP = [
  '$schema', 'permissions', 'hooks', 'env', 'attribution', 'includeCoAuthoredBy',
  'modelSettings', 'promptCacheTtl', 'subagentPromptCacheTtl', 'autoCompactEnabled',
  'autoCompactWindow', 'skillOverrides', 'sandbox',
];
const ENV_KEEP = [
  'API_TIMEOUT_MS', 'BASH_DEFAULT_TIMEOUT_MS', 'BASH_MAX_OUTPUT_LENGTH', 'BASH_MAX_TIMEOUT_MS',
  'CLAUDE_CODE_MAX_RETRIES', 'CLAUDE_CODE_RETRY_WATCHDOG', 'CLAUDE_CODE_SUBAGENT_MODEL',
  'DISABLE_ERROR_REPORTING', 'ENABLE_TOOL_SEARCH', 'CLAUDE_CODE_TOOL_MEMORY_LIMIT',
  'CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP', 'CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS',
  'CLAUDE_ENV_FILE', 'CLAUDE_CODE_PLUGIN_DIRS',
];
if (dcgPath) ENV_KEEP.push('DCG_FAIL_CLOSED');

function parse(text) {
  try { return JSON.parse(text); } catch {
    return JSON.parse(text.slice(0, text.lastIndexOf('}') + 1)); // tolerate trailing content
  }
}
const source = parse(fs.readFileSync(src, 'utf8'));

const report = { droppedKeys: [], droppedEnv: [], droppedHooks: 0, rewrites: 0, droppedBound: [] };

function render(str) {
  return str.split(MY_CFG).join(cfg).split(MY_HOME + '/').join(home + '/');
}
function rewrite(str) {
  const out = render(str);
  if (out !== str) report.rewrites += 1;
  return out;
}
// An own key even when it is `__proto__`, which plain assignment would treat as the prototype.
function put(o, k, v) {
  Object.defineProperty(o, k, { value: v, enumerable: true, writable: true, configurable: true });
}
function walk(value) {
  if (typeof value === 'string') return rewrite(value);
  if (Array.isArray(value)) return value.map(walk);
  if (value && typeof value === 'object') {
    const o = {};
    for (const [k, v] of Object.entries(value)) put(o, k, walk(v));
    return o;
  }
  return value;
}

const seed = {};
for (const key of Object.keys(source)) {
  if (KEEP.includes(key)) seed[key] = source[key];
  else report.droppedKeys.push(key);
}

if (seed.env) {
  const env = {};
  for (const [k, v] of Object.entries(seed.env)) {
    if (ENV_KEEP.includes(k)) env[k] = v;
    else report.droppedEnv.push(k);
  }
  seed.env = env;
}

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const kindOf = (v) => (Array.isArray(v) ? 'a list' : isObject(v) ? 'an object' : 'a plain value');
const key = (v) => JSON.stringify(v, (_k, x) => (typeof x === 'string' ? render(x) : x));
class Mismatch extends Error {}
function prune(v) {  // an overlay value taken as it stands: each null in it removes its key
  if (Array.isArray(v)) return v.map(prune);
  if (isObject(v)) {
    const o = {};
    for (const [k, x] of Object.entries(v)) if (x !== null) put(o, k, prune(x));
    return o;
  }
  return v;
}
function merge(base, over, trail) {
  if (kindOf(base) !== kindOf(over)) {
    throw new Mismatch(`gives ${trail} ${kindOf(over)} where the template has ${kindOf(base)}`);
  }
  if (Array.isArray(base)) {
    const out = base.slice();
    const seen = new Set(base.map(key));
    for (const v of over) {
      const k = key(v);
      if (!seen.has(k)) { seen.add(k); out.push(prune(v)); }
    }
    if (out.length > base.length) report.overlay.push(`${trail} +${out.length - base.length}`);
    return out;
  }
  if (isObject(base)) {
    const out = {};
    for (const [k, v] of Object.entries(base)) put(out, k, v);
    for (const [k, v] of Object.entries(over)) {
      const t = trail ? `${trail}.${k}` : k;
      if (v === null) {
        if (Object.hasOwn(out, k)) { report.overlay.push(`${t} removed`); delete out[k]; }
      } else if (Object.hasOwn(out, k)) {
        put(out, k, merge(out[k], v, t));
      } else {
        put(out, k, prune(v));
        report.overlay.push(t);
      }
    }
    return out;
  }
  if (JSON.stringify(base) !== JSON.stringify(over)) report.overlay.push(trail);
  return over;
}

let merged = seed;
if (overlayPath) {
  let overlay;
  try {
    overlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
  } catch (err) {
    console.error(`settings-seed: the overlay ${overlayPath} is not readable JSON (${err.message}); no seed was written`);
    process.exit(1);
  }
  if (!isObject(overlay)) {
    console.error(`settings-seed: the overlay ${overlayPath} is not a JSON object; no seed was written`);
    process.exit(1);
  }
  report.overlay = [];
  try {
    merged = merge(seed, overlay, '');
  } catch (err) {
    if (!(err instanceof Mismatch)) throw err;
    console.error(`settings-seed: the overlay ${overlayPath} ${err.message}; no seed was written`);
    process.exit(1);
  }
}

// The dcg rule, for the template's hooks and the overlay's alike. A hook shaped other than
// Claude Code's {event: [{hooks: [...]}]} is left as it is, for Claude Code to report.
if (isObject(merged.hooks)) {
  const hooks = {};
  for (const [event, groups] of Object.entries(merged.hooks)) {
    if (!Array.isArray(groups)) { put(hooks, event, groups); continue; }
    const kept = [];
    for (const group of groups) {
      if (!isObject(group) || !Array.isArray(group.hooks)) { kept.push(group); continue; }
      const entries = group.hooks.flatMap((h) => {
        const cmd = isObject(h) && typeof h.command === 'string' ? h.command : '';
        if (!cmd.includes(MY_DCG)) return [h];
        if (!dcgPath) { report.droppedHooks += 1; return []; }
        return [{ ...h, command: cmd.split(MY_DCG).join(dcgPath) }];
      });
      if (entries.length) kept.push({ ...group, hooks: entries });
    }
    if (kept.length) put(hooks, event, kept);
  }
  merged.hooks = hooks;
}

let out = walk(merged);

// Last line of defence: anything still carrying an unrendered `$HOME/` is dropped, never
// written. A bare `$HOME` with no slash (a permission rule's argument) is not a path.
function scrub(value, trail) {
  if (typeof value === 'string') {
    if (value.includes(MY_HOME + '/')) { report.droppedBound.push(trail); return undefined; }
    return value;
  }
  if (Array.isArray(value)) return value.map((v, i) => scrub(v, `${trail}[${i}]`)).filter((v) => v !== undefined);
  if (value && typeof value === 'object') {
    const o = {};
    for (const [k, v] of Object.entries(value)) {
      const s = scrub(v, trail ? `${trail}.${k}` : k);
      if (s !== undefined) put(o, k, s);
    }
    return o;
  }
  return value;
}
out = scrub(out, '');

fs.writeFileSync(dst, JSON.stringify(out, null, 2) + '\n');

const counts = (o) => Object.entries(o || {}).map(([k, v]) => `${k} ${Array.isArray(v) ? v.length : ''}`.trim()).join(', ');
console.log(`  wrote ${dst}`);
console.log(`    kept: ${Object.keys(out).join(', ')}`);
console.log(`    permissions: ${counts(out.permissions)}`);
console.log(`    hooks: ${counts(out.hooks)}`);
console.log(`    paths rewritten to ${cfg} and ${home}: ${report.rewrites}`);
if (report.droppedKeys.length) console.log(`    dropped (bound to my machine): ${report.droppedKeys.sort().join(', ')}`);
if (report.droppedEnv.length) console.log(`    dropped env: ${report.droppedEnv.sort().join(', ')}`);
if (report.droppedHooks) console.log(`    dropped hook entries needing dcg: ${report.droppedHooks}`);
if (report.droppedBound.length) console.log(`    dropped entries still carrying an unrendered $HOME/: ${report.droppedBound.join(', ')}`);
if (report.overlay) console.log(`    from the overlay ${overlayPath}: ${report.overlay.length ? report.overlay.join(', ') : 'nothing new'}`);
