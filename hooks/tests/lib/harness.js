'use strict';
/**
 * Tiny, zero-dependency test harness for the Claude Code hooks.
 *
 * Everything runs through Node's built-in `node:test` runner. Hooks are
 * exercised BLACK-BOX where possible: spawn `node <hook>`, feed a JSON payload
 * on stdin, and assert on {exit code, stdout, stderr} — exactly how Claude Code
 * invokes them. Pure-logic libs (hook-flags, resolve-formatter, package-manager)
 * are require()d in-process for speed.
 *
 * Hermeticity: tests neutralize every env var that changes hook behavior
 * (profiles, disables, package-manager, git escapes, plugin root) so a runner's
 * own environment can't leak in, and every spawn defaults HOME/USERPROFILE to
 * one per-process throwaway directory (removed at exit) so hooks that write
 * under $HOME — loop-guard state, papercut denial records, package-manager
 * global config — land in a sandbox, never the live store. Node's os.homedir()
 * honors $HOME on POSIX. A test that needs a specific home passes its own
 * env.HOME, which wins over the default.
 */

const { spawn } = require('node:child_process');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// tests/lib/harness.js  ->  ../../ = the hooks root
const HOOKS_DIR = path.resolve(__dirname, '..', '..');

// Env vars that alter hook behavior — cleared before each spawn so tests are
// hermetic against whatever environment invoked the suite.
const NEUTRALIZE = [
  // The hook now resolves its store from PAPERCUT_STORE (parity with
  // papercut.py:68). Without neutralizing it here, a developer who has the
  // variable set would have every hook test append to their REAL papercut
  // store -- the same live-store pollution the sandboxed HOME fixed.
  'PAPERCUT_STORE',
  'HOOK_DISABLED',
  'CLAUDE_LOOP_GUARD',
  'CLAUDE_LOOP_MAX',
  'CLAUDE_LOOP_MAX_MS',
  'CLAUDE_LOOP_STOP_MARKER',
  'CLAUDE_FANOUT_GATE_BLOCK',
  'CLAUDE_FANOUT_TASK_THRESHOLD',
  'CLAUDE_FANOUT_TASK_WINDOW_MS',
  'CLAUDE_PACKAGE_MANAGER',
  'ALLOW_DESTRUCTIVE_GIT',
  'ALLOW_MAIN_COMMIT',
  'CLAUDE_PLUGIN_ROOT',
  'CLAUDE_VERIFY_ON_STOP',
  'CLAUDE_VERIFY_TRUSTED_ROOTS',
  'CLAUDE_VERIFY_CMD',
  'WORKTREE_CLAIM_DEDUP',
  'CLAUDE_HEAVY_JOB_TEST_MODE',
  'CLAUDE_HEAVY_JOB_TEST_PROC_ROOT',
  'CLAUDE_HEAVY_JOB_TEST_RUNTIME_DIR',
  'CLAUDE_HEAVY_JOB_TEST_LOCK_PATH',
  'CLAUDE_HEAVY_JOB_TEST_MIN_AVAILABLE_BYTES',
  'CLAUDE_HEAVY_JOB_TEST_MIN_AVAILABLE_PERCENT',
  'CLAUDE_HEAVY_JOB_TEST_MIN_COMBINED_BYTES',
  'CLAUDE_HEAVY_JOB_TEST_MIN_COMBINED_PERCENT',
  'CLAUDE_HEAVY_JOB_TEST_MAX_PSI_FULL_AVG10',
  'CLAUDE_HEAVY_JOB_TEST_MAX_PSI_SOME_AVG10',
  'CLAUDE_CODE_TOOL_MEMORY_LIMIT',
  'WACLI_GUARD_TEST_MODE',
  'WACLI_GUARD_TEST_ROOT',
  'WACLI_GUARD_TEST_SHA256',
  'WACLI_READONLY',
  'WACLI_STORE_DIR',
  // codex-quota-guard / codex-pick resolve auth, the catalog cache, caam
  // profiles, and the API-key lane from these; a developer's live values must
  // not turn a fixture run into a real usage fetch or an API-key rewrite.
  'CODEX_HOME',
  'OPENAI_API_KEY',
  'XDG_DATA_HOME',
  'CODEX_PICK_USAGE_FIXTURE',
  'CODEX_PICK_CATALOG_FIXTURE',
  'CODEX_PICK_ACCOUNTS',
  'CODEX_PICK_API_LANE',
  'CODEX_PICK_CCFLARE_FIXTURE',
  'CLAUDE_HOME',
  // SessionStart's workspace-trust seed (lib/workspace-trust.js) writes the
  // global config these locate; a runner's live values must not point a
  // fixture's repositories at the real ~/.claude.json.
  'CLAUDE_CONFIG_DIR',
  'CLAUDE_CODE_CUSTOM_OAUTH_URL',
];

// One throwaway home per test process, shared by every spawn AND by the test
// process itself: expected-denial tests exercise real guards, and a real
// denial appends a real papercut record under os.homedir() — with the
// runner's HOME that polluted the LIVE store (issue #526). Redirect, never
// suppress: the logging path stays exercised, its writes just land here.
let sandboxHome = null;
function testHome() {
  if (!sandboxHome) {
    sandboxHome = fs.mkdtempSync(path.join(os.tmpdir(), 'hooktest-home-'));
    process.on('exit', () => rmTmp(sandboxHome));
  }
  return sandboxHome;
}

// Deliberate require-time side effect: sandbox THIS process too. Some tests
// require a hook and call run() in-process — no spawn, no buildEnv — so their
// denial writes use the test process's own HOME (how codex-quota-guard's
// fixtures reached the live store). os.homedir() honors $HOME on POSIX and
// USERPROFILE on Windows, both at call time, so re-pointing them here covers
// every later in-process homedir lookup and any raw {...process.env} spawn.
process.env.HOME = testHome();
process.env.USERPROFILE = testHome();

// Same leak class for the filesystem root: the SessionStart hook's stray-.git
// heal (lib/stray-dot-git.js) scans and RENAMES entries under the host's real
// / and /tmp. Every test scans an empty sandbox root instead; a test planting
// .git shapes passes its own STRAY_DOT_GIT_FS_ROOT, which wins.
let sandboxFsRoot = null;
function testFsRoot() {
  if (!sandboxFsRoot) {
    sandboxFsRoot = path.join(testHome(), 'fs-root');
    fs.mkdirSync(sandboxFsRoot, { recursive: true });
  }
  return sandboxFsRoot;
}
process.env.STRAY_DOT_GIT_FS_ROOT = testFsRoot();

function buildEnv(overrides = {}) {
  const env = { ...process.env };
  for (const k of NEUTRALIZE) delete env[k];
  env.HOOK_PROFILE = 'standard'; // deterministic default; override explicitly if needed
  env.HOME = testHome();
  env.USERPROFILE = testHome(); // os.homedir() on Windows
  env.STRAY_DOT_GIT_FS_ROOT = testFsRoot();
  return { ...env, ...overrides };
}

/**
 * Spawn `node <script> [argv...]`, feed `stdin`, resolve with the result.
 * Never rejects — a spawn error resolves as {code:-1, stderr}.
 */
function spawnNode(scriptRel, { argv = [], stdin = '', env = {}, cwd } = {}) {
  const scriptAbs = path.isAbsolute(scriptRel) ? scriptRel : path.join(HOOKS_DIR, scriptRel);
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [scriptAbs, ...argv], {
      cwd: cwd || HOOKS_DIR,
      env: buildEnv(env),
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
    child.on('error', (e) => resolve({ code: -1, stdout, stderr: String((e && e.stack) || e) }));
    child.stdin.end(stdin);
  });
}

/** Run a hook directly, feeding a JSON payload (object → stringified, or raw string). */
function runHook(scriptRel, payload, opts = {}) {
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  return spawnNode(scriptRel, { ...opts, stdin });
}

/** Run a hook THROUGH the run-with-flags dispatcher (hookId, relScript, profilesCsv). */
function runViaFlags(hookId, relScript, profilesCsv, payload, opts = {}) {
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  return spawnNode('run-with-flags.js', { ...opts, argv: [hookId, relScript, profilesCsv], stdin });
}

// Matches the way a dangling require / missing import surfaces at runtime.
const MODULE_ERROR_RE = /MODULE_NOT_FOUND|Cannot find module|ModuleNotFoundError|ImportError|No module named/;

/**
 * Parse a hook's stdout and return its normalized decision, or null.
 * PreToolUse now emits hookSpecificOutput.permissionDecision ('deny'/'allow'/'ask');
 * Stop/PostToolUse still emit a top-level `decision` ('block'/'approve'). Normalize
 * the PreToolUse form back to block/approve so assertions stay schema-agnostic.
 */
function decisionOf(res) {
  try {
    const out = JSON.parse(res.stdout);
    const pd = out.hookSpecificOutput && out.hookSpecificOutput.permissionDecision;
    if (pd) return pd === 'deny' ? 'block' : pd === 'approve' || pd === 'allow' ? 'approve' : pd;
    return out.decision || null;
  } catch {
    return null;
  }
}

/** Parse a hook's stdout and return its human-readable reason, or null (schema-agnostic). */
function reasonOf(res) {
  try {
    const out = JSON.parse(res.stdout);
    return (out.hookSpecificOutput && out.hookSpecificOutput.permissionDecisionReason) || out.reason || null;
  } catch {
    return null;
  }
}

/**
 * Assert a PreToolUse hook blocked via the CURRENT schema
 * (hookSpecificOutput.permissionDecision='deny'), and did NOT fall back to the
 * deprecated top-level {decision:'block'} form. Locks the schema migration —
 * decisionOf() intentionally accepts both, so this is what proves the new wire.
 */
function assertPreToolUseDeny(res) {
  const out = JSON.parse(res.stdout);
  assert.ok(out.hookSpecificOutput, 'expected hookSpecificOutput (current PreToolUse schema)');
  assert.strictEqual(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, 'deny');
  assert.ok(out.hookSpecificOutput.permissionDecisionReason, 'expected permissionDecisionReason');
  assert.strictEqual(out.decision, undefined, 'must not emit the deprecated top-level decision field');
}

/**
 * Assert a PreToolUse hook AUTO-APPROVED via the current schema
 * (hookSpecificOutput.permissionDecision='allow'), not the deprecated top-level
 * {decision:'approve'} form. The symmetric partner to assertPreToolUseDeny — use
 * it to lock the migrated allow-path (escape hatches / documented recovery).
 */
function assertPreToolUseAllow(res) {
  const out = JSON.parse(res.stdout);
  assert.ok(out.hookSpecificOutput, 'expected hookSpecificOutput (current PreToolUse schema)');
  assert.strictEqual(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, 'allow');
  assert.ok(out.hookSpecificOutput.permissionDecisionReason, 'expected permissionDecisionReason');
  assert.strictEqual(out.decision, undefined, 'must not emit the deprecated top-level decision field');
}

/**
 * Assert a hook ALLOWED the action by passing input through unchanged:
 * exit 0 AND stdout === the exact raw input. Use this (not `decisionOf===null`)
 * for allow/pass-through cases — a crashed hook also yields no `decision`, so
 * `decisionOf(res)===null` alone cannot tell "allowed" from "crashed" and would
 * let a broken hook pass green. This makes the failure loud.
 */
function assertPassThrough(res, payload) {
  const expected = typeof payload === 'string' ? payload : JSON.stringify(payload);
  assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
  assert.strictEqual(res.stdout, expected, 'expected raw input to pass through unchanged');
}

/**
 * Assert a hook's no-op/pass-through path produced literally nothing on
 * stdout: exit 0, empty stdout. Sibling of assertPassThrough() for the hooks
 * fixed to stop echoing rawInput on their no-op branches (issue #1339) --
 * PostToolUse/most events only ever route that stdout to the debug/transcript
 * record and PreToolUse parses it as a decision JSON, so echoing the raw tool
 * call back out had no reader on either side, only cost (1.73GB of echoed
 * stdout in 1,126,103 hook_success records over 7 days to 2026-09-23; see
 * hooks/lib/hook-output.js).
 */
function assertQuietPassThrough(res) {
  assert.strictEqual(res.code, 0, `expected exit 0, got ${res.code}; stderr: ${res.stderr}`);
  assert.strictEqual(res.stdout, '', 'expected empty stdout on a quiet pass-through');
}

function mkTmp(prefix = 'hooktest-') {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}
function rmTmp(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
}

module.exports = {
  HOOKS_DIR,
  spawnNode,
  runHook,
  runViaFlags,
  MODULE_ERROR_RE,
  decisionOf,
  reasonOf,
  assertPreToolUseDeny,
  assertPreToolUseAllow,
  assertPassThrough,
  assertQuietPassThrough,
  mkTmp,
  rmTmp,
  buildEnv,
  testHome,
};
