'use strict';

// Shared small lexer; input is one executedPieces text, with bodies removed.
// Legacy mode retains the public heavy/shape tokenizer contract.
// preserveWords adds parallel ops/meta arrays. A word's meta records lexical
// assignment/quoting and its static fragments, separated by live substitutions.
// The string keeps a $() marker for each already-scanned substitution so a
// fresh -c payload retains its full word without rescanning removed heredocs.
function readBacktick(command, start) {
  for (let i = start; i < command.length; i += 1) {
    if (command[i] === '\\' && i + 1 < command.length) {
      i += 1;
      continue;
    }
    if (command[i] === '`') return { payload: command.slice(start, i), end: i };
  }
  return null;
}

function readDollarParen(command, start) {
  let depth = 1;
  let quote = null;
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
        const nested = readDollarParen(command, i + 2);
        if (nested) i = nested.end;
      } else if (ch === '`') {
        const nested = readBacktick(command, i + 1);
        if (nested) i = nested.end;
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
      const nested = readBacktick(command, i + 1);
      if (nested) i = nested.end;
      continue;
    }
    if (ch === '$' && command[i + 1] === '(') {
      const nested = readDollarParen(command, i + 2);
      if (nested) i = nested.end;
      continue;
    }
    if (ch === '(') depth += 1;
    else if (ch === ')' && --depth === 0) return { payload: command.slice(start, i), end: i };
  }
  return null;
}

function substitution(payload) {
  return { type: 'command-substitution', payload };
}

function isSubstitution(token) {
  return token && typeof token === 'object' && token.type === 'command-substitution';
}

function shellTokens(command, { preserveWords = false } = {}) {
  const tokens = [];
  let current = '';
  let quote = null;
  let started = false;
  let embedded = [];
  let wordStart = -1;
  let quoted = false;
  let fragments = [''];
  const ops = [];
  const meta = [];
  const begin = (at) => {
    if (wordStart < 0) wordStart = at;
  };
  const append = (text) => {
    current += text;
    fragments[fragments.length - 1] += text;
  };
  const push = (token, op = false, info = { op }) => {
    tokens.push(token);
    ops.push(op);
    meta.push(info);
  };
  const addSubstitution = (nested) => {
    if (!preserveWords) {
      flush();
      push(substitution(nested.payload));
      return;
    }
    embedded.push(substitution(nested.payload));
    // Output is unknown. Keep its place in the argv word, but never rescan
    // the already-scanned heredoc opener in a fresh shell payload.
    current += '$()';
    fragments.push('');
    started = true;
  };
  const flush = () => {
    if (started)
      push(current, false, {
        op: false,
        quoted,
        fragments,
        assignment: /^[A-Za-z_][A-Za-z0-9_]*=/.test(command.slice(wordStart)),
      });
    for (const token of embedded) push(token);
    embedded = [];
    current = '';
    started = false;
    wordStart = -1;
    quoted = false;
    fragments = [''];
  };

  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    if (quote === "'") {
      if (ch === "'") quote = null;
      else append(ch);
      continue;
    }
    if (quote === '"') {
      if (ch === '"') quote = null;
      else if (ch === '\\' && i + 1 < command.length && '"$`\\\n'.includes(command[i + 1])) {
        i += 1;
        if (command[i] !== '\n') append(command[i]);
      } else if (ch === '$' && command[i + 1] === '(') {
        const nested = readDollarParen(command, i + 2);
        if (nested) {
          addSubstitution(nested);
          i = nested.end;
        } else append(ch);
      } else if (ch === '`') {
        const nested = readBacktick(command, i + 1);
        if (nested) {
          addSubstitution(nested);
          i = nested.end;
        } else append(ch);
      } else append(ch);
      continue;
    }
    if (ch === '$' && command[i + 1] === '(') {
      const nested = readDollarParen(command, i + 2);
      if (nested) {
        begin(i);
        addSubstitution(nested);
        i = nested.end;
        continue;
      }
    }
    if (ch === '`') {
      const nested = readBacktick(command, i + 1);
      if (nested) {
        begin(i);
        addSubstitution(nested);
        i = nested.end;
        continue;
      }
    }
    if (ch === "'" || ch === '"') {
      begin(i);
      quoted = true;
      quote = ch;
      started = true;
      continue;
    }
    if (ch === '\\' && i + 1 < command.length) {
      if (command[i + 1] === '\n') {
        i += 1;
        continue;
      }
      begin(i);
      quoted = true;
      i += 1;
      if (command[i] !== '\n') {
        append(command[i]);
        started = true;
      }
      continue;
    }
    if (ch === '#' && !started && !preserveWords) {
      while (i + 1 < command.length && command[i + 1] !== '\n') i += 1;
      continue;
    }
    if (/\s/.test(ch)) {
      flush();
      if (ch === '\n') push('\n', true);
      continue;
    }
    if (ch === '<' || ch === '>') {
      flush();
      let redirection = ch;
      if (command[i + 1] === ch) redirection += command[++i];
      if (command[i + 1] === '&') redirection += command[++i];
      push(redirection, true);
      continue;
    }
    if (ch === '&' && command[i + 1] === '>') {
      flush();
      push('&>', true);
      i += 1;
      continue;
    }
    if ('|;&()'.includes(ch)) {
      flush();
      if ((ch === '|' || ch === '&') && command[i + 1] === ch) {
        push(ch + command[++i], true);
      } else push(ch, true);
      continue;
    }
    begin(i);
    append(ch);
    started = true;
  }
  flush();
  if (preserveWords) {
    tokens.ops = ops;
    tokens.meta = meta;
  }
  return tokens;
}

const SHELL_OPTIONS_WITH_VALUE = new Set(['-o', '+o', '-O', '+O', '--rcfile', '--init-file']);

function shellCommandIndex(argv, start = 1) {
  let command = false;
  for (let i = start; i < argv.length; i++) {
    const token = argv[i];
    if (token === '--') return command && i + 1 < argv.length ? i + 1 : -1;
    const option = token.startsWith('--') ? token.split('=', 1)[0] : token;
    if (SHELL_OPTIONS_WITH_VALUE.has(option)) {
      if (token === option) i++;
    } else if (/^-[A-Za-z]*c[A-Za-z]*$/.test(token)) {
      command = true;
    } else if (!token.startsWith('-') && !token.startsWith('+')) {
      return command ? i : -1;
    }
  }
  return -1;
}

// find parses an expression, then passes each action's operands directly as
// argv. Skip predicate values so a literal "-exec" cannot start an action.
const FIND_VALUE_OPTIONS = new Set([
  '-D', '-f', '-files0-from', '-maxdepth', '-mindepth', '-regextype',
  '-amin', '-anewer', '-atime', '-cmin', '-cnewer', '-context', '-ctime', '-fstype', '-gid', '-group',
  '-ilname', '-iname', '-inum', '-ipath', '-iregex', '-iwholename', '-links',
  '-lname', '-mmin', '-mtime', '-name', '-newer', '-path', '-perm', '-regex',
  '-samefile', '-since', '-size', '-type', '-uid', '-used', '-user', '-wholename',
  '-xtype', '-fls', '-fprint', '-fprint0', '-printf',
]);
const FIND_EXEC_ACTIONS = new Set(['-exec', '-execdir', '-ok', '-okdir']);

function findActionRanges(argv, start = 1) {
  const actions = [];
  for (let i = start; i < argv.length; i++) {
    const action = argv[i];
    if (FIND_VALUE_OPTIONS.has(action) || /^-newer[acmBt][acmBt]$/.test(action)) {
      i++;
    } else if (action === '-fprintf') {
      i += 2;
    } else if (FIND_EXEC_ACTIONS.has(action)) {
      const first = i + 1;
      const batch = action === '-exec' || action === '-execdir';
      for (i = first; i < argv.length; i++) {
        if (argv[i] === ';' || (batch && argv[i] === '+' && argv[i - 1] === '{}')) {
          if (i > first) actions.push({ start: first, end: i, chdir: action.endsWith('dir') });
          break;
        }
      }
    }
  }
  return actions;
}

module.exports = { shellTokens, isSubstitution, shellCommandIndex, findActionRanges };
