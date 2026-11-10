'use strict';

// Could a Bash deny or ask rule from a settings file match this command?
//
// Claude Code checks permission rules against the input a PreToolUse hook
// returns, not the input the agent sent (code.claude.com/docs/en/hooks,
// updatedInput: "Claude Code evaluates permission rules ... against the input
// your hook returns"). A hook that wraps the whole command in one quoted
// argument (heavy-job-admission) or replaces it with `bash <script>`
// (shape-rewrite) therefore hides every subcommand from those rules:
// `pnpm build && pnpm publish` would run past a `Bash(pnpm publish:*)` deny.
// Before such a rewrite, the hook asks this module, and leaves the command
// untouched when a rule could apply, so Claude Code applies it to the text the
// agent wrote.
//
// The test is deliberately over-inclusive. A false "may apply" costs only the
// rewrite; a false "does not apply" lets a rule be bypassed. So an unreadable
// settings file, a command nested too deep, or a spent deadline all count as
// "may apply". A rule is tried at every word where a command can start (start
// of a segment, after assignments or `then`/`do`, or any word after a wrapper
// such as sudo, env, xargs or a shell; `/usr/bin/wget` also counts as `wget`),
// against the rest of the command with redirections dropped: the rule's text up
// to its first `*` must begin there, and each later piece must follow in order,
// anywhere up to the end of the command. A rule that holds a shell operator
// (`|`, `;`, `>`, ...) or starts with `*` cannot be pinned to one command
// start, so it gets a looser test: its first word at a command start and every
// other piece anywhere in the command.
//
// Not visible here: rules passed on the command line (--settings,
// --allowedTools/--disallowedTools), rules added for one session, and
// server-delivered managed policy. Those can still be hidden by a rewrite.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { shellTokens, isSubstitution } = require('./shell-words');

// Test seam, same pattern as STRAY_DOT_GIT_FS_ROOT: the suite points it at an
// empty sandbox so the host's managed policy cannot change a result.
const MANAGED_DIR_ENV = 'CLAUDE_HOOK_MANAGED_SETTINGS_DIR';
const MANAGED_DIRS = {
  linux: ['/etc/claude-code'],
  darwin: ['/Library/Application Support/ClaudeCode'],
  win32: ['C:\\Program Files\\ClaudeCode'],
};

const BOUNDARIES = new Set([';', '&', '&&', '|', '||', '\n', '(', ')']);
const OPENERS = new Set(['!', '{', '}', 'if', 'then', 'elif', 'else', 'fi', 'do', 'done', 'while', 'until', 'coproc']);
// Commands that run their arguments as another command. After one of these,
// every later word in the segment counts as a possible command word.
const WRAPPERS = new Set([
  'sudo', 'doas', 'su', 'runuser', 'env', 'nice', 'nohup', 'ionice', 'chrt', 'taskset', 'setsid',
  'stdbuf', 'timeout', 'time', 'command', 'builtin', 'exec', 'eval', 'xargs', 'find', 'parallel',
  'watch', 'flock', 'strace', 'ltrace', 'unbuffer', 'script', 'systemd-run', 'ssh', 'busybox',
  'bash', 'sh', 'dash', 'zsh', 'ksh', 'mksh', 'fish', 'source', '.',
]);
const ASSIGNMENT = /^[a-z_][a-z0-9_]*\+?=/;
const DIGITS = /^\d+$/;
// A quoted word carrying any of these may be shell text run elsewhere
// (bash -c '...', eval "...", ssh host '...'): scan it as a command too.
const NESTED_TEXT = /[\s;&|`()<>$]/;
// Shell syntax in a rule that a single command start cannot hold.
const SPANS_COMMANDS = /[|;&<>()$`\n]/;
const MAX_DEPTH = 16;
// Callers without their own deadline get this much time before failing closed.
const DEFAULT_BUDGET_MS = 300;

class Unscannable extends Error {}

function basename(word) {
  return word.slice(Math.max(word.lastIndexOf('/'), word.lastIndexOf('\\')) + 1);
}

function exists(file) {
  try {
    fs.statSync(file);
    return true;
  } catch {
    return false;
  }
}

/** Upward from `start` to the nearest directory holding `.git`, inclusive. */
function projectDirs(start) {
  const dirs = [];
  let dir = path.resolve(start);
  for (;;) {
    dirs.push(dir);
    if (exists(path.join(dir, '.git'))) break;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // A worktree under <checkout>/.claude/worktrees/<name> stops the walk at its
  // own .git file; the checkout that owns it may hold the project's rules.
  for (const d of [...dirs]) {
    const worktrees = path.dirname(d);
    const dotClaude = path.dirname(worktrees);
    if (path.basename(worktrees) === 'worktrees' && path.basename(dotClaude) === '.claude') {
      dirs.push(path.dirname(dotClaude));
    }
  }
  return dirs;
}

/** Every settings file that may carry permission rules for a call in `cwd`. */
function settingsFiles({ cwd, env = process.env } = {}) {
  const files = [];
  if (env.CLAUDE_CONFIG_DIR) files.push(path.join(env.CLAUDE_CONFIG_DIR, 'settings.json'));
  const home = env.HOME || env.USERPROFILE || os.homedir();
  if (home) files.push(path.join(home, '.claude', 'settings.json'));

  for (const start of [env.CLAUDE_PROJECT_DIR, cwd]) {
    if (typeof start !== 'string' || !path.isAbsolute(start)) continue;
    for (const dir of projectDirs(start)) {
      files.push(path.join(dir, '.claude', 'settings.json'), path.join(dir, '.claude', 'settings.local.json'));
    }
  }

  const managedDirs = env[MANAGED_DIR_ENV] ? [env[MANAGED_DIR_ENV]] : MANAGED_DIRS[process.platform] || [];
  for (const dir of managedDirs) {
    files.push(path.join(dir, 'managed-settings.json'));
    let dropIns = [];
    try {
      dropIns = fs.readdirSync(path.join(dir, 'managed-settings.d'));
    } catch {
      /* no drop-in directory */
    }
    for (const name of dropIns.sort()) {
      if (name.endsWith('.json') && !name.startsWith('.')) files.push(path.join(dir, 'managed-settings.d', name));
    }
  }
  return [...new Set(files)];
}

/** The Bash deny and ask rules in `files`, plus any file that could not be read. */
function loadBashRules(files) {
  const rules = [];
  const unreadable = [];
  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (err) {
      if (err && (err.code === 'ENOENT' || err.code === 'ENOTDIR')) continue;
      unreadable.push(file);
      continue;
    }
    let settings;
    try {
      settings = JSON.parse(text);
    } catch {
      unreadable.push(file);
      continue;
    }
    const perms = settings && typeof settings === 'object' ? settings.permissions : null;
    if (!perms || typeof perms !== 'object') continue;
    for (const kind of ['deny', 'ask']) {
      if (!Array.isArray(perms[kind])) continue;
      for (const rule of perms[kind]) {
        const pattern = bashPattern(rule);
        if (pattern !== null) rules.push({ kind, rule, pattern, file });
      }
    }
  }
  return { rules, unreadable };
}

/** The text inside Bash(...), '' for a bare Bash rule, null for anything else. */
function bashPattern(rule) {
  if (typeof rule !== 'string') return null;
  const r = rule.trim();
  if (r === 'Bash') return '';
  if (!r.startsWith('Bash(') || !r.endsWith(')')) return null;
  return r.slice('Bash('.length, -1);
}

function normalize(text) {
  return String(text).toLowerCase().split('"').join('').split("'").join('').split('\\').join('');
}

/** Words that sit where a command can start, lowercased. Throws Unscannable. */
function commandWords(command, { deadline } = {}) {
  return scanCommand(command, deadline).words;
}

/**
 * The command's command-start words, and for each command text (the whole
 * command, plus every substitution and quoted shell text inside it) a
 * single-spaced lowercase copy with redirections dropped and the offset of
 * every command start in it. Throws Unscannable.
 */
function scanCommand(command, deadline) {
  const scan = { words: new Set(), streams: [] };
  collect(String(command), 0, scan, deadline);
  return scan;
}

function collect(text, depth, scan, deadline) {
  if (depth > MAX_DEPTH) throw new Unscannable('nested too deep to check against permission rules');
  const toks = shellTokens(text, { preserveWords: true });
  const ops = toks.ops || [];
  const meta = toks.meta || [];
  let stream = '';
  const starts = [];
  const append = (word, isStart) => {
    if (isStart) {
      starts.push(stream.length);
      const slash = Math.max(word.lastIndexOf('/'), word.lastIndexOf('\\'));
      if (slash >= 0 && slash < word.length - 1) starts.push(stream.length + slash + 1);
    }
    stream += `${word} `;
  };
  let atStart = true;
  let wrapped = false;
  let skipTarget = false;
  for (let i = 0; i < toks.length; i += 1) {
    if (deadline && (i & 63) === 0 && Date.now() > deadline) {
      throw new Unscannable('ran out of time checking against permission rules');
    }
    const tok = toks[i];
    if (isSubstitution(tok)) {
      collect(tok.payload, depth + 1, scan, deadline);
      continue;
    }
    if (ops[i]) {
      if (BOUNDARIES.has(tok)) {
        atStart = true;
        wrapped = false;
        skipTarget = false;
        append(tok, false);
      } else {
        skipTarget = true; // a redirection: its next word is a file, not a command
      }
      continue;
    }
    const word = String(tok).toLowerCase();
    if (meta[i] && meta[i].quoted && NESTED_TEXT.test(word)) collect(word, depth + 1, scan, deadline);
    if (skipTarget) {
      skipTarget = false;
      continue;
    }
    // `2>/dev/null cmd`: a file-descriptor number before a redirection.
    if (atStart && DIGITS.test(word) && ops[i + 1] && !BOUNDARIES.has(toks[i + 1])) continue;
    const isStart = wrapped || atStart;
    append(word, isStart);
    if (!isStart) continue;
    scan.words.add(word);
    if (wrapped || ASSIGNMENT.test(word) || OPENERS.has(word)) continue;
    atStart = false;
    if (WRAPPERS.has(basename(word))) wrapped = true;
  }
  if (starts.length) scan.streams.push({ stream, starts });
}

/**
 * Normalized rule text. A trailing `:*` is written as ` *`, which Claude Code
 * treats the same: `Bash(su:*)` covers `su` and `su -`, not `sudo`.
 */
function rulePattern(pattern) {
  const norm = normalize(pattern).trim().split(/\s+/).join(' ');
  return norm.endsWith(':*') ? `${norm.slice(0, -2)} *` : norm;
}

function ruleMayMatch(pattern, scan, haystack) {
  const norm = rulePattern(pattern);
  if (norm.split('*').join('').trim() === '') return true; // Bash, Bash(), Bash(*)
  if (norm.startsWith('*') || SPANS_COMMANDS.test(norm)) return looseMatch(pattern, scan.words, haystack);
  return anchoredMatch(norm.split('*'), scan.streams);
}

// Linear in the command's length per stream: plain string searches, no regex,
// so odd rule text cannot backtrack. Starts are in ascending order and a piece
// missing after one start is missing after every later one, so the first miss
// ends the stream.
function anchoredMatch([head, ...rest], streams) {
  for (const { stream, starts } of streams) {
    for (const at of starts) {
      if (!stream.startsWith(head, at)) continue;
      const found = piecesFollow(stream, at + head.length, rest);
      if (found === true) return true;
      if (found === null) break;
    }
  }
  return false;
}

/** true, false (not here), or null (not after here either). */
function piecesFollow(stream, from, pieces) {
  // A rule without `*` must end where a word ends.
  if (!pieces.length) return stream[from] === ' ';
  let pos = from;
  for (let k = 0; k < pieces.length; k += 1) {
    const piece = pieces[k];
    if (piece === '') continue;
    // `git * main` also covers `git main`: the spaces around `*` can be one.
    let idx = stream.indexOf(piece, piece.startsWith(' ') && stream[pos - 1] === ' ' ? pos - 1 : pos);
    if (k === pieces.length - 1) {
      while (idx >= 0 && stream[idx + piece.length] !== ' ') idx = stream.indexOf(piece, idx + 1);
    }
    if (idx < 0) return null;
    pos = idx + piece.length;
  }
  return true;
}

function looseMatch(pattern, words, haystack) {
  let norm = normalize(pattern).trim();
  if (norm.endsWith(':*')) norm = norm.slice(0, -2);
  const tokens = norm.split(/\s+/).filter(Boolean);
  if (!tokens.length || tokens.every((t) => t.split('*').join('') === '')) return true;
  const pieces = norm.split(/[\s*]+/).filter(Boolean);
  if (!pieces.every((p) => haystack.includes(p))) return false;
  const first = tokens[0];
  const star = first.indexOf('*');
  if (star === 0) return true; // no literal command word to anchor on
  const head = star < 0 ? first : first.slice(0, star);
  const headBase = basename(head);
  for (const word of words) {
    const base = basename(word);
    if (star < 0) {
      if (word === head || base === head || base === headBase) return true;
    } else if (word.startsWith(head) || base.startsWith(head) || base.startsWith(headBase)) {
      return true;
    }
  }
  return false;
}

/**
 * @param {string} command the Bash command the agent sent
 * @param {{cwd?: string, env?: object, deadline?: number}} opts
 * @returns {{applies: boolean, reason?: string}}
 */
function permissionRuleMayApply(command, { cwd, env = process.env, deadline } = {}) {
  const { rules, unreadable } = loadBashRules(settingsFiles({ cwd, env }));
  if (unreadable.length) return { applies: true, reason: `unreadable settings file ${unreadable[0]}` };
  if (!rules.length) return { applies: false };
  const text = String(command);
  const haystack = `${text.toLowerCase()}\n${normalize(text)}`;
  const until = deadline || Date.now() + DEFAULT_BUDGET_MS;
  let scan;
  try {
    scan = scanCommand(text, until);
  } catch (err) {
    return { applies: true, reason: err instanceof Unscannable ? `command ${err.message}` : 'command could not be scanned' };
  }
  for (const r of rules) {
    if (Date.now() > until) return { applies: true, reason: 'command ran out of time checking against permission rules' };
    if (ruleMayMatch(r.pattern, scan, haystack)) return { applies: true, reason: `${r.kind} rule ${r.rule} (${r.file})` };
  }
  return { applies: false };
}

module.exports = {
  permissionRuleMayApply,
  settingsFiles,
  loadBashRules,
  commandWords,
  MANAGED_DIR_ENV,
};
