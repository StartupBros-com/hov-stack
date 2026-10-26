#!/usr/bin/env node
/**
 * PreToolUse Hook: fanout-admission (producer/verifier fan-out governance)
 *
 * NOT REGISTERED (dotfiles#1865): sync.sh install removes this hook from live
 * settings. Its warnings reached only the papercut store (1,030 in the 30
 * days to 2026-10-17) and nothing acted on them. The file stays because
 * scripts/lib/wf-pin-lex.js loads its lexer and uncappedFanouts() for
 * wf-pin-audit.py. The text below describes the hook as it ran.
 *
 * Enforced, at spawn time, the rule CLAUDE.md already states as prose only
 * (Model Routing -> "Workflow fan-out hygiene", since 2026-10-18 in
 * plugins/hov-stack/skills/agent-swarm/SKILL.md: "the verify fleet should not
 * outnumber its producers. 5 producers x 8-cap = 40 verifiers is a bug, not
 * thoroughness."). Issue #1284. Adversarial review of PR #1294 (reproduced
 * live against ce0af4f) found six defects in the first cut -- P1-A/B/C/D,
 * P2, P3 below fix them; see that review for the exact repros.
 *
 * A second adversarial-review pass against that already-fixed code (same
 * PR, round 2) found four more defects: findings 0/5/8 (one root cause --
 * the accounting-unit granularity below conflated "traces back to an
 * earlier producer" with "verifies it"), finding 1 (scopedMapCap() missed
 * a named intermediate `.slice()` binding), finding 7 (an unguarded
 * mkdirSync in updateState() could crash the hook -- see
 * session-state.js), and finding 9 (an uncapped fan-out never denied even
 * under the blocking opt-in). Each is marked "round 2 finding N" at its
 * fix site below.
 *
 * OPT-IN BLOCKING ONLY — default is WARN-only (log a papercut via
 * papercut-log.js's logDenial, never deny), mirroring CLAUDE_LOOP_GUARD's
 * opt-in convention (loop-guard.js:13). Set CLAUDE_FANOUT_GATE_BLOCK=1 to
 * arm blocking, and even then ONLY the Workflow path's over-ratio case can
 * deny — the Task path never denies, in any mode (decision 1 below).
 * Graduation path (round 3, refuted finding E -- CLAUDE_FANOUT_GATE_BLOCK is
 * not armed anywhere in the tree today, unlike CLAUDE_LOOP_GUARD): this
 * stays a WARN-first canary until a week of `papercut list` output shows
 * fanout-admission records landing only on genuinely over-ratio/uncapped
 * workflows, at which point CLAUDE_FANOUT_GATE_BLOCK=1 gets armed in the
 * launcher.
 *
 * -- Workflow path (tool_name === 'Workflow') -------------------------------
 * tool_input.script carries the whole JS source for one workflow run
 * (confirmed against a live transcript: one Workflow tool call == one
 * persisted script, matching wf-pin-audit.py's own docstring that scripts
 * land one-per-call under
 * ~/.claude/projects/<proj>/<session>/workflows/scripts/*.js). A RESUME call
 * carries {scriptPath, resumeFromRunId} instead, with no `script` string --
 * that case is read from disk (see readScriptFile()) rather than skipped.
 *
 * Reuses wf-pin-audit.py's own-text/nested-span technique (blank string
 * literals, find call spans via paren-counting, exclude nested spans of the
 * same kind so a child's cap/reference can't vouch for its parent, or vice
 * versa — scripts/wf-pin-audit.py:68-102). wf-pin-audit.py itself has
 * no maxItems logic (grep confirms, 2026-09-21) and only checks `.slice(`,
 * so it and this file's cap detection are related but NOT identical --
 * this file additionally resolves a schema `maxItems` cap on the producing
 * agent() call, and THIS FILE scopes cap detection to the exact expression
 * chained onto `.map(`, not a bare substring search over the whole
 * fan-out's text (a per-item `.slice(0, 200)` prompt truncation inside a
 * map callback is not a cap on the array being mapped -- P1-A). Round 3
 * finding C (corrects a false claim in this same paragraph, previously
 * "both scope cap detection..."): wf-pin-audit.py's own uncapped_fanouts()
 * does NOT do this scoping -- it still does `if ".map(" in text and
 * ".slice(" not in text`, a bare substring check over the whole unit, and
 * reads the P1-A adversarial fixture below as capped. That gap is left
 * unfixed here (out of scope for this hook's own PR) -- tracked as issue
 * #1304 (port the scoped receiver-chain detection into wf-pin-audit.py, or
 * extract one shared analyzer both call).
 *
 * PER-CALL classification (round 2 findings 0/5/8, superseding the original
 * per-UNIT rule -- a parallel()/pipeline() call is no longer the atom of
 * classification, because a single literal-list unit can hold a genuine
 * mix of both, and "traces back to an earlier producer" alone can't tell a
 * verifier fleet from an ordinary "list N things, then process each" batch
 * pipeline, which satisfies it just as well):
 *
 *   Bare agent() call, not inside any parallel/pipeline           -> PRODUCER
 *     always, regardless of what it references or says. A single agent()
 *     consuming an earlier binding (e.g. a sequential research -> fetch ->
 *     summarize pipeline) is a producer/synthesis stage, not a verifier.
 *   Every agent() call inside a parallel/pipeline fan-out (data-driven
 *     `.map(` template, or one literal call in a list)             -> VERIFIER
 *     iff (1) its own text (nested spans excluded) references an earlier
 *     binding -- DIRECT or DERIVED (findDerivedBindings() already threads a
 *     one-hop synthesis call like `const claims = mergeClaims(p1,...)` into
 *     the same lookup a direct binding uses -- finding 0 was the old
 *     literal-list check consulting direct bindings only, so a
 *     barrier-deduped variable never counted), AND (2) that text matches
 *     VERIFICATION_LEXICON_RE (below). Otherwise PRODUCER. A data-driven
 *     fan-out's per-item call template is classified ONCE and its resolved
 *     count (scopedMapCap() -- P1-A, extended by finding 1 to also resolve a
 *     named intermediate `const capped = items.list.slice(0, N)` binding, or
 *     unknown) is added to whichever side that one classification picked
 *     (finding 5 -- a capped batch-processing map must add its count to
 *     PRODUCERS, not verifiers, same as any other producer). An unresolvable
 *     cap excludes the whole unit from the ratio (P1-C; see unknownUnits
 *     below) but, per finding 9, still independently denies under the
 *     blocking opt-in (Decision 3) -- CLAUDE.md's "hard-cap every
 *     data-driven fan-out" holds regardless of the ratio. A literal-list
 *     fan-out's calls are each classified independently (finding 8 -- the
 *     old `.every()` let one unrelated call launder an entire verifier
 *     fleet as producers, or vice versa).
 *
 * DISCLOSURE: purely structural detection (call shape, binding graph) cannot
 * separate "verifies an earlier result" from "is produced from one" -- a
 * per-item map over a derived list is structurally identical either way.
 * This file resolves the ambiguity lexically (does the prompt/label text
 * actually say "verify"/"audit"/etc. -- see VERIFICATION_LEXICON_RE), which
 * is a heuristic, not a proof: a genuine verification prompt that never uses
 * one of these words is misclassified as a producer, and an ordinary prompt
 * that uses e.g. "confirm" as plain English without cross-checking anything
 * is misclassified as a verifier.
 *
 * DISCLOSURE (fan-out shape coverage, round 5 finding 3): FANOUT_RE
 * recognizes literal parallel(/pipeline(/Promise.all( calls. A `.forEach(`
 * call or a bare `for (...) {...}`/`while (...) {...}` loop wrapping
 * agent()/fan-out calls is also detected (see loopSpans() below), but only
 * given COARSE, flag-only treatment: fail-closed uncapped/unknownUnits,
 * never a producer/verifier classification, because a loop's iteration
 * count is not generally resolvable to multiply a per-item classification
 * by. Two shapes remain genuinely undetected: a brace-less single-statement
 * loop body (`for (const c of xs) await agent(...)`, no `{`), and a
 * do-while loop (`\b(?:for|while)\s*\(` never matches "do") -- both fall
 * through with zero signal, same as every other named gap in this
 * paragraph.
 *
 * DISCLOSURE (hoisted `.map()`, round 9 fix, P1-C): a `.map(...)` result
 * bound to a named intermediate variable before being passed to
 * `parallel(NAME)`/`Promise.all(NAME)`/`pipeline(NAME)` is resolved by
 * resolveHoistedMapCap(), but only ONE hop back (the identifier's OWN
 * declaration must itself be `<expr>.map(...)`-shaped). A second hop
 * (`const a = verifyPromises; parallel(a)`), a spread/multi-argument call
 * (`parallel(...verifyPromises, extra)`), or a non-`.map()`-shaped
 * intermediate one hop back (`const capped = verifyPromises.slice(0, 5);
 * parallel(capped)`, where `verifyPromises` itself is map-shaped two hops
 * back) still falls through undetected to the plain literal-list heuristic,
 * same as every other named gap in this paragraph.
 *
 * DISCLOSURE (cap resolution, pro-gate reviews of 0907f93e and cbb61dc7): a
 * `.slice()` with no end index retains an unbounded tail, so it is never
 * itself a cap -- the count stays unknown unless the sliced value is bounded
 * some other way. A schema cap is read only from the agent() call's OPTIONS
 * object (its second argument), walking each node's IMMEDIATE members along
 * the receiver's property path through that node's own `properties`, on a
 * lexed view where string, template, comment, and regex literal contents are
 * blanked (see resolveOptionsCap()). So text in a prompt, a `description`, or
 * a comment is never a key or a cap; a same-named field nested elsewhere never
 * supplies the mapped field's cap; and a node's `maxItems` counts only when
 * that node is the array -- no own `properties`, and an own `type` that is
 * absent or 'array' (JSON Schema: a type-specific assertion is a no-op on an
 * instance of another type). A later duplicate key wins, as in JavaScript. A
 * `maxItems` written as a bare option with no schema object literal is still
 * honored, only as the options object's own member and only for a fan-out
 * that maps the bound value itself. Any object on the path holding a spread, a
 * computed key, a method, or an accessor -- each of which could supply or
 * override a member unseen -- is unreadable, and an unreadable object is never
 * a cap. A slice index is a nonnegative integer literal or a name whose
 * nearest reaching declaration is exactly `const NAME = <integer>`
 * (sliceIndexValue()). What this still cannot prove, and so reports as
 * uncapped: any other slice index (a `let`/`var`, an expression, an import),
 * a schema using `$ref`/`allOf`/`anyOf`, and a schema or options object
 * assembled in a variable rather than written inline at the call. A function
 * parameter or destructured name that shadows such a const is not a
 * declaration here, so the const still resolves -- the brace-scope
 * approximation every named cap in this file makes.
 *
 * DISCLOSURE (one receiver per fan-out call, pre-existing): `dataDrivenCapText`
 * matches a SINGLE `<receiver>.map(` or `<receiver>.flatMap(` per fan-out span,
 * so only the first in a call like `parallel([a.map(f), b.map(g)])` has its
 * cap resolved and its calls counted per item. Until cbb61dc7's review the
 * second map was invisible -- no producer, verifier, uncapped, OR unknownUnit
 * (measured `producers: 12, verifiers: 4, unknownUnits: 0` on a fixture whose
 * true verifier count is 24, identical at 0907f93e). Its calls are now
 * reported as one unknown unit per sibling callback, not dropped and not
 * passed off as single calls (`unknownUnits: 1` on the same fixture). A
 * sibling is any per-element callback, whatever the method: 6a702d11 knew
 * only `.map(`, so a `.flatMap(`/`.forEach(` sibling read as one-shot calls
 * and flipped `overRatio` to false on a script over ratio at any cap. A
 * per-element callback nested inside the resolved one, or enclosing it,
 * multiplies each launch by a cap this pass does not resolve: those calls
 * are counted at the resolved cap as a lower bound and the unit is also
 * reported unknown. All of this makes the unresolved part visible without
 * counting it: `verifiers` stays 4 and `overRatio` stays false where the true
 * 24-to-12 ratio would trip it, and an unknown unit does not deny. Resolving
 * each receiver's cap per call is the real fix. A per-element method reached
 * by bracket access (`xs['map'](f)`) is not recognized at all -- its name is
 * a string, which the lexed view blanks -- so that fan-out reads as a literal
 * list; none of 3,345 real scripts on this host is written that way.
 *
 * DISCLOSURE (helpers, known and left): a callback passed BY NAME to any
 * per-element call is read at its declaration (primary, sibling, or nested).
 * A helper CALLED from a fan-out is not followed -- `xs.map(x => check(x))`,
 * `parallel([check(a), check(b)])`, a pipeline stage `x => check(x)`: its
 * agent() calls count once, at the declaration, as a top-level producer,
 * whether it runs zero times or many. That can hide an over-ratio with no
 * unknown unit. Following calls needs call-site attribution this analyzer
 * does not have; at most 31 of the 3,345 real scripts reach agent() through
 * a helper from a fan-out, and this hook only warns.
 *
 * NOTE on template-literal interpolation: real workflow scripts pass a prior
 * result into the NEXT agent's prompt via `${JSON.stringify(priorVar)}`
 * inside a template literal (confirmed against a live transcript — see
 * blankStringsKeepInterpolation() below), not via a bare identifier in plain
 * code. wf-pin-audit.py's blank_strings() erases template-literal contents
 * WHOLESALE, including any `${...}` interpolation — correct for its own
 * required:/`.slice(` checks (prompt prose must not trip them), wrong for
 * this reference check (it would make almost every real verifier invisible,
 * since the reference lives inside the prompt string). This file therefore
 * keeps a SECOND stripped view that blanks plain string/template TEXT but
 * preserves `${...}` expression code, used only for the reference check.
 *
 * -- Task path (tool_name === 'Task', the Agent tool) -----------------------
 * A single PreToolUse call has no visibility into sibling spawns, so a ratio
 * check needs cross-call state. Reuses ../lib/session-state.js's
 * updateState() (a shared, lock-protected read-modify-write -- P2; a plain
 * load-then-save race lost updates under real concurrency: 20 concurrent
 * Task invocations were measured at 10-17 of 20 recorded before this fix,
 * 3 repeated runs -- method in session-state.js's own doc comment -- round
 * 2 finding 2 corrected three conflicting single-number citations of this
 * same measurement to one measured range) to record this spawn's
 * timestamp and count spawns in the trailing CLAUDE_FANOUT_TASK_WINDOW_MS
 * (default 10min). Flags (WARN only — NEVER deny, even under the opt-in)
 * once the count exceeds CLAUDE_FANOUT_TASK_THRESHOLD (default 12).
 *
 * Decision 1 (issue #1284): there is no script to structurally verify on
 * this path, so ratio enforcement here is heuristic/log-only by design —
 * shipping a block on a bare Task spawn would be false precision.
 *
 * Tunables (env):
 *   CLAUDE_FANOUT_GATE_BLOCK       arm Workflow-path blocking   (default off)
 *   CLAUDE_FANOUT_TASK_THRESHOLD   Task spawns/window before WARN (default 12)
 *   CLAUDE_FANOUT_TASK_WINDOW_MS   Task spawn lookback window   (default 10min)
 *
 * State: ~/.claude/.fanout-state/<session_id>.json (Task path only).
 *
 * Follows the run-with-flags.js convention: exports run(rawInput).
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { deny, setDenyContext } = require('../lib/pretooluse-decision');
const { sessionKey, loadState, saveState, updateState } = require('../lib/session-state');
const { logDenial } = require('../PostToolUseFailure/papercut-log');
const { writeHookOutput } = require('../lib/hook-output');

const GATE_BLOCK = process.env.CLAUDE_FANOUT_GATE_BLOCK === '1';
const TASK_THRESHOLD = Number(process.env.CLAUDE_FANOUT_TASK_THRESHOLD || 12);
const TASK_WINDOW_MS = Number(process.env.CLAUDE_FANOUT_TASK_WINDOW_MS || 10 * 60 * 1000);
// Round 5 finding 1 (P0): defense-in-depth wall-clock budget for
// analyzeWorkflow()'s callSpans() scans, well under settings.json's
// own "timeout": 5 for this hook -- a timed-out PreToolUse hook does NOT
// block the gated tool call (see this module's doc comment), so running
// unchecked into that external kill is a silent admission bypass, not a
// safe failure. This is a BACKSTOP behind the O(n) callSpans() rewrite
// below, for any other pathological shape that rewrite doesn't anticipate.
const ANALYSIS_BUDGET_MS = Number(process.env.CLAUDE_FANOUT_ANALYSIS_BUDGET_MS || 3000);

class AnalysisBudgetExceeded extends Error {}
const TASK_STATE_DIR = path.join(os.homedir(), '.claude', '.fanout-state');
// Reap other sessions' spawn-log files after 24h of inactivity. Deliberately
// much larger than TASK_WINDOW_MS: the window is a rolling lookback trimmed
// on every write, not a liveness signal — a session idle for 11 minutes
// between Task calls is not dead, so reaping on the window itself would
// discard a still-live session's history in the ordinary course of work.
const TASK_STATE_REAP_MS = 24 * 60 * 60 * 1000;
// A Workflow RESUME call's script is read from disk (P1-D) -- capped well
// above any real workflow script so this stays a defensive bound, not a
// working limit.
const SCRIPT_FILE_READ_CAP = 1024 * 1024;

// ---------------------------------------------------------------------------
// Text-analysis primitives, related to scripts/wf-pin-audit.py's own
// (blank_strings/AGENT_RE/FANOUT_RE/call_spans/own_text technique, lines
// 40-102 as of #1284) but NOT a byte-for-byte port -- see the module doc
// comment above for the maxItems/scoping differences (P1-A/P1-B).
// blankStringsKeepInterpolation is new to this file, and both blanking views
// now come from one lexer that also knows comments and regex literals, which
// wf-pin-audit.py's quote regex does not.
// ---------------------------------------------------------------------------

const STRING_RE = /`(?:[^`\\]|\\.)*`|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/gs;

// Whether a `/` starts a regex literal rather than a division: after opening
// punctuation or an operator, or after a keyword that takes an expression --
// the previous-token rule lightweight JS tokenizers use. Two operands look
// like those tokens and are not: a postfix `++`/`--` (`n++ / 2`), and a
// keyword spelled as a property name (`stats.return / 2`). Misreading either
// as a regex blanks the code up to the next `/`, agent() calls included.
const REGEX_AFTER_CHAR = new Set(['', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>', '~', '^']);
const REGEX_AFTER_WORD = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await']);

function regexAllowedAfter(text, start, prev, prevEnd) {
  if (prev === '+' || prev === '-') return text[prevEnd - 2] !== prev;
  if (REGEX_AFTER_CHAR.has(prev)) return true;
  if (!/[\w$]/.test(prev)) return false;
  let w = prevEnd;
  while (w > start && /[\w$]/.test(text[w - 1])) w -= 1;
  if (!REGEX_AFTER_WORD.has(text.slice(w, prevEnd))) return false;
  let p = w - 1;
  while (p >= start && /\s/.test(text[p])) p -= 1;
  return !(p >= start && text[p] === '.');
}

/**
 * End index (exclusive) of the string, template, comment, or regex literal
 * starting at `i`; `i` itself when none starts there (an unclosed regex
 * candidate included); -1 when a string, template, or block comment starts
 * but never terminates. A template's `${...}` is scanned as code, so a quote or a
 * brace inside an interpolation cannot end the template early. With
 * `keepInterp`, a template reports only its literal TEXT to `onLiteral`,
 * leaving each interpolation's code visible.
 */
function literalEnd(text, i, regexAllowed, onLiteral, keepInterp) {
  const c = text[i];
  if (c === "'" || c === '"') {
    for (let j = i + 1; j < text.length; j += 1) {
      if (text[j] === '\\') j += 1;
      else if (text[j] === c) return j + 1;
      else if (text[j] === '\n') return -1;
    }
    return -1;
  }
  if (c === '`') {
    let segStart = i;
    for (let j = i + 1; j < text.length; j += 1) {
      if (text[j] === '\\') j += 1;
      else if (text[j] === '`') {
        if (keepInterp) onLiteral(segStart, j + 1, '`');
        return j + 1;
      } else if (text[j] === '$' && text[j + 1] === '{') {
        if (keepInterp) onLiteral(segStart, j, '`');
        const k = scanCode(text, j + 2, true, keepInterp ? onLiteral : null, keepInterp);
        if (k < 0) return -1;
        segStart = k;
        j = k - 1;
      }
    }
    return -1;
  }
  if (c !== '/') return i;
  if (text[i + 1] === '/') {
    const k = text.indexOf('\n', i);
    return k < 0 ? text.length : k;
  }
  if (text[i + 1] === '*') {
    const k = text.indexOf('*/', i + 2);
    return k < 0 ? -1 : k + 2;
  }
  if (!regexAllowed) return i;
  // A regex literal cannot span a line, so a candidate that does not close on
  // its own line was a division the previous-token rule misjudged (`{} / 2`).
  // Reading it as one leaves the rest of the script lexable; failing the whole
  // lex would fall back to the comment-blind quote scan.
  let inClass = false;
  for (let j = i + 1; j < text.length; j += 1) {
    const d = text[j];
    if (d === '\\') j += 1;
    else if (d === '\n') return i;
    else if (d === '[') inClass = true;
    else if (d === ']') inClass = false;
    else if (d === '/' && !inClass) {
      let k = j + 1;
      while (k < text.length && /[A-Za-z]/.test(text[k])) k += 1;
      return k;
    }
  }
  return i;
}

/**
 * Scan code from `start`, reporting each literal to `onLiteral(start, end,
 * kind)` (`kind` is its opening quote, or 'comment'). With `untilBrace`, stop
 * after the `}` closing a template interpolation and return the index past it;
 * otherwise scan to the end. -1 on anything unterminated.
 */
function scanCode(text, start, untilBrace, onLiteral, keepInterp) {
  let depth = 0;
  let prev = '';
  let prevEnd = start;
  let i = start;
  while (i < text.length) {
    const c = text[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      i += 1;
      continue;
    }
    if (c === "'" || c === '"' || c === '`' || c === '/') {
      const regexAllowed = c === '/' && regexAllowedAfter(text, start, prev, prevEnd);
      const end = literalEnd(text, i, regexAllowed, onLiteral, keepInterp);
      if (end < 0) return -1;
      if (end > i) {
        const comment = c === '/' && (text[i + 1] === '/' || text[i + 1] === '*');
        // A keepInterp template already reported its own text segments.
        if (onLiteral && !(keepInterp && c === '`')) onLiteral(i, end, comment ? 'comment' : c);
        if (!comment) {
          prev = ')'; // a literal is an operand, so a `/` after it divides
          prevEnd = end;
        }
        i = end;
        continue;
      }
    }
    if (untilBrace && c === '{') depth += 1;
    else if (untilBrace && c === '}') {
      if (depth === 0) return i + 1;
      depth -= 1;
    }
    prev = c;
    prevEnd = i + 1;
    i += 1;
  }
  return untilBrace ? -1 : text.length;
}

/**
 * `text` with every string, template, comment, and regex literal blanked to
 * spaces at unchanged offsets (a comment keeps its newlines, so line structure
 * survives), plus the literal spans so a string VALUE can still be read from
 * the raw text. Null when the text does not lex.
 */
function lexView(text, keepInterp) {
  const chars = text.split('');
  const literals = [];
  const blank = (s, e, kind) => {
    literals.push([s, e, kind]);
    for (let k = s; k < e; k += 1) {
      if (kind !== 'comment' || chars[k] !== '\n') chars[k] = ' ';
    }
  };
  let end;
  try {
    end = scanCode(text, 0, false, blank, keepInterp);
  } catch (err) {
    if (err instanceof RangeError) return null; // interpolation nesting too deep to recurse
    throw err;
  }
  if (end < 0) return null;
  return { code: chars.join(''), literals };
}

function lexCode(text) {
  return lexView(text, false);
}

/**
 * Offset-preserving blanking of every string, template, comment, and regex
 * literal. It was a quote-matching regex that knew nothing of comments, so one
 * apostrophe in `// don't` flipped quote parity for the REST of the script:
 * code was blanked, string contents were exposed, and the first agent() span
 * swallowed every fan-out after it -- the gate went blind (measured on 8 of
 * 3,339 real workflow scripts; 0 of them failed to lex). A script this cannot
 * lex falls back to that regex, so no script reads worse than before.
 */
function blankStrings(text) {
  const view = lexView(text, false);
  return view ? view.code : text.replace(STRING_RE, (m) => ' '.repeat(m.length));
}

/**
 * Same as blankStrings(), except inside a template literal each `${...}`
 * interpolation's CODE stays visible -- only the literal text around it is
 * blanked. Falls back to the pre-lexer scan below when the text does not lex.
 */
function blankStringsKeepInterpolation(text) {
  const view = lexView(text, true);
  return view ? view.code : blankStringsKeepInterpolationUnlexed(text);
}

/**
 * The pre-lexer keep-interpolation scan, kept only as the fallback for text
 * lexView() cannot lex. Quote-aware but not comment-aware.
 */
function blankStringsKeepInterpolationUnlexed(text) {
  let out = '';
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];
    if (c === '`') {
      out += ' ';
      i += 1;
      while (i < n) {
        const ch = text[i];
        if (ch === '\\' && i + 1 < n) {
          out += '  ';
          i += 2;
          continue;
        }
        if (ch === '`') {
          out += ' ';
          i += 1;
          break;
        }
        if (ch === '$' && text[i + 1] === '{') {
          out += '${';
          i += 2;
          let depth = 1;
          while (i < n && depth > 0) {
            const ic = text[i];
            if (ic === '{') depth += 1;
            else if (ic === '}') depth -= 1;
            out += ic;
            i += 1;
          }
          continue;
        }
        out += ' ';
        i += 1;
      }
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      out += ' ';
      i += 1;
      while (i < n) {
        const ch = text[i];
        if (ch === '\\' && i + 1 < n) {
          out += '  ';
          i += 2;
          continue;
        }
        if (ch === quote) {
          out += ' ';
          i += 1;
          break;
        }
        out += ' ';
        i += 1;
      }
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

const AGENT_RE = () => /\bagent\s*\(/g;
// Round 5 finding 3: Promise.all(list.map(...)) is the same data-driven
// fan-out shape as parallel(list.map(...)) -- MAP_RECEIVER_RE's unanchored
// scan over the span's own text (scopedMapCap()) already finds `<name>.map(`
// wherever it sits inside a fan-out span, so adding this one alternative was
// enough for the INLINE shape.
//
// CORRECTION (round 9, P1-C): "no other call site needs to change" was
// falsified by a round 8 adversarial reproduction -- `.map(` hoisted into a
// named intermediate variable before being passed to `parallel(NAME)` /
// `Promise.all(NAME)` (`const verifyPromises = claims.map(...); await
// parallel(verifyPromises)`) has NO `.map(` substring anywhere in the
// fan-out call's OWN text, so MAP_RECEIVER_RE's scan over that text (which is
// all scopedMapCap() ever sees) never fires, and the whole unit silently
// disappeared from producer/verifier accounting AND from
// uncapped/unknownUnits. resolveHoistedMapCap()/soleBareIdentifierArg()
// (round 9) resolve this ONE-HOP hoisted-variable shape by tracing a bare
// identifier argument back to its own declaration; see their doc comments
// for the disclosed residual gap (a second hop, a spread/multi-arg call, or
// a non-`.map()`-shaped intermediate still falls through undetected).
const FANOUT_RE = () => /\b(?:parallel|pipeline|Promise\.all)\s*\(/g;
// Round 5 finding 3: `.forEach(` is a real fan-out shape FANOUT_RE cannot
// see (it has no `parallel`/`pipeline`/`Promise.all` prefix) -- reused by
// loopSpans()'s caller (analyzeWorkflowInner) for COARSE, flag-only
// detection only (see the module DISCLOSURE paragraph above); it is
// deliberately NOT folded into FANOUT_RE itself, which still means "give
// this span full producer/verifier classification".
const FOREACH_RE = () => /\.forEach\s*\(/g;

// Round 2 review findings 5/8: word-boundary-anchored on the LEADING edge
// only (no trailing \b), so a stem matches its inflections --
// "verifies"/"verifying"/"verification" all match "verif". Case-insensitive,
// and tested against RAW (unblanked) prompt/label text -- a blanked view
// erases the very prose that carries verification intent. Round 4 finding 2:
// this list is NOT sourced from CLAUDE.md or any other doc -- an earlier
// version of this comment claimed "verif", "validat", "confirm" and
// "adversarial-first review" were drawn from CLAUDE.md's review-ladder prose,
// but grep-confirmed 2026-09-21 that "validat", "adversarial-first review",
// and "confirm" (as review vocabulary, not its other senses) do not appear
// there. The stems below are this heuristic's own review vocabulary, chosen
// for what the fanout-admission review pipeline actually says in practice
// ("the verify fleet", "refute-by-default", "fact-check", "audit",
// "cross-check", "re-derive" -- the last two also appear in project memory
// notes, e.g. schema-validates-shape-not-work.md's "pair every producer with
// a re-deriving verifier") plus a `verify:` label prefix. The list below IS
// the contract -- nothing else backs it. Combined with an earlier-binding
// reference, this is the ONLY signal that separates a verifier fleet from an
// ordinary per-item batch pipeline -- see the module doc comment's
// DISCLOSURE paragraph for what this heuristic cannot see.
const VERIFICATION_LEXICON_RE = /\b(?:verif|refut|adversar|validat|fact-check|cross-check|confirm|audit|re-derive)/i;

/**
 * Spans (start, end) of callee(...) calls in `stripped`, via paren counting.
 *
 * Round 5 finding 1 (P0): the previous implementation restarted a full
 * forward paren-balancing scan from EACH match's opening paren (round 3
 * finding A2's `re.lastIndex = afterOpenParen` resume, needed so a nested
 * call is independently discovered -- see the comment preserved below on
 * that requirement) -- for K nested calls this rescans an ever-shrinking
 * overlapping suffix K times, O(n^2) worst case. A validator-reproduced
 * 224,001-byte script of 32,000 nested `agent(` calls took ~5.3-5.7s,
 * already past settings.json's own "timeout": 5 for this hook, and a
 * timed-out PreToolUse hook does not block the gated tool call.
 *
 * Rewritten as ONE left-to-right pass over `stripped`: a single global
 * paren-depth counter plus a stack of currently-open calls (callee start
 * position + the depth value at which THIS call's own opening paren was
 * counted). A call closes the instant depth returns to that exact value
 * (LIFO -- parens are always well-nested relative to each other, regardless
 * of what unrelated code sits between a call's open and close). This finds
 * the exact same spans round 3 finding A2 needed (a call nested inside
 * another's arguments is still discovered independently, because ITS OWN
 * opening paren still gets pushed as its own stack frame the moment the
 * scan reaches it) but spans close in CLOSE order (innermost first for
 * nested calls) rather than the old MATCH order (outermost first, since an
 * outer callee's name is textually first) -- sorting the K results by start
 * position restores the exact original ordering. Sorting K matches is O(K
 * log K), never quadratic even at K=32000 (regex matching itself was never
 * the O(n^2) part -- `re.exec()` with a global flag already advances
 * monotonically forward in one O(n) pass; only the old per-match rescan
 * was quadratic).
 *
 * `deadline` (an absolute Date.now() value, optional) is this fix's other
 * half: a defense-in-depth wall-clock backstop, checked every 4096
 * characters (cheap) plus always at i===0 (so a deadline already in the
 * past is caught even on a short/empty script, needed for deterministic
 * testing) -- throws AnalysisBudgetExceeded, which analyzeWorkflow() below
 * catches and turns into a fail-closed flagged result, rather than ever
 * running unchecked into the hook's external 5s kill.
 */
function callSpans(stripped, regexFactory, deadline) {
  const re = regexFactory();
  const calls = [];
  let m = re.exec(stripped);
  while (m) {
    // re.lastIndex right after a match is exactly the index just past this
    // call's own opening paren (every regexFactory pattern here ends in a
    // literal `\(`), matching the old code's `afterOpenParen`.
    calls.push({ start: m.index, openParenEnd: re.lastIndex });
    m = re.exec(stripped);
  }

  const spans = [];
  const stack = [];
  let depth = 0;
  let callIdx = 0;
  const n = stripped.length;
  for (let i = 0; i < n; i += 1) {
    if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const c = stripped[i];
    if (c === '(') {
      depth += 1;
      if (callIdx < calls.length && calls[callIdx].openParenEnd === i + 1) {
        stack.push({ start: calls[callIdx].start, depth });
        callIdx += 1;
      }
    } else if (c === ')') {
      if (stack.length > 0 && stack[stack.length - 1].depth === depth) {
        const call = stack.pop();
        spans.push([call.start, i + 1]);
      }
      depth -= 1;
    }
  }
  // Unbalanced input (malformed/truncated script): a call whose closing
  // paren was never found spans to the end of the text, matching the old
  // per-call scan's `while (i < stripped.length && depth > 0)` falling off
  // the end with depth still > 0.
  while (stack.length > 0) {
    const call = stack.pop();
    spans.push([call.start, n]);
  }
  spans.sort((a, b) => a[0] - b[0]);
  return spans;
}

/**
 * The text of one call span with any spans NESTED inside it removed — a
 * nested call's own properties must not vouch for (or contaminate) its
 * parent's, and vice versa.
 *
 * Round 7 finding 2 (P1): this used to run an unconditional
 * `for (const inner of spans)` over the WHOLE array on every call,
 * regardless of how many entries could possibly be nested inside `span`.
 * dataDrivenCapText() calls this once per fan-out span in
 * analyzeWorkflowInner()'s main loop -- O(fanoutSpans.length *
 * (fanoutSpans.length + agentSpans.length)) overall on a FLAT script, the
 * true dominant cost behind the finding's measured numbers (re-measuring
 * AFTER fixing directAgentSpansWithin() and the two loops named in the
 * finding text showed NO improvement, which is what surfaced this).
 * `spans` is required sorted ascending by start (true of every real
 * caller: callSpans()'s own output is already sorted; dataDrivenCapText's
 * combined exclude list is now sorted once by ITS caller, not per call) --
 * a binary search finds the first entry whose start is >= `start`, and the
 * scan breaks as soon as an entry's start exceeds `end` (no further entry
 * can qualify, since all later entries have an even larger start) --
 * O(log n + k) per call, where k is the number of spans actually nested
 * inside this one.
 */
function ownText(text, span, spans) {
  const [start, end] = span;
  let cursor = start;
  const parts = [];
  let lo = 0;
  let hi = spans.length - 1;
  let first = spans.length;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (spans[mid][0] >= start) {
      first = mid;
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  for (let i = first; i < spans.length; i += 1) {
    const inner = spans[i];
    const [innerStart, innerEnd] = inner;
    if (innerStart > end) break; // sorted ascending by start: nothing further can qualify
    if (innerStart === start && innerEnd === end) continue;
    if (innerEnd > end) continue; // starts inside span but overruns it: not nested
    if (innerStart >= cursor) {
      parts.push(text.slice(cursor, innerStart));
      cursor = innerEnd;
    }
  }
  parts.push(text.slice(cursor, end));
  return parts.join('');
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// The optional `\(?` tolerates the common `const x = (await parallel(...)).filter(...)`
// wrapping shape (confirmed against a live transcript) — a plain
// `= (?:await\s+)?` would miss the binding entirely when the await
// expression is itself parenthesized before a trailing method call. Captures
// `kind` (agent/parallel/pipeline) so a later lookup can find the SPECIFIC
// call that produced a given name (P1-A's maxItems resolution needs the
// exact agent() call, not just "some earlier binding").
const BIND_RE = () =>
  /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*\(?\s*(?:await\s+)?(agent|parallel|pipeline)\s*\(/g;

/**
 * Every `NAME = (await)? (agent|parallel|pipeline)(` DIRECT binding, in
 * source order. `callStart` is the absolute index of the callee word itself
 * (e.g. "agent" in "const items = await agent(...)"), which lines up with an
 * entry in callSpans(stripped, AGENT_RE)/callSpans(stripped, FANOUT_RE).
 */
function findBoundNames(stripped) {
  const re = BIND_RE();
  const bindings = [];
  let m = re.exec(stripped);
  while (m) {
    const kind = m[2];
    const window = stripped.slice(m.index, re.lastIndex);
    const kindMatch = new RegExp(`\\b${kind}\\s*\\(`).exec(window);
    const callStart = kindMatch ? m.index + kindMatch.index : m.index;
    bindings.push({ name: m[1], pos: m.index, kind, callStart });
    m = re.exec(stripped);
  }
  return bindings;
}

// A generic `const|let|var NAME = <rest of statement>` binder, used only to
// trace ONE HOP from a plain synthesis call back to a direct agent binding
// (P1-B) -- e.g. `const claims = mergeClaims(p1, p2, p3, p4, p5)`, the exact
// shape CLAUDE.md's own "dedup findings across producers at a barrier before
// spawning verifiers" guidance recommends. Deliberately bounded to one hop:
// this is a heuristic classifier over source text, not a dataflow analysis.
//
// Round 5 finding 4: this only matches the START of the binding (through
// the `=` and its trailing whitespace) -- it deliberately does NOT try to
// capture the RHS inline the way the old GENERIC_BIND_RE's `[^;\n]*` did,
// because a single regex capture group cannot express "stop at `;`/newline,
// but only once bracket depth returns to 0" -- scanGenericBindRhs() below
// does that scan instead.
const GENERIC_BIND_START_RE = () => /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*/g;

/**
 * Round 5 finding 4: scan a generic binding's RHS starting at `start` (the
 * index right after `GENERIC_BIND_START_RE`'s own match, i.e. right after
 * `=` and its trailing whitespace), stopping at the first `;` or newline
 * found AT BRACKET DEPTH 0 -- same depth-tracking technique as
 * splitTopLevelArgs() above, minus its comma-splitting (an RHS is one
 * expression, not a comma-separated argument list). Deadline-checked the
 * same way callSpans()/braceSpans() are (round 5 finding 1): many generic
 * bindings, each with a never-terminated RHS (adversarial or just
 * malformed input), would otherwise each independently scan toward
 * end-of-text, the same O(n*bindings) blowup finding 1 fixed for
 * callSpans() -- fails closed (throws AnalysisBudgetExceeded, caught by
 * analyzeWorkflow()'s wrapper) rather than ever running unchecked.
 *
 * The bug this replaces: the old GENERIC_BIND_RE's inline `[^;\n]*` RHS
 * capture stopped at the FIRST semicolon or newline unconditionally, even
 * one embedded inside an open paren/bracket/brace -- so a real, common
 * multi-line call binding like
 *   const claims = mergeClaims(
 *     p1,
 *     p2
 *   )
 * truncated the RHS capture to the empty string right after the opening
 * paren (the newline immediately following `mergeClaims(` ended the old
 * match), so `claims` never entered derivedBindings and every later call
 * verifying it silently misclassified as an unrelated producer.
 */
function scanGenericBindRhs(text, start, deadline) {
  let depth = 0;
  for (let i = start; i < text.length; i += 1) {
    if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if ((c === ';' || c === '\n') && depth <= 0) return text.slice(start, i);
  }
  return text.slice(start);
}

/**
 * Map of name -> earliest binding position, covering every DIRECT
 * agent/parallel/pipeline binding plus every name bound (one hop) from an
 * expression that references an earlier direct binding. A data-driven
 * fan-out mapping over any name in this map, positioned after it, is
 * "mapped over an earlier agent-produced result" for P1-B's verifier rule.
 */
function findDerivedBindings(stripped, directBindings, deadline) {
  const derived = new Map();
  for (const b of directBindings) {
    if (!derived.has(b.name)) derived.set(b.name, b.pos);
  }
  const re = GENERIC_BIND_START_RE();
  let m = re.exec(stripped);
  while (m) {
    const name = m[1];
    if (!derived.has(name)) {
      const rhs = scanGenericBindRhs(stripped, re.lastIndex, deadline);
      const referencesEarlierDirect = directBindings.some(
        (b) => b.pos < m.index && new RegExp(`\\b${escapeRegExp(b.name)}\\b`).test(rhs)
      );
      if (referencesEarlierDirect) derived.set(name, m.index);
    }
    m = re.exec(stripped);
  }
  return derived;
}

// Round 2 review finding 1: a named intermediate binding's OWN `.slice(N[,
// M])` -- e.g. `const capped = items.list.slice(0, 5);` used later as
// `capped.map(...)` -- was invisible to scopedMapCap(), which only resolves
// a slice chained DIRECTLY onto `.map(`. This finds every DIRECT binding
// (BIND_RE-adjacent const/let/var, chained `.prop` segments allowed same as
// MAP_RECEIVER_RE below) whose RHS is exactly `<name>.slice(N[, M])`, mapping
// the bound name to the resolved count. A syntactic match on the binding's
// own RHS text, not a dataflow analysis -- same scoping discipline as every
// other cap check in this file. An index may be a name; sliceCount() resolves
// it only to a reaching `const NAME = <integer>`.
const NAMED_SLICE_RE = () =>
  /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\.slice\(\s*(\d+|[A-Za-z_$][\w$]*)\s*(?:,\s*(\d+|[A-Za-z_$][\w$]*)\s*)?\)/g;

function findNamedSliceCaps(stripped, allDeclarations, deadline) {
  // Round 7 finding 1 (P1): this used to be a `Map<name, count>` -- a bare
  // name-keyed lookup with no position, so a LATER same-named `.slice()`
  // binding anywhere in the whole script silently overwrote (last-write-wins
  // from this forward scan) an earlier, actually-reachable one, and every
  // consumer matched by name alone with no positional/scope check at all.
  // Each entry now carries its own `pos` so nearestPrecedingBinding() below
  // can pick the one that can actually reach a given call site (the nearest
  // PRECEDING same-named declaration, not the textually-last one in the
  // whole script).
  const caps = [];
  const re = NAMED_SLICE_RE();
  let m = re.exec(stripped);
  while (m) {
    const name = m[1];
    caps.push({ name, pos: m.index, count: sliceCount(m[2], m[3], m.index, stripped, allDeclarations, deadline) });
    m = re.exec(stripped);
  }
  return caps;
}

/**
 * Round 9 fix (P1-A): for each declaration in `positions` (source order,
 * since GENERIC_BIND_START_RE's global-flag scan only ever advances
 * forward), the character offset of the innermost enclosing `{...}` block's
 * CLOSING brace -- i.e. the last position at which ordinary JS block/
 * function scoping still lets a reference see this declaration -- or
 * `Infinity` for a declaration at the top level of the script (module
 * scope, visible for the rest of the script). One left-to-right pass over
 * `stripped`, tracking a stack of currently-open `{` indices in lockstep
 * with `positions`: O(n) total, not O(n * positions.length). This is the
 * fix for round 8's own regression: findAllDeclarationPositions() found
 * every const/let/var declaration BREADTH-wise (round 7 finding 1) but
 * never tracked which function/block body each one lived in, so
 * nearestPrecedingDeclarationPos() could resolve a reference to a
 * same-named local variable declared inside a wholly unrelated function --
 * a cap adopted from an unrelated scope, the worst outcome this file's own
 * fail-closed philosophy exists to avoid.
 *
 * This is a brace-nesting APPROXIMATION of real lexical scoping (no
 * per-declaration temporal-dead-zone/hoisting subtlety, no distinction
 * between function and block scope), the level of fidelity this file's
 * regex-based approach can support -- but it is sound for the property that
 * matters here: a declaration made inside a `{...}` block can never reach a
 * reference outside that block, and a top-level declaration reaches
 * everything after it, including inside nested function bodies (ordinary
 * closure semantics).
 */
function declarationScopeEnds(stripped, positions, deadline) {
  const braces = braceSpans(stripped, deadline);
  const ends = new Array(positions.length);
  const stack = [];
  let pi = 0;
  const n = stripped.length;
  for (let i = 0; i <= n; i += 1) {
    if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    while (pi < positions.length && positions[pi].pos === i) {
      const openIdx = stack.length > 0 ? stack[stack.length - 1] : null;
      if (openIdx === null) {
        ends[pi] = Infinity;
      } else if (braces.has(openIdx)) {
        ends[pi] = braces.get(openIdx);
      } else {
        // Unmatched open brace (malformed/truncated script): fail closed --
        // treat the declaration as unable to reach anything past itself,
        // rather than treating it as reaching everything (Infinity) the way
        // a missing/undefined value would if left unguarded.
        ends[pi] = positions[pi].pos;
      }
      pi += 1;
    }
    if (i === n) break;
    const c = stripped[i];
    if (c === '{') stack.push(i);
    else if (c === '}') stack.pop();
  }
  return ends;
}

/**
 * Round 7 finding 1 (P1): every `const|let|var NAME = ` declaration's name
 * and position, regardless of RHS shape -- including a PLAIN rebind like
 * `const capped = hugeItems.list` that carries no cap of its own. Its
 * position still matters: it shadows any earlier same-named cap-bearing
 * binding (an agent() maxItems schema, or a named `.slice()`) for every
 * reference after it, exactly as ordinary variable shadowing would.
 * nearestPrecedingBinding() below treats "the nearest same-named
 * declaration of ANY shape, whose enclosing scope reaches the reference" as
 * the one that can reach a given call site (round 9 fix, P1-A: scope
 * reachability via declarationScopeEnds() -- see that function's doc
 * comment for why round 7/8's breadth-only fix was still unsound). Reaching
 * PAST a nearer, non-cap-bearing rebind to an older, unrelated cap is
 * exactly round 7 finding 1's bug (a helper bound elsewhere with the same
 * name silently supplying a cap for a call it has nothing to do with).
 * GENERIC_BIND_START_RE already matches every const/let/var start
 * regardless of RHS -- including agent/parallel/pipeline and named-slice
 * bindings, which are both subsets of this scan.
 */
function findAllDeclarationPositions(stripped, deadline) {
  const positions = [];
  const re = GENERIC_BIND_START_RE();
  let m = re.exec(stripped);
  while (m) {
    positions.push({ name: m[1], pos: m.index });
    m = re.exec(stripped);
  }
  const scopeEnds = declarationScopeEnds(stripped, positions, deadline);
  for (let i = 0; i < positions.length; i += 1) positions[i].scopeEnd = scopeEnds[i];
  return positions;
}

/**
 * Round 7 finding 1 (P1), round 9 fix (P1-A): the nearest declaration of
 * `name` (any shape -- see findAllDeclarationPositions()) that BOTH
 * precedes `beforePos` AND has a scope that reaches it (`beforePos <
 * d.scopeEnd`, computed by declarationScopeEnds()) -- i.e. the binding that
 * can actually reach a reference at that position under ordinary
 * shadowing/rebinding semantics approximated at brace-nesting granularity.
 * Returns null if no same-named, scope-reaching declaration precedes
 * `beforePos` at all -- this now correctly excludes a same-named
 * declaration made inside a DIFFERENT function/block than the one
 * containing `beforePos` (round 8 adversarial finding: a same-named local
 * in an unrelated function used to win here purely by text proximity).
 * Callers must check whether the WINNING declaration (not just any
 * same-named binding anywhere) is cap-bearing -- see resolveNamedCap().
 *
 * Round 10 finding 2 (P2): this is a full unguarded linear scan of EVERY
 * declaration in the script, with no early exit, called PER SPAN by each of
 * resolveNamedCap(), resolveHoistedMapCap(), scopedMapCap() (transitively,
 * via resolveNamedCap()) and resolvePipelineItemsCap() (same) -- the exact
 * O(units * declarations) shape isVerifierCall()'s own per-call scan had
 * before round 9's fix, just in a sibling function round 9 didn't touch.
 * Measured 3005-3338ms (reproduced across repeated runs) against this
 * module's own 3000ms ANALYSIS_BUDGET_MS on a script with many named
 * declarations and many fan-out units resolving caps -- past the INTERNAL
 * budget but never the external hook's 5000ms timeout, so every
 * configuration still failed closed (AnalysisBudgetExceeded -> flagged
 * result, never a bypass). Fixed with the same periodic deadline check
 * `referencesEarlierBinding()` got (matching callSpans()'s own `(i & 0xfff)
 * === 0` discipline) as a fail-closed backstop -- NOT an algorithmic
 * rewrite, since (unlike isVerifierCall()'s per-call binding-name scan) this
 * scan's cost is inherent to "find the nearest name match with a
 * scope-reaching check" and there is no O(1)/O(log n) lookup that preserves
 * the existing scope semantics without a real per-name index, which is out
 * of scope for a consistency fix.
 */
function sliceSpan(start, end) {
  // A missing end index keeps an unbounded tail, and a negative index counts
  // from the end -- neither is a count this check can prove. Only two
  // nonnegative literal indexes with the end at or after the start bound it.
  if (end === null || start < 0 || end < 0 || end < start) return null;
  return end - start;
}

function nearestPrecedingDeclarationPos(name, beforePos, allDeclarations, deadline) {
  let nearestPos = -Infinity;
  let found = false;
  for (let i = 0; i < allDeclarations.length; i += 1) {
    if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const d = allDeclarations[i];
    if (d.name === name && d.pos < beforePos && d.pos > nearestPos && beforePos < d.scopeEnd) {
      nearestPos = d.pos;
      found = true;
    }
  }
  return found ? nearestPos : null;
}

// A `const NAME = ` prefix at a declaration position, and the operators that
// would carry its RHS past a newline (no ASI there: `const N = 5\n+ x` is
// `5 + x`, `const N = 5\n(f)` calls 5).
const CONST_DECL_AT_RE = () => /\bconst\s+[A-Za-z_$][\w$]*\s*=\s*/y;
const RHS_CONTINUES_RE = () => /\s*[-+*/%&|^<>?:.,=([`]/y;

/**
 * One slice index's value at `pos`: a nonnegative integer literal as written,
 * or a name whose nearest declaration reaching `pos`
 * (nearestPrecedingDeclarationPos()) is exactly `const NAME = <integer>`.
 * Anything else is null: a `let`/`var` (rebindable), an expression, a name
 * with no reaching declaration, or no position to resolve from (`pos < 0`).
 * A nearer same-named declaration shadows an outer const, as in JavaScript.
 */
function sliceIndexValue(token, pos, stripped, allDeclarations, deadline) {
  if (/^\d+$/.test(token)) return Number(token);
  if (pos < 0 || !allDeclarations) return null;
  const declPos = nearestPrecedingDeclarationPos(token, pos, allDeclarations, deadline);
  if (declPos === null) return null;
  const re = CONST_DECL_AT_RE();
  re.lastIndex = declPos;
  if (!re.exec(stripped)) return null;
  const rhs = scanGenericBindRhs(stripped, re.lastIndex, deadline);
  if (!/^\s*\d+\s*$/.test(rhs)) return null;
  const end = re.lastIndex + rhs.length;
  if (stripped[end] === '\n') {
    const cont = RHS_CONTINUES_RE();
    cont.lastIndex = end;
    if (cont.test(stripped)) return null;
  }
  return Number(rhs.trim());
}

/** A `.slice(start, end)` cap from its two index tokens; null unless both resolve (no end is an unbounded tail). */
function sliceCount(startToken, endToken, pos, stripped, allDeclarations, deadline) {
  if (endToken === undefined) return null;
  const a = sliceIndexValue(startToken, pos, stripped, allDeclarations, deadline);
  const b = sliceIndexValue(endToken, pos, stripped, allDeclarations, deadline);
  return a === null || b === null ? null : sliceSpan(a, b);
}

// ---------------------------------------------------------------------------
// Cap resolution from an agent() call's own options object (pro-gate review of
// cbb61dc7, run marker 1790102252-2278026). Every lookup below reads the
// IMMEDIATE members of one object literal, on a view where string, template,
// comment, and regex literal contents are blanked. The walk it replaces found
// "the first textual match at or after an offset" over raw text, which is a
// descendant search on a view where prose looks like code: a nested field of
// the same name could supply the mapped field's cap, a `maxItems: 1` phrase
// inside a schema `description` string was read as the keyword, a `schema: {`
// phrase inside the PROMPT could be taken for the schema, and a nested
// `items: { type: 'object' }` made a bounded array of objects look like an
// object root. Anything this cannot read exactly -- a spread, a computed key,
// a method, a value that is not one literal -- makes that object unreadable,
// and an unreadable object is never a cap.
// ---------------------------------------------------------------------------

function addMember(code, raw, start, end, members) {
  const seg = code.slice(start, end);
  if (seg.trim() === '') return true; // `{}` or a trailing comma
  let m = /^\s*([A-Za-z_$][\w$]*)\s*:/.exec(seg);
  if (m) {
    members.set(m[1], [start + m[0].length, end]);
    return true;
  }
  // A quoted key is blanked in the code view, so its colon is the first
  // non-space character; the name itself is read from the raw text.
  m = /^\s*:/.exec(seg);
  if (m) {
    const colon = start + m[0].length - 1;
    const key = /^\s*(['"])([A-Za-z_$][\w$]*)\1\s*$/.exec(raw.slice(start, colon));
    if (!key) return false;
    members.set(key[2], [colon + 1, end]);
    return true;
  }
  m = /^\s*([A-Za-z_$][\w$]*)\s*$/.exec(seg);
  if (m) {
    members.set(m[1], null); // shorthand: a value this cannot read
    return true;
  }
  return false;
}

/**
 * The immediate members of the object literal whose `{` is at `open`: a Map
 * from key to value span (null for a shorthand member). A later duplicate
 * replaces an earlier one, as in JavaScript. Null when the object is
 * unbalanced or holds a member this cannot place -- a spread, a computed key,
 * a method, an accessor -- since any of those can supply or override a
 * member unseen.
 */
function objectMembers(code, raw, open) {
  const close = matchingBracket(code, open, '{', '}');
  if (close === null) return null;
  const members = new Map();
  let depth = 0;
  let segStart = open + 1;
  for (let i = open + 1; i <= close; i += 1) {
    const c = code[i];
    if (i < close && (c === '(' || c === '[' || c === '{')) depth += 1;
    else if (i < close && (c === ')' || c === ']' || c === '}')) depth -= 1;
    else if (i === close || (c === ',' && depth === 0)) {
      if (depth !== 0) return null;
      if (!addMember(code, raw, segStart, i, members)) return null;
      segStart = i + 1;
    }
  }
  return { close, members };
}

/**
 * The `{` of a value that is exactly one object literal, else null.
 * `Object.freeze(x)` returns `x` itself, so a frozen literal is still that
 * literal; no other call is looked through, since any other function could
 * return something else.
 */
function objectLiteralAt(code, span) {
  if (!span) return null;
  let [start, end] = span;
  for (;;) {
    const open = start + code.slice(start, end).search(/\S/);
    if (open < start) return null;
    const frozen = /^Object\s*\.\s*freeze\s*\(/.exec(code.slice(open, end));
    if (!frozen) break;
    const paren = open + frozen[0].length - 1;
    const closeParen = matchingBracket(code, paren, '(', ')');
    if (closeParen === null || closeParen >= end || code.slice(closeParen + 1, end).trim() !== '') return null;
    [start, end] = [paren + 1, closeParen];
  }
  const open = start + code.slice(start, end).search(/\S/);
  if (open < start || code[open] !== '{') return null;
  const close = matchingBracket(code, open, '{', '}');
  if (close === null || close >= end || code.slice(close + 1, end).trim() !== '') return null;
  return open;
}

/** A value that is exactly a nonnegative integer literal, else null. */
function integerLiteralAt(code, span) {
  if (!span) return null;
  const text = code.slice(span[0], span[1]).trim();
  return /^\d+$/.test(text) ? Number(text) : null;
}

/** The contents of a value that is exactly one plain quoted string, else null. */
function stringLiteralAt(code, raw, literals, span) {
  if (!span) return null;
  const [start, end] = span;
  if (code.slice(start, end).trim() !== '') return null;
  const inside = literals.filter(([s, e, kind]) => s >= start && e <= end && kind !== 'comment');
  if (inside.length !== 1) return null;
  const [s, e, kind] = inside[0];
  if (kind !== "'" && kind !== '"') return null;
  const body = raw.slice(s + 1, e - 1);
  return body.includes('\\') ? null : body;
}

/**
 * The cap a schema node puts on the array it describes: its own `maxItems`,
 * and only when the node is not itself an object schema. `maxItems` is an
 * array-only assertion, a no-op on an object instance, so a node with its own
 * `properties`, or an own `type` other than 'array', bounds nothing. Only the
 * node's OWN members count: a nested `items: { type: 'object' }` describes the
 * elements, not the node.
 */
function arrayCapOf(code, raw, literals, node) {
  if (node.members.has('properties')) return null;
  if (node.members.has('type') && stringLiteralAt(code, raw, literals, node.members.get('type')) !== 'array') {
    return null;
  }
  return integerLiteralAt(code, node.members.get('maxItems'));
}

/** The `{` of an agent() call's options object -- its second argument -- or null. */
function optionsObjectOpen(code) {
  const paren = code.indexOf('(');
  if (paren < 0) return null;
  const close = matchingBracket(code, paren, '(', ')');
  if (close === null) return null;
  let depth = 0;
  let argStart = null;
  let argEnd = close;
  for (let i = paren + 1; i < close; i += 1) {
    const c = code[i];
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if (c === ',' && depth === 0) {
      if (argStart !== null) {
        argEnd = i;
        break;
      }
      argStart = i + 1;
    }
  }
  if (argStart === null) return null;
  return objectLiteralAt(code, [argStart, argEnd]);
}

/**
 * The cap an agent() call's options put on the value it binds, walked along
 * the receiver's property path (`.findings`, `.report.claims`) through each
 * node's own `properties`. Null unless every object on that path reads
 * exactly.
 */
function resolveOptionsCap(callText, propPath) {
  const lexed = lexCode(callText);
  if (!lexed) return null;
  const { code, literals } = lexed;
  const optionsOpen = optionsObjectOpen(code);
  if (optionsOpen === null) return null;
  const options = objectMembers(code, callText, optionsOpen);
  if (!options) return null;
  const schemaOpen = objectLiteralAt(code, options.members.get('schema'));
  if (schemaOpen === null) {
    // Back-compat: a `maxItems` written as a plain option with no schema
    // object literal (`agent(p, { maxItems: 40 })`). Not JSON Schema, so no
    // property path can be walked -- honor it only when the fan-out maps the
    // bound value itself. Kept so this check still recognizes every cap it
    // recognized before; it is now the options object's own member, not any
    // `maxItems:` anywhere in the call.
    return propPath ? null : integerLiteralAt(code, options.members.get('maxItems'));
  }
  let node = objectMembers(code, callText, schemaOpen);
  const segments = propPath ? propPath.slice(1).split('.').filter(Boolean) : [];
  for (const segment of segments) {
    if (!node) return null;
    const propertiesOpen = objectLiteralAt(code, node.members.get('properties'));
    if (propertiesOpen === null) return null;
    const properties = objectMembers(code, callText, propertiesOpen);
    if (!properties) return null;
    const fieldOpen = objectLiteralAt(code, properties.members.get(segment));
    if (fieldOpen === null) return null;
    node = objectMembers(code, callText, fieldOpen);
  }
  return node ? arrayCapOf(code, callText, literals, node) : null;
}

/**
 * Round 7 finding 1 (P1): resolve `name`'s cap at a reference positioned at
 * `beforePos` -- the SAME resolution `boundMaxItems()`/`derivedSliceCaps`
 * used to provide, now constrained to a binding that can actually reach
 * this position. Fails closed to null (never a stale/unrelated cap) when:
 * no same-named declaration precedes `beforePos` at all; the nearest one is
 * a plain rebind or a parallel()/pipeline() binding (no maxItems schema to
 * read); or an agent() binding's own schema has no maxItems. This is the
 * single fallback both scopedMapCap() and resolvePipelineItemsCap() call --
 * fixing one and not the other was the original P1-A fix's own gap (round 7
 * finding 1 reproduced the identical bug in both).
 */
function resolveNamedCap(name, beforePos, directBindings, agentSpans, stripped, sliceCaps, allDeclarations, deadline, propPath, rawText) {
  const nearestPos = nearestPrecedingDeclarationPos(name, beforePos, allDeclarations, deadline);
  if (nearestPos === null) return null;
  const agentBinding = directBindings.find(
    (b) => b.name === name && b.pos === nearestPos && b.kind === 'agent'
  );
  if (agentBinding) {
    const span = agentSpans.find(([s]) => s === agentBinding.callStart);
    if (!span) return null;
    // Lexed from the raw call: a schema's string VALUES (its `type`) are
    // readable only there, and resolveOptionsCap() takes all STRUCTURE from
    // its own lexed view, so no text inside a prompt, a description, or a
    // comment can become a key, a brace, or a cap.
    const source = rawText !== undefined ? rawText : stripped;
    return resolveOptionsCap(ownText(source, span, agentSpans), propPath);
  }
  const sliceCap = sliceCaps.find((c) => c.name === name && c.pos === nearestPos);
  if (sliceCap) return sliceCap.count;
  // The nearest reaching declaration is a plain rebind, or a
  // parallel()/pipeline() binding with no maxItems schema -- fail closed
  // rather than reaching past it to an older, unrelated cap.
  return null;
}

// Matches the exact receiver chain immediately, syntactically adjacent to a
// `.map(` call: an identifier, optional further `.prop` segments (so
// `items.list.map(` and `items.findings.map(` resolve their base to
// `items`), and an OPTIONAL `.slice(N)`/`.slice(a,b)` cap directly chained
// onto it. A cap or base name is scoped to THIS position only -- text
// anywhere else in the fan-out (e.g. a per-item `.slice(0, 200)` prompt
// truncation inside the map callback) cannot match here, because nothing
// else in real workflow source is immediately followed by the literal
// substring ".map(" (P1-A). `.flatMap(` is the same receiver: its callback
// runs once per item exactly like `.map(`'s, so `parallel(xs.flatMap(x =>
// [agent(a), agent(b)]))` launches two calls per item of `xs`. Recognizing
// only `.map(` read that fan-out as a two-call literal list and never
// flagged an uncapped `xs`. Group 6 is the method name. Whitespace, newlines,
// and `?.` are allowed around each dot and before the paren: a formatter
// breaks `xs.slice(0, 5).map(...)` across lines, which read as no receiver
// at all -- a capped list reported uncapped, and an uncapped `xs.map (f)` or
// `xs?.map(f)` never flagged. 28 of 3,345 real scripts on this host break a
// fan-out receiver across lines; none of those receivers is capped, so no
// real verdict changes. Group 2 (the property path) is normalized before use.
// A method reached by bracket access (`xs['map'](...)`) is NOT recognized:
// its name is inside a string, which the lexed view blanks. A slice index
// (groups 4 and 5) may be a name; sliceCount() resolves it only to a
// reaching `const NAME = <integer>`.
const MAP_RECEIVER_RE = /([A-Za-z_$][\w$]*)((?:\s*\??\.\s*[A-Za-z_$][\w$]*)*)(\s*\??\.\s*slice\s*\(\s*(\d+|[A-Za-z_$][\w$]*)\s*(?:,\s*(\d+|[A-Za-z_$][\w$]*)\s*)?\))?\s*\??\.\s*(map|flatMap)\s*\(/;
const PER_ITEM_RECEIVER_RE = /\.\s*(?:map|flatMap)\s*\(/;

/** A receiver's property path (`.a.b`) without the whitespace or `?` MAP_RECEIVER_RE allows. */
function receiverPath(text) {
  return text.replace(/[\s?]/g, '');
}

// Every call whose function argument runs once per element: Array.prototype's
// callback methods plus Array.from's map function. An agent() call inside one
// of these launches per item, whatever the method is called.
const PER_ELEMENT_CALLBACK_RE = () =>
  /\.\s*(?:map|flatMap|forEach|filter|some|every|find|findIndex|findLast|findLastIndex|reduce|reduceRight|sort)\s*\(|\bArray\s*\.\s*from\s*\(/g;

// Round 7 finding 1 (P1): findBoundAgentSpan()/boundMaxItems() used to
// resolve a maxItems schema cap by matching `name` anywhere in the whole
// script (via directBindings.find(), no position check) -- superseded by
// resolveNamedCap() above, which folds the identical maxItems-schema lookup
// into its own position-constrained resolution.

/**
 * Resolve a data-driven fan-out's cap (P1-A): the expression immediately
 * before `.map(` is `<X>.slice(N)` (count N) or `<X>.slice(a, b)` (count
 * b - a); otherwise, if the base identifier was itself produced by an
 * agent() call whose schema carries `maxItems: N`, count is N; otherwise, if
 * `derivedSliceCaps` (findNamedSliceCaps() -- round 2 finding 1) resolved a
 * `.slice()` cap for a NAMED INTERMEDIATE binding matching the base
 * identifier, count is that. Anything else -- including a cap-shaped
 * substring anywhere else in the unit's text -- is not a cap; count stays
 * null (unknown, not zero).
 */
/**
 * `span` (the fan-out call's own absolute span in `stripped`) is OPTIONAL --
 * omitted by uncappedFanouts()'s cap-only check, which never needs
 * `itemParam`/`stage`. When given, round 4 finding 4 resolves the `.map(...)`
 * callback argument itself the same way pipelineCallShape() resolves a
 * pipeline stage: an inline function-shaped literal is used as-is; a bare
 * identifier (`xs.map(checkOne)`) is resolved to its own top-level
 * declaration via resolveStageArgument()/resolveNamedFunctionDecl() so its
 * body (not the unhelpful call-site text `xs.map(checkOne)`, which carries
 * no verification-lexicon signal at all) is what the caller tests; an
 * unresolvable bare identifier is reported as `stage.unresolved: true` so
 * the caller can fail closed to an unknownUnit rather than a fabricated
 * `producers += count`. `itemParam` is now sourced from firstParamName() on
 * the resolved/inline callback text -- replacing the old regex that matched
 * the first identifier after `.map(` indiscriminately, which for a bare
 * identifier callback wrongly read the FUNCTION NAME itself
 * (`xs.map(checkOne)` -> itemParam `"checkOne"`) as if it were the per-item
 * parameter.
 */
function scopedMapCap(capText, directBindings, agentSpans, stripped, derivedSliceCaps, span, allDeclarations, deadline, rawText) {
  const m = MAP_RECEIVER_RE.exec(capText);
  if (!m) return { baseName: null, itemParam: null, count: null, stage: null };
  const baseName = m[1];
  const sliceClause = m[3];

  // Round 7 finding 1 (P1): `receiverStart` (this call's own absolute
  // position in `stripped`) is hoisted above count resolution -- it used to
  // be computed only further down, for stage lookup. The fallback cap
  // resolution below (an agent()'s own maxItems schema, or a named
  // intermediate `.slice()` binding) used to match `baseName` anywhere in
  // the WHOLE script with no position check at all: an unrelated same-named
  // binding elsewhere (before OR after this call, in this function or any
  // other) could silently supply a cap for a fan-out that has nothing to do
  // with it. `resolveNamedCap()` below constrains resolution to the nearest
  // binding that can actually reach `receiverStart`.
  const receiverStart = span ? stripped.indexOf(m[0], span[0]) : -1;

  let count = null;
  if (sliceClause) {
    count = sliceCount(m[4], m[5], receiverStart, stripped, allDeclarations, deadline);
  } else if (receiverStart !== -1) {
    count = resolveNamedCap(baseName, receiverStart, directBindings, agentSpans, stripped, derivedSliceCaps, allDeclarations, deadline, receiverPath(m[2]), rawText);
  }
  // `span` omitted, or the receiver couldn't be relocated in `stripped`:
  // `count` stays null (fails closed to unknownUnits/uncapped in the
  // caller) rather than falling back to an unscoped whole-script match.

  let stage = null;
  if (receiverStart !== -1) {
    const mapOpenParenIdx = receiverStart + m[0].length - 1;
    const mapCloseParenIdx = matchingBracket(stripped, mapOpenParenIdx, '(', ')');
    if (mapCloseParenIdx != null) {
      const refSpan = [mapOpenParenIdx + 1, mapCloseParenIdx];
      const argText = stripped.slice(refSpan[0], refSpan[1]);
      stage = resolveStageArgument(argText, refSpan, stripped);
    }
  }

  let itemParam = null;
  if (stage && !stage.unresolved) {
    itemParam = firstParamName(stage.text);
  } else if (!stage) {
    // span omitted, or the callback's own span couldn't be relocated --
    // fall back to the original inline-only heuristic.
    // m[0] ends at the method's `(`, whatever whitespace preceded it.
    const afterParen = capText.slice(m.index + m[0].length);
    const itemMatch = /^\s*\(?\s*([A-Za-z_$][\w$]*)/.exec(afterParen);
    itemParam = itemMatch ? itemMatch[1] : null;
  }
  return { baseName, itemParam, count, stage };
}

function mapReferencesItemOrBase(refText, itemParam, baseName) {
  if (itemParam && new RegExp(`\\b${escapeRegExp(itemParam)}\\b`).test(refText)) return true;
  if (baseName && new RegExp(`\\b${escapeRegExp(baseName)}\\b`).test(refText)) return true;
  return false;
}

/**
 * Round 9 fix (P1-C): the RHS expression text (and its absolute start offset
 * in `stripped`) of the `const|let|var NAME = <rhs>` declaration whose own
 * `const/let/var NAME =` prefix starts at EXACTLY `declPos` -- as returned by
 * nearestPrecedingDeclarationPos()/findAllDeclarationPositions(). A sticky
 * regex anchored at `declPos` re-matches the identical `const/let/var NAME =`
 * shape GENERIC_BIND_START_RE already matched to produce `declPos` in the
 * first place, so this is guaranteed to match here; scanGenericBindRhs()
 * (round 5 finding 4) then does the actual bracket-depth-aware RHS scan.
 * Returns null only if `declPos` is somehow stale.
 */
function declarationRhs(stripped, declPos, deadline) {
  const re = /\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*/y;
  re.lastIndex = declPos;
  const m = re.exec(stripped);
  if (!m) return null;
  return { text: scanGenericBindRhs(stripped, re.lastIndex, deadline), start: re.lastIndex };
}

/**
 * Round 9 fix (P1-C, round 8 adversarial finding): a `parallel(NAME)` /
 * `Promise.all(NAME)` fan-out whose sole argument is a bare identifier bound,
 * via an earlier statement, to a `.map(...)` result --
 *   const verifyPromises = claims.map(c => agent('verify: ' + c))
 *   await parallel(verifyPromises)
 * -- the IDENTICAL fan-out shape as inlining the `.map(` directly onto the
 * call (`parallel(claims.map(...))`), just with the array hoisted into a
 * named intermediate variable first -- ordinary, idiomatic JS. The existing
 * `capText.includes('.map(')` check (capText = the fan-out CALL's own text,
 * see dataDrivenCapText()) only ever inspects the call site itself, so a
 * hoisted `.map(` is invisible to it: the map callback's own agent() call
 * then fell through to the bare-top-level-producer loop uncounted as a
 * verifier, AND the whole unit vanished from uncapped/unknownUnits too ("a
 * .map() array bound to a variable makes the whole mechanism a no-op").
 *
 * `argName`'s nearest preceding, SCOPE-REACHING declaration (the exact same
 * nearestPrecedingDeclarationPos() resolution P1-A's fix uses, so a
 * same-named unrelated local cannot supply a wrong RHS here either) is read
 * via declarationRhs(); if that RHS text itself matches MAP_RECEIVER_RE, this
 * reuses scopedMapCap() UNCHANGED against the RHS text, passing a synthetic
 * span pinned to the RHS's own absolute position in `stripped`.
 * scopedMapCap() only ever uses `span[0]` to relocate its own regex match via
 * `stripped.indexOf(m[0], span[0])` -- and since `rhs.text` is a PLAIN
 * contiguous slice of `stripped` (scanGenericBindRhs() never excises nested
 * spans the way ownText() does for an inline capText), that indexOf search is
 * guaranteed to find the exact same match scopedMapCap() itself just matched,
 * at precisely `rhs.start + m.index` -- no separate resolution logic is
 * needed, and the inline and hoisted paths cannot drift apart.
 *
 * Returns null when `argName` has no reaching declaration, or its RHS is not
 * `.map()`-shaped -- the caller's existing literal-list handling still
 * applies, unchanged, in that case. DISCLOSED RESIDUAL GAP: this resolves
 * exactly ONE hop (`const NAME = <expr>.map(...)`); a second hop (`const a =
 * NAME; parallel(a)`), a spread/multi-argument call (`parallel(...NAME, x)`),
 * or a non-`.map()`-shaped intermediate (`const capped = NAME.slice(0, 5)`
 * where NAME is itself map-shaped) still falls through undetected to the
 * plain literal-list heuristic -- see the module DISCLOSURE paragraph.
 */
function resolveHoistedMapCap(
  argName,
  beforePos,
  directBindings,
  agentSpans,
  stripped,
  derivedSliceCaps,
  allDeclarations,
  deadline,
  rawText
) {
  const declPos = nearestPrecedingDeclarationPos(argName, beforePos, allDeclarations, deadline);
  if (declPos === null) return null;
  const rhs = declarationRhs(stripped, declPos, deadline);
  if (!rhs || !MAP_RECEIVER_RE.test(rhs.text)) return null;
  const rhsSpan = [rhs.start, rhs.start + rhs.text.length];
  const resolved = scopedMapCap(rhs.text, directBindings, agentSpans, stripped, derivedSliceCaps, rhsSpan, allDeclarations, deadline, rawText);
  return { ...resolved, rhsSpan };
}

/**
 * Round 9 fix (P1-C): true (and the identifier itself) when fan-out `span`'s
 * call has EXACTLY one top-level argument and that argument's own text
 * (trimmed) is a bare identifier -- the `parallel(verifyPromises)` /
 * `Promise.all(verifyPromises)` shape resolveHoistedMapCap() needs. Reuses
 * splitTopLevelArgs() the same way pipelineCallShape() does. Returns null for
 * any other argument shape (multiple arguments, a literal array, an inline
 * `.map(`/`.slice(` expression -- the caller's own `capText.includes('.map(')`
 * check already handles the inline case -- etc).
 */
function soleBareIdentifierArg(span, stripped) {
  const openParenIdx = stripped.indexOf('(', span[0]);
  if (openParenIdx === -1) return null;
  const argsText = stripped.slice(openParenIdx + 1, span[1] - 1);
  const rawArgs = splitTopLevelArgs(argsText);
  if (rawArgs.length !== 1) return null;
  const t = rawArgs[0].text.trim();
  return isBareIdentifierText(t) ? t : null;
}

/**
 * Round 3 finding A: the classifier's only "data-driven fan-out" signal was
 * a literal `.map(` substring, but the Workflow tool's real, currently-used
 * calling convention is `pipeline(ITEMS, stage1, stage2, ...)` -- a
 * positional array argument plus one-or-more per-item stage callbacks, with
 * no `.map(` anywhere in sight (the array-to-per-item expansion is implicit
 * in pipeline()'s own semantics). Splits a call's argument-list text on
 * TOP-LEVEL commas only (depth-tracked across `()[]{}`, safe to run on the
 * blankStrings() view since string/template content is already blanked to
 * spaces with no delimiter characters left to unbalance depth).
 */
function splitTopLevelArgs(text) {
  const args = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if (c === ',' && depth === 0) {
      args.push({ text: text.slice(start, i), start, end: i });
      start = i + 1;
    }
  }
  if (start < text.length) {
    const tail = text.slice(start);
    if (tail.trim().length > 0) args.push({ text: tail, start, end: text.length });
  }
  return args;
}

/**
 * Strip a leading `async` keyword from function-shaped text -- on a `\b`
 * (word boundary) before an optional `\s*`, not a required `\s+`.
 *
 * Round 4 finding 3: the old per-call-site strips used `\s+` (one-or-more
 * whitespace required), which missed space-less `async()=>`/`async(x)=>`
 * stages (a real corpus fixture, `pipeline([1], async()=>agent(...),
 * async(done)=>{...})`, misread as `{producers:2, verifiers:0}` because the
 * second stage fell through every branch of isFunctionArgText() to `false`,
 * reverting the whole call to the pre-round-3 bare-call heuristic). `\b`
 * before `\s*` still refuses to strip a same-prefixed IDENTIFIER like
 * `asyncCompute(...)` -- there is no word boundary between the shared
 * `c`/`C`, so the strip never fires there and `asyncCompute` is correctly
 * left as a plain identifier reference (finding 4's case), not
 * misclassified as a function literal. Factored out of isFunctionArgText()
 * and firstParamName() (finding 3) and reused by resolveNamedFunctionDecl()
 * (finding 4) so the one fix covers every caller, not just the two the
 * lens happened to cite.
 */
function stripAsyncPrefix(text) {
  return text.replace(/^async\b\s*/, '');
}

/**
 * True if an argument's own text is a function expression -- `function(...)`,
 * `function name(...)`, `(a, b) => ...`, `async (a, b) => ...`,
 * `async(a, b) => ...` (no space -- valid ES2017+ arrow syntax), or a
 * single-bare-param arrow `x => ...` (the real fixture's stage-1 shape, e.g.
 * `c => agent(...)`). Balances only the FIRST paren group itself (arrow
 * params can't nest parens without a further callback, which this heuristic
 * doesn't need to see through) rather than a generic expression parser.
 */
function isFunctionArgText(argText) {
  const t = stripAsyncPrefix(argText.trim());
  if (/^function\b/.test(t)) return true;
  if (/^[A-Za-z_$][\w$]*\s*=>/.test(t)) return true;
  if (t[0] === '(') {
    let depth = 0;
    for (let i = 0; i < t.length; i += 1) {
      if (t[i] === '(') depth += 1;
      else if (t[i] === ')') {
        depth -= 1;
        if (depth === 0) return /^\s*=>/.test(t.slice(i + 1));
      }
    }
  }
  return false;
}

/**
 * The first declared parameter name of a stage callback's own text --
 * `c => ...` yields `c`; `async (v, c) => ...` yields `v`; `async(done)=>...`
 * (no space) also yields `done`; `function name(item) {...}` (round 4
 * finding 4's resolved-declaration form -- see resolveNamedFunctionDecl())
 * also yields `item`. Used to thread a pipeline stage's
 * per-item/per-previous-result parameter into derivedBindings
 * (threadPipelineStageParams(), below) so the EXISTING per-call verifier
 * rule (isVerifierCall(), earlier-binding-reference + lexicon) can see a
 * reference to it, exactly as it already sees a `.map()` callback's own item
 * parameter.
 */
function firstParamName(stageText) {
  const t = stripAsyncPrefix(stageText.trim());
  if (/^function\b/.test(t)) {
    const openParenIdx = t.indexOf('(');
    if (openParenIdx === -1) return null;
    const closeIdx = t.indexOf(')', openParenIdx);
    const paramsText = closeIdx === -1 ? t.slice(openParenIdx + 1) : t.slice(openParenIdx + 1, closeIdx);
    const m = /^\s*([A-Za-z_$][\w$]*)/.exec(paramsText);
    return m ? m[1] : null;
  }
  if (t[0] === '(') {
    const closeIdx = t.indexOf(')');
    const paramsText = closeIdx === -1 ? t.slice(1) : t.slice(1, closeIdx);
    const m = /^\s*([A-Za-z_$][\w$]*)/.exec(paramsText);
    return m ? m[1] : null;
  }
  const m = /^\s*([A-Za-z_$][\w$]*)\s*=>/.exec(t);
  return m ? m[1] : null;
}

/** True if `text` (trimmed) is nothing but a bare identifier -- `verifyOne`,
 * not `mod.verifyOne` (property access) or `verifyOne()` (a call). */
function isBareIdentifierText(text) {
  return /^[A-Za-z_$][\w$]*$/.test(text.trim());
}

/** The index of the bracket matching `text[openIdx]` (already `open`), or
 * null if unbalanced before the end of `text`. Depth-counts only `open`/
 * `close`, same technique as callSpans()'s own paren-balancing loop. */
function matchingBracket(text, openIdx, open, close) {
  let depth = 0;
  for (let i = openIdx; i < text.length; i += 1) {
    if (text[i] === open) depth += 1;
    else if (text[i] === close) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return null;
}

/**
 * Round 5 finding 3: a global, single O(n) pass pairing every `{` with its
 * matching `}` in the WHOLE script -- same stack technique as callSpans()'s
 * round-5-finding-1 rewrite, generalized from `(`/`)` to `{`/`}` and not
 * anchored to any particular opening regex. loopSpans() below needs to
 * check "does a loop body brace open at exactly this position, and where
 * does it close" for potentially many/deeply-nested loops; looking that up
 * via a fresh LOCAL forward scan per loop header would reintroduce exactly
 * the O(n^2) blowup finding 1 fixed (just on `{` instead of `(`) once a
 * script nests many loops. Building the whole map once, in one linear pass,
 * makes every subsequent lookup O(1).
 */
function braceSpans(stripped, deadline) {
  const openToClose = new Map();
  const stack = [];
  const n = stripped.length;
  for (let i = 0; i < n; i += 1) {
    if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const c = stripped[i];
    if (c === '{') {
      stack.push(i);
    } else if (c === '}') {
      if (stack.length > 0) {
        const openIdx = stack.pop();
        openToClose.set(openIdx, i);
      }
    }
  }
  return openToClose;
}

/**
 * Round 5 finding 3: [headerStart, bodyEnd) spans for bare `for (...) {...}`
 * / `while (...) {...}` loops -- FANOUT_RE only matches literal
 * parallel(/pipeline(/Promise.all( calls, so a loop wrapping an uncapped
 * verifier fan-out was previously invisible, reporting fully compliant with
 * zero signal. The header's own `(...)` span reuses callSpans() (already
 * O(n) and deadline-checked, per finding 1 -- `for`/`while` followed by `(`
 * is exactly the shape callSpans() already balances, no new paren-matching
 * code needed); the body's `{...}` span is looked up in the global
 * braceSpans() index above, in O(1) per header, to stay overall O(n) rather
 * than O(n*headers). A sticky (`y`-flag) whitespace-skip regex from the end
 * of the header's parens finds the body's opening `{` (if any) without
 * allocating a substring per header.
 *
 * DISCLOSED GAP (also named in the module DISCLOSURE paragraph): a
 * brace-less single-statement body (`for (const c of xs) await
 * agent(...)`) is not detected -- only a `{` immediately (whitespace only)
 * after the header's closing paren counts as a loop body here. do-while is
 * not covered either (`\b(?:for|while)\s*\(` never matches "do").
 */

/**
 * Round 7 finding 2 (P1): the final producer/verifier classification loop in
 * analyzeWorkflowInner() (and the topLevelCoarseSpans filter just above it)
 * used to answer "is [qs, qe] contained in some span of this list" via
 * `list.some(([s, e]) => s <= qs && qe <= e)`, run once per query with no
 * deadline check -- O(queries * list.length), unlike callSpans()/
 * scanGenericBindRhs() (round 5 finding 1 fixed only THAT quadratic path).
 * A FLAT script of N top-level `agent()` calls plus N empty `parallel()`
 * calls -- no nesting required -- measured N=9000 -> ~2.9-3.0s and
 * N=12000 -> ~5.7s against the old `.some()` scans, exceeding both this
 * module's own 3000ms analysis budget and the external 5000ms PreToolUse
 * hook timeout, with `result.flagged` staying false throughout: a silent
 * admission bypass via hook-timeout fail-open (a timed-out PreToolUse hook
 * does not block the gated tool call).
 *
 * buildContainmentIndex()/maxEndAtOrBefore()/isContainedIn() replace that
 * scan with one sort (once per span array, not per query) plus a binary
 * search per query: sorting candidate spans by start and tracking a running
 * prefix-max of `end` means "does some candidate starting at-or-before qs
 * reach far enough to contain qe" is answered by one binary search for the
 * rightmost start <= qs, then one array lookup -- O(log n) per query,
 * O(n log n) total, instead of O(n) per query / O(n^2) total. Correct
 * regardless of whether the candidate spans themselves nest or overlap.
 */
function buildContainmentIndex(spans) {
  const sorted = [...spans].sort((a, b) => a[0] - b[0]);
  const starts = new Array(sorted.length);
  const prefixMaxEnd = new Array(sorted.length);
  let maxEnd = -Infinity;
  for (let i = 0; i < sorted.length; i += 1) {
    starts[i] = sorted[i][0];
    maxEnd = Math.max(maxEnd, sorted[i][1]);
    prefixMaxEnd[i] = maxEnd;
  }
  return { starts, prefixMaxEnd };
}

/** Largest `end` among spans indexed by `index` (buildContainmentIndex())
 * whose `start` is <= `qs`, or -Infinity if none qualify. */
function maxEndAtOrBefore(qs, index) {
  const { starts, prefixMaxEnd } = index;
  let lo = 0;
  let hi = starts.length - 1;
  let winner = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (starts[mid] <= qs) {
      winner = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return winner === -1 ? -Infinity : prefixMaxEnd[winner];
}

/** True if some span indexed by `index` fully contains [qs, qe] (some
 * (s, e) in the original array with s <= qs && qe <= e). */
function isContainedIn(qs, qe, index) {
  return maxEndAtOrBefore(qs, index) >= qe;
}

/**
 * Reverse relationship from isContainedIn(): true if [qs, qe] fully
 * contains at least one span in `startSortedSpans` (pre-sorted ascending by
 * start, once, by the caller -- see buildStartSorted() below). Binary-
 * searches for the first candidate whose start is >= qs, then scans forward
 * only while candidates' starts remain <= qe. Used by the topLevelCoarseSpans
 * `wrapsSpawn` loop, whose queried spans (topLevelCoarseSpans) are mutually
 * disjoint by construction (round 5 finding 3's own outermost-only filter),
 * so across ALL queries in that loop the scanned-forward counts sum to at
 * most `startSortedSpans.length` -- no quadratic blowup despite the inner
 * scan.
 */
function containsAny(qs, qe, startSortedSpans) {
  let lo = 0;
  let hi = startSortedSpans.length - 1;
  let first = startSortedSpans.length;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (startSortedSpans[mid][0] >= qs) {
      first = mid;
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  for (let i = first; i < startSortedSpans.length; i += 1) {
    const [s, e] = startSortedSpans[i];
    if (s > qe) break;
    if (e <= qe) return true;
  }
  return false;
}

/** Sort spans ascending by start, once, for containsAny() callers. */
function buildStartSorted(spans) {
  return [...spans].sort((a, b) => a[0] - b[0]);
}

function loopSpans(stripped, deadline) {
  const headerSpans = callSpans(stripped, () => /\b(?:for|while)\s*\(/g, deadline);
  const braces = braceSpans(stripped, deadline);
  const wsRe = /\s*/y;
  const spans = [];
  for (const [start, parenEnd] of headerSpans) {
    wsRe.lastIndex = parenEnd;
    wsRe.exec(stripped);
    const afterWsIdx = wsRe.lastIndex;
    if (stripped[afterWsIdx] !== '{') continue; // brace-less body: unsupported, see doc comment
    const closeBraceIdx = braces.get(afterWsIdx);
    if (closeBraceIdx === undefined) continue; // unbalanced braces: skip rather than guess
    spans.push([start, closeBraceIdx + 1]);
  }
  return spans;
}

/**
 * Round 4 finding 4: resolve a bare identifier used as a pipeline/map stage
 * (`pipeline(items, verifyOne)`, `xs.map(checkOne)`) to its own top-level
 * `function name(...) {...}` or `const name = (...) => {...}` / `const name
 * = function(...) {...}` declaration elsewhere in the script. Returns
 * `{ span: [start, end] }` bounding exactly the FUNCTION-SHAPED expression
 * (not the `const name =` prefix, so the result can be fed straight into
 * isFunctionArgText()/firstParamName() unchanged, exactly like an inline
 * stage argument's own text), or null when no such declaration is found.
 *
 * SCOPING LIMIT (deliberate -- matches this file's existing honesty
 * convention of an honest gap over a fabricated answer, e.g. the pipeline
 * cap doc comment's "reporting the inner fan-out's own count un-multiplied
 * is an honest undercount, not a fabricated total"): only BLOCK-BODY forms
 * (`=> { ... }` or a `function` body) are resolved -- they have an
 * unambiguous brace-matched end. A bare EXPRESSION-body arrow (`const
 * verifyOne = item => agent(item)`, no braces) has no unambiguous end
 * without a real statement parser; rather than guess a boundary that could
 * swallow unrelated later code, this returns null (unresolved), same as a
 * name with no declaration at all -- the caller fails closed to
 * unknownUnits, never to a fabricated zero or a wrong span. The lens's own
 * corpus scan found zero non-inline stage args in 297 real pipeline() calls
 * across 3331 persisted scripts, so this residual gap is believed currently
 * unreachable in practice.
 */
function resolveNamedFunctionDecl(name, stripped) {
  const fnDeclRe = new RegExp(`\\bfunction\\s+${escapeRegExp(name)}\\s*\\(`);
  let m = fnDeclRe.exec(stripped);
  if (m) {
    const start = m.index;
    const openParenIdx = stripped.indexOf('(', start);
    const closeParenIdx = matchingBracket(stripped, openParenIdx, '(', ')');
    if (closeParenIdx == null) return null;
    const braceIdx = stripped.indexOf('{', closeParenIdx);
    if (braceIdx === -1 || stripped.slice(closeParenIdx + 1, braceIdx).trim() !== '') return null;
    const closeBraceIdx = matchingBracket(stripped, braceIdx, '{', '}');
    if (closeBraceIdx == null) return null;
    return { span: [start, closeBraceIdx + 1] };
  }

  const constDeclRe = new RegExp(`\\bconst\\s+${escapeRegExp(name)}\\s*=\\s*`);
  m = constDeclRe.exec(stripped);
  if (!m) return null;
  // Skip an optional `async` prefix the same way stripAsyncPrefix() does
  // elsewhere (word-boundary then optional whitespace, so `async(x)=>` and
  // `async (x)=>` both land `rhs` right at the function-shaped expression).
  const afterEq = m.index + m[0].length;
  const strippedFromEq = stripped.slice(afterEq);
  const rhs = afterEq + (strippedFromEq.length - stripAsyncPrefix(strippedFromEq).length);

  if (stripped.startsWith('function', rhs)) {
    const openParenIdx = stripped.indexOf('(', rhs);
    if (openParenIdx === -1) return null;
    const closeParenIdx = matchingBracket(stripped, openParenIdx, '(', ')');
    if (closeParenIdx == null) return null;
    const braceIdx = stripped.indexOf('{', closeParenIdx);
    if (braceIdx === -1 || stripped.slice(closeParenIdx + 1, braceIdx).trim() !== '') return null;
    const closeBraceIdx = matchingBracket(stripped, braceIdx, '{', '}');
    if (closeBraceIdx == null) return null;
    return { span: [rhs, closeBraceIdx + 1] };
  }

  let braceIdx = null;
  if (stripped[rhs] === '(') {
    const closeParenIdx = matchingBracket(stripped, rhs, '(', ')');
    if (closeParenIdx == null) return null;
    const arrowMatch = /^\s*=>\s*/.exec(stripped.slice(closeParenIdx + 1));
    if (arrowMatch) {
      const afterArrow = closeParenIdx + 1 + arrowMatch[0].length;
      if (stripped[afterArrow] === '{') braceIdx = afterArrow;
    }
  } else {
    const bareParamMatch = /^[A-Za-z_$][\w$]*\s*=>\s*/.exec(stripped.slice(rhs));
    if (bareParamMatch) {
      const afterArrow = rhs + bareParamMatch[0].length;
      if (stripped[afterArrow] === '{') braceIdx = afterArrow;
    }
  }
  if (braceIdx == null) return null; // expression-body arrow: unresolved by design (see doc comment)
  const closeBraceIdx = matchingBracket(stripped, braceIdx, '{', '}');
  if (closeBraceIdx == null) return null;
  return { span: [rhs, closeBraceIdx + 1] };
}

/**
 * Classify one pipeline/map stage argument (round 4 finding 4): an inline
 * function-shaped literal (`unresolved: false`, span is the argument's own
 * reference span, unchanged from before this finding), a bare identifier
 * resolved to its own top-level declaration (`unresolved: false`, span is
 * the RESOLVED declaration's body so directAgentSpansWithin() finds its
 * agent() calls; `defSpan` is set so the caller can exclude that
 * declaration from top-level unit counting -- its calls now belong to this
 * fan-out's per-item accounting, not a second, separate bare-producer
 * count), or a bare identifier that cannot be resolved (`unresolved: true`
 * -- caller must fail closed to an unknownUnit, never a fabricated zero).
 */
function resolveStageArgument(argText, refSpan, stripped) {
  if (isFunctionArgText(argText)) return { text: argText, span: refSpan, unresolved: false };
  if (isBareIdentifierText(argText)) {
    const name = argText.trim();
    const decl = resolveNamedFunctionDecl(name, stripped);
    if (decl) {
      return {
        text: stripped.slice(decl.span[0], decl.span[1]),
        span: decl.span,
        unresolved: false,
        refName: name,
        defSpan: decl.span,
        refSpan,
      };
    }
    return { text: argText, span: refSpan, unresolved: true, refName: name };
  }
  return { text: argText, span: refSpan, unresolved: true };
}

/**
 * Recognizes a `pipeline(ITEMS, stage1, stage2, ...)` call's shape: two or
 * more top-level arguments with the second (the first stage) shaped like a
 * function OR a resolvable/unresolvable bare identifier reference (round 4
 * finding 4) -- distinguishing it from `pipeline(singleThunk)`-style calls
 * (if any exist) and from `parallel(...)`, which this is never called for.
 * Returns null when `span` isn't a `pipeline(` call at all, or doesn't have
 * this shape. Stage/items spans carry ABSOLUTE offsets into `stripped` (the
 * same view callSpans()/agentSpans/fanoutSpans already use), so
 * directAgentSpansWithin() can be reused unchanged against them.
 */
function pipelineCallShape(span, stripped) {
  if (!stripped.startsWith('pipeline', span[0])) return null;
  const openParenIdx = stripped.indexOf('(', span[0]);
  if (openParenIdx === -1) return null;
  const argsText = stripped.slice(openParenIdx + 1, span[1] - 1);
  const rawArgs = splitTopLevelArgs(argsText);
  if (rawArgs.length < 2) return null;
  const isStageShaped = (a) => isFunctionArgText(a.text) || isBareIdentifierText(a.text);
  if (!isStageShaped(rawArgs[1])) return null;
  const base = openParenIdx + 1;
  const itemsArg = rawArgs[0];
  const stages = rawArgs
    .slice(1)
    .filter(isStageShaped)
    .map((a) => resolveStageArgument(a.text, [base + a.start, base + a.end], stripped));
  return {
    itemsText: itemsArg.text,
    itemsSpan: [base + itemsArg.start, base + itemsArg.end],
    stages,
  };
}

// Matches a pipeline's ITEMS argument when it is exactly `<name><.chain>*
// .slice(N[, M])` -- same cap-resolution shape as MAP_RECEIVER_RE's slice
// clause, just without a trailing `.map(` (pipeline's items argument is a
// plain array expression, not itself a `.map()` call).
const PIPELINE_ITEMS_SLICE_RE = /^([A-Za-z_$][\w$]*)((?:\.[A-Za-z_$][\w$]*)*)\.slice\(\s*(\d+|[A-Za-z_$][\w$]*)\s*(?:,\s*(\d+|[A-Za-z_$][\w$]*)\s*)?\)$/;
// Matches a pipeline's ITEMS argument when it is a bare identifier (plus
// optional `.chain`), e.g. `CLAIMS` or `someObj.list` -- resolved via
// resolveNamedCap() exactly like scopedMapCap()'s fallback (round 7
// finding 1).
const PIPELINE_ITEMS_IDENT_RE = /^([A-Za-z_$][\w$]*)((?:\.[A-Za-z_$][\w$]*)*)$/;

/**
 * Resolve a `pipeline(ITEMS, ...)` call's item-count cap (finding A, mirrors
 * scopedMapCap()'s resolution order): a `.slice(N)`/`.slice(a,b)` chained
 * directly onto the items expression; else a schema `maxItems` cap on the
 * agent() call that produced the items binding; else a named intermediate
 * `.slice()` binding (findNamedSliceCaps()); else unresolvable (null, never
 * fabricated as zero) -- e.g. a bare plain-array-literal binding like
 * `const CLAIMS = [...]`, which has no agent-produced cap at all. Round 7
 * finding 1 (P1): the maxItems-schema/named-slice fallback (the
 * bare-identifier branch below) used to match `baseName` anywhere in the
 * whole script with no position check -- the identical bug scopedMapCap()
 * had. `itemsSpanStart` (this pipeline call's own items-argument position)
 * lets resolveNamedCap() constrain resolution to a binding that can
 * actually reach this call, same as scopedMapCap()'s `receiverStart`.
 */
function resolvePipelineItemsCap(itemsExprText, itemsSpanStart, directBindings, agentSpans, stripped, derivedSliceCaps, allDeclarations, deadline, rawText) {
  const t = itemsExprText.trim();
  let m = PIPELINE_ITEMS_SLICE_RE.exec(t);
  if (m) {
    return { baseName: m[1], count: sliceCount(m[3], m[4], itemsSpanStart, stripped, allDeclarations, deadline) };
  }
  m = PIPELINE_ITEMS_IDENT_RE.exec(t);
  if (m) {
    const baseName = m[1];
    const count = resolveNamedCap(baseName, itemsSpanStart, directBindings, agentSpans, stripped, derivedSliceCaps, allDeclarations, deadline, m[2], rawText);
    return { baseName, count };
  }
  return { baseName: null, count: null };
}

/**
 * Threads a pipeline's stage-callback parameters into `derivedBindings` so
 * the existing per-call verifier rule can see a reference to them as a
 * reference to "an earlier agent-produced result", exactly as it already
 * does for a `.map()` callback's item parameter. Two cases (finding A's
 * design): stage 1's item parameter is registered ONLY IF the items
 * expression's own base identifier already traces back to an earlier
 * agent-produced binding (mirroring the existing `.map()`
 * mappedFromEarlierResult check -- a plain literal array of static config
 * is NOT "an earlier result"); stage 2+'s first parameter is ALWAYS
 * registered, unconditionally, because by pipeline()'s own documented
 * semantics that parameter is always fed by the PREVIOUS stage's return
 * value -- which is itself, transitively, produced by an agent() call (the
 * per-item stage always starts with an agent() call producing the value
 * later stages consume). Mutates the SAME Map instance the rest of
 * analyzeWorkflow() reads, and only ever ADDS a binding for a name not
 * already present -- never overwrites an earlier, unrelated binding of the
 * same name (mirrors findDerivedBindings()'s own "first position wins"
 * discipline).
 */
function threadPipelineStageParams(shape, derivedBindings) {
  if (!shape) return;
  const itemsBaseMatch = /^([A-Za-z_$][\w$]*)/.exec(shape.itemsText.trim());
  const itemsBase = itemsBaseMatch ? itemsBaseMatch[1] : null;
  const itemsBaseIsDerived = itemsBase != null && derivedBindings.has(itemsBase);
  shape.stages.forEach((stage, idx) => {
    // Round 4 finding 4: an unresolved bare-identifier stage has no
    // function-shaped text to read a parameter from -- the whole unit is
    // about to be excluded as an unknownUnit in analyzeWorkflow() below, so
    // there is nothing here worth threading.
    if (stage.unresolved) return;
    const param = firstParamName(stage.text);
    if (!param || derivedBindings.has(param)) return;
    if (idx === 0) {
      if (itemsBaseIsDerived) derivedBindings.set(param, stage.span[0]);
      return;
    }
    derivedBindings.set(param, stage.span[0]);
  });
}


/**
 * Literal agent() spans DIRECTLY inside one fan-out span -- i.e. nested
 * inside `rangeSpan` but NOT further nested inside some smaller fan-out
 * span that is itself inside `rangeSpan`. Round 3 finding A2's callSpans()
 * fix makes a nested parallel()/pipeline() call independently discoverable
 * as its OWN fanoutSpan; without this exclusion, a call already counted
 * when its enclosing (smaller) fan-out span is processed on its own turn
 * through the main loop would be counted AGAIN here when the outer span is
 * processed, double-counting it. Excluding anything nested inside a
 * DIFFERENT (non-self) fanout span keeps each agent() call attributed to
 * exactly the one fan-out unit that directly contains it.
 */
/**
 * Round 7 finding 2 (P1): re-measuring the FLAT shape (N top-level agent()
 * calls + N empty parallel() calls) AFTER fixing the topLevelCoarseSpans
 * filter and the final agentSpans classification loop (both named in the
 * finding) showed NO improvement -- N=9000 still ~2.9s, N=12000 still
 * ~5.6s, byte-for-byte the same as before those edits. Re-reading this
 * whole area (per the finding's own instruction for its sibling P1-B fix:
 * "re-read that area as a whole rather than patching one branch") found the
 * actual dominant cost here: this function used to run an UNCONDITIONAL
 * `agentSpans.filter()` -- O(agentSpans.length) -- once per call, and the
 * main per-fan-out-span loop above calls it once per fanoutSpans entry --
 * O(fanoutSpans.length * agentSpans.length) overall, independent of the two
 * loops named in the finding and not fixed by fixing them.
 *
 * `agentSpansByStart` (sorted ascending by start, built once by the caller
 * via buildStartSorted()) lets a binary search find the first candidate
 * whose start falls at-or-after rangeSpan's start, then a forward scan
 * collects only candidates whose start remains inside rangeSpan -- O(log n
 * + k) per call, where k is the number of agent spans actually inside
 * rangeSpan (typically 0 or small; a FLAT script with no nesting has k=0
 * for every call, turning the whole O(n^2) term into O(n log n)).
 *
 * PR #1821 CI round 1: the `nestedInSmallerFanout` exclusion below used to
 * be a `.some()` over the WHOLE fanoutSpans array per candidate -- O(k *
 * fanoutSpans.length) per call. On the round 9 P1-B shape (N fan-outs each
 * wrapping ONE agent() call, so k=1 for every one of the N calls) that is
 * N^2 span reads, the "remaining term" the previous paragraph of this
 * comment left in place. Its CPU share is runner-dependent (it is a
 * pointer-chasing scan over a 6000-12000-element array of two-element
 * arrays, so it grows faster than the regex passes as the cache gets
 * colder): the fanout-admission.test.js guard that pins this function's
 * growth measured 2.7-3.1x at 2x input on a quiet host but 3.569x on a
 * GitHub runner (run 38660315517), past its 3.5x bound with no code change
 * -- exactly the contention failure #1803/#1814 converted the guards to
 * prevent. Replaced with `enclosingFanout` (buildEnclosingFanoutIndex(),
 * built ONCE by the caller alongside agentSpansByStart): one Map lookup per
 * candidate, so a call is O(log n + k) with no fanoutSpans term at all.
 * Measured on the same host after the change: 2.09-2.16x at 2x input, and
 * the n=6000 median fell from ~89 to ~46 CPU ms.
 */
function directAgentSpansWithin(rangeSpan, agentSpansByStart, enclosingFanout) {
  const result = [];
  let lo = 0;
  let hi = agentSpansByStart.length - 1;
  let first = agentSpansByStart.length;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (agentSpansByStart[mid][0] >= rangeSpan[0]) {
      first = mid;
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  for (let i = first; i < agentSpansByStart.length; i += 1) {
    const [s, e] = agentSpansByStart[i];
    if (s > rangeSpan[1]) break;
    if (e > rangeSpan[1]) continue; // starts inside rangeSpan but overruns it: not contained
    // "Some fan-out span other than rangeSpan, inside rangeSpan, contains
    // [s, e]" is equivalent to "the INNERMOST fan-out span containing [s, e]
    // is inside rangeSpan and is not rangeSpan itself": every fan-out span
    // containing [s, e] also contains that innermost one (see
    // buildEnclosingFanoutIndex() for why they nest), so if any qualifies,
    // the innermost does too, and the converse is immediate.
    const f = enclosingFanout.get(s);
    const nestedInSmallerFanout =
      f !== undefined &&
      !(f[0] === rangeSpan[0] && f[1] === rangeSpan[1]) &&
      rangeSpan[0] <= f[0] && f[1] <= rangeSpan[1];
    if (!nestedInSmallerFanout) result.push([s, e]);
  }
  return result;
}

/**
 * PR #1821 CI round 1 (see directAgentSpansWithin()'s doc comment): the
 * innermost fan-out span containing each agent() span, keyed by the agent
 * span's start position, computed once for the whole script so
 * directAgentSpansWithin() answers its nested-in-a-smaller-fan-out question
 * with one Map lookup instead of a `.some()` over every fan-out span.
 *
 * Both inputs come from callSpans() over the SAME blanked text: a span runs
 * from its call's regex match to the `)` that closes its own `(` under one
 * depth count, so two spans either nest or are disjoint, never cross
 * (unbalanced input keeps this too -- an unclosed call's span runs to the
 * end of the text, and any call still open inside it does the same). Hence
 * the fan-out spans containing one agent() span form a chain, "innermost" is
 * well defined, and a single merge sweep finds it: walk agent spans in start
 * order, push each fan-out span as its start is passed, pop the ones whose
 * end has been passed, and the top of the stack is the innermost open
 * fan-out. The downward walk from the top only runs past a span that does
 * not contain [s, e], which the nesting argument above says cannot happen;
 * it stays as the cheap, exact fallback rather than an assumption. O(agent
 * spans + fan-out spans) total. `agentSpansByStart` is the caller's
 * buildStartSorted(agentSpans); `fanoutSpans` is callSpans()'s output,
 * already sorted ascending by start.
 */
function buildEnclosingFanoutIndex(agentSpansByStart, fanoutSpans) {
  const byStart = new Map();
  const open = [];
  let fi = 0;
  for (let i = 0; i < agentSpansByStart.length; i += 1) {
    const [s, e] = agentSpansByStart[i];
    while (fi < fanoutSpans.length && fanoutSpans[fi][0] <= s) {
      const f = fanoutSpans[fi];
      while (open.length > 0 && open[open.length - 1][1] <= f[0]) open.pop();
      open.push(f);
      fi += 1;
    }
    while (open.length > 0 && open[open.length - 1][1] <= s) open.pop();
    for (let j = open.length - 1; j >= 0; j -= 1) {
      const f = open[j];
      if (f[0] <= s && e <= f[1]) {
        byStart.set(s, f);
        break;
      }
    }
  }
  return byStart;
}

/**
 * Round 3 finding B: the old `capText.includes('.map(')` check (and
 * scopedMapCap's own regex scan) ran over a fan-out span's WHOLE own text,
 * including the text of any literal agent() call nested directly inside it
 * -- so an incidental `.map(` used only to build a PROMPT string (e.g.
 * `tags.map(t=>t).join(',')` folded into one verify call's own argument
 * text, nothing to do with a data-driven fan-out) reads the whole unit as
 * data-driven, and scopedMapCap can then substitute a same-named EARLIER
 * maxItems-capped binding's count for the true literal-call count. Fix:
 * decide data-driven-ness (and resolve the cap) on the unit's OWN
 * array-expression text only, after excising BOTH nested fan-out spans (as
 * before) AND nested agent() call spans -- mirrors ownText()'s existing
 * nested-span exclusion, just fed a wider exclusion set.
 */
function dataDrivenCapText(text, span, sortedExclude) {
  return ownText(text, span, sortedExclude);
}

/**
 * The argument spans of every per-element callback call (PER_ELEMENT_CALLBACK_RE)
 * inside `span`, in source order. Scans only `span`'s own text, so the cost is
 * bounded by the fan-out, not the script.
 */
function perElementArgumentSpans(stripped, span) {
  const text = stripped.slice(span[0], span[1]);
  const result = [];
  const re = PER_ELEMENT_CALLBACK_RE();
  let m = re.exec(text);
  while (m) {
    const open = m.index + m[0].length - 1;
    const close = matchingBracket(text, open, '(', ')');
    if (close !== null) result.push([span[0] + open, span[0] + close + 1]);
    m = re.exec(text);
  }
  return result;
}

/**
 * The per-element callbacks around one resolved receiver callback, for the
 * inline branch (`scopeSpan` = the fan-out call) and the hoisted one
 * (`scopeSpan` = the `const tasks = ...` right-hand side) alike:
 * - `nested`: per-element spans in the callback's OWN text. A callback passed
 *   by name has its body at its declaration, outside `scopeSpan`.
 * - `siblings`: per-element spans elsewhere in `scopeSpan` -- per item of a
 *   list whose cap this pass never resolves.
 * - `enclosed`: whether a per-element callback other than the receiver's own
 *   argument list contains the callback, i.e. multiplies it again. The
 *   smallest span containing the callback is the receiver's own.
 * - `namedNested` / `namedSiblings` (index-parallel to `siblings`): the
 *   declarations of callbacks passed BY NAME (`extra.map(checkOther)`). Their
 *   agent() calls sit at the declaration, outside every span above, so a
 *   caller that only scanned the spans saw none and the final top-level loop
 *   counted the declaration once as a producer, however often it ran.
 * `siteSpan` is where the callback is passed. It differs from `callbackSpan`
 * only for a callback passed by name, whose body is at its declaration: the
 * sibling and enclosing checks read the site, the nested check the body.
 */
function perElementContext(stripped, scopeSpan, callbackSpan, siteSpan = callbackSpan) {
  const inScope = perElementArgumentSpans(stripped, scopeSpan);
  const contains = ([s, e]) => s <= siteSpan[0] && siteSpan[1] <= e;
  const inside = ([s, e]) => siteSpan[0] <= s && e <= siteSpan[1];
  const nested = perElementArgumentSpans(stripped, callbackSpan);
  const siblings = inScope.filter((p) => !inside(p) && !contains(p));
  return {
    nested,
    siblings,
    enclosed: inScope.filter(contains).length > 1,
    namedNested: nested.flatMap((p) => namedCallbackDecls(stripped, p)),
    namedSiblings: siblings.map((p) => namedCallbackDecls(stripped, p)),
  };
}

/** Declaration spans of the bare-identifier arguments of one per-element call. */
function namedCallbackDecls(stripped, argSpan) {
  const decls = [];
  for (const a of splitTopLevelArgs(stripped.slice(argSpan[0] + 1, argSpan[1] - 1))) {
    if (!isBareIdentifierText(a.text)) continue;
    const decl = resolveNamedFunctionDecl(a.text.trim(), stripped);
    if (decl) decls.push(decl.span);
  }
  return decls;
}

/** Index of the first span in `spans` containing `call`, or -1. */
function containingIndex(spans, call) {
  return spans.findIndex(([s, e]) => s <= call[0] && call[1] <= e);
}

/**
 * Spans of parallel/pipeline calls that `.map()` a list with no resolvable
 * cap (scopedMapCap() — P1-A, extended by finding 1). Flagged on its own
 * terms regardless of the unit's producer/verifier classification.
 *
 * `deadline` (an absolute Date.now() value, optional) is threaded through to
 * callSpans()/findAllDeclarationPositions()/scopedMapCap() exactly as
 * analyzeWorkflowInner() does for its own equivalent loop, plus the same
 * periodic per-span checkpoint -- round 9/#1351's own threading fixed
 * analyzeWorkflow()'s path, but this EXPORTED entry point (the only one
 * wf-pin-lex.js calls) had no deadline parameter at all, so every deadline
 * check inside the chain below always saw `undefined` and never fired,
 * however large the script. Omitted (the default), this is unchanged from
 * before -- every existing in-process caller keeps running with no deadline.
 */
function uncappedFanouts(stripped, deadline) {
  const spans = callSpans(stripped, FANOUT_RE, deadline);
  const directBindings = findBoundNames(stripped);
  const agentSpans = callSpans(stripped, AGENT_RE, deadline);
  const allDeclarations = findAllDeclarationPositions(stripped, deadline);
  const derivedSliceCaps = findNamedSliceCaps(stripped, allDeclarations, deadline);
  // Round 7 finding 2 (P1): built once here, not per span inside the loop
  // below -- see dataDrivenCapText()'s own doc comment.
  const sortedExclude = [...spans, ...agentSpans].sort((a, b) => a[0] - b[0]);
  const flagged = [];
  for (let idx = 0; idx < spans.length; idx += 1) {
    if (deadline !== undefined && (idx & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const span = spans[idx];
    const capText = dataDrivenCapText(stripped, span, sortedExclude);
    if (!PER_ITEM_RECEIVER_RE.test(capText)) continue;
    // Round 7 finding 1 (P1): `span` (and now `allDeclarations`) must be
    // passed through so scopedMapCap()'s fallback resolution is
    // position-constrained here too -- this call used to omit `span`
    // entirely, which scopedMapCap() then treated as "receiver
    // unrelocatable" and skipped the position check, not as "no cap
    // exists".
    const { count } = scopedMapCap(capText, directBindings, agentSpans, stripped, derivedSliceCaps, span, allDeclarations, deadline, stripped);
    if (count == null) flagged.push(span);
  }
  return flagged;
}

/**
 * Classify every agent() spawn in a Workflow script as PRODUCER or VERIFIER
 * and total each side, plus any uncapped data-driven fan-outs. See the
 * module doc comment above for the full PER-CALL classification rule (round
 * 2 findings 0/5/8) and the per-unit ratio exclusion (P1-C).
 *
 * Accounting is per CALL, not per parallel()/pipeline() unit (finding 8): a
 * bare agent() call not nested inside any parallel/pipeline call is always
 * its own producer (count 1). Inside a fan-out, a data-driven map's one
 * per-item call TEMPLATE is classified once and its resolved cap (or
 * "unknown") applies to the whole map; a literal-list fan-out's calls are
 * each classified independently. A data-driven fan-out whose cap can't be
 * resolved has an unknowable spawn count -- rather than silently treating
 * "unknown" as zero (which would fabricate a ratio verdict), OR disabling
 * the ratio check for the whole script the instant any one unit is
 * unresolvable (the P1-C bug), that ONE unit is excluded from the
 * producer/verifier sums and counted in `unknownUnits`. It is still flagged
 * on its own terms via `uncapped`, so nothing goes unreported -- and, per
 * finding 9, it can independently deny under the blocking opt-in regardless
 * of the ratio (Decision 3).
 */
function analyzeWorkflow(scriptText, options) {
  // Round 5 finding 1 (P0): `options.budgetMs` lets a test force an
  // already-past deadline deterministically (no large fixture needed --
  // callSpans() checks the deadline at its very first iteration); run()'s
  // one real call site passes no options and gets the env-var tunable.
  const budgetMs = options && typeof options.budgetMs === 'number' ? options.budgetMs : ANALYSIS_BUDGET_MS;
  const deadline = Date.now() + budgetMs;
  try {
    return analyzeWorkflowInner(scriptText, deadline);
  } catch (err) {
    if (!(err instanceof AnalysisBudgetExceeded)) throw err;
    // Fail closed: could not finish structural analysis, so treat the
    // WHOLE script as one unresolvable/uncapped unit rather than silently
    // returning a clean-looking result -- see run()'s own handling of
    // `flagged` for how this surfaces as a WARN (or a deny under the
    // blocking opt-in).
    return {
      producers: 0,
      verifiers: 0,
      overRatio: false,
      uncapped: [[0, scriptText.length]],
      unknownUnits: 1,
      flagged: true,
    };
  }
}

function analyzeWorkflowInner(scriptText, deadline) {
  const stripped = blankStrings(scriptText);
  const strippedKeepInterp = blankStringsKeepInterpolation(scriptText);
  const agentSpans = callSpans(stripped, AGENT_RE, deadline);
  const fanoutSpans = callSpans(stripped, FANOUT_RE, deadline);
  // Round 5 finding 3: `.forEach(` calls and bare for/while loops are a
  // SEPARATE, coarse-only signal from fanoutSpans above -- see the module
  // DISCLOSURE paragraph and loopSpans()'s own doc comment. Computed here,
  // up front, alongside the other spans, but folded into the main loop's
  // accounting further down (after fanoutSpans/pipelineShapes are fully
  // resolved) rather than merged into fanoutSpans itself, since a coarse
  // span must never receive the FINE per-item producer/verifier
  // classification fanoutSpans entries get below.
  const coarseSpans = [...callSpans(stripped, FOREACH_RE, deadline), ...loopSpans(stripped, deadline)];
  const directBindings = findBoundNames(stripped);
  const derivedBindings = findDerivedBindings(stripped, directBindings, deadline);
  // Round 7 finding 1 (P1): every const/let/var declaration's name+position,
  // regardless of RHS shape -- feeds resolveNamedCap()'s position/shadow
  // check for both scopedMapCap() and resolvePipelineItemsCap() below.
  // Round 9 (P1-A): `deadline` threaded through so declarationScopeEnds()'s
  // own O(n) pass is budget-checked like every other full-script scan here.
  const allDeclarations = findAllDeclarationPositions(stripped, deadline);
  const derivedSliceCaps = findNamedSliceCaps(stripped, allDeclarations, deadline);
  // Round 3 finding A: detect pipeline(ITEMS, stage1, stage2, ...) shapes
  // among fanoutSpans BEFORE allBindings is assembled below, and thread
  // each stage's own parameter into derivedBindings (threadPipelineStageParams) --
  // this must run first so the per-call verifier rule can see a stage
  // callback's parameter as a reference to an earlier agent-produced
  // result, exactly like it already does for a `.map()` callback's item
  // parameter. `pipelineShapes` stays index-parallel to `fanoutSpans` so the
  // main loop below can look up "is this span a recognized pipeline
  // fan-out" without re-deriving it.
  const pipelineShapes = fanoutSpans.map((span) => pipelineCallShape(span, stripped));
  for (const shape of pipelineShapes) threadPipelineStageParams(shape, derivedBindings);
  // Round 4 finding 4: every RESOLVED bare-identifier stage's own top-level
  // declaration span -- e.g. `function verifyOne(item) {...}` referenced as
  // `pipeline(items, verifyOne)` -- gets its agent() calls folded into this
  // stage's per-item accounting below. Collected once, up front, so the
  // final bare-top-level agentSpans loop (below) can exclude these spans
  // from top-level producer counting; without this exclusion the same
  // declaration's calls would ALSO be counted there as an ordinary,
  // un-multiplied top-level producer -- the exact double-count the finding
  // described.
  const resolvedStageDefSpans = [];
  for (const shape of pipelineShapes) {
    if (!shape) continue;
    for (const stage of shape.stages) {
      if (!stage.unresolved && stage.defSpan) resolvedStageDefSpans.push(stage.defSpan);
    }
  }
  // Every direct AND derived binding as one flat {name, pos} list --
  // derivedBindings is already seeded with every direct binding too (see
  // findDerivedBindings()), so this single list is exactly what the per-call
  // rule's "references an earlier binding, direct OR derived" check
  // (finding 0) needs.
  const allBindings = Array.from(derivedBindings, ([name, pos]) => ({ name, pos }));

  const uncapped = [];
  let unknownUnits = 0;
  let producers = 0;
  let verifiers = 0;

  // Round 9 fix (P1-B): isVerifierCall() below used to run
  // `allBindings.filter((b) => b.pos < litSpan[0])` -- an unconditional
  // O(bindings) scan -- then `.some()` compiling and testing a FRESH
  // `\bname\b` regex per surviving binding against refText: O(bindings)
  // work, twice over, once per literal fan-out call, with no deadline check
  // at all. This was a FOURTH quadratic path in this file (see
  // callSpans()/round 5 finding 1, directAgentSpansWithin()/round 7 finding
  // 2, and dataDrivenCapText()'s per-span exclude-list construction/round 7
  // finding 2 for the three earlier ones, each fixed the same way: find the
  // O(n) work hiding inside a per-call loop and hoist it out). A script of N
  // sequential `const p_i = await agent(...); await
  // parallel([agent('verify: ' + String(p_i))])` pairs measured ~5.8s at
  // N=6000 and ~11.5s at N=8000 wall time -- both past settings.json's
  // 5000ms external PreToolUse timeout for this hook, and a timed-out
  // PreToolUse hook does NOT block the gated tool call (see this module's
  // own top-of-file doc comment). This module's internal 3000ms
  // ANALYSIS_BUDGET_MS fires too late to matter here, because the deadline
  // was never checked inside THIS scan specifically -- the outer per-span
  // loop's own `(idx & 0xfff) === 0` check only runs BETWEEN fanoutSpans
  // entries, and a single flat script's worth of literal-list calls can
  // blow the whole budget between two such checks.
  //
  // Fix: `\bname\b` matching some binding's name inside refText is exactly
  // equivalent to "refText contains a maximal identifier substring equal to
  // name" -- an identifier's own word-boundary IS its start/end -- so
  // instead of testing every earlier binding's name against refText, this
  // tokenizes refText ONCE into its maximal identifier runs and looks each
  // one up in `earliestBindingPos` (built ONCE below, outside the per-call
  // loop: name -> the SMALLEST position at which any binding with that name
  // occurs -- sufficient because isVerifierCall's own contract is just "does
  // SOME earlier binding of this name exist", not which declaration of it
  // reaches this position lexically; P1-A's scope-aware resolution is a
  // separate, position-constrained CAP lookup with different semantics and
  // is not a fit for this looser reference check). Cost per call is now
  // O(refText length) -- refText is one agent() call's own prompt text, not
  // the whole script -- independent of the total binding count.
  const earliestBindingPos = new Map();
  for (const b of allBindings) {
    const prev = earliestBindingPos.get(b.name);
    if (prev === undefined || b.pos < prev) earliestBindingPos.set(b.name, b.pos);
  }
  const IDENTIFIER_TOKEN_RE = /[A-Za-z_$][\w$]*/g;
  function referencesEarlierBinding(refText, beforePos) {
    if (earliestBindingPos.size === 0) return false;
    IDENTIFIER_TOKEN_RE.lastIndex = 0;
    let m = IDENTIFIER_TOKEN_RE.exec(refText);
    let i = 0;
    while (m) {
      // Backstop deadline check for a single pathologically long refText
      // (matching this file's existing discipline, e.g. callSpans()'s own
      // `(i & 0xfff) === 0` check) -- not the main fix (the main fix is that
      // this loop's length no longer depends on the total binding count),
      // but required so a worst-case refText can't itself become an
      // unbounded scan.
      if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
        throw new AnalysisBudgetExceeded();
      }
      const pos = earliestBindingPos.get(m[0]);
      if (pos !== undefined && pos < beforePos) return true;
      m = IDENTIFIER_TOKEN_RE.exec(refText);
      i += 1;
    }
    return false;
  }

  // Round 2 findings 0/5/8's per-call rule: references an earlier binding
  // (checked against the interpolation-preserving stripped view, so a
  // reference inside a template literal's `${...}` still counts) AND
  // matches the verification lexicon (checked against RAW, unblanked text --
  // prompt words live inside string literals, which every stripped view
  // blanks).
  function isVerifierCall(litSpan, spans) {
    const refText = ownText(strippedKeepInterp, litSpan, spans);
    const rawText = ownText(scriptText, litSpan, spans);
    return referencesEarlierBinding(refText, litSpan[0]) && VERIFICATION_LEXICON_RE.test(rawText);
  }

  // Round 7 finding 2 (P1): sorted once, reused by every
  // directAgentSpansWithin() call in this loop instead of each call
  // re-scanning the whole agentSpans array -- see that function's own doc
  // comment for why this loop (not just the two loops fixed further down)
  // was the actual dominant cost on the FLAT-shape regression.
  const agentSpansByStart = buildStartSorted(agentSpans);
  // PR #1821 CI round 1: likewise built once -- the innermost fan-out span
  // around each agent() call -- so the nested-in-a-smaller-fan-out exclusion
  // inside directAgentSpansWithin() is a Map lookup, not a scan of
  // fanoutSpans per nested call (see that function's doc comment).
  const enclosingFanout = buildEnclosingFanoutIndex(agentSpansByStart, fanoutSpans);
  // Whether any of `decls` (callbacks passed by name, see perElementContext())
  // launches an agent() call directly. Each one that does is kept out of the
  // final top-level loop: the fan-out that runs it reports it instead.
  function claimAgentDecls(decls) {
    const hits = decls.filter((d) => directAgentSpansWithin(d, agentSpansByStart, enclosingFanout).length > 0);
    resolvedStageDefSpans.push(...hits);
    return hits.length > 0;
  }
  // Round 7 finding 2 (P1): built once here, not per fan-out span inside
  // the loop below -- see dataDrivenCapText()'s own doc comment; this was
  // the actual dominant cost behind the finding's measured FLAT-shape
  // numbers, independent of directAgentSpansWithin() and the two loops
  // named in the finding text.
  const dataDrivenExclude = [...fanoutSpans, ...agentSpans].sort((a, b) => a[0] - b[0]);
  for (let idx = 0; idx < fanoutSpans.length; idx += 1) {
    if (deadline !== undefined && (idx & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const span = fanoutSpans[idx];
    const pipelineShape = pipelineShapes[idx];

    if (pipelineShape) {
      // Round 3 finding A: pipeline(ITEMS, stage1, stage2, ...) is treated
      // as one data-driven fan-out over ITEMS, capped the same way
      // scopedMapCap() resolves a `.map()`'s cap (resolvePipelineItemsCap
      // mirrors its resolution order exactly). An unresolvable cap excludes
      // the WHOLE pipeline unit -- every stage's own direct agent() calls,
      // not just stage 1's -- from the producer/verifier sums, mirroring
      // the existing P1-C `.map()` precedent (`continue` below); it is
      // still flagged in `uncapped`/`unknownUnits` so nothing goes
      // unreported. DISCLOSED SCOPING LIMIT: a fan-out independently
      // discovered NESTED inside one of this pipeline's stages (via the
      // A2 callSpans() fix) is still classified on its OWN terms as its own
      // fanoutSpans entry below -- it is NOT re-scaled by this outer
      // pipeline's (here, unknown) item cap, which would undercount the
      // true total in a script like the one this fix was built against
      // (verify-doc-drift-wf_fe54ed4d-826.js: true spawn count is roughly
      // 6x the 10 this reports, because the outer CLAIMS/LENSES caps are
      // themselves unresolvable plain array literals). Multiplying a
      // resolved inner cap by an unresolved outer one would fabricate a
      // specific wrong number; reporting the inner fan-out's own count
      // un-multiplied is an honest undercount, not a fabricated total.
      const { count } = resolvePipelineItemsCap(
        pipelineShape.itemsText,
        pipelineShape.itemsSpan[0],
        directBindings,
        agentSpans,
        stripped,
        derivedSliceCaps,
        allDeclarations,
        deadline,
        scriptText
      );
      // Round 4 finding 4: a stage that is a bare identifier with no
      // resolvable declaration (resolveStageArgument() returned
      // `unresolved: true`) has no body this heuristic can see agent()
      // calls inside -- crediting it as zero producers/verifiers would be
      // the exact "fabricated zero" this file's own conventions reject
      // elsewhere (see resolveNamedFunctionDecl()'s doc comment). Fail
      // closed for the WHOLE pipeline unit, same shape as an unresolvable
      // item cap just above.
      //
      // Round 5 finding 2: `uncapped` means "the numeric cap itself could
      // not be resolved" (see the module doc comment's DISCLOSURE
      // paragraph and this function's own doc comment above) -- it must
      // NOT ALSO grow when the cap resolved fine but a stage's BODY is
      // separately unresolvable; those are different problems with
      // different remedies (add a cap vs. make the stage resolvable), and
      // conflating them denied already-compliant code under the blocking
      // opt-in with a reason claiming "no .slice(N)/maxItems cap" on code
      // that has one. An unresolved-body-but-resolved-cap unit is still
      // excluded from the producer/verifier sums (same fail-closed
      // "unknowable, don't fabricate a classification" rule) and still
      // visible via unknownUnits and its own accurate reason line in
      // run() -- it just does not fabricate a false uncapped claim, and
      // (per Decision 3, which names only overRatio/uncapped as
      // independently-denying conditions) does not independently deny.
      const hasUnresolvedStage = pipelineShape.stages.some((s) => s.unresolved);
      if (count == null) {
        uncapped.push(span);
        unknownUnits += 1;
        continue;
      }
      if (hasUnresolvedStage) {
        unknownUnits += 1;
        continue;
      }
      for (const stage of pipelineShape.stages) {
        const literals = directAgentSpansWithin(stage.span, agentSpansByStart, enclosingFanout);
        for (const litSpan of literals) {
          if (isVerifierCall(litSpan, agentSpans)) verifiers += count;
          else producers += count;
        }
      }
      continue;
    }

    const capText = dataDrivenCapText(stripped, span, dataDrivenExclude);
    const isDataDriven = PER_ITEM_RECEIVER_RE.test(capText);

    if (isDataDriven) {
      const { baseName, itemParam, count, stage } = scopedMapCap(
        capText,
        directBindings,
        agentSpans,
        stripped,
        derivedSliceCaps,
        span,
        allDeclarations,
        deadline,
        scriptText
      );
      // Round 10 finding 1 (P1): a RESOLVED bare-identifier callback's own
      // declaration lives OUTSIDE this fan-out's own span -- its exclusion
      // from the final bare-top-level agentSpans loop (so its agent() call
      // isn't double-counted as a second, separate top-level producer) must
      // be recorded HERE, before either early-`continue` below, not after
      // them. An unresolvable cap (`count == null`) or an unresolvable
      // stage body are BOTH still-external-declaration cases -- the
      // callback's own defSpan is exactly as much "not this span" whether
      // or not its cap or lexicon check ever run. Recording it only on the
      // path that falls through past both continues silently left it
      // un-excluded on the other two, restoring it as a phantom top-level
      // producer that corrupts the overRatio signal (reproduced against
      // 0e1c021).
      const resolvedElsewhere = stage && !stage.unresolved && stage.defSpan;
      if (resolvedElsewhere) resolvedStageDefSpans.push(stage.defSpan);
      if (count == null) {
        uncapped.push(span);
        unknownUnits += 1;
        continue; // excluded from producer/verifier sums entirely (P1-C)
      }
      // Round 4 finding 4: a `.map()` callback given as a bare identifier
      // with no resolvable top-level declaration has no body this
      // heuristic can see agent() calls or verification lexicon inside --
      // same fail-closed rule as the pipeline() stage case above, not a
      // fabricated `producers += count`.
      //
      // Round 5 finding 2: same split as the pipeline branch above -- the
      // numeric cap (`count`) already resolved fine (the `count == null`
      // branch just above is the ONLY uncapped-worthy case here); an
      // unresolved callback body is a separate, unknownUnits-only concern,
      // never a fabricated "no cap" claim.
      if (stage && stage.unresolved) {
        unknownUnits += 1;
        continue;
      }
      // ITS text (not the uninformative call-site text `xs.map(checkOne)`)
      // is what the lexicon/reference checks below read for a resolved
      // callback -- the exclusion push itself already happened above.
      // One callback can hold several agent() calls, and each launches once
      // per item. Count the calls, then scale by the item cap, the same
      // accounting the pipeline branch already applies per stage. A callback
      // with no agent() call contributes nothing.
      // The callback's OWN span, not the whole fan-out call's. `stage.span`
      // is the `.map(...)` argument span that scopedMapCap() already
      // resolved, for an inline arrow as much as for a hoisted declaration.
      // Falling back to `span` here swept in every agent() call anywhere in
      // the fan-out: a SECOND sibling `.map()` inside the same parallel([...])
      // had its per-item call scaled by THIS map's cap and classified against
      // THIS map's item parameter, hiding a real verifier fleet behind the
      // wrong (smaller) cap; and an unrelated sibling literal call was
      // multiplied by this map's item cap. Only fall back to `span` when the
      // callback span could not be resolved at all.
      const callbackSpan = stage && stage.span ? stage.span : span;
      const calls = directAgentSpansWithin(callbackSpan, agentSpansByStart, enclosingFanout);
      const derivedPos = baseName != null ? derivedBindings.get(baseName) : undefined;
      const mappedFromEarlierResult = derivedPos !== undefined && derivedPos < span[0];
      // Per-element callbacks in this fan-out other than the resolved one: a
      // SIBLING (`[...xs.map(f), ...ys.flatMap(g)]`) runs per item of a list
      // whose cap this pass never resolves (the one-receiver limit in the
      // module doc); one NESTED inside the resolved callback
      // (`xs.flatMap(x => ys.map(...))`) or ENCLOSING it
      // (`groups.forEach(g => g.items.map(...))`) multiplies each launch by a
      // second, unresolved cap. The method name does not matter: forEach,
      // filter, reduce, and Array.from run their callbacks per element as
      // surely as map does. See perElementContext() for how each is found.
      const { nested, siblings, enclosed, namedNested, namedSiblings } =
        callbackSpan !== span
          ? perElementContext(stripped, span, callbackSpan, (stage && stage.refSpan) || callbackSpan)
          : { nested: [], siblings: [], enclosed: false, namedNested: [], namedSiblings: [] };
      // A nested callback passed by name runs its calls per item of a list
      // this pass never resolves: unknown, not counted.
      const namedNestedHit = claimAgentDecls(namedNested);
      let multiplierUnresolved = (calls.length > 0 && enclosed) || namedNestedHit;
      for (const call of calls) {
        const callRaw = scriptText.slice(call[0], call[1]);
        const callRef = strippedKeepInterp.slice(call[0], call[1]);
        const referencesItemOrBase = mapReferencesItemOrBase(callRef, itemParam, baseName);
        const isVerifier = mappedFromEarlierResult && referencesItemOrBase && VERIFICATION_LEXICON_RE.test(callRaw);
        // Nested or enclosed: `count` is a lower bound on this call's
        // launches, so it is still counted, and the unit is reported as not
        // fully resolved.
        if (containingIndex(nested, call) >= 0) multiplierUnresolved = true;
        if (isVerifier) verifiers += count;
        else producers += count;
      }
      if (multiplierUnresolved) unknownUnits += 1;
      // A call in this fan-out but OUTSIDE the mapped callback launches once,
      // not once per item: `Promise.all([...xs.map(verify), agent('refute')])`.
      // Scoping the per-item count to the callback is right, but it left these
      // calls in no counter at all, because the final top-level loop also skips
      // anything inside a fan-out -- an unseen verifier. Count each once --
      // unless it sits inside a sibling per-element callback, where counting it
      // once would fabricate a number: that callback is an unknown unit. A
      // thunk (`() => agent(x)`) or an IIFE is not a per-element callback and
      // still counts once.
      if (callbackSpan !== span) {
        const outside = directAgentSpansWithin(span, agentSpansByStart, enclosingFanout).filter(
          ([s, e]) => s < callbackSpan[0] || e > callbackSpan[1]
        );
        const hitSiblings = new Set();
        for (const call of outside) {
          const inSibling = containingIndex(siblings, call);
          if (inSibling >= 0) hitSiblings.add(inSibling);
          else if (isVerifierCall(call, agentSpans)) verifiers += 1;
          else producers += 1;
        }
        namedSiblings.forEach((decls, i) => {
          if (claimAgentDecls(decls)) hitSiblings.add(i);
        });
        unknownUnits += hitSiblings.size;
      }
    } else {
      // Round 9 fix (P1-C): before falling through to literal-list handling,
      // check whether the fan-out's sole argument is a bare identifier bound
      // (via an earlier statement) to a `.map(...)` result -- see
      // resolveHoistedMapCap()'s own doc comment for why the inline-only
      // `capText.includes('.map(')` check above cannot see this shape.
      const hoistedArgName = soleBareIdentifierArg(span, stripped);
      const hoisted = hoistedArgName
        ? resolveHoistedMapCap(
            hoistedArgName,
            span[0],
            directBindings,
            agentSpans,
            stripped,
            derivedSliceCaps,
            allDeclarations,
            deadline,
            scriptText
          )
        : null;

      if (hoisted) {
        const { baseName, itemParam, count, stage, rhsSpan } = hoisted;
        // Unlike the inline `.map()` branch above, the callback body here is
        // NEVER inside `span` (the `parallel(NAME)`/`Promise.all(NAME)` call
        // itself is just a bare identifier) -- it always lives in the
        // earlier hoisting statement, at `stage.span` when resolveStageArgument()
        // found one, or the whole RHS (`rhsSpan`) as a fallback when it
        // didn't (e.g. an unbalanced `.map(` -- see scopedMapCap()). Either
        // way this span's own agent() call(s) must be excluded from the
        // final bare-top-level loop below (resolvedStageDefSpans), the same
        // reason the RESOLVED-bare-identifier inline case does.
        //
        // Round 10 finding 1 (P1): this push must happen BEFORE the
        // count==null/stage.unresolved early-continues immediately below,
        // not after them -- an unresolvable cap or body is still an
        // externally-declared callback, and skipping the push on those two
        // paths let the callback's own agent() call fall through to the
        // final bare-top-level loop as a phantom second producer, silently
        // corrupting the overRatio signal (reproduced against 0e1c021). The
        // exclusion genuinely applies unconditionally now that it runs
        // before either `continue` can fire.
        const calleeSpan = stage ? stage.span : rhsSpan;
        resolvedStageDefSpans.push(calleeSpan);
        if (count == null) {
          uncapped.push(span);
          unknownUnits += 1;
          continue; // excluded from producer/verifier sums entirely (P1-C)
        }
        if (stage && stage.unresolved) {
          unknownUnits += 1;
          continue;
        }
        // Same per-call accounting as the inline branch above: each agent()
        // call the hoisted callback contains launches once per item.
        const calls = directAgentSpansWithin(calleeSpan, agentSpansByStart, enclosingFanout);
        const derivedPos = baseName != null ? derivedBindings.get(baseName) : undefined;
        const mappedFromEarlierResult = derivedPos !== undefined && derivedPos < rhsSpan[0];
        // And the same per-element context, scoped to the hoisted right-hand
        // side: `const tasks = claims.flatMap(c => extra.map(...))` multiplies
        // each launch by a second cap, and a sibling `...extra.flatMap(...)`
        // in that RHS launches per item of a list this pass never resolves.
        // Without this the hoisted form reported 4 of a true 80, and counted a
        // sibling's calls once each as producers in the final top-level loop
        // (their declaration is in no fan-out span), flipping overRatio false.
        const { nested, siblings, enclosed, namedNested, namedSiblings } = perElementContext(
          stripped,
          rhsSpan,
          calleeSpan,
          (stage && stage.refSpan) || calleeSpan
        );
        const namedNestedHit = claimAgentDecls(namedNested);
        let multiplierUnresolved = (calls.length > 0 && enclosed) || namedNestedHit;
        for (const call of calls) {
          const callRaw = scriptText.slice(call[0], call[1]);
          const callRef = strippedKeepInterp.slice(call[0], call[1]);
          const referencesItemOrBase = mapReferencesItemOrBase(callRef, itemParam, baseName);
          const isVerifier = mappedFromEarlierResult && referencesItemOrBase && VERIFICATION_LEXICON_RE.test(callRaw);
          if (containingIndex(nested, call) >= 0) multiplierUnresolved = true;
          if (isVerifier) verifiers += count;
          else producers += count;
        }
        if (multiplierUnresolved) unknownUnits += 1;
        const hitSiblings = new Set();
        for (const call of directAgentSpansWithin(rhsSpan, agentSpansByStart, enclosingFanout)) {
          const inSibling = containingIndex(siblings, call);
          if (inSibling >= 0) hitSiblings.add(inSibling);
        }
        namedSiblings.forEach((decls, i) => {
          if (claimAgentDecls(decls)) hitSiblings.add(i);
        });
        for (const i of hitSiblings) resolvedStageDefSpans.push(siblings[i]);
        unknownUnits += hitSiblings.size;
        continue;
      }

      // Finding 8: classify EACH literal agent() call independently -- the
      // old `.every()` let one unrelated call launder an entire verifier
      // fleet as producers (or one stray verifier call inflate an ordinary
      // producer unit).
      const literals = directAgentSpansWithin(span, agentSpansByStart, enclosingFanout);
      for (const litSpan of literals) {
        if (isVerifierCall(litSpan, agentSpans)) verifiers += 1;
        else producers += 1;
      }
    }
  }

  // Round 5 finding 3: coarse spans (`.forEach(`/bare loops) get
  // flag-only treatment, never a producer/verifier classification -- see
  // the module DISCLOSURE paragraph and loopSpans()'s doc comment. Only
  // the OUTERMOST coarse span matters (a loop nested inside another
  // already-flagged loop, or inside a fine fan-out span that is fully
  // accounted for on its own terms already, must not be flagged a second
  // time); of those, only ones that directly wrap at least one agent()
  // call or a nested fine fan-out call carry any signal at all -- an empty
  // or agent-free loop is not a fan-out and must not be fabricated into
  // one.
  // Round 7 finding 2 (P1): fanoutIndex/coarseIndex/agentSortedByStart/
  // fanoutSortedByStart are each built ONCE (O(n log n)) and reused across
  // every query below, replacing the repeated whole-array `.some()` scans
  // that made this section, and the classification loop further down,
  // O(n^2) on a large FLAT script (see buildContainmentIndex()'s own doc
  // comment for the measured numbers). Each loop also now checks `deadline`
  // periodically, matching callSpans()'s own discipline, so a script large
  // enough to still exceed the budget fails closed (flagged: true) instead
  // of running unchecked past the external hook timeout.
  const fanoutIndex = buildContainmentIndex(fanoutSpans);
  const coarseIndex = buildContainmentIndex(coarseSpans);
  const topLevelCoarseSpans = coarseSpans.filter(([cs, ce], i) => {
    if (deadline !== undefined && (i & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const insideFineFanout = isContainedIn(cs, ce, fanoutIndex);
    if (insideFineFanout) return false;
    // "insideLargerCoarse": is this span properly contained by a DIFFERENT
    // coarse span (not itself)? Loop/.forEach() spans from brace/paren
    // balancing are laminar -- two distinct spans either nest completely or
    // are disjoint, never share an exact [start, end] pair -- so the max
    // `end` reachable from a start <= cs strictly exceeds ce only when it
    // comes from a span other than this one.
    const insideLargerCoarse = maxEndAtOrBefore(cs, coarseIndex) > ce;
    return !insideLargerCoarse;
  });
  const agentSortedByStart = buildStartSorted(agentSpans);
  const fanoutSortedByStart = buildStartSorted(fanoutSpans);
  for (let ci = 0; ci < topLevelCoarseSpans.length; ci += 1) {
    if (deadline !== undefined && (ci & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const cspan = topLevelCoarseSpans[ci];
    const wrapsSpawn =
      containsAny(cspan[0], cspan[1], agentSortedByStart) ||
      containsAny(cspan[0], cspan[1], fanoutSortedByStart);
    if (wrapsSpawn) {
      uncapped.push(cspan);
      unknownUnits += 1;
    }
  }

  const resolvedStageDefIndex = buildContainmentIndex(resolvedStageDefSpans);
  const topLevelCoarseIndex = buildContainmentIndex(topLevelCoarseSpans);
  for (let ai = 0; ai < agentSpans.length; ai += 1) {
    if (deadline !== undefined && (ai & 0xfff) === 0 && Date.now() > deadline) {
      throw new AnalysisBudgetExceeded();
    }
    const span = agentSpans[ai];
    const insideFanout = isContainedIn(span[0], span[1], fanoutIndex);
    if (insideFanout) continue; // folded into its enclosing fan-out unit above
    // Round 4 finding 4: a bare-identifier pipeline stage's own top-level
    // declaration (e.g. `function verifyOne(item) {...}` referenced as
    // `pipeline(items, verifyOne)`) sits OUTSIDE the pipeline call's own
    // span, so the insideFanout check above does not see it -- without this
    // second check its agent() calls would be double-counted: once
    // (correctly, multiplied by the item cap) in the pipeline branch above,
    // and again here as an ordinary, un-multiplied top-level producer.
    const insideResolvedStageDef = isContainedIn(span[0], span[1], resolvedStageDefIndex);
    if (insideResolvedStageDef) continue; // folded into its referencing fan-out unit above
    // Round 5 finding 3: a call already flagged (fail-closed, unknown
    // spawn count) as wrapped by a coarse loop/.forEach() span above must
    // not ALSO be silently credited here as an ordinary, resolved
    // top-level producer -- that would contradict the very flag just
    // raised for it.
    const insideCoarse = isContainedIn(span[0], span[1], topLevelCoarseIndex);
    if (insideCoarse) continue; // folded into its enclosing coarse unit above
    // A bare top-level agent() call is always a producer/synthesis stage,
    // regardless of what it references or says (P1-B) -- a sequential
    // research -> fetch(uses p1) -> summarize(uses p2) pipeline is three
    // producer stages, not an escalating verifier chain.
    producers += 1;
  }

  const overRatio = verifiers > producers;
  return { producers, verifiers, overRatio, uncapped, unknownUnits, flagged: false };
}

/**
 * Read a Workflow RESUME call's script from disk (P1-D): tool_input carries
 * {scriptPath, resumeFromRunId} with no `script` string on resume, so
 * without this the hook silently skips analysis on every resume. Resolves a
 * relative scriptPath against `cwd`, caps the read at SCRIPT_FILE_READ_CAP,
 * and fails OPEN (returns null) on any error -- a missing/unreadable file
 * must never crash the hook or block the resume; it just means no analysis
 * happens for this call, exactly as an absent `script` already behaved.
 */
function readScriptFile(scriptPath, cwd) {
  try {
    const resolved = path.isAbsolute(scriptPath) ? scriptPath : path.join(cwd || '.', scriptPath);
    const fd = fs.openSync(resolved, 'r');
    try {
      const stat = fs.fstatSync(fd);
      const size = Math.min(stat.size, SCRIPT_FILE_READ_CAP);
      const buf = Buffer.alloc(size);
      fs.readSync(fd, buf, 0, size, 0);
      return buf.toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Task path: session-state-backed spawn counting.
// ---------------------------------------------------------------------------

function analyzeTaskSpawn(input) {
  const sid = sessionKey(input);
  const now = Date.now();
  let recent = [];
  // updateState() (P2) wraps load+mutate+save in a cross-process lock, so
  // concurrent Task spawns in the same session can't lose each other's
  // writes to an interleaved read-modify-write race -- 20 concurrent spawns
  // against ce0af4f's plain loadState()+saveState() were measured at
  // 10-17 of 20 recorded, 3 repeated runs (method in session-state.js).
  updateState(
    TASK_STATE_DIR,
    sid,
    { reapOlderThanMs: TASK_STATE_REAP_MS, defaultState: { spawns: [] }, now },
    (state) => {
      const spawns = Array.isArray(state.spawns) ? state.spawns : [];
      spawns.push(now);
      recent = spawns.filter((t) => now - t <= TASK_WINDOW_MS);
      state.spawns = recent;
      return state;
    }
  );
  return { count: recent.length, overThreshold: recent.length > TASK_THRESHOLD };
}

function run(rawInput) {
  let input = {};
  try {
    input = JSON.parse(rawInput);
  } catch {
    return rawInput;
  }

  const tool = input.tool_name;
  if (tool !== 'Task' && tool !== 'Workflow') return rawInput;

  if (tool === 'Task') {
    // No setDenyContext here: the Task path never calls deny()/hardStop() (see
    // decision 1 below), so there is nothing for a self-logging deny to read.
    // The one WARN record this path can produce is logged explicitly below,
    // with the fanout-admission:<kind> guard name the acceptance criteria
    // names -- distinct from the bare 'fanout-admission' every setDenyContext
    // caller in this repo uses to match its own filename exactly
    // (papercut-log.test.js's "every guard names itself" invariant).
    const { count, overThreshold } = analyzeTaskSpawn(input);
    if (overThreshold) {
      const reason =
        `fanout-admission: ${count} Task spawns in the last ` +
        `${Math.round(TASK_WINDOW_MS / 60000)}min exceeds CLAUDE_FANOUT_TASK_THRESHOLD=${TASK_THRESHOLD} ` +
        `(heuristic only — no script to verify structurally on this path).`;
      try {
        logDenial({
          guard: 'fanout-admission:task',
          tool: 'Task',
          reason,
          sessionId: input.session_id,
          agentId: input.agent_id,
          cwd: input.cwd,
        });
      } catch {
        /* counting is optional; admission is not */
      }
    }
    // Decision 1 (#1284): the Task path never denies, even under the
    // blocking opt-in — there is no script to structurally verify, so a
    // hard block here would be false precision.
    return rawInput;
  }

  // tool === 'Workflow'
  // guard: 'fanout-admission' (bare, matching the filename) -- this is the
  // ONE path that can ever call deny() (below), which self-logs through this
  // context; papercut-log.test.js's "every guard names itself" invariant
  // requires setDenyContext's guard to equal the filename exactly. The WARN
  // branch's own logDenial() call further down still uses the more specific
  // fanout-admission:workflow the acceptance criteria names -- that call is
  // not subject to the same invariant (see the Task branch above).
  setDenyContext({
    guard: 'fanout-admission',
    cwd: input.cwd,
    sessionId: input.session_id,
    agentId: input.agent_id,
    tool: 'Workflow',
  });

  const ti = input.tool_input || {};
  let script = typeof ti.script === 'string' ? ti.script : '';
  if (!script && typeof ti.scriptPath === 'string' && ti.scriptPath) {
    // Workflow RESUME (P1-D): no `script` string, only {scriptPath,
    // resumeFromRunId}. Read it from disk instead of skipping analysis.
    const fromFile = readScriptFile(ti.scriptPath, input.cwd);
    if (typeof fromFile === 'string') script = fromFile;
  }
  if (!script) return rawInput;

  const analysis = analyzeWorkflow(script);
  // Round 5 finding 2: a resolved-cap-but-unresolved-body unit (unknownUnits
  // alone, uncapped correctly empty) is still worth a WARN record for
  // visibility -- "nothing goes unreported" per this file's own convention
  // -- but it never independently denies under the blocking opt-in the way
  // a real cap violation does (Decision 3 below names only overRatio/uncapped
  // as independently-denying conditions). `capViolation` gates GATE_BLOCK;
  // `flagged` (widened to include unknownUnits and the round 5 finding 1
  // budget-exceeded case) only gates WARN-worthiness.
  const capViolation = analysis.overRatio || analysis.uncapped.length > 0;
  const flagged = analysis.flagged || capViolation || analysis.unknownUnits > 0;
  if (!flagged) return rawInput;

  const reasonParts = [];
  if (analysis.flagged) {
    // Round 5 finding 1 (P0): the internal analysis budget was exhausted --
    // fail closed rather than ever reaching the hook's external 5s kill
    // (which does not block the gated tool call). This is a distinct,
    // honest reason, not the generic "no cap" text below (which would be
    // false here -- we never finished analyzing the script at all).
    reasonParts.push(
      `script analysis exceeded its internal ${ANALYSIS_BUDGET_MS}ms budget and could not be fully checked -- treated as unresolvable, fail closed`
    );
  } else {
    if (analysis.overRatio) {
      reasonParts.push(`${analysis.verifiers} verifier agent call(s) exceed ${analysis.producers} producer agent call(s)`);
    }
    if (analysis.uncapped.length > 0) {
      // Round 2 finding 9: name the span(s) in the deny text, not just a count
      // -- a missing-cap reason with no location is much harder to act on.
      const offsets = analysis.uncapped.map(([s, e]) => `${s}-${e}`).join(', ');
      reasonParts.push(
        `${analysis.uncapped.length} data-driven fan-out(s) with no .slice(N)/maxItems cap (source offset ${offsets})`
      );
    }
    if (analysis.unknownUnits > 0) {
      reasonParts.push(`${analysis.unknownUnits} unit(s) with an unresolvable spawn count excluded from the ratio`);
    }
  }
  const reason = `fanout-admission: ${reasonParts.join('; ')} (agent-swarm skill, "Fan-out hygiene").`;

  // Decision 3 (#1284, revised round 2 finding 9): an uncapped fan-out is
  // excluded from the producer/verifier ratio precisely because its true
  // spawn count is unknown (P1-C) -- but "excluded from the ratio" must not
  // mean "never enforced": CLAUDE.md's "hard-cap every data-driven fan-out"
  // is a rule of its own, independent of the ratio. Either condition can now
  // independently deny under the opt-in. deny() self-logs via setDenyContext
  // above, so no separate logDenial call belongs on this branch (would
  // double-record). Round 5 finding 1: an exhausted analysis budget also
  // denies under the opt-in -- we could not verify compliance at all, so
  // fail closed rather than pass an unanalyzable script through.
  if (GATE_BLOCK && (analysis.flagged || capViolation)) {
    return deny(reason);
  }

  try {
    logDenial({
      guard: 'fanout-admission:workflow',
      tool: 'Workflow',
      reason,
      sessionId: input.session_id,
      agentId: input.agent_id,
      cwd: input.cwd,
    });
  } catch {
    /* counting is optional; admission is not */
  }
  return rawInput;
}

module.exports = {
  run,
  analyzeWorkflow,
  analyzeTaskSpawn,
  blankStrings,
  blankStringsKeepInterpolation,
  lexCode,
  callSpans,
  ownText,
  directAgentSpansWithin,
  buildEnclosingFanoutIndex,
  uncappedFanouts,
  findBoundNames,
  findDerivedBindings,
  scopedMapCap,
  readScriptFile,
  AnalysisBudgetExceeded,
};

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => {
    if (data.length < 1024 * 1024) data += c;
  });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}
