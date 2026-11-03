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

// ---------------------------------------------------------------------------
// pr-record stdin gate: the launcher literals must be the JS predicate (#369 pass 3)
// ---------------------------------------------------------------------------

const PR_RECORD_JS = path.resolve(__dirname, '..', 'PostToolUse', 'pr-record.js');

test('pr-record gate drift: the launcher skips only when run() returns at its first condition after the parse', () => {
  const js = fs.readFileSync(PR_RECORD_JS, 'utf8');
  const sh = fs.readFileSync(LAUNCHER, 'utf8');
  // JS: the early return is the first statement after parse/cmd, with nothing in between.
  const m = js.match(/function run\(rawInput\) \{\n  try \{\n    const input = JSON\.parse\(rawInput\);\n    const cmd = \(input\.tool_input && input\.tool_input\.command\) \|\| '';\n    if \(!cmd\.includes\('([^']*)'\)\) return rawInput;\n/);
  assert.ok(m, 'pr-record.js run() no longer opens parse -> cmd -> includes() early return: the launcher gate is invalid, remove or re-derive it');
  const literal = m[1];
  assert.strictEqual(literal, 'gh pr create');
  // Entry: stdin accumulated up to the cap, then run() output through the quiet writer.
  assert.ok(js.includes('if (data.length < 1024 * 1024) data += c;'));
  assert.ok(js.includes('writeHookOutput(run(data), data);'));
  // Top-level requires: a new one is a new load-time surface to re-audit before the gate stays valid.
  assert.deepStrictEqual(js.match(/^const .* = require\('[^']+'\);$/gm).map((l) => l.match(/require\('([^']+)'\)/)[1]),
    ['fs', 'os', 'path', 'child_process', 'perf_hooks', '../lib/hook-output.js', '../lib/session-prs.js']);

  // Shell: the arm is path-exact and holds exactly the literal plus the \u00XY escape prefixes of
  // every character of it (U+0020 -> \u002, U+0061..U+0074 -> \u006 / \u007).
  const arm = sh.match(/ {2}\*\/PostToolUse\/pr-record\.js\)\n {4}_hn_buf=\$\(tr '\\0' '\\1'; echo x\)\n {4}_hn_buf=\$\{_hn_buf%x\}\n {4}case \$_hn_buf in\n {6}(.*)\) _hn_stdin=1 ;;\n {6}\*\) exit 0 ;;\n {4}esac\n {4};;\n/);
  assert.ok(arm, 'launcher pr-record arm not found in its expected shape');
  const pats = arm[1].split(' | ').map((p) => p.replace(/^\*'/, '').replace(/'\*$/, ''));
  const wanted = new Set(literal.split('').map((c) => `\\u00${c.charCodeAt(0).toString(16).padStart(2, '0')[0]}`));
  assert.deepStrictEqual(pats, [literal, ...[...wanted].sort()]);
  assert.deepStrictEqual([...wanted].sort(), ['\\u002', '\\u006', '\\u007']);
  // Both exec sites hand node the buffered bytes when the gate did not skip.
  assert.strictEqual((sh.match(/\[ -z "\$_hn_stdin" \] \|\| \{ printf '%s' "\$_hn_buf" \| /g) || []).length, 2);
});

test('pr-record gate: the seed registers pr-record through the launcher as the only PostToolUse hook on Bash', () => {
  const settings = JSON.parse(fs.readFileSync(path.resolve(__dirname, '..', '..', 'settings.json'), 'utf8'));
  const onBash = [];
  for (const g of settings.hooks.PostToolUse) {
    if (!g.matcher || g.matcher === '*' || g.matcher.split('|').includes('Bash')) for (const h of g.hooks) onBash.push(h.command);
  }
  assert.deepStrictEqual(onBash, ['"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PostToolUse/pr-record.js"']);
});

test('pr-record gate: the arm is path-exact, skips without node, and hands node every byte otherwise', () => {
  const base = mkTmp('node-hook-prgate-');
  try {
    const dir = path.join(base, 'real');
    fs.mkdirSync(dir);
    // A fake node that echoes its stdin exactly (trailing newlines kept through an `x` sentinel).
    fs.writeFileSync(path.join(dir, 'node'), '#!/bin/sh\nprintf "[%s]" "$(cat; echo x)"\n', { mode: 0o755 });
    const env = { ...buildEnv(), PATH: `${dir}:/usr/bin:/bin` };
    const run = (script, input) => spawnSync('/bin/sh', [LAUNCHER, script], { env, input, encoding: 'utf8' });
    const hook = '/x/PostToolUse/pr-record.js';
    assert.strictEqual(run(hook, '{"c":"ls"}\n').stdout, '');
    assert.strictEqual(run(hook, '{"c":"ls"}\n').status, 0);
    assert.strictEqual(run(hook, '{"c":"gh pr create"}\n\n\n').stdout, '[{"c":"gh pr create"}\n\n\nx]');
    assert.strictEqual(run(hook, '{"c":"gh\\u0020pr"}').stdout, '[{"c":"gh\\u0020pr"}x]');
    assert.strictEqual(run(hook, '{"c":"\\u001b[0m"}').stdout, '');
    for (const other of ['/x/PostToolUse/pr-record.json', '/x/PreToolUse/pr-record.js', 'pr-record.js', '/x/PostToolUse/not-pr-record.js']) {
      assert.strictEqual(run(other, '{"c":"ls"}').stdout, '[{"c":"ls"}x]', other);
    }
  } finally { rmTmp(base); }
});

test('an inherited _hn_stdin / _hn_buf in the caller env never replaces another hook\'s stdin', () => {
  const base = mkTmp('node-hook-envleak-');
  try {
    const dir = path.join(base, 'real');
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'node'), '#!/bin/sh\nprintf "[%s]" "$(cat; echo x)"\n', { mode: 0o755 });
    const env = { ...buildEnv(), PATH: `${dir}:/usr/bin:/bin`, _hn_stdin: '1', _hn_buf: 'EVIL' };
    for (const script of ['/x/PreToolUse/git-guard.js', '/x/PostToolUse/not-pr-record.js']) {
      const r = spawnSync('/bin/sh', [LAUNCHER, script], { env, input: '{"a":1}', encoding: 'utf8' });
      assert.strictEqual(r.stdout, '[{"a":1}x]', script);
    }
    // The gated hook still skips a no-literal payload and still hands node the real bytes otherwise.
    const hook = '/x/PostToolUse/pr-record.js';
    assert.strictEqual(spawnSync('/bin/sh', [LAUNCHER, hook], { env, input: '{"c":"ls"}', encoding: 'utf8' }).stdout, '');
    assert.strictEqual(spawnSync('/bin/sh', [LAUNCHER, hook], { env, input: '{"c":"gh pr create"}', encoding: 'utf8' }).stdout, '[{"c":"gh pr create"}x]');
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
