'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');
const { createHash } = require('node:crypto');

const STATUSLINE = path.resolve(__dirname, '../../statusline-stack/local-statusline.mjs');
const ANSI = /\x1b\[[0-9;]*m/g;

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'statusline-route-'));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  const curl = path.join(bin, 'curl');
  fs.writeFileSync(curl, `#!/bin/sh
printf '%s\\n' "$*" >> "$CURL_LOG"
case "$CURL_MODE" in
  gpt) printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"acct-a","paused":false,"windows":[{"window":"five_hour","utilization":5}]}}}' ;;
  claude) printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"max-acct-c","paused":false,"windows":[{"window":"five_hour","utilization":12},{"window":"seven_day","utilization":91}]}}}' ;;
  unknownsession) printf '%s' '{"success":true,"data":{"status":"unknown"}}' ;;
  healthysnapshot) printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"acct-healthy","paused":false,"rateLimitStatus":"allowed (228m)","windows":[{"window":"five_hour","utilization":10}]}}}' ;;
  ratelimited) printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"acct-limited","paused":false,"rateLimitStatus":"Rate limited (5m)","windows":[{"window":"five_hour","utilization":10}]}}}' ;;
  evilwindows) printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"acct-evil","windows":[{"window":"\\u001b[2J","utilization":12},{"window":"\\u001b[H","utilization":9},{"window":"\\nX","utilization":8}]}}}' ;;
  manywindows) printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"acct-many","windows":[{"window":"five_hour","utilization":1},{"window":"five_hour","utilization":2},{"window":"five_hour","utilization":3},{"window":"five_hour","utilization":4},{"window":"five_hour","utilization":5},{"window":"five_hour","utilization":6}]}}}' ;;
  malformed) printf '%s' '{not json' ;;
  slowclaude) sleep 0.5; printf '%s' '{"success":true,"data":{"status":"known","account":{"name":"acct-slow","paused":false,"windows":[{"window":"five_hour","utilization":7}]}}}' ;;
  *) exit 7 ;;
esac
`);
  fs.chmodSync(curl, 0o755);
  return {
    dir,
    log: path.join(dir, 'curl.log'),
    env: {
      ...process.env,
      HOME: dir,
      TMPDIR: dir,
      CLAUDE_JOB_DIR: path.join(dir, 'job'),
      STATUSLINE_PR_CACHE_DIR: path.join(dir, 'pr-cache'),
      STATUSLINE_PR_REFRESH: '0',
      FORCE_HYPERLINK: '1',
      PATH: `${bin}:${process.env.PATH}`,
      CURL_LOG: path.join(dir, 'curl.log'),
      // A loaded CI runner can take longer than the 250 ms production budget
      // just to spawn the fake curl (#1671).
      LOCAL_STATUSLINE_PROVENANCE_TIMEOUT_MS: '3000',
    },
  };
}

// Write a JSONL transcript fixture. Each record is a raw object; the renderer
// tails this file for the last non-sidechain assistant record's message.model.
function writeTranscript(f, records) {
  const p = path.join(f.dir, 'transcript.jsonl');
  fs.writeFileSync(p, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  return p;
}

const assistant = (model, extra = {}) => ({
  type: 'assistant',
  message: { model },
  ...extra,
});

function runStatusline(f, mode, opts = {}) {
  const env = { ...f.env, CURL_MODE: mode };
  // The renderer keys both the endpoint base URL and the "○ ?" gating on
  // ANTHROPIC_BASE_URL, so tests must control it explicitly — never inherit
  // whatever the developer's shell happens to export.
  delete env.ANTHROPIC_BASE_URL;
  delete env.STATUSLINE_PRIVATE;
  if (opts.baseUrl) env.ANTHROPIC_BASE_URL = opts.baseUrl;
  if ('provenanceTimeout' in opts) {
    if (opts.provenanceTimeout === undefined) delete env.LOCAL_STATUSLINE_PROVENANCE_TIMEOUT_MS;
    else env.LOCAL_STATUSLINE_PROVENANCE_TIMEOUT_MS = opts.provenanceTimeout;
  }
  Object.assign(env, opts.env || {});
  const result = spawnSync(process.execPath, [STATUSLINE], {
    input: JSON.stringify({
      session_id: opts.sessionId ?? 'session-123',
      cwd: f.dir,
      transcript_path: opts.transcript,
      model: {
        display_name: 'Opus 5',
        id: 'modelId' in opts ? opts.modelId : 'claude-opus-5',
      },
      context_window: { used_percentage: 12, total_input_tokens: 5000 },
      rate_limits: {},
      ...(opts.payload || {}),
    }),
    encoding: 'utf8',
    env,
    timeout: 5000, // a renderer that blocks (e.g. on a FIFO transcript) must fail loudly
  });
  assert.strictEqual(result.status, 0, result.stderr);
  return opts.raw ? result.stdout : result.stdout.replace(ANSI, '');
}

const RED_DOT = '\x1b[38;5;203m●';

// mirror of the renderer's provenance cache key (endpoint base + session id)
function cacheKey(sessionId, base = 'http://127.0.0.1:8788') {
  return createHash('sha256').update(`${base}\n${sessionId}`).digest('hex').slice(0, 24);
}

// ---- main-chain served-model arrow ----

test('main-chain remap identifies the last reply, not the current request', () => {
  const f = fixture();
  try {
    const transcript = writeTranscript(f, [
      assistant('claude-opus-5'),
      assistant('gpt-5.6-terra'),
    ]);
    const output = runStatusline(f, 'unavailable', { transcript });
    assert.match(output, /Opus 5.*last reply gpt-5\.6-terra \(age unknown\)/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a subagent-only remap does not alter the model segment', () => {
  const f = fixture();
  try {
    const transcript = writeTranscript(f, [
      assistant('claude-opus-5'),
      assistant('gpt-5.6-terra', { isSidechain: true }),
    ]);
    const output = runStatusline(f, 'unavailable', { transcript });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /→/);
    assert.doesNotMatch(output, /gpt-5\.6-terra/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('bracketed context-window suffix is not a remap', () => {
  const f = fixture();
  try {
    const transcript = writeTranscript(f, [assistant('claude-opus-5[1m]')]);
    const output = runStatusline(f, 'unavailable', { transcript });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /→/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a native same-model serve renders no arrow', () => {
  const f = fixture();
  try {
    const transcript = writeTranscript(f, [assistant('claude-opus-5')]);
    const output = runStatusline(f, 'unavailable', { transcript });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /→/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('no model id means no remap claim', () => {
  const f = fixture();
  try {
    const transcript = writeTranscript(f, [assistant('gpt-5.6-terra')]);
    const output = runStatusline(f, 'unavailable', { transcript, modelId: null });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /→/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

// ---- serving-account badge ----

test('account badge shows name and every usage window', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'claude');
    assert.match(output, /● max-acct-c 5h 12% 7d 91%/);
    assert.match(
      fs.readFileSync(f.log, 'utf8').trim(),
      /\/api\/sessions\/session-123\/account$/,
    );
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('ANTHROPIC_BASE_URL overrides the fallback endpoint base', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'gpt', { baseUrl: 'http://127.0.0.1:9999' });
    assert.match(output, /● acct-a 5h 5%/);
    const call = fs.readFileSync(f.log, 'utf8').trim();
    assert.match(call, /http:\/\/127\.0\.0\.1:9999\/api\/sessions\/session-123\/account$/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('unknown session with ANTHROPIC_BASE_URL set renders the hollow placeholder', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'unknownsession', { baseUrl: 'http://127.0.0.1:9999' });
    assert.match(output, /○ \?/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('unknown session without the env renders no badge at all', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'unknownsession');
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /○/);
    assert.doesNotMatch(output, /●/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a healthy "allowed (…)" snapshot does not paint the dot red', () => {
  const f = fixture();
  try {
    const raw = runStatusline(f, 'healthysnapshot', { raw: true });
    assert.match(raw.replace(ANSI, ''), /● acct-healthy 5h 10%/);
    assert.ok(!raw.includes(RED_DOT), 'healthy snapshot rendered a red dot');
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('an actual rate-limit lock paints the dot red', () => {
  const f = fixture();
  try {
    const raw = runStatusline(f, 'ratelimited', { raw: true });
    assert.match(raw.replace(ANSI, ''), /● acct-limited 5h 10%/);
    assert.ok(raw.includes(RED_DOT), 'rate-limited account did not render a red dot');
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('unavailable or malformed provenance leaves the existing HUD intact', () => {
  for (const mode of ['malformed', 'unavailable']) {
    const f = fixture();
    try {
      const output = runStatusline(f, mode);
      assert.match(output, /Opus 5/);
      assert.doesNotMatch(output, /○/);
      assert.doesNotMatch(output, /●/);
      assert.doesNotMatch(output, /→/);
    } finally {
      fs.rmSync(f.dir, { recursive: true, force: true });
    }
  }
});

// ---- provenance fetch budget ----

test('a slow endpoint still renders inside the overridden fetch budget', () => {
  const f = fixture();
  try {
    assert.match(runStatusline(f, 'slowclaude'), /● acct-slow 5h 7%/);
    assert.match(fs.readFileSync(f.log, 'utf8'), /--max-time 1\.8 /);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a fetch slower than the budget renders no badge', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'slowclaude', { provenanceTimeout: '100' });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /●|acct-slow/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

// Production runs with the variable unset, which must keep the 250 ms bound.
test('with the budget variable unset, a slow endpoint renders no badge', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'slowclaude', { provenanceTimeout: undefined });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /acct-slow/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

// Asserts only the missing badge. At the 250 ms fallback a loaded runner can
// kill the fake curl before it logs its arguments, which is the #1671 flake.
test('an invalid budget override keeps the fetch bounded', () => {
  for (const value of ['', 'abc', '0', '10001', '1e3', '-5']) {
    const f = fixture();
    try {
      const output = runStatusline(f, 'slowclaude', { provenanceTimeout: value });
      assert.match(output, /Opus 5/);
      assert.doesNotMatch(output, /acct-slow/, `override ${JSON.stringify(value)}`);
    } finally {
      fs.rmSync(f.dir, { recursive: true, force: true });
    }
  }
});

// ---- provenance cache ----

test('rejects a future-dated cache instead of pinning stale provenance', () => {
  const f = fixture();
  try {
    const sessionId = 'session-123';
    fs.writeFileSync(
      path.join(f.dir, `better-ccflare-route-${cacheKey(sessionId)}.json`),
      JSON.stringify({
        at: Date.now() + 86_400_000,
        data: { status: 'known', account: { name: 'stale-account' } },
      }),
    );
    const output = runStatusline(f, 'gpt', { sessionId });
    assert.match(output, /● acct-a/);
    assert.doesNotMatch(output, /stale-account/);
    assert.match(
      fs.readFileSync(f.log, 'utf8').trim(),
      /\/api\/sessions\/session-123\/account$/,
    );
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('reuses the short provenance cache across renderer processes', () => {
  const f = fixture();
  try {
    assert.match(runStatusline(f, 'claude'), /● max-acct-c/);
    assert.match(runStatusline(f, 'unavailable'), /● max-acct-c/);
    const calls = fs.readFileSync(f.log, 'utf8').trim().split('\n');
    assert.strictEqual(calls.length, 1);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('an oversized cache file is ignored, not parsed', () => {
  const f = fixture();
  try {
    fs.writeFileSync(
      path.join(f.dir, `better-ccflare-route-${cacheKey('session-123')}.json`),
      'x'.repeat(70000),
    );
    assert.match(runStatusline(f, 'gpt'), /● acct-a/);
    const calls = fs.readFileSync(f.log, 'utf8').trim().split('\n');
    assert.strictEqual(calls.length, 1);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('the cache is namespaced per endpoint base', () => {
  const f = fixture();
  try {
    assert.match(
      runStatusline(f, 'claude', { baseUrl: 'http://127.0.0.1:9991' }),
      /● max-acct-c/,
    );
    // same session, different proxy, inside the TTL: must refetch, not replay
    assert.match(
      runStatusline(f, 'gpt', { baseUrl: 'http://127.0.0.1:9992' }),
      /● acct-a/,
    );
    const calls = fs.readFileSync(f.log, 'utf8').trim().split('\n');
    assert.strictEqual(calls.length, 2);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

// ---- hostile or degraded environments ----

test('endpoint-controlled window labels cannot inject control sequences', () => {
  const f = fixture();
  try {
    const raw = runStatusline(f, 'evilwindows', { raw: true });
    assert.ok(!raw.includes('\x1b[2J'), 'clear-screen sequence leaked into the HUD');
    assert.ok(!raw.includes('\x1b[H'), 'cursor-home sequence leaked into the HUD');
    const stripped = raw.replace(ANSI, '');
    assert.strictEqual(stripped.trim().split('\n').length, 3, 'HUD line layout broke');
    assert.match(stripped, /● acct-evil/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('the window list is capped so the badge cannot wrap the status line', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'manywindows');
    const shown = (output.match(/5h \d+%/g) || []).length;
    assert.strictEqual(shown, 4);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a FIFO transcript does not block or blank the render', () => {
  const f = fixture();
  try {
    const fifo = path.join(f.dir, 'transcript.fifo');
    try {
      require('node:child_process').execFileSync('mkfifo', [fifo]);
    } catch {
      return; // platform without mkfifo — nothing to assert
    }
    const output = runStatusline(f, 'unavailable', { transcript: fifo });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /→/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a non-HTTP base URL is never handed to curl', () => {
  const f = fixture();
  try {
    const output = runStatusline(f, 'gpt', { baseUrl: 'file:///etc/passwd' });
    assert.match(output, /Opus 5/);
    assert.doesNotMatch(output, /●/);
    assert.doesNotMatch(output, /○/);
    assert.ok(!fs.existsSync(f.log), 'curl was invoked despite the non-HTTP base');
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

// ---- git segment: two git spawns per render ----

// A repo with one commit and one untracked file, plus a logging `git` shim ahead of the real binary
// so the renderer's spawns can be counted (statusline-stack/local-statusline.mjs git()).
function gitRepoFixture() {
  const f = fixture();
  const real = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
  assert.ok(real, 'git not on PATH');
  const shim = path.join(f.dir, 'bin', 'git');
  fs.writeFileSync(shim, `#!/bin/sh\nprintf '%s\\n' "$*" >> "$GIT_LOG"\nexec ${real} "$@"\n`);
  fs.chmodSync(shim, 0o755);
  f.env.GIT_LOG = path.join(f.dir, 'git.log');
  const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
  const g = (...a) => spawnSync(real, ['-C', f.dir, ...a], { encoding: 'utf8', env });
  g('init', '-q', '-b', 'trunk');
  g('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'init');
  fs.writeFileSync(path.join(f.dir, 'dirty.txt'), 'x');
  return f;
}

test('the git segment renders branch and change count from two git spawns', () => {
  const f = gitRepoFixture();
  try {
    const output = runStatusline(f, 'gpt');
    assert.match(output, new RegExp(`^${path.basename(f.dir)} › trunk ±[1-9]\\d*`, 'm'));
    assert.doesNotMatch(output, /\bwt\b/);
    assert.ok(!output.includes(String.fromCodePoint(0xe0a0)), 'private-use branch glyph needs a Nerd Font');
    const calls = fs.readFileSync(f.env.GIT_LOG, 'utf8').split('\n').filter(Boolean);
    assert.strictEqual(calls.length, 2, calls.join(' | '));
    assert.match(calls[0], /^--no-optional-locks -C .+ rev-parse --is-inside-work-tree --abbrev-ref HEAD --show-toplevel --path-format=absolute --git-common-dir$/);
    assert.match(calls[1], /^--no-optional-locks -C .+ status --porcelain$/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('outside a repo the git segment is absent and git is asked once', () => {
  const f = fixture();
  try {
    const real = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
    const shim = path.join(f.dir, 'bin', 'git');
    fs.writeFileSync(shim, `#!/bin/sh\nprintf '%s\\n' "$*" >> "$GIT_LOG"\nexec ${real} "$@"\n`);
    fs.chmodSync(shim, 0o755);
    f.env.GIT_LOG = path.join(f.dir, 'git.log');
    const output = runStatusline(f, 'gpt');
    assert.doesNotMatch(output, /±/);
    const calls = fs.existsSync(f.env.GIT_LOG) ? fs.readFileSync(f.env.GIT_LOG, 'utf8').split('\n').filter(Boolean) : [];
    // the combined call fails (exit 128), then the bare question is asked once and answers false
    assert.strictEqual(calls.length, 2, calls.join(' | '));
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

// ---- independent observation provenance, never dispatch liveness ----

test('an old reply remains explicitly historical after a newer user turn', () => {
  const f = fixture();
  try {
    const transcript = writeTranscript(f, [
      assistant('gpt-6.1-sol', { timestamp: new Date(Date.now() - 121_000).toISOString() }),
      { type: 'user', timestamp: new Date().toISOString(), message: { content: 'fixture' } },
      assistant('gpt-6-astra', { isSidechain: true, timestamp: new Date().toISOString() }),
    ]);
    const output = runStatusline(f, 'gpt', { transcript });
    assert.match(output, /last reply gpt-6\.1-sol \(2m ago\)/);
    assert.match(output, /last session route ● acct-a 5h 5% \(age unknown\)/);
    assert.doesNotMatch(output, /gpt-6-astra|→/);
    assert.match(output, /12%/);
    assert.match(output, /^ctx ▕.*▏ 12% 5\.0k/m);
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test('last session route age comes from recordedAt, never the five-second fetch cache', () => {
  const f = fixture();
  try {
    const cache = path.join(f.dir, `better-ccflare-route-${cacheKey('session-123')}.json`);
    fs.writeFileSync(cache, JSON.stringify({
      at: Date.now(),
      data: {
        status: 'known', recordedAt: Date.now(), // wrong level must never freshen the route
        upstreamModel: 'gpt-6-astra',
        account: { name: 'secondary-route', recordedAt: Date.now() - 3_661_000, windows: [{ window: 'seven_day', utilization: 100 }] },
      },
    }));
    const transcript = writeTranscript(f, [assistant('gpt-6.1-sol')]);
    const output = runStatusline(f, 'unavailable', { transcript });
    assert.match(output, /last reply gpt-6\.1-sol \(age unknown\)/);
    assert.match(output, /last session route ● secondary-route 7d 100% \(1h ago\)/);
    assert.doesNotMatch(output, /gpt-6-astra/);
    assert.ok(!fs.existsSync(f.log), 'cached observation should not refetch');
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test('missing, invalid and future observation timestamps never imply freshness', () => {
  for (const timestamp of [undefined, null, 'invalid', '2026-01-01T00:00:00Z', 0, -1, Date.now() + 86_400_000]) {
    const f = fixture();
    try {
      fs.writeFileSync(path.join(f.dir, `better-ccflare-route-${cacheKey('session-123')}.json`), JSON.stringify({
        at: Date.now(), data: { status: 'known', account: { name: 'fixture', recordedAt: timestamp } },
      }));
      const transcript = writeTranscript(f, [assistant('gpt-6.1-sol', { timestamp })]);
      const output = runStatusline(f, 'unavailable', { transcript });
      assert.match(output, /last session route ● fixture \(age unknown\)/);
      if (timestamp !== '2026-01-01T00:00:00Z')
        assert.match(output, /last reply gpt-6\.1-sol \(age unknown\)/);
    } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
  }
});

// ---- prompt cache, quota, privacy, fitting (local-statusline.mjs cacheSegment/quota/fit) ----

const ESC = String.fromCharCode(27);
const RLO = String.fromCodePoint(0x202e);
const nowS = () => Math.floor(Date.now() / 1000);
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
// mirror of the renderer's clock(): "HH:MM" today, else "Ddd HH:MM"
function clockOf(epoch) {
  const d = new Date(epoch * 1000);
  const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  return d.toDateString() === new Date().toDateString() ? hm : `${DAYS[d.getDay()]} ${hm}`;
}
const cache = (extra) => ({ caching_observed: true, ttl: '1h', requests: 40, misses: 1, ...extra });
const lineOf = (output, n) => output.split('\n')[n] ?? '';
const withFixture = (fn) => { const f = fixture(); try { fn(f); } finally { fs.rmSync(f.dir, { recursive: true, force: true }); } };

const zeroUsage = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };

// Native snapshots across a cached turn, an interrupted placeholder, and the
// following completion. These fixtures test presentation, not a live provider.
test('incomplete zero usage cannot turn a cached conversation into zero context and cold cache', () => withFixture((f) => {
  const measured = { ...zeroUsage, input_tokens: 129, cache_read_input_tokens: 125056, output_tokens: 930 };
  const render = (usage, total, pc) => lineOf(runStatusline(f, 'unavailable', { payload: {
    context_window: { used_percentage: total ? 12.5 : 0, total_input_tokens: total, context_window_size: 1000000, current_usage: usage },
    prompt_cache: pc,
  } }), 0);
  const warm = cache({ warm: true, expires_at: nowS() + 2880 });
  assert.match(render(measured, 125185, warm), /125k\/1M │ cache 48m→/);
  const incomplete = render(zeroUsage, 0, cache({ warm: false, expires_at: null, recache_tokens_if_cold: 0, last_miss_at: nowS() - 6000 }));
  assert.match(incomplete, /^ctx usage unavailable │ cache unknown │/);
  assert.doesNotMatch(incomplete, /0%|0\/1M|cold|warm|re-cache|→/);
  assert.match(render(measured, 125185, warm), /125k\/1M │ cache 48m→/);
}));

test('unmeasured current usage preserves independently reported cache warmth and expiry', () => withFixture((f) => {
  const cases = [
    [cache({ warm: true, expires_at: nowS() + 2880 }), /cache 48m→/],
    [cache({ warm: true, expires_at: null }), /cache warm │/],
    [cache({ warm: true, expires_at: nowS() - 60 }), /cache cold · idle 1h01m/],
    [cache({ warm: false, expires_at: nowS() - 60 }), /cache cold · idle 1h01m/],
    [cache({ warm: false, expires_at: null, recache_tokens_if_cold: 125185 }), /cache cold · re-cache ~125k/],
  ];
  for (const [prompt_cache, expected] of cases) {
    const output = lineOf(runStatusline(f, 'unavailable', { payload: {
      context_window: { used_percentage: 0, total_input_tokens: 0, current_usage: zeroUsage },
      prompt_cache,
    } }), 0);
    assert.match(output, /^ctx usage unavailable │/);
    assert.match(output, expected);
    assert.doesNotMatch(output, /cache unknown/);
  }
}));

test('unmeasured usage does not invent cache metadata for an unobserved provider', () => withFixture((f) => {
  for (const prompt_cache of [undefined, null, 'cold', { caching_observed: false, warm: false }]) {
    const output = lineOf(runStatusline(f, 'unavailable', { payload: {
      context_window: { used_percentage: 0, total_input_tokens: 0, current_usage: zeroUsage },
      prompt_cache,
    } }), 0);
    assert.match(output, /^ctx usage unavailable │ Opus 5/);
    assert.doesNotMatch(output, /cache/);
  }
}));

test('missing or malformed current usage preserves legacy and fresh-session rendering', () => withFixture((f) => {
  for (const current_usage of [undefined, null, {}, [], 'zero', { ...zeroUsage, input_tokens: '0' }, { ...zeroUsage, output_tokens: null }, { ...zeroUsage, cache_read_input_tokens: -1 }]) {
    const output = lineOf(runStatusline(f, 'unavailable', { payload: {
      context_window: { used_percentage: 0, total_input_tokens: 0, context_window_size: 1000000, current_usage },
    } }), 0);
    assert.match(output, /0% 0\/1M │ Opus 5/);
    assert.doesNotMatch(output, /unavailable|unknown|cache/);
  }
}));

test('positive usage and positive context are not hidden by the unmeasured-usage guard', () => withFixture((f) => {
  const cases = [
    ...Object.keys(zeroUsage).map((key) => ({ usage: { ...zeroUsage, [key]: 128 }, total: 0, pct: 0 })),
    { usage: zeroUsage, total: 128, pct: 0 },
    { usage: zeroUsage, total: 0, pct: 12 },
  ];
  for (const { usage, total, pct } of cases) {
    const output = lineOf(runStatusline(f, 'unavailable', { payload: {
      context_window: { used_percentage: pct, total_input_tokens: total, current_usage: usage },
      prompt_cache: cache({ warm: false, expires_at: null, recache_tokens_if_cold: 128 }),
    } }), 0);
    assert.match(output, /cache cold · re-cache ~128/);
    assert.doesNotMatch(output, /unavailable|unknown/);
  }
}));

test('no prompt_cache field, or no caching observed, renders no cache segment', () => withFixture((f) => {
  assert.doesNotMatch(runStatusline(f, 'unavailable'), /cache/);
  const off = runStatusline(f, 'unavailable', { payload: { prompt_cache: { caching_observed: false, warm: false, ttl: '5m', recache_tokens_if_cold: 9000 } } });
  assert.doesNotMatch(off, /cache/);
  const junk = runStatusline(f, 'unavailable', { payload: { prompt_cache: 'warm' } });
  assert.doesNotMatch(junk, /cache/);
}));

test('a warm cache counts down to its absolute expiry, green until the last fifth of the TTL', () => withFixture((f) => {
  const exp = nowS() + 2880;
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { prompt_cache: cache({ warm: true, expires_at: exp }) } });
  assert.match(raw.replace(ANSI, ''), new RegExp(`^ctx .* │ cache 48m→${clockOf(exp)} │ Opus 5`, 'm'));
  assert.ok(raw.includes(`${ESC}[38;5;42m48m`), 'a comfortable countdown is green');
  const late = nowS() + 300;
  const rawLate = runStatusline(f, 'unavailable', { raw: true, payload: { prompt_cache: cache({ warm: true, expires_at: late }) } });
  assert.ok(rawLate.includes(`${ESC}[38;5;214m5m`), 'under a fifth of the 1h TTL is orange');
  const noExp = runStatusline(f, 'unavailable', { payload: { prompt_cache: cache({ warm: true, expires_at: null }) } });
  assert.match(noExp, /│ cache warm │/);
}));

test('a cold cache shows idle time and the re-cache cost, never in red', () => withFixture((f) => {
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { prompt_cache: cache({ warm: false, expires_at: nowS() - 600, recache_tokens_if_cold: 154851 }) } });
  assert.match(raw.replace(ANSI, ''), /│ cache cold · idle 1h10m · re-cache ~155k │/);
  assert.ok(!lineOf(raw, 0).includes('38;5;203m'), 'cold is a cost, not an error');
}));

test('a warm frame past its expiry reads cold', () => withFixture((f) => {
  const output = runStatusline(f, 'unavailable', { payload: { prompt_cache: cache({ warm: true, expires_at: nowS() - 60, recache_tokens_if_cold: 2000 }) } });
  assert.match(output, /cache cold · idle 1h01m · re-cache ~2\.0k/);
  assert.doesNotMatch(output, /cache \d+m→/);
}));

test('a null re-cache estimate says the next turn re-caches the compacted prompt', () => withFixture((f) => {
  const output = runStatusline(f, 'unavailable', { payload: { prompt_cache: cache({ warm: false, expires_at: null, recache_tokens_if_cold: null }) } });
  assert.match(output, /│ cache cold · next turn re-caches │/);
}));

test('an unknown TTL string still renders, without inventing idle time', () => withFixture((f) => {
  const cold = runStatusline(f, 'unavailable', { payload: { prompt_cache: cache({ ttl: '7d', warm: false, expires_at: nowS() - 600, recache_tokens_if_cold: 1000 }) } });
  assert.match(cold, /│ cache cold · re-cache ~1\.0k │/);
  const warm = runStatusline(f, 'unavailable', { payload: { prompt_cache: cache({ ttl: 'bogus', warm: true, expires_at: nowS() + 3000 }) } });
  assert.match(warm, /│ cache 50m→\S+/);
}));

for (const [day, now, expiry] of [
  ['same-day', Date.UTC(2026, 9, 7, 12), '12:50'],
  ['next-day', Date.UTC(2026, 9, 7, 23, 30), 'Thu 00:20'],
]) {
  test(`Pro round 2: fresh non-idle miss with ${day} expiry names its cause; other keys never print`, (t) => withFixture((f) => {
    t.mock.timers.enable({ apis: ['Date'], now });
    const clock = path.join(f.dir, 'clock.cjs');
    fs.writeFileSync(clock, `require('node:test').mock.timers.enable({ apis: ['Date'], now: ${now} });\n`);
    f.env.NODE_OPTIONS = `${f.env.NODE_OPTIONS || ''} --require=${clock}`;
    f.env.TZ = 'UTC';
    const warm = (causes, ago) => runStatusline(f, 'unavailable', { payload: { prompt_cache: cache({
      warm: true, expires_at: nowS() + 3000, last_miss_at: nowS() - ago, last_miss_cause: { causes },
    }) } });
    const output = warm(['tools_changed', 'model_changed'], 120);
    assert.ok(output.includes(`cache 50m→${expiry} miss: tool definitions changed +1 │`), output);
    assert.match(warm(['messages_rewritten'], 30), /miss: earlier messages changed │/);
    assert.doesNotMatch(warm(['tools_changed'], 700), /miss/, 'a miss older than ten minutes is history');
    assert.doesNotMatch(warm(['tools_changed'], -120), /miss/, 'a future-dated miss (clock skew) is not fresh');
    for (const key of ['ttl_expired_1h', 'ttl_expired_5m', 'unknown', 'constructor', '__proto__', 'toString', `x${ESC}[2J`]) {
      const output = warm([key], 60);
      assert.doesNotMatch(output, /miss/, key);
      assert.ok(!output.includes(ESC), key);
    }
  }));
}

test('a quota window already past its reset reads "reset due" instead of a stale bar', () => withFixture((f) => {
  const weekly = nowS() + 3 * 86400;
  const output = runStatusline(f, 'unavailable', { payload: { rate_limits: {
    five_hour: { used_percentage: 97, resets_at: nowS() - 10 },
    seven_day: { used_percentage: 41, resets_at: weekly },
  } } });
  const third = lineOf(output, 2);
  assert.ok(third.startsWith(`5h  ▕${'░'.repeat(10)}▏ reset due │ 7d ▕████░░░░░░▏ 41%→${clockOf(weekly)}`), third);
  assert.match(clockOf(weekly), /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) \d\d:\d\d$/, 'a reset days away carries its weekday');
}));

test('the first quota bar sits in the same column as the ctx bar', () => withFixture((f) => {
  for (const rate_limits of [
    { five_hour: { used_percentage: 23, resets_at: nowS() + 5400 }, seven_day: { used_percentage: 41, resets_at: nowS() + 9000 } },
    { seven_day: { used_percentage: 41, resets_at: nowS() + 9000 } },
  ]) {
    const output = runStatusline(f, 'unavailable', { payload: { rate_limits } });
    assert.strictEqual(lineOf(output, 2).indexOf('▕'), lineOf(output, 0).indexOf('▕'), output);
  }
}));

test('control and bidi characters in payload text never reach the terminal', () => withFixture((f) => {
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: {
    model: { display_name: `Opus${ESC}[2J${RLO}x`, id: 'claude-opus-5' },
    effort: { level: `xhigh${ESC}[H` },
    cwd: path.join(f.dir, `evil${ESC}[2J${RLO}dir`),
    worktree: { name: `wt${ESC}[H` },
    pr: { number: 7, review_state: `approved${ESC}[2J` },
  } });
  const visible = raw.replace(ANSI, '');
  assert.ok(!visible.includes(ESC), JSON.stringify(visible));
  assert.ok(!visible.includes(RLO), 'bidi override survived');
  assert.match(visible, /Opus\[2Jx/);
  assert.doesNotMatch(visible, /xhigh/, 'a non-allowlisted effort is dropped, not cleaned');
  assert.match(visible, /PR #7(?! approved)/);
}));

test('the PR segment carries its review state, colored by outcome', () => withFixture((f) => {
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 1673, review_state: 'changes_requested' } } });
  assert.match(lineOf(raw.replace(ANSI, ''), 2), /PR #1673 changes requested/);
  assert.ok(raw.includes(`${ESC}[38;5;214mchanges requested`));
  assert.doesNotMatch(runStatusline(f, 'unavailable', { payload: { pr: { number: '1673; x' } } }), /PR #/);
}));

test('private mode masks the account and hides the session id, by env or by flag file', () => withFixture((f) => {
  const open = runStatusline(f, 'claude');
  assert.match(open, /last session route ● max-acct-c 5h 12% 7d 91%/);
  assert.match(lineOf(open, 2), /session-/);
  const viaEnv = runStatusline(f, 'claude', { env: { STATUSLINE_PRIVATE: '1' } });
  assert.match(viaEnv, /last session route ● max-••• 5h 12% 7d 91%/);
  assert.doesNotMatch(viaEnv, /acct-c|session-/);
  fs.mkdirSync(path.join(f.dir, '.claude'));
  fs.writeFileSync(path.join(f.dir, '.claude', 'statusline-private'), '');
  const viaFile = runStatusline(f, 'claude');
  assert.match(viaFile, /max-•••/);
  assert.doesNotMatch(viaFile, /acct-c|session-/);
}));

test('private mode masks a name whose prefix is not a plan family in full', () => withFixture((f) => {
  assert.match(runStatusline(f, 'manywindows'), /last session route ● acct-many/);
  const masked = runStatusline(f, 'manywindows', { env: { STATUSLINE_PRIVATE: '1' } });
  assert.match(masked, /last session route ● •••• /);
  assert.doesNotMatch(masked, /acct/);
}));

test('a crowded HUD drops detail in order until every line fits 108 columns', () => withFixture((f) => {
  const transcript = writeTranscript(f, [assistant('claude-opus-5-5')]);
  const output = runStatusline(f, 'manywindows', { transcript, modelId: 'claude-sonnet-5-5', payload: {
    model: { display_name: 'Sonnet 5.5', id: 'claude-sonnet-5-5' },
    effort: { level: 'xhigh' },
    cwd: path.join(f.dir, 'a'.repeat(80)),
    context_window: { used_percentage: 15, total_input_tokens: 152115, context_window_size: 1000000 },
    cost: { total_cost_usd: 18.42 },
    prompt_cache: cache({ warm: false, expires_at: nowS() - 4200 + 3600, recache_tokens_if_cold: 154851 }),
    rate_limits: { five_hour: { used_percentage: 23, resets_at: nowS() + 5400 }, seven_day: { used_percentage: 41, resets_at: nowS() + 345600 } },
    pr: { number: 1673, review_state: 'changes_requested' },
  } });
  const lines = output.split('\n');
  assert.strictEqual(lines.length, 3, output);
  for (const line of lines) assert.ok([...line].length <= 108, `${[...line].length}: ${line}`);
  // line 1 kept the cost, the remap and the re-cache size; it shed the idle time first
  assert.match(lines[0], /cache cold · ~155k │ Sonnet 5\.5 xhigh last reply claude-opus-5-5 │ \$18\.42$/);
  assert.match(lines[1], /last session route ● acct-many/);
}));

test('a linked worktree is named for its repo, marked wt, and shows a differing worktree name', () => {
  const f = gitRepoFixture();
  try {
    const real = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
    const wt = path.join(f.dir, 'linked');
    const add = spawnSync(real, ['-C', f.dir, 'worktree', 'add', '-q', '-b', 'feat', wt], {
      encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' },
    });
    assert.strictEqual(add.status, 0, add.stderr);
    const repo = path.basename(f.dir);
    const named = runStatusline(f, 'unavailable', { payload: { cwd: wt, worktree: { name: 'agent-task' } } });
    assert.match(lineOf(named, 1), new RegExp(`^${repo} › wt feat \\(agent-task\\)`));
    const same = runStatusline(f, 'unavailable', { payload: { cwd: wt, worktree: { name: 'feat' } } });
    assert.match(lineOf(same, 1), new RegExp(`^${repo} › wt feat$`));
    const main = runStatusline(f, 'unavailable');
    assert.match(lineOf(main, 1), new RegExp(`^${repo} › trunk`));
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test('a cwd reached through a symlink keeps its repo, subdirectory and branch', () => {
  const f = gitRepoFixture();
  const link = `${f.dir}-link`;
  try {
    fs.mkdirSync(path.join(f.dir, 'sub'));
    fs.symlinkSync(f.dir, link);
    const repo = path.basename(f.dir);
    assert.match(lineOf(runStatusline(f, 'unavailable', { payload: { cwd: link } }), 1), new RegExp(`^${repo} › trunk ±`));
    assert.match(lineOf(runStatusline(f, 'unavailable', { payload: { cwd: path.join(link, 'sub') } }), 1), new RegExp(`^${repo}/sub › trunk ±`));
  } finally {
    try { fs.unlinkSync(link); } catch { /* never created */ }
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test('a fresh session renders an empty ctx bar and no cache or quota segments', () => withFixture((f) => {
  const output = runStatusline(f, 'unavailable', { sessionId: '3f9c1b2e-0000-4000-8000-000000000000', payload: {
    context_window: { used_percentage: 0, total_input_tokens: 0, context_window_size: 1000000 },
    effort: { level: 'xhigh' },
    cost: { total_cost_usd: 0 },
  } });
  assert.strictEqual(lineOf(output, 0), `ctx ▕${'░'.repeat(10)}▏  0% 0/1M │ Opus 5 xhigh │ $0.00`);
  assert.strictEqual(lineOf(output, 2), '3f9c1b2e');
  assert.doesNotMatch(output, /cache|5h|7d/);
}));

const OSC8 = /\x1b\]8;;[^\x1b]*\x1b\\/g;
const plain = (s) => s.replace(OSC8, '').replace(ANSI, '');
const prUrl = (n, repo = 'acme/main') => `https://github.com/${repo}/pull/${n}`;
const childPr = (n, repo) => ({ id: String(n), href: prUrl(n, repo), kind: 'pr' });
function writeJob(f, children, extra = {}, dir = f.env.CLAUDE_JOB_DIR) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify({ sessionId: 'session-123', children, ...extra }));
}
const urlsIn = (raw) => [...raw.matchAll(/\x1b\]8;;(https:[^\x1b]+)\x1b\\/g)].map((m) => m[1]);

test('all 25 native PR children plus the current PR wrap as whole clickable links', () => withFixture((f) => {
  writeJob(f, Array.from({ length: 25 }, (_, i) => childPr(1000 + i)));
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: {
    pr: { number: 2000, url: prUrl(2000) },
    rate_limits: { five_hour: { used_percentage: 20 }, seven_day: { used_percentage: 40 } },
  } });
  assert.deepStrictEqual(new Set(urlsIn(raw)), new Set([...Array.from({ length: 25 }, (_, i) => prUrl(1000 + i)), prUrl(2000)]));
  assert.ok(raw.split('\n').length > 3);
  for (const line of raw.split('\n')) {
    assert.ok(plain(line).length <= 108, plain(line));
    assert.strictEqual((line.match(/\x1b\]8;;/g) || []).length % 2, 0, 'links must close on their own row');
  }
}));

test('same-session resumed job discovery ignores a mismatched current job and unrelated jobs', () => withFixture((f) => {
  writeJob(f, [childPr(900)], { sessionId: 'other' });
  writeJob(f, [childPr(12)], { sessionId: 'old', resumeSessionId: 'session-123' }, path.join(f.dir, '.claude/jobs/resumed'));
  writeJob(f, [childPr(901)], { sessionId: 'unrelated' }, path.join(f.dir, '.claude/jobs/unrelated'));
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 13, url: prUrl(13) } } });
  assert.deepStrictEqual(new Set(urlsIn(raw)), new Set([prUrl(12), prUrl(13)]));
}));

test('a matching current job does not suppress additional same-session PR discovery', () => withFixture((f) => {
  f.env.CLAUDE_JOB_DIR = path.join(f.dir, '.claude/jobs/current');
  writeJob(f, [childPr(12)]);
  writeJob(f, [childPr(12, 'ACME/MAIN'), childPr(13)], { sessionId: 'old', resumeSessionId: 'session-123' }, path.join(f.dir, '.claude/jobs/resumed'));
  writeJob(f, [childPr(14)], {}, path.join(f.dir, '.claude/jobs/same-session'));
  writeJob(f, [childPr(901)], { sessionId: 'unrelated' }, path.join(f.dir, '.claude/jobs/unrelated'));
  const raw = runStatusline(f, 'unavailable', { raw: true });
  assert.strictEqual(urlsIn(raw).length, 3, 'current and discovered links must be deduplicated');
  assert.deepStrictEqual(new Set(urlsIn(raw)), new Set([prUrl(12), prUrl(13), prUrl(14)]));
}));

test('repo-qualified deduplication and cross-owner labels preserve distinct PR identities', () => withFixture((f) => {
  writeJob(f, [childPr(7), childPr(7, 'ACME/MAIN'), childPr(7, 'acme/lib'), childPr(7, 'other/lib'), childPr(8, 'other/tool')]);
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 7, url: prUrl(7) } } });
  assert.strictEqual(urlsIn(raw).length, 4);
  assert.match(plain(raw), /PR #7 acme\/lib#7 other\/lib#7 tool#8/);
  assert.strictEqual(raw.split('\n').length, 3, 'OSC8 target bytes must not consume column budget');
  const unlinked = runStatusline(f, 'unavailable', { raw: true, env: { FORCE_HYPERLINK: '0' }, payload: { pr: { number: 7, url: prUrl(7) } } });
  assert.deepStrictEqual(urlsIn(unlinked), []);
  assert.strictEqual(plain(raw), plain(unlinked));
}));

test('a number-only current PR retains its review label alongside native links', () => withFixture((f) => {
  writeJob(f, [childPr(42)]);
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: {
    pr: { number: 99, review_state: 'changes_requested' },
  } });
  assert.deepStrictEqual(urlsIn(raw), [prUrl(42)]);
  assert.match(plain(raw), /#42/);
  assert.match(plain(raw), /#99 changes requested/);
  assert.strictEqual(raw.split('\n').length, 3);
  writeJob(f, Array.from({ length: 25 }, (_, i) => childPr(1000 + i)));
  const crowded = runStatusline(f, 'unavailable', { raw: true, payload: {
    pr: { number: 99, review_state: 'pending' },
  } });
  assert.strictEqual(urlsIn(crowded).length, 25);
  assert.match(plain(crowded), /#99 pending/);
  for (const line of crowded.split('\n')) assert.ok(plain(line).length <= 108);
}));

test('malformed job data and unsafe PR targets cannot blank or inject into the HUD', () => withFixture((f) => {
  const evil = ['https://evil.test/acme/main/pull/1', 'https://me@github.com/acme/main/pull/2', `${prUrl(3)}?x=1`, `${prUrl(4)}#x`, `${prUrl(5)}\x1b[2J`, 'https://github.com/acme/main/pull/01', 'http://github.com/acme/main/pull/6'];
  writeJob(f, [...evil.map((href) => ({ kind: 'pr', href })), { kind: 'frame', href: prUrl(100) }, null, childPr(9)]);
  const options = { raw: true, payload: { pr: { number: 10, url: prUrl(10) } } };
  assert.deepStrictEqual(new Set(urlsIn(runStatusline(f, 'unavailable', options))), new Set([prUrl(9), prUrl(10)]));
  fs.writeFileSync(path.join(f.env.CLAUDE_JOB_DIR, 'state.json'), '{bad');
  const raw = runStatusline(f, 'unavailable', options);
  assert.deepStrictEqual(urlsIn(raw), [prUrl(10)]);
  assert.match(plain(raw), /ctx/);
}));

test('interactive typed PR events persist across incremental scans without scraping messages', () => withFixture((f) => {
  const transcript = writeTranscript(f, [
    { type: 'pr-link', sessionId: 'session-123', prNumber: 20, prUrl: prUrl(20) },
    { type: 'pr-link', sessionId: 'another', prNumber: 21, prUrl: prUrl(21) },
    { type: 'assistant', message: { content: prUrl(22) } },
  ]);
  assert.deepStrictEqual(urlsIn(runStatusline(f, 'unavailable', { raw: true, transcript })), [prUrl(20)]);
  fs.appendFileSync(transcript, JSON.stringify({ type: 'pr-link', sessionId: 'session-123', prNumber: 23, prUrl: prUrl(23) }) + '\n');
  assert.deepStrictEqual(new Set(urlsIn(runStatusline(f, 'unavailable', { raw: true, transcript }))), new Set([prUrl(20), prUrl(23)]));
}));

test('private mode keeps PR links but masks account and session identity', () => withFixture((f) => {
  writeJob(f, [childPr(42)]);
  const raw = runStatusline(f, 'claude', { raw: true, env: { STATUSLINE_PRIVATE: '1' } });
  assert.deepStrictEqual(urlsIn(raw), [prUrl(42)]);
  assert.match(plain(raw), /max-•••/);
  assert.doesNotMatch(plain(raw), /acct-c|session-/);
}));

const PR_HELPER = path.resolve(__dirname, '../../statusline-stack/pr-links.mjs');
function fakeGh(f, body) {
  fs.writeFileSync(path.join(f.dir, 'bin/gh'), `#!${process.execPath}\n${body}\n`, { mode: 0o755 });
}
function refresh(f, urls, env = {}) {
  const r = spawnSync(process.execPath, [PR_HELPER, '--refresh', 'session-123', JSON.stringify(urls)], {
    env: { ...f.env, ...env }, encoding: 'utf8', timeout: 12000,
  });
  assert.strictEqual(r.status, 0, r.stderr);
}
function stateFile(f) {
  const id = createHash('sha256').update('session-123').digest('hex').slice(0, 24);
  return path.join(f.env.STATUSLINE_PR_CACHE_DIR, `states-${id}.json`);
}

test('refresh child batches states atomically and colors each exact PR independently', () => withFixture((f) => {
  writeJob(f, Array.from({ length: 7 }, (_, i) => childPr(i + 1)));
  const data = {
    p0: { pr: { state: 'MERGED', isDraft: false } },
    p1: { pr: { state: 'OPEN', isDraft: true } },
    p2: { pr: { state: 'CLOSED', isDraft: false } },
    p3: { pr: { state: 'OPEN', isDraft: false, reviewDecision: 'APPROVED', commits: { nodes: [{ commit: { statusCheckRollup: { state: 'SUCCESS' } } }] } } },
    p4: { pr: { state: 'OPEN', isDraft: false, reviewDecision: null, commits: { nodes: [{ commit: { statusCheckRollup: { state: 'PENDING' } } }] } } },
    p5: { pr: { state: 'OPEN', isDraft: false, reviewDecision: 'CHANGES_REQUESTED', commits: { nodes: [{ commit: { statusCheckRollup: { state: 'SUCCESS' } } }] } } },
    p6: { pr: { state: 'OPEN', isDraft: false, reviewDecision: null, commits: { nodes: [] } } },
  };
  fakeGh(f, `require('fs').appendFileSync(process.env.GH_LOG, JSON.stringify(process.argv.slice(2))+'\\n'); process.stdout.write(${JSON.stringify(JSON.stringify({ data }))});`);
  f.env.GH_LOG = path.join(f.dir, 'gh.log');
  refresh(f, Array.from({ length: 7 }, (_, i) => prUrl(i + 1)));
  const calls = fs.readFileSync(f.env.GH_LOG, 'utf8').trim().split('\n');
  assert.strictEqual(calls.length, 1);
  const args = JSON.parse(calls[0]);
  assert.deepStrictEqual(args.slice(0, 3), ['api', 'graphql', '--hostname']);
  assert.ok(args.includes('github.com'));
  assert.match(args.join(' '), /statusCheckRollup/);
  assert.match(args.join(' '), /p6:/);
  assert.ok(fs.existsSync(stateFile(f)), 'child must commit a cache');
  assert.ok(fs.readdirSync(f.env.STATUSLINE_PR_CACHE_DIR).every((name) => !name.endsWith('.tmp') && !name.endsWith('.lock')));
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 7, url: prUrl(7), review_state: 'approved' } } });
  for (const [number, color] of [[1, 141], [2, 244], [3, 244], [4, 42], [5, 214], [6, 214], [7, 250]]) {
    assert.ok(raw.includes(`\x1b[38;5;${color}m#${number}\x1b[0m`), `PR ${number} must have its own state color ${color}`);
  }
  refresh(f, [prUrl(1)]);
  assert.strictEqual(fs.readFileSync(f.env.GH_LOG, 'utf8').trim().split('\n').length, 1, 'fresh cache suppresses a repeat refresh');
  const saved = JSON.parse(fs.readFileSync(stateFile(f)));
  saved.at = Date.now() - 180000;
  fs.writeFileSync(stateFile(f), JSON.stringify(saved));
  const stale = runStatusline(f, 'unavailable', { raw: true });
  assert.ok(stale.includes('\x1b[38;5;250m#4\x1b[0m'), 'expired readiness must not remain green');
}));

test('refresh failure commits unknown states and a cooldown without polluting links', () => withFixture((f) => {
  writeJob(f, [childPr(8)]);
  fakeGh(f, 'process.stdout.write("{bad"); process.exitCode = 1;');
  refresh(f, [prUrl(8)]);
  assert.deepStrictEqual(JSON.parse(fs.readFileSync(stateFile(f))).states, {});
  const raw = runStatusline(f, 'unavailable', { raw: true });
  assert.deepStrictEqual(urlsIn(raw), [prUrl(8)]);
  assert.ok(raw.includes('\x1b[38;5;250m#8\x1b[0m'));
}));

test('a partial GraphQL failure preserves unaffected PR states', () => withFixture((f) => {
  const response = {
    data: { p0: { pr: { state: 'MERGED' } }, p1: null },
    errors: [{ path: ['p1'], type: 'NOT_FOUND' }],
  };
  fakeGh(f, `process.stdout.write(${JSON.stringify(JSON.stringify(response))}); process.exitCode = 1;`);
  refresh(f, [prUrl(8), prUrl(9, 'other/repo')]);
  const saved = JSON.parse(fs.readFileSync(stateFile(f))).states;
  assert.strictEqual(saved[prUrl(8)], 'merged');
  assert.strictEqual(saved[prUrl(9, 'other/repo')], 'unknown');
}));

test('a GraphQL field error cannot fabricate readiness from null review data', () => withFixture((f) => {
  const response = {
    data: { p0: { pr: { state: 'OPEN', isDraft: false, reviewDecision: null, commits: { nodes: [{ commit: { statusCheckRollup: { state: 'SUCCESS' } } }] } } } },
    errors: [{ path: ['p0', 'pr', 'reviewDecision'] }],
  };
  fakeGh(f, `process.stdout.write(${JSON.stringify(JSON.stringify(response))}); process.exitCode = 1;`);
  refresh(f, [prUrl(8)]);
  assert.strictEqual(JSON.parse(fs.readFileSync(stateFile(f))).states[prUrl(8)], 'unknown');
}));

test('the refresh child kills a hung gh within its finite budget', () => withFixture((f) => {
  fakeGh(f, 'setInterval(() => {}, 1000);');
  const start = Date.now();
  refresh(f, [prUrl(10)]);
  assert.ok(Date.now() - start < 11000);
  assert.deepStrictEqual(JSON.parse(fs.readFileSync(stateFile(f))).states, {});
}));

test('render returns while gh waits for release and overlapping renders launch one refresh', { timeout: 20000 }, async () => {
  const f = fixture();
  try {
    writeJob(f, [childPr(11)]);
    f.env.GH_LOG = path.join(f.dir, 'gh.log');
    f.env.GH_RELEASE = path.join(f.dir, 'gh-release');
    fakeGh(f, `const fs = require('fs'); fs.appendFileSync(process.env.GH_LOG, 'call\\n'); const wait = setInterval(() => { if (!fs.existsSync(process.env.GH_RELEASE)) return; clearInterval(wait); process.stdout.write('{"data":{"p0":{"pr":{"state":"MERGED"}}}}'); }, 25);`);
    const outputs = await Promise.all(Array.from({ length: 4 }, () => new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [STATUSLINE], { env: { ...f.env, STATUSLINE_PR_REFRESH: '1', CURL_MODE: 'unavailable' }, stdio: ['pipe', 'pipe', 'pipe'] });
      let output = '', stderr = '';
      child.stdout.on('data', (d) => { output += d; });
      child.stderr.on('data', (d) => { stderr += d; });
      child.on('error', reject);
      child.on('close', (code) => code === 0 ? resolve(output) : reject(new Error(stderr)));
      child.stdin.end(JSON.stringify({ session_id: 'session-123', cwd: f.dir, model: { display_name: 'Opus' } }));
    })));
    assert.ok(!fs.existsSync(stateFile(f)), 'renders must finish before the held GitHub response is released');
    for (const raw of outputs) assert.deepStrictEqual(urlsIn(raw), [prUrl(11)]);
    fs.writeFileSync(f.env.GH_RELEASE, 'release');
    const until = Date.now() + 6000;
    while (!fs.existsSync(stateFile(f)) && Date.now() < until) await new Promise((resolve) => setTimeout(resolve, 25));
    assert.ok(fs.existsSync(stateFile(f)), 'background child must finish');
    assert.strictEqual(fs.readFileSync(f.env.GH_LOG, 'utf8'), 'call\n');
    const ready = runStatusline(f, 'unavailable', { raw: true });
    assert.ok(ready.includes('\x1b[38;5;141m#11\x1b[0m'));
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test('fallback review color belongs only to the exact current PR and never implies passed checks', () => withFixture((f) => {
  writeJob(f, [childPr(50), childPr(51)]);
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 51, url: prUrl(51), review_state: 'changes_requested' } } });
  assert.ok(raw.includes('\x1b[38;5;250m#50\x1b[0m'));
  assert.ok(raw.includes('\x1b[38;5;214m#51\x1b[0m'));
  const approved = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 51, url: prUrl(51), review_state: 'approved' } } });
  assert.ok(approved.includes('\x1b[38;5;250m#51\x1b[0m'));
}));

for (const failed of [true, false]) {
  test(`cached unknown preserves blocking-review fallback after ${failed ? 'failed' : 'partially unavailable'} GraphQL responses`, () => withFixture((f) => {
    writeJob(f, [childPr(50), childPr(51), childPr(51, 'other/main')]);
    const response = {
      data: { p0: { pr: { state: 'MERGED' } }, p1: null, p2: null },
      ...(failed ? { errors: [{ path: ['p1'], type: 'NOT_FOUND' }, { path: ['p2'], type: 'NOT_FOUND' }] } : {}),
    };
    fakeGh(f, `process.stdout.write(${JSON.stringify(JSON.stringify(response))}); process.exitCode = ${failed ? 1 : 0};`);
    refresh(f, [prUrl(50), prUrl(51), prUrl(51, 'other/main')]);
    const saved = JSON.parse(fs.readFileSync(stateFile(f)));
    assert.strictEqual(saved.states[prUrl(50)], 'merged');
    assert.strictEqual(saved.states[prUrl(51)], 'unknown');
    assert.strictEqual(saved.states[prUrl(51, 'other/main')], 'unknown');
    assert.ok(Date.now() - saved.at < 120000, 'exercise a fresh unknown cache, not the stale-cache fallback');
    for (const [review_state, color] of [['changes_requested', 214], ['pending', 214], ['approved', 250]]) {
      const raw = runStatusline(f, 'unavailable', { raw: true, payload: {
        pr: { number: 51, url: prUrl(51), review_state },
      } });
      assert.deepStrictEqual(new Set(urlsIn(raw)), new Set([prUrl(50), prUrl(51), prUrl(51, 'other/main')]));
      assert.ok(raw.includes(`\x1b[38;5;${color}m#51\x1b[0m`), `${review_state} must have fallback color ${color}`);
      assert.ok(raw.includes('\x1b[38;5;250mother/main#51\x1b[0m'), 'review fallback must not color another repository');
      assert.ok(raw.includes('\x1b[38;5;141m#50\x1b[0m'), 'unaffected known states retain their color');
    }
    const known = runStatusline(f, 'unavailable', { raw: true, payload: {
      pr: { number: 50, url: prUrl(50), review_state: 'changes_requested' },
    } });
    assert.ok(known.includes('\x1b[38;5;141m#50\x1b[0m'), 'a known cached state still takes precedence over the fallback');
  }));
}

test('fallback review color matches the canonical repository identity', () => withFixture((f) => {
  writeJob(f, [childPr(51)]);
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: {
    pr: { number: 51, url: prUrl(51, 'Acme/Main'), review_state: 'changes_requested' },
  } });
  assert.ok(raw.includes('\x1b[38;5;214m#51\x1b[0m'));
}));

test('a mismatched payload number cannot color another associated PR', () => withFixture((f) => {
  writeJob(f, [childPr(50), childPr(51)]);
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: {
    pr: { number: 51, url: prUrl(50), review_state: 'changes_requested' },
  } });
  assert.ok(raw.includes('\x1b[38;5;250m#50\x1b[0m'));
  assert.ok(raw.includes('\x1b[38;5;250m#51\x1b[0m'));
}));

test('FIFO metadata and corrupt state cache do not block the payload PR', () => withFixture((f) => {
  fs.mkdirSync(f.env.CLAUDE_JOB_DIR);
  const fifo = spawnSync('mkfifo', [path.join(f.env.CLAUDE_JOB_DIR, 'state.json')]);
  assert.strictEqual(fifo.status, 0);
  fs.mkdirSync(f.env.STATUSLINE_PR_CACHE_DIR);
  fs.writeFileSync(stateFile(f), '{bad');
  const raw = runStatusline(f, 'unavailable', { raw: true, payload: { pr: { number: 52, url: prUrl(52) } } });
  assert.deepStrictEqual(urlsIn(raw), [prUrl(52)]);
  assert.match(plain(raw), /ctx/);
}));

test('incremental transcript scan skips oversized messages and waits for complete typed events', () => withFixture((f) => {
  const transcript = path.join(f.dir, 'large.jsonl');
  const event = JSON.stringify({ type: 'pr-link', sessionId: 'session-123', prNumber: 53, prUrl: prUrl(53) });
  fs.writeFileSync(transcript, JSON.stringify({ type: 'user', content: 'x'.repeat(1048576 + 100) }) + '\n' + event.slice(0, -1));
  const options = { raw: true, transcript };
  assert.deepStrictEqual(urlsIn(runStatusline(f, 'unavailable', options)), []);
  assert.deepStrictEqual(urlsIn(runStatusline(f, 'unavailable', options)), []);
  fs.appendFileSync(transcript, '}\n');
  assert.deepStrictEqual(urlsIn(runStatusline(f, 'unavailable', options)), [prUrl(53)]);
  fs.writeFileSync(transcript, JSON.stringify({ type: 'pr-link', sessionId: 'session-123', prNumber: 54, prUrl: prUrl(54) }) + '\n');
  assert.deepStrictEqual(new Set(urlsIn(runStatusline(f, 'unavailable', options))), new Set([prUrl(53), prUrl(54)]), 'truncation restarts the scan without discarding session associations');
  const replaced = writeTranscript(f, [{ type: 'pr-link', sessionId: 'session-123', prNumber: 59, prUrl: prUrl(59) }]);
  assert.deepStrictEqual(new Set(urlsIn(runStatusline(f, 'unavailable', { raw: true, transcript: replaced }))), new Set([prUrl(53), prUrl(54), prUrl(59)]), 'a new transcript path retains earlier session associations');
}));

test('maximum GitHub names remain clickable within the column budget', () => withFixture((f) => {
  const repo = `${'o'.repeat(39)}/${'r'.repeat(100)}`;
  writeJob(f, [childPr(55), childPr(56, repo)]);
  const raw = runStatusline(f, 'unavailable', { raw: true });
  assert.deepStrictEqual(urlsIn(raw), [prUrl(55), prUrl(56, repo)]);
  for (const line of raw.split('\n')) assert.ok(plain(line).length <= 108, plain(line));
}));

test('expired refresh lock recovers and missing gh quietly writes unknown', () => withFixture((f) => {
  const lock = `${stateFile(f)}.lock`;
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, '11111111-1111-4111-8111-111111111111'), '');
  fs.utimesSync(lock, new Date(Date.now() - 60000), new Date(Date.now() - 60000));
  refresh(f, [prUrl(57)], { PATH: path.join(f.dir, 'bin') });
  assert.deepStrictEqual(JSON.parse(fs.readFileSync(stateFile(f))).states, {});
  assert.ok(!fs.existsSync(lock));
}));

test('symlinked renderer entry resolves its versioned helper beside the real source', () => withFixture((f) => {
  const entry = path.join(f.dir, 'local-statusline.mjs');
  fs.symlinkSync(STATUSLINE, entry);
  const result = spawnSync(process.execPath, [entry], {
    env: { ...f.env, CURL_MODE: 'unavailable' }, encoding: 'utf8', timeout: 5000,
    input: JSON.stringify({ cwd: f.dir, pr: { number: 58, url: prUrl(58) } }),
  });
  assert.strictEqual(result.status, 0, result.stderr);
  assert.deepStrictEqual(urlsIn(result.stdout), [prUrl(58)]);
}));
