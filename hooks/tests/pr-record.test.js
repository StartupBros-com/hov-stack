'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execSync } = require('node:child_process');
const { runHook, assertQuietPassThrough, mkTmp, rmTmp, HOOKS_DIR } = require('./lib/harness');

const HOOK = 'PostToolUse/pr-record.js';
const HOOK_ABS = path.join(HOOKS_DIR, HOOK);

function tmpHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'pr-record-home-'));
}

function logFile(home) {
  return path.join(home, '.claude', 'logs', 'session-prs.jsonl');
}

function readRows(home) {
  const p = logFile(home);
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

// A real git repo stands in for the session cwd (same convention as
// verify-on-stop.test.js's gitProject()), so repoFromCwd/branchFromCwd
// exercise the real `git remote get-url origin` / `git branch --show-current`
// path instead of a mock.
function gitProject({ branch = 'feature/pr-record', remote = 'https://github.com/acme/widgets.git' } = {}) {
  const dir = mkTmp('pr-record-repo-');
  const g = (args) => execSync(`git ${args}`, { cwd: dir, stdio: 'ignore' });
  g(`init -q -b ${branch}`);
  g('config user.email t@t.invalid');
  g('config user.name t');
  g(`remote add origin ${remote}`);
  fs.writeFileSync(path.join(dir, 'f'), 'x');
  g('add f');
  g('commit -q -m seed');
  return dir;
}

test('happy: successful gh pr create appends exactly one record with all fields', async () => {
  const home = tmpHome();
  const repo = gitProject();
  try {
    const p = {
      session_id: 'sess-happy-1',
      cwd: repo,
      tool_name: 'Bash',
      tool_input: {
        command:
          'gh pr create --repo acme/widgets --draft --base main --head feature/pr-record --title x --body y',
      },
      tool_response: { stdout: 'https://github.com/acme/widgets/pull/42\n', stderr: '' },
    };
    assertQuietPassThrough(await runHook(HOOK, p, { env: { HOME: home } }));
    const rows = readRows(home);
    assert.strictEqual(rows.length, 1, 'exactly one record');
    const r = rows[0];
    assert.strictEqual(r.fp, 1);
    assert.strictEqual(r.session_id, 'sess-happy-1');
    assert.strictEqual(r.repo, 'acme/widgets');
    assert.strictEqual(r.pr, 42);
    assert.strictEqual(r.branch, 'feature/pr-record');
    assert.strictEqual(r.pending, false);
    assert.ok(typeof r.ts === 'string' && r.ts.length > 0, 'ts must be present');
  } finally {
    rmTmp(home);
    rmTmp(repo);
  }
});

test('repo/branch resolved from cwd when the command omits --repo/--head', async () => {
  const home = tmpHome();
  const repo = gitProject({ branch: 'feature/cwd-derived', remote: 'git@github.com:acme/other.git' });
  try {
    const p = {
      session_id: 'sess-cwd-1',
      cwd: repo,
      tool_input: { command: 'gh pr create --title x --body y' },
      tool_response: { stdout: 'https://github.com/acme/other/pull/5\n' },
    };
    await runHook(HOOK, p, { env: { HOME: home } });
    const rows = readRows(home);
    assert.strictEqual(rows.length, 1);
    // repo comes from the extracted URL (authoritative), branch from cwd git state.
    assert.strictEqual(rows[0].repo, 'acme/other');
    assert.strictEqual(rows[0].branch, 'feature/cwd-derived');
  } finally {
    rmTmp(home);
    rmTmp(repo);
  }
});

test('non gh-pr-create Bash command: no write, pass-through', async () => {
  const home = tmpHome();
  try {
    const p = { session_id: 's1', cwd: '/tmp', tool_input: { command: 'echo hi' }, tool_response: 'hi' };
    assertQuietPassThrough(await runHook(HOOK, p, { env: { HOME: home } }));
    assert.strictEqual(readRows(home).length, 0);
  } finally {
    rmTmp(home);
  }
});

test('edge: extraction fails -> pending record written; resolvePending completes it via a gh PATH shim', async () => {
  const home = tmpHome();
  const repo = gitProject({ branch: 'feature/pending-branch' });
  const binDir = mkTmp('pr-record-bin-');
  // Fake `gh`: `gh pr list --repo R --head B --json number` -> one open PR, #99.
  fs.writeFileSync(path.join(binDir, 'gh'), '#!/usr/bin/env bash\necho \'[{"number":99}]\'\n');
  fs.chmodSync(path.join(binDir, 'gh'), 0o755);
  try {
    const p = {
      session_id: 'sess-pending-1',
      cwd: repo,
      tool_input: {
        command: 'gh pr create --repo acme/widgets --head feature/pending-branch --title x --body y',
      },
      // No URL in the tool result -- extraction must fail and fall back to pending.
      tool_response: { stdout: 'draft pull request created (no URL captured)', stderr: '' },
    };
    assertQuietPassThrough(await runHook(HOOK, p, { env: { HOME: home } }));
    let rows = readRows(home);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0].pending, true);
    assert.strictEqual(rows[0].pr, null);
    assert.strictEqual(rows[0].repo, 'acme/widgets');
    assert.strictEqual(rows[0].branch, 'feature/pending-branch');

    // resolvePending() is exported for a future Stop-time unit to import
    // in-process (not spawned) -- exercise it the same way here.
    delete require.cache[require.resolve(HOOK_ABS)];
    const mod = require(HOOK_ABS);
    const prevHome = process.env.HOME;
    const prevPath = process.env.PATH;
    process.env.HOME = home;
    process.env.PATH = `${binDir}:${process.env.PATH}`;
    let tally;
    try {
      tally = mod.resolvePending('sess-pending-1');
    } finally {
      process.env.HOME = prevHome;
      process.env.PATH = prevPath;
    }
    assert.strictEqual(tally.resolved, 1, `expected 1 resolved, got ${JSON.stringify(tally)}`);
    rows = readRows(home);
    assert.strictEqual(rows.length, 2, 'the pending row stays; a new completed row is appended');
    const completed = rows.find((r) => r.pending === false);
    assert.ok(completed, 'resolvePending must append a completed row');
    assert.strictEqual(completed.pr, 99);
    assert.strictEqual(completed.repo, 'acme/widgets');
    assert.strictEqual(completed.branch, 'feature/pending-branch');
    assert.strictEqual(completed.session_id, 'sess-pending-1');
  } finally {
    rmTmp(home);
    rmTmp(repo);
    rmTmp(binDir);
  }
});

test('edge: duplicate creation events for the same PR append once', async () => {
  const home = tmpHome();
  const repo = gitProject();
  try {
    const p = {
      session_id: 'sess-dup-1',
      cwd: repo,
      tool_input: { command: 'gh pr create --repo acme/widgets --head feature/pr-record --title x --body y' },
      tool_response: { stdout: 'https://github.com/acme/widgets/pull/7\n' },
    };
    await runHook(HOOK, p, { env: { HOME: home } });
    await runHook(HOOK, p, { env: { HOME: home } }); // duplicate observation of the same PR
    const rows = readRows(home);
    assert.strictEqual(rows.length, 1, 'dedupe by repo+pr must collapse the duplicate to one row');
  } finally {
    rmTmp(home);
    rmTmp(repo);
  }
});

test('edge: absent payload session_id -> no write, no crash', async () => {
  const home = tmpHome();
  try {
    const p = {
      cwd: '/tmp',
      tool_input: { command: 'gh pr create --repo acme/widgets --head x --title y --body z' },
      tool_response: { stdout: 'https://github.com/acme/widgets/pull/1\n' },
    };
    assertQuietPassThrough(await runHook(HOOK, p, { env: { HOME: home } }));
    assert.strictEqual(readRows(home).length, 0);
  } finally {
    rmTmp(home);
  }
});

test('error: unwritable log dir -> silent, no throw', async () => {
  const home = tmpHome();
  // Block $HOME/.claude from ever being a directory: mkdirSync(..., {recursive})
  // throws ENOTDIR against a same-named file, deterministically (no reliance on
  // permission bits, which behave differently under root/sandboxed uids).
  fs.writeFileSync(path.join(home, '.claude'), 'blocker');
  try {
    const p = {
      session_id: 'sess-unwritable-1',
      cwd: '/tmp',
      tool_input: { command: 'gh pr create --repo acme/widgets --head x --title y --body z' },
      tool_response: { stdout: 'https://github.com/acme/widgets/pull/1\n' },
    };
    const res = await runHook(HOOK, p, { env: { HOME: home } });
    assertQuietPassThrough(res);
    assert.strictEqual(res.stderr, '', 'must not leak a stack trace to stderr');
  } finally {
    rmTmp(home);
  }
});

test('malformed input passes through', async () => {
  const home = tmpHome();
  try {
    assertQuietPassThrough(await runHook(HOOK, 'not-json{{{', { env: { HOME: home } }));
  } finally {
    rmTmp(home);
  }
});
