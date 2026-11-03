'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');
const { runHook, decisionOf, reasonOf, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'Stop/verify-on-stop.js';

// Build a temp project with a .claude/verify.sh that (a) touches a canary file so
// we can prove whether it executed, and (b) exits with `code`. The canary is the
// key signal for the trust-gate test: if it exists, repo shell ran.
function project(code) {
  const dir = mkTmp('vos-proj-');
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  const canary = path.join(dir, 'RAN');
  fs.writeFileSync(
    path.join(dir, '.claude', 'verify.sh'),
    `#!/usr/bin/env bash\ntouch ${JSON.stringify(canary)}\nexit ${code}\n`
  );
  return { dir, canary };
}

// Build a temp GIT project whose package.json typecheck script writes `$CI|$GIT_OPTIONAL_LOCKS`
// to a canary file (proving execution and the CI=1, GIT_OPTIONAL_LOCKS=0 env) and exits
// with `typecheckExit`. The baseline commit is back-dated to 2020 so it can
// never be mistaken for a commit made "during" a test's fake session.
function gitProject({ typecheckExit = 0, nodeModules = false } = {}) {
  const dir = mkTmp('vos-git-');
  const g = (args, env) =>
    execSync(`git ${args}`, { cwd: dir, env: { ...process.env, ...env }, stdio: 'ignore' });
  g('init -q -b main');
  g('config user.email test@test.invalid');
  g('config user.name test');
  const canary = path.join(dir, 'CANARY');
  fs.writeFileSync(
    path.join(dir, 'check.js'),
    `require('fs').writeFileSync(${JSON.stringify(canary)}, (process.env.CI || '') + '|' + (process.env.GIT_OPTIONAL_LOCKS || ''));process.exit(${typecheckExit});`
  );
  fs.writeFileSync(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 't', version: '1.0.0', scripts: { typecheck: 'node check.js' } })
  );
  fs.writeFileSync(path.join(dir, 'old.ts'), 'export const a = 1;\n');
  const past = { GIT_AUTHOR_DATE: '2020-01-01T00:00:00Z', GIT_COMMITTER_DATE: '2020-01-01T00:00:00Z' };
  g('add -A');
  g('commit -q -m baseline', past);
  if (nodeModules) fs.mkdirSync(path.join(dir, 'node_modules'));
  return { dir, canary, g };
}

// Fake session transcript whose first line carries the session-start timestamp.
function transcriptFor(dir, msAgo = 60000) {
  const tp = path.join(dir, 'transcript.jsonl');
  fs.writeFileSync(
    tp,
    JSON.stringify({ type: 'system', timestamp: new Date(Date.now() - msAgo).toISOString() }) + '\n'
  );
  return tp;
}

const trustEnv = (dir) => ({
  CLAUDE_VERIFY_TRUSTED_ROOTS: path.dirname(dir),
  HOME: dir,
  USERPROFILE: dir,
});

test('stop_hook_active=true short-circuits (loop safety) even when armed', async () => {
  const { dir, canary } = project(1);
  try {
    const p = { cwd: dir, stop_hook_active: true };
    // Armed via env, but stop_hook_active must win first so a blocking Stop hook
    // can never drive an infinite continuation loop.
    assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir } }));
    assert.ok(!fs.existsSync(canary), 'must not execute the verifier once already blocking');
  } finally {
    rmTmp(dir);
  }
});

test('untrusted dir: a repo-provided .claude/verify.sh is NOT auto-executed (F3)', async () => {
  const { dir, canary } = project(1);
  try {
    // No env opt-in; cwd is a temp dir not under any trusted root -> full no-op.
    const p = { cwd: dir, stop_hook_active: false };
    const env = { CLAUDE_VERIFY_TRUSTED_ROOTS: '/nonexistent', HOME: dir, USERPROFILE: dir };
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.ok(!fs.existsSync(canary), 'mere presence of .claude/verify.sh must not run shell in an untrusted dir');
  } finally {
    rmTmp(dir);
  }
});

test('explicit env opt-in: a failing verify.sh blocks the stop', async () => {
  const { dir, canary } = project(1);
  try {
    const p = { cwd: dir, stop_hook_active: false };
    const res = await runHook(HOOK, p, { env: { CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir } });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /Verification gate FAILED/i);
    assert.ok(fs.existsSync(canary), 'the trusted verifier should have executed');
  } finally {
    rmTmp(dir);
  }
});

test('trusted root: a passing verify.sh runs and allows the stop (pass-through)', async () => {
  const { dir, canary } = project(0);
  try {
    // Mark the project's parent as a trusted root, so isTrusted() is true without env=1.
    // The fixture is not a git repo, so change detection is unknown -> gate runs.
    const p = { cwd: dir, stop_hook_active: false };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'a trusted passing verifier runs, then allows the stop');
  } finally {
    rmTmp(dir);
  }
});

test('malformed input passes through', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
});

// --- v2: session-scoped change gating ---------------------------------------

test('docs-only session skips the gate entirely (no exec, no deps demand)', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: false });
  try {
    fs.writeFileSync(path.join(dir, 'notes.md'), '# nothing tsc cares about\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    // Even with node_modules missing AND a failing typecheck, a docs-only
    // session must pass through untouched.
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(!fs.existsSync(canary), 'verifier must not run for a docs-only session');
  } finally {
    rmTmp(dir);
  }
});

test('pre-existing dirty code (old mtime, parked checkout) does not trigger the gate', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: true });
  try {
    // Simulate weeks-old local drift: a modified .ts whose mtime long predates
    // this session (the prbot parked-checkout regression).
    fs.appendFileSync(path.join(dir, 'old.ts'), '// drift\n');
    const old = new Date(Date.now() - 10 * 86400000);
    fs.utimesSync(path.join(dir, 'old.ts'), old, old);
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(!fs.existsSync(canary), 'weeks-old dirt is not this session\'s work');
  } finally {
    rmTmp(dir);
  }
});

test('fresh code change runs the gate with CI=1', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    fs.writeFileSync(path.join(dir, 'new.ts'), 'export const b = 2;\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'a session-fresh .ts change must trigger verification');
    assert.strictEqual(fs.readFileSync(canary, 'utf8'), '1|0', 'verify command must run with CI=1 and GIT_OPTIONAL_LOCKS=0');
  } finally {
    rmTmp(dir);
  }
});

test('fresh code change + failing typecheck still blocks', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: true });
  try {
    fs.writeFileSync(path.join(dir, 'new.ts'), 'export const b = 2;\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    const res = await runHook(HOOK, p, { env: trustEnv(dir) });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /Verification gate FAILED/i);
    assert.ok(fs.existsSync(canary));
  } finally {
    rmTmp(dir);
  }
});

test('missing node_modules yields the environmental block, not a fake failure', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: false });
  try {
    fs.writeFileSync(path.join(dir, 'new.ts'), 'export const b = 2;\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    const res = await runHook(HOOK, p, { env: trustEnv(dir) });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /node_modules missing/i);
    assert.match(reasonOf(res), /npm ci/, 'no lockfile in fixture, so the npm install command is surfaced');
    assert.ok(!fs.existsSync(canary), 'the verify command must not run before deps exist');
  } finally {
    rmTmp(dir);
  }
});

test('commit made during the session triggers the gate on a clean tree', async () => {
  const { dir, canary, g } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    fs.writeFileSync(path.join(dir, 'b.ts'), 'export const c = 3;\n');
    g('add b.ts');
    g('commit -q -m session-work'); // committer date = now, inside the session window
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'committed session work must be verified even with a clean tree');
  } finally {
    rmTmp(dir);
  }
});

test('no transcript timestamp: conservative, dirty code runs the gate', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    fs.appendFileSync(path.join(dir, 'old.ts'), '// drift\n');
    const old = new Date(Date.now() - 10 * 86400000);
    fs.utimesSync(path.join(dir, 'old.ts'), old, old);
    const p = { cwd: dir, stop_hook_active: false }; // no transcript_path at all
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'without a session timestamp the gate must err toward verifying');
  } finally {
    rmTmp(dir);
  }
});

test('explicit CLAUDE_VERIFY_ON_STOP=1 bypasses change gating (claude-loop contract)', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    // Zero session changes of any kind, yet the explicit arm must still verify.
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    const env = { CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir };
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.ok(fs.existsSync(canary), 'explicit arm always verifies');
  } finally {
    rmTmp(dir);
  }
});

// A pull or a launchpad fast-forward brings other sessions' merged commits into
// HEAD with committer dates inside this session's window. Found 2026-10-29: a
// read-only recovery session with no diff of its own hit the
// missing-dependency block on every stop.
test('commits already on the default remote branch are not this session\'s work', async () => {
  const { dir, canary, g } = gitProject({ typecheckExit: 1, nodeModules: false });
  try {
    fs.writeFileSync(path.join(dir, 'landed.ts'), 'export const d = 4;\n');
    g('add landed.ts');
    g('commit -q -m landed-by-another-session'); // committer date = now
    g('update-ref refs/remotes/origin/main HEAD'); // it is on origin/main
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(!fs.existsSync(canary), 'commits reachable from origin/main must not arm the gate');
  } finally {
    rmTmp(dir);
  }
});

test('a session commit beyond the default remote branch still triggers the gate', async () => {
  const { dir, canary, g } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    g('update-ref refs/remotes/origin/main HEAD');
    fs.writeFileSync(path.join(dir, 'mine.ts'), 'export const e = 5;\n');
    g('add mine.ts');
    g('commit -q -m session-work');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'unlanded session commits must still be verified');
  } finally {
    rmTmp(dir);
  }
});

// A hook process launched without mise activation has no bun or pnpm on PATH,
// so `bun run typecheck` died with "bun: not found" although the typecheck
// itself passed (17 such blocks in the 30 days to 2026-11-03). The fixture's PATH is
// one empty directory, so only the shims dir can supply `bun`.
function bunProject() {
  const dir = mkTmp('vos-bun-');
  fs.writeFileSync(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 't', version: '1.0.0', scripts: { typecheck: 'true' } })
  );
  fs.writeFileSync(path.join(dir, 'bun.lock'), '{}\n');
  fs.mkdirSync(path.join(dir, 'node_modules'));
  fs.mkdirSync(path.join(dir, 'emptybin'));
  const canary = path.join(dir, 'CANARY');
  const shim = (dataDir) => {
    const shims = path.join(dataDir, 'shims');
    fs.mkdirSync(shims, { recursive: true });
    fs.writeFileSync(path.join(shims, 'bun'), `#!/bin/sh\necho "$*" > ${JSON.stringify(canary)}\n`, { mode: 0o755 });
  };
  return { dir, canary, shim };
}

test('the verify command finds bun through mise\'s shims when PATH lacks it', async () => {
  const { dir, canary, shim } = bunProject();
  try {
    shim(path.join(dir, '.local', 'share', 'mise')); // mise's default data dir under HOME
    const p = { cwd: dir, stop_hook_active: false };
    const env = {
      CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir,
      PATH: path.join(dir, 'emptybin'), MISE_DATA_DIR: '', XDG_DATA_HOME: '',
    };
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(fs.readFileSync(canary, 'utf8').trim(), 'run typecheck');
  } finally {
    rmTmp(dir);
  }
});

test('MISE_DATA_DIR moves the shims dir the verify command uses', async () => {
  const { dir, canary, shim } = bunProject();
  try {
    const dataDir = path.join(dir, 'mise-data');
    shim(dataDir);
    const p = { cwd: dir, stop_hook_active: false };
    const env = {
      CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir,
      PATH: path.join(dir, 'emptybin'), MISE_DATA_DIR: dataDir, XDG_DATA_HOME: '',
    };
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(fs.readFileSync(canary, 'utf8').trim(), 'run typecheck');
  } finally {
    rmTmp(dir);
  }
});

// --- One-shot cycle and output clipping --------------------------------------
// Re-cut from the #1515 composition block when the hand-back half was retired
// (2026-11-03). Real hook processes and real verify commands; nothing is faked.

// A verify.sh that exits `verifyExit`, armed explicitly, with an fs observer
// that logs every *Sync call naming a path under HOME/.claude without changing
// its result, so the cycle test can prove the hook keeps no state there.
function stopCycleFixture(verifyExit = 1) {
  const home = mkTmp('vos-cycle-home-');
  const binDir = mkTmp('vos-cycle-bin-');
  const { dir, canary } = project(verifyExit);
  const ioLog = path.join(binDir, 'STATE-IO');
  const audit = path.join(binDir, 'audit-state.js');
  const watched = path.join(home, '.claude') + path.sep;
  fs.writeFileSync(audit, `const fs = require('fs');
const append = fs.appendFileSync;
for (const [name, original] of Object.entries(fs)) {
  if (!name.endsWith('Sync') || typeof original !== 'function') continue;
  fs[name] = function (...args) {
    if (args.some(arg => typeof arg === 'string' && arg.startsWith(${JSON.stringify(watched)}))) {
      append(${JSON.stringify(ioLog)}, name + ' ' + args[0] + '\\n');
    }
    return original.apply(this, args);
  };
}
`);
  const env = {
    HOME: home, USERPROFILE: home, CLAUDE_VERIFY_ON_STOP: '1', CLAUDE_LOOP_GUARD: '0',
    NODE_OPTIONS: `--require ${audit}`,
  };
  const stop = (active, extraEnv = {}) => runHook(HOOK, {
    cwd: dir, stop_hook_active: active, session_id: 'sess-cycle',
    last_assistant_message: 'All done.',
  }, { env: { ...env, ...extraEnv } });
  const activity = () => fs.existsSync(ioLog) ? fs.readFileSync(ioLog, 'utf8').trim().split('\n').filter(Boolean) : [];
  const cleanup = () => { rmTmp(home); rmTmp(binDir); rmTmp(dir); };
  return { home, binDir, dir, canary, audit, watched, ioLog, env, stop, activity, cleanup };
}

test('one-shot: the initial failing Stop blocks; sequential and concurrent active retries are quiet and keep no state', async () => {
  const f = stopCycleFixture();
  try {
    // The observer must be live, or "no state I/O" below would pass vacuously.
    execSync(`node -e ${JSON.stringify(`require('fs').existsSync(${JSON.stringify(f.watched + 'probe')})`)}`,
      { env: { ...process.env, ...f.env }, stdio: 'ignore' });
    assert.strictEqual(f.activity().length, 1, 'precondition: the I/O observer records a read under HOME/.claude');
    fs.unlinkSync(f.ioLog);

    const res = await f.stop(false);
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /Verification gate FAILED/);
    assert.ok(fs.existsSync(f.canary), 'verification actually ran');
    fs.unlinkSync(f.canary);
    for (let i = 0; i < 3; i++) assertQuietPassThrough(await f.stop(true));
    for (const r of await Promise.all(Array.from({ length: 8 }, () => f.stop(true)))) assertQuietPassThrough(r);
    assert.ok(!fs.existsSync(f.canary), 'no active-retry verification');
    assert.deepStrictEqual(f.activity(), [], 'no Stop reads or writes anything under HOME/.claude');
  } finally { f.cleanup(); }
});

test('each fresh false Stop runs verification anew', async () => {
  const f = stopCycleFixture();
  try {
    for (let i = 0; i < 2; i++) {
      assert.strictEqual(decisionOf(await f.stop(false)), 'block');
      assert.ok(fs.existsSync(f.canary));
      fs.unlinkSync(f.canary);
      assertQuietPassThrough(await f.stop(true));
      assert.ok(!fs.existsSync(f.canary));
    }
  } finally { f.cleanup(); }
});

test('clipping retains first 1500 and last 1000 characters plus the explicit marker', async (t) => {
  for (const size of [2499, 2500, 2501, 6000]) await t.test(String(size), async () => {
    const f = stopCycleFixture();
    try {
      const out = 'FIRST-ERROR:' + 'x'.repeat(size - 23) + ':LAST-ERROR';
      assert.strictEqual(out.length, size);
      fs.writeFileSync(path.join(f.dir, 'diagnostics.txt'), out);
      fs.writeFileSync(path.join(f.dir, '.claude', 'verify.sh'), 'cat diagnostics.txt\nexit 1\n');
      const res = await f.stop(false);
      assert.strictEqual(decisionOf(res), 'block');
      const captured = reasonOf(res).split('\n\n--- output ---\n')[1];
      if (size <= 2500) {
        assert.strictEqual(captured, out, 'short output is unchanged');
      } else {
        const marker = size === 2501 ? '\n…[1 chars elided]…\n' : '\n…[3500 chars elided]…\n';
        assert.strictEqual(captured, out.slice(0, 1500) + marker + out.slice(-1000));
        assert.strictEqual(captured.length, size === 2501 ? 2520 : 2523, '2500 retained characters PLUS marker');
      }
    } finally { f.cleanup(); }
  });
});
