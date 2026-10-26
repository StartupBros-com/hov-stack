'use strict';
/**
 * Tests for PreToolUse/fanout-admission.js (issue #1284) and its session-state
 * extraction (../lib/session-state.js).
 *
 * Layout:
 *   - session-state.js unit tests (the shared lib both loop-guard.js and this
 *     hook's Task path depend on; loop-guard.test.js is the regression check
 *     that the extraction changed nothing there).
 *   - analyzeWorkflow() unit tests: the CLAUDE.md:58 over-ratio example and a
 *     compliant 1:1 fixture, exercised directly (no process spawn needed).
 *   - run() WARN-mode behavior (default, no opt-in): in-process require, since
 *     GATE_BLOCK is read once at module load and WARN mode needs no particular
 *     value for it.
 *   - run() blocking-opt-in behavior: spawned via runHook so the opt-in env var
 *     is present BEFORE the module loads in a fresh process (a same-process
 *     `process.env.X = ...` after require() would not change an already-read
 *     module-level const).
 *   - Task-path spawn-threshold WARN test.
 *   - Hook-seam test: settings.json actually registers this hook on the
 *     Task and Workflow matchers.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, assertPreToolUseDeny, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');
const { measureCpu } = require('./lib/timing');
const { assertPerfScaling } = require('./lib/perf-guard');
const { projectSlug } = require('../PostToolUseFailure/papercut-log.js');

// GATE_BLOCK, TASK_THRESHOLD and TASK_WINDOW_MS are read ONCE at module load
// (same convention as CLAUDE_LOOP_GUARD in loop-guard.js). harness.js's
// NEUTRALIZE list only sanitizes SPAWNED child envs, not this test process's
// own -- so a developer who happens to have CLAUDE_FANOUT_GATE_BLOCK=1 set in
// their shell would otherwise silently flip every in-process "WARN mode"
// assertion below into block-mode behavior. Strip them before the require.
delete process.env.CLAUDE_FANOUT_GATE_BLOCK;
delete process.env.CLAUDE_FANOUT_TASK_THRESHOLD;
delete process.env.CLAUDE_FANOUT_TASK_WINDOW_MS;
const {
  run,
  analyzeWorkflow,
  uncappedFanouts,
  blankStrings,
  callSpans,
  directAgentSpansWithin,
  buildEnclosingFanoutIndex,
  AnalysisBudgetExceeded,
} = require('../PreToolUse/fanout-admission.js');
const { sessionKey, loadState, saveState, updateState, acquireLock, releaseLock, reapStaleLock } = require('../lib/session-state.js');

const HOOK = 'PreToolUse/fanout-admission.js';

// ===========================================================================
// session-state.js (shared lib, extracted from loop-guard.js for #1284)
// ===========================================================================

test('session-state: sessionKey uses session_id, falls back to ppid when absent', () => {
  assert.strictEqual(sessionKey({ session_id: 'abc123' }), 'abc123');
  assert.strictEqual(sessionKey({}), `unknown-${process.ppid}`);
  assert.strictEqual(sessionKey(null), `unknown-${process.ppid}`);
});

test('session-state: loadState returns the default state when no file exists yet', () => {
  const dir = mkTmp('sstate-');
  try {
    const { state, file } = loadState(dir, 'fresh-sid', { defaultState: { count: 0 } });
    assert.deepStrictEqual(state, { count: 0 });
    assert.strictEqual(file, path.join(dir, 'fresh-sid.json'));
    assert.ok(fs.existsSync(dir), 'loadState must create the state dir');
  } finally {
    rmTmp(dir);
  }
});

test('session-state: saveState + loadState round-trips via atomic temp+rename', () => {
  const dir = mkTmp('sstate-');
  try {
    const { file } = loadState(dir, 'sid-a', { defaultState: {} });
    assert.strictEqual(saveState(file, { count: 7, note: 'x' }), true);
    assert.ok(!fs.existsSync(`${file}.${process.pid}.tmp`), 'temp file must be renamed away, not left behind');
    const reloaded = loadState(dir, 'sid-a', { defaultState: {} }).state;
    assert.deepStrictEqual(reloaded, { count: 7, note: 'x' });
  } finally {
    rmTmp(dir);
  }
});

test('session-state: self-reaps OTHER stale sessions but never its own file', () => {
  const dir = mkTmp('sstate-');
  try {
    const staleFile = path.join(dir, 'stale-other.json');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(staleFile, '{}');
    const ownFile = path.join(dir, 'me.json');
    fs.writeFileSync(ownFile, JSON.stringify({ count: 42 }));
    const longAgoSec = Date.now() / 1000 - 3600;
    fs.utimesSync(staleFile, longAgoSec, longAgoSec);
    fs.utimesSync(ownFile, longAgoSec, longAgoSec); // own file has a stale mtime too
    const { state } = loadState(dir, 'me', { reapOlderThanMs: 1000, defaultState: {} });
    assert.ok(!fs.existsSync(staleFile), 'a stale OTHER session file must be reaped');
    assert.ok(fs.existsSync(ownFile), 'the live session own file must never be reaped, regardless of mtime');
    assert.strictEqual(state.count, 42, 'own state must load unchanged, not reset by the reap pass');
  } finally {
    rmTmp(dir);
  }
});

test('session-state: saveState fails closed (returns false, never throws) when the dir is gone', () => {
  const dir = mkTmp('sstate-');
  rmTmp(dir); // remove the dir out from under the write
  assert.strictEqual(saveState(path.join(dir, 'x.json'), { a: 1 }), false);
});

// ===========================================================================
// Round 4 (adversarial review of PR #1294, e8d50fd) finding 1: the pre-fix
// reapStaleLock()/releaseLock() identified a lock by the lock DIRECTORY's
// mtime alone, with no way to attribute it to a specific holder. Adapted
// from the coordinator-supplied reproduction at
// tmp-scratch-1294-lockrace/steal-repro.js (a different worktree, read-only
// reference), rewritten against the REAL exported session-state.js
// functions with the fix's owner-record fencing (pid + random token).
// ===========================================================================

test('round 4 finding 1: acquireLock() does not let a second caller steal a stale-mtime lock whose owner PID is still alive, and releaseLock() refuses a stale/mismatched token', () => {
  const dir = mkTmp('sstate-lockrace-sync-');
  const lockDir = path.join(dir, '.sess-steal.lock');

  // "Process A" acquires the lock normally -- its owner record's pid is
  // this very test process's own pid, which is alive for the rest of the
  // test by construction.
  const tokenA = acquireLock(lockDir);
  assert.ok(tokenA, 'A must acquire the lock and receive a fencing token');

  // Backdate the lock dir's mtime well past LOCK_STALE_MS (5000ms) while A
  // still holds it -- steal-repro.js's exact technique for simulating "A is
  // merely slow", not crashed.
  const longAgoSec = Date.now() / 1000 - 6;
  fs.utimesSync(lockDir, longAgoSec, longAgoSec);

  // On e8d50fd, reapStaleLock() reaped on this stale mtime ALONE and let a
  // second acquireLock() call steal A's still-live lock immediately. With
  // the fix, A's owner record names a live pid, so reaping must be refused
  // and this second attempt must spin out and fail.
  const tokenB = acquireLock(lockDir);
  assert.strictEqual(tokenB, null, 'a second caller must NOT be able to steal a lock whose owner pid is still alive, however stale its mtime reads');
  assert.strictEqual(fs.existsSync(lockDir), true, "A's lock must still be standing after the failed steal attempt");

  // A releases its own lock with its own token -- must succeed.
  assert.strictEqual(releaseLock(lockDir, tokenA), true);
  assert.strictEqual(fs.existsSync(lockDir), false);

  // The lock is now genuinely free. A later caller (call it C) legitimately
  // acquires a brand-new lock with its own, different token.
  const tokenC = acquireLock(lockDir);
  assert.ok(tokenC, 'C must be able to acquire the lock once it is genuinely free');
  assert.notStrictEqual(tokenC, tokenA, "C's lock must carry its OWN token, never reuse A's");

  // A's stale token (e.g. a delayed finally{} block from a caller that
  // thinks it still holds the ORIGINAL lock) must never be able to destroy
  // C's legitimately-held, unrelated current lock.
  assert.strictEqual(releaseLock(lockDir, tokenA), false, "a stale token must never release a DIFFERENT holder's current lock");
  assert.strictEqual(fs.existsSync(lockDir), true, "C's lock must still be standing after A's stale release attempt");

  assert.strictEqual(releaseLock(lockDir, tokenC), true);
  assert.strictEqual(fs.existsSync(lockDir), false);

  rmTmp(dir);
});

test('round 4 finding 1: reapStaleLock() reaps a stale-mtime lock only once its owner pid is confirmed dead', () => {
  const dir = mkTmp('sstate-lockrace-dead-');
  const lockDir = path.join(dir, '.sess-dead.lock');
  const token = acquireLock(lockDir);
  assert.ok(token);

  // A pid that is guaranteed to be dead BY THE TIME this line runs: spawnSync
  // blocks until the child has fully exited, so its pid is free again the
  // instant it returns (the standard "recently-dead pid" technique -- pid
  // reuse within a single synchronous test is not a realistic race here).
  const dead = require('node:child_process').spawnSync(process.execPath, ['-e', '']);
  const deadPid = dead.pid;
  fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify({ pid: deadPid, token, acquiredAt: Date.now() }));

  const longAgoSec = Date.now() / 1000 - 6;
  fs.utimesSync(lockDir, longAgoSec, longAgoSec);

  reapStaleLock(lockDir);
  assert.strictEqual(fs.existsSync(lockDir), false, 'a stale-mtime lock whose owner pid is confirmed dead must be reaped');

  rmTmp(dir);
});

test(
  'round 4 finding 1: two REAL concurrent processes -- B does not reap A\'s live-but-mtime-stale lock, and both updates persist (no lost update), adapted from tmp-scratch-1294-lockrace/steal-repro.js',
  { timeout: 8000 },
  async () => {
    const dir = mkTmp('sstate-lockrace-real-');
    const sid = 'sess-steal-real';
    const lockDir = path.join(dir, `.${sid}.lock`);
    const signalFile = path.join(dir, 'a-locked.signal');
    const aResultFile = path.join(dir, 'a-result.json');
    const bResultFile = path.join(dir, 'b-result.json');
    const sessionStateModule = path.join(__dirname, '..', 'lib', 'session-state.js');
    const cp = require('node:child_process');

    const procAScript = `
      const { acquireLock, releaseLock, loadState, saveState } = require(${JSON.stringify(sessionStateModule)});
      const fs = require('fs');
      const token = acquireLock(${JSON.stringify(lockDir)});
      if (!token) { fs.writeFileSync(${JSON.stringify(aResultFile)}, JSON.stringify({ token: false })); process.exit(0); }
      const { state, file } = loadState(${JSON.stringify(dir)}, ${JSON.stringify(sid)}, { defaultState: { spawns: [] } });
      state.spawns.push('A');
      fs.writeFileSync(${JSON.stringify(signalFile)}, 'locked');
      // Hold the lock for 200ms while A is genuinely alive and mid-critical-section
      // -- long enough for the parent to backdate the lock's mtime and launch B.
      const until = Date.now() + 200;
      while (Date.now() < until) { /* hold */ }
      saveState(file, state);
      const released = releaseLock(${JSON.stringify(lockDir)}, token);
      fs.writeFileSync(${JSON.stringify(aResultFile)}, JSON.stringify({ token: true, released }));
    `;

    const procA = cp.spawn(process.execPath, ['-e', procAScript], { stdio: ['ignore', 'ignore', 'inherit'] });

    const waitUntil = Date.now() + 2000;
    while (!fs.existsSync(signalFile) && Date.now() < waitUntil) {
      /* bounded spin -- A should signal within milliseconds */
    }
    assert.ok(fs.existsSync(signalFile), 'process A must acquire the lock and signal within the 2s bound');

    // steal-repro.js's exact technique: backdate the lock's mtime past
    // LOCK_STALE_MS while A is still genuinely holding (and using) it.
    const longAgoSec = Date.now() / 1000 - 6;
    fs.utimesSync(lockDir, longAgoSec, longAgoSec);

    const procBScript = `
      const { acquireLock, releaseLock, loadState, saveState } = require(${JSON.stringify(sessionStateModule)});
      const fs = require('fs');
      const token = acquireLock(${JSON.stringify(lockDir)});
      const result = { gotToken: !!token };
      if (token) {
        const { state, file } = loadState(${JSON.stringify(dir)}, ${JSON.stringify(sid)}, { defaultState: { spawns: [] } });
        state.spawns.push('B');
        saveState(file, state);
        result.released = releaseLock(${JSON.stringify(lockDir)}, token);
      }
      fs.writeFileSync(${JSON.stringify(bResultFile)}, JSON.stringify(result));
    `;

    // B's own acquireLock() call spins internally for up to ~500ms -- that
    // blocks only the CHILD process, so running it via spawnSync here does
    // not block A, which is a separate, already-running process.
    cp.spawnSync(process.execPath, ['-e', procBScript], { stdio: ['ignore', 'ignore', 'inherit'] });

    await new Promise((resolve) => procA.once('exit', resolve));

    const aResult = JSON.parse(fs.readFileSync(aResultFile, 'utf8'));
    const bResult = JSON.parse(fs.readFileSync(bResultFile, 'utf8'));

    assert.strictEqual(aResult.token, true, 'A must have acquired its lock normally');
    assert.strictEqual(aResult.released, true, 'A must release its own lock with its own token');
    // The core finding 1 assertion: on e8d50fd, reapStaleLock() checked
    // mtime alone, so B's very first mkdir retry reaped and stole A's
    // still-live lock within ~10ms, long before A's 200ms hold elapsed.
    // With the fix, B's bounded spin must instead wait out A's ACTUAL
    // release and acquire its own, later, honestly-obtained lock.
    assert.strictEqual(bResult.gotToken, true, "B must eventually acquire the lock (by waiting for A's real release), not fail outright");
    assert.strictEqual(bResult.released, true);

    const finalFile = path.join(dir, `${sid}.json`);
    const final = JSON.parse(fs.readFileSync(finalFile, 'utf8'));
    assert.deepStrictEqual(
      final.spawns.slice().sort(),
      ['A', 'B'],
      "both A's and B's updates must persist -- neither is lost the way steal-repro.js demonstrated (final.spawns.length === 1)"
    );

    rmTmp(dir);
  }
);

// ===========================================================================
// Round 6 (adversarial review of PR #1294, 72cb202) P2: acquireLock() does
// fs.mkdirSync(lockDir) then writeLockOwner()'s fs.writeFileSync as two
// back-to-back sync statements with nothing between them that can throw --
// the only way to land in that window is an external kill (SIGKILL/OOM/
// Ctrl-C). Pre-fix, the resulting ownerless lock dir was NEVER reapable
// (reapStaleLock()'s own comment: "wedge forever" was the accepted
// tradeoff) and loadState()'s general reap loop could not clear it either
// (fs.unlinkSync throws EISDIR on a directory, silently swallowed by the
// per-file try/catch). Neither existing lock test above constructs this
// state -- they cover "stale mtime, owner alive" and "owner confirmed
// dead", never "owner record never existed".
// ===========================================================================

test('round 6 P2: reapStaleLock() reaps a stale-mtime lock whose owner record was never written (crash between mkdir and writeLockOwner)', () => {
  const dir = mkTmp('sstate-lockrace-noowner-');
  const lockDir = path.join(dir, '.sess-noowner.lock');
  // Simulate the exact on-disk state a crash lands in during acquireLock()'s
  // momentary mkdir-then-write-owner window: a lock dir exists with no
  // owner.json at all.
  fs.mkdirSync(lockDir);
  assert.strictEqual(fs.existsSync(path.join(lockDir, 'owner.json')), false, 'precondition: no owner record on disk');

  const longAgoSec = Date.now() / 1000 - 6; // past LOCK_STALE_MS (5000ms)
  fs.utimesSync(lockDir, longAgoSec, longAgoSec);

  reapStaleLock(lockDir);
  assert.strictEqual(fs.existsSync(lockDir), false, 'an old ownerless lock dir (a crash remnant) must now be reapable, not wedged forever');

  rmTmp(dir);
});

test('round 6 P2: reapStaleLock() does NOT reap a fresh ownerless lock dir -- the age gate is what keeps this safe, not the owner check', () => {
  const dir = mkTmp('sstate-lockrace-noowner-fresh-');
  const lockDir = path.join(dir, '.sess-noowner-fresh.lock');
  fs.mkdirSync(lockDir); // fresh mtime, no owner.json yet -- acquireLock()'s momentary window, caught mid-flight
  reapStaleLock(lockDir);
  assert.strictEqual(fs.existsSync(lockDir), true, 'a lock dir younger than LOCK_STALE_MS must never be reaped, ownerless or not -- age is the only thing that can distinguish a crash remnant from a live acquire truly in progress');
  rmTmp(dir);
});

test("round 6 P2: loadState()'s general reap loop removes a stale ownerless lock DIRECTORY instead of silently swallowing EISDIR", () => {
  const dir = mkTmp('sstate-reaploop-lockdir-');
  const lockDir = path.join(dir, '.orphan-sid.lock');
  fs.mkdirSync(lockDir); // ownerless -- the session that made it crashed and never comes back to retry this exact lock
  const longAgoSec = Date.now() / 1000 - 6;
  fs.utimesSync(lockDir, longAgoSec, longAgoSec);

  const ownFile = path.join(dir, 'me.json');
  fs.writeFileSync(ownFile, JSON.stringify({ count: 1 }));

  // Pre-fix: readdirSync sees the lock dir, the general reap loop tries
  // fs.unlinkSync on it, gets EISDIR, and the per-file try/catch swallows it
  // silently -- the directory survives forever, with no error surfaced.
  const { state } = loadState(dir, 'me', { reapOlderThanMs: 1000, defaultState: {} });

  assert.strictEqual(fs.existsSync(lockDir), false, "loadState()'s own general reap pass must be able to clear a stale ownerless lock dir left over from a session that crashed and never retries the lock");
  assert.strictEqual(state.count, 1, 'own state must still load unchanged alongside the directory reap');

  rmTmp(dir);
});

test("round 6 P2: loadState()'s general reap loop does not steal a lock whose owner pid is still alive, even past the caller's (much larger) reapOlderThanMs", () => {
  const dir = mkTmp('sstate-reaploop-livelock-');
  const lockDir = path.join(dir, '.live-sid.lock');
  const token = acquireLock(lockDir);
  assert.ok(token, 'precondition: lock genuinely acquired, owner is this live test process');

  const longAgoSec = Date.now() / 1000 - 6;
  fs.utimesSync(lockDir, longAgoSec, longAgoSec);

  loadState(dir, 'someone-else', { reapOlderThanMs: 1000, defaultState: {} });

  assert.strictEqual(fs.existsSync(lockDir), true, "a live owner's lock dir must survive loadState()'s general reap pass even when its mtime alone looks old past the caller's reapOlderThanMs");

  releaseLock(lockDir, token);
  rmTmp(dir);
});

// ===========================================================================
// analyzeWorkflow(): structural producer/verifier classification
// ===========================================================================

// CLAUDE.md:58-style example: 5 producers feeding one 8-cap verifier fan-out
// ("5 producers x 8-cap = 40 verifiers is a bug, not thoroughness" -- here the
// fan-out itself is capped at 8, so this is the smaller, still-over-ratio case
// the rule is meant to catch: 8 verifier spawns for 5 producer spawns).
const OVER_RATIO_SCRIPT = `
const p1 = await agent('collect subsystem-a', { model: 'sonnet' })
const p2 = await agent('collect subsystem-b', { model: 'sonnet' })
const p3 = await agent('collect subsystem-c', { model: 'sonnet' })
const p4 = await agent('collect subsystem-d', { model: 'sonnet' })
const p5 = await agent('collect subsystem-e', { model: 'sonnet' })
const claims = mergeClaims(p1, p2, p3, p4, p5)
const verified = await parallel(claims.slice(0, 8).map(c => () => agent(\`Verify using context \${JSON.stringify(p1)}: \${c}\`, { model: 'sonnet' })))
`;

// Same shape, capped at 5 instead of 8 -- one verifier per producer, compliant.
const COMPLIANT_SCRIPT = OVER_RATIO_SCRIPT.replace('slice(0, 8)', 'slice(0, 5)');

test('analyzeWorkflow: CLAUDE.md:58 example (5 producers, 8-cap verifier fan-out) flags over-ratio', () => {
  const result = analyzeWorkflow(OVER_RATIO_SCRIPT);
  assert.strictEqual(result.producers, 5);
  assert.strictEqual(result.verifiers, 8);
  assert.strictEqual(result.overRatio, true);
  assert.deepStrictEqual(result.uncapped, [], 'the fan-out IS capped (.slice(0, 8)) -- only the ratio should trip');
});

test('analyzeWorkflow: a compliant 1:1 fixture (5 producers, 5-cap verifier fan-out) does not flag', () => {
  const result = analyzeWorkflow(COMPLIANT_SCRIPT);
  assert.strictEqual(result.producers, 5);
  assert.strictEqual(result.verifiers, 5);
  assert.strictEqual(result.overRatio, false);
  assert.deepStrictEqual(result.uncapped, []);
});

test('analyzeWorkflow: an uncapped data-driven fan-out is flagged on its own terms, without fabricating a ratio violation', () => {
  // A common, legitimate shape: several uncapped producers feed one synthesis
  // step. The spawn count of the fan-out is unknowable, so the ratio check
  // must not treat "unknown" as zero and invent an overRatio here -- only the
  // missing cap should be reported.
  const script = `
const items = await agent('list items', { model: 'sonnet' })
const collected = await parallel(items.list.map(x => () => agent(\`collect \${x}\`, { model: 'sonnet' })))
const synthesis = await agent(\`Summarize: \${JSON.stringify(collected)}\`, { model: 'sonnet' })
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.overRatio, false, 'unknown-count units must not fabricate a ratio violation');
  assert.strictEqual(result.uncapped.length, 1, 'the uncapped .map() with no .slice()/maxItems must still be flagged');
});


// ===========================================================================
// Round 2 regression (adversarial review of PR #1294, findings 0, 5, 8): the
// old classifier had TWO branches -- a literal-list branch checking only
// DIRECT bindings (finding 0), and a data-driven map branch that called ANY
// per-item fan-out over a one-hop-derived list a verifier fleet with no
// lexicon check at all (finding 5), plus an `.every()` all-or-nothing literal
// check that let one unrelated call launder an entire verifier fleet as
// producers (finding 8). Fixed: ONE per-call rule (see analyzeWorkflow's own
// doc comment) -- a call is a verifier iff it references an earlier binding
// (direct OR derived) AND its own text matches VERIFICATION_LEXICON_RE.
// ===========================================================================

test('round 2 finding 0: a literal-list fan-out referencing a DERIVED binding (not just a direct one) is still a verifier fleet', () => {
  const script = `
const p1 = await agent('a', { model: 'sonnet' })
const p2 = await agent('b', { model: 'sonnet' })
const claims = mergeClaims(p1, p2)
const verified = await parallel([
  agent('verify host1 vs ' + claims, { model: 'sonnet' }),
  agent('verify host2 vs ' + claims, { model: 'sonnet' }),
  agent('verify host3 vs ' + claims, { model: 'sonnet' }),
  agent('verify host4 vs ' + claims, { model: 'sonnet' }),
  agent('verify host5 vs ' + claims, { model: 'sonnet' }),
])
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 2);
  assert.strictEqual(result.verifiers, 5);
  assert.strictEqual(result.overRatio, true);
});

test('round 2 finding 5: a capped data-driven fan-out with no verification-lexicon match is an ordinary batch pipeline, not a verifier fleet', () => {
  const script = `
const p1 = await agent('collect list of files to process', { model: 'sonnet', schema: { maxItems: 5 } })
const files = extractFiles(p1)
const processed = await parallel(files.slice(0, 5).map(f => () => agent('process file ' + f, { model: 'sonnet' })))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 6, 'the collect call plus the 5-cap per-item fan-out are all producers -- no lexicon word, no earlier-binding reference framed as verification');
  assert.strictEqual(result.verifiers, 0);
  assert.strictEqual(result.overRatio, false);
});

test('round 2 finding 5: the benign batch pipeline above is actually allowed through under the blocking opt-in', async () => {
  const script = `
const p1 = await agent('collect list of files to process', { model: 'sonnet', schema: { maxItems: 5 } })
const files = extractFiles(p1)
const processed = await parallel(files.slice(0, 5).map(f => () => agent('process file ' + f, { model: 'sonnet' })))
`;
  const p = { tool_name: 'Workflow', tool_input: { script }, session_id: 'sess-r2-f5', cwd: '/tmp' };
  assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } }));
});

test('round 2 finding 8: one unrelated call in a literal array no longer launders the rest of a verifier fleet as producers', () => {
  const script = `
const a = await agent('produce a', { model: 'sonnet' })
const results = await parallel([
  agent('unrelated task', { model: 'sonnet' }),
  agent('verify 1 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 2 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 3 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 4 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 5 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 6 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 7 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 8 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 9 using ' + JSON.stringify(a), { model: 'sonnet' }),
])
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 2, 'the bare "a" producer plus the one unrelated literal call, counted per call, not per unit');
  assert.strictEqual(result.verifiers, 9);
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// Round 2 finding 1 (adversarial review of PR #1294): findDerivedBindings did
// not record a cap when a derived binding's RHS carried .slice(N[, M]) on an
// earlier binding -- `const capped = items.list.slice(0, 5)` resolved to
// "uncapped" even though the fan-out over `capped` is provably bounded at 5.
// ===========================================================================

test('round 2 finding 1: a named intermediate .slice(N) binding resolves the fan-out cap, not "uncapped"', () => {
  const script = `
const items = await agent('list items', { model: 'sonnet' })
const capped = items.list.slice(0, 5)
const verified = await parallel(capped.map(x => () => agent('verify ' + x, { model: 'sonnet' })))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0, 'the named-slice cap must resolve the count -- this must not be reported as uncapped');
  assert.strictEqual(result.producers, 1);
  assert.strictEqual(result.verifiers, 5);
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// Round 7 finding 1 (P1, adversarial round 7 of PR #1294): the cap-resolution
// fallback in scopedMapCap() (and the structurally identical fallback in
// resolvePipelineItemsCap()) used to match a bare NAME anywhere in the WHOLE
// script with no scope or position check at all -- an unrelated same-named
// binding elsewhere (a different function, before OR after the real call
// site) could silently "cap" a genuinely unbounded fan-out, defeating
// admission control, or silently un-cap an already-resolvable one. Fixed via
// resolveNamedCap(): resolution is now constrained to the nearest PRECEDING
// declaration of that name that can actually reach the call site; if none
// exists, the fan-out fails closed to uncapped/unknownUnits rather than
// crediting a cap that belongs to different code.
// ===========================================================================

test('round 7 finding 1 (P1): an unrelated same-named .slice() binding in a different, unconnected function must not silently supply a cap for a .map() receiver with no binding of its own', () => {
  const script = `
function unrelatedHelper() {
  const capped = someOtherThing.slice(0, 2)
  return capped
}
const hugeItems = await agent('collect a large list', { model: 'sonnet' })
const capped = hugeItems.list
const verified = await parallel(capped.map(u => () => agent('verify and audit user: ' + JSON.stringify(u), { model: 'sonnet' })))
`;
  const result = analyzeWorkflow(script);
  // Before the fix: `capped` (the .map() receiver) resolved via a bare
  // name-keyed lookup with no position/scope check -- it matched
  // unrelatedHelper's OWN `capped = someOtherThing.slice(0, 2)` (count 2),
  // even though that binding cannot reach this call site at all (different
  // function, unrelated data). Fixed: `capped` here is a plain rebind
  // (`hugeItems.list`, no .slice()) with no reachable cap-bearing
  // declaration of its own, so the fan-out must fail closed to uncapped,
  // never silently credited with someone else's cap.
  assert.strictEqual(result.uncapped.length, 1, 'no reachable cap exists for this receiver -- must be flagged uncapped, not silently capped at 2');
  assert.strictEqual(result.unknownUnits, 1);
  assert.strictEqual(result.verifiers, 0, 'an uncapped unit must not fabricate a verifier count from an unrelated binding');
});

test('round 7 finding 1 (P1): a LATER, unrelated same-named .slice() binding elsewhere in the script must not retroactively un-cap an already-resolvable fan-out', () => {
  const script = `
const items = await agent('collect targets', { model: 'sonnet' })
const capped = items.list.slice(0, 3)
const verified = await parallel(capped.map(u => () => agent('verify ' + JSON.stringify(u), { model: 'sonnet' })))
function unrelatedHelper() {
  const capped = somethingElse.slice(0, 99)
  return capped
}
`;
  const result = analyzeWorkflow(script);
  // Before the fix: findNamedSliceCaps() returned a bare Map<name, count> --
  // last-write-wins over the WHOLE script regardless of position, so
  // unrelatedHelper's LATER `capped = somethingElse.slice(0, 99)` (which
  // cannot reach this call site -- it comes after, in a different function)
  // silently overwrote the real, reachable cap of 3 with 99. Fixed:
  // resolution picks the nearest PRECEDING same-named declaration, never a
  // textually-later one.
  assert.strictEqual(result.uncapped.length, 0, 'the real, reachable .slice(0, 3) cap must still resolve');
  assert.strictEqual(result.verifiers, 3, 'the later, unreachable .slice(0, 99) binding must not override the real cap of 3');
});

test('round 7 finding 1 (P1): resolvePipelineItemsCap()\'s bare-identifier fallback has the identical unscoped-match bug as scopedMapCap()\'s, and needed the identical fix', () => {
  const script = `
function unrelatedHelper() {
  const capped = someOtherThing.slice(0, 2)
  return capped
}
const hugeItems = await agent('collect a large list', { model: 'sonnet' })
const capped = hugeItems.list
const checked = await pipeline(
  capped,
  x => agent('verify ' + x, { model: 'sonnet' })
)
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 1, 'no reachable cap exists for the pipeline items binding -- must be flagged uncapped');
  assert.strictEqual(result.unknownUnits, 1);
  assert.strictEqual(result.verifiers, 0, 'an uncapped pipeline unit must not fabricate a verifier count from an unrelated binding');
});

// ===========================================================================
// P1-A regression (adversarial review of PR #1294, reproduced live against
// ce0af4f): cap detection must be SCOPED to the expression immediately
// chained onto `.map(`, never a bare substring match over the whole fan-out's
// text. Against ce0af4f's unscoped substring/regex check, a per-item
// `.slice(0, 200)` PROMPT truncation inside the map callback read as a cap on
// the mapped array (a false negative -- the fan-out was actually uncapped),
// and separately made analyzeWorkflow report `verifiers: 200` (the digits
// out of "0, 200"), fabricating an over-ratio deny under
// CLAUDE_FANOUT_GATE_BLOCK=1 for a script with exactly one verifier spawn.
// ===========================================================================

test('P1-A: a per-item .slice() inside a map callback (prompt truncation) is not mistaken for a cap on the mapped array', () => {
  const script = `
const items = await agent('collect targets', { model: 'sonnet' })
const checked = await parallel(items.list.map(x => () => agent('check: ' + x.description.slice(0, 200), { model: 'sonnet' })))
`;
  const result = analyzeWorkflow(script);
  // ce0af4f's unscoped check read ".slice(0, 200)" as a cap on the fan-out
  // (false negative -- uncapped.length would be 0) AND separately extracted
  // "200" as a verifier count via the same substring/regex, fabricating
  // verifiers:200 / overRatio:true. Fixed: this unit's count is genuinely
  // unresolvable (no cap immediately chained onto `.map(`), so it is excluded
  // from the ratio (P1-C) and flagged only as uncapped.
  assert.strictEqual(result.uncapped.length, 1, 'the fan-out itself carries no cap chained onto .map( -- it must be flagged uncapped');
  assert.strictEqual(result.unknownUnits, 1);
  assert.strictEqual(result.verifiers, 0, 'the per-item .slice(0, 200) prompt truncation must never be read as a verifier count');
  assert.strictEqual(result.overRatio, false, 'one unresolvable unit must not fabricate an over-ratio verdict');
});

test('P1-A: a maxItems schema cap on the producing agent() call resolves the fan-out count precisely', () => {
  const script = `
const items = await agent('collect targets', { model: 'sonnet', schema: { type: 'object', properties: { list: { type: 'array', maxItems: 5 } } } })
const p1 = await agent('produce baseline', { model: 'sonnet' })
const checked = await parallel(items.list.map(x => () => agent('verify ' + x + ' against ' + JSON.stringify(p1), { model: 'sonnet' })))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0, 'a maxItems cap on the producing agent() call must resolve the count, not leave it uncapped');
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.verifiers, 5, 'the resolved cap (maxItems: 5) is the verifier count');
  assert.strictEqual(result.producers, 2, 'both bare agent() calls (items, p1) are producers');
});

// ===========================================================================
// P1-B regression (adversarial review of PR #1294, reproduced live against
// ce0af4f): "references any earlier-bound result" conflated CONSUMING a prior
// result with VERIFYING it. A sequential research -> fetch(uses p1) ->
// summarize(uses p2) pipeline -- three ordinary producer/synthesis stages --
// returned producers:1, verifiers:2, overRatio:true under ce0af4f: a false
// positive on an extremely common multi-stage script shape.
// ===========================================================================

test('P1-B: a sequential research -> fetch(p1) -> summarize(p2) pipeline is three producers, not an escalating verifier chain', () => {
  const script = `
const p1 = await agent('research the topic', { model: 'sonnet' })
const p2 = await agent('fetch details using ' + JSON.stringify(p1), { model: 'sonnet' })
const p3 = await agent('summarize using ' + JSON.stringify(p2), { model: 'sonnet' })
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 3, 'every bare top-level agent() call is a producer, even one that consumes an earlier binding');
  assert.strictEqual(result.verifiers, 0);
  assert.strictEqual(result.overRatio, false);
});

test('P1-B: a literal-list fan-out where every item verifies an earlier binding is still classified as a verifier fleet', () => {
  // The positive case this file's classifier must still catch: unlike the
  // sequential-pipeline fixture above, EVERY literal agent() call here
  // references an earlier DIRECT binding, so this parallel() is a genuine
  // verifier fleet, not a producer stage.
  const script = `
const a = await agent('produce a', { model: 'sonnet' })
const verified = await parallel([
  agent('verify 1 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 2 using ' + JSON.stringify(a), { model: 'sonnet' }),
])
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 1);
  assert.strictEqual(result.verifiers, 2);
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// P1-C regression (adversarial review of PR #1294, reproduced live against
// ce0af4f): a single maxItems-capped (or otherwise unresolvable) unit set a
// script-wide `hasUnknownCount` flag that disabled the overRatio check for
// the ENTIRE script. A script with 2 producers, one unresolvable data-driven
// fan-out, and 5 literal verifiers returned overRatio:false under ce0af4f.
// ===========================================================================

test('P1-C: one unresolvable-count unit excludes only itself from the ratio, not the whole script', () => {
  const script = `
const a = await agent('produce a', { model: 'sonnet' })
const b = await agent('produce b', { model: 'sonnet' })
const scanned = await parallel(args.files.map(f => () => agent('scan ' + f, { model: 'sonnet' })))
const verified = await parallel([
  agent('verify 1 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 2 using ' + JSON.stringify(a), { model: 'sonnet' }),
  agent('verify 3 using ' + JSON.stringify(b), { model: 'sonnet' }),
  agent('verify 4 using ' + JSON.stringify(b), { model: 'sonnet' }),
  agent('verify 5 using ' + JSON.stringify(a), { model: 'sonnet' }),
])
`;
  const result = analyzeWorkflow(script);
  // args.files is a workflow global never bound by any agent/parallel/pipeline
  // call in this script -- its count is genuinely unresolvable.
  assert.strictEqual(result.uncapped.length, 1);
  assert.strictEqual(result.unknownUnits, 1, 'the unresolvable unit must be recorded, not silently dropped');
  assert.strictEqual(result.producers, 2);
  assert.strictEqual(result.verifiers, 5);
  assert.strictEqual(result.overRatio, true, 'the resolvable units alone (2 producers, 5 verifiers) must still trip the ratio check');
});

// ===========================================================================
// Round 3 finding A regression (adversarial review of PR #1294, reproduced
// live against f7623af): analyzeWorkflow()'s only "data-driven fan-out"
// signal was the literal substring '.map(' inside a parallel()/pipeline()
// call's own text. The real, currently-used Workflow API calls pipeline with
// a positional ARRAY argument plus per-item stage callbacks --
// `pipeline(items, stage1, stage2, ...)` -- with no `.map()` anywhere; the
// per-item expansion is implicit in pipeline()'s own semantics. Reproduced
// against a real persisted production workflow script from this machine (a
// verify/refute drift-check workflow whose own meta.phases say "one verifier
// per claim" and "two skeptics per claim try to overturn") -- f7623af read
// it as `{producers: 11, verifiers: 0, overRatio: false, uncapped: [],
// unknownUnits: 0}`, zero verifiers out of what should be a majority-verifier
// fleet. Fixed: pipelineCallShape() recognizes the
// `pipeline(ITEMS, fn, fn, ...)` shape, resolves ITEMS's cap the same way
// scopedMapCap() resolves a `.map(`-chained array (a named .slice() binding,
// or a maxItems schema cap on the producing agent() call), then classifies
// each stage's own agent() call via the existing per-call rule, multiplied
// by the resolved cap.
// ===========================================================================

test('round 3 finding A: pipeline(items, stage1, stage2) recognizes the real calling convention, not just .map(', () => {
  const script = `
const items = await agent('collect claims', { model: 'sonnet', schema: { type: 'object', properties: { list: { type: 'array', maxItems: 5 } } } })
const checked = await pipeline(
  items.list,
  claim => agent('verify ' + claim, { model: 'sonnet' }),
  verified => agent('refute ' + verified, { model: 'sonnet' })
)
`;
  const result = analyzeWorkflow(script);
  // f7623af didn't recognize the pipeline(items, fn, fn) shape at all: with
  // no `.map(` anywhere and no stage-parameter bindings to satisfy
  // "references an earlier binding", it read this as producers:3 (the bare
  // "items" producer plus the verify/refute stage calls, none classified as
  // verifiers), verifiers:0, overRatio:false.
  assert.strictEqual(result.uncapped.length, 0, 'the maxItems:5 schema cap on the producing agent() call must resolve the pipeline items cap');
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.producers, 1, 'only the bare "items" producer call -- both stage callbacks are verifier-lexicon-shaped');
  assert.strictEqual(result.verifiers, 10, 'two verifier-lexicon stages x the resolved cap of 5 = 10, not 0');
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// Round 3 finding A2 regression (adversarial review of PR #1294, reproduced
// live against f7623af): callSpans() resumed scanning at a call's CLOSING
// paren after balancing, so a parallel()/pipeline() call nested textually
// inside another one's arguments was never discovered as its own span --
// invisible to fanoutSpans entirely (compounding finding A above: the real
// production fixture's nested `parallel([...refute agents...])` inside the
// outer `pipeline(CLAIMS, ...)` callback was never found). Fixed: resume
// scanning right after the call's OPENING paren instead, so a nested
// parallel()/pipeline() is discovered as its own independent span while the
// outer call's own span boundaries (computed by depth-balancing from that
// same start) are unaffected. That alone would double-count: the outer
// span's own scan would enumerate the nested call's agent() calls, and the
// newly-discovered nested span would enumerate them again. Companion fix:
// directAgentSpansWithin() (renamed from literalAgentSpansWithin) additionally
// excludes any agent() call nested inside a DIFFERENT, independently
// discovered fan-out span fully contained in the range being scanned, so
// each call is attributed to exactly one unit.
// ===========================================================================

test('round 3 finding A2: a nested pipeline(parallel([agent(...), agent(...)])) reports verifiers: 2, not 4, after the fix', () => {
  const script = `
const p1 = await agent('produce a claim list')
const results = await pipeline(
  p1,
  c => agent('process ' + c),
  async (v, c) => {
    const votes = await parallel([
      () => agent('verify this against ' + v),
      () => agent('verify this against ' + v + ' again'),
    ])
    return votes
  }
)
`;
  const result = analyzeWorkflow(script);
  // f7623af never discovered the nested parallel([...]) as its own span (the
  // A2 bug) and never recognized the outer pipeline() shape either
  // (finding A) -- its three nested agent() calls (process, verify, verify)
  // were all swept as ordinary un-attributed producers: f7623af read this as
  // producers:4, verifiers:0.
  assert.strictEqual(result.verifiers, 2, 'the two verify() calls inside the nested parallel() must be counted exactly once each, not doubled to 4');
  assert.strictEqual(result.producers, 1, 'the bare top-level "produce a claim list" call');
  assert.strictEqual(result.unknownUnits, 1, 'the outer pipeline\'s items binding (p1) carries no resolvable maxItems/slice cap');
  assert.strictEqual(result.uncapped.length, 1);
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// Round 3 finding B regression (adversarial review of PR #1294, reproduced
// live against f7623af): `isDataDriven = capText.includes('.map(')` was a raw
// substring search over the fan-out's ENTIRE text, including prompt-building
// code inside its own literal agent() calls -- an incidental `.map(` used to
// join/format a prompt string (e.g. `tags.map(t => t).join(',')`) made a
// genuine literal-list fleet of explicit verify() calls misread as
// "data-driven", short-circuiting the true per-item enumeration. Fixed:
// dataDrivenCapText() excises each nested agent() call's own text (not just
// nested fan-out spans) before the '.map(' check, via the same
// paren-balanced ownText() exclusion already used for nested fan-outs.
// ===========================================================================

test('round 3 finding B: an incidental .map( inside one verify call\'s own prompt text does not launder a literal-list fleet into "data-driven"', () => {
  const script = `
const p1 = await agent('produce a list of claims')
const results = await parallel([
  () => agent('verify claim 1 against ' + p1 + ' tags: ' + tags.map(t => t).join(',')),
  () => agent('verify claim 2 against ' + p1),
  () => agent('verify claim 3 against ' + p1),
  () => agent('verify claim 4 against ' + p1),
  () => agent('verify claim 5 against ' + p1),
  () => agent('verify claim 6 against ' + p1),
  () => agent('verify claim 7 against ' + p1),
  () => agent('verify claim 8 against ' + p1),
  () => agent('verify claim 9 against ' + p1),
  () => agent('verify claim 10 against ' + p1),
])
`;
  const result = analyzeWorkflow(script);
  // f7623af's unscoped substring check found ".map(" anywhere in the whole
  // parallel([...]) call's text (including inside one item's own prompt
  // expression) and misread this literal list of 10 explicit verify() calls
  // as one data-driven unit -- since "tags" is bound to nothing, that unit's
  // count was unresolvable: f7623af read producers:1, verifiers:0, with the
  // entire 10-call fleet vanishing into an uncapped/unknown unit instead.
  assert.strictEqual(result.uncapped.length, 0, 'this is a literal list of 10 explicit calls, not an unresolvable data-driven unit');
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.producers, 1);
  assert.strictEqual(result.verifiers, 10, 'all 10 explicit verify() calls must be counted individually, not laundered away by one unrelated incidental .map(');
  assert.strictEqual(result.overRatio, true);
});

test('round 3 finding B: an incidental .map( whose receiver shares a name with an earlier maxItems-capped producer does not fabricate the count from that unrelated cap', () => {
  const script = `
const p1 = await agent('produce a list of claims', { schema: { maxItems: 3 } })
const results = await parallel([
  () => agent('verify claim 1 against ' + p1 + ' via ' + p1.map(t => t).join(',')),
  () => agent('verify claim 2 against ' + p1),
  () => agent('verify claim 3 against ' + p1),
  () => agent('verify claim 4 against ' + p1),
  () => agent('verify claim 5 against ' + p1),
  () => agent('verify claim 6 against ' + p1),
  () => agent('verify claim 7 against ' + p1),
  () => agent('verify claim 8 against ' + p1),
  () => agent('verify claim 9 against ' + p1),
  () => agent('verify claim 10 against ' + p1),
])
`;
  const result = analyzeWorkflow(script);
  // Worse than the previous case: here the incidental map's receiver ("p1")
  // happens to share its name with p1's OWN maxItems:3 schema cap, so
  // f7623af's unscoped substring check both (a) misread this as data-driven
  // AND (b) successfully resolved a cap for it -- fabricating verifiers:3
  // (borrowed from an unrelated schema field on an unrelated array) instead
  // of the true count of 10 explicit calls, with no `uncapped` flag to
  // signal anything was wrong.
  assert.strictEqual(result.producers, 1);
  assert.strictEqual(result.verifiers, 10, 'the true count of 10 explicit verify() calls, not fabricated as 3 from the unrelated maxItems cap');
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// Round 4 (adversarial review of PR #1294, e8d50fd) findings 3 and 4.
// ===========================================================================

test('round 4 finding 3: pipeline() stages using space-less async arrows (`async()=>`, `async(x)=>`) are recognized as function-shaped, not misread as a bare literal-list call', () => {
  const script = `
const items = await agent('collect claims', { model: 'sonnet', schema: { type: 'object', properties: { list: { type: 'array', maxItems: 5 } } } })
const checked = await pipeline(
  items.list,
  async()=>agent('produce a candidate', { model: 'sonnet' }),
  async(done)=>agent('refute ' + done, { model: 'sonnet' })
)
`;
  const result = analyzeWorkflow(script);
  // Against e8d50fd: isFunctionArgText()'s async-prefix strip used `\s+`
  // (one-or-more whitespace REQUIRED) after `async`, so the space-less
  // `async()=>`/`async(done)=>` stages fell through every branch to
  // `false`. pipelineCallShape()'s stage-shape gate then rejected the
  // whole call as not pipeline-shaped (isStageShaped(rawArgs[1]) false),
  // so it fell through to the bare literal-call heuristic: every agent()
  // call found directly inside the pipeline() call's own span, classified
  // WITHOUT the item cap ever being applied -- e8d50fd reports
  // {producers: 2, verifiers: 0}, dropping the resolved 5x cap on both
  // stages and misclassifying stage 2's "refute ...done" call as a
  // producer because neither of firstParamName()'s branches recognized
  // the `async(done)=>` shape either, so `done` was never threaded into
  // derivedBindings for the isVerifierCall() reference check.
  assert.strictEqual(result.uncapped.length, 0, 'the maxItems:5 schema cap on the producing agent() call must resolve the pipeline items cap');
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.producers, 6, 'the bare "items" producer (1) plus stage 1 -- no verification lexicon -- x the resolved cap of 5');
  assert.strictEqual(result.verifiers, 5, 'stage 2 ("refute", referencing stage 1\'s per-item result "done") x the resolved cap of 5, not 0');
  assert.strictEqual(result.overRatio, false);
});

test('round 4 finding 4: a pipeline() stage given as a bare identifier resolves to its own top-level declaration, is classified as the per-item callback, and is excluded from top-level producer counting', () => {
  const script = `
function verifyOne(claim) {
  return agent('refute ' + claim, { model: 'sonnet' });
}
const items = await agent('collect claims', { model: 'sonnet', schema: { type: 'object', properties: { list: { type: 'array', maxItems: 5 } } } })
const checked = await pipeline(items.list, verifyOne)
`;
  const result = analyzeWorkflow(script);
  // Against e8d50fd: pipelineCallShape()'s stage-shape gate only recognized
  // an INLINE function-shaped stage argument -- a bare identifier
  // reference (`verifyOne`) matched neither the function-literal nor the
  // arrow-param branches, so the whole call was rejected as not
  // pipeline-shaped and fell to the literal-call heuristic, which finds NO
  // agent() call directly inside `pipeline(items.list, verifyOne)`'s own
  // span (the real call lives inside verifyOne's OWN top-level declaration,
  // textually outside the pipeline() call) -- zero credit for the whole
  // fan-out. Meanwhile verifyOne's own declaration, not being nested inside
  // any fanoutSpan, was picked up by the final bare-top-level agentSpans
  // loop and counted as a SECOND, ordinary, un-multiplied producer on top
  // of the bare "items" producer. Net result on e8d50fd: {producers: 2,
  // verifiers: 0} for what should be one top-level producer ("items") and
  // a 5x verifier fleet, with verifyOne's own declaration folded in, not
  // double-counted.
  assert.strictEqual(result.uncapped.length, 0, 'the maxItems:5 schema cap on the producing agent() call must resolve the pipeline items cap');
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.producers, 1, 'only the bare "items" producer -- verifyOne\'s declaration must NOT also be counted as a separate top-level producer');
  assert.strictEqual(result.verifiers, 5, 'verifyOne resolved to its own declaration, classified as the per-item callback, x the resolved cap of 5');
  assert.strictEqual(result.overRatio, true);
});

test('round 4 finding 4: an unresolvable bare-identifier pipeline stage (no matching top-level declaration in the script) fails closed to an unknownUnit, not a fabricated zero', () => {
  const script = `
const items = await agent('collect claims', { model: 'sonnet', schema: { type: 'object', properties: { list: { type: 'array', maxItems: 5 } } } })
const checked = await pipeline(items.list, verifyOneDefinedElsewhere)
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.unknownUnits, 1, 'a reference with no resolvable declaration must be flagged, never silently counted as zero');
  // Round 5 finding 2: this fixture's numeric cap (maxItems: 5 on the
  // producing agent() call) resolves fine -- only the pipeline STAGE body
  // is unresolvable. Before the fix this assertion was 1, which encoded
  // the exact bug being corrected (uncapped growing whenever a stage body
  // was unresolved, regardless of whether the cap itself resolved). The
  // cap-resolved-but-body-unresolved case now surfaces via unknownUnits
  // only, so uncapped must stay empty here.
  assert.strictEqual(result.uncapped.length, 0);
  assert.strictEqual(result.producers, 1, 'only the bare "items" producer -- the unresolvable pipeline unit contributes nothing to the sums');
  assert.strictEqual(result.verifiers, 0);
});

test('round 4 finding 4: a .map() callback given as a bare identifier resolves to its own top-level declaration for lexicon/reference checks, and is excluded from top-level producer counting', () => {
  const script = `
function checkOne(claim) {
  return agent('refute ' + claim, { model: 'sonnet' });
}
const p1 = await agent('produce a list of claims', { schema: { maxItems: 5 } })
const results = await parallel(p1.map(checkOne))
`;
  const result = analyzeWorkflow(script);
  // Symmetric .map() case: e8d50fd's itemMatch regex captured "checkOne"
  // itself as if it were the per-item PARAMETER name, and the lexicon/
  // reference checks ran against the call site's own raw text
  // (`parallel(p1.map(checkOne))`), which carries no "refute" and no
  // reference to a per-item parameter at all -- misread as an ordinary
  // producer unit, while checkOne's own top-level declaration was ALSO
  // counted separately as a bare top-level producer.
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.producers, 1, 'only the bare "p1" producer -- checkOne\'s declaration must not also be counted separately');
  assert.strictEqual(result.verifiers, 5, 'checkOne resolved to its own declaration ("refute", referencing its own "claim" param) x the resolved cap of 5');
  assert.strictEqual(result.overRatio, true);
});

test('round 4 finding 4: an unresolvable bare-identifier .map() callback fails closed to an unknownUnit, not a fabricated zero', () => {
  const script = `
const p1 = await agent('produce a list of claims', { schema: { maxItems: 5 } })
const results = await parallel(p1.map(checkOneDefinedElsewhere))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.unknownUnits, 1, 'a reference with no resolvable declaration must be flagged, never silently counted as zero');
  // Round 5 finding 2: same correction as the pipeline test above -- this
  // fixture's numeric cap (maxItems: 5) resolves fine, only the .map()
  // callback body is unresolvable, so uncapped must stay empty (the old
  // assertion of 1 encoded the bug this round fixes).
  assert.strictEqual(result.uncapped.length, 0);
  assert.strictEqual(result.producers, 1, 'only the bare "p1" producer -- the unresolvable map unit contributes nothing to the sums');
  assert.strictEqual(result.verifiers, 0);
});

// ===========================================================================
// Round 5 (ce-code-review of PR #1294, validator-reproduced): findings 1-4.
// ===========================================================================

// These four synchronous performance guards use CPU time for both the measured
// work and the analysis deadline, so descheduling cannot produce an early bailout.
// They do not prove the external 5s wall-clock SLA. Other deadline tests stay real.
test('round 5 finding 1 (P0): analyzeWorkflow() scales near-linearly on a pathologically nested script -- regression guard against callSpans() reverting to O(n^2)', () => {
  // Matches the finding's own reproduction shape: N nested `agent(` calls,
  // no closing text needed since callSpans()/analyzeWorkflow() operate on
  // raw text, not a real parser. The old per-match paren-balancing rescan
  // took ~5.3-5.7s at N=32000 (already past settings.json's own
  // "timeout": 5 for this hook) -- a timed-out PreToolUse hook does not
  // block the gated tool call (see this module's own doc comment), so this
  // is a real admission-bypass path, not just a slow test.
  assertPerfScaling({
    n: 8000,
    scale: 4,
    maxRatio: 6,
    sanityMs: 5000,
    label: 'analyzeWorkflow() nested agent() calls',
    measure: (N) => {
      const script = 'agent('.repeat(N) + ')'.repeat(N);
      const { result, elapsedMs } = measureCpu(() => analyzeWorkflow(script), {
        cpuClock: true,
      });
      assert.strictEqual(
        result.flagged,
        false,
        'a budget bailout must not masquerade as a fast completed analysis',
      );
      assert.strictEqual(
        result.producers,
        N,
        'all nested agent() calls must be analyzed',
      );
      return elapsedMs;
    },
  });
});

test('round 5 finding 1 (P0): an internal analysis budget fails closed (flagged:true, unknownUnits/uncapped set) instead of ever running unchecked into the hook\'s external kill', () => {
  // Deadline is forced into the past via the options override (not the
  // env-var tunable, which is read once at module load) -- deterministic
  // and instant, no large fixture required. Any non-empty script exercises
  // the check since callSpans()'s budget check runs at its very first
  // iteration (i === 0).
  const result = analyzeWorkflow("agent('x')", { budgetMs: -1 });
  assert.strictEqual(result.flagged, true, 'a budget-exceeded analysis must self-report as flagged, not silently return a clean-looking result');
  assert.ok(result.uncapped.length > 0 || result.unknownUnits > 0, 'a budget-exceeded analysis must land in uncapped/unknownUnits so run() treats it as fail-closed, not silently compliant');
});

test("round 7 finding 2 (P1): analyzeWorkflow() scales near-linearly on a FLAT script -- regression guard distinct from round 5 finding 1's NESTED-shape guard above", () => {
  // Round 5 finding 1 covers a NESTED shape (N agent( calls nested inside
  // each other). This covers a FLAT shape instead: N independent top-level
  // agent() calls plus N independent empty parallel() calls, no nesting at
  // all -- the reviewer's own reproduction for round 7 finding 2. Before
  // the fix, THREE separate O(n^2) paths (none caught by round 5's own
  // fix, which only addressed callSpans()/scanGenericBindRhs()) drove this
  // shape to ~2.9-3.0s at N=9000 and ~5.6-5.7s at N=12000 -- past both this
  // module's own 3000ms analysis budget and settings.json's 5000ms
  // hook timeout -- while `flagged` stayed false throughout (a timed-out
  // PreToolUse hook does not block the gated tool call, so this was a real
  // silent admission bypass, not just a slow analysis). The three paths,
  // found by re-measuring after each partial fix rather than trusting the
  // fix was complete: (1) the topLevelCoarseSpans filter and the final
  // agentSpans classification loop, both named in the finding text; (2)
  // directAgentSpansWithin()'s own unconditional agentSpans.filter() scan,
  // called once per fan-out span; (3) dataDrivenCapText()'s per-call
  // [...fanoutSpans, ...agentSpans].sort() plus ownText()'s own
  // unconditional full-array scan -- the actual DOMINANT cost, only
  // surfaced because fixing (1) and (2) alone left timing unchanged.
  //
  // COVERAGE: this test (FLAT, no nesting) plus round 5 finding 1's test
  // (NESTED, no top-level fan-outs) together cover the two shapes actually
  // measured across both rounds. NOT covered by either: a script mixing
  // deep nesting AND a large flat sibling count in the same script, or one
  // dominated by coarseSpans (.forEach()/for-loop) rather than agent()/
  // parallel() calls -- believed lower-risk since coarseSpans are rarer in
  // the corpus (see loopSpans()'s and resolveNamedFunctionDecl()'s own
  // corpus notes elsewhere in this file), but not independently measured
  // here.
  assertPerfScaling({
    n: 2250,
    scale: 4,
    maxRatio: 6,
    sanityMs: 5000,
    label: 'analyzeWorkflow() flat agent() + parallel() calls',
    measure: (N) => {
      const lines = [];
      for (let i = 0; i < N; i += 1) lines.push(`agent('item ${i}')`);
      for (let i = 0; i < N; i += 1) lines.push('parallel()');
      const script = lines.join('\n');
      const { result, elapsedMs } = measureCpu(() => analyzeWorkflow(script), {
        cpuClock: true,
      });
      assert.strictEqual(
        result.flagged,
        false,
        'an in-budget, well-formed flat script must not fail closed',
      );
      assert.strictEqual(
        result.producers,
        N,
        'every bare top-level agent() call is its own producer',
      );
      assert.strictEqual(
        result.verifiers,
        0,
        'the empty parallel() calls carry no literal or data-driven agent() calls of their own',
      );
      return elapsedMs;
    },
  });
});

test('round 5 finding 2: a resolved numeric cap (pipeline) is never reported as uncapped merely because a stage body is itself unresolvable -- uncapped must only grow when the CAP is unresolved', () => {
  const script = `
const items = await agent('collect claims', { model: 'sonnet', schema: { type: 'object', properties: { list: { type: 'array', maxItems: 5 } } } })
const checked = await pipeline(items.list, verifyOneDefinedElsewhere)
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0, 'the maxItems:5 cap on "items" resolves fine -- the ONLY unresolvable thing here is the stage body, which must route through unknownUnits only, never fabricate a false "no cap" claim');
  assert.strictEqual(result.unknownUnits, 1, 'the unresolvable stage body must still be visible via unknownUnits');
});

test('round 5 finding 2: a resolved numeric cap (.map()) is never reported as uncapped merely because the callback body is itself unresolvable', () => {
  const script = `
const p1 = await agent('produce a list of claims', { schema: { maxItems: 5 } })
const results = await parallel(p1.map(checkOneDefinedElsewhere))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0, 'the maxItems:5 cap on "p1" resolves fine -- the ONLY unresolvable thing here is the callback body, which must route through unknownUnits only');
  assert.strictEqual(result.unknownUnits, 1);
});

test('round 5 finding 3: a native for-of loop wrapping an uncapped verifier fan-out is flagged, not reported fully compliant with zero signal', () => {
  const script = `
const claims = await agent('produce claims', { schema: { maxItems: 5 } })
for (const claim of claims.list) {
  await agent('verify this claim against the source: ' + claim)
}
`;
  const result = analyzeWorkflow(script);
  assert.ok(result.uncapped.length > 0 || result.unknownUnits > 0, 'a for-of loop wrapping a verifier agent() call has an unresolvable iteration count and must fail closed, not report zero signal');
});

test('round 5 finding 3: Promise.all(list.map(...)) is recognized as a data-driven fan-out, same as parallel(list.map(...))', () => {
  const script = `
const p1 = await agent('produce a list of claims', { schema: { maxItems: 5 } })
const votes = await Promise.all(p1.map(c => agent('verify this against the source: ' + c)))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0, 'Promise.all(p1.map(...)) must resolve the same maxItems:5 cap parallel(p1.map(...)) would');
  assert.strictEqual(result.verifiers, 5, 'the resolved cap must be credited to verifiers, not silently dropped because Promise.all was never recognized as a fan-out');
});

test('round 5 finding 4: a multi-line generic binding (`const claims = mergeClaims(\n  p1, p2\n)`) is still recognized as a derived binding, not truncated at the first embedded newline', () => {
  // Identical at runtime to round 2 finding 0's single-line fixture above --
  // only whitespace inside the mergeClaims(...) call differs. GENERIC_BIND_RE's
  // old `[^;\n]*` RHS capture stopped at the newline immediately after the
  // opening paren, capturing an EMPTY rhs ("mergeClaims(") that references
  // neither p1 nor p2 -- so "claims" never enters derivedBindings at all,
  // and all 5 literal verify() calls below silently flip from verifiers to
  // producers (no earlier-binding reference found).
  const script = `
const p1 = await agent('a', { model: 'sonnet' })
const p2 = await agent('b', { model: 'sonnet' })
const claims = mergeClaims(
  p1,
  p2
)
const verified = await parallel([
  agent('verify host1 vs ' + claims, { model: 'sonnet' }),
  agent('verify host2 vs ' + claims, { model: 'sonnet' }),
  agent('verify host3 vs ' + claims, { model: 'sonnet' }),
  agent('verify host4 vs ' + claims, { model: 'sonnet' }),
  agent('verify host5 vs ' + claims, { model: 'sonnet' }),
])
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 2);
  assert.strictEqual(result.verifiers, 5, 'a multi-line mergeClaims(...) binding must be recognized as derived just like its single-line form -- the fan-out is a genuine verifier fleet');
  assert.strictEqual(result.overRatio, true);
});

// ===========================================================================
// run() -- WARN mode (default, no opt-in): in-process, since GATE_BLOCK's
// value doesn't matter for these assertions.
// ===========================================================================

function workflowPayload(script, over = {}) {
  return JSON.stringify({
    tool_name: 'Workflow',
    tool_input: { script },
    session_id: 'sess-warn-0001',
    cwd: '/tmp/fanout-admission-test-warn',
    ...over,
  });
}

function papercutFile(store, cwd) {
  return path.join(store, `${projectSlug(cwd)}.jsonl`);
}

function withPapercutStore(fn) {
  const store = mkTmp('fanout-papercut-');
  const oldEnv = process.env.PAPERCUT_STORE;
  process.env.PAPERCUT_STORE = store;
  try {
    return fn(store);
  } finally {
    if (oldEnv === undefined) delete process.env.PAPERCUT_STORE; else process.env.PAPERCUT_STORE = oldEnv;
    rmTmp(store);
  }
}

test('run(): WARN mode allows the over-ratio Workflow script through unchanged, but logs a papercut record', () => {
  withPapercutStore((store) => {
    const cwd = '/tmp/fanout-admission-test-warn-a';
    const p = workflowPayload(OVER_RATIO_SCRIPT, { cwd });
    const out = run(p);
    assert.strictEqual(out, p, 'default mode must never deny -- allow means byte-identical pass-through');
    const file = papercutFile(store, cwd);
    const recs = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.strictEqual(recs.length, 1);
    assert.strictEqual(recs[0].sig, 'guard_blocked:fanout-admission:workflow');
    assert.match(recs[0].err, /8 verifier agent call\(s\) exceed 5 producer/);
  });
});

test('run(): WARN mode leaves a compliant 1:1 Workflow script untouched and logs nothing', () => {
  withPapercutStore((store) => {
    const cwd = '/tmp/fanout-admission-test-warn-b';
    const p = workflowPayload(COMPLIANT_SCRIPT, { cwd });
    const out = run(p);
    assert.strictEqual(out, p);
    assert.ok(!fs.existsSync(papercutFile(store, cwd)), 'a compliant script must not write a papercut record');
  });
});

// ===========================================================================
// run() -- blocking opt-in (CLAUDE_FANOUT_GATE_BLOCK=1): spawned, so the env
// var is set BEFORE the module loads in a fresh process.
// ===========================================================================

test('blocking opt-in: denies the over-ratio Workflow fixture, naming the counts', async () => {
  const p = { tool_name: 'Workflow', tool_input: { script: OVER_RATIO_SCRIPT }, session_id: 'sess-block-0001', cwd: '/tmp' };
  const res = await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } });
  assertPreToolUseDeny(res);
  const out = JSON.parse(res.stdout);
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /8 verifier agent call\(s\) exceed 5 producer/);
});

test('blocking opt-in: does NOT deny a compliant 1:1 Workflow fixture', async () => {
  const p = { tool_name: 'Workflow', tool_input: { script: COMPLIANT_SCRIPT }, session_id: 'sess-block-0002', cwd: '/tmp' };
  assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } }));
});

// ===========================================================================
// Round 2 finding 9 (adversarial review of PR #1294): CLAUDE.md's "hard-cap
// every data-driven fan-out" is a rule of its own, independent of the
// producer/verifier ratio. Before this fix, an UNCAPPED data-driven fan-out
// was excluded from the ratio (correctly -- its true spawn count is unknown,
// P1-C) but that exclusion also meant it could never deny under the blocking
// opt-in even when it was the ONLY problem in the script. Fixed: either
// condition (overRatio OR a non-empty uncapped list) now independently denies
// under CLAUDE_FANOUT_GATE_BLOCK=1, naming the offending span(s) in the
// reason text. WARN mode is unaffected -- still log-only.
// ===========================================================================

test('round 2 finding 9: an uncapped data-driven fan-out denies under the blocking opt-in even with no ratio violation', async () => {
  const script = `
const items = await agent('list items', { model: 'sonnet' })
const collected = await parallel(items.list.map(x => () => agent('collect ' + x, { model: 'sonnet' })))
`;
  const p = { tool_name: 'Workflow', tool_input: { script }, session_id: 'sess-r2-f9-block', cwd: '/tmp' };
  const res = await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } });
  assertPreToolUseDeny(res);
  const out = JSON.parse(res.stdout);
  assert.match(
    out.hookSpecificOutput.permissionDecisionReason,
    /1 data-driven fan-out\(s\) with no \.slice\(N\)\/maxItems cap \(source offset \d+-\d+\)/,
    'the deny reason must name the span, not just a bare count'
  );
});

test('round 2 finding 9: the same uncapped fan-out stays log-only (never denies) in default WARN mode', () => {
  withPapercutStore((store) => {
    const cwd = '/tmp/fanout-admission-test-r2-f9-warn';
    const script = `
const items = await agent('list items', { model: 'sonnet' })
const collected = await parallel(items.list.map(x => () => agent('collect ' + x, { model: 'sonnet' })))
`;
    const p = workflowPayload(script, { cwd, session_id: 'sess-r2-f9-warn' });
    const out = run(p);
    assert.strictEqual(out, p, 'WARN mode must never deny, even for an uncapped fan-out');
    const file = papercutFile(store, cwd);
    const recs = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.strictEqual(recs.length, 1);
    assert.match(recs[0].err, /data-driven fan-out\(s\) with no \.slice\(N\)\/maxItems cap/);
  });
});

test('blocking opt-in: a lean-reader Task spawn with no siblings passes silently in every mode', async () => {
  const p = {
    tool_name: 'Task',
    tool_input: { subagent_type: 'lean-reader', description: 'x', prompt: 'y' },
    session_id: 'sess-lean-reader-solo',
    cwd: '/tmp',
  };
  // Default (WARN) mode:
  assertQuietPassThrough(await runHook(HOOK, p));
  // Blocking opt-in armed -- must STILL pass through; decision 1 (#1284): the
  // Task path never denies, in any mode.
  assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } }));
});

// ===========================================================================
// P1-D regression (adversarial review of PR #1294, reproduced live against
// ce0af4f): a Workflow RESUME call carries tool_input {scriptPath,
// resumeFromRunId} and NO `script` string -- ce0af4f's run() only ever read
// `ti.script`, so it returned rawInput with zero analysis on every resume,
// silently disarming the whole hook for any resumed run. Fixed: when `script`
// is not a string and `scriptPath` is, read the file (resolved relative to
// cwd, capped, fails open on any read error) and analyze that text.
// ===========================================================================

test('P1-D: a Workflow RESUME call ({scriptPath, resumeFromRunId}, no script) is read from disk and denied under the blocking opt-in', async () => {
  const dir = mkTmp('fanout-p1d-');
  try {
    const scriptPath = path.join(dir, 'workflow-script.js');
    fs.writeFileSync(scriptPath, OVER_RATIO_SCRIPT);
    const p = {
      tool_name: 'Workflow',
      tool_input: { scriptPath, resumeFromRunId: 'run-123' },
      session_id: 'sess-p1d-resume-block',
      cwd: dir,
    };
    const res = await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } });
    assertPreToolUseDeny(res);
    const out = JSON.parse(res.stdout);
    assert.match(out.hookSpecificOutput.permissionDecisionReason, /8 verifier agent call\(s\) exceed 5 producer/);
  } finally {
    rmTmp(dir);
  }
});

test('P1-D: a Workflow RESUME call with a relative scriptPath resolves it against cwd', async () => {
  const dir = mkTmp('fanout-p1d-');
  try {
    fs.writeFileSync(path.join(dir, 'workflow-script.js'), OVER_RATIO_SCRIPT);
    const p = {
      tool_name: 'Workflow',
      tool_input: { scriptPath: 'workflow-script.js', resumeFromRunId: 'run-124' },
      session_id: 'sess-p1d-relative',
      cwd: dir,
    };
    const res = await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } });
    assertPreToolUseDeny(res);
  } finally {
    rmTmp(dir);
  }
});

test('P1-D: a Workflow RESUME call whose script file is missing fails OPEN (passes through unchanged, no crash)', async () => {
  const p = {
    tool_name: 'Workflow',
    tool_input: { scriptPath: '/nonexistent/does-not-exist-workflow-script.js', resumeFromRunId: 'run-125' },
    session_id: 'sess-p1d-missing',
    cwd: '/tmp',
  };
  assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_FANOUT_GATE_BLOCK: '1' } }));
});

// ===========================================================================
// Task path: spawn-threshold WARN (heuristic-only; never denies, any mode).
// ===========================================================================

function taskPayload(sid, cwd) {
  return { tool_name: 'Task', tool_input: { subagent_type: 'general-purpose', description: 'x', prompt: 'y' }, session_id: sid, cwd };
}

test('Task path: exceeding CLAUDE_FANOUT_TASK_THRESHOLD logs a WARN but still passes every spawn through, WARN mode', async () => {
  const home = mkTmp('fanout-home-');
  const store = mkTmp('fanout-papercut-task-warn-');
  try {
    const env = { HOME: home, USERPROFILE: home, PAPERCUT_STORE: store, CLAUDE_FANOUT_TASK_THRESHOLD: '2' };
    const cwd = '/tmp/fanout-admission-test-task-warn';
    const p = taskPayload('sess-task-warn', cwd);
    assertQuietPassThrough(await runHook(HOOK, p, { env })); // spawn 1
    assertQuietPassThrough(await runHook(HOOK, p, { env })); // spawn 2 -- at cap
    assertQuietPassThrough(await runHook(HOOK, p, { env })); // spawn 3 -- over cap, WARN only
    const file = papercutFile(store, cwd);
    const recs = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.strictEqual(recs.length, 1, 'only the spawn that crosses the threshold logs');
    assert.strictEqual(recs[0].sig, 'guard_blocked:fanout-admission:task');
    assert.match(recs[0].err, /exceeds CLAUDE_FANOUT_TASK_THRESHOLD=2/);
  } finally {
    rmTmp(home);
    rmTmp(store);
  }
});

test('Task path: exceeding the threshold under the blocking opt-in still never denies', async () => {
  const home = mkTmp('fanout-home-');
  try {
    const env = { HOME: home, USERPROFILE: home, CLAUDE_FANOUT_TASK_THRESHOLD: '1', CLAUDE_FANOUT_GATE_BLOCK: '1' };
    const p = taskPayload('sess-task-block', '/tmp/fanout-admission-test-task-block');
    assertQuietPassThrough(await runHook(HOOK, p, { env })); // spawn 1 -- at cap
    assertQuietPassThrough(await runHook(HOOK, p, { env })); // spawn 2 -- over cap, block armed, must STILL pass
    assertQuietPassThrough(await runHook(HOOK, p, { env })); // spawn 3 -- still never denies
  } finally {
    rmTmp(home);
  }
});

// ===========================================================================
// Round 2 finding 7 (adversarial review of PR #1294): updateState()'s own
// fs.mkdirSync(stateDir, {recursive: true}) was the one unguarded call left
// in the module -- on EACCES (e.g. an unwritable parent dir, state dir not
// yet created) it threw straight through analyzeTaskSpawn()/run(): exit 1,
// empty stdout, no decision, a hook crash rather than a fail-open pass-
// through. Reproduced against a scratch HOME whose <HOME>/.claude PARENT is
// chmod 0500 and .fanout-state does not exist yet (the existing unwritable-
// dir coverage elsewhere in this suite pre-creates the state dir before
// chmodding it, which never reaches this line).
// ===========================================================================

test('round 2 finding 7: the Task path survives (does not crash) when the state dir\'s PARENT is unwritable and the dir does not exist yet', async () => {
  const home = mkTmp('fanout-home-r2f7-');
  const claudeDir = path.join(home, '.claude');
  try {
    fs.mkdirSync(claudeDir, { recursive: true });
    fs.chmodSync(claudeDir, 0o500); // r-x: updateState's own mkdirSync(TASK_STATE_DIR) must fail here
    const env = { HOME: home, USERPROFILE: home };
    const p = taskPayload('sess-r2-f7-task', '/tmp/fanout-admission-test-r2-f7');
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
    assert.strictEqual(res.stderr.trim(), '', 'no uncaught exception should reach stderr');
    assertQuietPassThrough(res);
  } finally {
    fs.chmodSync(claudeDir, 0o700); // restore so cleanup can remove it
    rmTmp(home);
  }
});

// ===========================================================================
// P2 regression (adversarial review of PR #1294, reproduced live against
// ce0af4f): the Task path's read-modify-write across SEPARATE hook processes
// (one `node fanout-admission.js` per Task spawn, exactly how Claude Code
// invokes PreToolUse hooks) lost updates under real concurrency -- 20
// concurrent spawns against ce0af4f's plain loadState()+saveState() pair were
// measured at 10-17 of 20 recorded, not 20, across 3 repeated runs (method in
// ../lib/session-state.js's own doc comment -- round 2 review finding 2
// corrected three conflicting single-number citations of this same
// measurement to one measured range with the method stated). Fixed via
// ../lib/session-state.js's updateState(), a
// cross-process mkdir-based exclusive lock (P2). Spawns 20 REAL child
// processes (not 20 in-process calls, which would never exercise the race)
// against one shared session_id and HOME, then reads the persisted state file
// directly to assert every one of the 20 was recorded.
// ===========================================================================

test('P2: 20 concurrent Task spawns (separate processes, one session_id) are all recorded, none lost to the race', async () => {
  const home = mkTmp('fanout-home-p2-');
  try {
    const env = { HOME: home, USERPROFILE: home };
    const sid = 'sess-p2-concurrent';
    const p = taskPayload(sid, '/tmp/fanout-admission-test-p2');
    const N = 20;
    const results = await Promise.all(Array.from({ length: N }, () => runHook(HOOK, p, { env })));
    for (const res of results) assertQuietPassThrough(res);
    const stateFile = path.join(home, '.claude', '.fanout-state', `${sid}.json`);
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    assert.strictEqual(state.spawns.length, N, `expected all ${N} concurrent spawns recorded, got ${state.spawns.length}`);
  } finally {
    rmTmp(home);
  }
});

// ===========================================================================
// Round 9 (adversarial review of PR #1294, reproduced live against 3f46f37):
// three P1 findings the round 7/8 fixture set could not have caught --
// P1-A's shadow shape needs an UNRELATED FUNCTION BODY (round 7's own P1-A
// fixtures shadow at top level, never cross a function boundary); P1-B's
// timing shape needs REAL const bindings and NESTED calls (round 7 finding
// 2's own FLAT timing guard below has zero of either, so it structurally
// cannot reach isVerifierCall()'s scan at all); P1-C's shape needs the
// .map() array HOISTED into a named variable before being passed to
// parallel()/Promise.all() (every existing fixture in this file inlines
// .map( directly onto the fan-out call).
// ===========================================================================

test('round 9 P1-A: an unrelated same-named .slice() binding LEXICALLY SCOPED inside a different function body must not donate its cap by textual proximity', () => {
  const script = `
const capped = await agent('collect a HUGE, unbounded list of users')
function unrelatedHelper() { const capped = trustedSource.slice(0, 5); return capped; }
parallel(capped.list.map(u => agent('verify: ' + u)))
`;
  const result = analyzeWorkflow(script);
  // Against 3f46f37, resolveNamedCap()/nearestPrecedingDeclarationPos()
  // matched this NAME by nearest-preceding TEXT POSITION only, with no scope
  // check -- the helper function's own local `capped = trustedSource.slice(0,
  // 5)` (lexically invisible to the outer `capped.list.map(...)`, which sits
  // OUTSIDE unrelatedHelper's braces) was picked up as if it capped the
  // outer binding, producing {producers:1, verifiers:5, overRatio:true,
  // uncapped:[], unknownUnits:0} -- a fabricated resolved cap for what is
  // actually a genuinely unbounded fan-out (measured live against 3f46f37,
  // reproduced in this session). Fixed via declarationScopeEnds(): a
  // binding can only supply a cap to a reference within its own enclosing
  // brace block (a brace-nesting approximation of lexical scope, not a real
  // parser -- see that function's own doc comment for its fail-closed
  // behavior on unmatched braces).
  assert.strictEqual(result.uncapped.length, 1, 'the outer capped.list fan-out has no cap in its own lexical scope -- must be flagged uncapped, not resolved from an unrelated function-local binding');
  assert.strictEqual(result.unknownUnits, 1);
  assert.strictEqual(result.verifiers, 0, 'the unrelated helper-local slice(0, 5) must never be read as a cap on the outer fan-out');
  assert.strictEqual(result.overRatio, false, 'an unresolvable unit must not fabricate an over-ratio verdict');
});

test("round 9 P1-B: isVerifierCall()'s per-call scan scales near-linearly with REAL const bindings and NESTED calls -- the shape round 7 finding 2's own FLAT timing guard cannot reach", () => {
  // Round 7 finding 2's FLAT timing guard (below) has zero const bindings
  // and zero nested calls, so it never drives isVerifierCall()'s
  // allBindings.filter(...).some(...) scan at all -- that guard protects a
  // DIFFERENT set of paths (topLevelCoarseSpans, directAgentSpansWithin,
  // dataDrivenCapText). This fixture is the shape actually reproduced live
  // against 3f46f37: N const bindings (one per produce stage), each
  // immediately verified by a NESTED parallel([agent(...)]) call that
  // references it. Every verifier call's isVerifierCall() scan lands its
  // one true match at the END of the (ascending-position) earlier-bindings
  // array -- the worst case for a linear .some() -- making isVerifierCall a
  // fourth O(n^2) path with NO deadline check, invisible to this module's
  // own internal analysis budget in per-iteration terms (the budget only
  // checks callSpans()-style loop iteration counts, not per-call scan cost).
  // Measured live against 3f46f37: n=6000 took ~5.9s wall time -- past the
  // external PreToolUse hook's OWN 5000ms timeout in settings.json --
  // while the internal budget only caught it AFTER the fact (flagged:true,
  // producers:0, verifiers:0, i.e. the fail-closed verdict was computed
  // after the CLI would already have killed the process). Fixed via
  // referencesEarlierBinding(): tokenize the (short) reference text once and
  // look up each token in a precomputed Map<name, earliestPos> instead of
  // testing every earlier binding's name against the reference text.
  // The complete workflow used to also run directAgentSpansWithin()'s
  // fanoutSpans.some() containment scan per nested call, a second quadratic
  // term whose share was runner-dependent: 2x input cost ~3.1x CPU on a
  // quiet host and 3.569x on a GitHub runner (PR #1821 CI round 1, run
  // 38660315517), failing this guard's 3.5x bound with no code change. That
  // scan is now a per-call Map lookup (buildEnclosingFanoutIndex(), pinned
  // by the two tests below); 2x input measures ~2.1x CPU. The 3.5x bound is
  // unchanged (not a ceiling move either way) and still rejects the ~4x
  // signature of reintroducing either quadratic scan.
  assertPerfScaling({
    n: 3000,
    scale: 2,
    maxRatio: 3.5,
    sanityMs: 5000,
    label: 'analyzeWorkflow() const-bound produce/verify pairs',
    measure: (N) => {
      const lines = [];
      for (let i = 0; i < N; i += 1) {
        lines.push(`const p_${i} = await agent('produce ${i}')`);
        lines.push(`await parallel([agent('verify: ' + String(p_${i}))])`);
      }
      const script = lines.join('\n');
      const { result, elapsedMs } = measureCpu(() => analyzeWorkflow(script), {
        cpuClock: true,
      });
      assert.strictEqual(
        result.flagged,
        false,
        'an in-budget, well-formed script must not fail closed',
      );
      assert.strictEqual(
        result.producers,
        N,
        'every produce stage is its own producer',
      );
      assert.strictEqual(
        result.verifiers,
        N,
        `every nested parallel([agent('verify: ...')]) call referencing its own p_i must still be classified as a verifier`,
      );
      return elapsedMs;
    },
  });
});

// ===========================================================================
// PR #1821 CI round 1: the round 9 P1-B guard above failed CI (run
// 38660315517, "Harness suites (hooks + dispatch)") at ratio 3.569x against
// its 3.5x bound with no code change. The guard's own comment had allowed
// ~3.1x for directAgentSpansWithin()'s remaining `fanoutSpans.some()`
// containment scan per nested agent() call -- O(fan-outs x nested calls),
// N^2 on the P1-B shape -- a quadratic term whose CPU share depends on the
// runner (a quiet host measured 2.7-3.1x, the runner 3.569x). The two tests
// below pin the fix deterministically, with no timing: the first counts
// fanoutSpans reads and requires the per-call work to touch none, the
// second checks the Map-lookup rule against the exact `.some()` predicate
// it replaced on real nested call spans from callSpans().
// ===========================================================================

test('PR #1821 CI round 1: directAgentSpansWithin() must not rescan fanoutSpans per nested agent() call -- the quadratic term that pushed the round 9 P1-B guard past 3.5x on a GitHub runner', () => {
  // The P1-B shape as bare spans: F disjoint fan-outs, each wrapping exactly
  // one agent() call, so every call has k=1 candidate and the old `.some()`
  // read all F fan-out spans for it (no span other than the fan-out itself
  // ever matched, so it never short-circuited): F*F reads in total.
  const F = 2048;
  const fanoutSpans = [];
  const agentSpans = [];
  for (let i = 0; i < F; i += 1) {
    fanoutSpans.push([10 * i, 10 * i + 8]);
    agentSpans.push([10 * i + 2, 10 * i + 6]);
  }
  let reads = 0;
  const counted = new Proxy(fanoutSpans, {
    get(target, prop, receiver) {
      if (typeof prop === 'string' && /^\d+$/.test(prop)) reads += 1;
      return Reflect.get(target, prop, receiver);
    },
  });
  const enclosing = buildEnclosingFanoutIndex(agentSpans, counted);
  const buildReads = reads;
  assert.ok(
    buildReads <= 4 * F,
    `building the index must read fanoutSpans a bounded number of times per span, got ${buildReads} reads for ${F} spans`
  );
  for (const span of fanoutSpans) {
    const literals = directAgentSpansWithin(span, agentSpans, enclosing);
    assert.deepStrictEqual(literals, [[span[0] + 2, span[1] - 2]], `the one agent() call directly inside ${JSON.stringify(span)} must be returned`);
  }
  assert.strictEqual(
    reads - buildReads,
    0,
    `${F} directAgentSpansWithin() calls must not read fanoutSpans at all (the old per-candidate .some() read ${F} spans per call, ${F * F} in total)`
  );
});

test('PR #1821 CI round 1: the innermost-enclosing-fan-out rule agrees with the per-candidate fanoutSpans.some() predicate it replaced, on real nested spans', () => {
  // Every nesting the old predicate distinguished, as real text through
  // callSpans(): an agent directly in a fan-out, one two fan-outs deep, a
  // fan-out inside a function body (claimAgentDecls() queries declaration
  // spans, not just fan-out spans), siblings, and a top-level agent in no
  // fan-out at all. The whole-script span is queried too: against it every
  // agent inside any fan-out is "nested in a smaller fan-out".
  const script = [
    "await parallel([agent('a1'), parallel([agent('b1'), pipeline(xs, agent('c1'))]), agent('a2')])",
    "function helper() { return parallel([agent('d1')]) }",
    "function plain() { return agent('e1') }",
    "await Promise.all([agent('f1'), agent('f2')])",
    "await agent('top')",
  ].join('\n');
  const stripped = blankStrings(script);
  const agentSpans = callSpans(stripped, () => /\bagent\s*\(/g);
  const fanoutSpans = callSpans(stripped, () => /\b(?:parallel|pipeline|Promise\.all)\s*\(/g);
  assert.strictEqual(agentSpans.length, 9);
  assert.strictEqual(fanoutSpans.length, 5);
  const helperBody = [script.indexOf('{ return parallel'), script.indexOf("agent('d1')]) }") + "agent('d1')]) }".length];
  const plainBody = [script.indexOf("{ return agent('e1') }"), script.indexOf("{ return agent('e1') }") + "{ return agent('e1') }".length];
  const ranges = [...fanoutSpans, helperBody, plainBody, [0, script.length]];
  // The predicate directAgentSpansWithin() ran per candidate before this
  // round, verbatim.
  const reference = (rangeSpan) => {
    const out = [];
    for (const [s, e] of agentSpans) {
      if (s < rangeSpan[0] || s > rangeSpan[1] || e > rangeSpan[1]) continue;
      const nestedInSmallerFanout = fanoutSpans.some(
        ([fs, fe]) => !(fs === rangeSpan[0] && fe === rangeSpan[1]) && rangeSpan[0] <= fs && fe <= rangeSpan[1] && fs <= s && e <= fe
      );
      if (!nestedInSmallerFanout) out.push([s, e]);
    }
    return out;
  };
  const enclosing = buildEnclosingFanoutIndex(agentSpans, fanoutSpans);
  const text = ([s, e]) => script.slice(s, e);
  for (const rangeSpan of ranges) {
    assert.deepStrictEqual(
      directAgentSpansWithin(rangeSpan, agentSpans, enclosing).map(text),
      reference(rangeSpan).map(text),
      `directly-contained agent() calls of ${JSON.stringify(text(rangeSpan))}`
    );
  }
  // And the shape the fixture is built to exercise actually occurred: the
  // outer parallel keeps a1/a2 and loses b1 (one deeper) and c1 (two
  // deeper); the function body keeps nothing of its own; the plain body
  // keeps e1; the whole script keeps only the two calls in no fan-out.
  assert.deepStrictEqual(directAgentSpansWithin(fanoutSpans[0], agentSpans, enclosing).map(text), ["agent('a1')", "agent('a2')"]);
  assert.deepStrictEqual(directAgentSpansWithin(helperBody, agentSpans, enclosing), []);
  assert.deepStrictEqual(directAgentSpansWithin(plainBody, agentSpans, enclosing).map(text), ["agent('e1')"]);
  assert.deepStrictEqual(directAgentSpansWithin([0, script.length], agentSpans, enclosing).map(text), ["agent('e1')", "agent('top')"]);
});

test('round 9 P1-C: a .map() array HOISTED into a named intermediate variable before being passed to parallel() is still recognized as the SAME data-driven fan-out as the inline form', () => {
  const inline = `
const claims = await agent('gather claims', { maxItems: 40 })
const results = await parallel(claims.map(c => agent('verify: ' + c)))
`;
  const hoisted = `
const claims = await agent('gather claims', { maxItems: 40 })
const verifyPromises = claims.map(c => agent('verify: ' + c))
const results = await parallel(verifyPromises)
`;
  const inlineResult = analyzeWorkflow(inline);
  const hoistedResult = analyzeWorkflow(hoisted);
  // Against 3f46f37, hoisting the SAME .map() expression into a named
  // `verifyPromises` binding before passing it to parallel() made the
  // fan-out invisible: FANOUT_RE and every scanning path in this file only
  // ever looked for `.map(` INSIDE a parallel()/pipeline()/Promise.all()
  // call's own argument text, so `parallel(verifyPromises)` (a bare
  // identifier argument) fell through to the "no data-driven signal" path
  // entirely -- measured live against 3f46f37: {producers:2, verifiers:0,
  // overRatio:false, uncapped:[], unknownUnits:0}. Not merely miscounted,
  // but silently INVISIBLE -- the uncapped[]/unknownUnits fail-closed nets,
  // which exist to catch exactly this kind of unresolvable fan-out, both
  // stayed at zero too. "Hoisting an expression into a named intermediate
  // variable is ordinary, idiomatic JS." Fixed via resolveHoistedMapCap():
  // when a fan-out call's sole argument is a bare identifier, trace it back
  // to its own declaration (reusing the P1-A-fixed, scope-correct
  // nearestPrecedingDeclarationPos()) and, if that declaration's RHS is
  // itself `.map()`-shaped, resolve the cap from the RHS exactly as the
  // inline form would (one-hop only -- see this module's DISCLOSURE
  // paragraph for the documented limit on chained hoists).
  assert.deepStrictEqual(
    hoistedResult,
    inlineResult,
    'a .map() array hoisted into a named variable before being passed to parallel() must classify identically to the inline .map() form'
  );
  assert.strictEqual(hoistedResult.producers, 1);
  assert.strictEqual(hoistedResult.verifiers, 40, 'the maxItems:40 cap on the producing agent() call must resolve through the hoisted binding, exactly as it would inline');
  assert.strictEqual(hoistedResult.overRatio, true);
});

test('round 9 P1-C: the same hoisted-.map() shape is recognized through Promise.all(), not just parallel()', () => {
  const hoistedPromiseAll = `
const claims = await agent('gather claims', { maxItems: 40 })
const verifyPromises = claims.map(c => agent('verify: ' + c))
const results = await Promise.all(verifyPromises)
`;
  const result = analyzeWorkflow(hoistedPromiseAll);
  // Same invisibility bug as the parallel() case above, reached via the
  // Promise.all() call form instead.
  assert.strictEqual(result.producers, 1);
  assert.strictEqual(result.verifiers, 40);
  assert.strictEqual(result.overRatio, true);
  assert.strictEqual(result.uncapped.length, 0);
  assert.strictEqual(result.unknownUnits, 0);
});


// ===========================================================================
// Round 10 (adversarial review of PR #1294, reviewer-reproduced): findings 1-2.
// ===========================================================================

test('round 10 finding 1 (P1): an UNRESOLVABLE-cap bare-identifier .map() callback\'s own hoisted function declaration is still excluded from the top-level producer count -- not just the resolvable-cap case', () => {
  // Against 0e1c021: the exclusion push (`resolvedStageDefSpans.push(...)`)
  // that keeps a callback's own external declaration out of the final
  // bare-top-level agentSpans loop ran only on the path that fell through
  // PAST both of this branch's early `continue`s (unresolvable cap,
  // unresolvable stage body). A callback whose declaration lives outside
  // this fan-out's own span, but whose CAP is unresolvable (e.g. an
  // unsliced external array), took the `count == null` continue BEFORE
  // that push ever ran -- so its own agent() call fell through, uncovered,
  // to the final top-level loop and got counted a SECOND time as a
  // phantom producer. Reproduced live against 0e1c021: three such
  // untracked .map(checkOneN) fan-outs (each referencing a hoisted
  // `function checkOneN(c) { return agent(...) }`) plus one legitimately
  // capped seed producer/verifier pair yielded producers:4 (1 real seed
  // producer + 3 phantom checkOneN producers), overRatio:false -- even
  // though all three uncapped units correctly landed in
  // uncapped[]/unknownUnits (the fail-closed nets were never the problem;
  // the phantom ADDITION to producers was). Fixed by moving the exclusion
  // push before both early continues.
  const script = `
function checkOne1(c) { return agent('handle-1: ' + c) }
function checkOne2(c) { return agent('handle-2: ' + c) }
function checkOne3(c) { return agent('handle-3: ' + c) }
const seedGroup = await agent('collect seeds', { maxItems: 3 })
const seedVerified = await parallel(seedGroup.map(s => agent('verify: ' + s)))
const untracked1 = fetchExternal1()
await parallel(untracked1.map(checkOne1))
const untracked2 = fetchExternal2()
await parallel(untracked2.map(checkOne2))
const untracked3 = fetchExternal3()
await parallel(untracked3.map(checkOne3))
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 1, 'only the real seedGroup producer -- the three checkOneN function bodies must be excluded as external declarations, not double-counted as top-level producers (0e1c021 measured producers:4)');
  assert.strictEqual(result.verifiers, 3, 'the seedGroup.map() verifier fan-out must still be counted correctly');
  assert.strictEqual(result.overRatio, true, '3 verifiers > 1 producer (0e1c021 measured overRatio:false because the phantom producers masked the imbalance)');
  assert.strictEqual(result.uncapped.length, 3, 'the three untracked fan-outs must still fail closed into uncapped, unaffected by the fix');
  assert.strictEqual(result.unknownUnits, 3);

  // Control, in both directions: the SAME shape but with each external
  // array `.slice(0, 2)`-capped instead of unbounded must classify
  // IDENTICALLY before and after this fix -- proving the fix only touches
  // the double-counting defect, not resolvable-cap classification. Against
  // both 0e1c021 and the fix, this control measures producers:7 (1 seed +
  // 3 capped units, each capped unit's own checkOneCN producer correctly
  // counted once), overRatio:false.
  const control = `
function checkOneC1(c) { return agent('handle-c1: ' + c) }
function checkOneC2(c) { return agent('handle-c2: ' + c) }
function checkOneC3(c) { return agent('handle-c3: ' + c) }
const seedGroup = await agent('collect seeds', { maxItems: 3 })
const seedVerified = await parallel(seedGroup.map(s => agent('verify: ' + s)))
const cappedItems1 = fetchExternalC1()
await parallel(cappedItems1.slice(0, 2).map(checkOneC1))
const cappedItems2 = fetchExternalC2()
await parallel(cappedItems2.slice(0, 2).map(checkOneC2))
const cappedItems3 = fetchExternalC3()
await parallel(cappedItems3.slice(0, 2).map(checkOneC3))
`;
  const controlResult = analyzeWorkflow(control);
  assert.strictEqual(controlResult.producers, 7, 'a resolvable-cap variant of the same shape must be unaffected by this fix (0e1c021 and the fix both measure producers:7)');
  assert.strictEqual(controlResult.overRatio, false);
  assert.strictEqual(controlResult.uncapped.length, 0);
  assert.strictEqual(controlResult.unknownUnits, 0);
});

test('round 10 finding 1 (P1): the same fix applies to the HOISTED .map() shape (resolveHoistedMapCap), not just the inline .map() branch', () => {
  // Same defect, same fix, in the hoisted-.map() branch that round 9 added
  // (resolveHoistedMapCap()) -- the fan-out array is assigned to a named
  // intermediate variable before being passed to parallel(), instead of a
  // direct .map() call inside the fan-out call's own argument. Reproduced
  // live against 0e1c021 with the same numbers as the inline case above:
  // producers:4, overRatio:false.
  const script = `
function checkOneH1(c) { return agent('handle-h1: ' + c) }
function checkOneH2(c) { return agent('handle-h2: ' + c) }
function checkOneH3(c) { return agent('handle-h3: ' + c) }
const seedGroup = await agent('collect seeds', { maxItems: 3 })
const seedVerified = await parallel(seedGroup.map(s => agent('verify: ' + s)))
const untrackedH1 = fetchExternalH1()
const hoistedH1 = untrackedH1.map(checkOneH1)
await parallel(hoistedH1)
const untrackedH2 = fetchExternalH2()
const hoistedH2 = untrackedH2.map(checkOneH2)
await parallel(hoistedH2)
const untrackedH3 = fetchExternalH3()
const hoistedH3 = untrackedH3.map(checkOneH3)
await parallel(hoistedH3)
`;
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.producers, 1, '0e1c021 measured producers:4 (3 phantom checkOneHN producers from the hoisted-.map() branch\'s own version of the same ordering bug)');
  assert.strictEqual(result.verifiers, 3);
  assert.strictEqual(result.overRatio, true);
  assert.strictEqual(result.uncapped.length, 3);
  assert.strictEqual(result.unknownUnits, 3);

  // Control: same capped-array variant, hoisted form.
  const control = `
function checkOneHC1(c) { return agent('handle-hc1: ' + c) }
function checkOneHC2(c) { return agent('handle-hc2: ' + c) }
function checkOneHC3(c) { return agent('handle-hc3: ' + c) }
const seedGroup = await agent('collect seeds', { maxItems: 3 })
const seedVerified = await parallel(seedGroup.map(s => agent('verify: ' + s)))
const cappedH1 = fetchExternalHC1()
const hoistedHC1 = cappedH1.slice(0, 2).map(checkOneHC1)
await parallel(hoistedHC1)
const cappedH2 = fetchExternalHC2()
const hoistedHC2 = cappedH2.slice(0, 2).map(checkOneHC2)
await parallel(hoistedHC2)
const cappedH3 = fetchExternalHC3()
const hoistedHC3 = cappedH3.slice(0, 2).map(checkOneHC3)
await parallel(hoistedHC3)
`;
  const controlResult = analyzeWorkflow(control);
  assert.strictEqual(controlResult.producers, 7, 'identical before and after this fix (0e1c021 and the fix both measure producers:7)');
  assert.strictEqual(controlResult.overRatio, false);
  assert.strictEqual(controlResult.uncapped.length, 0);
  assert.strictEqual(controlResult.unknownUnits, 0);
});

test("round 10 finding 2 (P2): nearestPrecedingDeclarationPos() self-interrupts on its OWN deadline check -- the outer per-span loop's coarse (idx & 0xfff)===0 checkpoint cannot catch an over-budget run when the fan-out unit count stays under 4096", () => {
  // Round 9 fixed the exactly analogous O(n^2) risk in isVerifierCall() by
  // giving IT a periodic deadline check. nearestPrecedingDeclarationPos()
  // -- called per-span by resolveNamedCap(), resolveHoistedMapCap(),
  // scopedMapCap(), and resolvePipelineItemsCap() -- never got one. The
  // main per-span loop's own deadline check only fires every 4096
  // iterations (`(idx & 0xfff) === 0`), so for any script with FEWER than
  // 4096 fan-out units (overwhelmingly the common case), that checkpoint
  // fires exactly once, at idx===0, before any unit is processed, and
  // never again. With a large enough `allDeclarations` array, the
  // per-unit cost of resolving each unit's cap by tracing back to its own
  // declaration (an O(D) scan, D = declaration count) accumulates across
  // every unit with nothing to interrupt it until the entire per-span loop
  // finishes.
  //
  // Reproduced live against 0e1c021 at this module's own DEFAULT 3000ms
  // budget (no override): a script with 350,000 plain declarations and
  // 4,000 fan-out units (each `.slice(0, 2)`-capped on the unit's OWN
  // receiver declaration, so every cap is fully resolvable -- this is not
  // an uncapped-fanout artifact) took 6733-7190ms across repeated runs --
  // not just past this module's own 3000ms internal budget, but past
  // settings.json's 5000ms EXTERNAL PreToolUse hook timeout too (a
  // timed-out hook does not block the gated tool call, per this module's
  // own doc comment -- so at that scale this was a real, if narrow,
  // admission-bypass window, not merely a slow analysis; this exceeds even
  // the reviewer's own reported 3005-3338ms/never-near-5000ms window,
  // because that reproduction interleaved declarations 1:1 with fan-out
  // units instead of isolating the < 4096-units case).
  //
  // This test uses a smaller, `budgetMs`-overridden fixture (200,000
  // declarations / 3,500 units / 500ms budget) to keep CI fast and
  // deterministic while preserving the identical defect shape: both
  // before and after the fix, analyzeWorkflow() ultimately returns the
  // SAME fail-closed shape (flagged:true, uncapped/unknownUnits both set
  // to this module's fixed budget-exceeded fallback) -- the observable
  // difference is ONLY how long it takes to get there. Measured against
  // 0e1c021 with the original long dummy names: 3166-3711ms. Fixed
  // with the same periodic-check discipline referencesEarlierBinding()
  // got.
  const D = 200000;
  const budgetMs = 500;
  // Keep BOTH sizes below 4096: 3500 -> 7000 would let the outer checkpoint
  // interrupt at 4096 and mask a missing inner check. With D fixed, the old
  // O(D * U) scan's 3166-3711ms at 3500 predicts roughly half that at 1750;
  // its ~2x growth fails <1.5x even when both samples fit the 5000ms sanity
  // bound. The inner periodic check instead stops BOTH near budgetMs=500.
  // Compact, repeated var declarations still make allDeclarations contain
  // D entries (each cap scans every entry), while avoiding long dummy names
  // spending the entire 500ms budget in lexing before cap resolution starts.
  assertPerfScaling({
    n: 1750,
    scale: 2,
    maxRatio: 1.5,
    sanityMs: 5000,
    label: 'analyzeWorkflow() 500 CPU ms budget over 200000 declarations',
    measure: (U) => {
      const lines = ['var h=0\n'.repeat(D)];
      for (let i = 0; i < U; i += 1) {
        lines.push(`const items_${i} = fetchThings_${i}().slice(0, 2)`);
        lines.push(
          `await parallel(items_${i}.map(x => agent('verify: ' + x)))`,
        );
      }
      const script = lines.join('\n');
      const { result, elapsedMs } = measureCpu(
        () => analyzeWorkflow(script, { budgetMs }),
        { cpuClock: true },
      );
      assert.strictEqual(
        result.flagged,
        true,
        'a budget-exceeded analysis must self-report as flagged, not silently return a clean-looking result',
      );
      assert.ok(
        result.uncapped.length > 0 || result.unknownUnits > 0,
        'a budget-exceeded analysis must land in uncapped/unknownUnits so run() treats it as fail-closed',
      );
      return elapsedMs;
    },
  });
});

// ===========================================================================
// uncappedFanouts() direct tests (issue #1351 third adversarial pass):
// wf-pin-lex.js's shim calls this EXPORTED function directly, not through
// analyzeWorkflow()'s wrapper -- it never had a deadline parameter at all
// before this round, so every deadline check in the chain below it always
// saw `undefined` and never fired, however large the input.
// ===========================================================================

test('uncappedFanouts(): a capped unit is not flagged', () => {
  const stripped = blankStrings("parallel(items.slice(0, 8).map(x => agent(x)))\n");
  assert.deepStrictEqual(uncappedFanouts(stripped), []);
});

test('uncappedFanouts(): an uncapped unit is flagged', () => {
  const stripped = blankStrings("parallel(items.map(x => agent(x)))\n");
  const flagged = uncappedFanouts(stripped);
  assert.strictEqual(flagged.length, 1);
  assert.strictEqual(stripped.slice(flagged[0][0], flagged[0][1]), stripped.trimEnd());
});

test('uncappedFanouts(): an unresolvable (call-expression) receiver is flagged', () => {
  // P2-B (round 9): a call-expression receiver breaks MAP_RECEIVER_RE's
  // bare-identifier-chain requirement, so scopedMapCap() cannot resolve a
  // cap even though `.slice(20)` is chained right there -- this asserts the
  // shared hook's CURRENT documented WARN, not a fix to receiver resolution.
  const stripped = blankStrings('parallel(getItems().slice(0, 20).map(x => agent(x)))\n');
  const flagged = uncappedFanouts(stripped);
  assert.strictEqual(flagged.length, 1);
});

test('uncappedFanouts(): a deadline already in the past throws AnalysisBudgetExceeded', () => {
  // callSpans() checks its deadline at i===0 unconditionally (so an
  // already-past deadline is caught even on a short input, no large
  // fixture needed) -- this is the exact signal analyzeWorkflow() catches
  // and turns into a fail-closed result; wf-pin-lex.js's lexOne() catches
  // the same instanceof check to produce a per-script {"error": ...} entry
  // instead of crashing the whole batch.
  const stripped = blankStrings("parallel(items.map(x => agent(x)))\n");
  assert.throws(() => uncappedFanouts(stripped, Date.now() - 1), AnalysisBudgetExceeded);
});

test('uncappedFanouts(): omitted deadline is unaffected (existing in-process callers keep running unbounded)', () => {
  const stripped = blankStrings("parallel(items.map(x => agent(x)))\n");
  assert.doesNotThrow(() => uncappedFanouts(stripped));
  assert.strictEqual(uncappedFanouts(stripped).length, 1);
});

// ===========================================================================
// Hook-seam test: the registration itself, in settings.json.
// ===========================================================================

// The registration is retired (sync.sh reconcile_fanout_admission_hook removes
// it from live settings); the file stays because wf-pin-lex.js loads its lexer.
test('hook-seam: settings.json no longer registers fanout-admission.js', () => {
  const settingsPath = path.resolve(__dirname, '..', '..', 'settings.json');
  const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  const registered = Object.values(settings.hooks || {}).flat().some((g) =>
    (g.hooks || []).some((h) => /fanout-admission\.js/.test(h.command || '')));
  assert.strictEqual(registered, false, 'fanout-admission.js is retired as a hook; do not re-register it');
});

// ===========================================================================
// pro-gate FIX-FIRST review of PR #1294 (pg-run marker 1790067922-2326296),
// reproduced live against 0907f93 before this fix. Three admission bypasses,
// each with a control that already passed at that revision so the assertion
// is specific to the gap and not to the harness.
// ===========================================================================

test('slice semantics: a one-argument slice is not a cap, in all three resolvers', () => {
  // slice(0) keeps the whole array and slice(1) keeps everything but the
  // first element. Both are unbounded. Only an explicit end index bounds.
  const producer = "const claims = await agent('list claims', { schema: { type: 'object', properties: { claims: { type: 'array', maxItems: 8 } } } })";
  const cases = [
    ['inline slice(0)', producer + "\nawait Promise.all(claims.slice(0).map(c => agent('verify: ' + c)))"],
    ['inline slice(1)', producer + "\nawait Promise.all(claims.slice(1).map(c => agent('verify: ' + c)))"],
    ['named slice(0)', producer + "\nconst rest = claims.slice(0)\nawait Promise.all(rest.map(c => agent('verify: ' + c)))"],
    ['pipeline slice(0)', producer + "\nawait pipeline(claims.slice(0), c => agent('verify: ' + c))"],
  ];
  for (const [label, script] of cases) {
    const result = analyzeWorkflow(script);
    assert.ok(result.uncapped.length > 0, label + ': a one-argument slice must be reported uncapped, not silently admitted');
    assert.strictEqual(result.verifiers, 0, label + ': an unbounded slice must not contribute a verifier count');
  }
});

test('slice semantics: an explicit end index still bounds, in all three resolvers', () => {
  const producer = "const claims = await agent('list claims', { schema: { type: 'object', properties: { claims: { type: 'array', maxItems: 40 } } } })";
  // Spans deliberately vary, and none of them is 1. An earlier version of
  // this test used slice(0, 1) everywhere, so an implementation that simply
  // returned a hardcoded 1 passed it -- the assertion pinned nothing about
  // the end-minus-start arithmetic it claims to check.
  const spans = [
    { from: 0, to: 1, expect: 1 },
    { from: 0, to: 5, expect: 5 },
    { from: 2, to: 5, expect: 3 },
    { from: 3, to: 12, expect: 9 },
  ];
  for (const { from, to, expect } of spans) {
    const label = 'slice(' + from + ', ' + to + ')';
    const args = '(' + from + ', ' + to + ')';
    const cases = [
      ['inline', producer + "\nawait Promise.all(claims.slice" + args + ".map(c => agent('verify: ' + c)))"],
      ['named', producer + "\nconst rest = claims.slice" + args + "\nawait Promise.all(rest.map(c => agent('verify: ' + c)))"],
      ['pipeline', producer + "\nawait pipeline(claims.slice" + args + ", c => agent('verify: ' + c))"],
    ];
    for (const [resolver, script] of cases) {
      const result = analyzeWorkflow(script);
      assert.strictEqual(result.uncapped.length, 0, resolver + ' ' + label + ' must resolve a cap');
      assert.strictEqual(result.verifiers, expect, resolver + ' ' + label + ' retains end - start = ' + expect + ' elements');
    }
  }
});

test('schema path: a capped sibling field must not cap the array actually mapped', () => {
  const script = [
    "const report = await agent('list', { schema: { type: 'object', properties: { tags: { type: 'array', maxItems: 1 }, claims: { type: 'array' } } } })",
    "await Promise.all(report.claims.map(c => agent('verify: ' + c)))",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.ok(result.uncapped.length > 0, 'the mapped field has no maxItems of its own, so the fan-out is uncapped');
  assert.strictEqual(result.verifiers, 0, 'the sibling field cap of 1 must not become this fan-out verifier count');
});

test('schema path: the mapped field own maxItems still resolves, including through a property path', () => {
  const script = [
    "const report = await agent('list', { schema: { type: 'object', properties: { tags: { type: 'array' }, claims: { type: 'array', maxItems: 4 } } } })",
    "await Promise.all(report.claims.map(c => agent('verify: ' + c)))",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0);
  assert.strictEqual(result.verifiers, 4, 'the cap comes from the mapped field, not from the first maxItems in the schema');
});

test('per-call accounting: each agent call inside a map callback is counted, times the item cap', () => {
  const producer = "const claims = await agent('list claims', { schema: { type: 'object', properties: { claims: { type: 'array', maxItems: 8 } } } })";
  const two = analyzeWorkflow(producer + "\nawait Promise.all(claims.slice(0, 1).map(async c => { await agent('verify: ' + c); return agent('refute: ' + c); }))");
  assert.strictEqual(two.verifiers, 2, 'two verifier calls per item, one item, is two verifiers');
  assert.strictEqual(two.uncapped.length, 0);

  const mixed = analyzeWorkflow(producer + "\nawait Promise.all(claims.slice(0, 3).map(async c => { await agent('verify: ' + c); return agent('summarize: ' + c); }))");
  assert.strictEqual(mixed.verifiers, 3, 'the verify call is a verifier, counted per item');
  assert.strictEqual(mixed.producers, 1 + 3, 'the producing agent() plus one summarize call per item');

  const none = analyzeWorkflow(producer + "\nawait Promise.all(claims.slice(0, 1).map(async c => c.length))");
  assert.strictEqual(none.verifiers, 0, 'a callback with no agent() call launches nothing');
  assert.strictEqual(none.producers, 1, 'only the producing agent() call remains');
});

test('per-call accounting: a hoisted map counts each call in its callback the same way', () => {
  const script = [
    "const claims = await agent('list claims', { schema: { type: 'object', properties: { claims: { type: 'array', maxItems: 8 } } } })",
    "const work = claims.slice(0, 1).map(async c => { await agent('verify: ' + c); return agent('refute: ' + c); })",
    "await Promise.all(work)",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.verifiers, 2, 'hoisting the map must not change the count');
  assert.strictEqual(result.uncapped.length, 0);
});


// ===========================================================================
// Adversarial review of the fix above (refute-by-default lenses, verified by
// independent repro). Three defects the first cut INTRODUCED, plus one the
// depth check got wrong. Each test below was confirmed to fail against that
// first cut before the fix landed.
// ===========================================================================

test('a maxItems written in PROMPT PROSE is not a cap', () => {
  // The schema walk reads raw text so it can see keys inside object literals.
  // The bare-option scan has no structure to anchor on, so on raw text this
  // prompt string silently supplied a cap of 1 and cleared the uncapped flag.
  const script = [
    "const items = await agent('produce an unbounded list, note maxItems: 1 is flavor text', { model: 'sonnet' })",
    "await parallel(items.map(x => () => agent('verify ' + x)))",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.ok(result.uncapped.length > 0, 'prose mentioning maxItems must not cap the fan-out');
  assert.strictEqual(result.verifiers, 0);

  // Control: the same option written as real code still resolves.
  const real = [
    "const claims = await agent('gather claims', { maxItems: 40 })",
    "await parallel(claims.map(c => agent('verify: ' + c)))",
  ].join('\n');
  const realResult = analyzeWorkflow(real);
  assert.strictEqual(realResult.uncapped.length, 0, 'a real bare maxItems option still caps');
  assert.strictEqual(realResult.verifiers, 40);
});

test('per-call accounting counts only calls inside the map callback', () => {
  // The callback span used to fall back to the WHOLE fan-out call, so an
  // unrelated sibling call in the same parallel([...]) was multiplied by this
  // map's item cap.
  const script = [
    // Array-root schema, because the fan-out maps the bound value ITSELF.
    // An object-root schema here would correctly resolve no cap: the object
    // is not the array, so its field's maxItems says nothing about it.
    "const claims = await agent('list claims', { schema: { type: 'array', maxItems: 5, items: { type: 'string' } } })",
    "await parallel([claims.map(c => agent('verify: ' + c)), agent('write final summary')])",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.verifiers, 5, 'the mapped verifier call scales by the item cap');
  // True spawns: 'list claims' once, 'write final summary' once -> 2
  // producers. This asserted 1 until the pro-gate review of cbb61dc7, which
  // held only because the summary call was DROPPED (counted zero times, not
  // once): scoping to the callback left calls outside it in no counter. 1 is
  // that drop, 6 is the older scale-by-cap bug, 2 is correct.
  assert.strictEqual(result.producers, 2, 'the sibling summary call is counted exactly once');
});

test('a nested child maxItems appearing first does not mask the mapped field own cap', () => {
  // The depth check tested only the FIRST regex match, so a nested child cap
  // occurring earlier in the text made a genuinely capped fan-out read as
  // uncapped.
  const script = [
    "const report = await agent('list', { schema: { type: 'object', properties: { claims: { type: 'array', items: { type: 'object', properties: { sub: { type: 'array', maxItems: 99 } } }, maxItems: 7 } } } })",
    "await Promise.all(report.claims.map(c => agent('verify: ' + c)))",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 0, 'the field own cap must resolve despite an earlier nested cap');
  assert.strictEqual(result.verifiers, 7, 'the cap is the mapped field own 7, never the nested 99');
});

test('a cap that belongs only to a nested child is still not borrowed', () => {
  // The companion direction of the test above: when the mapped field has NO
  // cap of its own, a nested child's cap must not be adopted.
  const script = [
    "const report = await agent('list', { schema: { type: 'object', properties: { claims: { type: 'array', items: { type: 'object', properties: { sub: { type: 'array', maxItems: 99 } } } } } } })",
    "await Promise.all(report.claims.map(c => agent('verify: ' + c)))",
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.ok(result.uncapped.length > 0, 'a child cap must not stand in for the mapped field');
  assert.strictEqual(result.verifiers, 0);
});

// ---------------------------------------------------------------------------
// pro-gate FIX-FIRST review of PR #1294 at cbb61dc7 (pg-run marker
// 1790102252-2278026): three P1s and a P2. Three share one defect: every
// schema lookup was "the first textual match at or after an offset" over raw
// text -- a descendant search, on a view where prose reads as code. Cap
// resolution now reads each object's IMMEDIATE members on a lexed view with
// string, template, comment, and regex literal contents blanked. Every case
// here is RED against cbb61dc7 unless its comment says it guards the lexer.
// ---------------------------------------------------------------------------

// A producer binding `claims` via `call`, then one verifier per item of
// `receiver`.
function mapOver(call, receiver = 'claims') {
  return analyzeWorkflow([
    `const claims = await ${call}`,
    `await Promise.all(${receiver}.map(c => agent('verify: ' + c)))`,
  ].join('\n'));
}

test('a maxItems phrase inside a schema description string is not a cap', () => {
  const result = mapOver("agent('produce claims', { schema: { type: 'array', description: 'maxItems: 1', items: { type: 'string' } } })");
  assert.ok(result.uncapped.length > 0, 'description TEXT imposes no length limit');
  assert.strictEqual(result.verifiers, 0);
});

test('a schema phrase inside the PROMPT is not the schema', () => {
  const result = mapOver(`agent('Return JSON matching schema: { type: "array", maxItems: 1 }')`);
  assert.ok(result.uncapped.length > 0, 'only the options object can carry the schema');
  assert.strictEqual(result.verifiers, 0);
});

test('a same-named field nested in a sibling never supplies the mapped field cap, in either order', () => {
  const nestedFirst = mapOver(
    "agent('produce', { schema: { type: 'object', properties: { metadata: { type: 'object', properties: { claims: { type: 'array', maxItems: 1 } } }, claims: { type: 'array' } } } })",
    'claims.claims'
  );
  const nestedLast = mapOver(
    "agent('produce', { schema: { type: 'object', properties: { claims: { type: 'array' }, metadata: { type: 'object', properties: { claims: { type: 'array', maxItems: 1 } } } } } })",
    'claims.claims'
  );
  assert.ok(nestedFirst.uncapped.length > 0, 'metadata.claims is not claims, nested first');
  assert.ok(nestedLast.uncapped.length > 0, 'metadata.claims is not claims, nested last');
  const ownCap = mapOver(
    "agent('produce', { schema: { type: 'object', properties: { metadata: { type: 'object', properties: { claims: { type: 'array', maxItems: 1 } } }, claims: { type: 'array', maxItems: 3 } } } })",
    'claims.claims'
  );
  assert.strictEqual(ownCap.uncapped.length, 0);
  assert.strictEqual(ownCap.verifiers, 3, 'the field own 3, never the nested 1');
});

test('a literal call beside a mapped callback in one fan-out is counted once', () => {
  const result = analyzeWorkflow([
    "const claims = await agent('produce claims', { schema: { type: 'array', maxItems: 1, items: { type: 'string' } } })",
    "await Promise.all([...claims.slice(0, 1).map(c => agent('verify: ' + c)), agent('refute: ' + claims)])",
  ].join('\n'));
  assert.strictEqual(result.producers, 1);
  assert.strictEqual(result.verifiers, 2, 'the mapped verify once per item, plus the refute call once');
});

test('a call inside a second sibling map is an unknown unit, not dropped and not counted once', () => {
  // True verifiers: 4 + 20. This pass resolves only the first map's cap (the
  // one-receiver limit disclosed in the module doc); what this pins is that
  // the second map is no longer invisible, and is not passed off as one call.
  const result = analyzeWorkflow([
    "const claims = await agent('list claims', { schema: { type: 'array', maxItems: 4, items: { type: 'string' } } })",
    "const extra = await agent('list extra', { schema: { type: 'array', maxItems: 20, items: { type: 'string' } } })",
    "await parallel([claims.map(c => agent('verify: ' + c)), extra.map(e => agent('verify: ' + e))])",
  ].join('\n'));
  assert.strictEqual(result.unknownUnits, 1, 'the second map is reported, not silently dropped');
  assert.strictEqual(result.producers, 2, 'the two list calls only: the second map is not counted as one literal call');
  assert.ok(result.verifiers >= 4);
});

test('a bounded array whose items are objects keeps its cap', () => {
  const plain = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1, items: { type: 'object' } } })");
  const withProps = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1, items: { type: 'object', properties: { a: { type: 'string' } } } } })");
  for (const [label, result] of [['plain object items', plain], ['object items with properties', withProps]]) {
    assert.strictEqual(result.uncapped.length, 0, `${label}: items describes the elements, not the root`);
    assert.strictEqual(result.verifiers, 1, label);
  }
});

test('maxItems on a node whose own type is not array is not a cap', () => {
  // maxItems is an array-only assertion: a no-op on an object or a string.
  const objectType = mapOver("agent('produce', { schema: { type: 'object', maxItems: 1 } })");
  const stringType = mapOver("agent('produce', { schema: { type: 'string', maxItems: 5 } })");
  assert.ok(objectType.uncapped.length > 0, "type 'object', no properties");
  assert.ok(stringType.uncapped.length > 0, "type 'string'");
});

test('a node that declares its own properties is not read as the mapped array', () => {
  // Guards the new member reader (not RED against cbb61dc7, which had the
  // same rule): no `type` at all, so only the `properties` rule can decide --
  // a node that describes object fields is not taken to be the array its
  // maxItems bounds. Without this, dropping that rule went undetected.
  const result = mapOver("agent('produce', { schema: { maxItems: 1, properties: { a: { type: 'string' } } } })");
  assert.ok(result.uncapped.length > 0);
});

test('an object literal in the prompt argument is not the options object', () => {
  // The old walk searched the whole call for `schema: {`, so a schema-shaped
  // object passed to a PROMPT builder was taken as the agent's own schema.
  const result = mapOver("agent(buildPrompt({ schema: { type: 'array', maxItems: 1 } }), { label: 'produce' })");
  assert.ok(result.uncapped.length > 0, 'the options object is the second argument, and it has no schema');
});

test('a later duplicate maxItems overrides an earlier one, as in JavaScript', () => {
  const result = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1, maxItems: 30, items: { type: 'string' } } })");
  assert.strictEqual(result.verifiers, 30, 'the object literal evaluates to the LAST value');
});

test('a spread or computed key that could override maxItems makes the schema unreadable', () => {
  const spread = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1, ...OVERRIDE } })");
  const computed = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1, ['maxItems']: 500 } })");
  assert.ok(spread.uncapped.length > 0, 'a spread after maxItems may replace it');
  assert.ok(computed.uncapped.length > 0, 'a computed key may be maxItems');
});

test('a schema or maxItems value that is not exactly one literal is not a cap', () => {
  const guarded = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1 } && BIG_SCHEMA })");
  const arithmetic = mapOver("agent('produce', { schema: { type: 'array', maxItems: 1 + n, items: { type: 'string' } } })");
  assert.ok(guarded.uncapped.length > 0, '`{...} && BIG_SCHEMA` evaluates to BIG_SCHEMA');
  assert.ok(arithmetic.uncapped.length > 0, '`1 + n` is not the literal 1');
});

test('maxItems inside a comment is not a cap', () => {
  const block = mapOver("agent('produce', { schema: { type: 'array', /* maxItems: 1 */ items: { type: 'string' } } })");
  // An apostrophe in a line comment must not open a string that exposes the
  // description's text as code.
  const apostrophe = mapOver("agent('produce', {\n  // don't cap here\n  schema: { type: 'array', description: 'x, maxItems: 1', items: { type: 'string' } } })");
  assert.ok(block.uncapped.length > 0, 'block comment');
  assert.ok(apostrophe.uncapped.length > 0, 'line comment holding an apostrophe');
});

test('quoted JSON-style keys resolve like bare ones', () => {
  // Also RED against 0907f93e: neither the parent nor cbb61dc7 could read a
  // quoted "maxItems" key, so a correctly capped schema read as uncapped.
  const result = mapOver(`agent('produce', { "schema": { "type": "array", "maxItems": 3, "items": { "type": "string" } } })`);
  assert.strictEqual(result.uncapped.length, 0);
  assert.strictEqual(result.verifiers, 3);
});

test('a regex or nested template in the prompt does not derail the options read', () => {
  // Guards the new lexer (not RED against cbb61dc7, which searched raw text
  // for `schema: {` and so never split arguments at all): an unbalanced brace
  // inside a regex literal or a template interpolation must not shift where
  // the options argument starts.
  const regex = mapOver("agent(text.split(/{/)[0], { schema: { type: 'array', maxItems: 2, items: { type: 'string' } } })");
  const template = mapOver("agent(`n=${ {x: '}'}.x } and ${`inner ${1}`}`, { schema: { type: 'array', maxItems: 3, items: { type: 'string' } } })");
  assert.strictEqual(regex.verifiers, 2, 'regex literal holding `{`');
  assert.strictEqual(template.verifiers, 3, 'template interpolation holding a quoted `}` and a nested template');
});

// Found while testing the fixes above, and pre-existing since this hook's
// first commit (identical at 0907f93e): the whole-script blanked view was a
// quote-matching regex with no notion of comments, so ONE apostrophe in a
// `//` comment flipped quote parity for the rest of the script. The first
// agent() span then swallowed every fan-out after it and the gate saw none.
// Over 3,339 real workflow scripts on this host, 8 were partly blind this way.

test('an apostrophe in a line comment does not hide the fan-outs after it', () => {
  const result = analyzeWorkflow([
    '// don\'t forget: this list is unbounded',
    "const claims = await agent('produce claims')",
    "await Promise.all(claims.map(c => agent('verify: ' + c)))",
  ].join('\n'));
  assert.strictEqual(result.uncapped.length, 1, 'the uncapped fan-out must still be seen');
  assert.strictEqual(result.producers, 1);
});

test('agent( in comment prose is not an agent call', () => {
  // Reduced from a real script: "members get 1 agent (2 batches of 5/4)".
  const result = analyzeWorkflow([
    '// members get 1 agent (2 batches of 5/4)',
    "await agent('the only real call')",
  ].join('\n'));
  assert.strictEqual(result.producers, 1, 'the comment is prose, not a second producer');
});

// ---------------------------------------------------------------------------
// Adversarial review of 6a702d11 (the fix above): two P1s it introduced, both
// reproduced, plus the pre-existing class the first one sat in. Every case is
// RED against 6a702d11 unless its comment says it guards.
// ---------------------------------------------------------------------------

const LIST_4 = "const claims = await agent('list claims', { schema: { type: 'array', maxItems: 4, items: { type: 'string' } } })";
const LIST_20 = "const extra = await agent('list extra', { schema: { type: 'array', maxItems: 20, items: { type: 'string' } } })";

test('a flatMap or forEach sibling of a mapped callback is an unknown unit, not one call', () => {
  // True verifiers: 4 + 2 x 20. 6a702d11 counted the two flatMap calls as two
  // one-shot producers (producers 4, verifiers 4), which flipped overRatio to
  // false on a script that is over ratio at any cap.
  const flatMap = analyzeWorkflow([
    LIST_4,
    LIST_20,
    "await Promise.all([...claims.map(c => agent('verify: ' + c)), ...extra.flatMap(e => [agent('checkA: ' + e), agent('checkB: ' + e)])])",
  ].join('\n'));
  assert.strictEqual(flatMap.producers, 2, 'the two list calls only');
  assert.strictEqual(flatMap.unknownUnits, 1);
  assert.strictEqual(flatMap.overRatio, true);
  const forEach = analyzeWorkflow([
    LIST_4,
    LIST_20,
    "await Promise.all([...claims.map(c => agent('verify: ' + c)), extra.forEach(e => agent('verify: ' + e))])",
  ].join('\n'));
  assert.strictEqual(forEach.producers, 2);
  assert.strictEqual(forEach.unknownUnits, 1);
  const arrayFrom = analyzeWorkflow([
    LIST_4,
    "await parallel([...claims.map(c => () => agent('verify: ' + c)), ...Array.from({ length: 9 }, (_, i) => () => agent('verify ' + i))])",
  ].join('\n'));
  assert.strictEqual(arrayFrom.producers, 1, 'Array.from runs its map function per element too');
  assert.strictEqual(arrayFrom.unknownUnits, 1);
});

test('a thunk or IIFE beside a mapped callback still counts once', () => {
  // Guard (passes at 6a702d11): a function literal is not per-element by
  // itself. parallel() takes thunks, and a thunk list must not read as unknown.
  const thunks = analyzeWorkflow("await parallel([() => agent('a'), () => agent('b')])");
  assert.strictEqual(thunks.producers, 2);
  assert.strictEqual(thunks.unknownUnits, 0);
  const iife = analyzeWorkflow([
    LIST_4,
    "await parallel([...claims.map(c => agent('verify: ' + c)), (() => agent('summarize all'))()])",
  ].join('\n'));
  assert.strictEqual(iife.producers, 2, 'the list call and the one summarize call');
  assert.strictEqual(iife.unknownUnits, 0);
});

test('a flatMap fan-out is data-driven: an uncapped list is flagged and a capped one scales', () => {
  // Pre-existing since this hook's first commit: only `.map(` was a per-item
  // receiver, so this read as a two-call literal list and never flagged `xs`.
  const uncapped = analyzeWorkflow([
    "const xs = await agent('list things')",
    "await parallel(xs.flatMap(x => [agent('verify a: ' + x), agent('verify b: ' + x)]))",
  ].join('\n'));
  assert.strictEqual(uncapped.uncapped.length, 1, 'an uncapped list behind flatMap must be flagged');
  const capped = analyzeWorkflow([
    LIST_4,
    "await parallel(claims.flatMap(c => [agent('verify a: ' + c), agent('verify b: ' + c)]))",
  ].join('\n'));
  assert.strictEqual(capped.uncapped.length, 0);
  assert.strictEqual(capped.verifiers, 8, 'two calls per item, four items');
});

test('a per-element callback nested in the mapped one flags the unit as not fully resolved', () => {
  // True verifiers: 4 x 20. Only one cap is resolved, so the count is a lower
  // bound; the unit must say so rather than present the bound as the count.
  const result = analyzeWorkflow([
    LIST_4,
    LIST_20,
    "await parallel(claims.flatMap(c => extra.map(e => agent('verify: ' + c + e))))",
  ].join('\n'));
  assert.strictEqual(result.unknownUnits, 1);
  assert.ok(result.verifiers >= 4, 'the resolved part is still counted');
  // Enclosing instead of nested: 3 x 4 true verifiers, 4 resolved.
  const enclosing = analyzeWorkflow([
    LIST_4,
    "await parallel(Array.from({ length: 3 }, () => claims.map(c => () => agent('verify: ' + c))).flat())",
  ].join('\n'));
  assert.strictEqual(enclosing.unknownUnits, 1, 'an enclosing per-element callback is a second multiplier');
  assert.strictEqual(enclosing.verifiers, 4);
  const prompt = analyzeWorkflow([
    LIST_4,
    "await parallel(claims.map(c => agent('verify: ' + [c].filter(Boolean).join())))",
  ].join('\n'));
  assert.strictEqual(prompt.unknownUnits, 0, 'a filter inside the prompt argument encloses no call');
  assert.strictEqual(prompt.verifiers, 4);
});

test('a keyword spelled as a property, or a postfix increment, before a division does not open a regex', () => {
  // 6a702d11's previous-token rule read `.return /` and `n++ /` as the start
  // of a regex literal and blanked everything to the next `/`, agent() call
  // included. The base revision counted both calls.
  const prop = analyzeWorkflow('const stats = { return: 10 };\nconst ratio = stats.return / agent("build report") / 2;');
  assert.strictEqual(prop.producers, 1);
  const postfix = analyzeWorkflow('let n = 3;\nconst ratio = n++ / agent("produce results") / 2;');
  assert.strictEqual(postfix.producers, 1);
  // Guards: a real regex after `return`, and after a binary `+`, still lexes.
  // Each holds a quote, so misreading it as a division would open a string
  // that never closes, fail the lex, and hide the uncapped fan-out below.
  const fanout = "\nawait parallel(xs.map(x => agent('v ' + x)))";
  assert.strictEqual(analyzeWorkflow("function f(s) { return /'/.test(s) }" + fanout).uncapped.length, 1);
  assert.strictEqual(analyzeWorkflow("const a = 1 + /'/.source.length" + fanout).uncapped.length, 1);
});

// Review of bb27d54e: its nested-callback check read only the fan-out's own
// text, so a callback passed by name hid its nested map; and a receiver chain
// broken across lines never matched at all (28 of 3,345 real scripts do it,
// none with a capped receiver). Both RED against bb27d54e.

test('a per-element callback nested in a callback passed by name is found at its declaration', () => {
  // True verifiers: 4 x 20. bb27d54e reported 4 with no unknown unit.
  const result = analyzeWorkflow([
    LIST_4,
    LIST_20,
    "function checkAll(c) { return extra.map(e => agent('verify: ' + c + e)); }",
    'await parallel(claims.map(checkAll))',
  ].join('\n'));
  assert.strictEqual(result.unknownUnits, 1);
  assert.ok(result.verifiers >= 4);
});

test('a hoisted fan-out gets the same nested and sibling accounting as an inline one', () => {
  // Review of a1359cff: `const tasks = <receiver>; parallel(tasks)` never ran
  // the per-element checks. Nested: 4 of a true 80 with no unknown unit.
  // Sibling: its calls sit in no fan-out span, so the final top-level loop
  // counted them once each as producers (producers 4) and overRatio went
  // false. Both identical at 6a702d11 for `.map`; RED against a1359cff.
  for (const method of ['flatMap', 'map']) {
    const nested = analyzeWorkflow([
      LIST_4,
      LIST_20,
      `const tasks = claims.${method}(c => extra.map(e => agent('verify: ' + c + e)))`,
      'await parallel(tasks)',
    ].join('\n'));
    assert.strictEqual(nested.unknownUnits, 1, `nested under a hoisted ${method}`);
    assert.ok(nested.verifiers >= 4);
  }
  const sibling = analyzeWorkflow([
    LIST_4,
    LIST_20,
    "const tasks = [...claims.map(c => agent('verify: ' + c)), ...extra.flatMap(e => [agent('verify a: ' + e), agent('verify b: ' + e)])]",
    'await parallel(tasks)',
  ].join('\n'));
  assert.strictEqual(sibling.producers, 2, 'the two list calls only');
  assert.strictEqual(sibling.unknownUnits, 1);
  assert.strictEqual(sibling.overRatio, true);
  // Guard: a plain hoisted map of thunks is fully resolved.
  const plain = analyzeWorkflow([LIST_4, "const tasks = claims.map(c => () => agent('verify: ' + c))", 'await parallel(tasks)'].join('\n'));
  assert.strictEqual(plain.unknownUnits, 0);
  assert.strictEqual(plain.verifiers, 4);
});

test('a receiver chain broken across lines, or with ?. or a space before the paren, is still the receiver', () => {
  const capped = analyzeWorkflow([LIST_20, 'await parallel(', '  extra', "    .map(x => agent('verify: ' + x))", ')'].join('\n'));
  assert.strictEqual(capped.uncapped.length, 0, 'a capped list written across lines keeps its cap');
  assert.strictEqual(capped.verifiers, 20);
  const sliced = analyzeWorkflow([
    "const xs = await agent('list things')",
    'await parallel(',
    '  xs',
    '    .slice(0, 5)',
    "    .map(x => agent('verify: ' + x))",
    ')',
  ].join('\n'));
  assert.strictEqual(sliced.uncapped.length, 0);
  assert.strictEqual(sliced.verifiers, 5);
  // The property path broken across lines still walks to the field's own cap.
  const path = analyzeWorkflow([
    "const claims = await agent('produce', { schema: { type: 'object', properties: { claims: { type: 'array', maxItems: 3 } } } })",
    'await parallel(',
    '  claims',
    '    .claims',
    "    .map(c => agent('verify: ' + c))",
    ')',
  ].join('\n'));
  assert.strictEqual(path.uncapped.length, 0);
  assert.strictEqual(path.verifiers, 3);
  for (const receiver of ["xs\n    .map(x => agent('verify: ' + x))", "xs?.map(x => agent('verify: ' + x))", "xs.map (x => agent('verify: ' + x))"]) {
    const result = analyzeWorkflow(["const xs = await agent('list things')", `await parallel(${receiver})`].join('\n'));
    assert.strictEqual(result.uncapped.length, 1, `an uncapped list must be flagged: ${JSON.stringify(receiver)}`);
  }
});

test('a schema wrapped in Object.freeze keeps its cap, and no other wrapper is looked through', () => {
  // P2 from the same review: 6a702d11 required the value to start with `{`,
  // so a frozen, correctly capped schema read as uncapped.
  const frozen = mapOver("agent('produce', { schema: Object.freeze({ type: 'array', maxItems: 5, items: { type: 'object' } }) })");
  assert.strictEqual(frozen.uncapped.length, 0);
  assert.strictEqual(frozen.verifiers, 5);
  const nested = mapOver("agent('produce', { schema: Object.freeze({ type: 'object', properties: { claims: Object.freeze({ type: 'array', maxItems: 2 }) } }) })", 'claims.claims');
  assert.strictEqual(nested.verifiers, 2, 'freeze at any level of the path');
  // Guard: an arbitrary function can return a different schema.
  const wrapped = mapOver("agent('produce', { schema: withDefaults({ type: 'array', maxItems: 5 }) })");
  assert.ok(wrapped.uncapped.length > 0, 'only Object.freeze is an identity');
});

test('a regex candidate that does not close on its line reads as a division, not an unlexable script', () => {
  // `{} / 2` passes the previous-token rule; with no closing `/` the whole
  // lex failed and fell back to the comment-blind quote scan, where the
  // apostrophe hid the fan-out.
  const result = analyzeWorkflow([
    "// don't forget",
    'const f = () => {} / 2',
    "await parallel(xs.map(x => agent('v ' + x)))",
  ].join('\n'));
  assert.strictEqual(result.uncapped.length, 1);
});

test('a sibling or nested callback passed by name is read at its declaration', () => {
  const checkOther = "function checkOther(e) { return agent('verify other: ' + e) }";
  // True: 3 producers, 24 verifiers. Before this fix the sibling's call was
  // counted once as a top-level producer: producers 4, verifiers 4, overRatio
  // false, no unknown unit.
  const sibling = analyzeWorkflow([
    LIST_4, LIST_20, checkOther,
    "await Promise.all([...claims.map(c => agent('verify: ' + c)), ...extra.map(checkOther)])",
    "await agent('write report')",
  ].join('\n'));
  assert.strictEqual(sibling.producers, 3, 'the declaration is not a top-level producer');
  assert.strictEqual(sibling.verifiers, 4);
  assert.strictEqual(sibling.unknownUnits, 1, 'the named sibling is an unknown unit');
  assert.strictEqual(sibling.overRatio, true);

  const hoistedSibling = analyzeWorkflow([
    LIST_4, LIST_20, checkOther,
    "const tasks = [...claims.map(c => agent('verify: ' + c)), ...extra.map(checkOther)]",
    'await parallel(tasks)',
    "await agent('write report')",
  ].join('\n'));
  assert.strictEqual(hoistedSibling.producers, 3);
  assert.strictEqual(hoistedSibling.unknownUnits, 1);

  // True: 80 verifiers. The flatMap receiver change made this read producers
  // 3, verifiers 0, overRatio false, no unknown unit.
  const nested = analyzeWorkflow([LIST_4, LIST_20, checkOther, 'await parallel(claims.flatMap(c => extra.map(checkOther)))'].join('\n'));
  assert.strictEqual(nested.producers, 2, 'the declaration is not a top-level producer');
  assert.strictEqual(nested.unknownUnits, 1, 'the named nested callback is an unknown unit');

  const hoistedNested = analyzeWorkflow([LIST_4, LIST_20, checkOther, 'const tasks = claims.flatMap(c => extra.map(checkOther))', 'await parallel(tasks)'].join('\n'));
  assert.strictEqual(hoistedNested.producers, 2);
  assert.strictEqual(hoistedNested.unknownUnits, 1);

  // Guard: a named callback with no agent() call is not a unit.
  const plain = analyzeWorkflow([
    LIST_4, 'function isReal(c) { return c.length > 0 }',
    "await parallel(claims.map(c => agent('verify: ' + c)).filter(isReal))",
  ].join('\n'));
  assert.strictEqual(plain.unknownUnits, 0);
  assert.strictEqual(plain.verifiers, 4);
});

// ===========================================================================
// Named slice indexes: `.slice(0, CAP)` caps the fan-out when CAP's nearest
// reaching declaration is exactly `const CAP = <integer>`. Before this, every
// non-literal index read as uncapped, so a script that hoisted its cap into a
// named constant drew the same WARN as one with no cap at all. Any other name
// -- rebindable, computed, shadowed by a nearer declaration -- stays uncapped.
// ===========================================================================

function namedCapScript(capDecl, fanout) {
  return [capDecl, "const items = await agent('list items', { model: 'sonnet' })", fanout, ''].join('\n');
}

const VERIFY_EACH = "x => () => agent('verify ' + x, { model: 'sonnet' })";

test('named slice index: a const integer caps an inline .map() fan-out', () => {
  const result = analyzeWorkflow(namedCapScript(
    'const MAX_VERIFY = 5',
    `const verified = await parallel(items.list.slice(0, MAX_VERIFY).map(${VERIFY_EACH}))`
  ));
  assert.deepStrictEqual(result.uncapped, []);
  assert.strictEqual(result.unknownUnits, 0);
  assert.strictEqual(result.verifiers, 5);
});

test('named slice index: a const integer caps a named intermediate .slice() binding', () => {
  const result = analyzeWorkflow(namedCapScript(
    'const CAP = 4;',
    `const capped = items.list.slice(0, CAP)\nconst verified = await parallel(capped.map(${VERIFY_EACH}))`
  ));
  assert.deepStrictEqual(result.uncapped, []);
  assert.strictEqual(result.verifiers, 4);
});

test('named slice index: a const integer caps pipeline() items', () => {
  const result = analyzeWorkflow(namedCapScript(
    'const CAP = 3 // per-run ceiling',
    "const checked = await pipeline(items.list.slice(0, CAP), x => agent('verify ' + x, { model: 'sonnet' }))"
  ));
  assert.deepStrictEqual(result.uncapped, []);
  assert.strictEqual(result.verifiers, 3);
});

test('named slice index: both indexes may be names', () => {
  const result = analyzeWorkflow(namedCapScript(
    'const FROM = 2\nconst TO = 6',
    `const verified = await parallel(items.list.slice(FROM, TO).map(${VERIFY_EACH}))`
  ));
  assert.deepStrictEqual(result.uncapped, []);
  assert.strictEqual(result.verifiers, 4);
});

test('named slice index: uncappedFanouts() (the wf-pin-audit entry point) accepts a const cap', () => {
  const stripped = blankStrings('const MAX = 8\nparallel(items.slice(0, MAX).map(x => agent(x)))\n');
  assert.deepStrictEqual(uncappedFanouts(stripped), []);
});

for (const [label, capDecl, sliceArgs] of [
  ['a let binding (rebindable)', 'let MAX = 5', '0, MAX'],
  ['a var binding (rebindable)', 'var MAX = 5', '0, MAX'],
  ['a computed value', 'const MAX = items.list.length', '0, MAX'],
  ['an arithmetic expression', 'const MAX = 2 * 4', '0, MAX'],
  ['a newline continuation (no ASI before an operator)', 'const MAX = 5\n  + extra', '0, MAX'],
  ['a newline continuation into a call', 'const MAX = 5\n(extra)', '0, MAX'],
  ['a name with no declaration', '', '0, MAX'],
  ['a single named index (an unbounded tail)', 'const MAX = 5', 'MAX'],
  ['an end before the start', 'const FROM = 6\nconst TO = 2', 'FROM, TO'],
]) {
  test(`named slice index: ${label} stays uncapped`, () => {
    const result = analyzeWorkflow(namedCapScript(
      capDecl,
      `const verified = await parallel(items.list.slice(${sliceArgs}).map(${VERIFY_EACH}))`
    ));
    assert.strictEqual(result.uncapped.length, 1);
    assert.strictEqual(result.unknownUnits, 1);
    assert.strictEqual(result.verifiers, 0);
  });
}

test('named slice index: a nearer same-named declaration shadows an outer const', () => {
  const script = [
    'const MAX = 5',
    "const items = await agent('list items', { model: 'sonnet' })",
    'async function run() {',
    '  const MAX = items.list.length',
    `  return parallel(items.list.slice(0, MAX).map(${VERIFY_EACH}))`,
    '}',
    '',
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 1, 'the inner computed MAX is the binding in scope, not the outer const 5');
});

test('named slice index: a const declared in an unrelated function never caps the call', () => {
  const script = [
    'function config() { const MAX = 5; return MAX }',
    "const items = await agent('list items', { model: 'sonnet' })",
    `const verified = await parallel(items.list.slice(0, MAX).map(${VERIFY_EACH}))`,
    '',
  ].join('\n');
  const result = analyzeWorkflow(script);
  assert.strictEqual(result.uncapped.length, 1);
});

test('named slice index: a const declared after the call never caps it', () => {
  const stripped = blankStrings('parallel(items.slice(0, MAX).map(x => agent(x)))\nconst MAX = 8\n');
  assert.strictEqual(uncappedFanouts(stripped).length, 1);
});
