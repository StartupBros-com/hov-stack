'use strict';
/**
 * pr-record.js is retired (2026-11-03) but kept as a no-op so a live
 * settings.json that still registers it, until `sync.sh install` removes the
 * registration, never sees a hook error. Delete this test with the file.
 */

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { HOOKS_DIR, buildEnv } = require('./lib/harness');

const STUB = path.join(HOOKS_DIR, 'PostToolUse', 'pr-record.js');

// spawnNode has no error listener on the child's stdin, so an EPIPE there
// would crash the test file instead of failing one case. Record it instead.
function runStub(stdin) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [STUB], { cwd: HOOKS_DIR, env: buildEnv() });
    const stdinErrors = [];
    let stdout = '';
    let stderr = '';
    child.stdin.on('error', (e) => stdinErrors.push(e.code));
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => resolve({ code, stdout, stderr, stdinErrors }));
    child.stdin.end(stdin);
  });
}

test('retired stub: exits 0 with no output for a gh pr create call', async () => {
  const res = await runStub(JSON.stringify({
    session_id: 'sess-stub',
    tool_name: 'Bash',
    tool_input: { command: 'gh pr create --title t --body b' },
    tool_response: { stdout: 'https://github.com/o/r/pull/1\n', stderr: '', interrupted: false },
  }));
  assert.deepStrictEqual(res, { code: 0, stdout: '', stderr: '', stdinErrors: [] });
});

test('retired stub: reads a payload past the pipe buffer before exiting', async () => {
  // Claude Code writes the whole tool call to the hook's stdin. A child that
  // exits before reading leaves the writer with EPIPE once the payload is past
  // the 64 KiB Linux pipe buffer; 2 MiB is a large Bash output.
  const payload = JSON.stringify({
    tool_name: 'Bash',
    tool_input: { command: 'cat big.log' },
    tool_response: { stdout: 'x'.repeat(2 * 1024 * 1024), stderr: '' },
  });
  const res = await runStub(payload);
  assert.deepStrictEqual(res, { code: 0, stdout: '', stderr: '', stdinErrors: [] });
});
