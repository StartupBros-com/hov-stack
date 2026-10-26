'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, decisionOf, reasonOf, assertPreToolUseDeny, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'PreToolUse/loop-guard.js';
const payload = (sid) => ({ session_id: sid, tool_input: {} });

test('no-op (pass-through) unless CLAUDE_LOOP_GUARD=1', async () => {
  const p = payload('s1');
  // This is the default path on every tool call — assert it actually ran and
  // echoed input, not just that no decision was emitted (a crash yields neither).
  assertQuietPassThrough(await runHook(HOOK, p));
});

test('blocks once the per-session call count exceeds CLAUDE_LOOP_MAX', async () => {
  const home = mkTmp('lg-home-');
  try {
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '2' };
    assertQuietPassThrough(await runHook(HOOK, payload('loop'), { env })); // call 1
    assertQuietPassThrough(await runHook(HOOK, payload('loop'), { env })); // call 2
    const blocked = await runHook(HOOK, payload('loop'), { env }); // call 3 > 2
    assert.strictEqual(decisionOf(blocked), 'block');
    assertPreToolUseDeny(blocked); // locks the current PreToolUse (permissionDecision) schema
  } finally {
    rmTmp(home);
  }
});

test('escalates to a hard stop (continue:false) when tool calls continue past the fence', async () => {
  const home = mkTmp('lg-home-');
  try {
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '1', CLAUDE_LOOP_HARD_GRACE: '2' };
    const call = () => runHook(HOOK, payload('flail'), { env });
    assertQuietPassThrough(await call());       // call 1: at cap, still allowed
    assert.strictEqual(decisionOf(await call()), 'block');   // call 2: over budget -> soft deny (wrap up)
    assert.strictEqual(decisionOf(await call()), 'block');   // call 3: within grace -> soft deny
    const stopped = await call();                            // call 4: grace exhausted -> hard stop
    assert.strictEqual(decisionOf(stopped), 'block', 'hard stop still denies the call');
    assert.strictEqual(JSON.parse(stopped.stdout).continue, false, 'expected continue:false to halt the run');
    assert.match(JSON.parse(stopped.stdout).stopReason, /hard-stopping/);
    assertPreToolUseDeny(stopped); // hardStop() builds its own object — lock its embedded schema too
  } finally {
    rmTmp(home);
  }
});

test('self-reaps abandoned session state older than 2x the wall-clock budget', async () => {
  const home = mkTmp('lg-home-');
  try {
    const stateDir = path.join(home, '.claude', '.loop-state');
    fs.mkdirSync(stateDir, { recursive: true });
    const stale = path.join(stateDir, 'abandoned.json');
    const fresh = path.join(stateDir, 'recent.json');
    fs.writeFileSync(stale, '{}');
    fs.writeFileSync(fresh, '{}');
    // Age the abandoned file past 2x the default 60min budget (2h); the fresh
    // file and the live session's own file must survive.
    const threeHoursAgoSec = Date.now() / 1000 - 3 * 3600;
    fs.utimesSync(stale, threeHoursAgoSec, threeHoursAgoSec);
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1' };
    await runHook(HOOK, payload('live'), { env });
    assert.ok(!fs.existsSync(stale), 'abandoned state should be reaped');
    assert.ok(fs.existsSync(fresh), 'recent state should be preserved');
    assert.ok(fs.existsSync(path.join(stateDir, 'live.json')), 'live session state should be written');
  } finally {
    rmTmp(home);
  }
});

test('does NOT reap the live session own state even when its mtime is stale', async () => {
  const home = mkTmp('lg-home-');
  try {
    const stateDir = path.join(home, '.claude', '.loop-state');
    fs.mkdirSync(stateDir, { recursive: true });
    // Own file with a fresh startMs (not over budget) but a stale mtime, as after
    // a long single tool call / idle gap. It is a reap candidate by age but must
    // be skipped, or the fence would silently reset to zero.
    const own = path.join(stateDir, 'slow.json');
    fs.writeFileSync(own, JSON.stringify({ count: 42, startMs: Date.now() }));
    const tenHoursAgoSec = Date.now() / 1000 - 10 * 3600;
    fs.utimesSync(own, tenHoursAgoSec, tenHoursAgoSec);
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1' };
    assertQuietPassThrough(await runHook(HOOK, payload('slow'), { env }));
    assert.ok(fs.existsSync(own), 'live session own file must not be self-reaped despite a stale mtime');
    assert.strictEqual(JSON.parse(fs.readFileSync(own, 'utf8')).count, 43, 'preserved count advances 42 -> 43, not reset to 1');
  } finally {
    rmTmp(home);
  }
});

test('hard-stops immediately when over budget and state cannot be persisted (fail closed)', async () => {
  const home = mkTmp('lg-home-');
  const stateDir = path.join(home, '.claude', '.loop-state');
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    // Seed an already-over-budget session, then make the dir unwritable so the
    // atomic write fails and the grace counter can never advance.
    fs.writeFileSync(path.join(stateDir, 'unwritable.json'), JSON.stringify({ count: 5, startMs: Date.now() }));
    fs.chmodSync(stateDir, 0o500); // r-x: no writes
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '1' };
    const stopped = await runHook(HOOK, payload('unwritable'), { env });
    assert.strictEqual(JSON.parse(stopped.stdout).continue, false, 'unwritable state + over budget must hard-stop, not soft-deny forever');
    assert.match(JSON.parse(stopped.stdout).stopReason, /unwritable/);
    assertPreToolUseDeny(stopped);
  } finally {
    fs.chmodSync(stateDir, 0o700); // restore so cleanup can remove it
    rmTmp(home);
  }
});

// ===========================================================================
// Round 2 finding 7 (adversarial review of PR #1294): the existing
// "unwritable-dir" test above pre-creates .loop-state and THEN chmods it, so
// it never exercises updateState()'s own fs.mkdirSync(stateDir, {recursive:
// true}) -- that call only fires when the state dir does not exist yet. Here
// the PARENT (<HOME>/.claude) is chmod 0500 and .loop-state is never created,
// so updateState()'s mkdirSync is the very first attempt to create it and
// must fail with EACCES. Before the fix this threw straight out of run()
// (exit 1, empty stdout, no decision emitted -- a crash, not a fail-closed
// decision). Fixed: updateState() catches the mkdirSync failure, skips the
// lock, and falls through to the existing best-effort load+mutate+save path,
// which (like the test above) still fails closed via the persisted:false
// branch -- but as a real decision, not a crash.
// ===========================================================================

test('round 2 finding 7: hard-stops (not crashes) when the state dir\'s PARENT is unwritable and the dir does not exist yet', async () => {
  const home = mkTmp('lg-home-');
  const claudeDir = path.join(home, '.claude');
  try {
    fs.mkdirSync(claudeDir, { recursive: true });
    fs.chmodSync(claudeDir, 0o500); // r-x: updateState's own mkdirSync(stateDir) must fail here
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '0' };
    const stopped = await runHook(HOOK, payload('unwritable-parent'), { env });
    assert.strictEqual(stopped.code, 0, 'a guarded mkdirSync failure must exit 0, not crash the process');
    assert.strictEqual(stopped.stderr.trim(), '', 'no uncaught exception should reach stderr');
    assert.strictEqual(JSON.parse(stopped.stdout).continue, false, 'over budget + unwritable state must still hard-stop, not silently allow');
    assert.match(JSON.parse(stopped.stdout).stopReason, /unwritable/);
    assertPreToolUseDeny(stopped);
  } finally {
    fs.chmodSync(claudeDir, 0o700); // restore so cleanup can remove it
    rmTmp(home);
  }
});

test('blocks once the wall-clock budget (CLAUDE_LOOP_MAX_MS) is exceeded', async () => {
  const home = mkTmp('lg-home-');
  try {
    const stateDir = path.join(home, '.claude', '.loop-state');
    fs.mkdirSync(stateDir, { recursive: true });
    // Pre-seed a session that started long ago so elapsed > budget on the next call.
    fs.writeFileSync(path.join(stateDir, 'timed.json'), JSON.stringify({ count: 1, startMs: Date.now() - 999999 }));
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '999', CLAUDE_LOOP_MAX_MS: '1000' };
    const res = await runHook(HOOK, payload('timed'), { env });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /budget/);
  } finally {
    rmTmp(home);
  }
});

test('hard stop writes the CLAUDE_LOOP_STOP_MARKER file for claude-loop (issue 562)', async () => {
  const home = mkTmp('lg-home-');
  try {
    const marker = path.join(home, 'run.budget-stop');
    const env = {
      HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1',
      CLAUDE_LOOP_MAX: '1', CLAUDE_LOOP_HARD_GRACE: '0',
      CLAUDE_LOOP_STOP_MARKER: marker,
    };
    assertQuietPassThrough(await runHook(HOOK, payload('bstop'), { env })); // call 1: at cap
    const stopped = await runHook(HOOK, payload('bstop'), { env }); // call 2: over + zero grace -> hard stop
    assert.strictEqual(JSON.parse(stopped.stdout).continue, false, 'fixture must actually hard-stop');
    assert.ok(fs.existsSync(marker), 'hard stop must write the budget-stop marker');
    const m = JSON.parse(fs.readFileSync(marker, 'utf8'));
    assert.strictEqual(m.stopped, 'budget');
    assert.match(m.reason, /exceeds CLAUDE_LOOP_MAX/);
    // Both paths land on a healthy filesystem (issue 562 follow-up).
    const fb = path.join(home, '.claude', '.loop-state', 'stop-markers', 'run.budget-stop');
    assert.ok(fs.existsSync(fb), 'hard stop must also write the state-dir fallback marker');
  } finally {
    rmTmp(home);
  }
});

test('a failed PRIMARY marker write still lands the state-dir fallback (issue 562 follow-up)', async () => {
  // The refute-lens EISDIR probe: primary marker at an existing DIRECTORY ->
  // writeFileSync throws, was swallowed, wrapper stayed blind and the
  // false-success path returned. The guard now writes a second, independent
  // path under its own state dir, which it proves writable on every call.
  const home = mkTmp('lg-home-');
  try {
    const marker = path.join(home, 'run.budget-stop');
    fs.mkdirSync(marker, { recursive: true }); // EISDIR on the primary write
    const env = {
      HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1',
      CLAUDE_LOOP_MAX: '1', CLAUDE_LOOP_HARD_GRACE: '0',
      CLAUDE_LOOP_STOP_MARKER: marker,
    };
    assertQuietPassThrough(await runHook(HOOK, payload('bfall'), { env }));
    const stopped = await runHook(HOOK, payload('bfall'), { env });
    assert.strictEqual(JSON.parse(stopped.stdout).continue, false, 'fixture must actually hard-stop');
    const fb = path.join(home, '.claude', '.loop-state', 'stop-markers', 'run.budget-stop');
    assert.ok(fs.existsSync(fb), 'fallback marker must land when the primary write fails');
    const m = JSON.parse(fs.readFileSync(fb, 'utf8'));
    assert.strictEqual(m.stopped, 'budget');
  } finally {
    rmTmp(home);
  }
});

test('soft deny does NOT write the marker — only a hard stop means the run is dead (issue 562)', async () => {
  const home = mkTmp('lg-home-');
  try {
    const marker = path.join(home, 'run.budget-stop');
    const env = {
      HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1',
      CLAUDE_LOOP_MAX: '1', CLAUDE_LOOP_HARD_GRACE: '10',
      CLAUDE_LOOP_STOP_MARKER: marker,
    };
    assertQuietPassThrough(await runHook(HOOK, payload('bsoft'), { env })); // call 1: at cap
    assert.strictEqual(decisionOf(await runHook(HOOK, payload('bsoft'), { env })), 'block'); // call 2: soft deny
    assert.ok(!fs.existsSync(marker), 'a soft deny (agent can still land cleanly) must not fake a budget kill');
  } finally {
    rmTmp(home);
  }
});

// ===========================================================================
// Issue #1514: the counter IS the fence, so state the guard cannot persist or
// cannot read must stop the run instead of silently allowing it. The rows
// mirror the probe in the oxlint/Lean harness vet
// (docs/vets/2026-10-02-oxlint-anti-slop-lean-harness-vet.md, section 2):
// CLAUDE_LOOP_MAX=3 and CLAUDE_LOOP_HARD_GRACE=2, so a healthy session runs
// allow x3, deny x2, then hard-stops.
// ===========================================================================

const bash = (sid, command) => ({ session_id: sid, tool_name: 'Bash', tool_input: { command } });
const probeEnv = (home, extra = {}) => ({
  HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1',
  CLAUDE_LOOP_MAX: '3', CLAUDE_LOOP_HARD_GRACE: '2', ...extra,
});

// One verdict per call. The exit-code check comes first so a crashed hook
// (which Claude Code treats as a non-blocking error, i.e. an allow) can never
// read as a pass.
function verdict(res) {
  assert.strictEqual(res.code, 0, `hook must exit 0, got ${res.code}; stderr: ${res.stderr}`);
  if (res.stdout === '') return 'allow';
  const out = JSON.parse(res.stdout);
  if (out.continue === false) return 'HARDSTOP';
  return decisionOf(res) === 'block' ? 'deny' : `other:${res.stdout}`;
}

async function calls(n, env, payload) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(verdict(await runHook(HOOK, payload, { env })));
  return out;
}

const HEALTHY = ['allow', 'allow', 'allow', 'deny', 'deny', 'HARDSTOP', 'HARDSTOP', 'HARDSTOP'];

test('#1514 planted negative: a healthy session still runs allow x3, deny x2, then hard-stops', async () => {
  const home = mkTmp('lg-home-');
  try {
    assert.deepStrictEqual(await calls(8, probeEnv(home), bash('healthy', 'ls')), HEALTHY);
  } finally {
    rmTmp(home);
  }
});

test('#1514: a state dir unwritable from the first call hard-stops on that call', async () => {
  const home = mkTmp('lg-home-');
  try {
    // ~/.claude is a regular file, so ~/.claude/.loop-state can never be created.
    fs.writeFileSync(path.join(home, '.claude'), 'not a directory');
    assert.ok(fs.statSync(path.join(home, '.claude')).isFile(), 'precondition: the state dir cannot exist');
    const first = await runHook(HOOK, bash('nostate', 'ls'), { env: probeEnv(home) });
    assert.strictEqual(verdict(first), 'HARDSTOP', 'an untrackable budget must stop the run, not allow every call');
    assert.match(JSON.parse(first.stdout).stopReason, /unwritable/);
    assertPreToolUseDeny(first);
    assert.deepStrictEqual(await calls(3, probeEnv(home), bash('nostate', 'ls')), ['HARDSTOP', 'HARDSTOP', 'HARDSTOP']);
  } finally {
    rmTmp(home);
  }
});

test('#1514: a state dir made read-only mid-run hard-stops at the first write that fails', async () => {
  const home = mkTmp('lg-home-');
  const stateDir = path.join(home, '.claude', '.loop-state');
  try {
    const env = probeEnv(home);
    assert.deepStrictEqual(await calls(2, env, bash('ro', 'ls')), ['allow', 'allow']);
    const seeded = JSON.parse(fs.readFileSync(path.join(stateDir, 'ro.json'), 'utf8'));
    assert.strictEqual(seeded.count, 2, 'precondition: both calls were counted before the dir went read-only');
    fs.chmodSync(stateDir, 0o500); // r-x: the temp-file write fails from here on
    assert.deepStrictEqual(await calls(3, env, bash('ro', 'ls')), ['HARDSTOP', 'HARDSTOP', 'HARDSTOP']);
  } finally {
    try { fs.chmodSync(stateDir, 0o700); } catch { /* already gone */ }
    rmTmp(home);
  }
});

test('#1514: a state dir that can be written but not listed keeps counting', async () => {
  // -wx: the reap loop's readdir fails, but the session's own file is still
  // readable and writable by name. Reading it used to sit inside the same
  // try as the readdir, so every call reset the count to 1.
  const home = mkTmp('lg-home-');
  const stateDir = path.join(home, '.claude', '.loop-state');
  try {
    const env = probeEnv(home);
    assert.deepStrictEqual(await calls(2, env, bash('nolist', 'ls')), ['allow', 'allow']);
    fs.chmodSync(stateDir, 0o300);
    assert.throws(() => fs.readdirSync(stateDir), /EACCES/, 'precondition: the dir cannot be listed');
    assert.deepStrictEqual(await calls(4, env, bash('nolist', 'ls')), ['allow', 'deny', 'deny', 'HARDSTOP']);
  } finally {
    try { fs.chmodSync(stateDir, 0o700); } catch { /* already gone */ }
    rmTmp(home);
  }
});

test('#1514: an agent retrying a fenced call is hard-stopped after the grace window', async () => {
  const home = mkTmp('lg-home-');
  try {
    const env = probeEnv(home);
    const first = await runHook(HOOK, bash('fenced', 'gh pr merge 5'), { env });
    assert.strictEqual(verdict(first), 'deny');
    assert.match(reasonOf(first), /loop-authority fence/, 'the first denial still names the fence');
    const rest = await calls(11, env, bash('fenced', 'gh pr merge 5'));
    assert.deepStrictEqual(rest, ['deny', ...Array(10).fill('HARDSTOP')]);
  } finally {
    rmTmp(home);
  }
});

test('#1514: only consecutive fenced denials hard-stop; a counted call resets the run', async () => {
  // Scattered fence hits in a long healthy run must never add up to a stop
  // (adversarial-first round 1 on PR #1520): a counted call in between starts
  // the grace window over. GRACE=2 and MAX=3, so the counted call stays allowed.
  const home = mkTmp('lg-home-');
  try {
    const env = probeEnv(home);
    assert.deepStrictEqual(await calls(2, env, bash('scatter', 'gh pr merge 5')), ['deny', 'deny']);
    assert.deepStrictEqual(await calls(1, env, bash('scatter', 'ls')), ['allow']);
    assert.deepStrictEqual(await calls(3, env, bash('scatter', 'gh pr merge 5')), ['deny', 'deny', 'HARDSTOP']);
  } finally {
    rmTmp(home);
  }
});

test('#1514 planted negative: fenced denials do not spend the tool-call budget', async () => {
  const home = mkTmp('lg-home-');
  try {
    const env = probeEnv(home);
    assert.deepStrictEqual(await calls(2, env, bash('mixed', 'gh pr merge 5')), ['deny', 'deny']);
    assert.deepStrictEqual(await calls(3, env, bash('mixed', 'ls')), ['allow', 'allow', 'allow']);
  } finally {
    rmTmp(home);
  }
});

test('#1514: a corrupted state file keeps a stopped run stopped instead of resetting the count', async () => {
  const home = mkTmp('lg-home-');
  try {
    const env = probeEnv(home);
    assert.deepStrictEqual(await calls(7, env, bash('corrupt', 'ls')), HEALTHY.slice(0, 7), 'precondition: the run reached the hard-stop zone');
    fs.writeFileSync(path.join(home, '.claude', '.loop-state', 'corrupt.json'), '{corrupt');
    assert.deepStrictEqual(await calls(3, env, bash('corrupt', 'ls')), ['HARDSTOP', 'HARDSTOP', 'HARDSTOP']);
  } finally {
    rmTmp(home);
  }
});

for (const [label, body] of [
  ['truncated JSON', '{corrupt'],
  ['null', 'null'],
  ['a number', '5'],
  ['a string', '"x"'],
  ['an array', '[]'],
]) {
  test(`#1514: a state file holding ${label} fails closed and stays closed`, async () => {
    const home = mkTmp('lg-home-');
    try {
      const env = probeEnv(home);
      assert.deepStrictEqual(await calls(1, env, bash('bad', 'ls')), ['allow']);
      fs.writeFileSync(path.join(home, '.claude', '.loop-state', 'bad.json'), body);
      const res = await runHook(HOOK, bash('bad', 'ls'), { env });
      assert.strictEqual(verdict(res), 'HARDSTOP');
      assert.match(JSON.parse(res.stdout).stopReason, /could not be read/);
      assert.deepStrictEqual(await calls(2, env, bash('bad', 'ls')), ['HARDSTOP', 'HARDSTOP'], 'later calls stay stopped');
    } finally {
      rmTmp(home);
    }
  });
}

test('#1514: a fail-closed stop writes the budget-stop marker so claude-loop sees the kill', async () => {
  const home = mkTmp('lg-home-');
  try {
    fs.writeFileSync(path.join(home, '.claude'), 'not a directory');
    const marker = path.join(home, 'run.budget-stop');
    const res = await runHook(HOOK, bash('marked', 'ls'), { env: probeEnv(home, { CLAUDE_LOOP_STOP_MARKER: marker }) });
    assert.strictEqual(verdict(res), 'HARDSTOP');
    assert.ok(fs.existsSync(marker), 'the primary marker must land; its directory is writable');
    assert.match(JSON.parse(fs.readFileSync(marker, 'utf8')).reason, /unwritable/);
  } finally {
    rmTmp(home);
  }
});

// U6 ownership authority fixtures: command strings are classified, never run.
for (const command of [
  'pr-handoff.sh acme/widgets 5',
  'env -u CLAUDE_LOOP_GUARD pr-handoff.sh acme/widgets 5',
  'bash ~/.claude/scripts/pr-handoff.sh acme/widgets 5',
  'pr-owner.sh park state reason',
  'pr-owner.sh run state',
  'bash ~/.claude/scripts/pr-owner-recover.sh',
  'systemd-run --user --unit=pr-owner-x true',
  'systemd-run --user --unit pr-owner-x true',
  'systemctl --user stop pr-owner-x',
  'systemctl --user is-active pr-owner-x.service',
  "systemctl --user stop 'pr-owner-*'",
  'systemctl --user stop *.service',
  'git -c alias.x=!pr-owner.sh x',
  'git rebase --exec pr-owner.sh main',
  'git restore --source=abc123 -- scripts/pr-owner.sh',
  'git mv scripts/pr-owner.sh scripts/pr-owner-old.sh',
  'timeout 5 pr-owner.sh park state reason',
  "bash -c 'pr-handoff.sh acme/widgets 5'",
  'env -u CLAUDE_LOOP_GUARD systemd-run --user --unit=pr-owner-x true',
  'env -u CLAUDE_LOOP_GUARD systemctl --user stop pr-owner-x',
  'gh pr edit 5 --remove-label loop-run',
  'gh pr edit 5 --remove-label=bug,loop-run',
  'env -u CLAUDE_LOOP_GUARD gh pr edit 5 --remove-label loop-run',
]) {
  test(`U6 ownership surface fenced only with guard: ${command}`, async () => {
    const home = mkTmp('lg-owner-');
    try {
      const input = bash('owner', command);
      assertPreToolUseDeny(await runHook(HOOK, input, { env: probeEnv(home) }));
      assertQuietPassThrough(await runHook(HOOK, input, { env: probeEnv(home, { CLAUDE_LOOP_GUARD: '0' }) }));
    } finally { rmTmp(home); }
  });
}

for (const command of [
  'systemd-run --user --unit=unrelated true',
  'systemctl --user stop unrelated',
  'gh pr edit 5 --remove-label bug',
  'gh pr edit 5 --add-label loop-run',
  // A fixer on a PR that edits the owner scripts can still inspect and commit.
  'git add scripts/pr-owner.sh scripts/pr-handoff.sh',
  'git -C /tmp/w commit -m fix-pr-owner.sh-retry scripts/pr-owner.sh',
  'shellcheck -x scripts/pr-owner.sh',
  'rg -n park scripts/pr-owner.sh',
  'bash tests/pr-owner.test.sh',
]) {
  test(`U6 unrelated authority surface stays allowed: ${command}`, async () => {
    const home = mkTmp('lg-owner-');
    try {
      assertQuietPassThrough(await runHook(HOOK, bash('owner', command), { env: probeEnv(home) }));
    } finally { rmTmp(home); }
  });
}
