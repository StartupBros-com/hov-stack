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

// ---------------------------------------------------------------------------
// loop-guard env gate: the launcher literal must be the JS predicate (#369 pass 2)
// ---------------------------------------------------------------------------

const LOOP_GUARD_JS = path.resolve(__dirname, '..', 'PreToolUse', 'loop-guard.js');

test('gate drift: the launcher skips exactly when loop-guard.js returns at its first statement', () => {
  const js = fs.readFileSync(LOOP_GUARD_JS, 'utf8');
  const sh = fs.readFileSync(LAUNCHER, 'utf8');
  // JS: the only read of the env var, and it is the first statement of run().
  assert.strictEqual((js.match(/process\.env\.CLAUDE_LOOP_GUARD/g) || []).length, 1, 'loop-guard.js reads CLAUDE_LOOP_GUARD exactly once');
  const m = js.match(/function run\(rawInput\) \{\n  if \(process\.env\.CLAUDE_LOOP_GUARD !== '([^']*)'\) return rawInput;\n/);
  assert.ok(m, 'loop-guard.js run() no longer opens with the env no-op return: the launcher gate is invalid, remove or re-derive it');
  // The entry point drains stdin and writes only a changed result (the no-op prints nothing).
  assert.ok(js.includes("process.stdin.on('end', () => writeHookOutput(run(data), data));"));
  // Shell: same variable, same literal, inverted comparison, same script name.
  const g = sh.match(/case \$1 in\n  \*\/PreToolUse\/loop-guard\.js\)\n    if \[ "\$CLAUDE_LOOP_GUARD" != ([^ ]+) \]; then\n      command exec cat >\/dev\/null 2>&1\n      exit 0\n/);
  assert.ok(g, 'launcher gate block not found in its expected shape');
  assert.strictEqual(g[1], m[1], 'launcher literal differs from the JS literal');
  assert.strictEqual(m[1], '1');
});

test('gate: the seed registers loop-guard through the launcher with no env or flag in the command (gate needs no settings change)', () => {
  const settings = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', '..', 'settings.json'), 'utf8'));
  const cmds = [];
  for (const g of settings.hooks.PreToolUse) for (const h of g.hooks) if (h.command.includes('loop-guard.js')) cmds.push([g.matcher, h.command]);
  assert.deepStrictEqual(cmds, [['*', '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PreToolUse/loop-guard.js"']]);
});

test('gate: only the loop-guard script is gated; any other script starts node (case arm is path-exact)', () => {
  const base = mkTmp('node-hook-gate-');
  try {
    const real = fakeNodeDir(base, 'real', 'real');
    const env = { ...buildEnv(), PATH: `${real}:/usr/bin:/bin` };
    delete env.CLAUDE_LOOP_GUARD;
    for (const script of ['/x/PreToolUse/loop-guard.json', '/x/PreToolUse/not-loop-guard.js', '/x/PostToolUse/loop-guard.js', 'loop-guard.js']) {
      const r = spawnSync('/bin/sh', [LAUNCHER, script], { env, input: '{}', encoding: 'utf8' });
      assert.strictEqual(r.stdout, `real:${script}\n`, script);
    }
    const skipped = spawnSync('/bin/sh', [LAUNCHER, '/x/PreToolUse/loop-guard.js'], { env, input: '{}', encoding: 'utf8' });
    assert.strictEqual(skipped.stdout, '');
    assert.strictEqual(skipped.status, 0);
    const armed = spawnSync('/bin/sh', [LAUNCHER, '/x/PreToolUse/loop-guard.js'], { env: { ...env, CLAUDE_LOOP_GUARD: '1' }, input: '{}', encoding: 'utf8' });
    assert.strictEqual(armed.stdout, 'real:/x/PreToolUse/loop-guard.js\n');
  } finally { rmTmp(base); }
});

test('the launcher never stats /mnt entries (a drvfs lookup is ~2 ms each)', () => {
  const src = fs.readFileSync(LAUNCHER, 'utf8');
  // The case arm that skips them must precede the only file test in the loop.
  assert.ok(src.indexOf('/mnt/*') !== -1 && src.indexOf('/mnt/*') < src.indexOf('[ -f "$_hn_d/node" ]'));
});

test('an inherited _hn_stdin / _hn_buf in the caller env never replaces another hook\'s stdin', () => {
  const base = mkTmp('node-hook-envleak-');
  try {
    const dir = path.join(base, 'real');
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'node'), '#!/bin/sh\nprintf "[%s]" "$(cat; echo x)"\n', { mode: 0o755 });
    const env = { ...buildEnv(), PATH: `${dir}:/usr/bin:/bin`, _hn_stdin: '1', _hn_buf: 'EVIL' };
    for (const script of ['/x/PreToolUse/git-guard.js', '/x/PreToolUse/not-settings-guard.js']) {
      const r = spawnSync('/bin/sh', [LAUNCHER, script], { env, input: '{"a":1}', encoding: 'utf8' });
      assert.strictEqual(r.stdout, '[{"a":1}x]', script);
    }
    // The gated hook still skips a no-literal payload and still hands node the real bytes otherwise.
    const hook = '/x/PreToolUse/settings-guard.js';
    assert.strictEqual(spawnSync('/bin/sh', [LAUNCHER, hook], { env, input: '{"c":"ls"}', encoding: 'utf8' }).stdout, '');
    assert.strictEqual(spawnSync('/bin/sh', [LAUNCHER, hook], { env, input: '{"c":"settings.json"}', encoding: 'utf8' }).stdout, '[{"c":"settings.json"}x]');
  } finally { rmTmp(base); }
});

// ---------------------------------------------------------------------------
// settings-guard stdin gate: the launcher literals must be derived from GUARDED (#369 pass 4)
// ---------------------------------------------------------------------------

const SETTINGS_GUARD_JS = path.resolve(__dirname, '..', 'PreToolUse', 'settings-guard.js');

/** Longest substring common to every name (brute force; the names are short). */
function commonSubstring(names) {
  const [first, ...rest] = names;
  let best = '';
  for (let i = 0; i < first.length; i += 1) {
    for (let j = i + 1; j <= first.length; j += 1) {
      const sub = first.slice(i, j);
      if (sub.length > best.length && rest.every((n) => n.includes(sub))) best = sub;
    }
  }
  return best;
}

test('settings-guard gate drift: the launcher skips only when run() cannot reach ask(), and its literal is derived from GUARDED', () => {
  const js = fs.readFileSync(SETTINGS_GUARD_JS, 'utf8');
  const sh = fs.readFileSync(LAUNCHER, 'utf8');
  // JS: GUARDED is the only trigger, ask() is called once and only behind it, and the passes before it return the input.
  const set = js.match(/const GUARDED = new Set\(\[\n((?:  '[^']+',\n)+)\]\);/);
  assert.ok(set, 'settings-guard.js GUARDED no longer has the expected literal shape');
  const guarded = [...set[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  assert.deepStrictEqual([...guarded].sort(), ['managed-settings.json', 'settings.json', 'settings.local.json']);
  assert.strictEqual((js.match(/\bask\(/g) || []).length, 1, 'exactly one ask( call');
  assert.ok(js.includes('    if (GUARDED.has(path.basename(fp))) {\n      return ask('), 'ask() is only reachable behind GUARDED.has(basename(file_path))');
  assert.ok(js.includes("    const input = JSON.parse(rawInput);\n    const tool = input.tool_name;\n    if (tool && !/^(Edit|Write|MultiEdit)$/.test(tool)) return rawInput;\n\n    const fp = input.tool_input?.file_path;\n    if (typeof fp !== 'string') return rawInput;\n"));
  // Entry: stdin accumulated to the cap, run() output through the quiet writer, exit 0.
  assert.ok(js.includes('if (data.length < 1024 * 1024) data += chunk;'));
  assert.ok(js.includes('writeHookOutput(run(data), data);'));
  // Load-time surface: a new top-level require is a new effect to audit before the gate stays valid.
  assert.deepStrictEqual(js.match(/^const .* = require\('[^']+'\);$/gm).map((l) => l.match(/require\('([^']+)'\)/)[1]),
    ['path', '../lib/pretooluse-decision', '../lib/hook-output']);

  // Shell: the arm is path-exact and holds the common substring of GUARDED plus the \u00XY escape
  // prefixes of every character of it.
  const literal = commonSubstring(guarded);
  assert.strictEqual(literal, 'settings.');
  const arm = sh.match(/ {2}\*\/PreToolUse\/settings-guard\.js\)\n {4}_hn_buf=\$\(tr '\\0' '\\1'; echo x\)\n {4}_hn_buf=\$\{_hn_buf%x\}\n {4}case \$_hn_buf in\n {6}(.*)\) _hn_stdin=1 ;;\n {6}\*\) exit 0 ;;\n {4}esac\n {4};;\n/);
  assert.ok(arm, 'launcher settings-guard arm not found in its expected shape');
  const pats = arm[1].split(' | ').map((p) => p.replace(/^\*'/, '').replace(/'\*$/, ''));
  const wanted = new Set(literal.split('').map((c) => `\\u00${c.charCodeAt(0).toString(16).padStart(2, '0')[0]}`));
  assert.deepStrictEqual(pats, [literal, ...[...wanted].sort()]);
  assert.deepStrictEqual([...wanted].sort(), ['\\u002', '\\u006', '\\u007']);
  assert.strictEqual((sh.match(/\[ -z "\$_hn_stdin" \] \|\| \{ printf '%s' "\$_hn_buf" \| /g) || []).length, 2);
});

test('settings-guard gate: the seed registers settings-guard through the launcher as the only node hook on Edit|Write|MultiEdit PreToolUse besides env-gated loop-guard', () => {
  const settings = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', '..', 'settings.json'), 'utf8'));
  const onEdit = [];
  for (const g of settings.hooks.PreToolUse) {
    const ms = !g.matcher ? ['*'] : g.matcher.split('|');
    if (ms.includes('*') || ms.includes('Edit') || ms.includes('Write') || ms.includes('MultiEdit')) {
      for (const h of g.hooks) onEdit.push([g.matcher, h.command]);
    }
  }
  assert.deepStrictEqual(onEdit, [
    ['*', '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PreToolUse/loop-guard.js"'],
    ['Edit|Write|MultiEdit', '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PreToolUse/settings-guard.js"'],
  ]);
});

test('settings-guard gate: path-exact, skips without node, hands node every byte otherwise', () => {
  const base = mkTmp('node-hook-sggate-');
  try {
    const dir = path.join(base, 'real');
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'node'), '#!/bin/sh\nprintf "[%s]" "$(cat; echo x)"\n', { mode: 0o755 });
    const env = { ...buildEnv(), PATH: `${dir}:/usr/bin:/bin` };
    const run = (script, input) => spawnSync('/bin/sh', [LAUNCHER, script], { env, input, encoding: 'utf8' });
    const hook = '/x/PreToolUse/settings-guard.js';
    assert.strictEqual(run(hook, '{"tool_input":{"file_path":"/a/b.js"}}\n').stdout, '');
    assert.strictEqual(run(hook, '{"tool_input":{"file_path":"/a/b.js"}}\n').status, 0);
    assert.strictEqual(run(hook, '{"tool_input":{"file_path":"/a/settings.json"}}\n\n\n').stdout, '[{"tool_input":{"file_path":"/a/settings.json"}}\n\n\nx]');
    assert.strictEqual(run(hook, '{"p":"/a/s\\u0065ttings.json"}').stdout, '[{"p":"/a/s\\u0065ttings.json"}x]');
    assert.strictEqual(run(hook, '{"p":"\\u001b[0m"}').stdout, '');
    // `settings` without the dot cannot be a GUARDED basename.
    assert.strictEqual(run(hook, '{"p":"/a/settings_json"}').stdout, '');
    for (const other of ['/x/PreToolUse/settings-guard.json', '/x/PostToolUse/settings-guard.js', 'settings-guard.js', '/x/PreToolUse/not-settings-guard.js']) {
      assert.strictEqual(run(other, '{"c":"ls"}').stdout, '[{"c":"ls"}x]', other);
    }
  } finally { rmTmp(base); }
});

// ---------------------------------------------------------------------------
// auto-format stdin gate: the launcher endings must be the JS regex, the argv the seed (#369 pass 5)
// ---------------------------------------------------------------------------

const AUTO_FORMAT_JS = path.resolve(__dirname, '..', 'PostToolUse', 'auto-format.js');
const RUN_WITH_FLAGS_JS = path.resolve(__dirname, '..', 'run-with-flags.js');
const HOOKS_LIB = path.resolve(__dirname, '..', 'lib');
const AF_ARM_RE = / {2}\*\/run-with-flags\.js\)\n {4}if \[ "\$2" = (\S+) \] && \[ "\$3" = (\S+) \] && \[ -z "\$CLAUDE_PLUGIN_ROOT" \] && \[ -f "\$\{1%\/\*\}\/(\S+)" \] && \[ -r "\$\{1%\/\*\}\/(\S+)" \]; then\n {6}_hn_buf=\$\(tr '\\0' '\\1'; echo x\)\n {6}_hn_buf=\$\{_hn_buf%x\}\n {6}case \$_hn_buf in\n {8}(.*)\) _hn_stdin=1 ;;\n {8}\*\) exit 0 ;;\n {6}esac\n {4}fi\n {4};;\n/;

function afArm() {
  const arm = fs.readFileSync(LAUNCHER, 'utf8').match(AF_ARM_RE);
  assert.ok(arm, 'launcher run-with-flags arm not found in its expected shape');
  return { hookId: arm[1], rel: arm[2], rel2: arm[3], rel3: arm[4], pats: arm[5].split(' | ').map((p) => p.replace(/^\*'/, '').replace(/'\*$/, '')) };
}

/** The shell predicate, from the arm's own patterns (a `case` pattern `*'lit'*` is a substring test). */
const afRunsNode = (pats, raw) => pats.some((p) => raw.includes(p));

test('auto-format gate drift: the launcher endings are the JS regex, the argv is the seed registration, the arm cannot skip a path run() would act on', () => {
  const js = fs.readFileSync(AUTO_FORMAT_JS, 'utf8');
  const rwf = fs.readFileSync(RUN_WITH_FLAGS_JS, 'utf8');
  const sh = fs.readFileSync(LAUNCHER, 'utf8');
  // JS: the only code that acts is behind this exact test, and run() opens parse -> file_path.
  const m = js.match(/function run\(rawInput\) \{\n {2}try \{\n {4}const input = JSON\.parse\(rawInput\);\n {4}const filePath = input\.tool_input\?\.file_path;\n\n {4}if \(filePath && \/\\\.\(([a-z|]+)\)\$\/\.test\(filePath\)\) \{\n/);
  assert.ok(m, 'auto-format.js run() no longer opens parse -> file_path -> /\\.(ext)$/ test: the launcher gate is invalid, remove or re-derive it');
  const endings = m[1].split('|');
  assert.deepStrictEqual([...endings].sort(), ['js', 'jsx', 'ts', 'tsx']);
  // The effects (formatter spawns) sit only inside that block; the file has exactly these top-level requires.
  assert.strictEqual(js.indexOf('execFileSync(', js.indexOf('function run(')) > js.indexOf('.test(filePath)'), true);
  assert.deepStrictEqual(js.match(/^const .* = require\('[^']+'\);$/gm).map((l) => l.match(/require\('([^']+)'\)/)[1]),
    ['child_process', 'path', '../lib/resolve-formatter', '../lib/hook-output']);
  // Load-time surface of everything run-with-flags requires: these and nothing else.
  assert.deepStrictEqual(rwf.match(/^const .* = require\('[^']+'\);$/gm).map((l) => l.match(/require\('([^']+)'\)/)[1]), ['fs', 'path', 'child_process', './lib/hook-flags', './lib/hook-output']);
  for (const f of ['hook-flags.js', 'hook-output.js']) assert.ok(!/require\(/.test(fs.readFileSync(path.join(HOOKS_LIB, f), 'utf8')), `${f} requires nothing`);
  assert.deepStrictEqual(fs.readFileSync(path.join(HOOKS_LIB, 'resolve-formatter.js'), 'utf8').match(/require\('[^']+'\)/g), ["require('fs')", "require('path')", "require('./package-manager')"]);
  // run-with-flags.js: the plugin-root rule the arm mirrors, argv order, and the 1 MiB caps.
  assert.ok(rwf.includes('if (process.env.CLAUDE_PLUGIN_ROOT && process.env.CLAUDE_PLUGIN_ROOT.trim()) {'));
  assert.ok(rwf.includes('  return __dirname;'));
  assert.ok(rwf.includes('const [, , hookId, relScriptPath, profilesCsv] = process.argv;'));
  assert.ok(rwf.includes('const MAX_STDIN = 1024 * 1024;') && js.includes('const MAX_STDIN = 1024 * 1024;'));
  // Shell: the arm's argv equals the seed's, and its patterns are exactly `<ending>"` for every ending plus the
  // \u00XY escape prefixes of every character of every ending and the dot.
  const { hookId, rel, rel2, rel3, pats } = afArm();
  const settings = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', '..', 'settings.json'), 'utf8'));
  const seed = settings.hooks.PostToolUse.flatMap((g) => (g.hooks || []).map((h) => ({ matcher: g.matcher, command: h.command }))).filter((x) => x.command.includes('post:edit:format'));
  assert.strictEqual(seed.length, 1);
  assert.strictEqual(seed[0].matcher, 'Edit|Write|MultiEdit');
  assert.strictEqual(seed[0].command, `"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/run-with-flags.js" "${hookId}" "${rel}" "standard,strict"`);
  assert.strictEqual(rel2, rel);
  assert.strictEqual(rel3, rel);
  assert.strictEqual(hookId, 'post:edit:format');
  assert.strictEqual(rel, 'PostToolUse/auto-format.js');
  const wanted = new Set(['.', ...endings.join('').split('')].map((c) => `\\u00${c.charCodeAt(0).toString(16).padStart(2, '0')[0]}`));
  assert.deepStrictEqual([...wanted].sort(), ['\\u002', '\\u006', '\\u007']);
  assert.deepStrictEqual([...pats].sort(), [...endings.map((e) => `.${e}"`), ...wanted].sort());
  assert.strictEqual((sh.match(/\[ -z "\$_hn_stdin" \] \|\| \{ printf '%s' "\$_hn_buf" \| /g) || []).length, 2);
});

test('auto-format gate: only post:edit:format is registered on PostToolUse Edit|Write|MultiEdit (the only post-phase hook there)', () => {
  const settings = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', '..', 'settings.json'), 'utf8'));
  const onEdit = [];
  for (const g of settings.hooks.PostToolUse) {
    const ms = !g.matcher ? ['*'] : g.matcher.split('|');
    if (ms.includes('*') || ms.includes('Edit') || ms.includes('Write') || ms.includes('MultiEdit')) for (const h of g.hooks) onEdit.push([g.matcher, h.command]);
  }
  assert.deepStrictEqual(onEdit, [['Edit|Write|MultiEdit', '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/run-with-flags.js" "post:edit:format" "PostToolUse/auto-format.js" "standard,strict"']]);
});

test('auto-format gate: the predicate never skips a payload whose DECODED file_path matches the JS regex (randomised spellings)', () => {
  const { pats } = afArm();
  const RE = /\.(ts|tsx|js|jsx)$/;
  let seed = 12345;
  const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
  const names = ['x.js', 'x.jsx', 'x.ts', 'x.tsx', 'a/b.test.tsx', 'x.json', 'x.jsonl', 'x.mjs', 'x.cjs', 'x.js\n', 'x.ts ', 'x.js\\', 'x.js"', 'é.ts', 'x.t', 'x', 'jsx', 'a b/c d.ts', '.js', 'x.ts '];
  // JSON string body with a random subset of characters rewritten as \uXXXX (either hex case).
  const spell = (s) => {
    let out = '';
    for (const ch of s) {
      const enc = JSON.stringify(ch).slice(1, -1);
      if (rnd() < 0.06 && ch.charCodeAt(0) < 0x10000) { const h = ch.charCodeAt(0).toString(16).padStart(4, '0'); out += `\\u${rnd() < 0.5 ? h : h.toUpperCase()}`; } else out += enc;
    }
    assert.strictEqual(JSON.parse(`"${out}"`), s);
    return out;
  };
  let acts = 0; let skipped = 0;
  for (let i = 0; i < 4000; i += 1) {
    const fp = `/p${Math.floor(rnd() * 3)}/${names[Math.floor(rnd() * names.length)]}`;
    const shape = Math.floor(rnd() * 3);
    const val = shape === 0 ? `"${spell(fp)}"` : shape === 1 ? `["${spell('q')}","${spell(fp)}"]` : `[["${spell(fp)}"]]`;
    const raw = `{"transcript_path":"/h/.claude/projects/x/abc.jsonl","tool_name":"Edit","tool_input":{"file_path":${val}},"tool_response":{"n":1}}`;
    const decoded = JSON.parse(raw).tool_input.file_path;
    const hit = Boolean(decoded) && RE.test(decoded);
    const runs = afRunsNode(pats, raw);
    if (hit) acts += 1;
    if (!runs) skipped += 1;
    if (hit) assert.ok(runs, `skipped a payload run() acts on: ${raw}`);
  }
  assert.ok(acts > 500 && skipped > 500, `degenerate sample: ${acts} act, ${skipped} skip`);
});

test('auto-format gate: argv-exact, skips without node, hands node every byte otherwise', () => {
  const base = mkTmp('node-hook-afgate-');
  try {
    const dir = path.join(base, 'real');
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'node'), '#!/bin/sh\nprintf "[%s]" "$(cat; echo x)"\n', { mode: 0o755 });
    // A hooks root with the registered script, and one without it.
    const withHooks = path.join(base, 'with');
    const withoutHooks = path.join(base, 'without');
    fs.mkdirSync(path.join(withHooks, 'PostToolUse'), { recursive: true });
    fs.writeFileSync(path.join(withHooks, 'PostToolUse', 'auto-format.js'), '');
    fs.mkdirSync(withoutHooks);
    const baseEnv = { ...buildEnv(), PATH: `${dir}:/usr/bin:/bin` };
    delete baseEnv.CLAUDE_PLUGIN_ROOT;
    const run = (args, input, extraEnv = {}) => spawnSync('/bin/sh', [LAUNCHER, ...args], { env: { ...baseEnv, ...extraEnv }, input, encoding: 'utf8' });
    const rwf = `${withHooks}/run-with-flags.js`;
    const reg = [rwf, 'post:edit:format', 'PostToolUse/auto-format.js', 'standard,strict'];
    const md = '{"transcript_path":"/h/a.jsonl","tool_input":{"file_path":"/a/b.md"}}\n';
    const ts = '{"transcript_path":"/h/a.jsonl","tool_input":{"file_path":"/a/b.ts"}}\n\n\n';
    assert.strictEqual(run(reg, md).stdout, '', 'registered argv, non-JS: skipped, no node');
    assert.strictEqual(run(reg, md).status, 0);
    assert.strictEqual(run(reg, ts).stdout, `[${ts}x]`, 'registered argv, .ts: node, every byte incl. trailing newlines');
    assert.strictEqual(run(reg, '{"p":"/a/b.\\u006As"}').stdout, '[{"p":"/a/b.\\u006As"}x]');
    assert.strictEqual(run(reg, '{"p":"/a/b.js\\n"}').stdout, '', '`.js\\n"` is not `.js"` and not an escape prefix');
    assert.strictEqual(run(reg, '{"p":"/a/b.json","q":"\\u001b"}').stdout, '');
    // Any other argv shape starts node (the arm is argv-exact), including the other run-with-flags registrations.
    const others = [
      [rwf, 'pre:git-guard', 'PreToolUse/git-guard.js', 'standard,strict'],
      [rwf, 'post:edit:format', 'PostToolUse/other.js', 'standard,strict'],
      [rwf, 'post:edit:format2', 'PostToolUse/auto-format.js', 'standard,strict'],
      [rwf, 'POST:EDIT:FORMAT', 'PostToolUse/auto-format.js', 'standard,strict'],
      [rwf, 'post:edit:format'],
      [rwf],
      [`${withHooks}/run-with-flags.json`, 'post:edit:format', 'PostToolUse/auto-format.js'],
      [`${withHooks}/not-run-with-flags.js`, 'post:edit:format', 'PostToolUse/auto-format.js'],
      ['run-with-flags.js', 'post:edit:format', 'PostToolUse/auto-format.js'],
    ];
    // (`not-run-with-flags.js` still matches the glob `*/run-with-flags.js`? No: the `/` before `run` is required.)
    for (const args of others) assert.strictEqual(run(args, md).stdout, `[${md}x]`, args.join(' '));
    // $4 (profiles) does not matter: a skipped payload is silent for every profile string.
    for (const prof of ['minimal', 'strict', 'standard', 'nonsense', '']) assert.strictEqual(run([...reg.slice(0, 3), prof], md).stdout, '', prof);
    assert.strictEqual(run(reg.slice(0, 3), md).stdout, '');
    // Env: HOOK_DISABLED / HOOK_PROFILE never matter to a skip; CLAUDE_PLUGIN_ROOT must be empty or unset.
    assert.strictEqual(run(reg, md, { HOOK_DISABLED: 'post:edit:format', HOOK_PROFILE: 'minimal' }).stdout, '');
    assert.strictEqual(run(reg, md, { CLAUDE_PLUGIN_ROOT: '' }).stdout, '');
    for (const v of [' ', '\t', '  \n', '/x', withHooks, withoutHooks]) assert.strictEqual(run(reg, md, { CLAUDE_PLUGIN_ROOT: v }).stdout, `[${md}x]`, JSON.stringify(v));
    // A hooks dir without the registered script (run-with-flags would print "Script not found"): node runs.
    assert.strictEqual(run([`${withoutHooks}/run-with-flags.js`, ...reg.slice(1)], md).stdout, `[${md}x]`);
    // An unreadable script (readFileSync would throw into main().catch's stderr line): node runs.
    const script = path.join(withHooks, 'PostToolUse', 'auto-format.js');
    fs.chmodSync(script, 0);
    if (process.getuid && process.getuid() !== 0) assert.strictEqual(run(reg, md).stdout, `[${md}x]`, 'unreadable script: node runs');
    fs.chmodSync(script, 0o644);
    assert.strictEqual(run(reg, md).stdout, '');
  } finally { rmTmp(base); }
});
