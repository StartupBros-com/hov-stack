#!/usr/bin/env node
/**
 * papercut transcript backfill: record the tool failures the capture hook
 * never receives, and measure per-tool capture coverage.
 *
 * Claude Code fires PostToolUseFailure only for errors raised while a tool
 * RUNS. A call rejected before it runs -- input validation, which is where
 * the Write/Edit worktree guard lives -- comes back as a tool_result wrapped
 * in <tool_use_error> and fires no hook at all. The hooks reference says so
 * under PostToolUseFailure: "Validation rejections are returned as
 * tool_use_error results and happen before hooks run, so they fire neither
 * PreToolUse nor PostToolUseFailure." Measured over 3 days of
 * transcripts (2026-10-04): 0 of ~1,100 such results reached the store, so
 * ~2,080 "Edit the worktree copy" refusals from a stray /tmp/.git ran for four
 * weeks without one papercut record while agents wrote the refusal down as a
 * rule (dotfiles#1553). Untagged failures, which do fire the hook, were ~89%
 * captured, the rest being permission denials that denial-mine owns.
 *
 * What it ingests: tool_results that START with <tool_use_error> and have no
 * record yet. Each record is built by the hook's own record() (same redaction,
 * same signature), stamped with the transcript time, `source: "transcript"`,
 * and the tool_use_id tail `tu`, which makes a re-run append nothing.
 *
 * What it does not ingest: PreToolUse hook blocks (our guards self-log through
 * logDenial; dcg belongs to denial-mine) and permission denials (denial-mine).
 * Those are counted, not recorded.
 *
 * Coverage: every failure the hook SHOULD see (untagged, not a hook block, not
 * a permission denial, not dropped by record()'s own filters) is matched
 * against the store by session, agent, tool, time and error text, and the
 * per-tool counts go to <store>/.backfill-coverage.json. harness-doctor check
 * 19 reads that file, so a tool whose failures stop reaching the store shows
 * up as a count instead of a quiet week.
 *
 * Deletion condition: Claude Code fires PostToolUseFailure for input-validation
 * refusals; then this shrinks to the coverage measurement alone.
 *
 * Usage: papercut-backfill.js [--days N] [--dry-run] [--projects DIR] [--coverage FILE]
 * Exit:  0 done (drops, unreadable transcripts, a run skipped for another
 *        run's lock and a run without flock(1) are WARN lines; unreadable ones
 *        also land in the coverage file as scan_errors) · 2 usage or missing
 *        transcripts directory
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const papercut = require('../hooks/PostToolUseFailure/papercut-log.js');

const MATCH_WINDOW_MS = 15000; // hook record vs transcript timestamp, same call
const TAG = '<tool_use_error>';
const CHUNK = 1 << 20;
const IS_ERROR = Buffer.from('"is_error":true');
const TOOL_USE = Buffer.from('"tool_use"');

// Permission-system outcomes, all denial-mine's domain (its FALLBACK_MARKERS
// plus the approval-prompt phrasings seen in the 2026-10-04 measurement).
const PERMISSION_RE = new RegExp([
  '^Permission to use ',
  'has been denied',
  "^The user doesn't want to proceed",
  '^This command requires approval',
  '^Part of this command .{0,80}cannot be checked in advance',
  '^This Bash command contains multiple operations',
].join('|'));

function usage(msg) {
  if (msg) process.stderr.write(`papercut-backfill: ${msg}\n`);
  process.stderr.write('usage: papercut-backfill.js [--days N] [--dry-run] [--projects DIR] [--coverage FILE]\n');
  process.exit(2);
}

function parseArgs(argv) {
  const configDir = process.env.CLAUDE_CONFIG_DIR && process.env.CLAUDE_CONFIG_DIR.trim();
  const opts = {
    days: 8,
    dryRun: false,
    projects: path.join(configDir || path.join(os.homedir(), '.claude'), 'projects'),
    coverage: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--days') opts.days = Number(argv[++i]);
    else if (a === '--projects') opts.projects = argv[++i];
    else if (a === '--coverage') opts.coverage = argv[++i];
    else usage(`unknown argument: ${a}`);
  }
  if (!Number.isFinite(opts.days) || opts.days <= 0) usage('--days needs a positive number');
  if (!opts.projects) usage('--projects needs a directory');
  if (!opts.coverage) opts.coverage = path.join(papercut.storeDir(), '.backfill-coverage.json');
  return opts;
}

/** Yield each line of a file as a Buffer, reading 1 MiB at a time. */
function* lines(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(CHUNK);
    let carry = null;
    for (;;) {
      const n = fs.readSync(fd, buf, 0, CHUNK, null);
      if (n === 0) break;
      let chunk = buf.subarray(0, n);
      if (carry) { chunk = Buffer.concat([carry, chunk]); carry = null; }
      let start = 0;
      for (let nl = chunk.indexOf(10, start); nl !== -1; nl = chunk.indexOf(10, start)) {
        yield chunk.subarray(start, nl);
        start = nl + 1;
      }
      if (start < chunk.length) carry = Buffer.from(chunk.subarray(start));
    }
    if (carry && carry.length) yield carry;
  } finally {
    fs.closeSync(fd);
  }
}

function parse(buf) {
  try { return JSON.parse(buf.toString('utf8')); } catch { return null; }
}

function contentText(block) {
  const c = block.content;
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map((x) => (x && typeof x.text === 'string' ? x.text : '')).join('\n');
  return '';
}

/** Comparable error text: tags, digits and runs of whitespace folded out. */
function norm(s) {
  return String(s || '').replace(/<\/?tool_use_error>/g, '').replace(/[0-9]/g, '')
    .replace(/\s+/g, ' ').trim().slice(0, 40);
}

/**
 * Transcript files modified since the cutoff. An unreadable directory counts in
 * stats.scanErrors: coverage over a tree it could not read is incomplete, and
 * must not read as a clean week.
 */
function* transcripts(root, cutoffMs, stats) {
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) {
      stats.scanErrors += 1;
      process.stderr.write(`papercut-backfill: unreadable directory ${dir}: ${(e && e.code) || e}\n`);
      continue;
    }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) stack.push(p);
      else if (e.isFile() && e.name.endsWith('.jsonl')) {
        try { if (fs.statSync(p).mtimeMs >= cutoffMs) yield p; } catch { /* vanished */ }
      }
    }
  }
}

/** Store records from the window, indexed for the two match kinds. */
function loadStore(sinceMs) {
  const byKey = new Map();
  const tus = new Set();
  let files = [];
  try { files = fs.readdirSync(papercut.storeDir()).filter((f) => f.endsWith('.jsonl')); } catch { /* empty store */ }
  for (const f of files) {
    for (const line of lines(path.join(papercut.storeDir(), f))) {
      const r = parse(line);
      if (!r || typeof r !== 'object') continue;
      const t = Date.parse(r.ts);
      if (!(t >= sinceMs)) continue;
      // A record with a tool_use_id tail came from a transcript, and the exact
      // `tu` key alone dedupes it. Only hook-written records feed the fuzzy
      // index: matching against an earlier backfill would swallow a fresh
      // refusal of the same text within the window as "hook-captured".
      if (r.tu) { tus.add(r.tu); continue; }
      const key = `${r.session || ''}|${r.agent || ''}|${r.tool || ''}`;
      if (!byKey.has(key)) byKey.set(key, []);
      byKey.get(key).push({ t, e: norm(r.err) });
    }
  }
  return { byKey, tus };
}

/**
 * Claim the nearest unclaimed hook record for this failure. One record
 * accounts for one failure: two identical failures seconds apart with one
 * record between them are one captured and one missed, not two captured.
 */
function matched(store, rec, t) {
  const list = store.byKey.get(`${rec.session}|${rec.agent}|${rec.tool}`);
  if (!list) return false;
  const e = norm(rec.err);
  let best = null;
  for (const x of list) {
    if (x.used || x.e !== e) continue;
    const d = Math.abs(x.t - t);
    if (d <= MATCH_WINDOW_MS && (!best || d < Math.abs(best.t - t))) best = x;
  }
  if (!best) return false;
  best.used = true;
  return true;
}

const COUNTERS = ['tagged', 'backfilled', 'already', 'captured_tagged', 'dropped',
  'visible', 'visible_captured', 'filtered', 'hook_block', 'permission'];

function bump(tools, tool, key) {
  if (!tools[tool]) tools[tool] = Object.fromEntries(COUNTERS.map((k) => [k, 0]));
  tools[tool][key] += 1;
}

/** Rebuild a record() line with the transcript's time, source and tool_use tail. */
function stamp(line, ts, tu) {
  const rec = JSON.parse(line);
  rec.ts = ts;
  rec.source = 'transcript';
  rec.tu = tu;
  let out = JSON.stringify(rec) + '\n';
  if (Buffer.byteLength(out) > papercut.MAX_RECORD_BYTES) {
    rec.err = String(rec.err).slice(0, 200);
    rec.cmd = String(rec.cmd).slice(0, 80);
    out = JSON.stringify(rec) + '\n';
    if (Buffer.byteLength(out) > papercut.MAX_RECORD_BYTES) return null;
  }
  return out;
}

function scanFile(file, cutoffMs, store, tools, dryRun) {
  // Pass 1: the failures. Most transcripts have none and cost one read.
  const failures = [];
  for (const line of lines(file)) {
    if (line.indexOf(IS_ERROR) === -1) continue;
    const r = parse(line);
    if (!r || r.type !== 'user' || !r.message || !Array.isArray(r.message.content)) continue;
    const t = Date.parse(r.timestamp);
    if (!(t >= cutoffMs)) continue;
    for (const b of r.message.content) {
      if (b && b.type === 'tool_result' && b.is_error === true && b.tool_use_id) {
        failures.push({ id: b.tool_use_id, text: contentText(b), r, t });
      }
    }
  }
  if (!failures.length) return;

  // Pass 2: the tool_use blocks those failures answer, parsing only lines that name one.
  const wanted = new Map(failures.map((f) => [f.id, null]));
  const ids = [...wanted.keys()].map((id) => [id, Buffer.from(id)]);
  for (const line of lines(file)) {
    if (line.indexOf(TOOL_USE) === -1) continue;
    if (!ids.some(([, needle]) => line.indexOf(needle) !== -1)) continue;
    const r = parse(line);
    if (!r || r.type !== 'assistant' || !r.message || !Array.isArray(r.message.content)) continue;
    for (const b of r.message.content) {
      if (b && b.type === 'tool_use' && wanted.has(b.id)) wanted.set(b.id, b);
    }
  }

  for (const f of failures) {
    const use = wanted.get(f.id);
    const tool = (use && use.name) || 'unknown';
    const text = f.text.trimStart();
    const tagged = text.startsWith(TAG);
    if (!tagged) {
      if (text.startsWith('PreToolUse:')) { bump(tools, tool, 'hook_block'); continue; }
      if (PERMISSION_RE.test(text)) { bump(tools, tool, 'permission'); continue; }
    }
    const line = papercut.record({
      tool_name: tool,
      tool_input: (use && use.input) || {},
      error: tagged ? text.slice(TAG.length).replace(/<\/tool_use_error>\s*$/, '').trim() : text,
      cwd: f.r.cwd || '',
      session_id: f.r.sessionId || '',
      agent_id: f.r.agentId || '',
    });
    if (!line) { bump(tools, tool, 'filtered'); continue; }
    const rec = JSON.parse(line);
    if (!tagged) {
      bump(tools, tool, 'visible');
      if (matched(store, rec, f.t)) bump(tools, tool, 'visible_captured');
      continue;
    }
    bump(tools, tool, 'tagged');
    const tu = String(f.id).slice(-12);
    if (store.tus.has(tu)) { bump(tools, tool, 'already'); continue; }
    if (matched(store, rec, f.t)) { bump(tools, tool, 'captured_tagged'); continue; }
    const out = stamp(line, new Date(f.t).toISOString(), tu);
    if (!out || (!dryRun && !papercut.appendRecord(f.r.cwd || '', out, { keepMtime: true }))) { bump(tools, tool, 'dropped'); continue; }
    store.tus.add(tu);
    bump(tools, tool, 'backfilled');
  }
}

function writeCoverage(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

const LOCKED = 'PAPERCUT_BACKFILL_LOCKED';

/**
 * One writing run at a time: two overlapping runs (the weekly and a manual
 * seed) each load the store before the other appends, and both write the same
 * tool_use_id. The lock is a kernel flock(2) on <store>/.backfill.lock, taken
 * through flock(1) by re-running this script under it with LOCKED set. The
 * kernel holds it for exactly the locked run's lifetime, so a killed run
 * leaves nothing to take over and a pid the kernel hands out again holds
 * nothing (pro-gate round 2 on dotfiles#1560: a by-name takeover of a dead
 * holder's file could remove the live lock a concurrent run had just linked,
 * and a pid-only liveness check read a reused pid as a live holder). The
 * file's content, the locked run's pid, is a diagnostic for the skip line and
 * never a decision input. Without flock(1) on PATH (macOS; harness-weekly
 * runs under systemd) the run proceeds unlocked with a WARN: the tool_use_id
 * dedupe makes two overlapping runs at worst append the same records.
 *
 * Returns null when the caller is to run the scan itself (the lock is held,
 * or there is no flock), else the exit code the locked run ended with.
 */
function runLocked(lock, argv) {
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  const r = spawnSync('flock', ['--nonblock', '--conflict-exit-code', '75', '--no-fork', lock, process.execPath, __filename, ...argv],
    { stdio: 'inherit', env: { ...process.env, [LOCKED]: '1' } });
  if (r.error) {
    if (r.error.code !== 'ENOENT') throw r.error;
    process.stdout.write('WARN papercut backfill: flock(1) not found; running without the single-writer lock\n');
    return null;
  }
  if (r.status !== 75) return r.status === null ? 1 : r.status;
  let holder = '';
  try { holder = fs.readFileSync(lock, 'utf8').trim(); } catch { /* no pid to name */ }
  process.stdout.write(`WARN papercut backfill: skipped, another run${/^\d+$/.test(holder) ? ` (pid ${holder})` : ''} holds ${lock}\n`);
  return 0;
}

function main(argv) {
  const opts = parseArgs(argv);
  if (!fs.existsSync(opts.projects)) usage(`no transcripts directory at ${opts.projects}`);
  if (!opts.dryRun) {
    const lock = path.join(papercut.storeDir(), '.backfill.lock');
    if (process.env[LOCKED] !== '1') {
      const code = runLocked(lock, argv);
      if (code !== null) { process.exitCode = code; return null; }
    } else {
      try { fs.writeFileSync(lock, String(process.pid)); } catch { /* diagnostic only */ }
    }
  }
  return scanAll(opts);
}

function scanAll(opts) {
  const now = Date.now();
  const cutoffMs = now - opts.days * 86400000;
  const store = loadStore(cutoffMs - 86400000);
  const tools = {};
  const stats = { scanErrors: 0 };
  let files = 0;
  for (const file of transcripts(opts.projects, cutoffMs, stats)) {
    files += 1;
    try { scanFile(file, cutoffMs, store, tools, opts.dryRun); } catch (e) {
      stats.scanErrors += 1;
      process.stderr.write(`papercut-backfill: skipped ${file}: ${e && e.message ? e.message : e}\n`);
    }
  }
  const totals = Object.fromEntries(COUNTERS.map((k) => [k, 0]));
  for (const c of Object.values(tools)) for (const k of COUNTERS) totals[k] += c[k];
  const data = { generated_at: new Date(now).toISOString(), days: opts.days, dry_run: opts.dryRun, transcripts: files,
    scan_errors: stats.scanErrors, totals, tools };
  if (!opts.dryRun) writeCoverage(opts.coverage, data);

  const verb = opts.dryRun ? 'would backfill' : 'backfilled';
  process.stdout.write(`papercut backfill: ${files} transcripts, last ${opts.days}d: ${verb} ${totals.backfilled} `
    + `of ${totals.tagged} <tool_use_error> results (${totals.already} already recorded, `
    + `${totals.captured_tagged} hook-captured); hook-visible failures captured `
    + `${totals.visible_captured}/${totals.visible}\n`);
  const rows = Object.entries(tools).filter(([, c]) => c.tagged || c.visible)
    .sort((a, b) => (b[1].tagged + b[1].visible) - (a[1].tagged + a[1].visible));
  for (const [tool, c] of rows) {
    process.stdout.write(`  ${tool}: tool_use_error ${c.tagged} (${verb} ${c.backfilled}), `
      + `hook-visible ${c.visible_captured}/${c.visible} captured\n`);
  }
  if (totals.dropped) {
    process.stdout.write(`WARN papercut backfill: ${totals.dropped} record(s) dropped (store file over its size cap, `
      + 'or a record too large to append atomically)\n');
  }
  if (stats.scanErrors) {
    process.stdout.write(`WARN papercut backfill: ${stats.scanErrors} transcript director(ies) or file(s) unreadable; `
      + 'coverage is incomplete\n');
  }
  return data;
}

module.exports = { main, norm, lines, PERMISSION_RE };

if (require.main === module) main(process.argv.slice(2));
