'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');
const { runHook, decisionOf, reasonOf, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'Stop/verify-on-stop.js';

// Build a temp project with a .claude/verify.sh that (a) touches a canary file so
// we can prove whether it executed, and (b) exits with `code`. The canary is the
// key signal for the trust-gate test: if it exists, repo shell ran.
function project(code) {
  const dir = mkTmp('vos-proj-');
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  const canary = path.join(dir, 'RAN');
  fs.writeFileSync(
    path.join(dir, '.claude', 'verify.sh'),
    `#!/usr/bin/env bash\ntouch ${JSON.stringify(canary)}\nexit ${code}\n`
  );
  return { dir, canary };
}

// Build a temp GIT project whose package.json typecheck script writes `$CI|$GIT_OPTIONAL_LOCKS`
// to a canary file (proving execution and the CI=1, GIT_OPTIONAL_LOCKS=0 env) and exits
// with `typecheckExit`. The baseline commit is back-dated to 2020 so it can
// never be mistaken for a commit made "during" a test's fake session.
function gitProject({ typecheckExit = 0, nodeModules = false } = {}) {
  const dir = mkTmp('vos-git-');
  const g = (args, env) =>
    execSync(`git ${args}`, { cwd: dir, env: { ...process.env, ...env }, stdio: 'ignore' });
  g('init -q -b main');
  g('config user.email test@test.invalid');
  g('config user.name test');
  const canary = path.join(dir, 'CANARY');
  fs.writeFileSync(
    path.join(dir, 'check.js'),
    `require('fs').writeFileSync(${JSON.stringify(canary)}, (process.env.CI || '') + '|' + (process.env.GIT_OPTIONAL_LOCKS || ''));process.exit(${typecheckExit});`
  );
  fs.writeFileSync(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 't', version: '1.0.0', scripts: { typecheck: 'node check.js' } })
  );
  fs.writeFileSync(path.join(dir, 'old.ts'), 'export const a = 1;\n');
  const past = { GIT_AUTHOR_DATE: '2020-01-01T00:00:00Z', GIT_COMMITTER_DATE: '2020-01-01T00:00:00Z' };
  g('add -A');
  g('commit -q -m baseline', past);
  if (nodeModules) fs.mkdirSync(path.join(dir, 'node_modules'));
  return { dir, canary, g };
}

// Fake session transcript whose first line carries the session-start timestamp.
function transcriptFor(dir, msAgo = 60000) {
  const tp = path.join(dir, 'transcript.jsonl');
  fs.writeFileSync(
    tp,
    JSON.stringify({ type: 'system', timestamp: new Date(Date.now() - msAgo).toISOString() }) + '\n'
  );
  return tp;
}

const trustEnv = (dir) => ({
  CLAUDE_VERIFY_TRUSTED_ROOTS: path.dirname(dir),
  HOME: dir,
  USERPROFILE: dir,
});

test('stop_hook_active=true short-circuits (loop safety) even when armed', async () => {
  const { dir, canary } = project(1);
  try {
    const p = { cwd: dir, stop_hook_active: true };
    // Armed via env, but stop_hook_active must win first so a blocking Stop hook
    // can never drive an infinite continuation loop.
    assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir } }));
    assert.ok(!fs.existsSync(canary), 'must not execute the verifier once already blocking');
  } finally {
    rmTmp(dir);
  }
});

test('untrusted dir: a repo-provided .claude/verify.sh is NOT auto-executed (F3)', async () => {
  const { dir, canary } = project(1);
  try {
    // No env opt-in; cwd is a temp dir not under any trusted root -> full no-op.
    const p = { cwd: dir, stop_hook_active: false };
    const env = { CLAUDE_VERIFY_TRUSTED_ROOTS: '/nonexistent', HOME: dir, USERPROFILE: dir };
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.ok(!fs.existsSync(canary), 'mere presence of .claude/verify.sh must not run shell in an untrusted dir');
  } finally {
    rmTmp(dir);
  }
});

test('explicit env opt-in: a failing verify.sh blocks the stop', async () => {
  const { dir, canary } = project(1);
  try {
    const p = { cwd: dir, stop_hook_active: false };
    const res = await runHook(HOOK, p, { env: { CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir } });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /Verification gate FAILED/i);
    assert.ok(fs.existsSync(canary), 'the trusted verifier should have executed');
  } finally {
    rmTmp(dir);
  }
});

test('trusted root: a passing verify.sh runs and allows the stop (pass-through)', async () => {
  const { dir, canary } = project(0);
  try {
    // Mark the project's parent as a trusted root, so isTrusted() is true without env=1.
    // The fixture is not a git repo, so change detection is unknown -> gate runs.
    const p = { cwd: dir, stop_hook_active: false };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'a trusted passing verifier runs, then allows the stop');
  } finally {
    rmTmp(dir);
  }
});

test('malformed input passes through', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
});

// --- v2: session-scoped change gating ---------------------------------------

test('docs-only session skips the gate entirely (no exec, no deps demand)', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: false });
  try {
    fs.writeFileSync(path.join(dir, 'notes.md'), '# nothing tsc cares about\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    // Even with node_modules missing AND a failing typecheck, a docs-only
    // session must pass through untouched.
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(!fs.existsSync(canary), 'verifier must not run for a docs-only session');
  } finally {
    rmTmp(dir);
  }
});

test('pre-existing dirty code (old mtime, parked checkout) does not trigger the gate', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: true });
  try {
    // Simulate weeks-old local drift: a modified .ts whose mtime long predates
    // this session (the prbot parked-checkout regression).
    fs.appendFileSync(path.join(dir, 'old.ts'), '// drift\n');
    const old = new Date(Date.now() - 10 * 86400000);
    fs.utimesSync(path.join(dir, 'old.ts'), old, old);
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(!fs.existsSync(canary), 'weeks-old dirt is not this session\'s work');
  } finally {
    rmTmp(dir);
  }
});

test('fresh code change runs the gate with CI=1', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    fs.writeFileSync(path.join(dir, 'new.ts'), 'export const b = 2;\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'a session-fresh .ts change must trigger verification');
    assert.strictEqual(fs.readFileSync(canary, 'utf8'), '1|0', 'verify command must run with CI=1 and GIT_OPTIONAL_LOCKS=0');
  } finally {
    rmTmp(dir);
  }
});

test('fresh code change + failing typecheck still blocks', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: true });
  try {
    fs.writeFileSync(path.join(dir, 'new.ts'), 'export const b = 2;\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    const res = await runHook(HOOK, p, { env: trustEnv(dir) });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /Verification gate FAILED/i);
    assert.ok(fs.existsSync(canary));
  } finally {
    rmTmp(dir);
  }
});

test('missing node_modules yields the environmental block, not a fake failure', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 1, nodeModules: false });
  try {
    fs.writeFileSync(path.join(dir, 'new.ts'), 'export const b = 2;\n');
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    const res = await runHook(HOOK, p, { env: trustEnv(dir) });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /node_modules missing/i);
    assert.match(reasonOf(res), /npm ci/, 'no lockfile in fixture, so the npm install command is surfaced');
    assert.ok(!fs.existsSync(canary), 'the verify command must not run before deps exist');
  } finally {
    rmTmp(dir);
  }
});

test('commit made during the session triggers the gate on a clean tree', async () => {
  const { dir, canary, g } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    fs.writeFileSync(path.join(dir, 'b.ts'), 'export const c = 3;\n');
    g('add b.ts');
    g('commit -q -m session-work'); // committer date = now, inside the session window
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'committed session work must be verified even with a clean tree');
  } finally {
    rmTmp(dir);
  }
});

test('no transcript timestamp: conservative, dirty code runs the gate', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    fs.appendFileSync(path.join(dir, 'old.ts'), '// drift\n');
    const old = new Date(Date.now() - 10 * 86400000);
    fs.utimesSync(path.join(dir, 'old.ts'), old, old);
    const p = { cwd: dir, stop_hook_active: false }; // no transcript_path at all
    assertQuietPassThrough(await runHook(HOOK, p, { env: trustEnv(dir) }));
    assert.ok(fs.existsSync(canary), 'without a session timestamp the gate must err toward verifying');
  } finally {
    rmTmp(dir);
  }
});

test('explicit CLAUDE_VERIFY_ON_STOP=1 bypasses change gating (claude-loop contract)', async () => {
  const { dir, canary } = gitProject({ typecheckExit: 0, nodeModules: true });
  try {
    // Zero session changes of any kind, yet the explicit arm must still verify.
    const p = { cwd: dir, stop_hook_active: false, transcript_path: transcriptFor(dir) };
    const env = { CLAUDE_VERIFY_ON_STOP: '1', HOME: dir, USERPROFILE: dir };
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.ok(fs.existsSync(canary), 'explicit arm always verifies');
  } finally {
    rmTmp(dir);
  }
});

// =============================================================================
// U3: positive handoff hand-back predicate (KD1-KD7, KTD1-KTD6)
// =============================================================================

function tmpHome() {
  return mkTmp('vos-handback-home-');
}

// Seeds the U1 record layer this predicate reads (never writes) -- one JSONL
// row per session->PR link, mirroring pr-record.js's row shape exactly.
function seedSessionPrs(home, rows) {
  const dir = path.join(home, '.claude', 'logs');
  fs.mkdirSync(dir, { recursive: true });
  const lines = rows.map((r) =>
    JSON.stringify({ fp: 1, ts: new Date().toISOString(), pending: false, ...r })
  );
  fs.writeFileSync(path.join(dir, 'session-prs.jsonl'), lines.join('\n') + '\n');
}

function handbackLedgerPath(home) {
  return path.join(home, '.claude', 'logs', 'handback-ledger.jsonl');
}

function readHandbackRows(home) {
  const p = handbackLedgerPath(home);
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

// U8: parse a hook's stdout and return its `systemMessage`, or null. Not in
// lib/harness.js (out of scope for this unit) since no other hook emits this
// field yet.
function systemMessageOf(res) {
  try {
    const out = JSON.parse(res.stdout);
    return typeof out.systemMessage === 'string' ? out.systemMessage : null;
  } catch {
    return null;
  }
}

function shQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

// Fake `gh`: routes `pr view <n> --repo R --json ...` and `issue view <n>
// --repo R --json ...` by the numeric id to a canned JSON fixture (same
// PATH-shim idiom as pr-record.test.js / needs-human.test.sh). `pr list` (only
// reached if a seeded row were still pending, which these tests never do)
// answers empty. `sleepMs` simulates a hung network call for the timeout /
// inconclusive scenario -- KTD3 requires a hang to yield inconclusive, never a
// block, and never a ledger row.
// prListByHead (U8): maps a branch name to the PR number resolvePending()'s
// own `gh pr list --repo R --head <branch> --json number` lookup should find
// for it; a branch with no entry answers `[]` (still no PR). callLog (U8):
// when given, every invocation appends its full argv to that file so a test
// can assert a call NEVER happened (e.g. "no pr view call") without relying
// on prStates/issueStates' permissive `*) echo '{}'` fallback to catch it.
function writeFakeGh(binDir, { prStates = {}, issueStates = {}, prListByHead = {}, sleepMs = 0, callLog = null, exitCode = 0 } = {}) {
  const prCases = Object.entries(prStates)
    .map(([num, json]) => `      ${num}) echo ${shQuote(JSON.stringify(json))} ;;`)
    .join('\n');
  const issueCases = Object.entries(issueStates)
    .map(([num, json]) => `      ${num}) echo ${shQuote(JSON.stringify(json))} ;;`)
    .join('\n');
  const prListCases = Object.entries(prListByHead)
    .map(([branch, num]) => `      ${shQuote(branch)}) echo ${shQuote(JSON.stringify([{ number: num }]))} ;;`)
    .join('\n');
  const body = `#!/usr/bin/env bash
set -u
${callLog ? `echo "$*" >> ${shQuote(callLog)}` : ''}
${sleepMs ? `sleep ${sleepMs / 1000}` : ''}
${exitCode ? `exit ${exitCode}` : ''}
case "$1 $2" in
  "pr view")
    case "$3" in
${prCases}
      *) echo '{}' ;;
    esac
    ;;
  "issue view")
    case "$3" in
${issueCases}
      *) echo '{}' ;;
    esac
    ;;
  "pr list")
    head=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --head) head="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$head" in
${prListCases}
      *) echo '[]' ;;
    esac
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
`;
  const p = path.join(binDir, 'gh');
  fs.writeFileSync(p, body);
  fs.chmodSync(p, 0o755);
}

// A `gh` that only proves whether it was ever invoked (touches `sentinel`),
// for the off-mode inertness test -- distinguishes "never called gh" from
// "called gh and got a harmless answer."
function writeSentinelGh(binDir, sentinel) {
  const p = path.join(binDir, 'gh');
  fs.writeFileSync(p, `#!/usr/bin/env bash\ntouch ${JSON.stringify(sentinel)}\necho '{}'\n`);
  fs.chmodSync(p, 0o755);
}

// U8 error-path fixture: pr-record.js's resolvePending() is written so it can
// never throw for any row/deadline shape reachable from valid stdin (every
// risky call is already try/caught internally) -- so the only way to exercise
// verify-on-stop.js's own `try { require(...).resolvePending(...) } catch`
// fail-open wrapper is to make the require() itself fail. A NODE_OPTIONS
// --require shim that intercepts just that one module id does this without
// touching pr-record.js (out of scope for this unit).
function writeResolvePendingThrowShim(dir) {
  const p = path.join(dir, 'throw-on-pr-record-require.js');
  fs.writeFileSync(
    p,
    "'use strict';\n" +
    "const Module = require('module');\n" +
    'const orig = Module.prototype.require;\n' +
    'Module.prototype.require = function (id) {\n' +
    "  if (typeof id === 'string' && id.indexOf('pr-record.js') !== -1) {\n" +
    "    throw new Error('resolvePending boom (test fixture)');\n" +
    '  }\n' +
    '  return orig.apply(this, arguments);\n' +
    '};\n'
  );
  return p;
}

function handbackEnv(home, binDir, extra = {}) {
  return {
    HOME: home,
    USERPROFILE: home,
    PATH: `${binDir}:${process.env.PATH}`,
    CLAUDE_HANDBACK_MODE: 'shadow',
    ...extra,
  };
}

const GREEN = {
  state: 'OPEN', mergedAt: null, autoMergeRequest: null,
  statusCheckRollup: [{ name: 'Test', status: 'COMPLETED', conclusion: 'SUCCESS' }],
};
const MERGED = {
  state: 'MERGED', mergedAt: '2026-08-17T10:00:00Z', autoMergeRequest: null, statusCheckRollup: [],
};
const PENDING = {
  state: 'OPEN', mergedAt: null, autoMergeRequest: null,
  statusCheckRollup: [{ name: 'Test', status: 'IN_PROGRESS', conclusion: null }],
};

test('KTD2 planted negative (load-bearing): untrusted repo, no resolvable verify command -- the hand-back predicate STILL runs and shadow-logs', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 11: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ktd2', repo: 'acme/widgets', pr: 11, branch: 'b' }]);
    const p = {
      // No .claude/verify.sh, no package.json, no pyproject.toml, and not under
      // any trusted root: the verify-command path has NOTHING to block on for
      // two independent reasons (untrusted AND unresolvable). KTD2's defect
      // class is a naive "append the predicate after the last no-block return"
      // implementation, which is dead code for exactly this cwd shape.
      cwd, stop_hook_active: false, session_id: 'sess-ktd2',
      last_assistant_message: 'All set, nothing more from me.',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_VERIFY_TRUSTED_ROOTS: '/nonexistent' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    const rows = readHandbackRows(home);
    assert.strictEqual(rows.length, 1, 'the verify path found nothing to block on, so the hand-back predicate must still have run and logged');
    assert.strictEqual(rows[0].repo, 'acme/widgets');
    assert.strictEqual(rows[0].pr, 11);
    assert.strictEqual(rows[0].condition, 'no-tag');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('planted negative (R6/R11, AE1): enforce mode, gate-green unmerged PR, "result:" with no state backing it -- blocks once with a machine-gate reason', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 21: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ae1', repo: 'acme/widgets', pr: 21, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-ae1',
      last_assistant_message: 'result: PR ready for your review',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(decisionOf(res), 'block');
    const reason = reasonOf(res) || '';
    assert.match(reason, /MACHINE GATE/i);
    assert.ok(!/\bdenied\b/i.test(reason), 'must not read as a user denial (anthropics/claude-code#24327)');
    assert.match(reason, /acme\/widgets#21/);
    // The session may be in any repository, so name the installed scripts.
    assert.ok(reason.includes('~/.claude/scripts/needs-human.sh'), 'names the installed needs-human.sh');
    assert.ok(!/(?<!~\/\.)claude\/scripts\/needs-human\.sh/.test(reason), 'no repo-relative needs-human.sh path');
    assert.strictEqual(readHandbackRows(home).length, 0, 'enforce mode blocks; it does not also write the shadow ledger');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('planted negative (R13, AE7): enforce mode, gate-green unmerged PR, "failed:" is not a valid exit while the PR is still open -- blocks', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 22: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ae7', repo: 'acme/widgets', pr: 22, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-ae7',
      last_assistant_message: 'failed: could not complete',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res) || '', /MACHINE GATE/i);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('happy (R6/AE6): merged PR, arbitrary phrasing -- passes, no record (no phrase list consulted, even under enforce)', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 31: MERGED } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ae6', repo: 'acme/widgets', pr: 31, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-ae6',
      last_assistant_message: 'Whatever wording -- the PR merged itself basically, thanks!',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 0);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('happy (R7): valid "needs input:" citing an open, PR-referencing needs-human artifact -- passes', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, {
    prStates: { 41: GREEN },
    issueStates: {
      57: {
        state: 'OPEN',
        labels: [{ name: 'needs-human' }],
        body: 'Category: prod-data-mutation\nGated PR: #41\n\nneeds a DELETE against prod.',
      },
    },
  });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-r7', repo: 'acme/widgets', pr: 41, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-r7',
      last_assistant_message: 'needs input: filed https://github.com/acme/widgets/issues/57 for the prod mutation',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 0);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('edge (R7/AE9): needs-input artifact closed since filing -- treated as unresolved (shadow-logged, not a clean pass)', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, {
    prStates: { 42: GREEN },
    issueStates: { 58: { state: 'CLOSED', labels: [{ name: 'needs-human' }], body: 'Gated PR: #42' } },
  });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ae9', repo: 'acme/widgets', pr: 42, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-ae9',
      last_assistant_message: 'needs input: see #58',
    };
    const env = handbackEnv(home, binDir); // shadow (explicit default)
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    const rows = readHandbackRows(home);
    assert.strictEqual(rows.length, 1, 'a closed artifact must not let the PR read as resolved');
    assert.strictEqual(rows[0].condition, 'needs-input-artifact-invalid');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('edge (R12): required checks pending -- no record, no block (out of scope)', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 61: PENDING } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-r12', repo: 'acme/widgets', pr: 61, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-r12',
      last_assistant_message: 'Still waiting on CI.',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 0);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('edge (AE5): stop_hook_active short-circuits BOTH gates, even with a hand-back-eligible PR present', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 71: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ae5', repo: 'acme/widgets', pr: 71, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: true, session_id: 'sess-ae5',
      last_assistant_message: 'result: done',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 0, 'stop_hook_active must prevent even a shadow-style evaluation from running');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('edge (R15): two recorded PRs, one merged and one unresolved -- exactly one record, for the unresolved PR', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 81: MERGED, 82: GREEN } });
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-r15', repo: 'acme/widgets', pr: 81, branch: 'a' },
      { session_id: 'sess-r15', repo: 'acme/widgets', pr: 82, branch: 'b' },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-r15',
      last_assistant_message: 'Both done I think.',
    };
    const env = handbackEnv(home, binDir);
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    const rows = readHandbackRows(home);
    assert.strictEqual(rows.length, 1, 'exactly one record, per R15');
    assert.strictEqual(rows[0].pr, 82);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('error (KTD3/AE8): gh times out -- outcome inconclusive, stop allowed, NO hand-back record', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 91: GREEN }, sleepMs: 3000 });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-ae8', repo: 'acme/widgets', pr: 91, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-ae8',
      last_assistant_message: 'result: merged it',
    };
    // enforce mode too: proves a timeout NEVER blocks, not merely that shadow
    // mode declines to log one.
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce', CLAUDE_HANDBACK_GH_TIMEOUT_MS: '200' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 0);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('integration (#1515): verify failure AND enforced handback deliver both reasons in the first Stop', async () => {
  const { dir, canary } = project(1); // fails
  const home = tmpHome();
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 91: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-integration', repo: 'acme/widgets', pr: 91, branch: 'b' }]);
    const p = {
      cwd: dir, stop_hook_active: false, session_id: 'sess-integration',
      last_assistant_message: 'result: ready',
    };
    const env = {
      CLAUDE_VERIFY_TRUSTED_ROOTS: path.dirname(dir),
      HOME: home,
      USERPROFILE: home,
      PATH: `${binDir}:${process.env.PATH}`,
      CLAUDE_HANDBACK_MODE: 'enforce',
    };
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res) || '', /Verification gate FAILED/i);
    assert.ok(fs.existsSync(canary), 'the verify command should have run and failed');
    assert.match(reasonOf(res), /MACHINE GATE/);
    assert.match(reasonOf(res), /acme\/widgets#91/);
    assert.strictEqual(readHandbackRows(home).length, 0, 'enforce does not write the shadow ledger');
  } finally {
    rmTmp(dir); rmTmp(home); rmTmp(binDir);
  }
});

test('off mode: hand-back predicate is fully inert -- gh is never even invoked', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  const sentinel = path.join(binDir, 'CALLED');
  writeSentinelGh(binDir, sentinel);
  try {
    seedSessionPrs(home, [{ session_id: 'sess-off', repo: 'acme/widgets', pr: 111, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-off',
      last_assistant_message: 'result: done',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'off' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.ok(!fs.existsSync(sentinel), 'off mode must not invoke gh at all');
    assert.strictEqual(readHandbackRows(home).length, 0);
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

// --- Review-round regression cases (2026-08-18) -----------------------------
// Each planted negative below fails against the pre-review implementation.

const CLOSED_UNMERGED = {
  state: 'CLOSED', mergedAt: null, autoMergeRequest: null, statusCheckRollup: [],
};

test('planted negative (review): one ledger row per session+PR incident, not one per Stop event', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 71: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-dedupe', repo: 'acme/widgets', pr: 71, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-dedupe',
      last_assistant_message: 'result: PR is up for your review',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'shadow' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 1,
      'three turn-ends on one unresolved PR is one incident, not three -- otherwise the flip metric inflates');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('planted negative (review): a PR closed without merging is out of scope -- never blocks, never logs', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 72: CLOSED_UNMERGED } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-closed', repo: 'acme/widgets', pr: 72, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-closed',
      last_assistant_message: 'Closed that PR -- superseded by another approach.',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.strictEqual(readHandbackRows(home).length, 0,
      'an abandoned PR has no reachable valid exit -- gating it would trap the session');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('planted negative (review): CLAUDE_HANDBACK_MODE=1 arms enforcement instead of silently shadowing', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 73: GREEN } });
  try {
    seedSessionPrs(home, [{ session_id: 'sess-mode1', repo: 'acme/widgets', pr: 73, branch: 'b' }]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-mode1',
      last_assistant_message: 'result: ready for your review',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: '1' });
    assert.strictEqual(decisionOf(await runHook(HOOK, p, { env })), 'block',
      'the sibling verify gate arms with =1; a typo must not silently disarm this one');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

// =============================================================================
// U8: stop-time handback keeps a signal for deferred (claimed, no-PR) work
// =============================================================================

test('U8: session with no PR/claim rows at all -- null return unchanged (zero-row pass-through)', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  const sentinel = path.join(binDir, 'CALLED');
  writeSentinelGh(binDir, sentinel);
  try {
    // No seedSessionPrs call: session-prs.jsonl does not exist for this session.
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-norows',
      last_assistant_message: 'Nothing to report.',
    };
    const env = handbackEnv(home, binDir);
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    assert.ok(!fs.existsSync(sentinel), 'zero rows for this session: gh must never be consulted');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('U8 (AE11): one pending row, gh pr list finds nothing -- systemMessage names the branch, no verification call', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  const callLog = path.join(binDir, 'CALLS');
  writeFakeGh(binDir, { callLog }); // no prListByHead entries: every --head lookup answers []
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-u8-nopr', repo: 'acme/widgets', branch: 'feat-nopr', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-nopr',
      last_assistant_message: 'Still working on it.',
    };
    const env = handbackEnv(home, binDir);
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
    const msg = systemMessageOf(res);
    assert.match(msg || '', /feat-nopr/, 'the unresolved branch must be named');
    const calls = fs.existsSync(callLog) ? fs.readFileSync(callLog, 'utf8') : '';
    assert.ok(!/pr view/.test(calls), 'no resolved PR to verify -- pr view must never be called');
    assert.strictEqual(readHandbackRows(home).length, 0, 'a still-pending claim is not a resolved-PR unresolved incident');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('U8: one pending row whose branch now has a PR -- resolves and verifies exactly as today', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 501: GREEN }, prListByHead: { 'feat-resolves': 501 } });
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-u8-resolves', repo: 'acme/widgets', branch: 'feat-resolves', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-resolves',
      last_assistant_message: 'Should be good.',
    };
    const env = handbackEnv(home, binDir); // shadow (explicit default)
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(systemMessageOf(res), null, 'a resolved claim must not be named as pending');
    assertQuietPassThrough(res);
    const rows = readHandbackRows(home);
    assert.strictEqual(rows.length, 1, 'the newly-resolved PR must go through the same unresolved-PR evaluation as today');
    assert.strictEqual(rows[0].pr, 501);
    assert.strictEqual(rows[0].condition, 'no-tag');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('U8: mixed resolved and pending rows -- resolved PR verified (shadow-logged), pending branch named', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 502: GREEN } }); // 'pending-branch' --head lookup answers []
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-u8-mixed', repo: 'acme/widgets', pr: 502, branch: 'resolved-branch' },
      { session_id: 'sess-u8-mixed', repo: 'acme/widgets', branch: 'pending-branch', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-mixed',
      last_assistant_message: 'Two in flight.',
    };
    const env = handbackEnv(home, binDir); // shadow
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
    const rows = readHandbackRows(home);
    assert.strictEqual(rows.length, 1, 'the resolved PR is verified exactly as today');
    assert.strictEqual(rows[0].pr, 502);
    const msg = systemMessageOf(res);
    assert.match(msg || '', /pending-branch/, 'the still-pending branch must be named');
    assert.ok(!/resolved-branch/.test(msg || ''), 'a resolved branch is not a pending one');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('U8 (supplement): enforce mode, resolved PR blocks AND a sibling pending branch is named in the same output', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, { prStates: { 903: GREEN } });
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-u8-enforce-mixed', repo: 'acme/widgets', pr: 903, branch: 'resolved-branch-2' },
      { session_id: 'sess-u8-enforce-mixed', repo: 'acme/widgets', branch: 'pending-branch-2', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-enforce-mixed',
      last_assistant_message: 'result: ready',
    };
    const env = handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: 'enforce' });
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(decisionOf(res), 'block', 'the resolved-PR path must still block exactly as today');
    assert.match(reasonOf(res) || '', /acme\/widgets[#]903/);
    const msg = systemMessageOf(res);
    assert.match(msg || '', /pending-branch-2/, 'the pending branch must still be named alongside the block');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('U8: two pending rows for different branches -- both named, each exactly once', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  writeFakeGh(binDir, {}); // every --head lookup answers []
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-u8-two', repo: 'acme/widgets', branch: 'branch-one', pending: true, pr: null },
      { session_id: 'sess-u8-two', repo: 'acme/widgets', branch: 'branch-two', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-two',
      last_assistant_message: 'Two claims open.',
    };
    const env = handbackEnv(home, binDir);
    const res = await runHook(HOOK, p, { env });
    const msg = systemMessageOf(res) || '';
    const lines = msg.split('\n').filter(Boolean);
    assert.strictEqual(lines.length, 2, 'one line per pending branch');
    assert.strictEqual((msg.match(/branch-one/g) || []).length, 1, 'branch-one named exactly once');
    assert.strictEqual((msg.match(/branch-two/g) || []).length, 1, 'branch-two named exactly once');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

test('U8 (finding #10): same branch name in two repos -- one repo\'s resolution must not suppress the other repo\'s still-pending claim', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  // No prListByHead entry for 'shared-branch': the fake's --head lookup is
  // keyed on branch name only (it can't see --repo), so if the pending row's
  // own resolvePending() call were ever satisfied by the OTHER repo's PR,
  // this fixture would silently mask that bug. Leaving it unconfigured means
  // the pending row can only stay pending or get wrongly dropped by the
  // repo-blind branch key this test targets -- never wrongly resolved.
  writeFakeGh(binDir, { prStates: { 601: GREEN } });
  try {
    seedSessionPrs(home, [
      // Already resolved (pending:false, pr set) -- acme/widgets' branch.
      { session_id: 'sess-u8-tworepos', repo: 'acme/widgets', pr: 601, branch: 'shared-branch' },
      // Still pending -- a DIFFERENT repo, SAME branch name.
      { session_id: 'sess-u8-tworepos', repo: 'acme/other', branch: 'shared-branch', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-tworepos',
      last_assistant_message: 'Both in flight.',
    };
    const env = handbackEnv(home, binDir); // shadow
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
    const rows = readHandbackRows(home);
    assert.strictEqual(rows.length, 1, 'the resolved acme/widgets PR is verified exactly as today');
    assert.strictEqual(rows[0].repo, 'acme/widgets');
    assert.strictEqual(rows[0].pr, 601);
    const msg = systemMessageOf(res);
    assert.match(msg || '', /shared-branch/, 'the still-pending branch must be named');
    assert.match(msg || '', /acme\/other/, 'the message must name the still-pending repo (acme/other), not the resolved one');
    assert.strictEqual((String(msg).match(/shared-branch/g) || []).length, 1, 'named exactly once, not once per repo sharing the branch name');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir);
  }
});

// #1515: real hook processes and verification commands; only gh is a fixture.
// The former extra-block tests are replaced by initial composition plus quiet
// active retries. Old eligibility files are inert, not repaired or consumed.
function stopCycleFixture(sessionId = 'sess-1515', verifyExit = 1) {
  const home = tmpHome();
  const binDir = mkTmp('vos-1515-bin-');
  const { dir, canary } = project(verifyExit);
  const callLog = path.join(binDir, 'CALLS');
  const ioLog = path.join(binDir, 'STATE-IO');
  const audit = path.join(binDir, 'audit-state.js');
  const stateDir = path.join(home, '.claude', '.stop-gate-state');
  const stateFile = path.join(stateDir, `${sessionId}.json`);
  // Observe actual fs calls, without substituting their results. This detects
  // reads/failed writes too, which an unchanged directory snapshot would miss.
  fs.writeFileSync(audit, `const fs = require('fs');
const append = fs.appendFileSync;
for (const [name, original] of Object.entries(fs)) {
  if (!name.endsWith('Sync') || typeof original !== 'function') continue;
  fs[name] = function (...args) {
    if (args.some(arg => typeof arg === 'string' && arg.startsWith(${JSON.stringify(path.join(home, '.claude') + path.sep)}))) {
      append(${JSON.stringify(ioLog)}, name + ' ' + args[0] + '\\n');
    }
    return original.apply(this, args);
  };
}
`);
  writeFakeGh(binDir, { prStates: { 31: GREEN }, callLog });
  seedSessionPrs(home, [{ session_id: sessionId, repo: 'acme/widgets', pr: 31, branch: 'b' }]);
  const env = handbackEnv(home, binDir, {
    CLAUDE_HANDBACK_MODE: 'enforce', CLAUDE_VERIFY_ON_STOP: '1', CLAUDE_LOOP_GUARD: '0',
    CLAUDE_VERIFY_TIMEOUT_MS: '180000', CLAUDE_HANDBACK_GH_TIMEOUT_MS: '8000',
    NODE_OPTIONS: `--require ${audit}`,
  });
  const stop = (active, payload = {}, extraEnv = {}) => runHook(HOOK, {
    cwd: dir, stop_hook_active: active, session_id: sessionId,
    last_assistant_message: 'All done.', ...payload,
  }, { env: { ...env, ...extraEnv } });
  const lines = (file) => fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n') : [];
  const calls = () => lines(callLog);
  const activity = () => lines(ioLog);
  const cleanup = () => { rmTmp(home); rmTmp(binDir); rmTmp(dir); };
  return { home, binDir, dir, canary, stateDir, stateFile, audit, stop, calls, activity, cleanup };
}

function assertCombined(res) {
  assert.strictEqual(decisionOf(res), 'block');
  assert.match(reasonOf(res), /Verification gate/);
  assert.match(reasonOf(res), /MACHINE GATE/);
  assert.match(reasonOf(res), /acme\/widgets#31/);
}

test('#1515: initial combined block, then every sequential or concurrent active retry is quiet', async () => {
  const f = stopCycleFixture();
  try {
    assertCombined(await f.stop(false));
    assert.ok(fs.existsSync(f.canary), 'verification actually ran');
    assert.strictEqual(f.calls().length, 1, 'handback runs on the initial Stop');
    assert.ok(!fs.existsSync(f.stateDir), 'no new gate state');
    assert.ok(f.activity().length > 0, 'precondition: the I/O observer saw handback reads');
    assert.ok(f.activity().every(line => !line.includes(f.stateDir)), 'no gate-state I/O');
    const activity = f.activity();
    fs.unlinkSync(f.canary);
    for (let i = 0; i < 3; i++) assertQuietPassThrough(await f.stop(true));
    for (const res of await Promise.all(Array.from({ length: 8 }, () => f.stop(true)))) assertQuietPassThrough(res);
    assert.strictEqual(f.calls().length, 1, 'no active-retry GH activity');
    assert.deepStrictEqual(f.activity(), activity, 'no active-retry state reads or writes');
    assert.ok(!fs.existsSync(f.canary), 'no active-retry verification');
  } finally { f.cleanup(); }
});

test('#1515: prior eligibility, corrupt/expired records and inaccessible storage are irrelevant', async (t) => {
  for (const shape of ['eligible', 'expired', 'corrupt', 'held-lock', 'not-directory', 'directory-record']) {
    await t.test(shape, async () => {
      const f = stopCycleFixture();
      try {
        if (shape === 'not-directory') fs.writeFileSync(f.stateDir, 'not a directory');
        else {
          fs.mkdirSync(f.stateDir);
          if (shape === 'directory-record') fs.mkdirSync(f.stateFile);
          else fs.writeFileSync(f.stateFile, shape === 'corrupt' ? '{broken' : JSON.stringify({
            lastBlock: 'verify', ts: Date.now() - (shape === 'expired' ? 25 * 60 * 60 * 1000 : 0),
          }));
          if (shape === 'held-lock') {
            const lock = path.join(f.stateDir, '.sess-1515.lock');
            fs.mkdirSync(lock);
            fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify({ pid: process.pid, token: 'test-owner' }));
          }
        }
        assertQuietPassThrough(await f.stop(true));
        assert.deepStrictEqual(f.calls(), []);
        assert.deepStrictEqual(f.activity(), [], 'active Stop must not even read stale state');
        assert.ok(!fs.existsSync(f.canary));
        assertCombined(await f.stop(false));
        assert.ok(f.activity().every(line => !line.includes(f.stateDir)), 'initial Stop also ignores old storage');
      } finally { f.cleanup(); }
    });
  }
});

test('#1515: EISDIR reset obstruction followed by recovery cannot revive prior eligibility', async () => {
  const f = stopCycleFixture();
  try {
    fs.mkdirSync(f.stateDir);
    const old = JSON.stringify({ lastBlock: 'verify', ts: Date.now() });
    fs.writeFileSync(f.stateFile, old);
    const shim = path.join(f.binDir, 'obstruct-reset.js');
    fs.writeFileSync(shim, `require('fs').mkdirSync(${JSON.stringify(f.stateFile)} + '.' + process.pid + '.tmp');\n`);
    seedSessionPrs(f.home, []);
    // A fresh cycle whose verifier setup throws used to leave the old record
    // eligible when reset failed. Obstruct the real PID-specific write path.
    assertQuietPassThrough(await f.stop(false, { cwd: { invalid: true } }, {
      NODE_OPTIONS: `--require ${shim} --require ${f.audit}`,
    }));
    assert.ok(fs.readdirSync(f.stateDir).some(name => name.endsWith('.tmp')), 'EISDIR obstruction exists');
    seedSessionPrs(f.home, [{ session_id: 'sess-1515', repo: 'acme/widgets', pr: 31, branch: 'b' }]);
    const activity = f.activity();
    for (let i = 0; i < 3; i++) assertQuietPassThrough(await f.stop(true));
    assert.deepStrictEqual(f.calls(), [], 'storage recovery does not permit a deferred handback');
    assert.deepStrictEqual(f.activity(), activity);
    assert.strictEqual(fs.readFileSync(f.stateFile, 'utf8'), old, 'old eligibility remains untouched and inert');
    assert.ok(!fs.existsSync(f.canary));
  } finally { f.cleanup(); }
});

test('#1515: each fresh false Stop evaluates verification and handback anew', async () => {
  const f = stopCycleFixture();
  try {
    for (let i = 0; i < 2; i++) {
      assertCombined(await f.stop(false));
      assert.ok(fs.existsSync(f.canary));
      fs.unlinkSync(f.canary);
      assertQuietPassThrough(await f.stop(true));
      assert.ok(!fs.existsSync(f.canary));
      assert.strictEqual(f.calls().length, i + 1);
    }
    assert.ok(!fs.existsSync(f.stateDir));
  } finally { f.cleanup(); }
});

test('#1515: pass, untrusted skip, no command and missing dependencies still evaluate handback', async (t) => {
  for (const kind of ['pass', 'untrusted', 'no-command', 'missing-deps']) await t.test(kind, async () => {
    const f = stopCycleFixture('sess-1515', 0);
    try {
      if (kind === 'no-command') fs.unlinkSync(path.join(f.dir, '.claude', 'verify.sh'));
      if (kind === 'missing-deps') {
        fs.writeFileSync(path.join(f.dir, 'package.json'), '{}');
        fs.writeFileSync(path.join(f.dir, 'pnpm-lock.yaml'), '');
      }
      const res = await f.stop(false, {}, kind === 'untrusted' ? { CLAUDE_VERIFY_ON_STOP: '0' } : {});
      assert.strictEqual(decisionOf(res), 'block');
      assert.match(reasonOf(res), /acme\/widgets#31/);
      if (kind === 'missing-deps') assert.match(reasonOf(res), /dependencies were never installed[\s\S]*pnpm install/);
      else assert.doesNotMatch(reasonOf(res), /Verification gate/);
      assert.strictEqual(fs.existsSync(f.canary), kind === 'pass');
      assert.strictEqual(f.calls().length, 1);
      assertQuietPassThrough(await f.stop(true));
      assert.strictEqual(f.calls().length, 1);
    } finally { f.cleanup(); }
  });
});

test('#1515 planted negative: passing verify with no session PR stops without creating state', async () => {
  const f = stopCycleFixture('sess-1515-clean', 0);
  try {
    seedSessionPrs(f.home, []);
    assertQuietPassThrough(await f.stop(false));
    assert.ok(fs.existsSync(f.canary), 'precondition: verification ran and passed');
    assert.deepStrictEqual(f.calls(), []);
    assert.ok(!fs.existsSync(f.stateDir));
  } finally { f.cleanup(); }
});

test('#1515: shadow evaluates/logs alongside verify; off makes no GH calls; neither adds a block', async (t) => {
  for (const mode of ['shadow', 'off']) for (const code of [0, 1]) await t.test(`${mode}, verify ${code}`, async () => {
    const f = stopCycleFixture('sess-1515', code);
    try {
      const res = await f.stop(false, {}, { CLAUDE_HANDBACK_MODE: mode });
      if (code) {
        assert.strictEqual(decisionOf(res), 'block');
        assert.match(reasonOf(res), /Verification gate FAILED/);
        assert.doesNotMatch(reasonOf(res), /MACHINE GATE/);
      } else assertQuietPassThrough(res);
      assert.strictEqual(f.calls().length, mode === 'off' ? 0 : 1);
      assert.strictEqual(readHandbackRows(f.home).length, mode === 'off' ? 0 : 1);
      const activity = f.activity();
      assertQuietPassThrough(await f.stop(true)); // switching to enforce must not retry
      assert.deepStrictEqual(f.activity(), activity);
      assert.strictEqual(f.calls().length, mode === 'off' ? 0 : 1);
    } finally { f.cleanup(); }
  });
});

test('#1515: pending systemMessage survives verification and enforced/shadow handback composition', async (t) => {
  for (const mode of ['enforce', 'shadow']) for (const hasPr of [false, true]) await t.test(`${mode}, PR ${hasPr}`, async () => {
    const f = stopCycleFixture();
    try {
      seedSessionPrs(f.home, [
        ...(hasPr ? [{ session_id: 'sess-1515', repo: 'acme/widgets', pr: 31, branch: 'b' }] : []),
        { session_id: 'sess-1515', repo: 'acme/widgets', pr: null, pending: true, branch: 'feat-pending' },
      ]);
      const res = await f.stop(false, {}, { CLAUDE_HANDBACK_MODE: mode });
      assert.strictEqual(decisionOf(res), 'block');
      assert.match(reasonOf(res), /Verification gate FAILED/);
      assert.match(systemMessageOf(res), /feat-pending/);
      if (hasPr && mode === 'enforce') assertCombined(res);
      else assert.doesNotMatch(reasonOf(res), /MACHINE GATE/);
      assert.strictEqual(readHandbackRows(f.home).length, hasPr && mode === 'shadow' ? 1 : 0);
      assertQuietPassThrough(await f.stop(true));
    } finally { f.cleanup(); }
  });
});

test('#1515: unknown/error handback and a real handback exception cannot erase verification failure', async (t) => {
  for (const kind of ['unknown', 'gh-error', 'exception']) await t.test(kind, async () => {
    const f = stopCycleFixture();
    try {
      if (kind === 'exception') {
        assert.throws(() => String({ toString: null }), TypeError);
        seedSessionPrs(f.home, [
          { session_id: 'sess-1515', repo: 'acme/widgets', pr: 31, branch: 'b' },
          { session_id: 'sess-1515', repo: 'acme/widgets', pr: null, pending: true, branch: { toString: null } },
        ]);
      } else writeFakeGh(f.binDir, {
        prStates: kind === 'unknown' ? { 31: {} } : {}, callLog: path.join(f.binDir, 'CALLS'),
      });
      const res = await f.stop(false);
      assert.strictEqual(decisionOf(res), 'block');
      assert.match(reasonOf(res), /Verification gate FAILED/);
      assert.doesNotMatch(reasonOf(res), /MACHINE GATE/);
      assert.strictEqual(f.calls().length, kind === 'exception' ? 0 : 1);
      assert.strictEqual(readHandbackRows(f.home).length, 0, 'inconclusive is not an unresolved incident');
      const activity = f.activity();
      assertQuietPassThrough(await f.stop(true));
      assert.deepStrictEqual(f.activity(), activity);
    } finally { f.cleanup(); }
  });
});

test('#1515: unexpected verification setup failure preserves handback block and pending output', async () => {
  const f = stopCycleFixture();
  try {
    seedSessionPrs(f.home, [
      { session_id: 'sess-1515', repo: 'acme/widgets', pr: 31, branch: 'b' },
      { session_id: 'sess-1515', repo: 'acme/widgets', pr: null, pending: true, branch: 'feat-pending' },
    ]);
    const res = await f.stop(false, { cwd: { invalid: true } });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /acme\/widgets#31/);
    assert.doesNotMatch(reasonOf(res), /Verification gate/);
    assert.match(systemMessageOf(res), /feat-pending/);
    assert.ok(!fs.existsSync(f.canary), 'verifier setup failed before command execution');
    assert.strictEqual(f.calls().length, 2, 'pending branch lookup and PR evaluation both ran');
    assertQuietPassThrough(await f.stop(true));
    assert.strictEqual(f.calls().length, 2);
  } finally { f.cleanup(); }
});

test('#1515: clipping retains first 1500 and last 1000 characters plus the explicit marker', async (t) => {
  for (const size of [2499, 2500, 2501, 6000]) await t.test(String(size), async () => {
    const f = stopCycleFixture();
    try {
      const out = 'FIRST-ERROR:' + 'x'.repeat(size - 23) + ':LAST-ERROR';
      assert.strictEqual(out.length, size);
      fs.writeFileSync(path.join(f.dir, 'diagnostics.txt'), out);
      fs.writeFileSync(path.join(f.dir, '.claude', 'verify.sh'), 'cat diagnostics.txt\nexit 1\n');
      const res = await f.stop(false, {}, { CLAUDE_HANDBACK_MODE: 'off' });
      assert.strictEqual(decisionOf(res), 'block');
      const captured = reasonOf(res).split('\n\n--- output ---\n')[1];
      if (size <= 2500) {
        assert.strictEqual(captured, out, 'short output is unchanged');
      } else {
        const marker = size === 2501 ? '\n…[1 chars elided]…\n' : '\n…[3500 chars elided]…\n';
        assert.strictEqual(captured, out.slice(0, 1500) + marker + out.slice(-1000));
        assert.strictEqual(captured.length, size === 2501 ? 2520 : 2523, '2500 retained characters PLUS marker');
      }
    } finally { f.cleanup(); }
  });
});

test('U8 (error path): resolvePending() throws -- the hook still fails open and still names the pending branch', async () => {
  const home = tmpHome();
  const cwd = mkTmp('vos-handback-cwd-');
  const binDir = mkTmp('vos-handback-bin-');
  const shimDir = mkTmp('vos-handback-shim-');
  writeFakeGh(binDir, {});
  const shim = writeResolvePendingThrowShim(shimDir);
  try {
    seedSessionPrs(home, [
      { session_id: 'sess-u8-throw', repo: 'acme/widgets', branch: 'feat-throw', pending: true, pr: null },
    ]);
    const p = {
      cwd, stop_hook_active: false, session_id: 'sess-u8-throw',
      last_assistant_message: 'Still working.',
    };
    const env = handbackEnv(home, binDir, { NODE_OPTIONS: `--require ${shim}` });
    const res = await runHook(HOOK, p, { env });
    assert.strictEqual(res.code, 0, 'a throwing resolvePending() must never crash the Stop hook (fail open)');
    const msg = systemMessageOf(res);
    assert.match(msg || '', /feat-throw/, 'the pending branch must still be named even though resolution itself failed');
  } finally {
    rmTmp(home); rmTmp(cwd); rmTmp(binDir); rmTmp(shimDir);
  }
});

// U6 fixtures: these records and command shims prove hook behavior, not live
// ownership. Every systemctl/gh invocation stays inside the fixture PATH.
function seedOwner(home, patch = {}, heartbeat = { phase: 'ci', deadline: Math.floor(Date.now() / 1000) + 3600 }) {
  const dir = path.join(home, '.claude', '.loop-state', 'pr-owner', 'acme--widgets--301');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'owner.json');
  fs.writeFileSync(file, JSON.stringify({
    schema: 'pr-owner/v1', repo: 'acme/widgets', pr: 301, state: 'owned',
    head: 'current-head', unit: 'pr-owner-acme--widgets--301', ...patch,
  }));
  if (heartbeat !== null) fs.writeFileSync(path.join(dir, 'heartbeat.json'), JSON.stringify(heartbeat));
  return file;
}

function writeFakeSystemctl(binDir, { output = 'active', code = 0, sleepMs = 0 } = {}) {
  const file = path.join(binDir, 'systemctl');
  fs.writeFileSync(file, `#!/usr/bin/env bash
[ "$*" = '--user is-active pr-owner-acme--widgets--301' ] || exit 99
${sleepMs ? `sleep ${sleepMs / 1000}` : ''}
printf '%s\\n' ${shQuote(output)}
exit ${code}
`);
  fs.chmodSync(file, 0o755);
}

async function ownerFixture(fn, { prState = GREEN, owner = {}, heartbeat, systemctl = {}, gh = {} } = {}) {
  const home = tmpHome();
  const cwd = mkTmp('vos-owner-cwd-');
  const binDir = mkTmp('vos-owner-bin-');
  try {
    const ownerFile = seedOwner(home, owner, heartbeat);
    seedSessionPrs(home, [{ session_id: 'sess-owner', repo: 'Acme/Widgets', pr: 301, branch: 'b' }]);
    writeFakeGh(binDir, { prStates: { 301: { ...prState, headRefOid: 'current-head' } }, ...gh });
    writeFakeSystemctl(binDir, systemctl);
    const input = { cwd, session_id: 'sess-owner', stop_hook_active: false, last_assistant_message: 'result: handed off' };
    const call = (mode = 'shadow', extra = {}, patch = {}) => runHook(HOOK, { ...input, ...patch }, {
      env: handbackEnv(home, binDir, { CLAUDE_HANDBACK_MODE: mode, ...extra }),
    });
    await fn({ home, binDir, ownerFile, call });
  } finally { rmTmp(home); rmTmp(cwd); rmTmp(binDir); }
}

for (const [name, prState] of Object.entries({
  green: GREEN, pending: PENDING,
  failing: { ...GREEN, statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'FAILURE' }] },
  draft: { ...GREEN, isDraft: true },
})) {
  test(`U6 live owned current head resolves as handed-off before ${name} classification`, async () => {
    await ownerFixture(async ({ home, call }) => {
      assertQuietPassThrough(await call('enforce'));
      assertQuietPassThrough(await call());
      const rows = readHandbackRows(home);
      assert.strictEqual(rows.length, 1);
      assert.strictEqual(rows[0].condition, 'handed-off');
      assert.strictEqual(rows[0].status, 'resolved');
    }, { prState });
  });
}

test('U6 AE6 inactive owner falls through to result-invalid and blocks only the initial Stop', async () => {
  await ownerFixture(async ({ home, call }) => {
    const blocked = await call('enforce');
    assert.strictEqual(decisionOf(blocked), 'block');
    assert.match(reasonOf(blocked), /needs-human\.sh/);
    assert.doesNotMatch(reasonOf(blocked), /pr-handoff|live owner/);
    assertQuietPassThrough(await call('enforce', {}, { stop_hook_active: true }));
    assert.strictEqual(readHandbackRows(home).length, 0);
    assertQuietPassThrough(await call());
    assert.strictEqual(readHandbackRows(home)[0].condition, 'result-invalid');
  }, { systemctl: { output: 'inactive', code: 3 } });
});

for (const [name, owner] of Object.entries({ 'stale head': { head: 'old-head' }, 'parked record': { state: 'parked' } })) {
  test(`U6 ${name} never resolves as handed-off`, async () => {
    await ownerFixture(async ({ home, call }) => {
      assert.strictEqual(decisionOf(await call('enforce')), 'block');
      assertQuietPassThrough(await call());
      assert.strictEqual(readHandbackRows(home)[0].condition, 'result-invalid');
    }, { owner });
  });
}

for (const [name, options, timeout, read] of [
  ['systemctl failure', { systemctl: { output: '', code: 1 } }, {}, /systemctl/],
  ['systemctl timeout', { systemctl: { sleepMs: 400 } }, { CLAUDE_HANDBACK_GH_TIMEOUT_MS: '150' }, /systemctl.*ETIMEDOUT/],
  ['gh failure', { gh: { exitCode: 1 } }, {}, /PR head/],
  ['gh timeout', { gh: { sleepMs: 400 } }, { CLAUDE_HANDBACK_GH_TIMEOUT_MS: '150' }, /PR head.*ETIMEDOUT/],
  ['missing head', { gh: { prStates: { 301: GREEN } } }, {}, /PR head/],
]) {
  test(`U6 ${name} is inconclusive in shadow and blocks a handed-off result in enforce`, async () => {
    await ownerFixture(async ({ home, call }) => {
      assertQuietPassThrough(await call('shadow', timeout));
      const rows = readHandbackRows(home);
      assert.strictEqual(rows.length, 1);
      assert.strictEqual(rows[0].status, 'inconclusive');
      assert.strictEqual(rows[0].condition, 'inconclusive');
      assert.match(rows[0].readFailure, read);
      const result = await call('enforce', timeout);
      assert.strictEqual(decisionOf(result), 'block');
      assert.match(reasonOf(result), read);
    }, options);
  });
}

// A handed-off PR stays draft or pending until its owner finishes, so a dead
// or stale owner must not let a result claim pass as out of scope there.
for (const [name, prState] of Object.entries({
  draft: { ...GREEN, isDraft: true },
  pending: PENDING,
  failing: { ...GREEN, statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'FAILURE' }] },
})) {
  for (const [why, options] of Object.entries({
    'inactive unit': { systemctl: { output: 'inactive', code: 3 } },
    'expired heartbeat': { heartbeat: { phase: 'ci', deadline: Math.floor(Date.now() / 1000) - 60 } },
    'stale head': { owner: { head: 'old-head' } },
  })) {
    test(`U6 ${why} on a ${name} PR blocks a handed-off result claim`, async () => {
      await ownerFixture(async ({ home, call }) => {
        assert.strictEqual(decisionOf(await call('enforce')), 'block');
        assertQuietPassThrough(await call());
        assert.strictEqual(readHandbackRows(home)[0].condition, 'handoff-not-live');
      }, { prState, ...options });
    });
  }
  test(`U6 dead owner on a ${name} PR leaves a non-result stop alone`, async () => {
    await ownerFixture(async ({ call }) => {
      assertQuietPassThrough(await call('enforce', {}, { last_assistant_message: 'Still working on the fix.' }));
    }, { prState, systemctl: { output: 'inactive', code: 3 } });
  });
}

// systemd unloads a collected owner unit once it ends, so is-active on a dead
// owner exits 4 ("no such unit") while still printing inactive.
test('U6 collected dead owner (is-active exit 4) falls through to result-invalid', async () => {
  await ownerFixture(async ({ home, call }) => {
    assert.strictEqual(decisionOf(await call('enforce')), 'block');
    assertQuietPassThrough(await call());
    const rows = readHandbackRows(home);
    assert.strictEqual(rows[0].condition, 'result-invalid');
    assert.strictEqual(rows[0].readFailure, undefined);
  }, { systemctl: { output: 'inactive', code: 4 } });
});

// A wedged owner keeps its unit active but stops renewing its deadline, so an
// active unit at the current head is still not a live owner on its own.
for (const [name, heartbeat] of Object.entries({
  'expired heartbeat': { phase: 'ci', deadline: Math.floor(Date.now() / 1000) - 60 },
  'missing heartbeat': null,
})) {
  test(`U6 active unit with ${name} never resolves as handed-off`, async () => {
    await ownerFixture(async ({ home, call }) => {
      assert.strictEqual(decisionOf(await call('enforce')), 'block');
      assertQuietPassThrough(await call());
      assert.strictEqual(readHandbackRows(home)[0].condition, 'result-invalid');
    }, { heartbeat });
  });
}

test('U6 invalid heartbeat deadline is inconclusive and blocks a handed-off result in enforce', async () => {
  await ownerFixture(async ({ home, call }) => {
    assertQuietPassThrough(await call());
    const rows = readHandbackRows(home);
    assert.strictEqual(rows[0].status, 'inconclusive');
    assert.match(rows[0].readFailure, /heartbeat/);
    assert.strictEqual(decisionOf(await call('enforce')), 'block');
  }, { heartbeat: { phase: 'ci', deadline: 'soon' } });
});

for (const kind of ['invalid JSON', 'unreadable record']) {
  test(`U6 ${kind} read propagates as inconclusive`, async () => {
    await ownerFixture(async ({ ownerFile, home, call }) => {
      fs.unlinkSync(ownerFile);
      if (kind === 'invalid JSON') fs.writeFileSync(ownerFile, '{invalid');
      else fs.mkdirSync(ownerFile); // EISDIR, deterministic without a permission probe
      assertQuietPassThrough(await call());
      assert.strictEqual(readHandbackRows(home)[0].status, 'inconclusive');
      assert.match(readHandbackRows(home)[0].readFailure, /owner record/);
      const blocked = await call('enforce');
      assert.strictEqual(decisionOf(blocked), 'block');
      assert.match(reasonOf(blocked), /owner record/);
    });
  });
}

test('U6 no owner record keeps green result-invalid and pending pass-through behavior', async () => {
  for (const prState of [GREEN, PENDING]) {
    await ownerFixture(async ({ ownerFile, home, call, binDir }) => {
      fs.unlinkSync(ownerFile);
      // Any systemctl read would fail: no-record behavior must not depend on it.
      writeFakeSystemctl(binDir, { output: '', code: 99 });
      const result = await call('enforce');
      if (prState === GREEN) assert.strictEqual(decisionOf(result), 'block');
      else assertQuietPassThrough(result);
      assertQuietPassThrough(await call());
      assert.strictEqual(readHandbackRows(home).length, prState === GREEN ? 1 : 0);
    }, { prState });
  }
});

// dotfiles#1598: the rollup holds every run a head ever had; classification must read only
// the newest tested run per workflow. 'green' is observable as a result-invalid row (a
// "result:" claim on a gate-green unmerged PR); any other class logs another condition or none.
const RUN = (id) => `https://github.com/acme/widgets/actions/runs/${id}/job/1`;
const CR = (workflowName, name, conclusion, runId, status = 'COMPLETED') => ({
  __typename: 'CheckRun', workflowName, name, status, conclusion, detailsUrl: RUN(runId),
});
const SHARDS = ['Harness suites (core)', 'Harness suites (language + pro-gate candidates)'];
const GREEN_ROW = 'result-invalid';

async function classifyViaHook(prState) {
  const home = tmpHome();
  const cwd = mkTmp('vos-rollup-cwd-');
  const binDir = mkTmp('vos-rollup-bin-');
  try {
    writeFakeGh(binDir, { prStates: { 41: { ...GREEN, ...prState } } });
    seedSessionPrs(home, [{ session_id: 'sess-rollup', repo: 'acme/widgets', pr: 41, branch: 'b' }]);
    assertQuietPassThrough(await runHook(HOOK, {
      cwd, stop_hook_active: false, session_id: 'sess-rollup', last_assistant_message: 'result: done',
    }, { env: handbackEnv(home, binDir, { CLAUDE_VERIFY_TRUSTED_ROOTS: '/nonexistent' }) }));
    const rows = readHandbackRows(home);
    return rows.length ? rows[0].condition : 'no-row';
  } finally { rmTmp(home); rmTmp(cwd); rmTmp(binDir); }
}

test('rollup: an older skipped run of a workflow does not hide the newer run, which is green', async () => {
  assert.strictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('Harness', 'Harness suites (core)', 'SKIPPED', 100),
    CR('Harness', 'Harness suites (core)', 'SUCCESS', 200),
    CR('Harness', 'Harness suites', 'SUCCESS', 200),
  ] }), GREEN_ROW);
});

test('rollup: a draft run (failed aggregate, skipped shards) beside a green ready run is green', async () => {
  assert.strictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('Harness', 'Harness suites (draft)', 'FAILURE', 100),
    ...SHARDS.map((n) => CR('Harness', n, 'SKIPPED', 100)),
    CR('Harness', 'Harness suites', 'SUCCESS', 200),
    ...SHARDS.map((n) => CR('Harness', n, 'SUCCESS', 200)),
  ] }), GREEN_ROW);
});

test('rollup planted negative: the same draft run beside a ready run whose aggregate FAILED is not green', async () => {
  assert.notStrictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('Harness', 'Harness suites (draft)', 'FAILURE', 100),
    ...SHARDS.map((n) => CR('Harness', n, 'SKIPPED', 100)),
    CR('Harness', 'Harness suites', 'FAILURE', 200),
    ...SHARDS.map((n) => CR('Harness', n, 'SUCCESS', 200)),
  ] }), GREEN_ROW);
});

test('rollup: a newer skip-only run does not supersede an older green run', async () => {
  assert.strictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('Harness', 'Harness suites', 'SUCCESS', 100),
    CR('Harness', 'Harness suites (core)', 'SKIPPED', 200),
  ] }), GREEN_ROW);
});

test('rollup: an older red run superseded by a newer green run of the same workflow is green', async () => {
  assert.strictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('Harness', 'Harness suites', 'FAILURE', 100),
    CR('Harness', 'Harness suites', 'SUCCESS', 200),
  ] }), GREEN_ROW);
});

test('rollup: a StatusContext entry with no detailsUrl is kept and its FAILURE still fails', async () => {
  assert.notStrictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('Harness', 'Harness suites', 'SUCCESS', 200),
    { __typename: 'StatusContext', context: 'ci/legacy', state: 'FAILURE' },
  ] }), GREEN_ROW);
});

test('rollup: two different workflows each keep their own newest run', async () => {
  // B's newest run (150) is red even though A's newest (200) is higher: runs are not compared across workflows.
  assert.notStrictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('A', 'a', 'FAILURE', 100), CR('A', 'a', 'SUCCESS', 200),
    CR('B', 'b', 'FAILURE', 150),
  ] }), GREEN_ROW);
  assert.strictEqual(await classifyViaHook({ statusCheckRollup: [
    CR('A', 'a', 'FAILURE', 100), CR('A', 'a', 'SUCCESS', 200),
    CR('B', 'b', 'FAILURE', 120), CR('B', 'b', 'SUCCESS', 150),
  ] }), GREEN_ROW);
});

test('rollup: a draft PR is classified draft before any rollup evaluation', async () => {
  assert.notStrictEqual(await classifyViaHook({ isDraft: true, statusCheckRollup: [
    CR('Harness', 'Harness suites', 'SUCCESS', 200),
  ] }), GREEN_ROW);
});
