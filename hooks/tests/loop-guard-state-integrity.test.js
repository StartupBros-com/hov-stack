'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, assertQuietPassThrough, assertPreToolUseDeny, mkTmp, rmTmp } = require('./lib/harness');
const HOOK = 'PreToolUse/loop-guard.js';

async function fixture(fn) {
  const home = mkTmp('lg-integrity-');
  const dir = path.join(home, '.claude', '.loop-state');
  const file = path.join(dir, 's.json');
  const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '3', CLAUDE_LOOP_HARD_GRACE: '2' };
  const call = (command = 'ls') => runHook(HOOK, { session_id: 's', tool_name: 'Bash', tool_input: { command } }, { env });
  try {
    assertQuietPassThrough(await call());
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).count, 1);
    await fn({ home, dir, file, env, call });
  } finally { rmTmp(home); }
}
function stopped(res) {
  assert.equal(res.code, 0, res.stderr);
  assertPreToolUseDeny(res);
  assert.equal(JSON.parse(res.stdout).continue, false);
}
async function badField(patch, command = 'ls') {
  await fixture(async ({ file, call }) => {
    const prior = JSON.parse(fs.readFileSync(file, 'utf8'));
    fs.writeFileSync(file, JSON.stringify({ ...prior, ...patch }));
    stopped(await call(command));
    stopped(await call('ls'));
    stopped(await call('gh pr merge 5'));
  });
}

test('loop state: a string call count fails closed across both paths', () => badField({ count: 'x' }));
test('loop state: a string fenced-denial count fails closed', () => badField({ fencedDenials: 'x' }, 'gh pr merge 5'));
test('loop state: a negative call count fails closed', () => badField({ count: -1 }));
test('loop state: a fractional call count fails closed', () => badField({ count: 1.5 }));
test('loop state: a non-numeric start timestamp fails closed', () => badField({ startMs: 'x' }));
test('loop state: a future start timestamp fails closed', () => badField({ startMs: Date.now() + 60000 }));
test('loop state: an invalid grace origin fails closed', () => badField({ overSinceCount: 'x' }));
test('loop state: a grace origin beyond the count fails closed', () => badField({ overSinceCount: 99 }));

test('loop state: an unreadable dangling entry does not reset the counter', async () => {
  await fixture(async ({ file, home, call }) => {
    fs.unlinkSync(file);
    fs.symlinkSync(path.join(home, 'absent-target'), file);
    assert.equal(fs.existsSync(file), false);
    assert.equal(fs.lstatSync(file).isSymbolicLink(), true);
    stopped(await call());
    stopped(await call());
  });
});

test('loop state: fenced calls hard-stop immediately without writable state', async () => {
  const home = mkTmp('lg-fenced-unwritable-');
  try {
    fs.writeFileSync(path.join(home, '.claude'), 'not a directory');
    const res = await runHook(HOOK, { session_id: 's', tool_name: 'Bash', tool_input: { command: 'gh pr merge 5' } }, {
      env: { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '3', CLAUDE_LOOP_HARD_GRACE: '2' },
    });
    stopped(res);
  } finally { rmTmp(home); }
});

test('loop state: a corrupt file fails closed first on the fenced path', async () => {
  await fixture(async ({ file, call }) => {
    fs.writeFileSync(file, '{corrupt');
    stopped(await call('gh pr merge 5'));
    stopped(await call());
  });
});

test('loop state: a held live lock does not allow an unaccounted call', async () => {
  await fixture(async ({ dir, file, call }) => {
    const lock = path.join(dir, '.s.lock');
    fs.mkdirSync(lock);
    fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify({ pid: process.pid, token: 'live-test-owner', acquiredAt: Date.now() }));
    const before = fs.readFileSync(file, 'utf8');
    stopped(await call());
    stopped(await call('gh pr merge 5'));
    assert.equal(fs.readFileSync(file, 'utf8'), before, 'failed lock acquisition must not write unlocked state');
    assert.equal(fs.existsSync(path.join(lock, 'owner.json')), true, 'a live owner lock must survive');
  });
});

test('loop state: an uncoercible fenced timestamp stops and writes markers on repeated calls', async () => {
  await fixture(async ({ home, dir, file, env, call }) => {
    const marker = path.join(home, 'invalid-time.budget-stop');
    env.CLAUDE_LOOP_STOP_MARKER = marker;
    const state = JSON.parse(fs.readFileSync(file, 'utf8'));
    state.startMs = { valueOf: null, toString: null };
    fs.writeFileSync(file, JSON.stringify(state));
    assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).startMs, state.startMs);
    stopped(await call('gh pr merge 5'));
    stopped(await call('gh pr merge 5'));
    assert.equal(JSON.parse(fs.readFileSync(marker, 'utf8')).stopped, 'budget');
    assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'stop-markers', path.basename(marker)), 'utf8')).stopped, 'budget');
  });
});

async function reorderedInitialCalls(command) {
  const home = mkTmp('lg-clock-order-');
  const preloader = path.join(home, 'before-lock.cjs');
  const signal = path.join(home, 'before-lock');
  const release = path.join(home, 'release');
  // Delay A before lock acquisition without changing time or state. B will
  // create valid state at a later real timestamp, then A resumes.
  fs.writeFileSync(preloader, `
    const fs = require('node:fs');
    const path = require('node:path');
    const original = fs.mkdirSync;
    let paused = false;
    fs.mkdirSync = function(target, ...args) {
      if (!paused && path.basename(String(target)) === '.clock.lock') {
        paused = true;
        fs.writeFileSync(${JSON.stringify(signal)}, String(Date.now()));
        const deadline = Date.now() + 10000;
        while (!fs.existsSync(${JSON.stringify(release)})) {
          if (Date.now() > deadline) throw new Error('clock-order fixture was not released');
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
        }
      }
      return original.call(this, target, ...args);
    };
  `);
  const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '20', CLAUDE_LOOP_HARD_GRACE: '2' };
  const input = (cmd) => ({ session_id: 'clock', tool_name: 'Bash', tool_input: { command: cmd } });
  const pending = runHook(HOOK, input(command), { env: { ...env, NODE_OPTIONS: `--require=${preloader}` } });
  try {
    const deadline = Date.now() + 10000;
    while (!fs.existsSync(signal)) {
      assert.ok(Date.now() < deadline, 'A must reach the pre-lock scheduling point');
      await new Promise((resolve) => setImmediate(resolve));
    }
    const beforeLock = Number(fs.readFileSync(signal, 'utf8'));
    assertQuietPassThrough(await runHook(HOOK, input('ls'), { env }));
    const file = path.join(home, '.claude', '.loop-state', 'clock.json');
    const initialized = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.ok(initialized.startMs > beforeLock, 'precondition: B initialized after A captured its clock');
    fs.writeFileSync(release, 'go');
    const resumed = await pending;
    assert.equal(resumed.code, 0, resumed.stderr);
    if (command === 'ls') assertQuietPassThrough(resumed);
    else {
      assertPreToolUseDeny(resumed);
      assert.notEqual(JSON.parse(resumed.stdout).continue, false, 'ordinary fence denial, not a corruption stop');
    }
    const after = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.notEqual(after.failClosed, true, 'healthy ordering must not poison the session');
    assert.equal(after.count, command === 'ls' ? 2 : 1);
    assertQuietPassThrough(await runHook(HOOK, input('ls'), { env }));
  } finally {
    fs.writeFileSync(release, 'go');
    await pending;
    rmTmp(home);
  }
}

test('loop state: counted startup calls tolerate reversed lock acquisition', () => reorderedInitialCalls('ls'));
test('loop state: fenced startup calls tolerate reversed lock acquisition', () => reorderedInitialCalls('gh pr merge 5'));

// U6 fixtures: protect only the owned-PR root, keeping ordinary loop state
// writable as before. These inputs never execute an actual shell mutation.
for (const tool of ['Write', 'Edit', 'Bash']) {
  for (const spelling of ['absolute', '~', '$HOME', '${HOME}']) {
    test(`U6 ${tool} protects owned-PR state via ${spelling} only under guard`, async () => {
      const home = mkTmp('lg-owner-state-');
      try {
        const prefix = spelling === 'absolute' ? home : spelling;
        const target = `${prefix}/.claude/.loop-state/pr-owner/acme--widgets--5/owner.json`;
        const input = (file) => ({
          session_id: 'owner', tool_name: tool,
          tool_input: tool === 'Bash' ? { command: `printf '{}' > ${file}` } : { file_path: file, content: '{}' },
        });
        const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '20' };
        assertPreToolUseDeny(await runHook(HOOK, input(target), { env }));
        assertQuietPassThrough(await runHook(HOOK, input(target), { env: { ...env, CLAUDE_LOOP_GUARD: '0' } }));
        assertQuietPassThrough(await runHook(HOOK, input(`${prefix}/.claude/.loop-state/ordinary.json`), { env }));
        assertQuietPassThrough(await runHook(HOOK, input(`${prefix}/.claude/.loop-state/pr-owner-other/owner.json`), { env }));
      } finally { rmTmp(home); }
    });
  }
}

// The owned-PR root is fenced by where a command acts: a cd (in this call or
// the session cwd the hook reports) or a relative operand reaches it without
// the full path, and only reads may follow.
for (const [name, command, cwd] of [
  ['cd then rm', (root) => `cd ${root}/acme--widgets--5 && rm owner.json`],
  ['cd then relative redirect', (root) => `cd ${root}/acme--widgets--5; jq '.state="owned"' owner.json > owner.json`],
  ['subshell cd then rm', (root) => `(cd ${root}/acme--widgets--5 && rm heartbeat.json)`],
  ['cd to parent then relative operand', (root) => `cd ${root}/.. && rm -r pr-owner/acme--widgets--5`],
  ['find -delete under the root', (root) => `find ${root} -name owner.json -delete`],
  ['interpreter naming the root', (root) => `python3 -c "import os; os.remove('${root}/acme--widgets--5/owner.json')"`],
  ['session cwd inside the root', () => 'rm owner.json', (root) => `${root}/acme--widgets--5`],
]) {
  test(`U6 Bash owned-PR state fence: ${name} is denied only under guard`, async () => {
    const home = mkTmp('lg-owner-cwd-');
    try {
      const root = `${home}/.claude/.loop-state/pr-owner`;
      const input = { session_id: 'owner', tool_name: 'Bash', tool_input: { command: command(root) } };
      if (cwd) input.cwd = cwd(root);
      const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '20' };
      assertPreToolUseDeny(await runHook(HOOK, input, { env }));
      assertQuietPassThrough(await runHook(HOOK, input, { env: { ...env, CLAUDE_LOOP_GUARD: '0' } }));
    } finally { rmTmp(home); }
  });
}

for (const [name, command, cwd] of [
  ['cd then read', (root) => `cd ${root}/acme--widgets--5 && cat owner.json && jq .state heartbeat.json`],
  ['read with an outside redirect', (root) => `jq . ${root}/acme--widgets--5/owner.json > /tmp/owner-copy.json 2>&1`],
  ['unrelated cd then rm', () => 'cd /tmp/scratch-dir && rm notes.txt'],
  ['worktree cwd edit', () => 'rm build.log', () => '/tmp/some-worktree'],
]) {
  test(`U6 Bash owned-PR state fence: ${name} stays allowed under guard`, async () => {
    const home = mkTmp('lg-owner-cwd-');
    try {
      const root = `${home}/.claude/.loop-state/pr-owner`;
      const input = { session_id: 'owner', tool_name: 'Bash', tool_input: { command: command(root) } };
      if (cwd) input.cwd = cwd(root);
      const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '20' };
      assertQuietPassThrough(await runHook(HOOK, input, { env }));
    } finally { rmTmp(home); }
  });
}

// The owner runs ~/.claude/scripts (a link into the canonical checkout) with
// merge authority: a fenced session may run those scripts and edit its own
// linked worktree, but never change the installed copies or move the checkout.
function installedHome() {
  const home = mkTmp('lg-installed-');
  const checkout = path.join(home, 'hov-stack');
  fs.mkdirSync(path.join(checkout, '.git'), { recursive: true });
  fs.mkdirSync(path.join(checkout, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(checkout, '.claude', 'worktrees', 'w', 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(home, 'other', '.git'), { recursive: true });
  fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
  fs.symlinkSync(path.join(checkout, 'scripts'), path.join(home, '.claude', 'scripts'));
  return { home, checkout, env: { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '20' } };
}
const toolInput = (input) => ({ session_id: 'installed', ...input });
for (const [name, make] of [
  ['Write to the installed owner script', ({ home }) => ({ tool_name: 'Write', tool_input: { file_path: `${home}/.claude/scripts/pr-owner.sh`, content: 'x' } })],
  ['Edit of the resolved installed library', ({ checkout }) => ({ tool_name: 'Edit', tool_input: { file_path: `${checkout}/scripts/lib/pr-owner-state.sh`, old_string: 'a', new_string: 'b' } })],
  ['cp into the installed scripts', () => ({ tool_name: 'Bash', tool_input: { command: 'cp scripts/pr-owner.sh ~/.claude/scripts/pr-owner.sh' } })],
  ['redirect into an installed script', () => ({ tool_name: 'Bash', tool_input: { command: "printf 'x' > ~/.claude/scripts/pro-gate-loop.sh" } })],
  ['git restore in the canonical checkout', ({ checkout }) => ({ tool_name: 'Bash', tool_input: { command: `git -C ${checkout} restore --source=abc123 -- scripts/pr-owner.sh` } })],
  ['git checkout of another branch in the canonical checkout', ({ checkout }) => ({ tool_name: 'Bash', tool_input: { command: `git -C ${checkout} checkout fixer-branch` } })],
  ['cd into the canonical checkout then reset', ({ checkout }) => ({ tool_name: 'Bash', tool_input: { command: `cd ${checkout} && git reset --hard origin/fixer-branch` } })],
]) {
  test(`U6 installed harness fence: ${name} is denied only under guard`, async () => {
    const fixture = installedHome();
    try {
      const input = toolInput(make(fixture));
      assertPreToolUseDeny(await runHook(HOOK, input, { env: fixture.env }));
      assertQuietPassThrough(await runHook(HOOK, input, { env: { ...fixture.env, CLAUDE_LOOP_GUARD: '0' } }));
    } finally { rmTmp(fixture.home); }
  });
}
for (const [name, make] of [
  ['git status in the canonical checkout', ({ checkout }) => ({ tool_name: 'Bash', tool_input: { command: `git -C ${checkout} status` } })],
  ['git commit in a linked worktree', ({ checkout }) => ({ tool_name: 'Bash', tool_input: { command: `git -C ${checkout}/.claude/worktrees/w commit -m fix scripts/pr-owner.sh` } })],
  ['Write to the worktree copy', ({ checkout }) => ({ tool_name: 'Write', tool_input: { file_path: `${checkout}/.claude/worktrees/w/scripts/pr-owner.sh`, content: 'x' } })],
  ['running an installed script', () => ({ tool_name: 'Bash', tool_input: { command: 'bash ~/.claude/scripts/papercut-report.sh' } })],
  ['git commit in a sibling repository beside the checkout', ({ home }) => ({ tool_name: 'Bash', tool_input: { command: `git -C ${home}/other commit -m fix scripts/x.sh` } })],
]) {
  test(`U6 installed harness fence: ${name} stays allowed under guard`, async () => {
    const fixture = installedHome();
    try {
      assertQuietPassThrough(await runHook(HOOK, toolInput(make(fixture)), { env: fixture.env }));
    } finally { rmTmp(fixture.home); }
  });
}

// The temp HOME is outside /home/<user>, so only the resolved-path check can
// see this: a lookalike sibling earlier in the same segment must not hide the
// owned root after it.
test('U6 Bash protects owned-PR state named after a lookalike sibling path', async () => {
  const home = mkTmp('lg-owner-state-');
  try {
    const root = `${home}/.claude/.loop-state`;
    const command = `cp ${root}/pr-owner-other/x ${root}/pr-owner/acme--widgets--5/owner.json`;
    const env = { HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1', CLAUDE_LOOP_MAX: '20' };
    assertPreToolUseDeny(await runHook(HOOK, { session_id: 'owner', tool_name: 'Bash', tool_input: { command } }, { env }));
  } finally { rmTmp(home); }
});
