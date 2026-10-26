'use strict';
const { test, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Track every temp dir so we can clean them all up (no /tmp leakage).
const CREATED = [];
const tmp = (p = 'fmt-') => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), p));
  CREATED.push(d);
  return d;
};
after(() => {
  for (const d of CREATED) {
    try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* ignore */ }
  }
});

// Run `fn` with a hermetic env: an empty temp $HOME (so package-manager's global
// config lookup finds nothing) and no CLAUDE_PACKAGE_MANAGER override. These
// tests call getPackageManager IN-PROCESS, so unlike the spawned hook tests they
// don't get the harness's env neutralization — do it here or the result depends
// on the developer's own ~/.claude and shell (os.homedir() honors $HOME).
function withCleanEnv(fn) {
  const saved = {
    HOME: process.env.HOME,
    USERPROFILE: process.env.USERPROFILE,
    CLAUDE_PACKAGE_MANAGER: process.env.CLAUDE_PACKAGE_MANAGER,
  };
  const home = tmp('pm-home-');
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  delete process.env.CLAUDE_PACKAGE_MANAGER;
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test('package-manager loads without a missing-module throw [regression: deleted lib/utils.js]', () => {
  assert.doesNotThrow(() => require('../lib/package-manager'));
});

test('package-manager exposes only getPackageManager (dead surface removed)', () => {
  const pm = require('../lib/package-manager');
  assert.deepStrictEqual(Object.keys(pm), ['getPackageManager']);
});

test('getPackageManager: default → npm, lockfile → pnpm, env override wins', () => {
  const { getPackageManager } = require('../lib/package-manager');
  withCleanEnv(() => {
    const empty = tmp('pm-');
    assert.strictEqual(getPackageManager({ projectDir: empty }).name, 'npm');

    const pnpm = tmp('pm-');
    fs.writeFileSync(path.join(pnpm, 'pnpm-lock.yaml'), '');
    assert.strictEqual(getPackageManager({ projectDir: pnpm }).name, 'pnpm');

    process.env.CLAUDE_PACKAGE_MANAGER = 'yarn';
    try {
      assert.strictEqual(getPackageManager({ projectDir: empty }).name, 'yarn');
    } finally {
      delete process.env.CLAUDE_PACKAGE_MANAGER;
    }
  });
});

test('detectFormatter: biome by config, prettier by package.json key', () => {
  const rf = require('../lib/resolve-formatter');
  rf.clearCaches();
  const b = tmp();
  fs.writeFileSync(path.join(b, 'biome.json'), '{}');
  assert.strictEqual(rf.detectFormatter(rf.findProjectRoot(b)), 'biome');

  const p = tmp();
  fs.writeFileSync(path.join(p, 'package.json'), JSON.stringify({ prettier: {} }));
  assert.strictEqual(rf.detectFormatter(rf.findProjectRoot(p)), 'prettier');
});

test('resolveFormatterBin fallback resolves via package manager without throwing [regression]', () => {
  const rf = require('../lib/resolve-formatter');
  rf.clearCaches();
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'biome.json'), '{}');
  const root = rf.findProjectRoot(dir);
  let resolved;
  // Before the fix this threw MODULE_NOT_FOUND (package-manager → missing ./utils).
  // The @biomejs/biome pkg name is always appended regardless of which package
  // manager resolves, so this assertion is independent of ambient PM config.
  assert.doesNotThrow(() => { resolved = rf.resolveFormatterBin(root, 'biome'); });
  assert.ok(resolved && resolved.prefix.includes('@biomejs/biome'));
});

test('resolveFormatterBin prefers a local node_modules/.bin binary', () => {
  const rf = require('../lib/resolve-formatter');
  rf.clearCaches();
  const dir = tmp();
  const binDir = path.join(dir, 'node_modules', '.bin');
  fs.mkdirSync(binDir, { recursive: true });
  const local = path.join(binDir, process.platform === 'win32' ? 'biome.cmd' : 'biome');
  fs.writeFileSync(local, '');
  const r = rf.resolveFormatterBin(dir, 'biome');
  assert.strictEqual(r.bin, local);
  assert.deepStrictEqual(r.prefix, []);
});
