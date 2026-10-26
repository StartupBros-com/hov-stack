#!/usr/bin/env node
'use strict';

const path = require('node:path');
const { deny, setDenyContext } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');
const { executedPieces, NestingTooDeep, MAX_NESTING } = require('../lib/heredoc-scan');

const HEADROOM_SCRIPT = path.resolve(__dirname, '..', '..', 'scripts', 'heavy-job-headroom.js');
const HEAVY_SCRIPTS = new Set(['build', 'typecheck', 'compile']);
const SHELLS = new Set(['bash', 'sh', 'dash', 'zsh', 'ksh']);
const PREFIX_WORDS = new Set(['!', '{', 'do', 'then', 'else', 'elif', 'if', 'while', 'until']);
const EMPTY_OPTION_SPEC = { shortWithValue: new Set(), longWithValue: new Set() };
const WRAPPER_OPTIONS = {
  exec: { shortWithValue: new Set(['a']), longWithValue: new Set() },
  env: {
    shortWithValue: new Set(['C', 'S', 'u']),
    longWithValue: new Set(['--chdir', '--split-string', '--unset']),
  },
  sudo: {
    shortWithValue: new Set(['C', 'D', 'g', 'h', 'p', 'R', 'r', 'T', 't', 'u']),
    longWithValue: new Set(['--close-from', '--chdir', '--group', '--host', '--prompt', '--chroot', '--role', '--command-timeout', '--type', '--user']),
  },
  nice: { shortWithValue: new Set(['n']), longWithValue: new Set(['--adjustment']) },
  time: { shortWithValue: new Set(['f', 'o']), longWithValue: new Set(['--format', '--output']) },
  timeout: { shortWithValue: new Set(['k', 's']), longWithValue: new Set(['--kill-after', '--signal']) },
  packageManager: {
    shortWithValue: new Set(['C', 'F']),
    longWithValue: new Set(['--cwd', '--dir', '--filter', '--prefix', '--workspace', '--workspace-concurrency']),
  },
  packageExec: {
    shortWithValue: new Set(['p']),
    longWithValue: new Set(['--package', '--call']),
  },
};

function basename(token) {
  return path.posix.basename(token.replace(/\\/g, '/'));
}

function isAssignment(token) {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(token);
}

function isHeavyScript(token) {
  if (typeof token !== 'string') return false;
  if (HEAVY_SCRIPTS.has(token)) return true;
  return [...HEAVY_SCRIPTS].some((prefix) => token.startsWith(`${prefix}:`));
}

const { shellTokens, isSubstitution, shellCommandIndex, findActionRanges } = require('../lib/shell-words');

const REDIRECTIONS = new Set(['<', '>', '<<', '>>', '<&', '>&', '&>']);

function skipCommandPreamble(tokens, start, state) {
  if (tokens.argvOnly) return start;
  let i = start;
  while (i < tokens.length) {
    if (typeof tokens[i] === 'string' && isAssignment(tokens[i])) {
      noteTurboAssignment(tokens[i], state);
      i += 1;
      continue;
    }
    if (PREFIX_WORDS.has(tokens[i])) {
      i += 1;
      continue;
    }
    if (/^[0-9]+$/.test(tokens[i]) && REDIRECTIONS.has(tokens[i + 1])) i += 1;
    if (REDIRECTIONS.has(tokens[i])) {
      i += Math.min(2, tokens.length - i);
      continue;
    }
    break;
  }
  return i;
}

function commandGroups(tokens) {
  return parseCommandGroups(tokens).groups;
}

function parseCommandGroups(tokens, start = 0) {
  const groups = [];
  let job = [];
  let segments = [];
  const newSegment = () => Object.assign([], { meta: [] });
  let segment = newSegment();
  const flushSegment = () => {
    if (segment.length) segments.push(segment);
    segment = newSegment();
  };
  const flushPipeline = () => {
    flushSegment();
    if (segments.length) job.push({ segments, background: false });
    segments = [];
  };
  const flushJob = (background = false) => {
    flushPipeline();
    for (const group of job) groups.push({ ...group, background: group.background || background });
    job = [];
  };

  for (let i = start; i < tokens.length; i += 1) {
    const token = tokens[i];
    const op = tokens.ops?.[i] !== false;
    if (op && token === '|') flushSegment();
    else if (op && token === '&') flushJob(true);
    else if (op && ['||', '&&', ';', '\n'].includes(token)) flushJob(false);
    else if (op && token === '(') {
      flushPipeline();
      const nested = parseCommandGroups(tokens, i + 1);
      job.push(...nested.groups);
      i = nested.index;
    } else if (op && token === ')') {
      flushJob(false);
      return { groups, index: i };
    } else {
      segment.push(token);
      segment.meta.push(tokens.meta?.[i]);
    }
  }
  flushJob(false);
  return { groups, index: tokens.length };
}

function skipOptions(tokens, start, spec = EMPTY_OPTION_SPEC) {
  let i = start;
  while (i < tokens.length && tokens[i].startsWith('-') && tokens[i] !== '-') {
    if (tokens[i] === '--') return i + 1;
    const token = tokens[i];
    if (token.startsWith('--')) {
      const equals = token.indexOf('=');
      const name = equals >= 0 ? token.slice(0, equals) : token;
      i += 1;
      if (equals < 0 && spec.longWithValue.has(name) && i < tokens.length) i += 1;
      continue;
    }
    let consumesNext = false;
    for (let j = 1; j < token.length; j += 1) {
      if (!spec.shortWithValue.has(token[j])) continue;
      consumesNext = j === token.length - 1;
      break;
    }
    i += 1;
    if (consumesNext && i < tokens.length) i += 1;
  }
  return i;
}

// Keep the full originating argv word when classifying through exec wrappers.
function sliceWords(tokens, start) {
  const words = tokens.slice(start);
  words.payloads = tokens.payloads?.slice(start);
  words.wordInfo = tokens.wordInfo?.slice(start);
  words.argvWords = tokens.wordInfo?.[start]
    ? tokens.argvWords?.slice(tokens.argvWords.indexOf(tokens.wordInfo[start])) : [];
  words.argvOnly = tokens.argvOnly;
  return words;
}

function packageManagerHeavy(name, tokens, start, depth, state) {
  let i = start;
  if (name === 'bunx' || name === 'npx') {
    i = skipOptions(tokens, i, WRAPPER_OPTIONS.packageExec);
    return inspectSegment(sliceWords(tokens, i), depth + 1, state);
  }
  if (name === 'bun' && tokens[i] === 'x') return inspectSegment(sliceWords(tokens, i + 1), depth + 1, state);

  i = skipOptions(tokens, i, WRAPPER_OPTIONS.packageManager);
  const subcommand = tokens[i];
  if (subcommand === 'exec' || subcommand === 'dlx' || (name === 'bun' && subcommand === 'x')) {
    const commandIndex = skipOptions(tokens, i + 1, WRAPPER_OPTIONS.packageExec);
    return inspectSegment(sliceWords(tokens, commandIndex), depth + 1, state);
  }
  if (subcommand === 'run') {
    const scriptIndex = skipOptions(tokens, i + 1, WRAPPER_OPTIONS.packageManager);
    return isHeavyScript(tokens[scriptIndex]);
  }
  return isHeavyScript(subcommand);
}

function shellPayload(tokens, start) {
  const i = shellCommandIndex(tokens, start);
  return i < 0 ? null : tokens.payloads?.[i] ?? tokens[i];
}

function noteTurboAssignment(token, state) {
  const prefix = 'TURBO_CONCURRENCY=';
  if (token.startsWith(prefix) && token.slice(prefix.length) !== '1') state.unsafeConcurrency = true;
}

function turboHeavy(tokens, start, state) {
  const heavy = tokens.slice(start).some(isHeavyScript);
  if (!heavy) return false;
  for (let i = start; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token === '--parallel' || token === '--concurrency' || token.startsWith('--concurrency=')) {
      state.unsafeConcurrency = true;
    }
  }
  return true;
}

function inspectSegment(
  tokens,
  depth = 0,
  state = { background: false, unsafeConcurrency: false, dynamicEval: false },
) {
  if (depth > 8) return false;
  let substitutionHeavy = false;
  let hadSubstitution = false;
  const words = [];
  words.payloads = [];
  words.wordInfo = [];
  words.argvWords = tokens.argvWords || [];
  words.argvOnly = tokens.argvOnly;
  for (let at = 0; at < tokens.length; at += 1) {
    const token = tokens[at];
    if (!isSubstitution(token)) {
      const info = tokens.meta?.[at];
      const wordInfo = tokens.wordInfo?.[at] || { value: tokens.payloads?.[at] ?? token, meta: info };
      if (!tokens.argvWords) words.argvWords.push(wordInfo);
      // Match known static fragments without pretending the unknown output
      // glues them together. An unquoted substitution-only field can elide;
      // a quoted empty word still occupies argv[0]. The full -c word remains
      // available to shellPayload, with already-scanned interiors removed.
      const fragments = info?.fragments?.filter((part) => part !== '') || [token];
      if (!fragments.length && info?.quoted) fragments.push('');
      for (const fragment of fragments) {
        words.push(fragment);
        words.payloads.push(tokens.payloads?.[at] ?? token);
        words.wordInfo.push(wordInfo);
      }
      continue;
    }
    hadSubstitution = true;
    // The scan in analyzeCommand already took this payload's bodies out.
    const nested = analyzeText(token.payload, depth + 1);
    state.dynamicEval ||= nested.dynamicEval;
    if (!nested.heavy) continue;
    substitutionHeavy = true;
    state.background ||= nested.background;
    state.unsafeConcurrency ||= nested.unsafeConcurrency;
  }
  tokens = words;
  let i = skipCommandPreamble(tokens, 0, state);

  while (i < tokens.length) {
    const name = basename(tokens[i]);
    if (['command', 'builtin', 'nohup'].includes(name)) {
      i = skipOptions(tokens, i + 1, EMPTY_OPTION_SPEC);
      i = skipCommandPreamble(tokens, i, state);
      continue;
    }
    if (name === 'exec') {
      i = skipOptions(tokens, i + 1, WRAPPER_OPTIONS.exec);
      i = skipCommandPreamble(tokens, i, state);
      continue;
    }
    if (name === 'env') {
      i = skipOptions(tokens, i + 1, WRAPPER_OPTIONS.env);
      while (i < tokens.length && isAssignment(tokens[i])) {
        noteTurboAssignment(tokens[i], state);
        i += 1;
      }
      i = skipCommandPreamble(tokens, i, state);
      continue;
    }
    if (name === 'sudo' || name === 'nice' || name === 'time') {
      i = skipOptions(tokens, i + 1, WRAPPER_OPTIONS[name]);
      i = skipCommandPreamble(tokens, i, state);
      continue;
    }
    if (name === 'timeout') {
      i = skipOptions(tokens, i + 1, WRAPPER_OPTIONS.timeout);
      if (i < tokens.length) i += 1;
      i = skipCommandPreamble(tokens, i, state);
      continue;
    }
    if (name === 'eval') {
      const payloadTokens = tokens.slice(i + 1);
      if (hadSubstitution || payloadTokens.some((token) => token.includes('$') || token.includes('`'))) {
        state.dynamicEval = true;
        return substitutionHeavy;
      }
      const payload = payloadTokens.join(' ');
      if (!payload) return substitutionHeavy;
      const nested = analyzeCommand(payload, depth + 1);
      state.background ||= nested.heavy && nested.background;
      state.unsafeConcurrency ||= nested.heavy && nested.unsafeConcurrency;
      state.dynamicEval ||= nested.dynamicEval;
      return nested.heavy || substitutionHeavy;
    }
    if (name === 'find') {
      // Static fragments are useful for command classification, but find's
      // expression grammar must consume whole originating argv words.
      const argv = tokens.argvWords.slice(tokens.argvWords.indexOf(tokens.wordInfo[i]));
      const inherited = { ...state };
      let heavy = substitutionHeavy;
      for (const { start, end } of findActionRanges(argv.map((word) => word.value))) {
        const action = argv.slice(start, end);
        const child = action.map((word) => word.value);
        child.meta = action.map((word) => word.meta);
        child.argvOnly = true;
        const childState = { ...inherited };
        const childHeavy = inspectSegment(child, depth + 1, childState);
        state.dynamicEval ||= childState.dynamicEval;
        if (childHeavy) {
          heavy = true;
          state.background ||= childState.background;
          state.unsafeConcurrency ||= childState.unsafeConcurrency;
        }
      }
      return heavy;
    }
    if (name === 'tsc' || name === 'velite') return true;
    if (name === 'next') return tokens[i + 1] === 'build' || substitutionHeavy;
    if (name === 'astro') return tokens[i + 1] === 'build' || tokens[i + 1] === 'check' || substitutionHeavy;
    if (name === 'turbo') return turboHeavy(tokens, i + 1, state) || substitutionHeavy;
    if (['pnpm', 'bun', 'bunx', 'npx', 'npm', 'yarn', 'yarnpkg'].includes(name)) {
      return packageManagerHeavy(name, tokens, i + 1, depth, state) || substitutionHeavy;
    }
    if (SHELLS.has(name)) {
      const payload = shellPayload(tokens, i + 1);
      if (!payload) return substitutionHeavy;
      const nested = analyzeCommand(payload, depth + 1);
      state.background ||= nested.heavy && nested.background;
      state.unsafeConcurrency ||= nested.heavy && nested.unsafeConcurrency;
      state.dynamicEval ||= nested.dynamicEval;
      return nested.heavy || substitutionHeavy;
    }
    return substitutionHeavy;
  }
  return substitutionHeavy;
}

// A command's shell text arrives here as the pieces of executedPieces (#1853):
// here-document bodies and comments are taken out, a body that runs comes
// back as a piece of its own, and each piece is lexed alone, because a
// runnable body may hold an unbalanced quote. A `bash -c` or static `eval`
// payload is fresh text and comes back through here; a substitution's payload
// was part of the scanned text and goes straight to analyzeText, since a
// second scan would read its kept `<<EOF` opener as unterminated and swallow
// what follows.
function analyzeCommand(command, depth = 0) {
  const shape = { heavy: false, background: false, unsafeConcurrency: false, dynamicEval: false };
  for (const piece of executedPieces(command)) {
    const pieceShape = analyzeText(piece.text, depth);
    for (const key of Object.keys(shape)) shape[key] ||= pieceShape[key];
  }
  return shape;
}

function analyzeText(command, depth) {
  const groups = commandGroups(shellTokens(command, { preserveWords: true }));
  let heavy = false;
  let background = false;
  let unsafeConcurrency = false;
  let dynamicEval = false;
  for (const group of groups) {
    let groupHeavy = false;
    let groupNestedBackground = false;
    let groupUnsafeConcurrency = false;
    for (const segment of group.segments) {
      const state = { background: false, unsafeConcurrency: false, dynamicEval: false };
      const segmentHeavy = inspectSegment(segment, depth, state);
      dynamicEval ||= state.dynamicEval;
      if (!segmentHeavy) continue;
      groupHeavy = true;
      groupNestedBackground ||= state.background;
      groupUnsafeConcurrency ||= state.unsafeConcurrency;
    }
    heavy ||= groupHeavy;
    background ||= (groupHeavy && group.background) || groupNestedBackground;
    unsafeConcurrency ||= groupHeavy && groupUnsafeConcurrency;
  }
  return { heavy, background, unsafeConcurrency, dynamicEval };
}

function shellQuote(value) {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

// The admission wrapper lives in a FILE (hooks/lib/heavy-job-admission-run.sh),
// invoked by absolute path with the original command as one quoted argument.
// It used to be inlined into the rewritten command, and its six `$( )` tool
// resolutions made Claude Code's worktree-isolation verifier refuse every
// command this gate admitted in an isolated session (dotfiles #864: 312
// refusals in one day, 27 deep in one session, each naming the wrapper's own
// substitutions). A script run by absolute path is never parsed internally,
// and a package-manager operand as a quoted argument passes -- both measured
// live 2026-09-02 -- so the rewritten text now carries nothing the verifier
// objects to while the file keeps every runtime check verbatim.
const SUPERVISOR_SCRIPT = path.resolve(__dirname, '..', 'lib', 'heavy-job-admission-run.sh');

function admissionCommand(command) {
  return `bash ${shellQuote(SUPERVISOR_SCRIPT)} ${shellQuote(process.execPath)} ${shellQuote(HEADROOM_SCRIPT)} ${shellQuote(command)}`;
}

function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    if (input.tool_name !== 'Bash') return rawInput;
    const command = input.tool_input?.command;
    if (typeof command !== 'string') return rawInput;

    setDenyContext({
      guard: 'heavy-job-admission',
      cwd: input.cwd,
      sessionId: input.session_id,
      agentId: input.agent_id,
      tool: input.tool_name,
      command,
    });

    const shape = analyzeCommand(command);
    if (shape.dynamicEval) {
      return deny('Blocked: dynamic eval can hide a heavy build or typecheck from admission. Replace eval with a static command or invoke the command directly.');
    }
    if (!shape.heavy) return rawInput;
    if (shape.unsafeConcurrency) {
      return deny('Blocked: heavy jobs must keep TURBO_CONCURRENCY=1; remove inline TURBO_CONCURRENCY overrides and Turbo --parallel/--concurrency flags, then retry.');
    }
    if (shape.background) {
      return deny('Blocked: heavy build and typecheck commands must run in the foreground so global admission remains effective. Retry without backgrounding or deferral.');
    }
    return JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        updatedInput: { command: admissionCommand(command) },
      },
    });
  } catch (err) {
    // Padding a command with nesting must not skip admission (#1853).
    if (err instanceof NestingTooDeep) {
      return deny(`Blocked: this command's quotes and substitutions nest more than ${MAX_NESTING} levels deep, too deep for heavy-job admission to check it for a heavy build or typecheck. Assign inner substitutions to variables first, then retry.`);
    }
    return rawInput;
  }
}

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    if (data.length < 1024 * 1024) data += chunk;
  });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}

module.exports = { analyzeCommand, run, shellTokens };
