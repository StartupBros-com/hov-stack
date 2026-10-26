'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const {
  runHook,
  spawnNode,
  assertQuietPassThrough,
  assertPreToolUseDeny,
  mkTmp,
  rmTmp,
} = require('./lib/harness');

const HOOK = 'PreToolUse/heavy-job-admission.js';
const HEADROOM = path.resolve(__dirname, '..', '..', 'scripts', 'heavy-job-headroom.js');
const RUNNER = path.resolve(__dirname, '..', 'lib', 'heavy-job-admission-run.sh');

const bash = (command) => ({
  tool_name: 'Bash',
  cwd: '/home/user/SITES/demo',
  session_id: 'heavyjob12345678',
  tool_input: { command },
});

function updatedCommand(res) {
  assert.strictEqual(res.code, 0, res.stderr);
  assert.notStrictEqual(res.stdout.trim(), '', 'the hook passed the command through without wrapping it');
  const out = JSON.parse(res.stdout);
  assert.strictEqual(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, undefined);
  assert.strictEqual(typeof out.hookSpecificOutput.updatedInput.command, 'string');
  return out.hookSpecificOutput.updatedInput.command;
}

function writeProc(root, { totalGiB = 40, availableGiB = 10, swapGiB = 8, some = 1, full = 0.1 } = {}) {
  fs.mkdirSync(path.join(root, 'pressure'), { recursive: true });
  const kib = (gib) => Math.round(gib * 1024 * 1024);
  fs.writeFileSync(path.join(root, 'meminfo'), [
    `MemTotal:       ${kib(totalGiB)} kB`,
    `MemAvailable:   ${kib(availableGiB)} kB`,
    `SwapFree:       ${kib(swapGiB)} kB`,
    '',
  ].join('\n'));
  fs.writeFileSync(path.join(root, 'pressure', 'memory'), [
    `some avg10=${some.toFixed(2)} avg60=0.00 avg300=0.00 total=1`,
    `full avg10=${full.toFixed(2)} avg60=0.00 avg300=0.00 total=1`,
    '',
  ].join('\n'));
}

function runShell(command, env = {}, { cwd, input = '' } = {}) {
  return new Promise((resolve) => {
    const shellEnv = { ...process.env };
    delete shellEnv.CLAUDE_CODE_TOOL_MEMORY_LIMIT;
    Object.assign(shellEnv, env);
    const child = spawn('/bin/bash', ['-c', command], { env: shellEnv, cwd });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(input);
  });
}

function writeFakeSystemdRun(bin) {
  const file = path.join(bin, 'systemd-run');
  fs.writeFileSync(file, [
    '#!/bin/sh',
    'if [ -n "$SYSTEMD_ARGV_MARKER" ]; then printf "%s\\n" "$@" >"$SYSTEMD_ARGV_MARKER"; fi',
    'if [ "$SYSTEMD_RUN_FAIL" = 1 ]; then echo "fake systemd manager unavailable" >&2; exit 69; fi',
    'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done',
    'if [ "$#" -eq 0 ]; then echo "fake systemd missing subject" >&2; exit 70; fi',
    'shift',
    'exec "$@"',
    '',
  ].join('\n'));
  fs.chmodSync(file, 0o755);
}

async function waitForFile(file, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(file) && fs.statSync(file).size > 0) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for ${file}`);
}

test('classifies heavy commands only at actual Bash command positions', async () => {
  for (const command of [
    'tsc --noEmit',
    'next build',
    'astro build',
    'astro check',
    'velite',
    'bun run build',
    'bun run typecheck',
    'pnpm run compile',
    'pnpm build',
    'bunx tsc --noEmit',
    'pnpm exec next build',
    'pnpm exec astro check',
    'pnpm exec velite',
    'turbo run build --cache-dir=.turbo',
    'pnpm exec turbo run typecheck',
    'env NODE_ENV=production command tsc --noEmit',
    'sudo -u will tsc --noEmit',
    'nice -n 5 tsc --noEmit',
    'timeout --signal TERM 10s tsc --noEmit',
    "bash -lc 'pnpm build'",
    "bash -o pipefail -c 'pnpm build'",
    "bash +o history -c 'pnpm build'",
    "bash -O extglob -c 'pnpm build'",
    "bash +O extglob -c 'pnpm build'",
    "bash --rcfile /tmp/claude-heavy-rc -c 'pnpm build'",
    "bash --init-file=/tmp/claude-heavy-rc -c 'pnpm build'",
    'pnpm --filter app exec -- tsc --noEmit',
    'pnpm -C apps/web run build',
    'pnpm --filter app run --if-present build:web',
    'pnpm run --filter app typecheck:ci',
    'bun --cwd apps/web run build:app',
    'bun --cwd=apps/web run --if-present compile:assets',
    'bunx --bun tsc --noEmit',
    '>build.log pnpm run build:redirection',
    '2>typecheck.err bun run typecheck:redirection',
    'npm run build:npm',
    'npm --workspace app run typecheck:npm',
    'npm exec -- tsc --noEmit',
    'yarn run compile:yarn',
    'yarn --cwd apps/web build:yarn',
    'yarn exec tsc --noEmit',
    'TURBO_CONCURRENCY=1 pnpm build',
    'echo "$(pnpm build)"',
    'echo "`pnpm build`"',
    "eval 'pnpm run build:eval'",
  ]) {
    const res = await runHook(HOOK, bash(command));
    const updated = updatedCommand(res);
    // The rewritten TEXT names the script file and the headroom probe and
    // carries no command substitution: the worktree-isolation verifier
    // refuses `$( )` in argument position, which is what made every admitted
    // command un-runnable in isolated sessions (dotfiles #864).
    assert.match(updated, /^bash '[^']*\/hooks\/lib\/heavy-job-admission-run\.sh' /);
    assert.match(updated, /heavy-job-headroom\.js/);
    // The wrapper adds none of its own; an original that already carries one
    // is the agent's own shape and the verifier's own business.
    const count = (s, needle) => s.split(needle).length - 1;
    assert.strictEqual(count(updated, '$('), count(command, '$('),
      `rewritten command must add no command substitution: ${updated}`);
    assert.strictEqual(count(updated, '`'), count(command, '`'), 'rewritten command must add no backticks');
    // The wrapper's mechanics live in the file, verbatim.
    const supervisor = fs.readFileSync(path.resolve(__dirname, '..', 'lib', 'heavy-job-admission-run.sh'), 'utf8');
    assert.match(supervisor, /exec \{__claude_heavy_lock_fd\}>/);
    assert.match(supervisor, /flock.*-n/);
    assert.match(supervisor, /export TURBO_CONCURRENCY=1/);
  }

  for (const command of [
    'printf %s "tsc --noEmit"',
    "echo 'next build'",
    '# astro check',
    'printf velite',
    'pnpm run lint',
    'bun test',
    'turbo run lint',
    "echo '$(pnpm build)'",
    "echo '`pnpm build`'",
    "eval 'pnpm run lint'",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('supervisor preserves original command arguments and environment', async () => {
  const tmp = mkTmp('heavy-command-semantics-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const marker = path.join(tmp, 'arguments');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf "%s\\n" "$FOO" "$@" >"$HEAVY_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const command = "  FOO='a b' pnpm run build -- --flag=\"x y\"  \n";
    const updated = updatedCommand(await runHook(HOOK, bash(command)));
    const res = await runShell(updated, {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_MARKER: marker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.deepStrictEqual(fs.readFileSync(marker, 'utf8').trim().split('\n'), [
      'a b', 'run', 'build', '--', '--flag=x y',
    ]);
  } finally {
    rmTmp(tmp);
  }
});

test('rejects recognized background heavy jobs', async () => {
  for (const command of [
    'tsc --noEmit &',
    'nohup pnpm run build >build.log 2>&1 &',
    'next build | tee build.log &',
    "bash -lc 'astro check &'",
    '(pnpm build) &',
    '(printf ready; pnpm build) &',
  ]) {
    const res = await runHook(HOOK, bash(command));
    assertPreToolUseDeny(res);
    assert.match(JSON.parse(res.stdout).hookSpecificOutput.permissionDecisionReason, /foreground|background/i);
  }
});

test('allows unrelated background work beside a foreground heavy job', async () => {
  for (const command of [
    'printf ready & pnpm build',
    '(printf ready &) && pnpm build',
  ]) {
    const updated = updatedCommand(await runHook(HOOK, bash(command)));
    assert.match(updated, /heavy-job-admission-run\.sh/);
  }
});

test('rejects heavy commands that override the Turbo concurrency cap', async () => {
  for (const command of [
    'TURBO_CONCURRENCY=99 pnpm build',
    'env TURBO_CONCURRENCY=99 pnpm build',
    'turbo run build --parallel',
    'turbo --parallel build',
    'turbo run typecheck --concurrency 99',
    'turbo --concurrency=99 run compile',
  ]) {
    const res = await runHook(HOOK, bash(command));
    assertPreToolUseDeny(res);
    assert.match(JSON.parse(res.stdout).hookSpecificOutput.permissionDecisionReason, /concurrency|parallel/i);
  }
});

test('fails closed when eval payload is dynamic', async () => {
  for (const command of [
    'eval "$HEAVY_COMMAND"',
    'eval "${PACKAGE_MANAGER} run build"',
    'eval "$(printf pnpm) build"',
  ]) {
    const res = await runHook(HOOK, bash(command));
    assertPreToolUseDeny(res);
    assert.match(JSON.parse(res.stdout).hookSpecificOutput.permissionDecisionReason, /dynamic.*eval|eval.*dynamic/i);
  }
});

// Heredoc bodies and comments (dotfiles #1853): lib/heredoc-scan.js removes
// data bodies and comments from the text this hook classifies and hands back
// the bodies that run. Each case below failed on the lexer before #1853; the
// regression test pins shapes it already handled.
test('#1853: an apostrophe in a commit-message heredoc does not hide a later heavy job', async () => {
  const updated = updatedCommand(await runHook(HOOK, bash("git commit -q -F - <<'EOF'\nfix: it's done\nEOF\npnpm build")));
  assert.match(updated, /heavy-job-admission-run\.sh/);
});

test('#1853: a heavy job written only into a file by cat is data, not a heavy job', async () => {
  assertQuietPassThrough(await runHook(HOOK, bash("cat > notes.md <<'EOF'\npnpm build\nEOF")));
  assertQuietPassThrough(await runHook(HOOK, bash('cat <<EOF > notes.md\npnpm build\nEOF')));
  // A file handed to gh as a PR body is read, not run.
  assertQuietPassThrough(await runHook(HOOK, bash("cat > body.md <<'EOF'\npnpm build\nEOF\ngh pr create --body-file body.md")));
});

test('#1853: an eval written only into a file is data, not a dynamic eval', async () => {
  assertQuietPassThrough(await runHook(HOOK, bash("cat > notes.md <<'EOF'\neval \"$HEAVY_COMMAND\"\nEOF")));
});

test('#1853: an odd double quote in a heredoc inside "$( )" does not hide a later heavy job', async () => {
  const updated = updatedCommand(await runHook(HOOK, bash('git commit -q -m "$(cat <<\'EOF\'\nsay "hi\nEOF\n)" && pnpm build')));
  assert.match(updated, /heavy-job-admission-run\.sh/);
});

test('#1853: an apostrophe in a heredoc assigned through $( ) does not hide a later heavy job', async () => {
  const updated = updatedCommand(await runHook(HOOK, bash("msg=$(cat <<'EOF'\nit's\nEOF\n)\npnpm build")));
  assert.match(updated, /heavy-job-admission-run\.sh/);
});

test('#1853: analyzeCommand, which shape-rewrite and grep-cost-guard defer to, reads heredocs the same way', () => {
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission.js');
  assert.strictEqual(analyzeCommand("cat > notes.md <<'EOF'\npnpm build\nEOF").heavy, false);
  assert.strictEqual(analyzeCommand("git commit -q -F - <<'EOF'\nit's\nEOF\npnpm build").heavy, true);
  assert.strictEqual(analyzeCommand('(true)# pnpm build').heavy, false);
  assert.strictEqual(analyzeCommand("(true)# it's a note\npnpm build").heavy, true);
  assert.strictEqual(analyzeCommand('[[ a =~ ^(a)#b ]]; pnpm build').heavy, true);
});

// Line continuations: bash removes backslash-newline before reading `<<` and
// the delimiter, and joins an unquoted body's lines before comparing them.
test('#1853: line continuations around heredocs neither hide a heavy job nor turn data into one', () => {
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission.js');
  assert.strictEqual(analyzeCommand("cat <<EOF >/dev/null\nx \\\nEOF\nit's\nEOF\npnpm build").heavy, true);
  assert.strictEqual(analyzeCommand("git commit -q -F - <\\\n<'EOF'\nfix: it's done\nEOF\npnpm build").heavy, true);
  assert.strictEqual(analyzeCommand('cat <<E\\\nOF\n$(pnpm build)\nEOF').heavy, true);
  assert.strictEqual(analyzeCommand('bash <<EOF\n\\$(pnpm build)\nEOF').heavy, true);
  assert.strictEqual(analyzeCommand('cat <<EOF >/dev/null\nx \\\nEOF\npnpm build\nEOF').heavy, false);
});

test('#1853: a command nested past the scan limit is denied, not admitted unscanned', async () => {
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission.js');
  const deep = (levels, tail) => `${'echo "$('.repeat(levels)}cat <<'H0'\nbody\nH0\n${')"'.repeat(levels)}\n${tail}`;
  assert.throws(() => analyzeCommand(deep(40, 'true')), { name: 'NestingTooDeep' });
  const res = await runHook(HOOK, bash(deep(40, 'true')));
  assertPreToolUseDeny(res);
  assert.match(JSON.parse(res.stdout).hookSpecificOutput.permissionDecisionReason, /nest more than 64 levels deep/);
  assert.strictEqual(analyzeCommand(deep(20, 'pnpm build')).heavy, true);
  assert.strictEqual(analyzeCommand(deep(20, 'true')).heavy, false);
});

test('#1853 regression: bodies that run, substitutions and later lines stay classified', async () => {
  for (const command of [
    "bash <<'EOF'\npnpm build\nEOF",
    "cat <<'EOF' | bash\npnpm build\nEOF",
    "cat > s.sh <<'EOF'\npnpm build\nEOF\nbash s.sh",
    "while read -r l; do $l; done <<'EOF'\npnpm build\nEOF",
    'cat <<EOF\n$(pnpm build)\nEOF',
    'echo $((x<<y))\npnpm build',
    'cat <<EOF\nbody\nEOF\npnpm build',
    "# it's a note\npnpm build",
    "{ cat <<'EOF'\npnpm build\nEOF\n} | bash",
    "( cat <<'EOF'\npnpm build\nEOF\n) | bash",
    "if true; then cat <<'EOF'\npnpm build\nEOF\nfi | bash",
    "cat > s.sh <<'EOF'\npnpm build\nEOF\nbash < s.sh",
    "cat > s.sh <<'EOF'\npnpm build\nEOF\ncat s.sh | bash",
    "cat > \"$HOME/s.sh\" <<'EOF'\npnpm build\nEOF\nbash \"$HOME/s.sh\"",
    "cat <<'EOF' > >(bash)\npnpm build\nEOF",
    "tee >(bash) <<'EOF'\npnpm build\nEOF",
    "cat <<'EOF' > s.sh\npnpm build\nEOF\nsh -c 'cat s.sh|sh'",
    "cat >> \"$HOME/.bashrc\" <<'EOF'\npnpm build\nEOF\nbash -ic true",
  ]) {
    const updated = updatedCommand(await runHook(HOOK, bash(command)));
    assert.match(updated, /heavy-job-admission-run\.sh/, command);
  }
});

test('headroom accepts safe metrics and exits 75 for unsafe or malformed metrics', async () => {
  const tmp = mkTmp('heavy-headroom-');
  try {
    writeProc(tmp);
    const testEnv = { CLAUDE_HEAVY_JOB_TEST_MODE: '1', CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: tmp };
    let res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 0, res.stderr);

    writeProc(tmp, { availableGiB: 8, swapGiB: 4 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 0, `equality at byte/percentage thresholds must be admitted: ${res.stderr}`);

    writeProc(tmp, { availableGiB: 7, swapGiB: 20 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /MemAvailable/i);
    assert.match(res.stderr, /deferred: transient pressure/i);

    writeProc(tmp, { totalGiB: 100, availableGiB: 19, swapGiB: 20 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /MemAvailable/i);

    writeProc(tmp, { availableGiB: 10, swapGiB: 1 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /SwapFree|combined/i);

    writeProc(tmp, { totalGiB: 100, availableGiB: 25, swapGiB: 4 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /combined/i);

    writeProc(tmp, { some: 5 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /some avg10/i);

    writeProc(tmp, { full: 1 });
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /full avg10/i);

    writeProc(tmp);
    fs.writeFileSync(path.join(tmp, 'pressure', 'memory'), 'some avg10=oops avg60=0.00 avg300=0.00 total=1\n');
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /pressure.*malformed/i);
    assert.match(res.stderr, /failed closed: malformed metric or configuration/i);

    fs.writeFileSync(path.join(tmp, 'meminfo'), 'not metrics\n');
    res = await spawnNode(HEADROOM, { env: testEnv });
    assert.strictEqual(res.code, 75);
    assert.match(res.stderr, /malformed|unreadable/i);
  } finally {
    rmTmp(tmp);
  }
});

test('memory limit normalizer matches the installed Claude value grammar', async () => {
  const accepted = new Map([
    ['4', '4'],
    ['4B', '4'],
    ['4iB', '4'],
    ['1K', '1024'],
    ['1KB', '1024'],
    ['1KiB', '1024'],
    ['1.5M', '1572864'],
    ['2gib', '2147483648'],
    [' 0.001 TIB ', '1099511627'],
  ]);
  for (const [raw, bytes] of accepted) {
    const res = await spawnNode(HEADROOM, { argv: ['--normalize-memory-limit', raw] });
    assert.strictEqual(res.code, 0, `${raw}: ${res.stderr}`);
    assert.strictEqual(res.stdout.trim(), bytes, raw);
  }

  for (const raw of ['', '0', 'false', 'no', 'off', 'none', ' FALSE ']) {
    const res = await spawnNode(HEADROOM, { argv: ['--normalize-memory-limit', raw] });
    assert.strictEqual(res.code, 0, `${raw}: ${res.stderr}`);
    assert.strictEqual(res.stdout, '', raw);
  }
});

test('memory limit normalizer rejects explicit invalid values with exit 75', async () => {
  for (const raw of ['wat', '-1G', '.5G', '1P', '0.1B', '0G', 'true']) {
    const res = await spawnNode(HEADROOM, { argv: ['--normalize-memory-limit', raw] });
    assert.strictEqual(res.code, 75, raw);
    assert.match(res.stderr, /CLAUDE_CODE_TOOL_MEMORY_LIMIT/i, raw);
    assert.match(res.stderr, /failed closed/i, raw);
  }
});

test('production headroom ignores test overrides without the explicit gate', async () => {
  const tmp = mkTmp('heavy-headroom-test-gate-');
  try {
    fs.writeFileSync(path.join(tmp, 'meminfo'), 'not metrics\n');
    fs.mkdirSync(path.join(tmp, 'pressure'));
    fs.writeFileSync(path.join(tmp, 'pressure', 'memory'), 'not metrics\n');
    const res = await spawnNode(HEADROOM, {
      env: {
        CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: tmp,
        CLAUDE_HEAVY_JOB_TEST_MIN_AVAILABLE_PERCENT: '101',
      },
    });
    assert.doesNotMatch(res.stderr, /meminfo MemTotal|percentage threshold is malformed/);
  } finally {
    rmTmp(tmp);
  }
});

test('unsafe headroom prevents the original heavy command from starting', async () => {
  const tmp = mkTmp('heavy-headroom-stop-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const marker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc, { availableGiB: 7, swapGiB: 20 });
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);

    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const res = await runShell(command, {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_MARKER: marker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    assert.strictEqual(res.code, 75, res.stderr);
    assert.strictEqual(fs.existsSync(marker), false, 'unsafe admission executed the original command');
  } finally {
    rmTmp(tmp);
  }
});

test('unsafe runtime directories and symlink lock targets fail closed', async () => {
  const tmp = mkTmp('heavy-runtime-guard-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const marker = path.join(tmp, 'started');
    const unsafeRuntime = path.join(tmp, 'unsafe-runtime');
    const safeRuntime = path.join(tmp, 'safe-runtime');
    fs.mkdirSync(bin);
    fs.mkdirSync(unsafeRuntime, { mode: 0o755 });
    fs.mkdirSync(safeRuntime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const baseEnv = {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_MARKER: marker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
    };

    let res = await runShell(command, { ...baseEnv, CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: unsafeRuntime });
    assert.strictEqual(res.code, 75, res.stderr);
    assert.match(res.stderr, /runtime directory/i);
    assert.strictEqual(fs.existsSync(marker), false);

    fs.symlinkSync(path.join(tmp, 'lock-target'), path.join(safeRuntime, 'claude-heavy-job-admission.lock'));
    res = await runShell(command, { ...baseEnv, CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: safeRuntime });
    assert.strictEqual(res.code, 75, res.stderr);
    assert.match(res.stderr, /lock.*symlink|unsafe lock/i);
    assert.strictEqual(fs.existsSync(marker), false);
  } finally {
    rmTmp(tmp);
  }
});

test('enabled memory limit runs the original command in a capped transient scope', async () => {
  const tmp = mkTmp('heavy-memory-scope-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const argvMarker = path.join(tmp, 'systemd-argv');
    const commandMarker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);

    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const res = await runShell(command, {
      PATH: `${bin}:${process.env.PATH}`,
      SYSTEMD_ARGV_MARKER: argvMarker,
      HEAVY_MARKER: commandMarker,
      CLAUDE_CODE_TOOL_MEMORY_LIMIT: '4G',
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.strictEqual(fs.readFileSync(commandMarker, 'utf8'), 'started');
    const systemdArgv = fs.readFileSync(argvMarker, 'utf8').trim().split('\n');
    assert.deepStrictEqual(systemdArgv.slice(0, 6), [
      '--user', '--scope', '--quiet', '--collect', '--property', 'MemoryMax=4294967296',
    ]);
    assert.strictEqual(systemdArgv[6], '--');
    assert.strictEqual(systemdArgv.at(-2), '-c');
    assert.strictEqual(systemdArgv.at(-1), 'pnpm build');
    assert.strictEqual(systemdArgv.some((arg) => arg.startsWith('MemoryHigh=')), false);
    assert.strictEqual(systemdArgv.some((arg) => arg.startsWith('MemorySwapMax=')), false);
  } finally {
    rmTmp(tmp);
  }
});

test('absent, empty, and disabled limits preserve the direct launch path', async () => {
  const tmp = mkTmp('heavy-memory-disabled-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const systemdMarker = path.join(tmp, 'systemd-invoked');
    const commandMarker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf "started\\n" >>"$HEAVY_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const baseEnv = {
      PATH: `${bin}:${process.env.PATH}`,
      SYSTEMD_ARGV_MARKER: systemdMarker,
      HEAVY_MARKER: commandMarker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    };

    for (const raw of [undefined, '', '0', 'false', 'no', 'off', 'none', ' FALSE ']) {
      const env = { ...baseEnv };
      if (raw !== undefined) env.CLAUDE_CODE_TOOL_MEMORY_LIMIT = raw;
      const res = await runShell(command, env);
      assert.strictEqual(res.code, 0, `${String(raw)}: ${res.stderr}`);
      assert.strictEqual(fs.existsSync(systemdMarker), false, `${String(raw)} invoked systemd-run`);
    }
    assert.strictEqual(fs.readFileSync(commandMarker, 'utf8').trim().split('\n').length, 8);
  } finally {
    rmTmp(tmp);
  }
});

test('started commands preserve every supported exit status on direct and scoped paths', async () => {
  const tmp = mkTmp('heavy-exit-status-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nexit "$2"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const baseEnv = {
      PATH: `${bin}:${process.env.PATH}`,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    };

    for (const memoryLimit of [undefined, '4G']) {
      for (const status of [0, 7, 75, 200, 255]) {
        const env = { ...baseEnv };
        if (memoryLimit !== undefined) env.CLAUDE_CODE_TOOL_MEMORY_LIMIT = memoryLimit;
        const command = updatedCommand(await runHook(HOOK, bash(`pnpm build ${status}`)));
        const res = await runShell(command, env);
        assert.strictEqual(res.code, status, `limit=${String(memoryLimit)} status=${status}: ${res.stderr}`);
      }
    }
  } finally {
    rmTmp(tmp);
  }
});

test('SIGINT during admission prevents launch, holds the lock until drain, returns 130, and permits reuse', async () => {
  const tmp = mkTmp('heavy-admission-cancel-');
  let runner;
  try {
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const headroom = path.join(tmp, 'barrier-headroom.js');
    const supervisorMarker = path.join(tmp, 'supervisor');
    const startMarker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    fs.writeFileSync(headroom, [
      "'use strict';",
      "const fs = require('node:fs');",
      "if (process.argv[2] === '--normalize-memory-limit') process.exit(0);",
      'if (!fs.existsSync(process.env.HEAVY_SUPERVISOR_MARKER)) {',
      '  fs.writeFileSync(process.env.HEAVY_SUPERVISOR_MARKER, String(process.ppid));',
      "  process.kill(process.ppid, 'SIGSTOP');",
      '}',
      '',
    ].join('\n'));
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_START_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const env = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_SUPERVISOR_MARKER: supervisorMarker,
      HEAVY_START_MARKER: startMarker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    };
    runner = spawn('/bin/bash', [RUNNER, process.execPath, headroom, 'pnpm build first'], {
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    runner.stderr.on('data', (chunk) => { stderr += chunk; });
    const closed = new Promise((resolve) => runner.once('close', (code, signal) => resolve({ code, signal })));

    await waitForFile(supervisorMarker);
    const supervisorPid = Number(fs.readFileSync(supervisorMarker, 'utf8'));
    assert.strictEqual(supervisorPid, runner.pid, 'admission barrier must stop the runner itself');
    const stoppedDeadline = Date.now() + 2_000;
    let supervisorState;
    while (Date.now() < stoppedDeadline) {
      const stat = fs.readFileSync(`/proc/${supervisorPid}/stat`, 'utf8');
      supervisorState = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[0];
      if (supervisorState === 'T') break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.strictEqual(supervisorState, 'T', 'admission barrier must stop the supervisor before SIGINT');
    assert.strictEqual(fs.existsSync(startMarker), false, 'admission barrier executed the workload');

    process.kill(supervisorPid, 'SIGINT');
    const contending = await runShell(
      `/bin/bash '${RUNNER}' '${process.execPath}' '${headroom}' 'pnpm build contending'`,
      env,
    );
    assert.strictEqual(contending.code, 75, contending.stderr);
    assert.match(contending.stderr, /another heavy job is already running/i);
    assert.strictEqual(fs.existsSync(startMarker), false, 'queued SIGINT released the lock or launched a workload');

    process.kill(supervisorPid, 'SIGCONT');
    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('SIGINT admission cancellation did not finish')), 2_000)),
    ]);
    assert.deepStrictEqual(result, { code: 130, signal: null }, stderr);
    assert.strictEqual(fs.existsSync(startMarker), false, 'cancelled admission launched the command');

    const reuse = await runShell(
      `/bin/bash '${RUNNER}' '${process.execPath}' '${headroom}' 'pnpm build reuse'`,
      env,
    );
    assert.strictEqual(reuse.code, 0, reuse.stderr);
    assert.strictEqual(fs.readFileSync(startMarker, 'utf8'), 'started');
  } finally {
    if (runner && runner.exitCode === null && runner.signalCode === null) {
      try { process.kill(-runner.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    rmTmp(tmp);
  }
});

// SIGINT and SIGTERM reach the same cancellation path but carry different
// statuses, so the barrier above cannot stand in for this one.
test('SIGTERM during admission prevents launch and returns its cancellation status', async () => {
  const tmp = mkTmp('heavy-admission-term-');
  let runner;
  try {
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const headroom = path.join(tmp, 'barrier-headroom.js');
    const supervisorMarker = path.join(tmp, 'supervisor');
    const startMarker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    fs.writeFileSync(headroom, [
      "'use strict';",
      "const fs = require('node:fs');",
      "if (process.argv[2] === '--normalize-memory-limit') process.exit(0);",
      'fs.writeFileSync(process.env.HEAVY_SUPERVISOR_MARKER, String(process.ppid));',
      "process.kill(process.ppid, 'SIGSTOP');",
      '',
    ].join('\n'));
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_START_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const env = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_SUPERVISOR_MARKER: supervisorMarker,
      HEAVY_START_MARKER: startMarker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    };
    runner = spawn('/bin/bash', [RUNNER, process.execPath, headroom, 'pnpm build'], {
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    runner.stderr.on('data', (chunk) => { stderr += chunk; });
    const closed = new Promise((resolve) => runner.once('close', (code, signal) => resolve({ code, signal })));

    await waitForFile(supervisorMarker);
    const supervisorPid = Number(fs.readFileSync(supervisorMarker, 'utf8'));
    assert.strictEqual(supervisorPid, runner.pid, 'admission barrier must stop the runner itself');
    const stoppedDeadline = Date.now() + 2_000;
    let supervisorState;
    while (Date.now() < stoppedDeadline) {
      const stat = fs.readFileSync(`/proc/${supervisorPid}/stat`, 'utf8');
      supervisorState = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[0];
      if (supervisorState === 'T') break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.strictEqual(supervisorState, 'T', 'admission barrier must stop the supervisor before SIGTERM');

    process.kill(supervisorPid, 'SIGTERM');
    process.kill(supervisorPid, 'SIGCONT');
    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('cancelled admission did not finish')), 2_000)),
    ]);
    assert.deepStrictEqual(result, { code: 143, signal: null }, stderr);
    assert.strictEqual(fs.existsSync(startMarker), false, 'cancelled admission launched the command');
  } finally {
    if (runner && runner.exitCode === null && runner.signalCode === null) {
      try { process.kill(-runner.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    rmTmp(tmp);
  }
});

test('admitted commands and descendants do not inherit the lock descriptor', async () => {
  const tmp = mkTmp('heavy-lock-fd-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const marker = path.join(tmp, 'descriptors');
    const inspector = path.join(bin, 'inspect-heavy-fds');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(inspector, [
      '#!/bin/sh',
      'found=clean',
      'for fd in /proc/$$/fd/*; do',
      '  target=$(readlink -- "$fd") || continue',
      '  if [ "$target" = "$HEAVY_LOCK_PATH" ]; then found="inherited:${fd##*/}"; fi',
      'done',
      'printf "%s:%s\\n" "$1" "$found" >>"$HEAVY_FD_MARKER"',
      '',
    ].join('\n'));
    fs.chmodSync(inspector, 0o755);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\n"$HEAVY_INSPECTOR" command\n"$HEAVY_INSPECTOR" descendant\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const res = await runShell(command, {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_INSPECTOR: inspector,
      HEAVY_FD_MARKER: marker,
      HEAVY_LOCK_PATH: path.join(runtime, 'claude-heavy-job-admission.lock'),
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    assert.strictEqual(res.code, 0, res.stderr);
    assert.deepStrictEqual(fs.readFileSync(marker, 'utf8').trim().split('\n'), [
      'command:clean',
      'descendant:clean',
    ]);
  } finally {
    rmTmp(tmp);
  }
});

test('cancellation drains the owned group and returns a TERM-trapped child status', async () => {
  const tmp = mkTmp('heavy-launch-cancel-');
  let runner;
  let workloadPgid;
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const topologyMarker = path.join(tmp, 'topology');
    const signalMarker = path.join(tmp, 'signal');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(path.join(bin, 'pnpm'), [
      '#!/bin/sh',
      'trap \'printf term >"$HEAVY_SIGNAL_MARKER"; exit 42\' TERM',
      'supervisor=$PPID',
      'child=$$',
      'pgid=$(ps -o pgid= -p "$$")',
      'printf "%s %s %s\\n" "$supervisor" "$child" "$pgid" >"$HEAVY_TOPOLOGY_MARKER"',
      'while :; do sleep 0.05; done',
      '',
    ].join('\n'));
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const env = { ...process.env };
    delete env.CLAUDE_CODE_TOOL_MEMORY_LIMIT;
    Object.assign(env, {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_TOPOLOGY_MARKER: topologyMarker,
      HEAVY_SIGNAL_MARKER: signalMarker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    runner = spawn('/bin/bash', [RUNNER, process.execPath, HEADROOM, 'pnpm build'], {
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    runner.stderr.on('data', (chunk) => { stderr += chunk; });
    const closed = new Promise((resolve) => runner.once('close', (code, signal) => resolve({ code, signal })));

    await waitForFile(topologyMarker);
    const [supervisorPid, childPid, pgid] = fs.readFileSync(topologyMarker, 'utf8').trim().split(/\s+/).map(Number);
    workloadPgid = pgid;
    assert.strictEqual(childPid, pgid, 'setsid workload must lead its owned process group');
    assert.strictEqual(supervisorPid, runner.pid, 'runner must directly supervise the workload group');
    assert.notStrictEqual(supervisorPid, childPid, 'supervisor must remain outside the workload group');
    process.kill(supervisorPid, 'SIGTERM');

    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('runner did not finish after cancellation')), 2_000)),
    ]);
    assert.deepStrictEqual(result, { code: 42, signal: null }, stderr);
    assert.strictEqual(fs.readFileSync(signalMarker, 'utf8'), 'term');
  } finally {
    if (runner && runner.exitCode === null && runner.signalCode === null) {
      try { process.kill(-runner.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    if (Number.isSafeInteger(workloadPgid)) {
      try { process.kill(-workloadPgid, 'SIGKILL'); } catch { /* already drained */ }
    }
    rmTmp(tmp);
  }
});

test('cancellation at the post-fork identity boundary cannot strand the launched group', async () => {
  const tmp = mkTmp('heavy-fork-boundary-');
  let runner;
  let launchedPid;
  let workloadPgid;
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const bashEnv = path.join(tmp, 'fork-barrier.bash');
    const barrierMarker = path.join(tmp, 'fork-barrier');
    const topologyMarker = path.join(tmp, 'topology');
    const signalMarker = path.join(tmp, 'signal');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(bashEnv, [
      'if [ -n "${HEAVY_FORK_BARRIER_MARKER:-}" ]; then',
      '  trap \'if [ "$BASH_COMMAND" = "__claude_heavy_child=\\$!" ]; then trap - DEBUG; printf "%s %s\\n" "$BASHPID" "$!" >"$HEAVY_FORK_BARRIER_MARKER"; kill -STOP "$BASHPID"; fi\' DEBUG',
      'fi',
      '',
    ].join('\n'));
    fs.writeFileSync(path.join(bin, 'pnpm'), [
      '#!/bin/sh',
      'trap \'printf term >"$HEAVY_SIGNAL_MARKER"; exit 42\' TERM',
      'child=$$',
      'pgid=$(ps -o pgid= -p "$$")',
      'printf "%s %s\\n" "$child" "$pgid" >"$HEAVY_TOPOLOGY_MARKER"',
      'while :; do sleep 0.05; done',
      '',
    ].join('\n'));
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const env = { ...process.env };
    delete env.CLAUDE_CODE_TOOL_MEMORY_LIMIT;
    Object.assign(env, {
      BASH_ENV: bashEnv,
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_FORK_BARRIER_MARKER: barrierMarker,
      HEAVY_TOPOLOGY_MARKER: topologyMarker,
      HEAVY_SIGNAL_MARKER: signalMarker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    runner = spawn('/bin/bash', [RUNNER, process.execPath, HEADROOM, 'pnpm build'], {
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    runner.stderr.on('data', (chunk) => { stderr += chunk; });
    const closed = new Promise((resolve) => runner.once('close', (code, signal) => resolve({ code, signal })));

    await waitForFile(barrierMarker);
    const [supervisorPid, childPid] = fs.readFileSync(barrierMarker, 'utf8').trim().split(/\s+/).map(Number);
    const stat = fs.readFileSync(`/proc/${childPid}/stat`, 'utf8');
    const fieldsAfterComm = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
    const childParent = Number(fieldsAfterComm[1]);
    const preSetsidPgid = Number(fieldsAfterComm[2]);
    launchedPid = childPid;
    workloadPgid = childPid;
    assert.strictEqual(childParent, supervisorPid, 'barrier must capture the direct child before ownership validation');
    assert.ok(Number.isSafeInteger(preSetsidPgid) && preSetsidPgid > 0, 'child snapshot must expose a real PGID');
    assert.notStrictEqual(supervisorPid, childPid, 'barrier must stop the supervisor, not the workload');
    process.kill(supervisorPid, 'SIGTERM');
    process.kill(supervisorPid, 'SIGCONT');

    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('runner did not finish after fork-boundary cancellation')), 2_000)),
    ]);
    assert.deepStrictEqual(result, { code: 143, signal: null }, stderr);
    assert.strictEqual(fs.existsSync(topologyMarker), false, 'cancelled bootstrap executed the admitted command');
    assert.strictEqual(fs.existsSync(signalMarker), false, 'unstarted command handled a signal');
  } finally {
    if (runner && runner.exitCode === null && runner.signalCode === null) {
      try { process.kill(-runner.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    if (Number.isSafeInteger(workloadPgid)) {
      try { process.kill(-workloadPgid, 'SIGKILL'); } catch { /* already drained */ }
    }
    rmTmp(tmp);
  }
});

test('readiness waits for the post-setsid child to acknowledge its stop', async () => {
  const tmp = mkTmp('heavy-stop-handshake-');
  let runner;
  let workloadPgid;
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const bashEnv = path.join(tmp, 'delay-stop.bash');
    const beforeStop = path.join(tmp, 'before-stop');
    const observations = path.join(tmp, 'observations');
    const release = path.join(tmp, 'release');
    const started = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(bashEnv, [
      'if [ -n "${HEAVY_BEFORE_STOP_MARKER:-}" ]; then',
      '  __heavy_test_debug() {',
      '    case $BASH_COMMAND in',
      '      \'builtin kill -STOP "$BASHPID"\')',
      '        trap - DEBUG',
      '        printf "%s\\n" "$BASHPID" >"$HEAVY_BEFORE_STOP_MARKER"',
      '        while [ ! -e "$HEAVY_STOP_RELEASE" ]; do sleep 0.01; done',
      '        ;;',
      '      __claude_heavy_identity=*)',
      '        if [ -s "$HEAVY_BEFORE_STOP_MARKER" ]; then printf "observed\\n" >>"$HEAVY_OBSERVATIONS_MARKER"; fi',
      '        ;;',
      '    esac',
      '  }',
      '  trap __heavy_test_debug DEBUG',
      'fi',
      '',
    ].join('\n'));
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_START_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const env = { ...process.env };
    delete env.CLAUDE_CODE_TOOL_MEMORY_LIMIT;
    Object.assign(env, {
      BASH_ENV: bashEnv,
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_BEFORE_STOP_MARKER: beforeStop,
      HEAVY_OBSERVATIONS_MARKER: observations,
      HEAVY_STOP_RELEASE: release,
      HEAVY_START_MARKER: started,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    runner = spawn('/bin/bash', [RUNNER, process.execPath, HEADROOM, 'pnpm build'], {
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    runner.stderr.on('data', (chunk) => { stderr += chunk; });
    const closed = new Promise((resolve) => runner.once('close', (code, signal) => resolve({ code, signal })));

    await waitForFile(beforeStop);
    workloadPgid = Number(fs.readFileSync(beforeStop, 'utf8').trim());
    const stat = fs.readFileSync(`/proc/${workloadPgid}/stat`, 'utf8');
    const fields = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
    assert.strictEqual(Number(fields[2]), workloadPgid, 'delayed bootstrap must already lead its process group');
    assert.notStrictEqual(fields[0], 'T', 'test gate must hold the bootstrap before its SIGSTOP');

    const observationDeadline = Date.now() + 2_000;
    while (Date.now() < observationDeadline) {
      const count = fs.existsSync(observations)
        ? fs.readFileSync(observations, 'utf8').trim().split('\n').filter(Boolean).length
        : 0;
      if (count >= 2) break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const count = fs.existsSync(observations)
      ? fs.readFileSync(observations, 'utf8').trim().split('\n').filter(Boolean).length
      : 0;
    assert.ok(count >= 2, `supervisor accepted PGID before stopped-state acknowledgement; observations=${count}`);
    fs.writeFileSync(release, 'continue');

    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('runner did not finish after stop acknowledgement')), 2_000)),
    ]);
    assert.deepStrictEqual(result, { code: 0, signal: null }, stderr);
    assert.strictEqual(fs.readFileSync(started, 'utf8'), 'started');
  } finally {
    if (runner && runner.exitCode === null && runner.signalCode === null) {
      try { process.kill(-runner.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    if (Number.isSafeInteger(workloadPgid)) {
      try { process.kill(-workloadPgid, 'SIGKILL'); } catch { /* already drained */ }
    }
    rmTmp(tmp);
  }
});

test('scoped launch preserves stdio, environment, cwd, and command exit status', async () => {
  const tmp = mkTmp('heavy-memory-transport-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const cwd = path.join(tmp, 'working-directory');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    fs.mkdirSync(cwd);
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), [
      '#!/bin/sh',
      'IFS= read -r input',
      'printf "stdout:%s:%s:%s\\n" "$input" "$FOO" "$PWD"',
      'printf "stderr:%s\\n" "$FOO" >&2',
      'exit 7',
      '',
    ].join('\n'));
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);

    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const res = await runShell(command, {
      PATH: `${bin}:${process.env.PATH}`,
      FOO: 'a b',
      CLAUDE_CODE_TOOL_MEMORY_LIMIT: '4G',
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    }, { cwd, input: 'from-stdin\n' });
    assert.strictEqual(res.code, 7, res.stderr);
    assert.strictEqual(res.stdout, `stdout:from-stdin:a b:${cwd}\n`);
    assert.strictEqual(res.stderr, 'stderr:a b\n');
  } finally {
    rmTmp(tmp);
  }
});

test('invalid limit and scope setup errors prevent the original command', async () => {
  const tmp = mkTmp('heavy-memory-setup-error-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const marker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), '#!/bin/sh\nprintf started >"$HEAVY_MARKER"\n');
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const baseEnv = {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_MARKER: marker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    };

    let res = await runShell(command, { ...baseEnv, CLAUDE_CODE_TOOL_MEMORY_LIMIT: 'bogus' });
    assert.strictEqual(res.code, 75, res.stderr);
    assert.match(res.stderr, /CLAUDE_CODE_TOOL_MEMORY_LIMIT.*malformed/i);
    assert.strictEqual(fs.existsSync(marker), false);

    res = await runShell(command, {
      ...baseEnv,
      CLAUDE_CODE_TOOL_MEMORY_LIMIT: '4G',
      SYSTEMD_RUN_FAIL: '1',
    });
    assert.strictEqual(res.code, 69, res.stderr);
    assert.match(res.stderr, /systemd manager unavailable/i);
    assert.strictEqual(fs.existsSync(marker), false);

    const badPsBin = path.join(tmp, 'bad-ps-bin');
    fs.mkdirSync(badPsBin);
    for (const [name, target] of [
      ['bash', '/bin/bash'],
      ['flock', '/usr/bin/flock'],
      ['setsid', '/usr/bin/setsid'],
      ['sleep', '/usr/bin/sleep'],
      ['stat', '/usr/bin/stat'],
      ['id', '/usr/bin/id'],
    ]) fs.symlinkSync(target, path.join(badPsBin, name));
    fs.copyFileSync(path.join(bin, 'pnpm'), path.join(badPsBin, 'pnpm'));
    fs.chmodSync(path.join(badPsBin, 'pnpm'), 0o755);
    fs.writeFileSync(path.join(badPsBin, 'ps'), '#!/bin/sh\necho "fake ps identity failure" >&2\nexit 66\n');
    fs.chmodSync(path.join(badPsBin, 'ps'), 0o755);
    res = await runShell(command, { ...baseEnv, PATH: badPsBin });
    assert.strictEqual(res.code, 75, res.stderr);
    assert.match(res.stderr, /fake ps identity failure/i);
    assert.match(res.stderr, /cannot inspect workload process identity/i);
    assert.strictEqual(fs.existsSync(marker), false);

    const noSystemdBin = path.join(tmp, 'no-systemd-bin');
    fs.mkdirSync(noSystemdBin);
    for (const [name, target] of [
      ['bash', '/bin/bash'],
      ['flock', '/usr/bin/flock'],
      ['setsid', '/usr/bin/setsid'],
      ['sleep', '/usr/bin/sleep'],
      ['stat', '/usr/bin/stat'],
      ['id', '/usr/bin/id'],
      ['ps', '/usr/bin/ps'],
    ]) fs.symlinkSync(target, path.join(noSystemdBin, name));
    fs.copyFileSync(path.join(bin, 'pnpm'), path.join(noSystemdBin, 'pnpm'));
    fs.chmodSync(path.join(noSystemdBin, 'pnpm'), 0o755);
    res = await runShell(command, {
      ...baseEnv,
      PATH: noSystemdBin,
      CLAUDE_CODE_TOOL_MEMORY_LIMIT: '4G',
    });
    assert.strictEqual(res.code, 75, res.stderr);
    assert.match(res.stderr, /systemd-run is required/i);
    assert.strictEqual(fs.existsSync(marker), false);
  } finally {
    rmTmp(tmp);
  }
});

test('supervisor forwards termination to the scoped process group', async () => {
  const tmp = mkTmp('heavy-memory-signal-');
  let child;
  let scopedPid;
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const ready = path.join(tmp, 'ready');
    const signalMarker = path.join(tmp, 'signal');
    const pidMarker = path.join(tmp, 'scoped-pid');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), [
      '#!/bin/sh',
      'trap \'printf term >"$HEAVY_SIGNAL_MARKER"; exit 42\' TERM',
      'printf "%s" "$$" >"$HEAVY_PID_MARKER"',
      'printf ready >"$HEAVY_READY_MARKER"',
      'while :; do sleep 0.05; done',
      '',
    ].join('\n'));
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const command = updatedCommand(await runHook(HOOK, bash('pnpm build')));
    const env = { ...process.env };
    delete env.CLAUDE_CODE_TOOL_MEMORY_LIMIT;
    Object.assign(env, {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_READY_MARKER: ready,
      HEAVY_SIGNAL_MARKER: signalMarker,
      HEAVY_PID_MARKER: pidMarker,
      CLAUDE_CODE_TOOL_MEMORY_LIMIT: '4G',
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    child = spawn('/bin/bash', ['-c', command], { env, detached: true });
    const closed = new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
    child.stdin.end();
    await waitForFile(ready);
    await waitForFile(pidMarker);
    scopedPid = Number(fs.readFileSync(pidMarker, 'utf8'));
    process.kill(-child.pid, 'SIGTERM');
    await waitForFile(signalMarker);
    assert.strictEqual(fs.readFileSync(signalMarker, 'utf8'), 'term');
    const result = await closed;
    assert.deepStrictEqual(result, { code: 42, signal: null });
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    if (Number.isSafeInteger(scopedPid)) {
      try { process.kill(-scopedPid, 'SIGKILL'); } catch { /* already drained */ }
    }
    rmTmp(tmp);
  }
});

test('cancellation keeps the lock through descendant drain and forwards HUP as TERM', async () => {
  const tmp = mkTmp('heavy-cancel-drain-lock-');
  let runner;
  let workloadPgid;
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const marker = path.join(tmp, 'started');
    const ready = path.join(tmp, 'descendant-ready');
    const directExit = path.join(tmp, 'direct-exit');
    const termMarker = path.join(tmp, 'descendant-term');
    const doneMarker = path.join(tmp, 'descendant-done');
    const releaseMarker = path.join(tmp, 'descendant-release');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    fs.writeFileSync(path.join(bin, 'pnpm'), [
      '#!/bin/sh',
      'if [ "$2" = survivor ]; then',
      '  /bin/sh -c \'trap "printf term >\\"$HEAVY_TERM_MARKER\\"; while [ ! -e \\"$HEAVY_RELEASE_MARKER\\" ]; do sleep 0.01; done; printf done >\\"$HEAVY_DONE_MARKER\\"; exit 0" TERM; pgid=$(ps -o pgid= -p "$$"); printf "%s %s\\n" "$$" "$pgid" >"$HEAVY_READY_MARKER"; while :; do sleep 0.05; done\' &',
      '  printf exited >"$HEAVY_DIRECT_EXIT_MARKER"',
      '  exit 0',
      'fi',
      'printf "%s\\n" "$2" >>"$HEAVY_MARKER"',
      '',
    ].join('\n'));
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);
    const env = { ...process.env };
    delete env.CLAUDE_CODE_TOOL_MEMORY_LIMIT;
    Object.assign(env, {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_MARKER: marker,
      HEAVY_READY_MARKER: ready,
      HEAVY_DIRECT_EXIT_MARKER: directExit,
      HEAVY_TERM_MARKER: termMarker,
      HEAVY_DONE_MARKER: doneMarker,
      HEAVY_RELEASE_MARKER: releaseMarker,
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    });
    runner = spawn('/bin/bash', [RUNNER, process.execPath, HEADROOM, 'pnpm build survivor'], {
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    runner.stderr.on('data', (chunk) => { stderr += chunk; });
    const closed = new Promise((resolve) => runner.once('close', (code, signal) => resolve({ code, signal })));

    await waitForFile(ready);
    await waitForFile(directExit);
    const [descendantPid, pgid] = fs.readFileSync(ready, 'utf8').trim().split(/\s+/).map(Number);
    workloadPgid = pgid;
    assert.notStrictEqual(descendantPid, pgid, 'the direct group leader must have exited before descendant drain');

    const second = await runShell(updatedCommand(await runHook(HOOK, bash('pnpm build second'))), env);
    assert.strictEqual(second.code, 75, second.stderr);
    assert.strictEqual(fs.existsSync(marker), false, 'contending command started before cancellation');

    process.kill(runner.pid, 'SIGHUP');
    await waitForFile(termMarker);
    const third = await runShell(updatedCommand(await runHook(HOOK, bash('pnpm build third'))), env);
    assert.strictEqual(third.code, 75, third.stderr);
    assert.strictEqual(fs.existsSync(doneMarker), false, 'descendant drain barrier did not hold');
    assert.strictEqual(fs.existsSync(marker), false, 'lock released while cancelled descendant remained');

    fs.writeFileSync(releaseMarker, 'release');
    await waitForFile(doneMarker);
    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('runner did not finish after descendant drain')), 2_000)),
    ]);
    assert.deepStrictEqual(result, { code: 0, signal: null }, stderr);
    const fourth = await runShell(updatedCommand(await runHook(HOOK, bash('pnpm build fourth'))), env);
    assert.strictEqual(fourth.code, 0, fourth.stderr);
    assert.strictEqual(fs.readFileSync(marker, 'utf8'), 'fourth\n');
  } finally {
    if (runner && runner.exitCode === null && runner.signalCode === null) {
      try { process.kill(-runner.pid, 'SIGKILL'); } catch { /* already exited */ }
    }
    if (Number.isSafeInteger(workloadPgid)) {
      try { process.kill(-workloadPgid, 'SIGKILL'); } catch { /* already drained */ }
    }
    rmTmp(tmp);
  }
});

test('turbo-backed pnpm build is serialized globally with Turbo concurrency one inside a scope', async () => {
  const tmp = mkTmp('heavy-lock-');
  try {
    const proc = path.join(tmp, 'proc');
    const bin = path.join(tmp, 'bin');
    const runtime = path.join(tmp, 'runtime');
    const marker = path.join(tmp, 'started');
    fs.mkdirSync(bin);
    fs.mkdirSync(runtime, { mode: 0o700 });
    writeProc(proc);
    writeFakeSystemdRun(bin);
    fs.writeFileSync(path.join(bin, 'pnpm'), [
      '#!/bin/sh',
      'if [ "$2" = survivor ]; then',
      '  echo "survivor-start:$TURBO_CONCURRENCY" >> "$HEAVY_MARKER"',
      '  (sleep "${HEAVY_SLEEP:-0}"; echo "survivor-done:$TURBO_CONCURRENCY" >> "$HEAVY_MARKER") &',
      '  exit 0',
      'fi',
      'echo "$2:$TURBO_CONCURRENCY" >> "$HEAVY_MARKER"',
      '',
    ].join('\n'));
    fs.chmodSync(path.join(bin, 'pnpm'), 0o755);

    const firstCommand = updatedCommand(await runHook(HOOK, bash('exec 9>"$HEAVY_FD9_MARKER"; flock -u 9; exec 9>&-; exec 10>&-; exec 11>&-; pnpm build survivor')));
    const secondCommand = updatedCommand(await runHook(HOOK, bash('pnpm build second')));
    const env = {
      PATH: `${bin}:${process.env.PATH}`,
      HEAVY_MARKER: marker,
      HEAVY_FD9_MARKER: path.join(tmp, 'fd-9'),
      HEAVY_SLEEP: '0.5',
      CLAUDE_CODE_TOOL_MEMORY_LIMIT: '4G',
      CLAUDE_HEAVY_JOB_TEST_MODE: '1',
      CLAUDE_HEAVY_JOB_TEST_PROC_ROOT: proc,
      CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR: runtime,
    };

    const first = runShell(firstCommand, env);
    await waitForFile(marker);
    assert.ok(fs.existsSync(env.HEAVY_FD9_MARKER), 'original command did not exercise its own fd 9');
    const second = await runShell(secondCommand, env);
    assert.strictEqual(second.code, 75, second.stderr);
    assert.deepStrictEqual(fs.readFileSync(marker, 'utf8').trim().split('\n'), ['survivor-start:1']);
    assert.strictEqual((await first).code, 0);
    assert.deepStrictEqual(fs.readFileSync(marker, 'utf8').trim().split('\n'), ['survivor-start:1', 'survivor-done:1']);

    const third = await runShell(updatedCommand(await runHook(HOOK, bash('pnpm build third'))), { ...env, HEAVY_SLEEP: '0' });
    assert.strictEqual(third.code, 0, third.stderr);
    assert.deepStrictEqual(fs.readFileSync(marker, 'utf8').trim().split('\n'), ['survivor-start:1', 'survivor-done:1', 'third:1']);
  } finally {
    rmTmp(tmp);
  }
});
