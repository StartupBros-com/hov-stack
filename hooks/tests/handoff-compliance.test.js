'use strict';
/**
 * handoff-compliance.js is retired (dotfiles#1865) but kept as a no-op so a
 * live settings.json that still registers it, until `sync.sh install` removes
 * the registration, never sees a hook error. Delete this test with the file.
 */

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { HOOKS_DIR, buildEnv } = require('./lib/harness');

const STUB = path.join(HOOKS_DIR, 'PreToolUse', 'handoff-compliance.js');

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

test('retired stub: exits 0 with no output', async () => {
  const res = await runStub(JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'ls' } }));
  assert.deepStrictEqual(res, { code: 0, stdout: '', stderr: '', stdinErrors: [] });
});

test('retired stub: reads a payload past the pipe buffer before exiting', async () => {
  // Claude Code writes the whole tool call to the hook's stdin. A child that
  // exits before reading leaves the writer with EPIPE once the payload is past
  // the 64 KiB Linux pipe buffer; 2 MiB is a large Write or Workflow call.
  const payload = JSON.stringify({ tool_name: 'Write', tool_input: { content: 'x'.repeat(2 * 1024 * 1024) } });
  const res = await runStub(payload);
  assert.deepStrictEqual(res, { code: 0, stdout: '', stderr: '', stdinErrors: [] });
});
