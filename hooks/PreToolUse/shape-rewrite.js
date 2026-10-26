#!/usr/bin/env node
/**
 * PreToolUse Hook: Rewrite-not-deny for verifier-refused Bash shapes
 *
 * Claude Code's worktree-isolation verifier refuses a family of Bash shapes
 * as "too complex to verify that it stays inside the worktree" — command
 * substitution in argument position, backticks, a `${VAR:-x}`-style
 * parameter-expansion modifier, an unquoted-delimiter heredoc, a `for` loop
 * that uses its own loop variable, and a package-manager operand
 * (`pnpm typecheck`, `npx tsc`). Every one of those shapes is harmless when
 * the command never reaches outside the worktree; the verifier refuses
 * because it cannot prove that, not because the command is dangerous.
 *
 * This hook rewrites (never denies): when a refused shape is detected and a
 * reach check confirms the command cannot touch anything outside the
 * allowed roots (the worktree root, the session's scratch directory, /tmp,
 * and $HOME/.claude/jobs), the call is written verbatim into a script file
 * and `updatedInput.command` becomes `bash <script>` — a form the verifier
 * does not parse internally (doc: harness/worktree-command-shapes.md,
 * "Running a script file by absolute path"). A command already excluded by
 * heavy-job-admission's own package-manager handling, one that reaches
 * outside the roots, or one the reach check cannot resolve is left
 * untouched (pass-through): this hook only ever narrows verifier friction,
 * never widens what a Bash call can touch.
 *
 * See docs/plans/2026-09-20-2120-feat-rewrite-not-deny-hook-plan.md for the
 * full Product and Planning Contract (KTD1-KTD10, R1-R10, AE1-AE17).
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { shellTokens, analyzeCommand } = require('./heavy-job-admission.js');
const { logDenial } = require('../PostToolUseFailure/papercut-log.js');
const { writeHookOutput } = require('../lib/hook-output');
const {
  wordLiteralText, wordHasDynamic, wordDynamicPayloads,
  toLiteralTokens, hasNonFlagOperand: sharedHasNonFlagOperand,
  ghSubcommandPosition, ghNoPathSegment, ghReachesOutright,
} = require('../lib/shape-rewrite-reach.js');

// Chain/pipe/subshell operators that split one Bash call into independent
// command segments (finding #11: hoisted so detectShapes and segment() can't
// drift out of sync with each other).
const SHELL_CHAIN_OPS = new Set([';', '&&', '||', '|', '&', '(', ')', '\n']);
// After one of these ops a newline emits no separator: `|`, `&&`, `||` and
// `(` still expect their right-hand side, and `;`, `&` and `\n` already ended
// the command.
const NEWLINE_CONTINUATION_OPS = new Set(['|', '&&', '||', '(', ';', '&', '\n']);

// Finding #2 (adversarial review of PR #1295 round 7): both the SHELLS `-c`
// flag check and the pre-existing ln/cp symlink-flag check used a
// `/^-X*[target]X*$/`-shaped regex (`/^-\w*c\w*$/` and
// `/^-[a-zA-Z]*[sf][a-zA-Z]*$/`). That shape backtracks quadratically: given
// a dense run of the allowed char class that also contains the target
// char(s) many times, followed by a terminator that makes the whole match
// fail, the engine retries the trailing `X*` against every occurrence of
// the target char before it can conclude there is no match. Measured on the
// live functions: `'-' + 'c'.repeat(320000) + '!'` took 24.3s in a SINGLE
// synchronous .test() call; 1.5s at n=80000 for the -c form, 2.4s at
// n=80000 for the ln/cp form (reproduced this round against 246216b via
// `shape-rewrite.OLD.js`, a same-round scratch copy of the pre-fix file
// kept only long enough to capture this comparison and removed before this
// commit). checkBudget() cannot preempt this: it only runs BETWEEN
// iterations, and the blowup is inside one synchronous regex call.
// isUnbundledFlagCluster() replaces both with a single linear scan: the
// question "does every character after the leading `-` belong to the
// allowed class, and does at least one of them match a target char" is
// answered in one pass with no ambiguity to backtrack over. `isWordChar`/
// `isAlphaChar` are plain range checks (ASCII only, matching `\w` and
// `[a-zA-Z]` exactly as those regexes did with no `u` flag) so no regex
// runs in the hot loop at all.
function isWordChar(ch) {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch === '_';
}
function isAlphaChar(ch) {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}
function isUnbundledFlagCluster(literal, isAllowedChar, targetChars) {
  if (literal.length < 2 || literal[0] !== '-') return false;
  let hasTarget = false;
  for (let i = 1; i < literal.length; i += 1) {
    const ch = literal[i];
    if (!isAllowedChar(ch)) return false;
    if (targetChars.indexOf(ch) !== -1) hasTarget = true;
  }
  return hasTarget;
}

// F2 (adversarial review of PR #1295 round 6): this file's own history
// already has TWO rounds (round 5 findings #4/#6) of profiling and fixing
// O(n^2) parsing in the exact functions below (findHeredocs,
// hasInterpStdinShape), yet had no general internal execution-time
// backstop -- only a per-round fix for whichever specific quadratic path
// that round happened to find and profile. Per memory doctrine
// (pretooluse-command-hooks-fail-open-on-timeout.md): "a superlinear parser
// inside a guard is a security finding, not a latency one... The
// countermeasure is an internal budget well under the registered timeout
// that bails out to the guard's own fail-closed path, rather than letting
// the CLI kill the process." This mirrors PR #1294's fanout-admission.js
// pattern (ANALYSIS_BUDGET_MS / AnalysisBudgetExceeded / a deadline
// threaded through the hot-loop functions / an options.budgetMs
// test-override seam) rather than inventing a new one.
//
// This hook's own "fail closed" is "grant no rewrite": unlike a
// deny-capable guard, shape-rewrite.js never blocks a command outright --
// its only two outcomes are "rewrite to `bash <script>`" (a bypass grant,
// only once reach analysis proves the command is safe) or "return
// rawInput unchanged" (defer entirely to the pre-existing verifier/
// ask-permission pipeline, the safe default). So exceeding the budget must
// always resolve to the second outcome: reaches() reports a reach reason
// (no rewrite) and detectShapes() reports no shapes (the same effect,
// since run()'s `if (!shapes.length) return rawInput;` already takes this
// exact path) -- both catch AnalysisBudgetExceeded EXPLICITLY, rather than
// falling through to run()'s own generic top-level catch (which exists for
// a different case: invalid JSON / an unexpected input shape), so the
// outcome is observable and directly testable via the same options.budgetMs
// seam fanout-admission uses (a deterministic `{ budgetMs: -1 }` test
// forces an already-past deadline with no large fixture needed).
//
// run() computes ONE absolute deadline and threads it into BOTH of its own
// analysis calls (detectShapes then reaches) rather than letting each
// default to its own fresh, independent budget -- two independent
// ANALYSIS_BUDGET_MS-sized budgets back to back could together approach
// double the configured budget, which for a large-enough setting could
// creep back up toward the registered 5s external timeout this exists to
// stay well under. A caller that invokes detectShapes()/reaches() directly
// (every existing test, and the exported API) and passes no deadline still
// gets a fresh ANALYSIS_BUDGET_MS budget of its own, so this is additive,
// not a breaking change to either signature.
const ANALYSIS_BUDGET_MS = Number(process.env.CLAUDE_SHAPE_REWRITE_BUDGET_MS || 2500);

class AnalysisBudgetExceeded extends Error {}

/** Throws once `deadline` (an absolute Date.now() value) has passed; a no-op when `deadline` is undefined. */
function checkBudget(deadline) {
  if (deadline !== undefined && Date.now() > deadline) throw new AnalysisBudgetExceeded();
}

// ---------------------------------------------------------------------------
// Shared low-level scanning: quote-aware masking, heredoc extraction.
// ---------------------------------------------------------------------------

/**
 * Replaces every character that sits inside a single-quoted span, or that is
 * escaped, with U+0000 placeholders (same length, so indices stay aligned
 * with the original string) while leaving unquoted and double-quoted text
 * untouched. Used to find shell metacharacters (`${`, `<<`) at positions
 * that are NOT quoted/escaped-away, without discarding the ability to slice
 * the ORIGINAL string at the same offsets for the real text.
 */
function maskQuotes(command) {
  let out = '';
  let quote = null;
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") {
      out += ch === "'" ? "'" : '\u0000';
      if (ch === "'") quote = null;
      continue;
    }
    if (quote === '"') {
      if (ch === '\\' && i + 1 < command.length) {
        out += '\u0000\u0000';
        i += 1;
        continue;
      }
      out += ch === '"' ? '"' : ch;
      if (ch === '"') quote = null;
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) {
      out += '\u0000\u0000';
      i += 1;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      out += ch;
      continue;
    }
    out += ch;
  }
  return out;
}

/**
 * Finds every top-level (unquoted, unescaped) `<<`/`<<-` heredoc operator and
 * returns, for each, its delimiter, whether the delimiter was quoted or
 * backslash-escaped (which suppresses expansion inside the body — a POSIX
 * heredoc rule, not a guess), and the body text plus the offset range the
 * WHOLE construct (operator through terminator line) occupies, so a caller
 * can excise it from the surrounding text.
 */
function findHeredocs(command, deadline) {
  const masked = maskQuotes(command);
  const results = [];
  const opRe = /<<-?/g;
  let m;
  // Multiple `<<` operators can share one source line (`cmd <<'A' <<'B'`);
  // bash then reads their bodies back-to-back, in operator order, starting
  // right after that shared line -- A's body first, then B's immediately
  // after A's terminator, and so on. `nextBodyStart` is that running
  // pointer: each heredoc's body search begins at whichever is later, its
  // own line's end or where the PRECEDING heredoc's body search actually
  // stopped. Without it, every heredoc in a shared-line group would
  // restart its scan from the same shared line end and re-walk all of the
  // earlier heredocs' body text to reach its own delimiter -- silently
  // reintroducing O(heredocs^2) cost (round-5 F6 profiling: this, not
  // hasInterpStdinShape, was the still-quadratic remainder after that
  // function's own fix) and also mis-attributing body text: B's `body`
  // field would wrongly include A's body+terminator as a prefix.
  let nextBodyStart = 0;
  while ((m = opRe.exec(masked))) {
    checkBudget(deadline); // F2: bounds a pathological heredoc-COUNT input (the exact shape round 5 finding #6 profiled)
    const opStart = m.index;
    const dash = m[0].endsWith('-');
    let i = opStart + m[0].length;
    while (i < command.length && (command[i] === ' ' || command[i] === '\t')) i += 1;
    let delimiter = '';
    let quoted = false;
    if (command[i] === '"' || command[i] === "'") {
      quoted = true;
      const q = command[i];
      let j = i + 1;
      while (j < command.length && command[j] !== q) j += 1;
      delimiter = command.slice(i + 1, j);
      i = j < command.length ? j + 1 : j;
    } else if (command[i] === '\\') {
      quoted = true;
      i += 1;
      let j = i;
      while (j < command.length && /[A-Za-z0-9_]/.test(command[j])) j += 1;
      delimiter = command.slice(i, j);
      i = j;
    } else {
      let j = i;
      while (j < command.length && /[A-Za-z0-9_]/.test(command[j])) j += 1;
      delimiter = command.slice(i, j);
      i = j;
    }
    if (!delimiter) continue; // not a real heredoc (e.g. `a << b` comparison-ish text); skip
    const delimEnd = i;
    const firstNl = command.indexOf('\n', delimEnd);
    if (firstNl === -1) {
      results.push({ opStart, delimEnd, quoted, delimiter, body: '', skipTo: command.length });
      nextBodyStart = command.length;
      continue;
    }
    const bodyStart = Math.max(firstNl + 1, nextBodyStart);
    let pos = bodyStart;
    let bodyEnd = command.length;
    let skipTo = command.length;
    for (;;) {
      let lineEnd = command.indexOf('\n', pos);
      const atEof = lineEnd === -1;
      if (atEof) lineEnd = command.length;
      const line = command.slice(pos, lineEnd);
      const compare = dash ? line.replace(/^\t+/, '') : line;
      if (compare === delimiter) {
        bodyEnd = pos;
        skipTo = atEof ? lineEnd : lineEnd + 1;
        break;
      }
      if (atEof) { bodyEnd = command.length; skipTo = command.length; break; }
      pos = lineEnd + 1;
    }
    nextBodyStart = skipTo;
    const body = bodyEnd > bodyStart ? command.slice(bodyStart, bodyEnd - 1) : '';
    // `sameLineEnd` marks where the heredoc's OWN START LINE ends (the
    // newline right after the `<<delim` token) -- everything between
    // `delimEnd` and here is NOT part of the heredoc body; it is more of
    // the same command (finding #1, adversarial review of PR #1295 round
    // 3: `cat <<'EOF' | bash` has ` | bash` sitting right here, on the
    // heredoc's own start line, not inside its body). excludeHeredocBodies
    // must keep this span, and only exclude from the FIRST newline onward.
    results.push({
      opStart, delimEnd, quoted, delimiter, body, skipTo, sameLineEnd: firstNl,
    });
  }
  return results;
}

/**
 * Does a heredoc body contain a quote (`"` or `'`) nested inside a `{...}`
 * span?
 *
 * Not a reach judgment — quoting still suppresses expansion inside this
 * body exactly as before, and `reachesWithin` never recurses into it. This
 * is a work-around predicate for a CC-internal worktree-verifier behavior,
 * not a judgment derived from Claude Code source: the trigger shape is
 * inferred from live probes on Claude Code 2.1.280, 2026-09-23 (`cat
 * <<'EOF'` with body `{"a": 1}` or `{'a': 1}` refused, `{a: 1}` and
 * `'a' {b}` allowed), filed upstream as anthropics/claude-code#96253, with
 * the probe table in harness/worktree-command-shapes.md. #1348
 * matched only the double quote; the single quote, mostly Python dict
 * literals, was 175 of the week's 1,402 refusals (12.5%) before #1365
 * added it, not counting the session that built #1365, whose own probes
 * and review subagents were a third of that week's refusals.
 * The match scope is any quote at brace depth > 0 -- a JSON object body is
 * the common case, but a parameter-expansion default like `${VAR:-"x"}`
 * and a brace group like `{ echo "hi"; }` inside a quoted heredoc are
 * refused too, confirmed empirically. That breadth is deliberate: the
 * verifier's own trigger is at least this broad, so narrowing to
 * JSON-shaped bodies would stop rewriting refused heredocs. An extra match
 * costs only a `bash <script>` indirection the reach check still gates; a
 * missed one costs a refused call and a retry. Depth-tracking (not a flat
 * "does the body contain both `{` and a quote" check) so an unrelated
 * quote before any `{` or after every `}` has closed does not
 * false-positive. shape-refusal-mine.js imports this function, so a trigger
 * learned from new probes lands in the hook and the miner at once; drift
 * from the verifier itself shows in the miner's not-detected bucket, which
 * is measured against real refusals.
 */
function heredocBodyHasQuoteInBraces(body) {
  let depth = 0;
  for (const ch of body) {
    if (ch === '{') depth += 1;
    else if (ch === '}') depth = Math.max(0, depth - 1);
    else if (depth > 0 && (ch === '"' || ch === "'")) return true;
  }
  return false;
}

/**
 * Does a `<<` heredoc operator follow a redirect in a command entered
 * through `&&` or `||`?
 *
 * The verifier's second quoted-heredoc trigger, independent of the body.
 * Live probes on CC 2.1.280, 2026-09-23, each with the plain body `hello`:
 * after `true &&` or `false ||`, a `cat` with `>`, `>>`, `>|`, `2>`, `2>&1`,
 * `<`, or `&>` before `<<'EOF'` is refused; `true && cat <<'EOF' > f`
 * (redirect after the operator), `true && tee f <<'EOF'`,
 * `echo hi; cat > f <<'EOF'`, and a lone `cat > f <<'EOF'` or
 * `cat >| f <<'EOF'` run. `mkdir -p d && cat > d/f <<'EOF'` is the usual
 * way a session writes a scratch file, which made this 119 of the same
 * week's 1,402 refusals (#1365).
 *
 * `entries` is reachWords() over the body-excluded text, the quote-aware
 * tokenizer the reach check uses. A quoted or escaped `'>'` or `'<<'` is a
 * word there, not an operator, and the verifier agrees: `true && echo '>'
 * <<'EOF'` and `true && printf '%s\n' '>' '<<'` run. shellTokens drops
 * quotes, so the first version of this scan read both as refused and the
 * rewrite changed `$0` for them (#1370 review). reachWords emits each
 * redirect as one operator (`>|`, `&>>`, `<>`; `2>&1` as the word `2` and
 * `>&`), so every operator that is neither a chain operator nor a heredoc
 * counts as the redirect, with no list to fall behind the tokenizer; a
 * `<<<` here-string is such an operator, never the heredoc. It also drops
 * the newline after an operator that expects more, so `true &&` then
 * `cat > f <<'EOF'` on the next line matches, as probed. A command entered
 * through `|`, `;`, `(`, or a plain newline does not match; those shapes run
 * or were not probed, so the verifier keeps judging them.
 */
function hasListRedirectHeredoc(entries) {
  let afterListOp = false;
  let redirected = false;
  for (const e of entries) {
    if (e.type !== 'op') continue;
    if (SHELL_CHAIN_OPS.has(e.value)) {
      afterListOp = e.value === '&&' || e.value === '||';
      redirected = false;
    } else if (e.value === '<<' || e.value === '<<-') {
      if (afterListOp && redirected) return true;
    } else {
      redirected = true;
    }
  }
  return false;
}

/**
 * Removes every heredoc's body+terminator (keeping the `<<delim` operator
 * AND the rest of its own start line, e.g. `| bash`) from the text.
 *
 * Finding #1 (adversarial review of PR #1295 round 3): this used to slice
 * only up to `h.delimEnd` (right after the delimiter word itself) before
 * jumping to `h.skipTo` (just past the terminator line), silently dropping
 * whatever else shared the heredoc's OWN start line -- `cat <<'EOF' | bash`
 * lost ` | bash` entirely, so the piped `bash` never even reached
 * segment()/reachesWithin() as a token to classify. `sameLineEnd` (the
 * position of the newline that actually starts the body) is the correct
 * cut point instead; a heredoc whose `firstNl` search failed (no newline
 * anywhere after the marker -- an incomplete/malformed construct with no
 * possible body) has no `sameLineEnd` and keeps the prior, conservative
 * from-delimEnd behavior.
 *
 * Finding #5 (adversarial review of PR #1295 round 5): `sameLineEnd` is the
 * INDEX OF the newline character itself (an exclusive slice boundary), so
 * slicing "up to" it (as round 3's fix above did) never includes that
 * newline in the kept text -- and every heredoc's kept-before span is
 * concatenated directly onto the kept-after span from the PREVIOUS
 * heredoc (or, for the last one, onto whatever follows `skipTo`) with no
 * separator of its own. Two previously-distinct tokens then fuse into one
 * literal word at the join: `cat <<EOF\nbody\nEOF\ngh pr merge 123 --squash`
 * excluded to `"cat <<EOF" + "gh pr merge 123 --squash"` = the single word
 * `"cat <<EOFgh pr merge 123 --squash"`, so the trailing `gh pr merge` was
 * never tokenized as a command at all and reached() saw nothing to deny.
 * This is the general form of the round-3 fix's own bug class -- a
 * body-exclusion transform must never drop the token separator living at
 * the exact position it drops the body -- so the fix is general too: cut
 * one character further, AT `sameLineEnd + 1`, so the real newline that
 * terminates the heredoc's own opening line is always kept as the
 * separator between "before this heredoc" and "after this heredoc's
 * terminator" text, for every heredoc, not just the one a specific exploit
 * happened to target. `\n` is itself a SHELL_CHAIN_OPS member (see above),
 * so preserving it here also correctly re-establishes a command boundary
 * for the tokenizer, exactly like an explicit `;` would.
 */
function excludeHeredocBodies(command, heredocs) {
  if (!heredocs.length) return command;
  let out = '';
  let last = 0;
  for (const h of heredocs) {
    const cut = h.sameLineEnd === undefined ? h.delimEnd : h.sameLineEnd + 1;
    out += command.slice(last, cut);
    last = h.skipTo;
  }
  out += command.slice(last);
  return out;
}

// ---------------------------------------------------------------------------
// U1: detectShapes, stripWrappers (verifier-shape detection)
// ---------------------------------------------------------------------------

const PKG_MANAGERS = new Set(['pnpm', 'npm', 'npx', 'yarn', 'yarnpkg', 'bun', 'bunx']);
const PKG_OPT_WITH_VALUE = new Set(['--filter', '--dir', '--cwd', '--prefix', '-C', '-F']);

function basenameToken(text) {
  const i = text.lastIndexOf('/');
  return i === -1 ? text : text.slice(i + 1);
}

/** Is this a package-manager invocation with a real script/exec operand (not flags-only)? */
function pkgmgrShape(tokens) {
  if (!tokens.length || typeof tokens[0] !== 'string') return false;
  const name = basenameToken(tokens[0]);
  if (!PKG_MANAGERS.has(name)) return false;
  let i = 1;
  if (name === 'npx' || name === 'bunx') {
    while (i < tokens.length && typeof tokens[i] === 'string' && tokens[i].startsWith('-')) {
      const t = tokens[i];
      i += 1;
      if ((t === '-p' || t === '--package' || t === '--call') && !t.includes('=')) i += 1;
    }
    return i < tokens.length;
  }
  while (i < tokens.length && typeof tokens[i] === 'string' && tokens[i].startsWith('-')) {
    const t = tokens[i];
    i += 1;
    if (PKG_OPT_WITH_VALUE.has(t) && !t.includes('=')) i += 1;
  }
  const sub = tokens[i];
  if (sub === undefined || typeof sub !== 'string') return false;
  if (sub === '--version' || sub === '-v') return false;
  if (sub === 'exec' || sub === 'dlx' || (name === 'bun' && sub === 'x')) {
    let j = i + 1;
    while (j < tokens.length && typeof tokens[j] === 'string' && tokens[j].startsWith('-')) j += 1;
    return j < tokens.length;
  }
  if (sub === 'run') {
    let j = i + 1;
    while (j < tokens.length && typeof tokens[j] === 'string' && tokens[j].startsWith('-')) j += 1;
    return j < tokens.length;
  }
  return i < tokens.length; // bare script name as subcommand (pnpm typecheck)
}

// Wrapper prefixes both passes skip before classifying the command name:
// leading `FOO=bar` assignments, `sudo`, `nohup`, `exec`, `env`, `timeout`,
// `nice`, `time`, `command`, `builtin`, `stdbuf`, `setsid`, `doas`.
// The option tables are ALLOWLISTS, mirroring (not calling) heavy-job-admission's
// private wrapper table (KTD4). An option not listed here leaves the prefix
// UNCERTAIN, and the reach check treats uncertainty as reaching: `sudo -u x git`
// must never read as a command named `-u`, and `timeout -s TERM 30 git` must
// not read as a command named `30`. A value-taking option consumes the next
// token (`-s TERM`); the joined forms (`--signal=TERM`, `-sTERM`) are one
// token and consume nothing. `time`'s `-o`/`-a`/`--output`/`--append` are
// deliberately left off the allowlist so they read as uncertain (fail closed)
// rather than guessed at. Even with this table, an unlisted wrapper name
// (any name not a key here) is not silently trusted as a no-op passthrough:
// reachesWithin's whole-core scan (finding #1b) still classifies a
// reach-checked command name appearing anywhere in the segment, including
// behind an unrecognised wrapper.
const WRAPPER_OPTIONS = {
  sudo: { flags: new Set(), withValue: new Set() },
  nohup: { flags: new Set(), withValue: new Set() },
  exec: { flags: new Set(), withValue: new Set() },
  timeout: {
    flags: new Set(['-v', '--verbose', '--foreground', '--preserve-status']),
    withValue: new Set(['-s', '--signal', '-k', '--kill-after']),
    duration: true,
  },
  env: {
    flags: new Set(['-i', '--ignore-environment', '-0', '--null', '-v', '--debug']),
    withValue: new Set(['-u', '--unset']),
    assignments: true,
  },
  nice: { flags: new Set(), withValue: new Set(['-n', '--adjustment']) },
  time: {
    flags: new Set(['-p', '--portability', '-v', '--verbose', '-q', '--quiet']),
    withValue: new Set(['-f', '--format']),
  },
  command: { flags: new Set(), withValue: new Set() },
  builtin: { flags: new Set(), withValue: new Set() },
  stdbuf: { flags: new Set(), withValue: new Set(['-i', '-o', '-e']) },
  setsid: { flags: new Set(['-f', '--fork', '-w', '--wait']), withValue: new Set() },
  doas: { flags: new Set(), withValue: new Set() },
};
// Shell compound-statement keywords, not programs -- `for x in ...; do REAL
// CMD; done` and `if ...; then REAL CMD; else REAL CMD; elif ...; fi` split
// into segments whose HEAD is the keyword (segment() only breaks on
// punctuation chain ops, never on `do`/`then`/`else`/`elif`), leaving the
// real command one slot later. Without stripping these, that real command
// reads as an ARGUMENT rather than the segment's own head -- which both
// hides it from the no-path/gh-read-verb dispatch below (the no-path
// variables feature's "or loop variable" case: `for n in 1 2; do gh pr view
// $n; done`) and, when it names git/gh, was misrouted into the
// whole-segment "outside the command position" scan (finding #1b) meant for
// wrapper commands, not loop syntax. A GENUINELY UNQUOTED occurrence of one
// of these four tokens is never a real command name (no `/usr/bin/do`), so
// stripping it is safe -- but a quoted or escaped one (`"do"`, `'then'`,
// `\elif`) is bash's ordinary way of naming a real program called `do` (real
// bash: `"do" echo hi` execs a program literally named `do`, exit 127 when
// absent -- it is not a syntax error the way unquoted `do` outside a loop is)
// (finding #4, adversarial review of PR #1295 round 3): stripping those
// unconditionally treated that program as a wrapper prefix and read the
// REAL command one slot later instead, exempting it from every check below.
// `reachWords()` tags each word with whether any character of it went
// through a quote or a backslash escape (`word.quoted`); the word-object
// path below only strips when that flag is false. They are not wrapper
// commands (no options, no man page) either way, so they get their own set
// rather than living in WRAPPER_OPTIONS.
const SEGMENT_HEAD_KEYWORDS = new Set(['do', 'then', 'else', 'elif']);
const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const DURATION_RE = /^\d+(\.\d+)?[smhd]?$/;

/**
 * The shared wrapper-prefix skip. `literalOf(item)` returns an item's literal
 * text, or null when it is not a plain literal (a substitution token, a word
 * built from a variable or expression), which stops the strip since a dynamic
 * command name can't be classified. `quotedOf(item)` (optional) reports
 * whether the item was genuinely quoted/escaped -- passed only by the
 * word-object caller, which has that information; the plain-string-token
 * caller (`shellTokens`, no quote metadata) omits it, which keeps the
 * SEGMENT_HEAD_KEYWORDS strip quote-INsensitive on that path exactly as
 * before (that path only gates whether a shape is considered for rewrite at
 * all, never the reach/safety judgment itself, so the pre-existing
 * imprecision there carries no safety cost). Returns the index of the first
 * non-wrapper item and whether the prefix was uncertain (see WRAPPER_OPTIONS).
 */
function stripWrapperPrefix(items, literalOf, quotedOf) {
  let i = 0;
  let uncertain = false;
  const lit = (k) => (k < items.length ? literalOf(items[k]) : null);
  while (i < items.length) {
    const t = lit(i);
    if (t === null) break;
    if (ASSIGNMENT_RE.test(t)) {
      i += 1;
      // `shellTokens` splits `FOO=$(date)` into two items: the literal
      // "FOO=" prefix and the command-substitution payload as a separate,
      // non-literal item. Advance past both, or the loop re-reads that
      // payload item as if it were the (unresolvable) head and stops the
      // strip one item early (finding #9).
      if (t.endsWith('=') && i < items.length && lit(i) === null) i += 1;
      continue;
    }
    if (SEGMENT_HEAD_KEYWORDS.has(t) && !(quotedOf && quotedOf(items[i]))) {
      i += 1;
      continue;
    }
    if (!Object.prototype.hasOwnProperty.call(WRAPPER_OPTIONS, t)) break;
    const opts = WRAPPER_OPTIONS[t];
    i += 1;
    for (;;) {
      const o = lit(i);
      if (o === null || !o.startsWith('-') || o === '-') break;
      i += 1;
      const name = o.startsWith('--') ? o.split('=')[0] : o.slice(0, 2);
      const glued = o.startsWith('--') ? o.includes('=') : o.length > 2;
      if (opts.withValue.has(name)) {
        if (glued) continue;
        if (lit(i) === null) { uncertain = true; break; }
        i += 1;
      } else if (!opts.flags.has(o)) {
        uncertain = true;
      }
    }
    if (opts.duration) {
      const d = lit(i);
      if (d !== null && DURATION_RE.test(d)) i += 1; else uncertain = true;
    }
    if (opts.assignments) {
      while (lit(i) !== null && ASSIGNMENT_RE.test(lit(i))) i += 1;
    }
  }
  const head = lit(i);
  if (head !== null && head.startsWith('-')) uncertain = true;
  return { index: i, uncertain };
}

/**
 * Wrapper-prefix skip for a token list produced by heavy-job-admission's
 * `shellTokens` (the shape detector). Uncertainty is dropped here on purpose:
 * a shape the detector then misses leaves the call for the verifier, which is
 * the no-rewrite direction.
 */
function stripWrappers(tokens) {
  const { index } = stripWrapperPrefix(tokens, (t) => (typeof t === 'string' ? t : null));
  return tokens.slice(index);
}

function hasVarMod(command) {
  const masked = maskQuotes(command);
  const re = /\$\{/g;
  let m;
  while ((m = re.exec(masked))) {
    let depth = 1;
    let j = m.index + 2;
    while (j < masked.length && depth > 0) {
      if (masked[j] === '{') depth += 1;
      else if (masked[j] === '}') depth -= 1;
      j += 1;
    }
    if (depth !== 0) continue;
    const inner = command.slice(m.index + 2, j - 1);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(inner)) return true;
  }
  return false;
}

function hasLoopVarUse(command) {
  const masked = maskQuotes(command);
  const forRe = /\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/g;
  let m;
  while ((m = forRe.exec(masked))) {
    const varName = m[1];
    // Word-boundary matches (finding #10): `indexOf('do', ...)`/`indexOf('done',
    // ...)` match inside a longer identifier too (a list item like "undone"
    // contains "do" and "done" as substrings), which can pick the wrong
    // boundary and mis-slice the loop body.
    const doMatch = /\bdo\b/.exec(masked.slice(forRe.lastIndex));
    if (!doMatch) continue;
    const doIdx = forRe.lastIndex + doMatch.index;
    const doneMatch = /\bdone\b/.exec(masked.slice(doIdx));
    if (!doneMatch) continue;
    const doneIdx = doIdx + doneMatch.index;
    const body = command.slice(doIdx + 2, doneIdx);
    const useRe = new RegExp('\\$\\{?' + varName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b');
    if (useRe.test(body)) return true;
  }
  return false;
}

/**
 * Returns the sorted list of verifier-refused shape names this command
 * carries ([] if none), on the verifier's own top-level model: quoted
 * strings opaque, wrapper prefixes skipped first, heavy-job-admission's own
 * targets excluded (AE11), and a trailing `&` disqualifying the whole call
 * (a backgrounded call never reaches the verifier's synchronous parse the
 * same way, and heavy-job-admission already owns backgrounded heavy jobs).
 */
function detectShapes(command, deadline) {
  if (typeof command !== 'string' || !command.trim()) return [];
  // F2 (adversarial review of PR #1295 round 6): a direct caller (every
  // existing test, and any other future caller of the exported
  // `detectShapes`) that omits `deadline` gets its own fresh default
  // budget, same as `reaches` -- non-breaking. `run()` passes the ONE
  // shared deadline it computes so this call and the later `reaches()` call
  // share a single budget rather than each getting an independent one.
  const effectiveDeadline = typeof deadline === 'number' ? deadline : Date.now() + ANALYSIS_BUDGET_MS;
  try {
    return detectShapesInner(command, effectiveDeadline);
  } catch (err) {
    if (err instanceof AnalysisBudgetExceeded) {
      // Fail closed for shape detection means "detect nothing rewritable":
      // an empty shape list makes run() fall through to its normal
      // no-known-shape path, i.e. no rewrite is offered.
      return [];
    }
    throw err;
  }
}

function detectShapesInner(command, deadline) {
  let heavy = false;
  try {
    heavy = Boolean(analyzeCommand(command).heavy);
  } catch {
    heavy = false;
  }
  if (heavy) return [];

  // Heredoc bodies are nested content, not the top-level command grammar the
  // verifier is parsing at this point (KTD4): a $() or ${VAR:-x} sitting
  // inside a heredoc body must not be mistaken for a top-level occurrence of
  // that shape. The heredoc shape itself is still detected against the FULL
  // original text (below), since that's a top-level `<<` operator.
  const heredocsForMasking = findHeredocs(command, deadline);
  const topLevel = excludeHeredocBodies(command, heredocsForMasking);

  const tokens = shellTokens(topLevel);
  const lastReal = [...tokens].reverse().find((t) => typeof t === 'string' && t !== '\n');
  if (lastReal === '&') return [];

  const shapes = new Set();

  const firstSegEnd = tokens.findIndex((t) => typeof t === 'string' && SHELL_CHAIN_OPS.has(t));
  const firstSeg = stripWrappers(firstSegEnd === -1 ? tokens : tokens.slice(0, firstSegEnd));
  if (pkgmgrShape(firstSeg)) shapes.add('pkgmgr');

  for (let i = 0; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (t && typeof t === 'object' && t.type === 'command-substitution') {
      const prev = tokens[i - 1];
      const isAssignValue = typeof prev === 'string' && /^[A-Za-z_][A-Za-z0-9_]*=$/.test(prev);
      if (!isAssignValue) {
        shapes.add('cmdsub');
      } else {
        // `NAME=$(...)` as a STANDALONE statement (nothing else follows in
        // this segment -- it ends at `;`/`&&`/`||`/`|`/newline/EOF) is a
        // variable-binding statement the verifier still cannot parse: it is
        // rewritable exactly like any other cmdsub, once the payload itself
        // passes the reach check (assignment substitution). `NAME=$(...) realcmd ...`
        // (an env-prefix to a real command in the SAME segment) is
        // unaffected -- `next` is a real command token there, not a chain
        // operator or end-of-input, so this keeps today's PASS-row behavior.
        const next = tokens[i + 1];
        const standalone = next === undefined || (typeof next === 'string' && SHELL_CHAIN_OPS.has(next));
        if (standalone) shapes.add('cmdsub');
      }
    }
  }

  if (hasVarMod(topLevel)) shapes.add('varmod');
  // The length check skips the second tokenizer pass for the many commands
  // with no heredoc, and a `<<` findHeredocs() rejected (no delimiter) never
  // counts as one.
  if (heredocsForMasking.some((h) => !h.quoted || heredocBodyHasQuoteInBraces(h.body))
    || (heredocsForMasking.length > 0 && hasListRedirectHeredoc(reachWords(topLevel)))) shapes.add('heredoc');
  if (hasLoopVarUse(topLevel)) shapes.add('loopvar');
  if (hasInterpStdinShape(command, heredocsForMasking, deadline)) shapes.add('interp');
  if (hasBareExecShape(topLevel, heredocsForMasking, deadline)) shapes.add('bareexec');

  return [...shapes].sort();
}

// ---------------------------------------------------------------------------
// U1: reaches (new code per KTD5 — does not call heavy-job-admission's
// private tokenizer helpers, only its exported shellTokens/analyzeCommand
// used above for shape detection).
// ---------------------------------------------------------------------------

const DEVICE_ALLOW = new Set(['/dev/null', '/dev/zero', '/dev/full', '/dev/stdin', '/dev/stdout', '/dev/stderr', '/dev/tty']);
// Findings #2/#3 (adversarial review of PR #1295 round 5): the two
// "reads its piped stdin as its own program" checks just below (SHELLS and
// INLINE_INTERPRETERS) both treat any literal non-flag word as proof of "a
// real, distinct script-file argument is present" -- but a path that merely
// RE-NAMES the same piped stdin (`/dev/stdin`, or the equivalent `/proc` and
// `/dev/fd` spellings of file descriptor 0) is not a separate file at all,
// it is the identical pipe under another name. `bash /dev/stdin` and
// `python3 /dev/stdin` are exactly the piped-stdin-as-script shape the
// pipedStdin checks exist to catch, not an exemption from it. Shared here so
// both call sites stay in lockstep -- this is the general form of "what
// counts as a genuine distinct operand," not a one-off /dev/stdin special
// case bolted onto each branch separately.
const STDIN_ALIAS_PATHS = new Set(['/dev/stdin', '/dev/fd/0', '/proc/self/fd/0']);
const REACH_COMMANDS = new Set(['cd', 'pushd', 'popd']);
const OPAQUE_ALWAYS = new Set(['eval', 'xargs', 'parallel', 'awk', 'gawk', 'mawk', 'nawk', 'sed']);
const INLINE_INTERPRETERS = new Set(['python', 'python2', 'python3', 'node', 'nodejs', 'perl', 'ruby']);
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh']);

// F1 (adversarial review of PR #1295 round 6): the heredoc-body denylist
// family this comment used to point at (HEREDOC_BODY_LITERAL_DENY,
// HEREDOC_BODY_DENY_PATH_PREFIXES, normalizeHeredocPathToken,
// heredocBodyHasOutsidePath, heredocBodyReaches -- moved to
// lib/shape-rewrite-reach.js by finding #8, round 3) is deleted along with
// the interp carve-out it existed only to gate (see the INLINE_INTERPRETERS
// branch of reachesWithin below): a denylist/pattern scan over a
// Turing-complete language's raw source text cannot be made sound against
// composed or computed constructions, live-reproduced against 682831d with
// chr()-built path strings and getattr()-based dynamic dispatch. With the
// carve-out reverted, the family has no remaining caller.

/**
 * interp family: is there a top-level segment in `command` shaped
 * like `[wrapper...] <interpreter> - <<'TAG' ... TAG` -- an interpreter
 * reading its program from stdin, fed by a heredoc whose delimiter is
 * QUOTED (so the body carries no shell expansion at all)? Runs on
 * `shellTokens` (detectShapes' own tokenizer), for shape-DETECTION only.
 *
 * F1 (adversarial review of PR #1295 round 6): this shape no longer has a
 * matching reach-check carve-out. `isInterpStdinArgShape()` -- the shared
 * `{ literal, dynamic }` predicate finding #12 (round 3) introduced so this
 * function and reachesWithin's own carve-out could not diverge on what
 * counts as a flag, a bare dash, or "some other operand" -- is removed
 * along with it: reachesWithin no longer has a carve-out to share the
 * predicate with (a bare "-" argument fed by a heredoc, quoted or not, is
 * unconditionally reaching again), and this function never actually called
 * it either -- finding #6's O(n) grouped rewrite just below folds the same
 * three checks (inline flag / bare stdin arg / other operand) inline via
 * `foldToken`, for the performance reasons documented there, so the two
 * mentions below of `isInterpStdinArgShape`'s three checks are naming the
 * shape being folded, not a still-live function call.
 *
 * A command detected as this shape is therefore always denied a rewrite by
 * reachesWithin now, making this bucket a permanent dead end for
 * detectShapes' caller -- kept anyway because it is harmless (an
 * over-detected shape simply fails the reach check and falls through to
 * ordinary pass-through, exactly like any other refused shape) and dropping
 * it would discard real shape-detection test coverage for no behavior
 * change. An UNQUOTED delimiter is deliberately not this shape (it already
 * carries the `heredoc` shape and, more importantly, DOES expand
 * `$(...)`/`$VAR` in its body, unlike a quoted one).
 */
/**
 * Finding #6 (adversarial review of PR #1295 round 5): this used to compute,
 * for EVERY quoted heredoc independently, its own `segStart` via a backward
 * character scan from `h.opStart`, then re-tokenize `command.slice(segStart,
 * h.opStart)` from scratch. Heredocs stacked on one command line (`cmd
 * <<'A' <<'B' <<'C' ...`) all share the SAME `segStart` (there is no chain
 * operator between them) while `h.opStart` grows heredoc-over-heredoc, so
 * both the backward scan and the re-tokenization did O(window length) work
 * per heredoc, for an O(n) window growing over n heredocs -- O(n^2) total.
 * Live-measured on the unmodified code: n=500/2000/8000 stacked heredocs
 * took 32.6/319.7/5259.6ms, versus 1.7/7.1/27.1ms for the same heredoc
 * COUNT spread across separate, chain-op-separated commands (each already
 * gets a short, freshly-reset `segStart`, so that shape was never the
 * problem). A follow-up isolation run timing the backward scan alone showed
 * it was itself already quadratic (7.0/101.4/1555.6ms for n=500/2000/8000),
 * confirming the scan -- not just the re-tokenization -- was a real
 * contributor, not only a rounding error next to the tokenizer cost.
 *
 * General fix, in two independent parts:
 *
 * (1) `segStart` for every heredoc is computed by a single O(n) forward
 *     pass over `masked` up front (heredocs are already opStart-ascending,
 *     per findHeredocs' own single forward regex scan, and a
 *     "last-boundary-at-or-before-i" value is monotonic non-decreasing as
 *     `i` grows, so one left-to-right pass suffices for all of them),
 *     instead of each heredoc re-scanning backward from its own opStart.
 *
 * (2) Heredocs sharing a `segStart` are walked as a GROUP (they are always
 *     contiguous in opStart order, since `segStarts[]` is itself
 *     non-decreasing). Within a group, only the DELTA text since the
 *     previous heredoc's opStart is tokenized -- not the whole growing
 *     prefix from scratch -- and folded into three RUNNING, monotone flags
 *     mirroring `isInterpStdinArgShape`'s own three checks, rather than
 *     re-deriving `restTokens` and re-calling it fresh each time. This is
 *     sound because:
 *       (a) each of `isInterpStdinArgShape`'s three checks is a plain
 *           "does ANY token in the sequence satisfy P" existential test,
 *           and "any token in A++B satisfies P" == "any in A satisfies P"
 *           OR "any in B satisfies P" regardless of split point -- so the
 *           three flags computed over one prefix and folded with the next
 *           delta's own flags reproduce exactly what re-scanning the whole,
 *           longer prefix from scratch would find;
 *       (b) two of those three checks (`hasInlineFlag`, `hasOtherOperand`)
 *           are individually monotone: once true for some heredoc in a
 *           group, they stay true for every later heredoc sharing that
 *           `segStart`, because the token sequence only grows by
 *           appending, never by removing or rewriting earlier tokens. Once
 *           either fires, `isInterpStdinArgShape` can never match again for
 *           the rest of the group, so the remaining heredocs are skipped
 *           outright instead of individually re-checked;
 *       (c) every heredoc's own `opStart` is, by construction
 *           (`findHeredocs` finds only TOP-LEVEL, unquoted `<<`/`<<-` via
 *           `maskQuotes`), never inside an open `'`/`"` quote, and
 *           `shellTokens` treats `<`/`>` as an unconditional flush point --
 *           so cutting the text exactly at one heredoc's `opStart` never
 *           splits a token the original, from-scratch-per-heredoc
 *           tokenization would have kept whole;
 *       (d) the interpreter identity (`core[0]`) is invariant across an
 *           entire group: it is resolved from tokens that all precede the
 *           FIRST heredoc's own `<<` (a heredoc operator can only follow
 *           the command it is attached to), so it is computed once, from
 *           the first heredoc's own delta, and reused for the rest of the
 *           group instead of being re-resolved from a longer re-tokenized
 *           prefix each time.
 *     (Residual, already pre-existing limitation, not introduced by this
 *     fix: neither `maskQuotes` nor `findHeredocs` understands `$( )` or
 *     backtick nesting, so a `<<` that is -- highly unusually -- embedded
 *     inside a still-open, unclosed `$( )` spanning a heredoc boundary was
 *     never handled correctly by the original per-heredoc-from-scratch code
 *     either; this rewrite does not change that.)
 */
function hasInterpStdinShape(command, heredocs, deadline) {
  if (!heredocs.length) return false;
  const masked = maskQuotes(command);

  const segStarts = new Array(heredocs.length);
  {
    let lastStop = 0;
    let hi = 0;
    for (let i = 0; i < masked.length && hi < heredocs.length; i += 1) {
      while (hi < heredocs.length && heredocs[hi].opStart === i) {
        segStarts[hi] = lastStop;
        hi += 1;
      }
      if (';&|()\n'.includes(masked[i])) lastStop = i + 1;
    }
    while (hi < heredocs.length) {
      segStarts[hi] = lastStop;
      hi += 1;
    }
  }
  const foldToken = (t, flags) => {
    if (typeof t === 'string') {
      if (/^(-c|-m|-e|--eval)$/.test(t)) flags.inlineFlag = true;
      if (t === '-') flags.bareStdin = true;
      else if (!t.startsWith('-')) flags.otherOperand = true;
    } else {
      flags.otherOperand = true; // dynamic (substitution) token
    }
  };

  let idx = 0;
  while (idx < heredocs.length) {
    checkBudget(deadline); // F2: bounds a pathological heredoc-COUNT input (the exact shape round 5 finding #6 profiled)
    const segStart = segStarts[idx];
    // The whole contiguous run of heredocs sharing this segStart is the
    // group. Compute its end up front so that idx always jumps past the
    // ENTIRE group when we're done with it -- whether we consumed every
    // member or stopped early because the group is already provably
    // disqualified. Advancing idx only to where an early stop occurred (the
    // bug this replaces) makes the outer loop "rediscover" the remaining
    // members as a fresh one-heredoc group apiece, re-running the from-
    // scratch prefix retokenization per member and silently reintroducing
    // the O(n^2) cost this rewrite exists to remove.
    let groupEnd = idx;
    while (groupEnd < heredocs.length && segStarts[groupEnd] === segStart) groupEnd += 1;

    let prevCut = segStart;
    const flags = { inlineFlag: false, bareStdin: false, otherOperand: false };
    let coreChecked = false;
    let coreIsInterp = false;
    for (let j = idx; j < groupEnd; j += 1) {
      const h = heredocs[j];
      const deltaTokens = shellTokens(command.slice(prevCut, h.opStart));
      prevCut = h.opStart;
      let restDelta = deltaTokens;
      if (!coreChecked) {
        const core = stripWrappers(deltaTokens);
        coreChecked = true;
        coreIsInterp = core.length > 0 && typeof core[0] === 'string'
          && INLINE_INTERPRETERS.has(basenameToken(core[0]));
        // core[0] is invariant for every heredoc in this group (proven via
        // stripWrappers' forward-only prefix resolution), so once it's
        // known to be a non-interpreter, no remaining member can match
        // either -- break out and let idx jump straight to groupEnd below.
        if (!coreIsInterp) break;
        restDelta = core.slice(1);
      }
      for (const t of restDelta) foldToken(t, flags);
      if (h.quoted && flags.bareStdin && !flags.inlineFlag && !flags.otherOperand) return true;
      // inlineFlag/otherOperand are monotone non-decreasing as the group's
      // token sequence grows by appending only, so once either fires the
      // group is permanently dead for every later member too.
      if (flags.inlineFlag || flags.otherOperand) break;
    }
    idx = groupEnd;
  }
  return false;
}

/**
 * Finding #4 (adversarial review of PR #1295 round 5): detectShapes() had no
 * signal at all for "a bare shell/interpreter reads its own pipe or heredoc
 * as its program" -- reachesWithin() already judges every one of these
 * forms correctly once it actually runs, but run() never called it: with no
 * detected shape, `if (!shapes.length) return rawInput;` short-circuits
 * before reaches() is ever invoked, so the command passes through with
 * ZERO scrutiny of any kind, not merely a bypassed one. This is three
 * narrow, targeted mirrors of reachesWithin's own already-proven
 * conditions -- not a rebuild of its full heredoc/pipe logic, and
 * deliberately scoped to avoid re-flagging cases that already have a
 * dedicated, deliberately-scoped carve-out elsewhere (the 'interp' shape's
 * script-FILE-argument planted negative in particular):
 *   (a) a SHELLS or INLINE_INTERPRETERS segment fed by a real pipe with no
 *       non-flag/script operand (`echo x | bash`, `echo x | python3`, and
 *       `cat <<'EOF' | bash` via cat's heredoc output feeding bash through
 *       the pipe -- the pipe, not the heredoc, is what matters for bash's
 *       own segment here);
 *   (b) a SHELLS segment fed ANY heredoc directly, unconditional on
 *       quoting -- SHELLS' own reach rule is unconditional on quoting too
 *       (`bash -s <<'EOF'`);
 *   (c) a QUOTED heredoc feeding a segment head that is neither a safe sink
 *       (cat/tee/OUTPUT_ONLY_COMMANDS) nor SHELLS nor INLINE_INTERPRETERS
 *       (`ssh host <<'EOF'`, `psql <<'EOF'`) -- the unquoted case is already
 *       covered unconditionally by the 'heredoc' shape above, and
 *       SHELLS/INLINE_INTERPRETERS are excluded here because they have
 *       their own dedicated rules ((a)/(b) above, and the 'interp' shape)
 *       with their own deliberate carve-outs.
 */
function hasBareExecShape(topLevel, heredocsForMasking, deadline) {
  if (!heredocsForMasking.length && !topLevel.includes('|')) return false;
  const entries = reachWords(topLevel);
  const heredocOpToInfo = new Map();
  {
    let hIdx = 0;
    for (const e of entries) {
      if (e.type === 'op' && (e.value === '<<' || e.value === '<<-')) {
        heredocOpToInfo.set(e, heredocsForMasking[hIdx]);
        hIdx += 1;
      }
    }
  }
  for (const { tokens: seg, pipedStdin } of segment(entries)) {
    checkBudget(deadline); // F2: bounds a pathological segment-COUNT input
    const { core, uncertain } = stripWordWrappers(seg);
    if (uncertain || !core.length || core[0].type !== 'word' || wordHasDynamic(core[0])) continue;
    const name = basenameToken(wordLiteralText(core[0]));
    const heredocOpsInSeg = seg.filter((e) => e.type === 'op' && (e.value === '<<' || e.value === '<<-'));
    const hasHeredocRedirect = heredocOpsInSeg.length > 0;

    if (SHELLS.has(name) || INLINE_INTERPRETERS.has(name)) {
      const rest = core.slice(1);
      const hasNonFlagOperand = sharedHasNonFlagOperand(toLiteralTokens(rest), STDIN_ALIAS_PATHS);
      if (pipedStdin && !hasNonFlagOperand) return true; // rule (a)
      if (SHELLS.has(name) && hasHeredocRedirect) return true; // rule (b)
      continue;
    }

    const hasQuotedHeredoc = heredocOpsInSeg.some((e) => {
      const info = heredocOpToInfo.get(e);
      return info && info.quoted;
    });
    const isSafeSink = name === 'cat' || name === 'tee' || OUTPUT_ONLY_COMMANDS.has(name);
    if (hasQuotedHeredoc && !isSafeSink) return true; // rule (c)
  }
  return false;
}

// gh verb-classification family (GH_READ_VERB_PAIRS, GH_API_WRITE_FLAGS,
// GH_GLOBAL_FLAGS_WITH_VALUE, ghApiIsReadOnly, ghSubcommandPosition,
// ghNoPathSegment) moved to lib/shape-rewrite-reach.js (finding #8) --
// self-contained pure functions over a `core` word array, no dependency on
// the rest of this file beyond the word-object accessors, also moved.

function readBacktickPayload(command, start) {
  for (let i = start; i < command.length; i += 1) {
    if (command[i] === '\\' && i + 1 < command.length) { i += 1; continue; }
    if (command[i] === '`') return { payload: command.slice(start, i), end: i };
  }
  return null;
}

/** Balances a parenthesized payload starting right after the opening `(`, quote-aware. */
function readParenPayload(command, start) {
  let depth = 1;
  let quote = null;
  for (let i = start; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") { if (ch === "'") quote = null; continue; }
    if (quote === '"') {
      if (ch === '\\' && i + 1 < command.length) { i += 1; continue; }
      if (ch === '"') quote = null;
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) { i += 1; continue; }
    if (ch === "'" || ch === '"') { quote = ch; continue; }
    if (ch === '(') depth += 1;
    else if (ch === ')') { depth -= 1; if (depth === 0) return { payload: command.slice(start, i), end: i }; }
  }
  return null;
}

/**
 * Word-level tokenizer for the reach check: groups characters into `words`
 * (each an array of {type:'text',value} | {type:'sub'|'procin'|'procout',
 * payload} parts, preserving which parts of one shell word are literal vs.
 * dynamically produced) and `{op:...}` separators. This is deliberately
 * separate from heavy-job-admission's `shellTokens` (which flattens
 * substitutions to top-level array entries and cannot represent "a
 * substitution glued to adjacent literal text as one argument", the shape
 * AE17's `"$(dirname x)/../outside/y"` needs) and it additionally
 * understands `<( )`/`>( )` process substitution, which `shellTokens` does
 * not parse at all.
 */
function reachWords(command, options) {
  // An unquoted heredoc body is data, not shell source, so a `#` in it is
  // never marked below (#1317 review).
  const heredocBody = Boolean(options && options.heredocBody);
  const out = [];
  let parts = [];
  let curText = '';
  let quote = null;
  // Finding #4 (adversarial review of PR #1295 round 3): a word is only
  // bash's reserved-word `do`/`then`/`else`/`elif` when EVERY character of it
  // is genuinely unquoted and unescaped -- `"do"`, `'do'`, and `\do` all name
  // a real command called `do` in bash, never the keyword. Tracked as one
  // flag per word (not per character) because the SEGMENT_HEAD_KEYWORDS
  // consumer below only needs "was this token exempt from bash's keyword
  // rule at all", not which character did it -- a word split across a quote
  // boundary (`d"o"`) is just as disqualified as one entirely quoted.
  let wordQuoted = false;
  const flushText = () => { if (curText !== '') { parts.push({ type: 'text', value: curText }); curText = ''; } };
  const flushWord = () => {
    flushText();
    if (parts.length) out.push({ type: 'word', parts, quoted: wordQuoted });
    parts = [];
    wordQuoted = false;
  };
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") {
      if (ch === "'") quote = null; else curText += ch;
      continue;
    }
    if (quote === '"') {
      if (ch === '"') { quote = null; continue; }
      if (ch === '\\' && i + 1 < command.length && '"$`\\\n'.includes(command[i + 1])) {
        i += 1;
        if (command[i] !== '\n') curText += command[i];
        continue;
      }
      if (ch === '$' && command[i + 1] === '(') {
        const nested = readParenPayload(command, i + 2);
        if (nested) { flushText(); parts.push({ type: 'sub', payload: nested.payload }); i = nested.end; continue; }
      }
      if (ch === '`') {
        const nested = readBacktickPayload(command, i + 1);
        if (nested) { flushText(); parts.push({ type: 'sub', payload: nested.payload }); i = nested.end; continue; }
      }
      curText += ch;
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) { i += 1; wordQuoted = true; if (command[i] !== '\n') curText += command[i]; continue; }
    if (ch === "'" || ch === '"') { quote = ch; wordQuoted = true; continue; }
    if (ch === '$' && command[i + 1] === '(') {
      const nested = readParenPayload(command, i + 2);
      if (nested) { flushText(); parts.push({ type: 'sub', payload: nested.payload }); i = nested.end; continue; }
    }
    if (ch === '`') {
      const nested = readBacktickPayload(command, i + 1);
      if (nested) { flushText(); parts.push({ type: 'sub', payload: nested.payload }); i = nested.end; continue; }
    }
    if (ch === '<' && command[i + 1] === '(') {
      const nested = readParenPayload(command, i + 2);
      if (nested) { flushText(); parts.push({ type: 'procin', payload: nested.payload }); i = nested.end; continue; }
    }
    if (ch === '>' && command[i + 1] === '(') {
      const nested = readParenPayload(command, i + 2);
      if (nested) { flushText(); parts.push({ type: 'procout', payload: nested.payload }); i = nested.end; continue; }
    }
    if (ch === '\n') {
      flushWord();
      // An unquoted newline ends a command exactly like `;` -- SHELL_CHAIN_OPS
      // and segment() already expect a '\n' op, and this is the only place
      // that can emit one (#1317). Reading it as plain whitespace glued every
      // later line onto the first line's command, so `echo "$(date)"` +
      // newline + `rm -rf "$X"` was one echo call with output-only arguments
      // and was rewritten past the verifier. After an operator that still
      // expects its right-hand side, or after another separator, bash keeps
      // reading the same command, so no op is emitted there: `a |` + newline
      // + `bash` keeps bash's piped stdin.
      const last = out[out.length - 1];
      if (last && !(last.type === 'op' && NEWLINE_CONTINUATION_OPS.has(last.value))) {
        out.push({ type: 'op', value: '\n' });
      }
      continue;
    }
    if (/\s/.test(ch)) { flushWord(); continue; }
    if (ch === '<' || ch === '>') {
      flushWord();
      let op = ch;
      if (command[i + 1] === ch) {
        op += command[++i];
        // A THIRD identical char makes `<<<` a here-string operator, which
        // must never be tokenized as a `<<` op: findHeredocs() does not
        // treat `<<<` as a heredoc at all (the char right after its own
        // `<<` is another `<`,
        // which can never become a delimiter, so its real-heredoc check
        // discards it via an empty-delimiter guard) -- emitting a `<<` op
        // here anyway desyncs heredocOpToInfo's sequential counter against
        // findHeredocs()'s array, misattributing every later heredoc's
        // quoted/unquoted record by one.
        if (ch === '<' && command[i + 1] === '<') op += command[++i];
        // Finding #4 (adversarial review of PR #1295 round 8, tokenizer
        // correctness, refuted as a security finding -- hasHeredocRedirect
        // counts op entries only, and heredocOpToInfo pairs sequentially by
        // position, so neither cares which exact string this token carries):
        // a `<<-` heredoc's dash belongs to the OPERATOR, matching
        // findHeredocs()'s own `/<<-?/g`. Without this, the dash glued onto
        // the following word instead (`<<-EOF` tokenized as op `<<` + word
        // `-EOF`), silently desyncing this tokenizer from findHeredocs()'s
        // delimiter text on every `<<-` heredoc.
        else if (ch === '<' && command[i + 1] === '-') op += command[++i];
      } else if (ch === '>' && command[i + 1] === '|') op += command[++i];
      else if (ch === '<' && command[i + 1] === '>') op += command[++i];
      if (command[i + 1] === '&') op += command[++i];
      out.push({ type: 'op', value: op });
      continue;
    }
    if (ch === '&' && command[i + 1] === '>') {
      flushWord();
      let op = '&>';
      i += 1;
      if (command[i + 1] === '>') { op += '>'; i += 1; }
      out.push({ type: 'op', value: op });
      continue;
    }
    if ('|;&()'.includes(ch)) {
      flushWord();
      if ((ch === '|' || ch === '&') && command[i + 1] === ch) out.push({ type: 'op', value: ch + command[++i] });
      else out.push({ type: 'op', value: ch });
      continue;
    }
    // A `#` that starts a word is marked, not skipped, and stays text. bash
    // reads it as a comment, except inside extglob, `(( ))`, `${ }` and
    // `$[ ]`, where it is pattern or expression text and the rest of the
    // line still runs; this tokenizer does not model those. Read as words, a
    // comment could cut a pipe (`a | # note` + newline + `bash` lost bash's
    // piped stdin) or open a quote (`# don't`). So reachesWithin() refuses
    // any marked command outright (#1317 review). Measured: 0 of the 404
    // rewritable commands in the 30-day refused set carry one.
    if (ch === '#' && !heredocBody && curText === '' && !parts.length && !wordQuoted) {
      out.hashWord = true;
    }
    curText += ch;
  }
  flushWord();
  return out;
}

// wordLiteralText/wordHasDynamic/wordDynamicPayloads moved to
// lib/shape-rewrite-reach.js (finding #8) and imported below -- pure
// accessors over the `word = { parts: [...] }` shape produced by
// reachWords(), used throughout this file's reach checks.

/**
 * Splits the flat reachWords() stream into command segments on
 * chain/pipe/subshell operators. Each segment is returned as
 * `{ tokens, pipedStdin }`: `pipedStdin` is true when the segment's stdin
 * traces back to a real single `|` (never `||`, which chains on exit
 * status, not stdin) -- finding #1 (adversarial review of PR #1295
 * round 3): reachesWithin() used to analyze every segment in isolation with
 * no memory of what operator preceded it, so nothing could tell "this
 * segment's stdin comes from a preceding command's stdout" from "this
 * segment starts fresh". That made a bare, argument-less `bash`/`sh` (or a
 * zero-argument INLINE_INTERPRETERS member) fed via a pipe indistinguishable
 * from the same command run standalone, even though piped stdin is exactly
 * the payload a `-c`/heredoc check already treats as reaching when it
 * arrives some other way.
 *
 * Finding #3 (round 5) then finding #1 (round 7) closed two layers of the
 * same defect class -- "checks only one lexical spelling of a chain
 * operator instead of the semantic category (still inside the group the
 * pipe fed)":
 *
 * Round 5: `(`/`)` are themselves SHELL_CHAIN_OPS members (segment() must
 * still split on them), but structurally they are TRANSPARENT grouping
 * punctuation, not a fresh command boundary -- `cmd | (bash)` still pipes
 * `cmd`'s stdout into the subshell's first command exactly as `cmd | bash`
 * would. The round-5 fix special-cased `(`/`)` to skip the
 * `curPipedStdin = e.value === '|'` reassignment.
 *
 * Round 7: that fix only covered a SINGLE-command group. Any OTHER chain
 * op inside the still-open group -- `;`, `&&`, `||`, `&`, newline -- still
 * hit the unconditional reassignment and clobbered the association anyway:
 * `cmd | (true; bash)` associated `bash`'s segment with pipedStdin=false,
 * because the interior `;` reset it before `bash` was ever reached. Adding
 * `;`/`&&` to a "transparent ops" set would be a fourth special case over
 * the same hole (the next operator spelling would reopen it); the actual
 * invariant is structural, not lexical: while still nested inside a group
 * that was open when the pipe fed it, EVERY command in that group shares
 * the group's stdin, regardless of which chain operator separates them.
 * `(` and `)` are not the only grouping syntax either -- a bare `{ ...; }`
 * command group is never tokenized as an 'op' at all (reachWords() only
 * special-cases `(`/`)` as isolated characters; `{`/`}` fall through into
 * ordinary word text unless they stand alone as their own
 * whitespace-delimited word, which is exactly bash's brace-group syntax),
 * so it needs the identical treatment via isBraceGroupWord() below.
 *
 * Fix: track actual group-nesting DEPTH, plus `pipedDepth` -- the depth at
 * which the current `curPipedStdin=true` was established. A non-pipe chain
 * op only clears the association once depth has returned to (not above)
 * `pipedDepth`: back at the same syntactic level the pipe itself was at,
 * not still nested inside the group it fed. A group-close that walks depth
 * back BELOW `pipedDepth` also clears it (we've now exited the very group
 * the pipe fed). Group-open/close never themselves set or clear the
 * association -- they only move `depth`.
 */
function isBraceGroupWord(e, ch) {
  return e.type === 'word' && e.quoted === false && !wordHasDynamic(e) && wordLiteralText(e) === ch;
}

function segment(entries) {
  const segments = [];
  let cur = [];
  // Whether `cur` (the segment currently being accumulated) traces its
  // stdin back to a real `|`; decided the moment `cur` starts, at the
  // boundary operator that closed the PREVIOUS segment -- not recomputed
  // later, so the final (unterminated) segment's flush below sees the same
  // value the loop already settled on.
  let curPipedStdin = false;
  let depth = 0;
  // Depth at which the current curPipedStdin=true was established; null
  // whenever curPipedStdin is false. Comparisons below rely on the
  // invariant that depth never falls below pipedDepth except at the exact
  // group-close that clears it (enforced in the isGroupClose branch).
  let pipedDepth = null;
  for (const e of entries) {
    const isRealChainOp = e.type === 'op' && SHELL_CHAIN_OPS.has(e.value);
    const isGroupOpen = (isRealChainOp && e.value === '(') || isBraceGroupWord(e, '{');
    const isGroupClose = (isRealChainOp && e.value === ')') || isBraceGroupWord(e, '}');
    if (!isRealChainOp && !isGroupOpen && !isGroupClose) { cur.push(e); continue; }

    if (cur.length) segments.push({ tokens: cur, pipedStdin: curPipedStdin });
    cur = [];

    if (isGroupOpen) {
      depth += 1;
    } else if (isGroupClose) {
      depth = Math.max(0, depth - 1);
      if (pipedDepth !== null && depth < pipedDepth) { curPipedStdin = false; pipedDepth = null; }
    } else if (e.value === '|') {
      curPipedStdin = true;
      pipedDepth = depth;
    } else if (pipedDepth === null || depth <= pipedDepth) {
      // Any other real chain op (';', '&&', '||', '&', '\n'): only clears
      // the association once we're back at (or above) the depth it began
      // at -- still nested deeper than that means still inside the group
      // the pipe fed, so the association survives.
      curPipedStdin = false;
      pipedDepth = null;
    }
  }
  if (cur.length) segments.push({ tokens: cur, pipedStdin: curPipedStdin });
  return segments;
}

/**
 * Wrapper-prefix skip for word-object segments (the reach check). Returns the
 * core words and whether the prefix was uncertain; the caller treats
 * uncertainty as reaching, since the command name is then unknown.
 */
function stripWordWrappers(words) {
  const { index, uncertain } = stripWrapperPrefix(
    words,
    (w) => (w.type === 'word' && !wordHasDynamic(w) ? wordLiteralText(w) : null),
    (w) => w.type === 'word' && w.quoted === true,
  );
  return { core: words.slice(index), uncertain };
}

function globPrefix(p) {
  const m = p.match(/[{*?[]/);
  return m ? p.slice(0, m.index) : p;
}

function isAbsentError(e) {
  // ENAMETOOLONG: no file system holds such a name, and no command can create or reveal it.
  return !!e && (e.code === 'ENOENT' || e.code === 'ENOTDIR' || e.code === 'ENAMETOOLONG');
}

/**
 * realpath a path that may not exist yet, one component at a time. Each `..`
 * applies to the physical directory reached so far, as the kernel applies it:
 * folding `..` lexically first (path.resolve, realpathSync) reads
 * `<root>/link/../etc` as `<root>/etc` when `link` points at `/`, and kept an
 * outside path in bounds (#1606 review). Past the first missing component the
 * rest is appended as text, which is sound only while it only descends: an
 * earlier `mkdir` in the same command can create that component, so a `..`
 * after it returns to real directories this check never resolved
 * (`<root>/m/../link/../etc`). That case resolves to `/`, which no root
 * contains. A dangling symlink also throws and counts as missing; it is
 * resolved through readlink so a write through it is judged at its target,
 * and that target's own `/` or missing state carries on into the rest.
 */
function resolveIsh(p, hops = 0) {
  let cur = '/';
  let missing = false;
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') {
      if (missing) return '/';
      cur = path.dirname(cur);
      continue;
    }
    const next = path.join(cur, seg);
    if (missing) { cur = next; continue; }
    try {
      cur = fs.realpathSync(next);
    } catch (e) {
      // Only nonexistence is "missing". Anything else (EACCES, EPERM, ELOOP)
      // means the component exists but cannot be read, and an earlier
      // `chmod` in the same command can open it onto a symlink this check
      // never saw, so it fails closed. ENOTDIR (a regular file mid-path)
      // is missing: nothing below a file can be traversed or hidden.
      if (!isAbsentError(e)) return '/';
      let target = null;
      try { if (fs.lstatSync(next).isSymbolicLink()) target = fs.readlinkSync(next); } catch (e2) { if (!isAbsentError(e2)) return '/'; }
      if (target !== null) {
        if (hops >= 40) return '/';
        cur = resolveIsh(path.isAbsolute(target) ? target : `${cur}/${target}`, hops + 1);
        // The target failed closed: stop here, or the rest would resolve from `/`.
        if (cur === '/') return '/';
        // A target that does not exist yet leaves the rest as text, as above.
        try { fs.lstatSync(cur); } catch (e3) { if (!isAbsentError(e3)) return '/'; missing = true; }
        continue;
      }
      missing = true;
      cur = next;
    }
  }
  return cur;
}

function underRoot(resolved, rootsResolved) {
  return rootsResolved.some((r) => resolved === r || resolved.startsWith(r + path.sep));
}

// A generic-argument word for one of these commands cannot touch a path
// through that argument (it only ever reads its own operand as text/output
// it never dereferences as a filesystem path), so an unresolved
// variable/expression there stays exempt from the generic-argument reach
// check (findings #2/#3): `echo ${X:-y}` and similar idioms stay usefully
// rewritable. This does NOT exempt redirect targets or tee's target
// (`always=true` never consults this set) -- writing wherever the variable
// happens to expand to is always unresolvable.
//
// Membership test is "does this command have ANY file-operand semantics at
// all", not merely "is its argument usually text" -- `jq`, `cut`, `sort`,
// `uniq`, `head`, `tail`, and `wc` were removed here, a containment hole:
// each of them can take a FILE operand (`sort -o file`/`uniq in out` WRITE
// one; `head`/`jq . `/`wc -l`/
// `cut -f1` READ one), so exempting that operand from the unresolvable-
// variable check let a `$var` there resolve to a read or write target
// outside the worktree while still being rewritten. `tr` stays: every one
// of its operands is a character-set spec or inline text, never a path.
// `date`, `test`, `[`, and `[[` were removed for the same bar (ce-code-review
// round on 2b279d2, finding #4): `date -f FILE` reads dates line-by-line
// from FILE (live-reproduced: non-date content in that file is echoed
// verbatim to stderr), and `test`/`[`/`[[`'s `-f`/`-e`/`-r`/`-w`/`-x`/`-s`
// operators file-test their operand -- checkPathWord has no flag-awareness
// to exempt only the non-file-test operands of these commands, so the
// entire command must lose the output-only exemption rather than gaining
// one it cannot enforce narrowly.
const OUTPUT_ONLY_COMMANDS = new Set([
  'echo', 'printf', 'printenv', 'true', 'false', ':',
  'expr', 'seq', 'basename', 'dirname', 'sleep', 'tr',
]);

// Every redirect operator whose operand names a filesystem path (finding
// #6). `>&` and `<&` are included because their operand is USUALLY an fd
// duplication target (a digit or `-`), not a path -- FD_DUP_OPS below
// carves that case out so `2>&1` and `exec 3>&-` are not misread as path
// writes, while `>&file`/`<&file` (a real path operand) still gets the
// full always=true check.
const REDIRECT_TARGET_OPS = new Set(['>', '>>', '>|', '&>', '&>>', '>&', '<', '<>', '<&']);
const FD_DUP_OPS = new Set(['>&', '<&']);
const FD_DUP_TARGET_RE = /^(-|\d+)$/;

/**
 * Checks one shell word used as a path-relevant argument.
 * `always`: true for redirect targets and `tee`'s target (checked
 * regardless of command) -- a dynamic or `$VAR`-bearing word there is
 * unconditionally unresolvable, since it names where the shell writes/reads.
 * `always=false` (a generic argument): a word built from a variable
 * reference or from a substitution (pure, or glued to literal text such as
 * `"$(dirname /etc)/x"`) is an unresolvable reach UNLESS `cmdName` is in
 * OUTPUT_ONLY_COMMANDS. The payload recursion validates a substitution's
 * own command, never its runtime output, so `cp $(cat list) dest` is
 * refused while `echo $(date)` stays rewritable (R4). Every remaining
 * literal word -- flag-looking or not -- is canonicalized and root-checked
 * exactly like the `always=true` path: only a word that resolves outside
 * every allowed root (directly or through a symlink) is reaching.
 * `noPathOverride`: true when the caller has already determined THIS
 * specific invocation is not path-capable even though `cmdName` alone would
 * not say so (gh-read no-path -- a `gh` read-verb call; ghNoPathSegment
 * decides this per-call, not per-command-name, since `gh pr edit` and
 * `gh pr view` share a command name but not this property).
 * Returns a reason string, or null.
 */
function checkPathWord(word, rootsResolved, bases, always, cmdName, noPathOverride) {
  const literalText = wordLiteralText(word);
  const dynamic = wordHasDynamic(word);
  const hasVarRef = /\$[A-Za-z_{]/.test(literalText);

  if (always) {
    if (dynamic || hasVarRef) {
      return `builds a path from a variable or expression this hook cannot resolve: ${JSON.stringify(literalText || '<dynamic>')}`;
    }
  } else {
    const outputOnly = OUTPUT_ONLY_COMMANDS.has(cmdName || '') || Boolean(noPathOverride);
    if (!outputOnly && (hasVarRef || dynamic)) {
      return `builds a path from a variable or expression this hook cannot resolve: ${JSON.stringify(literalText || '<dynamic>')}`;
    }
    if (dynamic && !literalText) return null; // output-only command: the payload itself was validated by recursion
  }

  if (!literalText) return null;

  // Tilde handling: `~` or `~/...` resolves against the invoking user's home
  // directory before the root check; `~someoneelse` (another user's home)
  // cannot be resolved the same way and is an unresolvable reach.
  let toResolve = literalText;
  if (toResolve === '~' || toResolve.startsWith('~/')) {
    toResolve = path.join(os.homedir(), toResolve.slice(1));
  } else if (toResolve.startsWith('~')) {
    return `builds a path from another user's home directory, which this hook cannot resolve: ${JSON.stringify(literalText)}`;
  }

  const prefix = globPrefix(toResolve);
  if (!prefix) return null;
  if (DEVICE_ALLOW.has(prefix)) return null;
  // A relative path is checked from every directory the command could be in
  // when it runs: the worktree root and each accepted `cd` target.
  for (const base of path.isAbsolute(prefix) ? [null] : bases) {
    // Joined as text, not path.resolve: resolveIsh must see `link/..` intact.
    const resolved = resolveIsh(base === null ? prefix : `${base}/${prefix}`);
    if (DEVICE_ALLOW.has(resolved)) continue;
    if (!underRoot(resolved, rootsResolved)) {
      return `path argument resolves outside every allowed root: ${resolved}`;
    }
  }
  return null;
}

const CD_REACH_REASON = 'command "cd" is treated as reaching outright unless its one operand is a literal '
  + 'absolute path, with no "." or ".." segment, inside an allowed root';

// A cd target is accepted only when every character is one that bash leaves
// alone in an unquoted word: no glob, brace, `$`, `~` or quoting syntax, and
// none of extglob's `?*+@!` prefixes, so the text checked is the directory
// bash enters (#1606 review: `@(x)` is split at its parenthesis by the
// tokenizer, which left the in-bounds prefix `/tmp/d/@` to be checked).
const CD_TARGET_RE = /^\/[A-Za-z0-9._/,:=-]+$/;

/** True when `word` is the builtin `cd` itself, spelled exactly; `./cd` is an executable. */
function isCdWord(word) {
  return word.type === 'word' && !wordHasDynamic(word) && wordLiteralText(word) === 'cd';
}

/**
 * The directories a command can run from: `inherited` plus the target of each
 * `cd` in it. A `cd` whose single operand is a literal absolute path matching
 * CD_TARGET_RE, with no `.` or `..` segment, that resolves inside an allowed
 * root keeps the command in bounds; any other `cd` reaches. The set is a
 * union across every segment, subshell and `&&`/`||` branch, never a
 * sequence, so a `cd` that fails or runs in a subshell only adds a directory
 * that is checked needlessly. Measured 2026-10-05: 285 of 663 cd-refused
 * calls in 7 days cd'd into /tmp, most of them CE review leaves writing
 * findings JSON there. Returns { bases } or { reason }.
 */
function cdBases(entries, rootsResolved, inherited) {
  const bases = [...inherited];
  for (const { tokens: seg } of segment(entries)) {
    const { core, uncertain } = stripWordWrappers(seg);
    if (uncertain || !core.length || !isCdWord(core[0])) continue;
    const operands = [];
    for (let i = 1; i < core.length; i += 1) {
      const e = core[i];
      if (e.type === 'op') {
        if (!REDIRECT_TARGET_OPS.has(e.value)) return { reason: CD_REACH_REASON };
        i += 1; // the redirect's own target; the segment loop path-checks it
        continue;
      }
      const next = core[i + 1];
      const fdNumber = next && next.type === 'op' && REDIRECT_TARGET_OPS.has(next.value)
        && !wordHasDynamic(e) && /^\d+$/.test(wordLiteralText(e));
      if (!fdNumber) operands.push(e);
    }
    if (operands.length !== 1 || wordHasDynamic(operands[0])) return { reason: CD_REACH_REASON };
    const target = wordLiteralText(operands[0]);
    if (!CD_TARGET_RE.test(target) || target.split('/').some((s) => s === '.' || s === '..')) {
      return { reason: CD_REACH_REASON };
    }
    const resolved = resolveIsh(target);
    if (!underRoot(resolved, rootsResolved)) return { reason: CD_REACH_REASON };
    if (!bases.includes(resolved)) bases.push(resolved);
  }
  return { bases };
}

/**
 * Recurses into the reach check for a raw text payload (a substitution's
 * body, a heredoc's unquoted body, a shell -c argument). `roots[0]` is the
 * base used to resolve relative paths (the worktree root), together with
 * each accepted `cd` target (cdBases).
 */
function reaches(command, roots, options) {
  if (typeof command !== 'string' || !command.trim()) return null;
  const rootsResolved = roots.map((r) => { try { return fs.realpathSync(r); } catch { return path.resolve(r); } });
  // F2 (adversarial review of PR #1295 round 6): `options.deadline` is an
  // ABSOLUTE Date.now() value, used by run() to share one budget across both
  // its detectShapes() and reaches() calls (see the ANALYSIS_BUDGET_MS doc
  // comment above). `options.budgetMs` is a RELATIVE, test-only override
  // seam (a negative value forces the deadline into the past, exercising the
  // fail-closed path deterministically). A direct caller supplying neither
  // (every existing test, and any other future caller of the exported
  // `reaches`) gets its own fresh default budget, unchanged from before this
  // finding.
  const deadline = (options && typeof options.deadline === 'number')
    ? options.deadline
    : Date.now() + ((options && typeof options.budgetMs === 'number') ? options.budgetMs : ANALYSIS_BUDGET_MS);
  try {
    return reachesWithin(command, roots, rootsResolved, deadline);
  } catch (err) {
    if (err instanceof AnalysisBudgetExceeded) {
      // Fail closed: for this rewrite-only hook, "closed" means "grant no
      // rewrite," i.e. treat the command as reaching outright so run() falls
      // through to `return rawInput` (the verifier's original refusal
      // stands) rather than risk clearing a command that could not be fully
      // analyzed in time.
      return 'internal reach analysis exceeded its execution budget and could not be fully checked -- treated as reaching outright, fail closed';
    }
    throw err;
  }
}

/** The recursive body of `reaches`: roots are resolved once per top-level call, never per nesting level. */
function reachesWithin(command, roots, rootsResolved, deadline, heredocBody, inheritedBases) {
  if (typeof command !== 'string' || !command.trim()) return null;
  checkBudget(deadline); // F2: bounds pathological recursion depth x fan-out

  const heredocs = findHeredocs(command, deadline);
  const withoutHeredocBodies = excludeHeredocBodies(command, heredocs);
  const entries = reachWords(withoutHeredocBodies, { heredocBody });

  // Every relative path below, including those in nested payloads, resolves
  // from each directory a `cd` in this command could leave it in.
  const cd = cdBases(entries, rootsResolved, inheritedBases || [roots[0]]);
  if (cd.reason) return cd.reason;
  const { bases } = cd;

  for (const h of heredocs) {
    if (!h.quoted) {
      const r = reachesWithin(h.body, roots, rootsResolved, deadline, true, bases);
      if (r) return r;
    }
  }

  if (entries.hashWord) {
    return 'has a word-start "#" (a comment, or extglob or arithmetic text), which this hook does not analyze -- treated as reaching outright';
  }

  // Recurse into every substitution/process-substitution payload wherever it occurs.
  for (const e of entries) {
    if (e.type !== 'word') continue;
    for (const payload of wordDynamicPayloads(e)) {
      checkBudget(deadline); // F2: bounds a pathological substitution-payload FAN-OUT
      const r = reachesWithin(payload, roots, rootsResolved, deadline, false, bases);
      if (r) return r;
    }
  }

  // Maps each `<<`/`<<-` op ENTRY (by object identity) in `entries` to its
  // `findHeredocs()` record (quoted flag included), for the interpreter
  // carve-out below (interp family). `entries` is the flat, unsegmented
  // stream in the same left-to-right order `findHeredocs` scanned the
  // original text in, and body-removal never reorders operators, so the
  // k-th heredoc op encountered here is always `heredocs[k]` -- this holds
  // regardless of which segment the op ends up in after segment().
  const heredocOpToInfo = new Map();
  {
    let hIdx = 0;
    for (const e of entries) {
      if (e.type === 'op' && (e.value === '<<' || e.value === '<<-')) {
        heredocOpToInfo.set(e, heredocs[hIdx]);
        hIdx += 1;
      }
    }
  }

  for (const { tokens: seg, pipedStdin } of segment(entries)) {
    checkBudget(deadline); // F2: bounds a pathological segment-COUNT input
    const { core, uncertain } = stripWordWrappers(seg);
    if (uncertain) return 'a wrapper option could not be classified, so the command name is unknown';
    if (!core.length || core[0].type !== 'word') continue;
    // A segment made ENTIRELY of assignment words (`NAME=value`,
    // `NAME=$(...)`) is a variable-binding statement, not a command
    // invocation -- there is no command name to resolve. Every dynamic
    // payload in it was already recursed into and validated above (the
    // substitution-payload loop just above); the bound variable's later use
    // is checked wherever it is actually read, in ITS OWN segment.
    // stripWordWrappers already strips a PURE-LITERAL leading assignment
    // (`A=1`) via stripWrapperPrefix's own ASSIGNMENT_RE check, leaving
    // `core` empty (already handled by the guard above). This covers the
    // case that stripper cannot advance past: a GLUED assignment +
    // substitution word (`SCRATCH=$(mktemp ...)`, no space before `$(`),
    // whose literalOf is null (it has a dynamic part) and so never matches
    // that stripper's own ASSIGNMENT_RE test. `V=$(date) printenv V` does
    // NOT match (a real command word follows in the same segment) and keeps
    // today's behavior (assignment substitution).
    const allAssignments = core.every((w) => w.type === 'word'
      && ASSIGNMENT_RE.test(wordLiteralText(w)));
    if (allAssignments) continue;
    const first = core[0];
    const firstLiteralText = wordLiteralText(first);
    // A command name is unresolvable both when it is built from a
    // substitution/process-substitution (wordHasDynamic) and when its literal
    // text carries a bare `$VAR`/`${VAR...}` reference that reachWords does
    // not parse into a `sub` part (finding #4): `g${EMPTY:-}it` must not read
    // as the literal text "git".
    const dynamicCore = wordHasDynamic(first) || /\$[A-Za-z_{]/.test(firstLiteralText);
    const name = dynamicCore ? '' : basenameToken(firstLiteralText);

    if (dynamicCore) {
      return 'command name is built from an unresolvable variable or expression';
    }

    // Whole-segment reach-name scan (finding #1b): a wrapper this hook does
    // not recognise (nice/time/command/builtin/stdbuf/setsid/flock/... or any
    // future one) must not silently hide a reach-checked command name one
    // position later. Scan every literal word in `core` other than the head:
    // if its basename names git, gh, or a command in REACH_COMMANDS,
    // OPAQUE_ALWAYS, SHELLS, or INLINE_INTERPRETERS, treat the whole call as
    // reaching -- this closes every unknown-wrapper variant in one rule,
    // independent of WRAPPER_OPTIONS ever being complete.
    for (let k = 1; k < core.length; k += 1) {
      const w = core[k];
      if (w.type !== 'word' || wordHasDynamic(w)) continue;
      const wName = basenameToken(wordLiteralText(w));
      if (wName === 'git' || wName === 'gh' || REACH_COMMANDS.has(wName)
        || OPAQUE_ALWAYS.has(wName) || SHELLS.has(wName) || INLINE_INTERPRETERS.has(wName)) {
        return `names "${wName}", a command this hook treats as reaching, outside the command position (a wrapper or an argument), so the call cannot be classified`;
      }
    }

    if (name === 'git') return 'command "git" is treated as reaching outright';
    // A builtin `cd` here was accepted by cdBases above (the same isCdWord
    // test); its operand and any redirect are still path-checked by the
    // generic scan below. `./cd` and `/x/cd` are executables and still reach.
    if (REACH_COMMANDS.has(name) && !isCdWord(first)) return `command "${name}" is treated as reaching outright`;
    if (OPAQUE_ALWAYS.has(name)) return `command "${name}" is opaque to static analysis and is treated as reaching outright`;

    if (name === 'find') {
      const hasExec = core.some((w) => w.type === 'word' && !wordHasDynamic(w) && /^-exec(dir)?$/.test(wordLiteralText(w)));
      if (hasExec) return 'command "find" with -exec/-execdir is treated as reaching outright';
    }

    let ghNoPath = false;
    if (name === 'gh') {
      // Read the subcommand from the fixed, global-flag-skipped position
      // (finding #10): this is the same `ghSubcommandPosition()` helper
      // gh-read no-path already uses just below, rather than a second,
      // separately-implemented unbounded scan over every adjacent literal
      // pair in `core`. The unbounded form let a WRITE call whose ARGUMENT
      // VALUES happened to contain "pr"/"checkout" or "repo"/"clone"/"sync"
      // as an adjacent pair (e.g. inside a `--title`/`--body` value) read as
      // reaching for the wrong reason, or -- more subtly -- matched a real
      // subcommand pair split by an intervening flag purely by chance of
      // position; anchoring to the fixed subcommand slot removes that
      // false-match surface entirely. A global flag before the subcommand
      // pair (`gh --repo owner/repo pr checkout 123`) still resolves
      // (finding #5); a flag splitting the pair itself (`gh pr --repo
      // owner/repo checkout 123`) stays a residual gap, unchanged by this
      // replacement (ghSubcommandPosition only skips flags BEFORE b1).
      //
      // ghReachesOutright() (findings #3/#6, round 3) replaces what used to
      // be a two-pair hardcoded literal check here: any verb NOT positively
      // recognized as a read shape is write-shaped, unconditionally -- this
      // is what closes `gh co 123` (gh's own built-in alias for `pr
      // checkout`) and an interposed unrecognized global flag shifting the
      // anchor, neither of which a hardcoded pair table could ever
      // anticipate. `api`/`search`/`auth status` keep their own
      // nuanced/exempt dispatch (see ghReachesOutright's own doc comment).
      if (ghReachesOutright(core)) {
        const { b1: ghB1, b2: ghB2 } = ghSubcommandPosition(core);
        const shown = [ghB1, ghB2].filter((w) => w !== null).join(' ');
        return `command "gh ${shown}" is not a recognized read-only gh shape and is treated as reaching outright`;
      }
      // gh-read no-path: a read-verb `gh` call is not path-capable -- its
      // generic arguments (a `$n`, a `--jq` string with `\(...)`) never name
      // a filesystem path, so they are exempt from the generic-argument
      // reach check below exactly like OUTPUT_ONLY_COMMANDS.
      ghNoPath = ghNoPathSegment(core);
    }

    if (name === 'ln' || name === 'cp') {
      const flagged = core.slice(1).some((w) => w.type === 'word' && !wordHasDynamic(w) && isUnbundledFlagCluster(wordLiteralText(w), isAlphaChar, 'sf') && wordLiteralText(w).startsWith('-') && !wordLiteralText(w).startsWith('--'));
      if (flagged) return `command "${name}" creates a symlink and is treated as reaching outright`;
    }

    // Finding #1 (P0): compute this segment's `<<`/`<<-` heredoc ops once,
    // so INLINE_INTERPRETERS, SHELLS, and the default-deny fallback below
    // all share one source of truth for "does this segment feed a heredoc".
    // Scoped to `<<`/`<<-` only, never `<<<` or plain `<`: an unquoted
    // `<<`/`<<-` body is already unconditionally recursed into at the top
    // of this function (the heredocs loop before the segment loop begins);
    // a QUOTED `<<`/`<<-` body is the actual gap this finding closes (never
    // scanned unless the consuming command has an explicit rule below); and
    // `<<<`/`<` targets remain ordinary tokens the generic redirect-
    // target/argument scan at the end of this loop already covers in full
    // (a `<<<` target is a plain word subject to the same checkPathWord
    // call as any other argument; a `<` target is a REDIRECT_TARGET_OPS
    // member, checked with always=true).
    const heredocOpsInSeg = seg.filter((e) => e.type === 'op' && (e.value === '<<' || e.value === '<<-'));
    const hasHeredocRedirect = heredocOpsInSeg.length > 0;

    if (INLINE_INTERPRETERS.has(name)) {
      // The word immediately following a `<<`/`<<-` op in `seg` is that
      // heredoc's DELIMITER (its terminator token, e.g. `EOF` in `<<'EOF'`)
      // -- never a program argument. Exclude it from every operand scan
      // below; otherwise a heredoc-fed interpreter's own delimiter always
      // reads as "some other operand" and defeats the item-1 carve-out for
      // every case it exists to cover (found via direct tokenizer probe:
      // `python3 - <<'EOF'` produced core words [python3, -, <<, EOF] and
      // the bare EOF word tripped hasOtherOperand below).
      const heredocDelimWords = new Set();
      for (let k = 0; k < seg.length; k += 1) {
        if (seg[k].type === 'op' && (seg[k].value === '<<' || seg[k].value === '<<-')) {
          const next = seg[k + 1];
          if (next && next.type === 'word') heredocDelimWords.add(next);
        }
      }
      // `core` (unlike detectShapes' pre-heredoc-sliced token list) still
      // carries the `<<`/`<<-` op entries themselves alongside their
      // delimiter words -- excluded here by type, not just by identity, so
      // an op entry can never be miscounted as a dynamic "other operand" by
      // the shared shape predicate below.
      const rest = core.slice(1).filter((w) => w.type === 'word' && !heredocDelimWords.has(w));
      // F1 (adversarial review of PR #1295 round 6, P1): this used to carve
      // out a bare "-" argument fed by a QUOTED-delimiter heredoc as
      // rewritable whenever the heredoc BODY passed a denylist scan
      // (heredocBodyReaches(), lib/shape-rewrite-reach.js). Live-reproduced
      // against 682831d: a denylist/pattern scan over a Turing-complete
      // language's raw source text cannot be made sound against composed or
      // computed constructions -- `chr()`-built path strings and a
      // `getattr(os, 'sys'+'tem')`-based dynamic dispatch both read `null`
      // (not reaching) with zero denylisted literal ever appearing in the
      // source text, for an outside-root file read, an outside-root file
      // write, and an `os.system` shell-out. The code's own prior comment
      // already disclosed this as an accepted "literal tripwire, not a
      // containment proof" residual risk; live testing showed the two most
      // basic obfuscations (character-code construction, attribute lookup)
      // defeat it with no sophistication required, which is more severe
      // than "residual." No sound, non-enumerative gate for this carve-out
      // was articulated (the only way to make it sound is to actually parse
      // the target language's AST and separately verify every one of
      // python/node/perl/ruby's dynamic-dispatch and string-construction
      // forms are absent -- out of proportion for a shell-command-shape
      // classifier, and not attempted here) -- so per the reviewing task's
      // own instruction ("if you cannot articulate (b) precisely, take
      // (a)"), the carve-out is REVERTED outright: a bare "-" argument fed
      // by ANY heredoc (quoted or not) is, again, unconditionally treated
      // as reaching, restoring the pre-#1273 rule this carve-out reversed.
      // `hasHeredocRedirect` alone (already required for this shape, since
      // isInterpStdinArgShape's caller always has at least one heredoc
      // here) now takes the branch that `hasSuspiciousArg || hasHeredocRedirect`
      // already took for the unquoted/suspicious-arg case -- there is no
      // longer a quoting-conditional distinction at all. The heredoc-body
      // denylist scan this carve-out depended on (HEREDOC_BODY_LITERAL_DENY,
      // heredocBodyReaches, and the rest of that family in
      // lib/shape-rewrite-reach.js) is removed in this same commit, since it
      // no longer has any caller and would otherwise be dead, misleading
      // code claiming to gate a carve-out that no longer exists.
      const restTokens = toLiteralTokens(rest);
      const hasSuspiciousArg = restTokens.some((t) => !t.dynamic
        && (/^(-c|-m|-e|--eval)$/.test(t.literal) || t.literal === '-'));
      if (hasSuspiciousArg || hasHeredocRedirect) {
        return `interpreter "${name}" runs an inline or stdin-fed program and is treated as reaching outright`;
      } else if (pipedStdin) {
        // Finding #1 (INLINE_INTERPRETERS residual, same root cause as the
        // SHELLS-block fix just below): a zero-argument interpreter fed via
        // a real pipe (e.g. `echo 'print(1)' | python3`) reads its piped
        // stdin as the program to run, identical in effect to the `-`/-c/
        // heredoc shapes just handled above, except `isInterpStdinArgShape`
        // requires an explicit bare `-` token and returns false for a
        // wholly empty `restTokens`, so a bare `python3` with no arguments
        // at all fell through every existing check.
        const hasNonFlagOperand = sharedHasNonFlagOperand(restTokens, STDIN_ALIAS_PATHS);
        if (!hasNonFlagOperand) {
          return `interpreter "${name}" reads its piped stdin as a program and is treated as reaching outright`;
        }
      }
    }

    if (SHELLS.has(name)) {
      // Finding #1 (SHELLS residual): a heredoc fed to a shell is `bash -c`
      // smuggling regardless of quoting -- an unquoted body's LITERAL
      // script text (no `$()`/backtick substitution to trip the top-level
      // recursive scan above) would otherwise run unaudited, and a quoted
      // body is the same unscanned-payload gap the default-deny below
      // closes for every other command. Checked before -c payload
      // recursion, since a shell fed both a heredoc and -c is reaching on
      // the heredoc alone.
      if (hasHeredocRedirect) {
        return `shell "${name}" is fed a heredoc body and is treated as reaching outright`;
      }
      const rest = core.slice(1);
      for (let i = 0; i < rest.length; i += 1) {
        const w = rest[i];
        if (w.type !== 'word' || wordHasDynamic(w)) continue;
        if (!isUnbundledFlagCluster(wordLiteralText(w), isWordChar, 'c')) continue;
        const payloadWord = rest[i + 1];
        if (payloadWord && payloadWord.type === 'word') {
          if (wordHasDynamic(payloadWord)) {
            return 'shell -c payload is built from an unresolvable variable or expression';
          }
          const r = reachesWithin(wordLiteralText(payloadWord), roots, rootsResolved, deadline, false, bases);
          if (r) return r;
        }
        break;
      }
      // Finding #1 (adversarial review of PR #1295 round 3): a shell fed via
      // a real PIPE (this segment's stdin is the previous segment's
      // stdout -- `pipedStdin`, threaded through from segment() above) with
      // no `-c` payload (handled by the loop just above) and no literal
      // positional script-file argument reads that piped stdin as its own
      // script, exactly like the heredoc-fed case above: `echo 'touch
      // /etc/PWNED' | bash` and the "safe sink" variant `cat <<'EOF' | bash`
      // both hit this -- the piping command's own segment passes every
      // check in isolation (echo/cat never execute their own stdin), and a
      // bare, argument-less `bash`/`sh` segment has no heredoc, no -c, and
      // no argument for the generic literal-argument scan below to ever
      // flag. A literal non-flag operand (`bash script.sh`) is a real
      // script-file argument -- the shell does not read stdin as its
      // program when one is present, so that case is deliberately left
      // alone here (and stays subject to the ordinary argument/path scan
      // below, same as any other command's file operand).
      const hasNonFlagOperand = sharedHasNonFlagOperand(toLiteralTokens(rest), STDIN_ALIAS_PATHS);
      if (pipedStdin && !hasNonFlagOperand) {
        return `shell "${name}" reads its piped stdin as a script and is treated as reaching outright`;
      }
    }

    // Finding #1 (P0) default-deny: a quoted `<<`/`<<-` heredoc body fed to
    // any command with no explicit heredoc rule above (ssh, psql, and every
    // other stdin-reading client this hook does not name) is reaching
    // outright. INLINE_INTERPRETERS and SHELLS are fully handled above
    // (each already returns when reaching, or deliberately falls through
    // when not); this covers every other command name. The safe-sink
    // exception -- cat/tee/OUTPUT_ONLY_COMMANDS -- is the one case
    // explicitly permitted to skip this: none of those commands execute
    // their stdin as code, and each one's own write target (tee's operand,
    // any `>` redirect) is already checked by the generic redirect/argument
    // scan just below, so an inert heredoc body handed to one of them needs
    // no body scan at all (unlike the interp carve-out, which DOES scan the
    // body, because an interpreter DOES execute it).
    if (hasHeredocRedirect && !INLINE_INTERPRETERS.has(name) && !SHELLS.has(name)) {
      const anyQuoted = heredocOpsInSeg
        .map((e) => heredocOpToInfo.get(e))
        .some((h) => h && h.quoted);
      const isSafeSink = name === 'cat' || name === 'tee' || OUTPUT_ONLY_COMMANDS.has(name);
      if (anyQuoted && !isSafeSink) {
        return `command "${name}" is fed a quoted heredoc body this hook cannot classify as inert and is treated as reaching outright`;
      }
    }

    // Generic argument/redirect-target scan for every word in this segment.
    // `coreStart` is core's offset within `seg` (wrapper words precede it):
    // the tee special case (finding #7) must key off "is this the command
    // word", not "is this the first word of the segment" -- `sudo tee` and
    // `env FOO=1 tee` put tee's own word past index 0 in `seg`.
    const coreStart = seg.length - core.length;
    for (let i = 0; i < seg.length; i += 1) {
      const e = seg[i];
      if (e.type === 'op' && REDIRECT_TARGET_OPS.has(e.value)) {
        const target = seg[i + 1];
        if (target && target.type === 'word') {
          if (FD_DUP_OPS.has(e.value) && !wordHasDynamic(target) && FD_DUP_TARGET_RE.test(wordLiteralText(target))) {
            // fd duplication (`2>&1`, `exec 3<&-`): the operand names a file
            // descriptor, not a path -- do not path-check it.
          } else {
            const r = checkPathWord(target, rootsResolved, bases, true, name);
            if (r) return r;
          }
        }
        continue;
      }
      if (e.type !== 'word') continue;
      if (i === coreStart && !dynamicCore && name === 'tee') {
        for (let j = i + 1; j < seg.length; j += 1) {
          const arg = seg[j];
          if (arg.type !== 'word') break;
          if (!wordHasDynamic(arg) && wordLiteralText(arg).startsWith('-')) continue;
          const r = checkPathWord(arg, rootsResolved, bases, true, name);
          if (r) return r;
          break;
        }
      }
      const r = checkPathWord(e, rootsResolved, bases, false, name, ghNoPath);
      if (r) return r;
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// U2: run (the PreToolUse entry point)
// ---------------------------------------------------------------------------

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

function sanitizeId(v) {
  const s = String(v || '').replace(/[^\w-]/g, '');
  return s || 'x';
}

const PRUNE_MS = 24 * 60 * 60 * 1000;
function pruneOldScripts(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch {
    return;
  }
  const cutoff = Date.now() - PRUNE_MS;
  for (const name of entries) {
    if (!name.startsWith('shape-rewrite-')) continue;
    const p = path.join(dir, name);
    try {
      const st = fs.statSync(p);
      if (st.mtimeMs < cutoff) fs.unlinkSync(p);
    } catch {
      /* races with a concurrent prune are fine to ignore */
    }
  }
}

function worktreeRootOf(cwd) {
  let real;
  try {
    real = fs.realpathSync(cwd);
  } catch {
    real = path.resolve(String(cwd || ''));
  }
  const m = /^(.*[\\/]\.claude[\\/]worktrees[\\/][^\\/]+)(?:[\\/]|$)/.exec(real);
  return m ? m[1] : null;
}

/**
 * @param {string} rawInput - JSON string from Claude Code stdin
 * @returns {string} the rewrite JSON, or the raw input unchanged (pass-through)
 */
function run(rawInput) {
  try {
    if (String(process.env.SHAPE_REWRITE_DISABLE || '') === '1') return rawInput;

    const input = JSON.parse(rawInput);
    if (input.tool_name !== 'Bash') return rawInput;
    const ti = input.tool_input;
    if (!ti || typeof ti !== 'object' || Array.isArray(ti)) return rawInput;
    const command = ti.command;
    if (typeof command !== 'string' || !command.trim()) return rawInput;

    const worktreeRoot = worktreeRootOf(input.cwd);
    if (!worktreeRoot) return rawInput;

    let scratchDir = typeof input.scratchpad_dir === 'string' && input.scratchpad_dir
      ? input.scratchpad_dir
      : (process.env.CLAUDE_JOB_DIR ? path.join(process.env.CLAUDE_JOB_DIR, 'tmp') : '');
    if (!scratchDir) return rawInput;
    try {
      fs.mkdirSync(scratchDir, { recursive: true });
    } catch {
      return rawInput;
    }

    // F2 (adversarial review of PR #1295 round 6): ONE shared absolute
    // deadline for BOTH analysis calls below, computed once here rather than
    // letting each of detectShapes/reaches compute its own fresh
    // ANALYSIS_BUDGET_MS-relative budget -- the latter would let total
    // wall-clock time run up to ~2x the configured budget on a single
    // invocation, eating into the margin under the hook's registered 5000ms
    // CLI timeout for no benefit (a rewrite is only offered when BOTH calls
    // finish anyway).
    const deadline = Date.now() + ANALYSIS_BUDGET_MS;

    const shapes = detectShapes(command, deadline);
    if (!shapes.length) return rawInput;

    let scratchReal;
    try { scratchReal = fs.realpathSync(scratchDir); } catch { scratchReal = path.resolve(scratchDir); }
    let tmpReal;
    try { tmpReal = fs.realpathSync(os.tmpdir()); } catch { tmpReal = os.tmpdir(); }
    const jobsDir = path.join(os.homedir(), '.claude', 'jobs');
    let jobsReal;
    try { jobsReal = fs.realpathSync(jobsDir); } catch { jobsReal = jobsDir; }
    const roots = [worktreeRoot, scratchReal, tmpReal, jobsReal];

    if (reaches(command, roots, { deadline })) return rawInput;

    const shapeName = shapes.join('+');
    const toolUseId = sanitizeId(input.tool_use_id || input.id);
    const scriptPath = path.join(scratchDir, `shape-rewrite-${shapeName}-${toolUseId}.sh`);
    // The rewritten call is `bash <path>` unquoted (the doc's measured PASS shape);
    // a scratch path carrying whitespace would split into arguments, so fail open.
    if (/\s/.test(scriptPath)) return rawInput;
    const receipt = rewriteReceipt(shapeName, scriptPath);
    const body = `#!/usr/bin/env bash\necho ${shellQuote(receipt)}\n${command}\n`;

    try {
      // 'wx': exclusive create, fails with EEXIST rather than overwriting.
      // Two concurrent rewrites that land on the same tool_use_id-derived
      // scriptPath (finding #13) must never clobber each other's script;
      // the existing catch below already fails open (pass-through) on any
      // write error, so EEXIST needs no special handling beyond the flag.
      fs.writeFileSync(scriptPath, body, { flag: 'wx', mode: 0o600 });
    } catch {
      return rawInput;
    }

    pruneOldScripts(scratchDir);

    try {
      logDenial({
        guard: `shape-rewrite:${shapeName}`,
        tool: 'Bash',
        command,
        reason: receipt,
        sessionId: input.session_id,
        agentId: input.agent_id,
        cwd: input.cwd,
      });
    } catch {
      /* counting is optional; the rewrite is not */
    }

    return JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecisionReason: receipt,
        updatedInput: { ...ti, command: `bash ${scriptPath}` },
      },
    });
  } catch {
    // Invalid JSON, unexpected shape, or any surprise -- pass through (fail-open, KTD10).
  }
  return rawInput;
}

/** The line a rewritten script echoes before running the original command. */
function rewriteReceipt(shapeName, scriptPath) {
  return `[shape-rewrite] rewritten: ${shapeName}; no action needed; `
    + `original: ${scriptPath}; signature: guard_blocked:shape-rewrite:${shapeName}`;
}

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { if (data.length < 1024 * 1024) data += chunk; });
  process.stdin.on('end', () => { writeHookOutput(run(data), data); process.exit(0); });
}

module.exports = {
  run, detectShapes, reaches, stripWrappers,
  // Exported so shape-refusal-mine.js sizes the heredoc family with the
  // hook's own predicate instead of a private copy (#1365).
  heredocBodyHasQuoteInBraces,
  // Exported for the committed differential fuzz (round-8 adversarial review
  // of PR #1295, finding #1): the fuzz must call the REAL predicates this
  // module uses at its two call sites, not a test-local reimplementation
  // that could silently drift from them and validate nothing.
  isUnbundledFlagCluster, isWordChar, isAlphaChar,
  // Exported for a tokenizer-correctness test only (round-8 adversarial
  // review, finding #4): reachWords() mis-tokenizes `<<-EOF` as op `<<` +
  // word `-EOF` instead of op `<<-` + word `EOF`. Refuted as a security
  // finding (hasHeredocRedirect counts op entries only, and
  // heredocOpToInfo pairs sequentially by position -- neither cares about
  // the specific `<<` vs `<<-` string), but it is a real tokenizer bug the
  // committed test below pins directly.
  reachWords,
  // Exported for the agreement test in tests/heredoc-scan.test.js (#1853):
  // the shared lib/heredoc-scan.js must find the same heredocs this module
  // does on the inputs both handle.
  findHeredocs,
  // Exported so papercut-log.js's receipt-skip test runs on the real line
  // (dotfiles#1840), not a copy that could drift from it.
  rewriteReceipt,
};
