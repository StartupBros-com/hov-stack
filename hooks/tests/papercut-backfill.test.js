'use strict';
/**
 * scripts/papercut-backfill.js (dotfiles#1553): records the
 * <tool_use_error> failures PostToolUseFailure never receives, idempotently,
 * and measures per-tool capture of the failures it does receive.
 *
 * Planted negatives: a Bash failure whose output merely CONTAINS the tag, a
 * tagged failure the store already holds, and a second run over the same
 * transcript must all append nothing.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { spawnNode, mkTmp, rmTmp } = require('./lib/harness');

const SCRIPT = path.resolve(__dirname, '..', '..', 'scripts', 'papercut-backfill.js');
const CWD = '/w/proj';
const SLUG = '-w-proj.jsonl';
const SESSION = '11111111-2222-3333-4444-555566667777';
const ISOLATION = 'This session is isolated in the worktree /home/tester/proj/.claude/worktrees/x. '
  + 'Edit the worktree copy of this file instead of the shared-checkout path.';

let base;
let projects;
let store;

beforeEach(() => {
  base = mkTmp('pcbf-');
  projects = path.join(base, 'projects');
  store = path.join(base, 'store');
  fs.mkdirSync(path.join(projects, '-w-proj', SESSION, 'subagents'), { recursive: true });
});

afterEach(() => rmTmp(base));

const ago = (minutes) => new Date(Date.now() - minutes * 60000).toISOString();

function use(id, name, input, ts) {
  return { type: 'assistant', timestamp: ts, sessionId: SESSION, cwd: CWD,
    message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } };
}
function result(id, content, ts, extra = {}) {
  return { type: 'user', timestamp: ts, sessionId: SESSION, cwd: CWD, ...extra,
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, is_error: true, content }] } };
}
function writeTranscript(rel, rows) {
  fs.writeFileSync(path.join(projects, '-w-proj', rel), rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
}

/** The standard fixture: one row per class the script must tell apart. */
function standardTranscript() {
  writeTranscript(`${SESSION}.jsonl`, [
    use('toolu_01AAAAAAAAAAAAAAAAAAAAAA', 'Write', { file_path: '/tmp/run/x.json', content: '{}' }, ago(60)),
    result('toolu_01AAAAAAAAAAAAAAAAAAAAAA', `<tool_use_error>${ISOLATION}</tool_use_error>`, ago(60)),
    // Contains the tag but does not START with it: ordinary Bash output.
    use('toolu_01BBBBBBBBBBBBBBBBBBBBBB', 'Bash', { command: 'printf x' }, ago(50)),
    result('toolu_01BBBBBBBBBBBBBBBBBBBBBB', 'Exit code 1\n<tool_use_error>printed by the command</tool_use_error>', ago(50)),
    use('toolu_01CCCCCCCCCCCCCCCCCCCCCC', 'Bash', { command: 'rm -rf build' }, ago(40)),
    result('toolu_01CCCCCCCCCCCCCCCCCCCCCC', 'PreToolUse:Bash hook error: BLOCKED by dcg', ago(40)),
    use('toolu_01DDDDDDDDDDDDDDDDDDDDDD', 'Bash', { command: 'rm -rf x' }, ago(30)),
    result('toolu_01DDDDDDDDDDDDDDDDDDDDDD', 'Permission to use Bash with command rm -rf x has been denied.', ago(30)),
    use('toolu_01FFFFFFFFFFFFFFFFFFFFFF', 'Bash', { command: 'false' }, ago(20)),
    result('toolu_01FFFFFFFFFFFFFFFFFFFFFF', 'Exit code 1', ago(20)),
    // Outside a 1-day window.
    use('toolu_01GGGGGGGGGGGGGGGGGGGGGG', 'Edit', { file_path: '/w/a' }, ago(3 * 1440)),
    result('toolu_01GGGGGGGGGGGGGGGGGGGGGG', '<tool_use_error>String to replace not found in file.</tool_use_error>', ago(3 * 1440)),
  ]);
}

function run(args, env = {}) {
  return spawnNode(SCRIPT, { argv: ['--projects', projects, ...args], env: { PAPERCUT_STORE: store, ...env } });
}

function storeRecords() {
  const file = path.join(store, SLUG);
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

const coverage = () => JSON.parse(fs.readFileSync(path.join(store, '.backfill-coverage.json'), 'utf8'));

test('backfills only results that START with <tool_use_error>, as the hook would record them', async () => {
  standardTranscript();
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  const recs = storeRecords();
  assert.strictEqual(recs.length, 1, JSON.stringify(recs));
  const [r] = recs;
  assert.strictEqual(r.tool, 'Write');
  assert.strictEqual(r.source, 'transcript');
  assert.strictEqual(r.tu, 'AAAAAAAAAAAA');
  assert.strictEqual(r.target, '/tmp/run/x.json');
  assert.strictEqual(r.session, '66667777');
  assert.match(r.sig, /^write:this session is isolated in the worktree <path>/);
  assert.match(r.err, /^This session is isolated/, 'the tag itself is not part of the error');
  assert.ok(Math.abs(Date.parse(r.ts) - (Date.now() - 3600000)) < 120000, 'ts is the transcript time, not now');
  assert.match(res.stdout, /backfilled 1 of 1 <tool_use_error> results/);
});

test('every other class is counted, not recorded', async () => {
  standardTranscript();
  await run(['--days', '1']);
  const c = coverage();
  assert.deepStrictEqual(c.tools.Write, {
    tagged: 1, backfilled: 1, already: 0, captured_tagged: 0, dropped: 0,
    visible: 0, visible_captured: 0, filtered: 0, hook_block: 0, permission: 0,
  });
  const b = c.tools.Bash;
  assert.deepStrictEqual([b.visible, b.visible_captured, b.hook_block, b.permission, b.filtered, b.tagged],
    [1, 0, 1, 1, 1, 0]);
  assert.strictEqual(c.tools.Edit, undefined, 'a failure outside --days is not read at all');
  assert.strictEqual(c.days, 1);
  assert.strictEqual(c.dry_run, false);
});

test('a second run over the same transcripts appends nothing', async () => {
  standardTranscript();
  await run(['--days', '1']);
  const again = await run(['--days', '1']);
  assert.strictEqual(again.code, 0, again.stderr);
  assert.strictEqual(storeRecords().length, 1);
  assert.strictEqual(coverage().tools.Write.already, 1);
  assert.match(again.stdout, /backfilled 0 of 1 <tool_use_error> results \(1 already recorded/);
});

test('a tagged failure the hook already recorded is not duplicated', async () => {
  writeTranscript(`${SESSION}.jsonl`, [
    use('toolu_01EEEEEEEEEEEEEEEEEEEEEE', 'Read', { file_path: '/w/big' }, ago(10)),
    result('toolu_01EEEEEEEEEEEEEEEEEEEEEE', '<tool_use_error>File does not exist.</tool_use_error>', ago(10)),
  ]);
  fs.mkdirSync(store, { recursive: true });
  fs.writeFileSync(path.join(store, SLUG), JSON.stringify({
    ts: new Date(Date.now() - 10 * 60000 + 2000).toISOString(), sig: 'no_such_file:big', tool: 'Read',
    err: 'File does not exist.', cmd: '', target: '/w/big', cwd: CWD, session: '66667777', agent: '', source: 'auto',
  }) + '\n');
  await run(['--days', '1']);
  assert.strictEqual(storeRecords().length, 1, 'only the hook record');
  assert.strictEqual(coverage().tools.Read.captured_tagged, 1);
});

test('an earlier backfill never passes for the hook: the same refusal 5 s later is still recorded', async () => {
  const tA = ago(60);
  const tB = new Date(Date.parse(tA) + 5000).toISOString();
  const a = [
    use('toolu_01AAAAAAAAAAAAAAAAAAAAAA', 'Write', { file_path: '/tmp/run/x.json', content: '{}' }, tA),
    result('toolu_01AAAAAAAAAAAAAAAAAAAAAA', `<tool_use_error>${ISOLATION}</tool_use_error>`, tA),
  ];
  writeTranscript(`${SESSION}.jsonl`, a);
  await run(['--days', '1']);
  assert.strictEqual(storeRecords().length, 1, 'precondition: run 1 backfilled refusal A');
  writeTranscript(`${SESSION}.jsonl`, [...a,
    use('toolu_01HHHHHHHHHHHHHHHHHHHHHH', 'Write', { file_path: '/tmp/run/x.json', content: '{}' }, tB),
    result('toolu_01HHHHHHHHHHHHHHHHHHHHHH', `<tool_use_error>${ISOLATION}</tool_use_error>`, tB),
  ]);
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.deepStrictEqual(storeRecords().map((r) => r.tu), ['AAAAAAAAAAAA', 'HHHHHHHHHHHH']);
  const w = coverage().tools.Write;
  assert.deepStrictEqual([w.already, w.backfilled, w.captured_tagged], [1, 1, 0]);
});

test('a hook-visible failure the hook recorded counts as captured', async () => {
  writeTranscript(`${SESSION}.jsonl`, [
    use('toolu_01HHHHHHHHHHHHHHHHHHHHHH', 'Bash', { command: 'make' }, ago(5)),
    result('toolu_01HHHHHHHHHHHHHHHHHHHHHH', 'Exit code 2\nmake: *** No rule to make target', ago(5)),
  ]);
  fs.mkdirSync(store, { recursive: true });
  fs.writeFileSync(path.join(store, SLUG), JSON.stringify({
    ts: ago(5), sig: 'bash:make: *** no rule to make target', tool: 'Bash',
    err: 'Exit code 2\nmake: *** No rule to make target', cmd: 'make', target: '', cwd: CWD,
    session: '66667777', agent: '', source: 'auto',
  }) + '\n');
  await run(['--days', '1']);
  assert.deepStrictEqual([coverage().tools.Bash.visible, coverage().tools.Bash.visible_captured], [1, 1]);
});

test('one hook record accounts for one failure: an identical retry 5 s later reads as missed', async () => {
  const t1 = ago(5);
  const t2 = new Date(Date.parse(t1) + 5000).toISOString();
  writeTranscript(`${SESSION}.jsonl`, [
    use('toolu_01HHHHHHHHHHHHHHHHHHHHHH', 'Bash', { command: 'make' }, t1),
    result('toolu_01HHHHHHHHHHHHHHHHHHHHHH', 'Exit code 2\nmake: *** No rule to make target', t1),
    use('toolu_01JJJJJJJJJJJJJJJJJJJJJJ', 'Bash', { command: 'make' }, t2),
    result('toolu_01JJJJJJJJJJJJJJJJJJJJJJ', 'Exit code 2\nmake: *** No rule to make target', t2),
  ]);
  fs.mkdirSync(store, { recursive: true });
  fs.writeFileSync(path.join(store, SLUG), JSON.stringify({
    ts: t1, sig: 'bash:make: *** no rule to make target', tool: 'Bash',
    err: 'Exit code 2\nmake: *** No rule to make target', cmd: 'make', target: '', cwd: CWD,
    session: '66667777', agent: '', source: 'auto',
  }) + '\n');
  await run(['--days', '1']);
  assert.deepStrictEqual([coverage().tools.Bash.visible, coverage().tools.Bash.visible_captured], [2, 1]);
});

test('an unreadable transcript directory is counted and warned, not read as a clean week', async (t) => {
  if (process.getuid && process.getuid() === 0) { t.skip('root reads a mode-000 directory'); return; }
  standardTranscript();
  const locked = path.join(projects, '-w-other');
  fs.mkdirSync(locked);
  fs.chmodSync(locked, 0o000);
  try {
    assert.throws(() => fs.readdirSync(locked), /EACCES/, 'precondition: the directory is unreadable');
    const res = await run(['--days', '1']);
    assert.strictEqual(res.code, 0, res.stderr);
    assert.strictEqual(coverage().scan_errors, 1);
    assert.match(res.stdout, /^WARN papercut backfill: 1 transcript director\(ies\) or file\(s\) unreadable/m);
    assert.match(res.stderr, /unreadable directory .*-w-other: EACCES/);
    assert.strictEqual(storeRecords().length, 1, 'the readable transcripts are still backfilled');
  } finally {
    fs.chmodSync(locked, 0o755);
  }
});

test('a clean scan records scan_errors 0', async () => {
  standardTranscript();
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.strictEqual(coverage().scan_errors, 0);
  assert.doesNotMatch(res.stdout, /unreadable/);
});

// The single-writer lock is a kernel flock(2) the run takes through flock(1)
// on <store>/.backfill.lock, held for exactly the run's lifetime. A test that
// needs a live holder takes the same lock from a child process and waits
// until it is held before the run starts, else the run can win the race and
// the holder blocks instead.
const lockHeld = (lock) => spawnSync('flock', ['--nonblock', '--conflict-exit-code', '75', lock, 'true']).status === 75;

function holdLock(lock) {
  const holder = spawn('flock', ['--no-fork', lock, 'sleep', '30'], { stdio: 'ignore' });
  for (let i = 0; i < 200 && !lockHeld(lock); i++) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
  assert.ok(lockHeld(lock), 'precondition: the holder has the lock');
  return holder;
}

test('a run that finds another live run holding the lock appends nothing and says so', async () => {
  standardTranscript();
  fs.mkdirSync(store, { recursive: true });
  const lock = path.join(store, '.backfill.lock');
  fs.writeFileSync(lock, String(process.pid)); // the diagnostic a locked run leaves in the file
  const holder = holdLock(lock);
  try {
    const res = await run(['--days', '1']);
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, new RegExp(`^WARN papercut backfill: skipped, another run \\(pid ${process.pid}\\) holds`, 'm'));
    assert.deepStrictEqual(storeRecords(), []);
    assert.ok(!fs.existsSync(path.join(store, '.backfill-coverage.json')));
    assert.strictEqual(fs.readFileSync(lock, 'utf8'), String(process.pid), 'a live holder keeps its lock');
  } finally {
    holder.kill();
  }
});

test('a killed run\'s lock file (held by nobody) does not block the next run', async () => {
  standardTranscript();
  fs.mkdirSync(store, { recursive: true });
  const lock = path.join(store, '.backfill.lock');
  const dead = spawnSync(process.execPath, ['-e', '']).pid;
  assert.throws(() => process.kill(dead, 0), /ESRCH/, 'precondition: the holder is dead');
  fs.writeFileSync(lock, String(dead));
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.strictEqual(storeRecords().length, 1);
  assert.ok(!lockHeld(lock), 'the lock is free after the run');
});

// pro-gate round 2 P2 (the stale takeover, old line 325): a run that decides
// from the lock file's content whether its holder is dead removes a lock a
// live run holds. Here the file names a dead pid while a live process holds
// the kernel lock, which is the state the instant after a takeover has linked
// a fresh lock: the run must honor the lock, not remove it.
test('round 2 P2 (line 325): a lock a live run holds is never removed on the strength of its content', async () => {
  standardTranscript();
  fs.mkdirSync(store, { recursive: true });
  const lock = path.join(store, '.backfill.lock');
  const dead = spawnSync(process.execPath, ['-e', '']).pid;
  assert.throws(() => process.kill(dead, 0), /ESRCH/, 'precondition: the pid in the file is dead');
  fs.writeFileSync(lock, String(dead));
  const ino = fs.statSync(lock).ino;
  const holder = holdLock(lock);
  try {
    const res = await run(['--days', '1']);
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /^WARN papercut backfill: skipped, another run/m);
    assert.deepStrictEqual(storeRecords(), [], 'the run did not write');
    assert.strictEqual(fs.statSync(lock).ino, ino, 'the held lock is the same file');
    assert.ok(lockHeld(lock), 'the holder still has the lock');
  } finally {
    holder.kill();
  }
});

// pro-gate round 2 P2 (pid reuse, old line 324): a lock file left by an
// unclean exit names a pid; once the kernel hands that pid to an unrelated
// process, a liveness check on the pid reads the lock as held for as long as
// that process lives. The kernel lock dies with its holder, so the content
// must not matter: this test process is the "unrelated live process".
test('round 2 P2 (line 324): a lock file naming a live, unrelated pid does not hold the lock', async () => {
  standardTranscript();
  fs.mkdirSync(store, { recursive: true });
  const lock = path.join(store, '.backfill.lock');
  fs.writeFileSync(lock, String(process.pid));
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.doesNotMatch(res.stdout, /^WARN papercut backfill: skipped/m, 'a reused pid does not hold the lock');
  assert.strictEqual(storeRecords().length, 1, 'the run backfilled');
  assert.ok(!lockHeld(lock), 'the lock is free after the run');
});

test('without flock(1) on PATH the run proceeds unlocked and says so', async () => {
  standardTranscript();
  const empty = path.join(base, 'empty-path');
  fs.mkdirSync(empty);
  const res = await run(['--days', '1'], { PATH: empty });
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /^WARN papercut backfill: flock\(1\) not found; running without the single-writer lock$/m);
  assert.strictEqual(storeRecords().length, 1);
});

test('lines(): a line spanning the 1 MiB read boundary and a final line with no newline both arrive whole', () => {
  const { lines } = require(SCRIPT);
  const CHUNK = 1 << 20;
  const file = path.join(base, 'boundary.jsonl');
  const a = 'a'.repeat(CHUNK - 10);
  const b = 'b'.repeat(100); // starts 9 bytes before the boundary, ends after it
  fs.writeFileSync(file, `${a}\n${b}\nccccc`);
  const got = [...lines(file)].map((buf) => buf.toString('utf8'));
  assert.deepStrictEqual(got.map((s) => s.length), [CHUNK - 10, 100, 5]);
  assert.strictEqual(got[1], b);
  assert.strictEqual(got[2], 'ccccc');
});

test('subagent transcripts are read and keep the agent id', async () => {
  writeTranscript(path.join(SESSION, 'subagents', 'agent-a1b2c3d4e5f60718.jsonl'), [
    use('toolu_01JJJJJJJJJJJJJJJJJJJJJJ', 'Write', { file_path: '/tmp/r/REPORT.md' }, ago(5)),
    result('toolu_01JJJJJJJJJJJJJJJJJJJJJJ',
      '<tool_use_error>Subagents should return findings as text, not write report files.</tool_use_error>',
      ago(5), { agentId: 'a1b2c3d4e5f60718' }),
  ]);
  await run(['--days', '1']);
  const [r] = storeRecords();
  assert.strictEqual(r.agent, 'e5f60718');
  assert.match(r.sig, /^write:subagents should return findings as text/);
});

test('--dry-run writes neither records nor the coverage file', async () => {
  standardTranscript();
  const res = await run(['--days', '1', '--dry-run']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /would backfill 1 of 1/);
  assert.deepStrictEqual(storeRecords(), []);
  assert.ok(!fs.existsSync(path.join(store, '.backfill-coverage.json')));
});

test('a store file over its size cap: the drop is counted and printed as a WARN', async () => {
  standardTranscript();
  fs.mkdirSync(store, { recursive: true });
  fs.writeFileSync(path.join(store, SLUG), '');
  fs.truncateSync(path.join(store, SLUG), 33 * 1024 * 1024); // sparse, over MAX_LOG_BYTES
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.strictEqual(coverage().tools.Write.dropped, 1);
  assert.strictEqual(coverage().tools.Write.backfilled, 0);
  assert.match(res.stdout, /^WARN papercut backfill: 1 record\(s\) dropped/m);
});

// `papercut staleness` reads the newest store mtime as proof the capture hook is
// alive, and harness-weekly runs the backfill right before it. These run the
// real reader against a store whose last hook write is 5 days old.
const PAPERCUT_CLI = path.resolve(__dirname, '..', '..', 'bin', 'papercut.py');
const papercutLog = require('../PostToolUseFailure/papercut-log.js');

function staleness() {
  const res = spawnSync('python3', [PAPERCUT_CLI, 'staleness', '--max-gap-hours', '72'], {
    env: { ...process.env, PAPERCUT_STORE: store, CLAUDE_CONFIG_DIR: base }, encoding: 'utf8',
  });
  assert.strictEqual(res.status, 0, res.stderr);
  return res.stdout;
}
function seedOldHookRecord() {
  const old = new Date(Math.floor(Date.now() / 1000) * 1000 - 5 * 86400000); // whole seconds round-trip exactly
  fs.mkdirSync(store, { recursive: true });
  fs.writeFileSync(path.join(store, SLUG), JSON.stringify({
    ts: old.toISOString(), sig: 'exit_1:false', tool: 'Bash', err: 'Exit code 1', cmd: 'false',
    target: '', cwd: CWD, session: '66667777', agent: '', source: 'auto',
  }) + '\n');
  fs.utimesSync(path.join(store, SLUG), old, old);
  return old;
}
// The session goes on after the capture; a record newer than it reads as clock skew.
// A second later, not a fresh Date: the kernel stamps an append below the
// millisecond and a Date truncates to it, so a Date read in the capture's own
// millisecond lands before the capture it follows.
function touchSessionAfterCapture({ nowMs = Date.now() } = {}) {
  const after = new Date(nowMs + 1000);
  fs.utimesSync(path.join(projects, '-w-proj', `${SESSION}.jsonl`), after, after);
}

test('a backfill run does not make a dead capture hook read healthy', async () => {
  standardTranscript();
  const old = seedOldHookRecord();
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.strictEqual(storeRecords().length, 2, 'precondition: the backfill appended its record');
  assert.strictEqual(fs.statSync(path.join(store, SLUG)).mtimeMs, old.getTime());
  assert.match(staleness(), /WARN papercut capture stale/);
});

test('planted negative: a live capture write still reads healthy to the same reader', () => {
  standardTranscript();
  seedOldHookRecord();
  const saved = process.env.PAPERCUT_STORE;
  process.env.PAPERCUT_STORE = store;
  try {
    assert.ok(papercutLog.appendRecord(CWD, JSON.stringify({ ts: new Date().toISOString(), sig: 'exit_1:false', source: 'auto' }) + '\n'));
  } finally {
    if (saved === undefined) delete process.env.PAPERCUT_STORE;
    else process.env.PAPERCUT_STORE = saved;
  }
  touchSessionAfterCapture();
  assert.match(staleness(), /papercut capture: healthy/);
});

test('round 1 CI (language shard): a capture stamped inside the session clock\'s millisecond still reads healthy', () => {
  standardTranscript();
  seedOldHookRecord();
  const file = path.join(store, SLUG);
  const nowMs = Math.floor(Date.now() / 1000) * 1000;
  // The kernel's sub-millisecond stamp on a live append, in the millisecond a Date reads.
  fs.utimesSync(file, nowMs / 1000 + 0.0004, nowMs / 1000 + 0.0004);
  assert.ok(fs.statSync(file, { bigint: true }).mtimeNs > BigInt(nowMs) * 1000000n,
    'precondition: the capture is stamped past the millisecond');
  touchSessionAfterCapture({ nowMs });
  assert.match(staleness(), /papercut capture: healthy/);
});

test('a capture append landing during a keep-mtime write keeps its fresher mtime', () => {
  const old = seedOldHookRecord();
  const fresh = new Date(Math.floor(Date.now() / 1000) * 1000);
  const file = path.join(store, SLUG);
  const capture = JSON.stringify({ ts: fresh.toISOString(), sig: 'exit_1:false', source: 'auto' }) + '\n';
  const saved = process.env.PAPERCUT_STORE;
  const realAppend = fs.appendFileSync;
  process.env.PAPERCUT_STORE = store;
  // A live hook appends right after the backfill's own append, before its restore.
  fs.appendFileSync = (target, data, ...rest) => {
    realAppend(target, data, ...rest);
    if (target === file) {
      fs.appendFileSync = realAppend;
      realAppend(file, capture);
      fs.utimesSync(file, fresh, fresh);
    }
  };
  try {
    assert.ok(papercutLog.appendRecord(CWD, JSON.stringify({ ts: old.toISOString(), sig: 'x', source: 'transcript' }) + '\n',
      { keepMtime: true }));
  } finally {
    fs.appendFileSync = realAppend;
    if (saved === undefined) delete process.env.PAPERCUT_STORE;
    else process.env.PAPERCUT_STORE = saved;
  }
  assert.strictEqual(fs.readFileSync(file, 'utf8').trim().split('\n').length, 3, 'precondition: both appends landed');
  assert.strictEqual(fs.statSync(file).mtimeMs, fresh.getTime());
});

test('a store file only the backfill wrote carries no capture time', async () => {
  standardTranscript();
  const res = await run(['--days', '1']);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.strictEqual(storeRecords().length, 1, 'precondition: the backfill created the file');
  assert.strictEqual(fs.statSync(path.join(store, SLUG)).mtimeMs, 0);
  assert.match(staleness(), /WARN papercut capture: sessions are running .* is the PostToolUseFailure hook registered/);
});

test('usage errors exit 2', async () => {
  assert.strictEqual((await run(['--bogus'])).code, 2);
  assert.strictEqual((await run(['--days', '0'])).code, 2);
  const missing = await spawnNode(SCRIPT, { argv: ['--projects', path.join(base, 'nope')], env: { PAPERCUT_STORE: store } });
  assert.strictEqual(missing.code, 2);
  assert.match(missing.stderr, /no transcripts directory/);
});
