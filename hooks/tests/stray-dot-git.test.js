'use strict';
/**
 * lib/stray-dot-git.js: which `.git` shapes are moved aside, which are left
 * alone, and that check mode never moves anything (dotfiles#1553).
 *
 * Every case plants shapes under its own STRAY_DOT_GIT_FS_ROOT, so nothing
 * here can touch the host's real / or /tmp. The planted negatives are the
 * near-identical valid shapes: a real repository and a valid gitfile sit at
 * the same anchor as the strays and must survive.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { spawnNode, mkTmp, rmTmp } = require('./lib/harness');

const sdg = require('../lib/stray-dot-git');

const UID = 4242;
const HOME = '/home/tester';
const NOW = new Date('2026-10-04T21:25:40.123Z');
const STAMP = '20261004T212540Z';

let root;
let savedRoot;
let savedStore;

beforeEach(() => {
  root = mkTmp('sdg-root-');
  savedRoot = process.env.STRAY_DOT_GIT_FS_ROOT;
  savedStore = process.env.PAPERCUT_STORE;
  process.env.STRAY_DOT_GIT_FS_ROOT = root;
  process.env.PAPERCUT_STORE = path.join(root, 'store');
  fs.mkdirSync(path.join(root, 'tmp', `cc-daemon-${UID}`, 'abc12345', 'spare'), { recursive: true });
  fs.mkdirSync(path.join(root, HOME), { recursive: true });
});

afterEach(() => {
  process.env.STRAY_DOT_GIT_FS_ROOT = savedRoot;
  if (savedStore === undefined) delete process.env.PAPERCUT_STORE;
  else process.env.PAPERCUT_STORE = savedStore;
  rmTmp(root);
});

const disk = (hostPath) => path.join(root, hostPath);
const scan = (opts = {}) => sdg.scan({ home: HOME, uid: UID, now: NOW, ...opts });

function gitInit(hostDir) {
  fs.mkdirSync(disk(hostDir), { recursive: true });
  execFileSync('git', ['init', '-q', disk(hostDir)], { stdio: 'ignore' });
}

const SHAPES = {
  'empty directory': (d) => fs.mkdirSync(disk(path.join(d, '.git'))),
  'junk directory': (d) => {
    fs.mkdirSync(disk(path.join(d, '.git')));
    fs.writeFileSync(disk(path.join(d, '.git', 'notes.txt')), 'junk\n');
  },
  'junk gitfile': (d) => fs.writeFileSync(disk(path.join(d, '.git')), 'not a gitfile\n'),
  'symlink to a non-repository': (d) => {
    fs.mkdirSync(disk('/elsewhere'), { recursive: true });
    fs.symlinkSync(disk('/elsewhere'), disk(path.join(d, '.git')));
  },
  'dangling symlink': (d) => fs.symlinkSync(disk('/does-not-exist'), disk(path.join(d, '.git'))),
};

for (const [shape, plant] of Object.entries(SHAPES)) {
  test(`heal moves a stray ${shape} at /tmp aside, renamed not deleted`, () => {
    plant('/tmp');
    const [f, ...rest] = scan({ heal: true });
    assert.strictEqual(rest.length, 0);
    assert.strictEqual(f.action, 'moved');
    assert.strictEqual(f.verdict, 'stray');
    assert.strictEqual(f.cls, 'tmp');
    assert.match(f.dest, new RegExp(`^/tmp/\\.git\\.stray-${STAMP}-[0-9a-f]{8}$`));
    assert.throws(() => fs.lstatSync(disk('/tmp/.git')), /ENOENT/);
    assert.ok(fs.lstatSync(disk(f.dest)), 'renamed entry must still exist');
  });
}

test('every daemon anchor is scanned: config dir and spare dir', () => {
  SHAPES['empty directory'](`/tmp/cc-daemon-${UID}/abc12345/spare`);
  SHAPES['junk gitfile'](`/tmp/cc-daemon-${UID}/abc12345`);
  SHAPES['junk directory'](`/tmp/cc-daemon-${UID}`);
  const got = scan({ heal: true }).map((f) => [f.cls, f.action, f.kind]);
  assert.deepStrictEqual(got, [
    ['cc-daemon', 'moved', 'directory'],
    ['cc-daemon-config', 'moved', 'file'],
    ['cc-daemon-spare', 'moved', 'empty directory'],
  ]);
});

test('a real repository at /tmp is reported and never moved', () => {
  gitInit('/tmp');
  const [f] = scan({ heal: true });
  assert.strictEqual(f.verdict, 'repo');
  assert.strictEqual(f.action, 'reported');
  assert.ok(fs.statSync(disk('/tmp/.git')).isDirectory(), 'real repository must stay in place');
});

test('a valid gitfile at /tmp is reported and never moved', () => {
  gitInit('/elsewhere');
  fs.writeFileSync(disk('/tmp/.git'), `gitdir: ${disk('/elsewhere/.git')}\n`);
  const [f] = scan({ heal: true });
  assert.strictEqual(f.verdict, 'repo');
  assert.strictEqual(f.action, 'reported');
  assert.ok(fs.statSync(disk('/tmp/.git')).isFile());
});

test('a real repository at $HOME is silent; one at its parent is reported', () => {
  gitInit(HOME);
  assert.deepStrictEqual(scan({ heal: true }), []);
  gitInit('/home');
  const got = scan({ heal: true }).map((f) => [f.path, f.verdict, f.action]);
  assert.deepStrictEqual(got, [['/home/.git', 'repo', 'reported']]);
});

test('a stray at $HOME is still moved', () => {
  SHAPES['empty directory'](HOME);
  const [f] = scan({ heal: true });
  assert.strictEqual(f.cls, 'home');
  assert.strictEqual(f.action, 'moved');
});

test('another user\'s stray is reported and never moved', () => {
  SHAPES['empty directory']('/tmp');
  const [f] = scan({ heal: true, owner: 99999 });
  assert.strictEqual(f.verdict, 'foreign');
  assert.strictEqual(f.action, 'reported');
  assert.ok(fs.statSync(disk('/tmp/.git')).isDirectory());
  assert.match(sdg.advisory([f]), /another user[\s\S]*needs the operator/);
});

test('a symlink of ours into another user\'s directory is foreign: never probed, never moved', (t) => {
  if (process.getuid() === 0) { t.skip('needs a non-root uid: /usr is owned by root'); return; }
  assert.notStrictEqual(fs.statSync('/usr').uid, process.getuid(), 'precondition: /usr belongs to someone else');
  fs.symlinkSync('/usr', disk('/tmp/.git'));
  const [f] = scan({ heal: true });
  assert.strictEqual(f.verdict, 'foreign');
  assert.strictEqual(f.action, 'reported');
  assert.ok(fs.lstatSync(disk('/tmp/.git')).isSymbolicLink(), 'the link must stay in place');
});

// git exits 128 with "not a git repository" for a corrupt real repository
// too, so these must be left alone however git words its refusal.
const DAMAGED = {
  'repository with a corrupt HEAD': (d) => { gitInit(d); fs.writeFileSync(disk(path.join(d, '.git', 'HEAD')), ''); },
  'repository missing its objects': (d) => {
    gitInit(d);
    fs.rmSync(disk(path.join(d, '.git', 'objects')), { recursive: true, force: true });
  },
  'repository with an unsupported format version': (d) => {
    gitInit(d);
    execFileSync('git', ['-C', disk(d), 'config', 'core.repositoryformatversion', '99'], { stdio: 'ignore' });
  },
  'gitfile pointing at a vanished worktree': (d) => {
    fs.writeFileSync(disk(path.join(d, '.git')), `gitdir: ${disk('/gone/.git/worktrees/x')}\n`);
  },
};

for (const [shape, plant] of Object.entries(DAMAGED)) {
  test(`a ${shape} at /tmp is reported as damaged and never moved`, () => {
    plant('/tmp');
    assert.ok(sdg.probeGit(disk('/tmp/.git')) !== 'accepted', 'precondition: git refuses this shape');
    const [f] = scan({ heal: true });
    assert.strictEqual(f.verdict, 'damaged');
    assert.strictEqual(f.action, 'reported');
    assert.ok(fs.existsSync(disk('/tmp/.git')), 'a damaged repository must stay in place');
    assert.match(sdg.describe(f), /damaged git repository/);
  });
}

test('the probe is pinned to git\'s C-locale messages', () => {
  // A stand-in git that answers in German unless LC_ALL=C and no LANGUAGE.
  const bin = disk('/fakebin');
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\n'
    + 'if [ "$LC_ALL" = C ] && [ -z "$LANGUAGE" ]; then echo "fatal: not a git repository: x" >&2;\n'
    + 'else echo "fatal: kein Git-Repository: x" >&2; fi\nexit 128\n', { mode: 0o755 });
  const saved = { PATH: process.env.PATH, LC_ALL: process.env.LC_ALL, LANGUAGE: process.env.LANGUAGE };
  process.env.PATH = `${bin}:${saved.PATH}`;
  process.env.LC_ALL = 'de_DE.UTF-8';
  process.env.LANGUAGE = 'de';
  try {
    const raw = require('node:child_process').spawnSync('git', ['--version'], { encoding: 'utf8' });
    assert.match(raw.stderr, /kein Git-Repository/, 'precondition: the inherited locale localizes the stand-in');
    SHAPES['empty directory']('/tmp');
    const [f] = scan({ heal: true });
    assert.strictEqual(f.action, 'moved');
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
  }
});

test('an entry replaced while git was probing it is not renamed', () => {
  SHAPES['empty directory']('/tmp');
  const p = disk('/tmp/.git');
  const real = fs.lstatSync;
  let calls = 0;
  fs.lstatSync = (q, ...rest) => {
    if (q === p && ++calls === 2) {
      // Keep the old inode allocated so the replacement cannot reuse it.
      fs.mkdirSync(disk('/tmp/fresh'));
      fs.renameSync(p, disk('/tmp/held'));
      fs.renameSync(disk('/tmp/fresh'), p);
    }
    return real(q, ...rest);
  };
  try {
    assert.deepStrictEqual(scan({ heal: true }), []);
  } finally {
    fs.lstatSync = real;
  }
  assert.strictEqual(calls, 2, 'precondition: the entry was re-checked before the rename');
  assert.ok(fs.statSync(p).isDirectory(), 'the replacement must stay in place');
  assert.deepStrictEqual(fs.readdirSync(disk('/tmp')).filter((n) => n.includes('.stray-')), []);
});

test('an entry a concurrent git init filled in while git was probing it is not renamed', () => {
  // git init makes the empty .git directory first and writes HEAD after.
  SHAPES['empty directory']('/tmp');
  const p = disk('/tmp/.git');
  const real = fs.lstatSync;
  let calls = 0;
  fs.lstatSync = (q, ...rest) => {
    if (q === p && ++calls === 2) fs.writeFileSync(path.join(p, 'HEAD'), 'ref: refs/heads/main\n');
    return real(q, ...rest);
  };
  try {
    assert.deepStrictEqual(scan({ heal: true }), []);
  } finally {
    fs.lstatSync = real;
  }
  assert.strictEqual(calls, 2, 'precondition: the entry was re-checked before the rename');
  assert.ok(fs.existsSync(path.join(p, 'HEAD')), 'the filled-in entry must stay in place');
  assert.deepStrictEqual(fs.readdirSync(disk('/tmp')).filter((n) => n.includes('.stray-')), []);
});

test('past the deadline an entry is left unverified, not probed or moved', () => {
  SHAPES['empty directory']('/tmp');
  const [f] = scan({ heal: true, deadline: 0 });
  assert.strictEqual(f.verdict, 'unverified');
  assert.strictEqual(f.action, 'reported');
  assert.ok(fs.statSync(disk('/tmp/.git')).isDirectory());
});

test('another user\'s entry is never probed with git (a real repo still reads foreign, not repo)', () => {
  gitInit('/tmp');
  const [f] = scan({ heal: true, owner: 99999 });
  assert.strictEqual(f.verdict, 'foreign', 'git was consulted on a foreign entry');
});

test('check mode never renames anything', () => {
  SHAPES['empty directory']('/tmp');
  const [f] = scan({ heal: false });
  assert.strictEqual(f.verdict, 'stray', 'precondition: the heal would have moved it');
  assert.strictEqual(f.action, 'found');
  assert.ok(fs.statSync(disk('/tmp/.git')).isDirectory());
});

test('clean host: no findings, empty advisory, nothing recorded', () => {
  const findings = scan({ heal: true });
  assert.deepStrictEqual(findings, []);
  assert.strictEqual(sdg.advisory(findings), '');
  assert.strictEqual(sdg.recordFindings(findings, { cwd: '/w' }), 0);
  assert.ok(!fs.existsSync(path.join(root, 'store')));
});

test('a peer winning the rename race is neither an error nor a finding', () => {
  SHAPES['empty directory']('/tmp');
  const real = fs.renameSync;
  fs.renameSync = () => { const e = new Error('gone'); e.code = 'ENOENT'; throw e; };
  try {
    assert.deepStrictEqual(scan({ heal: true }), []);
  } finally {
    fs.renameSync = real;
  }
});

test('a rename this user may not make is reported as failed and handed to the operator', () => {
  SHAPES['empty directory']('/tmp');
  const real = fs.renameSync;
  fs.renameSync = () => { const e = new Error('nope'); e.code = 'EACCES'; throw e; };
  try {
    const findings = scan({ heal: true });
    assert.strictEqual(findings[0].verdict, 'stray');
    assert.strictEqual(findings[0].action, 'failed');
    assert.strictEqual(findings[0].error, 'EACCES');
    assert.match(sdg.advisory(findings), /needs the operator/);
  } finally {
    fs.renameSync = real;
  }
});

// A dangling symlink is the shape an existsSync check reads as free: rename(2)
// would then replace it.
test('a destination name already taken, even by a dangling symlink, is never renamed over', () => {
  SHAPES['empty directory']('/tmp');
  const taken = `/tmp/.git.stray-${STAMP}-aaaaaaaa`;
  fs.symlinkSync(disk('/does-not-exist'), disk(taken));
  const real = crypto.randomBytes;
  let calls = 0;
  crypto.randomBytes = (n) => Buffer.alloc(n, (calls++ === 0) ? 0xaa : 0xbb);
  try {
    const [f] = scan({ heal: true });
    assert.strictEqual(calls, 2, 'precondition: the taken name was drawn first');
    assert.strictEqual(f.action, 'moved');
    assert.strictEqual(f.dest, `/tmp/.git.stray-${STAMP}-bbbbbbbb`);
    assert.ok(fs.lstatSync(disk(taken)).isSymbolicLink(), 'the taken entry must not be clobbered');
    assert.ok(fs.statSync(disk(f.dest)).isDirectory(), 'the stray landed at the free name');
  } finally {
    crypto.randomBytes = real;
  }
});

test('no free destination name: reported as failed, nothing renamed over', () => {
  SHAPES['empty directory']('/tmp');
  const taken = `/tmp/.git.stray-${STAMP}-cccccccc`;
  fs.writeFileSync(disk(taken), 'earlier\n');
  const real = crypto.randomBytes;
  crypto.randomBytes = (n) => Buffer.alloc(n, 0xcc);
  try {
    const [f] = scan({ heal: true });
    assert.strictEqual(f.action, 'failed');
    assert.strictEqual(f.error, 'EEXIST');
    assert.strictEqual(fs.readFileSync(disk(taken), 'utf8'), 'earlier\n');
    assert.ok(fs.statSync(disk('/tmp/.git')).isDirectory(), 'the stray stays in place');
  } finally {
    crypto.randomBytes = real;
  }
});

test('advisory names the path and says a lingering refusal is cached state, not a rule', () => {
  SHAPES['empty directory']('/tmp');
  const text = sdg.advisory(scan({ heal: true }));
  assert.match(text, /^\[stray-dot-git\] moved stray \/tmp\/\.git \(empty directory/);
  assert.match(text, /cached-state artifact, not a rule/);
  assert.doesNotMatch(text, /needs the operator/);
});

test('recordFindings writes one heal record per finding through the papercut store', () => {
  SHAPES['empty directory']('/tmp');
  gitInit('/home');
  const findings = scan({ heal: true });
  assert.strictEqual(sdg.recordFindings(findings, { cwd: '/w/proj', sessionId: 'abcdef0123456789' }), 2);
  const lines = fs.readFileSync(path.join(root, 'store', '-w-proj.jsonl'), 'utf8').trim().split('\n');
  const recs = lines.map((l) => JSON.parse(l));
  assert.deepStrictEqual(recs.map((r) => [r.sig, r.source, r.target, r.session]), [
    ['stray_dot_git:tmp', 'heal', '/tmp/.git', '23456789'],
    ['stray_dot_git:home-parent', 'heal', '/home/.git', '23456789'],
  ]);
  assert.match(recs[0].err, /^moved stray \/tmp\/\.git/);
});

test('heal records never advance a store mtime, which papercut staleness reads as capture liveness', () => {
  SHAPES['empty directory']('/tmp');
  const file = path.join(root, 'store', '-w-proj.jsonl');
  assert.strictEqual(sdg.recordFindings(scan({ heal: true }), { cwd: '/w/proj' }), 1);
  assert.strictEqual(fs.statSync(file).mtimeMs, 0, 'a store file only a heal wrote carries no capture time');
  const old = new Date(Math.floor(Date.now() / 1000) * 1000 - 5 * 86400000); // whole seconds round-trip exactly
  fs.utimesSync(file, old, old);
  SHAPES['empty directory']('/tmp');
  assert.strictEqual(sdg.recordFindings(scan({ heal: true }), { cwd: '/w/proj' }), 1);
  assert.strictEqual(fs.readFileSync(file, 'utf8').trim().split('\n').length, 2, 'precondition: the second record was appended');
  assert.strictEqual(fs.statSync(file).mtimeMs, old.getTime());
});

test('anchors: daemon dirs from disk, $HOME under /tmp does not duplicate /tmp', () => {
  const dirs = sdg.anchors({ home: '/tmp/somehome', uid: UID }).map((a) => a.dir);
  assert.deepStrictEqual(dirs, [
    '/', '/tmp', `/tmp/cc-daemon-${UID}`,
    `/tmp/cc-daemon-${UID}/abc12345`, `/tmp/cc-daemon-${UID}/abc12345/spare`,
    '/tmp/somehome',
  ]);
});

test('CLI --check: exit 1 with one line per stray, nothing moved; clean exit 0; bad usage exit 2', async () => {
  // The CLI resolves $HOME itself; point it inside the sandbox root.
  const env = { STRAY_DOT_GIT_FS_ROOT: root, HOME: HOME };
  const clean = await spawnNode('lib/stray-dot-git.js', { argv: ['--check'], env });
  assert.strictEqual(clean.code, 0, clean.stderr);
  assert.strictEqual(clean.stdout, '');

  SHAPES['empty directory']('/tmp');
  const dirty = await spawnNode('lib/stray-dot-git.js', { argv: ['--check'], env });
  assert.strictEqual(dirty.code, 1, dirty.stderr);
  assert.match(dirty.stdout, /^stray \/tmp\/\.git \(empty directory/);
  assert.ok(fs.statSync(disk('/tmp/.git')).isDirectory());

  const usage = await spawnNode('lib/stray-dot-git.js', { argv: [], env });
  assert.strictEqual(usage.code, 2);
});

test('CLI --heal: moves the stray and exits 0', async () => {
  SHAPES['empty directory']('/tmp');
  const env = { STRAY_DOT_GIT_FS_ROOT: root, HOME: HOME, PAPERCUT_STORE: path.join(root, 'store') };
  const res = await spawnNode('lib/stray-dot-git.js', { argv: ['--heal'], env });
  assert.strictEqual(res.code, 0, res.stderr);
  assert.match(res.stdout, /^moved stray \/tmp\/\.git/);
  assert.throws(() => fs.lstatSync(disk('/tmp/.git')), /ENOENT/);
});
