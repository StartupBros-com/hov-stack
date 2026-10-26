#!/usr/bin/env node
/**
 * PreToolUse Hook: grep bounded-repeat cost guard
 *
 * Claude Code can shadow `grep` with an embedded ugrep binary. Some paired
 * bounded single-character regex repeats make affected ugrep builds grow
 * without bound on large inputs. This guard stops the high-cost command shape
 * before Bash starts it. It is deliberately engine-agnostic so swapping `grep` for `ugrep`,
 * `rg`, or another grep-family binary cannot turn a retry into another OOM.
 *
 * Three shapes are handled:
 *   - paired bounded spans with an upper-bound product >= COST_THRESHOLD: DENY.
 *   - a pattern file (-f/--file): DENY (contents cannot be inspected).
 *   - an opaque expanded operand (`grep "$w" f`, `for w in ..; do grep "$w"`):
 *     BOUNDED, not refused. Bash expands the operand after this hook runs, so
 *     the hook cannot judge it; refusing cost a wasted turn per call (174
 *     refusals in 14 days, dotfiles#1737). Instead `updatedInput.command`
 *     becomes the original call behind one inline prefix,
 *       `ulimit -t <seconds> 2>/dev/null; ulimit -v <KiB> 2>/dev/null; <original>`
 *     so the Bash tool's own shell carries two per-process limits that every
 *     child inherits, a backgrounded grep and a run_in_background call
 *     included:
 *       - `ulimit -t` (default 600 CPU seconds), the time bound, and the
 *         only one: on Claude Code 2.1.x a foreground call that reaches the
 *         Bash tool's timeout is moved to the background, not stopped
 *         (code.claude.com/docs/en/tools-reference, "Foreground commands
 *         that move to the background"), so nothing outside the call ends a
 *         runaway grep.
 *       - `ulimit -v` (default 8 GiB), the direct bound on a grep engine
 *         growing without bound. 8 GiB was probed to leave node, python3,
 *         jq, grep and rg working (#1738, the PR for #1737).
 *     Each limit is its own statement: Bash's ulimit stops at the first
 *     option it cannot set, so a single `ulimit -v 8388608 -t 600` under a
 *     hard -v limit below 8 GiB installed neither (Pro round 1 on #1738,
 *     P2). A limit the shell cannot raise is a stricter one already in
 *     place: as non-root `ulimit -t N` or `-v N` fails only when N is above
 *     the hard limit, which bounds every child below N already, and as root
 *     it never fails. So a failed statement is left to fail, never retried
 *     and never a reason to refuse the call: a preset hard -v of 1 GiB
 *     stays at 1 GiB and the CPU bound is installed beside it. The one
 *     thing the prefix cannot do inline is keep a lower *soft* limit under
 *     a higher hard one (`ulimit -v N` raises it to N); reading the current
 *     value would need `$( )`, which the worktree verifier refuses in
 *     argument position (harness/worktree-command-shapes.md).
 *     No script, wrapper shell or re-exec: the original text follows the
 *     prefix as its own subcommands, so settings deny and ask rules, which
 *     Claude Code evaluates against the updated input and against every
 *     subcommand (code.claude.com/docs/en/permissions, "Compound commands"),
 *     and the worktree verifier judge exactly what they judged before. The
 *     earlier `bash <script>` rewrite hid both (ce-code-review P1 on #1738).
 *     Outside bypass mode the `ulimit` subcommand needs an allow rule, as
 *     `bash <script>` did. Shell functions and aliases from the Bash tool's
 *     snapshot, and a leading `cd`, behave as in any other call.
 *     Either bound is changed per call by writing `GREP_COST_GUARD_VMEM_KB=<KiB>`
 *     or `GREP_COST_GUARD_TIMEOUT_S=<CPU seconds>` at the start of the
 *     command, as a leading assignment (`GREP_COST_GUARD_VMEM_KB=0 grep …`,
 *     `GREP_COST_GUARD_TIMEOUT_S=120; grep …`; 0 lifts that bound; with
 *     both lifted the call passes through unchanged and is still logged).
 *     Only that leading run of unquoted `NAME=value` words counts, the last
 *     assignment of a name winning as in Bash: the same text in a comment, a
 *     quoted string, an argument or a branch that may never run is not an
 *     assignment Bash makes before the grep, so it cannot lift a bound (Pro
 *     round 1 on #1738, P1; the earlier regex matched the raw text anywhere).
 *     The hook's process environment, which the Bash tool shares, overrides
 *     both. Bash state does not persist between tool calls, so an assignment
 *     in an earlier call never reaches this one.
 *     An operand whose literal text already holds an expensive paired span
 *     (`grep "$x.{0,60}y.{0,60}"`) is denied as before: the span check runs
 *     before the opaque check. A denial always outranks the bound across the
 *     whole command too: every grep in the call is inspected, every `-exec`
 *     of a `find` included, and one paired-span or pattern-file grep
 *     anywhere in it denies, whatever opaque grep came first (`grep "$w" f;
 *     grep -E ".{0,60}x.{0,60}" f` is denied, never run under the bound).
 *     The bound covers the whole call, not only the grep (`grep "$x" f &&
 *     pnpm test` runs under it too): a documented trade-off, since the
 *     tokenizer carries no offsets to wrap one word. A runtime that reserves
 *     more than 8 GiB of address space (V8 WebAssembly guard regions) can
 *     fail under the ulimit; GREP_COST_GUARD_VMEM_KB=0 in the command lifts it.
 *     Only one updatedInput survives a PreToolUse round (hooks complete in no
 *     fixed order), so this rewrite never shares a call with another:
 *       - shape-rewrite.js passes through any command whose grep operand is
 *         a variable or expansion ("builds a path from a variable or
 *         expression this hook cannot resolve"); a test here pins that, and
 *         widening shape-rewrite's reach resolution means composing the two
 *         rewrites first;
 *       - heavy-job-admission.js wraps heavy build or typecheck commands in
 *         its admission supervisor, so a call that carries both an opaque
 *         grep and a heavy job (`grep "$x" f && pnpm build`) is denied here,
 *         as it was before the rewrite existed, with the ask to run the heavy
 *         job in its own call. The check is heavy-job-admission's own exported
 *         analyzeCommand, the way shape-rewrite defers to it;
 *       - codex-quota-guard.js rewrites a Codex spend (`codex exec`, `codex
 *         review`, the app server) to an available model when the active
 *         subscription is explicitly exhausted, so a call that carries both an
 *         opaque grep and a Codex spend is denied here too, with the ask to
 *         run Codex in its own call. The check is lib/codex-spend's
 *         isCodexSpend, read raw the way that guard reads it.
 *     The rewrite is logged via the same papercut `logDenial` channel
 *     shape-rewrite uses, guard `grep-cost-guard:opaque-rewrite`, so
 *     transcript pulls count rewrites where they used to count refusals.
 *
 * The repeat detector is a single forward scan. It never compiles or executes
 * the supplied pattern (the dangerous operation this hook exists to prevent),
 * and it caps parsed bounds while still comparing them as BigInts.
 */

'use strict';

const path = require('node:path');
const { deny, setDenyContext } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');
const { executedPieces, NestingTooDeep, MAX_NESTING } = require('../lib/heredoc-scan');
const { logDenial } = require('../PostToolUseFailure/papercut-log.js');
// heavy-job-admission's own classifier, so this hook never rewrites a call
// that hook also rewrites (shape-rewrite defers the same way).
const { analyzeCommand: analyzeHeavyJob } = require('./heavy-job-admission.js');
// codex-quota-guard rewrites a Codex spend to an available model when the
// subscription is explicitly exhausted; this is the classifier it reads.
const { isCodexSpend } = require('../lib/codex-spend');

// Paired 30-character spans are the lowest reviewed unsafe boundary. Keep the
// comparison inclusive so 30x30 is denied while 29x29 remains available.
const COST_THRESHOLD = 900n;
const GREP_FAMILY = new Set([
  'grep',
  'egrep',
  'ugrep',
  'ug',
  'rg',
  'ripgrep',
  'pcregrep',
]);

const SIMPLE_COMMAND_WRAPPERS = new Set(['builtin', 'nohup']);
const SHELL_FAMILY = new Set(['sh', 'bash', 'dash', 'ksh', 'mksh', 'zsh']);
const COMMAND_PREFIX_KEYWORDS = new Set(['!', '{', 'do', 'then', 'else', 'elif', 'if', 'while', 'until']);
const MAX_NESTED_COMMAND_DEPTH = 16;

const WRAPPER_OPTION_SPECS = {
  xargs: {
    shortWithValue: new Set(['a', 'd', 'E', 'I', 'L', 'n', 'P', 's']),
    longWithValue: new Set([
      '--arg-file', '--delimiter', '--eof', '--replace', '--max-lines',
      '--max-args', '--max-procs', '--max-chars',
    ]),
  },
  sudo: {
    shortWithValue: new Set(['C', 'D', 'g', 'h', 'p', 'R', 'r', 'T', 't', 'u']),
    longWithValue: new Set([
      '--close-from', '--chdir', '--group', '--host', '--prompt', '--chroot',
      '--role', '--command-timeout', '--type', '--user',
    ]),
  },
  env: {
    shortWithValue: new Set(['C', 'S', 'u']),
    longWithValue: new Set(['--chdir', '--split-string', '--unset']),
  },
  nice: {
    shortWithValue: new Set(['n']),
    longWithValue: new Set(['--adjustment']),
  },
  time: {
    shortWithValue: new Set(['f', 'o']),
    longWithValue: new Set(['--format', '--output']),
  },
  timeout: {
    shortWithValue: new Set(['k', 's']),
    longWithValue: new Set(['--kill-after', '--signal']),
  },
};

const GREP_SHORT_OPTIONS_WITH_VALUE = new Set(['A', 'B', 'C', 'D', 'd', 'g', 'j', 'm', 'M', 't', 'T']);
const GREP_LONG_OPTIONS_WITH_VALUE = new Set([
  '--after-context', '--before-context', '--context', '--devices', '--directories',
  '--glob', '--iglob', '--threads', '--max-count', '--max-columns', '--max-columns-preview',
  '--max-depth', '--path-separator', '--replace', '--type', '--type-not',
  '--type-add', '--type-clear', '--encoding', '--engine', '--regexp-flavor',
  '--sort', '--sortr',
]);

function basename(token) {
  return path.posix.basename(token.replace(/\\/g, '/'));
}

function isAssignment(token) {
  const eq = token.indexOf('=');
  if (eq <= 0) return false;
  const name = token.slice(0, eq);
  if (!/[A-Za-z_]/.test(name[0])) return false;
  for (let i = 1; i < name.length; i += 1) {
    if (!/[A-Za-z0-9_]/.test(name[i])) return false;
  }
  return true;
}

/**
 * Minimal shell lexer for command shape, not execution. Quotes are removed but
 * their contents remain one token; pipelines and statement boundaries become
 * separators. This is enough to distinguish an invoked grep from prose passed
 * to `printf`, while preserving regex backslashes inside quoted patterns.
 *
 * `tokens.live[i]` is true when token i holds a `$` or backtick that Bash
 * expands. It is decided here, where the quoting is known, because the token
 * text cannot say: a quoted regex `'a\$b'` and an escaped backslash `"a\\$b"`
 * lex to the same characters, and only the second expands `$b`. An unquoted
 * `$'…'` is decoded here too, so its token text is what grep receives.
 */
function shellTokens(command) {
  const tokens = [];
  const live = [];
  // True where the token is a shell operator Bash read unquoted; an
  // escaped or quoted `;`, `&`, `(` or `)` (find's `\;` and `\( \)`) is a
  // word and never ends a statement.
  const ops = [];
  let current = '';
  let currentLive = false;
  let quote = null;
  let tokenStarted = false;

  const emit = (token, isLive, isOp = false) => {
    tokens.push(token);
    live.push(isLive);
    ops.push(isOp);
  };
  const flush = () => {
    if (tokenStarted) emit(current, currentLive);
    current = '';
    currentLive = false;
    tokenStarted = false;
  };
  // Bash removes a backslash-newline before it reads what follows a `$`.
  const afterContinuations = (i) => {
    let j = i;
    while (command[j] === '\\' && command[j + 1] === '\n') j += 2;
    return j;
  };
  const expands = (i) => command[i] === '`'
    || (command[i] === '$' && expansionStart(command[afterContinuations(i + 1)]));

  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") {
      if (ch === "'") quote = null;
      else current += ch === '$' || ch === '`' ? `\\${ch}` : ch;
      continue;
    }
    if (quote === '"') {
      if (ch === '"') {
        quote = null;
      } else if (ch === '\\' && i + 1 < command.length && '"$`\\\n'.includes(command[i + 1])) {
        i += 1;
        if (command[i] !== '\n') current += command[i] === '$' || command[i] === '`' ? `\\${command[i]}` : command[i];
      } else {
        if (expands(i)) currentLive = true;
        current += ch;
      }
      continue;
    }
    if (ch === '$' && command[afterContinuations(i + 1)] === "'") {
      const quoted = ansiCQuoted(command, afterContinuations(i + 1) + 1);
      current += quoted.text;
      tokenStarted = true;
      i = quoted.end;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      tokenStarted = true;
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) {
      i += 1;
      if (command[i] !== '\n') {
        current += command[i] === '$' || command[i] === '`' ? `\\${command[i]}` : command[i];
        tokenStarted = true;
      }
      continue;
    }
    if (/\s/.test(ch)) {
      flush();
      if (ch === '\n') emit('\n', false, true);
      continue;
    }
    if (ch === '<' || ch === '>') {
      flush();
      let redirection = ch;
      if (command[i + 1] === ch) redirection += command[++i];
      if (command[i + 1] === '&') redirection += command[++i];
      emit(redirection, false, true);
      continue;
    }
    if (ch === '&' && command[i + 1] === '>') {
      flush();
      emit('&>', false, true);
      i += 1;
      continue;
    }
    if ('|;&()'.includes(ch)) {
      flush();
      if ((ch === '|' || ch === '&') && command[i + 1] === ch) {
        emit(ch + ch, false, true);
        i += 1;
      } else {
        emit(ch, false, true);
      }
      continue;
    }
    if (expands(i)) currentLive = true;
    current += ch;
    tokenStarted = true;
  }
  flush();
  tokens.live = live;
  tokens.ops = ops;
  return tokens;
}

/** Characters after `$` that make Bash expand it; a `$` before a quote or at the end stays literal. */
function expansionStart(next) {
  return next !== undefined && ('{(@*#?$!-'.includes(next) || /[A-Za-z0-9_]/.test(next));
}

const ANSI_C_SIMPLE_ESCAPES = {
  a: '\x07', b: '\b', e: '\x1b', E: '\x1b', f: '\f', n: '\n', r: '\r', t: '\t', v: '\v',
  '\\': '\\', "'": "'", '"': '"', '?': '?',
};

/**
 * Decode the body of a Bash `$'…'` string from `start` (just past its opening
 * quote) as Bash does before the command runs: `$'a\x7b30\x7d'` reaches grep
 * as `a{30}`. Nothing expands inside, so a decoded `$` or backtick is rendered
 * as `\$` like a single-quoted one. An unknown escape keeps its backslash.
 * Returns the text and the index of the closing quote, or the last index when
 * the quote is unterminated.
 */
function ansiCQuoted(command, start) {
  let text = '';
  const add = (ch) => {
    text += ch === '$' || ch === '`' ? `\\${ch}` : ch;
  };
  const digitsEnd = (from, max, digit) => {
    let j = from;
    while (j < command.length && j - from < max && digit.test(command[j])) j += 1;
    return j;
  };

  for (let i = start; i < command.length; i += 1) {
    const ch = command[i];
    if (ch === "'") return { text, end: i };
    if (ch !== '\\' || i + 1 >= command.length) {
      add(ch);
      continue;
    }
    const escape = command[i + 1];
    if (Object.hasOwn(ANSI_C_SIMPLE_ESCAPES, escape)) {
      add(ANSI_C_SIMPLE_ESCAPES[escape]);
      i += 1;
      continue;
    }
    if (/[0-7]/.test(escape)) {
      const end = digitsEnd(i + 1, 3, /[0-7]/);
      add(String.fromCharCode(parseInt(command.slice(i + 1, end), 8) & 0xff));
      i = end - 1;
      continue;
    }
    const width = { x: 2, u: 4, U: 8 }[escape];
    if (width !== undefined) {
      const end = digitsEnd(i + 2, width, /[0-9A-Fa-f]/);
      const codePoint = parseInt(command.slice(i + 2, end), 16);
      if (end > i + 2 && codePoint <= 0x10ffff) {
        add(String.fromCodePoint(codePoint));
        i = end - 1;
        continue;
      }
    }
    if (escape === 'c' && i + 2 < command.length) {
      add(String.fromCharCode(command.charCodeAt(i + 2) & 0x1f));
      i += 2;
      continue;
    }
    add('\\');
  }
  return { text, end: command.length - 1 };
}

/** Each statement carries its tokens' `live` flags, index for index. */
const STATEMENT_SEPARATORS = new Set(['|', '||', '&&', ';', '&', '\n', '(', ')']);

function splitStatements(tokens) {
  const statements = [];
  let current = [];
  let currentLive = [];
  const close = () => {
    if (current.length > 0) {
      current.live = currentLive;
      statements.push(current);
    }
    current = [];
    currentLive = [];
  };
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    const isOperator = tokens.ops ? tokens.ops[i] === true : true;
    if (isOperator && STATEMENT_SEPARATORS.has(token)) {
      close();
    } else {
      current.push(token);
      currentLive.push(tokens.live?.[i] === true);
    }
  }
  close();
  return statements;
}

function backtickEnd(command, start) {
  for (let i = start; i < command.length; i += 1) {
    if (command[i] === '\\' && i + 1 < command.length) {
      i += 1;
      continue;
    }
    if (command[i] === '`') return i;
  }
  return -1;
}

/** Find a matching command-substitution `)` without evaluating shell text. */
function commandSubstitutionEnd(command, start) {
  let quote = null;
  let plainParens = 0;

  for (let i = start; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") {
      if (ch === "'") quote = null;
      continue;
    }
    if (quote === '"') {
      if (ch === '\\' && i + 1 < command.length) {
        i += 1;
        continue;
      }
      if (ch === '"') {
        quote = null;
        continue;
      }
      if (ch === '$' && command[i + 1] === '(') {
        const nestedEnd = commandSubstitutionEnd(command, i + 2);
        if (nestedEnd < 0) return -1;
        i = nestedEnd;
        continue;
      }
      if (ch === '`') {
        const nestedEnd = backtickEnd(command, i + 1);
        if (nestedEnd < 0) return -1;
        i = nestedEnd;
      }
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) {
      i += 1;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === '`') {
      const nestedEnd = backtickEnd(command, i + 1);
      if (nestedEnd < 0) return -1;
      i = nestedEnd;
      continue;
    }
    if (ch === '$' && command[i + 1] === '(') {
      const nestedEnd = commandSubstitutionEnd(command, i + 2);
      if (nestedEnd < 0) return -1;
      i = nestedEnd;
      continue;
    }
    if (ch === '(') {
      plainParens += 1;
      continue;
    }
    if (ch !== ')') continue;
    if (plainParens === 0) return i;
    plainParens -= 1;
  }
  return -1;
}

/** Extract executable `$()` and backtick bodies, including inside double quotes. */
function embeddedCommandPayloads(command) {
  const payloads = [];
  let quote = null;

  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") {
      if (ch === "'") quote = null;
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) {
      i += 1;
      continue;
    }
    if (ch === '"') {
      quote = quote === '"' ? null : '"';
      continue;
    }
    if (ch === "'" && quote === null) {
      quote = "'";
      continue;
    }
    if (ch === '$' && command[i + 1] === '(') {
      const end = commandSubstitutionEnd(command, i + 2);
      if (end < 0) break;
      payloads.push(command.slice(i + 2, end));
      i = end;
      continue;
    }
    if (ch === '`') {
      const end = backtickEnd(command, i + 1);
      if (end < 0) break;
      payloads.push(command.slice(i + 1, end));
      i = end;
    }
  }
  return payloads;
}

// The text with every unescaped `$( )` and backtick interior taken out
// (`echo $(cat <<EOF\n); grep …` becomes `echo $(); grep …`). Applied to a
// `-c` script that Bash expands before its shell reads it (Pro round 1 on
// #1859, P1): the token keeps an expanding `$(` bare and writes a quoted or
// escaped one as `\$(`, so a bare one here ran in the outer shell, and its
// interior was already queued from the piece the script was lexed out of by
// embeddedCommandPayloads. Left in, it would be scanned again by
// executedPieces, which reads the kept `<<EOF` opener of a body the first
// scan removed as an unterminated body swallowing the rest of the script.
function withoutEmbeddedCommands(command) {
  let out = '';
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (ch === '\\' && i + 1 < command.length) {
      out += ch + command[i + 1];
      i += 1;
      continue;
    }
    if (ch === '$' && command[i + 1] === '(') {
      const end = commandSubstitutionEnd(command, i + 2);
      if (end < 0) return out + command.slice(i);
      out += '$()';
      i = end;
      continue;
    }
    if (ch === '`') {
      const end = backtickEnd(command, i + 1);
      if (end < 0) return out + command.slice(i);
      out += '``';
      i = end;
      continue;
    }
    out += ch;
  }
  return out;
}

function skipWrapperOptions(tokens, start, end, spec) {
  let i = start;
  while (i < end) {
    const token = tokens[i];
    if (token === '--') return i + 1;
    if (!token.startsWith('-') || token === '-') return i;
    if (token.startsWith('--')) {
      const equals = token.indexOf('=');
      const name = equals >= 0 ? token.slice(0, equals) : token;
      i += 1;
      if (equals < 0 && spec.longWithValue.has(name) && i < end) i += 1;
      continue;
    }

    let consumesNext = false;
    for (let j = 1; j < token.length; j += 1) {
      if (!spec.shortWithValue.has(token[j])) continue;
      consumesNext = j === token.length - 1;
      break;
    }
    i += 1;
    if (consumesNext && i < end) i += 1;
  }
  return i;
}

/** Pull only regex operands from a grep invocation; filenames are not scanned. */
function grepPatterns(tokens, commandIndex, end, engineOverride = null) {
  const engine = engineOverride === null ? basename(tokens[commandIndex]) : basename(engineOverride);
  const explicitPatterns = [];
  const explicitLive = [];
  const positional = [];
  const positionalLive = [];
  const isLive = (index) => tokens.live?.[index] === true;
  const addExplicit = (pattern, index) => {
    explicitPatterns.push(pattern);
    explicitLive.push(isLive(index));
  };
  let fixed = false;
  let regexMode = false;
  let patternFile = false;
  let options = true;
  let syntax = ['grep'].includes(engine) ? 'bre'
    : ['egrep', 'rg', 'ripgrep', 'pcregrep'].includes(engine) ? 'ere'
      : 'both';

  for (let i = commandIndex + 1; i < end; i += 1) {
    const token = tokens[i];
    if (options && token === '--') {
      options = false;
      continue;
    }

    if (options && token.startsWith('--')) {
      const equals = token.indexOf('=');
      const optionName = equals >= 0 ? token.slice(0, equals) : token;
      const attached = equals >= 0 ? token.slice(equals + 1) : null;

      if (optionName === '--fixed-strings') fixed = true;
      if (optionName === '--extended-regexp' || optionName === '--perl-regexp' || optionName === '--pcre2') {
        regexMode = true;
        syntax = 'ere';
      }
      if (optionName === '--basic-regexp') {
        regexMode = true;
        syntax = 'bre';
      }
      if (optionName === '--engine' || optionName === '--regexp-flavor' || optionName === '--auto-hybrid-regex') {
        regexMode = true;
      }

      if (optionName === '--regexp') {
        if (attached !== null) addExplicit(attached, i);
        else if (i + 1 < end) addExplicit(tokens[++i], i);
        continue;
      }
      if (optionName === '--file') {
        patternFile = true;
        if (attached === null && i + 1 < end) i += 1;
        continue;
      }
      if (attached === null && GREP_LONG_OPTIONS_WITH_VALUE.has(optionName) && i + 1 < end) {
        i += 1;
      }
      continue;
    }

    if (options && token.startsWith('-') && token !== '-') {
      for (let j = 1; j < token.length; j += 1) {
        const flag = token[j];
        if (flag === 'F') fixed = true;
        if (flag === 'E' || flag === 'P') {
          regexMode = true;
          syntax = 'ere';
        }
        if (flag === 'G') {
          regexMode = true;
          syntax = 'bre';
        }

        if (flag === 'e') {
          const attached = token.slice(j + 1);
          if (attached !== '') addExplicit(attached, i);
          else if (i + 1 < end) addExplicit(tokens[++i], i);
          break;
        }
        if (flag === 'f') {
          patternFile = true;
          if (j === token.length - 1 && i + 1 < end) i += 1;
          break;
        }
        if (GREP_SHORT_OPTIONS_WITH_VALUE.has(flag)) {
          if (j === token.length - 1 && i + 1 < end) i += 1;
          break;
        }
      }
      continue;
    }
    positional.push(token);
    positionalLive.push(isLive(i));
  }

  const patterns = explicitPatterns.length > 0 ? explicitPatterns : positional.slice(0, 1);

  return {
    engine,
    patterns,
    patternFile,
    syntax,
    inspect: !fixed || regexMode,
    // A `$` or backtick Bash expands hides the real pattern until it runs.
    opaque: explicitPatterns.length > 0 ? explicitLive.some(Boolean) : positionalLive[0] === true,
  };
}

function inspectGrepInvocation(tokens, commandIndex, end, engineOverride = null) {
  const parsed = grepPatterns(tokens, commandIndex, end, engineOverride);
  if (!parsed.inspect) return null;
  if (parsed.patternFile) return { kind: 'pattern-file', engine: parsed.engine };
  // The literal text of an operand is scanned even when Bash will expand part
  // of it: `grep "$x.{0,60}y.{0,60}" f` is an expensive pair whatever `$x`
  // becomes, so it stays a denial rather than falling to the bounded rewrite.
  for (const pattern of parsed.patterns) {
    const hit = expensiveSpanPair(pattern, parsed.syntax);
    if (hit) return { ...hit, kind: 'repeat-pair', engine: parsed.engine };
  }
  if (parsed.opaque) return { kind: 'opaque-pattern', engine: parsed.engine };
  return null;
}

function execCommandSpec(tokens, start, end) {
  let i = start;
  let persona = null;
  while (i < end) {
    const token = tokens[i];
    if (token === '--') return { next: i + 1, persona };
    if (!token.startsWith('-') || token === '-') return { next: i, persona };
    if (token === '-a') {
      if (i + 1 < end) persona = tokens[i + 1];
      i += 2;
      continue;
    }
    if (token.startsWith('-a') && token.length > 2) {
      persona = token.slice(2);
      i += 1;
      continue;
    }
    i += 1;
  }
  return { next: i, persona };
}

function commandBuiltinNext(tokens, start, end) {
  let i = start;
  while (i < end) {
    const token = tokens[i];
    if (token === '--') return i + 1;
    if (!token.startsWith('-') || token === '-') return i;
    if (token.slice(1).includes('v') || token.slice(1).includes('V')) return -1;
    i += 1;
  }
  return i;
}

const REDIRECTIONS = new Set(['<', '>', '<<', '>>', '<&', '>&', '&>']);

function skipCommandPreamble(tokens, start, end) {
  let i = start;
  while (i < end) {
    if (isAssignment(tokens[i]) || COMMAND_PREFIX_KEYWORDS.has(tokens[i])) {
      i += 1;
      continue;
    }
    if (/^[0-9]+$/.test(tokens[i]) && REDIRECTIONS.has(tokens[i + 1])) i += 1;
    if (REDIRECTIONS.has(tokens[i])) {
      i += Math.min(2, end - i);
      continue;
    }
    break;
  }
  return i;
}

// The script a `-c` word hands its shell, as that shell reads it: a live
// word (an unquoted or double-quoted `$( )` or backtick in it) is expanded by
// the outer shell first, so those substitutions are taken out; the token of
// a single-quoted or `$'…'` script carries none that Bash expands and is
// returned as it is.
function shellCommandPayload(tokens, start, end) {
  const script = (index, text) => (tokens.live?.[index] === true ? withoutEmbeddedCommands(text) : text);
  for (let i = start; i < end; i += 1) {
    const token = tokens[i];
    if (token === '--') return null;
    if (['-o', '+o', '-O', '+O', '--rcfile', '--init-file'].includes(token)) {
      if (i + 1 >= end) return null;
      i += 1;
      continue;
    }
    if (!token.startsWith('-') || token === '-') return null;
    if (token === '--command') return i + 1 < end ? script(i + 1, tokens[i + 1]) : null;
    if (token.startsWith('--command=')) return script(i, token.slice('--command='.length));

    for (let j = 1; j < token.length && token[j] !== '-'; j += 1) {
      if (token[j] !== 'c') continue;
      const attached = token.slice(j + 1);
      return attached !== '' ? script(i, attached) : i + 1 < end ? script(i + 1, tokens[i + 1]) : null;
    }
  }
  return null;
}

function inspectFindExecutions(tokens, start, end, depth, payloads) {
  // Every -exec/-execdir is inspected and a denial outranks the bound, so
  // `find . -exec grep "$p" {} + -exec grep -E '.{0,60}x.{0,60}' {} +` denies
  // in either order (ce-code-review on #1738, P2). The `;` matched here is
  // find's own escaped terminator: an unescaped one already split the
  // statement.
  let opaque = null;
  for (let i = start; i < end; i += 1) {
    if (tokens[i] !== '-exec' && tokens[i] !== '-execdir') continue;
    const nestedStart = i + 1;
    let nestedEnd = end;
    for (let j = nestedStart; j < end; j += 1) {
      if (tokens[j] === ';' || tokens[j] === '+') {
        nestedEnd = j;
        break;
      }
    }
    const hit = inspectCommandRange(tokens, nestedStart, nestedEnd, depth + 1, payloads);
    if (hit && hit.kind !== 'opaque-pattern') return hit;
    if (hit && opaque === null) opaque = hit;
    i = nestedEnd;
  }
  return opaque;
}

function inspectCommandRange(tokens, start, end, depth, payloads) {
  if (depth > MAX_NESTED_COMMAND_DEPTH) return null;
  let i = skipCommandPreamble(tokens, start, end);

  while (i < end) {
    i = skipCommandPreamble(tokens, i, end);
    if (i >= end) return null;
    const name = basename(tokens[i]);

    if (GREP_FAMILY.has(name)) {
      return inspectGrepInvocation(tokens, i, end);
    }

    if (SIMPLE_COMMAND_WRAPPERS.has(name)) {
      i = skipWrapperOptions(tokens, i + 1, end, { shortWithValue: new Set(), longWithValue: new Set() });
      i = skipCommandPreamble(tokens, i, end);
      continue;
    }
    if (name === 'command') {
      i = commandBuiltinNext(tokens, i + 1, end);
      if (i < 0) return null;
      i = skipCommandPreamble(tokens, i, end);
      continue;
    }
    if (name === 'exec') {
      const spec = execCommandSpec(tokens, i + 1, end);
      // Claude's upstream launcher uses `exec -a ugrep <claude-binary> ...`:
      // the executable is a multicall binary and argv[0] selects its grep
      // persona. Treat a grep-family persona as the effective command while
      // starting argument inspection after the real executable path.
      if (spec.persona !== null && GREP_FAMILY.has(basename(spec.persona)) && spec.next < end) {
        return inspectGrepInvocation(tokens, spec.next, end, spec.persona);
      }
      i = spec.next;
      i = skipCommandPreamble(tokens, i, end);
      continue;
    }
    if (name === 'xargs' || name === 'sudo' || name === 'env' || name === 'nice' || name === 'time') {
      i = skipWrapperOptions(tokens, i + 1, end, WRAPPER_OPTION_SPECS[name]);
      i = skipCommandPreamble(tokens, i, end);
      continue;
    }
    if (name === 'timeout') {
      i = skipWrapperOptions(tokens, i + 1, end, WRAPPER_OPTION_SPECS.timeout);
      if (i < end) i += 1; // duration
      i = skipCommandPreamble(tokens, i, end);
      continue;
    }
    if (SHELL_FAMILY.has(name)) {
      const payload = shellCommandPayload(tokens, i + 1, end);
      if (payload !== null) payloads.push({ command: payload, depth: depth + 1 });
      return null;
    }
    if (name === 'find') return inspectFindExecutions(tokens, i + 1, end, depth, payloads);
    return null;
  }
  return null;
}

function cappedBound(text, start, end) {
  let value = 0n;
  for (let i = start; i < end; i += 1) {
    value = value * 10n + BigInt(text.charCodeAt(i) - 48);
    if (value >= COST_THRESHOLD) return COST_THRESHOLD;
  }
  return value;
}

/** Parse exact, closed, or open ERE/BRE repeats after a one-character atom. */
function boundedRepeatAt(pattern, start, syntax) {
  let i = start;
  let bre = false;
  if (syntax !== 'ere' && pattern[i] === '\\' && pattern[i + 1] === '{') {
    bre = true;
    i += 2;
  } else if (syntax !== 'bre' && pattern[i] === '{') {
    i += 1;
  } else {
    return null;
  }

  const minStart = i;
  while (i < pattern.length && pattern.charCodeAt(i) >= 48 && pattern.charCodeAt(i) <= 57) i += 1;
  if (i === minStart) return null;

  let upper = cappedBound(pattern, minStart, i);
  if (pattern[i] === ',') {
    i += 1;
    const maxStart = i;
    while (i < pattern.length && pattern.charCodeAt(i) >= 48 && pattern.charCodeAt(i) <= 57) i += 1;
    upper = i === maxStart ? COST_THRESHOLD : cappedBound(pattern, maxStart, i);
  }

  const end = bre
    ? pattern[i] === '\\' && pattern[i + 1] === '}' ? i + 2 : -1
    : pattern[i] === '}' ? i + 1 : -1;
  if (end < 0) return null;
  return { end, upper };
}

/** Return the end of a complete regex bracket expression, or -1 if malformed. */
function characterClassEnd(pattern, index) {
  if (pattern[index] !== '[') return -1;
  let i = index + 1;
  if (pattern[i] === '^') i += 1;
  // `]` is literal when it is the first class member (after optional `^`).
  if (pattern[i] === ']') i += 1;

  while (i < pattern.length) {
    if (pattern[i] === '\\') {
      if (i + 1 >= pattern.length) return -1;
      i += 2;
      continue;
    }
    // POSIX bracket constructs contain their own closing `]`, e.g.
    // `[[:space:]]`, `[[.ch.]]`, and `[[=a=]]`. Skip the inner construct so
    // its terminator is not mistaken for the outer class terminator.
    if (pattern[i] === '[' && [':', '.', '='].includes(pattern[i + 1])) {
      const marker = pattern[i + 1];
      let inner = i + 2;
      while (inner + 1 < pattern.length) {
        if (pattern[inner] === marker && pattern[inner + 1] === ']') break;
        inner += 1;
      }
      if (inner + 1 >= pattern.length) return -1;
      i = inner + 2;
      continue;
    }
    if (pattern[i] === ']') return i + 1;
    i += 1;
  }
  return -1;
}

function escapedSingleCharacterEnd(pattern, index, syntax) {
  if (pattern[index] !== '\\' || index + 1 >= pattern.length) return -1;
  const next = pattern[index + 1];
  if ('sSwWdDtnrfv'.includes(next)) return index + 2;
  const code = next.charCodeAt(0);
  const alphaNumeric = (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || next === '_';
  if (alphaNumeric) return -1;
  if (syntax === 'bre' && '+?|(){}'.includes(next)) return -1;
  return index + 2;
}

function boundedAtomEnd(pattern, index, syntax) {
  const ch = pattern[index];
  if (ch === '.') return index + 1;
  if (ch === '[') return characterClassEnd(pattern, index);
  if (ch === '\\') return escapedSingleCharacterEnd(pattern, index, syntax);

  const operators = syntax === 'bre' ? '^$*' : '^$|(){}*+?';
  if (operators.includes(ch)) return -1;
  return index + 1;
}

/** Linear scan: maximum prior bound is sufficient to detect any costly pair. */
function expensiveSpanPair(pattern, syntax = 'both') {
  let largestPrior = null;
  let i = 0;
  while (i < pattern.length) {
    const atomEnd = boundedAtomEnd(pattern, i, syntax);
    if (atomEnd < 0) {
      // An unterminated class consumes the rest of an invalid pattern. Stopping
      // here avoids retrying the same suffix from every nested `[`.
      if (pattern[i] === '[') return null;
      i += pattern[i] === '\\' && i + 1 < pattern.length ? 2 : 1;
      continue;
    }
    const repeat = boundedRepeatAt(pattern, atomEnd, syntax);
    if (!repeat) {
      i = atomEnd;
      continue;
    }
    if (largestPrior !== null) {
      const product = largestPrior * repeat.upper;
      if (product >= COST_THRESHOLD) return { product, threshold: COST_THRESHOLD };
    }
    if (largestPrior === null || repeat.upper > largestPrior) largestPrior = repeat.upper;
    i = repeat.end;
  }
  return null;
}

// Every dangerous grep invocation in the command, in scan order (statements
// of the outer command first, then nested payloads).
function findDangerousInvocations(command) {
  const pending = [{ command, depth: 0 }];
  const hits = [];
  let cursor = 0;
  // Nested `sh -c` payloads are substrings already scanned by an outer lexer.
  // A fixed total budget keeps even adversarial nesting O(command.length).
  let remainingCharacters = command.length * (MAX_NESTED_COMMAND_DEPTH + 1) + 1024;

  while (cursor < pending.length) {
    const item = pending[cursor++];
    if (item.depth > MAX_NESTED_COMMAND_DEPTH) continue;
    remainingCharacters -= item.command.length;
    if (remainingCharacters < 0) break;
    // Fresh text (the call itself, a `sh -c` payload) is lexed as the pieces
    // of executedPieces (#1853): here-document bodies and comments out, each
    // body that runs a piece of its own, every piece lexed alone. The pieces
    // are walked here rather than queued, so the budget charges the item
    // once. A substitution's payload was part of a scanned piece and is not
    // scanned again: its kept `<<EOF` opener would read as unterminated. A
    // `sh -c` payload's own heredocs sat inside a quoted word the outer scan
    // did not read, so it is scanned, with the substitutions the outer shell
    // expands taken out of it first (shellCommandPayload), since those were
    // part of the scanned piece and queued from it below.
    const texts = item.scanned ? [item.command] : executedPieces(item.command).map((piece) => piece.text);
    for (const text of texts) {
      for (const payload of embeddedCommandPayloads(text)) {
        pending.push({ command: payload, depth: item.depth + 1, scanned: true });
      }
      for (const statement of splitStatements(shellTokens(text))) {
        const hit = inspectCommandRange(statement, 0, statement.length, item.depth, pending);
        if (hit) hits.push(hit);
      }
    }
  }
  return hits;
}

// The hit that decides the call. A denial outranks the bounded rewrite: an
// opaque operand earlier in the command must not mask a paired-span or
// pattern-file grep later in it, which was denied before the rewrite existed.
function findDangerousInvocation(command) {
  const hits = findDangerousInvocations(command);
  return hits.find((hit) => hit.kind !== 'opaque-pattern') || hits[0] || null;
}

const SAFE_ALTERNATIVES =
  'Use `rg -F` with literal anchors. For HTML/PDF, extract a bounded section, ' +
  'then search literal anchors in stages. Use `ast-grep` only for structural ' +
  'source-code queries. Do not retry by swapping grep engines.';

// The CPU bound is the time bound: on Claude Code 2.1.x a foreground call
// that reaches the Bash tool's timeout is moved to the background, not
// stopped (tools-reference, "Foreground commands that move to the
// background"), so nothing outside this call ends a runaway grep. 600 CPU
// seconds, not 60: the whole call runs under the bound, not only the grep,
// so a tight default would kill the unrelated tail of a compound command
// (`grep "$x" f && pnpm test`). `ulimit -t` is per process, so a loop of
// greps gets 600 s each, as does a grep backgrounded with `&`.
const REWRITE_CPU_DEFAULT_S = 600;
const REWRITE_VMEM_DEFAULT_KB = 8 * 1024 * 1024; // 8 GiB

// The run of unquoted `NAME=value` words at the start of the command, before
// its first command word: the assignments Bash makes first whatever follows.
// Words are separated by blanks, a newline, `;` or `&&`, and the run ends at
// the first word that is not a plain assignment (a quoted value, an
// expansion, a command name). A later assignment of the same name wins, as
// in Bash. Nothing after the run is read: a `NAME=0` in a comment, a quoted
// string, an argument or an `if` branch is not an assignment made before
// the grep and must not lift a bound (Pro round 1 on #1738, P1). A statement
// is read only once its end is known: one that `|`, a lone `&`, a
// redirection, a quote or an expansion follows is not honoured, since Bash
// would make its assignments in a pipeline or background subshell, or not
// before the grep at all (`A=0 B=0 | grep …` lifts nothing; `A=0; B=0 |
// grep …` lifts A). The value class is Bash's word: anything but a blank, a
// newline or an operator, so `NAME=0#x` and `NAME=0\r` carry the value Bash
// would assign and fail the digits check.
const LEADING_ASSIGNMENT = /([A-Za-z_][A-Za-z0-9_]*)=([^ \t\n;&|()<>'"`$\\]*)/y;
const ASSIGNMENT_STOP = /[|&()<>'"`$\\]/;

function leadingAssignments(command) {
  const assignments = new Map();
  // Assignment words of the statement being read, honoured once it ends.
  let statement = [];
  const commit = () => {
    for (const [name, value] of statement) assignments.set(name, value);
    statement = [];
  };
  let i = 0;
  for (;;) {
    while (command[i] === ' ' || command[i] === '\t' || command[i] === '\n') i += 1;
    LEADING_ASSIGNMENT.lastIndex = i;
    const word = LEADING_ASSIGNMENT.exec(command);
    if (word === null) {
      // A command name or a comment: the statement's assignments precede it.
      commit();
      break;
    }
    statement.push([word[1], word[2]]);
    let j = LEADING_ASSIGNMENT.lastIndex;
    while (command[j] === ' ' || command[j] === '\t') j += 1;
    const next = command[j];
    if (next === undefined) {
      commit();
      break;
    }
    if (next === '&' && command[j + 1] === '&') {
      commit();
      j += 2;
    } else if (next === ';' || next === '\n') {
      commit();
      j += 1;
    } else if (ASSIGNMENT_STOP.test(next)) {
      break;
    }
    i = j;
  }
  return assignments;
}

// `NAME=<digits>` as a leading assignment of the command. Anything else
// keeps the default.
function commandOverride(command, name, fallback) {
  const value = leadingAssignments(command).get(name);
  return value !== undefined && /^\d{1,9}$/.test(value) ? Number(value) : fallback;
}

// The hook's process environment is the Bash tool's, so a bound exported
// there outranks one written into the command.
function envOverride(name, fallback) {
  const value = process.env[name];
  return typeof value === 'string' && /^\d{1,9}$/.test(value) ? Number(value) : fallback;
}

/**
 * The inline prefix: per-process limits set in the Bash tool's own shell and
 * inherited by every child, with the original call following unchanged as
 * its own subcommands. 0 lifts a bound; both lifted means no prefix.
 *
 * One `ulimit` statement per limit, the CPU bound first: Bash's ulimit
 * stops at the first option it cannot set, so one `ulimit -v 8388608 -t 600`
 * under a hard -v limit below 8 GiB left the CPU time unlimited (Pro round 1
 * on #1738, P2). A statement that fails is a limit the shell may not raise,
 * which means a stricter one is already in place (see the header), so its
 * failure is neither retried nor a reason to refuse the call.
 */
function boundedPrefix(command) {
  const cpuS = envOverride('GREP_COST_GUARD_TIMEOUT_S',
    commandOverride(command, 'GREP_COST_GUARD_TIMEOUT_S', REWRITE_CPU_DEFAULT_S));
  const vmemKb = envOverride('GREP_COST_GUARD_VMEM_KB',
    commandOverride(command, 'GREP_COST_GUARD_VMEM_KB', REWRITE_VMEM_DEFAULT_KB));
  const statements = [];
  if (cpuS !== 0) statements.push(`ulimit -t ${cpuS} 2>/dev/null; `);
  if (vmemKb !== 0) statements.push(`ulimit -v ${vmemKb} 2>/dev/null; `);
  return { prefix: statements.join(''), cpuS, vmemKb };
}

/**
 * Return the hook output JSON that runs the call behind the prefix, or null
 * when both bounds were lifted in the command (the caller passes the call
 * through unchanged). Either way the call is logged as a rewrite.
 */
function boundedRewrite(input, command, engine) {
  const ti = input.tool_input;
  const { prefix, cpuS, vmemKb } = boundedPrefix(command);
  const bounds = [
    vmemKb === 0 ? 'no ulimit -v (lifted)' : `ulimit -v ${vmemKb} KiB`,
    cpuS === 0 ? 'no ulimit -t (lifted)' : `ulimit -t ${cpuS} CPU s`,
  ].join(' and ');
  const receipt = `[grep-cost-guard] opaque regex operand from ${engine}: the call runs under ` +
    `${bounds} instead of being refused; no action needed unless it is killed ` +
    '(CPU time limit exceeded) or fails to allocate: then write ' +
    'GREP_COST_GUARD_TIMEOUT_S=<CPU seconds> or GREP_COST_GUARD_VMEM_KB=<KiB> ' +
    '(0 lifts) as a leading assignment at the start of the command; ' +
    'signature: guard_rewritten:grep-cost-guard:opaque-rewrite';
  try {
    logDenial({
      guard: 'grep-cost-guard:opaque-rewrite',
      tool: 'Bash',
      command,
      reason: receipt,
      sessionId: input.session_id,
      agentId: input.agent_id,
      cwd: input.cwd,
    });
  } catch { /* counting is optional; the bound is not */ }
  if (!prefix) return null;
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecisionReason: receipt,
      updatedInput: { ...ti, command: `${prefix}${command}` },
    },
  });
}

function heavyJobInSameCall(command) {
  try {
    return Boolean(analyzeHeavyJob(command).heavy);
  } catch {
    return false;
  }
}

function codexSpendInSameCall(command) {
  try {
    return Boolean(isCodexSpend(command));
  } catch {
    return false;
  }
}

function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    if (input.tool_name !== 'Bash') return rawInput;
    const command = input.tool_input?.command;
    if (typeof command !== 'string') return rawInput;

    setDenyContext({
      guard: 'grep-cost-guard',
      cwd: input.cwd,
      sessionId: input.session_id,
      agentId: input.agent_id,
      tool: input.tool_name,
      command,
    });

    const hit = findDangerousInvocation(command);
    if (!hit) return rawInput;
    if (hit.kind === 'pattern-file') {
      return deny(
        `Blocked: ${hit.engine} uses a regex pattern file (-f/--file), which ` +
          'this hook cannot inspect without compiling or executing supplied regex. ' +
          'Use a fixed-string-only invocation when the file contains literals. ' +
          SAFE_ALTERNATIVES
      );
    }
    if (hit.kind === 'opaque-pattern') {
      if (heavyJobInSameCall(command)) {
        return deny(
          `Blocked: ${hit.engine} uses an opaque expanded regex operand that this ` +
            'hook would run under a bound, but the same call carries a heavy build ' +
            'or typecheck that heavy-job-admission rewrites, and only one rewrite ' +
            'survives a PreToolUse round. Run the heavy job in its own call. ' +
            SAFE_ALTERNATIVES
        );
      }
      if (codexSpendInSameCall(command)) {
        return deny(
          `Blocked: ${hit.engine} uses an opaque expanded regex operand that this ` +
            'hook would run under a bound, but the same call spends Codex, which ' +
            'codex-quota-guard rewrites to an available model when the subscription ' +
            'is exhausted, and only one rewrite survives a PreToolUse round. Run ' +
            'the Codex command in its own call. ' +
            SAFE_ALTERNATIVES
        );
      }
      // null: both bounds lifted in the command, the agent's explicit choice.
      const rewritten = boundedRewrite(input, command, hit.engine);
      return rewritten === null ? rawInput : rewritten;
    }
    return deny(
      `Blocked: ${hit.engine} regex contains paired bounded character spans ` +
        `whose upper-bound product is ${hit.product} (limit ${hit.threshold}). ` +
        'This command shape can make Claude Code\'s embedded grep shim consume ' +
        'memory without bound. ' + SAFE_ALTERNATIVES
    );
  } catch (err) {
    // Padding a command with nesting must not hide a grep from this guard (#1853).
    if (err instanceof NestingTooDeep) {
      return deny(
        `Blocked: this command's quotes and substitutions nest more than ${MAX_NESTING} ` +
          'levels deep, too deep for this hook to check it for a grep or rg regex. ' +
          'Assign inner substitutions to variables first, then retry. ' + SAFE_ALTERNATIVES
      );
    }
    // Malformed input is not this guard's decision to make.
  }
  return rawInput;
}

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

module.exports = {
  run,
  shellTokens,
  expensiveSpanPair,
  findDangerousInvocation,
  findDangerousInvocations,
  leadingAssignments,
  commandOverride,
  boundedPrefix,
};
