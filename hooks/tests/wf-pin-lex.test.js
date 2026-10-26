'use strict';
/**
 * Tests for scripts/lib/wf-pin-lex.js (issue #1351, round 10 third
 * adversarial pass), the batch lexer shim wf-pin-audit.py delegates to
 * (see wf_pin_lex_client.py and scripts/wf-pin-audit.py's own doc
 * comments for why: every hand-ported copy of fanout-admission.js's lexer
 * has drifted from it in a prior round).
 *
 * Required in-process (no subprocess/stdin plumbing): wf-pin-lex.js's own
 * module.exports = { lexOne } already exposes the one function that matters
 * for these tests, exactly the way the shim's own main() calls it per text.
 */

const assert = require('node:assert');
const { test } = require('node:test');

const { lexOne } = require('../../scripts/lib/wf-pin-lex.js');
const { blankStrings } = require('../PreToolUse/fanout-admission.js');

// Finding 3 (round 10): lexOne() used to call lexCode(text) AND
// blankStrings(text) separately, each independently re-scanning the whole
// text. It now derives the blanked view from lexCode()'s own literal spans
// (deriveBlanked()) and must produce a result byte-for-byte identical to
// calling blankStrings(text) directly, for every one of these fixtures.
const FIXTURES = [
  'plain code with no literals at all\n',
  "const s = 'single quoted, has a # and // inside it'\n",
  'const d = "double quoted, has a /* fake block comment */ inside it"\n',
  'const t = `template ${1 + 1} literal with an interpolation`\n',
  'const nested = `outer ${`inner ${1}`} template`\n',
  '// a line comment with a \' unmatched quote in it\nconst x = 1\n',
  '/* a block\n   comment spanning\n   several lines */\nconst y = 2\n',
  'const re = /[/*]/g // a regex literal that looks like it opens a comment\n',
  "const apostrophe = 'it\\'s escaped'\nconst after = 1\n",
  '',
];

test('lexOne(): blanked view is byte-identical to blankStrings() for every lexable fixture', () => {
  for (const text of FIXTURES) {
    const result = lexOne(text);
    assert.strictEqual(result.error, undefined, `fixture unexpectedly errored: ${JSON.stringify(text)}`);
    assert.strictEqual(result.blanked, blankStrings(text), `mismatch for fixture: ${JSON.stringify(text)}`);
  }
});

test('lexOne(): an unlexable (unterminated) text returns an "unlexable" error, not spans/blanked/uncapped', () => {
  // Finding #1 (PR #1352 round 7): a null lexCode() result used to fall
  // through to blankStrings()'s own regex fallback and read as a normal,
  // fully-lexed (if empty-spans) result -- wf-pin-audit.py's caller then
  // audited this script with a degraded view instead of reporting it
  // unaudited. The auditor now fails closed: this is a per-script error
  // entry, routed through wf-pin-audit.py's existing unaudited path.
  const text = "const s = 'unterminated\nconst after = 1\n";
  const result = lexOne(text);
  assert.match(result.error, /^unlexable:/);
  assert.strictEqual(result.spans, undefined);
  assert.strictEqual(result.blanked, undefined);
  assert.strictEqual(result.uncapped, undefined);
});

test('lexOne(): a script over WF_PIN_LEX_MAX_BYTES returns a size-cap error, not spans/blanked/uncapped', () => {
  const prev = process.env.WF_PIN_LEX_MAX_BYTES;
  process.env.WF_PIN_LEX_MAX_BYTES = '10';
  try {
    const result = lexOne('this text is definitely over ten bytes long\n');
    assert.strictEqual(result.error, 'script exceeds 10 bytes');
    assert.strictEqual(result.spans, undefined);
    assert.strictEqual(result.blanked, undefined);
    assert.strictEqual(result.uncapped, undefined);
  } finally {
    if (prev === undefined) delete process.env.WF_PIN_LEX_MAX_BYTES;
    else process.env.WF_PIN_LEX_MAX_BYTES = prev;
  }
});

test('lexOne(): a script that outlives WF_PIN_LEX_BUDGET_MS returns a budget error, not spans/blanked/uncapped', () => {
  const prev = process.env.WF_PIN_LEX_BUDGET_MS;
  process.env.WF_PIN_LEX_BUDGET_MS = '1';
  try {
    const declarations = Array.from({ length: 50000 }, (_, i) => `const helper_${i} = 0`).join('\n');
    const result = lexOne(`${declarations}\n`);
    assert.match(result.error, /^budget exceeded after \d+ ms$/);
    assert.strictEqual(result.spans, undefined);
    assert.strictEqual(result.blanked, undefined);
    assert.strictEqual(result.uncapped, undefined);
  } finally {
    if (prev === undefined) delete process.env.WF_PIN_LEX_BUDGET_MS;
    else process.env.WF_PIN_LEX_BUDGET_MS = prev;
  }
});

test('lexOne(): default budget/size caps still return a normal result for an everyday script', () => {
  const result = lexOne("await agent('work', {model: 'sonnet'})\n");
  assert.strictEqual(result.error, undefined);
  assert.ok(Array.isArray(result.uncapped));
});

// Round 6 (#1352 adversarial finding, P2): before this round, lexOne()'s
// catch special-cased only AnalysisBudgetExceeded (and lexCode() itself ran
// with no try/catch around it at all) -- any OTHER per-text exception
// escaped lexOne() entirely, escaped the `.map()` in main() below, and
// turned one pathological script into a SHIM-LEVEL failure for the WHOLE
// batch. WF_PIN_LEX_FAULT_INJECT is the doc-comment's own test seam for
// exercising that catch-all without depending on a real script that makes
// fanout-admission.js's lexer throw today.
test('lexOne(): a fault injected via WF_PIN_LEX_FAULT_INJECT returns a lexer-error, not spans/blanked/uncapped', () => {
  const prev = process.env.WF_PIN_LEX_FAULT_INJECT;
  process.env.WF_PIN_LEX_FAULT_INJECT = 'ZAP_MARKER';
  try {
    const result = lexOne("await agent('work') // ZAP_MARKER\n");
    assert.match(result.error, /^lexer-error: fault injected via WF_PIN_LEX_FAULT_INJECT/);
    assert.strictEqual(result.spans, undefined);
    assert.strictEqual(result.blanked, undefined);
    assert.strictEqual(result.uncapped, undefined);
  } finally {
    if (prev === undefined) delete process.env.WF_PIN_LEX_FAULT_INJECT;
    else process.env.WF_PIN_LEX_FAULT_INJECT = prev;
  }
});

test('lexOne(): WF_PIN_LEX_FAULT_INJECT is inert when unset, even if the text contains the marker string', () => {
  const prev = process.env.WF_PIN_LEX_FAULT_INJECT;
  delete process.env.WF_PIN_LEX_FAULT_INJECT;
  try {
    const text = "await agent('work') // ZAP_MARKER\n";
    const result = lexOne(text);
    assert.strictEqual(result.error, undefined);
    assert.strictEqual(result.blanked, blankStrings(text));
    assert.ok(Array.isArray(result.uncapped));
  } finally {
    if (prev === undefined) delete process.env.WF_PIN_LEX_FAULT_INJECT;
    else process.env.WF_PIN_LEX_FAULT_INJECT = prev;
  }
});

// PR #1352 round-7 landing: the Python budget tests used a run-wide
// WF_PIN_LEX_BUDGET_MS=1, so under CPU load the tiny sibling script that must
// audit normally exceeded 1ms too (the deadline check fires at i === 0) and
// the test failed 2 of 6 runs. WF_PIN_LEX_BUDGET_INJECT marks ONE text as
// already over budget through the real AnalysisBudgetExceeded path; every
// other text keeps the real budget.
test('lexOne(): WF_PIN_LEX_BUDGET_INJECT makes a marked text a budget error through the real budget path, siblings unaffected', () => {
  const prev = process.env.WF_PIN_LEX_BUDGET_INJECT;
  process.env.WF_PIN_LEX_BUDGET_INJECT = 'OVER_BUDGET_MARKER';
  try {
    const marked = lexOne("await agent('work') // OVER_BUDGET_MARKER\n");
    assert.match(marked.error, /^budget exceeded after \d+ ms$/);
    assert.strictEqual(marked.spans, undefined);
    assert.strictEqual(marked.blanked, undefined);
    assert.strictEqual(marked.uncapped, undefined);
    const sibling = "await agent('work')\n";
    const normal = lexOne(sibling);
    assert.strictEqual(normal.error, undefined);
    assert.strictEqual(normal.blanked, blankStrings(sibling));
    assert.ok(Array.isArray(normal.uncapped));
  } finally {
    if (prev === undefined) delete process.env.WF_PIN_LEX_BUDGET_INJECT;
    else process.env.WF_PIN_LEX_BUDGET_INJECT = prev;
  }
});

test('lexOne(): WF_PIN_LEX_BUDGET_INJECT is inert when unset, even if the text contains the marker string', () => {
  const prev = process.env.WF_PIN_LEX_BUDGET_INJECT;
  delete process.env.WF_PIN_LEX_BUDGET_INJECT;
  try {
    const text = "await agent('work') // OVER_BUDGET_MARKER\n";
    const result = lexOne(text);
    assert.strictEqual(result.error, undefined);
    assert.strictEqual(result.blanked, blankStrings(text));
    assert.ok(Array.isArray(result.uncapped));
  } finally {
    if (prev === undefined) delete process.env.WF_PIN_LEX_BUDGET_INJECT;
    else process.env.WF_PIN_LEX_BUDGET_INJECT = prev;
  }
});
