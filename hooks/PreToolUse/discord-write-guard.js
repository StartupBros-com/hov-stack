/**
 * Discord write ask floor, called by the already-registered WhatsApp guard.
 * Asks only when a command executes discord-cli / discord_cli.py (directly,
 * through python -m discord_cli, a wrapper, a shell, or eval of a held string)
 * with a write verb (send, edit, delete), an api call whose method is not a
 * literal GET, or a verb or method that cannot be read statically. Never
 * denies; every other command passes through. --confirm-write
 * is not human approval, so the ask holds under bypassPermissions. Renamed
 * copies, python -c, shells outside SHELLS, exec -a, brace-expanded verbs,
 * script files read from stdin, and raw API clients remain outside this
 * classifier.
 */
'use strict';

const path = require('node:path');
const {
  segments, commandShape, shellPayload, lex, withoutSingleQuotedLiterals,
  DISCORD_WRITE_TAIL: WRITE_TAIL, DISCORD_WRITE_RE: WRITE_RE,
} = require('./whatsapp-guard');
const { ask } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

// Keep equal to WRITES in bin/discord_cli.py (cross-checked by the test).
const WRITES = new Set(['send', 'edit', 'delete']);
const DATA = new Set(['echo', 'printf', 'rg', 'grep', 'egrep', 'fgrep', 'cat']);
// Commands that only name a file and never execute it, so a file argument
// followed by a verb-named operand is not a Discord write.
const INSPECT = new Set(['ls', 'head', 'tail', 'wc', 'mv', 'cp', 'rm', 'touch', 'tee', 'diff', 'vim', 'vi', 'nano', 'less', 'more', 'stat', 'file', 'chmod', 'ln']);
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash']);
const DECLARATIONS = new Set(['alias', 'export', 'readonly', 'declare', 'typeset']);
const SIGNAL = /\b(?:discord-cli|discord_cli\.py)\b/;
// WRITE_RE (named CLI, global flags, write or unreadable verb, api without an
// adjacent literal GET) covers text the lexer cannot attribute to one command;
// it lives in whatsapp-guard.js so the fallback there for an unloadable
// classifier matches it. It also asks when api options precede the method.
const basename = (value) => path.posix.basename(value.replace(/\\/g, '/'));
const named = (value) => new Set(['discord-cli', 'discord_cli.py']).has(basename(value));

function cliArgs(shape) {
  if (named(shape.executable)) return shape.args;
  if (!/^python(?:\d+(?:\.\d+)*)?$/.test(basename(shape.executable))) return null;
  const args = shape.args;
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value.startsWith('--')) continue;
    if (value.length > 1 && value.startsWith('-')) {
      // Short options cluster (-Bm). -c and -m end option parsing; -m, -X and
      // -W take the rest of the cluster or the next word as their value.
      for (let at = 1; at < value.length; at += 1) {
        const flag = value[at];
        if (flag === 'c') return null; // arbitrary code is outside this guardrail
        if (!['m', 'X', 'W'].includes(flag)) continue;
        const operand = value.slice(at + 1) || args[(index += 1)];
        if (flag !== 'm') break;
        return /(?:^|\.)discord_cli$/.test(operand || '') ? args.slice(index + 1) : null;
      }
      continue;
    }
    return basename(value) === 'discord_cli.py' ? args.slice(index + 1) : null;
  }
  return null;
}

// argparse (allow_abbrev) also accepts any unique prefix of a long option;
// every top-level option differs by its first letter after the dashes.
const abbreviates = (value, option) => value.length >= 3 && option.startsWith(value);

// An expansion before the verb or method can word-split into one.
const UNREADABLE = /[$`*?{]/;

// The index of the last word an option consumed, or -1 when its value cannot
// be read statically.
function optionValue(args, index, name) {
  const value = args[index];
  if (name !== value) return UNREADABLE.test(value.slice(name.length + 1)) ? -1 : index;
  return UNREADABLE.test(args[index + 1] || '') ? -1 : index + 1;
}

// api reads only when its method, the first positional after the api options
// (argparse accepts them first), is a literal GET. A missing method asks: it
// may arrive from xargs or an expansion.
function apiWrites(args) {
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    const name = value.split('=')[0];
    if (value === '-h' || abbreviates(name, '--help')) return false;
    if (['--timeout', '--query', '--body'].some((option) => abbreviates(name, option))) {
      index = optionValue(args, index, name);
      if (index === -1) return true;
      continue;
    }
    if (value.startsWith('-') && !/[$`]/.test(value)) continue;
    return value !== 'GET';
  }
  return true;
}

// True when the first positional (after the global flags) is a write verb, an
// api write, or cannot be read statically. --help/--where/--version and bare
// calls have no effect.
function writeVerb(args) {
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    const name = value.split('=')[0];
    if (abbreviates(name, '--json')) continue;
    if (abbreviates(name, '--timeout')) {
      index = optionValue(args, index, name);
      if (index === -1) return true;
      continue;
    }
    if (value === '-h' || ['--where', '--help', '--version'].some((option) => abbreviates(value, option))) return false;
    if (value.startsWith('-') && !/[$`]/.test(value)) continue;
    if (value === 'api') return apiWrites(args.slice(index + 1));
    return WRITES.has(value) || UNREADABLE.test(value);
  }
  return false;
}

function assignment(word) {
  const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(word.value);
  return match ? { name: match[1], value: match[2] } : null;
}

function containsNamedValue(value) {
  return lex(value).some((word) => word.type === 'word' && named(word.value));
}

function shellPipelines(script) {
  const groups = [];
  let pipeline = [];
  let words = [];
  const segment = () => {
    if (words.length) pipeline.push(commandShape(words));
    words = [];
  };
  const finish = () => {
    segment();
    if (pipeline.length > 1 && pipeline.some((shape) => SHELLS.has(basename(shape.executable)) || sourcesStdin(shape))) {
      groups.push(pipeline);
    }
    pipeline = [];
  };
  for (const token of lex(script)) {
    if (token.type === 'word') words.push(token);
    else if (token.value === '|' || token.value === '|&') segment();
    else finish();
  }
  finish();
  return groups;
}

function stripQuotedDataHeredocs(script) {
  const lines = script.split('\n');
  const kept = [];
  let delimiter = null;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (delimiter !== null) {
      if (line === delimiter) delimiter = null;
      continue;
    }
    kept.push(line);
    // Check the logical header too: a continued pipeline/redirection can feed
    // the quoted data into a shell on the following physical line.
    let header = line;
    let next = index;
    while (header.endsWith('\\') && next + 1 < lines.length) {
      header = header.slice(0, -1) + lines[++next];
    }
    const words = segments(header)[0] || [];
    const shape = commandShape(words);
    // Shell consumers and process substitutions make this executable input.
    if (!DATA.has(basename(shape.executable)) || shellPipelines(header).length || /[<>=]\(/.test(header)) continue;
    const redirectIndex = words.findIndex((word) => word.value === '<<');
    if (redirectIndex !== -1 && words[redirectIndex + 1]?.quoted) delimiter = words[redirectIndex + 1].value;
  }
  return kept.join('\n');
}

// A script operand naming fd 0, in any spelling, reads stdin like no operand.
// A glob, parameter or backtick operand is not resolved here, so it may too.
const readsStdin = (arg) => arg !== undefined
  && (/[*?[$`]/.test(arg) || /(?:^|\/)(?:stdin|fd\/0)$/.test(path.posix.normalize(arg)));

// source or . given fd 0 runs whatever reaches stdin, like a shell.
function sourcesStdin(shape) {
  const executable = basename(shape.executable);
  if (executable !== 'source' && executable !== '.') return false;
  return readsStdin(shape.args[shape.args[0] === '--' ? 1 : 0]);
}

// Any command a process substitution body runs, after a pipe or list operator
// too, may be a shell reading stdin.
function runsShell(body) {
  return segments(body).some((words) => {
    const shape = commandShape(words);
    return SHELLS.has(basename(shape.executable)) || sourcesStdin(shape);
  });
}

// The lexer splits {...}, (...), ${...} and $(...) off the words around them,
// so a shell's operand and the here-string feeding it can land in different
// segments. Operators nested in a group or substitution do not end a command;
// a split command that runs a shell or source has its here-strings classified.
function splitHereStrings(script) {
  const payloads = [];
  let command = [];
  let words = [];
  let nesting = 0;
  const endSegment = () => {
    if (words.length) command.push(commandShape(words));
    words = [];
  };
  const endCommand = () => {
    endSegment();
    const runs = (shape) => SHELLS.has(basename(shape.executable)) || ['source', '.'].includes(basename(shape.executable));
    if (command.length > 1 && command.some(runs)) {
      for (const shape of command) payloads.push(hereStringWord(shape));
    }
    command = [];
  };
  for (const token of lex(script)) {
    if (token.type === 'word') words.push(token);
    else if (token.value === '{' || token.value === '(') { endSegment(); nesting += 1; }
    else if (token.value === '}' || token.value === ')') { endSegment(); nesting = Math.max(0, nesting - 1); }
    else if (nesting > 0) endSegment();
    else endCommand();
  }
  endCommand();
  return payloads.filter(Boolean);
}

function stdinHereString(shape) {
  if (sourcesStdin(shape)) return hereString(shape);
  if (!SHELLS.has(basename(shape.executable))) return null;
  let stdinMode = false;
  for (let index = 0; index < shape.args.length; index += 1) {
    const arg = shape.args[index];
    if (/^-[^-]*c/.test(arg) || arg === '--command') return null;
    if (/^-[^-]*s/.test(arg)) stdinMode = true;
    if (/^[+-][^-]*[oO]/.test(arg) || ['--rcfile', '--init-file'].includes(arg)) { index += 1; continue; }
    if (arg === '--') {
      const script = shape.args[index + 1];
      if (!stdinMode && script !== undefined && !readsStdin(script)) return null;
      break;
    }
    if (arg === '-') break;
    if (!arg.startsWith('-') && !arg.startsWith('+')) {
      if (!stdinMode && !readsStdin(arg)) return null; // a script filename, not stdin
      break;
    }
  }
  return hereString(shape);
}

// Only the last stdin redirection supplies stdin. Other fd operands and
// quoted lookalikes remain data, even when they name a Discord write.
function hereStringWord(shape) {
  let payload = null;
  for (let index = 0; index < shape.words.length; index += 1) {
    const word = shape.words[index];
    if (word.quoted) continue;
    const redirect = /^(\d*)(<<<|<<|>>|<>|>&|<&|>\||>|<)$/.exec(word.value);
    if (!redirect) continue;
    const operand = shape.words[++index];
    if (Number(redirect[1] || 0) === 0 && redirect[2].startsWith('<')) {
      payload = redirect[2] === '<<<' ? operand : null;
    }
  }
  return payload;
}

function hereString(shape) {
  return hereStringWord(shape)?.value ?? null;
}

const EXEC_HELPER = (shape, executable) => executable === 'eval' || executable === 'xargs' || shape.opaque
  || SHELLS.has(executable)
  || (executable === 'find' && shape.args.some((arg) => ['-exec', '-execdir', '-ok', '-okdir'].includes(arg)));
// Quoted text an execution helper runs: a named write, or the named CLI with
// $'...' escapes, which the shared lexer does not decode.
const quotedWrite = (word) => !word.singleOnly && word.quoted && SIGNAL.test(word.value)
  && (WRITE_RE.test(word.value) || /\\(?:x[0-9a-f]{2}|[0-7]{2,3}|u[0-9a-f]{4})/i.test(word.value));
const aliasVar = (value) => /^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/.exec(value)?.[1];
const SYNTH_NAME = String.raw`(?:discord-cli|discord_cli\.py)`;
// A synthesized executable (command/backtick/parameter substitution naming the
// CLI) is classified by the words that follow it.
const SYNTHESIZED = new RegExp(
  String.raw`(?:^|[;&|\n]\s*)(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S+)\s+)*(?:\$\([^\n)]*${SYNTH_NAME}[^\n)]*\)`
  + String.raw`|` + '`[^`\\n]*' + SYNTH_NAME + '[^`\\n]*`'
  + String.raw`|\$\{[^}\n]*${SYNTH_NAME}[^}\n]*\})([^\n;&|]*)`, 'g');
const SUBSTITUTED_ASSIGNMENT = new RegExp(
  String.raw`(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=["']?(?:\$\([^\n)]*${SYNTH_NAME}[^\n)]*\)`
  + '|`[^`\\n]*' + SYNTH_NAME + '[^`\\n]*`)', 'g');
const wordValues = (text) => lex(text).filter((word) => word.type === 'word').map((word) => word.value);

// True when the script executes the named CLI with a write (or unreadable) verb.
function classify(inputScript, depth = 0, inheritedNames = new Map()) {
  const script = stripQuotedDataHeredocs(inputScript);
  if (depth > 4) return WRITE_RE.test(script);
  const parsed = segments(script);
  const aliases = new Map(inheritedNames);
  for (const words of parsed) {
    const first = basename(words[0]?.value || '');
    if (DATA.has(first)) continue;
    const shape = commandShape(words);
    for (let index = 0; index < words.length; index += 1) {
      const value = assignment(words[index]);
      // commandShape consumes every leading assignment, including X=1 D=... .
      if (value && (index < shape.index || DECLARATIONS.has(first) || first === 'env')
          && containsNamedValue(value.value)) {
        const parts = wordValues(value.value);
        aliases.set(value.name, parts.slice(parts.findIndex(named) + 1));
      }
    }
  }
  // The lexer splits an unquoted d=$(command -v discord-cli) into several
  // words, and ${d} into separate segments, so a substitution-held CLI path
  // and its use are matched in the raw text. Single-quoted text never runs;
  // a quote left open on its line stays visible (an apostrophe in a heredoc
  // body must not hide the commands after it).
  const unquoted = withoutSingleQuotedLiterals(script, { withinLine: true });
  for (const match of unquoted.matchAll(SUBSTITUTED_ASSIGNMENT)) {
    if (!aliases.has(match[1])) aliases.set(match[1], []);
  }
  for (const name of aliases.keys()) {
    if (new RegExp(String.raw`"?\$\{?${name}\}?"?` + WRITE_TAIL).test(unquoted)) return true;
  }

  for (const match of script.matchAll(SYNTHESIZED)) {
    if (writeVerb(wordValues(match[1]))) return true;
  }

  // Literal data becomes executable input when piped into a shell, and so
  // does a here-string anywhere in that pipeline, since a filter passes it on;
  // it gets the script and quoted-text checks a shell's own here-string gets.
  for (const pipeline of shellPipelines(script)) {
    for (const shape of pipeline) {
      const word = hereStringWord(shape);
      if (word && (WRITE_RE.test(word.value) || classify(word.value, depth + 1, aliases) || quotedWrite(word))) return true;
      if (DATA.has(basename(shape.executable)) && shape.args.some((arg) => WRITE_RE.test(arg))) return true;
    }
  }
  // Process substitutions run too, as does an unquoted <<<$(...) the lexer
  // splits off its command; text fed to a shell or source is executed.
  const feedsShell = parsed.some((words) => {
    const exe = basename(commandShape(words).executable);
    return SHELLS.has(exe) || exe === 'source' || exe === '.';
  });
  const substitutions = [...script.matchAll(/(?:[<>]|<<<\s*\$)\(([^()]*)\)/g)];
  // [^()]* cannot span nested parentheses, so an opener it left unmatched
  // fails closed, as the per-word $(...) scan below does.
  if ((script.match(/(?:[<>]|<<<\s*\$)\(/g) || []).length > substitutions.length && WRITE_RE.test(script)) return true;
  // A shell in >(...) reads the command's output, here-string data included;
  // one in <(...) reads the stdin the command inherits, such as a pipe. Any
  // word on the line may be that input, so each gets a shell's script checks.
  let fed;
  const feedsWrite = () => (fed ??= WRITE_RE.test(script) || parsed.some((words) => words.some((word) =>
    classify(word.value, depth + 1, aliases) || quotedWrite(word))));
  for (const match of substitutions) {
    if (/^[<>]\(/.test(match[0]) && runsShell(match[1]) && feedsWrite()) return true;
    if (!SIGNAL.test(match[1])) continue;
    if (classify(match[1], depth + 1, aliases) || (feedsShell && WRITE_RE.test(match[1]))) return true;
  }
  // A split here-string also gets the quoted-text check a shell's own words get.
  for (const word of splitHereStrings(script)) {
    if (classify(word.value, depth + 1, aliases) || quotedWrite(word)) return true;
  }
  for (const words of parsed) {
    const shape = commandShape(words);
    const executable = basename(shape.executable);

    // Substitutions run even inside a data command's arguments.
    for (const word of words) {
      if (word.singleOnly || !SIGNAL.test(word.value)) continue;
      const substitutions = [...word.value.matchAll(/\$\(([^()]*)\)/g)];
      if ((word.value.match(/\$\(/g) || []).length > substitutions.length && WRITE_RE.test(word.value)) return true;
      for (const match of substitutions) if (classify(match[1], depth + 1, aliases)) return true;
    }
    const executableText = words.filter((word) => !word.singleOnly).map((word) => word.value).join(' ');
    for (const match of executableText.matchAll(/`([^`]*)`/g)) {
      if (SIGNAL.test(match[1]) && classify(match[1], depth + 1, aliases)) return true;
    }
    if (DATA.has(executable)) continue;

    const extra = aliases.get(aliasVar(shape.executable) ?? executable);
    if (extra) {
      if (writeVerb([...extra, ...shape.args])) return true;
      continue;
    }
    const args = cliArgs(shape);
    if (args !== null) {
      if (writeVerb(args)) return true;
      continue;
    }

    // Heredoc bodies stay visible in parsed; here-strings are a single word
    // removed from args, so classify their stdin script recursively instead.
    const stdinScript = stdinHereString(shape);
    if (stdinScript && classify(stdinScript, depth + 1, aliases)) return true;
    const nested = shellPayload(shape);
    if (nested && classify(nested, depth + 1, aliases)) return true;
    // eval runs its joined arguments as a script, so a held string executes.
    if (executable === 'eval' && classify(shape.args.join(' '), depth + 1, aliases)) return true;
    if (EXEC_HELPER(shape, executable) && shape.words.some(quotedWrite)) return true;
    // Opaque wrappers and execution helpers: a named CLI word followed by a
    // write-verb word, or by api without a literal GET method (xargs may supply
    // it), is a write. Merely mentioning the CLI is not.
    if (INSPECT.has(executable)) continue;
    const at = shape.words.findIndex((word) => !assignment(word) && named(word.value));
    if (at === -1) continue;
    const rest = shape.words.slice(at + 1).map((word) => word.value);
    if (rest.some((value) => WRITES.has(value))) return true;
    if (rest.includes('api') && apiWrites(rest.slice(rest.indexOf('api') + 1))) return true;
  }
  return false;
}

function evaluate(event) {
  if (event.tool_name && event.tool_name !== 'Bash') return null;
  const command = event.tool_input?.command;
  if (typeof command !== 'string') return null;
  let writes;
  try { writes = classify(command); } catch { writes = WRITE_RE.test(command); }
  if (!writes) return null;
  return ask(
    'This Discord CLI call writes to Discord (a message send, edit, or delete, or a non-GET api call), or its verb or method cannot be read statically. ' +
    'Human approval is required for the exact Bash command even with --confirm-write and bypassPermissions.'
  );
}

function run(rawInput) {
  try { return evaluate(JSON.parse(rawInput)) || rawInput; } catch { return rawInput; }
}

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { if (data.length < 1024 * 1024) data += chunk; });
  process.stdin.on('end', () => { writeHookOutput(run(data), data); process.exit(0); });
}
module.exports = { classify, evaluate, run, WRITES };

