/**
 * Resend send/write/destructive ask floor, called by the already-registered
 * WhatsApp guard. Asks only when a command executes resend-cli / resend_cli.py
 * (directly, through python -m resend_cli, a wrapper, a shell, or eval of a
 * held string) with a command path whose tier is send, write or destructive,
 * or a path that cannot be read statically. Never denies; every other command
 * passes through. The decision is keyed on the command path (`emails send`,
 * `broadcasts delete`), never on the --confirm-* flag: the wrapper only checks
 * that the expanded flag is present, and a flag held in a variable, quoted,
 * escaped or spelled inside a `bash -c` string matches no settings.json text
 * rule, so the ask holds under bypassPermissions (pro-gate round 1 on
 * dotfiles#1742). The structural reading below is backed by a text rule that
 * asks whenever the literal CLI name is followed anywhere by a send, write or
 * destructive path, so a bash comment or $'...' escape with an apostrophe, a
 * heredoc body with a quote, brace expansion in the name position, a wrapper
 * between a pipe and a shell or a printf-built command line cannot hide a
 * spelled-out write from it. A CLI name that never appears literally (r=resend;
 * ${r}-cli, a glob such as resend-c* or resend_c*.py, a module name held in a
 * variable), renamed copies, python -c, shells outside SHELLS, exec -a, script
 * files read from stdin and the vendor binary run outside the wrapper remain
 * outside any text classifier; the wrapper is the only place that can see them.
 */
'use strict';

const path = require('node:path');
const {
  segments, commandShape, shellPayload, lex,
} = require('./whatsapp-guard');
const { ask } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

// Keep equal to COMMANDS and ALIASES in bin/resend_cli.py (cross-checked
// by the test): every leaf of the pinned vendor, classified exactly once.
const TIERS = {
  'login': 'refused',
  'emails list': 'read', 'emails send': 'send', 'emails get': 'read', 'emails batch': 'send',
  'emails cancel': 'write', 'emails update': 'write', 'emails share': 'write',
  'emails metrics': 'read', 'emails attachments': 'read', 'emails attachment': 'read',
  'emails receiving list': 'read', 'emails receiving get': 'read',
  'emails receiving listen': 'refused', 'emails receiving attachments': 'read',
  'emails receiving attachment': 'read', 'emails receiving forward': 'send',
  'broadcasts create': 'write', 'broadcasts open': 'refused', 'broadcasts send': 'send',
  'broadcasts get': 'read', 'broadcasts list': 'read', 'broadcasts recipients': 'read',
  'broadcasts update': 'write', 'broadcasts cancel': 'write', 'broadcasts duplicate': 'write',
  'broadcasts delete': 'destructive', 'broadcasts clicked-links': 'read',
  'automations create': 'write', 'automations get': 'read', 'automations list': 'read',
  'automations update': 'write', 'automations delete': 'destructive',
  'automations duplicate': 'write', 'automations stop': 'write', 'automations open': 'refused',
  'automations runs list': 'read', 'automations runs get': 'read',
  'events create': 'write', 'events get': 'read', 'events list': 'read', 'events update': 'write',
  'events delete': 'destructive', 'events open': 'refused', 'events send': 'send',
  'templates create': 'write', 'templates get': 'read', 'templates open': 'refused',
  'templates list': 'read', 'templates update': 'write', 'templates delete': 'destructive',
  'templates publish': 'write', 'templates duplicate': 'write',
  'contacts create': 'write', 'contacts get': 'read', 'contacts list': 'read',
  'contacts update': 'write', 'contacts delete': 'destructive', 'contacts segments': 'read',
  'contacts add-segment': 'write', 'contacts remove-segment': 'write', 'contacts topics': 'read',
  'contacts update-topics': 'write', 'contacts imports create': 'write',
  'contacts imports get': 'read', 'contacts imports list': 'read',
  'contact-properties create': 'write', 'contact-properties get': 'read',
  'contact-properties list': 'read', 'contact-properties update': 'write',
  'contact-properties delete': 'destructive',
  'segments contacts': 'read', 'segments create': 'write', 'segments get': 'read',
  'segments list': 'read', 'segments update': 'write', 'segments delete': 'destructive',
  'topics create': 'write', 'topics get': 'read', 'topics list': 'read', 'topics update': 'write',
  'topics delete': 'destructive',
  'domains create': 'write', 'domains verify': 'write', 'domains get': 'read', 'domains list': 'read',
  'domains update': 'write', 'domains delete': 'destructive', 'domains claim create': 'write',
  'domains claim get': 'read', 'domains claim verify': 'write',
  'logs get': 'read', 'logs list': 'read', 'logs open': 'refused',
  'usage': 'read',
  'careers apply': 'refused', 'careers list': 'refused',
  'suppressions list': 'read', 'suppressions add': 'write', 'suppressions get': 'read',
  'suppressions delete': 'destructive', 'suppressions batch add': 'write',
  'suppressions batch remove': 'destructive',
  'api-keys create': 'destructive', 'api-keys list': 'read', 'api-keys update': 'destructive',
  'api-keys delete': 'destructive',
  'webhooks create': 'write', 'webhooks get': 'read', 'webhooks events list': 'read',
  'webhooks events get': 'read', 'webhooks events attempts': 'read',
  'webhooks events replay': 'write', 'webhooks listen': 'refused', 'webhooks list': 'read',
  'webhooks update': 'write', 'webhooks rotate-signing-secret': 'destructive',
  'webhooks delete': 'destructive',
  'oauth-grants list': 'read', 'oauth-grants revoke': 'destructive',
  'auth login': 'refused', 'auth logout': 'refused', 'auth list': 'refused', 'auth switch': 'refused',
  'auth rename': 'refused', 'auth remove': 'refused',
  'logout': 'refused', 'whoami': 'read', 'doctor': 'refused', 'open': 'refused', 'docs': 'refused',
  'update': 'refused', 'commands': 'metadata', 'completion': 'refused',
};
const ALIASES = { ls: ['list'], rm: ['delete', 'remove'] };
const ASK_TIERS = new Set(['send', 'write', 'destructive']);
const GROUPS = new Set(Object.keys(TIERS).flatMap((key) => {
  const tokens = key.split(' ');
  return tokens.slice(0, -1).map((_, depth) => tokens.slice(0, depth + 1).join(' '));
}));
// Flags the wrapper reads before the command path. -h/--help anywhere before
// -- turns the call into vendor help; --where/--version with any other
// argument is a usage error; neither runs a command.
const NO_EFFECT = new Set(['-h', '--help', '--where', '--version']);
// The wrapper's account selector, `--account NAME` or `--account=NAME`.
const ACCOUNT_FLAG = '--account';
const LEADING_FLAG_RE = /^(?:--confirm-\S+|--json|-q|--quiet)$/;

const DATA = new Set(['echo', 'printf', 'rg', 'grep', 'egrep', 'fgrep', 'cat']);
// Commands that only name a file and never execute it, so a file argument
// followed by a path-named operand is not a Resend write.
const INSPECT = new Set(['ls', 'head', 'tail', 'wc', 'mv', 'cp', 'rm', 'touch', 'tee', 'diff', 'vim', 'vi', 'nano', 'less', 'more', 'stat', 'file', 'chmod', 'ln']);
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash']);
const DECLARATIONS = new Set(['alias', 'export', 'readonly', 'declare', 'typeset']);
const SIGNAL = /\b(?:resend-cli|resend_cli)\b/;
const basename = (value) => path.posix.basename(value.replace(/\\/g, '/'));
const named = (value) => new Set(['resend-cli', 'resend_cli.py']).has(basename(value));

// Literal named CLI, optional leading wrapper flags, then a send, write or
// destructive path (an alias spelling counts) or an expansion in any path
// position. Covers text the lexer cannot attribute to one command.
const spell = (token) => {
  const spellings = [token, ...Object.keys(ALIASES).filter((alias) => ALIASES[alias].includes(token))];
  return spellings.length > 1 ? '(?:' + spellings.join('|') + ')' : token;
};
const joinPath = (key) => key.split(' ').map(spell).join(String.raw`\s+["']?`);
const WRITE_TAIL = String.raw`(?:\s+(?:--confirm-\S+|--json|-q|--quiet|--account(?:=\S*|\s+\S+)))*\s+["']?(?:`
  + [
    ...Object.keys(TIERS).filter((key) => ASK_TIERS.has(TIERS[key])).map((key) => joinPath(key) + String.raw`\b`),
    '[$`]',
    ...[...GROUPS].map((group) => joinPath(group) + String.raw`\s+["']?[$\`]`),
  ].join('|') + ')';
const WRITE_RE = new RegExp(String.raw`\b(?:resend-cli|resend_cli\.py)['"]?` + WRITE_TAIL);
// The lexer splits an unquoted brace expansion (`emails {send,list}`) into
// separate segments, so one after the named CLI is read from the raw text.
const BRACE_RE = /\b(?:resend-cli|resend_cli\.py)\b[^\n;&|]*\{[^}\n]*(?:,|\.\.)[^}\n]*\}/;

// Fail-closed text rule, read before the structural pass: from the first
// literal CLI name on, every send, write or destructive leaf asks unless
// shellWords() proves the wrapper runs no command for it. The shared lexer
// has no comment or $'...' handling and keeps heredoc bodies (#1748), so one
// apostrophe can swallow the real command into a quoted word; a wrapper
// between a pipe and a shell (setsid, xargs, a group) and a printf-built
// command line are not unwrapped either. The text is still there, and a
// mention that spells a write is asked on by design.
const NAME_RE = /\b(?:resend-cli|resend_cli)\b/;
const LEAF_RE = new RegExp(
  String.raw`(?<=^|[\s"'=(,{};|&])["']?(?:`
  + Object.keys(TIERS).filter((key) => ASK_TIERS.has(TIERS[key])).map(joinPath).join('|')
  + String.raw`)\b`, 'gm');
const CONFIRMS = new Set(['--confirm-send', '--confirm-write', '--confirm-destructive']);
const OPERATOR_RE = /;;&|;;|;&|&&|\|\||\|&|&>>|&>|<<<|<<-|<<|<>|<&|>>|>&|>\||[;&|()<>]/y;
const REDIRECTS = new Set(['<', '>', '>>', '<<', '<<-', '<<<', '<>', '<&', '>&', '>|', '&>', '&>>']);
// Only a substitution or expansion with nothing nested in it has an extent
// this reading is sure of; any other one stops it.
const BOUNDED_RE = /\$\([^()'"`$\\\n]*\)|\$\{[^{}'"`$\\\n]*\}|`[^`'"$\\\n]*`|[<>]\([^()'"`$\\\n]*\)/y;
const PARAMETER_RE = /\$(?:[A-Za-z_]\w*|[0-9@*#?$!-])/y;
const sticky = (re, text, at) => {
  re.lastIndex = at;
  return re.exec(text)?.[0];
};

// Bash splits words only at blanks, newlines and these operators: a carriage
// return, form feed or no-break space is part of the word. A process
// substitution is part of the word it touches: bash hands -h<(true) over as
// -h/dev/fd/63, never as -h (re-review of 1cc4f597, P1).
const META_RE = /[ \t\n;&|()<>]/;
const procSub = (text, i) => (text[i] === '<' || text[i] === '>') && text[i + 1] === '(';

// One word from `at`: its value when quoting and escapes alone decide it,
// null when an expansion, substitution, glob or brace may change or split it,
// and undefined when its extent is not certain (an unclosed quote, a nested
// substitution). Also: split, when bash may turn it into other words (an
// unquoted expansion, a brace or bracket, any $@ form); lits, the characters
// every result keeps; tail, those after the last unknown part.
function readWord(text, at) {
  let i = at;
  let value = '';
  let known = true;
  let split = false;
  let lits = '';
  let tail = '';
  const literal = (chars) => {
    value += chars;
    lits += chars;
    tail += chars;
  };
  const unknown = () => {
    known = false;
    tail = '';
  };
  // $name, $1 or a bounded substitution leaves the value unknown; a nested
  // one has no certain extent; any other $ is text.
  const expansion = (quoted) => {
    const bounded = sticky(BOUNDED_RE, text, i) || sticky(PARAMETER_RE, text, i);
    if (bounded) {
      unknown();
      if (!quoted || /^\$\{?[!#]?@|^\$\{.*@/.test(bounded)) split = true;
      i += bounded.length;
      return true;
    }
    if (text[i] === '`' || /[({]/.test(text[i + 1] || '')) return false;
    literal('$');
    i += 1;
    return true;
  };
  while (i < text.length && (procSub(text, i) || !META_RE.test(text[i]))) {
    const c = text[i];
    if (procSub(text, i)) {
      const bounded = sticky(BOUNDED_RE, text, i);
      if (!bounded) return undefined;
      unknown();
      i += bounded.length;
    } else if (c === '\\') {
      if (i + 1 === text.length) return undefined;
      if (text[i + 1] !== '\n') literal(text[i + 1]);
      i += 2;
    } else if (c === "'") {
      const close = text.indexOf("'", i + 1);
      if (close === -1) return undefined;
      literal(text.slice(i + 1, close));
      i = close + 1;
    } else if (c === '$' && text[i + 1] === "'") {
      // An escape is not decoded here, so it leaves the value unknown.
      let close = i + 2;
      while (close < text.length && text[close] !== "'") close += text[close] === '\\' ? 2 : 1;
      if (close >= text.length) return undefined;
      if (text.slice(i + 2, close).includes('\\')) unknown();
      else literal(text.slice(i + 2, close));
      i = close + 1;
    } else if (c === '"' || (c === '$' && text[i + 1] === '"')) {
      i += c === '$' ? 2 : 1;
      for (;;) {
        if (i >= text.length) return undefined;
        const d = text[i];
        if (d === '"') break;
        if (d === '\\') {
          if (i + 1 === text.length) return undefined;
          const next = text[i + 1];
          if (!'$`"\\\n'.includes(next)) literal('\\');
          if (next !== '\n') literal(next);
          i += 2;
        } else if (d === '$' || d === '`') {
          if (!expansion(true)) return undefined;
        } else {
          literal(d);
          i += 1;
        }
      }
      i += 1;
    } else if (c === '$' || c === '`') {
      if (!expansion(false)) return undefined;
    } else if ('*?[{'.includes(c)) {
      // A glob matches names that keep its other characters; a brace or a
      // bracket set may yield any word.
      unknown();
      if (c === '[' || c === '{') split = true;
      value += c;
      i += 1;
    } else {
      literal(c);
      i += 1;
    }
  }
  return { value: known ? value : null, end: i, split, lits, tail };
}

// Whether bash may hand the wrapper a -- here, after which a flag is an operand.
const mayEndFlags = (word) => (word.value !== null ? word.value === '--' : word.split || !/[^-]/.test(word.lits));

// A conservative reading of the whole text as bash would split it, for the
// text rule's only exemption: words (value or null), redirections with their
// target (not argv), and 'end' for a command boundary or the first point it is
// not sure of, after which nothing is read. Comments and heredoc bodies are
// skipped, so the #1748 desync cannot move a word across a quote.
function shellWords(text) {
  const tokens = [];
  const heredocs = [];
  let i = 0;
  const stop = () => [...tokens, { type: 'end', start: i, end: text.length }];
  while (i < text.length) {
    const c = text[i];
    if (c === ' ' || c === '\t') {
      i += 1;
    } else if (c === '\\' && text[i + 1] === '\n') {
      i += 2; // a line continuation between words
    } else if (c === '\n') {
      tokens.push({ type: 'end', start: i, end: i + 1 });
      i += 1;
      for (const { delimiter, strip } of heredocs.splice(0)) {
        for (;;) {
          if (i >= text.length) return stop();
          const lineEnd = text.indexOf('\n', i) === -1 ? text.length : text.indexOf('\n', i);
          const line = text.slice(i, lineEnd);
          i = lineEnd + 1;
          if ((strip ? line.replace(/^\t+/, '') : line) === delimiter) break;
        }
      }
    } else if (c === '#') {
      const lineEnd = text.indexOf('\n', i);
      i = lineEnd === -1 ? text.length : lineEnd;
    } else if (!procSub(text, i) && sticky(OPERATOR_RE, text, i)) {
      const op = sticky(OPERATOR_RE, text, i);
      const start = i;
      i += op.length;
      if (!REDIRECTS.has(op)) {
        tokens.push({ type: 'end', start, end: i });
        continue;
      }
      // A glued fd (2>, {fd}>) belongs to the redirection, not argv.
      const last = tokens[tokens.length - 1];
      if (last?.type === 'word' && last.end === start && /^(?:\d+|\{[A-Za-z_]\w*\})$/.test(text.slice(last.start, start))) tokens.pop();
      while (text[i] === ' ' || text[i] === '\t') i += 1;
      const target = i < text.length && !META_RE.test(text[i]) ? readWord(text, i) : undefined;
      if (target === undefined || target.end === i) return stop();
      if (op === '<<' || op === '<<-') {
        if (target.value === null) return stop();
        heredocs.push({ delimiter: target.value, strip: op === '<<-' });
      }
      tokens.push({ type: 'redirect', start, end: target.end });
      i = target.end;
    } else {
      const word = readWord(text, i);
      if (word === undefined || word.end === i) return stop();
      tokens.push({ type: 'word', start: i, ...word });
      i = word.end;
    }
  }
  return tokens;
}

const SKIPPED_RE = /^(?:[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=.*|!|\{|if|then|elif|else|do|while|until|time)$/s;

// The words a simple command hands the wrapper, or null unless the CLI is the
// command itself (after assignments and reserved words), the script of bash or
// sh, or the script or -m module of a python cliArgs() accepts. A name whose
// directory is an expansion ("$HOME/.local/bin/resend-cli") still counts when
// nothing can split it. An argument of any other program (echo, printf,
// xargs, env) is not a call this reading can follow.
function wrapperArgv(text, words) {
  let index = 0;
  while (index < words.length && SKIPPED_RE.test(text.slice(words[index].start, words[index].end))) index += 1;
  const spelled = words.slice(index).map((word) => word.value ?? (word.split ? '\0' : '\0' + word.tail));
  if (!spelled.length) return null;
  if (['bash', 'sh'].includes(basename(spelled[0])) && named(spelled[1] || '')) return words.slice(index + 1);
  const args = cliArgs({ executable: spelled[0], args: spelled.slice(1) });
  return args === null ? null : words.slice(words.length - args.length - 1);
}

// Whether the wrapper provably runs no command for this simple command: its
// argv carries a plain (unquoted, unescaped) `help` as the first non-confirm
// word, or a plain -h/--help/--where/--version before any word that may be --.
// The wrapper reads these only as whole argv tokens before --, so `--text
// "see --help here"`, a comment, a redirection target, bash -c's $0 and a
// substitution's output never count. (Codex review on 0816d57b,
// dotfiles#1742 P1.)
function noEffect(text, words) {
  const call = wrapperArgv(text, words);
  if (!call) return false;
  const argv = call.slice(1);
  const plain = (word, values) => values.has(word.value) && text.slice(word.start, word.end) === word.value;
  const first = argv.find((word) => !CONFIRMS.has(word.value));
  if (first && plain(first, new Set(['help']))) return true;
  for (const word of argv) {
    if (mayEndFlags(word)) return false;
    if (plain(word, NO_EFFECT)) return true;
  }
  return false;
}

// The text a no-effect wrapper call covers: the name and argv words of each
// such simple command whose value is certain. A substitution, an expansion, a
// redirection, a comment and a heredoc body are never covered, so a leaf
// there asks even inside a help call (second Codex pass on 0816d57b).
function noEffectSpans(text) {
  const spans = [];
  let words = [];
  for (const token of shellWords(text)) {
    if (token.type === 'word') words.push(token);
    if (token.type !== 'end') continue;
    if (noEffect(text, words)) {
      for (const word of wrapperArgv(text, words)) if (word.value !== null) spans.push(word);
    }
    words = [];
  }
  if (words.length && noEffect(text, words)) {
    for (const word of wrapperArgv(text, words)) if (word.value !== null) spans.push(word);
  }
  return spans;
}

// Spans come in text order and never overlap, so the first one ending after
// `at` is the only one that can hold it; a linear scan per leaf made a long
// help call quadratic and could outlast the hook timeout.
function covered(spans, at) {
  let low = 0;
  let high = spans.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (spans[mid].end <= at) low = mid + 1;
    else high = mid;
  }
  return low < spans.length && spans[low].start <= at;
}

function literalWrite(text) {
  const at = text.search(NAME_RE);
  if (at === -1) return false;
  let spans;
  for (const match of text.slice(at).matchAll(LEAF_RE)) {
    spans ??= noEffectSpans(text);
    if (covered(spans, at + match.index)) continue; // argv of a no-effect call
    return true;
  }
  return false;
}

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
        return /(?:^|\.)resend_cli$/.test(operand || '') ? args.slice(index + 1) : null;
      }
      continue;
    }
    return basename(value) === 'resend_cli.py' ? args.slice(index + 1) : null;
  }
  return null;
}

function resolvePath(key, token) {
  const candidate = key ? key + ' ' + token : token;
  if (Object.hasOwn(TIERS, candidate) || GROUPS.has(candidate)) return candidate;
  for (const canonical of ALIASES[token] || []) {
    const aliased = key ? key + ' ' + canonical : canonical;
    if (Object.hasOwn(TIERS, aliased)) return aliased;
  }
  return null;
}

// Mirrors classify() in bin/resend_cli.py: the leading run of
// non-option tokens before -- is the command path. True when that path is a
// send, write or destructive leaf, or when an expansion, glob or brace could
// still complete it. A bare call, vendor help, --where/--version, a refused or
// unlisted path and a read run no credentialed effect without approval.
function writePath(args) {
  const tokens = [];
  for (const value of args) {
    if (value === '--') break; // vendor operands: a path or flag there grants nothing
    tokens.push(value);
  }
  if (tokens.some((value) => NO_EFFECT.has(value))) return false;
  let key = '';
  for (let index = 0; index < tokens.length; index += 1) {
    const value = tokens[index];
    if (/[$`]/.test(value)) {
      if (!Object.hasOwn(TIERS, key)) return true; // an expansion may complete the path
      continue;
    }
    if (value === ACCOUNT_FLAG) {
      // The wrapper takes the next word as the account name wherever this
      // flag sits before --, so it is never a path word; an expansion or a
      // glob there may split into one (`--account $A` with A='x emails send').
      index += 1;
      if (index < tokens.length && /[$`*?{[]/.test(tokens[index]) && !Object.hasOwn(TIERS, key)) return true;
      continue;
    }
    if (value.startsWith('-')) continue;
    if (Object.hasOwn(TIERS, key)) continue; // leaf resolved; the rest are vendor operands
    if (/[*?{[]/.test(value)) return true;
    if (value === 'help') return false; // vendor help first, unlisted anywhere else
    key = resolvePath(key, value);
    if (key === null) return false; // the wrapper exits 2 before any file, credential or network access
  }
  return Object.hasOwn(TIERS, key) && ASK_TIERS.has(TIERS[key]);
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
// quoted lookalikes remain data, even when they name a Resend write.
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
const SYNTH_NAME = String.raw`(?:resend-cli|resend_cli\.py)`;
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

// True when the script executes the named CLI with a send, write or
// destructive path (or one it cannot read).
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
      // commandShape consumes every leading assignment, including X=1 R=... .
      if (value && (index < shape.index || DECLARATIONS.has(first) || first === 'env')
          && containsNamedValue(value.value)) {
        const parts = wordValues(value.value);
        aliases.set(value.name, parts.slice(parts.findIndex(named) + 1));
      }
    }
  }
  // The lexer splits an unquoted r=$(command -v resend-cli) into several
  // words, and ${r} into separate segments, so a substitution-held CLI path
  // and its use are matched in the raw text. Single-quoted text never runs.
  const unquoted = script.replace(/'[^'\n]*'/g, "''");
  if (BRACE_RE.test(unquoted.replace(/"[^"\n]*"/g, '""'))) return true;
  for (const match of unquoted.matchAll(SUBSTITUTED_ASSIGNMENT)) {
    if (!aliases.has(match[1])) aliases.set(match[1], []);
  }
  for (const name of aliases.keys()) {
    if (new RegExp(String.raw`"?\$\{?${name}\}?"?` + WRITE_TAIL).test(unquoted)) return true;
  }

  for (const match of script.matchAll(SYNTHESIZED)) {
    if (writePath(wordValues(match[1]))) return true;
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
      if (writePath([...extra, ...shape.args])) return true;
      continue;
    }
    const args = cliArgs(shape);
    if (args !== null) {
      if (writePath(args)) return true;
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
    // send, write or destructive path is a write. Merely mentioning the CLI is not.
    if (INSPECT.has(executable)) continue;
    const at = shape.words.findIndex((word) => !assignment(word) && named(word.value));
    if (at !== -1 && writePath(shape.words.slice(at + 1).map((word) => word.value))) return true;
  }
  return false;
}

// Not every reading here is linear: past this size a repeated CLI name, help
// word or brace takes seconds (400 KB: 6 to 25 s), and a hook killed at its
// 5 s timeout passes. A longer command that names the CLI asks unread
// (re-review of 849b704b).
const MAX_READ = 32 * 1024;
const UNREAD = 'This command names the Resend CLI and is over 32 KiB, too long for the Resend guard to read. ' +
  'Human approval is required for the exact Bash command.';

function evaluate(event) {
  if (event.tool_name && event.tool_name !== 'Bash') return null;
  const command = event.tool_input?.command;
  if (typeof command !== 'string') return null;
  if (command.length > MAX_READ && NAME_RE.test(command)) return ask(UNREAD);
  let writes;
  try { writes = literalWrite(command) || classify(command); } catch { writes = literalWrite(command) || WRITE_RE.test(command); }
  if (!writes) return null;
  return ask(
    'This Resend CLI call sends email, writes or deletes Resend data (or its command path cannot be read statically). ' +
    'Human approval is required for the exact Bash command even with --confirm-send/--confirm-write/--confirm-destructive and bypassPermissions.'
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
module.exports = { classify, evaluate, run, writePath, literalWrite, TIERS, ALIASES, ASK_TIERS, WRITE_RE };
