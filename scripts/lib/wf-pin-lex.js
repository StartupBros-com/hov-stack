#!/usr/bin/env node
'use strict';
/**
 * Batch lexer shim for scripts/wf-pin-audit.py.
 *
 * wf-pin-audit.py must not hand-port fanout-admission.js's lexer and
 * scopedMapCap()/uncappedFanouts() cap-resolution logic: this shim is the
 * ONE place that logic runs for the auditor, calling fanout-admission.js's
 * own already-exported, adversarially reviewed `lexCode()`/
 * `uncappedFanouts()` directly instead of a second, independently-drifting
 * copy of the same scan. History: see issue #1351.
 *
 * Contract (one process per batch, never per script):
 *   stdin:  {"texts": ["<script text>", ...]}
 *   stdout: {"results": [{"spans": [[start, end, kind], ...],
 *                          "blanked": "<text with every span replaced by
 *                            spaces (comments keep embedded newlines)>",
 *                          "uncapped": [[start, end], ...]}
 *                        | {"error": "<reason>"}, ...]}
 *     A result entry is EITHER the {"spans", "blanked", "uncapped"} success
 *     shape OR a per-script {"error": "<reason>"} entry with none of those
 *     three keys -- see the "Per-script error" paragraph below for the
 *     conditions that produce the latter. wf_pin_lex_client.py passes an
 *     error entry through as-is (never raises for it); only wf-pin-audit.py
 *     decides what "this one script is unaudited" means. Every offset below
 *     is a UTF-16 code-unit offset into the ORIGINAL input text (JavaScript
 *     string indexing) -- wf_pin_lex_client.py converts these to Unicode
 *     code-point offsets (Python string indexing) before any Python caller
 *     reads them; see that module's own doc comment for why an astral
 *     character (outside the Basic Multilingual Plane) makes the two
 *     indexings diverge.
 *     "spans" mirrors lexCode()'s `literals`: kind is "string" (a `'`, `"`,
 *     or backtick literal -- a template's own `${...}` interpolation is
 *     part of the same atomic span), "comment" (a line or block comment),
 *     or "regex" (a `/.../ ` literal).
 *     "blanked" is this shim's own derived blanking of every span in
 *     "spans" (space-filled, comment newlines kept) -- byte-identical to
 *     calling fanout-admission.js's own blankStrings(text) directly, for
 *     any text lexCode() can lex.
 *     "uncapped" is fanout-admission.js's uncappedFanouts(blanked, deadline)
 *     verbatim -- the fan-out spans (per the HOOK's own FANOUT_RE) whose
 *     data-driven `.map(`/`.flatMap(` has no cap scopedMapCap() can
 *     resolve. wf-pin-audit.py.uncapped_fanouts() intersects these with its
 *     own narrower (parallel|pipeline)-only FANOUT_RE, so the hook's
 *     broader recognition (it also matches Promise.all(...)) never
 *     silently widens the auditor's own scope.
 *
 * Per-script error: a result entry is `{"error": "<reason>"}` -- no
 * "spans"/"blanked"/"uncapped" at all -- for any of four per-script
 * conditions, none of which aborts the batch: (1) this text exceeds the
 * per-script size cap (env WF_PIN_LEX_MAX_BYTES, default 2000000 bytes),
 * skipped before lexing at all; (2) lexCode() returned null -- the hook's
 * own lexer could not lex this text at all (an unterminated string,
 * template, comment, or regex literal) -- reason `unlexable: <detail>`;
 * this auditor fails closed on an unlexable script (doctrine: a gate that
 * cannot compare must fail) rather than falling back to a comment-blind
 * regex scan; (3) this text's own lexCode()/uncappedFanouts() scan ran
 * past its per-script budget (env WF_PIN_LEX_BUDGET_MS, default 3000ms);
 * or (4) lexOne() threw any other error while lexing or analyzing this ONE
 * text (reason `lexer-error: <message>`, truncated to ~200 chars).
 * wf_pin_lex_client.py passes all four kinds of per-script error through as
 * per-script results rather than raising; wf-pin-audit.py counts that one
 * script as unaudited (naming the specific reason) and keeps auditing
 * every other script in the batch -- see both modules' own doc comments.
 *
 * Any SHIM-LEVEL failure (bad JSON on stdin, the hook file missing or
 * throwing on require, an unexpected exception escaping the per-text
 * processing loop) is reported on STDERR as one line and the process exits
 * non-zero -- wf_pin_lex_client.py's ShimUnavailable. wf-pin-audit.py's
 * doctrine (a gate that cannot compare must fail) means its caller must
 * NOT treat that as "no findings."
 *
 * Test seam: WF_PIN_LEX_FAULT_INJECT=<marker>. Inert unless set. When set,
 * lexOne() throws a plain Error for any text containing `<marker>` as a
 * substring, landing on condition (4) above, without depending on finding
 * a real script that makes fanout-admission.js's own lexer throw today.
 *
 * Test seam: WF_PIN_LEX_BUDGET_INJECT=<marker>. Inert unless set. When set,
 * any text containing `<marker>` as a substring starts with its per-script
 * budget already exhausted, so fanout-admission.js's own first deadline
 * check throws AnalysisBudgetExceeded through the real condition-(3) path
 * for THAT text alone while every sibling keeps the real budget. The tests
 * use it instead of a run-wide WF_PIN_LEX_BUDGET_MS=1, which also applied
 * to the tiny sibling script that must audit normally: a scheduler stall
 * between startedAt and the first deadline check under CPU load made that
 * sibling a budget error too, and the test flaked (2 of 6 runs under load).
 */

let fanout;
try {
  // eslint-disable-next-line import/no-dynamic-require
  fanout = require('../../hooks/PreToolUse/fanout-admission.js');
} catch (err) {
  process.stderr.write(
    `wf-pin-lex: cannot load fanout-admission.js: ${err && err.message ? err.message : err}\n`
  );
  process.exit(1);
}

const { blankStrings, lexCode, uncappedFanouts, AnalysisBudgetExceeded } = fanout;
if (
  typeof blankStrings !== 'function' ||
  typeof lexCode !== 'function' ||
  typeof uncappedFanouts !== 'function' ||
  typeof AnalysisBudgetExceeded !== 'function'
) {
  process.stderr.write('wf-pin-lex: fanout-admission.js does not export the expected functions\n');
  process.exit(1);
}

const DEFAULT_BUDGET_MS = 3000;
const DEFAULT_MAX_BYTES = 2000000;

function envPositiveNumber(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function budgetMs() {
  return envPositiveNumber('WF_PIN_LEX_BUDGET_MS', DEFAULT_BUDGET_MS);
}

function maxBytes() {
  return envPositiveNumber('WF_PIN_LEX_MAX_BYTES', DEFAULT_MAX_BYTES);
}

// Test seam (see this file's own "Per-script budget" doc comment above):
// unset in every real run, so this is a no-op unless a caller deliberately
// sets it.
function faultInjectMarker() {
  const raw = process.env.WF_PIN_LEX_FAULT_INJECT;
  return raw === undefined || raw === '' ? null : raw;
}

// Test seam (same doc comment): unset in every real run.
function budgetInjectMarker() {
  const raw = process.env.WF_PIN_LEX_BUDGET_INJECT;
  return raw === undefined || raw === '' ? null : raw;
}

function normalizeKind(kind) {
  if (kind === 'comment') return 'comment';
  if (kind === '/') return 'regex';
  return 'string';
}

/**
 * `text` with every span in `literals` (lexCode()'s own [start, end, kind]
 * tuples, kind is the RAW opening-quote character or 'comment', not yet
 * normalizeKind()'d) blanked to spaces -- byte-for-byte the same blanking
 * fanout-admission.js's own lexView()/blankStrings() do internally, just
 * derived from a lex this module already ran instead of re-scanning the
 * text a second time (round 10, #1351 third adversarial pass finding 3:
 * lexOne() used to call lexCode(text) AND blankStrings(text) separately,
 * each independently re-running the same O(n) scan).
 */
function deriveBlanked(text, literals) {
  const chars = text.split('');
  for (const [start, end, kind] of literals) {
    for (let k = start; k < end; k += 1) {
      if (kind !== 'comment' || chars[k] !== '\n') chars[k] = ' ';
    }
  }
  return chars.join('');
}

// Longest an "error" reason may be for a caught-per-text exception --
// enough to identify the error class without one pathological script's
// stack-trace-shaped message dominating the per-script WARN line
// (wf-pin-audit.py prints this reason inline, one per unaudited script).
const LEXER_ERROR_MESSAGE_MAX = 200;

function lexOne(text) {
  const startedAt = Date.now();
  const cap = maxBytes();
  if (Buffer.byteLength(text, 'utf8') > cap) {
    return { error: `script exceeds ${cap} bytes` };
  }
  const budgetMarker = budgetInjectMarker();
  // Test seam (doc comment above): a marked text's budget is already spent,
  // so the hook lib's first deadline check (i === 0) throws through the real
  // budget path; every other text keeps the real budget.
  const deadline =
    budgetMarker !== null && text.includes(budgetMarker) ? startedAt - 1 : startedAt + budgetMs();
  // Every step below that can throw for THIS text alone -- the
  // fault-injection seam, lexCode(), and uncappedFanouts() -- is inside the
  // SAME try/catch, so a per-script exception can never escape lexOne()
  // into main()'s `.map()` (which would turn one pathological script into a
  // SHIM-LEVEL failure for the whole batch).
  try {
    const marker = faultInjectMarker();
    if (marker && text.includes(marker)) {
      throw new Error(`fault injected via WF_PIN_LEX_FAULT_INJECT (marker ${JSON.stringify(marker)})`);
    }
    const lexed = lexCode(text);
    if (!lexed) {
      // The hook's own lexer could not lex this text at all (an
      // unterminated string, template, comment, or regex literal). This
      // auditor fails closed here (a gate that cannot compare must fail):
      // wf-pin-audit.py routes this script through its per-script
      // unaudited path instead of silently falling back to a
      // comment-blind regex scan and reporting it clean.
      return { error: 'unlexable: unterminated string, template, comment, or regex literal' };
    }
    const spans = lexed.literals.map(([s, e, kind]) => [s, e, normalizeKind(kind)]);
    // lexCode() and blankStrings() share the SAME underlying scan
    // (fanout-admission.js's lexView()); derive the blanked view from the
    // literals already in hand instead of a second scan.
    const blanked = deriveBlanked(text, lexed.literals);
    const uncapped = uncappedFanouts(blanked, deadline);
    return { spans, blanked, uncapped };
  } catch (err) {
    if (err instanceof AnalysisBudgetExceeded) {
      return { error: `budget exceeded after ${Date.now() - startedAt} ms` };
    }
    const message = err && err.message ? err.message : String(err);
    return { error: `lexer-error: ${message.slice(0, LEXER_ERROR_MESSAGE_MAX)}` };
  }
}

function main() {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    raw += chunk;
  });
  process.stdin.on('end', () => {
    let payload;
    try {
      payload = JSON.parse(raw);
    } catch (err) {
      process.stderr.write(`wf-pin-lex: invalid JSON on stdin: ${err.message}\n`);
      process.exit(1);
      return;
    }
    if (!payload || !Array.isArray(payload.texts)) {
      process.stderr.write('wf-pin-lex: expected {"texts": [...]} on stdin\n');
      process.exit(1);
      return;
    }
    try {
      const results = payload.texts.map((text) => {
        if (typeof text !== 'string') {
          throw new Error('every entry in "texts" must be a string');
        }
        return lexOne(text);
      });
      process.stdout.write(JSON.stringify({ results }));
    } catch (err) {
      process.stderr.write(`wf-pin-lex: ${err && err.stack ? err.stack : err}\n`);
      process.exit(1);
    }
  });
}

if (require.main === module) {
  main();
}

module.exports = { lexOne };
