/**
 * Here-document and comment scanner shared by the hooks that judge a Bash
 * command's text (dotfiles #1853).
 *
 * Each of those hooks carries its own small shell lexer, and those lexers read
 * a here-document body and a `#` comment as shell text. That fails both ways.
 * An odd `'` or `"` in a body or comment opens a quote that hides every command
 * after it (a MISS: `git commit -F - <<'EOF'` with "it's" in the message, then
 * `gh pr merge 5` on a later line, passed loop-guard's fence on 2026-10-16). A
 * command written only as data into a body (`cat > notes.md <<'EOF'`) is acted
 * on (a FALSE HIT). This module removes both from the text a hook lexes and
 * hands back, as separate pieces, the bodies that do run.
 *
 * executedPieces(command) is the entry point. It returns the command as an
 * ordered list of shell texts. Each text has every here-document body and
 * comment removed. The newline that ends a heredoc's opening line is kept, so
 * the text before a body and the text after its terminator stay separate
 * words (shape-rewrite's #1295 round-5 defect was the fused word). A hook
 * lexes each piece on its own and never joins them, because a runnable body
 * may itself hold an unbalanced quote.
 *
 * A body is dropped as data only when its consumer is on a positive
 * allowlist (DATA_COMMANDS and INTERPRETER below). The consumer is the command
 * that reads it, every command it pipes into (directly or after the compound
 * command around it: `{ cat <<EOF …; } | bash`), and, for a heredoc inside
 * `$( )`, backquotes or `<( )`, the command whose word receives that output.
 * Anything else keeps the body as a runnable piece: a shell (`bash <<'EOF'`,
 * `cat <<'EOF' | bash`, `source /dev/stdin`), an unknown command, a loop
 * (`done <<EOF`), a function body, a `>(cmd)` target, a substitution in
 * command position, and a file written by cat, tee or a compound's redirect
 * that a later command in the same call runs (`bash s.sh`, `bash < s.sh`,
 * `cat s.sh | bash`, `sh -c 'cat s.sh|sh'`, matched by basename anywhere in
 * the words of a command that is not DATA) or that is a shell startup file
 * (`.bashrc`, `.profile`, ...), which a later shell runs unnamed. An unquoted
 * delimiter's `$( )` and
 * backquote substitutions run in the outer shell even when the body is data,
 * so they are always pieces, single quotes in the body notwithstanding.
 *
 * Bash facts this follows, each probed on bash 5.2.21 (2026-10-16/17):
 * - The delimiter is the quote-removed word: `<<"a\"b"` is `a"b`, `<<"\$EOF"`
 *   is `$EOF`, `<<"a\zb"` keeps the backslash, `<<$'EOF'` and `<<"E"OF` are
 *   `EOF`. Any quoting makes the body literal. `<<""` ends at an empty line.
 * - `<<` inside `$(( ))`, `(( ))` (including `for ((`) or `$[ ]` is a shift.
 *   `<<1` outside them is a heredoc. A comment's `<<` is not a heredoc, and a
 *   comment starts at any word-initial `#`, after an operator too (`>#f`).
 * - Bodies are read, in operator order, from the first unquoted newline after
 *   the operator, in whatever command-substitution depth that newline sits;
 *   a newline inside a quoted word does not start them. Pending bodies carry
 *   past a `)` that closes `$(cat <<EOF)`.
 * - Inside `$( )` a line holding the delimiter, optional blanks and `)` ends
 *   the body and the `)` closes the substitution (`EOF)`, `EOF )`, `EOF); x`).
 *   `EOF;`, `EOF x`, a subshell's `EOF)` and a backquote's `EOF)` do not.
 * - An unterminated body runs to the end of the command.
 * - `cat <<'EOF' |`, the body, then `bash` on the line after the terminator
 *   pipes the body into bash.
 *
 * Not a full shell parser. `eval`, `node -e`, `python3 -c`, dynamic command
 * names, files written in an earlier call, a written file a later command
 * reaches by a name built at run time (a substitution's output, a variable set
 * outside the call, a glob, a decoded string),
 * and a written file a later command reads without naming it (a Makefile for
 * `make`, a justfile, `package.json` scripts, `.git/hooks/*` on `git push`)
 * stay the documented residuals of the hooks that use it. When this scanner cannot be sure, it leans toward
 * leaving text visible: an unknown consumer keeps its body, and an internal
 * error returns the raw command as the only piece.
 */

'use strict';

// Commands that read stdin, or a substitution's output word, only as data.
const DATA_COMMANDS = new Set([
  'cat', 'tee', 'head', 'tail', 'wc', 'sort', 'uniq', 'tr', 'cut', 'grep', 'egrep', 'fgrep', 'rg',
  'jq', 'yq', 'base64', 'diff', 'column', 'fold', 'fmt', 'nl', 'paste', 'rev', 'od', 'xxd',
  'hexdump', 'iconv', 'envsubst', 'md5sum', 'sha1sum', 'sha256sum', 'shasum',
  'pbcopy', 'wl-copy', 'xclip', 'xsel', 'clip.exe',
  'echo', 'printf', 'true', ':', 'test', '[', '[[',
  'export', 'local', 'declare', 'readonly', 'typeset', 'for', 'case',
  // A commit message (`git commit -F -`) or a PR body (`gh pr create --body-file -`).
  'git', 'gh',
]);
// An interpreter reading its program or data from stdin. Its body is not
// shell, and judging it is outside these hooks, like `python3 -c`.
const INTERPRETER = /^(?:python(?:\d+(?:\.\d+)*)?|node|nodejs|ruby|perl|php)$/;
const SHELLS = new Set(['bash', 'sh', 'dash', 'zsh', 'ksh', 'mksh', 'fish', 'source', '.']);
const SHELL_KIND = new Set([...SHELLS, 'ssh', 'eval', 'xargs']);
// Wrappers skipped to find the command they run. An option value they take
// (`sudo -u user`, `env -u cat bash`) is then read as the command, so once a
// wrapper option outside WRAPPER_FLAGS is skipped a DATA name no longer makes
// the command DATA.
const WRAPPERS = new Set(['sudo', 'nice', 'nohup', 'command', 'builtin', 'exec', 'time', 'stdbuf', 'env', 'timeout']);
// Wrapper options that take no value, so the word after one is still the
// command or another option (`uv run --no-project python -`, `env -i cat`).
const WRAPPER_FLAGS = new Map([
  ['env', new Set(['-i', '--ignore-environment', '-'])],
  ['sudo', new Set(['-n', '--non-interactive', '-E', '-H'])],
  ['uv', new Set(['-q', '--quiet', '--no-project', '--frozen', '--locked', '--isolated', '--no-sync', '--offline'])],
]);
// Builtins whose `NAME=value` operands are assignments (`export BASH_ENV=s.sh`).
const DECLARATIONS = new Set(['export', 'local', 'declare', 'readonly', 'typeset']);
// Reserved words that open a compound command; the word after one is the command.
const OPENERS = new Set(['!', '{', 'if', 'then', 'elif', 'else', 'do', 'while', 'until']);
const BOUNDARIES = new Set([';', ';;', ';&', ';;&', '&', '&&', '||', '|', '|&', '\n', '(', ')']);
const OUTPUT_REDIRECTS = new Set(['>', '>>', '>|', '&>', '&>>', '<>']);
const INPUT_REDIRECTS = new Set(['<', '<>']);
// Reserved words that open a compound command, and the closers that end each.
const COMPOUND_OPENERS = new Set(['{', 'if', 'while', 'until', 'for', 'select', 'case']);
const COMPOUND_CLOSERS = new Map([
  ['}', ['{']], ['fi', ['if']], ['done', ['while', 'until', 'for', 'select']], ['esac', ['case']],
]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=/;
const DEFAULT_MAX_DEPTH = 4;
// The most quote and substitution frames scanCore holds open at once. Every
// enclosing word re-reads its whole interior, so a scan costs depth times
// length; past this a command is refused rather than scanned. The retained
// corpus (484,639 unique Bash commands, 2026-10-17) nests at most 8.
const MAX_NESTING = 64;

// Thrown by scanCore and passed on by executedPieces, never swallowed: a hook
// that fell back to the raw command would read heredoc bodies as shell again,
// so each caller decides what an unscanned command gets.
class NestingTooDeep extends Error {
  constructor(limit) {
    super(`quotes and substitutions nest more than ${limit} levels deep`);
    this.name = 'NestingTooDeep';
    this.limit = limit;
  }
}

function basename(value) {
  const parts = String(value || '').split('/');
  return parts[parts.length - 1];
}

// The basenames inside one word, split at blanks and shell operators, so a
// file named within a string another shell runs still matches:
// `sh -c 'cat s.sh|sh'`, `env -S 'bash s.sh'`, `xargs sh < <(echo s.sh)`.
const WORD_PARTS = /[\s;&|<>(){}`'"=]+/;
function wordFiles(value) {
  return String(value || '').split(WORD_PARTS).map(basename).filter(Boolean);
}

// Startup files a later shell reads on its own (`bash -i`, `bash -l`, `exec
// bash`, the next session), so whatever is written to one counts as run.
const STARTUP_FILES = new Set([
  '.bashrc', '.bash_profile', '.bash_login', '.bash_logout', '.profile', 'bash.bashrc',
  '.zshrc', '.zshenv', '.zprofile', '.zlogin', '.zlogout', '.kshrc', '.mkshrc',
]);

function isData(name) {
  return DATA_COMMANDS.has(name) || INTERPRETER.test(name);
}

// The git and gh subcommands whose stdin is data and that run no command line
// of the caller's. Anything else (an alias, an extension, `git submodule
// foreach`, `git bisect run`, `gh codespace ssh`, `gh alias set m -`, which
// saves stdin as an alias) may hand stdin to a shell.
const GIT_DATA = new Set([
  'add', 'am', 'apply', 'blame', 'branch', 'cat-file', 'check-attr', 'check-ignore', 'check-mailmap',
  'checkout', 'cherry-pick', 'clean', 'clone', 'commit', 'commit-tree', 'config', 'credential',
  'describe', 'diff', 'fast-import', 'fetch', 'for-each-ref', 'format-patch', 'grep', 'hash-object',
  'index-pack', 'init', 'interpret-trailers', 'log', 'ls-files', 'ls-tree', 'mailinfo', 'mailsplit',
  'merge', 'mktag', 'mktree', 'mv', 'name-rev', 'notes', 'pack-objects', 'patch-id', 'push',
  'read-tree', 'remote', 'reset', 'restore', 'rev-list', 'rev-parse', 'revert', 'rm', 'shortlog',
  'show', 'show-ref', 'sparse-checkout', 'stash', 'status', 'stripspace', 'switch', 'tag',
  'unpack-objects', 'update-index', 'update-ref',
]);
const GH_DATA = new Set([
  'api', 'attestation', 'auth', 'browse', 'cache', 'completion', 'config', 'gist',
  'gpg-key', 'issue', 'label', 'org', 'pr', 'project', 'release', 'repo', 'ruleset', 'run',
  'search', 'secret', 'ssh-key', 'status', 'variable', 'workflow',
]);
// git's global options that take the next word as their value.
const GIT_VALUE_OPTIONS = new Set(['-C', '--git-dir', '--work-tree', '--namespace', '--super-prefix']);
// `git -c` keys that start no command. Any other key (alias.*, core.editor,
// core.pager) can start one that reads git's stdin as a script. Hooks get
// their own stdin, and a hook written in the same call is unscanned either
// way, so core.hooksPath stays data.
const GIT_INERT_CONFIG = new Set(['user.name', 'user.email', 'commit.gpgsign', 'core.hookspath']);
// Assignments git and gh read as nothing that starts a command. Any other
// name (GIT_EDITOR, GIT_CONFIG_*, GH_PAGER, HOME, PATH) can point them at one
// that reads stdin as a script: `GIT_EDITOR='bash -s' git commit --amend`.
// A config file of /dev/null holds nothing.
const INERT_ENV = /^(?:(?:ALLOW_[A-Z_]+|GIT_(?:AUTHOR|COMMITTER)_(?:NAME|EMAIL|DATE)|GIT_LITERAL_PATHSPECS|GIT_CONFIG_NOSYSTEM|GH_(?:TOKEN|REPO|HOST|PROMPT_DISABLED|NO_UPDATE_NOTIFIER)|GITHUB_TOKEN|NO_COLOR|LANG|LC_[A-Z]+|TZ)=|GIT_CONFIG_(?:GLOBAL|SYSTEM)=\/dev\/null$)/;

// The subcommand a git command runs, or '' when its global options can start
// some other command first (`-c` outside GIT_INERT_CONFIG, --config-env).
function gitSubcommand(args) {
  for (let k = 0; k < args.length; k += 1) {
    const a = args[k];
    if (a === '-c') {
      const v = args[k + 1] || '';
      const eq = v.indexOf('=');
      if (!GIT_INERT_CONFIG.has((eq === -1 ? v : v.slice(0, eq)).toLowerCase())) return '';
      k += 1;
    } else if (a.startsWith('-c') || a.startsWith('--config-env')) {
      return '';
    } else if (GIT_VALUE_OPTIONS.has(a)) {
      k += 1;
    } else if (!a.startsWith('-')) {
      return a;
    }
  }
  return '';
}

// Whether a described command reads its stdin only as data. A DATA name found
// past a wrapper option may be that option's value (`env -u cat bash`), and
// git or gh given an alias, an extension, inline config or an environment
// outside the inert lists can start a command that reads stdin as a script
// (`git -c alias.m='!bash' m`), so those stay runnable.
function isDataConsumer(name, args, assigns, optioned) {
  if (!isData(name) || optioned) return false;
  if (name !== 'git' && name !== 'gh') return true;
  if (!assigns.every((a) => INERT_ENV.test(a.replace(/^\$/, '')))) return false;
  if (name === 'git') return GIT_DATA.has(gitSubcommand(args));
  return GH_DATA.has(args.find((a) => !a.startsWith('-')) || '');
}

function runnableKind(name) {
  return SHELL_KIND.has(name) ? 'shell' : 'unknown';
}

// A word's text after quote removal, and whether an expansion makes it dynamic.
// Text that quote removal leaves alone is copied a run at a time (`from` marks
// the run's start): a word around a deep substitution holds all of it, and one
// append per character left most of a deep scan's time to the garbage collector.
function unquote(raw) {
  const n = raw.length;
  let value = '';
  let dynamic = false;
  let from = 0;
  let k = 0;
  while (k < n) {
    const c = raw[k];
    if (c === "'") {
      const close = raw.indexOf("'", k + 1);
      const end = close === -1 ? n : close;
      value += raw.slice(from, k) + raw.slice(k + 1, end);
      k = end + 1;
      from = k;
      continue;
    }
    if (c === '\\') {
      value += raw.slice(from, k);
      if (k + 1 < n && raw[k + 1] !== '\n') value += raw[k + 1];
      k += 2;
      from = k;
      continue;
    }
    if (c === '"') {
      value += raw.slice(from, k);
      k += 1;
      from = k;
      while (k < n && raw[k] !== '"') {
        if (raw[k] === '\\' && '"\\$`'.includes(raw[k + 1])) {
          value += raw.slice(from, k) + raw[k + 1];
          k += 2;
          from = k;
          continue;
        }
        if (raw[k] === '$' || raw[k] === '`') dynamic = true;
        k += 1;
      }
      value += raw.slice(from, k);
      k += 1;
      from = k;
      continue;
    }
    if (c === '$' && raw[k + 1] === "'") {
      let end = k + 2;
      while (end < n && raw[end] !== "'") end += raw[end] === '\\' ? 2 : 1;
      value += raw.slice(from, k) + raw.slice(k + 2, Math.min(end, n));
      k = end + 1;
      from = k;
      continue;
    }
    if (c === '$' || c === '`') dynamic = true;
    k += 1;
  }
  if (from < n) value += raw.slice(from, n);
  return { value, dynamic };
}

// The heredoc delimiter word starting at command[j]: its quote-removed text,
// whether any quoting made the body literal, and the index just past it.
function readDelimiter(command, j) {
  const n = command.length;
  let delimiter = '';
  let quoted = false;
  let k = j;
  while (k < n && !' \t\n;&|<>()'.includes(command[k])) {
    const c = command[k];
    if (c === "'") {
      quoted = true;
      const close = command.indexOf("'", k + 1);
      const end = close === -1 ? n : close;
      delimiter += command.slice(k + 1, end);
      k = end + 1;
      continue;
    }
    if (c === '$' && (command[k + 1] === "'" || command[k + 1] === '"')) {
      if (command[k + 1] === '"') {
        k += 1;
        continue;
      }
      quoted = true;
      let end = k + 2;
      while (end < n && command[end] !== "'") end += command[end] === '\\' ? 2 : 1;
      delimiter += command.slice(k + 2, Math.min(end, n));
      k = end + 1;
      continue;
    }
    if (c === '"') {
      quoted = true;
      k += 1;
      while (k < n && command[k] !== '"') {
        if (command[k] === '\\' && '"\\$`\n'.includes(command[k + 1])) {
          if (command[k + 1] !== '\n') delimiter += command[k + 1];
          k += 2;
          continue;
        }
        delimiter += command[k];
        k += 1;
      }
      k += 1;
      continue;
    }
    if (c === '\\') {
      if (command[k + 1] !== '\n') {
        quoted = true;
        if (k + 1 < n) delimiter += command[k + 1];
      }
      k += 2;
      continue;
    }
    delimiter += c;
    k += 1;
  }
  if (k === j) return null;
  return { delimiter, quoted, end: Math.min(k, n) };
}

// The index past any line continuations (backslash-newline) at command[j].
// bash removes them before it reads operators, so `<\␤<` is `<<` and `$\␤(`
// opens a substitution.
function skipContinuations(command, j) {
  while (command[j] === '\\' && command[j + 1] === '\n') j += 2;
  return j;
}

// An unquoted here-document body as bash reads it: each backslash-newline is
// removed, and a backslash before another character is kept with it.
function joinContinuations(body) {
  if (!body.includes('\\\n')) return body;
  let out = '';
  for (let k = 0; k < body.length; k += 1) {
    if (body[k] === '\\') {
      if (body[k + 1] !== '\n') out += body.slice(k, k + 2);
      k += 1;
      continue;
    }
    out += body[k];
  }
  return out;
}

// The text a shell gets from an unquoted body once the outer shell has
// expanded it: a backslash quotes only `$`, a backquote and itself, so
// `\$(cmd)` reaches the runner as `$(cmd)`. Substitutions stay as written.
function unescapeBody(joined) {
  let out = '';
  for (let k = 0; k < joined.length; k += 1) {
    if (joined[k] === '\\' && '$`\\'.includes(joined[k + 1])) {
      out += joined[k + 1];
      k += 1;
      continue;
    }
    out += joined[k];
  }
  return out;
}

function op(value, heredoc) {
  return heredoc ? { type: 'op', value, heredoc } : { type: 'op', value };
}

/**
 * One left-to-right pass over `command`. Returns the text with comments and
 * heredoc bodies removed, every heredoc found, the command frames (top level
 * and each `$( )`, backquote and `<( )`) with their word and operator tokens,
 * and the text offsets where a piece may be split without cutting a quote or
 * substitution. With `inComsub`, the scan starts inside `$(` and stops where
 * that substitution closes, returning the closing `)`'s index as `closedAt`.
 */
function scanCore(command, inComsub) {
  const n = command.length;
  const stack = [];
  const cmdFrames = [];
  const heredocs = [];
  const safePoints = [];
  let pending = [];
  let out = '';
  let copyFrom = 0;
  let closedAt = -1;

  const remove = (start, end) => {
    if (end <= start) return;
    out += command.slice(copyFrom, start);
    copyFrom = end;
  };
  const textLength = (at) => out.length + (at - copyFrom);
  const cont = (j) => skipContinuations(command, j);
  const pushFrame = (frame) => {
    if (stack.length >= MAX_NESTING) throw new NestingTooDeep(MAX_NESTING);
    stack.push(frame);
  };
  const nearestCmd = () => {
    for (let k = stack.length - 1; k >= 0; k -= 1) if (stack[k].kind === 'cmd') return stack[k];
    return null;
  };
  // srcStart and srcEnd: the offsets of a substitution's opener and closer
  // (srcEnd stays undefined while it is open).
  const newCmdFrame = (sub, parent, srcStart) => {
    const frame = {
      kind: 'cmd', sub, tokens: [], word: null, parenDepth: 0, caseDepth: 0,
      conditional: false, regexWord: false, patternDepth: 0, parent, srcStart,
    };
    cmdFrames.push(frame);
    return frame;
  };
  const startWord = (f, i) => {
    if (!f.word) f.word = { start: i };
  };
  const atCommandPosition = (f) => {
    const prev = f.tokens[f.tokens.length - 1];
    if (!prev) return true;
    if (prev.type === 'op') return BOUNDARIES.has(prev.value);
    return OPENERS.has(prev.value);
  };
  const endWord = (f, i) => {
    if (!f.word) return;
    const start = f.word.start;
    const raw = command.slice(start, i);
    const { value, dynamic } = unquote(raw);
    const keyword = raw.replace(/\\\n/g, '');
    // A bare `]]` ends the conditional even when `=~` was a literal operand
    // (for example `[[ -n =~ ]]`), not the binary regex operator.
    if (f.conditional && keyword === ']]') {
      f.conditional = false;
      f.regexWord = false;
    } else if (f.regexWord) {
      f.regexWord = false;
    } else if (!dynamic && keyword === value) {
      if (f.conditional && value === '=~') f.regexWord = true;
      else if (atCommandPosition(f) && value === '[[') f.conditional = true;
    }
    if (!dynamic && raw === value && atCommandPosition(f)) {
      if (value === 'case') f.caseDepth += 1;
      else if (value === 'esac' && f.caseDepth > 0) f.caseDepth -= 1;
    }
    f.tokens.push({ type: 'word', start, end: i, raw, value, dynamic });
    f.word = null;
  };
  // A word of only digits (or `{name}`) right before `<`/`>` names a file
  // descriptor, so it is part of the redirection, not an argument.
  const fdWord = (f, i) => {
    if (f.word && /^(?:\d+|\{[A-Za-z_][A-Za-z0-9_]*\})$/.test(command.slice(f.word.start, i))) f.word = null;
    else endWord(f, i);
  };
  const pushCmd = (sub, at) => {
    const p = nearestCmd();
    const parent = p ? { frame: p, wordIndex: p.tokens.length } : null;
    pushFrame(newCmdFrame(sub, parent, at));
  };
  const popFrame = (i) => {
    const frame = stack.pop();
    if (frame.kind === 'cmd') {
      endWord(frame, i);
      frame.srcEnd = i;
    }
  };
  const inDoubleQuote = () => {
    const t = stack[stack.length - 1];
    return t.kind === 'dq' || (t.kind === 'brace' && t.inDq);
  };

  // One here-document line from pos. In an unquoted body (`joins`) a line that
  // ends in an odd run of backslashes continues on the next, and bash compares
  // the joined line with the delimiter, so `x \` then `EOF` ends nothing.
  // `physical` maps an offset in the joined line back into the command.
  const readLine = (pos, joins) => {
    let line = '';
    const segments = [];
    let p = pos;
    for (;;) {
      let lineEnd = command.indexOf('\n', p);
      const atEof = lineEnd === -1;
      if (atEof) lineEnd = n;
      let run = 0;
      while (run < lineEnd - p && command[lineEnd - 1 - run] === '\\') run += 1;
      segments.push([line.length, p]);
      if (joins && !atEof && run % 2 === 1) {
        line += command.slice(p, lineEnd - 1);
        p = lineEnd + 1;
        continue;
      }
      line += command.slice(p, lineEnd);
      const physical = (at) => {
        let s = segments.length - 1;
        while (s > 0 && segments[s][0] > at) s -= 1;
        return segments[s][1] + (at - segments[s][0]);
      };
      return { line, lineEnd, atEof, physical };
    }
  };

  const readBodies = (pos) => {
    const startText = textLength(pos);
    const first = pos;
    const inSubstitution = stack.some((fr) => fr.kind === 'cmd' && (fr.sub === 'comsub' || fr.sub === 'procsub'));
    while (pending.length) {
      const h = pending.shift();
      h.startText = startText;
      h.bodyStart = pos;
      let closesParen = false;
      for (;;) {
        const { line, lineEnd, atEof, physical } = readLine(pos, !h.quoted);
        const cmp = h.dash ? line.replace(/^\t+/, '') : line;
        if (cmp === h.delimiter) {
          h.bodyEnd = pos;
          h.terminated = true;
          pos = atEof ? n : lineEnd + 1;
          break;
        }
        if (inSubstitution && cmp.startsWith(h.delimiter) && /^[ \t]*\)/.test(cmp.slice(h.delimiter.length))) {
          h.bodyEnd = pos;
          h.terminated = true;
          pos = physical(line.length - cmp.length + h.delimiter.length);
          closesParen = true;
          break;
        }
        if (atEof) {
          h.bodyEnd = n;
          h.terminated = false;
          pos = n;
          break;
        }
        pos = lineEnd + 1;
      }
      h.end = pos;
      const raw = command.slice(h.bodyStart, h.bodyEnd);
      h.body = raw.endsWith('\n') ? raw.slice(0, -1) : raw;
      if (closesParen) break;
    }
    remove(first, pos);
    return pos;
  };

  const handleNewline = (f, i) => {
    const prev = f.tokens[f.tokens.length - 1];
    const continued = prev && prev.type === 'op' && ['|', '|&', '&&', '||'].includes(prev.value);
    f.tokens.push(op('\n'));
    const next = pending.length ? readBodies(i + 1) : i + 1;
    if (stack.length === 1 && f.parenDepth === 0 && !continued) safePoints.push(textLength(next));
    return next;
  };

  const heredocOp = (f, i, after) => {
    fdWord(f, i);
    let j = cont(after);
    const dash = command[j] === '-';
    if (dash) j = cont(j + 1);
    while (command[j] === ' ' || command[j] === '\t') j = cont(j + 1);
    const word = readDelimiter(command, j);
    if (!word) {
      f.tokens.push(op('<<'));
      return after;
    }
    const h = {
      opStart: i, delimEnd: word.end, delimiter: word.delimiter, quoted: word.quoted, dash,
      frame: f, tokenIndex: f.tokens.length,
    };
    f.tokens.push(op(dash ? '<<-' : '<<', h));
    heredocs.push(h);
    pending.push(h);
    return word.end;
  };

  // An unescaped backquote inside backquotes closes them (bash needs \` to nest).
  const backtick = (i) => {
    for (let k = stack.length - 1; k >= 0; k -= 1) {
      if (stack[k].kind !== 'cmd') continue;
      if (stack[k].sub === 'bq') {
        while (stack.length > k) popFrame(i);
        return i + 1;
      }
      break;
    }
    pushCmd('bq', i);
    return i + 1;
  };
  // The first backquote at or after i that no backslash escapes.
  const closingBackquote = (i) => {
    for (let k = i; k < n; k += 1) {
      if (command[k] === '\\') k += 1;
      else if (command[k] === '`') return k;
    }
    return n;
  };

  const dollar = (i) => {
    const j = cont(i + 1);
    const nx = command[j];
    if (nx === '(') {
      const k = cont(j + 1);
      if (command[k] === '(') {
        pushFrame({ kind: 'arith', closer: '))', depth: 0, command: false });
        return k + 1;
      }
      pushCmd('comsub', i);
      return j + 1;
    }
    if (nx === '{') {
      pushFrame({ kind: 'brace', inDq: inDoubleQuote() });
      return j + 1;
    }
    if (nx === '[') {
      pushFrame({ kind: 'arith', closer: ']', depth: 0, command: false });
      return j + 1;
    }
    if (!inDoubleQuote()) {
      if (nx === "'") {
        pushFrame({ kind: 'ansi' });
        return j + 1;
      }
      if (nx === '"') {
        pushFrame({ kind: 'dq' });
        return j + 1;
      }
    }
    return i + 1;
  };

  // `$((a) | b)` and `((a) | b)` hold a subshell, not arithmetic: the lone `)`
  // closed it, so reopen what bash would have parsed.
  const reinterpretArith = (f, i) => {
    stack.pop();
    if (f.command) {
      const c = nearestCmd();
      c.word = null;
      c.tokens.push(op('('));
      c.parenDepth += 1;
    } else {
      pushCmd('comsub', i);
    }
    return i + 1;
  };

  const cmdStep = (f, i) => {
    const ch = command[i];
    if (ch === '\\') {
      if (command[i + 1] === '\n') return i + 2;
      startWord(f, i);
      return i + 2;
    }
    // The next character once line continuations are removed, and its index.
    const j1 = cont(i + 1);
    const nx = command[j1];
    // Keep extglob words opaque rather than treating their `)` as a shell
    // boundary. This preserves the old conservative visibility of `@(a)#b`.
    if (f.patternDepth && ' \t\n'.includes(ch)) return i + 1;
    if (ch === '\n') {
      endWord(f, i);
      return handleNewline(f, i);
    }
    if (ch === ' ' || ch === '\t') {
      endWord(f, i);
      return i + 1;
    }
    if (ch === '#' && !f.word) {
      let j = command.indexOf('\n', i);
      if (j === -1) j = n;
      // Bash finds a backquote's closer before it parses what is inside, so a
      // comment there ends at that closer: `echo `echo a #x`; next`.
      if (stack.some((fr) => fr.sub === 'bq')) j = Math.min(j, closingBackquote(i));
      remove(i, j);
      return j;
    }
    if (ch === "'") {
      startWord(f, i);
      pushFrame({ kind: 'sq' });
      return i + 1;
    }
    if (ch === '"') {
      startWord(f, i);
      pushFrame({ kind: 'dq' });
      return i + 1;
    }
    if (ch === '`') {
      if (f.sub === 'bq') endWord(f, i);
      else startWord(f, i);
      return backtick(i);
    }
    if (ch === '$') {
      startWord(f, i);
      return dollar(i);
    }
    // Bash reads the RHS of `[[ … =~ … ]]` as one regex word. Its parens
    // and alternations are not shell operators: `^(a|b)#c` keeps its `#`.
    // Quotes and substitutions above still use their own frames.
    if (f.regexWord) {
      const after = command[cont(j1 + 1)];
      if (!f.word && ch === ']' && nx === ']' && (after === undefined || /[ \t\n;|&()<>]/.test(after))) {
        f.regexWord = false;
      } else {
        startWord(f, i);
        return i + 1;
      }
    }
    if (f.patternDepth) {
      if (ch === '(') f.patternDepth += 1;
      else if (ch === ')') f.patternDepth -= 1;
      return i + 1;
    }
    if (ch === '(' && f.word) {
      let prev = i - 1;
      while (command[prev] === '\n' && command[prev - 1] === '\\') prev -= 2;
      if ('?*+@!'.includes(command[prev])) {
        f.patternDepth = 1;
        return i + 1;
      }
    }
    if (ch === '(') {
      if (!f.word && nx === '(') {
        startWord(f, i);
        pushFrame({ kind: 'arith', closer: '))', depth: 0, command: true });
        return j1 + 1;
      }
      endWord(f, i);
      f.tokens.push(op('('));
      f.parenDepth += 1;
      return i + 1;
    }
    if (ch === ')') {
      endWord(f, i);
      if (f.parenDepth > 0) {
        f.parenDepth -= 1;
        f.tokens.push(op(')'));
        return i + 1;
      }
      if (f.caseDepth === 0 && (f.sub === 'comsub' || f.sub === 'procsub')) {
        popFrame(i);
        if (inComsub && stack.length === 1) closedAt = i;
        return i + 1;
      }
      f.tokens.push(op(')'));
      return i + 1;
    }
    if (ch === '<' || ch === '>') {
      if (nx === '(') {
        startWord(f, i);
        pushCmd('procsub', i);
        return j1 + 1;
      }
      if (ch === '<' && nx === '<' && command[cont(j1 + 1)] !== '<') return heredocOp(f, i, j1 + 1);
      fdWord(f, i);
      let value = ch;
      let j = i + 1;
      if (ch === '<' && nx === '<') {
        value = '<<<';
        j = cont(j1 + 1) + 1;
      } else if (nx === ch || (ch === '<' && nx === '>') || (ch === '>' && nx === '|')) {
        value += nx;
        j = j1 + 1;
      }
      if (value.length === 1 && command[cont(j)] === '&') {
        value += '&';
        j = cont(j) + 1;
      }
      f.tokens.push(op(value));
      return j;
    }
    if (ch === '&') {
      endWord(f, i);
      if (nx === '&') {
        f.tokens.push(op('&&'));
        return j1 + 1;
      }
      if (nx === '>') {
        const k = cont(j1 + 1);
        const append = command[k] === '>';
        f.tokens.push(op(append ? '&>>' : '&>'));
        return append ? k + 1 : j1 + 1;
      }
      f.tokens.push(op('&'));
      return i + 1;
    }
    if (ch === '|') {
      endWord(f, i);
      if (nx === '|' || nx === '&') {
        f.tokens.push(op(`|${nx}`));
        return j1 + 1;
      }
      f.tokens.push(op('|'));
      return i + 1;
    }
    if (ch === ';') {
      endWord(f, i);
      if (nx === ';') {
        const k = cont(j1 + 1);
        const amp = command[k] === '&';
        f.tokens.push(op(amp ? ';;&' : ';;'));
        return amp ? k + 1 : j1 + 1;
      }
      if (nx === '&') {
        f.tokens.push(op(';&'));
        return j1 + 1;
      }
      f.tokens.push(op(';'));
      return i + 1;
    }
    startWord(f, i);
    return i + 1;
  };

  const arithStep = (f, i) => {
    const ch = command[i];
    if (ch === '\\') return i + 2;
    if (f.closer === ']') {
      if (ch === '[') {
        f.depth += 1;
        return i + 1;
      }
      if (ch === ']') {
        if (f.depth > 0) f.depth -= 1;
        else stack.pop();
        return i + 1;
      }
    } else if (ch === '(') {
      f.depth += 1;
      return i + 1;
    } else if (ch === ')') {
      if (f.depth > 0) {
        f.depth -= 1;
        return i + 1;
      }
      const j = cont(i + 1);
      if (command[j] === ')') {
        stack.pop();
        if (f.command) endWord(nearestCmd(), j + 1);
        return j + 1;
      }
      return reinterpretArith(f, i);
    }
    if (ch === '"') {
      pushFrame({ kind: 'dq' });
      return i + 1;
    }
    if (ch === '`') return backtick(i);
    if (ch === '$') return dollar(i);
    return i + 1;
  };

  pushFrame(newCmdFrame('top', null));
  if (inComsub) pushCmd('comsub', 0);
  let i = 0;
  while (i < n && closedAt === -1) {
    const f = stack[stack.length - 1];
    const ch = command[i];
    if (f.kind === 'cmd') {
      i = cmdStep(f, i);
    } else if (f.kind === 'sq') {
      if (ch === "'") stack.pop();
      i += 1;
    } else if (f.kind === 'ansi') {
      if (ch === '\\') i += 2;
      else {
        if (ch === "'") stack.pop();
        i += 1;
      }
    } else if (f.kind === 'dq') {
      if (ch === '\\') i += 2;
      else if (ch === '"') {
        stack.pop();
        i += 1;
      } else if (ch === '`') i = backtick(i);
      else if (ch === '$') i = dollar(i);
      else i += 1;
    } else if (f.kind === 'brace') {
      if (ch === '\\') i += 2;
      else if (ch === '}') {
        stack.pop();
        i += 1;
      } else if (ch === "'" && !f.inDq) {
        pushFrame({ kind: 'sq' });
        i += 1;
      } else if (ch === '"') {
        pushFrame({ kind: 'dq' });
        i += 1;
      } else if (ch === '`') i = backtick(i);
      else if (ch === '$') i = dollar(i);
      else i += 1;
    } else {
      i = arithStep(f, i);
    }
  }
  const end = Math.min(i, n);
  for (let k = stack.length - 1; k >= 0; k -= 1) if (stack[k].kind === 'cmd') endWord(stack[k], end);
  const text = out + command.slice(copyFrom);
  for (const h of pending) {
    h.startText = text.length;
    h.bodyStart = n;
    h.bodyEnd = n;
    h.end = n;
    h.terminated = false;
    h.body = '';
  }
  return { text, heredocs, cmdFrames, safePoints, closedAt };
}

// The simple command around tokens[idx]: from the boundary before it to the
// one after. The verdict helpers below memoize per frame (segment bounds,
// describe, compound parents, pipe walks), because many heredocs can share a
// command or a pipeline (`cat <<A <<B …`, `cat <<A | cat <<B | …`) and
// redoing that work for each was quadratic; shape-rewrite.test.js times
// thousands of heredocs on one line through heavy-job-admission.
function segmentAt(frame, idx) {
  const tokens = frame.tokens;
  if (!frame.segStart) {
    frame.segStart = new Int32Array(tokens.length + 1);
    frame.segEnd = new Int32Array(tokens.length + 1);
    let start = 0;
    for (let k = 0; k <= tokens.length; k += 1) {
      frame.segStart[k] = start;
      if (k === tokens.length || (tokens[k].type === 'op' && BOUNDARIES.has(tokens[k].value))) {
        frame.segEnd[start] = k;
        start = k + 1;
      }
    }
  }
  const start = frame.segStart[Math.min(idx, tokens.length)];
  return { start, end: frame.segEnd[start] };
}

// A word as describe() reports it: a dynamic word keeps a leading `$`, so
// `"$HOME/s.sh"` is `$$HOME/s.sh` and its basename still names `s.sh`.
function wordValue(t) {
  return t.dynamic ? `$${t.value}` : t.value;
}

// An output process substitution, `>(cmd)`: whatever is written to it runs as cmd's stdin.
function isOutputProcsub(t) {
  return t.raw.startsWith('>(');
}

// The command a simple command runs once wrappers are peeled: its name and
// the token index of that word (`at`), its arguments, whether it reads stdin
// only as data (`data`), its assignments (prefix and `env NAME=value`), the
// files it writes and reads through redirections, whether it writes to a
// `>(cmd)`, and the role each word token plays in it (`roles`: command,
// argument, assignment or redirect; absent is missing). Callers must not
// mutate the cached result.
function describe(frame, seg) {
  if (!frame.described) frame.described = new Map();
  const cached = frame.described.get(seg.start);
  if (cached) return cached;
  const tokens = frame.tokens;
  const words = [];
  const assigns = [];
  const writes = [];
  const reads = [];
  const roles = new Map();
  let procsubOut = false;
  for (let k = seg.start; k < seg.end; k += 1) {
    const t = tokens[k];
    if (t.type === 'op') {
      if (t.heredoc || t.value === '\n') continue;
      const target = tokens[k + 1];
      if (k + 1 < seg.end && target.type === 'word') {
        roles.set(k + 1, 'redirect');
        if (isOutputProcsub(target)) procsubOut = true;
        else if (OUTPUT_REDIRECTS.has(t.value)) writes.push(wordValue(target));
        if (INPUT_REDIRECTS.has(t.value)) reads.push(wordValue(target));
        k += 1;
      }
      continue;
    }
    if (words.length === 0 && ASSIGNMENT.test(t.raw)) {
      roles.set(k, 'assignment');
      assigns.push(wordValue(t));
      continue;
    }
    if (words.length === 0 && OPENERS.has(t.raw)) continue;
    if (words.length > 0 && isOutputProcsub(t)) procsubOut = true;
    words.push(t);
    roles.set(k, words.length === 1 ? 'command' : 'argument');
  }
  const values = words.map(wordValue);
  let w = 0;
  let optioned = false;
  while (w < values.length) {
    const wrapper = basename(values[w]);
    if (wrapper === 'uv' && values[w + 1] === 'run') w += 2;
    else if (WRAPPERS.has(wrapper)) w += 1;
    else break;
    for (; w < values.length; w += 1) {
      if (values[w].startsWith('-')) {
        if (!WRAPPER_FLAGS.get(wrapper)?.has(values[w])) optioned = true;
      }
      else if (wrapper === 'env' && ASSIGNMENT.test(values[w])) assigns.push(values[w]);
      else break;
    }
    if (wrapper === 'timeout' && w < values.length) w += 1;
  }
  const word = w < values.length ? values[w] : '';
  const name = basename(word);
  const at = w < words.length ? tokens.indexOf(words[w], seg.start) : seg.start;
  const args = values.slice(w + 1);
  if (name === 'tee') for (const a of args) if (!a.startsWith('-') && !a.startsWith('>(')) writes.push(a);
  const data = isDataConsumer(name, args, assigns, optioned);
  const d = { name, word, at, args, data, assigns, roles, writes, reads, procsubOut };
  frame.described.set(seg.start, d);
  return d;
}

// The compound commands in one frame's tokens, as { open, close, kind, fn }
// token indices: `{ }`, `( )`, if, while, until, for, select and case. `close`
// is -1 when the compound never closes; `fn` marks a function body (`f() {`,
// `function f {`). A reserved word counts only in command position, and a
// case pattern's parens are not a subshell.
function compoundPairs(tokens) {
  const pairs = [];
  const stack = [];
  let cmdPos = true;
  let casePattern = false;
  let fnName = false;
  let fnBody = false;
  let skipTarget = false;
  const open = (k, kind) => {
    const pair = { open: k, close: -1, kind, fn: fnBody };
    fnBody = false;
    pairs.push(pair);
    stack.push(pair);
  };
  const close = (k) => {
    stack.pop().close = k;
  };
  for (let k = 0; k < tokens.length; k += 1) {
    const t = tokens[k];
    const top = stack[stack.length - 1];
    if (casePattern) {
      if (t.type === 'op' && t.value === ')') {
        casePattern = false;
        cmdPos = true;
      } else if (t.type === 'word' && t.raw === 'esac' && top && top.kind === 'case') {
        close(k);
        casePattern = false;
        cmdPos = false;
      }
      continue;
    }
    if (t.type === 'op') {
      if (t.heredoc) continue;
      if (t.value === '(' && tokens[k + 1] && tokens[k + 1].type === 'op' && tokens[k + 1].value === ')') {
        k += 1;
        fnBody = true;
        cmdPos = true;
      } else if (t.value === '(') {
        open(k, '(');
        cmdPos = true;
      } else if (t.value === ')') {
        if (top && top.kind === '(') close(k);
        cmdPos = false;
      } else if (BOUNDARIES.has(t.value)) {
        cmdPos = true;
        if (top && top.kind === 'case' && (t.value === ';;' || t.value === ';&' || t.value === ';;&')) casePattern = true;
      } else {
        skipTarget = true;
      }
      continue;
    }
    if (skipTarget) {
      skipTarget = false;
      continue;
    }
    const word = !t.dynamic && t.raw === t.value ? t.value : null;
    if (top && top.kind === 'case' && !top.sawIn && word === 'in') {
      top.sawIn = true;
      casePattern = true;
      continue;
    }
    if (fnName) {
      fnName = false;
      fnBody = true;
      cmdPos = true;
      continue;
    }
    if (!cmdPos || word === null) {
      cmdPos = false;
      continue;
    }
    if (COMPOUND_OPENERS.has(word)) {
      open(k, word);
      cmdPos = word !== 'for' && word !== 'select' && word !== 'case';
    } else if (COMPOUND_CLOSERS.has(word) && top && COMPOUND_CLOSERS.get(word).includes(top.kind)) {
      close(k);
      cmdPos = false;
    } else if (word === 'function') {
      fnName = true;
      cmdPos = false;
    } else {
      cmdPos = OPENERS.has(word) || word === 'time';
    }
  }
  return pairs;
}

// The compound commands around token index `at`, innermost first. Pairs nest,
// since compoundPairs closes only the innermost open one, so one pass finds
// each token's innermost pair and each pair's parent.
function enclosingCompounds(frame, at) {
  const tokens = frame.tokens;
  if (!frame.compounds) {
    const pairs = compoundPairs(tokens);
    const innermost = new Int32Array(tokens.length + 1);
    const stack = [];
    let next = 0;
    for (let k = 0; k <= tokens.length; k += 1) {
      while (stack.length && pairs[stack[stack.length - 1]].close !== -1 && pairs[stack[stack.length - 1]].close <= k) stack.pop();
      innermost[k] = stack.length ? stack[stack.length - 1] : -1;
      while (next < pairs.length && pairs[next].open === k) {
        pairs[next].parent = innermost[k];
        stack.push(next);
        next += 1;
      }
    }
    frame.compounds = { pairs, innermost };
  }
  const { pairs, innermost } = frame.compounds;
  const chain = [];
  for (let i = innermost[Math.min(at, tokens.length)]; i !== -1; i = pairs[i].parent) chain.push(pairs[i]);
  return chain;
}

// The first command a simple command's stdout pipes into that is not DATA, if
// any. A compound command or subshell after the pipe counts as one. When none
// does, the files the DATA stages write are added to `writes`. Memoized per
// pipe position; a pipeline whose DATA stages write more files than
// PIPE_WRITES_CAP counts as running one, rather than copying the list down
// every stage.
const PIPE_WRITES_CAP = 64;
function pipesIntoRunner(frame, end, writes) {
  const tokens = frame.tokens;
  if (!frame.pipes) frame.pipes = new Map();
  const stages = [];
  let k = end;
  let result = null;
  for (;;) {
    result = frame.pipes.get(k);
    if (result) break;
    if (!(k < tokens.length && tokens[k].type === 'op' && (tokens[k].value === '|' || tokens[k].value === '|&'))) {
      result = { into: null, writes: [] };
      break;
    }
    let j = k + 1;
    while (j < tokens.length && tokens[j].type === 'op' && tokens[j].value === '\n') j += 1;
    if (j >= tokens.length) {
      result = { into: null, writes: [] };
      break;
    }
    if (tokens[j].type === 'op' || (!tokens[j].dynamic && COMPOUND_OPENERS.has(tokens[j].raw))) {
      result = { into: tokens[j].type === 'op' ? tokens[j].value : tokens[j].raw, writes: [] };
      break;
    }
    const seg = segmentAt(frame, j);
    const d = describe(frame, seg);
    if (!d.data || d.procsubOut) {
      result = { into: d.name || '(none)', writes: [] };
      break;
    }
    stages.push({ at: k, writes: d.writes });
    k = seg.end;
  }
  for (let s = stages.length - 1; s >= 0; s -= 1) {
    const own = stages[s].writes;
    if (!result.into && own.length) {
      result = own.length + result.writes.length > PIPE_WRITES_CAP
        ? { into: '(writes)', writes: [] }
        : { into: null, writes: [...own, ...result.writes] };
    }
    frame.pipes.set(stages[s].at, result);
  }
  if (!result.into) writes.push(...result.writes);
  return result.into;
}

// Where the stdout of the simple command at seg, described by d, goes: the
// first command that is not DATA to read it, through the pipes after it and
// then after each compound command around it (`{ cat <<EOF …; } | bash`).
// A function body or a compound that never closes counts as one, since where
// its output goes is not known here. Output redirections met on the way are
// added to `writes`.
function outputRunner(frame, seg, d, writes) {
  const tokens = frame.tokens;
  const into = pipesIntoRunner(frame, seg.end, writes);
  if (into) return into;
  for (const pair of enclosingCompounds(frame, d.at)) {
    if (pair.fn) return 'function';
    if (pair.close === -1) return pair.kind;
    let k = pair.close + 1;
    while (k < tokens.length && !(tokens[k].type === 'op' && BOUNDARIES.has(tokens[k].value))) {
      const t = tokens[k];
      const target = tokens[k + 1];
      if (t.type === 'op' && !t.heredoc && target && target.type === 'word') {
        if (isOutputProcsub(target)) return target.raw;
        if (OUTPUT_REDIRECTS.has(t.value)) writes.push(wordValue(target));
        k += 2;
        continue;
      }
      k += 1;
    }
    const r = pipesIntoRunner(frame, k, writes);
    if (r) return r;
  }
  return null;
}

// Where a substitution's output word goes: null when it is data there,
// otherwise the verdict that makes the heredoc inside it runnable. Files the
// command around that word writes are added to `writes`.
function wordVerdict(frame, wIdx, writes) {
  const seg = segmentAt(frame, wIdx);
  const d = describe(frame, seg);
  const role = d.roles.get(wIdx) || 'missing';
  if (role === 'command' || role === 'missing') return { kind: 'command-word', consumer: '' };
  if (role === 'assignment' || role === 'redirect') return null;
  if (!d.data) return { kind: runnableKind(d.name), consumer: d.name };
  if (d.procsubOut) return { kind: 'unknown', consumer: d.name };
  writes.push(...d.writes);
  const into = outputRunner(frame, seg, d, writes);
  return into ? { kind: runnableKind(into), consumer: into } : null;
}

// The verdict for the output of a DATA command: the first command that is not
// DATA to read it, through pipes and compound commands and, inside a
// substitution, the word the substitution fills. Null when it stays data.
function outputConsumer(frame, seg, d, writes) {
  if (d.procsubOut) return { kind: 'unknown', consumer: d.name };
  const into = outputRunner(frame, seg, d, writes);
  if (into) return { kind: runnableKind(into), consumer: into };
  for (let f = frame; f.parent; f = f.parent.frame) {
    const v = wordVerdict(f.parent.frame, f.parent.wordIndex, writes);
    if (v) return v;
  }
  return null;
}

// basename -> the last source offset of a command that runs that file: the
// command word itself, an operand or stdin file of a command that is not DATA
// (`bash s.sh`, `bash < s.sh`, `source s.sh`), or one a DATA command hands to
// such a command (`cat s.sh | bash`), or the value of any assignment, which a
// shell may read unnamed (`BASH_ENV=s.sh bash -c true`, `export BASH_ENV=s.sh`).
// Those words are matched part by part (wordFiles), so a file named inside a
// string another shell runs counts too.
function runIndex(cmdFrames) {
  const runs = new Map();
  const note = (b, at) => {
    if (b && at > (runs.get(b) ?? -1)) runs.set(b, at);
  };
  // frame -> word index -> the substitution frames inside that word, in source order.
  const subs = new Map();
  for (const c of cmdFrames) {
    if (!c.parent) continue;
    let byWord = subs.get(c.parent.frame);
    if (!byWord) subs.set(c.parent.frame, (byWord = new Map()));
    const list = byWord.get(c.parent.wordIndex);
    if (list) list.push(c);
    else byWord.set(c.parent.wordIndex, [c]);
  }
  for (const frame of cmdFrames) {
    const tokens = frame.tokens;
    let k = 0;
    while (k < tokens.length) {
      const seg = segmentAt(frame, k);
      const first = tokens.slice(seg.start, seg.end).find((t) => t.type === 'word');
      if (first) {
        const d = describe(frame, seg);
        note(d.name, first.start);
        if (!d.data || dataOutput(frame, seg, d).out) {
          for (const a of [d.word, ...d.args, ...d.reads]) for (const b of wordFiles(a)) note(b, first.start);
        }
        for (let j = seg.start; j < seg.end; j += 1) {
          if (!isAssignmentWord(d, j, tokens[j])) continue;
          const v = literalValue(subs.get(frame)?.get(j), tokens[j]);
          for (const b of wordFiles(v.slice(v.indexOf('=') + 1))) note(b, first.start);
        }
      }
      k = Math.max(seg.end + 1, k + 1);
    }
  }
  return runs;
}

// Whether token j of a described command is an assignment: a prefix one, an
// `env NAME=value` operand, or a `NAME=value` operand of export and the like.
function isAssignmentWord(d, j, t) {
  const role = d.roles.get(j);
  if (role === 'assignment') return true;
  return role === 'argument' && (j < d.at || DECLARATIONS.has(d.name)) && ASSIGNMENT.test(t.value);
}

// An assignment word's value with the substitutions inside it cut out: their
// commands are read in their own frames, so `out=$(gh pr create --body-file
// b.md)` names no file itself. An open substitution runs to the word's end.
function literalValue(children, t) {
  if (!children) return t.value;
  let text = '';
  let from = 0;
  for (const c of children) {
    const s = c.srcStart - t.start;
    if (!(s >= from && s < t.raw.length)) continue;
    text += t.raw.slice(from, s);
    from = c.srcEnd === undefined ? t.raw.length : Math.min(t.raw.length, c.srcEnd + 1 - t.start);
  }
  return unquote(text + t.raw.slice(from)).value;
}

// What a DATA command's output reaches and the files it writes, once per
// command however many heredocs it reads.
function dataOutput(frame, seg, d) {
  if (!frame.outputs) frame.outputs = new Map();
  let o = frame.outputs.get(seg.start);
  if (!o) {
    const writes = [...d.writes];
    o = { out: outputConsumer(frame, seg, d, writes), writes, lastRun: undefined };
    frame.outputs.set(seg.start, o);
  }
  return o;
}

// The last source offset at which a file the command writes is run, or -1;
// Infinity for a shell startup file, which a later shell runs unnamed.
function lastRunOfWrites(o, lazyRuns) {
  if (o.lastRun === undefined) {
    o.lastRun = -1;
    const runs = o.writes.length ? lazyRuns() : null;
    for (const target of o.writes) {
      if (target === '/dev/null') continue;
      const b = basename(target);
      o.lastRun = STARTUP_FILES.has(b) ? Infinity : Math.max(o.lastRun, runs.get(b) ?? -1);
    }
  }
  return o.lastRun;
}

function heredocVerdict(h, lazyRuns) {
  const seg = segmentAt(h.frame, h.tokenIndex);
  const d = describe(h.frame, seg);
  if (!d.name) return { runnable: true, kind: 'unknown', consumer: '' };
  if (!d.data) return { runnable: true, kind: runnableKind(d.name), consumer: d.name };
  const o = dataOutput(h.frame, seg, d);
  if (o.out) return { runnable: true, ...o.out };
  if (lastRunOfWrites(o, lazyRuns) >= h.end) return { runnable: true, kind: 'write-then-run', consumer: d.name };
  return { runnable: false, kind: 'data', consumer: d.name };
}

// The `$( )` and backquote substitutions an unquoted body runs when the outer
// shell expands it. Quotes are literal there; only a backslash escapes.
function bodySubstitutions(body) {
  const found = [];
  for (let k = 0; k < body.length; k += 1) {
    const c = body[k];
    if (c === '\\') {
      k += 1;
      continue;
    }
    if (c === '$' && body[k + 1] === '(') {
      if (body[k + 2] === '(') {
        k += 2;
        continue;
      }
      const inner = body.slice(k + 2);
      const closedAt = scanCore(inner, true).closedAt;
      const end = closedAt === -1 ? inner.length : closedAt;
      found.push(inner.slice(0, end));
      k += 1 + end + 1;
      continue;
    }
    if (c === '`') {
      let end = k + 1;
      while (end < body.length && body[end] !== '`') end += body[end] === '\\' ? 2 : 1;
      found.push(body.slice(k + 1, Math.min(end, body.length)));
      k = end;
    }
  }
  return found;
}

// The first value >= x in an ascending array, by binary search.
function firstAtOrAfter(sorted, x) {
  let lo = 0;
  let hi = sorted.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (sorted[mid] < x) lo = mid + 1;
    else hi = mid;
  }
  return lo < sorted.length ? sorted[lo] : undefined;
}

/**
 * Scan one command: `text` has every comment and heredoc body removed, and
 * `heredocs` lists each operator in source order with its delimiter, body,
 * offsets in `command` (opStart, bodyStart, bodyEnd, end), consumer verdict
 * (`runnable`, `kind`: data | shell | unknown | command-word |
 * write-then-run, `consumer`), the substitutions an unquoted body runs
 * (`fragments`), and `insertAt`, the offset in `text` where its runnable
 * pieces belong.
 */
function scanHeredocs(command) {
  const core = scanCore(command, false);
  let runs = null;
  const lazyRuns = () => {
    if (!runs) runs = runIndex(core.cmdFrames);
    return runs;
  };
  const heredocs = core.heredocs.map((h) => {
    const verdict = heredocVerdict(h, lazyRuns);
    const insertAt = firstAtOrAfter(core.safePoints, h.startText) ?? core.text.length;
    return {
      opStart: h.opStart,
      delimEnd: h.delimEnd,
      delimiter: h.delimiter,
      quoted: h.quoted,
      dash: h.dash,
      bodyStart: h.bodyStart,
      bodyEnd: h.bodyEnd,
      end: h.end,
      terminated: h.terminated,
      body: h.body,
      runnable: verdict.runnable,
      kind: verdict.kind,
      consumer: verdict.consumer,
      fragments: h.quoted ? [] : bodySubstitutions(joinContinuations(h.body)),
      insertAt,
    };
  });
  return { text: core.text, heredocs };
}

// Text with neither can hold no heredoc body and no comment.
const NEEDS_SCAN = /<(?:\\\n)*<|#/;

/**
 * The command as the ordered shell texts that run: the top-level text cut at
 * safe line boundaries, with each runnable body and body substitution
 * (expanded the same way, up to `maxDepth` levels) placed after the line
 * that reads it. Each piece is `{ text, depth }`. Lex each piece separately.
 * Throws NestingTooDeep for a command nested past MAX_NESTING; any other
 * internal error returns the whole command as one piece.
 */

function executedPieces(command, { maxDepth = DEFAULT_MAX_DEPTH } = {}) {
  if (typeof command !== 'string') return [];
  if (!NEEDS_SCAN.test(command)) return [{ text: command, depth: 0 }];
  const pieces = [];
  const expand = (cmd, depth) => {
    if (depth > maxDepth) {
      pieces.push({ text: cmd, depth });
      return;
    }
    const scan = scanHeredocs(cmd);
    let last = 0;
    for (const h of scan.heredocs) {
      const runs = h.quoted ? h.body : unescapeBody(joinContinuations(h.body));
      const extras = h.runnable ? [runs, ...h.fragments] : h.fragments;
      if (!extras.length) continue;
      if (h.insertAt > last) {
        pieces.push({ text: scan.text.slice(last, h.insertAt), depth });
        last = h.insertAt;
      }
      for (const extra of extras) expand(extra, depth + 1);
    }
    if (last < scan.text.length || last === 0) pieces.push({ text: scan.text.slice(last), depth });
  };
  try {
    expand(command, 0);
  } catch (err) {
    if (err instanceof NestingTooDeep) throw err;
    return [{ text: command, depth: 0 }];
  }
  return pieces;
}

module.exports = { executedPieces, scanHeredocs, NestingTooDeep, MAX_NESTING, DATA_COMMANDS, INTERPRETER };
