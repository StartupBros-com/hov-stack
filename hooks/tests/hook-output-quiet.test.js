'use strict';
/**
 * Regression gate for issue #1339: every hook standalone entry must route
 * its stdout write through lib/hook-output.js's writeHookOutput(), not a
 * bare `process.stdout.write(...)` of run()'s return value or the raw
 * stdin payload -- that bare form re-echoes the entire tool-call JSON on
 * every no-op call (1.73GB/7 days of dead hook_success transcript bytes,
 * measured 2026-09-23).
 *
 * (a) unit-tests writeHookOutput() directly.
 * (b) scans every stdout call site in every non-test hook file and fails,
 *     naming file:line, on any site that is neither the helper nor an
 *     explicit, justified ALLOWLIST entry (or on a stale entry).
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { writeHookOutput } = require('../lib/hook-output');

// --- (a) writeHookOutput unit tests -----------------------------------

test('writeHookOutput: raw input unchanged -> writes nothing', () => {
  const raw = '{"a":1}';
  const calls = [];
  const orig = process.stdout.write;
  process.stdout.write = (chunk) => { calls.push(chunk); return true; };
  try {
    writeHookOutput(raw, raw);
  } finally {
    process.stdout.write = orig;
  }
  assert.deepStrictEqual(calls, []);
});

test('writeHookOutput: null/undefined/empty -> writes nothing', () => {
  const raw = '{"a":1}';
  const calls = [];
  const orig = process.stdout.write;
  process.stdout.write = (chunk) => { calls.push(chunk); return true; };
  try {
    writeHookOutput(null, raw);
    writeHookOutput(undefined, raw);
    writeHookOutput('', raw);
  } finally {
    process.stdout.write = orig;
  }
  assert.deepStrictEqual(calls, []);
});

test('writeHookOutput: a different string -> written', () => {
  const raw = '{"a":1}';
  const decision = '{"hookSpecificOutput":{"permissionDecision":"deny"}}';
  const calls = [];
  const orig = process.stdout.write;
  process.stdout.write = (chunk) => { calls.push(chunk); return true; };
  try {
    writeHookOutput(decision, raw);
  } finally {
    process.stdout.write = orig;
  }
  assert.deepStrictEqual(calls, [decision]);
});

test('writeHookOutput: a Buffer that differs from raw -> written; equal to raw -> not', () => {
  const raw = 'hello';
  const calls = [];
  const orig = process.stdout.write;
  process.stdout.write = (chunk) => { calls.push(chunk); return true; };
  try {
    writeHookOutput(Buffer.from('different'), raw);
    writeHookOutput(Buffer.from(raw), raw);
  } finally {
    process.stdout.write = orig;
  }
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(calls[0].toString('utf8'), 'different');
});

// --- (b) every stdout call site is either writeHookOutput or allowlisted ---
//
// A file-level scan (only look at files with `require.main === module`, and
// only ask "does this file mention writeHookOutput( anywhere") has two holes:
// run-with-flags.js's dispatcher runs at module scope (`main().catch(...)`,
// no `require.main === module` guard) so it was never scanned at all; and
// even a scanned file can carry a legitimate direct write (run-with-flags.js
// line ~119, the legacy spawnSync child-process relay) that would make the
// file "uses the helper" true forever, masking a regression in a *different*
// write on the same file (the require() fast path a few lines up). Scan every
// individual write call site instead, and require each one to be either the
// helper call or an explicit, justified ALLOWLIST entry.

const HOOKS_DIR = path.resolve(__dirname, '..');
const HOOK_OUTPUT_FILE = path.join(HOOKS_DIR, 'lib', 'hook-output.js');

function listHookFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'tests' || entry.name === 'node_modules') continue;
      out.push(...listHookFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.js')) {
      out.push(full);
    }
  }
  return out;
}

// Every way a call site could put bytes on stdout that this gate cares about.
const STDOUT_CALL_TRIGGERS = [
  'process.stdout.write(',
  'console.log(',
  'console.info(',
  'writeSync(1, ',
  'process.stdout.end(',
];

// Finds every call beginning with one of STDOUT_CALL_TRIGGERS and returns its
// full source text (trigger through the matching close paren) plus the line
// it starts on. Tracks string/template-literal state so a `(`/`)` or nested
// quote *inside* an argument (a template literal's `${...}` interpolation,
// e.g.) can't be mistaken for the call's own closing paren. The returned text
// is whitespace-normalized (collapsed to single spaces, trimmed) so a
// multi-line call's exact indentation doesn't have to be hand-transcribed
// into ALLOWLIST below -- it still changes, and fails a stale-entry check,
// the moment the call's actual arguments change.
function findStdoutCallSites(src) {
  const sites = [];
  for (const trigger of STDOUT_CALL_TRIGGERS) {
    let searchFrom = 0;
    let idx;
    while ((idx = src.indexOf(trigger, searchFrom)) !== -1) {
      let i = idx + trigger.length;
      let depth = 1; // the trigger already consumed the opening '('
      let quote = null;
      while (i < src.length && depth > 0) {
        const ch = src[i];
        if (quote) {
          if (ch === '\\') { i += 2; continue; } // skip the escaped char too
          if (ch === quote) quote = null;
          i++;
          continue;
        }
        if (ch === '"' || ch === "'" || ch === '`') { quote = ch; i++; continue; }
        if (ch === '(') depth++;
        else if (ch === ')') depth--;
        i++;
      }
      const text = src.slice(idx, i).trim().replace(/\s+/g, ' ');
      const line = src.slice(0, idx).split('\n').length;
      sites.push({ text, line });
      searchFrom = i;
    }
  }
  return sites;
}

// Every non-helper stdout write left in the tree, each with a justification
// verified against the code (not just asserted): confirm this before editing
// the entry, don't just carry it forward.
const ALLOWLIST = [
  {
    file: 'run-with-flags.js',
    text: 'process.stdout.write(result.stdout)',
    reason: 'legacy spawnSync relay of a child hook whose own entry already routes through writeHookOutput',
  },
  {
    file: 'PreCompact/compact-preserve.js',
    text: "process.stdout.write(PRESERVE_LIST + '\\n')",
    reason: 'deliberate injected text, never raw input',
  },
  {
    file: 'lib/live-sessions.js',
    text: "process.stdout.write(JSON.stringify(liveSessions(), null, 1) + '\\n')",
    reason: 'CLI output, not a hook entry',
  },
  {
    file: 'lib/live-sessions.js',
    text:
      "process.stdout.write( `sessions: ${r.live} live, ${r.pruned} dead ${flag('--dry-run') ? 'prunable' : 'pruned'} ` " +
      "+ `(>${minAgeDays}d), ${r.keptRecent} dead kept (<${minAgeDays}d)\\n` )",
    reason: 'CLI output, not a hook entry',
  },
  {
    file: 'lib/stray-dot-git.js',
    text: 'process.stdout.write(`${describe(f)}\\n`)',
    reason: 'CLI output (--check for harness-doctor, --heal by hand), not a hook entry; '
      + 'the SessionStart path returns its text through launchpad-advisory.js',
  },
  {
    file: 'lib/workspace-trust.js',
    text: 'process.stdout.write(`untrusted: ${key}\\n`)',
    reason: 'CLI output (--check by hand), not a hook entry; the SessionStart path calls seed() and prints nothing',
  },
  {
    file: 'lib/workspace-trust.js',
    text: 'process.stdout.write(`trusted: ${key}\\n`)',
    reason: 'CLI output (--seed by hand), not a hook entry; the SessionStart path calls seed() and prints nothing',
  },
  {
    file: 'lib/utils.js',
    text: 'console.log(JSON.stringify(data))',
    reason: "zero callers today; do NOT delete that helper",
  },
  {
    file: 'lib/utils.js',
    text: 'console.log(data)',
    reason: "zero callers today; do NOT delete that helper",
  },
];

test('every stdout call site outside writeHookOutput matches a justified ALLOWLIST entry', () => {
  const sites = [];
  for (const file of listHookFiles(HOOKS_DIR)) {
    if (file === HOOK_OUTPUT_FILE) continue; // the one file allowed to write unconditionally
    const rel = path.relative(HOOKS_DIR, file);
    const src = fs.readFileSync(file, 'utf8');
    for (const site of findStdoutCallSites(src)) {
      sites.push({ file: rel, text: site.text, line: site.line });
    }
  }

  const unlisted = sites
    .filter((site) => !ALLOWLIST.some((a) => a.file === site.file && a.text === site.text))
    .map((site) => `${site.file}:${site.line}: ${site.text}`);
  assert.deepStrictEqual(
    unlisted,
    [],
    'stdout call sites with no writeHookOutput() and no ALLOWLIST entry (route through the helper or add a ' +
      'justified entry): ' + unlisted.join(' | ')
  );

  // A stale entry (matches zero real call sites) would silently widen the
  // gate forever -- e.g. an ALLOWLIST text nobody updated after the call it
  // named was edited or deleted, leaving room for a new, different violation
  // to reuse the same file without ever being checked.
  const stale = ALLOWLIST
    .filter((entry) => !sites.some((s) => s.file === entry.file && s.text === entry.text))
    .map((entry) => `${entry.file}: ${entry.text}`);
  assert.deepStrictEqual(
    stale,
    [],
    'ALLOWLIST entries matching zero call sites (remove them or fix the text): ' + stale.join(' | ')
  );
});

test("run-with-flags.js's require() fast path routes a no-op run() through writeHookOutput", async () => {
  // A hook's run() signaling "no-op, pass through" by returning rawInput
  // unchanged (the documented contract in lib/hook-output.js) only stays
  // quiet on this path if writeHookOutput(output, raw) is the one deciding
  // whether to write -- a bare `process.stdout.write(output)` here would
  // echo the whole payload back out, the exact regression #1339 fixed.
  // Unlike the disabled/missing-script/traversal tests in
  // run-with-flags.test.js, echo-through.hook.js has a real run() export, so
  // this exercises the require() fast path itself, not an earlier bypass.
  const { runViaFlags, assertQuietPassThrough } = require('./lib/harness');
  const payload = '{"probe":"echo-through"}';
  const res = await runViaFlags('test:echo-through', 'tests/fixtures/echo-through.hook.js', 'standard', payload);
  assertQuietPassThrough(res);
});
