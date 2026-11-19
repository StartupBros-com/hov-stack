'use strict';
// papercut's capture rules ship four times. hooks/PostToolUseFailure/papercut-log.js is the
// harness copy, which seven other hook files and scripts/papercut-backfill.js load as a library;
// plugins/papercut/hooks/papercut-log.js is the copy the papercut plugin runs on every host that
// installs it. bin/papercut.py and the plugin's papercut/cli.py repeat its REDACTIONS table and
// signalLine() in Python, because the CLI scrubs and displays what it stores. scripts/
// papercut-vendor.py built the plugin files from the harness ones, and since #339 every copy is
// edited in place. Each has its own tests, and the plugin's hook tests are a fifth of the
// harness's, so a redaction or signature fix landed in one copy and its tests passes CI while
// another copy keeps the old rule: a secret one copy now scrubs still reaches the store, and an
// issue filed from it, through another.
//
// This file runs every copy on the same inputs and requires the same answers. The copies may
// differ in comments, in require paths, and in one sentence of readLimitHint (the harness copy
// points at the cass CLI, which the plugin cannot assume is installed), so it compares behaviour,
// never source text. Delete a copy's leg when that copy stops being a separate file.
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const harness = require(path.join(ROOT, 'hooks', 'PostToolUseFailure', 'papercut-log.js'));
const plugin = require(path.join(ROOT, 'plugins', 'papercut', 'hooks', 'papercut-log.js'));
const PYTHON_COPIES = [
  path.join(ROOT, 'bin', 'papercut.py'),
  path.join(ROOT, 'plugins', 'papercut', 'papercut', 'cli.py'),
];

// Assembled from fragments, as in papercut-log.test.js, so this file does not trip sync.sh's
// guard_no_credentials scanner.
const KEY_BEGIN = '-----BEGIN OPENSSH PRIV' + 'ATE KEY-----';
const KEY_END = '-----END OPENSSH PRIV' + 'ATE KEY-----';

// Fake credentials, the shapes hooks/tests/papercut-log.test.js and tests/test_papercut.py
// assert each copy scrubs.
const SECRET_TEXTS = [
  'curl -H "Authorization: Bearer sk-abc123def456ghi789"', // gitleaks:allow
  'psql postgres://admin:hunter2swordfish@db.example.net:5432/app', // gitleaks:allow
  'gh auth: token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345', // gitleaks:allow
  'export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE', // gitleaks:allow
  'PGPASSWORD=s3cr3tvalue psql -h db', // gitleaks:allow
  '{"api_key": "abcd1234efgh5678"}', // gitleaks:allow
  'slack: xoxb-1234567890-abcdefghijkl', // gitleaks:allow
  'stripe error: using key sk_live_51H8xAbCdEfGhIjKlMnOp', // gitleaks:allow
  'stripe test mode pk_test_51H8xAbCdEfGhIjKlMnOp failed', // gitleaks:allow
  'GET https://maps.googleapis.com/api?key=AIzaSyD1234567890abcdefghijklmnopqrst', // gitleaks:allow
  'jwt rejected: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NX0.dBjftJeZ4CVPmB92K27uhbUJU1p1r', // gitleaks:allow
  'curl: (22) HTTP 401 for https://user:hunter2swordfish@api.example.net/v1', // gitleaks:allow
  `${KEY_BEGIN}\nb3BlbnNzaC1rZXktdjE\n${KEY_END}`,
];

const PLAIN_TEXTS = [
  '',
  '   ',
  'Exit code 1',
  'Exit code 127\n/bin/bash: line 1: pytest: command not found',
  'Exit code 1\nsome_command: syntax error near unexpected token',
  'Exit code 1\nsrc/a.ts(1,1): error TS1005',
  "Exit code 2\nls: cannot access '/srv/app/node_modules/.bin/tsx': No such file or directory",
  'Exit code 1\n<claude-code-hint v="1" type="plugin" value="example@marketplace" />',
  "Exit code 1\nnode:internal/modules/run_main:107\n    triggerUncaughtException(\n    ^\nError [ERR_MODULE_NOT_FOUND]: Cannot find package 'x' imported from /srv/app/b.ts",
  'Exit code 1\nnode:internal/process/promises:394\n    triggerUncaughtException(err, true);',
  'File content (85675 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters.',
  "Output does not match required schema: root: must have required property 'refuted'",
  'API Error: 400 the requested server-tool options are invalid.',
  'error at 2026-11-19T10:22:33Z in /srv/app/build/out-4f9a2c1e/index.js:120:7 (pid 48213)',
  'boom ' + 'x'.repeat(20000),
  'x'.repeat(5000) + ' token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345', // gitleaks:allow
];

const TEXTS = [...SECRET_TEXTS, ...PLAIN_TEXTS];

const failure = (over = {}) => ({
  hook_event_name: 'PostToolUseFailure',
  session_id: 'abcdefgh12345678',
  cwd: '/srv/app/demo',
  tool_name: 'Bash',
  tool_input: { command: 'pytest -q' },
  error: 'Exit code 127\n/bin/bash: line 1: pytest: command not found',
  duration_ms: 42,
  ...over,
});

const READ_CEILING = 'File content (85675 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters.';

// One payload per branch of record() and of the hint functions run() chains together.
const PAYLOADS = [
  failure(),
  failure({ error: '   ' }),
  failure({ is_interrupt: true }),
  failure({ tool_input: { command: 'grep -q needle haystack.txt' }, error: 'Exit code 1' }),
  failure({ tool_input: { command: 'git diff --quiet' }, error: 'Exit code 1' }),
  failure({ tool_input: { command: 'cd /nope' }, error: 'Exit code 1' }),
  failure({ error: 'boom ' + 'x'.repeat(500000) }),
  failure({
    tool_input: { command: 'curl -H "Authorization: Bearer sk-abc123def456ghi789" https://api.example.net' }, // gitleaks:allow
    error: 'curl: (22) HTTP 401 for https://user:hunter2swordfish@api.example.net/v1', // gitleaks:allow
  }),
  failure({ tool_input: { command: 'tsc' }, error: 'Exit code 1\nsrc/a.ts(1,1): error TS1005', agent_id: 'a3eff2814d8720436' }),
  failure({ tool_name: 'Read', tool_input: { file_path: '/srv/app/big.diff', offset: 6600, limit: 6000 }, error: READ_CEILING }),
  failure({ tool_name: 'Read', tool_input: { file_path: '/srv/app/data/events.jsonl' }, error: READ_CEILING }),
  failure({
    tool_name: 'Read',
    tool_input: { file_path: '/home/user/.claude/projects/-srv-app-demo/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab.jsonl' },
    error: READ_CEILING,
  }),
  failure({ tool_name: 'Read', tool_input: { file_path: '/srv/app/missing.md' }, error: 'File does not exist.' }),
  failure({
    tool_name: 'StructuredOutput',
    tool_input: { verdict: 'refuted', notes: 'x' },
    error: "Output does not match required schema: root: must have required property 'refuted', root: must have required property 'reasoning'",
  }),
  failure({
    tool_name: 'StructuredOutput',
    tool_input: { input: { refuted: true } },
    error: "Output does not match required schema: root: must have required property 'refuted'",
  }),
  failure({ tool_name: 'WebSearch', tool_input: { query: 'node test runner glob' }, error: 'API Error: 400 the requested server-tool options are invalid.' }),
  failure({ tool_name: 'mcp__example__get_item', tool_input: { id: '123' }, error: 'it broke' }),
  failure({
    cwd: '/srv/app/packages/web',
    tool_input: { command: 'eslint .' },
    error: "Exit code 2\n\nOops! Something went wrong! :(\n\nESLint: 9.39.1\n\nESLint couldn't find an eslint.config.(js|mjs|cjs) file.",
  }),
  failure({
    tool_input: { command: 'node --test apps/web/route.test.ts' },
    error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'tsx' imported from /srv/app/packages/billing/gateway/x.test.ts",
  }),
  failure({
    tool_input: { command: 'node dist/server.js' },
    error: "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/srv/app/dist/config.js' imported from /srv/app/dist/server.js",
  }),
  failure({
    tool_input: { command: 'node node_modules/tsx/dist/cli.mjs x.ts' },
    error: "Error: Cannot find module '/srv/app/.claude/worktrees/fresh/node_modules/tsx/dist/cli.mjs'",
  }),
];

// record() stamps the wall clock; everything else in a record is a function of the input.
const withoutClock = (line) => {
  if (line === null) return null;
  const rec = JSON.parse(line);
  delete rec.ts;
  return rec;
};

// Compiles one Python copy from its source and answers [redact(t), signal_line(t)] for each
// text. Never through the import system: a __pycache__ entry whose recorded mtime and size still
// match (a same-length edit within the same second does that) is run in place of the source,
// and the comparison then passes on code that is no longer in the file.
const PY_PROBE = [
  'import json, sys, types',
  'path = sys.argv[1]',
  'mod = types.ModuleType("papercut_parity")',
  'mod.__file__ = path',
  'sys.modules[mod.__name__] = mod',
  'with open(path, encoding="utf-8") as f:',
  '    exec(compile(f.read(), path, "exec"), mod.__dict__)',
  'print(json.dumps([[mod.redact(t), mod.signal_line(t)] for t in json.load(sys.stdin)]))',
].join('\n');

const pythonAnswers = (file, texts) => JSON.parse(execFileSync('python3', ['-I', '-B', '-c', PY_PROBE, file], {
  input: JSON.stringify(texts), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
}));

test('both hook copies export the same names and the same record size bound', () => {
  assert.deepStrictEqual(Object.keys(plugin).sort(), Object.keys(harness).sort());
  assert.strictEqual(plugin.MAX_RECORD_BYTES, harness.MAX_RECORD_BYTES);
});

test('both hook copies redact, trim and normalize every text the same way', () => {
  for (const text of TEXTS) {
    const label = JSON.stringify(text.slice(0, 80));
    assert.strictEqual(plugin.redact(text), harness.redact(text), `redact ${label}`);
    assert.strictEqual(plugin.redactThenTrim(text), harness.redactThenTrim(text), `redactThenTrim ${label}`);
    assert.strictEqual(plugin.normalize(text), harness.normalize(text), `normalize ${label}`);
    assert.strictEqual(plugin.signalLine(text), harness.signalLine(text), `signalLine ${label}`);
    assert.strictEqual(plugin.isContentFree(text), harness.isContentFree(text), `isContentFree ${label}`);
  }
});

test('the corpus reaches the redaction rules it is meant to compare', () => {
  // Without this, a corpus every copy passes through untouched would compare nothing.
  for (const text of SECRET_TEXTS) {
    assert.match(harness.redact(text), /<redacted>/, `no rule fired on ${text}`);
  }
});

test('both Python copies redact and pick the signal line as the hook does', () => {
  for (const file of PYTHON_COPIES) {
    const answers = pythonAnswers(file, TEXTS);
    assert.strictEqual(answers.length, TEXTS.length, `${path.relative(ROOT, file)} answered ${answers.length} of ${TEXTS.length}`);
    TEXTS.forEach((text, i) => {
      const label = `${path.relative(ROOT, file)} on ${JSON.stringify(text.slice(0, 80))}`;
      assert.strictEqual(answers[i][0], harness.redact(text), `redact, ${label}`);
      assert.strictEqual(answers[i][1], harness.signalLine(text), `signal_line, ${label}`);
    });
  }
});

test('both hook copies compute the same signature for the same failure', () => {
  // Fed the redacted, trimmed text record() hands it: on a raw 500,000-character error
  // signature() takes about a minute per copy, and no caller passes it untrimmed text.
  for (const p of PAYLOADS) {
    const args = [harness.redactThenTrim(p.error), p.tool_name,
      harness.redactThenTrim(JSON.stringify(p.tool_input)), p.tool_input.command || ''];
    assert.strictEqual(plugin.signature(...args), harness.signature(...args), `signature for ${p.tool_name}: ${p.error.slice(0, 60)}`);
  }
});

test('both hook copies build the same record, or skip the same failure', () => {
  let built = 0;
  for (const p of PAYLOADS) {
    const h = withoutClock(harness.record(p));
    assert.deepStrictEqual(withoutClock(plugin.record(p)), h, `record for ${p.tool_name}: ${p.error.slice(0, 60)}`);
    if (h !== null) built += 1;
  }
  assert.ok(built >= 10, `only ${built} payloads produced a record; the comparison has lost its coverage`);
});

test('both hook copies give the same hints, and readLimitHint fires on the same failures', () => {
  for (const p of PAYLOADS) {
    const label = `${p.tool_name}: ${p.error.slice(0, 60)}`;
    assert.deepStrictEqual(plugin.structuredOutputShape(p.tool_input), harness.structuredOutputShape(p.tool_input), `structuredOutputShape ${label}`);
    assert.strictEqual(plugin.structuredOutputHint(p), harness.structuredOutputHint(p), `structuredOutputHint ${label}`);
    assert.strictEqual(plugin.workspaceBinHint(p), harness.workspaceBinHint(p), `workspaceBinHint ${label}`);
    assert.strictEqual(plugin.esmTestHint(p), harness.esmTestHint(p), `esmTestHint ${label}`);
    // The one sanctioned wording difference: compare whether it fires, not what it says.
    assert.strictEqual(plugin.readLimitHint(p) === null, harness.readLimitHint(p) === null, `readLimitHint ${label}`);
  }
});

test('both hook copies slug a project directory the same way', () => {
  for (const cwd of ['/srv/app/demo', '/home/user/SITES/acme-app', '/srv/app/.claude/worktrees/x', '', 'C:\\Users\\user\\proj']) {
    assert.strictEqual(plugin.projectSlug(cwd), harness.projectSlug(cwd), `projectSlug ${cwd}`);
  }
});
