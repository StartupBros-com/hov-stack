'use strict';
/**
 * lib/workspace-trust.js: that the home directory and the repositories under
 * ~/SITES become trusted in Claude Code's global config, that the write keeps
 * everything else and follows Claude Code's lock-and-rename protocol, and
 * that SessionStart runs it silently.
 *
 * Every case builds its own home with a .claude.json and a SITES root. The
 * home starts with the entry Claude Code's trust dialog leaves there, fields
 * kept and trust false, since that dialog never persists home trust. The
 * planted negatives sit beside the repositories that must be seeded: a plain
 * directory, a hidden repository, a regular file, an entry outside the root,
 * and an already-trusted entry carrying other fields.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { runHook, mkTmp, rmTmp } = require('./lib/harness');

const wt = require('../lib/workspace-trust');

// No CLAUDE_CONFIG_DIR and no custom OAuth: the config is <home>/.claude.json.
const ENV = {};

let home;
beforeEach(() => { home = fs.realpathSync(mkTmp('wt-home-')); });
afterEach(() => rmTmp(home));

const cfgFile = () => path.join(home, '.claude.json');
const sites = (...p) => path.join(home, 'SITES', ...p);
const seed = (opts = {}) => wt.seed({ home, env: ENV, ...opts });
const readCfg = () => JSON.parse(fs.readFileSync(cfgFile(), 'utf8'));

function writeCfg(obj, file = cfgFile()) {
  fs.writeFileSync(file, JSON.stringify(obj, null, 2), { mode: 0o600 });
}

// A gitfile repository here names a gitdir with no commondir (a separate git
// dir, not a linked worktree), so Claude Code keys it on itself.
function plantRepo(name, { gitfile = false } = {}) {
  fs.mkdirSync(sites(name), { recursive: true });
  if (gitfile) fs.writeFileSync(sites(name, '.git'), 'gitdir: /elsewhere/.git/worktrees/x\n');
  else fs.mkdirSync(sites(name, '.git'));
}

function git(dir, ...args) {
  execFileSync('git', ['-c', 'user.name=test', '-c', 'user.email=test@test.invalid', ...args],
    { cwd: dir, env: process.env, stdio: 'ignore' });
}

function gitRepo(dir) {
  fs.mkdirSync(dir, { recursive: true });
  git(dir, 'init', '-q', '-b', 'main');
  git(dir, 'commit', '-q', '--allow-empty', '-m', 'one');
}

function baseCfg() {
  return {
    numStartups: 7,
    oauthAccount: { accountUuid: 'u-1' },
    projects: {
      [home]: { hasTrustDialogAccepted: false, lastSessionId: 's-1' },
      [sites('kept')]: { hasTrustDialogAccepted: true, allowedTools: ['Bash'], lastCost: 1.5 },
      [sites('stale')]: { hasTrustDialogAccepted: false, lastCost: 2 },
      '/elsewhere/repo': { hasTrustDialogAccepted: false },
    },
  };
}

function plantAll() {
  plantRepo('kept');
  plantRepo('stale');
  plantRepo('fresh');
  plantRepo('linked', { gitfile: true });
  plantRepo('.hidden');
  fs.mkdirSync(sites('plain'));
  fs.writeFileSync(sites('notes.txt'), 'not a directory\n');
}

test('seeds the home directory and every repository under the root that is not trusted, and nothing else', () => {
  plantAll();
  writeCfg(baseCfg());

  const r = seed();

  assert.strictEqual(r.status, 'seeded');
  assert.deepStrictEqual(r.added, [home, sites('fresh'), sites('linked'), sites('stale')]);
  const expected = baseCfg();
  // An existing entry keeps its fields; a new one gets Claude Code's default shape.
  expected.projects[home] = { hasTrustDialogAccepted: true, lastSessionId: 's-1' };
  expected.projects[sites('stale')] = { hasTrustDialogAccepted: true, lastCost: 2 };
  expected.projects[sites('fresh')] = { ...wt.NEW_ENTRY, hasTrustDialogAccepted: true };
  expected.projects[sites('linked')] = { ...wt.NEW_ENTRY, hasTrustDialogAccepted: true };
  assert.deepStrictEqual(readCfg(), expected);
});

test('write matches Claude Code\'s own: 2-space JSON, no trailing newline, mode kept, no temp or lock left', () => {
  plantRepo('fresh');
  writeCfg(baseCfg());
  fs.chmodSync(cfgFile(), 0o600);

  assert.strictEqual(seed().status, 'seeded');

  const text = fs.readFileSync(cfgFile(), 'utf8');
  assert.strictEqual(text, JSON.stringify(JSON.parse(text), null, 2));
  assert.strictEqual(fs.statSync(cfgFile()).mode & 0o777, 0o600);
  assert.deepStrictEqual(fs.readdirSync(home).sort(), ['.claude.json', 'SITES']);
});

test('nothing missing: no lock taken, file not rewritten', () => {
  plantRepo('kept');
  const cfg = baseCfg();
  cfg.projects[home].hasTrustDialogAccepted = true;
  writeCfg(cfg);
  const before = fs.statSync(cfgFile());
  // A held lock proves the check never waits on it when there is nothing to add.
  fs.mkdirSync(`${cfgFile()}.lock`);

  const r = seed({ waitMs: 0 });

  assert.strictEqual(r.status, 'current');
  const after = fs.statSync(cfgFile());
  assert.strictEqual(after.ino, before.ino);
  assert.strictEqual(after.mtimeMs, before.mtimeMs);
});

test('second run after a seed is a no-op', () => {
  plantAll();
  writeCfg(baseCfg());
  assert.strictEqual(seed().status, 'seeded');
  const bytes = fs.readFileSync(cfgFile(), 'utf8');

  assert.strictEqual(seed().status, 'current');
  assert.strictEqual(fs.readFileSync(cfgFile(), 'utf8'), bytes);
});

test('a lock held past the wait defers the write and is left in place', () => {
  plantRepo('fresh');
  writeCfg(baseCfg());
  const bytes = fs.readFileSync(cfgFile(), 'utf8');
  fs.mkdirSync(`${cfgFile()}.lock`);

  const r = seed({ waitMs: 60 });

  assert.strictEqual(r.status, 'locked');
  assert.strictEqual(fs.readFileSync(cfgFile(), 'utf8'), bytes);
  assert.ok(fs.statSync(`${cfgFile()}.lock`).isDirectory(), 'another holder\'s lock must survive');
});

test('a lock released during the wait is taken and the write lands', async () => {
  plantRepo('fresh');
  writeCfg(baseCfg());
  fs.mkdirSync(`${cfgFile()}.lock`);
  // seed() blocks this thread while it polls, so release from another process.
  const { spawn } = require('node:child_process');
  const releaser = spawn(process.execPath, ['-e',
    `setTimeout(() => require('fs').rmdirSync(${JSON.stringify(`${cfgFile()}.lock`)}), 150)`]);
  const exited = new Promise((resolve) => releaser.on('exit', resolve));

  const r = seed({ waitMs: 3000 });
  await exited;

  assert.strictEqual(r.status, 'seeded');
  assert.strictEqual(readCfg().projects[sites('fresh')].hasTrustDialogAccepted, true);
  assert.throws(() => fs.statSync(`${cfgFile()}.lock`), /ENOENT/);
});

test('a save that lands while the lock is held is built on, not overwritten', async () => {
  plantRepo('fresh');
  plantRepo('stale');
  writeCfg(baseCfg());
  fs.mkdirSync(`${cfgFile()}.lock`);
  // Another writer saves under the lock after seed()'s first read: a new
  // top-level key, and 'stale' trusted with a field of its own.
  const saved = baseCfg();
  saved.lastSave = 'peer';
  saved.projects[sites('stale')] = { hasTrustDialogAccepted: true, marker: 'peer' };
  const { spawn } = require('node:child_process');
  const peer = spawn(process.execPath, ['-e', `const fs = require('fs'); setTimeout(() => {
    fs.writeFileSync(${JSON.stringify(cfgFile())}, ${JSON.stringify(JSON.stringify(saved, null, 2))});
    fs.rmdirSync(${JSON.stringify(`${cfgFile()}.lock`)});
  }, 150);`]);
  const exited = new Promise((resolve) => peer.on('exit', resolve));

  const r = seed({ waitMs: 3000 });
  await exited;

  assert.strictEqual(r.status, 'seeded');
  assert.deepStrictEqual(r.added, [home, sites('fresh')]);
  saved.projects[home] = { hasTrustDialogAccepted: true, lastSessionId: 's-1' };
  saved.projects[sites('fresh')] = { ...wt.NEW_ENTRY, hasTrustDialogAccepted: true };
  assert.deepStrictEqual(readCfg(), saved);
  assert.throws(() => fs.statSync(`${cfgFile()}.lock`), /ENOENT/);
});

test('a lock lost before the rename aborts the write: target kept, no temp left', () => {
  writeCfg(baseCfg());
  const bytes = fs.readFileSync(cfgFile(), 'utf8');

  assert.throws(() => wt.writeAtomic(cfgFile(), '{"clobbered": true}', () => false), { code: 'ECOMPROMISED' });

  assert.strictEqual(fs.readFileSync(cfgFile(), 'utf8'), bytes);
  assert.deepStrictEqual(fs.readdirSync(home), ['.claude.json']);
});

test('the lock is ours only while it is the same directory and too young to be judged stale', () => {
  const lockDir = `${cfgFile()}.lock`;
  fs.mkdirSync(lockDir);
  const { ino } = fs.lstatSync(lockDir);

  assert.strictEqual(wt.ownsLock(lockDir, { ino, at: Date.now() }), true);
  // Old enough that a peer may have taken it over with a reused inode.
  assert.strictEqual(wt.ownsLock(lockDir, { ino, at: Date.now() - wt.OWN_LOCK_MS }), false);
  assert.strictEqual(wt.ownsLock(lockDir, { ino: ino + 1, at: Date.now() }), false);
  fs.rmdirSync(lockDir);
  assert.strictEqual(wt.ownsLock(lockDir, { ino, at: Date.now() }), false);
});

test('a .git FIFO, or a gitdir naming a FIFO, never blocks the scan', { skip: process.platform === 'win32' }, () => {
  fs.mkdirSync(sites('pipe'), { recursive: true });
  execFileSync('mkfifo', [sites('pipe', '.git')]);
  const gitDir = path.join(home, 'trap', 'worktrees', 'x');
  fs.mkdirSync(gitDir, { recursive: true });
  execFileSync('mkfifo', [path.join(gitDir, 'commondir')]);
  fs.mkdirSync(sites('gitfile'));
  fs.writeFileSync(sites('gitfile', '.git'), `gitdir: ${gitDir}\n`);
  const lib = path.join(__dirname, '..', 'lib', 'workspace-trust.js');

  // A blocking read hangs the scan, so it runs in a child with a deadline.
  const out = execFileSync(process.execPath, ['-e',
    `process.stdout.write(JSON.stringify(require(${JSON.stringify(lib)}).repoKeys([${JSON.stringify(sites())}])))`],
  { timeout: 5000, encoding: 'utf8' });

  assert.deepStrictEqual(JSON.parse(out), [sites('gitfile'), sites('pipe')]);
});

test('no config file: nothing is created', () => {
  plantRepo('fresh');
  assert.strictEqual(seed().status, 'no-config');
  assert.strictEqual(fs.existsSync(cfgFile()), false);
});

for (const [label, text] of [
  ['truncated JSON', '{"projects": {'],
  ['a JSON array', '[]'],
  ['projects that is not an object', '{"projects": []}'],
]) {
  test(`unreadable config (${label}) is never rewritten`, () => {
    plantRepo('fresh');
    fs.writeFileSync(cfgFile(), text);
    assert.strictEqual(seed().status, 'unreadable');
    assert.strictEqual(fs.readFileSync(cfgFile(), 'utf8'), text);
  });
}

test('a symlinked config is written through to its target, the link kept', () => {
  plantRepo('fresh');
  fs.mkdirSync(path.join(home, 'real'));
  const target = path.join(home, 'real', 'claude.json');
  writeCfg(baseCfg(), target);
  fs.symlinkSync(target, cfgFile());

  assert.strictEqual(seed().status, 'seeded');

  assert.ok(fs.lstatSync(cfgFile()).isSymbolicLink());
  assert.strictEqual(JSON.parse(fs.readFileSync(target, 'utf8')).projects[sites('fresh')].hasTrustDialogAccepted, true);
});

test('a symlinked repository is keyed by its realpath, as Claude Code keys it', () => {
  const real = path.join(home, 'elsewhere', 'repo');
  fs.mkdirSync(path.join(real, '.git'), { recursive: true });
  fs.mkdirSync(sites());
  fs.symlinkSync(real, sites('alias'));
  writeCfg({ projects: {} });

  const r = seed();

  assert.deepStrictEqual(r.added, [home, real]);
  assert.strictEqual(readCfg().projects[sites('alias')], undefined);
});

test('a home with no entry gets Claude Code\'s default shape, keyed by its realpath', () => {
  plantRepo('kept');
  writeCfg({ projects: { [sites('kept')]: { hasTrustDialogAccepted: true } } });
  const linkDir = fs.realpathSync(mkTmp('wt-link-'));
  const link = path.join(linkDir, 'home');
  fs.symlinkSync(home, link);
  try {
    const r = seed({ home: link });

    assert.deepStrictEqual(r.added, [home]);
    const projects = readCfg().projects;
    assert.deepStrictEqual(projects[home], { ...wt.NEW_ENTRY, hasTrustDialogAccepted: true });
    assert.strictEqual(projects[link], undefined);
  } finally {
    rmTmp(linkDir);
  }
});

test('a home missing on disk adds no key; the repositories are still listed', () => {
  plantRepo('fresh');
  assert.deepStrictEqual(
    wt.trustKeys({ home: path.join(home, 'missing'), roots: [sites()] }),
    [sites('fresh')],
  );
});

test('a linked worktree is keyed by its main repository, as Claude Code keys it', () => {
  // A sibling worktree of a repository under the root, and a worktree under
  // the root of a repository kept elsewhere.
  gitRepo(sites('main'));
  git(sites('main'), 'worktree', 'add', '-q', '-b', 'side', sites('side'));
  const upstream = path.join(home, 'elsewhere', 'upstream');
  gitRepo(upstream);
  git(upstream, 'worktree', 'add', '-q', '-b', 'wt', sites('upstream-wt'));
  writeCfg({ projects: {} });

  const r = seed();

  assert.deepStrictEqual([...r.added].sort(), [home, upstream, sites('main')].sort());
  const projects = readCfg().projects;
  assert.strictEqual(projects[sites('side')], undefined);
  assert.strictEqual(projects[sites('upstream-wt')], undefined);
});

test('config path: legacy .config.json, then CLAUDE_CONFIG_DIR, custom-OAuth suffix, home', () => {
  assert.strictEqual(wt.configPath({ home, env: {} }), path.join(home, '.claude.json'));
  assert.strictEqual(wt.configPath({ home, env: { CLAUDE_CONFIG_DIR: '/srv/cc' } }), '/srv/cc/.claude.json');
  assert.strictEqual(
    wt.configPath({ home, env: { CLAUDE_CODE_CUSTOM_OAUTH_URL: 'https://x.invalid' } }),
    path.join(home, '.claude-custom-oauth.json'),
  );
  fs.mkdirSync(path.join(home, '.claude'));
  fs.writeFileSync(path.join(home, '.claude', '.config.json'), '{}');
  assert.strictEqual(wt.configPath({ home, env: {} }), path.join(home, '.claude', '.config.json'));
});

test('SessionStart: launchpad-advisory seeds silently', async () => {
  plantRepo('fresh');
  writeCfg(baseCfg());

  const res = await runHook('SessionStart/launchpad-advisory.js',
    { cwd: home, hook_event_name: 'SessionStart', source: 'startup' },
    { env: { HOME: home, USERPROFILE: home } });

  assert.strictEqual(res.code, 0, res.stderr);
  assert.strictEqual(res.stdout, '');
  assert.strictEqual(readCfg().projects[home].hasTrustDialogAccepted, true);
  assert.strictEqual(readCfg().projects[sites('fresh')].hasTrustDialogAccepted, true);
});
