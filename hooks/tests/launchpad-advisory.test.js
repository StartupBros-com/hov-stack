'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execSync, execFileSync } = require('node:child_process');
const { runHook, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'SessionStart/launchpad-advisory.js';

function gexec(dir, args) {
  execSync(`git ${args}`, { cwd: dir, env: process.env, stdio: 'ignore' });
}

// Repo with two commits pushed to a real, file-backed bare remote (no network).
// Keep the remote and its writer under .git so they cannot count as local dirt.
// Callers then park/detach/dirty it per scenario.
function repo({ under } = {}) {
  const base = mkTmp('lpa-');
  const dir = under ? path.join(base, under) : base;
  fs.mkdirSync(dir, { recursive: true });
  const g = (args) => gexec(dir, args);
  g('init -q -b main');
  g('config user.email test@test.invalid');
  g('config user.name test');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'one\n');
  g('add -- a.txt');
  g('commit -q -m one');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'two\n');
  g('commit -q -am two');
  const remote = path.join(dir, '.git', 'origin.git');
  execFileSync('git', ['init', '--bare', '-q', '-b', 'main', remote]);
  execFileSync('git', ['remote', 'add', 'origin', remote], { cwd: dir });
  g('push -q -u origin main');
  g('symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main');
  return { base, dir, g, remote };
}

function advanceRemote({ dir, remote }, file = 'a.txt') {
  const writer = path.join(dir, '.git', 'writer');
  execFileSync('git', ['clone', '-q', remote, writer]);
  gexec(writer, 'config user.email test@test.invalid');
  gexec(writer, 'config user.name test');
  fs.writeFileSync(path.join(writer, file), 'upstream three\n');
  execFileSync('git', ['add', '--', file], { cwd: writer });
  gexec(writer, 'commit -q -m three');
  gexec(writer, 'push -q origin main');
  return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: writer, encoding: 'utf8' }).trim();
}

function branchOf(dir) {
  return execSync('git branch --show-current', { cwd: dir, encoding: 'utf8' }).trim();
}

// Silent means byte-for-byte empty stdout with exit 0: SessionStart hook output
// becomes session context, so any stray output is context pollution.
function assertSilent(res) {
  assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
  assert.strictEqual(res.stdout, '', 'expected no advisory output');
}

test('non-git directory: silent', async () => {
  const dir = mkTmp('lpa-plain-');
  try {
    assertSilent(await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' }));
  } finally {
    rmTmp(dir);
  }
});

test('healthy checkout on default branch: silent', async () => {
  const { base, dir } = repo();
  try {
    assertSilent(await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' }));
    assert.ok(fs.existsSync(path.join(dir, '.git', 'FETCH_HEAD')), 'healthy silence must follow a real fetch');
  } finally {
    rmTmp(base);
  }
});

test('incoming dirty-path collision reports the exact refusal and preserves local bytes', async () => {
  const fixture = repo();
  const { base, dir, g } = fixture;
  try {
    const before = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dir, encoding: 'utf8' });
    advanceRemote(fixture);
    const local = Buffer.from('operator local bytes\n\x00not upstream\n');
    fs.writeFileSync(path.join(dir, 'a.txt'), local);
    g('config merge.autostash true'); // the helper must still refuse, never stash
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /WARN launchpad .*: ff-only merge failed, not touched/);
    assert.match(res.stdout, /WARN: 1 locally-modified file\(s\) are in this update's path; commit or revert them first\./);
    assert.ok(res.stdout.includes('          a.txt'), 'preserve the helper\'s indented blocking path');
    assert.match(res.stdout, /1 commits behind origin\/main/);
    assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed|active or dirty state is never touched/);
    assert.deepStrictEqual(fs.readFileSync(path.join(dir, 'a.txt')), local);
    assert.strictEqual(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dir, encoding: 'utf8' }), before);
    assert.strictEqual(execFileSync('git', ['stash', 'list'], { cwd: dir, encoding: 'utf8' }), '');
  } finally {
    rmTmp(base);
  }
});

test('successful fast-forward carries unrelated dirty bytes and names the actual mutation', async () => {
  const fixture = repo();
  const { base, dir, g } = fixture;
  try {
    const target = advanceRemote(fixture, 'incoming.txt');
    const local = Buffer.from('unrelated operator bytes\n\x00preserve me\n');
    fs.writeFileSync(path.join(dir, 'a.txt'), local);
    g('config merge.autostash true');
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /fast-forwarded 1 commit\(s\), carried 1 unrelated local edit\(s\)/);
    assert.match(res.stdout, /Checkout is now fresh on main/);
    assert.match(res.stdout, /files on disk just changed.*re-read/i);
    assert.doesNotMatch(res.stdout, /self-heal declined|diagnostics|active or dirty state is never touched/i);
    assert.strictEqual(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dir, encoding: 'utf8' }).trim(), target);
    assert.strictEqual(fs.readFileSync(path.join(dir, 'incoming.txt'), 'utf8'), 'upstream three\n');
    assert.deepStrictEqual(fs.readFileSync(path.join(dir, 'a.txt')), local);
    assert.strictEqual(execFileSync('git', ['stash', 'list'], { cwd: dir, encoding: 'utf8' }), '');
  } finally {
    rmTmp(base);
  }
});

test('fetch failure is visible even when cached origin and HEAD match', async () => {
  const { base, dir, g } = repo();
  try {
    g('fetch -q origin'); // even a very recent FETCH_HEAD cannot hide this failure
    execFileSync('git', ['remote', 'set-url', 'origin', path.join(base, 'missing-origin.git')], { cwd: dir });
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /fetch failed \(offline\?\), skipped/);
    assert.match(res.stdout, /freshness not confirmed/);
    assert.match(res.stdout, /cached origin refs/i);
    assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed|active or dirty state is never touched/i);
  } finally {
    rmTmp(base);
  }
});

test('successful branch switch followed by failed fetch reports partial success, not freshness', async () => {
  const { base, dir, g } = repo();
  try {
    g('checkout -q -b parked HEAD~1');
    execFileSync('git', ['remote', 'set-url', 'origin', path.join(base, 'missing-origin.git')], { cwd: dir });
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /healed, switched 'parked' -> main/);
    assert.match(res.stdout, /fetch failed \(offline\?\), skipped/);
    assert.match(res.stdout, /files on disk just changed.*re-read/i);
    assert.match(res.stdout, /freshness not confirmed/);
    assert.doesNotMatch(res.stdout, /Checkout is now fresh|active or dirty state is never touched/);
    assert.strictEqual(branchOf(dir), 'main');
    assert.strictEqual(execFileSync('git', ['rev-parse', 'parked'], { cwd: dir, encoding: 'utf8' }).trim(),
      execFileSync('git', ['rev-parse', 'main~1'], { cwd: dir, encoding: 'utf8' }).trim(), 'parked branch ref survives');
    assert.strictEqual(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'two\n');
  } finally {
    rmTmp(base);
  }
});

// Copied hooks exercise the helper's process/output boundary without a
// production-only test override. These scripts are protocol controls, not
// evidence of live refresh or checkout activation.
async function controlledHelper(script) {
  const tree = mkTmp('lpa-helper-');
  const { base, dir } = repo();
  const hooks = path.join(tree, 'hooks');
  try {
    fs.mkdirSync(path.join(hooks, 'SessionStart'), { recursive: true });
    fs.mkdirSync(path.join(hooks, 'lib'));
    fs.mkdirSync(path.join(tree, 'scripts'));
    fs.copyFileSync(path.join(__dirname, '..', HOOK), path.join(hooks, HOOK));
    fs.copyFileSync(path.join(__dirname, '..', 'lib', 'hook-output.js'), path.join(hooks, 'lib', 'hook-output.js'));
    fs.symlinkSync(path.join(__dirname, '..', '..', 'scripts', 'repo-route.py'), path.join(tree, 'scripts', 'repo-route.py'));
    fs.writeFileSync(path.join(tree, 'scripts', 'launchpad-freshen.sh'), `#!/usr/bin/env bash\n${script}\n`);
    return await runHook(path.join(hooks, HOOK), { cwd: dir, hook_event_name: 'SessionStart' });
  } finally {
    rmTmp(tree);
    rmTmp(base);
  }
}

test('helper nonzero exit preserves stdout diagnostics without exposing stderr or stacks', async () => {
  const res = await controlledHelper("printf '%s\\n' 'WARN launchpad fixture: controlled refusal, not healed' '  collision/path.txt'\nprintf '%s\\n' 'credential-bearing-stderr-DO-NOT-EXPOSE' >&2\nexit 23");
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /exited with status 23/);
  assert.ok(res.stdout.includes('WARN launchpad fixture: controlled refusal, not healed\n  collision/path.txt'));
  assert.match(res.stdout, /freshness not confirmed/);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed|credential-bearing-stderr|Command failed|Error:|at heal/i);
  assert.strictEqual(res.stderr, '');
});

test('helper timeout preserves partial stdout and explicitly reports the bounded wait', { timeout: 15000 }, async () => {
  const res = await controlledHelper("printf '%s\\n' 'WARN launchpad fixture: waiting for fetch'\nexec sleep 30");
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /timed out after 7000ms/);
  assert.match(res.stdout, /WARN launchpad fixture: waiting for fetch/);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed|Command failed|Error:|at heal/i);
  assert.strictEqual(res.stderr, '');
});

test('helper with no stdout reports missing detail on both zero and nonzero exit', async (t) => {
  for (const status of [0, 19]) {
    await t.test(`exit ${status}`, async () => {
      const res = await controlledHelper(`exit ${status}`);
      assert.strictEqual(res.code, 0, res.stderr);
      assert.match(res.stdout, /no helper stdout detail/i);
      if (status !== 0) assert.match(res.stdout, /exited with status 19/);
      assert.match(res.stdout, /freshness not confirmed/);
      assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed/i);
    });
  }
});

test('helper branch-switch output without refresh completion is reported as incomplete', async () => {
  const res = await controlledHelper('git -C "$2" switch -q --detach HEAD~1\ngit -C "$2" switch -q main\nprintf "%s\\n" "launchpad fixture: healed, switched \'DETACHED HEAD\' -> main (branch left intact)"');
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /healed, switched 'DETACHED HEAD' -> main/);
  assert.match(res.stdout, /files on disk just changed.*re-read/i);
  assert.match(res.stdout, /no refresh completion detail/i);
  assert.match(res.stdout, /freshness not confirmed/);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh/);
});

test('nonempty helper stdout is diagnostic, not evidence of mutation or freshness', async () => {
  const res = await controlledHelper("printf '%s\\n' 'WARN launchpad fixture: not healed; would have fast-forwarded after manual repair'");
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /not healed; would have fast-forwarded after manual repair/);
  assert.match(res.stdout, /freshness not confirmed/);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed/i);
});

test('helper diagnostics preserve exact early paths and explicitly bound long line lists', async () => {
  const lines = ['WARN launchpad fixture: ff-only merge failed, not touched',
    ...Array.from({ length: 80 }, (_, i) => `  blocker/path-${String(i).padStart(3, '0')}.txt`)];
  const res = await controlledHelper(`printf '%s\\n' ${lines.map((line) => `'${line}'`).join(' ')}`);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.ok(res.stdout.includes(`${lines[0]}\n${lines[1]}`), 'preserve diagnostic text and path indentation');
  assert.match(res.stdout, /helper stdout truncated/i);
  assert.ok(!res.stdout.includes('blocker/path-079.txt'), 'long lists must be capped');
  assert.ok(res.stdout.length < 6000, `bounded session context, got ${res.stdout.length} characters`);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed/i);
});

test('helper diagnostics explicitly bound a single overlong line', async () => {
  const res = await controlledHelper(`printf '%s\\n' 'WARN launchpad fixture: ${'x'.repeat(12000)}'`);
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /WARN launchpad fixture: xxx/);
  assert.match(res.stdout, /helper stdout truncated/i);
  assert.ok(res.stdout.length < 6000, `bounded session context, got ${res.stdout.length} characters`);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed/i);
});

test('helper stdout capture overflow is explicit rather than a silent execution failure', async () => {
  const res = await controlledHelper("printf '%s\\n' 'WARN launchpad fixture: oversized diagnostics'\nprintf '%200000s' ''");
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /exceeded.*stdout capture limit/i);
  assert.match(res.stdout, /WARN launchpad fixture: oversized diagnostics/);
  assert.match(res.stdout, /helper stdout truncated/i);
  assert.ok(res.stdout.length < 6000, `bounded session context, got ${res.stdout.length} characters`);
  assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed|Command failed|Error:/i);
});

test('in-progress merge is diagnosed even when cached HEAD is current and never mutated', async () => {
  const { base, dir } = repo();
  try {
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dir, encoding: 'utf8' });
    fs.writeFileSync(path.join(dir, '.git', 'MERGE_HEAD'), head);
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /rebase\/merge in progress, not touched/);
    assert.doesNotMatch(res.stdout, /Checkout is now fresh|files on disk just changed|active or dirty state is never touched/i);
    assert.strictEqual(fs.readFileSync(path.join(dir, '.git', 'MERGE_HEAD'), 'utf8'), head);
    assert.strictEqual(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: dir, encoding: 'utf8' }), head);
    assert.strictEqual(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'two\n');
  } finally {
    rmTmp(base);
  }
});

test('parked with recent UNPUSHED work: heal declines, advisory names the branch', async () => {
  const { base, dir, g } = repo();
  try {
    g('checkout -q -b parked HEAD~1');
    fs.writeFileSync(path.join(dir, 'wip.txt'), 'local-only\n');
    g('add -- wip.txt');
    g('commit -q -m local-only'); // fresh tip, reachable from no remote ref
    const res = await runHook(HOOK, { cwd: base, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /\[launchpad-advisory\]/);
    assert.match(res.stdout, /parked on branch 'parked'/);
    assert.match(res.stdout, /self-heal declined/);
    assert.strictEqual(branchOf(dir), 'parked', 'recent unpushed work must never be yanked');
  } finally {
    rmTmp(base);
  }
});

test('parked but tip is pushed: self-heals back to the default branch', async () => {
  const { base, dir } = repo();
  try {
    gexec(dir, 'checkout -q -b parked HEAD~1'); // tip = commit one, an ancestor of origin/main
    const res = await runHook(HOOK, { cwd: base, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /healed, switched 'parked' -> main/);
    assert.strictEqual(branchOf(dir), 'main');
  } finally {
    rmTmp(base);
  }
});

test('detached HEAD with pushed tip: self-heals back to the default branch', async () => {
  const { base, dir } = repo();
  try {
    gexec(dir, 'checkout -q --detach');
    const res = await runHook(HOOK, { cwd: base, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /healed, switched 'DETACHED HEAD' -> main/);
    assert.strictEqual(branchOf(dir), 'main');
  } finally {
    rmTmp(base);
  }
});

test('parked with tracked modifications: never healed, advisory shows dirt', async () => {
  const { base, dir } = repo();
  try {
    gexec(dir, 'checkout -q -b parked HEAD~1');
    fs.writeFileSync(path.join(dir, 'a.txt'), 'local drift\n'); // tracked modification
    const res = await runHook(HOOK, { cwd: base, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /parked on branch 'parked'/);
    assert.match(res.stdout, /uncommitted change/);
    assert.strictEqual(branchOf(dir), 'parked', 'dirty state is never touched');
  } finally {
    rmTmp(base);
  }
});

test('inside a .claude/worktrees path: rebase phrasing, no heal attempted', async () => {
  const { base, dir } = repo({ under: path.join('.claude', 'worktrees', 'wt1') });
  try {
    gexec(dir, 'checkout -q -b task HEAD~1'); // behind origin/main by 1, tip pushed
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /Rebase on origin\/main/);
    assert.doesNotMatch(res.stdout, /healed/);
    assert.strictEqual(branchOf(dir), 'task', 'worktrees must never be healed off their branch');
  } finally {
    rmTmp(base);
  }
});

test('worktree path fully up to date: silent', async () => {
  const { base, dir } = repo({ under: path.join('.claude', 'worktrees', 'wt2') });
  try {
    assertSilent(await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' }));
  } finally {
    rmTmp(base);
  }
});

test('malformed input: silent, exit 0', async () => {
  assertSilent(await runHook(HOOK, 'not-json{{{'));
});

test('checkout path metacharacters are passed as argv, never evaluated by a shell', async () => {
  const marker = path.join(mkTmp('lpa-marker-'), 'executed');
  const { base, dir } = repo({ under: `$(touch ${marker})` });
  try {
    await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.strictEqual(fs.existsSync(marker), false, 'checkout path executed command substitution');
  } finally {
    rmTmp(base);
    rmTmp(path.dirname(marker));
  }
});

function routeResolver(base) {
  const resolver = path.join(base, 'route-resolver.py');
  fs.writeFileSync(resolver, '#!/usr/bin/env python3\nimport os\nprint(os.environ["ROUTE_RESULT"])\n', { mode: 0o755 });
  return resolver;
}

test('enrolled warn/enforce route without host authority skips self-heal', async () => {
  const { base, dir } = repo();
  try {
    gexec(dir, 'checkout -q -b parked HEAD~1');
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' }, {
      env: {
        REPO_ROUTE_RESOLVER: routeResolver(base),
        ROUTE_RESULT: JSON.stringify({ classification: 'unregistered', route: 'r', mode: 'enforce' }),
      },
    });
    assert.match(res.stdout, /no canonical authority registered on this host/);
    assert.strictEqual(branchOf(dir), 'parked', 'authority-missing checkout must not self-heal');
  } finally {
    rmTmp(base);
  }
});

test('missing canonical launchpad leaves a surviving sibling untouched', async () => {
  const { base, dir } = repo();
  try {
    gexec(dir, 'checkout -q -b task HEAD~1');
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' }, {
      env: {
        REPO_ROUTE_RESOLVER: routeResolver(base),
        ROUTE_RESULT: JSON.stringify({
          classification: 'canonical-sibling', route: 'r', mode: 'observe',
          canonical_missing: true, canonical_path: '/missing/launchpad',
        }),
      },
    });
    assert.match(res.stdout, /canonical-sibling/);
    assert.match(res.stdout, /self-heal was skipped/);
    assert.strictEqual(branchOf(dir), 'task', 'surviving sibling must remain on its branch');
  } finally {
    rmTmp(base);
  }
});

test('missing canonical launchpad blocks observe-mode healing of an independent clone', async () => {
  const { base, dir } = repo();
  try {
    gexec(dir, 'checkout -q -b parked HEAD~1');
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' }, {
      env: {
        REPO_ROUTE_RESOLVER: routeResolver(base),
        ROUTE_RESULT: JSON.stringify({
          classification: 'noncanonical-independent-clone', route: 'r', mode: 'observe',
          canonical_missing: true, canonical_path: '/missing/launchpad',
        }),
      },
    });
    assert.match(res.stdout, /canonical authority.*missing/i);
    assert.match(res.stdout, /self-heal was skipped/);
    assert.strictEqual(branchOf(dir), 'parked', 'independent clone must remain untouched after authority loss');
  } finally {
    rmTmp(base);
  }
});

// --- Windows-mount guard -----------------------------------------------------
// 78 sessions in one week launched on /mnt/c and the advisory said nothing,
// because the Windows-side repo has no remote: defaultBranch() returned null and
// run() bailed before printing. The mount check therefore runs FIRST, before any
// git call, and must not depend on the cwd being a repo at all.

test('mount: a session on /mnt/c is warned, and told where to go', async () => {
  // A fake native home holding a same-named repo, passed as an explicit HOME
  // override. The harness sandboxes HOME by default (issue #526), so the
  // destination this asserts on is built here, not leaked from the runner.
  const home = mkTmp('lpa-home-');
  fs.mkdirSync(path.join(home, 'dotfiles', '.git'), { recursive: true });
  try {
    const res = await runHook(
      HOOK,
      { cwd: '/mnt/c/Users/someone/dotfiles', hook_event_name: 'SessionStart' },
      { env: { HOME: home } }
    );
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /WINDOWS MOUNT/);
    // The destination must be the resolved native repo, never a guess.
    assert.ok(
      res.stdout.includes(`cd ${path.join(home, 'dotfiles')}`),
      `advisory must name the native repo under the test HOME; got: ${res.stdout}`
    );
  } finally {
    rmTmp(home);
  }
});

test('mount: fires even when the cwd is not a git repo at all', async () => {
  // The original bug: every git-dependent path returned '' first.
  const base = mkTmp('lpa-mount-');
  try {
    const res = await runHook(HOOK, { cwd: '/mnt/c/does/not/exist/anywhere', hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0);
    assert.match(res.stdout, /WINDOWS MOUNT/);
  } finally {
    rmTmp(base);
  }
});

test('mount: names the three silent consequences, not just slowness', async () => {
  const res = await runHook(HOOK, { cwd: '/mnt/c/Users/someone', hook_event_name: 'SessionStart' });
  assert.match(res.stdout, /slower/);          // perf
  assert.match(res.stdout, /slug/);            // misfiled per-project state
  assert.match(res.stdout, /gh/);              // broken tooling
});

test('mount: any drive letter, not just c', async () => {
  const res = await runHook(HOOK, { cwd: '/mnt/d/some/project', hook_event_name: 'SessionStart' });
  assert.match(res.stdout, /WINDOWS MOUNT/);
});

test('mount: native paths never trigger it', async () => {
  const { base, dir } = repo();
  try {
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' });
    assert.doesNotMatch(res.stdout, /WINDOWS MOUNT/);
  } finally {
    rmTmp(base);
  }
});

test('mount: /mnt-prefixed native dirs are not mistaken for a mount', async () => {
  // /mnt/c matches; /mntlogs or /mnt/data-store (multi-char) must not.
  const res = await runHook(HOOK, { cwd: '/mntlogs/project', hook_event_name: 'SessionStart' });
  assert.doesNotMatch(res.stdout, /WINDOWS MOUNT/);
});

// Stray .git heal (lib/stray-dot-git.js, dotfiles#1553). Each case gets its own
// fake filesystem root; the harness default root is empty, which is why every
// case above stays silent.
function strayRoot() {
  const root = mkTmp('lpa-stray-');
  fs.mkdirSync(path.join(root, 'tmp', '.git'), { recursive: true }); // empty: git rejects it
  return root;
}

test('stray .git: moved aside first, even when the cwd is not a repo', async () => {
  const root = strayRoot();
  const dir = mkTmp('lpa-plain-');
  try {
    const res = await runHook(HOOK, { cwd: dir, hook_event_name: 'SessionStart' },
      { env: { STRAY_DOT_GIT_FS_ROOT: root, PAPERCUT_STORE: path.join(root, 'store') } });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /\[stray-dot-git\] moved stray \/tmp\/\.git \(empty directory/);
    assert.doesNotMatch(res.stdout, /\[launchpad-advisory\]/);
    assert.ok(!fs.existsSync(path.join(root, 'tmp', '.git')), 'stray must be gone');
    assert.strictEqual(fs.readdirSync(path.join(root, 'store')).length, 1, 'one papercut store file written');
  } finally {
    rmTmp(root);
    rmTmp(dir);
  }
});

test('stray .git: its note precedes the launch-checkout advisory', async () => {
  const root = strayRoot();
  const { base, dir, g } = repo();
  try {
    g('checkout -q -b parked HEAD~1');
    fs.writeFileSync(path.join(dir, 'wip.txt'), 'local-only\n');
    g('add -- wip.txt');
    g('commit -q -m local-only');
    const res = await runHook(HOOK, { cwd: base, hook_event_name: 'SessionStart' },
      { env: { STRAY_DOT_GIT_FS_ROOT: root, PAPERCUT_STORE: path.join(root, 'store') } });
    assert.strictEqual(res.code, 0, res.stderr);
    const stray = res.stdout.indexOf('[stray-dot-git]');
    const launch = res.stdout.indexOf('[launchpad-advisory]');
    assert.ok(stray >= 0 && launch > stray, `stray note must come first:\n${res.stdout}`);
    assert.match(res.stdout, /parked on branch 'parked'/);
  } finally {
    rmTmp(root);
    rmTmp(base);
  }
});

test('stray .git: a lib that fails to load costs only its own note', async () => {
  // A copy of the hook beside a stray-dot-git.js that throws on require; the
  // real scripts dir sits where the hook resolves ../../scripts.
  const tree = mkTmp('lpa-brokenlib-');
  const hooks = path.join(tree, 'hooks');
  const { base, dir, g } = repo();
  try {
    fs.mkdirSync(path.join(hooks, 'SessionStart'), { recursive: true });
    fs.mkdirSync(path.join(hooks, 'lib'));
    fs.symlinkSync(path.join(__dirname, '..', '..', 'scripts'), path.join(tree, 'scripts'));
    fs.copyFileSync(path.join(__dirname, '..', HOOK), path.join(hooks, HOOK));
    fs.copyFileSync(path.join(__dirname, '..', 'lib', 'hook-output.js'), path.join(hooks, 'lib', 'hook-output.js'));
    fs.writeFileSync(path.join(hooks, 'lib', 'stray-dot-git.js'), 'throw new Error("partial deploy");\n');
    g('checkout -q -b parked HEAD~1');
    fs.writeFileSync(path.join(dir, 'wip.txt'), 'local-only\n');
    g('add -- wip.txt');
    g('commit -q -m local-only');
    const res = await runHook(path.join(hooks, HOOK), { cwd: base, hook_event_name: 'SessionStart' });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.match(res.stdout, /parked on branch 'parked'/);
    assert.doesNotMatch(res.stdout, /\[stray-dot-git\]/);
  } finally {
    rmTmp(tree);
    rmTmp(base);
  }
});
