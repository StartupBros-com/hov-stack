'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '..');
const GREEN = {
  state: 'OPEN', isDraft: false, autoMergeRequest: null,
  statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }],
};
const ESCALATION = { state: 'OPEN', labels: [{ name: 'needs-human' }], body: 'Gated PR: #12' };

// Execute the real public run(rawInput) and the real pending-record helper.
// Only process I/O and the monotonic clock are stubbed. No exported internals,
// sleeps, network, or operator-home reads; shared time makes the budget tests
// deterministic even on a loaded CI runner.
function fixture(t, { prs = [12], pending = 0, rows: extra = [], mode = 'enforce', gh, env = {}, verifyMs = 0, gitMs = 0, trusted = false } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'handback-hardening-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const logs = path.join(home, '.claude', 'logs');
  fs.mkdirSync(logs, { recursive: true });
  const rows = [
    ...prs.map((pr) => ({ repo: 'acme/widgets', pr, pending: false })),
    ...Array.from({ length: pending }, (_, n) => ({ repo: 'acme/widgets', pr: null, branch: `b${n}`, pending: true })),
    ...extra,
  ].map((row) => ({ fp: 1, ts: new Date().toISOString(), session_id: 's', ...row }));
  fs.writeFileSync(path.join(logs, 'session-prs.jsonl'), rows.map(JSON.stringify).join('\n') + '\n');
  let now = 0;
  let gitCalls = 0;
  const calls = [];
  const child = {
    // Faithful to Node: a call that would outrun its own `timeout` advances the
    // clock by exactly that timeout and throws ETIMEDOUT, so no test can reach
    // an elapsed time the real process cannot (review finding on PR 1188).
    // Git calls come from verifyGate's change detection and answer as a dirty
    // checkout on origin/main; the verify command itself returns nothing.
    execSync(command, options = {}) {
      const isGit = String(command).startsWith('git ');
      const ms = isGit ? gitMs : verifyMs;
      if (options.timeout > 0 && ms > options.timeout) {
        now += options.timeout;
        throw Object.assign(new Error('fixture timeout'), { code: 'ETIMEDOUT', killed: true });
      }
      now += ms;
      if (!isGit) return '';
      gitCalls += 1;
      // The real helper passes git's global --no-optional-locks before the
      // subcommand (dotfiles#1590); strip it so the subcommand match below holds.
      const args = String(command).slice(4).replace(/^--no-optional-locks /, '');
      if (args.startsWith('status ')) return ' M src/a.js\n';
      if (args.startsWith('symbolic-ref ')) return 'refs/remotes/origin/main\n';
      if (args.startsWith('merge-base ')) return 'abc123\n';
      if (args.startsWith('diff ')) return 'src/a.js\n';
      return 'true\n';
    },
    execFileSync(command, args, options) {
      assert.equal(command, 'gh');
      const call = { args: Array.from(args), timeout: options.timeout, killSignal: options.killSignal };
      calls.push(call);
      const response = gh ? gh(call, calls.length) : { value: args[0] === 'issue' ? ESCALATION : GREEN };
      const ms = response.ms || 0;
      if (options.timeout > 0 && ms > options.timeout) {
        now += options.timeout;
        throw Object.assign(new Error('fixture timeout'), { code: 'ETIMEDOUT' });
      }
      now += ms;
      if (response.error) throw new Error(response.error);
      return JSON.stringify(response.value);
    },
  };
  const modules = new Map();
  function load(filename) {
    if (modules.has(filename)) return modules.get(filename).exports;
    const module = { exports: {} };
    modules.set(filename, module);
    const imports = (name) => {
      if (name === 'child_process') return child;
      if (name === 'os') return { homedir: () => home };
      if (name === 'perf_hooks') return { performance: { now: () => now } };
      if (name.startsWith('.')) return load(path.resolve(path.dirname(filename), name));
      return require(name);
    };
    vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
      module, exports: module.exports, require: imports, Buffer,
      process: {
        env: { CLAUDE_VERIFY_TRUSTED_ROOTS: trusted ? home : '/nonexistent', CLAUDE_HANDBACK_MODE: mode, ...env },
        cwd: () => home, stderr: { write() {} },
      },
    }, { filename });
    return module.exports;
  }
  const hook = load(path.join(ROOT, 'Stop', 'verify-on-stop.js'));
  return {
    calls,
    gitCalls: () => gitCalls,
    elapsed: () => now,
    run(message = 'result: ready', extra = {}) {
      const raw = JSON.stringify({ cwd: home, session_id: 's', last_assistant_message: message, ...extra });
      const output = hook.run(raw);
      return { raw, output, decision: JSON.parse(output).decision };
    },
    ledger() {
      const p = path.join(logs, 'handback-ledger.jsonl');
      return fs.existsSync(p) ? fs.readFileSync(p, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
    },
  };
}

for (const [name, state] of [
  ['draft', { ...GREEN, isDraft: true }],
  ['unknown PR state', { ...GREEN, state: 'UNKNOWN' }],
  ['missing PR state', { statusCheckRollup: GREEN.statusCheckRollup }],
  ['null PR', null],
  ['empty object PR', {}],
  ['array PR', []],
  ['absent rollup', { state: 'OPEN' }],
  ['empty rollup', { ...GREEN, statusCheckRollup: [] }],
  ['null rollup', { ...GREEN, statusCheckRollup: null }],
  ['object rollup', { ...GREEN, statusCheckRollup: {} }],
  ['null check', { ...GREEN, statusCheckRollup: [null] }],
  ['malformed check', { ...GREEN, statusCheckRollup: [{}] }],
  ['unknown conclusion', { ...GREEN, statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'NEW_STATE' }] }],
  ['skipped-only', { ...GREEN, statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SKIPPED' }] }],
  ['neutral-only', { ...GREEN, statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'NEUTRAL' }] }],
  ['mixed success and skipped', { ...GREEN, statusCheckRollup: [...GREEN.statusCheckRollup, { status: 'COMPLETED', conclusion: 'SKIPPED' }] }],
  ['mixed success and malformed', { ...GREEN, statusCheckRollup: [...GREEN.statusCheckRollup, {}] }],
  ['pending', { ...GREEN, statusCheckRollup: [{ status: 'IN_PROGRESS' }] }],
  ['failing', { ...GREEN, statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'FAILURE' }] }],
]) {
  test(`handback does not treat ${name} as green (enforce or shadow)`, (t) => {
    for (const mode of ['enforce', 'shadow']) {
      const f = fixture(t, { mode, gh: () => ({ value: state }) });
      const r = f.run();
      assert.equal(r.output, r.raw);
      assert.equal(f.ledger().length, 0);
    }
  });
}

for (const [name, rollup] of [
  ['check-run', GREEN.statusCheckRollup],
  ['legacy status', [{ state: 'SUCCESS' }]],
]) {
  test(`handback still detects a real green PR via ${name}`, (t) => {
    const gh = () => ({ value: { ...GREEN, statusCheckRollup: rollup } });
    assert.equal(fixture(t, { gh }).run().decision, 'block');
    const shadow = fixture(t, { gh, mode: 'shadow' });
    const r = shadow.run();
    assert.equal(r.output, r.raw);
    assert.equal(shadow.ledger().length, 1);
    assert.equal(shadow.ledger()[0].pr, 12);
    assert.ok(shadow.calls[0].args.at(-1).split(',').includes('isDraft'), 'real gh query must request draft state');
  });
}

for (const [name, state] of [
  ['merged', { state: 'MERGED' }],
  ['closed without merging', { state: 'CLOSED' }],
  ['auto-merge armed', { ...GREEN, autoMergeRequest: { enabledAt: '2026-09-14' }, statusCheckRollup: [] }],
]) {
  test(`handback keeps the ${name} exit`, (t) => {
    const f = fixture(t, { gh: () => ({ value: state }) });
    const r = f.run();
    assert.equal(r.output, r.raw);
    assert.equal(f.ledger().length, 0);
  });
}

for (const [body, valid] of [
  ['Gated PR: #12\nReason: credentials', true],
  ['See (#12).', true],
  ['Gated PR: `#12`', true],
  ['Gated PR: acme/widgets#12', true],
  ['Gated PR: ACME/Widgets#12', true],
  ['[PR](https://github.com/acme/widgets/pull/12)', true],
  // Collision numbers are five digits on purpose: the design-drift CI scan
  // (budget 0) reads a '#' followed by 3, 4, 6 or 8 hex-safe characters as a
  // colour literal, so '#123' in a .js string fails the build.
  ['Gated PR: #12345', false],
  ['Gated PR: #12000', false],
  ['Gated PR: #11212', false],
  ['Gated PR: #12abc', false],
  ['Gated PR: other/widgets#12', false],
  ['Gated PR: https://github.com/other/widgets/pull/12', false],
  ['Gated PR: https://example.com/#12', false],
  ['Gated PR: https://github.com/acme/widgets/issues/12', false],
  ['Gated PR: #13\nSee also unrelated text.', false],
]) {
  test(`escalation ${valid ? 'accepts' : 'rejects'} ${body.split('\n')[0]}`, (t) => {
    const f = fixture(t, { gh: ({ args }) => ({ value: args[0] === 'issue' ? { ...ESCALATION, body } : GREEN }) });
    assert.equal(f.run('needs input: #57').decision, valid ? undefined : 'block');
    assert.equal(f.calls.length, 2, 'both PR state and escalation must actually be read');
  });
}

test('all PR lookups share one 8s deadline, even after a timeout', (t) => {
  const f = fixture(t, {
    prs: [12, 13, 14],
    gh: (_, n) => n === 1 ? { value: { state: 'MERGED' }, ms: 6000 } : { value: GREEN, ms: 10000 },
  });
  const r = f.run();
  assert.equal(r.output, r.raw);
  assert.equal(f.ledger().length, 0);
  assert.deepEqual(f.calls.map((c) => c.timeout), [8000, 2000]);
  assert.equal(f.elapsed(), 8000);
  assert.ok(f.calls.every((c) => c.killSignal === 'SIGKILL'), 'a gh child ignoring SIGTERM must not overrun its budget');
});

test('pending-PR resolution consumes the SAME deadline and stops issuing gh calls', (t) => {
  const f = fixture(t, { prs: [], pending: 3, gh: () => ({ value: [{ number: 12 }], ms: 10000 }) });
  const r = f.run();
  // U8/R15: rows still pending after the budget is spent are named, never
  // silently passed over -- but naming is a systemMessage only: no decision,
  // no block, no ledger row (the budget rules below are unchanged).
  const out = JSON.parse(r.output);
  assert.equal(out.decision, undefined, 'an unresolved pending claim never blocks');
  for (const b of ['b0', 'b1', 'b2']) assert.match(out.systemMessage, new RegExp(`Branch ${b} `));
  assert.equal(f.ledger().length, 0);
  assert.deepEqual(f.calls.map((c) => c.timeout), [5000, 3000]);
  assert.equal(f.elapsed(), 8000);
  assert.ok(f.calls.every((c) => c.killSignal === 'SIGKILL'));
});

test('pending resolution, PR read, and escalation read share the deadline end to end', (t) => {
  const f = fixture(t, {
    prs: [], pending: 1,
    gh: (_, n) => [
      { value: [{ number: 12 }], ms: 4000 },
      { value: GREEN, ms: 1000 },
      { value: ESCALATION, ms: 10000 },
    ][n - 1],
  });
  const r = f.run('needs input: #57');
  assert.equal(r.output, r.raw, 'timed-out escalation is inconclusive, not invalid');
  assert.equal(f.ledger().length, 0);
  assert.deepEqual(f.calls.map((c) => c.timeout), [5000, 4000, 3000]);
  assert.equal(f.elapsed(), 8000);
});

// #1542: a claim's pending row is never retired, and `gh pr list` lists only
// open PRs, so a long session kept re-asking about branches that had already
// resolved until those calls spent the whole budget and no PR was evaluated.
const listCalls = (f) => f.calls.filter((c) => c.args[0] === 'pr' && c.args[1] === 'list');

test('pending rows for a branch that already resolved cost no gh call, so its PR is still evaluated', (t) => {
  const f = fixture(t, {
    mode: 'shadow', prs: [],
    rows: [
      ...Array.from({ length: 11 }, () => ({ repo: 'acme/widgets', pr: null, branch: 'feat', pending: true })),
      { repo: 'acme/widgets', pr: 12, branch: 'feat', pending: false },
    ],
    gh: (call) => (call.args[1] === 'list' ? { value: [], ms: 1000 } : { value: GREEN }),
  });
  const r = f.run();
  assert.equal(r.output, r.raw, 'a resolved branch is not named as a pending claim');
  assert.deepEqual(f.ledger().map((row) => row.pr), [12], 'the PR is evaluated within the budget');
  assert.equal(listCalls(f).length, 0, 'a branch with a resolved row is never queried again');
});

test('pending resolution queries each still-pending repo+branch once, and only this session\'s', (t) => {
  const f = fixture(t, {
    prs: [],
    rows: [
      ...Array.from({ length: 3 }, () => ({ repo: 'acme/widgets', pr: null, branch: 'feat', pending: true })),
      { repo: 'acme/gadgets', pr: null, branch: 'feat', pending: true },
      // Another session's resolved row does not clear this session's claim,
      // and another session's pending row is not this session's to resolve.
      { session_id: 'other', repo: 'acme/widgets', pr: 7, branch: 'feat', pending: false },
      { session_id: 'other', repo: 'acme/widgets', pr: null, branch: 'theirs', pending: true },
    ],
    gh: () => ({ value: [] }),
  });
  const out = JSON.parse(f.run().output);
  assert.deepEqual(listCalls(f).map((c) => c.args.slice(2, 6)), [
    ['--repo', 'acme/widgets', '--head', 'feat'],
    ['--repo', 'acme/gadgets', '--head', 'feat'],
  ]);
  assert.match(out.systemMessage, /Branch feat in acme\/widgets /);
  assert.match(out.systemMessage, /Branch feat in acme\/gadgets /);
  assert.doesNotMatch(out.systemMessage, /theirs/);
});

// pro-gate round 1 P1 on #1563: the pending-pair rule read every resolved row
// of the session as one unordered set, so a branch's first PR permanently
// hid a later claim that reused the branch. The reused claim must be
// queried, and the PR it finds evaluated alongside the first.
test('pro-gate round 1 P1: a claim logged after its branch\'s earlier PR resolved is queried and its new PR evaluated', (t) => {
  const f = fixture(t, {
    mode: 'shadow', prs: [],
    rows: [
      { repo: 'acme/widgets', pr: null, branch: 'feat', pending: true },
      { repo: 'acme/widgets', pr: 12, branch: 'feat', pending: false },
      // Branch reused after PR 12: a second `gh pr create` whose URL was not
      // extracted. Only this claim is still open.
      { repo: 'acme/widgets', pr: null, branch: 'feat', pending: true },
    ],
    gh: (call) => (call.args[1] === 'list' ? { value: [{ number: 13 }] } : { value: GREEN }),
  });
  const r = f.run();
  assert.deepEqual(listCalls(f).map((c) => c.args.slice(2, 6)), [
    ['--repo', 'acme/widgets', '--head', 'feat'],
  ], 'the reopened claim is queried exactly once');
  assert.deepEqual(f.ledger().map((row) => row.pr).sort((a, b) => a - b), [12, 13], 'both PRs on the branch are evaluated');
  assert.equal(r.output, r.raw, 'the claim resolved to PR 13, so no branch is named as pending');
});

test('budget exhaustion does not invent flags for unobserved PRs or erase observed ones', (t) => {
  const f = fixture(t, {
    mode: 'shadow', prs: [12, 13, 14],
    gh: (_, n) => ({ value: GREEN, ms: n === 1 ? 1000 : 10000 }),
  });
  f.run();
  assert.deepEqual(f.ledger().map((r) => r.pr), [12]);
  assert.equal(f.calls.length, 2);
});

// Change-detection setup can eat into handback's headroom before the 180 s
// verifier runs. Both gates now contribute to the initial Stop even on a
// verification timeout; handback only gets the remaining shared budget.
test('slow change detection plus a near-timeout verify leaves only the remaining Stop-time headroom for handback', (t) => {
  const f = fixture(t, {
    trusted: true, gitMs: 1600, verifyMs: 179000,
    env: { CLAUDE_VERIFY_CMD: 'fixture-verify' },
    gh: () => ({ value: GREEN, ms: 10000 }),
  });
  const r = f.run();
  assert.equal(r.output, r.raw);
  assert.equal(f.gitCalls(), 5, 'rev-parse, status, symbolic-ref, merge-base, diff');
  assert.deepEqual(f.calls.map((c) => c.timeout), [1000]);
  assert.equal(f.elapsed(), 188000);
});

test('expired Stop-time headroom starts no handback lookup', (t) => {
  const f = fixture(t, {
    trusted: true, gitMs: 1800, verifyMs: 179000, pending: 1,
    env: { CLAUDE_VERIFY_CMD: 'fixture-verify' },
  });
  const r = f.run();
  assert.equal(r.output, r.raw);
  assert.equal(f.gitCalls(), 5);
  assert.equal(f.calls.length, 0);
  assert.equal(f.elapsed(), 188000);
});

test('#1515: verify timeout still composes handback within the remaining shared 8s', (t) => {
  const f = fixture(t, {
    prs: [12, 13, 14], verifyMs: 187000,
    env: { CLAUDE_VERIFY_ON_STOP: '1', CLAUDE_VERIFY_CMD: 'fixture-verify' },
    gh: (_, n) => ({ value: GREEN, ms: n === 1 ? 1000 : 10000 }),
  });
  const r = f.run();
  assert.equal(r.decision, 'block');
  const reason = JSON.parse(r.output).reason;
  assert.match(reason, /timed out/);
  assert.match(reason, /acme\/widgets#12/);
  assert.doesNotMatch(reason, /acme\/widgets#13|acme\/widgets#14/, 'timed out and unobserved PRs are not unresolved findings');
  assert.deepEqual(f.calls.map(c => c.timeout), [8000, 7000]);
  assert.equal(f.elapsed(), 188000);
  const active = f.run('result: ready', { stop_hook_active: true });
  assert.equal(active.output, active.raw);
  assert.equal(f.calls.length, 2);
  assert.equal(f.elapsed(), 188000, 'active retry does not verify or look up GH again');
});

test('#1515: exhausted setup headroom preserves a verify timeout without scheduling handback retries', (t) => {
  const f = fixture(t, {
    trusted: true, gitMs: 1800, verifyMs: 187000,
    env: { CLAUDE_VERIFY_CMD: 'fixture-verify' },
  });
  const r = f.run();
  assert.equal(r.decision, 'block');
  assert.match(JSON.parse(r.output).reason, /timed out/);
  assert.doesNotMatch(JSON.parse(r.output).reason, /MACHINE GATE/);
  assert.equal(f.gitCalls(), 5);
  assert.equal(f.calls.length, 0);
  assert.equal(f.ledger().length, 0, 'unobserved is inconclusive, not success or an incident');
  assert.equal(f.elapsed(), 189000, 'setup itself can overrun the combined nominal budget');
  const active = f.run('result: ready', { stop_hook_active: true });
  assert.equal(active.output, active.raw);
  assert.equal(f.gitCalls(), 5);
  assert.equal(f.calls.length, 0);
  assert.equal(f.elapsed(), 189000);
});

test('off mode and recursive Stop still make zero gh calls', (t) => {
  const off = fixture(t, { mode: 'off', pending: 1 });
  off.run();
  assert.equal(off.calls.length, 0);
  const recursive = fixture(t, { pending: 1 });
  recursive.run('result: ready', { stop_hook_active: true });
  assert.equal(recursive.calls.length, 0);
});

test('a per-call timeout smaller than the shared budget is still honored', (t) => {
  const f = fixture(t, { env: { CLAUDE_HANDBACK_GH_TIMEOUT_MS: '200' }, gh: () => ({ value: GREEN, ms: 1000 }) });
  assert.equal(f.run().decision, undefined);
  assert.deepEqual(f.calls.map((c) => c.timeout), [200]);
});

// Real subprocess smoke complements the deterministic clock tests above: the
// executable hook must produce the same wire result, and a gh child ignoring
// SIGTERM must actually terminate. The fixture never calls real git or gh.
for (const [name, state, body, hang, blocked] of [
  ['green', GREEN, 'Gated PR: #13', false, true],
  ['draft', { ...GREEN, isDraft: true }, 'Gated PR: #13', false, false],
  ['prefix collision', GREEN, 'Gated PR: #12345', false, true],
  ['valid escalation', GREEN, 'Gated PR: #12', false, false],
  ['gh ignores SIGTERM', GREEN, 'Gated PR: #12', true, false],
]) {
  test(`real hook process: ${name}`, (t) => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'handback-process-'));
    t.after(() => fs.rmSync(home, { recursive: true, force: true }));
    const logs = path.join(home, '.claude', 'logs');
    fs.mkdirSync(logs, { recursive: true });
    fs.writeFileSync(path.join(logs, 'session-prs.jsonl'), JSON.stringify({ session_id: 's', repo: 'acme/widgets', pr: 12 }) + '\n');
    fs.writeFileSync(path.join(home, 'gh'), `#!/usr/bin/env node
if (${hang}) { process.on('SIGTERM', () => {}); setInterval(() => {}, 1000); }
else console.log(JSON.stringify(process.argv[2] === 'issue' ? ${JSON.stringify({ ...ESCALATION, body })} : ${JSON.stringify(state)}));
`, { mode: 0o755 });
    const raw = JSON.stringify({ cwd: home, session_id: 's', last_assistant_message: 'needs input: #57' });
    const proc = require('node:child_process').spawnSync(process.execPath, [path.join(ROOT, 'Stop', 'verify-on-stop.js')], {
      input: raw, encoding: 'utf8', timeout: 5000,
      env: {
        ...process.env, HOME: home, USERPROFILE: home, PATH: `${home}${path.delimiter}${process.env.PATH}`,
        CLAUDE_VERIFY_ON_STOP: '0', CLAUDE_VERIFY_TRUSTED_ROOTS: '/nonexistent',
        CLAUDE_HANDBACK_MODE: 'enforce', CLAUDE_HANDBACK_GH_TIMEOUT_MS: hang ? '200' : '2000',
      },
    });
    assert.ifError(proc.error);
    assert.equal(proc.status, 0, proc.stderr);
    if (blocked) {
      assert.equal(JSON.parse(proc.stdout).decision, 'block');
    } else {
      assert.equal(proc.stdout, '');
    }
  });
}
