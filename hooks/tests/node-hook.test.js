'use strict';
/**
 * hooks/bin/node-hook: PATH-shape behaviour and pass-through contract.
 * (The registered-command comparison lives in hook-launcher-golden.test.js.)
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { mkTmp, rmTmp, buildEnv } = require('./lib/harness');

const LAUNCHER = path.resolve(__dirname, '..', 'bin', 'node-hook');

/** A directory holding a fake `node` that prints its own tag and argv, or null when absent. */
function fakeNodeDir(base, rel, tag) {
  const dir = path.join(base, rel);
  fs.mkdirSync(dir, { recursive: true });
  if (tag) fs.writeFileSync(path.join(dir, 'node'), `#!/bin/sh\necho "${tag}:$*"\n`, { mode: 0o755 });
  return dir;
}

function launch(pathValue, args = ['x.js', 'a b'], opts = {}) {
  return spawnSync('/bin/sh', [LAUNCHER, ...args], {
    env: { ...buildEnv(), PATH: pathValue },
    encoding: 'utf8',
    ...opts,
  });
}

test('skips a mise shim dir and takes the first real node after it', () => {
  const base = mkTmp('node-hook-');
  try {
    const shim = fakeNodeDir(base, 'home/.local/share/mise/shims', 'shim');
    const real = fakeNodeDir(base, 'real', 'real');
    const later = fakeNodeDir(base, 'later', 'later');
    const r = launch([shim, real, later].join(':'));
    assert.strictEqual(r.stdout, 'real:x.js a b\n');
  } finally { rmTmp(base); }
});

test('skips asdf shim dirs as well, including a trailing slash spelling', () => {
  const base = mkTmp('node-hook-');
  try {
    const asdf = fakeNodeDir(base, 'home/.asdf/shims', 'asdf');
    const asdf2 = fakeNodeDir(base, 'opt/asdf/shims', 'asdf2');
    const real = fakeNodeDir(base, 'real', 'real');
    assert.strictEqual(launch(`${asdf}/:${asdf2}:${real}`).stdout, 'real:x.js a b\n');
  } finally { rmTmp(base); }
});

test('a PATH entry holding glob characters is taken literally, never expanded into other dirs', () => {
  const base = mkTmp('node-hook-');
  try {
    // `a?b` and `a[x]b` must not match the sibling dirs `a*b` / `axb` that hold a node.
    fakeNodeDir(base, 'a*b', 'globbed');
    fakeNodeDir(base, 'axb', 'globbed2');
    const real = fakeNodeDir(base, 'real', 'real');
    const r = launch([path.join(base, 'a?b'), path.join(base, 'a[x]b'), real].join(':'), ['x.js', 'a b'], { cwd: base });
    assert.strictEqual(r.stdout, 'real:x.js a b\n');
  } finally { rmTmp(base); }
});

test('a real node that precedes the shim wins, exactly as the shell lookup would have', () => {
  const base = mkTmp('node-hook-');
  try {
    const real = fakeNodeDir(base, 'real', 'real');
    const shim = fakeNodeDir(base, 'home/.local/share/mise/shims', 'shim');
    assert.strictEqual(launch(`${real}:${shim}`).stdout, 'real:x.js a b\n');
  } finally { rmTmp(base); }
});

test('shims only: falls back to the literal `exec node` (the shim runs, as it did before)', () => {
  const base = mkTmp('node-hook-');
  try {
    const shim = fakeNodeDir(base, 'home/.local/share/mise/shims', 'shim');
    assert.strictEqual(launch(`${base}:${shim}`).stdout, 'shim:x.js a b\n');
  } finally { rmTmp(base); }
});

test('no node on PATH: exit 127 from the shell, like the bare command', () => {
  const base = mkTmp('node-hook-');
  try {
    const empty = fakeNodeDir(base, 'empty', null);
    const r = launch(empty);
    assert.strictEqual(r.status, 127);
    assert.strictEqual(r.stdout, '');
  } finally { rmTmp(base); }
});

test('empty PATH entries and entries holding a directory named node are not mistaken for node', () => {
  const base = mkTmp('node-hook-');
  try {
    const dirNode = path.join(base, 'dirnode');
    fs.mkdirSync(path.join(dirNode, 'node'), { recursive: true });
    const real = fakeNodeDir(base, 'real', 'real');
    assert.strictEqual(launch(`::${dirNode}::${real}:`).stdout, 'real:x.js a b\n');
  } finally { rmTmp(base); }
});

test('a PATH entry containing spaces and glob characters is walked literally', () => {
  const base = mkTmp('node-hook-');
  try {
    const odd = fakeNodeDir(base, 'a dir*[x]', 'odd');
    assert.strictEqual(launch(odd).stdout, 'odd:x.js a b\n');
  } finally { rmTmp(base); }
});

test('IFS is restored before exec: the node child sees the caller IFS-independent environment', () => {
  const base = mkTmp('node-hook-');
  try {
    const dir = path.join(base, 'real');
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'node'), '#!/bin/sh\nprintf "[%s]" "$PATH"\n', { mode: 0o755 });
    const p = `${dir}:/usr/bin`;
    assert.strictEqual(launch(p).stdout, `[${p}]`);
  } finally { rmTmp(base); }
});

test('stdin, argv, cwd, exit code and env pass through an exec of the real node', () => {
  const base = mkTmp('node-hook-');
  try {
    const dir = path.join(base, 'bin');
    fs.mkdirSync(dir);
    fs.symlinkSync(process.execPath, path.join(dir, 'node'));
    const script = path.join(base, 's.js');
    fs.writeFileSync(script, [
      "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{",
      "process.stdout.write(JSON.stringify({d,argv:process.argv.slice(2),cwd:process.cwd(),e:process.env.GOLDEN_X}));",
      "process.stderr.write('err-line');process.exit(7);});",
    ].join(''));
    const r = spawnSync('/bin/sh', [LAUNCHER, script, 'one', 'two words', ''], {
      env: { ...buildEnv(), PATH: `${dir}:/usr/bin`, GOLDEN_X: 'env-ok' },
      cwd: base,
      input: 'payload\nline2',
      encoding: 'utf8',
    });
    assert.strictEqual(r.status, 7);
    assert.strictEqual(r.stderr, 'err-line');
    assert.deepStrictEqual(JSON.parse(r.stdout), { d: 'payload\nline2', argv: ['one', 'two words', ''], cwd: fs.realpathSync(base), e: 'env-ok' });
  } finally { rmTmp(base); }
});

test('the launcher never stats /mnt entries (a drvfs lookup is ~2 ms each)', () => {
  const src = fs.readFileSync(LAUNCHER, 'utf8');
  // The case arm that skips them must precede the only file test in the loop.
  assert.ok(src.indexOf('/mnt/*') !== -1 && src.indexOf('/mnt/*') < src.indexOf('[ -f "$_hn_d/node" ]'));
});
