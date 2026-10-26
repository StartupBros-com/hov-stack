#!/usr/bin/env node
/**
 * PreToolUse Hook: WhatsApp Effect Guard
 *
 * `wacli` is a linked WhatsApp device with the authority to send messages and
 * mutate chats, groups, profile state, and the linked-device session. Claude
 * Code commonly runs with bypassPermissions on this host, so settings allow/
 * ask rules are not the right boundary. This hook forces the full permission
 * pipeline for literal `wacli` executable names that are not provably local/read-only.
 * Renamed binaries, positional/array argv0 synthesis, and code-runtime laundering remain outside this guardrail.
 * Frictionless calls also attest the direct live link, versioned target, and pin.
 * That check is not bound to Bash's later execve; same-user replacement races are accepted.
 *
 * Passes without prompting:
 *   - canonical-store, JSON, local reads with explicit read-only mode;
 *   - list/search reads only with a concrete `--limit` of at most 200;
 *   - message context only with its default or 0–50 items per side;
 *   - help/version, canonical `auth status`, and offline `doctor`.
 *
 * Literal writes ask; otherwise-unsafe calls with shell-expanded values deny
 * because the permission dialog cannot show their resolved effect. This is intentionally
 * fail-safe on ambiguity: the agent can make a read frictionless by spelling the
 * documented read-only form, while one false prompt costs less than one send.
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { allow, ask, deny, setDenyContext } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

const TRUTHY = new Set(['1', 'true', 'yes', 'on']);
// Paths follow the home directory of the account running the hook, never a
// host literal. The hook's own environment is set by settings.json, not by
// the Bash command under review, so an absolute WACLI_STORE_DIR there names
// the canonical store; a relative or `~` value is not trusted and the
// default under $HOME stands.
const HOME_DIR = os.homedir();
const DEFAULT_STORE = path.join(HOME_DIR, '.local', 'state', 'wacli');
const CANONICAL_STORE = path.isAbsolute(process.env.WACLI_STORE_DIR || '')
  ? process.env.WACLI_STORE_DIR
  : DEFAULT_STORE;
const PRODUCTION_LIVE = path.join(HOME_DIR, '.local', 'bin', 'wacli');
const PRODUCTION_TARGET = path.join(HOME_DIR, '.local', 'lib', 'wacli', 'v0.17.1', 'wacli');
const REVIEWED_BINARY_SHA256 = 'c71d7cb1395b228ac82d063a1b7d315e379d660f41654d08aacf9200bdb95527';
const EXECUTABLE_CONFIG = executableConfig();
const CANONICAL_LIVE = EXECUTABLE_CONFIG.live;
const MAX_AUTO_READ_LIMIT = 200;
const MAX_CONTEXT_SIDE = 50;
const GLOBAL_VALUE_FLAGS = new Set([
  '--store',
  '--account',
  '--timeout',
  '--lock-wait',
]);
const GLOBAL_BOOLEAN_FLAGS = new Set([
  '--json',
  '--events',
  '--full',
  '--read-only',
]);
const EXECUTION_ENV_VARS = new Set(['PATH', 'BASH_ENV', 'ENV', 'ZDOTDIR']);
const CLI_VALUE_FLAGS = new Set([
  ...GLOBAL_VALUE_FLAGS,
  '--after',
  '--before',
  '--chat',
  '--from',
  '--id',
  '--limit',
  '--pick',
  '--query',
  '--sender',
  '--type',
]);
const LITERAL_DATA_COMMANDS = new Set(['echo', 'printf', 'rg', 'grep', 'egrep', 'fgrep', 'cat']);
const BOUNDED_READ_PATHS = new Set([
  'calls list',
  'chats list',
  'contacts search',
  'groups list',
  'messages list',
  'messages search',
  'polls list',
]);
const POINT_READ_PATHS = new Set([
  'messages show',
  'store stats',
]);
// Inside $'...' these two escapes decide where the quote ends; the rest of
// bash's ANSI-C escapes are left undecoded (see #1626).
const ANSI_C_QUOTE_ESCAPES = new Set(["'", '\\']);

function executableConfig() {
  if (process.env.WACLI_GUARD_TEST_MODE !== '1') {
    return {
      valid: true,
      live: PRODUCTION_LIVE,
      target: PRODUCTION_TARGET,
      sha256: REVIEWED_BINARY_SHA256,
    };
  }

  try {
    const root = fs.realpathSync(process.env.WACLI_GUARD_TEST_ROOT || '');
    const sha256 = (process.env.WACLI_GUARD_TEST_SHA256 || '').toLowerCase();
    if (!root.startsWith('/tmp/') || !/^[0-9a-f]{64}$/.test(sha256)) {
      return { valid: false, live: '', target: '', sha256: '' };
    }
    return {
      valid: true,
      live: path.join(root, 'bin', 'wacli'),
      target: path.join(root, 'lib', 'wacli', 'v0.17.1', 'wacli'),
      sha256,
    };
  } catch {
    return { valid: false, live: '', target: '', sha256: '' };
  }
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function canonicalExecutableVerified() {
  const { valid, live, target, sha256 } = EXECUTABLE_CONFIG;
  if (!valid) return false;
  try {
    const liveStat = fs.lstatSync(live);
    const targetStat = fs.lstatSync(target);
    if (!liveStat.isSymbolicLink() || !targetStat.isFile()) return false;
    if (fs.readlinkSync(live) !== target) return false;
    if (fs.realpathSync(live) !== target) return false;
    if ((targetStat.mode & 0o111) === 0) return false;
    return sha256File(target) === sha256;
  } catch {
    return false;
  }
}

function firstPathExecutable(name) {
  for (const directory of (process.env.PATH || '').split(path.delimiter)) {
    const candidate = path.resolve(directory || process.cwd(), name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // Continue to the next PATH entry.
    }
  }
  return null;
}

function reviewedExecutable(shape) {
  if (shape.privileged) return false;
  if (shape.executable === CANONICAL_LIVE) return canonicalExecutableVerified();
  if (shape.executable !== 'wacli' || !shape.trustedLookup) return false;
  return firstPathExecutable('wacli') === CANONICAL_LIVE && canonicalExecutableVerified();
}

/** A deliberately small shell lexer: enough to find command boundaries and
 * preserve quoted `sh -c` payloads without treating quoted prose as commands. */
function lex(script) {
  const tokens = [];
  let value = '';
  let quote = null;
  let quoted = false;
  let singleQuoted = false;
  let doubleQuoted = false;
  let hadUnquoted = false;
  let shellExpanded = false;

  const push = () => {
    if (value !== '' || quoted) {
      tokens.push({
        type: 'word',
        value,
        quoted,
        singleOnly: singleQuoted && !doubleQuoted && !hadUnquoted,
        shellExpanded,
      });
    }
    value = '';
    quoted = false;
    singleQuoted = false;
    doubleQuoted = false;
    hadUnquoted = false;
    shellExpanded = false;
  };

  for (let i = 0; i < script.length; i += 1) {
    const char = script[i];
    if (quote === "'") {
      if (char === "'") quote = null;
      else value += char;
      continue;
    }
    if (quote === "$'") {
      // ANSI-C quoting: `\'` and `\\` are escapes, so only an unescaped `'`
      // ends the word. Every other escape stays raw (decoding `\x64`-style
      // escapes that hide a CLI name is #1626).
      if (char === "'") {
        quote = null;
      } else if (char === '\\' && ANSI_C_QUOTE_ESCAPES.has(script[i + 1])) {
        value += script[i + 1];
        i += 1;
      } else {
        value += char;
      }
      continue;
    }
    if (quote === '"') {
      if (char === '"') {
        quote = null;
      } else if (char === '\\' && i + 1 < script.length) {
        value += script[i + 1];
        i += 1;
      } else {
        value += char;
      }
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      quoted = true;
      if (char === "'") singleQuoted = true;
      else doubleQuoted = true;
      continue;
    }
    if (char === '$' && script[i + 1] === "'") {
      // Keep the `$` as the ANSI-C marker (`$'wacli'` -> `$wacli`) that
      // valueContainsWacliToken and hasRawShellExpansion already key on.
      value += char;
      hadUnquoted = true;
      quote = "$'";
      quoted = true;
      singleQuoted = true;
      i += 1;
      continue;
    }
    if (char === '\\' && i + 1 < script.length) {
      if (script[i + 1] !== '\n') value += script[i + 1];
      i += 1;
      continue;
    }
    // Redirections are shell grammar even when glued to argv0, an argument,
    // or their target (`wacli>file`, `2>file`, `<<<word`). Keep them as word
    // tokens so commandShape can skip them without turning a pipeline boundary
    // into a new command segment. Quoted < and > remain ordinary data.
    if (char === '<' || char === '>' || (char === '&' && script[i + 1] === '>')) {
      let prefix = '';
      if ((char === '<' || char === '>') && /^\d+$/.test(value)) {
        prefix = value;
        value = '';
        quoted = false;
        singleQuoted = false;
        doubleQuoted = false;
        hadUnquoted = false;
        shellExpanded = false;
      } else {
        push();
      }

      let operator = char;
      if (char === '&') {
        operator = script[i + 2] === '>' ? '&>>' : '&>';
      } else if (char === '<') {
        if (script[i + 1] === '<') operator = script[i + 2] === '<' ? '<<<' : '<<';
        else if (script[i + 1] === '>') operator = '<>';
        else if (script[i + 1] === '&') operator = '<&';
      } else if (script[i + 1] === '>') {
        operator = '>>';
      } else if (script[i + 1] === '&') {
        operator = '>&';
      } else if (script[i + 1] === '|') {
        operator = '>|';
      }
      tokens.push({
        type: 'word',
        value: prefix + operator,
        quoted: false,
        singleOnly: false,
        shellExpanded: false,
      });
      i += operator.length - 1;
      continue;
    }
    if (char === '\n' || /[;&|(){}]/.test(char)) {
      push();
      let operator = char;
      if ((char === '&' || char === '|') && script[i + 1] === char) {
        operator += char;
        i += 1;
      }
      tokens.push({ type: 'op', value: operator });
      continue;
    }
    if (/\s/.test(char)) {
      push();
      continue;
    }
    if (['*', '?', '['].includes(char)
        || (char === '~' && (value === '' || /[=:]$/.test(value)))) shellExpanded = true;
    value += char;
    hadUnquoted = true;
  }
  push();
  return tokens;
}

function hasRawShellExpansion(script) {
  let quote = null;
  let wordStart = true;
  for (let index = 0; index < script.length; index += 1) {
    const char = script[index];
    if (quote === "'") {
      if (char === "'") quote = null;
      continue;
    }
    if (quote === '"') {
      if (char === '"') {
        quote = null;
      } else if (char === '\\') {
        index += 1;
      } else if (char === '`' || (char === '$' && /[A-Za-z0-9_@*#?!${(\["']/.test(script[index + 1] || ''))) {
        return true;
      }
      continue;
    }
    if (char === '\\') {
      index += 1;
      wordStart = false;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      wordStart = false;
      continue;
    }
    if (/\s/.test(char) || /[;&|(){}]/.test(char)) {
      wordStart = true;
      continue;
    }
    if (char === '`'
        || (char === '$' && /[A-Za-z0-9_@*#?!${(\["']/.test(script[index + 1] || ''))
        || ((char === '<' || char === '>' || char === '=') && script[index + 1] === '(')
        || (['?', '*', '+', '@', '!'].includes(char) && script[index + 1] === '(')
        || ['*', '?', '['].includes(char)
        || (char === '~' && wordStart)) return true;
    wordStart = false;
  }
  return hasUnquotedBraceExpansion(script);
}

function hasUnquotedBraceExpansion(script) {
  let quote = null;
  let start = -1;
  for (let index = 0; index < script.length; index += 1) {
    const char = script[index];
    if (quote) {
      if (quote === "$'" && char === '\\' && ANSI_C_QUOTE_ESCAPES.has(script[index + 1])) index += 1;
      else if (quote === '"' && char === '\\') index += 1;
      else if (char === quote.slice(-1)) quote = null;
      continue;
    }
    if (char === '\\') {
      index += 1;
      continue;
    }
    if (char === '$' && script[index + 1] === "'") {
      quote = "$'";
      index += 1;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === '{') {
      start = index + 1;
      continue;
    }
    if (char === '}' && start !== -1) {
      const body = script.slice(start, index);
      if (body.includes(',') || body.includes('..')) return true;
      start = -1;
    }
  }
  return false;
}

const EXPANSION_CLOSERS = { '$(': ')', '${': '}' };

/** Index of the character that closes the context `opener` starts at `open`:
 * a '...' or $'...' literal, a "..." span, a backtick command, or a $(...)
 * or ${...} expansion (`script.length` when it never closes). Each is read
 * the way bash reads it: a `\` pairs with the next character except inside
 * '...' (never) and $'...' (only ANSI_C_QUOTE_ESCAPES); an expansion or
 * backtick inside a "..." span is its own context, so "$(echo 'a"b')" is one
 * word whose inner `"` does not end the span. Iterative on purpose: a deeply
 * nested input must not overflow the stack and crash the guard. */
function contextEnd(script, open, opener) {
  const stack = [{ opener, depth: 1 }];
  for (let index = open + opener.length; index < script.length; index += 1) {
    const char = script[index];
    const next = script[index + 1];
    const context = stack[stack.length - 1];
    if (context.opener === "'") {
      if (char === "'") stack.pop();
    } else if (context.opener === "$'") {
      if (char === '\\' && ANSI_C_QUOTE_ESCAPES.has(next)) index += 1;
      else if (char === "'") stack.pop();
    } else if (char === '\\') {
      index += 1;
    } else if (context.opener === '`') {
      if (char === '`') stack.pop();
    } else if (context.opener === '"') {
      if (char === '"') stack.pop();
      else if (char === '`') stack.push({ opener: '`', depth: 1 });
      else if (char === '$' && (next === '(' || next === '{')) {
        stack.push({ opener: char + next, depth: 1 });
        index += 1;
      }
    } else if (char === context.opener[1]) {
      // $(...) or ${...}: a nested command or parameter word where every
      // quote and expansion is live.
      context.depth += 1;
    } else if (char === EXPANSION_CLOSERS[context.opener]) {
      context.depth -= 1;
      if (context.depth === 0) stack.pop();
    } else if (char === "'" || char === '"' || char === '`') {
      stack.push({ opener: char, depth: 1 });
    } else if (char === '$' && (next === "'" || next === '(' || next === '{')) {
      stack.push({ opener: char + next, depth: 1 });
      index += 1;
    }
    if (stack.length === 0) return index;
  }
  return script.length;
}

/** Drop the text inside '...' and $'...' literals (keeping the quote marks)
 * so the synthesis regexes below only see text bash could execute. A `'`
 * inside a "..." span or behind a backslash is data, not a boundary, and
 * the span ends where bash ends it (contextEnd), not at a `"` nested in an
 * expansion. With `withinLine`, a literal or span that does not close before
 * the next newline is read as a plain character: this lexer does not read
 * heredoc bodies, so a quote in one must not hide the commands after it. */
function withoutSingleQuotedLiterals(script, { withinLine = false } = {}) {
  let output = '';
  for (let index = 0; index < script.length; index += 1) {
    const char = script[index];
    if (char === '\\' && index + 1 < script.length) {
      output += char + script[index + 1];
      index += 1;
      continue;
    }
    const opener = char === '$' && script[index + 1] === "'" ? "$'" : char;
    if (opener !== "'" && opener !== "$'" && opener !== '"') {
      output += char;
      continue;
    }
    const end = contextEnd(script, index, opener);
    const closed = end < script.length;
    if (withinLine && (!closed || script.slice(index, end).includes('\n'))) {
      output += opener;
      index += opener.length - 1;
      continue;
    }
    if (opener === '"') output += script.slice(index, end + 1);
    else output += opener + (closed ? "'" : '');
    index = end;
  }
  return output;
}

function hasSynthesizedWacliExecutable(script) {
  const visible = withoutSingleQuotedLiterals(script);
  const assignment = /(?:^|[;&|\n]\s*|\s)(?:alias\s+)?[A-Za-z_][A-Za-z0-9_]*=\s*"?(?:\$\([^)]*\bwacli\b[^)]*\)|\$\{[^}]*\bwacli\b[^}]*\}|`[^`]*\bwacli\b[^`]*`)/m;
  const evaluated = /(?:^|[;&|\n]\s*)eval\s+[^;&|\n]*(?:\$\([^)]*\bwacli\b[^)]*\)|\$\{[^}]*\bwacli\b[^}]*\}|`[^`]*\bwacli\b[^`]*`)/m;
  return assignment.test(visible) || evaluated.test(script);
}

function hasDynamicSensitiveAssignment(script) {
  const sensitivePrefix = /^(?:PATH|BASH_ENV|ENV|ZDOTDIR|WACLI_STORE_DIR|WACLI_READONLY)\+?=/;
  let current = '';
  let quote = null;
  let assignmentEligible = true;

  for (let index = 0; index < script.length; index += 1) {
    const char = script[index];
    if (quote === "'") {
      if (char === "'") quote = null;
      else current += char;
      continue;
    }
    if (quote === "$'") {
      if (char === "'") {
        quote = null;
      } else if (char === '\\' && ANSI_C_QUOTE_ESCAPES.has(script[index + 1])) {
        current += script[index + 1];
        index += 1;
      } else {
        current += char;
      }
      continue;
    }
    if (quote === '"') {
      if (char === '"') {
        quote = null;
      } else if (char === '\\' && index + 1 < script.length) {
        current += script[index + 1];
        index += 1;
      } else {
        if ((char === '$' || char === '`')
            && assignmentEligible && sensitivePrefix.test(current)) return true;
        current += char;
      }
      continue;
    }
    if (char === '\\' && index + 1 < script.length) {
      current += script[index + 1];
      index += 1;
      continue;
    }
    if (char === '$' && script[index + 1] === "'") {
      // ANSI-C quoting is literal, as the `$` check below already assumes.
      current += char;
      quote = "$'";
      index += 1;
      continue;
    }
    if (char === "'" || char === '"') {
      if (current === '') assignmentEligible = false;
      quote = char;
      continue;
    }
    if (/\s/.test(char) || /[;&|(){}]/.test(char)) {
      current = '';
      assignmentEligible = true;
      continue;
    }
    if (assignmentEligible && sensitivePrefix.test(current)) {
      if (char === '$' && script[index + 1] !== "'") return true;
      if (char === '`') return true;
      if ((char === '<' || char === '>' || char === '=') && script[index + 1] === '(') return true;
      if (char === '~' && current.endsWith('=')) return true;
    }
    current += char;
  }
  return false;
}

function segments(script) {
  const out = [];
  let current = [];
  // Keep heredoc bodies visible. A quoted delimiter suppresses expansion by
  // the outer shell but the body may still be executable input to `bash`/`sh`;
  // treating it as inert would fail open on `bash <<"EOF"`.
  for (const token of lex(script)) {
    if (token.type === 'op') {
      if (current.length) out.push(current);
      current = [];
    } else {
      current.push(token);
    }
  }
  if (current.length) out.push(current);
  return out;
}

function assignment(token) {
  const match = /^([A-Za-z_][A-Za-z0-9_]*)(\+?=)(.*)$/.exec(token);
  return match ? { name: match[1], value: match[3], append: match[2] === '+=' } : null;
}

function hasTopLevelRedirection(script) {
  return lex(script).some((token) =>
    token.type === 'word' && !token.quoted && redirectionWidth(token.value) > 0
  );
}

function basename(token) {
  return path.posix.basename(token.replace(/\\/g, '/'));
}

function redirectionWidth(token) {
  const match = /^(?:\d+|&)?(?:<<<|<<|>>|<>|>&|<&|>\||>|<)(.*)$/.exec(token);
  if (!match) return 0;
  return match[1] === '' ? 2 : 1;
}

function argvWithoutRedirections(words) {
  const args = [];
  for (let index = 0; index < words.length; index += 1) {
    const width = redirectionWidth(words[index].value);
    if (width) {
      index += width - 1;
      continue;
    }
    args.push(words[index].value);
  }
  return args;
}

function commandShape(words, inherited = {}) {
  let index = 0;
  let readOnly = Object.hasOwn(inherited, 'readOnly')
    ? inherited.readOnly
    : (process.env.WACLI_READONLY === undefined
      ? null
      : TRUTHY.has(process.env.WACLI_READONLY.toLowerCase()));
  let storeDir = Object.hasOwn(inherited, 'storeDir')
    ? inherited.storeDir
    : (process.env.WACLI_STORE_DIR || null);
  let trustedLookup = Object.hasOwn(inherited, 'trustedLookup')
    ? inherited.trustedLookup
    : true;
  let privileged = Object.hasOwn(inherited, 'privileged')
    ? inherited.privileged
    : false;
  let opaque = false;

  const applyAssignment = (parsed) => {
    if (parsed.name === 'WACLI_READONLY') {
      readOnly = parsed.append ? false : TRUTHY.has(parsed.value.toLowerCase());
    }
    if (parsed.name === 'WACLI_STORE_DIR') storeDir = parsed.append ? null : parsed.value;
    if (EXECUTION_ENV_VARS.has(parsed.name)) trustedLookup = false;
  };

  const consumeAssignments = () => {
    while (index < words.length) {
      const parsed = assignment(words[index].value);
      if (!parsed) break;
      applyAssignment(parsed);
      index += 1;
    }
  };

  consumeAssignments();

  // Unwrap the ordinary execution helpers agents put in front of a command.
  // This is bounded and explicit rather than a generic "skip options" parser:
  // wrapper options that consume a value must not promote that value to the
  // executable position and make a real wacli call disappear.
  for (let wrappers = 0; wrappers < 32 && index < words.length; wrappers += 1) {
    const redirect = redirectionWidth(words[index].value);
    if (redirect) {
      index += redirect;
      continue;
    }

    const wrapper = basename(words[index].value);

    if (wrapper === 'env') {
      index += 1;
      while (index < words.length) {
        const token = words[index].value;
        if (token === '-i' || token === '--ignore-environment') {
          readOnly = false;
          storeDir = null;
          trustedLookup = false;
          index += 1;
          continue;
        }
        if (token === '-u' || token === '--unset') {
          const name = words[index + 1]?.value;
          if (name === 'WACLI_READONLY') readOnly = false;
          if (name === 'WACLI_STORE_DIR') storeDir = null;
          if (EXECUTION_ENV_VARS.has(name)) trustedLookup = false;
          index += 2;
          continue;
        }
        if (/^-u.+/.test(token)) {
          const name = token.slice(2);
          if (name === 'WACLI_READONLY') readOnly = false;
          if (name === 'WACLI_STORE_DIR') storeDir = null;
          if (EXECUTION_ENV_VARS.has(name)) trustedLookup = false;
          index += 1;
          continue;
        }
        if (token.startsWith('--unset=')) {
          const name = token.slice('--unset='.length);
          if (name === 'WACLI_READONLY') readOnly = false;
          if (name === 'WACLI_STORE_DIR') storeDir = null;
          if (EXECUTION_ENV_VARS.has(name)) trustedLookup = false;
          index += 1;
          continue;
        }
        if (token === '-C' || token === '--chdir') {
          trustedLookup = false;
          index += 2;
          continue;
        }
        if (token === '--argv0') {
          index += 2;
          continue;
        }
        if (token.startsWith('--chdir=')) {
          trustedLookup = false;
          index += 1;
          continue;
        }
        if (token.startsWith('--argv0=')) {
          index += 1;
          continue;
        }
        if (token === '-S' || token === '--split-string' || token.startsWith('--split-string=')) {
          // env reparses this opaque string into argv. Leave wacli visible to
          // classify()'s conservative non-data-command fallback below.
          opaque = true;
          break;
        }
        if (token.startsWith('-')) {
          index += 1;
          continue;
        }
        const parsed = assignment(token);
        if (!parsed) break;
        applyAssignment(parsed);
        index += 1;
      }
      continue;
    }

    if (new Set(['if', 'then', 'elif', 'else', 'while', 'until', 'do', '!']).has(wrapper)) {
      index += 1;
      continue;
    }

    if (wrapper === 'command' || wrapper === 'nohup' || wrapper === 'exec') {
      const commandWrapper = wrapper === 'command';
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        if (commandWrapper && words[index].value === '-p') trustedLookup = false;
        index += 1;
      }
      continue;
    }

    if (wrapper === 'time') {
      const valueOptions = new Set(['-f', '--format', '-o', '--output']);
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        const option = words[index].value;
        index += 1;
        if (valueOptions.has(option) && index < words.length) index += 1;
      }
      continue;
    }

    if (wrapper === 'sudo') {
      const valueOptions = new Set(['-u', '--user', '-g', '--group', '-h', '--host']);
      privileged = true;
      trustedLookup = false;
      // sudo commonly resets the caller environment; require the read-only
      // assignment after sudo (or the explicit CLI flag) rather than assuming
      // a leading assignment survives policy.
      readOnly = false;
      storeDir = null;
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        const option = words[index].value;
        index += 1;
        if (valueOptions.has(option) && index < words.length) index += 1;
      }
      consumeAssignments();
      continue;
    }

    if (wrapper === 'timeout') {
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        const option = words[index].value;
        index += 1;
        if (['-k', '--kill-after', '-s', '--signal'].includes(option) && index < words.length) index += 1;
      }
      if (index < words.length) index += 1; // duration
      continue;
    }

    if (wrapper === 'stdbuf') {
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        const option = words[index].value;
        index += 1;
        if (['-i', '--input', '-o', '--output', '-e', '--error'].includes(option)
            && index < words.length) index += 1;
      }
      continue;
    }

    if (wrapper === 'nice') {
      index += 1;
      if (words[index]?.value === '-n' || words[index]?.value === '--adjustment') index += 2;
      else if (words[index]?.value?.startsWith('--adjustment=')) index += 1;
      else if (/^-n[+-]?\d+$/.test(words[index]?.value || '')) index += 1;
      else if (/^-[0-9]+$/.test(words[index]?.value || '')) index += 1;
      continue;
    }

    break;
  }

  return {
    executable: words[index]?.value || '',
    args: argvWithoutRedirections(words.slice(index + 1)),
    words,
    index,
    readOnly,
    storeDir,
    trustedLookup,
    privileged,
    opaque,
  };
}

function primaryArgs(args) {
  const positional = [];
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (GLOBAL_VALUE_FLAGS.has(token)) {
      index += 1;
      continue;
    }
    if ([...GLOBAL_VALUE_FLAGS].some((flag) => token.startsWith(`${flag}=`))) continue;
    if (GLOBAL_BOOLEAN_FLAGS.has(token)) continue;
    if (token.startsWith('-')) continue;
    positional.push(token);
  }
  return positional;
}

function readOnlyMode(shape) {
  let mode = shape.readOnly;
  // A later explicit false wins in pflag even if a safe flag/environment value
  // appeared first. Treat it conservatively wherever it occurs; if this token
  // was merely message text, an extra prompt is safer than an unreviewed send.
  if (shape.args.some((token) => token.startsWith('--read-only=')
      && !TRUTHY.has(token.slice('--read-only='.length).toLowerCase()))) return false;
  // Trust the CLI flag only in the documented global prefix, before the first
  // command word. A later `--read-only` can be a value (for example the text of
  // `--message`) and must not turn a real send into an auto-approved read.
  for (let index = 0; index < shape.args.length; index += 1) {
    const token = shape.args[index];
    if (GLOBAL_VALUE_FLAGS.has(token)) {
      index += 1;
      continue;
    }
    if ([...GLOBAL_VALUE_FLAGS].some((flag) => token.startsWith(`${flag}=`))) continue;
    if (token === '--read-only') {
      mode = true;
      continue;
    }
    if (token.startsWith('--read-only=')) {
      mode = TRUTHY.has(token.slice('--read-only='.length).toLowerCase());
      continue;
    }
    if (GLOBAL_BOOLEAN_FLAGS.has(token)) continue;
    if (token.startsWith('-')) continue;
    break;
  }
  return mode === true;
}

function parsedLongOptions(args) {
  const options = [];
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--') break;
    if (!token.startsWith('--')) continue;

    const equals = token.indexOf('=');
    const name = equals === -1 ? token : token.slice(0, equals);
    let value = equals === -1 ? null : token.slice(equals + 1);
    if (CLI_VALUE_FLAGS.has(name) && equals === -1) {
      if (index + 1 >= args.length) return null;
      value = args[index + 1];
      index += 1;
    }
    options.push({ name, value });
  }
  return options;
}

function hasOption(args, name) {
  const options = parsedLongOptions(args);
  return options !== null && options.some((option) => option.name === name);
}

function enabledBooleanOption(args, name) {
  const options = parsedLongOptions(args);
  if (options === null) return false;
  let enabled = false;
  for (const option of options) {
    if (option.name !== name) continue;
    enabled = option.value === null || new Set(['1', 't', 'true']).has(
      option.value.toLowerCase()
    );
  }
  return enabled;
}

function boundedPositiveIntegerOption(args, name, maximum) {
  const options = parsedLongOptions(args);
  if (options === null) return false;
  const values = options.filter((option) => option.name === name).map((option) => option.value);
  if (values.length === 0) return false;
  return values.every((value) => {
    if (!/^[1-9]\d*$/.test(value || '')) return false;
    const numeric = Number(value);
    return Number.isSafeInteger(numeric) && numeric <= maximum;
  });
}

function optionalBoundedNonnegativeIntegerOption(args, name, maximum) {
  const options = parsedLongOptions(args);
  if (options === null) return false;
  return options.filter((option) => option.name === name).every((option) => {
    if (!/^\d+$/.test(option.value || '')) return false;
    const numeric = Number(option.value);
    return Number.isSafeInteger(numeric) && numeric <= maximum;
  });
}

function hasShellExpansion(shape) {
  return shape.words.some((word) =>
    word.shellExpanded
    || (!word.singleOnly && /\$\(|\$\{|\$[A-Za-z0-9_@*#?!-]|`|[<>=]\(/.test(word.value))
  );
}

function hasPreExecutableShellExpansion(shape) {
  return hasShellExpansion({ words: shape.words.slice(0, shape.index) });
}

function selectedStore(shape) {
  let store = shape.storeDir;
  const options = parsedLongOptions(shape.args);
  if (options === null) return null;
  for (const option of options) {
    if (option.name === '--account') return null;
    if (option.name === '--store') store = option.value || null;
  }
  return store;
}

function safeInvocation(shape) {
  const { args } = shape;
  const dynamic = hasShellExpansion(shape);
  const canonicalStore = selectedStore(shape) === CANONICAL_STORE;
  if (!reviewedExecutable(shape)) return false;
  if (args.length === 0) return true; // bare command prints help

  const positional = primaryArgs(args);
  const commandPath = positional.slice(0, 2).join(' ');
  const structured = enabledBooleanOption(args, '--json');
  const bounded = boundedPositiveIntegerOption(args, '--limit', MAX_AUTO_READ_LIMIT);

  if (readOnlyMode(shape) && !dynamic && canonicalStore && structured) {
    if (POINT_READ_PATHS.has(commandPath)) return true;
    if (commandPath === 'messages context'
        && optionalBoundedNonnegativeIntegerOption(args, '--before', MAX_CONTEXT_SIDE)
        && optionalBoundedNonnegativeIntegerOption(args, '--after', MAX_CONTEXT_SIDE)) return true;
    if (BOUNDED_READ_PATHS.has(commandPath) && bounded) return true;
  }

  // Keep only the unambiguous global forms frictionless. Subcommand help can use
  // `wacli help <path>`; a mutation command that merely contains --help or
  // --version still asks rather than trusting flag precedence across releases.
  if (!dynamic && positional.length === 0
      && args.every((token) => ['--help', '-h', '--version', '-v'].includes(token))) return true;
  if (!dynamic && positional[0] === 'help') return true;
  if (!dynamic && positional.length === 1 && positional[0] === 'version') return true;
  if (!dynamic && canonicalStore && structured
      && positional[0] === 'auth' && positional[1] === 'status') return true;
  if (!dynamic && canonicalStore && structured
      && positional[0] === 'doctor' && !hasOption(args, '--connect')) return true;
  return false;
}

function trustedNestedShell(shape) {
  if (shape.privileged || !shape.trustedLookup) return false;
  const shell = basename(shape.executable);
  const trustedTargets = {
    bash: new Set(['/usr/bin/bash']),
    sh: new Set(['/usr/bin/dash']),
    dash: new Set(['/usr/bin/dash']),
    zsh: new Set(['/usr/bin/zsh']),
  };
  if (!trustedTargets[shell]) return false;
  const candidate = shape.executable === shell
    ? firstPathExecutable(shell)
    : path.resolve(shape.executable);
  if (!candidate) return false;
  try {
    return trustedTargets[shell].has(fs.realpathSync(candidate));
  } catch {
    return false;
  }
}

function shellPayload(shape) {
  const shell = basename(shape.executable);
  if (!new Set(['sh', 'bash', 'zsh', 'dash']).has(shell)) return null;
  for (let index = 0; index < shape.args.length - 1; index += 1) {
    if (/^-[^-]*c[^-]*$/.test(shape.args[index]) || shape.args[index] === '--command') {
      const next = shape.args[index + 1] === '--' ? index + 2 : index + 1;
      return shape.args[next] || null;
    }
  }
  return null;
}

function valueContainsWacliToken(value) {
  return lex(value).some((token) => {
    if (token.type !== 'word') return false;
    // Bash's ANSI-C / locale quote prefixes survive this small lexer as a
    // leading `$` (`$'wacli'` -> `$wacli`). Strip only that marker before the
    // executable-token comparison; arbitrary no-literal synthesis stays out of scope.
    const normalized = token.value.startsWith('$') ? token.value.slice(1) : token.value;
    return basename(normalized) === 'wacli';
  });
}

function childExecutionContext(shape) {
  return {
    readOnly: shape.readOnly,
    storeDir: shape.storeDir,
    trustedLookup: shape.trustedLookup,
    privileged: shape.privileged,
  };
}

function crossSegmentWacliEnvMutation(parsedSegments) {
  let priorMutation = false;
  let dynamic = false;
  const names = new Set([...EXECUTION_ENV_VARS, 'WACLI_READONLY', 'WACLI_STORE_DIR']);
  const declarations = new Set(['export', 'readonly', 'typeset', 'declare', 'unset']);

  for (const words of parsedSegments) {
    const mentionsWacli = words.some((word) => /\bwacli\b/.test(word.value));
    if (priorMutation && mentionsWacli) return { detected: true, dynamic };

    const first = basename(words[0]?.value || '');
    for (let index = 0; index < words.length; index += 1) {
      const word = words[index];
      const parsed = assignment(word.value);
      const isMutation = parsed && names.has(parsed.name)
        && (index === 0 || declarations.has(first));
      const isNameOnlyMutation = declarations.has(first) && names.has(word.value);
      if (!isMutation && !isNameOnlyMutation) continue;
      priorMutation = true;
      dynamic ||= word.shellExpanded
        || (!word.singleOnly && /\$\(|\$\{|\$[A-Za-z0-9_@*#?!-]|`|[<>=]\(/.test(word.value));
    }
  }
  return { detected: false, dynamic: false };
}

function hasDynamicWacliExecutable(script, parsedSegments, inherited) {
  const variables = new Set();
  const aliases = new Set();
  for (const words of parsedSegments) {
    const first = basename(words[0]?.value || '');
    for (let index = 0; index < words.length; index += 1) {
      const word = words[index];
      if (word.singleOnly) continue;
      const parsed = assignment(word.value);
      if (!parsed || !valueContainsWacliToken(parsed.value)) continue;
      // Shell wrappers and declaration builtins can export assignments into a
      // nested interpreter. Tracking every assignment token is conservative,
      // but avoids laundering taint through `env`, `sudo env`, or a later export.
      variables.add(parsed.name);
      if (first === 'alias') aliases.add(parsed.name);
    }
  }

  for (const words of parsedSegments) {
    const shape = commandShape(words, inherited);
    const executableWord = shape.words[shape.index];
    if (executableWord && !executableWord.singleOnly
        && /\bwacli\b/.test(shape.executable) && /\$|`/.test(shape.executable)) return true;
    const variable = /^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/.exec(shape.executable);
    if (variable && variables.has(variable[1])) return true;
    if (aliases.has(basename(shape.executable))) return true;
    const nested = shellPayload(shape);
    if (nested) {
      for (const name of variables) {
        if (new RegExp(`\\$(?:\\{${name}\\}|${name}\\b)`).test(nested)) return true;
      }
      for (const name of aliases) {
        if (new RegExp(`(?:^|[;&|\\n]\\s*)${name}(?=\\s|$)`).test(nested)) return true;
      }
    }
  }

  // Command substitution can synthesize argv[0] before our lexer sees a literal
  // executable. Restrict this to shell-command boundaries so an ordinary echo
  // argument containing `$(printf wacli)` remains data.
  const prefix = String.raw`(?:^|[;&|\n]\s*)(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S+)\s+)*`;
  const dollarCommand = new RegExp(
    prefix + String.raw`\$\([^\n)]*\bwacli\b[^\n)]*\)(?=\s|$)`
  );
  const parameterCommand = new RegExp(
    prefix + String.raw`\$\{[^}\n]*\bwacli\b[^}\n]*\}(?=\s|$)`
  );
  const backtickCommand = new RegExp(
    prefix + "`[^`\\n]*\\bwacli\\b[^`\\n]*`(?=\\s|$)"
  );
  return dollarCommand.test(script) || parameterCommand.test(script) || backtickCommand.test(script);
}

function classify(script, depth = 0, inherited = {}) {
  if (depth > 3) return { seen: /\bwacli\b/.test(script), unsafe: true, dynamic: true };
  const braceExpanded = hasUnquotedBraceExpansion(script);
  const rawExpanded = hasRawShellExpansion(script);
  if (/\bwacli\b/.test(script)
      && (hasDynamicSensitiveAssignment(script) || hasSynthesizedWacliExecutable(script))) {
    return { seen: true, unsafe: true, dynamic: true };
  }
  const parsedSegments = segments(script);
  const crossSegmentMutation = crossSegmentWacliEnvMutation(parsedSegments);
  const dynamicExecutable = hasDynamicWacliExecutable(script, parsedSegments, inherited);
  if (crossSegmentMutation.detected) {
    return {
      seen: true,
      unsafe: true,
      dynamic: crossSegmentMutation.dynamic || dynamicExecutable,
    };
  }
  if (dynamicExecutable) return { seen: true, unsafe: true, dynamic: true };
  let seen = false;
  let exclusive = !hasTopLevelRedirection(script);

  for (const words of parsedSegments) {
    let owned = false;
    const shape = commandShape(words, inherited);
    const executable = basename(shape.executable);

    if (executable === 'wacli') {
      seen = true;
      if (braceExpanded || !safeInvocation(shape)) {
        return {
          seen: true,
          unsafe: true,
          dynamic: rawExpanded || braceExpanded || hasShellExpansion(shape) || /[<>=]\(/.test(script),
        };
      }
      continue;
    }

    const nested = shellPayload(shape);
    const shellExecutable = new Set(['sh', 'bash', 'zsh', 'dash']).has(executable);
    const shellInputLoader = shellExecutable || new Set(['source', '.']).has(executable);
    if (shellInputLoader && !nested) {
      const literalSignal = words.some((word) => /\bwacli\b/.test(word.value));
      const processSubstitutionSignal = /[<>=]\([\s\S]*\bwacli\b/.test(script);
      if (literalSignal || processSubstitutionSignal) {
        return {
          seen: true,
          unsafe: true,
          dynamic: processSubstitutionSignal || braceExpanded || hasShellExpansion(shape),
        };
      }
    }
    if (nested && /\bwacli\b/.test(nested)) {
      const result = classify(nested, depth + 1, childExecutionContext(shape));
      seen ||= result.seen;
      if (result.unsafe) {
        return {
          ...result,
          dynamic: result.dynamic || braceExpanded || hasShellExpansion(shape),
        };
      }
      if (result.seen && !trustedNestedShell(shape)) {
        return { seen: true, unsafe: true, dynamic: braceExpanded || hasShellExpansion(shape) };
      }
      if (result.seen) {
        exclusive = exclusive && result.exclusive;
        owned = true;
      }
    }

    if (executable === 'eval' && shape.args.some((arg) => /\bwacli\b/.test(arg))) {
      const payload = shape.args.find((arg) => /\bwacli\b/.test(arg)) || '';
      return {
        seen: true,
        unsafe: true,
        dynamic: hasUnquotedBraceExpansion(payload) || /\$|`|[<>=]\(/.test(payload),
      };
    }

    // Command substitutions execute even when the containing command is a
    // harmless echo/printf. Recursively inspect bounded non-nested forms. When
    // nesting prevents a complete parse, fail safe instead of classifying only
    // the inner substitution and missing an outer wacli command.
    for (const word of words) {
      if (word.singleOnly || !word.value.includes('wacli')) continue;
      const substitutions = [...word.value.matchAll(/\$\(([^()]*)\)/g)];
      const openCount = (word.value.match(/\$\(/g) || []).length;
      if (openCount > substitutions.length) {
        return { seen: true, unsafe: true, dynamic: true };
      }
      for (const match of substitutions) {
        const result = classify(match[1], depth + 1, childExecutionContext(shape));
        seen ||= result.seen;
        if (result.unsafe) {
          return {
            ...result,
            dynamic: result.dynamic || hasPreExecutableShellExpansion(shape),
          };
        }
        if (result.seen && !shape.trustedLookup) {
          return { seen: true, unsafe: true, dynamic: true };
        }
        if (result.seen) {
          exclusive = exclusive && result.exclusive;
          if (LITERAL_DATA_COMMANDS.has(executable)) owned = true;
        }
      }
    }

    // Backtick bodies often span several lexer words. Rejoin only executable
    // (not single-quoted literal) text before recursively classifying them.
    const executableText = words
      .filter((word) => !word.singleOnly)
      .map((word) => word.value)
      .join(' ');
    for (const match of executableText.matchAll(/`([^`]*)`/g)) {
      if (!/\bwacli\b/.test(match[1])) continue;
      const result = classify(match[1], depth + 1, childExecutionContext(shape));
      seen ||= result.seen;
      if (result.unsafe) {
        return {
          ...result,
          dynamic: result.dynamic || hasPreExecutableShellExpansion(shape),
        };
      }
      if (result.seen && !shape.trustedLookup) {
        return { seen: true, unsafe: true, dynamic: true };
      }
      if (result.seen) {
        exclusive = exclusive && result.exclusive;
        if (LITERAL_DATA_COMMANDS.has(executable)) owned = true;
      }
    }
    if ((executableText.match(/`/g) || []).length % 2 === 1 && /\bwacli\b/.test(executableText)) {
      return { seen: true, unsafe: true, dynamic: true };
    }

    // Unknown wrappers should cost a prompt, not become a bypass. Keep the
    // narrow data-command allowlist so searches/prose mentioning "wacli" remain
    // inert; code runtimes are deliberately outside this guardrail's threat model.
    const visibleWacli = words.some((word) =>
      !word.singleOnly && !assignment(word.value) && basename(word.value) === 'wacli'
    );
    if ((shape.opaque || visibleWacli) && !LITERAL_DATA_COMMANDS.has(executable)) {
      return {
        seen: true,
        unsafe: true,
        dynamic: braceExpanded || hasShellExpansion(shape),
      };
    }
    if (!owned) exclusive = false;
  }

  return { seen, unsafe: false, dynamic: false, exclusive };
}

// Literal named Discord CLI, optional global flags (argparse also accepts their
// unique prefixes, e.g. --time 5), then a write verb, api not directly followed
// by a literal GET, or an expansion in verb position. Shared with
// discord-write-guard.js so this file's fallback for an unloadable classifier
// cannot drift from it. The optional quotes around GET sit inside the lookahead
// so backtracking cannot step past a quote and miss the GET.
const DISCORD_API_WRITE = String.raw`api(?![\w-]|["']?\s+["']?GET["']?(?:[\s;&|)]|$))`;
const DISCORD_WRITE_TAIL = String.raw`(?:\s+(?:--j(?:s(?:on?)?)?|--t(?:i(?:m(?:e(?:o(?:ut?)?)?)?)?)?(?:=|\s+)\S+))*\s+["']?(?:send|edit|delete|${DISCORD_API_WRITE}|\$|` + '`)';
const DISCORD_WRITE_RE = new RegExp(String.raw`\b(?:discord-cli|discord_cli\.py)['"]?` + DISCORD_WRITE_TAIL);
// Literal named Resend CLI (or its module) running any command path at all:
// the fallback for an unloadable resend-write-guard.js asks on reads too,
// since the tier map that tells a read from a send lives in that classifier.
// --where, --version, --help and a bare call stay quiet.
const RESEND_COMMAND_RE = /\b(?:resend-cli|resend_cli(?:\.py)?)['"]?(?:\s+(?:--confirm-\S+|--json|-q|--quiet))*\s+["']?[^\s"'-]/;

function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    if (input.tool_name && input.tool_name !== 'Bash') return rawInput;
    const command = input.tool_input?.command;
    if (typeof command !== 'string') return rawInput;

    setDenyContext({
      guard: 'whatsapp-guard',
      cwd: input.cwd,
      sessionId: input.session_id,
      agentId: input.agent_id,
      tool: input.tool_name || 'Bash',
      command,
    });

    // Reuse the established hook registration for Discord's human ask floor.
    // Decided before the wacli classifier so an exception there cannot skip it;
    // a wacli deny still wins below. Lazy require avoids the import cycle.
    let discordDecision = null;
    try {
      discordDecision = require('./discord-write-guard').evaluate(input);
    } catch {
      // Classifier unavailable: never deny, but a literal named write still asks.
      if (DISCORD_WRITE_RE.test(command)) {
        discordDecision = ask('This Discord CLI call writes to Discord (a message send, edit, or delete, or a non-GET api call) and the Discord classifier is unavailable. Human approval is required for the exact Bash command.');
      }
    }
    // Same ask floor for Resend sends, writes and deletes, keyed on the command
    // path rather than the --confirm-* text the settings rules match, so a
    // flag held in a variable, quoted, escaped or inside `bash -c` still asks.
    let resendDecision = null;
    try {
      resendDecision = require('./resend-write-guard').evaluate(input);
    } catch {
      if (RESEND_COMMAND_RE.test(command)) {
        resendDecision = ask('This Resend CLI call runs a command and the Resend classifier is unavailable. Human approval is required for the exact Bash command.');
      }
    }
    const askDecision = discordDecision || resendDecision;

    let result;
    try {
      result = classify(command);
    } catch {
      return askDecision || rawInput;
    }
    if (result.unsafe && result.dynamic) {
      return deny(
        'Blocked: this wacli call contains shell-expanded values, so the permission ' +
          'dialog cannot show the exact executable, store, query, recipient, or payload ' +
          'that will be used. Resolve variables, command substitutions, and process ' +
          'substitutions first, then retry with literal arguments.'
      );
    }
    if (askDecision) return askDecision;

    if (result.unsafe) {
      return ask(
        'This wacli call is not provably local/read-only and can contact WhatsApp or ' +
          'mutate messages, chats, groups, profile state, or the linked-device session. ' +
          'Confirm the exact Bash command before it runs. For local reads, use ' +
          '`wacli --store ' + CANONICAL_STORE + ' --read-only --json ...`.'
      );
    }
    if (result.seen && result.exclusive) {
      return allow('Explicit local/read-only wacli call; no WhatsApp mutation is possible.');
    }
  } catch {
    // Invalid JSON or unexpected input: preserve the established fail-open hook posture.
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
  classify,
  lex,
  segments,
  commandShape,
  safeInvocation,
  shellPayload,
  childExecutionContext,
  trustedNestedShell,
  crossSegmentWacliEnvMutation,
  hasDynamicWacliExecutable,
  hasDynamicSensitiveAssignment,
  hasSynthesizedWacliExecutable,
  hasRawShellExpansion,
  hasUnquotedBraceExpansion,
  withoutSingleQuotedLiterals,
  DISCORD_WRITE_TAIL,
  DISCORD_WRITE_RE,
  RESEND_COMMAND_RE,
};
