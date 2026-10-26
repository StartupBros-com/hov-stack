'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const LIB = path.join(__dirname, '..', 'lib', 'seam-heartbeat.js');
const DECISION = path.join(__dirname, '..', 'lib', 'pretooluse-decision.js');

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'seam-hb-'));
}

/** Load a fresh copy of the module with CLAUDE_SEAM_DIR pointed somewhere safe. */
function freshLib(dir) {
  process.env.CLAUDE_SEAM_DIR = dir;
  delete require.cache[require.resolve(LIB)];
  // eslint-disable-next-line global-require
  return require(LIB);
}

test('keyFor is a stable opaque hash, not a guessed project slug', () => {
  const hb = freshLib(tmpdir());
  const a = hb.keyFor('/home/user/dotfiles');
  assert.match(a, /^[0-9a-f]{20}$/, 'filesystem-safe hex on any OS');
  assert.strictEqual(a, hb.keyFor('/home/user/dotfiles'), 'stable across calls');
  // `/a/b` and `/a-b` both slugify to `-a-b`; hashing must keep them distinct.
  assert.notStrictEqual(hb.keyFor('/a/b'), hb.keyFor('/a-b'));
});

test('the beat body carries the literal cwd, which is the real key', () => {
  // Claude Code's cwd->project-directory mapping changed between Apr and Jul
  // 2026 (`.` preserved, then folded to `-`). Reimplementing it silently
  // unpaired every worktree session, so nothing here derives it.
  const dir = tmpdir();
  const hb = freshLib(dir);
  const cwd = '/home/user/SITES/acme-agency/.claude/worktrees/acme-agency-plan';
  assert.strictEqual(hb.beat(cwd), true);
  const rec = JSON.parse(fs.readFileSync(hb.beatPath(cwd), 'utf8'));
  assert.strictEqual(rec.cwd, cwd);
});

test('no temp files are left behind by a successful beat', () => {
  const dir = tmpdir();
  const hb = freshLib(dir);
  hb.beat('/tmp/x');
  assert.deepStrictEqual(
    fs.readdirSync(dir).filter((f) => f.endsWith('.tmp')),
    [],
    'temp-then-rename must not leak .tmp files',
  );
});

test('beat writes a record carrying a timestamp and the parent pid', () => {
  const dir = tmpdir();
  const hb = freshLib(dir);
  assert.strictEqual(hb.beat('/home/user/dotfiles'), true);
  const target = hb.beatPath('/home/user/dotfiles');
  assert.ok(fs.existsSync(target), 'beat file should exist');
  const rec = JSON.parse(fs.readFileSync(target, 'utf8'));
  assert.ok(typeof rec.ts === 'number' && rec.ts > 0, 'carries a timestamp');
  assert.ok(typeof rec.ppid === 'number', 'carries the parent pid');
});

test('beat creates the seam directory on first use', () => {
  const dir = path.join(tmpdir(), 'nested', 'not-yet-there');
  const hb = freshLib(dir);
  assert.strictEqual(hb.beat('/tmp/x'), true);
  assert.ok(fs.existsSync(hb.beatPath('/tmp/x')));
});

test('beat overwrites in place — constant space, no growth', () => {
  const dir = tmpdir();
  const hb = freshLib(dir);
  hb.beat('/tmp/x');
  const first = fs.statSync(hb.beatPath('/tmp/x')).size;
  for (let i = 0; i < 25; i += 1) hb.beat('/tmp/x');
  const after = fs.statSync(hb.beatPath('/tmp/x')).size;
  assert.ok(Math.abs(after - first) < 32, 'file must not grow with repeated beats');
});

test('CLAUDE_SEAM_HEARTBEAT=0 is a hard kill switch', () => {
  const dir = tmpdir();
  const hb = freshLib(dir);
  process.env.CLAUDE_SEAM_HEARTBEAT = '0';
  try {
    assert.strictEqual(hb.beat('/tmp/x'), false);
    assert.ok(!fs.existsSync(hb.beatPath('/tmp/x')));
  } finally {
    delete process.env.CLAUDE_SEAM_HEARTBEAT;
  }
});

test('a failed beat leaves no temp file behind, even with cwd defaulted', () => {
  // REGRESSION: the cleanup path recomputed the target as beatPath('') when cwd
  // was defaulted, which hashes differently from the file actually written, so
  // it unlinked the wrong name and leaked a .tmp on every failure.
  const dir = tmpdir();
  const hb = freshLib(dir);
  // Make the rename fail by parking a DIRECTORY at the destination path.
  fs.mkdirSync(hb.beatPath(process.cwd()));
  assert.strictEqual(hb.beat(), false);
  assert.deepStrictEqual(
    fs.readdirSync(dir).filter((f) => f.endsWith('.tmp')),
    [],
    'no orphaned temp file after a failed beat',
  );
});

test('beat never throws when the target is unwritable', () => {
  // A file where the directory should be: mkdir and write both fail.
  const base = tmpdir();
  const blocked = path.join(base, 'blocked');
  fs.writeFileSync(blocked, 'not a directory');
  const hb = freshLib(blocked);
  assert.doesNotThrow(() => hb.beat('/tmp/x'));
  assert.strictEqual(hb.beat('/tmp/x'), false, 'reports failure rather than raising');
});

test('INTEGRATION: requiring pretooluse-decision beats, with no guard changes', () => {
  // Spawned so the module-load side effect is exercised for real rather than
  // being served from this process's require cache.
  const dir = tmpdir();
  execFileSync(process.execPath, ['-e', `require(${JSON.stringify(DECISION)})`], {
    env: { ...process.env, CLAUDE_SEAM_DIR: dir, CLAUDE_SEAM_HEARTBEAT: '1' },
  });
  const beats = fs.readdirSync(dir).filter((f) => f.endsWith('.beat'));
  assert.strictEqual(beats.length, 1, 'loading the shared decision lib must emit exactly one beat');
});

test('INTEGRATION: a broken heartbeat module cannot stop a guard from deciding', () => {
  // pretooluse-decision must still export a working deny() even when the beat
  // target is unusable — enforcement never depends on telemetry.
  const base = tmpdir();
  const blocked = path.join(base, 'blocked');
  fs.writeFileSync(blocked, 'not a directory');
  const out = execFileSync(
    process.execPath,
    ['-e', `process.stdout.write(require(${JSON.stringify(DECISION)}).deny('nope'))`],
    { env: { ...process.env, CLAUDE_SEAM_DIR: blocked }, encoding: 'utf8' },
  );
  const parsed = JSON.parse(out);
  assert.strictEqual(parsed.hookSpecificOutput.permissionDecision, 'deny');
});

test('INTEGRATION: the beat writes nothing to stdout', () => {
  // Hook stdout is parsed as a decision; a stray byte here would corrupt one.
  const dir = tmpdir();
  const out = execFileSync(process.execPath, ['-e', `require(${JSON.stringify(DECISION)})`], {
    env: { ...process.env, CLAUDE_SEAM_DIR: dir },
    encoding: 'utf8',
  });
  assert.strictEqual(out, '', 'module load must be silent on stdout');
});
