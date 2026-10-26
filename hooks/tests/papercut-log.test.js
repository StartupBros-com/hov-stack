'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { runHook, assertQuietPassThrough, mkTmp, rmTmp, HOOKS_DIR } = require('./lib/harness');

const HOOK = 'PostToolUseFailure/papercut-log.js';
const { signature, projectSlug, redact, signalLine, readLimitHint } = require('../PostToolUseFailure/papercut-log.js');

// The hook writes under $HOME/.claude/papercuts, and os.homedir() honors $HOME on
// POSIX — so a temp HOME fully isolates each test from the real store.
function sandbox() {
  const home = mkTmp('papercut-home-');
  return { home, env: { HOME: home, USERPROFILE: home } };
}
const storeFor = (home, cwd) =>
  path.join(home, '.claude', 'papercuts', `${projectSlug(cwd)}.jsonl`);

function readRecords(home, cwd) {
  const f = storeFor(home, cwd);
  if (!fs.existsSync(f)) return [];
  return fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

const failure = (over = {}) => ({
  hook_event_name: 'PostToolUseFailure',
  session_id: 'abcdefgh12345678',
  cwd: '/home/user/SITES/demo',
  tool_name: 'Bash',
  tool_input: { command: 'pytest -q' },
  error: 'Exit code 127\n/bin/bash: line 1: pytest: command not found',
  duration_ms: 42,
  ...over,
});

// --- the load-bearing invariant: this is a logger, never a gate ---------------

test('store resolution matches the CLI: PAPERCUT_STORE, then CLAUDE_CONFIG_DIR, then home', async () => {
  const { home, env } = sandbox();
  const configDir = mkTmp('papercut-configdir-');
  const storeOverride = mkTmp('papercut-storedir-');
  try {
    // CLAUDE_CONFIG_DIR set -> records land under it, not under HOME.
    await runHook(HOOK, failure(), { env: { ...env, CLAUDE_CONFIG_DIR: configDir } });
    const underConfig = path.join(configDir, 'papercuts');
    assert.ok(fs.existsSync(underConfig), 'store must follow CLAUDE_CONFIG_DIR');
    assert.ok(!fs.existsSync(path.join(home, '.claude', 'papercuts')),
      'nothing may leak to the home store when the config dir is overridden');
    // PAPERCUT_STORE still wins over CLAUDE_CONFIG_DIR.
    await runHook(HOOK, failure(), { env: { ...env, CLAUDE_CONFIG_DIR: configDir, PAPERCUT_STORE: storeOverride } });
    assert.ok(fs.readdirSync(storeOverride).length > 0, 'PAPERCUT_STORE must take precedence');
  } finally {
    rmTmp(home); rmTmp(configDir); rmTmp(storeOverride);
  }
});

test('always passes stdin through unchanged (never blocks a session)', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure();
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
  } finally { rmTmp(home); }
});

test('malformed stdin passes through and writes nothing', async () => {
  const { home, env } = sandbox();
  try {
    const res = await runHook(HOOK, 'not json at all', { env });
    assertQuietPassThrough(res);
    assert.ok(!fs.existsSync(path.join(home, '.claude', 'papercuts')));
  } finally { rmTmp(home); }
});

test('an unwritable store cannot break the session', async () => {
  const { home, env } = sandbox();
  try {
    // A FILE where the papercuts DIRECTORY should be: every write path fails.
    fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(home, '.claude', 'papercuts'), 'not a dir');
    const p = failure();
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
  } finally { rmTmp(home); }
});

// --- capture ------------------------------------------------------------------

test('records a real tool failure with a parsed signature', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure();
    await runHook(HOOK, p, { env });
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs.length, 1);
    assert.strictEqual(recs[0].sig, 'command_not_found:pytest');
    assert.strictEqual(recs[0].source, 'auto');
    assert.strictEqual(recs[0].tool, 'Bash');
    assert.strictEqual(recs[0].session, '12345678', 'session is stored short (last 8)');
    assert.match(recs[0].ts, /^\d{4}-\d{2}-\d{2}T/);
  } finally { rmTmp(home); }
});

test('duplicates accumulate — repetition is the priority signal, not noise', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure();
    await runHook(HOOK, p, { env });
    await runHook(HOOK, p, { env });
    await runHook(HOOK, p, { env });
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs.length, 3, 'must NOT dedupe: the rollup ranks by frequency');
    assert.ok(recs.every((r) => r.sig === 'command_not_found:pytest'));
  } finally { rmTmp(home); }
});

test('separate projects write to separate stores', async () => {
  const { home, env } = sandbox();
  try {
    await runHook(HOOK, failure({ cwd: '/home/user/SITES/alpha' }), { env });
    await runHook(HOOK, failure({ cwd: '/home/user/SITES/beta' }), { env });
    assert.strictEqual(readRecords(home, '/home/user/SITES/alpha').length, 1);
    assert.strictEqual(readRecords(home, '/home/user/SITES/beta').length, 1);
  } finally { rmTmp(home); }
});

test('reads the error out of tool_response when there is no top-level error field', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({ error: undefined, tool_response: { stderr: 'fatal: not a git repository' } });
    delete p.error;
    await runHook(HOOK, p, { env });
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs.length, 1, 'field-name drift must not silently drop capture');
    assert.match(recs[0].sig, /^git_fatal:/);
  } finally { rmTmp(home); }
});

// --- filtering: the flood guard -----------------------------------------------

test('a user interrupt is not friction', async () => {
  const { home, env } = sandbox();
  try {
    await runHook(HOOK, failure({ is_interrupt: true }), { env });
    assert.strictEqual(readRecords(home, '/home/user/SITES/demo').length, 0);
  } finally { rmTmp(home); }
});

test('grep/test exiting nonzero is control flow, not friction', async () => {
  const { home, env } = sandbox();
  try {
    await runHook(HOOK, failure({ tool_input: { command: 'grep -q needle haystack.txt' }, error: 'Exit code 1' }), { env });
    await runHook(HOOK, failure({ tool_input: { command: 'test -f /nope' }, error: 'Exit code 1' }), { env });
    await runHook(HOOK, failure({ tool_input: { command: 'git diff --quiet' }, error: 'Exit code 1' }), { env });
    assert.strictEqual(readRecords(home, '/home/user/SITES/demo').length, 0,
      'normal negative answers must not drown the real signal');
  } finally { rmTmp(home); }
});

test('an empty error is not recorded', async () => {
  const { home, env } = sandbox();
  try {
    await runHook(HOOK, failure({ error: '   ' }), { env });
    assert.strictEqual(readRecords(home, '/home/user/SITES/demo').length, 0);
  } finally { rmTmp(home); }
});

test('a giant error is truncated so the append stays atomic', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({ error: 'boom ' + 'x'.repeat(500000) });
    await runHook(HOOK, p, { env });
    const raw = fs.readFileSync(storeFor(home, p.cwd), 'utf8');
    assert.ok(Buffer.byteLength(raw) < 4096,
      'a record must stay under PIPE_BUF or concurrent appends can interleave');
  } finally { rmTmp(home); }
});

// --- signature normalization (pure) -------------------------------------------

test('redacting a long word-character body stays linear (dotfiles#1069)', () => {
  // The patterns used to carry unbounded greedy prefixes, which are retried at
  // every start position. Truncation to MAX_INPUT_CHARS hid it here, but the
  // python copy of this table has no truncation and spent 142s on one 40,000
  // character dossier. Both tables are bounded now; this fails if either the
  // bound or the truncation is removed without the other being sound.
  const body = 'x'.repeat(40_000);
  const start = process.hrtime.bigint();
  const out = redact(body);
  const seconds = Number(process.hrtime.bigint() - start) / 1e9;
  assert.equal(out, body, 'a body with no credential must come back unchanged');
  assert.ok(seconds < 5, `redact() on 40,000 word characters took ${seconds.toFixed(1)}s`);
});

test('a credential name longer than the bound is still redacted', () => {
  // Planted negative for the {0,64} bound: it may shorten the capture, never
  // anchor the match away.
  const name = 'a_very_long_prefix_that_exceeds_sixty_four_characters_in_total_length_password';
  assert.ok(name.length > 64);
  const out = redact(`${name}=hunter2hunter2`);
  assert.ok(!out.includes('hunter2hunter2'), `secret survived: ${out}`);
  assert.ok(out.includes('<redacted>'));
});

test('signature folds out paths, digits and hashes so occurrences collapse', () => {
  const a = signature('fatal: pathspec /home/user/SITES/a/x.ts at 3f2a1b9 did not match', 'Bash');
  const b = signature('fatal: pathspec /home/user/SITES/b/y.ts at 9c4d2e1 did not match', 'Bash');
  assert.strictEqual(a, b, 'same friction from different repos must share one signature');
});

test('signature classifies the measured friction families', () => {
  assert.strictEqual(signature('bash: line 2: gh: command not found'), 'command_not_found:gh');
  assert.strictEqual(signature("ModuleNotFoundError: No module named 'pytest'"), 'module_not_found:pytest');
  assert.strictEqual(signature('Command timed out after 2m'), 'timed_out');
  assert.strictEqual(signature('BLOCKED by dcg\nReason: destructive'), 'guard_blocked:dcg');
  assert.strictEqual(signature('Permission denied'), 'permission_denied');
  assert.match(signature('MCP error -32000: not connected'), /^mcp_error:-32000$/);
});

test('guard blocks are attributed to the guard that fired', () => {
  assert.strictEqual(
    signature('Blocked: commit on main. Escape with ALLOW_MAIN_COMMIT=1'),
    'guard_blocked:git-guard',
    'a rule rediscovered N times is either under-documented or an allowlist candidate',
  );
  assert.strictEqual(
    signature('Codex quota is explicitly unavailable for the active direct ChatGPT account.'),
    'guard_blocked:codex-quota-guard',
  );
  assert.strictEqual(
    signature('Codex circuit breaker TRIPPED — doghouse active'),
    'guard_blocked:codex-doghouse',
    'historical records keep their old aggregation key',
  );
});

// --- shape-rewrite refused (AE5, KTD7): the verifier still refuses a rewrite -

// The doc's verbatim too-complex refusal (harness/worktree-command-shapes.md).
const VERIFIER_REFUSAL =
  'This session is isolated in the worktree `/home/user/dotfiles/.claude/worktrees/x`, '
  + 'but this command is too complex to verify that it stays inside the worktree. '
  + "Refusing to run it — a worktree-isolated session's git operations must target "
  + 'its own worktree. Split it into plain, separate commands and run them from '
  + '`/home/user/dotfiles/.claude/worktrees/x`.';
const rewriteScript = (shapes, id = 'toolu_01A2B3C4D5E6F7G8H9J0K1L2') =>
  `bash /home/user/.claude/jobs/job123/tmp/shape-rewrite-${shapes}-${id}.sh`;

test('AE5: a refused rewrite script is keyed under its own signature, shapes preserved', () => {
  assert.strictEqual(
    signature(VERIFIER_REFUSAL, 'Bash', '', rewriteScript('cmdsub')),
    'guard_blocked:shape-rewrite-refused:cmdsub',
  );
  // A compound shape name (KTD4's sorted `cmdsub+loopvar`) survives intact.
  assert.strictEqual(
    signature(VERIFIER_REFUSAL, 'Bash', '', rewriteScript('cmdsub+loopvar')),
    'guard_blocked:shape-rewrite-refused:cmdsub+loopvar',
  );
});

test('AE5: through the real hook — a refused rewrite is captured with the refused signature', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({
      tool_input: { command: rewriteScript('cmdsub') },
      error: VERIFIER_REFUSAL,
    });
    await runHook(HOOK, p, { env });
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs.length, 1);
    assert.strictEqual(recs[0].sig, 'guard_blocked:shape-rewrite-refused:cmdsub');
  } finally { rmTmp(home); }
});

test('a rewrite script that fails on its own (no verifier message) stays on the ordinary failure path', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({
      tool_input: { command: rewriteScript('cmdsub') },
      error: 'Exit code 1\nsome_command: syntax error near unexpected token',
    });
    await runHook(HOOK, p, { env });
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs.length, 1);
    assert.ok(!recs[0].sig.startsWith('guard_blocked:shape-rewrite-refused'),
      `a plain non-zero exit must not be classified as a refused rewrite, got ${recs[0].sig}`);
  } finally { rmTmp(home); }
});

test('a verifier refusal of a non-rewrite command is unchanged', () => {
  // Same error text, but the command never carries the shape-rewrite script
  // marker: this must classify exactly as it did before the new branch existed.
  const before = signature(VERIFIER_REFUSAL, 'Bash', '');
  const withUnrelatedCmd = signature(VERIFIER_REFUSAL, 'Bash', '', 'git -C /home/user/dotfiles status');
  assert.strictEqual(withUnrelatedCmd, before);
  assert.ok(!withUnrelatedCmd.startsWith('guard_blocked:shape-rewrite-refused'));
});

test('every existing guard_blocked:* fixture keeps its pre-change signature (regression)', () => {
  // Pins the placement requirement: the new branch sits after every hard-coded
  // guard_blocked:* branch, so it must never be able to steal one of these,
  // whether or not a cmd argument is supplied at all.
  const fixtures = [
    ['BLOCKED by dcg\nReason: destructive', 'guard_blocked:dcg'],
    ['Blocked: commit on main. Escape with ALLOW_MAIN_COMMIT=1', 'guard_blocked:git-guard'],
    ['Codex quota is explicitly unavailable for the active direct ChatGPT account.', 'guard_blocked:codex-quota-guard'],
    ['Codex circuit breaker TRIPPED — doghouse active', 'guard_blocked:codex-doghouse'],
  ];
  for (const [err, expected] of fixtures) {
    assert.strictEqual(signature(err, 'Bash'), expected, `regressed with no cmd arg: ${err}`);
    assert.strictEqual(signature(err, 'Bash', '', 'pytest -q'), expected,
      `regressed with an unrelated cmd arg: ${err}`);
  }
});

// --- guard denials: the class no post-hook can ever see ----------------------

test('a git-guard denial is logged as a papercut, and still denies', async () => {
  const { home, env } = sandbox();
  try {
    const p = {
      tool_name: 'Bash',
      cwd: '/home/user/SITES/demo',
      session_id: 'aaaabbbbccccdddd',
      tool_input: { command: 'git reset --hard HEAD' },
    };
    const res = await runHook('PreToolUse/git-guard.js', p, { env });
    // Enforcement is the contract; logging is a passenger.
    assert.strictEqual(JSON.parse(res.stdout).hookSpecificOutput.permissionDecision, 'deny');
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs.length, 1, 'a PreToolUse denial reaches no post-hook — the guard must log itself');
    assert.strictEqual(recs[0].sig, 'guard_blocked:git-guard');
    assert.strictEqual(recs[0].source, 'guard');
    assert.strictEqual(recs[0].cmd, 'git reset --hard HEAD');
  } finally { rmTmp(home); }
});

test('every guard that can deny also sets its attribution context', () => {
  // The regression guard for the real defect: logDeny() silently no-ops without
  // setDenyContext, so a guard that forgets it is invisible with no error. Three
  // of four guards were in exactly that state. Enumerate rather than hard-code,
  // so a NEW guard fails this test instead of quietly going uncaptured.
  const dir = path.join(HOOKS_DIR, 'PreToolUse');
  const guards = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  const missing = [];
  const noAgent = [];
  for (const g of guards) {
    const src = fs.readFileSync(path.join(dir, g), 'utf8');
    if (!/require\(['"]\.\.\/lib\/pretooluse-decision['"]\)/.test(src)) continue;
    if (!/\b(deny|hardStop)\s*\(/.test(src)) continue;
    if (!/setDenyContext\s*\(/.test(src)) { missing.push(g); continue; }
    // A context without the agent attributes every denial to the main
    // conversation: a per-agent read cannot see who was denied.
    if (!/agentId:\s*\w+\.agent_id/.test(src)) noAgent.push(g);
  }
  assert.deepStrictEqual(missing, [],
    `these guards can deny but never call setDenyContext, so their denials are not captured: ${missing.join(', ')}`);
  assert.deepStrictEqual(noAgent, [],
    `these guards set a deny context without agentId, so their denials attribute to the main conversation: ${noAgent.join(', ')}`);
});

test('a banner-first output keys on its trailing summary, ANSI stripped', () => {
  const err = 'Exit code 1\nChecking formatting...\n[\u001b[33mwarn\u001b[39m] tooling/a.test.mjs\n[\u001b[33mwarn\u001b[39m] Code style issues found in 2 files. Run Prettier with --write to fix.';
  assert.strictEqual(
    signature(err, 'Bash'),
    'bash:[warn] code style issues found in <n> files. run prettier with --write to fix.',
  );
});

test('a lone progress banner still keys on itself', () => {
  assert.strictEqual(signature('Exit code 1\nChecking formatting...', 'Bash'),
    'bash:checking formatting...');
});

test('an errorish first line ending in an ellipsis keeps its key (no drift)', () => {
  assert.strictEqual(
    signature('Exit code 1\nerror: connection failed...\nstack detail', 'Bash'),
    'bash:error: connection failed...');
});

test('ansi styling never reaches a signature key', () => {
  const key = signature('Exit code 1\n\u001b[31mBuild failed\u001b[0m with 3 problems', 'Bash');
  assert.strictEqual(key, 'bash:build failed with <n> problems');
  assert.ok(!key.includes('\u001b'));
});

test('a tool ENOENT with no path in the message keys on the captured target', () => {
  assert.strictEqual(
    signature('File does not exist.', 'Read', '/home/u/SITES/x/.compound-engineering/config.yaml'),
    'no_such_file:config.yaml');
  // Without a target the generic bucket remains — never an empty subject.
  assert.strictEqual(signature('File does not exist.', 'Read', ''), 'no_such_file');
  // A subject recovered from the message still wins over the target.
  assert.strictEqual(
    signature("ugrep: sync.sh: No such file or directory", 'Bash', '/some/target'),
    'no_such_file:sync.sh');
});

test('the hook emits additionalContext JSON for an oversized jsonl read', async () => {
  const { home, env } = sandbox();
  try {
    const out = await runHook(HOOK, {
      hook_event_name: 'PostToolUseFailure',
      session_id: 'abcdefgh12345678',
      cwd: '/home/user/SITES/demo',
      tool_name: 'Read',
      tool_input: { file_path: '/home/u/.claude/projects/-home-u-x/abc.jsonl' },
      error: 'File content (85675 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters.',
    }, { env });
    const parsed = JSON.parse(out.stdout);
    assert.strictEqual(parsed.hookSpecificOutput.hookEventName, 'PostToolUseFailure');
    assert.match(parsed.hookSpecificOutput.additionalContext, /cass/);
    // The failure is still captured — the hint never replaces the record.
    const recs = readRecords(home, '/home/user/SITES/demo');
    assert.strictEqual(recs.length, 1);
    assert.match(recs[0].sig, /^read:file content/);
  } finally {
    rmTmp(home);
  }
});

test('read-limit hint fires on oversized jsonl, names the right tool per shape', () => {
  const base = {
    tool_name: 'Read',
    error: 'File content (85675 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters.',
  };
  const transcript = readLimitHint({ ...base,
    tool_input: { file_path: '/home/u/.claude/projects/-home-u-x/abc.jsonl' } });
  assert.match(transcript, /cass/);
  const store = readLimitHint({ ...base,
    tool_input: { file_path: '/home/u/.claude/papercuts/-x.jsonl' } });
  assert.match(store, /jq/);
  assert.ok(!/cass/.test(store), 'store hint does not claim transcript search');
});

test('transcript detection honors CLAUDE_CONFIG_DIR (refute-vet finding)', () => {
  const saved = process.env.CLAUDE_CONFIG_DIR;
  process.env.CLAUDE_CONFIG_DIR = '/srv/claude-state';
  try {
    const hint = readLimitHint({
      tool_name: 'Read',
      error: 'File content (85675 tokens) exceeds maximum allowed tokens (25000).',
      tool_input: { file_path: '/srv/claude-state/projects/-x/abc.jsonl' },
    });
    assert.match(hint, /cass/, 'overridden config dir still routes to the transcript hint');
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = saved;
  }
});

test('read-limit hint stays silent off its narrow trigger (planted negatives)', () => {
  const err = 'File content (85675 tokens) exceeds maximum allowed tokens (25000).';
  // not a jsonl target: offset/limit is the right answer, no hint
  assert.strictEqual(readLimitHint({ tool_name: 'Read', error: err,
    tool_input: { file_path: '/home/u/big-source.py' } }), null);
  // not a read-limit error
  assert.strictEqual(readLimitHint({ tool_name: 'Read', error: 'File does not exist.',
    tool_input: { file_path: '/home/u/x.jsonl' } }), null);
  // not the Read tool
  assert.strictEqual(readLimitHint({ tool_name: 'Bash', error: err,
    tool_input: { file_path: '/home/u/x.jsonl' } }), null);
});

test('the third identical read-limit failure escalates, type-agnostic', async () => {
  const { home, env } = sandbox();
  const payload = {
    hook_event_name: 'PostToolUseFailure',
    session_id: 'abcdefgh12345678',
    cwd: '/home/user/SITES/demo',
    tool_name: 'Read',
    tool_input: { file_path: '/repo/full.diff' },
    error: 'File content (85675 tokens) exceeds maximum allowed tokens (25000).',
  };
  try {
    const first = await runHook(HOOK, payload, { env });
    assertQuietPassThrough(first);
    const second = await runHook(HOOK, payload, { env });
    assertQuietPassThrough(second);
    const third = await runHook(HOOK, payload, { env });
    const parsed = JSON.parse(third.stdout);
    assert.match(parsed.hookSpecificOutput.additionalContext, /Attempt 3/);
    assert.match(parsed.hookSpecificOutput.additionalContext, /offset and limit/);
    // A different target in the same session does not inherit the count.
    const other = { ...payload, tool_input: { file_path: '/repo/other.diff' } };
    assertQuietPassThrough(await runHook(HOOK, other, { env }));
    // All four failures are captured regardless of hint path.
    const recs = readRecords(home, '/home/user/SITES/demo');
    assert.strictEqual(recs.length, 4);
  } finally {
    rmTmp(home);
  }
});

test('a node internal-frame dump keys on its Error line, not the frame', () => {
  const dump = "Exit code 1\nnode:internal/modules/run_main:107\n    triggerUncaughtException(\n    ^\n\nError: Transform failed with 1 error:\n/tmp/x.ts:5:15: ERROR: Top-level await is not supported\n    at failureErrorWithLog";
  assert.strictEqual(
    signature(dump, 'Bash'),
    'bash:error: transform failed with <n> error:');
  const coded = "Exit code 1\nnode:internal/modules/esm/resolve:274\n    throw new ERR_MODULE_NOT_FOUND(\n          ^\n\nError [ERR_MODULE_NOT_FOUND]: Cannot find module '/repo/bin/x.ts' imported from /repo/";
  assert.match(signature(coded, 'Bash'), /^bash:error \[err_module_not_found\]: cannot find module/);
  // A dump with no Error line keeps the frame key (no silent regression).
  assert.strictEqual(
    signature('Exit code 1\nnode:internal/process/promises:394\n    triggerUncaughtException(', 'Bash'),
    'bash:node:internal/process/promises:<n>');
});

test('an injected claude-code-hint line never becomes the key', () => {
  // Live shape 2026-09-01: 68 records keyed on the vercel plugin hint while
  // the real causes sat one line below it.
  const masked = 'Exit code 1\n<claude-code-hint v="1" type="plugin" value="vercel@claude-plugins-official" />\nError: unknown or unexpected option: --format';
  assert.strictEqual(
    signature(masked, 'Bash'),
    'bash:error: unknown or unexpected option: --format');
  // Future hint kinds must not mask either.
  const other = 'Exit code 1\n<claude-code-hint v="2" type="mcp" value="something@else" />\nError: real cause';
  assert.strictEqual(signature(other, 'Bash'), 'bash:error: real cause');
});

test('a hint-only failure is as content-free as a bare exit code', async () => {
  const { home, env } = sandbox();
  try {
    await runHook(HOOK, failure({
      tool_input: { command: 'vercel deploy' },
      error: 'Exit code 1\n<claude-code-hint v="1" type="plugin" value="vercel@claude-plugins-official" />',
    }), { env });
    assert.strictEqual(readRecords(home, '/home/user/SITES/demo').length, 0,
      'harness metadata alone carries no signal to record');
  } finally { rmTmp(home); }
});

// shape-rewrite.js echoes this receipt as the first line of every rewritten
// call, so a rewritten command that fails used to be keyed on the receipt
// (566 records in the 30 days to 2026-10-17, dotfiles#1840 decision 6).
const { rewriteReceipt } = require('../PreToolUse/shape-rewrite.js');
const receipt = (shapes) => rewriteReceipt(shapes,
  `/home/user/.claude/jobs/job123/tmp/shape-rewrite-${shapes}-toolu_01.sh`);

test('a shape-rewrite receipt line never becomes the key', () => {
  const cause = 'ERR_PNPM_NO_SCRIPT  Missing script: typecheck';
  const bare = signature(`Exit code 1\n${cause}`, 'Bash');
  assert.ok(!bare.includes('shape-rewrite'), `control key is the cause: ${bare}`);
  assert.strictEqual(signature(`Exit code 1\n${receipt('pkgmgr')}\n${cause}`, 'Bash'), bare);
  assert.strictEqual(signature(`Exit code 1\n${receipt('cmdsub+loopvar')}\n${cause}`, 'Bash'), bare);
  // Planted negative: a line that only starts like the receipt is output, not
  // the hook's own echo, and keeps its key.
  assert.match(signature('Exit code 1\n[shape-rewrite] rewritten: by hand\nlater', 'Bash'),
    /^bash:\[shape-rewrite\] rewritten: by hand/);
});

test('a receipt-only failure is as content-free as a bare exit code', async () => {
  const { home, env } = sandbox();
  try {
    await runHook(HOOK, failure({
      tool_input: { command: 'bash /home/user/.claude/jobs/job123/tmp/shape-rewrite-pkgmgr-toolu_01.sh' },
      error: `Exit code 1\n${receipt('pkgmgr')}`,
    }), { env });
    assert.strictEqual(readRecords(home, '/home/user/SITES/demo').length, 0,
      'the receipt alone carries no signal to record');
  } finally { rmTmp(home); }
});

test('a StructuredOutput failure records the sent key-shape as its target, never values', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({
      tool_name: 'StructuredOutput',
      tool_input: { input: { refuted: false, reasoning: 'secret-ish text' } },
      error: "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'",
    });
    await runHook(HOOK, p, { env });
    const [rec] = readRecords(home, p.cwd);
    assert.strictEqual(rec.sig, 'structuredoutput_schema_mismatch');
    assert.strictEqual(rec.target, 'keys:input=object');
    assert.ok(!JSON.stringify(rec).includes('secret-ish'), 'values must never reach the store');
  } finally { rmTmp(home); }
});

test('a failure inside a subagent records the agent id; the main conversation records none', async () => {
  const { home, env } = sandbox();
  try {
    const inAgent = failure({ tool_input: { command: 'tsc' }, error: 'Exit code 1\nsrc/a.ts(1,1): error TS1005', agent_id: 'a3eff2814d8720436' });
    await runHook(HOOK, inAgent, { env });
    const main = failure({ tool_input: { command: 'tsc' }, error: 'Exit code 1\nsrc/b.ts(1,1): error TS1005' });
    await runHook(HOOK, main, { env });
    const recs = readRecords(home, inAgent.cwd);
    assert.strictEqual(recs.length, 2);
    assert.strictEqual(recs[0].agent, 'd8720436', 'last 8 chars, same convention as session');
    assert.strictEqual(recs[1].agent, '', 'main conversation has no agent');
  } finally { rmTmp(home); }
});

test('a Read failure records the window it asked for as page; other tools and absent windows record none', async () => {
  const { home, env } = sandbox();
  try {
    const ceiling = 'File content (60000 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters to read specific portions of the file.';
    const paged = failure({ tool_name: 'Read', tool_input: { file_path: '/srv/app/big.diff', offset: 6600, limit: 6000 }, error: ceiling });
    await runHook(HOOK, paged, { env });
    const whole = failure({ tool_name: 'Read', tool_input: { file_path: '/srv/app/big.diff' }, error: ceiling });
    await runHook(HOOK, whole, { env });
    const junk = failure({ tool_name: 'Read', tool_input: { file_path: '/srv/app/big.diff', limit: 'all', offset: -3 }, error: ceiling });
    await runHook(HOOK, junk, { env });
    const bash = failure({ tool_input: { command: 'tsc', limit: 5 }, error: 'Exit code 1\nsrc/a.ts(1,1): error TS1005' });
    await runHook(HOOK, bash, { env });
    const recs = readRecords(home, paged.cwd);
    assert.strictEqual(recs.length, 4);
    assert.deepStrictEqual(recs[0].page, { offset: 6600, limit: 6000 }, 'numbers only, both keys');
    assert.strictEqual('page' in recs[1], false, 'a whole-file Read carried no window');
    assert.strictEqual('page' in recs[2], false, 'non-numeric or negative values are not a window');
    assert.strictEqual('page' in recs[3], false, 'only Read records a page');
  } finally { rmTmp(home); }
});

test('a missing workspace binary gets the pnpm --filter hint through the real hook; other ENOENTs do not', async () => {
  const { workspaceBinHint } = require('../PostToolUseFailure/papercut-log.js');
  const { home, env } = sandbox();
  // A working directory that has a node_modules (this repo has none).
  const installedCwd = path.join(home, 'proj');
  fs.mkdirSync(path.join(installedCwd, 'node_modules'), { recursive: true });
  try {
    // Through run(): a wiring mistake in the hint chain fails here, not only
    // in the helper (a mutant with the chain entry removed passed the
    // helper-only test — refute-vet finding).
    const probe = failure({ cwd: installedCwd, tool_input: { command: 'ls /srv/app/node_modules/.bin/tsx' },
      error: "Exit code 2\nls: cannot access '/srv/app/node_modules/.bin/tsx': No such file or directory" });
    const out = await runHook(HOOK, probe, { env });
    const parsed = JSON.parse(out.stdout);
    assert.strictEqual(parsed.hookSpecificOutput.hookEventName, 'PostToolUseFailure');
    assert.match(parsed.hookSpecificOutput.additionalContext, /No `tsx` binary under that node_modules/);
    assert.match(parsed.hookSpecificOutput.additionalContext, /pnpm --filter <package> exec tsx/);
    assert.strictEqual(readRecords(home, probe.cwd).length, 1, 'the failure is still captured');
    // The helper's edges.
    const script = failure({ tool_input: { command: 'bash run.sh' },
      error: 'Exit code 127\nrun.sh: line 5: /srv/app/.claude/worktrees/x/node_modules/.bin/tsx: No such file or directory' });
    assert.match(workspaceBinHint(script), /`tsx` binary/);
    // Paths under the installed checkout: the per-package answer.
    const pkgDir = failure({ cwd: installedCwd, tool_input: { command: 'ls -d ' + installedCwd + '/node_modules/tsx' },
      error: "Exit code 2\nls: cannot access '" + installedCwd + "/node_modules/tsx': No such file or directory" });
    assert.match(workspaceBinHint(pkgDir), /`tsx` package under that node_modules.*pnpm why tsx/);
    const scoped = failure({ cwd: installedCwd, tool_input: { command: 'ls ' + installedCwd + '/node_modules/@types/node' },
      error: "Exit code 2\nls: cannot access '" + installedCwd + "/node_modules/@types/node': No such file or directory" });
    assert.match(workspaceBinHint(scoped), /`@types\/node` package/);
    // A bare scope directory, a deeper path, and an unrelated ENOENT get nothing.
    const bareScope = failure({ tool_input: { command: 'ls /srv/app/node_modules/@types' },
      error: "Exit code 2\nls: cannot access '/srv/app/node_modules/@types': No such file or directory" });
    assert.strictEqual(workspaceBinHint(bareScope), null);
    const deep = failure({ tool_input: { command: 'cat /srv/app/node_modules/foo/dist/index.js' },
      error: "cat: /srv/app/node_modules/foo/dist/index.js: No such file or directory" });
    assert.strictEqual(workspaceBinHint(deep), null);
    // Node's loader shape when a package script path is run directly.
    const withInstall = { cwd: installedCwd };
    const loader = failure({ ...withInstall, tool_input: { command: 'node ' + installedCwd + '/node_modules/tsx/dist/cli.mjs run.ts' },
      error: "Exit code 1\nnode:internal/modules/cjs/loader:1424\n  throw err;\n  ^\n\nError: Cannot find module '" + installedCwd + "/node_modules/tsx/dist/cli.mjs'" });
    assert.match(workspaceBinHint(loader), /`tsx` package under that node_modules.*pnpm why tsx/);
    const scopedLoader = failure({ ...withInstall, tool_input: { command: 'node x.js' },
      error: "Error: Cannot find module '" + installedCwd + "/node_modules/@scope/pkg/lib/index.js'" });
    assert.match(workspaceBinHint(scopedLoader), /`@scope\/pkg` package/);
    // A working directory with no node_modules at all gets the install
    // answer instead of the per-package one (the fixture cwd does not exist).
    const fresh = failure({ tool_input: { command: 'node /srv/app/node_modules/tsx/dist/cli.mjs' },
      cwd: '/srv/app/.claude/worktrees/fresh',
      error: "Error: Cannot find module '/srv/app/.claude/worktrees/fresh/node_modules/tsx/dist/cli.mjs'" });
    assert.match(workspaceBinHint(fresh), /no node_modules at all in \/srv\/app\/\.claude\/worktrees\/fresh.*pnpm install/);
    // The checkout comes from the matched path, not the session cwd: a
    // session in an installed worktree probing a fresh one gets the install
    // answer about the fresh one, and the converse gets the per-package one.
    const freshRoot = path.join(home, 'fresh-wt');
    fs.mkdirSync(freshRoot, { recursive: true });
    const crossA = failure({ cwd: installedCwd, tool_input: { command: 'node x' },
      error: "Error: Cannot find module '" + freshRoot + "/node_modules/tsx/dist/cli.mjs'" });
    assert.match(workspaceBinHint(crossA), new RegExp('no node_modules at all in ' + freshRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    const crossB = failure({ cwd: freshRoot, tool_input: { command: 'node x' },
      error: "Error: Cannot find module '" + installedCwd + "/node_modules/tsx/dist/cli.mjs'" });
    assert.match(workspaceBinHint(crossB), /`tsx` package under that node_modules/);
    // A dot-directory in the virtual store is not a package: silence.
    const pnpmStore = failure({ cwd: installedCwd, tool_input: { command: 'node x' },
      error: "Error: Cannot find module '/srv/app/node_modules/.pnpm/missing@1.0.0/package.json'" });
    assert.strictEqual(workspaceBinHint(pnpmStore), null);
    // ESLint 9 with no config from the working directory upward.
    const eslint = failure({ cwd: installedCwd, tool_input: { command: 'node ' + installedCwd + '/node_modules/eslint/bin/eslint.js .' },
      error: "Exit code 2\n\nOops! Something went wrong! :(\n\nESLint: 9.39.1\n\nESLint couldn't find an eslint.config.(js|mjs|cjs) file.\n\nFrom ESLint v9.0.0, the default configuration file is now eslint.config.js." });
    assert.match(workspaceBinHint(eslint), /pnpm --filter <package> lint/);
    // A module that is not under node_modules is the caller's own file.
    const ownFile = failure({ tool_input: { command: 'node lib/missing.js' },
      error: "Error: Cannot find module '/srv/app/lib/missing.js'" });
    assert.strictEqual(workspaceBinHint(ownFile), null);
    const unrelated = failure({ tool_input: { command: 'cat config.yaml' },
      error: 'Exit code 1\ncat: config.yaml: No such file or directory' });
    assert.strictEqual(workspaceBinHint(unrelated), null);
    const unrelatedOut = await runHook(HOOK, unrelated, { env });
    assertQuietPassThrough(unrelatedOut);
  } finally { rmTmp(home); }
});

test('a self-logged denial records the subagent when the guard passes one', () => {
  const { logDenial } = require('../PostToolUseFailure/papercut-log.js');
  const { home, env } = sandbox();
  const saved = process.env.PAPERCUT_STORE;
  try {
    // In-process call: point the store at the sandbox so nothing reaches the live store.
    process.env.PAPERCUT_STORE = path.join(home, '.claude', 'papercuts');
    assert.strictEqual(logDenial({ guard: 'read-ceiling-chunk', tool: 'Read', command: '/srv/app/big.diff', reason: 'stopped',
      sessionId: 'abcdefgh12345678', agentId: 'agent-a3eff2814d8720436', cwd: '/home/user/SITES/demo' }), true);
    assert.strictEqual(logDenial({ guard: 'git-guard', tool: 'Bash', command: 'git push --force', reason: 'no',
      sessionId: 'abcdefgh12345678', cwd: '/home/user/SITES/demo' }), true);
    const recs = readRecords(home, '/home/user/SITES/demo');
    assert.strictEqual(recs.length, 2);
    assert.strictEqual(recs[0].agent, 'd8720436');
    assert.strictEqual(recs[1].agent, '', 'a guard that passes no agent records none');
  } finally {
    if (saved === undefined) delete process.env.PAPERCUT_STORE; else process.env.PAPERCUT_STORE = saved;
    rmTmp(home);
  }
});

test('ESM loader misses from a direct test run get the matching hint; a real missing file does not', async () => {
  const { esmTestHint } = require('../PostToolUseFailure/papercut-log.js');
  const { home, env } = sandbox();
  try {
    // The dominant live shape: the `~` alias from a test run at the checkout root.
    const alias = failure({ tool_input: { command: 'node apps/acme-help/node_modules/tsx/dist/cli.mjs --test apps/acme-help/lib/x.test.ts' },
      error: "Exit code 1\nnode:internal/modules/run_main:107\n    triggerUncaughtException(\n    ^\nError [ERR_MODULE_NOT_FOUND]: Cannot find package '~' imported from /srv/app/apps/acme-help/app/api/route.test.ts\n    at Object.getPackageJSONURL (node:internal/modules/package_json_reader:316:9)" });
    const out = await runHook(HOOK, alias, { env });
    assert.match(JSON.parse(out.stdout).hookSpecificOutput.additionalContext, /could not resolve the `~` path alias from \/srv\/app\/apps\/acme-help\/app\/api\/route\.test\.ts\..*pnpm --filter <package> test/);
    assert.strictEqual(readRecords(home, alias.cwd).length, 1);
    // A tool that is not a dependency of the importing package.
    const tool = failure({ tool_input: { command: 'node --import tsx --test /srv/app/packages/billing/gateway/x.test.ts' },
      error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'tsx' imported from /srv/app/packages/billing/gateway/x.test.ts" });
    assert.match(esmTestHint(tool), /could not find the package `tsx` from \/srv\/app\/packages\/billing\/gateway\/x\.test\.ts:.*not a dependency of that package/);
    // A library missing outside a test run is the same fact, with pnpm add.
    const lib = failure({ tool_input: { command: 'node dist/server.js' },
      error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'undici' imported from /srv/app/dist/server.js" });
    assert.match(esmTestHint(lib), /`undici`.*pnpm add/);
    // An extensionless local import in a test run: hedged on whether it exists;
    // a trailing digit in the importer's name survives, a :line:col does not.
    const local = failure({ tool_input: { command: 'node --import tsx --test /srv/app/apps/foo2/tests/suite1.test.ts' },
      error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/srv/app/apps/foo2/lib/admission.service' imported from /srv/app/apps/foo2/tests/suite1:12:3" });
    const localHint = esmTestHint(local);
    assert.match(localHint, /If that file exists.*if it does not, the import itself is wrong/);
    assert.match(localHint, /from \/srv\/app\/apps\/foo2\/tests\/suite1\./);
    // A missing file with a real extension, and a dev server, get nothing.
    const withExt = failure({ tool_input: { command: 'node --test x.test.ts' },
      error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/srv/app/dist/config.js' imported from /srv/app/dist/server.js" });
    assert.strictEqual(esmTestHint(withExt), null);
    const dev = failure({ tool_input: { command: 'pnpm dev' },
      error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/srv/app/lib/critters' imported from /srv/app/server.ts" });
    assert.strictEqual(esmTestHint(dev), null);
  } finally { rmTmp(home); }
});

test('a wrapped StructuredOutput failure gets the unwrap hint; an omitted field does not', () => {
  const { structuredOutputHint } = require('../PostToolUseFailure/papercut-log.js');
  const wrapped = structuredOutputHint({
    tool_name: 'StructuredOutput',
    tool_input: { input: { refuted: true, reasoning: 'x' } },
    error: "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'",
  });
  assert.match(wrapped, /wrapped under a top-level `input` key/);
  assert.match(wrapped, /refuted, reasoning/);
  const prose = structuredOutputHint({
    tool_name: 'StructuredOutput',
    tool_input: { summary: 'a paragraph of prose' },
    error: "Output does not match required schema: root: must have required property 'findings'",
  });
  assert.match(prose, /prose under a single `summary` key/);
  assert.match(prose, /findings/);
  const { structuredOutputShape } = require('../PostToolUseFailure/papercut-log.js');
  const asJson = { input: JSON.stringify({ refuted: true, reasoning: 'x' }) };
  assert.strictEqual(structuredOutputShape(asJson), 'keys:input=json',
    'a JSON-encoded object under input is its own shape, not prose');
  const jsonHint = structuredOutputHint({
    tool_name: 'StructuredOutput', tool_input: asJson,
    error: "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'",
  });
  assert.match(jsonHint, /JSON-encoded as a string under a top-level `input` key/);
  assert.match(jsonHint, /refuted, reasoning/);
  const envelopeHint = structuredOutputHint({
    tool_name: 'StructuredOutput', tool_input: { name: 'StructuredOutput', input: { refuted: true, reasoning: 'x' } },
    error: "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'",
  });
  assert.match(envelopeHint, /wrapped under a top-level `input` key/);
  const omitted = structuredOutputHint({
    tool_name: 'StructuredOutput',
    tool_input: { finding: 'x', key: 'y' },
    error: "Output does not match required schema: root: must have required property 'evidence'",
  });
  assert.strictEqual(omitted, null, 'the error text already names the fix for an omitted field');
  const wrongTool = structuredOutputHint({ tool_name: 'Read', tool_input: { input: {} }, error: 'Output does not match required schema' });
  assert.strictEqual(wrongTool, null);
});

test('worktree_collision keys only on git\'s own already-exists phrasings', () => {
  assert.match(signature("Exit code 128\nfatal: '/home/user/SITES/x/.claude/worktrees/foo' already exists", 'Bash'), /^worktree_collision:/);
  assert.match(signature("Exit code 128\nfatal: 'feature-x' is already used by worktree at '/home/user/SITES/x/.claude/worktrees/foo'", 'Bash'), /^worktree_collision:/);
  assert.match(signature("Exit code 128\nfatal: a branch named 'feature-x' already exists", 'Bash'), /^worktree_collision:/);
  // Planted negatives: the bare phrase elsewhere is not a collision.
  assert.doesNotMatch(signature('Exit code 1\n# Failed test 12: "recovery returns stale when the source set already exists"', 'Bash'), /worktree_collision/);
  assert.doesNotMatch(signature('Exit code 1\nERROR:  relation "users" already exists', 'Bash'), /worktree_collision/);
});

test('python errno ENOENT keys on its quoted path basename', () => {
  assert.strictEqual(
    signature("Exit code 3\npeer-job-runner: file missing or unreadable: [Errno 2] No such file or directory: '/tmp/run/adversarial-codex.json'", 'Bash'),
    'no_such_file:adversarial-codex.json');
  // node's comma form keeps its existing branch
  assert.strictEqual(
    signature("Error: ENOENT: no such file or directory, open '/x/y.txt'", 'Bash'),
    'no_such_file:y.txt');
  // subject-less ENOENT keeps the generic key
  assert.strictEqual(signature('ENOENT somewhere mysterious', 'Bash'), 'no_such_file');
});

test('every guard names itself, so its signature never depends on its prose', () => {
  // Inferring the guard from its deny text put git-guard's un-prefixed
  // `git add .` message into the generic bucket and split one runner-guard rule
  // across 13 signatures. The guard name must be explicit and must match the file.
  const dir = path.join(HOOKS_DIR, 'PreToolUse');
  const wrong = [];
  for (const g of fs.readdirSync(dir).filter((f) => f.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, g), 'utf8');
    if (!/setDenyContext\s*\(/.test(src)) continue;
    const m = src.match(/setDenyContext\(\{[\s\S]{0,80}?guard:\s*'([^']+)'/);
    const expected = g.replace(/\.js$/, '');
    if (!m) wrong.push(`${g} (no guard name)`);
    else if (m[1] !== expected) wrong.push(`${g} (says '${m[1]}')`);
  }
  assert.deepStrictEqual(wrong, [], `guard name missing or mismatched: ${wrong.join(', ')}`);
});

test('a denial without session_id or cwd still gets a usable identity', async () => {
  const { home, env } = sandbox();
  try {
    // Measured on live data: 95% of real PreToolUse payloads carried neither.
    // Empty values made rank() count every record as its own distinct session,
    // inventing "80 sessions" from 82 records. loop-guard.js:58-61 documents the
    // same gap and falls back to ppid.
    const p = { tool_name: 'Bash', tool_input: { command: 'git reset --hard HEAD' } };
    const res = await runHook('PreToolUse/git-guard.js', p, { env });
    assert.strictEqual(JSON.parse(res.stdout).hookSpecificOutput.permissionDecision, 'deny');
    const all = fs.readdirSync(path.join(home, '.claude', 'papercuts'));
    assert.strictEqual(all.length, 1, 'a record must still be written');
    const rec = JSON.parse(fs.readFileSync(path.join(home, '.claude', 'papercuts', all[0]), 'utf8').trim());
    assert.ok(rec.session, 'session must never be empty — it is the ranking unit');
    assert.ok(rec.cwd, 'cwd must never be empty — it is the project attribution');
    assert.strictEqual(rec.sig, 'guard_blocked:git-guard');
  } finally { rmTmp(home); }
});

test('one guard rule never splits across signatures by message wording', () => {
  // runner-guard's systemctl block produced 13 signatures differing only by verb
  // and a trailing quote. Attribution is by guard, so wording cannot fragment it.
  const { signature: _s } = require('../PostToolUseFailure/papercut-log.js');
  const variants = [
    "Blocked: systemctl restart on runner unit actions.runner.x.service'. The fleet runs killmode=control-group",
    'Blocked: systemctl kill on runner unit actions.runner.x.service. The fleet runs killmode=control-group',
    'Blocked: systemctl try-restart on runner unit actions.runner.y.service. The fleet runs killmode=control-group',
  ];
  // Text-derived signatures genuinely differ (that was the bug) ...
  assert.strictEqual(new Set(variants.map((v) => _s(v, 'Bash'))).size, 3);
  // ... which is exactly why the guard name, not the prose, is the signature.
});

test('a git-guard ALLOW writes nothing', async () => {
  const { home, env } = sandbox();
  try {
    const p = {
      tool_name: 'Bash',
      cwd: '/home/user/SITES/demo',
      session_id: 'aaaabbbbccccdddd',
      tool_input: { command: 'git status' },
    };
    await runHook('PreToolUse/git-guard.js', p, { env });
    assert.strictEqual(readRecords(home, p.cwd).length, 0, 'only denials are friction');
  } finally { rmTmp(home); }
});

test('guard enforcement survives an unwritable papercut store', async () => {
  const { home, env } = sandbox();
  try {
    // Logging must never be able to break a safety guard.
    fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(home, '.claude', 'papercuts'), 'not a dir');
    const p = {
      tool_name: 'Bash',
      cwd: '/home/user/SITES/demo',
      session_id: 'x',
      tool_input: { command: 'git push --force origin main' },
    };
    const res = await runHook('PreToolUse/git-guard.js', p, { env });
    assert.strictEqual(res.code, 0);
    assert.strictEqual(JSON.parse(res.stdout).hookSpecificOutput.permissionDecision, 'deny');
  } finally { rmTmp(home); }
});

// --- measured against the real 30-day corpus (22,278 records, no sampling) ----

test('a Bash failure with nothing but the exit-code line is not recorded', async () => {
  const { home, env } = sandbox();
  try {
    // 353 such records over 30 days — cd/pkill/ssh/find/timeout control flow,
    // 22% carrying signal exit codes and 16% xargs' exit-123 convention. It was
    // the single largest signature in the 7-day rollup simulation
    // (54 sessions / 693 occurrences) with zero actionable cases sampled.
    for (const err of ['Exit code 1', 'Exit code 143\n', 'Exit code 123']) {
      await runHook(HOOK, failure({ tool_input: { command: 'pkill -f something' }, error: err }), { env });
    }
    assert.strictEqual(readRecords(home, '/home/user/SITES/demo').length, 0);
  } finally { rmTmp(home); }
});

test('a Bash failure WITH content is still recorded', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({ tool_input: { command: 'tsc' }, error: 'Exit code 1\nsrc/a.ts(1,1): error TS1005' });
    await runHook(HOOK, p, { env });
    assert.strictEqual(readRecords(home, p.cwd).length, 1, 'the content-free skip must not swallow real failures');
  } finally { rmTmp(home); }
});

test('no_such_file recovers the real subject from coreutils and Node phrasings', () => {
  // The old capture required the path to be followed only by whitespace before
  // EOL, which no real message satisfies — it fired on 4% of cases and captured
  // ANSI fragments ('0m', '39m'). These recover a subject on 89%.
  assert.strictEqual(
    signature("ls: cannot access '/home/user/SITES/acme-app/apps/acme-editor': No such file or directory", 'Bash'),
    'no_such_file:acme-editor');
  assert.strictEqual(
    signature('/bin/bash: line 1: cd: apps/acme-web: No such file or directory', 'Bash'),
    'no_such_file:acme-web');
  assert.strictEqual(
    signature("Error: ENOENT: no such file or directory, open '/tmp/x/config.json'", 'Bash'),
    'no_such_file:config.json');
});

test('no_such_file never captures an ANSI fragment as the subject', () => {
  const sig = signature('[0;31mls: cannot access \'/nope/thing.txt\': No such file or directory[0m', 'Bash');
  assert.ok(!/0m|39m/.test(sig), `captured an ANSI fragment: ${sig}`);
});

test('a bare traceback header yields the exception, not the header', () => {
  // 265 occurrences / 105 sessions collapsed into one key once the exit-code fix
  // exposed them: JSONDecodeError, TypeError, KeyError and more, all one bucket.
  const a = signature('Exit code 1\nTraceback (most recent call last):\n  File "<string>", line 1\njson.decoder.JSONDecodeError: Expecting value', 'Bash');
  const b = signature('Exit code 1\nTraceback (most recent call last):\n  File "<string>", line 1\nKeyError: \'account_id\'', 'Bash');
  assert.notStrictEqual(a, b, 'distinct exceptions must not share one signature');
  for (const s of [a, b]) assert.ok(!/traceback/i.test(s), `still keyed on the header: ${s}`);
  assert.match(a, /jsondecodeerror/i);
});

test('projectSlug matches the ~/.claude/projects and memory-store convention', () => {
  assert.strictEqual(projectSlug('/home/user/SITES/acme-app'), '-home-user-SITES-acme-app');
});

// --- redaction: a papercut is never worth a leaked token ----------------------

test('redact scrubs the credential shapes that reach a GitHub issue body', () => {
  const cases = [
    ['curl -H "Authorization: Bearer sk-abc123def456ghi789"', 'sk-abc123def456ghi789'],
    ['psql postgres://admin:hunter2swordfish@db.example.net:5432/app', 'hunter2swordfish'],
    ['gh auth: token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345', 'ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345'],
    ['export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE', 'AKIAIOSFODNN7EXAMPLE'],
    ['PGPASSWORD=s3cr3tvalue psql -h db', 's3cr3tvalue'],
    ['{"api_key": "abcd1234efgh5678"}', 'abcd1234efgh5678'],
    ['slack: xoxb-1234567890-abcdefghijkl', 'xoxb-1234567890-abcdefghijkl'],
  ];
  for (const [input, secret] of cases) {
    const out = redact(input);
    assert.ok(!out.includes(secret), `secret survived redaction: ${input} -> ${out}`);
    assert.match(out, /<redacted>/);
  }
});

test('redact keeps a private key block bounded, not the key material', () => {
  // Fixture assembled from fragments so this test file does not itself trip
  // sync.sh's guard_no_credentials scanner (see the note beside REDACTIONS).
  const B = '-----BEGIN OPENSSH PRIV' + 'ATE KEY-----';
  const E = '-----END OPENSSH PRIV' + 'ATE KEY-----';
  const out = redact(`${B}\nb3BlbnNzaC1rZXktdjE\n${E}`);
  assert.ok(!out.includes('b3BlbnNzaC1rZXktdjE'), 'key material survived redaction');
  assert.ok(out.startsWith(B) && out.endsWith(E) && out.includes('<redacted>'));
});

test('redact covers the credential shapes the first pass missed', () => {
  // All three measured passing through unredacted before this fix: Stripe uses an
  // UNDERSCORE so the hyphenated sk- rule never matched, Google keys had no rule,
  // and a bare JWT carries no Authorization/Bearer label to anchor on.
  const cases = [
    ['stripe error: using key sk_live_51H8xAbCdEfGhIjKlMnOp', 'sk_live_51H8xAbCdEfGhIjKlMnOp'],
    ['stripe test mode pk_test_51H8xAbCdEfGhIjKlMnOp failed', 'pk_test_51H8xAbCdEfGhIjKlMnOp'],
    ['GET https://maps.googleapis.com/api?key=AIzaSyD1234567890abcdefghijklmnopqrst', 'AIzaSyD1234567890abcdefghijklmnopqrst'],
    ['jwt rejected: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NX0.dBjftJeZ4CVPmB92K27uhbUJU1p1r', 'dBjftJeZ4CVPmB92K27uhbUJU1p1r'],
  ];
  for (const [input, secret] of cases) {
    const out = redact(input);
    assert.ok(!out.includes(secret), `secret survived redaction: ${input} -> ${out}`);
    assert.match(out, /<redacted>/);
  }
});

// --- the Exit-code wrapper bug: the main source of garbage signatures ---------

test('signalLine skips the harness wrapper and returns the real message', () => {
  assert.strictEqual(signalLine('Exit code 1\ntsc: type error in foo.ts'), 'tsc: type error in foo.ts');
  assert.strictEqual(signalLine('Exit code 127'), 'Exit code 127', 'wrapper alone is better than nothing');
  assert.strictEqual(signalLine('plain message'), 'plain message');
});

test('unrelated Bash failures no longer collapse into one bash:exit-code bucket', () => {
  // Measured 2026-08-06: a TypeScript error, an eslint failure and a script exit
  // from three different repos all produced the identical signature
  // `bash:exit code <n>` and crossed the rollup threshold on day one.
  const a = signature('Exit code 1\nsrc/app.ts(9,5): error TS2322: Type mismatch', 'Bash');
  const b = signature('Exit code 1\n/app/x.js:3:1  error  Unexpected console statement', 'Bash');
  const c = signature('Exit code 1\nticker fetch failed for AAPL', 'Bash');
  assert.notStrictEqual(a, b);
  assert.notStrictEqual(b, c);
  assert.notStrictEqual(a, c);
  for (const s of [a, b, c]) assert.ok(!/^bash:exit code/.test(s), `still the catch-all: ${s}`);
});

test('Read/Edit "File does not exist" joins the same bucket as Bash ENOENT', () => {
  // Probed live: Read's wording never matched the ENOENT regex, so the same
  // underlying friction (a stale/wrong path) split across two buckets.
  assert.match(signature('File does not exist.', 'Read'), /^no_such_file/);
  assert.match(signature('ENOENT: no such file or directory', 'Bash'), /^no_such_file/);
});

test('signature subjects are length-capped so a record can never be dropped', () => {
  // sig is NOT shrunk by the oversize-record recovery path, so an unbounded
  // capture could push a record past MAX_RECORD_BYTES and lose it silently.
  const huge = 'x'.repeat(5000);
  assert.ok(signature(`bash: line 1: ${huge}: command not found`).length < 160);
  assert.ok(signature(`ModuleNotFoundError: No module named '${huge}'`).length < 160);
  // The fallback branch interpolates toolName; it must be capped too.
  assert.ok(signature('some unrecognized error text', huge).length < 260,
    'an unbounded tool name would push the record past the cap and drop it');
});

test('a guard denial with a huge command stays fast and still denies', async () => {
  const { home, env } = sandbox();
  try {
    // Several REDACTIONS patterns are O(n^2) on long non-matching input, and this
    // runs synchronously inside the guard. 1MB previously did not finish in five
    // minutes; hook timeouts fail CLOSED, so that stalls the session.
    const huge = 'a'.repeat(1024 * 1024);
    const p = {
      tool_name: 'Bash',
      cwd: '/home/user/SITES/demo',
      session_id: 'aaaabbbbccccdddd',
      tool_input: { command: `git reset --hard HEAD # ${huge}` },
    };
    const t0 = Date.now();
    const res = await runHook('PreToolUse/git-guard.js', p, { env });
    const ms = Date.now() - t0;
    assert.strictEqual(JSON.parse(res.stdout).hookSpecificOutput.permissionDecision, 'deny');
    assert.ok(ms < 10000, `guard took ${ms}ms on a 1MB command; input must be truncated before redact()`);
    assert.strictEqual(readRecords(home, p.cwd).length, 1);
  } finally { rmTmp(home); }
});

test('redact leaves ordinary friction text intact', () => {
  const plain = '/bin/bash: line 1: pytest: command not found';
  assert.strictEqual(redact(plain), plain, 'over-redaction would destroy the signal');
});

test('a secret in a failing command never reaches the store', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({
      tool_input: { command: 'curl -H "Authorization: Bearer sk-livetoken1234567890" https://api.x' },
      error: 'curl: (22) HTTP 401 for https://user:hunter2swordfish@api.x/v1',
    });
    await runHook(HOOK, p, { env });
    const raw = fs.readFileSync(storeFor(home, p.cwd), 'utf8');
    assert.ok(!raw.includes('sk-livetoken1234567890'), 'command secret leaked into the store');
    assert.ok(!raw.includes('hunter2swordfish'), 'URI password leaked into the store');
    assert.match(raw, /<redacted>/);
  } finally { rmTmp(home); }
});

test('StructuredOutput schema failures collapse to one signature', () => {
  // Measured 2026-08-06: this one failure mode fragmented across 52 signatures
  // (122 records, 17 sessions, 49% of all auto-source fallback) because the
  // message names whichever property happened to be missing first. No fragment
  // ever crossed the rollup threshold, so the largest real cluster was invisible.
  const variants = [
    "Output does not match required schema: root: must have required property 'headline'",
    "Output does not match required schema: root: must have required property 'impact_here'",
    "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'",
  ];
  const sigs = new Set(variants.map((v) => signature(v, 'StructuredOutput')));
  assert.strictEqual(sigs.size, 1, `expected one bucket, got ${[...sigs].join(' | ')}`);
  assert.strictEqual([...sigs][0], 'structuredoutput_schema_mismatch');
});

test('the schema collapse does not swallow unrelated StructuredOutput errors', () => {
  const other = signature('StructuredOutput tool timed out waiting for the model', 'StructuredOutput');
  assert.notStrictEqual(other, 'structuredoutput_schema_mismatch');
});

// --- store resolution: the hook and the CLI must never diverge ---------------

// --- target: WHAT the tool failed on, not just that it failed -----------------

test('records WHAT a non-Bash tool failed on', async () => {
  // Only Bash carries `command`, so every other tool logged the error and lost
  // the subject. Measured over 30 days: 6,350 Read records, 1,385
  // StructuredOutput, 1,178 WebSearch and ~520 MCP/WebFetch had no target at
  // all -- which is why the corpus's #2 and #3 signatures could not be triaged.
  const { home, env } = sandbox();
  try {
    const p = failure({ tool_name: 'Read',
                        tool_input: { file_path: '/home/user/SITES/demo/huge.md' },
                        error: 'File content (108892 tokens) exceeds maximum allowed tokens (25000).' });
    await runHook(HOOK, p, { env });
    const [rec] = readRecords(home, p.cwd);
    assert.strictEqual(rec.target, '/home/user/SITES/demo/huge.md');
  } finally { rmTmp(home); }
});

test('a search records its query as the target', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({ tool_name: 'WebSearch',
                        tool_input: { query: 'how to fix the thing' },
                        error: 'API Error: 400 the requested server-tool options are invalid.' });
    await runHook(HOOK, p, { env });
    assert.strictEqual(readRecords(home, p.cwd)[0].target, 'how to fix the thing');
  } finally { rmTmp(home); }
});

test('a Bash failure is unchanged: command in cmd, no target', async () => {
  // Planted negative. rawCmd stays load-bearing for BENIGN_COMMAND and the
  // content-free check, so this must not drift.
  const { home, env } = sandbox();
  try {
    const p = failure();
    await runHook(HOOK, p, { env });
    const [rec] = readRecords(home, p.cwd);
    assert.strictEqual(rec.cmd, 'pytest -q');
    assert.strictEqual(rec.target, '');
  } finally { rmTmp(home); }
});

test('a secret in a target never reaches the store', async () => {
  const { home, env } = sandbox();
  try {
    const p = failure({ tool_name: 'Read',
                        tool_input: { file_path: '/tmp/x?token=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' },
                        error: 'File does not exist.' });
    await runHook(HOOK, p, { env });
    const [rec] = readRecords(home, p.cwd);
    assert.ok(!rec.target.includes('ghp_AAAA'), `secret leaked: ${rec.target}`);
    assert.match(rec.target, /redacted/);
  } finally { rmTmp(home); }
});

test('an unrecognised tool input captures nothing rather than a blob', async () => {
  // Allowlist, not a dump: a blob capture would sweep in arguments nobody
  // vetted and grow every record.
  const { home, env } = sandbox();
  try {
    const p = failure({ tool_name: 'SomeTool',
                        tool_input: { secret_payload: 'do-not-capture-me', size: 3 },
                        error: 'it broke' });
    await runHook(HOOK, p, { env });
    const [rec] = readRecords(home, p.cwd);
    assert.strictEqual(rec.target, '');
    assert.ok(!JSON.stringify(rec).includes('do-not-capture-me'));
  } finally { rmTmp(home); }
});

test('honors PAPERCUT_STORE, the same override the CLI reads', async () => {
  // papercut.py:68 resolves STORE from PAPERCUT_STORE; this hook hardcoded
  // ~/.claude/papercuts. Anyone who set the variable got a split corpus -- the
  // hook appending records that list/triage/rollup would never read, so real
  // friction silently read as "never happened".
  const { home, env } = sandbox();
  const store = mkTmp('papercut-store-');
  try {
    const p = failure();
    await runHook(HOOK, p, { env: { ...env, PAPERCUT_STORE: store } });
    const overridden = path.join(store, `${projectSlug(p.cwd)}.jsonl`);
    assert.ok(fs.existsSync(overridden), 'the record must land in $PAPERCUT_STORE');
    const rec = JSON.parse(fs.readFileSync(overridden, 'utf8').trim());
    assert.strictEqual(rec.cwd, p.cwd);
    assert.ok(!fs.existsSync(path.join(home, '.claude', 'papercuts')),
      'nothing may be written to the default store while an override is set');
  } finally { rmTmp(home); rmTmp(store); }
});

test('a synthesized session identity keeps its marker', async () => {
  // The hook falls back to `ppid-<pid>` when a payload carries no session_id,
  // specifically so a synthesized identity is recognizable. A .slice(-8) on the
  // result used to cut from the right and keep only the digits, so `ppid-318283`
  // was stored as `d-318283` -- shaped exactly like a real 8-char session id.
  // Measured on the live store: 4,899 of 4,917 runner-guard records were
  // synthesized, and separating them meant inferring intent from a stray hyphen.
  // The ppid fallback lives on the GUARD path (source: 'guard'), which is
  // reached through a PreToolUse guard denial, not the PostToolUseFailure path.
  const { home, env } = sandbox();
  try {
    const p = { tool_name: 'Bash', tool_input: { command: 'git reset --hard HEAD' } };
    const res = await runHook('PreToolUse/git-guard.js', p, { env });
    assert.strictEqual(JSON.parse(res.stdout).hookSpecificOutput.permissionDecision, 'deny');
    const dir = path.join(home, '.claude', 'papercuts');
    const files = fs.readdirSync(dir);
    assert.strictEqual(files.length, 1);
    const rec = JSON.parse(fs.readFileSync(path.join(dir, files[0]), 'utf8').trim());
    assert.match(rec.session, /^ppid-\d+$/,
      `a denial with no session_id must store a marked identity, got ${rec.session}`);
  } finally { rmTmp(home); }
});

test('a real session id is still shortened to its last 8 characters', async () => {
  // The bound still applies where there is no marker to lose.
  const { home, env } = sandbox();
  try {
    const p = failure({ session_id: 'abcdefgh12345678' });
    await runHook(HOOK, p, { env });
    const recs = readRecords(home, p.cwd);
    assert.strictEqual(recs[0].session, '12345678');
    assert.ok(!recs[0].session.includes('-'),
      'a real session id must never look like a synthesized one');
  } finally { rmTmp(home); }
});

test('the CLI reads back the record the hook just wrote to PAPERCUT_STORE', () => {
  // The gap PR #593 left open. That change made the hook honor PAPERCUT_STORE,
  // and both halves were tested -- the hook writes there (test above), and the
  // python suite sets the same variable for its own isolation. Neither proves
  // the ROUND TRIP: that the CLI reads the file the hook just wrote. That is
  // the actual invariant #593 claims, and it spans two languages and two
  // suites, so neither suite could catch a divergence on its own.
  //
  // Binds the two sides by the hook's OWN computed signature rather than a
  // hard-coded string, so a change to signature() cannot pass this vacuously.
  const { home, env } = sandbox();
  const store = mkTmp('papercut-parity-');
  try {
    const p = failure();
    const expected = signature(p.error, p.tool_name);

    const hook = spawnSync(process.execPath, [path.join(HOOKS_DIR, HOOK)], {
      input: JSON.stringify(p),
      env: { ...process.env, ...env, PAPERCUT_STORE: store },
      encoding: 'utf8',
    });
    assert.strictEqual(hook.status, 0, `hook failed: ${hook.stderr}`);

    const cli = path.join(HOOKS_DIR, '..', 'bin', 'papercut.py');
    const read = spawnSync('python3', [cli, 'list', '--days', '30'], {
      env: { ...process.env, ...env, PAPERCUT_STORE: store },
      encoding: 'utf8',
    });
    assert.strictEqual(read.status, 0, `CLI failed: ${read.stderr}`);
    assert.ok(
      read.stdout.includes(expected),
      `the CLI must read back the hook's record from the same store; ` +
      `wanted signature ${expected} in:\n${read.stdout}`,
    );

    // ...and the default store must be untouched, so a pass cannot come from
    // both sides quietly agreeing on ~/.claude/papercuts instead.
    assert.ok(!fs.existsSync(path.join(home, '.claude', 'papercuts')),
      'nothing may be written to the default store while an override is set');
  } finally { rmTmp(home); rmTmp(store); }
});

test('a blank PAPERCUT_STORE falls back to the default store', async () => {
  // An empty or whitespace value is an unset variable, not a request to write
  // to a whitespace-named directory.
  const { home, env } = sandbox();
  try {
    const p = failure();
    await runHook(HOOK, p, { env: { ...env, PAPERCUT_STORE: '   ' } });
    assert.strictEqual(readRecords(home, p.cwd).length, 1,
      'a blank override must not redirect the write');
  } finally { rmTmp(home); }
});
