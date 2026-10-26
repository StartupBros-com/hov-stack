#!/usr/bin/env node
/**
 * PreToolUse Hook: Settings Surface Guard
 *
 * `ask`-gates any Edit/Write/MultiEdit whose target is a permission-surface file
 * (settings.json / settings.local.json / managed-settings.json), so an agent
 * cannot silently rewrite what the harness allows/denies/hooks. Bash is
 * deliberately NOT gated: agents use the shell constantly and full Bash
 * autonomy is a standing operator decision; the permission-surface guardrail
 * covers the file-edit tools only. Legitimate edits
 * (the update-config / fewer-permission-prompts skills, a human asking to add a
 * permission) still go through — they just prompt for confirmation first.
 *
 * The statusline ad daemon rewrites settings.json (statusLine/spinnerVerbs)
 * out-of-band as a background process, NOT through a tool call, so it never
 * reaches this hook and is unaffected.
 *
 * Fail-open: any parse problem or unexpected shape passes the call through
 * unchanged. Mirrors git-guard.js: exports run(rawInput) for direct require().
 */

'use strict';

const path = require('path');

// Basenames whose contents are the permission/enforcement surface.
const GUARDED = new Set([
  'settings.json',
  'settings.local.json',
  'managed-settings.json',
]);

// Uses the shared builder rather than a local copy of the JSON: one schema for
// every guard, and — because that module emits the seam heartbeat at load — this
// guard now participates in hook-seam-check.py's liveness signal. Previously it
// was the one first-party PreToolUse guard that never beat, while the heartbeat's
// own comments claimed every guard was covered.
const { ask } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

/**
 * @param {string} rawInput - JSON string from Claude Code stdin
 * @returns {string} JSON response or pass-through
 */
function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    const tool = input.tool_name;
    if (tool && !/^(Edit|Write|MultiEdit)$/.test(tool)) return rawInput;

    const fp = input.tool_input?.file_path;
    if (typeof fp !== 'string') return rawInput;

    if (GUARDED.has(path.basename(fp))) {
      return ask(
        'Editing the permission surface (' + path.basename(fp) + '). This changes what the ' +
          'harness allows / denies / hooks — confirm before applying. (statusLine/spinnerVerbs ' +
          'are fine; the ad daemon rewrites those out-of-band, not through this path.)'
      );
    }
  } catch {
    // Invalid JSON or unexpected shape -- pass through (fail-open).
  }
  return rawInput;
}

// Standalone entry point (backwards-compatible with direct hook invocation)
if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    if (data.length < 1024 * 1024) data += chunk;
  });
  process.stdin.on('end', () => {
    writeHookOutput(run(data), data);
    process.exit(0);
  });
}

module.exports = { run };
