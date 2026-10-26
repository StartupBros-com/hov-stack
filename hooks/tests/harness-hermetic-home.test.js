'use strict';
/**
 * The shared harness must sandbox $HOME for every spawned hook (issue #526).
 *
 * Expected-denial tests exercise real guard hooks, and a real denial writes a
 * real papercut record under os.homedir(). With the runner's own HOME that
 * meant ~9k fabricated records per 30 days in the LIVE store (99.6% of
 * runner-guard's records, 69% of git-guard's — measured 2026-08-27). These
 * tests pin the remedy at both layers: spawns default to a throwaway home,
 * requiring the harness re-points the test process's own home (for in-process
 * hook calls), and the denial write is REDIRECTED there, never suppressed —
 * the logging path stays live.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// The home the runner handed this process — what no hook under test may see.
// Captured BEFORE the harness require: requiring the harness deliberately
// re-points this process's HOME at the sandbox, so capturing after would
// compare sandbox to sandbox and prove nothing.
const REAL_HOME = process.env.HOME || os.homedir();

const { runHook, spawnNode, decisionOf, buildEnv } = require('./lib/harness');

const HOOK = 'PreToolUse/runner-guard.js';
const bash = (command) => ({ tool_name: 'Bash', tool_input: { command } });
// Same fixture as runner-guard.test.js: an expected denial.
const UNIT = 'actions.runner.StartupBros-com.runner-01.service';

test('suite launcher serializes every test file and preserves failures and sandbox cleanup', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-suite-launcher-'));
  try {
    // Inspect the real launcher's invocation without recursively running this suite.
    fs.writeFileSync(path.join(tmp, 'node'), `#!${process.execPath}
process.stdout.write(JSON.stringify({
  args: process.argv.slice(2),
  home: process.env.HOME,
  profile: process.env.USERPROFILE,
  seam: process.env.CLAUDE_SEAM_DIR,
  root: process.env.STRAY_DOT_GIT_FS_ROOT,
  homeExists: require('node:fs').existsSync(process.env.HOME),
}));
process.exit(Number(process.env.FIXTURE_EXIT));
`, { mode: 0o755 });
    const files = fs.readdirSync(__dirname)
      .filter((name) => name.endsWith('.test.js')).sort().map((name) => `./${name}`);
    for (const status of [0, 17]) {
      const result = spawnSync('/bin/bash', [path.join(__dirname, 'run.sh')], {
        env: buildEnv({ PATH: `${tmp}:${process.env.PATH}`, FIXTURE_EXIT: String(status) }),
        encoding: 'utf8',
        timeout: 10000,
      });
      assert.ifError(result.error);
      assert.strictEqual(result.status, status, result.stderr);
      const seen = JSON.parse(result.stdout);
      assert.deepStrictEqual(seen.args, ['--test', '--test-concurrency=1', ...files],
        'timed hook tests must not compete with other test files; no files may be omitted');
      assert.ok(seen.homeExists, 'launcher must create its sandbox before invoking node');
      assert.notStrictEqual(seen.home, process.env.HOME);
      assert.strictEqual(seen.profile, seen.home);
      assert.strictEqual(seen.root, path.join(seen.home, 'fs-root'));
      assert.strictEqual(fs.existsSync(seen.home), false, 'HOME is removed even on failure');
      assert.strictEqual(fs.existsSync(seen.seam), false, 'seam directory is removed even on failure');
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('spawned processes see a throwaway HOME, not the real one', async () => {
  const probe = path.join(os.tmpdir(), `home-probe-${process.pid}.js`);
  fs.writeFileSync(
    probe,
    'process.stdout.write(JSON.stringify({' +
      'home: process.env.HOME,' +
      'userprofile: process.env.USERPROFILE,' +
      "resolved: require('node:os').homedir()}));",
  );
  try {
    const res = await spawnNode(probe, {});
    assert.strictEqual(res.code, 0, `probe failed: ${res.stderr}`);
    const seen = JSON.parse(res.stdout);
    assert.ok(seen.home, 'spawned process must have HOME set');
    assert.notStrictEqual(seen.home, REAL_HOME,
      'spawned HOME must be a sandbox, not the real home');
    assert.strictEqual(seen.userprofile, seen.home,
      'USERPROFILE must point at the same sandbox');
    assert.strictEqual(seen.resolved, seen.home,
      'os.homedir() in the child must follow the sandbox HOME');
    assert.ok(fs.existsSync(seen.home), 'sandbox home must exist on disk');
  } finally {
    fs.rmSync(probe, { force: true });
  }
});

test('requiring the harness sandboxes the test process itself', () => {
  // Some tests require a hook and call run() IN-PROCESS — no spawn, no
  // buildEnv — so their denial writes use this process's HOME. That was the
  // second half of the leak: spawn-level sandboxing alone left those writing
  // to the live store.
  assert.ok(process.env.HOME, 'HOME must be set');
  assert.notStrictEqual(process.env.HOME, REAL_HOME,
    'requiring the harness must re-point process.env.HOME at a sandbox');
  assert.strictEqual(process.env.USERPROFILE, process.env.HOME,
    'USERPROFILE must point at the same sandbox');
  assert.strictEqual(os.homedir(), process.env.HOME,
    'os.homedir() must follow the sandbox in-process');
  assert.ok(fs.existsSync(process.env.HOME), 'sandbox home must exist on disk');
});

test('an explicit env.HOME override still wins over the sandbox default', async () => {
  const env = buildEnv({ HOME: '/nonexistent/override' });
  assert.strictEqual(env.HOME, '/nonexistent/override');
});

test('an expected denial is redirected into the sandbox store, not suppressed', async () => {
  const env = buildEnv({});
  assert.notStrictEqual(env.HOME, REAL_HOME,
    'buildEnv must default HOME away from the real home');

  const res = await runHook(HOOK, bash(`sudo systemctl restart ${UNIT}`));
  assert.strictEqual(decisionOf(res), 'block', 'fixture must still be denied');

  // The denial's papercut write must land under the sandbox. Asserting the
  // record EXISTS is the anti-suppression half: a harness that fixed the leak
  // by disabling logging would fail here.
  const dir = path.join(env.HOME, '.claude', 'papercuts');
  const files = fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'))
    : [];
  assert.ok(files.length >= 1,
    `expected a redirected papercut record under ${dir}; found none — ` +
      'the denial write was suppressed instead of redirected');
  const content = files
    .map((f) => fs.readFileSync(path.join(dir, f), 'utf8'))
    .join('\n');
  assert.match(content, /runner-guard/,
    'the redirected record must attribute the denying guard');
});
